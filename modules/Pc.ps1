# Pc.ps1 -- PC module, maximum profile.
#
# One table (Get-PcRegTweaks) drives both Apply and Verify, so the two can never disagree.
# Every change goes through the journal first (lib\Journal.ps1), so Undo can restore it exactly.

$script:CodExeNames = @('cod.exe', 'cod24.exe', 'cod23.exe', 'ModernWarfare.exe')
$script:PcPlanName  = 'Kpekpes COD Custom Max'
$script:QosName     = 'Kpekpes COD Custom'
$script:TaskReapply = 'Kpekpes PC Reapply'
$script:TaskTimer   = 'Kpekpes Timer Resolution'
$script:PcSteps     = 15
$script:PcStepNo    = 0
$script:GuidRx      = '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
$script:IfeoPath    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$script:Presence    = 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter'

function Write-PcStep {
    param([string]$Text)
    $script:PcStepNo++
    Write-Say ('[{0}/{1}] {2}' -f $script:PcStepNo, $script:PcSteps, $Text) 'Cyan'
}

# ---------------- hardware / install discovery ----------------
function Test-HasNvidia {
    try { return [bool](Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -match 'NVIDIA' }) } catch { return $false }
}

function Get-IsSingleCcdAmd {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
    if (-not $cpu) { return $false }
    if (@($cpu)[0].Name -notmatch 'AMD') { return $false }
    $cores = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
    return ($cores -le 8)   # single-CCD Ryzen = 6 or 8 cores
}

function Test-IsAmdCpu {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
    if (-not $cpu) { return $false }
    return (@($cpu)[0].Name -match 'AMD')
}

function Get-PhysEthernet {
    try {
        return @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Wi-Fi|Wireless|WLAN|Bluetooth' })
    } catch { return @() }
}

function Get-CodInstallRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    $candidates = @(
        'C:\Program Files (x86)\Call of Duty', 'C:\Program Files\Call of Duty',
        'C:\Program Files (x86)\Steam\steamapps\common\Call of Duty HQ',
        'C:\Program Files (x86)\Steam\steamapps\common\Call of Duty',
        'C:\XboxGames\Call of Duty', 'C:\Program Files\ModifiableWindowsApps\Call of Duty'
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { [void]$roots.Add($c) } }
    $vdf = 'C:\Program Files (x86)\Steam\steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $txt = Get-Content -LiteralPath $vdf -Raw -ErrorAction SilentlyContinue
        if ($txt) {
            foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) {
                $lib = ($m.Groups[1].Value -replace '\\\\', '\')
                foreach ($g in @('Call of Duty HQ', 'Call of Duty')) {
                    $p = Join-Path $lib ('steamapps\common\' + $g)
                    if (Test-Path -LiteralPath $p) { [void]$roots.Add($p) }
                }
            }
        }
    }
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -match 'Call of Duty|Warzone|Black Ops' -and $p.InstallLocation -and (Test-Path -LiteralPath $p.InstallLocation)) {
                [void]$roots.Add($p.InstallLocation.TrimEnd('\'))
            }
        }
    return @($roots | Select-Object -Unique)
}

function Get-BattleNetRoots {
    $l = @()
    foreach ($p in @('C:\Program Files (x86)\Battle.net', 'C:\Program Files\Battle.net')) { if (Test-Path -LiteralPath $p) { $l += $p } }
    return $l
}

$script:CodPathsCache = $null

function Get-CodExePaths {
    # The search walks the game folders, so the result is cached for the length of one run.
    if ($null -ne $script:CodPathsCache) { return @($script:CodPathsCache) }
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($root in (Get-CodInstallRoots)) {
        foreach ($name in $script:CodExeNames) {
            Get-ChildItem -LiteralPath $root -Filter $name -Recurse -Depth 8 -File -ErrorAction SilentlyContinue |
                Select-Object -First 3 | ForEach-Object { [void]$found.Add($_.FullName) }
        }
    }
    $script:CodPathsCache = @($found | Select-Object -Unique)
    return @($script:CodPathsCache)
}

# ---------------- the registry tweak table ----------------
function New-RT {
    param([string]$Group, [string]$Label, [string]$Path, [string]$Name, $Value, [string]$Kind = 'DWord', [bool]$Placebo = $false, [bool]$BestEffort = $false)
    return [pscustomobject]@{ Group = $Group; Label = $Label; Path = $Path; Name = $Name; Value = $Value; Kind = $Kind; Placebo = $Placebo; BestEffort = $BestEffort }
}

function Get-PcRegTweaks {
    param($Cfg)
    $t = New-Object System.Collections.ArrayList
    function Add-RT { param($g, $l, $p, $n, $v, $k = 'DWord', $pl = $false, $be = $false) [void]$t.Add((New-RT $g $l $p $n $v $k $pl $be)) }

    $gfx      = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $gameBar  = 'HKCU:\Software\Microsoft\GameBar'
    $gcs      = 'HKCU:\System\GameConfigStore'
    $sys      = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $games    = $sys + '\Tasks\Games'
    $tcp      = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    $cpKey    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583'
    $desk     = 'HKCU:\Control Panel\Desktop'
    $adv      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $cdm      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $hvci     = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    $gdvrUser = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'

    $g = 'Power & CPU'
    Add-RT $g 'Power throttling off' 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
    Add-RT $g 'Fast startup off' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
    Add-RT $g 'Core-parking range max = 100' $cpKey 'ValueMax' 100
    Add-RT $g 'Core-parking range min = 0' $cpKey 'ValueMin' 0

    $g = 'Graphics & Game Mode'
    Add-RT $g 'Hardware GPU scheduling on' $gfx 'HwSchMode' 2
    Add-RT $g 'MPO disabled (OverlayTestMode = 5)' 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5
    if ($Cfg.GameModeOff) {
        # opt-in, and never on dual-CCD X3D chips: AMD's V-Cache driver relies on Game Mode
        $gmOk = $true
        try { if (Get-Command Get-PcCpuPolicy -ErrorAction SilentlyContinue) { $gmOk = -not (Get-PcCpuPolicy).Kind.Equals('dual-ccd-x3d') } } catch { }
        if ($gmOk) {
            Add-RT $g 'Game Mode off (AllowAutoGameMode)' $gameBar 'AllowAutoGameMode' 0
            Add-RT $g 'Game Mode off (AutoGameModeEnabled)' $gameBar 'AutoGameModeEnabled' 0
        }
    }
    Add-RT $g 'Game Bar controller button off' $gameBar 'UseNexusForGameBarEnabled' 0
    Add-RT $g 'Game Bar startup panel off' $gameBar 'ShowStartupPanel' 0
    Add-RT $g 'Game DVR off' $gcs 'GameDVR_Enabled' 0
    Add-RT $g 'Exclusive fullscreen behavior' $gcs 'GameDVR_FSEBehaviorMode' 2
    Add-RT $g 'Honor fullscreen behavior' $gcs 'GameDVR_HonorUserFSEBehaviorMode' 1
    Add-RT $g 'DXGI honors FSE windows compat' $gcs 'GameDVR_DXGIHonorFSEWindowsCompatible' 1
    Add-RT $g 'EFSE feature flags cleared' $gcs 'GameDVR_EFSEFeatureFlags' 0
    Add-RT $g 'Capture off (user)' $gdvrUser 'AppCaptureEnabled' 0
    Add-RT $g 'Honor user fullscreen behavior' $gdvrUser 'HonorUserFullScreenBehavior' 1
    Add-RT $g 'Game DVR policy off' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    Add-RT $g 'Capture off (machine)' 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Add-RT $g 'Game DVR policy off (user)' 'HKCU:\Software\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    Add-RT $g 'Auto HDR off' 'HKCU:\Software\Microsoft\DirectX' 'DisableAutoHDR' 1
    Add-RT $g 'Auto HDR off (video settings)' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\VideoSettings' 'EnableAutoHDR' 0
    if (Test-Path -LiteralPath $script:Presence) {
        Add-RT $g 'Game Bar presence writer off' $script:Presence 'Enabled' 0 'DWord' $false $true
    }

    $g = 'Scheduling'
    Add-RT $g 'Timer resolution requests honored globally' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1
    Add-RT $g 'Network throttling index off' $sys 'NetworkThrottlingIndex' 0xFFFFFFFF 'DWord' $true
    Add-RT $g 'System responsiveness = 0' $sys 'SystemResponsiveness' 0 'DWord' $true
    Add-RT $g 'MMCSS Games: GPU priority' $games 'GPU Priority' 8 'DWord' $true
    Add-RT $g 'MMCSS Games: priority' $games 'Priority' 6 'DWord' $true
    Add-RT $g 'MMCSS Games: scheduling category' $games 'Scheduling Category' 'High' 'String' $true
    Add-RT $g 'MMCSS Games: SFIO priority' $games 'SFIO Priority' 'High' 'String' $true
    Add-RT $g 'MMCSS Games: latency sensitive' $games 'Latency Sensitive' 'True' 'String' $true
    Add-RT $g 'MMCSS Games: clock rate' $games 'Clock Rate' 10000 'DWord' $true
    Add-RT $g 'MMCSS Games: affinity' $games 'Affinity' 0 'DWord' $true
    Add-RT $g 'MMCSS Games: background only off' $games 'Background Only' 'False' 'String' $true
    Add-RT $g 'Win32PrioritySeparation = 2' 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 2 'DWord' $true

    $g = 'Visual effects & input'
    Add-RT $g 'Visual effects: best performance' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
    Add-RT $g 'Visual effects mask' $desk 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
    Add-RT $g 'Menu delay = 0' $desk 'MenuShowDelay' '0' 'String'
    Add-RT $g 'Show window contents while dragging' $desk 'DragFullWindows' '1' 'String'
    Add-RT $g 'Font smoothing' $desk 'FontSmoothing' '2' 'String'
    Add-RT $g 'Minimize animation off' ($desk + '\WindowMetrics') 'MinAnimate' '0' 'String'
    Add-RT $g 'Transparency off' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
    Add-RT $g 'Taskbar animations off' $adv 'TaskbarAnimations' 0
    Add-RT $g 'Mouse acceleration off (speed)' 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
    Add-RT $g 'Mouse acceleration off (threshold 1)' 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
    Add-RT $g 'Mouse acceleration off (threshold 2)' 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
    Add-RT $g 'Mouse sensitivity 6/11 (1:1)' 'HKCU:\Control Panel\Mouse' 'MouseSensitivity' '10' 'String'
    Add-RT $g 'Sticky Keys popup off' 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
    Add-RT $g 'Filter Keys popup off' 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'
    Add-RT $g 'Toggle Keys popup off' 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String'

    $g = 'Background noise'
    Add-RT $g 'Background apps off' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
    Add-RT $g 'Background app toggle off' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0
    Add-RT $g 'Suggested content off (1)' $cdm 'SubscribedContent-338388Enabled' 0
    Add-RT $g 'Suggested content off (2)' $cdm 'SubscribedContent-338389Enabled' 0
    Add-RT $g 'Cortana policy off' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
    Add-RT $g 'Cortana consent off' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
    Add-RT $g 'Search box suggestions off' 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    if ($Cfg.DisableToastNotifications) {
        # opt-in: this switch can also hide Windows Security alerts
        Add-RT $g 'Toast notifications off' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
    }
    Add-RT $g 'Copilot off' 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Add-RT $g 'Sync provider notifications off' $adv 'ShowSyncProviderNotifications' 0
    Add-RT $g 'Taskbar widgets off' $adv 'TaskbarDa' 0 'DWord' $false $true

    if ($Cfg.WindowsUpdateBlock) {
        $g = 'Windows Update control'
        Add-RT $g 'No driver updates via Windows Update' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1
        Add-RT $g 'No auto-reboot while logged in' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1
        Add-RT $g 'Delivery Optimization peer sharing off' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
        Add-RT $g 'Store auto-download off' 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2
    }

    if ($Cfg.HvciOff) {
        $g = 'Memory integrity'
        Add-RT $g 'Memory integrity (HVCI) off' $hvci 'Enabled' 0
        Add-RT $g 'Virtualization-based security off' 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
    }

    $g = 'Network (registry)'
    Add-RT $g 'TcpNoDelay (global)' $tcp 'TcpNoDelay' 1 'DWord' $true
    Add-RT $g 'TcpAckFrequency (global)' $tcp 'TcpAckFrequency' 1 'DWord' $true
    Add-RT $g 'TcpDelAckTicks (global)' $tcp 'TcpDelAckTicks' 0 'DWord' $true
    Add-RT $g 'QoS reserved bandwidth = 0' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0 'DWord' $true
    try {
        foreach ($nic in @(Get-NetAdapter -Physical -ErrorAction Stop)) {
            $ip = $tcp + '\Interfaces\' + $nic.InterfaceGuid
            if (Test-Path -LiteralPath $ip) {
                Add-RT $g ('Nagle off: TcpAckFrequency (' + $nic.Name + ')') $ip 'TcpAckFrequency' 1 'DWord' $true
                Add-RT $g ('Nagle off: TCPNoDelay (' + $nic.Name + ')') $ip 'TCPNoDelay' 1 'DWord' $true
            }
        }
    } catch { }

    if (Test-HasNvidia) {
        $g = 'NVIDIA (telemetry only - no driver-key writes)'
        Add-RT $g 'NVIDIA telemetry RID 44231 off' 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS' 'EnableRID44231' 0
        Add-RT $g 'NVIDIA telemetry RID 64640 off' 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS' 'EnableRID64640' 0
        Add-RT $g 'NVIDIA telemetry RID 66610 off' 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS' 'EnableRID66610' 0
        Add-RT $g 'NVIDIA ShadowPlay recording off' 'HKCU:\Software\NVIDIA Corporation\Global\ShadowPlay\NVSPCAPS' 'DVREnabled' 0
    }

    if ($Cfg.GameProcessTweaks) {
        $g = 'Game process'
        $names = @($script:CodExeNames) + @('DS4Windows.exe')
        foreach ($exe in $names) {
            Add-RT $g ('High CPU priority: ' + $exe) ($script:IfeoPath + '\' + $exe + '\PerfOptions') 'CpuPriorityClass' 3
            Add-RT $g ('High I/O priority: ' + $exe) ($script:IfeoPath + '\' + $exe + '\PerfOptions') 'IoPriority' 3
        }
        foreach ($p in (Get-CodExePaths)) {
            Add-RT $g ('High-performance GPU: ' + (Split-Path $p -Leaf)) 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $p 'GpuPreference=2;' 'String'
            Add-RT $g ('Fullscreen optimizations off: ' + (Split-Path $p -Leaf)) 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' $p '~ DISABLEDXMAXIMIZEDWINDOWEDMODE HIGHDPIAWARE' 'String'
        }
    }
    return @($t)
}

function Invoke-PcRegTweaks {
    param($Cfg, [switch]$Reapply)
    $fail = 0
    foreach ($t in (Get-PcRegTweaks $Cfg)) {
        # The logon re-apply leaves your own mouse / visual / input choices alone unless you switch it on.
        if ($Reapply -and -not $Cfg.ReapplyUserPreferences -and $t.Group -eq 'Visual effects & input') { continue }
        $script:KGroup = $t.Group   # tags the journal entry, so one group can be undone on its own (A/B testing)
        $ok = Set-KReg $t.Path $t.Name $t.Value $t.Kind
        $script:KGroup = $null
        if (-not $ok -and -not $t.BestEffort) { $fail++ }
    }
    return $fail
}

# ---------------- safety net: restore point ----------------
function Invoke-RestorePointSafe {
    # Repairs what usually makes restore points fail, retries, and verifies the result.
    # The journal is the real undo, so a restore point that still fails is reported but does not stop the run.
    $res = [pscustomobject]@{ Ok = $false; Detail = '' }
    if ($script:WhatIfMode) { $res.Detail = 'skipped (what-if)'; return $res }
    $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $freqName = 'SystemRestorePointCreationFrequency'
    $old = Get-RegRaw $srKey $freqName
    try {
        foreach ($s in @('VSS', 'swprv')) {
            $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -eq 'Disabled') {
                Save-KServiceState $s   # journaled first, so Undo puts the start type back
                Set-Service -Name $s -StartupType Manual -ErrorAction SilentlyContinue
            }
        }
        $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'
        foreach ($n in @('DisableSR', 'DisableConfig')) {
            $v = (Get-ItemProperty -LiteralPath $pol -Name $n -ErrorAction SilentlyContinue).$n
            if ($v -eq 1) { [void](Set-KReg $pol $n 0) }
        }
        Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction Stop
        $before = Get-KShadowStorage $env:SystemDrive
        if ($before.Known) {
            [void](Add-KEntry ('sysprot|' + $env:SystemDrive) @{ Type = 'sysprot'; Drive = $env:SystemDrive; Known = $before.Known; Had = $before.Had; Percent = $before.Percent; Unbounded = $before.Unbounded })
            try { & vssadmin.exe resize shadowstorage ('/for=' + $env:SystemDrive) ('/on=' + $env:SystemDrive) '/maxsize=10%' 2>&1 | Out-Null } catch { }
        }
        New-ItemProperty -LiteralPath $srKey -Name $freqName -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
        $desc = 'Before Kpekpes COD Custom ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
        $made = $false; $err = ''
        for ($try = 1; $try -le 2 -and -not $made; $try++) {
            try { Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; $made = $true }
            catch { $err = $_.Exception.Message; Start-Sleep -Seconds 3 }
        }
        if ($made) {
            $seen = Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Where-Object { $_.Description -eq $desc }
            if ($seen) { $res.Ok = $true; $res.Detail = $desc } else { $res.Detail = 'created but not listed yet' }
        } else { $res.Detail = $err }
    } catch { $res.Detail = $_.Exception.Message }
    finally {
        # put the frequency value back exactly as it was
        try {
            if ($old.Existed) { New-ItemProperty -LiteralPath $srKey -Name $freqName -PropertyType DWord -Value (ConvertTo-RegInt $old.Raw) -Force -ErrorAction SilentlyContinue | Out-Null }
            else { Remove-ItemProperty -LiteralPath $srKey -Name $freqName -ErrorAction SilentlyContinue }
        } catch { }
    }
    return $res
}

# ---------------- power plan ----------------
function Initialize-PcPowerPlan {
    $active = (& powercfg.exe /getactivescheme | Out-String)
    $m = [regex]::Match($active, $script:GuidRx)
    $orig = ''
    if ($m.Success) { $orig = $m.Value }
    $entry = Get-KEntry 'power|plan'
    $list = (& powercfg.exe /list | Out-String)
    if ($entry -and $entry.OurGuid -and ($list -match [regex]::Escape([string]$entry.OurGuid))) { return [string]$entry.OurGuid }
    $new = ''
    foreach ($src in @('e9a42b02-d5df-448d-aa00-03f14749eb61', '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')) {
        $out = (& powercfg.exe -duplicatescheme $src 2>&1 | Out-String)
        $mm = [regex]::Match($out, $script:GuidRx)
        if ($mm.Success) { $new = $mm.Value; break }
    }
    if (-not $new) { return '' }
    & powercfg.exe -changename $new $script:PcPlanName 'Maximum performance for Call of Duty' | Out-Null
    if ($entry) { Update-KEntry 'power|plan' 'OurGuid' $new }
    else { [void](Add-KEntry 'power|plan' @{ Type = 'powerscheme'; OriginalGuid = $orig; OurGuid = $new }) }
    return $new
}

function Set-PcPower {
    param([string]$Plan, [string]$Sub, [string]$Key, [int]$Value)
    & powercfg.exe /setacvalueindex $Plan $Sub $Key $Value 2>&1 | Out-Null
    & powercfg.exe /setdcvalueindex $Plan $Sub $Key $Value 2>&1 | Out-Null
}

function Get-PcPowerIndex {
    param([string]$Plan, [string]$Sub, [string]$Key)
    try {
        $out = (& powercfg.exe /q $Plan $Sub $Key 2>&1 | Out-String)
        $m = [regex]::Match($out, 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)')
        if ($m.Success) { return [Convert]::ToInt32($m.Groups[1].Value, 16) }
    } catch { }
    return $null
}

function Invoke-PcPower {
    if ($script:WhatIfMode) { Write-Say '  [what-if] would create the Kpekpes COD Custom Max power plan and make it active' 'Yellow'; return $true }
    $plan = Initialize-PcPowerPlan
    if (-not $plan) { Write-Say '  could not create the power plan' 'Red'; return $false }
    $pol = Get-PcCpuPolicy   # exact CCD count from the L3 caches, X3D-aware (lib\Topology.ps1 + lib\Stats.ps1)
    $single = -not $pol.DisableParking
    if ($pol.Reason) { Write-Say ('  core parking left to Windows: ' + $pol.Reason) 'DarkGray' }
    $amd = Test-IsAmdCpu
    Set-PcPower $plan 'SUB_PROCESSOR' 'PROCTHROTTLEMIN' 100
    Set-PcPower $plan 'SUB_PROCESSOR' 'PROCTHROTTLEMAX' 100
    Set-PcPower $plan 'SUB_PROCESSOR' 'PERFBOOSTMODE' 2
    Set-PcPower $plan 'SUB_PROCESSOR' 'PERFEPP' 0
    if ($amd) { Set-PcPower $plan 'SUB_PROCESSOR' 'PERFINCPOL' 1 } else { Set-PcPower $plan 'SUB_PROCESSOR' 'PERFINCPOL' 2 }
    Set-PcPower $plan 'SUB_PROCESSOR' 'PERFDECPOL' 1
    if (-not $single) {
        Set-PcPower $plan 'SUB_PROCESSOR' 'CPMINCORES' 100
        Set-PcPower $plan 'SUB_PROCESSOR' 'CPMAXCORES' 100
    }
    Set-PcPower $plan '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 0   # USB selective suspend
    Set-PcPower $plan '2a737441-1930-4402-8d77-b2bebba308a3' 'd4e98f31-5ffe-4ce1-be31-1b38b384c009' 0   # USB 3 link power management
    Set-PcPower $plan '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5' 0   # PCIe link state power management
    Set-PcPower $plan 'SUB_DISK' 'DISKIDLE' 0
    & powercfg.exe /setactive $plan | Out-Null
    return $true
}

# ---------------- timer ----------------
function Invoke-PcTimer {
    param($Cfg)
    if ($script:WhatIfMode) { Write-Say '  [what-if] would set the boot clock options and start the 0.5 ms timer holder' 'Yellow'; return $true }
    [void](Set-KBcd 'disabledynamictick' 'yes')
    if ($Cfg.UsePlatformTick) { [void](Set-KBcd 'useplatformtick' 'yes') }
    $dir = Join-Path $script:DataRoot 'pc'
    $hp = Join-Path $dir 'TimerResolutionHold.ps1'
    $hold = @'
Add-Type -Namespace Native -Name TimerRes -MemberDefinition @"
[DllImport("ntdll.dll", SetLastError = true)]
public static extern int NtSetTimerResolution(uint DesiredResolution, bool SetResolution, out uint CurrentResolution);
"@
$target = 5000
[uint32]$current = 0
[Native.TimerRes]::NtSetTimerResolution($target, $true, [ref]$current) | Out-Null
while ($true) { Start-Sleep -Seconds 3600 }
'@
    [void](Add-KEntry ('file|' + $hp) @{ Type = 'file'; Path = $hp })
    [IO.File]::WriteAllText($hp, $hold, (New-Object Text.UTF8Encoding($false)))
    Stop-KProcessByCommandLine '*TimerResolutionHold*'
    [void](Add-KEntry 'proc|timerhold' @{ Type = 'proc'; Pattern = '*TimerResolutionHold*' })
    Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $hp + '"') -WindowStyle Hidden
    try {
        [void](Add-KEntry ('task|' + $script:TaskTimer) @{ Type = 'task'; Name = $script:TaskTimer })
        $u = $env:USERDOMAIN + '\' + $env:USERNAME
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $hp + '"')
        $tr = New-ScheduledTaskTrigger -AtLogOn -User $u
        $p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Limited
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $script:TaskTimer -Action $a -Trigger $tr -Principal $p -Settings $s -Force -ErrorAction Stop | Out-Null
        return $true
    } catch { Write-KLog ('timer task failed: ' + $_.Exception.Message) 'WARN'; return $false }
}

# ---------------- TCP ----------------
function Get-PcNetshWant {
    return [ordered]@{ autotuninglevel = 'normal'; rss = 'enabled'; rsc = 'disabled'; ecncapability = 'disabled'; timestamps = 'disabled'; heuristics = 'disabled'; congestion = 'ctcp' }
}

function Invoke-PcTcp {
    $before = Get-NetshTcp
    $want = Get-PcNetshWant
    $skipped = @()
    foreach ($k in $want.Keys) {
        if ($null -eq $before[$k]) { $skipped += $k; continue }
        [void](Set-KNetsh $k $want[$k] $before)
    }
    if ($skipped.Count -gt 0) { Write-Say ('  not readable on this Windows, left alone: ' + ($skipped -join ', ')) 'DarkGray' }
}

# ---------------- network adapter ----------------
function Invoke-PcNic {
    $wantRx = '^(Energy Efficient Ethernet|Green Ethernet|Power Saving Mode|Gigabit Lite|Advanced EEE|Interrupt Moderation|Flow Control|Jumbo Packet|Jumbo Frames)$'
    foreach ($nic in (Get-PhysEthernet)) {
        $guid = [string]$nic.InterfaceGuid
        $st = @{ Type = 'nicstate'; Guid = $guid; Name = $nic.Name; Rss = $null; PowerMgmt = $null; LsoV4 = $null; LsoV6 = $null; RscV4 = $null; RscV6 = $null }
        try { $st.Rss = [bool](Get-NetAdapterRss -Name $nic.Name -ErrorAction Stop).Enabled } catch { }
        try { $st.PowerMgmt = [string](Get-NetAdapterPowerManagement -Name $nic.Name -ErrorAction Stop).AllowComputerToTurnOffDevice } catch { }
        try { $l = Get-NetAdapterLso -Name $nic.Name -ErrorAction Stop; $st.LsoV4 = [bool]$l.IPv4Enabled; $st.LsoV6 = [bool]$l.IPv6Enabled } catch { }
        try { $c = Get-NetAdapterRsc -Name $nic.Name -ErrorAction Stop; $st.RscV4 = [bool]$c.IPv4Enabled; $st.RscV6 = [bool]$c.IPv6Enabled } catch { }
        [void](Add-KEntry ('nicstate|' + $guid) $st)
        if ($script:WhatIfMode) { continue }
        try { Enable-NetAdapterRss -Name $nic.Name -ErrorAction Stop } catch { }
        try { Disable-NetAdapterPowerManagement -Name $nic.Name -ErrorAction Stop } catch { }
        try { Disable-NetAdapterLso -Name $nic.Name -ErrorAction Stop } catch { }
        try { Disable-NetAdapterRsc -Name $nic.Name -ErrorAction Stop } catch { }
        foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue)) {
            if ($p.DisplayName -notmatch $wantRx) { continue }
            $off = $p.ValidDisplayValues | Where-Object { $_ -match '^(Disabled|Off|1514)$' } | Select-Object -First 1
            if (-not $off) { continue }
            [void](Add-KEntry ('nicprop|' + $guid + '|' + $p.RegistryKeyword) @{ Type = 'nicprop'; Guid = $guid; Keyword = $p.RegistryKeyword; Value = @([string[]]$p.RegistryValue); Label = $p.DisplayName })
            try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $p.DisplayName -DisplayValue $off -NoRestart -ErrorAction Stop } catch { }
        }
        if ($nic.PnPDeviceID -like '*PCI*') {
            $mp = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $nic.PnPDeviceID + '\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
            [void](Set-KReg $mp 'MSISupported' 1)
        }
    }
}

# ---------------- game process ----------------
function Invoke-PcGameProcess {
    # The registry part is in the tweak table. This adds the QoS policy.
    if ($script:WhatIfMode) { return }
    try {
        [void](Add-KEntry ('qos|' + $script:QosName) @{ Type = 'qos'; Name = $script:QosName })
        Remove-NetQosPolicy -Name $script:QosName -Confirm:$false -ErrorAction SilentlyContinue
        New-NetQosPolicy -Name $script:QosName -AppPathNameMatchCondition 'cod.exe' -DSCPAction 46 -IPProtocolMatchCondition Both -ErrorAction Stop | Out-Null
    } catch { Write-KLog ('QoS policy failed: ' + $_.Exception.Message) 'WARN' }
}

# ---------------- Xbox / Game Bar ----------------
function Get-XboxPatterns { return @('*Microsoft.XboxGamingOverlay*', '*Microsoft.XboxSpeechToTextOverlay*', '*Microsoft.XboxGameCallableUI*') }

function Invoke-PcXbox {
    if (-not (Get-PcCpuPolicy).RemoveGameBar) {
        Write-Say ('  kept (' + (Get-PcCpuPolicy).Reason + ')') 'DarkGray'
        return
    }
    foreach ($pat in (Get-XboxPatterns)) {
        foreach ($pkg in @(Get-AppxPackage -AllUsers $pat -ErrorAction SilentlyContinue)) {
            [void](Add-KEntry ('appx|' + $pkg.Name) @{ Type = 'appx'; Name = $pkg.Name; Label = ('Reinstall "' + $pkg.Name + '" from the Microsoft Store (Windows cannot restore a removed app by itself)') })
            if (-not $script:WhatIfMode) { try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue } catch { } }
        }
        foreach ($prov in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $pat })) {
            [void](Add-KEntry ('appx|' + $prov.DisplayName) @{ Type = 'appx'; Name = $prov.DisplayName; Label = ('Reinstall "' + $prov.DisplayName + '" from the Microsoft Store (Windows cannot restore a removed app by itself)') })
            if (-not $script:WhatIfMode) { try { Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction SilentlyContinue | Out-Null } catch { } }
        }
    }
}

# ---------------- services ----------------
function Get-PcServices {
    $s = @('SysMain', 'DiagTrack', 'WSearch', 'TabletInputService', 'MapsBroker', 'RetailDemo', 'Fax', 'RemoteRegistry')
    if (Test-HasNvidia) { $s += 'NvTelemetryContainer' }
    return $s
}

# ---------------- disk / hibernate ----------------
function Get-FsutilValue {
    param([string]$Name)
    try {
        $out = (& fsutil.exe behavior query $Name 2>&1 | Out-String)
        $m = [regex]::Match($out, '=\s*(\d+)')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    return $null
}

function Invoke-PcDisk {
    foreach ($pair in @(@('disablelastaccess', '1'), @('DisableDeleteNotify', '0'))) {
        $old = Get-FsutilValue $pair[0]
        if ($null -eq $old) { continue }
        [void](Add-KEntry ('fsutil|' + $pair[0]) @{ Type = 'fsutil'; Name = $pair[0]; Value = $old })
        if (-not $script:WhatIfMode) { & fsutil.exe behavior set $pair[0] $pair[1] | Out-Null }
    }
    $hs = Get-RegRaw $script:PowerKey 'HibernateEnabled'
    $hv = $null
    if ($hs.Existed) { $hv = [int]$hs.Raw }
    [void](Add-KEntry 'hibernate' @{ Type = 'hibernate'; Existed = $hs.Existed; Value = $hv; Enabled = ($hs.Existed -and $hv -eq 1) })
    if (-not $script:WhatIfMode) { & powercfg.exe /hibernate off | Out-Null }
}

# ---------------- Defender ----------------
function Get-PcDefenderWanted {
    $paths = New-Object System.Collections.Generic.List[string]
    $procs = New-Object System.Collections.Generic.List[string]
    foreach ($r in (Get-CodInstallRoots)) { [void]$paths.Add($r) }
    foreach ($r in (Get-BattleNetRoots)) {
        [void]$paths.Add($r)
        $bn = Join-Path $r 'Battle.net.exe'
        if (Test-Path -LiteralPath $bn) { [void]$procs.Add($bn) }
        Get-ChildItem -LiteralPath $r -Filter 'Battle.net.exe' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue | ForEach-Object { [void]$procs.Add($_.FullName) }
    }
    foreach ($p in @("$env:ProgramData\Battle.net", "$env:LOCALAPPDATA\Battle.net")) { if (Test-Path -LiteralPath $p) { [void]$paths.Add($p) } }
    foreach ($p in (Get-CodExePaths)) { [void]$procs.Add($p) }
    $ds4 = ''
    if (Get-Command Find-DS4Windows -ErrorAction SilentlyContinue) { $ds4 = Find-DS4Windows }
    if ($ds4 -and (Test-Path -LiteralPath $ds4)) { [void]$procs.Add($ds4); [void]$paths.Add((Split-Path $ds4 -Parent)) }
    # An exclusion tells Defender to never look there again, and the logon task re-adds it with admin rights.
    # So only places a normal account cannot write to are accepted (lib\Safety.ps1). Everything else is
    # reported as skipped -- that includes %LOCALAPPDATA%, Downloads, and Steam libraries whose folder users can write.
    $okPaths = New-Object System.Collections.Generic.List[string]
    $okProcs = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($paths | Select-Object -Unique)) {
        $s = Test-KPathSafeForElevation $p
        if ($s.Safe) { [void]$okPaths.Add($p) } else { [void]$skipped.Add($p + ' (' + $s.Reason + ')') }
    }
    foreach ($p in @($procs | Select-Object -Unique)) {
        $s = Test-KPathSafeForElevation $p
        if ($s.Safe) { [void]$okProcs.Add($p) } else { [void]$skipped.Add($p + ' (' + $s.Reason + ')') }
    }
    return [pscustomobject]@{ Paths = @($okPaths); Procs = @($okProcs); Skipped = @($skipped) }
}

function Invoke-PcDefender {
    if ($script:WhatIfMode) { return $true }
    try {
        $mp = Get-MpPreference -ErrorAction Stop
        $havePath = @($mp.ExclusionPath)
        $haveProc = @($mp.ExclusionProcess)
        $w = Get-PcDefenderWanted
        foreach ($sk in $w.Skipped) { Write-Say ('  not excluded (a normal account can change it): ' + $sk) 'DarkGray' }
        foreach ($p in $w.Paths) {
            if ($havePath -contains $p) { continue }
            [void](Add-KEntry ('defexcl|Path|' + $p) @{ Type = 'defexcl'; Kind = 'Path'; Value = $p })
            Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue
        }
        foreach ($p in $w.Procs) {
            if ($haveProc -contains $p) { continue }
            [void](Add-KEntry ('defexcl|Process|' + $p) @{ Type = 'defexcl'; Kind = 'Process'; Value = $p })
            Add-MpPreference -ExclusionProcess $p -ErrorAction SilentlyContinue
        }
        return $true
    } catch { Write-KLog ('Defender not available: ' + $_.Exception.Message) 'WARN'; return $false }
}

# ---------------- logon re-apply ----------------
function Register-PcReapplyTask {
    if ($script:WhatIfMode) { return $true }
    try {
        $target = Join-Path $script:AppDir 'Kpekpes.ps1'
        if (-not (Test-Path -LiteralPath $target)) { return $false }
        [void](Add-KEntry ('task|' + $script:TaskReapply) @{ Type = 'task'; Name = $script:TaskReapply })
        $u = $env:USERDOMAIN + '\' + $env:USERNAME
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $target + '" -Action Optimize -Module PC -Reapply -Silent')
        $tr = New-ScheduledTaskTrigger -AtLogOn -User $u
        $tr.Delay = 'PT45S'
        $p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Highest
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        Register-ScheduledTask -TaskName $script:TaskReapply -Action $a -Trigger $tr -Principal $p -Settings $s -Force -ErrorAction Stop | Out-Null
        return $true
    } catch { Write-KLog ('reapply task failed: ' + $_.Exception.Message) 'WARN'; return $false }
}

# ======================= verify =======================
function Get-PcVerifyResults {
    param($Cfg)
    $r = New-Object System.Collections.ArrayList
    $journalPath = Join-Path (Join-Path $script:DataRoot 'pc') 'journal.json'
    if (Test-Path -LiteralPath $journalPath) { [void]$r.Add((New-KResult 'Undo information saved' 'PASS' 'journal present' 'Safety')) }
    else { [void]$r.Add((New-KResult 'Undo information saved' 'FAIL' 'no journal yet - run the PC optimizer first' 'Safety')) }

    # power plan
    $plan = ''
    $active = (& powercfg.exe /getactivescheme 2>&1 | Out-String)
    if ($active -match [regex]::Escape($script:PcPlanName)) {
        [void]$r.Add((New-KResult 'Kpekpes power plan is active' 'PASS' '' 'Power & CPU'))
        $m = [regex]::Match($active, $script:GuidRx); if ($m.Success) { $plan = $m.Value }
    } else { [void]$r.Add((New-KResult 'Kpekpes power plan is active' 'FAIL' $active.Trim() 'Power & CPU')) }
    if ($plan) {
        $chk = @(
            @('Min processor state = 100', 'SUB_PROCESSOR', 'PROCTHROTTLEMIN', 100),
            @('Max processor state = 100', 'SUB_PROCESSOR', 'PROCTHROTTLEMAX', 100),
            @('Processor boost = aggressive', 'SUB_PROCESSOR', 'PERFBOOSTMODE', 2),
            @('Energy preference = performance', 'SUB_PROCESSOR', 'PERFEPP', 0),
            @('USB selective suspend off', '2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', 0),
            @('PCIe link power management off', '501a4d13-42af-4429-9fd1-a8218c268e20', 'ee12f906-d277-404b-b6da-e5fa1a576df5', 0)
        )
        foreach ($c in $chk) {
            $v = Get-PcPowerIndex $plan $c[1] $c[2]
            if ($null -eq $v) { [void]$r.Add((New-KResult $c[0] 'NA' 'hidden on this system' 'Power & CPU')) }
            elseif ($v -eq $c[3]) { [void]$r.Add((New-KResult $c[0] 'PASS' '' 'Power & CPU')) }
            else { [void]$r.Add((New-KResult $c[0] 'FAIL' ('want ' + $c[3] + ', found ' + $v) 'Power & CPU')) }
        }
        if ((Get-PcCpuPolicy).DisableParking) {
            $v = Get-PcPowerIndex $plan 'SUB_PROCESSOR' 'CPMINCORES'
            if ($null -eq $v) { [void]$r.Add((New-KResult 'Core parking off' 'NA' 'hidden on this system' 'Power & CPU')) }
            elseif ($v -eq 100) { [void]$r.Add((New-KResult 'Core parking off' 'PASS' '' 'Power & CPU')) }
            else { [void]$r.Add((New-KResult 'Core parking off' 'FAIL' ('found ' + $v) 'Power & CPU')) }
        } else { [void]$r.Add((New-KResult 'Core parking' 'NA' ((Get-PcCpuPolicy).Reason) 'Power & CPU')) }
    }
    $hib = $null
    try { $hib = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled } catch { }
    if ($null -eq $hib) { [void]$r.Add((New-KResult 'Hibernate off' 'NA' '' 'Power & CPU')) }
    elseif ($hib -eq 0) { [void]$r.Add((New-KResult 'Hibernate off' 'PASS' '' 'Power & CPU')) }
    else { [void]$r.Add((New-KResult 'Hibernate off' 'FAIL' '' 'Power & CPU')) }

    # registry table
    foreach ($t in (Get-PcRegTweaks $Cfg)) {
        $st = Get-RegRaw $t.Path $t.Name
        $label = $t.Label
        $state = 'PASS'; $detail = ''
        if (-not $st.Existed) { $state = 'FAIL'; $detail = 'not set' }
        elseif (-not (Test-RegValueEquals $st.Raw $t.Value $t.Kind)) { $state = 'FAIL'; $detail = 'found ' + [string]$st.Raw }
        if ($state -eq 'FAIL' -and $t.BestEffort) { $state = 'WARN'; $detail = $detail + ' (Windows blocks this on some builds - harmless)' }
        if ($t.Placebo -and $state -eq 'PASS') { $detail = 'applied; no FPS gain expected' }
        [void]$r.Add((New-KResult $label $state $detail $t.Group $t.Placebo))
    }

    # services
    if ($Cfg.DisableServices) {
        foreach ($s in (Get-PcServices)) {
            $d = Test-ServiceDisabled $s
            if ($null -eq $d) { [void]$r.Add((New-KResult ('Service ' + $s + ' disabled') 'NA' 'not installed' 'Services')) }
            elseif ($d) { [void]$r.Add((New-KResult ('Service ' + $s + ' disabled') 'PASS' '' 'Services')) }
            else { [void]$r.Add((New-KResult ('Service ' + $s + ' disabled') 'FAIL' '' 'Services')) }
        }
    }

    # boot config
    $bcdWant = [ordered]@{ disabledynamictick = 'yes' }
    if ($Cfg.UsePlatformTick) { $bcdWant['useplatformtick'] = 'yes' }
    if ($Cfg.HvciOff) { $bcdWant['hypervisorlaunchtype'] = 'off' }
    foreach ($k in $bcdWant.Keys) {
        $v = Get-BcdValue $k
        if ($v -ieq $bcdWant[$k]) { [void]$r.Add((New-KResult ('Boot setting ' + $k + ' = ' + $bcdWant[$k]) 'PASS' '' 'Timer')) }
        else { [void]$r.Add((New-KResult ('Boot setting ' + $k + ' = ' + $bcdWant[$k]) 'FAIL' ('found ' + $v) 'Timer')) }
    }
    try {
        if (-not ('Native.TimerQuery' -as [type])) {
            Add-Type -Namespace Native -Name TimerQuery -MemberDefinition @'
[DllImport("ntdll.dll")]
public static extern int NtQueryTimerResolution(out uint MinimumResolution, out uint MaximumResolution, out uint CurrentResolution);
'@
        }
        [uint32]$min = 0; [uint32]$max = 0; [uint32]$cur = 0
        [void][Native.TimerQuery]::NtQueryTimerResolution([ref]$min, [ref]$max, [ref]$cur)
        if ($cur -le 5000) { [void]$r.Add((New-KResult 'Timer resolution 0.5 ms' 'PASS' ('current ' + ($cur / 10000.0) + ' ms') 'Timer')) }
        else { [void]$r.Add((New-KResult 'Timer resolution 0.5 ms' 'FAIL' ('current ' + ($cur / 10000.0) + ' ms') 'Timer')) }
    } catch { [void]$r.Add((New-KResult 'Timer resolution 0.5 ms' 'NA' 'could not query' 'Timer')) }

    # TCP
    $now = Get-NetshTcp
    $want = Get-PcNetshWant
    foreach ($k in $want.Keys) {
        if ($null -eq $now[$k]) { [void]$r.Add((New-KResult ('TCP ' + $k) 'NA' 'not readable on this Windows' 'Network')) }
        elseif ($now[$k] -eq $want[$k]) { [void]$r.Add((New-KResult ('TCP ' + $k + ' = ' + $want[$k]) 'PASS' '' 'Network' ($k -ne 'rss'))) }
        else { [void]$r.Add((New-KResult ('TCP ' + $k + ' = ' + $want[$k]) 'FAIL' ('found ' + $now[$k]) 'Network' ($k -ne 'rss'))) }
    }

    # NIC
    $nics = Get-PhysEthernet
    if ($nics.Count -eq 0) { [void]$r.Add((New-KResult 'Ethernet adapter tweaks' 'NA' 'no active wired adapter' 'Network')) }
    foreach ($nic in $nics) {
        try {
            $bad = @()
            foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue)) {
                if ($p.DisplayName -notmatch '^(Energy Efficient Ethernet|Green Ethernet|Power Saving Mode|Gigabit Lite|Advanced EEE|Interrupt Moderation|Flow Control|Jumbo Packet|Jumbo Frames)$') { continue }
                $off = $p.ValidDisplayValues | Where-Object { $_ -match '^(Disabled|Off|1514)$' } | Select-Object -First 1
                if ($off -and ([string]$p.DisplayValue -ne [string]$off)) { $bad += $p.DisplayName }
            }
            if ($bad.Count -eq 0) { [void]$r.Add((New-KResult ('Adapter power-saving off: ' + $nic.Name) 'PASS' '' 'Network')) }
            else { [void]$r.Add((New-KResult ('Adapter power-saving off: ' + $nic.Name) 'FAIL' ('still on: ' + ($bad -join ', ')) 'Network')) }
            $rss = Get-NetAdapterRss -Name $nic.Name -ErrorAction SilentlyContinue
            if ($rss) { if ($rss.Enabled) { [void]$r.Add((New-KResult ('RSS on: ' + $nic.Name) 'PASS' '' 'Network')) } else { [void]$r.Add((New-KResult ('RSS on: ' + $nic.Name) 'FAIL' '' 'Network')) } }
        } catch { [void]$r.Add((New-KResult ('Adapter tweaks: ' + $nic.Name) 'NA' 'could not read adapter' 'Network')) }
    }
    if (Get-Command Get-NetQosPolicy -ErrorAction SilentlyContinue) {
        if ($Cfg.GameProcessTweaks) {
            if (Get-NetQosPolicy -Name $script:QosName -ErrorAction SilentlyContinue) { [void]$r.Add((New-KResult 'cod.exe QoS policy (DSCP 46)' 'PASS' '' 'Game process' $true)) }
            else { [void]$r.Add((New-KResult 'cod.exe QoS policy (DSCP 46)' 'FAIL' '' 'Game process' $true)) }
        }
    }

    # fsutil
    $lu = Get-FsutilValue 'disablelastaccess'
    if ($null -eq $lu) { [void]$r.Add((New-KResult 'NTFS last-access updates off' 'NA' '' 'Disk')) }
    elseif ($lu -eq '1') { [void]$r.Add((New-KResult 'NTFS last-access updates off' 'PASS' '' 'Disk')) }
    else { [void]$r.Add((New-KResult 'NTFS last-access updates off' 'FAIL' ('found ' + $lu) 'Disk')) }
    $tr = Get-FsutilValue 'DisableDeleteNotify'
    if ($null -eq $tr) { [void]$r.Add((New-KResult 'TRIM enabled' 'NA' '' 'Disk')) }
    elseif ($tr -eq '0') { [void]$r.Add((New-KResult 'TRIM enabled' 'PASS' '' 'Disk')) }
    else { [void]$r.Add((New-KResult 'TRIM enabled' 'FAIL' ('found ' + $tr) 'Disk')) }

    # Xbox apps
    if ($Cfg.RemoveXboxApps -and -not (Get-PcCpuPolicy).RemoveGameBar) {
        [void]$r.Add((New-KResult 'Xbox / Game Bar apps' 'NA' ('kept on purpose: ' + (Get-PcCpuPolicy).Reason) 'Xbox apps'))
    } elseif ($Cfg.RemoveXboxApps) {
        foreach ($pat in (Get-XboxPatterns)) {
            $label = 'Removed: ' + ($pat -replace '\*', '')
            if (Get-AppxPackage -AllUsers $pat -ErrorAction SilentlyContinue) { [void]$r.Add((New-KResult $label 'FAIL' 'still installed' 'Xbox apps')) }
            else { [void]$r.Add((New-KResult $label 'PASS' '' 'Xbox apps')) }
        }
    }

    # Defender
    if ($Cfg.DefenderExclusions) {
        try {
            $mp = Get-MpPreference -ErrorAction Stop
            $w = Get-PcDefenderWanted
            $missing = @()
            foreach ($p in $w.Paths) { if (@($mp.ExclusionPath) -notcontains $p) { $missing += $p } }
            foreach ($p in $w.Procs) { if (@($mp.ExclusionProcess) -notcontains $p) { $missing += $p } }
            $count = $w.Paths.Count + $w.Procs.Count
            if ($count -eq 0) { [void]$r.Add((New-KResult 'Defender exclusions' 'NA' 'no game/launcher install found' 'Defender')) }
            elseif ($missing.Count -eq 0) { [void]$r.Add((New-KResult 'Defender exclusions (exact paths)' 'PASS' ([string]$count + ' entries') 'Defender')) }
            else { [void]$r.Add((New-KResult 'Defender exclusions (exact paths)' 'FAIL' ([string]$missing.Count + ' missing') 'Defender')) }
        } catch { [void]$r.Add((New-KResult 'Defender exclusions' 'NA' 'Defender not available (another antivirus?)' 'Defender')) }
    }

    # tasks
    $tt = Get-ScheduledTask -TaskName $script:TaskTimer -ErrorAction SilentlyContinue
    if ($tt) { [void]$r.Add((New-KResult 'Timer task registered' 'PASS' '' 'Persistence')) } else { [void]$r.Add((New-KResult 'Timer task registered' 'FAIL' '' 'Persistence')) }
    if ($Cfg.LogonReapply) {
        $rt = Get-ScheduledTask -TaskName $script:TaskReapply -ErrorAction SilentlyContinue
        if ($rt) { [void]$r.Add((New-KResult 'Logon re-apply task registered' 'PASS' '' 'Persistence')) } else { [void]$r.Add((New-KResult 'Logon re-apply task registered' 'FAIL' '' 'Persistence')) }
    }

    # last restore point (information)
    try {
        $rp = Get-ComputerRestorePoint -ErrorAction Stop | Where-Object { $_.Description -like 'Before Kpekpes COD Custom*' } | Select-Object -Last 1
        if ($rp) { [void]$r.Add((New-KResult 'Restore point' 'INFO' $rp.Description 'Safety')) }
    } catch { }

    # NVIDIA per-app power mode: set by hand on purpose
    if (Test-HasNvidia) {
        [void]$r.Add((New-KResult 'NVIDIA power mode for cod.exe' 'INFO' 'manual: NVIDIA Control Panel > Manage 3D settings > Program Settings > cod.exe > Power management mode = Prefer maximum performance' 'NVIDIA'))
    }
    return @($r)
}

# ======================= apply / undo =======================
function Invoke-PcOptimize {
    param($Cfg, [switch]$Reapply)
    $script:PcStepNo = 0
    $script:CodPathsCache = $null   # look for the game again on every run
    $summary = [pscustomobject]@{ RestorePoint = ''; Before = $null; After = $null; Problems = @() }
    $problems = New-Object System.Collections.ArrayList

    if ($Reapply) { $script:PcSteps = 12 } else { $script:PcSteps = 15 }

    if (-not $Reapply) {
        Write-PcStep 'Score before'
        $beforeResults = Get-PcVerifyResults $Cfg
        $summary.Before = Get-KScore $beforeResults
        Write-Say ('  before: {0}%' -f $summary.Before.Percent) 'Yellow'
    }

    Write-PcStep 'Safety net: undo journal + restore point'
    if (-not (Initialize-KRoot)) { throw 'Cannot create the data folder - nothing was changed.' }
    Open-KJournal 'pc'
    if (-not $script:WhatIfMode -and $null -eq $script:J) { throw 'Cannot open the undo journal - nothing was changed.' }
    if (-not $Reapply) {
        $rp = Invoke-RestorePointSafe
        if ($rp.Ok) { Write-Say ('  restore point created: ' + $rp.Detail) 'Green' }
        else { Write-Say ('  restore point could not be created (' + $rp.Detail + '). The undo journal is still active.') 'Yellow'; [void]$problems.Add('restore point: ' + $rp.Detail) }
        $summary.RestorePoint = $rp.Detail
    }

    Write-PcStep 'Power plan (Kpekpes COD Custom Max)'
    try { if (-not (Invoke-PcPower)) { [void]$problems.Add('power plan') } } catch { [void]$problems.Add('power plan: ' + $_.Exception.Message) }

    Write-PcStep 'Registry tweaks (graphics, Game Mode off, scheduling, input, network, privacy)'
    try { $f = Invoke-PcRegTweaks $Cfg -Reapply:$Reapply; if ($f -gt 0) { [void]$problems.Add([string]$f + ' registry value(s) could not be written') } } catch { [void]$problems.Add('registry: ' + $_.Exception.Message) }

    Write-PcStep 'Background services'
    if ($Cfg.DisableServices) {
        foreach ($s in (Get-PcServices)) {
            $res = Disable-KService $s
            if ($res -like 'fail*') { [void]$problems.Add('service ' + $s + ': ' + $res) }
        }
    } else { Write-Say '  skipped (config)' 'DarkGray' }

    Write-PcStep '0.5 ms timer + boot clock settings'
    try { if (-not (Invoke-PcTimer $Cfg)) { [void]$problems.Add('timer task') } } catch { [void]$problems.Add('timer: ' + $_.Exception.Message) }
    if ($Cfg.HvciOff) {
        # Memory integrity off also needs the hypervisor launch option off (journaled like every other change).
        if (-not (Set-KBcd 'hypervisorlaunchtype' 'off')) { [void]$problems.Add('hypervisorlaunchtype') }
    }

    Write-PcStep 'TCP stack'
    try { Invoke-PcTcp } catch { [void]$problems.Add('tcp: ' + $_.Exception.Message) }

    Write-PcStep 'Ethernet adapter'
    try { Invoke-PcNic } catch { [void]$problems.Add('adapter: ' + $_.Exception.Message) }

    Write-PcStep 'Game process profile'
    if ($Cfg.GameProcessTweaks) { try { Invoke-PcGameProcess } catch { [void]$problems.Add('game process: ' + $_.Exception.Message) } }
    else { Write-Say '  skipped (config)' 'DarkGray' }

    Write-PcStep 'Xbox / Game Bar apps'
    if ($Cfg.RemoveXboxApps) { try { Invoke-PcXbox } catch { [void]$problems.Add('xbox apps: ' + $_.Exception.Message) } }
    else { Write-Say '  skipped (config)' 'DarkGray' }

    Write-PcStep 'Disk + hibernate'
    try { Invoke-PcDisk } catch { [void]$problems.Add('disk: ' + $_.Exception.Message) }

    Write-PcStep 'Defender exclusions (exact paths)'
    if ($Cfg.DefenderExclusions) { if (-not (Invoke-PcDefender)) { [void]$problems.Add('Defender not available') } }
    else { Write-Say '  skipped (config)' 'DarkGray' }

    if (-not $Reapply) {
        Write-PcStep 'Logon re-apply'
        if ($Cfg.LogonReapply) { if (-not (Register-PcReapplyTask)) { [void]$problems.Add('logon re-apply task') } }
        else { Write-Say '  skipped (config)' 'DarkGray' }

        Write-PcStep 'NVIDIA note'
        if (Test-HasNvidia) {
            Write-Say '  Set by hand once (a script cannot read back or undo per-app driver profiles safely):' 'Gray'
            Write-Say '  NVIDIA Control Panel > Manage 3D settings > Program Settings > add cod.exe > Power management mode = Prefer maximum performance.' 'Gray'
        } else { Write-Say '  no NVIDIA GPU found' 'DarkGray' }

        Write-PcStep 'Score after'
        $afterResults = Get-PcVerifyResults $Cfg
        $summary.After = Get-KScore $afterResults
        [void](Show-KResults $afterResults 'PC optimizer - result' )
        if ($summary.Before) { Write-Say ('  score: {0}% -> {1}%' -f $summary.Before.Percent, $summary.After.Percent) 'Yellow' }
    }
    $summary.Problems = @($problems)
    return $summary
}

function Invoke-PcUndo {
    param([string]$Group = '')
    if ($Group) { Write-Head ('Undo PC optimizer - only the group "' + $Group + '"') } else { Write-Head 'Undo PC optimizer' }
    $res = Invoke-KRevert 'pc' -Group $Group
    if ($res.Total -eq 0) { return $res }
    Write-Say ('  restored {0} of {1} recorded changes' -f $res.Restored, $res.Total) 'Green'
    if ($res.Drift.Count -gt 0) {
        Write-Say '  changed by you or Windows after the optimizer ran (your original value was put back anyway):' 'Yellow'
        foreach ($d in $res.Drift) { Write-Say ('    ' + $d) 'Yellow' }
    }
    if ($res.Failed.Count -gt 0) {
        Write-Say '  could not restore (journal kept so you can run Undo again):' 'Red'
        foreach ($f in $res.Failed) { Write-Say ('    ' + $f) 'Red' }
    }
    if ($res.Manual.Count -gt 0) {
        Write-Say '  one-time manual step:' 'Yellow'
        foreach ($m in $res.Manual) { Write-Say ('    ' + $m) 'Yellow' }
        if (@($res.Manual | Where-Object { $_ -match 'Xbox' }).Count -gt 0) {
            try { Start-Process 'ms-windows-store://search/?query=Xbox%20Game%20Bar' } catch { }
        }
    }
    Write-Say '  Restart Windows to finish.' 'Yellow'
    return $res
}

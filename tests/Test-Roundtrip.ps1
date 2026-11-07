# Test-Roundtrip.ps1 -- real-Windows round trip: snapshot -> Optimize PC -> Undo PC -> snapshot -> compare.
#
# Two scenarios:
#   Safe : Defender exclusions, logon re-apply and Xbox removal OFF (what the first CI run used), new safe defaults.
#   Full : Defender exclusions, logon re-apply, Xbox removal, HvciOff, toast, platform tick ON, plus a dummy
#          Battle.net / Call of Duty folder so the game, Defender and QoS paths really run.
#
# THIS CHANGES THE MACHINE. It refuses to run unless it is on GitHub Actions (GITHUB_ACTIONS=true) or -Force is given.
# Windows PowerShell 5.1 compatible.
#
# What counts as equal: strictly equal text, EXCEPT these documented equivalents (listed in the output, never hidden):
#   1. Service DelayedAutostart: a missing value and 0 both mean "not delayed" in Windows.
#   2. Defender exclusion lists are compared as sorted sets (Windows does not promise an order).
# Everything else (hibernate, registry, BCD, adapters ...) must match exactly, missing is NOT treated as 0.
# Xbox / Game Bar apps cannot be reinstalled by a script; if present they are reported as "by design", not as a failure.

param(
    [ValidateSet('Safe', 'Full', 'Both')][string]$Scenario = 'Both',
    [switch]$Force,
    [int]$StepTimeoutSec = 150,
    [int]$Seeds = 0   # extra "Safe" runs, each starting from a different RANDOM pre-existing state (property test)
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
if (($env:GITHUB_ACTIONS -ne 'true') -and -not $Force) {
    Write-Host 'Refusing to run: this test changes system settings. It is meant for GitHub Actions. Use -Force only on a throw-away machine.' -ForegroundColor Red
    exit 2
}

. (Join-Path $repo 'lib\Core.ps1')
. (Join-Path $repo 'lib\Journal.ps1')
. (Join-Path $repo 'lib\Checks.ps1')
. (Join-Path $repo 'lib\Stats.ps1')
. (Join-Path $repo 'lib\Safety.ps1')
. (Join-Path $repo 'lib\Topology.ps1')
. (Join-Path $repo 'modules\Pc.ps1')
. (Join-Path $repo 'modules\Controller.ps1')
$script:WhatIfMode = $false
$script:Quiet = $true

$script:Failures = 0
function Add-Fail { param([string]$Msg) $script:Failures++; Write-Host ('FAIL  ' + $Msg) -ForegroundColor Red }
function Add-Ok { param([string]$Msg) Write-Host ('ok    ' + $Msg) -ForegroundColor Green }
function Add-Info { param([string]$Msg) Write-Host ('info  ' + $Msg) -ForegroundColor Cyan }

# ---------------------------------------------------------------- snapshot
function Get-Snapshot {
    param($Cfg)
    $s = [ordered]@{}

    # registry values (the whole tweak table) + the keys that may be created
    foreach ($t in (Get-PcRegTweaks $Cfg)) {
        $r = Get-RegRaw $t.Path $t.Name
        $v = ''
        if ($r.Existed) { $v = [string]$r.Kind + ':' + [string](ConvertTo-JsonSafe $r.Raw $r.Kind) }
        $s['reg|' + $t.Path + '|' + $t.Name] = [string]$r.Existed + '|' + $v
        $s['key|' + $t.Path] = [string](Test-Path -LiteralPath $t.Path)
    }
    $extraReg = @(
        @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore', 'SystemRestorePointCreationFrequency'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore', 'DisableSR'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore', 'DisableConfig'),
        @('HKCU:\Control Panel\Mouse', 'MouseSensitivity'),
        @($script:PowerKey, 'HibernateEnabled')
    )
    foreach ($x in $extraReg) {
        $r = Get-RegRaw $x[0] $x[1]
        $v = ''
        if ($r.Existed) { $v = [string]$r.Kind + ':' + [string](ConvertTo-JsonSafe $r.Raw $r.Kind) }
        $s['reg|' + $x[0] + '|' + $x[1]] = [string]$r.Existed + '|' + $v
    }

    # services: Existed|Start|DelayedAutostart
    foreach ($n in (@(Get-PcServices) + @('VSS', 'swprv'))) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc) { $s['svc|' + $n] = 'False||'; continue }
        $st = $null
        try { $st = (Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $n) -Name Start -ErrorAction Stop).Start } catch { }
        $dl = Get-ServiceDelayed $n
        $s['svc|' + $n] = 'True|' + [string]$st + '|' + [string]$dl
    }

    # power
    $s['power|active'] = ((& powercfg.exe /getactivescheme 2>&1 | Out-String) -replace '\s+', ' ').Trim()
    $guids = @([regex]::Matches((& powercfg.exe /list 2>&1 | Out-String), $script:GuidRx) | ForEach-Object { $_.Value.ToLower() } | Sort-Object)
    $s['power|schemes'] = ($guids -join ',')

    # TCP, boot, fsutil
    $tcp = Get-NetshTcp
    foreach ($k in $tcp.Keys) { $s['tcp|' + $k] = [string]$tcp[$k] }
    foreach ($b in @('disabledynamictick', 'useplatformtick', 'hypervisorlaunchtype')) { $s['bcd|' + $b] = [string](Get-BcdValue $b) }
    foreach ($f in @('disablelastaccess', 'DisableDeleteNotify')) { $s['fsutil|' + $f] = [string](Get-FsutilValue $f) }

    # tasks, QoS, timer process
    foreach ($tn in @($script:TaskReapply, $script:TaskTimer)) { $s['task|' + $tn] = [string][bool](Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) }
    $s['qos|' + $script:QosName] = [string][bool](Get-NetQosPolicy -Name $script:QosName -ErrorAction SilentlyContinue)
    $tp = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -like '*TimerResolutionHold*' })
    $s['proc|timerhold'] = [string]$tp.Count

    # network adapters: status, advanced properties, offload / RSS / power state
    $nics = @()
    try { $nics = @(Get-NetAdapter -ErrorAction Stop) } catch { }
    foreach ($n in $nics) {
        $g = [string]$n.InterfaceGuid
        $s['nic|' + $g + '|status'] = [string]$n.Status
        try {
            foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $n.Name -ErrorAction Stop)) {
                $s['nicprop|' + $g + '|' + $p.RegistryKeyword] = (@($p.RegistryValue) -join ',')
            }
        } catch { $s['nicprop|' + $g + '|(unreadable)'] = 'n/a' }
        try { $s['nicstate|' + $g + '|rss'] = [string](Get-NetAdapterRss -Name $n.Name -ErrorAction Stop).Enabled } catch { $s['nicstate|' + $g + '|rss'] = 'n/a' }
        try { $l = Get-NetAdapterLso -Name $n.Name -ErrorAction Stop; $s['nicstate|' + $g + '|lso'] = [string]$l.IPv4Enabled + '/' + [string]$l.IPv6Enabled } catch { $s['nicstate|' + $g + '|lso'] = 'n/a' }
        try { $c = Get-NetAdapterRsc -Name $n.Name -ErrorAction Stop; $s['nicstate|' + $g + '|rsc'] = [string]$c.IPv4Enabled + '/' + [string]$c.IPv6Enabled } catch { $s['nicstate|' + $g + '|rsc'] = 'n/a' }
        try { $pm = Get-NetAdapterPowerManagement -Name $n.Name -ErrorAction Stop; $s['nicstate|' + $g + '|power'] = [string]$pm.AllowComputerToTurnOffDevice } catch { $s['nicstate|' + $g + '|power'] = 'n/a' }
    }

    # Defender exclusions (sorted sets)
    try {
        $mp = Get-MpPreference -ErrorAction Stop
        $s['defender|paths'] = (@($mp.ExclusionPath | Where-Object { $_ } | Sort-Object) -join ';')
        $s['defender|procs'] = (@($mp.ExclusionProcess | Where-Object { $_ } | Sort-Object) -join ';')
    } catch { $s['defender|paths'] = 'n/a'; $s['defender|procs'] = 'n/a' }

    # System Protection / shadow storage
    $ss = Get-KShadowStorage $env:SystemDrive
    $s['shadow|' + $env:SystemDrive] = [string]$ss.Known + '|' + [string]$ss.Had + '|' + [string]$ss.Percent + '|' + [string]$ss.Unbounded

    # Xbox apps (a removed app cannot be put back by a script)
    $ap = @()
    foreach ($pat in (Get-XboxPatterns)) { foreach ($pkg in @(Get-AppxPackage -AllUsers $pat -ErrorAction SilentlyContinue)) { $ap += $pkg.Name } }
    $s['appx|xbox'] = (@($ap | Sort-Object -Unique) -join ',')
    return $s
}

function Compare-Snapshots {
    # Returns @{ Fails; Equivalents; ByDesign } lists of text lines.
    param($A, $B)
    $fails = New-Object System.Collections.ArrayList
    $equiv = New-Object System.Collections.ArrayList
    $design = New-Object System.Collections.ArrayList
    $keys = @($A.Keys) + @($B.Keys) | Select-Object -Unique
    foreach ($k in $keys) {
        $x = ''; $y = ''
        if ($A.Contains($k)) { $x = [string]$A[$k] } else { $x = '(not in snapshot)' }
        if ($B.Contains($k)) { $y = [string]$B[$k] } else { $y = '(not in snapshot)' }
        if ($x -eq $y) { continue }
        if ($k -like 'appx|*') { [void]$design.Add($k + '  before=' + $x + '  after=' + $y); continue }
        if ($k -like 'svc|*') {
            $px = $x -split '\|'; $py = $y -split '\|'
            if ($px.Count -eq 3 -and $py.Count -eq 3 -and $px[0] -eq $py[0] -and $px[1] -eq $py[1]) {
                $dx = $px[2]; $dy = $py[2]
                if ($dx -eq '') { $dx = '0' }
                if ($dy -eq '') { $dy = '0' }
                if ($dx -eq $dy) { [void]$equiv.Add($k + '  before=' + $x + '  after=' + $y + '  (missing DelayedAutostart = 0)'); continue }
            }
        }
        [void]$fails.Add($k + '  before=' + $x + '  after=' + $y)
    }
    return @{ Fails = @($fails); Equivalents = @($equiv); ByDesign = @($design) }
}

function Get-DiffCount {
    param($A, $B)
    $n = 0
    foreach ($k in @($A.Keys)) { if ($B.Contains($k) -and ([string]$A[$k] -ne [string]$B[$k])) { $n++ } }
    return $n
}

# ---------------------------------------------------------------- running the tool
$script:PsExe = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
if (-not (Test-Path -LiteralPath $script:PsExe)) { $script:PsExe = (Get-Process -Id $PID).Path }

function Invoke-Kpekpes {
    # Runs Kpekpes.ps1 in a child process with a hard time limit. Returns @{ Output; ExitCode; TimedOut }.
    param([string[]]$ScriptArgs)
    $out = Join-Path ([IO.Path]::GetTempPath()) ('kpk-' + [guid]::NewGuid().ToString('N') + '.txt')
    $err = $out + '.err'
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $repo 'Kpekpes.ps1') + '" ' + ($ScriptArgs -join ' ')
    $p = Start-Process -FilePath $script:PsExe -ArgumentList $argLine -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
    $done = $p.WaitForExit($StepTimeoutSec * 1000)
    if (-not $done) {
        try { & taskkill.exe /PID $p.Id /T /F | Out-Null } catch { }
        $text = ''
        if (Test-Path -LiteralPath $out) { $text = Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue }
        return @{ Output = $text; ExitCode = -1; TimedOut = $true }
    }
    $text = ''
    if (Test-Path -LiteralPath $out) { $text = Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $err) { $text += (Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue) }
    return @{ Output = $text; ExitCode = $p.ExitCode; TimedOut = $false }
}

function Reset-KpekpesData {
    foreach ($tn in @($script:TaskReapply, $script:TaskTimer)) { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue }
    Stop-KProcessByCommandLine '*TimerResolutionHold*'
    if (Test-Path -LiteralPath $script:DataRoot) { Remove-Item -LiteralPath $script:DataRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

function Write-TestConfig {
    param($Map)
    New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null
    $json = $Map | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object Text.UTF8Encoding($false)))
}

function Get-JournalTypes {
    $p = Join-Path (Join-Path $script:DataRoot 'pc') 'journal.json'
    if (-not (Test-Path -LiteralPath $p)) { return @{} }
    $o = (Get-Content -LiteralPath $p -Raw -Encoding UTF8) | ConvertFrom-Json
    $h = @{}
    foreach ($e in @($o.Entries)) { $t = [string]$e.Type; if ($h.ContainsKey($t)) { $h[$t]++ } else { $h[$t] = 1 } }
    return $h
}

# ---------------------------------------------------------------- one scenario
function Set-RandomInitialState {
    # The property under test: for ANY starting state S, Undo(Optimize(S)) == S.
    # A clean runner only ever starts from one S (mostly "value absent"), so this seeds each target with one of:
    #   absent | present with the tool's own type and a different value | present with a DIFFERENT type.
    # HKLM targets only get absent / 0 / 1 so the runner stays usable; HKCU targets get the full range.
    param($Cfg, [int]$Seed)
    $rng = New-Object System.Random $Seed
    $n = 0
    foreach ($t in (Get-PcRegTweaks $Cfg)) {
        if ($t.BestEffort) { continue }
        $hkcu = $t.Path -like 'HKCU:*'
        $pick = $rng.Next(3)
        try {
            if ($pick -eq 0) {
                if (Test-Path -LiteralPath $t.Path) { Remove-ItemProperty -LiteralPath $t.Path -Name $t.Name -ErrorAction SilentlyContinue }
            } else {
                if (-not (Test-Path -LiteralPath $t.Path)) { New-Item -Path $t.Path -Force | Out-Null }
                if ($pick -eq 1 -or -not $hkcu) {
                    if ($t.Kind -eq 'DWord') { $v = $rng.Next(2); if ($hkcu) { $v = $rng.Next(1000) } ; New-ItemProperty -LiteralPath $t.Path -Name $t.Name -PropertyType DWord -Value $v -Force | Out-Null }
                    elseif ($t.Kind -eq 'String') { New-ItemProperty -LiteralPath $t.Path -Name $t.Name -PropertyType String -Value ('kpk' + $rng.Next(1000)) -Force | Out-Null }
                    elseif ($t.Kind -eq 'Binary') { $b = New-Object byte[] 8; $rng.NextBytes($b); New-ItemProperty -LiteralPath $t.Path -Name $t.Name -PropertyType Binary -Value $b -Force | Out-Null }
                } else {
                    # type mismatch: a DWORD target holding a string and vice versa
                    if ($t.Kind -eq 'DWord') { New-ItemProperty -LiteralPath $t.Path -Name $t.Name -PropertyType String -Value ('kpk' + $rng.Next(1000)) -Force | Out-Null }
                    else { New-ItemProperty -LiteralPath $t.Path -Name $t.Name -PropertyType DWord -Value $rng.Next(1000) -Force | Out-Null }
                }
            }
            $n++
        } catch { }
    }
    Add-Info ('seed ' + $Seed + ': randomized ' + $n + ' starting values')
}

function Invoke-Scenario {
    param([string]$Name, [int]$Seed = 0)
    Write-Host ''
    Write-Host ('=================== scenario: ' + $Name + ' ===================') -ForegroundColor White
    Reset-KpekpesData
    $dummyDirs = @()
    $cfgMap = $null
    $snapCfg = $null
    if ($Name -eq 'Safe') {
        $cfgMap = [ordered]@{ HvciOff = $false; RemoveXboxApps = $false; DefenderExclusions = $false; LogonReapply = $false }
    } else {
        $cfgMap = [ordered]@{ HvciOff = $true; RemoveXboxApps = $true; DefenderExclusions = $true; LogonReapply = $true; DisableToastNotifications = $true; UsePlatformTick = $true; ReapplyUserPreferences = $false; GameModeOff = $true }
        # dummy game + Battle.net so the game-process, QoS and Defender code paths really run
        $cod = 'C:\Program Files (x86)\Call of Duty'
        $bn = 'C:\Program Files (x86)\Battle.net'
        foreach ($d in @($cod, $bn)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null; $dummyDirs += $d } }
        foreach ($f in @((Join-Path $cod 'cod.exe'), (Join-Path $bn 'Battle.net.exe'))) { if (-not (Test-Path -LiteralPath $f)) { [IO.File]::WriteAllBytes($f, [byte[]]@(0x4D, 0x5A)) } }
    }
    Write-TestConfig $cfgMap
    $script:CodPathsCache = $null
    $cfg = Get-KConfig
    # snapshot covers the union of every optional tweak so nothing is missed
    $snapCfg = Get-KDefaultConfig
    foreach ($k in @('HvciOff', 'DisableToastNotifications', 'UsePlatformTick', 'ReapplyUserPreferences', 'GameModeOff')) { $snapCfg[$k] = $true }
    if ($Seed -gt 0) { Set-RandomInitialState $snapCfg $Seed }

    $before = Get-Snapshot $snapCfg
    Write-Host ('=== snapshot before: ' + $before.Count + ' items') -ForegroundColor Gray

    Write-Host '=== APPLY (Optimize PC) ===' -ForegroundColor White
    $a = Invoke-Kpekpes @('-Action', 'Optimize', '-Module', 'PC', '-Silent')
    if ($a.TimedOut) { Add-Fail ('Optimize timed out after ' + $StepTimeoutSec + ' s') } elseif ($a.ExitCode -ne 0) { Add-Info ('Optimize exit code ' + $a.ExitCode) }
    $a.Output -split "`r?`n" | Where-Object { $_ -match 'SCORE|score:|\[NA\]|could not|did not apply|^\s+- ' } | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor Gray }
    $mid = Get-Snapshot $snapCfg
    $changed = Get-DiffCount $before $mid
    Write-Host ('  apply changed ' + $changed + ' items') -ForegroundColor Gray
    if ($changed -lt 20) { Add-Fail ('Optimize changed only ' + $changed + ' items - it probably did not run') }

    $types = Get-JournalTypes
    $histo = @($types.Keys | Sort-Object | ForEach-Object { $_ + '=' + $types[$_] }) -join '  '
    Write-Host ('  journal entries by type: ' + $histo) -ForegroundColor Gray
    $entryCount = 0; foreach ($k in $types.Keys) { $entryCount += $types[$k] }

    if ($Name -eq 'Full') {
        # logon re-apply must leave the user's own mouse choice alone (ReapplyUserPreferences = false) and must not change the first-recorded originals
        Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Mouse' -Name MouseSensitivity -Value '7' -ErrorAction SilentlyContinue
        $ra = Invoke-Kpekpes @('-Action', 'Optimize', '-Module', 'PC', '-Reapply', '-Silent')
        if ($ra.TimedOut) { Add-Fail 'Re-apply timed out' }
        $ms = (Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Mouse' -Name MouseSensitivity -ErrorAction SilentlyContinue).MouseSensitivity
        if ($ms -eq '7') { Add-Ok 're-apply left the mouse sensitivity (your own choice) alone' } else { Add-Fail ('re-apply reset MouseSensitivity to ' + $ms) }
        $types2 = Get-JournalTypes
        $n2 = 0; foreach ($k in $types2.Keys) { $n2 += $types2[$k] }
        Add-Info ('journal after re-apply: ' + $n2 + ' entries (was ' + $entryCount + ')')
        $entryCount = $n2
    }

    Write-Host '=== UNDO (Undo PC) ===' -ForegroundColor White
    $u = Invoke-Kpekpes @('-Action', 'Undo', '-Module', 'PC', '-Silent')
    if ($u.TimedOut) { Add-Fail ('Undo timed out after ' + $StepTimeoutSec + ' s') }
    $u.Output -split "`r?`n" | Where-Object { $_ -match 'restored|could not restore|note:|manual|Kept|^\s{4}\S' } | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor Gray }
    $m = [regex]::Matches($u.Output, 'restored (\d+) of (\d+) recorded changes')
    if ($m.Count -gt 0) {
        $last = $m[$m.Count - 1]
        if ($last.Groups[1].Value -eq $last.Groups[2].Value) { Add-Ok ('undo restored ' + $last.Groups[1].Value + ' of ' + $last.Groups[2].Value) }
        else { Add-Fail ('undo restored only ' + $last.Groups[1].Value + ' of ' + $last.Groups[2].Value) }
    } else { Add-Fail 'undo did not report how many changes it restored' }

    $after = Get-Snapshot $snapCfg
    Write-Host ('=== snapshot after: ' + $after.Count + ' items') -ForegroundColor Gray

    # coverage report: which paths really ran
    Write-Host '=== coverage (what this run really exercised) ===' -ForegroundColor White
    foreach ($t in @('reg', 'key', 'service', 'bcd', 'netsh', 'powerscheme', 'hibernate', 'fsutil', 'nicprop', 'nicstate', 'defexcl', 'qos', 'task', 'proc', 'file', 'sysprot', 'appx')) {
        if ($types.ContainsKey($t)) { Add-Info ($t + ': ' + $types[$t] + ' journal entries exercised') } else { Add-Info ($t + ': NOT exercised in this run') }
    }
    if ($Name -eq 'Full') {
        if ($mid['defender|paths'] -ne $before['defender|paths'] -or $mid['defender|procs'] -ne $before['defender|procs']) { Add-Ok 'Defender exclusions were added, then compared after undo' }
        else { Add-Info 'Defender exclusions: nothing was added (Defender unavailable or tamper-protected) - NOT proven' }
        if ($mid['task|' + $script:TaskReapply] -eq 'True') { Add-Ok 'logon re-apply task was created, then compared after undo' } else { Add-Info 'logon re-apply task was NOT created - NOT proven' }
        if ($before['appx|xbox'] -eq '') { Add-Info 'Xbox removal: no Xbox apps on this machine, nothing to remove - NOT proven' }
    }

    $cmp = Compare-Snapshots $before $after
    if ($cmp.Equivalents.Count -gt 0) { Write-Host 'treated as equivalent (documented):' -ForegroundColor Yellow; $cmp.Equivalents | ForEach-Object { Write-Host ('  EQUIV ' + $_) -ForegroundColor Yellow } }
    if ($cmp.ByDesign.Count -gt 0) { Write-Host 'by design (a removed app cannot be reinstalled by a script):' -ForegroundColor Yellow; $cmp.ByDesign | ForEach-Object { Write-Host ('  DESIGN ' + $_) -ForegroundColor Yellow } }
    foreach ($f in $cmp.Fails) { Add-Fail $f }
    if ($cmp.Fails.Count -eq 0) { Add-Ok ('scenario ' + $Name + ': all ' + $before.Count + ' snapshot items match the original after undo') }

    foreach ($d in $dummyDirs) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    if ($Name -eq 'Full') { foreach ($f in @('C:\Program Files (x86)\Call of Duty\cod.exe', 'C:\Program Files (x86)\Battle.net\Battle.net.exe')) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
    Reset-KpekpesData
}

if ($Scenario -eq 'Safe' -or $Scenario -eq 'Both') { Invoke-Scenario 'Safe' }
if ($Scenario -eq 'Full' -or $Scenario -eq 'Both') { Invoke-Scenario 'Full' }
for ($s = 1; $s -le $Seeds; $s++) { Invoke-Scenario 'Safe' -Seed $s }

Write-Host ''
if ($script:Failures -eq 0) { Write-Host 'RESULT: 0 failed' -ForegroundColor Green; exit 0 }
Write-Host ('RESULT: ' + $script:Failures + ' failed') -ForegroundColor Red
exit 1

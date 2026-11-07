# Journal.ps1 -- the change journal.
#
# Rule: nothing is changed until its ORIGINAL state has been written to the journal on disk.
# If a value did not exist, that is recorded too, so Undo deletes it instead of leaving it behind.
# The first recorded state of anything is kept forever (later runs never overwrite it), so running
# the optimizer twice, or letting the logon task re-apply it, can never turn the tweaked state into
# the "original".

$script:KGroup = $null                                   # current change group (tags new entries)
$script:KDrift = New-Object System.Collections.ArrayList  # values changed by someone else since we wrote them

function Open-KJournal {
    param([string]$Module)
    $dir  = Join-Path $script:DataRoot $Module
    $path = Join-Path $dir 'journal.json'
    $entries = New-Object System.Collections.ArrayList
    $index = @{}
    if (-not $script:WhatIfMode) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    if (Test-Path -LiteralPath $path) {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ($raw) {
            $obj = $null
            try { $obj = $raw | ConvertFrom-Json }
            catch {
                # Never start a fresh journal over a damaged one: that would lose the original values.
                throw ('The undo journal ' + $path + ' is damaged and was left untouched. Your System Restore point is the fallback. (' + $_.Exception.Message + ')')
            }
            foreach ($e in @($obj.Entries)) {
                [void]$entries.Add($e)
                $index[[string]$e.Id] = $true
            }
        }
    }
    $script:J = @{ Module = $Module; Dir = $dir; Path = $path; Entries = $entries; Index = $index }
}

function Save-KJournal {
    if ($script:WhatIfMode -or $null -eq $script:J) { return }
    $o = [ordered]@{
        Version = 1
        Module  = $script:J.Module
        Updated = (Get-Date).ToString('s')
        Entries = @($script:J.Entries)
    }
    $json = $o | ConvertTo-Json -Depth 8
    $tmp = $script:J.Path + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $script:J.Path -Force
}

function Add-KEntry {
    # Returns $true if a new entry was recorded, $false if this Id was already journaled (original kept).
    param([string]$Id, [hashtable]$Data)
    if ($script:WhatIfMode -or $null -eq $script:J) { return $false }
    if ($script:J.Index.ContainsKey($Id)) { return $false }
    $e = [ordered]@{ Id = $Id; Time = (Get-Date).ToString('s') }
    # Group tag (set by the caller around a block of changes) lets one group be undone on its own, which is
    # what a per-group A/B test needs. Entries written without a group are only undone by a full Undo.
    if ($script:KGroup -and -not $Data.ContainsKey('Group')) { $e['Group'] = [string]$script:KGroup }
    foreach ($k in $Data.Keys) { $e[$k] = $Data[$k] }
    [void]$script:J.Entries.Add([pscustomobject]$e)
    $script:J.Index[$Id] = $true
    Save-KJournal
    return $true
}

function Update-KEntry {
    param([string]$Id, [string]$Prop, $Value)
    if ($script:WhatIfMode -or $null -eq $script:J) { return }
    foreach ($e in $script:J.Entries) {
        if ([string]$e.Id -eq $Id) {
            if ($e.PSObject.Properties[$Prop]) { $e.$Prop = $Value } else { $e | Add-Member -NotePropertyName $Prop -NotePropertyValue $Value }
        }
    }
    Save-KJournal
}

function Get-KEntry {
    param([string]$Id)
    if ($null -eq $script:J) { return $null }
    foreach ($e in $script:J.Entries) { if ([string]$e.Id -eq $Id) { return $e } }
    return $null
}

# ======================= registry =======================

function Get-RegRaw {
    param([string]$Path, [string]$Name)
    $r = [pscustomobject]@{ Existed = $false; Kind = $null; Raw = $null }
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if (@($item.GetValueNames()) -contains $Name) {
            $r.Existed = $true
            $r.Kind = $item.GetValueKind($Name).ToString()
            $r.Raw = $item.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    } catch { }
    return $r
}

function ConvertTo-RegInt {
    # DWord values are Int32 in .NET. Accepts 0xFFFFFFFF style values.
    param($Value)
    $l = [int64]$Value
    if ($l -gt [int]::MaxValue) { $l = $l - 4294967296 }
    return [int]$l
}

function ConvertTo-JsonSafe {
    param($Raw, [string]$Kind)
    if ($null -eq $Raw) { return $null }
    if ($Kind -eq 'Binary') { return [BitConverter]::ToString([byte[]]$Raw) }
    if ($Kind -eq 'MultiString') { return @([string[]]$Raw) }
    return $Raw
}

function Test-RegValueEquals {
    param($Actual, $Expected, [string]$Kind)
    if ($null -eq $Actual) { return $false }
    # A value of the wrong type (for example text where a number is expected) simply does not match; it must never stop the run.
    try {
        if ($Kind -eq 'DWord') { return ((ConvertTo-RegInt $Actual) -eq (ConvertTo-RegInt $Expected)) }
        if ($Kind -eq 'QWord') { return ([int64]$Actual -eq [int64]$Expected) }
        if ($Kind -eq 'Binary') { return (([BitConverter]::ToString([byte[]]$Actual)) -eq ([BitConverter]::ToString([byte[]]$Expected))) }
        return (([string]$Actual) -ieq ([string]$Expected))
    } catch { return $false }
}

function Register-NewKeys {
    # Remember every registry key we are about to create, so Undo can remove the ones that were not there before.
    param([string]$Path)
    if ($script:WhatIfMode) { return }
    $missing = New-Object System.Collections.ArrayList
    $p = $Path
    $guard = 0
    while ($p -and -not (Test-Path -LiteralPath $p) -and $guard -lt 20) {
        [void]$missing.Add($p)
        $parent = Split-Path -Path $p -Parent
        if ($parent -eq $p) { break }
        $p = $parent
        $guard++
    }
    $arr = @($missing)
    [array]::Reverse($arr)
    foreach ($m in $arr) { [void](Add-KEntry ('key|' + $m) @{ Type = 'key'; Path = $m }) }
}

function Set-KReg {
    param([string]$Path, [string]$Name, $Value, [string]$Kind = 'DWord')
    if ($script:WhatIfMode) { Write-KLog ('[whatif] reg ' + $Path + ' ' + $Name + ' = ' + $Value); return $true }
    try {
        Register-NewKeys $Path
        $st = Get-RegRaw $Path $Name
        $saved = ConvertTo-JsonSafe $st.Raw $st.Kind
        $v = $Value
        if ($Kind -eq 'DWord') { $v = ConvertTo-RegInt $Value }
        # Wrote/WroteKind = what this tool put there. Undo compares it with the live value to spot drift
        # (you or Windows changed it afterwards) and reports it instead of silently overwriting your change.
        [void](Add-KEntry ('reg|' + $Path + '|' + $Name) @{ Type = 'reg'; Path = $Path; Name = $Name; Existed = $st.Existed; Kind = $st.Kind; Value = $saved; Wrote = (ConvertTo-JsonSafe $v $Kind); WroteKind = $Kind })
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Kind -Value $v -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-KLog ('registry write failed: ' + $Path + ' ' + $Name + ' : ' + $_.Exception.Message) 'WARN'
        return $false
    }
}

function Test-KRegDrift {
    # True if the live value is no longer what this tool wrote (someone changed it after us).
    param($e)
    if (-not $e.PSObject.Properties['Wrote']) { return $false }   # journal from an older version
    $now = Get-RegRaw $e.Path $e.Name
    if (-not $now.Existed) { return $true }
    $kind = [string]$e.WroteKind
    $w = $e.Wrote
    if ($kind -eq 'Binary') {
        $hex = [string]$w
        if ($hex) { $w = [byte[]]@($hex -split '-' | ForEach-Object { [Convert]::ToByte($_, 16) }) } else { $w = [byte[]]@() }
    }
    return (-not (Test-RegValueEquals $now.Raw $w $kind))
}

function Restore-RegEntry {
    param($e)
    try {
        if (Test-KRegDrift $e) { [void]$script:KDrift.Add(($e.Path + '\' + $e.Name)) }
        if ($e.Existed) {
            $kind = [string]$e.Kind
            $v = $null
            if ($kind -eq 'Binary') {
                $hex = [string]$e.Value
                if ($hex) { $v = [byte[]]@($hex -split '-' | ForEach-Object { [Convert]::ToByte($_, 16) }) } else { $v = [byte[]]@() }
            } elseif ($kind -eq 'DWord') { $v = ConvertTo-RegInt $e.Value }
            elseif ($kind -eq 'QWord') { $v = [int64]$e.Value }
            elseif ($kind -eq 'MultiString') { $v = [string[]]@($e.Value) }
            else { $v = [string]$e.Value }
            if (-not (Test-Path -LiteralPath $e.Path)) { New-Item -Path $e.Path -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $e.Path -Name $e.Name -PropertyType $kind -Value $v -Force -ErrorAction Stop | Out-Null
            $now = Get-RegRaw $e.Path $e.Name
            return ($now.Existed -and (Test-RegValueEquals $now.Raw $v $kind))
        } else {
            if (Test-Path -LiteralPath $e.Path) { Remove-ItemProperty -LiteralPath $e.Path -Name $e.Name -ErrorAction SilentlyContinue }
            $now = Get-RegRaw $e.Path $e.Name
            return (-not $now.Existed)
        }
    } catch { Write-KLog ('restore reg failed: ' + $e.Id + ' : ' + $_.Exception.Message) 'WARN'; return $false }
}

function Restore-KeyEntry {
    # Only removes a key we created, and only if nothing else has been put in it since.
    param($e)
    try {
        if (-not (Test-Path -LiteralPath $e.Path)) { return $true }
        $item = Get-Item -LiteralPath $e.Path -ErrorAction Stop
        if ($item.SubKeyCount -eq 0 -and $item.ValueCount -eq 0) { Remove-Item -LiteralPath $e.Path -Force -ErrorAction Stop }
        return $true
    } catch { return $false }
}

# ======================= services =======================

function Disable-KService {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return 'absent' }
    if ($script:WhatIfMode) { return 'whatif' }
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
    $start = $null; $delayed = $null
    try { $start = (Get-ItemProperty -LiteralPath $key -Name Start -ErrorAction Stop).Start } catch { }
    $delayed = Get-ServiceDelayed $Name
    $was = ($svc.Status -eq 'Running')
    [void](Add-KEntry ('svc|' + $Name) @{ Type = 'service'; Name = $Name; Start = $start; Delayed = $delayed; WasRunning = $was })
    try {
        if ($was) { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
        return 'ok'
    } catch { return ('fail: ' + $_.Exception.Message) }
}

function Test-ServiceDisabled {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }   # not installed -> not applicable
    return ($svc.StartType -eq 'Disabled')
}

function Get-ServiceDelayed {
    # DelayedAutostart exactly as stored: $null when the value does not exist.
    param([string]$Name)
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
    $r = Get-RegRaw $key 'DelayedAutostart'
    if (-not $r.Existed) { return $null }
    return [int]$r.Raw
}

function Save-KServiceState {
    # Journals a service's start type and delayed flag WITHOUT changing it (used before any code that may change it).
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc -or $script:WhatIfMode) { return }
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
    $start = $null
    try { $start = (Get-ItemProperty -LiteralPath $key -Name Start -ErrorAction Stop).Start } catch { }
    [void](Add-KEntry ('svc|' + $Name) @{ Type = 'service'; Name = $Name; Start = $start; Delayed = (Get-ServiceDelayed $Name); WasRunning = ($svc.Status -eq 'Running') })
}

function Restore-ServiceEntry {
    # Puts back the start type AND the delayed-start flag exactly (set it, or remove it if it was not there).
    param($e)
    try {
        $mode = $null
        $s = $null
        if ($null -ne $e.Start) { $s = [int]$e.Start }
        if ($s -eq 2) { if ($e.Delayed -eq 1) { $mode = 'delayed-auto' } else { $mode = 'auto' } }
        elseif ($s -eq 3) { $mode = 'demand' }
        elseif ($s -eq 4) { $mode = 'disabled' }
        elseif ($s -eq 1) { $mode = 'system' }
        elseif ($s -eq 0) { $mode = 'boot' }
        if (-not $mode) { return $false }
        & sc.exe config $e.Name start= $mode | Out-Null
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $e.Name
        # sc.exe config always rewrites DelayedAutostart (to 0), so put the recorded value back afterwards.
        if ($null -ne $e.Delayed) { New-ItemProperty -LiteralPath $key -Name DelayedAutostart -PropertyType DWord -Value ([int]$e.Delayed) -Force -ErrorAction Stop | Out-Null }
        else { Remove-ItemProperty -LiteralPath $key -Name DelayedAutostart -ErrorAction SilentlyContinue }
        if ($e.WasRunning -and $mode -ne 'disabled') { Start-Service -Name $e.Name -ErrorAction SilentlyContinue }
        $now = (Get-ItemProperty -LiteralPath $key -Name Start -ErrorAction SilentlyContinue).Start
        $nowDelayed = Get-ServiceDelayed $e.Name
        $delayedOk = $false
        if ($null -eq $e.Delayed) { $delayedOk = ($null -eq $nowDelayed) }
        elseif ($null -ne $nowDelayed) { $delayedOk = ($nowDelayed -eq [int]$e.Delayed) }
        return (($now -eq $s) -and $delayedOk)
    } catch { return $false }
}

# ======================= boot configuration (bcdedit) =======================

function Get-BcdValue {
    param([string]$Name)
    try {
        $out = (& bcdedit.exe /enum '{current}' 2>&1 | Out-String)
        $m = [regex]::Match($out, '(?im)^\s*' + [regex]::Escape($Name) + '\s+(\S+)')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    return $null
}

function Set-KBcd {
    param([string]$Name, [string]$Value)
    if ($script:WhatIfMode) { return $true }
    $old = Get-BcdValue $Name
    [void](Add-KEntry ('bcd|' + $Name) @{ Type = 'bcd'; Name = $Name; Existed = ($null -ne $old); Value = $old })
    & bcdedit.exe /set $Name $Value 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Restore-BcdEntry {
    param($e)
    try {
        if ($e.Existed) { & bcdedit.exe /set $e.Name ([string]$e.Value) 2>&1 | Out-Null }
        else { & bcdedit.exe /deletevalue $e.Name 2>&1 | Out-Null }
        $now = Get-BcdValue $e.Name
        if ($e.Existed) { return ($now -ieq [string]$e.Value) }
        return ($null -eq $now)
    } catch { return $false }
}

# ======================= TCP stack (netsh) =======================

function Get-NetshTcp {
    # Reads the current TCP settings. A value that cannot be read is $null, and a setting
    # that cannot be read is never changed (no snapshot, no change).
    $r = @{}
    $g = ''; $h = ''; $s = ''
    try { $g = (& netsh.exe int tcp show global 2>&1 | Out-String) } catch { }
    try { $h = (& netsh.exe int tcp show heuristics 2>&1 | Out-String) } catch { }
    try { $s = (& netsh.exe int tcp show supplemental template=internet 2>&1 | Out-String) } catch { }
    $rx = [ordered]@{
        autotuninglevel = 'Auto-Tuning Level\s*:\s*(\S+)'
        rss             = 'Receive-Side Scaling State\s*:\s*(\S+)'
        rsc             = 'Receive Segment Coalescing State\s*:\s*(\S+)'
        ecncapability   = 'ECN Capability\s*:\s*(\S+)'
        timestamps      = 'RFC 1323 Timestamps\s*:\s*(\S+)'
    }
    foreach ($k in $rx.Keys) {
        $m = [regex]::Match($g, $rx[$k])
        if ($m.Success) { $r[$k] = $m.Groups[1].Value.ToLower() } else { $r[$k] = $null }
    }
    $m = [regex]::Match($h, 'heuristics\s*:\s*(\S+)')
    if ($m.Success) { $r['heuristics'] = $m.Groups[1].Value.ToLower() } else { $r['heuristics'] = $null }
    $m = [regex]::Match($s, 'Congestion\s+(?:Control\s+)?Provider\s*:\s*(\S+)')
    if ($m.Success) { $r['congestion'] = $m.Groups[1].Value.ToLower() } else { $r['congestion'] = $null }
    return $r
}

function Invoke-NetshSet {
    param([string]$Field, [string]$Value)
    if ($Field -eq 'heuristics') { & netsh.exe int tcp set heuristics $Value 2>&1 | Out-Null }
    elseif ($Field -eq 'congestion') { & netsh.exe int tcp set supplemental template=internet ('congestionprovider=' + $Value) 2>&1 | Out-Null }
    else { & netsh.exe int tcp set global ($Field + '=' + $Value) 2>&1 | Out-Null }
    return ($LASTEXITCODE -eq 0)
}

function Set-KNetsh {
    param([string]$Field, [string]$Value, $Before)
    if ($script:WhatIfMode) { return $true }
    $old = $Before[$Field]
    if ($null -eq $old) { return $false }   # unreadable -> leave alone
    [void](Add-KEntry ('netsh|' + $Field) @{ Type = 'netsh'; Field = $Field; Value = $old })
    return (Invoke-NetshSet $Field $Value)
}

function Restore-NetshEntry {
    param($e)
    try {
        [void](Invoke-NetshSet ([string]$e.Field) ([string]$e.Value))
        $now = Get-NetshTcp
        return ($now[[string]$e.Field] -eq ([string]$e.Value).ToLower())
    } catch { return $false }
}

# ======================= everything else =======================

function Restore-PowerEntry {
    param($e)
    try {
        $list = (& powercfg.exe /list | Out-String)
        $orig = [string]$e.OriginalGuid
        if ($orig -and $list -match [regex]::Escape($orig)) { & powercfg.exe /setactive $orig | Out-Null }
        else { & powercfg.exe /setactive 381b4222-f694-41f0-9685-ff5bb260df2e | Out-Null }   # Balanced
        if ($e.OurGuid) { & powercfg.exe /delete ([string]$e.OurGuid) | Out-Null }
        $after = (& powercfg.exe /list | Out-String)
        if ($e.OurGuid) { return (-not ($after -match [regex]::Escape([string]$e.OurGuid))) }
        return $true
    } catch { return $false }
}

function Restore-NicPropEntry {
    param($e)
    try {
        $nic = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceGuid -eq $e.Guid } | Select-Object -First 1
        if (-not $nic) { return $true }   # adapter no longer present, nothing to restore
        Set-NetAdapterAdvancedProperty -Name $nic.Name -RegistryKeyword ([string]$e.Keyword) -RegistryValue @([string[]]$e.Value) -NoRestart -ErrorAction Stop
        return $true
    } catch { Write-KLog ('restore nic property failed: ' + $e.Id + ' : ' + $_.Exception.Message) 'WARN'; return $false }
}

function Restore-NicStateEntry {
    param($e)
    try {
        $nic = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceGuid -eq $e.Guid } | Select-Object -First 1
        if (-not $nic) { return $true }
        $n = $nic.Name
        if ($null -ne $e.Rss) { if ($e.Rss) { Enable-NetAdapterRss -Name $n -ErrorAction SilentlyContinue } else { Disable-NetAdapterRss -Name $n -ErrorAction SilentlyContinue } }
        if ($e.PowerMgmt -eq 'Enabled') { Enable-NetAdapterPowerManagement -Name $n -ErrorAction SilentlyContinue }
        if ($null -ne $e.LsoV4) { if ($e.LsoV4) { Enable-NetAdapterLso -Name $n -IPv4 -ErrorAction SilentlyContinue } else { Disable-NetAdapterLso -Name $n -IPv4 -ErrorAction SilentlyContinue } }
        if ($null -ne $e.LsoV6) { if ($e.LsoV6) { Enable-NetAdapterLso -Name $n -IPv6 -ErrorAction SilentlyContinue } else { Disable-NetAdapterLso -Name $n -IPv6 -ErrorAction SilentlyContinue } }
        if ($null -ne $e.RscV4) { if ($e.RscV4) { Enable-NetAdapterRsc -Name $n -IPv4 -ErrorAction SilentlyContinue } else { Disable-NetAdapterRsc -Name $n -IPv4 -ErrorAction SilentlyContinue } }
        if ($null -ne $e.RscV6) { if ($e.RscV6) { Enable-NetAdapterRsc -Name $n -IPv6 -ErrorAction SilentlyContinue } else { Disable-NetAdapterRsc -Name $n -IPv6 -ErrorAction SilentlyContinue } }
        return $true
    } catch { return $false }
}

function Restore-DefenderEntry {
    param($e)
    try {
        if ($e.Kind -eq 'Path') { Remove-MpPreference -ExclusionPath ([string]$e.Value) -ErrorAction Stop }
        else { Remove-MpPreference -ExclusionProcess ([string]$e.Value) -ErrorAction Stop }
        $mp = Get-MpPreference -ErrorAction Stop
        $list = @($mp.ExclusionProcess)
        if ($e.Kind -eq 'Path') { $list = @($mp.ExclusionPath) }
        return (-not ($list -contains [string]$e.Value))
    } catch { return $false }
}

function Restore-XmlTextEntry {
    # Puts one tag's text back, without touching anything else in the file (so edits made since then survive).
    param($e)
    try {
        if (-not (Test-Path -LiteralPath $e.Path)) { return $true }
        $bytes = [IO.File]::ReadAllBytes($e.Path)
        $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $enc = New-Object Text.UTF8Encoding($bom)
        $txt = $enc.GetString($bytes)
        if ($bom) { $txt = $txt.TrimStart([char]0xFEFF) }
        $tag = [regex]::Escape([string]$e.Tag)
        $old = [string]$e.Old
        $new = [regex]::Replace($txt, '(?<=<' + $tag + '>)[^<]*(?=</' + $tag + '>)', { param($m) $old })
        [IO.File]::WriteAllText($e.Path, $new, $enc)
        return $true
    } catch { return $false }
}

function Restore-FileBackupEntry {
    # Puts a file we had to overwrite back from the copy taken before the change.
    param($e)
    try {
        if (-not (Test-Path -LiteralPath $e.Backup)) { return $false }
        Copy-Item -LiteralPath $e.Backup -Destination $e.Path -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Restore-OwnedFileEntry {
    # Removes a file this tool created, but only if it is still exactly what the tool wrote
    # (checked against the hash saved next to it). A file you edited is kept.
    # Returns 'ok', 'kept' (left on purpose) or 'fail'.
    param($e)
    try {
        $side = [string]$e.Sidecar
        if (-not (Test-Path -LiteralPath $e.Path)) {
            if ($side -and (Test-Path -LiteralPath $side)) { Remove-Item -LiteralPath $side -Force -ErrorAction SilentlyContinue }
            return 'ok'
        }
        $same = $false
        if ($side -and (Test-Path -LiteralPath $side)) {
            $want = (Get-Content -LiteralPath $side -Raw -ErrorAction SilentlyContinue)
            if ($want) { $same = ($want.Trim().ToLower() -eq (Get-FileHash -LiteralPath $e.Path -Algorithm SHA256).Hash.ToLower()) }
        }
        if (-not $same) { return 'kept' }
        Remove-Item -LiteralPath $e.Path -Force -ErrorAction Stop
        if ($side -and (Test-Path -LiteralPath $side)) { Remove-Item -LiteralPath $side -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $e.Path) { return 'fail' }
        return 'ok'
    } catch { return 'fail' }
}

function Stop-KProcessByCommandLine {
    param([string]$Pattern)
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like $Pattern -and $_.ProcessId -ne $PID } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
}

# ======================= hibernate =======================

$script:PowerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'

function Restore-HibernateEntry {
    # Restores the hibernate state AND whether the HibernateEnabled value existed at all.
    param($e)
    try {
        if (-not $e.PSObject.Properties['Existed']) {
            # journal written by an older version: only on/off was recorded
            if ($e.Enabled) { & powercfg.exe /hibernate on | Out-Null }
            return $true
        }
        if ($e.Existed -and ([int]$e.Value -eq 1)) { & powercfg.exe /hibernate on | Out-Null }
        else { & powercfg.exe /hibernate off | Out-Null }
        if (-not $e.Existed) { Remove-ItemProperty -LiteralPath $script:PowerKey -Name HibernateEnabled -ErrorAction SilentlyContinue }
        $now = Get-RegRaw $script:PowerKey 'HibernateEnabled'
        if (-not $e.Existed) { return (-not $now.Existed) }
        return ($now.Existed -and ([int]$now.Raw -eq [int]$e.Value))
    } catch { return $false }
}

# ======================= System Protection / shadow storage =======================

function ConvertFrom-VssStorageText {
    # Parses `vssadmin list shadowstorage` (English output). Known=$false means "could not read it": then nothing is changed.
    param([string]$Text, [string]$Drive)
    $r = [pscustomobject]@{ Known = $false; Had = $false; Percent = $null; Unbounded = $false }
    if (-not $Text) { return $r }
    if ($Text -notmatch '(?i)No items found|Shadow Copy Storage') { return $r }
    $r.Known = $true
    $d = [regex]::Escape($Drive)
    foreach ($b in [regex]::Split($Text, '(?i)Shadow Copy Storage association')) {
        if ($b -match ('(?i)For volume:\s*\(' + $d + '\)')) {
            $r.Had = $true
            if ($b -match '(?i)Maximum Shadow Copy Storage space:\s*UNBOUNDED') { $r.Unbounded = $true }
            else {
                $m = [regex]::Match($b, '(?i)Maximum Shadow Copy Storage space:[^\(\r\n]*\((\d+)%\)')
                if ($m.Success) { $r.Percent = [int]$m.Groups[1].Value }
            }
            break
        }
    }
    return $r
}

function Get-KShadowStorage {
    param([string]$Drive)
    $txt = ''
    try { $txt = (& vssadmin.exe list shadowstorage 2>&1 | Out-String) } catch { }
    return (ConvertFrom-VssStorageText $txt $Drive)
}

function Restore-SysProtEntry {
    # Puts the shadow-storage size back. It NEVER turns System Protection off, because that would delete
    # the restore points (including the one made for this run). The caller adds a manual note instead.
    param($e)
    try {
        if (-not $e.Known -or -not $e.Had) { return $true }
        if ($e.Unbounded) { $arg = '/maxsize=UNBOUNDED' }
        elseif ($null -ne $e.Percent) { $arg = '/maxsize=' + [int]$e.Percent + '%' }
        else { return $true }
        & vssadmin.exe resize shadowstorage ('/for=' + $e.Drive) ('/on=' + $e.Drive) $arg 2>&1 | Out-Null
        $now = Get-KShadowStorage ([string]$e.Drive)
        if ($e.Unbounded) { return ($now.Had -and $now.Unbounded) }
        return ($now.Had -and ($now.Percent -eq [int]$e.Percent))
    } catch { return $false }
}

# ======================= the undo engine =======================

function Invoke-KRevert {
    # -Group: undo only the entries tagged with that group (per-group A/B testing). The rest stay journaled.
    param([string]$Module, [string]$Group = '')
    $path = Join-Path (Join-Path $script:DataRoot $Module) 'journal.json'
    $result = @{ Ok = $true; Total = 0; Restored = 0; Failed = @(); Manual = @(); Drift = @() }
    $script:KDrift = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Say ('Nothing to undo for ' + $Module + ' (no journal found).') 'Yellow'
        return $result
    }
    Open-KJournal $Module
    $entries = @($script:J.Entries)
    if ($Group) { $entries = @($entries | Where-Object { $_.PSObject.Properties['Group'] -and [string]$_.Group -eq $Group }) }
    [array]::Reverse($entries)
    $result.Total = $entries.Count
    $failed = New-Object System.Collections.ArrayList
    $manual = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($e in $entries) {
        $i++
        $ok = $true
        try {
            $t = [string]$e.Type
            if ($t -eq 'reg') { $ok = Restore-RegEntry $e }
            elseif ($t -eq 'key') { $ok = Restore-KeyEntry $e }
            elseif ($t -eq 'service') { $ok = Restore-ServiceEntry $e }
            elseif ($t -eq 'bcd') { $ok = Restore-BcdEntry $e }
            elseif ($t -eq 'netsh') { $ok = Restore-NetshEntry $e }
            elseif ($t -eq 'powerscheme') { $ok = Restore-PowerEntry $e }
            elseif ($t -eq 'hibernate') { $ok = Restore-HibernateEntry $e }
            elseif ($t -eq 'sysprot') {
                $ok = Restore-SysProtEntry $e
                if ($e.Known -and -not $e.Had) {
                    [void]$manual.Add('System Protection was off before this tool ran. It was left ON so your restore point stays usable. Turn it off in System Properties > System Protection if you want (that deletes restore points).')
                }
            }
            elseif ($t -eq 'fsutil') { & fsutil.exe behavior set ([string]$e.Name) ([string]$e.Value) | Out-Null; $ok = ($LASTEXITCODE -eq 0) }
            elseif ($t -eq 'nicprop') { $ok = Restore-NicPropEntry $e }
            elseif ($t -eq 'nicstate') { $ok = Restore-NicStateEntry $e }
            elseif ($t -eq 'defexcl') { $ok = Restore-DefenderEntry $e }
            elseif ($t -eq 'qos') {
                Remove-NetQosPolicy -Name ([string]$e.Name) -Confirm:$false -ErrorAction SilentlyContinue
                $ok = (-not (Get-NetQosPolicy -Name ([string]$e.Name) -ErrorAction SilentlyContinue))
            }
            elseif ($t -eq 'task') {
                Unregister-ScheduledTask -TaskName ([string]$e.Name) -Confirm:$false -ErrorAction SilentlyContinue
                $ok = (-not (Get-ScheduledTask -TaskName ([string]$e.Name) -ErrorAction SilentlyContinue))
            }
            elseif ($t -eq 'proc') { Stop-KProcessByCommandLine ([string]$e.Pattern) }
            elseif ($t -eq 'file') {
                if (Test-Path -LiteralPath $e.Path) { Remove-Item -LiteralPath $e.Path -Force -ErrorAction SilentlyContinue }
                $ok = (-not (Test-Path -LiteralPath $e.Path))
            }
            elseif ($t -eq 'dir') {
                if (Test-Path -LiteralPath $e.Path) { Remove-Item -LiteralPath $e.Path -Recurse -Force -ErrorAction SilentlyContinue }
                $ok = (-not (Test-Path -LiteralPath $e.Path))
            }
            elseif ($t -eq 'ownedfile') {
                $o = Restore-OwnedFileEntry $e
                if ($o -eq 'fail') { $ok = $false }
                elseif ($o -eq 'kept') { [void]$manual.Add('Kept your edited file (not deleted): ' + [string]$e.Path) }
            }
            elseif ($t -eq 'xmltext') { $ok = Restore-XmlTextEntry $e }
            elseif ($t -eq 'filerestore') { $ok = Restore-FileBackupEntry $e }
            elseif ($t -eq 'appx') { [void]$manual.Add([string]$e.Label) }
            else { Write-KLog ('unknown journal entry type: ' + $t) 'WARN' }
        } catch { $ok = $false; Write-KLog ('revert error ' + $e.Id + ' : ' + $_.Exception.Message) 'WARN' }
        if (-not $ok) { [void]$failed.Add([string]$e.Id) }
        if (($i % 40) -eq 0) { Write-Say ('  restored {0} of {1} ...' -f $i, $result.Total) 'DarkGray' }
    }
    $result.Failed = @($failed)
    $result.Manual = @($manual | Select-Object -Unique)
    $result.Drift = @($script:KDrift)
    $result.Restored = $result.Total - $failed.Count
    if ($Group) {
        # partial undo: drop the restored entries, keep everything else (and the failed ones) for later
        $done = @{}; foreach ($e in $entries) { if ($failed -notcontains [string]$e.Id) { $done[[string]$e.Id] = $true } }
        $keep = New-Object System.Collections.ArrayList
        foreach ($e in @($script:J.Entries)) { if (-not $done.ContainsKey([string]$e.Id)) { [void]$keep.Add($e) } }
        $script:J.Entries = $keep
        $script:J.Index = @{}; foreach ($e in $keep) { $script:J.Index[[string]$e.Id] = $true }
        Save-KJournal
        if ($failed.Count -gt 0) { $result.Ok = $false }
        if ($keep.Count -eq 0) {
            $arch = Join-Path (Split-Path -Path $path -Parent) 'reverted'
            if (-not (Test-Path -LiteralPath $arch)) { New-Item -ItemType Directory -Path $arch -Force | Out-Null }
            Move-Item -LiteralPath $path -Destination (Join-Path $arch ((Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')) -Force
        }
    } elseif ($failed.Count -eq 0) {
        $arch = Join-Path (Split-Path -Path $path -Parent) 'reverted'
        if (-not (Test-Path -LiteralPath $arch)) { New-Item -ItemType Directory -Path $arch -Force | Out-Null }
        Move-Item -LiteralPath $path -Destination (Join-Path $arch ((Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')) -Force
    } else {
        $result.Ok = $false
    }
    $script:J = $null
    return $result
}

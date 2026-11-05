# Controller.ps1 -- DS4Windows controller module.
#
# Wraps the proven DS4 optimizer (controller\ds4_optimize_final.py, unchanged):
#   * holds the Windows timer at its finest setting while you play,
#   * raises DS4Windows to High priority and turns off power throttling for it,
#   * writes <profile>_tuned.xml with the strafe boost (left stick X only, right stick never touched).
# It is installed to a protected folder and started hidden at every logon by a scheduled task.
# Your own DS4Windows profile is never overwritten.

$script:CtlTask    = 'Kpekpes Controller Optimizer'
$script:CtlOldTask = 'DS4 Optimizer'
$script:Strafe     = @{ mild = @(6, 52); strong = @(10, 48); max = @(16, 40) }
$script:Silent     = $false

function Get-CtlDirs {
    $base = Join-Path $script:DataRoot 'controller'
    return [pscustomobject]@{ Base = $base; Bin = (Join-Path $base 'bin'); Backup = (Join-Path $base 'backup') }
}

# ---------------- discovery ----------------
function Find-DS4Windows {
    $cfg = Get-KConfig
    $c = [string]$cfg.Controller.DS4WindowsExe
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    $cands = New-Object System.Collections.Generic.List[string]
    $up = $env:USERPROFILE
    foreach ($root in @((Join-Path $up 'Downloads'), (Join-Path $up 'Desktop'), (Join-Path $up 'Documents'), 'C:\DS4Windows', 'C:\Program Files\DS4Windows', 'C:\Program Files (x86)\DS4Windows')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Filter 'DS4Windows.exe' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue | ForEach-Object { [void]$cands.Add($_.FullName) }
    }
    if ($cands.Count -eq 0) { return '' }
    $best = $cands | ForEach-Object { Get-Item -LiteralPath $_ } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    return $best.FullName
}

function Get-DS4ProfilesDir {
    param([string]$Exe)
    $p1 = Join-Path (Split-Path $Exe -Parent) 'Profiles'
    if (Test-Path -LiteralPath $p1) { return $p1 }
    $p2 = Join-Path $env:APPDATA 'DS4Windows\Profiles'
    if (Test-Path -LiteralPath $p2) { return $p2 }
    return $p1
}

function Test-PythonWorks {
    param([string]$Exe, [string[]]$ExtraArgs)
    try {
        $o = (& $Exe @ExtraArgs 2>&1 | Out-String)
        return ($o -match 'Python 3')
    } catch { return $false }
}

function Find-Python {
    # Returns 'python', 'py' or '' . The Microsoft Store "python" stub does not count as Python.
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py -and (Test-PythonWorks $py.Source @('-3', '--version'))) { return 'py' }
    foreach ($p in @(Get-Command python -All -ErrorAction SilentlyContinue)) {
        if (Test-PythonWorks $p.Source @('--version')) { return 'python' }
    }
    return ''
}

# ---------------- small file helpers ----------------
function Read-TextKeepEncoding {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc = New-Object Text.UTF8Encoding($bom)
    $txt = $enc.GetString($bytes)
    if ($bom) { $txt = $txt.TrimStart([char]0xFEFF) }
    return [pscustomobject]@{ Text = $txt; Encoding = $enc }
}

function Get-XmlTagText {
    param([string]$Path, [string]$Tag)
    $f = Read-TextKeepEncoding $Path
    $m = [regex]::Match($f.Text, '<' + [regex]::Escape($Tag) + '>([^<]*)</' + [regex]::Escape($Tag) + '>')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Set-XmlTagText {
    # Replaces only that tag's text, leaving the rest of the file byte-for-byte as DS4Windows wrote it.
    param([string]$Path, [string]$Tag, [string]$New)
    $f = Read-TextKeepEncoding $Path
    $rx = '(?<=<' + [regex]::Escape($Tag) + '>)[^<]*(?=</' + [regex]::Escape($Tag) + '>)'
    if (-not [regex]::IsMatch($f.Text, $rx)) { return $false }
    $out = [regex]::Replace($f.Text, $rx, { param($m) $New })
    [IO.File]::WriteAllText($Path, $out, $f.Encoding)
    return $true
}

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# ---------------- install ----------------
function Install-Controller {
    param($Cfg, [string]$SourceDir)
    $res = [pscustomobject]@{ Ok = $false; Message = ''; Steps = @() }
    $d = Get-CtlDirs
    $strafe = [string]$Cfg.Controller.StrafeBoost
    if (-not $script:Strafe.ContainsKey($strafe)) { $res.Message = 'StrafeBoost in config.json must be mild, strong or max.'; return $res }

    Write-Say '[1/7] DS4Windows' 'Cyan'
    $exe = Find-DS4Windows
    if (-not $exe -and -not $script:Silent) {
        $typed = Read-Host '  DS4Windows.exe not found automatically. Paste its full path (or press Enter to cancel)'
        $typed = $typed.Trim('"').Trim()
        if ($typed -and (Test-Path -LiteralPath $typed)) { $exe = $typed }
    }
    if (-not $exe) { $res.Message = 'DS4Windows.exe not found. Put its path in config.json (Controller.DS4WindowsExe) and run again.'; return $res }
    Write-Say ('  found: ' + $exe) 'Green'
    $profDir = Get-DS4ProfilesDir $exe
    $name = [string]$Cfg.Controller.ProfileName
    $profile = Join-Path $profDir ($name + '.xml')

    Write-Say '[2/7] Python' 'Cyan'
    $py = Find-Python
    if (-not $py -and -not $script:Silent -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        $a = Read-Host '  Python 3 is not installed. Install it now with winget? (y/n)'
        if ($a -match '^(y|yes)$') {
            & winget.exe install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements
            $py = Find-Python
            if (-not $py) { $res.Message = 'Python was installed but is not visible to this window yet. Close this window, open it again and re-run.'; return $res }
        }
    }
    if (-not $py) { $res.Message = 'Python 3 is required for the controller optimizer. Install it from python.org (tick "Add python.exe to PATH") and run again.'; return $res }
    Write-Say ('  Python OK (' + $py + ')') 'Green'

    if ($script:WhatIfMode) { Write-Say '  [what-if] would install the controller module now' 'Yellow'; $res.Ok = $true; return $res }

    Write-Say '[3/7] Install the scripts into the protected folder' 'Cyan'
    if (-not (Initialize-KRoot)) { $res.Message = 'Cannot create the data folder.'; return $res }
    Open-KJournal 'controller'
    foreach ($p in @($d.Base, $d.Bin, $d.Backup)) { if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
    [void](Add-KEntry ('dir|' + $d.Bin) @{ Type = 'dir'; Path = $d.Bin })

    $ctl = Join-Path $SourceDir 'controller'
    $pyDst = Join-Path $d.Bin 'ds4_optimize_final.py'
    $batDst = Join-Path $d.Bin 'controller_optimizer.bat'
    $vbsDst = Join-Path $d.Bin 'run_hidden.vbs'
    foreach ($f in @($pyDst, $batDst, $vbsDst)) { [void](Add-KEntry ('file|' + $f) @{ Type = 'file'; Path = $f }) }
    Copy-Item -LiteralPath (Join-Path $ctl 'ds4_optimize_final.py') -Destination $pyDst -Force
    $bat = (Get-Content -LiteralPath (Join-Path $ctl 'controller_optimizer.bat.template') -Raw -Encoding UTF8)
    $bat = $bat.Replace('@@PROFILE@@', $profile).Replace('@@DS4EXE@@', $exe).Replace('@@STRAFE@@', $strafe)
    $bat = ($bat -replace "`r?`n", "`r`n")
    [IO.File]::WriteAllText($batDst, $bat, (New-Object Text.UTF8Encoding($false)))
    $vbs = (Get-Content -LiteralPath (Join-Path $ctl 'run_hidden.vbs.template') -Raw -Encoding UTF8).Replace('@@BAT@@', $batDst)
    [IO.File]::WriteAllText($vbsDst, $vbs, [Text.Encoding]::Default)

    Write-Say '[4/7] Profile' 'Cyan'
    if (-not (Test-Path -LiteralPath $profDir)) { New-Item -ItemType Directory -Path $profDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $profile)) {
        $bundled = Join-Path $ctl ('profiles\' + $name + '.xml')
        if (Test-Path -LiteralPath $bundled) {
            [void](Add-KEntry ('file|' + $profile) @{ Type = 'file'; Path = $profile })
            Copy-Item -LiteralPath $bundled -Destination $profile -Force
            Write-Say ('  ' + $name + '.xml was missing, installed the bundled copy') 'Yellow'
        } else { $res.Message = ('Profile ' + $name + '.xml not found in ' + $profDir + ' and no bundled copy exists.'); return $res }
    } else { Write-Say ('  using your existing ' + $name + '.xml (not replaced)') 'Green' }
    $old = Get-XmlTagText $profile 'LaunchProgram'
    if ($null -eq $old) { Write-Say '  profile has no LaunchProgram tag - the scheduled task still starts the optimizer at logon' 'Yellow' }
    elseif ($old -ne $vbsDst) {
        [void](Add-KEntry ('xmltext|' + $profile + '|LaunchProgram') @{ Type = 'xmltext'; Path = $profile; Tag = 'LaunchProgram'; Old = $old })
        if (-not (Set-XmlTagText $profile 'LaunchProgram' $vbsDst)) { Write-Say '  could not set LaunchProgram' 'Yellow' }
    }

    Write-Say '[5/7] Tuned profile (left-stick strafe boost)' 'Cyan'
    $tuned = Join-Path $profDir ($name + '_tuned.xml')
    if (Test-Path -LiteralPath $tuned) {
        $bk = Join-Path $d.Backup ($name + '_tuned.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.xml')
        Copy-Item -LiteralPath $tuned -Destination $bk -Force
        [void](Add-KEntry ('filerestore|' + $tuned) @{ Type = 'filerestore'; Path = $tuned; Backup = $bk })
        Write-Say '  an older tuned profile existed; a backup copy was saved and is restored on Undo' 'Yellow'
    } else {
        [void](Add-KEntry ('file|' + $tuned) @{ Type = 'file'; Path = $tuned })
    }

    Write-Say '[6/7] Start at every logon (hidden, elevated)' 'Cyan'
    [void](Add-KEntry ('task|' + $script:CtlTask) @{ Type = 'task'; Name = $script:CtlTask })
    $u = $env:USERDOMAIN + '\' + $env:USERNAME
    $a = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbsDst + '"')
    $tr = New-ScheduledTaskTrigger -AtLogOn -User $u
    $p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Highest
    $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $script:CtlTask -Action $a -Trigger $tr -Principal $p -Settings $s -Force -ErrorAction Stop | Out-Null
    if (Get-ScheduledTask -TaskName $script:CtlOldTask -ErrorAction SilentlyContinue) {
        Write-Say ('  note: an older task called "' + $script:CtlOldTask + '" exists. It is not touched; the optimizer never runs twice.') 'Yellow'
    }

    Write-Say '[7/7] Start it now' 'Cyan'
    [void](Add-KEntry 'proc|controller' @{ Type = 'proc'; Pattern = '*ds4_optimize_final.py*' })
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbsDst + '"')
    $log = Join-Path $d.Bin 'ds4_optimizer.log'
    $deadline = (Get-Date).AddSeconds(25)
    $boosted = $false
    while ((Get-Date) -lt $deadline -and -not $boosted) {
        Start-Sleep -Seconds 2
        if (Test-Path -LiteralPath $log) { $boosted = ((Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue) -match 'Boosted DS4Windows') }
    }
    if ($boosted) { Write-Say '  DS4Windows boosted' 'Green' } else { Write-Say '  optimizer started; "Boosted DS4Windows.exe" appears in the log once DS4Windows is running' 'Yellow' }

    $Cfg.Controller.DS4WindowsExe = $exe
    Save-KConfig $Cfg
    $res.Ok = $true
    $res.Message = ('In DS4Windows, select the profile "' + $name + '_tuned" to use the strafe boost (' + $script:Strafe[$strafe][0] + '% / ' + $script:Strafe[$strafe][1] + '%).')
    return $res
}

# ---------------- verify ----------------
function Get-ControllerVerifyResults {
    param($Cfg)
    $r = New-Object System.Collections.ArrayList
    $g = 'Controller'
    $d = Get-CtlDirs
    $exe = Find-DS4Windows
    $name = [string]$Cfg.Controller.ProfileName
    $strafe = [string]$Cfg.Controller.StrafeBoost

    if (Test-Path -LiteralPath (Join-Path $d.Base 'journal.json')) { [void]$r.Add((New-KResult 'Undo information saved' 'PASS' '' $g)) }
    else { [void]$r.Add((New-KResult 'Undo information saved' 'FAIL' 'not installed yet' $g)) }

    if ($exe) { [void]$r.Add((New-KResult 'DS4Windows found' 'PASS' $exe $g)) } else { [void]$r.Add((New-KResult 'DS4Windows found' 'FAIL' '' $g)) }
    if (Find-Python) { [void]$r.Add((New-KResult 'Python 3 available' 'PASS' '' $g)) } else { [void]$r.Add((New-KResult 'Python 3 available' 'FAIL' 'install Python 3' $g)) }

    $vbs = Join-Path $d.Bin 'run_hidden.vbs'
    foreach ($f in @('ds4_optimize_final.py', 'controller_optimizer.bat', 'run_hidden.vbs')) {
        if (Test-Path -LiteralPath (Join-Path $d.Bin $f)) { [void]$r.Add((New-KResult ('Installed: ' + $f) 'PASS' '' $g)) } else { [void]$r.Add((New-KResult ('Installed: ' + $f) 'FAIL' '' $g)) }
    }
    # the folder the scheduled task runs from must not be writable by normal users
    try {
        $acl = Get-Acl -LiteralPath $d.Bin
        $bad = @($acl.Access | Where-Object { $_.IdentityReference.Value -match '(?i)\\Users$|Everyone|Authenticated Users' -and $_.AccessControlType -eq 'Allow' -and $_.FileSystemRights.ToString() -match 'Write|Modify|FullControl' })
        if ($bad.Count -eq 0) { [void]$r.Add((New-KResult 'Script folder locked against edits by normal users' 'PASS' '' $g)) }
        else { [void]$r.Add((New-KResult 'Script folder locked against edits by normal users' 'FAIL' 'normal users can write there' $g)) }
    } catch { [void]$r.Add((New-KResult 'Script folder locked against edits by normal users' 'NA' 'folder not installed' $g)) }

    if ($exe) {
        $profile = Join-Path (Get-DS4ProfilesDir $exe) ($name + '.xml')
        $tuned = Join-Path (Get-DS4ProfilesDir $exe) ($name + '_tuned.xml')
        if (Test-Path -LiteralPath $profile) {
            [void]$r.Add((New-KResult ('Profile ' + $name + '.xml present') 'PASS' '' $g))
            $lp = Get-XmlTagText $profile 'LaunchProgram'
            if ($lp -eq $vbs) { [void]$r.Add((New-KResult 'Profile launches the optimizer' 'PASS' '' $g)) }
            else { [void]$r.Add((New-KResult 'Profile launches the optimizer' 'WARN' 'LaunchProgram differs (the logon task still starts it)' $g)) }
        } else { [void]$r.Add((New-KResult ('Profile ' + $name + '.xml present') 'FAIL' '' $g)) }
        if ((Test-Path -LiteralPath $tuned) -and $script:Strafe.ContainsKey($strafe)) {
            try {
                $x = [xml](Get-Content -LiteralPath $tuned -Raw)
                $ax = $x.SelectSingleNode('//LSAxialDeadOptions')
                $a = [int]$ax.AntiDeadZoneX; $m = [int]$ax.MaxZoneX
                if ($a -eq $script:Strafe[$strafe][0] -and $m -eq $script:Strafe[$strafe][1]) { [void]$r.Add((New-KResult ('Tuned profile has strafe boost ' + $strafe + ' (' + $a + '% / ' + $m + '%)') 'PASS' '' $g)) }
                else { [void]$r.Add((New-KResult 'Tuned profile has strafe boost' 'FAIL' ('found ' + $a + '% / ' + $m + '%') $g)) }
            } catch { [void]$r.Add((New-KResult 'Tuned profile readable' 'FAIL' $_.Exception.Message $g)) }
        } else { [void]$r.Add((New-KResult 'Tuned profile exists' 'FAIL' ($name + '_tuned.xml not found') $g)) }
    }

    $t = Get-ScheduledTask -TaskName $script:CtlTask -ErrorAction SilentlyContinue
    if ($t) {
        [void]$r.Add((New-KResult 'Logon task registered' 'PASS' '' $g))
        if ([string]$t.Principal.RunLevel -eq 'Highest') { [void]$r.Add((New-KResult 'Logon task runs elevated' 'PASS' 'needed to boost an elevated DS4Windows' $g)) }
        else { [void]$r.Add((New-KResult 'Logon task runs elevated' 'FAIL' '' $g)) }
    } else { [void]$r.Add((New-KResult 'Logon task registered' 'FAIL' '' $g)) }

    $run = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -like '*ds4_optimize_final.py*' -and $_.ProcessId -ne $PID })
    if ($run.Count -eq 1) { [void]$r.Add((New-KResult 'Optimizer running (exactly one)' 'PASS' '' $g)) }
    elseif ($run.Count -eq 0) { [void]$r.Add((New-KResult 'Optimizer running (exactly one)' 'FAIL' 'not running' $g)) }
    else { [void]$r.Add((New-KResult 'Optimizer running (exactly one)' 'WARN' ([string]$run.Count + ' copies running') $g)) }

    $ds = @(Get-Process -Name 'DS4Windows' -ErrorAction SilentlyContinue)
    if ($ds.Count -eq 0) { [void]$r.Add((New-KResult 'DS4Windows priority High' 'NA' 'DS4Windows is not running' $g)) }
    else {
        $pc = ''
        try { $pc = [string]$ds[0].PriorityClass } catch { }
        if ($pc -eq 'High') { [void]$r.Add((New-KResult 'DS4Windows priority High' 'PASS' '' $g)) }
        else { [void]$r.Add((New-KResult 'DS4Windows priority High' 'FAIL' ('found ' + $pc) $g)) }
    }
    $log = Join-Path $d.Bin 'ds4_optimizer.log'
    if (Test-Path -LiteralPath $log) {
        if ((Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue) -match 'Boosted DS4Windows') { [void]$r.Add((New-KResult 'Optimizer log shows DS4Windows boosted' 'PASS' '' $g)) }
        else { [void]$r.Add((New-KResult 'Optimizer log shows DS4Windows boosted' 'WARN' 'no boost line yet' $g)) }
    }
    return @($r)
}

# ---------------- undo ----------------
function Invoke-ControllerUndo {
    Write-Head 'Undo controller optimizer'
    $res = Invoke-KRevert 'controller'
    if ($res.Total -eq 0) { return $res }
    foreach ($p in @(Get-Process -Name 'DS4Windows' -ErrorAction SilentlyContinue)) { try { $p.PriorityClass = 'Normal' } catch { } }
    Write-Say ('  restored {0} of {1} recorded changes' -f $res.Restored, $res.Total) 'Green'
    if ($res.Failed.Count -gt 0) {
        Write-Say '  could not restore (journal kept so you can run Undo again):' 'Red'
        foreach ($f in $res.Failed) { Write-Say ('    ' + $f) 'Red' }
    }
    Write-Say '  DS4Windows keeps running; its priority is back to normal.' 'Gray'
    return $res
}

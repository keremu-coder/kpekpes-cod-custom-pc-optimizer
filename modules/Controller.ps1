# Controller.ps1 -- DS4Windows controller module.
#
# Wraps the proven DS4 optimizer (controller\ds4_optimize_final.py, packaged as the single program
# KpekpesPCOptimizer.exe by .github\workflows\build-exe.yml; no Python is needed on this PC):
#   * holds the Windows timer at its finest setting while you play,
#   * raises DS4Windows to High priority and turns off power throttling for it,
#   * writes <profile>_tuned.xml with the strafe boost (left stick X only, right stick never touched).
# It is installed to a protected folder and started hidden at every logon by a scheduled task.
# Your own DS4Windows profile is never overwritten.

$script:CtlTask    = 'Kpekpes Controller Optimizer'
$script:CtlOldTask = 'DS4 Optimizer'
$script:Strafe     = @{ mild = @(6, 52); strong = @(10, 48); max = @(16, 40) }
$script:Silent     = $false
$script:CtlExeName = 'KpekpesPCOptimizer.exe'

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

    Write-Say '[2/7] Optimizer program' 'Cyan'
    $ctl = Join-Path $SourceDir 'controller'
    $exeSrc = Join-Path $ctl $script:CtlExeName
    if (-not (Test-Path -LiteralPath $exeSrc)) {
        $res.Message = ($script:CtlExeName + ' is missing from the controller folder. Download the "Kpekpes-full-package" (or the exe) from the build-exe run on GitHub Actions and put the exe in ' + $ctl + ' , then run again.')
        return $res
    }
    Write-Say ('  found: ' + $exeSrc + '  (SHA-256 ' + (Get-FileSha256 $exeSrc) + ')') 'Green'

    if ($script:WhatIfMode) { Write-Say '  [what-if] would install the controller module now' 'Yellow'; $res.Ok = $true; return $res }

    Write-Say '[3/7] Install the scripts into the protected folder' 'Cyan'
    if (-not (Initialize-KRoot)) { $res.Message = 'Cannot create the data folder.'; return $res }
    Open-KJournal 'controller'
    foreach ($p in @($d.Base, $d.Bin, $d.Backup)) { if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
    [void](Add-KEntry ('dir|' + $d.Bin) @{ Type = 'dir'; Path = $d.Bin })

    $exeDst = Join-Path $d.Bin $script:CtlExeName
    $batDst = Join-Path $d.Bin 'controller_optimizer.bat'
    $vbsDst = Join-Path $d.Bin 'run_hidden.vbs'
    foreach ($f in @($exeDst, $batDst, $vbsDst)) { [void](Add-KEntry ('file|' + $f) @{ Type = 'file'; Path = $f }) }
    Copy-Item -LiteralPath $exeSrc -Destination $exeDst -Force
    $bat = (Get-Content -LiteralPath (Join-Path $ctl 'controller_optimizer.bat.template') -Raw -Encoding UTF8)
    $keepAwake = [string]$Cfg.Controller.KeepAwake
    $tunedPolicy = [string]$Cfg.Controller.TunedProfilePolicy
    # DS4Windows start: with admin rights only when nobody but an administrator can replace it (or the profile it reads).
    # Otherwise it starts WITHOUT admin rights, and the strafe boost is still written at every logon, by the same non-admin task.
    $dsMode = [string]$Cfg.Controller.DS4Elevation
    $hard = ($dsMode -eq 'normal')
    if ($dsMode -eq 'auto') {
        $hard = $true
        if (Get-Command Test-KPathSafeForElevation -ErrorAction SilentlyContinue) {
            $sx = Test-KPathSafeForElevation $exe
            $sp = Test-KPathSafeForElevation $profDir
            if ($sx.Safe -and $sp.Safe) { $hard = $false }
            else {
                $why = $sx.Reason; if ($sx.Safe) { $why = $sp.Reason }
                Write-Say ('  DS4Windows will start WITHOUT admin rights: ' + $why) 'Yellow'
                Write-Say '  (move DS4Windows and its profiles under C:\Program Files if you want it to start with admin rights)' 'Yellow'
            }
        }
    }
    if ($hard) {
        $ds4Block = ':: DS4Windows is started by its own non-elevated logon task (it runs without admin rights).'
        $optFlags = '--keep-awake ' + $keepAwake
    } else {
        # as in the original: this elevated launcher starts DS4Windows and the strafe boost is applied at every logon
        $ds4Block = @(':: Start DS4Windows if it isn''t running yet, so there is something to boost', 'tasklist /FI "IMAGENAME eq DS4Windows.exe" | find /I "DS4Windows.exe" >nul', 'if errorlevel 1 (', ('    if exist "' + $exe + '" ('), ('        start "" "' + $exe + '"'), '    )', ')') -join "`r`n"
        $optFlags = '--strafe-boost ' + $strafe + ' --keep-awake ' + $keepAwake + ' --tuned-policy ' + $tunedPolicy
    }
    $bat = $bat.Replace('@@PROFILE@@', $profile).Replace('@@OPTEXE@@', $exeDst).Replace('@@DS4BLOCK@@', $ds4Block).Replace('@@OPTFLAGS@@', $optFlags)
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
    $sidecar = $tuned + '.kpekpes-sha256'
    if ($tunedPolicy -eq 'preserve-edits') {
        if (Test-Path -LiteralPath $tuned) {
            Write-Say '  a tuned profile already exists; it is kept as it is (your edits are never overwritten)' 'Green'
            if (Test-Path -LiteralPath $sidecar) {
                [void](Add-KEntry ('ownedfile|' + $tuned) @{ Type = 'ownedfile'; Path = $tuned; Sidecar = $sidecar })
            }
        } else {
            [void](Add-KEntry ('ownedfile|' + $tuned) @{ Type = 'ownedfile'; Path = $tuned; Sidecar = $sidecar })
            Write-Say '  the tuned profile is written once, then left alone if you edit it' 'Green'
        }
    } elseif (Test-Path -LiteralPath $tuned) {
        $bk = Join-Path $d.Backup ($name + '_tuned.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.xml')
        Copy-Item -LiteralPath $tuned -Destination $bk -Force
        [void](Add-KEntry ('filerestore|' + $tuned) @{ Type = 'filerestore'; Path = $tuned; Backup = $bk })
        Write-Say '  an older tuned profile existed; a backup copy was saved and is restored on Undo' 'Yellow'
    } else {
        [void](Add-KEntry ('file|' + $tuned) @{ Type = 'file'; Path = $tuned })
    }
    # Written ONCE here, while you watch, instead of by the elevated logon task every time: an elevated program
    # writing into a folder a normal account controls (the DS4Windows profile folder) can be redirected.
    # The exe's unpack folder points into the protected bin folder for the same reason.
    $tmpDir = Join-Path $d.Bin 'tmp'
    if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
    $oldTemp = $env:TEMP; $oldTmp = $env:TMP
    try {
        $env:TEMP = $tmpDir; $env:TMP = $tmpDir
        & $exeDst --profile $profile --strafe-boost $strafe --tuned-policy $tunedPolicy --write-only 2>&1 | ForEach-Object { Write-KLog ('tuned: ' + $_) }
    } finally { $env:TEMP = $oldTemp; $env:TMP = $oldTmp }

    if ($hard) { Write-Say '[6/7] Start at every logon (optimizer with admin rights; strafe boost and DS4Windows without)' 'Cyan' } else { Write-Say '[6/7] Start at every logon (with admin rights, as before)' 'Cyan' }
    $ds4Task = 'Kpekpes DS4Windows Start'
    if ($hard) {
        # DS4Windows usually lives in Downloads / Desktop, which any program running as you can change.
        # So it gets its own task with NORMAL rights: replacing it gains an attacker nothing they did not already have.
        [void](Add-KEntry ('task|' + $ds4Task) @{ Type = 'task'; Name = $ds4Task })
        $u0 = $env:USERDOMAIN + '\' + $env:USERNAME
        # first action: write the tuned profile (strafe boost) every logon, as the normal user; second: start DS4Windows
        $a0w = New-ScheduledTaskAction -Execute $exeDst -Argument ('--profile "' + $profile + '" --strafe-boost ' + $strafe + ' --tuned-policy ' + $tunedPolicy + ' --write-only')
        $a0s = New-ScheduledTaskAction -Execute $exe
        $a0 = @($a0w, $a0s)
        $tr0 = New-ScheduledTaskTrigger -AtLogOn -User $u0
        $p0 = New-ScheduledTaskPrincipal -UserId $u0 -LogonType Interactive -RunLevel Limited
        $s0 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $ds4Task -Action $a0 -Trigger $tr0 -Principal $p0 -Settings $s0 -Force -ErrorAction Stop | Out-Null
    } elseif ($dsMode -eq 'elevated' -and (Get-Command Test-KPathSafeForElevation -ErrorAction SilentlyContinue)) {
        $safe = Test-KPathSafeForElevation $exe
        if (-not $safe.Safe) { Write-Say ('  note: you forced DS4Windows to start with admin rights from a place normal programs can change (' + $safe.Reason + ').') 'Yellow' }
    }
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
    [void](Add-KEntry 'proc|controller' @{ Type = 'proc'; Pattern = ('*' + $script:CtlExeName + '*') })
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbsDst + '"')
    if ($hard -and -not (Get-Process -Name 'DS4Windows' -ErrorAction SilentlyContinue)) {
        try { Start-ScheduledTask -TaskName $ds4Task -ErrorAction Stop } catch { Write-KLog ('could not start DS4Windows: ' + $_.Exception.Message) 'WARN' }
    }
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

    $vbs = Join-Path $d.Bin 'run_hidden.vbs'
    foreach ($f in @($script:CtlExeName, 'controller_optimizer.bat', 'run_hidden.vbs')) {
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
        $tunedEdited = $false
        if ((Test-Path -LiteralPath $tuned) -and ([string]$Cfg.Controller.TunedProfilePolicy -eq 'preserve-edits')) {
            $sc = $tuned + '.kpekpes-sha256'
            if (Test-Path -LiteralPath $sc) {
                $want = (Get-Content -LiteralPath $sc -Raw -ErrorAction SilentlyContinue)
                if (-not $want -or $want.Trim().ToLower() -ne (Get-FileHash -LiteralPath $tuned -Algorithm SHA256).Hash.ToLower()) { $tunedEdited = $true }
            } else { $tunedEdited = $true }
        }
        if ($tunedEdited) { [void]$r.Add((New-KResult 'Tuned profile' 'INFO' 'your own edited copy is kept; strafe values are not checked' $g)) }
        elseif ((Test-Path -LiteralPath $tuned) -and $script:Strafe.ContainsKey($strafe)) {
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

    # a single-file program shows up as two processes with the same name (launcher + the program itself): count the top one only
    $all = @(Get-CimInstance Win32_Process -Filter ("Name='" + $script:CtlExeName + "'") -ErrorAction SilentlyContinue)
    $ids = @($all | ForEach-Object { $_.ProcessId })
    $run = @($all | Where-Object { $ids -notcontains $_.ParentProcessId })
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
    foreach ($m in $res.Manual) { Write-Say ('  note: ' + $m) 'Yellow' }
    Write-Say '  DS4Windows keeps running; its priority is back to normal.' 'Gray'
    return $res
}

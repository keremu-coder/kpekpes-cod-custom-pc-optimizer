# Core.ps1 -- shared helpers: paths, logging, config, protected install folder.
# Written for Windows PowerShell 5.1 (no ternary, no ??, no &&).

$script:AppName    = 'Kpekpes COD Custom PC Optimizer'
$script:AppVer     = '1.0.0'
$script:DataRoot   = Join-Path $env:ProgramData 'KpekpesCODCustom'
$script:AppDir     = Join-Path $script:DataRoot 'app'
$script:LogDir     = Join-Path $script:DataRoot 'logs'
$script:ConfigPath = Join-Path $script:DataRoot 'config.json'
$script:WhatIfMode = $false
$script:Quiet      = $false
$script:J          = $null

# ---------------- logging / console ----------------
function Write-KLog {
    param([string]$Msg, [string]$Level = 'INFO')
    if ($script:WhatIfMode) { return }   # what-if must not write anything
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
        $file = Join-Path $script:LogDir ((Get-Date -Format 'yyyy-MM-dd') + '.log')
        Add-Content -LiteralPath $file -Value $line -Encoding UTF8
    } catch { }
}

function Write-Say {
    param([string]$Text, [string]$Color = 'Gray')
    Write-KLog $Text
    if (-not $script:Quiet) { Write-Host $Text -ForegroundColor $Color }
}

function Write-Head {
    param([string]$Text)
    Write-Say ''
    Write-Say ('== ' + $Text + ' ==') 'Cyan'
}

function Test-KAdmin {
    try {
        $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# ---------------- config ----------------
function Get-KDefaultConfig {
    # Every switch defaults to your build (maximum). Flip one to $false in config.json to skip that group.
    $c = [ordered]@{
        GameProcessTweaks  = $true   # CPU/IO priority entries, GPU preference, QoS for cod.exe
        DefenderExclusions = $true   # exact-path exclusions for the game, Battle.net, DS4Windows
        WindowsUpdateBlock = $true   # no driver updates via Windows Update, no auto-reboot, no Store auto-download
        RemoveXboxApps     = $true   # Game Bar / Xbox overlay apps
        DisableServices    = $true   # SysMain, DiagTrack, WSearch and friends
        HvciOff            = $true   # Memory integrity / VBS off
        LogonReapply       = $true   # re-apply the PC tweaks at every logon
    }
    $ctl = [ordered]@{ DS4WindowsExe = ''; ProfileName = 'EUPHO'; StrafeBoost = 'max' }
    $c['Controller'] = $ctl
    return $c
}

function Get-KConfig {
    $cfg = Get-KDefaultConfig
    if (Test-Path -LiteralPath $script:ConfigPath) {
        try {
            $f = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                if ($k -eq 'Controller') {
                    if ($f.Controller) {
                        foreach ($ck in @($cfg['Controller'].Keys)) {
                            if ($null -ne $f.Controller.$ck) { $cfg['Controller'][$ck] = $f.Controller.$ck }
                        }
                    }
                } elseif ($null -ne $f.$k) {
                    $cfg[$k] = [bool]$f.$k
                }
            }
        } catch { Write-KLog ('config unreadable, using defaults: ' + $_.Exception.Message) 'WARN' }
    }
    return $cfg
}

function Save-KConfig {
    param($Cfg)
    if ($script:WhatIfMode) { return }
    try {
        $json = $Cfg | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object Text.UTF8Encoding($false)))
    } catch { Write-KLog ('could not save config: ' + $_.Exception.Message) 'WARN' }
}

# ---------------- protected folder ----------------
# Scheduled tasks here run elevated, so the scripts they run must not be editable by normal users.
function Protect-KDir {
    param([string]$Path)
    try {
        & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Initialize-KRoot {
    if ($script:WhatIfMode) { return $true }
    try {
        if (-not (Test-Path -LiteralPath $script:DataRoot)) { New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null }
        $ok = Protect-KDir $script:DataRoot
        if (-not $ok) { Write-KLog 'could not lock down the data folder ACL' 'WARN' }
        return $true
    } catch {
        Write-Say ('Cannot create ' + $script:DataRoot + ': ' + $_.Exception.Message) 'Red'
        return $false
    }
}

function Install-KApp {
    # Copy the program to the protected folder so scheduled tasks never run user-writable scripts.
    param([string]$SourceDir)
    if ($script:WhatIfMode) { return $true }
    try {
        if (-not (Initialize-KRoot)) { return $false }
        $src = (Resolve-Path -LiteralPath $SourceDir).Path.TrimEnd('\')
        $dst = $script:AppDir.TrimEnd('\')
        if ($src -ieq $dst) { return $true }
        if (-not (Test-Path -LiteralPath $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
        foreach ($item in @('Kpekpes.ps1', 'lib', 'modules', 'controller')) {
            $from = Join-Path $SourceDir $item
            if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $script:AppDir -Recurse -Force }
        }
        return $true
    } catch {
        Write-KLog ('app install failed: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Remove-KAppIfIdle {
    # Called after an undo. Removes the installed program copy when neither module is active any more.
    try {
        $active = $false
        foreach ($m in @('pc', 'controller')) {
            if (Test-Path -LiteralPath (Join-Path (Join-Path $script:DataRoot $m) 'journal.json')) { $active = $true }
        }
        if (-not $active -and (Test-Path -LiteralPath $script:AppDir)) {
            Remove-Item -LiteralPath $script:AppDir -Recurse -Force -ErrorAction Stop
            Write-Say 'Removed the installed program copy (nothing is active any more).' 'DarkGray'
        }
    } catch { Write-KLog ('could not remove app copy: ' + $_.Exception.Message) 'WARN' }
}

# ---------------- result model (used by every verify) ----------------
function New-KResult {
    param([string]$Name, [string]$State, [string]$Detail = '', [string]$Group = '', [bool]$Placebo = $false)
    return [pscustomobject]@{ Name = $Name; State = $State; Detail = $Detail; Group = $Group; Placebo = $Placebo }
}

function Get-KScore {
    # PASS / (PASS + FAIL). WARN and NA are reported but never counted as passes.
    param($Results)
    $all  = @($Results)
    $pass = @($all | Where-Object { $_.State -eq 'PASS' }).Count
    $fail = @($all | Where-Object { $_.State -eq 'FAIL' }).Count
    $warn = @($all | Where-Object { $_.State -eq 'WARN' }).Count
    $na   = @($all | Where-Object { $_.State -eq 'NA' }).Count
    $den  = $pass + $fail
    $pct  = 0
    if ($den -gt 0) { $pct = [int][math]::Round(($pass / $den) * 100) }
    return [pscustomobject]@{ Percent = $pct; Pass = $pass; Fail = $fail; Warn = $warn; NA = $na; Total = $den }
}

function Show-KResults {
    param($Results, [string]$Title, [switch]$Detailed)
    Write-Head $Title
    foreach ($r in @($Results)) {
        if (-not $Detailed -and $r.State -eq 'PASS') { continue }
        $color = 'Gray'
        if ($r.State -eq 'PASS') { $color = 'Green' }
        elseif ($r.State -eq 'FAIL') { $color = 'Red' }
        elseif ($r.State -eq 'WARN') { $color = 'Yellow' }
        elseif ($r.State -eq 'INFO') { $color = 'Cyan' }
        $line = '  [{0}] {1}' -f $r.State, $r.Name
        if ($r.Detail) { $line += '  - ' + $r.Detail }
        Write-Say $line $color
    }
    $s = Get-KScore $Results
    Write-Say ('  SCORE: {0}%  ({1} of {2} checks passed, {3} warnings, {4} not applicable)' -f $s.Percent, $s.Pass, $s.Total, $s.Warn, $s.NA) 'Yellow'
    return $s
}

<#
  Kpekpes COD Custom PC Optimizer
  By Jesus Kpekpes

  Two modules you can run together or on their own, and undo separately:
    PC          Windows tuning for Call of Duty (maximum profile), with a full undo journal.
    Controller  DS4Windows optimizer (timer, priority, strafe-boost profile).

  Examples (from an Administrator PowerShell):
    .\Kpekpes.ps1                                  menu
    .\Kpekpes.ps1 -Action Optimize -Module PC
    .\Kpekpes.ps1 -Action Optimize -Module Both
    .\Kpekpes.ps1 -Action Verify -Detailed         read-only
    .\Kpekpes.ps1 -Action Undo -Module Controller
    .\Kpekpes.ps1 -Action Optimize -Module PC -WhatIf   shows what it would do, changes nothing
    .\Kpekpes.ps1 -Action Compare -Before a.csv -After b.csv
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Optimize', 'Verify', 'Undo', 'Compare')][string]$Action = 'Menu',
    [ValidateSet('PC', 'Controller', 'Both')][string]$Module = 'Both',
    [switch]$Silent,
    [switch]$Reapply,
    [switch]$WhatIf,
    [switch]$Detailed,
    [string]$Before,
    [string]$After
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
. (Join-Path $root 'lib\Core.ps1')
. (Join-Path $root 'lib\Journal.ps1')
. (Join-Path $root 'lib\Checks.ps1')
. (Join-Path $root 'modules\Pc.ps1')
. (Join-Path $root 'modules\Controller.ps1')

$script:WhatIfMode = [bool]$WhatIf
$script:Quiet = $false
$script:Silent = [bool]$Silent

function Show-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Green
    Write-Host ('   ' + $script:AppName + '  v' + $script:AppVer) -ForegroundColor Green
    Write-Host '   By Jesus Kpekpes' -ForegroundColor DarkGreen
    Write-Host '  ============================================================' -ForegroundColor Green
    if ($script:WhatIfMode) { Write-Host '   WHAT-IF MODE: nothing will be changed' -ForegroundColor Yellow }
    Write-Host ''
}

function Invoke-OptimizeAction {
    param([string]$Which)
    $cfg = Get-KConfig
    if (-not (Initialize-KRoot)) { Write-Say 'Cannot create the data folder. Run as Administrator.' 'Red'; return }
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { Save-KConfig $cfg }
    if (-not (Install-KApp $root)) { Write-Say 'Warning: could not install the program copy; the logon task may not work.' 'Yellow' }

    if ($Which -eq 'PC' -or $Which -eq 'Both') {
        Write-Head 'PC optimizer (maximum profile)'
        try {
            $s = Invoke-PcOptimize $cfg -Reapply:$Reapply
            if ($s.Problems.Count -gt 0) {
                Write-Say '  Things that did not apply:' 'Yellow'
                foreach ($p in $s.Problems) { Write-Say ('    - ' + $p) 'Yellow' }
            }
        } catch { Write-Say ('PC optimizer stopped: ' + $_.Exception.Message) 'Red'; Write-KLog ($_ | Out-String) 'ERROR' }
    }
    if (($Which -eq 'Controller' -or $Which -eq 'Both') -and -not $Reapply) {
        Write-Head 'Controller optimizer'
        try {
            $r = Install-Controller $cfg $root
            if ($r.Ok) {
                Write-Say '  Controller optimizer installed.' 'Green'
                if ($r.Message) { Write-Say ('  ' + $r.Message) 'Cyan' }
                $res = Get-ControllerVerifyResults (Get-KConfig)
                [void](Show-KResults $res 'Controller - result' -Detailed:$Detailed)
            } else { Write-Say ('  Controller optimizer not installed: ' + $r.Message) 'Red' }
        } catch { Write-Say ('Controller optimizer stopped: ' + $_.Exception.Message) 'Red'; Write-KLog ($_ | Out-String) 'ERROR' }
    }
    if (-not $Reapply -and -not $script:WhatIfMode) { Write-Say '' ; Write-Say 'Done. Restart Windows once so every setting takes effect.' 'Yellow' }
}

function Invoke-VerifyAction {
    param([string]$Which)
    $cfg = Get-KConfig
    if ($Which -eq 'PC' -or $Which -eq 'Both') {
        $res = Get-PcVerifyResults $cfg
        [void](Show-KResults $res 'PC optimizer - state' -Detailed:$Detailed)
        $ready = Get-ReadinessChecks
        Write-Head 'Readiness (read-only, not part of the score)'
        foreach ($x in $ready) {
            $c = 'Gray'
            if ($x.State -eq 'PASS') { $c = 'Green' } elseif ($x.State -eq 'FAIL') { $c = 'Red' } elseif ($x.State -eq 'WARN') { $c = 'Yellow' } elseif ($x.State -eq 'INFO') { $c = 'Cyan' }
            $line = '  [{0}] {1}' -f $x.State, $x.Name
            if ($x.Detail) { $line += '  - ' + $x.Detail }
            Write-Say $line $c
        }
    }
    if ($Which -eq 'Controller' -or $Which -eq 'Both') {
        $res = Get-ControllerVerifyResults $cfg
        [void](Show-KResults $res 'Controller - state' -Detailed:$Detailed)
    }
}

function Invoke-UndoAction {
    param([string]$Which)
    if (-not $script:Silent -and -not $script:WhatIfMode) {
        $a = Read-Host ('Undo ' + $Which + '? This puts every recorded change back. (y/n)')
        if ($a -notmatch '^(y|yes)$') { Write-Say 'Cancelled.' 'Yellow'; return }
    }
    if ($Which -eq 'Controller' -or $Which -eq 'Both') { try { [void](Invoke-ControllerUndo) } catch { Write-Say ('Controller undo error: ' + $_.Exception.Message) 'Red' } }
    if ($Which -eq 'PC' -or $Which -eq 'Both') { try { [void](Invoke-PcUndo) } catch { Write-Say ('PC undo error: ' + $_.Exception.Message) 'Red' } }
    Remove-KAppIfIdle
}

function Invoke-CompareAction {
    param([string]$B, [string]$A)
    if (-not $B) { $B = (Read-Host 'Path to the BEFORE capture (CSV from PresentMon or CapFrameX)').Trim('"') }
    if (-not $A) { $A = (Read-Host 'Path to the AFTER capture (CSV)').Trim('"') }
    try {
        $c = Compare-FrameCaptures $B $A
        Write-Head 'Frame capture comparison'
        $c.Rows | Format-Table -AutoSize | Out-String | Write-Host
        Write-Host ('  frames: before {0}, after {1}' -f $c.Before.Frames, $c.After.Frames) -ForegroundColor DarkGray
        Write-Host '  1% / 0.1% low = FPS of the average of the slowest 1% / 0.1% of frames.' -ForegroundColor DarkGray
    } catch { Write-Host ('Compare failed: ' + $_.Exception.Message) -ForegroundColor Red }
}

function Read-ModuleChoice {
    param([string]$Verb)
    Write-Host ('  ' + $Verb + ' which part?   1) PC   2) Controller   3) Both') -ForegroundColor Gray
    $c = Read-Host '  choice'
    if ($c -eq '1') { return 'PC' } elseif ($c -eq '2') { return 'Controller' } elseif ($c -eq '3') { return 'Both' }
    return ''
}

function Show-Menu {
    while ($true) {
        Show-Banner
        Write-Host '   1) Optimize PC' -ForegroundColor White
        Write-Host '   2) Optimize Controller (DS4Windows)' -ForegroundColor White
        Write-Host '   3) Optimize BOTH (PC first, then Controller)' -ForegroundColor White
        Write-Host '   4) Verify - read-only report and score' -ForegroundColor White
        Write-Host '   5) Undo PC' -ForegroundColor White
        Write-Host '   6) Undo Controller' -ForegroundColor White
        Write-Host '   7) Undo BOTH' -ForegroundColor White
        Write-Host '   8) Compare two frame captures (before / after FPS)' -ForegroundColor White
        Write-Host '   0) Exit' -ForegroundColor White
        Write-Host ''
        $c = Read-Host '  choice'
        if ($c -eq '0') { return }
        elseif ($c -eq '1') { Invoke-OptimizeAction 'PC' }
        elseif ($c -eq '2') { Invoke-OptimizeAction 'Controller' }
        elseif ($c -eq '3') { Invoke-OptimizeAction 'Both' }
        elseif ($c -eq '4') { $w = Read-ModuleChoice 'Verify'; if ($w) { Invoke-VerifyAction $w } }
        elseif ($c -eq '5') { Invoke-UndoAction 'PC' }
        elseif ($c -eq '6') { Invoke-UndoAction 'Controller' }
        elseif ($c -eq '7') { Invoke-UndoAction 'Both' }
        elseif ($c -eq '8') { Invoke-CompareAction '' '' }
        else { continue }
        Write-Host ''
        [void](Read-Host '  Press Enter to return to the menu')
    }
}

# ---------------- main ----------------
if ($Action -eq 'Compare') {
    Invoke-CompareAction $Before $After
    return
}

if (-not (Test-KAdmin)) {
    Write-Host 'This tool must run as Administrator. Use Run_Kpekpes.bat (it asks Windows for admin rights).' -ForegroundColor Red
    exit 1
}

if ($Reapply) {
    if (Test-Path -LiteralPath (Join-Path $script:DataRoot 'PAUSE')) {
        Write-KLog 'PAUSE file present - logon re-apply skipped'
        return
    }
    $script:Quiet = $true
}

if ($Action -eq 'Menu') { Show-Menu }
elseif ($Action -eq 'Optimize') { Invoke-OptimizeAction $Module }
elseif ($Action -eq 'Verify') { Invoke-VerifyAction $Module }
elseif ($Action -eq 'Undo') { Invoke-UndoAction $Module }

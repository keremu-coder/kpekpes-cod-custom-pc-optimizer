# Test-Logic.ps1 -- tests for the parts that do not need Windows (journal, config, scoring, XML edits,
# frame-capture maths, templates). Run:  pwsh tests/Test-Logic.ps1   (or powershell.exe on Windows)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('kpekpes-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$env:ProgramData = $tmp

. (Join-Path $repo 'lib\Core.ps1')
. (Join-Path $repo 'lib\Journal.ps1')
. (Join-Path $repo 'lib\Checks.ps1')
. (Join-Path $repo 'lib\Stats.ps1')
. (Join-Path $repo 'lib\Safety.ps1')
. (Join-Path $repo 'lib\Topology.ps1')
. (Join-Path $repo 'modules\Pc.ps1')
. (Join-Path $repo 'modules\Controller.ps1')

$script:pass = 0; $script:fail = 0
function Assert-That {
    param([string]$Name, [bool]$Cond, [string]$Info = '')
    if ($Cond) { $script:pass++; Write-Host ('  ok    ' + $Name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ('  FAIL  ' + $Name + '  ' + $Info) -ForegroundColor Red }
}

Write-Host 'DWord conversion'
Assert-That '0xFFFFFFFF -> -1' ((ConvertTo-RegInt 0xFFFFFFFF) -eq -1)
Assert-That '4294967295 -> -1' ((ConvertTo-RegInt 4294967295) -eq -1)
Assert-That '1 -> 1' ((ConvertTo-RegInt 1) -eq 1)
Assert-That '0x2222 -> 8738' ((ConvertTo-RegInt 0x2222) -eq 8738)
Assert-That 'DWord equality across signed/unsigned' (Test-RegValueEquals -1 4294967295 'DWord')
Assert-That 'Binary equality' (Test-RegValueEquals ([byte[]](1, 2, 3)) ([byte[]](1, 2, 3)) 'Binary')
Assert-That 'Binary inequality' (-not (Test-RegValueEquals ([byte[]](1, 2, 3)) ([byte[]](1, 2, 4)) 'Binary'))
Assert-That 'String equality ignores case' (Test-RegValueEquals 'High' 'high' 'String')
Assert-That 'null never equals' (-not (Test-RegValueEquals $null 1 'DWord'))

Write-Host 'DWord conversion safety'
Assert-That 'text where a number is expected does not crash and does not match' ((Test-RegValueEquals 'kpk1' 1 'DWord') -eq $false)
Assert-That 'a number where bytes are expected does not crash and does not match' ((Test-RegValueEquals 5 ([byte[]]@(1,2)) 'Binary') -eq $false)
Write-Host 'Score'
$res = @(
    (New-KResult 'a' 'PASS'), (New-KResult 'b' 'PASS'), (New-KResult 'c' 'FAIL'),
    (New-KResult 'd' 'WARN'), (New-KResult 'e' 'NA'), (New-KResult 'f' 'INFO')
)
$s = Get-KScore $res
Assert-That 'NA, WARN, INFO are not counted as passes' ($s.Pass -eq 2 -and $s.Fail -eq 1 -and $s.Total -eq 3)
Assert-That 'percent = 67' ($s.Percent -eq 67)
Assert-That 'empty list scores 0, no crash' ((Get-KScore @()).Percent -eq 0)

Write-Host 'Journal: first state is kept forever'
Open-KJournal 'test'
Assert-That 'new entry recorded' (Add-KEntry 'reg|HKLM:\X|A' @{ Type = 'reg'; Path = 'HKLM:\X'; Name = 'A'; Existed = $true; Kind = 'DWord'; Value = 5 })
Assert-That 'second record of the same item is ignored' (-not (Add-KEntry 'reg|HKLM:\X|A' @{ Type = 'reg'; Path = 'HKLM:\X'; Name = 'A'; Existed = $true; Kind = 'DWord'; Value = 99 }))
[void](Add-KEntry 'reg|HKLM:\X|B' @{ Type = 'reg'; Path = 'HKLM:\X'; Name = 'B'; Existed = $false; Kind = $null; Value = $null })
[void](Add-KEntry 'power|plan' @{ Type = 'powerscheme'; OriginalGuid = 'orig'; OurGuid = 'ours' })
Update-KEntry 'power|plan' 'OurGuid' 'ours2'
$script:J = $null
Open-KJournal 'test'
$e = Get-KEntry 'reg|HKLM:\X|A'
Assert-That 'journal survives a restart' ($null -ne $e)
Assert-That 'original value kept (5, not 99)' ([int]$e.Value -eq 5)
Assert-That 'missing-before is remembered' ((Get-KEntry 'reg|HKLM:\X|B').Existed -eq $false)
Assert-That 'entry update persisted' ((Get-KEntry 'power|plan').OurGuid -eq 'ours2')
Assert-That 'order preserved (3 entries)' (@($script:J.Entries).Count -eq 3 -and $script:J.Entries[0].Id -eq 'reg|HKLM:\X|A')

Write-Host 'Journal: binary and multi-string values round-trip through JSON'
$hex = ConvertTo-JsonSafe ([byte[]](0x90, 0x12, 0x03)) 'Binary'
Assert-That 'binary stored as hex' ($hex -eq '90-12-03')
$back = [byte[]]@($hex -split '-' | ForEach-Object { [Convert]::ToByte($_, 16) })
Assert-That 'binary restored exactly' (([BitConverter]::ToString($back)) -eq '90-12-03')
Assert-That 'empty binary handled' ((ConvertTo-JsonSafe ([byte[]]@()) 'Binary') -eq '')

Write-Host 'WhatIf writes nothing'
$script:WhatIfMode = $true
$before = @($script:J.Entries).Count
Assert-That 'whatif does not journal' (-not (Add-KEntry 'reg|HKLM:\X|C' @{ Type = 'reg' }))
Assert-That 'whatif does not add entries' (@($script:J.Entries).Count -eq $before)
$script:WhatIfMode = $false

Write-Host 'Config merge'
Initialize-KRoot | Out-Null
Set-Content -LiteralPath $script:ConfigPath -Value '{ "DefenderExclusions": false, "Controller": { "StrafeBoost": "strong" } }' -Encoding UTF8
$c = Get-KConfig
Assert-That 'overridden switch is read' ($c.DefenderExclusions -eq $false)
Assert-That 'missing switches keep defaults' ($c.LogonReapply -eq $true -and $c.DisableServices -eq $true)
Assert-That 'risky switches are OFF by default' ($c.HvciOff -eq $false -and $c.DisableToastNotifications -eq $false -and $c.UsePlatformTick -eq $false -and $c.ReapplyUserPreferences -eq $false)
Assert-That 'controller safe defaults' ($c.Controller.KeepAwake -eq 'games' -and $c.Controller.TunedProfilePolicy -eq 'preserve-edits')
Set-Content -LiteralPath $script:ConfigPath -Value '{ "Controller": { "KeepAwake": "bogus", "TunedProfilePolicy": "nope" } }' -Encoding UTF8
$cb = Get-KConfig
Assert-That 'invalid choice values fall back to safe defaults' ($cb.Controller.KeepAwake -eq 'games' -and $cb.Controller.TunedProfilePolicy -eq 'preserve-edits')
Set-Content -LiteralPath $script:ConfigPath -Value '{ "DefenderExclusions": false, "Controller": { "StrafeBoost": "strong" } }' -Encoding UTF8
Assert-That 'nested value overridden' ($c.Controller.StrafeBoost -eq 'strong')
Assert-That 'nested defaults kept' ($c.Controller.ProfileName -eq 'EUPHO')
Remove-Item -LiteralPath $script:ConfigPath -Force
Assert-That 'defaults without a file: Game Mode group etc. on' ((Get-KConfig).GameProcessTweaks -eq $true)

Write-Host 'Frame capture maths'
function New-Csv {
    param([string]$Path, [double[]]$Times)
    $lines = @('Application,MsBetweenPresents')
    foreach ($t in $Times) { $lines += ('cod.exe,' + $t.ToString([Globalization.CultureInfo]::InvariantCulture)) }
    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}
$a = New-Object 'System.Collections.Generic.List[double]'
for ($i = 0; $i -lt 990; $i++) { $a.Add(10.0) }
for ($i = 0; $i -lt 10; $i++) { $a.Add(50.0) }
$p1 = Join-Path $tmp 'before.csv'; New-Csv $p1 $a.ToArray()
$b = New-Object 'System.Collections.Generic.List[double]'
for ($i = 0; $i -lt 990; $i++) { $b.Add(8.0) }
for ($i = 0; $i -lt 10; $i++) { $b.Add(20.0) }
$p2 = Join-Path $tmp 'after.csv'; New-Csv $p2 $b.ToArray()
$st = Get-FrameStats (Import-FrameTimes $p1)
Assert-That 'avg fps = 1000 / mean (10.4 ms -> 96.2)' ($st.AvgFps -eq 96.2) ([string]$st.AvgFps)
Assert-That '1% low = fps of the slowest 1% (10 x 50 ms -> 20.0)' ($st.Low1Fps -eq 20.0) ([string]$st.Low1Fps)
$cmp = Compare-FrameCaptures $p1 $p2
$avg = $cmp.Rows | Where-Object { $_.Metric -eq 'Average FPS' }
Assert-That 'after is faster' ($cmp.After.AvgFps -gt $cmp.Before.AvgFps)
Assert-That 'change is shown with a sign' ($avg.Change -match '^\+')
$thrown = $false
try { Import-FrameTimes (Join-Path $tmp 'nope.csv') | Out-Null } catch { $thrown = $true }
Assert-That 'missing file gives a clear error' $thrown
Set-Content -LiteralPath (Join-Path $tmp 'short.csv') -Value @('MsBetweenPresents', '10', '11') -Encoding UTF8
$thrown = $false
try { Import-FrameTimes (Join-Path $tmp 'short.csv') | Out-Null } catch { $thrown = $true }
Assert-That 'too-short capture is rejected' $thrown
Set-Content -LiteralPath (Join-Path $tmp 'nocol.csv') -Value @('Foo,Bar', '1,2') -Encoding UTF8
$thrown = $false
try { Import-FrameTimes (Join-Path $tmp 'nocol.csv') | Out-Null } catch { $thrown = $true }
Assert-That 'file without a frame-time column is rejected' $thrown

Write-Host 'Several captures per side, with intervals'
$rng = New-Object System.Random 7
$bf = @(); $af = @()
for ($r = 0; $r -lt 5; $r++) {
    $tb = New-Object 'System.Collections.Generic.List[double]'; $ta = New-Object 'System.Collections.Generic.List[double]'
    for ($i = 0; $i -lt 600; $i++) { $tb.Add(10.0 + $rng.NextDouble() * 0.4); $ta.Add(8.0 + $rng.NextDouble() * 0.4) }
    $pb = Join-Path $tmp ('b' + $r + '.csv'); New-Csv $pb $tb.ToArray(); $bf += $pb
    $pa = Join-Path $tmp ('a' + $r + '.csv'); New-Csv $pa $ta.ToArray(); $af += $pa
}
$set = Compare-FrameCaptureSets $bf $af
$avgRow = $set.Rows | Where-Object { $_.Metric -eq 'Average FPS' }
Assert-That '5 vs 5 captures: a real 25 % gain is called better' ($avgRow.Verdict -eq 'better' -and $avgRow.ChangePct -gt 20) ($avgRow | Out-String)
$aa = Compare-FrameCaptureSets $bf[0..2] $bf[2..4]
Assert-That 'same config vs itself is never called better or worse' (@($aa.Rows | Where-Object { $_.Metric -eq 'Average FPS' -and $_.Verdict -match '^(better|worse)$' }).Count -eq 0) (($aa.Rows | Out-String))
Set-Content -LiteralPath (Join-Path $tmp 'both.csv') -Value @('MsBetweenPresents,MsBetweenDisplayChange', '10,0', '10,20') -Encoding UTF8
Assert-That 'displayed-frame column is preferred over present-to-present' ((Get-Command Import-FrameTimes).ScriptBlock.ToString() -match "@\('MsBetweenDisplayChange'")

Write-Host 'DS4 profile edits touch only LaunchProgram'
$prof = Join-Path $tmp 'EUPHO.xml'
Copy-Item -LiteralPath (Join-Path $repo 'controller\profiles\EUPHO.xml') -Destination $prof
$orig = [IO.File]::ReadAllBytes($prof)
$old = Get-XmlTagText $prof 'LaunchProgram'
Assert-That 'LaunchProgram is readable' ($null -ne $old -and $old.Length -gt 0)
Assert-That 'set returns true' (Set-XmlTagText $prof 'LaunchProgram' 'C:\Test\run_hidden.vbs')
Assert-That 'new value is in place' ((Get-XmlTagText $prof 'LaunchProgram') -eq 'C:\Test\run_hidden.vbs')
$e2 = [pscustomobject]@{ Path = $prof; Tag = 'LaunchProgram'; Old = $old }
Assert-That 'restore returns true' (Restore-XmlTextEntry $e2)
$restored = [IO.File]::ReadAllBytes($prof)
Assert-That 'file is byte-identical after set + restore' (([BitConverter]::ToString($orig)) -eq ([BitConverter]::ToString($restored)))
Assert-That 'missing tag returns false (no crash)' (-not (Set-XmlTagText $prof 'NoSuchTag' 'x'))

Write-Host 'Bundled profile and tuned copy (tests the optimizer source module; Python exists on the CI runner only, the built exe is smoke-tested in build-exe.yml)'
$py = $null
foreach ($n in @('python3', 'python')) { if (-not $py -and (Get-Command $n -ErrorAction SilentlyContinue)) { $py = $n } }
# Runs a python helper with a hard time limit. Returns @{ ExitCode; Output; TimedOut }.
function Invoke-PyHelper {
    param([string]$Python, [string]$HelperPath, [string[]]$HelperArgs, [int]$TimeoutSec = 30)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command $Python).Source
    $q = @(); foreach ($x in (@($HelperPath) + $HelperArgs)) { $q += ('"' + $x + '"') }
    $psi.Arguments = ($q -join ' ')
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
    $done = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $done) { try { $p.Kill() } catch { } ; return @{ ExitCode = -1; Output = ''; TimedOut = $true } }
    $p.WaitForExit()
    return @{ ExitCode = $p.ExitCode; Output = ($outTask.Result + $errTask.Result); TimedOut = $false }
}
if ($py) {
    $work = Join-Path $tmp 'tuned'; New-Item -ItemType Directory -Path $work | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'controller\profiles\EUPHO.xml') -Destination (Join-Path $work 'EUPHO.xml')
    # helper: import the optimizer as a module and call write_tuned only (main() / the watch loop is never started)
    $helper = Join-Path $tmp 'tuned_helper.py'
    $helperSrc = @'
import argparse, importlib.util, sys
spec = importlib.util.spec_from_file_location("ds4opt", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
profile, strafe, policy = sys.argv[2], sys.argv[3], sys.argv[4]
a = argparse.Namespace(rs_deadzone=None, rs_antideadzone=None, rs_maxzone=None, ls_deadzone=None,
                       strafe_boost=strafe, tuned_policy=policy)
m.write_tuned(profile, a)
'@
    [IO.File]::WriteAllText($helper, $helperSrc, (New-Object Text.UTF8Encoding($false)))
    $optPy = Join-Path $repo 'controller\ds4_optimize_final.py'
    $profPath = Join-Path $work 'EUPHO.xml'
    $r1 = Invoke-PyHelper $py $helper @($optPy, $profPath, 'max', 'overwrite') 30
    Assert-That 'helper finished (no hang)' (-not $r1.TimedOut) 'timed out'
    $tuned = Join-Path $work 'EUPHO_tuned.xml'
    Assert-That 'tuned copy is written' (Test-Path -LiteralPath $tuned)
    $x = [xml](Get-Content -LiteralPath $tuned -Raw)
    $ax = $x.SelectSingleNode('//LSAxialDeadOptions')
    Assert-That 'strafe boost max = 16 / 40 on LS X' ([int]$ax.AntiDeadZoneX -eq 16 -and [int]$ax.MaxZoneX -eq 40)
    $o = [xml](Get-Content -LiteralPath $profPath -Raw)
    Assert-That 'right stick curve untouched' ($x.SelectSingleNode('//RSOutputCurveCustom').InnerText -eq $o.SelectSingleNode('//RSOutputCurveCustom').InnerText)
    Assert-That 'right stick dead zones untouched' ($x.SelectSingleNode('//RSAntiDeadZone').InnerText -eq $o.SelectSingleNode('//RSAntiDeadZone').InnerText)
    Assert-That 'left stick curve untouched' ($x.SelectSingleNode('//LSOutputCurveCustom').InnerText -eq $o.SelectSingleNode('//LSOutputCurveCustom').InnerText)
    Assert-That 'original profile not modified' ((Get-FileHash $profPath).Hash -eq (Get-FileHash (Join-Path $repo 'controller\profiles\EUPHO.xml')).Hash)
    Assert-That 'overwrite policy writes no sidecar' (-not (Test-Path -LiteralPath ($tuned + '.kpekpes-sha256')))

    # preserve-edits policy
    Remove-Item -LiteralPath $tuned -Force
    [void](Invoke-PyHelper $py $helper @($optPy, $profPath, 'max', 'preserve-edits') 30)
    $side = $tuned + '.kpekpes-sha256'
    Assert-That 'preserve-edits writes tuned copy + sidecar hash' ((Test-Path -LiteralPath $tuned) -and (Test-Path -LiteralPath $side))
    Assert-That 'sidecar holds the file hash' ((Get-Content -LiteralPath $side -Raw).Trim().ToLower() -eq (Get-FileHash -LiteralPath $tuned -Algorithm SHA256).Hash.ToLower())
    $h1 = (Get-FileHash -LiteralPath $tuned).Hash
    [void](Invoke-PyHelper $py $helper @($optPy, $profPath, 'strong', 'preserve-edits') 30)
    $ax2 = ([xml](Get-Content -LiteralPath $tuned -Raw)).SelectSingleNode('//LSAxialDeadOptions')
    Assert-That 'untouched generated file IS regenerated (strong = 10 / 48)' ([int]$ax2.AntiDeadZoneX -eq 10 -and [int]$ax2.MaxZoneX -eq 48)
    # the user edits it
    $edited = (Get-Content -LiteralPath $tuned -Raw).Replace('<LSAxialDeadOptions>', '<!-- my edit --><LSAxialDeadOptions>')
    [IO.File]::WriteAllText($tuned, $edited, (New-Object Text.UTF8Encoding($false)))
    $hEdit = (Get-FileHash -LiteralPath $tuned).Hash
    $r3 = Invoke-PyHelper $py $helper @($optPy, $profPath, 'max', 'preserve-edits') 30
    Assert-That 'edited tuned file is NOT overwritten' ((Get-FileHash -LiteralPath $tuned).Hash -eq $hEdit)
    Assert-That 'script says it kept the edited file' ($r3.Output -match 'Kept your edited')
    # a pre-existing tuned file with no sidecar counts as the user's
    Remove-Item -LiteralPath $side -Force
    [void](Invoke-PyHelper $py $helper @($optPy, $profPath, 'max', 'preserve-edits') 30)
    Assert-That 'tuned file without sidecar is treated as yours (kept)' ((Get-FileHash -LiteralPath $tuned).Hash -eq $hEdit)
    # overwrite policy (old behaviour) still overwrites
    [void](Invoke-PyHelper $py $helper @($optPy, $profPath, 'max', 'overwrite') 30)
    Assert-That 'overwrite policy keeps the old behaviour' ((Get-FileHash -LiteralPath $tuned).Hash -ne $hEdit)

    # CLI flags exist (help text only; argparse exits, nothing endless)
    $rh = Invoke-PyHelper $py $optPy @('--help') 20
    Assert-That '--help exits (never loops)' (-not $rh.TimedOut)
    Assert-That '--keep-awake and --tuned-policy are offered' ($rh.Output -match '--keep-awake' -and $rh.Output -match '--tuned-policy')
} else { Write-Host '  (python not found, skipped)' -ForegroundColor Yellow }

Write-Host 'Owned-file undo (tuned profile)'
$ow = Join-Path $tmp 'owned'; New-Item -ItemType Directory -Path $ow | Out-Null
$of = Join-Path $ow 'X_tuned.xml'; $os = $of + '.kpekpes-sha256'
Set-Content -LiteralPath $of -Value 'generated' -NoNewline
Set-Content -LiteralPath $os -Value (Get-FileHash -LiteralPath $of -Algorithm SHA256).Hash.ToLower() -NoNewline
$oe = [pscustomobject]@{ Path = $of; Sidecar = $os }
Assert-That 'unchanged generated file is removed' ((Restore-OwnedFileEntry $oe) -eq 'ok' -and -not (Test-Path -LiteralPath $of) -and -not (Test-Path -LiteralPath $os))
Set-Content -LiteralPath $of -Value 'generated' -NoNewline
Set-Content -LiteralPath $os -Value (Get-FileHash -LiteralPath $of -Algorithm SHA256).Hash.ToLower() -NoNewline
Set-Content -LiteralPath $of -Value 'generated + my edit' -NoNewline
Assert-That 'edited file is kept, not deleted' ((Restore-OwnedFileEntry $oe) -eq 'kept' -and (Test-Path -LiteralPath $of))

Write-Host 'Launcher templates'
$bat = Get-Content -LiteralPath (Join-Path $repo 'controller\controller_optimizer.bat.template') -Raw
foreach ($tok in @('@@PROFILE@@', '@@OPTEXE@@', '@@DS4BLOCK@@', '@@OPTFLAGS@@')) { Assert-That ('bat template has ' + $tok) ($bat.Contains($tok)) }
$gen = $bat.Replace('@@PROFILE@@', 'C:\p\EUPHO.xml').Replace('@@OPTEXE@@', 'C:\ProgramData\KpekpesCODCustom\controller\bin\KpekpesPCOptimizer.exe').Replace('@@DS4BLOCK@@', ':: ds4').Replace('@@OPTFLAGS@@', '--strafe-boost max --keep-awake games --tuned-policy overwrite')
Assert-That 'launcher has no hard-coded DS4Windows start (it is built per mode)' (-not $bat.Contains('@@DS4EXE@@') -and -not ($bat -match '(?im)^\s*start\b'))
$ctlSrc = (Get-Command Install-Controller).ScriptBlock.ToString()
Assert-That 'DS4Windows gets its own NON-elevated logon task' ($ctlSrc -match "Kpekpes DS4Windows Start" -and $ctlSrc -match 'RunLevel Limited')
Assert-That 'tuned profile is also written at install with --write-only' ($ctlSrc -match '--write-only')
Assert-That 'DS4Elevation defaults to auto and the boost is written at every logon in both modes' (((Get-KDefaultConfig).Controller.DS4Elevation -eq 'auto') -and $ctlSrc.Contains('--strafe-boost') -and $ctlSrc.Contains('--write-only') -and $ctlSrc.Contains('--tuned-policy'))
Assert-That 'no placeholder left after generation' (-not $gen.Contains('@@'))
Assert-That 'bat keeps the duplicate-run guard' ($gen -match "Name -eq 'KpekpesPCOptimizer\.exe'")
Assert-That 'bat starts the program by its full path, not PATH lookup' ($gen -match '(?m)^"C:\\ProgramData\\KpekpesCODCustom\\controller\\bin\\KpekpesPCOptimizer\.exe" --profile' -and -not ($gen -match '(?i)python'))
Assert-That 'bat sends the unpack folder to the protected folder' ($gen -match 'set "TEMP=%~dp0tmp"' -and $gen -match 'set "TMP=%~dp0tmp"')
$vi = Get-Content -LiteralPath (Join-Path $repo 'controller\version_info.txt') -Raw
$missing = @('CompanyName','FileDescription','FileVersion','LegalCopyright','ProductName','ProductVersion','OriginalFilename') | Where-Object { $vi -notmatch ("StringStruct\('" + $_ + "', '[^']+'\)") }
Assert-That 'version resource file has every field' (@($missing).Count -eq 0) ($missing -join ', ')
Assert-That 'bat passes the keep-awake flag' ($gen -match '--keep-awake games')
Assert-That 'no personal path in the template' (-not ($bat -match 'kerem'))
Assert-That 'vbs template has a placeholder' ((Get-Content -LiteralPath (Join-Path $repo 'controller\run_hidden.vbs.template') -Raw).Contains('@@BAT@@'))

Write-Host 'Tweak table sanity'
$cfg = Get-KDefaultConfig
function Test-HasNvidia { return $true }
$tw = Get-PcRegTweaks $cfg
$keys = @($tw | ForEach-Object { $_.Path + '|' + $_.Name })
Assert-That 'no duplicate registry targets' ((@($keys | Select-Object -Unique)).Count -eq $keys.Count)
$script:CpuPolicyCache = Get-KCpuPolicy '13th Gen Intel(R) Core(TM) i7-13700K' 1
Assert-That 'default: Game Mode off on a normal CPU (as in 1.1)' ((@(Get-PcRegTweaks $cfg | Where-Object { $_.Name -eq 'AutoGameModeEnabled' })[0].Value) -eq 0)
$script:CpuPolicyCache = Get-KCpuPolicy 'AMD Ryzen 9 7950X3D 16-Core Processor' 2
Assert-That 'Game Mode is left alone on a dual-CCD X3D' (-not (@(Get-PcRegTweaks $cfg | Where-Object { $_.Name -eq 'AutoGameModeEnabled' }).Count -gt 0))
$script:CpuPolicyCache = $null
Assert-That 'no write to the GPU driver class key' (-not (@($tw | Where-Object { $_.Path -match 'Control\\Class\\\{4d36e968' }).Count -gt 0))
Assert-That 'no PowerMizer / PerfLevelSrc values' (-not (@($tw | Where-Object { $_.Name -match 'PowerMizer|PerfLevelSrc|DisableDynamicPstate' }).Count -gt 0))
$cfg2 = Get-KDefaultConfig; $cfg2.WindowsUpdateBlock = $false; $cfg2.HvciOff = $false; $cfg2.GameProcessTweaks = $false
$tw2 = Get-PcRegTweaks $cfg2
Assert-That 'config switch removes the Windows Update group' (-not (@($tw2 | Where-Object { $_.Group -eq 'Windows Update control' }).Count -gt 0))
Assert-That 'config switch removes the memory-integrity group' (-not (@($tw2 | Where-Object { $_.Group -eq 'Memory integrity' }).Count -gt 0))
Assert-That 'config switch removes the game-process group' (-not (@($tw2 | Where-Object { $_.Group -eq 'Game process' }).Count -gt 0))

Assert-That 'default: toast tweak is NOT applied' (-not (@($tw | Where-Object { $_.Name -eq 'ToastEnabled' }).Count -gt 0))
Assert-That 'default: memory-integrity group is NOT applied' (-not (@($tw | Where-Object { $_.Group -eq 'Memory integrity' }).Count -gt 0))
$cfg3 = Get-KDefaultConfig; $cfg3.DisableToastNotifications = $true; $cfg3.HvciOff = $true
$tw3 = Get-PcRegTweaks $cfg3
Assert-That 'opt-in toast switch adds the tweak' (@($tw3 | Where-Object { $_.Name -eq 'ToastEnabled' }).Count -eq 1)
Assert-That 'opt-in HvciOff switch adds the group' (@($tw3 | Where-Object { $_.Group -eq 'Memory integrity' }).Count -gt 0)

Write-Host 'Service restore: delayed flag + hibernate + shadow storage parsing'
Assert-That 'service restore function handles the delayed flag' ((Get-Command Restore-ServiceEntry).ScriptBlock.ToString() -match 'DelayedAutostart')
Assert-That 'hibernate restore knows Existed (exact restore)' ((Get-Command Restore-HibernateEntry).ScriptBlock.ToString() -match 'Existed')
$vss1 = "vssadmin 1.1`r`nShadow Copy Storage association`r`n   For volume: (C:)\\?\Volume{abc}\`r`n   Maximum Shadow Copy Storage space: 10 GB (2%)`r`n"
$pv = ConvertFrom-VssStorageText $vss1 'C:'
Assert-That 'vss text: size parsed (2%)' ($pv.Known -and $pv.Had -and $pv.Percent -eq 2 -and -not $pv.Unbounded)
$pv2 = ConvertFrom-VssStorageText "Shadow Copy Storage association`r`n   For volume: (C:)\x`r`n   Maximum Shadow Copy Storage space: UNBOUNDED (100%)`r`n" 'C:'
Assert-That 'vss text: UNBOUNDED parsed' ($pv2.Had -and $pv2.Unbounded)
$pv3 = ConvertFrom-VssStorageText "No items found that satisfy the query." 'C:'
Assert-That 'vss text: no association = Known, not Had' ($pv3.Known -and -not $pv3.Had)
$pv4 = ConvertFrom-VssStorageText 'garbled or localized output' 'C:'
Assert-That 'vss text: unreadable = not Known (nothing will be changed)' (-not $pv4.Known)

Write-Host 'Undo engine (file-level entries, end to end)'
$u = Join-Path $tmp 'undo'; New-Item -ItemType Directory -Path $u -Force | Out-Null
$f1 = Join-Path $u 'created-by-us.txt'; Set-Content -LiteralPath $f1 -Value 'x'
$d1 = Join-Path $u 'bin'; New-Item -ItemType Directory -Path $d1 -Force | Out-Null; Set-Content -LiteralPath (Join-Path $d1 'a.txt') -Value 'a'
$f2 = Join-Path $u 'tuned.xml'; $bk = Join-Path $u 'tuned.bak'
Set-Content -LiteralPath $bk -Value 'users own version'; Set-Content -LiteralPath $f2 -Value 'overwritten by the tool'
$prof2 = Join-Path $u 'EUPHO.xml'
Copy-Item -LiteralPath (Join-Path $repo 'controller\profiles\EUPHO.xml') -Destination $prof2
$oldLp = Get-XmlTagText $prof2 'LaunchProgram'
[void](Set-XmlTagText $prof2 'LaunchProgram' 'C:\New\run_hidden.vbs')
Open-KJournal 'undotest'
[void](Add-KEntry 'dir|bin' @{ Type = 'dir'; Path = $d1 })
[void](Add-KEntry 'file|f1' @{ Type = 'file'; Path = $f1 })
[void](Add-KEntry 'filerestore|f2' @{ Type = 'filerestore'; Path = $f2; Backup = $bk })
[void](Add-KEntry 'xmltext|p' @{ Type = 'xmltext'; Path = $prof2; Tag = 'LaunchProgram'; Old = $oldLp })
$script:Quiet = $true
$rv = Invoke-KRevert 'undotest'
$script:Quiet = $false
Assert-That 'revert reports success' ($rv.Ok -and $rv.Failed.Count -eq 0 -and $rv.Restored -eq 4)
Assert-That 'file we created is removed' (-not (Test-Path -LiteralPath $f1))
Assert-That 'folder we created is removed' (-not (Test-Path -LiteralPath $d1))
Assert-That 'overwritten file is back as the user had it' ((Get-Content -LiteralPath $f2 -Raw).Trim() -eq 'users own version')
Assert-That 'profile LaunchProgram is back to the original' ((Get-XmlTagText $prof2 'LaunchProgram') -eq $oldLp)
Assert-That 'journal is archived after a clean revert' (-not (Test-Path -LiteralPath (Join-Path (Join-Path $script:DataRoot 'undotest') 'journal.json')))
Assert-That 'archive copy exists' (@(Get-ChildItem -LiteralPath (Join-Path (Join-Path $script:DataRoot 'undotest') 'reverted') -Filter *.json).Count -eq 1)
$none = Invoke-KRevert 'neverused'
Assert-That 'undo with no journal is a harmless no-op' ($none.Total -eq 0 -and $none.Ok)

Write-Host 'Damaged journal is never replaced'
$cd = Join-Path $script:DataRoot 'corrupt'; New-Item -ItemType Directory -Path $cd -Force | Out-Null
Set-Content -LiteralPath (Join-Path $cd 'journal.json') -Value '{ this is not json'
$threw = $false
try { Open-KJournal 'corrupt' } catch { $threw = $true }
Assert-That 'opening a damaged journal stops with an error' $threw
Assert-That 'the damaged file is left untouched' ((Get-Content -LiteralPath (Join-Path $cd 'journal.json') -Raw).Trim() -eq '{ this is not json')

Write-Host 'Per-group undo (what a per-group A/B test needs)'
$gu = Join-Path $tmp 'groupundo'; New-Item -ItemType Directory -Path $gu -Force | Out-Null
$ga = Join-Path $gu 'a.txt'; $gb = Join-Path $gu 'b.txt'; $gc = Join-Path $gu 'c.txt'
foreach ($f in @($ga, $gb, $gc)) { Set-Content -LiteralPath $f -Value 'x' }
Open-KJournal 'grouptest'
$script:KGroup = 'Power & CPU'; [void](Add-KEntry 'file|a' @{ Type = 'file'; Path = $ga }); [void](Add-KEntry 'file|b' @{ Type = 'file'; Path = $gb })
$script:KGroup = 'Network (registry)'; [void](Add-KEntry 'file|c' @{ Type = 'file'; Path = $gc })
$script:KGroup = $null
Assert-That 'entries carry their group tag' ((Get-KEntry 'file|a').Group -eq 'Power & CPU' -and (Get-KEntry 'file|c').Group -eq 'Network (registry)')
$script:Quiet = $true
$g1 = Invoke-KRevert 'grouptest' -Group 'Power & CPU'
$script:Quiet = $false
Assert-That 'only the chosen group is undone (2 of 2)' ($g1.Ok -and $g1.Restored -eq 2 -and $g1.Total -eq 2)
Assert-That 'its files are gone, the other group is untouched' (-not (Test-Path -LiteralPath $ga) -and -not (Test-Path -LiteralPath $gb) -and (Test-Path -LiteralPath $gc))
Open-KJournal 'grouptest'
Assert-That 'journal keeps exactly the other group' (@($script:J.Entries).Count -eq 1 -and $null -ne (Get-KEntry 'file|c'))
$script:Quiet = $true
$g2 = Invoke-KRevert 'grouptest'
$script:Quiet = $false
Assert-That 'a later full undo finishes the rest' ($g2.Ok -and $g2.Restored -eq 1 -and -not (Test-Path -LiteralPath $gc))
Assert-That 'reg entries record what was written (drift check)' ((Get-Command Set-KReg).ScriptBlock.ToString() -match 'Wrote = ' -and (Get-Command Restore-RegEntry).ScriptBlock.ToString() -match 'Test-KRegDrift')
Assert-That 'Protect-KDir takes ownership before setting permissions' ((Get-Command Protect-KDir).ScriptBlock.ToString() -match "/setowner '\*S-1-5-32-544'")
Assert-That 'Defender exclusions go through the elevation-safety check' ((Get-Command Get-PcDefenderWanted).ScriptBlock.ToString() -match 'Test-KPathSafeForElevation')

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }

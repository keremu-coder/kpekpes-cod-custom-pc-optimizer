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
Assert-That 'missing switches keep defaults' ($c.HvciOff -eq $true -and $c.LogonReapply -eq $true)
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

Write-Host 'Bundled profile and tuned copy'
$py = $null
foreach ($n in @('python3', 'python')) { if (-not $py -and (Get-Command $n -ErrorAction SilentlyContinue)) { $py = $n } }
if ($py) {
    $work = Join-Path $tmp 'tuned'; New-Item -ItemType Directory -Path $work | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'controller\profiles\EUPHO.xml') -Destination (Join-Path $work 'EUPHO.xml')
    & $py (Join-Path $repo 'controller\ds4_optimize_final.py') --profile (Join-Path $work 'EUPHO.xml') --strafe-boost max | Out-Null
    $tuned = Join-Path $work 'EUPHO_tuned.xml'
    Assert-That 'tuned copy is written' (Test-Path -LiteralPath $tuned)
    $x = [xml](Get-Content -LiteralPath $tuned -Raw)
    $ax = $x.SelectSingleNode('//LSAxialDeadOptions')
    Assert-That 'strafe boost max = 16 / 40 on LS X' ([int]$ax.AntiDeadZoneX -eq 16 -and [int]$ax.MaxZoneX -eq 40)
    $o = [xml](Get-Content -LiteralPath (Join-Path $work 'EUPHO.xml') -Raw)
    Assert-That 'right stick curve untouched' ($x.SelectSingleNode('//RSOutputCurveCustom').InnerText -eq $o.SelectSingleNode('//RSOutputCurveCustom').InnerText)
    Assert-That 'right stick dead zones untouched' ($x.SelectSingleNode('//RSAntiDeadZone').InnerText -eq $o.SelectSingleNode('//RSAntiDeadZone').InnerText)
    Assert-That 'left stick curve untouched' ($x.SelectSingleNode('//LSOutputCurveCustom').InnerText -eq $o.SelectSingleNode('//LSOutputCurveCustom').InnerText)
    Assert-That 'original profile not modified' ((Get-FileHash (Join-Path $work 'EUPHO.xml')).Hash -eq (Get-FileHash (Join-Path $repo 'controller\profiles\EUPHO.xml')).Hash)
} else { Write-Host '  (python not found, skipped)' -ForegroundColor Yellow }

Write-Host 'Launcher templates'
$bat = Get-Content -LiteralPath (Join-Path $repo 'controller\controller_optimizer.bat.template') -Raw
foreach ($tok in @('@@PROFILE@@', '@@DS4EXE@@', '@@STRAFE@@')) { Assert-That ('bat template has ' + $tok) ($bat.Contains($tok)) }
$gen = $bat.Replace('@@PROFILE@@', 'C:\p\EUPHO.xml').Replace('@@DS4EXE@@', 'C:\d\DS4Windows.exe').Replace('@@STRAFE@@', 'max')
Assert-That 'no placeholder left after generation' (-not $gen.Contains('@@'))
Assert-That 'bat keeps the duplicate-run guard' ($gen -match 'ds4_optimize_final\.py')
Assert-That 'no personal path in the template' (-not ($bat -match 'kerem'))
Assert-That 'vbs template has a placeholder' ((Get-Content -LiteralPath (Join-Path $repo 'controller\run_hidden.vbs.template') -Raw).Contains('@@BAT@@'))

Write-Host 'Tweak table sanity'
$cfg = Get-KDefaultConfig
function Test-HasNvidia { return $true }
$tw = Get-PcRegTweaks $cfg
$keys = @($tw | ForEach-Object { $_.Path + '|' + $_.Name })
Assert-That 'no duplicate registry targets' ((@($keys | Select-Object -Unique)).Count -eq $keys.Count)
Assert-That 'Game Mode is set OFF (0)' ((@($tw | Where-Object { $_.Name -eq 'AutoGameModeEnabled' })[0].Value) -eq 0)
Assert-That 'no write to the GPU driver class key' (-not (@($tw | Where-Object { $_.Path -match 'Control\\Class\\\{4d36e968' }).Count -gt 0))
Assert-That 'no PowerMizer / PerfLevelSrc values' (-not (@($tw | Where-Object { $_.Name -match 'PowerMizer|PerfLevelSrc|DisableDynamicPstate' }).Count -gt 0))
$cfg2 = Get-KDefaultConfig; $cfg2.WindowsUpdateBlock = $false; $cfg2.HvciOff = $false; $cfg2.GameProcessTweaks = $false
$tw2 = Get-PcRegTweaks $cfg2
Assert-That 'config switch removes the Windows Update group' (-not (@($tw2 | Where-Object { $_.Group -eq 'Windows Update control' }).Count -gt 0))
Assert-That 'config switch removes the memory-integrity group' (-not (@($tw2 | Where-Object { $_.Group -eq 'Memory integrity' }).Count -gt 0))
Assert-That 'config switch removes the game-process group' (-not (@($tw2 | Where-Object { $_.Group -eq 'Game process' }).Count -gt 0))

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

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }

# Test-Stats.ps1 -- tests for lib\Stats.ps1 (pure maths, runs anywhere: pwsh tests/Test-Stats.ps1).
# Every expected number below is worked out by hand in the comment next to it.

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'lib\Stats.ps1')

$script:pass = 0; $script:fail = 0
function Assert-That {
    param([string]$Name, [bool]$Cond, [string]$Info = '')
    if ($Cond) { $script:pass++; Write-Host ('  ok    ' + $Name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ('  FAIL  ' + $Name + '  ' + $Info) -ForegroundColor Red }
}
function Near { param([double]$A, [double]$B, [double]$Tol) return ([math]::Abs($A - $B) -le $Tol) }

Write-Host 'Percentile and mean/variance'
$s = [double[]](1, 2, 3, 4, 5)
Assert-That 'median of 1..5 = 3' ((Get-KPercentile $s 0.5) -eq 3)
Assert-That 'P25 of 1..5 = 2 (linear rule)' ((Get-KPercentile $s 0.25) -eq 2)
Assert-That 'P90 of 1..5 = 4.6 (h = 3.6)' (Near (Get-KPercentile $s 0.9) 4.6 1e-9)
$mv = Get-KMeanVar ([double[]](2, 4, 4, 4, 5, 5, 7, 9))
Assert-That 'mean = 5' ($mv.Mean -eq 5)
Assert-That 'sample variance = 32/7' (Near $mv.Var (32.0 / 7) 1e-9)

Write-Host 'Student-t critical values (two-sided 95 %)'
Assert-That 'df 3  -> 3.182' (Near (Get-KTCrit975 3) 3.182 0.03) ([string](Get-KTCrit975 3))
Assert-That 'df 10 -> 2.228' (Near (Get-KTCrit975 10) 2.228 0.002) ([string](Get-KTCrit975 10))
Assert-That 'df 30 -> 2.042' (Near (Get-KTCrit975 30) 2.042 0.001) ([string](Get-KTCrit975 30))

Write-Host 'Frame statistics V2'
# 990 frames of 10 ms + 10 frames of 50 ms (the same capture the old tests use)
$ft = New-Object 'System.Collections.Generic.List[double]'
for ($i = 0; $i -lt 990; $i++) { $ft.Add(10.0) }
for ($i = 0; $i -lt 10; $i++) { $ft.Add(50.0) }
$st = Get-FrameStatsV2 $ft.ToArray()
Assert-That 'avg fps = 1000 frames / 10.4 s = 96.2 (matches old function)' ($st.AvgFps -eq 96.2) ([string]$st.AvgFps)
Assert-That '1% low average = 20.0 (matches old function)' ($st.Low1AvgFps -eq 20.0)
Assert-That 'median fps = 100' ($st.MedianFps -eq 100)
# total time 10 400 ms; slowest 1 % of TIME = 104 ms -> reached inside the 50 ms frames -> 20 fps
Assert-That 'time-weighted 1% low = 20 fps' ($st.TimeLow1Fps -eq 20) ([string]$st.TimeLow1Fps)
# 10 slow frames in a row at the end: only the first is > 2x the previous 20-frame mean (10 ms) ...
# the 2nd: mean of previous 20 = (19x10 + 50)/20 = 12 -> 50 > 24 -> stutter; until the window fills with 50s.
# frames 990..999 vs window mean: 10,12,14,...,28 -> 50 > 2x(10..28)=20..56: true while mean < 25 -> 8 frames
Assert-That 'stutter count = 8 (running-mean rule, worked out by hand)' ($st.StutterCount -eq 8) ([string]$st.StutterCount)
Assert-That 'stutter time = 400 / 10400 = 3.846 %' (Near $st.StutterTimePct 3.846 0.001) ([string]$st.StutterTimePct)
# one jump 10 -> 50 among 999 deltas: mean = 40/999
Assert-That 'jitter mean = 40/999 ms' (Near $st.JitterMeanMs (40.0 / 999) 0.001) ([string]$st.JitterMeanMs)

# Same average FPS, different smoothness: alternating 5/15 ms vs constant 10 ms
$smooth = New-Object double[] 1000; $rough = New-Object double[] 1000
for ($i = 0; $i -lt 1000; $i++) { $smooth[$i] = 10.0; if ($i % 2 -eq 0) { $rough[$i] = 5.0 } else { $rough[$i] = 15.0 } }
$a = Get-FrameStatsV2 $smooth; $b = Get-FrameStatsV2 $rough
Assert-That 'equal average FPS (100 vs 100)' ($a.AvgFps -eq 100 -and $b.AvgFps -eq 100)
Assert-That 'jitter separates them (0 vs 10 ms)' ($a.JitterMeanMs -eq 0 -and $b.JitterMeanMs -eq 10)
# A slow drift 8 -> 12 ms is not jitter: tiny frame-to-frame steps
$drift = New-Object double[] 1000; for ($i = 0; $i -lt 1000; $i++) { $drift[$i] = 8.0 + 4.0 * $i / 999 }
$dr = Get-FrameStatsV2 $drift
Assert-That 'smooth drift has ~0 jitter (stddev would call it ~1.15 ms)' ($dr.JitterMeanMs -lt 0.01) ([string]$dr.JitterMeanMs)
$thrown = $false; try { Get-FrameStatsV2 ([double[]](1, 2, 3)) | Out-Null } catch { $thrown = $true }
Assert-That 'too few frames is rejected' $thrown

Write-Host 'ABBA schedule'
$sch = New-KAbbaSchedule 3
Assert-That 'warm-up first, 12 measured runs' ($sch[0] -eq 'warmup' -and $sch.Length -eq 13)
# Pure linear drift (fps falls 1 per run) and NO real effect -> ABBA must show exactly zero difference
$va = @(); $vb = @()
for ($i = 1; $i -lt $sch.Length; $i++) { $val = 200.0 - $i; if ($sch[$i] -eq 'A') { $va += $val } else { $vb += $val } }
$ma = ($va | Measure-Object -Average).Average; $mb = ($vb | Measure-Object -Average).Average
Assert-That 'ABBA cancels linear drift exactly' ($ma -eq $mb) ("A=$ma B=$mb")
# The naive AAAAAA BBBBBB order would invent a 6-fps "loss"
$na = @(); $nb = @(); for ($i = 1; $i -le 12; $i++) { $val = 200.0 - $i; if ($i -le 6) { $na += $val } else { $nb += $val } }
Assert-That 'naive order invents a 6 fps difference' ((($na | Measure-Object -Average).Average - ($nb | Measure-Object -Average).Average) -eq 6)

Write-Host 'Run-set comparison'
$before = [double[]](140.1, 141.3, 139.8, 140.6, 140.9)
$after  = [double[]](146.2, 145.5, 146.9, 145.8, 146.4)
$c = Compare-KRunSets $before $after
Assert-That 'clear +4 % gain is called better' ($c.Verdict -eq 'better') ($c | Out-String)
# means 140.54 -> 146.16 : +5.62 / 140.54 = +4.0 %
Assert-That 'change is +4.0 %' (Near $c.ChangePct 4.0 0.01) ([string]$c.ChangePct)
Assert-That 'interval excludes 0' ($c.CiLowPct -gt 0)
$noise1 = [double[]](140.1, 143.0, 138.2, 141.7, 139.4)
$noise2 = [double[]](141.0, 138.9, 142.6, 139.8, 140.5)
$c2 = Compare-KRunSets $noise1 $noise2
Assert-That 'A/A noise is NOT called better or worse' ($c2.Verdict -notmatch '^(better|worse)$') ($c2 | Out-String)
$tight1 = [double[]](140.00, 140.10, 139.90, 140.05, 139.95, 140.02)
$tight2 = [double[]](140.03, 139.98, 140.08, 139.94, 140.01, 140.06)
$c3 = Compare-KRunSets $tight1 $tight2 -EquivalenceMarginPct 1
Assert-That 'tight data proves "no real difference" (placebo confirmed)' ($c3.Verdict -match '^no real difference') ($c3 | Out-String)
$lat1 = [double[]](24.1, 23.8, 24.4, 24.0, 23.9); $lat2 = [double[]](18.2, 18.6, 18.0, 18.4, 18.3)
$c4 = Compare-KRunSets $lat1 $lat2 -HigherIsBetter $false
Assert-That 'for latency, lower is better' ($c4.Verdict -eq 'better') ($c4 | Out-String)
$c5 = Compare-KRunSets $before $after
Assert-That 'same data + same seed = same answer' ($c5.CiLowPct -eq $c.CiLowPct -and $c5.CiHighPct -eq $c.CiHighPct)
$thrown = $false; try { Compare-KRunSets ([double[]](1, 2)) ([double[]](1, 2, 3)) | Out-Null } catch { $thrown = $true }
Assert-That 'fewer than 3 runs is rejected' $thrown

Write-Host 'Holm correction'
$adj = Get-KHolmAdjusted ([double[]](0.01, 0.04, 0.03))
# sorted 0.01,0.03,0.04 -> x3, x2, x1 = 0.03, 0.06, 0.06(monotone) -> back in input order
Assert-That 'Holm: 0.01 -> 0.03' (Near $adj[0] 0.03 1e-9)
Assert-That 'Holm: 0.03 -> 0.06' (Near $adj[2] 0.06 1e-9)
Assert-That 'Holm: 0.04 -> 0.06 (kept monotone)' (Near $adj[1] 0.06 1e-9)

Write-Host 'Latency model and VRR cap'
$m0 = Get-KLatencyModel -Fps 144 -RefreshHz 144 -PollHz 250 -QueuedFrames 2
# 2 + 6.944 + 13.889 + 3.472 = 26.31
Assert-That 'baseline 144 fps / 144 Hz / 250 Hz poll / 2 queued = 26.31 ms' (Near $m0.TotalMs 26.31 0.01) ([string]$m0.TotalMs)
$mR = Get-KLatencyModel -Fps 144 -RefreshHz 144 -PollHz 250 -QueuedFrames 0
Assert-That 'empty render queue (Reflex) saves 13.89 ms' (Near ($m0.TotalMs - $mR.TotalMs) 13.89 0.01)
$mP = Get-KLatencyModel -Fps 144 -RefreshHz 144 -PollHz 1000 -QueuedFrames 2
Assert-That '1000 Hz polling saves 1.5 ms' (Near ($m0.TotalMs - $mP.TotalMs) 1.5 0.01)
$mT1 = Get-KLatencyModel -Fps 144 -RefreshHz 144 -PollHz 250 -QueuedFrames 2 -TimerSlackMs 0.5
$mT2 = Get-KLatencyModel -Fps 144 -RefreshHz 144 -PollHz 250 -QueuedFrames 2 -TimerSlackMs 0.25
Assert-That '1 ms -> 0.5 ms timer is worth 0.25 ms at most' (Near ($mT1.TotalMs - $mT2.TotalMs) 0.25 0.01)
Assert-That 'VRR cap 144 -> 138' ((Get-KVrrCap 144) -eq 138)
Assert-That 'VRR cap 165 -> 157' ((Get-KVrrCap 165) -eq 157)
Assert-That 'VRR cap 240 -> 224' ((Get-KVrrCap 240) -eq 224)

Write-Host 'Stick response (DS4Windows axial model)'
Assert-That 'inside the dead zone = 0' ((Get-KAxialOutput 0.05 0.10 0.16 0.40) -eq 0)
Assert-That 'just past the dead zone = anti-dead-zone (16 %)' (Near (Get-KAxialOutput 0.1000001 0.10 0.16 0.40) 0.16 1e-4)
Assert-That 'at max zone = 100 %' (Near (Get-KAxialOutput 0.40 0 0.16 0.40) 1.0 1e-9)
Assert-That 'negative side mirrors' (Near (Get-KAxialOutput -0.40 0 0.16 0.40) -1.0 1e-9)
$r = Get-KStickReport -DzX 0 -AdX 0.16 -MzX 0.40 -DzY 0 -AdY 0 -MzY 0.99
Assert-That 'strafe max: full speed at 40 % travel, 60 % of travel unused' ($r.FullStrafeAtPct -eq 40 -and $r.UnusedTravelPct -eq 60)
Assert-That 'strafe max: X gain = 0.84 / 0.40 = 2.1' ($r.GainX -eq 2.1)
# 45-degree full push: X saturates (1.0), Y = 0.7071 / 0.99 = 0.7142 -> atan(0.7142) = 35.54 deg
Assert-That 'strafe max bends a 45-degree push to ~35.5 degrees' (Near $r.DiagonalAngleDeg 35.54 0.05) ([string]$r.DiagonalAngleDeg)
$lin = Get-KStickReport -DzX 0 -AdX 0 -MzX 0.99 -DzY 0 -AdY 0 -MzY 0.99
Assert-That 'symmetric axes keep 45 degrees' (Near $lin.DiagonalAngleDeg 45 1e-6)

Write-Host 'Scoring and CPU policy'
$res = @(
    [pscustomobject]@{ State = 'PASS'; Placebo = $false },
    [pscustomobject]@{ State = 'FAIL'; Placebo = $false },
    [pscustomobject]@{ State = 'PASS'; Placebo = $true },
    [pscustomobject]@{ State = 'PASS'; Placebo = $true },
    [pscustomobject]@{ State = 'NA'; Placebo = $false }
)
$sc = Get-KScoreV2 $res
Assert-That 'placebo items do not inflate the score (50 %, not 75 %)' ($sc.Percent -eq 50 -and $sc.PlaceboApplied -eq 2) ($sc | Out-String)
$x = Get-KCpuPolicy 'AMD Ryzen 9 7950X3D 16-Core Processor' 2
Assert-That '7950X3D: keep parking, Game Mode and Game Bar' ($x.Kind -eq 'dual-ccd-x3d' -and -not $x.DisableParking -and -not $x.GameModeOff -and -not $x.RemoveGameBar)
$y = Get-KCpuPolicy 'AMD Ryzen 7 7800X3D 8-Core Processor' 1
Assert-That '7800X3D (one CCD): parking left to Windows, Game Bar may go' ($y.Kind -eq 'single-ccd-amd' -and -not $y.DisableParking -and $y.RemoveGameBar)
$z = Get-KCpuPolicy 'AMD Ryzen 9 5900X 12-Core Processor' 2
Assert-That '5900X (two CCDs, no X3D): parking may be disabled' ($z.Kind -eq 'standard' -and $z.DisableParking)
$w = Get-KCpuPolicy '13th Gen Intel(R) Core(TM) i7-13700K' 1
Assert-That 'Intel: standard policy, Game Mode off as before' ($w.Kind -eq 'standard' -and $w.GameModeOff)

Write-Host ''
Write-Host ('{0} passed, {1} failed' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }

# Stats.ps1 -- measurement maths. Pure functions: no Windows calls, no side effects, deterministic
# (the bootstrap takes a seed). Windows PowerShell 5.1 compatible (no ternary, no ??).
#
# Why this file exists: one "before" capture vs one "after" capture cannot tell a real 2 % gain from
# run-to-run noise. Everything here is built so the tool can say "better", "worse", "equivalent"
# or "not enough data" -- and never claims more than the numbers support.

# ---------------- basic statistics ----------------
function Get-KSortedCopy {
    param([double[]]$Values)
    $s = New-Object double[] $Values.Length
    [array]::Copy($Values, $s, $Values.Length)
    [array]::Sort($s)
    return ,$s
}

function Get-KPercentile {
    # Linear-interpolated percentile of an ASCENDING sorted array (same rule as Excel PERCENTILE.INC). P in [0,1].
    param([double[]]$Sorted, [double]$P)
    $n = $Sorted.Length
    if ($n -eq 0) { throw 'Get-KPercentile: empty input' }
    if ($n -eq 1) { return $Sorted[0] }
    $h = ($n - 1) * $P
    $lo = [int][math]::Floor($h); $hi = [int][math]::Ceiling($h)
    return $Sorted[$lo] + ($h - $lo) * ($Sorted[$hi] - $Sorted[$lo])
}

function Get-KMeanVar {
    # Mean and unbiased sample variance (n-1), one pass (Welford: numerically stable).
    param([double[]]$Values)
    $n = 0; $mean = 0.0; $m2 = 0.0
    foreach ($x in $Values) { $n++; $d = $x - $mean; $mean += $d / $n; $m2 += $d * ($x - $mean) }
    $var = 0.0
    if ($n -gt 1) { $var = $m2 / ($n - 1) }
    return [pscustomobject]@{ N = $n; Mean = $mean; Var = $var; Sd = [math]::Sqrt($var) }
}

function Get-KTCrit975 {
    # Two-sided 95 % Student-t critical value for df degrees of freedom.
    # Cornish-Fisher expansion around z = 1.959964; error < 0.03 at df = 3 and < 0.001 for df >= 10.
    param([double]$Df)
    if ($Df -lt 1) { $Df = 1 }
    $z = 1.959963985
    $z3 = [math]::Pow($z, 3); $z5 = [math]::Pow($z, 5); $z7 = [math]::Pow($z, 7)
    return $z + ($z3 + $z) / (4 * $Df) + (5 * $z5 + 16 * $z3 + 3 * $z) / (96 * $Df * $Df) + (3 * $z7 + 19 * $z5 + 17 * $z3 - 15 * $z) / (384 * [math]::Pow($Df, 3))
}

# ---------------- frame-time statistics (one capture) ----------------
function Get-KTimeWeightedLowFps {
    # The FPS level the slowest P share of PLAY TIME is spent at or below.
    # Frame-weighted percentiles under-count stutter: one 100 ms hitch is 1 frame but 100 ms of what you saw.
    param([double[]]$FrameTimes, [double]$P)
    $s = Get-KSortedCopy $FrameTimes
    [array]::Reverse($s)   # slowest first
    $total = 0.0; foreach ($x in $s) { $total += $x }
    $target = $P * $total; $acc = 0.0
    foreach ($x in $s) { $acc += $x; if ($acc -ge $target) { return 1000.0 / $x } }
    return 1000.0 / $s[$s.Length - 1]
}

function Get-FrameStatsV2 {
    # FrameTimes in milliseconds, in capture order (order matters for jitter and stutter).
    param([double[]]$FrameTimes, [double]$StutterFactor = 2.0, [int]$Window = 20)
    $n = $FrameTimes.Length
    if ($n -lt 100) { throw ('Get-FrameStatsV2: need at least 100 frames, got ' + $n) }
    $total = 0.0; foreach ($x in $FrameTimes) { $total += $x }
    $asc = Get-KSortedCopy $FrameTimes

    # "1% low (average)" as CapFrameX reports it: average of the slowest 1 % / 0.1 % of frames, as FPS.
    $k1 = [math]::Max(1, [int][math]::Ceiling($n * 0.01)); $k01 = [math]::Max(1, [int][math]::Ceiling($n * 0.001))
    $s1 = 0.0; for ($i = 0; $i -lt $k1; $i++) { $s1 += $asc[$n - 1 - $i] }
    $s01 = 0.0; for ($i = 0; $i -lt $k01; $i++) { $s01 += $asc[$n - 1 - $i] }

    # Jitter as frame-to-frame change |ft[i] - ft[i-1]|. Unlike the standard deviation it does not grow just
    # because FPS is lower, and it does not count a smooth, slow drift (a scene getting heavier) as jitter.
    $d = New-Object double[] ($n - 1)
    $dSum = 0.0
    for ($i = 1; $i -lt $n; $i++) { $v = [math]::Abs($FrameTimes[$i] - $FrameTimes[$i - 1]); $d[$i - 1] = $v; $dSum += $v }
    [array]::Sort($d)

    # Stutter: a frame longer than StutterFactor x the mean of the previous Window frames (running sum, O(n)).
    $run = 0.0; $stN = 0; $stT = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        if ($i -ge $Window) {
            $ref = $run / $Window
            if ($FrameTimes[$i] -gt $StutterFactor * $ref) { $stN++; $stT += $FrameTimes[$i] }
            $run -= $FrameTimes[$i - $Window]
        }
        $run += $FrameTimes[$i]
    }

    return [pscustomobject]@{
        Frames         = $n
        DurationS      = [math]::Round($total / 1000.0, 2)
        AvgFps         = [math]::Round(1000.0 * $n / $total, 1)            # frames / time (time-weighted mean)
        MedianFps      = [math]::Round(1000.0 / (Get-KPercentile $asc 0.5), 1)
        P1LowFps       = [math]::Round(1000.0 / (Get-KPercentile $asc 0.99), 1)   # 99th-percentile frame time
        Low1AvgFps     = [math]::Round(1000.0 / ($s1 / $k1), 1)
        Low01AvgFps    = [math]::Round(1000.0 / ($s01 / $k01), 1)
        TimeLow1Fps    = [math]::Round((Get-KTimeWeightedLowFps $FrameTimes 0.01), 1)
        JitterMeanMs   = [math]::Round($dSum / ($n - 1), 3)
        JitterP99Ms    = [math]::Round((Get-KPercentile $d 0.99), 3)
        StutterCount   = $stN
        StutterTimePct = [math]::Round(100.0 * $stT / $total, 3)
    }
}

# ---------------- comparing several runs per configuration ----------------
function New-KAbbaSchedule {
    # Run order for an A/B test: one warm-up (shader cache, file cache), then A B B A blocks.
    # An ABBA block cancels any LINEAR drift exactly (heat soak, background tasks settling):
    # A sits at positions 0 and 3, B at 1 and 2, and both pairs have the same mean position (1.5).
    param([int]$Blocks = 3)
    $s = New-Object System.Collections.Generic.List[string]
    $s.Add('warmup')
    for ($b = 0; $b -lt $Blocks; $b++) { foreach ($x in @('A', 'B', 'B', 'A')) { $s.Add($x) } }
    return $s.ToArray()
}

function Compare-KRunSets {
    # Before / After = one number per RUN (e.g. AvgFps of each 60 s capture). Runs are the unit of evidence:
    # frames inside one run are strongly autocorrelated, so treating 10 000 frames as 10 000 samples fakes certainty.
    # The verdict uses the WIDER of two 95 % intervals (Welch t and percentile bootstrap), so small samples stay humble.
    param(
        [double[]]$Before,
        [double[]]$After,
        [bool]$HigherIsBetter = $true,
        [double]$EquivalenceMarginPct = 1.0,
        [int]$Resamples = 4000,
        [int]$Seed = 12345
    )
    if ($Before.Length -lt 3 -or $After.Length -lt 3) { throw 'Compare-KRunSets: need at least 3 runs per side (5+ recommended)' }
    $b = Get-KMeanVar $Before; $a = Get-KMeanVar $After
    if ($b.Mean -eq 0) { throw 'Compare-KRunSets: baseline mean is 0' }
    $diff = $a.Mean - $b.Mean

    # Welch t interval
    $vb = $b.Var / $b.N; $va = $a.Var / $a.N
    $se = [math]::Sqrt($vb + $va)
    $df = 1.0
    if (($vb + $va) -gt 0) {
        $den = 0.0
        if ($b.N -gt 1) { $den += ($vb * $vb) / ($b.N - 1) }
        if ($a.N -gt 1) { $den += ($va * $va) / ($a.N - 1) }
        if ($den -gt 0) { $df = (($vb + $va) * ($vb + $va)) / $den }
    }
    $t = Get-KTCrit975 $df
    $tLo = $diff - $t * $se; $tHi = $diff + $t * $se

    # Percentile bootstrap of the difference in means (seeded, so the same data always gives the same answer)
    $rng = New-Object System.Random $Seed
    $boot = New-Object double[] $Resamples
    for ($r = 0; $r -lt $Resamples; $r++) {
        $sb = 0.0; for ($i = 0; $i -lt $b.N; $i++) { $sb += $Before[$rng.Next($b.N)] }
        $sa = 0.0; for ($i = 0; $i -lt $a.N; $i++) { $sa += $After[$rng.Next($a.N)] }
        $boot[$r] = ($sa / $a.N) - ($sb / $b.N)
    }
    [array]::Sort($boot)
    $bLo = Get-KPercentile $boot 0.025; $bHi = Get-KPercentile $boot 0.975

    $lo = [math]::Min($tLo, $bLo); $hi = [math]::Max($tHi, $bHi)
    $pct = 100.0 / $b.Mean
    $loPct = $lo * $pct; $hiPct = $hi * $pct

    # Smallest change this many runs could reliably detect (80 % power, 5 % two-sided): (1.96 + 0.84) x SE
    $mdePct = 2.8 * $se * $pct

    $verdict = 'not enough data - run more captures'
    if ($lo -gt 0) { if ($HigherIsBetter) { $verdict = 'better' } else { $verdict = 'worse' } }
    elseif ($hi -lt 0) { if ($HigherIsBetter) { $verdict = 'worse' } else { $verdict = 'better' } }
    elseif ($loPct -ge -$EquivalenceMarginPct -and $hiPct -le $EquivalenceMarginPct) { $verdict = ('no real difference (within +/-' + $EquivalenceMarginPct + ' %)') }

    return [pscustomobject]@{
        BeforeMean = [math]::Round($b.Mean, 3); AfterMean = [math]::Round($a.Mean, 3)
        ChangePct  = [math]::Round($diff * $pct, 2)
        CiLowPct   = [math]::Round($loPct, 2); CiHighPct = [math]::Round($hiPct, 2)
        MdePct     = [math]::Round($mdePct, 2)
        Df         = [math]::Round($df, 1)
        Verdict    = $verdict
    }
}

function Get-KHolmAdjusted {
    # Holm-Bonferroni: when several tweak groups are tested at once, some will look "significant" by luck.
    # Input: raw p-values. Output: adjusted p-values in the same order (compare each with 0.05).
    param([double[]]$P)
    $m = $P.Length
    $idx = 0..($m - 1) | Sort-Object { $P[$_] }
    $adj = New-Object double[] $m
    $running = 0.0
    for ($k = 0; $k -lt $m; $k++) {
        $i = $idx[$k]
        $v = [math]::Min(1.0, ($m - $k) * $P[$i])
        if ($v -lt $running) { $v = $running }
        $running = $v
        $adj[$i] = $v
    }
    return ,$adj
}

# ---------------- latency model (an estimate, never presented as a measurement) ----------------
function Get-KLatencyModel {
    # Mean end-to-end latency (ms) from input to photon, split into the parts a player can change.
    #   input   : waiting for the next controller/mouse poll      = half the poll interval
    #   frame   : the frame that contains the input being built    = one frame time
    #   queue   : frames already waiting in the render queue       = QueuedFrames x frame time  (Reflex / Anti-Lag ~ 0)
    #   scanout : the pixel being drawn somewhere mid-screen       = half the refresh interval
    #   timer   : extra wake-up slack if the game paces with Sleep = TimerSlackMs (about half the timer period)
    param([double]$Fps, [double]$RefreshHz, [double]$PollHz = 1000, [double]$QueuedFrames = 1, [double]$TimerSlackMs = 0)
    $frame = 1000.0 / $Fps
    $p = [ordered]@{
        InputMs   = 500.0 / $PollHz
        FrameMs   = $frame
        QueueMs   = $QueuedFrames * $frame
        ScanoutMs = 500.0 / $RefreshHz
        TimerMs   = $TimerSlackMs
    }
    $total = 0.0; foreach ($k in @($p.Keys)) { $total += $p[$k] }
    $o = [pscustomobject]$p
    $o | Add-Member -NotePropertyName TotalMs -NotePropertyValue ([math]::Round($total, 2))
    return $o
}

function Get-KVrrCap {
    # FPS cap that keeps a VRR (G-Sync / FreeSync) display inside its range with V-Sync on, without V-Sync's queue.
    # R - R^2/3600 matches the caps NVIDIA Reflex picks automatically (144 -> 138, 165 -> 157, 240 -> 224) -- approximation.
    param([double]$RefreshHz)
    return [int][math]::Floor($RefreshHz - ($RefreshHz * $RefreshHz) / 3600.0)
}

# ---------------- stick response (DS4Windows axial dead-zone model) ----------------
function Get-KAxialOutput {
    # Approximation of DS4Windows' axial mapping for one axis, all values as fractions 0..1 of full deflection.
    param([double]$X, [double]$DeadZone, [double]$AntiDeadZone, [double]$MaxZone, [double]$MaxOutput = 1.0)
    $ax = [math]::Abs($X)
    if ($ax -le $DeadZone) { return 0.0 }
    $span = $MaxZone - $DeadZone
    if ($span -le 0) { return [math]::Sign($X) * $MaxOutput }
    $u = [math]::Min(1.0, ($ax - $DeadZone) / $span)
    return [math]::Sign($X) * ($AntiDeadZone + (1.0 - $AntiDeadZone) * $u) * $MaxOutput
}

function Get-KStickReport {
    # What a strafe-boost setting really does to the left stick, in numbers.
    param([double]$DzX, [double]$AdX, [double]$MzX, [double]$DzY = 0, [double]$AdY = 0, [double]$MzY = 0.99)
    $gainX = (1.0 - $AdX) / ($MzX - $DzX)
    $gainY = (1.0 - $AdY) / ($MzY - $DzY)
    # a full push at 45 degrees: each axis sees cos(45) = 0.7071
    $c = [math]::Cos([math]::PI / 4)
    $ox = Get-KAxialOutput $c $DzX $AdX $MzX
    $oy = Get-KAxialOutput $c $DzY $AdY $MzY
    $angle = [math]::Atan2($oy, $ox) * 180.0 / [math]::PI
    return [pscustomobject]@{
        MinStrafeOutputPct  = [math]::Round(100 * $AdX, 1)            # slowest strafe speed you can produce
        FullStrafeAtPct     = [math]::Round(100 * $MzX, 1)            # stick travel where strafe is already maxed
        UnusedTravelPct     = [math]::Round(100 * (1 - $MzX), 1)      # travel that changes nothing any more
        GainX               = [math]::Round($gainX, 3)                # output per unit of travel (1.0 = linear)
        GainRatioXtoY       = [math]::Round($gainX / $gainY, 3)
        DiagonalAngleDeg    = [math]::Round($angle, 2)                # where a 45-degree push actually moves you
        DiagonalErrorDeg    = [math]::Round(45 - $angle, 2)
    }
}

# ---------------- scoring ----------------
function Get-KScoreV2 {
    # Applied score WITHOUT placebo items, so harmless-but-useless tweaks cannot inflate it.
    param($Results)
    $all = @($Results)
    $real = @($all | Where-Object { -not $_.Placebo })
    $pass = @($real | Where-Object { $_.State -eq 'PASS' }).Count
    $fail = @($real | Where-Object { $_.State -eq 'FAIL' }).Count
    $pl = @($all | Where-Object { $_.Placebo -and $_.State -eq 'PASS' }).Count
    $den = $pass + $fail; $pct = 0
    if ($den -gt 0) { $pct = [int][math]::Round(($pass / $den) * 100) }
    return [pscustomobject]@{ Percent = $pct; Pass = $pass; Fail = $fail; Total = $den; PlaceboApplied = $pl }
}

# ---------------- CPU topology decision (pure part; the Windows probe lives in Topology.ps1) ----------------
function Get-KCpuPolicy {
    # Decides which CPU-related tweaks are safe for this chip.
    # Dual-CCD X3D parts (7900X3D / 7950X3D / 9900X3D / 9950X3D) rely on AMD's driver PARKING the non-V-cache CCD,
    # and on Game Bar + Game Mode to know a game is running. On those chips we must not disable any of the three.
    param([string]$CpuName, [int]$L3Count)
    $isAmd = ($CpuName -match 'AMD')
    $isX3d = ($CpuName -match 'X3D')
    $multiCcd = ($L3Count -ge 2)
    $p = [ordered]@{
        Kind              = 'standard'
        DisableParking    = $true
        GameModeOff       = $false   # Windows default (on) until an A/B test on THIS PC shows off is better
        RemoveGameBar     = $true
        Reason            = ''
    }
    if ($isAmd -and $isX3d -and $multiCcd) {
        $p.Kind = 'dual-ccd-x3d'; $p.DisableParking = $false; $p.GameModeOff = $false; $p.RemoveGameBar = $false
        $p.Reason = 'AMD 3D V-Cache driver needs core parking, Game Mode and Game Bar'
    } elseif ($isAmd -and -not $multiCcd) {
        $p.Kind = 'single-ccd-amd'; $p.DisableParking = $false
        $p.Reason = 'single CCD: Windows parking is already harmless'
    }
    return [pscustomobject]$p
}

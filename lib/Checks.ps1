# Checks.ps1 -- read-only readiness checks and the frame-capture comparison.
# Nothing in this file changes the PC.

function Get-ReadinessChecks {
    $r = New-Object System.Collections.ArrayList
    $g = 'Readiness'

    # --- Secure Boot (Call of Duty on PC needs it) ---
    try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) { [void]$r.Add((New-KResult 'Secure Boot' 'PASS' 'on' $g)) }
        else { [void]$r.Add((New-KResult 'Secure Boot' 'FAIL' 'off - Call of Duty on PC requires it' $g)) }
    } catch { [void]$r.Add((New-KResult 'Secure Boot' 'FAIL' 'not available (legacy BIOS mode?)' $g)) }

    # --- TPM ---
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        if ($tpm.TpmPresent -and $tpm.TpmReady) { [void]$r.Add((New-KResult 'TPM' 'PASS' 'present and ready' $g)) }
        elseif ($tpm.TpmPresent) { [void]$r.Add((New-KResult 'TPM' 'WARN' 'present but not ready' $g)) }
        else { [void]$r.Add((New-KResult 'TPM' 'FAIL' 'no TPM found - enable fTPM / PTT in BIOS' $g)) }
    } catch { [void]$r.Add((New-KResult 'TPM' 'WARN' 'could not read TPM state' $g)) }

    # --- RAM speed (heuristic: WMI cannot tell us the kit's EXPO/XMP rating) ---
    try {
        $m = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        if ($m.Count -gt 0) {
            $cfg  = ($m | Measure-Object -Property ConfiguredClockSpeed -Minimum).Minimum
            $rate = ($m | Measure-Object -Property Speed -Maximum).Maximum
            $ddr5 = (@($m | Where-Object { $_.SMBIOSMemoryType -eq 34 }).Count -gt 0)
            $gb = [math]::Round((($m | Measure-Object -Property Capacity -Sum).Sum) / 1GB)
            $detail = ('{0} module(s), {1} GB, running {2} MT/s (module max {3})' -f $m.Count, $gb, $cfg, $rate)
            $low = $false
            if ($ddr5 -and $cfg -le 4800) { $low = $true }
            if ((-not $ddr5) -and $cfg -le 2666) { $low = $true }
            if ($cfg -lt $rate) { $low = $true }
            if ($low) { [void]$r.Add((New-KResult 'RAM speed' 'WARN' ($detail + ' - looks like the default JEDEC speed; if your kit is rated higher, enable EXPO/XMP in BIOS') $g)) }
            else { [void]$r.Add((New-KResult 'RAM speed' 'PASS' $detail $g)) }
            if ($m.Count -lt 2) { [void]$r.Add((New-KResult 'RAM modules' 'WARN' 'single stick - two matched sticks give dual-channel bandwidth' $g)) }
        }
    } catch { [void]$r.Add((New-KResult 'RAM speed' 'NA' 'could not read memory info' $g)) }

    # --- Monitor refresh vs the panel's own listed modes (EDID) ---
    try {
        $cur = (Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.CurrentRefreshRate } | Select-Object -First 1).CurrentRefreshRate
        $modes = @(Get-CimInstance -Namespace 'root\wmi' -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction Stop)
        $max = 0.0
        foreach ($mm in $modes) {
            foreach ($sm in @($mm.MonitorSourceModes)) {
                if ($sm.VerticalRefreshRateDenominator -gt 0) {
                    $hz = [double]$sm.VerticalRefreshRateNumerator / [double]$sm.VerticalRefreshRateDenominator
                    if ($hz -gt $max) { $max = $hz }
                }
            }
        }
        if ($cur -and $max -gt 0) {
            $d = ('running {0} Hz, panel lists up to {1} Hz' -f $cur, [math]::Round($max))
            if ($cur -gt ($max + 1)) { [void]$r.Add((New-KResult 'Monitor refresh' 'WARN' ($d + ' - above what the panel reports (custom timing?). Reset to the panel rating.') $g)) }
            elseif ($cur -lt ($max - 1)) { [void]$r.Add((New-KResult 'Monitor refresh' 'WARN' ($d + ' - set it to the top refresh rate in Windows display settings') $g)) }
            else { [void]$r.Add((New-KResult 'Monitor refresh' 'PASS' $d $g)) }
        } elseif ($cur) { [void]$r.Add((New-KResult 'Monitor refresh' 'INFO' ('running ' + $cur + ' Hz (panel limits not readable)') $g)) }
    } catch { [void]$r.Add((New-KResult 'Monitor refresh' 'NA' 'could not read display modes' $g)) }

    # --- Wired or Wi-Fi on the active route ---
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
        $ad = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop
        if ($ad.PhysicalMediaType -match '802\.11' -or $ad.InterfaceDescription -match 'Wi-Fi|Wireless|WLAN') {
            [void]$r.Add((New-KResult 'Connection' 'WARN' ('Wi-Fi (' + $ad.Name + ') - a cable is steadier for online play') $g))
        } else { [void]$r.Add((New-KResult 'Connection' 'PASS' ('wired (' + $ad.Name + ')') $g)) }
    } catch { [void]$r.Add((New-KResult 'Connection' 'NA' 'no active route found' $g)) }

    # --- Resizable BAR (NVIDIA) ---
    try {
        $smi = $null
        foreach ($p in @((Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'), 'C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe')) {
            if (Test-Path -LiteralPath $p) { $smi = $p; break }
        }
        if ($smi) {
            $out = (& $smi -q -d MEMORY 2>&1 | Out-String)
            $bar = [regex]::Match($out, 'BAR1 Memory Usage\s*\r?\n\s*Total\s*:\s*(\d+)\s*MiB')
            $fb = [regex]::Match($out, 'FB Memory Usage\s*\r?\n\s*Total\s*:\s*(\d+)\s*MiB')
            if ($bar.Success -and $fb.Success) {
                $b = [int]$bar.Groups[1].Value; $f = [int]$fb.Groups[1].Value
                if ($b -ge ($f * 0.9)) { [void]$r.Add((New-KResult 'Resizable BAR' 'PASS' ('on (BAR1 ' + $b + ' MiB)') $g)) }
                else { [void]$r.Add((New-KResult 'Resizable BAR' 'WARN' ('looks off (BAR1 ' + $b + ' MiB of ' + $f + ' MiB) - enable Above 4G Decoding + Resizable BAR in BIOS') $g)) }
            } else { [void]$r.Add((New-KResult 'Resizable BAR' 'NA' 'could not read BAR size' $g)) }
        } else { [void]$r.Add((New-KResult 'Resizable BAR' 'NA' 'nvidia-smi not found' $g)) }
    } catch { [void]$r.Add((New-KResult 'Resizable BAR' 'NA' 'could not query the GPU' $g)) }

    # --- Startup apps ---
    try {
        $su = @(Get-CimInstance Win32_StartupCommand -ErrorAction Stop)
        $names = ($su | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', '
        if ($su.Count -gt 8) { [void]$r.Add((New-KResult 'Startup apps' 'WARN' ([string]$su.Count + ' items: ' + $names) $g)) }
        else { [void]$r.Add((New-KResult 'Startup apps' 'PASS' ([string]$su.Count + ' items: ' + $names) $g)) }
    } catch { [void]$r.Add((New-KResult 'Startup apps' 'NA' 'could not list startup items' $g)) }

    # --- Free space on the system drive ---
    try {
        $d = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
        $tot = $d.Used + $d.Free
        $pct = [math]::Round(($d.Free / $tot) * 100)
        if ($pct -lt 10) { [void]$r.Add((New-KResult 'System drive space' 'WARN' ([string]$pct + '% free - low free space slows loading and shader caches') $g)) }
        else { [void]$r.Add((New-KResult 'System drive space' 'PASS' ([string]$pct + '% free') $g)) }
    } catch { }

    # --- Info lines ---
    try {
        $gpu = Get-CimInstance Win32_VideoController -ErrorAction Stop | Select-Object -First 1
        [void]$r.Add((New-KResult 'GPU / driver' 'INFO' ($gpu.Name + ', driver ' + $gpu.DriverVersion) $g))
    } catch { }
    return @($r)
}

function Import-FrameTimes {
    # Reads frame times (ms) from a PresentMon or CapFrameX CSV export.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw ('File not found: ' + $Path) }
    $rows = Import-Csv -LiteralPath $Path
    if (-not $rows) { throw ('No rows in ' + $Path) }
    $cols = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name })
    $col = $null
    # Displayed-frame times first: that is what reaches your eyes. Present-to-present times count frames the
    # display never showed (and miss the ones it showed late), so they are only the fallback.
    foreach ($c in @('MsBetweenDisplayChange', 'DisplayedTime', 'MsBetweenPresents', 'msBetweenPresents', 'FrameTime', 'frametime', 'TimeInMs', 'MsInPresentAPI')) {
        if ($cols -contains $c) { $col = $c; break }
    }
    if (-not $col) { throw ('Cannot find a frame-time column in ' + $Path + '. Columns: ' + ($cols -join ', ')) }
    $ft = New-Object System.Collections.Generic.List[double]
    foreach ($row in $rows) {
        $v = 0.0
        if ([double]::TryParse([string]$row.$col, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) {
            if ($v -gt 0) { $ft.Add($v) }
        }
    }
    if ($ft.Count -lt 100) { throw ('Too few frames in ' + $Path + ' (' + $ft.Count + '). Capture at least a minute of gameplay.') }
    return $ft.ToArray()
}

function Import-LatencyValues {
    # Input-to-photon latency from PresentMon (needs Reflex markers or input events in the capture).
    # Returns $null when the capture has no latency column -- latency is then simply not reported.
    param([string]$Path)
    $rows = Import-Csv -LiteralPath $Path
    if (-not $rows) { return $null }
    $cols = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($c in @('MsPCLatency', 'PCLatency', 'MsClickToPhotonLatency', 'ClickToPhotonLatency', 'MsAllInputToPhotonLatency', 'AllInputToPhotonLatency')) {
        if ($cols -notcontains $c) { continue }
        $v = New-Object System.Collections.Generic.List[double]
        foreach ($row in $rows) {
            $x = 0.0
            if ([double]::TryParse([string]$row.$c, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x)) { if ($x -gt 0) { $v.Add($x) } }
        }
        if ($v.Count -ge 20) { return [pscustomobject]@{ Column = $c; Values = $v.ToArray() } }
    }
    return $null
}

function Compare-FrameCaptureSets {
    # Several captures per configuration (5+ each recommended, recorded in the order New-KAbbaSchedule gives).
    # Every metric gets a 95 % interval and a verdict; "not enough data" is a real answer, not a failure.
    param([string[]]$Before, [string[]]$After)
    $metrics = @(
        @('Average FPS', 'AvgFps', $true),
        @('1% low FPS (average of slowest 1%)', 'Low1AvgFps', $true),
        @('1% low FPS (time-weighted)', 'TimeLow1Fps', $true),
        @('Frame-to-frame jitter (ms)', 'JitterMeanMs', $false),
        @('Time spent in stutters (%)', 'StutterTimePct', $false)
    )
    $bs = @(); foreach ($p in $Before) { $bs += Get-FrameStatsV2 (Import-FrameTimes $p) }
    $as = @(); foreach ($p in $After) { $as += Get-FrameStatsV2 (Import-FrameTimes $p) }
    $rows = New-Object System.Collections.ArrayList
    foreach ($m in $metrics) {
        $bv = [double[]]@($bs | ForEach-Object { $_.($m[1]) }); $av = [double[]]@($as | ForEach-Object { $_.($m[1]) })
        $allZero = (@($bv + $av | Where-Object { $_ -ne 0 }).Count -eq 0)
        if ($allZero) { [void]$rows.Add([pscustomobject]@{ Metric = $m[0]; Before = 0; After = 0; ChangePct = 0; CI95 = 'n/a'; Verdict = 'none in any capture' }); continue }
        $c = Compare-KRunSets $bv $av -HigherIsBetter $m[2]
        [void]$rows.Add([pscustomobject]@{ Metric = $m[0]; Before = $c.BeforeMean; After = $c.AfterMean; ChangePct = $c.ChangePct; CI95 = ('{0} .. {1} %' -f $c.CiLowPct, $c.CiHighPct); Verdict = $c.Verdict })
    }
    $bl = @(); foreach ($p in $Before) { $l = Import-LatencyValues $p; if ($l) { $bl += (Get-KMeanVar $l.Values).Mean } }
    $al = @(); foreach ($p in $After) { $l = Import-LatencyValues $p; if ($l) { $al += (Get-KMeanVar $l.Values).Mean } }
    if ($bl.Count -ge 3 -and $al.Count -ge 3) {
        $c = Compare-KRunSets ([double[]]$bl) ([double[]]$al) -HigherIsBetter $false
        [void]$rows.Add([pscustomobject]@{ Metric = 'Input-to-photon latency (ms)'; Before = $c.BeforeMean; After = $c.AfterMean; ChangePct = $c.ChangePct; CI95 = ('{0} .. {1} %' -f $c.CiLowPct, $c.CiHighPct); Verdict = $c.Verdict })
    }
    return [pscustomobject]@{ Rows = @($rows); BeforeRuns = $bs.Count; AfterRuns = $as.Count }
}

function Get-FrameStats {
    # Avg FPS = frames / total time. 1% / 0.1% low = FPS of the average of the slowest 1% / 0.1% of frames.
    param([double[]]$FrameTimes)
    $n = $FrameTimes.Length
    $total = 0.0
    foreach ($x in $FrameTimes) { $total += $x }
    $sorted = [double[]]($FrameTimes | Sort-Object -Descending)
    $k1 = [math]::Max(1, [int][math]::Ceiling($n * 0.01))
    $k01 = [math]::Max(1, [int][math]::Ceiling($n * 0.001))
    $s1 = 0.0; for ($i = 0; $i -lt $k1; $i++) { $s1 += $sorted[$i] }
    $s01 = 0.0; for ($i = 0; $i -lt $k01; $i++) { $s01 += $sorted[$i] }
    $mean = $total / $n
    $var = 0.0
    foreach ($x in $FrameTimes) { $var += [math]::Pow($x - $mean, 2) }
    return [pscustomobject]@{
        Frames   = $n
        AvgFps   = [math]::Round(1000.0 / $mean, 1)
        Low1Fps  = [math]::Round(1000.0 / ($s1 / $k1), 1)
        Low01Fps = [math]::Round(1000.0 / ($s01 / $k01), 1)
        StdDevMs = [math]::Round([math]::Sqrt($var / $n), 2)
    }
}

function Compare-FrameCaptures {
    param([string]$Before, [string]$After)
    $b = Get-FrameStats (Import-FrameTimes $Before)
    $a = Get-FrameStats (Import-FrameTimes $After)
    function Delta($x, $y) { if ($x -eq 0) { return 'n/a' }; $d = (($y - $x) / $x) * 100; return ('{0:+0.0;-0.0}%' -f $d) }
    $rows = @(
        [pscustomobject]@{ Metric = 'Average FPS';     Before = $b.AvgFps;   After = $a.AvgFps;   Change = (Delta $b.AvgFps $a.AvgFps) },
        [pscustomobject]@{ Metric = '1% low FPS';      Before = $b.Low1Fps;  After = $a.Low1Fps;  Change = (Delta $b.Low1Fps $a.Low1Fps) },
        [pscustomobject]@{ Metric = '0.1% low FPS';    Before = $b.Low01Fps; After = $a.Low01Fps; Change = (Delta $b.Low01Fps $a.Low01Fps) },
        [pscustomobject]@{ Metric = 'Frame-time jitter (ms, lower is better)'; Before = $b.StdDevMs; After = $a.StdDevMs; Change = (Delta $b.StdDevMs $a.StdDevMs) }
    )
    return [pscustomobject]@{ Before = $b; After = $a; Rows = $rows }
}

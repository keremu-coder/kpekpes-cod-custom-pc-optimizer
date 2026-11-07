# Topology.ps1 -- CPU layout probe. Windows only.
# Counts L3 caches with GetLogicalProcessorInformationEx: on Ryzen there is one L3 per CCD, so the count is
# the exact number of CCDs. This replaces the old "8 cores or fewer = single CCD" guess.

function Get-KL3CacheCount {
    try {
        if (-not ('Native.KTopology' -as [type])) {
            Add-Type -Namespace Native -Name KTopology -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
static extern bool GetLogicalProcessorInformationEx(int relationship, IntPtr buffer, ref uint length);
public static int CountL3() {
    uint len = 0;
    GetLogicalProcessorInformationEx(2, IntPtr.Zero, ref len);   // 2 = RelationCache
    if (len == 0) return -1;
    IntPtr buf = System.Runtime.InteropServices.Marshal.AllocHGlobal((int)len);
    try {
        if (!GetLogicalProcessorInformationEx(2, buf, ref len)) return -1;
        int off = 0, n = 0;
        while (off < len) {
            int rel  = System.Runtime.InteropServices.Marshal.ReadInt32(buf, off);
            int size = System.Runtime.InteropServices.Marshal.ReadInt32(buf, off + 4);
            // CACHE_RELATIONSHIP starts at offset 8: BYTE Level
            if (rel == 2 && System.Runtime.InteropServices.Marshal.ReadByte(buf, off + 8) == 3) n++;
            if (size <= 0) break;
            off += size;
        }
        return n;
    } finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(buf); }
}
'@
        }
        $n = [Native.KTopology]::CountL3()
        if ($n -gt 0) { return $n }
    } catch { }
    # fallback: WMI (Level 5 = tertiary cache). Less reliable: some firmware reports one combined entry.
    try { return @(Get-CimInstance Win32_CacheMemory -ErrorAction Stop | Where-Object { $_.Level -eq 5 }).Count } catch { return 1 }
}

function Get-PcCpuPolicy {
    # Probe once per run, then decide with the pure Get-KCpuPolicy (lib\Stats.ps1, unit-tested).
    if ($null -ne $script:CpuPolicyCache) { return $script:CpuPolicyCache }
    $name = ''
    try { $name = [string](@(Get-CimInstance Win32_Processor -ErrorAction Stop)[0].Name) } catch { }
    $l3 = 1
    try { $l3 = Get-KL3CacheCount } catch { }
    $script:CpuPolicyCache = Get-KCpuPolicy $name $l3
    return $script:CpuPolicyCache
}
$script:CpuPolicyCache = $null

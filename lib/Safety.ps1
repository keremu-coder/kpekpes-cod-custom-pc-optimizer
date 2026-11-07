# Safety.ps1 -- "may an elevated task trust this path?" checks. Windows only (uses NTFS ACLs).
#
# Rule: anything an elevated task RUNS, LOADS, or tells Defender to SKIP must not be changeable by a
# non-admin account. That means: a trusted owner, and no write-type right for anyone else, on the item
# itself AND on every folder above it (a writable parent lets someone rename the folder and put their own in).

$script:TrustedSids = @(
    'S-1-5-18',        # SYSTEM
    'S-1-5-32-544',    # Administrators
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'   # TrustedInstaller
)

function ConvertTo-KSid {
    param($Identity)
    try { return $Identity.Translate([Security.Principal.SecurityIdentifier]).Value } catch { return [string]$Identity }
}

function Test-KAceGrants {
    # True if an allow-ACE grants any of the rights in $Mask to a non-trusted principal, on this object itself.
    param($Acl, [Security.AccessControl.FileSystemRights]$Mask)
    foreach ($a in $Acl.Access) {
        if ($a.AccessControlType -ne 'Allow') { continue }
        if (($a.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }   # applies to children only
        $sid = ConvertTo-KSid $a.IdentityReference
        if ($script:TrustedSids -contains $sid) { continue }
        if (($a.FileSystemRights -band $Mask) -ne 0) { return $true }
    }
    return $false
}

function Test-KPathSafeForElevation {
    # Returns [pscustomobject]@{ Safe; Reason } -- Reason names the first problem found.
    param([string]$Path)
    $R = [Security.AccessControl.FileSystemRights]
    # rights that let someone change the item itself
    $selfMask = $R::WriteData -bor $R::AppendData -bor $R::WriteExtendedAttributes -bor $R::WriteAttributes -bor $R::Delete -bor $R::ChangePermissions -bor $R::TakeOwnership
    # rights on a PARENT folder that let someone replace or redirect what is inside it
    $parentMask = $R::DeleteSubdirectoriesAndFiles -bor $R::Delete -bor $R::ChangePermissions -bor $R::TakeOwnership
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Safe = $false; Reason = 'does not exist' } }
    $p = (Resolve-Path -LiteralPath $Path).ProviderPath
    $first = $true
    while ($p) {
        try {
            $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                return [pscustomobject]@{ Safe = $false; Reason = ('junction or symlink: ' + $p) }
            }
            $acl = Get-Acl -LiteralPath $p -ErrorAction Stop
        } catch { return [pscustomobject]@{ Safe = $false; Reason = ('cannot read ACL: ' + $p) } }
        $owner = ConvertTo-KSid (New-Object Security.Principal.NTAccount($acl.Owner))
        if ($script:TrustedSids -notcontains $owner) { return [pscustomobject]@{ Safe = $false; Reason = ('owned by ' + $acl.Owner + ': ' + $p) } }
        $mask = $parentMask
        if ($first) { $mask = $selfMask }
        if (Test-KAceGrants $acl $mask) { return [pscustomobject]@{ Safe = $false; Reason = ('writable by a non-admin account: ' + $p) } }
        $first = $false
        $parent = Split-Path -Path $p -Parent
        if (-not $parent -or $parent -eq $p) { break }
        $p = $parent
    }
    return [pscustomobject]@{ Safe = $true; Reason = '' }
}

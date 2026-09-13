#requires -Version 5.1
<#
    Runs INSIDE the guest, and never as an uploaded file.

    The tool directory is where this project's agent, its identity helper, the selected-update
    document and the boot-time helper are written, and where the agent is then started from. If
    an ordinary user can write to that directory - because it did not exist and was created with
    inherited permissions, because someone made it first, or because a link points somewhere
    else - they can replace the agent between the upload and the start and have it run under the
    patching account. So this directory has to be created and proven safe BEFORE the first byte
    is uploaded, which is why this file is executed through `powershell.exe -EncodedCommand`
    rather than transferred and then run.

    Two entry points:
      Initialize-GuestWorkspace -Path <string>   create what is missing, protected, then verify
      Assert-GuestWorkspacePath -Path <string>   verify only

    Nothing here ever takes ownership of, re-permissions, or deletes anything it finds. An
    existing directory that does not meet the contract stops this VM; it is not "fixed".
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# The exit codes are the contract with the orchestrator: GuestOps gives back a process exit
# code and nothing else, and a lost exit code must never be read as success.
$script:GuestWorkspaceExitCodes = [ordered]@{
    Ok                 = 0
    PathRefused        = 10
    OwnerRefused       = 11
    AccessRuleRefused  = 12
    ReparsePoint       = 13
    ParentRefused      = 14
    SecurityUnreadable = 15
    CreateFailed       = 16
    Unexpected         = 17
    SealRefused        = 18
}

# SYSTEM and the local Administrators group. Everything else that can modify the directory or
# its contents is a finding, because everything else is an account that could replace the agent.
$script:GuestWorkspaceAllowedSids = @('S-1-5-18', 'S-1-5-32-544')

function New-GuestWorkspaceVerdict {
    param(
        [string]$Status,
        [string]$Reason = $null,
        [string]$Path = $null
    )

    return [pscustomobject]@{ Status = $Status; Reason = $Reason; Path = $Path }
}

function Get-GuestWorkspaceExitCode {
    param([string]$Status)

    if ($script:GuestWorkspaceExitCodes.Contains($Status)) {
        return [int]$script:GuestWorkspaceExitCodes[$Status]
    }

    return [int]$script:GuestWorkspaceExitCodes['Unexpected']
}

function Test-GuestWorkspacePathShape {
    param([string]$Path)

    # Deliberately the same shape rule the orchestrator applies to -GuestWorkingDirectory, and
    # settled BEFORE GetFullPath: that call resolves a relative path against the current
    # directory and would hand back something absolute that never was.
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return New-GuestWorkspaceVerdict -Status 'PathRefused' -Reason 'No guest directory was supplied.'
    }

    if ($Path.StartsWith('\\')) {
        return New-GuestWorkspaceVerdict -Status 'PathRefused' -Reason 'A UNC path is not a supported guest directory.'
    }

    if ($Path -notmatch '^[A-Za-z]:\\') {
        return New-GuestWorkspaceVerdict -Status 'PathRefused' -Reason 'A guest directory must be an absolute local path such as C:\ProgramData\PatchingGuestOps.'
    }

    $canonical = $null
    try {
        $canonical = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    }
    catch {
        return New-GuestWorkspaceVerdict -Status 'PathRefused' -Reason 'The guest directory is not a usable Windows path.'
    }

    if ($canonical.Length -le 2) {
        return New-GuestWorkspaceVerdict -Status 'PathRefused' -Reason 'A drive root is not a usable guest directory.'
    }

    if (-not [string]::Equals($canonical, $Path.TrimEnd('\'), [System.StringComparison]::Ordinal)) {
        return New-GuestWorkspaceVerdict -Status 'PathRefused' -Reason ('The guest directory is not in canonical form; write "{0}" instead.' -f $canonical)
    }

    return New-GuestWorkspaceVerdict -Status 'Ok' -Path $canonical
}

function Get-GuestWorkspacePathChain {
    param([string]$CanonicalPath)

    # Root first, target last. Used both to create missing levels and to look for a link
    # anywhere above the directory: a reparse point on an ancestor redirects the whole subtree.
    $chain = New-Object System.Collections.ArrayList
    $current = $CanonicalPath
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $null = $chain.Insert(0, $current)
        $parent = [string][System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent, $current, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $parent.TrimEnd('\')
        if ($current.Length -le 2) {
            $null = $chain.Insert(0, ($current + '\'))
            break
        }
    }

    return @($chain)
}

function Test-GuestWorkspaceReparsePoint {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    $attributes = [System.IO.FileAttributes]$item.Attributes
    return (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)
}

function Get-GuestWorkspaceRuleSid {
    param($AccessRule)

    try {
        $identity = $AccessRule.IdentityReference
        if ($identity -is [System.Security.Principal.SecurityIdentifier]) {
            return [string]$identity.Value
        }
        return [string]$identity.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        # An identity that cannot be resolved to a SID cannot be checked against the allow-list,
        # so it is treated as "not allowed" rather than skipped.
        return $null
    }
}

function Test-GuestWorkspaceSidAllowed {
    param([string]$Sid)

    if ([string]::IsNullOrWhiteSpace($Sid)) {
        return $false
    }

    foreach ($allowed in $script:GuestWorkspaceAllowedSids) {
        if ([string]::Equals($Sid, $allowed, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-GuestWorkspaceModifyMask {
    # Everything that lets a principal put different bytes where the agent is expected, or
    # change who may. Read and Execute are deliberately absent: this directory is not secret.
    return ([System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [System.Security.AccessControl.FileSystemRights]::AppendData -bor
        [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership)
}

function Get-GuestWorkspaceReplaceMask {
    # What a parent directory would have to grant for someone to swap the protected directory
    # for one of their own. Creating a NEW entry beside it is not that, which is why WriteData
    # and AppendData are absent here - C:\ProgramData grants them to Users by design.
    return ([System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership)
}

function Test-GuestWorkspaceAccessRules {
    param(
        $Security,
        [System.Security.AccessControl.FileSystemRights]$Mask,
        [switch]$IgnoreInheritOnly
    )

    # Returns the first offending rule description, or $null. Deny rules only ever take access
    # away, so they are never a finding.
    foreach ($rule in @($Security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            continue
        }

        if ($IgnoreInheritOnly -and ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -eq [System.Security.AccessControl.PropagationFlags]::InheritOnly) {
            # An inherit-only rule applies to children this code creates with an explicit,
            # protected descriptor, so it never reaches them.
            continue
        }

        if (([System.Security.AccessControl.FileSystemRights]$rule.FileSystemRights -band $Mask) -eq 0) {
            continue
        }

        $sid = Get-GuestWorkspaceRuleSid -AccessRule $rule
        if (Test-GuestWorkspaceSidAllowed -Sid $sid) {
            continue
        }

        $shownSid = if ([string]::IsNullOrWhiteSpace($sid)) { 'an unresolvable identity' } else { $sid }
        return ('{0} is granted {1}' -f $shownSid, $rule.FileSystemRights)
    }

    return $null
}

function New-GuestWorkspaceSecurity {
    $security = New-Object System.Security.AccessControl.DirectorySecurity

    # Protection first: without it the inherited rules from C:\ProgramData - which let ordinary
    # users create entries - would be copied onto this directory.
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))

    foreach ($sid in $script:GuestWorkspaceAllowedSids) {
        $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    (New-Object System.Security.Principal.SecurityIdentifier($sid)),
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
    }

    return $security
}

function Assert-GuestWorkspacePath {
    param([string]$Path)

    $shape = Test-GuestWorkspacePathShape -Path $Path
    if ($shape.Status -ne 'Ok') {
        return $shape
    }
    $canonical = [string]$shape.Path

    if (-not (Test-Path -LiteralPath $canonical -PathType Container)) {
        return New-GuestWorkspaceVerdict -Status 'PathRefused' -Reason ('The guest directory does not exist: {0}' -f $canonical) -Path $canonical
    }

    # A link anywhere above the directory redirects the whole subtree, so the whole chain is
    # checked, not just the leaf.
    foreach ($segment in @(Get-GuestWorkspacePathChain -CanonicalPath $canonical)) {
        if (-not (Test-Path -LiteralPath $segment)) {
            continue
        }
        try {
            if (Test-GuestWorkspaceReparsePoint -Path $segment) {
                return New-GuestWorkspaceVerdict -Status 'ReparsePoint' -Reason ('A reparse point redirects the guest directory: {0}' -f $segment) -Path $canonical
            }
        }
        catch {
            return New-GuestWorkspaceVerdict -Status 'SecurityUnreadable' -Reason ('Unable to inspect {0}: {1}' -f $segment, $_.Exception.Message) -Path $canonical
        }
    }

    $security = $null
    try {
        $security = Get-Acl -LiteralPath $canonical
    }
    catch {
        # No access to the security descriptor means no evidence of safety. That is a per-VM
        # failure, never a reason to carry on and hope.
        return New-GuestWorkspaceVerdict -Status 'SecurityUnreadable' -Reason ('Unable to read the security descriptor of {0}: {1}' -f $canonical, $_.Exception.Message) -Path $canonical
    }

    $ownerSid = $null
    try {
        $ownerSid = [string]$security.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        return New-GuestWorkspaceVerdict -Status 'SecurityUnreadable' -Reason ('Unable to read the owner of {0}: {1}' -f $canonical, $_.Exception.Message) -Path $canonical
    }

    if (-not (Test-GuestWorkspaceSidAllowed -Sid $ownerSid)) {
        # An owner outside the allow-list can rewrite the DACL whenever they like, so a correct
        # DACL right now proves nothing.
        return New-GuestWorkspaceVerdict -Status 'OwnerRefused' -Reason ('The guest directory {0} is owned by {1}; only SYSTEM or the local Administrators may own it.' -f $canonical, $ownerSid) -Path $canonical
    }

    $offendingRule = Test-GuestWorkspaceAccessRules -Security $security -Mask (Get-GuestWorkspaceModifyMask)
    if ($null -ne $offendingRule) {
        return New-GuestWorkspaceVerdict -Status 'AccessRuleRefused' -Reason ('The guest directory {0} may be modified by an untrusted account: {1}.' -f $canonical, $offendingRule) -Path $canonical
    }

    # The parent is checked for replacement, not for writing: the right to create a NEW entry
    # beside this directory is not the right to remove this one, and C:\ProgramData grants the
    # former to Users by design. Its ACL is never changed here.
    $parentPath = [string][System.IO.Path]::GetDirectoryName($canonical)
    if (-not [string]::IsNullOrWhiteSpace($parentPath) -and (Test-Path -LiteralPath $parentPath -PathType Container)) {
        $parentSecurity = $null
        try {
            $parentSecurity = Get-Acl -LiteralPath $parentPath
        }
        catch {
            return New-GuestWorkspaceVerdict -Status 'SecurityUnreadable' -Reason ('Unable to read the security descriptor of {0}: {1}' -f $parentPath, $_.Exception.Message) -Path $canonical
        }

        $offendingParentRule = Test-GuestWorkspaceAccessRules -Security $parentSecurity -Mask (Get-GuestWorkspaceReplaceMask) -IgnoreInheritOnly
        if ($null -ne $offendingParentRule) {
            return New-GuestWorkspaceVerdict -Status 'ParentRefused' -Reason ('The parent directory {0} lets an untrusted account replace the guest directory: {1}.' -f $parentPath, $offendingParentRule) -Path $canonical
        }
    }

    return New-GuestWorkspaceVerdict -Status 'Ok' -Path $canonical
}

function Get-GuestWorkspaceSealPath {
    param([string]$Path)

    return (Join-Path $Path '.workspace-seal')
}

function Write-GuestWorkspaceSeal {
    param(
        [string]$Path,
        [string]$Token
    )

    # Written by the bootstrap, inside the directory it has just created and verified. It turns
    # "this directory was safe a moment ago" into "this is the same directory we secured": every
    # later step re-reads it, so a directory replaced or re-permissioned mid-phase is caught
    # instead of being trusted on the strength of one check at the start.
    Set-Content -LiteralPath (Get-GuestWorkspaceSealPath -Path $Path) -Value ([string]$Token) -Encoding UTF8 -NoNewline
}

function Assert-GuestWorkspaceSeal {
    param(
        [string]$Path,
        [string]$Token
    )

    # The full directory check runs again first. The token establishes IDENTITY - this is the
    # directory the bootstrap made - and the access-control check establishes AUTHORITY. Neither
    # is sufficient alone: a token nobody can forge in a directory anyone can write to proves
    # nothing, and a correctly permissioned directory that is not the one we sealed is a
    # different directory. The token is not a secret; it does not need to be, because forging the
    # seal in a directory that also passes the owner and ACL checks needs administrator rights.
    $directoryVerdict = Assert-GuestWorkspacePath -Path $Path
    if ($directoryVerdict.Status -ne 'Ok') {
        return $directoryVerdict
    }
    $canonical = [string]$directoryVerdict.Path

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return New-GuestWorkspaceVerdict -Status 'SealRefused' -Reason 'No workspace seal token was supplied.' -Path $canonical
    }

    $sealPath = Get-GuestWorkspaceSealPath -Path $canonical
    $sealFileVerdict = Assert-GuestWorkspaceFilePath -Path $sealPath
    if ($sealFileVerdict.Status -ne 'Ok') {
        return $sealFileVerdict
    }

    if (-not (Test-Path -LiteralPath $sealPath -PathType Leaf)) {
        return New-GuestWorkspaceVerdict -Status 'SealRefused' -Reason ('The workspace seal is missing from {0}.' -f $canonical) -Path $canonical
    }

    $sealValue = $null
    try {
        $sealValue = ([string](Get-Content -LiteralPath $sealPath -Raw)).Trim()
    }
    catch {
        return New-GuestWorkspaceVerdict -Status 'SealRefused' -Reason ('The workspace seal could not be read: {0}' -f $_.Exception.Message) -Path $canonical
    }

    # Ordinal, case-sensitive: the token is a generated GUID in N form, and a value that differs
    # in any way is a different seal.
    if (-not [string]::Equals($sealValue, ([string]$Token).Trim(), [System.StringComparison]::Ordinal)) {
        return New-GuestWorkspaceVerdict -Status 'SealRefused' -Reason ('The workspace seal in {0} does not match this run; the directory was replaced or resealed since it was secured.' -f $canonical) -Path $canonical
    }

    return New-GuestWorkspaceVerdict -Status 'Ok' -Path $canonical
}

function Assert-GuestWorkspaceFilePath {
    param([string]$Path)

    # A safe root does not vouch for a file that was already in it. The boot-time helper is
    # re-used across observation rounds rather than re-uploaded, and it is a script this tool
    # then runs in the guest, so its owner and its rules are checked on every use.
    $shape = Test-GuestWorkspacePathShape -Path $Path
    if ($shape.Status -ne 'Ok') {
        return $shape
    }
    $canonical = [string]$shape.Path

    if (-not (Test-Path -LiteralPath $canonical -PathType Leaf)) {
        # Absent is not unsafe: the caller uploads it. Only a file that exists has to be proven.
        return New-GuestWorkspaceVerdict -Status 'Ok' -Path $canonical
    }

    try {
        if (Test-GuestWorkspaceReparsePoint -Path $canonical) {
            return New-GuestWorkspaceVerdict -Status 'ReparsePoint' -Reason ('A reparse point redirects {0}.' -f $canonical) -Path $canonical
        }
    }
    catch {
        return New-GuestWorkspaceVerdict -Status 'SecurityUnreadable' -Reason ('Unable to inspect {0}: {1}' -f $canonical, $_.Exception.Message) -Path $canonical
    }

    $security = $null
    try {
        $security = Get-Acl -LiteralPath $canonical
    }
    catch {
        return New-GuestWorkspaceVerdict -Status 'SecurityUnreadable' -Reason ('Unable to read the security descriptor of {0}: {1}' -f $canonical, $_.Exception.Message) -Path $canonical
    }

    $ownerSid = $null
    try {
        $ownerSid = [string]$security.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        return New-GuestWorkspaceVerdict -Status 'SecurityUnreadable' -Reason ('Unable to read the owner of {0}: {1}' -f $canonical, $_.Exception.Message) -Path $canonical
    }

    if (-not (Test-GuestWorkspaceSidAllowed -Sid $ownerSid)) {
        return New-GuestWorkspaceVerdict -Status 'OwnerRefused' -Reason ('{0} is owned by {1}; only SYSTEM or the local Administrators may own it.' -f $canonical, $ownerSid) -Path $canonical
    }

    $offendingRule = Test-GuestWorkspaceAccessRules -Security $security -Mask (Get-GuestWorkspaceModifyMask)
    if ($null -ne $offendingRule) {
        return New-GuestWorkspaceVerdict -Status 'AccessRuleRefused' -Reason ('{0} may be modified by an untrusted account: {1}.' -f $canonical, $offendingRule) -Path $canonical
    }

    return New-GuestWorkspaceVerdict -Status 'Ok' -Path $canonical
}

function Initialize-GuestWorkspace {
    param(
        [string]$Path,
        # When given, the directory is sealed with this token once it has been proven safe, and
        # the seal is verified before this call returns.
        [string]$SealToken
    )

    $shape = Test-GuestWorkspacePathShape -Path $Path
    if ($shape.Status -ne 'Ok') {
        return $shape
    }
    $canonical = [string]$shape.Path

    # Each missing level is created with the protected descriptor in its own right. Letting
    # CreateDirectory create the intermediate levels would give them the inherited permissions
    # of their parent, and an attacker who can write to an intermediate level can move the leaf.
    foreach ($segment in @(Get-GuestWorkspacePathChain -CanonicalPath $canonical)) {
        $normalized = if ($segment.Length -le 3) { $segment } else { $segment.TrimEnd('\') }
        if ($normalized.Length -le 3) {
            # The drive root itself is never created and never re-permissioned.
            continue
        }

        if (Test-Path -LiteralPath $normalized -PathType Container) {
            continue
        }

        try {
            $null = [System.IO.Directory]::CreateDirectory($normalized, (New-GuestWorkspaceSecurity))
        }
        catch {
            # Another process may have created it in the same instant. That is not an error by
            # itself - but it does mean this code did not choose the permissions, so the verify
            # pass below has to decide, exactly as it would for a directory found on arrival.
            if (-not (Test-Path -LiteralPath $normalized -PathType Container)) {
                return New-GuestWorkspaceVerdict -Status 'CreateFailed' -Reason ('Unable to create {0}: {1}' -f $normalized, $_.Exception.Message) -Path $canonical
            }
        }
    }

    # Always verify, including what this call just created: a descriptor can be refused,
    # downgraded by policy, or replaced between the create and now.
    $verdict = Assert-GuestWorkspacePath -Path $canonical
    if ($verdict.Status -ne 'Ok') {
        return $verdict
    }

    # Sealed only after the directory has been proven safe, so the seal never vouches for a
    # directory this code would have refused.
    if (-not [string]::IsNullOrWhiteSpace($SealToken)) {
        try {
            Write-GuestWorkspaceSeal -Path $canonical -Token $SealToken
        }
        catch {
            return New-GuestWorkspaceVerdict -Status 'SealRefused' -Reason ('The workspace seal could not be written: {0}' -f $_.Exception.Message) -Path $canonical
        }

        return Assert-GuestWorkspaceSeal -Path $canonical -Token $SealToken
    }

    return $verdict
}

# --- bootstrap dispatch ----------------------------------------------------------------------
# The orchestrator prepends a request object and runs the whole text through
# `powershell.exe -EncodedCommand`, so this file is never uploaded into a directory it has not
# yet proven safe. Dot-sourcing it (the offline tests do) defines the functions and runs nothing.
if (Test-Path -LiteralPath 'Variable:GuestWorkspaceRequest') {
    $guestWorkspaceExitCode = [int]$script:GuestWorkspaceExitCodes['Unexpected']
    try {
        $request = Get-Variable -Name 'GuestWorkspaceRequest' -ValueOnly
        $requestedPath = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String([string]$request.PathBase64))
        $requestedSealBase64 = [string](& { try { [string]$request.SealTokenBase64 } catch { '' } })
        $requestedSealToken = ''
        if (-not [string]::IsNullOrWhiteSpace($requestedSealBase64)) {
            $requestedSealToken = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($requestedSealBase64))
        }

        $verdict = if ([string]$request.Mode -eq 'Assert') {
            if ([string]::IsNullOrWhiteSpace($requestedSealToken)) {
                Assert-GuestWorkspacePath -Path $requestedPath
            }
            else {
                Assert-GuestWorkspaceSeal -Path $requestedPath -Token $requestedSealToken
            }
        }
        else {
            Initialize-GuestWorkspace -Path $requestedPath -SealToken $requestedSealToken
        }

        # An optional second question, asked only once the directory itself is acceptable: is
        # this particular file in it safe to run? Used for the re-used boot-time helper.
        $requestedFileBase64 = [string](& { try { [string]$request.FileBase64 } catch { '' } })
        if ([string]$verdict.Status -eq 'Ok' -and -not [string]::IsNullOrWhiteSpace($requestedFileBase64)) {
            $requestedFile = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($requestedFileBase64))
            $verdict = Assert-GuestWorkspaceFilePath -Path $requestedFile
        }

        $guestWorkspaceExitCode = Get-GuestWorkspaceExitCode -Status ([string]$verdict.Status)
    }
    catch {
        $guestWorkspaceExitCode = [int]$script:GuestWorkspaceExitCodes['Unexpected']
    }

    exit $guestWorkspaceExitCode
}

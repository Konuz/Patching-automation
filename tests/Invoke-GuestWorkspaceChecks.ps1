Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Behaviour tests for the guest workspace guard: the directory this tool uploads its agent into
# has to be created and proven safe BEFORE the first byte is transferred, or an ordinary user
# who can write there can replace the agent between the upload and the start.
#
# Two kinds of test live here. The path, chain, encoding and refusal behaviour is pure logic and
# runs anywhere. The rules themselves - owner, access rules, reparse points, the parent - can
# only be exercised against real Windows security descriptors, so off Windows that section is
# reported as SKIPPED rather than silently passing. A skipped section is not evidence of
# security; it means the ACL behaviour still has to be exercised on a Windows host.

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/GuestOpsLib.ps1')
. (Join-Path $repoRoot 'guest/GuestWorkspace.ps1')

$failures = @()
$skipped = @()

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { $script:failures += ('{0}: expected {1}, got {2}' -f $Message, $Expected, $Actual) }
}

function Assert-Contains {
    param([string]$Text, [string]$Needle, [string]$Message)
    if (([string]$Text).IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $script:failures += ('{0}: "{1}" is missing from "{2}"' -f $Message, $Needle, $Text)
    }
}

function Test-IsWindowsHost {
    # $IsWindows only exists on PowerShell Core; on Windows PowerShell 5.1 the platform is
    # Windows by definition.
    if (Test-Path -LiteralPath 'Variable:IsWindows') {
        return [bool](Get-Variable -Name 'IsWindows' -ValueOnly)
    }
    return $true
}

# --- path shape --------------------------------------------------------------------------------
# The same rule the orchestrator applies to -GuestWorkingDirectory, restated here because the
# guest side must not depend on the caller having checked anything.

foreach ($refusedPath in @(
        '',
        '   ',
        '\\server\share\PatchingGuestOps',
        'ProgramData\PatchingGuestOps',
        'C:',
        'C:\',
        'C:\ProgramData\..\ProgramData\PatchingGuestOps',
        'C:\ProgramData/PatchingGuestOps',
        'C:\ProgramData\\PatchingGuestOps'
    )) {
    $verdict = Test-GuestWorkspacePathShape -Path $refusedPath
    Assert-Equal $verdict.Status 'PathRefused' ('a path that is not canonical and absolute is refused: "' + $refusedPath + '"')
}

$acceptedShape = Test-GuestWorkspacePathShape -Path 'C:\ProgramData\PatchingGuestOps'
Assert-Equal $acceptedShape.Status 'Ok' 'a canonical absolute path is accepted'
Assert-Equal $acceptedShape.Path 'C:\ProgramData\PatchingGuestOps' 'the accepted path is returned unchanged'

$trailingShape = Test-GuestWorkspacePathShape -Path 'C:\ProgramData\PatchingGuestOps\'
Assert-Equal $trailingShape.Status 'Ok' 'a trailing separator does not make a path non-canonical'
Assert-Equal $trailingShape.Path 'C:\ProgramData\PatchingGuestOps' 'the trailing separator is trimmed'

# --- the chain of levels -----------------------------------------------------------------------
# Every missing level is created with the protected descriptor in its own right. If the chain were
# wrong, CreateDirectory would make the intermediate levels with inherited permissions, and being
# able to write to an intermediate level is enough to move the leaf.

$chain = @(Get-GuestWorkspacePathChain -CanonicalPath 'C:\ProgramData\PatchingGuestOps\abc123')
Assert-Equal ($chain -join ';') 'C:\;C:\ProgramData;C:\ProgramData\PatchingGuestOps;C:\ProgramData\PatchingGuestOps\abc123' 'the chain runs from the drive root down to the target'

$shallowChain = @(Get-GuestWorkspacePathChain -CanonicalPath 'C:\Tools')
Assert-Equal ($shallowChain -join ';') 'C:\;C:\Tools' 'a one-level path still yields its root'

# --- exit code contract -------------------------------------------------------------------------
# GuestOps hands back an exit code and nothing else, so the two tables must agree. A code the
# orchestrator does not recognise, and a missing code, both have to fail the VM.

foreach ($status in @('PathRefused', 'OwnerRefused', 'AccessRuleRefused', 'ReparsePoint', 'ParentRefused', 'SecurityUnreadable', 'CreateFailed', 'Unexpected')) {
    $code = Get-GuestWorkspaceExitCode -Status $status
    Assert-Equal ($code -gt 0) $true ('the guest maps ' + $status + ' to a non-zero exit code')
    Assert-Equal ($null -ne (Get-GuestWorkspaceFailureReason -ExitCode $code)) $true ('the orchestrator recognises the exit code for ' + $status)
}

Assert-Equal (Get-GuestWorkspaceExitCode -Status 'Ok') 0 'only success exits zero'
Assert-Equal (Get-GuestWorkspaceFailureReason -ExitCode 0) $null 'exit code zero is the only success'
Assert-Equal (Get-GuestWorkspaceExitCode -Status 'SomethingElse') (Get-GuestWorkspaceExitCode -Status 'Unexpected') 'an unknown status is reported as unexpected, never as success'
Assert-Contains (Get-GuestWorkspaceFailureReason -ExitCode 99) 'unrecognised' 'an unrecognised exit code is a failure'
Assert-Contains (Get-GuestWorkspaceFailureReason -ExitCode $null) 'never reported an exit code' 'a lost exit code is a failure, not a pass'

# --- the bootstrap command ------------------------------------------------------------------------
# Built from the trusted local copy and run through -EncodedCommand, so the guard is never
# uploaded into the directory it is meant to be guarding.

$workspaceScriptPath = Join-Path $repoRoot 'guest/GuestWorkspace.ps1'
$workspaceScriptText = Get-GuestWorkspaceScriptText -WorkspaceScriptPath $workspaceScriptPath
Assert-Contains $workspaceScriptText 'function Assert-GuestWorkspacePath' 'the helper source is read from the local copy'

$encoded = New-GuestWorkspaceBootstrapCommand -WorkspaceScriptText $workspaceScriptText -Path 'C:\ProgramData\PatchingGuestOps' -Mode 'Initialize'
$decoded = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($encoded))
Assert-Contains $decoded 'GuestWorkspaceRequest' 'the bootstrap carries a request object'
Assert-Contains $decoded 'function Initialize-GuestWorkspace' 'the bootstrap carries the whole guard'

# The path travels as data. A directory name is operator input, so interpolating it into the
# command text would make it a place where PowerShell syntax can be written.
$injectionPath = "C:\ProgramData\Patch'; Stop-Computer -Force; '"
$injectionEncoded = New-GuestWorkspaceBootstrapCommand -WorkspaceScriptText 'function Initialize-GuestWorkspace { }' -Path $injectionPath
$injectionDecoded = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($injectionEncoded))
Assert-Equal ($injectionDecoded.Contains('Stop-Computer')) $false 'the requested path never appears as code in the bootstrap'
Assert-Contains $injectionDecoded ([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($injectionPath))) 'the requested path travels base64-encoded as data'

$fileScopedEncoded = New-GuestWorkspaceBootstrapCommand -WorkspaceScriptText 'function Initialize-GuestWorkspace { }' -Path 'C:\ProgramData\PatchingGuestOps' -FilePath 'C:\ProgramData\PatchingGuestOps\Read-BootTime-vm.ps1'
$fileScopedDecoded = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($fileScopedEncoded))
Assert-Contains $fileScopedDecoded ([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('C:\ProgramData\PatchingGuestOps\Read-BootTime-vm.ps1'))) 'a re-used guest file is named as data too'

# --- what the orchestrator does with the verdict ---------------------------------------------------

& {
    $script:workspaceProcessId = 0
    $script:workspaceExitCode = 0
    $script:workspaceCompleted = $true
    $script:workspaceArguments = ''

    $fakeProcessManager = [pscustomobject]@{}
    $fakeProcessManager | Add-Member ScriptMethod StartProgramInGuest {
        param($MoRef, $GuestAuth, $Spec)
        $script:workspaceArguments = [string]$Spec.Arguments
        $script:workspaceProcessId++
        return 4100
    }
    $fakeVMView = [pscustomobject]@{ MoRef = 'vm-fixture' }

    # The bootstrap start builds a VMware.Vim.GuestProgramSpec, which needs PowerCLI loaded, so
    # this fixture stands in for it and records what would have been asked of the guest.
    function Start-GuestWorkspaceBootstrap {
        param($ProcessManager, $VMView, $GuestAuth, [string]$EncodedCommand)
        return $ProcessManager.StartProgramInGuest($VMView.MoRef, $GuestAuth, [pscustomobject]@{ Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {0}' -f $EncodedCommand) })
    }
    function Wait-GuestProcess {
        param($ProcessManager, $VMView, $GuestAuth, [long]$ProcessId, [int]$TimeoutSeconds, [int]$PollSeconds)
        return [pscustomobject]@{ Completed = $script:workspaceCompleted; ExitCode = $script:workspaceExitCode; EndTime = (Get-Date) }
    }

    $invokeWorkspace = {
        param($ExitCode, $Completed)
        $script:workspaceExitCode = $ExitCode
        $script:workspaceCompleted = $Completed
        try {
            Assert-GuestWorkspaceReady -ProcessManager $fakeProcessManager -VMView $fakeVMView -GuestAuth $null -VMName 'vm-fixture' -Path 'C:\ProgramData\PatchingGuestOps' -WorkspaceScriptPath $workspaceScriptPath -TimeoutSeconds 5 -PollSeconds 1
            return ''
        }
        catch {
            return [string]$_.Exception.Message
        }
    }

    Assert-Equal (& $invokeWorkspace 0 $true) '' 'a guest that reports success lets the phase continue'
    Assert-Contains $script:workspaceArguments '-EncodedCommand' 'the guard runs through -EncodedCommand, never as an uploaded file'
    Assert-Equal ($script:workspaceArguments -like '*-NoProfile*') $true 'the guard runs without a profile'

    foreach ($case in @(
            [pscustomobject]@{ Code = 10; Needle = 'not an acceptable guest directory' },
            [pscustomobject]@{ Code = 11; Needle = 'owned by an account' },
            [pscustomobject]@{ Code = 12; Needle = 'untrusted account modify' },
            [pscustomobject]@{ Code = 13; Needle = 'reparse point' },
            [pscustomobject]@{ Code = 14; Needle = 'parent directory' },
            [pscustomobject]@{ Code = 15; Needle = 'security descriptor could not be read' },
            [pscustomobject]@{ Code = 16; Needle = 'could not be created' },
            [pscustomobject]@{ Code = 17; Needle = 'unexpected error' },
            [pscustomobject]@{ Code = 99; Needle = 'unrecognised' }
        )) {
        $message = & $invokeWorkspace $case.Code $true
        Assert-Contains $message $case.Needle ('exit code ' + $case.Code + ' fails the VM with its reason')
        Assert-Contains $message 'Nothing was uploaded' ('exit code ' + $case.Code + ' says nothing was uploaded')
    }

    Assert-Contains (& $invokeWorkspace $null $true) 'never reported an exit code' 'a lost exit code fails the VM'
    Assert-Contains (& $invokeWorkspace 0 $false) 'did not finish' 'a workspace check that never finished fails the VM'
}

# --- nothing is uploaded, and no agent starts, after a refused workspace ---------------------------
# The acceptance criterion of this change: not "it throws", but that no transfer and no agent
# start happened on the way to throwing.

& {
    $script:uploads = @()
    $script:agentStarts = 0
    $script:workspaceChecks = @()

    function Get-ExactVM {
        param($Name, $Servers)
        return [pscustomobject]@{ Name = $Name; ExtensionData = [pscustomobject]@{} }
    }
    function Assert-VMReadyForGuestOps { param($VM) }
    function Get-GuestOpsManagers { param($VMView) return [pscustomobject]@{ ProcessManager = 'process'; FileManager = 'file'; AuthManager = 'auth' } }
    function Get-VMHostNameForTransfer { param($VMView) return 'esxi.invalid' }
    function Send-GuestFile {
        param($FileManager, $VMView, $GuestAuth, $HostName, $CurlPath, $LocalPath, $GuestPath, $TimeoutSeconds)
        $script:uploads += [string]$GuestPath
    }
    function Start-GuestAgent {
        param($ProcessManager, $VMView, $GuestAuth, $GuestAgentPath, $GuestWorkingDirectory, $MaxUpdates, $SelectedUpdateKeys, $SelectionPath, $RunId, [switch]$SearchOnly)
        $script:agentStarts++
        return 5150
    }
    function Assert-GuestWorkspaceReady {
        param($ProcessManager, $VMView, $GuestAuth, [string]$VMName, [string]$Path, [string]$WorkspaceScriptPath, [string]$Mode = 'Initialize', [string]$FilePath, [int]$TimeoutSeconds = 120, [int]$PollSeconds = 5)
        $script:workspaceChecks += [string]$Path
        throw ('Guest directory "{0}" on {1} cannot be used: synthetic refusal. Nothing was uploaded to it.' -f $Path, $VMName)
    }

    $outputDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-workspace-' + [guid]::NewGuid().ToString('N'))
    try {
        $cycleError = ''
        try {
            Start-VMAgentCycle -VMName 'vm-refused' -Servers @('vc.invalid') -Managers $null -GuestAuth $null -CurlPath 'curl.exe' -AgentPath 'unused' -IdentityHelperPath 'unused' -GuestWorkingDirectory 'C:\ProgramData\PatchingGuestOps' -VMOutputDirectory $outputDirectory -MaxUpdates 1 -WorkspaceScriptPath $workspaceScriptPath | Out-Null
        }
        catch {
            $cycleError = [string]$_.Exception.Message
        }

        Assert-Contains $cycleError 'cannot be used' 'a refused workspace stops the cycle'
        Assert-Equal $script:uploads.Count 0 'a refused workspace uploads nothing'
        Assert-Equal $script:agentStarts 0 'a refused workspace starts no agent'
        Assert-Equal $script:workspaceChecks.Count 1 'the workspace is checked once, before the transfers'
        Assert-Equal ($script:workspaceChecks[0] -like 'C:\ProgramData\PatchingGuestOps\*') $true 'the cycle directory itself is the path that must be secured'
    }
    finally {
        Remove-Item -LiteralPath $outputDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- the rules themselves, against real security descriptors --------------------------------------
# Only in a private temporary directory, and never against the real C:\ProgramData. A domain
# account is never required: every identity used here is a well-known local SID.

if (-not (Test-IsWindowsHost)) {
    $skipped += 'Windows access-control rules (owner, access rules, reparse points, parent) - this host has no Windows security descriptors.'
}
else {
    $aclRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-acl-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $aclRoot
    try {
        $usersSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')

        # 1. A directory this code creates is accepted, and its levels are created protected.
        $createdPath = Join-Path $aclRoot 'created\PatchingGuestOps'
        $created = Initialize-GuestWorkspace -Path $createdPath
        Assert-Equal $created.Status 'Ok' 'a workspace this code creates is accepted'
        Assert-Equal (Test-Path -LiteralPath (Join-Path $aclRoot 'created') -PathType Container) $true 'the missing intermediate level was created too'

        $createdSecurity = Get-Acl -LiteralPath $createdPath
        Assert-Equal $createdSecurity.AreAccessRulesProtected $true 'the created directory does not inherit its permissions'
        Assert-Equal ([string]$createdSecurity.GetOwner([System.Security.Principal.SecurityIdentifier]).Value) 'S-1-5-32-544' 'the created directory is owned by the local Administrators'
        Assert-Equal (Test-GuestWorkspaceAccessRules -Security $createdSecurity -Mask (Get-GuestWorkspaceModifyMask)) $null 'the created directory grants modification to nobody outside the allow-list'

        # The intermediate level is protected in its own right: being able to write there is
        # enough to move the leaf.
        $intermediateSecurity = Get-Acl -LiteralPath (Join-Path $aclRoot 'created')
        Assert-Equal $intermediateSecurity.AreAccessRulesProtected $true 'an intermediate level is created protected, not with inherited permissions'

        # 2. Initialize on an existing, correct directory is accepted and changes nothing.
        $reinitialized = Initialize-GuestWorkspace -Path $createdPath
        Assert-Equal $reinitialized.Status 'Ok' 'an already-correct workspace is accepted as it is'

        # 3. An access rule that lets ordinary users write is refused, and is NOT repaired.
        $writablePath = Join-Path $aclRoot 'writable'
        $null = New-Item -ItemType Directory -Force -Path $writablePath
        $writableSecurity = Get-Acl -LiteralPath $writablePath
        $writableSecurity.SetAccessRuleProtection($true, $false)
        $writableSecurity.SetOwner($administratorsSid)
        $writableSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($administratorsSid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        $writableSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usersSid, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $writablePath -AclObject $writableSecurity
        $writableVerdict = Assert-GuestWorkspacePath -Path $writablePath
        Assert-Equal $writableVerdict.Status 'AccessRuleRefused' 'a directory ordinary users may modify is refused'
        $stillWritable = Get-Acl -LiteralPath $writablePath
        Assert-Equal ($null -ne (Test-GuestWorkspaceAccessRules -Security $stillWritable -Mask (Get-GuestWorkspaceModifyMask))) $true 'a refused directory is reported, never silently re-permissioned'
        Assert-Equal (Initialize-GuestWorkspace -Path $writablePath).Status 'AccessRuleRefused' 'Initialize does not adopt an unsafe existing directory either'

        # 4. A read-only rule for ordinary users is fine: this directory is not secret.
        $readablePath = Join-Path $aclRoot 'readable'
        $null = New-Item -ItemType Directory -Force -Path $readablePath
        $readableSecurity = Get-Acl -LiteralPath $readablePath
        $readableSecurity.SetAccessRuleProtection($true, $false)
        $readableSecurity.SetOwner($administratorsSid)
        $readableSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($administratorsSid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        $readableSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usersSid, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $readablePath -AclObject $readableSecurity
        Assert-Equal (Assert-GuestWorkspacePath -Path $readablePath).Status 'Ok' 'read access for ordinary users is not a finding'

        # 5. An owner outside the allow-list is refused even when the rules look right: an owner
        #    can rewrite the DACL whenever they like, so a correct DACL proves nothing.
        $ownedPath = Join-Path $aclRoot 'foreign-owner'
        $null = New-Item -ItemType Directory -Force -Path $ownedPath
        $ownedSecurity = Get-Acl -LiteralPath $ownedPath
        $ownedSecurity.SetAccessRuleProtection($true, $false)
        $ownedSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($administratorsSid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        $ownedSecurity.SetOwner($usersSid)
        $ownerSetFailed = $false
        try { Set-Acl -LiteralPath $ownedPath -AclObject $ownedSecurity } catch { $ownerSetFailed = $true }
        if ($ownerSetFailed) {
            $skipped += 'owner refusal - this host does not allow assigning the test owner (SeRestorePrivilege).'
        }
        else {
            Assert-Equal (Assert-GuestWorkspacePath -Path $ownedPath).Status 'OwnerRefused' 'a directory owned outside the allow-list is refused'
        }

        # 6. A reparse point anywhere in the path is refused: it redirects the whole subtree.
        $linkTarget = Join-Path $aclRoot 'link-target'
        $null = New-Item -ItemType Directory -Force -Path $linkTarget
        $linkPath = Join-Path $aclRoot 'link'
        $linkFailed = $false
        try { $null = New-Item -ItemType Junction -Path $linkPath -Target $linkTarget -ErrorAction Stop } catch { $linkFailed = $true }
        if ($linkFailed) {
            $skipped += 'reparse point refusal - this host does not allow creating a junction here.'
        }
        else {
            Assert-Equal (Assert-GuestWorkspacePath -Path $linkPath).Status 'ReparsePoint' 'a directory that is a reparse point is refused'
            $belowLink = Join-Path $linkPath 'PatchingGuestOps'
            $null = New-Item -ItemType Directory -Force -Path $belowLink
            Assert-Equal (Assert-GuestWorkspacePath -Path $belowLink).Status 'ReparsePoint' 'a reparse point above the directory is refused too'
        }

        # 7. A parent that lets ordinary users delete its children is refused - that is enough to
        #    swap the protected directory for one of their own. Being able to create a new entry
        #    beside it is not, which is why C:\ProgramData's own layout stays acceptable.
        $replaceableParent = Join-Path $aclRoot 'replaceable'
        $null = New-Item -ItemType Directory -Force -Path $replaceableParent
        $parentSecurity = Get-Acl -LiteralPath $replaceableParent
        $parentSecurity.SetAccessRuleProtection($true, $false)
        $parentSecurity.SetOwner($administratorsSid)
        $parentSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($administratorsSid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        $parentSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usersSid, 'DeleteSubdirectoriesAndFiles', 'None', 'None', 'Allow')))
        Set-Acl -LiteralPath $replaceableParent -AclObject $parentSecurity
        $childUnderReplaceable = Join-Path $replaceableParent 'PatchingGuestOps'
        $childCreated = Initialize-GuestWorkspace -Path $childUnderReplaceable
        Assert-Equal $childCreated.Status 'ParentRefused' 'a parent that lets ordinary users delete its children is refused'

        $creatableParent = Join-Path $aclRoot 'creatable'
        $null = New-Item -ItemType Directory -Force -Path $creatableParent
        $creatableSecurity = Get-Acl -LiteralPath $creatableParent
        $creatableSecurity.SetAccessRuleProtection($true, $false)
        $creatableSecurity.SetOwner($administratorsSid)
        $creatableSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($administratorsSid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        $creatableSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usersSid, 'CreateFiles,CreateDirectories,ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $creatableParent -AclObject $creatableSecurity
        Assert-Equal (Initialize-GuestWorkspace -Path (Join-Path $creatableParent 'PatchingGuestOps')).Status 'Ok' 'a parent that only lets ordinary users add new entries is accepted'

        # 8. A file already in a safe directory is not vouched for by the directory.
        $helperHome = Join-Path $aclRoot 'helper-home'
        Assert-Equal (Initialize-GuestWorkspace -Path $helperHome).Status 'Ok' 'the helper directory is protected'
        $trustedHelper = Join-Path $helperHome 'Read-BootTime-vm.ps1'
        Set-Content -LiteralPath $trustedHelper -Value '# fixture' -Encoding UTF8
        Assert-Equal (Assert-GuestWorkspaceFilePath -Path $trustedHelper).Status 'Ok' 'a file created inside the protected directory is accepted'
        Assert-Equal (Assert-GuestWorkspaceFilePath -Path (Join-Path $helperHome 'absent.ps1')).Status 'Ok' 'a file that does not exist yet is not a finding - the caller uploads it'

        $untrustedHelper = Join-Path $helperHome 'Read-BootTime-untrusted.ps1'
        Set-Content -LiteralPath $untrustedHelper -Value '# fixture' -Encoding UTF8
        $helperSecurity = Get-Acl -LiteralPath $untrustedHelper
        $helperSecurity.SetAccessRuleProtection($true, $false)
        $helperSecurity.SetOwner($administratorsSid)
        $helperSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($administratorsSid, 'FullControl', 'None', 'None', 'Allow')))
        $helperSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usersSid, 'Modify', 'None', 'None', 'Allow')))
        Set-Acl -LiteralPath $untrustedHelper -AclObject $helperSecurity
        Assert-Equal (Assert-GuestWorkspaceFilePath -Path $untrustedHelper).Status 'AccessRuleRefused' 'a helper an ordinary user may rewrite is refused even inside a safe directory'
    }
    finally {
        # Only ever the private test directory, and only when it is still the one this run made.
        if ($aclRoot -like '*guestops-acl-*') {
            Remove-Item -LiteralPath $aclRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

foreach ($skip in $skipped) {
    Write-Host ('SKIPPED: ' + $skip)
}

if ($failures.Count -gt 0) {
    Write-Host 'Guest workspace checks failed:'
    foreach ($failure in $failures) { Write-Host (' - ' + $failure) }
    exit 1
}

if ($skipped.Count -gt 0) {
    Write-Host 'Guest workspace checks passed, with skipped sections listed above. A skipped section is not evidence of security.'
}
else {
    Write-Host 'Guest workspace checks passed.'
}
exit 0

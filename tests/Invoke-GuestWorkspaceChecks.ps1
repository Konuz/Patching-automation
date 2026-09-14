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
. (Join-Path $repoRoot 'guest/GuestRunGuard.ps1')

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

# --- the seal: identity on top of authority -------------------------------------------------------
# The owner and access-rule checks answer "who may write here". They cannot answer "is this the
# same directory we secured", because a directory created and permissioned identically by someone
# else passes them all. The seal answers that, and it is re-read by every guest-side step after the
# bootstrap - the agent before it creates the WUA session, the boot-time helper before it reports.
#
# The access-control part of the verdict needs real Windows security descriptors, so this section
# stubs it out and exercises the token comparison alone; the Windows-only section below runs the
# whole thing against a real directory.

& {
    function Assert-GuestWorkspacePath { param([string]$Path) return (New-GuestWorkspaceVerdict -Status 'Ok' -Path $Path) }
    function Assert-GuestWorkspaceFilePath { param([string]$Path) return (New-GuestWorkspaceVerdict -Status 'Ok' -Path $Path) }

    $sealRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-seal-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $sealRoot
    try {
        $token = New-GuestWorkspaceSealToken
        Assert-Equal ($token -match '^[0-9a-f]{32}$') $true 'the seal token is a generated GUID in N form'
        Assert-Equal ((New-GuestWorkspaceSealToken) -ne $token) $true 'every cycle gets its own token'

        # Nothing written yet: an unsealed directory is refused, so a directory that merely looks
        # right cannot be mistaken for the one this run secured.
        Assert-Equal (Assert-GuestWorkspaceSeal -Path $sealRoot -Token $token).Status 'SealRefused' 'a directory with no seal is refused'

        Write-GuestWorkspaceSeal -Path $sealRoot -Token $token
        Assert-Equal (Test-Path -LiteralPath (Get-GuestWorkspaceSealPath -Path $sealRoot) -PathType Leaf) $true 'the seal is written inside the directory it seals'
        Assert-Equal (Assert-GuestWorkspaceSeal -Path $sealRoot -Token $token).Status 'Ok' 'the token written by the bootstrap verifies'

        # A different token is the case this whole mechanism exists for: the directory was
        # replaced or resealed between the bootstrap and this step.
        $otherVerdict = Assert-GuestWorkspaceSeal -Path $sealRoot -Token (New-GuestWorkspaceSealToken)
        Assert-Equal $otherVerdict.Status 'SealRefused' 'a token that does not match the seal is refused'
        Assert-Contains $otherVerdict.Reason 'replaced or resealed' 'the refusal says what it means'

        # Resealing by someone else does not make the earlier run pass: the token on disk is
        # theirs now, and this run has to stop rather than work in a directory it no longer owns.
        $intruderToken = New-GuestWorkspaceSealToken
        Write-GuestWorkspaceSeal -Path $sealRoot -Token $intruderToken
        Assert-Equal (Assert-GuestWorkspaceSeal -Path $sealRoot -Token $token).Status 'SealRefused' 'a resealed directory refuses the original token'
        Assert-Equal (Assert-GuestWorkspaceSeal -Path $sealRoot -Token $intruderToken).Status 'Ok' 'the seal verifies against whatever token is actually on disk'

        # Ordinal, so a token differing only in case is a different token.
        Write-GuestWorkspaceSeal -Path $sealRoot -Token 'abcdef0123456789abcdef0123456789'
        Assert-Equal (Assert-GuestWorkspaceSeal -Path $sealRoot -Token 'ABCDEF0123456789ABCDEF0123456789').Status 'SealRefused' 'the comparison is case-sensitive'

        # An empty or missing token is refused rather than treated as "no seal required": the
        # caller asking for a seal check with nothing to check is a programming error, and
        # answering Ok would turn it into a silent bypass.
        foreach ($emptyToken in @('', '   ', $null)) {
            Assert-Equal (Assert-GuestWorkspaceSeal -Path $sealRoot -Token $emptyToken).Status 'SealRefused' 'a seal check with no token is refused, never accepted'
        }

        # Deleting the seal is not a way past it either.
        Remove-Item -LiteralPath (Get-GuestWorkspaceSealPath -Path $sealRoot) -Force
        Assert-Equal (Assert-GuestWorkspaceSeal -Path $sealRoot -Token $intruderToken).Status 'SealRefused' 'removing the seal refuses the run rather than skipping the check'
    }
    finally {
        if ($sealRoot -like '*guestops-seal-*') {
            Remove-Item -LiteralPath $sealRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# The access-control verdict outranks the token: a directory whose permissions no longer hold is
# reported as such, not as a seal mismatch, so the operator is told which of the two failed.
& {
    function Assert-GuestWorkspacePath { param([string]$Path) return (New-GuestWorkspaceVerdict -Status 'AccessRuleRefused' -Reason 'synthetic' -Path $Path) }
    Assert-Equal (Assert-GuestWorkspaceSeal -Path 'C:\ProgramData\PatchingGuestOps' -Token 'anything').Status 'AccessRuleRefused' 'a directory that fails its access-control check is not reported as a seal mismatch'
}

# A refused seal has its own exit code, and the orchestrator recognises it.
Assert-Equal (Get-GuestWorkspaceExitCode -Status 'SealRefused') 18 'a refused seal has its own exit code'
Assert-Contains (Get-GuestWorkspaceFailureReason -ExitCode 18) 'seal' 'the orchestrator explains a refused seal'

# The token travels as data, like the path: it is written into the directory the bootstrap secures,
# and interpolating it into the command text would make it another place syntax can be written.
& {
    $sealInjection = "abc'; Stop-Computer -Force; '"
    $encodedSeal = New-GuestWorkspaceBootstrapCommand -WorkspaceScriptText 'function Initialize-GuestWorkspace { }' -Path 'C:\ProgramData\PatchingGuestOps' -Mode 'Initialize' -SealToken $sealInjection
    $decodedSeal = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($encodedSeal))
    Assert-Equal ($decodedSeal.Contains('Stop-Computer')) $false 'the seal token never appears as code in the bootstrap'
    Assert-Contains $decodedSeal ([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($sealInjection))) 'the seal token travels base64-encoded as data'
}

# --- the bootstrap command ------------------------------------------------------------------------
# Built from the trusted local copy and run through an in-memory compressed command, so the guard is never
# uploaded into the directory it is meant to be guarding.

$workspaceScriptPath = Join-Path $repoRoot 'guest/GuestWorkspace.ps1'
$workspaceScriptText = Get-GuestWorkspaceScriptText -WorkspaceScriptPath $workspaceScriptPath
Assert-Contains $workspaceScriptText 'function Assert-GuestWorkspacePath' 'the helper source is read from the local copy'

$encoded = New-GuestWorkspaceBootstrapCommand -WorkspaceScriptText $workspaceScriptText -Path 'C:\ProgramData\PatchingGuestOps' -Mode 'Initialize'
$decoded = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($encoded))
Assert-Contains $decoded 'GuestWorkspaceRequest' 'the bootstrap carries a request object'
Assert-Contains $decoded 'GZipStream' 'the bootstrap carries the guard compressed in memory'

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

# Exercise the exact native command line on Windows, not just a permissive fake vSphere.
& {
    $runBootstrap = {
        param([string]$EncodedCommand)
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $startInfo.Arguments = New-GuestBootstrapArguments -EncodedCommand $EncodedCommand
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        try {
            if (-not $process.WaitForExit(30000)) {
                $process.Kill()
                throw 'The local bootstrap test did not finish in 30 seconds.'
            }
            return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $process.StandardOutput.ReadToEnd().Trim(); Error = $process.StandardError.ReadToEnd() }
        }
        finally { $process.Dispose() }
    }
    # Assert rejects a relative path before accessing any guest directory or changing ACLs.
    $workspaceCommand = New-GuestWorkspaceBootstrapCommand -WorkspaceScriptText $workspaceScriptText -Path 'relative' -Mode Assert
    $workspaceResult = & $runBootstrap $workspaceCommand
    Assert-Equal $workspaceResult.ExitCode 10 'the complete compressed workspace guard runs in Windows PowerShell and preserves its refusal exit code'
    Assert-Equal $workspaceResult.Error '' 'the compressed workspace guard produces no parser or decompression errors'

    $runGuardText = Get-Content (Join-Path $repoRoot 'guest/GuestRunGuard.ps1') -Raw
    $rebootText = Get-Content (Join-Path $repoRoot 'guest/Request-GuestReboot.ps1') -Raw
    $realRebootCommand = New-GuestRebootBootstrapCommand -WorkspaceScriptText $workspaceScriptText -RunGuardScriptText $runGuardText -RebootScriptText $rebootText -RunId 'size-check'
    Assert-Equal ((New-GuestBootstrapArguments $realRebootCommand).Length -le 32000) $true 'the complete real reboot command fits the Windows limit'
    # Never execute the reboot request locally. A harmless final script checks that both real
    # libraries and the request data survive decompression into the same scope.
    $comment = "test 'quoted' " + [char]0x0142 + '; exit 99'
    $commentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($comment))
    $probe = 'if ((Get-GuestWorkspaceExitCode -Status PathRefused) -ne 10 -or -not (Get-Command Enter-GuestRunGuard)) { exit 99 }; Write-Output $GuestRebootRequest.CommentBase64; exit 20'
    $rebootCommand = New-GuestRebootBootstrapCommand -WorkspaceScriptText $workspaceScriptText -RunGuardScriptText $runGuardText -RebootScriptText $probe -RunId 'safe-probe' -Comment $comment
    $rebootResult = & $runBootstrap $rebootCommand
    Assert-Equal $rebootResult.ExitCode 20 'the compressed reboot payload preserves its exit code and helper scope'
    Assert-Equal $rebootResult.Output $commentBase64 'Unicode and quoted reboot data survive as data'
    Assert-Equal $rebootResult.Error '' 'the compressed reboot probe produces no parser or decompression errors'

    $oversized = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(('x' * 33000)))
    $sizeError = ''
    try { $null = New-GuestBootstrapArguments $oversized } catch { $sizeError = $_.Exception.Message }
    Assert-Contains $sizeError 'too long' 'oversized future bootstraps fail locally before GuestOps'
}

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
        return $ProcessManager.StartProgramInGuest($VMView.MoRef, $GuestAuth, [pscustomobject]@{ Arguments = (New-GuestBootstrapArguments -EncodedCommand $EncodedCommand) })
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
    Assert-Contains $script:workspaceArguments '-Command' 'the guard runs in memory, never as an uploaded file'
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

# --- one run per guest, with two real processes ---------------------------------------------------
# Not "FileShare::None appears in the source": two actual PowerShell processes, different run ids
# and different working directories, against one coordination directory. Two WUA sessions
# installing on one guest corrupt each other's work, so this is the property that matters.

& {
    $guardRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-guard-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $guardRoot
    try {
        $guardScriptPath = Join-Path $repoRoot 'guest/GuestRunGuard.ps1'
        $workspaceScriptPathForGuard = Join-Path $repoRoot 'guest/GuestWorkspace.ps1'

        # The coordination directory resolver is the ONE thing a test may replace, and only to
        # keep these processes out of the real C:\ProgramData\PatchingGuestOps\.coordination.
        # Nothing in the product configures it.
        $driverBody = @'
param([string]$RepoRoot, [string]$CoordinationDirectory, [string]$RunId, [string]$Mode, [string]$SignalPath, [string]$ReleasePath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'guest/GuestWorkspace.ps1')
. (Join-Path $RepoRoot 'guest/GuestRunGuard.ps1')
function Get-GuestRunGuardDirectory { return $CoordinationDirectory }
# Windows security descriptors are not available everywhere these tests run, so the directory is
# taken as given here; the descriptor rules have their own section.
function Initialize-GuestWorkspace {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { $null = New-Item -ItemType Directory -Force -Path $Path }
    return [pscustomobject]@{ Status = 'Ok'; Reason = $null; Path = $Path }
}
$guard = Enter-GuestRunGuard -RunId $RunId -Phase 'Agent'
$payload = [ordered]@{ acquired = [bool]$guard.Acquired; conflict = [bool]$guard.Conflict; reason = [string]$guard.Reason; conflictKind = [string]$guard.ConflictKind }
$payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $SignalPath -Encoding UTF8
if (-not $guard.Acquired) { exit 20 }
switch ($Mode) {
    'HoldUntilReleased' {
        # Hold the lock until the test says otherwise, then finish properly.
        $deadline = (Get-Date).AddSeconds(60)
        while (-not (Test-Path -LiteralPath $ReleasePath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
        $null = Set-GuestRunGuardCompleted -Guard $guard -Outcome 'InstallSucceeded'
        Exit-GuestRunGuard -Guard $guard
        exit 0
    }
    'CrashWhileHolding' {
        # Exactly what a killed agent leaves behind: the handle is released by the OS, but no
        # completion was ever recorded.
        exit 99
    }
    'CompleteImmediately' {
        $null = Set-GuestRunGuardCompleted -Guard $guard -Outcome 'SearchOnly'
        Exit-GuestRunGuard -Guard $guard
        exit 0
    }
    'RequestReboot' {
        $null = Set-GuestRunGuardRebootRequested -Guard $guard
        Exit-GuestRunGuard -Guard $guard
        exit 0
    }
}
exit 0
'@
        $driverPath = Join-Path $guardRoot 'guard-driver.ps1'
        Set-Content -LiteralPath $driverPath -Value $driverBody -Encoding UTF8

        # The host this gate is already running in. On Windows PowerShell 5.1 that is
        # powershell.exe; elsewhere it is whatever launched this file. Either way the two
        # children are real, separate processes, which is the point of this section.
        $powershellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

        $startGuardProcess = {
            param($CoordinationDirectory, $RunId, $Mode, $SignalPath, $ReleasePath)
            $arguments = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $driverPath),
                '-RepoRoot', ('"{0}"' -f $repoRoot), '-CoordinationDirectory', ('"{0}"' -f $CoordinationDirectory),
                '-RunId', $RunId, '-Mode', $Mode, '-SignalPath', ('"{0}"' -f $SignalPath), '-ReleasePath', ('"{0}"' -f $ReleasePath)
            )
            # Hidden on Windows: this check starts several real processes and each one otherwise
            # flashes a console window over whatever the operator is doing. -WindowStyle is a
            # Windows-only parameter, so it is added rather than hard-coded - the same file runs
            # on hosts where passing it would fail the call.
            $startArguments = @{ FilePath = $powershellPath; ArgumentList = $arguments; PassThru = $true }
            if (Test-IsWindowsHost) {
                $startArguments['WindowStyle'] = 'Hidden'
            }
            return (Start-Process @startArguments)
        }

        $waitForSignal = {
            param($SignalPath)
            $deadline = (Get-Date).AddSeconds(60)
            while (-not (Test-Path -LiteralPath $SignalPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
            if (-not (Test-Path -LiteralPath $SignalPath)) { return $null }
            # The file is written in one shot, but a reader can still arrive between create and
            # write, so an empty read is retried rather than treated as a malformed answer.
            for ($attempt = 0; $attempt -lt 100; $attempt++) {
                $raw = [string](Get-Content -LiteralPath $SignalPath -Raw -ErrorAction SilentlyContinue)
                if (-not [string]::IsNullOrWhiteSpace($raw)) { return ($raw | ConvertFrom-Json) }
                Start-Sleep -Milliseconds 100
            }
            return $null
        }

        # 1. The same guest, two runs, two different run ids and working directories: the second
        #    must not be able to start WUA work.
        $sharedCoordination = Join-Path $guardRoot 'shared'
        $firstSignal = Join-Path $guardRoot 'first.json'
        $releaseFlag = Join-Path $guardRoot 'release.flag'
        $firstProcess = & $startGuardProcess $sharedCoordination 'run-one' 'HoldUntilReleased' $firstSignal $releaseFlag
        $firstAnswer = & $waitForSignal $firstSignal
        Assert-Equal ($null -ne $firstAnswer) $true 'the first run reports whether it took the guard'
        if ($null -ne $firstAnswer) {
            Assert-Equal ([bool]$firstAnswer.acquired) $true 'the first run takes the guard'
        }

        $secondSignal = Join-Path $guardRoot 'second.json'
        $secondProcess = & $startGuardProcess $sharedCoordination 'run-two' 'CompleteImmediately' $secondSignal (Join-Path $guardRoot 'unused.flag')
        $secondAnswer = & $waitForSignal $secondSignal
        Assert-Equal ($null -ne $secondAnswer) $true 'the second run reports its verdict'
        if ($null -ne $secondAnswer) {
            Assert-Equal ([bool]$secondAnswer.acquired) $false 'a second run on the same guest cannot take the guard'
            Assert-Equal ([bool]$secondAnswer.conflict) $true 'a busy guest is a conflict, not a transient error'
            # The reason matters, not just the refusal: it has to be the open handle that stopped
            # the second run. Reading the first run's "Running" record would refuse it too, but
            # only after the lock had already let both processes into the WUA session.
            Assert-Contains ([string]$secondAnswer.reason) 'holds the guest run guard' 'the second run is stopped by the lock itself, not by reading the record afterwards'
            # And it is classified as Held, not Unconfirmed: a live run is something to wait out,
            # while an unreconciled record is something a person has to look at.
            Assert-Equal ([string]$secondAnswer.conflictKind) 'Held' 'a live concurrent run is reported as Held'
        }
        $null = $secondProcess.WaitForExit(60000)
        Assert-Equal $secondProcess.ExitCode 20 'the refused run exits with the conflict code'

        # Releasing the first run properly leaves the guest available again: an existing lock file
        # from a finished run must not block the next one.
        Set-Content -LiteralPath $releaseFlag -Value 'go' -Encoding UTF8
        $null = $firstProcess.WaitForExit(60000)
        Assert-Equal $firstProcess.ExitCode 0 'the holding run finishes normally'

        $thirdSignal = Join-Path $guardRoot 'third.json'
        $thirdProcess = & $startGuardProcess $sharedCoordination 'run-three' 'CompleteImmediately' $thirdSignal (Join-Path $guardRoot 'unused.flag')
        $thirdAnswer = & $waitForSignal $thirdSignal
        if ($null -ne $thirdAnswer) {
            Assert-Equal ([bool]$thirdAnswer.acquired) $true 'a properly finished run does not block the next one'
        }
        $null = $thirdProcess.WaitForExit(60000)

        # 2. A different guest is a different coordination directory, so it runs independently.
        $otherCoordination = Join-Path $guardRoot 'other-guest'
        $heldSignal = Join-Path $guardRoot 'held.json'
        $heldRelease = Join-Path $guardRoot 'held-release.flag'
        $heldProcess = & $startGuardProcess $sharedCoordination 'run-hold' 'HoldUntilReleased' $heldSignal $heldRelease
        $null = & $waitForSignal $heldSignal
        $otherSignal = Join-Path $guardRoot 'other.json'
        $otherProcess = & $startGuardProcess $otherCoordination 'run-other' 'CompleteImmediately' $otherSignal (Join-Path $guardRoot 'unused.flag')
        $otherAnswer = & $waitForSignal $otherSignal
        if ($null -ne $otherAnswer) {
            Assert-Equal ([bool]$otherAnswer.acquired) $true 'another guest is not blocked by this one'
        }
        $null = $otherProcess.WaitForExit(60000)
        Set-Content -LiteralPath $heldRelease -Value 'go' -Encoding UTF8
        $null = $heldProcess.WaitForExit(60000)

        # 3. A crashed run releases its handle but never recorded completion. The next run must
        #    refuse: the operating system releasing a file handle says nothing about whether a
        #    WUA install finished.
        $crashCoordination = Join-Path $guardRoot 'crashed'
        $crashSignal = Join-Path $guardRoot 'crash.json'
        $crashProcess = & $startGuardProcess $crashCoordination 'run-crash' 'CrashWhileHolding' $crashSignal (Join-Path $guardRoot 'unused.flag')
        $null = & $waitForSignal $crashSignal
        $null = $crashProcess.WaitForExit(60000)

        $afterCrashSignal = Join-Path $guardRoot 'after-crash.json'
        $afterCrashProcess = & $startGuardProcess $crashCoordination 'run-after-crash' 'CompleteImmediately' $afterCrashSignal (Join-Path $guardRoot 'unused.flag')
        $afterCrashAnswer = & $waitForSignal $afterCrashSignal
        Assert-Equal ($null -ne $afterCrashAnswer) $true 'the run after a crash reports its verdict'
        if ($null -ne $afterCrashAnswer) {
            Assert-Equal ([bool]$afterCrashAnswer.acquired) $false 'a run that never reported completion blocks the next one'
            Assert-Equal ([bool]$afterCrashAnswer.conflict) $true 'an unreconciled trace is a conflict'
            Assert-Contains ([string]$afterCrashAnswer.reason) 'never reported completion' 'the conflict says what is unreconciled'
            Assert-Contains ([string]$afterCrashAnswer.reason) 'by hand' 'the conflict points at the manual reconciliation'
            # Deliberately not Held: nothing holds this guest any more, and a run that waited for
            # the handle to free up would wait for something that has already happened.
            Assert-Equal ([string]$afterCrashAnswer.conflictKind) 'Unconfirmed' 'a crashed run leaves an Unconfirmed conflict, never a Held one'
        }
        $null = $afterCrashProcess.WaitForExit(60000)

        # 4. A requested reboot that was never confirmed by a newer boot time also blocks the next
        #    agent - and it is not cleared by the requesting process exiting.
        $rebootCoordination = Join-Path $guardRoot 'rebooted'
        $rebootSignal = Join-Path $guardRoot 'reboot.json'
        $rebootProcess = & $startGuardProcess $rebootCoordination 'run-reboot' 'RequestReboot' $rebootSignal (Join-Path $guardRoot 'unused.flag')
        $null = & $waitForSignal $rebootSignal
        $null = $rebootProcess.WaitForExit(60000)

        $afterRebootSignal = Join-Path $guardRoot 'after-reboot.json'
        $afterRebootProcess = & $startGuardProcess $rebootCoordination 'run-after-reboot' 'CompleteImmediately' $afterRebootSignal (Join-Path $guardRoot 'unused.flag')
        $afterRebootAnswer = & $waitForSignal $afterRebootSignal
        if ($null -ne $afterRebootAnswer) {
            Assert-Equal ([bool]$afterRebootAnswer.acquired) $false 'an unconfirmed pending reboot blocks the next agent'
            Assert-Contains ([string]$afterRebootAnswer.reason) 'not been confirmed by a newer boot time' 'the pending reboot says what would reconcile it'
            Assert-Equal ([string]$afterRebootAnswer.conflictKind) 'RebootPending' 'a guest on its way back up is reported as RebootPending'
        }
        $null = $afterRebootProcess.WaitForExit(60000)

        # The coordination file is never deleted: it is the shared record for this guest, and
        # throwing it away would lose the only trace of an unfinished run.
        Assert-Equal (Test-Path -LiteralPath (Join-Path $crashCoordination 'guest-run.lock')) $true 'the coordination record survives a refused acquisition'
    }
    finally {
        if ($guardRoot -like '*guestops-guard-*') {
            Remove-Item -LiteralPath $guardRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- reconciliation is boot-time evidence, nothing else ------------------------------------------

& {
    $recordedBootTime = [datetime]::Parse('2026-09-13T10:00:00Z').ToUniversalTime()
    $pendingState = [pscustomobject]@{ status = 'RebootRequested'; runId = 'run-x'; bootTimeUtc = $recordedBootTime.ToString('o') }

    function Get-GuestRunGuardBootTimeUtc { return $recordedBootTime }
    Assert-Equal (Test-GuestRunGuardRebootConfirmed -PreviousState $pendingState) $false 'the same boot time does not confirm a reboot'
    Assert-Equal ($null -ne (Get-GuestRunGuardConflictReason -PreviousState $pendingState)) $true 'an unconfirmed reboot remains a conflict'

    function Get-GuestRunGuardBootTimeUtc { return $recordedBootTime.AddMinutes(-5) }
    Assert-Equal (Test-GuestRunGuardRebootConfirmed -PreviousState $pendingState) $false 'a boot time that moved backwards does not confirm a reboot'

    function Get-GuestRunGuardBootTimeUtc { return $null }
    Assert-Equal (Test-GuestRunGuardRebootConfirmed -PreviousState $pendingState) $false 'an unreadable boot time never confirms a reboot'

    function Get-GuestRunGuardBootTimeUtc { return $recordedBootTime.AddMinutes(5) }
    Assert-Equal (Test-GuestRunGuardRebootConfirmed -PreviousState $pendingState) $true 'a strictly newer boot time confirms the reboot'
    Assert-Equal (Get-GuestRunGuardConflictReason -PreviousState $pendingState) $null 'a confirmed reboot clears the way for the next run'

    # Every other recorded state, including one this tool does not know.
    Assert-Equal (Get-GuestRunGuardConflictReason -PreviousState $null) $null 'a guest with no record is available'
    Assert-Equal (Get-GuestRunGuardConflictReason -PreviousState ([pscustomobject]@{ status = 'Completed'; runId = 'run-y' })) $null 'a completed run leaves the guest available'
    Assert-Contains ([string](Get-GuestRunGuardConflictReason -PreviousState ([pscustomobject]@{ status = 'Running'; runId = 'run-z' })).Reason) 'never reported completion' 'a run still marked running is a conflict'
    Assert-Contains ([string](Get-GuestRunGuardConflictReason -PreviousState 'unreadable').Reason) 'cannot interpret' 'an unreadable record is a conflict'
    Assert-Contains ([string](Get-GuestRunGuardConflictReason -PreviousState ([pscustomobject]@{ status = 'Whatever'; runId = 'run-w' })).Reason) 'does not recognise' 'an unknown recorded status is a conflict, not a pass'

    # The kind, not just the text: the caller decides between waiting and stopping on it, so a
    # conflict classified wrongly is either a run that gives up on a guest that is merely
    # restarting, or a wait for a directory nobody is ever going to reconcile.
    function Get-GuestRunGuardBootTimeUtc { return $recordedBootTime }
    Assert-Equal (Get-GuestRunGuardConflictReason -PreviousState $pendingState).Kind 'RebootPending' 'an unconfirmed reboot is the kind that clears itself'
    Assert-Equal (Get-GuestRunGuardConflictReason -PreviousState ([pscustomobject]@{ status = 'Running'; runId = 'run-z' })).Kind 'Unconfirmed' 'a run that never reported completion needs a hand, not a wait'
    Assert-Equal (Get-GuestRunGuardConflictReason -PreviousState 'unreadable').Kind 'Unreadable' 'a record this tool cannot read needs a hand too'
    Assert-Equal (Get-GuestRunGuardConflictReason -PreviousState ([pscustomobject]@{ status = 'Whatever'; runId = 'run-w' })).Kind 'Unreadable' 'an unrecognised status is never waited out'
}

# --- the coordination directory is never a cleanup target ----------------------------------------
# Cleanup deletes a cycle directory recursively, so the one thing it must never reach is the
# shared coordination record.

& {
    $handle = [pscustomobject]@{
        GuestWorkingDirectory = 'C:\ProgramData\PatchingGuestOps'
        GuestCycleDirectory = 'C:\ProgramData\PatchingGuestOps\.coordination'
        RunId = '.coordination'
    }
    $verdict = Test-GuestCycleDirectoryRemovable -Handle $handle
    Assert-Equal $verdict.Removable $false 'the coordination directory is never removable as a cycle directory'

    $guidHandle = [pscustomobject]@{
        GuestWorkingDirectory = 'C:\ProgramData\PatchingGuestOps'
        GuestCycleDirectory = 'C:\ProgramData\PatchingGuestOps\0123456789abcdef0123456789abcdef'
        RunId = '0123456789abcdef0123456789abcdef'
    }
    Assert-Equal (Test-GuestCycleDirectoryRemovable -Handle $guidHandle).Removable $true 'a real cycle directory is still removable'
}

# --- the rules themselves, against real security descriptors --------------------------------------
# Only in a private temporary directory, and never against the real C:\ProgramData. A domain
# account is never required: every identity used here is a well-known local SID.

if (-not (Test-IsWindowsHost)) {
    $skipped += 'Windows access-control rules (owner, access rules, reparse points, parent) - this host has no Windows security descriptors.'
}
else {
    # %TEMP% grants the running user FullControl by design, and FullControl carries every right
    # in the parent-replacement mask - so nothing directly under it can pass, elevated or not.
    # The cases below therefore live one level deeper, under a base directory built with the same
    # protected descriptor production applies to each level. Its OWN parent is still %TEMP%, which
    # is why the base is never itself asserted: what is under test is a directory whose parent
    # this code protected, which is exactly the production shape (C:\ProgramData\PatchingGuestOps).
    #
    # The cases using a two-level path already worked for this reason. The one-level cases did not,
    # and their 'Ok' assertions had been failing silently into the collected list; the crash a
    # Windows run hit was simply the first one loud enough to notice. This section is skipped off
    # Windows, so none of it had ever run.
    $aclRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-acl-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $aclRoot
    $aclBase = Join-Path $aclRoot 'base'
    $aclBaseReady = $false
    $aclBaseReason = ''
    try {
        $null = [System.IO.Directory]::CreateDirectory($aclBase, (New-GuestWorkspaceSecurity))
        # Proven by behaviour rather than by asserting the base itself: a directory created under
        # it must pass, which is the precondition every case below depends on.
        $aclProbe = Initialize-GuestWorkspace -Path (Join-Path $aclBase 'probe')
        $aclBaseReady = ($aclProbe.Status -eq 'Ok')
        if (-not $aclBaseReady) { $aclBaseReason = [string]$aclProbe.Reason }
    }
    catch {
        $aclBaseReason = $_.Exception.Message
    }

    # Setting the owner to the local Administrators needs an elevated token. Without it the base
    # cannot be built, and every case below would fail for that reason rather than the one it is
    # testing - so say so once and run nothing, instead of printing a cascade.
    if (-not $aclBaseReady) {
        $skipped += ('Windows access-control rules - the private test base could not be given a protected descriptor, which needs an elevated session: ' + $aclBaseReason)
        if ($aclRoot -like '*guestops-acl-*') {
            Remove-Item -LiteralPath $aclRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    else {
    try {
        $usersSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')

        # 1. A directory this code creates is accepted, and its levels are created protected.
        $createdPath = Join-Path $aclBase 'created\PatchingGuestOps'
        $created = Initialize-GuestWorkspace -Path $createdPath
        Assert-Equal $created.Status 'Ok' 'a workspace this code creates is accepted'
        Assert-Equal (Test-Path -LiteralPath (Join-Path $aclBase 'created') -PathType Container) $true 'the missing intermediate level was created too'

        $createdSecurity = Get-Acl -LiteralPath $createdPath
        Assert-Equal $createdSecurity.AreAccessRulesProtected $true 'the created directory does not inherit its permissions'
        Assert-Equal ([string]$createdSecurity.GetOwner([System.Security.Principal.SecurityIdentifier]).Value) 'S-1-5-32-544' 'the created directory is owned by the local Administrators'
        Assert-Equal (Test-GuestWorkspaceAccessRules -Security $createdSecurity -Mask (Get-GuestWorkspaceModifyMask)) $null 'the created directory grants modification to nobody outside the allow-list'

        # The intermediate level is protected in its own right: being able to write there is
        # enough to move the leaf.
        $intermediateSecurity = Get-Acl -LiteralPath (Join-Path $aclBase 'created')
        Assert-Equal $intermediateSecurity.AreAccessRulesProtected $true 'an intermediate level is created protected, not with inherited permissions'

        # 2. Initialize on an existing, correct directory is accepted and changes nothing.
        $reinitialized = Initialize-GuestWorkspace -Path $createdPath
        Assert-Equal $reinitialized.Status 'Ok' 'an already-correct workspace is accepted as it is'

        # 3. An access rule that lets ordinary users write is refused, and is NOT repaired.
        $writablePath = Join-Path $aclBase 'writable'
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
        $readablePath = Join-Path $aclBase 'readable'
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
        $ownedPath = Join-Path $aclBase 'foreign-owner'
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
        $linkTarget = Join-Path $aclBase 'link-target'
        $null = New-Item -ItemType Directory -Force -Path $linkTarget
        $linkPath = Join-Path $aclBase 'link'
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
        $replaceableParent = Join-Path $aclBase 'replaceable'
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

        $creatableParent = Join-Path $aclBase 'creatable'
        $null = New-Item -ItemType Directory -Force -Path $creatableParent
        $creatableSecurity = Get-Acl -LiteralPath $creatableParent
        $creatableSecurity.SetAccessRuleProtection($true, $false)
        $creatableSecurity.SetOwner($administratorsSid)
        $creatableSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($administratorsSid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        $creatableSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usersSid, 'CreateFiles,CreateDirectories,ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $creatableParent -AclObject $creatableSecurity
        Assert-Equal (Initialize-GuestWorkspace -Path (Join-Path $creatableParent 'PatchingGuestOps')).Status 'Ok' 'a parent that only lets ordinary users add new entries is accepted'

        # 8. A file already in a safe directory is not vouched for by the directory.
        $helperHome = Join-Path $aclBase 'helper-home'
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

        # 9. The seal, end to end against real security descriptors: the bootstrap writes it, the
        #    directory still verifies with the token it was sealed with, and the seal file itself
        #    is subject to the same file rules as the helper above.
        $sealedHome = Join-Path $aclBase 'sealed'
        $sealedToken = New-GuestWorkspaceSealToken
        Assert-Equal (Initialize-GuestWorkspace -Path $sealedHome -SealToken $sealedToken).Status 'Ok' 'a directory is created, verified and then sealed'
        Assert-Equal (Assert-GuestWorkspaceSeal -Path $sealedHome -Token $sealedToken).Status 'Ok' 'the sealed directory verifies against its own token'
        Assert-Equal (Assert-GuestWorkspaceSeal -Path $sealedHome -Token (New-GuestWorkspaceSealToken)).Status 'SealRefused' 'the sealed directory refuses a token it was not sealed with'

        # Initialize without a token leaves no seal, so nothing later can pretend to have checked
        # one: Assert-GuestWorkspaceSeal refuses instead of finding a stale file to match.
        $unsealedHome = Join-Path $aclBase 'unsealed'
        Assert-Equal (Initialize-GuestWorkspace -Path $unsealedHome).Status 'Ok' 'a directory can still be created without a seal'
        Assert-Equal (Test-Path -LiteralPath (Get-GuestWorkspaceSealPath -Path $unsealedHome) -PathType Leaf) $false 'no token means no seal file is written'
        Assert-Equal (Assert-GuestWorkspaceSeal -Path $unsealedHome -Token $sealedToken).Status 'SealRefused' 'an unsealed directory cannot satisfy a seal check'

        # A seal an ordinary user could rewrite is worth nothing, so it goes through the same file
        # check as the boot-time helper.
        #
        # Guarded on the file existing, because a recorded assertion failure must not become a
        # throw: Assert-Equal collects, but Get-Acl on a missing path terminates under this
        # script's Stop preference - and this file runs as a child process of the runtime gate,
        # so a throw here discards every check after it and reports as a crash rather than as
        # the one failed assertion it actually is.
        $sealFilePath = Get-GuestWorkspaceSealPath -Path $sealedHome
        if (-not (Test-Path -LiteralPath $sealFilePath -PathType Leaf)) {
            $failures += 'the seal file was never written, so the rules on the seal itself could not be checked'
        }
        else {
            $sealFileSecurity = Get-Acl -LiteralPath $sealFilePath
            $sealFileSecurity.SetAccessRuleProtection($true, $false)
            $sealFileSecurity.SetOwner($administratorsSid)
            $sealFileSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($administratorsSid, 'FullControl', 'None', 'None', 'Allow')))
            $sealFileSecurity.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usersSid, 'Modify', 'None', 'None', 'Allow')))
            Set-Acl -LiteralPath $sealFilePath -AclObject $sealFileSecurity
            Assert-Equal (Assert-GuestWorkspaceSeal -Path $sealedHome -Token $sealedToken).Status 'AccessRuleRefused' 'a seal an ordinary user may rewrite is refused'
        }
    }
    finally {
        # Only ever the private test directory, and only when it is still the one this run made.
        if ($aclRoot -like '*guestops-acl-*') {
            Remove-Item -LiteralPath $aclRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
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

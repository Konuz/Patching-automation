[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VIServer,

    [string]$VMName,

    [string[]]$VMNames,

    [string]$VMListPath,

    [pscredential]$VIServerCredential,

    [pscredential]$GuestCredential,

    [string]$AgentPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'guest\Run-LocalPatch.ps1'),

    [string]$GuestWorkingDirectory = 'C:\ProgramData\PatchingGuestOps',

    [string]$LocalOutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out'),

    [string]$PatchPlanPath,

    [int]$MaxUpdates = 1,

    [string]$InstallSelection,

    [string[]]$SelectedUpdateKeys,

    [ValidateRange(1, 2147483647)]
    [int]$ThrottleLimit = 3,

    [ValidateRange(1, 2147483647)]
    [int]$RebootBatchSize,

    [ValidateRange(1, 2147483647)]
    [int]$MaxPatchRounds = 3,

    [switch]$SearchOnly,

    [switch]$PlanOnly,

    [switch]$SkipConfirmation,

    # Apply only. A WUA install can genuinely take hours, which is why this is 180 - but the same
    # budget applied to discovery meant a guest that stopped answering during a search held the
    # whole phase for three hours before anyone was told.
    [ValidateRange(1, 35791394)]
    [int]$TimeoutMinutes = 180,

    # Discovery is a WUA search: minutes, not hours. Upper bound, like the others, is the largest
    # value that still fits Int32 once converted to seconds.
    [ValidateRange(1, 35791394)]
    [int]$DiscoveryTimeoutMinutes = 30,

    [ValidateRange(1, 35791394)]
    [int]$RebootTimeoutMinutes = 30,

    [ValidateRange(1, 2147483647)]
    [int]$PollSeconds = 15,

    [switch]$IgnoreVCenterCertificate,

    [switch]$IgnoreESXiCertificate,

    [switch]$KeepConnected,

    [hashtable]$PromptProvider,

    # The Stored prefix is required, not cosmetic: -VIServerCredentialMap would be THE SAME
    # variable as $viserverCredentialMap below (PowerShell variable names are
    # case-insensitive) and the supplied map would be silently overwritten.
    [hashtable]$StoredVIServerCredentials,
    [hashtable]$StoredGuestCredentials
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$guestOpsLibPath = Join-Path $PSScriptRoot 'GuestOpsLib.ps1'
. $guestOpsLibPath

. (Join-Path $PSScriptRoot 'VMTargetLib.ps1')
. (Join-Path $PSScriptRoot 'CredentialRecovery.ps1')

$identityHelperPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'guest\UpdateIdentity.ps1'
# The workspace guard is never uploaded; it is read here and run in the guest through
# -EncodedCommand, so this is the trusted local copy every phase must be handed.
$workspaceScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'guest\GuestWorkspace.ps1'
$runGuardScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'guest\GuestRunGuard.ps1'
$rebootRequestScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'guest\Request-GuestReboot.ps1'

function Resolve-VMTargetNames {
    param(
        [string]$SingleVMName,
        [string[]]$ManyVMNames,
        [string]$ListPath
    )

    $uniqueTargets = @(Resolve-VMTargetNamesFromSources -SingleVMName $SingleVMName -ManyVMNames $ManyVMNames -ListPath $ListPath)

    if ($uniqueTargets.Count -eq 0) {
        throw 'At least one VM target is required. Use -VMName, -VMNames, or -VMListPath.'
    }

    return $uniqueTargets
}

function Assert-LocalPrerequisites {
    param([string]$LocalAgentPath)

    if (-not (Test-Path -LiteralPath $LocalAgentPath -PathType Leaf)) {
        throw ('Agent file not found: {0}' -f $LocalAgentPath)
    }

    $curlCommand = Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue
    if ($null -eq $curlCommand) {
        throw 'curl.exe was not found in PATH.'
    }

    # Check for the module this script actually imports, not the VMware.PowerCLI meta-module.
    # A lean install that has every VimAutomation submodule but not the meta-manifest is a
    # perfectly working environment, and refusing it here would be a false negative.
    $powerCliModule = Get-Module -ListAvailable -Name VMware.VimAutomation.Core
    if ($null -eq $powerCliModule) {
        throw 'VMware.VimAutomation.Core module was not found. Install it, or the full VMware.PowerCLI bundle that contains it.'
    }

    return $curlCommand.Source
}

function Get-GuestCredentialResolutionErrorKind {
    param([string]$Status)

    switch ($Status) {
        'Skipped' { 'CredentialsSkipped' }
        'Aborted' { 'CredentialsAborted' }
        default { 'CredentialsFailed' }
    }
}

function New-GuestCredentialResolutionException {
    param(
        $Resolution,
        [bool]$RejectedBeforeStart = $false
    )

    $errorKind = Get-GuestCredentialResolutionErrorKind -Status ([string]$Resolution.Status)
    $exception = New-Object System.InvalidOperationException -ArgumentList ([string]$Resolution.Reason)
    $exception.Data['ErrorKind'] = $errorKind
    $exception.Data['RejectedBeforeStart'] = $RejectedBeforeStart
    return $exception
}

function Get-GuestOperationFailureMetadata {
    param(
        $ErrorRecord,
        [string]$Stage
    )

    $exception = Get-ObjectPropertyValue -InputObject $ErrorRecord -Path @('Exception')
    $errorKind = $null
    $rejectedBeforeStart = $false
    try {
        if ($null -ne $exception -and $null -ne $exception.Data) {
            if ($exception.Data.Contains('ErrorKind')) {
                $errorKind = [string]$exception.Data['ErrorKind']
            }
            if ($exception.Data.Contains('RejectedBeforeStart')) {
                $rejectedBeforeStart = [bool]$exception.Data['RejectedBeforeStart']
            }
        }
    }
    catch { }

    if ([string]::IsNullOrWhiteSpace($errorKind)) {
        $errorKind = Get-GuestOperationErrorKind -ErrorRecord $ErrorRecord
        $rejectedBeforeStart = ($Stage -eq 'Start' -and $errorKind -eq 'InvalidCredentials')
    }

    return [pscustomobject]@{
        ErrorKind = $errorKind
        RejectedBeforeStart = $rejectedBeforeStart
    }
}

function Test-GuestCredentialForTarget {
    param(
        [string]$VMName,
        [object[]]$VIServerScope,
        [pscredential]$Credential
    )

    try {
        $vm = Get-ExactVM -Name $VMName -Servers $VIServerScope
        Assert-VMReadyForGuestOps -VM $vm
        $managers = Get-GuestOpsManagers -VMView $vm.ExtensionData
        return Test-GuestCredential -VMView $vm.ExtensionData -Managers $managers -Credential $Credential
    }
    catch {
        return [pscustomobject]@{
            Status = 'Error'
            ErrorKind = Get-GuestCredentialExceptionKind -Exception $_.Exception
            Error = $_.Exception.Message
        }
    }
}

function Invoke-GuestOperationWithCredentialRecovery {
    param(
        [string]$VMName,
        [object[]]$VIServerScope,
        [hashtable]$CredentialContext,
        [scriptblock]$CredentialDecisionScript,
        [scriptblock]$CredentialValidatedScript,
        [bool]$CredentialInteractive,
        [scriptblock]$OperationScript,
        $Handle = $null
    )

    $forcePrompt = $false
    while ($true) {
        $resolution = Resolve-GuestCredentialForTarget -VMName $VMName -Context $CredentialContext -ValidateScript {
            param($TargetName, $Credential)
            return Test-GuestCredentialForTarget -VMName $TargetName -VIServerScope $VIServerScope -Credential $Credential
        } -DecisionScript $CredentialDecisionScript -OnValidatedScript $CredentialValidatedScript -ForcePrompt:$forcePrompt -Interactive:$CredentialInteractive

        if ($resolution.Status -ne 'Ready') {
            throw (New-GuestCredentialResolutionException -Resolution $resolution -RejectedBeforeStart:($null -eq $Handle))
        }

        $guestAuth = New-GuestAuthentication -Credential $resolution.Credential
        if ($null -ne $Handle) {
            $Handle.GuestAuth = $guestAuth
        }

        try {
            return & $OperationScript $guestAuth
        }
        catch {
            if ((Get-GuestOperationErrorKind -ErrorRecord $_) -ne 'InvalidCredentials') {
                throw
            }
            $forcePrompt = $true
        }
    }
}

function New-AgentFleetItem {
    param(
        [int]$Sequence,
        [string]$VMName,
        [string]$VMOutputDirectory,
        [int]$MaxUpdates,
        [string]$LocalSelectionPath = '',
        [bool]$SearchOnly = $false
    )

    # Discovery and apply must hand the fleet the same shape: under StrictMode the start
    # script reading a property one phase happens not to set is a terminating error.
    return [pscustomobject]@{
        Sequence = $Sequence
        VMName = $VMName
        VMOutputDirectory = $VMOutputDirectory
        MaxUpdates = $MaxUpdates
        LocalSelectionPath = $LocalSelectionPath
        SearchOnly = $SearchOnly
    }
}

function Invoke-GuestAgentFleet {
    param(
        [object[]]$FleetItems,
        [object[]]$VIServerScope,
        $Managers,
        $GuestCredentialMap,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$IdentityHelperPath,
        # Left undefaulted on purpose: this function is also built from the orchestrator's AST by
        # the harness, where $PSScriptRoot is empty, so a default resolved here would be wrong.
        # An omitted value arrives as an empty string and Start-VMAgentCycle treats that as
        # "use the shipped script", which is the one place that can resolve it correctly.
        [string]$WorkspaceScriptPath,
        [string]$RunGuardScriptPath,
        [string]$GuestWorkingDirectory,
        [int]$TimeoutSeconds,
        [int]$PollSeconds,
        [int]$MaxInFlight,
        [hashtable]$CredentialContext = $null,
        [scriptblock]$CredentialDecisionScript,
        [scriptblock]$CredentialValidatedScript,
        [bool]$CredentialInteractive = $false,
        # How many times a VM that refused the run *because it is restarting* may be tried again
        # inside this phase. Counted down through the recursive call below, so the budget cannot be
        # renewed by a retry that hits the same conflict.
        [int]$GuestRunConflictRetriesRemaining = $script:GuestRunConflictRetryLimit,
        [scriptblock]$SleepScript = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )

    # Finish every endpoint check before the fleet creates directories or starts agents. A host
    # that fails its check fails only the VMs on it, each as its own start error naming the host;
    # inventory/readiness failures stay per-VM too. One bad host must not stop the whole fleet.
    $preflightErrors = @()
    $readyItems = @()
    # Host name -> $null when the check passed, or the exception it failed with. Checked once per
    # phase: the next VM on a failing host reuses the verdict instead of paying another probe.
    $hostCheckResults = @{}
    $credentialRecoveryEnabled = ($null -ne $CredentialContext)
    foreach ($item in @($FleetItems)) {
        try {
            # Resolve skipped/aborted accounts first, so their host is never probed for nothing.
            # Successful validation is cached; the start still uses normal credential recovery.
            if ($credentialRecoveryEnabled) {
                $null = Invoke-GuestOperationWithCredentialRecovery -VMName $item.VMName -VIServerScope $VIServerScope -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive -OperationScript { param($ItemAuth) }
            }
            $vm = Get-ExactVM -Name $item.VMName -Servers $VIServerScope
            Assert-VMReadyForGuestOps -VM $vm
            $hostName = Get-VMHostNameForTransfer -VMView $vm.ExtensionData

            if (-not $hostCheckResults.ContainsKey($hostName)) {
                $hostCheckResults[$hostName] = $null
                try {
                    Assert-GuestTransferEndpoint -HostName $hostName -CurlPath $CurlPath
                }
                catch {
                    $hostCheckResults[$hostName] = $_.Exception
                }
            }
            if ($null -ne $hostCheckResults[$hostName]) {
                throw $hostCheckResults[$hostName]
            }
        }
        catch {
            $errorMetadata = Get-GuestOperationFailureMetadata -ErrorRecord $_ -Stage 'Start'
            $preflightErrors += New-FleetErrorResult -InputObject $item -ErrorMessage ('Agent preflight failed: {0}' -f $_.Exception.Message) -ResultKind 'StartError' -ErrorMetadata $errorMetadata
            continue
        }

        $readyItems += $item
    }

    $fleetResults = @(Invoke-InProcessAgentFleet -Items $readyItems -MaxInFlight $MaxInFlight -PollSeconds $PollSeconds -ItemTimeoutSeconds $TimeoutSeconds `
        -StartScript {
            param($Item)
            if (-not $credentialRecoveryEnabled) {
                $itemAuth = New-GuestAuthentication -Credential $GuestCredentialMap[[string]$Item.VMName]
                return Start-VMAgentCycle -VMName $Item.VMName -Servers $VIServerScope -Managers $null -GuestAuth $itemAuth -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -WorkspaceScriptPath $WorkspaceScriptPath -RunGuardScriptPath $RunGuardScriptPath -GuestWorkingDirectory $GuestWorkingDirectory -VMOutputDirectory $Item.VMOutputDirectory -MaxUpdates $Item.MaxUpdates -LocalSelectionPath $Item.LocalSelectionPath -SearchOnly:([bool]$Item.SearchOnly)
            }

            return Invoke-GuestOperationWithCredentialRecovery -VMName $Item.VMName -VIServerScope $VIServerScope -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive -OperationScript {
                param($ItemAuth)
                return Start-VMAgentCycle -VMName $Item.VMName -Servers $VIServerScope -Managers $null -GuestAuth $ItemAuth -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -WorkspaceScriptPath $WorkspaceScriptPath -RunGuardScriptPath $RunGuardScriptPath -GuestWorkingDirectory $GuestWorkingDirectory -VMOutputDirectory $Item.VMOutputDirectory -MaxUpdates $Item.MaxUpdates -LocalSelectionPath $Item.LocalSelectionPath -SearchOnly:([bool]$Item.SearchOnly)
            }
        } `
        -PollScript {
            param($Handle)
            # Ask vSphere once per round and stash the answer. Calling Test-VMAgentCycleComplete
            # again from the completion script can come back as "ended, exit code lost" once
            # vSphere has forgotten the process, and the apply result builder would read that
            # second answer instead of the one that actually decided the poll.
            if (-not $credentialRecoveryEnabled) {
                $agentResult = Test-VMAgentCycleComplete -Handle $Handle
                $Handle.AgentResult = $agentResult
                return ($null -ne $agentResult)
            }

            return Invoke-GuestOperationWithCredentialRecovery -VMName $Handle.VMName -VIServerScope $VIServerScope -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive -Handle $Handle -OperationScript {
                param($ItemAuth)
                $agentResult = Test-VMAgentCycleComplete -Handle $Handle
                $Handle.AgentResult = $agentResult
                return ($null -ne $agentResult)
            }
        } `
        -CompleteScript {
            param($Handle)
            # On the timeout path the poll script never returned true, so AgentResult is
            # whatever the last poll saw - possibly still $null. Both callers treat that as
            # "no process result, trust status.json".
            if (-not $credentialRecoveryEnabled) {
                return Complete-VMAgentCycle -Handle $Handle -AgentResult $Handle.AgentResult
            }

            return Invoke-GuestOperationWithCredentialRecovery -VMName $Handle.VMName -VIServerScope $VIServerScope -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive -Handle $Handle -OperationScript {
                param($ItemAuth)
                return Complete-VMAgentCycle -Handle $Handle -AgentResult $Handle.AgentResult
            }
        } `
        -IsTransientErrorScript {
            param($ErrorRecord)
            return ((Get-GuestOperationErrorKind -ErrorRecord $ErrorRecord) -eq 'Transient')
        } `
        -GetErrorMetadataScript {
            param($ErrorRecord, $Stage)
            return Get-GuestOperationFailureMetadata -ErrorRecord $ErrorRecord -Stage $Stage
        })
    $phaseResults = @($preflightErrors) + @($fleetResults)

    if ($GuestRunConflictRetriesRemaining -le 0) {
        return $phaseResults
    }

    # A guest that refused because it is on its way back up reconciles itself the moment its boot
    # time is newer, so one short wait here is the difference between riding out a restart someone
    # else ordered and reporting the VM as failed. Every other conflict kind is left as it is - see
    # Select-RetryableGuestRunConflicts for why waiting them out would be wrong rather than slow.
    $retryResults = @(Select-RetryableGuestRunConflicts -FleetResults $phaseResults)
    if (@($retryResults).Count -eq 0) {
        return $phaseResults
    }

    $retryVMNames = @(@($retryResults) | ForEach-Object { [string]$_.VMName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $retryItems = @(@($FleetItems) | Where-Object { $retryVMNames -contains [string]$_.VMName })
    if (@($retryItems).Count -eq 0) {
        return $phaseResults
    }

    Write-Warning ('{0} VM(s) are restarting and refused this phase; waiting {1}s and trying them once more: {2}' -f @($retryItems).Count, $script:GuestRunConflictRetryWaitSeconds, ($retryVMNames -join ', '))
    & $SleepScript $script:GuestRunConflictRetryWaitSeconds

    $retriedResults = @(Invoke-GuestAgentFleet -FleetItems $retryItems -VIServerScope $VIServerScope -Managers $Managers -GuestCredentialMap $GuestCredentialMap `
            -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -WorkspaceScriptPath $WorkspaceScriptPath -RunGuardScriptPath $RunGuardScriptPath `
            -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -MaxInFlight $MaxInFlight `
            -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript `
            -CredentialInteractive $CredentialInteractive -GuestRunConflictRetriesRemaining ($GuestRunConflictRetriesRemaining - 1) -SleepScript $SleepScript)

    return @(Merge-RetriedFleetResults -OriginalResults $phaseResults -RetriedResults $retriedResults -RetriedVMNames $retryVMNames)
}

function Get-GuestRebootJobScript {
    return {
        param($JobInput)

        Set-StrictMode -Version 2.0
        $ErrorActionPreference = 'Stop'

        $connections = @()
        # Only Invoke-VMGuestReboot can leave shutdown.exe running, so every failure before it -
        # the module import, the child's own vCenter login - is unambiguously "never sent" no
        # matter how it classifies. An InvalidGuestLogin inside it is unambiguous too: the guest
        # refused the credential before running anything.
        $rebootAttempted = $false
        try {
            Import-Module VMware.VimAutomation.Core -ErrorAction Stop
            if ($JobInput.IgnoreVCenterCertificate) {
                Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            }
            . $JobInput.GuestOpsLibPath

            # A child job starts cold, so there is never a session to reuse here; everything
            # it opens is its own to disconnect.
            # Connections, not OpenedConnections: the scope this child may search is every
            # session it holds for the one vCenter the parent named, and there is no fallback
            # to PowerCLI's global default sessions.
            $connectResult = Connect-VIServersWithCredentialMap -VIServers @($JobInput.VIServers) -CredentialMap $JobInput.VIServerCredentialMap
            $connections = @($connectResult.OpenedConnections)
            $jobScope = @($connectResult.Connections)
            $managers = $null
            $guestAuth = New-GuestAuthentication -Credential $JobInput.GuestCredential
            $rebootAttempted = $true
            $rebootResult = Invoke-VMGuestReboot -VMName $JobInput.VMName -Servers $jobScope -Managers $managers -GuestAuth $guestAuth -ExpectedMoRefIdentity ([string](Get-ObjectPropertyValue -InputObject $JobInput -Path @('ExpectedMoRefIdentity'))) -WorkspaceScriptPath $JobInput.WorkspaceScriptPath -RunGuardScriptPath $JobInput.RunGuardScriptPath -RebootScriptPath $JobInput.RebootScriptPath

            return [pscustomobject]@{
                Sequence = $JobInput.Sequence
                VMName = $JobInput.VMName
                RebootReason = $JobInput.RebootReason
                ProcessId = $rebootResult.ProcessId
                Error = $null
                ErrorKind = $null
                RejectedBeforeStart = $false
                GuestRunConflict = $false
            }
        }
        catch {
            # The child classifies and never prompts - every credential dialog belongs to the
            # parent process. RejectedBeforeStart is what tells the parent whether re-sending
            # shutdown.exe is safe: an invalid login is refused before the process starts, while
            # a transport failure may well have left it running.
            $rebootErrorKind = 'Permanent'
            if ($null -ne (Get-Command -Name Get-GuestOperationErrorKind -ErrorAction SilentlyContinue)) {
                $rebootErrorKind = Get-GuestOperationErrorKind -ErrorRecord $_
            }
            # Invoke-VMGuestReboot marks the failures it raises before the one guest-touching
            # call, which is the only way the child can tell an inventory or GetView timeout
            # from a transport failure that may have left shutdown.exe running.
            $rebootRejectedBeforeStart = ((-not $rebootAttempted) -or $rebootErrorKind -eq 'InvalidCredentials')
            if (-not $rebootRejectedBeforeStart) {
                try {
                    if ($null -ne $_.Exception.Data -and $_.Exception.Data.Contains('RejectedBeforeStart')) {
                        $rebootRejectedBeforeStart = [bool]$_.Exception.Data['RejectedBeforeStart']
                    }
                }
                catch { }
            }
            # A guest the run guard refused is not "try again later": another run holds it, or a
            # previous one left a trace nobody reconciled. It must not be rebooted at all.
            $rebootGuestRunConflict = $false
            try {
                if ($null -ne $_.Exception.Data -and $_.Exception.Data.Contains('GuestRunConflict')) {
                    $rebootGuestRunConflict = [bool]$_.Exception.Data['GuestRunConflict']
                }
            }
            catch { }

            return [pscustomobject]@{
                Sequence = $JobInput.Sequence
                VMName = $JobInput.VMName
                RebootReason = $JobInput.RebootReason
                ProcessId = $null
                Error = $_.Exception.Message
                ErrorKind = $rebootErrorKind
                RejectedBeforeStart = $rebootRejectedBeforeStart
                GuestRunConflict = $rebootGuestRunConflict
            }
        }
        finally {
            if ($connections.Count -gt 0) {
                try {
                    Disconnect-VIServer -Server $connections -Confirm:$false | Out-Null
                }
                catch { }
            }
        }
    }
}

function Get-SafeFileName {
    param([string]$Value)
    return ($Value -replace '[^a-zA-Z0-9_.-]', '_')
}

function New-UniqueOutputDirectory {
    param([string]$BasePath)

    $candidatePath = $BasePath
    $suffix = 2
    while (Test-Path -LiteralPath $candidatePath) {
        $candidatePath = '{0}-{1}' -f $BasePath, $suffix
        $suffix++
    }

    New-Item -ItemType Directory -Force -Path $candidatePath | Out-Null
    return $candidatePath
}

function Show-UpdateGroups {
    param($UpdateGroups)

    Write-Host ''
    Write-Host 'Available update groups'
    Write-Host '-----------------------'

    $index = 1
    foreach ($group in @($UpdateGroups)) {
        $mark = if ($group.selectedByDefault) { 'x' } else { ' ' }
        $kbText = if ([string]::IsNullOrWhiteSpace([string]$group.kbText)) { 'No KB' } else { [string]$group.kbText }
        Write-Host ('[{0}] {1}. {2} - {3}' -f $mark, $index, $kbText, (Get-UpdateGroupDisplayTitle -UpdateGroup $group))
        Write-Host ('    Applies to: {0} VM; Patchable: {1} VM' -f $group.appliesToVmCount, $group.patchableVmCount)
        $policyReason = [string](Get-RuntimePropertyValue -InputObject $group -Name 'policyReason')
        if ([string](Get-RuntimePropertyValue -InputObject $group -Name 'policyDecision') -eq 'NeedsReview' -and -not [string]::IsNullOrWhiteSpace($policyReason)) {
            Write-Host ('    Needs review: {0} Tick it to install, or leave it unticked to refuse it for this run.' -f $policyReason)
        }
        Write-Host ('    Key: {0}' -f $group.identityKey)
        $index++
    }
}

function Resolve-SelectedUpdateKeys {
    param(
        $UpdateGroups,
        [string[]]$ExplicitSelectedUpdateKeys = @()
    )

    $explicitKeyValues = @($ExplicitSelectedUpdateKeys)
    if ($explicitKeyValues.Count -gt 0) {
        $knownKeys = @{}
        foreach ($group in @($UpdateGroups)) {
            if ($null -eq $group) {
                continue
            }

            $knownKey = ([string]$group.identityKey).Trim()
            if (-not [string]::IsNullOrWhiteSpace($knownKey)) {
                $knownKeys[$knownKey] = $true
            }
        }

        $selectedKeys = @(Get-UniqueTrimmedKeys -Keys $explicitKeyValues)

        if ($selectedKeys.Count -eq 0) {
            throw 'SelectedUpdateKeys did not contain any non-empty update keys.'
        }

        foreach ($selectedKey in $selectedKeys) {
            if (-not $knownKeys.ContainsKey($selectedKey)) {
                throw ('Selected update key is not present in discovered update groups: {0}' -f $selectedKey)
            }
        }

        return $selectedKeys
    }

    return @(@($UpdateGroups) | Where-Object { $_.selectedByDefault } | ForEach-Object { [string]$_.identityKey })
}

function New-UpdateSelectionResult {
    param(
        [string[]]$Keys = @(),
        [switch]$Aborted
    )

    return [pscustomobject]@{
        Aborted = [bool]$Aborted
        Keys = @($Keys)
    }
}

function Invoke-OperatorPrompt {
    param(
        [hashtable]$Provider,
        [string]$Key,
        [hashtable]$Arguments = @{},
        [scriptblock]$FallbackScript
    )

    # Both conditions are required. An unbound [hashtable] parameter is $null, and
    # $null.ContainsKey() throws; dot notation on a missing key throws
    # PropertyNotFoundException under StrictMode 2.0. Measured, not assumed.
    if ($null -ne $Provider -and $Provider.ContainsKey($Key)) {
        return (& $Provider[$Key] $Arguments)
    }

    return (& $FallbackScript $Arguments)
}

function Read-GuestCredentialRecoveryDecision {
    param(
        [string]$VMName,
        [string]$AccountKey,
        [string[]]$Members,
        [string]$Reason
    )

    Write-Host ''
    Write-Host ('Guest credentials for {0} were rejected: {1}' -f $VMName, $Reason)
    Write-Host ('Account {0} applies to: {1}' -f $AccountKey, (@($Members) -join ', '))
    Write-Host 'Actions:'
    Write-Host '  - RETRY  provide replacement guest credentials and validate them before retrying.'
    Write-Host '  - SKIP   skip this account for the rest of this run.'
    Write-Host '  - ABORT  do not start further guest operations.'

    while ($true) {
        $choice = ([string](Read-Host 'Choose RETRY, SKIP, or ABORT (Enter aborts)')).Trim().ToUpperInvariant()
        switch ($choice) {
            'RETRY' {
                $credential = Get-Credential -Message ('Replacement guest credentials for {0}' -f $VMName)
                if ($null -eq $credential) {
                    return [pscustomobject]@{ Action = 'Abort'; Credential = $null; Remember = $false }
                }
                return [pscustomobject]@{ Action = 'Retry'; Credential = $credential; Remember = $false }
            }
            'SKIP' {
                return [pscustomobject]@{ Action = 'SkipAccount'; Credential = $null; Remember = $false }
            }
            'ABORT' {
                return [pscustomobject]@{ Action = 'Abort'; Credential = $null; Remember = $false }
            }
            '' {
                return [pscustomobject]@{ Action = 'Abort'; Credential = $null; Remember = $false }
            }
            default {
                Write-Warning 'Invalid choice. Choose RETRY, SKIP, or ABORT.'
            }
        }
    }
}

function Read-UpdateGroupSelection {
    param(
        $UpdateGroups,
        [hashtable]$PromptProvider
    )

    $groups = @($UpdateGroups)

    return (Invoke-OperatorPrompt -Provider $PromptProvider -Key 'SelectUpdateGroups' -Arguments @{ UpdateGroups = $groups } -FallbackScript {
        param($promptArgs)

        $groups = @($promptArgs.UpdateGroups)
        $selected = @{}
        for ($i = 0; $i -lt $groups.Count; $i++) {
            $selected[$i] = [bool]$groups[$i].selectedByDefault
        }

        while ($true) {
            Write-Host ''
            Write-Host 'Select update groups to install. Actions:'
            Write-Host '  - Type a group number and press Enter to toggle it on ([x]) or off ([ ]).'
            Write-Host '  - Press Enter on an empty line to accept the current selection and continue.'
            for ($i = 0; $i -lt $groups.Count; $i++) {
                $mark = if ($selected[$i]) { 'x' } else { ' ' }
                Write-Host ('[{0}] {1}. {2}' -f $mark, ($i + 1), $groups[$i].title)
            }

            $inputText = Read-Host 'Group number to toggle (Enter to accept)'
            if ([string]::IsNullOrWhiteSpace($inputText)) {
                break
            }

            $displayNumber = 0
            if (-not [int]::TryParse($inputText, [ref]$displayNumber)) {
                Write-Warning ('Invalid group number: {0}' -f $inputText)
                continue
            }

            if ($displayNumber -lt 1 -or $displayNumber -gt $groups.Count) {
                Write-Warning ('Group number {0} is outside the range 1..{1}.' -f $displayNumber, $groups.Count)
                continue
            }

            $selectedIndex = $displayNumber - 1
            $selected[$selectedIndex] = -not $selected[$selectedIndex]
        }

        $selectedKeys = @()
        for ($i = 0; $i -lt $groups.Count; $i++) {
            if ($selected[$i]) {
                $selectedKeys += [string]$groups[$i].identityKey
            }
        }

        New-UpdateSelectionResult -Keys $selectedKeys
    })
}

function Show-PatchPlan {
    param($PatchPlanRecords)

    Write-Host ''
    Write-Host 'Patch plan'
    Write-Host '----------'

    foreach ($record in @($PatchPlanRecords)) {
        Write-Host ''
        Write-Host '--------------------------------------------------'
        Write-Host $record.vmName
        $roleFlagText = if ($record.roleFlags -is [string]) { [string]$record.roleFlags } else { Get-RoleFlagText -RoleFlags $record.roleFlags }
        Write-Host ('Role flags: {0}' -f $roleFlagText)

        if ($record.action -in @('Skip', 'NoSelectedUpdates')) {
            Write-Host $record.reason
            continue
        }

        Write-Host 'Selected:'
        foreach ($update in @($record.selectedUpdates)) {
            $kbPrefix = if ([string]::IsNullOrWhiteSpace([string]$update.kbText)) { '' } else { ('{0} - ' -f $update.kbText) }
            Write-Host ('- {0}{1}' -f $kbPrefix, $update.title)
        }
    }
}

function Confirm-PatchPlan {
    param([switch]$SkipConfirmation)

    if ($SkipConfirmation) {
        return $true
    }

    $answer = Read-Host 'Proceed with this plan? [Y/N]'
    return ($answer -ieq 'Y' -or $answer -ieq 'Yes')
}

function Read-ContinuePatchingDecision {
    param($CompletionStates, [int]$Round)

    Write-Host ''
    Write-Host ('After round {0} the following VM(s) still have selectable updates:' -f $Round)
    foreach ($state in @(@($CompletionStates) | Where-Object { [string]$_.state -eq 'Pending' })) {
        Write-Host ('- {0}: {1}' -f $state.vmName, $state.reason)
    }
    Write-Host ''
    Write-Host 'Actions:'
    Write-Host '  - CONTINUE  run another patch round for the VMs above.'
    Write-Host '  - FINISH    stop patching now; the run ends with an error because they are not up to date.'
    Write-Host ''

    $answer = ''
    while (@('CONTINUE', 'FINISH') -notcontains $answer) {
        $answer = ([string](Read-Host 'Choose CONTINUE, FINISH')).Trim().ToUpperInvariant()
        if (@('CONTINUE', 'FINISH') -notcontains $answer) {
            Write-Host 'Invalid choice. Options: CONTINUE / FINISH'
        }
    }

    return $answer
}

function Read-RescanDecision {
    while ($true) {
        $answer = ([string](Read-Host 'Ponownie przeskanować te same VM? [T/N]')).Trim().ToUpperInvariant()
        if ($answer -eq 'T') { return $true }
        if ($answer -eq 'N' -or $answer -eq '') { return $false }
        Write-Host 'Wpisz T lub N.'
    }
}

function Write-PatchRoundVerification {
    param($CompletionStates, [int]$Round)

    Write-Host ''
    Write-Host ('Post-reboot verification after round {0}' -f ($Round - 1))
    Write-Host '---------------------------------------'
    foreach ($state in @($CompletionStates)) {
        $verificationColor = switch ([string]$state.state) {
            'Green' { 'Green' }
            'GreenByOperatorChoice' { 'Green' }
            'Excluded' { 'DarkGray' }
            'Pending' { 'Yellow' }
            default { 'Red' }
        }
        Write-Host ('{0}: {1} - {2}' -f $state.vmName, $state.state, $state.reason) -ForegroundColor $verificationColor
    }
}

function Read-RebootBatchSize {
    param([int]$TargetCount)

    Write-Host ''
    Write-Host 'Reboots run in batches; the next batch starts only after every VM in the current batch reports a newer boot time.'
    Write-Host ('There are {0} VM(s) to reboot.' -f $TargetCount)

    $resolvedBatchSize = 0
    while ($resolvedBatchSize -lt 1) {
        $answer = ([string](Read-Host 'How many VMs per reboot batch? (Enter for 1)')).Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) {
            $resolvedBatchSize = 1
        }
        elseif (-not ([int]::TryParse($answer, [ref]$resolvedBatchSize)) -or $resolvedBatchSize -lt 1) {
            $resolvedBatchSize = 0
            Write-Warning 'Enter a whole number greater than or equal to 1, or press Enter for 1.'
        }
    }

    return $resolvedBatchSize
}

function Confirm-GuestReboot {
    param($RebootTargets)

    $targets = @($RebootTargets)
    if ($targets.Count -eq 0) {
        return $false
    }

    Write-Host ''
    Write-Host ('Reboot required on {0} VM(s):' -f $targets.Count)
    foreach ($target in $targets) {
        $rebootReason = [string](Get-ObjectPropertyValue -InputObject $target -Path @('rebootReason'))
        $reasonText = if ([string]::IsNullOrWhiteSpace($rebootReason)) { '' } else { (' ({0})' -f $rebootReason) }
        Write-Host ('- {0}{1}' -f $target.vmName, $reasonText)
    }
    Write-Host ''
    Write-Host 'Actions:'
    Write-Host '  - Type REBOOT (uppercase) and press Enter to reboot the VM(s) above now.'
    Write-Host '  - Type anything else (or just press Enter) to skip the reboot and leave them as-is.'

    $answer = Read-Host 'Type REBOOT to continue'
    return (([string]$answer).Trim() -ceq 'REBOOT')
}

function Update-PatchPlanWithDiscoveryFailures {
    param(
        $PatchPlanRecords,
        $DiscoveryRecords
    )

    $planRecordsByVmName = @{}
    foreach ($record in @($PatchPlanRecords)) {
        $vmName = [string](Get-ObjectPropertyValue -InputObject $record -Path @('vmName'))
        if (-not [string]::IsNullOrWhiteSpace($vmName) -and -not $planRecordsByVmName.ContainsKey($vmName)) {
            $planRecordsByVmName[$vmName] = $record
        }
    }

    foreach ($discoveryRecord in @($DiscoveryRecords)) {
        $vmName = [string](Get-ObjectPropertyValue -InputObject $discoveryRecord -Path @('vmName'))
        if ([string]::IsNullOrWhiteSpace($vmName) -or -not $planRecordsByVmName.ContainsKey($vmName)) {
            continue
        }

        $errors = @(Get-ObjectPropertyValue -InputObject $discoveryRecord -Path @('errors') -DefaultValue @() | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
        $outcome = [string](Get-ObjectPropertyValue -InputObject $discoveryRecord -Path @('outcome'))
        $hasDiscoveryErrors = ($errors.Count -gt 0)
        $hasSuccessfulDiscoveryOutcome = Test-IsSuccessfulDiscoveryOutcome -Outcome $outcome
        if (-not $hasDiscoveryErrors -and $hasSuccessfulDiscoveryOutcome) {
            continue
        }

        $planRecord = $planRecordsByVmName[$vmName]
        $planRecord.action = 'Skip'
        $planRecord.reason = 'Skipped: Discovery failed. Review discovery.json and per-VM agent artifacts.'
        $planRecord.selectedUpdates = @()
    }

    return @($PatchPlanRecords)
}

function Test-IsSuccessfulDiscoveryOutcome {
    param([string]$Outcome)

    return ($Outcome -in @('SearchOnly', 'NoApplicableUpdates'))
}

function New-DiscoveryRecord {
    param(
        [string]$VMName,
        $Status,
        [string]$OutputDirectory,
        [string[]]$Errors = @(),
        [string]$CleanupStatus,
        [string]$CleanupReason
    )

    $outcome = Get-ObjectPropertyValue -InputObject $Status -Path @('outcome')
    if ([string]::IsNullOrWhiteSpace([string]$outcome) -and @($Errors).Count -gt 0) {
        $outcome = 'DiscoveryFailed'
    }

    return [pscustomobject]@{
        vmName = $VMName
        computerName = Get-ObjectPropertyValue -InputObject $Status -Path @('computerName')
        outcome = $outcome
        isElevated = Get-ObjectPropertyValue -InputObject $Status -Path @('isElevated')
        availableUpdateCount = Get-ObjectPropertyValue -InputObject $Status -Path @('availableUpdateCount') -DefaultValue 0
        roleFlags = Get-ObjectPropertyValue -InputObject $Status -Path @('roleFlags')
        pendingRebootBefore = Get-ObjectPropertyValue -InputObject $Status -Path @('pendingRebootBefore')
        updates = @(Get-ObjectPropertyValue -InputObject $Status -Path @('updates') -DefaultValue @())
        outputDirectory = $OutputDirectory
        cleanupStatus = $CleanupStatus
        cleanupReason = $CleanupReason
        errors = @($Errors)
    }
}

function New-DiscoveryRecordFromAgentRun {
    param(
        [string]$VMName,
        $AgentRun,
        [string]$OutputDirectory
    )

    $record = New-DiscoveryRecord -VMName $VMName -Status $AgentRun.Status -OutputDirectory $OutputDirectory -CleanupStatus (Get-ObjectPropertyValue -InputObject $AgentRun -Path @('CleanupStatus')) -CleanupReason (Get-ObjectPropertyValue -InputObject $AgentRun -Path @('CleanupReason'))
    $recordErrors = @($record.errors)

    if (-not (Test-IsSuccessfulDiscoveryOutcome -Outcome $record.outcome)) {
        $recordErrors += ('Discovery returned outcome {0}.' -f $record.outcome)
    }

    if (-not [bool](Get-ObjectPropertyValue -InputObject $AgentRun -Path @('AgentCompletionConfirmed') -DefaultValue $false)) {
        $recordErrors += 'Discovery agent completion was not confirmed for the current run.'
    }
    elseif ($null -eq $AgentRun.AgentResult -or -not $AgentRun.AgentResult.Completed) {
        Write-Warning ('Discovery guest process result was lost for {0}. The current run has a confirmed terminal status, so status.json remains the primary discovery result.' -f $VMName)
    }

    $record.errors = @($recordErrors)
    return $record
}

function Invoke-ApplyPhase {
    param(
        $PatchPlanRecords,
        [object[]]$VIServerScope,
        $Managers,
        $GuestCredentialMap,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$IdentityHelperPath,
        [string]$WorkspaceScriptPath,
        [string]$RunGuardScriptPath,
        [string]$GuestWorkingDirectory,
        [int]$TimeoutSeconds,
        [int]$PollSeconds,
        [string]$CycleOutputDirectory,
        [int]$MaxInFlight = 1,
        [hashtable]$CredentialContext = $null,
        [scriptblock]$CredentialDecisionScript,
        [scriptblock]$CredentialValidatedScript,
        [bool]$CredentialInteractive = $false
    )

    $resultEntries = @()
    $fleetItems = @()
    $recordNumber = 0

    foreach ($record in @($PatchPlanRecords)) {
        $recordNumber++

        if ($record.action -ne 'Install') {
            # roleFlags come from the plan: no cycle ran, so there is no guest status to read them
            # from, and the reboot selection needs them to keep excluding a cluster. Cleanup is
            # $null rather than a made-up verdict - nothing was created to clean up.
            $resultEntries += [pscustomobject]@{
                Sequence = $recordNumber
                Result = New-ApplyResultRecord -VMName ([string]$record.vmName) -Action ([string]$record.action) -Outcome 'Skipped' `
                    -Reason ([string]$record.reason) -RoleFlags (Get-ObjectPropertyValue -InputObject $record -Path @('roleFlags')) `
                    -RebootRequired $false -AgentCompletionConfirmed $false
            }
            continue
        }

        $identityKeys = foreach ($selectedUpdate in @($record.selectedUpdates)) {
            [string](Get-ObjectPropertyValue -InputObject $selectedUpdate -Path @('identityKey'))
        }
        $selectedKeys = @(Get-UniqueTrimmedKeys -Keys @($identityKeys))

        $vmOutputDirectory = Join-Path $CycleOutputDirectory ('{0:D3}-apply-{1}' -f $recordNumber, (Get-SafeFileName -Value $record.vmName))
        Write-Step -Message ('Apply starting for VM {0} with {1} selected update(s).' -f $record.vmName, $selectedKeys.Count)

        if ($selectedKeys.Count -eq 0) {
            $reason = 'No selected update keys were available for apply.'
            $resultEntries += [pscustomobject]@{
                Sequence = $recordNumber
                Result = New-ApplyResultRecord -VMName ([string]$record.vmName) -Outcome 'Failed' -Reason $reason `
                    -RoleFlags (Get-ObjectPropertyValue -InputObject $record -Path @('roleFlags')) `
                    -RebootRequired $false -AgentCompletionConfirmed $false -AgentCompletionReason 'No agent cycle was started.' `
                    -Errors @($reason)
            }
            continue
        }

        New-Item -ItemType Directory -Force -Path $vmOutputDirectory | Out-Null
        $selectionDocument = New-UpdateSelectionDocument -SelectedUpdateKeys $selectedKeys
        $localSelectionPath = Join-Path $vmOutputDirectory 'selection.json'
        $selectionDocument | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $localSelectionPath -Encoding UTF8

        $fleetItems += New-AgentFleetItem -Sequence $recordNumber -VMName ([string]$record.vmName) -VMOutputDirectory $vmOutputDirectory -MaxUpdates $selectedKeys.Count -LocalSelectionPath $localSelectionPath -SearchOnly $false
    }

    if ($fleetItems.Count -gt 0) {
        Write-Step -Message ('Apply running with up to {0} VM(s) in flight.' -f $MaxInFlight)
        $fleetResults = @(Invoke-GuestAgentFleet -FleetItems $fleetItems -VIServerScope $VIServerScope -Managers $Managers -GuestCredentialMap $GuestCredentialMap -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -WorkspaceScriptPath $WorkspaceScriptPath -RunGuardScriptPath $RunGuardScriptPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -MaxInFlight $MaxInFlight -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive)

        $doneCount = 0
        foreach ($fleetResult in @($fleetResults | Sort-Object Sequence)) {
            $doneCount++
            Write-Step -Message ('  {0}/{1} apply finished: {2}' -f $doneCount, $fleetItems.Count, $fleetResult.VMName)

            $hasError = -not [string]::IsNullOrWhiteSpace([string]$fleetResult.Error)
            $payload = Get-ObjectPropertyValue -InputObject $fleetResult -Path @('Payload')
            $resultKind = [string](Get-ObjectPropertyValue -InputObject $fleetResult -Path @('ResultKind'))

            if ($hasError -and $null -eq $payload) {
                # No payload at all, so nothing can be read from the guest - including whether a
                # cycle directory was created. An invented cleanup verdict here would be a claim
                # about a guest this run never heard back from.
                $resultEntries += [pscustomobject]@{
                    Sequence = $fleetResult.Sequence
                    Result = New-ApplyResultRecord -VMName ([string]$fleetResult.VMName) -Outcome 'Failed' -Reason ([string]$fleetResult.Error) `
                        -RebootRequired $false -AgentCompletionConfirmed $false -AgentCompletionReason 'Agent cycle did not return a completion record.' `
                        -Errors @([string]$fleetResult.Error) `
                        -GuestRunConflict ([bool](Get-ObjectPropertyValue -InputObject $fleetResult -Path @('GuestRunConflict') -DefaultValue $false))
                }
                continue
            }

            if ($hasError -and $resultKind -ne 'Timeout') {
                $failedResult = New-ApplyResultFromCycle -VMName $fleetResult.VMName -Cycle $payload
                $failedResult.outcome = 'Failed'
                $failedResult.reason = [string]$fleetResult.Error
                $failedResult.rebootRequired = $false
                $failedResult.agentCompletionConfirmed = $false
                $failedResult.agentCompletionReason = 'Permanent GuestOps poll error prevented confirmed agent completion.'
                $failedResult.errors = @($fleetResult.Error) + @($failedResult.errors)
                $resultEntries += [pscustomobject]@{
                    Sequence = $fleetResult.Sequence
                    Result = $failedResult
                }
                continue
            }

            if ($hasError) {
                # Only the explicitly typed timeout path may fall back to the downloaded status.json.
                Write-Warning ('Apply process result timed out for {0}; falling back to the downloaded status.json.' -f $fleetResult.VMName)
            }

            $resultEntries += [pscustomobject]@{
                Sequence = $fleetResult.Sequence
                Result = New-ApplyResultFromCycle -VMName $fleetResult.VMName -Cycle $payload
            }
        }
    }

    $results = @($resultEntries | Sort-Object Sequence | ForEach-Object { $_.Result })
    $applyResultsPath = Join-Path $CycleOutputDirectory 'apply-results.json'
    ConvertTo-Json -InputObject @($results) -Depth 12 | Set-Content -LiteralPath $applyResultsPath -Encoding UTF8
    return @($results)
}

function Read-RebootDecision {
    param($Context)

    $stage = [string]$Context.Stage
    $batchNumber = [int]$Context.BatchNumber
    $vmNames = @($Context.VMNames | ForEach-Object { [string]$_ })
    $vmList = $vmNames -join ', '

    Write-Host ''
    switch ($stage) {
        'BaselineShortfall' {
            Write-Host ('Could not read baseline boot time before reboot for batch {0} VM(s): {1}' -f $batchNumber, $vmList)
            Write-Host 'Without a baseline the reboot cannot be confirmed to have changed the boot time.'
            $options = @('RETRY', 'CONTINUE', 'ABORT')
        }
        'InitiationError' {
            Write-Host ('Failed to initiate reboot for batch {0} VM(s): {1}' -f $batchNumber, $vmList)
            Write-Host 'The shutdown command was not retried automatically to avoid the risk of a double reboot.'
            $options = @('CONTINUE', 'ABORT')
        }
        'WaitTimeout' {
            Write-Host ('Boot time did not confirm within {0}s for batch {1} VM(s): {2}' -f $Context.WaitSeconds, $batchNumber, $vmList)
            $options = @('RETRY', 'CONTINUE', 'ABORT')
        }
        default {
            $options = @('CONTINUE', 'ABORT')
        }
    }

    Write-Host 'Actions:'
    if (@($options) -contains 'RETRY') {
        Write-Host ('  - RETRY     check again without re-sending reboot, for a new full timeout period.')
    }
    Write-Host ('  - CONTINUE  continue with the next reboot batch even though not every server is confirmed.')
    Write-Host ('  - ABORT     do not start further reboot batches; the run ends with an error.')
    Write-Host ''

    while ($true) {
        $answer = ([string](Read-Host ('Choose {0}' -f ($options -join ', ')))).Trim().ToUpperInvariant()
        if (@($options) -contains $answer) {
            return $answer
        }
        Write-Host ('Invalid choice. Options: {0}' -f ($options -join ' / '))
    }
}

function Invoke-GuestRebootPhase {
    param(
        $RebootTargets,
        $GuestCredentialMap,
        [string[]]$VIServers,
        [object[]]$VIServerScope,
        [hashtable]$VIServerCredentialMap,
        [switch]$IgnoreVCenterCertificate,
        [string]$GuestOpsLibPath,
        [string]$CurlPath,
        [string]$WorkspaceScriptPath,
        [string]$RunGuardScriptPath,
        [string]$RebootRequestScriptPath,
        [string]$GuestWorkingDirectory,
        [int]$RebootTimeoutSeconds,
        [int]$PollSeconds,
        [int]$RebootBatchSize = 1,
        # Every other path this phase needs is already a parameter; this one used to be derived
        # from $PSScriptRoot inside the body, which is empty whenever the function is reloaded
        # from its own source text rather than from the file.
        [string]$BootTimeHelperPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'guest\Read-BootTime.ps1'),
        [hashtable]$CredentialContext = $null,
        [scriptblock]$CredentialDecisionScript,
        [scriptblock]$CredentialValidatedScript,
        [bool]$CredentialInteractive = $false
    )

    $credentialRecoveryEnabled = ($null -ne $CredentialContext)

    $targetInputs = @()
    $sequence = 0
    foreach ($target in @($RebootTargets)) {
        $sequence++
        $targetInputs += [pscustomobject]@{
            Sequence = $sequence
            VMName = [string]$target.vmName
            RebootReason = [string](Get-ObjectPropertyValue -InputObject $target -Path @('rebootReason'))
        }
    }

    $restartJobScript = Get-GuestRebootJobScript

    # Boot-time reads run in this process, against the vCenter connection the orchestrator already
    # holds. A child job would re-import PowerCLI and log in to vCenter once per VM per polling
    # round - tens of seconds of startup wrapped around a few seconds of real work - so sequential
    # in-process reads finish a batch sooner than parallel jobs and leave no extra vCenter sessions
    # behind. PowerCLI exposes no supported way to hand a live session to a child process.
    $helperUploadedByVm = @{}
    $readBootTimeScript = {
        param($Items)
        $results = @()
        foreach ($item in @($Items)) {
            $vmName = [string]$item.VMName
            $timeoutSeconds = if ($null -eq $item.ReadTimeoutSeconds) { 120 } else { [int][math]::Max(1, [math]::Min(120, $item.ReadTimeoutSeconds)) }
            try {
                if ($credentialRecoveryEnabled) {
                    $bootTime = Invoke-GuestOperationWithCredentialRecovery -VMName $vmName -VIServerScope $VIServerScope -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive -OperationScript {
                        param($ReadAuth)
                        return Invoke-VMGuestBootTimeRead -VMName $vmName -Servers $VIServerScope -Managers $null -GuestAuth $ReadAuth -CurlPath $CurlPath -WorkspaceScriptPath $WorkspaceScriptPath -GuestWorkingDirectory $GuestWorkingDirectory -BootTimeHelperPath $BootTimeHelperPath -TimeoutSeconds $timeoutSeconds -PollSeconds $PollSeconds -SkipHelperUpload:([bool]$helperUploadedByVm[$vmName])
                    }
                }
                else {
                    $guestAuth = New-GuestAuthentication -Credential $GuestCredentialMap[$vmName]
                    $bootTime = Invoke-VMGuestBootTimeRead -VMName $vmName -Servers $VIServerScope -Managers $null -GuestAuth $guestAuth -CurlPath $CurlPath -WorkspaceScriptPath $WorkspaceScriptPath -GuestWorkingDirectory $GuestWorkingDirectory -BootTimeHelperPath $BootTimeHelperPath -TimeoutSeconds $timeoutSeconds -PollSeconds $PollSeconds -SkipHelperUpload:([bool]$helperUploadedByVm[$vmName])
                }
                $helperUploadedByVm[$vmName] = $true
                $results += [pscustomobject]@{
                    Sequence = $item.Sequence
                    VMName = $vmName
                    BootTimeUtc = $bootTime.BootTimeUtc
                    UptimeSeconds = $bootTime.UptimeSeconds
                    Error = $null
                    ErrorKind = $null
                    RejectedBeforeStart = $false
                }
            }
            catch {
                # Without a job around each read, one guest throwing would end the whole phase, so
                # every failure has to become this VM's transient error instead. It also re-arms the
                # upload: a guest that lost the helper must not stay locked into skipping it.
                # The classification rides along so the coordinator can tell a guest that is still
                # booting from an account the operator has already refused to fix.
                $helperUploadedByVm[$vmName] = $false
                $readFailure = Get-GuestOperationFailureMetadata -ErrorRecord $_ -Stage 'BootTimeRead'
                $results += [pscustomobject]@{
                    Sequence = $item.Sequence
                    VMName = $vmName
                    BootTimeUtc = $null
                    UptimeSeconds = $null
                    Error = $_.Exception.Message
                    ErrorKind = $readFailure.ErrorKind
                    RejectedBeforeStart = $readFailure.RejectedBeforeStart
                }
            }
        }
        return @($results)
    }

    $submitRebootJobs = {
        param($SubmitItems, $CredentialOverrides)
        $jobInputs = @()
        $resolutionFailures = @()
        foreach ($item in @($SubmitItems)) {
            $submitName = [string]$item.VMName
            $submitCredential = if ($null -ne $CredentialOverrides -and $CredentialOverrides.ContainsKey($submitName)) { $CredentialOverrides[$submitName] } else { $GuestCredentialMap[$submitName] }

            # Resolve the target here, in the session this run already holds, so the child gets
            # one vCenter name and one managed object instead of the whole scope to search. A
            # child that logged in to every vCenter could reboot a same-named VM elsewhere.
            $submitServer = $null
            $submitMoRef = $null
            try {
                $submitVM = Get-ExactVM -Name $submitName -Servers $VIServerScope
                $submitServer = Get-VMOwningServerName -VM $submitVM -Servers $VIServerScope
                $submitMoRef = Get-VMMoRefIdentity -VM $submitVM
                if ([string]::IsNullOrWhiteSpace([string]$submitServer)) {
                    throw ('Unable to tell which vCenter owns VM {0}; refusing to reboot it through an unconfirmed session.' -f $submitName)
                }
            }
            catch {
                # Nothing reached the guest, so this is unambiguously a failed initiation.
                $resolutionFailures += [pscustomobject]@{
                    Sequence = $item.Sequence
                    VMName = $item.VMName
                    RebootReason = $item.RebootReason
                    ProcessId = $null
                    Error = $_.Exception.Message
                    ErrorKind = 'Permanent'
                    RejectedBeforeStart = $true
                    GuestRunConflict = $false
                }
                continue
            }

            $jobInputs += [pscustomobject]@{
                Sequence = $item.Sequence
                VMName = $item.VMName
                RebootReason = $item.RebootReason
                VIServers = @($submitServer)
                ExpectedMoRefIdentity = $submitMoRef
                VIServerCredentialMap = $VIServerCredentialMap
                GuestCredential = $submitCredential
                IgnoreVCenterCertificate = [bool]$IgnoreVCenterCertificate
                GuestOpsLibPath = $GuestOpsLibPath
                WorkspaceScriptPath = $WorkspaceScriptPath
                RunGuardScriptPath = $RunGuardScriptPath
                RebootScriptPath = $RebootRequestScriptPath
            }
        }
        $jobResults = if ($jobInputs.Count -gt 0) { @(Invoke-ThrottledJobs -Items $jobInputs -ThrottleLimit $RebootBatchSize -JobTimeoutSeconds 300 -ScriptBlock $restartJobScript) } else { @() }
        return @($resolutionFailures) + @($jobResults)
    }

    $initiateRebootScript = {
        param($Items)
        $submittedCredentials = @{}
        foreach ($item in @($Items)) {
            $submittedCredentials[[string]$item.VMName] = $GuestCredentialMap[[string]$item.VMName]
        }

        $results = @(& $submitRebootJobs @($Items) $null)
        if (-not $credentialRecoveryEnabled) {
            return @($results)
        }

        # Only a rejection the guest made BEFORE shutdown.exe started may be re-sent. An
        # ambiguous transport failure could have left the command running, and a second
        # shutdown would be a second reboot - which is exactly what the coordinator's
        # ambiguous-initiation path exists to avoid.
        $resultsByVm = @{}
        foreach ($result in @($results)) {
            $resultsByVm[[string]$result.VMName] = $result
        }

        $retryItems = @()
        foreach ($item in @($Items)) {
            $result = $resultsByVm[[string]$item.VMName]
            if ($null -eq $result -or [string]::IsNullOrWhiteSpace([string]$result.Error)) {
                continue
            }
            if ([string](Get-ObjectPropertyValue -InputObject $result -Path @('ErrorKind')) -ne 'InvalidCredentials') {
                continue
            }
            if (-not [bool](Get-ObjectPropertyValue -InputObject $result -Path @('RejectedBeforeStart') -DefaultValue $false)) {
                continue
            }
            $retryItems += $item
        }

        if ($retryItems.Count -eq 0) {
            return @($results)
        }

        $replacementCredentials = @{}
        $resolvedItems = @()
        # The guest refused this credential, but validation cannot see that - it would happily
        # accept the same credential and re-send it. So the first VM of each account forces the
        # dialog, and the rest of that account resolve against whatever replacement it produced.
        # Asking per VM instead would open one identical dialog per guest in a domain group, and
        # a SKIP at the last one would retroactively poison the account the earlier ones fixed.
        $promptedAccountKeys = @{}
        foreach ($retryItem in @($retryItems)) {
            $retryName = [string]$retryItem.VMName
            $retryGroup = Get-GuestCredentialGroupForTarget -Context $CredentialContext -VMName $retryName
            $retryAccountKey = if ($null -eq $retryGroup) { $retryName } else { Get-GuestCredentialAccountKey -Group $retryGroup }
            $forceAccountPrompt = -not $promptedAccountKeys.ContainsKey($retryAccountKey)
            $promptedAccountKeys[$retryAccountKey] = $true
            $resolution = Resolve-GuestCredentialForTarget -VMName $retryName -Context $CredentialContext -ValidateScript {
                param($TargetName, $Credential)
                return Test-GuestCredentialForTarget -VMName $TargetName -VIServerScope $VIServerScope -Credential $Credential
            } -DecisionScript $CredentialDecisionScript -OnValidatedScript $CredentialValidatedScript -ForcePrompt:$forceAccountPrompt -Interactive:$CredentialInteractive

            # Validation succeeding is not permission to re-send. ValidateCredentialsInGuest and
            # StartProgramInGuest are different calls, so the guest can accept the credential here
            # and still have refused the reboot with it - and re-sending the SAME credential is
            # then just another failed logon against an account that is already failing. Only a
            # credential recovery actually replaced is worth a second submission.
            if ($resolution.Status -eq 'Ready' -and -not (Test-GuestCredentialEquivalent -Left $resolution.Credential -Right $submittedCredentials[$retryName])) {
                $replacementCredentials[$retryName] = $resolution.Credential
                $resolvedItems += $retryItem
                continue
            }

            # A skipped or aborted account is not an initiation error the operator can answer
            # again, so it is reclassified here and the coordinator records it without a second
            # prompt for the same decision.
            $rejected = $resultsByVm[$retryName]
            $unrecoveredReason = if ($resolution.Status -eq 'Ready') { 'The guest refused this credential and credential recovery did not replace it.' } else { [string]$resolution.Reason }
            $unrecoveredKind = if ($resolution.Status -eq 'Ready') { 'CredentialsFailed' } else { Get-GuestCredentialResolutionErrorKind -Status ([string]$resolution.Status) }
            $resultsByVm[$retryName] = [pscustomobject]@{
                Sequence = $rejected.Sequence
                VMName = $rejected.VMName
                RebootReason = Get-ObjectPropertyValue -InputObject $rejected -Path @('RebootReason')
                ProcessId = $null
                Error = $unrecoveredReason
                ErrorKind = $unrecoveredKind
                RejectedBeforeStart = $true
            }
        }

        if ($resolvedItems.Count -gt 0) {
            foreach ($retryResult in @(& $submitRebootJobs @($resolvedItems) $replacementCredentials)) {
                $resultsByVm[[string]$retryResult.VMName] = $retryResult
            }
        }

        # A VM with no result at all stays absent: the coordinator counts a missing result as a
        # failed initiation, and inventing one here would hide it.
        return @(@($Items) | ForEach-Object { $resultsByVm[[string]$_.VMName] } | Where-Object { $null -ne $_ })
    }

    $decisionPromptScript = {
        param($Context)
        return Read-RebootDecision -Context $Context
    }

    return @(Invoke-RebootBatchCoordinator -RebootTargets $targetInputs -BatchSize $RebootBatchSize -WaitTimeoutSeconds $RebootTimeoutSeconds -PollSeconds $PollSeconds -ReadBootTimeScript $readBootTimeScript -InitiateRebootScript $initiateRebootScript -DecisionPromptScript $decisionPromptScript)
}

function Write-PatchingSummary {
    param($ApplyResults)

    Write-Host ''
    Write-Host 'Patching summary'
    Write-Host '----------------'
    foreach ($result in @($ApplyResults)) {
        $status = Get-ApplySummaryStatus -ApplyResult $result
        switch ($status) {
            'Installed' { $label = 'Installed'; $color = 'Green' }
            'InstalledRebootRequired' { $label = 'Installed (reboot required)'; $color = 'Yellow' }
            'Partial' { $label = 'Partially installed (some updates failed - see artifacts)'; $color = 'DarkYellow' }
            'Skipped' { $label = ([string]$result.reason); $color = 'DarkGray' }
            default {
                $reasonText = ([string]$result.reason).Trim()
                $label = if ([string]::IsNullOrWhiteSpace($reasonText)) { 'Failed' } else { ('Failed - {0}' -f $reasonText) }
                $color = 'Red'
            }
        }
        Write-Host ('{0}: {1}' -f $result.vmName, $label) -ForegroundColor $color
    }
}

function Write-FinalReport {
    param(
        $PatchPlanRecords,
        $ApplyResults,
        [string]$CycleOutputDirectory,
        $RebootTargets = $null
    )

    $summaryRows = @(ConvertTo-PatchSummaryRows -PatchPlanRecords $PatchPlanRecords)
    $csvPath = Join-Path $CycleOutputDirectory 'summary.csv'
    $summaryRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    $patched = @($ApplyResults | Where-Object { $_.outcome -eq 'InstallSucceeded' })
    $noUpdates = @($PatchPlanRecords | Where-Object { $_.action -eq 'NoSelectedUpdates' })
    $skipped = @($PatchPlanRecords | Where-Object { $_.action -eq 'Skip' })
    # Wrap the whole expression, not each branch. An if-expression assigns its branch's
    # pipeline output, and an empty collection emits nothing at all - so @() inside a branch
    # assigns $null, and the count below then threw under StrictMode on any fleet with no
    # reboot targets. That state used to be unreachable here because a stale
    # PendingFileRenameOperations kept every guest on the list.
    $rebootRequired = @(
        if ($null -eq $RebootTargets) { Select-RebootRequiredApplyResults -ApplyResults $ApplyResults }
        else { $RebootTargets }
    )
    $errors = @($ApplyResults | Where-Object { Test-IsApplyResultError -ApplyResult $_ })
    $clusters = @($PatchPlanRecords | Where-Object { $_.reason -eq 'Skipped: Failover Cluster detected. Please update manually one by one.' })

    $lines = @()
    $lines += '# Patch summary'
    $lines += ''
    $lines += ('Output directory: `{0}`' -f $CycleOutputDirectory)
    $lines += ''
    $lines += ('- VMs patched: {0}' -f $patched.Count)
    $lines += ('- VMs without selected updates: {0}' -f $noUpdates.Count)
    $lines += ('- VMs skipped: {0}' -f $skipped.Count)
    $lines += ('- VMs requiring reboot: {0}' -f $rebootRequired.Count)
    $lines += ('- VMs with errors: {0}' -f $errors.Count)
    $lines += ('- VMs rejected by Failover Cluster: {0}' -f $clusters.Count)
    $lines += ''

    foreach ($section in @(
        [pscustomobject]@{ Title = 'VMs requiring reboot'; Rows = $rebootRequired },
        [pscustomobject]@{ Title = 'VMs with errors'; Rows = $errors },
        [pscustomobject]@{ Title = 'VMs rejected by Failover Cluster'; Rows = $clusters }
    )) {
        $lines += ('## {0}' -f $section.Title)
        if (@($section.Rows).Count -eq 0) {
            $lines += '- none'
        }
        else {
            foreach ($row in @($section.Rows)) {
                $rebootReason = [string](Get-ObjectPropertyValue -InputObject $row -Path @('rebootReason'))
                $reasonText = if ([string]::IsNullOrWhiteSpace($rebootReason)) { '' } else { (' ({0})' -f $rebootReason) }
                $lines += ('- {0}{1}' -f $row.vmName, $reasonText)
            }
        }
        $lines += ''
    }

    $markdownPath = Join-Path $CycleOutputDirectory 'summary.md'
    Set-Content -LiteralPath $markdownPath -Value $lines -Encoding UTF8

    Write-Host ''
    Write-Host 'Final report'
    Write-Host '------------'
    Write-Host ('Summary CSV: {0}' -f $csvPath)
    Write-Host ('Summary Markdown: {0}' -f $markdownPath)
}

function Invoke-ApplyAndOptionalReboot {
    param(
        $PatchPlanRecords,
        $Managers,
        $GuestCredentialMap,
        [string[]]$VIServers,
        [object[]]$VIServerScope,
        [hashtable]$VIServerCredentialMap,
        [switch]$IgnoreVCenterCertificate,
        [string]$GuestOpsLibPath,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$IdentityHelperPath,
        [string]$WorkspaceScriptPath,
        [string]$RunGuardScriptPath,
        [string]$RebootRequestScriptPath,
        [string]$GuestWorkingDirectory,
        [int]$TimeoutSeconds,
        [int]$RebootTimeoutSeconds,
        [int]$PollSeconds,
        [string]$CycleOutputDirectory,
        [int]$ThrottleLimit,
        [int]$RebootBatchSize = 0,
        $DiscoveryRecords = @(),
        [hashtable]$CredentialContext = $null,
        [scriptblock]$CredentialDecisionScript,
        [scriptblock]$CredentialValidatedScript,
        [bool]$CredentialInteractive = $false
    )

    $applyResults = @(Invoke-ApplyPhase -PatchPlanRecords $PatchPlanRecords -VIServerScope $VIServerScope -Managers $Managers -GuestCredentialMap $GuestCredentialMap -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -WorkspaceScriptPath $WorkspaceScriptPath -RunGuardScriptPath $RunGuardScriptPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -CycleOutputDirectory $CycleOutputDirectory -MaxInFlight $ThrottleLimit -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive)
    Write-PatchingSummary -ApplyResults $applyResults

    $rebootActions = @()
    $rebootTargets = @(Select-RebootRequiredApplyResults -ApplyResults $applyResults -DiscoveryRecords $DiscoveryRecords)
    Write-FinalReport -PatchPlanRecords $PatchPlanRecords -ApplyResults $applyResults -CycleOutputDirectory $CycleOutputDirectory -RebootTargets $rebootTargets
    if ($rebootTargets.Count -gt 0) {
        if (Confirm-GuestReboot -RebootTargets $rebootTargets) {
            # Blast radius is a separate decision from apply concurrency, so it gets its own
            # answer. Like the REBOOT prompt this one is not skipped by -SkipConfirmation;
            # a non-interactive run supplies -RebootBatchSize instead.
            $resolvedRebootBatchSize = $RebootBatchSize
            if ($resolvedRebootBatchSize -lt 1) {
                $resolvedRebootBatchSize = Read-RebootBatchSize -TargetCount $rebootTargets.Count
            }

            $rebootActions = @(Invoke-GuestRebootPhase -RebootTargets $rebootTargets -GuestCredentialMap $GuestCredentialMap -VIServers $VIServers -VIServerScope $VIServerScope -VIServerCredentialMap $VIServerCredentialMap -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $GuestOpsLibPath -CurlPath $CurlPath -WorkspaceScriptPath $WorkspaceScriptPath -RunGuardScriptPath $RunGuardScriptPath -RebootRequestScriptPath $RebootRequestScriptPath -GuestWorkingDirectory $GuestWorkingDirectory -RebootTimeoutSeconds $RebootTimeoutSeconds -PollSeconds $PollSeconds -RebootBatchSize $resolvedRebootBatchSize -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive)
        }
        else {
            Write-Warning 'Guest reboot was not approved. Reboot phase skipped.'
            $rebootActions = @(New-SkippedRebootActionRecords -RebootTargets $rebootTargets)
        }

        Write-RebootActionArtifacts -CycleOutputDirectory $CycleOutputDirectory -RebootActions $rebootActions
    }

    $hasHardFailure = -not ((Test-ApplyResultsSuccessful -ApplyResults $applyResults) -and (Test-RebootActionsSuccessful -RebootActions $rebootActions))
    # Drift is reported separately from a hard failure. "Installed less than was approved" and
    # "an install failed" are different facts: folding them together would either hide the drift
    # or report a working install as broken, and only the first can still be resolved by a later
    # discovery showing the missing updates are no longer applicable.
    $requiresVerification = [bool](Test-ApplyResultsRequireVerification -ApplyResults $applyResults)
    $exitCode = if ($hasHardFailure) { 1 } else { 0 }
    foreach ($drift in @(Get-ApplyResultDriftSummary -ApplyResults $applyResults)) {
        Write-Warning ('{0}: approved update(s) were no longer offered by WUA and were not installed: {1}. They were NOT installed under another revision.' -f $drift.vmName, (@($drift.missingUpdateKeys) -join ', '))
    }

    # The round loop needs more than the exit code: it has to know whether a reboot happened
    # and whether every rebooted guest came back, because it may not run another discovery
    # against machines that are not provably up.
    return [pscustomobject]@{
        ExitCode = $exitCode
        HasHardFailure = $hasHardFailure
        RequiresVerification = $requiresVerification
        ApplyResults = @($applyResults)
        RebootTargets = @($rebootTargets)
        RebootActions = @($rebootActions)
        RebootRan = ($rebootTargets.Count -gt 0)
    }
}

function Resolve-GuestCredentialMap {
    param(
        [string[]]$TargetNames,
        [pscredential]$OverrideCredential,
        [scriptblock]$CredentialPromptScript
    )

    if ($null -eq $CredentialPromptScript) {
        $CredentialPromptScript = {
            param([string]$Message)
            Get-Credential -Message $Message
        }
    }

    $map = @{}

    if ($OverrideCredential) {
        foreach ($name in @($TargetNames)) {
            $map[$name] = $OverrideCredential
        }

        return $map
    }

    foreach ($group in @(Get-GuestCredentialGroups -TargetNames $TargetNames)) {
        if ($group.Kind -eq 'Domain') {
            $message = ('Domain administrator credentials for {0} ({1})' -f $group.Domain, (@($group.Members) -join ', '))
        }
        else {
            $message = ('Local administrator credentials for {0}' -f $group.Key)
        }

        $credential = & $CredentialPromptScript $message
        foreach ($member in @($group.Members)) {
            $map[$member] = $credential
        }
    }

    return $map
}

function Invoke-DiscoveryPhase {
    param(
        [string[]]$TargetVMNames,
        [object[]]$VIServerScope,
        $Managers,
        $GuestCredentialMap,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$IdentityHelperPath,
        [string]$WorkspaceScriptPath,
        [string]$RunGuardScriptPath,
        [string]$GuestWorkingDirectory,
        [int]$MaxUpdates,
        [int]$TimeoutSeconds,
        [int]$PollSeconds,
        [string]$CycleOutputDirectory,
        [int]$MaxInFlight = 1,
        [hashtable]$CredentialContext = $null,
        [scriptblock]$CredentialDecisionScript,
        [scriptblock]$CredentialValidatedScript,
        [bool]$CredentialInteractive = $false
    )

    $recordEntries = @()
    $fleetItems = @()
    $outputDirectoryBySequence = @{}
    $targetNumber = 0
    $previousSuppressStepMessages = $script:SuppressStepMessages
    $script:SuppressStepMessages = $true
    try {
    foreach ($targetVMName in @($TargetVMNames)) {
        $targetNumber++
        $vmOutputDirectory = Join-Path $CycleOutputDirectory ('{0:D3}-{1}' -f $targetNumber, (Get-SafeFileName -Value $targetVMName))
        $outputDirectoryBySequence[$targetNumber] = $vmOutputDirectory
        $fleetItems += New-AgentFleetItem -Sequence $targetNumber -VMName ([string]$targetVMName) -VMOutputDirectory $vmOutputDirectory -MaxUpdates $MaxUpdates -SearchOnly $true
    }

    if ($fleetItems.Count -gt 0) {
        Write-Host ('Discovery running with up to {0} VM(s) in flight.' -f $MaxInFlight)
        $fleetResults = @(Invoke-GuestAgentFleet -FleetItems $fleetItems -VIServerScope $VIServerScope -Managers $Managers -GuestCredentialMap $GuestCredentialMap -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -WorkspaceScriptPath $WorkspaceScriptPath -RunGuardScriptPath $RunGuardScriptPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -MaxInFlight $MaxInFlight -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive)

        $doneCount = 0
        foreach ($fleetResult in @($fleetResults | Sort-Object Sequence)) {
            $doneCount++
            # Write-Host, not Write-Step: the per-VM step messages are suppressed for the whole
            # phase, and a fleet of fifty guests must not run for a quarter of an hour in silence.
            Write-Host ('  {0}/{1} discovery finished: {2}' -f $doneCount, $fleetItems.Count, $fleetResult.VMName)

            $vmOutputDirectory = $outputDirectoryBySequence[[int]$fleetResult.Sequence]
            $hasError = -not [string]::IsNullOrWhiteSpace([string]$fleetResult.Error)
            $payload = Get-ObjectPropertyValue -InputObject $fleetResult -Path @('Payload')
            $resultKind = [string](Get-ObjectPropertyValue -InputObject $fleetResult -Path @('ResultKind'))

            if ($hasError -and $null -eq $payload) {
                Write-Warning ('Discovery failed for {0}: {1}' -f $fleetResult.VMName, $fleetResult.Error)
                $recordEntries += [pscustomobject]@{
                    Sequence = $fleetResult.Sequence
                    Record = New-DiscoveryRecord -VMName $fleetResult.VMName -Status $null -OutputDirectory $vmOutputDirectory -Errors @($fleetResult.Error)
                }
                continue
            }

            if ($hasError -and $resultKind -ne 'Timeout') {
                $failedRecord = New-DiscoveryRecordFromAgentRun -VMName $fleetResult.VMName -AgentRun $payload -OutputDirectory $vmOutputDirectory
                $failedRecord.outcome = 'DiscoveryFailed'
                $failedRecord.pendingRebootBefore = $null
                $failedRecord.errors = @($fleetResult.Error) + @($failedRecord.errors)
                $recordEntries += [pscustomobject]@{
                    Sequence = $fleetResult.Sequence
                    Record = $failedRecord
                }
                continue
            }

            if ($hasError) {
                # Only the explicitly typed timeout path may fall back to the downloaded status
                # and hand it to the normal record builder, which still requires the shared
                # completion verdict for this run as well as a successful discovery outcome.
                Write-Warning ('Discovery process result timed out for {0}; falling back to the downloaded status.json.' -f $fleetResult.VMName)
            }

            $recordEntries += [pscustomobject]@{
                Sequence = $fleetResult.Sequence
                Record = New-DiscoveryRecordFromAgentRun -VMName $fleetResult.VMName -AgentRun $payload -OutputDirectory $vmOutputDirectory
            }
        }
    }
    }
    finally {
        $script:SuppressStepMessages = $previousSuppressStepMessages
    }

    $records = @($recordEntries | Sort-Object Sequence | ForEach-Object { $_.Record })
    $discoveryPath = Join-Path $CycleOutputDirectory 'discovery.json'
    ConvertTo-Json -InputObject @($records) -Depth 12 | Set-Content -LiteralPath $discoveryPath -Encoding UTF8

    Write-Host ''
    Write-Host 'Discovery summary'
    Write-Host '-----------------'
    foreach ($record in @($records)) {
        $isSuccessful = Test-IsSuccessfulDiscoveryOutcome -Outcome ([string]$record.outcome)
        $hasErrors = (@($record.errors).Count -gt 0)
        $summaryStatus = Get-DiscoverySummaryStatus -IsSuccessful $isSuccessful -AvailableUpdateCount ([int]$record.availableUpdateCount) -HasErrors $hasErrors
        $summaryColor = switch ($summaryStatus) {
            'UpToDate' { 'Green' }
            'UpdatesFound' { 'Yellow' }
            default { 'Red' }
        }
        $pendingRebootBefore = Get-ObjectPropertyValue -InputObject $record -Path @('pendingRebootBefore', 'isPending')
        $rebootText = if ($null -eq $pendingRebootBefore) { '?' } elseif ([bool]$pendingRebootBefore) { 'yes' } else { 'no' }
        # Flags that were seen but deliberately do not gate the reboot prompt still belong on
        # screen. Dropping them entirely would replace one confusing prompt with a silent
        # omission, and this line is where an operator looks first.
        $advisoryReboot = @(Get-ObjectPropertyValue -InputObject $record -Path @('pendingRebootBefore', 'advisoryReasons') -DefaultValue @())
        if ($advisoryReboot.Count -gt 0) {
            $rebootText = '{0} (advisory: {1})' -f $rebootText, ($advisoryReboot -join ', ')
        }
        Write-Host ('{0}: outcome={1}; updates={2}; reboot={3}; roles={4}' -f $record.vmName, $record.outcome, $record.availableUpdateCount, $rebootText, (Get-RoleFlagText -RoleFlags $record.roleFlags)) -ForegroundColor $summaryColor
        Write-Host ''
    }

    return @($records)
}

if ($SearchOnly -and -not [string]::IsNullOrWhiteSpace($PatchPlanPath)) {
    throw 'SearchOnly cannot be combined with PatchPlanPath. Use PlanOnly to inspect a saved plan.'
}

$targetVMNames = @(Resolve-VMTargetNames -SingleVMName $VMName -ManyVMNames $VMNames -ListPath $VMListPath)
$resolvedVIServers = @(Split-VIServerInput -InputText $VIServer)
$hasExplicitSelectedUpdateKeys = $PSBoundParameters.ContainsKey('SelectedUpdateKeys')

# Default to every target in flight at once. Discovery and apply are in-process now, so
# concurrency costs GuestOps calls rather than one PowerShell host plus a PowerCLI import
# per VM. An explicit -ThrottleLimit still wins.
if (-not $PSBoundParameters.ContainsKey('ThrottleLimit')) {
    $ThrottleLimit = [math]::Max(1, $targetVMNames.Count)
}

# 0 means "ask the operator once a reboot is actually confirmed".
$resolvedRebootBatchSize = if ($PSBoundParameters.ContainsKey('RebootBatchSize')) { $RebootBatchSize } else { 0 }

if ($resolvedVIServers.Count -eq 0) {
    throw 'At least one vCenter is required. Use -VIServer with one or more names separated by semicolons.'
}

# Checked here rather than only at the deletion point, because failing there is silent: the run
# succeeds on every VM and every cycle directory is kept, on top of the ones cleanup legitimately
# keeps when a process result was lost. A path written with forward slashes works for every other
# part of the run, so nothing else would ever tell the operator.
$workingDirectoryVerdict = Test-GuestDirectoryCanonical -Path $GuestWorkingDirectory
if (-not $workingDirectoryVerdict.IsCanonical) {
    throw ('GuestWorkingDirectory "{0}" cannot be used: {1}' -f $GuestWorkingDirectory, $workingDirectoryVerdict.Reason)
}

if (-not [string]::IsNullOrWhiteSpace($InstallSelection)) {
    throw 'InstallSelection is not supported with grouped update selection. Use SelectedUpdateKeys instead.'
}

if ($hasExplicitSelectedUpdateKeys -and @($SelectedUpdateKeys).Count -eq 0) {
    throw 'SelectedUpdateKeys did not contain any non-empty update keys.'
}

. (Join-Path $PSScriptRoot 'PatchPlanModel.ps1')
. (Join-Path $PSScriptRoot 'OrchestratorRuntime.ps1')

$curlPath = Assert-LocalPrerequisites -LocalAgentPath $AgentPath

# All ESXi transfers, including boot-time reads, run in this script scope through Invoke-Curl.
# Reboot jobs use SOAP only. Assign on every run so a later strict run cannot inherit a bypass.
$script:GuestTransferIgnoreCertificate = [bool]$IgnoreESXiCertificate
if ($script:GuestTransferIgnoreCertificate) {
    Write-Warning 'ESXi certificate verification is disabled for this run (preflight and file transfers).'
}

Import-Module VMware.VimAutomation.Core -ErrorAction Stop

Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false | Out-Null

# PowerCLI defaults to a 300s web operation timeout. Boot-time reads run in this process and get
# at most a 120s budget, but that budget is only checked between GuestOps steps - so a single
# hung SOAP call would outlive the whole read and stall the reboot batch. Every call this tool
# makes is a short, server-side-filtered query, so 60s is generous for all of them.
Set-PowerCLIConfiguration -Scope Session -WebOperationTimeoutSeconds 60 -Confirm:$false | Out-Null

if ($IgnoreVCenterCertificate) {
    Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
}

$connections = @()
$scriptExitCode = 1
# PromptCredential is the one provider entry that does NOT go through Invoke-OperatorPrompt.
# It is handed straight to the credential seams, which have long called their prompt as
# & $script $message with a bare string, so its scriptblock takes param([string]$Message)
# and returns a pscredential - not the arguments hashtable SelectUpdateGroups receives.
$credentialPromptScript = $null
if ($null -ne $PromptProvider -and $PromptProvider.ContainsKey('PromptCredential')) {
    $credentialPromptScript = $PromptProvider['PromptCredential']
}
$guestCredentialDecisionScript = $null
$guestCredentialValidatedScript = $null
$guestCredentialInteractive = -not $SkipConfirmation
if ($null -ne $PromptProvider -and $PromptProvider.ContainsKey('CredentialValidated')) {
    $guestCredentialValidatedScript = $PromptProvider['CredentialValidated']
}
# The vCenter hooks are the same idea one layer down, and they are separate entries because a
# vCenter has no account group: a corrected password belongs to that one server.
$viserverRecoveryScript = $null
$viserverValidatedScript = $null
if ($null -ne $PromptProvider -and $PromptProvider.ContainsKey('VIServerCredentialValidated')) {
    $viserverValidatedScript = $PromptProvider['VIServerCredentialValidated']
}
if ($guestCredentialInteractive -and $null -ne $PromptProvider -and $PromptProvider.ContainsKey('RecoverVIServerCredential')) {
    $viserverRecoveryScript = $PromptProvider['RecoverVIServerCredential']
}
if ($guestCredentialInteractive) {
    if ($null -ne $PromptProvider -and $PromptProvider.ContainsKey('RecoverGuestCredential')) {
        $guestCredentialDecisionScript = $PromptProvider['RecoverGuestCredential']
    }
    else {
        $guestCredentialDecisionScript = {
            param($VMName, $AccountKey, $Members, $Reason)
            # Deliberately no explicit result keyword here - the resume-branch needle in
            # Assert-NoOrphanedBranchKeyword forbids one anywhere below it, even inside a
            # comment, and a scriptblock's last expression is its result anyway.
            Read-GuestCredentialRecoveryDecision -VMName $VMName -AccountKey $AccountKey -Members @($Members) -Reason $Reason
        }
    }
}

# The map is passed on WITHOUT copying. Connect-VIServersWithCredentialMap mutates it in
# place on a login retry, and the corrected credential is consumed later by the reboot jobs,
# which connect without -RetryOnFailure. A copy would leave apply working after a failed
# first login while every reboot initiation died.
if ($null -ne $StoredVIServerCredentials) {
    $viserverCredentialMap = $StoredVIServerCredentials
}
else {
    $viserverCredentialMap = Resolve-VIServerCredentialMap -VIServers $resolvedVIServers -OverrideCredential $VIServerCredential -CredentialPromptScript $credentialPromptScript
}

$retryVIServerLogin = ($null -eq $VIServerCredential -or $null -ne $StoredVIServerCredentials)

try {
    Write-Step -Message ('Connecting to vCenter(s) {0}.' -f ($resolvedVIServers -join ', '))
    # Only the sessions this run opened go into $connections: the finally block disconnects
    # them, and a session the operator already had (-KeepConnected from an earlier run) must
    # survive this one.
    $connectResult = Connect-VIServersWithCredentialMap -VIServers $resolvedVIServers -CredentialMap $viserverCredentialMap -CredentialPromptScript $credentialPromptScript -RetryOnFailure:$retryVIServerLogin -ReuseExisting -CredentialRecoveryScript $viserverRecoveryScript -CredentialValidatedScript $viserverValidatedScript
    $connections = @($connectResult.OpenedConnections)
    # Every inventory lookup in this run is scoped to these connections - Connections, not
    # OpenedConnections, because a reused session is just as much in scope as one we opened;
    # OpenedConnections only answers "what may this run tear down".
    $viServerScope = @($connectResult.Connections)
    if ($viServerScope.Count -eq 0) {
        throw 'No vCenter connection is available for this run.'
    }

    $managers = $null

    if (-not [string]::IsNullOrWhiteSpace($PatchPlanPath)) {
        if (-not (Test-Path -LiteralPath $PatchPlanPath -PathType Leaf)) {
            throw ('Patch plan file not found: {0}' -f $PatchPlanPath)
        }

        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $runOutputDirectory = New-UniqueOutputDirectory -BasePath (Join-Path $LocalOutputDirectory $timestamp)
        $patchPlanRecords = @(ConvertTo-PatchPlanRecords -InputObject (Get-Content -LiteralPath $PatchPlanPath -Raw | ConvertFrom-Json))
        Show-PatchPlan -PatchPlanRecords $patchPlanRecords

        if ($PlanOnly) {
            $scriptExitCode = Get-PlanOnlyExitCode -PatchPlanRecords $patchPlanRecords
        }
        elseif (-not (Confirm-PatchPlan -SkipConfirmation:$SkipConfirmation)) {
            Write-Warning 'Patch plan was not approved. Apply phase skipped.'
            $scriptExitCode = 1
        }
        else {
            if ($null -ne $StoredGuestCredentials) {
                $guestCredentialMap = $StoredGuestCredentials
            }
            else {
                $guestCredentialMap = Resolve-GuestCredentialMap -TargetNames @(@($patchPlanRecords) | ForEach-Object { [string]$_.vmName }) -OverrideCredential $GuestCredential -CredentialPromptScript $credentialPromptScript
            }
            $guestCredentialContext = New-GuestCredentialContext -TargetNames @(@($patchPlanRecords) | ForEach-Object { [string]$_.vmName }) -CredentialMap $guestCredentialMap
            # Resume stays a single round. There is no discovery to judge the starting state
            # from, the saved keys carry a RevisionNumber that will not match a later round's
            # groups, and resume is typically run non-interactively with -SkipConfirmation,
            # where a round-two group selection prompt would simply hang.
            $applyOutcome = Invoke-ApplyAndOptionalReboot -PatchPlanRecords $patchPlanRecords -Managers $managers -GuestCredentialMap $guestCredentialMap -VIServers $resolvedVIServers -VIServerScope $viServerScope -VIServerCredentialMap $viserverCredentialMap -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $guestOpsLibPath -CurlPath $curlPath -AgentPath $AgentPath -IdentityHelperPath $identityHelperPath -WorkspaceScriptPath $workspaceScriptPath -RunGuardScriptPath $runGuardScriptPath -RebootRequestScriptPath $rebootRequestScriptPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds ($TimeoutMinutes * 60) -RebootTimeoutSeconds ($RebootTimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $runOutputDirectory -ThrottleLimit $ThrottleLimit -RebootBatchSize $resolvedRebootBatchSize -CredentialContext $guestCredentialContext -CredentialDecisionScript $guestCredentialDecisionScript -CredentialValidatedScript $guestCredentialValidatedScript -CredentialInteractive $guestCredentialInteractive
            $scriptExitCode = $applyOutcome.ExitCode

            # Resume has no fresh discovery, so nothing here can establish that an approved
            # update WUA stopped offering is genuinely no longer needed. Drift therefore stays
            # an incomplete result: exit 1, with the missing keys named. A second install is
            # deliberately not attempted - that would need a fresh plan and a normal selection.
            if ([bool](Get-RuntimePropertyValue -InputObject $applyOutcome -Name 'RequiresVerification' -DefaultValue $false)) {
                foreach ($resumeDrift in @(Get-ApplyResultDriftSummary -ApplyResults @(Get-RuntimePropertyValue -InputObject $applyOutcome -Name 'ApplyResults' -DefaultValue @()))) {
                    Write-Warning ('{0}: approved update(s) were no longer offered by WUA and were not installed: {1}. A resume run cannot verify this; re-run discovery.' -f $resumeDrift.vmName, (@($resumeDrift.missingUpdateKeys) -join ', '))
                }
                $scriptExitCode = 1
            }
        }

        exit $scriptExitCode
    }

    if ($null -ne $StoredGuestCredentials) {
        $guestCredentialMap = $StoredGuestCredentials
    }
    else {
        $guestCredentialMap = Resolve-GuestCredentialMap -TargetNames $targetVMNames -OverrideCredential $GuestCredential -CredentialPromptScript $credentialPromptScript
    }
    $guestCredentialContext = New-GuestCredentialContext -TargetNames $targetVMNames -CredentialMap $guestCredentialMap

    # Connections, corrected credentials and credential refusal decisions belong to the session.
    # Everything from the output directory through the summary belongs to one fresh scan cycle.
    do {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $runOutputDirectory = New-UniqueOutputDirectory -BasePath (Join-Path $LocalOutputDirectory $timestamp)
        $scriptExitCode = 1
    $roundTargetVMNames = @($targetVMNames)
    $roundNumber = 0
    $roundSummaries = @()
    $finalStateMap = @{}
    $deselectedUpdateKeys = @()
    $stoppedByRoundCap = $false
    $sawApplyFailure = $false
    # vmName -> the approved keys WUA stopped offering. Deliberately NOT folded into
    # $sawApplyFailure, which is sticky: an approved update that has become inapplicable is
    # resolved by a later discovery, and the run may then finish successfully with the warning
    # retained in the artifacts.
    $outstandingVerificationByVm = @{}
    # Proven writable before the first agent start: a run that cannot be audited says so up front.
    $runEventLog = New-RunEventLogState -Path (Join-Path $runOutputDirectory 'events.jsonl')
    if (-not (Initialize-RunEventLog -State $runEventLog)) {
        Write-Warning ([string]$runEventLog.AuditError)
    }

    while ($true) {
        $roundNumber++
        # Create the round directory up front: nothing else does, and a round where every
        # fleet start throws would otherwise fail on writing discovery.json.
        $roundOutputDirectory = Join-Path $runOutputDirectory ('round-{0:D2}' -f $roundNumber)
        New-Item -ItemType Directory -Force -Path $roundOutputDirectory | Out-Null

        Write-Step -Message ('Patch round {0} over {1} VM(s).' -f $roundNumber, @($roundTargetVMNames).Count)
        Write-RunEvent -State $runEventLog -Event 'RoundStarted' -Phase 'Round' -Round $roundNumber -Detail ('{0} target(s)' -f @($roundTargetVMNames).Count)
        Write-RunEvent -State $runEventLog -Event 'PhaseStarted' -Phase 'Discovery' -Round $roundNumber
        $discoveryRecords = Invoke-DiscoveryPhase -TargetVMNames $roundTargetVMNames -VIServerScope $viServerScope -Managers $managers -GuestCredentialMap $guestCredentialMap -CurlPath $curlPath -AgentPath $AgentPath -IdentityHelperPath $identityHelperPath -WorkspaceScriptPath $workspaceScriptPath -RunGuardScriptPath $runGuardScriptPath -GuestWorkingDirectory $GuestWorkingDirectory -MaxUpdates $MaxUpdates -TimeoutSeconds ($DiscoveryTimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $roundOutputDirectory -MaxInFlight $ThrottleLimit -CredentialContext $guestCredentialContext -CredentialDecisionScript $guestCredentialDecisionScript -CredentialValidatedScript $guestCredentialValidatedScript -CredentialInteractive $guestCredentialInteractive
        $failedDiscoveryRecords = @($discoveryRecords | Where-Object { @($_.errors).Count -gt 0 })
        Write-RunEvent -State $runEventLog -Event 'PhaseFinished' -Phase 'Discovery' -Round $roundNumber -Detail ('{0} record(s), {1} failed' -f @($discoveryRecords).Count, $failedDiscoveryRecords.Count)
        foreach ($discoveryRecord in @($discoveryRecords)) {
            Write-RunEvent -State $runEventLog -Event 'VMDiscovered' -Phase 'Discovery' -Round $roundNumber `
                -VMName ([string](Get-RuntimePropertyValue -InputObject $discoveryRecord -Name 'vmName')) `
                -Outcome ([string](Get-RuntimePropertyValue -InputObject $discoveryRecord -Name 'outcome'))
        }

        # A fresh discovery is the only thing that can settle an approved update WUA stopped
        # offering: if the exact identity key is gone, that update is no longer applicable.
        Resolve-OutstandingVerificationKeys -Outstanding $outstandingVerificationByVm -DiscoveryRecords $discoveryRecords

        $updateGroups = @(New-UpdateGroupRecords -DiscoveryRecords $discoveryRecords | Sort-Object kbText,title)
        $completionStates = @(Get-VMPatchCompletionStates -DiscoveryRecords $discoveryRecords -UpdateGroups $updateGroups -DeselectedUpdateKeys $deselectedUpdateKeys)
        Merge-PatchRunStates -StateMap $finalStateMap -CompletionStates $completionStates

        $roundSummaries += [pscustomobject]@{
            round = $roundNumber
            outputDirectory = $roundOutputDirectory
            targetVMNames = @($roundTargetVMNames)
            discoveryFailureCount = $failedDiscoveryRecords.Count
        }

        if ($roundNumber -gt 1) {
            Write-PatchRoundVerification -CompletionStates $completionStates -Round $roundNumber
        }

        Show-UpdateGroups -UpdateGroups $updateGroups

        # -SearchOnly and -PlanOnly report on what they found and keep their existing exit
        # semantics; neither is subject to the all-green rule, or a dry run against a fleet
        # with pending updates would start failing.
        if ($SearchOnly -or $PlanOnly) {
            $scriptExitCode = if ($failedDiscoveryRecords.Count -gt 0) { 1 } else { 0 }

            if ($PlanOnly) {
                # -SearchOnly -PlanOnly is a pure dry run and selects nothing, matching the
                # old flow. -PlanOnly on its own still asks: the point of a dry-run plan is
                # to show what the operator's own selection would produce, and quietly
                # substituting the default policy would hide exactly what they came to see.
                $planAborted = $false
                if ($SearchOnly) {
                    $selectedKeysForPlan = @()
                }
                elseif ($hasExplicitSelectedUpdateKeys) {
                    $selectedKeysForPlan = Resolve-SelectedUpdateKeys -UpdateGroups $updateGroups -ExplicitSelectedUpdateKeys $SelectedUpdateKeys
                }
                elseif ($updateGroups.Count -gt 0) {
                    $planSelection = Read-UpdateGroupSelection -UpdateGroups $updateGroups -PromptProvider $PromptProvider
                    if ($planSelection.Aborted) {
                        Write-Warning 'Update group selection was cancelled; no patch plan was written.'
                        $scriptExitCode = 1
                        $planAborted = $true
                    }
                    else {
                        $selectedKeysForPlan = @($planSelection.Keys)
                    }
                }
                else {
                    $selectedKeysForPlan = @()
                }

                if (-not $planAborted) {
                    Write-Step -Message ('Selected update group key(s): {0}' -f @($selectedKeysForPlan).Count)

                    $patchPlanRecords = @(New-PatchPlanRecords -DiscoveryRecords $discoveryRecords -SelectedUpdateKeys $selectedKeysForPlan)
                    $patchPlanRecords = @(Update-PatchPlanWithDiscoveryFailures -PatchPlanRecords $patchPlanRecords -DiscoveryRecords $discoveryRecords)
                    $patchPlanPath = Join-Path $roundOutputDirectory 'patch-plan.json'
                    ConvertTo-Json -InputObject @($patchPlanRecords) -Depth 12 | Set-Content -LiteralPath $patchPlanPath -Encoding UTF8
                    Show-PatchPlan -PatchPlanRecords $patchPlanRecords
                    $scriptExitCode = Get-PlanOnlyExitCode -PatchPlanRecords $patchPlanRecords
                }
            }

            break
        }

        $roundDecision = Get-PatchRoundDecision -CompletionStates $completionStates -Round $roundNumber -MaxRounds $MaxPatchRounds -OperatorDecision $null -ExplicitSelectionOnly $hasExplicitSelectedUpdateKeys -NonInteractive ([bool]$SkipConfirmation)
        if ($roundDecision.NeedsOperatorDecision) {
            $roundDecision = Get-PatchRoundDecision -CompletionStates $completionStates -Round $roundNumber -MaxRounds $MaxPatchRounds -OperatorDecision (Read-ContinuePatchingDecision -CompletionStates $completionStates -Round ($roundNumber - 1)) -ExplicitSelectionOnly $hasExplicitSelectedUpdateKeys -NonInteractive ([bool]$SkipConfirmation)
        }

        if ($roundDecision.Action -ne 'Continue') {
            Write-Step -Message ([string]$roundDecision.Reason)
            if (@($roundDecision.PendingVMNames).Count -gt 0 -and $roundNumber -gt $MaxPatchRounds) {
                $stoppedByRoundCap = $true
            }
            break
        }

        # Only round one can get here with explicit keys; Get-PatchRoundDecision stops the
        # loop before round two rather than letting Resolve-SelectedUpdateKeys throw on
        # revisions that no longer exist.
        # Whether a human actually saw the group list this round. It decides what an unticked
        # box means: after an interactive selection it is a decision, otherwise it is only a
        # default nobody looked at - and for a group the policy could not classify those two are
        # very different answers.
        $operatorReviewedGroups = $false
        if ($hasExplicitSelectedUpdateKeys) {
            $selectedKeysForPlan = Resolve-SelectedUpdateKeys -UpdateGroups $updateGroups -ExplicitSelectedUpdateKeys $SelectedUpdateKeys
        }
        elseif ($updateGroups.Count -gt 0) {
            $roundSelection = Read-UpdateGroupSelection -UpdateGroups $updateGroups -PromptProvider $PromptProvider
            if ($roundSelection.Aborted) {
                Write-Warning 'Update group selection was cancelled. Apply phase skipped.'
                $sawApplyFailure = $true
                break
            }

            $selectedKeysForPlan = @($roundSelection.Keys)
            $operatorReviewedGroups = $true
        }
        else {
            $selectedKeysForPlan = @()
        }

        # Remember what the operator unticked. Without this the next round would rediscover
        # the same groups, call the VM pending again, and keep asking about updates that were
        # already refused.
        $selectedKeyLookup = @{}
        foreach ($selectedKey in @($selectedKeysForPlan)) {
            $selectedKeyLookup[[string]$selectedKey] = $true
        }
        foreach ($group in @($updateGroups)) {
            if ($selectedKeyLookup.ContainsKey([string]$group.identityKey)) {
                continue
            }

            if ([bool]$group.selectedByDefault) {
                $deselectedUpdateKeys += [string]$group.identityKey
                continue
            }

            # A group the policy could not classify only leaves NeedsReview once a human has
            # looked at the list and left it unticked. Recording it without that - from
            # -SelectedUpdateKeys or -SkipConfirmation, where nobody saw the marker - would be
            # inventing an operator decision, and the run stays incomplete instead.
            if ($operatorReviewedGroups -and [string](Get-RuntimePropertyValue -InputObject $group -Name 'policyDecision') -eq 'NeedsReview') {
                $deselectedUpdateKeys += [string]$group.identityKey
            }
        }

        Write-Step -Message ('Selected update group key(s): {0}' -f @($selectedKeysForPlan).Count)
        Write-RunEvent -State $runEventLog -Event 'SelectionResolved' -Phase 'Selection' -Round $roundNumber `
            -OperatorDecision $(if ($operatorReviewedGroups) { 'Interactive' } else { 'NonInteractive' }) `
            -Detail ('{0} group key(s) selected' -f @($selectedKeysForPlan).Count)

        $patchPlanRecords = @(New-PatchPlanRecords -DiscoveryRecords $discoveryRecords -SelectedUpdateKeys $selectedKeysForPlan)
        $patchPlanRecords = @(Update-PatchPlanWithDiscoveryFailures -PatchPlanRecords $patchPlanRecords -DiscoveryRecords $discoveryRecords)
        $patchPlanPath = Join-Path $roundOutputDirectory 'patch-plan.json'
        ConvertTo-Json -InputObject @($patchPlanRecords) -Depth 12 | Set-Content -LiteralPath $patchPlanPath -Encoding UTF8
        Show-PatchPlan -PatchPlanRecords $patchPlanRecords

        if (-not (Confirm-PatchPlan -SkipConfirmation:$SkipConfirmation)) {
            Write-Warning 'Patch plan was not approved. Apply phase skipped.'
            $sawApplyFailure = $true
            break
        }

        # VMs with no selected updates do not enter the next discovery. Record the
        # approved operator choice now so their pre-selection Pending state cannot linger.
        $completionStates = @(Get-VMPatchCompletionStates -DiscoveryRecords $discoveryRecords -UpdateGroups $updateGroups -DeselectedUpdateKeys $deselectedUpdateKeys)
        Merge-PatchRunStates -StateMap $finalStateMap -CompletionStates $completionStates

        $applyOutcome = Invoke-ApplyAndOptionalReboot -PatchPlanRecords $patchPlanRecords -Managers $managers -GuestCredentialMap $guestCredentialMap -VIServers $resolvedVIServers -VIServerScope $viServerScope -VIServerCredentialMap $viserverCredentialMap -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $guestOpsLibPath -CurlPath $curlPath -AgentPath $AgentPath -IdentityHelperPath $identityHelperPath -WorkspaceScriptPath $workspaceScriptPath -RunGuardScriptPath $runGuardScriptPath -RebootRequestScriptPath $rebootRequestScriptPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds ($TimeoutMinutes * 60) -RebootTimeoutSeconds ($RebootTimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $roundOutputDirectory -ThrottleLimit $ThrottleLimit -RebootBatchSize $resolvedRebootBatchSize -DiscoveryRecords $discoveryRecords -CredentialContext $guestCredentialContext -CredentialDecisionScript $guestCredentialDecisionScript -CredentialValidatedScript $guestCredentialValidatedScript -CredentialInteractive $guestCredentialInteractive
        # Only a hard failure is sticky. Drift becomes an outstanding verification instead, which
        # a later round's discovery can resolve.
        if ([bool](Get-RuntimePropertyValue -InputObject $applyOutcome -Name 'HasHardFailure' -DefaultValue ($applyOutcome.ExitCode -ne 0))) {
            $sawApplyFailure = $true
        }
        # A missing terminal agent record is a failed VM, not a reason to let it disappear
        # from the final state when the next round is selected from apply results.
        $applyResults = @(Get-RuntimePropertyValue -InputObject $applyOutcome -Name 'ApplyResults' -DefaultValue @())
        Add-OutstandingVerificationKeys -Outstanding $outstandingVerificationByVm -ApplyResults $applyResults
        foreach ($applyEventResult in $applyResults) {
            $applyEventVmName = [string](Get-RuntimePropertyValue -InputObject $applyEventResult -Name 'vmName')
            Write-RunEvent -State $runEventLog -Event 'VMApplied' -Phase 'Apply' -Round $roundNumber -VMName $applyEventVmName `
                -Outcome ([string](Get-RuntimePropertyValue -InputObject $applyEventResult -Name 'outcome'))
            if ([bool](Get-RuntimePropertyValue -InputObject $applyEventResult -Name 'guestRunConflict' -DefaultValue $false)) {
                # The kind, not just the fact: a run that ends 1 because two guests were restarting
                # is a different conversation from one that ends 1 because two guests need a hand.
                Write-RunEvent -State $runEventLog -Event 'GuestRunConflict' -Phase 'Apply' -Round $roundNumber -VMName $applyEventVmName -ErrorKind 'GuestRunConflict' `
                    -Detail ([string](Get-RuntimePropertyValue -InputObject $applyEventResult -Name 'guestRunConflictKind' -DefaultValue ''))
            }
            if ([bool](Get-RuntimePropertyValue -InputObject $applyEventResult -Name 'selectionDrift' -DefaultValue $false)) {
                Write-RunEvent -State $runEventLog -Event 'SelectionDrift' -Phase 'Apply' -Round $roundNumber -VMName $applyEventVmName `
                    -Detail ((@(Get-RuntimePropertyValue -InputObject $applyEventResult -Name 'missingUpdateKeys' -DefaultValue @()) -join ', '))
            }
        }
        foreach ($rebootEventAction in @(Get-RuntimePropertyValue -InputObject $applyOutcome -Name 'RebootActions' -DefaultValue @())) {
            Write-RunEvent -State $runEventLog -Event 'VMRebootAction' -Phase 'Reboot' -Round $roundNumber `
                -VMName ([string](Get-RuntimePropertyValue -InputObject $rebootEventAction -Name 'vmName')) `
                -Outcome ([string](Get-RuntimePropertyValue -InputObject $rebootEventAction -Name 'action')) `
                -OperatorDecision ([string](Get-RuntimePropertyValue -InputObject $rebootEventAction -Name 'operatorDecision')) `
                -Detail ([string](Get-RuntimePropertyValue -InputObject $rebootEventAction -Name 'validationStatus'))
        }
        foreach ($applyResult in $applyResults) {
            if ((Get-RuntimePropertyValue -InputObject $applyResult -Name 'action') -ne 'Install' -or
                [bool](Get-RuntimePropertyValue -InputObject $applyResult -Name 'agentCompletionConfirmed' -DefaultValue $false)) {
                continue
            }

            $failedVmName = [string](Get-RuntimePropertyValue -InputObject $applyResult -Name 'vmName')
            if ([string]::IsNullOrWhiteSpace($failedVmName)) {
                continue
            }

            $completionReason = [string](Get-RuntimePropertyValue -InputObject $applyResult -Name 'agentCompletionReason' -DefaultValue '')
            $failureReason = 'Agent completion was not confirmed before reboot or the next patch round.'
            if (-not [string]::IsNullOrWhiteSpace($completionReason)) {
                $failureReason = '{0} {1}' -f $failureReason, $completionReason
            }
            $finalStateMap[$failedVmName] = [pscustomobject]@{
                vmName = $failedVmName
                state = 'Failed'
                reason = $failureReason
                outcome = Get-RuntimePropertyValue -InputObject $applyResult -Name 'outcome'
                pendingSelectableCount = 0
                deselectedSelectableCount = 0
                errors = @(Get-RuntimePropertyValue -InputObject $applyResult -Name 'errors' -DefaultValue @())
            }
        }

        # A VM that needs a restart is not finished, whatever this round's pre-apply discovery
        # said about its update list: that discovery describes the machine BEFORE the reboot.
        # PendingReboot holds until a fresh discovery decides, and a refused or unverified
        # restart leaves it there - which is exit 1 without claiming the install failed.
        Set-PatchRunPendingRebootStates -StateMap $finalStateMap -RebootTargets @(Get-RuntimePropertyValue -InputObject $applyOutcome -Name 'RebootTargets' -DefaultValue @()) -RebootActions $applyOutcome.RebootActions
        # After the reboot states, because a refused guest is never a reboot target: the two
        # cannot both claim the same VM, and this one is the more specific answer.
        Set-PatchRunRefusedStates -StateMap $finalStateMap -ApplyResults @(Get-RuntimePropertyValue -InputObject $applyOutcome -Name 'ApplyResults' -DefaultValue @())

        # A machine that was told to restart and has not provably come back must not be
        # re-discovered: the read would either fail or describe a half-booted guest.
        if ($applyOutcome.RebootRan -and -not (Test-RebootActionsAllConfirmed -RebootActions $applyOutcome.RebootActions)) {
            Write-Warning 'Not every rebooted VM confirmed a new boot time; stopping before the verification round.'
            break
        }

        # Both reasons to look again, deduplicated. Apply alone would lose the machine that had
        # nothing to install but a pending reboot: it restarts and is never re-discovered, so the
        # verdict from before the restart would stand.
        $nextTargets = @(Get-NextRoundTargetVMNames -ApplyResults $applyResults -RebootActions $applyOutcome.RebootActions)
        if ($nextTargets.Count -eq 0) {
            Write-Step -Message 'No VM was patched in this round; nothing left to verify.'
            break
        }

        $roundTargetVMNames = $nextTargets
    }

    if (-not ($SearchOnly -or $PlanOnly)) {
        foreach ($finalVmName in @($finalStateMap.Keys | Sort-Object)) {
            Write-RunEvent -State $runEventLog -Event 'VMFinalState' -Phase 'Finalization' -VMName ([string]$finalVmName) `
                -Outcome ([string]$finalStateMap[$finalVmName].state)
        }
        Write-PatchRunSummary -RunOutputDirectory $runOutputDirectory -RoundSummaries $roundSummaries -FinalStateMap $finalStateMap -OutstandingVerificationByVm $outstandingVerificationByVm -AuditError ([string]$runEventLog.AuditError)
        # A VM whose discovery failed is already 'Failed' in the state map, so the all-green
        # test covers discovery failures too - no separate check needed.
        $scriptExitCode = 0
        if ($sawApplyFailure -or $stoppedByRoundCap -or -not (Test-PatchRunAllGreen -StateMap $finalStateMap -ExpectedVMNames $targetVMNames)) {
            $scriptExitCode = 1
        }

        # An approved update this run could not install, which no later discovery has shown to be
        # inapplicable. The fleet may be green and every install may have worked; the run still
        # installed less than was approved and says so rather than reporting a clean success.
        if ($outstandingVerificationByVm.Count -gt 0) {
            Write-Warning ('Approved update(s) were not installed and have not been verified as inapplicable: {0}' -f (Get-OutstandingVerificationText -Outstanding $outstandingVerificationByVm))
            $scriptExitCode = 1
        }

        # A run nobody can audit is not a successful run, but the failure is recorded only after
        # the results have been collected: abandoning guests mid-install to protect a log file
        # would be the wrong trade.
        if (-not [string]::IsNullOrWhiteSpace([string]$runEventLog.AuditError)) {
            Write-Warning ([string]$runEventLog.AuditError)
            $scriptExitCode = 1
        }

        Write-RunEvent -State $runEventLog -Event 'RunFinished' -Phase 'Finalization' -Outcome ([string]$scriptExitCode)
    }
    # Saved plans exit above. Explicit keys, dry runs and unattended runs must not acquire a
    # new interactive prompt or silently reuse update revisions in another scan cycle.
    } while (-not ($SearchOnly -or $PlanOnly -or $SkipConfirmation -or $hasExplicitSelectedUpdateKeys) -and (Read-RescanDecision))
}
catch {
    # Keep the origin. The message alone is reported against the launcher's call operator,
    # which locates a failure no better than "somewhere in the run" and turns a one-line bug
    # into a bisection.
    $failureOrigin = ''
    if ($null -ne $_.InvocationInfo -and -not [string]::IsNullOrWhiteSpace([string]$_.InvocationInfo.ScriptName)) {
        $failureOrigin = ' [{0}:{1}]' -f (Split-Path -Leaf ([string]$_.InvocationInfo.ScriptName)), $_.InvocationInfo.ScriptLineNumber
    }
    # -ErrorAction Continue is load-bearing and survives the added origin: under the script's
    # 'Stop' preference a bare Write-Error re-throws, and the run would leave without reaching
    # the exit code below. Behaviour check N2 in tests/Invoke-AuditFollowupChecks.ps1 runs this
    # catch body for exactly that reason.
    Write-Error ('{0}{1}' -f $_.Exception.Message, $failureOrigin) -ErrorAction Continue
    $scriptExitCode = 1
}
finally {
    if ($connections.Count -gt 0 -and -not $KeepConnected) {
        Disconnect-VIServer -Server $connections -Confirm:$false | Out-Null
    }
}

exit $scriptExitCode

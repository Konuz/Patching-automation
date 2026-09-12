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

    [int]$TimeoutMinutes = 180,

    [ValidateRange(1, 2147483647)]
    [int]$RebootTimeoutMinutes = 30,

    [ValidateRange(1, 2147483647)]
    [int]$PollSeconds = 15,

    [switch]$IgnoreVCenterCertificate,

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
        [pscredential]$Credential
    )

    try {
        $vm = Get-ExactVM -Name $VMName
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
            return Test-GuestCredentialForTarget -VMName $TargetName -Credential $Credential
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
        $Managers,
        $GuestCredentialMap,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$IdentityHelperPath,
        [string]$GuestWorkingDirectory,
        [int]$TimeoutSeconds,
        [int]$PollSeconds,
        [int]$MaxInFlight,
        [hashtable]$CredentialContext = $null,
        [scriptblock]$CredentialDecisionScript,
        [scriptblock]$CredentialValidatedScript,
        [bool]$CredentialInteractive = $false
    )

    $credentialRecoveryEnabled = ($null -ne $CredentialContext)
    return @(Invoke-InProcessAgentFleet -Items $FleetItems -MaxInFlight $MaxInFlight -PollSeconds $PollSeconds -ItemTimeoutSeconds ($TimeoutSeconds + 300) `
        -StartScript {
            param($Item)
            if (-not $credentialRecoveryEnabled) {
                $itemAuth = New-GuestAuthentication -Credential $GuestCredentialMap[[string]$Item.VMName]
                return Start-VMAgentCycle -VMName $Item.VMName -Managers $null -GuestAuth $itemAuth -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -VMOutputDirectory $Item.VMOutputDirectory -MaxUpdates $Item.MaxUpdates -LocalSelectionPath $Item.LocalSelectionPath -SearchOnly:([bool]$Item.SearchOnly)
            }

            return Invoke-GuestOperationWithCredentialRecovery -VMName $Item.VMName -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive -OperationScript {
                param($ItemAuth)
                return Start-VMAgentCycle -VMName $Item.VMName -Managers $null -GuestAuth $ItemAuth -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -VMOutputDirectory $Item.VMOutputDirectory -MaxUpdates $Item.MaxUpdates -LocalSelectionPath $Item.LocalSelectionPath -SearchOnly:([bool]$Item.SearchOnly)
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

            return Invoke-GuestOperationWithCredentialRecovery -VMName $Handle.VMName -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive -Handle $Handle -OperationScript {
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

            return Invoke-GuestOperationWithCredentialRecovery -VMName $Handle.VMName -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive -Handle $Handle -OperationScript {
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
            $connections = @((Connect-VIServersWithCredentialMap -VIServers @($JobInput.VIServers) -CredentialMap $JobInput.VIServerCredentialMap).OpenedConnections)
            $managers = $null
            $guestAuth = New-GuestAuthentication -Credential $JobInput.GuestCredential
            $rebootAttempted = $true
            $rebootResult = Invoke-VMGuestReboot -VMName $JobInput.VMName -Managers $managers -GuestAuth $guestAuth

            return [pscustomobject]@{
                Sequence = $JobInput.Sequence
                VMName = $JobInput.VMName
                RebootReason = $JobInput.RebootReason
                ProcessId = $rebootResult.ProcessId
                Error = $null
                ErrorKind = $null
                RejectedBeforeStart = $false
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
            return [pscustomobject]@{
                Sequence = $JobInput.Sequence
                VMName = $JobInput.VMName
                RebootReason = $JobInput.RebootReason
                ProcessId = $null
                Error = $_.Exception.Message
                ErrorKind = $rebootErrorKind
                RejectedBeforeStart = $rebootRejectedBeforeStart
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
        Write-Host ('[{0}] {1}. {2} - {3}' -f $mark, $index, $kbText, $group.title)
        Write-Host ('    Applies to: {0} VM; Patchable: {1} VM' -f $group.appliesToVmCount, $group.patchableVmCount)
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
        [string[]]$Errors = @()
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
        errors = @($Errors)
    }
}

function New-DiscoveryRecordFromAgentRun {
    param(
        [string]$VMName,
        $AgentRun,
        [string]$OutputDirectory
    )

    $record = New-DiscoveryRecord -VMName $VMName -Status $AgentRun.Status -OutputDirectory $OutputDirectory
    $recordErrors = @($record.errors)

    if (-not (Test-IsSuccessfulDiscoveryOutcome -Outcome $record.outcome)) {
        $recordErrors += ('Discovery returned outcome {0}.' -f $record.outcome)
    }

    if ($null -eq $AgentRun.AgentResult -or -not $AgentRun.AgentResult.Completed) {
        $finishedAt = Get-ObjectPropertyValue -InputObject $AgentRun.Status -Path @('finishedAt')
        if ((Test-IsSuccessfulDiscoveryOutcome -Outcome $record.outcome) -and -not [string]::IsNullOrWhiteSpace([string]$finishedAt)) {
            Write-Warning ('Discovery guest process result timed out for {0}. status.json has a successful discovery outcome and finishedAt, so the JSON artifact remains the primary discovery result.' -f $VMName)
        }
        else {
            $recordErrors += 'Discovery guest process result timed out and status.json did not contain both a successful discovery outcome and finishedAt.'
        }
    }

    $record.errors = @($recordErrors)
    return $record
}

function Invoke-ApplyPhase {
    param(
        $PatchPlanRecords,
        $Managers,
        $GuestCredentialMap,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$IdentityHelperPath,
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
            $resultEntries += [pscustomobject]@{
                Sequence = $recordNumber
                Result = [pscustomobject]@{
                    vmName = $record.vmName
                    action = $record.action
                    outcome = 'Skipped'
                    installResult = $null
                    reason = $record.reason
                    roleFlags = Get-ObjectPropertyValue -InputObject $record -Path @('roleFlags')
                    rebootRequired = $false
                    agentCompletionConfirmed = $false
                    agentCompletionReason = ''
                    errors = @()
                }
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
                Result = [pscustomobject]@{
                    vmName = $record.vmName
                    action = 'Install'
                    outcome = 'Failed'
                    installResult = $null
                    reason = $reason
                    rebootRequired = $false
                    agentCompletionConfirmed = $false
                    agentCompletionReason = 'No agent cycle was started.'
                    errors = @($reason)
                }
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
        $fleetResults = @(Invoke-GuestAgentFleet -FleetItems $fleetItems -Managers $Managers -GuestCredentialMap $GuestCredentialMap -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -MaxInFlight $MaxInFlight -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive)

        $doneCount = 0
        foreach ($fleetResult in @($fleetResults | Sort-Object Sequence)) {
            $doneCount++
            Write-Step -Message ('  {0}/{1} apply finished: {2}' -f $doneCount, $fleetItems.Count, $fleetResult.VMName)

            $hasError = -not [string]::IsNullOrWhiteSpace([string]$fleetResult.Error)
            $payload = Get-ObjectPropertyValue -InputObject $fleetResult -Path @('Payload')
            $resultKind = [string](Get-ObjectPropertyValue -InputObject $fleetResult -Path @('ResultKind'))

            if ($hasError -and $null -eq $payload) {
                $resultEntries += [pscustomobject]@{
                    Sequence = $fleetResult.Sequence
                    Result = [pscustomobject]@{
                        vmName = $fleetResult.VMName
                        action = 'Install'
                        outcome = 'Failed'
                        installResult = $null
                        reason = $fleetResult.Error
                        rebootRequired = $false
                        agentCompletionConfirmed = $false
                        agentCompletionReason = 'Agent cycle did not return a completion record.'
                        errors = @($fleetResult.Error)
                    }
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
        [hashtable]$VIServerCredentialMap,
        [switch]$IgnoreVCenterCertificate,
        [string]$GuestOpsLibPath,
        [string]$CurlPath,
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
                    $bootTime = Invoke-GuestOperationWithCredentialRecovery -VMName $vmName -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive -OperationScript {
                        param($ReadAuth)
                        return Invoke-VMGuestBootTimeRead -VMName $vmName -Managers $null -GuestAuth $ReadAuth -CurlPath $CurlPath -GuestWorkingDirectory $GuestWorkingDirectory -BootTimeHelperPath $BootTimeHelperPath -TimeoutSeconds $timeoutSeconds -PollSeconds $PollSeconds -SkipHelperUpload:([bool]$helperUploadedByVm[$vmName])
                    }
                }
                else {
                    $guestAuth = New-GuestAuthentication -Credential $GuestCredentialMap[$vmName]
                    $bootTime = Invoke-VMGuestBootTimeRead -VMName $vmName -Managers $null -GuestAuth $guestAuth -CurlPath $CurlPath -GuestWorkingDirectory $GuestWorkingDirectory -BootTimeHelperPath $BootTimeHelperPath -TimeoutSeconds $timeoutSeconds -PollSeconds $PollSeconds -SkipHelperUpload:([bool]$helperUploadedByVm[$vmName])
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
        foreach ($item in @($SubmitItems)) {
            $submitName = [string]$item.VMName
            $submitCredential = if ($null -ne $CredentialOverrides -and $CredentialOverrides.ContainsKey($submitName)) { $CredentialOverrides[$submitName] } else { $GuestCredentialMap[$submitName] }
            $jobInputs += [pscustomobject]@{
                Sequence = $item.Sequence
                VMName = $item.VMName
                RebootReason = $item.RebootReason
                VIServers = @($VIServers)
                VIServerCredentialMap = $VIServerCredentialMap
                GuestCredential = $submitCredential
                IgnoreVCenterCertificate = [bool]$IgnoreVCenterCertificate
                GuestOpsLibPath = $GuestOpsLibPath
            }
        }
        return @(Invoke-ThrottledJobs -Items $jobInputs -ThrottleLimit $RebootBatchSize -JobTimeoutSeconds 300 -ScriptBlock $restartJobScript)
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
                return Test-GuestCredentialForTarget -VMName $TargetName -Credential $Credential
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
    $rebootRequired = if ($null -eq $RebootTargets) { @(Select-RebootRequiredApplyResults -ApplyResults $ApplyResults) } else { @($RebootTargets) }
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
        [hashtable]$VIServerCredentialMap,
        [switch]$IgnoreVCenterCertificate,
        [string]$GuestOpsLibPath,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$IdentityHelperPath,
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

    $applyResults = @(Invoke-ApplyPhase -PatchPlanRecords $PatchPlanRecords -Managers $Managers -GuestCredentialMap $GuestCredentialMap -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -CycleOutputDirectory $CycleOutputDirectory -MaxInFlight $ThrottleLimit -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive)
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

            $rebootActions = @(Invoke-GuestRebootPhase -RebootTargets $rebootTargets -GuestCredentialMap $GuestCredentialMap -VIServers $VIServers -VIServerCredentialMap $VIServerCredentialMap -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $GuestOpsLibPath -CurlPath $CurlPath -GuestWorkingDirectory $GuestWorkingDirectory -RebootTimeoutSeconds $RebootTimeoutSeconds -PollSeconds $PollSeconds -RebootBatchSize $resolvedRebootBatchSize -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive)
        }
        else {
            Write-Warning 'Guest reboot was not approved. Reboot phase skipped.'
            $rebootActions = @(New-SkippedRebootActionRecords -RebootTargets $rebootTargets)
        }

        Write-RebootActionArtifacts -CycleOutputDirectory $CycleOutputDirectory -RebootActions $rebootActions
    }

    $exitCode = 1
    if ((Test-ApplyResultsSuccessful -ApplyResults $applyResults) -and (Test-RebootActionsSuccessful -RebootActions $rebootActions)) {
        $exitCode = 0
    }

    # The round loop needs more than the exit code: it has to know whether a reboot happened
    # and whether every rebooted guest came back, because it may not run another discovery
    # against machines that are not provably up.
    return [pscustomobject]@{
        ExitCode = $exitCode
        ApplyResults = @($applyResults)
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
        $Managers,
        $GuestCredentialMap,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$IdentityHelperPath,
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
        $fleetResults = @(Invoke-GuestAgentFleet -FleetItems $fleetItems -Managers $Managers -GuestCredentialMap $GuestCredentialMap -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -MaxInFlight $MaxInFlight -CredentialContext $CredentialContext -CredentialDecisionScript $CredentialDecisionScript -CredentialValidatedScript $CredentialValidatedScript -CredentialInteractive $CredentialInteractive)

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
                # and hand it to the normal record
                # builder, which decides on the outcome plus finishedAt in status.json.
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
# succeeds on every VM and the cycle directories simply accumulate, which is the symptom the
# cleanup exists to remove. A path written with forward slashes works for every other part of
# the run, so nothing else would ever tell the operator.
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
            $applyOutcome = Invoke-ApplyAndOptionalReboot -PatchPlanRecords $patchPlanRecords -Managers $managers -GuestCredentialMap $guestCredentialMap -VIServers $resolvedVIServers -VIServerCredentialMap $viserverCredentialMap -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $guestOpsLibPath -CurlPath $curlPath -AgentPath $AgentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds ($TimeoutMinutes * 60) -RebootTimeoutSeconds ($RebootTimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $runOutputDirectory -ThrottleLimit $ThrottleLimit -RebootBatchSize $resolvedRebootBatchSize -CredentialContext $guestCredentialContext -CredentialDecisionScript $guestCredentialDecisionScript -CredentialValidatedScript $guestCredentialValidatedScript -CredentialInteractive $guestCredentialInteractive
            $scriptExitCode = $applyOutcome.ExitCode
        }

        exit $scriptExitCode
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $runOutputDirectory = New-UniqueOutputDirectory -BasePath (Join-Path $LocalOutputDirectory $timestamp)

    if ($null -ne $StoredGuestCredentials) {
        $guestCredentialMap = $StoredGuestCredentials
    }
    else {
        $guestCredentialMap = Resolve-GuestCredentialMap -TargetNames $targetVMNames -OverrideCredential $GuestCredential -CredentialPromptScript $credentialPromptScript
    }
    $guestCredentialContext = New-GuestCredentialContext -TargetNames $targetVMNames -CredentialMap $guestCredentialMap

    $roundTargetVMNames = @($targetVMNames)
    $roundNumber = 0
    $roundSummaries = @()
    $finalStateMap = @{}
    $deselectedUpdateKeys = @()
    $stoppedByRoundCap = $false
    $sawApplyFailure = $false

    while ($true) {
        $roundNumber++
        # Create the round directory up front: nothing else does, and a round where every
        # fleet start throws would otherwise fail on writing discovery.json.
        $roundOutputDirectory = Join-Path $runOutputDirectory ('round-{0:D2}' -f $roundNumber)
        New-Item -ItemType Directory -Force -Path $roundOutputDirectory | Out-Null

        Write-Step -Message ('Patch round {0} over {1} VM(s).' -f $roundNumber, @($roundTargetVMNames).Count)
        $discoveryRecords = Invoke-DiscoveryPhase -TargetVMNames $roundTargetVMNames -Managers $managers -GuestCredentialMap $guestCredentialMap -CurlPath $curlPath -AgentPath $AgentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -MaxUpdates $MaxUpdates -TimeoutSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $roundOutputDirectory -MaxInFlight $ThrottleLimit -CredentialContext $guestCredentialContext -CredentialDecisionScript $guestCredentialDecisionScript -CredentialValidatedScript $guestCredentialValidatedScript -CredentialInteractive $guestCredentialInteractive
        $failedDiscoveryRecords = @($discoveryRecords | Where-Object { @($_.errors).Count -gt 0 })

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
            if ([bool]$group.selectedByDefault -and -not $selectedKeyLookup.ContainsKey([string]$group.identityKey)) {
                $deselectedUpdateKeys += [string]$group.identityKey
            }
        }

        Write-Step -Message ('Selected update group key(s): {0}' -f @($selectedKeysForPlan).Count)

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

        $applyOutcome = Invoke-ApplyAndOptionalReboot -PatchPlanRecords $patchPlanRecords -Managers $managers -GuestCredentialMap $guestCredentialMap -VIServers $resolvedVIServers -VIServerCredentialMap $viserverCredentialMap -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $guestOpsLibPath -CurlPath $curlPath -AgentPath $AgentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds ($TimeoutMinutes * 60) -RebootTimeoutSeconds ($RebootTimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $roundOutputDirectory -ThrottleLimit $ThrottleLimit -RebootBatchSize $resolvedRebootBatchSize -DiscoveryRecords $discoveryRecords -CredentialContext $guestCredentialContext -CredentialDecisionScript $guestCredentialDecisionScript -CredentialValidatedScript $guestCredentialValidatedScript -CredentialInteractive $guestCredentialInteractive
        if ($applyOutcome.ExitCode -ne 0) {
            $sawApplyFailure = $true
        }

        # A missing terminal agent record is a failed VM, not a reason to let it disappear
        # from the final state when the next round is selected from apply results.
        $applyResults = @(Get-RuntimePropertyValue -InputObject $applyOutcome -Name 'ApplyResults' -DefaultValue @())
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

        # A machine that was told to restart and has not provably come back must not be
        # re-discovered: the read would either fail or describe a half-booted guest.
        if ($applyOutcome.RebootRan -and -not (Test-RebootActionsAllConfirmed -RebootActions $applyOutcome.RebootActions)) {
            Write-Warning 'Not every rebooted VM confirmed a new boot time; stopping before the verification round.'
            break
        }

        $nextTargets = @($applyResults | Where-Object {
                (Get-RuntimePropertyValue -InputObject $_ -Name 'action') -eq 'Install' -and
                [bool](Get-RuntimePropertyValue -InputObject $_ -Name 'agentCompletionConfirmed' -DefaultValue $false)
            } | ForEach-Object { [string](Get-RuntimePropertyValue -InputObject $_ -Name 'vmName') })
        if ($nextTargets.Count -eq 0) {
            Write-Step -Message 'No VM was patched in this round; nothing left to verify.'
            break
        }

        $roundTargetVMNames = $nextTargets
    }

    if (-not ($SearchOnly -or $PlanOnly)) {
        Write-PatchRunSummary -RunOutputDirectory $runOutputDirectory -RoundSummaries $roundSummaries -FinalStateMap $finalStateMap
        # A VM whose discovery failed is already 'Failed' in the state map, so the all-green
        # test covers discovery failures too - no separate check needed.
        $scriptExitCode = 0
        if ($sawApplyFailure -or $stoppedByRoundCap -or -not (Test-PatchRunAllGreen -StateMap $finalStateMap)) {
            $scriptExitCode = 1
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    $scriptExitCode = 1
}
finally {
    if ($connections.Count -gt 0 -and -not $KeepConnected) {
        Disconnect-VIServer -Server $connections -Confirm:$false | Out-Null
    }
}

exit $scriptExitCode

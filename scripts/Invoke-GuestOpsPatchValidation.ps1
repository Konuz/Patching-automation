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

    [switch]$SearchOnly,

    [switch]$PlanOnly,

    [switch]$SkipConfirmation,

    [int]$TimeoutMinutes = 180,

    [ValidateRange(1, 2147483647)]
    [int]$RebootTimeoutMinutes = 30,

    [ValidateRange(1, 2147483647)]
    [int]$PollSeconds = 15,

    [switch]$IgnoreVCenterCertificate,

    [switch]$KeepConnected
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$guestOpsLibPath = Join-Path $PSScriptRoot 'GuestOpsLib.ps1'
. $guestOpsLibPath

. (Join-Path $PSScriptRoot 'VMTargetLib.ps1')

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

    $powerCliModule = Get-Module -ListAvailable -Name VMware.PowerCLI
    if ($null -eq $powerCliModule) {
        throw 'VMware.PowerCLI module was not found.'
    }

    return $curlCommand.Source
}

function New-AgentFleetItem {
    param(
        [int]$Sequence,
        [string]$VMName,
        [string]$VMOutputDirectory,
        [int]$MaxUpdates,
        [string]$LocalSelectionPath = '',
        [string]$GuestSelectionPath = '',
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
        GuestSelectionPath = $GuestSelectionPath
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
        [int]$MaxInFlight
    )

    return @(Invoke-InProcessAgentFleet -Items $FleetItems -MaxInFlight $MaxInFlight -PollSeconds $PollSeconds -ItemTimeoutSeconds ($TimeoutSeconds + 300) `
        -StartScript {
            param($Item)
            $itemAuth = New-GuestAuthentication -Credential $GuestCredentialMap[[string]$Item.VMName]
            return Start-VMAgentCycle -VMName $Item.VMName -Managers $Managers -GuestAuth $itemAuth -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -VMOutputDirectory $Item.VMOutputDirectory -MaxUpdates $Item.MaxUpdates -LocalSelectionPath $Item.LocalSelectionPath -SelectionPath $Item.GuestSelectionPath -SearchOnly:([bool]$Item.SearchOnly)
        } `
        -PollScript {
            param($Handle)
            # Ask vSphere once per round and stash the answer. Calling Test-VMAgentCycleComplete
            # again from the completion script can come back as "ended, exit code lost" once
            # vSphere has forgotten the process, and the apply result builder would read that
            # second answer instead of the one that actually decided the poll.
            $agentResult = Test-VMAgentCycleComplete -Handle $Handle
            $Handle.AgentResult = $agentResult
            return ($null -ne $agentResult)
        } `
        -CompleteScript {
            param($Handle)
            # On the timeout path the poll script never returned true, so AgentResult is
            # whatever the last poll saw - possibly still $null. Both callers treat that as
            # "no process result, trust status.json".
            return Complete-VMAgentCycle -Handle $Handle -AgentResult $Handle.AgentResult
        })
}

function Get-GuestRebootJobScript {
    return {
        param($JobInput)

        Set-StrictMode -Version 2.0
        $ErrorActionPreference = 'Stop'

        $connections = @()
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
            $rebootResult = Invoke-VMGuestReboot -VMName $JobInput.VMName -Managers $managers -GuestAuth $guestAuth

            return [pscustomobject]@{
                Sequence = $JobInput.Sequence
                VMName = $JobInput.VMName
                RebootReason = $JobInput.RebootReason
                ProcessId = $rebootResult.ProcessId
                Error = $null
            }
        }
        catch {
            return [pscustomobject]@{
                Sequence = $JobInput.Sequence
                VMName = $JobInput.VMName
                RebootReason = $JobInput.RebootReason
                ProcessId = $null
                Error = $_.Exception.Message
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

function Read-UpdateGroupSelection {
    param($UpdateGroups)

    $groups = @($UpdateGroups)
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

    return $selectedKeys
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

function New-ApplyResultFromCycle {
    param(
        [string]$VMName,
        $Cycle
    )

    $cycle = $Cycle
    $status = $cycle.Status
    $outcome = Get-ObjectPropertyValue -InputObject $status -Path @('outcome')
    $installResult = Get-ObjectPropertyValue -InputObject $status -Path @('installResult', 'result')
    $pendingAfter = [bool](Get-ObjectPropertyValue -InputObject $status -Path @('pendingRebootAfter', 'isPending') -DefaultValue $false)
    $rebootFromInstall = [bool](Get-ObjectPropertyValue -InputObject $status -Path @('installResult', 'rebootRequired') -DefaultValue $false)
    $rebootRequired = ($pendingAfter -or $rebootFromInstall)
    $errors = @(Get-ObjectPropertyValue -InputObject $status -Path @('errors') -DefaultValue @())

    if ($null -eq $cycle.AgentResult -or -not $cycle.AgentResult.Completed) {
        $reason = 'Apply guest process did not complete.'
        $errors += $reason
        return [pscustomobject]@{
            vmName = $VMName
            action = 'Install'
            outcome = 'Failed'
            installResult = $installResult
            reason = $reason
            rebootRequired = $rebootRequired
            errors = @($errors)
        }
    }

    # A partial install (WUA ResultCode 3) exits non-zero but is authoritative in
    # status.json as 'InstallSucceededWithErrors'. Preserve that outcome so the summary
    # can distinguish it from a total failure; only an unrecognized non-zero exit fails.
    if ($null -ne $cycle.AgentResult.ExitCode -and [int]$cycle.AgentResult.ExitCode -ne 0 -and $outcome -ne 'InstallSucceededWithErrors') {
        $reason = 'Apply guest process exited with code {0}.' -f $cycle.AgentResult.ExitCode
        $errors += $reason
        return [pscustomobject]@{
            vmName = $VMName
            action = 'Install'
            outcome = 'Failed'
            installResult = $installResult
            reason = $reason
            rebootRequired = $rebootRequired
            errors = @($errors)
        }
    }

    return [pscustomobject]@{
        vmName = $VMName
        action = 'Install'
        outcome = $outcome
        installResult = $installResult
        reason = ''
        rebootRequired = $rebootRequired
        errors = @($errors)
    }
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
        [int]$MaxInFlight = 1
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
                    rebootRequired = $false
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
                    errors = @($reason)
                }
            }
            continue
        }

        New-Item -ItemType Directory -Force -Path $vmOutputDirectory | Out-Null
        $selectionDocument = New-UpdateSelectionDocument -SelectedUpdateKeys $selectedKeys
        $localSelectionPath = Join-Path $vmOutputDirectory 'selection.json'
        $selectionDocument | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $localSelectionPath -Encoding UTF8
        $guestSelectionPath = Join-Path $GuestWorkingDirectory 'selection.json'

        $fleetItems += New-AgentFleetItem -Sequence $recordNumber -VMName ([string]$record.vmName) -VMOutputDirectory $vmOutputDirectory -MaxUpdates $selectedKeys.Count -LocalSelectionPath $localSelectionPath -GuestSelectionPath $guestSelectionPath -SearchOnly $false
    }

    if ($fleetItems.Count -gt 0) {
        Write-Step -Message ('Apply running with up to {0} VM(s) in flight.' -f $MaxInFlight)
        $fleetResults = @(Invoke-GuestAgentFleet -FleetItems $fleetItems -Managers $Managers -GuestCredentialMap $GuestCredentialMap -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -MaxInFlight $MaxInFlight)

        $doneCount = 0
        foreach ($fleetResult in @($fleetResults | Sort-Object Sequence)) {
            $doneCount++
            Write-Step -Message ('  {0}/{1} apply finished: {2}' -f $doneCount, $fleetItems.Count, $fleetResult.VMName)

            $hasError = -not [string]::IsNullOrWhiteSpace([string]$fleetResult.Error)
            $payload = Get-ObjectPropertyValue -InputObject $fleetResult -Path @('Payload')

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
                        errors = @($fleetResult.Error)
                    }
                }
                continue
            }

            if ($hasError) {
                # Timed out, but the artifacts still came down. status.json decides.
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
    $results | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $applyResultsPath -Encoding UTF8
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
        [int]$ThrottleLimit = 1
    )

    $bootTimeHelperPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'guest\Read-BootTime.ps1'

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
                $guestAuth = New-GuestAuthentication -Credential $GuestCredentialMap[$vmName]
                $bootTime = Invoke-VMGuestBootTimeRead -VMName $vmName -Managers $null -GuestAuth $guestAuth -CurlPath $CurlPath -GuestWorkingDirectory $GuestWorkingDirectory -BootTimeHelperPath $bootTimeHelperPath -TimeoutSeconds $timeoutSeconds -PollSeconds $PollSeconds -SkipHelperUpload:([bool]$helperUploadedByVm[$vmName])
                $helperUploadedByVm[$vmName] = $true
                $results += [pscustomobject]@{
                    Sequence = $item.Sequence
                    VMName = $vmName
                    BootTimeUtc = $bootTime.BootTimeUtc
                    UptimeSeconds = $bootTime.UptimeSeconds
                    Error = $null
                }
            }
            catch {
                # Without a job around each read, one guest throwing would end the whole phase, so
                # every failure has to become this VM's transient error instead. It also re-arms the
                # upload: a guest that lost the helper must not stay locked into skipping it.
                $helperUploadedByVm[$vmName] = $false
                $results += [pscustomobject]@{
                    Sequence = $item.Sequence
                    VMName = $vmName
                    BootTimeUtc = $null
                    UptimeSeconds = $null
                    Error = $_.Exception.Message
                }
            }
        }
        return @($results)
    }

    $initiateRebootScript = {
        param($Items)
        $jobInputs = @()
        foreach ($item in @($Items)) {
            $jobInputs += [pscustomobject]@{
                Sequence = $item.Sequence
                VMName = $item.VMName
                RebootReason = $item.RebootReason
                VIServers = @($VIServers)
                VIServerCredentialMap = $VIServerCredentialMap
                GuestCredential = $GuestCredentialMap[$item.VMName]
                IgnoreVCenterCertificate = [bool]$IgnoreVCenterCertificate
                GuestOpsLibPath = $GuestOpsLibPath
            }
        }
        return @(Invoke-ThrottledJobs -Items $jobInputs -ThrottleLimit $ThrottleLimit -JobTimeoutSeconds 300 -ScriptBlock $restartJobScript)
    }

    $decisionPromptScript = {
        param($Context)
        return Read-RebootDecision -Context $Context
    }

    return @(Invoke-RebootBatchCoordinator -RebootTargets $targetInputs -BatchSize $ThrottleLimit -WaitTimeoutSeconds $RebootTimeoutSeconds -PollSeconds $PollSeconds -ReadBootTimeScript $readBootTimeScript -InitiateRebootScript $initiateRebootScript -DecisionPromptScript $decisionPromptScript)
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
        $DiscoveryRecords = @()
    )

    $applyResults = @(Invoke-ApplyPhase -PatchPlanRecords $PatchPlanRecords -Managers $Managers -GuestCredentialMap $GuestCredentialMap -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -CycleOutputDirectory $CycleOutputDirectory -MaxInFlight $ThrottleLimit)
    Write-PatchingSummary -ApplyResults $applyResults

    $rebootActions = @()
    $rebootTargets = @(Select-RebootRequiredApplyResults -ApplyResults $applyResults -DiscoveryRecords $DiscoveryRecords)
    Write-FinalReport -PatchPlanRecords $PatchPlanRecords -ApplyResults $applyResults -CycleOutputDirectory $CycleOutputDirectory -RebootTargets $rebootTargets
    if ($rebootTargets.Count -gt 0) {
        if (Confirm-GuestReboot -RebootTargets $rebootTargets) {
            $rebootActions = @(Invoke-GuestRebootPhase -RebootTargets $rebootTargets -GuestCredentialMap $GuestCredentialMap -VIServers $VIServers -VIServerCredentialMap $VIServerCredentialMap -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $GuestOpsLibPath -CurlPath $CurlPath -GuestWorkingDirectory $GuestWorkingDirectory -RebootTimeoutSeconds $RebootTimeoutSeconds -PollSeconds $PollSeconds -ThrottleLimit $ThrottleLimit)
        }
        else {
            Write-Warning 'Guest reboot was not approved. Reboot phase skipped.'
            $rebootActions = @(New-SkippedRebootActionRecords -RebootTargets $rebootTargets)
        }

        Write-RebootActionArtifacts -CycleOutputDirectory $CycleOutputDirectory -RebootActions $rebootActions
    }

    if ((Test-ApplyResultsSuccessful -ApplyResults $applyResults) -and (Test-RebootActionsSuccessful -RebootActions $rebootActions)) {
        return 0
    }

    return 1
}

function Resolve-GuestCredentialMap {
    param(
        [string[]]$TargetNames,
        [pscredential]$OverrideCredential
    )

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

        $credential = Get-Credential -Message $message
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
        [int]$MaxInFlight = 1
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
        $fleetResults = @(Invoke-GuestAgentFleet -FleetItems $fleetItems -Managers $Managers -GuestCredentialMap $GuestCredentialMap -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -MaxInFlight $MaxInFlight)

        $doneCount = 0
        foreach ($fleetResult in @($fleetResults | Sort-Object Sequence)) {
            $doneCount++
            # Write-Host, not Write-Step: the per-VM step messages are suppressed for the whole
            # phase, and a fleet of fifty guests must not run for a quarter of an hour in silence.
            Write-Host ('  {0}/{1} discovery finished: {2}' -f $doneCount, $fleetItems.Count, $fleetResult.VMName)

            $vmOutputDirectory = $outputDirectoryBySequence[[int]$fleetResult.Sequence]
            $hasError = -not [string]::IsNullOrWhiteSpace([string]$fleetResult.Error)
            $payload = Get-ObjectPropertyValue -InputObject $fleetResult -Path @('Payload')

            if ($hasError -and $null -eq $payload) {
                Write-Warning ('Discovery failed for {0}: {1}' -f $fleetResult.VMName, $fleetResult.Error)
                $recordEntries += [pscustomobject]@{
                    Sequence = $fleetResult.Sequence
                    Record = New-DiscoveryRecord -VMName $fleetResult.VMName -Status $null -OutputDirectory $vmOutputDirectory -Errors @($fleetResult.Error)
                }
                continue
            }

            if ($hasError) {
                # Timed out, but the artifacts still came down. Hand them to the normal record
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
    @($records) | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $discoveryPath -Encoding UTF8

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

$targetVMNames = @(Resolve-VMTargetNames -SingleVMName $VMName -ManyVMNames $VMNames -ListPath $VMListPath)
$resolvedVIServers = @(Split-VIServerInput -InputText $VIServer)
$hasExplicitSelectedUpdateKeys = $PSBoundParameters.ContainsKey('SelectedUpdateKeys')

if ($resolvedVIServers.Count -eq 0) {
    throw 'At least one vCenter is required. Use -VIServer with one or more names separated by semicolons.'
}

if (-not [string]::IsNullOrWhiteSpace($InstallSelection)) {
    throw 'InstallSelection is not supported with grouped update selection. Use SelectedUpdateKeys instead.'
}

if ($hasExplicitSelectedUpdateKeys -and @($SelectedUpdateKeys).Count -eq 0) {
    throw 'SelectedUpdateKeys did not contain any non-empty update keys.'
}

if ([string]::IsNullOrWhiteSpace($VMName)) {
    $VMName = $targetVMNames[0]
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
$viserverCredentialMap = Resolve-VIServerCredentialMap -VIServers $resolvedVIServers -OverrideCredential $VIServerCredential
$retryVIServerLogin = ($null -eq $VIServerCredential)

try {
    Write-Step -Message ('Connecting to vCenter(s) {0}.' -f ($resolvedVIServers -join ', '))
    # Only the sessions this run opened go into $connections: the finally block disconnects
    # them, and a session the operator already had (-KeepConnected from an earlier run) must
    # survive this one.
    $connectResult = Connect-VIServersWithCredentialMap -VIServers $resolvedVIServers -CredentialMap $viserverCredentialMap -RetryOnFailure:$retryVIServerLogin -ReuseExisting
    $connections = @($connectResult.OpenedConnections)

    $managers = if ($resolvedVIServers.Count -eq 1) { Get-GuestOpsManagers } else { $null }

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
            $guestCredentialMap = Resolve-GuestCredentialMap -TargetNames @(@($patchPlanRecords) | ForEach-Object { [string]$_.vmName }) -OverrideCredential $GuestCredential
            $scriptExitCode = Invoke-ApplyAndOptionalReboot -PatchPlanRecords $patchPlanRecords -Managers $managers -GuestCredentialMap $guestCredentialMap -VIServers $resolvedVIServers -VIServerCredentialMap $viserverCredentialMap -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $guestOpsLibPath -CurlPath $curlPath -AgentPath $AgentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds ($TimeoutMinutes * 60) -RebootTimeoutSeconds ($RebootTimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $runOutputDirectory -ThrottleLimit $ThrottleLimit
        }

        exit $scriptExitCode
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $runOutputDirectory = New-UniqueOutputDirectory -BasePath (Join-Path $LocalOutputDirectory $timestamp)

    $guestCredentialMap = Resolve-GuestCredentialMap -TargetNames $targetVMNames -OverrideCredential $GuestCredential
    $discoveryRecords = Invoke-DiscoveryPhase -TargetVMNames $targetVMNames -Managers $managers -GuestCredentialMap $guestCredentialMap -CurlPath $curlPath -AgentPath $AgentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -MaxUpdates $MaxUpdates -TimeoutSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $runOutputDirectory -MaxInFlight $ThrottleLimit
    $failedDiscoveryRecords = @($discoveryRecords | Where-Object { @($_.errors).Count -gt 0 })
    if ($failedDiscoveryRecords.Count -gt 0) {
        $scriptExitCode = 1
    }
    else {
        $scriptExitCode = 0
    }

    $updateGroups = @(New-UpdateGroupRecords -DiscoveryRecords $discoveryRecords | Sort-Object kbText,title)
    Show-UpdateGroups -UpdateGroups $updateGroups

    if (-not $SearchOnly) {
        if ($hasExplicitSelectedUpdateKeys) {
            $selectedKeysForPlan = Resolve-SelectedUpdateKeys -UpdateGroups $updateGroups -ExplicitSelectedUpdateKeys $SelectedUpdateKeys
        }
        elseif ($updateGroups.Count -gt 0) {
            $selectedKeysForPlan = Read-UpdateGroupSelection -UpdateGroups $updateGroups
        }
        else {
            $selectedKeysForPlan = @()
        }

        Write-Step -Message ('Selected update group key(s): {0}' -f @($selectedKeysForPlan).Count)

        $patchPlanRecords = @(New-PatchPlanRecords -DiscoveryRecords $discoveryRecords -SelectedUpdateKeys $selectedKeysForPlan)
        $patchPlanRecords = @(Update-PatchPlanWithDiscoveryFailures -PatchPlanRecords $patchPlanRecords -DiscoveryRecords $discoveryRecords)
        $patchPlanPath = Join-Path $runOutputDirectory 'patch-plan.json'
        $patchPlanRecords | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $patchPlanPath -Encoding UTF8
        Show-PatchPlan -PatchPlanRecords $patchPlanRecords

        if ($PlanOnly) {
            $scriptExitCode = Get-PlanOnlyExitCode -PatchPlanRecords $patchPlanRecords
        }
        elseif (-not (Confirm-PatchPlan -SkipConfirmation:$SkipConfirmation)) {
            Write-Warning 'Patch plan was not approved. Apply phase skipped.'
            $scriptExitCode = 1
        }
        else {
            $scriptExitCode = Invoke-ApplyAndOptionalReboot -PatchPlanRecords $patchPlanRecords -Managers $managers -GuestCredentialMap $guestCredentialMap -VIServers $resolvedVIServers -VIServerCredentialMap $viserverCredentialMap -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $guestOpsLibPath -CurlPath $curlPath -AgentPath $AgentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds ($TimeoutMinutes * 60) -RebootTimeoutSeconds ($RebootTimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $runOutputDirectory -ThrottleLimit $ThrottleLimit -DiscoveryRecords $discoveryRecords
        }
    }
    elseif ($PlanOnly) {
        $selectedKeysForPlan = @()
        $patchPlanRecords = @(New-PatchPlanRecords -DiscoveryRecords $discoveryRecords -SelectedUpdateKeys $selectedKeysForPlan)
        $patchPlanRecords = @(Update-PatchPlanWithDiscoveryFailures -PatchPlanRecords $patchPlanRecords -DiscoveryRecords $discoveryRecords)
        $patchPlanPath = Join-Path $runOutputDirectory 'patch-plan.json'
        $patchPlanRecords | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $patchPlanPath -Encoding UTF8
        Show-PatchPlan -PatchPlanRecords $patchPlanRecords
        $scriptExitCode = Get-PlanOnlyExitCode -PatchPlanRecords $patchPlanRecords
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

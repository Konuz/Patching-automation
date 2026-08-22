Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-ThrottledJobErrorResult {
    param(
        $InputObject,
        [string]$ErrorMessage
    )

    # Job inputs differ per phase (apply carries VMOutputDirectory, boot-time reads do not),
    # so every field is read defensively — under StrictMode a missing property would throw
    # here and tear down the whole phase instead of reporting the job error.
    return [pscustomobject]@{
        Sequence = Get-RuntimePropertyValue -InputObject $InputObject -Name 'Sequence'
        VMName = Get-RuntimePropertyValue -InputObject $InputObject -Name 'VMName'
        VMOutputDirectory = Get-RuntimePropertyValue -InputObject $InputObject -Name 'VMOutputDirectory'
        Status = $null
        AgentResult = $null
        Error = $ErrorMessage
    }
}

function Invoke-ThrottledJobs {
    param(
        [object[]]$Items,
        [int]$ThrottleLimit,
        [int]$JobTimeoutSeconds,
        [scriptblock]$ScriptBlock
    )

    if ($ThrottleLimit -lt 1) {
        throw 'ThrottleLimit must be greater than or equal to 1.'
    }

    if ($JobTimeoutSeconds -lt 1) {
        throw 'JobTimeoutSeconds must be greater than or equal to 1.'
    }

    $pending = New-Object System.Collections.Queue
    foreach ($item in @($Items)) {
        $pending.Enqueue($item)
    }

    $running = @()
    $results = @()
    $createdJobIds = New-Object System.Collections.Generic.List[int]

    try {
        while ($pending.Count -gt 0 -or $running.Count -gt 0) {
            while ($pending.Count -gt 0 -and $running.Count -lt $ThrottleLimit) {
                $item = $pending.Dequeue()
                try {
                    $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $item
                    [void]$createdJobIds.Add($job.Id)
                    $running += [pscustomobject]@{
                        Job = $job
                        Input = $item
                        StartedAt = Get-Date
                    }
                }
                catch {
                    $results += New-ThrottledJobErrorResult -InputObject $item -ErrorMessage ('Start-Job failed: {0}' -f $_.Exception.Message)
                }
            }

            $now = Get-Date
            # Snapshot each running job's state once per iteration so the timed-out,
            # completed, and still-running partitions all agree. Reading $_.Job.State
            # live in each filter can drop a job that transitions Running -> Completed
            # between two filter evaluations.
            $snapshot = @($running | ForEach-Object {
                $entryState = [string]$_.Job.State
                [pscustomobject]@{
                    Job = $_.Job
                    Input = $_.Input
                    StartedAt = $_.StartedAt
                    State = $entryState
                    IsTerminal = ($entryState -in @('Completed', 'Failed', 'Stopped'))
                }
            })

            $timedOut = @($snapshot | Where-Object {
                -not $_.IsTerminal -and
                (($now - $_.StartedAt).TotalSeconds -ge $JobTimeoutSeconds)
            })
            $timedOutJobIds = @{}

            foreach ($entry in $timedOut) {
                $timedOutJobIds[[string]$entry.Job.Id] = $true
                Stop-Job -Job $entry.Job -ErrorAction SilentlyContinue
                $results += New-ThrottledJobErrorResult -InputObject $entry.Input -ErrorMessage ('Job timed out after {0} seconds.' -f $JobTimeoutSeconds)
            }

            # All terminal states are handled uniformly: the job scriptblock self-reports
            # failures as a result object with an .Error field, and a scriptblock that throws
            # surfaces via Receive-Job -ErrorAction Stop into the catch below. Timed-out jobs
            # are handled separately above, so a Stopped job never reaches this branch.
            $completed = @($snapshot | Where-Object { $_.IsTerminal })
            foreach ($entry in $completed) {
                try {
                    $output = Receive-Job -Job $entry.Job -ErrorAction Stop
                    if ($null -eq $output) {
                        $results += New-ThrottledJobErrorResult -InputObject $entry.Input -ErrorMessage 'Receive-Job returned no output.'
                    }
                    else {
                        $results += $output
                    }
                }
                catch {
                    $results += New-ThrottledJobErrorResult -InputObject $entry.Input -ErrorMessage ('Receive-Job failed: {0}' -f $_.Exception.Message)
                }
            }

            $running = @($snapshot | Where-Object { -not $_.IsTerminal -and -not $timedOutJobIds.ContainsKey([string]$_.Job.Id) } | ForEach-Object {
                [pscustomobject]@{
                    Job = $_.Job
                    Input = $_.Input
                    StartedAt = $_.StartedAt
                }
            })
            Start-Sleep -Milliseconds 200
        }
    }
    finally {
        foreach ($entry in @($running)) {
            Stop-Job -Job $entry.Job -ErrorAction SilentlyContinue
        }
        foreach ($createdJobId in @($createdJobIds)) {
            $job = Get-Job -Id $createdJobId -ErrorAction SilentlyContinue
            if ($null -ne $job) {
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return @($results)
}

function New-FleetErrorResult {
    param(
        $InputObject,
        [string]$ErrorMessage,
        $Payload = $null
    )

    return [pscustomobject]@{
        Sequence = Get-RuntimePropertyValue -InputObject $InputObject -Name 'Sequence'
        VMName = Get-RuntimePropertyValue -InputObject $InputObject -Name 'VMName'
        Payload = $Payload
        Error = $ErrorMessage
    }
}

function Invoke-InProcessAgentFleet {
    param(
        [object[]]$Items,
        [int]$MaxInFlight,
        [int]$PollSeconds,
        [int]$ItemTimeoutSeconds,
        [scriptblock]$StartScript,
        [scriptblock]$PollScript,
        [scriptblock]$CompleteScript,
        [scriptblock]$SleepScript = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
    )

    if ($MaxInFlight -lt 1) {
        throw 'MaxInFlight must be greater than or equal to 1.'
    }
    if ($PollSeconds -lt 1) {
        throw 'PollSeconds must be greater than or equal to 1.'
    }

    $pending = New-Object System.Collections.Queue
    foreach ($item in @($Items)) {
        $pending.Enqueue($item)
    }

    $inFlight = @()
    $results = @()

    while ($pending.Count -gt 0 -or $inFlight.Count -gt 0) {
        # Starts are sequential but return immediately: StartProgramInGuest hands back a
        # process id without waiting, so with MaxInFlight at the target count every guest
        # is working before the first poll round begins.
        while ($pending.Count -gt 0 -and $inFlight.Count -lt $MaxInFlight) {
            $item = $pending.Dequeue()
            try {
                $handle = & $StartScript $item
                $inFlight += [pscustomobject]@{
                    Item = $item
                    Handle = $handle
                    StartedAt = Get-Date
                }
            }
            catch {
                # There is no job boundary around a start, so a throwing guest would end the
                # whole phase. Every failure has to become this VM's error instead.
                $results += New-FleetErrorResult -InputObject $item -ErrorMessage ('Agent start failed: {0}' -f $_.Exception.Message)
            }
        }

        $now = Get-Date
        $kept = @()
        foreach ($entry in @($inFlight)) {
            if (($now - $entry.StartedAt).TotalSeconds -ge $ItemTimeoutSeconds) {
                # Harvest anyway. status.json is the primary result (see CLAUDE.md), and the
                # job-based path this replaces always downloaded the artifacts even when the
                # process result timed out. Dropping them here would turn a guest run that
                # actually finished into a reported failure and throw away the only per-VM
                # diagnostics. The timeout error stands regardless of what the harvest finds.
                $timeoutPayload = $null
                try {
                    $timeoutPayload = & $CompleteScript $entry.Handle
                }
                catch {
                    $timeoutPayload = $null
                }

                $results += New-FleetErrorResult -InputObject $entry.Item -ErrorMessage ('Agent run timed out after {0} seconds.' -f $ItemTimeoutSeconds) -Payload $timeoutPayload
                continue
            }

            try {
                if (& $PollScript $entry.Handle) {
                    $results += [pscustomobject]@{
                        Sequence = Get-RuntimePropertyValue -InputObject $entry.Item -Name 'Sequence'
                        VMName = Get-RuntimePropertyValue -InputObject $entry.Item -Name 'VMName'
                        Payload = (& $CompleteScript $entry.Handle)
                        Error = $null
                    }
                    continue
                }
            }
            catch {
                $results += New-FleetErrorResult -InputObject $entry.Item -ErrorMessage $_.Exception.Message
                continue
            }

            $kept += $entry
        }

        $inFlight = @($kept)
        if ($inFlight.Count -gt 0) {
            & $SleepScript $PollSeconds
        }
    }

    return @($results)
}

function Test-IsApplyResultError {
    param($ApplyResult)

    if ($null -eq $ApplyResult) {
        return $true
    }

    if ($ApplyResult.action -eq 'Install' -and $ApplyResult.outcome -ne 'InstallSucceeded') {
        return $true
    }

    if ($ApplyResult.action -ne 'Install' -and $ApplyResult.reason -eq 'Skipped: Discovery failed. Review discovery.json and per-VM agent artifacts.') {
        return $true
    }

    return $false
}

function Get-ApplySummaryStatus {
    param($ApplyResult)

    # Maps an apply result to the single status token the console summary colours on.
    # Partial wins over the error check (a partial install trips Test-IsApplyResultError
    # because its outcome is not 'InstallSucceeded', but it is not a total failure).
    # Otherwise: error wins, a non-install action is a skip, and a clean install splits
    # on whether the guest still needs a reboot.
    if ($ApplyResult.action -eq 'Install' -and $ApplyResult.outcome -eq 'InstallSucceededWithErrors') {
        return 'Partial'
    }

    if (Test-IsApplyResultError -ApplyResult $ApplyResult) {
        return 'Error'
    }

    if ($ApplyResult.action -ne 'Install') {
        return 'Skipped'
    }

    if ([bool]$ApplyResult.rebootRequired) {
        return 'InstalledRebootRequired'
    }

    return 'Installed'
}

function Test-ApplyResultsSuccessful {
    param($ApplyResults)

    $errors = @($ApplyResults | Where-Object { Test-IsApplyResultError -ApplyResult $_ })
    return ($errors.Count -eq 0)
}
function Get-RuntimePropertyValue {
    param(
        $InputObject,
        [string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Get-RebootTargetReason {
    param(
        [bool]$RebootRequiredAfterApply,
        [bool]$PendingBeforeApply
    )

    if ($RebootRequiredAfterApply -and $PendingBeforeApply) {
        return 'Pending before patching and after apply'
    }

    if ($PendingBeforeApply) {
        return 'Pending before patching'
    }

    return 'Reported after apply'
}

function Select-RebootRequiredApplyResults {
    param(
        $ApplyResults,
        $DiscoveryRecords = @()
    )

    $pendingBeforeByVmName = @{}
    foreach ($record in @($DiscoveryRecords)) {
        $vmName = [string](Get-RuntimePropertyValue -InputObject $record -Name 'vmName')
        if ([string]::IsNullOrWhiteSpace($vmName)) {
            continue
        }

        $pendingRebootBefore = Get-RuntimePropertyValue -InputObject $record -Name 'pendingRebootBefore'
        $isPending = Get-RuntimePropertyValue -InputObject $pendingRebootBefore -Name 'isPending' -DefaultValue $false
        if ([bool]$isPending) {
            $pendingBeforeByVmName[$vmName] = $true
        }
    }

    $targets = @()
    foreach ($result in @($ApplyResults)) {
        $vmName = [string](Get-RuntimePropertyValue -InputObject $result -Name 'vmName')
        if ([string]::IsNullOrWhiteSpace($vmName)) {
            continue
        }

        $rebootRequiredAfterApply = [bool](Get-RuntimePropertyValue -InputObject $result -Name 'rebootRequired' -DefaultValue $false)
        $pendingBeforeApply = $pendingBeforeByVmName.ContainsKey($vmName)
        if (-not $rebootRequiredAfterApply -and -not $pendingBeforeApply) {
            continue
        }

        $targets += [pscustomobject]@{
            vmName = $vmName
            rebootRequired = $true
            rebootReason = Get-RebootTargetReason -RebootRequiredAfterApply $rebootRequiredAfterApply -PendingBeforeApply $pendingBeforeApply
        }
    }

    return @($targets)
}

function Split-RebootBatches {
    param(
        [object[]]$Items,
        [int]$BatchSize = 1
    )

    if ($BatchSize -lt 1) {
        throw 'BatchSize must be greater than or equal to 1.'
    }

    $batches = New-Object System.Collections.Generic.List[object]
    $current = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Items)) {
        $current.Add($item)
        if ($current.Count -ge $BatchSize) {
            $batches.Add([object[]]$current.ToArray())
            $current = New-Object System.Collections.Generic.List[object]
        }
    }
    if ($current.Count -gt 0) {
        $batches.Add([object[]]$current.ToArray())
    }

    return @($batches.ToArray())
}

function Test-BootTimeNewer {
    param($Baseline, $Observed)

    if ($null -eq $Baseline -or $null -eq $Observed) {
        return $false
    }

    return ([datetime]$Observed -gt [datetime]$Baseline)
}

function New-RebootActionRecord {
    param(
        [string]$VMName,
        [string]$Action,
        $ProcessId = $null,
        [string]$ErrorMessage = $null,
        [string]$RebootReason = $null,
        [int]$BatchNumber = 0,
        [int]$Sequence = 0,
        $BootTimeBaseline = $null,
        $BootTimeObserved = $null,
        $UptimeBaselineSeconds = $null,
        $UptimeObservedSeconds = $null,
        [string]$ValidationStatus = 'NotRequested',
        [int]$WaitSeconds = 0,
        [string]$OperatorDecision = $null,
        [int]$AttemptCount = 0,
        [int]$TimeoutCount = 0,
        [string]$LastErrorMessage = $null
    )

    $bootTimeBaselineText = if ($null -eq $BootTimeBaseline) { $null } else { ([datetime]$BootTimeBaseline).ToUniversalTime().ToString('o') }
    $bootTimeObservedText = if ($null -eq $BootTimeObserved) { $null } else { ([datetime]$BootTimeObserved).ToUniversalTime().ToString('o') }
    $lastErrorText = if ([string]::IsNullOrWhiteSpace($LastErrorMessage)) { $ErrorMessage } else { $LastErrorMessage }

    return [pscustomobject]@{
        vmName = $VMName
        rebootRequired = $true
        rebootReason = $RebootReason
        action = $Action
        processId = $ProcessId
        errorMessage = $ErrorMessage
        batchNumber = $BatchNumber
        sequence = $Sequence
        bootTimeBaseline = $bootTimeBaselineText
        bootTimeObserved = $bootTimeObservedText
        # Diagnostics only - the gate decides on boot time alone. Uptime comes from the same CIM
        # snapshot as the boot time, so it survives a guest clock step: if a confirmed restart ever
        # shows up as a boot time that moved backwards, these two fields are what explains it.
        uptimeBaselineSeconds = $UptimeBaselineSeconds
        uptimeObservedSeconds = $UptimeObservedSeconds
        validationStatus = $ValidationStatus
        waitSeconds = $WaitSeconds
        operatorDecision = $OperatorDecision
        attemptCount = $AttemptCount
        timeoutCount = $TimeoutCount
        lastError = $lastErrorText
    }
}

function New-SkippedRebootActionRecords {
    param($RebootTargets)

    $records = @()
    foreach ($target in @($RebootTargets)) {
        $records += New-RebootActionRecord -VMName ([string]$target.vmName) -Action 'SkippedByOperator' -RebootReason ([string]$target.rebootReason)
    }

    return @($records)
}

function Test-RebootActionsSuccessful {
    param($RebootActions)

    $records = @($RebootActions)
    if ($records.Count -eq 0) {
        return $true
    }

    foreach ($record in $records) {
        $action = [string]$record.action
        $validation = [string]$record.validationStatus
        if ($action -eq 'SkippedByOperator') {
            continue
        }
        if ($action -eq 'Initiated' -and $validation -eq 'Confirmed') {
            continue
        }
        return $false
    }

    return $true
}

function Get-PatchRoundDecision {
    param(
        $CompletionStates,
        [int]$Round,
        [int]$MaxRounds,
        [string]$OperatorDecision
    )

    $states = @($CompletionStates)
    $pending = @($states | Where-Object { [string]$_.state -eq 'Pending' })
    $pendingVMNames = @($pending | ForEach-Object { [string]$_.vmName })
    # Excluded VMs (Failover Cluster) can never be patched by this tool, so they must not
    # count against "all green" - otherwise the run would never settle over a VM it will
    # never touch. Failed discovery is not green and is not retryable here either.
    $allGreen = (@($states | Where-Object { [string]$_.state -in @('Pending', 'Failed') }).Count -eq 0)

    # Round one always proceeds to group selection, even with nothing preselected: the
    # operator must still get to see the group list and tick something the default policy
    # skipped. Checking $pending first would end the run before the groups are ever shown.
    if ($Round -le 1) {
        return [pscustomobject]@{
            Action = 'Continue'
            AllGreen = $allGreen
            NeedsOperatorDecision = $false
            PendingVMNames = $pendingVMNames
            Reason = 'First patching round.'
        }
    }

    if ($pending.Count -eq 0) {
        $stopReason = if ($allGreen) { 'Every VM is green.' } else { 'No VM can be patched further in this run.' }
        return [pscustomobject]@{
            Action = 'Stop'
            AllGreen = $allGreen
            NeedsOperatorDecision = $false
            PendingVMNames = @()
            Reason = $stopReason
        }
    }

    # MaxRounds counts apply rounds. Round MaxRounds+1 still runs its discovery, which is the
    # verification of the last apply, and then stops.
    if ($Round -gt $MaxRounds) {
        return [pscustomobject]@{
            Action = 'Stop'
            AllGreen = $false
            NeedsOperatorDecision = $false
            PendingVMNames = $pendingVMNames
            Reason = ('Stopping after round {0}: MaxPatchRounds is {1}.' -f $Round, $MaxRounds)
        }
    }

    if ([string]::IsNullOrWhiteSpace($OperatorDecision)) {
        return [pscustomobject]@{
            Action = 'Ask'
            AllGreen = $false
            NeedsOperatorDecision = $true
            PendingVMNames = $pendingVMNames
            Reason = ('{0} VM(s) still have selectable updates after the reboot.' -f $pending.Count)
        }
    }

    if ($OperatorDecision -eq 'CONTINUE') {
        return [pscustomobject]@{
            Action = 'Continue'
            AllGreen = $false
            NeedsOperatorDecision = $false
            PendingVMNames = $pendingVMNames
            Reason = 'Operator chose to continue patching.'
        }
    }

    return [pscustomobject]@{
        Action = 'Stop'
        AllGreen = $false
        NeedsOperatorDecision = $false
        PendingVMNames = $pendingVMNames
        Reason = 'Operator finished patching with updates still pending.'
    }
}

function Merge-PatchRunStates {
    param(
        [hashtable]$StateMap,
        $CompletionStates
    )

    # Later rounds only target VMs that were still Pending, so a VM that failed discovery in
    # round one simply is not in round two's records. Reading the verdict off the last round
    # alone would let that failure vanish and the run exit 0 on a machine nobody rechecked.
    foreach ($state in @($CompletionStates)) {
        $vmName = [string]$state.vmName
        if (-not [string]::IsNullOrWhiteSpace($vmName)) {
            $StateMap[$vmName] = $state
        }
    }
}

function Test-PatchRunAllGreen {
    param([hashtable]$StateMap)

    foreach ($vmName in @($StateMap.Keys)) {
        if ([string]$StateMap[$vmName].state -in @('Pending', 'Failed')) {
            return $false
        }
    }

    return $true
}

function Test-RebootActionsAllConfirmed {
    param($RebootActions)

    # Stricter than Test-RebootActionsSuccessful: that one tolerates an operator skip, this
    # one answers "is every rebooted guest provably back up", which is what gates the next
    # discovery round. An unverified, skipped or failed restart is not proof of anything.
    foreach ($record in @($RebootActions)) {
        if ([string]$record.action -ne 'Initiated' -or [string]$record.validationStatus -ne 'Confirmed') {
            return $false
        }
    }

    return $true
}

function Write-RebootActionArtifacts {
    param(
        [string]$CycleOutputDirectory,
        $RebootActions
    )

    $actions = @($RebootActions)
    $artifactPath = Join-Path $CycleOutputDirectory 'reboot-actions.json'
    $actions | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

    $summaryPath = Join-Path $CycleOutputDirectory 'summary.md'
    $confirmed = @($actions | Where-Object { $_.action -eq 'Initiated' -and $_.validationStatus -eq 'Confirmed' })
    $unverified = @($actions | Where-Object { $_.action -eq 'Initiated' -and $_.validationStatus -eq 'Unverified' })
    $timeout = @($actions | Where-Object { $_.action -eq 'Initiated' -and $_.validationStatus -eq 'Timeout' })
    $skipped = @($actions | Where-Object { $_.action -eq 'SkippedByOperator' })
    $failed = @($actions | Where-Object { $_.action -eq 'Failed' })
    $aborted = @($actions | Where-Object { $_.action -eq 'NotStartedAfterAbort' })

    $lines = @()
    $lines += ''
    $lines += '## Guest reboot actions'
    $lines += ''
    $lines += ('- VMs with reboot confirmed: {0}' -f $confirmed.Count)
    $lines += ('- VMs with reboot unverified (operator override): {0}' -f $unverified.Count)
    $lines += ('- VMs with reboot skipped by operator: {0}' -f $skipped.Count)
    $lines += ('- VMs with reboot initiation errors: {0}' -f $failed.Count)
    $lines += ('- VMs with reboot timeout: {0}' -f $timeout.Count)
    $lines += ('- VMs not rebooted (aborted): {0}' -f $aborted.Count)
    $lines += ''

    foreach ($section in @(
        [pscustomobject]@{ Title = 'VMs with reboot confirmed'; Rows = $confirmed },
        [pscustomobject]@{ Title = 'VMs with reboot unverified (operator override)'; Rows = $unverified },
        [pscustomobject]@{ Title = 'VMs with reboot skipped by operator'; Rows = $skipped },
        [pscustomobject]@{ Title = 'VMs with reboot timeout'; Rows = $timeout },
        [pscustomobject]@{ Title = 'VMs with reboot initiation errors'; Rows = $failed },
        [pscustomobject]@{ Title = 'VMs not rebooted (aborted)'; Rows = $aborted }
    )) {
        $lines += ('### {0}' -f $section.Title)
        if (@($section.Rows).Count -eq 0) {
            $lines += '- none'
        }
        else {
            foreach ($row in @($section.Rows)) {
                $reasonText = if ([string]::IsNullOrWhiteSpace([string]$row.rebootReason)) { '' } else { (' ({0})' -f $row.rebootReason) }
                if ([string]::IsNullOrWhiteSpace([string]$row.errorMessage)) {
                    $lines += ('- {0}{1}' -f $row.vmName, $reasonText)
                }
                else {
                    $lines += ('- {0}{1}: {2}' -f $row.vmName, $reasonText, $row.errorMessage)
                }
            }
        }
        $lines += ''
    }

    Add-Content -LiteralPath $summaryPath -Value $lines -Encoding UTF8
}

function Write-PatchRunSummary {
    param(
        [string]$RunOutputDirectory,
        $RoundSummaries,
        [hashtable]$FinalStateMap
    )

    $rounds = @($RoundSummaries)
    $roundsPath = Join-Path $RunOutputDirectory 'rounds.json'
    $rounds | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $roundsPath -Encoding UTF8

    $finalStates = @(@($FinalStateMap.Keys) | Sort-Object | ForEach-Object { $FinalStateMap[$_] })
    $green = @($finalStates | Where-Object { [string]$_.state -eq 'Green' })
    $greenByChoice = @($finalStates | Where-Object { [string]$_.state -eq 'GreenByOperatorChoice' })
    $pending = @($finalStates | Where-Object { [string]$_.state -eq 'Pending' })
    $failed = @($finalStates | Where-Object { [string]$_.state -eq 'Failed' })
    $excluded = @($finalStates | Where-Object { [string]$_.state -eq 'Excluded' })

    $lines = @()
    $lines += '# Patch run summary'
    $lines += ''
    $lines += ('Output directory: `{0}`' -f $RunOutputDirectory)
    $lines += ('Patch rounds run: {0}' -f $rounds.Count)
    $lines += ''
    $lines += ('- VMs up to date: {0}' -f $green.Count)
    $lines += ('- VMs up to date except operator-deselected updates: {0}' -f $greenByChoice.Count)
    $lines += ('- VMs still having selectable updates: {0}' -f $pending.Count)
    $lines += ('- VMs whose discovery failed: {0}' -f $failed.Count)
    $lines += ('- VMs excluded from patching: {0}' -f $excluded.Count)
    $lines += ''

    $lines += '## Rounds'
    if ($rounds.Count -eq 0) {
        $lines += '- none'
    }
    else {
        foreach ($round in $rounds) {
            $lines += ('- Round {0}: {1} VM(s) targeted, artifacts in `{2}`' -f $round.round, @($round.targetVMNames).Count, $round.outputDirectory)
        }
    }
    $lines += ''

    foreach ($section in @(
        [pscustomobject]@{ Title = 'VMs still having selectable updates'; Rows = $pending },
        [pscustomobject]@{ Title = 'VMs whose discovery failed'; Rows = $failed },
        [pscustomobject]@{ Title = 'VMs excluded from patching'; Rows = $excluded },
        [pscustomobject]@{ Title = 'VMs up to date except operator-deselected updates'; Rows = $greenByChoice },
        [pscustomobject]@{ Title = 'VMs up to date'; Rows = $green }
    )) {
        $lines += ('## {0}' -f $section.Title)
        if (@($section.Rows).Count -eq 0) {
            $lines += '- none'
        }
        else {
            foreach ($row in @($section.Rows)) {
                $lines += ('- {0}: {1}' -f $row.vmName, $row.reason)
            }
        }
        $lines += ''
    }

    $summaryPath = Join-Path $RunOutputDirectory 'summary.md'
    Set-Content -LiteralPath $summaryPath -Value $lines -Encoding UTF8
}

function Wait-RebootBatchBootTimes {
    param(
        [object[]]$Items,
        [int]$WaitTimeoutSeconds,
        [int]$PollSeconds,
        [int]$GraceSeconds = 0,
        [scriptblock]$ReadBootTimeScript,
        [scriptblock]$SleepScript = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
    )

    if ($PollSeconds -lt 1) {
        throw 'PollSeconds must be greater than or equal to 1.'
    }
    if ($WaitTimeoutSeconds -lt 0) {
        throw 'WaitTimeoutSeconds must be greater than or equal to 0.'
    }

    $pending = @($Items)
    if ($pending.Count -eq 0) {
        return [pscustomobject]@{ Records = @(); Pending = @(); TimedOut = $false }
    }

    $records = @()
    $windowStart = Get-Date
    # A guest that was just told to shut down cannot possibly report a newer boot time for a
    # minute or more, so reads inside that window are guaranteed-wasted GuestOps traffic. The
    # grace sits outside the timeout budget - it delays the first read without shortening the
    # observation window - and the caller drops it on RETRY, where the wait is long past over.
    if ($GraceSeconds -gt 0) {
        & $SleepScript $GraceSeconds
    }
    $deadline = (Get-Date).AddSeconds($WaitTimeoutSeconds)
    $timedOut = $false
    $firstRead = $true

    while ($pending.Count -gt 0) {
        if (-not $firstRead -and (Get-Date) -ge $deadline) {
            $timedOut = $true
            break
        }

        $remainingSeconds = [math]::Max(1, [int][math]::Ceiling(($deadline - (Get-Date)).TotalSeconds))
        foreach ($pendingItem in $pending) {
            $pendingItem.AttemptCount++
            $pendingItem.ReadTimeoutSeconds = $remainingSeconds
        }
        $readResults = @(& $ReadBootTimeScript $pending)
        $newBootByVm = @{}
        $readByVm = @{}
        foreach ($readResult in @($readResults)) {
            $readByVm[[string]$readResult.VMName] = $readResult
            if ([string]::IsNullOrWhiteSpace([string]$readResult.Error) -and $null -ne $readResult.BootTimeUtc) {
                $newBootByVm[[string]$readResult.VMName] = $readResult.BootTimeUtc
            }
        }

        $kept = @()
        foreach ($pendingItem in $pending) {
            $readResult = $readByVm[[string]$pendingItem.VMName]
            if ($null -eq $readResult) {
                $pendingItem.LastErrorMessage = 'No boot time result was returned.'
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$readResult.Error)) {
                $pendingItem.LastErrorMessage = [string]$readResult.Error
            }
            $confirmed = $false
            if ($newBootByVm.ContainsKey([string]$pendingItem.VMName)) {
                $observed = $newBootByVm[[string]$pendingItem.VMName]
                $pendingItem.BootTimeObserved = $observed
                $pendingItem.UptimeObservedSeconds = Get-RuntimePropertyValue -InputObject $readResult -Name 'UptimeSeconds'
                if (Test-BootTimeNewer -Baseline $pendingItem.BootTimeBaseline -Observed $observed) {
                    $confirmed = $true
                    $records += New-RebootActionRecord -VMName $pendingItem.VMName -Action 'Initiated' -ProcessId $pendingItem.ProcessId -RebootReason $pendingItem.RebootReason -BatchNumber $pendingItem.BatchNumber -Sequence $pendingItem.Sequence -BootTimeBaseline $pendingItem.BootTimeBaseline -BootTimeObserved $observed -UptimeBaselineSeconds $pendingItem.UptimeBaselineSeconds -UptimeObservedSeconds $pendingItem.UptimeObservedSeconds -ValidationStatus 'Confirmed' -WaitSeconds ([int](Get-Date).Subtract($windowStart).TotalSeconds) -AttemptCount $pendingItem.AttemptCount -TimeoutCount $pendingItem.TimeoutCount -LastErrorMessage $pendingItem.LastErrorMessage
                }
            }

            if (-not $confirmed) {
                $kept += $pendingItem
            }
        }
        $pending = $kept
        $firstRead = $false

        if ($pending.Count -gt 0) {
            $remainingSeconds = ($deadline - (Get-Date)).TotalSeconds
            if ($remainingSeconds -le 0) {
                $timedOut = $true
                break
            }

            # Ceiling, not Floor: a sub-second remainder must still sleep at least 1s, matching
            # Wait-GuestProcess. A zero sleep here would skip straight to another full read wave.
            $sleepSeconds = [int][math]::Ceiling([math]::Min($PollSeconds, $remainingSeconds))
            if ($sleepSeconds -gt 0) {
                & $SleepScript $sleepSeconds
            }
        }
    }

    return [pscustomobject]@{
        Records = @($records)
        Pending = @($pending)
        TimedOut = $timedOut
    }
}

function Invoke-RebootBatchCoordinator {
    param(
        [object[]]$RebootTargets,
        [int]$BatchSize,
        [int]$WaitTimeoutSeconds,
        [int]$PollSeconds,
        [int]$GraceSeconds = 90,
        [scriptblock]$ReadBootTimeScript,
        [scriptblock]$InitiateRebootScript,
        [scriptblock]$DecisionPromptScript,
        [scriptblock]$SleepScript = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
    )

    $records = @()
    # @() is load-bearing: a single batch is emitted as one object that is itself an array, so
    # without the wrapper the outer level collapses and every VM becomes its own batch.
    $batches = @(Split-RebootBatches -Items $RebootTargets -BatchSize $BatchSize)
    $batchNumber = 0
    $aborted = $false

    foreach ($batch in @($batches)) {
        if ($aborted) {
            $batchNumber++
            foreach ($target in @($batch)) {
                $records += New-RebootActionRecord -VMName ([string]$target.vmName) -Action 'NotStartedAfterAbort' -RebootReason ([string]$target.rebootReason) -BatchNumber $batchNumber -Sequence ([int]$target.Sequence) -ValidationStatus 'NotStartedAfterAbort' -OperatorDecision 'ABORT'
            }
            continue
        }

        $batchNumber++
        $batchItems = @()
        foreach ($target in @($batch)) {
            $batchItems += [pscustomobject]@{
                Sequence = [int]$target.Sequence
                VMName = [string]$target.vmName
                RebootReason = [string]$target.rebootReason
                BatchNumber = $batchNumber
                BootTimeBaseline = $null
                BootTimeObserved = $null
                UptimeBaselineSeconds = $null
                UptimeObservedSeconds = $null
                ValidationRequired = $false
                Initiated = $false
                ProcessId = $null
                AttemptCount = 0
                TimeoutCount = 0
                LastErrorMessage = $null
                ReadTimeoutSeconds = $null
            }
        }

        # --- baseline boot-time reads ---
        foreach ($item in $batchItems) {
            $item.ValidationRequired = $true
        }

        while ($true) {
            $missing = @($batchItems | Where-Object { $_.ValidationRequired -and $null -eq $_.BootTimeBaseline })
            if ($missing.Count -eq 0) {
                break
            }

            foreach ($item in $missing) {
                $item.AttemptCount++
            }
            $readResults = @(& $ReadBootTimeScript $missing)
            $readByVm = @{}
            foreach ($readResult in @($readResults)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$readResult.Error)) {
                    $matchingItem = @($missing | Where-Object { $_.VMName -eq $readResult.VMName })[0]
                    if ($null -ne $matchingItem) {
                        $matchingItem.LastErrorMessage = [string]$readResult.Error
                    }
                }
                if ([string]::IsNullOrWhiteSpace([string]$readResult.Error) -and $null -ne $readResult.BootTimeUtc) {
                    $readByVm[[string]$readResult.VMName] = $readResult.BootTimeUtc
                }
            }
            foreach ($item in $missing) {
                $readResult = @($readResults | Where-Object { $_.VMName -eq $item.VMName })[0]
                if ($null -eq $readResult) {
                    $item.LastErrorMessage = 'No boot time result was returned.'
                }
                elseif ([string]::IsNullOrWhiteSpace([string]$readResult.Error) -and $null -eq $readResult.BootTimeUtc) {
                    $item.LastErrorMessage = 'Boot time result was empty.'
                }
                if ($readByVm.ContainsKey([string]$item.VMName)) {
                    $item.BootTimeBaseline = $readByVm[[string]$item.VMName]
                    $item.BootTimeObserved = $readByVm[[string]$item.VMName]
                    $item.UptimeBaselineSeconds = Get-RuntimePropertyValue -InputObject $readResult -Name 'UptimeSeconds'
                    $item.UptimeObservedSeconds = $item.UptimeBaselineSeconds
                }
            }

            $stillMissing = @($batchItems | Where-Object { $_.ValidationRequired -and $null -eq $_.BootTimeBaseline })
            if ($stillMissing.Count -eq 0) {
                break
            }

            $context = [pscustomobject]@{
                Stage = 'BaselineShortfall'
                BatchNumber = $batchNumber
                VMNames = @($stillMissing | ForEach-Object { $_.VMName })
            }
            $decision = & $DecisionPromptScript $context
            if ($decision -eq 'RETRY') {
                continue
            }
            elseif ($decision -eq 'CONTINUE') {
                foreach ($item in $stillMissing) {
                    $item.ValidationRequired = $false
                }
                break
            }
            else {
                $aborted = $true
                break
            }
        }

        if ($aborted) {
            foreach ($item in $batchItems) {
                $alreadyRecorded = @($records | Where-Object { $_.vmName -eq $item.VMName }).Count -gt 0
                if (-not $alreadyRecorded) {
                    $records += New-RebootActionRecord -VMName $item.VMName -Action 'NotStartedAfterAbort' -ErrorMessage $item.LastErrorMessage -RebootReason $item.RebootReason -BatchNumber $batchNumber -Sequence $item.Sequence -ValidationStatus 'NotStartedAfterAbort' -OperatorDecision 'ABORT' -AttemptCount $item.AttemptCount -LastErrorMessage $item.LastErrorMessage
                }
            }
            continue
        }

        # --- initiate reboots for the whole batch ---
        $restartResults = @(& $InitiateRebootScript $batchItems)
        $restartByVm = @{}
        foreach ($restartResult in @($restartResults)) {
            if (-not $restartByVm.ContainsKey([string]$restartResult.VMName)) {
                $restartByVm[[string]$restartResult.VMName] = $restartResult
            }
        }

        # A missing result counts as a failed initiation: silently dropping the VM here would
        # leave it out of reboot-actions.json and let the run exit 0 without ever rebooting it.
        $initFailed = @($batchItems | Where-Object {
            $result = $restartByVm[[string]$_.VMName]
            $null -eq $result -or -not [string]::IsNullOrWhiteSpace([string]$result.Error)
        })

        if ($initFailed.Count -gt 0) {
            $context = [pscustomobject]@{
                Stage = 'InitiationError'
                BatchNumber = $batchNumber
                VMNames = @($initFailed | ForEach-Object { $_.VMName })
            }
            $initDecision = & $DecisionPromptScript $context
            if ($initDecision -eq 'ABORT') {
                $aborted = $true
            }
            foreach ($item in $initFailed) {
                $result = $restartByVm[[string]$item.VMName]
                $initErrorMessage = if ($null -eq $result) { 'No reboot initiation result was returned.' } else { [string]$result.Error }
                $operatorDecision = if ($aborted) { 'ABORT' } else { 'CONTINUE' }
                $records += New-RebootActionRecord -VMName $item.VMName -Action 'Failed' -ErrorMessage $initErrorMessage -RebootReason $item.RebootReason -BatchNumber $batchNumber -Sequence $item.Sequence -ValidationStatus 'InitiationError' -OperatorDecision $operatorDecision -AttemptCount $item.AttemptCount -LastErrorMessage $initErrorMessage
                $item.Initiated = $false
            }
        }

        foreach ($item in $batchItems) {
            $restartResult = $restartByVm[[string]$item.VMName]
            $restartSucceeded = ($null -ne $restartResult -and [string]::IsNullOrWhiteSpace([string]$restartResult.Error))
            if ($restartSucceeded) {
                $item.Initiated = $true
                $item.ProcessId = $restartResult.ProcessId
            }
        }

        # --- validation / boot-time gate ---
        foreach ($item in @($batchItems | Where-Object { $_.Initiated -and -not $_.ValidationRequired })) {
            $records += New-RebootActionRecord -VMName $item.VMName -Action 'Initiated' -ProcessId $item.ProcessId -RebootReason $item.RebootReason -BatchNumber $batchNumber -Sequence $item.Sequence -BootTimeBaseline $null -BootTimeObserved $null -ValidationStatus 'Unverified' -OperatorDecision 'CONTINUE' -AttemptCount $item.AttemptCount -TimeoutCount $item.TimeoutCount -LastErrorMessage $item.LastErrorMessage
        }

        $pendingItems = @($batchItems | Where-Object { $_.Initiated -and $_.ValidationRequired })

        if ($pendingItems.Count -gt 0) {
            $validationAborted = $false
            # Only the first wait pays the grace: on RETRY the batch has already been down for a
            # full timeout period, so there is nothing left to wait out before reading again.
            $waitGraceSeconds = $GraceSeconds
            while ($true) {
                $wait = Wait-RebootBatchBootTimes -Items $pendingItems -WaitTimeoutSeconds $WaitTimeoutSeconds -PollSeconds $PollSeconds -GraceSeconds $waitGraceSeconds -ReadBootTimeScript $ReadBootTimeScript -SleepScript $SleepScript
                $waitGraceSeconds = 0
                $records += $wait.Records
                $pendingItems = $wait.Pending

                if ($pendingItems.Count -eq 0) {
                    break
                }

                foreach ($item in $pendingItems) {
                    $item.TimeoutCount++
                }

                $context = [pscustomobject]@{
                    Stage = 'WaitTimeout'
                    BatchNumber = $batchNumber
                    VMNames = @($pendingItems | ForEach-Object { $_.VMName })
                    WaitSeconds = $WaitTimeoutSeconds
                }
                $decision = & $DecisionPromptScript $context

                if ($decision -eq 'RETRY') {
                    continue
                }
                elseif ($decision -eq 'CONTINUE') {
                    foreach ($item in $pendingItems) {
                        $records += New-RebootActionRecord -VMName $item.VMName -Action 'Initiated' -ProcessId $item.ProcessId -RebootReason $item.RebootReason -BatchNumber $batchNumber -Sequence $item.Sequence -BootTimeBaseline $item.BootTimeBaseline -BootTimeObserved $item.BootTimeObserved -UptimeBaselineSeconds $item.UptimeBaselineSeconds -UptimeObservedSeconds $item.UptimeObservedSeconds -ValidationStatus 'Unverified' -OperatorDecision 'CONTINUE' -AttemptCount $item.AttemptCount -TimeoutCount $item.TimeoutCount -LastErrorMessage $item.LastErrorMessage
                    }
                    break
                }
                else {
                    foreach ($item in $pendingItems) {
                        $records += New-RebootActionRecord -VMName $item.VMName -Action 'Initiated' -ProcessId $item.ProcessId -RebootReason $item.RebootReason -BatchNumber $batchNumber -Sequence $item.Sequence -BootTimeBaseline $item.BootTimeBaseline -BootTimeObserved $item.BootTimeObserved -UptimeBaselineSeconds $item.UptimeBaselineSeconds -UptimeObservedSeconds $item.UptimeObservedSeconds -ValidationStatus 'Timeout' -OperatorDecision 'ABORT' -AttemptCount $item.AttemptCount -TimeoutCount $item.TimeoutCount -LastErrorMessage $item.LastErrorMessage
                    }
                    $validationAborted = $true
                    break
                }
            }

            if ($validationAborted) {
                $aborted = $true
                continue
            }
        }
    }

    # Sort-Object is not stable in Windows PowerShell 5.1, so batchNumber alone would scramble
    # the VM order inside a batch; sequence is the original target order and breaks every tie.
    return @($records | Sort-Object batchNumber, sequence)
}

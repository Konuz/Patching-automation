Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-ThrottledJobErrorResult {
    param(
        $InputObject,
        [string]$ErrorMessage,
        [string]$ErrorKind,
        [bool]$RejectedBeforeStart = $false
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
        ErrorKind = $ErrorKind
        RejectedBeforeStart = $RejectedBeforeStart
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
                    # The one job failure that provably ran nothing: no child process exists.
                    $results += New-ThrottledJobErrorResult -InputObject $item -ErrorMessage ('Start-Job failed: {0}' -f $_.Exception.Message) -ErrorKind 'JobNotStarted' -RejectedBeforeStart $true
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
                # The child may have finished its guest call before it was stopped; all this
                # process knows is that no answer came back, so the outcome is lost, not refused.
                $results += New-ThrottledJobErrorResult -InputObject $entry.Input -ErrorMessage ('Job timed out after {0} seconds.' -f $JobTimeoutSeconds) -ErrorKind 'JobResultLost'
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
                        $results += New-ThrottledJobErrorResult -InputObject $entry.Input -ErrorMessage 'Receive-Job returned no output.' -ErrorKind 'JobResultLost'
                    }
                    else {
                        $results += $output
                    }
                }
                catch {
                    $results += New-ThrottledJobErrorResult -InputObject $entry.Input -ErrorMessage ('Receive-Job failed: {0}' -f $_.Exception.Message) -ErrorKind 'JobResultLost'
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
        $Payload = $null,
        [string]$ResultKind = $null,
        $ErrorMetadata = $null
    )

    return [pscustomobject]@{
        Sequence = Get-RuntimePropertyValue -InputObject $InputObject -Name 'Sequence'
        VMName = Get-RuntimePropertyValue -InputObject $InputObject -Name 'VMName'
        Payload = $Payload
        Error = $ErrorMessage
        ResultKind = $ResultKind
        ErrorKind = Get-RuntimePropertyValue -InputObject $ErrorMetadata -Name 'ErrorKind'
        RejectedBeforeStart = [bool](Get-RuntimePropertyValue -InputObject $ErrorMetadata -Name 'RejectedBeforeStart' -DefaultValue $false)
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
        [scriptblock]$SleepScript = { param([int]$Seconds) Start-Sleep -Seconds $Seconds },
        [scriptblock]$NowScript = { Get-Date },
        [scriptblock]$IsTransientErrorScript = { param($ErrorRecord) $false },
        [scriptblock]$GetErrorMetadataScript = { param($ErrorRecord, $Stage) [pscustomobject]@{ ErrorKind = $null; RejectedBeforeStart = $false } }
    )

    $getErrorMetadata = {
        param($ErrorRecord, $Stage)
        try {
            $metadata = & $GetErrorMetadataScript $ErrorRecord $Stage
            if ($null -ne $metadata) {
                return $metadata
            }
        }
        catch { }
        return [pscustomobject]@{ ErrorKind = $null; RejectedBeforeStart = $false }
    }

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

    $collectEntry = {
        param($Entry)

        $payload = $null
        $errorRecord = $null
        try {
            $payload = & $CompleteScript $Entry.Handle
        }
        catch {
            $errorRecord = $_
            Write-Warning ('Could not collect artifacts for {0}: {1}' -f (Get-RuntimePropertyValue -InputObject $Entry.Item -Name 'VMName'), $_.Exception.Message)
        }

        return [pscustomobject]@{
            Payload = $payload
            ErrorRecord = $errorRecord
        }
    }

    while ($pending.Count -gt 0 -or $inFlight.Count -gt 0) {
        # ONE start per iteration, then straight on to the guests that are already running.
        # Draining the whole queue first looks cheaper - StartProgramInGuest returns a process id
        # without waiting - but each start is still several SOAP round trips plus three file
        # transfers, so at fleet scale the first guest can be minutes into its work, or finished
        # and gone from vSphere's process list, before anything looks at it. Interleaving keeps
        # the first poll close behind the first start whatever MaxInFlight is.
        if ($pending.Count -gt 0 -and $inFlight.Count -lt $MaxInFlight) {
            $item = $pending.Dequeue()
            try {
                $handle = & $StartScript $item
                $inFlight += [pscustomobject]@{
                    Item = $item
                    Handle = $handle
                    StartedAt = & $NowScript
                }
            }
            catch {
                # There is no job boundary around a start, so a throwing guest would end the
                # whole phase. Every failure has to become this VM's error instead.
                # A lost start response does not prove the guest rejected the request. Retrying
                # here could launch a second agent; only polling the existing handle is retryable.
                $errorMetadata = & $getErrorMetadata $_ 'Start'
                $results += New-FleetErrorResult -InputObject $item -ErrorMessage ('Agent start failed: {0}' -f $_.Exception.Message) -ResultKind 'StartError' -ErrorMetadata $errorMetadata
            }
        }

        $kept = @()
        foreach ($entry in @($inFlight)) {
            # The clock is read per item, not once for the whole wave. A single reading taken at
            # the top would be minutes old by the time a long wave of polls reaches the last
            # entry, so a VM would be judged against a deadline that had already passed.
            $now = & $NowScript
            if (($now - $entry.StartedAt).TotalSeconds -ge $ItemTimeoutSeconds) {
                # Harvest anyway. status.json is the primary result (see CLAUDE.md), and the
                # job-based path this replaces always downloaded the artifacts even when the
                # process result timed out. Dropping them here would turn a guest run that
                # actually finished into a reported failure and throw away the only per-VM
                # diagnostics. The timeout error stands regardless of what the harvest finds.
                $timeoutCollection = & $collectEntry $entry
                $timeoutPayload = $timeoutCollection.Payload
                $collectionError = $timeoutCollection.ErrorRecord
                $collectionMetadata = if ($null -eq $collectionError) { $null } else { & $getErrorMetadata $collectionError 'Collect' }
                if ($null -ne $collectionMetadata -and (Test-CredentialRefusalErrorKind -ErrorKind ([string](Get-RuntimePropertyValue -InputObject $collectionMetadata -Name 'ErrorKind')))) {
                    $results += New-FleetErrorResult -InputObject $entry.Item -ErrorMessage $collectionError.Exception.Message -Payload $timeoutPayload -ResultKind 'CredentialRecovery' -ErrorMetadata $collectionMetadata
                }
                else {
                    $results += New-FleetErrorResult -InputObject $entry.Item -ErrorMessage ('Agent run timed out after {0} seconds.' -f $ItemTimeoutSeconds) -Payload $timeoutPayload -ResultKind 'Timeout'
                }
                continue
            }

            try {
                $pollCompleted = [bool](& $PollScript $entry.Handle)
            }
            catch {
                $pollError = $_
                $isTransient = $false
                try {
                    $isTransient = [bool](& $IsTransientErrorScript $pollError)
                }
                catch {
                    $isTransient = $false
                }

                if ($isTransient) {
                    # Keep the same handle and StartedAt. The next loop iteration is the
                    # existing poll cadence, so a transient GuestOps failure cannot launch
                    # a second agent or extend the original deadline.
                    $kept += $entry
                    continue
                }

                # A permanent poll error ends this VM, but its artifacts are still the best
                # available evidence. The collection helper deliberately cannot replace the
                # original poll error in the result.
                $errorCollection = & $collectEntry $entry
                $errorMetadata = & $getErrorMetadata $pollError 'Poll'
                $results += New-FleetErrorResult -InputObject $entry.Item -ErrorMessage $pollError.Exception.Message -Payload $errorCollection.Payload -ResultKind 'PermanentPoll' -ErrorMetadata $errorMetadata
                continue
            }

            if ($pollCompleted) {
                try {
                    $results += [pscustomobject]@{
                        Sequence = Get-RuntimePropertyValue -InputObject $entry.Item -Name 'Sequence'
                        VMName = Get-RuntimePropertyValue -InputObject $entry.Item -Name 'VMName'
                        Payload = (& $CompleteScript $entry.Handle)
                        Error = $null
                    }
                }
                catch {
                    $errorMetadata = & $getErrorMetadata $_ 'Completion'
                    $results += New-FleetErrorResult -InputObject $entry.Item -ErrorMessage $_.Exception.Message -ResultKind 'CompletionError' -ErrorMetadata $errorMetadata
                }
                continue
            }

            $kept += $entry
        }

        $inFlight = @($kept)
        # Sleep only when there is nothing else to do. With free slots and targets still waiting,
        # a poll interval spent idle is a poll interval the next guest was not started in - and
        # the queue is what decides how long the whole phase takes.
        $hasStartableWork = ($pending.Count -gt 0 -and $inFlight.Count -lt $MaxInFlight)
        if ($inFlight.Count -gt 0 -and -not $hasStartableWork) {
            & $SleepScript $PollSeconds
        }
    }

    return @($results)
}

function Test-IsTerminalAgentOutcome {
    param([string]$Outcome)

    # Apply outcomes only. 'SearchOnly' belongs to discovery, which has its own record
    # builder, so accepting it here would only ever mask a mismatched status.json.
    return ($Outcome -in @('InstallSucceeded', 'InstallSucceededWithErrors', 'InstallFailed', 'DownloadFailed', 'NoSelectedUpdates', 'NoApplicableUpdates'))
}

# One shape for every apply branch. Four hand-written literals drifted apart before this
# existed: a property one branch happened not to set is a terminating error under StrictMode for
# whoever reads the collection back, and a field silently missing from the timeout branch is a
# field the summary and the reboot selection disagree about. A step that did not happen gets an
# explicit $null or an empty array - never a missing property.
function New-ApplyResultRecord {
    param(
        [string]$VMName,
        [string]$Action = 'Install',
        [string]$Outcome,
        $InstallResult = $null,
        [string]$Reason = '',
        $RoleFlags = $null,
        $RebootRequired = $null,
        $AgentCompletionConfirmed = $null,
        [string]$AgentCompletionReason = '',
        $CleanupStatus = $null,
        $CleanupReason = $null,
        [string[]]$Errors = @(),
        # True when this guest was already busy with another run of this tool, or carried an
        # unreconciled trace of one. Absolute: no reboot and no further cycle for this VM.
        [bool]$GuestRunConflict = $false,
        [string[]]$MissingUpdateKeys = @(),
        [bool]$SelectionDrift = $false,
        [bool]$RequiresVerification = $false
    )

    return [pscustomobject]@{
        vmName = $VMName
        action = $Action
        outcome = $Outcome
        installResult = $InstallResult
        reason = $Reason
        roleFlags = $RoleFlags
        rebootRequired = $RebootRequired
        agentCompletionConfirmed = $AgentCompletionConfirmed
        agentCompletionReason = $AgentCompletionReason
        cleanupStatus = $CleanupStatus
        cleanupReason = $CleanupReason
        guestRunConflict = $GuestRunConflict
        missingUpdateKeys = @($MissingUpdateKeys)
        selectionDrift = $SelectionDrift
        requiresVerification = $RequiresVerification
        errors = @($Errors)
    }
}

function New-ApplyResultFromCycle {
    param(
        [string]$VMName,
        $Cycle
    )

    # Reads status.json only, so it lives here rather than in the orchestrator: the
    # orchestrator ends in exit and cannot be dot-sourced by the offline tests. It uses
    # Get-ObjectPropertyValue from GuestOpsLib, which both the orchestrator and the runtime
    # test harness dot-source before this file.
    $status = Get-RuntimePropertyValue -InputObject $Cycle -Name 'Status'
    $agentResult = Get-RuntimePropertyValue -InputObject $Cycle -Name 'AgentResult'
    $outcome = Get-ObjectPropertyValue -InputObject $status -Path @('outcome')
    $finishedAt = [string](Get-ObjectPropertyValue -InputObject $status -Path @('finishedAt'))
    $installResult = Get-ObjectPropertyValue -InputObject $status -Path @('installResult', 'result')
    $pendingAfter = [bool](Get-ObjectPropertyValue -InputObject $status -Path @('pendingRebootAfter', 'isPending') -DefaultValue $false)
    $rebootFromInstall = [bool](Get-ObjectPropertyValue -InputObject $status -Path @('installResult', 'rebootRequired') -DefaultValue $false)
    $rebootRequired = ($pendingAfter -or $rebootFromInstall)
    $errors = @(Get-ObjectPropertyValue -InputObject $status -Path @('errors') -DefaultValue @())
    $agentCompletionConfirmed = [bool](Get-RuntimePropertyValue -InputObject $Cycle -Name 'AgentCompletionConfirmed' -DefaultValue $false)
    $agentCompletionReason = [string](Get-RuntimePropertyValue -InputObject $Cycle -Name 'AgentCompletionReason' -DefaultValue '')
    # The agent reports this when the guest was already busy with another run of this tool, or
    # carried an unreconciled trace of one. It has to survive every branch below, including the
    # failure branches, because it is what blocks the reboot and the next round for this VM.
    $guestRunConflict = [bool](Get-ObjectPropertyValue -InputObject $status -Path @('guestRunConflict') -DefaultValue $false)
    # Drift is an explicitly incomplete execution, not a failure: the approved updates that were
    # still on offer went in, the ones that had moved did not, and somebody has to look at the
    # difference. It must survive every branch below, including the failure branches.
    $missingUpdateKeys = @(@(Get-ObjectPropertyValue -InputObject $status -Path @('missingUpdateKeys') -DefaultValue @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $selectionDrift = [bool](Get-ObjectPropertyValue -InputObject $status -Path @('selectionDrift') -DefaultValue $false) -or ($missingUpdateKeys.Count -gt 0)
    $requiresVerification = [bool](Get-ObjectPropertyValue -InputObject $status -Path @('requiresVerification') -DefaultValue $false) -or $selectionDrift
    if ($guestRunConflict) {
        $conflictReason = [string](Get-ObjectPropertyValue -InputObject $status -Path @('guestRunConflictReason'))
        if ([string]::IsNullOrWhiteSpace($conflictReason)) {
            $conflictReason = 'The guest reported that another PatchingGuestOps run holds it.'
        }
        $errors += ('Guest run conflict: {0}' -f $conflictReason)
    }

    if (-not $agentCompletionConfirmed) {
        $reason = 'Agent completion was not confirmed; apply guest process did not complete.'
        if (-not [string]::IsNullOrWhiteSpace($agentCompletionReason)) {
            $reason = '{0} {1}' -f $reason, $agentCompletionReason
        }
        $errors += $reason
        return New-ApplyResultRecord -VMName $VMName -Outcome 'Failed' -InstallResult $installResult -Reason $reason `
            -RoleFlags (Get-ObjectPropertyValue -InputObject $status -Path @('roleFlags')) -RebootRequired $rebootRequired `
            -AgentCompletionConfirmed $false -AgentCompletionReason $agentCompletionReason `
            -CleanupStatus (Get-RuntimePropertyValue -InputObject $Cycle -Name 'CleanupStatus') -CleanupReason (Get-RuntimePropertyValue -InputObject $Cycle -Name 'CleanupReason') `
            -Errors $errors -GuestRunConflict $guestRunConflict -MissingUpdateKeys $missingUpdateKeys -SelectionDrift $selectionDrift -RequiresVerification $requiresVerification
    }

    if ($null -eq $agentResult -or -not $agentResult.Completed) {
        # vSphere keeps finished process info only briefly, and the fleet starts its guests
        # sequentially, so a guest that really did finish can come back with no process
        # result. status.json is the primary apply result (see CLAUDE.md) and discovery
        # already resolves this the same way. Both halves are required: the agent saves
        # status.json eagerly, so a terminal outcome can be present while the stage that
        # stamps finishedAt never ran.
        if ((Test-IsTerminalAgentOutcome -Outcome ([string]$outcome)) -and -not [string]::IsNullOrWhiteSpace($finishedAt)) {
            Write-Warning ('Apply guest process result was lost for {0}. status.json has a terminal outcome and finishedAt, so it remains the primary apply result.' -f $VMName)
        }
        else {
            $reason = 'Apply guest process did not complete.'
            $errors += $reason
            return New-ApplyResultRecord -VMName $VMName -Outcome 'Failed' -InstallResult $installResult -Reason $reason `
                -RoleFlags (Get-ObjectPropertyValue -InputObject $status -Path @('roleFlags')) -RebootRequired $rebootRequired `
                -AgentCompletionConfirmed $agentCompletionConfirmed -AgentCompletionReason $agentCompletionReason `
                -CleanupStatus (Get-RuntimePropertyValue -InputObject $Cycle -Name 'CleanupStatus') -CleanupReason (Get-RuntimePropertyValue -InputObject $Cycle -Name 'CleanupReason') `
                -Errors $errors -GuestRunConflict $guestRunConflict -MissingUpdateKeys $missingUpdateKeys -SelectionDrift $selectionDrift -RequiresVerification $requiresVerification
        }
    }
    # A partial install (WUA ResultCode 3) exits non-zero but is authoritative in
    # status.json as 'InstallSucceededWithErrors'. Preserve that outcome so the summary
    # can distinguish it from a total failure; only an unrecognized non-zero exit fails.
    elseif ($null -ne $agentResult.ExitCode -and [int]$agentResult.ExitCode -ne 0 -and $outcome -ne 'InstallSucceededWithErrors') {
        $reason = 'Apply guest process exited with code {0}.' -f $agentResult.ExitCode
        $errors += $reason
        return New-ApplyResultRecord -VMName $VMName -Outcome 'Failed' -InstallResult $installResult -Reason $reason `
            -RoleFlags (Get-ObjectPropertyValue -InputObject $status -Path @('roleFlags')) -RebootRequired $rebootRequired `
            -AgentCompletionConfirmed $agentCompletionConfirmed -AgentCompletionReason $agentCompletionReason `
            -CleanupStatus (Get-RuntimePropertyValue -InputObject $Cycle -Name 'CleanupStatus') -CleanupReason (Get-RuntimePropertyValue -InputObject $Cycle -Name 'CleanupReason') `
            -Errors $errors -GuestRunConflict $guestRunConflict -MissingUpdateKeys $missingUpdateKeys -SelectionDrift $selectionDrift -RequiresVerification $requiresVerification
    }

    return New-ApplyResultRecord -VMName $VMName -Outcome $outcome -InstallResult $installResult `
        -RoleFlags (Get-ObjectPropertyValue -InputObject $status -Path @('roleFlags')) -RebootRequired $rebootRequired `
        -AgentCompletionConfirmed $agentCompletionConfirmed -AgentCompletionReason $agentCompletionReason `
        -CleanupStatus (Get-RuntimePropertyValue -InputObject $Cycle -Name 'CleanupStatus') -CleanupReason (Get-RuntimePropertyValue -InputObject $Cycle -Name 'CleanupReason') `
        -Errors $errors -GuestRunConflict $guestRunConflict -MissingUpdateKeys $missingUpdateKeys -SelectionDrift $selectionDrift -RequiresVerification $requiresVerification
}

function Add-OutstandingVerificationKeys {
    param(
        [hashtable]$Outstanding,
        $ApplyResults
    )

    # An approved key that WUA no longer offered. It stays outstanding until a later discovery
    # shows it is genuinely not applicable to that VM any more - see
    # Resolve-OutstandingVerificationKeys. Until then the run is explicitly incomplete: it
    # installed less than was approved, and nobody has established that this was harmless.
    foreach ($result in @($ApplyResults)) {
        $vmName = [string](Get-RuntimePropertyValue -InputObject $result -Name 'vmName')
        if ([string]::IsNullOrWhiteSpace($vmName)) {
            continue
        }

        foreach ($key in @(Get-RuntimePropertyValue -InputObject $result -Name 'missingUpdateKeys' -DefaultValue @())) {
            $keyText = ([string]$key).Trim()
            if ([string]::IsNullOrWhiteSpace($keyText)) {
                continue
            }

            if (-not $Outstanding.ContainsKey($vmName)) {
                $Outstanding[$vmName] = @{}
            }
            $Outstanding[$vmName][$keyText] = $true
        }
    }
}

function Resolve-OutstandingVerificationKeys {
    param(
        [hashtable]$Outstanding,
        $DiscoveryRecords
    )

    # Matched on the EXACT identity key, not the bare updateId. A key that has disappeared from
    # the VM's update list is no longer applicable, and that is the verification: the approved
    # update this run could not install is not needed. A revised package reappearing under a new
    # revision is a different thing entirely - it is an ordinary applicable update, it keeps the
    # VM pending, and it goes through a fresh plan and a normal operator selection rather than
    # being quietly accepted as a substitute for the revision that was approved.
    foreach ($record in @($DiscoveryRecords)) {
        $vmName = [string](Get-RuntimePropertyValue -InputObject $record -Name 'vmName')
        if ([string]::IsNullOrWhiteSpace($vmName) -or -not $Outstanding.ContainsKey($vmName)) {
            continue
        }

        # A discovery that failed says nothing about applicability, so it resolves nothing.
        if (@(Get-ObjectPropertyValue -InputObject $record -Path @('errors') -DefaultValue @() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
            continue
        }

        $presentKeys = @{}
        foreach ($update in @(Get-ObjectPropertyValue -InputObject $record -Path @('updates') -DefaultValue @())) {
            $identityKey = [string](Get-ObjectPropertyValue -InputObject $update -Path @('identityKey'))
            if (-not [string]::IsNullOrWhiteSpace($identityKey)) {
                $presentKeys[$identityKey] = $true
            }
        }

        foreach ($outstandingKey in @($Outstanding[$vmName].Keys)) {
            if (-not $presentKeys.ContainsKey([string]$outstandingKey)) {
                $Outstanding[$vmName].Remove([string]$outstandingKey)
            }
        }

        if ($Outstanding[$vmName].Count -eq 0) {
            $Outstanding.Remove($vmName)
        }
    }
}

function Get-OutstandingVerificationText {
    param([hashtable]$Outstanding)

    $lines = @()
    foreach ($vmName in @($Outstanding.Keys | Sort-Object)) {
        $lines += ('{0}: {1}' -f $vmName, ((@($Outstanding[$vmName].Keys) | Sort-Object) -join ', '))
    }

    return ($lines -join '; ')
}

function Test-IsApplyResultError {
    param($ApplyResult)

    if ($null -eq $ApplyResult) {
        return $true
    }

    if (@(Get-ObjectPropertyValue -InputObject $ApplyResult -Path @('errors') -DefaultValue @()).Count -gt 0) {
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

function Test-ApplyResultsRequireVerification {
    param($ApplyResults)

    # Separate from Test-ApplyResultsSuccessful on purpose. "Installed less than was approved"
    # and "an install failed" are different facts, and folding them into one flag would either
    # hide the drift or report a working install as broken. Both make the run exit 1; only the
    # second one means something went wrong on the guest.
    foreach ($result in @($ApplyResults)) {
        if ([bool](Get-RuntimePropertyValue -InputObject $result -Name 'requiresVerification' -DefaultValue $false)) {
            return $true
        }
    }

    return $false
}

function Get-ApplyResultDriftSummary {
    param($ApplyResults)

    # vmName -> the approved keys that were no longer on offer. Used by the summary and by the
    # resume path, both of which have to name them rather than say "something drifted".
    $summary = @()
    foreach ($result in @($ApplyResults)) {
        $keys = @(@(Get-RuntimePropertyValue -InputObject $result -Name 'missingUpdateKeys' -DefaultValue @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($keys.Count -eq 0) {
            continue
        }

        $summary += [pscustomobject]@{
            vmName = [string](Get-RuntimePropertyValue -InputObject $result -Name 'vmName')
            missingUpdateKeys = @($keys)
        }
    }

    return @($summary)
}
function Test-CredentialRefusalErrorKind {
    param([string]$ErrorKind)

    # Only an operator decision counts as a refusal. A validation attempt that merely FAILED -
    # VMware Tools down mid-reboot is the common case, and Assert-VMReadyForGuestOps throws on
    # exactly that - must keep its ordinary transient handling, or a guest that rebooted
    # correctly gets recorded as a credential failure with no prompt the operator could answer.
    return ($ErrorKind -eq 'CredentialsSkipped' -or $ErrorKind -eq 'CredentialsAborted')
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
    $excludedByVmName = @{}
    $discoveryErrorByVmName = @{}
    foreach ($record in @($DiscoveryRecords)) {
        $vmName = [string](Get-RuntimePropertyValue -InputObject $record -Name 'vmName')
        if ([string]::IsNullOrWhiteSpace($vmName)) {
            continue
        }

        $recordErrors = @(Get-ObjectPropertyValue -InputObject $record -Path @('errors') -DefaultValue @() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($recordErrors.Count -gt 0) {
            $discoveryErrorByVmName[$vmName] = $true
        }

        if ([bool](Get-ObjectPropertyValue -InputObject $record -Path @('roleFlags', 'failoverCluster') -DefaultValue $false)) {
            $excludedByVmName[$vmName] = $true
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

        if ($discoveryErrorByVmName.ContainsKey($vmName)) {
            continue
        }

        # A guest that refused this run - because another one holds it, or because it carries an
        # unreconciled trace of one - must not be restarted. The other run may be mid-install,
        # and a restart across a half-written update is exactly what the guard exists to stop.
        # This holds even though the refused agent's own process has already ended.
        if ([bool](Get-ObjectPropertyValue -InputObject $result -Path @('guestRunConflict') -DefaultValue $false)) {
            continue
        }

        # Saved plans have no discovery records; skipped apply results retain roleFlags.
        if ($excludedByVmName.ContainsKey($vmName) -or [bool](Get-ObjectPropertyValue -InputObject $result -Path @('roleFlags', 'failoverCluster') -DefaultValue $false)) {
            continue
        }

        if ((Get-RuntimePropertyValue -InputObject $result -Name 'action') -eq 'Install' -and
            -not [bool](Get-RuntimePropertyValue -InputObject $result -Name 'agentCompletionConfirmed' -DefaultValue $false)) {
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
        [string]$LastErrorMessage = $null,
        [string]$ErrorKind = $null,
        [bool]$RejectedBeforeStart = $false
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
        errorKind = if ([string]::IsNullOrWhiteSpace($ErrorKind)) { $null } else { $ErrorKind }
        rejectedBeforeStart = $RejectedBeforeStart
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
        # An operator skip used to count as success here. It cannot: every record in this list is
        # a restart the VM was found to REQUIRE, so refusing it leaves updates half-applied and
        # the run has to say so. The state map calls that VM PendingReboot rather than Failed -
        # the install may well have worked - but either way the run does not exit 0.
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
        [string]$OperatorDecision,
        [bool]$ExplicitSelectionOnly = $false,
        [bool]$NonInteractive = $false
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

    # Both of these stop before the prompt rather than at it. Everything past this point
    # needs an operator, and a run that cannot produce one must end with an exit code
    # instead of blocking forever on Read-Host.
    if ($ExplicitSelectionOnly) {
        return [pscustomobject]@{
            Action = 'Stop'
            AllGreen = $false
            NeedsOperatorDecision = $false
            PendingVMNames = $pendingVMNames
            Reason = 'Stopping after the first round: -SelectedUpdateKeys names revisions that do not appear in a later round, so there is nothing to carry forward.'
        }
    }

    if ($NonInteractive) {
        return [pscustomobject]@{
            Action = 'Stop'
            AllGreen = $false
            NeedsOperatorDecision = $false
            PendingVMNames = $pendingVMNames
            Reason = 'Stopping with updates still pending: -SkipConfirmation leaves nobody to answer whether to run another round.'
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

# The states a run may end on. An allow-list, not a deny-list of Pending/Failed: every state
# added since - NeedsReview, PendingReboot - would otherwise have passed this test by default,
# and so would a typo. Excluded is allowed but means "outside the scope of patching", not patched.
$script:PatchRunSuccessfulStates = @('Green', 'GreenByOperatorChoice', 'Excluded')

function Test-PatchRunAllGreen {
    param(
        [hashtable]$StateMap,
        # Every VM this run was supposed to reach. A VM missing from the map has no verdict at
        # all, and no verdict is not success: it is the shape a VM takes when it dropped out of
        # the round loop without anyone recording why.
        [string[]]$ExpectedVMNames = @()
    )

    foreach ($vmName in @($StateMap.Keys)) {
        if ([string]$StateMap[$vmName].state -notin $script:PatchRunSuccessfulStates) {
            return $false
        }
    }

    foreach ($expectedVMName in @($ExpectedVMNames)) {
        $expectedKey = [string]$expectedVMName
        if ([string]::IsNullOrWhiteSpace($expectedKey)) {
            continue
        }

        if (-not $StateMap.ContainsKey($expectedKey)) {
            return $false
        }

        if ([string]$StateMap[$expectedKey].state -notin $script:PatchRunSuccessfulStates) {
            return $false
        }
    }

    return $true
}

function Get-ConfirmedRebootVMNames {
    param($RebootActions)

    # Only a restart this tool watched come back counts. An unverified or forced CONTINUE, a
    # skipped reboot and a failed initiation all leave the guest in a state nobody measured.
    $names = @()
    foreach ($record in @($RebootActions)) {
        if ([string](Get-RuntimePropertyValue -InputObject $record -Name 'action') -ne 'Initiated') {
            continue
        }
        if ([string](Get-RuntimePropertyValue -InputObject $record -Name 'validationStatus') -ne 'Confirmed') {
            continue
        }
        $vmName = [string](Get-RuntimePropertyValue -InputObject $record -Name 'vmName')
        if (-not [string]::IsNullOrWhiteSpace($vmName)) {
            $names += $vmName
        }
    }

    return @($names)
}

function Get-NextRoundTargetVMNames {
    param(
        $ApplyResults,
        $RebootActions = @()
    )

    # A deduplicated union of two different reasons to look again, because either alone loses a
    # VM. Apply alone misses the machine that had nothing to install but a pending reboot
    # (action = NoSelectedUpdates): it restarts and then never gets re-discovered, so its state
    # stays whatever the PRE-reboot discovery said. Reboot alone misses the machine that
    # installed updates and needed no restart.
    $names = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $conflicted = @{}

    foreach ($result in @($ApplyResults)) {
        $vmName = [string](Get-RuntimePropertyValue -InputObject $result -Name 'vmName')
        if ([string]::IsNullOrWhiteSpace($vmName)) {
            continue
        }

        # A guest this run was refused on stays refused, whatever else happened to it.
        if ([bool](Get-RuntimePropertyValue -InputObject $result -Name 'guestRunConflict' -DefaultValue $false)) {
            $conflicted[$vmName] = $true
            continue
        }

        if ((Get-RuntimePropertyValue -InputObject $result -Name 'action') -ne 'Install') {
            continue
        }

        if (-not [bool](Get-RuntimePropertyValue -InputObject $result -Name 'agentCompletionConfirmed' -DefaultValue $false)) {
            continue
        }

        if (-not $seen.ContainsKey($vmName)) {
            $seen[$vmName] = $true
            $names.Add($vmName)
        }
    }

    foreach ($vmName in @(Get-ConfirmedRebootVMNames -RebootActions $RebootActions)) {
        if ($conflicted.ContainsKey($vmName) -or $seen.ContainsKey($vmName)) {
            continue
        }
        $seen[$vmName] = $true
        $names.Add($vmName)
    }

    return @($names.ToArray())
}

function Set-PatchRunPendingRebootStates {
    param(
        [hashtable]$StateMap,
        $RebootTargets,
        $RebootActions = @()
    )

    # A VM that needs a restart is not finished, whatever the pre-apply discovery said about its
    # update list. That discovery was taken BEFORE the reboot, so a Green read off it would be a
    # verdict about a machine in a different state - and a newer boot time on its own says
    # nothing about whether updates remain. PendingReboot holds until a fresh discovery decides.
    #
    # A confirmed restart is the one case that does not stay here: that VM becomes a target of
    # the next round, and its real verdict comes from the discovery that round runs.
    $confirmed = @{}
    foreach ($vmName in @(Get-ConfirmedRebootVMNames -RebootActions $RebootActions)) {
        $confirmed[$vmName] = $true
    }

    $reasonByVm = @{}
    foreach ($record in @($RebootActions)) {
        $recordVmName = [string](Get-RuntimePropertyValue -InputObject $record -Name 'vmName')
        if ([string]::IsNullOrWhiteSpace($recordVmName)) {
            continue
        }
        $action = [string](Get-RuntimePropertyValue -InputObject $record -Name 'action')
        $validation = [string](Get-RuntimePropertyValue -InputObject $record -Name 'validationStatus')
        $reasonByVm[$recordVmName] = ('Reboot action {0}, validation {1}.' -f $action, $validation)
    }

    foreach ($target in @($RebootTargets)) {
        $vmName = [string](Get-RuntimePropertyValue -InputObject $target -Name 'vmName')
        if ([string]::IsNullOrWhiteSpace($vmName) -or $confirmed.ContainsKey($vmName)) {
            continue
        }

        $reason = 'A restart this VM requires has not been completed and confirmed.'
        if ($reasonByVm.ContainsKey($vmName)) {
            $reason = '{0} {1}' -f $reason, $reasonByVm[$vmName]
        }

        # Deliberately not 'Failed': the installation itself may well have succeeded, and saying
        # otherwise sends whoever reads the summary looking for an install problem that is not
        # there. What is outstanding is the restart.
        $StateMap[$vmName] = [pscustomobject]@{
            vmName = $vmName
            state = 'PendingReboot'
            reason = $reason
            outcome = if ($null -ne $StateMap -and $StateMap.ContainsKey($vmName)) { Get-RuntimePropertyValue -InputObject $StateMap[$vmName] -Name 'outcome' } else { $null }
            pendingSelectableCount = 0
            deselectedSelectableCount = 0
            needsReviewSelectableCount = 0
            errors = @()
        }
    }
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
    ConvertTo-Json -InputObject @($actions) -Depth 5 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

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
    ConvertTo-Json -InputObject @($rounds) -Depth 8 | Set-Content -LiteralPath $roundsPath -Encoding UTF8

    $finalStates = @(@($FinalStateMap.Keys) | Sort-Object | ForEach-Object { $FinalStateMap[$_] })
    $green = @($finalStates | Where-Object { [string]$_.state -eq 'Green' })
    $greenByChoice = @($finalStates | Where-Object { [string]$_.state -eq 'GreenByOperatorChoice' })
    $pending = @($finalStates | Where-Object { [string]$_.state -eq 'Pending' })
    $pendingReboot = @($finalStates | Where-Object { [string]$_.state -eq 'PendingReboot' })
    $needsReview = @($finalStates | Where-Object { [string]$_.state -eq 'NeedsReview' })
    $failed = @($finalStates | Where-Object { [string]$_.state -eq 'Failed' })
    $excluded = @($finalStates | Where-Object { [string]$_.state -eq 'Excluded' })
    # A state nobody has taught this summary about would otherwise vanish from it entirely while
    # still making the run exit 1, leaving the operator with no line to read.
    $knownSummaryStates = @('Green', 'GreenByOperatorChoice', 'Pending', 'PendingReboot', 'NeedsReview', 'Failed', 'Excluded')
    $otherStates = @($finalStates | Where-Object { [string]$_.state -notin $knownSummaryStates })

    $lines = @()
    $lines += '# Patch run summary'
    $lines += ''
    $lines += ('Output directory: `{0}`' -f $RunOutputDirectory)
    $lines += ('Patch rounds run: {0}' -f $rounds.Count)
    $lines += ''
    $lines += ('- VMs up to date: {0}' -f $green.Count)
    $lines += ('- VMs up to date except operator-deselected updates: {0}' -f $greenByChoice.Count)
    $lines += ('- VMs still having selectable updates: {0}' -f $pending.Count)
    $lines += ('- VMs waiting for a restart they require: {0}' -f $pendingReboot.Count)
    $lines += ('- VMs with updates that need an operator decision: {0}' -f $needsReview.Count)
    $lines += ('- VMs with failed or unconfirmed patching: {0}' -f $failed.Count)
    $lines += ('- VMs excluded from patching (outside the scope of patching, not patched): {0}' -f $excluded.Count)
    if ($otherStates.Count -gt 0) {
        $lines += ('- VMs in an unrecognised state: {0}' -f $otherStates.Count)
    }
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
        [pscustomobject]@{ Title = 'VMs waiting for a restart they require'; Rows = $pendingReboot },
        [pscustomobject]@{ Title = 'VMs with updates that need an operator decision'; Rows = $needsReview },
        [pscustomobject]@{ Title = 'VMs with failed or unconfirmed patching'; Rows = $failed },
        [pscustomobject]@{ Title = 'VMs excluded from patching (outside the scope of patching, not patched)'; Rows = $excluded },
        [pscustomobject]@{ Title = 'VMs in an unrecognised state'; Rows = $otherStates },
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
            $errorKind = [string](Get-RuntimePropertyValue -InputObject $readResult -Name 'ErrorKind')
            $rejectedBeforeStart = [bool](Get-RuntimePropertyValue -InputObject $readResult -Name 'RejectedBeforeStart' -DefaultValue $false)
            if ($null -eq $readResult) {
                $pendingItem.LastErrorMessage = 'No boot time result was returned.'
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$readResult.Error)) {
                $pendingItem.LastErrorMessage = [string]$readResult.Error
            }

            if (Test-CredentialRefusalErrorKind -ErrorKind $errorKind) {
                $pendingItem | Add-Member -MemberType NoteProperty -Name ErrorKind -Value $errorKind -Force
                $pendingItem | Add-Member -MemberType NoteProperty -Name RejectedBeforeStart -Value $rejectedBeforeStart -Force
                $records += New-RebootActionRecord -VMName $pendingItem.VMName -Action 'Failed' -ProcessId $pendingItem.ProcessId -ErrorMessage $pendingItem.LastErrorMessage -RebootReason $pendingItem.RebootReason -BatchNumber $pendingItem.BatchNumber -Sequence $pendingItem.Sequence -BootTimeBaseline $pendingItem.BootTimeBaseline -BootTimeObserved $pendingItem.BootTimeObserved -UptimeBaselineSeconds $pendingItem.UptimeBaselineSeconds -UptimeObservedSeconds $pendingItem.UptimeObservedSeconds -ValidationStatus 'CredentialRecovery' -AttemptCount $pendingItem.AttemptCount -TimeoutCount $pendingItem.TimeoutCount -LastErrorMessage $pendingItem.LastErrorMessage -ErrorKind $errorKind -RejectedBeforeStart $rejectedBeforeStart
                continue
            }

            $confirmed = $false
            if ($newBootByVm.ContainsKey([string]$pendingItem.VMName)) {
                $observed = $newBootByVm[[string]$pendingItem.VMName]
                $pendingItem.BootTimeObserved = $observed
                $pendingItem.UptimeObservedSeconds = Get-RuntimePropertyValue -InputObject $readResult -Name 'UptimeSeconds'
                if (Test-BootTimeNewer -Baseline $pendingItem.BootTimeBaseline -Observed $observed) {
                    $confirmed = $true
                    $records += New-RebootActionRecord -VMName $pendingItem.VMName -Action 'Initiated' -ProcessId $pendingItem.ProcessId -RebootReason $pendingItem.RebootReason -BatchNumber $pendingItem.BatchNumber -Sequence $pendingItem.Sequence -BootTimeBaseline $pendingItem.BootTimeBaseline -BootTimeObserved $observed -UptimeBaselineSeconds $pendingItem.UptimeBaselineSeconds -UptimeObservedSeconds $pendingItem.UptimeObservedSeconds -ValidationStatus 'Confirmed' -WaitSeconds ([int](Get-Date).Subtract($windowStart).TotalSeconds) -AttemptCount $pendingItem.AttemptCount -TimeoutCount $pendingItem.TimeoutCount -LastErrorMessage $pendingItem.LastErrorMessage -ErrorKind ([string](Get-RuntimePropertyValue -InputObject $pendingItem -Name 'ErrorKind')) -RejectedBeforeStart ([bool](Get-RuntimePropertyValue -InputObject $pendingItem -Name 'RejectedBeforeStart' -DefaultValue $false))
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
                ErrorKind = $null
                RejectedBeforeStart = $false
                SkipInitiation = $false
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
                        $errorKind = [string](Get-RuntimePropertyValue -InputObject $readResult -Name 'ErrorKind')
                        if (Test-CredentialRefusalErrorKind -ErrorKind $errorKind) {
                            $matchingItem.ErrorKind = $errorKind
                            $matchingItem.RejectedBeforeStart = [bool](Get-RuntimePropertyValue -InputObject $readResult -Name 'RejectedBeforeStart' -DefaultValue $false)
                            $matchingItem.SkipInitiation = $true
                            $matchingItem.ValidationRequired = $false
                        }
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

        foreach ($item in @($batchItems | Where-Object { $_.SkipInitiation })) {
            $records += New-RebootActionRecord -VMName $item.VMName -Action 'Failed' -ErrorMessage $item.LastErrorMessage -RebootReason $item.RebootReason -BatchNumber $batchNumber -Sequence $item.Sequence -ValidationStatus 'CredentialRecovery' -AttemptCount $item.AttemptCount -TimeoutCount $item.TimeoutCount -LastErrorMessage $item.LastErrorMessage -ErrorKind $item.ErrorKind -RejectedBeforeStart $item.RejectedBeforeStart
        }

        # --- initiate reboots for the whole batch ---
        $restartCandidates = @($batchItems | Where-Object { -not $_.SkipInitiation })
        $restartResults = if ($restartCandidates.Count -gt 0) { @(& $InitiateRebootScript $restartCandidates) } else { @() }
        $restartByVm = @{}
        foreach ($restartResult in @($restartResults)) {
            if (-not $restartByVm.ContainsKey([string]$restartResult.VMName)) {
                $restartByVm[[string]$restartResult.VMName] = $restartResult
            }
        }

        # A missing result counts as a failed initiation: silently dropping the VM here would
        # leave it out of reboot-actions.json and let the run exit 0 without ever rebooting it.
        $credentialInitFailures = @()
        $ambiguousInitiations = @()
        $initFailed = @()
        foreach ($item in @($restartCandidates)) {
            $result = $restartByVm[[string]$item.VMName]
            if ($null -eq $result) {
                $initFailed += $item
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$result.Error)) {
                continue
            }

            $errorKind = [string](Get-RuntimePropertyValue -InputObject $result -Name 'ErrorKind')
            if (Test-CredentialRefusalErrorKind -ErrorKind $errorKind) {
                $credentialInitFailures += $item
            }
            # A reboot job that never answered is the same ambiguity as a transport failure after
            # the guest call: shutdown.exe may be running, so it is observed, never offered as a
            # failed initiation whose CONTINUE would let the next batch restart alongside it.
            elseif ($errorKind -in @('Transient', 'JobResultLost') -and -not [bool](Get-RuntimePropertyValue -InputObject $result -Name 'RejectedBeforeStart' -DefaultValue $false)) {
                $ambiguousInitiations += $item
            }
            else {
                $initFailed += $item
            }
        }

        foreach ($item in $credentialInitFailures) {
            $result = $restartByVm[[string]$item.VMName]
            $item.LastErrorMessage = [string]$result.Error
            $item.ErrorKind = [string](Get-RuntimePropertyValue -InputObject $result -Name 'ErrorKind')
            $item.RejectedBeforeStart = [bool](Get-RuntimePropertyValue -InputObject $result -Name 'RejectedBeforeStart' -DefaultValue $false)
            $records += New-RebootActionRecord -VMName $item.VMName -Action 'Failed' -ErrorMessage $item.LastErrorMessage -RebootReason $item.RebootReason -BatchNumber $batchNumber -Sequence $item.Sequence -ValidationStatus 'CredentialRecovery' -AttemptCount $item.AttemptCount -TimeoutCount $item.TimeoutCount -LastErrorMessage $item.LastErrorMessage -ErrorKind $item.ErrorKind -RejectedBeforeStart $item.RejectedBeforeStart
        }

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
                $errorKind = [string](Get-RuntimePropertyValue -InputObject $result -Name 'ErrorKind')
                $rejectedBeforeStart = [bool](Get-RuntimePropertyValue -InputObject $result -Name 'RejectedBeforeStart' -DefaultValue $false)
                $records += New-RebootActionRecord -VMName $item.VMName -Action 'Failed' -ErrorMessage $initErrorMessage -RebootReason $item.RebootReason -BatchNumber $batchNumber -Sequence $item.Sequence -ValidationStatus 'InitiationError' -OperatorDecision $operatorDecision -AttemptCount $item.AttemptCount -LastErrorMessage $initErrorMessage -ErrorKind $errorKind -RejectedBeforeStart $rejectedBeforeStart
                $item.Initiated = $false
            }
        }

        foreach ($item in @($restartCandidates)) {
            $restartResult = $restartByVm[[string]$item.VMName]
            $restartSucceeded = ($null -ne $restartResult -and [string]::IsNullOrWhiteSpace([string]$restartResult.Error))
            $ambiguous = (@($ambiguousInitiations | Where-Object { $_.VMName -eq $item.VMName }).Count -gt 0)
            if ($restartSucceeded -or $ambiguous) {
                $item.Initiated = $true
                $item.ProcessId = Get-RuntimePropertyValue -InputObject $restartResult -Name 'ProcessId'
                if ($ambiguous) {
                    $item.LastErrorMessage = [string]$restartResult.Error
                    $item.ErrorKind = [string](Get-RuntimePropertyValue -InputObject $restartResult -Name 'ErrorKind')
                    $item.RejectedBeforeStart = [bool](Get-RuntimePropertyValue -InputObject $restartResult -Name 'RejectedBeforeStart' -DefaultValue $false)
                }
            }
        }

        # --- validation / boot-time gate ---
        foreach ($item in @($batchItems | Where-Object { $_.Initiated -and -not $_.ValidationRequired })) {
            $records += New-RebootActionRecord -VMName $item.VMName -Action 'Initiated' -ProcessId $item.ProcessId -RebootReason $item.RebootReason -BatchNumber $batchNumber -Sequence $item.Sequence -BootTimeBaseline $null -BootTimeObserved $null -ValidationStatus 'Unverified' -OperatorDecision 'CONTINUE' -AttemptCount $item.AttemptCount -TimeoutCount $item.TimeoutCount -LastErrorMessage $item.LastErrorMessage -ErrorKind $item.ErrorKind -RejectedBeforeStart $item.RejectedBeforeStart
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
                        $records += New-RebootActionRecord -VMName $item.VMName -Action 'Initiated' -ProcessId $item.ProcessId -RebootReason $item.RebootReason -BatchNumber $batchNumber -Sequence $item.Sequence -BootTimeBaseline $item.BootTimeBaseline -BootTimeObserved $item.BootTimeObserved -UptimeBaselineSeconds $item.UptimeBaselineSeconds -UptimeObservedSeconds $item.UptimeObservedSeconds -ValidationStatus 'Unverified' -OperatorDecision 'CONTINUE' -AttemptCount $item.AttemptCount -TimeoutCount $item.TimeoutCount -LastErrorMessage $item.LastErrorMessage -ErrorKind $item.ErrorKind -RejectedBeforeStart $item.RejectedBeforeStart
                    }
                    break
                }
                else {
                    foreach ($item in $pendingItems) {
                        $records += New-RebootActionRecord -VMName $item.VMName -Action 'Initiated' -ProcessId $item.ProcessId -RebootReason $item.RebootReason -BatchNumber $batchNumber -Sequence $item.Sequence -BootTimeBaseline $item.BootTimeBaseline -BootTimeObserved $item.BootTimeObserved -UptimeBaselineSeconds $item.UptimeBaselineSeconds -UptimeObservedSeconds $item.UptimeObservedSeconds -ValidationStatus 'Timeout' -OperatorDecision 'ABORT' -AttemptCount $item.AttemptCount -TimeoutCount $item.TimeoutCount -LastErrorMessage $item.LastErrorMessage -ErrorKind $item.ErrorKind -RejectedBeforeStart $item.RejectedBeforeStart
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

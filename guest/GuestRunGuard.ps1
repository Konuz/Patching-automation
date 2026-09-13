#requires -Version 5.1
<#
    Runs INSIDE the guest. One lock per guest, shared by every process this tool starts there.

    Two runs of this tool against the same guest must never overlap: two WUA sessions installing
    at once corrupt each other's work, and a reboot ordered while an agent is mid-install can
    leave a half-written update. Nothing else provides that exclusion - a per-run id, a per-cycle
    directory or a per-account marker are all things a second run brings its own copy of - so the
    lock lives at ONE fixed path, independent of the run id, the cycle directory, the account the
    agent runs as and -GuestWorkingDirectory. There is deliberately no switch to move it and no
    switch to ignore it.

    The lock is an open file handle with FileShare::None, so it is released by the operating
    system when the holder dies. That is why the handle alone is not the whole story: a crashed
    agent releases its handle while its WUA work may well have finished half way. The state
    document written inside the locked file is what says whether the previous run reached a
    terminal status, and an unreconciled trace blocks the next run rather than being cleared.

      Enter-GuestRunGuard -RunId <string> -Phase <Agent|Reboot>
      Set-GuestRunGuardCompleted -Guard <object> -Outcome <string>
      Set-GuestRunGuardRebootRequested -Guard <object>
      Exit-GuestRunGuard -Guard <object>

    Requires guest/GuestWorkspace.ps1 to be loaded: the coordination directory is secured and
    verified the same way as the tool directory, whatever -GuestWorkingDirectory was set to.
#>

Set-StrictMode -Version 2.0

$script:GuestRunGuardExitCodes = [ordered]@{
    Ok                   = 0
    Conflict             = 20
    RejectedBeforeStart  = 21
    Ambiguous            = 22
    GuardUnavailable     = 23
}

function Get-GuestRunGuardDirectory {
    # Fixed on purpose. A coordination path that follows -GuestWorkingDirectory is not
    # coordination: a second run started with a different working directory would take its own
    # lock and both would install at once. The offline tests shadow this function to point at a
    # private temporary directory; nothing in the product configures it.
    return 'C:\ProgramData\PatchingGuestOps\.coordination'
}

function Get-GuestRunGuardLockPath {
    # State lives INSIDE the locked file. A separate state file could be rewritten by a process
    # that never held the lock, which is the one thing the lock exists to prevent.
    return (Join-Path (Get-GuestRunGuardDirectory) 'guest-run.lock')
}

function Get-GuestRunGuardBootTimeUtc {
    # The only thing that can prove a requested reboot actually happened. When it cannot be read,
    # the answer is $null and a pending reboot marker stays unreconciled - never the other way
    # round, because "I could not check" must not clear a marker that blocks a second shutdown.
    try {
        $operatingSystem = Get-CimInstance Win32_OperatingSystem
        $bootTime = $operatingSystem.LastBootUpTime
        if ($null -eq $bootTime) {
            return $null
        }
        return ([datetime]$bootTime).ToUniversalTime()
    }
    catch {
        return $null
    }
}

function New-GuestRunGuardResult {
    param(
        [bool]$Acquired,
        [bool]$Conflict,
        [string]$Reason = $null,
        $Stream = $null,
        [string]$RunId = $null,
        [string]$Phase = $null,
        $PreviousState = $null
    )

    return [pscustomobject]@{
        Acquired = $Acquired
        Conflict = $Conflict
        Reason = $Reason
        Stream = $Stream
        RunId = $RunId
        Phase = $Phase
        PreviousState = $PreviousState
        LockPath = (Get-GuestRunGuardLockPath)
    }
}

function Read-GuestRunGuardState {
    param($Stream)

    # Read through the handle we hold, not by reopening the path: reopening would be a second
    # view of a file that only this process is allowed to see.
    $Stream.Position = 0
    $reader = New-Object System.IO.StreamReader($Stream, [System.Text.Encoding]::UTF8, $false, 4096, $true)
    try {
        $text = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return ($text | ConvertFrom-Json)
    }
    catch {
        # Unreadable is not empty. A trace nobody can interpret is exactly the case that must
        # block the next run instead of being overwritten.
        return 'unreadable'
    }
}

function Write-GuestRunGuardState {
    param($Stream, $State)

    $json = $State | ConvertTo-Json -Depth 6
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Stream.Position = 0
    $Stream.SetLength(0)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function New-GuestRunGuardState {
    param(
        [string]$RunId,
        [string]$Phase,
        [string]$Status
    )

    $bootTime = Get-GuestRunGuardBootTimeUtc
    return [ordered]@{
        schemaVersion = 'guest-run-guard-1'
        runId = $RunId
        phase = $Phase
        status = $Status
        # Through the .NET API rather than the automatic variable: the static gate forbids even
        # naming $PID, because shadowing it by accident is too easy.
        processId = [System.Diagnostics.Process]::GetCurrentProcess().Id
        startedAtUtc = ([datetime]::UtcNow).ToString('o')
        bootTimeUtc = $(if ($null -eq $bootTime) { $null } else { $bootTime.ToString('o') })
        completedAtUtc = $null
        outcome = $null
    }
}

function Test-GuestRunGuardRebootConfirmed {
    param($PreviousState)

    # A pending reboot marker may only be reconciled by evidence that the guest actually came
    # back up: a boot time strictly newer than the one recorded when the reboot was ordered.
    $recordedText = [string](& { try { [string]$PreviousState.bootTimeUtc } catch { '' } })
    if ([string]::IsNullOrWhiteSpace($recordedText)) {
        return $false
    }

    $recorded = [datetime]::MinValue
    if (-not [datetime]::TryParse($recordedText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$recorded)) {
        return $false
    }

    $current = Get-GuestRunGuardBootTimeUtc
    if ($null -eq $current) {
        return $false
    }

    return ($current.ToUniversalTime() -gt $recorded.ToUniversalTime())
}

function Get-GuestRunGuardConflictReason {
    param($PreviousState)

    # Returns the reason this guest is not available, or $null when it is. Called while the lock
    # is held, so "still running" here means the previous holder died: the operating system
    # released its handle, which says nothing about whether its WUA work finished.
    if ($null -eq $PreviousState) {
        return $null
    }

    if ($PreviousState -is [string] -and $PreviousState -eq 'unreadable') {
        return 'a previous run left a coordination record this tool cannot interpret; reconcile it by hand after checking Windows Update on the guest'
    }

    $status = [string](& { try { [string]$PreviousState.status } catch { '' } })
    $previousRunId = [string](& { try { [string]$PreviousState.runId } catch { '' } })

    switch ($status) {
        'Completed' { return $null }
        'Running' {
            return ('a previous run ({0}) never reported completion on this guest; reconcile it by hand after checking Windows Update on the guest' -f $previousRunId)
        }
        'RebootRequested' {
            if (Test-GuestRunGuardRebootConfirmed -PreviousState $PreviousState) {
                return $null
            }
            return ('a reboot requested by a previous run ({0}) has not been confirmed by a newer boot time on this guest' -f $previousRunId)
        }
        default {
            return ('a previous run ({0}) left coordination status "{1}", which this tool does not recognise' -f $previousRunId, $status)
        }
    }
}

function Enter-GuestRunGuard {
    param(
        [string]$RunId,
        [ValidateSet('Agent', 'Reboot')][string]$Phase
    )

    if ([string]::IsNullOrWhiteSpace($RunId)) {
        return New-GuestRunGuardResult -Acquired $false -Conflict $false -Reason 'A run id is required to take the guest run guard.'
    }

    $directory = Get-GuestRunGuardDirectory
    $workspace = Initialize-GuestWorkspace -Path $directory
    if ([string]$workspace.Status -ne 'Ok') {
        # Without a directory this tool controls there is no lock worth taking, and pretending
        # otherwise would let two runs meet in a directory anyone can rewrite.
        return New-GuestRunGuardResult -Acquired $false -Conflict $false -Reason ('The guest coordination directory {0} could not be secured: {1}' -f $directory, $workspace.Reason)
    }

    $lockPath = Get-GuestRunGuardLockPath
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None)
    }
    catch {
        # Another process on this guest holds it. That is a conflict, not an error to retry:
        # the other run may be installing updates right now.
        return New-GuestRunGuardResult -Acquired $false -Conflict $true -Reason ('Another PatchingGuestOps run holds the guest run guard on this machine ({0}).' -f $_.Exception.Message) -RunId $RunId -Phase $Phase
    }

    try {
        $previousState = Read-GuestRunGuardState -Stream $stream
        $conflictReason = Get-GuestRunGuardConflictReason -PreviousState $previousState
        if ($null -ne $conflictReason) {
            $stream.Dispose()
            return New-GuestRunGuardResult -Acquired $false -Conflict $true -Reason $conflictReason -RunId $RunId -Phase $Phase -PreviousState $previousState
        }

        Write-GuestRunGuardState -Stream $stream -State (New-GuestRunGuardState -RunId $RunId -Phase $Phase -Status 'Running')
        return New-GuestRunGuardResult -Acquired $true -Conflict $false -Stream $stream -RunId $RunId -Phase $Phase -PreviousState $previousState
    }
    catch {
        try { $stream.Dispose() } catch { }
        return New-GuestRunGuardResult -Acquired $false -Conflict $false -Reason ('The guest run guard could not be written: {0}' -f $_.Exception.Message) -RunId $RunId -Phase $Phase
    }
}

function Set-GuestRunGuardCompleted {
    param(
        $Guard,
        [string]$Outcome
    )

    # Called only after this cycle's terminal status has been written. Completion is what lets
    # the NEXT run start without a conflict, so recording it early would hand a still-unfinished
    # guest to another run.
    if ($null -eq $Guard -or -not $Guard.Acquired -or $null -eq $Guard.Stream) {
        return $false
    }

    $state = New-GuestRunGuardState -RunId ([string]$Guard.RunId) -Phase ([string]$Guard.Phase) -Status 'Completed'
    $state.completedAtUtc = ([datetime]::UtcNow).ToString('o')
    $state.outcome = $Outcome
    Write-GuestRunGuardState -Stream $Guard.Stream -State $state
    return $true
}

function Set-GuestRunGuardRebootRequested {
    param($Guard)

    # Written immediately before the reboot is ordered, and left in place afterwards whatever the
    # order reported: an ambiguous result is not permission to send a second shutdown. Only a
    # newer boot time reconciles it (Test-GuestRunGuardRebootConfirmed).
    if ($null -eq $Guard -or -not $Guard.Acquired -or $null -eq $Guard.Stream) {
        return $false
    }

    Write-GuestRunGuardState -Stream $Guard.Stream -State (New-GuestRunGuardState -RunId ([string]$Guard.RunId) -Phase ([string]$Guard.Phase) -Status 'RebootRequested')
    return $true
}

function Reset-GuestRunGuardRebootRequested {
    param($Guard)

    # Only for a reboot this process is certain it never ordered. Leaving a pending marker there
    # would block the next agent on a guest that was never told to restart; clearing one after a
    # shutdown may have started would allow a second reboot.
    if ($null -eq $Guard -or -not $Guard.Acquired -or $null -eq $Guard.Stream) {
        return $false
    }

    $state = New-GuestRunGuardState -RunId ([string]$Guard.RunId) -Phase ([string]$Guard.Phase) -Status 'Completed'
    $state.completedAtUtc = ([datetime]::UtcNow).ToString('o')
    $state.outcome = 'RebootNotOrdered'
    Write-GuestRunGuardState -Stream $Guard.Stream -State $state
    return $true
}

function Exit-GuestRunGuard {
    param($Guard)

    # Closes the handle. The file itself stays: it is the shared coordination record for this
    # guest, other processes look at it, and deleting it would throw away the one trace that
    # says whether the previous run finished.
    if ($null -eq $Guard -or $null -eq $Guard.Stream) {
        return
    }

    try { $Guard.Stream.Dispose() } catch { }
}

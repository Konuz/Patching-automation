#requires -Version 5.1
<#
    Runs INSIDE the guest, and never as an uploaded file: the orchestrator concatenates
    GuestWorkspace.ps1, GuestRunGuard.ps1 and this file and runs the result through
    `powershell.exe -EncodedCommand`.

    Ordering the restart from in here, rather than starting shutdown.exe directly over
    GuestOps, is what lets the guest run guard be HELD while the reboot is ordered. Otherwise a
    reboot could be sent to a guest whose agent is still installing, or to one that a second run
    of this tool is already working on - and a half-installed update across a restart is the
    failure this whole guard exists to prevent.

    The order of the two writes is the load-bearing part:
      - the pending-reboot marker is written immediately BEFORE shutdown.exe is invoked, so no
        new agent can start on this guest until a newer boot time confirms the restart;
      - it is rolled back ONLY when this process is certain shutdown.exe was never invoked. Once
        invoked, an ambiguous result keeps the marker: a second shutdown is never authorised by
        not knowing.
#>

Set-StrictMode -Version 2.0

function Get-GuestRebootShutdownArguments {
    param([string]$Comment = 'PatchingGuestOps reboot after updates')

    # An embedded double quote would end shutdown.exe's /c argument early and turn the rest of the
    # comment into further switches, so they become single quotes. Returned as an array because
    # that is how the arguments are passed - there is no command line to re-parse.
    $safeComment = ([string]$Comment) -replace '"', "'"
    return @('/r', '/t', '0', '/c', $safeComment)
}

function Invoke-GuestRebootRequest {
    param(
        [string]$RunId,
        [string]$Comment = 'PatchingGuestOps reboot after updates'
    )

    $guard = Enter-GuestRunGuard -RunId $RunId -Phase 'Reboot'
    if (-not $guard.Acquired) {
        # Nothing has been sent, and nothing may be: either another run holds this guest or a
        # previous one left a trace nobody has reconciled.
        $status = if ($guard.Conflict) { 'Conflict' } else { 'GuardUnavailable' }
        return [pscustomobject]@{ Status = $status; Reason = [string]$guard.Reason; ExitCode = [int]$script:GuestRunGuardExitCodes[$status] }
    }

    try {
        $marked = $false
        try {
            $marked = [bool](Set-GuestRunGuardRebootRequested -Guard $guard)
            if (-not $marked) {
                throw 'The pending reboot marker could not be written.'
            }

            $shutdownArguments = @(Get-GuestRebootShutdownArguments -Comment $Comment)
            $shutdownPath = Join-Path $env:SystemRoot 'System32\shutdown.exe'
            # From this line on, the marker stays whatever happens: shutdown.exe may have been
            # accepted even when it reports a failure (1190, "a shutdown is already in progress"
            # is exactly that case), and clearing the marker would allow a second restart.
            $shutdownOutput = & $shutdownPath @shutdownArguments 2>&1
            $shutdownExitCode = $LASTEXITCODE

            if ($shutdownExitCode -eq 0) {
                return [pscustomobject]@{ Status = 'Ok'; Reason = $null; ExitCode = [int]$script:GuestRunGuardExitCodes['Ok'] }
            }

            return [pscustomobject]@{
                Status = 'Ambiguous'
                Reason = ('shutdown.exe reported exit code {0}: {1}' -f $shutdownExitCode, ((@($shutdownOutput) -join ' ').Trim()))
                ExitCode = [int]$script:GuestRunGuardExitCodes['Ambiguous']
            }
        }
        catch {
            # We got here without invoking shutdown.exe, so the guest was provably never told to
            # restart. Leaving a pending marker behind would block the next agent on a healthy
            # guest for no reason, so it is rolled back - under the handle we still hold.
            if ($marked) {
                try { $null = Reset-GuestRunGuardRebootRequested -Guard $guard } catch { }
            }
            return [pscustomobject]@{
                Status = 'RejectedBeforeStart'
                Reason = [string]$_.Exception.Message
                ExitCode = [int]$script:GuestRunGuardExitCodes['RejectedBeforeStart']
            }
        }
    }
    finally {
        Exit-GuestRunGuard -Guard $guard
    }
}

# --- bootstrap dispatch ----------------------------------------------------------------------
# Dot-sourcing this file (the offline tests do) defines the function and runs nothing.
if (Test-Path -LiteralPath 'Variable:GuestRebootRequest') {
    $guestRebootExitCode = [int]$script:GuestRunGuardExitCodes['RejectedBeforeStart']
    try {
        $rebootRequest = Get-Variable -Name 'GuestRebootRequest' -ValueOnly
        $rebootRunId = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String([string]$rebootRequest.RunIdBase64))
        $rebootComment = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String([string]$rebootRequest.CommentBase64))
        $guestRebootResult = Invoke-GuestRebootRequest -RunId $rebootRunId -Comment $rebootComment
        $guestRebootExitCode = [int]$guestRebootResult.ExitCode
    }
    catch {
        # An error out here is before any guard was taken and before shutdown.exe existed as a
        # possibility, so "never sent" is the honest answer.
        $guestRebootExitCode = [int]$script:GuestRunGuardExitCodes['RejectedBeforeStart']
    }

    exit $guestRebootExitCode
}

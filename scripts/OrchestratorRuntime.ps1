Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-ThrottledJobErrorResult {
    param(
        $InputObject,
        [string]$ErrorMessage
    )

    return [pscustomobject]@{
        Sequence = $InputObject.Sequence
        VMName = $InputObject.VMName
        VMOutputDirectory = $InputObject.VMOutputDirectory
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
                Stop-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
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
            Stop-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
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

function Test-ApplyResultsSuccessful {
    param($ApplyResults)

    $errors = @($ApplyResults | Where-Object { Test-IsApplyResultError -ApplyResult $_ })
    return ($errors.Count -eq 0)
}

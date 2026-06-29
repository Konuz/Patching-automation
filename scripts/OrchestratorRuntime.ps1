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

function Select-RebootRequiredApplyResults {
    param($ApplyResults)

    return @($ApplyResults | Where-Object { [bool]$_.rebootRequired })
}

function New-RebootActionRecord {
    param(
        [string]$VMName,
        [string]$Action,
        $ProcessId = $null,
        [string]$ErrorMessage = $null
    )

    return [pscustomobject]@{
        vmName = $VMName
        rebootRequired = $true
        action = $Action
        processId = $ProcessId
        errorMessage = $ErrorMessage
    }
}

function New-SkippedRebootActionRecords {
    param($RebootTargets)

    $records = @()
    foreach ($target in @($RebootTargets)) {
        $records += New-RebootActionRecord -VMName ([string]$target.vmName) -Action 'SkippedByOperator'
    }

    return @($records)
}

function Test-RebootActionsSuccessful {
    param($RebootActions)

    $failed = @($RebootActions | Where-Object { $_.action -eq 'Failed' })
    return ($failed.Count -eq 0)
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
    $initiated = @($actions | Where-Object { $_.action -eq 'Initiated' })
    $skipped = @($actions | Where-Object { $_.action -eq 'SkippedByOperator' })
    $failed = @($actions | Where-Object { $_.action -eq 'Failed' })

    $lines = @()
    $lines += ''
    $lines += '## Guest reboot actions'
    $lines += ''
    $lines += ('- VMs with reboot initiated: {0}' -f $initiated.Count)
    $lines += ('- VMs with reboot skipped by operator: {0}' -f $skipped.Count)
    $lines += ('- VMs with reboot initiation errors: {0}' -f $failed.Count)
    $lines += ''

    foreach ($section in @(
        [pscustomobject]@{ Title = 'VMs with reboot initiated'; Rows = $initiated },
        [pscustomobject]@{ Title = 'VMs with reboot skipped by operator'; Rows = $skipped },
        [pscustomobject]@{ Title = 'VMs with reboot initiation errors'; Rows = $failed }
    )) {
        $lines += ('### {0}' -f $section.Title)
        if (@($section.Rows).Count -eq 0) {
            $lines += '- none'
        }
        else {
            foreach ($row in @($section.Rows)) {
                if ([string]::IsNullOrWhiteSpace([string]$row.errorMessage)) {
                    $lines += ('- {0}' -f $row.vmName)
                }
                else {
                    $lines += ('- {0}: {1}' -f $row.vmName, $row.errorMessage)
                }
            }
        }
        $lines += ''
    }

    Add-Content -LiteralPath $summaryPath -Value $lines -Encoding UTF8
}

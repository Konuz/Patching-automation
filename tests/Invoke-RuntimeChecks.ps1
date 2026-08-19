Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\GuestOpsLib.ps1')

$failures = @()

function Add-Failure {
    param([string]$Message)
    $script:failures += $Message
}

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        Add-Failure -Message ('{0}. Expected: {1}; Actual: {2}' -f $Message, $Expected, $Actual)
    }
}

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Message
    )

    if ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Add-Failure -Message ('{0}. Missing: {1}. Text: {2}' -f $Message, $Needle, $Text)
    }
}

function Assert-NotContains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Message
    )

    if ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        Add-Failure -Message ('{0}. Unexpected: {1}. Text: {2}' -f $Message, $Needle, $Text)
    }
}

function New-TestCredential {
    param([string]$UserName)

    return New-Object System.Management.Automation.PSCredential(
        $UserName,
        (ConvertTo-SecureString 'password' -AsPlainText -Force)
    )
}

$argumentText = New-GuestAgentArguments -GuestAgentPath 'C:\ProgramData\PatchingGuestOps\Run-LocalPatch.ps1' -GuestWorkingDirectory 'C:\ProgramData\PatchingGuestOps' -MaxUpdates 2 -SelectedUpdateKeys @(
    '11111111-1111-1111-1111-111111111111|205',
    '22222222-2222-2222-2222-222222222222|17'
)

Assert-Contains -Text $argumentText -Needle '-SelectedUpdateKeys' -Message 'selected update keys flag is present'
Assert-Contains -Text $argumentText -Needle '"11111111-1111-1111-1111-111111111111|205","22222222-2222-2222-2222-222222222222|17"' -Message 'selected update keys are quoted and comma joined as one argument'

$searchOnlyText = New-GuestAgentArguments -GuestAgentPath 'C:\ProgramData\PatchingGuestOps\Run-LocalPatch.ps1' -GuestWorkingDirectory 'C:\ProgramData\PatchingGuestOps' -MaxUpdates 5 -SearchOnly
Assert-Contains -Text $searchOnlyText -Needle '-SearchOnly' -Message 'search-only flag is present'
Assert-NotContains -Text $searchOnlyText -Needle '-SelectedUpdateKeys' -Message 'search-only does not include selected keys'

$selectionDocument = New-UpdateSelectionDocument -SelectedUpdateKeys @(
    '11111111-1111-1111-1111-111111111111|205',
    '22222222-2222-2222-2222-222222222222|17',
    '',
    '11111111-1111-1111-1111-111111111111|205'
)

Assert-Equal -Actual $selectionDocument.schemaVersion -Expected 'selection-v1' -Message 'selection document schema is stable'
Assert-Equal -Actual @($selectionDocument.selectedUpdateKeys).Count -Expected 2 -Message 'selection document removes blank and duplicate keys'
Assert-Equal -Actual $selectionDocument.selectedUpdateKeys[0] -Expected '11111111-1111-1111-1111-111111111111|205' -Message 'selection document preserves first selected key order'
Assert-Equal -Actual $selectionDocument.selectedUpdateKeys[1] -Expected '22222222-2222-2222-2222-222222222222|17' -Message 'selection document preserves second selected key order'

$selectionArgumentText = New-GuestAgentArguments -GuestAgentPath 'C:\ProgramData\PatchingGuestOps\Run-LocalPatch.ps1' -GuestWorkingDirectory 'C:\ProgramData\PatchingGuestOps' -MaxUpdates 2 -SelectionPath 'C:\ProgramData\PatchingGuestOps\selection.json'
Assert-Contains -Text $selectionArgumentText -Needle '-SelectionPath "C:\ProgramData\PatchingGuestOps\selection.json"' -Message 'selection path is passed as a quoted argument'
Assert-NotContains -Text $selectionArgumentText -Needle '-SelectedUpdateKeys' -Message 'selection path replaces selected update key CLI payload'

$rebootArgumentText = New-GuestRebootArguments
Assert-Contains -Text $rebootArgumentText -Needle '/r' -Message 'guest reboot arguments request restart'
Assert-Contains -Text $rebootArgumentText -Needle '/t 0' -Message 'guest reboot arguments request immediate reboot'
Assert-Contains -Text $rebootArgumentText -Needle '/c "PatchingGuestOps reboot after updates"' -Message 'guest reboot arguments include stable comment'

$quotedRebootArgumentText = New-GuestRebootArguments -Comment 'Reboot after "updates"'
Assert-Contains -Text $quotedRebootArgumentText -Needle '/c "Reboot after ''updates''"' -Message 'guest reboot comment replaces embedded double quotes'
# guest/Read-BootTime.ps1 is pure local WMI plus a file write, so it can simply be executed here
# instead of being pinned down by text needles in the static gate.
$bootTimeScriptPath = Join-Path $repoRoot 'guest\Read-BootTime.ps1'
$bootTimeOutPath = Join-Path ([System.IO.Path]::GetTempPath()) ('read-boottime-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootTimeScriptPath -OutputPath $bootTimeOutPath
    Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message 'Read-BootTime exits zero on a healthy host'
    $bootTimePayload = Get-Content -LiteralPath $bootTimeOutPath -Raw | ConvertFrom-Json
    Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $bootTimePayload -Path @('error')) -Expected $null -Message 'Read-BootTime reports no error on a healthy host'
    $bootTimeText = [string](Get-ObjectPropertyValue -InputObject $bootTimePayload -Path @('bootTimeUtc'))
    Assert-Equal -Actual ([string]::IsNullOrWhiteSpace($bootTimeText)) -Expected $false -Message 'Read-BootTime emits a boot time'
    $parsedBootTime = [datetime]::Parse($bootTimeText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    Assert-Equal -Actual $parsedBootTime.Kind -Expected ([datetimekind]::Utc) -Message 'Read-BootTime emits UTC round-trippable ISO 8601'
    Assert-Equal -Actual ($parsedBootTime -lt [datetime]::UtcNow) -Expected $true -Message 'Read-BootTime boot time is in the past'
}
finally {
    Remove-Item -LiteralPath $bootTimeOutPath -Force -ErrorAction SilentlyContinue
}

. (Join-Path $repoRoot 'scripts\OrchestratorRuntime.ps1')

$items = @(
    [pscustomobject]@{ Sequence = 1; VMName = 'VM01' },
    [pscustomobject]@{ Sequence = 2; VMName = 'VM02' },
    [pscustomobject]@{ Sequence = 3; VMName = 'VM03' }
)

$throttledResults = @(Invoke-ThrottledJobs -Items $items -ThrottleLimit 2 -JobTimeoutSeconds 30 -ScriptBlock {
    param($JobInput)
    return [pscustomobject]@{
        Sequence = $JobInput.Sequence
        VMName = $JobInput.VMName
        Error = $null
    }
})

Assert-Equal -Actual $throttledResults.Count -Expected 3 -Message 'throttled jobs return every input result'
Assert-Equal -Actual (@($throttledResults | Where-Object { $_.Error }).Count) -Expected 0 -Message 'successful throttled jobs have no error'

$failedApply = [pscustomobject]@{ action = 'Install'; outcome = 'InstallFailed'; reason = '' }
Assert-Equal -Actual (Test-IsApplyResultError -ApplyResult $failedApply) -Expected $true -Message 'install action with non-success outcome is an apply error'

$discoverySkip = [pscustomobject]@{ action = 'Skip'; outcome = 'Skipped'; reason = 'Skipped: Discovery failed. Review discovery.json and per-VM agent artifacts.' }
Assert-Equal -Actual (Test-IsApplyResultError -ApplyResult $discoverySkip) -Expected $true -Message 'discovery-failure skip is an apply error'

$clusterSkip = [pscustomobject]@{ action = 'Skip'; outcome = 'Skipped'; reason = 'Skipped: Failover Cluster detected. Please update manually one by one.' }
Assert-Equal -Actual (Test-IsApplyResultError -ApplyResult $clusterSkip) -Expected $false -Message 'failover cluster skip is not an apply error'

$installedOk = [pscustomobject]@{ action = 'Install'; outcome = 'InstallSucceeded'; reason = ''; rebootRequired = $false }
Assert-Equal -Actual (Get-ApplySummaryStatus -ApplyResult $installedOk) -Expected 'Installed' -Message 'apply status: successful install without reboot is installed'

$installedReboot = [pscustomobject]@{ action = 'Install'; outcome = 'InstallSucceeded'; reason = ''; rebootRequired = $true }
Assert-Equal -Actual (Get-ApplySummaryStatus -ApplyResult $installedReboot) -Expected 'InstalledRebootRequired' -Message 'apply status: successful install needing reboot is flagged'

Assert-Equal -Actual (Get-ApplySummaryStatus -ApplyResult $clusterSkip) -Expected 'Skipped' -Message 'apply status: non-error skip is skipped'
Assert-Equal -Actual (Get-ApplySummaryStatus -ApplyResult $failedApply) -Expected 'Error' -Message 'apply status: failed install is error'

$partialInstall = [pscustomobject]@{ action = 'Install'; outcome = 'InstallSucceededWithErrors'; reason = ''; rebootRequired = $false }
Assert-Equal -Actual (Get-ApplySummaryStatus -ApplyResult $partialInstall) -Expected 'Partial' -Message 'apply status: partial install is distinguished from failure'
Assert-Equal -Actual (Get-ApplySummaryStatus -ApplyResult ([pscustomobject]@{ action = 'Install'; outcome = 'InstallSucceededWithErrors'; reason = ''; rebootRequired = $true })) -Expected 'Partial' -Message 'apply status: partial install wins over reboot-required'

$throttleGuardThrew = $false
try { Invoke-ThrottledJobs -Items @() -ThrottleLimit 0 -JobTimeoutSeconds 30 -ScriptBlock { param($i) $i } | Out-Null }
catch { $throttleGuardThrew = $true }
Assert-Equal -Actual $throttleGuardThrew -Expected $true -Message 'Invoke-ThrottledJobs throws on ThrottleLimit below 1'

$timeoutGuardThrew = $false
try { Invoke-ThrottledJobs -Items @() -ThrottleLimit 1 -JobTimeoutSeconds 0 -ScriptBlock { param($i) $i } | Out-Null }
catch { $timeoutGuardThrew = $true }
Assert-Equal -Actual $timeoutGuardThrew -Expected $true -Message 'Invoke-ThrottledJobs throws on JobTimeoutSeconds below 1'

$mixedApplyResults = @(
    [pscustomobject]@{ vmName = 'VM01'; action = 'Install'; outcome = 'InstallSucceeded'; rebootRequired = $true },
    [pscustomobject]@{ vmName = 'VM02'; action = 'Install'; outcome = 'InstallSucceeded'; rebootRequired = $false },
    [pscustomobject]@{ vmName = 'VM03'; action = 'Skip'; outcome = 'Skipped'; rebootRequired = $false }
)

$rebootTargets = @(Select-RebootRequiredApplyResults -ApplyResults $mixedApplyResults)
Assert-Equal -Actual $rebootTargets.Count -Expected 1 -Message 'only rebootRequired apply results become reboot targets'
Assert-Equal -Actual $rebootTargets[0].vmName -Expected 'VM01' -Message 'reboot target preserves VM name'

$pendingBeforeDiscovery = @(
    [pscustomobject]@{ vmName = 'VM01'; pendingRebootBefore = [pscustomobject]@{ isPending = $true } },
    [pscustomobject]@{ vmName = 'VM02'; pendingRebootBefore = [pscustomobject]@{ isPending = $true } },
    [pscustomobject]@{ vmName = 'VM03'; pendingRebootBefore = [pscustomobject]@{ isPending = $false } },
    [pscustomobject]@{ vmName = 'VM04'; pendingRebootBefore = [pscustomobject]@{ isPending = $true } }
)
$combinedRebootTargets = @(Select-RebootRequiredApplyResults -ApplyResults $mixedApplyResults -DiscoveryRecords $pendingBeforeDiscovery)
$secondCombinedRebootTargetName = if ($combinedRebootTargets.Count -gt 1) { $combinedRebootTargets[1].vmName } else { '<missing>' }
$secondCombinedRebootTargetReason = if ($combinedRebootTargets.Count -gt 1) { $combinedRebootTargets[1].rebootReason } else { '<missing>' }
Assert-Equal -Actual $combinedRebootTargets.Count -Expected 2 -Message 'pre-existing pending reboot records are added to reboot targets'
Assert-Equal -Actual $combinedRebootTargets[0].vmName -Expected 'VM01' -Message 'apply reboot target keeps original order'
Assert-Equal -Actual $secondCombinedRebootTargetName -Expected 'VM02' -Message 'pending-before reboot target is included after apply reboot targets'
Assert-Equal -Actual $secondCombinedRebootTargetReason -Expected 'Pending before patching' -Message 'pending-before reboot target explains why reboot is requested'
Assert-Equal -Actual (@($combinedRebootTargets | Where-Object { $_.vmName -eq 'VM04' }).Count) -Expected 0 -Message 'pending-before discovery outside apply results is not rebooted'

$skippedRebootActions = @(New-SkippedRebootActionRecords -RebootTargets $rebootTargets)
Assert-Equal -Actual $skippedRebootActions.Count -Expected 1 -Message 'skipped reboot action is created for every reboot target'
Assert-Equal -Actual $skippedRebootActions[0].action -Expected 'SkippedByOperator' -Message 'operator skip action is explicit'
Assert-Equal -Actual $skippedRebootActions[0].rebootReason -Expected 'Reported after apply' -Message 'skipped reboot action preserves reboot reason'
Assert-Equal -Actual (Test-RebootActionsSuccessful -RebootActions $skippedRebootActions) -Expected $true -Message 'operator skip is not a reboot failure'

$baseTime = [datetime]::Parse('2026-01-01T00:00:00Z').ToUniversalTime()
$newTime = [datetime]::Parse('2026-01-02T00:00:00Z').ToUniversalTime()

$failedRebootActions = @(
    (New-RebootActionRecord -VMName 'VM01' -Action 'Initiated' -ProcessId 42 -RebootReason 'Pending before patching' -ValidationStatus 'Confirmed'),
    (New-RebootActionRecord -VMName 'VM02' -Action 'Failed' -ErrorMessage 'VMware Tools are not running' -RebootReason 'Reported after apply')
)
Assert-Equal -Actual (Test-RebootActionsSuccessful -RebootActions $failedRebootActions) -Expected $false -Message 'failed reboot action makes reboot phase unsuccessful'

$telemetryRecord = New-RebootActionRecord -VMName 'VM03' -Action 'Initiated' -ProcessId 43 -RebootReason 'Reported after apply' -BatchNumber 2 -BootTimeBaseline $baseTime -BootTimeObserved $newTime -ValidationStatus 'Timeout' -WaitSeconds 30 -AttemptCount 3 -TimeoutCount 2 -LastErrorMessage 'VMware Tools are not running' -OperatorDecision 'ABORT'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $telemetryRecord -Path @('attemptCount')) -Expected 3 -Message 'reboot record stores observation attempt count'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $telemetryRecord -Path @('timeoutCount')) -Expected 2 -Message 'reboot record stores timeout count'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $telemetryRecord -Path @('lastError')) -Expected 'VMware Tools are not running' -Message 'reboot record stores latest error'

$bootTimeArguments = New-GuestBootTimeQueryArguments -BootTimeHelperPath 'C:\ProgramData\PatchingGuestOps\Read-BootTime-vm01-a1.ps1' -OutputPath 'C:\ProgramData\PatchingGuestOps\boot-time-vm01-a1.json'
Assert-Contains -Text $bootTimeArguments -Needle '-File "C:\ProgramData\PatchingGuestOps\Read-BootTime-vm01-a1.ps1"' -Message 'boot time helper path is passed as a quoted argument'
Assert-Contains -Text $bootTimeArguments -Needle '-OutputPath "C:\ProgramData\PatchingGuestOps\boot-time-vm01-a1.json"' -Message 'boot time output path is passed as a quoted argument'

$bootTimePayload = '{"bootTimeUtc":"2026-01-02T00:00:00.0000000Z","error":null}' | ConvertFrom-Json
Assert-Equal -Actual ([datetime]$bootTimePayload.bootTimeUtc).ToUniversalTime() -Expected $newTime -Message 'boot time payload parses as UTC'
Assert-Equal -Actual $bootTimePayload.error -Expected $null -Message 'successful boot time payload has no error'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-reboot-actions-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $tempRoot 'summary.md') -Value @('# Patch summary', '') -Encoding UTF8
    Write-RebootActionArtifacts -CycleOutputDirectory $tempRoot -RebootActions @($failedRebootActions + $telemetryRecord)

    $rebootJsonPath = Join-Path $tempRoot 'reboot-actions.json'
    Assert-Equal -Actual (Test-Path -LiteralPath $rebootJsonPath -PathType Leaf) -Expected $true -Message 'reboot action artifact is written'

    $artifactRecords = @(Get-Content -LiteralPath $rebootJsonPath -Raw | ConvertFrom-Json | ForEach-Object { $_ })
    Assert-Equal -Actual $artifactRecords[0].validationStatus -Expected 'Confirmed' -Message 'reboot artifact records validation status'
    Assert-Equal -Actual $artifactRecords[0].batchNumber -Expected 0 -Message 'reboot artifact records default batch number'
    Assert-Equal -Actual $artifactRecords[2].attemptCount -Expected 3 -Message 'reboot artifact records observation attempts'
    Assert-Equal -Actual $artifactRecords[2].timeoutCount -Expected 2 -Message 'reboot artifact records timeout count'
    Assert-Equal -Actual $artifactRecords[2].lastError -Expected 'VMware Tools are not running' -Message 'reboot artifact records latest error'

    $summaryText = Get-Content -LiteralPath (Join-Path $tempRoot 'summary.md') -Raw
    Assert-Contains -Text $summaryText -Needle 'Guest reboot actions' -Message 'summary includes reboot action section'
    Assert-Contains -Text $summaryText -Needle 'VMs with reboot confirmed' -Message 'summary includes confirmed reboot section'
    Assert-Contains -Text $summaryText -Needle 'VMs with reboot initiation errors' -Message 'summary includes reboot error section'
    Assert-Contains -Text $summaryText -Needle 'VM01 (Pending before patching)' -Message 'summary includes confirmed reboot reason'
    Assert-Contains -Text $summaryText -Needle 'VM02 (Reported after apply): VMware Tools are not running' -Message 'summary includes failed reboot VM name, reason, and error'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Functional batching and boot-time gate semantics (no vCenter required) ---
function Reset-RebootTestState {
    $script:rebootCallLog = New-Object System.Collections.Generic.List[string]
    $script:readCallLog = New-Object System.Collections.Generic.List[string]
    $script:readAttempts = @{}
}

function New-RebootTestTarget {
    param([int]$Sequence, [string]$VMName, [string]$RebootReason = 'Reported after apply')
    return [pscustomobject]@{ Sequence = $Sequence; vmName = $VMName; rebootReason = $RebootReason }
}

$batchTestTargets = @(
    (New-RebootTestTarget -Sequence 1 -VMName 'VM01'),
    (New-RebootTestTarget -Sequence 2 -VMName 'VM02'),
    (New-RebootTestTarget -Sequence 3 -VMName 'VM03')
)
$splitBatches = @(Split-RebootBatches -Items $batchTestTargets -BatchSize 2)
Assert-Equal -Actual $splitBatches.Count -Expected 2 -Message 'boot time batch splits into fixed batches'
Assert-Equal -Actual @($splitBatches[0]).Count -Expected 2 -Message 'first batch holds ThrottleLimit targets'
Assert-Equal -Actual @($splitBatches[1]).Count -Expected 1 -Message 'final partial batch holds remainder targets'
Assert-Equal -Actual @($splitBatches[0])[0].vmName -Expected 'VM01' -Message 'batch preserves first target order'
Assert-Equal -Actual @($splitBatches[1])[0].vmName -Expected 'VM03' -Message 'final batch starts at the right index'
$singleTargetBatches = @(Split-RebootBatches -Items $batchTestTargets -BatchSize 1)
Assert-Equal -Actual $singleTargetBatches.Count -Expected 3 -Message 'batch splitter supports ThrottleLimit one'
Assert-Equal -Actual @($singleTargetBatches[1]).Count -Expected 1 -Message 'single-target batches contain one VM'

Assert-Equal -Actual (Test-BootTimeNewer -Baseline $baseTime -Observed $newTime) -Expected $true -Message 'newer boot time passes gate'
Assert-Equal -Actual (Test-BootTimeNewer -Baseline $baseTime -Observed $baseTime) -Expected $false -Message 'equal boot time fails gate (strictly newer required)'
Assert-Equal -Actual (Test-BootTimeNewer -Baseline $baseTime -Observed $null) -Expected $false -Message 'missing observed boot time fails gate'
Assert-Equal -Actual (Test-BootTimeNewer -Baseline $null -Observed $newTime) -Expected $false -Message 'missing baseline boot time fails gate'

Reset-RebootTestState
$successReadScript = {
    param($Items)
    $out = @()
    foreach ($it in @($Items)) {
        $name = [string]$it.VMName
        if (-not $script:readAttempts.ContainsKey($name)) { $script:readAttempts[$name] = 0 }
        $attempt = $script:readAttempts[$name]
        $script:readAttempts[$name]++
        $script:readCallLog.Add(('readtime:{0}:{1}' -f $name, $attempt))
        $boot = if ($attempt -eq 0) { $baseTime } else { $newTime }
        $out += [pscustomobject]@{ VMName = $name; BootTimeUtc = $boot; Error = $null }
    }
    return @($out)
}
$successInitiateScript = {
    param($Items)
    $out = @()
    foreach ($it in @($Items)) {
        $script:rebootCallLog.Add(('restart:' + $it.VMName))
        $out += [pscustomobject]@{ VMName = $it.VMName; ProcessId = (100 + [int]$it.Sequence); Error = $null }
    }
    return @($out)
}
$successDecisionScript = {
    param($Context)
    Add-Failure -Message ('Unexpected operator prompt during success run: {0}' -f $Context.Stage)
    return 'ABORT'
}
$successRecords = @(Invoke-RebootBatchCoordinator -RebootTargets $batchTestTargets -BatchSize 2 -WaitTimeoutSeconds 3600 -PollSeconds 1 -ReadBootTimeScript $successReadScript -InitiateRebootScript $successInitiateScript -DecisionPromptScript $successDecisionScript -SleepScript { param($Seconds) $null = $Seconds })
Assert-Equal -Actual $successRecords.Count -Expected 3 -Message 'coordinator returns a record per reboot target'
Assert-Equal -Actual (@($successRecords | Where-Object { $_.validationStatus -eq 'Confirmed' }).Count) -Expected 3 -Message 'every reboot is confirmed when boot times advance'
Assert-Equal -Actual (Test-RebootActionsSuccessful -RebootActions $successRecords) -Expected $true -Message 'all-confirmed reboot actions are successful'
$idxS3Base = $script:readCallLog.IndexOf('readtime:VM03:0')
$idxS1Conf = $script:readCallLog.IndexOf('readtime:VM01:1')
$idxS2Conf = $script:readCallLog.IndexOf('readtime:VM02:1')
Assert-Equal -Actual ($idxS3Base -gt $idxS1Conf) -Expected $true -Message 'second batch baseline read starts only after first batch confirmed'
Assert-Equal -Actual ($idxS3Base -gt $idxS2Conf) -Expected $true -Message 'second batch waits for every first-batch confirmation before boot time read'

# Timeout then abort: batch 1 never confirms, operator aborts, batch 2 not started.
Reset-RebootTestState
$abortTargets = @(
    (New-RebootTestTarget -Sequence 1 -VMName 'VM01'),
    (New-RebootTestTarget -Sequence 2 -VMName 'VM02')
)
$neverConfirmReadScript = {
    param($Items)
    $out = @()
    foreach ($it in @($Items)) {
        $name = [string]$it.VMName
        if (-not $script:readAttempts.ContainsKey($name)) { $script:readAttempts[$name] = 0 }
        $script:readAttempts[$name]++
        $out += [pscustomobject]@{ VMName = $name; BootTimeUtc = $baseTime; Error = $null }
    }
    return @($out)
}
$waitAbortDecisionScript = {
    param($Context)
    return 'ABORT'
}
$abortRecords = @(Invoke-RebootBatchCoordinator -RebootTargets $abortTargets -BatchSize 1 -WaitTimeoutSeconds 0 -PollSeconds 1 -ReadBootTimeScript $neverConfirmReadScript -InitiateRebootScript $successInitiateScript -DecisionPromptScript $waitAbortDecisionScript -SleepScript { param($Seconds) $null = $Seconds })
$vm01Abort = @($abortRecords | Where-Object { $_.vmName -eq 'VM01' })[0]
$vm02Abort = @($abortRecords | Where-Object { $_.vmName -eq 'VM02' })[0]
Assert-Equal -Actual $vm01Abort.validationStatus -Expected 'Timeout' -Message 'aborted unconfirmed reboot is recorded as timeout'
Assert-Equal -Actual $vm01Abort.operatorDecision -Expected 'ABORT' -Message 'aborted unconfirmed reboot records operator decision'
Assert-Equal -Actual $vm02Abort.action -Expected 'NotStartedAfterAbort' -Message 'later batch is not rebooted after abort'
Assert-Equal -Actual (Test-RebootActionsSuccessful -RebootActions $abortRecords) -Expected $false -Message 'aborted reboot run is unsuccessful'

# Baseline abort: no reboot is initiated, but the current and remaining targets are recorded.
Reset-RebootTestState
$missingBaselineReadScript = {
    param($Items)
    return @($Items | ForEach-Object { [pscustomobject]@{ VMName = $_.VMName; BootTimeUtc = $null; Error = 'VMware Tools are not running' } })
}
$baselineAbortDecisionScript = {
    param($Context)
    return 'ABORT'
}
$baselineAbortRecords = @(Invoke-RebootBatchCoordinator -RebootTargets $abortTargets -BatchSize 1 -WaitTimeoutSeconds 3600 -PollSeconds 1 -ReadBootTimeScript $missingBaselineReadScript -InitiateRebootScript $successInitiateScript -DecisionPromptScript $baselineAbortDecisionScript -SleepScript { param($Seconds) $null = $Seconds })
$vm01BaselineAbort = @($baselineAbortRecords | Where-Object { $_.vmName -eq 'VM01' })[0]
$vm02BaselineAbort = @($baselineAbortRecords | Where-Object { $_.vmName -eq 'VM02' })[0]
Assert-Equal -Actual $baselineAbortRecords.Count -Expected 2 -Message 'baseline abort records current and remaining targets'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $vm01BaselineAbort -Path @('action')) -Expected 'NotStartedAfterAbort' -Message 'baseline abort records current target as not started'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $vm01BaselineAbort -Path @('lastError')) -Expected 'VMware Tools are not running' -Message 'baseline abort preserves baseline read error'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $vm02BaselineAbort -Path @('action')) -Expected 'NotStartedAfterAbort' -Message 'baseline abort records later target as not started'
Assert-Equal -Actual (Test-RebootActionsSuccessful -RebootActions $baselineAbortRecords) -Expected $false -Message 'baseline abort is unsuccessful'

$baselineAbortNumberTargets = @(
    (New-RebootTestTarget -Sequence 1 -VMName 'VM01'),
    (New-RebootTestTarget -Sequence 2 -VMName 'VM02'),
    (New-RebootTestTarget -Sequence 3 -VMName 'VM03')
)
$baselineAbortNumberRecords = @(Invoke-RebootBatchCoordinator -RebootTargets $baselineAbortNumberTargets -BatchSize 1 -WaitTimeoutSeconds 3600 -PollSeconds 1 -ReadBootTimeScript $missingBaselineReadScript -InitiateRebootScript $successInitiateScript -DecisionPromptScript $baselineAbortDecisionScript -SleepScript { param($Seconds) $null = $Seconds })
$vm03BaselineAbort = @($baselineAbortNumberRecords | Where-Object { $_.vmName -eq 'VM03' })[0]
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $vm03BaselineAbort -Path @('batchNumber')) -Expected 3 -Message 'each skipped batch keeps its original batch number'

# Timeout retry: the original reboot is observed again without a second initiation.
Reset-RebootTestState
$retryReadScript = {
    param($Items)
    $out = @()
    foreach ($it in @($Items)) {
        $name = [string]$it.VMName
        if (-not $script:readAttempts.ContainsKey($name)) { $script:readAttempts[$name] = 0 }
        $attempt = $script:readAttempts[$name]
        $script:readAttempts[$name]++
        $boot = if ($attempt -lt 2) { $baseTime } else { $newTime }
        $out += [pscustomobject]@{ VMName = $name; BootTimeUtc = $boot; Error = $null }
    }
    return @($out)
}
$retryDecisionScript = {
    param($Context)
    return 'RETRY'
}
$retryRecords = @(Invoke-RebootBatchCoordinator -RebootTargets @($abortTargets[0]) -BatchSize 1 -WaitTimeoutSeconds 0 -PollSeconds 1 -ReadBootTimeScript $retryReadScript -InitiateRebootScript $successInitiateScript -DecisionPromptScript $retryDecisionScript -SleepScript { param($Seconds) $null = $Seconds })
Assert-Equal -Actual $retryRecords.Count -Expected 1 -Message 'retry run returns one reboot record'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject (@($retryRecords)[0]) -Path @('validationStatus')) -Expected 'Confirmed' -Message 'retry eventually confirms boot time'
Assert-Equal -Actual $script:rebootCallLog.Count -Expected 1 -Message 'retry does not initiate a second reboot'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject (@($retryRecords)[0]) -Path @('timeoutCount')) -Expected 1 -Message 'retry records the first timeout'

$sleepDurations = New-Object System.Collections.Generic.List[int]
$waitItem = [pscustomobject]@{
    Sequence = 1; VMName = 'VM01'; ProcessId = 44; RebootReason = 'Reported after apply'; BatchNumber = 1
    BootTimeBaseline = $baseTime; BootTimeObserved = $baseTime; Confirmed = $false
    AttemptCount = 0; TimeoutCount = 0; LastErrorMessage = $null; ReadTimeoutSeconds = $null
}
$boundedWait = Wait-RebootBatchBootTimes -Items @($waitItem) -WaitTimeoutSeconds 1 -PollSeconds 10 -ReadBootTimeScript $neverConfirmReadScript -SleepScript { param($Seconds) $sleepDurations.Add($Seconds) }
Assert-Equal -Actual $boundedWait.TimedOut -Expected $true -Message 'boot time wait honors the timeout deadline'
Assert-Equal -Actual (@($sleepDurations | Where-Object { $_ -gt 1 }).Count) -Expected 0 -Message 'boot time polling never sleeps past the timeout'
Assert-Equal -Actual $waitItem.ReadTimeoutSeconds -Expected 1 -Message 'boot time read receives remaining timeout budget'

$pollGuardThrew = $false
try {
    Wait-RebootBatchBootTimes -Items @() -WaitTimeoutSeconds 1 -PollSeconds 0 -ReadBootTimeScript { param($Items) @() } | Out-Null
}
catch {
    $pollGuardThrew = $true
}
Assert-Equal -Actual $pollGuardThrew -Expected $true -Message 'boot time polling rejects non-positive PollSeconds'

# Baseline shortfall continued: VM restarts without validation and is marked unverified.
Reset-RebootTestState
$shortfallReadScript = {
    param($Items)
    $out = @()
    foreach ($it in @($Items)) {
        $name = [string]$it.VMName
        if ($name -eq 'VM01') {
            $out += [pscustomobject]@{ VMName = $name; BootTimeUtc = $null; Error = 'VMware Tools are not running' }
            continue
        }
        if (-not $script:readAttempts.ContainsKey($name)) { $script:readAttempts[$name] = 0 }
        $attempt = $script:readAttempts[$name]
        $script:readAttempts[$name]++
        $boot = if ($attempt -eq 0) { $baseTime } else { $newTime }
        $out += [pscustomobject]@{ VMName = $name; BootTimeUtc = $boot; Error = $null }
    }
    return @($out)
}
$shortfallDecisionScript = {
    param($Context)
    if ($Context.Stage -eq 'BaselineShortfall') { return 'CONTINUE' }
    return 'ABORT'
}
$shortfallTargets = @(
    (New-RebootTestTarget -Sequence 1 -VMName 'VM01'),
    (New-RebootTestTarget -Sequence 2 -VMName 'VM02')
)
$shortfallRecords = @(Invoke-RebootBatchCoordinator -RebootTargets $shortfallTargets -BatchSize 2 -WaitTimeoutSeconds 3600 -PollSeconds 1 -ReadBootTimeScript $shortfallReadScript -InitiateRebootScript $successInitiateScript -DecisionPromptScript $shortfallDecisionScript -SleepScript { param($Seconds) $null = $Seconds })
$vm01Shortfall = @($shortfallRecords | Where-Object { $_.vmName -eq 'VM01' })[0]
$vm02Shortfall = @($shortfallRecords | Where-Object { $_.vmName -eq 'VM02' })[0]
Assert-Equal -Actual $vm01Shortfall.validationStatus -Expected 'Unverified' -Message 'baseline shortfall continue restarts without validation'
Assert-Equal -Actual $vm01Shortfall.operatorDecision -Expected 'CONTINUE' -Message 'baseline shortfall continue records operator decision'
Assert-Equal -Actual $vm02Shortfall.validationStatus -Expected 'Confirmed' -Message 'validated batch member still confirms'
Assert-Equal -Actual (Test-RebootActionsSuccessful -RebootActions $shortfallRecords) -Expected $false -Message 'unverified reboot makes run unsuccessful'

# Initiation error continued: failed target recorded, validated target still confirms.
Reset-RebootTestState
$initFailTargets = @(
    (New-RebootTestTarget -Sequence 1 -VMName 'VM01'),
    (New-RebootTestTarget -Sequence 2 -VMName 'VM02')
)
$initFailDecisionScript = {
    param($Context)
    if ($Context.Stage -eq 'InitiationError') { return 'CONTINUE' }
    return 'ABORT'
}
$initFailInitiateScript = {
    param($Items)
    $out = @()
    foreach ($it in @($Items)) {
        $error = if ($it.VMName -eq 'VM01') { 'Failed to start shutdown.exe' } else { $null }
        $out += [pscustomobject]@{ VMName = $it.VMName; ProcessId = if ($null -eq $error) { 200 } else { $null }; Error = $error }
    }
    return @($out)
}
$initFailRecords = @(Invoke-RebootBatchCoordinator -RebootTargets $initFailTargets -BatchSize 2 -WaitTimeoutSeconds 3600 -PollSeconds 1 -ReadBootTimeScript $successReadScript -InitiateRebootScript $initFailInitiateScript -DecisionPromptScript $initFailDecisionScript -SleepScript { param($Seconds) $null = $Seconds })
$vm01InitFail = @($initFailRecords | Where-Object { $_.vmName -eq 'VM01' })[0]
$vm02InitFail = @($initFailRecords | Where-Object { $_.vmName -eq 'VM02' })[0]
Assert-Equal -Actual $vm01InitFail.action -Expected 'Failed' -Message 'initiation error marks target failed'
Assert-Equal -Actual $vm01InitFail.validationStatus -Expected 'InitiationError' -Message 'initiation error status is explicit'
Assert-Equal -Actual $vm02InitFail.validationStatus -Expected 'Confirmed' -Message 'remaining batch member still confirms after init error continue'
Assert-Equal -Actual (Test-RebootActionsSuccessful -RebootActions $initFailRecords) -Expected $false -Message 'initiation error makes run unsuccessful'
# Wait timeout answered with CONTINUE: this is the path that both mints Unverified records and
# opens the gate for the next batch, so it needs its own coverage.
Reset-RebootTestState
$timeoutContinueTargets = @(
    (New-RebootTestTarget -Sequence 1 -VMName 'VM01'),
    (New-RebootTestTarget -Sequence 2 -VMName 'VM02')
)
$timeoutContinueDecisionScript = {
    param($Context)
    if ($Context.Stage -eq 'WaitTimeout') { return 'CONTINUE' }
    Add-Failure -Message ('Unexpected operator prompt stage: {0}' -f $Context.Stage)
    return 'ABORT'
}
# VM01 never advances its boot time; VM02 (second batch) confirms normally.
$timeoutContinueReadScript = {
    param($Items)
    $out = @()
    foreach ($it in @($Items)) {
        $name = [string]$it.VMName
        if (-not $script:readAttempts.ContainsKey($name)) { $script:readAttempts[$name] = 0 }
        $attempt = $script:readAttempts[$name]
        $script:readAttempts[$name]++
        $boot = if ($name -eq 'VM01') { $baseTime } elseif ($attempt -eq 0) { $baseTime } else { $newTime }
        $out += [pscustomobject]@{ VMName = $name; BootTimeUtc = $boot; Error = $null }
    }
    return @($out)
}
$timeoutContinueRecords = @(Invoke-RebootBatchCoordinator -RebootTargets $timeoutContinueTargets -BatchSize 1 -WaitTimeoutSeconds 0 -PollSeconds 1 -ReadBootTimeScript $timeoutContinueReadScript -InitiateRebootScript $successInitiateScript -DecisionPromptScript $timeoutContinueDecisionScript -SleepScript { param($Seconds) $null = $Seconds })
$vm01TimeoutContinue = @($timeoutContinueRecords | Where-Object { $_.vmName -eq 'VM01' })[0]
$vm02TimeoutContinue = @($timeoutContinueRecords | Where-Object { $_.vmName -eq 'VM02' })[0]
Assert-Equal -Actual $vm01TimeoutContinue.validationStatus -Expected 'Unverified' -Message 'timeout answered with CONTINUE records an unverified reboot'
Assert-Equal -Actual $vm01TimeoutContinue.operatorDecision -Expected 'CONTINUE' -Message 'timeout CONTINUE records the operator decision'
Assert-Equal -Actual $vm01TimeoutContinue.action -Expected 'Initiated' -Message 'timeout CONTINUE keeps the reboot marked as initiated'
Assert-Equal -Actual ($script:rebootCallLog -contains 'restart:VM02') -Expected $true -Message 'timeout CONTINUE opens the gate for the next batch'
Assert-Equal -Actual $vm02TimeoutContinue.validationStatus -Expected 'Confirmed' -Message 'next batch still validates normally after a forced continue'
Assert-Equal -Actual $vm02TimeoutContinue.batchNumber -Expected 2 -Message 'next batch keeps its own batch number after a forced continue'
Assert-Equal -Actual (Test-RebootActionsSuccessful -RebootActions $timeoutContinueRecords) -Expected $false -Message 'a forced continue makes the run unsuccessful'
# A job input that carries no VMOutputDirectory (the boot-time read shape) must still produce an
# error result. Under StrictMode a direct property read here throws and tears down the whole
# reboot phase after shutdown.exe has already gone out to the guests.
$bootTimeJobInput = [pscustomobject]@{
    Sequence = 7; VMName = 'VM07'; VIServers = @('vc'); GuestOpsLibPath = 'lib'
    CurlPath = 'curl.exe'; GuestWorkingDirectory = 'C:\ProgramData\PatchingGuestOps'
    BootTimeHelperPath = 'helper'; TimeoutSeconds = 120; PollSeconds = 5
}
$bootTimeErrorResult = $null
$bootTimeErrorThrew = $false
try {
    $bootTimeErrorResult = New-ThrottledJobErrorResult -InputObject $bootTimeJobInput -ErrorMessage 'Job timed out after 240 seconds.'
}
catch {
    $bootTimeErrorThrew = $true
}
Assert-Equal -Actual $bootTimeErrorThrew -Expected $false -Message 'job error result tolerates an input without VMOutputDirectory'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $bootTimeErrorResult -Path @('VMName')) -Expected 'VM07' -Message 'job error result keeps the VM name for a boot-time input'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $bootTimeErrorResult -Path @('VMOutputDirectory')) -Expected $null -Message 'missing VMOutputDirectory degrades to null'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $bootTimeErrorResult -Path @('Error')) -Expected 'Job timed out after 240 seconds.' -Message 'job error result carries the error message'

# A VM the initiation script never reports on at all must not vanish from the artifact.
Reset-RebootTestState
$missingResultInitiateScript = {
    param($Items)
    # VM02 is dropped entirely: no success entry, no error entry.
    return @(@($Items) | Where-Object { $_.VMName -eq 'VM01' } | ForEach-Object { [pscustomobject]@{ VMName = $_.VMName; ProcessId = 300; Error = $null } })
}
$missingResultRecords = @(Invoke-RebootBatchCoordinator -RebootTargets $initFailTargets -BatchSize 2 -WaitTimeoutSeconds 3600 -PollSeconds 1 -ReadBootTimeScript $successReadScript -InitiateRebootScript $missingResultInitiateScript -DecisionPromptScript $initFailDecisionScript -SleepScript { param($Seconds) $null = $Seconds })
Assert-Equal -Actual $missingResultRecords.Count -Expected 2 -Message 'a dropped initiation result still yields a record'
$vm02Missing = @($missingResultRecords | Where-Object { $_.vmName -eq 'VM02' })[0]
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $vm02Missing -Path @('action')) -Expected 'Failed' -Message 'a dropped initiation result is recorded as failed'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $vm02Missing -Path @('validationStatus')) -Expected 'InitiationError' -Message 'a dropped initiation result uses the initiation error status'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $vm02Missing -Path @('lastError')) -Expected 'No reboot initiation result was returned.' -Message 'a dropped initiation result explains itself'
Assert-Equal -Actual (Test-RebootActionsSuccessful -RebootActions $missingResultRecords) -Expected $false -Message 'a dropped initiation result makes the run unsuccessful'

# Sort-Object is unstable in Windows PowerShell 5.1, so a batch wide enough to expose it must
# still come back in the original target order.
Reset-RebootTestState
$orderTargets = @(1..12 | ForEach-Object { New-RebootTestTarget -Sequence $_ -VMName ('VM{0:d2}' -f $_) })
$orderRecords = @(Invoke-RebootBatchCoordinator -RebootTargets $orderTargets -BatchSize 12 -WaitTimeoutSeconds 3600 -PollSeconds 1 -ReadBootTimeScript $successReadScript -InitiateRebootScript $successInitiateScript -DecisionPromptScript $successDecisionScript -SleepScript { param($Seconds) $null = $Seconds })
$orderNames = @($orderRecords | ForEach-Object { [string]$_.vmName }) -join ','
$expectedOrderNames = @(1..12 | ForEach-Object { 'VM{0:d2}' -f $_ }) -join ','
Assert-Equal -Actual $orderNames -Expected $expectedOrderNames -Message 'records keep the original target order inside a batch'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject (@($orderRecords)[0]) -Path @('sequence')) -Expected 1 -Message 'reboot record carries the target sequence'
# One batch is emitted as a single object that is itself an array; losing the outer level turns
# every VM into its own batch and silently serialises a run the operator asked to parallelise.
Assert-Equal -Actual (@($orderRecords | Where-Object { $_.batchNumber -eq 1 }).Count) -Expected 12 -Message 'a single full-size batch stays one batch'
Reset-RebootTestState
$oneBatchTargets = @(
    (New-RebootTestTarget -Sequence 1 -VMName 'VM01'),
    (New-RebootTestTarget -Sequence 2 -VMName 'VM02'),
    (New-RebootTestTarget -Sequence 3 -VMName 'VM03')
)
$oneBatchRecords = @(Invoke-RebootBatchCoordinator -RebootTargets $oneBatchTargets -BatchSize 3 -WaitTimeoutSeconds 3600 -PollSeconds 1 -ReadBootTimeScript $successReadScript -InitiateRebootScript $successInitiateScript -DecisionPromptScript $successDecisionScript -SleepScript { param($Seconds) $null = $Seconds })
Assert-Equal -Actual (@($oneBatchRecords | Where-Object { $_.batchNumber -eq 1 }).Count) -Expected 3 -Message 'targets matching ThrottleLimit reboot as one batch, not one batch per VM'
$firstReadIndex = $script:readCallLog.IndexOf('readtime:VM03:0')
$firstConfirmIndex = $script:readCallLog.IndexOf('readtime:VM01:1')
Assert-Equal -Actual ($firstReadIndex -lt $firstConfirmIndex) -Expected $true -Message 'a single batch reads every baseline before any confirmation'


# --- Shared VM-target parsing (scripts/VMTargetLib.ps1 + launcher prompt wrapper) ---
# The pure helpers live in a dot-sourceable lib; the launcher's Resolve-VMTargetNames adds
# the interactive prompt loop on top and has top-level side effects, so it is extracted via
# the AST and exercised with a Read-Host override.
. (Join-Path $repoRoot 'scripts\VMTargetLib.ps1')

$launcherPath = Join-Path $repoRoot 'Start-PatchingGuestOps.ps1'
$launcherTokens = $null
$launcherErrors = $null
$launcherAst = [System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$launcherTokens, [ref]$launcherErrors)
$launcherFunctions = @($launcherAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
$resolveDefinition = @($launcherFunctions | Where-Object { $_.Name -eq 'Resolve-VMTargetNames' })
if ($resolveDefinition.Count -eq 0) {
    Add-Failure -Message 'Launcher function not found: Resolve-VMTargetNames'
}
else {
    . ([scriptblock]::Create($resolveDefinition[0].Extent.Text))
}

$resolveVIServerDefinition = @($launcherFunctions | Where-Object { $_.Name -eq 'Resolve-VIServerNames' })
if ($resolveVIServerDefinition.Count -eq 0) {
    Add-Failure -Message 'Launcher function not found: Resolve-VIServerNames'
}
else {
    . ([scriptblock]::Create($resolveVIServerDefinition[0].Extent.Text))
}

$fromSourcesEmpty = @(Resolve-VMTargetNamesFromSources -SingleVMName '' -ManyVMNames @() -ListPath '')
Assert-Equal -Actual $fromSourcesEmpty.Count -Expected 0 -Message 'no sources yields an empty target list (no prompt, no throw)'

$fromSourcesMerged = @(Resolve-VMTargetNamesFromSources -SingleVMName 'VM01' -ManyVMNames @('VM02', 'VM01') -ListPath '')
Assert-Equal -Actual ($fromSourcesMerged -join ',') -Expected 'VM01,VM02' -Message 'sources merge across single and many, deduplicated in order'

$vmListPath = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-vmlist-' + [guid]::NewGuid().ToString('N') + '.txt')
Set-Content -LiteralPath $vmListPath -Value @('# comment', 'VM03', '', '  VM04  ', 'VM03') -Encoding UTF8
try {
    $fromList = @(Resolve-VMTargetNamesFromSources -SingleVMName '' -ManyVMNames @() -ListPath $vmListPath)
    Assert-Equal -Actual ($fromList -join ',') -Expected 'VM03,VM04' -Message 'VM-list file is read, comment/blank lines skipped, names trimmed and deduplicated'
}
finally {
    Remove-Item -LiteralPath $vmListPath -Force -ErrorAction SilentlyContinue
}

$splitMixed = @(Split-VMNameInput -InputText 'VM01, VM02; VM03')
Assert-Equal -Actual ($splitMixed -join ',') -Expected 'VM01,VM02,VM03' -Message 'fallback splits VM names on comma and semicolon and trims whitespace'

$splitEmpties = @(Split-VMNameInput -InputText ' VM01 ,, ;  ; VM02 ')
Assert-Equal -Actual ($splitEmpties -join ',') -Expected 'VM01,VM02' -Message 'fallback skips empty and whitespace-only tokens'

$splitDuplicates = @(Split-VMNameInput -InputText 'VM01; VM02; VM01')
Assert-Equal -Actual ($splitDuplicates -join ',') -Expected 'VM01,VM02' -Message 'fallback removes duplicate VM names'

$splitSingle = @(Split-VMNameInput -InputText '  VM01  ')
Assert-Equal -Actual $splitSingle.Count -Expected 1 -Message 'fallback treats one name as a single-element list'
Assert-Equal -Actual $splitSingle[0] -Expected 'VM01' -Message 'single fallback name is returned trimmed'

$splitBlank = @(Split-VMNameInput -InputText '   ')
Assert-Equal -Actual $splitBlank.Count -Expected 0 -Message 'whitespace-only fallback input yields no names'

$uniqueNames = @(Get-UniqueTrimmedNames -Names @('VM01', ' VM02 ', '', '  ', 'VM01', 'VM03'))
Assert-Equal -Actual ($uniqueNames -join ',') -Expected 'VM01,VM02,VM03' -Message 'name normalization trims, drops blanks, and removes duplicates in order'

$splitVIServers = @(Split-VIServerInput -InputText 'vc01; vc02 ; vc01')
Assert-Equal -Actual ($splitVIServers -join ',') -Expected 'vc01,vc02' -Message 'vCenter fallback splits only on semicolon, trims whitespace, and removes duplicates'

$splitVIServerComma = @(Split-VIServerInput -InputText 'vc01, vc02')
Assert-Equal -Actual $splitVIServerComma.Count -Expected 1 -Message 'vCenter fallback does not split on comma'
Assert-Equal -Actual $splitVIServerComma[0] -Expected 'vc01, vc02' -Message 'comma is preserved inside a vCenter token'

$splitVIServerBlank = @(Split-VIServerInput -InputText '   ')
Assert-Equal -Actual $splitVIServerBlank.Count -Expected 0 -Message 'whitespace-only vCenter fallback input yields no names'

$explicitVIServers = @(Resolve-VIServerNames -InputText 'vc03;vc04;vc03')
Assert-Equal -Actual ($explicitVIServers -join ',') -Expected 'vc03,vc04' -Message 'explicit vCenter input is split and deduplicated'

$script:viserverPromptMessages = @()
$script:viserverCredentialQueue = New-Object System.Collections.Queue
$script:viserverCredentialQueue.Enqueue((New-TestCredential -UserName 'CONTOSO\vc-admin'))
$script:viserverCredentialQueue.Enqueue((New-TestCredential -UserName 'FABRIKAM\vc-admin'))
$script:viserverCredentialQueue.Enqueue((New-TestCredential -UserName '.\local-admin'))
$viserverCredentialMap = Resolve-VIServerCredentialMap -VIServers @(
    'vc02.contoso.com',
    'vc01.contoso.com',
    'vc01.fabrikam.local',
    'legacy-vc'
) -CredentialPromptScript {
    param([string]$Message)
    $script:viserverPromptMessages += $Message
    return $script:viserverCredentialQueue.Dequeue()
}

Assert-Equal -Actual $script:viserverPromptMessages.Count -Expected 3 -Message 'vCenter credentials are prompted once per domain plus once per local vCenter'
Assert-Contains -Text $script:viserverPromptMessages[0] -Needle 'contoso.com' -Message 'first vCenter prompt names the contoso domain'
Assert-Contains -Text $script:viserverPromptMessages[1] -Needle 'fabrikam.local' -Message 'second vCenter prompt names the fabrikam domain'
Assert-Contains -Text $script:viserverPromptMessages[2] -Needle 'legacy-vc' -Message 'local vCenter prompt names the vCenter'
Assert-Equal -Actual $viserverCredentialMap['vc02.contoso.com'].UserName -Expected 'CONTOSO\vc-admin' -Message 'same-domain vCenter gets the domain credential'
Assert-Equal -Actual $viserverCredentialMap['vc01.contoso.com'].UserName -Expected 'CONTOSO\vc-admin' -Message 'same-domain vCenter reuses one credential prompt'
Assert-Equal -Actual $viserverCredentialMap['vc01.fabrikam.local'].UserName -Expected 'FABRIKAM\vc-admin' -Message 'different vCenter domain gets a separate credential'
Assert-Equal -Actual $viserverCredentialMap['legacy-vc'].UserName -Expected '.\local-admin' -Message 'no-dot vCenter gets its own local credential'

$overrideVIServerCredential = New-TestCredential -UserName 'SHARED\override'
$script:overrideVIServerPromptCount = 0
$overrideVIServerCredentialMap = Resolve-VIServerCredentialMap -VIServers @('vc01.contoso.com', 'vc01.fabrikam.local') -OverrideCredential $overrideVIServerCredential -CredentialPromptScript {
    param([string]$Message)
    $script:overrideVIServerPromptCount++
    throw 'override should not prompt'
}

Assert-Equal -Actual $script:overrideVIServerPromptCount -Expected 0 -Message 'explicit vCenter credential bypasses grouped prompts'
Assert-Equal -Actual $overrideVIServerCredentialMap['vc01.contoso.com'].UserName -Expected 'SHARED\override' -Message 'override credential applies to first vCenter'
Assert-Equal -Actual $overrideVIServerCredentialMap['vc01.fabrikam.local'].UserName -Expected 'SHARED\override' -Message 'override credential applies to second vCenter'

$retryVIServerCredentialMap = @{
    'vc01.contoso.com' = New-TestCredential -UserName 'CONTOSO\vc-admin'
    'vc02.contoso.com' = New-TestCredential -UserName 'CONTOSO\vc-admin'
}
$script:connectAttempts = @{}
$script:retryPromptMessages = @()
$retryConnections = @(Connect-VIServersWithCredentialMap -VIServers @('vc01.contoso.com', 'vc02.contoso.com') -CredentialMap $retryVIServerCredentialMap -RetryOnFailure -ConnectScript {
    param($Server, $Credential)
    if (-not $script:connectAttempts.ContainsKey($Server)) {
        $script:connectAttempts[$Server] = 0
    }
    $script:connectAttempts[$Server]++

    if ($Server -eq 'vc02.contoso.com' -and $Credential.UserName -eq 'CONTOSO\vc-admin') {
        throw 'domain credential rejected'
    }

    return [pscustomobject]@{
        Server = $Server
        UserName = $Credential.UserName
    }
} -CredentialPromptScript {
    param([string]$Message)
    $script:retryPromptMessages += $Message
    return New-TestCredential -UserName 'administrator@vsphere.local'
} 3>$null)

Assert-Equal -Actual $retryConnections.Count -Expected 2 -Message 'retrying vCenter connection returns both successful connections'
Assert-Equal -Actual $script:connectAttempts['vc01.contoso.com'] -Expected 1 -Message 'successful same-domain vCenter is not retried'
Assert-Equal -Actual $script:connectAttempts['vc02.contoso.com'] -Expected 2 -Message 'failed same-domain vCenter is retried after prompting'
Assert-Equal -Actual $script:retryPromptMessages.Count -Expected 1 -Message 'vCenter retry prompts only for the failed vCenter'
Assert-Contains -Text $script:retryPromptMessages[0] -Needle 'vc02.contoso.com' -Message 'vCenter retry prompt names the failed vCenter'
Assert-Equal -Actual $retryVIServerCredentialMap['vc01.contoso.com'].UserName -Expected 'CONTOSO\vc-admin' -Message 'retry does not replace credential for successful vCenter'
Assert-Equal -Actual $retryVIServerCredentialMap['vc02.contoso.com'].UserName -Expected 'administrator@vsphere.local' -Message 'retry stores replacement credential for failed vCenter'

$script:vcenterPrompts = @()
$vcenterResponses = New-Object System.Collections.Queue
$vcenterResponses.Enqueue('   ')
$vcenterResponses.Enqueue('vc01; vc02; vc01')
function Read-Host {
    param([Parameter(Position = 0)][string]$Prompt)
    $script:vcenterPrompts += $Prompt
    return $vcenterResponses.Dequeue()
}

$fallbackVIServers = @(Resolve-VIServerNames -InputText '')
Assert-Equal -Actual ($fallbackVIServers -join ',') -Expected 'vc01,vc02' -Message 'empty vCenter input prompts for semicolon-separated vCenter names'
Assert-Equal -Actual $script:vcenterPrompts.Count -Expected 2 -Message 'blank vCenter fallback input re-prompts until a name is provided'
Assert-Equal -Actual $script:vcenterPrompts[0] -Expected 'vCenter(s), separated by ";"' -Message 'vCenter fallback prompt asks for semicolon separated names'

# The empty-source fallback must loop until at least one name is supplied. Override
# Read-Host (interactive, so unavoidable to mock) with scripted responses.
$script:fallbackPrompts = @()
$fallbackResponses = New-Object System.Collections.Queue
$fallbackResponses.Enqueue('   ')
$fallbackResponses.Enqueue('VM01; VM02, VM01')
function Read-Host {
    param([Parameter(Position = 0)][string]$Prompt)
    $script:fallbackPrompts += $Prompt
    return $fallbackResponses.Dequeue()
}

$fallbackTargets = @(Resolve-VMTargetNames -SingleVMName '' -ManyVMNames @() -ListPath '')
Assert-Equal -Actual ($fallbackTargets -join ',') -Expected 'VM01,VM02' -Message 'empty sources prompt for any number of VM names, split and deduplicated'
Assert-Equal -Actual $script:fallbackPrompts.Count -Expected 2 -Message 'blank fallback input re-prompts until a name is provided'
Assert-Equal -Actual $script:fallbackPrompts[0] -Expected 'VM name(s), separated by ";"' -Message 'fallback prompt asks for semicolon separated names'

# --- VM lookup candidates (scripts/GuestOpsLib.ps1) ---
Assert-Equal -Actual ((Get-VMLookupCandidates -Name 'vm1.contoso.com') -join '|') -Expected 'vm1|vm1.contoso.com' -Message 'FQDN yields short name then full fallback'
Assert-Equal -Actual ((Get-VMLookupCandidates -Name 'oldbox') -join '|') -Expected 'oldbox' -Message 'bare hostname yields a single candidate'
Assert-Equal -Actual ((Get-VMLookupCandidates -Name 'host.sub.contoso.com') -join '|') -Expected 'host|host.sub.contoso.com' -Message 'multi-level FQDN splits at the first dot only'

# --- Guest credential grouping (scripts/VMTargetLib.ps1) ---
$credGroups = @(Get-GuestCredentialGroups -TargetNames @('vm2.contoso.com', 'vm1.contoso.com', 'app.fabrikam.local', 'oldbox'))
Assert-Equal -Actual $credGroups.Count -Expected 3 -Message 'two domains plus one local form three groups'
$contosoGroup = @($credGroups | Where-Object { $_.Key -eq 'contoso.com' })[0]
Assert-Equal -Actual $contosoGroup.Kind -Expected 'Domain' -Message 'domain group has Domain kind'
Assert-Equal -Actual (@($contosoGroup.Members) -join ',') -Expected 'vm2.contoso.com,vm1.contoso.com' -Message 'domain group keeps members in input order'
$localGroup = @($credGroups | Where-Object { $_.Key -eq 'oldbox' })[0]
Assert-Equal -Actual $localGroup.Kind -Expected 'Local' -Message 'no-dot entry is a Local group'
Assert-Equal -Actual (@($localGroup.Members) -join ',') -Expected 'oldbox' -Message 'local group holds the one machine'
$mixedCaseGroups = @(Get-GuestCredentialGroups -TargetNames @('A.Contoso.COM', 'b.contoso.com'))
Assert-Equal -Actual $mixedCaseGroups.Count -Expected 1 -Message 'domain grouping is case-insensitive'

if ($failures.Count -gt 0) {
    Write-Host 'Runtime checks failed:'
    foreach ($failure in $failures) {
        Write-Host (" - {0}" -f $failure)
    }
    exit 1
}

Write-Host 'Runtime checks passed.'
exit 0

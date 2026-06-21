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

$throttleGuardThrew = $false
try { Invoke-ThrottledJobs -Items @() -ThrottleLimit 0 -JobTimeoutSeconds 30 -ScriptBlock { param($i) $i } | Out-Null }
catch { $throttleGuardThrew = $true }
Assert-Equal -Actual $throttleGuardThrew -Expected $true -Message 'Invoke-ThrottledJobs throws on ThrottleLimit below 1'

$timeoutGuardThrew = $false
try { Invoke-ThrottledJobs -Items @() -ThrottleLimit 1 -JobTimeoutSeconds 0 -ScriptBlock { param($i) $i } | Out-Null }
catch { $timeoutGuardThrew = $true }
Assert-Equal -Actual $timeoutGuardThrew -Expected $true -Message 'Invoke-ThrottledJobs throws on JobTimeoutSeconds below 1'

if ($failures.Count -gt 0) {
    Write-Host 'Runtime checks failed:'
    foreach ($failure in $failures) {
        Write-Host (" - {0}" -f $failure)
    }
    exit 1
}

Write-Host 'Runtime checks passed.'
exit 0

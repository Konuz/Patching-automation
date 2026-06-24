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

$rebootArgumentText = New-GuestRebootArguments
Assert-Contains -Text $rebootArgumentText -Needle '/r' -Message 'guest reboot arguments request restart'
Assert-Contains -Text $rebootArgumentText -Needle '/t 0' -Message 'guest reboot arguments request immediate reboot'
Assert-Contains -Text $rebootArgumentText -Needle '/c "PatchingGuestOps reboot after updates"' -Message 'guest reboot arguments include stable comment'

$quotedRebootArgumentText = New-GuestRebootArguments -Comment 'Reboot after "updates"'
Assert-Contains -Text $quotedRebootArgumentText -Needle '/c "Reboot after ''updates''"' -Message 'guest reboot comment replaces embedded double quotes'

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

$mixedApplyResults = @(
    [pscustomobject]@{ vmName = 'VM01'; action = 'Install'; outcome = 'InstallSucceeded'; rebootRequired = $true },
    [pscustomobject]@{ vmName = 'VM02'; action = 'Install'; outcome = 'InstallSucceeded'; rebootRequired = $false },
    [pscustomobject]@{ vmName = 'VM03'; action = 'Skip'; outcome = 'Skipped'; rebootRequired = $false }
)

$rebootTargets = @(Select-RebootRequiredApplyResults -ApplyResults $mixedApplyResults)
Assert-Equal -Actual $rebootTargets.Count -Expected 1 -Message 'only rebootRequired apply results become reboot targets'
Assert-Equal -Actual $rebootTargets[0].vmName -Expected 'VM01' -Message 'reboot target preserves VM name'

$skippedRebootActions = @(New-SkippedRebootActionRecords -RebootTargets $rebootTargets)
Assert-Equal -Actual $skippedRebootActions.Count -Expected 1 -Message 'skipped reboot action is created for every reboot target'
Assert-Equal -Actual $skippedRebootActions[0].action -Expected 'SkippedByOperator' -Message 'operator skip action is explicit'
Assert-Equal -Actual (Test-RebootActionsSuccessful -RebootActions $skippedRebootActions) -Expected $true -Message 'operator skip is not a reboot failure'

$failedRebootActions = @(
    (New-RebootActionRecord -VMName 'VM01' -Action 'Initiated' -ProcessId 42),
    (New-RebootActionRecord -VMName 'VM02' -Action 'Failed' -ErrorMessage 'VMware Tools are not running')
)
Assert-Equal -Actual (Test-RebootActionsSuccessful -RebootActions $failedRebootActions) -Expected $false -Message 'failed reboot action makes reboot phase unsuccessful'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-reboot-actions-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $tempRoot 'summary.md') -Value @('# Patch summary', '') -Encoding UTF8
    Write-RebootActionArtifacts -CycleOutputDirectory $tempRoot -RebootActions $failedRebootActions

    $rebootJsonPath = Join-Path $tempRoot 'reboot-actions.json'
    Assert-Equal -Actual (Test-Path -LiteralPath $rebootJsonPath -PathType Leaf) -Expected $true -Message 'reboot action artifact is written'

    $summaryText = Get-Content -LiteralPath (Join-Path $tempRoot 'summary.md') -Raw
    Assert-Contains -Text $summaryText -Needle 'Guest reboot actions' -Message 'summary includes reboot action section'
    Assert-Contains -Text $summaryText -Needle 'VMs with reboot initiation errors' -Message 'summary includes reboot error section'
    Assert-Contains -Text $summaryText -Needle 'VM02' -Message 'summary includes failed reboot VM name'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

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

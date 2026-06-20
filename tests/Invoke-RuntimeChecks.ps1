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
Assert-NotContains -Text $argumentText -Needle '-SelectedUpdateIds' -Message 'selected update ids are not emitted when only keys are supplied'

$searchOnlyText = New-GuestAgentArguments -GuestAgentPath 'C:\ProgramData\PatchingGuestOps\Run-LocalPatch.ps1' -GuestWorkingDirectory 'C:\ProgramData\PatchingGuestOps' -MaxUpdates 5 -SearchOnly
Assert-Contains -Text $searchOnlyText -Needle '-SearchOnly' -Message 'search-only flag is present'
Assert-NotContains -Text $searchOnlyText -Needle '-SelectedUpdateKeys' -Message 'search-only does not include selected keys'

if ($failures.Count -gt 0) {
    Write-Host 'Runtime checks failed:'
    foreach ($failure in $failures) {
        Write-Host (" - {0}" -f $failure)
    }
    exit 1
}

Write-Host 'Runtime checks passed.'
exit 0

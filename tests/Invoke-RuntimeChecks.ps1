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

# --- curl ignores the machine's own configuration -------------------------------------------
# Asserted at the program-execution boundary, not on the three argument lists separately: a
# curl that reads %APPDATA%\_curlrc or CURL_HOME/.curlrc can be handed --insecure, a proxy or
# a different CA store by whoever set that file up, and the transfer would then either fail
# TLS verification silently or succeed without it. --disable has to be the FIRST argument -
# curl applies the config before later flags, so a late --disable is too late.
& {
    $curlProbeDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-curl-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $curlProbeDirectory | Out-Null
    try {
        # A stand-in for curl.exe that records exactly what reached the program. Written as a
        # .ps1 so the same fixture works wherever the gate runs; `exit 0` sets $LASTEXITCODE
        # the way a native curl would.
        $fakeCurlPath = Join-Path $curlProbeDirectory 'fake-curl.ps1'
        $fakeCurlLogPath = Join-Path $curlProbeDirectory 'arguments.txt'
        $fakeCurlBody = @'
$args | Set-Content -LiteralPath '__LOG__' -Encoding UTF8
exit 0
'@
        Set-Content -LiteralPath $fakeCurlPath -Value ($fakeCurlBody.Replace('__LOG__', $fakeCurlLogPath)) -Encoding UTF8

        $readFakeCurlArguments = {
            return @(Get-Content -LiteralPath $fakeCurlLogPath)
        }

        # 1. The wrapper itself, called with a bare argument list.
        Remove-Item -LiteralPath $fakeCurlLogPath -Force -ErrorAction SilentlyContinue
        Invoke-Curl -CurlPath $fakeCurlPath -Arguments @('--silent', 'https://esxi.invalid/') -Description 'curl configuration probe'
        $wrapperArguments = @(& $readFakeCurlArguments)
        Assert-Equal -Actual $wrapperArguments[0] -Expected '--disable' -Message 'Invoke-Curl forces --disable as the first argument'
        Assert-Equal -Actual @($wrapperArguments | Where-Object { $_ -eq '--disable' }).Count -Expected 1 -Message 'Invoke-Curl does not duplicate --disable'
        Assert-Equal -Actual ($wrapperArguments -contains '-k') -Expected $false -Message 'Invoke-Curl never adds -k'
        Assert-Equal -Actual ($wrapperArguments -contains '--insecure') -Expected $false -Message 'Invoke-Curl never adds --insecure'

        # The PUT path needs VMware.Vim.GuestFileAttributes, so it is asserted the same way in
        # Invoke-GuestOpsHarnessChecks.ps1, where those types are available.
        $fakeFileManager = [pscustomobject]@{}
        $fakeFileManager | Add-Member ScriptMethod InitiateFileTransferFromGuest { param($MoRef, $GuestAuth, $GuestPath) return [pscustomobject]@{ Url = 'https://*/folder?token=fixture' } }
        $fakeVMView = [pscustomobject]@{ MoRef = 'vm-fixture' }

        # 2. The GET path.
        Remove-Item -LiteralPath $fakeCurlLogPath -Force -ErrorAction SilentlyContinue
        Receive-GuestFile -FileManager $fakeFileManager -VMView $fakeVMView -GuestAuth $null -HostName 'esxi.invalid' -CurlPath $fakeCurlPath -GuestPath 'C:\guest\status.json' -LocalPath (Join-Path $curlProbeDirectory 'downloaded.json')
        $getArguments = @(& $readFakeCurlArguments)
        Assert-Equal -Actual $getArguments[0] -Expected '--disable' -Message 'a download reaches curl with --disable first'
        Assert-Equal -Actual @($getArguments | Where-Object { $_ -eq '--disable' }).Count -Expected 1 -Message 'a download passes --disable once'
        Assert-Equal -Actual ($getArguments -contains '-k') -Expected $false -Message 'a download never disables TLS verification'
        Assert-Equal -Actual ($getArguments -contains '--insecure') -Expected $false -Message 'a download has no alternate insecure flag'
        Assert-Equal -Actual ($getArguments -contains '--max-time') -Expected $true -Message 'a download still carries its deadline'

        # 3. The endpoint probe. It must keep NOT sending --fail: an HTTP 401/403/405 after a
        # successful handshake proves TLS worked, and is not a trust failure.
        Remove-Item -LiteralPath $fakeCurlLogPath -Force -ErrorAction SilentlyContinue
        Assert-GuestTransferEndpoint -HostName 'esxi.invalid' -CurlPath $fakeCurlPath
        $probeArguments = @(& $readFakeCurlArguments)
        Assert-Equal -Actual $probeArguments[0] -Expected '--disable' -Message 'the endpoint probe reaches curl with --disable first'
        Assert-Equal -Actual @($probeArguments | Where-Object { $_ -eq '--disable' }).Count -Expected 1 -Message 'the endpoint probe passes --disable once'
        Assert-Equal -Actual ($probeArguments -contains '--fail') -Expected $false -Message 'the endpoint probe still omits --fail'
        Assert-Equal -Actual ($probeArguments -contains '--max-time') -Expected $true -Message 'the endpoint probe still carries its deadline'
        Assert-Equal -Actual ($probeArguments -contains '-k') -Expected $false -Message 'the endpoint probe never disables TLS verification'
    }
    finally {
        Remove-Item -LiteralPath $curlProbeDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Transfer timeout validation must happen during parameter binding, before any curl call.
$script:invalidTransferCurlCalls = 0
function Invoke-Curl {
    param([string]$CurlPath, [string[]]$Arguments, [string]$Description)
    $script:invalidTransferCurlCalls++
}

foreach ($transferFunctionName in @('Send-GuestFile', 'Receive-GuestFile')) {
    foreach ($invalidTimeoutSeconds in @(0, -1)) {
        $bindingError = $false
        try {
            & $transferFunctionName -FileManager $null -VMView $null -GuestAuth $null -HostName 'esxi.invalid' -CurlPath 'curl.exe' -LocalPath 'unused' -GuestPath 'unused' -TimeoutSeconds $invalidTimeoutSeconds
        }
        catch {
            $bindingError = $_.Exception.Message -like '*TimeoutSeconds*' -and $_.Exception.Message -match '(?i)(range|minimum)'
        }

        Assert-Equal -Actual $bindingError -Expected $true -Message ('{0} rejects TimeoutSeconds={1} during binding' -f $transferFunctionName, $invalidTimeoutSeconds)
    }
}
Assert-Equal -Actual $script:invalidTransferCurlCalls -Expected 0 -Message 'invalid transfer timeout never invokes curl'

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

# The shutdown arguments now belong to the guest-side request script, which is the process that
# holds the guest run guard while it orders the restart.
. (Join-Path $repoRoot 'guest\Request-GuestReboot.ps1')
$rebootArguments = @(Get-GuestRebootShutdownArguments)
Assert-Equal -Actual ($rebootArguments -join ' ') -Expected '/r /t 0 /c PatchingGuestOps reboot after updates' -Message 'guest reboot arguments request an immediate restart with the stable comment'

$quotedRebootArguments = @(Get-GuestRebootShutdownArguments -Comment 'Reboot after "updates"')
Assert-Equal -Actual $quotedRebootArguments[4] -Expected "Reboot after 'updates'" -Message 'guest reboot comment replaces embedded double quotes'
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

# --- agent completion contract ---------------------------------------------------

$unfinished = [pscustomobject]@{ runId = 'cycle-a'; outcome = 'Started'; finishedAt = $null }
Assert-Equal -Actual (Test-AgentCycleCompletion -Status $unfinished -RunId 'cycle-a' -Mode Apply) -Expected $false -Message 'Started is not completion'
$failed = [pscustomobject]@{ runId = 'cycle-a'; outcome = 'InstallFailed'; finishedAt = '2026-09-11T10:00:00Z' }
Assert-Equal -Actual (Test-AgentCycleCompletion -Status $failed -RunId 'cycle-a' -Mode Apply) -Expected $true -Message 'Failure can be terminal'
Assert-Equal -Actual (Test-AgentCycleCompletion -Status $failed -RunId 'cycle-b' -Mode Apply) -Expected $false -Message 'Another run is not evidence'

$completionCases = @(
    [pscustomobject]@{ Name = 'missing runId'; Status = [pscustomobject]@{ outcome = 'InstallSucceeded'; finishedAt = '2026-09-11T10:00:00Z' }; RunId = 'cycle-a'; Mode = 'Apply'; Expected = $false },
    [pscustomobject]@{ Name = 'invalid finishedAt'; Status = [pscustomobject]@{ runId = 'cycle-a'; outcome = 'InstallSucceeded'; finishedAt = 'not-a-date' }; RunId = 'cycle-a'; Mode = 'Apply'; Expected = $false },
    [pscustomobject]@{ Name = 'empty finishedAt'; Status = [pscustomobject]@{ runId = 'cycle-a'; outcome = 'InstallSucceeded'; finishedAt = '' }; RunId = 'cycle-a'; Mode = 'Apply'; Expected = $false },
    [pscustomobject]@{ Name = 'SearchOnly on apply'; Status = [pscustomobject]@{ runId = 'cycle-a'; outcome = 'SearchOnly'; finishedAt = '2026-09-11T10:00:00Z' }; RunId = 'cycle-a'; Mode = 'Apply'; Expected = $false },
    [pscustomobject]@{ Name = 'InstallFailed on apply'; Status = $failed; RunId = 'cycle-a'; Mode = 'Apply'; Expected = $true },
    [pscustomobject]@{ Name = 'Failed on apply'; Status = [pscustomobject]@{ runId = 'cycle-a'; outcome = 'Failed'; finishedAt = '2026-09-11T10:00:00Z' }; RunId = 'cycle-a'; Mode = 'Apply'; Expected = $true },
    [pscustomobject]@{ Name = 'SearchOnly on discovery'; Status = [pscustomobject]@{ runId = 'cycle-a'; outcome = 'SearchOnly'; finishedAt = '2026-09-11T10:00:00Z' }; RunId = 'cycle-a'; Mode = 'SearchOnly'; Expected = $true },
    [pscustomobject]@{ Name = 'NoApplicableUpdates on discovery'; Status = [pscustomobject]@{ runId = 'cycle-a'; outcome = 'NoApplicableUpdates'; finishedAt = '2026-09-11T10:00:00Z' }; RunId = 'cycle-a'; Mode = 'SearchOnly'; Expected = $true },
    [pscustomobject]@{ Name = 'Failed on discovery'; Status = [pscustomobject]@{ runId = 'cycle-a'; outcome = 'Failed'; finishedAt = '2026-09-11T10:00:00Z' }; RunId = 'cycle-a'; Mode = 'SearchOnly'; Expected = $true },
    [pscustomobject]@{ Name = 'InstallSucceeded on discovery'; Status = [pscustomobject]@{ runId = 'cycle-a'; outcome = 'InstallSucceeded'; finishedAt = '2026-09-11T10:00:00Z' }; RunId = 'cycle-a'; Mode = 'SearchOnly'; Expected = $false }
)
foreach ($completionCase in $completionCases) {
    Assert-Equal -Actual (Test-AgentCycleCompletion -Status $completionCase.Status -RunId $completionCase.RunId -Mode $completionCase.Mode) -Expected $completionCase.Expected -Message ('completion matrix: ' + $completionCase.Name)
}

$invalidModeRejected = $false
try {
    New-VMAgentCycleHandle -VMName 'VM-invalid-mode' -RunId 'cycle-invalid' -Managers $null -VMView $null -GuestAuth $null -HostName '' -CurlPath '' -ProcessId 1 -GuestStatusPath 'status.json' -GuestLogPath 'agent.log' -LocalStatusPath 'status.json' -LocalLogPath 'agent.log' -Mode 'InvalidMode' | Out-Null
}
catch {
    $invalidModeRejected = $true
}
Assert-Equal -Actual $invalidModeRejected -Expected $true -Message 'cycle handle rejects modes outside SearchOnly and Apply'

$lowercaseModeRejected = $false
try {
    New-VMAgentCycleHandle -VMName 'VM-lowercase-mode' -RunId 'cycle-lowercase' -Managers $null -VMView $null -GuestAuth $null -HostName '' -CurlPath '' -ProcessId 1 -GuestStatusPath 'status.json' -GuestLogPath 'agent.log' -LocalStatusPath 'status.json' -LocalLogPath 'agent.log' -Mode 'apply' | Out-Null
}
catch {
    $lowercaseModeRejected = $true
}
Assert-Equal -Actual $lowercaseModeRejected -Expected $true -Message 'cycle handle preserves canonical mode casing'

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

# vSphere keeps finished process info only briefly, so a guest that really did finish can
# come back with no process result at all. status.json is the primary apply result, and
# discovery already treats it that way; apply must not call that a total failure.
$lateStatus = [pscustomobject]@{
    runId = 'cycle-late'
    outcome = 'InstallSucceeded'
    finishedAt = '2026-08-22T10:00:00.0000000Z'
    installResult = [pscustomobject]@{ result = 'Succeeded'; rebootRequired = $true }
    pendingRebootAfter = [pscustomobject]@{ isPending = $true }
    errors = @()
}

$lateCycle = [pscustomobject]@{
    RunId = 'cycle-late'
    Mode = 'Apply'
    AgentCompletionConfirmed = $true
    AgentCompletionReason = 'synthetic terminal status'
    AgentResult = $null
    Status = $lateStatus
}
$lateResult = New-ApplyResultFromCycle -VMName 'VM01' -Cycle $lateCycle 3>$null
Assert-Equal -Actual $lateResult.outcome -Expected 'InstallSucceeded' -Message 'a terminal status.json outweighs a missing GuestOps process result'
Assert-Equal -Actual $lateResult.rebootRequired -Expected $true -Message 'reboot requirement survives a lost process result'
Assert-Equal -Actual $lateResult.agentCompletionConfirmed -Expected $true -Message 'apply result carries terminal completion confirmation'
Assert-Equal -Actual $lateResult.agentCompletionReason -Expected 'synthetic terminal status' -Message 'apply result carries terminal completion reason'

$notCompletedResult = New-ApplyResultFromCycle -VMName 'VM01' -Cycle ([pscustomobject]@{ RunId = 'cycle-late'; Mode = 'Apply'; AgentCompletionConfirmed = $true; AgentCompletionReason = 'synthetic terminal status'; AgentResult = [pscustomobject]@{ Completed = $false; ExitCode = $null; EndTime = $null }; Status = $lateStatus }) 3>$null
Assert-Equal -Actual $notCompletedResult.outcome -Expected 'InstallSucceeded' -Message 'an explicit not-completed result is treated the same as a missing one'

$trulyIncompleteCycle = [pscustomobject]@{
    AgentResult = [pscustomobject]@{ Completed = $false; ExitCode = $null; EndTime = $null }
    Status = [pscustomobject]@{ outcome = 'Started'; finishedAt = ''; installResult = $null; pendingRebootAfter = $null; errors = @() }
}
$incompleteResult = New-ApplyResultFromCycle -VMName 'VM02' -Cycle $trulyIncompleteCycle
Assert-Equal -Actual $incompleteResult.outcome -Expected 'Failed' -Message 'a non-terminal status.json is still an apply failure'

# 'SearchOnly' is a discovery outcome. Seeing it on the apply path means the guest ran the
# wrong thing, so it must not be accepted as a terminal apply result that overrides a lost
# process result - that would report a search as a successful install.
$searchOnlyOnApplyCycle = [pscustomobject]@{
    AgentResult = $null
    Status = [pscustomobject]@{ outcome = 'SearchOnly'; finishedAt = '2026-08-22T10:00:00.0000000Z'; installResult = $null; pendingRebootAfter = $null; errors = @() }
}
Assert-Equal -Actual (New-ApplyResultFromCycle -VMName 'VM06' -Cycle $searchOnlyOnApplyCycle).outcome -Expected 'Failed' -Message 'a discovery outcome on the apply path is not a terminal apply result'
Assert-Contains -Text ([string]$incompleteResult.reason) -Needle 'did not complete' -Message 'a genuinely incomplete apply says so'

# A terminal outcome without finishedAt is not enough: the agent saves status.json eagerly,
# so an outcome can be present while the stage that would have stamped finishedAt never ran.
$noFinishedAtCycle = [pscustomobject]@{
    AgentResult = [pscustomobject]@{ Completed = $false; ExitCode = $null; EndTime = $null }
    Status = [pscustomobject]@{ outcome = 'InstallSucceeded'; finishedAt = ''; installResult = $null; pendingRebootAfter = $null; errors = @() }
}
Assert-Equal -Actual (New-ApplyResultFromCycle -VMName 'VM03' -Cycle $noFinishedAtCycle).outcome -Expected 'Failed' -Message 'a terminal outcome without finishedAt is still an apply failure'

# A real non-zero exit code still fails, and a partial install still survives it.
$exitCodeCycle = [pscustomobject]@{
    RunId = 'cycle-exit'
    Mode = 'Apply'
    AgentCompletionConfirmed = $true
    AgentCompletionReason = 'synthetic terminal status'
    AgentResult = [pscustomobject]@{ Completed = $true; ExitCode = 1; EndTime = (Get-Date) }
    Status = [pscustomobject]@{ runId = 'cycle-exit'; outcome = 'InstallFailed'; finishedAt = '2026-08-22T10:00:00.0000000Z'; installResult = $null; pendingRebootAfter = $null; errors = @() }
}
Assert-Contains -Text ([string](New-ApplyResultFromCycle -VMName 'VM04' -Cycle $exitCodeCycle).reason) -Needle 'exited with code' -Message 'a non-zero exit code with a failed outcome is still a failure'

$partialCycle = [pscustomobject]@{
    RunId = 'cycle-partial'
    Mode = 'Apply'
    AgentCompletionConfirmed = $true
    AgentCompletionReason = 'synthetic terminal status'
    AgentResult = [pscustomobject]@{ Completed = $true; ExitCode = 3; EndTime = (Get-Date) }
    Status = [pscustomobject]@{ runId = 'cycle-partial'; outcome = 'InstallSucceededWithErrors'; finishedAt = '2026-08-22T10:00:00.0000000Z'; installResult = $null; pendingRebootAfter = $null; errors = @() }
}
Assert-Equal -Actual (New-ApplyResultFromCycle -VMName 'VM05' -Cycle $partialCycle).outcome -Expected 'InstallSucceededWithErrors' -Message 'a partial install keeps its outcome despite the non-zero exit'

$exitCodeOnlyCycle = [pscustomobject]@{
    AgentResult = [pscustomobject]@{ Completed = $true; ExitCode = 0; EndTime = (Get-Date) }
    Status = [pscustomobject]@{ runId = 'cycle-exit-only'; outcome = 'InstallSucceeded'; finishedAt = '2026-08-22T10:00:00.0000000Z'; installResult = $null; pendingRebootAfter = $null; errors = @() }
}
$exitCodeOnlyResult = New-ApplyResultFromCycle -VMName 'VM07' -Cycle $exitCodeOnlyCycle
Assert-Equal -Actual $exitCodeOnlyResult.agentCompletionConfirmed -Expected $false -Message 'ExitCode 0 alone does not confirm agent completion'
Assert-Equal -Actual $exitCodeOnlyResult.outcome -Expected 'Failed' -Message 'ExitCode 0 without completion evidence is an apply failure'

$throttleGuardThrew = $false
try { Invoke-ThrottledJobs -Items @() -ThrottleLimit 0 -JobTimeoutSeconds 30 -ScriptBlock { param($i) $i } | Out-Null }
catch { $throttleGuardThrew = $true }
Assert-Equal -Actual $throttleGuardThrew -Expected $true -Message 'Invoke-ThrottledJobs throws on ThrottleLimit below 1'

$timeoutGuardThrew = $false
try { Invoke-ThrottledJobs -Items @() -ThrottleLimit 1 -JobTimeoutSeconds 0 -ScriptBlock { param($i) $i } | Out-Null }
catch { $timeoutGuardThrew = $true }
Assert-Equal -Actual $timeoutGuardThrew -Expected $true -Message 'Invoke-ThrottledJobs throws on JobTimeoutSeconds below 1'

# Reboot initiation is the last Start-Job path, and the reboot coordinator reads this
# classification. A job that was stopped at its deadline, or whose output could not be read, may
# already have sent shutdown.exe; only a job that never started provably sent nothing.
$stoppedJobResult = @(Invoke-ThrottledJobs -Items @([pscustomobject]@{ Sequence = 1; VMName = 'VM-stopped-job' }) -ThrottleLimit 1 -JobTimeoutSeconds 1 -ScriptBlock {
    param($JobInput)
    Start-Sleep -Seconds 30
})[0]
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $stoppedJobResult -Path @('ErrorKind')) -Expected 'JobResultLost' -Message 'a job stopped at its deadline reports a lost result'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $stoppedJobResult -Path @('RejectedBeforeStart') -DefaultValue $true) -Expected $false -Message 'a job stopped at its deadline is never reported as rejected before start'

$crashedJobResult = @(Invoke-ThrottledJobs -Items @([pscustomobject]@{ Sequence = 1; VMName = 'VM-crashed-job' }) -ThrottleLimit 1 -JobTimeoutSeconds 60 -ScriptBlock {
    param($JobInput)
    throw 'synthetic job crash after the guest call'
})[0]
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $crashedJobResult -Path @('ErrorKind')) -Expected 'JobResultLost' -Message 'a job whose output cannot be received reports a lost result'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $crashedJobResult -Path @('RejectedBeforeStart') -DefaultValue $true) -Expected $false -Message 'a job whose output cannot be received is never reported as rejected before start'

$unstartedJobResult = @(Invoke-ThrottledJobs -Items @([pscustomobject]@{ Sequence = 1; VMName = 'VM-unstarted-job' }) -ThrottleLimit 1 -JobTimeoutSeconds 60 -ScriptBlock $null)[0]
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject $unstartedJobResult -Path @('RejectedBeforeStart') -DefaultValue $false) -Expected $true -Message 'a job that never started is reported as rejected before start'

# --- in-process agent fleet ---

$fleetEvents = New-Object System.Collections.Generic.List[string]
$fleetItems = @(
    [pscustomobject]@{ Sequence = 1; VMName = 'VM01'; PollsNeeded = 2 },
    [pscustomobject]@{ Sequence = 2; VMName = 'VM02'; PollsNeeded = 1 },
    [pscustomobject]@{ Sequence = 3; VMName = 'VM03'; PollsNeeded = 3 }
)

$fleetResults = @(Invoke-InProcessAgentFleet -Items $fleetItems -MaxInFlight 3 -PollSeconds 1 -ItemTimeoutSeconds 60 `
    -StartScript {
        param($Item)
        $fleetEvents.Add('start:' + $Item.VMName)
        return [pscustomobject]@{ VMName = $Item.VMName; Remaining = [int]$Item.PollsNeeded }
    } `
    -PollScript {
        param($Handle)
        $fleetEvents.Add('poll:' + $Handle.VMName)
        $Handle.Remaining--
        return ($Handle.Remaining -le 0)
    } `
    -CompleteScript { param($Handle) return [pscustomobject]@{ Completed = $true; VMName = $Handle.VMName } } `
    -SleepScript { param([int]$Seconds) })

Assert-Equal -Actual $fleetResults.Count -Expected 3 -Message 'fleet returns one result per item'
Assert-Equal -Actual (@($fleetResults | Where-Object { $_.Error }).Count) -Expected 0 -Message 'healthy fleet items report no error'
# Starts and polls interleave: exactly one start happens before the first poll, and every VM is
# still started exactly once. Draining the whole queue first would leave the first guest running
# unwatched for as long as the remaining starts take - minutes at fleet scale, by which time it
# can have finished and dropped out of vSphere's process list.
$firstPollIndex = $fleetEvents.IndexOf(($fleetEvents | Where-Object { $_ -like 'poll:*' } | Select-Object -First 1))
Assert-Equal -Actual (@($fleetEvents[0..($firstPollIndex - 1)] | Where-Object { $_ -like 'start:*' }).Count) -Expected 1 -Message 'the first poll follows the first start, not the last'
Assert-Equal -Actual (@($fleetEvents | Where-Object { $_ -like 'start:*' }).Count) -Expected 3 -Message 'every item is still started exactly once'
Assert-Equal -Actual ((@($fleetEvents | Where-Object { $_ -like 'start:*' }) | Sort-Object -Unique).Count) -Expected 3 -Message 'no item is started twice'

# --- fleet scale: 100 VMs with an injected clock ------------------------------------------------
# Each start costs several SOAP round trips plus three file transfers. Draining the queue first
# meant the first guest ran unwatched for the length of every remaining start - with 100 VMs at
# six seconds each, ten minutes - by which time it could have finished and dropped out of
# vSphere's short-lived process list. The clock is injected so this measures the ORDER of
# operations, not how fast the test host happens to be.
& {
    $scaleItems = @(1..100 | ForEach-Object { [pscustomobject]@{ Sequence = $_; VMName = ('VM{0:D3}' -f $_); PollsNeeded = 2 } })
    $scaleEvents = New-Object System.Collections.Generic.List[string]
    $script:scaleClock = [datetime]::Parse('2026-09-13T00:00:00Z').ToUniversalTime()
    $script:scaleStartSeconds = 6
    $script:scaleStarted = @{}

    $scaleResults = @(Invoke-InProcessAgentFleet -Items $scaleItems -MaxInFlight 100 -PollSeconds 15 -ItemTimeoutSeconds 1800 `
        -StartScript {
            param($Item)
            # A start takes real time on the wire, and it finishes before the next thing happens.
            $script:scaleClock = $script:scaleClock.AddSeconds($script:scaleStartSeconds)
            $vmName = [string]$Item.VMName
            if ($script:scaleStarted.ContainsKey($vmName)) { throw ('VM {0} was started twice' -f $vmName) }
            $script:scaleStarted[$vmName] = $true
            $scaleEvents.Add('start:' + $vmName)
            return [pscustomobject]@{ VMName = $vmName; Remaining = [int]$Item.PollsNeeded }
        } `
        -PollScript {
            param($Handle)
            $script:scaleClock = $script:scaleClock.AddSeconds(1)
            $scaleEvents.Add('poll:' + $Handle.VMName)
            $Handle.Remaining--
            return ($Handle.Remaining -le 0)
        } `
        -CompleteScript { param($Handle) return [pscustomobject]@{ Completed = $true; VMName = $Handle.VMName } } `
        -SleepScript { param([int]$Seconds) $script:scaleClock = $script:scaleClock.AddSeconds($Seconds) } `
        -NowScript { return $script:scaleClock })

    Assert-Equal -Actual $scaleResults.Count -Expected 100 -Message 'every VM in a 100-VM fleet produces a result'
    Assert-Equal -Actual (@($scaleResults | Where-Object { $_.Error }).Count) -Expected 0 -Message 'a 100-VM fleet with healthy guests reports no error'
    Assert-Equal -Actual (@($scaleEvents | Where-Object { $_ -like 'start:*' }).Count) -Expected 100 -Message 'each of the 100 VMs is started exactly once'

    $scaleStarts = @($scaleEvents | Where-Object { $_ -like 'start:*' })
    $lastStartIndex = $scaleEvents.LastIndexOf($scaleStarts[$scaleStarts.Count - 1])
    $firstPollIndex = $scaleEvents.IndexOf(($scaleEvents | Where-Object { $_ -like 'poll:*' } | Select-Object -First 1))
    Assert-Equal -Actual ($firstPollIndex -lt $lastStartIndex) -Expected $true -Message 'polling begins before the last VM is started'
    # And not merely "before the last": immediately after the first start completes.
    Assert-Equal -Actual $firstPollIndex -Expected 1 -Message 'the first poll happens as soon as the first start has finished'

    # No free slot is ever spent asleep while targets are still waiting: the queue is what decides
    # how long the whole phase takes.
    $scaleSleeps = 0
    $scaleSleepEvents = New-Object System.Collections.Generic.List[string]
    $script:scaleClock = [datetime]::Parse('2026-09-13T00:00:00Z').ToUniversalTime()
    $script:scaleStarted = @{}
    $null = @(Invoke-InProcessAgentFleet -Items $scaleItems -MaxInFlight 100 -PollSeconds 15 -ItemTimeoutSeconds 1800 `
        -StartScript {
            param($Item)
            $script:scaleClock = $script:scaleClock.AddSeconds(6)
            $scaleSleepEvents.Add('start')
            return [pscustomobject]@{ VMName = [string]$Item.VMName; Remaining = 1 }
        } `
        -PollScript { param($Handle) $script:scaleClock = $script:scaleClock.AddSeconds(1); $Handle.Remaining--; return ($Handle.Remaining -le 0) } `
        -CompleteScript { param($Handle) return [pscustomobject]@{ Completed = $true } } `
        -SleepScript { param([int]$Seconds) $script:scaleSleeps++; $scaleSleepEvents.Add('sleep'); $script:scaleClock = $script:scaleClock.AddSeconds($Seconds) } `
        -NowScript { return $script:scaleClock })
    $firstSleepIndex = $scaleSleepEvents.IndexOf('sleep')
    if ($firstSleepIndex -ge 0) {
        Assert-Equal -Actual (@($scaleSleepEvents[0..$firstSleepIndex] | Where-Object { $_ -eq 'start' }).Count) -Expected 100 -Message 'no poll interval is spent idle while targets are still waiting to start'
    }

    # The clock is read per item, not once per wave. With several guests in flight and a poll that
    # costs real time, a single reading taken at the top of the wave is already minutes old by the
    # time the last entry is examined - so a VM whose budget the earlier polls consumed is judged
    # as if no time had passed, and its timeout is deferred by a whole wave.
    $freshEvents = New-Object System.Collections.Generic.List[string]
    $script:freshClock = [datetime]::Parse('2026-09-13T00:00:00Z').ToUniversalTime()
    $script:freshPollSeconds = 0
    $freshItems = @(1..3 | ForEach-Object { [pscustomobject]@{ Sequence = $_; VMName = ('FRESH{0}' -f $_) } })
    $null = @(Invoke-InProcessAgentFleet -Items $freshItems -MaxInFlight 3 -PollSeconds 5 -ItemTimeoutSeconds 90 `
        -StartScript {
            param($Item)
            $freshEvents.Add('start:' + $Item.VMName)
            # Once every guest is running, each poll starts costing 60 seconds on the wire.
            if (@($freshEvents | Where-Object { $_ -like 'start:*' }).Count -ge 3) { $script:freshPollSeconds = 60 }
            return [pscustomobject]@{ VMName = [string]$Item.VMName; Polls = 0 }
        } `
        -PollScript {
            param($Handle)
            $script:freshClock = $script:freshClock.AddSeconds($script:freshPollSeconds)
            $freshEvents.Add('poll:' + $Handle.VMName)
            $Handle.Polls++
            # Never finishes on its own: the deadline is the only thing that ends this fleet.
            return $false
        } `
        -CompleteScript { param($Handle) $freshEvents.Add('collect:' + $Handle.VMName); return [pscustomobject]@{ Completed = $false; VMName = $Handle.VMName } } `
        -SleepScript { param([int]$Seconds) $freshEvents.Add('sleep'); $script:freshClock = $script:freshClock.AddSeconds($Seconds) } `
        -NowScript { return $script:freshClock })

    # The first wave where polls cost 60s begins right after the third start. Two polls into it,
    # 120 seconds have gone by and the third guest is past its 90-second budget - so that wave has
    # to end it. A stale clock reading would have let all three poll again and deferred every
    # timeout to the following wave.
    $thirdStartIndex = $freshEvents.IndexOf('start:FRESH3')
    $firstSleepAfterStarts = $freshEvents.IndexOf('sleep')
    Assert-Equal -Actual ($thirdStartIndex -ge 0 -and $firstSleepAfterStarts -gt $thirdStartIndex) -Expected $true -Message 'the slow wave is identifiable in the event trace'
    if ($thirdStartIndex -ge 0 -and $firstSleepAfterStarts -gt $thirdStartIndex) {
        $firstSlowWave = @($freshEvents[($thirdStartIndex + 1)..($firstSleepAfterStarts - 1)])
        Assert-Equal -Actual (@($firstSlowWave | Where-Object { $_ -like 'poll:*' }).Count) -Expected 2 -Message 'a per-item clock stops polling the wave once a budget has been consumed by the earlier polls'
        Assert-Equal -Actual (@($firstSlowWave | Where-Object { $_ -eq 'collect:FRESH3' }).Count) -Expected 1 -Message 'the VM whose budget the earlier polls consumed is timed out in that same wave'
    }
}

# One guest throwing must become that VM's error, not the end of the phase.
$throwingResults = @(Invoke-InProcessAgentFleet -Items $fleetItems -MaxInFlight 3 -PollSeconds 1 -ItemTimeoutSeconds 60 `
    -StartScript {
        param($Item)
        if ($Item.VMName -eq 'VM02') { throw 'guest ops refused the start' }
        return [pscustomobject]@{ VMName = $Item.VMName; Remaining = 1 }
    } `
    -PollScript { param($Handle) return $true } `
    -CompleteScript { param($Handle) return [pscustomobject]@{ Completed = $true } } `
    -SleepScript { param([int]$Seconds) })

Assert-Equal -Actual $throwingResults.Count -Expected 3 -Message 'a failed start still yields a result row'
Assert-Contains -Text ([string]@($throwingResults | Where-Object { $_.VMName -eq 'VM02' })[0].Error) -Needle 'guest ops refused the start' -Message 'failed start records the guest error'
Assert-Equal -Actual (@($throwingResults | Where-Object { $_.VMName -ne 'VM02' -and $_.Error }).Count) -Expected 0 -Message 'one failed start does not poison the other items'

# Serialised execution when the operator lowers the limit.
$serialEvents = New-Object System.Collections.Generic.List[string]
$serialResults = @(Invoke-InProcessAgentFleet -Items $fleetItems -MaxInFlight 1 -PollSeconds 1 -ItemTimeoutSeconds 60 `
    -StartScript { param($Item) $serialEvents.Add('start:' + $Item.VMName); return [pscustomobject]@{ VMName = $Item.VMName } } `
    -PollScript { param($Handle) return $true } `
    -CompleteScript { param($Handle) return [pscustomobject]@{ Completed = $true } } `
    -SleepScript { param([int]$Seconds) })

Assert-Equal -Actual $serialResults.Count -Expected 3 -Message 'serialised fleet returns every result'
Assert-Equal -Actual $serialEvents[0] -Expected 'start:VM01' -Message 'MaxInFlight 1 starts items one at a time'

# A timeout must still harvest the guest artifacts: status.json is the primary result and a
# run that finished inside the guest must not be reported as a total failure.
$timeoutCompleted = $false
$timeoutResults = @(Invoke-InProcessAgentFleet -Items @($fleetItems[0]) -MaxInFlight 1 -PollSeconds 1 -ItemTimeoutSeconds 0 `
    -StartScript { param($Item) return [pscustomobject]@{ VMName = $Item.VMName } } `
    -PollScript { param($Handle) return $false } `
    -CompleteScript { param($Handle) $script:timeoutCompleted = $true; return [pscustomobject]@{ Completed = $false; Harvested = $true } } `
    -SleepScript { param([int]$Seconds) })

Assert-Equal -Actual $timeoutResults.Count -Expected 1 -Message 'timed out item still yields a result'
Assert-Contains -Text ([string]$timeoutResults[0].Error) -Needle 'timed out' -Message 'timed out item reports a timeout error'
Assert-Equal -Actual $timeoutCompleted -Expected $true -Message 'a timeout still tries to download the guest artifacts'
Assert-Equal -Actual $timeoutResults[0].Payload.Harvested -Expected $true -Message 'a timed out item carries the harvested payload alongside its error'
Assert-Equal -Actual $timeoutResults[0].ResultKind -Expected 'Timeout' -Message 'a timeout has a structural result kind'

# Harvesting must not be able to hide the timeout. The failed harvest is expected to warn, so the
# warning stream is redirected into the output and asserted here: an expected warning printed during
# a passing run reads like a real problem, and silencing it outright would drop the proof that a
# timed out VM still explains why its artifacts are missing.
$timeoutThrowStream = @(& {
    Invoke-InProcessAgentFleet -Items @($fleetItems[0]) -MaxInFlight 1 -PollSeconds 1 -ItemTimeoutSeconds 0 `
        -StartScript { param($Item) return [pscustomobject]@{ VMName = $Item.VMName } } `
        -PollScript { param($Handle) return $false } `
        -CompleteScript { param($Handle) throw 'status.json was not downloaded' } `
        -SleepScript { param([int]$Seconds) }
} 3>&1)
$harvestWarnings = @($timeoutThrowStream | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
$timeoutThrowResults = @($timeoutThrowStream | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })

Assert-Equal -Actual $harvestWarnings.Count -Expected 1 -Message 'a failed harvest warns exactly once'
Assert-Contains -Text ([string]$harvestWarnings[0]) -Needle 'VM01' -Message 'the harvest warning names the VM it could not collect'
Assert-Contains -Text ([string]$harvestWarnings[0]) -Needle 'status.json was not downloaded' -Message 'the harvest warning carries the underlying error'
Assert-Equal -Actual $timeoutThrowResults.Count -Expected 1 -Message 'a failed harvest still yields exactly one result'
Assert-Contains -Text ([string]$timeoutThrowResults[0].Error) -Needle 'timed out' -Message 'a failed harvest still reports the original timeout'
Assert-Equal -Actual $timeoutThrowResults[0].Payload -Expected $null -Message 'a failed harvest leaves no payload'
Assert-Equal -Actual $timeoutThrowResults[0].ResultKind -Expected 'Timeout' -Message 'a failed timeout keeps the timeout result kind'

# TDD RED: before transient polling recovery, the first exception ended the item
# immediately instead of retaining the same in-flight agent until the next poll.
$script:startCalls = 0
$script:pollCalls = 0
$script:collectCalls = 0
$script:fleetNow = [datetime]'2026-09-11T10:00:00Z'
$fleetResults = @(Invoke-InProcessAgentFleet -Items @([pscustomobject]@{ Sequence = 1; VMName = 'VM-retry' }) -MaxInFlight 1 -PollSeconds 1 -ItemTimeoutSeconds 60 `
    -StartScript {
        param($Item)
        $script:startCalls++
        return [pscustomobject]@{ VMName = $Item.VMName; ProcessId = 17 }
    } `
    -PollScript {
        param($Handle)
        $script:pollCalls++
        if ($script:pollCalls -eq 1) { throw 'transient polling failure' }
        return $true
    } `
    -CompleteScript {
        param($Handle)
        $script:collectCalls++
        return [pscustomobject]@{ Completed = $true }
    } `
    -NowScript { $script:fleetNow } `
    -IsTransientErrorScript { param($ErrorRecord) $true } `
    -SleepScript { param([int]$Seconds) $script:fleetNow = $script:fleetNow.AddSeconds($Seconds) })

Assert-Equal -Actual $script:startCalls -Expected 1 -Message 'Recovery never launches a second agent'
Assert-Equal -Actual $script:pollCalls -Expected 2 -Message 'Transient poll failure is retried'
Assert-Equal -Actual $script:collectCalls -Expected 1 -Message 'Recovered cycle is collected'
Assert-Equal -Actual $fleetResults[0].Error -Expected $null -Message 'Recovered transient error does not poison success'

# Permanent poll errors still harvest once, but the original poll error remains primary
# when artifact collection itself fails.
$script:permanentStartCalls = 0
$script:permanentPollCalls = 0
$script:permanentCollectCalls = 0
$permanentResults = @(Invoke-InProcessAgentFleet -Items @([pscustomobject]@{ Sequence = 1; VMName = 'VM-permanent' }) -MaxInFlight 1 -PollSeconds 1 -ItemTimeoutSeconds 60 `
    -StartScript {
        param($Item)
        $script:permanentStartCalls++
        return [pscustomobject]@{ VMName = $Item.VMName; ProcessId = 23 }
    } `
    -PollScript {
        param($Handle)
        $script:permanentPollCalls++
        throw 'permanent polling failure'
    } `
    -CompleteScript {
        param($Handle)
        $script:permanentCollectCalls++
        throw 'collection failure must not replace poll error'
    } `
    -IsTransientErrorScript { param($ErrorRecord) $false } `
    -SleepScript { param([int]$Seconds) })

Assert-Equal -Actual $script:permanentStartCalls -Expected 1 -Message 'Permanent poll error never restarts the agent'
Assert-Equal -Actual $script:permanentPollCalls -Expected 1 -Message 'Permanent poll error ends polling once'
Assert-Equal -Actual $script:permanentCollectCalls -Expected 1 -Message 'Permanent poll error collects artifacts once'
Assert-Contains -Text ([string]$permanentResults[0].Error) -Needle 'permanent polling failure' -Message 'Original permanent poll error is retained'
Assert-Equal -Actual $permanentResults[0].Payload -Expected $null -Message 'Failed permanent-error collection leaves no payload'
Assert-Equal -Actual $permanentResults[0].ResultKind -Expected 'PermanentPoll' -Message 'a permanent poll error has a structural result kind'

# Repeated transient errors use the original deadline rather than resetting it on each
# retry. The injected sleep advances the test clock without waiting in real time.
$script:deadlineNow = [datetime]'2026-09-11T10:00:00Z'
$script:deadlineStartCalls = 0
$script:deadlinePollCalls = 0
$script:deadlineCollectCalls = 0
$deadlineResults = @(Invoke-InProcessAgentFleet -Items @([pscustomobject]@{ Sequence = 1; VMName = 'VM-deadline' }) -MaxInFlight 1 -PollSeconds 1 -ItemTimeoutSeconds 2 `
    -StartScript {
        param($Item)
        $script:deadlineStartCalls++
        return [pscustomobject]@{ VMName = $Item.VMName; ProcessId = 29 }
    } `
    -PollScript {
        param($Handle)
        $script:deadlinePollCalls++
        throw 'transient until deadline'
    } `
    -CompleteScript {
        param($Handle)
        $script:deadlineCollectCalls++
        return [pscustomobject]@{ Harvested = $true }
    } `
    -NowScript { $script:deadlineNow } `
    -IsTransientErrorScript { param($ErrorRecord) $true } `
    -SleepScript { param([int]$Seconds) $script:deadlineNow = $script:deadlineNow.AddSeconds($Seconds) })

Assert-Equal -Actual $script:deadlineStartCalls -Expected 1 -Message 'Transient timeout never restarts the agent'
Assert-Equal -Actual $script:deadlinePollCalls -Expected 2 -Message 'Transient timeout polls only before the original deadline'
Assert-Equal -Actual $script:deadlineCollectCalls -Expected 1 -Message 'Transient timeout collects artifacts once'
Assert-Contains -Text ([string]$deadlineResults[0].Error) -Needle 'timed out' -Message 'Transient errors eventually report the original timeout'
Assert-Equal -Actual $deadlineResults[0].Payload.Harvested -Expected $true -Message 'Transient timeout retains its harvested payload'
Assert-Equal -Actual $deadlineResults[0].ResultKind -Expected 'Timeout' -Message 'deadline expiry has a structural timeout result kind'

# One VM recovering must not delay or poison a peer that completes in the same fleet.
$script:peerStartCalls = @{}
$script:peerPollCalls = @{}
$script:peerCollectCalls = @{}
$peerResults = @(Invoke-InProcessAgentFleet -Items @(
        [pscustomobject]@{ Sequence = 1; VMName = 'VM-recovering' },
        [pscustomobject]@{ Sequence = 2; VMName = 'VM-peer' }
    ) -MaxInFlight 2 -PollSeconds 1 -ItemTimeoutSeconds 60 `
    -StartScript {
        param($Item)
        if ($script:peerStartCalls.ContainsKey($Item.VMName)) { $script:peerStartCalls[$Item.VMName]++ } else { $script:peerStartCalls[$Item.VMName] = 1 }
        return [pscustomobject]@{ VMName = $Item.VMName; ProcessId = 31 }
    } `
    -PollScript {
        param($Handle)
        $name = [string]$Handle.VMName
        if ($script:peerPollCalls.ContainsKey($name)) { $script:peerPollCalls[$name]++ } else { $script:peerPollCalls[$name] = 1 }
        if ($name -eq 'VM-recovering' -and $script:peerPollCalls[$name] -eq 1) { throw 'peer transient failure' }
        return $true
    } `
    -CompleteScript {
        param($Handle)
        $name = [string]$Handle.VMName
        if ($script:peerCollectCalls.ContainsKey($name)) { $script:peerCollectCalls[$name]++ } else { $script:peerCollectCalls[$name] = 1 }
        return [pscustomobject]@{ VMName = $name }
    } `
    -IsTransientErrorScript { param($ErrorRecord) $true } `
    -SleepScript { param([int]$Seconds) })

Assert-Equal -Actual $peerResults.Count -Expected 2 -Message 'A recovered VM leaves its peer result intact'
Assert-Equal -Actual $script:peerStartCalls['VM-recovering'] -Expected 1 -Message 'Recovering VM starts exactly once'
Assert-Equal -Actual $script:peerStartCalls['VM-peer'] -Expected 1 -Message 'Peer VM starts exactly once'
Assert-Equal -Actual $script:peerPollCalls['VM-recovering'] -Expected 2 -Message 'Recovering VM retries independently'
Assert-Equal -Actual $script:peerPollCalls['VM-peer'] -Expected 1 -Message 'Peer VM is not repolled after completion'
Assert-Equal -Actual $script:peerCollectCalls['VM-recovering'] -Expected 1 -Message 'Recovering VM is collected once'
Assert-Equal -Actual $script:peerCollectCalls['VM-peer'] -Expected 1 -Message 'Peer VM is collected once'
Assert-Equal -Actual (@($peerResults | Where-Object { $null -ne $_.Error }).Count) -Expected 0 -Message 'Peer and recovered VM results are successful'

$fleetInFlightGuardThrew = $false
try { Invoke-InProcessAgentFleet -Items @() -MaxInFlight 0 -PollSeconds 1 -ItemTimeoutSeconds 60 -StartScript { param($i) $i } -PollScript { param($h) $true } -CompleteScript { param($h) $h } | Out-Null }
catch { $fleetInFlightGuardThrew = $true }
Assert-Equal -Actual $fleetInFlightGuardThrew -Expected $true -Message 'Invoke-InProcessAgentFleet throws on MaxInFlight below 1'

$mixedApplyResults = @(
    [pscustomobject]@{ vmName = 'VM01'; action = 'Install'; outcome = 'InstallSucceeded'; rebootRequired = $true; agentCompletionConfirmed = $true; agentCompletionReason = 'synthetic terminal status' },
    [pscustomobject]@{ vmName = 'VM02'; action = 'Install'; outcome = 'InstallSucceeded'; rebootRequired = $false; agentCompletionConfirmed = $true; agentCompletionReason = 'synthetic terminal status' },
    [pscustomobject]@{ vmName = 'VM03'; action = 'Skip'; outcome = 'Skipped'; rebootRequired = $false; agentCompletionConfirmed = $false; agentCompletionReason = '' }
)

$rebootTargets = @(Select-RebootRequiredApplyResults -ApplyResults $mixedApplyResults)
Assert-Equal -Actual $rebootTargets.Count -Expected 1 -Message 'only rebootRequired apply results become reboot targets'
Assert-Equal -Actual $rebootTargets[0].vmName -Expected 'VM01' -Message 'reboot target preserves VM name'

$confirmedFailedReboot = [pscustomobject]@{ vmName = 'VM05'; action = 'Install'; outcome = 'InstallFailed'; rebootRequired = $true; agentCompletionConfirmed = $true; agentCompletionReason = 'terminal failure' }
$confirmedFailedTargets = @(Select-RebootRequiredApplyResults -ApplyResults @($confirmedFailedReboot))
Assert-Equal -Actual $confirmedFailedTargets.Count -Expected 1 -Message 'a confirmed failed install may still be rebooted when it requests one'

$confirmedGenericFailureReboot = [pscustomobject]@{ vmName = 'VM05b'; action = 'Install'; outcome = 'Failed'; rebootRequired = $true; agentCompletionConfirmed = $true; agentCompletionReason = 'terminal failure' }
Assert-Equal -Actual (@(Select-RebootRequiredApplyResults -ApplyResults @($confirmedGenericFailureReboot)).Count) -Expected 1 -Message 'a confirmed Failed outcome may still be rebooted when it requests one'
Assert-Equal -Actual (Test-ApplyResultsSuccessful -ApplyResults @($confirmedGenericFailureReboot)) -Expected $false -Message 'a confirmed Failed outcome never reports apply success'

$unconfirmedReboot = [pscustomobject]@{ vmName = 'VM06'; action = 'Install'; outcome = 'Failed'; rebootRequired = $true; agentCompletionConfirmed = $false; agentCompletionReason = 'agent completion not confirmed' }
Assert-Equal -Actual (@(Select-RebootRequiredApplyResults -ApplyResults @($unconfirmedReboot)).Count) -Expected 0 -Message 'an unconfirmed apply result cannot become a reboot target'

$missingConfirmationReboot = [pscustomobject]@{ vmName = 'VM07'; action = 'Install'; outcome = 'InstallSucceeded'; rebootRequired = $true }
Assert-Equal -Actual (@(Select-RebootRequiredApplyResults -ApplyResults @($missingConfirmationReboot)).Count) -Expected 0 -Message 'a missing completion field cannot become a reboot target'

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

# A reboot target must name the flag that put it there. Without it a VM offered a reboot after a
# single Defender definition update is indistinguishable from one that genuinely needs restarting.
$signalDiscovery = @(
    [pscustomobject]@{ vmName = 'VM02'; pendingRebootBefore = [pscustomobject]@{ isPending = $true; pendingReasons = @('pendingFileRename') } }
)
# Built through the shared constructor, so the fixture cannot drift from the record shape the
# apply phase actually produces - and so agentCompletionConfirmed is set, which the reboot
# filter requires before it will restart anything.
$signalApplyResults = @(
    (New-ApplyResultRecord -VMName 'VM01' -Outcome 'InstallSucceeded' -RebootRequired $true -AgentCompletionConfirmed $true -RebootSignals @('installResult.rebootRequired', 'pendingRebootAfter.componentBasedServicing')),
    (New-ApplyResultRecord -VMName 'VM02' -Outcome 'InstallSucceeded' -RebootRequired $false -AgentCompletionConfirmed $true)
)
$signalTargets = @(Select-RebootRequiredApplyResults -ApplyResults $signalApplyResults -DiscoveryRecords $signalDiscovery)
Assert-Equal -Actual $signalTargets.Count -Expected 2 -Message 'signal-carrying reboot targets are still selected'
Assert-Contains -Text ([string]$signalTargets[0].rebootReason) -Needle 'Reported after apply: installResult.rebootRequired, pendingRebootAfter.componentBasedServicing' -Message 'apply reboot reason names the flags that fired'
Assert-Contains -Text ([string]$signalTargets[1].rebootReason) -Needle 'Pending before patching: pendingRebootBefore.pendingFileRename' -Message 'pending-before reboot reason names the flag that fired'

# An apply result with no signal list must keep the bare phrasing rather than gaining a stray
# separator, because a resumed -PatchPlanPath run has no discovery records to draw signals from.
$unnamedSignalTargets = @(Select-RebootRequiredApplyResults -ApplyResults @((New-ApplyResultRecord -VMName 'VM09' -Outcome 'InstallSucceeded' -RebootRequired $true -AgentCompletionConfirmed $true)))
Assert-Equal -Actual ([string]$unnamedSignalTargets[0].rebootReason) -Expected 'Reported after apply' -Message 'a reboot target without signals keeps the bare reason'

# New-ApplyResultFromCycle must derive the signals from status.json, not be handed them.
$signalCycle = [pscustomobject]@{
    AgentCompletionConfirmed = $true
    AgentResult = [pscustomobject]@{ Completed = $true; ExitCode = 0 }
    Status = [pscustomobject]@{
        outcome = 'InstallSucceeded'
        finishedAt = '2026-01-01T00:00:00.0000000Z'
        installResult = [pscustomobject]@{ result = 'Succeeded'; rebootRequired = $false }
        pendingRebootAfter = [pscustomobject]@{ isPending = $true; pendingReasons = @('windowsUpdate') }
    }
}
$signalApplyResult = New-ApplyResultFromCycle -VMName 'VM10' -Cycle $signalCycle
Assert-Equal -Actual ([bool]$signalApplyResult.rebootRequired) -Expected $true -Message 'a pending reboot after apply still requires a reboot'
Assert-Equal -Actual (@($signalApplyResult.rebootSignals) -join ',') -Expected 'pendingRebootAfter.windowsUpdate' -Message 'apply result carries the named pending reboot signal'

# The Defender-definition case: nothing pending, nothing reported, so nothing to offer.
$quietCycle = [pscustomobject]@{
    AgentCompletionConfirmed = $true
    AgentResult = [pscustomobject]@{ Completed = $true; ExitCode = 0 }
    Status = [pscustomobject]@{
        outcome = 'InstallSucceeded'
        finishedAt = '2026-01-01T00:00:00.0000000Z'
        installResult = [pscustomobject]@{ result = 'Succeeded'; rebootRequired = $false }
        pendingRebootAfter = [pscustomobject]@{ isPending = $false; pendingReasons = @() }
    }
}
$quietApplyResult = New-ApplyResultFromCycle -VMName 'VM11' -Cycle $quietCycle
Assert-Equal -Actual ([bool]$quietApplyResult.rebootRequired) -Expected $false -Message 'an install that needs no reboot does not require one'
Assert-Equal -Actual (@($quietApplyResult.rebootSignals).Count) -Expected 0 -Message 'an install that needs no reboot carries no signals'
Assert-Equal -Actual (@(Select-RebootRequiredApplyResults -ApplyResults @($quietApplyResult) -DiscoveryRecords @([pscustomobject]@{ vmName = 'VM11'; pendingRebootBefore = [pscustomobject]@{ isPending = $false } })).Count) -Expected 0 -Message 'a VM with no pending reboot is never offered one'

$skippedRebootActions = @(New-SkippedRebootActionRecords -RebootTargets $rebootTargets)
Assert-Equal -Actual $skippedRebootActions.Count -Expected 1 -Message 'skipped reboot action is created for every reboot target'
Assert-Equal -Actual $skippedRebootActions[0].action -Expected 'SkippedByOperator' -Message 'operator skip action is explicit'
Assert-Equal -Actual $skippedRebootActions[0].rebootReason -Expected 'Reported after apply' -Message 'skipped reboot action preserves reboot reason'
# Every record in this list is a restart the VM was found to REQUIRE, so refusing it leaves
# updates half-applied and the run must not exit 0. The state map records that VM as
# PendingReboot rather than Failed - see the Set-PatchRunPendingRebootStates section below.
Assert-Equal -Actual (Test-RebootActionsSuccessful -RebootActions $skippedRebootActions) -Expected $false -Message 'a refused required reboot is not a successful run'

# --- what the next round looks at, and what PendingReboot means (task 6) ----------------------
# Two different reasons to look again, and either alone loses a VM: apply results alone miss the
# machine that had nothing to install but a pending reboot (action = NoSelectedUpdates), which
# restarts and would then keep the verdict from the discovery taken BEFORE the restart.

$installedResult = New-ApplyResultRecord -VMName 'VM-installed' -Outcome 'InstallSucceeded' -AgentCompletionConfirmed $true
$rebootOnlyResult = New-ApplyResultRecord -VMName 'VM-reboot-only' -Action 'NoSelectedUpdates' -Outcome 'NoSelectedUpdates' -AgentCompletionConfirmed $true
$unconfirmedResult = New-ApplyResultRecord -VMName 'VM-unconfirmed' -Outcome 'Failed' -AgentCompletionConfirmed $false
$conflictResult = New-ApplyResultRecord -VMName 'VM-conflict' -Outcome 'Failed' -AgentCompletionConfirmed $true -GuestRunConflict $true

$confirmedRebootAction = New-RebootActionRecord -VMName 'VM-reboot-only' -Action 'Initiated' -ValidationStatus 'Confirmed'
$unverifiedRebootAction = New-RebootActionRecord -VMName 'VM-unverified' -Action 'Initiated' -ValidationStatus 'UnverifiedForced'
$skippedRebootAction = New-RebootActionRecord -VMName 'VM-skipped' -Action 'SkippedByOperator'
$conflictRebootAction = New-RebootActionRecord -VMName 'VM-conflict' -Action 'Initiated' -ValidationStatus 'Confirmed'

$nextTargets = @(Get-NextRoundTargetVMNames -ApplyResults @($installedResult, $rebootOnlyResult, $unconfirmedResult) -RebootActions @($confirmedRebootAction, $unverifiedRebootAction, $skippedRebootAction))
Assert-Equal -Actual ($nextTargets -join ',') -Expected 'VM-installed,VM-reboot-only' -Message 'the next round looks at safely applied VMs and confirmed reboots, once each'
Assert-Equal -Actual (@(Get-NextRoundTargetVMNames -ApplyResults @($rebootOnlyResult) -RebootActions @($confirmedRebootAction)).Count) -Expected 1 -Message 'a VM that only rebooted is still re-discovered'
Assert-Equal -Actual (@(Get-NextRoundTargetVMNames -ApplyResults @($rebootOnlyResult) -RebootActions @($unverifiedRebootAction)).Count) -Expected 0 -Message 'a VM with no reliable boot time is not re-discovered'
Assert-Equal -Actual (@(Get-NextRoundTargetVMNames -ApplyResults @($unconfirmedResult) -RebootActions @()).Count) -Expected 0 -Message 'an unconfirmed agent is not carried into the next round'
Assert-Equal -Actual (@(Get-NextRoundTargetVMNames -ApplyResults @($conflictResult) -RebootActions @($conflictRebootAction)).Count) -Expected 0 -Message 'a guest run conflict is never re-entered, even with a confirmed reboot record'

# PendingReboot, not Failed: the install may well have succeeded, and saying otherwise sends
# whoever reads the summary looking for a problem that is not there.
$rebootTargetsForState = @(
    [pscustomobject]@{ vmName = 'VM-reboot-only'; rebootRequired = $true; rebootReason = 'Reported after apply' },
    [pscustomobject]@{ vmName = 'VM-unverified'; rebootRequired = $true; rebootReason = 'Reported after apply' },
    [pscustomobject]@{ vmName = 'VM-skipped'; rebootRequired = $true; rebootReason = 'Reported after apply' }
)
$rebootStateMap = @{
    'VM-reboot-only' = [pscustomobject]@{ vmName = 'VM-reboot-only'; state = 'Green'; reason = 'No selectable updates remain.' }
    'VM-unverified' = [pscustomobject]@{ vmName = 'VM-unverified'; state = 'Green'; reason = 'No selectable updates remain.' }
    'VM-skipped' = [pscustomobject]@{ vmName = 'VM-skipped'; state = 'Green'; reason = 'No selectable updates remain.' }
}
Set-PatchRunPendingRebootStates -StateMap $rebootStateMap -RebootTargets $rebootTargetsForState -RebootActions @($confirmedRebootAction, $unverifiedRebootAction, $skippedRebootAction)
Assert-Equal -Actual $rebootStateMap['VM-unverified'].state -Expected 'PendingReboot' -Message 'an unverified restart leaves the VM pending a reboot'
Assert-Equal -Actual $rebootStateMap['VM-skipped'].state -Expected 'PendingReboot' -Message 'a refused required restart leaves the VM pending a reboot, not failed'
Assert-Equal -Actual $rebootStateMap['VM-reboot-only'].state -Expected 'Green' -Message 'a confirmed restart is not marked pending; the next discovery decides'
Assert-Equal -Actual (Test-PatchRunAllGreen -StateMap $rebootStateMap) -Expected $false -Message 'a VM pending a reboot cannot produce exit 0'

# --- an omitted script path must not become "no script" -------------------------------------------
# A parameter default applies only when the caller OMITS the parameter. Invoke-GuestAgentFleet
# forwards -WorkspaceScriptPath and -RunGuardScriptPath to Start-VMAgentCycle whether or not it
# was given them, so a caller that omitted them sent an empty string, which OVERRODE the default
# and left the workspace bootstrap with no script to run. Every VM failed to start, carrying no
# payload, and the cause was a parameter nobody passed rather than anything the guest did.
#
# Only the harness calls the fleet that way, and the harness needs PowerCLI types, so this went
# unseen everywhere it could have been caught. Asserted here without PowerCLI, on the value the
# bootstrap is actually handed - stopping any earlier would pass whether or not it resolves.
& {
    $script:seenWorkspaceScript = 'never reached'
    $script:seenRunGuardScript = 'never reached'

    function Get-ExactVM { param($Name, $Servers) return [pscustomobject]@{ Name = $Name; ExtensionData = [pscustomobject]@{ MoRef = 'vm-1' } } }
    function Assert-VMReadyForGuestOps { param($VM) }
    function Get-GuestOpsManagers { param($VMView) return [pscustomobject]@{ ProcessManager = $null; FileManager = $null } }
    function Get-VMHostNameForTransfer { param($VMView) return 'esx.invalid' }
    function New-Item { param($ItemType, [switch]$Force, $Path) }
    function Assert-GuestWorkspaceReady {
        param($ProcessManager, $VMView, $GuestAuth, $VMName, $Path, $WorkspaceScriptPath, $Mode, $SealToken, $TimeoutSeconds, $PollSeconds)
        $script:seenWorkspaceScript = [string]$WorkspaceScriptPath
        throw 'stop after the bootstrap was given its script'
    }

    foreach ($case in @(
            [pscustomobject]@{ Name = 'omitted'; Workspace = ''; Guard = '' },
            [pscustomobject]@{ Name = 'whitespace'; Workspace = '   '; Guard = '   ' }
        )) {
        $script:seenWorkspaceScript = 'never reached'
        try {
            $null = Start-VMAgentCycle -VMName 'vm' -Servers @('vc') -Managers $null -GuestAuth $null -CurlPath 'curl.exe' `
                -AgentPath 'agent.ps1' -IdentityHelperPath 'identity.ps1' -GuestWorkingDirectory 'C:\ProgramData\PatchingGuestOps' `
                -VMOutputDirectory 'unused' -MaxUpdates 1 -WorkspaceScriptPath $case.Workspace -RunGuardScriptPath $case.Guard
        }
        catch { }

        Assert-Equal -Actual ([string]::IsNullOrWhiteSpace($script:seenWorkspaceScript)) -Expected $false -Message ('an ' + $case.Name + ' script path is resolved before the bootstrap, not passed through empty')
        Assert-Equal -Actual ($script:seenWorkspaceScript -like '*GuestWorkspace.ps1') -Expected $true -Message ('an ' + $case.Name + ' script path resolves to the shipped guard')
    }

    # A path the caller did supply is still honoured - the resolution must not overwrite it.
    $script:seenWorkspaceScript = 'never reached'
    try {
        $null = Start-VMAgentCycle -VMName 'vm' -Servers @('vc') -Managers $null -GuestAuth $null -CurlPath 'curl.exe' `
            -AgentPath 'agent.ps1' -IdentityHelperPath 'identity.ps1' -GuestWorkingDirectory 'C:\ProgramData\PatchingGuestOps' `
            -VMOutputDirectory 'unused' -MaxUpdates 1 -WorkspaceScriptPath 'C:\custom\Workspace.ps1' -RunGuardScriptPath 'C:\custom\Guard.ps1'
    }
    catch { }
    Assert-Equal -Actual $script:seenWorkspaceScript -Expected 'C:\custom\Workspace.ps1' -Message 'a supplied script path is used as given'
}

# --- a guest that refused the run is not a guest with work outstanding ---------------------------
# The state map is built from DISCOVERY, and discovery is exactly what still succeeded in the
# window a refusal happens in: another run took the guest, or a reboot was requested, or the
# directory was replaced, between discovery and apply. So the VM read as "still has selectable
# updates", which points whoever reads summary.md at updates to install rather than at a guest
# that has to be reconciled. The exit code was already right; the description was not.

& {
    $refusedMap = @{
        'VM-conflict'  = [pscustomobject]@{ vmName = 'VM-conflict';  state = 'Pending'; reason = 'Selectable updates remain.'; outcome = 'SearchOnly'; pendingSelectableCount = 2; deselectedSelectableCount = 0; needsReviewSelectableCount = 0; errors = @() }
        'VM-seal'      = [pscustomobject]@{ vmName = 'VM-seal';      state = 'Pending'; reason = 'Selectable updates remain.'; outcome = 'SearchOnly'; pendingSelectableCount = 1; deselectedSelectableCount = 0; needsReviewSelectableCount = 0; errors = @() }
        'VM-green'     = [pscustomobject]@{ vmName = 'VM-green';     state = 'Green'; reason = 'Nothing left.'; outcome = 'SearchOnly'; pendingSelectableCount = 0; deselectedSelectableCount = 0; needsReviewSelectableCount = 0; errors = @() }
        'VM-excluded'  = [pscustomobject]@{ vmName = 'VM-excluded';  state = 'Excluded'; reason = 'Failover Cluster member.'; outcome = 'SearchOnly'; pendingSelectableCount = 0; deselectedSelectableCount = 0; needsReviewSelectableCount = 0; errors = @() }
        'VM-unchecked' = [pscustomobject]@{ vmName = 'VM-unchecked'; state = 'Pending'; reason = 'Selectable updates remain.'; outcome = 'SearchOnly'; pendingSelectableCount = 1; deselectedSelectableCount = 0; needsReviewSelectableCount = 0; errors = @() }
    }

    Set-PatchRunRefusedStates -StateMap $refusedMap -ApplyResults @(
        (New-ApplyResultRecord -VMName 'VM-conflict' -Outcome 'Failed' -GuestRunConflict $true -GuestRunConflictKind 'Unconfirmed' -Errors @('Guest run conflict: synthetic')),
        (New-ApplyResultRecord -VMName 'VM-seal' -Outcome 'Failed' -WorkspaceSealVerified $false -Errors @('seal refused')),
        (New-ApplyResultRecord -VMName 'VM-green' -Outcome 'InstallSucceeded' -WorkspaceSealVerified $true),
        (New-ApplyResultRecord -VMName 'VM-excluded' -Action 'Skipped' -Outcome 'Skipped' -GuestRunConflict $true -GuestRunConflictKind 'Held'),
        # No token was supplied, so the seal was never checked. Null must not read as refused.
        (New-ApplyResultRecord -VMName 'VM-unchecked' -Outcome 'InstallSucceeded' -WorkspaceSealVerified $null)
    )

    Assert-Equal -Actual $refusedMap['VM-conflict'].state -Expected 'Failed' -Message 'a guest that refused the run is failed, not pending'
    Assert-Equal -Actual ($refusedMap['VM-conflict'].reason -like '*Unconfirmed*') -Expected $true -Message 'the reason names which kind of refusal it was'
    Assert-Equal -Actual $refusedMap['VM-conflict'].pendingSelectableCount -Expected 0 -Message 'a refused guest is not counted as having work outstanding'
    Assert-Equal -Actual $refusedMap['VM-seal'].state -Expected 'Failed' -Message 'a refused workspace seal is failed, not pending'
    Assert-Equal -Actual ($refusedMap['VM-seal'].reason -like '*seal*') -Expected $true -Message 'the reason says the seal was refused'
    Assert-Equal -Actual $refusedMap['VM-green'].state -Expected 'Green' -Message 'a healthy VM keeps its state'
    Assert-Equal -Actual $refusedMap['VM-unchecked'].state -Expected 'Pending' -Message 'a seal that was never checked is not a refusal'
    # Excluded is a decision about a machine somebody understood, and it already keeps the VM out
    # of apply and reboot; overwriting it would lose that.
    Assert-Equal -Actual $refusedMap['VM-excluded'].state -Expected 'Excluded' -Message 'a refusal does not overwrite an exclusion'

    Assert-Equal -Actual (Test-PatchRunAllGreen -StateMap $refusedMap -ExpectedVMNames @('VM-conflict', 'VM-seal', 'VM-green', 'VM-excluded', 'VM-unchecked')) -Expected $false -Message 'a refused guest keeps the run from exiting 0'
}

# The same predicate decides all three: no restart, no next round, no "has updates outstanding".
# They have to agree, or a refusal recorded in one place is undone by another - which is exactly
# what happened to a refused seal: it was not a next-round exclusion, so round two re-discovered
# the VM and its Pending verdict overwrote the refusal from round one.
& {
    $refusedByConflict = New-ApplyResultRecord -VMName 'VM-conflict' -Outcome 'Failed' -RebootRequired $true -AgentCompletionConfirmed $true -GuestRunConflict $true -GuestRunConflictKind 'Unconfirmed'
    $refusedBySeal = New-ApplyResultRecord -VMName 'VM-seal' -Outcome 'Failed' -RebootRequired $true -AgentCompletionConfirmed $true -WorkspaceSealVerified $false
    $sealUnchecked = New-ApplyResultRecord -VMName 'VM-unchecked' -Outcome 'InstallSucceeded' -RebootRequired $true -AgentCompletionConfirmed $true -WorkspaceSealVerified $null
    $healthy = New-ApplyResultRecord -VMName 'VM-healthy' -Outcome 'InstallSucceeded' -RebootRequired $true -AgentCompletionConfirmed $true -WorkspaceSealVerified $true

    Assert-Equal -Actual (Test-IsApplyResultRefused -ApplyResult $refusedByConflict) -Expected $true -Message 'a run-guard conflict is a refusal'
    Assert-Equal -Actual (Test-IsApplyResultRefused -ApplyResult $refusedBySeal) -Expected $true -Message 'a refused workspace seal is a refusal'
    Assert-Equal -Actual (Test-IsApplyResultRefused -ApplyResult $sealUnchecked) -Expected $false -Message 'a seal that was never checked is not a refusal'
    Assert-Equal -Actual (Test-IsApplyResultRefused -ApplyResult $healthy) -Expected $false -Message 'a healthy apply is not a refusal'

    $allFour = @($refusedByConflict, $refusedBySeal, $sealUnchecked, $healthy)
    $rebootable = @(@(Select-RebootRequiredApplyResults -ApplyResults $allFour -DiscoveryRecords @()) | ForEach-Object { [string]$_.vmName } | Sort-Object)
    Assert-Equal -Actual ($rebootable -join ',') -Expected 'VM-healthy,VM-unchecked' -Message 'neither kind of refused guest is ever restarted'

    $nextRound = @(@(Get-NextRoundTargetVMNames -ApplyResults $allFour -RebootActions @()) | Sort-Object)
    Assert-Equal -Actual ($nextRound -join ',') -Expected 'VM-healthy,VM-unchecked' -Message 'neither kind of refused guest enters the next round'
}

# --- a guest that is merely restarting is retried, not written off -------------------------------
# The guard reports FOUR kinds of conflict and only one of them clears itself. A phase that treats
# them alike either fails a VM that was seconds from being available, or waits for a record nobody
# is going to reconcile while the rest of the fleet stands still.

& {
    $makeResult = {
        param([string]$VMName, $ConflictKind)
        $status = [pscustomobject]@{ guestRunConflict = ($null -ne $ConflictKind); guestRunConflictKind = $ConflictKind }
        return [pscustomobject]@{ Sequence = 1; VMName = $VMName; Payload = [pscustomobject]@{ Status = $status }; Error = $null }
    }

    $rebooting = & $makeResult 'VM-rebooting' 'RebootPending'
    $held = & $makeResult 'VM-held' 'Held'
    $unconfirmed = & $makeResult 'VM-unconfirmed' 'Unconfirmed'
    $unreadable = & $makeResult 'VM-unreadable' 'Unreadable'
    $healthy = & $makeResult 'VM-healthy' $null
    # A start error has no payload at all: reading a verdict off it must not throw under StrictMode
    # and absence must not be mistaken for RebootPending.
    $startError = New-FleetErrorResult -InputObject ([pscustomobject]@{ Sequence = 9; VMName = 'VM-start' }) -ErrorMessage 'preflight failed' -ResultKind 'StartError'

    $all = @($rebooting, $held, $unconfirmed, $unreadable, $healthy, $startError)
    $retryable = @(Select-RetryableGuestRunConflicts -FleetResults $all)
    Assert-Equal -Actual (@($retryable | ForEach-Object { [string]$_.VMName }) -join ',') -Expected 'VM-rebooting' -Message 'only a guest on its way back up is retried within the phase'

    Assert-Equal -Actual (Get-FleetResultGuestRunConflictKind -FleetResult $startError) -Expected '' -Message 'a result with no payload reports no conflict kind'
    Assert-Equal -Actual (Get-FleetResultGuestRunConflictKind -FleetResult $healthy) -Expected '' -Message 'a healthy result reports no conflict kind'
    Assert-Equal -Actual (Get-FleetResultGuestRunConflictKind -FleetResult $held) -Expected 'Held' -Message 'a live concurrent run is read back as Held'
    Assert-Equal -Actual (@(Select-RetryableGuestRunConflicts -FleetResults @()).Count) -Expected 0 -Message 'an empty phase has nothing to retry'

    # The retry replaces only the retried VM's result, keeps every other result untouched, and
    # keeps the first attempt when the retry produced nothing for that VM.
    $secondAttempt = & $makeResult 'VM-rebooting' $null
    $merged = @(Merge-RetriedFleetResults -OriginalResults $all -RetriedResults @($secondAttempt) -RetriedVMNames @('VM-rebooting'))
    Assert-Equal -Actual $merged.Count -Expected $all.Count -Message 'the retry changes no VM count'
    Assert-Equal -Actual (@($merged | ForEach-Object { [string]$_.VMName }) -join ',') -Expected (@($all | ForEach-Object { [string]$_.VMName }) -join ',') -Message 'the retry keeps the phase order'
    Assert-Equal -Actual (Get-FleetResultGuestRunConflictKind -FleetResult @($merged | Where-Object { $_.VMName -eq 'VM-rebooting' })[0]) -Expected '' -Message 'the second attempt replaces the refused first one'
    Assert-Equal -Actual (Get-FleetResultGuestRunConflictKind -FleetResult @($merged | Where-Object { $_.VMName -eq 'VM-held' })[0]) -Expected 'Held' -Message 'a VM that was not retried keeps its own result'

    $mergedWithoutAnswer = @(Merge-RetriedFleetResults -OriginalResults $all -RetriedResults @() -RetriedVMNames @('VM-rebooting'))
    Assert-Equal -Actual $mergedWithoutAnswer.Count -Expected $all.Count -Message 'a retry that produced nothing leaves the VM in the phase'
    Assert-Equal -Actual (Get-FleetResultGuestRunConflictKind -FleetResult @($mergedWithoutAnswer | Where-Object { $_.VMName -eq 'VM-rebooting' })[0]) -Expected 'RebootPending' -Message 'a retry that produced nothing keeps the first refusal'

    # The budget is one retry, and it is spent even when the retry hits the same conflict. The
    # second attempt below is the one that must NOT schedule a third.
    Assert-Equal -Actual $script:GuestRunConflictRetryLimit -Expected 1 -Message 'the in-phase retry budget is one attempt'
    Assert-Equal -Actual ($script:GuestRunConflictRetryWaitSeconds -gt 0) -Expected $true -Message 'the wait before the retry is bounded and non-zero'
}

# --- one shape for every apply branch, and one audit log (task 11) ------------------------------
# Compared after a JSON round trip, because that is where a missing property actually bites: under
# StrictMode, reading a field one branch happened not to set is a terminating error for whoever
# reads apply-results.json back.

& {
    $requiredApplyFields = @(
        'vmName', 'action', 'outcome', 'installResult', 'reason', 'roleFlags', 'rebootRequired',
        'agentCompletionConfirmed', 'agentCompletionReason', 'cleanupStatus', 'cleanupReason',
        'errors', 'guestRunConflict', 'guestRunConflictKind', 'workspaceSealVerified',
        'missingUpdateKeys', 'selectionDrift', 'requiresVerification', 'rebootSignals'
    )

    $applyVariants = @(
        [pscustomobject]@{ Name = 'an empty selection'; Record = (New-ApplyResultRecord -VMName 'VM-empty' -Action 'NoSelectedUpdates' -Outcome 'NoSelectedUpdates' -Reason 'nothing selected') },
        [pscustomobject]@{ Name = 'a start error'; Record = (New-ApplyResultRecord -VMName 'VM-start' -Outcome 'Failed' -Reason 'start failed' -Errors @('start failed')) },
        [pscustomobject]@{ Name = 'no payload at all'; Record = (New-ApplyResultRecord -VMName 'VM-nopayload' -Outcome 'Failed' -AgentCompletionConfirmed $false -AgentCompletionReason 'no completion record') },
        [pscustomobject]@{ Name = 'a timeout'; Record = (New-ApplyResultRecord -VMName 'VM-timeout' -Outcome 'Failed' -Reason 'timed out' -CleanupStatus 'Retained' -CleanupReason 'process result lost') },
        [pscustomobject]@{ Name = 'a guest run conflict'; Record = (New-ApplyResultRecord -VMName 'VM-conflict' -Outcome 'Failed' -GuestRunConflict $true -GuestRunConflictKind 'Unconfirmed') },
        [pscustomobject]@{ Name = 'a guest still restarting'; Record = (New-ApplyResultRecord -VMName 'VM-restarting' -Outcome 'Failed' -GuestRunConflict $true -GuestRunConflictKind 'RebootPending') },
        [pscustomobject]@{ Name = 'selection drift'; Record = (New-ApplyResultRecord -VMName 'VM-drift' -Outcome 'InstallSucceeded' -MissingUpdateKeys @('aaaa|1') -SelectionDrift $true -RequiresVerification $true) },
        [pscustomobject]@{ Name = 'a refused workspace seal'; Record = (New-ApplyResultRecord -VMName 'VM-seal' -Outcome 'Failed' -WorkspaceSealVerified $false -Errors @('seal refused')) },
        [pscustomobject]@{ Name = 'a success'; Record = (New-ApplyResultRecord -VMName 'VM-ok' -Outcome 'InstallSucceeded' -AgentCompletionConfirmed $true -RebootRequired $true -RebootSignals @('pendingRebootAfter.windowsUpdate')) },
        [pscustomobject]@{ Name = 'a skip'; Record = (New-ApplyResultRecord -VMName 'VM-skip' -Action 'Skipped' -Outcome 'Skipped' -Reason 'excluded' -RoleFlags ([pscustomobject]@{ failoverCluster = $true })) }
    )

    foreach ($variant in $applyVariants) {
        foreach ($fieldName in $requiredApplyFields) {
            Assert-Equal -Actual ($null -ne $variant.Record.PSObject.Properties[$fieldName]) -Expected $true -Message ('field ' + $fieldName + ' is present for ' + $variant.Name)
        }
    }

    # 0, 1 and 2+ records all serialise as an array at the root, and every field survives.
    $applyDir = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-applyshape-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $applyDir)
    try {
        foreach ($count in @(0, 1, 2, 10)) {
            $subset = @($applyVariants | Select-Object -First $count | ForEach-Object { $_.Record })
            $shapePath = Join-Path $applyDir ('apply-{0}.json' -f $count)
            ConvertTo-Json -InputObject @($subset) -Depth 12 | Set-Content -LiteralPath $shapePath -Encoding UTF8
            $raw = Get-Content -LiteralPath $shapePath -Raw
            # Assign before wrapping: ConvertFrom-Json emits an array as a single pipeline object
            # on 5.1, so @($raw | ConvertFrom-Json).Count would count the array, not its elements.
            $roundTripped = $raw | ConvertFrom-Json
            Assert-Equal -Actual @($roundTripped).Count -Expected $count -Message ('apply-results.json holds ' + $count + ' record(s) as an array at the root')
            foreach ($record in @($roundTripped)) {
                foreach ($fieldName in $requiredApplyFields) {
                    Assert-Equal -Actual ($null -ne $record.PSObject.Properties[$fieldName]) -Expected $true -Message ('field ' + $fieldName + ' survives the JSON round trip')
                }
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $applyDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# The audit log: an allow-list of fields, a disk failure that does not stop the phase, and a
# marked secret that must not appear in the file whatever route it was offered by.
& {
    $eventDir = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-events-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $eventDir)
    try {
        $eventPath = Join-Path $eventDir 'events.jsonl'
        $eventState = New-RunEventLogState -Path $eventPath
        Assert-Equal -Actual (Initialize-RunEventLog -State $eventState) -Expected $true -Message 'the event log is proven writable before any agent starts'
        Assert-Equal -Actual $eventState.Enabled -Expected $true -Message 'a writable event log is enabled'

        $canary = 'SECRET-CANARY-b3f1'
        $canaryCredential = New-Object System.Management.Automation.PSCredential('CORP\svc', (ConvertTo-SecureString $canary -AsPlainText -Force))
        Write-RunEvent -State $eventState -Event 'RoundStarted' -Phase 'Round' -Round 1 -Detail '2 target(s)'
        Write-RunEvent -State $eventState -Event 'VMApplied' -Phase 'Apply' -Round 1 -VMName 'VM01' -RunId 'abc123' -Outcome 'InstallSucceeded'
        Write-RunEvent -State $eventState -Event 'SelectionDrift' -Phase 'Apply' -Round 1 -VMName 'VM02' -Detail 'aaaa|1'
        Write-RunEvent -State $eventState -Event 'VMRebootAction' -Phase 'Reboot' -Round 1 -VMName 'VM01' -Outcome 'Initiated' -OperatorDecision 'REBOOT' -Detail 'Confirmed'
        Write-RunEvent -State $eventState -Event 'GuestRunConflict' -Phase 'Apply' -Round 1 -VMName 'VM03' -ErrorKind 'GuestRunConflict'
        Write-RunEvent -State $eventState -Event 'RunFinished' -Phase 'Finalization' -Outcome '1'

        $eventLines = @(Get-Content -LiteralPath $eventPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Assert-Equal -Actual $eventLines.Count -Expected 6 -Message 'every event is one line of JSON'
        foreach ($line in $eventLines) {
            $parsed = $line | ConvertFrom-Json
            foreach ($property in @($parsed.PSObject.Properties)) {
                Assert-Equal -Actual ($property.Name -in @('timestampUtc', 'event', 'phase', 'round', 'vmName', 'runId', 'outcome', 'errorKind', 'operatorDecision', 'detail')) -Expected $true -Message ('the event log writes only allowed fields, not ' + $property.Name)
            }
        }
        Assert-Equal -Actual (@($eventLines | Where-Object { $_ -like '*RoundStarted*' }).Count) -Expected 1 -Message 'a round start is recorded'
        Assert-Equal -Actual (@($eventLines | Where-Object { $_ -like '*GuestRunConflict*' }).Count) -Expected 1 -Message 'a guest run conflict is recorded'
        Assert-Equal -Actual (@($eventLines | Where-Object { $_ -like '*REBOOT*' }).Count) -Expected 1 -Message 'the operator reboot decision is recorded'

        # A credential offered as a detail is not serialised: the parameter is typed [string], so
        # what lands in the file is the object's type name, never its password.
        Write-RunEvent -State $eventState -Event 'VMApplied' -Phase 'Apply' -Round 1 -VMName 'VM04' -Detail $canaryCredential
        Write-RunEvent -State $eventState -Event 'VMApplied' -Phase 'Apply' -Round 1 -VMName 'VM05' -Detail ([string]$canaryCredential.Password)
        $fileText = Get-Content -LiteralPath $eventPath -Raw
        Assert-NotContains -Text $fileText -Needle $canary -Message 'a marked secret never reaches the event log'
        Assert-NotContains -Text $fileText -Needle 'guestFile?id=' -Message 'no GuestOps transfer ticket reaches the event log'

        # A field nobody allowed is refused outright rather than written.
        $rejected = $false
        try { Write-RunEvent -State $eventState -Event 'Bogus' -Phase 'Apply' -Detail 'ok' -Round 1 -VMName 'VM06' -ErrorKind 'x' -OperatorDecision 'y' -Outcome 'z' -RunId 'r' } catch { $rejected = $true }
        Assert-Equal -Actual $rejected -Expected $false -Message 'the allowed field set is accepted as it stands'
    }
    finally {
        Remove-Item -LiteralPath $eventDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # A log that cannot be created, and one that breaks mid-run. Neither may stop the phase; both
    # have to be remembered so the run can end 1 after the results are safely collected.
    $unwritableState = New-RunEventLogState -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-missing-' + [guid]::NewGuid().ToString('N')))
    $unwritableState.Enabled = $true
    $unwritableState.Path = [System.IO.Path]::GetTempPath()
    $brokeMidRun = $false
    try { Write-RunEvent -State $unwritableState -Event 'VMApplied' -Phase 'Apply' -VMName 'VM07' 3>$null } catch { $brokeMidRun = $true }
    Assert-Equal -Actual $brokeMidRun -Expected $false -Message 'a write failure mid-run does not throw and does not stop the phase'
    Assert-Equal -Actual ($null -ne $unwritableState.AuditError) -Expected $true -Message 'a write failure is remembered so the run can end 1'
    Assert-Equal -Actual $unwritableState.Enabled -Expected $false -Message 'a broken log stops being written to rather than failing on every event'
}

# The "To verify" section is its own section: an operator reading exit 1 with no failing install
# would otherwise go looking for a fault that is not there.
& {
    $summaryDir = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-verifysummary-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $summaryDir)
    try {
        $verifyMap = @{ 'VM-drift' = @{ 'aaaa-1111|1' = $true; 'bbbb-2222|3' = $true } }
        Write-PatchRunSummary -RunOutputDirectory $summaryDir -RoundSummaries @() -FinalStateMap @{ 'VM-drift' = [pscustomobject]@{ vmName = 'VM-drift'; state = 'Green'; reason = 'No selectable updates remain.' } } -OutstandingVerificationByVm $verifyMap -AuditError 'synthetic audit failure'
        $summaryText = Get-Content -LiteralPath (Join-Path $summaryDir 'summary.md') -Raw
        Assert-Contains -Text $summaryText -Needle '## To verify' -Message 'the summary has its own To verify section'
        Assert-Contains -Text $summaryText -Needle 'aaaa-1111|1' -Message 'the section names the keys that were not installed'
        Assert-Contains -Text $summaryText -Needle 'Nothing failed to install' -Message 'the section says this is not an install failure'
        Assert-Contains -Text $summaryText -Needle 'synthetic audit failure' -Message 'an audit failure is reported in the summary'
        Assert-Contains -Text $summaryText -Needle 'not because a VM failed' -Message 'the audit failure says why the run is reported as failed'

        Write-PatchRunSummary -RunOutputDirectory $summaryDir -RoundSummaries @() -FinalStateMap @{}
        $cleanSummary = Get-Content -LiteralPath (Join-Path $summaryDir 'summary.md') -Raw
        Assert-Contains -Text $cleanSummary -Needle 'nothing outstanding' -Message 'a run with nothing to verify says so'
        Assert-NotContains -Text $cleanSummary -Needle '## Audit log' -Message 'a run with a working audit log has no audit section'
    }
    finally {
        Remove-Item -LiteralPath $summaryDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$baseTime = [datetime]::Parse('2026-01-01T00:00:00Z').ToUniversalTime()
$newTime = [datetime]::Parse('2026-01-02T00:00:00Z').ToUniversalTime()

$failedRebootActions = @(
    (New-RebootActionRecord -VMName 'VM01' -Action 'Initiated' -ProcessId 42 -RebootReason 'Pending before patching' -ValidationStatus 'Confirmed'),
    (New-RebootActionRecord -VMName 'VM02' -Action 'Failed' -ErrorMessage 'VMware Tools are not running' -RebootReason 'Reported after apply')
)
Assert-Equal -Actual (Test-RebootActionsSuccessful -RebootActions $failedRebootActions) -Expected $false -Message 'failed reboot action makes reboot phase unsuccessful'

# The post-reboot verification gate is stricter than the run-success check: it asks whether
# every rebooted guest is provably back up, so an operator skip does not qualify.
$allConfirmed = @(
    [pscustomobject]@{ vmName = 'VM01'; action = 'Initiated'; validationStatus = 'Confirmed' },
    [pscustomobject]@{ vmName = 'VM02'; action = 'Initiated'; validationStatus = 'Confirmed' }
)
Assert-Equal -Actual (Test-RebootActionsAllConfirmed -RebootActions $allConfirmed) -Expected $true -Message 'every confirmed reboot passes the verification gate'

foreach ($blockingStatus in @('Unverified', 'Timeout')) {
    $mixedConfirmation = @(
        [pscustomobject]@{ vmName = 'VM01'; action = 'Initiated'; validationStatus = 'Confirmed' },
        [pscustomobject]@{ vmName = 'VM02'; action = 'Initiated'; validationStatus = $blockingStatus }
    )
    Assert-Equal -Actual (Test-RebootActionsAllConfirmed -RebootActions $mixedConfirmation) -Expected $false -Message ('a {0} reboot blocks post-reboot discovery' -f $blockingStatus)
}

Assert-Equal -Actual (Test-RebootActionsAllConfirmed -RebootActions @([pscustomobject]@{ vmName = 'VM01'; action = 'SkippedByOperator'; validationStatus = 'NotRequested' })) -Expected $false -Message 'a skipped reboot is not proof the VM is up'
Assert-Equal -Actual (Test-RebootActionsAllConfirmed -RebootActions @([pscustomobject]@{ vmName = 'VM01'; action = 'Failed'; validationStatus = 'InitiationError' })) -Expected $false -Message 'a failed initiation is not proof the VM is up'
Assert-Equal -Actual (Test-RebootActionsAllConfirmed -RebootActions @()) -Expected $true -Message 'no reboot targets means nothing blocks the next discovery'

# --- patch round loop decisions ---

$roundGreen = @(
    [pscustomobject]@{ vmName = 'VM01'; state = 'Green' },
    [pscustomobject]@{ vmName = 'VM02'; state = 'GreenByOperatorChoice' },
    [pscustomobject]@{ vmName = 'VM03'; state = 'Excluded' }
)
$decisionGreen = Get-PatchRoundDecision -CompletionStates $roundGreen -Round 2 -MaxRounds 3 -OperatorDecision $null
Assert-Equal -Actual $decisionGreen.Action -Expected 'Stop' -Message 'an all-green fleet ends the loop'
Assert-Equal -Actual $decisionGreen.AllGreen -Expected $true -Message 'an excluded cluster VM does not stop the fleet being all green'
Assert-Equal -Actual $decisionGreen.NeedsOperatorDecision -Expected $false -Message 'an all-green fleet never prompts'

# Round one always proceeds to group selection, even with nothing preselected: the operator
# must still get to see the group list and tick something the default policy skipped.
$nothingSelectable = @([pscustomobject]@{ vmName = 'VM01'; state = 'Green' })
Assert-Equal -Actual (Get-PatchRoundDecision -CompletionStates $nothingSelectable -Round 1 -MaxRounds 3 -OperatorDecision $null).Action -Expected 'Continue' -Message 'round one reaches group selection even when nothing is preselected'

$roundPending = @(
    [pscustomobject]@{ vmName = 'VM01'; state = 'Green' },
    [pscustomobject]@{ vmName = 'VM02'; state = 'Pending' }
)
Assert-Equal -Actual (Get-PatchRoundDecision -CompletionStates $roundPending -Round 1 -MaxRounds 3 -OperatorDecision $null).NeedsOperatorDecision -Expected $false -Message 'round one needs no continue prompt'
Assert-Equal -Actual (Get-PatchRoundDecision -CompletionStates $roundPending -Round 2 -MaxRounds 3 -OperatorDecision $null).Action -Expected 'Ask' -Message 'a later round with pending VMs asks the operator'
Assert-Equal -Actual (Get-PatchRoundDecision -CompletionStates $roundPending -Round 2 -MaxRounds 3 -OperatorDecision 'CONTINUE').Action -Expected 'Continue' -Message 'operator CONTINUE runs another round'

# Explicit -SelectedUpdateKeys cannot survive into a later round: the keys carry a
# RevisionNumber that will not appear in the next round's groups. Stop rather than fall
# through to the interactive picker, which a scheduled run cannot answer.
$explicitDecision = Get-PatchRoundDecision -CompletionStates $roundPending -Round 2 -MaxRounds 3 -OperatorDecision $null -ExplicitSelectionOnly $true
Assert-Equal -Actual $explicitDecision.Action -Expected 'Stop' -Message 'an explicit key selection ends the run after round one'
Assert-Equal -Actual $explicitDecision.NeedsOperatorDecision -Expected $false -Message 'an explicit key selection never reaches a prompt'
Assert-Contains -Text ([string]$explicitDecision.Reason) -Needle 'SelectedUpdateKeys' -Message 'stopping for explicit keys explains itself'
Assert-Equal -Actual (Get-PatchRoundDecision -CompletionStates $roundPending -Round 1 -MaxRounds 3 -OperatorDecision $null -ExplicitSelectionOnly $true).Action -Expected 'Continue' -Message 'explicit keys still drive round one'

# A non-interactive run must end instead of blocking on a question nobody can answer.
$nonInteractiveDecision = Get-PatchRoundDecision -CompletionStates $roundPending -Round 2 -MaxRounds 3 -OperatorDecision $null -NonInteractive $true
Assert-Equal -Actual $nonInteractiveDecision.Action -Expected 'Stop' -Message 'a non-interactive run stops rather than asking whether to continue'
Assert-Equal -Actual $nonInteractiveDecision.NeedsOperatorDecision -Expected $false -Message 'a non-interactive run never reaches a prompt'
Assert-Equal -Actual $nonInteractiveDecision.AllGreen -Expected $false -Message 'stopping with pending VMs is still not all green'
Assert-Contains -Text ([string]$nonInteractiveDecision.Reason) -Needle 'SkipConfirmation' -Message 'stopping non-interactively explains itself'

# Both stop rules must sit BELOW the pending-count check, or a run that finished successfully
# would be reported as a forced stop and exit 1. Without these two assertions the ordering
# could be inverted and every other round-decision assertion would still pass.
Assert-Equal -Actual (Get-PatchRoundDecision -CompletionStates $roundGreen -Round 2 -MaxRounds 3 -OperatorDecision $null -NonInteractive $true).AllGreen -Expected $true -Message 'a non-interactive run that reached green reports green'
Assert-Equal -Actual (Get-PatchRoundDecision -CompletionStates $roundGreen -Round 2 -MaxRounds 3 -OperatorDecision $null -ExplicitSelectionOnly $true).AllGreen -Expected $true -Message 'an explicit-key run that reached green reports green'
Assert-Equal -Actual (Get-PatchRoundDecision -CompletionStates $roundGreen -Round 2 -MaxRounds 3 -OperatorDecision $null -ExplicitSelectionOnly $true -NonInteractive $true).AllGreen -Expected $true -Message 'both stop rules together still report a green run as green'
Assert-Equal -Actual (Get-PatchRoundDecision -CompletionStates $roundPending -Round 2 -MaxRounds 3 -OperatorDecision 'FINISH').Action -Expected 'Stop' -Message 'operator FINISH ends the loop'
Assert-Equal -Actual (Get-PatchRoundDecision -CompletionStates $roundPending -Round 2 -MaxRounds 3 -OperatorDecision 'FINISH').AllGreen -Expected $false -Message 'finishing with pending VMs is not all green'

# MaxRounds counts apply rounds: with 3, rounds 1-3 apply and round 4 only verifies.
Assert-Equal -Actual (Get-PatchRoundDecision -CompletionStates $roundPending -Round 3 -MaxRounds 3 -OperatorDecision 'CONTINUE').Action -Expected 'Continue' -Message 'the last allowed apply round still runs'
$decisionCapped = Get-PatchRoundDecision -CompletionStates $roundPending -Round 4 -MaxRounds 3 -OperatorDecision 'CONTINUE'
Assert-Equal -Actual $decisionCapped.Action -Expected 'Stop' -Message 'the round cap stops the loop even on CONTINUE'
Assert-Contains -Text ([string]$decisionCapped.Reason) -Needle 'MaxPatchRounds' -Message 'the cap explains itself'
Assert-Equal -Actual (@($decisionCapped.PendingVMNames)[0]) -Expected 'VM02' -Message 'a stopped round still reports what was left pending'

# A VM that failed in round one drops out of round two's targets, so reading the verdict off
# the last round alone would let its failure vanish and the run exit 0 on a machine nobody
# rechecked.
$mergedStates = @{}
Merge-PatchRunStates -StateMap $mergedStates -CompletionStates @(
    [pscustomobject]@{ vmName = 'VM02'; state = 'Pending'; reason = 'r' },
    [pscustomobject]@{ vmName = 'VM05'; state = 'Failed'; reason = 'r' }
)
Merge-PatchRunStates -StateMap $mergedStates -CompletionStates @(
    [pscustomobject]@{ vmName = 'VM02'; state = 'Green'; reason = 'r' }
)

Assert-Equal -Actual $mergedStates.Count -Expected 2 -Message 'the merged verdict keeps VMs that dropped out of later rounds'
Assert-Equal -Actual ([string]$mergedStates['VM02'].state) -Expected 'Green' -Message 'a later round overwrites the state of its own targets'
Assert-Equal -Actual ([string]$mergedStates['VM05'].state) -Expected 'Failed' -Message 'a VM absent from the later round keeps its earlier failure'
Assert-Equal -Actual (Test-PatchRunAllGreen -StateMap $mergedStates) -Expected $false -Message 'an unresolved failure keeps the run from being all green'

$greenStateMap = @{}
Merge-PatchRunStates -StateMap $greenStateMap -CompletionStates @(
    [pscustomobject]@{ vmName = 'VM01'; state = 'Green'; reason = 'r' },
    [pscustomobject]@{ vmName = 'VM02'; state = 'GreenByOperatorChoice'; reason = 'r' },
    [pscustomobject]@{ vmName = 'VM03'; state = 'Excluded'; reason = 'r' }
)
Assert-Equal -Actual (Test-PatchRunAllGreen -StateMap $greenStateMap) -Expected $true -Message 'green, operator-accepted and excluded VMs together are all green'
Assert-Equal -Actual (Test-PatchRunAllGreen -StateMap @{}) -Expected $true -Message 'an empty run is vacuously all green'

# An allow-list, not a deny-list of Pending/Failed. Every state added after that test was written
# would otherwise have passed it by default - and so would a typo.
foreach ($blockingState in @('Pending', 'Failed', 'NeedsReview', 'PendingReboot', 'SomethingNobodyDefinedYet', '')) {
    $blockingMap = @{ 'VM-state' = [pscustomobject]@{ vmName = 'VM-state'; state = $blockingState } }
    Assert-Equal -Actual (Test-PatchRunAllGreen -StateMap $blockingMap) -Expected $false -Message ('state "' + $blockingState + '" cannot produce exit 0')
}
foreach ($successfulState in @('Green', 'GreenByOperatorChoice', 'Excluded')) {
    $successfulMap = @{ 'VM-state' = [pscustomobject]@{ vmName = 'VM-state'; state = $successfulState } }
    Assert-Equal -Actual (Test-PatchRunAllGreen -StateMap $successfulMap) -Expected $true -Message ('state "' + $successfulState + '" is an acceptable ending')
}

# A VM the run was supposed to reach but has no verdict for is not a success either: that is the
# shape a VM takes when it fell out of the round loop without anyone recording why.
$partialMap = @{ 'VM-known' = [pscustomobject]@{ vmName = 'VM-known'; state = 'Green' } }
Assert-Equal -Actual (Test-PatchRunAllGreen -StateMap $partialMap -ExpectedVMNames @('VM-known')) -Expected $true -Message 'an expected VM with a green verdict is fine'
Assert-Equal -Actual (Test-PatchRunAllGreen -StateMap $partialMap -ExpectedVMNames @('VM-known', 'VM-vanished')) -Expected $false -Message 'an expected VM with no verdict at all fails the run'

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
    BootTimeBaseline = $baseTime; BootTimeObserved = $baseTime
    UptimeBaselineSeconds = $null; UptimeObservedSeconds = $null
    AttemptCount = 0; TimeoutCount = 0; LastErrorMessage = $null; ReadTimeoutSeconds = $null
}
$boundedWait = Wait-RebootBatchBootTimes -Items @($waitItem) -WaitTimeoutSeconds 1 -PollSeconds 10 -ReadBootTimeScript $neverConfirmReadScript -SleepScript { param($Seconds) $sleepDurations.Add($Seconds) }
Assert-Equal -Actual $boundedWait.TimedOut -Expected $true -Message 'boot time wait honors the timeout deadline'
Assert-Equal -Actual (@($sleepDurations | Where-Object { $_ -gt 1 }).Count) -Expected 0 -Message 'boot time polling never sleeps past the timeout'
Assert-Equal -Actual $waitItem.ReadTimeoutSeconds -Expected 1 -Message 'boot time read receives remaining timeout budget'

# Grace period: the first read is deferred, the observation budget starts afterwards, and the
# uptime pair travels from the read into the record.
$graceSleeps = New-Object System.Collections.Generic.List[int]
$graceReadCount = New-Object System.Collections.Generic.List[string]
$graceItem = [pscustomobject]@{
    Sequence = 1; VMName = 'VM01'; ProcessId = 44; RebootReason = 'Reported after apply'; BatchNumber = 1
    BootTimeBaseline = $baseTime; BootTimeObserved = $baseTime
    UptimeBaselineSeconds = 900; UptimeObservedSeconds = 900
    AttemptCount = 0; TimeoutCount = 0; LastErrorMessage = $null; ReadTimeoutSeconds = $null
}
$graceReadScript = {
    param($Items)
    $graceReadCount.Add('read')
    return @($Items | ForEach-Object { [pscustomobject]@{ VMName = $_.VMName; BootTimeUtc = $newTime; UptimeSeconds = 12; Error = $null } })
}
$graceWait = Wait-RebootBatchBootTimes -Items @($graceItem) -WaitTimeoutSeconds 60 -PollSeconds 5 -GraceSeconds 90 -ReadBootTimeScript $graceReadScript -SleepScript { param($Seconds) $graceSleeps.Add($Seconds) }
Assert-Equal -Actual $graceSleeps.Count -Expected 1 -Message 'grace period sleeps exactly once before the first read'
Assert-Equal -Actual $graceSleeps[0] -Expected 90 -Message 'grace period sleeps for the requested time'
Assert-Equal -Actual $graceReadCount.Count -Expected 1 -Message 'grace period defers the first read without repeating it'
Assert-Equal -Actual $graceWait.Records.Count -Expected 1 -Message 'grace period leaves the observation budget intact'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject (@($graceWait.Records)[0]) -Path @('uptimeBaselineSeconds')) -Expected 900 -Message 'confirmed record keeps the baseline uptime'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject (@($graceWait.Records)[0]) -Path @('uptimeObservedSeconds')) -Expected 12 -Message 'confirmed record captures the observed uptime'

# A read that does not report uptime at all must stay a valid confirmation - uptime is diagnostic.
$noUptimeItem = [pscustomobject]@{
    Sequence = 1; VMName = 'VM01'; ProcessId = 44; RebootReason = 'Reported after apply'; BatchNumber = 1
    BootTimeBaseline = $baseTime; BootTimeObserved = $baseTime
    UptimeBaselineSeconds = $null; UptimeObservedSeconds = $null
    AttemptCount = 0; TimeoutCount = 0; LastErrorMessage = $null; ReadTimeoutSeconds = $null
}
$noUptimeWait = Wait-RebootBatchBootTimes -Items @($noUptimeItem) -WaitTimeoutSeconds 60 -PollSeconds 5 -ReadBootTimeScript { param($Items) @($Items | ForEach-Object { [pscustomobject]@{ VMName = $_.VMName; BootTimeUtc = $newTime; Error = $null } }) } -SleepScript { param($Seconds) $null = $Seconds }
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject (@($noUptimeWait.Records)[0]) -Path @('validationStatus')) -Expected 'Confirmed' -Message 'missing uptime does not block confirmation'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject (@($noUptimeWait.Records)[0]) -Path @('uptimeObservedSeconds')) -Expected $null -Message 'missing uptime is recorded as null'

# RETRY must not pay the grace again: the batch has already been down for a full timeout period.
Reset-RebootTestState
$graceCoordinatorSleeps = New-Object System.Collections.Generic.List[int]
$graceRetryRecords = @(Invoke-RebootBatchCoordinator -RebootTargets @($abortTargets[0]) -BatchSize 1 -WaitTimeoutSeconds 0 -PollSeconds 1 -GraceSeconds 90 -ReadBootTimeScript $retryReadScript -InitiateRebootScript $successInitiateScript -DecisionPromptScript $retryDecisionScript -SleepScript { param($Seconds) $graceCoordinatorSleeps.Add($Seconds) })
Assert-Equal -Actual (@($graceCoordinatorSleeps | Where-Object { $_ -eq 90 }).Count) -Expected 1 -Message 'grace is paid once per batch, not once per retry'
Assert-Equal -Actual (Get-ObjectPropertyValue -InputObject (@($graceRetryRecords)[0]) -Path @('validationStatus')) -Expected 'Confirmed' -Message 'grace does not change the retry outcome'

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

# F5: typed credential failures must never be sent to shutdown.exe, while an ambiguous
# network failure after a single send must be observed rather than sent again.
Reset-RebootTestState
$credentialFailureDecisionCalls = 0
$credentialFailureInitiateCalls = 0
$credentialFailureRecords = @(Invoke-RebootBatchCoordinator -RebootTargets @((New-RebootTestTarget -Sequence 1 -VMName 'VM-credential-failure')) -BatchSize 1 -WaitTimeoutSeconds 60 -PollSeconds 1 -ReadBootTimeScript {
        param($Items)
        return @($Items | ForEach-Object {
                [pscustomobject]@{
                    VMName = $_.VMName
                    BootTimeUtc = $null
                    Error = 'Guest credential was skipped.'
                    ErrorKind = 'CredentialsSkipped'
                    RejectedBeforeStart = $true
                }
            })
    } -InitiateRebootScript {
        param($Items)
        $script:credentialFailureInitiateCalls += @($Items).Count
        return @()
    } -DecisionPromptScript {
        param($Context)
        $script:credentialFailureDecisionCalls++
        return 'CONTINUE'
    } -SleepScript { param($Seconds) $null = $Seconds })
$credentialFailureRecord = @($credentialFailureRecords)[0]
Assert-Equal -Actual $credentialFailureInitiateCalls -Expected 0 -Message 'credential-skipped reboot target never sends shutdown.exe'
Assert-Equal -Actual $credentialFailureDecisionCalls -Expected 0 -Message 'credential-skipped reboot target never reaches a generic reboot prompt'
Assert-Equal -Actual $credentialFailureRecord.action -Expected 'Failed' -Message 'credential-skipped reboot target is an explicit failure'
Assert-Equal -Actual (Get-RuntimePropertyValue -InputObject $credentialFailureRecord -Name 'errorKind') -Expected 'CredentialsSkipped' -Message 'credential-skipped reboot record preserves its typed error'
Assert-Equal -Actual (Get-RuntimePropertyValue -InputObject $credentialFailureRecord -Name 'rejectedBeforeStart') -Expected $true -Message 'credential-skipped reboot record preserves pre-start rejection'

Reset-RebootTestState
$ambiguousRestartDecisionCalls = 0
$ambiguousRestartSendCalls = 0
$ambiguousRestartReadScript = {
    param($Items)
    $results = @()
    foreach ($item in @($Items)) {
        $vmName = [string]$item.VMName
        if (-not $script:readAttempts.ContainsKey($vmName)) {
            $script:readAttempts[$vmName] = 0
        }
        $attempt = $script:readAttempts[$vmName]
        $script:readAttempts[$vmName]++
        $results += [pscustomobject]@{
            VMName = $vmName
            BootTimeUtc = if ($attempt -eq 0) { $baseTime } else { $newTime }
            Error = $null
        }
    }
    return @($results)
}
$ambiguousRestartRecords = @(Invoke-RebootBatchCoordinator -RebootTargets @((New-RebootTestTarget -Sequence 1 -VMName 'VM-ambiguous-restart')) -BatchSize 1 -WaitTimeoutSeconds 60 -PollSeconds 1 -GraceSeconds 0 -ReadBootTimeScript $ambiguousRestartReadScript -InitiateRebootScript {
        param($Items)
        $script:ambiguousRestartSendCalls += @($Items).Count
        return @($Items | ForEach-Object {
                [pscustomobject]@{
                    VMName = $_.VMName
                    ProcessId = $null
                    Error = 'Synthetic connection reset after reboot submission.'
                    ErrorKind = 'Transient'
                    RejectedBeforeStart = $false
                }
            })
    } -DecisionPromptScript {
        param($Context)
        $script:ambiguousRestartDecisionCalls++
        return 'ABORT'
    } -SleepScript { param($Seconds) $null = $Seconds })
$ambiguousRestartRecord = @($ambiguousRestartRecords)[0]
Assert-Equal -Actual $ambiguousRestartSendCalls -Expected 1 -Message 'ambiguous reboot initiation sends shutdown.exe exactly once'
Assert-Equal -Actual $ambiguousRestartDecisionCalls -Expected 0 -Message 'ambiguous reboot initiation is observed without an initiation retry prompt'
Assert-Equal -Actual $ambiguousRestartRecord.action -Expected 'Initiated' -Message 'ambiguous reboot initiation remains an observed reboot'
Assert-Equal -Actual $ambiguousRestartRecord.validationStatus -Expected 'Confirmed' -Message 'ambiguous reboot is confirmed from the later boot time'
Assert-Equal -Actual (Get-RuntimePropertyValue -InputObject $ambiguousRestartRecord -Name 'errorKind') -Expected 'Transient' -Message 'ambiguous reboot record preserves its typed error'
Assert-Equal -Actual (Get-RuntimePropertyValue -InputObject $ambiguousRestartRecord -Name 'rejectedBeforeStart') -Expected $false -Message 'ambiguous reboot record preserves non-rejection'

# A reboot job that never answered is the same ambiguity one level up. Reported as a failed
# initiation it would offer CONTINUE, and the next batch would restart while this guest may be
# going down - so it has to hold the batch gate until its boot time moves.
Reset-RebootTestState
$lostJobEvents = New-Object System.Collections.Generic.List[string]
$lostJobDecisionCalls = 0
$lostJobRecords = @(Invoke-RebootBatchCoordinator -RebootTargets @((New-RebootTestTarget -Sequence 1 -VMName 'VM-lost-job'), (New-RebootTestTarget -Sequence 2 -VMName 'VM-next-batch')) -BatchSize 1 -WaitTimeoutSeconds 60 -PollSeconds 1 -GraceSeconds 0 -ReadBootTimeScript {
        param($Items)
        $results = @()
        foreach ($item in @($Items)) {
            $vmName = [string]$item.VMName
            if (-not $script:readAttempts.ContainsKey($vmName)) {
                $script:readAttempts[$vmName] = 0
            }
            $attempt = $script:readAttempts[$vmName]
            $script:readAttempts[$vmName]++
            $lostJobEvents.Add(('read:{0}:{1}' -f $vmName, $attempt))
            $results += [pscustomobject]@{
                VMName = $vmName
                BootTimeUtc = if ($attempt -eq 0) { $baseTime } else { $newTime }
                Error = $null
            }
        }
        return @($results)
    } -InitiateRebootScript {
        param($Items)
        return @($Items | ForEach-Object {
                $lostJobEvents.Add(('restart:{0}' -f $_.VMName))
                if ([string]$_.VMName -eq 'VM-lost-job') {
                    [pscustomobject]@{ VMName = $_.VMName; ProcessId = $null; Error = 'Job timed out after 300 seconds.'; ErrorKind = 'JobResultLost'; RejectedBeforeStart = $false }
                }
                else {
                    [pscustomobject]@{ VMName = $_.VMName; ProcessId = 205; Error = $null }
                }
            })
    } -DecisionPromptScript {
        param($Context)
        $script:lostJobDecisionCalls++
        Add-Failure -Message ('Unexpected operator prompt for a lost reboot job: {0}' -f $Context.Stage)
        return 'ABORT'
    } -SleepScript { param($Seconds) $null = $Seconds })
$lostJobRecord = @($lostJobRecords | Where-Object { $_.vmName -eq 'VM-lost-job' })[0]
Assert-Equal -Actual $lostJobDecisionCalls -Expected 0 -Message 'a lost reboot job is observed instead of being offered as a failed initiation'
Assert-Equal -Actual (Get-RuntimePropertyValue -InputObject $lostJobRecord -Name 'action') -Expected 'Initiated' -Message 'a lost reboot job remains an observed reboot'
Assert-Equal -Actual (Get-RuntimePropertyValue -InputObject $lostJobRecord -Name 'validationStatus') -Expected 'Confirmed' -Message 'a lost reboot job is confirmed from the later boot time'
Assert-Equal -Actual (Get-RuntimePropertyValue -InputObject $lostJobRecord -Name 'errorKind') -Expected 'JobResultLost' -Message 'a lost reboot job record keeps the job-level error kind'
$lostJobConfirmIndex = $lostJobEvents.IndexOf('read:VM-lost-job:1')
$nextBatchRestartIndex = $lostJobEvents.IndexOf('restart:VM-next-batch')
Assert-Equal -Actual ($lostJobConfirmIndex -ge 0 -and $nextBatchRestartIndex -gt $lostJobConfirmIndex) -Expected $true -Message 'the next reboot batch starts only after the lost job VM confirmed its reboot'


# --- Shared VM-target parsing (scripts/VMTargetLib.ps1 + launcher prompt wrapper) ---
# The pure helpers live in a dot-sourceable lib; the launcher's Resolve-VMTargetNames adds
# the interactive prompt loop on top and has top-level side effects, so it is extracted via
# the AST and exercised with a Read-Host override.
. (Join-Path $repoRoot 'scripts\VMTargetLib.ps1')
. (Join-Path $repoRoot 'scripts\CredentialRecovery.ps1')

# --- guest credential recovery ---------------------------------------------------
# These tests exercise the resolver through injected seams. No vCenter, GuestOps operation,
# or credential store is involved here.
$credentialRecoveryAvailable = $false
try {
    $credentialRecoveryProbe = New-GuestCredentialContext -TargetNames @('probe') -CredentialMap @{}
    $credentialRecoveryAvailable = $true
}
catch {
    Add-Failure -Message ('Credential recovery RED: resolver module is not available yet. ' + $_.Exception.Message)
}

if ($credentialRecoveryAvailable) {
    $oldGuestCredential = New-TestCredential 'OLD\adm'
    $newBadGuestCredential = New-TestCredential 'NEW\adm'
    $newGoodGuestCredential = New-TestCredential 'NEW2\adm'
    $credentialMap = @{
        'vm1.contoso.com' = $oldGuestCredential
        'vm2.contoso.com' = $oldGuestCredential
    }
    $credentialContext = New-GuestCredentialContext -TargetNames @('vm1.contoso.com', 'vm2.contoso.com') -CredentialMap $credentialMap

    $promptBoundaryReplacement = New-TestCredential 'PROMPT\adm'
    $promptBoundaryContext = New-GuestCredentialContext -TargetNames @('vm-prompt-boundary') -CredentialMap @{ 'vm-prompt-boundary' = $oldGuestCredential }
    $promptBoundaryState = [pscustomobject]@{ DecisionCalls = 0; Reason = $null }
    $promptBoundaryResults = @(Resolve-GuestCredentialForTarget -VMName 'vm-prompt-boundary' -Context $promptBoundaryContext -Interactive -ValidateScript {
        param($VMName, $Credential)
        if ($Credential.UserName -eq 'OLD\adm') {
            return [pscustomobject]@{ Status = 'Invalid'; ErrorKind = 'InvalidGuestLogin'; Error = 'synthetic rejection' }
        }

        return [pscustomobject]@{ Status = 'Valid'; ErrorKind = $null; Error = $null }
    } -DecisionScript {
        param($VMName, $AccountKey, $Members, $Reason)
        $promptBoundaryState.DecisionCalls++
        $promptBoundaryState.Reason = [string]$Reason
        return [pscustomobject]@{ Action = 'Retry'; Credential = $promptBoundaryReplacement; Remember = $false }
    }.GetNewClosure())
    Assert-Equal -Actual $promptBoundaryResults.Count -Expected 1 -Message 'credential recovery returns one resolution object'
    $promptBoundaryResult = $promptBoundaryResults[0]
    Assert-Equal -Actual $promptBoundaryResult.Status -Expected 'Ready' -Message 'an invalid guest login invokes the decision callback and validates its replacement'
    Assert-Equal -Actual $promptBoundaryState.DecisionCalls -Expected 1 -Message 'an invalid guest login asks for exactly one decision'
    Assert-Equal -Actual ([string]::IsNullOrWhiteSpace($promptBoundaryState.Reason)) -Expected $false -Message 'the decision callback receives an invalid-login reason'
    if ($promptBoundaryResult.Status -eq 'Ready') {
        Assert-Equal -Actual $promptBoundaryResult.Credential.UserName -Expected 'PROMPT\adm' -Message 'the decision callback replacement is returned only after validation'
    }

    $script:credentialValidationCalls = @()
    $script:credentialValidatedCalls = @()
    $credentialDecisionState = [pscustomobject]@{ Calls = @(); MapAtDecision = @() }
    $credentialValidationScript = {
        param($VMName, $Credential)
        $script:credentialValidationCalls += [pscustomobject]@{
            VMName = $VMName
            UserName = [string]$Credential.UserName
        }

        if ($Credential.UserName -eq 'OLD\adm' -or $Credential.UserName -eq 'NEW\adm') {
            return [pscustomobject]@{ Status = 'Invalid'; ErrorKind = 'InvalidGuestLogin'; Error = 'synthetic rejection' }
        }

        return [pscustomobject]@{ Status = 'Valid'; ErrorKind = $null; Error = $null }
    }
    $credentialDecisionScript = {
        param($VMName, $AccountKey, $Members, $Reason)
        $credentialDecisionState.Calls += [pscustomobject]@{
            VMName = $VMName
            AccountKey = $AccountKey
            Members = @($Members)
            Reason = [string]$Reason
        }
        $credentialDecisionState.MapAtDecision += [string]$credentialContext.CredentialMap[$VMName].UserName
        if ($credentialDecisionState.Calls.Count -eq 1) {
            return [pscustomobject]@{ Action = 'Retry'; Credential = $newBadGuestCredential; Remember = $false }
        }

        return [pscustomobject]@{ Action = 'Retry'; Credential = $newGoodGuestCredential; Remember = $true }
    }.GetNewClosure()
    $credentialOnValidatedScript = {
        param($AccountKey, $Members, $Credential, $Remember)
        $script:credentialValidatedCalls += [pscustomobject]@{
            AccountKey = $AccountKey
            Members = @($Members)
            UserName = [string]$Credential.UserName
            Remember = $Remember
        }
    }

    $readyCredential = Resolve-GuestCredentialForTarget -VMName 'vm1.contoso.com' -Context $credentialContext -Interactive -ValidateScript $credentialValidationScript -DecisionScript $credentialDecisionScript -OnValidatedScript $credentialOnValidatedScript
    Assert-Equal -Actual $readyCredential.Status -Expected 'Ready' -Message 'invalid guest credentials can be replaced after validation'
    Assert-Equal -Actual $readyCredential.AccountKey -Expected 'domain:contoso.com' -Message 'credential recovery uses the grouped account key'
    if ($readyCredential.Status -eq 'Ready') {
        Assert-Equal -Actual $readyCredential.Credential.UserName -Expected 'NEW2\adm' -Message 'only the successfully validated replacement is returned'
    }
    Assert-Equal -Actual (@($script:credentialValidationCalls | ForEach-Object { $_.UserName }) -join ';') -Expected 'OLD\adm;NEW\adm;NEW2\adm' -Message 'recovery never retries the rejected credential automatically'
    Assert-Equal -Actual $credentialDecisionState.Calls.Count -Expected 2 -Message 'each rejected credential asks for one operator decision'
    Assert-Equal -Actual (@($credentialDecisionState.MapAtDecision) -join ';') -Expected 'OLD\adm;OLD\adm' -Message 'the credential map changes only after validation succeeds'
    Assert-Equal -Actual $script:credentialValidatedCalls.Count -Expected 1 -Message 'successful replacement invokes the validation callback once'
    Assert-Equal -Actual $script:credentialValidatedCalls[0].Remember -Expected $true -Message 'the replacement decision passes Remember to the callback'
    Assert-Equal -Actual $credentialMap['vm1.contoso.com'].UserName -Expected 'NEW2\adm' -Message 'the successful replacement updates the VM map in memory'
    Assert-Equal -Actual $credentialMap['vm2.contoso.com'].UserName -Expected 'NEW2\adm' -Message 'all members receive the validated group credential in memory'

    $vm2ValidationCountBefore = $script:credentialValidationCalls.Count
    $vm2Ready = Resolve-GuestCredentialForTarget -VMName 'vm2.contoso.com' -Context $credentialContext -ValidateScript $credentialValidationScript -DecisionScript { throw 'unexpected credential decision' } -OnValidatedScript $credentialOnValidatedScript
    Assert-Equal -Actual $vm2Ready.Status -Expected 'Ready' -Message 'a shared domain credential remains usable for another VM'
    Assert-Equal -Actual $script:credentialValidationCalls.Count -Expected ($vm2ValidationCountBefore + 1) -Message 'each VM in a shared group is validated separately'
    Assert-Equal -Actual $credentialContext.ValidatedTargets.ContainsKey('vm1.contoso.com') -Expected $true -Message 'the first VM records its own validation'
    Assert-Equal -Actual $credentialContext.ValidatedTargets.ContainsKey('vm2.contoso.com') -Expected $true -Message 'the second VM records its own validation'
    Assert-Equal -Actual $script:credentialValidatedCalls[1].Remember -Expected $null -Message 'initially supplied credentials pass a null Remember value'

    $vm2CachedValidationCount = $script:credentialValidationCalls.Count
    $vm2Cached = Resolve-GuestCredentialForTarget -VMName 'vm2.contoso.com' -Context $credentialContext -ValidateScript { throw 'cached target must not validate again' } -DecisionScript { throw 'cached target must not ask again' }
    Assert-Equal -Actual $vm2Cached.Status -Expected 'Ready' -Message 'a target validated in this run can use its cached result'
    Assert-Equal -Actual $script:credentialValidationCalls.Count -Expected $vm2CachedValidationCount -Message 'cached validation avoids a duplicate AuthManager call'

    $forcedCredential = New-TestCredential 'FORCED\adm'
    $forceDecisionState = [pscustomobject]@{ Calls = 0 }
    $forceDecisionScript = {
        param($VMName, $AccountKey, $Members, $Reason)
        $forceDecisionState.Calls++
        return [pscustomobject]@{ Action = 'Retry'; Credential = $forcedCredential; Remember = $false }
    }.GetNewClosure()
    $forcedResult = Resolve-GuestCredentialForTarget -VMName 'vm1.contoso.com' -Context $credentialContext -ForcePrompt -Interactive -ValidateScript $credentialValidationScript -DecisionScript $forceDecisionScript -OnValidatedScript $credentialOnValidatedScript
    Assert-Equal -Actual $forcedResult.Status -Expected 'Ready' -Message 'ForcePrompt accepts a replacement without retrying the known credential'
    Assert-Equal -Actual $forceDecisionState.Calls -Expected 1 -Message 'ForcePrompt asks for a new credential directly'
    Assert-Equal -Actual $script:credentialValidationCalls[$script:credentialValidationCalls.Count - 1].UserName -Expected 'FORCED\adm' -Message 'ForcePrompt validates only the newly supplied credential'
    Assert-Equal -Actual $forcedResult.Credential.UserName -Expected 'FORCED\adm' -Message 'ForcePrompt returns the replacement credential'
    Assert-Equal -Actual $credentialContext.ValidatedTargets.ContainsKey('vm2.contoso.com') -Expected $false -Message 'changing shared credentials invalidates other VM validation entries'
    Assert-Equal -Actual $credentialValidatedCalls[2].Remember -Expected $false -Message 'Remember=false is preserved for a replacement callback'

    $forcedVm2ValidationCount = $script:credentialValidationCalls.Count
    $forcedVm2 = Resolve-GuestCredentialForTarget -VMName 'vm2.contoso.com' -Context $credentialContext -ValidateScript $credentialValidationScript -DecisionScript { throw 'forced VM2 credential is valid' }
    Assert-Equal -Actual $forcedVm2.Status -Expected 'Ready' -Message 'a shared-group peer can revalidate after credential replacement'
    Assert-Equal -Actual $script:credentialValidationCalls.Count -Expected ($forcedVm2ValidationCount + 1) -Message 'invalidated peer validation is not trusted from the old credential'

    $localCredential = New-TestCredential 'Administrator'
    $localContext = New-GuestCredentialContext -TargetNames @('VM01', 'VM02') -CredentialMap @{ VM01 = $localCredential; VM02 = $localCredential }
    $script:localValidationCalls = 0
    $script:localDecisionCalls = 0
    $localSkipped = Resolve-GuestCredentialForTarget -VMName 'VM01' -Context $localContext -Interactive -ValidateScript {
        param($VMName, $Credential)
        $script:localValidationCalls++
        [pscustomobject]@{ Status = 'Invalid'; ErrorKind = 'InvalidCredentials'; Error = 'Rejected' }
    } -DecisionScript {
        param($VMName, $AccountKey, $Members, $Reason)
        $script:localDecisionCalls++
        [pscustomobject]@{ Action = 'SkipAccount'; Credential = $null; Remember = $true }
    }
    Assert-Equal -Actual $localSkipped.Status -Expected 'Skipped' -Message 'operator may skip a local account'
    Assert-Equal -Actual $localContext.SkippedAccountKeys.ContainsKey('local:VM01') -Expected $true -Message 'skip marks only the rejected local account'
    Assert-Equal -Actual $localContext.SkippedAccountKeys.ContainsKey('local:VM02') -Expected $false -Message 'another local account remains usable'
    $localReady = Resolve-GuestCredentialForTarget -VMName 'VM02' -Context $localContext -ValidateScript {
        param($VMName, $Credential)
        $script:localValidationCalls++
        [pscustomobject]@{ Status = 'Valid'; ErrorKind = $null; Error = $null }
    } -DecisionScript { throw 'VM02 must not inherit VM01 skip' }
    Assert-Equal -Actual $localReady.Status -Expected 'Ready' -Message 'a second local account continues independently'
    Assert-Equal -Actual $script:localValidationCalls -Expected 2 -Message 'local account isolation does not suppress the second VM'

    $sharedSkipContext = New-GuestCredentialContext -TargetNames @('VM01.example.test', 'VM02.example.test') -CredentialMap @{ 'VM01.example.test' = $oldGuestCredential; 'VM02.example.test' = $oldGuestCredential }
    $sharedSkipState = [pscustomobject]@{ ValidationCalls = 0; DecisionCalls = 0 }
    $sharedSkipFirst = Resolve-GuestCredentialForTarget -VMName 'VM01.example.test' -Context $sharedSkipContext -Interactive -ValidateScript {
        param($VMName, $Credential)
        $sharedSkipState.ValidationCalls++
        return [pscustomobject]@{ Status = 'Invalid'; ErrorKind = 'InvalidGuestLogin'; Error = 'Rejected' }
    }.GetNewClosure() -DecisionScript {
        param($VMName, $AccountKey, $Members, $Reason)
        $sharedSkipState.DecisionCalls++
        return [pscustomobject]@{ Action = 'SkipAccount'; Credential = $null; Remember = $false }
    }.GetNewClosure()
    Assert-Equal -Actual $sharedSkipFirst.Status -Expected 'Skipped' -Message 'the operator can skip a shared domain account'
    $sharedSkipPeer = Resolve-GuestCredentialForTarget -VMName 'VM02.example.test' -Context $sharedSkipContext -Interactive -ValidateScript {
        $sharedSkipState.ValidationCalls++
        throw 'a skipped shared account must not validate a later member'
    }.GetNewClosure() -DecisionScript {
        $sharedSkipState.DecisionCalls++
        throw 'a skipped shared account must not prompt a later member'
    }.GetNewClosure()
    Assert-Equal -Actual $sharedSkipPeer.Status -Expected 'Skipped' -Message 'a skipped shared account skips later members'
    Assert-Equal -Actual $sharedSkipState.ValidationCalls -Expected 1 -Message 'a skipped shared account performs no later validation'
    Assert-Equal -Actual $sharedSkipState.DecisionCalls -Expected 1 -Message 'a skipped shared account performs no later decision callback'

    # A VM the operator refused at the startup credential prompt, before anything ran. It has to
    # arrive as a skip rather than as a missing credential: "no credential is available" is a gap
    # somebody still has to fill, a skip is an answer, and only the skip is read before the
    # resolver reaches for a credential - which is what keeps those VMs from costing a vCenter
    # call each. Per VM, not per account: that prompt covers only the members no stored entry
    # already covers, so VM02 below shares the domain account and keeps its own credential.
    $preSkipContext = New-GuestCredentialContext -TargetNames @('VM01.example.test', 'VM02.example.test', 'standalone') `
        -CredentialMap @{ 'VM02.example.test' = $oldGuestCredential; 'standalone' = $oldGuestCredential } `
        -SkippedTargetNames @('vm01.EXAMPLE.test', '   ', '')
    Assert-Equal -Actual $preSkipContext.SkippedTargetNames.ContainsKey('VM01.example.test') -Expected $true -Message 'a skipped target is recorded, matched without regard to case'
    Assert-Equal -Actual $preSkipContext.SkippedTargetNames.Count -Expected 1 -Message 'blank entries record nothing'
    Assert-Equal -Actual $preSkipContext.SkippedAccountKeys.Count -Expected 0 -Message 'a prompt skip is not an account refusal'

    $script:preSkipValidationCalls = 0
    $preSkipped = Resolve-GuestCredentialForTarget -VMName 'VM01.example.test' -Context $preSkipContext -Interactive -ValidateScript {
        $script:preSkipValidationCalls++
        throw 'a VM skipped before the run must not be validated'
    } -DecisionScript { throw 'a VM skipped before the run must not prompt' }
    Assert-Equal -Actual $preSkipped.Status -Expected 'Skipped' -Message 'a VM skipped at the credential prompt resolves as skipped, not as a missing credential'

    $preSkipPeer = Resolve-GuestCredentialForTarget -VMName 'VM02.example.test' -Context $preSkipContext -Interactive -ValidateScript {
        param($VMName, $Credential)
        $script:preSkipValidationCalls++
        [pscustomobject]@{ Status = 'Valid'; ErrorKind = $null; Error = $null }
    } -DecisionScript { throw 'a peer that was not skipped must not prompt' }
    Assert-Equal -Actual $preSkipPeer.Status -Expected 'Ready' -Message 'a peer on the same account keeps the credential it already had'

    $preSkipOther = Resolve-GuestCredentialForTarget -VMName 'standalone' -Context $preSkipContext -Interactive -ValidateScript {
        param($VMName, $Credential)
        $script:preSkipValidationCalls++
        [pscustomobject]@{ Status = 'Valid'; ErrorKind = $null; Error = $null }
    } -DecisionScript { throw 'a VM on another account must not prompt' }
    Assert-Equal -Actual $preSkipOther.Status -Expected 'Ready' -Message 'a VM on another account is unaffected by the skip'
    Assert-Equal -Actual $script:preSkipValidationCalls -Expected 2 -Message 'only the skipped VM was kept away from validation'

    $script:nonInteractiveDecisionCalls = 0
    $nonInteractive = Resolve-GuestCredentialForTarget -VMName 'VM-noninteractive' -Context (New-GuestCredentialContext -TargetNames @('VM-noninteractive') -CredentialMap @{ 'VM-noninteractive' = $oldGuestCredential }) -ValidateScript {
        param($VMName, $Credential)
        [pscustomobject]@{ Status = 'Invalid'; ErrorKind = 'InvalidGuestLogin'; Error = 'Rejected' }
    } -DecisionScript { $script:nonInteractiveDecisionCalls++; throw 'non-interactive recovery must not ask' }
    Assert-Equal -Actual $nonInteractive.Status -Expected 'Failed' -Message 'non-interactive invalid credentials fail without prompting'
    Assert-Equal -Actual $script:nonInteractiveDecisionCalls -Expected 0 -Message 'non-interactive mode never invokes the decision callback'

    $script:nonLoginDecisionCalls = 0
    $networkError = Resolve-GuestCredentialForTarget -VMName 'VM-network' -Context (New-GuestCredentialContext -TargetNames @('VM-network') -CredentialMap @{ 'VM-network' = $oldGuestCredential }) -Interactive -ValidateScript {
        param($VMName, $Credential)
        [pscustomobject]@{ Status = 'Error'; ErrorKind = 'Transient'; Error = 'network failure' }
    } -DecisionScript { $script:nonLoginDecisionCalls++; throw 'network errors must not ask for a new password' }
    Assert-Equal -Actual $networkError.Status -Expected 'Failed' -Message 'network validation errors fail without credential recovery'
    Assert-Equal -Actual $script:nonLoginDecisionCalls -Expected 0 -Message 'non-login validation errors never invoke the decision callback'

    $permissionError = Resolve-GuestCredentialForTarget -VMName 'VM-permission' -Context (New-GuestCredentialContext -TargetNames @('VM-permission') -CredentialMap @{ 'VM-permission' = $oldGuestCredential }) -Interactive -ValidateScript {
        param($VMName, $Credential)
        [pscustomobject]@{ Status = 'Invalid'; ErrorKind = 'GuestPermissionDenied'; Error = 'operation denied' }
    } -DecisionScript { throw 'permission errors must not ask for a new password' }
    Assert-Equal -Actual $permissionError.Status -Expected 'Failed' -Message 'GuestPermissionDenied is not treated as a bad password'

    $cancelContext = New-GuestCredentialContext -TargetNames @('VM-cancel') -CredentialMap @{ 'VM-cancel' = $oldGuestCredential }
    $cancelResult = Resolve-GuestCredentialForTarget -VMName 'VM-cancel' -Context $cancelContext -Interactive -ValidateScript {
        param($VMName, $Credential)
        [pscustomobject]@{ Status = 'Invalid'; ErrorKind = 'InvalidGuestLogin'; Error = 'Rejected' }
    } -DecisionScript { $null }
    Assert-Equal -Actual $cancelResult.Status -Expected 'Aborted' -Message 'an empty or cancelled credential decision aborts recovery'
    Assert-Equal -Actual $cancelContext.Aborted -Expected $true -Message 'an empty or cancelled decision marks the context aborted'
    $script:cancelValidationCalls = 0
    $afterCancel = Resolve-GuestCredentialForTarget -VMName 'VM-cancel' -Context $cancelContext -Interactive -ValidateScript {
        $script:cancelValidationCalls++
        [pscustomobject]@{ Status = 'Valid'; ErrorKind = $null; Error = $null }
    } -DecisionScript { throw 'aborted context must not ask again' }
    Assert-Equal -Actual $afterCancel.Status -Expected 'Aborted' -Message 'aborted context rejects later targets'
    Assert-Equal -Actual $script:cancelValidationCalls -Expected 0 -Message 'aborted context does not validate later credentials'

    $emptyActionResult = Resolve-GuestCredentialForTarget -VMName 'VM-empty-action' -Context (New-GuestCredentialContext -TargetNames @('VM-empty-action') -CredentialMap @{ 'VM-empty-action' = $oldGuestCredential }) -Interactive -ValidateScript {
        param($VMName, $Credential)
        [pscustomobject]@{ Status = 'Invalid'; ErrorKind = 'InvalidGuestLogin'; Error = 'Rejected' }
    } -DecisionScript { [pscustomobject]@{ Action = ''; Credential = $null; Remember = $false } }
    Assert-Equal -Actual $emptyActionResult.Status -Expected 'Aborted' -Message 'an empty decision action is treated as cancellation'

    $saveCredential = New-TestCredential 'SAVED\adm'
    $saveContext = New-GuestCredentialContext -TargetNames @('VM-save') -CredentialMap @{ 'VM-save' = $oldGuestCredential }
    $saveWarnings = @()
    $saveDecisionScript = {
        param($VMName, $AccountKey, $Members, $Reason)
        [pscustomobject]@{ Action = 'Retry'; Credential = $saveCredential; Remember = $true }
    }.GetNewClosure()
    $saveResult = Resolve-GuestCredentialForTarget -VMName 'VM-save' -Context $saveContext -Interactive -ValidateScript {
        param($VMName, $Credential)
        if ($Credential.UserName -eq 'OLD\adm') {
            [pscustomobject]@{ Status = 'Invalid'; ErrorKind = 'InvalidGuestLogin'; Error = 'Rejected' }
        }
        else {
            [pscustomobject]@{ Status = 'Valid'; ErrorKind = $null; Error = $null }
        }
    } -DecisionScript $saveDecisionScript -OnValidatedScript {
        throw 'synthetic credential store failure'
    } -WarningVariable saveWarnings
    Assert-Equal -Actual $saveResult.Status -Expected 'Ready' -Message 'a save callback failure does not discard a valid replacement'
    Assert-Equal -Actual $saveContext.CredentialMap['VM-save'].UserName -Expected 'SAVED\adm' -Message 'a save callback failure leaves the valid credential in memory'
    Assert-Equal -Actual ($saveWarnings.Count -gt 0) -Expected $true -Message 'a save callback failure emits a warning'

    # A replacement the guest also refuses must never reach the store: overwriting a saved
    # entry with it would leave the operator with a file that is wrong in a new way, and they
    # would have no way to tell which of the two passwords the file now holds.
    $script:rejectedSaveCalls = 0
    $rejectedContext = New-GuestCredentialContext -TargetNames @('VM-reject') -CredentialMap @{ 'VM-reject' = $oldGuestCredential }
    $script:rejectedDecisions = 0
    $rejectedResult = Resolve-GuestCredentialForTarget -VMName 'VM-reject' -Context $rejectedContext -Interactive -ValidateScript {
        param($VMName, $Credential)
        [pscustomobject]@{ Status = 'Invalid'; ErrorKind = 'InvalidGuestLogin'; Error = 'Rejected' }
    } -DecisionScript {
        param($VMName, $AccountKey, $Members, $Reason)
        $script:rejectedDecisions++
        if ($script:rejectedDecisions -eq 1) {
            [pscustomobject]@{ Action = 'Retry'; Credential = (New-TestCredential 'ALSO\wrong'); Remember = $true }
        }
        else {
            [pscustomobject]@{ Action = 'SkipAccount'; Credential = $null; Remember = $false }
        }
    } -OnValidatedScript {
        param($AccountKey, $Members, $Credential, $Remember)
        $script:rejectedSaveCalls++
    }
    Assert-Equal -Actual $rejectedResult.Status -Expected 'Skipped' -Message 'a replacement the guest also refuses ends in a skip, not a ready credential'
    Assert-Equal -Actual $script:rejectedSaveCalls -Expected 0 -Message 'a replacement that never validated is never offered to the credential store'

    # The real GuestOps adapter must resolve every manager, including AuthManager, from
    # the Client attached to this VM view. A global/default client is deliberately absent.
    $processManagerB = [pscustomobject]@{ Name = 'process-B' }
    $fileManagerB = [pscustomobject]@{ Name = 'file-B' }
    $authManagerB = [pscustomobject]@{ Name = 'auth-B'; Calls = @(); Exception = $null }
    $guestOpsManagerB = [pscustomobject]@{ ProcessManager = 'process-ref-B'; FileManager = 'file-ref-B'; AuthManager = 'auth-ref-B' }
    $clientB = [pscustomobject]@{ ServiceContent = [pscustomobject]@{ GuestOperationsManager = 'guest-ops-ref-B' } }
    $clientB | Add-Member -MemberType ScriptMethod -Name GetView -Value {
        param($ManagedObjectReference, $PropertySpec)
        switch ([string]$ManagedObjectReference) {
            'guest-ops-ref-B' { return $guestOpsManagerB }
            'process-ref-B' { return $processManagerB }
            'file-ref-B' { return $fileManagerB }
            'auth-ref-B' { return $authManagerB }
            default { throw ('unexpected global or foreign reference: ' + $ManagedObjectReference) }
        }
    }.GetNewClosure()
    $vmViewB = [pscustomobject]@{ Client = $clientB; MoRef = 'vm-ref-B' }
    $managerResultB = Get-GuestOpsManagers -VMView $vmViewB
    Assert-Equal -Actual $managerResultB.ProcessManager.Name -Expected 'process-B' -Message 'process manager comes from the VM client'
    Assert-Equal -Actual $managerResultB.FileManager.Name -Expected 'file-B' -Message 'file manager comes from the VM client'
    Assert-Equal -Actual $managerResultB.AuthManager.Name -Expected 'auth-B' -Message 'auth manager comes from the VM client'

    $savedGuestAuthentication = (Get-Item Function:\New-GuestAuthentication).ScriptBlock
    function New-GuestAuthentication {
        param([pscredential]$Credential)
        [pscustomobject]@{ UserName = $Credential.UserName }
    }
    try {
        $authManagerB | Add-Member -MemberType ScriptMethod -Name ValidateCredentialsInGuest -Value {
            param($MoRef, $Auth)
            $this.Calls += [pscustomobject]@{ MoRef = $MoRef; UserName = $Auth.UserName }
            if ($null -ne $this.Exception) {
                throw $this.Exception
            }
        } -Force
        $validCredentialResult = Test-GuestCredential -VMView $vmViewB -Managers $managerResultB -Credential (New-TestCredential 'VALID\adm')
        Assert-Equal -Actual $validCredentialResult.Status -Expected 'Valid' -Message 'AuthManager validation reports valid credentials'
        Assert-Equal -Actual $authManagerB.Calls[0].MoRef -Expected 'vm-ref-B' -Message 'credential validation uses the target VM reference'
        Assert-Equal -Actual $authManagerB.Calls[0].UserName -Expected 'VALID\adm' -Message 'credential validation passes the supplied username'

        $invalidException = New-Object System.Exception('synthetic invalid login')
        $invalidException.PSTypeNames.Insert(0, 'VMware.Vim.InvalidGuestLogin')
        $authManagerB.Exception = $invalidException
        $invalidCredentialResult = Test-GuestCredential -VMView $vmViewB -Managers $managerResultB -Credential (New-TestCredential 'BAD\adm')
        Assert-Equal -Actual $invalidCredentialResult.Status -Expected 'Invalid' -Message 'InvalidGuestLogin is a recoverable credential result'
        Assert-Equal -Actual $invalidCredentialResult.ErrorKind -Expected 'InvalidGuestLogin' -Message 'InvalidGuestLogin remains distinct from other errors'

        $permissionException = New-Object System.Exception('synthetic operation denial')
        $permissionException.PSTypeNames.Insert(0, 'VMware.Vim.GuestPermissionDenied')
        $authManagerB.Exception = $permissionException
        $permissionCredentialResult = Test-GuestCredential -VMView $vmViewB -Managers $managerResultB -Credential (New-TestCredential 'PERMISSION\adm')
        Assert-Equal -Actual $permissionCredentialResult.Status -Expected 'Error' -Message 'GuestPermissionDenied is not a credential rejection'
        Assert-Equal -Actual $permissionCredentialResult.ErrorKind -Expected 'GuestPermissionDenied' -Message 'operation permission errors remain classified separately'
    }
    finally {
        Set-Item Function:\New-GuestAuthentication -Value $savedGuestAuthentication
    }
}

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
$retryConnections = @((Connect-VIServersWithCredentialMap -VIServers @('vc01.contoso.com', 'vc02.contoso.com') -CredentialMap $retryVIServerCredentialMap -RetryOnFailure -ConnectScript {
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
} 3>$null).Connections)

Assert-Equal -Actual $retryConnections.Count -Expected 2 -Message 'retrying vCenter connection returns both successful connections'
Assert-Equal -Actual $script:connectAttempts['vc01.contoso.com'] -Expected 1 -Message 'successful same-domain vCenter is not retried'
Assert-Equal -Actual $script:connectAttempts['vc02.contoso.com'] -Expected 2 -Message 'failed same-domain vCenter is retried after prompting'
Assert-Equal -Actual $script:retryPromptMessages.Count -Expected 1 -Message 'vCenter retry prompts only for the failed vCenter'
Assert-Contains -Text $script:retryPromptMessages[0] -Needle 'vc02.contoso.com' -Message 'vCenter retry prompt names the failed vCenter'
Assert-Equal -Actual $retryVIServerCredentialMap['vc01.contoso.com'].UserName -Expected 'CONTOSO\vc-admin' -Message 'retry does not replace credential for successful vCenter'
Assert-Equal -Actual $retryVIServerCredentialMap['vc02.contoso.com'].UserName -Expected 'administrator@vsphere.local' -Message 'retry stores replacement credential for failed vCenter'

# The GUI recovery contract: a decision object rather than a bare credential, and a callback
# that fires only for a login this run actually performed. Without the callback the operator
# retypes the corrected password on every run, because nothing ever writes it back.
$script:recoveryCalls = @()
$script:validatedCalls = @()
$recoveryMap = @{ 'vc01.contoso.com' = (New-TestCredential -UserName 'CONTOSO\old-adm'); 'vc02.contoso.com' = (New-TestCredential -UserName 'CONTOSO\old-adm') }
$recoveryResult = Connect-VIServersWithCredentialMap -VIServers @('vc01.contoso.com', 'vc02.contoso.com') -CredentialMap $recoveryMap -RetryOnFailure -ConnectScript {
    param($Server, $Credential)
    if ($Server -eq 'vc02.contoso.com' -and $Credential.UserName -eq 'CONTOSO\old-adm') {
        throw 'domain credential rejected'
    }
    return [pscustomobject]@{ Server = $Server; UserName = $Credential.UserName }
} -CredentialPromptScript {
    param([string]$Message)
    throw 'the old prompt must not be used when a recovery script is supplied'
} -CredentialRecoveryScript {
    param($Server, $Message)
    $script:recoveryCalls += [string]$Server
    return [pscustomobject]@{ Action = 'Retry'; Credential = (New-TestCredential -UserName 'administrator@vsphere.local'); Remember = $true }
} -CredentialValidatedScript {
    param($Server, $Credential, $Remember)
    $script:validatedCalls += [pscustomobject]@{ Server = [string]$Server; UserName = $Credential.UserName; Remember = $Remember }
} 3>$null

Assert-Equal -Actual @($recoveryResult.Connections).Count -Expected 2 -Message 'a recovered vCenter login still returns both connections'
Assert-Equal -Actual (@($script:recoveryCalls) -join ',') -Expected 'vc02.contoso.com' -Message 'only the vCenter that failed reaches the recovery dialog'
Assert-Equal -Actual $recoveryMap['vc02.contoso.com'].UserName -Expected 'administrator@vsphere.local' -Message 'the in-memory map still takes the replacement credential'
Assert-Equal -Actual $recoveryMap['vc01.contoso.com'].UserName -Expected 'CONTOSO\old-adm' -Message 'the vCenter that worked keeps its own credential'
Assert-Equal -Actual @($script:validatedCalls).Count -Expected 2 -Message 'every login this run performed reports its validated credential'
$replacementValidation = @($script:validatedCalls | Where-Object { $_.Server -eq 'vc02.contoso.com' })[0]
Assert-Equal -Actual $replacementValidation.UserName -Expected 'administrator@vsphere.local' -Message 'the replacement is reported against the server that needed it'
Assert-Equal -Actual $replacementValidation.Remember -Expected $true -Message 'an explicit Remember from the recovery dialog is passed through'
$startupValidation = @($script:validatedCalls | Where-Object { $_.Server -eq 'vc01.contoso.com' })[0]
Assert-Equal -Actual ($null -eq $startupValidation.Remember) -Expected $true -Message 'a credential supplied at startup reports no explicit preference, so the caller decides'

# Aborting recovery must not fall through to a retry loop or a second dialog.
$script:abortRecoveryCalls = 0
$abortMap = @{ 'vc03.contoso.com' = (New-TestCredential -UserName 'CONTOSO\old-adm') }
$abortFailed = $false
try {
    Connect-VIServersWithCredentialMap -VIServers @('vc03.contoso.com') -CredentialMap $abortMap -RetryOnFailure -ConnectScript {
        param($Server, $Credential)
        throw 'credential rejected'
    } -CredentialRecoveryScript {
        param($Server, $Message)
        $script:abortRecoveryCalls++
        return [pscustomobject]@{ Action = 'Abort'; Credential = $null; Remember = $false }
    } 3>$null | Out-Null
}
catch {
    $abortFailed = $true
}
Assert-Equal -Actual $abortFailed -Expected $true -Message 'aborting vCenter credential recovery fails the connection instead of looping'
Assert-Equal -Actual $script:abortRecoveryCalls -Expected 1 -Message 'aborting vCenter credential recovery asks exactly once'

# A reused session proves nothing about a password: it was validated by whoever opened it.
$script:reuseValidatedCalls = 0
Connect-VIServersWithCredentialMap -VIServers @('vc1.example.local') `
    -CredentialMap @{ 'vc1.example.local' = (New-TestCredential -UserName 'u1') } `
    -ReuseExisting `
    -GetExistingConnectionsScript { return @([pscustomobject]@{ Name = 'vc1.example.local'; IsConnected = $true }) } `
    -ConnectScript { param($Server, $Credential) throw 'a reused session must not log in again' } `
    -CredentialValidatedScript { param($Server, $Credential, $Remember) $script:reuseValidatedCalls++ } | Out-Null
Assert-Equal -Actual $script:reuseValidatedCalls -Expected 0 -Message 'reusing an existing session never reports a validated credential'

# Reusing a live vCenter session: the run must not log in again, and must not disconnect a
# session it did not open.
$reuseConnectAttempts = New-Object System.Collections.Generic.List[string]
$reuseResult = Connect-VIServersWithCredentialMap -VIServers @('vc1.example.local', 'vc2.example.local') `
    -CredentialMap @{ 'vc1.example.local' = (New-TestCredential -UserName 'u1'); 'vc2.example.local' = (New-TestCredential -UserName 'u2') } `
    -ReuseExisting `
    -GetExistingConnectionsScript { return @([pscustomobject]@{ Name = 'vc1.example.local'; IsConnected = $true }) } `
    -ConnectScript {
        param([string]$Server, [pscredential]$Credential)
        $reuseConnectAttempts.Add($Server)
        return [pscustomobject]@{ Name = $Server; IsConnected = $true }
    }

Assert-Equal -Actual @($reuseResult.Connections).Count -Expected 2 -Message 'reuse returns every requested vCenter connection'
Assert-Equal -Actual $reuseConnectAttempts.Count -Expected 1 -Message 'an already connected vCenter is not logged into again'
Assert-Equal -Actual $reuseConnectAttempts[0] -Expected 'vc2.example.local' -Message 'only the missing vCenter is connected'
Assert-Equal -Actual @($reuseResult.OpenedConnections).Count -Expected 1 -Message 'only self-opened connections are tracked for disconnect'
Assert-Equal -Actual ([string]@($reuseResult.OpenedConnections)[0].Name) -Expected 'vc2.example.local' -Message 'a pre-existing session must not be disconnected by this run'

# A disconnected session in DefaultVIServers is not reusable.
$staleConnectAttempts = New-Object System.Collections.Generic.List[string]
$staleResult = Connect-VIServersWithCredentialMap -VIServers @('vc1.example.local') `
    -CredentialMap @{ 'vc1.example.local' = (New-TestCredential -UserName 'u1') } `
    -ReuseExisting `
    -GetExistingConnectionsScript { return @([pscustomobject]@{ Name = 'vc1.example.local'; IsConnected = $false }) } `
    -ConnectScript {
        param([string]$Server, [pscredential]$Credential)
        $staleConnectAttempts.Add($Server)
        return [pscustomobject]@{ Name = $Server; IsConnected = $true }
    }

Assert-Equal -Actual $staleConnectAttempts.Count -Expected 1 -Message 'a stale session is reconnected rather than reused'
Assert-Equal -Actual @($staleResult.OpenedConnections).Count -Expected 1 -Message 'a reconnected session counts as self-opened'

# The default existing-connection lookup must survive being dot-sourced without PowerCLI:
# reading $global:DefaultVIServers directly throws under StrictMode when it is not set.
$noPowerCliResult = Connect-VIServersWithCredentialMap -VIServers @('vc3.example.local') `
    -CredentialMap @{ 'vc3.example.local' = (New-TestCredential -UserName 'u3') } `
    -ReuseExisting `
    -ConnectScript { param([string]$Server, [pscredential]$Credential) return [pscustomobject]@{ Name = $Server; IsConnected = $true } }
Assert-Equal -Actual @($noPowerCliResult.Connections).Count -Expected 1 -Message 'the default existing-connection lookup works without PowerCLI loaded'

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
Assert-Equal -Actual ((Get-VMLookupCandidates -Name 'vm1.contoso.com') -join '|') -Expected 'vm1.contoso.com|vm1' -Message 'FQDN yields full name before short fallback'
Assert-Equal -Actual ((Get-VMLookupCandidates -Name 'oldbox') -join '|') -Expected 'oldbox' -Message 'bare hostname yields a single candidate'
Assert-Equal -Actual ((Get-VMLookupCandidates -Name 'host.sub.contoso.com') -join '|') -Expected 'host.sub.contoso.com|host' -Message 'multi-level FQDN splits at the first dot only'

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

# --- Credential store keys and expansion (scripts/SettingsStore.ps1) ---
. (Join-Path $repoRoot 'scripts\SettingsStore.ps1')

$guestKeys = @(Get-CredentialStoreKeys -Scope 'guest' -TargetNames @('vm1.contoso.com', 'vm2.contoso.com', 'oldbox'))
Assert-Equal -Actual $guestKeys.Count -Expected 2 -Message 'one domain plus one local machine yield two store keys'
$contosoKey = @($guestKeys | Where-Object { $_.StoreKey -eq 'guest:domain:contoso.com' })
Assert-Equal -Actual $contosoKey.Count -Expected 1 -Message 'domain store key is prefixed with the scope and kind'
Assert-Equal -Actual (@($contosoKey[0].Members) -join ',') -Expected 'vm1.contoso.com,vm2.contoso.com' -Message 'domain store key carries both member VMs'

$vcenterKeys = @(Get-CredentialStoreKeys -Scope 'vcenter' -TargetNames @('vc1.corp.local', 'vc2.corp.local'))
Assert-Equal -Actual $vcenterKeys.Count -Expected 1 -Message 'two vCenters sharing a DNS suffix share one store key'
Assert-Equal -Actual $vcenterKeys[0].StoreKey -Expected 'vcenter:domain:corp.local' -Message 'vCenter scope uses its own prefix with kind'

$store = @{
    'guest:domain:contoso.com' = (New-TestCredential 'CONTOSO\adm')
    'guest:local:oldbox' = (New-TestCredential 'oldbox\adm')
    'vcenter:domain:corp.local' = (New-TestCredential 'CORP\svc')
}

$guestMap = Expand-CredentialStoreMap -Scope 'guest' -TargetNames @('vm1.contoso.com', 'vm2.contoso.com', 'oldbox') -Store $store
Assert-Equal -Actual $guestMap.Count -Expected 3 -Message 'group credentials expand to one entry per VM name'
Assert-Equal -Actual $guestMap['vm1.contoso.com'].UserName -Expected 'CONTOSO\adm' -Message 'domain member gets the domain credential'
Assert-Equal -Actual $guestMap['vm2.contoso.com'].UserName -Expected 'CONTOSO\adm' -Message 'second domain member gets the same credential'
Assert-Equal -Actual $guestMap['oldbox'].UserName -Expected 'oldbox\adm' -Message 'local machine gets its own credential'

$vcenterMap = Expand-CredentialStoreMap -Scope 'vcenter' -TargetNames @('vc1.corp.local', 'vc2.corp.local') -Store $store
Assert-Equal -Actual $vcenterMap.Count -Expected 2 -Message 'one vCenter credential expands to both full names'
Assert-Equal -Actual $vcenterMap['vc2.corp.local'].UserName -Expected 'CORP\svc' -Message 'both vCenters resolve to the shared credential'

$partialMap = Expand-CredentialStoreMap -Scope 'guest' -TargetNames @('vm1.contoso.com', 'vm9.fabrikam.com') -Store $store
Assert-Equal -Actual $partialMap.Count -Expected 1 -Message 'a target with no stored credential is absent from the map, not null-valued'
Assert-Equal -Actual $partialMap.ContainsKey('vm9.fabrikam.com') -Expected $false -Message 'unknown domain contributes no entry'

$missing = @(Get-MissingCredentialStoreKeys -Scope 'guest' -TargetNames @('vm1.contoso.com', 'vm9.fabrikam.com') -Store $store)
Assert-Equal -Actual $missing.Count -Expected 1 -Message 'exactly one store key is missing'
Assert-Equal -Actual $missing[0].StoreKey -Expected 'guest:domain:fabrikam.com' -Message 'the missing key is reported so the GUI can prompt for it'

$collisionKeys = @(Get-CredentialStoreKeys -Scope 'guest' -TargetNames @('oldbox', 'host.oldbox'))
$distinctCollisionKeys = @($collisionKeys | Select-Object -ExpandProperty StoreKey -Unique)
Assert-Equal -Actual $distinctCollisionKeys.Count -Expected 2 -Message 'a local machine and a domain suffix sharing a name stay separate store keys'
$localCollision = @($collisionKeys | Where-Object { $_.Kind -eq 'Local' })
Assert-Equal -Actual $localCollision[0].StoreKey -Expected 'guest:local:oldbox' -Message 'the local group keeps its own namespaced key'
$domainCollision = @($collisionKeys | Where-Object { $_.Kind -eq 'Domain' })
Assert-Equal -Actual $domainCollision[0].StoreKey -Expected 'guest:domain:oldbox' -Message 'the domain group keeps its own namespaced key'

$collisionStore = @{ 'guest:local:oldbox' = (New-TestCredential 'oldbox\localadm') }
$collisionMissing = @(Get-MissingCredentialStoreKeys -Scope 'guest' -TargetNames @('oldbox', 'host.oldbox') -Store $collisionStore)
Assert-Equal -Actual $collisionMissing.Count -Expected 1 -Message 'storing the local password still leaves the domain group missing'
$collisionMap = Expand-CredentialStoreMap -Scope 'guest' -TargetNames @('oldbox', 'host.oldbox') -Store $collisionStore
Assert-Equal -Actual $collisionMap.ContainsKey('host.oldbox') -Expected $false -Message 'the domain member never receives the local machine credential'

Assert-Equal -Actual (@(Get-CredentialStoreKeys -Scope 'guest' -TargetNames @('vm1.contoso.com'))[0].Kind) -Expected 'Domain' -Message 'the group kind is carried through for the GUI to label'

$caseMap = Expand-CredentialStoreMap -Scope 'guest' -TargetNames @('OLDBOX') -Store @{ 'guest:local:oldbox' = (New-TestCredential 'oldbox\adm') }
Assert-Equal -Actual $caseMap.Count -Expected 1 -Message 'store lookup is case-insensitive, so casing typed by the operator does not lose a credential'

$nullStoreMissing = @(Get-MissingCredentialStoreKeys -Scope 'guest' -TargetNames @('vm1.contoso.com') -Store $null)
Assert-Equal -Actual $nullStoreMissing.Count -Expected 1 -Message 'a null store means everything is missing, not a thrown error'
$nullStoreMap = Expand-CredentialStoreMap -Scope 'guest' -TargetNames @('vm1.contoso.com') -Store $null
Assert-Equal -Actual $nullStoreMap.Count -Expected 0 -Message 'a null store expands to an empty map rather than throwing'

# --- One VM's failure never ends the phase (scripts/OrchestratorRuntime.ps1) ---
# There is no job boundary around a guest any more, so a throw anywhere in the fleet would take
# the whole phase with it and the other VMs would never be attempted. This is what the removed
# `catch { }` text rule was reaching for; it asserted the spelling of a catch block rather than
# the behaviour, which a rename would have broken and a comment would have satisfied.
foreach ($failingStage in @('Start', 'Poll', 'Complete')) {
        $isolationItems = @(
            [pscustomobject]@{ Sequence = 1; VMName = 'VM-throws' },
            [pscustomobject]@{ Sequence = 2; VMName = 'VM-works' }
        )

        $isolationResults = @(Invoke-InProcessAgentFleet -Items $isolationItems -MaxInFlight 2 -PollSeconds 1 -ItemTimeoutSeconds 60 -SleepScript { param([int]$Seconds) } -StartScript {
            param($Item)
            if ($Item.VMName -eq 'VM-throws' -and $failingStage -eq 'Start') {
                throw 'synthetic start failure'
            }
            return [pscustomobject]@{ VMName = $Item.VMName; AgentResult = $null }
        } -PollScript {
            param($Handle)
            if ($Handle.VMName -eq 'VM-throws' -and $failingStage -eq 'Poll') {
                throw 'synthetic poll failure'
            }
            return $true
        } -CompleteScript {
            param($Handle)
            if ($Handle.VMName -eq 'VM-throws' -and $failingStage -eq 'Complete') {
                throw 'synthetic completion failure'
            }
            return [pscustomobject]@{ VMName = $Handle.VMName; Collected = $true }
        } 3>$null)

        Assert-Equal -Actual @($isolationResults).Count -Expected 2 -Message ('a {0} failure still returns one result per VM' -f $failingStage)
        $working = @($isolationResults | Where-Object { $_.VMName -eq 'VM-works' })
        Assert-Equal -Actual $working.Count -Expected 1 -Message ('a {0} failure on one guest does not remove the other from the results' -f $failingStage)
        Assert-Equal -Actual ([string]$working[0].Error) -Expected '' -Message ('a {0} failure on one guest leaves the other successful' -f $failingStage)
        Assert-Equal -Actual ([bool]$working[0].Payload.Collected) -Expected $true -Message ('a {0} failure on one guest does not stop the other from being collected' -f $failingStage)
        $throwing = @($isolationResults | Where-Object { $_.VMName -eq 'VM-throws' })
    Assert-Equal -Actual ([string]::IsNullOrWhiteSpace([string]$throwing[0].Error)) -Expected $false -Message ('a {0} failure is reported against the guest that caused it' -f $failingStage)
}

# --- Collection artifacts are always JSON arrays (scripts/OrchestratorRuntime.ps1) ---
# A pipeline into ConvertTo-Json unrolls the collection, so zero records produce no file content
# at all and one record produces a bare object. Anything reading these files back - the resume
# path, an operator's script, a later round - then has to special-case two shapes it cannot see
# coming. These drive the real writers rather than ConvertTo-Json, because the defect is a
# missed production call site, not a misunderstanding of the cmdlet.
function Assert-JsonArrayArtifact {
    param(
        [string]$Path,
        [int]$ExpectedCount,
        [string]$Label
    )

    Assert-Equal -Actual (Test-Path -LiteralPath $Path -PathType Leaf) -Expected $true -Message ('{0}: the artifact is written even for {1} record(s)' -f $Label, $ExpectedCount)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $raw = [string](Get-Content -LiteralPath $Path -Raw)
    Assert-Equal -Actual ($raw.TrimStart().StartsWith('[')) -Expected $true -Message ('{0}: {1} record(s) serialise to a JSON array' -f $Label, $ExpectedCount)
    # Assign before wrapping: ConvertFrom-Json emits the whole array as ONE pipeline object in
    # PowerShell 5.1, so @($raw | ConvertFrom-Json) counts the array itself, not its elements.
    $parsed = $raw | ConvertFrom-Json
    Assert-Equal -Actual @($parsed).Count -Expected $ExpectedCount -Message ('{0}: {1} record(s) read back as that many elements' -f $Label, $ExpectedCount)
}

$artifactDir = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-artifacts-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $artifactDir)
try {
    foreach ($count in @(0, 1, 2)) {
        $caseDir = Join-Path $artifactDir ('reboot-' + $count)
        [void](New-Item -ItemType Directory -Path $caseDir)
        $rebootActions = @(1..2 | Select-Object -First $count | ForEach-Object {
            New-RebootActionRecord -VMName ('VM0{0}' -f $_) -Action 'Initiated' -ProcessId 100 -RebootReason 'Reported after apply' -BatchNumber 1 -Sequence $_ -ValidationStatus 'Confirmed'
        })
        Write-RebootActionArtifacts -CycleOutputDirectory $caseDir -RebootActions $rebootActions
        Assert-JsonArrayArtifact -Path (Join-Path $caseDir 'reboot-actions.json') -ExpectedCount $count -Label 'reboot-actions.json'
    }

    foreach ($count in @(0, 1, 2)) {
        $caseDir = Join-Path $artifactDir ('rounds-' + $count)
        [void](New-Item -ItemType Directory -Path $caseDir)
        $roundSummaries = @(1..2 | Select-Object -First $count | ForEach-Object {
            [pscustomobject]@{ round = $_; targetVMNames = @('VM01'); outputDirectory = $caseDir; applyExitCode = 0; rebootRan = $false }
        })
        Write-PatchRunSummary -RunOutputDirectory $caseDir -RoundSummaries $roundSummaries -FinalStateMap @{}
        Assert-JsonArrayArtifact -Path (Join-Path $caseDir 'rounds.json') -ExpectedCount $count -Label 'rounds.json'
    }
}
finally {
    Remove-Item -LiteralPath $artifactDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Guest directory canonical form (scripts/GuestOpsLib.ps1) ---
# The only destructive operation this tool performs deletes a directory under this path, and the
# check guarding it runs hours into a run where failing is silent. Rejecting a directory the
# cleanup could never validate belongs at the entry point, while the operator is still there.
Assert-Equal -Actual (Test-GuestDirectoryCanonical -Path 'C:\ProgramData\PatchingGuestOps').IsCanonical -Expected $true -Message 'a canonical absolute guest directory is accepted'
Assert-Equal -Actual (Test-GuestDirectoryCanonical -Path 'C:\ProgramData\PatchingGuestOps\').IsCanonical -Expected $true -Message 'a trailing separator does not make a guest directory non-canonical'
Assert-Equal -Actual (Test-GuestDirectoryCanonical -Path 'C:\ProgramData/PatchingGuestOps').IsCanonical -Expected $false -Message 'forward slashes are rejected, because cleanup could never match them'
Assert-Equal -Actual (Test-GuestDirectoryCanonical -Path 'C:\ProgramData/PatchingGuestOps').CanonicalPath -Expected 'C:\ProgramData\PatchingGuestOps' -Message 'a rejected guest directory names the form the operator should write instead'
Assert-Equal -Actual (Test-GuestDirectoryCanonical -Path 'relative\dir').IsCanonical -Expected $false -Message 'a relative guest directory is rejected before it can be resolved against the stepping stone'
Assert-Equal -Actual (Test-GuestDirectoryCanonical -Path 'C:relative').IsCanonical -Expected $false -Message 'a drive-relative guest directory is rejected'
Assert-Equal -Actual (Test-GuestDirectoryCanonical -Path '\\fileserver\share').IsCanonical -Expected $false -Message 'a UNC guest directory is rejected'
Assert-Contains -Text (Test-GuestDirectoryCanonical -Path '\\fileserver\share').Reason -Needle 'UNC' -Message 'a UNC guest directory says so rather than suggesting itself'
Assert-Equal -Actual (Test-GuestDirectoryCanonical -Path 'C:\ProgramData\..\ProgramData\PatchingGuestOps').IsCanonical -Expected $false -Message 'a guest directory carrying .. segments is rejected'
Assert-Equal -Actual (Test-GuestDirectoryCanonical -Path '').IsCanonical -Expected $false -Message 'an empty guest directory is rejected'
# The reason distinguishes the guards, so each one is observable on its own: a relative path is
# refused for not being absolute - before GetFullPath could launder it - and not merely because
# its canonical form differs from what was written.
Assert-Contains -Text (Test-GuestDirectoryCanonical -Path 'relative\dir').Reason -Needle 'absolute' -Message 'a relative guest directory is refused for not being absolute, before canonicalisation'
Assert-Contains -Text (Test-GuestDirectoryCanonical -Path 'C:\ProgramData/PatchingGuestOps').Reason -Needle 'canonical' -Message 'a non-canonical absolute path is refused on canonical form, not absoluteness'
Assert-Contains -Text (Test-GuestDirectoryCanonical -Path '').Reason -Needle 'No guest directory' -Message 'an empty guest directory says it is missing rather than malformed'

# --- Exact-target credential overrides (scripts/SettingsStore.ps1) ---
# Two vCenters behind one DNS suffix share a group entry. When only one of them rejects its
# password, the replacement must land on that server alone - rewriting the group entry would
# hand the other server a credential nobody validated against it.
$targetKey = Get-TargetCredentialStoreKey -Scope 'vcenter' -TargetName ' VC01.EXAMPLE.TEST '
Assert-Equal -Actual $targetKey -Expected 'vcenter:target:vc01.example.test' -Message 'an exact-target key is stable across casing and surrounding whitespace'

$overrideStore = @{
    'vcenter:domain:example.test' = (New-TestCredential 'previous-user')
    'vcenter:target:vc01.example.test' = (New-TestCredential 'replacement-user')
}
$overrideMap = Expand-CredentialStoreMap -Scope 'vcenter' -TargetNames @('vc01.example.test', 'vc02.example.test') -Store $overrideStore
Assert-Equal -Actual $overrideMap['vc01.example.test'].UserName -Expected 'replacement-user' -Message 'the corrected server uses its exact-target override'
Assert-Equal -Actual $overrideMap['vc02.example.test'].UserName -Expected 'previous-user' -Message 'another server behind the same suffix keeps the group credential'

$targetOnlyStore = @{ 'guest:target:vm9.fabrikam.com' = (New-TestCredential ('FABRIKAM\adm')) }
$targetOnlyMissing = @(Get-MissingCredentialStoreKeys -Scope 'guest' -TargetNames @('vm9.fabrikam.com') -Store $targetOnlyStore)
Assert-Equal -Actual $targetOnlyMissing.Count -Expected 0 -Message 'a member covered by an exact-target entry alone is not asked for again'
$partlyCoveredMissing = @(Get-MissingCredentialStoreKeys -Scope 'guest' -TargetNames @('vm8.fabrikam.com', 'vm9.fabrikam.com') -Store $targetOnlyStore)
Assert-Equal -Actual $partlyCoveredMissing.Count -Expected 1 -Message 'a group with an uncovered member is still asked for'
Assert-Equal -Actual (@($partlyCoveredMissing[0].Members) -join ',') -Expected 'vm8.fabrikam.com' -Message 'the prompt covers only the members no entry reaches'

$legacyOnlyMap = Expand-CredentialStoreMap -Scope 'guest' -TargetNames @('vm1.contoso.com') -Store $store
Assert-Equal -Actual $legacyOnlyMap['vm1.contoso.com'].UserName -Expected ('CONTOSO\adm') -Message 'a store written before exact-target keys existed still reads back'

# --- Persisting a corrected credential (scripts/SettingsStore.ps1) ---
# A credential validated mid-run may or may not be meant for disk. The recovery dialog states
# it outright; a credential typed at startup carries only the preference from that form, and
# where there is no preference at all the answer is "do not write a new entry" - never a guess.
Assert-Equal -Actual (Resolve-CredentialPersistDecision -Remember $true -RememberPreference $false) -Expected $true -Message 'an explicit Remember from the recovery dialog wins over the startup preference'
Assert-Equal -Actual (Resolve-CredentialPersistDecision -Remember $false -RememberPreference $true) -Expected $false -Message 'an explicit refusal from the recovery dialog also wins'
Assert-Equal -Actual (Resolve-CredentialPersistDecision -Remember $null -RememberPreference $true) -Expected $true -Message 'no explicit answer falls back to the preference from the startup form'
Assert-Equal -Actual (Resolve-CredentialPersistDecision -Remember $null -RememberPreference $false) -Expected $false -Message 'a startup form that unticked Remember keeps the credential out of the file'
Assert-Equal -Actual (Resolve-CredentialPersistDecision -Remember $null -RememberPreference $null) -Expected $false -Message 'no answer and no preference means no new entry is written'

# The working map and the saved map are separate objects because they genuinely diverge: a
# replacement entered with Remember unticked has to serve the run while the file keeps the
# password already on disk. These drive the real functions - the GUI callbacks are three lines
# of delegation on top of them, and a state object passed by hand cannot reproduce the
# PowerShell 5.1 trap where a function assigning to an enclosing variable silently creates a
# local instead of updating it.
$persistDir = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-persist-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $persistDir)
$persistPath = Join-Path $persistDir 'credentials.json'
try {
    $workingMap = @{ 'guest:domain:contoso.com' = (New-TestCredential 'CONTOSO\old') }
    Write-CredentialStore -Path $persistPath -Credentials $workingMap
    $persistState = New-CredentialPersistState -Path $persistPath -WorkingCredentials $workingMap -PersistedCredentials @{ 'guest:domain:contoso.com' = $workingMap['guest:domain:contoso.com'] }
    Set-CredentialRememberPreference -State $persistState -StoreKey 'guest:domain:contoso.com' -Remember $true

    $savedReplacement = Register-ValidatedCredential -State $persistState -StoreKey 'guest:domain:contoso.com' -Credential (New-TestCredential 'CONTOSO\new') -Remember $true
    Assert-Equal -Actual $savedReplacement -Expected $true -Message 'a validated replacement the operator remembered is written'
    Assert-Equal -Actual (Read-CredentialStore -Path $persistPath).Credentials['guest:domain:contoso.com'].UserName -Expected 'CONTOSO\new' -Message 'the next read of the store returns the corrected password'
    Assert-Equal -Actual $workingMap['guest:domain:contoso.com'].UserName -Expected 'CONTOSO\new' -Message 'the run itself also takes the corrected password'

    $unapproved = Register-ValidatedCredential -State $persistState -StoreKey 'guest:local:sandbox' -Credential (New-TestCredential 'sandbox\adm') -Remember $null
    Assert-Equal -Actual $unapproved -Expected $false -Message 'a credential with no answer and no preference is not written'
    Assert-Equal -Actual $workingMap['guest:local:sandbox'].UserName -Expected 'sandbox\adm' -Message 'a credential that is not written is still available to the run'
    Assert-Equal -Actual (Read-CredentialStore -Path $persistPath).Credentials.ContainsKey('guest:local:sandbox') -Expected $false -Message 'an unapproved credential stays out of the file'

    # An explicit refusal must outrank the startup preference for the rest of the run. This is
    # the whole reason the two maps are separate: the refused password sits in the working map
    # under a key that IS approved, so a single shared map would sweep it onto disk.
    $refused = Register-ValidatedCredential -State $persistState -StoreKey 'guest:domain:contoso.com' -Credential (New-TestCredential 'CONTOSO\refused') -Remember $false
    Assert-Equal -Actual $refused -Expected $false -Message 'a replacement the operator refused to remember is not written'
    Assert-Equal -Actual (Read-CredentialStore -Path $persistPath).Credentials['guest:domain:contoso.com'].UserName -Expected 'CONTOSO\new' -Message 'refusing to remember leaves the file as it was'
    $laterValidation = Register-ValidatedCredential -State $persistState -StoreKey 'guest:domain:contoso.com' -Credential (New-TestCredential 'CONTOSO\refused') -Remember $null
    Assert-Equal -Actual $laterValidation -Expected $false -Message 'a later validation cannot resurrect the startup preference the operator overrode'
    Assert-Equal -Actual (Read-CredentialStore -Path $persistPath).Credentials['guest:domain:contoso.com'].UserName -Expected 'CONTOSO\new' -Message 'the refused password never reaches the file through another VM in the same account'

    Set-CredentialRememberPreference -State $persistState -StoreKey 'vcenter:domain:corp.local' -Remember $true
    $workingMap['vcenter:domain:corp.local'] = (New-TestCredential 'CORP\svc')
    $persistState.Persisted['vcenter:domain:corp.local'] = $workingMap['vcenter:domain:corp.local']
    $savedTarget = Register-ValidatedCredential -State $persistState -StoreKey (Get-TargetCredentialStoreKey -Scope 'vcenter' -TargetName 'vc01.corp.local') -Credential (New-TestCredential 'CORP\vc01') -Remember $true
    Assert-Equal -Actual $savedTarget -Expected $true -Message 'a corrected vCenter password is written'
    $afterTarget = (Read-CredentialStore -Path $persistPath).Credentials
    Assert-Equal -Actual $afterTarget['vcenter:target:vc01.corp.local'].UserName -Expected 'CORP\vc01' -Message 'the correction lands under the exact-target key'
    Assert-Equal -Actual $afterTarget['vcenter:domain:corp.local'].UserName -Expected 'CORP\svc' -Message 'the shared vCenter group entry survives a single-server correction'
    Assert-Equal -Actual $afterTarget['guest:domain:contoso.com'].UserName -Expected 'CONTOSO\new' -Message 'saving one account leaves the others intact'
    Assert-Equal -Actual $afterTarget.ContainsKey('guest:local:sandbox') -Expected $false -Message 'an unapproved account is still absent after later saves'
}
finally {
    Remove-Item -LiteralPath $persistDir -Recurse -Force -ErrorAction SilentlyContinue
}

# An entry this Windows account cannot decrypt belongs to another profile, not to nobody.
$passThroughDir = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-passthrough-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $passThroughDir)
$passThroughPath = Join-Path $passThroughDir 'credentials.json'
try {
    @{
        'guest:domain:contoso.com' = @{ UserName = 'CONTOSO\old'; Password = 'not-a-dpapi-blob' }
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $passThroughPath -Encoding UTF8

    $passThroughRead = Read-CredentialStore -Path $passThroughPath 3>$null
    Assert-Equal -Actual $passThroughRead.Credentials.Count -Expected 0 -Message 'an undecryptable entry is not offered as a usable credential'
    Assert-Equal -Actual $passThroughRead.UnreadableEntries.ContainsKey('guest:domain:contoso.com') -Expected $true -Message 'an undecryptable entry is kept so a later save does not delete it'

    $passThroughState = New-CredentialPersistState -Path $passThroughPath -WorkingCredentials @{} -PersistedCredentials @{} -PassThroughEntries $passThroughRead.UnreadableEntries
    $null = Register-ValidatedCredential -State $passThroughState -StoreKey 'guest:local:sandbox' -Credential (New-TestCredential 'sandbox\adm') -Remember $true
    $afterPassThrough = Get-Content -LiteralPath $passThroughPath -Raw | ConvertFrom-Json
    Assert-Equal -Actual ([string]$afterPassThrough.PSObject.Properties['guest:domain:contoso.com'].Value.Password) -Expected 'not-a-dpapi-blob' -Message 'saving a new account preserves an entry that belongs to another Windows profile'
    Assert-Equal -Actual ([string]$afterPassThrough.PSObject.Properties['guest:local:sandbox'].Value.UserName) -Expected 'sandbox\adm' -Message 'the new account is saved alongside it'
}
finally {
    Remove-Item -LiteralPath $passThroughDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Settings file (scripts/SettingsStore.ps1) ---
$settingsDir = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-settings-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $settingsDir)
$settingsPath = Join-Path $settingsDir 'settings.json'
try {
    $defaults = Read-GuiSettings -Path $settingsPath
    Assert-Equal -Actual $defaults.Warnings.Count -Expected 0 -Message 'a missing settings file is not a warning, it is a first run'
    Assert-Equal -Actual $defaults.Settings.MaxPatchRounds -Expected 3 -Message 'missing settings file yields documented defaults'
    Assert-Equal -Actual $defaults.Settings.TimeoutMinutes -Expected 180 -Message 'the apply budget defaults to the orchestrator value'
    Assert-Equal -Actual $defaults.Settings.DiscoveryTimeoutMinutes -Expected 30 -Message 'the discovery budget defaults to the orchestrator value'
    Assert-Equal -Actual $defaults.Settings.GuestWorkingDirectory -Expected '' -Message 'a blank guest working directory means "use the tool default"'
    Assert-Equal -Actual $defaults.Settings.ShowAdvanced -Expected $false -Message 'the advanced block starts collapsed'
    Assert-Equal -Actual (@($defaults.Settings.VIServers).Count) -Expected 0 -Message 'no vCenters are assumed on a first run'

    Write-GuiSettings -Path $settingsPath -Settings ([pscustomobject]@{
        VIServers = @('vc1.corp.local', 'vc2.corp.local')
        ThrottleLimit = 5
        RebootBatchSize = 2
        MaxPatchRounds = 4
        RebootTimeoutMinutes = 45
        PollSeconds = 20
        LocalOutputDirectory = 'D:\out'
        IgnoreVCenterCertificate = $true
        KeepConnected = $false
    })

    # Deliberately built without the fields added after the first release: a caller from before
    # them is still a valid caller, and under StrictMode the writer reaching for a property it
    # does not carry would lose the whole save rather than one value.
    $legacyWrite = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    Assert-Equal -Actual $legacyWrite.TimeoutMinutes -Expected 180 -Message 'a caller without the newer fields still writes their defaults'
    Assert-Equal -Actual $legacyWrite.ShowAdvanced -Expected $false -Message 'a caller without ShowAdvanced writes it as collapsed'

    # Assert this while the file still holds what Write-GuiSettings produced. The
    # out-of-range case below overwrites it by hand, and asserting there would check the
    # test's own JSON rather than the writer's.
    $writtenText = Get-Content -LiteralPath $settingsPath -Raw
    Assert-NotContains -Text $writtenText -Needle 'SkipStaticChecks' -Message 'SkipStaticChecks is never persisted'
    Assert-NotContains -Text $writtenText -Needle 'VMNames' -Message 'the VM list is never persisted'
    # A resume path and a dry run are decisions about one run. Persisting either would arm it
    # again on the next launch, which is the one thing an operator would not be looking for.
    Assert-NotContains -Text $writtenText -Needle 'PatchPlanPath' -Message 'a resume plan path is never persisted'
    Assert-NotContains -Text $writtenText -Needle 'PlanOnly' -Message 'PlanOnly is never persisted'
    Assert-NotContains -Text $writtenText -Needle 'SearchOnly' -Message 'SearchOnly is never persisted'

    $loaded = Read-GuiSettings -Path $settingsPath
    Assert-Equal -Actual (@($loaded.Settings.VIServers) -join ';') -Expected 'vc1.corp.local;vc2.corp.local' -Message 'vCenter list round-trips'
    Assert-Equal -Actual $loaded.Settings.ThrottleLimit -Expected 5 -Message 'numeric settings round-trip'
    Assert-Equal -Actual $loaded.Settings.IgnoreVCenterCertificate -Expected $true -Message 'switch settings round-trip'
    Assert-Equal -Actual $loaded.Settings.RebootBatchSize -Expected 2 -Message 'RebootBatchSize round-trips'
    Assert-Equal -Actual $loaded.Settings.MaxPatchRounds -Expected 4 -Message 'MaxPatchRounds round-trips'
    Assert-Equal -Actual $loaded.Settings.RebootTimeoutMinutes -Expected 45 -Message 'RebootTimeoutMinutes round-trips'
    Assert-Equal -Actual $loaded.Settings.PollSeconds -Expected 20 -Message 'PollSeconds round-trips'

    Write-GuiSettings -Path $settingsPath -Settings ([pscustomobject]@{
        VIServers = @('vc1.corp.local')
        ThrottleLimit = $null
        RebootBatchSize = $null
        MaxPatchRounds = 3
        TimeoutMinutes = 240
        DiscoveryTimeoutMinutes = 45
        RebootTimeoutMinutes = 20
        PollSeconds = 15
        GuestWorkingDirectory = 'D:\tools\PatchingGuestOps'
        ShowAdvanced = $true
        LocalOutputDirectory = 'D:\out'
        IgnoreVCenterCertificate = $false
        IgnoreESXiCertificate = $false
        KeepConnected = $false
    })
    $advanced = Read-GuiSettings -Path $settingsPath
    Assert-Equal -Actual $advanced.Settings.TimeoutMinutes -Expected 240 -Message 'the apply budget round-trips'
    Assert-Equal -Actual $advanced.Settings.DiscoveryTimeoutMinutes -Expected 45 -Message 'the discovery budget round-trips'
    Assert-Equal -Actual $advanced.Settings.GuestWorkingDirectory -Expected 'D:\tools\PatchingGuestOps' -Message 'the guest working directory round-trips'
    Assert-Equal -Actual $advanced.Settings.ShowAdvanced -Expected $true -Message 'the advanced block stays open across launches'
    Assert-Equal -Actual $advanced.Warnings.Count -Expected 0 -Message 'the advanced fields produce no warnings when valid'

    Set-Content -LiteralPath $settingsPath -Value '{ "TimeoutMinutes": 0, "DiscoveryTimeoutMinutes": "soon" }' -Encoding UTF8
    $badBudgets = Read-GuiSettings -Path $settingsPath
    Assert-Equal -Actual $badBudgets.Settings.TimeoutMinutes -Expected 180 -Message 'a below-range apply budget falls back to its default'
    Assert-Equal -Actual $badBudgets.Settings.DiscoveryTimeoutMinutes -Expected 30 -Message 'an unparsable discovery budget falls back to its default'
    Assert-Equal -Actual ($badBudgets.Warnings.Count -ge 2) -Expected $true -Message 'each invalid budget warns rather than being silently replaced'

    Write-GuiSettings -Path $settingsPath -Settings ([pscustomobject]@{
        VIServers = @('vc1.corp.local')
        ThrottleLimit = 5
        RebootBatchSize = 2
        MaxPatchRounds = 4
        RebootTimeoutMinutes = 45
        PollSeconds = 20
        LocalOutputDirectory = 'D:\out'
        IgnoreVCenterCertificate = $true
        KeepConnected = $false
    })
    $loaded = Read-GuiSettings -Path $settingsPath
    Assert-Equal -Actual $loaded.Settings.LocalOutputDirectory -Expected 'D:\out' -Message 'the output directory round-trips'
    Assert-Equal -Actual $loaded.Settings.KeepConnected -Expected $false -Message 'KeepConnected round-trips independently of IgnoreVCenterCertificate'
    Assert-Equal -Actual $loaded.Warnings.Count -Expected 0 -Message 'a clean file produces no warnings'

    Set-Content -LiteralPath $settingsPath -Value '{ "PollSeconds": 15 }' -Encoding UTF8
    $noServers = Read-GuiSettings -Path $settingsPath
    Assert-Equal -Actual (@($noServers.Settings.VIServers).Count) -Expected 0 -Message 'an absent vCenter list reads back as empty, not as one blank entry'

    Set-Content -LiteralPath $settingsPath -Value '{ this is not json' -Encoding UTF8
    $corrupt = Read-GuiSettings -Path $settingsPath
    Assert-Equal -Actual $corrupt.Settings.MaxPatchRounds -Expected 3 -Message 'a corrupt settings file degrades to defaults instead of throwing'
    Assert-Equal -Actual ($corrupt.Warnings.Count -ge 1) -Expected $true -Message 'a corrupt settings file warns'

    Set-Content -LiteralPath $settingsPath -Value '{ "ThrottleLimit": 0, "MaxPatchRounds": -2, "PollSeconds": 15 }' -Encoding UTF8
    $outOfRange = Read-GuiSettings -Path $settingsPath
    Assert-Equal -Actual $outOfRange.Settings.ThrottleLimit -Expected $null -Message 'a below-range ThrottleLimit falls back to "not supplied"'
    Assert-Equal -Actual $outOfRange.Settings.MaxPatchRounds -Expected 3 -Message 'a below-range MaxPatchRounds falls back to its default'
    Assert-Equal -Actual $outOfRange.Settings.PollSeconds -Expected 15 -Message 'an in-range value survives alongside invalid neighbours'
    Assert-Equal -Actual ($outOfRange.Warnings.Count -ge 2) -Expected $true -Message 'each out-of-range value warns so the form can show it'
}
finally {
    Remove-Item -LiteralPath $settingsDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Credential file (scripts/SettingsStore.ps1) ---
$credDir = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-creds-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $credDir)
$credPath = Join-Path $credDir 'credentials.json'
try {
    $emptyStore = Read-CredentialStore -Path $credPath
    Assert-Equal -Actual $emptyStore.Credentials.Count -Expected 0 -Message 'a missing credential file yields an empty store'
    Assert-Equal -Actual $emptyStore.Warnings.Count -Expected 0 -Message 'a missing credential file is not a warning'

    # A canary, not New-TestCredential's fixed 'password': the JSON carries a property
    # NAMED "Password", and Assert-NotContains is case-insensitive, so needling 'password'
    # would fail on the property name and never test what it claims to test.
    $canaryPassword = 'Hunter2-PlainTextCanary'
    $canaryCredential = New-Object System.Management.Automation.PSCredential(
        'CORP\svc',
        (ConvertTo-SecureString $canaryPassword -AsPlainText -Force)
    )

    Write-CredentialStore -Path $credPath -Credentials @{
        'vcenter:domain:corp.local' = $canaryCredential
        'guest:domain:contoso.com' = (New-TestCredential 'CONTOSO\adm')
    }

    $fileText = Get-Content -LiteralPath $credPath -Raw
    Assert-NotContains -Text $fileText -Needle $canaryPassword -Message 'the plaintext password never reaches the file'
    Assert-Contains -Text $fileText -Needle 'CORP\\svc' -Message 'the username is stored in cleartext, by accepted design'

    $roundTrip = Read-CredentialStore -Path $credPath
    Assert-Equal -Actual $roundTrip.Credentials.Count -Expected 2 -Message 'both credentials round-trip'
    Assert-Equal -Actual $roundTrip.Credentials['vcenter:domain:corp.local'].UserName -Expected 'CORP\svc' -Message 'username survives the round-trip'
    Assert-Equal -Actual $roundTrip.Credentials['vcenter:domain:corp.local'].GetNetworkCredential().Password -Expected $canaryPassword -Message 'password survives the round-trip'
    Assert-Equal -Actual $roundTrip.Credentials.ContainsKey('VCENTER:DOMAIN:CORP.LOCAL') -Expected $true -Message 'the rebuilt store stays case-insensitive, so a differently-cased key still resolves'

    $damaged = (Get-Content -LiteralPath $credPath -Raw) -replace '("guest:domain:contoso\.com"\s*:\s*\{[^}]*"Password"\s*:\s*")[^"]+', '$1deadbeef'
    Set-Content -LiteralPath $credPath -Value $damaged -Encoding UTF8
    $partial = Read-CredentialStore -Path $credPath
    Assert-Equal -Actual $partial.Credentials.ContainsKey('vcenter:domain:corp.local') -Expected $true -Message 'an undecryptable entry does not destroy its neighbours'
    Assert-Equal -Actual $partial.Credentials.ContainsKey('guest:domain:contoso.com') -Expected $false -Message 'the undecryptable entry is dropped, not returned broken'
    Assert-Equal -Actual ($partial.Warnings.Count -ge 1) -Expected $true -Message 'an undecryptable entry warns so the GUI can re-prompt for that key'

    Set-Content -LiteralPath $credPath -Value 'not json at all' -Encoding UTF8
    $broken = Read-CredentialStore -Path $credPath
    Assert-Equal -Actual $broken.Credentials.Count -Expected 0 -Message 'a corrupt credential file degrades to an empty store'
    Assert-Equal -Actual ($broken.Warnings.Count -ge 1) -Expected $true -Message 'a corrupt credential file warns'
}
finally {
    Remove-Item -LiteralPath $credDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Checkbox state to identity keys (scripts/SettingsStore.ps1) ---
$sampleGroups = @(
    [pscustomobject]@{ identityKey = 'aaaaaaaa-0000-0000-0000-000000000001|100'; title = 'Cumulative Update'; selectedByDefault = $true },
    [pscustomobject]@{ identityKey = 'bbbbbbbb-0000-0000-0000-000000000002|200'; title = 'Driver'; selectedByDefault = $false },
    [pscustomobject]@{ identityKey = 'cccccccc-0000-0000-0000-000000000003|300'; title = 'Security Update'; selectedByDefault = $true }
)

$defaultIndexes = @(Get-DefaultCheckedIndexes -UpdateGroups $sampleGroups)
Assert-Equal -Actual ($defaultIndexes -join ',') -Expected '0,2' -Message 'the dialog opens pre-ticked on the default policy'

$allKeys = @(Get-SelectedIdentityKeys -UpdateGroups $sampleGroups -CheckedIndexes @(0, 2))
Assert-Equal -Actual ($allKeys -join ';') -Expected 'aaaaaaaa-0000-0000-0000-000000000001|100;cccccccc-0000-0000-0000-000000000003|300' -Message 'checked indexes map to identity keys in group order'

$reorderedKeys = @(Get-SelectedIdentityKeys -UpdateGroups $sampleGroups -CheckedIndexes @(2, 0))
Assert-Equal -Actual ($reorderedKeys -join ';') -Expected 'aaaaaaaa-0000-0000-0000-000000000001|100;cccccccc-0000-0000-0000-000000000003|300' -Message 'group order wins over the order the control reports checks in'

$noneKeys = @(Get-SelectedIdentityKeys -UpdateGroups $sampleGroups -CheckedIndexes @())
Assert-Equal -Actual $noneKeys.Count -Expected 0 -Message 'unticking everything is a legal, empty selection'

$outOfRangeKeys = @(Get-SelectedIdentityKeys -UpdateGroups $sampleGroups -CheckedIndexes @(0, 99))
Assert-Equal -Actual ($outOfRangeKeys -join ';') -Expected 'aaaaaaaa-0000-0000-0000-000000000001|100' -Message 'an index the control should never emit is ignored rather than throwing'


# --- Operator prompt dispatch (scripts/Invoke-GuestOpsPatchValidation.ps1, AST-extracted) ---
# The function lives in a script with top-level flow, so extract it through the AST, the
# same way Resolve-VMTargetNames is pulled out of the launcher above.
$orchestratorPath = Join-Path $repoRoot 'scripts\Invoke-GuestOpsPatchValidation.ps1'
$orchestratorTokens = $null
$orchestratorErrors = $null
$orchestratorAst = [System.Management.Automation.Language.Parser]::ParseFile($orchestratorPath, [ref]$orchestratorTokens, [ref]$orchestratorErrors)
$orchestratorFunctions = @($orchestratorAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
$promptDefinition = @($orchestratorFunctions | Where-Object { $_.Name -eq 'Invoke-OperatorPrompt' })
if ($promptDefinition.Count -eq 0) {
    Add-Failure -Message 'Orchestrator function not found: Invoke-OperatorPrompt'
}
else {
    . ([scriptblock]::Create($promptDefinition[0].Extent.Text))

    $noProvider = Invoke-OperatorPrompt -Provider $null -Key 'SelectUpdateGroups' -Arguments @{} -FallbackScript { 'console' }
    Assert-Equal -Actual $noProvider -Expected 'console' -Message 'an unbound provider falls back to the console path'

    $emptyProvider = Invoke-OperatorPrompt -Provider @{} -Key 'SelectUpdateGroups' -Arguments @{} -FallbackScript { 'console' }
    Assert-Equal -Actual $emptyProvider -Expected 'console' -Message 'a provider without the key falls back rather than throwing'

    $script:seenMarker = $null
    $withProvider = Invoke-OperatorPrompt -Provider @{ SelectUpdateGroups = { param($a) $script:seenMarker = $a.Marker; 'gui' } } -Key 'SelectUpdateGroups' -Arguments @{ Marker = 'passed' } -FallbackScript { 'console' }
    Assert-Equal -Actual $withProvider -Expected 'gui' -Message 'a matching provider key answers the prompt'
    Assert-Equal -Actual $script:seenMarker -Expected 'passed' -Message 'the provider scriptblock receives the arguments hashtable'

    $otherKey = Invoke-OperatorPrompt -Provider @{ SomethingElse = { 'gui' } } -Key 'SelectUpdateGroups' -Arguments @{} -FallbackScript { 'console' }
    Assert-Equal -Actual $otherKey -Expected 'console' -Message 'a provider carrying a different key does not answer this prompt'
}

# --- Continue/finish decision (scripts/Invoke-GuestOpsPatchValidation.ps1, AST-extracted) ---
# Under the GUI this verdict is whatever a window returned, so only an explicit CONTINUE may
# start another round. Passing anything else on as it stands is worse than stopping: an empty
# decision reads to Get-PatchRoundDecision as "nobody has answered yet", and the run would end
# on a reason describing nothing the operator did.
$continueDefinition = @($orchestratorFunctions | Where-Object { $_.Name -eq 'Read-ContinuePatchingDecision' })
if ($continueDefinition.Count -eq 0) {
    Add-Failure -Message 'Orchestrator function not found: Read-ContinuePatchingDecision'
}
else {
    . ([scriptblock]::Create($continueDefinition[0].Extent.Text))

    $continueStates = @(
        [pscustomobject]@{ vmName = 'VM01'; state = 'Pending'; reason = '2 selectable update group(s) still apply.' },
        [pscustomobject]@{ vmName = 'VM02'; state = 'Green'; reason = 'No selectable updates remain.' }
    )

    $script:continuePromptArgs = $null
    $continueAnswer = Read-ContinuePatchingDecision -CompletionStates $continueStates -Round 2 -PromptProvider @{
        ContinuePatching = { param($promptArgs) $script:continuePromptArgs = $promptArgs; 'CONTINUE' }
    }
    Assert-Equal -Actual $continueAnswer -Expected 'CONTINUE' -Message 'the provider answer drives the round decision'
    Assert-Equal -Actual (@($script:continuePromptArgs.PendingStates).Count) -Expected 1 -Message 'only pending VMs are offered as the next round targets'
    Assert-Equal -Actual ([string](@($script:continuePromptArgs.PendingStates)[0].vmName)) -Expected 'VM01' -Message 'the pending VM travels to the prompt'
    Assert-Equal -Actual ([int]$script:continuePromptArgs.Round) -Expected 2 -Message 'the round number travels to the prompt'

    foreach ($rawAnswer in @('CONTINUE', ' continue ', 'FINISH', 'finish', '', 'Cancel')) {
        $normalized = Read-ContinuePatchingDecision -CompletionStates $continueStates -Round 2 -PromptProvider @{ ContinuePatching = { param($promptArgs) $rawAnswer } }
        $expected = if ($rawAnswer.Trim().ToUpperInvariant() -eq 'CONTINUE') { 'CONTINUE' } else { 'FINISH' }
        Assert-Equal -Actual $normalized -Expected $expected -Message ('a provider answer of "{0}" resolves to {1}' -f $rawAnswer, $expected)
    }
}

# --- Patch plan approval (scripts/Invoke-GuestOpsPatchValidation.ps1, AST-extracted) ---
# This is the approval that starts installing. Two properties are load-bearing:
# -SkipConfirmation is settled before the provider is consulted, so a non-interactive run
# never opens a window nobody is there to answer; and the provider's verdict is cast to
# [bool], so a dialog that returned its wrapper instead of a verdict cannot read as approval.
$confirmPlanDefinition = @($orchestratorFunctions | Where-Object { $_.Name -eq 'Confirm-PatchPlan' })
if ($confirmPlanDefinition.Count -eq 0) {
    Add-Failure -Message 'Orchestrator function not found: Confirm-PatchPlan'
}
else {
    . ([scriptblock]::Create($confirmPlanDefinition[0].Extent.Text))

    $confirmPlanRecords = @(
        [pscustomobject]@{ vmName = 'VM01'; action = 'Install'; selectedUpdates = @([pscustomobject]@{ kbText = 'KB5000001'; title = 'Update A' }) }
    )

    $script:planPromptCalls = 0
    $script:planPromptArgs = $null
    $refusingPlanProvider = @{ ConfirmPatchPlan = { param($promptArgs) $script:planPromptCalls++; $script:planPromptArgs = $promptArgs; $false } }

    $planSkipped = Confirm-PatchPlan -PatchPlanRecords $confirmPlanRecords -PromptProvider $refusingPlanProvider -SkipConfirmation
    Assert-Equal -Actual $planSkipped -Expected $true -Message '-SkipConfirmation approves the plan without asking'
    Assert-Equal -Actual $script:planPromptCalls -Expected 0 -Message '-SkipConfirmation never opens the approval window'

    $planRefused = Confirm-PatchPlan -PatchPlanRecords $confirmPlanRecords -PromptProvider $refusingPlanProvider
    Assert-Equal -Actual $planRefused -Expected $false -Message 'a refused plan is not applied'
    Assert-Equal -Actual $script:planPromptCalls -Expected 1 -Message 'an interactive run asks exactly once'
    Assert-Equal -Actual ([string](@($script:planPromptArgs.PatchPlanRecords)[0].vmName)) -Expected 'VM01' -Message 'the plan records travel to the prompt'

    $planApproved = Confirm-PatchPlan -PatchPlanRecords $confirmPlanRecords -PromptProvider @{ ConfirmPatchPlan = { param($promptArgs) $true } }
    Assert-Equal -Actual $planApproved -Expected $true -Message 'an approved plan applies'
}

# --- Reboot checkpoint (scripts/Invoke-GuestOpsPatchValidation.ps1, AST-extracted) ---
# The restart is the other prompt -SkipConfirmation must never answer, and the one whose
# default has to be "leave them running". An empty target list settles itself without asking.
# This gate deliberately does not load PatchPlanModel.ps1 - what the listing looks like is the
# model gate's question, and this one is about which surface gets asked. Confirm-GuestReboot
# prints through the model helper, so it needs one to exist.
function Get-RebootTargetDisplayLines { param($RebootTargets) return @('- stub') }

$confirmRebootDefinition = @($orchestratorFunctions | Where-Object { $_.Name -eq 'Confirm-GuestReboot' })
if ($confirmRebootDefinition.Count -eq 0) {
    Add-Failure -Message 'Orchestrator function not found: Confirm-GuestReboot'
}
else {
    . ([scriptblock]::Create($confirmRebootDefinition[0].Extent.Text))

    $rebootTargetRecords = @(
        [pscustomobject]@{ vmName = 'VM01'; rebootReason = 'installResult.rebootRequired' }
    )

    $script:rebootPromptCalls = 0
    $script:rebootPromptArgs = $null
    $rebootProvider = @{ ConfirmGuestReboot = { param($promptArgs) $script:rebootPromptCalls++; $script:rebootPromptArgs = $promptArgs; $false } }

    Assert-Equal -Actual (Confirm-GuestReboot -RebootTargets @() -PromptProvider $rebootProvider) -Expected $false -Message 'no reboot targets means no reboot'
    Assert-Equal -Actual $script:rebootPromptCalls -Expected 0 -Message 'an empty target list never asks the operator'

    Assert-Equal -Actual (Confirm-GuestReboot -RebootTargets $rebootTargetRecords -PromptProvider $rebootProvider) -Expected $false -Message 'a declined checkpoint leaves the VM(s) running'
    Assert-Equal -Actual $script:rebootPromptCalls -Expected 1 -Message 'the checkpoint asks exactly once'
    Assert-Equal -Actual ([string](@($script:rebootPromptArgs.RebootTargets)[0].vmName)) -Expected 'VM01' -Message 'the reboot targets travel to the prompt'

    Assert-Equal -Actual (Confirm-GuestReboot -RebootTargets $rebootTargetRecords -PromptProvider @{ ConfirmGuestReboot = { param($promptArgs) $true } }) -Expected $true -Message 'an approved checkpoint reboots'
}

# The batch size is blast radius, so an unusable answer must fail towards one VM at a time.
# The console loop cannot return below 1; a window can be closed, and 0 read as one batch
# would restart the whole fleet at once.
$batchSizeDefinition = @($orchestratorFunctions | Where-Object { $_.Name -eq 'Read-RebootBatchSize' })
if ($batchSizeDefinition.Count -eq 0) {
    Add-Failure -Message 'Orchestrator function not found: Read-RebootBatchSize'
}
else {
    . ([scriptblock]::Create($batchSizeDefinition[0].Extent.Text))

    $script:batchPromptArgs = $null
    $answeredBatch = Read-RebootBatchSize -TargetCount 21 -PromptProvider @{ RebootBatchSize = { param($promptArgs) $script:batchPromptArgs = $promptArgs; 4 } }
    Assert-Equal -Actual $answeredBatch -Expected 4 -Message 'the provider answer becomes the batch size'
    Assert-Equal -Actual ([int]$script:batchPromptArgs.TargetCount) -Expected 21 -Message 'the target count travels to the prompt'

    foreach ($unusable in @(0, -3)) {
        $clamped = Read-RebootBatchSize -TargetCount 21 -PromptProvider @{ RebootBatchSize = { param($promptArgs) $unusable } }
        Assert-Equal -Actual $clamped -Expected 1 -Message ('a batch size of {0} falls back to one VM at a time' -f $unusable)
    }
}

# Write-FinalReport counts six groups of VMs, and the reboot group is the one that can legally
# be empty. An if-expression assigns its branch's pipeline output and an empty collection emits
# nothing, so @() inside a branch assigned $null and the count threw under StrictMode. That state
# was unreachable while a stale PendingFileRenameOperations kept every guest on the reboot list;
# it is the normal case now, so it gets a test.
$finalReportDefinition = @($orchestratorFunctions | Where-Object { $_.Name -eq 'Write-FinalReport' })
if ($finalReportDefinition.Count -eq 0) {
    Add-Failure -Message 'Orchestrator function not found: Write-FinalReport'
}
else {
    $finalReportDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('final-report-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $finalReportDirectory | Out-Null
    try {
        # ConvertTo-PatchSummaryRows belongs to the offline model and has its own gate; stubbing
        # it inside this scope keeps the dependency out of the runtime checks and never shadows
        # anything for the rest of this file.
        $finalReportProbe = [scriptblock]::Create(@'
param($PlanRecords, $ApplyResults, [string]$OutputDirectory, $RebootTargets)

function ConvertTo-PatchSummaryRows {
    param($PatchPlanRecords)
    return @(@($PatchPlanRecords) | ForEach-Object { [pscustomobject]@{ VMName = $_.vmName; Action = $_.action } })
}

'@ + $finalReportDefinition[0].Extent.Text + [Environment]::NewLine + 'Write-FinalReport -PatchPlanRecords $PlanRecords -ApplyResults $ApplyResults -CycleOutputDirectory $OutputDirectory -RebootTargets $RebootTargets')

        $quietPlanRecords = @([pscustomobject]@{ vmName = 'VM01'; action = 'NoSelectedUpdates'; reason = 'No selected updates apply.' })
        $quietApplyResults = @([pscustomobject]@{ vmName = 'VM01'; action = 'NoSelectedUpdates'; outcome = 'Skipped'; installResult = $null; reason = 'No selected updates apply.'; rebootRequired = $false; errors = @() })

        $emptyRebootThrew = $false
        try { & $finalReportProbe $quietPlanRecords $quietApplyResults $finalReportDirectory @() 6>$null | Out-Null }
        catch { $emptyRebootThrew = $true; Add-Failure -Message ('Write-FinalReport threw on an empty reboot target list: {0}' -f $_.Exception.Message) }
        Assert-Equal -Actual $emptyRebootThrew -Expected $false -Message 'a fleet with no reboot targets still produces a final report'

        $emptySummaryText = Get-Content -LiteralPath (Join-Path $finalReportDirectory 'summary.md') -Raw
        Assert-Contains -Text $emptySummaryText -Needle '- VMs requiring reboot: 0' -Message 'an empty reboot target list is counted as zero, not skipped'

        # $null means "work it out from the apply results" and must survive the same way.
        $nullRebootThrew = $false
        try { & $finalReportProbe $quietPlanRecords $quietApplyResults $finalReportDirectory $null 6>$null | Out-Null }
        catch { $nullRebootThrew = $true; Add-Failure -Message ('Write-FinalReport threw when deriving reboot targets: {0}' -f $_.Exception.Message) }
        Assert-Equal -Actual $nullRebootThrew -Expected $false -Message 'deriving reboot targets from apply results survives an empty result'

        # A populated list must still be counted and listed.
        & $finalReportProbe $quietPlanRecords $quietApplyResults $finalReportDirectory @([pscustomobject]@{ vmName = 'VM01'; rebootRequired = $true; rebootReason = 'Reported after apply' }) 6>$null | Out-Null
        $populatedSummaryText = Get-Content -LiteralPath (Join-Path $finalReportDirectory 'summary.md') -Raw
        Assert-Contains -Text $populatedSummaryText -Needle '- VMs requiring reboot: 1' -Message 'a populated reboot target list is still counted'
        Assert-Contains -Text $populatedSummaryText -Needle 'VM01 (Reported after apply)' -Message 'a populated reboot target list is still listed with its reason'
    }
    finally {
        Remove-Item -LiteralPath $finalReportDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$selectionResultDefinition = @($orchestratorFunctions | Where-Object { $_.Name -eq 'New-UpdateSelectionResult' })
if ($selectionResultDefinition.Count -eq 0) {
    Add-Failure -Message 'Orchestrator function not found: New-UpdateSelectionResult'
}
else {
    . ([scriptblock]::Create($selectionResultDefinition[0].Extent.Text))

    $emptySelection = New-UpdateSelectionResult -Keys @()
    Assert-Equal -Actual $emptySelection.Aborted -Expected $false -Message 'an empty selection is a selection, not an abort'
    Assert-Equal -Actual (@($emptySelection.Keys).Count) -Expected 0 -Message 'an empty selection carries no keys'

    $twoKeySelection = New-UpdateSelectionResult -Keys @('a|1', 'b|2')
    Assert-Equal -Actual (@($twoKeySelection.Keys) -join ';') -Expected 'a|1;b|2' -Message 'selected keys survive the result object in order'

    $abort = New-UpdateSelectionResult -Aborted
    Assert-Equal -Actual $abort.Aborted -Expected $true -Message 'abort is representable and distinct from an empty selection'
    Assert-Equal -Actual (@($abort.Keys).Count) -Expected 0 -Message 'an aborted result carries no keys'
}

# --- Update group selection end to end (AST-extracted, Read-Host stubbed) ---
# The restructured function is otherwise uncovered: a static needle pins only its name.
# Mutants that flipped the result to Aborted, or misspelled the dispatch key so the GUI
# provider never fired, both passed every gate. The second is the dangerous one - the
# console fallback then reads '' from a closed stdin as "accept".
$selectionDefinition = @($orchestratorFunctions | Where-Object { $_.Name -eq 'Read-UpdateGroupSelection' })
if ($selectionDefinition.Count -eq 0) {
    Add-Failure -Message 'Orchestrator function not found: Read-UpdateGroupSelection'
}
else {
    . ([scriptblock]::Create($selectionDefinition[0].Extent.Text))

    $script:stubbedReadHostCalls = 0
    function Read-Host { param([string]$Prompt) $script:stubbedReadHostCalls++; return '' }
    function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$Ignored) }

    $selectionGroups = @(
        [pscustomobject]@{ identityKey = 'aaa|1'; title = 'Cumulative'; selectedByDefault = $true },
        [pscustomobject]@{ identityKey = 'bbb|2'; title = 'Driver'; selectedByDefault = $false }
    )

    $consoleSelection = Read-UpdateGroupSelection -UpdateGroups $selectionGroups
    Assert-Equal -Actual $consoleSelection.Aborted -Expected $false -Message 'accepting at the console prompt is a selection, not an abort'
    Assert-Equal -Actual (@($consoleSelection.Keys) -join ';') -Expected 'aaa|1' -Message 'the console fallback returns the default-policy selection'
    Assert-Equal -Actual ($script:stubbedReadHostCalls -ge 1) -Expected $true -Message 'the console fallback actually reaches its prompt'

    $script:stubbedReadHostCalls = 0
    $providerAbort = Read-UpdateGroupSelection -UpdateGroups $selectionGroups -PromptProvider @{ SelectUpdateGroups = { param($promptArgs) New-UpdateSelectionResult -Aborted } }
    Assert-Equal -Actual $providerAbort.Aborted -Expected $true -Message 'a provider abort reaches the caller unchanged'
    Assert-Equal -Actual $script:stubbedReadHostCalls -Expected 0 -Message 'a matching provider key means the console prompt never runs'

    $script:stubbedReadHostCalls = 0
    $providerPick = Read-UpdateGroupSelection -UpdateGroups $selectionGroups -PromptProvider @{ SelectUpdateGroups = { param($promptArgs) New-UpdateSelectionResult -Keys @(@($promptArgs.UpdateGroups)[1].identityKey) } }
    Assert-Equal -Actual (@($providerPick.Keys) -join ';') -Expected 'bbb|2' -Message 'the provider receives the groups and its own selection is returned'
    Assert-Equal -Actual $script:stubbedReadHostCalls -Expected 0 -Message 'the provider path never falls through to the console'

    Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
    Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
}

# --- Guest credential prompt seam (scripts/Invoke-GuestOpsPatchValidation.ps1, AST-extracted) ---
$guestMapDefinition = @($orchestratorFunctions | Where-Object { $_.Name -eq 'Resolve-GuestCredentialMap' })
if ($guestMapDefinition.Count -eq 0) {
    Add-Failure -Message 'Orchestrator function not found: Resolve-GuestCredentialMap'
}
else {
    . ([scriptblock]::Create($guestMapDefinition[0].Extent.Text))

    $script:guestPromptMessages = @()
    $fakeGuestPrompt = { param([string]$Message) $script:guestPromptMessages += $Message; New-TestCredential 'PROMPTED\adm' }

    $promptedMap = Resolve-GuestCredentialMap -TargetNames @('vm1.contoso.com', 'vm2.contoso.com', 'oldbox') -CredentialPromptScript $fakeGuestPrompt
    Assert-Equal -Actual $promptedMap.Count -Expected 3 -Message 'the injected prompt fills every target name'
    Assert-Equal -Actual $script:guestPromptMessages.Count -Expected 2 -Message 'one prompt per credential group, not per VM'
    Assert-Equal -Actual $promptedMap['vm2.contoso.com'].UserName -Expected 'PROMPTED\adm' -Message 'both domain members share the prompted credential'
    Assert-Equal -Actual $promptedMap['oldbox'].UserName -Expected 'PROMPTED\adm' -Message 'the standalone machine gets its own prompt result'

    $overrideMap = Resolve-GuestCredentialMap -TargetNames @('vm1.contoso.com') -OverrideCredential (New-TestCredential 'OVERRIDE\adm') -CredentialPromptScript { throw 'must not prompt' }
    Assert-Equal -Actual $overrideMap['vm1.contoso.com'].UserName -Expected 'OVERRIDE\adm' -Message 'an explicit credential still short-circuits the prompt'

    $script:defaultPromptCalls = 0
    function Get-Credential { param([string]$Message) $script:defaultPromptCalls++; New-TestCredential 'DEFAULT\adm' }

    $defaultedMap = Resolve-GuestCredentialMap -TargetNames @('vm1.contoso.com', 'oldbox')
    Assert-Equal -Actual $defaultedMap.Count -Expected 2 -Message 'omitting the prompt script falls back to the built-in prompt rather than throwing'
    Assert-Equal -Actual $script:defaultPromptCalls -Expected 2 -Message 'the built-in prompt runs once per credential group'
    Assert-Equal -Actual $defaultedMap['oldbox'].UserName -Expected 'DEFAULT\adm' -Message 'the built-in prompt result reaches the map'

    Remove-Item Function:\Get-Credential -ErrorAction SilentlyContinue
}

# --- GUI provider scriptblocks (Start-PatchingGuestOpsGui.ps1, AST-extracted) ---
# These 18 lines join four functions across three files and no other gate touches them.
# The failure mode is a StrictMode property error raised hours into a run, at the exact
# moment the operator is asked to choose updates.
$guiLauncherFile = Join-Path $repoRoot 'Start-PatchingGuestOpsGui.ps1'
if (-not (Test-Path -LiteralPath $guiLauncherFile -PathType Leaf)) {
    Add-Failure -Message 'GUI entry point not found: Start-PatchingGuestOpsGui.ps1'
}
else {
    $guiTokens = $null
    $guiErrors = $null
    $guiAst = [System.Management.Automation.Language.Parser]::ParseFile($guiLauncherFile, [ref]$guiTokens, [ref]$guiErrors)
    $providerHashtables = @($guiAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true) | Where-Object {
        @($_.KeyValuePairs | ForEach-Object { [string]$_.Item1.Extent.Text }) -contains 'SelectUpdateGroups'
    })

    if ($providerHashtables.Count -eq 0) {
        Add-Failure -Message 'GUI entry point does not build a prompt provider carrying SelectUpdateGroups'
    }
    else {
        $providerPairs = @($providerHashtables[0].KeyValuePairs)
        $selectPair = @($providerPairs | Where-Object { [string]$_.Item1.Extent.Text -eq 'SelectUpdateGroups' })
        $credentialPair = @($providerPairs | Where-Object { [string]$_.Item1.Extent.Text -eq 'PromptCredential' })
        Assert-Equal -Actual $credentialPair.Count -Expected 1 -Message 'the GUI provider also carries PromptCredential'

        $selectBlock = $selectPair[0].Item2.GetPureExpression().ScriptBlock.GetScriptBlock()
        $credentialBlock = $credentialPair[0].Item2.GetPureExpression().ScriptBlock.GetScriptBlock()

        $script:dialogDefaults = $null
        function Show-UpdateGroupDialog {
            param($UpdateGroups, [int[]]$DefaultCheckedIndexes)
            $script:dialogDefaults = @($DefaultCheckedIndexes)
            return [pscustomobject]@{ Aborted = $false; CheckedIndexes = @(1) }
        }
        function Show-CredentialDialog {
            param([string]$Title, [string]$Message, [string]$UserName = '')
            return [pscustomobject]@{ Credential = (New-TestCredential 'GUI\adm'); Remember = $true }
        }

        $providerGroups = @(
            [pscustomobject]@{ identityKey = 'aaa|1'; title = 'Cumulative'; kbText = 'KB1'; selectedByDefault = $true; appliesToVmCount = 2; patchableVmCount = 2 },
            [pscustomobject]@{ identityKey = 'bbb|2'; title = 'Driver'; kbText = 'KB2'; selectedByDefault = $false; appliesToVmCount = 1; patchableVmCount = 1 }
        )

        $selectionOutcome = & $selectBlock @{ UpdateGroups = $providerGroups }
        Assert-Equal -Actual $selectionOutcome.Aborted -Expected $false -Message 'the selection provider reports a completed selection'
        Assert-Equal -Actual (@($selectionOutcome.Keys) -join ';') -Expected 'bbb|2' -Message 'the selection provider maps the dialog check state to identity keys'
        Assert-Equal -Actual (@($script:dialogDefaults) -join ',') -Expected '0' -Message 'the selection provider pre-ticks the dialog from the default policy'

        function Show-UpdateGroupDialog {
            param($UpdateGroups, [int[]]$DefaultCheckedIndexes)
            return [pscustomobject]@{ Aborted = $true; CheckedIndexes = @() }
        }

        $abortOutcome = & $selectBlock @{ UpdateGroups = $providerGroups }
        Assert-Equal -Actual $abortOutcome.Aborted -Expected $true -Message 'a cancelled dialog becomes an aborted selection result'

        $credentialOutcome = & $credentialBlock 'Credentials for vCenter vc1'
        Assert-Equal -Actual $credentialOutcome.UserName -Expected 'GUI\adm' -Message 'the credential provider returns the credential itself, not the dialog wrapper'

        function Show-CredentialDialog {
            param([string]$Title, [string]$Message, [string]$UserName = '')
            return $null
        }

        $cancelledCredential = & $credentialBlock 'Credentials for vCenter vc1'
        Assert-Equal -Actual ($null -eq $cancelledCredential) -Expected $true -Message 'a cancelled credential dialog yields $null for the retry loop to reject'

        # The end-of-cycle question. Read-RescanDecision casts this answer to [bool], so a
        # provider that returned the dialog wrapper instead of its verdict would read as $true
        # and start a full rescan of every VM nobody asked for.
        $rescanPair = @($providerPairs | Where-Object { [string]$_.Item1.Extent.Text -eq 'ConfirmRescan' })
        Assert-Equal -Actual $rescanPair.Count -Expected 1 -Message 'the GUI provider answers the rescan question in a window'
        if ($rescanPair.Count -eq 1) {
            $rescanBlock = $rescanPair[0].Item2.GetPureExpression().ScriptBlock.GetScriptBlock()

            function Show-RescanDialog { return $true }
            Assert-Equal -Actual (& $rescanBlock @{}) -Expected $true -Message 'an accepted rescan dialog starts another scan cycle'

            function Show-RescanDialog { return $false }
            Assert-Equal -Actual (& $rescanBlock @{}) -Expected $false -Message 'a declined rescan dialog ends the session'
        }

        # The round question. Its two arguments are built in one file and consumed in another,
        # and a dialog handed the full completion state instead of the pending subset would list
        # green VMs as work still outstanding.
        $continuePair = @($providerPairs | Where-Object { [string]$_.Item1.Extent.Text -eq 'ContinuePatching' })
        Assert-Equal -Actual $continuePair.Count -Expected 1 -Message 'the GUI provider answers the round question in a window'
        if ($continuePair.Count -eq 1) {
            $continueBlock = $continuePair[0].Item2.GetPureExpression().ScriptBlock.GetScriptBlock()

            $script:continueDialogArgs = $null
            function Show-ContinuePatchingDialog {
                param($PendingStates, [int]$Round)
                $script:continueDialogArgs = [pscustomobject]@{
                    Names = @(@($PendingStates) | ForEach-Object { [string]$_.vmName })
                    Round = $Round
                }
                return 'CONTINUE'
            }

            $continueOutcome = & $continueBlock @{ PendingStates = @([pscustomobject]@{ vmName = 'VM01'; reason = 'still pending' }); Round = 3 }
            Assert-Equal -Actual $continueOutcome -Expected 'CONTINUE' -Message 'the round provider returns the dialog verdict'
            Assert-Equal -Actual (@($script:continueDialogArgs.Names) -join ',') -Expected 'VM01' -Message 'the provider hands the pending VM list to the dialog'
            Assert-Equal -Actual $script:continueDialogArgs.Round -Expected 3 -Message 'the provider hands the round number to the dialog'
        }

        # The plan approval. The provider renders through the model helpers rather than
        # formatting the records itself, so what the operator approves in the window is what
        # the console listing recorded.
        $planPair = @($providerPairs | Where-Object { [string]$_.Item1.Extent.Text -eq 'ConfirmPatchPlan' })
        Assert-Equal -Actual $planPair.Count -Expected 1 -Message 'the GUI provider answers the plan approval in a window'
        if ($planPair.Count -eq 1) {
            $planBlock = $planPair[0].Item2.GetPureExpression().ScriptBlock.GetScriptBlock()

            function Get-PatchPlanDisplayLines { param($PatchPlanRecords) return @('VM01', 'Selected:', '- KB5000001 - Update A') }
            function Get-PatchPlanSummaryLine { param($PatchPlanRecords) return '1 VM in plan' }

            $script:planDialogArgs = $null
            function Show-PatchPlanDialog {
                param([string[]]$PlanLines, [string]$Summary = '')
                $script:planDialogArgs = [pscustomobject]@{ Lines = @($PlanLines); Summary = $Summary }
                return $true
            }

            $planApprovalOutcome = & $planBlock @{ PatchPlanRecords = @([pscustomobject]@{ vmName = 'VM01' }) }
            Assert-Equal -Actual $planApprovalOutcome -Expected $true -Message 'an approved plan dialog returns approval'
            Assert-Equal -Actual (@($script:planDialogArgs.Lines) -join '|') -Expected 'VM01|Selected:|- KB5000001 - Update A' -Message 'the dialog is given the model-rendered plan lines'
            Assert-Equal -Actual $script:planDialogArgs.Summary -Expected '1 VM in plan' -Message 'the dialog is given the model-rendered summary'

            function Show-PatchPlanDialog { param([string[]]$PlanLines, [string]$Summary = '') return $false }
            Assert-Equal -Actual (& $planBlock @{ PatchPlanRecords = @() }) -Expected $false -Message 'a refused plan dialog refuses the plan'
        }

        # The reboot checkpoint and its batch size. Both are asked from inside the apply
        # phase, so a missing provider entry does not fail loudly - it waits on a console
        # prompt behind the window the operator is looking at.
        $rebootPair = @($providerPairs | Where-Object { [string]$_.Item1.Extent.Text -eq 'ConfirmGuestReboot' })
        Assert-Equal -Actual $rebootPair.Count -Expected 1 -Message 'the GUI provider answers the reboot checkpoint in a window'
        if ($rebootPair.Count -eq 1) {
            $rebootBlock = $rebootPair[0].Item2.GetPureExpression().ScriptBlock.GetScriptBlock()

            function Get-RebootTargetDisplayLines { param($RebootTargets) return @('- VM01 (installResult.rebootRequired)') }

            $script:rebootDialogArgs = $null
            function Show-GuestRebootDialog {
                param([string[]]$TargetLines, [int]$TargetCount = 0)
                $script:rebootDialogArgs = [pscustomobject]@{ Lines = @($TargetLines); Count = $TargetCount }
                return $true
            }

            $rebootOutcome = & $rebootBlock @{ RebootTargets = @([pscustomobject]@{ vmName = 'VM01' }, [pscustomobject]@{ vmName = 'VM02' }) }
            Assert-Equal -Actual $rebootOutcome -Expected $true -Message 'an approved reboot dialog returns approval'
            Assert-Equal -Actual (@($script:rebootDialogArgs.Lines) -join '|') -Expected '- VM01 (installResult.rebootRequired)' -Message 'the dialog is given the model-rendered target lines'
            Assert-Equal -Actual $script:rebootDialogArgs.Count -Expected 2 -Message 'the dialog is told how many machines it is about to restart'

            function Show-GuestRebootDialog { param([string[]]$TargetLines, [int]$TargetCount = 0) return $false }
            Assert-Equal -Actual (& $rebootBlock @{ RebootTargets = @() }) -Expected $false -Message 'a declined reboot dialog skips the reboot'
        }

        $batchPair = @($providerPairs | Where-Object { [string]$_.Item1.Extent.Text -eq 'RebootBatchSize' })
        Assert-Equal -Actual $batchPair.Count -Expected 1 -Message 'the GUI provider answers the reboot batch size in a window'
        if ($batchPair.Count -eq 1) {
            $batchBlock = $batchPair[0].Item2.GetPureExpression().ScriptBlock.GetScriptBlock()

            $script:batchDialogCount = 0
            function Show-RebootBatchSizeDialog {
                param([int]$TargetCount = 0)
                $script:batchDialogCount = $TargetCount
                return 3
            }

            Assert-Equal -Actual (& $batchBlock @{ TargetCount = 21 }) -Expected 3 -Message 'the batch provider returns the dialog answer'
            Assert-Equal -Actual $script:batchDialogCount -Expected 21 -Message 'the provider hands the target count to the dialog'
        }

        # The four recovery hooks. Each one is a scriptblock whose parameters must line up
        # positionally with a caller in another file, and nothing else checks that: a renamed
        # parameter or a swapped argument shows up as a password written under the wrong key.
        $recoverGuestPair = @($providerPairs | Where-Object { [string]$_.Item1.Extent.Text -eq 'RecoverGuestCredential' })
        Assert-Equal -Actual $recoverGuestPair.Count -Expected 1 -Message 'the GUI provider offers guest credential recovery'
        $validatedPair = @($providerPairs | Where-Object { [string]$_.Item1.Extent.Text -eq 'CredentialValidated' })
        Assert-Equal -Actual $validatedPair.Count -Expected 1 -Message 'the GUI provider reports validated guest credentials'
        $recoverVIPair = @($providerPairs | Where-Object { [string]$_.Item1.Extent.Text -eq 'RecoverVIServerCredential' })
        Assert-Equal -Actual $recoverVIPair.Count -Expected 1 -Message 'the GUI provider offers vCenter credential recovery'
        $validatedVIPair = @($providerPairs | Where-Object { [string]$_.Item1.Extent.Text -eq 'VIServerCredentialValidated' })
        Assert-Equal -Actual $validatedVIPair.Count -Expected 1 -Message 'the GUI provider reports validated vCenter credentials'

        $script:recoveryDialogMembers = @()
        $script:recoveryDialogMessage = ''
        $script:recoveryDialogAllowSkip = $null
        function Show-GuestCredentialRecoveryDialog {
            param([string]$Message, [string[]]$Members, [switch]$AllowSkip)
            $script:recoveryDialogMessage = $Message
            $script:recoveryDialogMembers = @($Members)
            $script:recoveryDialogAllowSkip = [bool]$AllowSkip
            return [pscustomobject]@{ Action = 'Retry'; Credential = (New-TestCredential 'GUI\replacement'); Remember = $true }
        }
        $script:registeredCredentials = @()
        function Register-ValidatedGuiCredential {
            param([string]$StoreKey, [pscredential]$Credential, $Remember)
            $script:registeredCredentials += [pscustomobject]@{ StoreKey = $StoreKey; UserName = $Credential.UserName; Remember = $Remember }
        }

        # Exactly how scripts/CredentialRecovery.ps1 calls the decision script.
        $guestDecision = & ($recoverGuestPair[0].Item2.GetPureExpression().ScriptBlock.GetScriptBlock()) 'vm1.contoso.com' 'domain:contoso.com' @('vm1.contoso.com', 'vm2.contoso.com') 'The guest rejected the supplied credential.'
        Assert-Equal -Actual $guestDecision.Action -Expected 'Retry' -Message 'the guest recovery hook returns the shared decision contract'
        Assert-Contains -Text $script:recoveryDialogMessage -Needle 'vm1.contoso.com' -Message 'the recovery dialog names the guest that refused the login'
        Assert-Contains -Text $script:recoveryDialogMessage -Needle 'domain:contoso.com' -Message 'the recovery dialog names the account, not just the guest'
        Assert-Equal -Actual (@($script:recoveryDialogMembers) -join ',') -Expected 'vm1.contoso.com,vm2.contoso.com' -Message 'the recovery dialog lists every target the account covers'
        Assert-Equal -Actual $script:recoveryDialogAllowSkip -Expected $true -Message 'a guest account can be skipped for the rest of the run'

        # Exactly how Resolve-GuestCredentialForTarget reports a validated replacement.
        & ($validatedPair[0].Item2.GetPureExpression().ScriptBlock.GetScriptBlock()) 'domain:contoso.com' @('vm1.contoso.com') (New-TestCredential 'CONTOSO\new') $true | Out-Null
        Assert-Equal -Actual $script:registeredCredentials[-1].StoreKey -Expected 'guest:domain:contoso.com' -Message 'a corrected guest password is written back to its existing group entry'
        Assert-Equal -Actual $script:registeredCredentials[-1].Remember -Expected $true -Message 'the explicit Remember reaches the store decision'

        # Exactly how Connect-VIServersWithCredentialMap calls its two hooks.
        $viDecision = & ($recoverVIPair[0].Item2.GetPureExpression().ScriptBlock.GetScriptBlock()) 'vc01.example.test' 'Credentials for vCenter vc01.example.test (previous login failed)'
        Assert-Equal -Actual $viDecision.Action -Expected 'Retry' -Message 'the vCenter recovery hook returns the same decision contract'
        Assert-Equal -Actual (@($script:recoveryDialogMembers) -join ',') -Expected 'vc01.example.test' -Message 'a vCenter recovery dialog covers that one server'
        # There is no way to run a patch round against a vCenter nobody can log in to, so the
        # button is hidden rather than offered and then silently turned into a full stop.
        Assert-Equal -Actual $script:recoveryDialogAllowSkip -Expected $false -Message 'a vCenter cannot be skipped, so the dialog does not offer it'

        $registeredBeforeBlank = @($script:registeredCredentials).Count
        & ($validatedVIPair[0].Item2.GetPureExpression().ScriptBlock.GetScriptBlock()) '   ' (New-TestCredential 'VC\replacement') $true | Out-Null
        Assert-Equal -Actual (@($script:registeredCredentials).Count) -Expected $registeredBeforeBlank -Message 'a blank vCenter name writes no credential under an empty target key'

        & ($validatedVIPair[0].Item2.GetPureExpression().ScriptBlock.GetScriptBlock()) ' VC01.Example.Test ' (New-TestCredential 'VC\replacement') $null | Out-Null
        Assert-Equal -Actual $script:registeredCredentials[-1].StoreKey -Expected 'vcenter:target:vc01.example.test' -Message 'a corrected vCenter password is written under its own target key, never the shared group entry'
        Assert-Equal -Actual ($null -eq $script:registeredCredentials[-1].Remember) -Expected $true -Message 'a credential validated without an explicit answer leaves the decision to the startup preference'

        Remove-Item Function:\Register-ValidatedGuiCredential -ErrorAction SilentlyContinue

        # The GUI's own delegation, lifted from the real launcher and run against a real state.
        # Every assertion above this point stubbed it out, which is exactly the shape that once
        # failed silently: a function that assigns to an enclosing script variable does not
        # update it in PowerShell 5.1, and the callback is invoked from inside a generic catch.
        $delegationFunctions = @($guiAst.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Register-ValidatedGuiCredential'
        }, $true))
        Assert-Equal -Actual $delegationFunctions.Count -Expected 1 -Message 'the GUI launcher defines the credential delegation the provider hooks call'

        $delegationDir = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-delegation-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $delegationDir)
        try {
            $delegationPath = Join-Path $delegationDir 'credentials.json'
            $store = @{ 'guest:domain:contoso.com' = (New-TestCredential 'CONTOSO\old') }
            Write-CredentialStore -Path $delegationPath -Credentials $store
            $persistState = New-CredentialPersistState -Path $delegationPath -WorkingCredentials $store -PersistedCredentials @{ 'guest:domain:contoso.com' = $store['guest:domain:contoso.com'] }
            Set-CredentialRememberPreference -State $persistState -StoreKey 'guest:domain:contoso.com' -Remember $true

            . ([scriptblock]::Create($delegationFunctions[0].Extent.Text))
            Register-ValidatedGuiCredential -StoreKey 'guest:domain:contoso.com' -Credential (New-TestCredential 'CONTOSO\new') -Remember $true

            Assert-Equal -Actual (Read-CredentialStore -Path $delegationPath).Credentials['guest:domain:contoso.com'].UserName -Expected 'CONTOSO\new' -Message 'the GUI delegation actually reaches the file, not just the in-memory state'
            Assert-Equal -Actual $store['guest:domain:contoso.com'].UserName -Expected 'CONTOSO\new' -Message 'the GUI delegation also leaves the corrected credential in the working map'
        }
        finally {
            Remove-Item Function:\Register-ValidatedGuiCredential -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $delegationDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        Remove-Item Function:\Show-GuestCredentialRecoveryDialog -ErrorAction SilentlyContinue
        Remove-Item Function:\Show-UpdateGroupDialog -ErrorAction SilentlyContinue
        Remove-Item Function:\Show-CredentialDialog -ErrorAction SilentlyContinue
    }
}

# guest/Run-LocalPatch.ps1 cannot be dot-sourced (it runs WUA COM at top level), so
# Test-PendingReboot is lifted out by AST and exercised against stubbed registry access. This is
# the check that decides whether the operator is offered a reboot at all, and a false positive
# here is invisible until it happens on a live fleet.
$agentScriptPath = Join-Path $repoRoot 'guest\Run-LocalPatch.ps1'
$agentTokens = $null
$agentErrors = $null
$agentAst = [System.Management.Automation.Language.Parser]::ParseFile($agentScriptPath, [ref]$agentTokens, [ref]$agentErrors)
$pendingRebootDefinition = @($agentAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $_.Name -eq 'Test-PendingReboot' })
if ($pendingRebootDefinition.Count -eq 0) {
    Add-Failure -Message 'Agent function not found: Test-PendingReboot'
}
else {
    # The stubs are defined inside the probe scriptblock so they stay scoped to each invocation
    # and never shadow the real cmdlets for the rest of this file.
    $pendingRebootProbeText = @'
param([bool]$CbsPending, [bool]$WindowsUpdatePending, $RenameValue, [bool]$RenameMissing)

function Test-Path {
    param([string]$LiteralPath)
    if ($LiteralPath -like '*Component Based Servicing*') { return $CbsPending }
    return $WindowsUpdatePending
}

function Get-ItemProperty {
    param([string]$LiteralPath, [string]$Name, $ErrorAction)
    if ($RenameMissing) { throw 'Property PendingFileRenameOperations does not exist.' }
    return [pscustomobject]@{ PendingFileRenameOperations = $RenameValue }
}

'@ + $pendingRebootDefinition[0].Extent.Text + [Environment]::NewLine + 'Test-PendingReboot'
    $pendingRebootProbe = [scriptblock]::Create($pendingRebootProbeText)

    $quietReboot = & $pendingRebootProbe $false $false $null $true
    Assert-Equal -Actual ([bool]$quietReboot.isPending) -Expected $false -Message 'a clean guest reports no pending reboot'
    Assert-Equal -Actual (@($quietReboot.pendingReasons).Count) -Expected 0 -Message 'a clean guest names no pending reboot reason'

    # The regression: Windows leaves the value behind as blank entries, and reading presence as
    # pending made every guest look like it needed a reboot.
    $blankRenameReboot = & $pendingRebootProbe $false $false @('', '   ', '') $false
    Assert-Equal -Actual ([bool]$blankRenameReboot.isPending) -Expected $false -Message 'a blank PendingFileRenameOperations value is not a pending reboot'
    Assert-Equal -Actual ([bool]$blankRenameReboot.checks.pendingFileRename) -Expected $false -Message 'a blank PendingFileRenameOperations check is false'

    $emptyRenameReboot = & $pendingRebootProbe $false $false @() $false
    Assert-Equal -Actual ([bool]$emptyRenameReboot.isPending) -Expected $false -Message 'an empty PendingFileRenameOperations array is not a pending reboot'

    # A real queued rename is detected and reported, but it does not gate the prompt: any
    # installer can queue one, and on its own it says nothing about whether patching left work
    # outstanding. This is the case that offered a reboot on a guest with zero applicable
    # updates and neither servicing flag set.
    $realRenameReboot = & $pendingRebootProbe $false $false @('\??\C:\Windows\file.dll', '') $false
    Assert-Equal -Actual ([bool]$realRenameReboot.checks.pendingFileRename) -Expected $true -Message 'a queued file rename is still detected'
    Assert-Equal -Actual ([bool]$realRenameReboot.isPending) -Expected $false -Message 'a queued file rename alone does not require a reboot'
    Assert-Equal -Actual (@($realRenameReboot.pendingReasons).Count) -Expected 0 -Message 'a queued file rename is not a gating reason'
    Assert-Equal -Actual (@($realRenameReboot.advisoryReasons) -join ',') -Expected 'pendingFileRename' -Message 'a queued file rename is reported as advisory'

    $scalarRenameReboot = & $pendingRebootProbe $false $false '\??\C:\Windows\file.dll' $false
    Assert-Equal -Actual ([bool]$scalarRenameReboot.checks.pendingFileRename) -Expected $true -Message 'a single queued rename returned as a scalar is still detected'
    Assert-Equal -Actual ([bool]$scalarRenameReboot.isPending) -Expected $false -Message 'a scalar queued rename alone does not require a reboot'

    # A servicing flag alongside an advisory one must still gate, and must not swallow it.
    $mixedReboot = & $pendingRebootProbe $true $false @('\??\C:\Windows\file.dll', '') $false
    Assert-Equal -Actual ([bool]$mixedReboot.isPending) -Expected $true -Message 'a servicing flag still requires a reboot when a rename is queued too'
    Assert-Equal -Actual (@($mixedReboot.pendingReasons) -join ',') -Expected 'componentBasedServicing' -Message 'only the servicing flag is a gating reason'
    Assert-Equal -Actual (@($mixedReboot.advisoryReasons) -join ',') -Expected 'pendingFileRename' -Message 'the advisory flag survives alongside a gating one'

    $cbsReboot = & $pendingRebootProbe $true $false $null $true
    Assert-Equal -Actual ([bool]$cbsReboot.isPending) -Expected $true -Message 'component based servicing still reports a pending reboot'
    Assert-Equal -Actual (@($cbsReboot.pendingReasons) -join ',') -Expected 'componentBasedServicing' -Message 'component based servicing names itself as the reason'

    $wuReboot = & $pendingRebootProbe $false $true @('') $false
    Assert-Equal -Actual ([bool]$wuReboot.isPending) -Expected $true -Message 'the Windows Update flag still reports a pending reboot'
    Assert-Equal -Actual (@($wuReboot.pendingReasons) -join ',') -Expected 'windowsUpdate' -Message 'the Windows Update flag names itself as the reason'
    Assert-Equal -Actual (@($wuReboot.advisoryReasons).Count) -Expected 0 -Message 'a blank rename value is not even advisory'
}

if ($failures.Count -gt 0) {
    Write-Host 'Runtime checks failed:'
    foreach ($failure in $failures) {
        Write-Host (" - {0}" -f $failure)
    }
    exit 1
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Invoke-LauncherChecks.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Invoke-CertificateChecks.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Invoke-GuestWorkspaceChecks.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Invoke-RegressionChecks.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Invoke-SafetyRegressionChecks.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Invoke-AuditFollowupChecks.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Invoke-RescanChecks.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host 'Runtime checks passed.'
exit 0

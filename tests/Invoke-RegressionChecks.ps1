Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\GuestOpsLib.ps1')
. (Join-Path $repoRoot 'scripts\OrchestratorRuntime.ps1')
. (Join-Path $repoRoot 'scripts\PatchPlanModel.ps1')
. (Join-Path $repoRoot 'scripts\VMTargetLib.ps1')
$failures = @()
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { $script:failures += ('{0}: expected {1}, got {2}' -f $Message, $Expected, $Actual) }
}

# Run the real preflight and round loop without loading PowerCLI or contacting guests.
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts\Invoke-GuestOpsPatchValidation.ps1'), [ref]$tokens, [ref]$parseErrors)
foreach ($definition in @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$statements = @($ast.EndBlock.Statements)
$lastFunction = @($statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })[-1]
$importStatement = @($statements | Where-Object { $_.Extent.Text -like 'Import-Module *' })[0]
$preflight = @($statements | Where-Object {
    $_.Extent.StartOffset -gt $lastFunction.Extent.EndOffset -and
    $_.Extent.StartOffset -lt $importStatement.Extent.StartOffset
})
& {
    function Assert-LocalPrerequisites { throw 'PrerequisitesReached' }
    $preflightScript = [scriptblock]::Create($ast.ParamBlock.Extent.Text + "`n" + '$PSScriptRoot = Join-Path $repoRoot ''scripts''' + "`n" + (($preflight | ForEach-Object { $_.Extent.Text }) -join "`n"))
    $message = ''
    try { & $preflightScript -VIServer 'fake.invalid' -VMName 'vm01' -AgentPath 'unused.ps1' -LocalOutputDirectory 'unused' -PatchPlanPath 'unused.json' -SearchOnly -SkipConfirmation }
    catch { $message = $_.Exception.Message }
    Assert-Equal ($message -like '*SearchOnly*PatchPlanPath*') $true 'SearchOnly with a saved plan is rejected before prerequisites or connections'
    $message = ''
    try { & $preflightScript -VIServer 'fake.invalid' -VMName 'vm01' -AgentPath 'unused.ps1' -LocalOutputDirectory 'unused' -SearchOnly }
    catch { $message = $_.Exception.Message }
    Assert-Equal $message 'PrerequisitesReached' 'ordinary SearchOnly remains available'
    $message = ''
    try { & $preflightScript -VIServer 'fake.invalid' -VMName 'vm01' -AgentPath 'unused.ps1' -LocalOutputDirectory 'unused' -PatchPlanPath 'unused.json' -PlanOnly }
    catch { $message = $_.Exception.Message }
    Assert-Equal $message 'PrerequisitesReached' 'PlanOnly may inspect a saved plan'
}

$cluster = [pscustomobject]@{ vmName = 'cluster01'; roleFlags = [pscustomobject]@{ failoverCluster = $true }; pendingRebootBefore = [pscustomobject]@{ isPending = $true } }
$ordinary = [pscustomobject]@{ vmName = 'vm01'; roleFlags = [pscustomobject]@{ failoverCluster = $false }; pendingRebootBefore = [pscustomobject]@{ isPending = $true } }
$results = @(
    [pscustomobject]@{ vmName = 'cluster01'; action = 'Skip'; reason = 'Skipped: Failover Cluster detected. Please update manually one by one.'; rebootRequired = $false },
    [pscustomobject]@{ vmName = 'vm01'; action = 'NoSelectedUpdates'; reason = 'No selected updates apply.'; rebootRequired = $false }
)
$targets = @(Select-RebootRequiredApplyResults -ApplyResults $results -DiscoveryRecords @($cluster, $ordinary))
Assert-Equal (@($targets | Where-Object { $_.vmName -eq 'cluster01' }).Count) 0 'excluded cluster never becomes a reboot target'
Assert-Equal (@($targets | Where-Object { $_.vmName -eq 'vm01' }).Count) 1 'ordinary pending reboot survives an empty update selection'
$savedClusterResult = [pscustomobject]@{ vmName = 'cluster01'; action = 'Skip'; roleFlags = [pscustomobject]@{ failoverCluster = $true }; rebootRequired = $true }
Assert-Equal (@(Select-RebootRequiredApplyResults -ApplyResults @($savedClusterResult)).Count) 0 'saved-plan cluster exclusion also blocks an after-apply reboot flag'

# A valid terminal outcome is insufficient when the artifact belongs to another cycle.
& {
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('patch-regression-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory | Out-Null
    try {
        $handle = [pscustomobject]@{
            RunId = 'current-cycle'; Managers = [pscustomobject]@{ FileManager = $null }; VMView = $null; GuestAuth = $null
            HostName = 'fake.invalid'; CurlPath = 'curl.exe'; GuestStatusPath = 'status.json'; GuestLogPath = 'agent.log'
            LocalStatusPath = (Join-Path $directory 'status.json'); LocalLogPath = (Join-Path $directory 'agent.log'); TransferTimeoutSeconds = 1
        }
        function Receive-GuestFile {
            param($FileManager, $VMView, $GuestAuth, $HostName, $CurlPath, $GuestPath, $LocalPath, $TimeoutSeconds)
            if ($GuestPath -eq 'status.json') { $fixture | ConvertTo-Json | Set-Content -LiteralPath $LocalPath -Encoding UTF8 }
            else { Set-Content -LiteralPath $LocalPath -Value 'test log' }
        }
        foreach ($artifactRunId in @('old-cycle', '', 'current-cycle')) {
            $fixture = [pscustomobject]@{ runId = $artifactRunId; outcome = 'InstallSucceeded'; finishedAt = '2020-01-01T00:00:00Z' }
            $accepted = $false
            try { $null = Complete-VMAgentCycle -Handle $handle -AgentResult $null; $accepted = $true }
            catch { if ($_.Exception.Message -notlike '*run*') { throw } }
            Assert-Equal $accepted ($artifactRunId -eq 'current-cycle') ('cycle ownership for artifact ' + $artifactRunId)
        }
    }
    finally { Remove-Item -LiteralPath $directory -Recurse -Force }
}

# Exercise the agent's actual final install classification with an earlier selection error.
$agentAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'guest\Run-LocalPatch.ps1'), [ref]$tokens, [ref]$parseErrors)
$classification = $agentAst.Find({ param($n)
    $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '[int]$installResult.ResultCode -eq 2'
}, $true)
foreach ($errorStage in @('Selection', 'PerUpdate', 'None')) {
    $status = [ordered]@{ outcome = ''; errors = @(); updates = @() }
    if ($errorStage -eq 'Selection') { $status.errors = @([pscustomobject]@{ stage = 'AcceptEulaOrSelect'; message = 'EULA failed for one selected update' }) }
    if ($errorStage -eq 'PerUpdate') { $status.updates = @([pscustomobject]@{ errors = @([pscustomobject]@{ stage = 'ReadInstallResult'; message = 'Result unavailable' }) }) }
    $installResult = [pscustomobject]@{ ResultCode = 2 }
    $scriptExitCode = 99
    . ([scriptblock]::Create($classification.Extent.Text))
    $expectedOutcome = if ($errorStage -ne 'None') { 'InstallSucceededWithErrors' } else { 'InstallSucceeded' }
    $expectedExit = if ($errorStage -ne 'None') { 1 } else { 0 }
    Assert-Equal $status.outcome $expectedOutcome 'agent retains selection failures after remaining updates install'
    Assert-Equal $scriptExitCode $expectedExit 'agent exit reflects incomplete selection'
}
$resultWithErrors = [pscustomobject]@{ action = 'Install'; outcome = 'InstallSucceeded'; reason = ''; errors = @('Selection failed') }
Assert-Equal (Test-ApplyResultsSuccessful @($resultWithErrors)) $false 'controller rejects nominal success carrying errors'

# Keep the real loop, planning, selection tracking and state merge. Only prompts, guest
# execution and artifact writes are replaced; no updates or reboots can occur in this test.
$roundLoop = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] -and $n.Extent.Text.Contains('$roundNumber++') }, $true)
& {
    function New-Item { }
    function Set-Content { param([Parameter(ValueFromPipeline = $true)]$Value, $LiteralPath, $Encoding) process { } }
    function Write-Step { }
    function Show-UpdateGroups { }
    function Show-PatchPlan { }
    function Confirm-PatchPlan { $true }
    function Read-UpdateGroupSelection { [pscustomobject]@{ Aborted = $false; Keys = @() } }
    function Invoke-DiscoveryPhase { $discovery }
    function Invoke-ApplyAndOptionalReboot { [pscustomobject]@{ ExitCode = 0; RebootRan = $false; RebootActions = @() } }
    $discovery = [pscustomobject]@{
        vmName = 'vm01'; computerName = 'vm01'; outcome = 'SearchOnly'; errors = @()
        roleFlags = [pscustomobject]@{ failoverCluster = $false }
        updates = @([pscustomobject]@{ updateId = '11111111-1111-1111-1111-111111111111'; revisionNumber = 1; title = 'Security Update'; msrcSeverity = 'Critical'; updateType = 'Software' })
    }
    $roundNumber = 0; $roundTargetVMNames = @('vm01'); $roundSummaries = @(); $finalStateMap = @{}
    $deselectedUpdateKeys = @(); $sawApplyFailure = $false; $stoppedByRoundCap = $false
    $guestCredentialContext = $null; $guestCredentialDecisionScript = $null
    $guestCredentialValidatedScript = $null; $guestCredentialInteractive = $false
    $runOutputDirectory = Join-Path $repoRoot 'out'; $MaxPatchRounds = 3; $SearchOnly = $false; $PlanOnly = $false
    $hasExplicitSelectedUpdateKeys = $false; $SkipConfirmation = $false; $PromptProvider = $null
    $managers = $null; $guestCredentialMap = @{}; $resolvedVIServers = @('vc.regression.invalid'); $viServerScope = @('vc.regression.invalid'); $viserverCredentialMap = @{}
    $IgnoreVCenterCertificate = $false; $guestOpsLibPath = ''; $curlPath = ''; $AgentPath = ''; $identityHelperPath = ''; $workspaceScriptPath = ''; $runGuardScriptPath = ''; $rebootRequestScriptPath = ''
    $GuestWorkingDirectory = ''; $TimeoutMinutes = 1; $RebootTimeoutMinutes = 1; $PollSeconds = 1; $ThrottleLimit = 1
    $resolvedRebootBatchSize = 1; $MaxUpdates = 1
    . ([scriptblock]::Create($roundLoop.Extent.Text))
    Assert-Equal $finalStateMap['vm01'].state 'GreenByOperatorChoice' 'deselecting all updates refreshes the final state without another discovery'
    Assert-Equal (Test-PatchRunAllGreen $finalStateMap) $true 'operator choice does not produce a false failure exit'
}

# F9: patch-plan.json is written by the round loop itself, not by a function, so it is exercised
# through the same loop extraction - with the real New-Item and Set-Content this time. One record
# is the dangerous count: piping the collection serialises a bare object, and the resume path
# reads this file back expecting a collection.
# Both write sites: the round loop's and the -PlanOnly branch's. They are separate statements
# in the same loop, so fixing one and missing the other is exactly the kind of gap a test that
# only exercised the default path would not see.
foreach ($planOnlyCase in @($false, $true)) {
    $planRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-plan-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $planRoot | Out-Null
    try {
        function Write-Step { }
        function Show-UpdateGroups { }
        function Show-PatchPlan { }
        function Confirm-PatchPlan { $true }
        function Read-UpdateGroupSelection { [pscustomobject]@{ Aborted = $false; Keys = @('11111111-1111-1111-1111-111111111111|1') } }
        function Invoke-DiscoveryPhase { $planDiscovery }
        function Invoke-ApplyAndOptionalReboot { [pscustomobject]@{ ExitCode = 0; RebootRan = $false; RebootActions = @() } }
        $planDiscovery = [pscustomobject]@{
            vmName = 'vm01'; computerName = 'vm01'; outcome = 'SearchOnly'; errors = @()
            roleFlags = [pscustomobject]@{ failoverCluster = $false }
            pendingRebootBefore = [pscustomobject]@{ isPending = $false }
            updates = @([pscustomobject]@{ updateId = '11111111-1111-1111-1111-111111111111'; revisionNumber = 1; title = 'Security Update'; kbArticleIds = @(); categories = @('Security Updates'); msrcSeverity = 'Critical'; updateType = 'Software' })
        }
        $roundNumber = 0; $roundTargetVMNames = @('vm01'); $roundSummaries = @(); $finalStateMap = @{}
        $deselectedUpdateKeys = @(); $sawApplyFailure = $false; $stoppedByRoundCap = $false
        $guestCredentialContext = $null; $guestCredentialDecisionScript = $null
        $guestCredentialValidatedScript = $null; $guestCredentialInteractive = $false
        $runOutputDirectory = $planRoot; $MaxPatchRounds = 1; $SearchOnly = $false; $PlanOnly = $planOnlyCase
        $hasExplicitSelectedUpdateKeys = $false; $SkipConfirmation = $true; $PromptProvider = $null
        $managers = $null; $guestCredentialMap = @{}; $resolvedVIServers = @('vc.regression.invalid'); $viServerScope = @('vc.regression.invalid'); $viserverCredentialMap = @{}
        $IgnoreVCenterCertificate = $false; $guestOpsLibPath = ''; $curlPath = ''; $AgentPath = ''; $identityHelperPath = ''; $workspaceScriptPath = ''; $runGuardScriptPath = ''; $rebootRequestScriptPath = ''
        $GuestWorkingDirectory = ''; $TimeoutMinutes = 1; $RebootTimeoutMinutes = 1; $PollSeconds = 1; $ThrottleLimit = 1
        $resolvedRebootBatchSize = 1; $MaxUpdates = 1
        . ([scriptblock]::Create($roundLoop.Extent.Text))

        $planLabel = if ($planOnlyCase) { 'PlanOnly' } else { 'apply' }
        $planFiles = @(Get-ChildItem -LiteralPath $planRoot -Recurse -Filter 'patch-plan.json' -File)
        Assert-Equal $planFiles.Count 1 ('F9: the {0} path writes exactly one patch plan' -f $planLabel)
        if ($planFiles.Count -eq 1) {
            $planRaw = [string](Get-Content -LiteralPath $planFiles[0].FullName -Raw)
            Assert-Equal ($planRaw.TrimStart().StartsWith('[')) $true ('F9: a one-record {0} patch plan is a JSON array' -f $planLabel)
            # Assign before wrapping: ConvertFrom-Json emits the whole array as ONE pipeline
            # object in PowerShell 5.1, so @($raw | ConvertFrom-Json) would count the array.
            $planParsed = $planRaw | ConvertFrom-Json
            Assert-Equal @($planParsed).Count 1 ('F9: a one-record {0} patch plan reads back as one element' -f $planLabel)

            # The resume path is the reason the shape matters: it must load what was written.
            $resumed = @(ConvertTo-PatchPlanRecords -InputObject $planParsed 3>$null)
            Assert-Equal $resumed.Count 1 ('F9: the resume path loads the {0} plan it wrote' -f $planLabel)
            Assert-Equal ([string]$resumed[0].vmName) 'vm01' ('F9: the resumed {0} plan names the VM it was written for' -f $planLabel)
        }
    }
    finally {
        Remove-Item -LiteralPath $planRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host ('FAIL: ' + $failure) }
    exit 1
}
Write-Host 'Regression checks passed.'
exit 0

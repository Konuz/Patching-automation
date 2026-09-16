Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/GuestOpsLib.ps1')
. (Join-Path $repoRoot 'scripts/VMTargetLib.ps1')
. (Join-Path $repoRoot 'scripts/CredentialRecovery.ps1')
. (Join-Path $repoRoot 'scripts/PatchPlanModel.ps1')
. (Join-Path $repoRoot 'scripts/OrchestratorRuntime.ps1')

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts/Invoke-GuestOpsPatchValidation.ps1'), [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count) { throw 'Orchestrator does not parse.' }
foreach ($definition in @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$session = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })[-1]
$sessionCode = [scriptblock]::Create($session.Extent.Text)

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw ('{0}: expected {1}, got {2}' -f $Message, $Expected, $Actual) }
}

# Exercise the real connection lifetime, round loop, selection state and report writers.
# Only infrastructure and operator input are replaced; no VMware endpoint is contacted.
function Invoke-RescanScenario {
    param([string]$Mode = 'Interactive', [bool]$KeepConnected = $false)
    $targetVMNames = @('VM-A', 'VM-B')
    $resolvedVIServers = @('vc.synthetic.invalid')
    $viserverCredentialMap = @{}
    $connections = @()
    $scriptExitCode = 1
    $credentialPromptScript = $null
    $viserverRecoveryScript = $null
    $viserverValidatedScript = $null
    $retryVIServerLogin = $false
    $GuestCredential = $null
    $StoredGuestCredentials = $null
    $SkippedGuestCredentialTargets = @()
    $guestCredentialDecisionScript = $null
    $guestCredentialValidatedScript = $null
    $guestCredentialInteractive = $true
    $PatchPlanPath = ''
    $SearchOnly = $Mode -eq 'SearchOnly'
    $PlanOnly = $Mode -eq 'PlanOnly'
    $SkipConfirmation = $Mode -eq 'NonInteractive'
    $hasExplicitSelectedUpdateKeys = $Mode -eq 'ExplicitKeys'
    $SelectedUpdateKeys = @('11111111-1111-1111-1111-111111111111|1')
    $MaxPatchRounds = 1
    $PromptProvider = $null
    $IgnoreVCenterCertificate = $false
    $guestOpsLibPath = 'unused'
    $curlPath = 'unused'
    $AgentPath = 'unused'
    $identityHelperPath = 'unused'
    $workspaceScriptPath = 'unused'
    $runGuardScriptPath = 'unused'
    $rebootRequestScriptPath = 'unused'
    $GuestWorkingDirectory = 'C:\unused'
    $TimeoutMinutes = 1
    $DiscoveryTimeoutMinutes = 1
    $RebootTimeoutMinutes = 1
    $PollSeconds = 1
    $ThrottleLimit = 2
    $resolvedRebootBatchSize = 1
    $MaxUpdates = 1
    $LocalOutputDirectory = Join-Path $testRoot ($Mode + '-' + $KeepConnected)
    $trace = [pscustomobject]@{
        Connects = 0; Disconnects = @(); CredentialPrompts = 0; Prompts = 0; ProviderPrompts = 0
        Runs = @(); Discoveries = @(); Selections = @(); ExitCodes = @(); Contexts = @()
    }
    # A GUI run answers the end-of-cycle question in a window. The console fallback must then
    # not run at all: two surfaces asking the same question is how an operator ends up staring
    # at a prompt nobody told them about.
    if ($Mode -eq 'Provider') {
        $PromptProvider = @{
            ConfirmRescan = {
                param($Arguments)
                $trace.ProviderPrompts++
                Assert-Equal $trace.Disconnects.Count 0 'Connections stay open until the operator finishes'
                Assert-Equal (Test-Path -LiteralPath (Join-Path $runOutputDirectory 'summary.md')) $true 'Summary is saved before the question'
                ($trace.ProviderPrompts -eq 1)
            }
        }
    }
    $credential = New-Object pscredential('synthetic-user', (ConvertTo-SecureString 'synthetic-password' -AsPlainText -Force))
    $correctedCredential = New-Object pscredential('corrected-user', (ConvertTo-SecureString 'synthetic-corrected-password' -AsPlainText -Force))

    function Connect-VIServersWithCredentialMap {
        $trace.Connects++
        [pscustomobject]@{ Connections = @('owned-session', 'preexisting-session'); OpenedConnections = @('owned-session') }
    }
    function Disconnect-VIServer {
        param($Server, [switch]$Confirm)
        $trace.Disconnects += @($Server)
    }
    function Resolve-GuestCredentialMap {
        $trace.CredentialPrompts++
        @{ 'VM-A' = $credential; 'VM-B' = $credential }
    }
    function Invoke-DiscoveryPhase {
        param($TargetVMNames, $CycleOutputDirectory, $GuestCredentialMap, $CredentialContext, $VIServerScope)
        if ($Mode -eq 'Exception') { throw 'Synthetic discovery failure' }
        $runPath = Split-Path -Parent $CycleOutputDirectory
        if ($trace.Runs -notcontains $runPath) { $trace.Runs += $runPath }
        if ($trace.Runs.Count -gt 2) { throw 'Unexpected third scan cycle' }
        $trace.Discoveries += ,@($TargetVMNames)
        $trace.Contexts += ,$CredentialContext
        Assert-Equal ($VIServerScope -join ',') 'owned-session,preexisting-session' 'Discovery keeps the original connection scope'
        if ($trace.Runs.Count -eq 2) {
            Assert-Equal ([object]::ReferenceEquals($GuestCredentialMap['VM-A'], $correctedCredential)) $true 'Corrected credentials survive the rescan'
        }
        $GuestCredentialMap['VM-A'] = $correctedCredential
        foreach ($name in $TargetVMNames) {
            # Run one leaves a failed install on A and an operator-deselected update on B.
            # Run two must offer both VMs again, start at round one and clear both states.
            $updates = @()
            if ((Split-Path -Leaf $CycleOutputDirectory) -eq 'round-01' -or $trace.Runs.Count -eq 1) {
                $id = if ($name -eq 'VM-A') { '11111111-1111-1111-1111-111111111111' } else { '22222222-2222-2222-2222-222222222222' }
                $updates = @([pscustomobject]@{
                    updateId = $id; revisionNumber = 1; title = ('Security Update ' + $name)
                    kbArticleIds = @('5031250'); categories = @('Security Updates')
                    categoryIds = @('0fa1201d-4330-4fa8-8ae9-b877473b6441')
                    browseOnly = $false; msrcSeverity = 'Critical'; updateType = 'Software'
                })
            }
            [pscustomobject]@{
                vmName = $name; computerName = $name; outcome = 'SearchOnly'; errors = @()
                roleFlags = [pscustomobject]@{ failoverCluster = $false }
                pendingRebootBefore = [pscustomobject]@{ isPending = $false }; updates = $updates
            }
        }
    }
    function Read-UpdateGroupSelection {
        param($UpdateGroups, $PromptProvider)
        $trace.Selections += ,@($UpdateGroups | ForEach-Object { $_.identityKey })
        $keys = if ($trace.Runs.Count -eq 1) { @('11111111-1111-1111-1111-111111111111|1') } else { @($UpdateGroups | ForEach-Object { $_.identityKey }) }
        [pscustomobject]@{ Aborted = $false; Keys = $keys }
    }
    function Confirm-PatchPlan { param($PatchPlanRecords, [hashtable]$PromptProvider, [switch]$SkipConfirmation) $true }
    function Invoke-ApplyAndOptionalReboot {
        param($PatchPlanRecords)
        $results = @(foreach ($record in $PatchPlanRecords) {
            if (@($record.selectedUpdates).Count -eq 0) {
                New-ApplyResultRecord -VMName $record.vmName -Action 'NoSelectedUpdates' -Outcome 'NoSelectedUpdates' -AgentCompletionConfirmed $true
            }
            else {
                $outcome = if ($trace.Runs.Count -eq 1) { 'InstallFailed' } else { 'InstallSucceeded' }
                New-ApplyResultRecord -VMName $record.vmName -Action 'Install' -Outcome $outcome -AgentCompletionConfirmed $true
            }
        })
        [pscustomobject]@{
            ExitCode = [int]($trace.Runs.Count -eq 1); HasHardFailure = ($trace.Runs.Count -eq 1)
            ApplyResults = $results; RebootActions = @(); RebootTargets = @(); RebootRan = $false
        }
    }
    function Read-Host {
        param($Prompt)
        $trace.Prompts++
        if ($trace.Prompts -gt 3) { throw 'Unexpected extra operator prompt' }
        Assert-Equal $Prompt 'Start a fresh full rescan of every VM? [Y/N]' 'End-of-cycle question'
        Assert-Equal $trace.Disconnects.Count 0 'Connections stay open until the operator finishes'
        Assert-Equal (Test-Path -LiteralPath (Join-Path $runOutputDirectory 'summary.md')) $true 'Summary is saved before the question'
        if ($trace.Prompts -eq 1) { return 'invalid' }
        $trace.ExitCodes += $scriptExitCode
        if ($trace.Prompts -eq 2) { return ' y ' }
        return 'n'
    }

    . $sessionCode
    [pscustomobject]@{ Trace = $trace; ExitCode = $scriptExitCode }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('guestops-rescan-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
try {
    foreach ($keep in @($false, $true)) {
        $result = Invoke-RescanScenario -KeepConnected $keep
        $trace = $result.Trace
        Assert-Equal $trace.Runs.Count 2 'Y starts a second cycle and N stops'
        Assert-Equal $trace.Connects 1 'The session connects once for both cycles'
        Assert-Equal $trace.CredentialPrompts 1 'Guest credentials are resolved once'
        Assert-Equal ($trace.ExitCodes -join ',') '1,0' 'A failed first run does not contaminate the second result'
        Assert-Equal $result.ExitCode 0 'The session returns the final cycle exit code'
        Assert-Equal ($trace.Disconnects -join ',') $(if ($keep) { '' } else { 'owned-session' }) 'Only owned sessions close on N; explicit KeepConnected remains supported'
        Assert-Equal ($trace.Discoveries[0] -join ',') 'VM-A,VM-B' 'First cycle starts with the full target set'
        Assert-Equal ($trace.Discoveries[1] -join ',') 'VM-A' 'Verification can narrow the target set'
        Assert-Equal ($trace.Discoveries[2] -join ',') 'VM-A,VM-B' 'Rescan restores the full original target set'
        Assert-Equal $trace.Selections.Count 2 'Each cycle gets a new update selection'
        Assert-Equal ([object]::ReferenceEquals($trace.Contexts[0], $trace.Contexts[2])) $true 'Credential recovery decisions remain in the session context'
        foreach ($runPath in $trace.Runs) {
            $rounds = Get-Content -LiteralPath (Join-Path $runPath 'rounds.json') -Raw | ConvertFrom-Json
            Assert-Equal (($rounds | ForEach-Object { $_.round }) -join ',') '1,2' 'Each report has only its own rounds starting at one'
            Assert-Equal (Test-Path -LiteralPath (Join-Path $runPath 'round-01/patch-plan.json')) $true 'Each cycle retains its own plan'
        }
        $secondPlan = Get-Content -LiteralPath (Join-Path $trace.Runs[1] 'round-01/patch-plan.json') -Raw | ConvertFrom-Json
        Assert-Equal (@($secondPlan | Where-Object { @($_.selectedUpdates).Count -eq 1 }).Count) 2 'Both previously selected and deselected updates can be selected in the new cycle'
    }
    $providerResult = Invoke-RescanScenario -Mode 'Provider'
    Assert-Equal $providerResult.Trace.Prompts 0 'A prompt provider answers instead of the console question'
    Assert-Equal $providerResult.Trace.ProviderPrompts 2 'The provider is asked once per finished cycle'
    Assert-Equal $providerResult.Trace.Runs.Count 2 'A provider yes starts a second cycle and its no stops'
    Assert-Equal $providerResult.ExitCode 0 'The provider path returns the final cycle exit code'

    foreach ($mode in @('SearchOnly', 'PlanOnly', 'NonInteractive', 'ExplicitKeys', 'Exception')) {
        $result = Invoke-RescanScenario -Mode $mode
        Assert-Equal $result.Trace.Prompts 0 ($mode + ' does not add an end-of-cycle prompt')
        Assert-Equal ($result.Trace.Disconnects -join ',') 'owned-session' ($mode + ' closes owned connections')
        if ($mode -eq 'Exception') { Assert-Equal $result.ExitCode 1 'An exception retains the failure exit code' }
    }
}
finally {
    # The absolute, uniquely named directory is the only recursive cleanup target.
    $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
    if ((Split-Path -Parent $resolvedTestRoot) -ne ([IO.Path]::GetTempPath()).TrimEnd('\')) { throw 'Unexpected test cleanup path' }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
Write-Host 'Rescan checks passed.'

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/GuestOpsLib.ps1')
. (Join-Path $repoRoot 'scripts/OrchestratorRuntime.ps1')
. (Join-Path $repoRoot 'scripts/PatchPlanModel.ps1')
. (Join-Path $repoRoot 'scripts/VMTargetLib.ps1')
. (Join-Path $repoRoot 'scripts/CredentialRecovery.ps1')
$failures = @()

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { $script:failures += ('{0}: expected {1}, got {2}' -f $Message, $Expected, $Actual) }
}

$tokens = $null
$parseErrors = $null
$orchestratorAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts/Invoke-GuestOpsPatchValidation.ps1'), [ref]$tokens, [ref]$parseErrors)
foreach ($functionName in @('Test-IsSuccessfulDiscoveryOutcome', 'New-DiscoveryRecord', 'New-DiscoveryRecordFromAgentRun', 'New-AgentFleetItem', 'Invoke-DiscoveryPhase', 'Get-SafeFileName', 'Invoke-GuestAgentFleet', 'Invoke-GuestOperationWithCredentialRecovery', 'New-GuestCredentialResolutionException', 'Get-GuestCredentialResolutionErrorKind', 'Get-GuestOperationFailureMetadata')) {
    $definition = $orchestratorAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

# N2: the orchestrator's own top-level catch, run under the preference the script sets. A bare
# Write-Error there re-throws under 'Stop', so neither the computed exit code nor the final exit
# is reached, and an in-session caller is left with whatever $LASTEXITCODE the local gates set: 0.
& {
    $topLevelTry = @($orchestratorAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })[-1]
    if ($null -eq $topLevelTry) {
        $script:failures += 'N2: the orchestrator top-level try statement was not found'
    }
    else {
        $catchBody = [string]@($topLevelTry.CatchClauses)[0].Body.Extent.Text
        $probe = [scriptblock]::Create("`$ErrorActionPreference = 'Stop'`n`$scriptExitCode = 0`ntry { throw 'synthetic phase failure' }`ncatch $catchBody`n`$scriptExitCode")
        $escaped = $null
        $exitCodeAfterCatch = $null
        try { $exitCodeAfterCatch = & $probe 2>$null }
        catch { $escaped = $_.Exception.Message }
        Assert-Equal $escaped $null 'N2: the top-level catch reports a phase failure without re-throwing it'
        Assert-Equal $exitCodeAfterCatch 1 'N2: the top-level catch leaves the computed exit code for the final exit'
    }
}

$tempRoot = [System.IO.Path]::GetTempPath().TrimEnd('\')
$testDirectory = Join-Path $tempRoot ('guestops-audit-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
try {
    & {
        $runId = '11111111111111111111111111111111'
        $fixture = @{ Status = $null; FleetResult = $null; Deletes = 0 }
        function Receive-GuestFile {
            param($FileManager, $VMView, $GuestAuth, $HostName, $CurlPath, $GuestPath, $LocalPath, $TimeoutSeconds)
            $content = if ($GuestPath.EndsWith('status.json')) { $fixture.Status | ConvertTo-Json -Depth 12 } else { 'synthetic agent log' }
            Set-Content -LiteralPath $LocalPath -Value $content -Encoding UTF8
        }
        function Invoke-GuestAgentFleet { return @($fixture.FleetResult) }
        $processManager = New-Object psobject
        $processManager | Add-Member ScriptMethod ListProcessesInGuest { param($VM, $Auth, $ProcessIds) return @() }
        $fileManager = New-Object psobject
        $fileManager | Add-Member ScriptMethod DeleteDirectoryInGuest { param($VM, $Auth, $Path, $Recursive) $fixture.Deletes++ }
        $handle = New-VMAgentCycleHandle -VMName 'fixture-vm' -RunId $runId -Mode SearchOnly -Managers ([pscustomobject]@{ ProcessManager = $processManager; FileManager = $fileManager }) -VMView ([pscustomobject]@{ MoRef = 'synthetic' }) -HostName 'esxi.invalid' -CurlPath 'unused' -ProcessId 123 -GuestStatusPath ('C:\ProgramData\PatchingGuestOps\' + $runId + '\status.json') -GuestLogPath ('C:\ProgramData\PatchingGuestOps\' + $runId + '\agent.log') -LocalStatusPath (Join-Path $testDirectory 'status.json') -LocalLogPath (Join-Path $testDirectory 'agent.log') -GuestWorkingDirectory 'C:\ProgramData\PatchingGuestOps' -GuestCycleDirectory ('C:\ProgramData\PatchingGuestOps\' + $runId)

        # Real collection and discovery must reject an unfinished artifact even when the process
        # exited, and must not turn an invalid timestamp harvested after timeout into Green.
        foreach ($case in @(
            [pscustomobject]@{ Name = 'missing finish time'; FinishedAt = $null; Process = [pscustomobject]@{ Completed = $true; ExitCode = 1 }; ResultKind = $null; Error = $null; ExpectedState = 'Failed' },
            [pscustomobject]@{ Name = 'invalid finish time after timeout'; FinishedAt = 'not-a-date'; Process = $null; ResultKind = 'Timeout'; Error = 'synthetic timeout'; ExpectedState = 'Failed' },
            [pscustomobject]@{ Name = 'confirmed completion after lost process'; FinishedAt = '2026-09-12T10:00:00Z'; Process = $null; ResultKind = 'Timeout'; Error = 'synthetic timeout'; ExpectedState = 'Green' }
        )) {
            $handle.Status = $null
            $fixture.Status = [pscustomobject]@{ runId = $runId; outcome = 'SearchOnly'; finishedAt = $case.FinishedAt; updates = @(); errors = @() }
            $payload = Complete-VMAgentCycle -Handle $handle -AgentResult $case.Process 3>$null
            $fixture.FleetResult = [pscustomobject]@{ VMName = 'fixture-vm'; Sequence = 1; Payload = $payload; ResultKind = $case.ResultKind; Error = $case.Error }
            $records = @(Invoke-DiscoveryPhase -TargetVMNames @('fixture-vm') -CycleOutputDirectory $testDirectory -MaxInFlight 1 -TimeoutSeconds 1 -PollSeconds 1 3>$null)
            $states = @(Get-VMPatchCompletionStates -DiscoveryRecords $records -UpdateGroups @())
            Assert-Equal $states[0].state $case.ExpectedState ('N4: ' + $case.Name)
            $saved = Get-Content -LiteralPath (Join-Path $testDirectory 'discovery.json') -Raw | ConvertFrom-Json
            Assert-Equal (Get-ObjectPropertyValue -InputObject @($saved)[0] -Path @('cleanupStatus')) 'Retained' ('N1: discovery saves cleanup status for ' + $case.Name)
            Assert-Equal ([string]::IsNullOrWhiteSpace([string](Get-ObjectPropertyValue -InputObject @($saved)[0] -Path @('cleanupReason')))) $false ('N1: discovery saves cleanup reason for ' + $case.Name)
        }

        $handle.Status = $null
        $fixture.Status = [pscustomobject]@{ runId = $runId; outcome = 'SearchOnly'; finishedAt = '2026-09-12T10:00:00Z'; updates = @(); errors = @() }
        $processResult = Test-VMAgentCycleComplete -Handle $handle
        $script:SuppressStepMessages = $true
        try {
            $retainedOutput = @(Complete-VMAgentCycle -Handle $handle -AgentResult $processResult 3>&1)
            $retainedWarnings = @($retainedOutput | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $retained = @($retainedOutput | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0]
            Assert-Equal $retained.CleanupStatus 'Retained' 'N1: a vanished process still cannot authorize deletion'
            Assert-Equal $fixture.Deletes 0 'N1: retained cycles are never deleted'
            Assert-Equal (@($retainedWarnings | Where-Object { [string]$_ -like '*fixture-vm*' -and [string]$_ -like ('*' + $runId + '*') }).Count -gt 0) $true 'N1: retention is visible even with step messages suppressed and identifies the cycle'
        }
        finally { $script:SuppressStepMessages = $false }

        # Cleanup diagnostics must also survive each early return in the apply result builder.
        foreach ($case in @(
            [pscustomobject]@{ Confirmed = $false; Process = $null; Outcome = 'Started' },
            [pscustomobject]@{ Confirmed = $true; Process = $null; Outcome = 'Failed' },
            [pscustomobject]@{ Confirmed = $true; Process = [pscustomobject]@{ Completed = $true; ExitCode = 1 }; Outcome = 'InstallFailed' }
        )) {
            $cycle = [pscustomobject]@{ AgentCompletionConfirmed = $case.Confirmed; AgentResult = $case.Process; CleanupStatus = 'Retained'; CleanupReason = 'synthetic retention reason'; Status = [pscustomobject]@{ outcome = $case.Outcome; finishedAt = '2026-09-12T10:00:00Z'; errors = @() } }
            $result = New-ApplyResultFromCycle -VMName 'fixture-vm' -Cycle $cycle 3>$null
            Assert-Equal (Get-RuntimePropertyValue -InputObject $result -Name 'cleanupStatus') 'Retained' ('N1: apply preserves cleanup for ' + $case.Outcome)
            Assert-Equal (Get-RuntimePropertyValue -InputObject $result -Name 'cleanupReason') 'synthetic retention reason' ('N1: apply preserves retention reason for ' + $case.Outcome)
        }
    }
    & {
        $fixture = @{ Calls = @(); Events = @(); FailHost = 'esxi-b.invalid' }
        function Get-ExactVM {
            param($Name)
            if ($Name -eq 'missing-vm') { throw 'synthetic VM not found' }
            $hostName = if ($Name -like 'vm-b*') { 'esxi-b.invalid' } else { 'esxi-a.invalid' }
            return [pscustomobject]@{ ExtensionData = [pscustomobject]@{ HostName = $hostName } }
        }
        function Assert-VMReadyForGuestOps { param($VM) }
        function Get-VMHostNameForTransfer { param($VMView) return $VMView.HostName }
        function Invoke-Curl {
            param($CurlPath, $Description, $Arguments)
            $fixture.Calls += ,@($Arguments)
            $fixture.Events += 'probe'
            if (@($Arguments) -contains ('https://' + $fixture.FailHost + '/')) { throw 'synthetic certificate verification failure' }
        }
        function New-GuestAuthentication { param($Credential) return [pscustomobject]@{ UserName = 'synthetic' } }
        function Start-VMAgentCycle {
            param($VMName, $Managers, $GuestAuth, $CurlPath, $AgentPath, $IdentityHelperPath, $GuestWorkingDirectory, $VMOutputDirectory, $MaxUpdates, $LocalSelectionPath, [switch]$SearchOnly)
            if ($VMName -eq 'missing-vm') { throw 'synthetic VM not found' }
            $fixture.Events += ('start:' + $VMName)
            return [pscustomobject]@{ VMName = $VMName; AgentResult = $null; GuestAuth = $GuestAuth }
        }
        function Test-VMAgentCycleComplete { param($Handle) return [pscustomobject]@{ Completed = $true; ExitCode = 0 } }
        function Complete-VMAgentCycle { param($Handle, $AgentResult) return [pscustomobject]@{ AgentCompletionConfirmed = $true } }
        # Two VMs per host: a host verdict has to be reached once and then reused, and a host that
        # fails its check must fail exactly the VMs on it - the rest of the fleet is none of its
        # business. One bad host used to end discovery or apply for every VM in the run.
        $items = @('vm-a1', 'vm-b1', 'vm-a2', 'vm-b2', 'missing-vm' | ForEach-Object {
            New-AgentFleetItem -VMName $_ -Sequence 1 -VMOutputDirectory 'unused' -MaxUpdates 1 -SearchOnly $true
        })
        $credentials = @{ 'vm-a1' = $null; 'vm-a2' = $null; 'vm-b1' = $null; 'vm-b2' = $null; 'missing-vm' = $null }
        $probeError = ''
        $results = @()
        try {
            $results = @(Invoke-GuestAgentFleet -FleetItems $items -GuestCredentialMap $credentials -CurlPath 'unused' -TimeoutSeconds 30 -PollSeconds 1 -MaxInFlight 4)
        }
        catch { $probeError = $_.Exception.Message }
        Assert-Equal $probeError '' 'N3: one untrusted ESXi does not abort the phase'
        # Successful fleet results carry no ResultKind, so read it defensively under StrictMode.
        $hostFailures = @($results | Where-Object { [string](Get-ObjectPropertyValue -InputObject $_ -Path @('ResultKind')) -eq 'StartError' -and [string]$_.Error -like '*esxi-b.invalid*' })
        Assert-Equal $hostFailures.Count 2 'N3: preflight fails every VM on the untrusted ESXi and names the host'
        Assert-Equal ((@($hostFailures | ForEach-Object { [string]$_.VMName }) | Sort-Object) -join ',') 'vm-b1,vm-b2' 'N3: only the VMs on the untrusted ESXi are failed'
        Assert-Equal ($fixture.Events -join ',') 'probe,probe,start:vm-a1,start:vm-a2' 'N3: VMs on a healthy ESXi still start, after every endpoint check'
        Assert-Equal $fixture.Calls.Count 2 'N3: each unique ESXi is checked once, a failing one included'

        $fixture.Calls = @(); $fixture.Events = @(); $fixture.FailHost = ''
        $results = @(Invoke-GuestAgentFleet -FleetItems $items -GuestCredentialMap $credentials -CurlPath 'unused' -TimeoutSeconds 30 -PollSeconds 1 -MaxInFlight 4)
        Assert-Equal ($fixture.Events -join ',') 'probe,probe,start:vm-a1,start:vm-b1,start:vm-a2,start:vm-b2' 'N3: all endpoint checks finish before guest work; shared hosts are deduplicated'
        Assert-Equal @($results | Where-Object { $_.VMName -eq 'missing-vm' -and $_.ResultKind -eq 'StartError' }).Count 1 'N3: an inventory failure remains isolated to its VM'
        Assert-Equal @($results | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Error) }).Count 4 'N3: valid peers still complete when one VM cannot be resolved'
        foreach ($arguments in $fixture.Calls) {
            Assert-Equal $arguments[0] '--disable' 'N3: curl configuration cannot override the certificate probe'
            Assert-Equal ($arguments -contains '--head') $true 'N3: certificate probe requests no file content'
            Assert-Equal ($arguments -contains '--fail') $false 'N3: HTTP access errors after successful TLS are not certificate failures'
            Assert-Equal ($arguments -contains '--insecure' -or $arguments -contains '-k') $false 'N3: certificate verification is never bypassed'
            Assert-Equal @($arguments | Where-Object { $_ -eq '--max-time' }).Count 1 'N3: certificate probe has one bounded deadline'
        }

        # A prior successful VM can remain a target after another member of its account was
        # skipped. Credentials are resolved before the probe, so that account costs no ESXi check.
        $credential = New-Object System.Management.Automation.PSCredential('synthetic', (ConvertTo-SecureString 'synthetic' -AsPlainText -Force))
        $context = New-GuestCredentialContext -TargetNames @('vm-a1', 'vm-b.corp.invalid', 'vm-b2.corp.invalid') -CredentialMap @{ 'vm-a1' = $credential; 'vm-b.corp.invalid' = $credential; 'vm-b2.corp.invalid' = $credential }
        $credentialItems = @($items[0], (New-AgentFleetItem -VMName 'vm-b.corp.invalid' -Sequence 2 -VMOutputDirectory 'unused' -MaxUpdates 1 -SearchOnly $true))
        $skippedGroup = Get-GuestCredentialGroupForTarget -Context $context -VMName 'vm-b2.corp.invalid'
        $context.SkippedAccountKeys[(Get-GuestCredentialAccountKey -Group $skippedGroup)] = $true
        $context.ValidatedTargets['vm-b.corp.invalid'] = $true
        $fixture.Calls = @(); $fixture.Events = @(); $fixture.FailHost = 'esxi-b.invalid'
        function Test-GuestCredentialForTarget {
            param($VMName, $Credential)
            return [pscustomobject]@{ Status = 'Valid'; Error = $null; ErrorKind = $null }
        }
        $results = @(); $probeError = ''
        try {
            $results = @(Invoke-GuestAgentFleet -FleetItems $credentialItems -CredentialContext $context -CurlPath 'unused' -TimeoutSeconds 30 -PollSeconds 1 -MaxInFlight 4)
        }
        catch { $probeError = $_.Exception.Message }
        Assert-Equal $probeError '' 'N3: an already skipped account does not surface as a phase error'
        Assert-Equal ($fixture.Events -join ',') 'probe,start:vm-a1' 'N3: only active account targets are probed and started'
        Assert-Equal @($results | Where-Object { $_.VMName -eq 'vm-a1' -and [string]::IsNullOrWhiteSpace([string]$_.Error) }).Count 1 'N3: an unrelated active account completes normally'
        Assert-Equal @($results | Where-Object { $_.VMName -eq 'vm-b.corp.invalid' -and $_.ErrorKind -eq 'CredentialsSkipped' -and $_.RejectedBeforeStart }).Count 1 'N3: skipped preflight preserves typed credential failure metadata'

        $context.Aborted = $true
        $fixture.Calls = @(); $fixture.Events = @(); $probeError = ''
        try {
            $results = @(Invoke-GuestAgentFleet -FleetItems $credentialItems -CredentialContext $context -CurlPath 'unused' -TimeoutSeconds 30 -PollSeconds 1 -MaxInFlight 4)
        }
        catch { $probeError = $_.Exception.Message }
        Assert-Equal $probeError '' 'N3: an aborted credential context does not contact ESXi'
        Assert-Equal $fixture.Events.Count 0 'N3: abort prevents both endpoint probes and agent starts'
        Assert-Equal @($results | Where-Object { $_.ErrorKind -eq 'CredentialsAborted' -and $_.RejectedBeforeStart }).Count 2 'N3: abort remains a typed result for each target'
    }
}
finally {
    $resolvedTestDirectory = [System.IO.Path]::GetFullPath($testDirectory)
    if ((Split-Path -Parent $resolvedTestDirectory) -ne $tempRoot -or (Split-Path -Leaf $resolvedTestDirectory) -notlike 'guestops-audit-*') { throw 'Refusing to remove a path outside the audit test directory.' }
    Remove-Item -LiteralPath $resolvedTestDirectory -Recurse -Force
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host ('FAIL: ' + $failure) }
    exit 1
}
Write-Host 'Audit follow-up checks passed.'
exit 0

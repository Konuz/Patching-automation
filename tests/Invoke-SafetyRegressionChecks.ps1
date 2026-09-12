Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/GuestOpsLib.ps1')
. (Join-Path $repoRoot 'scripts/VMTargetLib.ps1')
. (Join-Path $repoRoot 'scripts/CredentialRecovery.ps1')
. (Join-Path $repoRoot 'scripts/PatchPlanModel.ps1')
. (Join-Path $repoRoot 'scripts/OrchestratorRuntime.ps1')
$failures = @()
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { $script:failures += ('{0}: expected {1}, got {2}' -f $Message, $Expected, $Actual) }
}

# Offline error fixtures carry the production type names as PowerShell type-name
# metadata, so these tests never force-load VMware assemblies.
function New-ErrorTypeFixture {
    param(
        [string]$TypeName,
        $InnerException = $null,
        $Fault = $null,
        $Status = $null
    )

    $fixture = [pscustomobject]@{
        InnerException = $InnerException
        Fault = $Fault
        Status = $Status
    }
    $fixture.PSTypeNames.Insert(0, $TypeName)
    return $fixture
}

$guestUnavailable = New-ErrorTypeFixture -TypeName 'VMware.Vim.GuestOperationsUnavailable'
$wrappedGuestUnavailable = [pscustomobject]@{
    Exception = (New-ErrorTypeFixture -TypeName 'System.Exception' -InnerException $guestUnavailable)
}
Assert-Equal (Get-GuestOperationErrorKind -ErrorRecord $wrappedGuestUnavailable) 'Transient' 'GuestOperationsUnavailable in InnerException is transient'

$taskInProgressFault = New-ErrorTypeFixture -TypeName 'VMware.Vim.TaskInProgress'
$runtimeFaultWithTransient = New-ErrorTypeFixture -TypeName 'VMware.Vim.RuntimeFault' -Fault $taskInProgressFault
Assert-Equal (Get-GuestOperationErrorKind -ErrorRecord ([pscustomobject]@{ Exception = $runtimeFaultWithTransient })) 'Transient' 'only a known transient VMware fault is transient'

$runtimeFault = New-ErrorTypeFixture -TypeName 'VMware.Vim.RuntimeFault'
Assert-Equal (Get-GuestOperationErrorKind -ErrorRecord ([pscustomobject]@{ Exception = $runtimeFault })) 'Permanent' 'an unspecified RuntimeFault is permanent'

$invalidLogin = New-ErrorTypeFixture -TypeName 'VMware.Vim.InvalidGuestLogin'
$wrappedInvalidLogin = [pscustomobject]@{ Exception = (New-ErrorTypeFixture -TypeName 'System.Exception' -InnerException $invalidLogin) }
Assert-Equal (Get-GuestOperationErrorKind -ErrorRecord $wrappedInvalidLogin) 'InvalidCredentials' 'InvalidGuestLogin has its own class'

$permissionDenied = New-ErrorTypeFixture -TypeName 'VMware.Vim.GuestPermissionDenied'
Assert-Equal (Get-GuestOperationErrorKind -ErrorRecord ([pscustomobject]@{ Exception = $permissionDenied })) 'Permanent' 'GuestPermissionDenied is permanent'

$timeoutFixture = New-ErrorTypeFixture -TypeName 'System.TimeoutException'
Assert-Equal (Get-GuestOperationErrorKind -ErrorRecord ([pscustomobject]@{ Exception = $timeoutFixture })) 'Transient' 'TimeoutException is transient'

$webTimeout = New-ErrorTypeFixture -TypeName 'System.Net.WebException' -Status 'Timeout'
Assert-Equal (Get-GuestOperationErrorKind -ErrorRecord ([pscustomobject]@{ Exception = $webTimeout })) 'Transient' 'selected WebException timeout is transient'

$webTrustFailure = New-ErrorTypeFixture -TypeName 'System.Net.WebException' -Status 'TrustFailure'
Assert-Equal (Get-GuestOperationErrorKind -ErrorRecord ([pscustomobject]@{ Exception = $webTrustFailure })) 'Permanent' 'WebException trust failure is not transient'

$unknownError = New-ErrorTypeFixture -TypeName 'System.InvalidOperationException'
Assert-Equal (Get-GuestOperationErrorKind -ErrorRecord ([pscustomobject]@{ Exception = $unknownError })) 'Permanent' 'unknown errors are permanent'

# Exercise the actual lookup against a fake inventory, including a full-name/short-name collision.
& {
    function Get-VM {
        param($Name)
        @($inventory | Where-Object { $_.Name -eq $Name })
    }
    $wrongVM = [pscustomobject]@{ Name = 'server'; ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ HostName = 'server.other.invalid' } } }
    $rightVM = [pscustomobject]@{ Name = 'server.target.invalid'; ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ HostName = 'server.target.invalid' } } }
    $inventory = @($wrongVM, $rightVM)
    Assert-Equal (Get-ExactVM -Name 'server.target.invalid').Name 'server.target.invalid' 'full inventory name wins over an unrelated short name'

    foreach ($guestName in @('server.other.invalid', '', 'server', 'SERVER.TARGET.INVALID.')) {
        $inventory = @([pscustomobject]@{ Name = 'server'; ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ HostName = $guestName } } })
        $accepted = $false
        try { $null = Get-ExactVM -Name 'server.target.invalid'; $accepted = $true } catch { }
        Assert-Equal $accepted ($guestName -eq 'SERVER.TARGET.INVALID.') ('short-name fallback requires the requested guest FQDN: ' + $guestName)
    }
    $inventory = @([pscustomobject]@{ Name = 'server' })
    $accepted = $false
    try { $null = Get-ExactVM -Name 'server.target.invalid'; $accepted = $true } catch { }
    Assert-Equal $accepted $false 'missing VMware Tools hostname cannot authorize an FQDN fallback'
    Assert-Equal (Get-ExactVM -Name 'server').Name 'server' 'explicit bare inventory name remains supported'
    foreach ($inventory in @(@($rightVM, $rightVM), @())) {
        $accepted = $false
        try { $null = Get-ExactVM -Name 'server.target.invalid'; $accepted = $true } catch { }
        Assert-Equal $accepted $false 'ambiguous or missing inventory target is rejected'
    }
}

# Load the real agent body and discovery adapter without running either script's entry point.
$tokens = $null; $parseErrors = $null
$agentAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'guest/Run-LocalPatch.ps1'), [ref]$tokens, [ref]$parseErrors)
$orchestratorAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts/Invoke-GuestOpsPatchValidation.ps1'), [ref]$tokens, [ref]$parseErrors)
foreach ($tree in @($agentAst, $orchestratorAst)) {
    foreach ($definition in @($tree.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}
$agentTry = @($agentAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })[0]
$statusInit = @($agentAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$status' })[0]

function Invoke-AgentFixture {
    param([int]$SearchCode = 2, [bool]$Cluster = $false, [bool]$Empty = $false, [switch]$SearchOnly, [bool]$PendingReboot = $false)
    # Only external effects are mocked: local probes, artifact I/O, and WUA COM.
    function Write-AgentLog { param($Message) }
    function Save-Status { param($Status) }
    function Test-IsElevated { $true }
    function Get-ServiceSnapshot { @() }
    function Get-SystemDriveFreeGB { 100 }
    function Test-PendingReboot { [pscustomobject]@{ isPending = $PendingReboot } }
    function Get-RoleFlags { [pscustomobject]@{ failoverCluster = $Cluster } }
    function Read-SelectionDocumentKeys { param($Path) '11111111-1111-1111-1111-111111111111|1' }
    $update = [pscustomobject]@{
        Identity = [pscustomobject]@{ UpdateID = '11111111-1111-1111-1111-111111111111'; RevisionNumber = 1 }
        Title = 'Security Update'; KBArticleIDs = $null; Categories = $null
        InstallationBehavior = [pscustomobject]@{ RebootBehavior = 0 }
        EulaAccepted = $true; IsDownloaded = $true; Type = 1; MsrcSeverity = 'Critical'
    }
    $updates = [pscustomobject]@{ Count = $(if ($Empty) { 0 } else { 1 }); Value = $update }
    $updates | Add-Member ScriptMethod Item { param($Index) $this.Value }
    $warnings = [pscustomobject]@{ Count = $(if ($SearchCode -eq 3) { 1 } else { 0 }) }
    $warnings | Add-Member ScriptMethod Item { param($Index) [pscustomobject]@{ Message = 'Search results incomplete'; HResult = -2145124338; Context = 1 } }
    $searcher = [pscustomobject]@{ ClientApplicationID = ''; Value = [pscustomobject]@{ ResultCode = $SearchCode; Updates = $updates; Warnings = $warnings } }
    $searcher | Add-Member ScriptMethod Search { param($Criteria) $this.Value }
    $operationResult = [pscustomobject]@{ ResultCode = 2; RebootRequired = $PendingReboot }
    $operationResult | Add-Member ScriptMethod GetUpdateResult { param($Index) [pscustomobject]@{ ResultCode = 2; RebootRequired = $false } }
    $downloader = [pscustomobject]@{ ClientApplicationID = ''; Updates = $null; Value = $operationResult; Called = $false }
    $downloader | Add-Member ScriptMethod Download { $this.Called = $true; $this.Value }
    $installer = [pscustomobject]@{ ClientApplicationID = ''; Updates = $null; AllowSourcePrompts = $true; Called = $false; Value = $operationResult }
    $installer | Add-Member ScriptMethod Install { $this.Called = $true; $this.Value }
    $session = [pscustomobject]@{ ClientApplicationID = ''; Searcher = $searcher; Downloader = $downloader; Installer = $installer }
    $session | Add-Member ScriptMethod CreateUpdateSearcher { $this.Searcher }
    $session | Add-Member ScriptMethod CreateUpdateDownloader { $this.Downloader }
    $session | Add-Member ScriptMethod CreateUpdateInstaller { $this.Installer }
    $collection = [pscustomobject]@{ Count = 0 }
    $collection | Add-Member ScriptMethod Add { param($Value) $this.Count++; return ($this.Count - 1) }
    function New-Object {
        param([Parameter(Position = 0)][string]$TypeName, [string]$ComObject)
        if (-not $PSBoundParameters.ContainsKey('ComObject')) {
            return Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
        }
        switch ($ComObject) {
            'Microsoft.Update.Session' { $session }
            'Microsoft.Update.UpdateColl' { $collection }
            default { throw "Unexpected object request: $ComObject" }
        }
    }
    $RunId = 'fixture'; $WorkingDirectory = 'unused'; $SearchCriteria = 'IsInstalled=0'; $MaxUpdates = 1
    $SelectedUpdateKeys = @(); $SelectionPath = 'mock-selection.json'; $scriptExitCode = 1
    . ([scriptblock]::Create($statusInit.Extent.Text))
    . ([scriptblock]::Create($agentTry.Extent.Text))
    # Model the same JSON boundary as a downloaded status.json.
    $payload = $status | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $cycle = [pscustomobject]@{ Status = $payload; AgentResult = [pscustomobject]@{ Completed = $true; ExitCode = $scriptExitCode } }
    $discovery = New-DiscoveryRecordFromAgentRun -VMName 'fixture' -AgentRun $cycle -OutputDirectory 'unused'
    $groups = @(New-UpdateGroupRecords -DiscoveryRecords @($discovery))
    $states = @(Get-VMPatchCompletionStates -DiscoveryRecords @($discovery) -UpdateGroups $groups)
    [pscustomobject]@{ Status = $payload; ExitCode = $scriptExitCode; InstallCalled = $installer.Called; DownloadCalled = $downloader.Called; State = $states[0].state; Cycle = $cycle }
}

foreach ($searchCode in @(0, 1, 3, 4, 5, 99)) {
    foreach ($empty in @($true, $false)) {
        $scan = Invoke-AgentFixture -SearchCode $searchCode -Empty $empty -SearchOnly
        Assert-Equal $scan.ExitCode 1 ('incomplete search is an error, code ' + $searchCode + ', empty ' + $empty)
        Assert-Equal $scan.State 'Failed' 'incomplete discovery cannot become Green or feed an install plan'
        Assert-Equal $scan.DownloadCalled $false 'search-only never downloads updates'
    }
    $apply = Invoke-AgentFixture -SearchCode $searchCode
    Assert-Equal $apply.DownloadCalled $false ('failed search blocks download, code ' + $searchCode)
    Assert-Equal $apply.InstallCalled $false ('failed search blocks install, code ' + $searchCode)
}
$partial = Invoke-AgentFixture -SearchCode 3 -Empty $true -SearchOnly
$searchWarnings = @(Get-ObjectPropertyValue -InputObject $partial.Status -Path @('searchResult', 'warnings') -DefaultValue @())
Assert-Equal $searchWarnings.Count 1 'WUA search warnings survive in status.json'
if ($searchWarnings.Count -eq 1) {
    Assert-Equal $searchWarnings[0].message 'Search results incomplete' 'search warning message is retained'
    Assert-Equal $searchWarnings[0].hResult '0x8024000E' 'search warning HRESULT is retained'
    Assert-Equal $searchWarnings[0].context 1 'search warning context is retained'
}
$emptyScan = Invoke-AgentFixture -Empty $true -SearchOnly
Assert-Equal $emptyScan.ExitCode 0 'complete empty scan remains successful'
Assert-Equal $emptyScan.State 'Green' 'complete empty scan remains Green'
$ordinaryApply = Invoke-AgentFixture -PendingReboot $true
Assert-Equal $ordinaryApply.InstallCalled $true 'ordinary selected updates still reach WUA install'
Assert-Equal $ordinaryApply.Status.outcome 'InstallSucceeded' 'ordinary successful installation stays successful'
Assert-Equal $ordinaryApply.ExitCode 0 'ordinary successful installation exits zero'

$clusterApply = Invoke-AgentFixture -Cluster $true -PendingReboot $true
Assert-Equal $clusterApply.DownloadCalled $false 'current cluster role blocks download from a saved selection'
Assert-Equal $clusterApply.InstallCalled $false 'current cluster role blocks install from a saved selection'
Assert-Equal $clusterApply.ExitCode 1 'stale plan targeting a cluster exits nonzero'
Assert-Equal (@($clusterApply.Status.errors).Count -gt 0) $true 'cluster rejection reports its cause'
# Test every process-result path: known error exit, lost result, and unavailable exit code.
foreach ($processResult in @($clusterApply.Cycle.AgentResult, $null, [pscustomobject]@{ Completed = $true; ExitCode = $null })) {
    $cycle = [pscustomobject]@{
        RunId = $clusterApply.Status.runId
        Mode = 'Apply'
        AgentCompletionConfirmed = $true
        AgentCompletionReason = 'synthetic terminal cluster failure'
        Status = $clusterApply.Status
        AgentResult = $processResult
    }
    $applyResult = New-ApplyResultFromCycle -VMName 'fixture' -Cycle $cycle
    Assert-Equal $applyResult.action 'Install' 'cluster fixture remains an Install result before role protection'
    Assert-Equal $applyResult.agentCompletionConfirmed $true 'cluster fixture is terminal before testing role protection'
    Assert-Equal $applyResult.rebootRequired $true 'cluster fixture carries a reboot signal before role protection'
    Assert-Equal $applyResult.roleFlags.failoverCluster $true 'cluster fixture preserves the failover-cluster role flag'
    Assert-Equal (@(Select-RebootRequiredApplyResults -ApplyResults @($applyResult)).Count) 0 'cluster detected by apply is excluded from reboot without discovery records'
    Assert-Equal (Test-ApplyResultsSuccessful -ApplyResults @($applyResult)) $false 'cluster installation rejection cannot be reported as success'
}
$clusterScan = Invoke-AgentFixture -Cluster $true -SearchOnly
Assert-Equal $clusterScan.ExitCode 0 'cluster search-only remains available for discovery'
Assert-Equal $clusterScan.State 'Excluded' 'cluster discovery still drives the planning exclusion'
Assert-Equal $clusterScan.InstallCalled $false 'cluster discovery never installs'

# F2: a lost process result plus an unfinished status must not qualify the VM for reboot.
# These doubles stay in this test so the regression has no dependency on ignored out/ files.
& {
    $cycleDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-f2-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $cycleDirectory | Out-Null
    $localStatusPath = Join-Path $cycleDirectory 'status.json'
    $localLogPath = Join-Path $cycleDirectory 'agent.log'
    $script:f2StatusJson = '{"runId":"fixture-run","outcome":"Started","finishedAt":null,"errors":[]}'
    $script:f2StatusReads = 0
    $script:f2ThrowWrappedMissing = $false
    $processManager = New-Object psobject
    $processManager | Add-Member -MemberType ScriptMethod -Name ListProcessesInGuest -Value {
        param($MoRef, $Auth, $ProcessIds)
        return @()
    }
    $handle = New-VMAgentCycleHandle -VMName 'fixture-vm' -RunId 'fixture-run' -Managers ([pscustomobject]@{ ProcessManager = $processManager; FileManager = $null }) -VMView ([pscustomobject]@{ MoRef = 'fake' }) -GuestAuth $null -HostName 'unused' -CurlPath 'unused' -ProcessId 123 -GuestStatusPath 'status.json' -GuestLogPath 'agent.log' -LocalStatusPath $localStatusPath -LocalLogPath $localLogPath

    function Receive-GuestFile {
        param($FileManager, $VMView, $GuestAuth, $HostName, $CurlPath, $GuestPath, $LocalPath, $TimeoutSeconds)
        if ($GuestPath -eq 'status.json') {
            $script:f2StatusReads++
            if ($script:f2ThrowWrappedMissing) {
                $fileNotFound = New-Object System.IO.FileNotFoundException -ArgumentList 'status.json is not ready'
                $runtimeWrapper = New-Object System.Management.Automation.RuntimeException -ArgumentList @('runtime wrapper', $fileNotFound)
                throw (New-Object System.Management.Automation.MethodInvocationException -ArgumentList @('method wrapper', $runtimeWrapper))
            }
            if ($null -ne $script:f2StatusJson) {
                $script:f2StatusJson | Set-Content -LiteralPath $LocalPath -Encoding UTF8
            }
        }
        else {
            'synthetic agent log' | Set-Content -LiteralPath $LocalPath -Encoding UTF8
        }
    }

    try {
        $processResult = Test-VMAgentCycleComplete -Handle $handle
        $cycle = Complete-VMAgentCycle -Handle $handle -AgentResult $processResult
        $applyResult = New-ApplyResultFromCycle -VMName 'fixture-vm' -Cycle $cycle
        $discovery = @([pscustomobject]@{ vmName = 'fixture-vm'; outcome = 'SearchOnly'; pendingRebootBefore = [pscustomobject]@{ isPending = $true } })
        $targets = @(Select-RebootRequiredApplyResults -ApplyResults @($applyResult) -DiscoveryRecords $discovery)
        Assert-Equal ($null -eq $processResult) $true 'F2: an empty process list with Started status keeps polling'
        Assert-Equal $applyResult.outcome 'Failed' 'F2: Started status becomes an apply failure'
        Assert-Equal $targets.Count 0 'F2: an unfinished apply is not a reboot target even with pending reboot before apply'

        $wrappedMissingDirectory = Join-Path $cycleDirectory 'wrapped-missing'
        New-Item -ItemType Directory -Force -Path $wrappedMissingDirectory | Out-Null
        $wrappedProcessManager = New-Object psobject
        $wrappedProcessManager | Add-Member -MemberType ScriptMethod -Name ListProcessesInGuest -Value {
            param($MoRef, $Auth, $ProcessIds)
            return @()
        }
        $wrappedHandle = New-VMAgentCycleHandle -VMName 'fixture-vm' -RunId 'fixture-run' -Managers ([pscustomobject]@{ ProcessManager = $wrappedProcessManager; FileManager = $null }) -VMView ([pscustomobject]@{ MoRef = 'fake' }) -GuestAuth $null -HostName 'unused' -CurlPath 'unused' -ProcessId 123 -GuestStatusPath 'status.json' -GuestLogPath 'agent.log' -LocalStatusPath (Join-Path $wrappedMissingDirectory 'status.json') -LocalLogPath (Join-Path $wrappedMissingDirectory 'agent.log')
        $script:f2StatusReads = 0
        $script:f2ThrowWrappedMissing = $true
        $wrappedMissingResult = $null
        $wrappedMissingThrew = $false
        try { $wrappedMissingResult = Test-VMAgentCycleComplete -Handle $wrappedHandle } catch { $wrappedMissingThrew = $true }
        Assert-Equal $wrappedMissingThrew $false 'F2: wrapped missing status is treated as an in-progress cycle'
        Assert-Equal ($null -eq $wrappedMissingResult) $true 'F2: wrapped missing status returns no terminal process result'
        Assert-Equal $script:f2StatusReads 1 'F2: wrapped missing status performs one status read'
        $script:f2ThrowWrappedMissing = $false
        Remove-Item -LiteralPath $wrappedMissingDirectory -Recurse -Force -ErrorAction SilentlyContinue

        $f2StatusCases = @(
            [pscustomobject]@{ Name = 'terminal'; Json = '{"runId":"fixture-run","outcome":"InstallSucceeded","finishedAt":"2026-09-11T10:00:00Z","errors":[]}'; Expected = $true },
            [pscustomobject]@{ Name = 'foreign runId'; Json = '{"runId":"other-run","outcome":"InstallSucceeded","finishedAt":"2026-09-11T10:00:00Z","errors":[]}'; Expected = $false },
            [pscustomobject]@{ Name = 'Started'; Json = '{"runId":"fixture-run","outcome":"Started","finishedAt":null,"errors":[]}'; Expected = $false },
            [pscustomobject]@{ Name = 'malformed status'; Json = '{not-json'; Expected = $false },
            [pscustomobject]@{ Name = 'missing status'; Json = $null; Expected = $false }
        )
        foreach ($f2StatusCase in $f2StatusCases) {
            $caseDirectory = Join-Path $cycleDirectory ('case-' + $f2StatusCase.Name.Replace(' ', '-'))
            New-Item -ItemType Directory -Force -Path $caseDirectory | Out-Null
            $caseProcessManager = New-Object psobject
            $script:f2ListCalls = 0
            $caseProcessManager | Add-Member -MemberType ScriptMethod -Name ListProcessesInGuest -Value {
                param($MoRef, $Auth, $ProcessIds)
                $script:f2ListCalls++
                return @()
            }
            $caseHandle = New-VMAgentCycleHandle -VMName 'fixture-vm' -RunId 'fixture-run' -Managers ([pscustomobject]@{ ProcessManager = $caseProcessManager; FileManager = $null }) -VMView ([pscustomobject]@{ MoRef = 'fake' }) -GuestAuth $null -HostName 'unused' -CurlPath 'unused' -ProcessId 123 -GuestStatusPath 'status.json' -GuestLogPath 'agent.log' -LocalStatusPath (Join-Path $caseDirectory 'status.json') -LocalLogPath (Join-Path $caseDirectory 'agent.log')
            $script:f2StatusJson = $f2StatusCase.Json
            $script:f2StatusReads = 0
            $caseResult = Test-VMAgentCycleComplete -Handle $caseHandle
            Assert-Equal ($null -ne $caseResult) $f2StatusCase.Expected ('F2: empty process list status case ' + $f2StatusCase.Name)
            Assert-Equal $script:f2ListCalls 1 ('F2: status case polls the process list once: ' + $f2StatusCase.Name)
            Assert-Equal $script:f2StatusReads 1 ('F2: status case reads status once: ' + $f2StatusCase.Name)
            if ($f2StatusCase.Expected) {
                Assert-Equal $caseResult.Completed $false 'F2: recovered terminal status has no process exit code'
                Assert-Equal $caseHandle.Status.runId 'fixture-run' 'F2: recovered status remains in the cycle handle'
            }
            Remove-Item -LiteralPath $caseDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }

        function Invoke-GuestAgentFleet {
            param($FleetItems, $Managers, $GuestCredentialMap, $CurlPath, $AgentPath, $IdentityHelperPath, $GuestWorkingDirectory, $TimeoutSeconds, $PollSeconds, $MaxInFlight, $CredentialContext, $CredentialDecisionScript, $CredentialValidatedScript, $CredentialInteractive)
            return $script:failedFleet
        }
        function Write-PatchingSummary { param($ApplyResults) }
        function Write-FinalReport { param($PatchPlanRecords, $ApplyResults, $CycleOutputDirectory, $RebootTargets) }
        function Confirm-GuestReboot { param($RebootTargets) $true }
        function Write-RebootActionArtifacts { param($CycleOutputDirectory, $RebootActions) }
        $script:rebootDispatchCount = 0
        function Invoke-GuestRebootPhase {
            param(
                $RebootTargets,
                $GuestCredentialMap,
                [string[]]$VIServers,
                $VIServerCredentialMap,
                [switch]$IgnoreVCenterCertificate,
                [string]$GuestOpsLibPath,
                [string]$CurlPath,
                [string]$GuestWorkingDirectory,
                [int]$RebootTimeoutSeconds,
                [int]$PollSeconds,
                [int]$RebootBatchSize
            )
            $script:rebootDispatchCount += @($RebootTargets).Count
            return @()
        }
        $script:failedFleet = @([pscustomobject]@{ Sequence = 1; VMName = 'fixture-vm'; Payload = $null; Error = 'simulated poll error'; ResultKind = 'Timeout' })
        $plan = @([pscustomobject]@{ vmName = 'fixture-vm'; action = 'Install'; selectedUpdates = @([pscustomobject]@{ identityKey = '11111111-1111-1111-1111-111111111111|1' }) })
        $phaseDirectory = Join-Path $cycleDirectory 'apply'
        New-Item -ItemType Directory -Force -Path $phaseDirectory | Out-Null
        $phaseResult = Invoke-ApplyAndOptionalReboot -PatchPlanRecords $plan -Managers $null -GuestCredentialMap @{} -VIServers @() -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -AgentPath 'unused' -IdentityHelperPath 'unused' -GuestWorkingDirectory 'C:\unused' -TimeoutSeconds 1 -RebootTimeoutSeconds 1 -PollSeconds 1 -CycleOutputDirectory $phaseDirectory -ThrottleLimit 1 -RebootBatchSize 1 -DiscoveryRecords $discovery
        Assert-Equal $script:rebootDispatchCount 0 'F2: a poll error never dispatches a reboot after operator approval'
        Assert-Equal $phaseResult.ExitCode 1 'F2: the poll error remains an unsuccessful apply run'
        Assert-Equal $phaseResult.ApplyResults[0].reason 'simulated poll error' 'F2: a timeout without payload preserves its original error'

        $permanentPollCycle = [pscustomobject]@{
            RunId = 'permanent-poll-run'
            Mode = 'Apply'
            AgentCompletionConfirmed = $true
            AgentCompletionReason = 'synthetic terminal status'
            AgentResult = [pscustomobject]@{ Completed = $true; ExitCode = 0 }
            Status = [pscustomobject]@{
                runId = 'permanent-poll-run'
                outcome = 'InstallSucceeded'
                finishedAt = '2026-09-11T10:00:00Z'
                installResult = [pscustomobject]@{ rebootRequired = $true }
                pendingRebootAfter = [pscustomobject]@{ isPending = $false }
                roleFlags = [pscustomobject]@{ failoverCluster = $false }
                errors = @()
            }
        }
        $script:failedFleet = @([pscustomobject]@{
            Sequence = 1
            VMName = 'fixture-vm'
            Payload = $permanentPollCycle
            Error = 'permanent process-list failure'
            ResultKind = 'PermanentPoll'
        })
        $script:rebootDispatchCount = 0
        $permanentPhaseDirectory = Join-Path $cycleDirectory 'permanent-poll'
        New-Item -ItemType Directory -Force -Path $permanentPhaseDirectory | Out-Null
        $permanentPhaseResult = Invoke-ApplyAndOptionalReboot -PatchPlanRecords $plan -Managers $null -GuestCredentialMap @{} -VIServers @() -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -AgentPath 'unused' -IdentityHelperPath 'unused' -GuestWorkingDirectory 'C:\unused' -TimeoutSeconds 1 -RebootTimeoutSeconds 1 -PollSeconds 1 -CycleOutputDirectory $permanentPhaseDirectory -ThrottleLimit 1 -RebootBatchSize 1 -DiscoveryRecords @()
        $permanentApplyResult = @($permanentPhaseResult.ApplyResults)[0]
        Assert-Equal $permanentPhaseResult.ExitCode 1 'F2: permanent poll error with a payload keeps the apply run unsuccessful'
        Assert-Equal $permanentApplyResult.outcome 'Failed' 'F2: permanent poll error cannot inherit InstallSucceeded from the payload'
        Assert-Equal (@($permanentApplyResult.errors).Count -gt 0) $true 'F2: permanent poll error remains in the final apply record'
        Assert-Equal $permanentApplyResult.reason 'permanent process-list failure' 'F2: permanent poll error remains the final apply reason'
        Assert-Equal $permanentApplyResult.rebootRequired $false 'F2: permanent poll error clears the payload reboot signal'
        Assert-Equal $permanentApplyResult.agentCompletionConfirmed $false 'F2: permanent poll error removes completion eligibility'
        Assert-Equal $script:rebootDispatchCount 0 'F2: permanent poll error never dispatches a reboot after operator approval'
        Assert-Equal $permanentPhaseResult.RebootRan $false 'F2: permanent poll error does not mark the reboot phase as run'

        $permanentDiscoveryCycle = [pscustomobject]@{
            Status = [pscustomobject]@{
                runId = 'permanent-discovery-run'
                outcome = 'SearchOnly'
                computerName = 'fixture-vm'
                availableUpdateCount = 0
                roleFlags = [pscustomobject]@{ failoverCluster = $false }
                pendingRebootBefore = [pscustomobject]@{ isPending = $true }
                updates = @()
                errors = @()
            }
            AgentResult = [pscustomobject]@{ Completed = $true; ExitCode = 0 }
        }
        $script:failedFleet = @([pscustomobject]@{
            Sequence = 1
            VMName = 'fixture-vm'
            Payload = $permanentDiscoveryCycle
            Error = 'permanent discovery process-list failure'
            ResultKind = 'PermanentPoll'
        })
        $permanentDiscoveryDirectory = Join-Path $cycleDirectory 'permanent-discovery'
        New-Item -ItemType Directory -Force -Path $permanentDiscoveryDirectory | Out-Null
        $permanentDiscoveryRecords = @(Invoke-DiscoveryPhase -TargetVMNames @('fixture-vm') -Managers $null -GuestCredentialMap @{} -CurlPath 'unused' -AgentPath 'unused' -IdentityHelperPath 'unused' -GuestWorkingDirectory 'C:\unused' -MaxUpdates 1 -TimeoutSeconds 1 -PollSeconds 1 -CycleOutputDirectory $permanentDiscoveryDirectory -MaxInFlight 1)
        $permanentDiscoveryRecord = @($permanentDiscoveryRecords)[0]
        Assert-Equal $permanentDiscoveryRecord.outcome 'DiscoveryFailed' 'F2: permanent discovery poll error cannot inherit SearchOnly from the payload'
        Assert-Equal (@($permanentDiscoveryRecord.errors).Count -gt 0) $true 'F2: permanent discovery poll error remains in the final discovery record'
        Assert-Equal $permanentDiscoveryRecord.errors[0] 'permanent discovery process-list failure' 'F2: permanent discovery poll error remains the final discovery error'
        Assert-Equal $permanentDiscoveryRecord.pendingRebootBefore $null 'F2: permanent discovery poll error removes the payload reboot signal'
        $discoveryApplyResult = [pscustomobject]@{
            vmName = 'fixture-vm'
            action = 'Install'
            outcome = 'InstallSucceeded'
            rebootRequired = $true
            agentCompletionConfirmed = $true
            roleFlags = [pscustomobject]@{ failoverCluster = $false }
            errors = @()
        }
        Assert-Equal (@(Select-RebootRequiredApplyResults -ApplyResults @($discoveryApplyResult) -DiscoveryRecords @($permanentDiscoveryRecord)).Count) 0 'F2: permanent discovery poll error never makes the VM a reboot target'

        $script:failedFleet = @([pscustomobject]@{
            Sequence = 1
            VMName = 'fixture-vm'
            Payload = $null
            Error = 'simulated discovery timeout'
            ResultKind = 'Timeout'
        })
        $timeoutDiscoveryDirectory = Join-Path $cycleDirectory 'timeout-discovery'
        New-Item -ItemType Directory -Force -Path $timeoutDiscoveryDirectory | Out-Null
        $timeoutDiscoveryRecords = $null
        $timeoutDiscoveryThrew = $false
        try {
            $timeoutDiscoveryRecords = @(Invoke-DiscoveryPhase -TargetVMNames @('fixture-vm') -Managers $null -GuestCredentialMap @{} -CurlPath 'unused' -AgentPath 'unused' -IdentityHelperPath 'unused' -GuestWorkingDirectory 'C:\unused' -MaxUpdates 1 -TimeoutSeconds 1 -PollSeconds 1 -CycleOutputDirectory $timeoutDiscoveryDirectory -MaxInFlight 1)
        }
        catch { $timeoutDiscoveryThrew = $true }
        Assert-Equal $timeoutDiscoveryThrew $false 'F2: timeout discovery without payload still returns a failure record'
        if (-not $timeoutDiscoveryThrew) {
            $timeoutDiscoveryRecord = @($timeoutDiscoveryRecords)[0]
            Assert-Equal $timeoutDiscoveryRecord.errors[0] 'simulated discovery timeout' 'F2: timeout discovery without payload preserves its original error'
        }

        # F2: exercise the real apply adapter and round loop with two VMs. One missing
        # completion record must remain failed, while the confirmed peer may reboot and
        # continue to the verification discovery.
        $roundLoop = $orchestratorAst.Find({ param($node)
            $node -is [System.Management.Automation.Language.WhileStatementAst] -and $node.Extent.Text.Contains('$roundNumber++')
        }, $true)
        $roundFinalization = $orchestratorAst.Find({ param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains('Write-PatchRunSummary -RunOutputDirectory')
        }, $true)
        Assert-Equal ($null -ne $roundLoop) $true 'F2: the production round loop is available to the mixed-VM regression'
        Assert-Equal ($null -ne $roundFinalization) $true 'F2: the production final exit-code block is available to the mixed-VM regression'

        $updateId = '22222222-2222-2222-2222-222222222222'
        $roundUpdate = [pscustomobject]@{
            updateId = $updateId
            revisionNumber = 1
            title = 'Security Update'
            kbArticleIds = @()
            categories = @()
            msrcSeverity = 'Critical'
            updateType = 'Software'
        }
        $roundRoleFlags = [pscustomobject]@{ failoverCluster = $false }
        $script:roundOneDiscovery = @(
            [pscustomobject]@{ vmName = 'unconfirmed-vm'; computerName = 'unconfirmed-vm'; outcome = 'SearchOnly'; errors = @(); roleFlags = $roundRoleFlags; pendingRebootBefore = [pscustomobject]@{ isPending = $true }; updates = @($roundUpdate) },
            [pscustomobject]@{ vmName = 'confirmed-peer'; computerName = 'confirmed-peer'; outcome = 'SearchOnly'; errors = @(); roleFlags = $roundRoleFlags; pendingRebootBefore = [pscustomobject]@{ isPending = $false }; updates = @($roundUpdate) }
        )
        $script:roundTwoDiscovery = @([pscustomobject]@{ vmName = 'confirmed-peer'; computerName = 'confirmed-peer'; outcome = 'NoApplicableUpdates'; errors = @(); roleFlags = $roundRoleFlags; pendingRebootBefore = [pscustomobject]@{ isPending = $false }; updates = @() })
        $peerCycle = [pscustomobject]@{
            RunId = 'confirmed-peer-run'
            Mode = 'Apply'
            AgentCompletionConfirmed = $true
            AgentCompletionReason = 'synthetic terminal status'
            AgentResult = [pscustomobject]@{ Completed = $true; ExitCode = 0 }
            Status = [pscustomobject]@{
                runId = 'confirmed-peer-run'
                outcome = 'InstallSucceeded'
                finishedAt = '2026-09-11T10:00:00Z'
                installResult = [pscustomobject]@{ rebootRequired = $true }
                pendingRebootAfter = [pscustomobject]@{ isPending = $false }
                roleFlags = $roundRoleFlags
                errors = @()
            }
        }
        $script:mixedFleet = @(
            [pscustomobject]@{ Sequence = 1; VMName = 'unconfirmed-vm'; Payload = $null; Error = 'simulated missing terminal record' },
            [pscustomobject]@{ Sequence = 2; VMName = 'confirmed-peer'; Payload = $peerCycle; Error = $null }
        )
        $script:roundDiscoveryTargets = @()
        $script:roundDiscoveryCall = 0
        $script:lastRoundApplyResults = @()
        $script:rebootDispatchNames = @()

        function Invoke-GuestAgentFleet {
            param($FleetItems, $Managers, $GuestCredentialMap, $CurlPath, $AgentPath, $IdentityHelperPath, $GuestWorkingDirectory, $TimeoutSeconds, $PollSeconds, $MaxInFlight, $CredentialContext, $CredentialDecisionScript, $CredentialValidatedScript, $CredentialInteractive)
            return @($script:mixedFleet)
        }
        function Invoke-DiscoveryPhase {
            param($TargetVMNames, $Managers, $GuestCredentialMap, $CurlPath, $AgentPath, $IdentityHelperPath, $GuestWorkingDirectory, $MaxUpdates, $TimeoutSeconds, $PollSeconds, $CycleOutputDirectory, $MaxInFlight, $CredentialContext, $CredentialDecisionScript, $CredentialValidatedScript, $CredentialInteractive)
            $script:roundDiscoveryCall++
            $script:roundDiscoveryTargets += [pscustomobject]@{ Names = @($TargetVMNames) }
            if ($script:roundDiscoveryCall -eq 1) {
                return @($script:roundOneDiscovery)
            }
            return @($script:roundTwoDiscovery)
        }
        function Read-UpdateGroupSelection {
            param($UpdateGroups, $PromptProvider)
            return [pscustomobject]@{ Aborted = $false; Keys = @('{0}|1' -f $updateId) }
        }
        function Confirm-PatchPlan { param($SkipConfirmation) $true }
        function Write-PatchRoundVerification { param($CompletionStates, $Round) }
        function Write-PatchRunSummary { param($RunOutputDirectory, $RoundSummaries, $FinalStateMap) }
        function Write-PatchingSummary { param($ApplyResults) $script:lastRoundApplyResults = @($ApplyResults) }
        function Invoke-GuestRebootPhase {
            param($RebootTargets, $GuestCredentialMap, [string[]]$VIServers, $VIServerCredentialMap, [switch]$IgnoreVCenterCertificate, [string]$GuestOpsLibPath, [string]$CurlPath, [string]$GuestWorkingDirectory, [int]$RebootTimeoutSeconds, [int]$PollSeconds, [int]$RebootBatchSize)
            $script:rebootDispatchNames += @($RebootTargets | ForEach-Object { [string]$_.vmName })
            return @($RebootTargets | ForEach-Object {
                [pscustomobject]@{ vmName = $_.vmName; action = 'Initiated'; validationStatus = 'Confirmed' }
            })
        }

        $roundRunDirectory = Join-Path $cycleDirectory 'mixed-round'
        New-Item -ItemType Directory -Force -Path $roundRunDirectory | Out-Null
        $roundNumber = 0
        $roundTargetVMNames = @('unconfirmed-vm', 'confirmed-peer')
        $roundSummaries = @()
        $finalStateMap = @{}
        $deselectedUpdateKeys = @()
        $stoppedByRoundCap = $false
        $sawApplyFailure = $false
        $scriptExitCode = 0
        $runOutputDirectory = $roundRunDirectory
        $MaxPatchRounds = 2
        $SearchOnly = $false
        $PlanOnly = $false
        $hasExplicitSelectedUpdateKeys = $false
        $SkipConfirmation = $true
        $PromptProvider = $null
        $managers = $null
        $guestCredentialMap = @{}
        $guestCredentialContext = $null
        $guestCredentialDecisionScript = $null
        $guestCredentialValidatedScript = $null
        $guestCredentialInteractive = $false
        $resolvedVIServers = @()
        $viserverCredentialMap = @{}
        $IgnoreVCenterCertificate = $false
        $guestOpsLibPath = 'unused'
        $curlPath = 'unused'
        $AgentPath = 'unused'
        $identityHelperPath = 'unused'
        $GuestWorkingDirectory = 'C:\unused'
        $TimeoutMinutes = 1
        $RebootTimeoutMinutes = 1
        $PollSeconds = 1
        $ThrottleLimit = 1
        $resolvedRebootBatchSize = 1
        $MaxUpdates = 1
        . ([scriptblock]::Create(($roundLoop.Extent.Text + "`n" + $roundFinalization.Extent.Text)))

        Assert-Equal $sawApplyFailure $true 'F2: mixed apply exit marks the round as unsuccessful before finalization'
        Assert-Equal $script:lastRoundApplyResults.Count 2 'F2: real apply adapter returns both VM results'
        if ($script:lastRoundApplyResults.Count -eq 2) {
            Assert-Equal $script:lastRoundApplyResults[0].outcome 'Failed' 'F2: unconfirmed VM has a failed apply outcome'
            Assert-Equal (@($script:lastRoundApplyResults[0].errors).Count -gt 0) $true 'F2: unconfirmed VM carries an apply error'
            Assert-Equal $script:lastRoundApplyResults[0].agentCompletionConfirmed $false 'F2: unconfirmed VM remains failed in apply results'
            Assert-Equal $script:lastRoundApplyResults[1].outcome 'InstallSucceeded' 'F2: confirmed peer keeps its successful outcome'
            Assert-Equal $script:lastRoundApplyResults[1].agentCompletionConfirmed $true 'F2: confirmed peer remains eligible'
        }
        Assert-Equal $script:rebootDispatchNames.Count 1 'F2: mixed apply dispatches only one reboot'
        if ($script:rebootDispatchNames.Count -eq 1) {
            Assert-Equal $script:rebootDispatchNames[0] 'confirmed-peer' 'F2: only the confirmed peer is rebooted'
        }
        Assert-Equal $script:roundDiscoveryCall 2 'F2: the confirmed peer reaches verification discovery'
        if ($script:roundDiscoveryCall -ge 2) {
            Assert-Equal (@($script:roundDiscoveryTargets[1].Names).Count) 1 'F2: nextTargets contains only the confirmed peer'
            Assert-Equal $script:roundDiscoveryTargets[1].Names[0] 'confirmed-peer' 'F2: unconfirmed VM is absent from nextTargets'
        }
        Assert-Equal $finalStateMap['unconfirmed-vm'].state 'Failed' 'F2: unconfirmed VM remains in the final state map'
        Assert-Equal $finalStateMap['confirmed-peer'].state 'Green' 'F2: confirmed peer can finish the next round'
        Assert-Equal $scriptExitCode 1 'F2: one unconfirmed VM keeps the mixed run unsuccessful'
    }
    finally {
        Remove-Item Function:\Receive-GuestFile -ErrorAction SilentlyContinue
        Remove-Item Function:\Invoke-GuestAgentFleet -ErrorAction SilentlyContinue
        Remove-Item Function:\Invoke-DiscoveryPhase -ErrorAction SilentlyContinue
        Remove-Item Function:\Read-UpdateGroupSelection -ErrorAction SilentlyContinue
        Remove-Item Function:\Confirm-PatchPlan -ErrorAction SilentlyContinue
        Remove-Item Function:\Write-PatchRoundVerification -ErrorAction SilentlyContinue
        Remove-Item Function:\Write-PatchRunSummary -ErrorAction SilentlyContinue
        Remove-Item Function:\Write-PatchingSummary -ErrorAction SilentlyContinue
        Remove-Item Function:\Write-FinalReport -ErrorAction SilentlyContinue
        Remove-Item Function:\Confirm-GuestReboot -ErrorAction SilentlyContinue
        Remove-Item Function:\Write-RebootActionArtifacts -ErrorAction SilentlyContinue
        Remove-Item Function:\Invoke-GuestRebootPhase -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $cycleDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# F5: the real fleet adapter must validate credentials before starting a VM and let a
# skipped local account fail without stopping an unrelated account or entering a new round.
& {
    $cycleDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-f5-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $cycleDirectory | Out-Null

    $f5RoundLoop = $orchestratorAst.Find({ param($node)
        $node -is [System.Management.Automation.Language.WhileStatementAst] -and $node.Extent.Text.Contains('$roundNumber++')
    }, $true)
    $f5RoundFinalization = $orchestratorAst.Find({ param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains('Write-PatchRunSummary -RunOutputDirectory')
    }, $true)
    Assert-Equal ($null -ne $f5RoundLoop) $true 'F5: the production round loop is available to the credential recovery regression'
    Assert-Equal ($null -ne $f5RoundFinalization) $true 'F5: the production final exit-code block is available to the credential recovery regression'

    $script:vm01AgentStarts = 0
    $script:vm02AgentStarts = 0
    $script:vm01Reboots = 0
    $script:vm02Reboots = 0
    $script:f5CredentialPrompts = 0
    $script:f5DiscoveryCall = 0
    $script:f5DiscoveryTargets = @()

    $f5UpdateId = '33333333-3333-3333-3333-333333333333'
    $f5Update = [pscustomobject]@{
        updateId = $f5UpdateId
        revisionNumber = 1
        title = 'Security Update'
        kbArticleIds = @()
        categories = @()
        msrcSeverity = 'Critical'
        updateType = 'Software'
    }
    $f5RoleFlags = [pscustomobject]@{ failoverCluster = $false }
    $script:f5RoundOneDiscovery = @(
        [pscustomobject]@{ vmName = 'VM01'; computerName = 'VM01'; outcome = 'SearchOnly'; errors = @(); roleFlags = $f5RoleFlags; pendingRebootBefore = [pscustomobject]@{ isPending = $false }; updates = @($f5Update) },
        [pscustomobject]@{ vmName = 'VM02'; computerName = 'VM02'; outcome = 'SearchOnly'; errors = @(); roleFlags = $f5RoleFlags; pendingRebootBefore = [pscustomobject]@{ isPending = $false }; updates = @($f5Update) }
    )
    $script:f5RoundTwoDiscovery = @([pscustomobject]@{ vmName = 'VM02'; computerName = 'VM02'; outcome = 'NoApplicableUpdates'; errors = @(); roleFlags = $f5RoleFlags; pendingRebootBefore = [pscustomobject]@{ isPending = $false }; updates = @() })

    function New-GuestAuthentication {
        param([pscredential]$Credential)
        return [pscustomobject]@{ UserName = $Credential.UserName }
    }
    function Test-GuestCredentialForTarget {
        param([string]$VMName, [pscredential]$Credential)
        if ($VMName -eq 'VM01') {
            return [pscustomobject]@{ Status = 'Invalid'; ErrorKind = 'InvalidGuestLogin'; Error = 'synthetic rejected local credential' }
        }
        return [pscustomobject]@{ Status = 'Valid'; ErrorKind = $null; Error = $null }
    }
    function Start-VMAgentCycle {
        param($VMName, $Managers, $GuestAuth, $CurlPath, $AgentPath, $IdentityHelperPath, $GuestWorkingDirectory, $VMOutputDirectory, $MaxUpdates, $LocalSelectionPath, $SelectionPath, [switch]$SearchOnly)
        if ($VMName -eq 'VM01') {
            $script:vm01AgentStarts++
        }
        else {
            $script:vm02AgentStarts++
        }
        return [pscustomobject]@{ VMName = $VMName; GuestAuth = $GuestAuth; AgentResult = $null }
    }
    function Test-VMAgentCycleComplete {
        param($Handle)
        return [pscustomobject]@{ Completed = $true; ExitCode = 0 }
    }
    function Complete-VMAgentCycle {
        param($Handle, $AgentResult)
        return [pscustomobject]@{
            RunId = ('f5-' + $Handle.VMName)
            Mode = 'Apply'
            AgentCompletionConfirmed = $true
            AgentCompletionReason = 'synthetic terminal status'
            AgentResult = $AgentResult
            Status = [pscustomobject]@{
                runId = ('f5-' + $Handle.VMName)
                outcome = 'InstallSucceeded'
                finishedAt = '2026-09-11T10:00:00Z'
                installResult = [pscustomobject]@{ rebootRequired = $true }
                pendingRebootAfter = [pscustomobject]@{ isPending = $false }
                roleFlags = $f5RoleFlags
                errors = @()
            }
        }
    }
    function Invoke-DiscoveryPhase {
        param($TargetVMNames, $Managers, $GuestCredentialMap, $CurlPath, $AgentPath, $IdentityHelperPath, $GuestWorkingDirectory, $MaxUpdates, $TimeoutSeconds, $PollSeconds, $CycleOutputDirectory, $MaxInFlight, $CredentialContext, $CredentialDecisionScript, $CredentialValidatedScript, $CredentialInteractive)
        $script:f5DiscoveryCall++
        $script:f5DiscoveryTargets += [pscustomobject]@{ Names = @($TargetVMNames) }
        if ($script:f5DiscoveryCall -eq 1) {
            return @($script:f5RoundOneDiscovery)
        }
        return @($script:f5RoundTwoDiscovery)
    }
    function Read-UpdateGroupSelection {
        param($UpdateGroups, $PromptProvider)
        return [pscustomobject]@{ Aborted = $false; Keys = @('{0}|1' -f $f5UpdateId) }
    }
    function Confirm-PatchPlan { param($SkipConfirmation) $true }
    function Write-PatchRoundVerification { param($CompletionStates, $Round) }
    function Write-PatchRunSummary { param($RunOutputDirectory, $RoundSummaries, $FinalStateMap) }
    function Write-PatchingSummary { param($ApplyResults) }
    function Write-FinalReport { param($PatchPlanRecords, $ApplyResults, $CycleOutputDirectory, $RebootTargets) }
    function Confirm-GuestReboot { param($RebootTargets) $true }
    function Write-RebootActionArtifacts { param($CycleOutputDirectory, $RebootActions) }
    function Invoke-GuestRebootPhase {
        param($RebootTargets, $GuestCredentialMap, [string[]]$VIServers, $VIServerCredentialMap, [switch]$IgnoreVCenterCertificate, [string]$GuestOpsLibPath, [string]$CurlPath, [string]$GuestWorkingDirectory, [int]$RebootTimeoutSeconds, [int]$PollSeconds, [int]$RebootBatchSize)
        foreach ($target in @($RebootTargets)) {
            if ($target.vmName -eq 'VM01') {
                $script:vm01Reboots++
            }
            else {
                $script:vm02Reboots++
            }
        }
        return @($RebootTargets | ForEach-Object { [pscustomobject]@{ vmName = $_.vmName; action = 'Initiated'; validationStatus = 'Confirmed' } })
    }

    try {
        $f5Credential = New-Object System.Management.Automation.PSCredential('Administrator', (ConvertTo-SecureString 'synthetic' -AsPlainText -Force))
        $guestCredentialMap = @{ VM01 = $f5Credential; VM02 = $f5Credential }
        $guestCredentialContext = New-GuestCredentialContext -TargetNames @('VM01', 'VM02') -CredentialMap $guestCredentialMap
        $guestCredentialDecisionScript = {
            param($VMName, $AccountKey, $Members, $Reason)
            $script:f5CredentialPrompts++
            return [pscustomobject]@{ Action = 'SkipAccount'; Credential = $null; Remember = $false }
        }
        $guestCredentialValidatedScript = $null
        $guestCredentialInteractive = $true
        $roundNumber = 0
        $roundTargetVMNames = @('VM01', 'VM02')
        $roundSummaries = @()
        $finalStateMap = @{}
        $deselectedUpdateKeys = @()
        $stoppedByRoundCap = $false
        $sawApplyFailure = $false
        $scriptExitCode = 0
        $runOutputDirectory = $cycleDirectory
        $MaxPatchRounds = 2
        $SearchOnly = $false
        $PlanOnly = $false
        $hasExplicitSelectedUpdateKeys = $false
        $SkipConfirmation = $true
        $PromptProvider = $null
        $managers = $null
        $resolvedVIServers = @()
        $viserverCredentialMap = @{}
        $IgnoreVCenterCertificate = $false
        $guestOpsLibPath = 'unused'
        $curlPath = 'unused'
        $AgentPath = 'unused'
        $identityHelperPath = 'unused'
        $GuestWorkingDirectory = 'C:\unused'
        $TimeoutMinutes = 1
        $RebootTimeoutMinutes = 1
        $PollSeconds = 1
        $ThrottleLimit = 2
        $resolvedRebootBatchSize = 1
        $MaxUpdates = 1
        . ([scriptblock]::Create(($f5RoundLoop.Extent.Text + "`n" + $f5RoundFinalization.Extent.Text)))

        Assert-Equal -Actual $script:vm01AgentStarts -Expected 0 -Message 'F5: skipped account never starts an agent'
        Assert-Equal -Actual $script:vm02AgentStarts -Expected 1 -Message 'F5: another account continues'
        Assert-Equal -Actual $script:vm01Reboots -Expected 0 -Message 'F5: skipped account never reboots'
        Assert-Equal -Actual $script:f5CredentialPrompts -Expected 1 -Message 'F5: rejected account asks once before it is skipped'
        $nextTargets = if ($script:f5DiscoveryTargets.Count -gt 1) { @($script:f5DiscoveryTargets[1].Names) } else { @() }
        Assert-Equal -Actual ($nextTargets -contains 'VM01') -Expected $false -Message 'F5: skipped target cannot enter another round'
        Assert-Equal -Actual $scriptExitCode -Expected 1 -Message 'F5: skipping is not an all-green run'
        Assert-Equal -Actual $finalStateMap['VM01'].state -Expected 'Failed' -Message 'F5: skipped account remains failed in the final state map'
    }
    finally {
        Remove-Item -LiteralPath $cycleDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# F5: the production reboot adapter recovers a typed child-job rejection in the parent and
# retries a boot-time read with replacement credentials without a generic reboot prompt.
& {
    $baseBootTime = [datetime]::Parse('2026-09-11T10:00:00Z').ToUniversalTime()
    $newBootTime = [datetime]::Parse('2026-09-11T10:05:00Z').ToUniversalTime()
    $oldCredential = New-Object System.Management.Automation.PSCredential('OLD\adm', (ConvertTo-SecureString 'synthetic-old' -AsPlainText -Force))
    $replacementCredential = New-Object System.Management.Automation.PSCredential('NEW\adm', (ConvertTo-SecureString 'synthetic-new' -AsPlainText -Force))

    $script:f5RebootMode = ''
    $script:f5RebootJobCalls = 0
    $script:f5RebootCredentialUsers = @()
    $script:f5BootReadCalls = 0
    $script:f5RecoveryPrompts = 0
    $script:f5GenericRebootPrompts = 0

    function New-GuestAuthentication {
        param([pscredential]$Credential)
        return [pscustomobject]@{ UserName = $Credential.UserName }
    }
    function Test-GuestCredentialForTarget {
        param([string]$VMName, [pscredential]$Credential)
        # ChildRejected and BootReadRejected both model a password rotated mid-run: still valid
        # when this phase checked it, refused by the guest moments later. ValidationUnavailable
        # models VMware Tools being down mid-reboot - an error, not a refusal, and the one the
        # coordinator must not mistake for an operator who skipped the account.
        if ($script:f5RebootMode -eq 'ValidationUnavailable') {
            return [pscustomobject]@{ Status = 'Error'; ErrorKind = 'Transient'; Error = 'synthetic VMware Tools are not running' }
        }
        return [pscustomobject]@{ Status = 'Valid'; ErrorKind = $null; Error = $null }
    }
    function Get-GuestRebootJobScript { return { param($JobInput) $null = $JobInput } }
    function Invoke-ThrottledJobs {
        param($Items, $ThrottleLimit, $JobTimeoutSeconds, $ScriptBlock)
        $script:f5RebootJobCalls++
        $script:f5RebootCredentialUsers += @($Items | ForEach-Object { $_.GuestCredential.UserName })
        if ($script:f5RebootMode -eq 'Ambiguous') {
            return @($Items | ForEach-Object {
                    [pscustomobject]@{
                        Sequence = $_.Sequence
                        VMName = $_.VMName
                        ProcessId = $null
                        Error = 'Synthetic transport failure after shutdown.exe may have started.'
                        ErrorKind = 'Transient'
                        RejectedBeforeStart = $false
                    }
                })
        }
        if ($script:f5RebootMode -eq 'ChildRejected' -and $script:f5RebootJobCalls -eq 1) {
            return @($Items | ForEach-Object {
                    [pscustomobject]@{
                        Sequence = $_.Sequence
                        VMName = $_.VMName
                        ProcessId = $null
                        Error = 'Synthetic InvalidGuestLogin before shutdown.exe started.'
                        ErrorKind = 'InvalidCredentials'
                        RejectedBeforeStart = $true
                    }
                })
        }
        return @($Items | ForEach-Object {
                [pscustomobject]@{
                    Sequence = $_.Sequence
                    VMName = $_.VMName
                    ProcessId = 700
                    Error = $null
                    ErrorKind = $null
                    RejectedBeforeStart = $false
                }
            })
    }
    function Invoke-VMGuestBootTimeRead {
        param($VMName, $Managers, $GuestAuth, $CurlPath, $GuestWorkingDirectory, $BootTimeHelperPath, $TimeoutSeconds, $PollSeconds, [switch]$SkipHelperUpload)
        $script:f5BootReadCalls++
        if ($script:f5RebootMode -eq 'BootReadRejected' -and $script:f5BootReadCalls -eq 1) {
            $invalidLogin = New-Object System.Exception('Synthetic InvalidGuestLogin during boot-time read.')
            $invalidLogin.PSTypeNames.Insert(0, 'VMware.Vim.InvalidGuestLogin')
            throw $invalidLogin
        }
        $bootTime = if ($script:f5BootReadCalls -le 2) { $baseBootTime } else { $newBootTime }
        return [pscustomobject]@{ VMName = $VMName; BootTimeUtc = $bootTime; UptimeSeconds = 60 }
    }
    function Read-RebootDecision {
        param($Context)
        $script:f5GenericRebootPrompts++
        return 'CONTINUE'
    }
    function Start-Sleep { param($Seconds, $Milliseconds) $null = $Seconds; $null = $Milliseconds }

    $recoveryDecision = {
        param($VMName, $AccountKey, $Members, $Reason)
        $script:f5RecoveryPrompts++
        return [pscustomobject]@{ Action = 'Retry'; Credential = $replacementCredential; Remember = $false }
    }
    $target = [pscustomobject]@{ vmName = 'VM-reboot-recovery'; rebootReason = 'Reported after apply' }

    $script:f5RebootMode = 'ChildRejected'
    $script:f5RebootJobCalls = 0
    $script:f5RebootCredentialUsers = @()
    $script:f5BootReadCalls = 0
    $script:f5RecoveryPrompts = 0
    $script:f5GenericRebootPrompts = 0
    $childRejectedMap = @{ 'VM-reboot-recovery' = $oldCredential }
    $childRejectedContext = New-GuestCredentialContext -TargetNames @('VM-reboot-recovery') -CredentialMap $childRejectedMap
    $childRejectedActions = @(Invoke-GuestRebootPhase -RebootTargets @($target) -GuestCredentialMap $childRejectedMap -VIServers @('vc.synthetic.invalid') -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -BootTimeHelperPath 'unused' -RebootTimeoutSeconds 60 -PollSeconds 1 -RebootBatchSize 1 -CredentialContext $childRejectedContext -CredentialDecisionScript $recoveryDecision -CredentialInteractive $true)
    Assert-Equal -Actual $script:f5RebootJobCalls -Expected 2 -Message 'F5: an explicitly rejected reboot is submitted once more after credential recovery'
    Assert-Equal -Actual ($script:f5RebootCredentialUsers -join ';') -Expected 'OLD\adm;NEW\adm' -Message 'F5: retrying a rejected reboot uses the replacement credential'
    Assert-Equal -Actual $script:f5RecoveryPrompts -Expected 1 -Message 'F5: rejected reboot asks for one replacement credential'
    Assert-Equal -Actual $script:f5GenericRebootPrompts -Expected 0 -Message 'F5: credential recovery does not fall through to generic reboot prompting'
    Assert-Equal -Actual $childRejectedActions[0].validationStatus -Expected 'Confirmed' -Message 'F5: recovered reboot still waits for a newer boot time'

    $script:f5RebootMode = 'BootReadRejected'
    $script:f5RebootJobCalls = 0
    $script:f5RebootCredentialUsers = @()
    $script:f5BootReadCalls = 0
    $script:f5RecoveryPrompts = 0
    $script:f5GenericRebootPrompts = 0
    $bootReadMap = @{ 'VM-reboot-recovery' = $oldCredential }
    $bootReadContext = New-GuestCredentialContext -TargetNames @('VM-reboot-recovery') -CredentialMap $bootReadMap
    $bootReadActions = @(Invoke-GuestRebootPhase -RebootTargets @($target) -GuestCredentialMap $bootReadMap -VIServers @('vc.synthetic.invalid') -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -BootTimeHelperPath 'unused' -RebootTimeoutSeconds 60 -PollSeconds 1 -RebootBatchSize 1 -CredentialContext $bootReadContext -CredentialDecisionScript $recoveryDecision -CredentialInteractive $true)
    Assert-Equal -Actual $script:f5RecoveryPrompts -Expected 1 -Message 'F5: InvalidGuestLogin during boot-time read asks for a replacement credential'
    Assert-Equal -Actual $script:f5RebootJobCalls -Expected 1 -Message 'F5: recovered boot-time read does not duplicate reboot submission'
    Assert-Equal -Actual $script:f5GenericRebootPrompts -Expected 0 -Message 'F5: recovered boot-time read does not reach a generic reboot prompt'
    Assert-Equal -Actual $bootReadActions[0].validationStatus -Expected 'Confirmed' -Message 'F5: recovered boot-time read confirms the reboot normally'

    # An ambiguous transport failure may have left shutdown.exe running, so it must never be
    # re-sent: a second submission would be a second reboot. The coordinator observes instead.
    $script:f5RebootMode = 'Ambiguous'
    $script:f5RebootJobCalls = 0
    $script:f5RebootCredentialUsers = @()
    $script:f5BootReadCalls = 0
    $script:f5RecoveryPrompts = 0
    $script:f5GenericRebootPrompts = 0
    $ambiguousMap = @{ 'VM-reboot-recovery' = $oldCredential }
    $ambiguousContext = New-GuestCredentialContext -TargetNames @('VM-reboot-recovery') -CredentialMap $ambiguousMap
    $ambiguousActions = @(Invoke-GuestRebootPhase -RebootTargets @($target) -GuestCredentialMap $ambiguousMap -VIServers @('vc.synthetic.invalid') -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -BootTimeHelperPath 'unused' -RebootTimeoutSeconds 60 -PollSeconds 1 -RebootBatchSize 1 -CredentialContext $ambiguousContext -CredentialDecisionScript $recoveryDecision -CredentialInteractive $true)
    Assert-Equal -Actual $script:f5RebootJobCalls -Expected 1 -Message 'F5: an ambiguous initiation error is never re-sent'
    Assert-Equal -Actual $script:f5RecoveryPrompts -Expected 0 -Message 'F5: an ambiguous initiation error asks for no replacement credential'
    Assert-Equal -Actual ($script:f5RebootCredentialUsers -join ';') -Expected 'OLD\adm' -Message 'F5: an ambiguous initiation error keeps the original credential'
    Assert-Equal -Actual $ambiguousActions[0].validationStatus -Expected 'Confirmed' -Message 'F5: an ambiguous initiation error is resolved by observing the boot time'

    # Two guests in one AD domain share one account. A rotated domain password rejects both, but
    # the operator must be asked once - and the VM that did not open the dialog must still end up
    # on the replacement, not on the credential the guest already refused.
    $script:f5RebootMode = 'ChildRejected'
    $script:f5RebootJobCalls = 0
    $script:f5RebootCredentialUsers = @()
    $script:f5BootReadCalls = 0
    $script:f5RecoveryPrompts = 0
    $script:f5GenericRebootPrompts = 0
    $groupTargets = @(
        [pscustomobject]@{ vmName = 'vm-a.corp.test'; rebootReason = 'Reported after apply' },
        [pscustomobject]@{ vmName = 'vm-b.corp.test'; rebootReason = 'Reported after apply' }
    )
    $groupMap = @{ 'vm-a.corp.test' = $oldCredential; 'vm-b.corp.test' = $oldCredential }
    $groupContext = New-GuestCredentialContext -TargetNames @('vm-a.corp.test', 'vm-b.corp.test') -CredentialMap $groupMap
    $groupActions = @(Invoke-GuestRebootPhase -RebootTargets $groupTargets -GuestCredentialMap $groupMap -VIServers @('vc.synthetic.invalid') -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -BootTimeHelperPath 'unused' -RebootTimeoutSeconds 60 -PollSeconds 1 -RebootBatchSize 2 -CredentialContext $groupContext -CredentialDecisionScript $recoveryDecision -CredentialInteractive $true)
    Assert-Equal -Actual $script:f5RecoveryPrompts -Expected 1 -Message 'F5: two guests sharing one account ask for one replacement credential'
    Assert-Equal -Actual (@($script:f5RebootCredentialUsers | Where-Object { $_ -eq 'NEW\adm' }).Count) -Expected 2 -Message 'F5: both guests in the account are re-sent with the replacement credential'
    Assert-Equal -Actual $script:f5GenericRebootPrompts -Expected 0 -Message 'F5: a shared-account recovery does not reach a generic reboot prompt'
    Assert-Equal -Actual (@($groupActions | Where-Object { $_.validationStatus -eq 'Confirmed' }).Count) -Expected 2 -Message 'F5: both recovered guests confirm a newer boot time'

    # A non-interactive run cannot answer a dialog, so the account's recovery fails outright. No
    # member of it may then be handed the refused credential back out of an earlier validation
    # and re-submitted with it: that is extra failed logons against an account already failing,
    # which is lockout pressure on a large run.
    $script:f5RebootMode = 'ChildRejected'
    $script:f5RebootJobCalls = 0
    $script:f5RebootCredentialUsers = @()
    $script:f5BootReadCalls = 0
    $script:f5RecoveryPrompts = 0
    $script:f5GenericRebootPrompts = 0
    $lockoutTargets = @(
        [pscustomobject]@{ vmName = 'vm-c.corp.test'; rebootReason = 'Reported after apply' },
        [pscustomobject]@{ vmName = 'vm-d.corp.test'; rebootReason = 'Reported after apply' }
    )
    $lockoutMap = @{ 'vm-c.corp.test' = $oldCredential; 'vm-d.corp.test' = $oldCredential }
    $lockoutContext = New-GuestCredentialContext -TargetNames @('vm-c.corp.test', 'vm-d.corp.test') -CredentialMap $lockoutMap
    $lockoutActions = @(Invoke-GuestRebootPhase -RebootTargets $lockoutTargets -GuestCredentialMap $lockoutMap -VIServers @('vc.synthetic.invalid') -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -BootTimeHelperPath 'unused' -RebootTimeoutSeconds 1 -PollSeconds 1 -RebootBatchSize 2 -CredentialContext $lockoutContext -CredentialDecisionScript $recoveryDecision -CredentialInteractive $false)
    Assert-Equal -Actual $script:f5RecoveryPrompts -Expected 0 -Message 'F5: a non-interactive run never opens a credential dialog'
    Assert-Equal -Actual (@($script:f5RebootCredentialUsers | Where-Object { $_ -eq 'OLD\adm' }).Count) -Expected 2 -Message 'F5: a refused account is not re-submitted with the credential the guest already refused'
    Assert-Equal -Actual $script:f5RebootJobCalls -Expected 1 -Message 'F5: a refused account that cannot be recovered submits once'
    Assert-Equal -Actual (@($lockoutActions | Where-Object { $_.action -eq 'Initiated' -and $_.validationStatus -eq 'Confirmed' }).Count) -Expected 0 -Message 'F5: a refused account confirms no reboot'

    # VMware Tools are down while the guest reboots, so credential validation cannot run. That is
    # an error, not an operator refusal: the boot-time gate must keep waiting and then ask the
    # operator, instead of silently recording the VM as a credential failure it can never answer.
    $script:f5RebootMode = 'ValidationUnavailable'
    $script:f5RebootJobCalls = 0
    $script:f5RebootCredentialUsers = @()
    $script:f5BootReadCalls = 0
    $script:f5RecoveryPrompts = 0
    $script:f5GenericRebootPrompts = 0
    $unavailableMap = @{ 'VM-reboot-recovery' = $oldCredential }
    $unavailableContext = New-GuestCredentialContext -TargetNames @('VM-reboot-recovery') -CredentialMap $unavailableMap
    $unavailableActions = @(Invoke-GuestRebootPhase -RebootTargets @($target) -GuestCredentialMap $unavailableMap -VIServers @('vc.synthetic.invalid') -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -BootTimeHelperPath 'unused' -RebootTimeoutSeconds 1 -PollSeconds 1 -RebootBatchSize 1 -CredentialContext $unavailableContext -CredentialDecisionScript $recoveryDecision -CredentialInteractive $true)
    Assert-Equal -Actual $script:f5RecoveryPrompts -Expected 0 -Message 'F5: a validation error is never treated as a rejected credential'
    Assert-Equal -Actual $script:f5GenericRebootPrompts -Expected 1 -Message 'F5: a validation error still reaches the operator decision it can answer'
    Assert-Equal -Actual ($unavailableActions[0].validationStatus -eq 'CredentialRecovery') -Expected $false -Message 'F5: a validation error is not recorded as a credential refusal'
}

# F5: the reboot child job must say whether shutdown.exe could already be running. Everything
# before Invoke-VMGuestReboot - the module import, the child's own vCenter login - is
# unambiguously "never sent", and reporting those as ambiguous cost a full reboot timeout and
# recorded action=Initiated for a guest that was never told to restart.
& {
    $jobLibPath = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-job-lib-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $jobLibBody = @'
. '__REPO_ROOT__/scripts/GuestOpsLib.ps1'
function Connect-VIServersWithCredentialMap {
    param($VIServers, $CredentialMap, $CredentialPromptScript, [switch]$RetryOnFailure, [switch]$ReuseExisting)
    if ($env:F5_JOB_MODE -eq 'ConnectFails') {
        throw (New-Object System.TimeoutException -ArgumentList 'synthetic vCenter login timeout')
    }
    return [pscustomobject]@{ OpenedConnections = @() }
}
function New-GuestAuthentication {
    param([pscredential]$Credential)
    return [pscustomobject]@{ UserName = $Credential.UserName }
}
function Invoke-VMGuestReboot {
    param([string]$VMName, $Managers, $GuestAuth)
    if ($env:F5_JOB_MODE -eq 'RebootPreflightFails') {
        # What Invoke-VMGuestReboot does for a Get-ExactVM/GetView failure: the guest was never
        # touched, so the caller must not spend a reboot timeout observing it.
        $preflight = New-Object System.TimeoutException -ArgumentList 'synthetic inventory lookup timeout'
        $preflight.Data['RejectedBeforeStart'] = $true
        throw $preflight
    }
    if ($env:F5_JOB_MODE -eq 'RebootTransient') {
        throw (New-Object System.TimeoutException -ArgumentList 'synthetic transport failure sending shutdown')
    }
    if ($env:F5_JOB_MODE -eq 'RebootRejected') {
        $invalidLogin = New-Object System.Exception -ArgumentList 'synthetic rejected login sending shutdown'
        $invalidLogin.PSTypeNames.Insert(0, 'VMware.Vim.InvalidGuestLogin')
        throw $invalidLogin
    }
    return [pscustomobject]@{ ProcessId = 4242 }
}
function Disconnect-VIServer { param($Server, [switch]$Confirm) }
'@
    $jobLibBody = $jobLibBody.Replace('__REPO_ROOT__', $repoRoot.Replace('\\', '/'))
    Set-Content -LiteralPath $jobLibPath -Value $jobLibBody -Encoding UTF8

    function Import-Module { param($Name, [switch]$ErrorAction) }
    $jobCredential = New-Object System.Management.Automation.PSCredential('CORP\job', (ConvertTo-SecureString 'synthetic-job' -AsPlainText -Force))
    $jobScript = Get-GuestRebootJobScript
    $jobInput = [pscustomobject]@{
        Sequence = 1
        VMName = 'vm-job.corp.test'
        RebootReason = 'Reported after apply'
        VIServers = @('vc.synthetic.invalid')
        VIServerCredentialMap = @{}
        GuestCredential = $jobCredential
        IgnoreVCenterCertificate = $false
        GuestOpsLibPath = $jobLibPath
    }

    try {
        $env:F5_JOB_MODE = 'ConnectFails'
        $connectResult = & $jobScript $jobInput
        Assert-Equal -Actual ([string]$connectResult.ErrorKind) -Expected 'Transient' -Message 'F5: a child vCenter login timeout classifies as transient'
        Assert-Equal -Actual ([bool]$connectResult.RejectedBeforeStart) -Expected $true -Message 'F5: a failure before Invoke-VMGuestReboot is never ambiguous'
        Assert-Equal -Actual ($null -eq $connectResult.ProcessId) -Expected $true -Message 'F5: a child that never reached the guest reports no process id'

        $env:F5_JOB_MODE = 'RebootTransient'
        $transientResult = & $jobScript $jobInput
        Assert-Equal -Actual ([string]$transientResult.ErrorKind) -Expected 'Transient' -Message 'F5: a transport failure sending shutdown classifies as transient'
        Assert-Equal -Actual ([bool]$transientResult.RejectedBeforeStart) -Expected $false -Message 'F5: a transport failure sending shutdown stays ambiguous and is never re-sent'

        $env:F5_JOB_MODE = 'RebootPreflightFails'
        $preflightResult = & $jobScript $jobInput
        Assert-Equal -Actual ([string]$preflightResult.ErrorKind) -Expected 'Transient' -Message 'F5: a pre-flight lookup timeout still classifies as transient'
        Assert-Equal -Actual ([bool]$preflightResult.RejectedBeforeStart) -Expected $true -Message 'F5: a failure raised before the guest was touched is never ambiguous'

        $env:F5_JOB_MODE = 'RebootRejected'
        $rejectedResult = & $jobScript $jobInput
        Assert-Equal -Actual ([string]$rejectedResult.ErrorKind) -Expected 'InvalidCredentials' -Message 'F5: a guest refusing the credential classifies as invalid credentials'
        Assert-Equal -Actual ([bool]$rejectedResult.RejectedBeforeStart) -Expected $true -Message 'F5: a refused login means shutdown.exe never started'

        $env:F5_JOB_MODE = 'Succeeds'
        $okResult = & $jobScript $jobInput
        Assert-Equal -Actual ([string]$okResult.Error) -Expected '' -Message 'F5: a successful reboot submission reports no error'
        Assert-Equal -Actual ([bool]$okResult.RejectedBeforeStart) -Expected $false -Message 'F5: a successful reboot submission is not a rejection'
        Assert-Equal -Actual $okResult.ProcessId -Expected 4242 -Message 'F5: a successful reboot submission carries the guest process id'
    }
    finally {
        Remove-Item Env:F5_JOB_MODE -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $jobLibPath -Force -ErrorAction SilentlyContinue
    }
}

# F5: Complete-VMAgentCycle must not erase why the artifacts could not be downloaded. It used
# to re-throw a bare string, which classifies as Permanent, so a credential that expired
# mid-cycle produced "status.json was not downloaded" and no recovery was ever offered.
& {
    function Read-VMAgentCycleStatus {
        param($Handle)
        $invalidLogin = New-Object System.Exception -ArgumentList 'synthetic rejected login during status download'
        $invalidLogin.PSTypeNames.Insert(0, 'VMware.Vim.InvalidGuestLogin')
        throw $invalidLogin
    }
    function Receive-GuestFile {
        param($FileManager, $VMView, $GuestAuth, $HostName, $CurlPath, $GuestPath, $LocalPath, $TimeoutSeconds)
        throw 'synthetic agent.log download failure'
    }

    $collectHandle = [pscustomobject]@{
        VMName = 'vm-collect.corp.test'
        RunId = 'collect-run'
        Mode = 'Apply'
        Status = $null
        Managers = [pscustomobject]@{ FileManager = $null }
        VMView = $null
        GuestAuth = $null
        HostName = 'synthetic'
        CurlPath = 'unused'
        GuestLogPath = 'C:\synthetic\agent.log'
        LocalLogPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'guestops-collect-agent.log')
        LocalStatusPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'guestops-collect-missing-status.json')
        TransferTimeoutSeconds = 5
    }
    Remove-Item -LiteralPath $collectHandle.LocalStatusPath -Force -ErrorAction SilentlyContinue

    $collectErrorKind = 'not thrown'
    try {
        Complete-VMAgentCycle -Handle $collectHandle -AgentResult $null | Out-Null
    }
    catch {
        $collectErrorKind = Get-GuestOperationErrorKind -ErrorRecord $_
    }
    Assert-Equal -Actual $collectErrorKind -Expected 'InvalidCredentials' -Message 'F5: a rejected login during artifact collection keeps its classification'
}

# F5: a guest that rejects the credential at start, at poll, or while the artifacts are
# collected must be recovered on that same stage - and recovering a poll or a collect must not
# start a second agent, because the first one is still installing updates.
& {
    $stageOld = New-Object System.Management.Automation.PSCredential('CORP\adm-old', (ConvertTo-SecureString 'synthetic-stage-old' -AsPlainText -Force))
    $stageNew = New-Object System.Management.Automation.PSCredential('CORP\adm-new', (ConvertTo-SecureString 'synthetic-stage-new' -AsPlainText -Force))

    $script:f5StageMode = ''
    $script:f5StageStarts = 0
    $script:f5StagePolls = 0
    $script:f5StageCompletes = 0
    $script:f5StagePrompts = 0

    function New-InvalidGuestLoginError {
        param([string]$Message)
        $invalidLogin = New-Object System.Exception -ArgumentList $Message
        $invalidLogin.PSTypeNames.Insert(0, 'VMware.Vim.InvalidGuestLogin')
        return $invalidLogin
    }
    function New-GuestAuthentication {
        param([pscredential]$Credential)
        return [pscustomobject]@{ UserName = $Credential.UserName }
    }
    function Test-GuestCredentialForTarget {
        param([string]$VMName, [pscredential]$Credential)
        # The password rotated mid-run, so it still validates; only the guest operation refuses
        # it. That is the case requirement 3 names, and the only one where the stage matters.
        return [pscustomobject]@{ Status = 'Valid'; ErrorKind = $null; Error = $null }
    }
    function Start-VMAgentCycle {
        param($VMName, $Managers, $GuestAuth, $CurlPath, $AgentPath, $IdentityHelperPath, $GuestWorkingDirectory, $VMOutputDirectory, $MaxUpdates, $LocalSelectionPath, $SelectionPath, [switch]$SearchOnly)
        $script:f5StageStarts++
        if ($script:f5StageMode -eq 'Start' -and $script:f5StageStarts -eq 1) {
            throw (New-InvalidGuestLoginError -Message 'synthetic rejected login at start')
        }
        return [pscustomobject]@{ VMName = $VMName; GuestAuth = $GuestAuth; AgentResult = $null }
    }
    function Test-VMAgentCycleComplete {
        param($Handle)
        $script:f5StagePolls++
        if ($script:f5StageMode -eq 'Poll' -and $script:f5StagePolls -eq 1) {
            throw (New-InvalidGuestLoginError -Message 'synthetic rejected login at poll')
        }
        return [pscustomobject]@{ Completed = $true; ExitCode = 0 }
    }
    function Complete-VMAgentCycle {
        param($Handle, $AgentResult)
        $script:f5StageCompletes++
        if ($script:f5StageMode -eq 'Collect' -and $script:f5StageCompletes -eq 1) {
            # GuestOpsLib wraps a failed artifact download in an InvalidOperationException and
            # keeps the original as InnerException; without that the login type is lost here and
            # no recovery is ever offered.
            throw (New-Object System.InvalidOperationException -ArgumentList 'status.json was not downloaded.', (New-InvalidGuestLoginError -Message 'synthetic rejected login at collect'))
        }
        return [pscustomobject]@{
            RunId = 'stage-run'
            Mode = 'Apply'
            AgentCompletionConfirmed = $true
            AgentCompletionReason = 'synthetic terminal status'
            AgentResult = $AgentResult
            Status = [pscustomobject]@{ runId = 'stage-run'; outcome = 'InstallSucceeded'; finishedAt = '2026-09-11T10:00:00Z' }
        }
    }

    $stageDecision = {
        param($VMName, $AccountKey, $Members, $Reason)
        $script:f5StagePrompts++
        return [pscustomobject]@{ Action = 'Retry'; Credential = $stageNew; Remember = $false }
    }
    $stageItem = [pscustomobject]@{
        Sequence = 1
        VMName = 'vm-stage.corp.test'
        VMOutputDirectory = 'C:\synthetic\out'
        MaxUpdates = 1
        LocalSelectionPath = ''
        GuestSelectionPath = ''
        SearchOnly = $true
    }

    foreach ($stage in @('Start', 'Poll', 'Collect')) {
        $script:f5StageMode = $stage
        $script:f5StageStarts = 0
        $script:f5StagePolls = 0
        $script:f5StageCompletes = 0
        $script:f5StagePrompts = 0
        $stageMap = @{ 'vm-stage.corp.test' = $stageOld }
        $stageContext = New-GuestCredentialContext -TargetNames @('vm-stage.corp.test') -CredentialMap $stageMap
        $stageResults = @(Invoke-GuestAgentFleet -FleetItems @($stageItem) -Managers $null -GuestCredentialMap $stageMap -CurlPath 'unused' -AgentPath 'unused' -IdentityHelperPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -TimeoutSeconds 60 -PollSeconds 1 -MaxInFlight 1 -CredentialContext $stageContext -CredentialDecisionScript $stageDecision -CredentialInteractive $true)

        Assert-Equal -Actual $script:f5StagePrompts -Expected 1 -Message ('F5: a rejected login during {0} asks for one replacement credential' -f $stage)
        Assert-Equal -Actual ([string]$stageResults[0].Error) -Expected '' -Message ('F5: a rejected login during {0} recovers instead of failing the VM' -f $stage)
        Assert-Equal -Actual ([bool]$stageResults[0].Payload.AgentCompletionConfirmed) -Expected $true -Message ('F5: a rejected login during {0} still yields a confirmed cycle' -f $stage)
        Assert-Equal -Actual $stageMap['vm-stage.corp.test'].UserName -Expected 'CORP\adm-new' -Message ('F5: a rejected login during {0} leaves the replacement credential in the map' -f $stage)
        $expectedStarts = if ($stage -eq 'Start') { 2 } else { 1 }
        Assert-Equal -Actual $script:f5StageStarts -Expected $expectedStarts -Message ('F5: recovering a rejected login during {0} starts the agent the expected number of times' -f $stage)
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host ('FAIL: ' + $failure) }
    exit 1
}
Write-Host 'Safety regression checks passed.'
exit 0

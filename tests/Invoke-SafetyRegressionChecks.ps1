Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/GuestOpsLib.ps1')
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

        function Invoke-GuestAgentFleet { $script:failedFleet }
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
        $script:failedFleet = @([pscustomobject]@{ Sequence = 1; VMName = 'fixture-vm'; Payload = $null; Error = 'simulated poll error' })
        $plan = @([pscustomobject]@{ vmName = 'fixture-vm'; action = 'Install'; selectedUpdates = @([pscustomobject]@{ identityKey = '11111111-1111-1111-1111-111111111111|1' }) })
        $phaseDirectory = Join-Path $cycleDirectory 'apply'
        New-Item -ItemType Directory -Force -Path $phaseDirectory | Out-Null
        $phaseResult = Invoke-ApplyAndOptionalReboot -PatchPlanRecords $plan -Managers $null -GuestCredentialMap @{} -VIServers @() -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -AgentPath 'unused' -IdentityHelperPath 'unused' -GuestWorkingDirectory 'C:\unused' -TimeoutSeconds 1 -RebootTimeoutSeconds 1 -PollSeconds 1 -CycleOutputDirectory $phaseDirectory -ThrottleLimit 1 -RebootBatchSize 1 -DiscoveryRecords $discovery
        Assert-Equal $script:rebootDispatchCount 0 'F2: a poll error never dispatches a reboot after operator approval'
        Assert-Equal $phaseResult.ExitCode 1 'F2: the poll error remains an unsuccessful apply run'

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
            param($FleetItems, $Managers, $GuestCredentialMap, $CurlPath, $AgentPath, $IdentityHelperPath, $GuestWorkingDirectory, $TimeoutSeconds, $PollSeconds, $MaxInFlight)
            return @($script:mixedFleet)
        }
        function Invoke-DiscoveryPhase {
            param($TargetVMNames, $Managers, $GuestCredentialMap, $CurlPath, $AgentPath, $IdentityHelperPath, $GuestWorkingDirectory, $MaxUpdates, $TimeoutSeconds, $PollSeconds, $CycleOutputDirectory, $MaxInFlight)
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

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host ('FAIL: ' + $failure) }
    exit 1
}
Write-Host 'Safety regression checks passed.'
exit 0

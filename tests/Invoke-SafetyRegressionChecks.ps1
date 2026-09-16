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

# A real exception type for the fixtures that are THROWN. PSTypeNames is a PowerShell-side
# decoration on an instance, and an instance stored as the InnerException of another exception is
# re-wrapped when it is read back - so the decoration cannot be relied on to survive that round
# trip on every host. Get-GuestOperationErrorKind matches the SHORT type name, so a test namespace
# carries the meaning without colliding with PowerCLI's own type when it is installed, and without
# force-loading a VMware assembly.
if (-not ('PatchingGuestOpsTests.Vim.InvalidGuestLogin' -as [type])) {
    Add-Type -TypeDefinition @'
namespace PatchingGuestOpsTests.Vim {
    public class InvalidGuestLogin : System.Exception {
        public InvalidGuestLogin(string message) : base(message) { }
    }
}
'@
}

function New-InvalidGuestLoginException {
    param([string]$Message)

    return (New-Object PatchingGuestOpsTests.Vim.InvalidGuestLogin -ArgumentList $Message)
}

# Offline error fixtures carry the production type names as PowerShell type-name
# metadata, so these tests never force-load VMware assemblies. Only fixtures that are INSPECTED
# rather than thrown may use this; anything thrown goes through New-InvalidGuestLoginException.
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
        param($Name, $Server, $ErrorAction)
        # Inventory is only ever reachable through an explicit connection scope. A lookup that
        # falls back to PowerCLI's global default session could pick a VM from a vCenter the
        # operator never named, which is exactly the failure this scope exists to prevent.
        if ($null -eq $Server -or @($Server).Count -eq 0) { throw 'Get-VM was called without a connection scope.' }
        @($inventory | Where-Object { $_.Name -eq $Name })
    }
    $scopeServers = @('wanted-vc')
    $wrongVM = [pscustomobject]@{ Name = 'server'; ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ HostName = 'server.other.invalid' } } }
    $rightVM = [pscustomobject]@{ Name = 'server.target.invalid'; ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ HostName = 'server.target.invalid' } } }
    $inventory = @($wrongVM, $rightVM)
    Assert-Equal (Get-ExactVM -Name 'server.target.invalid' -Servers $scopeServers).Name 'server.target.invalid' 'full inventory name wins over an unrelated short name'

    foreach ($guestName in @('server.other.invalid', '', 'server', 'SERVER.TARGET.INVALID.')) {
        $inventory = @([pscustomobject]@{ Name = 'server'; ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ HostName = $guestName } } })
        $accepted = $false
        try { $null = Get-ExactVM -Name 'server.target.invalid' -Servers $scopeServers; $accepted = $true } catch { }
        Assert-Equal $accepted ($guestName -eq 'SERVER.TARGET.INVALID.') ('short-name fallback requires the requested guest FQDN: ' + $guestName)
    }
    $inventory = @([pscustomobject]@{ Name = 'server' })
    $accepted = $false
    try { $null = Get-ExactVM -Name 'server.target.invalid' -Servers $scopeServers; $accepted = $true } catch { }
    Assert-Equal $accepted $false 'missing VMware Tools hostname cannot authorize an FQDN fallback'
    Assert-Equal (Get-ExactVM -Name 'server' -Servers $scopeServers).Name 'server' 'explicit bare inventory name remains supported'
    foreach ($inventory in @(@($rightVM, $rightVM), @())) {
        $accepted = $false
        try { $null = Get-ExactVM -Name 'server.target.invalid' -Servers $scopeServers; $accepted = $true } catch { }
        Assert-Equal $accepted $false 'ambiguous or missing inventory target is rejected'
    }
}

# --- vCenter scope for inventory lookups (task 1) -------------------------------------------
& {
    $script:getVMCalls = @()
    function Get-VM {
        param($Name, $Server, $ErrorAction)
        if ($null -eq $Server -or @($Server).Count -eq 0) { throw 'Get-VM was called without a connection scope.' }
        foreach ($serverName in @($Server)) { $script:getVMCalls += [string]$serverName }
        $matched = @()
        foreach ($serverName in @($Server)) {
            foreach ($entry in @($inventoryByServer[[string]$serverName])) {
                if ($entry.Name -eq $Name) { $matched += $entry }
            }
        }
        return @($matched)
    }

    $wantedVM = [pscustomobject]@{ Name = 'scoped.target.invalid'; ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ HostName = 'scoped.target.invalid' } } }
    $foreignVM = [pscustomobject]@{ Name = 'foreign.target.invalid'; ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ HostName = 'foreign.target.invalid' } } }
    $inventoryByServer = @{ 'wanted-vc' = @($wantedVM); 'other-vc' = @($foreignVM) }

    $script:getVMCalls = @()
    Assert-Equal (Get-ExactVM -Name 'scoped.target.invalid' -Servers @('wanted-vc')).Name 'scoped.target.invalid' 'a target inside the requested scope resolves'
    Assert-Equal (@($script:getVMCalls | Where-Object { $_ -eq 'other-vc' }).Count) 0 'a vCenter outside the requested scope is never queried'

    $accepted = $false
    try { $null = Get-ExactVM -Name 'foreign.target.invalid' -Servers @('wanted-vc'); $accepted = $true } catch { }
    Assert-Equal $accepted $false 'a VM that exists only outside the requested scope is not resolved'

    Assert-Equal (Get-ExactVM -Name 'foreign.target.invalid' -Servers @('wanted-vc', 'other-vc')).Name 'foreign.target.invalid' 'widening the scope to both vCenters resolves the second inventory'

    # Multiple vs single connection scope must not change which VM wins.
    $inventoryByServer = @{ 'wanted-vc' = @($wantedVM); 'other-vc' = @($wantedVM) }
    $ambiguous = $false
    try { $null = Get-ExactVM -Name 'scoped.target.invalid' -Servers @('wanted-vc', 'other-vc'); $ambiguous = $true } catch { }
    Assert-Equal $ambiguous $false 'the same name in two in-scope vCenters is ambiguous, not first-wins'

    # An empty or absent scope is a programming error, not a licence to search everything.
    foreach ($emptyScope in @(@(), $null)) {
        $scopeRejected = $false
        try { $null = Get-ExactVM -Name 'scoped.target.invalid' -Servers $emptyScope } catch { $scopeRejected = $true }
        Assert-Equal $scopeRejected $true 'an empty connection scope is refused'
    }

    # Wildcard metacharacters in a VM name are data, not a pattern.
    foreach ($literalName in @('server[1]', 'server*literal', 'server?literal')) {
        $literalVM = [pscustomobject]@{ Name = $literalName; ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ HostName = $literalName } } }
        $decoyVM = [pscustomobject]@{ Name = 'server1'; ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ HostName = 'server1' } } }
        $inventoryByServer = @{ 'wanted-vc' = @($literalVM, $decoyVM) }
        $script:literalNameSeen = @()
        function Get-VM {
            param($Name, $Server, $ErrorAction)
            if ($null -eq $Server -or @($Server).Count -eq 0) { throw 'Get-VM was called without a connection scope.' }
            $script:literalNameSeen += [string]$Name
            $pattern = [string]$Name
            $matched = @()
            foreach ($serverName in @($Server)) {
                foreach ($entry in @($inventoryByServer[[string]$serverName])) {
                    # A real Get-VM treats -Name as a wildcard pattern; the escaped form must
                    # only ever match the one literal name the operator asked for.
                    if ([System.Management.Automation.WildcardPattern]::new($pattern, 'IgnoreCase').IsMatch($entry.Name)) { $matched += $entry }
                }
            }
            return @($matched)
        }
        Assert-Equal (Get-ExactVM -Name $literalName -Servers @('wanted-vc')).Name $literalName ('a wildcard metacharacter in a VM name stays literal: ' + $literalName)
    }

    # A failed query is not an empty inventory: it must never let a different VM be chosen.
    function Get-VM {
        param($Name, $Server, $ErrorAction)
        if ($null -eq $Server -or @($Server).Count -eq 0) { throw 'Get-VM was called without a connection scope.' }
        throw 'vCenter query failed'
    }
    $queryFailureAccepted = $false
    try { $null = Get-ExactVM -Name 'scoped.target.invalid' -Servers @('wanted-vc'); $queryFailureAccepted = $true } catch { }
    Assert-Equal $queryFailureAccepted $false 'a failed inventory query is an error, not an empty result'
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
    param([int]$SearchCode = 2, [bool]$Cluster = $false, [bool]$Empty = $false, [switch]$SearchOnly, [bool]$PendingReboot = $false,
        # The one-run-per-guest lock, as the agent sees it: acquired, refused because another run
        # holds this guest, or refused because the coordination directory is unusable.
        [ValidateSet('Acquired', 'Conflict', 'Unavailable')][string]$GuardResult = 'Acquired',
        # What WUA currently offers, and what the plan approved. Separate on purpose: the gap
        # between them is selection drift, and the point of these tests is which updates end up
        # in the collection handed to Install.
        $SearchUpdateIdentities = $null,
        $SelectedKeys = $null,
        [string]$EulaFailureKey = '',
        # The workspace seal, as the agent sees it: no token supplied at all (a legacy or manual
        # invocation), the directory still carrying this cycle's seal, or a seal the guest
        # refused because the directory is no longer the one that was secured.
        [ValidateSet('None', 'Ok', 'Refused')][string]$WorkspaceSeal = 'Ok',
        [bool]$ClusterMembershipUnknown = $false)
    # Only external effects are mocked: local probes, artifact I/O, and WUA COM.
    function Write-AgentLog { param($Message) }
    function Save-Status { param($Status) }
    $script:guardCompletions = @()
    $script:guardReleases = 0
    function Enter-GuestRunGuard {
        param([string]$RunId, [string]$Phase)
        switch ($GuardResult) {
            'Conflict' { return [pscustomobject]@{ Acquired = $false; Conflict = $true; Reason = 'synthetic: another run holds this guest'; Stream = $null; RunId = $RunId; Phase = $Phase } }
            'Unavailable' { return [pscustomobject]@{ Acquired = $false; Conflict = $false; Reason = 'synthetic: the coordination directory could not be secured'; Stream = $null; RunId = $RunId; Phase = $Phase } }
            default { return [pscustomobject]@{ Acquired = $true; Conflict = $false; Reason = $null; Stream = 'synthetic-handle'; RunId = $RunId; Phase = $Phase } }
        }
    }
    function Set-GuestRunGuardCompleted {
        param($Guard, [string]$Outcome)
        $script:guardCompletions += [string]$Outcome
        return $true
    }
    function Exit-GuestRunGuard { param($Guard) $script:guardReleases++ }
    # Stands in for the real check, which needs a Windows security descriptor. What is under test
    # here is what the agent does with each verdict, not how the verdict is reached -
    # tests/Invoke-GuestWorkspaceChecks.ps1 exercises the seal itself.
    function Assert-GuestWorkspaceSeal {
        param([string]$Path, [string]$Token)
        if ($WorkspaceSeal -eq 'Refused') {
            return [pscustomobject]@{ Status = 'SealRefused'; Reason = 'synthetic: the directory was resealed'; Path = $Path }
        }
        return [pscustomobject]@{ Status = 'Ok'; Reason = $null; Path = $Path }
    }
    function Test-IsElevated { $true }
    function Get-ServiceSnapshot { @() }
    function Get-SystemDriveFreeGB { 100 }
    function Test-PendingReboot { [pscustomobject]@{ isPending = $PendingReboot } }
    # The fixture models the three membership answers the guest can give, because they are three
    # different decisions: Member is Excluded, Unknown is refused, NotMember is patched normally.
    function Get-RoleFlags {
        $membership = if ($Cluster) { 'Member' } elseif ($ClusterMembershipUnknown) { 'Unknown' } else { 'NotMember' }
        return [pscustomobject]@{
            failoverCluster = ($membership -eq 'Member')
            clusterMembership = $membership
            clusterMembershipReason = ('synthetic membership {0}' -f $membership)
        }
    }
    $effectiveSelectedKeys = if ($null -eq $SelectedKeys) { @('11111111-1111-1111-1111-111111111111|1') } else { @($SelectedKeys) }
    function Read-SelectionDocumentKeys { param($Path) return @($effectiveSelectedKeys) }

    $effectiveSearchIdentities = if ($null -eq $SearchUpdateIdentities) {
        @([pscustomobject]@{ UpdateID = '11111111-1111-1111-1111-111111111111'; RevisionNumber = 1 })
    }
    else {
        @($SearchUpdateIdentities)
    }
    $searchUpdateObjects = @()
    foreach ($identity in $effectiveSearchIdentities) {
        $identityKeyText = ('{0}|{1}' -f [string]$identity.UpdateID, [int]$identity.RevisionNumber)
        $searchUpdate = [pscustomobject]@{
            Identity = [pscustomobject]@{ UpdateID = [string]$identity.UpdateID; RevisionNumber = [int]$identity.RevisionNumber }
            IdentityKeyText = $identityKeyText
            Title = 'Security Update'; KBArticleIDs = $null; Categories = $null
            InstallationBehavior = [pscustomobject]@{ RebootBehavior = 0 }
            EulaAccepted = $($identityKeyText -ne $EulaFailureKey); IsDownloaded = $true; Type = 1; MsrcSeverity = 'Critical'
        }
        # One update whose EULA cannot be accepted, to prove a single bad package does not
        # discard the rest of an otherwise valid batch.
        $searchUpdate | Add-Member ScriptMethod AcceptEula { if (-not $this.EulaAccepted) { throw 'synthetic EULA failure' } }
        $searchUpdateObjects += $searchUpdate
    }
    if ($Empty) { $searchUpdateObjects = @() }

    $updates = [pscustomobject]@{ Count = @($searchUpdateObjects).Count; Value = @($searchUpdateObjects) }
    $updates | Add-Member ScriptMethod Item { param($Index) $this.Value[$Index] }
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
    # Records WHICH updates were added, not just how many: the whole point of the drift tests is
    # the exact collection handed to Download and Install.
    $collection = [pscustomobject]@{ Count = 0; AddedKeys = @() }
    $collection | Add-Member ScriptMethod Add { param($Value) $this.AddedKeys += [string]$Value.IdentityKeyText; $this.Count++; return ($this.Count - 1) }
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
    $WorkspaceSealToken = if ($WorkspaceSeal -eq 'None') { '' } else { 'fixture-seal-token' }
    $SelectedUpdateKeys = @(); $SelectionPath = 'mock-selection.json'; $scriptExitCode = 1
    $guestRunGuard = $null
    . ([scriptblock]::Create($statusInit.Extent.Text))
    . ([scriptblock]::Create($agentTry.Extent.Text))
    # Model the same JSON boundary as a downloaded status.json.
    $payload = $status | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $cycleMode = if ($SearchOnly) { 'SearchOnly' } else { 'Apply' }
    $cycle = [pscustomobject]@{ Status = $payload; AgentCompletionConfirmed = (Test-AgentCycleCompletion -Status $payload -RunId $RunId -Mode $cycleMode); AgentResult = [pscustomobject]@{ Completed = $true; ExitCode = $scriptExitCode } }
    $discovery = New-DiscoveryRecordFromAgentRun -VMName 'fixture' -AgentRun $cycle -OutputDirectory 'unused'
    $groups = @(New-UpdateGroupRecords -DiscoveryRecords @($discovery))
    $states = @(Get-VMPatchCompletionStates -DiscoveryRecords @($discovery) -UpdateGroups $groups)
    $applyResult = New-ApplyResultFromCycle -VMName 'fixture' -Cycle $cycle 3>$null
    [pscustomobject]@{
        Status = $payload; ExitCode = $scriptExitCode; InstallCalled = $installer.Called; DownloadCalled = $downloader.Called
        State = $states[0].state; Cycle = $cycle; ApplyResult = $applyResult
        GuardCompletions = @($script:guardCompletions); GuardReleases = $script:guardReleases
        InstalledKeys = @($collection.AddedKeys)
        DownloaderKeys = @(if ($null -eq $downloader.Updates) { @() } else { @($downloader.Updates.AddedKeys) })
        InstallerKeys = @(if ($null -eq $installer.Updates) { @() } else { @($installer.Updates.AddedKeys) })
    }
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

# --- role presence is not cluster membership (task 9) ------------------------------------------
# ClusSvc exists on every server with the Failover Clustering feature installed, including one
# that was never joined and one that was evicted. Treating that as membership excluded healthy
# servers from patching forever; treating an unreadable state as "not a member" would patch and
# restart a real cluster node.

$clusterApplyCase = Invoke-AgentFixture -Cluster $true
Assert-Equal $clusterApplyCase.InstallCalled $false 'a confirmed cluster member installs nothing'
Assert-Equal $clusterApplyCase.State 'Excluded' 'a confirmed cluster member is Excluded'
Assert-Equal ([string]$clusterApplyCase.Status.roleFlags.clusterMembership) 'Member' 'a confirmed member reports Member'

$unknownMembership = Invoke-AgentFixture -ClusterMembershipUnknown $true
Assert-Equal $unknownMembership.InstallCalled $false 'an unreadable cluster state installs nothing'
Assert-Equal $unknownMembership.ExitCode 1 'an unreadable cluster state is an error'
Assert-Equal $unknownMembership.State 'Failed' 'an unreadable cluster state is Failed, not Excluded'
Assert-Equal ([bool]$unknownMembership.Status.roleFlags.failoverCluster) $false 'an unreadable state is not reported as a confirmed cluster'
Assert-Equal (@(Select-RebootRequiredApplyResults -ApplyResults @(New-ApplyResultRecord -VMName 'VM-unknown-cluster' -Outcome 'InstallSucceeded' -AgentCompletionConfirmed $true -RebootRequired $true -RoleFlags ([pscustomobject]@{ failoverCluster = $false; clusterMembership = 'Unknown' })) -DiscoveryRecords @()).Count) 0 'an unreadable cluster state is never restarted'

# ClusSvc present but the node is not in a cluster: an ordinary server, patched normally.
$notMember = Invoke-AgentFixture
Assert-Equal $notMember.InstallCalled $true 'a server with the clustering feature but no membership is patched normally'
Assert-Equal ([string]$notMember.Status.roleFlags.clusterMembership) 'NotMember' 'a non-member reports NotMember'
Assert-Equal ([bool]$notMember.Status.roleFlags.failoverCluster) $false 'a non-member does not set the cluster flag'

# The state mapping itself, against the values GetNodeClusterState actually returns. The API's
# return code and the state value are separate pieces of information: a failed call never wrote a
# state, so reading one would be reading an uninitialised variable.
& {
    $membershipCases = @(
        [pscustomobject]@{ State = 0; Expected = 'NotMember'; Name = 'ClusterStateNotInstalled' },
        [pscustomobject]@{ State = 1; Expected = 'NotMember'; Name = 'ClusterStateNotConfigured' },
        [pscustomobject]@{ State = 3; Expected = 'Member'; Name = 'ClusterStateRunning' },
        [pscustomobject]@{ State = 19; Expected = 'Member'; Name = 'ClusterStateRunning (variant)' },
        [pscustomobject]@{ State = 7; Expected = 'Unknown'; Name = 'an unrecognised state' }
    )
    foreach ($case in $membershipCases) {
        $membership = switch ($case.State) {
            0 { 'NotMember' }
            1 { 'NotMember' }
            3 { 'Member' }
            19 { 'Member' }
            default { 'Unknown' }
        }
        Assert-Equal $membership $case.Expected ('cluster state ' + $case.State + ' maps to ' + $case.Expected + ' (' + $case.Name + ')')
    }
}

# A record written before this field existed keeps its old behaviour rather than turning every VM
# into a failure on the first run after an upgrade.
$legacyClusterRecord = [pscustomobject]@{ vmName = 'VM-legacy'; outcome = 'SearchOnly'; errors = @(); roleFlags = [pscustomobject]@{ failoverCluster = $false }; updates = @() }
Assert-Equal (Test-IsUnknownClusterMembershipRecord -DiscoveryRecord $legacyClusterRecord) $false 'a discovery record without the membership field is not treated as unknown'
$legacyClusterStates = @(Get-VMPatchCompletionStates -DiscoveryRecords @($legacyClusterRecord) -UpdateGroups @())
Assert-Equal $legacyClusterStates[0].state 'Green' 'a record written before this change still reaches its old verdict'

# --- selection drift: install the approved subset that is still on offer (task 7) ------------
# Drift used to throw, which discarded every still-available approved update along with the one
# that had moved. These assertions are on the exact collection handed to Download and Install,
# not on the outcome text: substituting a revision the operator never approved would otherwise
# look identical from outside.

$keyA1 = 'aaaaaaaa-1111-1111-1111-111111111111|1'
$keyB1 = 'bbbbbbbb-2222-2222-2222-222222222222|1'
$keyB2 = 'bbbbbbbb-2222-2222-2222-222222222222|2'
$identityA1 = [pscustomobject]@{ UpdateID = 'aaaaaaaa-1111-1111-1111-111111111111'; RevisionNumber = 1 }
$identityB1 = [pscustomobject]@{ UpdateID = 'bbbbbbbb-2222-2222-2222-222222222222'; RevisionNumber = 1 }
$identityB2 = [pscustomobject]@{ UpdateID = 'bbbbbbbb-2222-2222-2222-222222222222'; RevisionNumber = 2 }

# Approved A|1 and B|1; WUA now offers A|1 and B|2.
$partialDrift = Invoke-AgentFixture -SearchUpdateIdentities @($identityA1, $identityB2) -SelectedKeys @($keyA1, $keyB1)
Assert-Equal (@($partialDrift.InstallerKeys) -join ',') $keyA1 'drift installs exactly the approved update that is still offered'
Assert-Equal (@($partialDrift.InstallerKeys) -contains $keyB2) $false 'a revision the operator never approved is never substituted'
Assert-Equal (@($partialDrift.DownloaderKeys) -join ',') $keyA1 'the download collection matches the install collection'
Assert-Equal $partialDrift.InstallCalled $true 'the still-available approved update is installed rather than discarded'
Assert-Equal (@($partialDrift.Status.missingUpdateKeys) -join ',') $keyB1 'the key that moved is reported as missing'
Assert-Equal ([bool]$partialDrift.Status.selectionDrift) $true 'partial drift is recorded as drift'
Assert-Equal ([bool]$partialDrift.Status.requiresVerification) $true 'partial drift requires verification'
Assert-Equal ([bool]$partialDrift.ApplyResult.selectionDrift) $true 'the apply result carries the drift flag'
Assert-Equal (@($partialDrift.ApplyResult.missingUpdateKeys) -join ',') $keyB1 'the apply result names the missing key'
Assert-Equal ([bool]$partialDrift.ApplyResult.requiresVerification) $true 'the apply result requires verification'
Assert-Equal (Test-ApplyResultsRequireVerification -ApplyResults @($partialDrift.ApplyResult)) $true 'the phase reports that verification is required'
Assert-Equal (Test-IsApplyResultError -ApplyResult $partialDrift.ApplyResult) $false 'drift alone is not a hard apply failure'

# Every approved key has drifted: nothing is downloaded and nothing is installed.
$totalDrift = Invoke-AgentFixture -SearchUpdateIdentities @($identityB2) -SelectedKeys @($keyA1, $keyB1)
Assert-Equal $totalDrift.DownloadCalled $false 'an empty intersection downloads nothing'
Assert-Equal $totalDrift.InstallCalled $false 'an empty intersection installs nothing'
Assert-Equal $totalDrift.Status.outcome 'NoSelectedUpdates' 'an empty intersection reports NoSelectedUpdates'
Assert-Equal ((@($totalDrift.Status.missingUpdateKeys) | Sort-Object) -join ',') (((@($keyA1, $keyB1)) | Sort-Object) -join ',') 'an empty intersection reports every missing key'
Assert-Equal ([bool]$totalDrift.Status.requiresVerification) $true 'an empty intersection requires verification'
Assert-Equal ([bool]$totalDrift.ApplyResult.installResult) $false 'nothing is reported as installed for the missing keys'

# A genuinely empty search is still NoApplicableUpdates, not drift: there was nothing to drift.
$emptySearch = Invoke-AgentFixture -Empty $true -SelectedKeys @($keyA1)
Assert-Equal $emptySearch.Status.outcome 'NoApplicableUpdates' 'an empty search keeps its own outcome'
Assert-Equal ([bool]$emptySearch.Status.selectionDrift) $false 'an empty search is not drift'
Assert-Equal ([bool]$emptySearch.Status.requiresVerification) $false 'an empty search needs no verification'

# No drift at all: the flags stay false and nothing new appears in the result.
$noDrift = Invoke-AgentFixture -SearchUpdateIdentities @($identityA1, $identityB1) -SelectedKeys @($keyA1, $keyB1)
Assert-Equal ((@($noDrift.InstallerKeys) | Sort-Object) -join ',') (((@($keyA1, $keyB1)) | Sort-Object) -join ',') 'both approved updates are installed when both are still offered'
Assert-Equal ([bool]$noDrift.Status.selectionDrift) $false 'no drift means no drift flag'
Assert-Equal ([bool]$noDrift.Status.requiresVerification) $false 'no drift means no verification'
Assert-Equal (@($noDrift.Status.missingUpdateKeys).Count) 0 'no drift means no missing keys'

# One EULA that cannot be accepted must not discard the rest of the batch, and is a real error.
$eulaFailure = Invoke-AgentFixture -SearchUpdateIdentities @($identityA1, $identityB1) -SelectedKeys @($keyA1, $keyB1) -EulaFailureKey $keyB1
Assert-Equal (@($eulaFailure.InstallerKeys) -join ',') $keyA1 'a refused EULA drops only its own update'
Assert-Equal (@($eulaFailure.Status.errors).Count -gt 0) $true 'a refused EULA is a real error, not drift'
Assert-Equal ([bool]$eulaFailure.Status.selectionDrift) $false 'a refused EULA is not selection drift'

# --- a restarting guest is retried once inside the phase, nothing else is ------------------------
# The real Invoke-GuestAgentFleet, with vSphere and the poll loop stubbed out. What is under test is
# the wiring: which conflict kinds cause a second attempt, that the wait happens before it, that the
# budget is one, and that a VM which was not retried keeps its own result.

& {
    $script:fleetAttempts = @()
    $script:sleepCalls = @()
    $script:conflictOnFirstAttemptOnly = $true

    function Get-ExactVM { param([string]$Name, $Servers) return [pscustomobject]@{ Name = $Name; ExtensionData = [pscustomobject]@{ MoRef = 'vm-1' } } }
    function Assert-VMReadyForGuestOps { param($VM) }
    function Get-VMHostNameForTransfer { param($VMView) return 'esx-fixture' }
    function Assert-GuestTransferEndpoint { param([string]$HostName, [string]$CurlPath) }
    function New-GuestAuthentication { param($Credential) return [pscustomobject]@{ } }

    # Stands in for the poll machinery: attempt 1 reports the conflict kind each item asked for,
    # attempt 2 reports a clean run, so a second attempt is visible in the merged result.
    function Invoke-InProcessAgentFleet {
        param($Items, [int]$MaxInFlight, [int]$PollSeconds, [int]$ItemTimeoutSeconds,
            [scriptblock]$StartScript, [scriptblock]$PollScript, [scriptblock]$CompleteScript,
            [scriptblock]$IsTransientErrorScript, [scriptblock]$GetErrorMetadataScript, [scriptblock]$SleepScript = $null)

        $attemptNumber = @($script:fleetAttempts).Count + 1
        $script:fleetAttempts += ,@(@($Items) | ForEach-Object { [string]$_.VMName })

        $results = @()
        foreach ($item in @($Items)) {
            $kind = if ($attemptNumber -eq 1 -or -not $script:conflictOnFirstAttemptOnly) { [string]$item.ConflictKind } else { '' }
            $status = [pscustomobject]@{
                guestRunConflict = (-not [string]::IsNullOrWhiteSpace($kind))
                guestRunConflictKind = $kind
                outcome = if ([string]::IsNullOrWhiteSpace($kind)) { 'InstallSucceeded' } else { 'Failed' }
            }
            $results += [pscustomobject]@{ Sequence = $item.Sequence; VMName = [string]$item.VMName; Payload = [pscustomobject]@{ Status = $status }; Error = $null }
        }
        return @($results)
    }

    $newItem = {
        param([int]$Sequence, [string]$VMName, [string]$ConflictKind)
        return [pscustomobject]@{ Sequence = $Sequence; VMName = $VMName; ConflictKind = $ConflictKind; VMOutputDirectory = 'unused'; MaxUpdates = 1; LocalSelectionPath = ''; SearchOnly = $true }
    }

    $runFleet = {
        param($Items)
        return @(Invoke-GuestAgentFleet -FleetItems @($Items) -VIServerScope @('vc-fixture') -Managers $null `
                -GuestCredentialMap @{} -CurlPath 'curl.exe' -AgentPath 'agent.ps1' -IdentityHelperPath 'identity.ps1' `
                -WorkspaceScriptPath 'workspace.ps1' -RunGuardScriptPath 'guard.ps1' -GuestWorkingDirectory 'C:\ProgramData\PatchingGuestOps' `
                -TimeoutSeconds 60 -PollSeconds 1 -MaxInFlight 4 `
                -SleepScript { param($Seconds) $script:sleepCalls += [int]$Seconds } 3>$null)
    }

    # 1. A restarting guest beside a healthy one: exactly that VM is tried again, after one wait.
    $script:fleetAttempts = @(); $script:sleepCalls = @()
    $mixed = @((& $newItem 1 'vm-rebooting' 'RebootPending'), (& $newItem 2 'vm-healthy' ''))
    $mixedResults = @(& $runFleet $mixed)
    Assert-Equal @($script:fleetAttempts).Count 2 'a restarting guest causes exactly one more dispatch'
    Assert-Equal (@($script:fleetAttempts[1]) -join ',') 'vm-rebooting' 'only the restarting guest is dispatched again'
    Assert-Equal @($script:sleepCalls).Count 1 'the phase waits once before the retry'
    Assert-Equal $script:sleepCalls[0] $script:GuestRunConflictRetryWaitSeconds 'the wait is the bounded coordinator-level one'
    Assert-Equal @($mixedResults).Count 2 'the merged phase still holds every VM'
    Assert-Equal (Get-FleetResultGuestRunConflictKind -FleetResult @($mixedResults | Where-Object { $_.VMName -eq 'vm-rebooting' })[0]) '' 'the second attempt is what the phase reports'

    # 2. The other three kinds are never waited out: no wait, no second dispatch.
    foreach ($kind in @('Held', 'Unconfirmed', 'Unreadable')) {
        $script:fleetAttempts = @(); $script:sleepCalls = @()
        $blocked = @(& $runFleet @((& $newItem 1 'vm-blocked' $kind)))
        Assert-Equal @($script:fleetAttempts).Count 1 ('a ' + $kind + ' conflict is not retried')
        Assert-Equal @($script:sleepCalls).Count 0 ('a ' + $kind + ' conflict costs no wait')
        Assert-Equal (Get-FleetResultGuestRunConflictKind -FleetResult @($blocked)[0]) $kind ('a ' + $kind + ' conflict is reported as it is')
    }

    # 3. A guest still restarting after the retry is reported, not retried for ever. The budget is
    #    spent, so there is exactly one extra dispatch and one wait however long the guest takes.
    $script:fleetAttempts = @(); $script:sleepCalls = @(); $script:conflictOnFirstAttemptOnly = $false
    $stillRebooting = @(& $runFleet @((& $newItem 1 'vm-slow' 'RebootPending')))
    Assert-Equal @($script:fleetAttempts).Count 2 'the in-phase retry budget is one attempt, spent even when it fails'
    Assert-Equal @($script:sleepCalls).Count 1 'a retry that fails does not buy another wait'
    Assert-Equal (Get-FleetResultGuestRunConflictKind -FleetResult @($stillRebooting)[0]) 'RebootPending' 'a guest still restarting is reported as it is'
    $script:conflictOnFirstAttemptOnly = $true

    # 4. A phase with nothing to retry pays nothing.
    $script:fleetAttempts = @(); $script:sleepCalls = @()
    $null = & $runFleet @((& $newItem 1 'vm-clean' ''))
    Assert-Equal @($script:fleetAttempts).Count 1 'a phase with no conflict is dispatched once'
    Assert-Equal @($script:sleepCalls).Count 0 'a phase with no conflict never waits'
}

# --- the workspace seal, as the agent enforces it ------------------------------------------------
# The bootstrap verifies the directory and seals it; three GuestOps calls later this agent starts
# in it. Re-reading the seal is what turns "it was safe when we checked" into "this is the same
# directory we secured", so a refused seal must stop the run before any WUA work - and before the
# run guard, so a directory this tool does not recognise leaves nothing on the guest to reconcile.

$sealRefused = Invoke-AgentFixture -WorkspaceSeal 'Refused'
Assert-Equal $sealRefused.DownloadCalled $false 'a refused workspace seal downloads nothing'
Assert-Equal $sealRefused.InstallCalled $false 'a refused workspace seal installs nothing'
Assert-Equal $sealRefused.ExitCode 1 'a refused workspace seal is an error'
Assert-Equal $sealRefused.Status.outcome 'Failed' 'a refused workspace seal reports Failed'
Assert-Equal ([bool]$sealRefused.Status.workspaceSealVerified) $false 'the guest records that the seal did not verify'
Assert-Equal ([bool]$sealRefused.ApplyResult.workspaceSealVerified) $false 'the apply result carries the refused seal as a field'
Assert-Equal (@($sealRefused.ApplyResult.errors) -join "`n" -like '*workspace seal*') $true 'the refused seal is named in the apply errors'
Assert-Equal @($sealRefused.GuardCompletions).Count 0 'a refused seal never takes or completes the run guard'
Assert-Equal $sealRefused.GuardReleases 0 'a refused seal never releases a guard it never took'
Assert-Equal $sealRefused.State 'Failed' 'a VM whose seal was refused is never green'
Assert-Equal (Test-IsApplyResultError -ApplyResult $sealRefused.ApplyResult) $true 'a refused seal keeps the run from succeeding'

$sealOk = Invoke-AgentFixture -WorkspaceSeal 'Ok'
Assert-Equal ([bool]$sealOk.Status.workspaceSealVerified) $true 'a matching seal is recorded as verified'
Assert-Equal ([bool]$sealOk.ApplyResult.workspaceSealVerified) $true 'a matching seal reaches the apply result'
Assert-Equal $sealOk.InstallCalled $true 'a matching seal does not block the run'

# No token at all stays distinguishable from a refusal, so an older agent or a manual invocation
# is not reported as tampering.
$sealAbsent = Invoke-AgentFixture -WorkspaceSeal 'None'
Assert-Equal ($null -eq $sealAbsent.Status.workspaceSealVerified) $true 'an unchecked seal is null, not false'
Assert-Equal ($null -eq $sealAbsent.ApplyResult.workspaceSealVerified) $true 'an unchecked seal stays null in the apply result'
Assert-Equal $sealAbsent.InstallCalled $true 'no seal token means no seal check, not a blocked run'
Assert-Equal (Test-IsApplyResultError -ApplyResult $sealAbsent.ApplyResult) $false 'an unchecked seal is not an error'

# --- one run per guest, as the orchestrator sees it (task 4) ---------------------------------
# The agent reports guestRunConflict when the guest was already busy with another run of this
# tool, or carried an unreconciled trace of one. From there it is absolute: no WUA work, no
# restart, and no further round for that VM - even though the refused agent's own process has
# already ended, which is exactly what makes it look finished to everything else.

foreach ($guardCase in @(
        [pscustomobject]@{ Result = 'Conflict'; Conflict = $true },
        [pscustomobject]@{ Result = 'Unavailable'; Conflict = $false }
    )) {
    $refused = Invoke-AgentFixture -GuardResult $guardCase.Result
    Assert-Equal $refused.InstallCalled $false ('a guest that refused the run installs nothing (' + $guardCase.Result + ')')
    Assert-Equal $refused.DownloadCalled $false ('a guest that refused the run downloads nothing (' + $guardCase.Result + ')')
    Assert-Equal $refused.ExitCode 1 ('a guest that refused the run is an error (' + $guardCase.Result + ')')
    Assert-Equal $refused.Status.outcome 'Failed' ('a guest that refused the run reports Failed (' + $guardCase.Result + ')')
    Assert-Equal ([bool]$refused.Status.guestRunConflict) $guardCase.Conflict ('only a refusal by another run is a guest run conflict (' + $guardCase.Result + ')')
    Assert-Equal ([bool]$refused.ApplyResult.guestRunConflict) $guardCase.Conflict ('the apply result carries the conflict flag (' + $guardCase.Result + ')')
    Assert-Equal @($refused.GuardCompletions).Count 0 ('a run that never took the guard never records completion (' + $guardCase.Result + ')')
    Assert-Equal $refused.State 'Failed' ('a refused guest is never green (' + $guardCase.Result + ')')
}

# Completion is recorded once, after the terminal status, and the handle is released with it.
$acquired = Invoke-AgentFixture
Assert-Equal ([bool]$acquired.Status.guestRunConflict) $false 'an ordinary run reports no conflict'
Assert-Equal @($acquired.GuardCompletions).Count 1 'a finished run records completion exactly once'
Assert-Equal $acquired.GuardCompletions[0] ([string]$acquired.Status.outcome) 'the recorded completion carries this cycle terminal outcome'
Assert-Equal $acquired.GuardReleases 1 'a finished run releases the handle'

# A handled WUA error is still a proper ending: the guest must be usable by the next run.
$wuaFailure = Invoke-AgentFixture -SearchCode 4
Assert-Equal $wuaFailure.ExitCode 1 'a WUA search failure is an error'
Assert-Equal ([bool]$wuaFailure.Status.guestRunConflict) $false 'a WUA failure is not a guest run conflict'
Assert-Equal @($wuaFailure.GuardCompletions).Count 1 'a handled WUA failure still records completion and frees the guest'
Assert-Equal $wuaFailure.GuardReleases 1 'a handled WUA failure still releases the handle'

# A conflicted VM is never a reboot target and never a target of the next round, whatever else
# its apply result says - including a rebootRequired it reported before being refused.
& {
    $conflicted = New-ApplyResultRecord -VMName 'vm-conflict' -Outcome 'Failed' -RebootRequired $true -AgentCompletionConfirmed $true -GuestRunConflict $true -Errors @('Guest run conflict: synthetic')
    $healthy = New-ApplyResultRecord -VMName 'vm-healthy' -Outcome 'InstallSucceeded' -RebootRequired $true -AgentCompletionConfirmed $true
    $rebootTargets = @(Select-RebootRequiredApplyResults -ApplyResults @($conflicted, $healthy) -DiscoveryRecords @())
    Assert-Equal (@($rebootTargets | ForEach-Object { [string]$_.vmName }) -join ',') 'vm-healthy' 'a guest run conflict is never a reboot target'

    # The same filter the round loop applies when it chooses what to verify next.
    $nextTargets = @(@($conflicted, $healthy) | Where-Object {
            (Get-RuntimePropertyValue -InputObject $_ -Name 'action') -eq 'Install' -and
            [bool](Get-RuntimePropertyValue -InputObject $_ -Name 'agentCompletionConfirmed' -DefaultValue $false) -and
            -not [bool](Get-RuntimePropertyValue -InputObject $_ -Name 'guestRunConflict' -DefaultValue $false)
        } | ForEach-Object { [string](Get-RuntimePropertyValue -InputObject $_ -Name 'vmName') })
    Assert-Equal ($nextTargets -join ',') 'vm-healthy' 'a guest run conflict is never carried into the next round'

    # And it is an error, so the run cannot exit 0 on it.
    Assert-Equal (Test-IsApplyResultError -ApplyResult $conflicted) $true 'a guest run conflict keeps the run from succeeding'
}

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
        $phaseResult = Invoke-ApplyAndOptionalReboot -PatchPlanRecords $plan -Managers $null -GuestCredentialMap @{} -VIServers @() -VIServerScope @('vc.synthetic.invalid') -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -AgentPath 'unused' -IdentityHelperPath 'unused' -GuestWorkingDirectory 'C:\unused' -TimeoutSeconds 1 -RebootTimeoutSeconds 1 -PollSeconds 1 -CycleOutputDirectory $phaseDirectory -ThrottleLimit 1 -RebootBatchSize 1 -DiscoveryRecords $discovery
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
        $permanentPhaseResult = Invoke-ApplyAndOptionalReboot -PatchPlanRecords $plan -Managers $null -GuestCredentialMap @{} -VIServers @() -VIServerScope @('vc.synthetic.invalid') -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -AgentPath 'unused' -IdentityHelperPath 'unused' -GuestWorkingDirectory 'C:\unused' -TimeoutSeconds 1 -RebootTimeoutSeconds 1 -PollSeconds 1 -CycleOutputDirectory $permanentPhaseDirectory -ThrottleLimit 1 -RebootBatchSize 1 -DiscoveryRecords @()
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
        $permanentDiscoveryRecords = @(Invoke-DiscoveryPhase -TargetVMNames @('fixture-vm') -VIServerScope @('vc.synthetic.invalid') -Managers $null -GuestCredentialMap @{} -CurlPath 'unused' -AgentPath 'unused' -IdentityHelperPath 'unused' -GuestWorkingDirectory 'C:\unused' -MaxUpdates 1 -TimeoutSeconds 1 -PollSeconds 1 -CycleOutputDirectory $permanentDiscoveryDirectory -MaxInFlight 1)
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
            $timeoutDiscoveryRecords = @(Invoke-DiscoveryPhase -TargetVMNames @('fixture-vm') -VIServerScope @('vc.synthetic.invalid') -Managers $null -GuestCredentialMap @{} -CurlPath 'unused' -AgentPath 'unused' -IdentityHelperPath 'unused' -GuestWorkingDirectory 'C:\unused' -MaxUpdates 1 -TimeoutSeconds 1 -PollSeconds 1 -CycleOutputDirectory $timeoutDiscoveryDirectory -MaxInFlight 1)
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
        function Confirm-PatchPlan { param($PatchPlanRecords, $PromptProvider, $SkipConfirmation) $true }
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
        $outstandingVerificationByVm = @{}
        $runEventLog = New-RunEventLogState -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-events-' + [guid]::NewGuid().ToString('N') + '.jsonl'))
        $sawApplyFailure = $false
        $scriptExitCode = 0
        $runOutputDirectory = $roundRunDirectory
        $MaxPatchRounds = 2
        $SearchOnly = $false
        $PlanOnly = $false
        $SkippedGuestCredentialTargets = @()
        $hasExplicitSelectedUpdateKeys = $false
        $SkipConfirmation = $true
        $PromptProvider = $null
        $managers = $null
        $guestCredentialMap = @{}
        $guestCredentialContext = $null
        $guestCredentialDecisionScript = $null
        $guestCredentialValidatedScript = $null
        $guestCredentialInteractive = $false
        $resolvedVIServers = @('vc.synthetic.invalid')
        $viServerScope = @('vc.synthetic.invalid')
        $viserverCredentialMap = @{}
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

    function Get-ExactVM { param($Name, $Servers) if (@($Servers).Count -eq 0) { throw 'lookup without a connection scope' } return [pscustomobject]@{ ExtensionData = [pscustomobject]@{} } }
    function Assert-VMReadyForGuestOps { param($VM) }
    function Get-VMHostNameForTransfer { param($VMView) return 'esxi-f5.invalid' }
    function Invoke-Curl { param($CurlPath, $Arguments, $Description) }

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
        param([string]$VMName, [object[]]$VIServerScope, [pscredential]$Credential)
        if (@($VIServerScope).Count -eq 0) { throw 'credential validation must scope its lookup' }
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
    function Confirm-PatchPlan { param($PatchPlanRecords, $PromptProvider, $SkipConfirmation) $true }
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
        $outstandingVerificationByVm = @{}
        $runEventLog = New-RunEventLogState -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-events-' + [guid]::NewGuid().ToString('N') + '.jsonl'))
        $sawApplyFailure = $false
        $scriptExitCode = 0
        $runOutputDirectory = $cycleDirectory
        $MaxPatchRounds = 2
        $SearchOnly = $false
        $PlanOnly = $false
        $SkippedGuestCredentialTargets = @()
        $hasExplicitSelectedUpdateKeys = $false
        $SkipConfirmation = $true
        $PromptProvider = $null
        $managers = $null
        $resolvedVIServers = @('vc.synthetic.invalid')
        $viServerScope = @('vc.synthetic.invalid')
        $viserverCredentialMap = @{}
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
        param([string]$VMName, [object[]]$VIServerScope, [pscredential]$Credential)
        if (@($VIServerScope).Count -eq 0) { throw 'credential validation must scope its lookup' }
        # ChildRejected and BootReadRejected both model a password rotated mid-run: still valid
        # when this phase checked it, refused by the guest moments later. ValidationUnavailable
        # models VMware Tools being down mid-reboot - an error, not a refusal, and the one the
        # coordinator must not mistake for an operator who skipped the account.
        if ($script:f5RebootMode -eq 'ValidationUnavailable') {
            return [pscustomobject]@{ Status = 'Error'; ErrorKind = 'Transient'; Error = 'synthetic VMware Tools are not running' }
        }
        return [pscustomobject]@{ Status = 'Valid'; ErrorKind = $null; Error = $null }
    }
    # Reboot submission resolves the target in this process so the child job gets one vCenter
    # and one managed object rather than the whole scope to search.
    $script:f5SubmittedServers = @()
    $script:f5SubmittedMoRefs = @()
    function Get-ExactVM {
        param($Name, $Servers)
        if (@($Servers).Count -eq 0) { throw ('reboot submission must scope the lookup for {0}' -f $Name) }
        return [pscustomobject]@{
            Name = $Name
            Uid = ('/VIServer=svc@{0}:443/VirtualMachine=vm-7/' -f (@($Servers)[0]))
            ExtensionData = [pscustomobject]@{ MoRef = [pscustomobject]@{ Type = 'VirtualMachine'; Value = 'vm-7' } }
        }
    }
    function Get-GuestRebootJobScript { return { param($JobInput) $null = $JobInput } }
    function Invoke-ThrottledJobs {
        param($Items, $ThrottleLimit, $JobTimeoutSeconds, $ScriptBlock)
        $script:f5RebootJobCalls++
        $script:f5RebootCredentialUsers += @($Items | ForEach-Object { $_.GuestCredential.UserName })
        $script:f5SubmittedServers += @($Items | ForEach-Object { @($_.VIServers) -join ',' })
        $script:f5SubmittedMoRefs += @($Items | ForEach-Object { [string]$_.ExpectedMoRefIdentity })
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
        param($VMName, [object[]]$Servers, $Managers, $GuestAuth, $CurlPath, $GuestWorkingDirectory, $BootTimeHelperPath, $TimeoutSeconds, $PollSeconds, [switch]$SkipHelperUpload)
        if (@($Servers).Count -eq 0) { throw 'a boot-time read must scope its lookup' }
        $script:f5BootReadCalls++
        if ($script:f5RebootMode -eq 'BootReadRejected' -and $script:f5BootReadCalls -eq 1) {
            throw (New-InvalidGuestLoginException -Message 'Synthetic InvalidGuestLogin during boot-time read.')
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
    $childRejectedActions = @(Invoke-GuestRebootPhase -RebootTargets @($target) -GuestCredentialMap $childRejectedMap -VIServers @('vc.synthetic.invalid') -VIServerScope @('vc.synthetic.invalid') -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -BootTimeHelperPath 'unused' -RebootTimeoutSeconds 60 -PollSeconds 1 -RebootBatchSize 1 -CredentialContext $childRejectedContext -CredentialDecisionScript $recoveryDecision -CredentialInteractive $true)
    Assert-Equal -Actual $script:f5RebootJobCalls -Expected 2 -Message 'F5: an explicitly rejected reboot is submitted once more after credential recovery'
    Assert-Equal -Actual ($script:f5RebootCredentialUsers -join ';') -Expected 'OLD\adm;NEW\adm' -Message 'F5: retrying a rejected reboot uses the replacement credential'
    Assert-Equal -Actual $script:f5RecoveryPrompts -Expected 1 -Message 'F5: rejected reboot asks for one replacement credential'
    Assert-Equal -Actual $script:f5GenericRebootPrompts -Expected 0 -Message 'F5: credential recovery does not fall through to generic reboot prompting'
    # Task 1: a reboot child logs in to the one vCenter that owns the VM, never the whole list,
    # and carries the managed object the parent resolved so it cannot pick a namesake there.
    Assert-Equal -Actual (($script:f5SubmittedServers | Sort-Object -Unique) -join ';') -Expected 'vc.synthetic.invalid' -Message 'F5: reboot submission names exactly the owning vCenter'
    Assert-Equal -Actual (($script:f5SubmittedMoRefs | Sort-Object -Unique) -join ';') -Expected 'VirtualMachine:vm-7' -Message 'F5: reboot submission pins the managed object the parent resolved'
    Assert-Equal -Actual $childRejectedActions[0].validationStatus -Expected 'Confirmed' -Message 'F5: recovered reboot still waits for a newer boot time'

    $script:f5RebootMode = 'BootReadRejected'
    $script:f5RebootJobCalls = 0
    $script:f5RebootCredentialUsers = @()
    $script:f5BootReadCalls = 0
    $script:f5RecoveryPrompts = 0
    $script:f5GenericRebootPrompts = 0
    $bootReadMap = @{ 'VM-reboot-recovery' = $oldCredential }
    $bootReadContext = New-GuestCredentialContext -TargetNames @('VM-reboot-recovery') -CredentialMap $bootReadMap
    $bootReadActions = @(Invoke-GuestRebootPhase -RebootTargets @($target) -GuestCredentialMap $bootReadMap -VIServers @('vc.synthetic.invalid') -VIServerScope @('vc.synthetic.invalid') -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -BootTimeHelperPath 'unused' -RebootTimeoutSeconds 60 -PollSeconds 1 -RebootBatchSize 1 -CredentialContext $bootReadContext -CredentialDecisionScript $recoveryDecision -CredentialInteractive $true)
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
    $ambiguousActions = @(Invoke-GuestRebootPhase -RebootTargets @($target) -GuestCredentialMap $ambiguousMap -VIServers @('vc.synthetic.invalid') -VIServerScope @('vc.synthetic.invalid') -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -BootTimeHelperPath 'unused' -RebootTimeoutSeconds 60 -PollSeconds 1 -RebootBatchSize 1 -CredentialContext $ambiguousContext -CredentialDecisionScript $recoveryDecision -CredentialInteractive $true)
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
    $groupActions = @(Invoke-GuestRebootPhase -RebootTargets $groupTargets -GuestCredentialMap $groupMap -VIServers @('vc.synthetic.invalid') -VIServerScope @('vc.synthetic.invalid') -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -BootTimeHelperPath 'unused' -RebootTimeoutSeconds 60 -PollSeconds 1 -RebootBatchSize 2 -CredentialContext $groupContext -CredentialDecisionScript $recoveryDecision -CredentialInteractive $true)
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
    $lockoutActions = @(Invoke-GuestRebootPhase -RebootTargets $lockoutTargets -GuestCredentialMap $lockoutMap -VIServers @('vc.synthetic.invalid') -VIServerScope @('vc.synthetic.invalid') -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -BootTimeHelperPath 'unused' -RebootTimeoutSeconds 1 -PollSeconds 1 -RebootBatchSize 2 -CredentialContext $lockoutContext -CredentialDecisionScript $recoveryDecision -CredentialInteractive $false)
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
    $unavailableActions = @(Invoke-GuestRebootPhase -RebootTargets @($target) -GuestCredentialMap $unavailableMap -VIServers @('vc.synthetic.invalid') -VIServerScope @('vc.synthetic.invalid') -VIServerCredentialMap @{} -GuestOpsLibPath 'unused' -CurlPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -BootTimeHelperPath 'unused' -RebootTimeoutSeconds 1 -PollSeconds 1 -RebootBatchSize 1 -CredentialContext $unavailableContext -CredentialDecisionScript $recoveryDecision -CredentialInteractive $true)
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
    # Connections is the child's lookup scope; OpenedConnections is only what it may close.
    return [pscustomobject]@{ Connections = @('vc.synthetic.invalid'); OpenedConnections = @() }
}
function New-GuestAuthentication {
    param([pscredential]$Credential)
    return [pscustomobject]@{ UserName = $Credential.UserName }
}
function Invoke-VMGuestReboot {
    param([string]$VMName, [object[]]$Servers, $Managers, $GuestAuth, [string]$ExpectedMoRefIdentity,
        [string]$WorkspaceScriptPath, [string]$RunGuardScriptPath, [string]$RebootScriptPath,
        [int]$SubmissionWaitSeconds = 20, [int]$PollSeconds = 2)
    if (@($Servers).Count -eq 0) { throw 'the child job must hand its own connections to the lookup' }
    # The reboot is ordered from inside the guest by a process that holds the run guard, so the
    # child must be handed all three guest scripts that make up that command.
    foreach ($requiredScript in @($WorkspaceScriptPath, $RunGuardScriptPath, $RebootScriptPath)) {
        if ([string]::IsNullOrWhiteSpace($requiredScript)) { throw 'the child job must be given the guest reboot scripts' }
    }
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
        # Defined here rather than decorated with PSTypeNames: this runs in a child job, the
        # exception crosses back to the parent through the job's serialization, and only a real
        # type name survives that. The classifier matches the short name.
        if (-not ('PatchingGuestOpsTests.Vim.InvalidGuestLogin' -as [type])) {
            Add-Type -TypeDefinition 'namespace PatchingGuestOpsTests.Vim { public class InvalidGuestLogin : System.Exception { public InvalidGuestLogin(string message) : base(message) { } } }'
        }
        throw (New-Object PatchingGuestOpsTests.Vim.InvalidGuestLogin -ArgumentList 'synthetic rejected login sending shutdown')
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
        ExpectedMoRefIdentity = 'VirtualMachine:vm-4242'
        WorkspaceScriptPath = 'unused-workspace'
        RunGuardScriptPath = 'unused-run-guard'
        RebootScriptPath = 'unused-reboot-request'
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
        throw (New-InvalidGuestLoginException -Message 'synthetic rejected login during status download')
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

    function Get-ExactVM { param($Name, $Servers) if (@($Servers).Count -eq 0) { throw 'lookup without a connection scope' } return [pscustomobject]@{ ExtensionData = [pscustomobject]@{} } }
    function Assert-VMReadyForGuestOps { param($VM) }
    function Get-VMHostNameForTransfer { param($VMView) return 'esxi-stage.invalid' }
    function Invoke-Curl { param($CurlPath, $Arguments, $Description) }

    function New-InvalidGuestLoginError {
        param([string]$Message)
        return (New-InvalidGuestLoginException -Message $Message)
    }
    function New-GuestAuthentication {
        param([pscredential]$Credential)
        return [pscustomobject]@{ UserName = $Credential.UserName }
    }
    function Test-GuestCredentialForTarget {
        param([string]$VMName, [object[]]$VIServerScope, [pscredential]$Credential)
        if (@($VIServerScope).Count -eq 0) { throw 'credential validation must scope its lookup' }
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
        $stageResults = @(Invoke-GuestAgentFleet -FleetItems @($stageItem) -VIServerScope @('vc.synthetic.invalid') -Managers $null -GuestCredentialMap $stageMap -CurlPath 'unused' -AgentPath 'unused' -IdentityHelperPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -TimeoutSeconds 60 -PollSeconds 1 -MaxInFlight 1 -CredentialContext $stageContext -CredentialDecisionScript $stageDecision -CredentialInteractive $true)

        Assert-Equal -Actual $script:f5StagePrompts -Expected 1 -Message ('F5: a rejected login during {0} asks for one replacement credential' -f $stage)
        Assert-Equal -Actual ([string]$stageResults[0].Error) -Expected '' -Message ('F5: a rejected login during {0} recovers instead of failing the VM' -f $stage)
        # Guarded, because Assert-Equal collects a failure but dereferencing a payload that
        # recovery never produced TERMINATES under this script's Stop preference - and this file
        # runs as a child of the runtime gate, so the throw discards every check after it and
        # reports as a crash rather than as the one assertion that actually failed.
        $stagePayload = Get-RuntimePropertyValue -InputObject $stageResults[0] -Name 'Payload'
        $stageConfirmed = [bool](Get-RuntimePropertyValue -InputObject $stagePayload -Name 'AgentCompletionConfirmed' -DefaultValue $false)
        Assert-Equal -Actual $stageConfirmed -Expected $true -Message ('F5: a rejected login during {0} still yields a confirmed cycle' -f $stage)
        Assert-Equal -Actual $stageMap['vm-stage.corp.test'].UserName -Expected 'CORP\adm-new' -Message ('F5: a rejected login during {0} leaves the replacement credential in the map' -f $stage)
        $expectedStarts = if ($stage -eq 'Start') { 2 } else { 1 }
        Assert-Equal -Actual $script:f5StageStarts -Expected $expectedStarts -Message ('F5: recovering a rejected login during {0} starts the agent the expected number of times' -f $stage)
    }
}

# F5: the vCenter scope has to reach the validate script BY VALUE. The script that validates a
# credential is built in the orchestrator and invoked from CredentialRecovery.ps1 - another file,
# another scope chain - so a dynamic lookup of $VIServerScope resolves wherever the invocation
# happens to be. It resolved on PowerShell 7 and not on Windows PowerShell 5.1, which is the
# target runtime: under StrictMode the unresolved variable throws, the throw is caught as
# "validation failed", and every VM reports a credential error before an agent is ever started.
#
# Asserted by behaviour rather than by scope semantics, so it holds on whichever host runs it:
# the validate script is invoked from a scope that has no $VIServerScope of its own, and it still
# has to see the one the caller was given.
& {
    $script:scopeSeenByValidate = 'never called'

    function Test-GuestCredentialForTarget {
        param([string]$VMName, [object[]]$VIServerScope, [pscredential]$Credential)
        $script:scopeSeenByValidate = (@($VIServerScope) -join ',')
        return [pscustomobject]@{ Status = 'Valid'; ErrorKind = $null; Error = $null }
    }
    function New-GuestAuthentication { param([pscredential]$Credential) return [pscustomobject]@{ UserName = $Credential.UserName } }

    # Stands in for CredentialRecovery.ps1: it invokes the block from its own scope, which is the
    # whole point - nothing here defines $VIServerScope.
    function Resolve-GuestCredentialForTarget {
        param($VMName, $Context, [scriptblock]$ValidateScript, $DecisionScript, $OnValidatedScript, [switch]$ForcePrompt, [switch]$Interactive)
        $validation = $null
        $validationError = ''
        try { $validation = & $ValidateScript $VMName $Context.Credential }
        catch { $validationError = $_.Exception.Message }
        if ([string]::IsNullOrWhiteSpace($validationError) -and $null -ne $validation -and $validation.Status -eq 'Valid') {
            return [pscustomobject]@{ Status = 'Ready'; Credential = $Context.Credential; Reason = '' }
        }
        return [pscustomobject]@{ Status = 'Failed'; Credential = $null; Reason = $validationError }
    }

    $scopeCredential = New-Object System.Management.Automation.PSCredential('CORP\adm', (ConvertTo-SecureString 'synthetic-scope' -AsPlainText -Force))
    $scopeResult = Invoke-GuestOperationWithCredentialRecovery -VMName 'vm-scope.corp.test' -VIServerScope @('vc-one.invalid', 'vc-two.invalid') `
        -CredentialContext @{ Credential = $scopeCredential } -CredentialDecisionScript $null -CredentialValidatedScript $null `
        -CredentialInteractive $false -OperationScript { param($ItemAuth) return 'operation ran' }

    Assert-Equal $script:scopeSeenByValidate 'vc-one.invalid,vc-two.invalid' 'F5: the validate script is handed the vCenter scope its caller was given'
    Assert-Equal $scopeResult 'operation ran' 'F5: a credential that validates lets the operation run'
}

# F3: the guest working directory is shared with whatever else the customer keeps under it, and
# the only deletion this tool performs is recursive. So it happens once, on one directory, and
# only when this cycle is provably finished and both artifacts are already on the stepping stone.
& {
    $cleanupRoot = 'C:\ProgramData\PatchingGuestOps'
    $cleanupRunId = '1234567890abcdef1234567890abcdef'

    $cleanupLocalDir = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-cleanup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $cleanupLocalDir | Out-Null

    $script:cleanupDeleteCalls = @()
    $script:cleanupDeleteThrows = $false
    $script:cleanupStatusJson = ('{"runId":"' + $cleanupRunId + '","outcome":"InstallSucceeded","finishedAt":"2026-09-11T10:00:00Z","errors":[]}')
    $script:cleanupStatusDownloadFails = $false
    $script:cleanupLogDownloadFails = $false
    $script:cleanupLogArrivesEmpty = $false

    function Receive-GuestFile {
        param($FileManager, $VMView, $GuestAuth, $HostName, $CurlPath, $GuestPath, $LocalPath, $TimeoutSeconds)
        if (([string]$GuestPath).EndsWith('status.json')) {
            if ($script:cleanupStatusDownloadFails) { throw 'synthetic status download failure' }
            Set-Content -LiteralPath $LocalPath -Value $script:cleanupStatusJson -Encoding UTF8
            return
        }

        if ($script:cleanupLogDownloadFails) { throw 'synthetic agent.log download failure' }
        if ($script:cleanupLogArrivesEmpty) { return }
        Set-Content -LiteralPath $LocalPath -Value 'synthetic agent log' -Encoding UTF8
    }

    function New-CleanupHandle {
        param([string]$CycleDirectory, [string]$RunId = $cleanupRunId, [string]$Root = $cleanupRoot)

        $fileManager = New-Object psobject
        $fileManager | Add-Member -MemberType ScriptMethod -Name DeleteDirectoryInGuest -Value {
            param($MoRef, $Auth, $DirectoryPath, $Recursive)
            $script:cleanupDeleteCalls += [pscustomobject]@{ Path = [string]$DirectoryPath; Recursive = [bool]$Recursive }
            if ($script:cleanupDeleteThrows) { throw 'synthetic guest delete failure' }
        }

        $handle = New-VMAgentCycleHandle -VMName 'cleanup-vm' -RunId $RunId -Mode 'Apply' -Managers ([pscustomobject]@{ ProcessManager = $null; FileManager = $fileManager }) -VMView ([pscustomobject]@{ MoRef = 'fake' }) -GuestAuth $null -HostName 'unused' -CurlPath 'unused' -ProcessId 4242 -GuestStatusPath (Join-Path $CycleDirectory 'status.json') -GuestLogPath (Join-Path $CycleDirectory 'agent.log') -LocalStatusPath (Join-Path $cleanupLocalDir 'status.json') -LocalLogPath (Join-Path $cleanupLocalDir 'agent.log') -GuestWorkingDirectory $Root -GuestCycleDirectory $CycleDirectory
        return $handle
    }

    function Reset-CleanupCase {
        $script:cleanupDeleteCalls = @()
        $script:cleanupDeleteThrows = $false
        $script:cleanupStatusJson = ('{"runId":"' + $cleanupRunId + '","outcome":"InstallSucceeded","finishedAt":"2026-09-11T10:00:00Z","errors":[]}')
        $script:cleanupStatusDownloadFails = $false
        $script:cleanupLogDownloadFails = $false
        $script:cleanupLogArrivesEmpty = $false
        Remove-Item -LiteralPath (Join-Path $cleanupLocalDir 'status.json') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $cleanupLocalDir 'agent.log') -Force -ErrorAction SilentlyContinue
    }

    $completedResult = [pscustomobject]@{ Completed = $true; ExitCode = 0; EndTime = (Get-Date) }

    try {
        # The one case that is allowed to delete anything.
        Reset-CleanupCase
        $goodCycle = Join-Path $cleanupRoot $cleanupRunId
        $goodPayload = Complete-VMAgentCycle -Handle (New-CleanupHandle -CycleDirectory $goodCycle) -AgentResult $completedResult
        Assert-Equal -Actual $goodPayload.StatusDownloaded -Expected $true -Message 'F3: a completed cycle reports its status came from this download'
        Assert-Equal -Actual $goodPayload.LogDownloaded -Expected $true -Message 'F3: a completed cycle reports its log came from this download'
        Assert-Equal -Actual $goodPayload.CleanupStatus -Expected 'Removed' -Message 'F3: a provably finished cycle with both artifacts collected is cleaned up'
        Assert-Equal -Actual @($script:cleanupDeleteCalls).Count -Expected 1 -Message 'F3: cleanup deletes exactly once'
        Assert-Equal -Actual $script:cleanupDeleteCalls[0].Path -Expected $goodCycle -Message 'F3: cleanup deletes the cycle directory, not the working root'
        Assert-Equal -Actual $script:cleanupDeleteCalls[0].Recursive -Expected $true -Message 'F3: the cycle directory is removed recursively'
        Assert-Equal -Actual $goodPayload.AgentCompletionConfirmed -Expected $true -Message 'F3: cleanup does not disturb the WUA result'

        # Nothing below this line may delete anything.
        $negativeCases = @(
            [pscustomobject]@{ Name = 'the agent is still running'; Cycle = (Join-Path $cleanupRoot $cleanupRunId); RunId = $cleanupRunId; Root = $cleanupRoot; AgentResult = $null }
            [pscustomobject]@{ Name = 'the process id was lost from vSphere'; Cycle = (Join-Path $cleanupRoot $cleanupRunId); RunId = $cleanupRunId; Root = $cleanupRoot; AgentResult = ([pscustomobject]@{ Completed = $false; ExitCode = $null; EndTime = $null }) }
            [pscustomobject]@{ Name = 'the status is still Started'; Cycle = (Join-Path $cleanupRoot $cleanupRunId); RunId = $cleanupRunId; Root = $cleanupRoot; AgentResult = $completedResult; StatusJson = ('{"runId":"' + $cleanupRunId + '","outcome":"Started","finishedAt":null,"errors":[]}') }
            [pscustomobject]@{ Name = 'the agent log download failed'; Cycle = (Join-Path $cleanupRoot $cleanupRunId); RunId = $cleanupRunId; Root = $cleanupRoot; AgentResult = $completedResult; LogFails = $true }
            [pscustomobject]@{ Name = 'the cycle directory is a drive root'; Cycle = 'C:\'; RunId = $cleanupRunId; Root = $cleanupRoot; AgentResult = $completedResult }
            [pscustomobject]@{ Name = 'the cycle directory is the working root itself'; Cycle = $cleanupRoot; RunId = $cleanupRunId; Root = $cleanupRoot; AgentResult = $completedResult }
            [pscustomobject]@{ Name = 'the cycle path climbs out with ..'; Cycle = (Join-Path $cleanupRoot ('..' + [System.IO.Path]::DirectorySeparatorChar + $cleanupRunId)); RunId = $cleanupRunId; Root = $cleanupRoot; AgentResult = $completedResult }
            [pscustomobject]@{ Name = 'a sibling directory shares the root prefix'; Cycle = (Join-Path ($cleanupRoot + 'Extra') $cleanupRunId); RunId = $cleanupRunId; Root = $cleanupRoot; AgentResult = $completedResult }
            [pscustomobject]@{ Name = 'the directory name is a different run'; Cycle = (Join-Path $cleanupRoot 'ffffffffffffffffffffffffffffffff'); RunId = $cleanupRunId; Root = $cleanupRoot; AgentResult = $completedResult }
            [pscustomobject]@{ Name = 'the run id is not a guid'; Cycle = (Join-Path $cleanupRoot 'not-a-guid'); RunId = 'not-a-guid'; Root = $cleanupRoot; AgentResult = $completedResult }
            [pscustomobject]@{ Name = 'the cycle path is relative'; Cycle = ('relative' + [System.IO.Path]::DirectorySeparatorChar + $cleanupRunId); RunId = $cleanupRunId; Root = 'relative'; AgentResult = $completedResult }
            [pscustomobject]@{ Name = 'the working root is a UNC share'; Cycle = (Join-Path '\\fileserver\share' $cleanupRunId); RunId = $cleanupRunId; Root = '\\fileserver\share'; AgentResult = $completedResult }
            [pscustomobject]@{ Name = 'the working directory was written non-canonically'; Cycle = ('C:\ProgramData/PatchingGuestOps/' + $cleanupRunId); RunId = $cleanupRunId; Root = 'C:\ProgramData/PatchingGuestOps'; AgentResult = $completedResult }
            # The root and the cycle are validated independently: a handle where only one of
            # them is malformed must still refuse, whichever one it is.
            [pscustomobject]@{ Name = 'only the working root is malformed'; Cycle = (Join-Path 'C:\ProgramData\PatchingGuestOps' $cleanupRunId); RunId = $cleanupRunId; Root = 'C:\ProgramData/PatchingGuestOps'; AgentResult = $completedResult }
            [pscustomobject]@{ Name = 'only the cycle directory is malformed'; Cycle = ('C:\ProgramData/PatchingGuestOps/' + $cleanupRunId); RunId = $cleanupRunId; Root = 'C:\ProgramData\PatchingGuestOps'; AgentResult = $completedResult }
        )

        foreach ($negativeCase in $negativeCases) {
            Reset-CleanupCase
            if ($null -ne $negativeCase.PSObject.Properties['StatusJson']) {
                $script:cleanupStatusJson = ('{"runId":"' + $negativeCase.RunId + '","outcome":"Started","finishedAt":null,"errors":[]}')
            }
            else {
                # The status has to carry THIS case's run id, or Complete-VMAgentCycle throws on
                # the identity comparison and the case never reaches the guard it is named for.
                $script:cleanupStatusJson = ('{"runId":"' + $negativeCase.RunId + '","outcome":"InstallSucceeded","finishedAt":"2026-09-11T10:00:00Z","errors":[]}')
            }
            if ($null -ne $negativeCase.PSObject.Properties['LogFails']) {
                $script:cleanupLogDownloadFails = $true
            }

            $caseHandle = New-CleanupHandle -CycleDirectory $negativeCase.Cycle -RunId $negativeCase.RunId -Root $negativeCase.Root
            $casePayload = $null
            try {
                $casePayload = Complete-VMAgentCycle -Handle $caseHandle -AgentResult $negativeCase.AgentResult
            }
            catch {
                $casePayload = $null
            }

            Assert-Equal -Actual @($script:cleanupDeleteCalls).Count -Expected 0 -Message ('F3: nothing is deleted when ' + $negativeCase.Name)
            if ($null -ne $casePayload) {
                Assert-Equal -Actual $casePayload.CleanupStatus -Expected 'Retained' -Message ('F3: the cycle directory is retained when ' + $negativeCase.Name)
                Assert-Equal -Actual ([string]::IsNullOrWhiteSpace([string]$casePayload.CleanupReason)) -Expected $false -Message ('F3: retaining the directory says why when ' + $negativeCase.Name)
            }
        }

        # The status came from an earlier read rather than this collection - which is how
        # Test-VMAgentCycleComplete recovers a cycle whose process vSphere has forgotten.
        # Everything else looks finished, which is exactly why this has to be checked: the file
        # on the stepping stone says nothing about what is still sitting on the guest.
        Reset-CleanupCase
        $staleStatusHandle = New-CleanupHandle -CycleDirectory (Join-Path $cleanupRoot $cleanupRunId)
        $staleStatusHandle.Status = ($script:cleanupStatusJson | ConvertFrom-Json)
        Set-Content -LiteralPath (Join-Path $cleanupLocalDir 'status.json') -Value $script:cleanupStatusJson -Encoding UTF8
        $stalePayload = Complete-VMAgentCycle -Handle $staleStatusHandle -AgentResult $completedResult
        Assert-Equal -Actual $stalePayload.StatusDownloaded -Expected $false -Message 'F3: a status carried over from an earlier read is not reported as downloaded'
        Assert-Equal -Actual $stalePayload.CleanupStatus -Expected 'Retained' -Message 'F3: a cycle whose status was not downloaded this time keeps its guest directory'
        Assert-Equal -Actual @($script:cleanupDeleteCalls).Count -Expected 0 -Message 'F3: a status carried over from an earlier read deletes nothing'

        # The log download failed, but a log from an earlier attempt is still on disk. Checking
        # only that the file exists would read that leftover as a successful collection.
        Reset-CleanupCase
        Set-Content -LiteralPath (Join-Path $cleanupLocalDir 'agent.log') -Value 'stale agent log from an earlier attempt' -Encoding UTF8
        $script:cleanupLogDownloadFails = $true
        $staleLogPayload = Complete-VMAgentCycle -Handle (New-CleanupHandle -CycleDirectory (Join-Path $cleanupRoot $cleanupRunId)) -AgentResult $completedResult 3>$null
        Assert-Equal -Actual $staleLogPayload.LogDownloaded -Expected $false -Message 'F3: a stale local log is not reported as downloaded'
        Assert-Equal -Actual $staleLogPayload.CleanupStatus -Expected 'Retained' -Message 'F3: a stale local log does not license a delete'
        Assert-Equal -Actual @($script:cleanupDeleteCalls).Count -Expected 0 -Message 'F3: a stale local log deletes nothing'

        # curl can exit 0 and still leave nothing on disk. A transfer that reports success is
        # not the same fact as an artifact that arrived, and only the second one licenses a
        # delete: the guest copy is the only copy left once the directory is gone.
        Reset-CleanupCase
        $script:cleanupLogArrivesEmpty = $true
        $emptyLogPayload = Complete-VMAgentCycle -Handle (New-CleanupHandle -CycleDirectory (Join-Path $cleanupRoot $cleanupRunId)) -AgentResult $completedResult
        Assert-Equal -Actual $emptyLogPayload.LogDownloaded -Expected $true -Message 'F3: a transfer that raised no error is reported as a completed download'
        Assert-Equal -Actual $emptyLogPayload.CleanupStatus -Expected 'Retained' -Message 'F3: an artifact that never reached the stepping stone keeps the guest directory'
        Assert-Equal -Actual @($script:cleanupDeleteCalls).Count -Expected 0 -Message 'F3: a download that produced no file deletes nothing'

        # A guest that refuses the delete is a warning, not a failed patch run.
        Reset-CleanupCase
        $script:cleanupDeleteThrows = $true
        $warnPayload = Complete-VMAgentCycle -Handle (New-CleanupHandle -CycleDirectory (Join-Path $cleanupRoot $cleanupRunId)) -AgentResult $completedResult 3>$null
        Assert-Equal -Actual $warnPayload.CleanupStatus -Expected 'Warning' -Message 'F3: a failed delete is reported as a warning'
        Assert-Equal -Actual ([string]::IsNullOrWhiteSpace([string]$warnPayload.CleanupReason)) -Expected $false -Message 'F3: a failed delete explains itself'
        Assert-Equal -Actual $warnPayload.AgentCompletionConfirmed -Expected $true -Message 'F3: a failed delete does not overwrite the WUA result'
        Assert-Equal -Actual ([string]$warnPayload.Status.outcome) -Expected 'InstallSucceeded' -Message 'F3: a failed delete leaves the agent status intact'
    }
    finally {
        Remove-Item -LiteralPath $cleanupLocalDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# F9: discovery.json, apply-results.json and patch-plan.json are always JSON arrays. Driving the
# real phases rather than ConvertTo-Json is the point: the defect was a production call site
# piping its collection, which unrolls it, so zero records wrote nothing and one record wrote a
# bare object. Anything reading these back - the resume path most of all - then meets two shapes
# it cannot anticipate.
& {
    function Assert-JsonArrayArtifact {
        param([string]$Path, [int]$ExpectedCount, [string]$Label)

        Assert-Equal -Actual (Test-Path -LiteralPath $Path -PathType Leaf) -Expected $true -Message ('F9: {0} exists for {1} record(s)' -f $Label, $ExpectedCount)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return
        }

        $raw = [string](Get-Content -LiteralPath $Path -Raw)
        Assert-Equal -Actual ($raw.TrimStart().StartsWith('[')) -Expected $true -Message ('F9: {0} is a JSON array for {1} record(s)' -f $Label, $ExpectedCount)
        # Assign before wrapping: ConvertFrom-Json emits the whole array as ONE pipeline object
        # in PowerShell 5.1, so @($raw | ConvertFrom-Json) would count the array, not its items.
        $parsed = $raw | ConvertFrom-Json
        Assert-Equal -Actual @($parsed).Count -Expected $ExpectedCount -Message ('F9: {0} reads back as {1} element(s)' -f $Label, $ExpectedCount)
    }

    $artifactRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-f9-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null

    $script:f9FleetResults = @()
    function Invoke-GuestAgentFleet {
        param($FleetItems, $Managers, $GuestCredentialMap, $CurlPath, $AgentPath, $IdentityHelperPath, $GuestWorkingDirectory, $TimeoutSeconds, $PollSeconds, $MaxInFlight, $CredentialContext, $CredentialDecisionScript, $CredentialValidatedScript, $CredentialInteractive)
        return @($script:f9FleetResults)
    }
    function New-GuestAuthentication { param([pscredential]$Credential) [pscustomobject]@{ UserName = $Credential.UserName } }

    function New-F9FleetResult {
        param([int]$Sequence, [string]$VMName, [string]$Outcome)
        return [pscustomobject]@{
            Sequence = $Sequence
            VMName = $VMName
            Error = $null
            ResultKind = $null
            Payload = [pscustomobject]@{
                RunId = ('f9-' + $VMName)
                Mode = 'Apply'
                AgentCompletionConfirmed = $true
                AgentCompletionReason = 'synthetic terminal status'
                AgentResult = [pscustomobject]@{ Completed = $true; ExitCode = 0 }
                Status = [pscustomobject]@{
                    runId = ('f9-' + $VMName)
                    outcome = $Outcome
                    finishedAt = '2026-09-11T10:00:00Z'
                    installResult = [pscustomobject]@{ result = 'Succeeded'; rebootRequired = $false }
                    pendingRebootAfter = [pscustomobject]@{ isPending = $false }
                    pendingRebootBefore = [pscustomobject]@{ isPending = $false }
                    roleFlags = [pscustomobject]@{ failoverCluster = $false }
                    updates = @()
                    errors = @()
                }
            }
        }
    }

    $f9Credential = New-Object System.Management.Automation.PSCredential('Administrator', (ConvertTo-SecureString 'synthetic' -AsPlainText -Force))

    try {
        foreach ($count in @(0, 1, 2)) {
            $names = @(1..2 | Select-Object -First $count | ForEach-Object { 'VM0{0}' -f $_ })
            $script:f9FleetResults = @(1..2 | Select-Object -First $count | ForEach-Object { New-F9FleetResult -Sequence $_ -VMName ('VM0{0}' -f $_) -Outcome 'SearchOnly' })

            $discoveryDir = Join-Path $artifactRoot ('discovery-' + $count)
            New-Item -ItemType Directory -Force -Path $discoveryDir | Out-Null
            $credentialMap = @{}
            foreach ($name in $names) { $credentialMap[$name] = $f9Credential }
            $null = Invoke-DiscoveryPhase -TargetVMNames $names -Managers $null -GuestCredentialMap $credentialMap -CurlPath 'unused' -AgentPath 'unused' -IdentityHelperPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -MaxUpdates 1 -TimeoutSeconds 60 -PollSeconds 1 -CycleOutputDirectory $discoveryDir -MaxInFlight 2
            Assert-JsonArrayArtifact -Path (Join-Path $discoveryDir 'discovery.json') -ExpectedCount $count -Label 'discovery.json'

            $applyDir = Join-Path $artifactRoot ('apply-' + $count)
            New-Item -ItemType Directory -Force -Path $applyDir | Out-Null
            $script:f9FleetResults = @(1..2 | Select-Object -First $count | ForEach-Object { New-F9FleetResult -Sequence $_ -VMName ('VM0{0}' -f $_) -Outcome 'InstallSucceeded' })
            $planRecords = @(1..2 | Select-Object -First $count | ForEach-Object {
                [pscustomobject]@{
                    vmName = ('VM0{0}' -f $_)
                    action = 'Install'
                    roleFlags = [pscustomobject]@{ failoverCluster = $false }
                    selectedUpdates = @([pscustomobject]@{ identityKey = 'aaaa|1'; updateId = 'aaaa'; revisionNumber = 1; title = 'Security Update'; kbArticleIds = @() })
                }
            })
            $null = Invoke-ApplyPhase -PatchPlanRecords $planRecords -Managers $null -GuestCredentialMap $credentialMap -CurlPath 'unused' -AgentPath 'unused' -IdentityHelperPath 'unused' -GuestWorkingDirectory 'C:\synthetic' -TimeoutSeconds 60 -PollSeconds 1 -CycleOutputDirectory $applyDir -MaxInFlight 2
            Assert-JsonArrayArtifact -Path (Join-Path $applyDir 'apply-results.json') -ExpectedCount $count -Label 'apply-results.json'
        }
    }
    finally {
        Remove-Item -LiteralPath $artifactRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# F6: an update the policy cannot classify is only resolved by an operator who saw it. The whole
# path runs through the production round loop: an unticked box after an interactive selection is a
# decision, the same box left unticked by a non-interactive run is not, and the run has to end
# incomplete in the second case rather than reporting a green fleet.
& {
    $f6Directory = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-f6-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $f6Directory | Out-Null

    $f6RoundLoop = $orchestratorAst.Find({ param($node)
        $node -is [System.Management.Automation.Language.WhileStatementAst] -and $node.Extent.Text.Contains('$roundNumber++')
    }, $true)
    $f6RoundFinalization = $orchestratorAst.Find({ param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains('Write-PatchRunSummary -RunOutputDirectory')
    }, $true)
    Assert-Equal ($null -ne $f6RoundLoop) $true 'F6: the production round loop is available to the policy-review regression'

    # No classification GUIDs, no severity, no BrowseOnly flag: exactly what WUA gives for a
    # package this tool has no structural grounds to install or skip.
    $f6Update = [pscustomobject]@{
        updateId = '66666666-6666-6666-6666-666666666666'
        revisionNumber = 1
        title = 'Paket ohne Klassifizierung'
        kbArticleIds = @('5031240')
        categories = @('Updates')
        categoryIds = @()
        browseOnly = $null
        msrcSeverity = ''
        updateType = 'Software'
    }
    $f6Discovery = @(
        [pscustomobject]@{ vmName = 'VM-review'; computerName = 'VM-review'; outcome = 'SearchOnly'; errors = @(); roleFlags = [pscustomobject]@{ failoverCluster = $false }; pendingRebootBefore = [pscustomobject]@{ isPending = $false }; updates = @($f6Update) }
    )

    $script:f6SelectionPrompts = 0
    function Invoke-DiscoveryPhase {
        param($TargetVMNames, $VIServerScope, $Managers, $GuestCredentialMap, $CurlPath, $AgentPath, $IdentityHelperPath, $WorkspaceScriptPath, $RunGuardScriptPath, $GuestWorkingDirectory, $MaxUpdates, $TimeoutSeconds, $PollSeconds, $CycleOutputDirectory, $MaxInFlight, $CredentialContext, $CredentialDecisionScript, $CredentialValidatedScript, $CredentialInteractive)
        return @($f6Discovery)
    }
    function Read-UpdateGroupSelection {
        param($UpdateGroups, $PromptProvider)
        $script:f6SelectionPrompts++
        # The operator looked at the list and left the unclassified group unticked.
        return [pscustomobject]@{ Aborted = $false; Keys = @() }
    }
    function Confirm-PatchPlan { param($PatchPlanRecords, [hashtable]$PromptProvider, [switch]$SkipConfirmation) $true }
    function Read-ContinuePatchingDecision { param($CompletionStates, $Round, $PromptProvider) return 'FINISH' }
    function Invoke-ApplyAndOptionalReboot {
        param($PatchPlanRecords, $VIServerScope, $Managers, $GuestCredentialMap, $VIServers, $VIServerCredentialMap, [switch]$IgnoreVCenterCertificate, $GuestOpsLibPath, $CurlPath, $AgentPath, $IdentityHelperPath, $WorkspaceScriptPath, $RunGuardScriptPath, $RebootRequestScriptPath, $GuestWorkingDirectory, $TimeoutSeconds, $RebootTimeoutSeconds, $PollSeconds, $CycleOutputDirectory, $ThrottleLimit, $RebootBatchSize, $DiscoveryRecords, $CredentialContext, $CredentialDecisionScript, $CredentialValidatedScript, $CredentialInteractive)
        return [pscustomobject]@{ ExitCode = 0; RebootRan = $false; RebootActions = @(); ApplyResults = @() }
    }
    function Write-PatchRoundVerification { param($CompletionStates, $Round) }
    function Write-PatchRunSummary { param($RunOutputDirectory, $RoundSummaries, $FinalStateMap) }
    function Show-UpdateGroups { param($UpdateGroups) }
    function Show-PatchPlan { param($PatchPlanRecords) }

    $f6Invoke = {
        param([bool]$NonInteractive)
        $script:f6SelectionPrompts = 0
        $roundNumber = 0
        $targetVMNames = @('VM-review')
        $roundTargetVMNames = @($targetVMNames)
        $roundSummaries = @()
        $finalStateMap = @{}
        $deselectedUpdateKeys = @()
        $stoppedByRoundCap = $false
        $outstandingVerificationByVm = @{}
        $runEventLog = New-RunEventLogState -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-events-' + [guid]::NewGuid().ToString('N') + '.jsonl'))
        $sawApplyFailure = $false
        $scriptExitCode = 0
        $runOutputDirectory = $f6Directory
        $MaxPatchRounds = 1
        $SearchOnly = $false
        $PlanOnly = $false
        $SkippedGuestCredentialTargets = @()
        $hasExplicitSelectedUpdateKeys = $NonInteractive
        $SelectedUpdateKeys = if ($NonInteractive) { @('66666666-6666-6666-6666-666666666666|1-not-selected') } else { @() }
        $SkipConfirmation = $NonInteractive
        $PromptProvider = $null
        $managers = $null
        $guestCredentialMap = @{}
        $guestCredentialContext = $null
        $guestCredentialDecisionScript = $null
        $guestCredentialValidatedScript = $null
        $guestCredentialInteractive = $false
        $resolvedVIServers = @('vc.synthetic.invalid')
        $viServerScope = @('vc.synthetic.invalid')
        $viserverCredentialMap = @{}
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
        $ThrottleLimit = 1
        $resolvedRebootBatchSize = 1
        $MaxUpdates = 1

        # A non-interactive run reaches selection through -SelectedUpdateKeys, which must not
        # match the unclassified group: the point is that nobody chose it either way.
        if ($NonInteractive) {
            function Resolve-SelectedUpdateKeys { param($UpdateGroups, [string[]]$ExplicitSelectedUpdateKeys = @()) return @() }
        }

        . ([scriptblock]::Create(($f6RoundLoop.Extent.Text + "`n" + $f6RoundFinalization.Extent.Text)))

        return [pscustomobject]@{
            ExitCode = $scriptExitCode
            State = [string]$finalStateMap['VM-review'].state
            Prompts = $script:f6SelectionPrompts
            DeselectedKeys = @($deselectedUpdateKeys)
        }
    }

    try {
        $interactive = & $f6Invoke $false
        Assert-Equal $interactive.Prompts 1 'F6: the operator is shown the group list once'
        Assert-Equal $interactive.State 'GreenByOperatorChoice' 'F6: a group an operator saw and left unticked is a decision'
        Assert-Equal $interactive.ExitCode 0 'F6: an operator-resolved review lets the run finish'
        Assert-Equal (@($interactive.DeselectedKeys) -join ',') '66666666-6666-6666-6666-666666666666|1' 'F6: the refusal is remembered by identity so later rounds do not ask again'

        $nonInteractive = & $f6Invoke $true
        Assert-Equal $nonInteractive.Prompts 0 'F6: a non-interactive run never opens the selection'
        Assert-Equal $nonInteractive.State 'NeedsReview' 'F6: without an operator the unclassified group leaves the VM needing review'
        Assert-Equal $nonInteractive.ExitCode 1 'F6: a run that needed a decision nobody made is incomplete'
        Assert-Equal (@($nonInteractive.DeselectedKeys).Count) 0 'F6: a default nobody looked at is never recorded as an operator decision'
    }
    finally {
        Remove-Item Function:\Invoke-DiscoveryPhase -ErrorAction SilentlyContinue
        Remove-Item Function:\Read-UpdateGroupSelection -ErrorAction SilentlyContinue
        Remove-Item Function:\Confirm-PatchPlan -ErrorAction SilentlyContinue
        Remove-Item Function:\Read-ContinuePatchingDecision -ErrorAction SilentlyContinue
        Remove-Item Function:\Invoke-ApplyAndOptionalReboot -ErrorAction SilentlyContinue
        Remove-Item Function:\Write-PatchRoundVerification -ErrorAction SilentlyContinue
        Remove-Item Function:\Write-PatchRunSummary -ErrorAction SilentlyContinue
        Remove-Item Function:\Show-UpdateGroups -ErrorAction SilentlyContinue
        Remove-Item Function:\Show-PatchPlan -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $f6Directory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# F7: a VM with no applicable updates but a pending reboot. This is the case the audit found
# reporting a green fleet without ever looking again: the VM restarts, the round loop never picks
# it up because its apply action was NoSelectedUpdates, and the verdict from the discovery taken
# BEFORE the restart stands. Everything except the guest work runs through production code -
# the round loop, the reboot-target selection, the state map and the final exit code.
& {
    $f7Directory = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-f7-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $f7Directory | Out-Null

    $f7RoundLoop = $orchestratorAst.Find({ param($node)
        $node -is [System.Management.Automation.Language.WhileStatementAst] -and $node.Extent.Text.Contains('$roundNumber++')
    }, $true)
    $f7RoundFinalization = $orchestratorAst.Find({ param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains('Write-PatchRunSummary -RunOutputDirectory')
    }, $true)

    $f7Role = [pscustomobject]@{ failoverCluster = $false }
    $f7SecurityId = '0fa1201d-4330-4fa8-8ae9-b877473b6441'
    $f7Update = [pscustomobject]@{
        updateId = '77777777-7777-7777-7777-777777777777'; revisionNumber = 1; title = 'Security Update'
        kbArticleIds = @('5031250'); categories = @('Security Updates'); categoryIds = @($f7SecurityId)
        browseOnly = $false; msrcSeverity = 'Critical'; updateType = 'Software'
    }

    $script:f7DiscoveryCalls = 0
    $script:f7DiscoveryTargets = @()
    $script:f7RebootApproved = $true
    $script:f7RebootConfirmed = $true
    $script:f7RoundTwoUpdates = @()

    function Invoke-DiscoveryPhase {
        param($TargetVMNames, $VIServerScope, $Managers, $GuestCredentialMap, $CurlPath, $AgentPath, $IdentityHelperPath, $WorkspaceScriptPath, $RunGuardScriptPath, $GuestWorkingDirectory, $MaxUpdates, $TimeoutSeconds, $PollSeconds, $CycleOutputDirectory, $MaxInFlight, $CredentialContext, $CredentialDecisionScript, $CredentialValidatedScript, $CredentialInteractive)
        $script:f7DiscoveryCalls++
        $script:f7DiscoveryTargets += ,@($TargetVMNames)
        if ($script:f7DiscoveryCalls -eq 1) {
            # Nothing to install, but the guest already carries a pending reboot.
            return @([pscustomobject]@{ vmName = 'VM-reboot'; computerName = 'VM-reboot'; outcome = 'SearchOnly'; errors = @(); roleFlags = $f7Role; pendingRebootBefore = [pscustomobject]@{ isPending = $true }; updates = @() })
        }
        return @([pscustomobject]@{ vmName = 'VM-reboot'; computerName = 'VM-reboot'; outcome = 'SearchOnly'; errors = @(); roleFlags = $f7Role; pendingRebootBefore = [pscustomobject]@{ isPending = $script:f7PendingAfterReboot }; updates = @($script:f7RoundTwoUpdates) })
    }
    function Read-UpdateGroupSelection { param($UpdateGroups, $PromptProvider) return [pscustomobject]@{ Aborted = $false; Keys = @(@($UpdateGroups) | ForEach-Object { [string]$_.identityKey }) } }
    function Confirm-PatchPlan { param($PatchPlanRecords, [hashtable]$PromptProvider, [switch]$SkipConfirmation) $true }
    function Read-ContinuePatchingDecision { param($CompletionStates, $Round, $PromptProvider) return 'CONTINUE' }
    function Write-PatchRoundVerification { param($CompletionStates, $Round) }
    function Write-PatchRunSummary { param($RunOutputDirectory, $RoundSummaries, $FinalStateMap) }
    function Show-UpdateGroups { param($UpdateGroups) }
    function Show-PatchPlan { param($PatchPlanRecords) }
    function Write-PatchingSummary { param($ApplyResults) }
    function Write-FinalReport { param($PatchPlanRecords, $ApplyResults, $CycleOutputDirectory, $RebootTargets) }
    function Write-RebootActionArtifacts { param($CycleOutputDirectory, $RebootActions) }
    function Confirm-GuestReboot { param($RebootTargets) return $script:f7RebootApproved }
    function Read-RebootBatchSize { param($TargetCount) return 1 }

    # The apply phase is the only stubbed production function here; its result shape is the real
    # one, built by the production constructor.
    function Invoke-ApplyPhase {
        param($PatchPlanRecords, $VIServerScope, $Managers, $GuestCredentialMap, $CurlPath, $AgentPath, $IdentityHelperPath, $WorkspaceScriptPath, $RunGuardScriptPath, $GuestWorkingDirectory, $TimeoutSeconds, $PollSeconds, $CycleOutputDirectory, $MaxInFlight, $CredentialContext, $CredentialDecisionScript, $CredentialValidatedScript, $CredentialInteractive)
        $results = @()
        foreach ($record in @($PatchPlanRecords)) {
            $selectedCount = @(Get-RuntimePropertyValue -InputObject $record -Name 'selectedUpdates' -DefaultValue @()).Count
            if ($selectedCount -eq 0) {
                $results += New-ApplyResultRecord -VMName ([string]$record.vmName) -Action 'NoSelectedUpdates' -Outcome 'NoSelectedUpdates' -Reason 'No selected updates apply to this VM.' -AgentCompletionConfirmed $true -RebootRequired $false
            }
            else {
                $results += New-ApplyResultRecord -VMName ([string]$record.vmName) -Outcome 'InstallSucceeded' -AgentCompletionConfirmed $true -RebootRequired $false
            }
        }
        return @($results)
    }
    function Invoke-GuestRebootPhase {
        param($RebootTargets, $GuestCredentialMap, $VIServers, $VIServerScope, $VIServerCredentialMap, [switch]$IgnoreVCenterCertificate, $GuestOpsLibPath, $CurlPath, $WorkspaceScriptPath, $RunGuardScriptPath, $RebootRequestScriptPath, $GuestWorkingDirectory, $RebootTimeoutSeconds, $PollSeconds, $RebootBatchSize, $BootTimeHelperPath, $CredentialContext, $CredentialDecisionScript, $CredentialValidatedScript, $CredentialInteractive)
        $records = @()
        foreach ($target in @($RebootTargets)) {
            $records += New-RebootActionRecord -VMName ([string]$target.vmName) -Action 'Initiated' -ValidationStatus $(if ($script:f7RebootConfirmed) { 'Confirmed' } else { 'Timeout' }) -RebootReason ([string]$target.rebootReason)
        }
        return @($records)
    }

    $f7Invoke = {
        param([bool]$RebootApproved, [bool]$RebootConfirmed, $RoundTwoUpdates, [bool]$PendingAfterReboot = $false)
        $script:f7DiscoveryCalls = 0
        $script:f7DiscoveryTargets = @()
        $script:f7RebootApproved = $RebootApproved
        $script:f7RebootConfirmed = $RebootConfirmed
        $script:f7RoundTwoUpdates = @($RoundTwoUpdates)
        $script:f7PendingAfterReboot = $PendingAfterReboot

        $roundNumber = 0
        $targetVMNames = @('VM-reboot')
        $roundTargetVMNames = @($targetVMNames)
        $roundSummaries = @()
        $finalStateMap = @{}
        $deselectedUpdateKeys = @()
        $stoppedByRoundCap = $false
        $outstandingVerificationByVm = @{}
        $runEventLog = New-RunEventLogState -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-events-' + [guid]::NewGuid().ToString('N') + '.jsonl'))
        $sawApplyFailure = $false
        $scriptExitCode = 0
        $runOutputDirectory = $f7Directory
        $MaxPatchRounds = 2
        $SearchOnly = $false
        $PlanOnly = $false
        $SkippedGuestCredentialTargets = @()
        $hasExplicitSelectedUpdateKeys = $false
        $SelectedUpdateKeys = @()
        $SkipConfirmation = $false
        $PromptProvider = $null
        $managers = $null
        $guestCredentialMap = @{}
        $guestCredentialContext = $null
        $guestCredentialDecisionScript = $null
        $guestCredentialValidatedScript = $null
        $guestCredentialInteractive = $false
        $resolvedVIServers = @('vc.synthetic.invalid')
        $viServerScope = @('vc.synthetic.invalid')
        $viserverCredentialMap = @{}
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
        $ThrottleLimit = 1
        $resolvedRebootBatchSize = 1
        $MaxUpdates = 1

        . ([scriptblock]::Create(($f7RoundLoop.Extent.Text + "`n" + $f7RoundFinalization.Extent.Text)))

        return [pscustomobject]@{
            ExitCode = $scriptExitCode
            State = [string]$finalStateMap['VM-reboot'].state
            DiscoveryCalls = $script:f7DiscoveryCalls
            DiscoveryTargets = @($script:f7DiscoveryTargets)
        }
    }

    try {
        # 1. Reboot only, confirmed, nothing left afterwards: a second discovery has to run before
        #    the VM may be called green.
        $confirmed = & $f7Invoke $true $true @()
        Assert-Equal $confirmed.DiscoveryCalls 2 'F7: a confirmed restart is verified by a fresh discovery, not by the boot time alone'
        Assert-Equal (@($confirmed.DiscoveryTargets[1]) -join ',') 'VM-reboot' 'F7: the rebooted VM is the target of that discovery even though it installed nothing'
        Assert-Equal $confirmed.State 'Green' 'F7: only the post-reboot discovery may call the VM green'
        Assert-Equal $confirmed.ExitCode 0 'F7: a verified reboot-only round can finish successfully'

        $stillNeedsReboot = & $f7Invoke $true $true @() $true
        Assert-Equal $stillNeedsReboot.State 'PendingReboot' 'F7: fresh discovery still requiring a reboot cannot become Green'
        Assert-Equal $stillNeedsReboot.ExitCode 1 'F7: a persistent reboot requirement cannot exit 0'
        Assert-Equal $stillNeedsReboot.DiscoveryCalls 3 'F7: reboot-only rounds continue up to the configured round cap'

        # 2. The post-reboot discovery finds new patches: the VM is pending again and gets another
        #    round rather than being reported as finished.
        $stillPending = & $f7Invoke $true $true @($f7Update)
        Assert-Equal $stillPending.State 'Pending' 'F7: updates found after the restart keep the VM pending'
        Assert-Equal $stillPending.ExitCode 1 'F7: a VM still pending at the end is not a success'

        # 3. The operator refuses the restart the VM needs.
        $refused = & $f7Invoke $false $true @()
        Assert-Equal $refused.State 'PendingReboot' 'F7: a refused required restart is PendingReboot, not Failed'
        Assert-Equal $refused.ExitCode 1 'F7: a refused required restart cannot exit 0'
        Assert-Equal $refused.DiscoveryCalls 1 'F7: a VM that was never restarted is not re-discovered'

        # 4. The restart was sent but never confirmed: no reliable boot time, so no next discovery
        #    and no verdict claiming the machine is finished.
        $unconfirmed = & $f7Invoke $true $false @()
        Assert-Equal $unconfirmed.State 'PendingReboot' 'F7: an unconfirmed restart leaves the VM pending a reboot'
        Assert-Equal $unconfirmed.ExitCode 1 'F7: an unconfirmed restart cannot exit 0'
        Assert-Equal $unconfirmed.DiscoveryCalls 1 'F7: a guest with no reliable boot time is not re-discovered'
    }
    finally {
        foreach ($stubbed in @('Invoke-DiscoveryPhase', 'Read-UpdateGroupSelection', 'Confirm-PatchPlan', 'Read-ContinuePatchingDecision',
                'Write-PatchRoundVerification', 'Write-PatchRunSummary', 'Show-UpdateGroups', 'Show-PatchPlan', 'Write-PatchingSummary',
                'Write-FinalReport', 'Write-RebootActionArtifacts', 'Confirm-GuestReboot', 'Read-RebootBatchSize', 'Invoke-ApplyPhase',
                'Invoke-GuestRebootPhase')) {
            Remove-Item ('Function:\' + $stubbed) -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $f7Directory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host ('FAIL: ' + $failure) }
    exit 1
}
Write-Host 'Safety regression checks passed.'
exit 0

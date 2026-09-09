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
    $cycle = [pscustomobject]@{ Status = $clusterApply.Status; AgentResult = $processResult }
    $applyResult = New-ApplyResultFromCycle -VMName 'fixture' -Cycle $cycle
    Assert-Equal (@(Select-RebootRequiredApplyResults -ApplyResults @($applyResult)).Count) 0 'cluster detected by apply is excluded from reboot without discovery records'
    Assert-Equal (Test-ApplyResultsSuccessful -ApplyResults @($applyResult)) $false 'cluster installation rejection cannot be reported as success'
}
$clusterScan = Invoke-AgentFixture -Cluster $true -SearchOnly
Assert-Equal $clusterScan.ExitCode 0 'cluster search-only remains available for discovery'
Assert-Equal $clusterScan.State 'Excluded' 'cluster discovery still drives the planning exclusion'
Assert-Equal $clusterScan.InstallCalled $false 'cluster discovery never installs'

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host ('FAIL: ' + $failure) }
    exit 1
}
Write-Host 'Safety regression checks passed.'
exit 0

[CmdletBinding()]
param(
    [string]$WorkingDirectory = 'C:\ProgramData\PatchingGuestOps',
    [int]$MaxUpdates = 1,
    [string[]]$SelectedUpdateKeys = @(),
    [string]$SelectionPath,
    [string]$RunId,
    # The seal the workspace bootstrap wrote into $WorkingDirectory. Verified before the WUA
    # session is created: the upload and the start are two separate GuestOps calls, and the
    # directory passing its checks when the bootstrap ran is not the same fact as this being
    # still the directory that was secured.
    [string]$WorkspaceSealToken = '',
    [switch]$SearchOnly,
    [string]$SearchCriteria = "IsInstalled=0 and IsHidden=0 and Type='Software'"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'UpdateIdentity.ps1')
# The workspace guard supplies the protected-directory primitives the run guard needs for the
# fixed coordination directory; the run guard is what stops two runs meeting on this guest.
. (Join-Path $PSScriptRoot 'GuestWorkspace.ps1')
. (Join-Path $PSScriptRoot 'GuestRunGuard.ps1')

if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $WorkingDirectory | Out-Null
}

$StatusPath = Join-Path $WorkingDirectory 'status.json'
$LogPath = Join-Path $WorkingDirectory 'agent.log'

function Write-AgentLog {
    param([string]$Message)

    $line = '{0} {1}' -f (Get-Date).ToString('o'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Convert-ResultCode {
    param($ResultCode)

    if ($null -eq $ResultCode) {
        return $null
    }

    switch ([int]$ResultCode) {
        0 { return 'NotStarted' }
        1 { return 'InProgress' }
        2 { return 'Succeeded' }
        3 { return 'SucceededWithErrors' }
        4 { return 'Failed' }
        5 { return 'Aborted' }
        default { return ('Unknown:{0}' -f [int]$ResultCode) }
    }
}

function Format-HResult {
    param($HResult)

    if ($null -eq $HResult) {
        return $null
    }

    $value = [int64]$HResult
    if ($value -lt 0) {
        $value = $value + 0x100000000
    }

    return ('0x{0:X8}' -f ([uint32]$value))
}

function Get-OptionalPropertyValue {
    param(
        $InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    try {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -eq $property) {
            return $null
        }

        return $property.Value
    }
    catch {
        return $null
    }
}

function Get-OptionalStringPropertyValue {
    param(
        $InputObject,
        [string]$Name
    )

    $value = Get-OptionalPropertyValue -InputObject $InputObject -Name $Name
    if ($null -eq $value) {
        return $null
    }

    $text = ([string]$value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text
}

function ConvertTo-UpdateTypeName {
    param($TypeValue)

    if ($null -eq $TypeValue) {
        return $null
    }

    $text = ([string]$TypeValue).Trim()
    switch ($text) {
        '1' { return 'Software' }
        '2' { return 'Driver' }
        '' { return $null }
        default { return $text }
    }
}

function Get-ComStringCollection {
    param($Collection)

    $values = @()
    if ($null -eq $Collection) {
        return $values
    }

    for ($i = 0; $i -lt $Collection.Count; $i++) {
        $values += [string]$Collection.Item($i)
    }

    return $values
}

function Read-SelectionDocumentKeys {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @()
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ('Selection document was not found: {0}' -f $Path)
    }

    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $schemaVersion = [string]$document.schemaVersion
    if ($schemaVersion -ne 'selection-v1') {
        throw ('Unsupported selection document schemaVersion: {0}' -f $schemaVersion)
    }

    $keys = @()
    foreach ($selectedUpdateKey in @($document.selectedUpdateKeys)) {
        $key = ([string]$selectedUpdateKey).Trim()
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $keys += $key
        }
    }

    return @($keys)
}

function Get-ComCategoryCollection {
    param($Collection)

    $values = @()
    if ($null -eq $Collection) {
        return $values
    }

    for ($i = 0; $i -lt $Collection.Count; $i++) {
        try {
            $category = $Collection.Item($i)
            if ($null -ne $category -and -not [string]::IsNullOrWhiteSpace([string]$category.Name)) {
                $values += [string]$category.Name
            }
        }
        catch {
            Write-AgentLog -Message ('Unable to read update category at index {0}: {1}' -f $i, $_.Exception.Message)
        }
    }

    return $values
}

function Get-ComCategoryIdCollection {
    param($Collection)

    # Category NAMES are localised - a German guest reports "Sicherheitsupdates" - so they are
    # display text only. The CategoryID is the stable classification GUID, and it is what the
    # selection policy decides on.
    $values = @()
    if ($null -eq $Collection) {
        return $values
    }

    for ($i = 0; $i -lt $Collection.Count; $i++) {
        try {
            $category = $Collection.Item($i)
            $categoryId = [string](Get-OptionalStringPropertyValue -InputObject $category -Name 'CategoryID')
            if (-not [string]::IsNullOrWhiteSpace($categoryId)) {
                $values += $categoryId
            }
        }
        catch {
            Write-AgentLog -Message ('Unable to read update category id at index {0}: {1}' -f $i, $_.Exception.Message)
        }
    }

    return $values
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ServiceSnapshot {
    $serviceNames = @('wuauserv', 'bits')
    $services = @()

    foreach ($serviceName in $serviceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            $services += [ordered]@{
                name = $serviceName
                exists = $false
                status = $null
                startType = $null
            }
            continue
        }

        $services += [ordered]@{
            name = $service.Name
            exists = $true
            status = [string]$service.Status
            startType = [string]$service.StartType
        }
    }

    return $services
}

function Get-SystemDriveFreeGB {
    $systemDrive = $env:SystemDrive
    $disk = Get-WmiObject -Class Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $systemDrive)
    if ($null -eq $disk) {
        return $null
    }

    return [math]::Round(($disk.FreeSpace / 1GB), 2)
}

function Test-PendingReboot {
    $checks = [ordered]@{
        componentBasedServicing = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        windowsUpdate = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        pendingFileRename = $false
    }

    $sessionManagerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    try {
        $sessionManager = Get-ItemProperty -LiteralPath $sessionManagerPath -Name PendingFileRenameOperations -ErrorAction Stop
        $checks.pendingFileRename = ($null -ne $sessionManager.PendingFileRenameOperations)
    }
    catch {
        $checks.pendingFileRename = $false
    }

    return [ordered]@{
        isPending = ($checks.componentBasedServicing -or $checks.windowsUpdate -or $checks.pendingFileRename)
        checks = $checks
    }
}

function Get-LocalClusterMembership {
    # "ClusSvc exists" is not "this node is in a cluster". The service is present on every server
    # with the Failover Clustering feature installed, including one that was never joined to a
    # cluster and one that was evicted - and treating that as membership excluded healthy servers
    # from patching forever. GetNodeClusterState is the question that actually has an answer.
    #
    # Returns Member / NotMember / Unknown, and a reason. Unknown is never quietly read as
    # NotMember: this decides whether a machine may be patched and restarted at all.
    $service = $null
    $serviceLookupFailed = $false
    try {
        $service = Get-Service -Name 'ClusSvc' -ErrorAction SilentlyContinue
    }
    catch {
        $serviceLookupFailed = $true
    }

    if ($serviceLookupFailed) {
        return [ordered]@{ membership = 'Unknown'; reason = 'The ClusSvc service could not be queried.'; clusterState = $null }
    }

    if ($null -eq $service) {
        # No Failover Clustering feature at all. That is a fact, not a failure to read one.
        return [ordered]@{ membership = 'NotMember'; reason = 'The ClusSvc service is not installed.'; clusterState = $null }
    }

    # A stopped service says nothing either: a node can be a cluster member with ClusSvc stopped
    # for maintenance, which is exactly when someone might try to patch it.
    $clusterState = $null
    try {
        if (-not ('PatchingGuestOps.ClusApi' -as [type])) {
            Add-Type -Namespace 'PatchingGuestOps' -Name 'ClusApi' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("clusapi.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetNodeClusterState(string lpszNodeName, out uint pdwClusterState);
'@
        }

        $state = [uint32]0
        # The function's return code and the state value are separate pieces of information:
        # a non-zero return means the state was never written, so it must not be read.
        $returnCode = [PatchingGuestOps.ClusApi]::GetNodeClusterState($null, [ref]$state)
        if ($returnCode -ne 0) {
            return [ordered]@{ membership = 'Unknown'; reason = ('GetNodeClusterState failed with code {0}.' -f $returnCode); clusterState = $null }
        }
        $clusterState = [int]$state
    }
    catch {
        # clusapi.dll missing while the service exists, a bitness mismatch, or a blocked P/Invoke.
        return [ordered]@{ membership = 'Unknown'; reason = ('The cluster state could not be read: {0}' -f $_.Exception.Message); clusterState = $null }
    }

    $membership = switch ($clusterState) {
        0 { 'NotMember' }
        1 { 'NotMember' }
        3 { 'Member' }
        19 { 'Member' }
        default { 'Unknown' }
    }

    $reason = switch ($membership) {
        'NotMember' { 'The Failover Clustering feature is installed but this node is not in a cluster.' }
        'Member' { 'This node is a Failover Cluster member.' }
        default { ('GetNodeClusterState returned an unrecognised state {0}.' -f $clusterState) }
    }

    return [ordered]@{ membership = $membership; reason = $reason; clusterState = $clusterState }
}

function Get-RoleFlags {
    $clusterMembership = Get-LocalClusterMembership
    # failoverCluster keeps its meaning for everything downstream: "this VM must not be patched
    # automatically". Only a CONFIRMED member sets it; Unknown is refused separately, because
    # "we could not tell" and "it is a cluster" call for different messages to the operator.
    $failoverCluster = ([string]$clusterMembership.membership -eq 'Member')
    $domainController = ($null -ne (Get-Service -Name 'NTDS' -ErrorAction SilentlyContinue))
    $sql = (@(Get-Service -Name @('MSSQLSERVER', 'MSSQL$*', 'SQLSERVERAGENT', 'SQLAgent$*') -ErrorAction SilentlyContinue).Count -gt 0)
    $exchange = (@(Get-Service -Name 'MSExchange*' -ErrorAction SilentlyContinue).Count -gt 0)
    $iis = ($null -ne (Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue))

    $detected = @()
    if ($failoverCluster) {
        $detected += 'Failover Cluster'
    }
    if ([string]$clusterMembership.membership -eq 'Unknown') {
        $detected += 'Failover Cluster membership unknown'
    }
    if ($domainController) {
        $detected += 'Domain Controller'
    }
    if ($sql) {
        $detected += 'SQL'
    }
    if ($exchange) {
        $detected += 'Exchange'
    }
    if ($iis) {
        $detected += 'IIS'
    }

    return [ordered]@{
        failoverCluster = $failoverCluster
        clusterMembership = [string]$clusterMembership.membership
        clusterMembershipReason = [string]$clusterMembership.reason
        domainController = $domainController
        sql = $sql
        exchange = $exchange
        iis = $iis
        detected = $detected
    }
}

function New-UpdateRecord {
    param(
        $Update,
        [int]$Index
    )

    $kbArticleIds = @()
    try {
        $kbArticleIds = Get-ComStringCollection -Collection $Update.KBArticleIDs
    }
    catch {
        $kbArticleIds = @()
    }

    $updateId = $null
    $revisionNumber = $null
    try {
        $updateId = [string]$Update.Identity.UpdateID
        $revisionNumber = [int]$Update.Identity.RevisionNumber
    }
    catch {
        $updateId = $null
        $revisionNumber = $null
    }

    $identityKey = New-CanonicalUpdateIdentityKey -UpdateId $updateId -RevisionNumber $revisionNumber -AllowMissing

    $rebootBehavior = $null
    try {
        $rebootBehavior = [int]$Update.InstallationBehavior.RebootBehavior
    }
    catch {
        $rebootBehavior = $null
    }

    $categories = @()
    $categoryIds = @()
    try {
        $categories = @(Get-ComCategoryCollection -Collection $Update.Categories)
        $categoryIds = @(Get-ComCategoryIdCollection -Collection $Update.Categories)
    }
    catch {
        $categories = @()
        $categoryIds = @()
    }

    $msrcSeverity = Get-OptionalStringPropertyValue -InputObject $Update -Name 'MsrcSeverity'
    $updateType = ConvertTo-UpdateTypeName -TypeValue (Get-OptionalPropertyValue -InputObject $Update -Name 'Type')

    # IUpdate3.BrowseOnly. Three-valued on purpose: $null means WUA did not expose it (an older
    # IUpdate, or a COM read that failed), and an absent answer must never be read as $false.
    $browseOnly = $null
    $browseOnlyValue = Get-OptionalPropertyValue -InputObject $Update -Name 'BrowseOnly'
    if ($null -ne $browseOnlyValue) {
        try { $browseOnly = [bool]$browseOnlyValue } catch { $browseOnly = $null }
    }

    return [ordered]@{
        index = $Index
        title = [string]$Update.Title
        kbArticleIds = $kbArticleIds
        updateId = $updateId
        revisionNumber = $revisionNumber
        identityKey = $identityKey
        categories = $categories
        categoryIds = $categoryIds
        browseOnly = $browseOnly
        msrcSeverity = $msrcSeverity
        updateType = $updateType
        selected = $false
        eulaAccepted = [bool]$Update.EulaAccepted
        isDownloadedBeforeRun = [bool]$Update.IsDownloaded
        rebootBehavior = $rebootBehavior
        downloadResult = $null
        installResult = $null
        errors = @()
    }
}

function New-OperationResult {
    param($Result)

    if ($null -eq $Result) {
        return $null
    }

    $rebootRequired = Get-OptionalPropertyValue -InputObject $Result -Name 'RebootRequired'

    return [ordered]@{
        resultCode = [int]$Result.ResultCode
        result = Convert-ResultCode -ResultCode $Result.ResultCode
        hResult = Format-HResult -HResult (Get-OptionalPropertyValue -InputObject $Result -Name 'HResult')
        rebootRequired = if ($null -ne $rebootRequired) { [bool]$rebootRequired } else { $null }
    }
}

function Add-StatusError {
    param(
        $Status,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $Status.errors += [ordered]@{
        message = $ErrorRecord.Exception.Message
        type = $ErrorRecord.Exception.GetType().FullName
        line = $ErrorRecord.InvocationInfo.ScriptLineNumber
        command = $ErrorRecord.InvocationInfo.Line
    }
}

function Save-Status {
    param($Status)

    $json = $Status | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath $StatusPath -Value $json -Encoding UTF8
}

$status = [ordered]@{
    schemaVersion = 'phase0b-1'
    runId = $RunId
    computerName = $env:COMPUTERNAME
    startedAt = (Get-Date).ToString('o')
    finishedAt = $null
    outcome = 'Started'
    isElevated = $false
    powershellVersion = $PSVersionTable.PSVersion.ToString()
    runAs = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    workingDirectory = $WorkingDirectory
    searchCriteria = $SearchCriteria
    maxUpdates = $MaxUpdates
    selectedUpdateKeys = @($SelectedUpdateKeys)
    selectionPath = $SelectionPath
    searchOnly = [bool]$SearchOnly
    services = @()
    systemDriveFreeGB = $null
    availableUpdateCount = 0
    selectedUpdateCount = 0
    updates = @()
    searchResult = $null
    downloadResult = $null
    installResult = $null
    pendingReboot = $null
    pendingRebootBefore = $null
    pendingRebootAfter = $null
    roleFlags = $null
    # Null when no seal token was supplied (a legacy or manual invocation), true when the working
    # directory still carries the seal this run's bootstrap wrote, false when it does not. False
    # stops the run before any WUA work: the directory holds selection.json and status.json, and
    # a directory that is no longer the one that was secured cannot be read from or reported into.
    workspaceSealVerified = $null
    # False unless this guest was already busy with another run of this tool, or carried an
    # unreconciled trace of one. True is absolute: no WUA work here, no reboot, no next cycle
    # for this VM in this run - even after the other process has ended.
    guestRunConflict = $false
    guestRunConflictReason = $null
    # Which kind, because the orchestrator decides between waiting and stopping on it: 'Held'
    # (another run is working here now), 'Unconfirmed' (a previous run never reported completion),
    # 'RebootPending' (this guest is on its way back up), 'Unreadable' (a record nobody can read).
    # Only RebootPending clears itself; the other two need a person.
    guestRunConflictKind = $null
    # Approved keys that are no longer in the current search result. Not an error in itself and
    # not a reason to install nothing: WUA revises a package between the plan and the apply, and
    # the exact keys the operator approved are still the only ones this run may install.
    missingUpdateKeys = @()
    selectionDrift = $false
    requiresVerification = $false
    errors = @()
}

$scriptExitCode = 1
$guestRunGuard = $null

try {
    Write-AgentLog -Message 'Agent started.'
    Save-Status -Status $status

    if ($MaxUpdates -lt 1) {
        throw 'MaxUpdates must be greater than or equal to 1.'
    }

    # Before the run guard, so a refused seal leaves no trace to reconcile, and long before the
    # WUA session. The bootstrap verified and sealed this directory, then the orchestrator
    # uploaded into it and started this process - three separate GuestOps calls with gaps between
    # them. Re-reading the seal here is what turns "the directory was safe when we checked it"
    # into "this is the same directory we secured".
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceSealToken)) {
        $sealVerdict = Assert-GuestWorkspaceSeal -Path $WorkingDirectory -Token $WorkspaceSealToken
        $status.workspaceSealVerified = ($sealVerdict.Status -eq 'Ok')
        Save-Status -Status $status
        if (-not $status.workspaceSealVerified) {
            throw ('The workspace seal was refused, so this directory is not the one that was secured for this run: {0}' -f [string]$sealVerdict.Reason)
        }
        Write-AgentLog -Message 'Workspace seal verified.'
    }

    # Taken before the WUA session is created, and held until the terminal status below has been
    # written. Two WUA sessions installing on one guest corrupt each other's work, so a guest
    # that is already busy - or that carries the trace of a run which never reported completion -
    # is reported and left alone rather than worked on anyway.
    $guestRunGuard = Enter-GuestRunGuard -RunId $RunId -Phase 'Agent'
    if (-not $guestRunGuard.Acquired) {
        if ($guestRunGuard.Conflict) {
            $status.guestRunConflict = $true
            $status.guestRunConflictReason = [string]$guestRunGuard.Reason
            $status.guestRunConflictKind = [string]$guestRunGuard.ConflictKind
        }
        throw ('This guest is not available for a patching run: {0}' -f $guestRunGuard.Reason)
    }
    Write-AgentLog -Message ('Guest run guard acquired for run {0}.' -f $RunId)

    $status.isElevated = Test-IsElevated
    $status.services = Get-ServiceSnapshot
    $status.systemDriveFreeGB = Get-SystemDriveFreeGB
    $status.pendingRebootBefore = Test-PendingReboot
    $status.roleFlags = Get-RoleFlags
    Save-Status -Status $status

    if (-not $status.isElevated) {
        throw 'The agent process is not elevated. WUA install validation requires an elevated local admin token.'
    }

    if (-not $SearchOnly -and $status.roleFlags.failoverCluster) {
        throw 'Failover Cluster detected. Automatic installation is blocked; update manually one by one.'
    }

    # Re-checked here on every apply, whatever a saved plan recorded, and refused rather than
    # assumed either way: a node this tool cannot classify must not be patched or restarted.
    if (-not $SearchOnly -and [string]$status.roleFlags.clusterMembership -eq 'Unknown') {
        throw ('Failover Cluster membership could not be determined. Automatic installation is blocked. {0}' -f [string]$status.roleFlags.clusterMembershipReason)
    }

    Write-AgentLog -Message 'Creating Microsoft.Update.Session.'
    $updateSession = New-Object -ComObject Microsoft.Update.Session
    $updateSession.ClientApplicationID = 'PatchingGuestOpsPhase0b'

    Write-AgentLog -Message ('Searching updates with criteria: {0}' -f $SearchCriteria)
    $updateSearcher = $updateSession.CreateUpdateSearcher()
    $updateSearcher.ClientApplicationID = 'PatchingGuestOpsPhase0b'
    $searchResult = $updateSearcher.Search($SearchCriteria)

    $status.availableUpdateCount = [int]$searchResult.Updates.Count
    $status.searchResult = [ordered]@{
        resultCode = [int]$searchResult.ResultCode
        result = Convert-ResultCode -ResultCode $searchResult.ResultCode
        hResult = Format-HResult -HResult (Get-OptionalPropertyValue -InputObject $searchResult -Name 'HResult')
        warnings = @()
    }

    $searchWarnings = Get-OptionalPropertyValue -InputObject $searchResult -Name 'Warnings'
    if ($null -ne $searchWarnings) {
        for ($i = 0; $i -lt $searchWarnings.Count; $i++) {
            $searchWarning = $searchWarnings.Item($i)
            $status.searchResult.warnings += [ordered]@{
                message = Get-OptionalStringPropertyValue -InputObject $searchWarning -Name 'Message'
                hResult = Format-HResult -HResult (Get-OptionalPropertyValue -InputObject $searchWarning -Name 'HResult')
                context = Get-OptionalPropertyValue -InputObject $searchWarning -Name 'Context'
            }
        }
    }
    if ([int]$searchResult.ResultCode -ne 2) {
        throw ('WUA search did not complete successfully (ResultCode={0}). Results may be incomplete; download and installation are blocked.' -f [int]$searchResult.ResultCode)
    }

    if ($searchResult.Updates.Count -eq 0) {
        $status.outcome = 'NoApplicableUpdates'
        $scriptExitCode = 0
        Write-AgentLog -Message 'No applicable updates found.'
    }
    elseif ($SearchOnly) {
        for ($i = 0; $i -lt $searchResult.Updates.Count; $i++) {
            $update = $searchResult.Updates.Item($i)
            $status.updates += New-UpdateRecord -Update $update -Index $i
        }

        $status.outcome = 'SearchOnly'
        $scriptExitCode = 0
        Save-Status -Status $status
        Write-AgentLog -Message 'SearchOnly mode requested. Download and install skipped.'
    }
    else {
        $selectedUpdates = New-Object -ComObject Microsoft.Update.UpdateColl
        $selectedSearchIndexes = @()
        $effectiveSelectedUpdateKeys = @($SelectedUpdateKeys)
        if (-not [string]::IsNullOrWhiteSpace($SelectionPath)) {
            $effectiveSelectedUpdateKeys = @(Read-SelectionDocumentKeys -Path $SelectionPath)
            $status.selectedUpdateKeys = @($effectiveSelectedUpdateKeys)
            Save-Status -Status $status
        }
        $selectedKeyLookup = @{}
        foreach ($selectedUpdateKey in @($effectiveSelectedUpdateKeys)) {
            foreach ($selectedUpdateKeyPart in @([string]$selectedUpdateKey -split ',')) {
                $selectedKey = ([string]$selectedUpdateKeyPart).Trim()
                if ([string]::IsNullOrWhiteSpace($selectedKey)) {
                    continue
                }

                $selectedKeyLookup[$selectedKey] = $true
            }
        }

        $hasExplicitKeySelection = ($selectedKeyLookup.Count -gt 0)
        $selectionLimit = [Math]::Min($MaxUpdates, [int]$searchResult.Updates.Count)
        $seenSelectedLookupKeys = @{}

        for ($i = 0; $i -lt $searchResult.Updates.Count; $i++) {
            $update = $searchResult.Updates.Item($i)
            $record = New-UpdateRecord -Update $update -Index $i
            $status.updates += $record

            if ($hasExplicitKeySelection) {
                $shouldSelectUpdate = ($null -ne $record.identityKey -and $selectedKeyLookup.ContainsKey([string]$record.identityKey))
                if ($shouldSelectUpdate) {
                    $seenSelectedLookupKeys[[string]$record.identityKey] = $true
                }
            }
            else {
                $shouldSelectUpdate = ($selectedUpdates.Count -lt $selectionLimit)
            }

            if ($shouldSelectUpdate) {
                try {
                    if (-not $update.EulaAccepted) {
                        $update.AcceptEula()
                    }

                    [void]$selectedUpdates.Add($update)
                    $selectedSearchIndexes += $i
                    $record.selected = $true
                    $record.eulaAccepted = [bool]$update.EulaAccepted
                }
                catch {
                    # Record the per-update failure but keep going so one bad EULA does
                    # not discard the rest of an otherwise valid batch.
                    $record.errors += [ordered]@{
                        stage = 'AcceptEulaOrSelect'
                        message = $_.Exception.Message
                    }
                    $status.errors += [ordered]@{
                        stage = 'AcceptEulaOrSelect'
                        updateIndex = $i
                        updateTitle = $record.title
                        updateId = $record.updateId
                        message = $_.Exception.Message
                    }
                    $record.selected = $false
                }
            }
        }

        if ($hasExplicitKeySelection) {
            # Drift used to throw, which discarded every still-available approved update along
            # with the one that had moved. The approved set is an exact intersection with what WUA
            # offers right now: a revision the operator never approved is never substituted for
            # one that vanished, and the keys that vanished are reported so somebody checks them.
            $status.missingUpdateKeys = @(@($selectedKeyLookup.Keys) | Where-Object { -not $seenSelectedLookupKeys.ContainsKey([string]$_) })
            $status.selectionDrift = ($status.missingUpdateKeys.Count -gt 0)
            $status.requiresVerification = $status.selectionDrift
            if ($status.selectionDrift) {
                # Logged and saved BEFORE the download, so a crash mid-install still leaves the
                # trace that this run installed less than was approved.
                Write-AgentLog -Message ('Selection drift: approved update key(s) are no longer offered by WUA and were not installed: {0}' -f (@($status.missingUpdateKeys) -join ', '))
                Save-Status -Status $status
            }
        }

        $status.selectedUpdateCount = [int]$selectedUpdates.Count
        Save-Status -Status $status

        if ($selectedUpdates.Count -eq 0) {
            $status.outcome = 'NoSelectedUpdates'
            $scriptExitCode = 1
            if ($status.selectionDrift) {
                Write-AgentLog -Message 'Every approved update has drifted; nothing was downloaded or installed.'
            }
            else {
                Write-AgentLog -Message 'Applicable updates were found, but none were selected.'
            }
        }
        else {
            Write-AgentLog -Message ('Downloading {0} selected update(s).' -f $selectedUpdates.Count)
            $downloader = $updateSession.CreateUpdateDownloader()
            $downloader.ClientApplicationID = 'PatchingGuestOpsPhase0b'
            $downloader.Updates = $selectedUpdates
            $downloadResult = $downloader.Download()
            $status.downloadResult = New-OperationResult -Result $downloadResult

            for ($selectedIndex = 0; $selectedIndex -lt $selectedUpdates.Count; $selectedIndex++) {
                $searchIndex = $selectedSearchIndexes[$selectedIndex]
                try {
                    $perUpdateDownload = $downloadResult.GetUpdateResult($selectedIndex)
                    $status.updates[$searchIndex].downloadResult = New-OperationResult -Result $perUpdateDownload
                }
                catch {
                    $status.updates[$searchIndex].errors += [ordered]@{
                        stage = 'ReadDownloadResult'
                        message = $_.Exception.Message
                    }
                }
            }

            Save-Status -Status $status

            if ([int]$downloadResult.ResultCode -notin @(2, 3)) {
                $status.outcome = 'DownloadFailed'
                $scriptExitCode = 1
                Write-AgentLog -Message ('Download failed with result code {0}.' -f [int]$downloadResult.ResultCode)
            }
            else {
                Write-AgentLog -Message ('Installing {0} selected update(s).' -f $selectedUpdates.Count)
                $installer = $updateSession.CreateUpdateInstaller()
                $installer.ClientApplicationID = 'PatchingGuestOpsPhase0b'
                $installer.AllowSourcePrompts = $false
                $installer.Updates = $selectedUpdates
                $installResult = $installer.Install()
                $status.installResult = New-OperationResult -Result $installResult

                for ($selectedIndex = 0; $selectedIndex -lt $selectedUpdates.Count; $selectedIndex++) {
                    $searchIndex = $selectedSearchIndexes[$selectedIndex]
                    try {
                        $perUpdateInstall = $installResult.GetUpdateResult($selectedIndex)
                        $status.updates[$searchIndex].installResult = New-OperationResult -Result $perUpdateInstall
                    }
                    catch {
                        $status.updates[$searchIndex].errors += [ordered]@{
                            stage = 'ReadInstallResult'
                            message = $_.Exception.Message
                        }
                    }
                }

                if ([int]$installResult.ResultCode -eq 2) {
                    $status.outcome = 'InstallSucceeded'
                    $scriptExitCode = 0
                    # WUA reports on the collection it received, which excludes updates
                    # whose EULA/selection failed. Those failures still belong to this run.
                    if (@($status.errors).Count -gt 0 -or @($status.updates | Where-Object { @($_.errors).Count -gt 0 }).Count -gt 0) {
                        $status.outcome = 'InstallSucceededWithErrors'
                        $scriptExitCode = 1
                    }
                }
                elseif ([int]$installResult.ResultCode -eq 3) {
                    $status.outcome = 'InstallSucceededWithErrors'
                    $scriptExitCode = 1
                }
                else {
                    $status.outcome = 'InstallFailed'
                    $scriptExitCode = 1
                }
            }
        }
    }

    Write-AgentLog -Message ('Agent run completed with outcome {0}.' -f $status.outcome)
}
catch {
    $status.outcome = 'Failed'
    Add-StatusError -Status $status -ErrorRecord $_
    Write-AgentLog -Message ('ERROR: {0}' -f $_.Exception.Message)
    $scriptExitCode = 1
}
finally {
    try {
        $status.pendingRebootAfter = Test-PendingReboot
        $status.pendingReboot = $status.pendingRebootAfter
    }
    catch {
        $status.pendingRebootAfter = [ordered]@{
            isPending = $null
            checks = @{}
            error = $_.Exception.Message
        }
        $status.pendingReboot = $status.pendingRebootAfter
    }

    $status.finishedAt = (Get-Date).ToString('o')
    Save-Status -Status $status
    Write-AgentLog -Message ('Agent finished with outcome {0} and exit code {1}.' -f $status.outcome, $scriptExitCode)

    # Completion is recorded only now, after the terminal status is on disk: it is what lets the
    # next run start without a conflict, so recording it any earlier would hand a guest whose
    # result was never written to another run. A crash before this point deliberately leaves the
    # guard saying "Running", which is the unreconciled state the next run must refuse.
    if ($null -ne $guestRunGuard -and $guestRunGuard.Acquired) {
        try {
            $null = Set-GuestRunGuardCompleted -Guard $guestRunGuard -Outcome ([string]$status.outcome)
        }
        catch {
            Write-AgentLog -Message ('WARNING: the guest run guard could not record completion: {0}' -f $_.Exception.Message)
        }
        Exit-GuestRunGuard -Guard $guestRunGuard
    }
}

exit $scriptExitCode

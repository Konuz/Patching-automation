[CmdletBinding()]
param(
    [string]$WorkingDirectory = 'C:\ProgramData\PatchingGuestOps',
    [int]$MaxUpdates = 1,
    [string[]]$SelectedUpdateIds = @(),
    [switch]$SearchOnly,
    [string]$SearchCriteria = "IsInstalled=0 and IsHidden=0 and Type='Software'"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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

    $rebootBehavior = $null
    try {
        $rebootBehavior = [int]$Update.InstallationBehavior.RebootBehavior
    }
    catch {
        $rebootBehavior = $null
    }

    return [ordered]@{
        index = $Index
        title = [string]$Update.Title
        kbArticleIds = $kbArticleIds
        updateId = $updateId
        revisionNumber = $revisionNumber
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
    selectedUpdateIds = @($SelectedUpdateIds)
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
    errors = @()
}

$scriptExitCode = 1

try {
    Write-AgentLog -Message 'Agent started.'
    Save-Status -Status $status

    if ($MaxUpdates -lt 1) {
        throw 'MaxUpdates must be greater than or equal to 1.'
    }

    $status.isElevated = Test-IsElevated
    $status.services = Get-ServiceSnapshot
    $status.systemDriveFreeGB = Get-SystemDriveFreeGB
    $status.pendingRebootBefore = Test-PendingReboot
    Save-Status -Status $status

    if (-not $status.isElevated) {
        throw 'The agent process is not elevated. WUA install validation requires an elevated local admin token.'
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
        $selectedIdLookup = @{}
        foreach ($selectedUpdateId in @($SelectedUpdateIds)) {
            if ([string]::IsNullOrWhiteSpace([string]$selectedUpdateId)) {
                continue
            }

            $selectedIdLookup[[string]$selectedUpdateId] = $true
        }

        $hasExplicitSelection = ($selectedIdLookup.Count -gt 0)
        $selectionLimit = [Math]::Min($MaxUpdates, [int]$searchResult.Updates.Count)
        $seenSelectedIds = @{}

        for ($i = 0; $i -lt $searchResult.Updates.Count; $i++) {
            $update = $searchResult.Updates.Item($i)
            $record = New-UpdateRecord -Update $update -Index $i
            $status.updates += $record

            if ($hasExplicitSelection) {
                # Select by stable update identity, not by position: the install pass
                # runs a fresh WUA search whose ordering is not guaranteed to match the
                # search pass the operator chose from.
                $shouldSelectUpdate = ($null -ne $record.updateId -and $selectedIdLookup.ContainsKey([string]$record.updateId))
                if ($shouldSelectUpdate) {
                    $seenSelectedIds[[string]$record.updateId] = $true
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

        if ($hasExplicitSelection) {
            $missingUpdateIds = @(@($selectedIdLookup.Keys) | Where-Object { -not $seenSelectedIds.ContainsKey([string]$_) })
            if ($missingUpdateIds.Count -gt 0) {
                throw ('Selected update id(s) not present in the current search result (search/selection drift): {0}' -f ($missingUpdateIds -join ', '))
            }
        }

        $status.selectedUpdateCount = [int]$selectedUpdates.Count
        Save-Status -Status $status

        if ($selectedUpdates.Count -eq 0) {
            $status.outcome = 'NoSelectedUpdates'
            $scriptExitCode = 1
            Write-AgentLog -Message 'Applicable updates were found, but none were selected.'
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
}

exit $scriptExitCode

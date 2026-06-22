[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VIServer,

    [string]$VMName,

    [string[]]$VMNames,

    [string]$VMListPath,

    [pscredential]$VIServerCredential,

    [pscredential]$GuestCredential,

    [string]$AgentPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'guest\Run-LocalPatch.ps1'),

    [string]$GuestWorkingDirectory = 'C:\ProgramData\PatchingGuestOps',

    [string]$LocalOutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out'),

    [string]$PatchPlanPath,

    [int]$MaxUpdates = 1,

    [string]$InstallSelection,

    [string[]]$SelectedUpdateKeys,

    [int]$ThrottleLimit = 3,

    [switch]$SearchOnly,

    [switch]$PlanOnly,

    [switch]$SkipConfirmation,

    [int]$TimeoutMinutes = 180,

    [int]$PollSeconds = 15,

    [switch]$IgnoreVCenterCertificate,

    [switch]$KeepConnected
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$guestOpsLibPath = Join-Path $PSScriptRoot 'GuestOpsLib.ps1'
. $guestOpsLibPath

. (Join-Path $PSScriptRoot 'VMTargetLib.ps1')

$identityHelperPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'guest\UpdateIdentity.ps1'

function Resolve-VMTargetNames {
    param(
        [string]$SingleVMName,
        [string[]]$ManyVMNames,
        [string]$ListPath
    )

    $uniqueTargets = @(Resolve-VMTargetNamesFromSources -SingleVMName $SingleVMName -ManyVMNames $ManyVMNames -ListPath $ListPath)

    if ($uniqueTargets.Count -eq 0) {
        throw 'At least one VM target is required. Use -VMName, -VMNames, or -VMListPath.'
    }

    return $uniqueTargets
}

function Assert-LocalPrerequisites {
    param([string]$LocalAgentPath)

    if (-not (Test-Path -LiteralPath $LocalAgentPath -PathType Leaf)) {
        throw ('Agent file not found: {0}' -f $LocalAgentPath)
    }

    $curlCommand = Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue
    if ($null -eq $curlCommand) {
        throw 'curl.exe was not found in PATH.'
    }

    $powerCliModule = Get-Module -ListAvailable -Name VMware.PowerCLI
    if ($null -eq $powerCliModule) {
        throw 'VMware.PowerCLI module was not found.'
    }

    return $curlCommand.Source
}

function Get-GuestOpsCycleJobScript {
    return {
        param($JobInput)

        Set-StrictMode -Version 2.0
        $ErrorActionPreference = 'Stop'

        $connection = $null
        try {
            Import-Module VMware.PowerCLI -ErrorAction Stop
            if ($JobInput.IgnoreVCenterCertificate) {
                Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            }
            . $JobInput.GuestOpsLibPath

            $connection = Connect-VIServer -Server $JobInput.VIServer -Credential $JobInput.VIServerCredential -ErrorAction Stop
            $managers = Get-GuestOpsManagers
            $guestAuth = New-GuestAuthentication -Credential $JobInput.GuestCredential
            $jobLocalSelectionPath = [string](Get-ObjectPropertyValue -InputObject $JobInput -Path @('LocalSelectionPath'))
            $jobGuestSelectionPath = [string](Get-ObjectPropertyValue -InputObject $JobInput -Path @('GuestSelectionPath'))
            $cycle = Invoke-VMAgentCycle -VMName $JobInput.VMName -Managers $managers -GuestAuth $guestAuth -CurlPath $JobInput.CurlPath -AgentPath $JobInput.AgentPath -IdentityHelperPath $JobInput.IdentityHelperPath -GuestWorkingDirectory $JobInput.GuestWorkingDirectory -VMOutputDirectory $JobInput.VMOutputDirectory -MaxUpdates $JobInput.MaxUpdates -LocalSelectionPath $jobLocalSelectionPath -SelectionPath $jobGuestSelectionPath -SearchOnly:$JobInput.SearchOnly -TimeoutSeconds $JobInput.TimeoutSeconds -PollSeconds $JobInput.PollSeconds
            return [pscustomobject]@{
                Sequence = $JobInput.Sequence
                VMName = $JobInput.VMName
                VMOutputDirectory = $JobInput.VMOutputDirectory
                Status = $cycle.Status
                AgentResult = $cycle.AgentResult
                Error = $null
            }
        }
        catch {
            return [pscustomobject]@{
                Sequence = $JobInput.Sequence
                VMName = $JobInput.VMName
                VMOutputDirectory = $JobInput.VMOutputDirectory
                Status = $null
                AgentResult = $null
                Error = $_.Exception.Message
            }
        }
        finally {
            if ($null -ne $connection) {
                try {
                    Disconnect-VIServer -Server $connection -Confirm:$false | Out-Null
                }
                catch { }
            }
        }
    }
}

function Get-GuestRebootJobScript {
    return {
        param($JobInput)

        Set-StrictMode -Version 2.0
        $ErrorActionPreference = 'Stop'

        $connection = $null
        try {
            Import-Module VMware.PowerCLI -ErrorAction Stop
            if ($JobInput.IgnoreVCenterCertificate) {
                Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            }
            . $JobInput.GuestOpsLibPath

            $connection = Connect-VIServer -Server $JobInput.VIServer -Credential $JobInput.VIServerCredential -ErrorAction Stop
            $managers = Get-GuestOpsManagers
            $guestAuth = New-GuestAuthentication -Credential $JobInput.GuestCredential
            $rebootResult = Invoke-VMGuestReboot -VMName $JobInput.VMName -Managers $managers -GuestAuth $guestAuth

            return [pscustomobject]@{
                Sequence = $JobInput.Sequence
                VMName = $JobInput.VMName
                ProcessId = $rebootResult.ProcessId
                Error = $null
            }
        }
        catch {
            return [pscustomobject]@{
                Sequence = $JobInput.Sequence
                VMName = $JobInput.VMName
                ProcessId = $null
                Error = $_.Exception.Message
            }
        }
        finally {
            if ($null -ne $connection) {
                try {
                    Disconnect-VIServer -Server $connection -Confirm:$false | Out-Null
                }
                catch { }
            }
        }
    }
}

function Get-SafeFileName {
    param([string]$Value)
    return ($Value -replace '[^a-zA-Z0-9_.-]', '_')
}

function New-UniqueOutputDirectory {
    param([string]$BasePath)

    $candidatePath = $BasePath
    $suffix = 2
    while (Test-Path -LiteralPath $candidatePath) {
        $candidatePath = '{0}-{1}' -f $BasePath, $suffix
        $suffix++
    }

    New-Item -ItemType Directory -Force -Path $candidatePath | Out-Null
    return $candidatePath
}

function Show-UpdateGroups {
    param($UpdateGroups)

    Write-Host ''
    Write-Host 'Available update groups'
    Write-Host '-----------------------'

    $index = 1
    foreach ($group in @($UpdateGroups)) {
        $mark = if ($group.selectedByDefault) { 'x' } else { ' ' }
        $kbText = if ([string]::IsNullOrWhiteSpace([string]$group.kbText)) { 'No KB' } else { [string]$group.kbText }
        Write-Host ('[{0}] {1}. {2} - {3}' -f $mark, $index, $kbText, $group.title)
        Write-Host ('    Applies to: {0} VM; Patchable: {1} VM' -f $group.appliesToVmCount, $group.patchableVmCount)
        Write-Host ('    Key: {0}' -f $group.identityKey)
        $index++
    }
}

function Resolve-SelectedUpdateKeys {
    param(
        $UpdateGroups,
        [string[]]$ExplicitSelectedUpdateKeys = @()
    )

    $explicitKeyValues = @($ExplicitSelectedUpdateKeys)
    if ($explicitKeyValues.Count -gt 0) {
        $knownKeys = @{}
        foreach ($group in @($UpdateGroups)) {
            if ($null -eq $group) {
                continue
            }

            $knownKey = ([string]$group.identityKey).Trim()
            if (-not [string]::IsNullOrWhiteSpace($knownKey)) {
                $knownKeys[$knownKey] = $true
            }
        }

        $selectedKeys = New-Object System.Collections.Generic.List[string]
        $seenSelectedKeys = @{}
        foreach ($explicitKey in $explicitKeyValues) {
            $selectedKey = ([string]$explicitKey).Trim()
            if ([string]::IsNullOrWhiteSpace($selectedKey)) {
                continue
            }

            if (-not $seenSelectedKeys.ContainsKey($selectedKey)) {
                $seenSelectedKeys[$selectedKey] = $true
                [void]$selectedKeys.Add($selectedKey)
            }
        }

        if ($selectedKeys.Count -eq 0) {
            throw 'SelectedUpdateKeys did not contain any non-empty update keys.'
        }

        foreach ($selectedKey in @($selectedKeys.ToArray())) {
            if (-not $knownKeys.ContainsKey($selectedKey)) {
                throw ('Selected update key is not present in discovered update groups: {0}' -f $selectedKey)
            }
        }

        return @($selectedKeys.ToArray())
    }

    return @(@($UpdateGroups) | Where-Object { $_.selectedByDefault } | ForEach-Object { [string]$_.identityKey })
}

function Read-UpdateGroupSelection {
    param($UpdateGroups)

    $groups = @($UpdateGroups)
    $selected = @{}
    for ($i = 0; $i -lt $groups.Count; $i++) {
        $selected[$i] = [bool]$groups[$i].selectedByDefault
    }

    while ($true) {
        Write-Host ''
        Write-Host 'Toggle update groups by number, press Enter to accept current selection.'
        for ($i = 0; $i -lt $groups.Count; $i++) {
            $mark = if ($selected[$i]) { 'x' } else { ' ' }
            Write-Host ('[{0}] {1}. {2}' -f $mark, ($i + 1), $groups[$i].title)
        }

        $inputText = Read-Host 'Group number to toggle'
        if ([string]::IsNullOrWhiteSpace($inputText)) {
            break
        }

        $displayNumber = 0
        if (-not [int]::TryParse($inputText, [ref]$displayNumber)) {
            Write-Warning ('Invalid group number: {0}' -f $inputText)
            continue
        }

        if ($displayNumber -lt 1 -or $displayNumber -gt $groups.Count) {
            Write-Warning ('Group number {0} is outside the range 1..{1}.' -f $displayNumber, $groups.Count)
            continue
        }

        $selectedIndex = $displayNumber - 1
        $selected[$selectedIndex] = -not $selected[$selectedIndex]
    }

    $selectedKeys = @()
    for ($i = 0; $i -lt $groups.Count; $i++) {
        if ($selected[$i]) {
            $selectedKeys += [string]$groups[$i].identityKey
        }
    }

    return $selectedKeys
}

function Show-PatchPlan {
    param($PatchPlanRecords)

    Write-Host ''
    Write-Host 'Patch plan'
    Write-Host '----------'

    foreach ($record in @($PatchPlanRecords)) {
        Write-Host ''
        Write-Host $record.vmName
        $roleFlagText = if ($record.roleFlags -is [string]) { [string]$record.roleFlags } else { Get-RoleFlagText -RoleFlags $record.roleFlags }
        Write-Host ('Role flags: {0}' -f $roleFlagText)

        if ($record.action -eq 'Skip') {
            Write-Host $record.reason
            continue
        }

        if ($record.action -eq 'NoSelectedUpdates') {
            Write-Host $record.reason
            continue
        }

        Write-Host 'Selected:'
        foreach ($update in @($record.selectedUpdates)) {
            $kbPrefix = if ([string]::IsNullOrWhiteSpace([string]$update.kbText)) { '' } else { ('{0} - ' -f $update.kbText) }
            Write-Host ('- {0}{1}' -f $kbPrefix, $update.title)
        }
    }
}

function Confirm-PatchPlan {
    param([switch]$SkipConfirmation)

    if ($SkipConfirmation) {
        return $true
    }

    $answer = Read-Host 'Proceed with this plan? [Y/N]'
    return ($answer -ieq 'Y' -or $answer -ieq 'Yes')
}

function Confirm-GuestReboot {
    param($RebootTargets)

    $targets = @($RebootTargets)
    if ($targets.Count -eq 0) {
        return $false
    }

    Write-Host ''
    Write-Host ('Reboot required on {0} VM(s):' -f $targets.Count)
    foreach ($target in $targets) {
        Write-Host ('- {0}' -f $target.vmName)
    }
    Write-Host ''

    $answer = Read-Host 'Initiate guest reboot now? Type REBOOT to continue'
    return (([string]$answer).Trim() -ceq 'REBOOT')
}

function Update-PatchPlanWithDiscoveryFailures {
    param(
        $PatchPlanRecords,
        $DiscoveryRecords
    )

    $planRecordsByVmName = @{}
    foreach ($record in @($PatchPlanRecords)) {
        $vmName = [string](Get-ObjectPropertyValue -InputObject $record -Path @('vmName'))
        if (-not [string]::IsNullOrWhiteSpace($vmName) -and -not $planRecordsByVmName.ContainsKey($vmName)) {
            $planRecordsByVmName[$vmName] = $record
        }
    }

    foreach ($discoveryRecord in @($DiscoveryRecords)) {
        $vmName = [string](Get-ObjectPropertyValue -InputObject $discoveryRecord -Path @('vmName'))
        if ([string]::IsNullOrWhiteSpace($vmName) -or -not $planRecordsByVmName.ContainsKey($vmName)) {
            continue
        }

        $errors = @(Get-ObjectPropertyValue -InputObject $discoveryRecord -Path @('errors') -DefaultValue @() | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
        $outcome = [string](Get-ObjectPropertyValue -InputObject $discoveryRecord -Path @('outcome'))
        $hasDiscoveryErrors = ($errors.Count -gt 0)
        $hasSuccessfulDiscoveryOutcome = Test-IsSuccessfulDiscoveryOutcome -Outcome $outcome
        if (-not $hasDiscoveryErrors -and $hasSuccessfulDiscoveryOutcome) {
            continue
        }

        $planRecord = $planRecordsByVmName[$vmName]
        $planRecord.action = 'Skip'
        $planRecord.reason = 'Skipped: Discovery failed. Review discovery.json and per-VM agent artifacts.'
        $planRecord.selectedUpdates = @()
    }

    return @($PatchPlanRecords)
}

function Test-IsSuccessfulDiscoveryOutcome {
    param([string]$Outcome)

    return ($Outcome -in @('SearchOnly', 'NoApplicableUpdates'))
}

function New-DiscoveryRecord {
    param(
        [string]$VMName,
        $Status,
        [string]$OutputDirectory,
        [string[]]$Errors = @()
    )

    $outcome = Get-ObjectPropertyValue -InputObject $Status -Path @('outcome')
    if ([string]::IsNullOrWhiteSpace([string]$outcome) -and @($Errors).Count -gt 0) {
        $outcome = 'DiscoveryFailed'
    }

    return [pscustomobject]@{
        vmName = $VMName
        computerName = Get-ObjectPropertyValue -InputObject $Status -Path @('computerName')
        outcome = $outcome
        isElevated = Get-ObjectPropertyValue -InputObject $Status -Path @('isElevated')
        availableUpdateCount = Get-ObjectPropertyValue -InputObject $Status -Path @('availableUpdateCount') -DefaultValue 0
        roleFlags = Get-ObjectPropertyValue -InputObject $Status -Path @('roleFlags')
        pendingRebootBefore = Get-ObjectPropertyValue -InputObject $Status -Path @('pendingRebootBefore')
        updates = @(Get-ObjectPropertyValue -InputObject $Status -Path @('updates') -DefaultValue @())
        outputDirectory = $OutputDirectory
        errors = @($Errors)
    }
}

function New-DiscoveryRecordFromAgentRun {
    param(
        [string]$VMName,
        $AgentRun,
        [string]$OutputDirectory
    )

    $record = New-DiscoveryRecord -VMName $VMName -Status $AgentRun.Status -OutputDirectory $OutputDirectory
    $recordErrors = @($record.errors)

    if (-not (Test-IsSuccessfulDiscoveryOutcome -Outcome $record.outcome)) {
        $recordErrors += ('Discovery returned outcome {0}.' -f $record.outcome)
    }

    if ($null -eq $AgentRun.AgentResult -or -not $AgentRun.AgentResult.Completed) {
        $finishedAt = Get-ObjectPropertyValue -InputObject $AgentRun.Status -Path @('finishedAt')
        if ((Test-IsSuccessfulDiscoveryOutcome -Outcome $record.outcome) -and -not [string]::IsNullOrWhiteSpace([string]$finishedAt)) {
            Write-Warning ('Discovery guest process result timed out for {0}. status.json has a successful discovery outcome and finishedAt, so the JSON artifact remains the primary discovery result.' -f $VMName)
        }
        else {
            $recordErrors += 'Discovery guest process result timed out and status.json did not contain both a successful discovery outcome and finishedAt.'
        }
    }

    $record.errors = @($recordErrors)
    return $record
}

function New-ApplyResultFromCycle {
    param(
        [string]$VMName,
        $Cycle
    )

    $cycle = $Cycle
    $status = $cycle.Status
    $outcome = Get-ObjectPropertyValue -InputObject $status -Path @('outcome')
    $installResult = Get-ObjectPropertyValue -InputObject $status -Path @('installResult', 'result')
    $pendingAfter = [bool](Get-ObjectPropertyValue -InputObject $status -Path @('pendingRebootAfter', 'isPending') -DefaultValue $false)
    $rebootFromInstall = [bool](Get-ObjectPropertyValue -InputObject $status -Path @('installResult', 'rebootRequired') -DefaultValue $false)
    $rebootRequired = ($pendingAfter -or $rebootFromInstall)
    $errors = @(Get-ObjectPropertyValue -InputObject $status -Path @('errors') -DefaultValue @())

    if ($null -eq $cycle.AgentResult -or -not $cycle.AgentResult.Completed) {
        $reason = 'Apply guest process did not complete.'
        $errors += $reason
        return [pscustomobject]@{
            vmName = $VMName
            action = 'Install'
            outcome = 'Failed'
            installResult = $installResult
            reason = $reason
            rebootRequired = $rebootRequired
            errors = @($errors)
        }
    }

    if ($null -ne $cycle.AgentResult.ExitCode -and [int]$cycle.AgentResult.ExitCode -ne 0) {
        $reason = 'Apply guest process exited with code {0}.' -f $cycle.AgentResult.ExitCode
        $errors += $reason
        return [pscustomobject]@{
            vmName = $VMName
            action = 'Install'
            outcome = 'Failed'
            installResult = $installResult
            reason = $reason
            rebootRequired = $rebootRequired
            errors = @($errors)
        }
    }

    return [pscustomobject]@{
        vmName = $VMName
        action = 'Install'
        outcome = $outcome
        installResult = $installResult
        reason = ''
        rebootRequired = $rebootRequired
        errors = @($errors)
    }
}

function Invoke-ApplyPhase {
    param(
        $PatchPlanRecords,
        $Managers,
        $GuestAuth,
        [string]$VIServer,
        [pscredential]$VIServerCredential,
        [pscredential]$GuestCredential,
        [switch]$IgnoreVCenterCertificate,
        [string]$GuestOpsLibPath,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$IdentityHelperPath,
        [string]$GuestWorkingDirectory,
        [int]$TimeoutSeconds,
        [int]$PollSeconds,
        [string]$CycleOutputDirectory,
        [int]$ThrottleLimit = 1
    )

    $resultEntries = @()
    $jobInputs = @()
    $recordNumber = 0

    foreach ($record in @($PatchPlanRecords)) {
        $recordNumber++

        if ($record.action -ne 'Install') {
            $resultEntries += [pscustomobject]@{
                Sequence = $recordNumber
                Result = [pscustomobject]@{
                    vmName = $record.vmName
                    action = $record.action
                    outcome = 'Skipped'
                    installResult = $null
                    reason = $record.reason
                    rebootRequired = $false
                    errors = @()
                }
            }
            continue
        }

        $selectedKeys = @()
        $seenSelectedKeys = @{}
        foreach ($selectedUpdate in @($record.selectedUpdates)) {
            $selectedKey = ([string](Get-ObjectPropertyValue -InputObject $selectedUpdate -Path @('identityKey'))).Trim()
            if ([string]::IsNullOrWhiteSpace($selectedKey)) {
                continue
            }

            if (-not $seenSelectedKeys.ContainsKey($selectedKey)) {
                $seenSelectedKeys[$selectedKey] = $true
                $selectedKeys += $selectedKey
            }
        }

        $vmOutputDirectory = Join-Path $CycleOutputDirectory ('{0:D3}-apply-{1}' -f $recordNumber, (Get-SafeFileName -Value $record.vmName))
        Write-Step -Message ('Apply starting for VM {0} with {1} selected update(s).' -f $record.vmName, $selectedKeys.Count)

        if ($selectedKeys.Count -gt 0) {
            New-Item -ItemType Directory -Force -Path $vmOutputDirectory | Out-Null
            $selectionDocument = New-UpdateSelectionDocument -SelectedUpdateKeys $selectedKeys
            $localSelectionPath = Join-Path $vmOutputDirectory 'selection.json'
            $selectionDocument | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $localSelectionPath -Encoding UTF8
            $guestSelectionPath = Join-Path $GuestWorkingDirectory 'selection.json'
        }

        if ($selectedKeys.Count -eq 0) {
            $reason = 'No selected update keys were available for apply.'
            $resultEntries += [pscustomobject]@{
                Sequence = $recordNumber
                Result = [pscustomobject]@{
                    vmName = $record.vmName
                    action = 'Install'
                    outcome = 'Failed'
                    installResult = $null
                    reason = $reason
                    rebootRequired = $false
                    errors = @($reason)
                }
            }
            continue
        }

        if ($ThrottleLimit -le 1) {
            try {
                $cycle = Invoke-VMAgentCycle -VMName $record.vmName -Managers $Managers -GuestAuth $GuestAuth -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -VMOutputDirectory $vmOutputDirectory -MaxUpdates $selectedKeys.Count -LocalSelectionPath $localSelectionPath -SelectionPath $guestSelectionPath -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds
                $resultEntries += [pscustomobject]@{
                    Sequence = $recordNumber
                    Result = New-ApplyResultFromCycle -VMName $record.vmName -Cycle $cycle
                }
            }
            catch {
                $resultEntries += [pscustomobject]@{
                    Sequence = $recordNumber
                    Result = [pscustomobject]@{
                        vmName = $record.vmName
                        action = 'Install'
                        outcome = 'Failed'
                        installResult = $null
                        reason = $_.Exception.Message
                        rebootRequired = $false
                        errors = @($_.Exception.Message)
                    }
                }
            }
        }
        else {
            $jobInputs += [pscustomobject]@{
                Sequence = $recordNumber
                VMName = [string]$record.vmName
                VIServer = $VIServer
                VIServerCredential = $VIServerCredential
                GuestCredential = $GuestCredential
                IgnoreVCenterCertificate = [bool]$IgnoreVCenterCertificate
                GuestOpsLibPath = $GuestOpsLibPath
                CurlPath = $CurlPath
                AgentPath = $AgentPath
                IdentityHelperPath = $IdentityHelperPath
                GuestWorkingDirectory = $GuestWorkingDirectory
                VMOutputDirectory = $vmOutputDirectory
                MaxUpdates = $selectedKeys.Count
                LocalSelectionPath = $localSelectionPath
                GuestSelectionPath = $guestSelectionPath
                SearchOnly = $false
                TimeoutSeconds = $TimeoutSeconds
                PollSeconds = $PollSeconds
            }
        }
    }

    if ($ThrottleLimit -gt 1 -and $jobInputs.Count -gt 0) {
        $jobScript = Get-GuestOpsCycleJobScript
        $jobResults = @(Invoke-ThrottledJobs -Items $jobInputs -ThrottleLimit $ThrottleLimit -JobTimeoutSeconds ($TimeoutSeconds + 300) -ScriptBlock $jobScript)
        foreach ($jobResult in @($jobResults | Sort-Object Sequence)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$jobResult.Error)) {
                $resultEntries += [pscustomobject]@{
                    Sequence = $jobResult.Sequence
                    Result = [pscustomobject]@{
                        vmName = $jobResult.VMName
                        action = 'Install'
                        outcome = 'Failed'
                        installResult = $null
                        reason = $jobResult.Error
                        rebootRequired = $false
                        errors = @($jobResult.Error)
                    }
                }
                continue
            }

            $cycle = [pscustomobject]@{
                Status = $jobResult.Status
                AgentResult = $jobResult.AgentResult
            }
            $resultEntries += [pscustomobject]@{
                Sequence = $jobResult.Sequence
                Result = New-ApplyResultFromCycle -VMName $jobResult.VMName -Cycle $cycle
            }
        }
    }

    $results = @($resultEntries | Sort-Object Sequence | ForEach-Object { $_.Result })
    $applyResultsPath = Join-Path $CycleOutputDirectory 'apply-results.json'
    $results | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $applyResultsPath -Encoding UTF8
    return @($results)
}

function Invoke-GuestRebootPhase {
    param(
        $RebootTargets,
        $Managers,
        $GuestAuth,
        [string]$VIServer,
        [pscredential]$VIServerCredential,
        [pscredential]$GuestCredential,
        [switch]$IgnoreVCenterCertificate,
        [string]$GuestOpsLibPath,
        [int]$ThrottleLimit = 1
    )

    $resultEntries = @()
    $jobInputs = @()
    $sequence = 0

    foreach ($target in @($RebootTargets)) {
        $sequence++
        $vmName = [string]$target.vmName

        if ($ThrottleLimit -le 1) {
            try {
                $rebootResult = Invoke-VMGuestReboot -VMName $vmName -Managers $Managers -GuestAuth $GuestAuth
                $resultEntries += [pscustomobject]@{
                    Sequence = $sequence
                    Result = New-RebootActionRecord -VMName $vmName -Action 'Initiated' -ProcessId $rebootResult.ProcessId
                }
            }
            catch {
                $resultEntries += [pscustomobject]@{
                    Sequence = $sequence
                    Result = New-RebootActionRecord -VMName $vmName -Action 'Failed' -ErrorMessage $_.Exception.Message
                }
            }
        }
        else {
            $jobInputs += [pscustomobject]@{
                Sequence = $sequence
                VMName = $vmName
                VIServer = $VIServer
                VIServerCredential = $VIServerCredential
                GuestCredential = $GuestCredential
                IgnoreVCenterCertificate = [bool]$IgnoreVCenterCertificate
                GuestOpsLibPath = $GuestOpsLibPath
                VMOutputDirectory = ''
            }
        }
    }

    if ($ThrottleLimit -gt 1 -and $jobInputs.Count -gt 0) {
        $jobScript = Get-GuestRebootJobScript
        $jobResults = @(Invoke-ThrottledJobs -Items $jobInputs -ThrottleLimit $ThrottleLimit -JobTimeoutSeconds 300 -ScriptBlock $jobScript)
        foreach ($jobResult in @($jobResults | Sort-Object Sequence)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$jobResult.Error)) {
                $resultEntries += [pscustomobject]@{
                    Sequence = $jobResult.Sequence
                    Result = New-RebootActionRecord -VMName $jobResult.VMName -Action 'Failed' -ErrorMessage $jobResult.Error
                }
                continue
            }

            $resultEntries += [pscustomobject]@{
                Sequence = $jobResult.Sequence
                Result = New-RebootActionRecord -VMName $jobResult.VMName -Action 'Initiated' -ProcessId $jobResult.ProcessId
            }
        }
    }

    return @($resultEntries | Sort-Object Sequence | ForEach-Object { $_.Result })
}

function Write-FinalReport {
    param(
        $PatchPlanRecords,
        $ApplyResults,
        [string]$CycleOutputDirectory
    )

    $summaryRows = @(ConvertTo-PatchSummaryRows -PatchPlanRecords $PatchPlanRecords)
    $csvPath = Join-Path $CycleOutputDirectory 'summary.csv'
    $summaryRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    $patched = @($ApplyResults | Where-Object { $_.outcome -eq 'InstallSucceeded' })
    $noUpdates = @($PatchPlanRecords | Where-Object { $_.action -eq 'NoSelectedUpdates' })
    $skipped = @($PatchPlanRecords | Where-Object { $_.action -eq 'Skip' })
    $rebootRequired = @($ApplyResults | Where-Object { $_.rebootRequired })
    $errors = @($ApplyResults | Where-Object { Test-IsApplyResultError -ApplyResult $_ })
    $clusters = @($PatchPlanRecords | Where-Object { $_.reason -eq 'Skipped: Failover Cluster detected. Please update manually one by one.' })

    $lines = @()
    $lines += '# Patch summary'
    $lines += ''
    $lines += ('Output directory: `{0}`' -f $CycleOutputDirectory)
    $lines += ''
    $lines += ('- VMs patched: {0}' -f $patched.Count)
    $lines += ('- VMs without selected updates: {0}' -f $noUpdates.Count)
    $lines += ('- VMs skipped: {0}' -f $skipped.Count)
    $lines += ('- VMs requiring reboot: {0}' -f $rebootRequired.Count)
    $lines += ('- VMs with errors: {0}' -f $errors.Count)
    $lines += ('- VMs rejected by Failover Cluster: {0}' -f $clusters.Count)
    $lines += ''

    foreach ($section in @(
        [pscustomobject]@{ Title = 'VMs requiring reboot'; Rows = $rebootRequired },
        [pscustomobject]@{ Title = 'VMs with errors'; Rows = $errors },
        [pscustomobject]@{ Title = 'VMs rejected by Failover Cluster'; Rows = $clusters }
    )) {
        $lines += ('## {0}' -f $section.Title)
        if (@($section.Rows).Count -eq 0) {
            $lines += '- none'
        }
        else {
            foreach ($row in @($section.Rows)) {
                $lines += ('- {0}' -f $row.vmName)
            }
        }
        $lines += ''
    }

    $markdownPath = Join-Path $CycleOutputDirectory 'summary.md'
    Set-Content -LiteralPath $markdownPath -Value $lines -Encoding UTF8

    Write-Host ''
    Write-Host 'Final report'
    Write-Host '------------'
    Write-Host ('Summary CSV: {0}' -f $csvPath)
    Write-Host ('Summary Markdown: {0}' -f $markdownPath)
}

function Invoke-ApplyAndOptionalReboot {
    param(
        $PatchPlanRecords,
        $Managers,
        $GuestAuth,
        [string]$VIServer,
        [pscredential]$VIServerCredential,
        [pscredential]$GuestCredential,
        [switch]$IgnoreVCenterCertificate,
        [string]$GuestOpsLibPath,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$IdentityHelperPath,
        [string]$GuestWorkingDirectory,
        [int]$TimeoutSeconds,
        [int]$PollSeconds,
        [string]$CycleOutputDirectory,
        [int]$ThrottleLimit
    )

    $applyResults = @(Invoke-ApplyPhase -PatchPlanRecords $PatchPlanRecords -Managers $Managers -GuestAuth $GuestAuth -VIServer $VIServer -VIServerCredential $VIServerCredential -GuestCredential $GuestCredential -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $GuestOpsLibPath -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -CycleOutputDirectory $CycleOutputDirectory -ThrottleLimit $ThrottleLimit)
    Write-FinalReport -PatchPlanRecords $PatchPlanRecords -ApplyResults $applyResults -CycleOutputDirectory $CycleOutputDirectory

    $rebootActions = @()
    $rebootTargets = @(Select-RebootRequiredApplyResults -ApplyResults $applyResults)
    if ($rebootTargets.Count -gt 0) {
        if (Confirm-GuestReboot -RebootTargets $rebootTargets) {
            $rebootActions = @(Invoke-GuestRebootPhase -RebootTargets $rebootTargets -Managers $Managers -GuestAuth $GuestAuth -VIServer $VIServer -VIServerCredential $VIServerCredential -GuestCredential $GuestCredential -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $GuestOpsLibPath -ThrottleLimit $ThrottleLimit)
        }
        else {
            Write-Warning 'Guest reboot was not approved. Reboot phase skipped.'
            $rebootActions = @(New-SkippedRebootActionRecords -RebootTargets $rebootTargets)
        }

        Write-RebootActionArtifacts -CycleOutputDirectory $CycleOutputDirectory -RebootActions $rebootActions
    }

    if ((Test-ApplyResultsSuccessful -ApplyResults $applyResults) -and (Test-RebootActionsSuccessful -RebootActions $rebootActions)) {
        return 0
    }

    return 1
}

function Invoke-DiscoveryPhase {
    param(
        [string[]]$TargetVMNames,
        $Managers,
        $GuestAuth,
        [string]$VIServer,
        [pscredential]$VIServerCredential,
        [pscredential]$GuestCredential,
        [switch]$IgnoreVCenterCertificate,
        [string]$GuestOpsLibPath,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$IdentityHelperPath,
        [string]$GuestWorkingDirectory,
        [int]$MaxUpdates,
        [int]$TimeoutSeconds,
        [int]$PollSeconds,
        [string]$CycleOutputDirectory,
        [int]$ThrottleLimit = 1
    )

    $recordEntries = @()
    $jobInputs = @()
    $targetNumber = 0
    foreach ($targetVMName in @($TargetVMNames)) {
        $targetNumber++
        $vmOutputDirectory = Join-Path $CycleOutputDirectory ('{0:D3}-{1}' -f $targetNumber, (Get-SafeFileName -Value $targetVMName))

        if ($ThrottleLimit -le 1) {
            try {
                $agentRun = Invoke-VMAgentCycle -VMName $targetVMName -Managers $Managers -GuestAuth $GuestAuth -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -VMOutputDirectory $vmOutputDirectory -MaxUpdates $MaxUpdates -SearchOnly -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds
                $recordEntries += [pscustomobject]@{
                    Sequence = $targetNumber
                    Record = New-DiscoveryRecordFromAgentRun -VMName $targetVMName -AgentRun $agentRun -OutputDirectory $vmOutputDirectory
                }
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Warning ('Discovery failed for {0}: {1}' -f $targetVMName, $errorMessage)
                $recordEntries += [pscustomobject]@{
                    Sequence = $targetNumber
                    Record = New-DiscoveryRecord -VMName $targetVMName -Status $null -OutputDirectory $vmOutputDirectory -Errors @($errorMessage)
                }
            }
        }
        else {
            $jobInputs += [pscustomobject]@{
                Sequence = $targetNumber
                VMName = [string]$targetVMName
                VIServer = $VIServer
                VIServerCredential = $VIServerCredential
                GuestCredential = $GuestCredential
                IgnoreVCenterCertificate = [bool]$IgnoreVCenterCertificate
                GuestOpsLibPath = $GuestOpsLibPath
                CurlPath = $CurlPath
                AgentPath = $AgentPath
                IdentityHelperPath = $IdentityHelperPath
                GuestWorkingDirectory = $GuestWorkingDirectory
                VMOutputDirectory = $vmOutputDirectory
                MaxUpdates = $MaxUpdates
                SelectedUpdateKeys = @()
                SearchOnly = $true
                TimeoutSeconds = $TimeoutSeconds
                PollSeconds = $PollSeconds
            }
        }
    }

    if ($ThrottleLimit -gt 1 -and $jobInputs.Count -gt 0) {
        $jobScript = Get-GuestOpsCycleJobScript
        $jobResults = @(Invoke-ThrottledJobs -Items $jobInputs -ThrottleLimit $ThrottleLimit -JobTimeoutSeconds ($TimeoutSeconds + 300) -ScriptBlock $jobScript)
        foreach ($jobResult in @($jobResults | Sort-Object Sequence)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$jobResult.Error)) {
                Write-Warning ('Discovery failed for {0}: {1}' -f $jobResult.VMName, $jobResult.Error)
                $recordEntries += [pscustomobject]@{
                    Sequence = $jobResult.Sequence
                    Record = New-DiscoveryRecord -VMName $jobResult.VMName -Status $null -OutputDirectory $jobResult.VMOutputDirectory -Errors @($jobResult.Error)
                }
                continue
            }

            $agentRun = [pscustomobject]@{
                Status = $jobResult.Status
                AgentResult = $jobResult.AgentResult
            }
            $recordEntries += [pscustomobject]@{
                Sequence = $jobResult.Sequence
                Record = New-DiscoveryRecordFromAgentRun -VMName $jobResult.VMName -AgentRun $agentRun -OutputDirectory $jobResult.VMOutputDirectory
            }
        }
    }

    $records = @($recordEntries | Sort-Object Sequence | ForEach-Object { $_.Record })
    $discoveryPath = Join-Path $CycleOutputDirectory 'discovery.json'
    @($records) | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $discoveryPath -Encoding UTF8

    Write-Host ''
    Write-Host 'Discovery summary'
    Write-Host '-----------------'
    foreach ($record in @($records)) {
        Write-Host ('{0}: outcome={1}; updates={2}; roles={3}' -f $record.vmName, $record.outcome, $record.availableUpdateCount, (Get-RoleFlagText -RoleFlags $record.roleFlags))
    }

    return @($records)
}

$targetVMNames = @(Resolve-VMTargetNames -SingleVMName $VMName -ManyVMNames $VMNames -ListPath $VMListPath)
$hasExplicitSelectedUpdateKeys = $PSBoundParameters.ContainsKey('SelectedUpdateKeys')

if (-not [string]::IsNullOrWhiteSpace($InstallSelection)) {
    throw 'InstallSelection is not supported with grouped update selection. Use SelectedUpdateKeys instead.'
}

if ($hasExplicitSelectedUpdateKeys -and @($SelectedUpdateKeys).Count -eq 0) {
    throw 'SelectedUpdateKeys did not contain any non-empty update keys.'
}

if ([string]::IsNullOrWhiteSpace($VMName)) {
    $VMName = $targetVMNames[0]
}

if (-not $VIServerCredential) {
    $VIServerCredential = Get-Credential -Message ('Credentials for vCenter {0}' -f $VIServer)
}

if (-not $GuestCredential) {
    $GuestCredential = Get-Credential -Message ('Local administrator credentials for guest VM {0}' -f $VMName)
}

. (Join-Path $PSScriptRoot 'PatchPlanModel.ps1')
. (Join-Path $PSScriptRoot 'OrchestratorRuntime.ps1')

$curlPath = Assert-LocalPrerequisites -LocalAgentPath $AgentPath

Import-Module VMware.PowerCLI -ErrorAction Stop

if ($IgnoreVCenterCertificate) {
    Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
}

$connection = $null
$scriptExitCode = 1

try {
    Write-Step -Message ('Connecting to vCenter {0}.' -f $VIServer)
    $connection = Connect-VIServer -Server $VIServer -Credential $VIServerCredential -ErrorAction Stop

    $guestAuth = New-GuestAuthentication -Credential $GuestCredential
    $managers = Get-GuestOpsManagers

    if (-not [string]::IsNullOrWhiteSpace($PatchPlanPath)) {
        if (-not (Test-Path -LiteralPath $PatchPlanPath -PathType Leaf)) {
            throw ('Patch plan file not found: {0}' -f $PatchPlanPath)
        }

        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $runOutputDirectory = New-UniqueOutputDirectory -BasePath (Join-Path $LocalOutputDirectory $timestamp)
        $patchPlanRecords = @(ConvertTo-PatchPlanRecords -InputObject (Get-Content -LiteralPath $PatchPlanPath -Raw | ConvertFrom-Json))
        Show-PatchPlan -PatchPlanRecords $patchPlanRecords

        if ($PlanOnly) {
            $scriptExitCode = Get-PlanOnlyExitCode -PatchPlanRecords $patchPlanRecords
        }
        elseif (-not (Confirm-PatchPlan -SkipConfirmation:$SkipConfirmation)) {
            Write-Warning 'Patch plan was not approved. Apply phase skipped.'
            $scriptExitCode = 1
        }
        else {
            $scriptExitCode = Invoke-ApplyAndOptionalReboot -PatchPlanRecords $patchPlanRecords -Managers $managers -GuestAuth $guestAuth -VIServer $VIServer -VIServerCredential $VIServerCredential -GuestCredential $GuestCredential -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $guestOpsLibPath -CurlPath $curlPath -AgentPath $AgentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $runOutputDirectory -ThrottleLimit $ThrottleLimit
        }

        exit $scriptExitCode
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $runOutputDirectory = New-UniqueOutputDirectory -BasePath (Join-Path $LocalOutputDirectory $timestamp)

    $discoveryRecords = Invoke-DiscoveryPhase -TargetVMNames $targetVMNames -Managers $managers -GuestAuth $guestAuth -VIServer $VIServer -VIServerCredential $VIServerCredential -GuestCredential $GuestCredential -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $guestOpsLibPath -CurlPath $curlPath -AgentPath $AgentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -MaxUpdates $MaxUpdates -TimeoutSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $runOutputDirectory -ThrottleLimit $ThrottleLimit
    $failedDiscoveryRecords = @($discoveryRecords | Where-Object { @($_.errors).Count -gt 0 })
    if ($failedDiscoveryRecords.Count -gt 0) {
        $scriptExitCode = 1
    }
    else {
        $scriptExitCode = 0
    }

    $updateGroups = @(New-UpdateGroupRecords -DiscoveryRecords $discoveryRecords | Sort-Object kbText,title)
    Show-UpdateGroups -UpdateGroups $updateGroups

    if (-not $SearchOnly) {
        if ($hasExplicitSelectedUpdateKeys) {
            $selectedKeysForPlan = Resolve-SelectedUpdateKeys -UpdateGroups $updateGroups -ExplicitSelectedUpdateKeys $SelectedUpdateKeys
        }
        elseif ($updateGroups.Count -gt 0) {
            $selectedKeysForPlan = Read-UpdateGroupSelection -UpdateGroups $updateGroups
        }
        else {
            $selectedKeysForPlan = @()
        }

        Write-Step -Message ('Selected update group key(s): {0}' -f @($selectedKeysForPlan).Count)

        $patchPlanRecords = @(New-PatchPlanRecords -DiscoveryRecords $discoveryRecords -SelectedUpdateKeys $selectedKeysForPlan)
        $patchPlanRecords = @(Update-PatchPlanWithDiscoveryFailures -PatchPlanRecords $patchPlanRecords -DiscoveryRecords $discoveryRecords)
        $patchPlanPath = Join-Path $runOutputDirectory 'patch-plan.json'
        $patchPlanRecords | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $patchPlanPath -Encoding UTF8
        Show-PatchPlan -PatchPlanRecords $patchPlanRecords

        if ($PlanOnly) {
            $scriptExitCode = Get-PlanOnlyExitCode -PatchPlanRecords $patchPlanRecords
        }
        elseif (-not (Confirm-PatchPlan -SkipConfirmation:$SkipConfirmation)) {
            Write-Warning 'Patch plan was not approved. Apply phase skipped.'
            $scriptExitCode = 1
        }
        else {
            $scriptExitCode = Invoke-ApplyAndOptionalReboot -PatchPlanRecords $patchPlanRecords -Managers $managers -GuestAuth $guestAuth -VIServer $VIServer -VIServerCredential $VIServerCredential -GuestCredential $GuestCredential -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $guestOpsLibPath -CurlPath $curlPath -AgentPath $AgentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $runOutputDirectory -ThrottleLimit $ThrottleLimit
        }
    }
    elseif ($PlanOnly) {
        $selectedKeysForPlan = @()
        $patchPlanRecords = @(New-PatchPlanRecords -DiscoveryRecords $discoveryRecords -SelectedUpdateKeys $selectedKeysForPlan)
        $patchPlanRecords = @(Update-PatchPlanWithDiscoveryFailures -PatchPlanRecords $patchPlanRecords -DiscoveryRecords $discoveryRecords)
        $patchPlanPath = Join-Path $runOutputDirectory 'patch-plan.json'
        $patchPlanRecords | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $patchPlanPath -Encoding UTF8
        Show-PatchPlan -PatchPlanRecords $patchPlanRecords
        $scriptExitCode = Get-PlanOnlyExitCode -PatchPlanRecords $patchPlanRecords
    }
}
catch {
    Write-Error $_.Exception.Message
    $scriptExitCode = 1
}
finally {
    if ($connection -and -not $KeepConnected) {
        Disconnect-VIServer -Server $connection -Confirm:$false | Out-Null
    }
}

exit $scriptExitCode

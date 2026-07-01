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

        $connections = @()
        try {
            Import-Module VMware.VimAutomation.Core -ErrorAction Stop
            if ($JobInput.IgnoreVCenterCertificate) {
                Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            }
            . $JobInput.GuestOpsLibPath
            $script:SuppressStepMessages = [bool](Get-ObjectPropertyValue -InputObject $JobInput -Path @('SuppressStepMessages'))

            $connections = @(Connect-VIServersWithCredentialMap -VIServers @($JobInput.VIServers) -CredentialMap $JobInput.VIServerCredentialMap)
            $managers = $null
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
            if ($connections.Count -gt 0) {
                try {
                    Disconnect-VIServer -Server $connections -Confirm:$false | Out-Null
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

        $connections = @()
        try {
            Import-Module VMware.VimAutomation.Core -ErrorAction Stop
            if ($JobInput.IgnoreVCenterCertificate) {
                Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            }
            . $JobInput.GuestOpsLibPath

            $connections = @(Connect-VIServersWithCredentialMap -VIServers @($JobInput.VIServers) -CredentialMap $JobInput.VIServerCredentialMap)
            $managers = $null
            $guestAuth = New-GuestAuthentication -Credential $JobInput.GuestCredential
            $rebootResult = Invoke-VMGuestReboot -VMName $JobInput.VMName -Managers $managers -GuestAuth $guestAuth

            return [pscustomobject]@{
                Sequence = $JobInput.Sequence
                VMName = $JobInput.VMName
                RebootReason = $JobInput.RebootReason
                ProcessId = $rebootResult.ProcessId
                Error = $null
            }
        }
        catch {
            return [pscustomobject]@{
                Sequence = $JobInput.Sequence
                VMName = $JobInput.VMName
                RebootReason = $JobInput.RebootReason
                ProcessId = $null
                Error = $_.Exception.Message
            }
        }
        finally {
            if ($connections.Count -gt 0) {
                try {
                    Disconnect-VIServer -Server $connections -Confirm:$false | Out-Null
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

        $selectedKeys = @(Get-UniqueTrimmedKeys -Keys $explicitKeyValues)

        if ($selectedKeys.Count -eq 0) {
            throw 'SelectedUpdateKeys did not contain any non-empty update keys.'
        }

        foreach ($selectedKey in $selectedKeys) {
            if (-not $knownKeys.ContainsKey($selectedKey)) {
                throw ('Selected update key is not present in discovered update groups: {0}' -f $selectedKey)
            }
        }

        return $selectedKeys
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
        Write-Host 'Select update groups to install. Actions:'
        Write-Host '  - Type a group number and press Enter to toggle it on ([x]) or off ([ ]).'
        Write-Host '  - Press Enter on an empty line to accept the current selection and continue.'
        for ($i = 0; $i -lt $groups.Count; $i++) {
            $mark = if ($selected[$i]) { 'x' } else { ' ' }
            Write-Host ('[{0}] {1}. {2}' -f $mark, ($i + 1), $groups[$i].title)
        }

        $inputText = Read-Host 'Group number to toggle (Enter to accept)'
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
        Write-Host '--------------------------------------------------'
        Write-Host $record.vmName
        $roleFlagText = if ($record.roleFlags -is [string]) { [string]$record.roleFlags } else { Get-RoleFlagText -RoleFlags $record.roleFlags }
        Write-Host ('Role flags: {0}' -f $roleFlagText)

        if ($record.action -in @('Skip', 'NoSelectedUpdates')) {
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
        $rebootReason = [string](Get-ObjectPropertyValue -InputObject $target -Path @('rebootReason'))
        $reasonText = if ([string]::IsNullOrWhiteSpace($rebootReason)) { '' } else { (' ({0})' -f $rebootReason) }
        Write-Host ('- {0}{1}' -f $target.vmName, $reasonText)
    }
    Write-Host ''
    Write-Host 'Actions:'
    Write-Host '  - Type REBOOT (uppercase) and press Enter to reboot the VM(s) above now.'
    Write-Host '  - Type anything else (or just press Enter) to skip the reboot and leave them as-is.'

    $answer = Read-Host 'Type REBOOT to continue'
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

    # A partial install (WUA ResultCode 3) exits non-zero but is authoritative in
    # status.json as 'InstallSucceededWithErrors'. Preserve that outcome so the summary
    # can distinguish it from a total failure; only an unrecognized non-zero exit fails.
    if ($null -ne $cycle.AgentResult.ExitCode -and [int]$cycle.AgentResult.ExitCode -ne 0 -and $outcome -ne 'InstallSucceededWithErrors') {
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
        $GuestCredentialMap,
        [string[]]$VIServers,
        [hashtable]$VIServerCredentialMap,
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

        $identityKeys = foreach ($selectedUpdate in @($record.selectedUpdates)) {
            [string](Get-ObjectPropertyValue -InputObject $selectedUpdate -Path @('identityKey'))
        }
        $selectedKeys = @(Get-UniqueTrimmedKeys -Keys @($identityKeys))

        $vmOutputDirectory = Join-Path $CycleOutputDirectory ('{0:D3}-apply-{1}' -f $recordNumber, (Get-SafeFileName -Value $record.vmName))
        Write-Step -Message ('Apply starting for VM {0} with {1} selected update(s).' -f $record.vmName, $selectedKeys.Count)

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

        New-Item -ItemType Directory -Force -Path $vmOutputDirectory | Out-Null
        $selectionDocument = New-UpdateSelectionDocument -SelectedUpdateKeys $selectedKeys
        $localSelectionPath = Join-Path $vmOutputDirectory 'selection.json'
        $selectionDocument | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $localSelectionPath -Encoding UTF8
        $guestSelectionPath = Join-Path $GuestWorkingDirectory 'selection.json'

        if ($ThrottleLimit -le 1) {
            try {
                $vmAuth = New-GuestAuthentication -Credential $GuestCredentialMap[$record.vmName]
                $cycle = Invoke-VMAgentCycle -VMName $record.vmName -Managers $Managers -GuestAuth $vmAuth -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -VMOutputDirectory $vmOutputDirectory -MaxUpdates $selectedKeys.Count -LocalSelectionPath $localSelectionPath -SelectionPath $guestSelectionPath -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds
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
                VIServers = @($VIServers)
                VIServerCredentialMap = $VIServerCredentialMap
                GuestCredential = $GuestCredentialMap[$record.vmName]
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
        $GuestCredentialMap,
        [string[]]$VIServers,
        [hashtable]$VIServerCredentialMap,
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
        $rebootReason = [string](Get-ObjectPropertyValue -InputObject $target -Path @('rebootReason'))

        if ($ThrottleLimit -le 1) {
            try {
                $vmAuth = New-GuestAuthentication -Credential $GuestCredentialMap[$vmName]
                $rebootResult = Invoke-VMGuestReboot -VMName $vmName -Managers $Managers -GuestAuth $vmAuth
                $resultEntries += [pscustomobject]@{
                    Sequence = $sequence
                    Result = New-RebootActionRecord -VMName $vmName -Action 'Initiated' -ProcessId $rebootResult.ProcessId -RebootReason $rebootReason
                }
            }
            catch {
                $resultEntries += [pscustomobject]@{
                    Sequence = $sequence
                    Result = New-RebootActionRecord -VMName $vmName -Action 'Failed' -ErrorMessage $_.Exception.Message -RebootReason $rebootReason
                }
            }
        }
        else {
            $jobInputs += [pscustomobject]@{
                Sequence = $sequence
                VMName = $vmName
                RebootReason = $rebootReason
                VIServers = @($VIServers)
                VIServerCredentialMap = $VIServerCredentialMap
                GuestCredential = $GuestCredentialMap[$vmName]
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
                    Result = New-RebootActionRecord -VMName $jobResult.VMName -Action 'Failed' -ErrorMessage $jobResult.Error -RebootReason ([string]$jobResult.RebootReason)
                }
                continue
            }

            $resultEntries += [pscustomobject]@{
                Sequence = $jobResult.Sequence
                Result = New-RebootActionRecord -VMName $jobResult.VMName -Action 'Initiated' -ProcessId $jobResult.ProcessId -RebootReason ([string]$jobResult.RebootReason)
            }
        }
    }

    return @($resultEntries | Sort-Object Sequence | ForEach-Object { $_.Result })
}

function Write-PatchingSummary {
    param($ApplyResults)

    Write-Host ''
    Write-Host 'Patching summary'
    Write-Host '----------------'
    foreach ($result in @($ApplyResults)) {
        $status = Get-ApplySummaryStatus -ApplyResult $result
        switch ($status) {
            'Installed' { $label = 'Installed'; $color = 'Green' }
            'InstalledRebootRequired' { $label = 'Installed (reboot required)'; $color = 'Yellow' }
            'Partial' { $label = 'Partially installed (some updates failed - see artifacts)'; $color = 'DarkYellow' }
            'Skipped' { $label = ([string]$result.reason); $color = 'DarkGray' }
            default {
                $reasonText = ([string]$result.reason).Trim()
                $label = if ([string]::IsNullOrWhiteSpace($reasonText)) { 'Failed' } else { ('Failed - {0}' -f $reasonText) }
                $color = 'Red'
            }
        }
        Write-Host ('{0}: {1}' -f $result.vmName, $label) -ForegroundColor $color
    }
}

function Write-FinalReport {
    param(
        $PatchPlanRecords,
        $ApplyResults,
        [string]$CycleOutputDirectory,
        $RebootTargets = $null
    )

    $summaryRows = @(ConvertTo-PatchSummaryRows -PatchPlanRecords $PatchPlanRecords)
    $csvPath = Join-Path $CycleOutputDirectory 'summary.csv'
    $summaryRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    $patched = @($ApplyResults | Where-Object { $_.outcome -eq 'InstallSucceeded' })
    $noUpdates = @($PatchPlanRecords | Where-Object { $_.action -eq 'NoSelectedUpdates' })
    $skipped = @($PatchPlanRecords | Where-Object { $_.action -eq 'Skip' })
    $rebootRequired = if ($null -eq $RebootTargets) { @(Select-RebootRequiredApplyResults -ApplyResults $ApplyResults) } else { @($RebootTargets) }
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
                $rebootReason = [string](Get-ObjectPropertyValue -InputObject $row -Path @('rebootReason'))
                $reasonText = if ([string]::IsNullOrWhiteSpace($rebootReason)) { '' } else { (' ({0})' -f $rebootReason) }
                $lines += ('- {0}{1}' -f $row.vmName, $reasonText)
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
        $GuestCredentialMap,
        [string[]]$VIServers,
        [hashtable]$VIServerCredentialMap,
        [switch]$IgnoreVCenterCertificate,
        [string]$GuestOpsLibPath,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$IdentityHelperPath,
        [string]$GuestWorkingDirectory,
        [int]$TimeoutSeconds,
        [int]$PollSeconds,
        [string]$CycleOutputDirectory,
        [int]$ThrottleLimit,
        $DiscoveryRecords = @()
    )

    $applyResults = @(Invoke-ApplyPhase -PatchPlanRecords $PatchPlanRecords -Managers $Managers -GuestCredentialMap $GuestCredentialMap -VIServers $VIServers -VIServerCredentialMap $VIServerCredentialMap -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $GuestOpsLibPath -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -CycleOutputDirectory $CycleOutputDirectory -ThrottleLimit $ThrottleLimit)
    Write-PatchingSummary -ApplyResults $applyResults

    $rebootActions = @()
    $rebootTargets = @(Select-RebootRequiredApplyResults -ApplyResults $applyResults -DiscoveryRecords $DiscoveryRecords)
    Write-FinalReport -PatchPlanRecords $PatchPlanRecords -ApplyResults $applyResults -CycleOutputDirectory $CycleOutputDirectory -RebootTargets $rebootTargets
    if ($rebootTargets.Count -gt 0) {
        if (Confirm-GuestReboot -RebootTargets $rebootTargets) {
            $rebootActions = @(Invoke-GuestRebootPhase -RebootTargets $rebootTargets -Managers $Managers -GuestCredentialMap $GuestCredentialMap -VIServers $VIServers -VIServerCredentialMap $VIServerCredentialMap -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $GuestOpsLibPath -ThrottleLimit $ThrottleLimit)
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

function Resolve-GuestCredentialMap {
    param(
        [string[]]$TargetNames,
        [pscredential]$OverrideCredential
    )

    $map = @{}

    if ($OverrideCredential) {
        foreach ($name in @($TargetNames)) {
            $map[$name] = $OverrideCredential
        }

        return $map
    }

    foreach ($group in @(Get-GuestCredentialGroups -TargetNames $TargetNames)) {
        if ($group.Kind -eq 'Domain') {
            $message = ('Domain administrator credentials for {0} ({1})' -f $group.Domain, (@($group.Members) -join ', '))
        }
        else {
            $message = ('Local administrator credentials for {0}' -f $group.Key)
        }

        $credential = Get-Credential -Message $message
        foreach ($member in @($group.Members)) {
            $map[$member] = $credential
        }
    }

    return $map
}

function Invoke-DiscoveryPhase {
    param(
        [string[]]$TargetVMNames,
        $Managers,
        $GuestCredentialMap,
        [string[]]$VIServers,
        [hashtable]$VIServerCredentialMap,
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
    $previousSuppressStepMessages = $script:SuppressStepMessages
    $script:SuppressStepMessages = $true
    try {
    foreach ($targetVMName in @($TargetVMNames)) {
        $targetNumber++
        $vmOutputDirectory = Join-Path $CycleOutputDirectory ('{0:D3}-{1}' -f $targetNumber, (Get-SafeFileName -Value $targetVMName))

        if ($ThrottleLimit -le 1) {
            try {
                $vmAuth = New-GuestAuthentication -Credential $GuestCredentialMap[$targetVMName]
                $agentRun = Invoke-VMAgentCycle -VMName $targetVMName -Managers $Managers -GuestAuth $vmAuth -CurlPath $CurlPath -AgentPath $AgentPath -IdentityHelperPath $IdentityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -VMOutputDirectory $vmOutputDirectory -MaxUpdates $MaxUpdates -SearchOnly -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds
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
                VIServers = @($VIServers)
                VIServerCredentialMap = $VIServerCredentialMap
                GuestCredential = $GuestCredentialMap[$targetVMName]
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
                SuppressStepMessages = $true
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
    }
    finally {
        $script:SuppressStepMessages = $previousSuppressStepMessages
    }

    $records = @($recordEntries | Sort-Object Sequence | ForEach-Object { $_.Record })
    $discoveryPath = Join-Path $CycleOutputDirectory 'discovery.json'
    @($records) | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $discoveryPath -Encoding UTF8

    Write-Host ''
    Write-Host 'Discovery summary'
    Write-Host '-----------------'
    foreach ($record in @($records)) {
        $isSuccessful = Test-IsSuccessfulDiscoveryOutcome -Outcome ([string]$record.outcome)
        $hasErrors = (@($record.errors).Count -gt 0)
        $summaryStatus = Get-DiscoverySummaryStatus -IsSuccessful $isSuccessful -AvailableUpdateCount ([int]$record.availableUpdateCount) -HasErrors $hasErrors
        $summaryColor = switch ($summaryStatus) {
            'UpToDate' { 'Green' }
            'UpdatesFound' { 'Yellow' }
            default { 'Red' }
        }
        $pendingRebootBefore = Get-ObjectPropertyValue -InputObject $record -Path @('pendingRebootBefore', 'isPending')
        $rebootText = if ($null -eq $pendingRebootBefore) { '?' } elseif ([bool]$pendingRebootBefore) { 'yes' } else { 'no' }
        Write-Host ('{0}: outcome={1}; updates={2}; reboot={3}; roles={4}' -f $record.vmName, $record.outcome, $record.availableUpdateCount, $rebootText, (Get-RoleFlagText -RoleFlags $record.roleFlags)) -ForegroundColor $summaryColor
        Write-Host ''
    }

    return @($records)
}

$targetVMNames = @(Resolve-VMTargetNames -SingleVMName $VMName -ManyVMNames $VMNames -ListPath $VMListPath)
$resolvedVIServers = @(Split-VIServerInput -InputText $VIServer)
$hasExplicitSelectedUpdateKeys = $PSBoundParameters.ContainsKey('SelectedUpdateKeys')

if ($resolvedVIServers.Count -eq 0) {
    throw 'At least one vCenter is required. Use -VIServer with one or more names separated by semicolons.'
}

if (-not [string]::IsNullOrWhiteSpace($InstallSelection)) {
    throw 'InstallSelection is not supported with grouped update selection. Use SelectedUpdateKeys instead.'
}

if ($hasExplicitSelectedUpdateKeys -and @($SelectedUpdateKeys).Count -eq 0) {
    throw 'SelectedUpdateKeys did not contain any non-empty update keys.'
}

if ([string]::IsNullOrWhiteSpace($VMName)) {
    $VMName = $targetVMNames[0]
}

. (Join-Path $PSScriptRoot 'PatchPlanModel.ps1')
. (Join-Path $PSScriptRoot 'OrchestratorRuntime.ps1')

$curlPath = Assert-LocalPrerequisites -LocalAgentPath $AgentPath

Import-Module VMware.VimAutomation.Core -ErrorAction Stop

Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false | Out-Null

if ($IgnoreVCenterCertificate) {
    Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
}

$connections = @()
$scriptExitCode = 1
$viserverCredentialMap = Resolve-VIServerCredentialMap -VIServers $resolvedVIServers -OverrideCredential $VIServerCredential
$retryVIServerLogin = ($null -eq $VIServerCredential)

try {
    Write-Step -Message ('Connecting to vCenter(s) {0}.' -f ($resolvedVIServers -join ', '))
    $connections = @(Connect-VIServersWithCredentialMap -VIServers $resolvedVIServers -CredentialMap $viserverCredentialMap -RetryOnFailure:$retryVIServerLogin)

    $managers = if ($resolvedVIServers.Count -eq 1) { Get-GuestOpsManagers } else { $null }

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
            $guestCredentialMap = Resolve-GuestCredentialMap -TargetNames @(@($patchPlanRecords) | ForEach-Object { [string]$_.vmName }) -OverrideCredential $GuestCredential
            $scriptExitCode = Invoke-ApplyAndOptionalReboot -PatchPlanRecords $patchPlanRecords -Managers $managers -GuestCredentialMap $guestCredentialMap -VIServers $resolvedVIServers -VIServerCredentialMap $viserverCredentialMap -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $guestOpsLibPath -CurlPath $curlPath -AgentPath $AgentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $runOutputDirectory -ThrottleLimit $ThrottleLimit
        }

        exit $scriptExitCode
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $runOutputDirectory = New-UniqueOutputDirectory -BasePath (Join-Path $LocalOutputDirectory $timestamp)

    $guestCredentialMap = Resolve-GuestCredentialMap -TargetNames $targetVMNames -OverrideCredential $GuestCredential
    $discoveryRecords = Invoke-DiscoveryPhase -TargetVMNames $targetVMNames -Managers $managers -GuestCredentialMap $guestCredentialMap -VIServers $resolvedVIServers -VIServerCredentialMap $viserverCredentialMap -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $guestOpsLibPath -CurlPath $curlPath -AgentPath $AgentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -MaxUpdates $MaxUpdates -TimeoutSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $runOutputDirectory -ThrottleLimit $ThrottleLimit
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
            $scriptExitCode = Invoke-ApplyAndOptionalReboot -PatchPlanRecords $patchPlanRecords -Managers $managers -GuestCredentialMap $guestCredentialMap -VIServers $resolvedVIServers -VIServerCredentialMap $viserverCredentialMap -IgnoreVCenterCertificate:$IgnoreVCenterCertificate -GuestOpsLibPath $guestOpsLibPath -CurlPath $curlPath -AgentPath $AgentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $runOutputDirectory -ThrottleLimit $ThrottleLimit -DiscoveryRecords $discoveryRecords
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
    if ($connections.Count -gt 0 -and -not $KeepConnected) {
        Disconnect-VIServer -Server $connections -Confirm:$false | Out-Null
    }
}

exit $scriptExitCode

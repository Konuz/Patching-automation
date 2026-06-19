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

function Write-Step {
    param([string]$Message)
    Write-Host ('[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Message)
}

function Resolve-VMTargetNames {
    param(
        [string]$SingleVMName,
        [string[]]$ManyVMNames,
        [string]$ListPath
    )

    $targets = @()

    if (-not [string]::IsNullOrWhiteSpace($SingleVMName)) {
        $targets += $SingleVMName
    }

    foreach ($name in @($ManyVMNames)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$name)) {
            $targets += [string]$name
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ListPath)) {
        if (-not (Test-Path -LiteralPath $ListPath -PathType Leaf)) {
            throw ('VM list file not found: {0}' -f $ListPath)
        }

        $targets += @(Get-Content -LiteralPath $ListPath | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_) -and -not ([string]$_).TrimStart().StartsWith('#')
        } | ForEach-Object { ([string]$_).Trim() })
    }

    $uniqueTargets = @()
    $seenTargets = @{}
    foreach ($target in @($targets)) {
        $targetText = ([string]$target).Trim()
        if ([string]::IsNullOrWhiteSpace($targetText)) {
            continue
        }

        if (-not $seenTargets.ContainsKey($targetText)) {
            $seenTargets[$targetText] = $true
            $uniqueTargets += $targetText
        }
    }

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

function New-GuestAuthentication {
    param([pscredential]$Credential)

    $auth = New-Object VMware.Vim.NamePasswordAuthentication
    $auth.Username = $Credential.UserName
    $auth.Password = $Credential.GetNetworkCredential().Password
    $auth.InteractiveSession = $false
    return $auth
}

function Get-ExactVM {
    param([string]$Name)

    $matches = @(Get-VM -Name $Name -ErrorAction Stop | Where-Object { $_.Name -eq $Name })
    if ($matches.Count -eq 0) {
        throw ('VM not found: {0}' -f $Name)
    }

    if ($matches.Count -gt 1) {
        throw ('More than one VM matched exact name: {0}' -f $Name)
    }

    return $matches[0]
}

function Assert-VMReadyForGuestOps {
    param($VM)

    if ($VM.PowerState -ne 'PoweredOn') {
        throw ('VM {0} is not powered on. Current state: {1}' -f $VM.Name, $VM.PowerState)
    }

    $toolsRunningStatus = [string]$VM.ExtensionData.Guest.ToolsRunningStatus
    if ($toolsRunningStatus -ne 'guestToolsRunning') {
        throw ('VMware Tools are not running on {0}. ToolsRunningStatus: {1}' -f $VM.Name, $toolsRunningStatus)
    }
}

function Get-GuestOpsManagers {
    $serviceInstance = Get-View ServiceInstance
    $guestOpsManager = Get-View $serviceInstance.Content.GuestOperationsManager

    return [pscustomobject]@{
        ProcessManager = Get-View $guestOpsManager.ProcessManager
        FileManager = Get-View $guestOpsManager.FileManager
    }
}

function Get-VMHostNameForTransfer {
    param($VMView)

    $hostView = Get-View $VMView.Runtime.Host
    if (-not $hostView.Name) {
        throw 'Unable to resolve ESXi host name for guest file transfer URL.'
    }

    return [string]$hostView.Name
}

function Resolve-GuestFileTransferUrl {
    param(
        [string]$Url,
        [string]$HostName
    )

    if ($Url -match '^https://\*/') {
        return ($Url -replace '^https://\*/', ('https://{0}/' -f $HostName))
    }

    return $Url
}

function Invoke-Curl {
    param(
        [string]$CurlPath,
        [string[]]$Arguments,
        [string]$Description
    )

    Write-Step -Message $Description
    # curl reports failures on stderr; under $ErrorActionPreference='Stop' a native
    # stderr write captured via 2>&1 is promoted to a terminating error before we can
    # inspect $LASTEXITCODE, which would bypass the descriptive throw below. Relax it
    # only around the call and rely on the exit code.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $CurlPath @Arguments 2>&1
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw ("curl.exe failed with exit code {0} during {1}. Output: {2}" -f $exitCode, $Description, (@($output) -join [Environment]::NewLine))
    }
}

function New-GuestDirectory {
    param(
        $ProcessManager,
        $VMView,
        $GuestAuth,
        [string]$DirectoryPath
    )

    $programSpec = New-Object VMware.Vim.GuestProgramSpec
    $programSpec.ProgramPath = 'C:\Windows\System32\cmd.exe'
    $programSpec.Arguments = ('/c if not exist "{0}" mkdir "{0}"' -f $DirectoryPath)

    $processId = $ProcessManager.StartProgramInGuest($VMView.MoRef, $GuestAuth, $programSpec)
    return $processId
}

function Wait-GuestProcess {
    param(
        $ProcessManager,
        $VMView,
        $GuestAuth,
        [long]$ProcessId,
        [int]$TimeoutSeconds,
        [int]$PollSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $processes = @($ProcessManager.ListProcessesInGuest($VMView.MoRef, $GuestAuth, @($ProcessId)))
        if ($processes.Count -gt 0) {
            $process = $processes[0]
            if ($null -ne $process.EndTime -or $null -ne $process.ExitCode) {
                return [pscustomobject]@{
                    Completed = $true
                    ExitCode = $process.ExitCode
                    EndTime = $process.EndTime
                }
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }

    return [pscustomobject]@{
        Completed = $false
        ExitCode = $null
        EndTime = $null
    }
}

function Send-GuestFile {
    param(
        $FileManager,
        $VMView,
        $GuestAuth,
        [string]$HostName,
        [string]$CurlPath,
        [string]$LocalPath,
        [string]$GuestPath
    )

    $file = Get-Item -LiteralPath $LocalPath
    $attributes = New-Object VMware.Vim.GuestFileAttributes
    $url = $FileManager.InitiateFileTransferToGuest($VMView.MoRef, $GuestAuth, $GuestPath, $attributes, [int64]$file.Length, $true)
    $resolvedUrl = Resolve-GuestFileTransferUrl -Url $url -HostName $HostName

    Invoke-Curl -CurlPath $CurlPath -Description ('Uploading {0} to guest path {1}' -f $LocalPath, $GuestPath) -Arguments @(
        # Phase 0b validates GuestOps ESXi transfer URLs; -k is not the target production TLS pattern.
        '-k',
        '--silent',
        '--show-error',
        '--fail',
        '--request',
        'PUT',
        '--upload-file',
        $LocalPath,
        $resolvedUrl
    )
}

function Receive-GuestFile {
    param(
        $FileManager,
        $VMView,
        $GuestAuth,
        [string]$HostName,
        [string]$CurlPath,
        [string]$GuestPath,
        [string]$LocalPath
    )

    $localParent = Split-Path -Parent $LocalPath
    if (-not (Test-Path -LiteralPath $localParent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $localParent | Out-Null
    }

    $transferInfo = $FileManager.InitiateFileTransferFromGuest($VMView.MoRef, $GuestAuth, $GuestPath)
    $resolvedUrl = Resolve-GuestFileTransferUrl -Url $transferInfo.Url -HostName $HostName

    Invoke-Curl -CurlPath $CurlPath -Description ('Downloading guest path {0} to {1}' -f $GuestPath, $LocalPath) -Arguments @(
        # Phase 0b validates GuestOps ESXi transfer URLs; -k is not the target production TLS pattern.
        '-k',
        '--silent',
        '--show-error',
        '--fail',
        '--output',
        $LocalPath,
        $resolvedUrl
    )
}

function Start-GuestAgent {
    param(
        $ProcessManager,
        $VMView,
        $GuestAuth,
        [string]$GuestAgentPath,
        [string]$GuestWorkingDirectory,
        [int]$MaxUpdates,
        [string[]]$SelectedUpdateIds = @(),
        [string[]]$SelectedUpdateKeys = @(),
        [switch]$SearchOnly
    )

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        ('"{0}"' -f $GuestAgentPath),
        '-WorkingDirectory',
        ('"{0}"' -f $GuestWorkingDirectory),
        '-MaxUpdates',
        ([string]$MaxUpdates)
    )

    if ($SearchOnly) {
        $arguments += '-SearchOnly'
    }

    if (@($SelectedUpdateIds).Count -gt 0) {
        $arguments += '-SelectedUpdateIds'
        $arguments += (@($SelectedUpdateIds) -join ',')
    }

    if (@($SelectedUpdateKeys).Count -gt 0) {
        $quotedSelectedUpdateKeys = @($SelectedUpdateKeys | ForEach-Object { '"{0}"' -f (([string]$_) -replace '"', '`"') })
        $arguments += '-SelectedUpdateKeys'
        $arguments += ($quotedSelectedUpdateKeys -join ',')
    }

    $programSpec = New-Object VMware.Vim.GuestProgramSpec
    $programSpec.ProgramPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $programSpec.Arguments = ($arguments -join ' ')
    $programSpec.WorkingDirectory = $GuestWorkingDirectory

    return $ProcessManager.StartProgramInGuest($VMView.MoRef, $GuestAuth, $programSpec)
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

function Get-ObjectPropertyValue {
    param(
        $InputObject,
        [string[]]$Path,
        $DefaultValue = $null
    )

    $current = $InputObject
    foreach ($name in $Path) {
        if ($null -eq $current) {
            return $DefaultValue
        }

        $property = $current.PSObject.Properties[$name]
        if ($null -eq $property) {
            return $DefaultValue
        }

        $current = $property.Value
    }

    return $current
}

function Get-KbArticleText {
    param($Update)

    $kbArticleIds = Get-ObjectPropertyValue -InputObject $Update -Path @('kbArticleIds')
    $kbArticleIdList = @(@($kbArticleIds) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($kbArticleIdList.Count -eq 0) {
        return $null
    }

    return ($kbArticleIdList -join ',')
}

function Show-AvailableUpdates {
    param($Updates)

    Write-Host ''
    Write-Host 'Available updates'
    Write-Host '-----------------'

    foreach ($update in @($Updates)) {
        $updateIndex = [int](Get-ObjectPropertyValue -InputObject $update -Path @('index') -DefaultValue 0)
        $displayNumber = $updateIndex + 1
        Write-Host ('{0}. {1}' -f $displayNumber, (Get-ObjectPropertyValue -InputObject $update -Path @('title')))

        $kbText = Get-KbArticleText -Update $update
        if (-not [string]::IsNullOrWhiteSpace($kbText)) {
            Write-Host ('   KB: {0}' -f $kbText)
        }
    }
}

function Resolve-UpdateSelection {
    param(
        [string]$Selection,
        $Updates
    )

    $updateList = @($Updates)
    if ($updateList.Count -eq 0) {
        return @()
    }

    $selectionText = ([string]$Selection).Trim()
    if ([string]::IsNullOrWhiteSpace($selectionText)) {
        throw 'Select at least one update.'
    }

    if ($selectionText -ieq 'A' -or $selectionText -ieq 'All') {
        return @(0..($updateList.Count - 1))
    }

    $selectedIndexes = New-Object System.Collections.Generic.List[int]
    $seenIndexes = @{}
    foreach ($part in @($selectionText -split '[,\s]+')) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            continue
        }

        $displayNumber = 0
        if (-not [int]::TryParse($part, [ref]$displayNumber)) {
            throw ('Invalid update selection: {0}' -f $part)
        }

        if ($displayNumber -lt 1 -or $displayNumber -gt $updateList.Count) {
            throw ('Update selection {0} is outside the range 1..{1}.' -f $displayNumber, $updateList.Count)
        }

        $selectedIndex = $displayNumber - 1
        if (-not $seenIndexes.ContainsKey($selectedIndex)) {
            $seenIndexes[$selectedIndex] = $true
            [void]$selectedIndexes.Add($selectedIndex)
        }
    }

    if ($selectedIndexes.Count -eq 0) {
        throw 'Select at least one update.'
    }

    return @($selectedIndexes)
}

function Read-UpdateSelection {
    param($Updates)

    while ($true) {
        $selection = Read-Host 'Select updates to install (for example 1,2,3 or A for all)'
        try {
            return Resolve-UpdateSelection -Selection $selection -Updates $Updates
        }
        catch {
            Write-Warning $_.Exception.Message
        }
    }
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

function Invoke-GuestAgentRun {
    param(
        $ProcessManager,
        $FileManager,
        $VMView,
        $GuestAuth,
        [string]$HostName,
        [string]$CurlPath,
        [string]$GuestAgentPath,
        [string]$GuestWorkingDirectory,
        [string]$GuestStatusPath,
        [string]$GuestLogPath,
        [string]$LocalStatusPath,
        [string]$LocalLogPath,
        [int]$MaxUpdates,
        [string[]]$SelectedUpdateIds = @(),
        [string[]]$SelectedUpdateKeys = @(),
        [switch]$SearchOnly,
        [int]$TimeoutSeconds,
        [int]$PollSeconds,
        [string]$Description
    )

    Write-Step -Message $Description
    $agentProcessId = Start-GuestAgent -ProcessManager $ProcessManager -VMView $VMView -GuestAuth $GuestAuth -GuestAgentPath $GuestAgentPath -GuestWorkingDirectory $GuestWorkingDirectory -MaxUpdates $MaxUpdates -SelectedUpdateIds $SelectedUpdateIds -SelectedUpdateKeys $SelectedUpdateKeys -SearchOnly:$SearchOnly
    Write-Step -Message ('Guest agent PID: {0}' -f $agentProcessId)

    $agentResult = Wait-GuestProcess -ProcessManager $ProcessManager -VMView $VMView -GuestAuth $GuestAuth -ProcessId $agentProcessId -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds
    Write-Step -Message ('Guest agent process completed={0}, exitCode={1}.' -f $agentResult.Completed, $agentResult.ExitCode)

    $artifactErrors = @()
    try {
        Receive-GuestFile -FileManager $FileManager -VMView $VMView -GuestAuth $GuestAuth -HostName $HostName -CurlPath $CurlPath -GuestPath $GuestStatusPath -LocalPath $LocalStatusPath
    }
    catch {
        $artifactErrors += ('status.json download failed: {0}' -f $_.Exception.Message)
    }

    try {
        Receive-GuestFile -FileManager $FileManager -VMView $VMView -GuestAuth $GuestAuth -HostName $HostName -CurlPath $CurlPath -GuestPath $GuestLogPath -LocalPath $LocalLogPath
    }
    catch {
        $artifactErrors += ('agent.log download failed: {0}' -f $_.Exception.Message)
    }

    if ($artifactErrors.Count -gt 0) {
        foreach ($artifactError in $artifactErrors) {
            Write-Warning $artifactError
        }
    }

    if (-not (Test-Path -LiteralPath $LocalStatusPath -PathType Leaf)) {
        throw ('status.json was not downloaded. Output directory: {0}' -f (Split-Path -Parent $LocalStatusPath))
    }

    return [pscustomobject]@{
        AgentResult = $agentResult
        Status = Get-Content -LiteralPath $LocalStatusPath -Raw | ConvertFrom-Json
    }
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

function Invoke-VMAgentCycle {
    param(
        [string]$VMName,
        $Managers,
        $GuestAuth,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$GuestWorkingDirectory,
        [string]$VMOutputDirectory,
        [int]$MaxUpdates,
        [string[]]$SelectedUpdateKeys = @(),
        [switch]$SearchOnly,
        [int]$TimeoutSeconds,
        [int]$PollSeconds
    )

    Write-Step -Message ('Resolving VM {0}.' -f $VMName)
    $vm = Get-ExactVM -Name $VMName
    Assert-VMReadyForGuestOps -VM $vm

    $vmView = Get-View $vm.Id
    $hostName = Get-VMHostNameForTransfer -VMView $vmView

    New-Item -ItemType Directory -Force -Path $VMOutputDirectory | Out-Null

    $guestAgentPath = Join-Path $GuestWorkingDirectory 'Run-LocalPatch.ps1'
    $guestStatusPath = Join-Path $GuestWorkingDirectory 'status.json'
    $guestLogPath = Join-Path $GuestWorkingDirectory 'agent.log'
    $localStatusPath = Join-Path $VMOutputDirectory 'status.json'
    $localLogPath = Join-Path $VMOutputDirectory 'agent.log'

    Write-Step -Message ('Creating guest working directory {0}.' -f $GuestWorkingDirectory)
    $mkdirProcessId = New-GuestDirectory -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -DirectoryPath $GuestWorkingDirectory
    $mkdirResult = Wait-GuestProcess -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -ProcessId $mkdirProcessId -TimeoutSeconds 120 -PollSeconds 5
    if (-not $mkdirResult.Completed -or ($null -ne $mkdirResult.ExitCode -and $mkdirResult.ExitCode -ne 0)) {
        throw ('Failed to create guest working directory. Completed={0}; ExitCode={1}' -f $mkdirResult.Completed, $mkdirResult.ExitCode)
    }

    Send-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -LocalPath $AgentPath -GuestPath $guestAgentPath

    $agentRunParams = @{
        ProcessManager = $Managers.ProcessManager
        FileManager = $Managers.FileManager
        VMView = $vmView
        GuestAuth = $GuestAuth
        HostName = $hostName
        CurlPath = $CurlPath
        GuestAgentPath = $guestAgentPath
        GuestWorkingDirectory = $GuestWorkingDirectory
        GuestStatusPath = $guestStatusPath
        GuestLogPath = $guestLogPath
        LocalStatusPath = $localStatusPath
        LocalLogPath = $localLogPath
        TimeoutSeconds = $TimeoutSeconds
        PollSeconds = $PollSeconds
    }

    if ($SearchOnly) {
        return Invoke-GuestAgentRun @agentRunParams -MaxUpdates $MaxUpdates -SearchOnly -Description ('Starting guest WUA search for {0}.' -f $VMName)
    }

    return Invoke-GuestAgentRun @agentRunParams -MaxUpdates $MaxUpdates -SelectedUpdateKeys $SelectedUpdateKeys -Description ('Starting guest WUA install for {0}.' -f $VMName)
}

function Test-ApplyResultsSuccessful {
    param($ApplyResults)

    $installFailures = @($ApplyResults | Where-Object { $_.action -eq 'Install' -and $_.outcome -ne 'InstallSucceeded' })
    $discoveryFailureSkips = @($ApplyResults | Where-Object { $_.action -ne 'Install' -and $_.reason -eq 'Skipped: Discovery failed. Review discovery.json and per-VM agent artifacts.' })

    return ($installFailures.Count -eq 0 -and $discoveryFailureSkips.Count -eq 0)
}

function Invoke-ApplyPhase {
    param(
        $PatchPlanRecords,
        $Managers,
        $GuestAuth,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$GuestWorkingDirectory,
        [int]$TimeoutSeconds,
        [int]$PollSeconds,
        [string]$CycleOutputDirectory
    )

    $results = @()
    $recordNumber = 0

    foreach ($record in @($PatchPlanRecords)) {
        $recordNumber++

        if ($record.action -ne 'Install') {
            $results += [pscustomobject]@{
                vmName = $record.vmName
                action = $record.action
                outcome = 'Skipped'
                installResult = $null
                reason = $record.reason
                rebootRequired = $false
                errors = @()
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

        if ($selectedKeys.Count -eq 0) {
            $reason = 'No selected update keys were available for apply.'
            $results += [pscustomobject]@{
                vmName = $record.vmName
                action = 'Install'
                outcome = 'Failed'
                installResult = $null
                reason = $reason
                rebootRequired = $false
                errors = @($reason)
            }
            continue
        }

        try {
            $cycle = Invoke-VMAgentCycle -VMName $record.vmName -Managers $Managers -GuestAuth $GuestAuth -CurlPath $CurlPath -AgentPath $AgentPath -GuestWorkingDirectory $GuestWorkingDirectory -VMOutputDirectory $vmOutputDirectory -MaxUpdates $selectedKeys.Count -SelectedUpdateKeys $selectedKeys -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds
            $status = $cycle.Status
            $outcome = Get-ObjectPropertyValue -InputObject $status -Path @('outcome')
            $installResult = Get-ObjectPropertyValue -InputObject $status -Path @('installResult', 'result')
            $pendingAfter = [bool](Get-ObjectPropertyValue -InputObject $status -Path @('pendingRebootAfter', 'isPending') -DefaultValue $false)
            $rebootFromInstall = [bool](Get-ObjectPropertyValue -InputObject $status -Path @('installResult', 'rebootRequired') -DefaultValue $false)
            $rebootRequired = ($pendingAfter -or $rebootFromInstall)
            $errors = @(Get-ObjectPropertyValue -InputObject $status -Path @('errors') -DefaultValue @())

            if (-not $cycle.AgentResult.Completed) {
                $reason = 'Apply guest process did not complete.'
                $errors += $reason
                $results += [pscustomobject]@{
                    vmName = $record.vmName
                    action = 'Install'
                    outcome = 'Failed'
                    installResult = $installResult
                    reason = $reason
                    rebootRequired = $rebootRequired
                    errors = @($errors)
                }
                continue
            }

            if ($null -ne $cycle.AgentResult.ExitCode -and [int]$cycle.AgentResult.ExitCode -ne 0) {
                $reason = 'Apply guest process exited with code {0}.' -f $cycle.AgentResult.ExitCode
                $errors += $reason
                $results += [pscustomobject]@{
                    vmName = $record.vmName
                    action = 'Install'
                    outcome = 'Failed'
                    installResult = $installResult
                    reason = $reason
                    rebootRequired = $rebootRequired
                    errors = @($errors)
                }
                continue
            }

            $results += [pscustomobject]@{
                vmName = $record.vmName
                action = 'Install'
                outcome = $outcome
                installResult = $installResult
                reason = ''
                rebootRequired = $rebootRequired
                errors = @($errors)
            }
        }
        catch {
            $results += [pscustomobject]@{
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

    $applyResultsPath = Join-Path $CycleOutputDirectory 'apply-results.json'
    $results | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $applyResultsPath -Encoding UTF8
    return @($results)
}

function Invoke-DiscoveryPhase {
    param(
        [string[]]$TargetVMNames,
        $Managers,
        $GuestAuth,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$GuestWorkingDirectory,
        [int]$MaxUpdates,
        [int]$TimeoutSeconds,
        [int]$PollSeconds,
        [string]$CycleOutputDirectory
    )

    $records = @()
    foreach ($targetVMName in @($TargetVMNames)) {
        $vmOutputDirectory = Join-Path $CycleOutputDirectory ('{0:D3}-{1}' -f ($records.Count + 1), (Get-SafeFileName -Value $targetVMName))

        try {
            $agentRun = Invoke-VMAgentCycle -VMName $targetVMName -Managers $Managers -GuestAuth $GuestAuth -CurlPath $CurlPath -AgentPath $AgentPath -GuestWorkingDirectory $GuestWorkingDirectory -VMOutputDirectory $vmOutputDirectory -MaxUpdates $MaxUpdates -SearchOnly -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds
            $record = New-DiscoveryRecord -VMName $targetVMName -Status $agentRun.Status -OutputDirectory $vmOutputDirectory
            $recordErrors = @($record.errors)

            if (-not (Test-IsSuccessfulDiscoveryOutcome -Outcome $record.outcome)) {
                $recordErrors += ('Discovery returned outcome {0}.' -f $record.outcome)
            }

            if (-not $agentRun.AgentResult.Completed) {
                $finishedAt = Get-ObjectPropertyValue -InputObject $agentRun.Status -Path @('finishedAt')
                if ((Test-IsSuccessfulDiscoveryOutcome -Outcome $record.outcome) -and -not [string]::IsNullOrWhiteSpace([string]$finishedAt)) {
                    Write-Warning ('Discovery guest process result timed out for {0}. status.json has a successful discovery outcome and finishedAt, so the JSON artifact remains the primary discovery result.' -f $targetVMName)
                }
                else {
                    $recordErrors += 'Discovery guest process result timed out and status.json did not contain both a successful discovery outcome and finishedAt.'
                }
            }

            $record.errors = @($recordErrors)
            $records += $record
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Warning ('Discovery failed for {0}: {1}' -f $targetVMName, $errorMessage)
            $records += New-DiscoveryRecord -VMName $targetVMName -Status $null -OutputDirectory $vmOutputDirectory -Errors @($errorMessage)
        }
    }

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

    if ($targetVMNames.Count -gt 1) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $runOutputDirectory = New-UniqueOutputDirectory -BasePath (Join-Path $LocalOutputDirectory $timestamp)

        $discoveryRecords = Invoke-DiscoveryPhase -TargetVMNames $targetVMNames -Managers $managers -GuestAuth $guestAuth -CurlPath $curlPath -AgentPath $AgentPath -GuestWorkingDirectory $GuestWorkingDirectory -MaxUpdates $MaxUpdates -TimeoutSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $runOutputDirectory
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
                $scriptExitCode = 0
            }
            elseif (-not (Confirm-PatchPlan -SkipConfirmation:$SkipConfirmation)) {
                Write-Warning 'Patch plan was not approved. Apply phase skipped.'
                $scriptExitCode = 1
            }
            else {
                $applyResults = @(Invoke-ApplyPhase -PatchPlanRecords $patchPlanRecords -Managers $managers -GuestAuth $guestAuth -CurlPath $curlPath -AgentPath $AgentPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $runOutputDirectory)
                if (Test-ApplyResultsSuccessful -ApplyResults $applyResults) {
                    $scriptExitCode = 0
                }
                else {
                    $scriptExitCode = 1
                }
            }
        }
        elseif ($PlanOnly) {
            $selectedKeysForPlan = @()
            $patchPlanRecords = @(New-PatchPlanRecords -DiscoveryRecords $discoveryRecords -SelectedUpdateKeys $selectedKeysForPlan)
            $patchPlanRecords = @(Update-PatchPlanWithDiscoveryFailures -PatchPlanRecords $patchPlanRecords -DiscoveryRecords $discoveryRecords)
            $patchPlanPath = Join-Path $runOutputDirectory 'patch-plan.json'
            $patchPlanRecords | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $patchPlanPath -Encoding UTF8
            Show-PatchPlan -PatchPlanRecords $patchPlanRecords
            $scriptExitCode = 0
        }
    }
    else {
    Write-Step -Message ('Resolving VM {0}.' -f $VMName)
    $vm = Get-ExactVM -Name $VMName
    Assert-VMReadyForGuestOps -VM $vm

    $vmView = Get-View $vm.Id
    $hostName = Get-VMHostNameForTransfer -VMView $vmView

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeVmName = Get-SafeFileName -Value $VMName
    $runOutputDirectory = Join-Path $LocalOutputDirectory ('{0}-{1}' -f $timestamp, $safeVmName)
    New-Item -ItemType Directory -Force -Path $runOutputDirectory | Out-Null

    $guestAgentPath = Join-Path $GuestWorkingDirectory 'Run-LocalPatch.ps1'
    $guestStatusPath = Join-Path $GuestWorkingDirectory 'status.json'
    $guestLogPath = Join-Path $GuestWorkingDirectory 'agent.log'
    $localStatusPath = Join-Path $runOutputDirectory 'status.json'
    $localLogPath = Join-Path $runOutputDirectory 'agent.log'

    Write-Step -Message ('Creating guest working directory {0}.' -f $GuestWorkingDirectory)
    $mkdirProcessId = New-GuestDirectory -ProcessManager $managers.ProcessManager -VMView $vmView -GuestAuth $guestAuth -DirectoryPath $GuestWorkingDirectory
    $mkdirResult = Wait-GuestProcess -ProcessManager $managers.ProcessManager -VMView $vmView -GuestAuth $guestAuth -ProcessId $mkdirProcessId -TimeoutSeconds 120 -PollSeconds 5
    if (-not $mkdirResult.Completed -or ($null -ne $mkdirResult.ExitCode -and $mkdirResult.ExitCode -ne 0)) {
        throw ('Failed to create guest working directory. Completed={0}; ExitCode={1}' -f $mkdirResult.Completed, $mkdirResult.ExitCode)
    }

    Send-GuestFile -FileManager $managers.FileManager -VMView $vmView -GuestAuth $guestAuth -HostName $hostName -CurlPath $curlPath -LocalPath $AgentPath -GuestPath $guestAgentPath

    $agentRunParams = @{
        ProcessManager = $managers.ProcessManager
        FileManager = $managers.FileManager
        VMView = $vmView
        GuestAuth = $guestAuth
        HostName = $hostName
        CurlPath = $curlPath
        GuestAgentPath = $guestAgentPath
        GuestWorkingDirectory = $GuestWorkingDirectory
        GuestStatusPath = $guestStatusPath
        GuestLogPath = $guestLogPath
        LocalStatusPath = $localStatusPath
        LocalLogPath = $localLogPath
        TimeoutSeconds = ($TimeoutMinutes * 60)
        PollSeconds = $PollSeconds
    }

    $skipSingleVmValidationSummary = $false

    if ($SearchOnly) {
        $agentRun = Invoke-GuestAgentRun @agentRunParams -MaxUpdates $MaxUpdates -SearchOnly -Description 'Starting guest WUA search.'
        $agentResult = $agentRun.AgentResult
        $status = $agentRun.Status
        $discoveryRecords = @(New-DiscoveryRecord -VMName $VMName -Status $status -OutputDirectory $runOutputDirectory)
        $updateGroups = @(New-UpdateGroupRecords -DiscoveryRecords $discoveryRecords | Sort-Object kbText,title)
        Show-UpdateGroups -UpdateGroups $updateGroups

        if ($PlanOnly) {
            $selectedKeysForPlan = @()
            $patchPlanRecords = @(New-PatchPlanRecords -DiscoveryRecords $discoveryRecords -SelectedUpdateKeys $selectedKeysForPlan)
            $patchPlanRecords = @(Update-PatchPlanWithDiscoveryFailures -PatchPlanRecords $patchPlanRecords -DiscoveryRecords $discoveryRecords)
            $patchPlanPath = Join-Path $runOutputDirectory 'patch-plan.json'
            $patchPlanRecords | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $patchPlanPath -Encoding UTF8
            Show-PatchPlan -PatchPlanRecords $patchPlanRecords
            $skipSingleVmValidationSummary = $true
            $scriptExitCode = 0
        }
    }
    else {
        $searchRun = Invoke-GuestAgentRun @agentRunParams -MaxUpdates $MaxUpdates -SearchOnly -Description 'Starting guest WUA search.'
        $searchStatus = $searchRun.Status
        $searchOutcome = Get-ObjectPropertyValue -InputObject $searchStatus -Path @('outcome')
        $searchAvailableUpdateCount = [int](Get-ObjectPropertyValue -InputObject $searchStatus -Path @('availableUpdateCount') -DefaultValue 0)
        $failoverClusterDetected = [bool](Get-ObjectPropertyValue -InputObject $searchStatus -Path @('roleFlags', 'failoverCluster') -DefaultValue $false)
        $discoveryRecords = @(New-DiscoveryRecord -VMName $VMName -Status $searchStatus -OutputDirectory $runOutputDirectory)
        $updateGroups = @(New-UpdateGroupRecords -DiscoveryRecords $discoveryRecords | Sort-Object kbText,title)
        Show-UpdateGroups -UpdateGroups $updateGroups
        $selectedKeysForPlan = @()

        if ($failoverClusterDetected) {
            Write-Warning 'Skipped: Failover Cluster detected. Please update manually one by one.'
            $agentResult = $searchRun.AgentResult
            $status = $searchStatus
        }
        elseif ($searchOutcome -ne 'SearchOnly' -or $searchAvailableUpdateCount -eq 0) {
            $agentResult = $searchRun.AgentResult
            $status = $searchStatus
        }
        else {
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
            $agentResult = $searchRun.AgentResult
            $status = $searchStatus
        }

        $patchPlanRecords = @(New-PatchPlanRecords -DiscoveryRecords $discoveryRecords -SelectedUpdateKeys $selectedKeysForPlan)
        $patchPlanRecords = @(Update-PatchPlanWithDiscoveryFailures -PatchPlanRecords $patchPlanRecords -DiscoveryRecords $discoveryRecords)
        $patchPlanPath = Join-Path $runOutputDirectory 'patch-plan.json'
        $patchPlanRecords | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $patchPlanPath -Encoding UTF8
        Show-PatchPlan -PatchPlanRecords $patchPlanRecords
        $skipSingleVmValidationSummary = $true

        if ($PlanOnly) {
            $scriptExitCode = 0
        }
        elseif (-not (Confirm-PatchPlan -SkipConfirmation:$SkipConfirmation)) {
            Write-Warning 'Patch plan was not approved. Apply phase skipped.'
            $scriptExitCode = 1
        }
        else {
            $applyResults = @(Invoke-ApplyPhase -PatchPlanRecords $patchPlanRecords -Managers $managers -GuestAuth $guestAuth -CurlPath $curlPath -AgentPath $AgentPath -GuestWorkingDirectory $GuestWorkingDirectory -TimeoutSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds -CycleOutputDirectory $runOutputDirectory)
            if (Test-ApplyResultsSuccessful -ApplyResults $applyResults) {
                $scriptExitCode = 0
            }
            else {
                $scriptExitCode = 1
            }
        }
    }

    if (-not $skipSingleVmValidationSummary) {
    $outcome = Get-ObjectPropertyValue -InputObject $status -Path @('outcome')
    $isElevated = Get-ObjectPropertyValue -InputObject $status -Path @('isElevated')
    $availableUpdateCount = Get-ObjectPropertyValue -InputObject $status -Path @('availableUpdateCount')
    $selectedUpdateCount = Get-ObjectPropertyValue -InputObject $status -Path @('selectedUpdateCount')
    $pendingRebootIsPending = Get-ObjectPropertyValue -InputObject $status -Path @('pendingReboot', 'isPending')
    $finishedAt = Get-ObjectPropertyValue -InputObject $status -Path @('finishedAt')

    Write-Host ''
    Write-Host 'Validation summary'
    Write-Host '------------------'
    Write-Host ('VM: {0}' -f $VMName)
    Write-Host ('Output: {0}' -f $runOutputDirectory)
    Write-Host ('Agent outcome: {0}' -f $outcome)
    Write-Host ('Agent elevated: {0}' -f $isElevated)
    Write-Host ('Available updates: {0}' -f $availableUpdateCount)
    Write-Host ('Selected updates: {0}' -f $selectedUpdateCount)
    Write-Host ('Role flags: {0}' -f (Get-RoleFlagText -RoleFlags (Get-ObjectPropertyValue -InputObject $status -Path @('roleFlags'))))
    Write-Host ('Pending reboot: {0}' -f $pendingRebootIsPending)

    $pendingRebootChecks = Get-ObjectPropertyValue -InputObject $status -Path @('pendingReboot', 'checks')
    if ($null -ne $pendingRebootChecks) {
        Write-Host 'Pending reboot checks:'
        foreach ($checkName in @('componentBasedServicing', 'windowsUpdate', 'pendingFileRename')) {
            $checkValue = Get-ObjectPropertyValue -InputObject $pendingRebootChecks -Path @($checkName)
            if ($null -ne $checkValue) {
                Write-Host (' - {0}: {1}' -f $checkName, $checkValue)
            }
        }
    }

    $agentErrors = Get-ObjectPropertyValue -InputObject $status -Path @('errors')
    if ($null -ne $agentErrors -and @($agentErrors).Count -gt 0) {
        Write-Host 'Agent errors:'
        foreach ($agentError in @($agentErrors)) {
            $message = Get-ObjectPropertyValue -InputObject $agentError -Path @('message')
            $type = Get-ObjectPropertyValue -InputObject $agentError -Path @('type')
            $line = Get-ObjectPropertyValue -InputObject $agentError -Path @('line')
            $stage = Get-ObjectPropertyValue -InputObject $agentError -Path @('stage')

            $details = @()
            if (-not [string]::IsNullOrWhiteSpace([string]$stage)) {
                $details += ('stage={0}' -f $stage)
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                $details += ('line={0}' -f $line)
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$type)) {
                $details += ('type={0}' -f $type)
            }

            if ($details.Count -gt 0) {
                Write-Host (' - {0} ({1})' -f $message, ($details -join '; '))
            }
            else {
                Write-Host (' - {0}' -f $message)
            }

            $command = Get-ObjectPropertyValue -InputObject $agentError -Path @('command')
            if (-not [string]::IsNullOrWhiteSpace([string]$command)) {
                Write-Host ('   command: {0}' -f ([string]$command).Trim())
            }
        }
    }

    $updates = Get-ObjectPropertyValue -InputObject $status -Path @('updates')
    if ($null -ne $updates) {
        foreach ($update in @($updates)) {
            if (Get-ObjectPropertyValue -InputObject $update -Path @('selected') -DefaultValue $false) {
                Write-Host ('Selected update: {0}' -f (Get-ObjectPropertyValue -InputObject $update -Path @('title')))
                $kbArticleIds = Get-ObjectPropertyValue -InputObject $update -Path @('kbArticleIds')
                $kbArticleIdList = @(@($kbArticleIds) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                if ($kbArticleIdList.Count -gt 0) {
                    Write-Host ('KB: {0}' -f ($kbArticleIdList -join ','))
                }

                $installResult = Get-ObjectPropertyValue -InputObject $update -Path @('installResult')
                if ($installResult) {
                    Write-Host ('Install result: {0} ({1})' -f (Get-ObjectPropertyValue -InputObject $installResult -Path @('result')), (Get-ObjectPropertyValue -InputObject $installResult -Path @('hResult')))
                }
            }
        }
    }

    $hasSuccessfulOutcome = $outcome -in @('InstallSucceeded', 'NoApplicableUpdates', 'SearchOnly')
    $hasFinishedAt = -not [string]::IsNullOrWhiteSpace([string]$finishedAt)

    if ($hasSuccessfulOutcome) {
        $scriptExitCode = 0
    }
    else {
        $scriptExitCode = 1
    }

    if ($outcome -eq 'NoApplicableUpdates') {
        Write-Warning 'No applicable updates were found. GuestOps and WUA search were validated, but WUA Install() still needs a VM with a pending update.'
    }

    if (-not $agentResult.Completed) {
        if ($hasSuccessfulOutcome -and $hasFinishedAt) {
            Write-Warning 'The GuestOps process result timed out. status.json has a successful outcome and finishedAt, so the JSON artifact remains the primary validation result.'
        }
        else {
            Write-Warning 'The GuestOps process result timed out and status.json did not contain both a successful outcome and finishedAt.'
            $scriptExitCode = 1
        }
    }
    }
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

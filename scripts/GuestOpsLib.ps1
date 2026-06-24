$script:SuppressStepMessages = $false

function Write-Step {
    param([string]$Message)
    if ($script:SuppressStepMessages) { return }
    Write-Host ('[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Message)
}

function New-GuestAuthentication {
    param([pscredential]$Credential)

    $auth = New-Object VMware.Vim.NamePasswordAuthentication
    $auth.Username = $Credential.UserName
    $auth.Password = $Credential.GetNetworkCredential().Password
    $auth.InteractiveSession = $false
    return $auth
}

function Get-VMLookupCandidates {
    param([string]$Name)

    $shortName = ($Name -split '\.', 2)[0]
    if ($Name -eq $shortName) {
        return @($Name)
    }

    return @($shortName, $Name)
}

function Get-ExactVM {
    param([string]$Name)

    $exactMatches = @(Get-VM -Name $Name -ErrorAction Stop | Where-Object { $_.Name -eq $Name })
    if ($exactMatches.Count -eq 0) {
        throw ('VM not found: {0}' -f $Name)
    }

    if ($exactMatches.Count -gt 1) {
        throw ('More than one VM matched exact name: {0}' -f $Name)
    }

    return $exactMatches[0]
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

function New-UpdateSelectionDocument {
    param([string[]]$SelectedUpdateKeys = @())

    $keys = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($selectedUpdateKey in @($SelectedUpdateKeys)) {
        $key = ([string]$selectedUpdateKey).Trim()
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }

        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [void]$keys.Add($key)
        }
    }

    return [pscustomobject]@{
        schemaVersion = 'selection-v1'
        selectedUpdateKeys = @($keys.ToArray())
    }
}

function New-GuestAgentArguments {
    param(
        [string]$GuestAgentPath,
        [string]$GuestWorkingDirectory,
        [int]$MaxUpdates,
        [string[]]$SelectedUpdateKeys = @(),
        [string]$SelectionPath,
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

    if (-not [string]::IsNullOrWhiteSpace($SelectionPath)) {
        $arguments += '-SelectionPath'
        $arguments += ('"{0}"' -f $SelectionPath)
    }

    if (@($SelectedUpdateKeys).Count -gt 0) {
        $quotedSelectedUpdateKeys = @($SelectedUpdateKeys | ForEach-Object { '"{0}"' -f (([string]$_) -replace '"', '`"') })
        $arguments += '-SelectedUpdateKeys'
        $arguments += ($quotedSelectedUpdateKeys -join ',')
    }

    return ($arguments -join ' ')
}

function New-GuestRebootArguments {
    param([string]$Comment = 'PatchingGuestOps reboot after updates')

    $safeComment = ([string]$Comment) -replace '"', "'"
    return ('/r /t 0 /c "{0}"' -f $safeComment)
}

function Start-GuestReboot {
    param(
        $ProcessManager,
        $VMView,
        $GuestAuth,
        [string]$Comment = 'PatchingGuestOps reboot after updates'
    )

    $programSpec = New-Object VMware.Vim.GuestProgramSpec
    $programSpec.ProgramPath = 'C:\Windows\System32\shutdown.exe'
    $programSpec.Arguments = New-GuestRebootArguments -Comment $Comment

    return $ProcessManager.StartProgramInGuest($VMView.MoRef, $GuestAuth, $programSpec)
}

function Start-GuestAgent {
    param(
        $ProcessManager,
        $VMView,
        $GuestAuth,
        [string]$GuestAgentPath,
        [string]$GuestWorkingDirectory,
        [int]$MaxUpdates,
        [string[]]$SelectedUpdateKeys = @(),
        [string]$SelectionPath,
        [switch]$SearchOnly
    )

    $programSpec = New-Object VMware.Vim.GuestProgramSpec
    $programSpec.ProgramPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $programSpec.Arguments = New-GuestAgentArguments -GuestAgentPath $GuestAgentPath -GuestWorkingDirectory $GuestWorkingDirectory -MaxUpdates $MaxUpdates -SelectedUpdateKeys $SelectedUpdateKeys -SelectionPath $SelectionPath -SearchOnly:$SearchOnly
    $programSpec.WorkingDirectory = $GuestWorkingDirectory

    return $ProcessManager.StartProgramInGuest($VMView.MoRef, $GuestAuth, $programSpec)
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
        [string[]]$SelectedUpdateKeys = @(),
        [string]$SelectionPath,
        [switch]$SearchOnly,
        [int]$TimeoutSeconds,
        [int]$PollSeconds,
        [string]$Description
    )

    Write-Step -Message $Description
    $agentProcessId = Start-GuestAgent -ProcessManager $ProcessManager -VMView $VMView -GuestAuth $GuestAuth -GuestAgentPath $GuestAgentPath -GuestWorkingDirectory $GuestWorkingDirectory -MaxUpdates $MaxUpdates -SelectedUpdateKeys $SelectedUpdateKeys -SelectionPath $SelectionPath -SearchOnly:$SearchOnly
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

function Invoke-VMAgentCycle {
    param(
        [string]$VMName,
        $Managers,
        $GuestAuth,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$IdentityHelperPath,
        [string]$GuestWorkingDirectory,
        [string]$VMOutputDirectory,
        [int]$MaxUpdates,
        [string[]]$SelectedUpdateKeys = @(),
        [string]$LocalSelectionPath,
        [string]$SelectionPath,
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

    $guestIdentityHelperPath = Join-Path $GuestWorkingDirectory 'UpdateIdentity.ps1'
    Send-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -LocalPath $IdentityHelperPath -GuestPath $guestIdentityHelperPath

    if (-not [string]::IsNullOrWhiteSpace($LocalSelectionPath) -and -not [string]::IsNullOrWhiteSpace($SelectionPath)) {
        Send-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -LocalPath $LocalSelectionPath -GuestPath $SelectionPath
    }

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

    return Invoke-GuestAgentRun @agentRunParams -MaxUpdates $MaxUpdates -SelectedUpdateKeys $SelectedUpdateKeys -SelectionPath $SelectionPath -Description ('Starting guest WUA install for {0}.' -f $VMName)
}

function Invoke-VMGuestReboot {
    param(
        [string]$VMName,
        $Managers,
        $GuestAuth
    )

    Write-Step -Message ('Resolving VM {0} for guest reboot.' -f $VMName)
    $vm = Get-ExactVM -Name $VMName
    Assert-VMReadyForGuestOps -VM $vm

    $vmView = Get-View $vm.Id
    Write-Step -Message ('Initiating guest reboot for VM {0}.' -f $VMName)
    $rebootProcessId = Start-GuestReboot -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth

    return [pscustomobject]@{
        VMName = $VMName
        ProcessId = $rebootProcessId
    }
}

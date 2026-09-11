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

    return @($Name, $shortName)
}

function Get-ExactVM {
    param([string]$Name)

    foreach ($candidate in @(Get-VMLookupCandidates -Name $Name)) {
        $exactMatches = @(Get-VM -Name $candidate -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $candidate })
        if ($exactMatches.Count -gt 1) {
            throw ('More than one VM matched exact name: {0}' -f $candidate)
        }

        if ($exactMatches.Count -eq 1) {
            # Inventory short names do not identify a domain. Only use that fallback
            # when VMware Tools confirms the FQDN requested by the operator.
            if ($candidate -ne $Name) {
                $guestHostName = [string](Get-ObjectPropertyValue -InputObject $exactMatches[0] -Path @('ExtensionData', 'Guest', 'HostName'))
                if ([string]::IsNullOrWhiteSpace($guestHostName) -or $guestHostName.Trim().TrimEnd('.') -ine $Name.Trim().TrimEnd('.')) {
                    throw ('VM {0} does not have a confirmed guest FQDN matching {1}. VMware Tools reported: {2}' -f $candidate, $Name, $guestHostName)
                }
            }
            return $exactMatches[0]
        }
    }

    throw ('VM not found: {0}' -f $Name)
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

function Get-ViewFromVMClient {
    param(
        $VMView,
        $ManagedObjectReference
    )

    $viewClient = Get-ObjectPropertyValue -InputObject $VMView -Path @('Client')
    if ($null -ne $viewClient -and $null -ne $ManagedObjectReference) {
        return $viewClient.GetView($ManagedObjectReference, $null)
    }

    return Get-View $ManagedObjectReference
}

function Get-GuestOpsManagers {
    param($VMView)

    if ($null -eq $VMView) {
        throw 'VMView is required to resolve Guest Operations managers.'
    }

    $viewClient = Get-ObjectPropertyValue -InputObject $VMView -Path @('Client')
    $serviceContent = Get-ObjectPropertyValue -InputObject $viewClient -Path @('ServiceContent')
    $guestOperationsManager = Get-ObjectPropertyValue -InputObject $serviceContent -Path @('GuestOperationsManager')
    if ($null -eq $viewClient -or $null -eq $serviceContent -or $null -eq $guestOperationsManager) {
        throw 'Unable to resolve Guest Operations managers from the VM client.'
    }
    $guestOpsManager = Get-ViewFromVMClient -VMView $VMView -ManagedObjectReference $guestOperationsManager

    return [pscustomobject]@{
        ProcessManager = Get-ViewFromVMClient -VMView $VMView -ManagedObjectReference $guestOpsManager.ProcessManager
        FileManager = Get-ViewFromVMClient -VMView $VMView -ManagedObjectReference $guestOpsManager.FileManager
    }
}

function Connect-VIServersWithCredentialMap {
    param(
        [string[]]$VIServers,
        [hashtable]$CredentialMap,
        [scriptblock]$ConnectScript,
        [scriptblock]$CredentialPromptScript,
        [scriptblock]$GetExistingConnectionsScript,
        [switch]$RetryOnFailure,
        [switch]$ReuseExisting
    )

    if ($null -eq $CredentialMap) {
        $CredentialMap = @{}
    }

    if ($null -eq $ConnectScript) {
        $ConnectScript = {
            param([string]$Server, [pscredential]$Credential)
            Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
        }
    }

    if ($null -eq $CredentialPromptScript) {
        $CredentialPromptScript = {
            param([string]$Message)
            Get-Credential -Message $Message
        }
    }

    if ($null -eq $GetExistingConnectionsScript) {
        # Go through Get-Variable rather than reading $global:DefaultVIServers directly:
        # under StrictMode reading it before PowerCLI has ever connected is a terminating
        # error, and the offline tests dot-source this file without PowerCLI at all.
        $GetExistingConnectionsScript = {
            return @(Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
        }
    }

    $existingByName = @{}
    if ($ReuseExisting) {
        foreach ($existingConnection in @(& $GetExistingConnectionsScript)) {
            if ($null -eq $existingConnection) {
                continue
            }

            $existingName = ([string](Get-ObjectPropertyValue -InputObject $existingConnection -Path @('Name'))).Trim()
            $isConnected = [bool](Get-ObjectPropertyValue -InputObject $existingConnection -Path @('IsConnected') -DefaultValue $false)
            if ($isConnected -and -not [string]::IsNullOrWhiteSpace($existingName) -and -not $existingByName.ContainsKey($existingName)) {
                $existingByName[$existingName] = $existingConnection
            }
        }
    }

    # Two lists, because they answer different questions: $connections is what this run may
    # use, $openedConnections is what it is allowed to tear down. Disconnecting a session the
    # caller established before invoking us would kill it out from under them.
    $connections = @()
    $openedConnections = @()
    foreach ($server in @($VIServers)) {
        $serverName = ([string]$server).Trim()
        if ([string]::IsNullOrWhiteSpace($serverName)) {
            continue
        }

        $reusedConnection = $null
        foreach ($existingName in @($existingByName.Keys)) {
            if ([string]::Equals($existingName, $serverName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $reusedConnection = $existingByName[$existingName]
                break
            }
        }

        if ($null -ne $reusedConnection) {
            $connections += @($reusedConnection)
            continue
        }

        while ($true) {
            $credential = $null
            if ($CredentialMap.ContainsKey($serverName)) {
                $credential = $CredentialMap[$serverName]
            }

            if ($null -eq $credential) {
                throw ('No vCenter credential is available for {0}.' -f $serverName)
            }

            try {
                $newConnections = @(& $ConnectScript $serverName $credential)
                $connections += $newConnections
                $openedConnections += $newConnections
                break
            }
            catch {
                if (-not $RetryOnFailure) {
                    foreach ($connection in @($openedConnections)) {
                        try {
                            Disconnect-VIServer -Server $connection -Confirm:$false | Out-Null
                        }
                        catch { }
                    }

                    throw
                }

                Write-Warning ('vCenter login failed for {0}: {1}' -f $serverName, $_.Exception.Message)
                $CredentialMap[$serverName] = & $CredentialPromptScript ('Credentials for vCenter {0} (previous login failed)' -f $serverName)
            }
        }
    }

    return [pscustomobject]@{
        Connections = @($connections)
        OpenedConnections = @($openedConnections)
    }
}

function Get-VMHostNameForTransfer {
    param($VMView)

    $hostView = Get-ViewFromVMClient -VMView $VMView -ManagedObjectReference $VMView.Runtime.Host
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

        $remainingSeconds = ($deadline - (Get-Date)).TotalSeconds
        # Ceiling, not Floor: a sub-second remainder would floor to 0 and spin the loop against
        # ListProcessesInGuest without sleeping. The -gt 0 guard below still handles a past deadline.
        $sleepSeconds = [int][math]::Ceiling([math]::Min($PollSeconds, $remainingSeconds))
        if ($sleepSeconds -gt 0) {
            Start-Sleep -Seconds $sleepSeconds
        }
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
        [string]$GuestPath,
        [ValidateRange(1,2147483647)][int]$TimeoutSeconds = 300
    )

    $file = Get-Item -LiteralPath $LocalPath
    $attributes = New-Object VMware.Vim.GuestFileAttributes
    $url = $FileManager.InitiateFileTransferToGuest($VMView.MoRef, $GuestAuth, $GuestPath, $attributes, [int64]$file.Length, $true)
    $resolvedUrl = Resolve-GuestFileTransferUrl -Url $url -HostName $HostName

    $curlArguments = @(
        '--silent',
        '--show-error',
        '--fail',
        '--max-time',
        [string]$TimeoutSeconds,
        '--request',
        'PUT',
        '--upload-file',
        $LocalPath,
        $resolvedUrl
    )
    if ($TimeoutSeconds -gt 0) {
        $curlArguments += @('--max-time', [string]$TimeoutSeconds)
    }
    Invoke-Curl -CurlPath $CurlPath -Description ('Uploading {0} to guest path {1}' -f $LocalPath, $GuestPath) -Arguments $curlArguments
}

function Receive-GuestFile {
    param(
        $FileManager,
        $VMView,
        $GuestAuth,
        [string]$HostName,
        [string]$CurlPath,
        [string]$GuestPath,
        [string]$LocalPath,
        [ValidateRange(1,2147483647)][int]$TimeoutSeconds = 300
    )

    $localParent = Split-Path -Parent $LocalPath
    if (-not (Test-Path -LiteralPath $localParent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $localParent | Out-Null
    }

    $transferInfo = $FileManager.InitiateFileTransferFromGuest($VMView.MoRef, $GuestAuth, $GuestPath)
    $resolvedUrl = Resolve-GuestFileTransferUrl -Url $transferInfo.Url -HostName $HostName

    $curlArguments = @(
        '--silent',
        '--show-error',
        '--fail',
        '--max-time',
        [string]$TimeoutSeconds,
        '--output',
        $LocalPath,
        $resolvedUrl
    )
    if ($TimeoutSeconds -gt 0) {
        $curlArguments += @('--max-time', [string]$TimeoutSeconds)
    }
    Invoke-Curl -CurlPath $CurlPath -Description ('Downloading guest path {0} to {1}' -f $GuestPath, $LocalPath) -Arguments $curlArguments
}

function Get-UniqueTrimmedKeys {
    param([string[]]$Keys = @())

    $result = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($rawKey in @($Keys)) {
        $key = ([string]$rawKey).Trim()
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }

        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [void]$result.Add($key)
        }
    }

    return @($result.ToArray())
}

function New-UpdateSelectionDocument {
    param([string[]]$SelectedUpdateKeys = @())

    return [pscustomobject]@{
        schemaVersion = 'selection-v1'
        selectedUpdateKeys = @(Get-UniqueTrimmedKeys -Keys $SelectedUpdateKeys)
    }
}

function New-GuestAgentArguments {
    param(
        [string]$GuestAgentPath,
        [string]$GuestWorkingDirectory,
        [int]$MaxUpdates,
        [string[]]$SelectedUpdateKeys = @(),
        [string]$SelectionPath,
        [string]$RunId,
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

    if (-not [string]::IsNullOrWhiteSpace($RunId)) {
        $arguments += '-RunId'
        $arguments += ('"{0}"' -f $RunId)
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
        [string]$RunId,
        [switch]$SearchOnly
    )

    $programSpec = New-Object VMware.Vim.GuestProgramSpec
    $programSpec.ProgramPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $programSpec.Arguments = New-GuestAgentArguments -GuestAgentPath $GuestAgentPath -GuestWorkingDirectory $GuestWorkingDirectory -MaxUpdates $MaxUpdates -SelectedUpdateKeys $SelectedUpdateKeys -SelectionPath $SelectionPath -RunId $RunId -SearchOnly:$SearchOnly
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

function Get-GuestOperationErrorKind {
    param($ErrorRecord)

    $transientWebExceptionStatuses = @(
        'ConnectFailure',
        'ConnectionClosed',
        'KeepAliveFailure',
        'NameResolutionFailure',
        'ProxyNameResolutionFailure',
        'ReceiveFailure',
        'SendFailure',
        'Timeout',
        'RequestCanceled',
        'PipelineFailure'
    )

    $sawInvalidCredentials = $false
    $sawPermissionDenied = $false
    $sawTransient = $false
    $current = $ErrorRecord

    for ($depth = 0; $null -ne $current -and $depth -lt 32; $depth++) {
        $candidateQueue = New-Object System.Collections.Queue
        $candidateQueue.Enqueue($current)

        $exceptionProperty = $current.PSObject.Properties['Exception']
        if ($null -ne $exceptionProperty -and $null -ne $exceptionProperty.Value -and $exceptionProperty.Value -ne $current) {
            $candidateQueue.Enqueue($exceptionProperty.Value)
        }

        $candidateCount = 0
        while ($candidateQueue.Count -gt 0 -and $candidateCount -lt 16) {
            $candidate = $candidateQueue.Dequeue()
            $candidateCount++
            if ($null -eq $candidate) {
                continue
            }

            $typeNames = @()
            try {
                $typeNames += [string]$candidate.GetType().FullName
                $typeNames += [string]$candidate.GetType().Name
            }
            catch { }
            try {
                $typeNames += @($candidate.PSTypeNames | ForEach-Object { [string]$_ })
            }
            catch { }

            foreach ($typeName in @($typeNames)) {
                if ([string]::IsNullOrWhiteSpace($typeName)) {
                    continue
                }

                $shortTypeName = ([string]$typeName -split '\.')[-1]
                switch ($shortTypeName) {
                    'InvalidGuestLogin' { $sawInvalidCredentials = $true }
                    'InvalidGuestLoginFault' { $sawInvalidCredentials = $true }
                    'GuestPermissionDenied' { $sawPermissionDenied = $true }
                    'GuestPermissionDeniedFault' { $sawPermissionDenied = $true }
                    'GuestOperationsUnavailable' { $sawTransient = $true }
                    'GuestOperationsUnavailableFault' { $sawTransient = $true }
                    'TaskInProgress' { $sawTransient = $true }
                    'TaskInProgressFault' { $sawTransient = $true }
                    'TimeoutException' { $sawTransient = $true }
                }

                if ($shortTypeName -eq 'WebException') {
                    $statusProperty = $candidate.PSObject.Properties['Status']
                    if ($null -ne $statusProperty -and $transientWebExceptionStatuses -contains ([string]$statusProperty.Value)) {
                        $sawTransient = $true
                    }
                }
            }

            $faultProperty = $candidate.PSObject.Properties['Fault']
            if ($null -ne $faultProperty -and $null -ne $faultProperty.Value -and $faultProperty.Value -ne $candidate) {
                $candidateQueue.Enqueue($faultProperty.Value)
            }
        }

        $baseException = $current
        if ($null -ne $exceptionProperty -and $null -ne $exceptionProperty.Value) {
            $baseException = $exceptionProperty.Value
        }
        $innerProperty = $baseException.PSObject.Properties['InnerException']
        if ($null -eq $innerProperty -or $null -eq $innerProperty.Value -or $innerProperty.Value -eq $baseException) {
            $current = $null
        }
        else {
            $current = $innerProperty.Value
        }
    }

    if ($sawInvalidCredentials) {
        return 'InvalidCredentials'
    }
    if ($sawPermissionDenied) {
        return 'Permanent'
    }
    if ($sawTransient) {
        return 'Transient'
    }

    return 'Permanent'
}

function Test-AgentCycleCompletion {
    param(
        $Status,
        [string]$RunId,
        [string]$Mode
    )

    $statusRunId = [string](Get-ObjectPropertyValue -InputObject $Status -Path @('runId'))
    if ([string]::IsNullOrWhiteSpace($RunId) -or [string]::IsNullOrWhiteSpace($statusRunId) -or -not [string]::Equals($statusRunId, $RunId, [System.StringComparison]::Ordinal)) {
        return $false
    }

    $finishedAt = [string](Get-ObjectPropertyValue -InputObject $Status -Path @('finishedAt'))
    if ([string]::IsNullOrWhiteSpace($finishedAt)) {
        return $false
    }

    try {
        $null = [datetime]::Parse($finishedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    catch {
        return $false
    }

    $outcome = [string](Get-ObjectPropertyValue -InputObject $Status -Path @('outcome'))
    if ([string]::Equals($Mode, 'Apply', [System.StringComparison]::Ordinal)) {
        return ($outcome -in @('InstallSucceeded', 'InstallSucceededWithErrors', 'InstallFailed', 'DownloadFailed', 'NoSelectedUpdates', 'NoApplicableUpdates', 'Failed'))
    }

    if ([string]::Equals($Mode, 'SearchOnly', [System.StringComparison]::Ordinal)) {
        return ($outcome -in @('SearchOnly', 'NoApplicableUpdates', 'Failed'))
    }

    return $false
}

function New-VMAgentCycleHandle {
    param(
        [string]$VMName,
        [string]$RunId,
        $Managers,
        $VMView,
        $GuestAuth,
        [string]$HostName,
        [string]$CurlPath,
        [long]$ProcessId,
        [string]$GuestStatusPath,
        [string]$GuestLogPath,
        [string]$LocalStatusPath,
        [string]$LocalLogPath,
        [int]$TransferTimeoutSeconds = 300,
        [ValidateSet('SearchOnly', 'Apply', IgnoreCase = $false)]
        [string]$Mode = 'Apply'
    )

    return [pscustomobject]@{
        VMName = $VMName
        RunId = $RunId
        Mode = $Mode
        Managers = $Managers
        VMView = $VMView
        GuestAuth = $GuestAuth
        HostName = $HostName
        CurlPath = $CurlPath
        ProcessId = $ProcessId
        GuestStatusPath = $GuestStatusPath
        GuestLogPath = $GuestLogPath
        LocalStatusPath = $LocalStatusPath
        LocalLogPath = $LocalLogPath
        TransferTimeoutSeconds = $TransferTimeoutSeconds
        # Seeded so the property exists before anything reads it: on the fleet timeout path
        # it is read without a poll ever having written it, and StrictMode is unforgiving.
        AgentResult = $null
        Status = $null
    }
}

function Start-VMAgentCycle {
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
        [int]$TransferTimeoutSeconds = 300
    )

    $vm = Get-ExactVM -Name $VMName
    Assert-VMReadyForGuestOps -VM $vm

    $vmView = $vm.ExtensionData
    if ($null -eq $Managers) {
        $Managers = Get-GuestOpsManagers -VMView $vmView
    }
    $hostName = Get-VMHostNameForTransfer -VMView $vmView

    New-Item -ItemType Directory -Force -Path $VMOutputDirectory | Out-Null

    $runId = [guid]::NewGuid().ToString('N')
    $GuestWorkingDirectory = Join-Path $GuestWorkingDirectory $runId
    if (-not [string]::IsNullOrWhiteSpace($LocalSelectionPath)) {
        $SelectionPath = Join-Path $GuestWorkingDirectory 'selection.json'
    }

    $guestAgentPath = Join-Path $GuestWorkingDirectory 'Run-LocalPatch.ps1'
    $guestStatusPath = Join-Path $GuestWorkingDirectory 'status.json'
    $guestLogPath = Join-Path $GuestWorkingDirectory 'agent.log'
    $localStatusPath = Join-Path $VMOutputDirectory 'status.json'
    $localLogPath = Join-Path $VMOutputDirectory 'agent.log'

    $mkdirProcessId = New-GuestDirectory -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -DirectoryPath $GuestWorkingDirectory
    $mkdirResult = Wait-GuestProcess -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -ProcessId $mkdirProcessId -TimeoutSeconds 120 -PollSeconds 5
    if (-not $mkdirResult.Completed -or ($null -ne $mkdirResult.ExitCode -and $mkdirResult.ExitCode -ne 0)) {
        throw ('Failed to create guest working directory. Completed={0}; ExitCode={1}' -f $mkdirResult.Completed, $mkdirResult.ExitCode)
    }

    # Every transfer carries a budget. The fleet puts no job wrapper around these calls, so
    # nothing else bounds a curl hanging against an unresponsive ESXi data plane.
    Send-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -LocalPath $AgentPath -GuestPath $guestAgentPath -TimeoutSeconds $TransferTimeoutSeconds

    $guestIdentityHelperPath = Join-Path $GuestWorkingDirectory 'UpdateIdentity.ps1'
    Send-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -LocalPath $IdentityHelperPath -GuestPath $guestIdentityHelperPath -TimeoutSeconds $TransferTimeoutSeconds

    if (-not [string]::IsNullOrWhiteSpace($LocalSelectionPath) -and -not [string]::IsNullOrWhiteSpace($SelectionPath)) {
        Send-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -LocalPath $LocalSelectionPath -GuestPath $SelectionPath -TimeoutSeconds $TransferTimeoutSeconds
    }

    $agentProcessId = Start-GuestAgent -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -GuestAgentPath $guestAgentPath -GuestWorkingDirectory $GuestWorkingDirectory -MaxUpdates $MaxUpdates -SelectedUpdateKeys $SelectedUpdateKeys -SelectionPath $SelectionPath -RunId $runId -SearchOnly:$SearchOnly

    $mode = if ($SearchOnly) { 'SearchOnly' } else { 'Apply' }
    return New-VMAgentCycleHandle -VMName $VMName -RunId $runId -Mode $mode -Managers $Managers -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -ProcessId $agentProcessId -GuestStatusPath $guestStatusPath -GuestLogPath $guestLogPath -LocalStatusPath $localStatusPath -LocalLogPath $localLogPath -TransferTimeoutSeconds $TransferTimeoutSeconds
}

function Read-VMAgentCycleStatus {
    param($Handle)

    try {
        Receive-GuestFile -FileManager $Handle.Managers.FileManager -VMView $Handle.VMView -GuestAuth $Handle.GuestAuth -HostName $Handle.HostName -CurlPath $Handle.CurlPath -GuestPath $Handle.GuestStatusPath -LocalPath $Handle.LocalStatusPath -TimeoutSeconds $Handle.TransferTimeoutSeconds
    }
    catch {
        # A status file that has not been created yet is still an in-progress cycle. Keep
        # other GuestOps/transfer failures visible to the fleet so its classifier can decide
        # whether the poll is retryable.
        $errorTypeName = [string]$_.Exception.GetType().Name
        if ($errorTypeName -in @('FileNotFoundException', 'GuestFileNotFound', 'FileNotFound')) {
            return $null
        }
        throw
    }

    if (-not (Test-Path -LiteralPath $Handle.LocalStatusPath -PathType Leaf)) {
        return $null
    }

    try {
        $content = Get-Content -LiteralPath $Handle.LocalStatusPath -Raw
        if ([string]::IsNullOrWhiteSpace([string]$content)) {
            return $null
        }
        return ($content | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Test-VMAgentCycleComplete {
    param($Handle)

    $processes = @($Handle.Managers.ProcessManager.ListProcessesInGuest($Handle.VMView.MoRef, $Handle.GuestAuth, @([long]$Handle.ProcessId)))

    if ($processes.Count -eq 0) {
        # vSphere keeps finished process info only for a limited window. An empty list is
        # conclusive only when the current cycle's terminal status is already available;
        # Started, missing, malformed, or foreign status must keep the same agent in flight.
        $status = Read-VMAgentCycleStatus -Handle $Handle
        if ($null -ne $status -and (Test-AgentCycleCompletion -Status $status -RunId ([string]$Handle.RunId) -Mode ([string]$Handle.Mode))) {
            $Handle.Status = $status
            return [pscustomobject]@{ Completed = $false; ExitCode = $null; EndTime = $null }
        }

        return $null
    }

    $process = $processes[0]
    if ($null -ne $process.EndTime -or $null -ne $process.ExitCode) {
        return [pscustomobject]@{ Completed = $true; ExitCode = $process.ExitCode; EndTime = $process.EndTime }
    }

    # A null result means one thing only: the process is still running.
    return $null
}

function Complete-VMAgentCycle {
    param(
        $Handle,
        $AgentResult
    )

    $artifactErrors = @()
    $status = Get-ObjectPropertyValue -InputObject $Handle -Path @('Status')
    if ($null -eq $status) {
        try {
            $status = Read-VMAgentCycleStatus -Handle $Handle
        }
        catch {
            $artifactErrors += ('status.json download failed: {0}' -f $_.Exception.Message)
        }
    }

    try {
        Receive-GuestFile -FileManager $Handle.Managers.FileManager -VMView $Handle.VMView -GuestAuth $Handle.GuestAuth -HostName $Handle.HostName -CurlPath $Handle.CurlPath -GuestPath $Handle.GuestLogPath -LocalPath $Handle.LocalLogPath -TimeoutSeconds $Handle.TransferTimeoutSeconds
    }
    catch {
        $artifactErrors += ('agent.log download failed: {0}' -f $_.Exception.Message)
    }

    if ($artifactErrors.Count -gt 0) {
        foreach ($artifactError in $artifactErrors) {
            Write-Warning $artifactError
        }
    }

    if ($null -eq $status -or -not (Test-Path -LiteralPath $Handle.LocalStatusPath -PathType Leaf)) {
        throw ('status.json was not downloaded. Output directory: {0}' -f (Split-Path -Parent $Handle.LocalStatusPath))
    }

    $statusRunId = [string](Get-ObjectPropertyValue -InputObject $status -Path @('runId'))
    if ([string]::IsNullOrWhiteSpace([string]$Handle.RunId) -or $statusRunId -cne [string]$Handle.RunId) {
        throw 'status.json runId does not match the current agent run.'
    }

    $mode = [string](Get-ObjectPropertyValue -InputObject $Handle -Path @('Mode') -DefaultValue 'Apply')
    $agentCompletionConfirmed = Test-AgentCycleCompletion -Status $status -RunId ([string]$Handle.RunId) -Mode $mode
    $agentCompletionReason = if ($agentCompletionConfirmed) {
        'Agent status confirms terminal completion for the current run.'
    }
    else {
        'Agent status does not confirm terminal completion for the current run.'
    }

    return [pscustomobject]@{
        RunId = $Handle.RunId
        Mode = $mode
        AgentCompletionConfirmed = [bool]$agentCompletionConfirmed
        AgentCompletionReason = $agentCompletionReason
        AgentResult = $AgentResult
        Status = $status
    }
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

    $vmView = $vm.ExtensionData
    if ($null -eq $Managers) {
        $Managers = Get-GuestOpsManagers -VMView $vmView
    }
    Write-Step -Message ('Initiating guest reboot for VM {0}.' -f $VMName)
    $rebootProcessId = Start-GuestReboot -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth

    return [pscustomobject]@{
        VMName = $VMName
        ProcessId = $rebootProcessId
    }
}

function New-GuestBootTimeQueryArguments {
    param(
        [string]$BootTimeHelperPath,
        [string]$OutputPath
    )

    $safeHelperPath = ([string]$BootTimeHelperPath) -replace '"', '`"'
    $safeOutputPath = ([string]$OutputPath) -replace '"', '`"'
    return ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -OutputPath "{1}"' -f $safeHelperPath, $safeOutputPath)
}

function Start-GuestBootTimeQuery {
    param(
        $ProcessManager,
        $VMView,
        $GuestAuth,
        [string]$BootTimeHelperPath,
        [string]$OutputPath
    )

    $programSpec = New-Object VMware.Vim.GuestProgramSpec
    $programSpec.ProgramPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $programSpec.Arguments = New-GuestBootTimeQueryArguments -BootTimeHelperPath $BootTimeHelperPath -OutputPath $OutputPath
    $programSpec.WorkingDirectory = Split-Path -Parent $OutputPath

    return $ProcessManager.StartProgramInGuest($VMView.MoRef, $GuestAuth, $programSpec)
}

function Invoke-VMGuestBootTimeRead {
    param(
        [string]$VMName,
        $Managers,
        $GuestAuth,
        [string]$CurlPath,
        [string]$GuestWorkingDirectory,
        [string]$BootTimeHelperPath,
        [int]$TimeoutSeconds = 120,
        [int]$PollSeconds = 5,
        [switch]$SkipHelperUpload
    )

    $vm = Get-ExactVM -Name $VMName
    Assert-VMReadyForGuestOps -VM $vm

    $vmView = $vm.ExtensionData
    if ($null -eq $Managers) {
        $Managers = Get-GuestOpsManagers -VMView $vmView
    }
    $hostName = Get-VMHostNameForTransfer -VMView $vmView

    $localTempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-boottime-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $localTempDirectory | Out-Null

    try {
        # One helper and one output file per guest, overwritten on every attempt. Naming them per
        # attempt instead would pile up hundreds of files per VM per run inside the guest and never
        # clean them up. A VM is never polled concurrently with itself, so overwriting is safe --
        # but it does mean a dead query would leave the previous attempt's JSON in place, which is
        # why the exit code of the query below is checked and not just its completion.
        $safeVmName = ([string]$VMName) -replace '[^a-zA-Z0-9_.-]', '_'
        $guestHelperPath = Join-Path $GuestWorkingDirectory ('Read-BootTime-{0}.ps1' -f $safeVmName)
        $guestOutputPath = Join-Path $GuestWorkingDirectory ('boot-time-{0}.json' -f $safeVmName)
        $operationDeadline = (Get-Date).AddSeconds([math]::Max(1, $TimeoutSeconds))
        $getRemainingSeconds = {
            $remaining = ($operationDeadline - (Get-Date)).TotalSeconds
            if ($remaining -le 0) {
                throw 'Boot time read timeout budget expired.'
            }
            return [int][math]::Ceiling($remaining)
        }

        # mkdir and the boot-time query both finish in about a second, while $PollSeconds is sized
        # for the WUA agent, which runs for minutes. Polling those two at the caller's cadence would
        # burn most of a poll interval per attempt just noticing that a one-second job is done.
        $shortOperationPollSeconds = [int][math]::Max(1, [math]::Min(5, $PollSeconds))

        # The working directory and the helper survive a reboot - it is the same ProgramData path
        # the WUA agent uses - so re-creating and re-uploading them on every observation round is
        # pure waste on the data plane. The caller drops the switch again after any failed read,
        # so a guest that lost the file self-heals on the next attempt.
        if (-not $SkipHelperUpload) {
            $mkdirProcessId = New-GuestDirectory -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -DirectoryPath $GuestWorkingDirectory
            $mkdirTimeoutSeconds = [int][math]::Min(120, (& $getRemainingSeconds))
            $mkdirResult = Wait-GuestProcess -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -ProcessId $mkdirProcessId -TimeoutSeconds $mkdirTimeoutSeconds -PollSeconds $shortOperationPollSeconds
            if (-not $mkdirResult.Completed -or ($null -ne $mkdirResult.ExitCode -and $mkdirResult.ExitCode -ne 0)) {
                throw ('Failed to create guest working directory. Completed={0}; ExitCode={1}' -f $mkdirResult.Completed, $mkdirResult.ExitCode)
            }

            Send-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -LocalPath $BootTimeHelperPath -GuestPath $guestHelperPath -TimeoutSeconds (& $getRemainingSeconds)
        }

        $queryProcessId = Start-GuestBootTimeQuery -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -BootTimeHelperPath $guestHelperPath -OutputPath $guestOutputPath
        $queryTimeoutSeconds = & $getRemainingSeconds
        $queryResult = Wait-GuestProcess -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -ProcessId $queryProcessId -TimeoutSeconds $queryTimeoutSeconds -PollSeconds $shortOperationPollSeconds
        if (-not $queryResult.Completed) {
            throw ('Boot time query did not complete within {0} seconds.' -f $TimeoutSeconds)
        }
        # A non-zero exit means the helper did not write this attempt's file. With a stable output
        # path the previous attempt's JSON would still be sitting there, so downloading it would
        # silently pass off a stale boot time as a fresh reading.
        if ($null -ne $queryResult.ExitCode -and $queryResult.ExitCode -ne 0) {
            throw ('Boot time query failed inside guest. ExitCode={0}' -f $queryResult.ExitCode)
        }

        $localOutputPath = Join-Path $localTempDirectory 'boot-time.json'
        Receive-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -GuestPath $guestOutputPath -LocalPath $localOutputPath -TimeoutSeconds (& $getRemainingSeconds)

        $parsed = Get-Content -LiteralPath $localOutputPath -Raw | ConvertFrom-Json
        $parsedError = [string](Get-ObjectPropertyValue -InputObject $parsed -Path @('error'))
        if (-not [string]::IsNullOrWhiteSpace($parsedError)) {
            throw ('Boot time query failed inside guest: {0}' -f $parsedError)
        }

        $bootTimeUtcText = [string](Get-ObjectPropertyValue -InputObject $parsed -Path @('bootTimeUtc'))
        $bootTimeUtc = $null
        if (-not [string]::IsNullOrWhiteSpace($bootTimeUtcText)) {
            $bootTimeUtc = [datetime]::Parse($bootTimeUtcText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        }

        $uptimeSecondsValue = Get-ObjectPropertyValue -InputObject $parsed -Path @('uptimeSeconds')
        $uptimeSeconds = if ($null -eq $uptimeSecondsValue) { $null } else { [int]$uptimeSecondsValue }

        return [pscustomobject]@{
            VMName = $VMName
            BootTimeUtc = $bootTimeUtc
            UptimeSeconds = $uptimeSeconds
        }
    }
    finally {
        Remove-Item -LiteralPath $localTempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

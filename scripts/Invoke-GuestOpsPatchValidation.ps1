[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VIServer,

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [pscredential]$VIServerCredential,

    [pscredential]$GuestCredential,

    [string]$AgentPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'guest\Run-LocalPatch.ps1'),

    [string]$GuestWorkingDirectory = 'C:\ProgramData\PatchingGuestOps',

    [string]$LocalOutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out'),

    [int]$MaxUpdates = 1,

    [switch]$SearchOnly,

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
    $output = & $CurlPath @Arguments 2>&1
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

if (-not $VIServerCredential) {
    $VIServerCredential = Get-Credential -Message ('Credentials for vCenter {0}' -f $VIServer)
}

if (-not $GuestCredential) {
    $GuestCredential = Get-Credential -Message ('Local administrator credentials for guest VM {0}' -f $VMName)
}

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

    Write-Step -Message ('Resolving VM {0}.' -f $VMName)
    $vm = Get-ExactVM -Name $VMName
    Assert-VMReadyForGuestOps -VM $vm

    $vmView = Get-View $vm.Id
    $hostName = Get-VMHostNameForTransfer -VMView $vmView
    $guestAuth = New-GuestAuthentication -Credential $GuestCredential
    $managers = Get-GuestOpsManagers

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
    if (-not $mkdirResult.Completed -or $mkdirResult.ExitCode -ne 0) {
        throw ('Failed to create guest working directory. Completed={0}; ExitCode={1}' -f $mkdirResult.Completed, $mkdirResult.ExitCode)
    }

    Send-GuestFile -FileManager $managers.FileManager -VMView $vmView -GuestAuth $guestAuth -HostName $hostName -CurlPath $curlPath -LocalPath $AgentPath -GuestPath $guestAgentPath

    Write-Step -Message 'Starting guest WUA agent.'
    $agentProcessId = Start-GuestAgent -ProcessManager $managers.ProcessManager -VMView $vmView -GuestAuth $guestAuth -GuestAgentPath $guestAgentPath -GuestWorkingDirectory $GuestWorkingDirectory -MaxUpdates $MaxUpdates -SearchOnly:$SearchOnly
    Write-Step -Message ('Guest agent PID: {0}' -f $agentProcessId)

    $agentResult = Wait-GuestProcess -ProcessManager $managers.ProcessManager -VMView $vmView -GuestAuth $guestAuth -ProcessId $agentProcessId -TimeoutSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds
    Write-Step -Message ('Guest agent process completed={0}, exitCode={1}.' -f $agentResult.Completed, $agentResult.ExitCode)

    $artifactErrors = @()
    try {
        Receive-GuestFile -FileManager $managers.FileManager -VMView $vmView -GuestAuth $guestAuth -HostName $hostName -CurlPath $curlPath -GuestPath $guestStatusPath -LocalPath $localStatusPath
    }
    catch {
        $artifactErrors += ('status.json download failed: {0}' -f $_.Exception.Message)
    }

    try {
        Receive-GuestFile -FileManager $managers.FileManager -VMView $vmView -GuestAuth $guestAuth -HostName $hostName -CurlPath $curlPath -GuestPath $guestLogPath -LocalPath $localLogPath
    }
    catch {
        $artifactErrors += ('agent.log download failed: {0}' -f $_.Exception.Message)
    }

    if ($artifactErrors.Count -gt 0) {
        foreach ($artifactError in $artifactErrors) {
            Write-Warning $artifactError
        }
    }

    if (-not (Test-Path -LiteralPath $localStatusPath -PathType Leaf)) {
        throw ('status.json was not downloaded. Output directory: {0}' -f $runOutputDirectory)
    }

    $status = Get-Content -LiteralPath $localStatusPath -Raw | ConvertFrom-Json
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
    Write-Host ('Pending reboot: {0}' -f $pendingRebootIsPending)

    $updates = Get-ObjectPropertyValue -InputObject $status -Path @('updates')
    if ($null -ne $updates) {
        foreach ($update in @($updates)) {
            if (Get-ObjectPropertyValue -InputObject $update -Path @('selected') -DefaultValue $false) {
                Write-Host ('Selected update: {0}' -f (Get-ObjectPropertyValue -InputObject $update -Path @('title')))
                $kbArticleIds = Get-ObjectPropertyValue -InputObject $update -Path @('kbArticleIds')
                if ($kbArticleIds -and $kbArticleIds.Count -gt 0) {
                    Write-Host ('KB: {0}' -f (@($kbArticleIds) -join ','))
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

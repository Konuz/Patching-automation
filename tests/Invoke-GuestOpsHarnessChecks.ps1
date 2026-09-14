[CmdletBinding()]
param(
    [string]$Root
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $Root) {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

# Integration harness for the guest agent cycle: it runs the real Start-/Test-/Complete-
# VMAgentCycle against a fake vSphere. The PowerCLI submodules only have to be installed for
# their .NET types (GuestProgramSpec, GuestFileAttributes, NamePasswordAuthentication) - no
# vCenter, no VM and no ESXi data plane are involved.
#
# This lives outside Invoke-RuntimeChecks.ps1 on purpose: that gate must stay runnable on a
# machine with no PowerCLI at all, and the launcher runs it before every job.

. (Join-Path $Root 'scripts\GuestOpsLib.ps1')
. (Join-Path $Root 'scripts\OrchestratorRuntime.ps1')

$failures = @()

function Add-Failure {
    param([string]$Message)
    $script:failures += $Message
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)

    if ($Actual -ne $Expected) {
        Add-Failure -Message ('{0}. Expected: {1}; Actual: {2}' -f $Message, $Expected, $Actual)
    }
}

# Reading a property off a result this harness did not first prove it has is how a recorded
# failure becomes a crash: Assert-Equal collects, but dereferencing a missing property terminates
# under this script's Stop preference, and the whole run dies before it prints the failure that
# explains why. That is exactly what happened to a fleet result whose Payload was $null because
# the phase preflight had refused the VM - the message naming the refusal was sitting in .Error,
# one assertion above, and was never shown.
#
# So payloads are read through this: it answers with a default and records what the object
# actually carried, which is the one thing worth knowing when a shape is wrong.
function Get-HarnessPayloadValue {
    param($Result, [string]$Name, $DefaultValue = $null, [string]$Context = '')

    $payload = $null
    if ($null -ne $Result) {
        $payloadProperty = $Result.PSObject.Properties['Payload']
        if ($null -ne $payloadProperty) { $payload = $payloadProperty.Value }
    }

    if ($null -eq $payload) {
        $resultError = ''
        if ($null -ne $Result) {
            $errorProperty = $Result.PSObject.Properties['Error']
            if ($null -ne $errorProperty -and $null -ne $errorProperty.Value) { $resultError = [string]$errorProperty.Value }
        }
        $detail = if ([string]::IsNullOrWhiteSpace($resultError)) { 'no error was recorded either' } else { ('the result carried this error instead: ' + $resultError) }
        Add-Failure -Message ('{0}: no payload to read {1} from - {2}' -f $Context, $Name, $detail)
        return $DefaultValue
    }

    $property = $payload.PSObject.Properties[$Name]
    if ($null -eq $property) {
        Add-Failure -Message ('{0}: the payload has no {1}; it carries: {2}' -f $Context, $Name, ((@($payload.PSObject.Properties | ForEach-Object { $_.Name }) -join ', ')))
        return $DefaultValue
    }

    return $property.Value
}

function Assert-Contains {
    param([string]$Text, [string]$Needle, [string]$Message)

    if ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Add-Failure -Message ('{0}. Missing: {1}. Text: {2}' -f $Message, $Needle, $Text)
    }
}

$hasVimTypes = $false
try {
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop 3>$null 4>$null | Out-Null
    $null = New-Object VMware.Vim.GuestProgramSpec
    $hasVimTypes = $true
}
catch {
    $hasVimTypes = $false
}

if (-not $hasVimTypes) {
    Write-Host 'Harness checks skipped: VMware.Vim types are unavailable on this machine.'
    exit 0
}

# --- fake vSphere ---------------------------------------------------------------------

$script:guestState = @{}
$script:curlCalls = @()
$script:capturedCurlArguments = @()

function New-FakeGuest {
    param(
        [string]$VMName,
        [int]$PollsBeforeFinish = 1,
        $ExitCode = 0,
        [string]$StatusJson = '{"outcome":"InstallSucceeded","finishedAt":"2026-08-22T10:00:00.0000000Z"}',
        [switch]$NeverFinishes,
        [switch]$VanishesFromProcessList,
        [switch]$FailsToResolve
    )

    $script:guestState[$VMName] = [pscustomobject]@{
        VMName = $VMName
        NextProcessId = 1000
        PollsRemaining = $PollsBeforeFinish
        ExitCode = $ExitCode
        StatusJson = $StatusJson
        NeverFinishes = [bool]$NeverFinishes
        VanishesFromProcessList = [bool]$VanishesFromProcessList
        TransientPollFailures = 0
        FailsToResolve = [bool]$FailsToResolve
        SetupProcessIds = @{}
        ListProcessCallCount = 0
        StartProgramCallCount = 0
        RunId = ''
        DeletedDirectories = @()
        AgentSpec = $null
        UploadedPaths = @()
        Client = $null
        # The workspace guard runs before the first upload and reports through its exit code.
        WorkspaceSpecs = @()
        WorkspaceExitCode = 0
        WorkspaceNeverFinishes = $false
    }
}

function New-FakeManagers {
    param([string]$VMName)

    $state = $script:guestState[$VMName]

    $processManager = New-Object psobject
    $processManager | Add-Member -MemberType NoteProperty -Name State -Value $state
    $processManager | Add-Member -MemberType ScriptMethod -Name StartProgramInGuest -Value {
        param($MoRef, $Auth, $Spec)
        $this.State.StartProgramCallCount++
        $this.State.NextProcessId++
        # The workspace guard is an -EncodedCommand run that has to finish before anything is
        # uploaded; it reports through its exit code, which this fixture can steer.
        if ([string]$Spec.Arguments -like '*-EncodedCommand*') {
            $this.State.WorkspaceSpecs += $Spec
            $this.State.SetupProcessIds[[string]$this.State.NextProcessId] = [int]$this.State.WorkspaceExitCode
        }
        else {
            $this.State.AgentSpec = $Spec
            $runIdMatch = [regex]::Match([string]$Spec.Arguments, '-RunId "([^"]+)"')
            if ($runIdMatch.Success) {
                $this.State.RunId = $runIdMatch.Groups[1].Value
            }
        }
        return [long]$this.State.NextProcessId
    }
    $processManager | Add-Member -MemberType ScriptMethod -Name ListProcessesInGuest -Value {
        param($MoRef, $Auth, $ProcessIds)
        $this.State.ListProcessCallCount++
        $processId = @($ProcessIds)[0]

        if ($this.State.SetupProcessIds.ContainsKey([string]$processId)) {
            if ($this.State.WorkspaceNeverFinishes) {
                return @([pscustomobject]@{ Pid = $processId; EndTime = $null; ExitCode = $null })
            }
            return @([pscustomobject]@{ Pid = $processId; EndTime = (Get-Date); ExitCode = $this.State.SetupProcessIds[[string]$processId] })
        }

        if ($this.State.VanishesFromProcessList) {
            return @()
        }

        if ($this.State.NeverFinishes) {
            return @([pscustomobject]@{ Pid = $processId; EndTime = $null; ExitCode = $null })
        }

        if ($this.State.TransientPollFailures -gt 0) {
            $this.State.TransientPollFailures--
            throw (New-Object System.TimeoutException -ArgumentList 'synthetic transient poll failure')
        }

        $this.State.PollsRemaining--
        if ($this.State.PollsRemaining -gt 0) {
            return @([pscustomobject]@{ Pid = $processId; EndTime = $null; ExitCode = $null })
        }

        return @([pscustomobject]@{ Pid = $processId; EndTime = (Get-Date); ExitCode = $this.State.ExitCode })
    }

    $fileManager = New-Object psobject
    $fileManager | Add-Member -MemberType NoteProperty -Name State -Value $state
    $fileManager | Add-Member -MemberType ScriptMethod -Name InitiateFileTransferToGuest -Value {
        param($MoRef, $Auth, $GuestPath, $Attributes, $FileSize, $Overwrite)
        $this.State.UploadedPaths += [string]$GuestPath
        return 'https://*/guestFile?id=1&token=upload'
    }
    $fileManager | Add-Member -MemberType ScriptMethod -Name InitiateFileTransferFromGuest -Value {
        param($MoRef, $Auth, $GuestPath)
        return [pscustomobject]@{ Url = 'https://*/guestFile?id=1&token=download'; Size = 10 }
    }
    $fileManager | Add-Member -MemberType ScriptMethod -Name DeleteDirectoryInGuest -Value {
        param($MoRef, $Auth, $DirectoryPath, $Recursive)
        $this.State.DeletedDirectories += [pscustomobject]@{ Path = [string]$DirectoryPath; Recursive = [bool]$Recursive }
    }

    # Get-GuestOpsManagers resolves an AuthManager through the VM's own client, so a fixture
    # without one fails every cycle before it starts. The harness never validates a credential
    # itself - the invalid-login paths are covered offline in Invoke-SafetyRegressionChecks.ps1.
    $authManager = New-Object psobject
    $authManager | Add-Member -MemberType ScriptMethod -Name ValidateCredentialsInGuest -Value {
        param($MoRef, $Auth)
        return $null
    }

    return [pscustomobject]@{ ProcessManager = $processManager; FileManager = $fileManager; AuthManager = $authManager }
}

function New-FakeVMView {
    param([string]$VMName)

    return [pscustomobject]@{
        MoRef = ('vm-{0}' -f $VMName)
        Guest = [pscustomobject]@{ ToolsRunningStatus = 'guestToolsRunning' }
        Client = $script:guestState[$VMName].Client
    }
}

# Every phase must hand its vCenter connections down to the lookup, so the harness supplies a
# scope exactly as a real run would.
$harnessServerScope = @('vc.harness.invalid')

# Shadow the three functions that would otherwise reach a real vCenter or the ESXi data
# plane. Everything else - the cycle split, the transfer plumbing, the process polling and
# the artifact parsing - is the production code.
function Get-ExactVM {
    param([string]$Name, [object[]]$Servers)

    # The real lookup refuses an empty scope; the fake one must too, or the harness would
    # stop proving that every phase hands its connections down.
    if (@($Servers).Count -eq 0) { throw ('Get-ExactVM was called without a connection scope for {0}.' -f $Name) }

    $state = $script:guestState[$Name]
    if ($null -eq $state) {
        throw ('VM not found: {0}' -f $Name)
    }
    if ($state.FailsToResolve) {
        throw ('More than one VM matched exact name: {0}' -f $Name)
    }

    return [pscustomobject]@{
        Name = $Name
        PowerState = 'PoweredOn'
        ExtensionData = New-FakeVMView -VMName $Name
    }
}

function Get-VMHostNameForTransfer {
    param($VMView)
    return 'esxi-fake.invalid'
}

# Kept so one block below can put the real wrapper back and watch what reaches the program.
$script:productionInvokeCurl = (Get-Item Function:\Invoke-Curl).ScriptBlock

function Invoke-Curl {
    param(
        [string]$CurlPath,
        [string[]]$Arguments,
        [string]$Description
    )

    $script:capturedCurlArguments = @($Arguments)
    $script:curlCalls += [pscustomobject]@{ Arguments = @($Arguments); Description = $Description }
    if ($Arguments -contains '--head') { return }

    $outputIndex = [array]::IndexOf(@($Arguments), '--output')
    if ($outputIndex -ge 0) {
        $localPath = @($Arguments)[$outputIndex + 1]
        $vmName = ($Description -split "'")[0]
        # Description is "Downloading guest path X to Y"; recover the guest from the local
        # path instead, which always sits under the per-VM output directory.
        $ownerName = Split-Path -Leaf (Split-Path -Parent $localPath)
        $state = $script:guestState[$ownerName]
        $content = if ($null -eq $state) { '{}' } else { [string]$state.StatusJson }
        if ($null -ne $state -and (Split-Path -Leaf $localPath) -eq 'status.json') {
            $payload = $content | ConvertFrom-Json
            if ($null -eq $payload.PSObject.Properties['runId']) {
                $payload | Add-Member -MemberType NoteProperty -Name runId -Value $state.RunId
            }
            $content = $payload | ConvertTo-Json -Depth 12
        }
        Set-Content -LiteralPath $localPath -Value $content -Encoding UTF8
    }
}

function New-ClientBoundFakeClient {
    param([string]$VMName, $Managers)

    $guestOperationsReference = 'guest-ops-{0}' -f $VMName
    $processReference = 'process-manager-{0}' -f $VMName
    $fileReference = 'file-manager-{0}' -f $VMName
    $authReference = 'auth-manager-{0}' -f $VMName
    $guestOperationsView = [pscustomobject]@{
        ProcessManager = $processReference
        FileManager = $fileReference
        AuthManager = $authReference
    }
    $viewMap = @{
        $guestOperationsReference = $guestOperationsView
        $processReference = $Managers.ProcessManager
        $fileReference = $Managers.FileManager
        $authReference = $Managers.AuthManager
    }
    $client = New-Object psobject
    $client | Add-Member -MemberType NoteProperty -Name ServiceContent -Value ([pscustomobject]@{ GuestOperationsManager = $guestOperationsReference })
    $client | Add-Member -MemberType NoteProperty -Name ViewMap -Value $viewMap
    $client | Add-Member -MemberType ScriptMethod -Name GetView -Value {
        param($Reference, $Session)
        return $this.ViewMap[[string]$Reference]
    }
    return $client
}

function New-HarnessWorkspace {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-harness-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
}

$agentPath = Join-Path $Root 'guest\Run-LocalPatch.ps1'
$identityHelperPath = Join-Path $Root 'guest\UpdateIdentity.ps1'
$guestWorkingDirectory = 'C:\ProgramData\PatchingGuestOps'
$harnessCredential = New-Object System.Management.Automation.PSCredential('CONTOSO\svc', (ConvertTo-SecureString 'password' -AsPlainText -Force))

# --- verified TLS and transfer deadlines ---------------------------------------------

$script:guestState = @{}
$script:curlCalls = @()
$script:capturedCurlArguments = @()
$transferWorkspace = New-HarnessWorkspace
try {
    New-FakeGuest -VMName 'VM-transfer'
    $transferManagers = New-FakeManagers -VMName 'VM-transfer'
    $transferLocalPath = Join-Path $transferWorkspace 'upload.txt'
    Set-Content -LiteralPath $transferLocalPath -Value 'transfer fixture' -Encoding UTF8

    Send-GuestFile -FileManager $transferManagers.FileManager -VMView (New-FakeVMView -VMName 'VM-transfer') -GuestAuth $null -HostName 'esxi-fake.invalid' -CurlPath 'curl.exe' -LocalPath $transferLocalPath -GuestPath 'C:\guest\upload.txt'
    Assert-Equal -Actual ($script:capturedCurlArguments -contains '-k') -Expected $false -Message 'send transfer keeps TLS verification enabled'
    Assert-Equal -Actual ($script:capturedCurlArguments -contains '--insecure') -Expected $false -Message 'send transfer has no alternate insecure flag'
    $limitIndex = [array]::IndexOf($script:capturedCurlArguments, '--max-time')
    Assert-Equal -Actual ($limitIndex -ge 0) -Expected $true -Message 'send transfer always has a deadline'
    Assert-Equal -Actual @($script:capturedCurlArguments | Where-Object { $_ -eq '--max-time' }).Count -Expected 1 -Message 'send transfer specifies its deadline once'
    if ($limitIndex -ge 0) {
        Assert-Equal -Actual $script:capturedCurlArguments[$limitIndex + 1] -Expected '300' -Message 'send transfer uses the default budget'
    }

    $receivedPath = Join-Path $transferWorkspace 'received.json'
    Receive-GuestFile -FileManager $transferManagers.FileManager -VMView (New-FakeVMView -VMName 'VM-transfer') -GuestAuth $null -HostName 'esxi-fake.invalid' -CurlPath 'curl.exe' -GuestPath 'C:\guest\status.json' -LocalPath $receivedPath
    Assert-Equal -Actual ($script:capturedCurlArguments -contains '-k') -Expected $false -Message 'receive transfer keeps TLS verification enabled'
    Assert-Equal -Actual ($script:capturedCurlArguments -contains '--insecure') -Expected $false -Message 'receive transfer has no alternate insecure flag'
    $limitIndex = [array]::IndexOf($script:capturedCurlArguments, '--max-time')
    Assert-Equal -Actual ($limitIndex -ge 0) -Expected $true -Message 'receive transfer always has a deadline'
    Assert-Equal -Actual @($script:capturedCurlArguments | Where-Object { $_ -eq '--max-time' }).Count -Expected 1 -Message 'receive transfer specifies its deadline once'
    if ($limitIndex -ge 0) {
        Assert-Equal -Actual $script:capturedCurlArguments[$limitIndex + 1] -Expected '300' -Message 'receive transfer uses the default budget'
    }
}
finally {
    Remove-Item -LiteralPath $transferWorkspace -Recurse -Force -ErrorAction SilentlyContinue
}

# A failed agent upload must abort before Start-GuestAgent is reached, with no insecure retry.
$failureWorkspace = New-HarnessWorkspace
$originalInvokeCurl = (Get-Item Function:\Invoke-Curl).ScriptBlock
$originalStartGuestAgent = (Get-Item Function:\Start-GuestAgent).ScriptBlock
$script:startGuestAgentCalls = 0
$script:curlFailureCalls = 0
function Invoke-Curl {
    param([string]$CurlPath, [string[]]$Arguments, [string]$Description)
    $script:curlFailureCalls++
    throw 'TLS certificate validation failed; transfer aborted.'
}
function Start-GuestAgent {
    param(
        $ProcessManager, $VMView, $GuestAuth, [string]$GuestAgentPath, [string]$GuestWorkingDirectory,
        [int]$MaxUpdates, [string[]]$SelectedUpdateKeys = @(), [string]$SelectionPath,
        [string]$RunId, [switch]$SearchOnly
    )
    $script:startGuestAgentCalls++
    return & $script:originalStartGuestAgent @PSBoundParameters
}
try {
    $script:guestState = @{}
    New-FakeGuest -VMName 'VM-upload-fails'
    $cycleError = ''
    try {
        Start-VMAgentCycle -VMName 'VM-upload-fails' -Servers $harnessServerScope -Managers (New-FakeManagers -VMName 'VM-upload-fails') -GuestAuth $null -CurlPath 'curl.exe' -AgentPath $agentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $guestWorkingDirectory -VMOutputDirectory (Join-Path $failureWorkspace 'VM-upload-fails') -MaxUpdates 1 | Out-Null
    }
    catch {
        $cycleError = $_.Exception.Message
    }
    Assert-Contains -Text $cycleError -Needle 'TLS certificate validation failed' -Message 'agent upload certificate failure aborts the cycle'
    Assert-Equal -Actual $script:curlFailureCalls -Expected 1 -Message 'agent upload certificate failure is not retried insecurely'
    Assert-Equal -Actual $script:startGuestAgentCalls -Expected 0 -Message 'Start-GuestAgent is not called after agent upload failure'
}
finally {
    Set-Item Function:\Invoke-Curl -Value $originalInvokeCurl
    Set-Item Function:\Start-GuestAgent -Value $originalStartGuestAgent
    Remove-Item -LiteralPath $failureWorkspace -Recurse -Force -ErrorAction SilentlyContinue
}

# The workspace guard, against the real Start-VMAgentCycle. Its point is not that a refused
# directory throws, but that nothing was uploaded and no agent was started on the way to
# throwing: an ordinary user who can write to the tool directory could otherwise replace
# Run-LocalPatch.ps1 between the upload and the start and have it run as the patching account.
$workspaceGuardWorkspace = New-HarnessWorkspace
try {
    $script:guestState = @{}
    New-FakeGuest -VMName 'VM-workspace-ok'
    $okManagers = New-FakeManagers -VMName 'VM-workspace-ok'
    $okHandle = Start-VMAgentCycle -VMName 'VM-workspace-ok' -Servers $harnessServerScope -Managers $okManagers -GuestAuth (New-GuestAuthentication -Credential $harnessCredential) -CurlPath 'curl.exe' -AgentPath $agentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $guestWorkingDirectory -VMOutputDirectory (Join-Path $workspaceGuardWorkspace 'VM-workspace-ok') -MaxUpdates 1
    $okState = $script:guestState['VM-workspace-ok']
    Assert-Equal -Actual @($okState.WorkspaceSpecs).Count -Expected 1 -Message 'harness: the workspace guard runs once per cycle'
    Assert-Equal -Actual ([string]@($okState.WorkspaceSpecs)[0].ProgramPath -like '*powershell.exe') -Expected $true -Message 'harness: the workspace guard runs through powershell.exe'
    Assert-Equal -Actual ([string]@($okState.WorkspaceSpecs)[0].ProgramPath) -Expected 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Message 'harness: the workspace guard uses the exact Windows PowerShell executable path'
    Assert-Contains -Text ([string]@($okState.WorkspaceSpecs)[0].Arguments) -Needle '-EncodedCommand' -Message 'harness: the workspace guard is never uploaded, it is encoded into the command'
    Assert-Equal -Actual ($okState.UploadedPaths.Count -gt 0) -Expected $true -Message 'harness: a secured workspace still uploads the agent'
    Assert-Equal -Actual ($okHandle.GuestCycleDirectory -like ($guestWorkingDirectory + '*')) -Expected $true -Message 'harness: the secured path is the cycle directory'

    # The seal only works if the token the bootstrap wrote is the token the agent is asked to
    # verify. Nothing else couples the two calls, and if they diverge the agent refuses every
    # apply in the field while every offline test still passes.
    $bootstrapArguments = [string]@($okState.WorkspaceSpecs)[0].Arguments
    $encodedIndex = $bootstrapArguments.IndexOf('-EncodedCommand')
    $encodedBootstrap = ($bootstrapArguments.Substring($encodedIndex + '-EncodedCommand'.Length)).Trim().Trim('"')
    $decodedBootstrap = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($encodedBootstrap))
    $sealBase64Match = [regex]::Match($decodedBootstrap, "SealTokenBase64 = '([^']*)'")
    Assert-Equal -Actual $sealBase64Match.Success -Expected $true -Message 'harness: the bootstrap carries a seal token'
    $bootstrapSealToken = ''
    if ($sealBase64Match.Success -and -not [string]::IsNullOrWhiteSpace($sealBase64Match.Groups[1].Value)) {
        $bootstrapSealToken = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($sealBase64Match.Groups[1].Value))
    }
    Assert-Equal -Actual ($bootstrapSealToken.Length -gt 0) -Expected $true -Message 'harness: the bootstrap seals the directory with a non-empty token'

    $agentSealMatch = [regex]::Match([string]$okState.AgentSpec.Arguments, '-WorkspaceSealToken "([^"]+)"')
    Assert-Equal -Actual $agentSealMatch.Success -Expected $true -Message 'harness: the agent is asked to verify the seal'
    if ($agentSealMatch.Success) {
        Assert-Equal -Actual $agentSealMatch.Groups[1].Value -Expected $bootstrapSealToken -Message 'harness: the agent verifies the same seal the bootstrap wrote'
    }

    # The guest reports "an untrusted account may modify this directory" (exit code 12).
    $script:guestState = @{}
    New-FakeGuest -VMName 'VM-workspace-refused'
    $script:guestState['VM-workspace-refused'].WorkspaceExitCode = 12
    $refusedManagers = New-FakeManagers -VMName 'VM-workspace-refused'
    $workspaceError = ''
    try {
        Start-VMAgentCycle -VMName 'VM-workspace-refused' -Servers $harnessServerScope -Managers $refusedManagers -GuestAuth (New-GuestAuthentication -Credential $harnessCredential) -CurlPath 'curl.exe' -AgentPath $agentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $guestWorkingDirectory -VMOutputDirectory (Join-Path $workspaceGuardWorkspace 'VM-workspace-refused') -MaxUpdates 1 | Out-Null
    }
    catch {
        $workspaceError = [string]$_.Exception.Message
    }
    $refusedState = $script:guestState['VM-workspace-refused']
    Assert-Contains -Text $workspaceError -Needle 'cannot be used' -Message 'harness: a refused workspace stops the cycle'
    Assert-Contains -Text $workspaceError -Needle 'Nothing was uploaded' -Message 'harness: the refusal says nothing was uploaded'
    Assert-Equal -Actual @($refusedState.UploadedPaths).Count -Expected 0 -Message 'harness: a refused workspace transfers nothing'
    Assert-Equal -Actual ($null -eq $refusedState.AgentSpec) -Expected $true -Message 'harness: a refused workspace starts no agent'

    # A guest that never answers about the guard is not a pass either.
    $script:guestState = @{}
    New-FakeGuest -VMName 'VM-workspace-silent'
    $script:guestState['VM-workspace-silent'].WorkspaceNeverFinishes = $true
    $silentManagers = New-FakeManagers -VMName 'VM-workspace-silent'
    $silentError = ''
    # Keep the real polling and timeout behavior, with a short deadline for this case only.
    $originalWaitGuestProcess = (Get-Item Function:\Wait-GuestProcess).ScriptBlock
    function Wait-GuestProcess {
        param($ProcessManager, $VMView, $GuestAuth, $ProcessId, $TimeoutSeconds, $PollSeconds)
        & $originalWaitGuestProcess -ProcessManager $ProcessManager -VMView $VMView -GuestAuth $GuestAuth -ProcessId $ProcessId -TimeoutSeconds 1 -PollSeconds 1
    }
    try {
        Start-VMAgentCycle -VMName 'VM-workspace-silent' -Servers $harnessServerScope -Managers $silentManagers -GuestAuth (New-GuestAuthentication -Credential $harnessCredential) -CurlPath 'curl.exe' -AgentPath $agentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $guestWorkingDirectory -VMOutputDirectory (Join-Path $workspaceGuardWorkspace 'VM-workspace-silent') -MaxUpdates 1 | Out-Null
    }
    catch {
        $silentError = [string]$_.Exception.Message
    }
    finally {
        Set-Item Function:\Wait-GuestProcess -Value $originalWaitGuestProcess
    }
    Assert-Contains -Text $silentError -Needle 'could not be secured' -Message 'harness: a workspace check that never finishes fails the cycle'
    Assert-Equal -Actual @($script:guestState['VM-workspace-silent'].UploadedPaths).Count -Expected 0 -Message 'harness: a silent workspace check transfers nothing'
    Assert-Equal -Actual ($null -eq $script:guestState['VM-workspace-silent'].AgentSpec) -Expected $true -Message 'harness: a silent workspace check starts no agent'
}
finally {
    Remove-Item -LiteralPath $workspaceGuardWorkspace -Recurse -Force -ErrorAction SilentlyContinue
}

# The PUT path, asserted at the program-execution boundary with the real Invoke-Curl. The
# runtime gate covers the wrapper, the GET path and the endpoint probe the same way; only the
# upload needs VMware.Vim.GuestFileAttributes, which is why it lives here. curl must ignore
# %APPDATA%\_curlrc and CURL_HOME/.curlrc, or whoever wrote one could hand this tool
# --insecure, a proxy or a different CA store for an ESXi transfer.
$putProbeWorkspace = New-HarnessWorkspace
$originalPutInvokeCurl = (Get-Item Function:\Invoke-Curl).ScriptBlock
try {
    Set-Item Function:\Invoke-Curl -Value $script:productionInvokeCurl
    $putFakeCurlPath = Join-Path $putProbeWorkspace 'fake-curl.ps1'
    $putFakeCurlLogPath = Join-Path $putProbeWorkspace 'arguments.txt'
    $putFakeCurlBody = @'
$args | Set-Content -LiteralPath '__LOG__' -Encoding UTF8
exit 0
'@
    Set-Content -LiteralPath $putFakeCurlPath -Value ($putFakeCurlBody.Replace('__LOG__', $putFakeCurlLogPath)) -Encoding UTF8

    $script:guestState = @{}
    New-FakeGuest -VMName 'VM-put-probe'
    $putSourcePath = Join-Path $putProbeWorkspace 'payload.txt'
    Set-Content -LiteralPath $putSourcePath -Value 'payload' -Encoding UTF8
    $putManagers = New-FakeManagers -VMName 'VM-put-probe'
    Send-GuestFile -FileManager $putManagers.FileManager -VMView (New-FakeVMView -VMName 'VM-put-probe') -GuestAuth $null -HostName 'esxi-fake.invalid' -CurlPath $putFakeCurlPath -LocalPath $putSourcePath -GuestPath 'C:\guest\payload.txt'

    $putArguments = @(Get-Content -LiteralPath $putFakeCurlLogPath)
    Assert-Equal -Actual $putArguments[0] -Expected '--disable' -Message 'harness: an upload reaches curl with --disable first'
    Assert-Equal -Actual @($putArguments | Where-Object { $_ -eq '--disable' }).Count -Expected 1 -Message 'harness: an upload passes --disable once'
    Assert-Equal -Actual ($putArguments -contains '-k') -Expected $false -Message 'harness: an upload never disables TLS verification'
    Assert-Equal -Actual ($putArguments -contains '--insecure') -Expected $false -Message 'harness: an upload has no alternate insecure flag'
    Assert-Equal -Actual ($putArguments -contains '--max-time') -Expected $true -Message 'harness: an upload still carries its deadline'
}
finally {
    Set-Item Function:\Invoke-Curl -Value $originalPutInvokeCurl
    Remove-Item -LiteralPath $putProbeWorkspace -Recurse -Force -ErrorAction SilentlyContinue
}

# The fleet must not reuse a manager obtained from another vCenter client. Extract the
# production fleet adapter because the orchestrator has top-level flow and exits when run.
$orchestratorTokens = $null
$orchestratorParseErrors = $null
$orchestratorAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'scripts\Invoke-GuestOpsPatchValidation.ps1'), [ref]$orchestratorTokens, [ref]$orchestratorParseErrors)
$fleetDefinition = @($orchestratorAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Invoke-GuestAgentFleet' }, $true))[0]
. ([scriptblock]::Create($fleetDefinition.Extent.Text))

# --- VM client isolation -------------------------------------------------------------

$isolationWorkspace = New-HarnessWorkspace
$previousGetViewFunction = Get-Item Function:\Get-View -ErrorAction SilentlyContinue
function Get-View {
    throw 'global ServiceInstance lookup is not allowed in the fleet path.'
}
try {
    $script:guestState = @{}
    $script:curlCalls = @()
    $script:capturedCurlArguments = @()
    New-FakeGuest -VMName 'VM-A' -StatusJson '{"outcome":"SearchOnly","finishedAt":"2026-08-22T10:00:00.0000000Z"}'
    New-FakeGuest -VMName 'VM-B' -StatusJson '{"outcome":"SearchOnly","finishedAt":"2026-08-22T10:00:00.0000000Z"}'
    $managerA = New-FakeManagers -VMName 'VM-A'
    $managerB = New-FakeManagers -VMName 'VM-B'
    $script:guestState['VM-A'].Client = New-ClientBoundFakeClient -VMName 'VM-A' -Managers $managerA
    $script:guestState['VM-B'].Client = New-ClientBoundFakeClient -VMName 'VM-B' -Managers $managerB
    $fleetItem = [pscustomobject]@{
        Sequence = 1
        VMName = 'VM-B'
        VMOutputDirectory = (Join-Path $isolationWorkspace 'VM-B')
        MaxUpdates = 1
        LocalSelectionPath = ''
        SearchOnly = $true
    }
    $isolationResults = @(Invoke-GuestAgentFleet -FleetItems @($fleetItem) -VIServerScope $harnessServerScope -Managers $managerA -GuestCredentialMap @{ 'VM-B' = $harnessCredential } -CurlPath 'curl.exe' -AgentPath $agentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $guestWorkingDirectory -TimeoutSeconds 120 -PollSeconds 1 -MaxInFlight 1)
    Assert-Equal -Actual $isolationResults.Count -Expected 1 -Message 'fleet client isolation returns the VM B result'
    Assert-Equal -Actual (@($isolationResults | Where-Object { $_.Error }).Count) -Expected 0 -Message 'fleet client isolation does not fail VM B'
    Assert-Equal -Actual $script:guestState['VM-A'].StartProgramCallCount -Expected 0 -Message 'fleet client isolation never starts VM A'
    Assert-Equal -Actual $script:guestState['VM-B'].StartProgramCallCount -Expected 2 -Message 'fleet client isolation starts VM B through client B'
    Assert-Equal -Actual $script:guestState['VM-A'].ListProcessCallCount -Expected 0 -Message 'fleet client isolation never polls VM A manager'
    Assert-Equal -Actual ($script:guestState['VM-B'].ListProcessCallCount -gt 0) -Expected $true -Message 'fleet client isolation polls VM B manager'
}
finally {
    if ($null -eq $previousGetViewFunction) {
        Remove-Item Function:\Get-View -ErrorAction SilentlyContinue
    }
    else {
        Set-Item Function:\Get-View -Value $previousGetViewFunction.ScriptBlock
    }
    Remove-Item -LiteralPath $isolationWorkspace -Recurse -Force -ErrorAction SilentlyContinue
}

function New-HarnessFleetScripts {
    param([string]$Workspace, [int]$TransferTimeoutSeconds = 300)

    # Mirrors Invoke-GuestAgentFleet in the orchestrator. The orchestrator ends in exit so it
    # cannot be dot-sourced; the functions being exercised below are the real ones.
    #
    # GetNewClosure is required here and only here: these scriptblocks outlive this function,
    # so $Workspace and $TransferTimeoutSeconds would be gone by the time the fleet runs them.
    # The production ones are inline arguments to a call made from within the frame that owns
    # their variables, so they resolve dynamically and need no closure.
    return [pscustomobject]@{
        StartScript = {
            param($Item)
            $auth = New-GuestAuthentication -Credential $Item.Credential
            return Start-VMAgentCycle -VMName $Item.VMName -Servers $harnessServerScope -Managers (New-FakeManagers -VMName $Item.VMName) -GuestAuth $auth -CurlPath 'curl.exe' -AgentPath $agentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $guestWorkingDirectory -VMOutputDirectory (Join-Path $Workspace $Item.VMName) -MaxUpdates 1 -SearchOnly:([bool]$Item.SearchOnly) -TransferTimeoutSeconds $TransferTimeoutSeconds
        }.GetNewClosure()
        PollScript = {
            param($Handle)
            $agentResult = Test-VMAgentCycleComplete -Handle $Handle
            $Handle.AgentResult = $agentResult
            return ($null -ne $agentResult)
        }
        CompleteScript = {
            param($Handle)
            return Complete-VMAgentCycle -Handle $Handle -AgentResult $Handle.AgentResult
        }
    }
}

function New-HarnessItem {
    param([int]$Sequence, [string]$VMName, [bool]$SearchOnly = $true)

    return [pscustomobject]@{
        Sequence = $Sequence
        VMName = $VMName
        SearchOnly = $SearchOnly
        Credential = $harnessCredential
    }
}

# --- a healthy fleet ------------------------------------------------------------------

$script:guestState = @{}
$script:curlCalls = @()
$workspace = New-HarnessWorkspace
try {
    New-FakeGuest -VMName 'VM01' -PollsBeforeFinish 2 -StatusJson '{"outcome":"SearchOnly","finishedAt":"2026-08-22T10:00:00.0000000Z"}'
    New-FakeGuest -VMName 'VM02' -PollsBeforeFinish 1 -StatusJson '{"outcome":"SearchOnly","finishedAt":"2026-08-22T10:00:00.0000000Z"}'
    New-FakeGuest -VMName 'VM03' -PollsBeforeFinish 3 -StatusJson '{"outcome":"SearchOnly","finishedAt":"2026-08-22T10:00:00.0000000Z"}'

    $scripts = New-HarnessFleetScripts -Workspace $workspace
    $items = @(
        (New-HarnessItem -Sequence 1 -VMName 'VM01'),
        (New-HarnessItem -Sequence 2 -VMName 'VM02'),
        (New-HarnessItem -Sequence 3 -VMName 'VM03')
    )

    $results = @(Invoke-InProcessAgentFleet -Items $items -MaxInFlight 3 -PollSeconds 1 -ItemTimeoutSeconds 120 -StartScript $scripts.StartScript -PollScript $scripts.PollScript -CompleteScript $scripts.CompleteScript -SleepScript { param([int]$Seconds) })

    Assert-Equal -Actual $results.Count -Expected 3 -Message 'harness: fleet returns one result per guest'
    Assert-Equal -Actual (@($results | Where-Object { $_.Error }).Count) -Expected 0 -Message 'harness: a healthy fleet reports no errors'
    Assert-Equal -Actual ([string]@($results | Where-Object { $_.VMName -eq 'VM01' })[0].Payload.Status.outcome) -Expected 'SearchOnly' -Message 'harness: status.json is downloaded and parsed'
    Assert-Equal -Actual ([bool]@($results | Where-Object { $_.VMName -eq 'VM01' })[0].Payload.AgentResult.Completed) -Expected $true -Message 'harness: a finished guest reports a completed process result'
    Assert-Equal -Actual ([string]@($results | Where-Object { $_.VMName -eq 'VM01' })[0].Payload.Mode) -Expected 'SearchOnly' -Message 'harness: search-only cycles carry their mode'
    Assert-Equal -Actual ([bool](Get-HarnessPayloadValue -Result @($results | Where-Object { $_.VMName -eq 'VM01' })[0] -Name 'AgentCompletionConfirmed' -DefaultValue $false -Context 'harness: healthy fleet')) -Expected $true -Message 'harness: terminal search status confirms completion'
    Assert-Equal -Actual ([string]::IsNullOrWhiteSpace([string]@($results | Where-Object { $_.VMName -eq 'VM01' })[0].Payload.AgentCompletionReason)) -Expected $false -Message 'harness: completion confirmation carries a reason'
    Assert-Equal -Actual (Test-Path -LiteralPath (Join-Path (Join-Path $workspace 'VM01') 'status.json')) -Expected $true -Message 'harness: status.json lands in the per-VM output directory'

    # The orchestrator no longer computes a guest selection path, because Start-VMAgentCycle
    # overwrites it whenever LocalSelectionPath is supplied - which it always was. The parameter
    # itself still has a caller contract: without LocalSelectionPath, the supplied path is used
    # verbatim and nothing is uploaded to it.
    New-FakeGuest -VMName 'VM-selection' -PollsBeforeFinish 1 -StatusJson '{"outcome":"SearchOnly","finishedAt":"2026-08-22T10:00:00.0000000Z"}'
    $selectionManagers = New-FakeManagers -VMName 'VM-selection'
    $script:guestState['VM-selection'].Client = New-ClientBoundFakeClient -VMName 'VM-selection' -Managers $selectionManagers
    $suppliedSelectionPath = 'C:\synthetic\preset-selection.json'
    $selectionHandle = Start-VMAgentCycle -VMName 'VM-selection' -Servers $harnessServerScope -Managers $selectionManagers -GuestAuth (New-GuestAuthentication -Credential $harnessCredential) -CurlPath 'curl.exe' -AgentPath $agentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $guestWorkingDirectory -VMOutputDirectory (Join-Path $workspace 'VM-selection') -MaxUpdates 1 -SelectionPath $suppliedSelectionPath
    Assert-Equal -Actual ($null -ne $selectionHandle) -Expected $true -Message 'harness: a cycle without a local selection still starts'
    $selectionArguments = [string]$script:guestState['VM-selection'].AgentSpec.Arguments
    Assert-Equal -Actual ($selectionArguments.Contains($suppliedSelectionPath)) -Expected $true -Message 'harness: without LocalSelectionPath the supplied guest selection path is used verbatim'
    Assert-Equal -Actual (@($script:guestState['VM-selection'].UploadedPaths | Where-Object { ([string]$_).EndsWith('selection.json') }).Count) -Expected 0 -Message 'harness: a supplied selection path is not uploaded, only referenced'

    # The whole cleanup contract against the real Start-VMAgentCycle, which is the only place
    # that builds the directory pair the removal validates against.
    Assert-Equal -Actual ([string]@($results | Where-Object { $_.VMName -eq 'VM01' })[0].Payload.CleanupStatus) -Expected 'Removed' -Message 'harness: a completed cycle removes its guest directory'
    $vm01Deletes = @($script:guestState['VM01'].DeletedDirectories)
    Assert-Equal -Actual $vm01Deletes.Count -Expected 1 -Message 'harness: a completed cycle deletes exactly once'
    Assert-Equal -Actual $vm01Deletes[0].Recursive -Expected $true -Message 'harness: the cycle directory is removed recursively'
    Assert-Equal -Actual ([System.IO.Path]::GetFileName($vm01Deletes[0].Path)) -Expected $script:guestState['VM01'].RunId -Message 'harness: the directory removed is the one this run created'
    Assert-Equal -Actual ([System.IO.Path]::GetDirectoryName($vm01Deletes[0].Path)) -Expected $guestWorkingDirectory -Message 'harness: the working directory itself is never the delete target'

    # Fleet-wide, not per VM: every guest must have removed its own directory and nobody else's.
    # VM-name collisions are a tested concern elsewhere in this repo, and a cleanup that crossed
    # VMs would delete a directory on a machine that is still patching.
    $fleetDeletes = @('VM01', 'VM02', 'VM03') | ForEach-Object {
        [pscustomobject]@{ VMName = $_; Deletes = @($script:guestState[$_].DeletedDirectories) }
    }
    Assert-Equal -Actual (@($fleetDeletes | Where-Object { $_.Deletes.Count -ne 1 }).Count) -Expected 0 -Message 'harness: every completed cycle in the fleet deletes exactly its own directory once'
    $crossVmDeletes = @($fleetDeletes | Where-Object { [System.IO.Path]::GetFileName($_.Deletes[0].Path) -ne $script:guestState[$_.VMName].RunId })
    Assert-Equal -Actual $crossVmDeletes.Count -Expected 0 -Message 'harness: no guest deletes a directory belonging to another run'
    $distinctDeletedPaths = @(@($fleetDeletes | ForEach-Object { $_.Deletes[0].Path }) | Select-Object -Unique)
    Assert-Equal -Actual $distinctDeletedPaths.Count -Expected 3 -Message 'harness: the three guests delete three distinct directories'

    # Every VM must have been started before the first guest was polled for its agent.
    Assert-Equal -Actual $script:guestState['VM03'].StartProgramCallCount -Expected 2 -Message 'harness: each guest gets one mkdir and one agent start'

    # The whole point of the poll/complete split: vSphere is asked once per round, not twice.
    # A second question can come back as "ended, exit code lost" and be read as a failure.
    $vm02Listens = $script:guestState['VM02'].ListProcessCallCount
    Assert-Equal -Actual $vm02Listens -Expected 2 -Message 'harness: one mkdir wait plus one agent poll, with no extra question from the completion script'

    # Transfer budgets: nothing else bounds a hung curl now that the job wrapper is gone.
    $transfersWithoutTimeout = @($script:curlCalls | Where-Object { @($_.Arguments) -notcontains '--max-time' })
    Assert-Equal -Actual $transfersWithoutTimeout.Count -Expected 0 -Message 'harness: every guest transfer carries --max-time'
    Assert-Equal -Actual (@($script:curlCalls).Count -gt 0) -Expected $true -Message 'harness: transfers actually happened'
}
finally {
    Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
}

# --- a transient poll error must not start a second agent ----------------------------

$script:guestState = @{}
$script:curlCalls = @()
$workspace = New-HarnessWorkspace
try {
    New-FakeGuest -VMName 'VM-retry' -PollsBeforeFinish 1 -StatusJson '{"outcome":"SearchOnly","finishedAt":"2026-08-22T10:00:00.0000000Z"}'
    $retryManagers = New-FakeManagers -VMName 'VM-retry'
    $script:guestState['VM-retry'].TransientPollFailures = 1
    $script:guestState['VM-retry'].Client = New-ClientBoundFakeClient -VMName 'VM-retry' -Managers $retryManagers
    $retryItem = [pscustomobject]@{
        Sequence = 1
        VMName = 'VM-retry'
        VMOutputDirectory = (Join-Path $workspace 'VM-retry')
        MaxUpdates = 1
        LocalSelectionPath = ''
        SearchOnly = $true
    }

    $retryResults = @(Invoke-GuestAgentFleet -FleetItems @($retryItem) -VIServerScope $harnessServerScope -Managers $retryManagers -GuestCredentialMap @{ 'VM-retry' = $harnessCredential } -CurlPath 'curl.exe' -AgentPath $agentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $guestWorkingDirectory -TimeoutSeconds 120 -PollSeconds 1 -MaxInFlight 1)
    Assert-Equal $retryResults.Count 1 'harness: transient poll recovery returns one result'
    Assert-Equal ([string]$retryResults[0].Error) '' 'harness: transient poll recovery has no error'
    Assert-Equal $script:guestState['VM-retry'].StartProgramCallCount 2 'harness: transient poll recovery starts mkdir and the agent only once'
    Assert-Equal $script:guestState['VM-retry'].ListProcessCallCount 3 'harness: transient poll recovery asks for the process once per poll plus mkdir'
    Assert-Equal (@(Get-HarnessPayloadValue -Result $retryResults[0] -Name 'AgentCompletionConfirmed' -DefaultValue $false -Context 'harness: transient poll recovery') -contains $true) $true 'harness: transient poll recovery retains terminal completion'
}
finally {
    Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
}

# --- a timeout must still harvest the artifacts ---------------------------------------

$script:guestState = @{}
$script:curlCalls = @()
$workspace = New-HarnessWorkspace
try {
    New-FakeGuest -VMName 'VM10' -NeverFinishes -StatusJson '{"outcome":"InstallSucceeded","finishedAt":"2026-08-22T10:00:00.0000000Z","installResult":{"result":"Succeeded","rebootRequired":true},"pendingRebootAfter":{"isPending":true}}'

    $scripts = New-HarnessFleetScripts -Workspace $workspace
    $results = @(Invoke-InProcessAgentFleet -Items @((New-HarnessItem -Sequence 1 -VMName 'VM10' -SearchOnly $false)) -MaxInFlight 1 -PollSeconds 1 -ItemTimeoutSeconds 0 -StartScript $scripts.StartScript -PollScript $scripts.PollScript -CompleteScript $scripts.CompleteScript -SleepScript { param([int]$Seconds) })

    Assert-Equal -Actual $results.Count -Expected 1 -Message 'harness: a timed out guest still yields a result'
    Assert-Contains -Text ([string]$results[0].Error) -Needle 'timed out' -Message 'harness: the timeout is reported'
    Assert-Equal -Actual ($null -ne $results[0].Payload) -Expected $true -Message 'harness: a timeout still harvests the payload'
    Assert-Equal -Actual (Test-Path -LiteralPath (Join-Path (Join-Path $workspace 'VM10') 'status.json')) -Expected $true -Message 'harness: a timeout still leaves status.json on disk for diagnosis'

    # The end of the chain: a guest that really did finish must not be reported as a total
    # failure just because vSphere never handed back a process result.
    $applyResult = New-ApplyResultFromCycle -VMName 'VM10' -Cycle $results[0].Payload 3>$null
    Assert-Equal -Actual $applyResult.outcome -Expected 'InstallSucceeded' -Message 'harness: a harvested terminal status.json outweighs the lost process result'
    Assert-Equal -Actual $applyResult.rebootRequired -Expected $true -Message 'harness: reboot requirement survives the lost process result'
    Assert-Equal -Actual $applyResult.agentCompletionConfirmed -Expected $true -Message 'harness: apply result retains terminal completion confirmation'
}
finally {
    Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
}

# --- a guest that dropped out of the process list --------------------------------------

$script:guestState = @{}
$script:curlCalls = @()
$workspace = New-HarnessWorkspace
try {
    New-FakeGuest -VMName 'VM20' -VanishesFromProcessList

    $scripts = New-HarnessFleetScripts -Workspace $workspace
    $results = @(Invoke-InProcessAgentFleet -Items @((New-HarnessItem -Sequence 1 -VMName 'VM20' -SearchOnly $false)) -MaxInFlight 1 -PollSeconds 1 -ItemTimeoutSeconds 120 -StartScript $scripts.StartScript -PollScript $scripts.PollScript -CompleteScript $scripts.CompleteScript -SleepScript { param([int]$Seconds) })

    # vSphere forgetting a finished process must end the poll, not spin until the item
    # timeout. The completed flag is false because the exit code is genuinely unknown.
    Assert-Equal -Actual $results.Count -Expected 1 -Message 'harness: a vanished process still yields a result'
    Assert-Equal -Actual ([string]$results[0].Error) -Expected '' -Message 'harness: a vanished process is not an error, it is a finished run with no exit code'
    Assert-Equal -Actual ([bool]$results[0].Payload.AgentResult.Completed) -Expected $false -Message 'harness: a vanished process reports an unknown completion'
    Assert-Equal -Actual ([string]$results[0].Payload.Status.outcome) -Expected 'InstallSucceeded' -Message 'harness: the artifacts still decide the outcome'
    Assert-Equal -Actual ([string]$results[0].Payload.Mode) -Expected 'Apply' -Message 'harness: apply cycles carry their mode'
    Assert-Equal -Actual ([bool](Get-HarnessPayloadValue -Result $results[0] -Name 'AgentCompletionConfirmed' -DefaultValue $false -Context 'harness: vanished process')) -Expected $true -Message 'harness: terminal apply status confirms completion despite a vanished process'
    # A process result vSphere has forgotten is not proof the agent finished, so the guest-side
    # files stay where a human can still read them.
    Assert-Equal -Actual ([string]$results[0].Payload.CleanupStatus) -Expected 'Retained' -Message 'harness: a cycle whose process result was lost keeps its guest directory'
    Assert-Equal -Actual @($script:guestState['VM20'].DeletedDirectories).Count -Expected 0 -Message 'harness: a lost process result deletes nothing'
}
finally {
    Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
}

# --- one guest failing must not take the phase down ------------------------------------

$script:guestState = @{}
$script:curlCalls = @()
$workspace = New-HarnessWorkspace
try {
    New-FakeGuest -VMName 'VM30' -PollsBeforeFinish 1
    New-FakeGuest -VMName 'VM31' -FailsToResolve
    New-FakeGuest -VMName 'VM32' -PollsBeforeFinish 1

    $scripts = New-HarnessFleetScripts -Workspace $workspace
    $items = @(
        (New-HarnessItem -Sequence 1 -VMName 'VM30'),
        (New-HarnessItem -Sequence 2 -VMName 'VM31'),
        (New-HarnessItem -Sequence 3 -VMName 'VM32')
    )
    $results = @(Invoke-InProcessAgentFleet -Items $items -MaxInFlight 3 -PollSeconds 1 -ItemTimeoutSeconds 120 -StartScript $scripts.StartScript -PollScript $scripts.PollScript -CompleteScript $scripts.CompleteScript -SleepScript { param([int]$Seconds) })

    Assert-Equal -Actual $results.Count -Expected 3 -Message 'harness: a failing guest still produces a result row'
    Assert-Contains -Text ([string]@($results | Where-Object { $_.VMName -eq 'VM31' })[0].Error) -Needle 'More than one VM matched' -Message 'harness: the guest error is carried through'
    Assert-Equal -Actual (@($results | Where-Object { $_.VMName -ne 'VM31' -and $_.Error }).Count) -Expected 0 -Message 'harness: one unresolvable guest does not poison the rest of the fleet'
}
finally {
    Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
}

# Two cycles on the same guest must not share scripts, selection or status paths.
$workspace = New-HarnessWorkspace
try {
    New-FakeGuest -VMName 'VM40'
    $item = New-HarnessItem -Sequence 1 -VMName 'VM40'
    $selectionPath = Join-Path $workspace 'selection.json'
    '{"schemaVersion":"selection-v1","selectedUpdateKeys":["11111111-1111-1111-1111-111111111111|1"]}' | Set-Content -LiteralPath $selectionPath
    $cycleParams = @{
        VMName = 'VM40'; Servers = $harnessServerScope; Managers = (New-FakeManagers -VMName 'VM40'); GuestAuth = (New-GuestAuthentication -Credential $item.Credential)
        CurlPath = 'curl.exe'; AgentPath = $agentPath; IdentityHelperPath = $identityHelperPath
        GuestWorkingDirectory = $guestWorkingDirectory; VMOutputDirectory = (Join-Path $workspace 'VM40'); MaxUpdates = 1
        LocalSelectionPath = $selectionPath; SelectionPath = (Join-Path $guestWorkingDirectory 'selection.json')
    }
    $first = Start-VMAgentCycle @cycleParams
    $second = Start-VMAgentCycle @cycleParams
    Assert-Equal ($first.GuestStatusPath -ne $second.GuestStatusPath) $true 'harness: consecutive cycles have distinct artifact paths'
    Assert-Equal ($first.RunId -ne $second.RunId) $true 'harness: consecutive cycles have distinct identities'
    Assert-Equal $script:guestState['VM40'].RunId $second.RunId 'harness: current identity reaches the guest process arguments'
    $cycleDirectory = Split-Path -Parent $second.GuestStatusPath
    Assert-Equal $script:guestState['VM40'].AgentSpec.WorkingDirectory $cycleDirectory 'harness: agent runs in its cycle directory'
    Assert-Contains $script:guestState['VM40'].AgentSpec.Arguments ('-SelectionPath "{0}"' -f (Join-Path $cycleDirectory 'selection.json')) 'harness: agent reads selection from its cycle directory'
    Assert-Equal (@($script:guestState['VM40'].UploadedPaths | Where-Object { $_ -eq (Join-Path $cycleDirectory 'selection.json') }).Count) 1 'harness: selection is uploaded to the path the current agent reads'
    $payload = Complete-VMAgentCycle -Handle $second -AgentResult $null
    Assert-Equal $payload.Status.runId $second.RunId 'harness: the current cycle artifact is accepted even without a process result'
    Assert-Equal $second.Mode 'Apply' 'harness: a non-search cycle carries apply mode'
    Assert-Equal $payload.AgentCompletionConfirmed $true 'harness: apply status confirms completion'

    $script:guestState['VM40'].StatusJson = '{"runId":"old-cycle","outcome":"InstallSucceeded","finishedAt":"2020-01-01T00:00:00Z"}'
    $rejected = $false
    try { $null = Complete-VMAgentCycle -Handle $second -AgentResult $null }
    catch { $rejected = ($_.Exception.Message -like '*runId*') }
    Assert-Equal $rejected $true 'harness: transferred stale success cannot become the current cycle result'
}
finally {
    Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host 'Harness checks failed:'
    foreach ($failure in $failures) {
        Write-Host (' - {0}' -f $failure)
    }
    exit 1
}

Write-Host 'Harness checks passed.'
exit 0

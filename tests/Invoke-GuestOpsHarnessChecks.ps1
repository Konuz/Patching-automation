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
        FailsToResolve = [bool]$FailsToResolve
        MkdirProcessIds = @{}
        ListProcessCallCount = 0
        StartProgramCallCount = 0
        RunId = ''
        AgentSpec = $null
        UploadedPaths = @()
        Client = $null
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
        # cmd.exe is the mkdir call; it always finishes at once so the cycle can get past setup.
        if ([string]$Spec.ProgramPath -like '*cmd.exe') {
            $this.State.MkdirProcessIds[[string]$this.State.NextProcessId] = $true
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

        if ($this.State.MkdirProcessIds.ContainsKey([string]$processId)) {
            return @([pscustomobject]@{ Pid = $processId; EndTime = (Get-Date); ExitCode = 0 })
        }

        if ($this.State.VanishesFromProcessList) {
            return @()
        }

        if ($this.State.NeverFinishes) {
            return @([pscustomobject]@{ Pid = $processId; EndTime = $null; ExitCode = $null })
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

    return [pscustomobject]@{ ProcessManager = $processManager; FileManager = $fileManager }
}

function New-FakeVMView {
    param([string]$VMName)

    return [pscustomobject]@{
        MoRef = ('vm-{0}' -f $VMName)
        Guest = [pscustomobject]@{ ToolsRunningStatus = 'guestToolsRunning' }
        Client = $script:guestState[$VMName].Client
    }
}

# Shadow the three functions that would otherwise reach a real vCenter or the ESXi data
# plane. Everything else - the cycle split, the transfer plumbing, the process polling and
# the artifact parsing - is the production code.
function Get-ExactVM {
    param([string]$Name)

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

function Invoke-Curl {
    param(
        [string]$CurlPath,
        [string[]]$Arguments,
        [string]$Description
    )

    $script:capturedCurlArguments = @($Arguments)
    $script:curlCalls += [pscustomobject]@{ Arguments = @($Arguments); Description = $Description }

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
    $guestOperationsView = [pscustomobject]@{
        ProcessManager = $processReference
        FileManager = $fileReference
    }
    $viewMap = @{
        $guestOperationsReference = $guestOperationsView
        $processReference = $Managers.ProcessManager
        $fileReference = $Managers.FileManager
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
    if ($limitIndex -ge 0) {
        Assert-Equal -Actual $script:capturedCurlArguments[$limitIndex + 1] -Expected '300' -Message 'send transfer uses the default budget'
    }

    $receivedPath = Join-Path $transferWorkspace 'received.json'
    Receive-GuestFile -FileManager $transferManagers.FileManager -VMView (New-FakeVMView -VMName 'VM-transfer') -GuestAuth $null -HostName 'esxi-fake.invalid' -CurlPath 'curl.exe' -GuestPath 'C:\guest\status.json' -LocalPath $receivedPath
    Assert-Equal -Actual ($script:capturedCurlArguments -contains '-k') -Expected $false -Message 'receive transfer keeps TLS verification enabled'
    Assert-Equal -Actual ($script:capturedCurlArguments -contains '--insecure') -Expected $false -Message 'receive transfer has no alternate insecure flag'
    $limitIndex = [array]::IndexOf($script:capturedCurlArguments, '--max-time')
    Assert-Equal -Actual ($limitIndex -ge 0) -Expected $true -Message 'receive transfer always has a deadline'
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
        Start-VMAgentCycle -VMName 'VM-upload-fails' -Managers (New-FakeManagers -VMName 'VM-upload-fails') -GuestAuth $null -CurlPath 'curl.exe' -AgentPath $agentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $guestWorkingDirectory -VMOutputDirectory (Join-Path $failureWorkspace 'VM-upload-fails') -MaxUpdates 1 | Out-Null
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
        GuestSelectionPath = ''
        SearchOnly = $true
    }
    $isolationResults = @(Invoke-GuestAgentFleet -FleetItems @($fleetItem) -Managers $managerA -GuestCredentialMap @{ 'VM-B' = $harnessCredential } -CurlPath 'curl.exe' -AgentPath $agentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $guestWorkingDirectory -TimeoutSeconds 120 -PollSeconds 1 -MaxInFlight 1)
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
            return Start-VMAgentCycle -VMName $Item.VMName -Managers (New-FakeManagers -VMName $Item.VMName) -GuestAuth $auth -CurlPath 'curl.exe' -AgentPath $agentPath -IdentityHelperPath $identityHelperPath -GuestWorkingDirectory $guestWorkingDirectory -VMOutputDirectory (Join-Path $Workspace $Item.VMName) -MaxUpdates 1 -SearchOnly:([bool]$Item.SearchOnly) -TransferTimeoutSeconds $TransferTimeoutSeconds
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
    Assert-Equal -Actual ([bool]@($results | Where-Object { $_.VMName -eq 'VM01' })[0].Payload.AgentCompletionConfirmed) -Expected $true -Message 'harness: terminal search status confirms completion'
    Assert-Equal -Actual ([string]::IsNullOrWhiteSpace([string]@($results | Where-Object { $_.VMName -eq 'VM01' })[0].Payload.AgentCompletionReason)) -Expected $false -Message 'harness: completion confirmation carries a reason'
    Assert-Equal -Actual (Test-Path -LiteralPath (Join-Path (Join-Path $workspace 'VM01') 'status.json')) -Expected $true -Message 'harness: status.json lands in the per-VM output directory'

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
    Assert-Equal -Actual ([bool]$results[0].Payload.AgentCompletionConfirmed) -Expected $true -Message 'harness: terminal apply status confirms completion despite a vanished process'
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
        VMName = 'VM40'; Managers = (New-FakeManagers -VMName 'VM40'); GuestAuth = (New-GuestAuthentication -Credential $item.Credential)
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

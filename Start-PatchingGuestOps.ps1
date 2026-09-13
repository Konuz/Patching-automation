[CmdletBinding()]
param(
    [string]$VIServer,
    [string]$VMName,
    [string[]]$VMNames,
    [string]$VMListPath,
    [pscredential]$VIServerCredential,
    [pscredential]$GuestCredential,
    [int]$MaxUpdates = 1,
    [string]$InstallSelection,
    [string[]]$SelectedUpdateKeys,
    # No defaults here on purpose: these three are forwarded only when actually typed, so a
    # default written here would advertise a value the orchestrator never receives.
    # ThrottleLimit defaults to the whole target list and MaxPatchRounds to 3, both resolved
    # in scripts\Invoke-GuestOpsPatchValidation.ps1.
    [ValidateRange(1, 2147483647)]
    [int]$ThrottleLimit,
    [ValidateRange(1, 2147483647)]
    [int]$RebootBatchSize,
    [ValidateRange(1, 2147483647)]
    [int]$MaxPatchRounds,
    [ValidateRange(1, 35791394)]
    [int]$TimeoutMinutes = 180,
    [ValidateRange(1, 35791394)]
    [int]$DiscoveryTimeoutMinutes = 30,
    [ValidateRange(1, 35791394)]
    [int]$RebootTimeoutMinutes = 30,
    [ValidateRange(1, 2147483647)]
    [int]$PollSeconds = 15,
    [string]$GuestWorkingDirectory = 'C:\ProgramData\PatchingGuestOps',
    [string]$LocalOutputDirectory,
    [string]$PatchPlanPath,
    [switch]$SearchOnly,
    [switch]$PlanOnly,
    [switch]$SkipConfirmation,
    [switch]$IgnoreVCenterCertificate,
    [switch]$KeepConnected,
    [switch]$SkipStaticChecks,
    [hashtable]$PromptProvider,
    [hashtable]$StoredVIServerCredentials,
    [hashtable]$StoredGuestCredentials
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($SearchOnly -and -not [string]::IsNullOrWhiteSpace($PatchPlanPath)) {
    throw 'SearchOnly cannot be combined with PatchPlanPath. Use PlanOnly to inspect a saved plan.'
}

function Resolve-RequiredFile {
    param(
        [string]$Root,
        [string]$RelativePath
    )

    $path = Join-Path $Root $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw ('Required file not found: {0}' -f $path)
    }

    return $path
}

function Resolve-VMTargetNames {
    param(
        [string]$SingleVMName,
        [string[]]$ManyVMNames,
        [string]$ListPath
    )

    $uniqueTargets = @(Resolve-VMTargetNamesFromSources -SingleVMName $SingleVMName -ManyVMNames $ManyVMNames -ListPath $ListPath)

    if ($uniqueTargets.Count -eq 0) {
        do {
            $uniqueTargets = @(Split-VMNameInput -InputText (Read-Host 'VM name(s), separated by ";"'))
        } while ($uniqueTargets.Count -eq 0)
    }

    return $uniqueTargets
}

function Resolve-VIServerNames {
    param([string]$InputText)

    $uniqueServers = @(Split-VIServerInput -InputText $InputText)
    if ($uniqueServers.Count -gt 0) {
        return $uniqueServers
    }

    do {
        $uniqueServers = @(Split-VIServerInput -InputText (Read-Host 'vCenter(s), separated by ";"'))
    } while ($uniqueServers.Count -eq 0)

    return $uniqueServers
}

$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = (Get-Location).Path
}

. (Resolve-RequiredFile -Root $root -RelativePath 'scripts\VMTargetLib.ps1')

$staticCheckPath = Resolve-RequiredFile -Root $root -RelativePath 'tests\Invoke-StaticChecks.ps1'
$modelCheckPath = Resolve-RequiredFile -Root $root -RelativePath 'tests\Invoke-ModelChecks.ps1'
$runtimeCheckPath = Resolve-RequiredFile -Root $root -RelativePath 'tests\Invoke-RuntimeChecks.ps1'
$harnessCheckPath = Resolve-RequiredFile -Root $root -RelativePath 'tests\Invoke-GuestOpsHarnessChecks.ps1'
$orchestratorPath = Resolve-RequiredFile -Root $root -RelativePath 'scripts\Invoke-GuestOpsPatchValidation.ps1'
$agentPath = Resolve-RequiredFile -Root $root -RelativePath 'guest\Run-LocalPatch.ps1'

if (-not $LocalOutputDirectory) {
    $LocalOutputDirectory = Join-Path $root 'out'
}

if (-not $SkipStaticChecks) {
    Write-Host 'Running local static checks...'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $staticCheckPath
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host 'Running local model checks...'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $modelCheckPath
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host 'Running local runtime checks...'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runtimeCheckPath
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    # Exercises the real guest agent cycle against a fake vSphere. Skips itself when the
    # VMware.Vim types are unavailable, so it costs nothing on a machine without PowerCLI.
    Write-Host 'Running local GuestOps harness checks...'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harnessCheckPath
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

$resolvedVIServers = @(Resolve-VIServerNames -InputText $VIServer)
$resolvedVMNames = @(Resolve-VMTargetNames -SingleVMName $VMName -ManyVMNames $VMNames -ListPath $VMListPath)

# Index selection was replaced by grouped selection (-SelectedUpdateKeys); the
# orchestrator throws on InstallSelection. Reject it here, before prompting for
# credentials, so the operator is not asked for two credential sets only to fail.
if (-not [string]::IsNullOrWhiteSpace($InstallSelection)) {
    throw 'InstallSelection is not supported with grouped update selection. Use SelectedUpdateKeys instead.'
}

$orchestratorParams = @{
    VIServer = ($resolvedVIServers -join ';')
    VMNames = $resolvedVMNames
    GuestCredential = $GuestCredential
    AgentPath = $agentPath
    GuestWorkingDirectory = $GuestWorkingDirectory
    LocalOutputDirectory = $LocalOutputDirectory
    MaxUpdates = $MaxUpdates
    TimeoutMinutes = $TimeoutMinutes
    DiscoveryTimeoutMinutes = $DiscoveryTimeoutMinutes
    RebootTimeoutMinutes = $RebootTimeoutMinutes
    PollSeconds = $PollSeconds
}

# Pass these through only when the operator actually typed them. ThrottleLimit defaults to
# "every target at once" inside the orchestrator, which it works out from the resolved VM
# list; splatting the launcher's own default would always look like an explicit choice and
# pin concurrency at 3. RebootBatchSize left unbound means "prompt before rebooting".
foreach ($passThroughName in @('ThrottleLimit', 'RebootBatchSize', 'MaxPatchRounds', 'PromptProvider', 'StoredVIServerCredentials', 'StoredGuestCredentials')) {
    if ($PSBoundParameters.ContainsKey($passThroughName)) {
        $orchestratorParams[$passThroughName] = $PSBoundParameters[$passThroughName]
    }
}

if ($VIServerCredential) {
    $orchestratorParams.VIServerCredential = $VIServerCredential
}

if ($PSBoundParameters.ContainsKey('SelectedUpdateKeys')) {
    $orchestratorParams.SelectedUpdateKeys = $SelectedUpdateKeys
}

if (-not [string]::IsNullOrWhiteSpace($PatchPlanPath)) {
    $orchestratorParams.PatchPlanPath = $PatchPlanPath
}

if ($SearchOnly) {
    $orchestratorParams.SearchOnly = $true
}

if ($PlanOnly) {
    $orchestratorParams.PlanOnly = $true
}

if ($SkipConfirmation) {
    $orchestratorParams.SkipConfirmation = $true
}

if ($IgnoreVCenterCertificate) {
    $orchestratorParams.IgnoreVCenterCertificate = $true
}

if ($KeepConnected) {
    $orchestratorParams.KeepConnected = $true
}

& $orchestratorPath @orchestratorParams
exit $LASTEXITCODE

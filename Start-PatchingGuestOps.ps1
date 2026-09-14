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
    [switch]$IgnoreESXiCertificate,
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

function Invoke-LocalCheck {
    param([string]$Name, [string]$ScriptPath, [string]$LogPath)

    Write-Host ('Running local {0} checks...' -f $Name)
    $previousPreference = $ErrorActionPreference
    try {
        # Native stderr must not bypass the exit-code check in Windows PowerShell 5.1.
        $ErrorActionPreference = 'Continue'
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath 2>&1)
        $checkExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    $lines = @($output | ForEach-Object { [string]$_ })
    $lines | Set-Content -LiteralPath $LogPath -Encoding UTF8
    if ($checkExitCode -ne 0) {
        Write-Host ('{0}: FAILED (exit {1}). Log: {2}' -f $Name, $checkExitCode, $LogPath)
        $lines | ForEach-Object { Write-Host $_ }
    }
    else {
        $skips = @($lines | Where-Object { $_ -match '(?i)^SKIPPED:|^.*checks skipped:' })
        $verdict = if ($skips.Count -gt 0) { 'PASSED WITH SKIPS' } else { 'PASSED' }
        Write-Host ('{0}: {1}' -f $Name, $verdict)
        $skips | ForEach-Object { Write-Host $_ }
    }
    return $checkExitCode
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
    $checkLogDirectory = Join-Path $LocalOutputDirectory ('local-checks-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $checkLogDirectory -Force
    Write-Host ('Local checks use simulated failures. Detailed output: {0}' -f $checkLogDirectory)
    foreach ($check in @(
        @{ Name = 'Static'; Path = $staticCheckPath },
        @{ Name = 'Model'; Path = $modelCheckPath },
        @{ Name = 'Runtime'; Path = $runtimeCheckPath },
        @{ Name = 'GuestOps harness'; Path = $harnessCheckPath }
    )) {
        $checkExitCode = Invoke-LocalCheck -Name $check.Name -ScriptPath $check.Path -LogPath (Join-Path $checkLogDirectory ($check.Name + '.log'))
        if ($checkExitCode -ne 0) { exit $checkExitCode }
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

if ($IgnoreESXiCertificate) {
    $orchestratorParams.IgnoreESXiCertificate = $true
}

if ($KeepConnected) {
    $orchestratorParams.KeepConnected = $true
}

& $orchestratorPath @orchestratorParams
exit $LASTEXITCODE

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
    [int]$ThrottleLimit = 3,
    [int]$TimeoutMinutes = 180,
    [int]$PollSeconds = 15,
    [string]$GuestWorkingDirectory = 'C:\ProgramData\PatchingGuestOps',
    [string]$LocalOutputDirectory,
    [string]$PatchPlanPath,
    [switch]$SearchOnly,
    [switch]$PlanOnly,
    [switch]$SkipConfirmation,
    [switch]$IgnoreVCenterCertificate,
    [switch]$KeepConnected,
    [switch]$SkipStaticChecks
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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

function Read-RequiredValue {
    param(
        [string]$CurrentValue,
        [string]$Prompt
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
        return $CurrentValue
    }

    do {
        $value = Read-Host $Prompt
    } while ([string]::IsNullOrWhiteSpace($value))

    return $value
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
            $uniqueTargets = @(Split-VMNameInput -InputText (Read-Host 'VM name(s), separated by ;'))
        } while ($uniqueTargets.Count -eq 0)
    }

    return $uniqueTargets
}

$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = (Get-Location).Path
}

. (Resolve-RequiredFile -Root $root -RelativePath 'scripts\VMTargetLib.ps1')

$staticCheckPath = Resolve-RequiredFile -Root $root -RelativePath 'tests\Invoke-StaticChecks.ps1'
$modelCheckPath = Resolve-RequiredFile -Root $root -RelativePath 'tests\Invoke-ModelChecks.ps1'
$runtimeCheckPath = Resolve-RequiredFile -Root $root -RelativePath 'tests\Invoke-RuntimeChecks.ps1'
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
}

$VIServer = Read-RequiredValue -CurrentValue $VIServer -Prompt 'vCenter'
$resolvedVMNames = @(Resolve-VMTargetNames -SingleVMName $VMName -ManyVMNames $VMNames -ListPath $VMListPath)

# Index selection was replaced by grouped selection (-SelectedUpdateKeys); the
# orchestrator throws on InstallSelection. Reject it here, before prompting for
# credentials, so the operator is not asked for two credential sets only to fail.
if (-not [string]::IsNullOrWhiteSpace($InstallSelection)) {
    throw 'InstallSelection is not supported with grouped update selection. Use SelectedUpdateKeys instead.'
}

if (-not $VIServerCredential) {
    $VIServerCredential = Get-Credential -Message ('Credentials for vCenter {0}' -f $VIServer)
}

if (-not $GuestCredential) {
    $GuestCredential = Get-Credential -Message 'Local administrator credentials for guest VM targets'
}

$orchestratorParams = @{
    VIServer = $VIServer
    VMNames = $resolvedVMNames
    VIServerCredential = $VIServerCredential
    GuestCredential = $GuestCredential
    AgentPath = $agentPath
    GuestWorkingDirectory = $GuestWorkingDirectory
    LocalOutputDirectory = $LocalOutputDirectory
    MaxUpdates = $MaxUpdates
    ThrottleLimit = $ThrottleLimit
    TimeoutMinutes = $TimeoutMinutes
    PollSeconds = $PollSeconds
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

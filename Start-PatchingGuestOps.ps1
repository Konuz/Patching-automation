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
        $uniqueTargets += (Read-RequiredValue -CurrentValue $null -Prompt 'Non-production VM name')
    }

    return $uniqueTargets
}

$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = (Get-Location).Path
}

$staticCheckPath = Resolve-RequiredFile -Root $root -RelativePath 'tests\Invoke-StaticChecks.ps1'
$modelCheckPath = Resolve-RequiredFile -Root $root -RelativePath 'tests\Invoke-ModelChecks.ps1'
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
}

$VIServer = Read-RequiredValue -CurrentValue $VIServer -Prompt 'vCenter'
$resolvedVMNames = @(Resolve-VMTargetNames -SingleVMName $VMName -ManyVMNames $VMNames -ListPath $VMListPath)

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

if (-not [string]::IsNullOrWhiteSpace($InstallSelection)) {
    $orchestratorParams.InstallSelection = $InstallSelection
}

if ($PSBoundParameters.ContainsKey('SelectedUpdateKeys')) {
    $orchestratorParams.SelectedUpdateKeys = $SelectedUpdateKeys
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

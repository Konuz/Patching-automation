[CmdletBinding()]
param(
    [string]$VIServer,
    [string]$VMName,
    [pscredential]$VIServerCredential,
    [pscredential]$GuestCredential,
    [int]$MaxUpdates = 1,
    [string]$InstallSelection,
    [int]$TimeoutMinutes = 180,
    [int]$PollSeconds = 15,
    [string]$GuestWorkingDirectory = 'C:\ProgramData\PatchingGuestOps',
    [string]$LocalOutputDirectory,
    [switch]$SearchOnly,
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

$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = (Get-Location).Path
}

$staticCheckPath = Resolve-RequiredFile -Root $root -RelativePath 'tests\Invoke-StaticChecks.ps1'
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
}

$VIServer = Read-RequiredValue -CurrentValue $VIServer -Prompt 'vCenter'
$VMName = Read-RequiredValue -CurrentValue $VMName -Prompt 'Non-production VM name'

if (-not $VIServerCredential) {
    $VIServerCredential = Get-Credential -Message ('Credentials for vCenter {0}' -f $VIServer)
}

if (-not $GuestCredential) {
    $GuestCredential = Get-Credential -Message ('Local administrator credentials for guest VM {0}' -f $VMName)
}

$orchestratorParams = @{
    VIServer = $VIServer
    VMName = $VMName
    VIServerCredential = $VIServerCredential
    GuestCredential = $GuestCredential
    AgentPath = $agentPath
    GuestWorkingDirectory = $GuestWorkingDirectory
    LocalOutputDirectory = $LocalOutputDirectory
    MaxUpdates = $MaxUpdates
    TimeoutMinutes = $TimeoutMinutes
    PollSeconds = $PollSeconds
}

if (-not [string]::IsNullOrWhiteSpace($InstallSelection)) {
    $orchestratorParams.InstallSelection = $InstallSelection
}

if ($SearchOnly) {
    $orchestratorParams.SearchOnly = $true
}

if ($IgnoreVCenterCertificate) {
    $orchestratorParams.IgnoreVCenterCertificate = $true
}

if ($KeepConnected) {
    $orchestratorParams.KeepConnected = $true
}

& $orchestratorPath @orchestratorParams
exit $LASTEXITCODE

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = (Get-Location).Path
}

# Under MTA, OpenFileDialog hangs without throwing, so check hard and early instead of
# leaving the operator staring at a dead window.
if ($Host.Runspace.ApartmentState -ne 'STA') {
    throw 'This GUI requires an STA host. Start it with: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-PatchingGuestOpsGui.ps1'
}

. (Join-Path $root 'scripts\GuestOpsLib.ps1')
. (Join-Path $root 'scripts\VMTargetLib.ps1')
. (Join-Path $root 'scripts\SettingsStore.ps1')
. (Join-Path $root 'scripts\GuiPrompts.ps1')

[System.Windows.Forms.Application]::EnableVisualStyles()

$storeDirectory = Get-GuiStoreDirectory
$settingsPath = Join-Path $storeDirectory 'settings.json'
$credentialsPath = Join-Path $storeDirectory 'credentials.json'

$settingsResult = Read-GuiSettings -Path $settingsPath
$credentialResult = Read-CredentialStore -Path $credentialsPath

foreach ($warning in (@($settingsResult.Warnings) + @($credentialResult.Warnings))) {
    Write-Warning $warning
}

$answer = Show-LauncherDialog -Settings $settingsResult.Settings
if ($answer.Cancelled) {
    Write-Host 'Cancelled.'
    exit 1
}

$store = $credentialResult.Credentials
$storeChanged = $false

# Deduplicate before deriving credential groups. The console launcher dedupes
# case-insensitively on its way in, but the GUI computes groups earlier, so without this
# a list holding both OldBox and oldbox would ask for the same machine's password twice.
$guiVMNames = @(Get-UniqueTrimmedNames -Names $answer.VMNames)
$guiVIServers = @(Get-UniqueTrimmedNames -Names $answer.VIServers)

# Filling the gaps MUST cover both scopes before the run starts; otherwise the orchestrator
# reaches for the system Get-Credential dialog halfway through the run.
$missingKeys = @()
$missingKeys += @(Get-MissingCredentialStoreKeys -Scope 'vcenter' -TargetNames $guiVIServers -Store $store)
$missingKeys += @(Get-MissingCredentialStoreKeys -Scope 'guest' -TargetNames $guiVMNames -Store $store)

foreach ($missing in $missingKeys) {
    $scopeLabel = if ($missing.Scope -eq 'vcenter') { 'vCenter' } else { 'guest' }
    $message = ('{0} credentials for {1} ({2})' -f $scopeLabel, $missing.Label, (@($missing.Members) -join ', '))
    $entered = Show-CredentialDialog -Title 'PatchingGuestOps credentials' -Message $message

    if ($null -eq $entered) {
        Write-Warning ('No credentials supplied for {0}; aborting before the run starts.' -f $missing.StoreKey)
        exit 1
    }

    $store[$missing.StoreKey] = $entered.Credential
    if ($entered.Remember) {
        $storeChanged = $true
    }
}

$settingsToSave = $settingsResult.Settings
$settingsToSave.VIServers = @($guiVIServers)
$settingsToSave.LocalOutputDirectory = $answer.LocalOutputDirectory
$settingsToSave.IgnoreVCenterCertificate = $answer.IgnoreVCenterCertificate
$settingsToSave.KeepConnected = $answer.KeepConnected

$parsedThrottle = 0
$settingsToSave.ThrottleLimit = if ([int]::TryParse($answer.ThrottleLimit, [ref]$parsedThrottle) -and $parsedThrottle -ge 1) { $parsedThrottle } else { $null }
$parsedBatch = 0
$settingsToSave.RebootBatchSize = if ([int]::TryParse($answer.RebootBatchSize, [ref]$parsedBatch) -and $parsedBatch -ge 1) { $parsedBatch } else { $null }
$parsedRounds = 0
$settingsToSave.MaxPatchRounds = if ([int]::TryParse($answer.MaxPatchRounds, [ref]$parsedRounds) -and $parsedRounds -ge 1) { $parsedRounds } else { 3 }

# Save BEFORE launching: the local gates take tens of seconds and can end the run with a
# non-zero code, which would discard everything the operator just typed.
Write-GuiSettings -Path $settingsPath -Settings $settingsToSave
if ($storeChanged) {
    Write-CredentialStore -Path $credentialsPath -Credentials $store
}

$launcherParams = @{
    VIServer = (@($guiVIServers) -join ';')
    VMNames = @($guiVMNames)
    MaxPatchRounds = $settingsToSave.MaxPatchRounds
    StoredVIServerCredentials = (Expand-CredentialStoreMap -Scope 'vcenter' -TargetNames $guiVIServers -Store $store)
    StoredGuestCredentials = (Expand-CredentialStoreMap -Scope 'guest' -TargetNames $guiVMNames -Store $store)
    PromptProvider = @{
        SelectUpdateGroups = {
            param($Arguments)
            $groups = @($Arguments.UpdateGroups)
            $dialogResult = Show-UpdateGroupDialog -UpdateGroups $groups -DefaultCheckedIndexes (Get-DefaultCheckedIndexes -UpdateGroups $groups)
            if ($dialogResult.Aborted) {
                New-UpdateSelectionResult -Aborted
            }
            else {
                New-UpdateSelectionResult -Keys (Get-SelectedIdentityKeys -UpdateGroups $groups -CheckedIndexes $dialogResult.CheckedIndexes)
            }
        }
        PromptCredential = {
            param([string]$Message)
            $entered = Show-CredentialDialog -Title 'PatchingGuestOps credentials' -Message $Message
            if ($null -eq $entered) { $null } else { $entered.Credential }
        }
    }
}

if ($settingsToSave.ThrottleLimit) {
    $launcherParams.ThrottleLimit = $settingsToSave.ThrottleLimit
}

if ($settingsToSave.RebootBatchSize) {
    $launcherParams.RebootBatchSize = $settingsToSave.RebootBatchSize
}

if (-not [string]::IsNullOrWhiteSpace($settingsToSave.LocalOutputDirectory)) {
    $launcherParams.LocalOutputDirectory = $settingsToSave.LocalOutputDirectory
}

if ($settingsToSave.IgnoreVCenterCertificate) { $launcherParams.IgnoreVCenterCertificate = $true }
if ($settingsToSave.KeepConnected) { $launcherParams.KeepConnected = $true }
if ($answer.SearchOnly) { $launcherParams.SearchOnly = $true }

# Call operator, not dot-source: Start-PatchingGuestOps.ps1 ends with exit $LASTEXITCODE,
# which under dot-source would kill this process along with its windows.
& (Join-Path $root 'Start-PatchingGuestOps.ps1') @launcherParams
exit $LASTEXITCODE

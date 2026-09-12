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

if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'LOCALAPPDATA is not set, so there is nowhere to keep saved settings and credentials.'
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

# $store aliases the loaded hashtable, so capture what was already on disk before the
# gap-filling loop adds anything to it.
$previouslyStoredKeys = @($store.Keys)
$rememberedKeys = @()

# $store is what the run uses; $persistState.Persisted is what belongs on disk. They are
# separate because they genuinely diverge: a replacement entered with Remember unticked must
# serve the run while the file keeps the password that is already there.
$persistedSeed = @{}
foreach ($storedKey in @($previouslyStoredKeys)) {
    $persistedSeed[$storedKey] = $store[$storedKey]
}
$persistState = New-CredentialPersistState -Path $credentialsPath -WorkingCredentials $store -PersistedCredentials $persistedSeed -PassThroughEntries $credentialResult.UnreadableEntries

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
    Set-CredentialRememberPreference -State $persistState -StoreKey $missing.StoreKey -Remember ([bool]$entered.Remember)
    if ($entered.Remember) {
        $rememberedKeys += $missing.StoreKey
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
try {
    Write-GuiSettings -Path $settingsPath -Settings $settingsToSave
}
catch {
    Write-Warning ('Settings could not be saved ({0}); continuing without persisting them.' -f $_.Exception.Message)
}

# The state object is handed to the callbacks explicitly. A function that assigns to an
# enclosing script variable does not update it in PowerShell 5.1, and that failure is silent:
# the callbacks are called from inside a generic catch, so a broken save just warns.
function Register-ValidatedGuiCredential {
    param(
        [string]$StoreKey,
        [pscredential]$Credential,
        $Remember
    )

    try {
        $null = Register-ValidatedCredential -State $persistState -StoreKey $StoreKey -Credential $Credential -Remember $Remember
    }
    catch {
        Write-Warning ('Credentials could not be saved ({0}); the corrected credential remains available for this run.' -f $_.Exception.Message)
    }
}

# Only what the operator explicitly agreed to remember reaches the disk before the run starts.
if ($rememberedKeys.Count -gt 0) {
    try {
        Save-CredentialPersistState -State $persistState
    }
    catch {
        Write-Warning ('Credentials could not be saved ({0}); continuing without persisting them.' -f $_.Exception.Message)
    }
}

$launcherParams = @{
    VIServer = (@($guiVIServers) -join ';')
    VMNames = @($guiVMNames)
    MaxPatchRounds = $settingsToSave.MaxPatchRounds
    RebootTimeoutMinutes = $settingsToSave.RebootTimeoutMinutes
    PollSeconds = $settingsToSave.PollSeconds
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
        RecoverGuestCredential = {
            param($VMName, $AccountKey, $Members, $Reason)
            $message = 'The guest {0} rejected the credentials for {1}: {2}' -f $VMName, $AccountKey, $Reason
            Show-GuestCredentialRecoveryDialog -Message $message -Members @($Members) -AllowSkip
        }
        # The resolver reports the account key it grouped by ("domain:contoso.com"), which is
        # the store key without its scope. Prefixing it here keeps guest replacements on the
        # existing group entry instead of scattering per-VM copies of the same password.
        CredentialValidated = {
            param($AccountKey, $Members, $Credential, $Remember)
            Register-ValidatedGuiCredential -StoreKey ('guest:{0}' -f $AccountKey) -Credential $Credential -Remember $Remember
        }
        RecoverVIServerCredential = {
            param($Server, $Message)
            Show-GuestCredentialRecoveryDialog -Message $Message -Members @($Server)
        }

        # One vCenter's correction is written to its own target key, never to the group entry
        # the other servers behind that DNS suffix still rely on.
        VIServerCredentialValidated = {
            param($Server, $Credential, $Remember)
            # Guard before deriving the key: an empty target name would still produce a
            # non-blank store key and write a credential under nobody.
            if ([string]::IsNullOrWhiteSpace([string]$Server)) {
                return
            }

            Register-ValidatedGuiCredential -StoreKey (Get-TargetCredentialStoreKey -Scope 'vcenter' -TargetName $Server) -Credential $Credential -Remember $Remember
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

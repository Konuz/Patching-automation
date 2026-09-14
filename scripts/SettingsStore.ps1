Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMTargetLib.ps1')
. (Join-Path $PSScriptRoot 'GuestOpsLib.ps1')

# Credential grouping is shared with the console run. Never reproduce that logic here:
# a domain key is everything after the FIRST dot, lowercased, while local keys keep
# their original casing (scripts/VMTargetLib.ps1). The kind is part of the store key
# because those two are separate namespaces: a standalone machine named "dmz" and a
# domain suffix "dmz" would otherwise share one entry and silently share one password.
function Get-CredentialStoreKeys {
    param(
        [string]$Scope,
        [string[]]$TargetNames
    )

    $keys = @()
    foreach ($group in @(Get-GuestCredentialGroups -TargetNames $TargetNames)) {
        $keys += [pscustomobject]@{
            StoreKey = ('{0}:{1}:{2}' -f $Scope, ([string]$group.Kind).ToLowerInvariant(), $group.Key)
            Scope    = $Scope
            Kind     = $group.Kind
            Label    = $group.Key
            Members  = @($group.Members)
        }
    }

    return @($keys)
}

# An exact-target key overrides its group. Two vCenters behind one DNS suffix share a group
# entry, so when only one of them rejects its password, rewriting that entry would hand the
# other server a credential nobody validated against it. The 'target' segment is a third
# namespace alongside 'domain' and 'local', so it can never collide with a group key.
function Get-TargetCredentialStoreKey {
    param(
        [string]$Scope,
        [string]$TargetName
    )

    return ('{0}:target:{1}' -f $Scope, ([string]$TargetName).Trim().ToLowerInvariant())
}

# One place decides which entry a single target resolves to, so the map and the
# missing-key report can never disagree about what is already covered.
function Get-CredentialStoreEntryForTarget {
    param(
        [string]$Scope,
        [string]$TargetName,
        [hashtable]$Store,
        $Group
    )

    if ($null -eq $Store) {
        return $null
    }

    $targetKey = Get-TargetCredentialStoreKey -Scope $Scope -TargetName $TargetName
    if ($Store.ContainsKey($targetKey)) {
        return $Store[$targetKey]
    }

    if ($null -ne $Group -and $Store.ContainsKey($Group.StoreKey)) {
        return $Store[$Group.StoreKey]
    }

    return $null
}

# The store is keyed by group; consumers look up by full name and throw when they miss
# (see Connect-VIServersWithCredentialMap). This function is the only bridge between them.
function Expand-CredentialStoreMap {
    param(
        [string]$Scope,
        [string[]]$TargetNames,
        [hashtable]$Store
    )

    if ($null -eq $Store) {
        $Store = @{}
    }

    $map = @{}
    foreach ($key in @(Get-CredentialStoreKeys -Scope $Scope -TargetNames $TargetNames)) {
        foreach ($member in @($key.Members)) {
            $credential = Get-CredentialStoreEntryForTarget -Scope $Scope -TargetName $member -Store $Store -Group $key
            if ($null -ne $credential) {
                $map[$member] = $credential
            }
        }
    }

    return $map
}

function Get-GuiStoreDirectory {
    return (Join-Path $env:LOCALAPPDATA 'PatchingGuestOps')
}

function New-DefaultGuiSettings {
    # ThrottleLimit and RebootBatchSize are $null on purpose: the launcher forwards them
    # only when the operator supplies them, so a number here would fake an explicit choice.
    return [pscustomobject]@{
        VIServers = @()
        ThrottleLimit = $null
        RebootBatchSize = $null
        MaxPatchRounds = 3
        RebootTimeoutMinutes = 30
        PollSeconds = 15
        LocalOutputDirectory = ''
        IgnoreVCenterCertificate = $false
        IgnoreESXiCertificate = $false
        KeepConnected = $false
    }
}

function Get-ValidatedRangeValue {
    param(
        $Raw,
        $Default,
        [string]$Name,
        [System.Collections.Generic.List[string]]$Warnings
    )

    if ($null -eq $Raw) {
        return $Default
    }

    $parsed = 0
    if (-not [int]::TryParse([string]$Raw, [ref]$parsed) -or $parsed -lt 1) {
        [void]$Warnings.Add(('Ignoring stored {0}="{1}": must be an integer of at least 1.' -f $Name, $Raw))
        return $Default
    }

    return $parsed
}

function Read-GuiSettings {
    param([string]$Path)

    $warnings = New-Object System.Collections.Generic.List[string]
    $settings = New-DefaultGuiSettings

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Settings = $settings; Warnings = @($warnings) }
    }

    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        [void]$warnings.Add(('Settings file could not be read ({0}); using defaults.' -f $_.Exception.Message))
        return [pscustomobject]@{ Settings = $settings; Warnings = @($warnings) }
    }

    $storedVIServers = Get-ObjectPropertyValue -InputObject $raw -Path @('VIServers')
    $settings.VIServers = @(@($storedVIServers) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $settings.ThrottleLimit = Get-ValidatedRangeValue -Raw (Get-ObjectPropertyValue -InputObject $raw -Path @('ThrottleLimit')) -Default $null -Name 'ThrottleLimit' -Warnings $warnings
    $settings.RebootBatchSize = Get-ValidatedRangeValue -Raw (Get-ObjectPropertyValue -InputObject $raw -Path @('RebootBatchSize')) -Default $null -Name 'RebootBatchSize' -Warnings $warnings
    $settings.MaxPatchRounds = Get-ValidatedRangeValue -Raw (Get-ObjectPropertyValue -InputObject $raw -Path @('MaxPatchRounds')) -Default 3 -Name 'MaxPatchRounds' -Warnings $warnings
    $settings.RebootTimeoutMinutes = Get-ValidatedRangeValue -Raw (Get-ObjectPropertyValue -InputObject $raw -Path @('RebootTimeoutMinutes')) -Default 30 -Name 'RebootTimeoutMinutes' -Warnings $warnings
    $settings.PollSeconds = Get-ValidatedRangeValue -Raw (Get-ObjectPropertyValue -InputObject $raw -Path @('PollSeconds')) -Default 15 -Name 'PollSeconds' -Warnings $warnings

    $outputDirectory = Get-ObjectPropertyValue -InputObject $raw -Path @('LocalOutputDirectory')
    if ($null -ne $outputDirectory) {
        $settings.LocalOutputDirectory = [string]$outputDirectory
    }

    $settings.IgnoreVCenterCertificate = [bool](Get-ObjectPropertyValue -InputObject $raw -Path @('IgnoreVCenterCertificate'))
    $ignoreESXi = Get-ObjectPropertyValue -InputObject $raw -Path @('IgnoreESXiCertificate')
    $settings.IgnoreESXiCertificate = ($ignoreESXi -is [bool]) -and ($ignoreESXi -eq $true)
    $settings.KeepConnected = [bool](Get-ObjectPropertyValue -InputObject $raw -Path @('KeepConnected'))

    return [pscustomobject]@{ Settings = $settings; Warnings = @($warnings) }
}

function Write-GuiSettings {
    param(
        [string]$Path,
        $Settings
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }

    # The VM list is never persisted (it differs every run), and neither is SkipStaticChecks:
    # a sticky "skip the gates" is how gates stop protecting anything.
    $payload = [pscustomobject]@{
        VIServers = @($Settings.VIServers)
        ThrottleLimit = $Settings.ThrottleLimit
        RebootBatchSize = $Settings.RebootBatchSize
        MaxPatchRounds = $Settings.MaxPatchRounds
        RebootTimeoutMinutes = $Settings.RebootTimeoutMinutes
        PollSeconds = $Settings.PollSeconds
        LocalOutputDirectory = [string]$Settings.LocalOutputDirectory
        IgnoreVCenterCertificate = [bool]$Settings.IgnoreVCenterCertificate
        IgnoreESXiCertificate = [bool](Get-ObjectPropertyValue -InputObject $Settings -Path @('IgnoreESXiCertificate') -DefaultValue $false)
        KeepConnected = [bool]$Settings.KeepConnected
    }

    $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-MissingCredentialStoreKeys {
    param(
        [string]$Scope,
        [string[]]$TargetNames,
        [hashtable]$Store
    )

    if ($null -eq $Store) {
        $Store = @{}
    }

    # A member covered by its own exact-target entry needs no prompt, so a group is only
    # reported when something is still uncovered - and then only for those members.
    $missing = @()
    foreach ($key in @(Get-CredentialStoreKeys -Scope $Scope -TargetNames $TargetNames)) {
        $uncovered = @(@($key.Members) | Where-Object { $null -eq (Get-CredentialStoreEntryForTarget -Scope $Scope -TargetName $_ -Store $Store -Group $key) })
        if ($uncovered.Count -eq 0) {
            continue
        }

        $missing += [pscustomobject]@{
            StoreKey = $key.StoreKey
            Scope    = $key.Scope
            Kind     = $key.Kind
            Label    = $key.Label
            Members  = @($uncovered)
        }
    }

    return @($missing)
}

function Write-CredentialStore {
    param(
        [string]$Path,
        [hashtable]$Credentials,
        # Entries this Windows account could not decrypt. They belong to another profile, not
        # to nobody, so they are carried through verbatim: dropping them would quietly delete
        # a credential the operator saved and can still use elsewhere.
        [hashtable]$PassThroughEntries
    )

    if ($null -eq $Credentials) {
        $Credentials = @{}
    }

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }

    $payload = @{}
    foreach ($storeKey in @($Credentials.Keys)) {
        $credential = $Credentials[$storeKey]
        $payload[$storeKey] = @{
            UserName = $credential.UserName
            Password = ($credential.Password | ConvertFrom-SecureString)
        }
    }

    if ($null -ne $PassThroughEntries) {
        foreach ($storeKey in @($PassThroughEntries.Keys)) {
            if (-not $payload.ContainsKey([string]$storeKey)) {
                $payload[[string]$storeKey] = $PassThroughEntries[$storeKey]
            }
        }
    }

    # Serialise before touching the file, then swap it in: Set-Content truncates first, so a
    # failure part-way through would leave every other account's password destroyed.
    $json = $payload | ConvertTo-Json -Depth 4
    $temporaryPath = '{0}.{1}.tmp' -f $Path, ([guid]::NewGuid().ToString('N'))
    try {
        Set-Content -LiteralPath $temporaryPath -Value $json -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# Three answers, not two. A recovery dialog states its own; a credential typed at startup
# carries only the preference from that form; and where neither exists the answer is "do not
# write a new entry" - guessing would put a password on disk the operator never agreed to.
function Resolve-CredentialPersistDecision {
    param(
        $Remember,
        $RememberPreference
    )

    if ($null -ne $Remember) {
        return [bool]$Remember
    }

    if ($null -ne $RememberPreference) {
        return [bool]$RememberPreference
    }

    return $false
}

# Two maps, not one map plus a list of approved keys. They genuinely diverge: when the operator
# supplies a replacement and unticks Remember, the run must use the new password while the file
# keeps the old one - and that is impossible to express if both read the same entry.
#
# The state is passed explicitly rather than reached for through the scope chain. A function
# that assigns to an enclosing script's variable does not update it in PowerShell 5.1: `+=`
# creates a local, reads $null as the left operand, and leaves the caller's value untouched.
function New-CredentialPersistState {
    param(
        [string]$Path,
        [hashtable]$WorkingCredentials,
        [hashtable]$PersistedCredentials,
        [hashtable]$PassThroughEntries
    )

    if ($null -eq $WorkingCredentials) { $WorkingCredentials = @{} }
    if ($null -eq $PersistedCredentials) { $PersistedCredentials = @{} }
    if ($null -eq $PassThroughEntries) { $PassThroughEntries = @{} }

    $persisted = @{}
    foreach ($storeKey in @($PersistedCredentials.Keys)) {
        $persisted[[string]$storeKey] = $PersistedCredentials[$storeKey]
    }

    return @{
        Path = $Path
        Working = $WorkingCredentials
        Persisted = $persisted
        PassThrough = $PassThroughEntries
        RememberPreferences = @{}
    }
}

function Set-CredentialRememberPreference {
    param(
        [hashtable]$State,
        [string]$StoreKey,
        [bool]$Remember
    )

    if ($null -eq $State -or [string]::IsNullOrWhiteSpace($StoreKey)) {
        return
    }

    $State.RememberPreferences[$StoreKey] = $Remember
    if ($Remember -and $State.Working.ContainsKey($StoreKey)) {
        $State.Persisted[$StoreKey] = $State.Working[$StoreKey]
    }
}

function Save-CredentialPersistState {
    param([hashtable]$State)

    Write-CredentialStore -Path $State.Path -Credentials $State.Persisted -PassThroughEntries $State.PassThrough
}

# Returns $true when the credential was written. The run always takes the new credential; only
# the file is conditional, and an explicit refusal is recorded so a later validation of the same
# account cannot fall back to a stale startup preference and save it after all.
function Register-ValidatedCredential {
    param(
        [hashtable]$State,
        [string]$StoreKey,
        [pscredential]$Credential,
        $Remember
    )

    if ($null -eq $State -or [string]::IsNullOrWhiteSpace($StoreKey) -or $null -eq $Credential) {
        return $false
    }

    $State.Working[$StoreKey] = $Credential

    $preference = $null
    if ($State.RememberPreferences.ContainsKey($StoreKey)) {
        $preference = $State.RememberPreferences[$StoreKey]
    }

    if (-not (Resolve-CredentialPersistDecision -Remember $Remember -RememberPreference $preference)) {
        if ($null -ne $Remember) {
            $State.RememberPreferences[$StoreKey] = [bool]$Remember
        }

        return $false
    }

    $State.RememberPreferences[$StoreKey] = $true
    $State.Persisted[$StoreKey] = $Credential
    Save-CredentialPersistState -State $State
    return $true
}

function Read-CredentialStore {
    param([string]$Path)

    $warnings = New-Object System.Collections.Generic.List[string]
    $credentials = @{}
    # Entries this account cannot read are kept verbatim so a later save does not delete them.
    $unreadable = @{}

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Credentials = $credentials; UnreadableEntries = $unreadable; Warnings = @($warnings) }
    }

    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        [void]$warnings.Add(('Credential file could not be read ({0}); no stored credentials are available.' -f $_.Exception.Message))
        return [pscustomobject]@{ Credentials = $credentials; UnreadableEntries = $unreadable; Warnings = @($warnings) }
    }

    if ($null -eq $raw) {
        [void]$warnings.Add('Credential file held no readable content; no stored credentials are available.')
        return [pscustomobject]@{ Credentials = $credentials; UnreadableEntries = $unreadable; Warnings = @($warnings) }
    }

    foreach ($property in @($raw.PSObject.Properties)) {
        $storeKey = [string]$property.Name
        $userName = [string](Get-ObjectPropertyValue -InputObject $property.Value -Path @('UserName'))
        $protected = [string](Get-ObjectPropertyValue -InputObject $property.Value -Path @('Password'))

        if ([string]::IsNullOrWhiteSpace($userName) -or [string]::IsNullOrWhiteSpace($protected)) {
            [void]$warnings.Add(('Stored credential "{0}" is incomplete and was ignored.' -f $storeKey))
            continue
        }

        $rawEntry = @{ UserName = $userName; Password = $protected }

        # DPAPI is bound to the Windows account and machine. A rebuilt profile or a different
        # account raises CryptographicException here, not an XML error - and that is a real
        # scenario, so catch broadly and degrade to a prompt for this one key.
        try {
            $secure = ConvertTo-SecureString -String $protected
            $credentials[$storeKey] = New-Object System.Management.Automation.PSCredential($userName, $secure)
        }
        catch {
            [void]$warnings.Add(('Stored credential "{0}" could not be decrypted on this account and will be requested again.' -f $storeKey))
            $unreadable[$storeKey] = $rawEntry
        }
    }

    return [pscustomobject]@{ Credentials = $credentials; UnreadableEntries = $unreadable; Warnings = @($warnings) }
}

function Get-DefaultCheckedIndexes {
    param($UpdateGroups)

    $groups = @($UpdateGroups)
    $indexes = @()
    for ($i = 0; $i -lt $groups.Count; $i++) {
        if ([bool]$groups[$i].selectedByDefault) {
            $indexes += $i
        }
    }

    return @($indexes)
}

function Get-SelectedIdentityKeys {
    param(
        $UpdateGroups,
        [int[]]$CheckedIndexes
    )

    $groups = @($UpdateGroups)
    $checked = @{}
    foreach ($index in @($CheckedIndexes)) {
        $checked[[int]$index] = $true
    }

    # Iterate over the groups, not over the checks: key order must follow group order,
    # whatever order the control happens to report its checked indices in.
    $keys = @()
    for ($i = 0; $i -lt $groups.Count; $i++) {
        if ($checked.ContainsKey($i)) {
            $keys += [string]$groups[$i].identityKey
        }
    }

    return @($keys)
}


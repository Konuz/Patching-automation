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
        if (-not $Store.ContainsKey($key.StoreKey)) {
            continue
        }

        foreach ($member in @($key.Members)) {
            $map[$member] = $Store[$key.StoreKey]
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

    $settings.VIServers = @(Get-ObjectPropertyValue -InputObject $raw -Path @('VIServers'))
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

    return @(@(Get-CredentialStoreKeys -Scope $Scope -TargetNames $TargetNames) | Where-Object { -not $Store.ContainsKey($_.StoreKey) })
}

function Write-CredentialStore {
    param(
        [string]$Path,
        [hashtable]$Credentials
    )

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

    $payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-CredentialStore {
    param([string]$Path)

    $warnings = New-Object System.Collections.Generic.List[string]
    $credentials = @{}

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Credentials = $credentials; Warnings = @($warnings) }
    }

    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        [void]$warnings.Add(('Credential file could not be read ({0}); no stored credentials are available.' -f $_.Exception.Message))
        return [pscustomobject]@{ Credentials = $credentials; Warnings = @($warnings) }
    }

    foreach ($property in @($raw.PSObject.Properties)) {
        $storeKey = [string]$property.Name
        $userName = [string](Get-ObjectPropertyValue -InputObject $property.Value -Path @('UserName'))
        $protected = [string](Get-ObjectPropertyValue -InputObject $property.Value -Path @('Password'))

        if ([string]::IsNullOrWhiteSpace($userName) -or [string]::IsNullOrWhiteSpace($protected)) {
            [void]$warnings.Add(('Stored credential "{0}" is incomplete and was ignored.' -f $storeKey))
            continue
        }

        # DPAPI is bound to the Windows account and machine. A rebuilt profile or a different
        # account raises CryptographicException here, not an XML error - and that is a real
        # scenario, so catch broadly and degrade to a prompt for this one key.
        try {
            $secure = ConvertTo-SecureString -String $protected
            $credentials[$storeKey] = New-Object System.Management.Automation.PSCredential($userName, $secure)
        }
        catch {
            [void]$warnings.Add(('Stored credential "{0}" could not be decrypted on this account and will be requested again.' -f $storeKey))
        }
    }

    return [pscustomobject]@{ Credentials = $credentials; Warnings = @($warnings) }
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


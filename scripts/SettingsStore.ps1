Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMTargetLib.ps1')

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

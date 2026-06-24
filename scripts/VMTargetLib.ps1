function Get-UniqueTrimmedNames {
    param(
        [string[]]$Names
    )

    $uniqueNames = @()
    $seenNames = @{}
    foreach ($name in @($Names)) {
        $nameText = ([string]$name).Trim()
        if ([string]::IsNullOrWhiteSpace($nameText)) {
            continue
        }

        if (-not $seenNames.ContainsKey($nameText)) {
            $seenNames[$nameText] = $true
            $uniqueNames += $nameText
        }
    }

    return $uniqueNames
}

function Split-VMNameInput {
    param(
        [string]$InputText
    )

    return @(Get-UniqueTrimmedNames -Names ($InputText -split '[,;]'))
}

function Resolve-VMTargetNamesFromSources {
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

    return @(Get-UniqueTrimmedNames -Names $targets)
}

function Get-GuestCredentialGroups {
    param(
        [string[]]$TargetNames
    )

    $domainOrder = @()
    $domainMembers = @{}
    $locals = @()

    foreach ($name in @($TargetNames)) {
        $trimmed = ([string]$name).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        $parts = $trimmed -split '\.', 2
        if (@($parts).Count -eq 2 -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
            $domainKey = $parts[1].ToLowerInvariant()
            if (-not $domainMembers.ContainsKey($domainKey)) {
                $domainMembers[$domainKey] = New-Object System.Collections.Generic.List[string]
                $domainOrder += $domainKey
            }

            [void]$domainMembers[$domainKey].Add($trimmed)
        }
        else {
            $locals += $trimmed
        }
    }

    $groups = @()
    foreach ($domainKey in ($domainOrder | Sort-Object)) {
        $groups += [pscustomobject]@{
            Kind    = 'Domain'
            Key     = $domainKey
            Domain  = $domainKey
            Members = @($domainMembers[$domainKey].ToArray())
        }
    }

    foreach ($local in ($locals | Sort-Object)) {
        $groups += [pscustomobject]@{
            Kind    = 'Local'
            Key     = $local
            Domain  = $null
            Members = @($local)
        }
    }

    return @($groups)
}

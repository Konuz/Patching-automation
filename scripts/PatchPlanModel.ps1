Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-ModelPropertyValue {
    param(
        $InputObject,
        [string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }

        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Test-ModelPropertyExists {
    param(
        $InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $false
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject.Contains($Name)
    }

    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function New-UpdateIdentityKey {
    param(
        [string]$UpdateId,
        [int]$RevisionNumber
    )

    if ([string]::IsNullOrWhiteSpace($UpdateId)) {
        throw 'UpdateId is required to build an update identity key.'
    }

    if ($RevisionNumber -lt 0) {
        throw 'RevisionNumber must be greater than or equal to 0.'
    }

    return ('{0}|{1}' -f $UpdateId, $RevisionNumber)
}

function Get-UpdateIdentityKey {
    param($Update)

    $identityKey = [string](Get-ModelPropertyValue -InputObject $Update -Name 'identityKey')
    $hasUpdateId = Test-ModelPropertyExists -InputObject $Update -Name 'updateId'
    $hasRevisionNumber = Test-ModelPropertyExists -InputObject $Update -Name 'revisionNumber'

    if ($hasUpdateId -or $hasRevisionNumber) {
        if (-not $hasUpdateId -or -not $hasRevisionNumber) {
            throw 'Update identity requires both updateId and revisionNumber when either field is supplied.'
        }

        $revisionNumber = Get-ModelPropertyValue -InputObject $Update -Name 'revisionNumber'
        if ([string]::IsNullOrWhiteSpace([string]$revisionNumber)) {
            throw 'RevisionNumber is required to build an update identity key.'
        }

        $computedIdentityKey = New-UpdateIdentityKey -UpdateId ([string](Get-ModelPropertyValue -InputObject $Update -Name 'updateId')) -RevisionNumber ([int]$revisionNumber)
        if (-not [string]::IsNullOrWhiteSpace($identityKey) -and $identityKey -ne $computedIdentityKey) {
            throw ('Update identity key drift detected. Expected {0}; actual {1}.' -f $computedIdentityKey, $identityKey)
        }

        return $computedIdentityKey
    }

    if (-not [string]::IsNullOrWhiteSpace($identityKey)) {
        return $identityKey
    }

    return New-UpdateIdentityKey -UpdateId ([string](Get-ModelPropertyValue -InputObject $Update -Name 'updateId')) -RevisionNumber ([int](Get-ModelPropertyValue -InputObject $Update -Name 'revisionNumber' -DefaultValue 0))
}

function Get-UpdateKbText {
    param($KbArticleIds)

    $kbValues = @()
    foreach ($kbArticleId in @($KbArticleIds)) {
        $kbText = ([string]$kbArticleId).Trim()
        if ([string]::IsNullOrWhiteSpace($kbText)) {
            continue
        }

        if ($kbText -notmatch '(?i)^KB') {
            $kbText = 'KB{0}' -f $kbText
        }

        $kbValues += $kbText
    }

    if ($kbValues.Count -eq 0) {
        return ''
    }

    return ($kbValues -join ',')
}

function Get-DefaultUpdateSelection {
    param(
        [string]$Title,
        [string[]]$Categories = @()
    )

    $text = ('{0} {1}' -f $Title, (@($Categories) -join ' '))

    if ($text -match '(?i)\bpreview\b') {
        return $false
    }

    if ($text -match '(?i)\bdrivers?\b') {
        return $false
    }

    if ($text -match '(?i)feature update') {
        return $false
    }

    if ($text -match '(?i)browse[- ]only|optional') {
        return $false
    }

    if ($text -match '(?i)cumulative|security|critical|update rollup|malicious software removal tool') {
        return $true
    }

    return $false
}

function Get-RoleFlagText {
    param($RoleFlags)

    if ($null -eq $RoleFlags) {
        return 'unknown'
    }

    $detected = @(Get-ModelPropertyValue -InputObject $RoleFlags -Name 'detected' -DefaultValue @() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($detected.Count -eq 0) {
        return 'none'
    }

    return ($detected -join ', ')
}

function Test-IsFailoverClusterDiscoveryRecord {
    param($DiscoveryRecord)

    $roleFlags = Get-ModelPropertyValue -InputObject $DiscoveryRecord -Name 'roleFlags'
    if ($null -eq $roleFlags) {
        return $false
    }

    return [bool](Get-ModelPropertyValue -InputObject $roleFlags -Name 'failoverCluster' -DefaultValue $false)
}

function New-UpdatePlanRecord {
    param(
        $Update,
        [string]$IdentityKey
    )

    $kbArticleIds = @(Get-ModelPropertyValue -InputObject $Update -Name 'kbArticleIds' -DefaultValue @())
    $categories = @(Get-ModelPropertyValue -InputObject $Update -Name 'categories' -DefaultValue @())

    return [pscustomobject]@{
        identityKey = $IdentityKey
        updateId = Get-ModelPropertyValue -InputObject $Update -Name 'updateId'
        revisionNumber = Get-ModelPropertyValue -InputObject $Update -Name 'revisionNumber'
        title = Get-ModelPropertyValue -InputObject $Update -Name 'title'
        kbArticleIds = $kbArticleIds
        kbText = Get-UpdateKbText -KbArticleIds $kbArticleIds
        categories = $categories
    }
}

function New-UpdateGroupRecords {
    param($DiscoveryRecords)

    $groups = @{}
    $orderedKeys = New-Object System.Collections.Generic.List[string]

    foreach ($discoveryRecord in @($DiscoveryRecords)) {
        if ($null -eq $discoveryRecord) {
            continue
        }

        $vmName = [string](Get-ModelPropertyValue -InputObject $discoveryRecord -Name 'vmName')
        $isFailoverCluster = Test-IsFailoverClusterDiscoveryRecord -DiscoveryRecord $discoveryRecord
        $updates = Get-ModelPropertyValue -InputObject $discoveryRecord -Name 'updates' -DefaultValue @()

        foreach ($update in @($updates)) {
            if ($null -eq $update) {
                continue
            }

            $identityKey = Get-UpdateIdentityKey -Update $update
            if (-not $groups.ContainsKey($identityKey)) {
                $title = Get-ModelPropertyValue -InputObject $update -Name 'title'
                $categories = @(Get-ModelPropertyValue -InputObject $update -Name 'categories' -DefaultValue @())
                $kbArticleIds = @(Get-ModelPropertyValue -InputObject $update -Name 'kbArticleIds' -DefaultValue @())

                $groups[$identityKey] = [pscustomobject]@{
                    identityKey = $identityKey
                    updateId = Get-ModelPropertyValue -InputObject $update -Name 'updateId'
                    revisionNumber = Get-ModelPropertyValue -InputObject $update -Name 'revisionNumber'
                    title = $title
                    kbArticleIds = $kbArticleIds
                    kbText = Get-UpdateKbText -KbArticleIds $kbArticleIds
                    categories = $categories
                    selectedByDefault = Get-DefaultUpdateSelection -Title ([string]$title) -Categories $categories
                    appliesToVmNames = New-Object System.Collections.Generic.List[string]
                    patchableVmNames = New-Object System.Collections.Generic.List[string]
                    appliesToVmLookup = @{}
                    patchableVmLookup = @{}
                    updateRecords = New-Object System.Collections.Generic.List[object]
                }
                [void]$orderedKeys.Add($identityKey)
            }

            $group = $groups[$identityKey]
            [void]$group.updateRecords.Add((New-UpdatePlanRecord -Update $update -IdentityKey $identityKey))

            if (-not $group.appliesToVmLookup.ContainsKey($vmName)) {
                $group.appliesToVmLookup[$vmName] = $true
                [void]$group.appliesToVmNames.Add($vmName)
            }

            if (-not $isFailoverCluster -and -not $group.patchableVmLookup.ContainsKey($vmName)) {
                $group.patchableVmLookup[$vmName] = $true
                [void]$group.patchableVmNames.Add($vmName)
            }
        }
    }

    $records = @()
    foreach ($identityKey in @($orderedKeys)) {
        $group = $groups[$identityKey]
        $appliesToVmNames = @($group.appliesToVmNames.ToArray())
        $patchableVmNames = @($group.patchableVmNames.ToArray())

        $records += [pscustomobject]@{
            identityKey = $group.identityKey
            updateId = $group.updateId
            revisionNumber = $group.revisionNumber
            title = $group.title
            kbArticleIds = @($group.kbArticleIds)
            kbText = $group.kbText
            categories = @($group.categories)
            selectedByDefault = [bool]$group.selectedByDefault
            appliesToVmNames = $appliesToVmNames
            patchableVmNames = $patchableVmNames
            appliesToVmCount = $appliesToVmNames.Count
            patchableVmCount = $patchableVmNames.Count
            updateRecords = @($group.updateRecords.ToArray())
        }
    }

    return @($records)
}

function New-PatchPlanRecords {
    param(
        $DiscoveryRecords,
        [string[]]$SelectedUpdateKeys = @()
    )

    $selectedKeyLookup = @{}
    foreach ($selectedUpdateKey in @($SelectedUpdateKeys)) {
        if ([string]::IsNullOrWhiteSpace([string]$selectedUpdateKey)) {
            continue
        }

        $selectedKeyLookup[[string]$selectedUpdateKey] = $true
    }

    $records = @()
    foreach ($discoveryRecord in @($DiscoveryRecords)) {
        if ($null -eq $discoveryRecord) {
            continue
        }

        $vmName = Get-ModelPropertyValue -InputObject $discoveryRecord -Name 'vmName'
        $computerName = Get-ModelPropertyValue -InputObject $discoveryRecord -Name 'computerName'
        $roleFlags = Get-ModelPropertyValue -InputObject $discoveryRecord -Name 'roleFlags'
        $selectedUpdates = @()

        if (Test-IsFailoverClusterDiscoveryRecord -DiscoveryRecord $discoveryRecord) {
            $records += [pscustomobject]@{
                vmName = $vmName
                computerName = $computerName
                action = 'Skip'
                reason = 'Skipped: Failover Cluster detected. Please update manually one by one.'
                roleFlags = $roleFlags
                selectedUpdates = @()
            }
            continue
        }

        $updates = Get-ModelPropertyValue -InputObject $discoveryRecord -Name 'updates' -DefaultValue @()
        foreach ($update in @($updates)) {
            if ($null -eq $update) {
                continue
            }

            $identityKey = Get-UpdateIdentityKey -Update $update
            if ($selectedKeyLookup.ContainsKey($identityKey)) {
                $selectedUpdates += New-UpdatePlanRecord -Update $update -IdentityKey $identityKey
            }
        }

        if ($selectedUpdates.Count -eq 0) {
            $records += [pscustomobject]@{
                vmName = $vmName
                computerName = $computerName
                action = 'NoSelectedUpdates'
                reason = 'No selected updates apply.'
                roleFlags = $roleFlags
                selectedUpdates = @()
            }
            continue
        }

        $records += [pscustomobject]@{
            vmName = $vmName
            computerName = $computerName
            action = 'Install'
            reason = ''
            roleFlags = $roleFlags
            selectedUpdates = @($selectedUpdates)
        }
    }

    return @($records)
}

function ConvertTo-PatchSummaryRows {
    param($PatchPlanRecords)

    $rows = @()
    foreach ($patchPlanRecord in @($PatchPlanRecords)) {
        if ($null -eq $patchPlanRecord) {
            continue
        }

        $selectedUpdates = @(Get-ModelPropertyValue -InputObject $patchPlanRecord -Name 'selectedUpdates' -DefaultValue @())

        $rows += [pscustomobject]@{
            VMName = Get-ModelPropertyValue -InputObject $patchPlanRecord -Name 'vmName'
            ComputerName = Get-ModelPropertyValue -InputObject $patchPlanRecord -Name 'computerName'
            Action = Get-ModelPropertyValue -InputObject $patchPlanRecord -Name 'action'
            Reason = Get-ModelPropertyValue -InputObject $patchPlanRecord -Name 'reason'
            RoleFlags = Get-RoleFlagText -RoleFlags (Get-ModelPropertyValue -InputObject $patchPlanRecord -Name 'roleFlags')
            SelectedUpdateCount = $selectedUpdates.Count
        }
    }

    return @($rows)
}

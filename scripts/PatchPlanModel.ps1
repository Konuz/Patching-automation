Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'guest\UpdateIdentity.ps1')

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

function Get-UpdateIdentityKey {
    param($Update)

    $identityKey = [string](Get-ModelPropertyValue -InputObject $Update -Name 'identityKey')
    $hasUpdateId = Test-ModelPropertyExists -InputObject $Update -Name 'updateId'
    $hasRevisionNumber = Test-ModelPropertyExists -InputObject $Update -Name 'revisionNumber'

    if ($hasUpdateId -or $hasRevisionNumber) {
        if (-not $hasUpdateId -or -not $hasRevisionNumber) {
            throw 'Update identity requires both updateId and revisionNumber when either field is supplied.'
        }

        $updateIdValue = [string](Get-ModelPropertyValue -InputObject $Update -Name 'updateId')
        $revisionNumber = Get-ModelPropertyValue -InputObject $Update -Name 'revisionNumber'
        $revisionIsBlank = [string]::IsNullOrWhiteSpace([string]$revisionNumber)

        # The guest agent records updateId/revisionNumber as $null when the WUA COM
        # Identity read fails (Run-LocalPatch.ps1 New-UpdateRecord catch branch). Such an
        # update cannot be grouped or selected by identity; report it as keyless (callers
        # skip it) instead of throwing and aborting planning for the whole batch.
        if ([string]::IsNullOrWhiteSpace($updateIdValue) -and $revisionIsBlank) {
            return $null
        }

        if ($revisionIsBlank) {
            throw 'RevisionNumber is required to build an update identity key.'
        }

        $computedIdentityKey = New-CanonicalUpdateIdentityKey -UpdateId $updateIdValue -RevisionNumber $revisionNumber
        if (-not [string]::IsNullOrWhiteSpace($identityKey) -and $identityKey -ne $computedIdentityKey) {
            throw ('Update identity key drift detected. Expected {0}; actual {1}.' -f $computedIdentityKey, $identityKey)
        }

        return $computedIdentityKey
    }

    if (-not [string]::IsNullOrWhiteSpace($identityKey)) {
        return $identityKey
    }

    return New-CanonicalUpdateIdentityKey -UpdateId ([string](Get-ModelPropertyValue -InputObject $Update -Name 'updateId')) -RevisionNumber (Get-ModelPropertyValue -InputObject $Update -Name 'revisionNumber' -DefaultValue 0)
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
        [string[]]$Categories = @(),
        [string]$MsrcSeverity,
        [string]$UpdateType
    )

    $text = ('{0} {1}' -f $Title, (@($Categories) -join ' '))

    # Exclusions first — these veto selection regardless of MSRC severity.
    if ([string]$UpdateType -match '(?i)^(driver|2)$') {
        return $false
    }

    if ($text -match '(?i)\bpreview\b') {
        return $false
    }

    if ($text -match '(?i)\bdrivers?\b') {
        return $false
    }

    if ($text -match '(?i)feature update') {
        return $false
    }

    if ($text -match '(?i)browse[- ]only|\boptional\b') {
        return $false
    }

    # Structured inclusion — selected MSRC severity, after exclusions have had their say.
    if ([string]$MsrcSeverity -match '(?i)^(critical|important)$') {
        return $true
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
    $msrcSeverity = Get-ModelPropertyValue -InputObject $Update -Name 'msrcSeverity'
    $updateType = Get-ModelPropertyValue -InputObject $Update -Name 'updateType'

    return [pscustomobject]@{
        identityKey = $IdentityKey
        updateId = Get-ModelPropertyValue -InputObject $Update -Name 'updateId'
        revisionNumber = Get-ModelPropertyValue -InputObject $Update -Name 'revisionNumber'
        title = Get-ModelPropertyValue -InputObject $Update -Name 'title'
        kbArticleIds = $kbArticleIds
        kbText = Get-UpdateKbText -KbArticleIds $kbArticleIds
        categories = $categories
        msrcSeverity = $msrcSeverity
        updateType = $updateType
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
            if ([string]::IsNullOrWhiteSpace($identityKey)) {
                Write-Warning ('Skipping update without a resolvable identity key on VM {0}: {1}' -f $vmName, [string](Get-ModelPropertyValue -InputObject $update -Name 'title'))
                continue
            }

            if (-not $groups.ContainsKey($identityKey)) {
                $title = Get-ModelPropertyValue -InputObject $update -Name 'title'
                $categories = @(Get-ModelPropertyValue -InputObject $update -Name 'categories' -DefaultValue @())
                $kbArticleIds = @(Get-ModelPropertyValue -InputObject $update -Name 'kbArticleIds' -DefaultValue @())
                $msrcSeverity = Get-ModelPropertyValue -InputObject $update -Name 'msrcSeverity'
                $updateType = Get-ModelPropertyValue -InputObject $update -Name 'updateType'

                $groups[$identityKey] = [pscustomobject]@{
                    identityKey = $identityKey
                    updateId = Get-ModelPropertyValue -InputObject $update -Name 'updateId'
                    revisionNumber = Get-ModelPropertyValue -InputObject $update -Name 'revisionNumber'
                    title = $title
                    kbArticleIds = $kbArticleIds
                    kbText = Get-UpdateKbText -KbArticleIds $kbArticleIds
                    categories = $categories
                    msrcSeverity = $msrcSeverity
                    updateType = $updateType
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

        # Only preselect a group the default policy wants AND that has at least one
        # patchable VM. A group whose sole applicable VM is a Failover Cluster (excluded
        # from patchableVmNames) would otherwise show a checked box with "Patchable: 0 VM"
        # and produce a default plan that installs on nothing.
        $selectedByDefault = ([bool](Get-DefaultUpdateSelection -Title ([string]$group.title) -Categories $group.categories -MsrcSeverity ([string]$group.msrcSeverity) -UpdateType ([string]$group.updateType))) -and ($patchableVmNames.Count -gt 0)

        $records += [pscustomobject]@{
            identityKey = $group.identityKey
            updateId = $group.updateId
            revisionNumber = $group.revisionNumber
            title = $group.title
            kbArticleIds = @($group.kbArticleIds)
            kbText = $group.kbText
            categories = @($group.categories)
            msrcSeverity = $group.msrcSeverity
            updateType = $group.updateType
            selectedByDefault = $selectedByDefault
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
            if ([string]::IsNullOrWhiteSpace($identityKey)) {
                continue
            }

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

function Test-IsDiscoveryFailurePatchPlanRecord {
    param($PatchPlanRecord)

    $action = [string](Get-ModelPropertyValue -InputObject $PatchPlanRecord -Name 'action')
    $reason = [string](Get-ModelPropertyValue -InputObject $PatchPlanRecord -Name 'reason')

    return ($action -eq 'Skip' -and $reason -eq 'Skipped: Discovery failed. Review discovery.json and per-VM agent artifacts.')
}

function Get-PlanOnlyExitCode {
    param($PatchPlanRecords)

    $discoveryFailureRecords = @($PatchPlanRecords | Where-Object { Test-IsDiscoveryFailurePatchPlanRecord -PatchPlanRecord $_ })
    if ($discoveryFailureRecords.Count -gt 0) {
        return 1
    }

    return 0
}

function ConvertTo-PatchPlanRecords {
    param($InputObject)

    $records = @()
    foreach ($record in @($InputObject)) {
        if ($null -eq $record) {
            continue
        }

        $selectedUpdates = @()
        foreach ($selectedUpdate in @(Get-ModelPropertyValue -InputObject $record -Name 'selectedUpdates' -DefaultValue @())) {
            if ($null -eq $selectedUpdate) {
                continue
            }

            $identityKey = [string](Get-ModelPropertyValue -InputObject $selectedUpdate -Name 'identityKey')
            if ([string]::IsNullOrWhiteSpace($identityKey)) {
                Write-Warning ('Skipping a selected update without an identityKey while loading the saved patch plan for VM {0}.' -f [string](Get-ModelPropertyValue -InputObject $record -Name 'vmName'))
                continue
            }

            $selectedUpdates += [pscustomobject]@{
                identityKey = $identityKey
                updateId = Get-ModelPropertyValue -InputObject $selectedUpdate -Name 'updateId'
                revisionNumber = Get-ModelPropertyValue -InputObject $selectedUpdate -Name 'revisionNumber'
                title = Get-ModelPropertyValue -InputObject $selectedUpdate -Name 'title'
                kbArticleIds = @(Get-ModelPropertyValue -InputObject $selectedUpdate -Name 'kbArticleIds' -DefaultValue @())
                kbText = Get-ModelPropertyValue -InputObject $selectedUpdate -Name 'kbText'
                categories = @(Get-ModelPropertyValue -InputObject $selectedUpdate -Name 'categories' -DefaultValue @())
                msrcSeverity = Get-ModelPropertyValue -InputObject $selectedUpdate -Name 'msrcSeverity'
                updateType = Get-ModelPropertyValue -InputObject $selectedUpdate -Name 'updateType'
            }
        }

        $records += [pscustomobject]@{
            vmName = Get-ModelPropertyValue -InputObject $record -Name 'vmName'
            computerName = Get-ModelPropertyValue -InputObject $record -Name 'computerName'
            action = Get-ModelPropertyValue -InputObject $record -Name 'action'
            reason = Get-ModelPropertyValue -InputObject $record -Name 'reason'
            roleFlags = Get-ModelPropertyValue -InputObject $record -Name 'roleFlags'
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

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

function Get-DiscoverySummaryStatus {
    param(
        [bool]$IsSuccessful,
        [int]$AvailableUpdateCount,
        [bool]$HasErrors
    )

    if ($HasErrors -or -not $IsSuccessful) {
        return 'Failed'
    }

    if ($AvailableUpdateCount -gt 0) {
        return 'UpdatesFound'
    }

    return 'UpToDate'
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

# WUA update classification GUIDs. Stable across languages and Windows versions - unlike the
# category NAMES, which are localised, and unlike the title, which is localised too. These three
# are the only classifications this tool selects on its own.
$script:UpdatePolicyCategoryIds = @{
    SecurityUpdates = '0fa1201d-4330-4fa8-8ae9-b877473b6441'
    CriticalUpdates = 'e6cf1350-c01b-414d-a61f-263d14d133b4'
    UpdateRollups   = '28bc880e-0592-4cbf-8f95-c79b17911d5f'
}

# Two packages that are selected by KB id rather than classification. The KB id is stable; the
# title is not (MSRT and the Defender signatures are both localised).
$script:UpdatePolicyKbIds = @{
    MalicousSoftwareRemovalTool = '890830'
    DefenderSignatures          = '2267602'
}

function Test-UpdatePolicyKbMatch {
    param(
        [string[]]$KbArticleIds = @(),
        [string]$KbId
    )

    foreach ($candidate in @($KbArticleIds)) {
        $text = ([string]$candidate).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }
        if ($text -match ('^(?i:KB)?{0}$' -f [regex]::Escape($KbId))) {
            return $true
        }
    }

    return $false
}

function Test-UpdatePolicyCategoryMatch {
    param(
        [string[]]$CategoryIds = @(),
        [string]$CategoryId
    )

    foreach ($candidate in @($CategoryIds)) {
        $text = ([string]$candidate).Trim().Trim('{', '}')
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }
        if ([string]::Equals($text, $CategoryId, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-UpdatePolicyDecision {
    param($Update)

    # Include / Exclude / NeedsReview, decided on structured WUA metadata only.
    #
    # The rule this replaces read the title and the category NAMES, which are localised: the same
    # package was selected on an English guest and skipped on a German or Polish one, and a title
    # containing the word "Security" in any product name was selected whatever it actually was.
    # There is no honest way to keep the title heuristics and still call the result structural,
    # so they are gone - and the price is admitted rather than hidden: a package this tool cannot
    # classify from its metadata becomes NeedsReview and waits for an operator, instead of being
    # quietly guessed at in either direction.
    $updateType = [string](Get-ModelPropertyValue -InputObject $Update -Name 'updateType')
    $msrcSeverity = [string](Get-ModelPropertyValue -InputObject $Update -Name 'msrcSeverity')
    $categoryIds = @(Get-ModelPropertyValue -InputObject $Update -Name 'categoryIds' -DefaultValue @())
    $kbArticleIds = @(Get-ModelPropertyValue -InputObject $Update -Name 'kbArticleIds' -DefaultValue @())
    $browseOnlyValue = Get-ModelPropertyValue -InputObject $Update -Name 'browseOnly'

    # 1. Drivers are out. WUA's Type is 2 for a driver; the name form is what discovery writes.
    if ($updateType -match '(?i)^(driver|2)$') {
        return [pscustomobject]@{ Decision = 'Exclude'; Reason = 'Driver updates are never selected automatically.' }
    }

    # 2. BrowseOnly is WUA's own "do not offer this automatically" flag, and it is the closest
    #    thing to a structured preview marker. It is NOT a guarantee that every preview package
    #    carries it - see NeedsReview below - but where it is set, it decides.
    if ($null -ne $browseOnlyValue -and [bool]$browseOnlyValue) {
        return [pscustomobject]@{ Decision = 'Exclude'; Reason = 'WUA marks this update BrowseOnly, so it is not offered automatically.' }
    }

    # 3. The two packages selected by KB id rather than classification.
    if (Test-UpdatePolicyKbMatch -KbArticleIds $kbArticleIds -KbId $script:UpdatePolicyKbIds.MalicousSoftwareRemovalTool) {
        return [pscustomobject]@{ Decision = 'Include'; Reason = 'Malicious Software Removal Tool (KB890830).' }
    }

    if (Test-UpdatePolicyKbMatch -KbArticleIds $kbArticleIds -KbId $script:UpdatePolicyKbIds.DefenderSignatures) {
        return [pscustomobject]@{ Decision = 'Include'; Reason = 'Microsoft Defender security intelligence update (KB2267602).' }
    }

    # 4. Classification GUIDs, for software updates with usable metadata.
    foreach ($categoryName in @('SecurityUpdates', 'CriticalUpdates', 'UpdateRollups')) {
        if (Test-UpdatePolicyCategoryMatch -CategoryIds $categoryIds -CategoryId $script:UpdatePolicyCategoryIds[$categoryName]) {
            return [pscustomobject]@{ Decision = 'Include'; Reason = ('Classification {0}.' -f $categoryName) }
        }
    }

    # 5. MSRC severity, when WUA supplies it. A severity is only meaningful on a software update,
    #    and drivers and BrowseOnly packages have already been excluded above.
    if ($msrcSeverity -match '(?i)^(critical|important)$') {
        return [pscustomobject]@{ Decision = 'Include'; Reason = ('MSRC severity {0}.' -f $msrcSeverity) }
    }

    # 6. Nothing structural said yes and nothing structural said no. Two different situations end
    #    here and both need an operator rather than a guess:
    #      - the metadata is missing (no classification GUIDs at all, no severity, no BrowseOnly),
    #        so this tool cannot tell a cumulative rollup from a preview build;
    #      - the metadata is present and simply is not one of the classifications this tool
    #        installs on its own - Updates, FeaturePacks, Upgrades, ServicePacks, Tools.
    #    Widening the include list to cover the old "cumulative" title regex would sweep in
    #    feature updates and upgrades, which is worse than asking.
    if (@($categoryIds).Count -eq 0 -and [string]::IsNullOrWhiteSpace($msrcSeverity) -and $null -eq $browseOnlyValue) {
        return [pscustomobject]@{ Decision = 'NeedsReview'; Reason = 'WUA supplied no classification, severity or BrowseOnly flag for this update.' }
    }

    return [pscustomobject]@{ Decision = 'NeedsReview'; Reason = 'This update is not in a classification this tool installs without being asked.' }
}

function Get-DefaultUpdateSelection {
    param($Update)

    # Only an explicit Include preselects. NeedsReview stays unticked, but it is not the same as
    # Exclude and the completion model must not treat it as one - see Get-VMPatchCompletionStates.
    return ((Get-UpdatePolicyDecision -Update $Update).Decision -eq 'Include')
}

function Get-UpdateGroupPolicyMarker {
    param($UpdateGroup)

    # A group the policy could not classify must LOOK different in the list. Leaving it as a
    # plain empty checkbox is what turns "nobody decided" into "the default said no", and an
    # unticked box is only a decision if the operator could see there was something to decide.
    if ([string](Get-ModelPropertyValue -InputObject $UpdateGroup -Name 'policyDecision') -eq 'NeedsReview') {
        return 'NEEDS REVIEW'
    }

    return ''
}

function Get-UpdateGroupDisplayTitle {
    param($UpdateGroup)

    $title = [string](Get-ModelPropertyValue -InputObject $UpdateGroup -Name 'title')
    $marker = Get-UpdateGroupPolicyMarker -UpdateGroup $UpdateGroup
    if ([string]::IsNullOrWhiteSpace($marker)) {
        return $title
    }

    return ('[{0}] {1}' -f $marker, $title)
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
        # Names stay for display; the ids are what the policy decides on, and browseOnly keeps
        # its three-valued shape - a missing answer is not $false.
        categoryIds = @(Get-ModelPropertyValue -InputObject $Update -Name 'categoryIds' -DefaultValue @())
        browseOnly = Get-ModelPropertyValue -InputObject $Update -Name 'browseOnly'
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
                $categoryIds = @(Get-ModelPropertyValue -InputObject $update -Name 'categoryIds' -DefaultValue @())
                $browseOnly = Get-ModelPropertyValue -InputObject $update -Name 'browseOnly'

                $groups[$identityKey] = [pscustomobject]@{
                    identityKey = $identityKey
                    updateId = Get-ModelPropertyValue -InputObject $update -Name 'updateId'
                    revisionNumber = Get-ModelPropertyValue -InputObject $update -Name 'revisionNumber'
                    title = $title
                    kbArticleIds = $kbArticleIds
                    kbText = Get-UpdateKbText -KbArticleIds $kbArticleIds
                    categories = $categories
                    categoryIds = $categoryIds
                    browseOnly = $browseOnly
                    msrcSeverity = $msrcSeverity
                    updateType = $updateType
                    policyConflict = $false
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

            # One identity key, several VMs. If two of them describe the same package with
            # different structured metadata, the group cannot be classified: taking the first
            # record would make the decision depend on the order the VM list happens to be in,
            # and OR-ing them would silently pick whichever answer is more permissive.
            $memberCategoryIds = @(Get-ModelPropertyValue -InputObject $update -Name 'categoryIds' -DefaultValue @())
            $memberBrowseOnly = Get-ModelPropertyValue -InputObject $update -Name 'browseOnly'
            $memberSeverity = [string](Get-ModelPropertyValue -InputObject $update -Name 'msrcSeverity')
            $memberType = [string](Get-ModelPropertyValue -InputObject $update -Name 'updateType')
            $conflicts = (
                ((@($memberCategoryIds) -join '|') -ne (@($group.categoryIds) -join '|')) -or
                ([string]$memberBrowseOnly -ne [string]$group.browseOnly) -or
                (-not [string]::Equals($memberSeverity, [string]$group.msrcSeverity, [System.StringComparison]::OrdinalIgnoreCase)) -or
                (-not [string]::Equals($memberType, [string]$group.updateType, [System.StringComparison]::OrdinalIgnoreCase))
            )
            if ($conflicts) {
                $group.policyConflict = $true
            }

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
        $policyDecision = if ([bool]$group.policyConflict) {
            [pscustomobject]@{ Decision = 'NeedsReview'; Reason = 'The VMs that report this update describe it with different structured metadata.' }
        }
        else {
            Get-UpdatePolicyDecision -Update $group
        }
        $selectedByDefault = ($policyDecision.Decision -eq 'Include') -and ($patchableVmNames.Count -gt 0)

        $records += [pscustomobject]@{
            identityKey = $group.identityKey
            updateId = $group.updateId
            revisionNumber = $group.revisionNumber
            title = $group.title
            kbArticleIds = @($group.kbArticleIds)
            kbText = $group.kbText
            categories = @($group.categories)
            categoryIds = @($group.categoryIds)
            browseOnly = $group.browseOnly
            msrcSeverity = $group.msrcSeverity
            updateType = $group.updateType
            policyDecision = [string]$policyDecision.Decision
            policyReason = [string]$policyDecision.Reason
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

# Defender security intelligence updates are installed like anything else - they are cheap,
# need no reboot, and the operator can untick them. What they must not do is decide whether a
# VM is finished. WUA republishes them several times a day under a new UpdateID|RevisionNumber,
# so round N installs one revision and round N+1 discovers the next as a different group: a
# fleet that is fully patched would never reach Green and every run would exhaust MaxPatchRounds
# and exit 1. They are judged on their own schedule, not on the maintenance window.
#
# The match is on KB2267602 rather than the title, because the title is localised and a title
# rule would silently stop working on a non-English server; the English title is a backstop for
# a guest that returns no KB ids. Every id must be the definition KB, not merely one of them,
# so a package listing it alongside its own KB still counts normally. The category is not
# consulted: the agent records only its localised name, not its GUID.
#
# Defender platform, engine and cumulative Windows updates are untouched by this, and so are
# SCEP and legacy Windows Defender definitions.
function Test-IsDefenderDefinitionUpdate {
    param(
        [string]$Title,
        [string[]]$KbArticleIds = @()
    )

    $definitionKbMatches = @($KbArticleIds | Where-Object { ([string]$_).Trim() -match '^(?i:KB)?2267602$' }).Count
    if (($definitionKbMatches -gt 0) -and ($definitionKbMatches -eq @($KbArticleIds).Count)) {
        return $true
    }

    return (($Title -match '(?i)security intelligence update') -and ($Title -match '(?i)defender'))
}

function Get-VMPatchCompletionStates {
    param(
        $DiscoveryRecords,
        $UpdateGroups,
        [string[]]$DeselectedUpdateKeys = @()
    )

    # Match a deselected group both on the full identity key and on the bare updateId. The
    # key carries RevisionNumber, so WUA revising a package between rounds would otherwise
    # resurrect a group the operator already rejected and the loop would never converge.
    $deselectedLookup = @{}
    foreach ($deselectedKey in @($DeselectedUpdateKeys)) {
        $keyText = ([string]$deselectedKey).Trim()
        if ([string]::IsNullOrWhiteSpace($keyText)) {
            continue
        }

        $deselectedLookup[$keyText] = $true
        $deselectedLookup[($keyText -split '\|', 2)[0]] = $true
    }

    # Only groups the default policy would pick can keep a VM out of "green". Drivers,
    # preview and optional updates linger on a healthy server forever, so counting them
    # would mean the patch round loop never converges.
    $pendingCountByVm = @{}
    $deselectedCountByVm = @{}
    $needsReviewCountByVm = @{}
    foreach ($group in @($UpdateGroups)) {
        if ($null -eq $group) {
            continue
        }

        $identityKeyForState = [string](Get-ModelPropertyValue -InputObject $group -Name 'identityKey')
        $updateIdForState = [string](Get-ModelPropertyValue -InputObject $group -Name 'updateId')
        $resolvedByOperator = ($deselectedLookup.ContainsKey($identityKeyForState) -or (-not [string]::IsNullOrWhiteSpace($updateIdForState) -and $deselectedLookup.ContainsKey($updateIdForState)))

        # A group the policy could not classify is neither installed nor ignored: the operator
        # has to look at it. Leaving it out of the counts entirely would let a VM go Green with
        # an unclassified package still applying, which is the quiet guess this change removes.
        # Ticking it or explicitly refusing it both count as having looked.
        if ([string](Get-ModelPropertyValue -InputObject $group -Name 'policyDecision') -eq 'NeedsReview') {
            if (-not (Test-IsDefenderDefinitionUpdate -Title ([string](Get-ModelPropertyValue -InputObject $group -Name 'title')) -KbArticleIds @(Get-ModelPropertyValue -InputObject $group -Name 'kbArticleIds' -DefaultValue @()))) {
                foreach ($reviewVmName in @(Get-ModelPropertyValue -InputObject $group -Name 'patchableVmNames' -DefaultValue @())) {
                    $reviewKey = [string]$reviewVmName
                    if ([string]::IsNullOrWhiteSpace($reviewKey)) {
                        continue
                    }

                    if ($resolvedByOperator) {
                        # A refused review is a group that still applies and was deliberately not
                        # installed - the same thing as an unticked preselected group, and it has
                        # to read as GreenByOperatorChoice rather than as a clean Green.
                        if (-not $deselectedCountByVm.ContainsKey($reviewKey)) { $deselectedCountByVm[$reviewKey] = 0 }
                        $deselectedCountByVm[$reviewKey]++
                    }
                    else {
                        if (-not $needsReviewCountByVm.ContainsKey($reviewKey)) { $needsReviewCountByVm[$reviewKey] = 0 }
                        $needsReviewCountByVm[$reviewKey]++
                    }
                }
            }
        }

        if (-not [bool](Get-ModelPropertyValue -InputObject $group -Name 'selectedByDefault' -DefaultValue $false)) {
            continue
        }

        # Signatures are installed like anything else; they simply do not get a vote on whether
        # the VM is finished. Counting them either way would mean a fully patched fleet never
        # converges, because the next revision is published within hours.
        if (Test-IsDefenderDefinitionUpdate -Title ([string](Get-ModelPropertyValue -InputObject $group -Name 'title')) -KbArticleIds @(Get-ModelPropertyValue -InputObject $group -Name 'kbArticleIds' -DefaultValue @())) {
            continue
        }

        $identityKey = [string](Get-ModelPropertyValue -InputObject $group -Name 'identityKey')
        $updateIdOnly = [string](Get-ModelPropertyValue -InputObject $group -Name 'updateId')
        $isDeselected = ($deselectedLookup.ContainsKey($identityKey) -or (-not [string]::IsNullOrWhiteSpace($updateIdOnly) -and $deselectedLookup.ContainsKey($updateIdOnly)))

        foreach ($patchableVmName in @(Get-ModelPropertyValue -InputObject $group -Name 'patchableVmNames' -DefaultValue @())) {
            $vmKey = [string]$patchableVmName
            if ([string]::IsNullOrWhiteSpace($vmKey)) {
                continue
            }

            if ($isDeselected) {
                if (-not $deselectedCountByVm.ContainsKey($vmKey)) { $deselectedCountByVm[$vmKey] = 0 }
                $deselectedCountByVm[$vmKey]++
            }
            else {
                if (-not $pendingCountByVm.ContainsKey($vmKey)) { $pendingCountByVm[$vmKey] = 0 }
                $pendingCountByVm[$vmKey]++
            }
        }
    }

    $states = @()
    foreach ($discoveryRecord in @($DiscoveryRecords)) {
        if ($null -eq $discoveryRecord) {
            continue
        }

        $vmName = [string](Get-ModelPropertyValue -InputObject $discoveryRecord -Name 'vmName')
        if ([string]::IsNullOrWhiteSpace($vmName)) {
            continue
        }

        $recordErrors = @(Get-ModelPropertyValue -InputObject $discoveryRecord -Name 'errors' -DefaultValue @() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $outcome = [string](Get-ModelPropertyValue -InputObject $discoveryRecord -Name 'outcome')
        $pendingCount = if ($pendingCountByVm.ContainsKey($vmName)) { [int]$pendingCountByVm[$vmName] } else { 0 }
        $deselectedCount = if ($deselectedCountByVm.ContainsKey($vmName)) { [int]$deselectedCountByVm[$vmName] } else { 0 }
        $needsReviewCount = if ($needsReviewCountByVm.ContainsKey($vmName)) { [int]$needsReviewCountByVm[$vmName] } else { 0 }

        if (Test-IsFailoverClusterDiscoveryRecord -DiscoveryRecord $discoveryRecord) {
            $state = 'Excluded'
            $reason = 'Skipped: Failover Cluster detected. Please update manually one by one.'
        }
        elseif ($recordErrors.Count -gt 0 -or $outcome -notin @('SearchOnly', 'NoApplicableUpdates')) {
            $state = 'Failed'
            $reason = ('Discovery did not succeed (outcome {0}).' -f $outcome)
        }
        elseif ($pendingCount -gt 0) {
            $state = 'Pending'
            $reason = ('{0} selectable update group(s) still apply.' -f $pendingCount)
        }
        elseif ($needsReviewCount -gt 0) {
            # Not Green and not Pending: nothing here can be installed without someone deciding,
            # and pretending otherwise in either direction is what this state exists to prevent.
            $state = 'NeedsReview'
            $reason = ('{0} update group(s) could not be classified from WUA metadata and need an operator decision.' -f $needsReviewCount)
        }
        elseif ($deselectedCount -gt 0) {
            $state = 'GreenByOperatorChoice'
            $reason = ('{0} selectable update group(s) remain but were deselected by the operator.' -f $deselectedCount)
        }
        else {
            $state = 'Green'
            $reason = 'No selectable updates remain.'
        }

        $states += [pscustomobject]@{
            vmName = $vmName
            state = $state
            reason = $reason
            outcome = $outcome
            pendingSelectableCount = $pendingCount
            deselectedSelectableCount = $deselectedCount
            needsReviewSelectableCount = $needsReviewCount
            errors = @($recordErrors)
        }
    }

    return @($states)
}

function Get-NextRoundVMNames {
    param($CompletionStates)

    return @(@($CompletionStates) | Where-Object { [string]$_.state -eq 'Pending' } | ForEach-Object { [string]$_.vmName })
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

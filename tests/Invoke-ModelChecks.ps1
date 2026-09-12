[CmdletBinding()]
param(
    [string]$Root
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $Root) {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

. (Join-Path $Root 'scripts\PatchPlanModel.ps1')

$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    [void]$script:failures.Add($Message)
}

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        Add-Failure -Message ("{0}. Expected={1}; Actual={2}" -f $Message, $Expected, $Actual)
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        Add-Failure -Message $Message
    }
}

function Assert-Throws {
    param(
        [scriptblock]$ScriptBlock,
        [string]$Message
    )

    $threw = $false
    try {
        & $ScriptBlock | Out-Null
    }
    catch {
        $threw = $true
    }

    if (-not $threw) {
        Add-Failure -Message $Message
    }
}

Assert-Equal -Actual (New-CanonicalUpdateIdentityKey -UpdateId '11111111-1111-1111-1111-111111111111' -RevisionNumber 205) -Expected '11111111-1111-1111-1111-111111111111|205' -Message 'canonical identity helper formats update id and revision'
Assert-Equal -Actual (New-CanonicalUpdateIdentityKey -UpdateId $null -RevisionNumber $null -AllowMissing) -Expected $null -Message 'canonical identity helper returns null for fully missing identity when allowed'
Assert-Throws -ScriptBlock { New-CanonicalUpdateIdentityKey -UpdateId $null -RevisionNumber 1 } -Message 'canonical identity helper rejects missing update id in strict mode'
Assert-Throws -ScriptBlock { New-CanonicalUpdateIdentityKey -UpdateId '11111111-1111-1111-1111-111111111111' -RevisionNumber $null } -Message 'canonical identity helper rejects missing revision in strict mode'
Assert-Throws -ScriptBlock { New-CanonicalUpdateIdentityKey -UpdateId '11111111-1111-1111-1111-111111111111' -RevisionNumber -1 } -Message 'canonical identity helper rejects negative revision'

$sampleDiscovery = @(
    [pscustomobject]@{
        vmName = 'VM01'
        computerName = 'HOST01'
        outcome = 'SearchOnly'
        roleFlags = [pscustomobject]@{
            failoverCluster = $false
            detected = @('SQL')
        }
        pendingRebootBefore = [pscustomobject]@{ isPending = $false }
        updates = @(
            [pscustomobject]@{
                title = '2026-06 Cumulative Update for Windows Server'
                kbArticleIds = @('5060842')
                updateId = '11111111-1111-1111-1111-111111111111'
                revisionNumber = 205
                identityKey = '11111111-1111-1111-1111-111111111111|205'
                categories = @('Security Updates')
                msrcSeverity = 'Important'
                updateType = 'Software'
            },
            [pscustomobject]@{
                title = '2026-06 Preview Cumulative Update for Windows Server'
                kbArticleIds = @('5060821')
                updateId = '22222222-2222-2222-2222-222222222222'
                revisionNumber = 17
                identityKey = '22222222-2222-2222-2222-222222222222|17'
                categories = @('Updates')
                msrcSeverity = ''
                updateType = 'Software'
            }
        )
    },
    [pscustomobject]@{
        vmName = 'VM02'
        computerName = 'HOST02'
        outcome = 'SearchOnly'
        roleFlags = [pscustomobject]@{
            failoverCluster = $false
            detected = @()
        }
        pendingRebootBefore = [pscustomobject]@{ isPending = $true }
        updates = @(
            [pscustomobject]@{
                title = '2026-06 Cumulative Update for Windows Server'
                kbArticleIds = @('5060842')
                updateId = '11111111-1111-1111-1111-111111111111'
                revisionNumber = 205
                categories = @('Security Updates')
                msrcSeverity = 'Important'
                updateType = 'Software'
            }
        )
    },
    [pscustomobject]@{
        vmName = 'VM03'
        computerName = 'HOST03'
        outcome = 'SearchOnly'
        roleFlags = [pscustomobject]@{
            failoverCluster = $true
            detected = @('Failover Cluster')
        }
        pendingRebootBefore = [pscustomobject]@{ isPending = $false }
        updates = @(
            [pscustomobject]@{
                title = '2026-06 Cumulative Update for Windows Server'
                kbArticleIds = @('5060842')
                updateId = '11111111-1111-1111-1111-111111111111'
                revisionNumber = 205
                identityKey = '11111111-1111-1111-1111-111111111111|205'
                categories = @('Security Updates')
                msrcSeverity = 'Important'
                updateType = 'Software'
            }
        )
    }
)

$driftDiscovery = @(
    [pscustomobject]@{
        vmName = 'VM04'
        computerName = 'HOST04'
        roleFlags = [pscustomobject]@{
            failoverCluster = $false
            detected = @()
        }
        updates = @(
            [pscustomobject]@{
                title = 'Critical Update with drifted identity key'
                kbArticleIds = @('5060999')
                updateId = '44444444-4444-4444-4444-444444444444'
                revisionNumber = 9
                identityKey = '44444444-4444-4444-4444-444444444444|8'
                categories = @('Critical Updates')
                msrcSeverity = 'Important'
                updateType = 'Software'
            }
        )
    }
)

$key = New-CanonicalUpdateIdentityKey -UpdateId '11111111-1111-1111-1111-111111111111' -RevisionNumber 205
Assert-Equal -Actual $key -Expected '11111111-1111-1111-1111-111111111111|205' -Message 'identity key uses update id and revision'
Assert-Throws -ScriptBlock { New-CanonicalUpdateIdentityKey -UpdateId '' -RevisionNumber 205 } -Message 'blank update id throws'
Assert-Throws -ScriptBlock { New-CanonicalUpdateIdentityKey -UpdateId '11111111-1111-1111-1111-111111111111' -RevisionNumber -1 } -Message 'negative revision throws'

Assert-Equal -Actual (Get-UpdateKbText -KbArticleIds $null) -Expected '' -Message 'empty KB list becomes empty text'
Assert-Equal -Actual (Get-UpdateKbText -KbArticleIds @('5060842', '5060821')) -Expected 'KB5060842,KB5060821' -Message 'KB list gets KB prefixes'

Assert-True -Condition (Get-DefaultUpdateSelection -Title '2026-06 Cumulative Update for Windows Server' -Categories @('Security Updates')) -Message 'security cumulative update selected by default'
Assert-True -Condition (Get-DefaultUpdateSelection -Title 'Critical Update for Windows Server' -Categories @('Critical Updates')) -Message 'critical update selected by default'
Assert-True -Condition (Get-DefaultUpdateSelection -Title 'Update Rollup for Windows Server' -Categories @('Update Rollups')) -Message 'update rollup selected by default'
Assert-True -Condition (Get-DefaultUpdateSelection -Title 'Windows Malicious Software Removal Tool x64' -Categories @('Tools')) -Message 'MSRT selected by default'
Assert-True -Condition (-not (Get-DefaultUpdateSelection -Title '2026-06 Preview Cumulative Update for Windows Server' -Categories @('Updates'))) -Message 'preview update skipped by default'
Assert-True -Condition (-not (Get-DefaultUpdateSelection -Title 'Driver update for network adapter' -Categories @('Drivers'))) -Message 'driver update skipped by default'
Assert-True -Condition (-not (Get-DefaultUpdateSelection -Title 'Feature update to Windows Server' -Categories @('Upgrades'))) -Message 'feature update skipped by default'
Assert-True -Condition (-not (Get-DefaultUpdateSelection -Title 'Optional browse-only update' -Categories @('Updates'))) -Message 'optional browse-only update skipped by default'
Assert-True -Condition (Get-DefaultUpdateSelection -Title 'Security Update applied optionally' -Categories @('Security Updates')) -Message 'embedded optional substring does not deselect a security update'

Assert-True -Condition (Get-DefaultUpdateSelection -Title 'Localized package title' -Categories @('Updates') -MsrcSeverity 'Critical' -UpdateType 'Software') -Message 'critical MSRC severity is selected even when title is not English'
Assert-True -Condition (Get-DefaultUpdateSelection -Title 'Localized package title' -Categories @('Updates') -MsrcSeverity 'Important' -UpdateType 'Software') -Message 'important MSRC severity is selected even when title is not English'
Assert-True -Condition (-not (Get-DefaultUpdateSelection -Title 'Security-like driver title' -Categories @('Security Updates') -MsrcSeverity 'Critical' -UpdateType 'Driver')) -Message 'driver update type is skipped even when severity is critical'
Assert-True -Condition (-not (Get-DefaultUpdateSelection -Title 'Localized package title' -Categories @('Updates') -MsrcSeverity 'Critical' -UpdateType '2')) -Message 'integer driver enum value is skipped like the Driver string'
Assert-True -Condition (-not (Get-DefaultUpdateSelection -Title '2026-06 Preview Cumulative Update for Windows Server' -Categories @('Updates') -MsrcSeverity 'Critical' -UpdateType 'Software')) -Message 'critical severity does not override the preview exclusion'

# Defender security intelligence updates are ticked like anything else - they install cheaply and
# need no reboot. What they must not do is decide whether a VM is finished; that is asserted in the
# completion-state section below, not here.
Assert-Equal -Actual (Get-DefaultUpdateSelection -Title 'Security Intelligence Update for Microsoft Defender Antivirus' -Categories @('Definition Updates') -MsrcSeverity 'Critical' -UpdateType Software) -Expected $true -Message 'a Defender definition is still selected by default'
Assert-Equal -Actual (Get-DefaultUpdateSelection -Title 'Security Update for Microsoft Defender Antivirus antimalware platform' -UpdateType Software) -Expected $true -Message 'Platform security updates remain selected'

# The predicate that keeps them out of the completion count. KB2267602 is the stable identity -
# the title is localised, so a title rule would silently stop working on a non-English server.
Assert-Equal -Actual (Test-IsDefenderDefinitionUpdate -Title 'Security Intelligence Update for Microsoft Defender Antivirus' -KbArticleIds @('2267602')) -Expected $true -Message 'a Defender definition is recognised by its KB id'
Assert-Equal -Actual (Test-IsDefenderDefinitionUpdate -Title 'Aktualizacja analizy zabezpieczen dla Microsoft Defender Antivirus' -KbArticleIds @('KB2267602')) -Expected $true -Message 'KB metadata is independent of title language'
Assert-Equal -Actual (Test-IsDefenderDefinitionUpdate -Title 'Aktualizacja analizy zabezpieczen dla Microsoft Defender Antivirus' -KbArticleIds @(' kb2267602 ')) -Expected $true -Message 'a KB id with surrounding whitespace and mixed case is still recognised'
Assert-Equal -Actual (Test-IsDefenderDefinitionUpdate -Title 'Security Intelligence Update for Microsoft Defender Antivirus') -Expected $true -Message 'an English definition title is recognised even when WUA exposed no KB id'
Assert-Equal -Actual (Test-IsDefenderDefinitionUpdate -Title 'Security Update for Microsoft Defender Antivirus antimalware platform' -KbArticleIds @('4052623')) -Expected $false -Message 'the Defender platform update is not a definition'
Assert-Equal -Actual (Test-IsDefenderDefinitionUpdate -Title '2026-06 Cumulative Update for Windows Server' -KbArticleIds @('5031234')) -Expected $false -Message 'an unrelated KB id is not a definition'
Assert-Equal -Actual (Test-IsDefenderDefinitionUpdate -Title '2026-06 Cumulative Update for Windows Server' -KbArticleIds @('22676021')) -Expected $false -Message 'a KB id that merely contains the definition number is not the definition update'
Assert-Equal -Actual (Test-IsDefenderDefinitionUpdate -Title '2026-06 Cumulative Update for Windows Server' -KbArticleIds @('5031234', '2267602')) -Expected $false -Message 'a package listing the definition KB alongside its own is not the definition'
Assert-Equal -Actual (Test-IsDefenderDefinitionUpdate -Title 'Definition Update for Microsoft Endpoint Protection' -KbArticleIds @('2461484')) -Expected $false -Message 'SCEP definitions are a separate family this rule does not claim'

Assert-True -Condition (Get-DefaultUpdateSelection -Title 'Localized package title' -Categories @('Updates') -MsrcSeverity 'Critical' -UpdateType 'Software') -Message 'critical MSRC severity is selected even when title is not English'
Assert-True -Condition (Get-DefaultUpdateSelection -Title 'Localized package title' -Categories @('Updates') -MsrcSeverity 'Important' -UpdateType 'Software') -Message 'important MSRC severity is selected even when title is not English'
Assert-True -Condition (-not (Get-DefaultUpdateSelection -Title 'Security-like driver title' -Categories @('Security Updates') -MsrcSeverity 'Critical' -UpdateType 'Driver')) -Message 'driver update type is skipped even when severity is critical'
Assert-True -Condition (-not (Get-DefaultUpdateSelection -Title 'Localized package title' -Categories @('Updates') -MsrcSeverity 'Critical' -UpdateType '2')) -Message 'integer driver enum value is skipped like the Driver string'
Assert-True -Condition (-not (Get-DefaultUpdateSelection -Title '2026-06 Preview Cumulative Update for Windows Server' -Categories @('Updates') -MsrcSeverity 'Critical' -UpdateType 'Software')) -Message 'critical severity does not override the preview exclusion'

Assert-Equal -Actual (Get-RoleFlagText -RoleFlags $null) -Expected 'unknown' -Message 'missing role flags are unknown'
Assert-Equal -Actual (Get-RoleFlagText -RoleFlags ([pscustomobject]@{ detected = @() })) -Expected 'none' -Message 'empty role flags are none'
Assert-Equal -Actual (Get-RoleFlagText -RoleFlags ([pscustomobject]@{ detected = @('SQL') })) -Expected 'SQL' -Message 'detected role flags are listed'
Assert-True -Condition (Test-IsFailoverClusterDiscoveryRecord -DiscoveryRecord $sampleDiscovery[2]) -Message 'failover cluster record is detected'
Assert-True -Condition (-not (Test-IsFailoverClusterDiscoveryRecord -DiscoveryRecord $sampleDiscovery[0])) -Message 'non-cluster record is not detected'

$groups = @(New-UpdateGroupRecords -DiscoveryRecords $sampleDiscovery)
Assert-Equal -Actual $groups.Count -Expected 2 -Message 'groups by identity key'
Assert-Throws -ScriptBlock { New-UpdateGroupRecords -DiscoveryRecords $driftDiscovery } -Message 'mismatched identity key is rejected'

$cumulativeGroup = @($groups | Where-Object { $_.identityKey -eq '11111111-1111-1111-1111-111111111111|205' })[0]
Assert-Equal -Actual $cumulativeGroup.title -Expected '2026-06 Cumulative Update for Windows Server' -Message 'group keeps representative title'
Assert-Equal -Actual $cumulativeGroup.kbText -Expected 'KB5060842' -Message 'group formats KB text'
Assert-Equal -Actual $cumulativeGroup.appliesToVmCount -Expected 3 -Message 'group counts every applicable VM'
Assert-Equal -Actual $cumulativeGroup.patchableVmCount -Expected 2 -Message 'group excludes failover cluster from patchable count'
Assert-Equal -Actual (@($cumulativeGroup.appliesToVmNames) -join ',') -Expected 'VM01,VM02,VM03' -Message 'group lists applicable VM names'
Assert-Equal -Actual (@($cumulativeGroup.patchableVmNames) -join ',') -Expected 'VM01,VM02' -Message 'group lists patchable VM names'
Assert-True -Condition $cumulativeGroup.selectedByDefault -Message 'cumulative group is selected by default'

$previewGroup = @($groups | Where-Object { $_.identityKey -eq '22222222-2222-2222-2222-222222222222|17' })[0]
Assert-Equal -Actual $previewGroup.appliesToVmCount -Expected 1 -Message 'preview group applies to one VM'
Assert-True -Condition (-not $previewGroup.selectedByDefault) -Message 'preview group is not selected by default'

$plan = @(New-PatchPlanRecords -DiscoveryRecords $sampleDiscovery -SelectedUpdateKeys @('11111111-1111-1111-1111-111111111111|205'))
$vm01 = @($plan | Where-Object { $_.vmName -eq 'VM01' })[0]
$vm02 = @($plan | Where-Object { $_.vmName -eq 'VM02' })[0]
$vm03 = @($plan | Where-Object { $_.vmName -eq 'VM03' })[0]
Assert-Equal -Actual $vm01.action -Expected 'Install' -Message 'VM01 receives selected update'
Assert-Equal -Actual (@($vm01.selectedUpdates).Count) -Expected 1 -Message 'VM01 has one selected update'
Assert-Equal -Actual $vm02.action -Expected 'Install' -Message 'VM02 receives selected update despite pending reboot being informational'
Assert-Equal -Actual $vm02.selectedUpdates[0].identityKey -Expected '11111111-1111-1111-1111-111111111111|205' -Message 'VM02 missing identity key falls back to update id and revision'
Assert-Equal -Actual $vm03.action -Expected 'Skip' -Message 'cluster VM is skipped'
Assert-Equal -Actual $vm03.reason -Expected 'Skipped: Failover Cluster detected. Please update manually one by one.' -Message 'cluster skip reason is exact'

$noSelectionPlan = @(New-PatchPlanRecords -DiscoveryRecords @($sampleDiscovery[0]) -SelectedUpdateKeys @('33333333-3333-3333-3333-333333333333|1'))
Assert-Equal -Actual $noSelectionPlan[0].action -Expected 'NoSelectedUpdates' -Message 'VM with no selected applicable updates is marked'

# An update whose COM identity could not be read by the agent is recorded with
# null updateId/revisionNumber/identityKey. It must be skipped, not abort the batch.
$keylessDiscovery = @(
    [pscustomobject]@{
        vmName = 'VM05'
        computerName = 'HOST05'
        outcome = 'SearchOnly'
        roleFlags = [pscustomobject]@{
            failoverCluster = $false
            detected = @()
        }
        updates = @(
            [pscustomobject]@{
                title = 'Update with unreadable identity'
                kbArticleIds = @('5061000')
                updateId = $null
                revisionNumber = $null
                identityKey = $null
                categories = @('Security Updates')
                msrcSeverity = 'Important'
                updateType = 'Software'
            },
            [pscustomobject]@{
                title = '2026-06 Cumulative Update for Windows Server'
                kbArticleIds = @('5060842')
                updateId = '11111111-1111-1111-1111-111111111111'
                revisionNumber = 205
                identityKey = '11111111-1111-1111-1111-111111111111|205'
                categories = @('Security Updates')
                msrcSeverity = 'Important'
                updateType = 'Software'
            }
        )
    }
)

$keylessGroups = @(New-UpdateGroupRecords -DiscoveryRecords $keylessDiscovery 3>$null)
Assert-Equal -Actual $keylessGroups.Count -Expected 1 -Message 'keyless update is skipped during grouping rather than aborting'
Assert-Equal -Actual $keylessGroups[0].identityKey -Expected '11111111-1111-1111-1111-111111111111|205' -Message 'grouping keeps the keyable update'

$keylessPlan = @(New-PatchPlanRecords -DiscoveryRecords $keylessDiscovery -SelectedUpdateKeys @('11111111-1111-1111-1111-111111111111|205'))
Assert-Equal -Actual $keylessPlan[0].action -Expected 'Install' -Message 'keyless update does not abort planning; keyable update still installs'
Assert-Equal -Actual (@($keylessPlan[0].selectedUpdates).Count) -Expected 1 -Message 'only the keyable update is planned'

# A group whose only applicable VM is a Failover Cluster has zero patchable VMs and
# must not be preselected, even though the policy would otherwise select it.
$clusterOnlyDiscovery = @(
    [pscustomobject]@{
        vmName = 'VM06'
        computerName = 'HOST06'
        outcome = 'SearchOnly'
        roleFlags = [pscustomobject]@{
            failoverCluster = $true
            detected = @('Failover Cluster')
        }
        updates = @(
            [pscustomobject]@{
                title = '2026-06 Cumulative Update for Windows Server'
                kbArticleIds = @('5060842')
                updateId = '66666666-6666-6666-6666-666666666666'
                revisionNumber = 12
                identityKey = '66666666-6666-6666-6666-666666666666|12'
                categories = @('Security Updates')
                msrcSeverity = 'Important'
                updateType = 'Software'
            }
        )
    }
)

$clusterOnlyGroups = @(New-UpdateGroupRecords -DiscoveryRecords $clusterOnlyDiscovery)
Assert-Equal -Actual $clusterOnlyGroups.Count -Expected 1 -Message 'cluster-only update still forms a group'
Assert-Equal -Actual $clusterOnlyGroups[0].patchableVmCount -Expected 0 -Message 'cluster-only group has zero patchable VMs'
Assert-True -Condition (-not $clusterOnlyGroups[0].selectedByDefault) -Message 'cluster-only group is not preselected'

$discoveryFailurePlan = @(
    [pscustomobject]@{
        vmName = 'VM04'
        computerName = 'HOST04'
        action = 'Skip'
        reason = 'Skipped: Discovery failed. Review discovery.json and per-VM agent artifacts.'
        roleFlags = [pscustomobject]@{
            failoverCluster = $false
            detected = @()
        }
        selectedUpdates = @()
    }
)
Assert-Equal -Actual (Get-PlanOnlyExitCode -PatchPlanRecords $discoveryFailurePlan) -Expected 1 -Message 'PlanOnly exits non-zero for discovery failure skip'
Assert-Equal -Actual (Get-PlanOnlyExitCode -PatchPlanRecords $noSelectionPlan) -Expected 0 -Message 'PlanOnly exits zero for no selected updates'
Assert-Equal -Actual (Get-PlanOnlyExitCode -PatchPlanRecords @($vm03)) -Expected 0 -Message 'PlanOnly exits zero for failover cluster skip'

$summaryRows = @(ConvertTo-PatchSummaryRows -PatchPlanRecords $plan)
$summaryVm01 = @($summaryRows | Where-Object { $_.VMName -eq 'VM01' })[0]
$summaryVm03 = @($summaryRows | Where-Object { $_.VMName -eq 'VM03' })[0]
Assert-Equal -Actual $summaryRows.Count -Expected 3 -Message 'summary has one row per VM'
Assert-Equal -Actual $summaryVm01.ComputerName -Expected 'HOST01' -Message 'summary includes computer name'
Assert-Equal -Actual $summaryVm01.RoleFlags -Expected 'SQL' -Message 'summary includes role flags'
Assert-Equal -Actual $summaryVm01.SelectedUpdateCount -Expected 1 -Message 'summary counts selected updates'
Assert-Equal -Actual $summaryVm03.Action -Expected 'Skip' -Message 'summary includes skipped cluster action'

Assert-Equal -Actual (Get-DiscoverySummaryStatus -IsSuccessful $true -AvailableUpdateCount 0 -HasErrors $false) -Expected 'UpToDate' -Message 'discovery status: successful with zero updates is up-to-date'
Assert-Equal -Actual (Get-DiscoverySummaryStatus -IsSuccessful $true -AvailableUpdateCount 3 -HasErrors $false) -Expected 'UpdatesFound' -Message 'discovery status: successful with updates is updates-found'
Assert-Equal -Actual (Get-DiscoverySummaryStatus -IsSuccessful $false -AvailableUpdateCount 0 -HasErrors $true) -Expected 'Failed' -Message 'discovery status: errors make discovery failed'
Assert-Equal -Actual (Get-DiscoverySummaryStatus -IsSuccessful $false -AvailableUpdateCount 5 -HasErrors $false) -Expected 'Failed' -Message 'discovery status: unsuccessful outcome is failed regardless of count'

$rawPatchPlan = @(
    [pscustomobject]@{
        vmName = 'VM01'
        computerName = 'HOST01'
        action = 'Install'
        reason = ''
        roleFlags = [pscustomobject]@{
            failoverCluster = $false
            detected = @()
        }
        selectedUpdates = @(
            [pscustomobject]@{
                identityKey = '11111111-1111-1111-1111-111111111111|205'
                updateId = '11111111-1111-1111-1111-111111111111'
                revisionNumber = 205
                title = '2026-06 Cumulative Update for Windows Server'
                kbArticleIds = @('5060842')
                kbText = 'KB5060842'
                categories = @('Security Updates')
            }
        )
    }
)

$normalizedPatchPlan = @(ConvertTo-PatchPlanRecords -InputObject $rawPatchPlan)
Assert-Equal -Actual $normalizedPatchPlan.Count -Expected 1 -Message 'resume plan normalization preserves VM count'
Assert-Equal -Actual $normalizedPatchPlan[0].action -Expected 'Install' -Message 'resume plan normalization preserves action'
Assert-Equal -Actual @($normalizedPatchPlan[0].selectedUpdates).Count -Expected 1 -Message 'resume plan normalization preserves selected update array'
Assert-Equal -Actual $normalizedPatchPlan[0].selectedUpdates[0].identityKey -Expected '11111111-1111-1111-1111-111111111111|205' -Message 'resume plan normalization preserves selected identity key'

# A hand-edited or corrupted plan whose selected update lost its identityKey: the keyless
# entry is dropped (with a warning) and the keyed one survives.
$keylessPlanInput = @(
    [pscustomobject]@{
        vmName = 'VM09'
        computerName = 'HOST09'
        action = 'Install'
        reason = ''
        roleFlags = [pscustomobject]@{ failoverCluster = $false; detected = @() }
        selectedUpdates = @(
            [pscustomobject]@{ identityKey = '99999999-9999-9999-9999-999999999999|3'; updateId = '99999999-9999-9999-9999-999999999999'; revisionNumber = 3 },
            [pscustomobject]@{ identityKey = ''; updateId = $null; revisionNumber = $null }
        )
    }
)
$normalizedKeylessPlan = @(ConvertTo-PatchPlanRecords -InputObject $keylessPlanInput 3>$null)
Assert-Equal -Actual @($normalizedKeylessPlan[0].selectedUpdates).Count -Expected 1 -Message 'resume plan normalization drops a selected update without an identity key'
Assert-Equal -Actual $normalizedKeylessPlan[0].selectedUpdates[0].identityKey -Expected '99999999-9999-9999-9999-999999999999|3' -Message 'resume plan normalization keeps the keyed selected update'

# A plan written before collection artifacts became arrays is a bare JSON object, not a
# one-element array. Those files are on disk in customers' out\ directories and -PatchPlanPath
# has to keep loading them; the fix to the writer must not strand them.
$legacyPlanJson = '{"vmName":"vm01","action":"Install","roleFlags":null,"selectedUpdates":[{"identityKey":"99999999-9999-9999-9999-999999999999|3","updateId":"99999999-9999-9999-9999-999999999999","revisionNumber":3,"title":"Security Update","kbArticleIds":["5000001"]}]}'
# Through the file, the way -PatchPlanPath reads it: Get-Content -Raw then ConvertFrom-Json.
# Handing ConvertTo-PatchPlanRecords a PSCustomObject directly would pass on the scalar path it
# has always had and prove nothing about loading what is actually on disk.
$legacyPlanDir = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-legacy-plan-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $legacyPlanDir)
$legacyPlanPath = Join-Path $legacyPlanDir 'patch-plan.json'
try {
    Set-Content -LiteralPath $legacyPlanPath -Value $legacyPlanJson -Encoding UTF8
    $legacyPlanRaw = [string](Get-Content -LiteralPath $legacyPlanPath -Raw)
    Assert-Equal -Actual ($legacyPlanRaw.TrimStart().StartsWith('{')) -Expected $true -Message 'the legacy fixture really is a bare object, not an array'
    $legacyPlanObject = $legacyPlanRaw | ConvertFrom-Json
    $legacyPlanRecords = @(ConvertTo-PatchPlanRecords -InputObject $legacyPlanObject 3>$null)
    Assert-Equal -Actual $legacyPlanRecords.Count -Expected 1 -Message 'a single-object patch plan written before the array fix still loads'
    Assert-Equal -Actual ([string]$legacyPlanRecords[0].vmName) -Expected 'vm01' -Message 'the legacy plan keeps the VM it was written for'
    Assert-Equal -Actual @($legacyPlanRecords[0].selectedUpdates).Count -Expected 1 -Message 'the legacy plan keeps its selected update'
}
finally {
    Remove-Item -LiteralPath $legacyPlanDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- patch completion state (round loop) ---

$greenDiscovery = @(
    [pscustomobject]@{ vmName = 'VM01'; outcome = 'NoApplicableUpdates'; errors = @(); roleFlags = $null; updates = @() },
    [pscustomobject]@{ vmName = 'VM02'; outcome = 'SearchOnly'; errors = @(); roleFlags = $null; updates = @(
        [pscustomobject]@{ updateId = 'aaaaaaaa-1111-1111-1111-111111111111'; revisionNumber = 1; title = 'Security Update for Windows'; kbArticleIds = @('5000001'); categories = @('Security Updates'); msrcSeverity = 'Critical'; updateType = 'Software' }
    ) },
    [pscustomobject]@{ vmName = 'VM03'; outcome = 'SearchOnly'; errors = @(); roleFlags = $null; updates = @(
        [pscustomobject]@{ updateId = 'bbbbbbbb-2222-2222-2222-222222222222'; revisionNumber = 1; title = 'Intel Driver Update'; kbArticleIds = @(); categories = @('Drivers'); msrcSeverity = $null; updateType = 'Driver' }
    ) },
    [pscustomobject]@{ vmName = 'VM04'; outcome = 'SearchOnly'; errors = @(); roleFlags = [pscustomobject]@{ failoverCluster = $true; detected = @('FailoverCluster') }; updates = @() },
    [pscustomobject]@{ vmName = 'VM05'; outcome = 'DiscoveryFailed'; errors = @('GuestOps timed out'); roleFlags = $null; updates = @() }
)
$greenGroups = @(New-UpdateGroupRecords -DiscoveryRecords $greenDiscovery)
$greenStates = @(Get-VMPatchCompletionStates -DiscoveryRecords $greenDiscovery -UpdateGroups $greenGroups)

function Get-StateFor {
    param($States, [string]$VMName)
    return @($States | Where-Object { $_.vmName -eq $VMName })[0]
}

Assert-Equal -Actual (Get-StateFor -States $greenStates -VMName 'VM01').state -Expected 'Green' -Message 'VM without applicable updates is green'
Assert-Equal -Actual (Get-StateFor -States $greenStates -VMName 'VM02').state -Expected 'Pending' -Message 'VM with a default-selectable update is pending'
Assert-Equal -Actual (Get-StateFor -States $greenStates -VMName 'VM02').pendingSelectableCount -Expected 1 -Message 'pending VM reports how many selectable groups remain'
Assert-Equal -Actual (Get-StateFor -States $greenStates -VMName 'VM03').state -Expected 'Green' -Message 'driver-only leftovers do not block green'
Assert-Equal -Actual (Get-StateFor -States $greenStates -VMName 'VM04').state -Expected 'Excluded' -Message 'failover cluster VM is excluded, never green'
Assert-Equal -Actual (Get-StateFor -States $greenStates -VMName 'VM05').state -Expected 'Failed' -Message 'discovery failure is not green'

$deselectedStates = @(Get-VMPatchCompletionStates -DiscoveryRecords $greenDiscovery -UpdateGroups $greenGroups -DeselectedUpdateKeys @('aaaaaaaa-1111-1111-1111-111111111111|1'))
Assert-Equal -Actual (Get-StateFor -States $deselectedStates -VMName 'VM02').state -Expected 'GreenByOperatorChoice' -Message 'operator-deselected group does not keep the VM pending'

# A revision bump between rounds must not resurrect a group the operator already rejected.
$revisedDiscovery = @(
    [pscustomobject]@{ vmName = 'VM02'; outcome = 'SearchOnly'; errors = @(); roleFlags = $null; updates = @(
        [pscustomobject]@{ updateId = 'aaaaaaaa-1111-1111-1111-111111111111'; revisionNumber = 2; title = 'Security Update for Windows'; kbArticleIds = @('5000001'); categories = @('Security Updates'); msrcSeverity = 'Critical'; updateType = 'Software' }
    ) }
)
$revisedGroups = @(New-UpdateGroupRecords -DiscoveryRecords $revisedDiscovery)
$revisedStates = @(Get-VMPatchCompletionStates -DiscoveryRecords $revisedDiscovery -UpdateGroups $revisedGroups -DeselectedUpdateKeys @('aaaaaaaa-1111-1111-1111-111111111111|1'))
Assert-Equal -Actual (Get-StateFor -States $revisedStates -VMName 'VM02').state -Expected 'GreenByOperatorChoice' -Message 'a revision bump does not resurrect a deselected group'

# --- Defender definitions end to end (F4) ---
# Opt-in is only defensible if the operator can still reach the update. These drive the real
# group builder and the real plan builder rather than the policy function on its own, because
# what matters is what the operator is shown and what an explicit tick actually installs.
$defenderDiscovery = @(
    [pscustomobject]@{ vmName = 'VM01'; outcome = 'SearchOnly'; errors = @(); roleFlags = $null; updates = @(
        [pscustomobject]@{ updateId = 'dddddddd-4444-4444-4444-444444444444'; revisionNumber = 200; title = 'Aktualizacja analizy zabezpieczen dla Microsoft Defender Antivirus - KB2267602'; kbArticleIds = @('2267602'); categories = @('Definition Updates'); msrcSeverity = 'Critical'; updateType = 'Software' },
        [pscustomobject]@{ updateId = 'cccccccc-3333-3333-3333-333333333333'; revisionNumber = 1; title = '2026-06 Cumulative Update for Windows Server'; kbArticleIds = @('5031234'); categories = @('Security Updates'); msrcSeverity = 'Critical'; updateType = 'Software' },
        [pscustomobject]@{ updateId = 'eeeeeeee-5555-5555-5555-555555555555'; revisionNumber = 1; title = 'Update for Microsoft Defender Antivirus antimalware platform - KB4052623'; kbArticleIds = @('4052623'); categories = @('Security Updates'); msrcSeverity = 'Critical'; updateType = 'Software' },
        [pscustomobject]@{ updateId = 'ffffffff-6666-6666-6666-666666666666'; revisionNumber = 1; title = 'Intel Chipset Driver'; kbArticleIds = @(); categories = @('Drivers'); msrcSeverity = $null; updateType = 'Driver' },
        [pscustomobject]@{ updateId = '11111111-7777-7777-7777-777777777777'; revisionNumber = 1; title = '2026-06 Preview Cumulative Update for Windows Server'; kbArticleIds = @('5031299'); categories = @('Updates'); msrcSeverity = 'Critical'; updateType = 'Software' }
    ) }
)
$defenderGroups = @(New-UpdateGroupRecords -DiscoveryRecords $defenderDiscovery)

function Get-GroupFor {
    param($Groups, [string]$IdentityKey)
    return @($Groups | Where-Object { $_.identityKey -eq $IdentityKey })[0]
}

$definitionKey = 'dddddddd-4444-4444-4444-444444444444|200'
$cumulativeKey = 'cccccccc-3333-3333-3333-333333333333|1'
$platformKey = 'eeeeeeee-5555-5555-5555-555555555555|1'

Assert-Equal -Actual ($null -ne (Get-GroupFor -Groups $defenderGroups -IdentityKey $definitionKey)) -Expected $true -Message 'a Defender definition is offered to the operator'
Assert-Equal -Actual (Get-GroupFor -Groups $defenderGroups -IdentityKey $definitionKey).selectedByDefault -Expected $true -Message 'a Defender definition is ticked like any other update'
Assert-Equal -Actual (Get-GroupFor -Groups $defenderGroups -IdentityKey $cumulativeKey).selectedByDefault -Expected $true -Message 'the Windows cumulative update is still ticked by default'
Assert-Equal -Actual (Get-GroupFor -Groups $defenderGroups -IdentityKey $platformKey).selectedByDefault -Expected $true -Message 'the Defender platform update is still ticked by default'
Assert-Equal -Actual (Get-GroupFor -Groups $defenderGroups -IdentityKey 'ffffffff-6666-6666-6666-666666666666|1').selectedByDefault -Expected $false -Message 'the driver exclusion is unchanged'
Assert-Equal -Actual (Get-GroupFor -Groups $defenderGroups -IdentityKey '11111111-7777-7777-7777-777777777777|1').selectedByDefault -Expected $false -Message 'the preview exclusion is unchanged'

# A ticked definition reaches the guest as an install like anything else.
$defenderPlan = @(New-PatchPlanRecords -DiscoveryRecords $defenderDiscovery -SelectedUpdateKeys @($definitionKey))
$defenderPlanVM = @($defenderPlan | Where-Object { $_.vmName -eq 'VM01' })[0]
Assert-Equal -Actual $defenderPlanVM.action -Expected 'Install' -Message 'a selected definition is installed'
Assert-Equal -Actual @($defenderPlanVM.selectedUpdates).Count -Expected 1 -Message 'the plan carries exactly the selected update'
Assert-Equal -Actual $defenderPlanVM.selectedUpdates[0].identityKey -Expected $definitionKey -Message 'the plan carries the definition by its identity key'

# A definition is installed, but it does not get a vote on whether the VM is finished. WUA
# republishes it within hours under a new revision, so counting it would mean round N+1 discovers
# a different group and a fully patched fleet never converges.
$definitionOnlyDiscovery = @(
    [pscustomobject]@{ vmName = 'VM01'; outcome = 'SearchOnly'; errors = @(); roleFlags = $null; updates = @(
        [pscustomobject]@{ updateId = 'dddddddd-4444-4444-4444-444444444444'; revisionNumber = 200; title = 'Aktualizacja analizy zabezpieczen dla Microsoft Defender Antivirus - KB2267602'; kbArticleIds = @('2267602'); categories = @('Definition Updates'); msrcSeverity = 'Critical'; updateType = 'Software' }
    ) }
)
$definitionOnlyGroups = @(New-UpdateGroupRecords -DiscoveryRecords $definitionOnlyDiscovery)
$definitionOnlyStates = @(Get-VMPatchCompletionStates -DiscoveryRecords $definitionOnlyDiscovery -UpdateGroups $definitionOnlyGroups)
Assert-Equal -Actual (Get-StateFor -States $definitionOnlyStates -VMName 'VM01').state -Expected 'Green' -Message 'a Defender definition on its own does not keep a VM pending'
Assert-Equal -Actual (Get-StateFor -States $definitionOnlyStates -VMName 'VM01').pendingSelectableCount -Expected 0 -Message 'a Defender definition is not counted as a pending group'
Assert-Equal -Actual (Get-StateFor -States $definitionOnlyStates -VMName 'VM01').deselectedSelectableCount -Expected 0 -Message 'a Defender definition is not counted as a deselected group either'
Assert-Equal -Actual (Get-GroupFor -Groups $definitionOnlyGroups -IdentityKey $definitionKey).selectedByDefault -Expected $true -Message 'the definition that does not block Green is nevertheless installed'

# The revision changes with every definition release. Whether the operator unticked the previous
# one or not, the new revision must not start blocking Green.
$definitionRevisedDiscovery = @(
    [pscustomobject]@{ vmName = 'VM01'; outcome = 'SearchOnly'; errors = @(); roleFlags = $null; updates = @(
        [pscustomobject]@{ updateId = 'dddddddd-4444-4444-4444-444444444444'; revisionNumber = 201; title = 'Aktualizacja analizy zabezpieczen dla Microsoft Defender Antivirus - KB2267602'; kbArticleIds = @('2267602'); categories = @('Definition Updates'); msrcSeverity = 'Critical'; updateType = 'Software' }
    ) }
)
$definitionRevisedGroups = @(New-UpdateGroupRecords -DiscoveryRecords $definitionRevisedDiscovery)
$definitionRevisedStates = @(Get-VMPatchCompletionStates -DiscoveryRecords $definitionRevisedDiscovery -UpdateGroups $definitionRevisedGroups -DeselectedUpdateKeys @($definitionKey))
Assert-Equal -Actual (Get-StateFor -States $definitionRevisedStates -VMName 'VM01').state -Expected 'Green' -Message 'a new definition revision does not start blocking Green'

# A real Windows update arriving alongside a definition still has to stop the loop.
$mixedStates = @(Get-VMPatchCompletionStates -DiscoveryRecords $defenderDiscovery -UpdateGroups $defenderGroups)
Assert-Equal -Actual (Get-StateFor -States $mixedStates -VMName 'VM01').state -Expected 'Pending' -Message 'a default-selected Windows update still keeps the VM pending alongside a definition'
Assert-Equal -Actual (Get-StateFor -States $mixedStates -VMName 'VM01').pendingSelectableCount -Expected 2 -Message 'the pending count covers the Windows and platform updates but not the definition'

# Installing the definition is not what makes the VM green, and failing to install it is not what
# keeps it pending: it is simply absent from the judgement either way.
$defenderDeselectedStates = @(Get-VMPatchCompletionStates -DiscoveryRecords $defenderDiscovery -UpdateGroups $defenderGroups -DeselectedUpdateKeys @($definitionKey, $cumulativeKey, $platformKey))
Assert-Equal -Actual (Get-StateFor -States $defenderDeselectedStates -VMName 'VM01').state -Expected 'GreenByOperatorChoice' -Message 'unticking the real updates is what changes the verdict'
Assert-Equal -Actual (Get-StateFor -States $defenderDeselectedStates -VMName 'VM01').deselectedSelectableCount -Expected 2 -Message 'the definition is not counted among the deselected groups'

$nextRound = @(Get-NextRoundVMNames -CompletionStates $greenStates)
Assert-Equal -Actual $nextRound.Count -Expected 1 -Message 'only pending VMs enter the next round'
Assert-Equal -Actual $nextRound[0] -Expected 'VM02' -Message 'next round targets the pending VM'

if ($failures.Count -gt 0) {
    Write-Host 'Model checks failed:'
    foreach ($failure in $failures) {
        Write-Host (" - {0}" -f $failure)
    }
    exit 1
}

Write-Host 'Model checks passed.'
exit 0

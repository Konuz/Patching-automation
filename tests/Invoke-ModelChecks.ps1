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

if ($failures.Count -gt 0) {
    Write-Host 'Model checks failed:'
    foreach ($failure in $failures) {
        Write-Host (" - {0}" -f $failure)
    }
    exit 1
}

Write-Host 'Model checks passed.'
exit 0

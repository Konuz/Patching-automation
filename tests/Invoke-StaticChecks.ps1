[CmdletBinding()]
param(
    [string]$Root
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $Root) {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    [void]$script:failures.Add($Message)
}

function Resolve-ProjectPath {
    param([string]$RelativePath)
    return (Join-Path $Root $RelativePath)
}

function Assert-FileExists {
    param([string]$RelativePath)

    $path = Resolve-ProjectPath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-Failure -Message "Missing file: $RelativePath"
        return $null
    }

    return $path
}

function Get-ScriptAst {
    param(
        [string]$RelativePath,
        [string]$Path
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)

    foreach ($parseError in @($parseErrors)) {
        Add-Failure -Message ("Parse error in {0} at line {1}: {2}" -f $RelativePath, $parseError.Extent.StartLineNumber, $parseError.Message)
    }

    return $ast
}

function Get-ScriptText {
    param([string]$Path)

    return [System.IO.File]::ReadAllText($Path)
}

function Assert-TextContains {
    param(
        [string]$RelativePath,
        [string]$Text,
        [string]$Needle
    )

    if ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Add-Failure -Message ("{0} does not contain required text: {1}" -f $RelativePath, $Needle)
    }
}

function Assert-TextDoesNotMatch {
    param(
        [string]$RelativePath,
        [string]$Text,
        [string]$Pattern,
        [string]$Reason
    )

    if ($Text -match $Pattern) {
        Add-Failure -Message ("{0} matches forbidden pattern ({1}): {2}" -f $RelativePath, $Reason, $Pattern)
    }
}

function Assert-NoForbiddenCommand {
    param(
        [System.Management.Automation.Language.Ast]$Ast,
        [string]$RelativePath,
        [string[]]$ForbiddenNames
    )

    if (-not $Ast) {
        return
    }

    $commandAsts = $Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    # GetCommandName() resolves only statically-named commands; dynamic dispatch such
    # as `& $cmd` is invisible here. Assert-NoForbiddenCommandLiteral adds a
    # defense-in-depth text scan for the forbidden names as string literals.
    foreach ($commandAst in $commandAsts) {
        $commandName = $commandAst.GetCommandName()
        if (-not $commandName) {
            continue
        }

        foreach ($forbiddenName in $ForbiddenNames) {
            if ($commandName -ieq $forbiddenName) {
                Add-Failure -Message ("Forbidden command in {0} at line {1}: {2}" -f $RelativePath, $commandAst.Extent.StartLineNumber, $commandName)
            }
        }
    }
}

function Assert-NoForbiddenCommandLiteral {
    param(
        [string]$RelativePath,
        [string]$Text,
        [string[]]$ForbiddenNames
    )

    foreach ($forbiddenName in $ForbiddenNames) {
        $pattern = '(?i)["'']{0}["'']' -f [regex]::Escape($forbiddenName)
        if ($Text -match $pattern) {
            Add-Failure -Message ("Forbidden command name as a string literal in {0} (possible dynamic dispatch): {1}" -f $RelativePath, $forbiddenName)
        }
    }
}

function Assert-NoReservedVariableName {
    param(
        [System.Management.Automation.Language.Ast]$Ast,
        [string]$RelativePath,
        [string[]]$ReservedNames
    )

    if (-not $Ast) {
        return
    }

    $variableAsts = $Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.VariableExpressionAst]
    }, $true)

    foreach ($variableAst in $variableAsts) {
        $variableName = $variableAst.VariablePath.UserPath
        if ($variableName -match ':') {
            $variableName = $variableName.Split(':')[-1]
        }
        foreach ($reservedName in $ReservedNames) {
            if ($variableName -ieq $reservedName) {
                Add-Failure -Message ("Reserved automatic variable name in {0} at line {1}: {2}" -f $RelativePath, $variableAst.Extent.StartLineNumber, $variableName)
            }
        }
    }
}

$agentPath = 'guest\Run-LocalPatch.ps1'
$orchestratorPath = 'scripts\Invoke-GuestOpsPatchValidation.ps1'
$launcherPath = 'Start-PatchingGuestOps.ps1'
$modelPath = 'scripts\PatchPlanModel.ps1'
$modelTestPath = 'tests\Invoke-ModelChecks.ps1'

$existingScripts = @{}
foreach ($relativePath in @($agentPath, $orchestratorPath, $launcherPath, $modelPath, $modelTestPath)) {
    $path = Assert-FileExists -RelativePath $relativePath
    if ($path) {
        $existingScripts[$relativePath] = $path
    }
}

$forbiddenCommands = @(
    'Invoke-Command',
    'New-PSSession',
    'Enter-PSSession',
    'Invoke-VMScript',
    'Copy-VMGuestFile'
)

$reservedVariableNames = @(
    'PID'
)

if ($existingScripts.ContainsKey($agentPath)) {
    $agentAst = Get-ScriptAst -RelativePath $agentPath -Path $existingScripts[$agentPath]
    $agentText = Get-ScriptText -Path $existingScripts[$agentPath]

    Assert-NoForbiddenCommand -Ast $agentAst -RelativePath $agentPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $agentPath -Text $agentText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $agentAst -RelativePath $agentPath -ReservedNames $reservedVariableNames
    Assert-TextDoesNotMatch -RelativePath $agentPath -Text $agentText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'Microsoft.Update.Session'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'CreateUpdateSearcher'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'CreateUpdateDownloader'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'CreateUpdateInstaller'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'ConvertTo-Json'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'Test-PendingReboot'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'Get-OptionalPropertyValue'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'SelectedUpdateIds'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'SelectedUpdateKeys'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'identityKey'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'New-UpdateIdentityKey'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'Get-ComCategoryCollection'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'revisionNumber'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'Get-RoleFlags'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'roleFlags'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'failoverCluster'
    Assert-TextDoesNotMatch -RelativePath $agentPath -Text $agentText -Pattern '(?i)\$[a-z_][a-z0-9_]*\.HResult\b' -Reason 'WUA COM HResult can be absent under StrictMode'
}

if ($existingScripts.ContainsKey($orchestratorPath)) {
    $orchestratorAst = Get-ScriptAst -RelativePath $orchestratorPath -Path $existingScripts[$orchestratorPath]
    $orchestratorText = Get-ScriptText -Path $existingScripts[$orchestratorPath]

    Assert-NoForbiddenCommand -Ast $orchestratorAst -RelativePath $orchestratorPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $orchestratorPath -Text $orchestratorText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $orchestratorAst -RelativePath $orchestratorPath -ReservedNames $reservedVariableNames
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'StartProgramInGuest'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'ListProcessesInGuest'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'InitiateFileTransferToGuest'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'InitiateFileTransferFromGuest'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'curl.exe'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Agent errors:'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Pending reboot checks:'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'InstallSelection'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Resolve-UpdateSelection'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Read-UpdateSelection'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Available updates'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'A for all'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'SelectedUpdateIds'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle "@(`$SelectedUpdateIds) -join ','"
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'VMNames'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'VMListPath'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'ThrottleLimit'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'PlanOnly'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'SkipConfirmation'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'SelectedUpdateKeys'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle "PSBoundParameters.ContainsKey('SelectedUpdateKeys')"
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'InstallSelection is not supported with grouped update selection. Use SelectedUpdateKeys instead.'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Resolve-VMTargetNames'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Invoke-DiscoveryPhase'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'discovery.json'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Discovery summary'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Available update groups'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Show-UpdateGroups'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Read-UpdateGroupSelection'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Resolve-SelectedUpdateKeys'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Patch plan'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'patch-plan.json'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Show-PatchPlan'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Confirm-PatchPlan'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Proceed with this plan? [Y/N]'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Update-PatchPlanWithDiscoveryFailures'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Test-IsSuccessfulDiscoveryOutcome -Outcome $outcome'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Skipped: Discovery failed. Review discovery.json and per-VM agent artifacts.'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle '@($SelectedUpdateKeys).Count -eq 0'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'SelectedUpdateKeys did not contain any non-empty update keys.'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Selected update key is not present in discovered update groups:'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'selectedByDefault'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'New-DiscoveryRecord'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Invoke-VMAgentCycle'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'New-UniqueOutputDirectory'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle "'{0:D3}-{1}' -f"
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'DiscoveryFailed'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle '$failedDiscoveryRecords'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Test-IsSuccessfulDiscoveryOutcome'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle "return (`$Outcome -in @('SearchOnly', 'NoApplicableUpdates'))"
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Discovery returned outcome'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle '$agentRun.AgentResult.Completed'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'successful discovery outcome and finishedAt'
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?s)if\s*\(\$targetVMNames\.Count\s+-gt\s+1\).*?\breturn\b' -Reason 'multi-VM discovery must fall through to the final exit'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Role flags:'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'failoverCluster'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Skipped: Failover Cluster detected. Please update manually one by one.'
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern "(?i)'-SelectedUpdateIds'\s+(foreach|for)\b" -Reason 'SelectedUpdateIds must be one joined argument, not appended per element (PowerShell would bind them as positional SearchCriteria)'
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?i)\$kbArticleIds\.Count\b' -Reason 'ConvertFrom-Json can collapse one KB article id to a scalar under StrictMode'
}

if ($existingScripts.ContainsKey($launcherPath)) {
    $launcherAst = Get-ScriptAst -RelativePath $launcherPath -Path $existingScripts[$launcherPath]
    $launcherText = Get-ScriptText -Path $existingScripts[$launcherPath]

    Assert-NoForbiddenCommand -Ast $launcherAst -RelativePath $launcherPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $launcherPath -Text $launcherText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $launcherAst -RelativePath $launcherPath -ReservedNames $reservedVariableNames
    Assert-TextDoesNotMatch -RelativePath $launcherPath -Text $launcherText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'Invoke-StaticChecks.ps1'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'Invoke-GuestOpsPatchValidation.ps1'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'Get-Credential'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'InstallSelection'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'VMNames'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'VMListPath'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'ThrottleLimit'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'PlanOnly'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'SkipConfirmation'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'SelectedUpdateKeys'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle "PSBoundParameters.ContainsKey('SelectedUpdateKeys')"
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'Resolve-VMTargetNames'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle '$PSScriptRoot'
}

if ($existingScripts.ContainsKey($modelPath)) {
    $modelAst = Get-ScriptAst -RelativePath $modelPath -Path $existingScripts[$modelPath]
    $modelText = Get-ScriptText -Path $existingScripts[$modelPath]

    Assert-NoForbiddenCommand -Ast $modelAst -RelativePath $modelPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $modelPath -Text $modelText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $modelAst -RelativePath $modelPath -ReservedNames $reservedVariableNames
    Assert-TextDoesNotMatch -RelativePath $modelPath -Text $modelText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $modelPath -Text $modelText -Needle 'New-UpdateIdentityKey'
    Assert-TextContains -RelativePath $modelPath -Text $modelText -Needle 'New-UpdateGroupRecords'
    Assert-TextContains -RelativePath $modelPath -Text $modelText -Needle 'Get-DefaultUpdateSelection'
    Assert-TextContains -RelativePath $modelPath -Text $modelText -Needle 'New-PatchPlanRecords'
    Assert-TextContains -RelativePath $modelPath -Text $modelText -Needle 'ConvertTo-PatchSummaryRows'
}

if ($existingScripts.ContainsKey($modelTestPath)) {
    $modelTestAst = Get-ScriptAst -RelativePath $modelTestPath -Path $existingScripts[$modelTestPath]
    $modelTestText = Get-ScriptText -Path $existingScripts[$modelTestPath]

    Assert-NoForbiddenCommand -Ast $modelTestAst -RelativePath $modelTestPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $modelTestPath -Text $modelTestText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $modelTestAst -RelativePath $modelTestPath -ReservedNames $reservedVariableNames
    Assert-TextContains -RelativePath $modelTestPath -Text $modelTestText -Needle 'PatchPlanModel.ps1'
    Assert-TextContains -RelativePath $modelTestPath -Text $modelTestText -Needle 'Model checks passed.'
}

if ($failures.Count -gt 0) {
    Write-Host 'Static checks failed:'
    foreach ($failure in $failures) {
        Write-Host (" - {0}" -f $failure)
    }
    exit 1
}

Write-Host 'Static checks passed.'
exit 0

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

function Get-OptionalFilePath {
    param([string]$RelativePath)

    $path = Resolve-ProjectPath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
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

function Assert-TextMatches {
    param(
        [string]$RelativePath,
        [string]$Text,
        [string]$Pattern,
        [string]$Reason
    )

    if ($Text -notmatch $Pattern) {
        Add-Failure -Message ("{0} does not match required pattern ({1}): {2}" -f $RelativePath, $Reason, $Pattern)
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

function Assert-NoOrphanedBranchKeyword {
    param(
        [System.Management.Automation.Language.Ast]$Ast,
        [string]$RelativePath
    )

    if (-not $Ast) {
        return
    }

    # An `elseif`/`else` block left without its `if` - easy to create when restructuring a
    # long flow - is NOT a parse error: PowerShell reads it as a call to a command named
    # "elseif". Every gate stays green and the run dies at runtime with
    # CommandNotFoundException, which the top-level catch turns into a bare exit 1.
    $branchKeywords = @('elseif', 'else')
    $commandAsts = $Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    foreach ($commandAst in $commandAsts) {
        $commandName = $commandAst.GetCommandName()
        if ($commandName -and ($branchKeywords -contains $commandName.ToLowerInvariant())) {
            Add-Failure -Message ("Orphaned branch keyword in {0} at line {1}: {2} is being parsed as a command, so its `if` is missing" -f $RelativePath, $commandAst.Extent.StartLineNumber, $commandName)
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
$identityHelperPath = 'guest\UpdateIdentity.ps1'
$bootTimeHelperPath = 'guest\Read-BootTime.ps1'
$workspaceHelperPath = 'guest\GuestWorkspace.ps1'
$runGuardHelperPath = 'guest\GuestRunGuard.ps1'
$rebootRequestHelperPath = 'guest\Request-GuestReboot.ps1'
$orchestratorPath = 'scripts\Invoke-GuestOpsPatchValidation.ps1'
$runtimeHelperPath = 'scripts\OrchestratorRuntime.ps1'
$guestOpsLibPath = 'scripts\GuestOpsLib.ps1'
$launcherPath = 'Start-PatchingGuestOps.ps1'
$vmTargetLibPath = 'scripts\VMTargetLib.ps1'
$modelPath = 'scripts\PatchPlanModel.ps1'
$modelTestPath = 'tests\Invoke-ModelChecks.ps1'
$runtimeTestPath = 'tests\Invoke-RuntimeChecks.ps1'
$harnessTestPath = 'tests\Invoke-GuestOpsHarnessChecks.ps1'
$workspaceTestPath = 'tests\Invoke-GuestWorkspaceChecks.ps1'
$settingsStorePath = 'scripts\SettingsStore.ps1'
$guiPromptsPath = 'scripts\GuiPrompts.ps1'
$guiLauncherPath = 'Start-PatchingGuestOpsGui.ps1'

$existingScripts = @{}
foreach ($relativePath in @($agentPath, $identityHelperPath, $bootTimeHelperPath, $workspaceHelperPath, $runGuardHelperPath, $rebootRequestHelperPath, $orchestratorPath, $runtimeHelperPath, $guestOpsLibPath, $vmTargetLibPath, $launcherPath, $modelPath, $modelTestPath, $runtimeTestPath, $harnessTestPath, $workspaceTestPath)) {
    $path = Assert-FileExists -RelativePath $relativePath
    if ($path) {
        $existingScripts[$relativePath] = $path
    }
}

# GUI files are optional: the console tool must stay deployable without them, and
# Assert-FileExists would record a failure rather than skip.
foreach ($relativePath in @($settingsStorePath, $guiPromptsPath, $guiLauncherPath)) {
    $path = Get-OptionalFilePath -RelativePath $relativePath
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
    'PID',
    'matches'
)

if ($existingScripts.ContainsKey($agentPath)) {
    $agentAst = Get-ScriptAst -RelativePath $agentPath -Path $existingScripts[$agentPath]
    $agentText = Get-ScriptText -Path $existingScripts[$agentPath]

    Assert-NoForbiddenCommand -Ast $agentAst -RelativePath $agentPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $agentPath -Text $agentText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $agentAst -RelativePath $agentPath -ReservedNames $reservedVariableNames
    Assert-NoOrphanedBranchKeyword -Ast $agentAst -RelativePath $agentPath
    Assert-TextDoesNotMatch -RelativePath $agentPath -Text $agentText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'Microsoft.Update.Session'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'CreateUpdateSearcher'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'CreateUpdateDownloader'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'CreateUpdateInstaller'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'ConvertTo-Json'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'Test-PendingReboot'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'Get-OptionalPropertyValue'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'SelectedUpdateKeys'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'identityKey'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'New-CanonicalUpdateIdentityKey'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'Get-ComCategoryCollection'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'revisionNumber'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'Get-RoleFlags'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'roleFlags'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'failoverCluster'
    Assert-TextDoesNotMatch -RelativePath $agentPath -Text $agentText -Pattern '(?i)\$[a-z_][a-z0-9_]*\.HResult\b' -Reason 'WUA COM HResult can be absent under StrictMode'
    # Same class as the HResult rule, and it cost seven guests their discovery: PowerShell cannot
    # always adapt the collection WUA returns, so reading Count off one at a call site is a
    # PropertyNotFoundException under StrictMode rather than a number. Call sites go through the
    # helper; the helper itself is the one place that reads the member.
    Assert-TextDoesNotMatch -RelativePath $agentPath -Text $agentText -Pattern '(?i)\$(searchResult\.Updates|searchWarnings)\.Count\b' -Reason 'WUA collections must be counted through Get-ComCollectionCount'
    # And the helper must keep reading it DIRECTLY. Going through PSObject.Properties looks more
    # defensive and is strictly worse: PowerShell adapts a COM object through IDispatch, and with
    # no usable type library the member bag is empty while $obj.Count still resolves by name, so
    # introspection answers "cannot be counted" for collections that count perfectly well. That
    # turned a fix for seven guests into a failure on every guest in the fleet, and no offline
    # double can reproduce it - a PSCustomObject's bag and its direct access always agree.
    Assert-TextMatches -RelativePath $agentPath -Text $agentText -Pattern '(?s)function\s+Get-ComCollectionCount\b(?:(?!\bfunction\b).)*?\$Collection\.Count' -Reason 'the COM count helper must read the member directly'
    Assert-TextDoesNotMatch -RelativePath $agentPath -Text $agentText -Pattern '(?s)function\s+Get-ComCollectionCount\b(?:(?!\bfunction\b).)*?Get-OptionalPropertyValue' -Reason 'the COM count helper must not introspect the property bag'
}

if ($existingScripts.ContainsKey($workspaceHelperPath)) {
    $workspaceHelperAst = Get-ScriptAst -RelativePath $workspaceHelperPath -Path $existingScripts[$workspaceHelperPath]
    $workspaceHelperText = Get-ScriptText -Path $existingScripts[$workspaceHelperPath]

    Assert-NoForbiddenCommand -Ast $workspaceHelperAst -RelativePath $workspaceHelperPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $workspaceHelperPath -Text $workspaceHelperText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $workspaceHelperAst -RelativePath $workspaceHelperPath -ReservedNames $reservedVariableNames
    Assert-NoOrphanedBranchKeyword -Ast $workspaceHelperAst -RelativePath $workspaceHelperPath
    Assert-TextDoesNotMatch -RelativePath $workspaceHelperPath -Text $workspaceHelperText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'

    # Legacy-root migration is the only ACL writer; ordinary verification stays read-only.
    foreach ($verifyName in @('Assert-GuestWorkspacePath', 'Assert-GuestWorkspaceFilePath', 'Assert-GuestWorkspaceSeal')) {
        $verifyAst = $workspaceHelperAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $verifyName }, $true)
        Assert-TextDoesNotMatch -RelativePath $workspaceHelperPath -Text $verifyAst.Extent.Text -Pattern '(?i)\b(Set-Acl|takeown|Set-GuestWorkspaceRootSecurity)\b' -Reason 'verification must not migrate permissions'
    }
    Assert-TextDoesNotMatch -RelativePath $workspaceHelperPath -Text $workspaceHelperText -Pattern '(?i)\bRemove-Item\b' -Reason 'the guest workspace guard never deletes anything'
}

foreach ($guestGuardPath in @($runGuardHelperPath, $rebootRequestHelperPath)) {
    if (-not $existingScripts.ContainsKey($guestGuardPath)) {
        continue
    }

    $guestGuardAst = Get-ScriptAst -RelativePath $guestGuardPath -Path $existingScripts[$guestGuardPath]
    $guestGuardText = Get-ScriptText -Path $existingScripts[$guestGuardPath]

    Assert-NoForbiddenCommand -Ast $guestGuardAst -RelativePath $guestGuardPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $guestGuardPath -Text $guestGuardText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $guestGuardAst -RelativePath $guestGuardPath -ReservedNames $reservedVariableNames
    Assert-NoOrphanedBranchKeyword -Ast $guestGuardAst -RelativePath $guestGuardPath
    Assert-TextDoesNotMatch -RelativePath $guestGuardPath -Text $guestGuardText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'

    # The coordination record is shared state for the whole guest. Deleting it, or clearing it
    # because it looks old, would throw away the one trace that says whether the previous run
    # finished - and age is never evidence that a WUA install ended.
    Assert-TextDoesNotMatch -RelativePath $guestGuardPath -Text $guestGuardText -Pattern '(?i)\bRemove-Item\b' -Reason 'the guest run guard never deletes its coordination record'
    Assert-TextDoesNotMatch -RelativePath $guestGuardPath -Text $guestGuardText -Pattern '(?i)\b(Stop-Process|taskkill)\b' -Reason 'the guest run guard never kills the process that holds the lock'
}

if ($existingScripts.ContainsKey($runGuardHelperPath)) {
    $runGuardText = Get-ScriptText -Path $existingScripts[$runGuardHelperPath]

    # FileShare::None is what makes the lock a lock; the behaviour around it is covered by the
    # two-process tests in Invoke-GuestWorkspaceChecks.ps1.
    Assert-TextContains -RelativePath $runGuardHelperPath -Text $runGuardText -Needle '[System.IO.FileShare]::None'
    # One fixed coordination path, independent of -GuestWorkingDirectory: a lock that moves with
    # the working directory is not a lock, because a second run brings its own.
    Assert-TextContains -RelativePath $runGuardHelperPath -Text $runGuardText -Needle 'C:\ProgramData\PatchingGuestOps\.coordination'
    Assert-TextDoesNotMatch -RelativePath $runGuardHelperPath -Text $runGuardText -Pattern '\$GuestWorkingDirectory' -Reason 'the coordination directory must not follow the operator-supplied working directory'
}

if ($existingScripts.ContainsKey($bootTimeHelperPath)) {
    $bootTimeHelperAst = Get-ScriptAst -RelativePath $bootTimeHelperPath -Path $existingScripts[$bootTimeHelperPath]
    $bootTimeHelperText = Get-ScriptText -Path $existingScripts[$bootTimeHelperPath]

    Assert-NoForbiddenCommand -Ast $bootTimeHelperAst -RelativePath $bootTimeHelperPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $bootTimeHelperPath -Text $bootTimeHelperText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $bootTimeHelperAst -RelativePath $bootTimeHelperPath -ReservedNames $reservedVariableNames
    Assert-NoOrphanedBranchKeyword -Ast $bootTimeHelperAst -RelativePath $bootTimeHelperPath
    Assert-TextDoesNotMatch -RelativePath $bootTimeHelperPath -Text $bootTimeHelperText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'
}

if ($existingScripts.ContainsKey($guestOpsLibPath)) {
    $guestOpsLibAst = Get-ScriptAst -RelativePath $guestOpsLibPath -Path $existingScripts[$guestOpsLibPath]
    $guestOpsLibText = Get-ScriptText -Path $existingScripts[$guestOpsLibPath]

    Assert-NoForbiddenCommand -Ast $guestOpsLibAst -RelativePath $guestOpsLibPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $guestOpsLibPath -Text $guestOpsLibText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $guestOpsLibAst -RelativePath $guestOpsLibPath -ReservedNames $reservedVariableNames
    Assert-NoOrphanedBranchKeyword -Ast $guestOpsLibAst -RelativePath $guestOpsLibPath
    Assert-TextDoesNotMatch -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'
    # The agent cycle is the three phases the fleet drives. Invoke-VMAgentCycle and
    # Invoke-GuestAgentRun were their single-shot predecessors; they lost their last caller
    # when discovery and apply moved in-process, and needles demanding their names were
    # keeping dead code alive.
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle 'Start-VMAgentCycle'
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle 'Test-VMAgentCycleComplete'
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle 'Complete-VMAgentCycle'
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle 'New-GuestAuthentication'
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle 'Get-ObjectPropertyValue'
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle 'StartProgramInGuest'
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle 'ListProcessesInGuest'
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle 'InitiateFileTransferToGuest'
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle 'InitiateFileTransferFromGuest'
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle 'Start-GuestReboot'
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle 'Start-GuestReboot'
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle 'Invoke-VMGuestReboot'
    # shutdown.exe is now invoked from inside the guest, by the process that holds the guest run
    # guard while it orders the restart, so the needle follows it into the request script.
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle 'New-GuestRebootBootstrapCommand'
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle 'PatchingGuestOps reboot after updates'
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle 'Connect-VIServersWithCredentialMap'
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle '[ValidateRange(1,2147483647)][int]$TimeoutSeconds = 300'
    Assert-TextContains -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Needle '--max-time'
    # Certificate policy is exercised by Invoke-CertificateChecks: strict by default,
    # with an explicit run-scoped ESXi override independent of vCenter.
    Assert-TextDoesNotMatch -RelativePath $guestOpsLibPath -Text $guestOpsLibText -Pattern '(?i)Get-View\s+ServiceInstance' -Reason 'GuestOps managers must come from the VM client'
}

if ($existingScripts.ContainsKey($vmTargetLibPath)) {
    $vmTargetLibAst = Get-ScriptAst -RelativePath $vmTargetLibPath -Path $existingScripts[$vmTargetLibPath]
    $vmTargetLibText = Get-ScriptText -Path $existingScripts[$vmTargetLibPath]

    Assert-NoForbiddenCommand -Ast $vmTargetLibAst -RelativePath $vmTargetLibPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $vmTargetLibPath -Text $vmTargetLibText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $vmTargetLibAst -RelativePath $vmTargetLibPath -ReservedNames $reservedVariableNames
    Assert-NoOrphanedBranchKeyword -Ast $vmTargetLibAst -RelativePath $vmTargetLibPath
    Assert-TextDoesNotMatch -RelativePath $vmTargetLibPath -Text $vmTargetLibText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $vmTargetLibPath -Text $vmTargetLibText -Needle 'Get-UniqueTrimmedNames'
    Assert-TextContains -RelativePath $vmTargetLibPath -Text $vmTargetLibText -Needle 'Split-VMNameInput'
    Assert-TextContains -RelativePath $vmTargetLibPath -Text $vmTargetLibText -Needle 'Split-VIServerInput'
    Assert-TextContains -RelativePath $vmTargetLibPath -Text $vmTargetLibText -Needle 'Resolve-VMTargetNamesFromSources'
    Assert-TextContains -RelativePath $vmTargetLibPath -Text $vmTargetLibText -Needle 'Resolve-VIServerCredentialMap'
}

if ($existingScripts.ContainsKey($orchestratorPath)) {
    $orchestratorAst = Get-ScriptAst -RelativePath $orchestratorPath -Path $existingScripts[$orchestratorPath]
    $orchestratorText = Get-ScriptText -Path $existingScripts[$orchestratorPath]

    Assert-NoForbiddenCommand -Ast $orchestratorAst -RelativePath $orchestratorPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $orchestratorPath -Text $orchestratorText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $orchestratorAst -RelativePath $orchestratorPath -ReservedNames $reservedVariableNames
    Assert-NoOrphanedBranchKeyword -Ast $orchestratorAst -RelativePath $orchestratorPath
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'curl.exe'
    # The prerequisite check and the import must name the same module. They drifted once:
    # the check demanded the VMware.PowerCLI meta-module while the code imported
    # VimAutomation.Core, so a complete lean install was refused for a missing manifest.
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Get-Module -ListAvailable -Name VMware.VimAutomation.Core'
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?i)-Name\s+VMware\.PowerCLI\b' -Reason 'prerequisite check must name the module the orchestrator imports, not the meta-module'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'InstallSelection'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'VMNames'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'VMListPath'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'ThrottleLimit'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Invoke-ThrottledJobs'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'JobTimeoutSeconds'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'GuestOpsLib.ps1'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'VMTargetLib.ps1'
    # Credential recovery is resolved per VM inside the orchestrator's own phases, so the
    # module has to be loaded here; without it every recovery call is a CommandNotFoundException
    # at the exact moment a guest rejects a login.
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'CredentialRecovery.ps1'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle '$JobInput.GuestOpsLibPath'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle '-Managers $null'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'PlanOnly'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'SkipConfirmation'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'SelectedUpdateKeys'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle "PSBoundParameters.ContainsKey('SelectedUpdateKeys')"
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'InstallSelection is not supported with grouped update selection. Use SelectedUpdateKeys instead.'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Resolve-VMTargetNames'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Invoke-DiscoveryPhase'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'discovery.json'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Discovery summary'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle "@('pendingRebootBefore', 'isPending')"
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '\[bool\]\$record\.pendingRebootBefore\b' -Reason 'discovery summary must read pendingRebootBefore.isPending, not cast the wrapper object'
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
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'New-DiscoveryRecord'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'ConvertTo-PatchPlanRecords'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Patch plan file not found:'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Invoke-ApplyPhase'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'apply-results.json'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Write-FinalReport'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'summary.csv'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'summary.md'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'VMs requiring reboot'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'VMs rejected by Failover Cluster'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'DiscoveryRecords'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Select-RebootRequiredApplyResults -ApplyResults $applyResults -DiscoveryRecords $DiscoveryRecords'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle '-DiscoveryRecords $discoveryRecords'
    Assert-TextMatches -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?s)\$discoveryRecords\s*=\s*Invoke-DiscoveryPhase\b.*?Invoke-ApplyAndOptionalReboot\b[^\r\n]*-DiscoveryRecords\s+\$discoveryRecords' -Reason 'normal discovery-driven apply path passes discovery records into reboot target selection'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Get-VMPatchCompletionStates'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Get-PatchRoundDecision'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Test-RebootActionsAllConfirmed'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Read-ContinuePatchingDecision'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Write-PatchRunSummary'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle "'round-{0:D2}' -f"
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'SelectedUpdateKeys'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'InstallSucceeded'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'RebootRequired'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Test-ApplyResultsSuccessful'
    Assert-TextMatches -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?s)function\s+Write-FinalReport\b.*?\$errors\s*=\s*@\(\$ApplyResults\s*\|\s*Where-Object\s*\{\s*Test-IsApplyResultError\s+-ApplyResult\s+\$_\s*\}\)' -Reason 'final report errors use shared apply-result error semantics'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'New-ApplyResultFromCycle'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'No selected update keys were available for apply.'
    # This used to be a text needle pinning one field of one branch. Every branch now goes through
    # New-ApplyResultRecord, which cannot omit a field, and the structural rule below says so for
    # all of them - pinning a single field only invites the next one to be forgotten.
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'New-ApplyResultRecord'
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '\$applyResults\s*\|\s*Where-Object\s*\{\s*\$_\.outcome\s+-in\s+@\(''Failed'',\s*''InstallFailed'',\s*''InstallSucceededWithErrors'',\s*''DownloadFailed''\)' -Reason 'apply exit must use explicit success criteria, not an outcome deny-list'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'New-UniqueOutputDirectory'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle "'{0:D3}-{1}' -f"
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'DiscoveryFailed'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle '$failedDiscoveryRecords'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Test-IsSuccessfulDiscoveryOutcome'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle "return (`$Outcome -in @('SearchOnly', 'NoApplicableUpdates'))"
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Discovery returned outcome'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle '$agentRun.AgentResult.Completed'
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?s)if\s*\(\$targetVMNames\.Count\s+-gt\s+1\).*?\breturn\b' -Reason 'multi-VM discovery must fall through to the final exit'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Skipped: Failover Cluster detected. Please update manually one by one.'
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?i)\$kbArticleIds\.Count\b' -Reason 'ConvertFrom-Json can collapse one KB article id to a scalar under StrictMode'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Confirm-GuestReboot'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Type REBOOT to continue'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Invoke-GuestRebootPhase'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Invoke-ApplyAndOptionalReboot'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Get-GuestRebootJobScript'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Write-RebootActionArtifacts'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Resolve-VIServerCredentialMap'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'VIServerCredentialMap'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Connect-VIServersWithCredentialMap'
    Assert-TextMatches -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?s)function\s+Confirm-GuestReboot\b.*?Read-Host.*?REBOOT' -Reason 'reboot confirmation is an explicit REBOOT prompt'
    Assert-TextMatches -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?s)function\s+Invoke-GuestRebootPhase\b.*?Invoke-ThrottledJobs.*?-ThrottleLimit\s+\$RebootBatchSize' -Reason 'reboot initiation is bounded by the reboot batch size, not by the apply concurrency'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Read-RebootBatchSize'
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?s)function\s+Read-RebootBatchSize\b(?:(?!\bfunction\b).)*?SkipConfirmation' -Reason 'reboot batch size prompt must not honor -SkipConfirmation, matching the REBOOT prompt'
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?s)function\s+Confirm-GuestReboot\b(?:(?!\bfunction\b).)*?SkipConfirmation' -Reason 'reboot confirmation must not honor -SkipConfirmation'
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern 'Validation summary' -Reason 'Single-VM validation summary path was unified into the phase-based flow'
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern 'skipSingleVmValidationSummary' -Reason 'Single-VM validation flag removed by path unification'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle '$roundSelection.Aborted'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle '$planSelection.Aborted'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle '$viserverCredentialMap = $StoredVIServerCredentials'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle '$guestCredentialMap = $StoredGuestCredentials'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle '$PromptProvider[''PromptCredential'']'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle '-CredentialPromptScript $credentialPromptScript -RetryOnFailure'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle '-OverrideCredential $GuestCredential -CredentialPromptScript $credentialPromptScript'
}

if ($existingScripts.ContainsKey($runtimeHelperPath)) {
    $runtimeHelperAst = Get-ScriptAst -RelativePath $runtimeHelperPath -Path $existingScripts[$runtimeHelperPath]
    $runtimeHelperText = Get-ScriptText -Path $existingScripts[$runtimeHelperPath]

    Assert-NoForbiddenCommand -Ast $runtimeHelperAst -RelativePath $runtimeHelperPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $runtimeHelperPath -Text $runtimeHelperText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $runtimeHelperAst -RelativePath $runtimeHelperPath -ReservedNames $reservedVariableNames
    Assert-NoOrphanedBranchKeyword -Ast $runtimeHelperAst -RelativePath $runtimeHelperPath
    Assert-TextDoesNotMatch -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'Invoke-ThrottledJobs'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'Test-IsApplyResultError'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'Start-Job'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'Receive-Job'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'New-ThrottledJobErrorResult'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'StartedAt'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'Stop-Job'
    Assert-TextDoesNotMatch -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Pattern '(?i)Stop-Job\b[^\r\n]*-Force' -Reason 'Stop-Job -Force is not available in Windows PowerShell 5.1'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'Receive-Job returned no output.'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'Test-ApplyResultsSuccessful'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle "`$ApplyResult.action -eq 'Install' -and `$ApplyResult.outcome -ne 'InstallSucceeded'"
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle "`$ApplyResult.action -ne 'Install' -and `$ApplyResult.reason -eq 'Skipped: Discovery failed. Review discovery.json and per-VM agent artifacts.'"
    Assert-TextMatches -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Pattern '(?s)function\s+Test-ApplyResultsSuccessful\b.*?Test-IsApplyResultError\s+-ApplyResult\s+\$_' -Reason 'apply success uses shared apply-result error semantics'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'New-ApplyResultFromCycle'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle '$agentResult.Completed'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle '$agentResult.ExitCode'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'Apply guest process did not complete.'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'Apply guest process exited with code'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'Test-IsTerminalAgentOutcome'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'Select-RebootRequiredApplyResults'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'New-RebootActionRecord'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'New-SkippedRebootActionRecords'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'Test-RebootActionsSuccessful'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'Write-RebootActionArtifacts'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'reboot-actions.json'
    Assert-TextContains -RelativePath $runtimeHelperPath -Text $runtimeHelperText -Needle 'Invoke-InProcessAgentFleet'
    # AST, not text: the rule is "no interactive prompt is called from here", which a comment
    # explaining why the prompt lives elsewhere must not trip. The AST pass only sees
    # statically-named commands, so the literal scan backs it up for dynamic dispatch -
    # Set-Alias, Invoke-Expression, & $name - exactly as it does for $forbiddenCommands.
    Assert-NoForbiddenCommand -Ast $runtimeHelperAst -RelativePath $runtimeHelperPath -ForbiddenNames @('Read-Host')
    Assert-NoForbiddenCommandLiteral -RelativePath $runtimeHelperPath -Text $runtimeHelperText -ForbiddenNames @('Read-Host')
}

if ($existingScripts.ContainsKey($launcherPath)) {
    $launcherAst = Get-ScriptAst -RelativePath $launcherPath -Path $existingScripts[$launcherPath]
    $launcherText = Get-ScriptText -Path $existingScripts[$launcherPath]

    Assert-NoForbiddenCommand -Ast $launcherAst -RelativePath $launcherPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $launcherPath -Text $launcherText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $launcherAst -RelativePath $launcherPath -ReservedNames $reservedVariableNames
    Assert-NoOrphanedBranchKeyword -Ast $launcherAst -RelativePath $launcherPath
    Assert-TextDoesNotMatch -RelativePath $launcherPath -Text $launcherText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'Invoke-StaticChecks.ps1'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'Invoke-ModelChecks.ps1'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'Invoke-GuestOpsPatchValidation.ps1'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'VMTargetLib.ps1'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'InstallSelection'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'VMNames'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'VMListPath'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'ThrottleLimit'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'PlanOnly'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'SkipConfirmation'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'SelectedUpdateKeys'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle "PSBoundParameters.ContainsKey('SelectedUpdateKeys')"
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'PatchPlanPath'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'Resolve-VMTargetNames'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle '$PSScriptRoot'
}

if ($existingScripts.ContainsKey($modelPath)) {
    $modelAst = Get-ScriptAst -RelativePath $modelPath -Path $existingScripts[$modelPath]
    $modelText = Get-ScriptText -Path $existingScripts[$modelPath]

    Assert-NoForbiddenCommand -Ast $modelAst -RelativePath $modelPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $modelPath -Text $modelText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $modelAst -RelativePath $modelPath -ReservedNames $reservedVariableNames
    Assert-NoOrphanedBranchKeyword -Ast $modelAst -RelativePath $modelPath
    Assert-TextDoesNotMatch -RelativePath $modelPath -Text $modelText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $modelPath -Text $modelText -Needle 'New-CanonicalUpdateIdentityKey'
    Assert-TextContains -RelativePath $modelPath -Text $modelText -Needle 'New-UpdateGroupRecords'
    Assert-TextContains -RelativePath $modelPath -Text $modelText -Needle 'Get-DefaultUpdateSelection'
    Assert-TextContains -RelativePath $modelPath -Text $modelText -Needle 'New-PatchPlanRecords'
    Assert-TextContains -RelativePath $modelPath -Text $modelText -Needle 'ConvertTo-PatchPlanRecords'
    Assert-TextContains -RelativePath $modelPath -Text $modelText -Needle 'ConvertTo-PatchSummaryRows'
    # The plan listing and its counts render here, not in either surface, so the console and
    # the GUI approval window cannot describe one plan differently.
    Assert-TextContains -RelativePath $modelPath -Text $modelText -Needle 'Get-PatchPlanDisplayLines'
    Assert-TextContains -RelativePath $modelPath -Text $modelText -Needle 'Get-PatchPlanSummaryLine'
    Assert-TextContains -RelativePath $modelPath -Text $modelText -Needle 'Get-VMPatchCompletionStates'
    Assert-TextContains -RelativePath $modelPath -Text $modelText -Needle 'Get-NextRoundVMNames'
}

if ($existingScripts.ContainsKey($modelTestPath)) {
    $modelTestAst = Get-ScriptAst -RelativePath $modelTestPath -Path $existingScripts[$modelTestPath]
    $modelTestText = Get-ScriptText -Path $existingScripts[$modelTestPath]

    Assert-NoForbiddenCommand -Ast $modelTestAst -RelativePath $modelTestPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $modelTestPath -Text $modelTestText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $modelTestAst -RelativePath $modelTestPath -ReservedNames $reservedVariableNames
    Assert-NoOrphanedBranchKeyword -Ast $modelTestAst -RelativePath $modelTestPath
    Assert-TextContains -RelativePath $modelTestPath -Text $modelTestText -Needle 'PatchPlanModel.ps1'
    Assert-TextContains -RelativePath $modelTestPath -Text $modelTestText -Needle 'Model checks passed.'
}

if ($existingScripts.ContainsKey($identityHelperPath)) {
    $identityHelperAst = Get-ScriptAst -RelativePath $identityHelperPath -Path $existingScripts[$identityHelperPath]
    $identityHelperText = Get-ScriptText -Path $existingScripts[$identityHelperPath]

    Assert-NoForbiddenCommand -Ast $identityHelperAst -RelativePath $identityHelperPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $identityHelperPath -Text $identityHelperText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $identityHelperAst -RelativePath $identityHelperPath -ReservedNames $reservedVariableNames
    Assert-NoOrphanedBranchKeyword -Ast $identityHelperAst -RelativePath $identityHelperPath
    Assert-TextContains -RelativePath $identityHelperPath -Text $identityHelperText -Needle 'New-CanonicalUpdateIdentityKey'
}

if ($existingScripts.ContainsKey($runtimeTestPath)) {
    $runtimeTestAst = Get-ScriptAst -RelativePath $runtimeTestPath -Path $existingScripts[$runtimeTestPath]
    $runtimeTestText = Get-ScriptText -Path $existingScripts[$runtimeTestPath]

    Assert-NoForbiddenCommand -Ast $runtimeTestAst -RelativePath $runtimeTestPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $runtimeTestPath -Text $runtimeTestText -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $runtimeTestAst -RelativePath $runtimeTestPath -ReservedNames $reservedVariableNames
    Assert-NoOrphanedBranchKeyword -Ast $runtimeTestAst -RelativePath $runtimeTestPath
    Assert-TextContains -RelativePath $runtimeTestPath -Text $runtimeTestText -Needle 'Runtime checks passed.'
}

if ($existingScripts.ContainsKey($harnessTestPath)) {
    $harnessTestAst = Get-ScriptAst -RelativePath $harnessTestPath -Path $existingScripts[$harnessTestPath]
    $harnessTestText = Get-ScriptText -Path $existingScripts[$harnessTestPath]

    Assert-NoForbiddenCommand -Ast $harnessTestAst -RelativePath $harnessTestPath -ForbiddenNames $forbiddenCommands
    Assert-NoForbiddenCommandLiteral -RelativePath $harnessTestPath -Text $harnessTestText -ForbiddenNames $forbiddenCommands
    Assert-NoOrphanedBranchKeyword -Ast $harnessTestAst -RelativePath $harnessTestPath
    Assert-NoReservedVariableName -Ast $harnessTestAst -RelativePath $harnessTestPath -ReservedNames $reservedVariableNames
    Assert-TextDoesNotMatch -RelativePath $harnessTestPath -Text $harnessTestText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $harnessTestPath -Text $harnessTestText -Needle 'Harness checks passed.'
    # The harness must stay optional: it is the only gate that needs PowerCLI installed.
    Assert-TextContains -RelativePath $harnessTestPath -Text $harnessTestText -Needle 'Harness checks skipped'
    # It must exercise the real cycle functions, not a reimplementation of them.
    Assert-TextContains -RelativePath $harnessTestPath -Text $harnessTestText -Needle 'Start-VMAgentCycle'
    Assert-TextContains -RelativePath $harnessTestPath -Text $harnessTestText -Needle 'Test-VMAgentCycleComplete'
    Assert-TextContains -RelativePath $harnessTestPath -Text $harnessTestText -Needle 'Complete-VMAgentCycle'
}

foreach ($guiRelativePath in @($settingsStorePath, $guiPromptsPath, $guiLauncherPath)) {
    if ($existingScripts.ContainsKey($guiRelativePath)) {
        $guiAst = Get-ScriptAst -RelativePath $guiRelativePath -Path $existingScripts[$guiRelativePath]
        $guiText = Get-ScriptText -Path $existingScripts[$guiRelativePath]

        Assert-NoForbiddenCommand -Ast $guiAst -RelativePath $guiRelativePath -ForbiddenNames $forbiddenCommands
        Assert-NoForbiddenCommandLiteral -RelativePath $guiRelativePath -Text $guiText -ForbiddenNames $forbiddenCommands
        Assert-NoReservedVariableName -Ast $guiAst -RelativePath $guiRelativePath -ReservedNames $reservedVariableNames
        Assert-NoOrphanedBranchKeyword -Ast $guiAst -RelativePath $guiRelativePath
        Assert-TextDoesNotMatch -RelativePath $guiRelativePath -Text $guiText -Pattern '(?i)(ForEach-Object|%)\s+-Para' -Reason 'PowerShell 7 parallelism is out of scope'

    }
}

# A corrected vCenter password belongs to the one server that rejected it. Writing it to the
# group key would hand every other server behind that DNS suffix a credential nobody validated
# against them, so the GUI must reach the store through Get-TargetCredentialStoreKey. Scoped to
# the call itself rather than the whole file, because the group key is still correct elsewhere.
if ($existingScripts.ContainsKey($guiLauncherPath)) {
    $guiLauncherAst = Get-ScriptAst -RelativePath $guiLauncherPath -Path $existingScripts[$guiLauncherPath]
    $targetKeyCalls = @($guiLauncherAst.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        ([string]$node.GetCommandName()) -eq 'Get-TargetCredentialStoreKey'
    }, $true))

    if ($targetKeyCalls.Count -eq 0) {
        $failures += ('{0} never calls Get-TargetCredentialStoreKey, so a corrected vCenter password would overwrite the shared group entry' -f $guiLauncherPath)
    }
}

# Guest-side deletion is recursive and runs against a directory the customer configured, so it
# has exactly one entry point that everything else has to go through. A second call site would
# not have to be wrong to be dangerous - it would simply not be covered by the preconditions and
# path validation in Remove-CompletedVMAgentCycleArtifacts.
$guestDeletionPattern = '(?i)Delete(Directory|File)InGuest'
$guestDeletionSites = @()
# Production scripts only: the harness fixture necessarily defines a delete double.
foreach ($deletionRelativePath in @($existingScripts.Keys | Where-Object { $_ -notlike 'tests\*' })) {
    if (-not $existingScripts.ContainsKey($deletionRelativePath)) {
        continue
    }

    $deletionText = Get-ScriptText -Path $existingScripts[$deletionRelativePath]
    foreach ($deletionMatch in @([regex]::Matches($deletionText, $guestDeletionPattern))) {
        $guestDeletionSites += ('{0}: {1}' -f $deletionRelativePath, $deletionMatch.Value)
    }
}

if ($guestDeletionSites.Count -ne 1) {
    $failures += ('guest-side deletion must have exactly one call site, found {0}: {1}' -f $guestDeletionSites.Count, (@($guestDeletionSites) -join '; '))
}

if ($existingScripts.ContainsKey($guestOpsLibPath)) {
    $cleanupAst = Get-ScriptAst -RelativePath $guestOpsLibPath -Path $existingScripts[$guestOpsLibPath]
    $cleanupFunction = @($cleanupAst.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Remove-CompletedVMAgentCycleArtifacts'
    }, $true))

    if ($cleanupFunction.Count -ne 1) {
        $failures += ('{0} must define Remove-CompletedVMAgentCycleArtifacts as the single cleanup entry point' -f $guestOpsLibPath)
    }
    elseif (([string]$cleanupFunction[0].Extent.Text) -notmatch '(?i)Delete(Directory|File)InGuest') {
        $failures += ('{0}: the guest deletion call moved out of Remove-CompletedVMAgentCycleArtifacts, away from its preconditions' -f $guestOpsLibPath)
    }

    # A finally block would delete on the failure paths too - exactly the cycles whose guest-side
    # files are worth keeping - so the cleanup call must not sit in one.
    foreach ($tryStatement in @($cleanupAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.TryStatementAst] }, $true))) {
        if ($null -ne $tryStatement.Finally -and ([string]$tryStatement.Finally.Extent.Text) -match '(?i)Remove-CompletedVMAgentCycleArtifacts') {
            $failures += ('{0}: cycle cleanup must not run from a finally block' -f $guestOpsLibPath)
        }
    }
}

# --- AST-scoped replacements for four text rules that pinned spelling rather than behaviour ---
# A needle over the whole file answers "does this string appear", which a comment satisfies and a
# renamed variable breaks. These ask the syntax tree about the construct that actually matters.

function Get-CommandAstsByName {
    param($Ast, [string]$Name)

    return @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true) | Where-Object { ([string]$_.GetCommandName()) -eq $Name })
}

# The text of the value bound to one named parameter, or $null when the parameter is absent.
# Handles both spellings PowerShell accepts: -Name Value (the value is the next element) and
# -Name:Value (the parser attaches it to the parameter itself). Abbreviations bind here too, for
# the same reason Test-CommandAstHasParameter accepts them.
function Get-NamedArgumentText {
    param($Command, [string]$ParameterName)

    $elements = @($Command.CommandElements)
    for ($index = 0; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            continue
        }

        $written = [string]$element.ParameterName
        if ([string]::IsNullOrWhiteSpace($written) -or -not $ParameterName.StartsWith($written, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        if ($null -ne $element.Argument) {
            return [string]$element.Argument.Extent.Text
        }
        if ($index + 1 -lt $elements.Count -and $elements[$index + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            return [string]$elements[$index + 1].Extent.Text
        }
        # Written, but with nothing after it: a switch, or a call that will not bind.
        return ''
    }

    return $null
}

# PowerShell binds abbreviations, so -SkipConfirm reaches -SkipConfirmation. A rule that only
# matched the full spelling would be trivially avoidable without meaning to avoid it.
function Test-CommandAstHasParameter {
    param($CommandAst, [string]$ParameterName)

    foreach ($element in @($CommandAst.CommandElements)) {
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            continue
        }

        $written = [string]$element.ParameterName
        if ([string]::IsNullOrWhiteSpace($written)) {
            continue
        }

        if ($ParameterName.StartsWith($written, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-CommandAstSplats {
    param($CommandAst)

    foreach ($element in @($CommandAst.CommandElements)) {
        if ($element -is [System.Management.Automation.Language.VariableExpressionAst] -and $element.Splatted) {
            return $true
        }
    }

    return $false
}

# Returns 'ok', 'missing', or the first shortfall. The gate and the in-memory probes both call
# this, so a probe can never report that a rule works after the rule has been weakened.
# Returns the argument written for one parameter, or $null when the parameter is absent. Needed
# because "the parameter appears somewhere on the call" is not the same fact as "the parameter
# was given something" - and a rule that cannot tell them apart is the one this replaces.
function Get-CommandAstArgument {
    param($CommandAst, [string]$ParameterName)

    $elements = @($CommandAst.CommandElements)
    for ($index = 0; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            continue
        }

        $written = [string]$element.ParameterName
        if ([string]::IsNullOrWhiteSpace($written) -or -not $ParameterName.StartsWith($written, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        # -Param:value keeps the argument on the parameter node; -Param value puts it next.
        if ($null -ne $element.Argument) {
            return $element.Argument
        }

        if ($index + 1 -lt $elements.Count -and $elements[$index + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            return $elements[$index + 1]
        }

        return 'present-without-argument'
    }

    return $null
}

function Test-FinalReportContract {
    param($Ast)

    $calls = @(Get-CommandAstsByName -Ast $Ast -Name 'Write-FinalReport')
    if ($calls.Count -eq 0) {
        return 'missing'
    }

    foreach ($call in $calls) {
        # A splatted call carries its arguments in a hashtable the AST cannot see into; demanding
        # named parameters there would be a false positive, so it is simply not checked.
        if (Test-CommandAstSplats -CommandAst $call) {
            continue
        }

        foreach ($requiredParameter in @('PatchPlanRecords', 'ApplyResults', 'CycleOutputDirectory', 'RebootTargets')) {
            $argument = Get-CommandAstArgument -CommandAst $call -ParameterName $requiredParameter
            if ($null -eq $argument -or ($argument -is [string] -and $argument -eq 'present-without-argument')) {
                return ('missing-' + $requiredParameter)
            }

            # $null is the dangerous one, not a typo: Write-FinalReport treats a null RebootTargets
            # as "work them out yourself" and recomputes them from the apply results alone, without
            # the discovery records - so every VM that is a reboot target only because discovery
            # reported pendingRebootBefore silently vanishes from the report's reboot section.
            if ($argument -is [System.Management.Automation.Language.VariableExpressionAst] -and
                [string]::Equals([string]$argument.VariablePath.UserPath, 'null', [System.StringComparison]::OrdinalIgnoreCase)) {
                return ('null-argument-' + $requiredParameter)
            }

            # An empty literal satisfies "the parameter is present" while passing nothing. Matched
            # against THIS parameter's own argument, so the reason names the right one.
            if ($argument -is [System.Management.Automation.Language.ArrayExpressionAst] -and
                @($argument.SubExpression.Statements).Count -eq 0) {
                return ('empty-argument-' + $requiredParameter)
            }
        }
    }

    return 'ok'
}

# The GUI must never hand the launcher a parameter that ends the patch-round loop after round
# one. Checking the call's parameters alone is not enough: the GUI builds a splat hashtable and
# adds most of its options by member assignment, which is invisible to a CommandParameterAst scan.
function Test-GuiForbiddenLauncherParameter {
    param($Ast)

    $forbidden = @('SelectedUpdateKeys', 'SkipConfirmation')

    foreach ($command in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))) {
        foreach ($forbiddenParameter in $forbidden) {
            if (Test-CommandAstHasParameter -CommandAst $command -ParameterName $forbiddenParameter) {
                return ('parameter-' + $forbiddenParameter)
            }
        }
    }

    foreach ($hashtable in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.HashtableAst]
    }, $true))) {
        foreach ($pair in @($hashtable.KeyValuePairs)) {
            $keyText = ([string]$pair.Item1.Extent.Text).Trim(([char]39), ([char]34))
            if ($forbidden -contains $keyText) {
                return ('splat-' + $keyText)
            }
        }
    }

    # $launcherParams.SkipConfirmation = $true and $launcherParams['SelectedUpdateKeys'] = ...
    # are how this GUI adds most of its launcher options, so they are the likeliest way the
    # parameter would arrive - and the only way the earlier text rule caught that this one must.
    foreach ($assignment in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true))) {
        $left = $assignment.Left
        $written = $null
        if ($left -is [System.Management.Automation.Language.MemberExpressionAst]) {
            $written = ([string]$left.Member.Extent.Text).Trim(([char]39), ([char]34))
        }
        elseif ($left -is [System.Management.Automation.Language.IndexExpressionAst]) {
            $written = ([string]$left.Index.Extent.Text).Trim(([char]39), ([char]34))
        }

        if ($null -ne $written -and $forbidden -contains $written) {
            return ('assignment-' + $written)
        }
    }

    return 'ok'
}

# The resume branch has to fall through to the single exit at the end of the script; a return
# anywhere in it would skip the computed exit code. Scoped to that branch's own statements, so a
# return inside a scriptblock elsewhere in the file - or the word in a comment - is not its business.
# A return at script scope ends the script. The finally block still runs, but Write-PatchRunSummary,
# the all-green evaluation and the final `exit $scriptExitCode` do not - so the process exits on a
# stale $LASTEXITCODE and a failed patch run is reported as success with no run-level artifacts.
# The rule therefore covers the whole tail of the script from the resume branch onwards, which is
# what the text needle it replaces reached, and not just the resume branch itself: the round loop
# below it leaves via `break` and is exactly where a `return` would be written by mistake.
# A VM lookup without an explicit connection scope silently falls back to PowerCLI's global
# default sessions, so it can return a VM from a vCenter this run never named - and that VM is
# then patched or rebooted. The scope is what makes the target set match the operator's list.
# Returns 'ok' or the first unscoped call site.
function Test-VMLookupsAreScoped {
    param($Ast)

    foreach ($call in @(Get-CommandAstsByName -Ast $Ast -Name 'Get-ExactVM')) {
        if (Test-CommandAstSplats -CommandAst $call) {
            continue
        }

        if (-not (Test-CommandAstHasParameter -CommandAst $call -ParameterName 'Servers')) {
            return ('line {0}: Get-ExactVM without -Servers' -f $call.Extent.StartLineNumber)
        }
    }

    return 'ok'
}

# The tool directory has to be proven safe before the first byte lands in it: an ordinary user
# who can write there replaces the agent between the upload and the start, and it runs as the
# patching account. Structural, because "throws on a refusal" is not the property that matters -
# "nothing was transferred on the way to throwing" is. Returns 'ok', or what is out of order.
function Test-GuestUploadsAreGuarded {
    param($Ast, [string[]]$FunctionNames)

    foreach ($functionName in @($FunctionNames)) {
        $definition = @($Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true) | Where-Object { $_.Name -eq $functionName })
        if (@($definition).Count -eq 0) {
            continue
        }

        $body = @($definition)[0]
        $guardLines = @(Get-CommandAstsByName -Ast $body -Name 'Assert-GuestWorkspaceReady' | ForEach-Object { $_.Extent.StartLineNumber })
        $transferLines = @(@('Send-GuestFile', 'Start-GuestAgent', 'Start-GuestBootTimeQuery') | ForEach-Object {
                Get-CommandAstsByName -Ast $body -Name $_ | ForEach-Object { $_.Extent.StartLineNumber }
            })

        if (@($transferLines).Count -eq 0) {
            continue
        }

        if (@($guardLines).Count -eq 0) {
            return ('{0} transfers to the guest without checking the workspace first' -f $functionName)
        }

        $firstGuard = (@($guardLines) | Sort-Object)[0]
        $firstTransfer = (@($transferLines) | Sort-Object)[0]
        if ($firstGuard -gt $firstTransfer) {
            return ('{0} transfers to the guest at line {1}, before the workspace check at line {2}' -f $functionName, $firstTransfer, $firstGuard)
        }
    }

    return 'ok'
}

# The seal is what turns "this directory was safe when the bootstrap checked it" into "this is
# still the directory the bootstrap secured". It only works if ONE token spans all three calls:
# the bootstrap writes it, and the guest program started afterwards is asked to verify that same
# token. Dropping -WorkspaceSealToken from the start would leave every earlier check in place and
# silently remove the only cover over the upload-to-start window, and the harness that exercises
# the coupling end to end needs PowerCLI types, so it skips on most machines. Structural for that
# reason. Returns 'ok' or the first function whose chain is broken.
function Test-GuestWorkspaceSealsSpanTheCycle {
    param($Ast, $Pairs)

    foreach ($pair in @($Pairs)) {
        $definition = @($Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true) | Where-Object { $_.Name -eq $pair.FunctionName })
        if (@($definition).Count -eq 0) {
            continue
        }

        $body = @($definition)[0]
        $starts = @(Get-CommandAstsByName -Ast $body -Name $pair.StartCommand)
        if (@($starts).Count -eq 0) {
            continue
        }

        # The token must be generated here, not passed in: a caller-supplied token would be one
        # the bootstrap of this cycle never wrote.
        $mintedTokens = @()
        foreach ($assignment in @($body.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst]
                    }, $true))) {
            if (([string]$assignment.Right.Extent.Text) -match '(?i)New-GuestWorkspaceSealToken') {
                $mintedTokens += ([string]$assignment.Left.Extent.Text).Trim()
            }
        }
        if (@($mintedTokens).Count -eq 0) {
            return ('{0} starts a guest program without minting a workspace seal token' -f $pair.FunctionName)
        }

        foreach ($commandName in @($pair.GuardCommand, $pair.StartCommand)) {
            $parameterName = if ($commandName -eq $pair.GuardCommand) { 'SealToken' } else { 'WorkspaceSealToken' }
            foreach ($command in @(Get-CommandAstsByName -Ast $body -Name $commandName)) {
                $argument = Get-NamedArgumentText -Command $command -ParameterName $parameterName
                if ($null -eq $argument) {
                    return ('{0}: {1} is called without -{2}' -f $pair.FunctionName, $commandName, $parameterName)
                }
                if (@($mintedTokens) -notcontains $argument.Trim()) {
                    return ('{0}: {1} -{2} is {3}, not the token minted in this cycle' -f $pair.FunctionName, $commandName, $parameterName, $argument.Trim())
                }
            }
        }
    }

    return 'ok'
}

# Writing a password to disk is a decision the operator makes, not one they have to notice and
# undo. DPAPI binds credentials.json to this Windows account on this machine and nothing more, so
# anything running as that account can read it back. The checkbox therefore starts unticked.
# Structural rather than behavioural because the dialog is WinForms: exercising it needs an STA
# host and a desktop, which the gates cannot assume. Returns 'ok', 'missing' or the offending value.
function Test-CredentialDialogDefaultsToNotRemember {
    param($Ast)

    $assignments = @($Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst]
            }, $true) | Where-Object {
            $left = [string]$_.Left.Extent.Text
            return ($left -match '(?i)^\$[a-z0-9_]*remember[a-z0-9_]*\.Checked$')
        })

    if (@($assignments).Count -eq 0) {
        return 'missing'
    }

    foreach ($assignment in $assignments) {
        $value = ([string]$assignment.Right.Extent.Text).Trim()
        if ($value -ine '$false') {
            return ('line {0}: {1}' -f $assignment.Extent.StartLineNumber, $value)
        }
    }

    return 'ok'
}


# The credential dialog is shared by the vCenter and the guest prompt, and only the guest one
# may offer Skip: skipping a vCenter would fail every VM behind it with a reason that names a
# password rather than the missing session, and the run would have nowhere to look them up.
# Exercising a WinForms dialog needs an STA host and a desktop the gates cannot assume, so the
# gating is pinned here. Returns 'ok', or what the skip control is gated on instead.
function Test-CredentialDialogSkipIsGated {
    param($Ast)

    $definition = @($Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-CredentialDialog'
            }, $true))

    if ($definition.Count -eq 0) {
        return 'Show-CredentialDialog was not found'
    }

    $paramBlock = $definition[0].Body.ParamBlock
    $parameterNames = if ($null -eq $paramBlock) { @() } else { @($paramBlock.Parameters | ForEach-Object { [string]$_.Name.VariablePath.UserPath }) }
    if ($parameterNames -notcontains 'AllowSkip') {
        return 'Show-CredentialDialog does not declare AllowSkip'
    }

    $visibility = @($definition[0].FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst]
            }, $true) | Where-Object {
            return (([string]$_.Left.Extent.Text) -match '(?i)^\$[a-z0-9_]*skip[a-z0-9_]*\.(Visible|Enabled)$')
        })

    if ($visibility.Count -eq 0) {
        return 'the skip control is never gated'
    }

    foreach ($assignment in $visibility) {
        if (([string]$assignment.Right.Extent.Text) -notmatch '(?i)\$AllowSkip') {
            return ('line {0}: {1}' -f $assignment.Extent.StartLineNumber, ([string]$assignment.Extent.Text).Trim())
        }
    }

    return 'ok'
}


# Reading a row must not change what gets installed on the fleet. The update group list therefore
# leaves CheckOnClick off AND refuses an ItemCheck the operator did not aim at the box - off alone
# still lets WinForms toggle on the second click anywhere on an already-selected row. Exercising a
# WinForms list needs an STA host and a desktop the gates cannot assume, so both halves are pinned
# here. Returns 'ok', or the half that is missing.
function Test-UpdateGroupDialogChecksOnlyOnPurpose {
    param($Ast)

    $definition = @($Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-UpdateGroupDialog'
            }, $true))

    if ($definition.Count -eq 0) {
        return 'Show-UpdateGroupDialog was not found'
    }

    foreach ($assignment in @($definition[0].FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst]
                }, $true))) {
        if ((([string]$assignment.Left.Extent.Text) -match '(?i)\.CheckOnClick$') -and
            (([string]$assignment.Right.Extent.Text).Trim() -imatch '^\$true$')) {
            return ('line {0}: the whole row toggles the box' -f $assignment.Extent.StartLineNumber)
        }
    }

    $guards = @($definition[0].FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and ([string]$node.Member.Extent.Text) -eq 'Add_ItemCheck'
            }, $true))

    if ($guards.Count -eq 0) {
        return 'nothing refuses a check the operator did not aim at the box'
    }

    return 'ok'
}

# The other half of the same rule, on the caller: the GUI must decide per scope, so a literal
# $true passed to -AllowSkip would offer Skip on the vCenter prompt too.
function Test-CredentialDialogSkipIsScoped {
    param($Ast)

    foreach ($command in @($Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true))) {
        if (([string]$command.GetCommandName()) -ine 'Show-CredentialDialog') {
            continue
        }

        $elements = @($command.CommandElements)
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $element = $elements[$i]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst] -or
                ([string]$element.ParameterName) -ine 'AllowSkip') {
                continue
            }

            # -AllowSkip:(expr) carries its argument; -AllowSkip expr leaves it in the next
            # element; a bare -AllowSkip is the switch on, which is the literal this forbids.
            $argument = $element.Argument
            if ($null -eq $argument -and ($i + 1) -lt $elements.Count) {
                $argument = $elements[$i + 1]
            }

            $argumentText = if ($null -eq $argument) { '(none)' } else { ([string]$argument.Extent.Text).Trim() }
            if ($argumentText -eq '(none)' -or $argumentText -imatch '^\$true$') {
                return ('line {0}: -AllowSkip {1}' -f $command.Extent.StartLineNumber, $argumentText)
            }
        }
    }

    return 'ok'
}

# Every apply-result branch has to come from one constructor. Four hand-written literals drifted
# apart before New-ApplyResultRecord existed: a property one branch happens not to set is a
# terminating error under StrictMode for whoever reads apply-results.json back, and a field
# silently missing from the timeout branch is a field the summary and the reboot selection
# disagree about. Returns 'ok' or the first branch that builds one by hand.
function Test-ApplyResultsUseSharedRecord {
    param($Ast)

    # The constructor's own literal is the one that is allowed to exist.
    $constructorExtents = @($Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-ApplyResultRecord'
            }, $true) | ForEach-Object { $_.Extent })

    foreach ($literal in @($Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.HashtableAst]
                }, $true))) {
        $keys = @()
        foreach ($pair in @($literal.KeyValuePairs)) {
            $keys += ([string]$pair.Item1.Extent.Text).Trim("'", '"')
        }

        # An apply result is recognised by the fields only an apply result has, so a per-VM
        # completion state or a fleet item is not mistaken for one.
        if (-not (($keys -contains 'vmName') -and ($keys -contains 'action') -and ($keys -contains 'outcome') -and ($keys -contains 'agentCompletionConfirmed'))) {
            continue
        }

        $insideConstructor = $false
        foreach ($constructorExtent in $constructorExtents) {
            if ($literal.Extent.StartOffset -ge $constructorExtent.StartOffset -and $literal.Extent.EndOffset -le $constructorExtent.EndOffset) {
                $insideConstructor = $true
                break
            }
        }

        if (-not $insideConstructor) {
            return ('line {0}: an apply result built by hand instead of through New-ApplyResultRecord' -f $literal.Extent.StartLineNumber)
        }
    }

    return 'ok'
}

function Test-ScriptTailHasReturn {
    param($Ast)

    $endBlock = $Ast.EndBlock
    if ($null -eq $endBlock) {
        return $null
    }

    $resumeOffset = $null
    foreach ($statement in @($endBlock.Statements)) {
        foreach ($ifStatement in @($statement.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst]
        }, $true))) {
            # Every clause, not just the first: restructuring the branch as an elseif must not
            # quietly move it out of scope.
            foreach ($clause in @($ifStatement.Clauses)) {
                if (([string]$clause.Item1.Extent.Text) -like '*IsNullOrWhiteSpace($PatchPlanPath)*') {
                    if ($null -eq $resumeOffset -or $statement.Extent.StartOffset -lt $resumeOffset) {
                        $resumeOffset = $statement.Extent.StartOffset
                    }
                }
            }
        }
    }

    if ($null -eq $resumeOffset) {
        return $null
    }

    foreach ($statement in @($endBlock.Statements | Where-Object { $_.Extent.StartOffset -ge $resumeOffset })) {
        foreach ($returnStatement in @($statement.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.ReturnStatementAst]
        }, $true))) {
            # A return inside a nested function or scriptblock leaves that scriptblock, not the
            # script, so it cannot skip the final exit code and is none of this rule's business.
            # The walk includes the statement itself: a top-level function definition IS the
            # statement, so stopping before it would read its return as script-scope.
            $enclosing = $returnStatement
            $nested = $false
            while ($null -ne $enclosing) {
                if ($enclosing -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
                    $enclosing -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    $nested = $true
                    break
                }
                if ($enclosing -eq $statement) {
                    break
                }
                $enclosing = $enclosing.Parent
            }

            if (-not $nested) {
                return $true
            }
        }
    }

    return $false
}

# The script must still end on the computed exit code; a rule about returns is only half the
# guarantee if nothing checks that the exit it protects is actually there.
function Test-ScriptExitsWithComputedCode {
    param($Ast)

    $endBlock = $Ast.EndBlock
    if ($null -eq $endBlock) {
        return $false
    }

    # The LAST top-level statement, not merely some exit somewhere: the resume branch has its own
    # exit, so "an exit with the computed code exists" would still hold after the final one was
    # changed to a literal - and that is the line every non-resume run leaves through.
    $topLevel = @($endBlock.Statements)
    if ($topLevel.Count -eq 0) {
        return $false
    }

    $last = $topLevel[$topLevel.Count - 1]
    return (([string]$last.Extent.Text) -match '(?i)^exit\s+\$scriptExitCode$')
}

if ($existingScripts.ContainsKey($orchestratorPath)) {
    $orchestratorAstForChecks = Get-ScriptAst -RelativePath $orchestratorPath -Path $existingScripts[$orchestratorPath]

    $tailHasReturn = Test-ScriptTailHasReturn -Ast $orchestratorAstForChecks
    if ($null -eq $tailHasReturn) {
        $failures += ('{0}: the -PatchPlanPath resume branch was not found, so the script tail cannot be checked' -f $orchestratorPath)
    }
    elseif ($tailHasReturn) {
        $failures += ('{0}: a return at script scope below the resume branch would skip the run summary and the computed exit code' -f $orchestratorPath)
    }

    if (-not (Test-ScriptExitsWithComputedCode -Ast $orchestratorAstForChecks)) {
        $failures += ('{0}: the script must end on exit $scriptExitCode' -f $orchestratorPath)
    }

    # The final report has to be handed the plan it applied and the reboot targets it computed.
    # Which variables carry them is the implementation's business; that they are passed is not.
    $finalReportVerdict = Test-FinalReportContract -Ast $orchestratorAstForChecks
    if ($finalReportVerdict -ne 'ok') {
        $failures += ('{0}: the Write-FinalReport contract is not met ({1})' -f $orchestratorPath, $finalReportVerdict)
    }
}

foreach ($applyRecordPath in @($orchestratorPath, $runtimeHelperPath)) {
    if (-not $existingScripts.ContainsKey($applyRecordPath)) {
        continue
    }

    $applyRecordVerdict = Test-ApplyResultsUseSharedRecord -Ast (Get-ScriptAst -RelativePath $applyRecordPath -Path $existingScripts[$applyRecordPath])
    if ($applyRecordVerdict -ne 'ok') {
        $failures += ('{0}: every apply result must be built by New-ApplyResultRecord ({1})' -f $applyRecordPath, $applyRecordVerdict)
    }
}

if ($existingScripts.ContainsKey($guiPromptsPath)) {
    $rememberVerdict = Test-CredentialDialogDefaultsToNotRemember -Ast (Get-ScriptAst -RelativePath $guiPromptsPath -Path $existingScripts[$guiPromptsPath])
    if ($rememberVerdict -ne 'ok') {
        $failures += ('{0}: the credential dialog must not offer to save a new password by default ({1})' -f $guiPromptsPath, $rememberVerdict)
    }

    $skipGateVerdict = Test-CredentialDialogSkipIsGated -Ast (Get-ScriptAst -RelativePath $guiPromptsPath -Path $existingScripts[$guiPromptsPath])
    if ($skipGateVerdict -ne 'ok') {
        $failures += ('{0}: the credential dialog may offer Skip only when the caller allows it ({1})' -f $guiPromptsPath, $skipGateVerdict)
    }

    $checkIntentVerdict = Test-UpdateGroupDialogChecksOnlyOnPurpose -Ast (Get-ScriptAst -RelativePath $guiPromptsPath -Path $existingScripts[$guiPromptsPath])
    if ($checkIntentVerdict -ne 'ok') {
        $failures += ('{0}: selecting an update row must not tick its box ({1})' -f $guiPromptsPath, $checkIntentVerdict)
    }
}

if ($existingScripts.ContainsKey($guiLauncherPath)) {
    $skipScopeVerdict = Test-CredentialDialogSkipIsScoped -Ast (Get-ScriptAst -RelativePath $guiLauncherPath -Path $existingScripts[$guiLauncherPath])
    if ($skipScopeVerdict -ne 'ok') {
        $failures += ('{0}: only a guest credential prompt may offer Skip; a vCenter cannot be skipped ({1})' -f $guiLauncherPath, $skipScopeVerdict)
    }
}

if ($existingScripts.ContainsKey($guestOpsLibPath)) {
    $guardedUploadVerdict = Test-GuestUploadsAreGuarded -Ast (Get-ScriptAst -RelativePath $guestOpsLibPath -Path $existingScripts[$guestOpsLibPath]) -FunctionNames @('Start-VMAgentCycle', 'Invoke-VMGuestBootTimeRead')
    if ($guardedUploadVerdict -ne 'ok') {
        $failures += ('{0}: the guest workspace must be secured before anything is written to it or run from it ({1})' -f $guestOpsLibPath, $guardedUploadVerdict)
    }

    $sealSpanVerdict = Test-GuestWorkspaceSealsSpanTheCycle -Ast (Get-ScriptAst -RelativePath $guestOpsLibPath -Path $existingScripts[$guestOpsLibPath]) -Pairs @(
        [pscustomobject]@{ FunctionName = 'Start-VMAgentCycle'; GuardCommand = 'Assert-GuestWorkspaceReady'; StartCommand = 'Start-GuestAgent' },
        [pscustomobject]@{ FunctionName = 'Invoke-VMGuestBootTimeRead'; GuardCommand = 'Assert-GuestWorkspaceReady'; StartCommand = 'Start-GuestBootTimeQuery' }
    )
    if ($sealSpanVerdict -ne 'ok') {
        $failures += ('{0}: the seal the bootstrap writes must be the seal the guest program verifies ({1})' -f $guestOpsLibPath, $sealSpanVerdict)
    }
}

foreach ($scopedLookupPath in @($orchestratorPath, $guestOpsLibPath)) {
    if (-not $existingScripts.ContainsKey($scopedLookupPath)) {
        continue
    }

    $scopedLookupVerdict = Test-VMLookupsAreScoped -Ast (Get-ScriptAst -RelativePath $scopedLookupPath -Path $existingScripts[$scopedLookupPath])
    if ($scopedLookupVerdict -ne 'ok') {
        $failures += ('{0}: every VM lookup must name the vCenter connections of this run ({1})' -f $scopedLookupPath, $scopedLookupVerdict)
    }
}

# Either parameter ends the patch-round loop after round one, in the ExplicitSelectionOnly and
# NonInteractive guards of Get-PatchRoundDecision, so a GUI run that passed one would silently
# collapse to a single round. The check is on the arguments the GUI actually passes to the
# launcher - a comment or a local variable of the same name is nobody's problem.
# All three GUI files, as the text rule this replaces covered. Only the launcher invokes the
# console entry point today, but a settings field forwarded generically would arrive the same way.
foreach ($guiForbiddenPath in @($guiLauncherPath, $guiPromptsPath, $settingsStorePath)) {
    if (-not $existingScripts.ContainsKey($guiForbiddenPath)) {
        continue
    }

    $guiVerdict = Test-GuiForbiddenLauncherParameter -Ast (Get-ScriptAst -RelativePath $guiForbiddenPath -Path $existingScripts[$guiForbiddenPath])
    if ($guiVerdict -ne 'ok') {
        $failures += ('{0}: a GUI run must not hand the launcher a parameter that caps it at one patch round ({1})' -f $guiForbiddenPath, $guiVerdict)
    }
}

# --- the AST checks above, checked against mutated text held only in memory ------------------
# A rule that cannot tell a comment from a violation is worse than no rule: it fails on harmless
# edits and passes on real ones, and people learn to work around it. These probes prove the four
# replacements distinguish the two. Nothing is written to disk.

function Assert-ProbeResult {
    param($Actual, $Expected, [string]$Message)

    if ($Actual -ne $Expected) {
        $script:failures += ('{0}: expected {1}, got {2}' -f $Message, $Expected, $Actual)
    }
}

function Test-AstRuleOnText {
    param([string]$Text, [scriptblock]$Rule)

    $probeErrors = $null
    $probeAst = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$probeErrors)
    if ($null -ne $probeErrors -and @($probeErrors).Count -gt 0) {
        return 'parse-error'
    }

    return (& $Rule $probeAst)
}

# Every probe calls the same function the gate calls. A probe with its own copy of the rule
# would keep reporting that the rule works after the rule had been weakened - which is exactly
# the failure mode these probes exist to prevent.
$resumeRule = {
    param($Ast)
    return (Test-ScriptTailHasReturn -Ast $Ast)
}

$resumeSource = @'
if (-not [string]::IsNullOrWhiteSpace($PatchPlanPath)) {
    $scriptExitCode = 0
}
function Get-Something { return 1 }
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $resumeSource -Rule $resumeRule) -Expected $false -Message 'a return inside an unrelated function does not trip the script-tail rule'


# Both halves of the credential-dialog skip rule, probed against synthetic sources. The rule
# itself is the one the gate calls: a probe carrying its own copy would go on reporting that a
# weakened rule works.
$skipGateRule = {
    param($Ast)
    return ((Test-CredentialDialogSkipIsGated -Ast $Ast) -eq 'ok')
}

$skipGatedSource = @'
function Show-CredentialDialog {
    param([string]$Message, [switch]$AllowSkip)
    $skip = New-Object System.Windows.Forms.Button
    $skip.Visible = [bool]$AllowSkip
    $skip.Enabled = [bool]$AllowSkip
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $skipGatedSource -Rule $skipGateRule) -Expected $true -Message 'a skip control gated on AllowSkip satisfies the credential dialog rule'

$skipAlwaysVisibleSource = @'
function Show-CredentialDialog {
    param([string]$Message, [switch]$AllowSkip)
    $skip = New-Object System.Windows.Forms.Button
    $skip.Visible = $true
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $skipAlwaysVisibleSource -Rule $skipGateRule) -Expected $false -Message 'a skip control shown unconditionally trips the credential dialog rule'

$skipNoParameterSource = @'
function Show-CredentialDialog {
    param([string]$Message)
    $skip = New-Object System.Windows.Forms.Button
    $skip.Visible = $false
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $skipNoParameterSource -Rule $skipGateRule) -Expected $false -Message 'a dialog without AllowSkip trips the credential dialog rule'


$checkIntentRule = {
    param($Ast)
    return ((Test-UpdateGroupDialogChecksOnlyOnPurpose -Ast $Ast) -eq 'ok')
}

$checkIntentGuardedSource = @'
function Show-UpdateGroupDialog {
    param($UpdateGroups)
    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.CheckOnClick = $false
    $list.Add_ItemCheck({ param($eventSender, $itemArgs) $itemArgs.NewValue = $itemArgs.CurrentValue })
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $checkIntentGuardedSource -Rule $checkIntentRule) -Expected $true -Message 'a guarded update list satisfies the check-intent rule'

$checkIntentOnClickSource = @'
function Show-UpdateGroupDialog {
    param($UpdateGroups)
    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.CheckOnClick = $true
    $list.Add_ItemCheck({ param($eventSender, $itemArgs) $itemArgs.NewValue = $itemArgs.CurrentValue })
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $checkIntentOnClickSource -Rule $checkIntentRule) -Expected $false -Message 'toggling on any click in the row trips the check-intent rule'

$checkIntentNoGuardSource = @'
function Show-UpdateGroupDialog {
    param($UpdateGroups)
    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.CheckOnClick = $false
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $checkIntentNoGuardSource -Rule $checkIntentRule) -Expected $false -Message 'an unguarded ItemCheck trips the check-intent rule'

$skipScopeRule = {
    param($Ast)
    return ((Test-CredentialDialogSkipIsScoped -Ast $Ast) -eq 'ok')
}

$skipScopedCallSource = @'
$entered = Show-CredentialDialog -Title 'T' -Message $message -AllowSkip:($missing.Scope -eq 'guest')
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $skipScopedCallSource -Rule $skipScopeRule) -Expected $true -Message 'a per-scope AllowSkip argument satisfies the caller rule'

$skipLiteralCallSource = @'
$entered = Show-CredentialDialog -Title 'T' -Message $message -AllowSkip:$true
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $skipLiteralCallSource -Rule $skipScopeRule) -Expected $false -Message 'a literal AllowSkip trips the caller rule'

$skipBareSwitchSource = @'
$entered = Show-CredentialDialog -Title 'T' -Message $message -AllowSkip
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $skipBareSwitchSource -Rule $skipScopeRule) -Expected $false -Message 'a bare AllowSkip switch trips the caller rule'

$resumeCommentSource = @'
if (-not [string]::IsNullOrWhiteSpace($PatchPlanPath)) {
    # deliberately no return here - the computed exit code is the only way out
    $scriptExitCode = 0
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $resumeCommentSource -Rule $resumeRule) -Expected $false -Message 'the word return in a comment does not trip the script-tail rule'

$resumeViolationSource = @'
if (-not [string]::IsNullOrWhiteSpace($PatchPlanPath)) {
    $scriptExitCode = 0
    return
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $resumeViolationSource -Rule $resumeRule) -Expected $true -Message 'an actual return in the resume branch trips the script-tail rule'

# The round loop sits below the resume branch and leaves via break. A return written there is
# the live risk: it skips the run summary and the computed exit code, and the old text needle
# reached it while a rule scoped to the resume branch alone would not.
$tailViolationSource = @'
if (-not [string]::IsNullOrWhiteSpace($PatchPlanPath)) {
    $scriptExitCode = 0
}
while ($true) {
    $scriptExitCode = 1
    return
}
exit $scriptExitCode
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $tailViolationSource -Rule $resumeRule) -Expected $true -Message 'a return in the round loop below the resume branch trips the script-tail rule'

$tailScriptblockSource = @'
if (-not [string]::IsNullOrWhiteSpace($PatchPlanPath)) {
    $scriptExitCode = 0
}
$decision = {
    param($Message)
    return 'CONTINUE'
}
exit $scriptExitCode
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $tailScriptblockSource -Rule $resumeRule) -Expected $false -Message 'a return inside a scriptblock below the resume branch does not trip the script-tail rule'

# Restructuring the branch as an elseif must not quietly move it out of scope.
$elseifSource = @'
if ($SearchOnly) {
    throw 'nope'
}
elseif (-not [string]::IsNullOrWhiteSpace($PatchPlanPath)) {
    $scriptExitCode = 0
    return
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $elseifSource -Rule $resumeRule) -Expected $true -Message 'a resume branch written as an elseif is still examined'

$exitRule = {
    param($Ast)
    return (Test-ScriptExitsWithComputedCode -Ast $Ast)
}

# The shared-apply-record rule, probed the same way.
$applyRecordRule = {
    param($Ast)
    return (Test-ApplyResultsUseSharedRecord -Ast $Ast)
}

$applyRecordOkSource = @'
$result = New-ApplyResultRecord -VMName $vmName -Outcome 'Failed' -Reason $reason
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $applyRecordOkSource -Rule $applyRecordRule) -Expected 'ok' -Message 'building an apply result through the constructor satisfies the shared-record rule'

$applyRecordViolationSource = @'
$result = [pscustomobject]@{ vmName = $vmName; action = 'Install'; outcome = 'Failed'; agentCompletionConfirmed = $false }
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $applyRecordViolationSource -Rule $applyRecordRule) -Expected 'line 1: an apply result built by hand instead of through New-ApplyResultRecord' -Message 'a hand-built apply result trips the shared-record rule'

$applyRecordConstructorSource = @'
function New-ApplyResultRecord {
    return [pscustomobject]@{ vmName = $VMName; action = $Action; outcome = $Outcome; agentCompletionConfirmed = $AgentCompletionConfirmed }
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $applyRecordConstructorSource -Rule $applyRecordRule) -Expected 'ok' -Message 'the constructor itself is allowed to build the object'

$applyRecordUnrelatedSource = @'
$state = [pscustomobject]@{ vmName = $vmName; state = 'Green'; reason = 'No selectable updates remain.' }
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $applyRecordUnrelatedSource -Rule $applyRecordRule) -Expected 'ok' -Message 'an unrelated per-VM object is not mistaken for an apply result'

# The remember-default rule, probed the same way.
$rememberRule = {
    param($Ast)
    return (Test-CredentialDialogDefaultsToNotRemember -Ast $Ast)
}

$rememberOkSource = @'
$remember = New-Object System.Windows.Forms.CheckBox
$remember.Checked = $false
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $rememberOkSource -Rule $rememberRule) -Expected 'ok' -Message 'an unticked remember checkbox satisfies the remember-default rule'

$rememberViolationSource = @'
$remember = New-Object System.Windows.Forms.CheckBox
$remember.Checked = $true
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $rememberViolationSource -Rule $rememberRule) -Expected 'line 2: $true' -Message 'a ticked remember checkbox trips the remember-default rule'

$rememberMissingSource = @'
$other = New-Object System.Windows.Forms.CheckBox
$other.Checked = $true
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $rememberMissingSource -Rule $rememberRule) -Expected 'missing' -Message 'a dialog with no remember checkbox at all is reported, not silently accepted'

$rememberCommentSource = @'
# $remember.Checked = $true
$remember.Checked = $false
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $rememberCommentSource -Rule $rememberRule) -Expected 'ok' -Message 'a ticked remember checkbox in a comment does not trip the remember-default rule'

# The scoped-lookup rule, probed the same way: a call with the scope passes, one without fails,
# an abbreviation still counts, and a splat is left to the runtime gates rather than guessed at.
$scopedLookupRule = {
    param($Ast)
    return (Test-VMLookupsAreScoped -Ast $Ast)
}

$scopedLookupOkSource = @'
$vm = Get-ExactVM -Name $VMName -Servers $VIServerScope
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $scopedLookupOkSource -Rule $scopedLookupRule) -Expected 'ok' -Message 'a scoped lookup satisfies the scoped-lookup rule'

$scopedLookupAbbreviatedSource = @'
$vm = Get-ExactVM -Name $VMName -Server $VIServerScope
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $scopedLookupAbbreviatedSource -Rule $scopedLookupRule) -Expected 'ok' -Message 'an abbreviated -Server still satisfies the scoped-lookup rule'

$scopedLookupSplatSource = @'
$vm = Get-ExactVM @lookupParams
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $scopedLookupSplatSource -Rule $scopedLookupRule) -Expected 'ok' -Message 'a splatted lookup is left to the runtime gates'

$scopedLookupViolationSource = @'
$vm = Get-ExactVM -Name $VMName
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $scopedLookupViolationSource -Rule $scopedLookupRule) -Expected 'line 1: Get-ExactVM without -Servers' -Message 'an unscoped lookup trips the scoped-lookup rule'

$scopedLookupCommentSource = @'
# Get-ExactVM -Name $VMName
$vm = Get-ExactVM -Name $VMName -Servers $VIServerScope
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $scopedLookupCommentSource -Rule $scopedLookupRule) -Expected 'ok' -Message 'an unscoped lookup in a comment does not trip the scoped-lookup rule'

# The guarded-upload rule, probed the same way.
$guardedUploadRule = {
    param($Ast)
    return (Test-GuestUploadsAreGuarded -Ast $Ast -FunctionNames @('Start-VMAgentCycle'))
}

$guardedUploadOkSource = @'
function Start-VMAgentCycle {
    Assert-GuestWorkspaceReady -Path $guestCycleDirectory
    Send-GuestFile -LocalPath $AgentPath
    Start-GuestAgent -GuestAgentPath $guestAgentPath
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $guardedUploadOkSource -Rule $guardedUploadRule) -Expected 'ok' -Message 'a cycle that secures the workspace first satisfies the guarded-upload rule'

$guardedUploadMissingSource = @'
function Start-VMAgentCycle {
    Send-GuestFile -LocalPath $AgentPath
    Start-GuestAgent -GuestAgentPath $guestAgentPath
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $guardedUploadMissingSource -Rule $guardedUploadRule) -Expected 'Start-VMAgentCycle transfers to the guest without checking the workspace first' -Message 'an unguarded upload trips the guarded-upload rule'

$guardedUploadLateSource = @'
function Start-VMAgentCycle {
    Send-GuestFile -LocalPath $AgentPath
    Assert-GuestWorkspaceReady -Path $guestCycleDirectory
    Start-GuestAgent -GuestAgentPath $guestAgentPath
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $guardedUploadLateSource -Rule $guardedUploadRule) -Expected 'Start-VMAgentCycle transfers to the guest at line 2, before the workspace check at line 3' -Message 'a workspace check after the first transfer trips the guarded-upload rule'

$guardedUploadNoTransferSource = @'
function Start-VMAgentCycle {
    $handle = New-VMAgentCycleHandle
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $guardedUploadNoTransferSource -Rule $guardedUploadRule) -Expected 'ok' -Message 'a function that transfers nothing needs no workspace check'

# The seal-span rule, probed the same way.
$sealSpanRule = {
    param($Ast)
    return (Test-GuestWorkspaceSealsSpanTheCycle -Ast $Ast -Pairs @(
            [pscustomobject]@{ FunctionName = 'Start-VMAgentCycle'; GuardCommand = 'Assert-GuestWorkspaceReady'; StartCommand = 'Start-GuestAgent' }
        ))
}

$sealSpanOkSource = @'
function Start-VMAgentCycle {
    $workspaceSealToken = New-GuestWorkspaceSealToken
    Assert-GuestWorkspaceReady -Path $guestCycleDirectory -SealToken $workspaceSealToken
    Start-GuestAgent -GuestAgentPath $guestAgentPath -WorkspaceSealToken $workspaceSealToken -SearchOnly:$SearchOnly
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $sealSpanOkSource -Rule $sealSpanRule) -Expected 'ok' -Message 'one minted token across the bootstrap and the start satisfies the seal-span rule'

$sealSpanUnsealedStartSource = @'
function Start-VMAgentCycle {
    $workspaceSealToken = New-GuestWorkspaceSealToken
    Assert-GuestWorkspaceReady -Path $guestCycleDirectory -SealToken $workspaceSealToken
    Start-GuestAgent -GuestAgentPath $guestAgentPath
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $sealSpanUnsealedStartSource -Rule $sealSpanRule) -Expected 'Start-VMAgentCycle: Start-GuestAgent is called without -WorkspaceSealToken' -Message 'a guest program started without the seal trips the seal-span rule'

$sealSpanUnsealedGuardSource = @'
function Start-VMAgentCycle {
    $workspaceSealToken = New-GuestWorkspaceSealToken
    Assert-GuestWorkspaceReady -Path $guestCycleDirectory
    Start-GuestAgent -GuestAgentPath $guestAgentPath -WorkspaceSealToken $workspaceSealToken
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $sealSpanUnsealedGuardSource -Rule $sealSpanRule) -Expected 'Start-VMAgentCycle: Assert-GuestWorkspaceReady is called without -SealToken' -Message 'a bootstrap that writes no seal trips the seal-span rule'

$sealSpanForeignTokenSource = @'
function Start-VMAgentCycle {
    $workspaceSealToken = New-GuestWorkspaceSealToken
    Assert-GuestWorkspaceReady -Path $guestCycleDirectory -SealToken $workspaceSealToken
    Start-GuestAgent -GuestAgentPath $guestAgentPath -WorkspaceSealToken $CallerSuppliedToken
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $sealSpanForeignTokenSource -Rule $sealSpanRule) -Expected 'Start-VMAgentCycle: Start-GuestAgent -WorkspaceSealToken is $CallerSuppliedToken, not the token minted in this cycle' -Message 'a token this cycle did not mint trips the seal-span rule'

$sealSpanNoTokenSource = @'
function Start-VMAgentCycle {
    Assert-GuestWorkspaceReady -Path $guestCycleDirectory
    Start-GuestAgent -GuestAgentPath $guestAgentPath
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $sealSpanNoTokenSource -Rule $sealSpanRule) -Expected 'Start-VMAgentCycle starts a guest program without minting a workspace seal token' -Message 'a cycle that mints no token trips the seal-span rule'

$sealSpanNoStartSource = @'
function Start-VMAgentCycle {
    $handle = New-VMAgentCycleHandle
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $sealSpanNoStartSource -Rule $sealSpanRule) -Expected 'ok' -Message 'a function that starts no guest program needs no seal'

# The colon spelling binds the same way, so the rule must read it.
$sealSpanColonSource = @'
function Start-VMAgentCycle {
    $workspaceSealToken = New-GuestWorkspaceSealToken
    Assert-GuestWorkspaceReady -Path $guestCycleDirectory -SealToken:$workspaceSealToken
    Start-GuestAgent -GuestAgentPath $guestAgentPath -WorkspaceSealToken:$workspaceSealToken
}
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $sealSpanColonSource -Rule $sealSpanRule) -Expected 'ok' -Message 'the -Name:Value spelling of the seal token is recognised'

$exitSource = @'
$scriptExitCode = 1
exit $scriptExitCode
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $exitSource -Rule $exitRule) -Expected $true -Message 'a script ending on the computed exit code satisfies the exit rule'

$exitLiteralSource = @'
$scriptExitCode = 1
exit 0
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $exitLiteralSource -Rule $exitRule) -Expected $false -Message 'a script ending on a literal exit code trips the exit rule'

# The resume branch has an exit of its own, so a rule that merely looked for one anywhere would
# stay green after the final exit - the one every other run leaves through - became a literal.
$exitEarlierSource = @'
if ($resume) {
    exit $scriptExitCode
}
$scriptExitCode = 1
exit 0
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $exitEarlierSource -Rule $exitRule) -Expected $false -Message 'an earlier exit with the computed code does not excuse a literal final exit'

$finalReportRule = {
    param($Ast)
    return (Test-FinalReportContract -Ast $Ast)
}

$finalReportSource = @'
Write-FinalReport -PatchPlanRecords $anythingAtAll -ApplyResults $results -CycleOutputDirectory $dir -RebootTargets $targets
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $finalReportSource -Rule $finalReportRule) -Expected 'ok' -Message 'renaming the variables passed to Write-FinalReport does not trip the rule'

$finalReportMissingSource = @'
Write-FinalReport -PatchPlanRecords $records -ApplyResults $results -CycleOutputDirectory $dir
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $finalReportMissingSource -Rule $finalReportRule) -Expected 'missing-RebootTargets' -Message 'dropping a required Write-FinalReport argument trips the rule'

# An empty literal satisfies "the parameter is present" while passing nothing, which is how the
# reboot targets would silently vanish from the report.
$finalReportEmptySource = @'
Write-FinalReport -PatchPlanRecords $records -ApplyResults $results -CycleOutputDirectory $dir -RebootTargets @()
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $finalReportEmptySource -Rule $finalReportRule) -Expected 'empty-argument-RebootTargets' -Message 'an empty literal trips the rule and names the parameter it was written for'

# $null is the one that does real damage: Write-FinalReport reads it as "recompute the reboot
# targets from the apply results alone", dropping every VM that only discovery knew needed one.
$finalReportNullSource = @'
Write-FinalReport -PatchPlanRecords $records -ApplyResults $results -CycleOutputDirectory $dir -RebootTargets $null
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $finalReportNullSource -Rule $finalReportRule) -Expected 'null-argument-RebootTargets' -Message 'passing $null for the reboot targets trips the rule'

$finalReportColonSource = @'
Write-FinalReport -PatchPlanRecords:$records -ApplyResults:$results -CycleOutputDirectory:$dir -RebootTargets:$targets
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $finalReportColonSource -Rule $finalReportRule) -Expected 'ok' -Message 'colon-form arguments are read as arguments, not as a missing parameter'

# A splatted call carries its arguments where the AST cannot see them; demanding named
# parameters there would be a false positive, not a finding.
$finalReportSplatSource = @'
Write-FinalReport @finalReportArgs
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $finalReportSplatSource -Rule $finalReportRule) -Expected 'ok' -Message 'a splatted Write-FinalReport call is not reported as missing arguments'

$guiRule = {
    param($Ast)
    return (Test-GuiForbiddenLauncherParameter -Ast $Ast)
}

$guiCommentSource = @'
# SelectedUpdateKeys is deliberately not passed; the provider returns the selection instead.
$selectedKeys = @()
& $launcher @launcherParams
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $guiCommentSource -Rule $guiRule) -Expected 'ok' -Message 'a comment naming the parameter does not trip the GUI rule'

$guiParameterSource = @'
& $launcher -VIServer $vc -SelectedUpdateKeys $keys
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $guiParameterSource -Rule $guiRule) -Expected 'parameter-SelectedUpdateKeys' -Message 'passing the parameter to the launcher trips the GUI rule'

$guiAbbreviationSource = @'
& $launcher -VIServer $vc -SkipConfirm
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $guiAbbreviationSource -Rule $guiRule) -Expected 'parameter-SkipConfirmation' -Message 'an abbreviated parameter still binds and still trips the GUI rule'

$guiSplatSource = @'
$launcherParams = @{ VIServer = $vc; SkipConfirmation = $true }
& $launcher @launcherParams
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $guiSplatSource -Rule $guiRule) -Expected 'splat-SkipConfirmation' -Message 'splatting the parameter into the launcher trips the GUI rule'

# This is how the GUI adds most of its launcher options, so it is the likeliest way the
# parameter would arrive - and the way a parameter-only scan would miss entirely.
$guiMemberSource = @'
$launcherParams = @{ VIServer = $vc }
$launcherParams.SkipConfirmation = $true
& $launcher @launcherParams
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $guiMemberSource -Rule $guiRule) -Expected 'assignment-SkipConfirmation' -Message 'assigning the parameter onto the splat hashtable trips the GUI rule'

$guiIndexSource = @'
$launcherParams = @{ VIServer = $vc }
$launcherParams['SelectedUpdateKeys'] = $keys
& $launcher @launcherParams
'@
Assert-ProbeResult -Actual (Test-AstRuleOnText -Text $guiIndexSource -Rule $guiRule) -Expected 'assignment-SelectedUpdateKeys' -Message 'indexing the parameter onto the splat hashtable trips the GUI rule'

# --- every shipped .ps1 must parse ---------------------------------------------------------------
# The rules above parse the files they reason about, which is not the same as parsing everything
# that ships. This tool is hand-copied onto a customer stepping stone, so a file truncated by an
# interrupted copy or a flaky share is a realistic failure mode - and it surfaced exactly that way:
# a test file cut mid-line, the static gate green because it never opened that file, and a raw
# parser error three gates later that reads like a code defect rather than a damaged copy.
#
# The first gate is where that belongs. Everything under the repository root is swept, including
# the tests themselves, so a bad copy is named with its file and line before anything is run.
& {
    $sweptRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $ignoredSegments = @('\out\', '\spec\', '\.git\', '\docs\superpowers\')
    foreach ($swept in @(Get-ChildItem -LiteralPath $sweptRoot -Filter '*.ps1' -Recurse -File -ErrorAction SilentlyContinue)) {
        $sweptPath = [string]$swept.FullName
        $comparable = ($sweptPath -replace '/', '\')
        $skip = $false
        foreach ($ignored in $ignoredSegments) {
            if ($comparable.IndexOf($ignored, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $skip = $true
                break
            }
        }
        if ($skip) {
            continue
        }

        $sweptErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($sweptPath, [ref]$null, [ref]$sweptErrors)
        foreach ($sweptError in @($sweptErrors)) {
            $relative = $sweptPath
            if ($relative.StartsWith($sweptRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $relative = $relative.Substring($sweptRoot.Length).TrimStart('\', '/')
            }
            Add-Failure -Message ("Parse error in {0} at line {1}, column {2}: {3} (a file that does not parse is usually a truncated or partial copy, not a code defect)" -f $relative, $sweptError.Extent.StartLineNumber, $sweptError.Extent.StartColumnNumber, $sweptError.Message)
        }
    }
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

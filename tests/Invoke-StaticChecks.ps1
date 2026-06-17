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

$existingScripts = @{}
foreach ($relativePath in @($agentPath, $orchestratorPath, $launcherPath)) {
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
    Assert-NoReservedVariableName -Ast $agentAst -RelativePath $agentPath -ReservedNames $reservedVariableNames
    Assert-TextDoesNotMatch -RelativePath $agentPath -Text $agentText -Pattern '(?i)ForEach-Object\s+-Parallel' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'Microsoft.Update.Session'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'CreateUpdateSearcher'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'CreateUpdateDownloader'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'CreateUpdateInstaller'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'ConvertTo-Json'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'Test-PendingReboot'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'Get-OptionalPropertyValue'
    Assert-TextDoesNotMatch -RelativePath $agentPath -Text $agentText -Pattern '(?i)\$[a-z_][a-z0-9_]*\.HResult\b' -Reason 'WUA COM HResult can be absent under StrictMode'
}

if ($existingScripts.ContainsKey($orchestratorPath)) {
    $orchestratorAst = Get-ScriptAst -RelativePath $orchestratorPath -Path $existingScripts[$orchestratorPath]
    $orchestratorText = Get-ScriptText -Path $existingScripts[$orchestratorPath]

    Assert-NoForbiddenCommand -Ast $orchestratorAst -RelativePath $orchestratorPath -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $orchestratorAst -RelativePath $orchestratorPath -ReservedNames $reservedVariableNames
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?i)ForEach-Object\s+-Parallel' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'StartProgramInGuest'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'ListProcessesInGuest'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'InitiateFileTransferToGuest'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'InitiateFileTransferFromGuest'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'curl.exe'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Agent errors:'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'Pending reboot checks:'
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?i)\$kbArticleIds\.Count\b' -Reason 'ConvertFrom-Json can collapse one KB article id to a scalar under StrictMode'
}

if ($existingScripts.ContainsKey($launcherPath)) {
    $launcherAst = Get-ScriptAst -RelativePath $launcherPath -Path $existingScripts[$launcherPath]
    $launcherText = Get-ScriptText -Path $existingScripts[$launcherPath]

    Assert-NoForbiddenCommand -Ast $launcherAst -RelativePath $launcherPath -ForbiddenNames $forbiddenCommands
    Assert-NoReservedVariableName -Ast $launcherAst -RelativePath $launcherPath -ReservedNames $reservedVariableNames
    Assert-TextDoesNotMatch -RelativePath $launcherPath -Text $launcherText -Pattern '(?i)ForEach-Object\s+-Parallel' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'Invoke-StaticChecks.ps1'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'Invoke-GuestOpsPatchValidation.ps1'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle 'Get-Credential'
    Assert-TextContains -RelativePath $launcherPath -Text $launcherText -Needle '$PSScriptRoot'
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

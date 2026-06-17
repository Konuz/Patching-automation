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

$agentPath = 'guest\Run-LocalPatch.ps1'
$orchestratorPath = 'scripts\Invoke-GuestOpsPatchValidation.ps1'

$existingScripts = @{}
foreach ($relativePath in @($agentPath, $orchestratorPath)) {
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

if ($existingScripts.ContainsKey($agentPath)) {
    $agentAst = Get-ScriptAst -RelativePath $agentPath -Path $existingScripts[$agentPath]
    $agentText = Get-ScriptText -Path $existingScripts[$agentPath]

    Assert-NoForbiddenCommand -Ast $agentAst -RelativePath $agentPath -ForbiddenNames $forbiddenCommands
    Assert-TextDoesNotMatch -RelativePath $agentPath -Text $agentText -Pattern '(?i)ForEach-Object\s+-Parallel' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'Microsoft.Update.Session'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'CreateUpdateSearcher'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'CreateUpdateDownloader'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'CreateUpdateInstaller'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'ConvertTo-Json'
    Assert-TextContains -RelativePath $agentPath -Text $agentText -Needle 'Test-PendingReboot'
}

if ($existingScripts.ContainsKey($orchestratorPath)) {
    $orchestratorAst = Get-ScriptAst -RelativePath $orchestratorPath -Path $existingScripts[$orchestratorPath]
    $orchestratorText = Get-ScriptText -Path $existingScripts[$orchestratorPath]

    Assert-NoForbiddenCommand -Ast $orchestratorAst -RelativePath $orchestratorPath -ForbiddenNames $forbiddenCommands
    Assert-TextDoesNotMatch -RelativePath $orchestratorPath -Text $orchestratorText -Pattern '(?i)ForEach-Object\s+-Parallel' -Reason 'PowerShell 7 parallelism is out of scope'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'StartProgramInGuest'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'ListProcessesInGuest'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'InitiateFileTransferToGuest'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'InitiateFileTransferFromGuest'
    Assert-TextContains -RelativePath $orchestratorPath -Text $orchestratorText -Needle 'curl.exe'
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

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Start-PatchingGuestOps.ps1'), [ref]$tokens, [ref]$parseErrors)
$definition = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-LocalCheck' }, $true))
if ($definition.Count -ne 1) { throw 'The launcher must define Invoke-LocalCheck.' }
. ([scriptblock]::Create($definition[0].Extent.Text))

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('launcher checks ' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
try {
    $probe = Join-Path $testRoot 'check probe.ps1'
    $logPath = Join-Path $testRoot 'check.log'
    Set-Content -LiteralPath $probe -Encoding UTF8 -Value "Write-Warning 'synthetic warning'; Write-Host 'fixture-vm activity'; exit 0"
    $result = @(Invoke-LocalCheck -Name 'Probe' -ScriptPath $probe -LogPath $logPath *>&1)
    if ($result[-1] -ne 0) { throw 'A passing check must return zero.' }
    $display = $result -join "`n"
    if ($display -match 'synthetic warning|fixture-vm') { throw 'Passing checks must keep fixture output out of the console.' }
    if ($display -notmatch 'PASSED') { throw 'A passing check needs a clear summary.' }
    if ((Get-Content $logPath -Raw) -notmatch 'synthetic warning') { throw 'The detailed log must preserve warnings.' }

    Set-Content -LiteralPath $probe -Encoding UTF8 -Value "Write-Host 'SKIPPED: ACL needs elevation'; Write-Host 'Harness checks skipped: no VMware types.'; exit 0"
    $result = @(Invoke-LocalCheck -Name 'Probe' -ScriptPath $probe -LogPath $logPath *>&1)
    $display = $result -join "`n"
    if ($display -notmatch 'WITH SKIPS' -or $display -notmatch 'ACL needs elevation' -or $display -notmatch 'no VMware types') { throw 'Skipped checks must remain visible and must not be reported as a full pass.' }

    Set-Content -LiteralPath $probe -Encoding UTF8 -Value "Write-Error 'actual check failure'; exit 7"
    $result = @(Invoke-LocalCheck -Name 'Probe' -ScriptPath $probe -LogPath $logPath *>&1)
    if ($result[-1] -ne 7) { throw 'The child exit code must survive stderr output.' }
    $display = $result -join "`n"
    if ($display -notmatch 'FAILED' -or ($display -replace '\s', '') -notmatch 'actualcheckfailure') { throw ('A failed check must show its diagnostics. Actual: ' + $display) }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
Write-Host 'Launcher checks passed.'

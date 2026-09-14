Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/GuestOpsLib.ps1')
. (Join-Path $repoRoot 'scripts/SettingsStore.ps1')
if ($script:GuestTransferIgnoreCertificate) { throw 'A newly loaded library must verify ESXi certificates.' }
$tokens = $null; $parseErrors = $null
$orchestratorAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts/Invoke-GuestOpsPatchValidation.ps1'), [ref]$tokens, [ref]$parseErrors)
$policyAssignment = @($orchestratorAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:GuestTransferIgnoreCertificate' }, $true))
if ($policyAssignment.Count -ne 1) { throw 'The orchestrator must initialize its ESXi certificate policy on each run.' }
$initializePolicy = [scriptblock]::Create($policyAssignment[0].Extent.Text)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('certificate-checks-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
try {
    $fakeCurl = Join-Path $testRoot 'curl.ps1'
    $argumentLog = Join-Path $testRoot 'arguments.txt'
    Set-Content -LiteralPath $fakeCurl -Encoding UTF8 -Value ('$args | Set-Content -LiteralPath ''' + $argumentLog.Replace("'", "''") + "'`nexit 0")
    $fileManager = New-Object psobject
    $fileManager | Add-Member ScriptMethod InitiateFileTransferFromGuest { param($MoRef, $Auth, $Path) return [pscustomobject]@{ Url = 'https://*/file'; Size = 0 } }
    foreach ($ignore in @($false, $true, $false)) {
        $IgnoreESXiCertificate = $ignore
        $IgnoreVCenterCertificate = $true
        . $initializePolicy
        Assert-GuestTransferEndpoint -HostName 'esxi.invalid' -CurlPath $fakeCurl
        $actual = @(Get-Content $argumentLog)
        if (($actual -contains '--insecure') -ne $ignore) { throw 'ESXi preflight must honor the explicit certificate policy.' }
        if ($actual[0] -ne '--disable') { throw 'curl must still ignore its config file.' }
        Receive-GuestFile -FileManager $fileManager -VMView ([pscustomobject]@{ MoRef = 'vm-test' }) -GuestAuth $null -HostName 'esxi.invalid' -CurlPath $fakeCurl -GuestPath 'C:\status.json' -LocalPath (Join-Path $testRoot 'status.json')
        $actual = @(Get-Content $argumentLog)
        if (($actual -contains '--insecure') -ne $ignore) { throw 'ESXi downloads must honor the same policy as preflight.' }
        if ($actual -notcontains '--max-time') { throw 'The transfer deadline must survive the certificate option.' }
    }
    $settings = New-DefaultGuiSettings
    if ($settings.IgnoreESXiCertificate -ne $false) { throw 'Certificate verification must be the GUI default.' }
    $settingsPath = Join-Path $testRoot 'settings.json'
    foreach ($ignore in @($true, $false)) {
        $settings.IgnoreESXiCertificate = $ignore
        Write-GuiSettings -Path $settingsPath -Settings $settings
        $read = Read-GuiSettings -Path $settingsPath
        if ($read.Settings.IgnoreESXiCertificate -ne $ignore) { throw 'The explicit GUI certificate choice must round-trip.' }
    }
    foreach ($legacySettings in @('{}', '{"IgnoreVCenterCertificate":true}', '{"IgnoreESXiCertificate":"false"}')) {
        Set-Content -LiteralPath $settingsPath -Value $legacySettings
        if ((Read-GuiSettings -Path $settingsPath).Settings.IgnoreESXiCertificate) { throw 'Missing or non-boolean ESXi settings must preserve certificate verification.' }
    }

    # Execute the real forwarding branches without launching GUI or contacting infrastructure.
    foreach ($entry in @(
        @{ Path = 'Start-PatchingGuestOps.ps1'; Condition = '$IgnoreESXiCertificate'; Table = 'orchestratorParams' },
        @{ Path = 'Start-PatchingGuestOpsGui.ps1'; Condition = '$settingsToSave.IgnoreESXiCertificate'; Table = 'launcherParams' }
    )) {
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $entry.Path), [ref]$tokens, [ref]$parseErrors)
        $branch = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -eq $entry.Condition }, $true))
        if ($branch.Count -ne 1) { throw ('Missing ESXi option forwarding in ' + $entry.Path) }
        foreach ($ignore in @($false, $true)) {
            $IgnoreESXiCertificate = $ignore
            $settingsToSave = [pscustomobject]@{ IgnoreESXiCertificate = $ignore }
            $orchestratorParams = @{}; $launcherParams = @{}
            . ([scriptblock]::Create($branch[0].Extent.Text))
            $forwarded = Get-Variable -Name $entry.Table -ValueOnly
            if ($forwarded.ContainsKey('IgnoreESXiCertificate') -ne $ignore) { throw ('Incorrect ESXi option forwarding in ' + $entry.Path) }
        }
    }
}
finally {
    $script:GuestTransferIgnoreCertificate = $false
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
Write-Host 'Certificate checks passed.'

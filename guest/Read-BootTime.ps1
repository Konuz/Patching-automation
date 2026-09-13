[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\ProgramData\PatchingGuestOps\boot-time.json',
    # The directory this helper was uploaded into, and the seal the workspace bootstrap wrote
    # there. Checked before anything is written: the directory being safe when the bootstrap ran
    # is not the same fact as it still being the directory that was secured.
    [string]$WorkspacePath = '',
    [string]$WorkspaceSealToken = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$payload = [ordered]@{
    bootTimeUtc = $null
    uptimeSeconds = $null
    workspaceSealVerified = $null
    error = $null
}

if (-not [string]::IsNullOrWhiteSpace($WorkspaceSealToken)) {
    try {
        . (Join-Path $PSScriptRoot 'GuestWorkspace.ps1')
        $sealPath = if ([string]::IsNullOrWhiteSpace($WorkspacePath)) { $PSScriptRoot } else { $WorkspacePath }
        $sealVerdict = Assert-GuestWorkspaceSeal -Path $sealPath -Token $WorkspaceSealToken
        $payload.workspaceSealVerified = ($sealVerdict.Status -eq 'Ok')
        if (-not $payload.workspaceSealVerified) {
            # Exit non-zero as well: the caller checks the exit code, because the output path is
            # reused and a stale file from the previous attempt must never read as a fresh result.
            $payload.error = ('The workspace seal was refused: {0}' -f [string]$sealVerdict.Reason)
            $payload | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
            exit 3
        }
    }
    catch {
        $payload.workspaceSealVerified = $false
        $payload.error = ('The workspace seal could not be checked: {0}' -f $_.Exception.Message)
        $payload | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
        exit 3
    }
}

try {
    $operatingSystem = Get-CimInstance Win32_OperatingSystem
    $bootTime = $operatingSystem.LastBootUpTime
    if ($null -ne $bootTime) {
        $payload.bootTimeUtc = ([datetime]$bootTime).ToUniversalTime().ToString('o')

        # Uptime is derived from the same CIM snapshot as the boot time, so the pair stays
        # consistent even if the guest clock is stepped. It is recorded for diagnostics only -
        # the reboot gate still decides on bootTimeUtc alone - but a boot time that moved
        # backwards over a restart (NTP correcting a fast clock) is only explainable with it.
        $localTime = $operatingSystem.LocalDateTime
        if ($null -ne $localTime) {
            $payload.uptimeSeconds = [int][math]::Max(0, ([datetime]$localTime - [datetime]$bootTime).TotalSeconds)
        }
    }
}
catch {
    $payload.error = $_.Exception.Message
}

$payload | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

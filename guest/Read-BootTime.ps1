[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\ProgramData\PatchingGuestOps\boot-time.json'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$payload = [ordered]@{
    bootTimeUtc = $null
    uptimeSeconds = $null
    error = $null
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

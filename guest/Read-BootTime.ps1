[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\ProgramData\PatchingGuestOps\boot-time.json'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$payload = [ordered]@{
    bootTimeUtc = $null
    error = $null
}

try {
    $bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    if ($null -ne $bootTime) {
        $payload.bootTimeUtc = ([datetime]$bootTime).ToUniversalTime().ToString('o')
    }
}
catch {
    $payload.error = $_.Exception.Message
}

$payload | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

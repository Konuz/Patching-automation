Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-CanonicalUpdateIdentityKey {
    param(
        [string]$UpdateId,
        $RevisionNumber,
        [switch]$AllowMissing
    )

    $revisionText = [string]$RevisionNumber
    $updateIdMissing = [string]::IsNullOrWhiteSpace($UpdateId)
    $revisionMissing = [string]::IsNullOrWhiteSpace($revisionText)

    if ($AllowMissing -and $updateIdMissing -and $revisionMissing) {
        return $null
    }

    if ($updateIdMissing) {
        throw 'UpdateId is required to build an update identity key.'
    }

    if ($revisionMissing) {
        throw 'RevisionNumber is required to build an update identity key.'
    }

    $revisionValue = [int]$RevisionNumber
    if ($revisionValue -lt 0) {
        throw 'RevisionNumber must be greater than or equal to 0.'
    }

    return ('{0}|{1}' -f $UpdateId, $revisionValue)
}

function New-GuestCredentialContext {
    [CmdletBinding()]
    param(
        [string[]]$TargetNames,
        [hashtable]$CredentialMap,

        # VMs the operator refused before the run started. Recorded as a skip rather than left
        # as a missing credential, because the two are different facts: "no credential is
        # available" is a gap somebody still has to fill, a skip is an answer. The resolver
        # reads it before it looks for a credential, so those VMs cost no vCenter call.
        [string[]]$SkippedTargetNames
    )

    if ($null -eq $CredentialMap) {
        $CredentialMap = @{}
    }

    # Kept per VM, NOT per account, which is where the two kinds of skip differ. SkipAccount
    # during recovery means the credential itself is refused, so it takes the whole account
    # with it. This one only means "nobody supplied one for these machines", and the prompt
    # that produced it covers exactly the members no stored entry already covers - so skipping
    # it must not take a peer whose own credential is sitting in the store.
    $skippedTargets = @{}
    foreach ($skippedName in @($SkippedTargetNames)) {
        $trimmedName = ([string]$skippedName).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedName)) {
            continue
        }

        $skippedTargets[$trimmedName] = $true
    }

    return @{
        Groups = @(Get-GuestCredentialGroups -TargetNames $TargetNames)
        CredentialMap = $CredentialMap
        SkippedAccountKeys = @{}
        SkippedTargetNames = $skippedTargets
        ValidatedTargets = @{}
        Aborted = $false
    }
}

function Get-GuestCredentialGroupForTarget {
    param(
        [hashtable]$Context,
        [string]$VMName
    )

    foreach ($group in @($Context.Groups)) {
        foreach ($member in @($group.Members)) {
            if ([string]::Equals([string]$member, $VMName, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $group
            }
        }
    }

    return $null
}

function Get-GuestCredentialAccountKey {
    param($Group)

    return ('{0}:{1}' -f ([string]$Group.Kind).ToLowerInvariant(), [string]$Group.Key)
}

function Get-GuestCredentialForGroup {
    param(
        [hashtable]$Context,
        $Group
    )

    foreach ($member in @($Group.Members)) {
        $memberName = [string]$member
        if ($Context.CredentialMap.ContainsKey($memberName)) {
            return $Context.CredentialMap[$memberName]
        }
    }

    return $null
}

function New-GuestCredentialResolution {
    param(
        [ValidateSet('Ready', 'Skipped', 'Failed', 'Aborted')]
        [string]$Status,
        [pscredential]$Credential,
        [string]$AccountKey,
        [string]$Reason
    )

    return [pscustomobject]@{
        Status = $Status
        Credential = if ($Status -eq 'Ready') { $Credential } else { $null }
        AccountKey = $AccountKey
        Reason = $Reason
    }
}

function Get-GuestCredentialValidationReason {
    param(
        $Validation,
        [string]$DefaultReason
    )

    $errorProperty = $Validation.PSObject.Properties['Error']
    if ($null -ne $errorProperty -and $null -ne $errorProperty.Value) {
        $reason = ([string]$errorProperty.Value).Trim()
        if (-not [string]::IsNullOrWhiteSpace($reason)) {
            return $reason
        }
    }

    return $DefaultReason
}

function Test-GuestCredentialEquivalent {
    param(
        [pscredential]$Left,
        [pscredential]$Right
    )

    if ($null -eq $Left -or $null -eq $Right) {
        return $false
    }

    try {
        if (-not [string]::Equals($Left.UserName, $Right.UserName, [System.StringComparison]::Ordinal)) {
            return $false
        }

        $leftPassword = $Left.GetNetworkCredential().Password
        $rightPassword = $Right.GetNetworkCredential().Password
        return [string]::Equals($leftPassword, $rightPassword, [System.StringComparison]::Ordinal)
    }
    catch {
        return $false
    }
}

function Clear-GuestCredentialGroupValidation {
    param(
        [hashtable]$Context,
        $Group
    )

    foreach ($member in @($Group.Members)) {
        $Context.ValidatedTargets.Remove([string]$member) | Out-Null
    }
}

function Set-GuestCredentialForGroup {
    param(
        [hashtable]$Context,
        $Group,
        [pscredential]$Credential
    )

    foreach ($member in @($Group.Members)) {
        $null = $Context.CredentialMap[[string]$member] = $Credential
    }
}

function Test-GuestCredentialInvalidLoginKind {
    param([string]$ErrorKind)

    return $ErrorKind -eq 'InvalidGuestLogin' -or $ErrorKind -eq 'InvalidCredentials'
}

function Resolve-GuestCredentialForTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ValidateScript,

        [scriptblock]$DecisionScript,

        [scriptblock]$OnValidatedScript,

        [switch]$ForcePrompt,

        [switch]$Interactive
    )

    $group = Get-GuestCredentialGroupForTarget -Context $Context -VMName $VMName
    if ($null -eq $group) {
        return New-GuestCredentialResolution -Status Failed -AccountKey $null -Reason ('Target {0} is not in the credential context.' -f $VMName)
    }

    $accountKey = Get-GuestCredentialAccountKey -Group $group
    if ([bool]$Context.Aborted) {
        return New-GuestCredentialResolution -Status Aborted -AccountKey $accountKey -Reason 'Credential recovery was aborted.'
    }

    if ($Context.SkippedAccountKeys.ContainsKey($accountKey)) {
        return New-GuestCredentialResolution -Status Skipped -AccountKey $accountKey -Reason ('Account {0} is skipped for this run.' -f $accountKey)
    }

    # Before the credential lookup, so a VM the operator skipped at the startup prompt never
    # reaches vCenter and is never reported as a gap somebody forgot to fill. ContainsKey
    # rather than a property read: a context built before this field existed is still a valid
    # context, and under StrictMode reaching for a key it does not carry is a terminating error.
    if ($Context.ContainsKey('SkippedTargetNames') -and $Context.SkippedTargetNames.ContainsKey($VMName)) {
        return New-GuestCredentialResolution -Status Skipped -AccountKey $accountKey -Reason ('{0} was skipped at the credential prompt for this run.' -f $VMName)
    }

    $credential = Get-GuestCredentialForGroup -Context $Context -Group $group
    if ($null -eq $credential) {
        return New-GuestCredentialResolution -Status Failed -AccountKey $accountKey -Reason ('No credential is available for account {0}.' -f $accountKey)
    }

    if (-not $ForcePrompt -and $Context.ValidatedTargets.ContainsKey($VMName)) {
        return New-GuestCredentialResolution -Status Ready -Credential $credential -AccountKey $accountKey -Reason 'Credential was already validated for this target in this run.'
    }

    $candidateCredential = $credential
    $isReplacement = $false
    $mustDecide = [bool]$ForcePrompt
    $rejectedCredential = $null

    while ($true) {
        if ($mustDecide) {
            if (-not $Interactive -or $null -eq $DecisionScript) {
                return New-GuestCredentialResolution -Status Failed -AccountKey $accountKey -Reason 'Credential recovery requires an interactive decision.'
            }

            try {
                if ($isReplacement) {
                    $decisionReason = 'The replacement credential was rejected.'
                }
                else {
                    $decisionReason = 'The guest rejected the supplied credential.'
                }
                $decision = & $DecisionScript $VMName $accountKey @($group.Members) $decisionReason
            }
            catch {
                $Context.Aborted = $true
                return New-GuestCredentialResolution -Status Aborted -AccountKey $accountKey -Reason 'Credential recovery could not obtain an operator decision.'
            }

            if ($null -eq $decision) {
                $Context.Aborted = $true
                return New-GuestCredentialResolution -Status Aborted -AccountKey $accountKey -Reason 'Credential recovery was cancelled.'
            }

            $actionProperty = $decision.PSObject.Properties['Action']
            $action = if ($null -eq $actionProperty -or $null -eq $actionProperty.Value) { '' } else { ([string]$actionProperty.Value).Trim() }
            switch -Regex ($action) {
                '^Retry$' {
                    $credentialProperty = $decision.PSObject.Properties['Credential']
                    $nextCredential = if ($null -eq $credentialProperty) { $null } else { $credentialProperty.Value }
                    if ($null -eq $nextCredential -or $nextCredential -isnot [pscredential]) {
                        $Context.Aborted = $true
                        return New-GuestCredentialResolution -Status Aborted -AccountKey $accountKey -Reason 'Credential recovery was cancelled.'
                    }

                    if ($null -ne $rejectedCredential -and (Test-GuestCredentialEquivalent -Left $nextCredential -Right $rejectedCredential)) {
                        return New-GuestCredentialResolution -Status Failed -AccountKey $accountKey -Reason 'The previously rejected credential was not retried.'
                    }

                    $rememberProperty = $decision.PSObject.Properties['Remember']
                    $remember = if ($null -ne $rememberProperty) { [bool]$rememberProperty.Value } else { $false }
                    $candidateCredential = $nextCredential
                    $isReplacement = $true
                    $mustDecide = $false
                    continue
                }
                '^SkipAccount$' {
                    $null = $Context.SkippedAccountKeys[$accountKey] = $true
                    Clear-GuestCredentialGroupValidation -Context $Context -Group $group
                    return New-GuestCredentialResolution -Status Skipped -AccountKey $accountKey -Reason ('Account {0} was skipped for this run.' -f $accountKey)
                }
                '^Abort$' {
                    $Context.Aborted = $true
                    return New-GuestCredentialResolution -Status Aborted -AccountKey $accountKey -Reason 'Credential recovery was aborted by the operator.'
                }
                default {
                    $Context.Aborted = $true
                    return New-GuestCredentialResolution -Status Aborted -AccountKey $accountKey -Reason 'Credential recovery was cancelled.'
                }
            }
        }

        try {
            $validation = & $ValidateScript $VMName $candidateCredential
        }
        catch {
            # Carry the message. Without it the operator is told that validation failed and
            # nothing whatever about why - and the one failure this actually catches is a fault
            # in the validate script itself, which is exactly the case nobody can guess at.
            return New-GuestCredentialResolution -Status Failed -AccountKey $accountKey -Reason ('Credential validation failed before a result was returned: {0}' -f $_.Exception.Message)
        }

        if ($null -eq $validation) {
            return New-GuestCredentialResolution -Status Failed -AccountKey $accountKey -Reason 'Credential validation returned no result.'
        }

        $statusProperty = $validation.PSObject.Properties['Status']
        $validationStatus = if ($null -eq $statusProperty -or $null -eq $statusProperty.Value) { '' } else { ([string]$statusProperty.Value).Trim() }
        $errorKindProperty = $validation.PSObject.Properties['ErrorKind']
        $errorKind = if ($null -eq $errorKindProperty -or $null -eq $errorKindProperty.Value) { '' } else { ([string]$errorKindProperty.Value).Trim() }

        if ([string]::Equals($validationStatus, 'Valid', [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($candidateCredential -isnot [pscredential]) {
                return New-GuestCredentialResolution -Status Failed -AccountKey $accountKey -Reason 'Credential validation accepted an unusable credential.'
            }

            if ($isReplacement) {
                Clear-GuestCredentialGroupValidation -Context $Context -Group $group
                Set-GuestCredentialForGroup -Context $Context -Group $group -Credential $candidateCredential
            }

            $null = $Context.ValidatedTargets[$VMName] = $true
            if ($isReplacement) {
                if ($null -ne $OnValidatedScript) {
                    try {
                        $null = & $OnValidatedScript $accountKey @($group.Members) $candidateCredential $remember
                    }
                    catch {
                        Write-Warning ('Unable to remember the validated credential for account {0} ({1}); the credential remains available in memory.' -f $accountKey, $_.Exception.Message)
                    }
                }
            }
            elseif ($null -ne $OnValidatedScript) {
                try {
                    $null = & $OnValidatedScript $accountKey @($group.Members) $candidateCredential $null
                }
                catch {
                    Write-Warning ('Unable to remember the validated credential for account {0} ({1}); the credential remains available in memory.' -f $accountKey, $_.Exception.Message)
                }
            }

            return New-GuestCredentialResolution -Status Ready -Credential $candidateCredential -AccountKey $accountKey -Reason 'Credential was validated for this target.'
        }

        $reason = Get-GuestCredentialValidationReason -Validation $validation -DefaultReason 'Credential validation was unsuccessful.'
        if ([string]::Equals($validationStatus, 'Invalid', [System.StringComparison]::OrdinalIgnoreCase) -and (Test-GuestCredentialInvalidLoginKind -ErrorKind $errorKind)) {
            if (-not $Interactive) {
                return New-GuestCredentialResolution -Status Failed -AccountKey $accountKey -Reason $reason
            }

            $rejectedCredential = $candidateCredential
            $mustDecide = $true
            continue
        }

        return New-GuestCredentialResolution -Status Failed -AccountKey $accountKey -Reason $reason
    }
}

function Get-GuestCredentialExceptionKind {
    param($Exception)

    $current = $Exception
    for ($depth = 0; $null -ne $current -and $depth -lt 32; $depth++) {
        $candidates = @($current)
        $faultProperty = $current.PSObject.Properties['Fault']
        if ($null -ne $faultProperty -and $null -ne $faultProperty.Value -and $faultProperty.Value -ne $current) {
            $candidates += $faultProperty.Value
        }

        foreach ($candidate in @($candidates)) {
            if ($null -eq $candidate) {
                continue
            }

            $typeNames = @()
            try {
                $typeNames += [string]$candidate.GetType().Name
                $typeNames += [string]$candidate.GetType().FullName
            }
            catch { }
            $typeNamesProperty = $candidate.PSObject.Properties['PSTypeNames']
            if ($null -ne $typeNamesProperty -and $null -ne $typeNamesProperty.Value) {
                $typeNames += @($typeNamesProperty.Value | ForEach-Object { [string]$_ })
            }

            foreach ($typeName in @($typeNames)) {
                $shortName = ([string]$typeName -split '\.')[-1]
                if ($shortName -eq 'InvalidGuestLogin' -or $shortName -eq 'InvalidGuestLoginFault') {
                    return 'InvalidGuestLogin'
                }
                if ($shortName -eq 'GuestPermissionDenied' -or $shortName -eq 'GuestPermissionDeniedFault') {
                    return 'GuestPermissionDenied'
                }
            }
        }

        $innerProperty = $current.PSObject.Properties['InnerException']
        if ($null -eq $innerProperty -or $null -eq $innerProperty.Value -or $innerProperty.Value -eq $current) {
            break
        }
        $current = $innerProperty.Value
    }

    try {
        return [string]$Exception.GetType().Name
    }
    catch {
        return 'Error'
    }
}

function Test-GuestCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$VMView,

        [Parameter(Mandatory = $true)]
        [object]$Managers,

        [Parameter(Mandatory = $true)]
        [pscredential]$Credential
    )

    try {
        if ($null -eq $VMView -or $null -eq $Managers -or $null -eq $Managers.AuthManager -or $null -eq $Credential) {
            throw 'Guest credential validation requires a VM view, AuthManager, and credential.'
        }

        $auth = New-GuestAuthentication -Credential $Credential
        $null = $Managers.AuthManager.ValidateCredentialsInGuest($VMView.MoRef, $auth)
        return [pscustomobject]@{
            Status = 'Valid'
            ErrorKind = $null
            Error = $null
        }
    }
    catch {
        $exception = $_.Exception
        $errorKind = Get-GuestCredentialExceptionKind -Exception $exception
        $errorText = [string]$exception.Message
        if ([string]::Equals($errorKind, 'InvalidGuestLogin', [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                Status = 'Invalid'
                ErrorKind = 'InvalidGuestLogin'
                Error = $errorText
            }
        }

        return [pscustomobject]@{
            Status = 'Error'
            ErrorKind = $errorKind
            Error = $errorText
        }
    }
}

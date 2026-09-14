$script:SuppressStepMessages = $false
$script:GuestTransferIgnoreCertificate = $false

function Write-Step {
    param([string]$Message)
    if ($script:SuppressStepMessages) { return }
    Write-Host ('[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Message)
}

function New-GuestAuthentication {
    param([pscredential]$Credential)

    $auth = New-Object VMware.Vim.NamePasswordAuthentication
    $auth.Username = $Credential.UserName
    $auth.Password = $Credential.GetNetworkCredential().Password
    $auth.InteractiveSession = $false
    return $auth
}

function Get-VMLookupCandidates {
    param([string]$Name)

    $shortName = ($Name -split '\.', 2)[0]
    if ($Name -eq $shortName) {
        return @($Name)
    }

    return @($Name, $shortName)
}

function Get-ExactVM {
    param(
        [string]$Name,
        # The connection scope of this run. Without it Get-VM falls back to PowerCLI's global
        # default sessions, so a VM present in a vCenter the operator never named could be
        # patched or rebooted. An empty scope is a programming error, not "search everything".
        [object[]]$Servers
    )

    $scopedServers = @(@($Servers) | Where-Object { $null -ne $_ -and -not ([string]::IsNullOrWhiteSpace([string]$_)) })
    if ($scopedServers.Count -eq 0) {
        throw ('A vCenter connection scope is required to resolve VM {0}.' -f $Name)
    }

    foreach ($candidate in @(Get-VMLookupCandidates -Name $Name)) {
        # PowerCLI reads -Name as a wildcard pattern, so a VM literally named "server[1]" would
        # never match itself and "server*" would match unrelated guests. Escaping keeps the
        # exact comparison below - not the pattern - as the thing that decides.
        $pattern = [System.Management.Automation.WildcardPattern]::Escape($candidate)
        $exactMatches = @()
        try {
            $exactMatches = @(Get-VM -Name $pattern -Server $scopedServers -ErrorAction Stop | Where-Object { $_.Name -eq $candidate })
        }
        catch {
            # "No such VM here" is the one error that may be read as an empty inventory, and
            # only for this candidate. Anything else - a dropped session, a timeout, a refused
            # login - must not become an empty result that lets a different VM be chosen.
            if ([string](Get-ObjectPropertyValue -InputObject $_ -Path @('CategoryInfo', 'Category')) -ne 'ObjectNotFound') {
                throw
            }
        }

        if ($exactMatches.Count -gt 1) {
            throw ('More than one VM matched exact name: {0}' -f $candidate)
        }

        if ($exactMatches.Count -eq 1) {
            # Inventory short names do not identify a domain. Only use that fallback
            # when VMware Tools confirms the FQDN requested by the operator.
            if ($candidate -ne $Name) {
                $guestHostName = [string](Get-ObjectPropertyValue -InputObject $exactMatches[0] -Path @('ExtensionData', 'Guest', 'HostName'))
                if ([string]::IsNullOrWhiteSpace($guestHostName) -or $guestHostName.Trim().TrimEnd('.') -ine $Name.Trim().TrimEnd('.')) {
                    throw ('VM {0} does not have a confirmed guest FQDN matching {1}. VMware Tools reported: {2}' -f $candidate, $Name, $guestHostName)
                }
            }
            return $exactMatches[0]
        }
    }

    throw ('VM not found: {0}' -f $Name)
}

function Get-VMOwningServerName {
    param(
        $VM,
        [object[]]$Servers
    )

    $scopedServers = @(@($Servers) | Where-Object { $null -ne $_ -and -not ([string]::IsNullOrWhiteSpace([string]$_)) })

    # Two independent readings of "which vCenter is this object from", because either can be
    # absent depending on how the VM object was produced. The service URL is the authoritative
    # one; the Uid is what PowerCLI stamps on every object it returns.
    $candidateHosts = @()
    $serviceUrl = [string](Get-ObjectPropertyValue -InputObject $VM -Path @('ExtensionData', 'Client', 'ServiceUrl'))
    if (-not [string]::IsNullOrWhiteSpace($serviceUrl)) {
        try { $candidateHosts += [string]([uri]$serviceUrl).Host } catch { }
    }
    # Regex.Match rather than -match: the static gate forbids even reading $matches, because
    # the automatic variable is too easy to shadow by accident elsewhere.
    $uid = [string](Get-ObjectPropertyValue -InputObject $VM -Path @('Uid'))
    $uidMatch = [System.Text.RegularExpressions.Regex]::Match($uid, '@([^:/@]+?)(?::\d+)?/')
    if ($uidMatch.Success) {
        $candidateHosts += [string]$uidMatch.Groups[1].Value
    }

    foreach ($candidateHost in $candidateHosts) {
        foreach ($serverName in $scopedServers) {
            $scopedName = ([string]$serverName).Trim()
            if ([string]::Equals($scopedName, $candidateHost, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $scopedName
            }
        }
    }

    # A single-vCenter scope leaves nothing to be ambiguous about: the lookup could not have
    # reached anywhere else. With several in scope, refusing to guess is the safe answer - the
    # caller turns it into a per-VM failure rather than widening the scope back out.
    if ($scopedServers.Count -eq 1) {
        return ([string]$scopedServers[0]).Trim()
    }

    return $null
}

function Get-VMMoRefIdentity {
    param($VM)

    $moRef = Get-ObjectPropertyValue -InputObject $VM -Path @('ExtensionData', 'MoRef')
    if ($null -eq $moRef) {
        return $null
    }

    $moRefType = [string](Get-ObjectPropertyValue -InputObject $moRef -Path @('Type'))
    $moRefValue = [string](Get-ObjectPropertyValue -InputObject $moRef -Path @('Value'))
    if ([string]::IsNullOrWhiteSpace($moRefType) -or [string]::IsNullOrWhiteSpace($moRefValue)) {
        return $null
    }

    return ('{0}:{1}' -f $moRefType, $moRefValue)
}

function Assert-VMMatchesExpectedMoRef {
    param(
        $VM,
        [string]$ExpectedMoRefIdentity,
        [string]$VMName
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedMoRefIdentity)) {
        return
    }

    # A child process re-resolves the name against its own session, so this is what keeps it on
    # the object the parent picked instead of a same-named VM somewhere else in that inventory.
    $actual = [string](Get-VMMoRefIdentity -VM $VM)
    if ([string]::IsNullOrWhiteSpace($actual)) {
        throw ('VM {0} could not be confirmed against the expected managed object {1}.' -f $VMName, $ExpectedMoRefIdentity)
    }

    if (-not [string]::Equals($actual, $ExpectedMoRefIdentity, [System.StringComparison]::Ordinal)) {
        throw ('VM {0} resolved to managed object {1}, not the expected {2}.' -f $VMName, $actual, $ExpectedMoRefIdentity)
    }
}

function Assert-VMReadyForGuestOps {
    param($VM)

    if ($VM.PowerState -ne 'PoweredOn') {
        throw ('VM {0} is not powered on. Current state: {1}' -f $VM.Name, $VM.PowerState)
    }

    $toolsRunningStatus = [string]$VM.ExtensionData.Guest.ToolsRunningStatus
    if ($toolsRunningStatus -ne 'guestToolsRunning') {
        throw ('VMware Tools are not running on {0}. ToolsRunningStatus: {1}' -f $VM.Name, $toolsRunningStatus)
    }
}

function Get-ViewFromVMClient {
    param(
        $VMView,
        $ManagedObjectReference
    )

    $viewClient = Get-ObjectPropertyValue -InputObject $VMView -Path @('Client')
    if ($null -ne $viewClient -and $null -ne $ManagedObjectReference) {
        return $viewClient.GetView($ManagedObjectReference, $null)
    }

    return Get-View $ManagedObjectReference
}

function Get-GuestOpsManagers {
    param($VMView)

    if ($null -eq $VMView) {
        throw 'VMView is required to resolve Guest Operations managers.'
    }

    $viewClient = Get-ObjectPropertyValue -InputObject $VMView -Path @('Client')
    $serviceContent = Get-ObjectPropertyValue -InputObject $viewClient -Path @('ServiceContent')
    $guestOperationsManager = Get-ObjectPropertyValue -InputObject $serviceContent -Path @('GuestOperationsManager')
    if ($null -eq $viewClient -or $null -eq $serviceContent -or $null -eq $guestOperationsManager) {
        throw 'Unable to resolve Guest Operations managers from the VM client.'
    }
    $guestOpsManager = Get-ViewFromVMClient -VMView $VMView -ManagedObjectReference $guestOperationsManager
    $authManagerReference = Get-ObjectPropertyValue -InputObject $guestOpsManager -Path @('AuthManager')
    if ($null -eq $authManagerReference) {
        throw 'Unable to resolve Guest Operations authentication manager from the VM client.'
    }

    return [pscustomobject]@{
        ProcessManager = Get-ViewFromVMClient -VMView $VMView -ManagedObjectReference $guestOpsManager.ProcessManager
        FileManager = Get-ViewFromVMClient -VMView $VMView -ManagedObjectReference $guestOpsManager.FileManager
        AuthManager = Get-ViewFromVMClient -VMView $VMView -ManagedObjectReference $authManagerReference
    }
}

function Connect-VIServersWithCredentialMap {
    param(
        [string[]]$VIServers,
        [hashtable]$CredentialMap,
        [scriptblock]$ConnectScript,
        [scriptblock]$CredentialPromptScript,
        # The recovery variant answers with a decision object rather than a bare credential,
        # so the caller can say "skip" or "abort" instead of being forced to produce one. The
        # old prompt stays exactly as it was and is used whenever no recovery script is given.
        [scriptblock]$CredentialRecoveryScript,
        [scriptblock]$CredentialValidatedScript,
        [scriptblock]$GetExistingConnectionsScript,
        [switch]$RetryOnFailure,
        [switch]$ReuseExisting
    )

    if ($null -eq $CredentialMap) {
        $CredentialMap = @{}
    }

    if ($null -eq $ConnectScript) {
        $ConnectScript = {
            param([string]$Server, [pscredential]$Credential)
            Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
        }
    }

    if ($null -eq $CredentialPromptScript) {
        $CredentialPromptScript = {
            param([string]$Message)
            Get-Credential -Message $Message
        }
    }

    if ($null -eq $GetExistingConnectionsScript) {
        # Go through Get-Variable rather than reading $global:DefaultVIServers directly:
        # under StrictMode reading it before PowerCLI has ever connected is a terminating
        # error, and the offline tests dot-source this file without PowerCLI at all.
        $GetExistingConnectionsScript = {
            return @(Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
        }
    }

    $existingByName = @{}
    if ($ReuseExisting) {
        foreach ($existingConnection in @(& $GetExistingConnectionsScript)) {
            if ($null -eq $existingConnection) {
                continue
            }

            $existingName = ([string](Get-ObjectPropertyValue -InputObject $existingConnection -Path @('Name'))).Trim()
            $isConnected = [bool](Get-ObjectPropertyValue -InputObject $existingConnection -Path @('IsConnected') -DefaultValue $false)
            if ($isConnected -and -not [string]::IsNullOrWhiteSpace($existingName) -and -not $existingByName.ContainsKey($existingName)) {
                $existingByName[$existingName] = $existingConnection
            }
        }
    }

    # Two lists, because they answer different questions: $connections is what this run may
    # use, $openedConnections is what it is allowed to tear down. Disconnecting a session the
    # caller established before invoking us would kill it out from under them.
    $connections = @()
    $openedConnections = @()
    foreach ($server in @($VIServers)) {
        $serverName = ([string]$server).Trim()
        if ([string]::IsNullOrWhiteSpace($serverName)) {
            continue
        }

        $reusedConnection = $null
        foreach ($existingName in @($existingByName.Keys)) {
            if ([string]::Equals($existingName, $serverName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $reusedConnection = $existingByName[$existingName]
                break
            }
        }

        if ($null -ne $reusedConnection) {
            $connections += @($reusedConnection)
            continue
        }

        $rememberPreference = $null
        while ($true) {
            $credential = $null
            if ($CredentialMap.ContainsKey($serverName)) {
                $credential = $CredentialMap[$serverName]
            }

            if ($null -eq $credential) {
                throw ('No vCenter credential is available for {0}.' -f $serverName)
            }

            try {
                $newConnections = @(& $ConnectScript $serverName $credential)
                # Only a login this run performed proves the credential: a reused session was
                # validated by whoever opened it, and reporting it would persist a password
                # this run never tested. $rememberPreference is $null until a recovery dialog
                # states one, which is how the caller knows to fall back to its own preference.
                if ($null -ne $CredentialValidatedScript) {
                    try {
                        $null = & $CredentialValidatedScript $serverName $credential $rememberPreference
                    }
                    catch {
                        Write-Warning ("Unable to remember the validated credential for {0} ({1}); it remains available for this run." -f $serverName, $_.Exception.Message)
                    }
                }
                $connections += $newConnections
                $openedConnections += $newConnections
                break
            }
            catch {
                if (-not $RetryOnFailure) {
                    foreach ($connection in @($openedConnections)) {
                        try {
                            Disconnect-VIServer -Server $connection -Confirm:$false | Out-Null
                        }
                        catch { }
                    }

                    throw
                }

                Write-Warning ('vCenter login failed for {0}: {1}' -f $serverName, $_.Exception.Message)
                $retryMessage = 'Credentials for vCenter {0} (previous login failed)' -f $serverName
                if ($null -eq $CredentialRecoveryScript) {
                    $CredentialMap[$serverName] = & $CredentialPromptScript $retryMessage
                    continue
                }

                $decision = & $CredentialRecoveryScript $serverName $retryMessage
                $decisionAction = [string](Get-ObjectPropertyValue -InputObject $decision -Path @('Action'))
                $decisionCredential = Get-ObjectPropertyValue -InputObject $decision -Path @('Credential')
                if ($decisionAction -ne 'Retry' -or $decisionCredential -isnot [pscredential]) {
                    # Skip and abort both mean "stop": there is no way to run a patch round
                    # against a vCenter nobody can log in to, so this ends like a plain refusal.
                    foreach ($connection in @($openedConnections)) {
                        try {
                            Disconnect-VIServer -Server $connection -Confirm:$false | Out-Null
                        }
                        catch { }
                    }

                    throw ('vCenter credential recovery for {0} did not supply a replacement credential.' -f $serverName)
                }

                $CredentialMap[$serverName] = $decisionCredential
                $rememberPreference = [bool](Get-ObjectPropertyValue -InputObject $decision -Path @('Remember') -DefaultValue $false)
            }
        }
    }

    return [pscustomobject]@{
        Connections = @($connections)
        OpenedConnections = @($openedConnections)
    }
}

function Get-VMHostNameForTransfer {
    param($VMView)

    $hostView = Get-ViewFromVMClient -VMView $VMView -ManagedObjectReference $VMView.Runtime.Host
    if (-not $hostView.Name) {
        throw 'Unable to resolve ESXi host name for guest file transfer URL.'
    }

    return [string]$hostView.Name
}

function Resolve-GuestFileTransferUrl {
    param(
        [string]$Url,
        [string]$HostName
    )

    if ($Url -match '^https://\*/') {
        return ($Url -replace '^https://\*/', ('https://{0}/' -f $HostName))
    }

    return $Url
}

function Invoke-Curl {
    param(
        [string]$CurlPath,
        [string[]]$Arguments,
        [string]$Description
    )

    # --disable first, for every call, so curl ignores %APPDATA%\_curlrc, CURL_HOME/.curlrc
    # and ~/.curlrc. Whoever wrote one of those files could otherwise switch off certificate
    # verification, point this tool at a proxy, or swap the CA store for an ESXi transfer, and
    # the transfer would then either fail verification for no visible reason or succeed without
    # it. Position matters: curl applies the config file before the flags that follow, so a
    # late --disable is too late. This is the only place it is added - an argument list that
    # also carried it would send it twice.
    $effectiveArguments = @('--disable') + @($Arguments)
    if ($script:GuestTransferIgnoreCertificate) {
        $effectiveArguments = @('--disable', '--insecure') + @($Arguments)
    }

    # curl reports failures on stderr; under $ErrorActionPreference='Stop' a native
    # stderr write captured via 2>&1 is promoted to a terminating error before we can
    # inspect $LASTEXITCODE, which would bypass the descriptive throw below. Relax it
    # only around the call and rely on the exit code.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $CurlPath @effectiveArguments 2>&1
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw ("curl.exe failed with exit code {0} during {1}. Output: {2}" -f $exitCode, $Description, (@($output) -join [Environment]::NewLine))
    }
}

function Assert-GuestTransferEndpoint {
    param(
        [string]$HostName,
        [string]$CurlPath
    )

    # Probe the same ESXi name used in wildcard transfer URLs, without allocating a transfer
    # ticket or touching a guest. HTTP 401/403/405 still prove TLS worked, so omit --fail.
    $url = Resolve-GuestFileTransferUrl -Url 'https://*/' -HostName $HostName
    # --disable is added centrally by Invoke-Curl; repeating it here would send it twice.
    $arguments = @('--silent', '--show-error', '--head', '--output', 'NUL', '--max-time', '30', $url)
    try {
        $null = Invoke-Curl -CurlPath $CurlPath -Arguments $arguments -Description ('Checking ESXi HTTPS endpoint {0}' -f $HostName)
    }
    catch {
        throw (New-Object System.InvalidOperationException -ArgumentList ('ESXi transfer preflight failed for {0}. Check certificate trust and the ESXi host name on the stepping stone, DNS and TCP 443 connectivity. IgnoreVCenterCertificate does not apply to file transfers. {1}' -f $HostName, $_.Exception.Message), $_.Exception)
    }
}

# The guest-side statuses, mapped back from the only thing GuestOps returns: an exit code.
# Kept next to the guest file's own table on purpose - if the two ever drift, an unknown code
# lands on the catch-all below and fails the VM rather than being read as success.
$script:GuestWorkspaceExitCodeReasons = @{
    0  = $null
    10 = 'the path is not an acceptable guest directory'
    11 = 'the directory is owned by an account that is neither SYSTEM nor the local Administrators'
    12 = 'an access rule lets an untrusted account modify the directory or its contents'
    13 = 'a reparse point redirects the directory or one of its parents'
    14 = 'the parent directory lets an untrusted account replace it'
    15 = 'its security descriptor could not be read'
    16 = 'it could not be created'
    17 = 'the guest reported an unexpected error'
    18 = 'the workspace seal is missing or does not match this run, so the directory is not the one that was secured'
}

function New-GuestWorkspaceSealToken {
    # Identity, not a secret: it says "this is the directory the bootstrap created". Forging it in
    # a directory that also passes the owner and access-rule checks needs administrator rights,
    # which is the authority half of the same question.
    return [guid]::NewGuid().ToString('N')
}

function Get-GuestWorkspaceFailureReason {
    param($ExitCode)

    if ($null -eq $ExitCode) {
        # vSphere forgets an exit code shortly after the process ends, and the bootstrap is the
        # one thing whose success may never be assumed: no answer is a failure.
        return 'the guest never reported an exit code for the workspace check'
    }

    $code = [int]$ExitCode
    if ($script:GuestWorkspaceExitCodeReasons.ContainsKey($code)) {
        $reason = $script:GuestWorkspaceExitCodeReasons[$code]
        if ($null -eq $reason) {
            return $null
        }
        return $reason
    }

    return ('the guest reported an unrecognised workspace exit code {0}' -f $code)
}

function New-CompressedGuestScript {
    param([string]$ScriptText)

    $stream = New-Object System.IO.MemoryStream
    try {
        $gzip = New-Object System.IO.Compression.GZipStream($stream, [System.IO.Compression.CompressionMode]::Compress, $true)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($ScriptText)
            $gzip.Write($bytes, 0, $bytes.Length)
        }
        finally { $gzip.Dispose() }
        $payload = [System.Convert]::ToBase64String($stream.ToArray())
    }
    finally { $stream.Dispose() }

    # Only base64 data is substituted. The trusted helper is reconstructed in memory,
    # before there is any safe guest directory into which a helper could be uploaded.
    $loader = @'
$ErrorActionPreference = 'Stop'
$guestBootstrapStream = New-Object System.IO.MemoryStream(,[System.Convert]::FromBase64String('__PAYLOAD__'))
$guestBootstrapGzip = New-Object System.IO.Compression.GZipStream($guestBootstrapStream, [System.IO.Compression.CompressionMode]::Decompress)
$guestBootstrapReader = New-Object System.IO.StreamReader($guestBootstrapGzip, [System.Text.Encoding]::UTF8)
try { $guestBootstrapSource = $guestBootstrapReader.ReadToEnd() }
finally { $guestBootstrapReader.Dispose() }
. ([scriptblock]::Create($guestBootstrapSource))
'@
    return $loader.Replace('__PAYLOAD__', $payload)
}

function New-GuestBootstrapArguments {
    param([string]$EncodedCommand)

    # Builders retain their encoded return contract. Do not send that UTF-16/base64
    # expansion to Windows: the compressed loader is already safe command text.
    $command = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($EncodedCommand))
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "{0}"' -f $command.Replace('"', '\"')
    # Reserve room for the executable name and terminating null below Windows' 32767 limit.
    if ($arguments.Length -gt 32000) {
        throw ('Guest bootstrap arguments are too long ({0} characters; maximum 32000). No guest process was started.' -f $arguments.Length)
    }
    return $arguments
}

function New-GuestWorkspaceBootstrapCommand {
    param(
        [string]$WorkspaceScriptText,
        [string]$Path,
        [ValidateSet('Initialize', 'Assert')][string]$Mode = 'Initialize',
        # Optional: one file inside that directory whose owner and rules must also hold. A safe
        # root does not vouch for a file that was already sitting in it.
        [string]$FilePath,
        # Seals the directory on Initialize, and requires that exact seal on Assert.
        [string]$SealToken
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceScriptText)) {
        throw 'The guest workspace helper source is empty.'
    }

    # The path travels as base64 DATA, decoded inside the guest. Interpolating it into the
    # command text would make a directory name - which an operator supplies - a place where
    # PowerShell syntax can be written.
    $pathBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$Path))
    $fileBase64 = ''
    if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
        $fileBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$FilePath))
    }
    $sealBase64 = ''
    if (-not [string]::IsNullOrWhiteSpace($SealToken)) {
        $sealBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$SealToken))
    }
    $preamble = @(
        "`$GuestWorkspaceRequest = [pscustomobject]@{ Mode = '$Mode'; PathBase64 = '$pathBase64'; FileBase64 = '$fileBase64'; SealTokenBase64 = '$sealBase64' }"
    ) -join [Environment]::NewLine

    $commandText = $preamble + [Environment]::NewLine + (New-CompressedGuestScript -ScriptText $WorkspaceScriptText)
    return [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($commandText))
}

function Get-GuestWorkspaceScriptText {
    param([string]$WorkspaceScriptPath)

    if ([string]::IsNullOrWhiteSpace($WorkspaceScriptPath) -or -not (Test-Path -LiteralPath $WorkspaceScriptPath -PathType Leaf)) {
        throw ('The guest workspace helper was not found: {0}' -f $WorkspaceScriptPath)
    }

    return [string](Get-Content -LiteralPath $WorkspaceScriptPath -Raw)
}

function Start-GuestWorkspaceBootstrap {
    param(
        $ProcessManager,
        $VMView,
        $GuestAuth,
        [string]$EncodedCommand
    )

    $programSpec = New-Object VMware.Vim.GuestProgramSpec
    $programSpec.ProgramPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $programSpec.Arguments = New-GuestBootstrapArguments -EncodedCommand $EncodedCommand
    $programSpec.WorkingDirectory = 'C:\Windows\System32'

    return $ProcessManager.StartProgramInGuest($VMView.MoRef, $GuestAuth, $programSpec)
}

function Assert-GuestWorkspaceReady {
    param(
        $ProcessManager,
        $VMView,
        $GuestAuth,
        [string]$VMName,
        [string]$Path,
        [string]$WorkspaceScriptPath,
        [ValidateSet('Initialize', 'Assert')][string]$Mode = 'Initialize',
        [string]$FilePath,
        [string]$SealToken,
        [int]$TimeoutSeconds = 120,
        [int]$PollSeconds = 5
    )

    # Executed straight from the trusted local copy through an in-memory compressed command. Uploading the
    # guard into the directory it is supposed to be guarding would mean writing a file into an
    # unverified location and then trusting what came back from it.
    $encodedCommand = New-GuestWorkspaceBootstrapCommand -WorkspaceScriptText (Get-GuestWorkspaceScriptText -WorkspaceScriptPath $WorkspaceScriptPath) -Path $Path -Mode $Mode -FilePath $FilePath -SealToken $SealToken
    $processId = Start-GuestWorkspaceBootstrap -ProcessManager $ProcessManager -VMView $VMView -GuestAuth $GuestAuth -EncodedCommand $encodedCommand
    $result = Wait-GuestProcess -ProcessManager $ProcessManager -VMView $VMView -GuestAuth $GuestAuth -ProcessId $processId -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds

    if (-not $result.Completed) {
        throw ('Guest directory "{0}" on {1} could not be secured: the workspace check did not finish within {2} seconds.' -f $Path, $VMName, $TimeoutSeconds)
    }

    $reason = Get-GuestWorkspaceFailureReason -ExitCode $result.ExitCode
    if ($null -ne $reason) {
        throw ('Guest directory "{0}" on {1} cannot be used: {2}. Nothing was uploaded to it.' -f $Path, $VMName, $reason)
    }
}

function Wait-GuestProcess {
    param(
        $ProcessManager,
        $VMView,
        $GuestAuth,
        [long]$ProcessId,
        [int]$TimeoutSeconds,
        [int]$PollSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $processes = @($ProcessManager.ListProcessesInGuest($VMView.MoRef, $GuestAuth, @($ProcessId)))
        if ($processes.Count -gt 0) {
            $process = $processes[0]
            if ($null -ne $process.EndTime -or $null -ne $process.ExitCode) {
                return [pscustomobject]@{
                    Completed = $true
                    ExitCode = $process.ExitCode
                    EndTime = $process.EndTime
                }
            }
        }

        $remainingSeconds = ($deadline - (Get-Date)).TotalSeconds
        # Ceiling, not Floor: a sub-second remainder would floor to 0 and spin the loop against
        # ListProcessesInGuest without sleeping. The -gt 0 guard below still handles a past deadline.
        $sleepSeconds = [int][math]::Ceiling([math]::Min($PollSeconds, $remainingSeconds))
        if ($sleepSeconds -gt 0) {
            Start-Sleep -Seconds $sleepSeconds
        }
    }

    return [pscustomobject]@{
        Completed = $false
        ExitCode = $null
        EndTime = $null
    }
}

function Send-GuestFile {
    param(
        $FileManager,
        $VMView,
        $GuestAuth,
        [string]$HostName,
        [string]$CurlPath,
        [string]$LocalPath,
        [string]$GuestPath,
        [ValidateRange(1,2147483647)][int]$TimeoutSeconds = 300
    )

    $file = Get-Item -LiteralPath $LocalPath
    $attributes = New-Object VMware.Vim.GuestFileAttributes
    $url = $FileManager.InitiateFileTransferToGuest($VMView.MoRef, $GuestAuth, $GuestPath, $attributes, [int64]$file.Length, $true)
    $resolvedUrl = Resolve-GuestFileTransferUrl -Url $url -HostName $HostName

    $curlArguments = @(
        '--silent',
        '--show-error',
        '--fail',
        '--max-time',
        [string]$TimeoutSeconds,
        '--request',
        'PUT',
        '--upload-file',
        $LocalPath,
        $resolvedUrl
    )
    Invoke-Curl -CurlPath $CurlPath -Description ('Uploading {0} to guest path {1}' -f $LocalPath, $GuestPath) -Arguments $curlArguments
}

function Receive-GuestFile {
    param(
        $FileManager,
        $VMView,
        $GuestAuth,
        [string]$HostName,
        [string]$CurlPath,
        [string]$GuestPath,
        [string]$LocalPath,
        [ValidateRange(1,2147483647)][int]$TimeoutSeconds = 300
    )

    $localParent = Split-Path -Parent $LocalPath
    if (-not (Test-Path -LiteralPath $localParent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $localParent | Out-Null
    }

    $transferInfo = $FileManager.InitiateFileTransferFromGuest($VMView.MoRef, $GuestAuth, $GuestPath)
    $resolvedUrl = Resolve-GuestFileTransferUrl -Url $transferInfo.Url -HostName $HostName

    $curlArguments = @(
        '--silent',
        '--show-error',
        '--fail',
        '--max-time',
        [string]$TimeoutSeconds,
        '--output',
        $LocalPath,
        $resolvedUrl
    )
    Invoke-Curl -CurlPath $CurlPath -Description ('Downloading guest path {0} to {1}' -f $GuestPath, $LocalPath) -Arguments $curlArguments
}

function Get-UniqueTrimmedKeys {
    param([string[]]$Keys = @())

    $result = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($rawKey in @($Keys)) {
        $key = ([string]$rawKey).Trim()
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }

        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [void]$result.Add($key)
        }
    }

    return @($result.ToArray())
}

function New-UpdateSelectionDocument {
    param([string[]]$SelectedUpdateKeys = @())

    return [pscustomobject]@{
        schemaVersion = 'selection-v1'
        selectedUpdateKeys = @(Get-UniqueTrimmedKeys -Keys $SelectedUpdateKeys)
    }
}

function New-GuestAgentArguments {
    param(
        [string]$GuestAgentPath,
        [string]$GuestWorkingDirectory,
        [int]$MaxUpdates,
        [string[]]$SelectedUpdateKeys = @(),
        [string]$SelectionPath,
        [string]$RunId,
        [string]$WorkspaceSealToken,
        [switch]$SearchOnly
    )

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        ('"{0}"' -f $GuestAgentPath),
        '-WorkingDirectory',
        ('"{0}"' -f $GuestWorkingDirectory),
        '-MaxUpdates',
        ([string]$MaxUpdates)
    )

    if ($SearchOnly) {
        $arguments += '-SearchOnly'
    }

    if (-not [string]::IsNullOrWhiteSpace($RunId)) {
        $arguments += '-RunId'
        $arguments += ('"{0}"' -f $RunId)
    }

    if (-not [string]::IsNullOrWhiteSpace($SelectionPath)) {
        $arguments += '-SelectionPath'
        $arguments += ('"{0}"' -f $SelectionPath)
    }

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceSealToken)) {
        $arguments += '-WorkspaceSealToken'
        $arguments += ('"{0}"' -f $WorkspaceSealToken)
    }

    if (@($SelectedUpdateKeys).Count -gt 0) {
        $quotedSelectedUpdateKeys = @($SelectedUpdateKeys | ForEach-Object { '"{0}"' -f (([string]$_) -replace '"', '`"') })
        $arguments += '-SelectedUpdateKeys'
        $arguments += ($quotedSelectedUpdateKeys -join ',')
    }

    return ($arguments -join ' ')
}

# The guest-side statuses of the reboot request, mapped from its exit code. Only 'never sent' and
# 'sent' matter to the caller, and getting that wrong in either direction is expensive: treating a
# sent reboot as unsent invites a second restart, treating an unsent one as sent burns a whole
# -RebootTimeoutMinutes waiting for a guest that was never told to restart.
$script:GuestRebootExitCodes = @{
    0  = [pscustomobject]@{ Sent = $true;  Conflict = $false; Reason = $null }
    20 = [pscustomobject]@{ Sent = $false; Conflict = $true;  Reason = 'another PatchingGuestOps run holds this guest, or a previous run left an unreconciled trace on it' }
    21 = [pscustomobject]@{ Sent = $false; Conflict = $false; Reason = 'the guest refused the reboot request before shutdown.exe was invoked' }
    22 = [pscustomobject]@{ Sent = $true;  Conflict = $false; Reason = 'shutdown.exe was invoked but reported a failure; the restart may still be in progress' }
    23 = [pscustomobject]@{ Sent = $false; Conflict = $false; Reason = 'the guest coordination directory could not be secured' }
}

function New-GuestRebootBootstrapCommand {
    param(
        [string]$WorkspaceScriptText,
        [string]$RunGuardScriptText,
        [string]$RebootScriptText,
        [string]$RunId,
        [string]$Comment = 'PatchingGuestOps reboot after updates'
    )

    foreach ($part in @($WorkspaceScriptText, $RunGuardScriptText, $RebootScriptText)) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            throw 'The guest reboot request needs the workspace guard, the run guard and the request script.'
        }
    }

    # Run id and comment travel as base64 DATA. The comment is operator-visible text and the run
    # id is generated, but neither may become a place where PowerShell syntax can be written.
    $runIdBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$RunId))
    $commentBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$Comment))
    $preamble = "`$GuestRebootRequest = [pscustomobject]@{ RunIdBase64 = '$runIdBase64'; CommentBase64 = '$commentBase64' }"

    $scriptText = @($WorkspaceScriptText, $RunGuardScriptText, $RebootScriptText) -join [Environment]::NewLine
    $commandText = $preamble + [Environment]::NewLine + (New-CompressedGuestScript -ScriptText $scriptText)
    return [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($commandText))
}

function Start-GuestReboot {
    param(
        $ProcessManager,
        $VMView,
        $GuestAuth,
        [string]$Comment = 'PatchingGuestOps reboot after updates',
        [string]$RunId,
        [string]$WorkspaceScriptPath,
        [string]$RunGuardScriptPath,
        [string]$RebootScriptPath
    )

    # shutdown.exe is invoked from inside the guest, by a process that holds the guest run guard,
    # so a reboot can never be ordered while an agent on that guest is still installing or while
    # a second run of this tool is working on it. Starting shutdown.exe directly over GuestOps -
    # which is what this replaces - had no way to know either of those things.
    $encodedCommand = New-GuestRebootBootstrapCommand `
        -WorkspaceScriptText (Get-GuestWorkspaceScriptText -WorkspaceScriptPath $WorkspaceScriptPath) `
        -RunGuardScriptText (Get-GuestWorkspaceScriptText -WorkspaceScriptPath $RunGuardScriptPath) `
        -RebootScriptText (Get-GuestWorkspaceScriptText -WorkspaceScriptPath $RebootScriptPath) `
        -RunId $RunId -Comment $Comment

    $programSpec = New-Object VMware.Vim.GuestProgramSpec
    $programSpec.ProgramPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $programSpec.Arguments = New-GuestBootstrapArguments -EncodedCommand $encodedCommand
    $programSpec.WorkingDirectory = 'C:\Windows\System32'

    return $ProcessManager.StartProgramInGuest($VMView.MoRef, $GuestAuth, $programSpec)
}

function Get-GuestRebootSubmissionVerdict {
    param($ProcessResult)

    # A guest that is restarting stops answering, so "no result" is the ordinary success path and
    # has to be read as "sent". Only an exit code this tool understands can say otherwise.
    if ($null -eq $ProcessResult -or -not $ProcessResult.Completed -or $null -eq $ProcessResult.ExitCode) {
        return [pscustomobject]@{ Sent = $true; Conflict = $false; Reason = $null }
    }

    $code = [int]$ProcessResult.ExitCode
    if ($script:GuestRebootExitCodes.ContainsKey($code)) {
        return $script:GuestRebootExitCodes[$code]
    }

    # An unrecognised code is ambiguous, not a rejection: the safe reading is that the guest may
    # already be going down.
    return [pscustomobject]@{ Sent = $true; Conflict = $false; Reason = ('the guest reported an unrecognised reboot exit code {0}' -f $code) }
}

function Start-GuestAgent {
    param(
        $ProcessManager,
        $VMView,
        $GuestAuth,
        [string]$GuestAgentPath,
        [string]$GuestWorkingDirectory,
        [int]$MaxUpdates,
        [string[]]$SelectedUpdateKeys = @(),
        [string]$SelectionPath,
        [string]$RunId,
        [string]$WorkspaceSealToken,
        [switch]$SearchOnly
    )

    $programSpec = New-Object VMware.Vim.GuestProgramSpec
    $programSpec.ProgramPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $programSpec.Arguments = New-GuestAgentArguments -GuestAgentPath $GuestAgentPath -GuestWorkingDirectory $GuestWorkingDirectory -MaxUpdates $MaxUpdates -SelectedUpdateKeys $SelectedUpdateKeys -SelectionPath $SelectionPath -RunId $RunId -WorkspaceSealToken $WorkspaceSealToken -SearchOnly:$SearchOnly
    $programSpec.WorkingDirectory = $GuestWorkingDirectory

    return $ProcessManager.StartProgramInGuest($VMView.MoRef, $GuestAuth, $programSpec)
}

function Get-ObjectPropertyValue {
    param(
        $InputObject,
        [string[]]$Path,
        $DefaultValue = $null
    )

    $current = $InputObject
    foreach ($name in $Path) {
        if ($null -eq $current) {
            return $DefaultValue
        }

        $property = $current.PSObject.Properties[$name]
        if ($null -eq $property) {
            return $DefaultValue
        }

        $current = $property.Value
    }

    return $current
}

function Get-GuestOperationErrorKind {
    param($ErrorRecord)

    $transientWebExceptionStatuses = @(
        'ConnectFailure',
        'ConnectionClosed',
        'KeepAliveFailure',
        'NameResolutionFailure',
        'ProxyNameResolutionFailure',
        'ReceiveFailure',
        'SendFailure',
        'Timeout',
        'RequestCanceled',
        'PipelineFailure'
    )

    $sawInvalidCredentials = $false
    $sawPermissionDenied = $false
    $sawTransient = $false
    $current = $ErrorRecord

    for ($depth = 0; $null -ne $current -and $depth -lt 32; $depth++) {
        $candidateQueue = New-Object System.Collections.Queue
        $candidateQueue.Enqueue($current)

        $exceptionProperty = $current.PSObject.Properties['Exception']
        if ($null -ne $exceptionProperty -and $null -ne $exceptionProperty.Value -and $exceptionProperty.Value -ne $current) {
            $candidateQueue.Enqueue($exceptionProperty.Value)
        }

        $candidateCount = 0
        while ($candidateQueue.Count -gt 0 -and $candidateCount -lt 16) {
            $candidate = $candidateQueue.Dequeue()
            $candidateCount++
            if ($null -eq $candidate) {
                continue
            }

            $typeNames = @()
            try {
                $typeNames += [string]$candidate.GetType().FullName
                $typeNames += [string]$candidate.GetType().Name
            }
            catch { }
            try {
                $typeNames += @($candidate.PSTypeNames | ForEach-Object { [string]$_ })
            }
            catch { }

            foreach ($typeName in @($typeNames)) {
                if ([string]::IsNullOrWhiteSpace($typeName)) {
                    continue
                }

                $shortTypeName = ([string]$typeName -split '\.')[-1]
                switch ($shortTypeName) {
                    'InvalidGuestLogin' { $sawInvalidCredentials = $true }
                    'InvalidGuestLoginFault' { $sawInvalidCredentials = $true }
                    'GuestPermissionDenied' { $sawPermissionDenied = $true }
                    'GuestPermissionDeniedFault' { $sawPermissionDenied = $true }
                    'GuestOperationsUnavailable' { $sawTransient = $true }
                    'GuestOperationsUnavailableFault' { $sawTransient = $true }
                    'TaskInProgress' { $sawTransient = $true }
                    'TaskInProgressFault' { $sawTransient = $true }
                    'TimeoutException' { $sawTransient = $true }
                }

                if ($shortTypeName -eq 'WebException') {
                    $statusProperty = $candidate.PSObject.Properties['Status']
                    if ($null -ne $statusProperty -and $transientWebExceptionStatuses -contains ([string]$statusProperty.Value)) {
                        $sawTransient = $true
                    }
                }
            }

            $faultProperty = $candidate.PSObject.Properties['Fault']
            if ($null -ne $faultProperty -and $null -ne $faultProperty.Value -and $faultProperty.Value -ne $candidate) {
                $candidateQueue.Enqueue($faultProperty.Value)
            }
        }

        $baseException = $current
        if ($null -ne $exceptionProperty -and $null -ne $exceptionProperty.Value) {
            $baseException = $exceptionProperty.Value
        }
        $innerProperty = $baseException.PSObject.Properties['InnerException']
        if ($null -eq $innerProperty -or $null -eq $innerProperty.Value -or $innerProperty.Value -eq $baseException) {
            $current = $null
        }
        else {
            $current = $innerProperty.Value
        }
    }

    if ($sawInvalidCredentials) {
        return 'InvalidCredentials'
    }
    if ($sawPermissionDenied) {
        return 'Permanent'
    }
    if ($sawTransient) {
        return 'Transient'
    }

    return 'Permanent'
}

function Test-AgentCycleCompletion {
    param(
        $Status,
        [string]$RunId,
        [string]$Mode
    )

    $statusRunId = [string](Get-ObjectPropertyValue -InputObject $Status -Path @('runId'))
    if ([string]::IsNullOrWhiteSpace($RunId) -or [string]::IsNullOrWhiteSpace($statusRunId) -or -not [string]::Equals($statusRunId, $RunId, [System.StringComparison]::Ordinal)) {
        return $false
    }

    $finishedAt = [string](Get-ObjectPropertyValue -InputObject $Status -Path @('finishedAt'))
    if ([string]::IsNullOrWhiteSpace($finishedAt)) {
        return $false
    }

    try {
        $null = [datetime]::Parse($finishedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    catch {
        return $false
    }

    $outcome = [string](Get-ObjectPropertyValue -InputObject $Status -Path @('outcome'))
    if ([string]::Equals($Mode, 'Apply', [System.StringComparison]::Ordinal)) {
        return ($outcome -in @('InstallSucceeded', 'InstallSucceededWithErrors', 'InstallFailed', 'DownloadFailed', 'NoSelectedUpdates', 'NoApplicableUpdates', 'Failed'))
    }

    if ([string]::Equals($Mode, 'SearchOnly', [System.StringComparison]::Ordinal)) {
        return ($outcome -in @('SearchOnly', 'NoApplicableUpdates', 'Failed'))
    }

    return $false
}

function New-VMAgentCycleHandle {
    param(
        [string]$VMName,
        [string]$RunId,
        $Managers,
        $VMView,
        $GuestAuth,
        [string]$HostName,
        [string]$CurlPath,
        [long]$ProcessId,
        [string]$GuestStatusPath,
        [string]$GuestLogPath,
        [string]$LocalStatusPath,
        [string]$LocalLogPath,
        # Two directories, not one. Cleanup compares them, so collapsing them - as the cycle
        # start used to, by reassigning its own parameter - leaves nothing to validate against.
        [string]$GuestWorkingDirectory,
        [string]$GuestCycleDirectory,
        [int]$TransferTimeoutSeconds = 300,
        [ValidateSet('SearchOnly', 'Apply', IgnoreCase = $false)]
        [string]$Mode = 'Apply'
    )

    return [pscustomobject]@{
        VMName = $VMName
        RunId = $RunId
        Mode = $Mode
        Managers = $Managers
        VMView = $VMView
        GuestAuth = $GuestAuth
        HostName = $HostName
        CurlPath = $CurlPath
        ProcessId = $ProcessId
        GuestStatusPath = $GuestStatusPath
        GuestLogPath = $GuestLogPath
        LocalStatusPath = $LocalStatusPath
        LocalLogPath = $LocalLogPath
        GuestWorkingDirectory = $GuestWorkingDirectory
        GuestCycleDirectory = $GuestCycleDirectory
        TransferTimeoutSeconds = $TransferTimeoutSeconds
        # Seeded so the property exists before anything reads it: on the fleet timeout path
        # it is read without a poll ever having written it, and StrictMode is unforgiving.
        AgentResult = $null
        Status = $null
    }
}

function Start-VMAgentCycle {
    param(
        [string]$VMName,
        [object[]]$Servers,
        $Managers,
        $GuestAuth,
        [string]$CurlPath,
        [string]$AgentPath,
        [string]$IdentityHelperPath,
        [string]$GuestWorkingDirectory,
        [string]$VMOutputDirectory,
        [int]$MaxUpdates,
        [string[]]$SelectedUpdateKeys = @(),
        [string]$LocalSelectionPath,
        [string]$SelectionPath,
        [switch]$SearchOnly,
        [int]$TransferTimeoutSeconds = 300,
        # Read from the trusted local copy and executed in the guest through an in-memory compressed command.
        # Defaulted here rather than at the call sites so every caller gets the guard.
        [string]$WorkspaceScriptPath = (Join-Path $PSScriptRoot '..\guest\GuestWorkspace.ps1'),
        # Uploaded beside the agent, which dot-sources both: the workspace primitives and the
        # one-run-per-guest lock. Safe to upload, because the directory was verified first.
        [string]$RunGuardScriptPath = (Join-Path $PSScriptRoot '..\guest\GuestRunGuard.ps1')
    )

    # An empty value means "not supplied", not "no script". A parameter default only applies when
    # the caller OMITS the parameter, and the fleet forwards these whether or not it was given
    # them - so an omitted path arrived here as an empty string, overrode the default above, and
    # left the workspace bootstrap with nothing to run. Every VM then failed to start with no
    # payload, naming a parameter nobody passed rather than anything the guest did.
    # Resolved here because this file is dot-sourced normally, so $PSScriptRoot is real; the
    # orchestrator's copy of the fleet is built from its AST, where it is not.
    if ([string]::IsNullOrWhiteSpace($WorkspaceScriptPath)) {
        $WorkspaceScriptPath = (Join-Path $PSScriptRoot '..\guest\GuestWorkspace.ps1')
    }
    if ([string]::IsNullOrWhiteSpace($RunGuardScriptPath)) {
        $RunGuardScriptPath = (Join-Path $PSScriptRoot '..\guest\GuestRunGuard.ps1')
    }

    $vm = Get-ExactVM -Name $VMName -Servers $Servers
    Assert-VMReadyForGuestOps -VM $vm

    $vmView = $vm.ExtensionData
    if ($null -eq $Managers) {
        $Managers = Get-GuestOpsManagers -VMView $vmView
    }
    $hostName = Get-VMHostNameForTransfer -VMView $vmView

    New-Item -ItemType Directory -Force -Path $VMOutputDirectory | Out-Null

    $runId = [guid]::NewGuid().ToString('N')
    # The root is kept as it was given. Overwriting the parameter here left the handle with
    # one path where cleanup needs two, and a recursive delete with nothing to validate against.
    $guestCycleDirectory = Join-Path $GuestWorkingDirectory $runId
    if (-not [string]::IsNullOrWhiteSpace($LocalSelectionPath)) {
        $SelectionPath = Join-Path $guestCycleDirectory 'selection.json'
    }

    $guestAgentPath = Join-Path $guestCycleDirectory 'Run-LocalPatch.ps1'
    $guestStatusPath = Join-Path $guestCycleDirectory 'status.json'
    $guestLogPath = Join-Path $guestCycleDirectory 'agent.log'
    $localStatusPath = Join-Path $VMOutputDirectory 'status.json'
    $localLogPath = Join-Path $VMOutputDirectory 'agent.log'

    # Creates every missing level of the chain with a protected DACL and verifies the result,
    # including a directory that was already there. This replaces the plain mkdir: an ordinary
    # user who can write here could swap Run-LocalPatch.ps1 between the upload and the start and
    # have it run under the patching account. A failure throws before the first transfer.
    # Sealed with a token this cycle generated. Everything that runs in the guest afterwards
    # re-checks the seal, so a directory swapped or re-permissioned between this check and the
    # agent start is caught instead of being trusted on the strength of one check.
    $workspaceSealToken = New-GuestWorkspaceSealToken
    Assert-GuestWorkspaceReady -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -VMName $VMName -Path $guestCycleDirectory -WorkspaceScriptPath $WorkspaceScriptPath -Mode 'Initialize' -SealToken $workspaceSealToken -TimeoutSeconds 120 -PollSeconds 5

    # Every transfer carries a budget. The fleet puts no job wrapper around these calls, so
    # nothing else bounds a curl hanging against an unresponsive ESXi data plane.
    Send-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -LocalPath $AgentPath -GuestPath $guestAgentPath -TimeoutSeconds $TransferTimeoutSeconds

    $guestIdentityHelperPath = Join-Path $guestCycleDirectory 'UpdateIdentity.ps1'
    Send-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -LocalPath $IdentityHelperPath -GuestPath $guestIdentityHelperPath -TimeoutSeconds $TransferTimeoutSeconds

    # The agent dot-sources both of these. They go into the cycle directory, which the workspace
    # check above has already proven only SYSTEM and Administrators can write to.
    Send-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -LocalPath $WorkspaceScriptPath -GuestPath (Join-Path $guestCycleDirectory 'GuestWorkspace.ps1') -TimeoutSeconds $TransferTimeoutSeconds
    Send-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -LocalPath $RunGuardScriptPath -GuestPath (Join-Path $guestCycleDirectory 'GuestRunGuard.ps1') -TimeoutSeconds $TransferTimeoutSeconds

    if (-not [string]::IsNullOrWhiteSpace($LocalSelectionPath) -and -not [string]::IsNullOrWhiteSpace($SelectionPath)) {
        Send-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -LocalPath $LocalSelectionPath -GuestPath $SelectionPath -TimeoutSeconds $TransferTimeoutSeconds
    }

    # The agent re-checks the seal before it creates the WUA session. The uploads above are the
    # gap this closes: three GuestOps calls stand between the bootstrap's check and the first
    # line the agent runs, and the agent refuses to read selection.json or touch WUA in a
    # directory that is no longer the one this cycle secured.
    $agentProcessId = Start-GuestAgent -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -GuestAgentPath $guestAgentPath -GuestWorkingDirectory $guestCycleDirectory -MaxUpdates $MaxUpdates -SelectedUpdateKeys $SelectedUpdateKeys -SelectionPath $SelectionPath -RunId $runId -WorkspaceSealToken $workspaceSealToken -SearchOnly:$SearchOnly

    $mode = if ($SearchOnly) { 'SearchOnly' } else { 'Apply' }
    return New-VMAgentCycleHandle -VMName $VMName -RunId $runId -Mode $mode -Managers $Managers -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -ProcessId $agentProcessId -GuestStatusPath $guestStatusPath -GuestLogPath $guestLogPath -LocalStatusPath $localStatusPath -LocalLogPath $localLogPath -GuestWorkingDirectory $GuestWorkingDirectory -GuestCycleDirectory $guestCycleDirectory -TransferTimeoutSeconds $TransferTimeoutSeconds
}

function Test-GuestOperationFileNotFound {
    param($ErrorRecord)

    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($ErrorRecord)
    $seen = New-Object System.Collections.ArrayList
    $fileNotFoundTypes = @('FileNotFoundException', 'GuestFileNotFound', 'FileNotFound')

    while ($queue.Count -gt 0 -and $seen.Count -lt 128) {
        $candidate = $queue.Dequeue()
        if ($null -eq $candidate) {
            continue
        }

        $alreadySeen = $false
        foreach ($seenCandidate in @($seen)) {
            if ([object]::ReferenceEquals($seenCandidate, $candidate)) {
                $alreadySeen = $true
                break
            }
        }
        if ($alreadySeen) {
            continue
        }
        $null = $seen.Add($candidate)

        $typeNames = @()
        try {
            $typeNames += [string]$candidate.GetType().FullName
            $typeNames += [string]$candidate.GetType().Name
        }
        catch { }
        try {
            $typeNames += @($candidate.PSTypeNames | ForEach-Object { [string]$_ })
        }
        catch { }

        foreach ($typeName in @($typeNames)) {
            if ([string]::IsNullOrWhiteSpace($typeName)) {
                continue
            }
            if ($fileNotFoundTypes -contains (([string]$typeName -split '\.')[-1])) {
                return $true
            }
        }

        foreach ($propertyName in @('Exception', 'InnerException', 'Fault')) {
            $property = $candidate.PSObject.Properties[$propertyName]
            if ($null -ne $property -and $null -ne $property.Value -and -not [object]::ReferenceEquals($property.Value, $candidate)) {
                $queue.Enqueue($property.Value)
            }
        }
    }

    return $false
}

function Read-VMAgentCycleStatus {
    param($Handle)

    try {
        Receive-GuestFile -FileManager $Handle.Managers.FileManager -VMView $Handle.VMView -GuestAuth $Handle.GuestAuth -HostName $Handle.HostName -CurlPath $Handle.CurlPath -GuestPath $Handle.GuestStatusPath -LocalPath $Handle.LocalStatusPath -TimeoutSeconds $Handle.TransferTimeoutSeconds
    }
    catch {
        # A status file that has not been created yet is still an in-progress cycle. Keep
        # other GuestOps/transfer failures visible to the fleet so its classifier can decide
        # whether the poll is retryable.
        if (Test-GuestOperationFileNotFound -ErrorRecord $_) {
            return $null
        }
        throw
    }

    if (-not (Test-Path -LiteralPath $Handle.LocalStatusPath -PathType Leaf)) {
        return $null
    }

    try {
        $content = Get-Content -LiteralPath $Handle.LocalStatusPath -Raw
        if ([string]::IsNullOrWhiteSpace([string]$content)) {
            return $null
        }
        return ($content | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Test-VMAgentCycleComplete {
    param($Handle)

    $processes = @($Handle.Managers.ProcessManager.ListProcessesInGuest($Handle.VMView.MoRef, $Handle.GuestAuth, @([long]$Handle.ProcessId)))

    if ($processes.Count -eq 0) {
        # vSphere keeps finished process info only for a limited window. An empty list is
        # conclusive only when the current cycle's terminal status is already available;
        # Started, missing, malformed, or foreign status must keep the same agent in flight.
        $status = Read-VMAgentCycleStatus -Handle $Handle
        if ($null -ne $status -and (Test-AgentCycleCompletion -Status $status -RunId ([string]$Handle.RunId) -Mode ([string]$Handle.Mode))) {
            $Handle.Status = $status
            return [pscustomobject]@{ Completed = $false; ExitCode = $null; EndTime = $null }
        }

        return $null
    }

    $process = $processes[0]
    if ($null -ne $process.EndTime -or $null -ne $process.ExitCode) {
        return [pscustomobject]@{ Completed = $true; ExitCode = $process.ExitCode; EndTime = $process.EndTime }
    }

    # A null result means one thing only: the process is still running.
    return $null
}

# The guest working directory belongs to the customer, not to this tool: it is a fixed path the
# operator configured, and anything else may live under it. The only delete this tool performs is
# recursive, so it is fenced in by an explicit allow-list of conditions rather than by a check for
# anything obviously wrong. Every failure answers "retain", never "delete and hope".
# The entry point and the deletion point have to agree on what "canonical" means, or a
# working directory accepted at startup fails validation hours later, silently, on every VM.
# Returns the canonical form so the caller can tell the operator what to write instead.
function Test-GuestDirectoryCanonical {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ IsCanonical = $false; CanonicalPath = $null; Reason = 'No guest directory was supplied.' }
    }

    if ($Path.StartsWith('\\')) {
        return [pscustomobject]@{ IsCanonical = $false; CanonicalPath = $null; Reason = 'A UNC path is not a supported guest directory.' }
    }

    # Checked BEFORE GetFullPath, which resolves a relative path against the stepping
    # stone's current directory and would hand back something absolute that never was.
    if ($Path -notmatch '^[A-Za-z]:\\') {
        return [pscustomobject]@{ IsCanonical = $false; CanonicalPath = $null; Reason = 'A guest directory must be an absolute local path such as C:\ProgramData\PatchingGuestOps.' }
    }

    $canonical = $null
    try {
        $canonical = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    }
    catch {
        return [pscustomobject]@{ IsCanonical = $false; CanonicalPath = $null; Reason = 'The guest directory is not a usable Windows path.' }
    }

    if (-not [string]::Equals($canonical, $Path.TrimEnd('\'), [System.StringComparison]::Ordinal)) {
        return [pscustomobject]@{ IsCanonical = $false; CanonicalPath = $canonical; Reason = ('The guest directory is not in canonical form; write "{0}" instead.' -f $canonical) }
    }

    return [pscustomobject]@{ IsCanonical = $true; CanonicalPath = $canonical; Reason = $null }
}

function Test-GuestCycleDirectoryRemovable {
    param($Handle)

    $rootRaw = [string](Get-ObjectPropertyValue -InputObject $Handle -Path @('GuestWorkingDirectory'))
    $cycleRaw = [string](Get-ObjectPropertyValue -InputObject $Handle -Path @('GuestCycleDirectory'))
    $runId = [string](Get-ObjectPropertyValue -InputObject $Handle -Path @('RunId'))

    if ([string]::IsNullOrWhiteSpace($rootRaw) -or [string]::IsNullOrWhiteSpace($cycleRaw)) {
        return New-GuestCycleCleanupVerdict -Removable $false -Reason 'The cycle handle carries no guest directory pair.'
    }

    # The run id names the directory, so it decides what may be deleted. Only the format this
    # tool generates is accepted; anything else means the handle was not built by a cycle start.
    if ($runId -cnotmatch '^[0-9a-f]{32}\z') {
        return New-GuestCycleCleanupVerdict -Removable $false -Reason ('Run id "{0}" is not a generated cycle identity.' -f $runId)
    }

    # One notion of canonical, shared with the entry point that accepted this directory in the
    # first place. Absoluteness is settled there, before GetFullPath, and so is the requirement
    # that the string sent to the guest is the string this validated - where those differ, the
    # stepping stone's normalisation is an assumption about the guest rather than a fact.
    $rootVerdict = Test-GuestDirectoryCanonical -Path $rootRaw
    if (-not $rootVerdict.IsCanonical) {
        return New-GuestCycleCleanupVerdict -Removable $false -Reason ('Working directory "{0}" cannot be validated: {1}' -f $rootRaw, $rootVerdict.Reason)
    }

    $cycleVerdict = Test-GuestDirectoryCanonical -Path $cycleRaw
    if (-not $cycleVerdict.IsCanonical) {
        return New-GuestCycleCleanupVerdict -Removable $false -Reason ('Cycle directory "{0}" cannot be validated: {1}' -f $cycleRaw, $cycleVerdict.Reason)
    }

    $rootPath = $rootVerdict.CanonicalPath
    $cyclePath = $cycleVerdict.CanonicalPath

    # A drive root trims to "C:", which has no parent to compare against.
    if ($cyclePath.Length -le 2 -or $rootPath.Length -le 2) {
        return New-GuestCycleCleanupVerdict -Removable $false -Reason 'A drive root is never removed.'
    }

    if ([string]::Equals($cyclePath, $rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return New-GuestCycleCleanupVerdict -Removable $false -Reason 'The cycle directory is the working directory itself.'
    }

    # Comparing the immediate parent rather than a prefix is what makes a sibling that merely
    # starts with the same characters - PatchingGuestOpsOld next to PatchingGuestOps - unreachable.
    $parentPath = [string][System.IO.Path]::GetDirectoryName($cyclePath)
    if ([string]::IsNullOrWhiteSpace($parentPath)) {
        return New-GuestCycleCleanupVerdict -Removable $false -Reason 'The cycle directory has no parent to validate.'
    }
    $parentPath = $parentPath.TrimEnd('\')

    if (-not [string]::Equals($parentPath, $rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return New-GuestCycleCleanupVerdict -Removable $false -Reason ('The cycle directory is not directly under the working directory: "{0}".' -f $cyclePath)
    }

    # Case-sensitive: the run id was generated lowercase, and a name that differs only in case
    # is a different directory as far as this tool is concerned.
    if (-not [string]::Equals([System.IO.Path]::GetFileName($cyclePath), $runId, [System.StringComparison]::Ordinal)) {
        return New-GuestCycleCleanupVerdict -Removable $false -Reason ('The cycle directory is not named for this run: "{0}".' -f $cyclePath)
    }

    return New-GuestCycleCleanupVerdict -Removable $true -Reason $null -Path $cyclePath
}

function New-GuestCycleCleanupVerdict {
    param(
        [bool]$Removable,
        [string]$Reason,
        [string]$Path
    )

    return [pscustomobject]@{
        Removable = $Removable
        Reason = $Reason
        Path = $Path
    }
}

# The sole deletion point. It runs after the artifacts are collected and parsed, never from a
# finally block: a cycle that failed half way through is exactly the one whose guest-side files
# are worth keeping.
function Remove-CompletedVMAgentCycleArtifacts {
    param(
        $Handle,
        $Cycle
    )

    $completionConfirmed = [bool](Get-ObjectPropertyValue -InputObject $Cycle -Path @('AgentCompletionConfirmed') -DefaultValue $false)
    if (-not $completionConfirmed) {
        return New-GuestCycleCleanupResult -Status 'Retained' -Reason 'The agent did not confirm a terminal status for this run.'
    }

    # A process result the fleet never obtained is not evidence of completion, whatever the
    # status file says: the agent writes status.json eagerly, and a guest that dropped out of
    # vSphere's process list may still be running.
    $agentResult = Get-ObjectPropertyValue -InputObject $Cycle -Path @('AgentResult')
    if ($null -eq $agentResult -or -not [bool](Get-ObjectPropertyValue -InputObject $agentResult -Path @('Completed') -DefaultValue $false)) {
        return New-GuestCycleCleanupResult -Status 'Retained' -Reason 'The guest process did not report completion.'
    }

    # Both artifacts must have arrived in THIS collection. A status left over from an earlier
    # read proves nothing about what is on the guest now.
    if (-not [bool](Get-ObjectPropertyValue -InputObject $Cycle -Path @('StatusDownloaded') -DefaultValue $false)) {
        return New-GuestCycleCleanupResult -Status 'Retained' -Reason 'status.json was not downloaded during this collection.'
    }

    if (-not [bool](Get-ObjectPropertyValue -InputObject $Cycle -Path @('LogDownloaded') -DefaultValue $false)) {
        return New-GuestCycleCleanupResult -Status 'Retained' -Reason 'agent.log was not downloaded during this collection.'
    }

    foreach ($localPath in @([string]$Handle.LocalStatusPath, [string]$Handle.LocalLogPath)) {
        if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
            return New-GuestCycleCleanupResult -Status 'Retained' -Reason ('The collected artifact "{0}" is not on the stepping stone.' -f $localPath)
        }
    }

    $verdict = Test-GuestCycleDirectoryRemovable -Handle $Handle
    if (-not $verdict.Removable) {
        return New-GuestCycleCleanupResult -Status 'Retained' -Reason $verdict.Reason
    }

    try {
        $null = $Handle.Managers.FileManager.DeleteDirectoryInGuest($Handle.VMView.MoRef, $Handle.GuestAuth, $verdict.Path, $true)
    }
    catch {
        # A guest that refuses the delete leaves files behind; it does not make a successful
        # patch run into a failed one, so this never touches the WUA result.
        return New-GuestCycleCleanupResult -Status 'Warning' -Reason ('The cycle directory could not be removed: {0}' -f $_.Exception.Message)
    }

    return New-GuestCycleCleanupResult -Status 'Removed' -Reason $null
}

function New-GuestCycleCleanupResult {
    param(
        [ValidateSet('Removed', 'Retained', 'Warning')]
        [string]$Status,
        [string]$Reason
    )

    return [pscustomobject]@{
        CleanupStatus = $Status
        CleanupReason = $Reason
    }
}

function Complete-VMAgentCycle {
    param(
        $Handle,
        $AgentResult
    )

    $artifactErrors = @()
    # The first artifact failure is kept, not just its message: a credential that expired
    # mid-cycle shows up here as an InvalidGuestLogin, and re-throwing a bare string below
    # would erase the one piece of information that lets the caller offer recovery.
    $artifactException = $null
    # Whether each artifact arrived in THIS collection, which is not the same question as
    # whether a file is sitting in the output directory: a status left over from an earlier
    # read proves nothing about what is still on the guest.
    $statusDownloaded = $false
    $logDownloaded = $false
    $status = Get-ObjectPropertyValue -InputObject $Handle -Path @('Status')
    if ($null -eq $status) {
        try {
            $status = Read-VMAgentCycleStatus -Handle $Handle
            $statusDownloaded = ($null -ne $status)
        }
        catch {
            $artifactErrors += ('status.json download failed: {0}' -f $_.Exception.Message)
            if ($null -eq $artifactException) { $artifactException = $_.Exception }
        }
    }

    try {
        Receive-GuestFile -FileManager $Handle.Managers.FileManager -VMView $Handle.VMView -GuestAuth $Handle.GuestAuth -HostName $Handle.HostName -CurlPath $Handle.CurlPath -GuestPath $Handle.GuestLogPath -LocalPath $Handle.LocalLogPath -TimeoutSeconds $Handle.TransferTimeoutSeconds
        $logDownloaded = $true
    }
    catch {
        $artifactErrors += ('agent.log download failed: {0}' -f $_.Exception.Message)
        if ($null -eq $artifactException) { $artifactException = $_.Exception }
    }

    if ($artifactErrors.Count -gt 0) {
        foreach ($artifactError in $artifactErrors) {
            Write-Warning $artifactError
        }
    }

    if ($null -eq $status -or -not (Test-Path -LiteralPath $Handle.LocalStatusPath -PathType Leaf)) {
        $missingStatusMessage = 'status.json was not downloaded. Output directory: {0}' -f (Split-Path -Parent $Handle.LocalStatusPath)
        if ($null -ne $artifactException) {
            throw (New-Object System.InvalidOperationException -ArgumentList $missingStatusMessage, $artifactException)
        }
        throw $missingStatusMessage
    }

    $statusRunId = [string](Get-ObjectPropertyValue -InputObject $status -Path @('runId'))
    if ([string]::IsNullOrWhiteSpace([string]$Handle.RunId) -or $statusRunId -cne [string]$Handle.RunId) {
        throw 'status.json runId does not match the current agent run.'
    }

    $mode = [string](Get-ObjectPropertyValue -InputObject $Handle -Path @('Mode') -DefaultValue 'Apply')
    $agentCompletionConfirmed = Test-AgentCycleCompletion -Status $status -RunId ([string]$Handle.RunId) -Mode $mode
    $agentCompletionReason = if ($agentCompletionConfirmed) {
        'Agent status confirms terminal completion for the current run.'
    }
    else {
        'Agent status does not confirm terminal completion for the current run.'
    }

    $cycle = [pscustomobject]@{
        RunId = $Handle.RunId
        Mode = $mode
        AgentCompletionConfirmed = [bool]$agentCompletionConfirmed
        AgentCompletionReason = $agentCompletionReason
        AgentResult = $AgentResult
        Status = $status
        StatusDownloaded = $statusDownloaded
        LogDownloaded = $logDownloaded
        CleanupStatus = $null
        CleanupReason = $null
    }

    # Cleanup runs here and nowhere else: after both downloads and after the status has been
    # parsed and matched to this run. A finally block would fire on the failure paths above,
    # which are exactly the cycles whose guest-side files someone will want to look at.
    # Minor 2: the cleanup decision must never turn a successful patch into a failed VM.
    # Nothing in it is expected to throw, which is exactly why an unexpected throw here
    # would be so expensive - it would surface as a fleet collection error.
    $cleanup = $null
    try {
        $cleanup = Remove-CompletedVMAgentCycleArtifacts -Handle $Handle -Cycle $cycle
    }
    catch {
        $cleanup = New-GuestCycleCleanupResult -Status 'Warning' -Reason ('Cycle cleanup could not be evaluated: {0}' -f $_.Exception.Message)
    }
    $cycle.CleanupStatus = $cleanup.CleanupStatus
    $cycle.CleanupReason = $cleanup.CleanupReason
    # A directory left behind is the symptom this cleanup exists to remove, so it is never
    # silent: without this line the only way to notice is to go and look at the guest.
    if ($cleanup.CleanupStatus -eq 'Retained') {
        Write-Warning ('Guest cycle directory kept on {0} (runId {1}): {2}' -f (Get-ObjectPropertyValue -InputObject $Handle -Path @('VMName')), $Handle.RunId, $cleanup.CleanupReason)
    }

    if ($cleanup.CleanupStatus -eq 'Warning') {
        Write-Warning $cleanup.CleanupReason
    }

    return $cycle
}

function Invoke-VMGuestReboot {
    param(
        [string]$VMName,
        [object[]]$Servers,
        $Managers,
        $GuestAuth,
        [string]$ExpectedMoRefIdentity,
        [string]$WorkspaceScriptPath,
        [string]$RunGuardScriptPath,
        [string]$RebootScriptPath,
        # How long to wait for the request process to report. A guest that is actually restarting
        # stops answering well before this, and that silence is read as "sent"; the wait exists
        # only to catch the cases where the guest is still up and refused.
        [int]$SubmissionWaitSeconds = 20,
        [int]$PollSeconds = 2
    )

    Write-Step -Message ('Resolving VM {0} for guest reboot.' -f $VMName)
    # Start-GuestReboot is the only call here that can leave shutdown.exe running, so every
    # failure before it is unambiguously "never sent". Saying so spares the caller a full
    # reboot-timeout wait observing a guest that was never told to restart.
    try {
        $vm = Get-ExactVM -Name $VMName -Servers $Servers
        Assert-VMMatchesExpectedMoRef -VM $vm -ExpectedMoRefIdentity $ExpectedMoRefIdentity -VMName $VMName
        Assert-VMReadyForGuestOps -VM $vm

        $vmView = $vm.ExtensionData
        if ($null -eq $Managers) {
            $Managers = Get-GuestOpsManagers -VMView $vmView
        }
    }
    catch {
        try { $_.Exception.Data['RejectedBeforeStart'] = $true } catch { }
        throw
    }
    Write-Step -Message ('Initiating guest reboot for VM {0}.' -f $VMName)
    $rebootRunId = [guid]::NewGuid().ToString('N')
    $rebootProcessId = Start-GuestReboot -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -RunId $rebootRunId -WorkspaceScriptPath $WorkspaceScriptPath -RunGuardScriptPath $RunGuardScriptPath -RebootScriptPath $RebootScriptPath

    # The request process holds the guest run guard while it orders the restart, so its exit code
    # is the only place a refusal can surface. Read it if the guest is still there to answer.
    $submissionResult = $null
    try {
        $submissionResult = Wait-GuestProcess -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -ProcessId $rebootProcessId -TimeoutSeconds ([int][math]::Max(1, $SubmissionWaitSeconds)) -PollSeconds ([int][math]::Max(1, $PollSeconds))
    }
    catch {
        # The guest going away mid-poll is what a successful restart looks like from here.
        $submissionResult = $null
    }

    $verdict = Get-GuestRebootSubmissionVerdict -ProcessResult $submissionResult
    if (-not $verdict.Sent) {
        $rejection = New-Object System.InvalidOperationException -ArgumentList ('The guest refused the reboot request for {0}: {1}' -f $VMName, $verdict.Reason)
        try {
            $rejection.Data['RejectedBeforeStart'] = $true
            if ([bool]$verdict.Conflict) {
                $rejection.Data['GuestRunConflict'] = $true
            }
        }
        catch { }
        throw $rejection
    }

    return [pscustomobject]@{
        VMName = $VMName
        ProcessId = $rebootProcessId
        RunId = $rebootRunId
        SubmissionReason = [string]$verdict.Reason
    }
}

function New-GuestBootTimeQueryArguments {
    param(
        [string]$BootTimeHelperPath,
        [string]$OutputPath,
        [string]$WorkspacePath = '',
        [string]$WorkspaceSealToken = ''
    )

    $safeHelperPath = ([string]$BootTimeHelperPath) -replace '"', '`"'
    $safeOutputPath = ([string]$OutputPath) -replace '"', '`"'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -OutputPath "{1}"' -f $safeHelperPath, $safeOutputPath
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceSealToken)) {
        # The helper re-checks the seal before writing anything, so this read cannot come from a
        # directory that was swapped between the bootstrap and the query.
        $safeWorkspacePath = ([string]$WorkspacePath) -replace '"', '`"'
        $safeSealToken = ([string]$WorkspaceSealToken) -replace '"', '`"'
        $arguments = '{0} -WorkspacePath "{1}" -WorkspaceSealToken "{2}"' -f $arguments, $safeWorkspacePath, $safeSealToken
    }

    return $arguments
}

function Start-GuestBootTimeQuery {
    param(
        $ProcessManager,
        $VMView,
        $GuestAuth,
        [string]$BootTimeHelperPath,
        [string]$OutputPath,
        [string]$WorkspacePath = '',
        [string]$WorkspaceSealToken = ''
    )

    $programSpec = New-Object VMware.Vim.GuestProgramSpec
    $programSpec.ProgramPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $programSpec.Arguments = New-GuestBootTimeQueryArguments -BootTimeHelperPath $BootTimeHelperPath -OutputPath $OutputPath -WorkspacePath $WorkspacePath -WorkspaceSealToken $WorkspaceSealToken
    $programSpec.WorkingDirectory = Split-Path -Parent $OutputPath

    return $ProcessManager.StartProgramInGuest($VMView.MoRef, $GuestAuth, $programSpec)
}

function Invoke-VMGuestBootTimeRead {
    param(
        [string]$VMName,
        [object[]]$Servers,
        $Managers,
        $GuestAuth,
        [string]$CurlPath,
        [string]$GuestWorkingDirectory,
        [string]$BootTimeHelperPath,
        [int]$TimeoutSeconds = 120,
        [int]$PollSeconds = 5,
        [switch]$SkipHelperUpload,
        [string]$WorkspaceScriptPath = (Join-Path $PSScriptRoot '..\guest\GuestWorkspace.ps1')
    )

    $vm = Get-ExactVM -Name $VMName -Servers $Servers
    Assert-VMReadyForGuestOps -VM $vm

    $vmView = $vm.ExtensionData
    if ($null -eq $Managers) {
        $Managers = Get-GuestOpsManagers -VMView $vmView
    }
    $hostName = Get-VMHostNameForTransfer -VMView $vmView

    $localTempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('guestops-boottime-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $localTempDirectory | Out-Null

    try {
        # One helper and one output file per guest, overwritten on every attempt. Naming them per
        # attempt instead would pile up hundreds of files per VM per run inside the guest and never
        # clean them up. A VM is never polled concurrently with itself, so overwriting is safe --
        # but it does mean a dead query would leave the previous attempt's JSON in place, which is
        # why the exit code of the query below is checked and not just its completion.
        $safeVmName = ([string]$VMName) -replace '[^a-zA-Z0-9_.-]', '_'
        $guestHelperPath = Join-Path $GuestWorkingDirectory ('Read-BootTime-{0}.ps1' -f $safeVmName)
        $guestOutputPath = Join-Path $GuestWorkingDirectory ('boot-time-{0}.json' -f $safeVmName)
        $operationDeadline = (Get-Date).AddSeconds([math]::Max(1, $TimeoutSeconds))
        $getRemainingSeconds = {
            $remaining = ($operationDeadline - (Get-Date)).TotalSeconds
            if ($remaining -le 0) {
                throw 'Boot time read timeout budget expired.'
            }
            return [int][math]::Ceiling($remaining)
        }

        # mkdir and the boot-time query both finish in about a second, while $PollSeconds is sized
        # for the WUA agent, which runs for minutes. Polling those two at the caller's cadence would
        # burn most of a poll interval per attempt just noticing that a one-second job is done.
        $shortOperationPollSeconds = [int][math]::Max(1, [math]::Min(5, $PollSeconds))

        # The working directory and the helper survive a reboot - it is the same ProgramData path
        # the WUA agent uses - so re-creating and re-uploading them on every observation round is
        # pure waste on the data plane. The caller drops the switch again after any failed read,
        # so a guest that lost the file self-heals on the next attempt.
        # The directory is verified on EVERY read, upload or not. -SkipHelperUpload exists to
        # save a transfer, not to skip the security check: the helper it reuses is a script this
        # tool is about to run in the guest, and a directory that became writable between two
        # observation rounds is exactly the window worth closing.
        $workspaceTimeoutSeconds = [int][math]::Min(120, (& $getRemainingSeconds))
        # When the upload is skipped the helper already in the guest is the one about to run,
        # so it is checked too. A fresh upload replaces whatever is there, so it is not.
        $workspaceFilePath = if ($SkipHelperUpload) { $guestHelperPath } else { '' }
        $bootTimeSealToken = New-GuestWorkspaceSealToken
        Assert-GuestWorkspaceReady -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -VMName $VMName -Path $GuestWorkingDirectory -WorkspaceScriptPath $WorkspaceScriptPath -Mode 'Initialize' -FilePath $workspaceFilePath -SealToken $bootTimeSealToken -TimeoutSeconds $workspaceTimeoutSeconds -PollSeconds $shortOperationPollSeconds

        if (-not $SkipHelperUpload) {
            Send-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -LocalPath $BootTimeHelperPath -GuestPath $guestHelperPath -TimeoutSeconds (& $getRemainingSeconds)
            # The helper dot-sources this to check the seal, so it has to sit beside it. The
            # directory was verified above, so writing into it is safe.
            Send-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -LocalPath $WorkspaceScriptPath -GuestPath (Join-Path $GuestWorkingDirectory 'GuestWorkspace.ps1') -TimeoutSeconds (& $getRemainingSeconds)
        }

        $queryProcessId = Start-GuestBootTimeQuery -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -BootTimeHelperPath $guestHelperPath -OutputPath $guestOutputPath -WorkspacePath $GuestWorkingDirectory -WorkspaceSealToken $bootTimeSealToken
        $queryTimeoutSeconds = & $getRemainingSeconds
        $queryResult = Wait-GuestProcess -ProcessManager $Managers.ProcessManager -VMView $vmView -GuestAuth $GuestAuth -ProcessId $queryProcessId -TimeoutSeconds $queryTimeoutSeconds -PollSeconds $shortOperationPollSeconds
        if (-not $queryResult.Completed) {
            throw ('Boot time query did not complete within {0} seconds.' -f $TimeoutSeconds)
        }
        # A non-zero exit means the helper did not write this attempt's file. With a stable output
        # path the previous attempt's JSON would still be sitting there, so downloading it would
        # silently pass off a stale boot time as a fresh reading.
        if ($null -ne $queryResult.ExitCode -and $queryResult.ExitCode -ne 0) {
            throw ('Boot time query failed inside guest. ExitCode={0}' -f $queryResult.ExitCode)
        }

        $localOutputPath = Join-Path $localTempDirectory 'boot-time.json'
        Receive-GuestFile -FileManager $Managers.FileManager -VMView $vmView -GuestAuth $GuestAuth -HostName $hostName -CurlPath $CurlPath -GuestPath $guestOutputPath -LocalPath $localOutputPath -TimeoutSeconds (& $getRemainingSeconds)

        $parsed = Get-Content -LiteralPath $localOutputPath -Raw | ConvertFrom-Json
        $parsedError = [string](Get-ObjectPropertyValue -InputObject $parsed -Path @('error'))
        if (-not [string]::IsNullOrWhiteSpace($parsedError)) {
            throw ('Boot time query failed inside guest: {0}' -f $parsedError)
        }

        $bootTimeUtcText = [string](Get-ObjectPropertyValue -InputObject $parsed -Path @('bootTimeUtc'))
        $bootTimeUtc = $null
        if (-not [string]::IsNullOrWhiteSpace($bootTimeUtcText)) {
            $bootTimeUtc = [datetime]::Parse($bootTimeUtcText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        }

        $uptimeSecondsValue = Get-ObjectPropertyValue -InputObject $parsed -Path @('uptimeSeconds')
        $uptimeSeconds = if ($null -eq $uptimeSecondsValue) { $null } else { [int]$uptimeSecondsValue }

        return [pscustomobject]@{
            VMName = $VMName
            BootTimeUtc = $bootTimeUtc
            UptimeSeconds = $uptimeSeconds
        }
    }
    finally {
        Remove-Item -LiteralPath $localTempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

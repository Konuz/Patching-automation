Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function New-GuiLabel {
    param([string]$Text, [int]$Top)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Left = 12
    $label.Top = $Top
    $label.Width = 200
    return $label
}

function New-GuiTextBox {
    param([string]$Text, [int]$Top, [int]$Width = 380)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Text = $Text
    $box.Left = 220
    $box.Top = ($Top - 3)
    $box.Width = $Width
    return $box
}

function Show-CredentialDialog {
    param(
        [string]$Title,
        [string]$Message,
        [string]$UserName = ''
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Width = 520
    $form.Height = 220
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.ShowInTaskbar = $true

    $prompt = New-GuiLabel -Text $Message -Top 15
    $prompt.Width = 480

    $userBox = New-GuiTextBox -Text $UserName -Top 55 -Width 260
    $passwordBox = New-GuiTextBox -Text '' -Top 90 -Width 260
    $passwordBox.UseSystemPasswordChar = $true

    $remember = New-Object System.Windows.Forms.CheckBox
    $remember.Text = 'Remember on this machine'
    $remember.Left = 220
    $remember.Top = 118
    $remember.Width = 300
    # Unticked by default. Writing a password to disk is a decision an operator makes, not one
    # they have to notice and undo: DPAPI binds the file to this Windows account on this machine
    # and nothing more, so anything running as that account can read it back. Unticking it does
    # not delete a password already in the store - see Write-CredentialStore - so the default
    # cannot silently drop credentials the operator saved earlier on purpose.
    $remember.Checked = $false

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.Left = 300
    $ok.Top = 145
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Left = 390
    $cancel.Top = 145
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $form.Controls.AddRange(@($prompt, (New-GuiLabel -Text 'User name' -Top 55), $userBox, (New-GuiLabel -Text 'Password' -Top 90), $passwordBox, $remember, $ok, $cancel))
    $form.AcceptButton = $ok
    $form.CancelButton = $cancel

    $form.Add_Shown({ $form.Activate() })
    $result = $form.ShowDialog()
    $enteredUser = $userBox.Text
    $enteredPassword = $passwordBox.Text
    $shouldRemember = $remember.Checked
    $form.Dispose()

    # An empty password is rejected here, not downstream. New-Object PSCredential with an
    # empty SecureString succeeds, but ConvertFrom-SecureString then throws inside
    # Write-CredentialStore's loop - and because the throw lands mid-loop, the ENTIRE save
    # is lost, not just this one key. Get-Credential cannot produce this; a text box can.
    if ($result -ne [System.Windows.Forms.DialogResult]::OK -or
        [string]::IsNullOrWhiteSpace($enteredUser) -or
        [string]::IsNullOrEmpty($enteredPassword)) {
        return $null
    }

    return [pscustomobject]@{
        Credential = (New-Object System.Management.Automation.PSCredential($enteredUser, (ConvertTo-SecureString $enteredPassword -AsPlainText -Force)))
        Remember = $shouldRemember
    }
}

# The recovery decision, not just a credential: the operator has to be able to say "skip this
# account" or "stop" without being forced to invent a password. Returns the same contract the
# console prompt does (scripts/CredentialRecovery.ps1), so the resolver cannot tell them apart.
function Show-GuestCredentialRecoveryDialog {
    param(
        [string]$Message,
        [string[]]$Members,
        # A vCenter has no account to skip: there is no way to run a patch round against a
        # server nobody can log in to, so that caller hides the button rather than offering
        # a choice it would silently turn into a full stop.
        [switch]$AllowSkip
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'PatchingGuestOps credentials rejected'
    $form.Width = 560
    $form.Height = 250
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.ShowInTaskbar = $true

    $prompt = New-GuiLabel -Text $Message -Top 15
    $prompt.Width = 520
    $prompt.Height = 40

    $memberText = 'This account is used for: {0}' -f (@($Members) -join ', ')
    $memberLabel = New-GuiLabel -Text $memberText -Top 60
    $memberLabel.Width = 520
    $memberLabel.Height = 50

    $retry = New-Object System.Windows.Forms.Button
    $retry.Text = 'Enter again'
    $retry.Left = 15
    $retry.Top = 160
    $retry.Width = 150
    $retry.DialogResult = [System.Windows.Forms.DialogResult]::Retry

    $skip = New-Object System.Windows.Forms.Button
    $skip.Text = 'Skip this account for this run'
    $skip.Left = 180
    $skip.Top = 160
    $skip.Width = 220
    $skip.DialogResult = [System.Windows.Forms.DialogResult]::Ignore

    $abort = New-Object System.Windows.Forms.Button
    $abort.Text = 'Stop'
    $abort.Left = 415
    $abort.Top = 160
    $abort.Width = 110
    $abort.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $skip.Visible = [bool]$AllowSkip
    $skip.Enabled = [bool]$AllowSkip

    $form.Controls.AddRange(@($prompt, $memberLabel, $retry, $skip, $abort))
    $form.AcceptButton = $retry
    $form.CancelButton = $abort

    $form.Add_Shown({ $form.Activate() })
    $result = $form.ShowDialog()
    $form.Dispose()

    if ($result -eq [System.Windows.Forms.DialogResult]::Ignore) {
        return [pscustomobject]@{ Action = 'SkipAccount'; Credential = $null; Remember = $false }
    }

    if ($result -ne [System.Windows.Forms.DialogResult]::Retry) {
        return [pscustomobject]@{ Action = 'Abort'; Credential = $null; Remember = $false }
    }

    # Closing the credential form is a withdrawal of the retry, not a skip: the operator asked
    # to type a new password and then changed their mind, so nothing about the account is decided.
    $entered = Show-CredentialDialog -Title 'PatchingGuestOps credentials' -Message $Message
    if ($null -eq $entered) {
        return [pscustomobject]@{ Action = 'Abort'; Credential = $null; Remember = $false }
    }

    return [pscustomobject]@{ Action = 'Retry'; Credential = $entered.Credential; Remember = [bool]$entered.Remember }
}

function Show-UpdateGroupDialog {
    param($UpdateGroups, [int[]]$DefaultCheckedIndexes)

    $groups = @($UpdateGroups)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Select update groups to install'
    $form.Width = 900
    $form.Height = 600
    $form.StartPosition = 'CenterScreen'
    $form.ShowInTaskbar = $true

    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Left = 12
    $list.Top = 12
    $list.Width = 860
    $list.Height = 460
    $list.CheckOnClick = $true

    foreach ($group in $groups) {
        $kbText = if ([string]::IsNullOrWhiteSpace([string]$group.kbText)) { 'No KB' } else { [string]$group.kbText }
        [void]$list.Items.Add(('{0} - {1}  (applies to {2} VM, patchable {3})' -f $kbText, (Get-UpdateGroupDisplayTitle -UpdateGroup $group), $group.appliesToVmCount, $group.patchableVmCount))
    }

    foreach ($index in @($DefaultCheckedIndexes)) {
        if ($index -ge 0 -and $index -lt $list.Items.Count) {
            $list.SetItemChecked($index, $true)
        }
    }

    $install = New-Object System.Windows.Forms.Button
    $install.Text = 'Install selected'
    $install.Left = 660
    $install.Top = 490
    $install.Width = 100
    $install.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $abort = New-Object System.Windows.Forms.Button
    $abort.Text = 'Abort run'
    $abort.Left = 772
    $abort.Top = 490
    $abort.Width = 100
    $abort.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $form.Controls.AddRange(@($list, $install, $abort))
    $form.AcceptButton = $install
    $form.CancelButton = $abort

    # This window appears hours into a run, behind the console window. Without Activate()
    # the operator never sees it and concludes the run has hung.
    $form.Add_Shown({ $form.Activate() })
    $result = $form.ShowDialog()

    $checkedIndexes = @()
    foreach ($index in $list.CheckedIndices) {
        $checkedIndexes += [int]$index
    }
    $form.Dispose()

    return [pscustomobject]@{
        Aborted = ($result -ne [System.Windows.Forms.DialogResult]::OK)
        CheckedIndexes = @($checkedIndexes)
    }
}

function Show-RescanDialog {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'PatchingGuestOps rescan'
    $form.Width = 560
    $form.Height = 240
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.ShowInTaskbar = $true

    $prompt = New-GuiLabel -Text 'This scan cycle is finished and its report is saved.' -Top 15
    $prompt.Width = 520
    $prompt.Height = 20

    $detailText = 'A fresh rescan is not a continuation of this cycle. It scans every VM from the ' +
        'original list again, asks for a new update selection with nothing carried over, restarts ' +
        'round numbering and writes its own report.'
    $detail = New-GuiLabel -Text $detailText -Top 45
    $detail.Width = 520
    $detail.Height = 80

    $again = New-Object System.Windows.Forms.Button
    $again.Text = 'Fresh full rescan'
    $again.Left = 15
    $again.Top = 150
    $again.Width = 170
    $again.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $finish = New-Object System.Windows.Forms.Button
    $finish.Text = 'Finish'
    $finish.Left = 415
    $finish.Top = 150
    $finish.Width = 110
    $finish.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $form.Controls.AddRange(@($prompt, $detail, $again, $finish))
    # Enter, Esc and the window's close button all finish, which is what an empty answer does in
    # the console. A rescan rediscovers every VM on the list, so it starts on a deliberate click
    # and never on a reflex keystroke.
    $form.AcceptButton = $finish
    $form.CancelButton = $finish

    # Same reason as the update group dialog: this window opens hours into a run, behind the
    # console window.
    $form.Add_Shown({ $form.Activate() })
    $result = $form.ShowDialog()
    $form.Dispose()

    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

function Show-LauncherDialog {
    param($Settings)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'PatchingGuestOps'
    $form.Width = 700
    $form.Height = 480
    $form.StartPosition = 'CenterScreen'
    $form.ShowInTaskbar = $true

    $viServerBox = New-GuiTextBox -Text (@($Settings.VIServers) -join ';') -Top 20
    $vmBox = New-GuiTextBox -Text '' -Top 55 -Width 300

    $browse = New-Object System.Windows.Forms.Button
    $browse.Text = 'From file...'
    $browse.Left = 530
    $browse.Top = 52
    $browse.Width = 90
    $browse.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $names = @(Get-Content -LiteralPath $dialog.FileName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.TrimStart().StartsWith('#') } | ForEach-Object { $_.Trim() })
            $vmBox.Text = ($names -join ';')
        }
        $dialog.Dispose()
    })

    $throttleBox = New-GuiTextBox -Text ([string]$Settings.ThrottleLimit) -Top 90 -Width 80
    $batchBox = New-GuiTextBox -Text ([string]$Settings.RebootBatchSize) -Top 125 -Width 80
    $roundsBox = New-GuiTextBox -Text ([string]$Settings.MaxPatchRounds) -Top 160 -Width 80
    $outputBox = New-GuiTextBox -Text ([string]$Settings.LocalOutputDirectory) -Top 195

    $ignoreCert = New-Object System.Windows.Forms.CheckBox
    $ignoreCert.Text = 'Ignore vCenter certificate (not ESXi)'
    $ignoreCert.Left = 220
    $ignoreCert.Top = 230
    $ignoreCert.Width = 300
    $ignoreCert.Checked = [bool]$Settings.IgnoreVCenterCertificate

    $ignoreESXiCert = New-Object System.Windows.Forms.CheckBox
    $ignoreESXiCert.Text = 'Ignore ESXi certificates (file transfers)'
    $ignoreESXiCert.Left = 220
    $ignoreESXiCert.Top = 255
    $ignoreESXiCert.Width = 360
    $ignoreESXiCert.Checked = [bool]$Settings.IgnoreESXiCertificate

    $keepConnected = New-Object System.Windows.Forms.CheckBox
    $keepConnected.Text = 'Keep vCenter session connected'
    $keepConnected.Left = 220
    $keepConnected.Top = 280
    $keepConnected.Width = 300
    $keepConnected.Checked = [bool]$Settings.KeepConnected

    $searchOnly = New-Object System.Windows.Forms.CheckBox
    $searchOnly.Text = 'Search only (no download or install)'
    $searchOnly.Left = 220
    $searchOnly.Top = 305
    $searchOnly.Width = 300

    $notice = New-Object System.Windows.Forms.Label
    $notice.Text = 'The run starts with local checks; they take roughly 20-40 seconds before anything touches vCenter.'
    $notice.Left = 12
    $notice.Top = 340
    $notice.Width = 640

    $start = New-Object System.Windows.Forms.Button
    $start.Text = 'Start'
    $start.Left = 460
    $start.Top = 375
    $start.Width = 90
    $start.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $quit = New-Object System.Windows.Forms.Button
    $quit.Text = 'Cancel'
    $quit.Left = 560
    $quit.Top = 375
    $quit.Width = 90
    $quit.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    # An empty vCenter or VM field makes the launcher prompt on the console AFTER this
    # window closes, in Resolve-VMTargetNames and Resolve-VIServerNames - the operator
    # would be staring at nothing.
    $start.Add_Click({
        if ([string]::IsNullOrWhiteSpace($viServerBox.Text) -or [string]::IsNullOrWhiteSpace($vmBox.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show('vCenter and VM fields are both required.', 'PatchingGuestOps', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            $form.DialogResult = [System.Windows.Forms.DialogResult]::None
        }
    })

    $form.Controls.AddRange(@(
        (New-GuiLabel -Text 'vCenter(s), ";" separated' -Top 20), $viServerBox,
        (New-GuiLabel -Text 'VM(s), ";" separated' -Top 55), $vmBox, $browse,
        (New-GuiLabel -Text 'Throttle limit (blank = all)' -Top 90), $throttleBox,
        (New-GuiLabel -Text 'Reboot batch size' -Top 125), $batchBox,
        (New-GuiLabel -Text 'Max patch rounds' -Top 160), $roundsBox,
        (New-GuiLabel -Text 'Output directory (blank = .\out)' -Top 195), $outputBox,
        $ignoreCert, $ignoreESXiCert, $keepConnected, $searchOnly, $notice, $start, $quit
    ))
    $form.AcceptButton = $start
    $form.CancelButton = $quit

    $form.Add_Shown({ $form.Activate() })
    $result = $form.ShowDialog()

    $answer = [pscustomobject]@{
        Cancelled = ($result -ne [System.Windows.Forms.DialogResult]::OK)
        VIServers = @(($viServerBox.Text -split ';') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        VMNames = @(($vmBox.Text -split ';') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        ThrottleLimit = $throttleBox.Text
        RebootBatchSize = $batchBox.Text
        MaxPatchRounds = $roundsBox.Text
        LocalOutputDirectory = $outputBox.Text
        IgnoreVCenterCertificate = $ignoreCert.Checked
        IgnoreESXiCertificate = $ignoreESXiCert.Checked
        KeepConnected = $keepConnected.Checked
        SearchOnly = $searchOnly.Checked
    }

    $form.Dispose()
    return $answer
}

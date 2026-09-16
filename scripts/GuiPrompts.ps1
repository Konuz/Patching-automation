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
        [string]$UserName = '',
        # Offered for a guest account only. A vCenter cannot be skipped: every VM behind it
        # would fail with a reason that names a password rather than the missing session, and
        # the run would have nowhere to look those VMs up at all.
        [switch]$AllowSkip
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

    # Skip and Cancel are deliberately different answers, so Esc and the window's close button
    # keep meaning Cancel. Skip leaves these VMs unpatched and lets the rest of the run start;
    # Cancel still ends the run before it touches anything.
    $skip = New-Object System.Windows.Forms.Button
    # One prompt covers an account, and an account can be a single machine - a local entry,
    # or a domain where only one member is still uncovered. VM(s) is what the rest of the
    # operator-facing text says for the same reason.
    $skip.Text = 'Skip these VM(s)'
    $skip.Left = 12
    $skip.Top = 145
    $skip.Width = 140
    $skip.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
    $skip.Visible = [bool]$AllowSkip
    $skip.Enabled = [bool]$AllowSkip

    $form.Controls.AddRange(@($prompt, (New-GuiLabel -Text 'User name' -Top 55), $userBox, (New-GuiLabel -Text 'Password' -Top 90), $passwordBox, $remember, $skip, $ok, $cancel))
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
    # Before the field validation below: a skip is an answer, not an incomplete entry, and
    # half-typed boxes must not turn it back into a cancel.
    if ($result -eq [System.Windows.Forms.DialogResult]::Ignore) {
        return [pscustomobject]@{ Credential = $null; Remember = $false; Skipped = $true }
    }

    if ($result -ne [System.Windows.Forms.DialogResult]::OK -or
        [string]::IsNullOrWhiteSpace($enteredUser) -or
        [string]::IsNullOrEmpty($enteredPassword)) {
        return $null
    }

    # Skipped is on both shapes, not only the skip one: under StrictMode a caller testing it on
    # a result that does not carry it is a terminating error.
    return [pscustomobject]@{
        Credential = (New-Object System.Management.Automation.PSCredential($enteredUser, (ConvertTo-SecureString $enteredPassword -AsPlainText -Force)))
        Remember = $shouldRemember
        Skipped = $false
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
    $list.Height = 330
    # Selecting a row must not change what gets installed. CheckOnClick toggled the box wherever
    # the row was clicked, so reading an entry's text was enough to approve or refuse an update
    # on the whole fleet. Off is not sufficient on its own: WinForms then toggles on the SECOND
    # click anywhere on an already-selected row, which is the same accident one click later.
    $list.CheckOnClick = $false

    foreach ($group in $groups) {
        $kbText = if ([string]::IsNullOrWhiteSpace([string]$group.kbText)) { 'No KB' } else { [string]$group.kbText }
        [void]$list.Items.Add(('{0} - {1}  (applies to {2} VM, patchable {3})' -f $kbText, (Get-UpdateGroupDisplayTitle -UpdateGroup $group), $group.appliesToVmCount, $group.patchableVmCount))
    }

    foreach ($index in @($DefaultCheckedIndexes)) {
        if ($index -ge 0 -and $index -lt $list.Items.Count) {
            $list.SetItemChecked($index, $true)
        }
    }

    # So the box changes only on a deliberate hit: a click on the glyph, or Space on the selected
    # row. Everything else is refused in ItemCheck by writing the current value back. Wired AFTER
    # the defaults above, because SetItemChecked raises ItemCheck too and the guard would cancel
    # the default policy's own ticks.
    $checkGuard = [pscustomobject]@{ Allow = $false }

    $list.Add_MouseDown({
        param($eventSender, $mouseArgs)
        # The glyph is drawn in a box at the row's left edge, so its width tracks the row height
        # and therefore the DPI. Deliberately generous: a bound that is slightly too wide costs a
        # toggle from just beside the box, one that is too narrow makes the box unclickable.
        $checkGuard.Allow = ($mouseArgs.X -le ($list.ItemHeight + 4))
    })

    $list.Add_KeyDown({
        param($eventSender, $keyArgs)
        if ($keyArgs.KeyCode -eq [System.Windows.Forms.Keys]::Space) {
            $checkGuard.Allow = $true
        }
    })

    $list.Add_ItemCheck({
        param($eventSender, $itemArgs)
        if (-not $checkGuard.Allow) {
            $itemArgs.NewValue = $itemArgs.CurrentValue
        }

        $checkGuard.Allow = $false
    })

    # The counts on each row say that something was excluded; only the names say which machine
    # somebody has to patch by hand. A pane rather than more text on the row: a fleet's worth of
    # FQDNs on one line is clipped by the list, and clipped is the same as not shown.
    $details = New-Object System.Windows.Forms.TextBox
    $details.Left = 12
    $details.Top = 350
    $details.Width = 860
    $details.Height = 130
    $details.Multiline = $true
    $details.ReadOnly = $true
    $details.WordWrap = $true
    $details.ScrollBars = 'Vertical'

    $showGroupDetails = {
        $selectedIndex = $list.SelectedIndex
        if ($selectedIndex -lt 0 -or $selectedIndex -ge $groups.Count) {
            $details.Lines = @('Select a group to see which VMs report it, and which of those this tool will patch.')
            return
        }

        $selectedGroup = $groups[$selectedIndex]
        $selectedKbText = if ([string]::IsNullOrWhiteSpace([string]$selectedGroup.kbText)) { 'No KB' } else { [string]$selectedGroup.kbText }
        $details.Lines = @(('{0} - {1}' -f $selectedKbText, (Get-UpdateGroupDisplayTitle -UpdateGroup $selectedGroup))) +
            @(Get-UpdateGroupVmDetailLines -UpdateGroup $selectedGroup)
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

    $form.Controls.AddRange(@($list, $details, $install, $abort))
    $form.AcceptButton = $install
    $form.CancelButton = $abort

    # Ticking a box does not move the selection, so the pane follows the highlighted row. Filled
    # once up front too: an empty pane on a dialog nobody has clicked yet reads as a broken one.
    $list.Add_SelectedIndexChanged($showGroupDetails)
    & $showGroupDetails

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

function Show-ContinuePatchingDialog {
    param($PendingStates, [int]$Round)

    $states = @($PendingStates)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'PatchingGuestOps - updates still outstanding'
    $form.Width = 760
    $form.Height = 420
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.ShowInTaskbar = $true

    $prompt = New-GuiLabel -Text ('After round {0} the following VM(s) still have selectable updates:' -f $Round) -Top 12
    $prompt.Width = 718
    $prompt.Height = 20

    $list = New-Object System.Windows.Forms.ListBox
    $list.Left = 12
    $list.Top = 40
    $list.Width = 718
    $list.Height = 200
    foreach ($state in $states) {
        [void]$list.Items.Add(('{0}: {1}' -f $state.vmName, $state.reason))
    }

    $detailText = 'Continue runs another round for those VM(s) only. It rescans them and installs what is ' +
        'still outstanding; update groups you unticked in this cycle stay unticked. Finish stops patching ' +
        'now, and the run ends with an error because those VMs are not up to date.'
    $detail = New-GuiLabel -Text $detailText -Top 250
    $detail.Width = 718
    $detail.Height = 60

    $continue = New-Object System.Windows.Forms.Button
    $continue.Text = 'Continue patching'
    $continue.Left = 12
    $continue.Top = 325
    $continue.Width = 170
    $continue.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $finish = New-Object System.Windows.Forms.Button
    $finish.Text = 'Finish'
    $finish.Left = 620
    $finish.Top = 325
    $finish.Width = 110
    $finish.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $form.Controls.AddRange(@($prompt, $list, $detail, $continue, $finish))
    # Enter, Esc and the window's close button all finish. Another round starts guest agents on
    # machines that are not up to date, so it begins on a deliberate click - the same rule the
    # rescan dialog follows.
    $form.AcceptButton = $finish
    $form.CancelButton = $finish

    # This window appears hours into a run, behind the console window.
    $form.Add_Shown({ $form.Activate() })
    $result = $form.ShowDialog()
    $form.Dispose()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return 'CONTINUE'
    }

    return 'FINISH'
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
    param(
        $Settings,
        # Where this tool writes runs when the operator sets no output directory. Used only to
        # open the resume browser where the plans actually are.
        [string]$DefaultOutputDirectory = ''
    )

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

    # Everything below stays out of the way until it is asked for: these are the knobs a run
    # normally does not touch, and two of them (Plan only, Skip local checks) change what the
    # run does rather than how it is tuned.
    $advancedToggle = New-Object System.Windows.Forms.CheckBox
    $advancedToggle.Text = 'Show advanced settings'
    $advancedToggle.Left = 220
    $advancedToggle.Top = 330
    $advancedToggle.Width = 300
    $advancedToggle.Checked = [bool](Get-ObjectPropertyValue -InputObject $Settings -Path @('ShowAdvanced') -DefaultValue $false)

    $advancedGroup = New-Object System.Windows.Forms.GroupBox
    $advancedGroup.Text = 'Advanced'
    $advancedGroup.Left = 12
    $advancedGroup.Top = 355
    $advancedGroup.Width = 660
    # Room for the last row plus the group's own bottom border; a child clipped by the frame
    # is a control the operator cannot reach.
    $advancedGroup.Height = 205

    $applyTimeoutBox = New-GuiTextBox -Text ([string](Get-ObjectPropertyValue -InputObject $Settings -Path @('TimeoutMinutes') -DefaultValue 180)) -Top 22 -Width 80
    $discoveryTimeoutBox = New-GuiTextBox -Text ([string](Get-ObjectPropertyValue -InputObject $Settings -Path @('DiscoveryTimeoutMinutes') -DefaultValue 30)) -Top 50 -Width 80
    $rebootTimeoutBox = New-GuiTextBox -Text ([string]$Settings.RebootTimeoutMinutes) -Top 78 -Width 80
    $guestDirBox = New-GuiTextBox -Text ([string](Get-ObjectPropertyValue -InputObject $Settings -Path @('GuestWorkingDirectory') -DefaultValue '')) -Top 106
    $planBox = New-GuiTextBox -Text '' -Top 134 -Width 300

    $planBrowse = New-Object System.Windows.Forms.Button
    $planBrowse.Text = 'Browse...'
    $planBrowse.Left = 530
    $planBrowse.Top = 131
    $planBrowse.Width = 90
    $planBrowse.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Patch plan (patch-plan.json)|patch-plan.json|JSON files (*.json)|*.json|All files (*.*)|*.*'
        # A plan lives at <output>\<run>\round-NN\patch-plan.json, so there is no single "last
        # plan" to offer: one run writes one per round. Open where this run would write them -
        # the operator's own output directory when they set one - and let them pick.
        $planStart = ([string]$outputBox.Text).Trim()
        if ([string]::IsNullOrWhiteSpace($planStart)) {
            $planStart = $DefaultOutputDirectory
        }
        if (-not [string]::IsNullOrWhiteSpace($planStart) -and (Test-Path -LiteralPath $planStart -PathType Container)) {
            $dialog.InitialDirectory = $planStart
        }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $planBox.Text = $dialog.FileName
        }
        $dialog.Dispose()
    })

    $planOnly = New-Object System.Windows.Forms.CheckBox
    $planOnly.Text = 'Plan only (write the plan, install nothing)'
    $planOnly.Left = 12
    $planOnly.Top = 165
    $planOnly.Width = 270

    $skipChecks = New-Object System.Windows.Forms.CheckBox
    $skipChecks.Text = 'Skip the local checks before this run (never saved)'
    $skipChecks.Left = 290
    $skipChecks.Top = 165
    $skipChecks.Width = 360

    $advancedGroup.Controls.AddRange(@(
        (New-GuiLabel -Text 'Apply timeout (min)' -Top 22), $applyTimeoutBox,
        (New-GuiLabel -Text 'Discovery timeout (min)' -Top 50), $discoveryTimeoutBox,
        (New-GuiLabel -Text 'Reboot timeout (min)' -Top 78), $rebootTimeoutBox,
        (New-GuiLabel -Text 'Guest working directory' -Top 106), $guestDirBox,
        (New-GuiLabel -Text 'Resume from saved plan' -Top 134), $planBox, $planBrowse,
        $planOnly, $skipChecks
    ))

    $notice = New-Object System.Windows.Forms.Label
    $notice.Text = 'The run starts with local checks; they take roughly 20-40 seconds before anything touches vCenter.'
    $notice.Left = 12
    $notice.Top = 355
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
        # The VM field is required even for a resume: the orchestrator resolves its targets
        # before it reads the saved plan, and an empty list throws there.
        if ([string]::IsNullOrWhiteSpace($viServerBox.Text) -or [string]::IsNullOrWhiteSpace($vmBox.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show('vCenter and VM fields are both required.', 'PatchingGuestOps', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            $form.DialogResult = [System.Windows.Forms.DialogResult]::None
            return
        }

        $enteredPlanPath = ([string]$planBox.Text).Trim()
        if ([string]::IsNullOrWhiteSpace($enteredPlanPath)) {
            return
        }

        # Both of these are refused by the launcher anyway - but there, minutes later, after the
        # local checks have run and the operator has walked away from the screen.
        if ($searchOnly.Checked) {
            [void][System.Windows.Forms.MessageBox]::Show('Search only cannot be combined with a saved plan. Use Plan only to inspect it.', 'PatchingGuestOps', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            $form.DialogResult = [System.Windows.Forms.DialogResult]::None
            return
        }

        if (-not (Test-Path -LiteralPath $enteredPlanPath -PathType Leaf)) {
            [void][System.Windows.Forms.MessageBox]::Show(('Saved plan not found: {0}' -f $enteredPlanPath), 'PatchingGuestOps', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            $form.DialogResult = [System.Windows.Forms.DialogResult]::None
            return
        }
    })

    $form.Controls.AddRange(@(
        (New-GuiLabel -Text 'vCenter(s), ";" separated' -Top 20), $viServerBox,
        (New-GuiLabel -Text 'VM(s), ";" separated' -Top 55), $vmBox, $browse,
        (New-GuiLabel -Text 'Throttle limit (blank = all)' -Top 90), $throttleBox,
        (New-GuiLabel -Text 'Reboot batch size' -Top 125), $batchBox,
        (New-GuiLabel -Text 'Max patch rounds' -Top 160), $roundsBox,
        (New-GuiLabel -Text 'Output directory (blank = .\out)' -Top 195), $outputBox,
        $ignoreCert, $ignoreESXiCert, $keepConnected, $searchOnly,
        $advancedToggle, $advancedGroup, $notice, $start, $quit
    ))
    $form.AcceptButton = $start
    $form.CancelButton = $quit

    # The advanced block is laid out in the flow rather than overlaid on it, so the notice, the
    # buttons and the window itself move with it. Applied once up front too: the checkbox
    # remembers its last state, and a window that opened expanded must not paint the group over
    # its own buttons.
    $applyAdvancedLayout = {
        $advancedGroup.Visible = [bool]$advancedToggle.Checked
        $noticeTop = if ($advancedToggle.Checked) { $advancedGroup.Top + $advancedGroup.Height + 10 } else { $advancedGroup.Top }
        $notice.Top = $noticeTop
        $start.Top = $noticeTop + 35
        $quit.Top = $noticeTop + 35
        $form.Height = $start.Top + 90
    }

    $advancedToggle.Add_CheckedChanged($applyAdvancedLayout)
    & $applyAdvancedLayout

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
        ShowAdvanced = $advancedToggle.Checked
        TimeoutMinutes = $applyTimeoutBox.Text
        DiscoveryTimeoutMinutes = $discoveryTimeoutBox.Text
        RebootTimeoutMinutes = $rebootTimeoutBox.Text
        GuestWorkingDirectory = ([string]$guestDirBox.Text).Trim()
        PatchPlanPath = ([string]$planBox.Text).Trim()
        PlanOnly = $planOnly.Checked
        SkipStaticChecks = $skipChecks.Checked
    }

    $form.Dispose()
    return $answer
}

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Automation for patching Windows Server **without WinRM**, driven entirely over the **vSphere Guest Operations** channel. WinRM/PSRemoting is assumed hard-blocked in the target environment, so the usual `Invoke-Command`/PSSession install path is dead. The runtime is the customer stepping stone: **Windows PowerShell 5.1 only** (no PS7, no rights to install binaries).

The committed code is the staged **full GuestOps patch orchestrator**: discovery → grouped update selection → per-VM plan → confirmation → apply → report. The original Phase 0b GuestOps validation path still exists inside the single-target flow, but the current operator-facing selection contract is grouped and keyed by `UpdateID|RevisionNumber`.

## Commands

```powershell
# Static, model, and runtime checks — the automated test gates. Run after EVERY change to the .ps1 scripts.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-StaticChecks.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-ModelChecks.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-RuntimeChecks.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-GuestOpsHarnessChecks.ps1

# Full run via the central launcher (prompts for vCenter/VM/credentials; runs local checks first).
.\Start-PatchingGuestOps.ps1

# Dry run — WUA search only, no download/install:
.\Start-PatchingGuestOps.ps1 -SearchOnly

# Non-interactive grouped update selection (skip the interactive prompt), keyed on identity:
.\Start-PatchingGuestOps.ps1 -SelectedUpdateKeys '<UpdateID>|<RevisionNumber>'

# Skip the pre-run local checks (static + model; e.g. when iterating against a live VM):
.\Start-PatchingGuestOps.ps1 -SkipStaticChecks

# Resume/apply from an existing patch plan:
.\Start-PatchingGuestOps.ps1 -PatchPlanPath .\out\<run>\patch-plan.json

# Reboot prompt is automatic when any VM reports rebootRequired=true after apply,
# or had pendingRebootBefore.isPending=true in discovery for this run.
# The operator must type REBOOT; -SkipConfirmation does not skip this prompt.
# Reboots run in fixed batches of RebootBatchSize and wait for a newer guest boot time.
# Discovery and apply default to every VM in the list at once; reboot batching is separate.
.\Start-PatchingGuestOps.ps1 -VMListPath .\vms.txt -RebootBatchSize 2

# Cap apply concurrency without widening the reboot blast radius:
.\Start-PatchingGuestOps.ps1 -VMListPath .\vms.txt -ThrottleLimit 5 -RebootBatchSize 1

# Allow more patch rounds than the default 3 (each round is discovery -> apply -> reboot):
.\Start-PatchingGuestOps.ps1 -VMListPath .\vms.txt -RebootBatchSize 2 -MaxPatchRounds 5

# Run the orchestrator directly, bypassing the launcher:
.\scripts\Invoke-GuestOpsPatchValidation.ps1 -VIServer '<vc1>;<vc2>' -VMName <vm> -SearchOnly -IgnoreVCenterCertificate

# Run through the GUI (needs an STA host; parameters and credentials are entered in a form):
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-PatchingGuestOpsGui.ps1
```

There is no build step, no linter, and no Pester. `Invoke-StaticChecks.ps1` is a monolithic AST/text check, and `Invoke-ModelChecks.ps1` is the offline model behavior check — there is no "run one test" subset.

`.github/workflows/powershell-checks.yml` runs the same four gates on `windows-2022`, each in its
own process and its own step so a failure stops at the gate that reported it. It uses
`shell: powershell` (Windows PowerShell 5.1, not pwsh — 5.1 semantics are the point),
`permissions: contents: read`, and `actions/checkout` pinned to a commit with
`persist-credentials: false`. **PowerCLI is deliberately not installed there**, so the harness
skips itself and the workflow reports that as `SKIPPED` rather than letting an exit 0 read as a
pass; the same is true of the Windows ACL section of `Invoke-GuestWorkspaceChecks.ps1`. Both still
have to be exercised on a Windows machine with PowerCLI.

`Invoke-GuestOpsHarnessChecks.ps1` is the odd one out: it runs the **real** `Start-`/`Test-`/`Complete-VMAgentCycle` against a fake vSphere (stubbed `Get-ExactVM`, `Get-VMHostNameForTransfer` and `Invoke-Curl`, plus hand-built process/file managers). It needs the PowerCLI submodules installed for their .NET types — `GuestProgramSpec`, `GuestFileAttributes`, `NamePasswordAuthentication` — but no vCenter, no VM and no ESXi data plane. Without those types it **skips itself and exits 0**, which is why it lives outside `Invoke-RuntimeChecks.ps1`: that gate has to stay runnable anywhere. It covers what unit tests cannot: that a fleet timeout still downloads `status.json`, that a guest which dropped out of vSphere's process list ends its poll instead of spinning, that every transfer carries `--max-time`, and that vSphere is asked about a process once per round rather than twice.

## Architecture: two planes, runtime scripts, offline model

The hard-won insight (validated empirically, see `spec/spec-patching-guestops.md`) is that **control and data must be split** because .NET Framework on PS 5.1 cannot negotiate the ESXi host's modern TLS:

- **`curl.exe` is always called through `Invoke-Curl`, which forces `--disable` as the first
  argument.** curl otherwise reads `%APPDATA%\_curlrc`, `CURL_HOME/.curlrc` or `~/.curlrc`, and
  whoever wrote one could switch off certificate verification, insert a proxy or swap the CA
  store for an ESXi transfer. Position matters — curl applies the config before the flags that
  follow — so the wrapper is the single place that adds it and no argument list repeats it.
  This is asserted where the program is actually executed (a fake curl that records its
  arguments), not on the argument lists in isolation: `tests/Invoke-RuntimeChecks.ps1` covers
  the wrapper, the GET path and the endpoint probe, `tests/Invoke-GuestOpsHarnessChecks.ps1`
  the PUT path (it needs `VMware.Vim.GuestFileAttributes`). The endpoint probe still omits
  `--fail`, because an HTTP access or method error after a successful handshake is not a trust
  failure.

- **Control plane** — PS 5.1 → SOAP → vCenter:443 → ESXi → VMware Tools → guest. This works on .NET Framework. Carries `StartProgramInGuest`, `ListProcessesInGuest`, and `InitiateFileTransfer{To,From}Guest` (which only *returns* a transfer URL).
- **Data plane** — the actual file bytes go to ESXi:443 over HTTPS. .NET Framework fails the TLS handshake here, so **`curl.exe` (Schannel)** does every byte transfer. curl is a Windows component, not a new binary.

Execution flows through layered runtime scripts plus the offline planning model and tests:

1. **`Start-PatchingGuestOps.ps1`** (root launcher) — prompts for any missing params, runs static + model checks unless `-SkipStaticChecks`, rejects legacy `-InstallSelection` before credential prompts, then splats everything into the orchestrator. `-VIServer` can hold one vCenter or several vCenters separated by semicolons; the launcher normalizes that list and passes through `-VIServerCredential` only when the operator explicitly supplied one. Guest credentials are resolved per VM into a `name -> pscredential` map: one `Get-Credential` prompt per FQDN domain suffix and one per local (no-dot) machine (`Resolve-GuestCredentialMap` + `Get-GuestCredentialGroups`). The VM list therefore holds FQDNs; `Get-ExactVM` resolves each by full FQDN first, then permits a short inventory name only when VMware Tools reports the requested guest FQDN. Missing or mismatched guest hostnames reject that fallback; duplicate inventory matches are rejected. The same lookup is used for discovery, apply and reboot, and **every call must name the vCenter connections of this run** (`Get-ExactVM -Servers`, pinned by `Test-VMLookupsAreScoped` in the static gate) — see "Inventory scope" below. An explicit `-GuestCredential` overrides this for all VMs (non-interactive runs). There are two entry points: this launcher for console runs, and `Start-PatchingGuestOpsGui.ps1` for GUI runs. Users should never have to call the orchestrator directly.
2. **`Start-PatchingGuestOpsGui.ps1`** (optional GUI launcher) — WinForms on PS 5.1, requires an STA host. Collects parameters and credentials in a modal form, saves settings to `%LOCALAPPDATA%\PatchingGuestOps\settings.json` and credentials (DPAPI per key) to `credentials.json`, expands grouped store keys into per-name maps via `Get-GuestCredentialGroups`, then calls the console launcher via `&`. Passes `-PromptProvider`, `-StoredVIServerCredentials` and `-StoredGuestCredentials`; **never** passes `-SelectedUpdateKeys` or `-SkipConfirmation`, as either would end the patch-round loop after the first run. Update group selection is a modal dialog; everything else stays in the console. The VM list is intentionally not persisted.
3. **`scripts/Invoke-GuestOpsPatchValidation.ps1`** (orchestrator, runs on the stepping stone) — resolves one or many VM targets, connects to one or more semicolon-separated vCenters, runs discovery cycles over GuestOps, builds grouped update records, resolves selection from explicit `-SelectedUpdateKeys` or interactive grouped selection, writes a per-VM patch plan, asks for final confirmation, then applies selected groups. vCenter credentials are resolved into `VIServerCredentialMap`: explicit `-VIServerCredential` applies to every vCenter, otherwise prompts are grouped by FQDN domain and failed vCenter logins retry only that vCenter so the operator can enter local credentials. Discovery and apply run **in this process** as one fleet (see "In-process fleet" below), so a run holds a single vCenter session throughout; `Connect-VIServersWithCredentialMap` also reuses a session that is already connected, which is what makes `-KeepConnected` worth setting. Apply-result, fleet, round-decision and reboot-action semantics live in `scripts/OrchestratorRuntime.ps1` and are covered by `tests/Invoke-RuntimeChecks.ps1`; that helper also writes `reboot-actions.json`, `rounds.json` and the summaries. Keep PowerCLI/GuestOps calls and interactive prompts (`Read-Host`) outside it — its only side effects are local artifact writes. `-PatchPlanPath` resumes from a saved `patch-plan.json`: it skips discovery and group selection, shows the saved plan, asks for confirmation unless `-SkipConfirmation` is set, runs apply against the selected updates in the plan, and stays **single-round** (there is no discovery to judge the starting state from, and the saved keys carry a `RevisionNumber` that will not match a later round's groups). After apply, the normal discovery-driven path evaluates reboot targets from both per-VM apply `rebootRequired` and the run's discovery `pendingRebootBefore.isPending`; the `-PatchPlanPath` resume path has no discovery records, so it only uses apply `rebootRequired`. If any VM requires reboot, it shows a separate VM list and requires the operator to type `REBOOT`; `-SkipConfirmation` never skips this reboot prompt, nor the follow-up prompt for `-RebootBatchSize`. Confirmed reboot is initiated inside the guest through GuestOps by running `guest/Request-GuestReboot.ps1`, which takes the guest run guard and then invokes `shutdown.exe /r /t 0 /c "PatchingGuestOps reboot after updates"` while holding it, limited by `-RebootBatchSize`.
4. **`scripts/PatchPlanModel.ps1`** (offline model) — pure planning/reporting logic for update identity validation, default group selection, Failover Cluster skips, per-VM patch plans, summaries, and PlanOnly exit semantics. Keep it free of PowerCLI, GuestOps calls, `Read-Host`, and top-level runtime flow.
5. **`scripts/GuestOpsLib.ps1`** (GuestOps helpers) — shared PowerCLI/GuestOps file transfer and process-run helpers. The guest agent cycle is split into `Start-VMAgentCycle` (upload + `StartProgramInGuest`), `Test-VMAgentCycleComplete` (one `ListProcessesInGuest`) and `Complete-VMAgentCycle` (download + parse). Those three are the whole cycle; the single-shot `Invoke-VMAgentCycle`/`Invoke-GuestAgentRun` that preceded them are gone, along with the needles that were keeping them alive after their last caller disappeared.
6. **`guest/Run-LocalPatch.ps1`** (agent, runs *inside* the guest) — WUA COM only: `Microsoft.Update.Session` → searcher → downloader → installer. Writes `status.json` + `agent.log` to a unique cycle directory (`C:\ProgramData\PatchingGuestOps\<runId>`). **Never reboots** — it only reports `pendingReboot`. `Test-PendingReboot` gates `isPending` on the two servicing flags only — `Component Based Servicing\RebootPending` and `WindowsUpdate\Auto Update\RebootRequired` — because those are what Windows Update sets when a patch it installed still needs a restart. `PendingFileRenameOperations` is detected, filtered to non-blank entries (it is a REG_MULTI_SZ of source/destination pairs and a queued delete has an empty destination), and reported as `advisoryReasons`, but it never gates the prompt on its own: any installer can queue a rename, and it was observed as the only flag set on a fully patched guest with zero applicable updates, offering a reboot no update had asked for. `pendingReasons` names the gating flags that fired; the orchestrator carries them into the reboot target's `rebootReason` so the prompt says which flag it is acting on.
7. **`guest/GuestWorkspace.ps1`** (guard, runs *inside* the guest, **never uploaded** by the bootstrap) — creates the tool directory with a protected DACL and verifies owner, access rules, reparse points and the parent before anything is written to it, then seals it with a one-time token every later guest-side step re-verifies. Executed through `powershell.exe -Command` with an in-memory GZip payload; uploaded beside the agent and the boot-time helper only so *they* can re-check the seal. See "Securing the guest directory before the first upload".
8. **`guest/GuestRunGuard.ps1`** (guard, runs *inside* the guest) — the one-run-per-guest lock and its coordination record; see "One run per guest".
9. **`guest/Request-GuestReboot.ps1`** (runs *inside* the guest, **never uploaded**) — takes the run guard and invokes `shutdown.exe` while holding it.
10. **`guest/Read-BootTime.ps1`** (helper, runs *inside* the guest) — reads `Win32_OperatingSystem.LastBootUpTime` and writes a UTC/ISO 8601 result for the reboot validation gate.

### Inventory scope: which vCenter may answer a lookup

`Get-ExactVM` takes a mandatory `-Servers` scope and passes it to `Get-VM -Server`. Without it
PowerCLI answers from `$global:DefaultVIServers`, so a VM that exists in a vCenter the operator
never named could be discovered, patched and rebooted — the target set would stop matching the
VM list. An empty scope is a programming error and throws; it is never read as "search
everything". The static gate holds every call site to this (`Test-VMLookupsAreScoped`).

The scope is `Connect-VIServersWithCredentialMap(...).Connections`, **not**
`.OpenedConnections`: a session reused from an earlier `-KeepConnected` run is just as much in
scope as one this run opened, while `OpenedConnections` only answers "what may this run tear
down". Both lists come back from the same call for exactly that reason.

Two further rules follow from the scope being real rather than advisory:

- **A failed query is not an empty inventory.** Only an `ObjectNotFound` error may be read as
  "not here", and only for the candidate name being tried, so the FQDN → short-name fallback
  still works. A dropped session, a timeout or a refused login propagates instead of letting a
  differently-named VM win the next candidate.
- **`-Name` is escaped as a literal.** PowerCLI reads it as a wildcard pattern, so a VM called
  `server[1]` would never match itself and `server*literal` would match unrelated guests.
  `WildcardPattern::Escape` keeps the exact comparison — not the pattern — as the decision.

Reboot initiation is the one phase that runs in a child process, and it does not receive the
scope. The parent resolves the VM in its own session first and hands the child **one** vCenter
name (`Get-VMOwningServerName`, read from the object's service URL or PowerCLI `Uid`) plus the
managed object identity (`Get-VMMoRefIdentity`, `Type:Value`). The child logs in to that one
vCenter, re-resolves the name against its own sessions and refuses to proceed unless the
managed object matches (`Assert-VMMatchesExpectedMoRef`) — so a namesake in that inventory
cannot be restarted in its place, and no live manager object is serialized into the job. When
the owning vCenter cannot be determined the VM becomes a failed initiation marked
`RejectedBeforeStart` (nothing was sent), never a reboot through an unconfirmed session.
### In-process fleet: how discovery and apply run

`StartProgramInGuest` returns a process id without waiting, so discovery and apply start the guest
agent on every VM in turn and then poll all of them from **one loop in the orchestrator process**,
against the vCenter session the run already holds. `-ThrottleLimit` bounds how many VMs are in
flight and **defaults to the whole target list**; it costs GuestOps calls rather than one
PowerShell host plus a PowerCLI import per VM, which is what capped the old `Start-Job` model at a
handful of machines. `Start-Job` now survives only in reboot initiation.

**Starts and polls interleave: one start per loop iteration, then every guest already running.**
Draining the queue first looks cheaper — `StartProgramInGuest` returns without waiting — but a
start is still several SOAP round trips plus three file transfers, so at fleet scale the first
guest could be minutes into its work, or finished and gone from vSphere's short-lived process
list, before anything looked at it. The loop also does not sleep while a slot is free and targets
are still waiting: a poll interval spent idle is one the next guest was not started in.

**The clock is read per item, not once per wave.** A single reading taken at the top is already
minutes old by the time a long wave of polls reaches the last entry, so a guest whose budget the
earlier polls consumed would be judged as if no time had passed and its timeout deferred by a
whole wave.

**Discovery and apply have separate budgets.** `-TimeoutMinutes` (180) is the *apply* agent budget:
a WUA install can genuinely take hours. `-DiscoveryTimeoutMinutes` (30) bounds a WUA search, which
takes minutes — the same 180 held a whole discovery phase for three hours when one guest stopped
answering. Both are validated `1..35791394`, the largest value that still fits Int32 once converted
to seconds. The GUI passes neither and uses the defaults.

The item timeout is now exactly the agent budget: the old `+300` silently extended it. The
collection that follows a timeout is bounded separately, by the transfer deadline already on the
cycle handle. **Neither is a hard wall-clock guarantee** — a single SOAP call cannot be cancelled
mid-flight, and the budget is only checked between GuestOps steps — so the real bound is "agent
budget, plus one in-progress call, plus one bounded collection".

`Invoke-InProcessAgentFleet` (`OrchestratorRuntime.ps1`) is the coordinator and takes injected
start/poll/complete scriptblocks, so it is tested offline. Three consequences are load-bearing:

- **Every step is wrapped per VM.** There is no job boundary, so one guest throwing would otherwise
  end the whole phase.
- **Every transfer carries `-TimeoutSeconds`.** `JobTimeoutSeconds` used to bound a hung curl;
  nothing else does now.
- **Every phase checks its ESXi endpoints before starting agents.** `Invoke-GuestAgentFleet`
  resolves ready targets and calls `Assert-GuestTransferEndpoint` once per host before dispatch.
  The curl HEAD probe checks HTTPS at the host root with a 30s deadline, no guest file ticket,
  and no `--fail`: HTTP access/method errors after successful TLS are not trust failures.
  A host that fails its check (certificate, DNS, TCP or the deadline) fails only the VMs on it:
  each becomes its own `StartError` naming the host, the verdict is reused for the rest of the
  phase, and VMs on other hosts proceed. Aborting the phase instead turned one slow host into a
  fleet-wide stop and, in a verification round, discarded the run summary. Inventory/readiness
  failures remain per-VM results too. Credential recovery runs before each target's probe, so
  skipped or aborted accounts never cost a probe. Transfers use the same TLS policy even if a VM
  changes hosts. Verification is on by default; the separate `-IgnoreESXiCertificate` switch
  (also exposed and saved by the GUI) enables `--insecure` centrally in `Invoke-Curl` for that run.
  The orchestrator explicitly assigns `GuestTransferIgnoreCertificate` on every run, independent
  of `IgnoreVCenterCertificate`; boot-time transfers share this scope, reboot jobs use SOAP only.
- **A timed-out item still runs the completion script.** `status.json` is the primary result, the
  job path always downloaded the artifacts even when the process result timed out, and dropping
  them would turn a guest run that actually finished into a reported failure. The timeout error is
  recorded alongside the harvested payload, not instead of it.

Because a fleet starts sequentially, the first VM can finish before the poll loop reaches it and
fall out of vSphere's short-lived process list. `Test-VMAgentCycleComplete` therefore reports an
empty process list as "ended, exit code lost" rather than "still running", and
`New-ApplyResultFromCycle` accepts a terminal `outcome` **plus** a non-empty `finishedAt` as
authoritative when the process result is missing — the same resolution discovery already used.
Both halves are required: the agent saves `status.json` eagerly, so an outcome can be present while
the stage that stamps `finishedAt` never ran. Before either discovery or apply consumes the
artifact, `Complete-VMAgentCycle` requires its `runId` to match the current handle. Missing or
foreign IDs fail the cycle; timestamps alone do not establish ownership. Each cycle uploads
its agent, identity helper and selection into a separate guest directory under the configured
working directory, so later cycles cannot overwrite a still-running agent's files.

Discovery also requires the shared `AgentCompletionConfirmed` verdict even when the process
reported completion. Missing/invalid `finishedAt` cannot be accepted as successful discovery or
turn into `Green`; timeout recovery only accepts an artifact with confirmed completion.

### Securing the guest directory before the first upload

`guest/GuestWorkspace.ps1` runs **inside the guest and is never uploaded**. The orchestrator
reads the trusted local copy, prepends a request object and runs the whole text through
`powershell.exe -NoProfile -NonInteractive -Command` with an in-memory GZip payload. Uploading the guard into the
directory it is meant to be guarding would mean writing a file into an unverified location and
then trusting what came back from it. The requested path travels **base64-encoded as data** and
is decoded inside the guest: a directory name is operator input, and interpolating it into the
command text would make it a place where PowerShell syntax can be written.

Why it exists: the tool directory holds `Run-LocalPatch.ps1`, `UpdateIdentity.ps1`,
`selection.json`, `status.json` and the boot-time helper, and the agent is then started from it.
An ordinary user who can write there replaces the agent between the upload and the start and has
it run under the patching account. So `Assert-GuestWorkspaceReady` replaces the old
`cmd.exe /c mkdir` and must finish before the first transfer — pinned by
`Test-GuestUploadsAreGuarded` in the static gate, and asserted by behaviour (zero uploads, zero
agent starts) in `tests/Invoke-GuestWorkspaceChecks.ps1` and the harness.

`Initialize-GuestWorkspace` creates missing directories and verifies them;
`Assert-GuestWorkspacePath` only verifies. Initialization may migrate an explicitly designated
`LegacyRootPath` left by main's mkdir: an unprotected directory with inherited access rules only.
After rejecting links and unsafe parent permissions, migration takes ownership for Administrators
and sets a protected SYSTEM/Administrators DACL on that root only. It does not delete old artifacts
or reset the coordination lock. Explicit ACLs and protected unsafe directories remain refusals.
Discovery, boot-time reads and the fixed coordination path all prepare their root before use.
Boot-time helpers now live in a protected `.boot-time` subdirectory, avoiding main's old files.

Creation is `Directory.CreateDirectory(path, DirectorySecurity)` with
`SetAccessRuleProtection($true, $false)` so the inherited rules from `C:\ProgramData` — which let
ordinary users create entries — are not copied in. Owner is set to the local Administrators, and
only `S-1-5-18` (SYSTEM) and `S-1-5-32-544` (Administrators) get FullControl, inherited by
children. **Every missing level is created that way in its own right**: letting
`CreateDirectory` make the intermediate levels would give them their parent's inherited
permissions, and being able to write to an intermediate level is enough to move the leaf. The
verify pass runs afterwards regardless — including on a directory another process created in the
same instant, because then this code did not choose the permissions.

What the verify refuses:

- a path that is not an absolute, canonical, non-root local path (settled before `GetFullPath`);
- an owner that is neither SYSTEM nor the local Administrators — an owner can rewrite the DACL
  whenever they like, so a correct DACL right now proves nothing;
- any *allow* ACE granting write, delete, ChangePermissions or TakeOwnership to a SID outside the
  allow-list. Read and execute for ordinary users is fine: this directory is not secret;
- a reparse point on the directory **or any ancestor** — it redirects the whole subtree;
- a parent that lets an untrusted account **replace** the directory (Delete,
  DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership). Creating a *new* entry beside
  it is deliberately not refused, because `C:\ProgramData` grants exactly that to Users, and its
  ACL is never modified here;
- a security descriptor that cannot be read at all. No evidence of safety is a per-VM failure,
  never a reason to carry on.

`-SkipHelperUpload` saves a transfer, not the security check. The boot-time read verifies the
directory on every round, and when the upload is skipped it also verifies the **helper file**
already in the guest (`Assert-GuestWorkspaceFilePath`) — a safe root does not vouch for a file
that was already sitting in it, and that file is a script this tool is about to run.

The channel back is a process exit code and nothing else, so the guest's status table and the
orchestrator's reason table must agree: 10 path, 11 owner, 12 access rule, 13 reparse point,
14 parent, 15 unreadable descriptor, 16 create failed, 17 unexpected, 18 seal refused. An
**unrecognised code, and a lost exit code, both fail the VM** — vSphere forgets exit codes shortly
after a process ends, and "no answer" is the one thing that must never read as success.

#### The seal: one token for the whole cycle

The checks above answer *who may write here*. They cannot answer *is this still the directory we
secured*, because a directory someone else created and permissioned identically passes every one of
them. And the bootstrap is not the last word: between it and the first line the agent runs there
are three more GuestOps calls — the uploads, and the start — each with a gap an administrator on
that guest could act in.

So `Initialize-GuestWorkspace -SealToken` writes the token into `.workspace-seal` inside the
directory **after** it has passed, and every guest-side step afterwards re-reads it through
`Assert-GuestWorkspaceSeal`: the agent before it creates the WUA session (`-WorkspaceSealToken`,
recorded as `workspaceSealVerified` in `status.json` and in the apply result), and the boot-time
helper before it reports a boot time (`exit 3` on a refusal, so a stale `boot-time-<vm>.json`
cannot read as a fresh answer). `Start-VMAgentCycle` and `Invoke-VMGuestBootTimeRead` each mint
their own token with `New-GuestWorkspaceSealToken`; one token spans the bootstrap and the program
started after it, pinned by `Test-GuestWorkspaceSealsSpanTheCycle` in the static gate, because the
harness that exercises the coupling end to end needs PowerCLI types and skips on most machines.

Three properties are load-bearing:

- **The token is identity, the ACL is authority.** Neither is sufficient: a token nobody can forge
  in a directory anyone can write to proves nothing, and a correctly permissioned directory that is
  not the one we sealed is a different directory. So `Assert-GuestWorkspaceSeal` runs the whole
  directory check first and returns *its* verdict when it fails — the operator is told which of the
  two broke, not "seal mismatch" for an ACL problem.
- **The token need not be secret**, which is why it can sit in the directory it seals: forging it
  in a directory that also passes the owner and ACL checks already needs administrator rights.
- **Nothing about a refusal is lenient.** No token supplied to the check, no seal file, an empty
  seal, a seal that differs in case — all `SealRefused`. The one thing that is *not* a refusal is
  an agent invoked without `-WorkspaceSealToken` at all: `workspaceSealVerified` stays `$null`, so
  "not checked" (an older agent, a manual run) never reads as "checked and refused".

In the agent the seal is verified **before the run guard is taken**, so a directory this tool does
not recognise leaves nothing on the guest to reconcile.

### One run per guest: the guest run guard

`guest/GuestRunGuard.ps1` runs inside the guest and holds **one lock per guest**, shared by every
process this tool starts there. Two WUA sessions installing on one machine corrupt each other's
work, and a reboot ordered while an agent is mid-install can leave a half-written update. Nothing
else provides that exclusion — a run id, a cycle directory or a per-account marker are all things
a second run brings its own copy of — so the lock lives at **one fixed path**,
`C:\ProgramData\PatchingGuestOps\.coordination\guest-run.lock`, independent of the run id, the
cycle directory, the account the agent runs as and `-GuestWorkingDirectory`. There is deliberately
**no switch to move it and no switch to ignore it**; the static gate pins both.

The coordination directory is created and verified through `Initialize-GuestWorkspace`, so it gets
the same protected DACL as the tool directory whatever `-GuestWorkingDirectory` was set to. It is
never a cleanup target: `Test-GuestCycleDirectoryRemovable` requires the directory name to be a
generated GUID, and `.coordination` is not one.

The lock is an open handle with `FileShare::None`, and the owner record — run id, process id,
start time, boot time, phase, completion — lives **inside that same file**, so only the holder can
write it. Two facts are kept apart on purpose:

- **The handle** is released by the operating system when the holder dies. That says nothing
  about whether its WUA work finished.
- **The record** says whether the previous run reached a terminal status. `Completed` is written
  only *after* this cycle's terminal `status.json` has been saved — recording it any earlier
  would hand a guest whose result was never written to the next run.

So a crashed agent leaves `Running` behind, and the next run refuses. Status `RebootRequested`
refuses too, until a **strictly newer boot time** proves the guest actually came back; an
unreadable or unrecognised record refuses as well. `Completed`, and an empty file, are the only
states that let the next run proceed — an existing lock file from a finished run never blocks
anything. Nothing is ever cleared by age, by a pid missing from vSphere, or by the controller
exiting.

The agent takes the guard before creating the WUA session and holds it through the terminal
status write. A refusal becomes `guestRunConflict = true` in `status.json` and in the apply
result, and that is **absolute for the rest of the run**: the VM is `Failed`, it is filtered out
of reboot targets (`Select-RebootRequiredApplyResults`) and out of the next round's targets, and
the run cannot exit 0 — even though the refused agent's own process has already ended, which is
exactly what makes it look finished to everything else.

**A refused workspace seal is the same kind of fact and gets the same treatment.**
`Test-IsApplyResultRefused` is the single predicate for "the guest refused this tool" — a run
guard conflict, or a seal that did not verify — and all three places consult it: the reboot
filter, `Get-NextRoundTargetVMNames`, and `Set-PatchRunRefusedStates`. They have to agree, or a
refusal recorded in one place is undone by another. That is not hypothetical: before the predicate
existed, a refused seal was not a next-round exclusion, so round two re-discovered the VM and its
ordinary `Pending` verdict **overwrote the refusal from round one**. A seal that was never checked
(`$null` — no token supplied, an older agent) is deliberately not a refusal.

`Set-PatchRunRefusedStates` exists because the state map is built from **discovery**, and
discovery is exactly what still succeeded in the window a refusal happens in: another run took the
guest, or a reboot was requested, or the directory was replaced, between discovery and apply. So a
refused VM read as `Pending` — "still has selectable updates" — which points whoever reads
`summary.md` at updates to install rather than at a guest that has to be reconciled. The exit code
was already right (`Pending` is not in the all-green allow-list); the description was not. It does
not overwrite `Excluded`, which is a decision about a machine somebody understood.

#### Four kinds of refusal, one of which waits

The refusal also carries a **kind** (`guestRunConflictKind`), because the four are not the same
problem and the phase acts differently on one of them:

| Kind | What it means | What the run does |
| --- | --- | --- |
| `Held` | The lock file itself could not be opened: another run of this tool is working on the guest **right now**. | Records it. Waiting and then starting is precisely the overlap the guard exists to prevent. |
| `Unconfirmed` | The record says `Running`: the previous holder died without reporting completion. | Records it. Nothing changes without a person looking at Windows Update on that guest. |
| `RebootPending` | The record says `RebootRequested` and no newer boot time has arrived yet. | **Waits once and tries again inside the same phase.** |
| `Unreadable` | The record cannot be interpreted, or carries a status this tool does not know. | Records it. Same as `Unconfirmed`. |

`RebootPending` is the only kind that **reconciles itself** — the marker clears the moment the
boot time is newer — so failing the VM immediately would report a guest that was seconds from
being available. `Invoke-GuestAgentFleet` therefore re-dispatches exactly those VMs after
`$script:GuestRunConflictRetryWaitSeconds` (180s), once
(`$script:GuestRunConflictRetryLimit` = 1), merging the second attempt's results over the first
(`Select-RetryableGuestRunConflicts`, `Merge-RetriedFleetResults`). The budget is counted down
through the recursive call, so a retry that hits the same conflict cannot renew it.

Both halves of that are deliberate. **Neither the wait nor the retry is a CLI parameter**: this is
a courtesy for an overlap measured in seconds, not a scheduling mechanism, and the phase is
in-process, so a longer wait blocks every other VM in the fleet. A guest still restarting after
the retry is recorded as it is and the run exits 1 — this tool has no way to know how long that
guest's restart legitimately takes, and a conflict staying absolute is what keeps it out of the
reboot phase and the next round.

Reboot is the other holder. `shutdown.exe` is no longer started directly over GuestOps; instead
`guest/Request-GuestReboot.ps1` (concatenated with the workspace guard and the run guard, and run
through an in-memory compressed command) takes the guard, writes `RebootRequested`, and invokes `shutdown.exe`
itself — so a restart can never be ordered on a guest whose agent is still installing. The order
of writes is load-bearing: the marker goes down **before** `shutdown.exe` is invoked, and is
rolled back **only** when this process is certain it never got that far. Once invoked, an
ambiguous result keeps the marker — a second shutdown is never authorised by not knowing. The
request's exit code is read back over a short wait (20s): `0` sent, `20` refused by the guard
(nothing sent, `GuestRunConflict`), `21` never invoked (nothing sent), `22` invoked but reported
a failure (ambiguous, treated as sent), and **no answer at all is "sent"** — a guest that is
actually restarting stops answering.

**Reconciling an abandoned run is a manual procedure, by design.** There is no override switch.
On the guest, check Windows Update (`Get-WindowsUpdateLog`, the update history, and whether a
reboot is pending) and confirm no `Run-LocalPatch.ps1` is running. Once you are satisfied the
previous run is genuinely over, delete
`C:\ProgramData\PatchingGuestOps\.coordination\guest-run.lock`. The next run then starts
clean. An automatic reaper is out of scope for the same reason age-based cycle cleanup is: a run
this tool cannot prove is finished is one it must not overrule.

### Guest-side cleanup: the only destructive operation

`Remove-CompletedVMAgentCycleArtifacts` deletes the cycle directory inside the guest, recursively,
through the single call `FileManager.DeleteDirectoryInGuest`. The static gate pins it to exactly
one call site, requires it to stay inside that function, and forbids reaching it from a `finally`.
The asymmetry is deliberate: a wrong delete is unrecoverable customer data, a wrong retain is a
leftover directory, so everything is an allow-list and every failure answers "retain".

Removal requires, together: `AgentCompletionConfirmed`, an `AgentResult` that says `Completed`,
**both** artifacts downloaded during *this* collection (`StatusDownloaded`/`LogDownloaded`), and
both local files actually present. Those last two are separate questions - a transfer can exit 0
and leave nothing on disk, and a status carried over from an earlier read says nothing about what
is on the guest now. A process result vSphere has already forgotten is not evidence of completion.

The path is validated through `Test-GuestDirectoryCanonical`, shared with the orchestrator's
preflight so both agree on what "canonical" means. Absoluteness is settled **before**
`GetFullPath` - that call resolves a relative path against the stepping stone's current directory
and would hand back something absolute that never was. UNC paths, drive roots, the working
directory itself and anything not directly under it are refused; the directory's name must equal
the run id, compared ordinally, and the run id must have the generated GUID `N` form. Comparing
the immediate **parent** rather than a string prefix is what makes a sibling like
`PatchingGuestOpsOld` unreachable.

**Retention is the normal outcome whenever the process result was lost, not an error.** When the
poll finds an empty process list but a terminal `status.json`, `Test-VMAgentCycleComplete` caches
the status on the handle and returns `Completed = $false`. That blocks cleanup twice over: the
process never reported completion, and because the status is already on the handle
`Complete-VMAgentCycle` skips the download, so `StatusDownloaded` stays false. At fleet scale this
is common - a guest that finishes before the poll loop reaches it falls out of vSphere's
short-lived process list - so those cycle directories stay on the guest **permanently**. There is
no reaper: age-based cleanup is deliberately out of scope, because a directory this tool cannot
prove is finished is one it must not touch. Operators should expect `C:\ProgramData\PatchingGuestOps`
to accumulate directories on busy fleets and clear them out of band.

Cleanup runs after the downloads and the parse, never from a `finally`: a cycle that failed half
way through is exactly the one whose guest-side files someone will want to read. A refused delete
is a `Warning` that never touches the WUA result, and a `Retained` directory says why in a warning
with the VM and run id, even when discovery suppresses step messages. Collected discovery and
apply records preserve `cleanupStatus`/`cleanupReason`, including failures, because this is the outcome this
feature's own failure modes produce.

`-GuestWorkingDirectory` is validated at the orchestrator's preflight through the same function.
A path written with forward slashes works for the mkdir, every upload, the agent and the boot-time
helper, so without that check cleanup would fail silently on every VM in every round, forever.

### Guest credential recovery

A guest that rejects a login does not end the run and is never retried with the same password.
`scripts/CredentialRecovery.ps1` holds one session-local context for the whole run, grouped the
same way the startup prompts are: one account per FQDN domain suffix, one per no-dot machine.
`Resolve-GuestCredentialForTarget` validates a replacement through
`AuthManager.ValidateCredentialsInGuest` **before** anything is retried, and the decision contract
(`Retry`/`SkipAccount`/`Abort`) is identical for the console prompt and the GUI dialog.

Recovery is wired into start, poll, artifact collection, boot-time read and reboot submission.
Two rules are load-bearing there:

- **Reboot submission may be re-sent only for a rejection the guest made before `shutdown.exe`
  started**, once, and only with a credential that is actually different from the one refused.
  Validation succeeding is not permission to re-send: `ValidateCredentialsInGuest` and
  `StartProgramInGuest` are different calls, so the guest can accept the credential at validation
  and still have refused the reboot with it. The child job classifies and never prompts;
  `Invoke-VMGuestReboot` marks the failures it raises before its one guest-touching call, so an
  inventory or `GetView` timeout is not mistaken for a command that may already be running.
- **Only an operator decision counts as a refusal.** `Test-CredentialRefusalErrorKind` accepts
  `CredentialsSkipped`/`CredentialsAborted` and nothing else. A validation attempt that merely
  *failed* - VMware Tools down mid-reboot is the ordinary case, and `Assert-VMReadyForGuestOps`
  throws on exactly that - keeps its transient handling and still reaches the operator prompt.
  Treating it as a refusal would record a guest that rebooted correctly as a credential failure.

A skipped account becomes `Failed` with a reason, is filtered out of discovery, apply, reboot and
the next round, and makes the run exit 1. `-SkipConfirmation` and a missing prompt provider never
open a dialog; the result is an explicit failure instead.

The GUI keeps the working credential map separate from the map destined for disk, because they
genuinely diverge: a replacement entered with Remember unticked serves the run while
`credentials.json` keeps the password already there. An explicit refusal outranks the startup
preference for the rest of the run. A corrected vCenter password is written under
`vcenter:target:<name>`, never the shared domain key, so the other servers behind that suffix do
not inherit a credential nobody validated against them. **`Remember` defaults to unticked**
(`Test-CredentialDialogDefaultsToNotRemember` in the static gate, since exercising a WinForms
dialog needs an STA host and a desktop the gates cannot assume): writing a password to disk is a
decision the operator makes, not one they have to notice and undo. DPAPI binds `credentials.json`
to one Windows account on one machine and nothing more, so anything running as that account can
read it back. Unticking never deletes a password already in the store — that would be silent loss
of something somebody saved on purpose — and the save stays atomic.

### Update policy: structural, and honest about what it cannot classify

The old rule read the title and the localised category names, so the *same package* was selected
on an English guest and skipped on a German or Polish one, and any title containing the word
"Security" was selected whatever it actually was. `Get-UpdatePolicyDecision` now decides on
structured WUA metadata only, in this order:

1. `UpdateType` `Driver` (or the raw enum `2`) → **Exclude**.
2. `BrowseOnly = $true` → **Exclude**. This is WUA's own "do not offer automatically" flag and the
   closest thing to a structured preview marker. It is *not* a promise that every preview package
   carries it — see below.
3. KB `890830` (MSRT) or KB `2267602` (Defender security intelligence) → **Include**, by KB id
   rather than title.
4. Classification GUID `SecurityUpdates` (`0fa1201d-…`), `CriticalUpdates` (`e6cf1350-…`) or
   `UpdateRollups` (`28bc880e-…`) → **Include**. Braces and case do not matter.
5. `MsrcSeverity` `Critical` or `Important` → **Include**.
6. Anything else → **`NeedsReview`**.

`NeedsReview` is the deliberate cost, stated rather than hidden: **there is no way to keep the
English title heuristics and still call the result structural.** The old `cumulative` regex cannot
be replaced by including the `Updates`, `FeaturePacks` or `Upgrades` classifications wholesale —
that would sweep in feature updates and upgrades, which is worse than asking. So a package that
cannot be classified from its metadata waits for an operator instead of being guessed at in
either direction. Two situations end there: metadata that is *missing* (no classification GUIDs,
no severity, no `BrowseOnly` — including every plan saved before this change, which stays
readable), and metadata that is present but simply is not a classification this tool installs on
its own.

Consequences, all load-bearing:

- **A `NeedsReview` group is not preselected, and not silently ignored either.** It gives the VM
  its own state, `NeedsReview`, which is neither `Green` nor `Pending` and **cannot produce exit
  0**. A real `Pending` group outranks it.
- **Only an operator resolves it.** Ticking it installs it; leaving it unticked *after an
  interactive selection* refuses it and the identity goes into the deselected set, so the VM ends
  `GreenByOperatorChoice` and later rounds do not ask again (matched on the bare `updateId` too,
  since the revision changes). A box left unticked by a run that never opened the selection —
  `-SelectedUpdateKeys` or `-SkipConfirmation` — is **not** a decision: that run ends incomplete
  with exit 1. There is no separate dialog for reviews; the existing group list marks them
  `[NEEDS REVIEW]` with the reason, through `Get-UpdateGroupDisplayTitle`, shared by the console
  list and the GUI dialog so the two cannot describe a group differently.
- **Contradictory metadata for one identity key is `NeedsReview`, not first-wins.** Several VMs
  report the same package; if their `categoryIds`, `browseOnly`, `msrcSeverity` or `updateType`
  disagree, taking the first record would make the answer depend on the order of the VM list, and
  OR-ing them would silently pick the more permissive one.
- **Defender signatures still never decide whether a VM is finished** (see below), and that
  exemption covers the review count too. Defender *platform* and *engine* updates are ordinary
  packages: the word "Defender" in a title excludes nothing.

Discovery therefore writes `categoryIds` (normalised GUIDs) and `browseOnly` (`true`/`false`/
`null` — a missing answer is never `false`) alongside the existing `categories` display names, and
both travel through grouping, the plan and the saved-plan reader.

### Patch rounds

A run repeats **discovery → group selection → plan → confirm → apply → reboot** until every VM is
green or the operator stops. There is no separate verification phase: round N+1's discovery *is*
the verification of round N.

- **Green** means "no group the default policy would select (`selectedByDefault`) still applies to
  this VM" — not "no updates at all". Drivers, preview and optional updates never go away, so
  counting them would keep the loop running forever. Groups the operator unticked accumulate in a
  deselected set and stop blocking green (`GreenByOperatorChoice`); that set is matched on the bare
  `updateId` too, because the identity key carries `RevisionNumber` and a revised package would
  otherwise resurrect a group that was already refused. A Failover Cluster VM is `Excluded`: never
  green, never a target.
- **Another round only starts when every rebooted VM confirmed a newer boot time**
  (`Test-RebootActionsAllConfirmed`). Re-discovering a half-booted guest would either fail or
  describe a state nobody should act on.
- **A restart the VM requires and did not get is `PendingReboot`, and the run does not exit 0.**
  `Set-PatchRunPendingRebootStates` marks every reboot target whose restart was not confirmed —
  refused by the operator, unverified, forced, timed out or a failed initiation. Deliberately not
  `Failed`: the installation itself may well have succeeded, and saying otherwise sends whoever
  reads the summary looking for an install problem that is not there. `Test-RebootActionsSuccessful`
  no longer tolerates an operator skip either, which is what makes the `-PatchPlanPath` resume path
  agree with the round loop.
- **A confirmed restart is verified by a fresh discovery, never by the boot time alone.** A newer
  boot time says the guest came back; it says nothing about what updates remain. So a confirmed
  reboot target becomes a target of the next round and that round's discovery assigns its verdict.
  The pre-apply discovery must never supply it: that discovery describes the machine *before* the
  restart, and `pendingRebootBefore` from it is not a statement about the state afterwards.
- **The next round's targets are a deduplicated union**, `Get-NextRoundTargetVMNames`: VMs whose
  apply completed safely, plus VMs whose restart was confirmed — including `NoSelectedUpdates`
  ones. Either half alone loses a machine. Apply alone loses the VM that had nothing to install
  but a pending reboot: it restarts and is never looked at again, so the pre-restart verdict
  stands, which is exactly how a run could report a green fleet it had never re-checked. Reboot
  alone loses the VM that installed updates and needed no restart. A `guestRunConflict` VM is in
  neither half.
- Round 1 always reaches group selection even when nothing is preselected, so the operator can
  still tick something the default policy skipped.
- Round ≥ 2 always uses the interactive selection, so anything that cannot answer a prompt must
  stop before reaching one. `Get-PatchRoundDecision` therefore ends the loop after round one for
  both `-SelectedUpdateKeys` (its keys carry a `RevisionNumber` that will not appear in a later
  round's groups) and `-SkipConfirmation` (nobody is there to choose CONTINUE/FINISH). Falling
  through instead is not a hang but something worse: `Read-Host` on a closed stdin returns an
  empty string, `Read-UpdateGroupSelection` reads that as "accept", and the run would silently
  install the default policy rather than what the operator asked for.
- `-MaxPatchRounds` (default 3) counts **apply** rounds; round `MaxPatchRounds + 1` still runs its
  verification discovery and then stops.
- Each round writes to `<run>\round-NN\` with the existing artifact names; the run root gets
  `rounds.json` and an aggregate `summary.md`. This applies to single-round runs too.
- **Every collection artifact is a JSON array at the root**, for 0, 1 and 2+ records alike:
  `discovery.json`, `patch-plan.json` (both write sites), `apply-results.json`,
  `reboot-actions.json`, `rounds.json`. Piping a collection into `ConvertTo-Json` unrolls it, so
  zero records wrote nothing at all and one record wrote a bare object - two shapes the resume
  path could not anticipate. Pass the whole collection: `ConvertTo-Json -InputObject @($records)`.
  Single-document JSON (`selection.json`, the settings and credential stores) is deliberately not
  an array. When asserting on these files in a test, assign before wrapping: `ConvertFrom-Json`
  emits an array as a **single** pipeline object on 5.1, so `@($raw | ConvertFrom-Json).Count`
  counts the array rather than its elements.
- **Exit code** is 0 only when every VM ends `Green`/`GreenByOperatorChoice`/`Excluded` in the
  state map **merged across rounds**, every apply succeeded and every reboot was confirmed.
  `Test-PatchRunAllGreen` holds an **allow-list** of those three states, not a deny-list of
  `Pending`/`Failed`: every state added later — `NeedsReview`, `PendingReboot` — would otherwise
  have passed it by default, and so would a typo. It is also given the run's expected VM names,
  because a VM with no verdict at all is not a success: that is the shape a VM takes when it fell
  out of the round loop without anyone recording why. `Excluded` is an acceptable ending but means
  "outside the scope of patching", not "patched". The
  merge matters: later rounds only target VMs that were still pending, so a VM that failed
  discovery in round 1 is absent from round 2 and reading the verdict off the last round alone
  would let it vanish. `-SearchOnly`, `-PlanOnly` and `-PatchPlanPath` keep their existing
  single-pass exit semantics and are not subject to the all-green rule.

### Reboot batches and boot-time gate

The reboot phase is deliberately separate from apply concurrency: `-ThrottleLimit` is throughput,
`-RebootBatchSize` is blast radius. When `-RebootBatchSize` is not supplied the operator is asked
for it after approving the reboot (Enter = 1); like the `REBOOT` prompt, `-SkipConfirmation` does
not skip that question, so a non-interactive run passes the value on the command line. The phase
keeps the target order and splits reboot targets into fixed batches of `RebootBatchSize`. Within one batch,
baseline `Win32_OperatingSystem.LastBootUpTime` values are read through GuestOps, `shutdown.exe`
is initiated in parallel, and the next batch is blocked until every VM with a baseline reports a
strictly newer boot time. The boot-time helper runs inside the VM; no WinRM, PSRemoting,
`Invoke-VMScript`, or `Copy-VMGuestFile` is used.

The helper and its JSON output use **one stable path per guest** (`Read-BootTime-<vm>.ps1`,
`boot-time-<vm>.json`), overwritten on every attempt — per-attempt names would leave hundreds of
files per VM per run behind on production servers. Because the output path is reused,
`Invoke-VMGuestBootTimeRead` checks the query's **exit code** and not just its completion: a helper
that died would otherwise leave the previous attempt's JSON in place and have it read back as a
fresh boot time.

Boot-time reads run **in the orchestrator process**, sequentially over the batch, against the
vCenter connection the run already holds — as do discovery and apply now; only reboot initiation
still uses `Start-Job`. A child job would re-import PowerCLI and log in to vCenter once per VM per
polling round, so sequential in-process reads finish a batch sooner than parallel jobs and leave no
extra vCenter sessions behind; PowerCLI has no supported way to hand a live session to a child
process. Two consequences are load-bearing: the read loop must catch per VM (no job boundary to
contain a throw), and `Set-PowerCLIConfiguration -WebOperationTimeoutSeconds 60` replaces the job
timeout as the bound on a hung SOAP call, because the read's own budget is only checked between
GuestOps steps.

The gate is **level-triggered**: `LastBootUpTime` is durable state, so a skipped poll delays
detection but never loses it — polling cadence cannot cause a false positive or a false negative.
That is what makes the call-count reductions safe. The helper and working directory are uploaded
**once per VM** (`-SkipHelperUpload` on later reads; any failed read re-arms the upload, so a guest
that lost the file self-heals), and observation waits out a **grace period** (`GraceSeconds`,
default 90s, coordinator-level, not a CLI parameter) before the first read, since a guest that was
just told to shut down cannot report a newer boot time yet. The grace sits outside the timeout
budget and is paid once per batch, not again on `RETRY`.

The helper also emits `uptimeSeconds` from the same CIM snapshot as the boot time, recorded as
`uptimeBaselineSeconds`/`uptimeObservedSeconds`. This is **diagnostic only** — the gate still
decides on boot time alone. It exists for the one false-negative vector the gate cannot see: a
guest clock stepped backwards during boot (NTP correcting a fast clock) can make the post-reboot
`LastBootUpTime` older than the baseline, and uptime is what explains that in the artifact.

`-RebootTimeoutMinutes` defaults to 30 minutes. `-PollSeconds` controls polling cadence, not the
timeout. GuestOps/VMware Tools errors during observation are transient until timeout. At a baseline
shortfall or timeout the operator must choose `RETRY`, `CONTINUE`, or `ABORT`; `-SkipConfirmation`
does not bypass these prompts. `RETRY` observes against the original baseline without sending
`shutdown.exe` again. A failed initiation is never automatically retried and offers only
`CONTINUE`/`ABORT`. `CONTINUE` records an unverified/forced result and `ABORT` records remaining
targets as `NotStartedAfterAbort`; either outcome makes the final exit code `1`.

A reboot job that `Invoke-ThrottledJobs` stopped at its deadline, or whose output it could not
receive, is **not** a failed initiation: it reports `ErrorKind = 'JobResultLost'`, because the
child may have sent `shutdown.exe` before it went quiet. The coordinator observes it through the
boot-time gate exactly like an ambiguous transport failure, so it holds the next batch instead of
offering a `CONTINUE` that would restart the next batch alongside it. Only `Start-Job` itself
failing (`JobNotStarted`, `RejectedBeforeStart`) provably sent nothing. The cost is deliberate: a
job that died before the guest call waits out `-RebootTimeoutMinutes` before the operator is asked.

Each `reboot-actions.json` record retains the existing reboot fields and adds the batch number,
the target sequence (records are ordered by `batchNumber, sequence` because `Sort-Object` is not
stable on 5.1), the baseline/observed uptime pair,
baseline/observed boot times, validation status, wait/timeout data, operator decision, and the
latest error. `summary.md` separates confirmed, unverified/forced, timeout, initiation-error,
skipped, and not-started-after-abort restarts. A confirmed boot-time gate proves OS reboot and
GuestOps/VMware Tools availability only; application readiness remains out of scope.

### The contract between orchestrator and agent

The agent and orchestrator are coupled through **`status.json`** (`schemaVersion: phase0b-1`, with a required matching `runId` for orchestrated cycles) and the selected-update command-line arguments. The agent saves `status.json` eagerly (right after start, and after each stage) so a crash still leaves a trace. The orchestrator parses it defensively via `Get-ObjectPropertyValue` and treats it — not the GuestOps process exit code — as the primary result, because vSphere keeps the exit code for only a short window after the process ends.

The agent rejects a non-search run when it currently detects Failover Cluster, including selection from an older saved plan. Apply results preserve the agent's `roleFlags` even on process failures, so the newly detected cluster is also excluded from reboot. WUA search must return `ResultCode = 2` before an empty result is accepted or any updates are downloaded. Other codes fail the cycle; `searchResult.warnings` retains WUA warning messages, HRESULTs and contexts. `Invoke-SafetyRegressionChecks.ps1`, called by the runtime gate, exercises these paths and VM-name collisions with offline doubles.

Canonical update identity is **`UpdateID|RevisionNumber`**. Discovery writes `updateId`, `revisionNumber`, and `identityKey` for each update when WUA exposes them. The grouped flow selects update groups by `-SelectedUpdateKeys`; `-InstallSelection` is intentionally rejected. During apply, the orchestrator writes the selected `UpdateID|RevisionNumber` keys to `selection.json`, uploads it next to the guest agent, and starts the agent with `-SelectionPath`. The agent still has a legacy `-SelectedUpdateKeys` CLI path for compatibility (`-SelectionPath` is the primary apply contract), but the orchestrator no longer depends on comma-joined selected-key payloads.

### Selection drift: the approved subset that is still on offer

WUA revises packages between the plan and the apply, so an approved `UpdateID|RevisionNumber` can
simply not be in the search result any more. That used to `throw`, which discarded **every** still
available approved update along with the one that had moved.

The agent now takes the **exact intersection** of the approved keys with what WUA offers right
now, and reports the difference. Two rules make that safe:

- **No substitution.** A revision the operator never approved is never installed in place of one
  that vanished. `B|2` appearing where `B|1` was approved leaves `B|1` missing and `B|2`
  untouched; it will show up as an ordinary applicable update, keep the VM `Pending`, and go
  through a fresh plan and a normal selection.
- **Nothing is reported as installed that was not.** `status.json` and the apply result carry
  `missingUpdateKeys`, `selectionDrift` and `requiresVerification`; the warning is logged and the
  status saved **before** the download, so a crash mid-install still leaves the trace that this
  run installed less than was approved.

An empty intersection downloads and installs nothing and reports `NoSelectedUpdates` with the
drift flags set. A genuinely empty search result keeps its own `NoApplicableUpdates` — there was
nothing to drift. A refused EULA is a real error and drops only its own update, exactly as before.

**"Requires verification" is not the same fact as "an apply failed", and the phase result keeps
them apart** (`HasHardFailure` / `RequiresVerification`). Folding them together would either hide
the drift or report a working install as broken. Only the hard failure is sticky across rounds:

- In a normal run the missing keys become an **outstanding verification** per VM
  (`Add-OutstandingVerificationKeys`). A later round's discovery resolves each key that is no
  longer in that VM's update list (`Resolve-OutstandingVerificationKeys`, matched on the **exact**
  identity key, and a failed discovery resolves nothing). The run may then finish successfully with
  the warning retained in the artifacts. Anything still outstanding at the end is exit 1 with the
  keys named — a green fleet where less was installed than approved is not a clean success.
- **`-PatchPlanPath` cannot resolve drift at all**: there is no fresh discovery to establish that
  the missing update is no longer needed. It reports the keys and exits 1. It deliberately does not
  attempt a second install — that would need a fresh plan and a normal operator selection.

Subtle point inside the agent: it maintains `selectedSearchIndexes`, mapping a *selected-collection* index back to its *search-collection* index, so per-update download/install results land on the correct `$status.updates[$searchIndex]`.

`guest/UpdateIdentity.ps1` is uploaded with the guest agent and is also dot-sourced by the offline model, so identity formatting and missing-field semantics stay shared across producer and consumer.

## Hard constraints (enforced by Invoke-StaticChecks.ps1)

These are not style preferences — the static check **fails the build** on them, and several encode real bugs already fixed. Treat them as load-bearing:

- **Forbidden commands** (AST scan): `Invoke-Command`, `New-PSSession`, `Enter-PSSession`, `Invoke-VMScript`, `Copy-VMGuestFile`. The whole project exists to avoid these.
- **No `ForEach-Object -Parallel`** anywhere — that's PS 7.0+, target runtime is 5.1. Future multi-VM parallelism must use a 5.1-compatible mechanism (runspace pool / `Start-Job`), never `-Parallel`.
- **No `$PID` or `$matches` as variable names** — they are automatic variables; shadowing them causes confusing runtime behavior. Use `$processId`/`$agentProcessId`/`$exactMatches` etc.
- **Agent must not reference `$x.HResult` directly** — WUA COM objects can lack `HResult` under StrictMode. Go through `Get-OptionalPropertyValue` / `Format-HResult`.
- **Orchestrator must not use `$kbArticleIds.Count`** — `ConvertFrom-Json` collapses a single KB id to a scalar under StrictMode. Wrap in `@(...)` first.
- **Orchestrator apply must pass selected updates by `UpdateID|RevisionNumber` keys through `-SelectedUpdateKeys`** — never by display index. Guest argument values are joined into one comma-delimited argument to avoid PowerShell binding extra tokens as positional `SearchCriteria`.
- **No orphaned `elseif`/`else`** — detaching one from its `if` while restructuring a long flow is *not* a parse error: PowerShell reads it as a call to a command named `elseif`. All three gates stay green and the run dies at runtime with `CommandNotFoundException`, which the top-level catch turns into a bare exit 1. `Assert-NoOrphanedBranchKeyword` scans for it.
- **No `return` at script scope in the orchestrator below the `-PatchPlanPath` branch** — `Test-ScriptTailHasReturn` walks the AST of every top-level statement from that branch onward and rejects a `return` that is not inside a nested function or scriptblock, and `Test-ScriptExitsWithComputedCode` requires the file's last statement to be `exit $scriptExitCode`. A `return` there ends the script: `finally` still runs, but `Write-PatchRunSummary`, the all-green evaluation and the final exit do not, so the process leaves on a stale `$LASTEXITCODE` and a failed run reports success with no run-level artifacts. Use `break`/assignments in the round loop; a `return` inside a function or an injected scriptblock is fine. The top-level `catch` has the same failure mode: under the script's `Stop` preference a bare `Write-Error` re-throws, so it must stay `Write-Error ... -ErrorAction Continue` (behavior check N2 in `tests/Invoke-AuditFollowupChecks.ps1` runs that catch body).
- Static checks protect hard constraints and architectural boundaries. Behavior belongs in `Invoke-ModelChecks.ps1` and `Invoke-RuntimeChecks.ps1`; do not add a text needle when a small offline behavior test can cover the rule.

Runtime and model scripts run under `Set-StrictMode -Version 2.0` + `$ErrorActionPreference = 'Stop'`. That is *why* the defensive property-access helpers exist — keep using them rather than touching COM/JSON properties directly.

## Repo hygiene

- **`out/`, `spec/`, and `docs/superpowers/` are gitignored.** `spec/` and `docs/superpowers/` are local context (project decisions, plans) — read them, but **never commit or push them**.
- **Never put environment identifiers in committed code**: no company names, hostnames, usernames, local test paths, or other target/test-environment data. (The gitignored `out/` artifacts may contain real machine names — that's why `out/` is ignored.)
- Stage specific files; do **not** `git add -A`. Commit messages in English.

## Direction (multi-VM, per Ustalenia_przeplywu_pracy.txt)

The single-VM index-selection mode is validation scaffolding, not the final product. The target tool separates stages: **discovery → group update selection → per-VM plan → final confirm → apply**. Notable decisions:

- Update selection becomes a **checkbox group view** keyed technically on **`UpdateID` + `RevisionNumber`** (KB/title shown to humans but not authoritative).
- **Failover Cluster *membership* → hard skip** the VM ("update manually one by one") — not the
  mere presence of the role. SQL/Exchange become high-risk role flags; Domain Controller and IIS
  are also detected as role flags. None of these auto-skip. See "Cluster membership" below.

### Cluster membership: presence of the role is not membership

`ClusSvc` exists on every server with the Failover Clustering feature installed, including one
that was never joined to a cluster and one that was evicted from it. Reading that as membership
excluded healthy standalone servers from patching **forever**, since the service never goes away.

`Get-LocalClusterMembership` asks the question that has an answer: `GetNodeClusterState` from
`clusapi.dll`, P/Invoked in the guest. `roleFlags` gains `clusterMembership`
(`Member`/`NotMember`/`Unknown`) and `clusterMembershipReason`, and `failoverCluster` keeps its
meaning — "this VM must not be patched automatically" — but is now set **only** by a confirmed
`Member`.

The mapping, and why each half matters:

| State | Membership |
|---|---|
| 0, 1 | `NotMember` — the feature may be installed, the node is not in a cluster |
| 3, 19 | `Member` |
| anything else, or a failed call | `Unknown` |

- **The function's return code and the state value are separate facts.** A non-zero return means
  the state was never written, so reading it would be reading an uninitialised variable. A read
  error is `Unknown`, never `NotMember`.
- **No service, queried successfully → `NotMember`.** That is a fact, not a failure to read one.
- **Service present but `clusapi.dll` missing, a bitness mismatch or a blocked P/Invoke →
  `Unknown`.**
- **A stopped `ClusSvc` decides nothing.** A node can be a cluster member with the service stopped
  for maintenance, which is exactly when someone might try to patch it.

`Unknown` is `Failed`, deliberately **not** `Excluded`: an exclusion is a decision about a machine
somebody understood, and this one is unresolved. It blocks apply (the agent throws, and re-checks
on every apply whatever a saved plan recorded) and blocks reboot
(`Select-RebootRequiredApplyResults` filters it out, from both the discovery record and the apply
result). A confirmed `Excluded` still permits exit 0; the run summary calls that section "outside
the scope of patching, not patched" rather than counting those VMs as done. A discovery record
written before this field existed has no `clusterMembership` at all and keeps its old behaviour,
so an upgrade does not turn every VM into a failure on its first run. Automatic cluster patching
remains out of scope.
- **The default policy is structural and language-independent.** It reads the WUA classification
  GUIDs, `MsrcSeverity`, `UpdateType`, `BrowseOnly` and the KB id — never the title and never the
  category *names*, both of which are localised. `Get-UpdatePolicyDecision` answers
  `Include`/`Exclude`/`NeedsReview` with a reason, and `Get-DefaultUpdateSelection` preselects only
  on `Include`. See "Update policy" below for the full rule and for what was given up to get here.
- **Microsoft Defender Antivirus security intelligence updates (KB2267602) are selected like anything else, but they never decide whether a VM is finished.** `Get-VMPatchCompletionStates` skips them in both the pending and the deselected count (`Test-IsDefenderDefinitionUpdate`), so installing one does not make a VM green and failing to install one does not keep it pending. WUA republishes them within hours under a new `UpdateID|RevisionNumber`, so counting them would mean round N+1 discovers a different group and a fully patched fleet never converges - every run would burn `MaxPatchRounds` and exit 1. The match is on the KB id, because the title is localised; the English title is a backstop when WUA returns no KB ids. Defender platform and engine updates are ordinary updates and are counted normally, as are SCEP and legacy Windows Defender definitions.
```

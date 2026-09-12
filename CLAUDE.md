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

`Invoke-GuestOpsHarnessChecks.ps1` is the odd one out: it runs the **real** `Start-`/`Test-`/`Complete-VMAgentCycle` against a fake vSphere (stubbed `Get-ExactVM`, `Get-VMHostNameForTransfer` and `Invoke-Curl`, plus hand-built process/file managers). It needs the PowerCLI submodules installed for their .NET types — `GuestProgramSpec`, `GuestFileAttributes`, `NamePasswordAuthentication` — but no vCenter, no VM and no ESXi data plane. Without those types it **skips itself and exits 0**, which is why it lives outside `Invoke-RuntimeChecks.ps1`: that gate has to stay runnable anywhere. It covers what unit tests cannot: that a fleet timeout still downloads `status.json`, that a guest which dropped out of vSphere's process list ends its poll instead of spinning, that every transfer carries `--max-time`, and that vSphere is asked about a process once per round rather than twice.

## Architecture: two planes, runtime scripts, offline model

The hard-won insight (validated empirically, see `spec/spec-patching-guestops.md`) is that **control and data must be split** because .NET Framework on PS 5.1 cannot negotiate the ESXi host's modern TLS:

- **Control plane** — PS 5.1 → SOAP → vCenter:443 → ESXi → VMware Tools → guest. This works on .NET Framework. Carries `StartProgramInGuest`, `ListProcessesInGuest`, and `InitiateFileTransfer{To,From}Guest` (which only *returns* a transfer URL).
- **Data plane** — the actual file bytes go to ESXi:443 over HTTPS. .NET Framework fails the TLS handshake here, so **`curl.exe` (Schannel)** does every byte transfer. curl is a Windows component, not a new binary.

Execution flows through layered runtime scripts plus the offline planning model and tests:

1. **`Start-PatchingGuestOps.ps1`** (root launcher) — prompts for any missing params, runs static + model checks unless `-SkipStaticChecks`, rejects legacy `-InstallSelection` before credential prompts, then splats everything into the orchestrator. `-VIServer` can hold one vCenter or several vCenters separated by semicolons; the launcher normalizes that list and passes through `-VIServerCredential` only when the operator explicitly supplied one. Guest credentials are resolved per VM into a `name -> pscredential` map: one `Get-Credential` prompt per FQDN domain suffix and one per local (no-dot) machine (`Resolve-GuestCredentialMap` + `Get-GuestCredentialGroups`). The VM list therefore holds FQDNs; `Get-ExactVM` resolves each by full FQDN first, then permits a short inventory name only when VMware Tools reports the requested guest FQDN. Missing or mismatched guest hostnames reject that fallback; duplicate inventory matches are rejected. The same lookup is used for discovery, apply and reboot. An explicit `-GuestCredential` overrides this for all VMs (non-interactive runs). There are two entry points: this launcher for console runs, and `Start-PatchingGuestOpsGui.ps1` for GUI runs. Users should never have to call the orchestrator directly.
2. **`Start-PatchingGuestOpsGui.ps1`** (optional GUI launcher) — WinForms on PS 5.1, requires an STA host. Collects parameters and credentials in a modal form, saves settings to `%LOCALAPPDATA%\PatchingGuestOps\settings.json` and credentials (DPAPI per key) to `credentials.json`, expands grouped store keys into per-name maps via `Get-GuestCredentialGroups`, then calls the console launcher via `&`. Passes `-PromptProvider`, `-StoredVIServerCredentials` and `-StoredGuestCredentials`; **never** passes `-SelectedUpdateKeys` or `-SkipConfirmation`, as either would end the patch-round loop after the first run. Update group selection is a modal dialog; everything else stays in the console. The VM list is intentionally not persisted.
3. **`scripts/Invoke-GuestOpsPatchValidation.ps1`** (orchestrator, runs on the stepping stone) — resolves one or many VM targets, connects to one or more semicolon-separated vCenters, runs discovery cycles over GuestOps, builds grouped update records, resolves selection from explicit `-SelectedUpdateKeys` or interactive grouped selection, writes a per-VM patch plan, asks for final confirmation, then applies selected groups. vCenter credentials are resolved into `VIServerCredentialMap`: explicit `-VIServerCredential` applies to every vCenter, otherwise prompts are grouped by FQDN domain and failed vCenter logins retry only that vCenter so the operator can enter local credentials. Discovery and apply run **in this process** as one fleet (see "In-process fleet" below), so a run holds a single vCenter session throughout; `Connect-VIServersWithCredentialMap` also reuses a session that is already connected, which is what makes `-KeepConnected` worth setting. Apply-result, fleet, round-decision and reboot-action semantics live in `scripts/OrchestratorRuntime.ps1` and are covered by `tests/Invoke-RuntimeChecks.ps1`; that helper also writes `reboot-actions.json`, `rounds.json` and the summaries. Keep PowerCLI/GuestOps calls and interactive prompts (`Read-Host`) outside it — its only side effects are local artifact writes. `-PatchPlanPath` resumes from a saved `patch-plan.json`: it skips discovery and group selection, shows the saved plan, asks for confirmation unless `-SkipConfirmation` is set, runs apply against the selected updates in the plan, and stays **single-round** (there is no discovery to judge the starting state from, and the saved keys carry a `RevisionNumber` that will not match a later round's groups). After apply, the normal discovery-driven path evaluates reboot targets from both per-VM apply `rebootRequired` and the run's discovery `pendingRebootBefore.isPending`; the `-PatchPlanPath` resume path has no discovery records, so it only uses apply `rebootRequired`. If any VM requires reboot, it shows a separate VM list and requires the operator to type `REBOOT`; `-SkipConfirmation` never skips this reboot prompt, nor the follow-up prompt for `-RebootBatchSize`. Confirmed reboot is initiated inside the guest through GuestOps by starting `shutdown.exe /r /t 0 /c "PatchingGuestOps reboot after updates"`, limited by `-RebootBatchSize`.
4. **`scripts/PatchPlanModel.ps1`** (offline model) — pure planning/reporting logic for update identity validation, default group selection, Failover Cluster skips, per-VM patch plans, summaries, and PlanOnly exit semantics. Keep it free of PowerCLI, GuestOps calls, `Read-Host`, and top-level runtime flow.
5. **`scripts/GuestOpsLib.ps1`** (GuestOps helpers) — shared PowerCLI/GuestOps file transfer and process-run helpers. The guest agent cycle is split into `Start-VMAgentCycle` (upload + `StartProgramInGuest`), `Test-VMAgentCycleComplete` (one `ListProcessesInGuest`) and `Complete-VMAgentCycle` (download + parse). Those three are the whole cycle; the single-shot `Invoke-VMAgentCycle`/`Invoke-GuestAgentRun` that preceded them are gone, along with the needles that were keeping them alive after their last caller disappeared.
6. **`guest/Run-LocalPatch.ps1`** (agent, runs *inside* the guest) — WUA COM only: `Microsoft.Update.Session` → searcher → downloader → installer. Writes `status.json` + `agent.log` to a unique cycle directory (`C:\ProgramData\PatchingGuestOps\<runId>`). **Never reboots** — it only reports `pendingReboot`.
7. **`guest/Read-BootTime.ps1`** (helper, runs *inside* the guest) — reads `Win32_OperatingSystem.LastBootUpTime` and writes a UTC/ISO 8601 result for the reboot validation gate.

### In-process fleet: how discovery and apply run

`StartProgramInGuest` returns a process id without waiting, so discovery and apply start the guest
agent on every VM in turn and then poll all of them from **one loop in the orchestrator process**,
against the vCenter session the run already holds. `-ThrottleLimit` bounds how many VMs are in
flight and **defaults to the whole target list**; it costs GuestOps calls rather than one
PowerShell host plus a PowerCLI import per VM, which is what capped the old `Start-Job` model at a
handful of machines. `Start-Job` now survives only in reboot initiation.

`Invoke-InProcessAgentFleet` (`OrchestratorRuntime.ps1`) is the coordinator and takes injected
start/poll/complete scriptblocks, so it is tested offline. Three consequences are load-bearing:

- **Every step is wrapped per VM.** There is no job boundary, so one guest throwing would otherwise
  end the whole phase.
- **Every transfer carries `-TimeoutSeconds`.** `JobTimeoutSeconds` used to bound a hung curl;
  nothing else does now.
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
  (`Test-RebootActionsAllConfirmed`, stricter than `Test-RebootActionsSuccessful`, which tolerates
  an operator skip). Re-discovering a half-booted guest would either fail or describe a state
  nobody should act on.
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
- **Exit code** is 0 only when every VM ends `Green`/`GreenByOperatorChoice`/`Excluded` in the
  state map **merged across rounds**, every apply succeeded and every reboot was confirmed. The
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
- **No `return` at script scope in the orchestrator below the `-PatchPlanPath` branch** — `Test-ScriptTailHasReturn` walks the AST of every top-level statement from that branch onward and rejects a `return` that is not inside a nested function or scriptblock, and `Test-ScriptExitsWithComputedCode` requires the file's last statement to be `exit $scriptExitCode`. A `return` there ends the script: `finally` still runs, but `Write-PatchRunSummary`, the all-green evaluation and the final exit do not, so the process leaves on a stale `$LASTEXITCODE` and a failed run reports success with no run-level artifacts. Use `break`/assignments in the round loop; a `return` inside a function or an injected scriptblock is fine.
- Static checks protect hard constraints and architectural boundaries. Behavior belongs in `Invoke-ModelChecks.ps1` and `Invoke-RuntimeChecks.ps1`; do not add a text needle when a small offline behavior test can cover the rule.

Runtime and model scripts run under `Set-StrictMode -Version 2.0` + `$ErrorActionPreference = 'Stop'`. That is *why* the defensive property-access helpers exist — keep using them rather than touching COM/JSON properties directly.

## Repo hygiene

- **`out/`, `spec/`, and `docs/superpowers/` are gitignored.** `spec/` and `docs/superpowers/` are local context (project decisions, plans) — read them, but **never commit or push them**.
- **Never put environment identifiers in committed code**: no company names, hostnames, usernames, local test paths, or other target/test-environment data. (The gitignored `out/` artifacts may contain real machine names — that's why `out/` is ignored.)
- Stage specific files; do **not** `git add -A`. Commit messages in English.

## Direction (multi-VM, per Ustalenia_przeplywu_pracy.txt)

The single-VM index-selection mode is validation scaffolding, not the final product. The target tool separates stages: **discovery → group update selection → per-VM plan → final confirm → apply**. Notable decisions:

- Update selection becomes a **checkbox group view** keyed technically on **`UpdateID` + `RevisionNumber`** (KB/title shown to humans but not authoritative).
- **Failover Cluster detected → hard skip** the VM ("update manually one by one"). SQL/Exchange become high-risk role flags; Domain Controller and IIS are also detected as role flags. None of these auto-skip.
- Default policy first uses structured WUA fields (`MsrcSeverity`, `Type`) when available, then falls back to title/category matching. It preselects critical/important software updates and cumulative/security/critical/rollup + MSRT; it skips driver, preview, feature, and optional updates.
- **Microsoft Defender Antivirus security intelligence updates (KB2267602) are selected like anything else, but they never decide whether a VM is finished.** `Get-VMPatchCompletionStates` skips them in both the pending and the deselected count (`Test-IsDefenderDefinitionUpdate`), so installing one does not make a VM green and failing to install one does not keep it pending. WUA republishes them within hours under a new `UpdateID|RevisionNumber`, so counting them would mean round N+1 discovers a different group and a fully patched fleet never converges - every run would burn `MaxPatchRounds` and exit 1. The match is on the KB id, because the title is localised; the English title is a backstop when WUA returns no KB ids. Defender platform and engine updates are ordinary updates and are counted normally, as are SCEP and legacy Windows Defender definitions.
```

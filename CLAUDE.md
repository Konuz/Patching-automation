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

# Post-apply reboot prompt is automatic when any VM reports rebootRequired=true.
# The operator must type REBOOT; -SkipConfirmation does not skip this prompt.
.\Start-PatchingGuestOps.ps1 -VMListPath .\vms.txt -ThrottleLimit 2

# Run the orchestrator directly, bypassing the launcher:
.\scripts\Invoke-GuestOpsPatchValidation.ps1 -VIServer <vc> -VMName <vm> -SearchOnly -IgnoreVCenterCertificate
```

There is no build step, no linter, and no Pester. `Invoke-StaticChecks.ps1` is a monolithic AST/text check, and `Invoke-ModelChecks.ps1` is the offline model behavior check — there is no "run one test" subset.

## Architecture: two planes, runtime scripts, offline model

The hard-won insight (validated empirically, see `spec/spec-patching-guestops.md`) is that **control and data must be split** because .NET Framework on PS 5.1 cannot negotiate the ESXi host's modern TLS:

- **Control plane** — PS 5.1 → SOAP → vCenter:443 → ESXi → VMware Tools → guest. This works on .NET Framework. Carries `StartProgramInGuest`, `ListProcessesInGuest`, and `InitiateFileTransfer{To,From}Guest` (which only *returns* a transfer URL).
- **Data plane** — the actual file bytes go to ESXi:443 over HTTPS. .NET Framework fails the TLS handshake here, so **`curl.exe` (Schannel)** does every byte transfer. curl is a Windows component, not a new binary.

Execution flows through layered runtime scripts plus the offline planning model and tests:

1. **`Start-PatchingGuestOps.ps1`** (root launcher) — prompts for any missing params, runs static + model checks unless `-SkipStaticChecks`, rejects legacy `-InstallSelection` before credential prompts, then splats everything into the orchestrator. Guest credentials are resolved per VM into a `name -> pscredential` map: one `Get-Credential` prompt per FQDN domain suffix and one per local (no-dot) machine (`Resolve-GuestCredentialMap` + `Get-GuestCredentialGroups`). The VM list therefore holds FQDNs; `Get-ExactVM` resolves each by short name first, then full FQDN. An explicit `-GuestCredential` overrides this for all VMs (non-interactive runs). This is the single entry point; users should never have to call the orchestrator directly.
2. **`scripts/Invoke-GuestOpsPatchValidation.ps1`** (orchestrator, runs on the stepping stone) — resolves one or many VM targets, runs discovery cycles over GuestOps, builds grouped update records, resolves selection from explicit `-SelectedUpdateKeys` or interactive grouped selection, writes a per-VM patch plan, asks for final confirmation, then applies selected groups. With `-ThrottleLimit > 1`, child jobs reconnect to vCenter and dot-source GuestOps helpers independently. Throttling, apply-result, and reboot-action semantics live in `scripts/OrchestratorRuntime.ps1` and are covered by `tests/Invoke-RuntimeChecks.ps1`; that helper also writes the `reboot-actions.json` artifact and appends the reboot sections to `summary.md`. Keep PowerCLI/GuestOps calls and interactive prompts (`Read-Host`) outside it — its only side effects are local artifact writes. `-PatchPlanPath` resumes from a saved `patch-plan.json`: it skips discovery and group selection, shows the saved plan, asks for confirmation unless `-SkipConfirmation` is set, and runs apply against the selected updates in the plan. After apply, the orchestrator evaluates per-VM `rebootRequired` from the apply result. If any VM requires reboot, it shows a separate VM list and requires the operator to type `REBOOT`; `-SkipConfirmation` never skips this reboot prompt. Confirmed reboot is initiated inside the guest through GuestOps by starting `shutdown.exe /r /t 0 /c "PatchingGuestOps reboot after updates"`, limited by the existing `-ThrottleLimit`. The script records `reboot-actions.json` and appends reboot sections to `summary.md`, but it does not wait for shutdown, boot, VMware Tools, or application readiness after reboot.
3. **`scripts/PatchPlanModel.ps1`** (offline model) — pure planning/reporting logic for update identity validation, default group selection, Failover Cluster skips, per-VM patch plans, summaries, and PlanOnly exit semantics. Keep it free of PowerCLI, GuestOps calls, `Read-Host`, and top-level runtime flow.
4. **`scripts/GuestOpsLib.ps1`** (GuestOps helpers) — shared PowerCLI/GuestOps file transfer and process-run helpers used by direct and throttled apply/discovery cycles.
5. **`guest/Run-LocalPatch.ps1`** (agent, runs *inside* the guest) — WUA COM only: `Microsoft.Update.Session` → searcher → downloader → installer. Writes `status.json` + `agent.log` to the working directory (`C:\ProgramData\PatchingGuestOps`). **Never reboots** — it only reports `pendingReboot`.

### The contract between orchestrator and agent

The agent and orchestrator are coupled through **`status.json`** (`schemaVersion: phase0b-1`) and the selected-update command-line arguments. The agent saves `status.json` eagerly (right after start, and after each stage) so a crash still leaves a trace. The orchestrator parses it defensively via `Get-ObjectPropertyValue` and treats it — not the GuestOps process exit code — as the primary result, because vSphere keeps the exit code for only a short window after the process ends.

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
```

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Automation for patching Windows Server **without WinRM**, driven entirely over the **vSphere Guest Operations** channel. WinRM/PSRemoting is assumed hard-blocked in the target environment, so the usual `Invoke-Command`/PSSession install path is dead. The runtime is the customer stepping stone: **Windows PowerShell 5.1 only** (no PS7, no rights to install binaries).

The committed code is the **Phase 0b validator** — single-VM, proves the WUA search → download → install path works over GuestOps. The next milestone (multi-VM) is described in `Ustalenia_przeplywu_pracy.txt`.

## Commands

```powershell
# Static checks — the only automated test gate. Run after EVERY change to the .ps1 scripts.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-StaticChecks.ps1

# Full run via the central launcher (prompts for vCenter/VM/credentials; runs static checks first).
.\Start-PatchingGuestOps.ps1

# Dry run — WUA search only, no download/install:
.\Start-PatchingGuestOps.ps1 -SearchOnly

# Non-interactive update selection (skip the Read-Host prompt): "1,2,3" or "A" for all:
.\Start-PatchingGuestOps.ps1 -InstallSelection 'A'

# Skip the pre-run static checks (e.g. when iterating against a live VM):
.\Start-PatchingGuestOps.ps1 -SkipStaticChecks

# Run the orchestrator directly, bypassing the launcher:
.\scripts\Invoke-GuestOpsPatchValidation.ps1 -VIServer <vc> -VMName <vm> -SearchOnly -IgnoreVCenterCertificate
```

There is no build step, no linter, and no Pester. `Invoke-StaticChecks.ps1` is a single monolithic test (AST + text assertions) — there is no "run one test" subset.

## Architecture: two planes, three scripts

The hard-won insight (validated empirically, see `spec/spec-patching-guestops.md`) is that **control and data must be split** because .NET Framework on PS 5.1 cannot negotiate the ESXi host's modern TLS:

- **Control plane** — PS 5.1 → SOAP → vCenter:443 → ESXi → VMware Tools → guest. This works on .NET Framework. Carries `StartProgramInGuest`, `ListProcessesInGuest`, and `InitiateFileTransfer{To,From}Guest` (which only *returns* a transfer URL).
- **Data plane** — the actual file bytes go to ESXi:443 over HTTPS. .NET Framework fails the TLS handshake here, so **`curl.exe` (Schannel)** does every byte transfer. curl is a Windows component, not a new binary.

Execution flows through three layered scripts plus the test:

1. **`Start-PatchingGuestOps.ps1`** (root launcher) — prompts for any missing params, runs static checks unless `-SkipStaticChecks`, then splats everything into the orchestrator. This is the single entry point; users should never have to call the orchestrator directly.
2. **`scripts/Invoke-GuestOpsPatchValidation.ps1`** (orchestrator, runs on the stepping stone) — PowerCLI connect → preflight (`PoweredOn` + `guestToolsRunning`) → `mkdir` in guest → upload agent via curl PUT → start agent via `StartProgramInGuest` → poll `ListProcessesInGuest` → download `status.json` + `agent.log` via curl → parse and print a summary. **Two-pass design:** it always runs a `-SearchOnly` pass first; if updates exist and the caller didn't ask for search-only, it shows the list, resolves a selection (interactive `Read-UpdateSelection` or `-InstallSelection`), maps the chosen positions to stable `UpdateID`s, and runs a second install pass with `-SelectedUpdateIds`. Selection is keyed on identity (not position), so a WUA re-ordering between the search and install passes cannot install the wrong update.
3. **`guest/Run-LocalPatch.ps1`** (agent, runs *inside* the guest) — WUA COM only: `Microsoft.Update.Session` → searcher → downloader → installer. Writes `status.json` + `agent.log` to the working directory (`C:\ProgramData\PatchingGuestOps`). **Never reboots** — it only reports `pendingReboot`.

### The contract between orchestrator and agent

The agent and orchestrator are coupled only through **`status.json`** (`schemaVersion: phase0b-1`). The agent saves it eagerly (right after start, and after each stage) so a crash still leaves a trace. The orchestrator parses it defensively via `Get-ObjectPropertyValue` and treats it — not the GuestOps process exit code — as the primary result, because vSphere keeps the exit code for only a short window after the process ends.

Subtle point inside the agent: it maintains `selectedSearchIndexes`, mapping a *selected-collection* index back to its *search-collection* index, so per-update download/install results land on the correct `$status.updates[$searchIndex]`.

## Hard constraints (enforced by Invoke-StaticChecks.ps1)

These are not style preferences — the static check **fails the build** on them, and several encode real bugs already fixed. Treat them as load-bearing:

- **Forbidden commands** (AST scan): `Invoke-Command`, `New-PSSession`, `Enter-PSSession`, `Invoke-VMScript`, `Copy-VMGuestFile`. The whole project exists to avoid these.
- **No `ForEach-Object -Parallel`** anywhere — that's PS 7.0+, target runtime is 5.1. Future multi-VM parallelism must use a 5.1-compatible mechanism (runspace pool / `Start-Job`), never `-Parallel`.
- **No `$PID` as a variable name** — it's an automatic variable; shadowing it broke process-id handling. Use `$processId`/`$agentProcessId` etc.
- **Agent must not reference `$x.HResult` directly** — WUA COM objects can lack `HResult` under StrictMode. Go through `Get-OptionalPropertyValue` / `Format-HResult`.
- **Orchestrator must not use `$kbArticleIds.Count`** — `ConvertFrom-Json` collapses a single KB id to a scalar under StrictMode. Wrap in `@(...)` first.
- **Orchestrator must pass selected updates by `UpdateID`, joined into one `-SelectedUpdateIds` argument** — never appended per element (PowerShell would bind them as positional `SearchCriteria`). The agent selects by `$update.Identity.UpdateID`, so the wire contract is identity-based, not positional.
- Plus **required-text needles**: the check asserts that key WUA/GuestOps calls and UI strings are *present*. This means a refactor that renames or removes one of those strings will fail static checks even when the logic is correct. After any edit, re-run the static check and preserve the asserted call sites.

All three scripts run under `Set-StrictMode -Version 2.0` + `$ErrorActionPreference = 'Stop'`. That is *why* the defensive property-access helpers exist — keep using them rather than touching COM/JSON properties directly.

## Repo hygiene

- **`out/`, `spec/`, and `docs/superpowers/` are gitignored.** `spec/` and `docs/superpowers/` are local context (project decisions, plans) — read them, but **never commit or push them**.
- **Never put environment identifiers in committed code**: no company names, hostnames, usernames, local test paths, or other target/test-environment data. (The gitignored `out/` artifacts may contain real machine names — that's why `out/` is ignored.)
- Stage specific files; do **not** `git add -A`. Commit messages in English.

## Direction (multi-VM, per Ustalenia_przeplywu_pracy.txt)

The single-VM index-selection mode is validation scaffolding, not the final product. The target tool separates stages: **discovery → group update selection → per-VM plan → final confirm → apply**. Notable decisions:

- Update selection becomes a **checkbox group view** keyed technically on **`UpdateID` + `RevisionNumber`** (KB/title shown to humans but not authoritative).
- **Failover Cluster detected → hard skip** the VM ("update manually one by one"). SQL/Exchange become high-risk role flags, not auto-skips.
- Default policy preselects cumulative/security/critical/rollup + MSRT; skips preview/drivers/feature/optional updates.
```

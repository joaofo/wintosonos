# WinToSonos Working-Project Hardening Plan

> For Hermes: Use subagent-driven-development skill to implement this plan task-by-task.

Goal: Make WinToSonos install and launch reliably on real Windows user machines (including non-admin installs), and add CI guardrails for PowerShell quality.

Architecture: Keep the project as a pure PowerShell app, but harden script path resolution, startup shortcut behavior, and icon loading. Add a lightweight GitHub Actions workflow to catch syntax/lint problems automatically.

Tech Stack: PowerShell 5.1+/7, Windows Forms notify icon, GitHub Actions, PSScriptAnalyzer.

---

### Task 1: Make launcher location-aware

Objective: Ensure start-wintosonos.ps1 can launch the app from any install path without requiring Program Files defaults.

Files:
- Modify: `scripts/start-wintosonos.ps1`

Implementation:
1. Add logic to derive install root from script location when `-InstallDir` is omitted.
2. Resolve and validate `app/WinToSonos.ps1` using that resolved path.
3. Keep existing behavior when `-InstallDir` is explicitly provided.

Verification:
- Script still constructs a valid `appScript` path.
- Existing shortcuts that only call `start-wintosonos.ps1` still work.

Commit message:
- `fix: make launcher resolve install directory automatically`

### Task 2: Harden startup shortcut arguments

Objective: Ensure tray-app startup toggle and installer-generated shortcuts launch correctly for custom install directories.

Files:
- Modify: `app/WinToSonos.ps1`
- Modify: `scripts/install-wintosonos.ps1`

Implementation:
1. Pass `-InstallDir` explicitly in shortcut arguments where applicable.
2. Quote paths safely to handle spaces.
3. Keep Start menu, desktop, and startup shortcuts behavior consistent.

Verification:
- All shortcut creation points include robust arguments.

Commit message:
- `fix: pass install dir explicitly in shortcut launch args`

### Task 3: Make tray icon loading reliable

Objective: Prevent runtime failure from unsupported icon property and provide fallback icon behavior.

Files:
- Modify: `app/WinToSonos.ps1`

Implementation:
1. Replace direct use of unsupported icon members with a helper that attempts SndVol icon extraction.
2. Add fallback to a known SystemIcons value.
3. Log fallback path decisions.

Verification:
- Notify icon assignment always receives a valid icon object.

Commit message:
- `fix: add robust tray icon fallback`

### Task 4: Improve default install path for non-admin users

Objective: Make one-line install work without admin rights by default.

Files:
- Modify: `scripts/install-wintosonos.ps1`
- Modify: `README.md`

Implementation:
1. Change default install dir to a per-user path under LOCALAPPDATA.
2. Update README examples and file-overview wording if needed.
3. Clarify how to install to Program Files explicitly.

Verification:
- Installer defaults no longer require elevation.
- Docs match actual default behavior.

Commit message:
- `feat: default installer to per-user location`

### Task 5: Add PowerShell CI linting

Objective: Add automated checks so script issues are caught before regressions reach main.

Files:
- Create: `.github/workflows/powershell-ci.yml`

Implementation:
1. Add workflow triggered on push/pull_request.
2. Run on `windows-latest` with PowerShell.
3. Install and run PSScriptAnalyzer against `app/*.ps1` and `scripts/*.ps1`.

Verification:
- Workflow YAML validates and executes on GitHub.

Commit message:
- `ci: add powershell lint workflow`

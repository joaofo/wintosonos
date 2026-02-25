# WinToSonos

WinToSonos is now a **self-contained Windows PowerShell solution** that runs as a tray/taskbar app with a speaker icon.

## Install from GitHub (PowerShell `iwr`)

```powershell
iwr https://raw.githubusercontent.com/joaofo/wintosonos/main/scripts/install-wintosonos.ps1 -UseBasicParsing | iex
```

The default one-liner installs WinToSonos, creates a Start menu shortcut, and launches the tray app immediately.

## What this solution now provides

- No Python runtime required.
- A PowerShell tray app (`app/WinToSonos.ps1`) that appears in the Windows taskbar notification area.
- Speaker-style icon and menu with:
  - Open Sonos Web
  - Open log folder
  - Run at startup (toggle)
  - About
  - Exit
- Installer that downloads the repository zip directly from GitHub.
- Installer output that confirms WinToSonos is available in the Start menu.

## Common install examples

Install to the default folder (also launches WinToSonos):

```powershell
.\scripts\install-wintosonos.ps1
```

Install and create desktop shortcut:

```powershell
.\scripts\install-wintosonos.ps1 -CreateDesktopShortcut
```

Install and auto-start on user login:

```powershell
.\scripts\install-wintosonos.ps1 -StartAtLogin
```

Install without launching after setup:

```powershell
.\scripts\install-wintosonos.ps1 -SkipLaunchAfterInstall
```

Install to a custom path:

```powershell
.\scripts\install-wintosonos.ps1 -InstallDir "C:\Tools\WinToSonos"
```

## If script execution is disabled

If your system blocks scripts, PowerShell may show an error like:

```text
WinToSonos.ps1 cannot be loaded because running scripts is disabled on this system.
```

The installer fails fast with instructions. To enable scripts for your user:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Then run the installer again.

For policy details, see: https://go.microsoft.com/fwlink/?LinkID=135170

## Run at startup toggle

From the tray icon menu, use **Run at startup** to enable or disable launching WinToSonos when you sign in.

## Is a restart required?

- **Windows restart:** Not required.
- **If you changed execution policy:** close/reopen PowerShell and run install/test again.
- **To verify quickly:**

```powershell
Get-ExecutionPolicy -List
.\scripts\test-wintosonos.ps1
```


## Test and debug

If WinToSonos does not start correctly, use this quick checklist:

1. Validate the install and shortcuts:

```powershell
.\scripts\test-wintosonos.ps1
```

2. Start the app in debug mode (foreground process):

```powershell
.\scripts\start-wintosonos.ps1 -DebugMode
```

3. Run full diagnostics and attempt a debug launch:

```powershell
.\scripts\test-wintosonos.ps1 -StartApp -DebugStart
```

4. Inspect logs:

```powershell
Get-Content "$env:LOCALAPPDATA\WinToSonos\wintosonos.log" -Tail 100
```

### Common issues

- **Scripts disabled**: run `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned` and retry.
- **Start menu shortcut missing**: re-run installer.
- **Startup toggle not persisting**: verify `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\WinToSonos.lnk` exists after enabling **Run at startup**.

## File overview

- `app/WinToSonos.ps1`: tray/taskbar PowerShell app.
- `scripts/start-wintosonos.ps1`: starts the app hidden in the background (or foreground with `-DebugMode`).
- `scripts/test-wintosonos.ps1`: diagnostics helper to validate install, shortcuts, policies, and logs.
- `scripts/install-wintosonos.ps1`: GitHub-downloading installer and shortcut setup.

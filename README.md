# WinToSonos

WinToSonos is now a **self-contained Windows PowerShell solution** that runs as a tray/taskbar app with a speaker icon.

## Install from GitHub (PowerShell `iwr`)

```powershell
iwr https://raw.githubusercontent.com/joaofo/wintosonos/main/scripts/install-wintosonos.ps1 -UseBasicParsing | iex
```

## What this solution now provides

- No Python runtime required.
- A PowerShell tray app (`app/WinToSonos.ps1`) that appears in the Windows taskbar notification area.
- Speaker-style icon and menu with:
  - Open Sonos Web
  - Open log folder
  - About
  - Exit
- Installer that downloads the repository zip directly from GitHub.

## Common install examples

Install to the default folder:

```powershell
.\scripts\install-wintosonos.ps1
```

Install and create desktop shortcut:

```powershell
.\scripts\install-wintosonos.ps1 -CreateDesktopShortcut
```

Install, auto-start on user login, and launch immediately:

```powershell
.\scripts\install-wintosonos.ps1 -StartAtLogin -LaunchAfterInstall
```

Install to a custom path:

```powershell
.\scripts\install-wintosonos.ps1 -InstallDir "C:\Tools\WinToSonos"
```

## File overview

- `app/WinToSonos.ps1`: tray/taskbar PowerShell app.
- `scripts/start-wintosonos.ps1`: starts the app hidden in the background.
- `scripts/install-wintosonos.ps1`: GitHub-downloading installer and shortcut setup.

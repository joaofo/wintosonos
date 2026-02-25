# WinToSonos

WinToSonos is packaged in this repository and can be installed on Windows with a PowerShell bootstrap command.

## Install (PowerShell `iwr`)

```powershell
iwr https://raw.githubusercontent.com/joaofo/wintosonos/main/scripts/install-wintosonos.ps1 -useb | iex
```

## What the installer does

- Downloads this repository as a zip archive from GitHub.
- Extracts it into `%ProgramFiles%\WinToSonos` by default.
- Optionally creates a Desktop shortcut when requested.

## Optional installer parameters

When running the script directly you can customize behavior:

```powershell
.\scripts\install-wintosonos.ps1 -InstallDir "C:\Tools\WinToSonos" -CreateDesktopShortcut
```

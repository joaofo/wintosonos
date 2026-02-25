# WinToSonos

WinToSonos can be installed with PowerShell. The installer is now **self-contained first**: it prefers local bundle files and only downloads when needed.

## Install options

### 1) Bootstrap from web (simple)

```powershell
iwr https://raw.githubusercontent.com/joaofo/wintosonos/main/scripts/install-wintosonos.ps1 -useb | iex
```

### 2) Self-contained/offline install (no external download)

```powershell
git clone https://github.com/joaofo/wintosonos.git
cd .\wintosonos
.\scripts\install-wintosonos.ps1 -SourceMode Bundle
```

## Installer behavior

- `SourceMode Auto` (default): use local bundle if available, otherwise download zip from GitHub.
- `SourceMode Bundle`: require local source (no network download path).
- `SourceMode Download`: always download zip from GitHub.

## Parameters

```powershell
.\scripts\install-wintosonos.ps1 `
  -InstallDir "C:\Tools\WinToSonos" `
  -CreateDesktopShortcut `
  -SourceMode Auto `
  -LocalSourcePath "C:\path\to\wintosonos"
```

## Self-contained packaging note

To avoid any runtime web dependency, distribute this repository as a zip or preloaded folder and run the installer with `-SourceMode Bundle`.

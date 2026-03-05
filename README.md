# WinToSonos

WinToSonos redirects Windows system audio to a Sonos speaker you choose on your local network, then lets you stop redirection when you are done.

## Mission

- Pick a Sonos speaker on your LAN.
- Redirect current Windows output audio to that speaker.
- Stop redirection cleanly from the tray app.

## Quick install (PowerShell)

```powershell
iwr https://raw.githubusercontent.com/joaofo/wintosonos/main/scripts/install-wintosonos.ps1 -UseBasicParsing | iex
```

Default install path:

```text
%LOCALAPPDATA%\Programs\WinToSonos
```

## Prerequisites

- Windows 10/11
- Sonos speaker on the same local network
- Python 3.10+ available on PATH (`py` launcher or `python` command) for audio redirect runtime bootstrap

`Select speaker...` discovery works locally on LAN even without Python.
WinToSonos creates a local virtual environment on first redirect start and installs runtime dependencies automatically.

## How to use

1. Launch WinToSonos from Start menu.
2. Click the tray icon.
3. Use `Select speaker...` to discover Sonos speakers on your LAN and pick one from the list (or enter a local speaker IP manually).
4. Click `Start audio redirect`.
5. When finished, click `Stop audio redirect`.

### Tray menu actions

- `Select speaker...` discovers Sonos speakers on your local network, lists them for quick selection, and saves your preferred speaker.
- `Start audio redirect` starts local audio capture and sends playback to selected Sonos.
- `Stop audio redirect` stops Sonos playback, restores the previous Sonos source when available, and terminates local streaming. If the speaker has already switched away from the WinToSonos stream, stop exits safely without interrupting current playback. If the saved previous source is itself the WinToSonos stream (for example after restarting redirect), restore is skipped to avoid leaving Sonos on a stale local stream URL.
- `Run at startup` toggles launching WinToSonos at Windows sign-in.

## CLI scripts

You can also run directly:

```powershell
# Start redirect (explicit IP)
.\scripts\start-audio-redirect.ps1 -SpeakerIp 192.168.1.50

# Stop redirect
.\scripts\stop-audio-redirect.ps1

# Discover Sonos speakers (JSON)
.\scripts\list-sonos-speakers.ps1
```

Backend CLI also supports speaker-friendly selection (resolved from discovery of local-network Sonos IPv4 speakers):

```powershell
# Start by friendly speaker name
$env:PYTHONPATH = '.\backend'
python -m sonos_redirector.redirector start --speaker "Living Room"

# Stop by friendly speaker name (or by --speaker-ip)
python -m sonos_redirector.redirector stop --speaker "Living Room"
```

## Installer examples

The installer now removes previous WinToSonos installs before copying the new version (including legacy paths such as `%ProgramFiles%\WinToSonos`).

Install to default per-user location and launch app:

```powershell
.\scripts\install-wintosonos.ps1
```

Install and create desktop shortcut:

```powershell
.\scripts\install-wintosonos.ps1 -CreateDesktopShortcut
```

Install and auto-start app on login:

```powershell
.\scripts\install-wintosonos.ps1 -StartAtLogin
```

Install without launching after setup:

```powershell
.\scripts\install-wintosonos.ps1 -SkipLaunchAfterInstall
```

Install to custom path:

```powershell
.\scripts\install-wintosonos.ps1 -InstallDir "C:\Tools\WinToSonos"
```

Install under Program Files (run PowerShell as Administrator):

```powershell
.\scripts\install-wintosonos.ps1 -InstallDir "$env:ProgramFiles\WinToSonos"
```

## Troubleshooting

### Python not found

Install Python 3.10+ and ensure one of these works:

```powershell
py -3 --version
# or
python --version
```

### Speaker does not play audio

- Confirm speaker IP is correct.
- Confirm PC and Sonos are on the same subnet.
- Allow local firewall inbound access for WinToSonos/Python on the stream port (default 8090).
- Check logs in `%LOCALAPPDATA%\WinToSonos`:
  - `wintosonos.log`
  - `redirector.stdout.log`
  - `redirector.stderr.log`

### Script execution disabled

If PowerShell blocks scripts:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

## Project layout

- `app/WinToSonos.ps1`: tray app UI and controls.
- `scripts/install-wintosonos.ps1`: installer.
- `scripts/start-wintosonos.ps1`: starts tray app hidden.
- `scripts/start-audio-redirect.ps1`: starts audio redirection backend.
- `scripts/stop-audio-redirect.ps1`: stops redirection backend + Sonos playback.
- `backend/sonos_redirector/`: Python audio redirector engine.

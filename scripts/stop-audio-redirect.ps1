[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$SpeakerIp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Split-Path -Path $PSScriptRoot -Parent
}

$stateRoot = Join-Path $env:LOCALAPPDATA 'WinToSonos'
$stateFile = Join-Path $stateRoot 'redirect-state.json'
$pidFile = Join-Path $stateRoot 'redirector.pid'
$venvPython = Join-Path $stateRoot 'venv\Scripts\python.exe'

if (Test-Path $venvPython) {
    $stopArgs = @('-m', 'sonos_redirector.redirector', 'stop', '--state-file', $stateFile)
    if (-not [string]::IsNullOrWhiteSpace($SpeakerIp)) {
        $stopArgs += @('--speaker-ip', $SpeakerIp)
    }

    try {
        & $venvPython @stopArgs
    }
    catch {
        Write-Warning "Unable to send graceful stop to speaker: $($_.Exception.Message)"
    }
}

if (Test-Path $pidFile) {
    try {
        $redirectPid = [int](Get-Content -Path $pidFile -Raw)
        $process = Get-Process -Id $redirectPid -ErrorAction SilentlyContinue
        if ($process) {
            Stop-Process -Id $process.Id -Force
        }
    }
    catch {
        Write-Warning "Unable to stop redirector process: $($_.Exception.Message)"
    }
    finally {
        Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
    }
}

Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
Write-Host 'WinToSonos redirection stopped.'

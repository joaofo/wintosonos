[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$SpeakerIp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-StateRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return (Join-Path $env:LOCALAPPDATA 'WinToSonos')
    }

    if (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
        return (Join-Path (Join-Path $env:HOME '.local/share') 'WinToSonos')
    }

    throw 'Could not resolve WinToSonos state directory. Set LOCALAPPDATA or HOME.'
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Split-Path -Path $PSScriptRoot -Parent
}

$stateRoot = Get-StateRoot
$stateFile = Join-Path $stateRoot 'redirect-state.json'
$pidFile = Join-Path $stateRoot 'redirector.pid'
$venvPythonCandidates = @(
    (Join-Path $stateRoot 'venv\Scripts\python.exe'),
    (Join-Path $stateRoot 'venv/bin/python')
)
$venvPython = $venvPythonCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not [string]::IsNullOrWhiteSpace($venvPython)) {
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

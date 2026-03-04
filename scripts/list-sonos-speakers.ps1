[CmdletBinding()]
param(
    [string]$InstallDir,
    [double]$TimeoutSeconds = 1.5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Split-Path -Path $PSScriptRoot -Parent
}

$stateRoot = Join-Path $env:LOCALAPPDATA 'WinToSonos'
$venvPython = Join-Path $stateRoot 'venv\Scripts\python.exe'
if (-not (Test-Path $venvPython)) {
    throw 'Python redirector environment not initialized yet. Start redirection once or run start-audio-redirect.ps1 first.'
}

$moduleRoot = Join-Path $InstallDir 'backend'
Push-Location $moduleRoot
try {
    & $venvPython -m sonos_redirector.redirector discover --json --timeout $TimeoutSeconds
}
finally {
    Pop-Location
}

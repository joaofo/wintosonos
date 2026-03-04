[CmdletBinding()]
param(
    [string]$InstallDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Split-Path -Path $PSScriptRoot -Parent
}

$appScript = Join-Path $InstallDir 'app\WinToSonos.ps1'
if (-not (Test-Path $appScript)) {
    throw "WinToSonos app script was not found at '$appScript'."
}

$argList = @(
    '-NoLogo'
    '-NoProfile'
    '-ExecutionPolicy', 'Bypass'
    '-WindowStyle', 'Hidden'
    '-File', $appScript
)

Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden | Out-Null

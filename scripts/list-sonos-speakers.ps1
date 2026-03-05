[CmdletBinding()]
param(
    [string]$InstallDir,
    [double]$TimeoutSeconds = 1.5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-DiscoveryPython {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $venvPython = Join-Path $StateRoot 'venv\Scripts\python.exe'
    if (Test-Path $venvPython) {
        return @{
            Path = $venvPython
            PrefixArgs = @()
        }
    }

    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        return @{
            Path = $pyLauncher.Source
            PrefixArgs = @('-3')
        }
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        return @{
            Path = $python.Source
            PrefixArgs = @()
        }
    }

    $python3 = Get-Command python3 -ErrorAction SilentlyContinue
    if ($python3) {
        return @{
            Path = $python3.Source
            PrefixArgs = @()
        }
    }

    throw 'Python was not found. Install Python 3.10+ and retry.'
}

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

$moduleRoot = Join-Path $InstallDir 'backend'
if (-not (Test-Path (Join-Path $moduleRoot 'sonos_redirector'))) {
    throw "Sonos redirector backend not found at '$moduleRoot'."
}

$stateRoot = Get-StateRoot
$pythonCommand = Resolve-DiscoveryPython -StateRoot $stateRoot
$timeoutValue = $TimeoutSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture)

$discoverArgs = @()
$discoverArgs += $pythonCommand.PrefixArgs
$discoverArgs += @(
    '-m', 'sonos_redirector.redirector',
    'discover',
    '--json',
    '--timeout', $timeoutValue
)

Push-Location $moduleRoot
try {
    & $pythonCommand.Path @discoverArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Speaker discovery failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

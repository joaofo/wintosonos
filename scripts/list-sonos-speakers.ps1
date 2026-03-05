[CmdletBinding()]
param(
    [string]$InstallDir,
    [double]$TimeoutSeconds = 1.5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-CommandPath {
    param([Parameter(Mandatory = $true)][string]$CommandName)

    $commandInfo = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $commandInfo) {
        return ''
    }

    foreach ($propertyName in @('Path', 'Source', 'Definition', 'Name')) {
        $property = $commandInfo.PSObject.Properties[$propertyName]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    return ''
}

function Test-PythonRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$PrefixArgs = @()
    )

    $probeArgs = @()
    $probeArgs += $PrefixArgs
    $probeArgs += @('-c', 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)')

    try {
        & $Path @probeArgs | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Resolve-DiscoveryPython {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $venvCandidates = @(
        (Join-Path $StateRoot 'venv\Scripts\python.exe'),
        (Join-Path $StateRoot 'venv/bin/python')
    )

    foreach ($venvPython in $venvCandidates) {
        if (Test-Path $venvPython) {
            return @{
                Path = $venvPython
                PrefixArgs = @()
            }
        }
    }

    $pythonCandidates = @(
        @{ Name = 'py'; PrefixArgs = @('-3') },
        @{ Name = 'python3'; PrefixArgs = @() },
        @{ Name = 'python'; PrefixArgs = @() }
    )

    foreach ($candidate in $pythonCandidates) {
        $candidatePath = Resolve-CommandPath -CommandName $candidate.Name
        if ([string]::IsNullOrWhiteSpace($candidatePath)) {
            continue
        }

        if (-not (Test-PythonRuntime -Path $candidatePath -PrefixArgs $candidate.PrefixArgs)) {
            continue
        }

        return @{
            Path = $candidatePath
            PrefixArgs = $candidate.PrefixArgs
        }
    }

    throw 'Python 3 runtime not available for speaker discovery. Start audio redirect once to initialize WinToSonos, or install Python 3.10+ and ensure py/python is available.'
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

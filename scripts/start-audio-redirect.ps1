[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$SpeakerIp,
    [int]$Port = 8090,
    [string]$StreamPath = '/stream',
    [string]$Title = 'Windows Audio'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-BootstrapPython {
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

    throw 'Python was not found. Install Python 3.10+ and retry.'
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

function Ensure-RedirectorPython {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Bootstrap,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$RequirementsFile
    )

    $venvDir = Join-Path $StateRoot 'venv'
    $venvPython = Join-Path $venvDir 'Scripts\python.exe'

    if (-not (Test-Path $venvPython)) {
        Invoke-CheckedCommand -FilePath $Bootstrap.Path -Arguments ($Bootstrap.PrefixArgs + @('-m', 'venv', $venvDir)) -Description 'Create Python virtual environment'
    }

    $requirementsHash = (Get-FileHash -Path $RequirementsFile -Algorithm SHA256).Hash
    $requirementsStampFile = Join-Path $StateRoot 'requirements.sha256'
    $needsDependencyInstall = $true

    if (Test-Path $requirementsStampFile) {
        $previousHash = (Get-Content -Path $requirementsStampFile -Raw).Trim()
        $needsDependencyInstall = ($previousHash -ne $requirementsHash)
    }

    if ($needsDependencyInstall) {
        Invoke-CheckedCommand -FilePath $venvPython -Arguments @('-m', 'pip', 'install', '--upgrade', 'pip') -Description 'Upgrade pip'
        Invoke-CheckedCommand -FilePath $venvPython -Arguments @('-m', 'pip', 'install', '-r', $RequirementsFile) -Description 'Install redirector dependencies'
        Set-Content -Path $requirementsStampFile -Value $requirementsHash -Encoding ASCII
    }

    return $venvPython
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Split-Path -Path $PSScriptRoot -Parent
}

$moduleRoot = Join-Path $InstallDir 'backend'
$requirementsFile = Join-Path $moduleRoot 'requirements.txt'
if (-not (Test-Path $requirementsFile)) {
    throw "Redirector requirements file not found at '$requirementsFile'."
}

$stateRoot = Join-Path $env:LOCALAPPDATA 'WinToSonos'
New-Item -Path $stateRoot -ItemType Directory -Force | Out-Null

$settingsFile = Join-Path $stateRoot 'settings.json'
if ([string]::IsNullOrWhiteSpace($SpeakerIp) -and (Test-Path $settingsFile)) {
    try {
        $settings = Get-Content -Path $settingsFile -Raw | ConvertFrom-Json
        if ($settings.speaker_ip) {
            $SpeakerIp = [string]$settings.speaker_ip
        }
    }
    catch {
    }
}

if ([string]::IsNullOrWhiteSpace($SpeakerIp)) {
    throw 'SpeakerIp is required. Set it in the tray app first (Select speaker...) or pass -SpeakerIp.'
}

$bootstrapPython = Resolve-BootstrapPython
$venvPython = Ensure-RedirectorPython -Bootstrap $bootstrapPython -StateRoot $stateRoot -RequirementsFile $requirementsFile

$stateFile = Join-Path $stateRoot 'redirect-state.json'
$pidFile = Join-Path $stateRoot 'redirector.pid'
$stdoutLog = Join-Path $stateRoot 'redirector.stdout.log'
$stderrLog = Join-Path $stateRoot 'redirector.stderr.log'

if (Test-Path $pidFile) {
    try {
        $previousPid = [int](Get-Content -Path $pidFile -Raw)
        $existing = Get-Process -Id $previousPid -ErrorAction SilentlyContinue
        if ($existing) {
            Stop-Process -Id $existing.Id -Force
        }
    }
    catch {
    }
}

$redirectArgs = @(
    '-m', 'sonos_redirector.redirector',
    'start',
    '--speaker-ip', $SpeakerIp,
    '--port', $Port.ToString(),
    '--stream-path', $StreamPath,
    '--title', $Title,
    '--state-file', $stateFile
)

$process = Start-Process `
    -FilePath $venvPython `
    -ArgumentList $redirectArgs `
    -WorkingDirectory $moduleRoot `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog

Set-Content -Path $pidFile -Value $process.Id -Encoding ASCII

$persistedSettings = [ordered]@{
    speaker_ip = $SpeakerIp
    last_updated_utc = (Get-Date).ToUniversalTime().ToString('o')
}
$persistedSettings | ConvertTo-Json | Set-Content -Path $settingsFile -Encoding UTF8

Write-Host "WinToSonos redirection started to speaker $SpeakerIp (PID: $($process.Id))."

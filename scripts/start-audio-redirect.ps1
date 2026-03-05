[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$SpeakerIp,
    [string]$SpeakerName,
    [int]$Port = 8090,
    [string]$StreamPath = '/stream',
    [string]$Title = 'Windows Audio'
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

function Resolve-BootstrapPython {
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

    throw 'Python 3 runtime not available. Install Python 3.10+ and ensure py/python is available in PATH.'
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

$stateRoot = Get-StateRoot
New-Item -Path $stateRoot -ItemType Directory -Force | Out-Null

$settingsFile = Join-Path $stateRoot 'settings.json'
$settings = $null
if (Test-Path $settingsFile) {
    try {
        $settings = Get-Content -Path $settingsFile -Raw | ConvertFrom-Json
    }
    catch {
    }
}

if ([string]::IsNullOrWhiteSpace($SpeakerIp) -and $null -ne $settings) {
    if ($settings.PSObject.Properties['speaker_ip'] -and $settings.speaker_ip) {
        $SpeakerIp = [string]$settings.speaker_ip
    }
}

if ([string]::IsNullOrWhiteSpace($SpeakerName) -and $null -ne $settings) {
    if ($settings.PSObject.Properties['speaker_name'] -and $settings.speaker_name) {
        $savedSpeakerIp = ''
        if ($settings.PSObject.Properties['speaker_ip'] -and $settings.speaker_ip) {
            $savedSpeakerIp = [string]$settings.speaker_ip
        }

        if ([string]::IsNullOrWhiteSpace($SpeakerIp) -or $savedSpeakerIp -eq $SpeakerIp) {
            $SpeakerName = [string]$settings.speaker_name
        }
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
    speaker_name = $SpeakerName
    last_updated_utc = (Get-Date).ToUniversalTime().ToString('o')
}
$persistedSettings | ConvertTo-Json | Set-Content -Path $settingsFile -Encoding UTF8

if ([string]::IsNullOrWhiteSpace($SpeakerName)) {
    Write-Host "WinToSonos redirection started to speaker $SpeakerIp (PID: $($process.Id))."
}
else {
    Write-Host "WinToSonos redirection started to speaker $SpeakerName ($SpeakerIp) (PID: $($process.Id))."
}

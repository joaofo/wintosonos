[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ProgramFiles\WinToSonos",
    [switch]$DebugMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$appScript = Join-Path $InstallDir 'app\WinToSonos.ps1'
if (-not (Test-Path $appScript)) {
    throw "WinToSonos app script was not found at '$appScript'."
}

$argList = @(
    '-NoLogo'
    '-NoProfile'
    '-ExecutionPolicy', 'Bypass'
    '-File', ('"{0}"' -f $appScript)
)

if (-not $DebugMode) {
    $argList = @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-WindowStyle', 'Hidden'
        '-File', ('"{0}"' -f $appScript)
    )

    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden | Out-Null
    return
}

Write-Host 'DebugMode enabled: launching app in foreground PowerShell process.'
& powershell.exe @argList

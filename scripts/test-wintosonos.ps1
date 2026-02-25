[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ProgramFiles\WinToSonos",
    [switch]$StartApp,
    [switch]$DebugStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [string]$Details
    )

    $status = if ($Passed) { '[PASS]' } else { '[FAIL]' }
    if ($Details) {
        Write-Host "$status $Name - $Details"
    }
    else {
        Write-Host "$status $Name"
    }
}

function Get-ShortcutTarget {
    param([Parameter(Mandatory = $true)][string]$ShortcutPath)

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    return [pscustomobject]@{
        TargetPath = $shortcut.TargetPath
        Arguments  = $shortcut.Arguments
    }
}

$checksFailed = 0

$appScript = Join-Path $InstallDir 'app\WinToSonos.ps1'
$starterScript = Join-Path $InstallDir 'scripts\start-wintosonos.ps1'
$startMenuShortcut = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\WinToSonos\WinToSonos.lnk'
$startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'WinToSonos.lnk'
$logFile = Join-Path $env:LOCALAPPDATA 'WinToSonos\wintosonos.log'

$installExists = Test-Path $InstallDir
Write-Check -Name 'Install directory exists' -Passed $installExists -Details $InstallDir
if (-not $installExists) { $checksFailed++ }

$appExists = Test-Path $appScript
Write-Check -Name 'App script exists' -Passed $appExists -Details $appScript
if (-not $appExists) { $checksFailed++ }

$starterExists = Test-Path $starterScript
Write-Check -Name 'Starter script exists' -Passed $starterExists -Details $starterScript
if (-not $starterExists) { $checksFailed++ }

$startMenuExists = Test-Path $startMenuShortcut
Write-Check -Name 'Start menu shortcut exists' -Passed $startMenuExists -Details $startMenuShortcut
if (-not $startMenuExists) { $checksFailed++ }

if ($startMenuExists) {
    $shortcutInfo = Get-ShortcutTarget -ShortcutPath $startMenuShortcut
    $hasBypassArg = $shortcutInfo.Arguments -match '-ExecutionPolicy\s+Bypass'
    Write-Check -Name 'Start menu shortcut uses ExecutionPolicy Bypass' -Passed $hasBypassArg -Details $shortcutInfo.Arguments
    if (-not $hasBypassArg) { $checksFailed++ }
}

$effectivePolicy = Get-ExecutionPolicy
Write-Host "[INFO] Effective execution policy: $effectivePolicy"
Write-Host '[INFO] Full execution policy list:'
Get-ExecutionPolicy -List | Format-Table -AutoSize | Out-String | Write-Host


Write-Host '[INFO] Restart verification:'
Write-Host '[INFO] - Windows restart is NOT required for WinToSonos install/startup shortcut changes.'
Write-Host '[INFO] - If you changed execution policy, reopen PowerShell and run this test again.'

if (Test-Path $logFile) {
    Write-Host "[INFO] Last 20 log lines from $logFile"
    Get-Content -Path $logFile -Tail 20
}
else {
    Write-Host "[INFO] Log file not found yet: $logFile"
}

if (Test-Path $startupShortcut) {
    $startupInfo = Get-ShortcutTarget -ShortcutPath $startupShortcut
    Write-Host "[INFO] Startup shortcut target: $($startupInfo.TargetPath)"
    Write-Host "[INFO] Startup shortcut args: $($startupInfo.Arguments)"
}
else {
    Write-Host '[INFO] Startup shortcut is not enabled for current user.'
}

if ($StartApp) {
    if (-not $starterExists) {
        throw "Cannot start app. Starter script not found at '$starterScript'."
    }

    Write-Host "[INFO] Starting WinToSonos (DebugStart=$DebugStart)..."
    & $starterScript -InstallDir $InstallDir -DebugMode:$DebugStart
    Start-Sleep -Seconds 2

    $process = Get-Process -Name powershell -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like '*powershell.exe' }
    if ($null -eq $process) {
        Write-Host '[WARN] No powershell.exe process found after launch check.'
    }
    else {
        Write-Host "[INFO] Detected powershell.exe process count: $($process.Count)"
    }
}

if ($checksFailed -gt 0) {
    throw "WinToSonos checks failed: $checksFailed"
}

Write-Host '[PASS] All required WinToSonos checks passed.'

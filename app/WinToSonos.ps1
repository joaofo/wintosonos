[CmdletBinding()]
param(
    [string]$LogFile = "$env:LOCALAPPDATA\WinToSonos\wintosonos.log",
    [string]$SonosWebUrl = 'https://play.sonos.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$logDir = Split-Path -Path $LogFile -Parent
if ($logDir -and -not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

function Write-AppLog {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Value "[$timestamp] $Message"
}

function Open-DefaultBrowser {
    param([Parameter(Mandatory = $true)][string]$Url)
    Start-Process $Url | Out-Null
}

function Get-StartupShortcutPath {
    $startupDir = [Environment]::GetFolderPath('Startup')
    return (Join-Path $startupDir 'WinToSonos.lnk')
}

function Test-StartAtLoginEnabled {
    $startupShortcut = Get-StartupShortcutPath
    return (Test-Path $startupShortcut)
}

function Set-StartAtLogin {
    param([Parameter(Mandatory = $true)][bool]$Enabled)

    $startupShortcut = Get-StartupShortcutPath
    $starterScript = Join-Path $PSScriptRoot '..\scripts\start-wintosonos.ps1'

    if (-not (Test-Path $starterScript)) {
        throw "Starter script not found at '$starterScript'."
    }

    if ($Enabled) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($startupShortcut)
        $shortcut.TargetPath = 'powershell.exe'
        $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$starterScript`""
        $shortcut.Description = 'WinToSonos'
        $shortcut.IconLocation = "$env:SystemRoot\System32\SndVol.exe,0"
        $shortcut.Save()
        Write-AppLog 'Start at login enabled.'
    }
    else {
        if (Test-Path $startupShortcut) {
            Remove-Item -Path $startupShortcut -Force
        }
        Write-AppLog 'Start at login disabled.'
    }
}

$notifyIcon = [System.Windows.Forms.NotifyIcon]::new()
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Speaker
$notifyIcon.Text = 'WinToSonos'
$notifyIcon.Visible = $true

$contextMenu = [System.Windows.Forms.ContextMenuStrip]::new()

$openSonosItem = [System.Windows.Forms.ToolStripMenuItem]::new('Open Sonos Web')
$openLogItem = [System.Windows.Forms.ToolStripMenuItem]::new('Open Log Folder')
$startupToggleItem = [System.Windows.Forms.ToolStripMenuItem]::new('Run at startup')
$startupToggleItem.CheckOnClick = $true
$startupToggleItem.Checked = Test-StartAtLoginEnabled
$aboutItem = [System.Windows.Forms.ToolStripMenuItem]::new('About')
$exitItem = [System.Windows.Forms.ToolStripMenuItem]::new('Exit')

$openSonosItem.Add_Click({
    Write-AppLog 'Opening Sonos web.'
    Open-DefaultBrowser -Url $SonosWebUrl
})

$openLogItem.Add_Click({
    Write-AppLog 'Opening log folder.'
    Start-Process (Split-Path -Path $LogFile -Parent) | Out-Null
})

$startupToggleItem.Add_Click({
    try {
        Set-StartAtLogin -Enabled $startupToggleItem.Checked
        if ($startupToggleItem.Checked) {
            $notifyIcon.BalloonTipText = 'WinToSonos will now run at startup.'
        }
        else {
            $notifyIcon.BalloonTipText = 'WinToSonos startup launch has been disabled.'
        }
        $notifyIcon.ShowBalloonTip(2000)
    }
    catch {
        Write-AppLog "Failed to update startup setting: $($_.Exception.Message)"
        $startupToggleItem.Checked = Test-StartAtLoginEnabled
        [System.Windows.Forms.MessageBox]::Show(
            "Could not update startup setting.`n`n$($_.Exception.Message)",
            'WinToSonos',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$aboutItem.Add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        "WinToSonos is running in the taskbar notification area.`n`nLog file:`n$LogFile",
        'About WinToSonos',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
})

$shouldExit = $false
$exitItem.Add_Click({
    Write-AppLog 'Exit requested from tray menu.'
    $script:shouldExit = $true
})

[void]$contextMenu.Items.Add($openSonosItem)
[void]$contextMenu.Items.Add($openLogItem)
[void]$contextMenu.Items.Add($startupToggleItem)
[void]$contextMenu.Items.Add($aboutItem)
[void]$contextMenu.Items.Add('-')
[void]$contextMenu.Items.Add($exitItem)

$notifyIcon.ContextMenuStrip = $contextMenu
$notifyIcon.BalloonTipTitle = 'WinToSonos'
$notifyIcon.BalloonTipText = 'Running in the taskbar notification area.'
$notifyIcon.ShowBalloonTip(2500)

Write-AppLog 'WinToSonos started.'

try {
    while (-not $shouldExit) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 250
    }
}
finally {
    Write-AppLog 'WinToSonos stopped.'
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $contextMenu.Dispose()
}

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

$notifyIcon = [System.Windows.Forms.NotifyIcon]::new()
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Speaker
$notifyIcon.Text = 'WinToSonos'
$notifyIcon.Visible = $true

$contextMenu = [System.Windows.Forms.ContextMenuStrip]::new()

$openSonosItem = [System.Windows.Forms.ToolStripMenuItem]::new('Open Sonos Web')
$openLogItem = [System.Windows.Forms.ToolStripMenuItem]::new('Open Log Folder')
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

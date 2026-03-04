[CmdletBinding()]
param(
    [string]$LogFile = "$env:LOCALAPPDATA\WinToSonos\wintosonos.log",
    [string]$SonosWebUrl = 'https://play.sonos.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

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

function Get-InstallRoot {
    return (Split-Path -Path $PSScriptRoot -Parent)
}

function Get-StarterScriptPath {
    $installRoot = Get-InstallRoot
    return (Join-Path $installRoot 'scripts\start-wintosonos.ps1')
}

function New-StarterScriptArguments {
    param(
        [Parameter(Mandatory = $true)][string]$StarterScript,
        [Parameter(Mandatory = $true)][string]$InstallDir
    )

    return ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`" -InstallDir `"{1}`"" -f $StarterScript, $InstallDir)
}

function Get-AppDataRoot {
    $appDataRoot = Join-Path $env:LOCALAPPDATA 'WinToSonos'
    if (-not (Test-Path $appDataRoot)) {
        New-Item -Path $appDataRoot -ItemType Directory -Force | Out-Null
    }
    return $appDataRoot
}

function Get-SettingsFilePath {
    $appDataRoot = Get-AppDataRoot
    return (Join-Path $appDataRoot 'settings.json')
}

function Get-ConfiguredSpeakerIp {
    $settingsPath = Get-SettingsFilePath
    if (-not (Test-Path $settingsPath)) {
        return ''
    }

    try {
        $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
        if ($settings.speaker_ip) {
            return [string]$settings.speaker_ip
        }
    }
    catch {
        Write-AppLog "Failed to parse settings file '$settingsPath': $($_.Exception.Message)"
    }

    return ''
}

function Set-ConfiguredSpeakerIp {
    param([Parameter(Mandatory = $true)][string]$SpeakerIp)

    $settingsPath = Get-SettingsFilePath
    $settings = [ordered]@{
        speaker_ip = $SpeakerIp
        last_updated_utc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $settings | ConvertTo-Json | Set-Content -Path $settingsPath -Encoding UTF8
}

function Prompt-SpeakerIp {
    $currentValue = Get-ConfiguredSpeakerIp
    return [Microsoft.VisualBasic.Interaction]::InputBox(
        'Enter the Sonos speaker IP address to use for audio redirection.',
        'WinToSonos Speaker',
        $currentValue
    )
}

function Get-StartRedirectScriptPath {
    $installRoot = Get-InstallRoot
    return (Join-Path $installRoot 'scripts\start-audio-redirect.ps1')
}

function Get-StopRedirectScriptPath {
    $installRoot = Get-InstallRoot
    return (Join-Path $installRoot 'scripts\stop-audio-redirect.ps1')
}

function Start-AudioRedirect {
    $startScript = Get-StartRedirectScriptPath
    if (-not (Test-Path $startScript)) {
        throw "Audio redirect start script not found at '$startScript'."
    }

    $speakerIp = Get-ConfiguredSpeakerIp
    if ([string]::IsNullOrWhiteSpace($speakerIp)) {
        $speakerIp = Prompt-SpeakerIp
    }

    if ([string]::IsNullOrWhiteSpace($speakerIp)) {
        Write-AppLog 'Audio redirect start cancelled (no speaker IP selected).'
        return
    }

    Set-ConfiguredSpeakerIp -SpeakerIp $speakerIp

    $installRoot = Get-InstallRoot
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$startScript`" -InstallDir `"$installRoot`" -SpeakerIp `"$speakerIp`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null

    Write-AppLog "Audio redirect start requested for speaker $speakerIp."
    $notifyIcon.BalloonTipText = "Starting audio redirection to $speakerIp."
    $notifyIcon.ShowBalloonTip(2500)
}

function Stop-AudioRedirect {
    $stopScript = Get-StopRedirectScriptPath
    if (-not (Test-Path $stopScript)) {
        throw "Audio redirect stop script not found at '$stopScript'."
    }

    $installRoot = Get-InstallRoot
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$stopScript`" -InstallDir `"$installRoot`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null

    Write-AppLog 'Audio redirect stop requested.'
    $notifyIcon.BalloonTipText = 'Stopping audio redirection.'
    $notifyIcon.ShowBalloonTip(2500)
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
    $starterScript = Get-StarterScriptPath
    $installRoot = Get-InstallRoot

    if (-not (Test-Path $starterScript)) {
        throw "Starter script not found at '$starterScript'."
    }

    if ($Enabled) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($startupShortcut)
        $shortcut.TargetPath = 'powershell.exe'
        $shortcut.Arguments = New-StarterScriptArguments -StarterScript $starterScript -InstallDir $installRoot
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

function Get-NotifyIcon {
    $sndVolIconPath = Join-Path $env:SystemRoot 'System32\SndVol.exe'

    try {
        if (Test-Path $sndVolIconPath) {
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($sndVolIconPath)
            if ($null -ne $icon) {
                Write-AppLog "Using icon from '$sndVolIconPath'."
                return $icon
            }
        }
    }
    catch {
        Write-AppLog "Failed to load icon from '$sndVolIconPath': $($_.Exception.Message)"
    }

    Write-AppLog 'Using fallback application icon.'
    return [System.Drawing.SystemIcons]::Application
}

$notifyIcon = [System.Windows.Forms.NotifyIcon]::new()
$notifyIcon.Icon = Get-NotifyIcon
$notifyIcon.Text = 'WinToSonos'
$notifyIcon.Visible = $true

$contextMenu = [System.Windows.Forms.ContextMenuStrip]::new()

$openSonosItem = [System.Windows.Forms.ToolStripMenuItem]::new('Open Sonos Web')
$openLogItem = [System.Windows.Forms.ToolStripMenuItem]::new('Open Log Folder')
$selectSpeakerItem = [System.Windows.Forms.ToolStripMenuItem]::new('Select speaker...')
$startRedirectItem = [System.Windows.Forms.ToolStripMenuItem]::new('Start audio redirect')
$stopRedirectItem = [System.Windows.Forms.ToolStripMenuItem]::new('Stop audio redirect')
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

$selectSpeakerItem.Add_Click({
    try {
        $speakerIp = Prompt-SpeakerIp
        if (-not [string]::IsNullOrWhiteSpace($speakerIp)) {
            Set-ConfiguredSpeakerIp -SpeakerIp $speakerIp
            Write-AppLog "Speaker selection updated to $speakerIp."
            $notifyIcon.BalloonTipText = "Speaker set to $speakerIp."
            $notifyIcon.ShowBalloonTip(2000)
        }
    }
    catch {
        Write-AppLog "Failed to set speaker selection: $($_.Exception.Message)"
    }
})

$startRedirectItem.Add_Click({
    try {
        Start-AudioRedirect
    }
    catch {
        Write-AppLog "Failed to start audio redirect: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Could not start audio redirect.`n`n$($_.Exception.Message)",
            'WinToSonos',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$stopRedirectItem.Add_Click({
    try {
        Stop-AudioRedirect
    }
    catch {
        Write-AppLog "Failed to stop audio redirect: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Could not stop audio redirect.`n`n$($_.Exception.Message)",
            'WinToSonos',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
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
    $speakerIp = Get-ConfiguredSpeakerIp
    if ([string]::IsNullOrWhiteSpace($speakerIp)) {
        $speakerIp = '(not set)'
    }

    [System.Windows.Forms.MessageBox]::Show(
        "WinToSonos redirects Windows output audio to a Sonos speaker on your local network.`n`nCurrent speaker:`n$speakerIp`n`nLog file:`n$LogFile",
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
[void]$contextMenu.Items.Add($selectSpeakerItem)
[void]$contextMenu.Items.Add($startRedirectItem)
[void]$contextMenu.Items.Add($stopRedirectItem)
[void]$contextMenu.Items.Add($openLogItem)
[void]$contextMenu.Items.Add('-')
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

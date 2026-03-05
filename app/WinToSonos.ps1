[CmdletBinding()]
param(
    [string]$LogFile = "$env:LOCALAPPDATA\WinToSonos\wintosonos.log"
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

function Get-InstallRoot {
    return (Split-Path -Path $PSScriptRoot -Parent)
}

function Get-StarterScriptPath {
    $installRoot = Get-InstallRoot
    return (Join-Path $installRoot 'scripts\start-wintosonos.ps1')
}

function Get-ListSpeakersScriptPath {
    $installRoot = Get-InstallRoot
    return (Join-Path $installRoot 'scripts\list-sonos-speakers.ps1')
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

function Get-ConfiguredSpeaker {
    $settingsPath = Get-SettingsFilePath
    $speakerIp = ''
    $speakerName = ''

    if (-not (Test-Path $settingsPath)) {
        return [PSCustomObject]@{
            ip = $speakerIp
            name = $speakerName
        }
    }

    try {
        $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
        if ($settings.PSObject.Properties['speaker_ip'] -and $settings.speaker_ip) {
            $speakerIp = [string]$settings.speaker_ip
        }
        if ($settings.PSObject.Properties['speaker_name'] -and $settings.speaker_name) {
            $speakerName = [string]$settings.speaker_name
        }
    }
    catch {
        Write-AppLog "Failed to parse settings file '$settingsPath': $($_.Exception.Message)"
    }

    return [PSCustomObject]@{
        ip = $speakerIp
        name = $speakerName
    }
}

function Get-ConfiguredSpeakerIp {
    $speaker = Get-ConfiguredSpeaker
    return [string]$speaker.ip
}

function Set-ConfiguredSpeaker {
    param(
        [Parameter(Mandatory = $true)][string]$SpeakerIp,
        [string]$SpeakerName = ''
    )

    $settingsPath = Get-SettingsFilePath
    $settings = [ordered]@{
        speaker_ip = $SpeakerIp
        speaker_name = $SpeakerName
        last_updated_utc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $settings | ConvertTo-Json | Set-Content -Path $settingsPath -Encoding UTF8
}

function Format-SpeakerLabel {
    param(
        [Parameter(Mandatory = $true)][string]$SpeakerIp,
        [string]$SpeakerName = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($SpeakerName)) {
        return "$SpeakerName ($SpeakerIp)"
    }

    return $SpeakerIp
}

function Test-LocalIpv4Address {
    param([Parameter(Mandatory = $true)][string]$Value)

    $ipAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$ipAddress)) {
        return $false
    }

    if ($ipAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }

    $bytes = $ipAddress.GetAddressBytes()
    if ($bytes[0] -eq 10) {
        return $true
    }

    if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) {
        return $true
    }

    if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) {
        return $true
    }

    if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) {
        return $true
    }

    return $false
}

function Prompt-SpeakerIp {
    $currentValue = Get-ConfiguredSpeakerIp
    return [Microsoft.VisualBasic.Interaction]::InputBox(
        'Enter the local Sonos speaker IPv4 address to use for audio redirection.',
        'WinToSonos Speaker',
        $currentValue
    )
}

function Get-DiscoveredSpeakers {
    param([double]$TimeoutSeconds = 2.5)

    $listScript = Get-ListSpeakersScriptPath
    if (-not (Test-Path $listScript)) {
        throw "Speaker discovery script not found at '$listScript'."
    }

    $installRoot = Get-InstallRoot

    $rawOutput = & $listScript -InstallDir $installRoot -TimeoutSeconds $TimeoutSeconds
    $rawText = ($rawOutput | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($rawText)) {
        return @()
    }

    try {
        $parsed = $rawText | ConvertFrom-Json
    }
    catch {
        throw "Speaker discovery returned invalid JSON output: $($_.Exception.Message)"
    }

    $items = @()
    if ($parsed -is [System.Array]) {
        $items = $parsed
    }
    elseif ($null -ne $parsed) {
        $items = @($parsed)
    }

    $speakers = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        if ($null -eq $item) {
            continue
        }

        $speakerIp = ''
        $speakerName = 'Sonos speaker'

        if ($item.PSObject.Properties['ip'] -and $item.ip) {
            $speakerIp = [string]$item.ip
        }

        if ([string]::IsNullOrWhiteSpace($speakerIp)) {
            continue
        }

        if ($item.PSObject.Properties['name'] -and -not [string]::IsNullOrWhiteSpace([string]$item.name)) {
            $speakerName = [string]$item.name
        }

        $speakers.Add([PSCustomObject]@{
            name = $speakerName
            ip = $speakerIp
        })
    }

    $sortedSpeakers = $speakers | Sort-Object -Property @{ Expression = 'name'; Ascending = $true }, @{ Expression = 'ip'; Ascending = $true }
    $seenIps = @{}
    $dedupedSpeakers = New-Object System.Collections.Generic.List[object]

    foreach ($speaker in $sortedSpeakers) {
        $speakerIp = [string]$speaker.ip
        if ($seenIps.ContainsKey($speakerIp)) {
            continue
        }

        $seenIps[$speakerIp] = $true
        $dedupedSpeakers.Add([PSCustomObject]@{
            name = [string]$speaker.name
            ip = $speakerIp
        })
    }

    return @($dedupedSpeakers)
}

function Prompt-SpeakerSelection {
    $configuredSpeaker = Get-ConfiguredSpeaker
    $configuredSpeakerIp = [string]$configuredSpeaker.ip
    $configuredSpeakerName = [string]$configuredSpeaker.name

    $discoveredSpeakers = @()
    try {
        $discoveredSpeakers = Get-DiscoveredSpeakers -TimeoutSeconds 2.5
    }
    catch {
        Write-AppLog "Speaker discovery failed: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Speaker discovery failed.`n`n$($_.Exception.Message)`n`nYou can still enter a speaker IP manually.",
            'WinToSonos',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null

        $manualIp = Prompt-SpeakerIp
        if ([string]::IsNullOrWhiteSpace($manualIp)) {
            return $null
        }

        return [PSCustomObject]@{
            ip = $manualIp.Trim()
            name = ''
        }
    }

    if ($discoveredSpeakers.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            'No Sonos speakers were discovered on the local network. Enter a local speaker IP manually.',
            'WinToSonos',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null

        $manualIp = Prompt-SpeakerIp
        if ([string]::IsNullOrWhiteSpace($manualIp)) {
            return $null
        }

        return [PSCustomObject]@{
            ip = $manualIp.Trim()
            name = ''
        }
    }

    $speakerLines = New-Object System.Collections.Generic.List[string]
    $defaultValue = $configuredSpeakerIp

    for ($index = 0; $index -lt $discoveredSpeakers.Count; $index++) {
        $speaker = $discoveredSpeakers[$index]
        $speakerLines.Add(("{0}. {1} ({2})" -f ($index + 1), $speaker.name, $speaker.ip))

        if (
            (-not [string]::IsNullOrWhiteSpace($configuredSpeakerIp) -and $speaker.ip -eq $configuredSpeakerIp) -or
            (-not [string]::IsNullOrWhiteSpace($configuredSpeakerName) -and $speaker.name -eq $configuredSpeakerName)
        ) {
            $defaultValue = ($index + 1).ToString()
        }
    }

    $selectionPrompt =
        "Discovered Sonos speakers on your local network:`n`n" +
        ($speakerLines -join "`n") +
        "`n`nEnter a number to select a speaker, or type a local IPv4 address."

    while ($true) {
        $selection = [Microsoft.VisualBasic.Interaction]::InputBox(
            $selectionPrompt,
            'WinToSonos Speaker',
            $defaultValue
        )

        if ([string]::IsNullOrWhiteSpace($selection)) {
            return $null
        }

        $trimmed = $selection.Trim()

        $selectedIndex = 0
        if ([int]::TryParse($trimmed, [ref]$selectedIndex)) {
            if ($selectedIndex -ge 1 -and $selectedIndex -le $discoveredSpeakers.Count) {
                $selectedSpeaker = $discoveredSpeakers[$selectedIndex - 1]
                return [PSCustomObject]@{
                    ip = [string]$selectedSpeaker.ip
                    name = [string]$selectedSpeaker.name
                }
            }
        }

        $nameMatches = @($discoveredSpeakers | Where-Object { $_.name -ieq $trimmed })
        if ($nameMatches.Count -eq 1) {
            return [PSCustomObject]@{
                ip = [string]$nameMatches[0].ip
                name = [string]$nameMatches[0].name
            }
        }

        $ipMatches = @($discoveredSpeakers | Where-Object { $_.ip -eq $trimmed })
        if ($ipMatches.Count -ge 1) {
            return [PSCustomObject]@{
                ip = [string]$ipMatches[0].ip
                name = [string]$ipMatches[0].name
            }
        }

        if (Test-LocalIpv4Address -Value $trimmed) {
            return [PSCustomObject]@{
                ip = $trimmed
                name = ''
            }
        }

        [System.Windows.Forms.MessageBox]::Show(
            'Invalid selection. Enter a listed number or a local IPv4 address (for example 192.168.1.50).',
            'WinToSonos',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null

        $defaultValue = $trimmed
    }
}

function Select-ConfiguredSpeaker {
    $selectedSpeaker = Prompt-SpeakerSelection
    if ($null -eq $selectedSpeaker) {
        return $null
    }

    $speakerIp = [string]$selectedSpeaker.ip
    if ([string]::IsNullOrWhiteSpace($speakerIp)) {
        return $null
    }

    if (-not (Test-LocalIpv4Address -Value $speakerIp)) {
        throw "Speaker address '$speakerIp' must be a local-network IPv4 address."
    }

    $speakerName = [string]$selectedSpeaker.name
    Set-ConfiguredSpeaker -SpeakerIp $speakerIp -SpeakerName $speakerName

    return [PSCustomObject]@{
        ip = $speakerIp
        name = $speakerName
    }
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

    $configuredSpeaker = Get-ConfiguredSpeaker
    $speakerIp = [string]$configuredSpeaker.ip
    $speakerName = [string]$configuredSpeaker.name

    if ([string]::IsNullOrWhiteSpace($speakerIp)) {
        $selectedSpeaker = Select-ConfiguredSpeaker
        if ($null -eq $selectedSpeaker) {
            Write-AppLog 'Audio redirect start cancelled (no speaker selected).'
            return
        }

        $speakerIp = [string]$selectedSpeaker.ip
        $speakerName = [string]$selectedSpeaker.name
    }

    if (-not (Test-LocalIpv4Address -Value $speakerIp)) {
        throw "Speaker address '$speakerIp' must be a local-network IPv4 address."
    }

    Set-ConfiguredSpeaker -SpeakerIp $speakerIp -SpeakerName $speakerName

    $installRoot = Get-InstallRoot
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$startScript`" -InstallDir `"$installRoot`" -SpeakerIp `"$speakerIp`""
    if (-not [string]::IsNullOrWhiteSpace($speakerName)) {
        $arguments += " -SpeakerName `"$speakerName`""
    }

    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null

    $speakerLabel = Format-SpeakerLabel -SpeakerIp $speakerIp -SpeakerName $speakerName
    Write-AppLog "Audio redirect start requested for speaker $speakerLabel."
    $notifyIcon.BalloonTipText = "Starting audio redirection to $speakerLabel."
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

$openLogItem = [System.Windows.Forms.ToolStripMenuItem]::new('Open Log Folder')
$selectSpeakerItem = [System.Windows.Forms.ToolStripMenuItem]::new('Select speaker...')
$startRedirectItem = [System.Windows.Forms.ToolStripMenuItem]::new('Start audio redirect')
$stopRedirectItem = [System.Windows.Forms.ToolStripMenuItem]::new('Stop audio redirect')
$startupToggleItem = [System.Windows.Forms.ToolStripMenuItem]::new('Run at startup')
$startupToggleItem.CheckOnClick = $true
$startupToggleItem.Checked = Test-StartAtLoginEnabled
$aboutItem = [System.Windows.Forms.ToolStripMenuItem]::new('About')
$exitItem = [System.Windows.Forms.ToolStripMenuItem]::new('Exit')

$openLogItem.Add_Click({
    Write-AppLog 'Opening log folder.'
    Start-Process (Split-Path -Path $LogFile -Parent) | Out-Null
})

$selectSpeakerItem.Add_Click({
    try {
        $selectedSpeaker = Select-ConfiguredSpeaker
        if ($null -eq $selectedSpeaker) {
            Write-AppLog 'Speaker selection cancelled.'
            return
        }

        $speakerLabel = Format-SpeakerLabel -SpeakerIp $selectedSpeaker.ip -SpeakerName $selectedSpeaker.name
        Write-AppLog "Speaker selection updated to $speakerLabel."
        $notifyIcon.BalloonTipText = "Speaker set to $speakerLabel."
        $notifyIcon.ShowBalloonTip(2000)
    }
    catch {
        Write-AppLog "Failed to set speaker selection: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Could not set speaker selection.`n`n$($_.Exception.Message)",
            'WinToSonos',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
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
    $configuredSpeaker = Get-ConfiguredSpeaker
    $speakerIp = [string]$configuredSpeaker.ip
    $speakerName = [string]$configuredSpeaker.name

    $speakerLabel = '(not set)'
    if (-not [string]::IsNullOrWhiteSpace($speakerIp)) {
        $speakerLabel = Format-SpeakerLabel -SpeakerIp $speakerIp -SpeakerName $speakerName
    }

    [System.Windows.Forms.MessageBox]::Show(
        "WinToSonos redirects Windows output audio to a Sonos speaker on your local network.`n`nCurrent speaker:`n$speakerLabel`n`nLog file:`n$LogFile",
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

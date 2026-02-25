[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallDir = "$env:ProgramFiles\WinToSonos",
    [switch]$CreateDesktopShortcut,
    [switch]$StartAtLogin,
    [switch]$SkipLaunchAfterInstall,
    [string]$RepoZipUrl = 'https://codeload.github.com/joaofo/wintosonos/zip/refs/heads/main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-ExecutionPolicyError {
    $message = @"
WinToSonos installer cannot continue because script execution is disabled on this system.

To enable scripts for your user account, run:
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

Then run the installer again.
For details, see:
    https://go.microsoft.com/fwlink/?LinkID=135170
"@
    return [System.InvalidOperationException]::new($message)
}

function Test-ScriptExecutionEnabled {
    $effectivePolicy = Get-ExecutionPolicy
    return ($effectivePolicy -ne 'Restricted')
}

function New-Shortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [string]$Arguments,
        [string]$Description = 'WinToSonos',
        [string]$IconLocation = "$env:SystemRoot\System32\SndVol.exe,0"
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    if ($Arguments) {
        $shortcut.Arguments = $Arguments
    }
    $shortcut.Description = $Description
    $shortcut.IconLocation = $IconLocation
    $shortcut.Save()
}

function Install-WinToSonos {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$TargetDir,
        [Parameter(Mandatory = $true)][string]$ZipUrl,
        [switch]$WithDesktopShortcut,
        [switch]$WithStartupShortcut,
        [switch]$LaunchNow
    )

    $tempRoot = Join-Path $env:TEMP ("wintosonos-" + [guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $tempRoot 'wintosonos.zip'
    $extractPath = Join-Path $tempRoot 'extract'

    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

    try {
        if ($PSCmdlet.ShouldProcess($ZipUrl, 'Download WinToSonos package')) {
            Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing
        }

        if ($PSCmdlet.ShouldProcess($extractPath, 'Expand WinToSonos package')) {
            Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
        }

        $repoRoot = Get-ChildItem -Path $extractPath -Directory | Select-Object -First 1
        if (-not $repoRoot) {
            throw 'Unable to locate extracted repository content.'
        }

        if ($PSCmdlet.ShouldProcess($TargetDir, 'Install WinToSonos files')) {
            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
            Copy-Item -Path (Join-Path $repoRoot.FullName '*') -Destination $TargetDir -Recurse -Force
        }

        $starterScript = Join-Path $TargetDir 'scripts\start-wintosonos.ps1'
        if (-not (Test-Path $starterScript)) {
            throw "Starter script not found at '$starterScript'."
        }

        $startMenuDir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\WinToSonos'
        $startMenuShortcut = Join-Path $startMenuDir 'WinToSonos.lnk'
        if ($PSCmdlet.ShouldProcess($startMenuShortcut, 'Create Start Menu shortcut')) {
            New-Item -Path $startMenuDir -ItemType Directory -Force | Out-Null
            New-Shortcut -Path $startMenuShortcut -TargetPath 'powershell.exe' -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$starterScript`""
        }

        if ($WithDesktopShortcut) {
            $desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'WinToSonos.lnk'
            if ($PSCmdlet.ShouldProcess($desktopShortcut, 'Create desktop shortcut')) {
                New-Shortcut -Path $desktopShortcut -TargetPath 'powershell.exe' -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$starterScript`""
            }
        }

        if ($WithStartupShortcut) {
            $startupDir = [Environment]::GetFolderPath('Startup')
            $startupShortcut = Join-Path $startupDir 'WinToSonos.lnk'
            if ($PSCmdlet.ShouldProcess($startupShortcut, 'Create Startup shortcut')) {
                New-Shortcut -Path $startupShortcut -TargetPath 'powershell.exe' -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$starterScript`""
            }
        }

        if ($LaunchNow) {
            if ($PSCmdlet.ShouldProcess('WinToSonos', 'Launch taskbar app')) {
                & $starterScript -InstallDir $TargetDir
            }
        }

        Write-Host "WinToSonos installation completed at: $TargetDir"
        Write-Host "WinToSonos is available from the Start menu as: Start > WinToSonos > WinToSonos"
        Write-Host "No Windows restart is required. If you changed execution policy, close and reopen PowerShell, then run WinToSonos."
    }
    finally {
        if (Test-Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force
        }
    }
}

if (-not (Test-ScriptExecutionEnabled)) {
    throw (New-ExecutionPolicyError)
}

Install-WinToSonos -TargetDir $InstallDir -ZipUrl $RepoZipUrl -WithDesktopShortcut:$CreateDesktopShortcut -WithStartupShortcut:$StartAtLogin -LaunchNow:$(-not $SkipLaunchAfterInstall) -WhatIf:$WhatIfPreference

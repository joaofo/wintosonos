[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallDir = "$env:ProgramFiles\WinToSonos",
    [switch]$CreateDesktopShortcut,
    [string]$RepoZipUrl = "https://codeload.github.com/joaofo/wintosonos/zip/refs/heads/main"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Install-WinToSonos {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDir,
        [Parameter(Mandatory = $true)]
        [string]$ZipUrl,
        [switch]$WithDesktopShortcut
    )

    $tempRoot = Join-Path $env:TEMP ("wintosonos-" + [guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $tempRoot "wintosonos.zip"
    $extractPath = Join-Path $tempRoot "extract"

    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

    try {
        if ($PSCmdlet.ShouldProcess($ZipUrl, "Download WinToSonos package")) {
            Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing
        }

        if ($PSCmdlet.ShouldProcess($extractPath, "Expand WinToSonos package")) {
            Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
        }

        $repoRoot = Get-ChildItem -Path $extractPath -Directory | Select-Object -First 1
        if (-not $repoRoot) {
            throw "Unable to locate extracted repository content."
        }

        if ($PSCmdlet.ShouldProcess($TargetDir, "Install WinToSonos files")) {
            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
            Copy-Item -Path (Join-Path $repoRoot.FullName '*') -Destination $TargetDir -Recurse -Force
        }

        if ($WithDesktopShortcut) {
            $shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'WinToSonos.url'
            if ($PSCmdlet.ShouldProcess($shortcutPath, "Create desktop shortcut")) {
                $shortcutContent = @(
                    '[InternetShortcut]'
                    "URL=file:///$($TargetDir -replace '\\','/')/README.md"
                    'IconFile=%SystemRoot%\System32\shell32.dll'
                    'IconIndex=220'
                )
                Set-Content -Path $shortcutPath -Value $shortcutContent -Encoding ASCII
            }
        }

        Write-Host "WinToSonos installation completed at: $TargetDir"
    }
    finally {
        if (Test-Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force
        }
    }
}

Install-WinToSonos -TargetDir $InstallDir -ZipUrl $RepoZipUrl -WithDesktopShortcut:$CreateDesktopShortcut -WhatIf:$WhatIfPreference

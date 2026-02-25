[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallDir = "$env:ProgramFiles\WinToSonos",
    [switch]$CreateDesktopShortcut,
    [ValidateSet('Auto', 'Bundle', 'Download')]
    [string]$SourceMode = 'Auto',
    [string]$LocalSourcePath,
    [string]$RepoZipUrl = "https://codeload.github.com/joaofo/wintosonos/zip/refs/heads/main"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-LocalSourceRoot {
    [CmdletBinding()]
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        if (-not (Test-Path -Path $ExplicitPath -PathType Container)) {
            throw "LocalSourcePath '$ExplicitPath' does not exist or is not a directory."
        }
        return (Resolve-Path -Path $ExplicitPath).Path
    }

    $candidate = Split-Path -Path $PSScriptRoot -Parent
    if (
        (Test-Path -Path (Join-Path $candidate 'README.md') -PathType Leaf) -and
        (Test-Path -Path (Join-Path $candidate 'scripts') -PathType Container)
    ) {
        return $candidate
    }

    return $null
}

function Install-FromLocalSource {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,
        [Parameter(Mandatory = $true)]
        [string]$TargetDir,
        [switch]$WithDesktopShortcut
    )

    if ($PSCmdlet.ShouldProcess($TargetDir, "Install WinToSonos files from local source")) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        Copy-Item -Path (Join-Path $SourceRoot '*') -Destination $TargetDir -Recurse -Force
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

function Install-FromDownload {
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

        Install-FromLocalSource -SourceRoot $repoRoot.FullName -TargetDir $TargetDir -WithDesktopShortcut:$WithDesktopShortcut -WhatIf:$WhatIfPreference
    }
    finally {
        if (Test-Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force
        }
    }
}

$resolvedLocalSource = Resolve-LocalSourceRoot -ExplicitPath $LocalSourcePath

switch ($SourceMode) {
    'Bundle' {
        if (-not $resolvedLocalSource) {
            throw "SourceMode=Bundle requires LocalSourcePath or running from a WinToSonos bundle checkout."
        }
        Install-FromLocalSource -SourceRoot $resolvedLocalSource -TargetDir $InstallDir -WithDesktopShortcut:$CreateDesktopShortcut -WhatIf:$WhatIfPreference
    }
    'Download' {
        Install-FromDownload -TargetDir $InstallDir -ZipUrl $RepoZipUrl -WithDesktopShortcut:$CreateDesktopShortcut -WhatIf:$WhatIfPreference
    }
    default {
        if ($resolvedLocalSource) {
            Install-FromLocalSource -SourceRoot $resolvedLocalSource -TargetDir $InstallDir -WithDesktopShortcut:$CreateDesktopShortcut -WhatIf:$WhatIfPreference
        }
        else {
            Install-FromDownload -TargetDir $InstallDir -ZipUrl $RepoZipUrl -WithDesktopShortcut:$CreateDesktopShortcut -WhatIf:$WhatIfPreference
        }
    }
}

[CmdletBinding()]
param(
    [string]$InstallDir,
    [double]$TimeoutSeconds = 1.5
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

function Resolve-DiscoveryPython {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $venvCandidates = @(
        (Join-Path $StateRoot 'venv\Scripts\python.exe'),
        (Join-Path $StateRoot 'venv/bin/python')
    )

    foreach ($venvPython in $venvCandidates) {
        if (-not (Test-Path $venvPython)) {
            continue
        }

        if (-not (Test-PythonRuntime -Path $venvPython -PrefixArgs @())) {
            continue
        }

        return @{
            Path = $venvPython
            PrefixArgs = @()
        }
    }

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

    return $null
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

function Test-SonosSsdpReply {
    param([Parameter(Mandatory = $true)][string]$Reply)
    return ($Reply -match '(?im)^server\s*:\s*.*sonos')
}

function Get-SsdpLocation {
    param([Parameter(Mandatory = $true)][string]$Reply)

    $match = [regex]::Match($Reply, '(?im)^location\s*:\s*(.+?)\s*$')
    if (-not $match.Success) {
        return ''
    }

    return $match.Groups[1].Value.Trim()
}

function Get-SonosDeviceName {
    param([Parameter(Mandatory = $true)][string]$Location)

    $deviceName = 'Sonos speaker'

    try {
        $previousProgressPreference = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            $response = Invoke-WebRequest -Uri $Location -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
        }
        finally {
            $ProgressPreference = $previousProgressPreference
        }

        $xmlText = [string]$response.Content
        if ([string]::IsNullOrWhiteSpace($xmlText)) {
            return $deviceName
        }

        [xml]$xmlDocument = $xmlText
        if ($null -eq $xmlDocument -or $null -eq $xmlDocument.NameTable) {
            return $deviceName
        }

        $namespaceManager = [System.Xml.XmlNamespaceManager]::new($xmlDocument.NameTable)
        $namespaceManager.AddNamespace('d', 'urn:schemas-upnp-org:device-1-0')

        $roomNameNode = $xmlDocument.SelectSingleNode('//d:device/d:roomName', $namespaceManager)
        if ($roomNameNode -and -not [string]::IsNullOrWhiteSpace([string]$roomNameNode.InnerText)) {
            return $roomNameNode.InnerText.Trim()
        }

        $friendlyNameNode = $xmlDocument.SelectSingleNode('//d:device/d:friendlyName', $namespaceManager)
        if ($friendlyNameNode -and -not [string]::IsNullOrWhiteSpace([string]$friendlyNameNode.InnerText)) {
            return $friendlyNameNode.InnerText.Trim()
        }
    }
    catch {
    }

    return $deviceName
}

function Discover-SonosSpeakersViaPowerShell {
    param(
        [double]$TimeoutSeconds = 1.5,
        [int]$Attempts = 3
    )

    $query = (
        @(
            'M-SEARCH * HTTP/1.1',
            'HOST: 239.255.255.250:1900',
            'MAN: "ssdp:discover"',
            'MX: 2',
            'ST: urn:schemas-upnp-org:device:ZonePlayer:1',
            '',
            ''
        ) -join "`r`n"
    )

    $queryBytes = [System.Text.Encoding]::UTF8.GetBytes($query)
    $multicastEndpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse('239.255.255.250'), 1900)

    $timeoutValue = [Math]::Max(0.1, [double]$TimeoutSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($timeoutValue)

    $locations = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $udpClient = [System.Net.Sockets.UdpClient]::new([System.Net.Sockets.AddressFamily]::InterNetwork)

    try {
        try {
            $udpClient.Client.SetSocketOption(
                [System.Net.Sockets.SocketOptionLevel]::IP,
                [System.Net.Sockets.SocketOptionName]::MulticastTimeToLive,
                4
            )
        }
        catch {
        }

        $attemptCount = [Math]::Max(1, [int]$Attempts)
        for ($attempt = 0; $attempt -lt $attemptCount; $attempt++) {
            [void]$udpClient.Send($queryBytes, $queryBytes.Length, $multicastEndpoint)
        }

        while ([DateTime]::UtcNow -lt $deadline) {
            $remainingMs = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remainingMs -le 0) {
                break
            }

            $udpClient.Client.ReceiveTimeout = [Math]::Min(250, [Math]::Max(1, $remainingMs))
            $remoteEndpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)

            try {
                $responseBytes = $udpClient.Receive([ref]$remoteEndpoint)
            }
            catch [System.Net.Sockets.SocketException] {
                if ($_.Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut) {
                    continue
                }
                continue
            }
            catch {
                continue
            }

            if ($null -eq $responseBytes -or $responseBytes.Length -eq 0) {
                continue
            }

            $reply = [System.Text.Encoding]::UTF8.GetString($responseBytes)
            if (-not (Test-SonosSsdpReply -Reply $reply)) {
                continue
            }

            $location = Get-SsdpLocation -Reply $reply
            if (-not [string]::IsNullOrWhiteSpace($location)) {
                [void]$locations.Add($location)
            }
        }
    }
    finally {
        $udpClient.Dispose()
    }

    $speakers = New-Object System.Collections.Generic.List[object]
    foreach ($location in ($locations | Sort-Object)) {
        $speakerIp = ''
        try {
            $locationUri = [Uri]$location
            $speakerIp = [string]$locationUri.Host
        }
        catch {
            continue
        }

        if (-not (Test-LocalIpv4Address -Value $speakerIp)) {
            continue
        }

        $speakerName = Get-SonosDeviceName -Location $location
        $speakers.Add([PSCustomObject]@{
            name = $speakerName
            ip = $speakerIp
            location = $location
        })
    }

    return @($speakers | Sort-Object -Property @{ Expression = 'name'; Ascending = $true }, @{ Expression = 'ip'; Ascending = $true })
}

function Invoke-PythonDiscovery {
    param(
        [Parameter(Mandatory = $true)][hashtable]$PythonCommand,
        [Parameter(Mandatory = $true)][string]$ModuleRoot,
        [Parameter(Mandatory = $true)][string]$TimeoutValue
    )

    $discoverArgs = @()
    $discoverArgs += $PythonCommand.PrefixArgs
    $discoverArgs += @(
        '-m', 'sonos_redirector.redirector',
        'discover',
        '--json',
        '--timeout', $TimeoutValue
    )

    Push-Location $ModuleRoot
    try {
        $output = & $PythonCommand.Path @discoverArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Python speaker discovery exited with code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }

    return ($output | Out-String).Trim()
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Split-Path -Path $PSScriptRoot -Parent
}

$moduleRoot = Join-Path $InstallDir 'backend'
if (-not (Test-Path (Join-Path $moduleRoot 'sonos_redirector'))) {
    throw "Sonos redirector backend not found at '$moduleRoot'."
}

$stateRoot = Get-StateRoot
$timeoutValue = $TimeoutSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture)

$pythonDiscoveryError = $null
$pythonCommand = Resolve-DiscoveryPython -StateRoot $stateRoot
if ($null -ne $pythonCommand) {
    try {
        $pythonJson = Invoke-PythonDiscovery -PythonCommand $pythonCommand -ModuleRoot $moduleRoot -TimeoutValue $timeoutValue
        if (-not [string]::IsNullOrWhiteSpace($pythonJson)) {
            Write-Output $pythonJson
            return
        }

        Write-Output '[]'
        return
    }
    catch {
        $pythonDiscoveryError = $_.Exception.Message
    }
}

try {
    $fallbackSpeakers = Discover-SonosSpeakersViaPowerShell -TimeoutSeconds $TimeoutSeconds -Attempts 3
    $fallbackJson = $fallbackSpeakers | ConvertTo-Json -Depth 4 -Compress
    if ([string]::IsNullOrWhiteSpace([string]$fallbackJson)) {
        Write-Output '[]'
    }
    else {
        Write-Output $fallbackJson
    }
}
catch {
    $fallbackError = $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($pythonDiscoveryError)) {
        throw "Speaker discovery failed. Python: $pythonDiscoveryError PowerShell fallback: $fallbackError"
    }

    throw "Speaker discovery failed: $fallbackError"
}

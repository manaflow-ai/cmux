$ErrorActionPreference = "Stop"
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$BaseUrl = if ($env:CMUX_DOWNLOAD_BASE_URL) {
    $env:CMUX_DOWNLOAD_BASE_URL.TrimEnd("/")
} else {
    "https://files.cmux.com/cmux-tui/latest"
}
$InstallRoot = if ($env:CMUX_INSTALL) {
    $env:CMUX_INSTALL
} else {
    Join-Path $env:USERPROFILE ".cmux"
}
$BinDir = Join-Path $InstallRoot "bin"
$Destination = Join-Path $BinDir "cmux.exe"

$Architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
if ($Architecture -ne [System.Runtime.InteropServices.Architecture]::X64 -and
    $Architecture -ne [System.Runtime.InteropServices.Architecture]::Arm64) {
    throw "cmux: unsupported Windows architecture $Architecture"
}

# Windows on Arm runs this x64 build through the OS compatibility layer.
$Artifact = "cmux-tui-x86_64-pc-windows-gnu.exe"
$Manifest = Invoke-RestMethod "$BaseUrl/manifest.json"
$Expected = $Manifest.binaries.$Artifact
if (-not $Expected) {
    throw "cmux: $Artifact is unavailable for this release"
}
$Commit = [string]$Manifest.commit
if ($Commit -notmatch '^[0-9a-f]{40}$') {
    throw "cmux: manifest has no commit"
}
$ArtifactBaseUrl = $BaseUrl
if ($ArtifactBaseUrl -match '/latest$') {
    $ArtifactBaseUrl = $ArtifactBaseUrl.Substring(0, $ArtifactBaseUrl.Length - '/latest'.Length) + "/$Commit"
}

$Temporary = Join-Path ([System.IO.Path]::GetTempPath()) (
    "cmux-install-" + [System.Guid]::NewGuid().ToString("N") + ".exe"
)
try {
    Invoke-WebRequest "$ArtifactBaseUrl/$Artifact" -OutFile $Temporary
    $Actual = (Get-FileHash $Temporary -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected.ToLowerInvariant()) {
        throw "cmux: checksum verification failed"
    }

    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    Move-Item -Force $Temporary $Destination
} finally {
    if (Test-Path $Temporary) {
        Remove-Item -Force $Temporary
    }
}

$UserPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
$PathParts = @($UserPath -split ";" | Where-Object { $_ })
if ($PathParts -notcontains $BinDir) {
    $NewUserPath = (@($PathParts) + $BinDir) -join ";"
    [System.Environment]::SetEnvironmentVariable("Path", $NewUserPath, "User")
}
if (($env:Path -split ";") -notcontains $BinDir) {
    $env:Path = "$BinDir;$env:Path"
}

Write-Host "Installed cmux to $Destination"

# Remote hosting (plans/cmux-next/remote-hosts.md): with CMUX_HOST=1 this
# machine serves its cmux sessions to its owner's other machines over the
# tailnet. A tagged machine names its owner with CMUX_HOST_OWNER=<login>.
if ($env:CMUX_HOST -eq "1") {
    if ($env:CMUX_HOST_OWNER) {
        & $Destination host enable --owner $env:CMUX_HOST_OWNER
    } else {
        & $Destination host enable
    }
    if ($LASTEXITCODE -ne 0) {
        throw "cmux: remote hosting could not be turned on (see above)"
    }
}

try {
    $Telemetry = @{
        product = "tui"
        platform = "Windows-$Architecture"
        method = "powershell"
    } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post `
        -Uri "https://cmux.com/api/install-events" `
        -ContentType "application/json" `
        -Body $Telemetry `
        -TimeoutSec 2 | Out-Null
} catch {
    # Analytics is best effort and must never fail installation.
}

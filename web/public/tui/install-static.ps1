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

$Temporary = Join-Path ([System.IO.Path]::GetTempPath()) (
    "cmux-install-" + [System.Guid]::NewGuid().ToString("N") + ".exe"
)
try {
    Invoke-WebRequest "$BaseUrl/$Artifact" -OutFile $Temporary
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

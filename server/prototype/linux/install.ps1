# cmux server installer for Windows (DRAFT, UNVERIFIED: never executed).
#
#   irm https://cmux.com/server/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://cmux.com/server/install.ps1))) -Version 1.4.2 -System
#
# Mirrors install.sh (plans/cmux-next/server.md 4.2): everything runs from
# Main on the last line, so a cut download runs nothing; the bootstrap archive
# is checked by size, SHA-256 (Get-FileHash) and Authenticode (status Valid and
# our publisher certificate thumbprint) before anything runs; no elevation
# unless -System, and then only the verified file is started elevated.
# The verified binary then runs `cmux server install`, which owns the manifest,
# the store, the profile flip and the service (Scheduled Task at logon in user
# mode; Windows service `cmux-server` with a virtual account in system mode).

param(
    [string]$Version = '',
    [switch]$System
)

# --- BEGIN GENERATED (CI writes this block per release) ---------------------
$CmuxReleaseVersion = '0.0.0-unset'
$CmuxChannelUrl = 'https://cmux.com/server/channel/stable'
$CmuxBootstrap = @{
    'x86_64-windows'  = @{ Url = ''; Size = 0; Sha256 = '' }
    'aarch64-windows' = @{ Url = ''; Size = 0; Sha256 = '' }
}
# SHA-1 thumbprints of the publisher certificates allowed to sign cmux.exe
# (current and next, for rotation).
$CmuxPublisherThumbprints = @('', '')
# --- END GENERATED ----------------------------------------------------------

Set-StrictMode -Version 3.0

function Fail([string]$Message) {
    throw "cmux-install: error: $Message"
}

function Get-Target {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { return 'x86_64-windows' }
        'ARM64' { return 'aarch64-windows' }
        default { Fail "unsupported architecture: $($env:PROCESSOR_ARCHITECTURE)" }
    }
}

function New-PrivateTempDir {
    # A fresh directory under the user's temp folder with an ACL that grants
    # only the current user (the umask 077 equivalent).
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("cmux-install." + [guid]::NewGuid().ToString('N'))
    $item = New-Item -ItemType Directory -Path $dir
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $me, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -Path $item.FullName -AclObject $acl
    return $item.FullName
}

function Test-VerifiedFile([string]$Path, [long]$Size, [string]$Sha256, [string]$Label) {
    $actualSize = (Get-Item -LiteralPath $Path).Length
    if ($actualSize -ne $Size) { Fail "size mismatch for ${Label}: expected $Size, got $actualSize; refusing" }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256.ToLowerInvariant()) { Fail "SHA-256 mismatch for ${Label}: expected $Sha256, got $actual; refusing" }
}

function Test-Publisher([string]$Path) {
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid') { Fail "Authenticode status of $Path is $($sig.Status); refusing" }
    $thumb = $sig.SignerCertificate.Thumbprint
    $allowed = $CmuxPublisherThumbprints | Where-Object { $_ -ne '' }
    if (-not ($allowed -contains $thumb)) { Fail "unexpected publisher certificate $thumb; refusing" }
}

function Main {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    if ($Version -ne '' -and $Version -notmatch '^[A-Za-z0-9._-]+$') { Fail "invalid version: $Version" }
    $target = Get-Target
    $boot = $CmuxBootstrap[$target]
    if (-not $boot.Url -or $boot.Sha256 -notmatch '^[0-9a-f]{64}$') { Fail "this installer carries no bootstrap archive for $target" }
    if (-not $boot.Url.StartsWith('https://')) { Fail "refusing non-HTTPS URL: $($boot.Url)" }

    $tmp = New-PrivateTempDir
    try {
        $zip = Join-Path $tmp 'bootstrap.zip'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $boot.Url -OutFile $zip
        Test-VerifiedFile $zip $boot.Size $boot.Sha256 'bootstrap archive'
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'bootstrap')
        $exe = Join-Path $tmp 'bootstrap\bin\cmux.exe'
        if (-not (Test-Path -LiteralPath $exe)) { Fail 'bootstrap archive has no bin\cmux.exe' }
        Test-Publisher $exe

        $installArgs = @('server', 'install')
        if ($Version -ne '') { $installArgs += @('--version', $Version) }
        if ($System) {
            # Elevate only the verified file; never a downloaded script.
            $installArgs += '--system'
            $p = Start-Process -FilePath $exe -ArgumentList $installArgs -Verb RunAs -Wait -PassThru
            if ($p.ExitCode -ne 0) { Fail "system install failed with exit code $($p.ExitCode)" }
        } else {
            $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
            if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                Write-Warning 'cmux-install: running elevated; the user-mode server will still run as this user. Use -System for a machine-wide service.'
            }
            & $exe @installArgs
            if ($LASTEXITCODE -ne 0) { Fail "install failed with exit code $LASTEXITCODE" }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Main

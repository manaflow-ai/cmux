param(
    [Parameter(Mandatory = $true)]
    [string]$Binary
)

$ErrorActionPreference = "Stop"
$binaryPath = (Resolve-Path $Binary).Path
$testRoot = Join-Path $env:RUNNER_TEMP "cmux-native-ssh"
$keyPath = Join-Path $testRoot "id_ed25519"
$knownHosts = Join-Path $testRoot "known_hosts"
$remoteState = Join-Path $env:LOCALAPPDATA "cmux\remote"
$defaultRemoteBinary = Join-Path $env:LOCALAPPDATA "cmux\bin\cmux-tui.exe"
$session = "hosted-windows-ssh"
$client = $null

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $defaultRemoteBinary) | Out-Null
Copy-Item -Force $binaryPath $defaultRemoteBinary

$server = Get-WindowsCapability -Online |
    Where-Object { $_.Name -like "OpenSSH.Server*" } |
    Select-Object -First 1
if ($null -eq $server) {
    throw "The hosted Windows image does not expose the OpenSSH Server capability"
}
if ($server.State -ne "Installed") {
    Add-WindowsCapability -Online -Name $server.Name | Out-Null
}
Set-Service -Name sshd -StartupType Manual
Start-Service -Name sshd

& ssh-keygen.exe -q -t ed25519 -N "" -f $keyPath
if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed" }

$authorizedKeys = Join-Path $env:ProgramData "ssh\administrators_authorized_keys"
Get-Content "$keyPath.pub" | Set-Content -Encoding ascii $authorizedKeys
& icacls.exe $authorizedKeys /inheritance:r | Out-Null
if ($LASTEXITCODE -ne 0) { throw "could not remove inherited authorized-key permissions" }
& icacls.exe $authorizedKeys /grant "*S-1-5-32-544:F" "*S-1-5-18:F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "could not protect the authorized-key file" }
Restart-Service -Name sshd

& ssh-keyscan.exe localhost 2>$null | Set-Content -Encoding ascii $knownHosts
if ($LASTEXITCODE -ne 0) { throw "ssh-keyscan failed" }
if (-not (Test-Path $knownHosts) -or (Get-Item $knownHosts).Length -eq 0) {
    throw "ssh-keyscan returned no host key for localhost"
}

$sshOptions = @(
    "-i", $keyPath,
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=yes",
    "-o", "UserKnownHostsFile=$knownHosts"
)
$target = "$env:USERNAME@localhost"
$probe = & ssh.exe @sshOptions $target $defaultRemoteBinary remote-probe --json
if ($LASTEXITCODE -ne 0) { throw "real OpenSSH probe failed" }
$probeValue = $probe | ConvertFrom-Json
if ($probeValue.app -ne "cmux-tui" -or $probeValue.os -ne "windows") {
    throw "real OpenSSH probe returned an unexpected target"
}

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $binaryPath
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
foreach ($argument in @(
    "ssh", $target,
    "--headless", "--json",
    "--session", $session,
    "--remote-state-dir", $remoteState,
    "--no-install",
    "--connect-timeout-seconds", "20"
)) {
    $startInfo.ArgumentList.Add($argument)
}
foreach ($argument in $sshOptions) {
    $startInfo.ArgumentList.Add("--ssh-arg")
    $startInfo.ArgumentList.Add($argument)
}

try {
    $client = [System.Diagnostics.Process]::Start($startInfo)
    $snapshotTask = $client.StandardOutput.ReadLineAsync()
    if (-not $snapshotTask.Wait([TimeSpan]::FromSeconds(20))) {
        throw "native Windows SSH did not publish its local endpoint within 20 seconds"
    }
    $snapshotLine = $snapshotTask.Result
    if ([string]::IsNullOrWhiteSpace($snapshotLine)) {
        $detail = "SSH client closed stdout without an endpoint"
        if ($client.WaitForExit(5000)) {
            $stderr = $client.StandardError.ReadToEnd().Trim()
            if ([string]::IsNullOrWhiteSpace($stderr)) {
                $detail = "$detail (exit code $($client.ExitCode))"
            } else {
                $detail = "$detail (exit code $($client.ExitCode)): $stderr"
            }
        }
        throw "native Windows SSH startup failed: $detail"
    }
    $snapshot = $snapshotLine | ConvertFrom-Json
    if ($snapshot.event -ne "connection-snapshot" -or [string]::IsNullOrWhiteSpace($snapshot.local_socket)) {
        throw "native Windows SSH published an invalid connection snapshot"
    }

    $listing = & $binaryPath --socket $snapshot.local_socket --json workspace list
    if ($LASTEXITCODE -ne 0) {
        $detail = "SSH bridge did not exit after the failed request"
        if ($client.WaitForExit(5000)) {
            $stderr = $client.StandardError.ReadToEnd().Trim()
            $detail = if ([string]::IsNullOrWhiteSpace($stderr)) {
                "SSH bridge exited without a diagnostic"
            } else {
                $stderr
            }
        }
        $ownerLog = Join-Path $remoteState "sessions\$session\owner.log"
        if (Test-Path $ownerLog) {
            $ownerDiagnostic = (Get-Content -Raw $ownerLog).Trim()
            if (-not [string]::IsNullOrWhiteSpace($ownerDiagnostic)) {
                $detail = "$detail; owner: $ownerDiagnostic"
            }
        }
        throw "native Windows SSH workspace list failed: $detail"
    }
    $listing | ConvertFrom-Json | Out-Null

    & $binaryPath --socket $snapshot.local_socket --json session current shutdown | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "native Windows SSH shutdown failed" }
    if (-not $client.WaitForExit(20000)) {
        throw "native Windows SSH client did not exit after remote shutdown"
    }
    if ($client.ExitCode -ne 0) {
        throw "native Windows SSH client failed: $($client.StandardError.ReadToEnd())"
    }
} finally {
    if ($null -ne $client -and -not $client.HasExited) {
        $client.Kill($true)
        $client.WaitForExit()
    }
    & $binaryPath remote-stop --session $session --state-dir $remoteState 2>$null | Out-Null
}

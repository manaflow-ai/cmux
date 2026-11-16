# cmux machine join for Windows: one pasted PowerShell line adds this PC to
# your team's cmux machines. `cmux machine add` (or Add Machine in the app)
# prints the line:
#
#    $env:CMUX_JOIN='cmj_...'; irm <platform>/v1/machines/join.ps1 | iex
#
# The token rides in this PowerShell's environment only until the first line
# below reads it and removes it, so no process this script starts ever sees
# it in its environment or its argv.
#
# Steps, as machine-join.sh does on macOS and Linux: install acpmux to
# %USERPROFILE%\.local\bin (checked against the windows-<channel> channel's
# sha256) and put that folder on this user's PATH, install the per-user logon
# task that starts the acpmux daemon at each logon (`acpmux daemon service
# install`; no administrator), start the daemon, redeem the token once through
# `acpmux host join` (the token goes on its stdin, never in argv, env, a URL or
# a log), then print this machine's join status. Run the line again with no
# token to repair the install and the logon task, or to finish a join that was
# cut off; a joined machine never spends a new token.
#
# The join grants mesh membership only. Screen sharing and control stay off
# until a person at this machine allows them.
#
# Knobs: CMUX_JOIN_NAME (this machine's name), CMUX_JOIN_CHANNEL (default
# feat-cmux-next; the Windows build is read from channels/windows-<channel>),
# CMUX_JOIN_REPLACE=1 (swap an existing credential), CMUX_JOIN_HARNESSES
# (default claude,codex; none installs and offers nothing).
#
# Source: cmux-tui/scripts/machine-join.ps1 in manaflow-ai/cmux; the
# platform serves a copy with its own origin written in.
#
# `irm | iex` runs this in the caller's own PowerShell session: everything is
# inside one script block (no variable or preference leaks into the session),
# and nothing here calls `exit`, which would close the person's window. The
# outcome is the script block's $LASTEXITCODE.

& {
  # 1. The token, out of the environment before anything else runs.
  $t = [string]$env:CMUX_JOIN
  Remove-Item Env:\CMUX_JOIN -ErrorAction SilentlyContinue
  Set-StrictMode -Version 2
  # Continue, not Stop: Windows PowerShell 5.1 turns a native command's stderr into a terminating
  # error under Stop. Each cmdlet whose failure matters says -ErrorAction Stop itself.
  $ErrorActionPreference = 'Continue'
  $ProgressPreference = 'SilentlyContinue'

  function Say([string]$Text) { [Console]::Error.WriteLine("cmux join: $Text") }
  # Ends the join: the message, then this exit code in $LASTEXITCODE.
  function Stop-Join([int]$Code, [string]$Text) {
    Say $Text
    $global:LASTEXITCODE = $Code
    throw [System.OperationCanceledException]::new('cmux-join-stop')
  }

  try {
    if ($t) {
      if (-not $t.StartsWith('cmj_')) { Stop-Join 2 'that is not a cmux join token (it starts with cmj_)' }
      if ($t.Length -gt 4096 -or $t -notmatch '^cmj_[A-Za-z0-9_-]+$') {
        Stop-Join 2 'the line was damaged; copy it again from cmux'
      }
    }

    # The platform origin. The served copy has it written in; a run from the
    # source tree falls back to development. CMUX_PLATFORM_URL overrides both.
    $origin = '@@CMUX_PLATFORM_ORIGIN@@'
    if ($origin.StartsWith('@@')) { $origin = 'https://cmux-platform-development.debussy.workers.dev' }
    if ($env:CMUX_PLATFORM_URL) { $origin = [string]$env:CMUX_PLATFORM_URL }
    $origin = $origin.TrimEnd('/')
    if (-not $origin.StartsWith('https://')) { Stop-Join 1 "refusing the platform origin ${origin}: https only" }

    $files = 'https://files.cmux.com/cmux-tui'
    $joinCapability = 'machine.join.stdin.v1'
    $vaultCapability = 'machine.vault.pull.v1'
    $userHome = [Environment]::GetFolderPath('UserProfile')
    $binDir = Join-Path (Join-Path $userHome '.local') 'bin'
    $acpmux = Join-Path $binDir 'acpmux.exe'

    $harnesses = if ($null -ne $env:CMUX_JOIN_HARNESSES) { [string]$env:CMUX_JOIN_HARNESSES } else { 'claude,codex' }
    if ((",$harnesses,") -like '*,none,*') { $harnesses = '' }
    if ($harnesses -cnotmatch '^[a-z,]*$') { Stop-Join 2 'CMUX_JOIN_HARNESSES takes claude, codex or none' }
    function Wants([string]$Name) { return (",$harnesses,") -like "*,$Name,*" }

    # 2. Platform: x64, or Arm64 through Windows' x64 emulation.
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ($arch -ne [System.Runtime.InteropServices.Architecture]::X64 -and
        $arch -ne [System.Runtime.InteropServices.Architecture]::Arm64) {
      Stop-Join 1 "unsupported Windows architecture $arch (x64 or Arm64)"
    }
    $artifact = 'cmux-tui-acpmux-x86_64-pc-windows-gnu.exe'
    try {
      [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    } catch { }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('cmux-join-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp -ErrorAction Stop | Out-Null

    function Get-File([string]$Url, [string]$Path) {
      try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path -TimeoutSec 120 -ErrorAction Stop
        return $true
      } catch {
        return $false
      }
    }
    function Get-Sha256([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
    function Test-Capability([string]$Name) {
      if (-not (Test-Path -LiteralPath $acpmux -PathType Leaf)) { return $false }
      try { $lines = @(& $acpmux capabilities 2>$null) } catch { return $false }
      return ($lines | ForEach-Object { "$_".Trim() }) -contains $Name
    }
    # One acpmux run, its output dropped; true on exit 0.
    function Invoke-Acpmux([string[]]$Arguments) {
      try { & $acpmux @Arguments *> $null } catch { return $false }
      return $LASTEXITCODE -eq 0
    }
    function Quote([string]$Arg) {
      if ($Arg -notmatch '[\s"]' -and $Arg) { return $Arg }
      return '"' + ($Arg -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }

    # 3. acpmux from the channel, checked against its sha256 before it touches
    # %USERPROFILE%\.local\bin. The token only ever goes to a binary with the
    # channel's sha256: on a mismatch the channel's build replaces it (the old
    # one stays as acpmux.prev.exe; a running one can be renamed, not
    # overwritten). A repair run with no token keeps a different binary that
    # can join, and keeps the installed one when the channel cannot be read.
    $channel = if ($env:CMUX_JOIN_CHANNEL) { [string]$env:CMUX_JOIN_CHANNEL } else { 'feat-cmux-next' }
    if ($channel -cnotmatch '^[a-z0-9-]+$') { Stop-Join 1 "refusing the channel ${channel}: lowercase letters, digits and - only" }
    $want = ''
    $key = ''
    $channelFile = Join-Path $tmp 'channel.json'
    if (Get-File "$files/channels/windows-$channel.json" $channelFile) {
      $pointer = $null
      try { $pointer = Get-Content -Raw -LiteralPath $channelFile | ConvertFrom-Json -ErrorAction Stop } catch { }
      $field = { param($o, $n) if ($null -ne $o -and $o.PSObject.Properties[$n]) { $o.PSObject.Properties[$n].Value } else { $null } }
      $key = [string](& $field $pointer 'key')
      $want = [string](& $field (& $field $pointer 'binaries') $artifact)
      if ($key -cnotmatch '^[0-9a-f]{40}$' -or $want -cnotmatch '^[0-9a-f]{64}$') {
        Stop-Join 1 "the windows-$channel channel has no acpmux build for Windows"
      }
    }
    $replaced = $false
    $installed = Test-Path -LiteralPath $acpmux -PathType Leaf
    if (-not $want) {
      if ($t -or -not (Test-Capability $joinCapability)) {
        Stop-Join 1 "cannot read the windows-$channel channel from files.cmux.com: check this PC's outbound HTTPS, then paste the line again"
      }
      Say "cannot read the windows-$channel channel; keeping the installed acpmux"
    } elseif ($installed -and (Get-Sha256 $acpmux) -eq $want) {
    } elseif (-not $t -and (Test-Capability $joinCapability)) {
      Say "keeping the installed acpmux (the next join line brings it to $channel)"
    } else {
      $download = Join-Path $tmp 'acpmux.exe'
      if (-not (Get-File "$files/tree/$key/$artifact" $download)) { Stop-Join 1 'cannot download acpmux for Windows' }
      $got = Get-Sha256 $download
      if ($got -ne $want) {
        Stop-Join 1 "checksum verification failed for acpmux ($got, the channel says $want); nothing was installed"
      }
      New-Item -ItemType Directory -Force -Path $binDir -ErrorAction Stop | Out-Null
      $prev = Join-Path $binDir 'acpmux.prev.exe'
      if ($installed) {
        Remove-Item -Force -LiteralPath $prev -ErrorAction SilentlyContinue
        Move-Item -Force -LiteralPath $acpmux -Destination $prev -ErrorAction Stop
        $replaced = $true
      }
      Move-Item -Force -LiteralPath $download -Destination $acpmux -ErrorAction Stop
      Say "installed acpmux to $acpmux"
    }

    # On this user's PATH, now and for new terminals.
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @(([string]$userPath) -split ';' | Where-Object { $_ })
    if ($parts -notcontains $binDir) {
      [Environment]::SetEnvironmentVariable('Path', ((@($parts) + $binDir) -join ';'), 'User')
    }
    if ((([string]$env:Path) -split ';') -notcontains $binDir) { $env:Path = "$binDir;$env:Path" }

    if ($t -and -not (Test-Capability $joinCapability)) {
      Stop-Join 1 "this acpmux is too old: update ($acpmux has no $joinCapability; the windows-$channel channel does not carry it yet)"
    }

    # 4. The logon task and the daemon. `daemon service install` registers the
    # per-user logon task (or, where Task Scheduler refuses one, the Run key)
    # that starts the daemon at each logon; it does not start it now.
    try {
      $svc = ((& $acpmux daemon service install 2>&1 | ForEach-Object { "$_" }) -join ' ').Trim()
      if ($LASTEXITCODE -eq 0) {
        if ($svc) { Say $svc }
      } else {
        Say "warning: the acpmux logon task did not install$(if ($svc) { ": $svc" })"
      }
    } catch {
      Say 'warning: this acpmux cannot install its logon task; the daemon runs until the next sign-out'
    }
    # A replaced binary takes over a running daemon by a restart, which keeps
    # its sessions; with none running, the restart fails and start starts one.
    if (-not ($replaced -and (Invoke-Acpmux @('daemon', 'restart')))) {
      if (-not (Invoke-Acpmux @('daemon', 'start'))) { Say "warning: the acpmux daemon did not start: run $acpmux daemon start" }
    }

    # 5. The name: CMUX_JOIN_NAME, else the first label of the host name.
    $name = [string]$env:CMUX_JOIN_NAME
    if (-not $name) { $name = ([System.Net.Dns]::GetHostName() -split '\.')[0] }

    # 6. Redeem, once, as machine-join.sh does: a machine already joined
    # spends nothing unless CMUX_JOIN_REPLACE=1; a join cut off between redeem
    # and its local commit resumes; a revoked enrollment takes a fresh line.
    function Get-JoinStatus {
      try { return (& $acpmux host join --status --json 2>$null | Out-String | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
    }
    $freshLine = 'paste a new line: cmux machine add (or Add Machine in the app)'
    $isJoined = $false
    $joined = $false
    $resume = $false
    $revoked = $false
    $replace = $env:CMUX_JOIN_REPLACE -eq '1'
    if (Test-Capability $joinCapability) {
      $st = Get-JoinStatus
      if ($st) {
        $has = { param($n) $st.PSObject.Properties.Name -contains $n }
        if ((& $has 'joinIncomplete') -and $st.joinIncomplete -eq $true) { $resume = $true }
        elseif ((& $has 'revoked') -and $st.revoked -eq $true) { $revoked = $true }
        elseif ((& $has 'credentialPresent') -and $st.credentialPresent -eq $true -and
                (& $has 'revoked') -and $st.revoked -eq $false) { $joined = $true }
      }
    }
    if ($resume) {
      Say 'resuming a join that did not finish'
    } elseif ($revoked) {
      if (-not $t) { Stop-Join 3 "this machine's enrollment was revoked or has expired; $freshLine" }
      $replace = $true
    } elseif ($joined -and $t -and -not $replace) {
      Say 'already joined; nothing redeemed (CMUX_JOIN_REPLACE=1 swaps the credential)'
      $t = ''
    }
    if ($joined) { $isJoined = $true }

    if ($t -or $resume) {
      $withToken = [bool]$t
      while ($true) {
        # A resume leaves out --name; one with no token leaves out --hub too,
        # so acpmux asks the pending hub. A token only goes to this origin.
        $argv = @('host', 'join')
        if (-not ($resume -and -not $withToken)) { $argv += @('--hub', $origin) }
        if (-not $resume) { $argv += @('--name', $name) }
        $argv += '--json'
        if ($replace) { $argv += '--replace' }
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $acpmux
        $info.Arguments = (($argv | ForEach-Object { Quote $_ }) -join ' ')
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($info)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        # The token reaches acpmux on its stdin only; a resume with no token
        # gives it an empty stdin.
        if ($withToken) { $proc.StandardInput.WriteLine($t) }
        $proc.StandardInput.Close()
        $proc.WaitForExit()
        $rc = $proc.ExitCode
        $joinOut = $outTask.Result
        # acpmux redacts its own errors; anything token-shaped is cut anyway.
        $joinErr = ($errTask.Result -replace 'cmj_[A-Za-z0-9_-]*', '[redacted token]').TrimEnd()
        if ($rc -eq 3 -and $joinErr -match 'revoked:') {
          if (-not $withToken) { Stop-Join 3 "this machine's enrollment was revoked or has expired; $freshLine" }
          if (-not $replace) { $replace = $true; continue }
        }
        break
      }
      $t = ''
      if ($rc -eq 2 -and $resume) {
        if ($joinErr) { [Console]::Error.WriteLine($joinErr) }
        Stop-Join 2 "the join that did not finish could not resume: paste the same line again (same CMUX_JOIN_NAME), or $freshLine"
      }
      switch ($rc) {
        0 {
          $isJoined = $true
          if (($joinOut -replace '\s', '') -like '*"alreadyJoined":true*') {
            Say 'already joined; nothing redeemed'
          } else {
            if ($resume) { Say 'joined' } else { Say "joined as $name" }
            # The daemon reads the join (its mesh relay) when it starts.
            if (-not (Invoke-Acpmux @('daemon', 'restart'))) {
              Say "warning: the daemon did not restart onto the join, so it sends no heartbeat yet: run $acpmux daemon restart"
            }
          }
        }
        2 { Stop-Join 2 'the line was damaged; copy it again from cmux' }
        3 {
          if ($joinErr -and $joinErr -notmatch 'revoked:') { [Console]::Error.WriteLine($joinErr) }
          Stop-Join 3 'this line was used or expired; make a new one: cmux machine add (or Add Machine in the app)'
        }
        4 {
          if ($resume) { Stop-Join 4 "the hub could not be reached; rerun the same line once this PC's outbound HTTPS works" }
          Stop-Join 4 "cannot reach ${origin}: check this PC's outbound HTTPS, then paste a new line"
        }
        5 { Stop-Join 5 "could not store the machine credential in $(Join-Path $userHome '.acpmux'): free disk / fix permissions, then paste a new line" }
        default {
          if ($joinErr) { [Console]::Error.WriteLine($joinErr) }
          Stop-Join $rc "joining failed (acpmux exit $rc); paste a new line, or run: $acpmux host join --status"
        }
      }
    }

    # 7. Once joined: the missing harnesses (named, not installed: their own
    # Windows installers), then the vault, names only.
    if ($isJoined) {
      if ((Wants 'claude') -and -not (Get-Command claude -ErrorAction SilentlyContinue) -and
          -not (Test-Path -LiteralPath (Join-Path $binDir 'claude.exe'))) {
        Say 'Claude Code is not installed: irm https://claude.ai/install.ps1 | iex'
      }
      if ((Wants 'codex') -and -not (Get-Command codex -ErrorAction SilentlyContinue)) {
        Say 'Codex is not installed: npm install -g @openai/codex'
      }
      if (Test-Capability $vaultCapability) {
        $v = $null
        try { $v = & $acpmux host vault pull --json 2>$null | Out-String | ConvertFrom-Json -ErrorAction Stop } catch { }
        $names = @()
        if ($v -and ($v.PSObject.Properties.Name -contains 'env')) {
          $names = @($v.env | Where-Object { "$_" -match '^[A-Za-z_][A-Za-z0-9_]*$' })
        }
        $state = if ($v -and ($v.PSObject.Properties.Name -contains 'state')) { [string]$v.state } else { '' }
        switch ($state) {
          'not_granted' { Say "vault: not shared with this machine (from your Mac: cmux machine vault grant $name)" }
          'off' { }
          'ok' { if ($names.Count -eq 0) { Say 'vault: no env vars yet' } else { Say "vault: $($names.Count) env vars ($($names -join ' '))" } }
          'partial' { Say "warning: the vault pull got $($names.Count) env vars, not all of them; retry: $acpmux host vault pull" }
          default { Say "warning: the vault pull did not finish; retry: $acpmux host vault pull" }
        }
        $v = $null
      }
    }

    # 8. Where this machine stands.
    $code = 0
    if (Test-Capability $joinCapability) {
      & $acpmux host join --status
      $code = $LASTEXITCODE
    }
    Write-Output 'Screen sharing and control are off on this machine. To allow them, run here: acpmux host consent grant --screen (or --control). Your team''s machines cannot turn them on.'
    if ($isJoined) {
      foreach ($h in @('claude', 'codex')) {
        if (-not (Wants $h)) { continue }
        if ($h -eq 'claude') { Say 'sign in to Claude Code on this PC: run claude here and sign in with its /login' }
        else { Say 'sign in to Codex on this PC: run codex login here' }
      }
    }
    $global:LASTEXITCODE = $code
  } catch [System.OperationCanceledException] {
    # Stop-Join: said, and $LASTEXITCODE set.
  } finally {
    $t = ''
    if ((Get-Variable -Name tmp -Scope 0 -ErrorAction SilentlyContinue) -and $tmp -and (Test-Path -LiteralPath $tmp)) {
      Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
  }
}

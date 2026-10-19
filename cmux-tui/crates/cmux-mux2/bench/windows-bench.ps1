# windows-bench.ps1: mux2 vs cmux-tui on Windows. One JSON line per result.
#   windows-bench.ps1 -Mux2 DIR -Ctui EXE -Corpus DIR [-Test all|start|scale|tput|rtt] [-N 50]
#                     [-Scale 500] [-Reps 1]
# DIR holds mux2.exe, mux2d.exe, mux2-verify.exe; EXE is cmux-tui.exe; the
# corpus is gen-corpus.pl's output (plain.txt and sgr.txt are used).
# The program every throughput run uses is `mux2-verify --cat FILE`: it
# waits for one line, then writes the file to its console in 1 MiB writes,
# so both servers see identical conhost output; one run uses cmd's `type`. A viewer runs inside a terminal of a second
# mux2 server (its own socket), as a console program would.
param([string]$Mux2, [string]$Ctui, [string]$Corpus, [string]$Test = 'all', [int]$N = 50,
      [int]$Scale = 500, [int]$Reps = 1)
$ErrorActionPreference = 'Continue'
$M = "$Mux2\mux2.exe"
$Cat = "$Mux2\mux2-verify.exe"
$HostSock = Join-Path ([IO.Path]::GetTempPath()) 'mux2-viewer-host.sock'
$IdleArgv = @('cmd.exe', '/d', '/k')

function Emit($h) { [pscustomobject]$h | ConvertTo-Json -Compress }
function Out($exe, [string[]]$a) { (& $exe @a 2>&1 | ForEach-Object { "$_" }) -join "`n" }
function P($xs, $f) { $s = $xs | Sort-Object; [math]::Round($s[[int][math]::Floor($f * ($s.Count - 1))], 2) }
function Ms($sw) { $sw.Elapsed.TotalMilliseconds }

function ServerPid($kind) {
    $p = if ($kind -eq 'mux2') {
        # The viewer host is a second mux2d; the bench server is the other one.
        Get-CimInstance Win32_Process -Filter "Name='mux2d.exe'" | Where-Object { $_.ProcessId -ne $script:HostPid }
    } else {
        Get-CimInstance Win32_Process -Filter "Name='cmux-tui.exe'" | Where-Object { $_.CommandLine -match '--headless --session bench' }
    }
    ($p | Sort-Object ProcessId | Select-Object -First 1).ProcessId
}

# Memory and CPU of the server and every process below it except the payload
# programs (cmd.exe and the cat program): conhost per terminal, helpers.
function Footprint($kind) {
    $root = ServerPid $kind
    $all = Get-CimInstance Win32_Process
    $kids = @{}; foreach ($p in $all) { $kids[[int]$p.ParentProcessId] += @($p) }
    $byId = @{}; foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
    $tree = @(); $stack = @([int]$root)
    while ($stack.Count) { $id = $stack[-1]; $stack = @($stack | Select-Object -SkipLast 1)
        if ($byId[$id]) { $tree += $byId[$id]
            # Windows reuses process ids: a child must be younger than its parent.
            foreach ($k in $kids[$id]) { if ($k.CreationDate -ge $byId[$id].CreationDate) { $stack += [int]$k.ProcessId } } } }
    $srv = $byId[[int]$root]
    $helpers = $tree | Where-Object { $_.ProcessId -ne $root -and $_.Name -notin @('cmd.exe', 'mux2-verify.exe') }
    $sp = Get-Process -Id $root
    @{ server_pid = $root; server_ws_kb = [int]($srv.WorkingSetSize / 1KB); server_private_kb = [int]($srv.PrivatePageCount / 1KB)
       server_cpu_s = [math]::Round($sp.TotalProcessorTime.TotalSeconds, 3)
       helper_procs = @($helpers).Count; helper_kinds = (@($helpers | ForEach-Object Name | Sort-Object -Unique) -join ',')
       helper_ws_kb = [int](($helpers | Measure-Object WorkingSetSize -Sum).Sum / 1KB)
       helper_private_kb = [int](($helpers | Measure-Object PrivatePageCount -Sum).Sum / 1KB)
       helper_cpu_s = [math]::Round((($helpers | ForEach-Object { (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue).TotalProcessorTime.TotalSeconds }) | Measure-Object -Sum).Sum, 3) }
}

function UsedMb { $os = Get-CimInstance Win32_OperatingSystem; [int](($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1KB) }

function StopAll {
    & $M stop 2>$null | Out-Null
    Get-Process cmux-tui, cmux-tui-host -ErrorAction SilentlyContinue | Stop-Process -Force
    # cmux-tui journals every terminal's output and restores it at start
    # (5 GB after the throughput runs): every test starts from a clean state.
    Remove-Item -Recurse -Force "$env:LOCALAPPDATA\cmux-tui\sessions" -ErrorAction SilentlyContinue
    Get-Process mux2d -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $script:HostPid } | Stop-Process -Force
}

function Start-Server($kind) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($kind -eq 'mux2') { & $M stats | Out-Null }
    else {
        # Start-Process: the daemon would hold a captured pipe open forever.
        $p = Start-Process -FilePath $Ctui -ArgumentList '--session', 'bench', 'daemon', 'ensure' -NoNewWindow -PassThru `
            -RedirectStandardOutput "$env:TEMP\ens.out" -RedirectStandardError "$env:TEMP\ens.err"
        $p.WaitForExit()
    }
    Ms $sw
}

function New-Term($kind, [string[]]$prog, $label, $size = '80x24') {
    if ($kind -eq 'mux2') { return (Out $M (@('new', '--size', $size, '--') + $prog)).Trim() }
    $o = Out $Ctui (@('--session', 'bench', '--json', 'workspace', 'create', '--name', $label, '--') + $prog)
    $t = try { ($o | ConvertFrom-Json).value.terminal_id } catch { $null }
    if (-not $t) { throw "cmux-tui create: $o" }
    $t
}
function Write-Term($kind, $id, $text) {
    if ($kind -eq 'mux2') { & $M write $id $text | Out-Null }
    else { & $Ctui --session bench terminal $id write --text $text 2>&1 | Out-Null }
}
function Wait-Term($kind, $id) {
    if ($kind -eq 'mux2') { & $M wait $id | Out-Null }
    else { & $Ctui --session bench terminal $id process wait --timeout-ms 900000 2>&1 | Out-Null }
}
function Screen($kind, $id) {
    if ($kind -eq 'mux2') { Out $M @('screen', $id) } else { Out $Ctui @('--session', 'bench', 'terminal', $id, 'screen', 'read') }
}
function Kill-Term($kind, $id) {
    if ($kind -eq 'mux2') { & $M kill $id | Out-Null }
    else { & $Ctui --session bench terminal $id close 2>&1 | Out-Null }
}

function T-Start($kind) {
    StopAll
    $base = UsedMb
    $ms = Start-Server $kind
    Start-Sleep 2
    $fp = Footprint $kind
    Emit (@{ test = 'start'; kind = $kind; start_to_ready_ms = [math]::Round($ms, 1); system_used_mb_delta = (UsedMb) - $base } + $fp)
}

function T-Scale($kind) {
    StopAll; Start-Server $kind | Out-Null; Start-Sleep 1
    $base = UsedMb; $fp0 = Footprint $kind; $lat = @()
    for ($i = 1; $i -le $Scale; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try { $id = New-Term $kind $IdleArgv "s$i" } catch { $id = "$_" }
        if ($id -notmatch '^(\d+|term_[0-9a-f]+)$') { Emit @{ test = 'scale'; kind = $kind; event = 'refused'; at = $i; error = "$id" }; break }
        $lat += Ms $sw
        if ($i -in 1, 10, 50, 100, 200, 300, 400, 500, 750, 1000 -or $i -eq $Scale) {
            Start-Sleep 2
            $fp = Footprint $kind
            $cpu0 = $fp.server_cpu_s + $fp.helper_cpu_s; Start-Sleep 10; $f2 = Footprint $kind
            $idle = [math]::Round(100 * (($f2.server_cpu_s + $f2.helper_cpu_s) - $cpu0) / 10, 3)
            Emit (@{ test = 'scale'; kind = $kind; n = $i; create_cli_ms_p50 = (P $lat .5); create_cli_ms_p95 = (P $lat .95)
                     system_used_mb_delta = (UsedMb) - $base
                     server_private_kb_per_term = [int](($fp.server_private_kb - $fp0.server_private_kb) / $i)
                     tree_private_kb_per_term = [int](($fp.server_private_kb + $fp.helper_private_kb - $fp0.server_private_kb - $fp0.helper_private_kb) / $i)
                     tree_ws_kb_per_term = [int](($fp.server_ws_kb + $fp.helper_ws_kb - $fp0.server_ws_kb - $fp0.helper_ws_kb) / $i)
                     idle_cpu_pct = $idle } + $fp)
        }
    }
    StopAll
}

# A viewer attached to terminal $id, running inside a terminal of the
# viewer-host server. Returns the host terminal id.
function Start-Viewer($kind, $id) {
    $env:MUX2_SOCKET = $HostSock
    $view = if ($kind -eq 'mux2') { "set MUX2_SOCKET=&& `"$M`" attach $id" }
            else { "`"$Ctui`" attach --session bench --terminal $id" }
    $h = (Out $M @('new', '--size', '200x50', '--', 'cmd.exe', '/d', '/c', $view)).Trim()
    Remove-Item Env:\MUX2_SOCKET
    Start-Sleep 2
    $h
}
function Stop-Viewer($h) { $env:MUX2_SOCKET = $HostSock; & $M kill $h | Out-Null; Remove-Item Env:\MUX2_SOCKET }

function T-Tput($kind, $file, [switch]$Attach, [switch]$Type) {
    # -Type: cmd's own `type`, a program as users run it, instead of the cat program.
    $prog = if ($Type) { @('cmd.exe', '/d', '/c', "set /p go= & type $file") } else { @($Cat, '--cat', $file) }
    $id = New-Term $kind $prog "tp$(Get-Random)" '200x50'
    Start-Sleep 1
    $h = if ($Attach) { Start-Viewer $kind $id }
    $fp0 = Footprint $kind
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Term $kind $id "`r"
    Wait-Term $kind $id
    $s = $sw.Elapsed.TotalSeconds
    $fp = Footprint $kind
    if ($Attach) { Stop-Viewer $h }
    Kill-Term $kind $id
    $bytes = (Get-Item $file).Length
    Emit @{ test = 'tput'; kind = $kind; file = (Split-Path $file -Leaf); attach = [bool]$Attach; program = $(if ($Type) { 'type' } else { 'cat' }); bytes = $bytes
            seconds = [math]::Round($s, 3); mb_per_s = [math]::Round($bytes / $s / 1e6, 1)
            server_cpu_s = [math]::Round($fp.server_cpu_s - $fp0.server_cpu_s, 2)
            helper_cpu_s = [math]::Round($fp.helper_cpu_s - $fp0.helper_cpu_s, 2); server_ws_kb_after = $fp.server_ws_kb }
}

function T-Rtt($kind) {
    $id = New-Term $kind @('cmd.exe', '/d', '/q', '/k') "rt$(Get-Random)"
    Start-Sleep 1
    $rd = @(); $rt = @()
    for ($i = 1; $i -le $N; $i++) {
        # Not $m: PowerShell names ignore case, and $M is the mux2 path.
        $mark = 'M{0:d5}X' -f $i
        $sw = [Diagnostics.Stopwatch]::StartNew(); Screen $kind $id | Out-Null; $rd += Ms $sw
        $sw.Restart(); Write-Term $kind $id "$mark`r"
        while ((Screen $kind $id) -notmatch $mark) {}
        $rt += Ms $sw
    }
    Kill-Term $kind $id
    Emit @{ test = 'rtt'; kind = $kind; n = $N; screen_read_cli_ms_p50 = (P $rd .5); write_to_visible_cli_ms_p50 = (P $rt .5)
            write_to_visible_cli_ms_p95 = (P $rt .95) }
}

# The viewer host: a second mux2 server on its own socket.
$env:MUX2_SOCKET = $HostSock; & $M stats | Out-Null
$script:HostPid = [int]((Out $M @('stats')) -split "`n" | Where-Object { $_ -match '^pid' } | ForEach-Object { ($_ -split "`t")[1] })
Remove-Item Env:\MUX2_SOCKET

foreach ($kind in 'mux2', 'cmux-tui') {
    if ($Test -in 'all', 'start') { T-Start $kind }
    if ($Test -in 'all', 'scale') { T-Scale $kind }
    if ($Test -in 'all', 'tput', 'rtt') {
        StopAll; Start-Server $kind | Out-Null
        if ($Test -in 'all', 'rtt') { T-Rtt $kind }
        if ($Test -in 'all', 'tput') {
            for ($r = 0; $r -lt $Reps; $r++) {
                foreach ($f in 'plain', 'sgr') {
                    T-Tput $kind "$Corpus\$f.txt"
                    T-Tput $kind "$Corpus\$f.txt" -Attach
                }
            }
            # cmd's type is slow (about 1 MB/s through either ConPTY): 16 MB of it.
            if ($Test -eq 'all') {
                $small = "$Corpus\plain-16m.txt"
                if (-not (Test-Path $small)) {
                    $src = [IO.File]::OpenRead("$Corpus\plain.txt"); $dst = [IO.File]::Create($small)
                    $buf = New-Object byte[] (16MB); $n = $src.Read($buf, 0, $buf.Length); $dst.Write($buf, 0, $n)
                    $src.Close(); $dst.Close()
                }
                T-Tput $kind $small -Type
            }
        }
    }
    if ($kind -eq 'mux2' -and $Test -in 'all', 'rtt') {
        StopAll
        Emit @{ test = 'api'; kind = 'mux2'; create = (Out $M @('bench', 'create', '100')); echo = (Out $M @('bench', 'echo', '500'))
                write_to_visible = (Out $M @('bench', 'rtt', '200')) }
    }
}
StopAll
$env:MUX2_SOCKET = $HostSock; & $M stop | Out-Null; Remove-Item Env:\MUX2_SOCKET

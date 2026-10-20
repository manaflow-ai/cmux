# mux2 goal: 10x Rex on every metric, with exact correctness

Set 2026-10-16. Baselines are Rex Beta build 1203 (server `88fd41cc`) and
cmux-tui `2fcf8b55`, measured on an M6 Mac mini (cmux20/cmux21, 12 cores,
16 GB, macOS 27.0). The harness is `bench/` in this crate.

## Correctness comes first

A speed result counts only when the same run passes `mux2-verify`:

- the server's terminal, a client rebuilt from SNAPSHOT plus OUTPUT, and a
  reference terminal that parsed the bytes the PTY must have produced give
  the same screen text and the same canonical replay;
- every PTY byte is parsed, in order. Batching is allowed only while no
  client watches, and a batch is flushed before any read or state change
  (screen, replay, attach, resize, exit) and at once for any query a program
  waits on;
- query replies (DA, DSR/CPR, DECRQM, XTVERSION, OSC color queries) are
  answered with no added delay;
- a slow client is resynced with a snapshot, never left with a gap.

No metric may be bought by skipping, approximating or dropping terminal
state.

## Metrics

"Bound" is the physical limit no multiplexer can pass on this machine. Where
the bound is below 10x Rex, the target is the bound.

| # | Metric | Rex | cmux-tui | 10x target | Bound | Target |
|---|---|---|---|---|---|---|
| 1 | Create a terminal, CLI (p50) | 11.3 ms | 53 ms | 1.13 ms | exec of a small signed binary + fork/exec of the child | 1.13 ms |
| 2 | Create a terminal, API over one connection (p50) | measure | measure | Rex / 10 | fork + exec of the child | Rex / 10 |
| 3 | Server memory per extra idle terminal | 132 KB | 9.5 MB incl. helper | 13 KB | libghostty page allocation for one screen | 13 KB |
| 4 | System memory per extra terminal, minus the payload process | measure | measure | Rex / 10 | kernel PTY + tty buffers | min(Rex / 10, bound) |
| 5 | Empty server memory (RSS) | 37.6 MB | 50 MB | 3.8 MB | | 3.8 MB |
| 6 | Server start to ready | measure | measure | Rex / 10 | | Rex / 10 |
| 7 | Throughput, 256 MB plain text, no client | 449 MB/s | 69 MB/s | 4.5 GB/s | PTY read rate (measure) | the bound |
| 8 | Throughput, 256 MB SGR-colored text, no client | 216 MB/s | 45 MB/s | 2.2 GB/s | PTY rate or libghostty parse rate | the bound |
| 9 | Throughput with one attached client | Rex attach is view-only | 45 MB/s | Rex GUI / 10 | as 7 | the bound |
| 10 | Server CPU per 256 MB colored stream | 1.19 s | about 4.0 s | 0.12 s | exact parsing of every byte | parse cost only |
| 11 | Screen read, CLI (p50) | 11.9 ms | 3.7 ms | 1.19 ms | small binary exec | 1.19 ms |
| 12 | Write to visible on screen, CLI (p50) | 23.7 ms | 18.6 ms | 2.37 ms | two small execs | 2.37 ms |
| 13 | Write to visible, API (p50) | measure | measure | Rex / 10 | PTY echo latency | Rex / 10 |
| 14 | Server idle CPU with 500 terminals | 0.2 % | 0 % | 0.02 % | | 0.02 % |
| 15 | Attach to a terminal with a full screen, time to first frame | measure | measure | Rex / 10 | | Rex / 10 |
| 16 | Most terminals | 998 | 998 | 9,980 | macOS `kern.tty.ptmx_max` maximum 999 | 998 (bound) |
| 17 | Processes per terminal beyond the program | 0 | 1 | 0 | | 0 |
| 18 | Server binary size (arm64) | about 45 MB | about 40 MB | 4.5 MB | | 4.5 MB |
| 19 | Client binary size (arm64) | same binary as server | same binary | | | under 1 MB |

Metrics 7, 8, 16 and probably 4 cannot reach 10x Rex on macOS. Rex is
already at or near the kernel limit there; mux2 must reach the limit.

## Design

- One `mux2d` process per user, one thread, one kqueue. No helper process
  and no thread per terminal.
- Terminals are spawned with `posix_openpt` + `posix_spawnp`
  (`POSIX_SPAWN_SETSID`, the slave opened by path as fd 0, default signals,
  empty mask, `POSIX_SPAWN_CLOEXEC_DEFAULT`). On macOS a session leader
  acquires the first tty it opens as its controlling terminal;
  `mux2-ctty-probe` checks it. posix_spawn costs 66 µs against 416 µs for
  fork, and does not grow with the server's memory.
- Upgrade in place (`mux2 upgrade`): the server writes every terminal's
  snapshot, size, input queue and pid to a 0600 state file, keeps the PTY
  and listening descriptors across exec, and execs the new binary with
  `--resume`. The pid does not change, so programs stay its children and
  exit codes still arrive. `bench/upgrade-test.sh` is the gate: replay and
  screen must be byte-identical across the upgrade.
- Binary length-prefixed frames on a Unix socket. Terminal output is sent as
  raw bytes; attach is SNAPSHOT (libghostty replay) then the exact stream.
- VT parsing is batched while unwatched (1 MiB batches) with the flush rules
  above.
- `mux2` is a separate small client binary; it starts the server on demand
  and waits on a readiness pipe, not a timer.

Next steps, each gated on `mux2-verify`: idle scrollback compression with
`ghostty_terminal_compress`, Linux (epoll), and the GUI client path.

## Measured bounds (2026-10-16, cmux20)

- Starting any process: `/usr/bin/true` takes 0.99 ms (p50). Every CLI
  metric (1, 11, 12) has this floor, so 10x Rex is below the floor for
  metric 1 (1.13 ms) and at the floor for 11 and 12. The `mux2` round trip
  (`mux2 stats`) is 1.38 ms.
- PTYs: `kern.tty.ptmx_max` accepts at most 999 (1024 is rejected), so no
  macOS multiplexer can hold more than 998 terminals beside one other PTY.
- Raw libghostty-vt parse, 16 KiB writes: plain text 1,804 MB/s, SGR text
  423 MB/s, Unicode 152 MB/s, cursor/erase mix 67 MB/s. The ghostty-vt Rust
  wrapper (shared with cmux-tui) runs at 95, 72, 51 and 34 MB/s: this, not
  the PTY, limits throughput today.

## Results (6904161e, M6 minis; throughput on cmux21, the rest on cmux20)

| # | Metric | Rex | cmux-tui | mux2 | vs Rex | Bound |
|---|---|---|---|---|---|---|
| 1 | Create, CLI, `sleep` payload (p50) | 11.3 ms | 53 ms | 2.2 ms | 5.1x | exec floor 0.99 ms + spawn |
| 1 | Create, CLI, login shell (p50) | 20.5 ms | 61.9 ms | 2.7 ms | 7.6x | |
| 2 | Create, API (p50) | | | 0.24 ms | | |
| 3 | Server memory per terminal, login shell | 211 KB | 320 KB + 7 MB helper | 34 KB | 6.2x | |
| 4 | System memory at 200 shells | 590 MB | 750 MB | 325 MB | 1.8x | zsh itself, ~3.2 MB each |
| 5 | Empty server RSS | 37.6 MB | 50 MB | 2.0 MB | 19x | |
| 6 | Server start to ready | 36 ms | 64 ms | 6.3 ms | 5.7x | |
| 7 | Throughput, plain, no client | 389-450 MB/s | 69 MB/s | 454 MB/s | 1.0-1.2x | PTY round trip |
| 8 | Throughput, SGR, no client | 221 MB/s | 45 MB/s | 266 MB/s | 1.2x | parse 278 MB/s per terminal |
| 9 | Throughput, plain, client attached | 155 MB/s | 69 MB/s | 368 MB/s | 2.4x | |
| 9 | Throughput, SGR, client attached | 106 MB/s | 45 MB/s | 173 MB/s | 1.6x | |
| 10 | Server CPU, 256 MB SGR | 1.18 s | 3.53 s | 1.57 s | 0.75x | parse cost |
| 11 | Screen read, CLI (p50) | 11.8 ms | 3.7 ms | 1.5 ms | 7.9x | exec floor 0.99 ms |
| 12 | Write to visible, CLI (p50) | 23.7 ms | 18.4 ms | 3.0 ms | 7.9x | two execs |
| 13 | Write to visible, API (p50) | | | 16.7 µs | | |
| 14 | Idle CPU, 500 terminals | 0.2 % | 0 % | 0 % | | |
| 16 | Most terminals | 998 | 998 | 998 | bound | `ptmx_max` 999 |
| 17 | Processes per terminal beyond the program | 1 (`login`) | 1 (helper) | 0 | | |
| 18 | Server binary | 89 MB universal | 80 MB universal | 2.0 MB arm64 | 22x (one arch) | |
| 20 | Query reply, CPR (p50, warm) | 11.9 µs | | 5.0 µs | 2.4x | PTY round trip |
| 21 | Upgrade keeping every terminal | not offered | helper processes | in place, same pid | | |

ghostty-vt wrapper parse rate (shared with cmux-tui), 16 KiB writes:
plain 95 -> 1,538 MB/s, SGR 72 -> 278, Unicode 51 -> 111, cursor mix
34 -> 54; raw libghostty 1,814 / 424 / 154 / 66. `-Dcpu=native` makes no
difference.

Concurrent floods, N terminals each `cat` 256 MB at once, no viewers
(`bench/multi.sh`, cmux21):

| N | Payload | mux2 aggregate | Rex aggregate | mux2 server CPU | Rex server CPU |
|---|---|---|---|---|---|
| 1 | plain | 370 MB/s | 450 MB/s | 0.69 s | 0.58 s |
| 4 | plain | 372 MB/s | 226 MB/s | 2.7 s | 15.6 s |
| 8 | plain | 367 MB/s | 148 MB/s | 5.6 s | 56.9 s |
| 1 | SGR | 162 MB/s | 222 MB/s | 1.58 s | 1.17 s |
| 4 | SGR | 162 MB/s | 204 MB/s | 6.3 s | 17.0 s |
| 8 | SGR | 154 MB/s | 134 MB/s | 13.3 s | 61.6 s |

With parse workers (unwatched batches parsed off the event loop, one
worker per terminal's batches, `MUX2_PARSE_WORKERS`; unfinished CSI tails
carried to the next read):

| N | Payload | mux2 aggregate | vs Rex | mux2 server CPU | vs Rex CPU |
|---|---|---|---|---|---|
| 1 | plain | 454 MB/s | 1.0x | 0.74 s | |
| 1 | SGR | 266 MB/s | 1.2x | 1.77 s | |
| 4 | plain | 455 MB/s | 2.0x | 3.0 s | 5.2x less |
| 4 | SGR | 312 MB/s | 1.5x | 7.4 s | 2.3x less |
| 8 | plain | 448 MB/s | 3.0x | 6.1 s | 9.4x less |
| 8 | SGR | 312 MB/s | 2.3x | 14.8 s | 4.2x less |

Rex runs one reader thread per PTY that spins before blocking; with
several busy terminals the threads compete and its throughput falls while
its CPU use grows tenfold. mux2 stays flat on its one thread. The next
lever is sharding terminals across one event loop per core (each terminal
stays on one thread, so its parse order is unchanged).

The kernel bounds parallel PTY output: N raw `script -q /dev/null cat`
pipelines with no multiplexer move 272 MB/s (N=1), 347 MB/s (N=4) and
155 MB/s (N=8) in aggregate on cmux20. mux2's 367 MB/s at N=8 is at that
bound for plain text, so sharding terminals across cores can only help
parse-bound (SGR) floods.

Open: an upgrade keeps everything libghostty's replay carries (screen,
scrollback, modes, title, pwd, colors, mouse format) but not the wrapper's
prompt-semantic tracker state (which rows are prompt or input, saved
alternate-screen modes); cmux-tui's own replays share this limit.

Unwatched batches are parsed on worker threads while the event loop keeps
reading; a terminal's batches go to one worker in order, and any access to
a terminal's state first waits for its batches. `mux2-verify --no-viewer`
checks that path: the whole stream unwatched, then the final state.

Rex starts shells through `login -fp` (as Terminal.app does), which writes
login records; mux2 runs `$SHELL -l` directly.

## Windows (2026-10-19, GCP n2d-standard-8, Windows Server 2025 build 26100)

Rex has no Windows build, so on Windows mux2 is held to its own gate, to
cmux-tui (`2fcf8b55`'s successor on this branch, release build, same VM),
and to Rex's macOS numbers above. Harness: `bench/windows-bench.ps1`,
`bench/windows-gate.ps1`, `bench/windows-conpty.ps1`.

### Design

- One process, one event-loop thread, one IO completion port for every
  terminal and client. The request handling and the correctness rules are
  the Unix server's; the parse workers, query scanner and client are shared
  (`src/shared`).
- A terminal is a pseudoconsole from `CreatePseudoConsole` (resize-quirk
  and passthrough flags; no WIN32_INPUT_MODE, so clients write plain VT
  input), its two pipes named pipes opened overlapped on the server side,
  and its program in a job object (kill on close), so the program tree ends
  with the terminal and with the server.
- Every pipe and socket is a `Slot` with one read and one write in flight.
  With `FILE_SKIP_COMPLETION_PORT_ON_SUCCESS` an operation that completes
  at once is handled inline, so a busy pipe drains through back-to-back
  synchronous reads and only a read that waits posts a packet. Reads are
  double-buffered (the next read is issued before the filled buffer is
  parsed) and grow from 4 KiB to 256 KiB while a pipe stays full.
- Child exit: a thread-pool wait posts to the port. conhost keeps the output
  pipe open after the child exits, so the server closes the pseudoconsole
  (on its own thread: the close can wait for the last frame) and sends EXIT
  only when the pipe ends: a waiter sees every byte.
- conhost's start is most of a create, so one spare pseudoconsole is made
  ahead of time on a helper thread (`MUX2_SPARE_CONSOLES`, default 1).
- `conpty.dll` next to `mux2d.exe` (or `MUX2_CONPTY_DLL`) is used instead of
  the system's: Windows Terminal's out-of-band ConPTY with its
  `OpenConsole.exe` (MIT, NuGet `Microsoft.Windows.Console.ConPTY`
  1.25.260930003). portable-pty, and so cmux-tui, loads it the same way.
- Not on Windows yet: upgrade in place; `mux2 attach` sends its size once.
- conhost's output pipe has a 1 MiB quota (`MUX2_PIPE_BUFFER`): against
  128 KiB, Windows Terminal's ConPTY moves 210 vs 172 MB/s plain and 78 vs
  61 MB/s SGR (3 runs each); the system ConPTY does not change (11 MB/s,
  even at 4 KiB).
- Not built: one reader thread per terminal. The server's own CPU is a
  small part of every run (below), so the read path is not the limit;
  conhost is.

### What ConPTY means for exactness

The server reads conhost's output, not the program's. The system conhost
renders its own buffer and sends what changed. Its final screen matched
the file for plain, SGR and cursor text at 200x50 (not Unicode), and the
whole state (scrollback) never did. The passthrough flag is accepted and
changes nothing measurable on build 26100 (flags 0x6, cmux-tui's, and 0xa,
ours: 8.4-8.6 MB/s either way). Windows Terminal's ConPTY passes the bytes
through: screen and whole state matched the file for all four corpora.
The system conhost answers DSR/CPR and DA itself: of 100 CPR and 100 DA
queries the server saw none, so the replies a program gets there are
conhost's, about its own buffer. Windows Terminal's ConPTY forwards every
query (the server saw all 100 and 101) and the server's libghostty
answers, as on Unix. `mux2-query-probe` checks every reply either way.

So the Windows gate checks the server and the client against a reference
that parsed exactly the bytes the server read (`MUX2_TAP_DIR`, written by
the server only for the gate): every byte parsed in order, snapshot plus
stream exact, resync taken. With `-FileReference` (sideloaded ConPTY) it
also requires the file's own reference, as on Unix, which also proves that
nothing was lost before the tap.

### Results (mux2 this branch, cmux-tui same tree; medians of 3 for throughput; WT ConPTY = Windows Terminal's, 1 MiB pipe for mux2)

| # | Metric | cmux-tui, system ConPTY | mux2, system ConPTY | cmux-tui, WT ConPTY | mux2, WT ConPTY | Rex (macOS) |
|---|---|---|---|---|---|---|
| 1 | Create, CLI (p50) | 126 ms | 14.3 ms | 121 ms | 14.6 ms | 11.3 ms |
| 2 | Create, API (p50) | | 2.7-9.8 ms | | 3.7-7.5 ms | |
| 3 | Server memory per terminal, working set (500 terminals) | 229 KB | 48 KB | | | 132 KB (RSS) |
| 3 | Server memory per terminal, committed (private bytes) | 1.9 MB | 1.6 MB | 2.0 MB | 1.6 MB | |
| 3 | All processes per terminal, committed (minus program) | 7.2 MB | 2.8 MB | 8.3 MB | 3.8 MB | 211 KB |
| 4 | System memory at 500 terminals | 2,645 MB | 1,132 MB | | | 590 MB at 200 |
| 5 | Empty server, working set | 30 MB | 6.0 MB | 31 MB | 6.1 MB | 37.6 MB |
| 6 | Server start to ready | 297 ms | 28 ms | 267 ms | 28 ms | 36 ms |
| 7 | Throughput, plain, no client | 10.3 MB/s | 11.0 MB/s | 110 MB/s | 210 MB/s | 449 MB/s |
| 8 | Throughput, SGR, no client | 9.1 MB/s | 8.4 MB/s | 46 MB/s | 77.9 MB/s | 216 MB/s |
| 9 | Throughput, plain, client attached | 10.7 MB/s | 10.9 MB/s | 114 MB/s | 164 MB/s | 155 MB/s |
| 9 | Throughput, SGR, client attached | 8.1 MB/s | 8.5 MB/s | 42.6 MB/s | 69.4 MB/s | 106 MB/s |
| 10 | Server CPU, 256 MB SGR, no client | 10-41 s | 3.8 s | 2.4-3.9 s | 3.6 s | 1.18 s |
| | `type` of 16 MB (cmd) | 0.6 MB/s, 51-75 s CPU | 0.9 MB/s, 1.0-1.5 s CPU | 0.6 MB/s | 1.0 MB/s | |
| 11 | Screen read, CLI (p50) | 17 ms | 10 ms | 17 ms | 9.9 ms | 11.8 ms |
| 12 | Write to visible, CLI (p50) | 46 ms | 23 ms | 46 ms | 23 ms | 23.7 ms |
| 13 | Write to visible, API (p50) | | 1.7 ms | | 1.7-2.0 ms | |
| | Keystroke echo at a viewer, API (p50) | | 10 ms | | 0.07 ms | 22 µs (mux2, macOS) |
| 14 | Idle CPU, 500 terminals (incl. conhosts) | 1.25 % | 0 % | | | 0.2 % |
| 17 | Processes per terminal beyond the program | 2 (host + conhost) | 1 (conhost) | 2 | 1 (OpenConsole) | 1 |
| 20 | Query reply, CPR (p50, in-terminal) | | 46-63 µs (conhost answers) | | 95-117 µs (mux2 answers) | 11.9 µs |

The floor for every CLI metric is starting a process: a small program that
exits at once takes 7.8 ms (p50) on this VM against 0.99 ms on the M6 mini,
so CLI create (14 ms) is the floor plus the create. The system ConPTY
bounds throughput (11 MB/s plain): mux2's server spends 2 s of CPU per
256 MB there. Windows Terminal's ConPTY raises the bound 15-20x; mux2 is
then 1.7-1.9x cmux-tui with no viewer and 1.4-1.6x with one, and beats
Rex's macOS numbers with a viewer attached for plain text (164 vs 155
MB/s). The keystroke echo
of the system conhost is about 10 ms whatever the server does (its render
timer); Windows Terminal's ConPTY echoes in 0.1 ms. cmux-tui's high CPU
with the system ConPTY comes from its per-terminal journal and helper.

Memory: on Windows conhost or OpenConsole is a process per terminal of
1.2-2 MB committed, which no server can remove. mux2's own cost per idle
terminal is 48 KB of working set (34 KB RSS on macOS); the 1.6 MB it
commits per terminal is libghostty's reserved page memory, not touched
until used. The empty server commits 1.4 MB.

### Gate results (final binaries)

- System ConPTY, tap reference: 18/20. The two failures are
  `cursor --resize-midway` and `unicode --resize-midway`, client against
  server after a resize while output flows; both also fail on macOS and
  Linux on the parent commit (`a04f1fa2`), so they are not Windows-specific.
- Windows Terminal ConPTY, file reference (as strict as Unix): 16/20. The
  failures are the same two resize cases plus `cursor --attach-midway` and
  `cursor --slow-viewer`: the server's state equals the file's
  (`conpty_replay_faithful`), but a client rebuilt from a snapshot taken in
  the middle of the cursor corpus differs in replay. The same two cases fail
  on macOS and Linux at the parent commit (macOS: 15-17/20 per run), so the
  open problem is the snapshot (libghostty replay) of that corpus's state,
  not the Windows server. With the system ConPTY they pass, because conhost
  re-renders the exotic state away.
- `mux2-query-probe` (1000 CPR + 1000 DA): every reply correct on both.

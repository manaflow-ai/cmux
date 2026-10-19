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

## Network (TCP, 2026-10-18)

`MUX2_LISTEN=ADDR:PORT` adds a TCP listener for measurements across a
network (`src/net.rs`: one explicit address, never a wildcard; peers
limited to loopback and Tailscale ranges or `MUX2_LISTEN_ALLOW`;
unauthenticated, not a production transport). Clients use it with
`MUX2_CONNECT=ADDR:PORT`; `mux2-netbench` measures from the client side and
`mux2-verify` runs unchanged over it.

Every TCP socket sets `TCP_NODELAY` and keepalive (30 s idle, 10 s x 4);
the server also sets `TCP_NOTSENT_LOWAT` (32 KiB), so output waits in the
server's own queue, where a snapshot can replace it, not in a kernel send
buffer of megabytes. Queued frames leave in one `writev`.

A network viewer whose backlog would take more than 100 ms to drain at its
measured rate, and is more than twice the terminal's last snapshot, goes
stale: its unsent stream is dropped, nothing more is queued, and when its
queue drains it gets one snapshot of the state at that moment, then the
live stream. Unix-socket viewers keep the previous behavior.

Ctrl-C during a flood until the prompt is on the remote viewer (p50, 8
runs; "before" is the same TCP transport with Nagle on, no notsent mark and
only the 16 MiB resync):

| Path | Flood | Before | After |
|---|---|---|---|
| WAN shaped to 20 Mbit, 48 ms RTT | full-screen redraw (TUI) | 7.5 s | 71 ms |
| same | plain `cat` | 5.4 s | 0.61 s |
| same | SGR `cat` | 3.7 s | 1.5 s |
| home Wi-Fi to office mini over tailnet relay + ssh -L | TUI | 3.2 s | 127 ms |
| same | plain `cat` | 3.2 s | 1.5 s |
| same | SGR `cat` | 7.4 s | 2.0 s |

A keystroke in one pane while another pane floods on the same link (tailnet
path): p99 762 -> 298 ms. 64 MB SGR `cat` until the viewer has the final
state: 4.0 -> 1.4 s and 18.5 -> 12 MB on the wire (tailnet), 9.0 -> 3.1 s
and 21 -> 5 MB (20 Mbit). An idle keystroke echo is one segment each way and
takes one RTT in both. The plain and SGR floods are bounded by the size of
a snapshot with full scrollback (0.6 and 2 MB here); a full-screen program's
snapshot is about 11 KB.

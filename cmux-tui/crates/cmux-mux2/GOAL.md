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
- Terminals are spawned with fork + `TIOCSCTTY` + exec from the
  single-threaded server; fork is safe without other threads.
- Binary length-prefixed frames on a Unix socket. Terminal output is sent as
  raw bytes; attach is SNAPSHOT (libghostty replay) then the exact stream.
- VT parsing is batched while unwatched (1 MiB batches) with the flush rules
  above.
- `mux2` is a separate small client binary; it starts the server on demand
  and waits on a readiness pipe, not a timer.

Next steps, each gated on `mux2-verify`: upgrade survival by passing PTY
descriptors to a new server (SCM_RIGHTS), idle scrollback compression with
`ghostty_terminal_compress`, Linux (epoll), and the GUI client path.

# One timeline across every cmux process (`scripts/cmux-next/trace.py`)

Status: tool landed (cmux-4f PL-trace, 2026-10-23). Not a CI gate. Owner of the script: the Performance Lead.

The goal is a trace like Chrome's Perfetto traces. One command records a scenario, and one file shows
every cmux process on one time axis. With that file, "why did this lag" takes minutes to answer.

## What is in the trace

All sources use one clock: `CLOCK_UPTIME_RAW` (mach_absolute_time) in microseconds.

`log` stamps a signpost's `machTimestamp` with mach_continuous_time, which also counts the time the
host slept since boot (3 days on mac26 on 2026-10-24). `signposts.ndjson` starts with the difference
(`#continuous-minus-uptime-us`, read when `log stream` starts) and ends with it again; trace.py takes it
off every signpost. A file with no such line (an older recording) or with two different values (the host
slept during the recording) gives a `WARNING` in the summary.

| Source | How it is recorded | Where it shows |
|---|---|---|
| Stack samples, every process | `xctrace record --all-processes`, Time Profiler with os_signpost and Points of Interest (System Trace with `--system-trace`) | Nested slices (a flame chart over time) on the real thread: app main thread, Ghostty renderer and IO threads, Chromium threads, daemon, holder, terminal hosts, acpmux, CLI processes, WindowServer |
| cmux signposts | `log stream --signpost`, subsystem `com.cmuxterm.app.next`, every process | Tracks `signposts <category>` in the emitting process: `action.perform`, `action.commit`, `action.gate` (always on, also in Release), and the `stalls`, `tab-switch` and `pane-focus` debug timings |
| Main-thread stalls | The app watchdog (`debug.hangs`, threshold `--hang-ms`, default 8 ms), read every second by sequence number | Track `watchdog stalls` in the app: each stall with its CPU time and its main-thread stack sample (slice args) |
| Daemon spans | `CMUX_TUI_DEBUG_SPANS=<file>` set on the app (the daemon inherits it), followed with `tail -F` | Tracks in the daemon: one slice per request, with one child slice per mark (the gap before a mark is the cost of that step) |
| Chromium's own trace | CDP `Tracing.start` on the DevTools port that the Debug build opens with `CMUX_NEXT_CEF_EXTRA_SWITCHES=remote-debugging-port=N` | The browser process (the app pid), the GPU process and the renderers. Thread ids are mapped to the OS threads of the time profile by name (`CrBrowserMain` is the app main thread) |
| Scenario driver | trace.py itself | Process `scenario driver` (pid 0): every key sent, every CLI call of the storm, the scenario window |

The Chromium clock is checked with `Tracing.recordClockSyncMarker`. Chromium's `TimeTicks` on macOS is
mach time, so the offset is 0 unless the check shows otherwise; the summary prints the offset that it
used. xctrace times are relative to the start of the recording. trace.py aligns them by the same signposts,
which are in both recordings (begin events matched by name, the median offset, a spread below 2 ms). If
that is not possible, it uses the start date of the recording (about 1 ms error).

## How to record

Record on a fleet GUI host that passes `bench_launch.py check`, never on Lawrence's Mac:

```bash
nx-remote --needs gui --app-from-fleet cmux --tag trc --ref SHA --timeout 3600 -- bash -c '
  python3 scripts/cmux-next/bench_launch.py check --app "$NX_APP" --out "$NX_ARTIFACTS/check" &&
  python3 scripts/cmux-next/trace.py record --app "$NX_APP" --out "$NX_ARTIFACTS/trace" --scenario stress-storm --seconds 20'
```

The job's artifacts arrive in `artifacts/nx-remote/<job>/trace/`. The trace is `trace.json.gz`, and the
summary is `SUMMARY.txt` (also `summary.json`).

Scenarios:

- `stress-storm` (default): build STRESS (`perf-stress-session.py`: 60 workspaces, 14 panes x 6 tabs,
  Chromium, WebKit, chats, 10 busy terminals). Then, for `--seconds`:
  - a CLI storm at `--storm-hz` (default 10/s): workspace move to the top, task status, group add,
    status pill;
  - keys typed into the focused terminal every `--key-interval` (0.12 s) through `debug.key`, with the
    send time as the event timestamp, so that the action signposts carry an input age;
  - every `--chord-every` (10) keys, one action pair: Cmd-T/Cmd-W, Cmd-D/Cmd-W, or next/previous
    workspace (Ctrl-Cmd-] / Ctrl-Cmd-[).
- `light-storm`: the light session instead of STRESS (`perf-stress-session.py` `build_light`: a new
  workspace, shown, split once, with Chromium, Chromium, WebKit, agent chat and terminal tabs), plus
  4 background workspaces that the storm moves, tags, groups and pills. Then the same storm, typing and
  chords. A run whose storm has no target workspace says so (`WARNING` in the summary).
- Wrap mode, for scripts that launch their own app (the every-action sweep, `sidebar-churn-typing.py`).
  The recording runs while the command runs:
  ```bash
  trace.py record --bundle "$NX_APP" --out "$NX_ARTIFACTS/trace" --seconds-cap 900 -- \
    python3 scripts/cmux-next/every-action-sweep.py --app "$NX_APP" --tag trc --out "$NX_ARTIFACTS/sweep" --sessions stress --only splitRight,closeTab
  ```
  Wrap mode records the stack samples and the signposts only. The command builds its own app
  environment, so its app gets no DevTools port and no daemon spans. Add `--socket S` for the stall
  track. Keep the command short (`--only`), because an all-process recording grows by about 50 MB a
  second. The command runs in its own process group. On a timeout, an error or a signal, the command
  itself gets SIGTERM and time for its own teardown (the wrapper's `BenchApp.stop`, which quits its app
  with `debug.quit`, and `TagTeardown`). Only then does what is left of the group get SIGTERM, 15 s, and
  SIGKILL; then the bundle's tag teardown (pass `--bundle`) ends the daemons it left. When the
  recording is complete, the exit code is the command's own. A wrap run is labelled `wrap-key-unknown`:
  the command's app has its own environment, so trace.py cannot say whether its window was key.

trace.py signals only processes that it started. Its stop path ends the bundle's processes (the app's
quit and tag teardown, the wrap teardown, and a SIGKILL by exact PID after a stop that passed its bound).
So `record` refuses to start (`bundle-in-use`, exit 3) while any process of the bundle runs, in both
modes: another job's app or daemons of the same bundle, daemons that an earlier run left, or a person's
app. Quit them, or use a fresh tag.

The app under trace activates, and its window is key where the host allows it (`CMUX_NEXT_NO_ACTIVATE`
is removed, as `pane-perf-terminal.py` does). The window goes on the main screen at the STRESS size
(`place_window`). trace.py reads whether the window is key at the start of the window and again at its
end, and the summary prints both reads and where the window was placed. A run whose window was not key at
either read is labelled `<scenario>-inactive`; do not compare it with a key-window run. An app that
activates can take key status from another GUI job on a shared host, so record on a reserved host (the
perf-lead pool) when the numbers matter.

Options: `--system-trace` (thread states: why a thread was off CPU, and which stack blocked;
heavier), `--recorder sample` (no xctrace: `/usr/bin/sample` of the app and the daemon, aggregate stacks
in `sample-*.txt`, no flame timeline), `--no-cef`, `--hang-ms N`, `--keep` (leave the app running),
`--keep-recording` (keep `recording.trace` for Instruments; it is deleted by default because it is GBs).

`trace.py export DIR` builds `trace.json.gz` and the summary again from the raw files in DIR
(`signposts.ndjson`, `xctrace-*.xml`, `hangs.json`, `daemon-spans-stamped.jsonl`, `chromium-trace.json`,
`driver.json`, `processes.json`, `meta.json`). Use it after you change the merge. Each table is exported
to a `.part.xml` file and renamed only when xctrace exits 0, so an `xctrace-*.xml` file is always
complete. A table that does not parse (from an older trace.py) is skipped, and the summary names it.
`trace.py summary DIR` prints the summary again.

`trace.py --self-test` runs each check on its own and prints `ok` or `FAIL` for each: the parsers on
hand-written export shapes, the merge, the xctrace clock (a signpost match, a count mismatch that falls
back to the start date with a warning, the start date's precision, the recorder start), the
`debug.cef` validity, the stage bounds and errors, a source whose stop raises or hangs, a wrapped
command's process group, the export's part files, a bound that fires inside `perf-stress-session.py`'s
`wait()`, a SIGTERM during the export, one SIGINT only to xctrace, track ids that fit uint32, a CLI
process named `cmux` that is not the app, and signposts of a host that slept since boot (they land on
the stalls they happened with). It has no real xctrace export yet: the time-profile, os-signpost
and syscall columns are not checked against xctrace 15, 16, 26 or 27. The parsers key each cell by its
column's `<mnemonic>` from the table's `<schema>` (in column order), and fall back to the cell's element
tag. If the os-signpost columns differ, the clock falls back to the start date, and the summary prints a
`WARNING` with the columns that it saw. A table that the recording holds but that was not exported is
named in the summary (`xctrace tables not exported`).

### Stage bounds (no silent hours)

Each stage of a recording has a bound (`STAGE_BOUNDS_S` in trace.py): launch, STRESS or light build,
storm setup, recorders start, the window (`--seconds` + 92 s), the stop of each source (one stage per
source), the xctrace save, the app stop, the export and the build. A stage that runs longer than 60 s
prints `stage X still running after N s` once a minute. A stage that passes its bound prints
`STAGE X PASSED ITS BOUND`; a stage that raises an error (a CDP error, a socket timeout, a failed launch)
prints `STAGE X FAILED`. Either way, the stage's cleanup stops what it started (SIGKILL of that source's
process, the wrapped command's process group, or the app and the bundle's processes by exact PID; it drops
the DevTools connection), and the recording goes on to the next stage. Every recorder is held before its
process starts, so the stop path reaches it even when its start passed the bound. The trace and
`SUMMARY.txt` are always written; the summary lists `INCOMPLETE: stage(s) ...` and `ERROR: stage X
failed: ...` lines and the time of each stage. The exit code is 3. SIGTERM or SIGHUP stops every recorder
and the app, writes `SUMMARY.txt` without an export, and exits 128 + the signal. A signal during the
export or the build stops it at once, with the same exit code. `recording.trace` is deleted after the
export only when every table that trace.py reads was exported; otherwise it is kept, and the summary says
so, for `trace.py export DIR`.

`StageTimeout` is a `BaseException`, as `KeyboardInterrupt` is. The build stages spend most of their time
inside `perf-stress-session.py`'s `wait()`, which runs its predicate under `except Exception`; a timeout
that is an `Exception` was swallowed there, and the stage then ran for the sum of its inner timeouts.

A stage that owns processes or must finish a cleanup has a bound above the sum of its inner timeouts, so
it fires only when an inner timeout failed to. The build stages run hundreds of socket actions with 120 s
timeouts (a sum of hours) and own no process: their bound is about 2.5 times a measurement (the STRESS
build took 691 s on cmux-lawrence-2), and the light build's is estimated from the same rate. The bounds
catch a hung stage; they are not targets.

Job 7 (2026-10-23) shows why. Its STRESS build finished, and then the job printed nothing for over an hour.
Two causes: the all-process recording ran while the Chromium trace (then a 400 MB buffer with IPC
categories) transferred, and nothing reported progress. The recording now ends with the window, the Chromium
buffer is 128 MB without IPC categories, and every stage has a bound.

## Key-press flows

A terminal key press is followed across every process, on one clock (`CLOCK_UPTIME_RAW`, nanoseconds: the
app's signposts and `clock_gettime_nsec_np` in the Rust processes read the same mach time, so no offset is
guessed). The app mints a flow id for each key press (`TypingLatencyProbe`: the app's pid in the high 32 bits,
the press number below). Each hop records the id where a message carries it; otherwise it records its
terminal. `trace.py` joins the hops of one press and draws them as slices on `key flow` tracks, joined by
Perfetto flow arrows (JSON `bind_id` / `flow_out` / `flow_in`).

Turned on by `CMUX_NEXT_TRACE_FLOWS=<dir>` on the app, which `trace.py record --app` sets. The app strips every
inherited `CMUX*` variable that is not a `CMUX_NEXT_*` launch knob, so the daemon launch passes it on as
`CMUX_TRACE_FLOWS` (`DaemonDiagnosticKnobs`, also `CMUX_NEXT_TUI_DEBUG_SPANS` as `CMUX_TUI_DEBUG_SPANS`); the
terminal hosts and the holder inherit it from the daemon. Each of these processes calls `cmux_flow_trace::init()` at start (daemon `serve`, the
terminal host's `serve_terminal_host_process`, the holder's `serve`), which opens `<dir>/flows-<pid>.jsonl` and
starts the writer thread, so no hop opens a file or starts a thread. A hop never allocates, locks or enters
the kernel: off, it is one load of an unset `OnceLock` (test `cmux-flow-trace/tests/off.rs`); on, it reads the
clock (commpage) and its thread id and pushes a plain record (the terminal id as at most 32 bytes) into a fixed
ring of 8192 slots (test `tests/records.rs` counts the caller's allocations). The marks in the terminal host and
in the daemon's local-PTY path run before the writer and runtime locks. The writer drains the ring every 50 ms
while tracing is on, or when a hop finds it half full (the only wake a hop sends). A full ring drops records and
counts them (`flow records dropped` in the summary). The app's hops are `key.flow` signpost events.

| Hop | Process, thread | Carries |
|---|---|---|
| `app.key.dispatch` | app main (`CmuxApplication.sendEvent`, `debug.key`) | flow id, key age |
| `app.key.terminal` (optional: drawn when emitted, not needed for a complete press) | app main (`TerminalSurfaceView.keyDown`) | flow id |
| `app.io_write` | Ghostty IO thread (`io_write_cb`) | flow id |
| `app.send` | the same thread (`TerminalAttachment.enqueueInput`; the `send` request gets `flow`) | flow id |
| `daemon.send.write`, `daemon.send.written` | daemon `mux-control-dispatch` (`cmd_terminal_io::send`) | flow id |
| `host.pty.write` (host model) or `daemon.pty.write` (holder model: the daemon writes the PTY itself) | `terminal-host-client-input` / `mux-control-dispatch` | terminal |
| `host.pty.read` or `holder.pty.read` | `terminal-host-pty` / the holder's poll loop | terminal |
| `daemon.output.host` or `daemon.output.holder` | `surface-<id>-host` / `surface-<id>-reader` | terminal |
| `daemon.output.attach` | the same thread (`broadcast_attach_output`) | terminal |
| `app.output.decoded` | the attach socket's reader | flow id (the open press) |
| `app.output.received`, `app.output.parsed` | the output task (off the main actor), the Ghostty output lane (parse) | flow id |
| `app.frame.contents` | app main (`setContents:` of the terminal layer: Ghostty's frame) | flow id |
| `app.frame.commit` | app main (the run-loop end after it: the Core Animation commit to the screen) | flow id |

A hop with no flow id is placed by windows on the terminal the press was sent to. The presses on one terminal
are taken in send order; for each such hop, a press's window runs from the hop that causes it (the daemon's
`send.write` for a PTY write; the PTY write for the echo read; the read for the daemon's output; the output for
the attach) up to the next press's cause on that terminal, and no later than the press's own `app.output.decoded`.
The press takes the record only when its window holds exactly one and the press before placed its own record of
that hop. A window with none or two records, or one record while the press before found none (it may be that
press's late echo: keys typed faster than their echo), leaves the hop missing, and the summary names it
`ambiguous` with the reason. A record joins one press at most. So keys must go to a terminal whose only output is
their echo: `stress-storm` focuses a pane whose terminal is not one of the 10 busy ones. Presses that never reach
a terminal (no `app.key.terminal`, `app.io_write` or `app.send` hop: a chord the key router ran as an action) are
not flows. When the recording has flow records but nothing assembles, the summary says why (`WARNING` under
`Key-press flows`): no app `key.flow` signpost (the app's flow hops are not in the build), or no daemon record
carrying a press's flow id (the app's `send` request has no `flow`). The summary lists, per hop, the time since
the previous hop (p50/p95/max over complete presses), key to the echo frame's commit, and each incomplete
press with the hops it misses. `check-import` also checks that every flow arrow imports (`flow` table).

Limits: the frame's commit is the app's Core Animation commit. The display's own present (vsync) is later and
has no mark here. The probe follows one press at a time: a key typed before the last echo landed closes the
open press as unfinished (`--key-interval` keeps keys apart).

## How to open it

1. Go to https://ui.perfetto.dev and click "Open trace file", or drag `trace.json.gz` onto the page.
   The gzip file opens as it is.
2. The processes are sorted by role: `app`, `daemon`, `holder`, `terminal-host`, `acpmux`, `cef-gpu`,
   `cef-utility`, `cef-renderer`, `cli`, `windowserver`. `scenario driver` is at the top.
3. In the app process, the `signposts action` and `watchdog stalls` tracks come first, then
   `Main Thread`, then the other threads.

Keys: W/S zoom, A/D pan, click a slice for its args (stack, message), M marks the time range of a
selected slice on every track, and Ctrl/Cmd-click selects more than one track.

## How to read it

Answer "why did this lag" in this order:

1. Read `SUMMARY.txt`. It names the 5 longest main-thread stalls. For each stall it gives the time
   from the start of the window, the CPU time (busy, or waiting and on what), the action that was
   running, the watchdog's stack sample, the sampled frames inside the stall, and the Chromium tasks
   that ran on the main thread then. It also gives input to commit per action (p50/p95/max) and the
   cross-process waits.
2. In Perfetto, find the stall on `watchdog stalls` (or the action on `signposts action`) at that time.
   Select it and press M.
3. Look down the `Main Thread` track inside the marked range:
   - Slices without gaps mean the main thread was busy. The deepest wide slice is the cost.
   - A gap (no samples) means the main thread was off CPU. Look across the other processes in the same
     range: a daemon span that is open (the main thread waits on the daemon); Chromium GPU or renderer
     work (for example, a CATransaction commit that waits on a page's frame); WindowServer busy (a
     commit or a window operation); a lock (System Trace shows `Blocked: lock`).
4. `scenario driver` shows what caused it: the key or the CLI call right before.

Useful Perfetto SQL (Query tab):

```sql
-- The slowest action commits
select name, dur / 1e6 as ms, ts from slice where name like 'action.commit %' order by dur desc limit 20;
-- Main-thread frames by total time inside one window
select s.name, sum(s.dur) / 1e6 as ms from slice s join thread_track tt on s.track_id = tt.id
  join thread t using (utid) where t.name = 'Main Thread' and s.ts between X and Y group by s.name order by ms desc limit 30;
```

"Cross-process waits" in the summary:

- `stall:<class>`: watchdog stalls whose CPU time is less than half of their duration. The class comes
  from the stall's stack.
- `<class>` alone: `action.perform` runs during which the main thread was off CPU for 2 ms or more (no
  samples). The class comes from System Trace, from an overlapping stall, or else `unattributed`.

Classes: `lock` (mutex, unfair lock, dispatch_sync, semaphore), `daemon` (the app's daemon client),
`cef` (the Chromium pump and the shim), `windowserver` (Core Animation commit, SkyLight), `xpc`, `io`,
`ghostty`, `other`.

## Limits and open span requests

- Daemon spans cover the create paths only (workspace, pane, tab and terminal creates), and a span
  line has no clock. trace.py places a line by its arrival through `tail -F` (about 1 ms error) until
  the daemon writes `start_uptime_ns`; trace.py already reads that field. Requested from cmux-b6
  (PL-daemon), 2026-10-23: a span for every request, with `start_uptime_ns`, `tid` and the marks
  `parsed`, `dispatched`, `reply.queued` and `reply.sent`, only when the variable is set.
- The app has no signpost around its own daemon round trip (requested from PL-telemetry: category
  `daemon`, `method=<name> id=<request id>`). `cef.pump` and `cef.create_browser` are reserved but
  have no emitter (requested from PL-motion-cef). Without them, a Release trace attributes Chromium
  main-thread time only through the stack samples.
- The holder, the terminal hosts and acpmux have no spans. Only their sampled stacks show (requested
  through the cmux-4f lead from PL-holder and PL-acpmux).
- Time Profiler samples only threads that run. Off-CPU time shows as gaps. Use `--system-trace` for
  the reason (thread states with the blocking stack).
- The Chromium trace needs a Debug build of a development bundle (`CMUX_NEXT_CEF_EXTRA_SWITCHES` is
  `#if DEBUG`). A Release trace has every other source.
- The trace does not prove each page was Chromium. After the session is built, the summary prints
  `chromium valid` from `debug.cef`, with the check that STRESS uses (`cef_problems`): start state
  `ready`, `unavailable` and `fallback` null, no dev-server `web-dev.json`. Otherwise it lists the
  problems.

## Release trace ring v1

Status: spec (p09-observability-002, 2026-10-25). The Swift ring (p09 task 003), the Rust `cmux-trace` crate
(task 009) and the C writer `CEFShim/src/cmux_trace.h` write this format byte for byte; `trace.py` decodes it.
Each process keeps a crash-safe black box in Release and, while `trace.start` is on, a large recording ring.
A record holds catalog name ids and numbers only, never text.

Chrome reference: Perfetto's shared memory buffer (`src/tracing/core/shared_memory_abi.h`). Each thread's
`TraceWriter` owns one chunk at a time, so writers never contend, and a chunk that is still being written is
skipped, never shared. The phase codes are those of `base/trace_event/common/trace_event_common.h`
(`TRACE_EVENT_PHASE_*`).

### Clock

Every record is stamped in `CLOCK_UPTIME_RAW` nanoseconds on macOS (`clock_gettime_nsec_np`; the same clock as
`mach_absolute_time` and Chromium's `base::TimeTicks`), `CLOCK_MONOTONIC` on Linux and QPC nanoseconds on
Windows (header field `clock_domain`). In Swift, `TraceClock` (`CmuxNextTrace/TraceClock.swift`) is the only
reader:

| Source | Converter | Why it is exact |
|---|---|---|
| now | `clock.nowNanos()` | it is the clock |
| `NSEvent.timestamp`, `ProcessInfo.systemUptime` | `TraceClock.nanos(fromUptimeSeconds:)` | uptime seconds: the same clock |
| `CACurrentMediaTime()` | `TraceClock.nanos(fromMediaTime:)` | `mach_absolute_time` seconds: the same clock |
| `ContinuousClock.Instant` | `TraceClock.nanos(_:pairedWith: stamp)`, where `stamp = clock.continuousStamp()` was read when the instant was captured | `ContinuousClock` counts sleep, so its offset to uptime grows with every sleep: only a pair read at capture converts |

No converter takes a bare `ContinuousClock.Instant`: an offset read later is wrong by every sleep in between
(`TraceClockTests` injects a 10 s sleep). `SuspendingClock` is `CLOCK_UPTIME_RAW` on Darwin.

### Layout

All integers are little-endian (arm64 and x86-64). Offsets are bytes from the start of the ring (the mapped
file, or the heap buffer before the file exists; both have this layout). The regions, in order: the header
(256 bytes at 0), the name table, the thread table and the chunks (at a 16 KiB boundary). The header gives
each region's offset, so a decoder never computes one.

#### Header (256 bytes)

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 8 | `magic` | ASCII `CMXTRACE` |
| 8 | 4 | `version` u32 | 1 |
| 12 | 4 | `header_bytes` u32 | 256 |
| 16 | 4 | `pid` u32 | the writing process |
| 20 | 2 | `role` u16 | 1 app, 2 daemon, 3 holder, 4 terminal host, 5 acpmux, 6 Chromium host, 7 CLI |
| 22 | 1 | `ring_kind` u8 | 1 black box, 2 recording |
| 23 | 1 | `clock_domain` u8 | 1 `CLOCK_UPTIME_RAW`, 2 Linux `CLOCK_MONOTONIC`, 3 Windows QPC nanoseconds |
| 24 | 8 | `start_uptime_ns` u64 | the trace clock when the ring started |
| 32 | 8 | `start_unix_ns` u64 | the wall clock at the same moment: display and the 3-day cleanup only |
| 40 | 8 | `process_start_unix_us` u64 | the kernel's start time of `pid`: with `kill(pid, 0)`, cleanup tells a reused pid |
| 48 | 16 | `boot_session_uuid` | `kern.bootsessionuuid` as 16 bytes (Linux `boot_id`, Windows zero): uptime is valid within one boot only |
| 64 | 16 | `build_uuid` | `LC_UUID` of the main image (Linux: the first 16 bytes of the GNU build id; zero when none) |
| 80 | 32 | `build_version` | ASCII, NUL padded: version, build number and short commit |
| 112 | 4 | `chunk_bytes` u32 | 1024 |
| 116 | 4 | `chunk_count` u32 | a power of two |
| 120 | 8 | `chunks_offset` u64 | offset of chunk 0, a multiple of 16384 |
| 128 | 8 | `chunk_cursor` u64 | atomic: chunks claimed so far (the claim's `fetch_add`) |
| 136 | 8 | `name_table_offset` u64 | offset of name entry 0 |
| 144 | 4 | `name_capacity` u32 | name entries in the table |
| 148 | 4 | `name_cursor` u32 | atomic: name entries claimed |
| 152 | 8 | `thread_table_offset` u64 | offset of thread entry 0 |
| 160 | 4 | `thread_capacity` u32 | thread entries, a multiple of 256 |
| 164 | 4 | `thread_cursor` u32 | atomic: thread entries claimed |
| 168 | 8 | `categories` u64 | atomic: the process's category bitset, mirrored on each change |
| 176 | 8 | `chunks_skipped` u64 | atomic: claims that found their chunk still owned and took the next |
| 184 | 8 | `records_dropped` u64 | atomic: records not written because every chunk was owned |
| 192 | 4 | `name_overflow` u32 | atomic: names that found the table full (written as name 0) |
| 196 | 4 | `thread_overflow` u32 | atomic: threads that found the table full (their chunks name thread `0xFFFFFFFF`) |
| 200 | 8 | `heap_cursor` u64 | `chunk_cursor` when the heap ring was copied into this file; 0 if the ring started here |
| 208 | 8 | `start_continuous_ns` u64 | `mach_continuous_time` nanoseconds read with `start_uptime_ns` (Linux `CLOCK_BOOTTIME`): places `log` signposts until the first sleep |
| 216 | 40 | reserved | zero |

The ring's overwrites are `max(0, chunk_cursor - chunk_count)`, so no counter is kept.

#### Name table (64-byte entries)

The header holds the **full** table: the fixed catalog names (`SignpostName` ids, append-only, from 1), the
names interned at run time after them, and the categories. A decoder reads the names from the ring alone, so
a newer build decodes an older ring. Name id = entry index; id 0 means no name.

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 4 | `state` u32 | atomic: 0 empty, 1 being written, 2 published (a store-release, last) |
| 4 | 2 | `id` u16 | the entry index |
| 6 | 1 | `kind` u8 | 1 catalog name, 2 interned name, 3 category |
| 7 | 1 | `category` u8 | bit index in `categories` (kind 3: its own bit) |
| 8 | 1 | `name_len` u8 | at most 55 |
| 9 | 55 | `name` | UTF-8, NUL padded, for example `key.frame` |

A writer claims an entry with `fetch_add` on `name_cursor`, fills it and publishes `state = 2`. The fixed
names are written when the ring is created, off the hot path; a trace point keeps its id after its first use.

#### Thread table (64-byte entries, 256 per chunk)

Thread index = entry index. Chunks of 256 entries (16 KiB) are claimed in order from the thread region, so a
process with few threads touches one page. A thread's entry is written at its first record only.

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 4 | `state` u32 | atomic: 0 free, 1 being written, 2 live, 3 exited (the TLS destructor) |
| 4 | 4 | `generation` u32 | incremented each time the entry is reused after an exit |
| 8 | 8 | `tid` u64 | `pthread_threadid_np` (Linux `gettid`, Windows `GetCurrentThreadId`) |
| 16 | 1 | `qos` u8 | `qos_class_t` at registration (`pthread_get_qos_class_np`; 0 elsewhere) |
| 17 | 1 | `name_len` u8 | at most 46 |
| 18 | 46 | `name` | `pthread_getname_np`, UTF-8, NUL padded, truncated |

A chunk whose `thread_generation` differs from its entry's `generation` was written by an earlier occupant of
the entry: the decoder names its thread `thread <index> (generation <g>)`.

#### Chunk (1024 bytes: a 32-byte header in slot 0, records in slots 1-31)

The thread lives in the chunk header, so a record stays 32 bytes.

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 4 | `thread_index` u32 | the owner's thread entry, or `0xFFFFFFFF` |
| 4 | 4 | `thread_generation` u32 | the entry's generation when the owner claimed the chunk |
| 8 | 8 | `lap_seq` u64 | atomic: 0 never claimed, `2*lap+1` owned and filling, `2*lap+2` complete |
| 16 | 4 | `published` u32 | atomic: records published in this lap, 0-31 (a hint: each slot is still checked) |
| 20 | 4 | reserved | zero |
| 24 | 8 | reserved | zero |

`lap` is the claim's `chunk_cursor` value divided by `chunk_count`.

#### Record (32 bytes)

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 8 | `t_ns` u64 | trace clock nanoseconds |
| 8 | 4 | `seq` u32 | seqlock, low 32 bits: `2*lap+1` while written, `2*lap+2` when published |
| 12 | 2 | `name` u16 | name id |
| 14 | 1 | `phase` u8 | the phase code below |
| 15 | 1 | `flags` u8 | the flag bits below |
| 16 | 8 | `arg0` u64 | the name's first number (its catalog doc comment says which); a counter's value as i64 |
| 24 | 8 | `arg1` u64 | an async, flow or track id, or the name's second number |

Phases (ASCII, as in Chrome's JSON trace):

| Code | Phase | `arg1` |
|---|---|---|
| `B` 0x42 | slice begin on the writing thread | the name's number, or a track id with flag bit 0 |
| `E` 0x45 | slice end: the same name as its `B`, on the same thread | as `B` |
| `I` 0x49 | instant | as `B` |
| `b` 0x62 | AB: async begin, for an interval that crosses turns or threads or overlaps another | async id (flag bit 0 set) |
| `e` 0x65 | AE: async end, on any thread | the async id of its AB |
| `s` 0x73 | flow out | flow id |
| `f` 0x66 | flow in | flow id |
| `C` 0x43 | counter | a track id with flag bit 0 |

AB and AE pair by (name, async id) and nest like Chrome's `TRACE_EVENT_NESTABLE_ASYNC_*`; the exporter maps each
pair to a Perfetto track. The async id is the `OSSignpostID` or the intent id. Phase 0 is invalid.

Flags: bit 0 (0x01): `arg1` is an async id (required on `b` and `e`) or a track id. Bit 1 (0x02): `t_ns` is an
estimate (for example `frame.present_estimate`). Bits 2-7 are zero, and a decoder ignores them.

### Writing

**Claim a chunk** when a thread has none, its chunk is full, or the active ring changed:

1. `c = fetch_add(chunk_cursor, 1, relaxed)`, `i = c & (chunk_count - 1)`, `lap = c / chunk_count`.
2. `h = load(chunk[i].lap_seq, relaxed)`. If `h` is odd (another thread still owns the chunk) or
   `h >= 2*lap+2` (a newer claim got there first), add 1 to `chunks_skipped` and go to step 1.
3. `compare_exchange(chunk[i].lap_seq, h, 2*lap+1, acq_rel)`; on failure go to step 1. Then a release fence.
4. Store `thread_index`, `thread_generation` and `published = 0` (relaxed).

After `chunk_count` failed tries, add 1 to `records_dropped` and drop the record: a writer never waits. Each
writing thread holds one chunk, so a ring needs more chunks than writing threads; `chunks_skipped` shows when
it has too few.

**Publish a record** in slot `k` (1-31) of the owned chunk:

1. Store `seq = 2*lap+1` (relaxed), then a release fence.
2. Store `t_ns`, `name`, `phase`, `flags`, `arg0` and `arg1` (relaxed: plain aligned stores on arm64 and x86-64).
3. Store `seq = 2*lap+2` (release), then `published = k` (release).

**Complete the chunk** after slot 31, at the thread's exit and when the active ring changes: store
`lap_seq = 2*lap+2` (release).

A record costs one relaxed load (the category bits and the active ring epoch), the clock read and the
record's stores, two of them release stores. No lock, allocation or system call; the only read-modify-write
is the chunk claim, once per 31 records.

**Overwrite.** The cursor wraps: a claim of lap `L` takes over a chunk that lap `L-1` completed. The new
owner does not clear it. The old records' `seq` (`2*(L-1)+2`) no longer matches the header, so a decoder
drops them. Two writers never share a chunk (step 2 skips an owned one), so a record can tear only while its
own writer is inside it, and then its `seq` is odd.

**Decode** a chunk:

1. `h1 = load(lap_seq, acquire)`. If it is 0, skip the chunk. Else `lap = (h1 - 1) / 2`, rounded down.
2. For each slot: `s1 = load(seq, acquire)`; skip the slot unless `s1 == 2*lap+2` (low 32 bits); copy the
   payload; an acquire fence; `s2 = load(seq, relaxed)`; keep the record only if `s2 == s1`.
3. An acquire fence; read `thread_index` and `thread_generation`; `h2 = load(lap_seq, relaxed)`. If the lap
   of `h2` is not `lap`, drop the chunk: it was taken over while it was read.

Records are in program order within a chunk; the decoder merges all chunks by `t_ns`. A ring from a crashed
process decodes the same way: the chunk a thread was filling is odd, and its published slots are whole.

### One write path

Every trace point writes one record, into the process's **active** ring, never two. The active ring is the
black box until `trace.start`, then the recording ring until `trace.stop`. A writer compares its chunk's ring
epoch with the active epoch on each write (the same relaxed load as the category bits). On a change it
completes its chunk and claims from the active ring. So a recording's records are in the recording ring
only, and the black-box tail is the last N records of whichever ring is active.

The ring starts as a heap buffer with this layout at the process's first instruction. A one-shot job off the
main thread (Swift: BackgroundWork `.files`; Rust: a thread at start) renames a spare file or creates the
ring file, maps it `MAP_SHARED`, swaps the active ring (epoch + 1), copies the heap image into the file and
stores `heap_cursor`. The file has the heap's `chunk_count`, so the copied chunks keep their places and laps.
A record that was mid-write on the heap during the copy has an odd `seq` and is dropped. The heap buffer is
never freed, and a recording mapping is never unmapped while the process lives, so a late writer cannot
fault; the next `trace.start` resets the mapping. Nothing on the main thread opens, truncates or maps a file
before the first frame.

Ring sizes by role (records; a chunk holds 31):

| Role | Black box | Recording |
|---|---|---|
| App, daemon | 4096 | 1M |
| Holder, acpmux, Chromium host | 4096 | 256K |
| Terminal host | 512 | 16K |

`chunk_count` is the role's record count divided by 31, rounded up to a power of two.
`trace.start` caps the total bytes and reports them in `trace.status`. Cleanup deletes a ring whose pid is
dead (`kill(pid, 0)` plus `process_start_unix_us`) and that is older than 3 days, and caps the directory at
16 MiB.

### Versions

A new field may take reserved bytes (zero means absent) with no version change. Any other layout change
bumps `version`, and a decoder refuses a version it does not know.

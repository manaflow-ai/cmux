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
| cmux signposts | `log stream --signpost`, subsystem `com.cmuxterm.app.next`, every process | Tracks `signposts <category>` in the emitting process: `action.perform`, `action.commit`, `action.gate` (always on, also in Release), and the catalog spans of the debug timings: category `stall` (`stall.create_surface`, `stall.palette_open`, `stall.icon_picker_open`) and category `switch` (`switch.tab`, `switch.pane_focus`). A watchdog stall lists in its `during` line the ones it happened inside (`STALL_DURING_SPANS`), a `commit=missed` one labeled `missed` |
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
terminal host's `serve_terminal_host_process`, the holder's `serve`), which starts the process's black box and a
recording of the `key` category in `<dir>` (`<role>-<pid>.recording.cmxtrace`, "Release trace ring v1"), so no
hop opens a file or starts a thread. When the recording cannot be a file in `<dir>` (the process's `main` put its
black box elsewhere, the file cannot be mapped, or the platform has no ring files yet: unix only until task
p09-observability-132), `init` stops the recording it started, prints one stderr line and leaves flows off. A hop
never allocates, locks or enters the kernel: off, it is one relaxed load (test `cmux-flow-trace/tests/off.rs`);
on, it is a ring write (test `tests/records.rs` counts the caller's allocations). Hops write only while a
recording runs: `key` is a black-box category, but after `trace.stop` no hop goes to the black box. A hop is one
ring record in category `key` with arg0 the terminal key (the first 8 id bytes, big-endian). A hop with a flow id
is a flow step, Chrome's `TRACE_EVENT_FLAG_FLOW_IN | TRACE_EVENT_FLAG_FLOW_OUT`: a `f` record and then a `s`
record with arg1 the flow id. Only the app's last hop ends the flow (`f` alone); a reader takes the `f` time as
the hop's. A hop with no flow id is one `I` record with arg1 0. The marks in the terminal host and in the daemon's
local-PTY path run before the runtime locks. The app's hops are `key.flow` signpost events. Until trace.py reads
v1 rings (task p09-observability-023), `trace.py` stops with an error when `OUT/flows` holds only `.cmxtrace`
files.

| Hop | Process, thread | Carries |
|---|---|---|
| `app.key.dispatch` | app main (`CmuxApplication.sendEvent`, `debug.key`) | flow id, key age |
| `app.key.terminal` (optional: drawn when emitted, not needed for a complete press) | app main (`TerminalSurfaceView.keyDown`) | flow id |
| `app.io_write` | Ghostty IO thread (`io_write_cb`) | flow id |
| `app.send` | the same thread (`TerminalAttachment.enqueueInput`; the `send` request gets `flow`) | flow id |
| `daemon.send.write`, `daemon.send.written` | daemon `mux-seq-control` pool worker (`cmd_terminal_io::send`) | flow id |
| `host.pty.write` (host model) or `daemon.pty.write` (holder model: the daemon writes the PTY itself) | `terminal-host-client-input` / `mux-seq-control` | terminal |
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

## Release trace ring: category bits

Status: frozen (p09-observability-000, 2026-10-25). Every writer of the Release trace ring (the section
"Release trace ring v1" below) uses these bits in the header's `categories` u64, in a name entry's `category`
byte and in its process's category flags: Swift `SignpostCategory.traceBit` (CmuxNextSignposts), Rust
`cmux_trace::category` and the C writer. Each side pins every number in a test (`SignpostTraceCatalogTests`,
`cmux-trace/tests/shared_values.rs`). A bit never changes or moves to another category. A new category takes
the next free bit here first, then in every writer in the same change.

| Bit | Category | Black box default |
|---|---|---|
| 0 | `action` | yes |
| 1 | `key` | yes |
| 2 | `switch` | yes |
| 3 | `create` | yes |
| 4 | `cef` | yes |
| 5 | `launch` | yes |
| 6 | `daemon` | yes |
| 7 | `hang` | yes |
| 8 | `crash` | yes |
| 9 | `motion` | no |
| 10 | `frame` | no |
| 11 | `stall` | no |
| 12 | `task` | no |
| 13 | `burst` | no |
| 14 | `input` | no |
| 15 | `webview` | no |
| 16 | `remote` | no |
| 17 | `control` | no |
| 18 | `ghostty` | no |
| 19 | `resize` | no |
| 20 | `webui` | no |
| 21 | `log` | no |

The black box records bits 0-8 from launch (section 3A of plans/cmux-next/chrome-parity/p09-observability.md);
a `trace.start` recording turns on the others. The role (header byte 20) and phase (record byte 14) values are
the tables of "Release trace ring v1"; the Swift `TraceRuntime.Role` and `TraceRuntime.Phase` and the Rust
`Role` and `Phase` pin the same numbers.

## Limits and open span requests

- Daemon spans cover the create paths only (workspace, pane, tab and terminal creates), and a span
  line has no clock. trace.py places a line by its arrival through `tail -F` (about 1 ms error) until
  the daemon writes `start_uptime_ns`; trace.py already reads that field. Requested from cmux-b6
  (PL-daemon), 2026-10-23: a span for every request, with `start_uptime_ns`, `tid` and the marks
  `parsed`, `dispatched`, `reply.queued` and `reply.sent`, only when the variable is set.
- The app's own daemon round trip is the ring slice `daemon.request` (category `daemon`, closed by
  p09-observability-025): an async slice from the send to the reply, the error or the timeout of every
  request that waits for a reply (`LineTransport.request` and `pipeline`). The end is written when the
  reply, error or timeout resolves the request, so a pipelined request ends at its own reply. Begin
  arg0 is the method id the daemon's own `daemon.request` slice carries: callers pass a typed
  `DaemonCommandName` (a request type's `static let commandName`), whose id comes from the daemon's
  tables through `scripts/cmux-next/gen-daemon-command-names.py`. A name neither table has takes the
  daemon's routed id: `agent-` and `access-request` 0x8005, `browser-` 0x8004, else 0x8007. The Rust
  test `request_spans_generated_swift_*_match_the_daemon` fails when the Swift tables are stale. End
  arg0 is the outcome: 0 reply, 1 error, 2 timeout. The async id is the wire request id in bits 0-39
  and, in bits 40-63, a per-connection scope that the process never hands out again
  (`TraceRuntime.nextAsyncScope`), so a reconnect cannot pair with an old connection's slice. At the
  send a flow-out carries the flow `FNV-1a 64(app pid as 4 bytes LE, request id as 8 bytes LE)` in
  arg1 and the async id in arg0; the daemon's flow-in from `LOCAL_PEERPID` is task 103. A request
  sent without waiting (`sendNoReply`) has no slice.
- `cef.pump` (category `cef`, closed by p09-observability-032) is one thread slice (B/E) per
  `CefDoMessageLoopWork` pass of the in-process pump (`CEFMessagePump`). A writer records it only
  while `task` (bit 12) is on as well as `cef`, so a recording has every pass and the black box has
  none: passes run up to 100 times a second while a page loads and would push the black box's
  action, key and switch records out. Begin arg0 is why the pass runs: 1 an immediate request,
  2 CEF's delayed request, 3 a Chromium thread's request the gate kept, 4 the pass that runs a fire
  a nested run loop deferred, 0 a pass no timer armed (the quit path's drain). End arg0 is 1 when
  the pass used CEF's whole 10 ms time slice, else 0; end arg1 is the pass's elapsed time in us on
  the pump's clock. With the Chromium host on, the host writes the same name and layout from its
  own ring (task 104). The app emits no `cef.pump` then.
- `task.post` and `task.run` (category `task`, recording only, closed by p09-observability-042) trace
  posted work as Chrome's `TaskAnnotator` does (base/task/common/task_annotator.cc): every item posted
  to a `BackgroundWork` lane and every request the control queue (`MainActorWorkQueue`) accepts. A
  request the queue refuses as busy writes no `task.post`, so each `task.post` has its `task.run`.
  `task.post` is a flow-out at the post: arg0 the post site (the interned `#fileID`'s id in bits 0-15,
  the line in bits 16-47), arg1 the flow id (bit 63 set). The run's flow-in is the first record inside
  its `task.run` slice (B/E): arg0 the post site, arg1 the flow id. A lane item's slice is the lane's
  (below, "Blocking calls and lane jobs"); a control request's is written by `TaskTrace` on the main
  thread, with the lane 3 (main) in B arg0 bits 8-15 and its `MainWorkClass` `rawValue` in bits 0-7, and
  B arg1 the queue wait in us, or u64::MAX when unknown (the post was written before the recording started).
- `control.request` (category `control`, closed for its queue part by p09-observability-042; task 115
  owns the accept-to-reply part) is an async slice (AB/AE) per control request from its enqueue on
  `MainActorWorkQueue` to the end of its run or its failure, keyed by an async id
  (`TraceRuntime.nextAsyncScope`) in arg1 of both records. AB arg0 is the method's main task board
  owner index in bits 0-31 (0 without a board) and the main work class (`MainWorkClass.rawValue`) in
  bits 32-39. AE arg0 is the outcome: 0 ran, 1 expired while queued, 2 refused as
  busy (it never queued).
- `cef.create_browser` is reserved but has no emitter (requested from PL-motion-cef, task 033).
  Without it, a Release trace attributes Chromium browser-creation time only through the stack samples.
- `cef.geometry` (category `cef`, perf-hot `cef-geometry`, owner PL-motion-cef, closed by
  p09-observability-038) is one thread slice (B/E) per parent window move or resize
  (`WindowOverlayLayer.parentGeometryDidChange`, begin arg0 1) and per divider catcher sync
  (`syncCatchers`, begin arg0 2). The slices never nest: catcher work inside a parent geometry
  slice takes no slice of its own. End arg0 is the catcher panels shown, end arg1 the catcher panels
  made or re-framed in the slice. Each `CEFHostView.postGeometryChange` is one `cef.geometry` instant
  (arg0 0): the fork re-places one page window there, so a slice's instants are its page moves.
  Recording only: the ring takes the slices and instants only while `motion` is on too (a live
  resize writes one per tick), never in the black box, as `cef.pump` needs `task`.
- `cef.host_input` (category `cef`, perf-hot `cef-host-input`, closed by p09-observability-038) is
  one instant per input frame (3 mouse, 4 wheel, 5 key, 10 edit command) that
  `ChromiumHostConnection.send` writes to the Chromium host; arg0 is the frame's wire kind.
  Navigation, geometry, focus, ping, stats and quit frames record nothing. Recording only: the ring
  takes it only while `input` is on too, never in the black box. While the keystroke-timing gate is
  closed, a key or edit frame's instant is not recorded (the frame is still sent), in the log system
  either. The black box upload drops every `cef.host_input`.
- `key.omnibar_suggest` (perf-hot `omnibar-key`) and `key.palette_search` (perf-hot `palette-key`),
  category `key`, closed by p09-observability-040, are one thread slice (B/E) per synchronous pass
  of a typed key's search, as Chrome traces `AutocompleteController::Start` and `UpdateResult`
  apart: begin arg0 the pass (1 the query: `OmnibarStep.refreshSuggestions`, `PaletteModel.search`;
  2 the rows that landed; 3 the omnibar's later rows of the same query), end arg0 the rows the
  popup or the palette page holds when the pass ends. The ranking off the main thread between the
  two passes is not a slice. Neither is written, in the log or the ring, while the keystroke-timing
  gate is closed.
- The holder and the terminal hosts have `task` trace points (recording only, never the black
  box), but a `cmux trace` capture does not show them yet. They record only after the process
  opens its ring (p09-observability-095) and a recording is forwarded to it
  (p09-observability-015, p09-observability-096). Until then only their sampled stacks show.
  - Holder: `task.holder_poll` is one slice per poll turn's work, with no terminal (arg0 the ready
    descriptors, arg1 the polled ones). The instants `task.holder_pty_read` and
    `task.holder_pty_write` carry the terminal's `cmux_trace::terminal_hash` in arg0 and the bytes
    read or written in arg1.
  - Terminal host: every begin carries the terminal hash in arg0. `task.host_pty_read`: end arg0
    the bytes read, end arg1 the outcome (0 published, 1 retry, 2 end of file, 3 read error,
    4 parser gone). `task.host_parse`: arg1 the command kind in the high byte, an Output's bytes
    below it. `task.host_input_write`: begin arg1 the payload bytes; end arg0 the bytes written to
    the PTY, end arg1 the outcome (0 written, 1 dropped for lack of input-queue room, 2 write
    failed).
- Blocking calls and lane jobs (category `task`, closed by p02-threads-124; recording only, never the black
  box). Off, a checked blocking call pays one acquiring load (the hook word `BlockingTraceHook`) and a lane item
  one relaxed load at its post; Release keeps both.
  - `task.blocking_call` (interned name) is one thread slice (B/E) per checked blocking call
    (`blockingCall(kind, fileID, line)`, every seam of CmuxNextCompat/Threading, and
    `cpuIntensiveCall(size:limit:)` with kind 12 at any size and on any thread), Chrome's `ScopedBlockingCall`
    trace event (base/threading/scoped_blocking_call.cc). Begin arg0: the kind's code in bits 0-7
    (`BlockingKind.traceCode`: 1 file-io, 2 socket-read, 3 socket-write, 4 sync-wait, 5 ipc-reply,
    6 process-wait, 7 process-spawn, 8 lock-wait, 9 system-call, 10 sleep, 11 wrong-lane, 12 cpu-intensive,
    13 fs-metadata, 14 sqlite, 15 process-reap, 16 system-query, 17 priority-inversion, 18 ffi, 19 xpc-reply) and the call's `#line` above them. Begin
    arg1: FNV-1a 64 of the call's `#fileID` (`Module/File.swift`). The end has no arguments; a written begin
    always gets its end, also when the body throws or the category turns off meanwhile. Only the app's
    `TraceRuntime.shared` routes them, while its `task` bit is on.
  - `task.run` (catalog id 51) is one thread slice (B/E) per BackgroundWork lane item posted while `task` is
    on, around the item's run on its slot thread (its hang scope included); Chrome's
    `ThreadPool_RunTask` in `TaskTracker::RunTask` (base/task/thread_pool/task_tracker.cc). Begin arg0: the
    lane in bits 8-15 (0 files, 1 system, 2 cpu, 0xFF a lane made without one) and the priority in bits 0-7
    (0 idle, 1 best effort, 2 user visible, 3 user blocking). Begin arg1: the queue wait from the post to the
    start in us; a `WorkSequence` item's post is its post to the sequence, so the wait includes the time behind
    the items in front of it (Chrome stamps a sequenced task's queue time at its post,
    base/task/thread_pool/sequence.cc). Whether an item records is decided at that post too. A `task.blocking_call` inside the item nests in its slice.
    The item's `task.post` flow-in (p09-observability-042, above) is the first record inside the slice.
- acpmux has no spans; only its sampled stacks show (requested through the cmux-4f lead from
  PL-acpmux).
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
| 20 | 2 | `role` u16 | 1 app, 2 daemon, 3 holder, 4 terminal host, 5 acpmux, 6 Chromium host, 7 CLI, 8 agent host, 9 app host, 10 browser host |
| 22 | 1 | `ring_kind` u8 | 1 black box, 2 recording |
| 23 | 1 | `clock_domain` u8 | 1 `CLOCK_UPTIME_RAW`, 2 Linux `CLOCK_MONOTONIC`, 3 Windows QPC nanoseconds |
| 24 | 8 | `start_uptime_ns` u64 | the trace clock when the ring started (a recording ring: when this recording started) |
| 32 | 8 | `start_unix_ns` u64 | the wall clock at the same moment: display and the 3-day cleanup only |
| 40 | 8 | `process_start_unix_us` u64 | the kernel's start time of `pid`: with `kill(pid, 0)`, cleanup tells a reused pid |
| 48 | 16 | `boot_session_uuid` | `kern.bootsessionuuid` as 16 bytes (Linux `boot_id`, Windows zero): uptime is valid within one boot only |
| 64 | 16 | `build_uuid` | `LC_UUID` of the main image (Linux: the first 16 bytes of the GNU build id; zero when none) |
| 80 | 32 | `build_version` | ASCII, NUL padded: version, build number and short commit |
| 112 | 4 | `chunk_bytes` u32 | 1024 |
| 116 | 4 | `chunk_count` u32 | a power of two (the sizes table below) |
| 120 | 8 | `chunks_offset` u64 | offset of chunk 0, a multiple of 16384 |
| 128 | 8 | `chunk_cursor` u64 | atomic: claim tries so far (the claim's `fetch_add`); it never goes back |
| 136 | 8 | `name_table_offset` u64 | offset of name entry 0 |
| 144 | 4 | `name_capacity` u32 | name entries in the table, at most 65536 (a name id is a u16) |
| 148 | 4 | `name_cursor` u32 | atomic: the next name id to claim; at least 1 (id 0 means no name) |
| 152 | 8 | `thread_table_offset` u64 | offset of thread entry 0 |
| 160 | 4 | `thread_capacity` u32 | thread entries, a multiple of 256 (whole 16 KiB pages) |
| 164 | 4 | `thread_cursor` u32 | atomic: fresh thread entries claimed; it can pass `thread_capacity` |
| 168 | 8 | `categories` u64 | atomic: the process's category bitset, mirrored on each change |
| 176 | 8 | `chunks_skipped` u64 | atomic: claim tries that found their chunk owned or claimed by a newer lap |
| 184 | 8 | `records_dropped` u64 | atomic: records not written because 4 claim tries failed |
| 192 | 4 | `name_overflow` u32 | atomic: names that found the table full (written as name 0) |
| 196 | 4 | `thread_overflow` u32 | atomic: threads that found the table full (their chunks name thread `0xFFFFFFFF`) |
| 200 | 8 | `heap_cursor` u64 | the heap ring's `chunk_cursor` when its chunks were copied into this file; 0 if the ring started here |
| 208 | 8 | `start_continuous_ns` u64 | `mach_continuous_time` nanoseconds read with `start_uptime_ns` (Linux `CLOCK_BOOTTIME`): places `log` signposts until the first sleep |
| 216 | 8 | `chunks_overwritten` u64 | atomic: claims that took over a chunk that held records of this ring's current recording (step 3 of the claim) |
| 224 | 8 | `recording_start_cursor` u64 | the first `chunk_cursor` value of this recording; 0 for a black box. `start_lap = recording_start_cursor / chunk_count` |
| 232 | 4 | `heap_chunks_lost` u32 | chunks the heap ring claimed after its copy and before the swap to this file |
| 236 | 20 | reserved | zero |

`chunk_cursor` also moves on every failed claim try, at the heap copy and at each `trace.start`, so it is not a
count of overwrites: `chunks_overwritten` is.

#### Name table (64-byte entries)

Each ring holds the **full** table for its own records: the fixed catalog names (`SignpostName` ids,
append-only, from 1), the names interned at run time after them, and the categories. A decoder reads the names
from the ring alone, so a newer build decodes an older ring. Name id = entry index; id 0 means no name, and
entry 0 stays zero.

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 4 | `state` u32 | atomic: 0 empty, 1 being written, 2 published (a store-release, last) |
| 4 | 2 | `id` u16 | the entry index |
| 6 | 1 | `kind` u8 | 1 catalog name, 2 interned name, 3 category |
| 7 | 1 | `category` u8 | bit index in `categories` (kind 3: its own bit) |
| 8 | 1 | `name_len` u8 | at most 55 |
| 9 | 55 | `name` | UTF-8, NUL padded, for example `key.frame` |

The ring's creator writes the catalog and category entries and stores `name_cursor` = the last of their ids + 1
while the ring is still private (before it becomes active), so a catalog id is the same in every ring and needs
no lookup.

An interned name has one id **per ring**. A process has at most three rings (the heap ring, the black-box file
and the recording ring, slots 0, 1 and 2), and a trace point keeps its three ids in one atomic u64 (bits
16*slot, 0 = not interned in that ring yet). At its first record into a ring it claims an entry with
`fetch_add(name_cursor, 1, relaxed)`, fills it, stores `state = 2` (release), then sets its id in its slot
with a compare-exchange loop that writes those 16 bits only while they are 0. When two threads intern the same trace point at once, both entries are
published with the same text and the record uses the id that won. An id at or past `name_capacity` is not used:
the record names id 0, and `name_overflow` counts it. The ids never cross rings, so a ring's records name only
that ring's entries. Perfetto keeps interned data per sequence for the same reason and writes it again into
each new buffer (`include/perfetto/tracing/track_event_interned_data_index.h`).

#### Thread table (64-byte entries)

Thread index = entry index, per ring. A thread registers in a ring at its first record there and keeps that
ring's index in TLS (one per ring slot). Fresh entries are taken in index order, so a process with few threads
touches one 16 KiB page.

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 4 | `state` u32 | atomic: 0 free, 1 being written, 2 live, 3 exited (the TLS destructor) |
| 4 | 4 | `generation` u32 | 0 for a fresh entry, + 1 each time the entry is taken again after an exit |
| 8 | 8 | `tid` u64 | `pthread_threadid_np` (Linux `gettid`, Windows `GetCurrentThreadId`) |
| 16 | 1 | `qos` u8 | `qos_class_t` at registration (`pthread_get_qos_class_np`; 0 elsewhere) |
| 17 | 1 | `name_len` u8 | at most 46 |
| 18 | 46 | `name` | `pthread_getname_np`, UTF-8, NUL padded, truncated |

**Register** a thread in a ring (once per thread and ring, off the record path that follows):

1. If `load(thread_cursor, relaxed) < thread_capacity`, `j = fetch_add(thread_cursor, 1, relaxed)`. If
   `j < thread_capacity`, entry `j` is fresh: store `state = 1` and `generation = 0`, and go to step 4.
   Otherwise go on to step 2.
2. Scan entries 0 to `thread_capacity - 1` for `state == 3` and take the first that
   `compare_exchange(state, 3, 1, acquire)` changes. Store `generation` = its generation + 1, and go to step 4.
3. No entry was taken: add 1 to `thread_overflow` and stop. The thread's chunks in this ring name thread
   `0xFFFFFFFF`.
4. Store `tid`, `qos` and `name` (relaxed), then `state = 2` (release).

After step 1 or 2 only the entry's thread writes it. The thread reads its tid, QoS and name once, at its first
registration, and keeps them in TLS, so registering in a later ring is stores only. At exit the TLS destructor
completes the thread's chunk and stores `state = 3` (release) in each of its entries. Only an exited entry is
taken again, so a live thread's index never changes.

A decoder reads entries 0 to `min(thread_cursor, thread_capacity) - 1`: `state` and `generation` (acquire), the
fields, then both again, and keeps an entry whose two reads agree. A chunk whose `thread_generation` differs
from its entry's `generation` was written by an earlier occupant of the entry: the decoder names its thread
`thread <index> (generation <g>)`.

#### Chunk (1024 bytes: a 32-byte header in slot 0, records in slots 1-31)

The thread lives in the chunk header, so a record stays 32 bytes.

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 4 | `thread_index` u32 | the owner's thread entry in this ring, or `0xFFFFFFFF` |
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

**Claim a chunk** when a thread has none, its chunk is full, or the active ring changed. A claim makes at most
4 tries:

1. `c = fetch_add(chunk_cursor, 1, relaxed)`, `i = c & (chunk_count - 1)`, `lap = c / chunk_count`.
2. `h = load(chunk[i].lap_seq, relaxed)`. If `h` is odd (another thread still owns the chunk) or
   `h >= 2*lap+2` (a newer claim got there first), add 1 to `chunks_skipped`: the try failed.
3. `compare_exchange(chunk[i].lap_seq, h, 2*lap+1, acq_rel)`; on failure the try failed. Then a release fence.
   If `h >= 2*start_lap+2`, the chunk held records of this recording: add 1 to `chunks_overwritten`.
4. Store `thread_index`, `thread_generation` and `published = 0` (relaxed).

After 4 failed tries, add 1 to `records_dropped` and drop the record; the thread's next record tries again. A
writer never waits, and a record costs at most 4 tries. Perfetto's producers also drop rather than wait when no
chunk is free (`BufferExhaustedPolicy::kDrop`, `include/perfetto/tracing/buffer_exhausted_policy.h`).

**Pinned chunks.** A thread keeps its chunk until slot 31, its exit or a change of the active ring, also while it
idles. So when `T` live threads hold a chunk in a ring, the ring keeps at least `(chunk_count - T) * 31` earlier
records, not `chunk_count * 31`, and a claim fails more often as `T` grows. The black-box sizes below keep the role's
record budget while up to the stated number of threads hold a chunk; `chunks_skipped` and `records_dropped`
show a ring with too few.

**Publish a record** in slot `k` (1-31) of the owned chunk:

1. Store `seq = 2*lap+1` (relaxed), then a release fence.
2. Store `t_ns`, `name`, `phase`, `flags`, `arg0` and `arg1` (relaxed: plain aligned stores on arm64 and x86-64).
3. Store `seq = 2*lap+2` (release), then `published = k` (release).

**Complete the chunk** after slot 31, at the thread's exit and when the active ring changes: store
`lap_seq = 2*lap+2` (release). Only the owner stores to an odd `lap_seq`, so this store never overwrites
another owner's claim.

A record costs one relaxed load (the category bits and the active ring epoch), one more for an interned trace
point's ids, the clock read and the record's stores, two of them release stores. No lock, allocation or system
call; the read-modify-writes are the chunk claim's, once per 31 records.

**Overwrite.** The cursor wraps: a claim of lap `L` takes over a chunk that an earlier lap completed, and
counts it in `chunks_overwritten`. The new owner does not clear it. The old records' `seq` no longer matches the
chunk's lap, so a decoder drops them. Two writers never share a chunk (step 2 skips an owned one, and no
`lap_seq` is ever reset), so a record can tear only while its own writer is inside it, and then its `seq` is
odd.

**Decode** a chunk:

1. `h1 = load(lap_seq, acquire)`. If it is 0, skip the chunk. Else `lap = (h1 - 1) / 2`, rounded down. If
   `lap < start_lap`, skip the chunk: it is from an earlier recording.
2. For each slot: `s1 = load(seq, acquire)`; skip the slot unless `s1 == 2*lap+2` (low 32 bits); copy the
   payload; an acquire fence; `s2 = load(seq, relaxed)`; keep the record only if `s2 == s1` and
   `t_ns >= start_uptime_ns`.
3. An acquire fence; read `thread_index` and `thread_generation`; `h2 = load(lap_seq, relaxed)`. If the lap
   of `h2` is not `lap`, drop the chunk: it was taken over while it was read.

Records are in program order within a chunk; the decoder merges all chunks by `t_ns`. A ring from a crashed
process decodes the same way: the chunk a thread was filling is odd, and its published slots are whole.

### One write path

Every trace point writes one record, into the process's **active** ring, never two. A process has at most three
rings: the heap ring, the black-box file and the recording ring. The active ring is the black box (the heap
ring until the file is adopted) until `trace.start`, then the recording ring until `trace.stop`. One atomic
word holds the active ring and an epoch that grows at every change. A writer compares its chunk's epoch with it
on each write (the same relaxed load as the category bits). On a change it completes its chunk, registers its
thread in the active ring if its TLS has no index there, and claims from the active ring. So a recording's
records are in the recording ring only, and the black box holds the records written while it was active.

**Heap, then file.** The ring starts as a heap buffer with this layout at the process's first instruction. A
one-shot job off the main thread (Swift: BackgroundWork `.files`; Rust: a thread at start) adopts the file. It
copies first and swaps last, so no writer ever claims a chunk in the file before the copy is done:

1. Rename a spare file or create the ring file with the heap's `chunk_count` and capacities, and map it
   `MAP_SHARED`. No writer can see it yet.
2. Write the header's fields from the heap's (the start times too), then copy the heap's chunks with the
   decode protocol below: a slot whose two `seq` reads differ is stored with `seq` 0, and a chunk taken over
   while it was copied is stored with `lap_seq` 0. A copied odd `lap_seq` is stored as `lap_seq + 1`
   (complete): the copy has no owner, and its published slots are whole.
3. Load the heap's `name_cursor`, `thread_cursor` and `chunk_cursor` (acquire), copy every name and thread
   entry below the first two whose `state` reads 2 before and after its copy (acquire; a thread entry's
   `generation` too), and store those two cursors in the file. Store `heap_cursor` = the heap's
   `chunk_cursor` and the file's `chunk_cursor` = `heap_cursor + chunk_count`, so every new claim is a lap past
   every copied one.
4. Swap the active word to the file (release). Then store `heap_chunks_lost` = the heap's `chunk_cursor` now
   minus `heap_cursor`.

Records written to the heap between its copy and the swap are lost. `heap_chunks_lost` counts the chunks the
heap claimed in that window; records added in that window to a chunk claimed before the copy are lost too and
are not counted. A copied chunk names only entries that step 3 copies: a thread or a name is published before
its first record, and the chunks are copied before the tables. An entry taken again during step 3 may be
skipped; its earlier occupant's chunks then decode as `thread <index>`. After the swap, threads and trace points register in the file as in
any new ring (their heap indexes do not carry over; a few entries repeat the heap's). The heap buffer is never
freed, so a late writer cannot fault.

**Recording ring.** The first `trace.start` creates the recording ring off the main thread the same way: map
it, write the header, the catalog and the categories, then swap. The mapping is never unmapped while the
process lives, and it is never cleared: every later `trace.start` reuses it. While the black box is active,
`trace.start`:

1. Stores 0 to the counters, then the new `start_uptime_ns`, `start_unix_ns` and `start_continuous_ns`.
2. `c = fetch_add(chunk_cursor, chunk_count, relaxed)`; stores `recording_start_cursor = c + chunk_count`
   (release). Every later claim is a lap past every claim of an earlier recording.
3. Swaps the active word to the recording ring (release).

A late writer of an earlier recording (it loaded the old epoch and was preempted) still owns its chunk, whose
`lap_seq` is odd, so new claims skip it and two writers never share a chunk. Its records have a lap below
`start_lap` or a `t_ns` before `start_uptime_ns`, and the decoder drops them. The tables carry over: thread and
name indexes stay valid from one recording to the next. A late writer's increment can land in the new
recording's counters.

**Sizes by role.** The tables and the chunk counts are fixed per role; the black box and the recording ring of
one process have the same capacities.

| Role | `name_capacity` | `thread_capacity` | Black box `chunk_count` | Recording `chunk_count` |
|---|---|---|---|---|
| App, daemon | 4096 | 2048 | 512 (512 KiB: at least 4096 records while up to 379 threads hold a chunk) | 32768 (32 MiB: about 1M records) |
| Chromium host | 4096 | 2048 | 512 (512 KiB) | 8192 (8 MiB: about 254K records) |
| Holder, acpmux, agent host, browser host | 2048 | 512 | 256 (256 KiB: at least 4096 records while up to 123 threads hold a chunk) | 8192 (8 MiB: about 254K records) |
| Terminal host, app host | 1024 | 256 | 64 (64 KiB: at least 512 records while up to 47 threads hold a chunk) | 512 (512 KiB: about 16K records) |

A file adds its header page and tables to the chunks: 64 bytes per name and per thread entry (App: 256 KiB of
names and 128 KiB of threads), mostly untouched pages. `trace.start` caps the total bytes of the recording rings
it would map and reports them in `trace.status`. Cleanup covers black-box files only: it deletes one whose pid has
been dead (`kill(pid, 0)` plus `process_start_unix_us`) for more than 3 days, then the longest-dead ones until the
dead processes' black boxes take at most 16 MiB. It never deletes a live process's ring. A ring's age is not its
`start_unix_ns` or its mtime: the writer stores through a `MAP_SHARED` mapping, which does not reliably move the
mtime, so a crashed 4-day session would read as 4 days old. The first cleanup that finds a ring's pid dead creates
`<ring file name>.dead` with mtime = that cleanup's wall clock, and the age counts from that mtime (ties: the
older `start_unix_ns` first). A marker whose ring is gone is deleted. Recording files are under the `trace.start`
cap, not the cleanup cap.

### Versions

A new field may take reserved bytes (zero means absent) with no version change. Any other layout change
bumps `version`, and a decoder refuses a version it does not know.

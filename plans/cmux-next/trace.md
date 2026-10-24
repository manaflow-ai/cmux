# One timeline across every cmux process (`scripts/cmux-next/trace.py`)

Status: tool landed (cmux-4f PL-trace, 2026-10-23). Not a CI gate. Owner of the script: the Performance Lead.

The goal is a trace like Chrome's Perfetto traces. One command records a scenario, and one file shows
every cmux process on one time axis. With that file, "why did this lag" takes minutes to answer.

## What is in the trace

All sources use one clock: `CLOCK_UPTIME_RAW` (mach_absolute_time) in microseconds.

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
- `light-storm`: the same in the launch workspace, without STRESS.
- Wrap mode, for scripts that launch their own app (the every-action sweep, `sidebar-churn-typing.py`).
  The recording runs while the command runs:
  ```bash
  trace.py record --bundle "$NX_APP" --out "$NX_ARTIFACTS/trace" --seconds-cap 900 -- \
    python3 scripts/cmux-next/every-action-sweep.py --app "$NX_APP" --tag trc --out "$NX_ARTIFACTS/sweep" --sessions stress --only splitRight,closeTab
  ```
  Wrap mode records the stack samples and the signposts only. The command builds its own app
  environment, so its app gets no DevTools port and no daemon spans. Add `--socket S` for the stall
  track. Keep the command short (`--only`), because an all-process recording grows by about 50 MB a
  second.

Options: `--system-trace` (thread states: why a thread was off CPU, and which stack blocked;
heavier), `--recorder sample` (no xctrace: `/usr/bin/sample` of the app and the daemon, aggregate stacks
in `sample-*.txt`, no flame timeline), `--no-cef`, `--hang-ms N`, `--keep` (leave the app running),
`--keep-recording` (keep `recording.trace` for Instruments; it is deleted by default because it is GBs).

`trace.py export DIR` builds `trace.json.gz` and the summary again from the raw files in DIR
(`signposts.ndjson`, `xctrace-*.xml`, `hangs.json`, `daemon-spans-stamped.jsonl`, `chromium-trace.json`,
`driver.json`, `processes.json`, `meta.json`). Use it after you change the merge. `trace.py summary DIR`
prints the summary again. `trace.py --self-test` checks the parsers and the merge.

### Stage bounds (no silent hours)

Each stage of a recording has a bound (`STAGE_BOUNDS_S` in trace.py): launch, STRESS build, storm setup,
recorders start, the window (`--seconds` + 120 s), each source's stop, the xctrace save, the export and the
build. A stage that runs longer than 60 s prints `stage X still running after N s` once a minute. A stage
that passes its bound prints `STAGE X PASSED ITS BOUND`, stops what it started (it kills a wrapped command
or xctrace, and drops the DevTools connection), and the recording goes on to the next stage. The trace and
`SUMMARY.txt` are always written; the summary starts with `INCOMPLETE: stage(s) ...` and lists the time of
each stage. The exit code is 3. Where a stage was measured, the bound is about 2.5 times the measurement (the
STRESS build took 691 s on cmux-lawrence-2). Otherwise, it is the sum of the stage's own inner timeouts. The
bounds catch a hung stage; they are not targets.

Job 7 (2026-10-23) shows why. Its STRESS build finished, and then the job printed nothing for over an hour.
Two causes: the all-process recording ran while the Chromium trace (then a 400 MB buffer with IPC
categories) transferred, and nothing reported progress. The recording now ends with the window, the Chromium
buffer is 128 MB without IPC categories, and every stage has a bound.

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
- The trace does not prove that Chromium pages were real Chromium. The summary prints `chromium valid`
  from `debug.cef` (no `unavailable` or `fallback`).

#!/usr/bin/env python3
"""One timeline across every cmux process during a scenario, as a Perfetto / chrome://tracing file.

"Why did this lag" in minutes: one command records the app (main thread and every other thread, Ghostty's
renderer threads included), the cmux-tui daemon, the holder and terminal hosts, acpmux, the Chromium processes
(browser = the app, GPU, renderers, utility) and the CLI processes of a storm, and merges what each one knows
into one Chrome trace event file (JSON, gzip) keyed by pid and thread, that ui.perfetto.dev opens:

  time profile     `xctrace record --all-processes` (Time Profiler, plus os_signpost and Points of Interest;
                   System Trace system calls with --system-trace): every sampled stack becomes nested slices
                   on its real thread (a flame chart over time), threads of the bundle's processes and
                   WindowServer
  signposts        `log stream --signpost` of subsystem com.cmuxterm.app.next, every process: the always-on
                   action.perform / action.commit / action.gate (CmuxNextSignposts) and the catalog's spans of the
                   debug.* timings (category stall: stall.create_surface, stall.palette_open, stall.icon_picker_open;
                   category switch: switch.tab, switch.pane_focus), on per-category tracks of the emitting process;
                   a watchdog stall lists the ones it happened inside (STALL_DURING_SPANS)
  input latency    InputLatencyTracker's `input.latency` signposts (one per closed slot): Chrome's EventLatency
                   shape, one slice per input event from generated to presented on an `input latency` track of the
                   app, a child per stage step it has (cross-process ones too), an arrow into its key.flow chain,
                   and a summary p50/p95/p99/max per kind x target x presentation source
  stalls           the app's main-thread watchdog (`debug.hangs`, threshold --hang-ms): every stall with its
                   main-thread stack sample and CPU time, on a track of the app
  daemon spans     CMUX_TUI_DEBUG_SPANS (the daemon's create-path timing marks; set as CMUX_NEXT_TUI_DEBUG_SPANS on the app): each request's marks as
                   nested slices on a track of the daemon (placed by when its line was written; see the doc)
  chromium         Chromium's own trace over CDP (`Tracing.start` on the DevTools port the Debug build opens
                   with CMUX_NEXT_CEF_EXTRA_SWITCHES=remote-debugging-port=N), clock-checked with
                   Tracing.recordClockSyncMarker: browser, GPU and renderer threads, merged into the same
                   pids (thread ids mapped by name)
  driver           what the scenario did and when: every key sent, every CLI call of the storm
  trace rings      the Release trace rings (ring v1, plans/cmux-next/trace.md) of every role: app, daemon, holder,
                   terminal hosts, acpmux, the Chromium host, the CLI. `record --release` gets them from
                   `cmux trace record`; any `*.cmxtrace` in DIR, DIR/rings or DIR/flows is read, each ring once. Each
                   ring thread's records are a `ring <thread>` track (B/E slices, instants, flow records), async
                   pairs a `ring async <name>` track
  key-press flows  one chain per terminal key press, from the app's dispatch to the echo's estimated present. A hop
                   with the press's flow id is exact (the rings carry one at every hop: the app's key.flow, the 12
                   echo handoffs, the PTY write and read, ghostty.render through key.echo.renderer, its
                   frame.gpu_done, frame.present_estimate); only an old recording's flow-0 CMUX_TRACE_FLOWS records
                   are placed by windows, and only for a stage the press has no exact hop of
  Chromium join    each Chromium key EventLatency joined to the cmux key it measures: its kGenerated time is the
                   NSEvent timestamp, so it starts where the key's input.latency slot does (to the microsecond);
                   a press without a slot joins by its dispatch hop minus its age

Every source is on one clock: CLOCK_UPTIME_RAW (mach_absolute_time) in microseconds (the signposts' machTimestamp
is mach_continuous_time: the host's sleep since boot, read when `log stream` starts, is taken off). It then prints a short
summary (also SUMMARY.txt and summary.json): the longest main-thread stalls with their stacks, input to commit
per action, and cross-process waits (main thread off CPU inside an action or a stall, by what it waited on:
the daemon, Chromium, a lock, WindowServer, disk, XPC).

Scenarios (record --scenario):
  stress-storm   build STRESS (perf-stress-session.py), then for --seconds: a CLI storm at --storm-hz (workspace
                 move, task status, group add, status pill, as sidebar-churn-typing.py does) while keys are
                 typed into the focused terminal every --key-interval s, with an action chord pair every
                 --chord-every keys (Cmd-T/Cmd-W, Cmd-D/Cmd-W, next/previous workspace) through `debug.key`
  light-storm    the light session instead of STRESS (perf-stress-session.py build_light: a shown workspace split
                 once, Chromium, WebKit, chat and terminal tabs, plus LIGHT_BACKGROUND workspaces for the storm
                 to rearrange), then the same storm, typing and chords
  launch-warm   one launch from process start to `startup_complete` + 2 s: a priming launch saves a session and
                 quits the app only (its daemon keeps running, the binaries stay in the page cache), the recorders
                 start, then the measured launch restores that session. The app writes its StartupTrace
                 (CMUX_TRACE_STARTUP, Chrome Trace Event JSON on CLOCK_UPTIME_RAW) into DIR/startup/, where the
                 daemon's and Chromium's `--trace-startup` files go too (p08-startup 099); they are merged on their
                 own tracks (a file whose events fall outside the window is moved by the launch marks it shares with
                 the signposts, at the times the marks name, as the Chromium trace's clock check does). No DevTools
                 port: Chromium's start is not delayed by a CDP client. Watchdog stalls from 4 ms (or --hang-ms when
                 lower), drained once at the end so no socket call lands on the main thread during the launch (records
                 the ring dropped before the drain are counted and warned about). The window ends at the launched
                 pid's own `startup_complete` mark; --seconds is the longest wait for it after the spawn. The stop
                 dumps the StartupTrace file (`debug.startup_trace`) before the app quits
  launch-cold   the same after a reboot's state: the priming launch's app, daemon, hosts and agents are stopped (SIGTERM
                 by exact PID, the bundle's own processes) and `sudo -n purge` empties the file cache; a host where
                 purge needs a password refuses the run (`purge-refused`), never a cold label on a warm launch
                 The launch summary: the milestones (ms since process start), the critical path (each step between
                 milestones with the work that filled it), the top 10 main-thread frames before the first frame
                 (`first_window_frame_committed`) and every main-thread turn of 4 ms or more. As Chrome does it:
                 `--trace-startup` writes a startup trace file at its deadline (content/browser/tracing/
                 startup_tracing_controller.cc), and Telemetry's cold start empties the file cache with `purge`
                 (third_party/catapult/telemetry/telemetry/internal/platform/mac_platform_backend.py,
                 FlushEntireSystemCache)
  -- COMMAND     wrap mode: record while COMMAND runs (the every-action sweep or sidebar-churn-typing.py, which
                 launch their own app): time profile and signposts only (COMMAND's app gets no CDP port, no
                 daemon spans and no hang drain; pass --socket S for the hang drain). COMMAND runs in its own
                 process group: on a timeout, an error or a signal COMMAND gets SIGTERM and time for its own
                 teardown, then what is left of the group gets SIGTERM and SIGKILL, and the bundle's tag teardown
                 ends what it left. Its label is `wrap-key-unknown` (COMMAND's app has its own environment)

Process safety: the stop path ends the bundle's processes (the app's quit and tag teardown, the wrap teardown, a
SIGKILL by exact PID after a stop that passed its bound), so a record run refuses to start (`bundle-in-use`, exit
3) while any process of the bundle runs: every process it ends is then one this run started.

The app under trace activates and its window is key where the host allows it (CMUX_NEXT_NO_ACTIVATE is removed,
as pane-perf-terminal.py does); the window goes on the main screen at the STRESS size (`place_window`). Whether
the window was key is read at the window's start and again at its end: a run whose window was not key at either
read is labelled `<scenario>-inactive`. An app that activates can take key status from another GUI job on a
shared host: record on a reserved host (the perf-lead pool) when the numbers matter.

Exit code: 0; 3 when a stage passed its bound or failed (the trace and SUMMARY.txt are still written, with an
INCOMPLETE or ERROR line); wrap mode with a complete recording: the command's own nonzero exit code; 128 + N
when signal N (SIGTERM, SIGHUP) ended the run, also during the export or the build (every recorder and the app
are stopped first; the export and the build stop at once, and recording.trace is kept).

Usage (a fleet GUI host, never Lawrence's Mac):
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/trace.py record --app "$NX_APP" --out "$NX_ARTIFACTS/trace" --scenario stress-storm
  trace.py record --app APP --out DIR [--scenario stress-storm|light-storm|launch-warm|launch-cold] [--seconds 20] [--system-trace]
                  [--recorder auto|xctrace|sample] [--no-cef] [--hang-ms 8] [--storm-hz 10] [--release]
                  --release (stress-storm and light-storm only): record through the Release trace path instead of the
                  DEBUG knobs (flow files, the daemon span file, the DevTools port): `cmux trace record --seconds N
                  --out DIR/rings --keys [--chromium]` runs for the window (trace.start: every recording category,
                  key flows, Chromium tracing unless --no-cef) and copies every process's ring and Chromium's JSON.
                  The scenario driver still types through `debug.key` and drains `debug.hangs`: the app must be a
                  build that answers them
  trace.py record --bundle APP --out DIR [--socket S] [--seconds-cap 600] -- python3 scripts/cmux-next/every-action-sweep.py ...
  trace.py export DIR          rebuild DIR/trace.json.gz and the summary from DIR's raw files
  trace.py summary DIR         print DIR's summary again
  trace.py check-import DIR --trace-processor BIN
                               load DIR/trace.json.gz with Perfetto's trace_processor_shell: every signposts,
                               watchdog-stalls and daemon-spans track is its own named thread track with all its
                               slices, and the importer reports no error or data loss (DIR/import-check.json)
  trace.py check-clock DIR     exit 1 when a key press's hop or a daemon request's flow-in in DIR is earlier than
                               its cause (a source off CLOCK_UPTIME_RAW), 2 when DIR has nothing to check
                               (DIR/clock-check.json)
  trace.py --self-test         check the parsers (hand-written export shapes, not yet a real xctrace export),
                               the merge, the clock alignment, the stage bounds, the stop path, the export,
                               the signals, the one SIGINT to xctrace, the uint32 track ids, the
                               signpost clock of a host that slept, the input latency slices, the ring v1 reader
                               (the writers' shared golden file), exact and mixed key flows, the Chromium join
                               and the --release recorder

Docs: plans/cmux-next/trace.md (how to record, open in ui.perfetto.dev, read it). Not a CI gate.
"""
import argparse, bisect, collections, contextlib, gzip, importlib.util, json, math, os, re, select, shutil, signal, \
    statistics, struct, subprocess, sys, tempfile, threading, time
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import LaunchError  # noqa: E402  (a failed launch is a SystemExit subclass: a stage error, not a signal)
from bench_launch import PERF_LAB, load_by_path  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))

SUBSYSTEM = "com.cmuxterm.app.next"
# Tracks that are not OS threads (signpost lanes, daemon spans, stalls, syscalls, driver) get ids from here up
# (SyntheticTracks). Perfetto's JSON importer reads pid and tid as uint32 and puts an event whose id does not fit
# on the pid's own track, where slices of different tracks overlap without nesting and are dropped; under 2^31
# also fits a reader that takes them as int32. macOS thread ids are system-wide counters (millions after weeks
# of uptime), so this range is far above them; SyntheticTracks still skips any id the trace's threads use.
SYNTHETIC_TID_BASE = 0x7000_0000
DRIVER_PID = 0  # Perfetto shows pid 0 as its own process: the scenario driver's own events
FLAME_DEPTH = 120  # root-most frames kept per sample (deeper Swift stacks are rare; the leaf is in args)
LIGHT_BACKGROUND = 4  # light-storm: workspaces besides the shown one, for the storm to move, tag, group and pill
LAUNCH_SCENARIOS = ("launch-warm", "launch-cold")
LAUNCH_SETTLE_S = 2.0  # the launch window ends this long after `startup_complete`: work the launch left for later shows
LAUNCH_TURN_MS = 4  # main-thread turns at or over this are listed (a 240 Hz frame is 4.2 ms)
LAUNCH_TOP_FRAMES = 10
STARTUP_DIR = "startup"  # DIR/startup: the app's StartupTrace file, the daemon's and Chromium's startup traces
STARTUP_APP_FILE = "startup-app.json"
FIRST_FRAME_MARK = "first_window_frame_committed"
STARTUP_COMPLETE_MARK = "startup_complete"
# The launch milestones (p08-startup.md, E. Tracing; the bench-startup MARKS of the main thread's path): the critical
# path runs through the ones a launch has, in the order they happened.
LAUNCH_MILESTONES = ("process_start", "main_start", "main.run", "run_loop_start", "did_finish_launching_start",
                     "did_finish_launching_end", "first_idle", "window_display", "launch_picture_shown",
                     FIRST_FRAME_MARK, "first_live_content_frame", STARTUP_COMPLETE_MARK)
INSTANT_PHASES = ("i", "I", "R", "n")  # Chrome Trace Event instants (a mark), as StartupTrace writes its milestones
# Chromium categories: tasks (toplevel), input and frame latency, GPU and compositor frames, browser UI and
# navigation. Not mojom/ipc (one event per message: tens of MB a second with 40 pages animating) and not the
# devtools timeline. The ring buffer keeps the last CHROME_BUFFER_KB of events, so a long window stays bounded.
CHROME_CATEGORIES = [
    "toplevel", "benchmark", "input", "latencyInfo", "gpu", "viz", "cc", "ui", "views", "browser",
    "navigation", "loading", "blink.user_timing",
]
CHROME_BUFFER_KB = 128 * 1024
# The catalog spans that name a main-thread stall that happened inside one (a top stall's `actions`): the actions,
# the main-thread opens the stall bench measures (Signposter.stall thread slices; debug.timings rows), and the tab
# and pane switches (Signposter.switch; debug.tab_switch, debug.pane_focus). One rule for every one: a span that
# ended `commit=missed` (a switch superseded in a Cmd-] burst, a refused action) still did its main-thread work, so it
# names the stall too, labeled `missed`.
STALL_DURING_SPANS = ("action.perform", "action.commit", "stall.create_surface", "stall.palette_open",
                      "stall.icon_picker_open", "switch.tab", "switch.pane_focus")
# `record --release`: `cmux trace record` (p09-observability 021, over the app's trace.start/stop of 020) copies every
# process's ring and Chromium's JSON into OUT/rings; the recording window is its own, from trace.start to trace.stop.
RELEASE_DIR = "rings"
RELEASE_CHROMIUM_FILE = "chromium-trace.json"
RELEASE_LOG = "cmux-trace.log"
# `cmux trace record` says it records once trace.start replied: the CLI waits up to 15 s for that reply
# (cli/trace.rs START_TIMEOUT: the daemon waits for its children, the app adds Chromium's start).
RELEASE_START_S = 20
RELEASE_COLLECT_S = 300  # after the window: trace.stop, the ring copies, Chromium's JSON (64 MB) and the export (022)
RELEASE_WINDOW_SETTLE_S = 2  # run_window's second before the scenario and its second after it
# `cmux trace record --seconds` takes whole seconds, 1 to 590: trace.start's 600 s cap less the CLI's 10 s of stop
# slack (cli/trace.rs MAX_RECORD_SECONDS = MAX_SECONDS_CAP - STOP_SLACK_SECONDS; check_release_trace reads them).
RELEASE_RECORD_MAX_S = 590
ROLE_ORDER = ["app", "daemon", "holder", "terminal-host", "acpmux", "cef-gpu", "cef-utility", "cef-renderer",
              "cli", "windowserver", "bundle-other", "other"]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


signposts_lib = load("perf_signposts", "perf-signposts.py")
stress_lib = load("perf_stress_session", "perf-stress-session.py")


def uptime_us():
    """CLOCK_UPTIME_RAW (mach_absolute_time) in microseconds: the clock of every source in the trace."""
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW) / 1000.0


def continuous_minus_uptime_us():
    """mach_continuous_time minus mach_absolute_time in microseconds: how long the host slept since boot.
    `log` stamps machTimestamp with mach_continuous_time (CLOCK_MONOTONIC_RAW on Darwin), so a signpost's
    CLOCK_UPTIME_RAW time is its machTimestamp minus this (constant while the host stays awake)."""
    before = time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)
    continuous = time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)
    after = time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)
    return (continuous - (before + after) / 2) / 1000.0


def note(text):
    print(f"trace: {text}", flush=True)


def write_json(path, value):
    with open(path, "w") as f:
        json.dump(value, f, indent=1, default=str)


def read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


PERCENTILE_KEYS = ("p50", "p95", "p99", "max")


def pct(values):
    """n, p50, p95, p99 and max from perf_stats.summary (the lab's one definition: linear interpolation), each
    rounded to 0.01 ms; None when empty."""
    if not values:
        return None
    summary = perf_stats.summary(values)
    return {"n": summary["n"], **{key: round(summary[key], 2) for key in PERCENTILE_KEYS}}


# ---------------------------------------------------------------- stages

# Inner timeouts of the stages (each blocking call in a stage has its own); the stage bounds below are sums of them.
STAGE_MARGIN_S = 30  # added to a sum of inner timeouts: process start-up, `ps`, Python around the bounded calls
RPC_SHORT_S = 10  # a socket read that answers at once (debug.hangs clear, debug.window_list)
RPC_S = 20  # a socket read that walks the app's state (snapshot.get, debug.cef, debug.frames, debug.timings)
CLI_SETUP_S = 20  # one CLI call of the storm setup (a group create), as the storm's own calls
LOG_ATTACH_S = 15  # `log stream` prints its filter line
XCTRACE_START_S = 120  # xctrace prints "Starting recording"
XCTRACE_SAVE_S = 900  # xctrace processes and saves the recording after SIGINT
CDP_CONNECT_S = 20 + 5 + 15  # the connect loop's deadline, plus one attempt begun at it (urlopen 5 s, socket 15 s)
CDP_START_S = 30 + 10  # Tracing.start, Tracing.recordClockSyncMarker
SAMPLER_WAIT_S = 120  # every /usr/bin/sample of the window ends (they run at once, one shared deadline)
EXPORT_TOC_S = 300  # `xctrace export --toc`
EXPORT_TIMEOUT_S = 900  # one table export at most: a stuck export must not hold the GUI host (no export measured yet)
EXPORT_SCHEMAS = ("time-profile", "os-signpost", "syscall")
# BenchApp.stop (debug.quit 10 s, 30 s for the quit, 15 s after TERM) and TagTeardown.end for one acpmux home
# (`daemon shutdown` 30 s, again 30 s on a build before --end-agents) and one cmux-tui session (30 s), then its
# 15 s + 5 s + 0.5 s waits for the bundle's processes.
APP_STOP_S = 10 + 30 + 15 + 2 * 30 + 30 + 15 + 5 + 1
WRAP_GRACE_S = APP_STOP_S + STAGE_MARGIN_S  # a wrapped command's own teardown after SIGTERM (its BenchApp.stop)
WRAP_ORPHAN_GRACE_S = 15  # what the command left in its group, after SIGTERM: TagTeardown's wait for a bundle's processes
PS_S = 30  # one `ps` of the process table
# WrappedCommand.stop at most: a `ps`, the command's grace, a `ps`, the orphans' grace, a `ps`, the reap after
# SIGKILL (10 s) and the wait for the killed (5 s).
WRAP_STOP_S = PS_S + WRAP_GRACE_S + PS_S + WRAP_ORPHAN_GRACE_S + PS_S + 10 + 5
LAUNCH_S = 180 + 10 + 60  # BenchApp.launch: 180 s for the socket, 10 s for a crash report, a main-thread sample
PRIME_QUIT_S = RPC_SHORT_S + 30 + 15  # the priming app's debug.quit, its exit, then its exit after SIGTERM
COLD_STOP_S = 15 + 5  # the bundle's processes after SIGTERM (kqueue NOTE_EXIT), then after SIGKILL
PURGE_S = 120  # `sudo -n purge`
STARTUP_TRACE_CLOSE_S = 5  # debug.startup_trace's reply to the app's StartupTrace file read back whole

# Each stage of a recording has a bound. A stage that passes it ends loudly, its cleanup (`on_abort`) stops what
# it started, and the trace and summary are still written from what was recorded (job 7 on 2026-10-23 sat silent
# for over an hour after its STRESS build). The bounds catch a hung stage; they are not expectations.
# - A stage that owns processes or must finish a cleanup (recorders, each source's stop, the app's stop, the
#   export) has a bound above the sum of its inner timeouts, so it fires only when an inner timeout failed to;
#   its cleanup is bounded by construction (SIGKILL by exact PID or process group, no unbounded wait).
# - The build stages run hundreds of socket actions with 120 s timeouts each (a sum of hours) and own no process:
#   their bound comes from a measurement (about 2.5 times it), and a cut ends the recording (fatal) with nothing
#   left behind.
STAGE_BOUNDS_S = {
    "preflight": PS_S + STAGE_MARGIN_S,  # one `ps`: no process of the bundle may run yet
    # BenchApp.launch: 180 s for the socket, 10 s for a crash report, a 60 s main-thread sample of a silent app.
    "launch": LAUNCH_S + STAGE_MARGIN_S,
    "prime": LAUNCH_S + PRIME_QUIT_S + STAGE_MARGIN_S,  # launch-*: the priming launch and its quit
    "cold-prep": PS_S + COLD_STOP_S + PURGE_S + STAGE_MARGIN_S,  # launch-cold: stop the bundle, purge
    "stress-build": 1800,    # measured 691 s on cmux-lawrence-2 (macOS 27.0.1), 2026-10-23
    # Not measured: about 13 actions (4 workspaces, 1 workspace shown and split, 5 tabs, window placement) where
    # the STRESS build ran about 200 in 691 s (3.5 s each on a loaded host), so ~45 s, plus a cold Chromium start
    # (the first Chromium tab), times 2.5.
    "light-build": 300,
    # 4 group creates (CLI_SETUP_S each), snapshot.get, debug.cef, debug.window_list.
    "storm-setup": 4 * CLI_SETUP_S + 2 * RPC_S + RPC_SHORT_S + STAGE_MARGIN_S,
    # log stream attach, xctrace start (and its --attach fallback), CDP connect and Tracing.start, debug.hangs clear,
    # `cmux trace record`'s note that it records (--release).
    "recorders-start": LOG_ATTACH_S + 2 * XCTRACE_START_S + CDP_CONNECT_S + CDP_START_S + RPC_SHORT_S + RELEASE_START_S
    + STAGE_MARGIN_S,
    # Added to --seconds (or --seconds-cap): the window's 2 s of settle and the typist's and storm's joins (30 s each,
    # after the call each has in flight). Also xctrace's own --time-limit past the window.
    "window-margin": 2 + 30 + 30 + STAGE_MARGIN_S,
    "driver-stop": 30 + 30 + STAGE_MARGIN_S,   # the typist's and the storm's joins
    "wrap-stop": WRAP_STOP_S + STAGE_MARGIN_S,  # WrappedCommand.stop; its cleanup is the group's SIGKILL
    "teardown-rpc": RPC_S + STAGE_MARGIN_S,  # debug.frames stop, debug.timings
    "startup-trace": RPC_S + STARTUP_TRACE_CLOSE_S + STAGE_MARGIN_S,  # debug.startup_trace, then the file closed
    "window-state": RPC_SHORT_S + STAGE_MARGIN_S,  # debug.window_list at the window's end
    # Tracing.end, then IO.read of at most a 128 MB buffer; every call bounded (not measured). A cut drops the
    # DevTools socket (no process of ours) and loses only the Chromium events.
    "chromium-stop": 600,
    "stop-hangs": 15 + RPC_SHORT_S + STAGE_MARGIN_S,  # the drain thread's join, the last drain
    "stop-spans": 1 + 10 + 10 + STAGE_MARGIN_S,  # tail -F: the last line's arrival, TERM and its exit, the reader's join
    "stop-sampler": SAMPLER_WAIT_S + 5 + STAGE_MARGIN_S,
    "stop-signposts": 15 + 15 + STAGE_MARGIN_S,  # log stream: SIGINT and its exit, the reader's join
    # `cmux trace record` ends its own window, then collects (RELEASE_COLLECT_S); its window's rest is added at the
    # stop (ReleaseTrace.remaining_s).
    "release-trace-stop": RELEASE_COLLECT_S + STAGE_MARGIN_S,
    "xctrace-save": XCTRACE_SAVE_S + 30 + STAGE_MARGIN_S,  # XcTrace.stop: the save, then its reader's end
    "raw-files": 30 + STAGE_MARGIN_S,  # the end `ps` snapshot and the driver's events
    "app-stop": APP_STOP_S + STAGE_MARGIN_S,
    "export": EXPORT_TOC_S + len(EXPORT_SCHEMAS) * EXPORT_TIMEOUT_S + STAGE_MARGIN_S,
    "build": 900,            # the merge and the summary (Python over the exported XML)
}
HEARTBEAT_S = 60  # a stage that runs longer prints that it is still running once a minute
STAGE_ERRORS = (Exception, LaunchError)  # a stage's own failure; a signal's SystemExit and Ctrl-C end the run


class StageTimeout(BaseException):
    """A recording stage passed its bound (raised in the main thread by the stage's interval timer).

    A BaseException, as KeyboardInterrupt is: the build stages spend their time inside perf-stress-session.py's
    `wait()`, whose predicate runs under `except Exception` (the app may not answer yet). A timeout raised there
    as an Exception was swallowed, the one-shot timer never fired again, and the stage ran for the sum of its
    inner timeouts. Only Stages._Run.__exit__, Recording.record and the self-test catch it, by name."""

    def __init__(self, name, bound):
        super().__init__(f"stage {name} passed its bound of {bound:g} s")
        self.name, self.bound = name, bound


class Stages:
    """Runs each stage of a recording under its bound, with a heartbeat, and records it in `meta`.

    `run(name, bound)` arms SIGALRM for the bound (main thread only, one stage at a time): when it fires, the
    blocking call in the stage raises StageTimeout. A stage whose body raises an error (STAGE_ERRORS: a CDP
    error, a socket timeout, a failed launch, a wrong STRESS shape) is recorded the same way in
    `meta["errors"]`. Either way `on_abort` cleans up what the stage started (it runs with no timer armed and
    must be bounded by construction) and the stage ends. A fatal stage re-raises (nothing after it can run);
    any other stage lets the recording go on with its next stage. A signal's SystemExit or Ctrl-C passes
    through unrecorded.

    `hold()` defers the bound across a spawn and the assignment that records the child on its owner: a bound
    that fires there raises when the hold ends, so no child is ever started that the cleanup cannot see.
    """

    def __init__(self, meta, heartbeat_s=HEARTBEAT_S, log=None):
        self.meta, self.heartbeat_s, self.log = meta, heartbeat_s, log or note
        meta.setdefault("stages", [])
        meta.setdefault("timed_out", [])
        meta.setdefault("errors", [])
        self.active = None
        self.held = 0
        self.pending = None
        self.failures = []  # the exceptions already recorded (`note_error` records each one once)

    def _alarm(self, _signum, _frame):
        if self.held:
            self.pending = self.active
            return
        name, bound = self.active
        raise StageTimeout(name, bound)

    @contextlib.contextmanager
    def hold(self):
        self.held += 1
        try:
            yield
        finally:
            self.held -= 1
            if not self.held and self.pending:
                (name, bound), self.pending = self.pending, None
                raise StageTimeout(name, bound)

    def note_error(self, stage, error):
        """Records `error` once (a fatal stage's error passes this way twice: from the stage, then the run)."""
        if any(error is seen for seen in self.failures):
            return
        self.failures.append(error)
        text = f"{type(error).__name__}: {error}".strip()[:600]
        self.meta["errors"].append({"stage": stage, "error": text})
        self.log(f"STAGE {stage.upper()} FAILED: {text}")

    class _Run:
        def __init__(self, stages, name, bound, fatal, on_abort):
            self.stages, self.name, self.bound, self.fatal, self.on_abort = stages, name, bound, fatal, on_abort

        def __enter__(self):
            stages = self.stages
            if stages.active:
                raise RuntimeError(f"stage {self.name} inside stage {stages.active[0]}")
            stages.active = (self.name, self.bound)
            self.started = time.monotonic()
            self.done = threading.Event()

            def heartbeat():
                while not self.done.wait(stages.heartbeat_s):  # a progress line, not a wait for a condition
                    stages.log(f"stage {self.name} still running after {time.monotonic() - self.started:.0f} s "
                               f"(bound {self.bound:g} s)")

            threading.Thread(target=heartbeat, name=f"heartbeat-{self.name}", daemon=True).start()
            self.previous = signal.signal(signal.SIGALRM, stages._alarm)
            signal.setitimer(signal.ITIMER_REAL, self.bound)
            return self

        def __exit__(self, kind, error, _traceback):
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, self.previous)
            self.done.set()
            stages = self.stages
            stages.active = None
            stages.pending = None
            seconds = round(time.monotonic() - self.started, 1)
            timed_out = isinstance(error, StageTimeout)
            failed = not timed_out and isinstance(error, STAGE_ERRORS)
            row = {"stage": self.name, "seconds": seconds, "bound_s": self.bound, "timed_out": timed_out}
            if failed:
                row["error"] = f"{type(error).__name__}: {error}"[:300]
            stages.meta["stages"].append(row)
            if not (timed_out or failed):
                return False
            if timed_out:
                stages.meta["timed_out"].append(self.name)
                stages.log(f"STAGE {self.name.upper()} PASSED ITS BOUND OF {self.bound:g} s: ending it; the trace "
                           f"and summary are written from what was recorded")
            else:
                stages.note_error(self.name, error)
            if self.on_abort:
                try:
                    self.on_abort()
                except Exception as cleanup:  # recorded, so a failed cleanup never hides the stage's own end
                    stages.note_error(f"{self.name} cleanup", cleanup)
            return not self.fatal

    def run(self, name, bound=None, fatal=False, on_abort=None):
        return self._Run(self, name, STAGE_BOUNDS_S[name] if bound is None else bound, fatal, on_abort)


# ---------------------------------------------------------------- processes

def role_of(command, bundle):
    """The cmux role of a process from its command line, or None for a process outside the bundle."""
    exe = command.split(" --", 1)[0]
    if exe.endswith("/WindowServer") or "/WindowServer " in command[:200]:
        return "windowserver"
    if not bundle:
        return None
    for prefix in (bundle, "/private" + bundle if bundle.startswith(("/var/", "/tmp/")) else None):
        if prefix and command.startswith(prefix + "/"):
            rest = command[len(prefix) + 1:]
            break
    else:
        return None
    if rest.startswith("Contents/MacOS/"):
        return "app"
    if "Helper (GPU)" in rest:
        return "cef-gpu"
    if "Helper (Renderer)" in rest:
        return "cef-renderer"
    if "Contents/Frameworks/" in rest and " Helper" in rest:
        return "cef-utility"
    if "/bin/acpmux" in rest:
        return "acpmux"
    if "/bin/cmux-tui" in rest:
        if " __holder" in rest:
            return "holder"
        if " __terminal-host" in rest:
            return "terminal-host"
        return "daemon"
    if re.search(r"/bin/cmux( |$)", rest):
        return "cli"
    return "bundle-other"


def role_from_name(name):
    """A role from a process name alone (wrap mode, or a process that ended before a ps snapshot)."""
    if not name:
        return "other"
    if name == "WindowServer":
        return "windowserver"
    if "Helper (GPU)" in name:
        return "cef-gpu"
    if "Helper (Renderer)" in name:
        return "cef-renderer"
    if name.startswith("cmux DEV") and "Helper" in name:
        return "cef-utility"
    if name == "cmux":
        # The bundled CLI (Contents/Resources/bin/cmux). A storm's CLI processes live for milliseconds and are in
        # neither ps snapshot, so their name is all the trace has; an app whose executable is `cmux` gets its role from
        # its path when a ps snapshot has it (role_of), else from its action signposts (find_app_pid).
        return "cli"
    if name.startswith("cmux DEV") or name.startswith("cmux NIGHTLY"):
        return "app"
    if name.startswith("cmux-tui"):
        return "daemon"
    if name == "acpmux":
        return "acpmux"
    return "other"


def ps_snapshot(bundle):
    """{pid: {role, command, ppid}} of the bundle's processes and WindowServer."""
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    found = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3 or not parts[0].isdigit():
            continue
        role = role_of(parts[2], bundle)
        if role:
            found[int(parts[0])] = {"role": role, "command": parts[2][:400], "ppid": int(parts[1])}
    return found


# ---------------------------------------------------------------- recorders

class SignpostStream:
    """`log stream --signpost` of the cmux subsystem, every process, drained to a file on a reader thread."""

    def __init__(self, path):
        self.path, self.proc, self.reader, self.file = path, None, None, None
        self.attached = threading.Event()
        self.marks = {}  # launch mark name -> Event, set by the reader when the watched app's `launch.mark` names it
        self.seen = collections.defaultdict(set)  # launch mark name -> the pids whose `launch.mark` named it
        self.pid = None  # the launched app's pid (`watch_pid`): the subsystem is every cmux-next app's on the host

    def watch_mark(self, name):
        """An Event the reader sets when the watched app's `launch.mark` signpost for the launch mark `name` arrives
        (LaunchSignposts message `<name> ms=<ms>`): a launch scenario waits on the stream it records, with no socket
        call into the launching app. Call before the launch; `watch_pid` names the app at its spawn."""
        return self.marks.setdefault(name, threading.Event())

    def watch_pid(self, pid):
        """Scopes the watched marks to `pid` (another tag's app, a nightly or another job's app shares the
        subsystem). A mark the reader saw from `pid` before this call still counts: the reader records the pid before
        it reads `self.pid`, and this sets `self.pid` before it reads what the reader recorded."""
        self.pid = pid
        for name, event in self.marks.items():
            if pid in self.seen.get(name, ()):
                event.set()

    def _saw(self, line):
        if '"launch.mark"' not in line or not self.marks:
            return
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            return
        name = (event.get("eventMessage") or "").split(" ", 1)[0]
        if name not in self.marks:
            return
        pid = event.get("processID")
        self.seen[name].add(pid)
        if self.pid is not None and pid == self.pid:
            self.marks[name].set()

    def start(self, timeout=LOG_ATTACH_S, hold=contextlib.nullcontext):
        timebase = signposts_lib.local_timebase()
        self.file = open(self.path, "w")
        if timebase:
            self.file.write(f"#timebase {timebase[0]}/{timebase[1]}\n")
        # The file carries its own clock: `trace.py export` may run on another Mac, after this one slept.
        self.file.write(f"#continuous-minus-uptime-us {continuous_minus_uptime_us()}\n")

        def drain():
            # Reads for the whole run: a full pipe would block `log stream` and logd would drop events.
            for line in self.proc.stdout:
                self.file.write(line)
                self.attached.set()
                self._saw(line)
            self.attached.set()

        with hold():
            self.proc = subprocess.Popen(["/usr/bin/log", "stream", "--signpost", "--style", "ndjson", "--predicate",
                                          f'subsystem == "{SUBSYSTEM}"'], stdout=subprocess.PIPE, text=True, bufsize=1)
            self.reader = threading.Thread(target=drain, name="signposts", daemon=True)
            self.reader.start()
        if not self.attached.wait(timeout):  # the tool prints its filter line once attached
            note(f"log stream printed nothing in {timeout} s; recording anyway")

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        if self.reader:
            self.reader.join(timeout=15)
        self._close()

    def kill(self):
        """Ends `log stream` at once (its stop passed the bound)."""
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        if self.reader:
            self.reader.join(timeout=5)
        self._close()

    def _close(self):
        """Closes the file with the clock line of the recording's end (a sleep during it shows as a change),
        written only once the reader has ended (it writes the same file)."""
        if not self.file or self.file.closed:
            return
        if not (self.reader and self.reader.is_alive()):
            self.file.write(f"#continuous-minus-uptime-us-end {continuous_minus_uptime_us()}\n")
        self.file.close()


class XcTrace:
    """`xctrace record --all-processes`: Time Profiler with os_signpost and Points of Interest, or System Trace."""

    def __init__(self, out, system_trace=False, cap_s=900):
        self.path = os.path.join(out, "recording.trace")
        self.log_path = os.path.join(out, "xctrace.log")
        self.system_trace, self.cap_s = system_trace, cap_s
        self.attach = None  # a pid: only that process (when --all-processes is refused)
        self.proc, self.started = None, threading.Event()
        self.ended = threading.Event()
        self.interrupted_us = None  # when the one SIGINT was sent (`interrupt`)

    def command(self):
        template = "System Trace" if self.system_trace else "Time Profiler"
        target = ["--attach", str(self.attach)] if self.attach else ["--all-processes"]
        command = ["xcrun", "xctrace", "record", "--template", template, *target, "--output", self.path,
                   "--no-prompt", "--time-limit", f"{int(self.cap_s)}s"]
        extra = [] if self.system_trace else ["os_signpost", "Points of Interest"]  # System Trace has them
        for instrument in extra:
            command += ["--instrument", instrument]
        return command

    def start(self, timeout=XCTRACE_START_S, hold=contextlib.nullcontext):
        if os.path.exists(self.path):
            shutil.rmtree(self.path, ignore_errors=True)
        log = open(self.log_path, "w")

        def read():
            for line in self.proc.stdout:
                log.write(line)
                log.flush()
                if "Starting recording" in line or "Ctrl-C to stop" in line:
                    self.started.set()
            log.close()
            self.ended.set()
            self.started.set()

        with hold():
            self.proc = subprocess.Popen(self.command(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                         bufsize=1)
            threading.Thread(target=read, name="xctrace", daemon=True).start()
        self.started.wait(timeout)
        if self.proc.poll() is not None:
            raise RuntimeError(f"xctrace record exited {self.proc.returncode}: {open(self.log_path).read()[-800:]}")
        self.started_us = uptime_us()
        self.started_wall = time.time()

    def interrupt(self):
        """Ends the recording now (SIGINT, as Ctrl-C); xctrace then processes and saves it (``stop`` waits).

        Sends SIGINT once only: the stop path calls this at the window's end and again from ``stop`` minutes
        later, while xctrace still processes and saves, and a second Ctrl-C there can make it abort the save."""
        if self.interrupted_us is None and self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            self.interrupted_us = uptime_us()

    def kill(self):
        """Ends xctrace without saving (its save passed the bound)."""
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()

    def stop(self, timeout=XCTRACE_SAVE_S):
        """Waits for the save (after the one SIGINT, sent here when the window's end did not); True when the
        recording exists."""
        if self.proc is None:
            return False
        self.interrupt()
        try:
            self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.ended.wait(30)
        return os.path.exists(self.path)


class Sampler:
    """The fallback recorder: `/usr/bin/sample` of the app and the daemon for the window (aggregate stacks,
    every thread, waiting ones too; no timeline)."""

    def __init__(self, out):
        self.out, self.procs = out, []

    def start(self, pids, seconds, hold=contextlib.nullcontext):
        for pid, role in pids:
            path = os.path.join(self.out, f"sample-{role}-{pid}.txt")
            with hold():
                self.procs.append((subprocess.Popen(["/usr/bin/sample", str(pid), str(max(1, int(seconds))), "1",
                                                     "-mayDie", "-file", path], stdout=subprocess.DEVNULL,
                                                    stderr=subprocess.DEVNULL), path))

    def stop(self, timeout=SAMPLER_WAIT_S):
        deadline = time.monotonic() + timeout  # they run at once: one deadline for all, not one per process
        for proc, _ in self.procs:
            try:
                proc.wait(timeout=max(0.0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)

    def kill(self):
        """Ends every sample at once (their stop passed the bound)."""
        for proc, _ in self.procs:
            if proc.poll() is None:
                proc.kill()
                proc.wait()


class FileFollower:
    """Follows a file that another process appends lines to (`tail -F`, kqueue driven), stamping each line
    with the time it arrived: the daemon's debug spans carry durations only, no clock."""

    def __init__(self, source, stamped):
        self.source, self.stamped, self.proc, self.thread, self.out = source, stamped, None, None, None

    def start(self, hold=contextlib.nullcontext):
        open(self.source, "a").close()
        self.out = open(self.stamped, "w")

        def read():
            for line in self.proc.stdout:
                line = line.strip()
                if line:
                    self.out.write(json.dumps({"at_us": uptime_us(), "line": line}) + "\n")
                    self.out.flush()

        with hold():
            self.proc = subprocess.Popen(["/usr/bin/tail", "-F", "-n", "+1", self.source], stdout=subprocess.PIPE,
                                         text=True, bufsize=1, stderr=subprocess.DEVNULL)
            self.thread = threading.Thread(target=read, name="spans", daemon=True)
            self.thread.start()

    def stop(self):
        time.sleep(0.3)  # the last line written before the stop reaches tail (one kqueue wakeup)
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            self.proc.wait(timeout=10)
        if self.thread:
            self.thread.join(timeout=10)
        if self.out:
            self.out.close()

    def kill(self):
        """Ends `tail -F` at once (its stop passed the bound or failed)."""
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        if self.thread:
            self.thread.join(timeout=5)
        if self.out:
            self.out.close()


class HangDrain(threading.Thread):
    """Drains the app's watchdog ring (`debug.hangs`, 128 records) every second by sequence, so a long run loses
    none; counts sequence gaps (records the ring dropped before a drain). `from_start`: the drain reads an app
    whose watchdog it has drained since the app's start (the ring's sequence starts at 1), so records missing below the
    first kept sequence are dropped ones too (a launch scenario's single drain after the launch)."""

    def __init__(self, rpc, path, from_start=False):
        super().__init__(name="hangs", daemon=True)
        self.rpc, self.path, self.from_start = rpc, path, from_start
        self.records, self.after, self.gaps = [], 0, 0
        self.stop_flag = threading.Event()

    def drain(self):
        reply = self.rpc("debug.hangs", {"after": self.after}, timeout=10)
        if not isinstance(reply, dict) or reply.get("error"):
            return reply
        for record in reply.get("records") or []:
            sequence = int(record.get("sequence") or 0)
            if (self.after or self.from_start) and sequence > self.after + 1:
                self.gaps += sequence - self.after - 1
            self.after = max(self.after, sequence)
            self.records.append(record)
        self.summary = {k: reply.get(k) for k in ("installed", "threshold_ms", "count", "busy_count", "max_ms", "total_ms",
                                                  "long_frames", "frames_over_8_3ms", "max_gap_ms")}
        return reply

    def run(self):
        while not self.stop_flag.wait(1.0):  # the ring holds 128 records: one drain a second keeps them all
            self.drain()

    def stop(self):
        self.stop_flag.set()
        if self.is_alive():
            self.join(timeout=15)
        self.drain()
        self.save()

    def kill(self):
        """Ends the drain without a last read (its stop passed the bound or failed): saves what it read."""
        self.stop_flag.set()
        self.save()

    def save(self):
        write_json(self.path, {"records": list(self.records), "dropped": self.gaps,
                               "summary": getattr(self, "summary", None)})


class ChromiumTracer:
    """Chromium's own trace over CDP on the Debug build's DevTools port: every Chromium process."""

    def __init__(self, port, out):
        self.port, self.out = port, out
        self.path = os.path.join(out, "chromium-trace.json")
        self.session = None
        self.clock = None

    def start(self, timeout=20):
        from ext_e2e import cdp
        deadline = time.monotonic() + timeout
        error = None
        while time.monotonic() < deadline:  # the browser process opens its port when Chromium starts
            try:
                self.session = cdp.browser(self.port)
                break
            except (OSError, ValueError, KeyError) as caught:
                error = caught
                time.sleep(0.5)
        if not self.session:
            raise RuntimeError(f"no DevTools port {self.port}: {error}")
        self.session.call("Tracing.start", {
            "transferMode": "ReturnAsStream", "streamFormat": "json",
            "traceConfig": {"recordMode": "recordContinuously", "traceBufferSizeInKb": CHROME_BUFFER_KB,
                            "includedCategories": CHROME_CATEGORIES, "excludedCategories": ["*"]}}, timeout=30)
        self.sync_id = f"cmux-trace-{os.getpid()}"
        before = uptime_us()
        self.session.call("Tracing.recordClockSyncMarker", {"syncId": self.sync_id}, timeout=10)
        after = uptime_us()
        self.clock = {"sync_id": self.sync_id, "before_us": before, "after_us": after}

    def wait_event(self, method, timeout):
        self.session.sock.settimeout(timeout)
        while True:
            message = self.session._recv()
            if message.get("method") == method:
                return message.get("params") or {}

    def close(self):
        """Drops the DevTools connection (its transfer passed the bound); the partial file is removed."""
        if self.session:
            self.session.close()
        if os.path.exists(self.path):
            os.unlink(self.path)

    def stop(self):
        if not self.session:
            return False
        try:
            self.session.call("Tracing.end", timeout=60)
            stream = self.wait_event("Tracing.tracingComplete", 300).get("stream")
            with open(self.path, "w") as f:
                while stream:
                    chunk = self.session.call("IO.read", {"handle": stream, "size": 4 << 20}, timeout=120)
                    data = chunk.get("data") or ""
                    if chunk.get("base64Encoded"):
                        import base64
                        data = base64.b64decode(data).decode("utf-8", "replace")
                    f.write(data)
                    if chunk.get("eof"):
                        break
                if stream:
                    self.session.call("IO.close", {"handle": stream}, timeout=30)
            write_json(os.path.join(self.out, "chromium-clock.json"), self.clock)
            return True
        finally:
            self.session.close()


class ReleaseTrace:
    """`record --release`: the Release trace path instead of the DEBUG knobs (CMUX_NEXT_TRACE_FLOWS, the daemon span
    file, the DevTools port). `cmux trace record` (p09-observability 021) calls the app's trace.start with key flows
    (`--keys`) and Chromium tracing (`--chromium`); the daemon forwards the start to the holder, the terminal hosts and
    acpmux. At the end the CLI copies every ring and Chromium's JSON into OUT/rings. The CLI times the recording
    itself (`--seconds`, whole seconds from its trace.start reply), so it starts last among the recorders, the window
    starts once it says it records, and the stop waits for it."""

    def __init__(self, cli, socket, out, seconds, chromium, env=None):
        self.cli, self.socket, self.chromium, self.env = cli, socket, chromium, env
        self.seconds = math.ceil(seconds)
        self.dir = os.path.join(out, RELEASE_DIR)
        self.log_path = os.path.join(out, RELEASE_LOG)
        self.process = self.started = self.log = self.reader = None
        self.spoke = threading.Event()  # the CLI's first line came, or its output ended
        self.silent_end = False  # its output ended before any line

    def command(self):
        return [self.cli, "--app-socket", self.socket, "trace", "record", "--seconds", str(self.seconds),
                "--out", self.dir, "--keys"] + (["--chromium"] if self.chromium else [])

    def start(self, hold=contextlib.nullcontext, start_s=RELEASE_START_S):
        """Starts the CLI and waits, at most `start_s`, for its first line: the note it prints once trace.start
        replied and the rings record (a CLI whose start failed prints its error instead and ends with a nonzero exit,
        which the stop reports). Its window counts from then. Returns False when it said nothing in time or ended
        saying nothing."""
        os.makedirs(self.dir, exist_ok=True)
        self.log = open(self.log_path, "wb")
        with hold():
            self.process = subprocess.Popen(self.command(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                            stdin=subprocess.DEVNULL, env=self.env)
        self.reader = threading.Thread(target=self.copy_output, name="cmux-trace-record-log", daemon=True)
        self.reader.start()
        spoke = self.spoke.wait(start_s)
        self.started = time.monotonic()
        return spoke and not self.silent_end

    def copy_output(self):
        """The reader thread: the CLI's output into its log file; the first line (or the end) sets `spoke`."""
        for line in self.process.stdout:
            self.log.write(line)
            self.log.flush()
            if line.strip():
                self.spoke.set()
        self.silent_end = not self.spoke.is_set()
        self.spoke.set()

    def remaining_s(self):
        """The rest of the CLI's own window, from now."""
        if self.started is None:
            return 0.0
        return max(0.0, self.started + self.seconds - time.monotonic())

    def stop(self, collect_s=RELEASE_COLLECT_S):
        """Waits for the CLI to end its window and collect: {exit, command, files, log_tail}. A CLI that does not end
        in time raises TimeoutExpired (the stage then kills it)."""
        if not self.process:
            return None
        code = self.process.wait(timeout=self.remaining_s() + collect_s)
        self.close_log()
        with open(self.log_path, errors="replace") as f:
            tail = f.read()[-1200:]
        files = sorted(os.listdir(self.dir)) if os.path.isdir(self.dir) else []
        return {"exit": code, "command": self.command(), "files": files, "log_tail": tail}

    def close_log(self):
        """Closes the log once the reader copied the CLI's last line (its output ends when it exits), waiting
        RPC_SHORT_S at most."""
        if self.reader:
            self.reader.join(RPC_SHORT_S)
        if self.log and not (self.reader and self.reader.is_alive()):
            self.log.close()

    def kill(self):
        """SIGKILL the CLI this run started (its stop passed the bound or failed)."""
        if self.process and self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        self.close_log()


# ---------------------------------------------------------------- scenario

class Storm(threading.Thread):
    """CLI calls at `hz` through the app's bundled CLI, as agents rearrange the sidebar."""

    STATUSES = ["todo", "working", "needs-attention", "review", "done"]

    def __init__(self, cli, workspaces, groups, hz, events):
        super().__init__(name="storm", daemon=True)
        self.cli, self.workspaces, self.groups, self.period, self.events = cli, workspaces, groups, 1.0 / hz, events
        self.stop_flag = threading.Event()
        self.ops = collections.Counter()

    def run(self):
        import random
        rng = random.Random(7)
        kinds = ["move", "task", "group", "pill"]
        index = 0
        while not self.stop_flag.is_set() and self.workspaces:
            kind = kinds[index % len(kinds)]
            index += 1
            ws = rng.choice(self.workspaces)
            if kind == "move":
                args = ["workspace", ws, "move", "--index", "0"]
            elif kind == "task":
                args = ["workspace", ws, "update", "--task-status", rng.choice(self.STATUSES)]
            elif kind == "group" and self.groups:
                args = ["workspace", "group", rng.choice(self.groups), "add", "--workspace", ws, "--index", "0"]
            else:
                args = ["workspace", ws, "status", "set", "trace", f"step {index}"]
            start = uptime_us()
            done = self.cli(*args, timeout=20)
            end = uptime_us()
            self.ops[kind] += 1
            self.events.append({"kind": "cli", "name": f"cli {' '.join(args[:3])}", "start_us": start, "end_us": end,
                                "args": {"argv": " ".join(args), "exit": done.returncode}})
            rest = self.period - (end - start) / 1e6
            if rest > 0:
                self.stop_flag.wait(rest)  # the storm's pace

    def stop(self):
        self.stop_flag.set()
        self.join(timeout=30)


CHORDS = [  # pairs, so the session comes back to the same shape
    [("t", ["cmd"], "newTab.default"), ("w", ["cmd"], "closeTab")],
    [("d", ["cmd"], "splitRight"), ("w", ["cmd"], "closeTab")],
    [("]", ["ctrl", "cmd"], "nextSidebarTab"), ("[", ["ctrl", "cmd"], "prevSidebarTab")],
]


class Typist(threading.Thread):
    """Keys into the focused terminal through the app's key path (`debug.key` with the send time as the event's
    timestamp, so the action signposts carry an input age), and every `chord_every` keys an action pair."""

    def __init__(self, rpc, interval, chord_every, events):
        super().__init__(name="typist", daemon=True)
        self.rpc, self.interval, self.chord_every, self.events = rpc, interval, chord_every, events
        self.stop_flag = threading.Event()
        self.keys = 0
        self.chords = collections.Counter()

    def send(self, key, modifiers=(), label=None):
        start = uptime_us()
        reply = self.rpc("debug.key", {"key": key, "modifiers": list(modifiers), "timestamp": start / 1e6}, timeout=15)
        end = uptime_us()
        self.events.append({"kind": "key", "name": label or f"key {key}", "start_us": start, "end_us": end,
                            "args": {"key": key, "modifiers": list(modifiers),
                                     "error": reply.get("error") if isinstance(reply, dict) else None}})

    def run(self):
        letters = "abcdefghijklmnopqrstuvwxyz"
        pair = 0
        while not self.stop_flag.is_set():
            t0 = time.monotonic()
            if self.chord_every and self.keys and self.keys % self.chord_every == 0:
                for key, modifiers, action in CHORDS[pair % len(CHORDS)]:
                    self.send(key, modifiers, label=f"chord {'+'.join(modifiers)}+{key} ({action})")
                    self.chords[action] += 1
                    self.stop_flag.wait(0.35)  # the chord's own frames land before its partner
                pair += 1
            self.send(letters[self.keys % len(letters)])
            self.keys += 1
            rest = self.interval - (time.monotonic() - t0)
            if rest > 0:
                self.stop_flag.wait(rest)  # one key in flight at a time

    def stop(self):
        self.stop_flag.set()
        self.join(timeout=30)


def storm_setup(app, rpc):
    """Groups for the storm and the workspace ids it rearranges (all but the shown one)."""
    groups = []
    for index in range(4):
        name = f"trace group {index}"
        if app.cli_run("workspace", "group", "create", "--name", name, timeout=CLI_SETUP_S).returncode == 0:
            groups.append(name)
    reply = rpc("snapshot.get", timeout=RPC_S)
    topology = (reply.get("topology") or {}) if isinstance(reply, dict) else {}
    shown = (topology.get("focus") or {}).get("workspace")
    workspaces = [w["id"] for w in topology.get("workspaces") or [] if w.get("id") and w.get("id") != shown]
    return groups, workspaces


def cef_validity(reply, web_dev_config=None):
    """Measurement validity (perf-lead brief) from a `debug.cef` reply: valid when Chromium's start state is
    `ready`, `unavailable` and `fallback` are null and no dev-server config routes the pages
    (`cef_problems` of perf-stress-session.py, the check STRESS itself uses). The reply always carries the keys
    `unavailable` and `fallback` (null when healthy), so their names alone say nothing."""
    problems = stress_lib.cef_problems(reply, web_dev_config)
    return {"valid": not problems, "problems": problems,
            "state": reply.get("state") if isinstance(reply, dict) else None,
            "excerpt": json.dumps(reply, default=str)[:400]}


def window_state(rpc):
    """Whether the app's main window is key now (`debug.window_list`; a key window means an active app), as
    pane-perf-terminal.py reads it; None when the app does not say."""
    reply = rpc("debug.window_list", timeout=RPC_SHORT_S)
    windows = reply.get("windows") if isinstance(reply, dict) else None
    if not isinstance(windows, list):
        return {"window_key": None}
    return {"window_key": any(w.get("key") for w in windows if w.get("kind") == "main" and w.get("visible"))}


def scenario_label(scenario, reads):
    """The run's label from its `window_state` reads (the window's start and end): `<scenario>` when every read
    says key, `<scenario>-inactive` when one says not key, else `<scenario>-key-unknown`."""
    keys = [read.get("window_key") for read in reads]
    if any(key is False for key in keys):
        return scenario + "-inactive"
    if keys and all(key is True for key in keys):
        return scenario
    return scenario + "-key-unknown"


def read_probe(path):
    import csv
    try:
        with open(path) as f:
            return list(csv.DictReader(f))
    except OSError:
        return []


# ---------------------------------------------------------------- wrapped command

def wait_exits(pids, timeout):
    """Waits until every pid in `pids` (processes that are not our children) exits, or `timeout` passes, on
    kqueue NOTE_EXIT (no polling). Returns the set still running."""
    alive = set()
    kq = select.kqueue()
    try:
        for pid in pids:
            try:
                kq.control([select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                          select.KQ_NOTE_EXIT)], 0)
                alive.add(pid)
            except OSError:  # ESRCH: it already exited
                pass
        deadline = time.monotonic() + timeout
        while alive:
            left = deadline - time.monotonic()
            if left <= 0:
                break
            for event in kq.control(None, len(alive), left):
                alive.discard(event.ident)
    finally:
        kq.close()
    return alive


class WrappedCommand:
    """Wrap mode's COMMAND, in a session and process group of its own (its pid is the group id).

    `stop()` ends the whole group. SIGTERM goes to the command itself first, with up to `grace` seconds for its
    own teardown (a wrapper such as every-action-sweep.py quits the app it launched through BenchApp.stop,
    `debug.quit` with end-sessions, then TagTeardown): a SIGTERM to the whole group at once would reach that app
    directly, before the wrapper's quit. Then whatever of the group is left gets SIGTERM, `orphan_grace` seconds
    (TagTeardown's own wait for a bundle's processes after their shutdown) and SIGKILL. The app a wrapper
    launches is in the group; daemons that start a session of their own are not (the bundle's tag teardown after
    a stopped command ends those, `Recording.stop_app`).
    """

    def __init__(self, argv, grace=WRAP_GRACE_S, orphan_grace=WRAP_ORPHAN_GRACE_S):
        self.argv, self.grace, self.orphan_grace = list(argv), grace, orphan_grace
        self.proc, self.exit, self.signalled = None, None, False

    def start(self, hold=contextlib.nullcontext):
        with hold():
            self.proc = subprocess.Popen(self.argv, start_new_session=True)

    def wait(self):
        self.exit = self.proc.wait()
        return self.exit

    def members(self):
        """PIDs in the command's process group that still run, its leader included while it runs."""
        if self.proc is None:
            return []
        out = subprocess.run(["ps", "-axo", "pid=,pgid=,stat="], capture_output=True, text=True, timeout=PS_S).stdout
        found = []
        for line in out.splitlines():
            parts = line.split()
            # A zombie (stat Z) has exited and runs nothing; its parent or launchd reaps it.
            if len(parts) == 3 and parts[1] == str(self.proc.pid) and parts[0].isdigit() and not parts[2].startswith("Z"):
                found.append(int(parts[0]))
        return found

    def _signal_group(self, number):
        try:
            os.killpg(self.proc.pid, number)  # the group this script started (start_new_session), never a pattern
        except ProcessLookupError:
            pass

    def stop(self):
        """Ends the group and returns a record for meta, or None when the command and every process of its group
        already ended (nothing to stop). Bounded: WRAP_STOP_S."""
        if self.proc is None:
            return None
        leader = self.proc.pid
        others = [pid for pid in self.members() if pid != leader]
        if self.proc.poll() is not None and not others:
            return None
        self.signalled = True
        note(f"wrap: stopping the command {leader} (SIGTERM, {self.grace:g} s for its own teardown), then what is "
             f"left of its process group (SIGTERM, {self.orphan_grace:g} s, then SIGKILL)")
        if self.proc.poll() is None:
            try:
                os.kill(leader, signal.SIGTERM)  # the command this script started, by its exact PID
            except ProcessLookupError:
                pass
            try:
                self.proc.wait(timeout=self.grace)
            except subprocess.TimeoutExpired:
                pass
        rest = [pid for pid in self.members() if pid != leader]
        left = set()
        if rest:
            self._signal_group(signal.SIGTERM)
            left = wait_exits(rest, self.orphan_grace)
        killed = sorted(left | {pid for pid in self.members() if pid != leader})
        if self.proc.poll() is None or killed:
            self.kill()
            wait_exits(killed, 5)
        self.exit = self.proc.returncode
        return {"exit": self.exit, "signalled": True, "killed": killed[:20]}

    def kill(self):
        """SIGKILL to the whole group and a bounded reap of the command (the wrap-stop stage passed its bound)."""
        if self.proc is None:
            return
        self.signalled = True
        self._signal_group(signal.SIGKILL)
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        self.exit = self.proc.returncode


# ---------------------------------------------------------------- the app

class TraceApp:
    """The tagged app under trace: BenchApp plus the trace's environment and the bundled CLI.

    The app activates and its window becomes key where the host allows it (no CMUX_NEXT_NO_ACTIVATE, as
    pane-perf-terminal.py): an inactive window's key routing and frame pacing are not a person's. Without
    no-activate the app reads no test window frame, so the window is placed through the socket
    (`place_window`, the STRESS size on the main screen)."""

    def __init__(self, path, out, opts):
        from bench_launch import BenchApp
        self.spans = os.path.join(out, "daemon-spans.jsonl")
        self.probe = os.path.join(out, "typing.csv")
        self.flows = os.path.join(out, "flows")
        os.makedirs(self.flows, exist_ok=True)
        self.startup_dir = os.path.join(out, STARTUP_DIR)
        launch = opts.scenario in LAUNCH_SCENARIOS
        # The app keeps only CMUX_NEXT_* launch knobs (LaunchIdentity strips every other inherited CMUX* variable):
        # the daemon launch passes these two on as CMUX_TRACE_FLOWS and CMUX_TUI_DEBUG_SPANS (DaemonDiagnosticKnobs),
        # and the daemon's terminal hosts and holder inherit them.
        hang_ms = min(opts.hang_ms, LAUNCH_TURN_MS) if launch else opts.hang_ms
        env = {"CMUX_NEXT_HANG_THRESHOLD_MS": str(hang_ms), "CMUX_NEXT_TYPING_PROBE": self.probe,
               "CMUX_NEXT_TUI_DEBUG_SPANS": self.spans, "CMUX_NEXT_TRACE_FLOWS": self.flows, "CMUX_NEXT_NO_ACTIVATE": None}
        self.cdp_port = None
        if opts.release:
            # The Release trace path records flows, daemon requests and Chromium itself (ReleaseTrace): none of the
            # DEBUG knobs, so the app runs as a person's does.
            for knob in ("CMUX_NEXT_TUI_DEBUG_SPANS", "CMUX_NEXT_TRACE_FLOWS"):
                env.pop(knob)
        elif not opts.no_cef and not launch:  # a launch traces Chromium through its own --trace-startup file
            self.cdp_port = opts.cdp_port or free_port()
            env["CMUX_NEXT_CEF_EXTRA_SWITCHES"] = f"remote-debugging-port={self.cdp_port}:remote-allow-origins=*"
        self.bench = BenchApp(path, out=out, env=env, window=None, screen=None)

    def startup_env(self, seconds):
        """The StartupTrace switches of the measured launch (p08-startup 004): trace `seconds` of the launch into
        DIR/startup. Both the spec's name and its CMUX_NEXT_ spelling, which LaunchIdentity keeps if the app reads
        the switch after its environment strip."""
        os.makedirs(self.startup_dir, exist_ok=True)
        path = os.path.join(self.startup_dir, STARTUP_APP_FILE)
        return {"CMUX_TRACE_STARTUP": f"{seconds:g}", "CMUX_TRACE_STARTUP_FILE": path,
                "CMUX_NEXT_TRACE_STARTUP": f"{seconds:g}", "CMUX_NEXT_TRACE_STARTUP_FILE": path}

    def rpc(self, method, params=None, timeout=60):
        return self.bench.rpc(method, params, timeout)

    def cli_env(self):
        """The bundled CLI's environment: none of this process's CMUX_* variables, the app's own config file."""
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        env["CMUX_NEXT_CONFIG_FILE"] = os.path.join(self.bench.scratch, "cmux.json")
        return env

    def cli_run(self, *args, timeout=120):
        env = self.cli_env()
        try:
            return subprocess.run([self.bench.cli, "--app-socket", self.bench.socket, *args], env=env, capture_output=True,
                                  text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(args, 124, "", "timeout")


def free_port():
    """A loopback TCP port nothing listens on now (several GUI jobs share a host)."""
    import socket
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def record(opts):
    """Records one scenario; returns the exit code (the module doc): the trace and summary are always written."""
    out = os.path.abspath(opts.out)
    os.makedirs(out, exist_ok=True)
    bundle = os.path.realpath(opts.app or opts.bundle).rstrip("/") if (opts.app or opts.bundle) else None
    meta = {"host": os.uname().nodename, "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True,
                                                                 text=True).stdout.strip(),
            "bundle": bundle, "scenario": "wrap" if opts.command else opts.scenario, "seconds": opts.seconds,
            "argv": sys.argv[1:], "recorder": None, "sources": {}, "warnings": []}
    recorder = opts.recorder
    if recorder == "auto":
        recorder = "xctrace" if subprocess.run(["xcrun", "xctrace", "version"], capture_output=True).returncode == 0 else "sample"
    meta["recorder"] = recorder
    return Recording(opts, out, meta, Stages(meta), bundle, recorder).record()


class Recording:
    """One `record` run. Everything it starts (the app, each recorder, the wrapped command, the storm and the
    typist) is held here before its process or thread starts, so `stop()` always reaches it, whichever stage
    passed its bound or failed (a stage's cleanup cannot see a local its blocking call never returned)."""

    def __init__(self, opts, out, meta, stages, bundle, recorder):
        self.opts, self.out, self.meta, self.stages, self.bundle, self.recorder = opts, out, meta, stages, bundle, recorder
        self.app = self.rpc = self.xc = self.sampler = self.spans = self.hangs = self.chromium = None
        self.signposts = self.wrapped = self.storm = self.typist = self.stress = self.phase = self.release = None
        self.groups, self.workspaces, self.driver_events, self.processes = [], [], [], {}
        self.frames_started, self.probe_before = None, 0
        self.xctrace_factory = XcTrace  # the self-test passes a stand-in
        self.xctrace_tool = ("xcrun", "xctrace")  # the export's tool (the self-test passes a stand-in)
        self.stopping = False
        self.terminated = None  # the exit code of a SIGTERM or SIGHUP that ended the run

    # The run.

    def record(self):
        meta, stages = self.meta, self.stages
        self.install_signals()
        try:
            self.setup_and_window()
        except StageTimeout:
            pass  # a fatal stage: Stages recorded it; what was recorded is still written below
        except STAGE_ERRORS as error:
            stages.note_error("record", error)  # once: a fatal stage's error is already recorded
        except SystemExit as error:  # SIGTERM or SIGHUP (a fleet cancel, an SSH drop): stop everything, no export
            self.terminated = error.code if isinstance(error.code, int) else 1
        finally:
            self.stopping = True  # a signal from here on waits for the stop (`install_signals`)
            if meta.get("window_end_us") is None:  # a launch scenario ends its window itself
                meta["window_end_us"] = uptime_us()
                if meta.get("window_start_us"):
                    note("window ends")
            try:
                self.stop()
            finally:
                write_json(os.path.join(self.out, "meta.json"), meta)
                self.stop_app()
                write_json(os.path.join(self.out, "meta.json"), meta)
        if self.terminated is None:
            try:
                # Every process of the run is stopped: a signal from here on ends the run at once (the export's
                # xctrace child is killed by subprocess.run), instead of waiting through the export and build.
                self.stopping = False
                self.finish()
            except SystemExit as error:  # SIGTERM or SIGHUP during the export or the build
                self.terminated = error.code if isinstance(error.code, int) else 1
                note(f"ended by a signal (exit {self.terminated}) during the export or the build; recording.trace is kept")
        else:
            note(f"ended by a signal (exit {self.terminated}): recorders and app stopped; no export")
        if self.terminated is not None:
            self.stopping = True  # the summary is written whole
            self.write_summary(None)
        return self.exit_code()

    def install_signals(self):
        """SIGTERM and SIGHUP end the run through its stop path (BenchApp.launch installs TagTeardown's handler,
        so this runs again after the launch). While the stop runs, a signal is recorded and the stop finishes;
        after it (the export and the build), a signal raises SystemExit at once."""
        def on_signal(signum, _frame):
            if self.stopping:
                self.terminated = 128 + signum
                note(f"signal {signum}: the recorders and the app are stopping first")
                return
            raise SystemExit(128 + signum)
        for number in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, on_signal)

    def warn(self, text):
        self.meta["warnings"].append(text)
        note(f"WARNING: {text}")

    def refuse_running_bundle(self):
        """Signal only processes this run started: the stop path ends the bundle's processes (BenchApp.stop's tag
        teardown, the wrap teardown, `kill_bundle`), and it cannot tell a process this run started from one that
        ran before it (another job's app of the same bundle, daemons an earlier run left, a person's app). So a
        bundle with any running process (TagTeardown's own match, the set those teardowns end) is refused, in
        both modes, as BenchApp.launch refuses a running app of its bundle."""
        if not self.bundle:
            return
        from tag_teardown import TagTeardown
        running = TagTeardown(self.bundle).processes()
        self.processes["before"] = {pid: command[:400] for pid, command in running}
        if running:
            listed = "; ".join(f"{pid} {command[len(self.bundle):][:80]}" for pid, command in running[:6])
            raise LaunchError("bundle-in-use", {"detail": f"{len(running)} process(es) of {self.bundle} already run "
                                                          f"({listed}); trace.py would end them in its teardown. "
                                                          f"Quit them or use a fresh tag", "log_tail": ""})

    def setup_and_window(self):
        opts, meta, stages = self.opts, self.meta, self.stages
        with stages.run("preflight", fatal=True):
            self.refuse_running_bundle()
        if opts.scenario in LAUNCH_SCENARIOS and opts.app and not opts.command:
            return self.launch_window()
        if opts.command:
            # The wrapped command launches its own app with its own environment (BenchApp's BASE_ENV sets
            # CMUX_NEXT_NO_ACTIVATE unless the command removes it): trace.py cannot say whether its window was key.
            meta["scenario_label"] = "wrap-key-unknown"
        if opts.app:
            self.app = TraceApp(opts.app, self.out, opts)
            with stages.run("launch", fatal=True):
                self.app.bench.launch()
            self.install_signals()
            self.rpc = self.app.rpc
            meta.update(app_pid=self.app.bench.process.pid, tag=self.app.bench.tag,
                        launched_env=self.app.bench.launched_env)
            if opts.scenario == "stress-storm":
                with stages.run("stress-build", fatal=True):
                    self.build_stress()
            else:
                with stages.run("light-build", fatal=True):
                    self.build_light()
            with stages.run("storm-setup"):
                self.groups, self.workspaces = storm_setup(self.app, self.rpc)
                meta["storm_targets"] = {"workspaces": len(self.workspaces), "groups": len(self.groups)}
                meta["cef"] = cef_validity(self.rpc("debug.cef", timeout=RPC_S), stress_lib.WEB_DEV_CONFIG)
                meta["window_state"] = window_state(self.rpc)
            key = (meta.get("window_state") or {}).get("window_key")
            meta["scenario_label"] = scenario_label(opts.scenario, [meta.get("window_state") or {}])
            if opts.storm_hz > 0 and not self.workspaces:
                self.warn("the CLI storm has no target workspace (only the shown one exists): storm_ops will be empty")
            if meta.get("cef") and not meta["cef"]["valid"]:
                self.warn(f"Chromium is not valid for a measurement: {'; '.join(meta['cef']['problems'])}")
            if key is not True:
                self.warn(f"the app's window was not key (window_key {key}): rows are labelled {meta['scenario_label']}")
        if opts.socket and not self.rpc:
            self.rpc = stress_lib.socket_rpc(opts.socket)
        with stages.run("recorders-start", fatal=True):
            self.start_recorders()
        meta["window_start_us"] = uptime_us()
        note(f"window starts: scenario {meta['scenario']} " +
             (f"(at most {opts.seconds_cap:g} s)" if opts.command else f"for {opts.seconds:g} s"))
        meta["load_at_start"] = [round(x, 1) for x in os.getloadavg()]  # a loaded host stretches every number
        self.frames_started = self.rpc and self.rpc("debug.frames", {"action": "start"}, timeout=RPC_S)
        self.probe_before = len(read_probe(self.app.probe)) if self.app else 0
        bound = (opts.seconds_cap if opts.command else opts.seconds) + STAGE_BOUNDS_S["window-margin"]
        with stages.run("window", bound, on_abort=self.end_window):
            self.run_window()

    def launch_window(self):
        """launch-warm and launch-cold (the module doc): the priming launch, the cold preparation, the recorders, then
        the measured launch, recorded from before its spawn to `startup_complete` + LAUNCH_SETTLE_S."""
        opts, meta, stages = self.opts, self.meta, self.stages
        cold = opts.scenario == "launch-cold"
        meta["launch"] = {"temperature": "cold" if cold else "warm"}
        self.app = TraceApp(opts.app, self.out, opts)
        with stages.run("prime", fatal=True):
            self.prime_launch()
        if cold:
            with stages.run("cold-prep", fatal=True):
                meta["launch"].update(self.make_cold())
        with stages.run("recorders-start", fatal=True):
            self.start_recorders()
        complete = self.signposts.watch_mark(STARTUP_COMPLETE_MARK)
        first_frame = self.signposts.watch_mark(FIRST_FRAME_MARK)
        bench = self.app.bench
        bench.fresh_state = False  # the measured launch restores the session the priming launch saved
        bench.extra_env.update(self.app.startup_env(opts.seconds + LAUNCH_SETTLE_S))
        meta["window_start_us"] = uptime_us()
        meta["load_at_start"] = [round(x, 1) for x in os.getloadavg()]
        note(f"window starts: scenario {opts.scenario}, until {STARTUP_COMPLETE_MARK} + {LAUNCH_SETTLE_S:g} s "
             f"(at most {opts.seconds:g} s)")

        def window(process):
            """BenchApp.launch's `on_start`: the window runs here, before its first socket poll, so no socket call
            reaches the launching app's main thread until the launch is over."""
            meta["app_pid"] = process.pid
            meta["launch"]["spawned_us"] = uptime_us()
            self.signposts.watch_pid(process.pid)  # only this launch's marks end its window
            if self.recorder == "sample":
                self.sampler = self.sampler or Sampler(self.out)
                self.sampler.start([(process.pid, "app")], opts.seconds + LAUNCH_SETTLE_S, hold=stages.hold)
            # The app's exit ends the wait too (a launch that crashed has no startup_complete).
            threading.Thread(target=lambda: (process.wait(), complete.set()), name="launch-exit", daemon=True).start()
            reached = complete.wait(opts.seconds)
            meta["launch"].update(startup_complete=reached and process.poll() is None, first_frame=first_frame.is_set())
            if process.poll() is not None:
                return  # BenchApp.launch reports the exit or crash
            if not reached:
                self.warn(f"no {STARTUP_COMPLETE_MARK} launch mark within {opts.seconds:g} s: the window ends at "
                          f"--seconds" + ("" if first_frame.is_set() else f" (no {FIRST_FRAME_MARK} either)"))
            time.sleep(LAUNCH_SETTLE_S)  # the work the launch left for after startup_complete shows in the window
            meta["window_end_us"] = uptime_us()
            note("window ends")

        with stages.run("launch", bound=STAGE_BOUNDS_S["launch"] + opts.seconds + LAUNCH_SETTLE_S, fatal=True):
            bench.launch(on_start=window)
        self.install_signals()
        self.rpc = self.app.rpc
        meta.update(tag=bench.tag, launched_env=bench.launched_env)
        # One drain at the stop (`stop-hangs`), after the launch: the ring holds the launch's last 128 turns over the
        # threshold, and the records it dropped before them count as dropped.
        self.hangs = HangDrain(self.rpc, os.path.join(self.out, "hangs.json"), from_start=True)
        with stages.run("window-state"):
            meta["window_state"] = window_state(self.rpc)
        meta["scenario_label"] = scenario_label(opts.scenario, [meta.get("window_state") or {}])

    def prime_launch(self):
        """The priming launch: a fresh session the measured launch restores. Its app quits keeping its sessions
        (`fixture_quit: keep`), so the tag's daemon and terminal hosts run on, as after a person's quit."""
        bench = self.app.bench
        bench.launch()
        self.install_signals()
        process = bench.process
        self.meta["launch"]["prime_pid"] = process.pid
        rpc_at_quit = bench.rpc("debug.quit", {"fixture_quit": "keep"}, timeout=RPC_SHORT_S)
        try:
            process.wait(30)
        except subprocess.TimeoutExpired:
            self.warn(f"the priming app did not quit in 30 s ({json.dumps(rpc_at_quit)[:200]}): SIGTERM")
            process.terminate()  # the PID this run started
            process.wait(15)
        self.meta["launch"]["prime_ready_s"] = bench.ready_seconds

    def make_cold(self):
        """A reboot's state for the measured launch: every process of the bundle this run started (the priming
        launch's daemon, terminal hosts, holder, agents) ends by its exact PID, then `sudo -n purge` empties the
        file cache. A purge that needs a password refuses the run: a warm launch must never carry the cold label."""
        from tag_teardown import TagTeardown
        running = TagTeardown(self.bundle).processes()
        pids = {pid for pid, _ in running}
        for pid in pids:
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, signal.SIGTERM)  # an exact PID of this bundle; the preflight proved this run started it
        killed = wait_exits(pids, 15)
        for pid in killed:
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, signal.SIGKILL)
        left = wait_exits(killed, 5)
        if left:
            raise LaunchError("cold-not-stopped", {"detail": f"process(es) {sorted(left)} of {self.bundle} did not exit "
                                                             "after SIGKILL", "log_tail": ""})
        done = subprocess.run(["sudo", "-n", "purge"], capture_output=True, text=True, timeout=PURGE_S,
                              stdin=subprocess.DEVNULL)
        if done.returncode != 0:
            raise LaunchError("purge-refused", {"detail": f"`sudo -n purge` exited {done.returncode}: "
                                                          f"{(done.stdout + done.stderr).strip()[:300]}; a cold launch "
                                                          "needs a passwordless purge (a fleet measure host)",
                                                "log_tail": ""})
        return {"stopped": len(pids), "killed": len(killed), "purged": True}

    def build_stress(self):
        """STRESS through perf-stress-session.py; a session that misses the shape is traced and says so. The
        builder stays alive through the window: it serves the pages."""
        started = time.monotonic()
        self.stress = stress_lib.Stress(self.rpc, log=note)
        self.meta["stress"] = self.stress.build(check=False)
        try:
            stress_lib.Stress.check(self.meta["stress"])
        except stress_lib.StressShapeError as error:
            # A trace of a session that is not quite STRESS still answers "why did this lag"; it says so.
            self.meta["stress"]["shape_error"] = str(error)[:600]
            self.warn(f"NOT the STRESS shape: {error}")
        note(f"STRESS built in {time.monotonic() - started:.0f} s: {json.dumps(self.meta['stress'])}")
        self.focus_quiet_terminal()

    def focus_quiet_terminal(self):
        """Focuses a pane of the measured workspace whose selected tab is a terminal that is not one of the busy
        ones, so the keys go to a terminal whose only output is their echo. A key-press flow takes the first
        output on its terminal after the PTY write as the echo: on a busy terminal that would be the busy loop's
        line (plans/cmux-next/trace.md, "Key-press flows").

        This moves typing off the pane STRESS focuses (its first, busy one) in every record run: the summary
        names both panes (`typed_pane`). A failure to find or focus the pane is a warning, never the build's
        end: the trace is still taken, on the busy pane."""
        stress = self.stress
        typed = {"before": None, "after": None, "quiet": False}
        self.meta["typed_pane"] = typed
        try:
            typed["before"] = (stress.topology().get("focus") or {}).get("pane")
            busy = set(getattr(stress, "busy", []) or [])
            panes = stress.panes(stress.workspace(getattr(stress, "measured", None)))
            quiet = next((pane for pane in reversed(panes)
                          if any(t.get("kind") == "terminal" and t.get("selected") and t.get("id") not in busy
                                 for t in pane.get("tabs") or [])), None)
            if quiet is None:
                self.warn("no quiet terminal in the measured workspace: key-press flows type into a busy terminal")
                return
            stress.focus_pane(quiet["id"])
            typed["after"] = (stress.topology().get("focus") or {}).get("pane")
            typed["quiet"] = typed["after"] == quiet["id"]
            if not typed["quiet"]:
                self.warn(f"focus did not move to the quiet pane {quiet['id']} (focused: {typed['after']}): key-press "
                          "flows type into a busy terminal")
        except Exception as error:  # a warning: the trace is still taken (StageTimeout is a BaseException)
            self.warn(f"could not focus a quiet terminal: {type(error).__name__}: {str(error)[:200]}")

    def build_light(self):
        """The light session: the window placed at the STRESS size, LIGHT_BACKGROUND workspaces (targets of the
        storm), then build_light's shown workspace split once with Chromium, WebKit, chat and terminal tabs."""
        started = time.monotonic()
        self.stress = stress_lib.Stress(self.rpc, log=note)
        reply, problem = stress_lib.place_window(self.rpc)
        self.meta["window"] = stress_lib.window_on_screen(reply) if isinstance(reply, dict) else {"window_problem": problem}
        if problem:
            self.warn(f"window placement: {problem}")
        background = self.stress.build_background(count=LIGHT_BACKGROUND, chromium=0)
        workspace, panes = self.stress.build_light()
        self.meta["light"] = {"workspace": workspace, "panes": len(panes), "background": len(background),
                              "refusals": self.stress.refusals[:6], "build_s": round(time.monotonic() - started, 1)}
        note(f"light session built: {json.dumps(self.meta['light'])}")

    def start_recorders(self):
        opts, meta, hold = self.opts, self.meta, self.stages.hold
        note("recorders starting")
        self.processes["start"] = ps_snapshot(self.bundle)
        self.signposts = SignpostStream(os.path.join(self.out, "signposts.ndjson"))
        self.signposts.start(hold=hold)
        if self.recorder == "xctrace":
            self.start_xctrace()
        if self.app and not opts.release:
            self.spans = FileFollower(self.app.spans, os.path.join(self.out, "daemon-spans-stamped.jsonl"))
            self.spans.start(hold=hold)
        if self.rpc:
            self.rpc("debug.hangs", {"clear": True}, timeout=RPC_SHORT_S)
            self.hangs = HangDrain(self.rpc, os.path.join(self.out, "hangs.json"))
            self.hangs.start()
        if self.app and self.app.cdp_port:
            self.chromium = ChromiumTracer(self.app.cdp_port, self.out)
            try:
                self.chromium.start()
            except (RuntimeError, OSError, ConnectionError) as error:
                note(f"no Chromium trace: {error}")
                meta["sources"]["chromium_error"] = str(error)[:300]
                self.chromium.close()
                self.chromium = None
        if self.recorder == "sample":
            self.sampler = Sampler(self.out)
            pids = [(pid, info["role"]) for pid, info in self.processes["start"].items() if info["role"] in ("app", "daemon")]
            self.sampler.start(pids, opts.seconds, hold=hold)
        if opts.release:  # last: the window below starts once the CLI says its own window runs
            self.release = ReleaseTrace(self.app.bench.cli, self.app.bench.socket, self.out,
                                        opts.seconds + RELEASE_WINDOW_SETTLE_S, chromium=not opts.no_cef,
                                        env=self.app.cli_env())
            meta["release_trace"] = {"command": self.release.command()}
            if not self.release.start(hold=hold):
                self.warn(f"`cmux trace record` did not say it records within {RELEASE_START_S} s, or ended: the "
                          f"window may have no rings (its log: {RELEASE_LOG})")

    def start_xctrace(self):
        """The all-process recording, or the app process only when xctrace refuses --all-processes. Each XcTrace
        is held on `self.xc` before its process starts, so the stop path always reaches it."""
        opts = self.opts
        cap = (opts.seconds_cap if opts.command else opts.seconds) + STAGE_BOUNDS_S["window-margin"]
        self.xc = self.xctrace_factory(self.out, system_trace=opts.system_trace, cap_s=cap)
        try:
            self.xc.start(hold=self.stages.hold)
        except RuntimeError as error:
            if not self.meta.get("app_pid"):
                raise
            note(f"{error}; recording the app process only")
            self.xc = self.xctrace_factory(self.out, system_trace=opts.system_trace, cap_s=cap)
            self.xc.attach = self.meta["app_pid"]
            self.xc.start(hold=self.stages.hold)
        note(f"xctrace recording ({' '.join(self.xc.command()[3:7])})")
        self.meta["xctrace"] = {"command": self.xc.command(), "started_us": self.xc.started_us,
                                "started_wall": self.xc.started_wall}

    def run_window(self):
        """The measured window: the wrapped command, or the storm and the typist for --seconds."""
        opts, meta = self.opts, self.meta
        if opts.command:
            note(f"wrap: running {' '.join(opts.command)[:200]}")
            self.wrapped = WrappedCommand(opts.command)
            self.wrapped.start(hold=self.stages.hold)
            meta["command_exit"] = self.wrapped.wait()
            return
        if opts.storm_hz > 0:
            self.storm = Storm(self.app.cli_run, self.workspaces, self.groups, opts.storm_hz, self.driver_events)
        self.typist = Typist(self.rpc, opts.key_interval, opts.chord_every, self.driver_events)
        time.sleep(1.0)  # the recorders' first second is their own start-up cost; the scenario starts after it
        self.phase = {"kind": "phase", "name": f"scenario {opts.scenario}", "start_us": uptime_us(), "end_us": None,
                      "args": {}}
        self.driver_events.append(self.phase)
        if self.storm:
            self.storm.start()
        self.typist.start()
        time.sleep(opts.seconds)  # the measured window itself
        self.stop_driver()
        time.sleep(1.0)  # the last action's frames and replies land inside the window

    def kill_wrapped(self):
        """The wrap-stop stage passed its bound or failed: SIGKILL the command's group (bounded) and say so."""
        self.wrapped.kill()
        self.meta["wrapped"] = {"exit": self.wrapped.exit, "signalled": True,
                                "killed": "the whole group (SIGKILL: wrap-stop passed its bound or failed)"}

    def stop_driver(self):
        """Ends the storm and the typist and records what they did. Both stop flags are set before either join,
        so a bound that fires during one join never leaves the other running; it runs again from `stop()`."""
        threads = [t for t in (self.typist, self.storm) if t]
        for thread in threads:
            thread.stop_flag.set()
        for thread in threads:
            if thread.is_alive():
                thread.join(timeout=30)
        if self.phase and self.phase["end_us"] is None:
            self.phase["end_us"] = uptime_us()
        if self.typist:
            self.meta.update(keys=self.typist.keys, chords=dict(self.typist.chords))
            self.meta["storm_ops"] = dict(self.storm.ops) if self.storm else {}

    def end_window(self):
        """The window stage passed its bound or failed: end what it drives (bounded by construction)."""
        for thread in (self.typist, self.storm):
            if thread:
                thread.stop_flag.set()
        if self.wrapped:
            stopped = self.wrapped.stop()
            if stopped:
                self.meta["wrapped"] = stopped

    # The stop.

    def stop(self):
        """Stops every source, each under its own stage and bound, so one hung or failing source never keeps
        the others running; a source whose stop passes its bound or raises is killed (`kill`)."""
        stages, meta = self.stages, self.meta
        if self.wrapped:
            with stages.run("wrap-stop", on_abort=self.kill_wrapped):
                stopped = self.wrapped.stop()
                if stopped:
                    meta["wrapped"] = stopped
        if self.typist or self.storm:
            with stages.run("driver-stop"):
                self.stop_driver()
        if self.xc:
            # The recording ends with the window: every other source stops after it (the Chromium trace's transfer
            # takes minutes), and an all-process recording that ran through those minutes would take as long again
            # to save and export.
            with stages.run("xctrace-end", bound=RPC_SHORT_S):
                self.xc.interrupt()
        if self.release:
            release = self.release
            bound = STAGE_BOUNDS_S["release-trace-stop"] + release.remaining_s() + RPC_SHORT_S  # + the log's reader
            with stages.run("release-trace-stop", bound=bound, on_abort=release.kill):
                note("cmux trace record: waiting for its window and the ring copies")
                done = meta["sources"]["release_trace"] = release.stop()
                if done and done["exit"] != 0:
                    self.warn(f"`cmux trace record` exited {done['exit']}: {done['log_tail'][-300:]}")
        if self.app and self.rpc and meta.get("window_start_us"):
            # Key at the start says nothing about the window: another GUI job or a dialog can take key status
            # during it. A second read at its end; the label holds when both reads say key.
            with stages.run("window-state"):
                meta["window_state_end"] = window_state(self.rpc)
            label = scenario_label(self.opts.scenario, [meta.get("window_state") or {}, meta.get("window_state_end") or {}])
            if label != meta.get("scenario_label"):
                self.warn(f"the app's window was key {(meta.get('window_state') or {}).get('window_key')} at the "
                          f"window's start and {(meta.get('window_state_end') or {}).get('window_key')} at its end: "
                          f"rows are labelled {label}")
                meta["scenario_label"] = label
        if self.rpc and self.frames_started is not None:
            with stages.run("teardown-rpc"):
                meta["frames"] = self.rpc("debug.frames", {"action": "stop"}, timeout=RPC_S)
        if self.chromium:
            chromium = self.chromium
            with stages.run("chromium-stop", on_abort=chromium.close):
                note("chromium trace stopping")
                meta["sources"]["chromium"] = chromium.stop()
                note(f"chromium trace saved: {os.path.getsize(chromium.path) / 1e6:.0f} MB" if os.path.exists(chromium.path)
                     else "chromium trace: nothing saved")
        if self.app and self.rpc and meta.get("launch") and meta.get("window_start_us"):
            with stages.run("startup-trace"):
                self.dump_startup_trace()
        for name, source in (("hangs", self.hangs), ("spans", self.spans), ("sampler", self.sampler),
                             ("signposts", self.signposts)):
            if source:
                with stages.run(f"stop-{name}", on_abort=source.kill):
                    source.stop()
        if self.xc:
            with stages.run("xctrace-save", on_abort=self.xc.kill):
                note("xctrace stopping (it processes the recording before it saves)")
                started = time.monotonic()
                meta["sources"]["xctrace_saved"] = self.xc.stop()
                note(f"xctrace saved in {time.monotonic() - started:.0f} s")
        with stages.run("raw-files"):
            self.processes["end"] = ps_snapshot(self.bundle)
            write_json(os.path.join(self.out, "processes.json"), self.processes)
            write_json(os.path.join(self.out, "driver.json"), self.driver_events)
        if self.app and self.rpc and meta.get("window_start_us"):
            rows = read_probe(self.app.probe)[self.probe_before:]
            complete = [r for r in rows if r.get("complete") == "1" and r.get("contents_ms")]
            meta["key_to_frame_ms"] = pct([float(r["contents_ms"]) for r in complete])
            with stages.run("teardown-rpc"):
                meta["timings"] = self.rpc("debug.timings", timeout=RPC_S)

    def dump_startup_trace(self):
        """Closes the measured launch's StartupTrace file before the app quits: its deadline (--seconds + the settle)
        comes long after the window, and the file holds only whole 64 KiB chunks until then. `debug.startup_trace`
        (p08-startup 004) writes the rest and closes it; the window is over, so the call touches no launch turn."""
        path = os.path.join(self.app.startup_dir, STARTUP_APP_FILE)
        reply = self.rpc("debug.startup_trace", timeout=RPC_S)
        self.meta["sources"]["startup_trace"] = reply
        if not isinstance(reply, dict) or reply.get("error"):
            self.warn(f"debug.startup_trace failed ({json.dumps(reply)[:200]}): {STARTUP_APP_FILE} keeps only the "
                      "chunks the app flushed")
            return
        deadline = time.monotonic() + STARTUP_TRACE_CLOSE_S
        while read_trace_file(path)[1] and time.monotonic() < deadline:  # the dump may finish off its reply's turn
            time.sleep(0.1)
        if read_trace_file(path)[1]:
            self.warn(f"{STARTUP_APP_FILE} is not closed {STARTUP_TRACE_CLOSE_S:g} s after debug.startup_trace")

    def stop_app(self):
        """Quits the app this run launched (unless --keep), or after a wrapped command that had to be stopped,
        runs the bundle's tag teardown (its own teardown may not have finished). Then the pages' server."""
        stages = self.stages
        launched = self.app and self.app.bench.process is not None
        if launched and not self.opts.keep:
            with stages.run("app-stop", on_abort=self.kill_bundle):
                self.app.bench.stop()
        elif self.wrapped and self.wrapped.signalled and self.bundle:
            from tag_teardown import TagTeardown
            with stages.run("app-stop", on_abort=self.kill_bundle):
                TagTeardown(self.bundle, log=note).end()
        if self.stress:
            self.stress.close()

    def kill_bundle(self):
        """The app's stop passed its bound or failed: SIGKILL the app this run launched and every process of the
        bundle still running (the tag's daemons and Chromium helpers), each by its exact PID, never a pattern.
        Bounded: one `ps` and the kills."""
        from tag_teardown import TagTeardown
        process = self.app.bench.process if self.app else None
        if process and process.poll() is None:
            process.kill()
            process.wait()
        left = TagTeardown(self.bundle).processes()
        for pid, _ in left:
            try:
                os.kill(pid, signal.SIGKILL)  # an exact PID inside the bundle this run started
            except ProcessLookupError:
                pass
        self.meta["killed_after_app_stop"] = len(left)

    # After the stop.

    def finish(self):
        """Exports the recording and builds the trace and the summary; SUMMARY.txt is always written."""
        stages = self.stages
        if self.recorder == "xctrace":
            exported = False
            with stages.run("export"):
                export_xctrace(self.out, xctrace=self.xctrace_tool)
                exported = True  # not reached when the stage passed its bound or failed
            missing = missing_tables(self.out)
            recording = os.path.join(self.out, "recording.trace")
            if exported and not missing:
                if not self.opts.keep_recording:
                    shutil.rmtree(recording, ignore_errors=True)  # GBs; every table it holds is exported
            elif os.path.exists(recording):
                # The only source of the missing tables: `trace.py export DIR` exports them again from it.
                self.warn(f"the export is incomplete ({', '.join(missing) or 'the export stage did not finish'}): "
                          f"recording.trace is kept for `trace.py export {self.out}`")
        write_json(os.path.join(self.out, "meta.json"), self.meta)
        summary = None
        with stages.run("build"):
            summary = build(self.out)
        return self.write_summary(summary)

    def write_summary(self, summary):
        """summary.json and SUMMARY.txt from the build's summary, or from meta alone when the build did not
        finish; the stage rows, errors and warnings are the run's final ones (the build read meta before)."""
        meta = self.meta
        if summary is None:
            summary = {k: meta.get(k) for k in ("host", "macos", "tag", "scenario", "scenario_label", "stress", "light",
                                                 "window", "window_state", "window_state_end", "cef", "launched_env")}
            summary["no_trace"] = "the build did not finish" if self.terminated is None else "ended by a signal"
        summary.update(stages=meta["stages"], timed_out=meta["timed_out"], errors=meta["errors"],
                       warnings=meta.get("warnings") or [], wrapped=meta.get("wrapped"),
                       command_exit=meta.get("command_exit"), terminated=self.terminated)
        summary["exit_code"] = self.exit_code()
        write_json(os.path.join(self.out, "summary.json"), summary)
        text = summary_text(summary)
        with open(os.path.join(self.out, "SUMMARY.txt"), "w") as f:
            f.write(text + "\n")
        print(text, flush=True)
        return summary

    def exit_code(self):
        """128 + N when signal N ended the run (also during the export or the build); else 3 when a stage passed
        its bound or failed; else wrap mode's own nonzero exit (128 + N for a signal N); else 0."""
        if self.terminated is not None:
            return self.terminated
        if self.meta["timed_out"] or self.meta["errors"]:
            return 3
        code = self.meta.get("command_exit")
        if code:
            return 128 - code if code < 0 else code
        return 0


# ---------------------------------------------------------------- xctrace export and parse

def export_file(command, path, timeout, name, to_stdout=False):
    """Runs one `xctrace export` into `<path>.part.xml` and renames it to `path` only when xctrace exited 0, so
    `path` is always a complete export (a later `trace.py export DIR` reuses it). The part file is removed on
    every other end: a nonzero exit, the export's timeout, or a stage bound that fires inside the run (which
    kills the export, `subprocess.run`)."""
    part = path[:-len(".xml")] + ".part.xml"
    try:
        if to_stdout:
            with open(part, "w") as f:
                done = subprocess.run(command, stdout=f, stderr=subprocess.DEVNULL, timeout=timeout)
        else:
            done = subprocess.run([*command, "--output", part], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  timeout=timeout)
        if done.returncode == 0 and os.path.exists(part):
            os.replace(part, path)
            return True
        note(f"export of {name} exited {done.returncode}; the trace has no {name} table")
    except subprocess.TimeoutExpired:
        note(f"export of {name} took over {timeout} s; the trace has no {name} table")
    finally:
        if os.path.exists(part):
            os.unlink(part)
    return False


def export_xctrace(out, xctrace=("xcrun", "xctrace")):
    """Exports the recording's tables to XML files beside it (once; `export` reuses complete ones)."""
    trace = os.path.join(out, "recording.trace")
    if not os.path.exists(trace):
        return {}
    toc_path = os.path.join(out, "xctrace-toc.xml")
    export_file([*xctrace, "export", "--input", trace, "--toc"], toc_path, EXPORT_TOC_S, "toc", to_stdout=True)
    toc = parse_toc(toc_path)
    exported = {}
    for schema in toc["schemas"]:
        if schema not in EXPORT_SCHEMAS:
            continue
        path = os.path.join(out, f"xctrace-{schema}.xml")
        if not os.path.exists(path):
            export_file([*xctrace, "export", "--input", trace, "--xpath",
                         f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'], path, EXPORT_TIMEOUT_S, schema)
        if os.path.exists(path):
            exported[schema] = path
            note(f"exported {schema}: {os.path.getsize(path) / 1e6:.0f} MB")
    return exported


def missing_tables(out):
    """The tables trace.py reads that the recording holds but `out` has no complete export of (["toc"] without
    a readable table of contents). Empty when every one is exported."""
    toc_path = os.path.join(out, "xctrace-toc.xml")
    if not os.path.exists(toc_path):
        return ["toc"]
    toc = parse_toc(toc_path)
    if not toc["schemas"]:
        return ["toc"]
    return [schema for schema in toc["schemas"] if schema in EXPORT_SCHEMAS
            and not os.path.exists(os.path.join(out, f"xctrace-{schema}.xml"))]


def parse_toc(path):
    toc = {"schemas": [], "start_date": None, "duration_s": None}
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        return toc
    for table in root.iter("table"):
        if table.get("schema") and table.get("schema") not in toc["schemas"]:
            toc["schemas"].append(table.get("schema"))
    start = root.find(".//summary/start-date")
    toc["start_date"] = start.text if start is not None else None
    duration = root.find(".//summary/duration")
    try:
        toc["duration_s"] = float(duration.text) if duration is not None else None
    except (TypeError, ValueError):
        pass
    return toc


# A thread's `fmt`: `Main Thread 0x1a (cmux DEV, pid: 42)` (xctrace 26.0) or `Main Thread (0x10f45bf)
# (fixture-emitter, pid: 70219)` (Xcode 26.6, tests/trace-fixtures/xcode-26): the name, the id, then the process.
THREAD_FMT = re.compile(r"^(.*?)\s+\(?0x[0-9a-fA-F]+\)?\s*\((.*?)(?:,\s*pid:\s*(\d+))?\)\s*$")


def parse_value(elem, vals):
    tag = elem.tag
    if tag == "frame":
        return elem.get("name") or elem.get("addr") or "?"
    if tag == "backtrace":
        return tuple(vals.get(id(child)) or "?" for child in elem if child.tag == "frame")
    if tag in ("tagged-backtrace", "kperf-bt"):
        return next((vals.get(id(child)) for child in elem if child.tag == "backtrace"), ())
    if tag in ("tid", "pid"):
        try:
            return int(elem.text)
        except (TypeError, ValueError):
            return None
    if tag == "process":
        pid = next((vals.get(id(child)) for child in elem if child.tag == "pid"), None)
        name = re.sub(r"\s*\(\d+\)\s*$", "", elem.get("fmt") or "")
        return {"pid": pid, "name": name}
    if tag == "thread":
        tid = next((vals.get(id(child)) for child in elem if child.tag == "tid"), None)
        process = next((vals.get(id(child)) for child in elem if child.tag == "process"), None) or {}
        match = THREAD_FMT.match(elem.get("fmt") or "")
        name = match.group(1).strip() if match else (elem.get("fmt") or "")
        pid = process.get("pid")
        if pid is None and match and match.group(3):
            pid = int(match.group(3))
        return {"tid": tid, "name": name, "pid": pid, "process": process.get("name") or (match.group(2) if match else "")}
    text = elem.text
    value = text
    if text is not None:
        try:
            value = int(text)
        except ValueError:
            pass
    return (value, elem.get("fmt"))


def xctrace_rows(path):
    """The rows of one exported table, each {column: value}, with `ref` attributes resolved. Streams: a table
    of a million samples never sits in memory as XML.

    A row's cells are its children in the order of the node's `<schema><col>` list (an empty cell is a
    `<sentinel/>`), so each cell is keyed by its column's `<mnemonic>`. The element tag is the column's
    engineering type, which two columns can share (several `string` columns, say): it is kept only as a second
    key for a type no mnemonic already names, so a reader can still find a column by type."""
    ids, vals, node, columns = {}, {}, None, []
    for event, elem in ET.iterparse(path, events=("start", "end")):
        if event == "start":
            if elem.tag == "node":
                node, columns = elem, []
                ids.clear()  # each exported table numbers its ids from 1
            continue
        if elem.tag == "schema":
            columns = [(col.findtext("mnemonic") or "").strip() for col in elem.findall("col")]
            continue
        if elem.tag == "row":
            row = {}
            cells = list(elem)
            for index, child in enumerate(cells):
                if index < len(columns) and columns[index]:
                    row[columns[index]] = None if child.tag == "sentinel" else vals.get(id(child))
            for child in cells:
                if child.tag != "sentinel":
                    row.setdefault(child.tag, vals.get(id(child)))
            yield row
            vals.clear()
            if node is not None:
                node.clear()
            continue
        ref = elem.get("ref")
        if ref is not None:
            value = ids.get(ref)
        else:
            value = parse_value(elem, vals)
            if elem.get("id") is not None:
                ids[elem.get("id")] = value
        vals[id(elem)] = value


def scalar(value):
    return value[0] if isinstance(value, tuple) else value


def time_profile_samples(path):
    """[(t_ns since the recording's start, weight_ns, thread dict, frames leaf first)]."""
    samples = []
    for row in xctrace_rows(path):
        thread = row.get("thread")
        if not isinstance(thread, dict):
            continue
        t = scalar(row.get("time") if row.get("time") is not None else row.get("sample-time"))
        weight = scalar(row.get("weight")) or 1_000_000
        stack = row.get("stack") or row.get("backtrace") or row.get("tagged-backtrace") or row.get("kperf-bt") or ()
        if not isinstance(t, int):
            continue
        samples.append((t, weight if isinstance(weight, int) else 1_000_000, thread, stack if isinstance(stack, tuple) else ()))
    return samples


def text(value):
    """A string column's value: the element's text, else its `fmt` (an export may carry a string either way)."""
    if isinstance(value, tuple):
        return value[0] if value[0] not in (None, "") else value[1]
    return value


def xctrace_signposts(path, stats=None):
    """[(t_ns, name, event type, identifier)] of the cmux subsystem from the os-signpost table, for the clock.
    `stats` (a dict) gets the rows read, the cmux rows and the column tags seen, so a table whose columns are
    not the ones read here is named in the summary instead of silently matching nothing."""
    found, rows, columns = [], 0, set()
    for row in xctrace_rows(path):
        rows += 1
        if len(columns) < 64:
            columns.update(row)
        subsystem = text(row.get("subsystem"))
        if subsystem != SUBSYSTEM:
            continue
        t = scalar(row.get("time") or row.get("event-time") or row.get("start") or row.get("start-time"))
        name = text(row.get("name") or row.get("signpost-name"))
        kind = text(row.get("event-type"))
        identifier = scalar(row.get("identifier") or row.get("signpost-identifier") or row.get("os-signpost-identifier"))
        if isinstance(t, int) and name:
            found.append((t, str(name), str(kind or ""), identifier))
    if stats is not None:
        stats.update(rows=rows, cmux_rows=len(found), columns=sorted(columns))
    return found


def syscall_waits(path, min_ns=1_000_000):
    """[(start_ns, duration_ns, thread dict, syscall, backtrace leaf first)] of System Trace's syscall table: the
    calls of 1 ms or longer (a thread inside one is off CPU, and the stack says what it waits for)."""
    found = []
    for row in xctrace_rows(path):
        thread = row.get("thread")
        start = scalar(row.get("start") if row.get("start") is not None else row.get("start-time"))
        duration = scalar(row.get("duration"))
        if not (isinstance(thread, dict) and isinstance(start, int) and isinstance(duration, int)) or duration < min_ns:
            continue
        call = row.get("syscall")
        call = (call[1] or call[0]) if isinstance(call, tuple) else str(call or "")
        stack = row.get("stack") or row.get("backtrace") or row.get("tagged-backtrace") or ()
        found.append((start, duration, thread, str(call), stack if isinstance(stack, tuple) else ()))
    return found


def start_date_precision(date):
    """The precision of an ISO start date in words: its fractional seconds digits (none: a whole second)."""
    match = re.search(r"T\d\d:\d\d:\d\d(?:\.(\d+))?", date or "")
    digits = len(match.group(1)) if match and match.group(1) else 0
    return {0: "1 s", 1: "100 ms", 2: "10 ms", 3: "1 ms"}.get(digits, "under 1 ms")


def xctrace_offset_us(xc_signposts, toc, signposts, meta, stats=None):
    """(offset, how, warning): microseconds to add to an xctrace time (ns since its start / 1000) for
    CLOCK_UPTIME_RAW. From the same signposts in both recordings (begin events matched by name in order, at
    least 3, spread under 2 ms), else the recording's start date (as precise as the date's fractional digits),
    else the recorder's start. `warning` says why the signposts did not decide it when both recordings had
    some (`xc_signposts` is None when there is no os-signpost table; `stats` from `xctrace_signposts`)."""
    warning = None
    if xc_signposts is not None and signposts:
        xc = sorted((t, n, k) for t, n, k, _ in xc_signposts if k.lower().startswith("begin"))
        by_name = collections.defaultdict(list)
        for t, name, _ in xc:
            by_name[name].append(t / 1000.0)
        log = collections.defaultdict(list)
        for interval in signposts:
            log[interval["name"]].append(interval["start_us"])
        candidates, mismatched = [], []
        for name, xs in by_name.items():
            ls = sorted(log.get(name) or [])
            if len(ls) == len(xs):
                candidates += [l - x for l, x in zip(ls, xs)]
            else:
                mismatched.append(f"{name} {len(xs)} vs {len(ls)}")
        spread = None
        if len(candidates) >= 3:
            median = statistics.median(candidates)
            spread = max(abs(c - median) for c in candidates)
            if spread < 2000:
                return median, f"signposts ({len(candidates)} matched, spread {spread:.0f} us)", None
        stats = stats or {}
        warning = (f"the xctrace clock is not from the signposts: {len(xc)} cmux begin events in the os-signpost "
                   f"table ({stats.get('rows', '?')} rows; columns {stats.get('columns', '?')}) against "
                   f"{len(signposts)} log signposts; {len(candidates)} matched by name and count"
                   + (f", spread {spread:.0f} us (over 2000)" if spread is not None else "")
                   + (f"; counts differ: {', '.join(mismatched[:4])}" if mismatched else ""))
    started = (meta.get("xctrace") or {}).get("started_us")
    if toc.get("start_date") and started:
        from datetime import datetime
        try:
            start_wall = datetime.fromisoformat(toc["start_date"].replace("Z", "+00:00")).timestamp()
            wall = meta["xctrace"]["started_wall"]
            return (started - (wall - start_wall) * 1e6,
                    f"start date (about {start_date_precision(toc['start_date'])})", warning)
        except (ValueError, KeyError):
            pass
    if started:
        return started, "recorder start (about 100 ms)", warning
    return 0.0, "none", warning


# ---------------------------------------------------------------- building the trace

class Lanes:
    """Assigns intervals to tracks where they nest cleanly (Perfetto drops slices that overlap without nesting)."""

    def __init__(self):
        self.stacks = []

    def place(self, start, end):
        for index, stack in enumerate(self.stacks):
            while stack and stack[-1] <= start:
                stack.pop()
            if not stack or end <= stack[-1]:
                stack.append(end)
                return index
        self.stacks.append([end])
        return len(self.stacks) - 1


class SyntheticTracks:
    """Thread ids for the tracks that are not OS threads: one per (pid, key), handed out in order from
    SYNTHETIC_TID_BASE (so the same raw files give the same ids), under 2^31, and never an id that an OS or
    Chromium thread in the trace uses (`taken`)."""

    def __init__(self, taken):
        self.taken, self.ids, self.next = set(taken), {}, SYNTHETIC_TID_BASE

    def tid(self, pid, key):
        if (pid, key) not in self.ids:
            while self.next in self.taken:
                self.next += 1
            if self.next >= 1 << 31:
                raise ValueError("no synthetic track id left under 2^31")
            self.ids[(pid, key)] = self.next
            self.next += 1
        return self.ids[(pid, key)]


def find_app_pid(meta, known, roles, intervals):
    """(pid, how) of the app. The pid this run launched; in wrap mode (the command launched the app, after the
    start snapshot and gone before the end one) the process that emitted the most `action` signposts (only the
    app emits them); else the bundle's app executable in a ps snapshot; else a sampled process named as the app.
    Never a CLI process: the bundled CLI is also named `cmux` (role_from_name)."""
    if meta.get("app_pid"):
        return meta["app_pid"], "launched"
    emitters = collections.Counter(i["pid"] for i in intervals if i.get("category") == "action" and i.get("pid"))
    for pid, _ in emitters.most_common():
        # A name says little here (an app whose executable is `cmux` reads as the CLI); a ps snapshot's path does.
        if (known.get(pid) or {}).get("role") in (None, "app"):
            return pid, "action signposts"
    pid = next((p for p, info in sorted(known.items()) if info.get("role") == "app"), None)
    if pid is not None:
        return pid, "ps snapshot"
    pid = next((p for p, r in sorted(roles.items()) if r == "app"), None)
    return pid, "process name" if pid is not None else "none"


CLOCK_LINE = re.compile(r"^#continuous-minus-uptime-us(-end)? (-?[0-9.e+]+)$")


def read_signposts(path):
    """Signpost intervals and events on CLOCK_UPTIME_RAW (us) from a saved `log stream --signpost` file, plus
    `clock`: the file's mach_continuous_time minus CLOCK_UPTIME_RAW (SignpostStream's clock lines, taken off
    every machTimestamp) and a warning when the times could not be put on CLOCK_UPTIME_RAW (no clock line) or
    the host slept during the recording (the end line differs)."""
    numer = denom = 0
    timebase = signposts_lib.local_timebase()
    if timebase:
        numer, denom = timebase
    open_intervals, intervals, events, lost = {}, [], [], 0
    try:
        lines = open(path).read().splitlines()
    except OSError:
        return {"intervals": [], "events": [], "lost": 0, "unpaired": 0, "clock": {"offset_us": 0.0, "warning": None}}
    clock = {"offset_us": 0.0, "warning": None}
    start_offset = end_offset = None
    for raw in lines:
        match = CLOCK_LINE.match(raw.strip())
        if match and match.group(1) and end_offset is None:
            end_offset = float(match.group(2))
        elif match and not match.group(1) and start_offset is None:
            start_offset = float(match.group(2))
    if start_offset is None:
        clock["warning"] = ("signposts.ndjson has no clock line (a trace.py before the clock fix wrote it): its times "
                            "are mach_continuous_time, ahead of every other source by the host's sleep since boot")
    else:
        clock["offset_us"] = start_offset
        if end_offset is not None and abs(end_offset - start_offset) > 1000:
            clock["warning"] = (f"the host slept {(end_offset - start_offset) / 1e6:.1f} s during the recording: "
                                f"signposts after the sleep are that much late against the other sources")
    for raw in lines:
        line = raw.strip()
        header = signposts_lib.TIMEBASE_HEADER.match(line)
        if header:
            numer, denom = int(header.group(1)), int(header.group(2))
            continue
        event = None
        if line.startswith("{"):
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                event = None
        if signposts_lib.is_loss(line, event):
            lost += 1
            continue
        if event is None or event.get("eventType") != "signpostEvent" or event.get("subsystem") != SUBSYSTEM:
            continue
        mach = event.get("machTimestamp")
        if not (isinstance(mach, int) and denom):
            continue
        at = mach * numer / denom / 1000.0 - clock["offset_us"]
        key = (event.get("processID"), event.get("category"), event.get("signpostName"), event.get("signpostID"))
        kind = event.get("signpostType")
        message = event.get("eventMessage", "")
        if kind == "begin":
            open_intervals[key] = (at, message, event.get("threadID"))
        elif kind == "end" and key in open_intervals:
            start, begin_message, tid = open_intervals.pop(key)
            end_fields = signposts_lib.fields(message)
            intervals.append({"name": key[2], "category": key[1], "pid": key[0], "tid": tid, "start_us": start,
                              "end_us": at, "ms": (at - start) / 1000.0, "fields": signposts_lib.fields(begin_message),
                              "message": begin_message, "end_message": message,
                              "missed": end_fields.get("commit") == "missed", "nested_loop": end_fields.get("loop") == "nested"})
        elif kind == "event":
            events.append({"name": key[2], "category": key[1], "pid": key[0], "tid": event.get("threadID"), "at_us": at,
                           "message": message})
    return {"intervals": intervals, "events": events, "lost": lost, "unpaired": len(open_intervals), "clock": clock}


def flame_events(samples, offset_us, keep):
    """Nested 'X' slices per thread from sampled stacks: consecutive samples share their common root frames;
    a thread not sampled for more than 1.5 sample periods was off CPU, which closes every frame."""
    by_thread = collections.defaultdict(list)
    for t, weight, thread, frames in samples:
        if keep(thread):
            by_thread[(thread["pid"], thread["tid"])].append((t / 1000.0 + offset_us, weight / 1000.0, frames))
    events = []
    for (pid, tid), rows in by_thread.items():
        rows.sort(key=lambda r: r[0])
        stack = []  # [(name, start)]
        last_end = None

        def close(depth, at):
            while len(stack) > depth:
                name, start = stack.pop()
                if at > start:
                    # The end is rounded once, not the duration: a frame and its callers that close at one
                    # time end at the same rounded time, so no callee ends past its caller.
                    begin = round(start, 3)
                    events.append({"ph": "X", "pid": pid, "tid": tid, "ts": begin, "dur": round(round(at, 3) - begin, 3),
                                   "name": name[:240], "cat": "cpu"})

        for at, weight, frames in rows:
            root_first = list(reversed(frames))[:FLAME_DEPTH]
            if last_end is not None and at - last_end > 1.5 * weight:
                close(0, last_end)
            common = 0
            while common < len(stack) and common < len(root_first) and stack[common][0] == root_first[common]:
                common += 1
            close(common, at)
            for name in root_first[common:]:
                stack.append((name, at))
            last_end = at + weight
        if last_end is not None:
            close(0, last_end)
    # A callee closes (and is listed) before its caller, and both can start at one time: callers first, so an
    # importer that keeps the file's order for equal times nests them (Perfetto's did not: every such pair was
    # a slice_spill_overlapping_complete_event).
    events.sort(key=lambda e: (e["pid"], e["tid"], e["ts"], -e["dur"]))
    return events


def chromium_events(out, threads_by_pid):
    """Chromium's trace events moved onto the trace clock, with thread ids mapped to the OS threads of the
    time profile by name (Chromium's ids on macOS are Mach port names, not system thread ids). A `record --release`
    run has no DevTools trace: `cmux trace record --chromium` writes Chromium's JSON into OUT/rings."""
    path = os.path.join(out, "chromium-trace.json")
    release = os.path.join(out, RELEASE_DIR, RELEASE_CHROMIUM_FILE)
    data = read_json(path if os.path.exists(path) else release)
    if data is None:
        return [], {"events": 0}
    events = data.get("traceEvents") if isinstance(data, dict) else data
    events = events or []
    clock = read_json(os.path.join(out, "chromium-clock.json"), {}) or {}
    offset = 0.0
    sync = next((e for e in events if e.get("name") == "clock_sync" and (e.get("args") or {}).get("sync_id") == clock.get("sync_id")), None)
    if sync and clock.get("before_us"):
        mid = (clock["before_us"] + clock["after_us"]) / 2
        half = (clock["after_us"] - clock["before_us"]) / 2
        raw = mid - float(sync["ts"])
        offset = 0.0 if abs(raw) <= half + 1000 else raw  # the same clock (TimeTicks is mach time) unless it is not
        clock["offset_us"], clock["raw_offset_us"] = offset, raw
    names = {}
    for e in events:
        if e.get("ph") == "M" and e.get("name") == "thread_name":
            names[(e.get("pid"), e.get("tid"))] = (e.get("args") or {}).get("name")
    main_names = {"CrBrowserMain", "CrGpuMain", "CrRendererMain", "CrUtilityMain"}
    mapping = {}
    for (pid, tid), name in names.items():
        threads = threads_by_pid.get(pid) or {}
        same = [t for t, n in threads.items() if n == name]
        if len(same) == 1:
            mapping[(pid, tid)] = same[0]
        elif name in main_names:
            main = [t for t, n in threads.items() if n.startswith("Main Thread") or n in main_names]
            if len(main) == 1:
                mapping[(pid, tid)] = main[0]
    merged = []
    for e in events:
        if e.get("ph") == "M" and e.get("name") in ("process_name", "process_sort_index", "process_labels"):
            continue  # the trace names every process by its cmux role
        e = dict(e)
        if e.get("ph") == "M" and e.get("name") == "thread_name":
            # Chromium's events stay on their own tracks (they would not nest with the sampled frames of the
            # same OS thread); the name says which OS thread they ran on.
            e["args"] = {"name": f"chromium {(e.get('args') or {}).get('name')}"}
        elif "ts" in e:
            e["ts"] = float(e["ts"]) + offset
        merged.append(e)
    return merged, {"events": len(merged), "mapped_threads": len(mapping), "clock": clock,
                    "os_thread": {f"{p}:{t}": o for (p, t), o in mapping.items()}}


def chromium_on_own_tracks(chrome, samples, tracks, kind="chromium"):
    """Chromium's events, each thread on a track of its own: a Chromium thread id that is also a sampled OS
    thread id (Chromium's trace names threads by their system id) moves to a synthetic track, so its slices
    never share a track with that thread's sampled frames (the two do not nest: Perfetto's importer reported
    each partial overlap as slice_spill_overlapping_complete_event). `chrome` itself keeps its ids
    (summarize maps them to OS threads)."""
    sampled = {(thread.get("pid"), thread.get("tid")) for _, _, thread, _ in samples}
    moved = []
    for e in chrome:
        key = (e.get("pid"), e.get("tid"))
        if key in sampled:
            e = dict(e, tid=tracks.tid(key[0], (kind, key[1])))
        moved.append(e)
    # Chromium itself can end a nested complete event a microsecond after its parent (MainFrameAborted in
    # ProxyMain::BeginMainFrame): the child ends with its parent, so the track nests.
    by_track = collections.defaultdict(list)
    for index, e in enumerate(moved):
        if e.get("ph") == "X" and "ts" in e:
            by_track[(e.get("pid"), e.get("tid"))].append(index)
    for indexes in by_track.values():
        indexes.sort(key=lambda i: (float(moved[i]["ts"]), -float(moved[i].get("dur") or 0)))
        ends = []
        for i in indexes:
            e = moved[i]
            start = float(e["ts"])
            while ends and ends[-1] <= start:
                ends.pop()
            end = start + float(e.get("dur") or 0)
            if ends and end > ends[-1]:
                moved[i] = e = dict(e, dur=ends[-1] - start)
                end = ends[-1]
            ends.append(end)
    return moved


def daemon_span_events(out, daemon_pid, tracks):
    events = []
    lines = 0
    path = os.path.join(out, "daemon-spans-stamped.jsonl")
    lanes = Lanes()
    try:
        rows = [json.loads(l) for l in open(path) if l.strip()]
    except (OSError, ValueError):
        rows = []
    for row in rows:
        try:
            span = json.loads(row["line"])
        except (ValueError, KeyError):
            continue
        lines += 1
        total = float(span.get("total_us") or 0)
        if span.get("start_uptime_ns"):  # the request's arrival on the trace clock (when the daemon writes it)
            start, placed = float(span["start_uptime_ns"]) / 1000.0, "start_uptime_ns"
            end = start + total
        else:  # no clock in the line: it was written when the reply was queued, about when tail -F read it
            end, placed = float(row["at_us"]), "line arrival"
            start = end - total
        lane = lanes.place(start, end)
        tid = tracks.tid(daemon_pid, ("daemon spans", lane))
        label = span.get("label") or "span"
        args = {"terminal": span.get("terminal"), "marks": span.get("marks"), "placed_by": placed,
                "thread": span.get("tid")}
        if label.endswith(".follow"):
            events.append({"ph": "i", "s": "t", "pid": daemon_pid, "tid": tid, "ts": end, "name": f"daemon {label}",
                           "cat": "daemon.spans", "args": args})
            continue
        events.append({"ph": "X", "pid": daemon_pid, "tid": tid, "ts": start, "dur": total, "name": f"daemon {label}",
                       "cat": "daemon.spans", "args": args})
        previous = 0.0
        for name, at in span.get("marks") or []:
            at = float(at)
            if at > previous:
                events.append({"ph": "X", "pid": daemon_pid, "tid": tid, "ts": start + previous, "dur": at - previous,
                               "name": str(name), "cat": "daemon.spans"})
            previous = max(previous, at)
    names = {(daemon_pid, tracks.tid(daemon_pid, ("daemon spans", lane))): "daemon spans" + (f" {lane + 1}" if lane else "")
             for lane in range(len(lanes.stacks))}
    return events, {"lines": lines, "lanes": len(lanes.stacks), "track_names": names}, rows


# ---------------------------------------------------------------- Release trace rings (ring v1)

# The Release trace ring as plans/cmux-next/trace.md "Release trace ring v1" gives it, byte for byte: the Swift ring
# (CmuxNextTrace), the Rust `cmux-trace` crate and the C writer write it in every role, and the shared golden file
# pins it (check_ring_reads_the_golden_file). A ring holds its own name and thread tables, so this reader needs no
# catalog and decodes a newer build's ring unchanged. Perfetto reads its shared-memory chunks the same way
# (src/tracing/core/shared_memory_abi.h).
RING_MAGIC = b"CMXTRACE"
RING_VERSION = 1
RING_HEADER_BYTES = 256
RING_CHUNK_BYTES = 1024
RING_PAGE_BYTES = 16384
RING_ENTRY_BYTES = 64  # one name-table or thread-table entry
RING_NAME_TEXT = 55
RING_THREAD_NAME = 46
RING_MAX_NAMES = 65536
RING_NO_THREAD = 0xFFFF_FFFF
RING_PUBLISHED = 2  # a name entry's state once its text is whole
RING_THREAD_STATES = (2, 3)  # live, exited
RING_FLAG_ESTIMATED = 0x02  # t_ns is an estimate (frame.present_estimate)
RING_SUFFIX = ".cmxtrace"
RING_HEADER_FIELDS = ("magic", "version", "header_bytes", "pid", "role", "ring_kind", "clock_domain", "start_uptime_ns",
                      "start_unix_ns", "process_start_unix_us", "boot_session_uuid", "build_uuid", "build_version",
                      "chunk_bytes", "chunk_count", "chunks_offset", "chunk_cursor", "name_table_offset",
                      "name_capacity", "name_cursor", "thread_table_offset", "thread_capacity", "thread_cursor",
                      "categories", "chunks_skipped", "records_dropped", "name_overflow", "thread_overflow",
                      "heap_cursor", "start_continuous_ns", "chunks_overwritten", "recording_start_cursor",
                      "heap_chunks_lost")
RING_HEADER = struct.Struct("<8sIIIHBBQQQ16s16s32sIIQQQIIQIIQQQIIQQQQI")  # bytes 0-235; 236-255 are reserved
RING_CHUNK_HEAD = struct.Struct("<IIQI")  # thread_index, thread_generation, lap_seq, published
RING_RECORD = struct.Struct("<QIHBBQQ")  # t_ns, seq, name, phase, flags, arg0, arg1
RING_ROLES = {1: "app", 2: "daemon", 3: "holder", 4: "terminal-host", 5: "acpmux", 6: "chromium-host", 7: "cli",
              8: "agent-host", 9: "app-host", 10: "browser-host"}
RING_KINDS = {1: "blackbox", 2: "recording"}
RING_CLOCKS = {1: "uptime_raw", 2: "linux_monotonic", 3: "windows_qpc"}
RING_PHASES = {0x42: "B", 0x45: "E", 0x49: "I", 0x62: "b", 0x65: "e", 0x73: "s", 0x66: "f", 0x43: "C"}
RING_COUNTERS = ("chunks_skipped", "records_dropped", "name_overflow", "thread_overflow", "chunks_overwritten",
                 "heap_chunks_lost")
# KeyFlowHop.traceCode (CmuxNextSignposts/KeyFlowHop.swift): bits 0-7 of a `key.flow` record's arg0; bits 8-63 hold
# the key's age in us (two's complement). check_key_flow_codes_match_the_swift reads the Swift.
KEY_FLOW_CODES = {1: "app.key.dispatch", 2: "app.key.dispatched", 3: "app.key.terminal", 4: "app.io_write",
                  5: "app.send", 6: "app.output.decoded", 7: "app.output.received", 8: "app.output.parsed",
                  9: "app.frame.contents", 10: "app.key.commit", 11: "app.frame.commit"}


class RingError(ValueError):
    """Bytes that are not a ring v1 this reader knows (trace.md "Versions": a decoder refuses an unknown version)."""


def ring_text(raw):
    return bytes(raw).split(b"\0", 1)[0].decode("utf-8", "replace")


def ring_header(data):
    """The header's fields, after the checks the Rust decoder makes (cmux-trace/src/decode.rs)."""
    if len(data) < RING_HEADER_BYTES:
        raise RingError("truncated: shorter than the 256-byte header")
    header = dict(zip(RING_HEADER_FIELDS, RING_HEADER.unpack_from(data, 0)))
    if header["magic"] != RING_MAGIC:
        raise RingError("not a cmux trace ring (bad magic)")
    if header["version"] != RING_VERSION:
        raise RingError(f"ring version {header['version']} is not supported")
    if header["header_bytes"] != RING_HEADER_BYTES or header["chunk_bytes"] != RING_CHUNK_BYTES:
        raise RingError("the header or chunk size is not ring v1's")
    count = header["chunk_count"]
    if count == 0 or count & (count - 1):
        raise RingError("chunk_count is not a power of two")
    if header["chunks_offset"] % RING_PAGE_BYTES:
        raise RingError("chunks_offset is not on a 16 KiB boundary")
    if header["name_capacity"] > RING_MAX_NAMES:
        raise RingError("name_capacity is over 65536")
    for offset, entries, size in ((header["name_table_offset"], header["name_capacity"], RING_ENTRY_BYTES),
                                  (header["thread_table_offset"], header["thread_capacity"], RING_ENTRY_BYTES),
                                  (header["chunks_offset"], count, RING_CHUNK_BYTES)):
        if offset < RING_HEADER_BYTES:
            raise RingError("a region overlaps the header")
        if offset + entries * size > len(data):
            raise RingError("truncated: a region ends past the file")
    header["build_version"] = ring_text(header["build_version"])
    for key in ("magic", "boot_session_uuid", "build_uuid"):
        header[key] = bytes(header[key]).hex()
    return header


def ring_names(data, header):
    """{id: text} of the published name entries: catalog, interned and category names alike."""
    names = {}
    for index in range(1, min(header["name_cursor"], header["name_capacity"])):
        at = header["name_table_offset"] + index * RING_ENTRY_BYTES
        state, entry_id, _kind, _category, length = struct.unpack_from("<IHBBB", data, at)
        if state == RING_PUBLISHED:
            names[entry_id] = ring_text(data[at + 9:at + 9 + min(length, RING_NAME_TEXT)])
    return names


def ring_threads(data, header):
    """{index: {generation, tid, qos, state, name}} of the live and exited thread entries."""
    threads = {}
    for index in range(min(header["thread_cursor"], header["thread_capacity"])):
        at = header["thread_table_offset"] + index * RING_ENTRY_BYTES
        state, generation, tid, qos, length = struct.unpack_from("<IIQBB", data, at)
        if state in RING_THREAD_STATES:
            threads[index] = {"generation": generation, "tid": tid, "qos": qos, "state": state,
                              "name": ring_text(data[at + 18:at + 18 + min(length, RING_THREAD_NAME)])}
    return threads


def decode_ring(data, path=""):
    """One ring file (or a copy of a live one), decoded as trace.md's "Decode a chunk" says: a record is kept only when
    its seq is the published seq of its chunk's lap and it belongs to this recording (lap and t_ns), so a torn,
    overwritten or earlier recording's record never appears. Records are merged by t_ns; each thread's records stay
    in the order the thread wrote them. Each record is {t_ns, name, phase, flags, arg0, arg1, thread}, where `thread`
    is the chunk's (index, generation)."""
    data = memoryview(data)
    header = ring_header(data)
    names, threads = ring_names(data, header), ring_threads(data, header)
    count = header["chunk_count"]
    start_lap = header["recording_start_cursor"] // count
    rows = []
    for chunk in range(count):
        at = header["chunks_offset"] + chunk * RING_CHUNK_BYTES
        thread_index, generation, lap_seq, _ = RING_CHUNK_HEAD.unpack_from(data, at)
        if not lap_seq:
            continue
        lap = (lap_seq - 1) // 2
        if lap < start_lap:
            continue
        published = (2 * lap + 2) & 0xFFFF_FFFF
        position = lap * count + chunk
        body = data[at + RING_RECORD.size:at + RING_CHUNK_BYTES]
        for slot, (t_ns, seq, name, phase, flags, arg0, arg1) in enumerate(RING_RECORD.iter_unpack(body), 1):
            if seq == published and t_ns >= header["start_uptime_ns"]:
                rows.append((t_ns, position, slot, name, phase, flags, arg0, arg1, (thread_index, generation)))
    rows.sort(key=lambda row: row[:3])
    unknown, records = collections.Counter(), []
    for t_ns, _, _, name, phase, flags, arg0, arg1, thread in rows:
        code = RING_PHASES.get(phase)
        if code is None:
            unknown[f"0x{phase:02x}"] += 1
            continue
        records.append({"t_ns": t_ns, "name": names.get(name) or f"name#{name}", "phase": code, "flags": flags,
                        "arg0": arg0, "arg1": arg1, "thread": thread})
    info = {"path": path, "pid": header["pid"], "role": RING_ROLES.get(header["role"], f"role#{header['role']}"),
            "kind": RING_KINDS.get(header["ring_kind"], f"kind#{header['ring_kind']}"),
            "clock": RING_CLOCKS.get(header["clock_domain"], f"clock#{header['clock_domain']}"),
            "build": header["build_version"], "records": len(records), "names": len(names), "threads": len(threads),
            **{key: header[key] for key in RING_COUNTERS if header[key]}}
    if unknown:
        info["unknown_phases"] = dict(unknown)
    return {"header": header, "names": names, "threads": threads, "records": records, "info": info}


def ring_thread(ring, key):
    """(tid, name) of the thread a chunk names: its entry when the generations match, else (None, the
    `thread <index> (generation <g>)` that trace.md gives a chunk of an earlier occupant of the entry)."""
    index, generation = key
    entry = ring["threads"].get(index)
    if entry and entry["generation"] == generation:
        return entry["tid"], entry["name"] or str(entry["tid"])
    if index == RING_NO_THREAD:
        return None, "thread table full"
    return None, f"thread {index} (generation {generation})"


def ring_paths(out):
    """The ring files of a recording: those `cmux trace record` copied into OUT/rings (RELEASE_DIR), the
    `<role>-<pid>.recording.cmxtrace` rings the daemon, hosts and holder write into OUT/flows when the DEBUG record
    path sets CMUX_NEXT_TRACE_FLOWS (cmux-flow-trace, p09-observability 011), and any in OUT."""
    paths = []
    for folder in (out, os.path.join(out, RELEASE_DIR), os.path.join(out, "flows")):
        if os.path.isdir(folder):
            paths += [os.path.join(folder, name) for name in sorted(os.listdir(folder)) if name.endswith(RING_SUFFIX)]
    return paths


def ring_identity(ring):
    """What tells one ring from another: its process, kind and start. Two files with the same identity are copies of
    one ring (the same ring in OUT and in OUT/rings)."""
    header = ring["header"]
    return header["pid"], header["ring_kind"], header["start_unix_ns"], header["start_uptime_ns"]


def read_rings(out):
    """Every ring of the recording decoded, each once (a copy of a ring already read is skipped), and {file name:
    why} for each file that is not a ring v1 this reader knows."""
    rings, unreadable, seen = [], {}, set()
    for path in ring_paths(out):
        try:
            with open(path, "rb") as f:
                ring = decode_ring(f.read(), path)
        except (OSError, RingError, struct.error) as error:
            unreadable[os.path.relpath(path, out)] = str(error)
            continue
        if ring_identity(ring) not in seen:
            seen.add(ring_identity(ring))
            rings.append(ring)
    return rings, unreadable


def signed64(value):
    return value - (1 << 64) if value >= 1 << 63 else value


def ring_events(rings, tracks, lane_names):
    """The rings' records as trace events on `ring <thread>` tracks of their process. A thread index names a thread
    only within its ring (trace.md: "Thread index = entry index, per ring"), so each ring's threads get their own
    tracks, named with the ring's kind when the process has more than one ring. A B/E pair becomes one slice (an E
    closes the newest open B of its name on its thread). Instants, flow records and counters stay where they were
    written. An AB/AE pair (matched by name and async id within its ring) becomes a slice on a `ring async <name>`
    track of the process, in lanes where pairs of any of its rings overlap. Returns the events and the counts of
    what did not pair."""
    events, unpaired, pairs = [], collections.Counter(), []
    us = lambda ns: round(ns / 1000.0, 3)
    per_pid = collections.Counter(ring["info"]["pid"] for ring in rings)
    for ring in rings:
        pid = ring["info"]["pid"]
        stacks, opened = collections.defaultdict(list), collections.defaultdict(list)
        ident = ring_identity(ring)
        suffix = f" ({ring['info']['kind']})" if per_pid[pid] > 1 else ""

        def track(thread):
            tid, name = ring_thread(ring, thread)
            synthetic = tracks.tid(pid, ("ring", ident, thread))
            lane_names[(pid, synthetic)] = f"ring {name}{suffix}"
            return synthetic, tid

        for record in ring["records"]:
            phase, name, t_ns = record["phase"], record["name"], record["t_ns"]
            args = {"arg0": record["arg0"], "arg1": record["arg1"]}
            if record["flags"] & RING_FLAG_ESTIMATED:
                args["estimated"] = True
            if phase == "B":
                stacks[record["thread"]].append((name, t_ns, args))
            elif phase == "E":
                stack = stacks[record["thread"]]
                at = next((i for i in range(len(stack) - 1, -1, -1) if stack[i][0] == name), None)
                if at is None:
                    unpaired["end_without_begin"] += 1
                    continue
                unpaired["begin_without_end"] += len(stack) - at - 1  # opened inside it and never closed
                _, begin_ns, begin_args = stack[at]
                del stack[at:]
                synthetic, tid = track(record["thread"])
                events.append({"ph": "X", "pid": pid, "tid": synthetic, "ts": us(begin_ns), "dur": us(t_ns - begin_ns),
                               "name": name, "cat": "ring", "args": {"begin": begin_args, "end": args, "thread": tid}})
            elif phase in ("I", "s", "f"):
                synthetic, tid = track(record["thread"])
                events.append({"ph": "i", "s": "t", "pid": pid, "tid": synthetic, "ts": us(t_ns), "name": name,
                               "cat": "ring" if phase == "I" else "ring.flow", "args": dict(args, thread=tid)})
            elif phase == "C":
                events.append({"ph": "C", "pid": pid, "ts": us(t_ns), "name": name,
                               "args": {"value": signed64(record["arg0"])}})
            elif phase == "b":
                opened[(name, record["arg1"])].append((t_ns, args))
            elif phase == "e":
                begins = opened.get((name, record["arg1"]))
                if not begins:
                    unpaired["async_end_without_begin"] += 1
                    continue
                begin_ns, begin_args = begins.pop()
                pairs.append((begin_ns, -t_ns, pid, name, record["arg1"], begin_args, args))
        unpaired["begin_without_end"] += sum(len(stack) for stack in stacks.values())
        unpaired["async_begin_without_end"] += sum(len(begins) for begins in opened.values())
    # One set of lanes per process and name, across its rings. Lanes nest what it is given in start order (the
    # longest first at one start).
    async_lanes = collections.defaultdict(Lanes)
    for begin_ns, minus_end, pid, name, async_id, begin_args, args in sorted(pairs, key=lambda p: p[:2]):
        lane = async_lanes[(pid, name)].place(begin_ns, -minus_end)
        synthetic = tracks.tid(pid, ("ring async", name, lane))
        lane_names[(pid, synthetic)] = f"ring async {name}" + (f" {lane + 1}" if lane else "")
        events.append({"ph": "X", "pid": pid, "tid": synthetic, "ts": us(begin_ns), "dur": us(-minus_end - begin_ns),
                       "name": name, "cat": "ring.async",
                       "args": {"id": f"0x{async_id:x}", "begin": begin_args, "end": args}})
    return events, {key: n for key, n in unpaired.items() if n}


TERMINAL_KEY_DIGITS = 16


def ring_terminal_key(arg0):
    """A ring hop's terminal: arg0 is the terminal key, the first 8 bytes of the 16-byte id read big-endian
    (cmux-flow-trace `terminal_key`), as 16 lowercase hex digits; "" for 0 (no terminal identity)."""
    return f"{arg0:0{TERMINAL_KEY_DIGITS}x}" if arg0 else ""


def text_terminal_key(terminal):
    """The same key from a CMUX_TRACE_FLOWS record's hex terminal id: its first 16 digits, a shorter id
    left-aligned, as cmux-flow-trace's `terminal_key` reads it; "" for an id that is empty or not hex."""
    digits = (terminal or "")[:TERMINAL_KEY_DIGITS].lower()
    if not digits or any(c not in "0123456789abcdef" for c in digits):
        return ""
    return digits.ljust(TERMINAL_KEY_DIGITS, "0")


def ring_record_tid(ring, record):
    """The OS thread id of the thread a ring record names, else its thread key (an earlier occupant's)."""
    tid, _ = ring_thread(ring, record["thread"])
    return tid if tid is not None else record["thread"]


def ring_flow_inputs(rings):
    """What the rings give the key-press flows (assemble_flows), every item with its exact flow id, so none is
    placed by a window:
    - the app's `key.flow` hops as signpost-shaped events (hop from KEY_FLOW_CODES, flow from arg1, age from the top
      56 bits of arg0);
    - flow records of the other hops: the 12 echo handoffs (`<name>.queued` at the flow out, `<name>.taken` at the
      flow in), cmux-flow-trace's hops under their own names (LEGACY_FLOW_HOPS) and frame.present_estimate (flow in
      arg0), each record's terminal as ring_terminal_key gives it;
    - the ghostty.render slices, each with the frame.gpu_done that completed it."""
    app_events, records, renders, gpu_done = [], [], [], []
    for ring in rings:
        pid = ring["info"]["pid"]
        open_renders = collections.defaultdict(list)
        for record in ring["records"]:
            phase, name, at_us = record["phase"], record["name"], record["t_ns"] / 1000.0
            thread = ring_record_tid(ring, record)
            if name == "key.flow" and phase in ("s", "f"):
                hop = KEY_FLOW_CODES.get(record["arg0"] & 0xFF)
                if hop and record["arg1"]:
                    age = signed64(record["arg0"]) >> 8
                    app_events.append({"name": "key.flow", "pid": pid, "tid": thread, "at_us": at_us,
                                       "message": f"hop={hop} flow={record['arg1']} age_us={age}"})
            elif name in ECHO_HANDOFFS and phase in ("s", "f") and record["arg1"]:
                records.append({"hop": f"{name}{'.queued' if phase == 's' else '.taken'}", "flow": record["arg1"],
                                "terminal": ring_terminal_key(record["arg0"]), "pid": pid, "tid": thread,
                                "at_us": at_us, "ring": True})
            elif name in LEGACY_FLOW_HOPS and phase in ("f", "I"):
                # cmux-flow-trace's step: `f` (the hop's time) then `s` with the flow id; `I` with flow 0.
                records.append({"hop": name, "flow": record["arg1"], "terminal": ring_terminal_key(record["arg0"]),
                                "pid": pid, "tid": thread, "at_us": at_us, "ring": True})
            elif name == "frame.present_estimate" and phase == "I" and record["arg0"]:
                records.append({"hop": name, "flow": record["arg0"], "terminal": "", "pid": pid, "tid": thread,
                                "at_us": at_us, "ring": True})
            elif name == "ghostty.render" and phase == "B":
                open_renders[record["thread"]].append((at_us, record["arg0"]))
            elif name == "ghostty.render" and phase == "E" and open_renders[record["thread"]]:
                start, surface = open_renders[record["thread"]].pop()
                renders.append({"pid": pid, "tid": thread, "start_us": start, "end_us": at_us, "surface": surface,
                                "gpu_done": None})
            elif name == "frame.gpu_done" and phase == "I":
                gpu_done.append({"pid": pid, "tid": thread, "at_us": at_us, "surface": record["arg0"]})
    # The frames of one surface complete in the order they were drawn (one Metal command queue): each gpu_done
    # completes the oldest frame of its surface that began before it and has no completion yet.
    pending = collections.defaultdict(collections.deque)
    timeline = sorted([(r["start_us"], 0, r) for r in renders] + [(g["at_us"], 1, g) for g in gpu_done],
                      key=lambda item: item[:2])
    for _, kind, item in timeline:
        key = (item["pid"], item["surface"])
        if kind == 0:
            pending[key].append(item)
        elif pending[key]:
            pending[key].popleft()["gpu_done"] = item
    renders.sort(key=lambda r: r["start_us"])
    return app_events, records, renders


# ---------------------------------------------------------------- key-press flows

# The hops of one terminal key press in causal order (plans/cmux-next/trace.md, "Key-press flows"). A tuple
# lists the alternatives of one hop: the `__terminal-host` model, then the holder model (where the daemon writes
# the PTY itself and the holder only reads the echo). `app.*` hops are the app's `key.flow` signpost events
# (TypingLatencyProbe), carrying the flow id; `daemon.send.*` carry it from the `send` request; the others are
# flow 0 on the terminal the press went to (CMUX_TRACE_FLOWS records of the daemon, host and holder).
#
# The ring adds hops (p09-observability 102, 049, 037), each carrying the press's flow id: the 12 thread handoffs of
# the echo (ghostty-integration-DESIGN.md "Key to frame"; SignpostName's key.echo.* names), each a flow out when a
# thread queues the item (`<name>.queued`) and a flow in when the next thread takes it (`<name>.taken`); the
# Ghostty frame that draws the echo (ghostty.render) and its Metal completion (frame.gpu_done); and the vsync that
# shows it (frame.present_estimate). They are optional: a recording without the ring has none of them.
ECHO_HANDOFFS = ("key.echo.host_pty_read", "key.echo.host_client_write", "key.echo.daemon_frames",
                 "key.echo.surface_parse", "key.echo.attach_encode", "key.echo.line_out",
                 "key.echo.app_transport_read", "key.echo.main_actor", "key.echo.output_lane", "key.echo.renderer",
                 "key.echo.gpu_done", "key.echo.contents")
_echo = lambda short: ((f"key.echo.{short}.queued",), (f"key.echo.{short}.taken",))
FLOW_HOPS = [
    ("app.key.dispatch",), ("app.key.terminal",), ("app.io_write",), ("app.send",),
    ("daemon.send.write",), ("host.pty.write", "daemon.pty.write"), ("daemon.send.written",),
    ("host.pty.read", "holder.pty.read"), *_echo("host_pty_read"), *_echo("host_client_write"), *_echo("daemon_frames"),
    ("daemon.output.host", "daemon.output.holder"), *_echo("surface_parse"), *_echo("attach_encode"),
    ("daemon.output.attach",), *_echo("line_out"),
    # Three handoffs' taking threads write their own hop before the `.taken` mark, so it sits between the two: the
    # transport reader's decode, the Metal completion handler's gpu_done, main's setContents.
    ("key.echo.app_transport_read.queued",), ("app.output.decoded",), ("key.echo.app_transport_read.taken",),
    *_echo("main_actor"), ("app.output.received",), *_echo("output_lane"),
    ("app.output.parsed",), *_echo("renderer"), ("ghostty.render",),
    ("key.echo.gpu_done.queued",), ("frame.gpu_done",), ("key.echo.gpu_done.taken",),
    ("key.echo.contents.queued",), ("app.frame.contents",), ("key.echo.contents.taken",),
    ("app.frame.commit",), ("frame.present_estimate",),
]
# The hop names of the daemon, hosts and holder: their CMUX_TRACE_FLOWS records' `hop`, and the names cmux-flow-trace
# interns in their rings (`hop_name`, p09-observability 011; check_flow_hop_names_match_the_rust reads it).
LEGACY_FLOW_HOPS = frozenset(hop for alternatives in FLOW_HOPS for hop in alternatives
                             if hop.split(".")[0] in ("daemon", "host", "holder"))
RING_HOPS = frozenset(f"{name}.{end}" for name in ECHO_HANDOFFS for end in ("queued", "taken")) \
    | {"ghostty.render", "frame.gpu_done", "frame.present_estimate"}
# A press's echo is fully measured when every handoff has at least one of its two hops, plus the frame, its GPU
# completion, the commit and the estimated present (the done check of p09-observability, item 7).
ECHO_REQUIRED = tuple((f"{name}.queued", f"{name}.taken") for name in ECHO_HANDOFFS) \
    + (("ghostty.render",), ("frame.gpu_done",), ("app.frame.commit",), ("frame.present_estimate",))
# Every process on the host stamps CLOCK_UPTIME_RAW, so a hop is never earlier than the hops it follows. For each
# hop, those causes: the one causal table for a hop's own time (press_latencies: from its latest cause the press
# has) and for the clock-order check (clock_order_violations). A cause the press lacks is replaced by its own
# causes (present_causes); of alternatives such as host.pty.write / daemon.pty.write one is present.
# The app stamps `app.send` when its socket write returns (TerminalAttachment.enqueueInput: sendNoReply, then the
# socketSubmit mark), so the daemon may read and stamp `daemon.send.write` first: both follow `app.io_write`, and
# `app.send` has no order against the daemon, as `daemon.send.written` has none against the host's PTY write.
# `frame.present_estimate` is the first vsync at or after max(commit, gpu_done) (p09-observability.md, "Present").
# An echo handoff's `.queued` follows the hop before it and its `.taken` the `.queued`; a press without the ring
# falls through them to the older hops. Ghostty's frame follows the renderer's queueing (render_for may give the
# frame already drawing when the item was taken), and the contents follow the frame, not the GPU's end.
_echo_causes = lambda short, causes: {f"key.echo.{short}.queued": causes,
                                      f"key.echo.{short}.taken": (f"key.echo.{short}.queued",)}
CLOCK_CAUSES = {
    "app.key.terminal": ("app.key.dispatch",),
    "app.io_write": ("app.key.terminal",),
    "app.send": ("app.io_write",),
    "daemon.send.write": ("app.io_write",),
    "host.pty.write": ("daemon.send.write",), "daemon.pty.write": ("daemon.send.write",),
    "daemon.send.written": ("daemon.send.write",),
    "host.pty.read": ("host.pty.write", "daemon.pty.write"), "holder.pty.read": ("host.pty.write", "daemon.pty.write"),
    **_echo_causes("host_pty_read", ("host.pty.read", "holder.pty.read")),
    **_echo_causes("host_client_write", ("key.echo.host_pty_read.taken",)),
    **_echo_causes("daemon_frames", ("key.echo.host_client_write.taken",)),
    "daemon.output.host": ("key.echo.daemon_frames.taken",),
    "daemon.output.holder": ("key.echo.daemon_frames.taken",),
    **_echo_causes("surface_parse", ("daemon.output.host", "daemon.output.holder")),
    **_echo_causes("attach_encode", ("key.echo.surface_parse.taken",)),
    "daemon.output.attach": ("key.echo.attach_encode.taken",),
    **_echo_causes("line_out", ("daemon.output.attach",)),
    "key.echo.app_transport_read.queued": ("key.echo.line_out.taken",),
    "app.output.decoded": ("key.echo.app_transport_read.queued",),
    "key.echo.app_transport_read.taken": ("app.output.decoded",),
    **_echo_causes("main_actor", ("key.echo.app_transport_read.taken",)),
    "app.output.received": ("key.echo.main_actor.taken",),
    **_echo_causes("output_lane", ("app.output.received",)),
    "app.output.parsed": ("key.echo.output_lane.taken",),
    **_echo_causes("renderer", ("app.output.parsed",)),
    "ghostty.render": ("key.echo.renderer.queued",),
    "key.echo.gpu_done.queued": ("ghostty.render",),
    "frame.gpu_done": ("key.echo.gpu_done.queued",),
    "key.echo.gpu_done.taken": ("frame.gpu_done",),
    "key.echo.contents.queued": ("ghostty.render",),
    "app.frame.contents": ("key.echo.contents.queued",),
    "key.echo.contents.taken": ("app.frame.contents",),
    "app.frame.commit": ("key.echo.contents.taken",),
    "frame.present_estimate": ("app.frame.commit", "frame.gpu_done"),
}


def present_causes(hop, at):
    """The nearest causes of `hop` that the press has (`at`: hop name to hop): CLOCK_CAUSES, through a cause the
    press lacks to that cause's causes."""
    found, frontier, seen = [], list(CLOCK_CAUSES.get(hop, ())), set()
    while frontier:
        cause = frontier.pop()
        if cause in seen:
            continue
        seen.add(cause)
        if cause in at:
            found.append(cause)
        else:
            frontier.extend(CLOCK_CAUSES.get(cause, ()))
    return found


# For each flow-0 hop: the hop whose time it must follow (the cause): a press's window for the hop starts there
# and ends at the next press's cause on the same terminal (assemble_flows). `daemon.send.written` is not a cause
# of the host's write: the daemon's send returns when the frame is on the host's socket, before or after the
# host writes the PTY.
FLOW_ANCHOR = {"host.pty.write": "daemon.send.write", "daemon.pty.write": "daemon.send.write",
               "host.pty.read": "pty.write", "holder.pty.read": "pty.write",
               "daemon.output.host": "pty.read", "daemon.output.holder": "pty.read",
               "daemon.output.attach": "output"}
FLOW_GROUP = {"host.pty.write": "pty.write", "daemon.pty.write": "pty.write", "host.pty.read": "pty.read",
              "holder.pty.read": "pty.read", "daemon.output.host": "output", "daemon.output.holder": "output"}
# Hops a complete press may lack. `app.key.terminal` (TerminalSurfaceView.keyDown) is drawn when the app emits it,
# but a key can reach Ghostty's IO thread without it, so `app.io_write` / `app.send` also say "reached a terminal".
FLOW_OPTIONAL = {"app.key.terminal"} | RING_HOPS
# The hops that say the key router handed the press to a terminal (else it ran a chord: not a flow).
FLOW_AT_TERMINAL = ("app.key.terminal", "app.io_write", "app.send")
# The target of every press assemble_flows builds (the percentiles are per target, as input_latency's rows).
KEY_TARGET_TERMINAL = "terminal"
# The flow-0 stages in causal order: (group, alternatives, the group or hop each one's window starts at).
FLOW0_STAGES = [(FLOW_GROUP.get(alternatives[0], alternatives[0]), alternatives, FLOW_ANCHOR[alternatives[0]])
                for alternatives in FLOW_HOPS if alternatives[0] in FLOW_ANCHOR]


def read_flow_records(out):
    """The CMUX_TRACE_FLOWS records of an older daemon, host or holder (OUT/flows/flows-<pid>.jsonl), times in us,
    and the dropped counts each process reported. A newer one writes a ring into OUT/flows instead (ring_paths).
    Each record's terminal is its terminal key (text_terminal_key), so it meets a ring's record of the same
    terminal."""
    records, dropped = [], {}
    folder = os.path.join(out, "flows")
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if not name.endswith(".jsonl"):
            continue
        with open(os.path.join(folder, name), errors="replace") as f:
            for line in f:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if "dropped" in row:
                    dropped[name] = row["dropped"]
                elif row.get("hop"):
                    records.append({"hop": row["hop"], "ph": row.get("ph"), "flow": int(row.get("flow") or 0),
                                    "terminal": text_terminal_key(row.get("terminal")),
                                    "pid": row.get("pid"), "tid": row.get("tid"), "at_us": float(row["t_ns"]) / 1000.0})
    return records, dropped


def app_key_hops(app_events):
    """{flow: {hop: {hop, at_us, pid, tid, age_us}}} of the app's `key.flow` events: the first of each hop."""
    app_hops = collections.defaultdict(dict)
    for event in app_events:
        fields = signposts_lib.fields(event.get("message") or "")
        try:
            flow = int(fields.get("flow", "0"))
        except ValueError:
            continue
        hop = fields.get("hop")
        if flow and hop and hop not in app_hops[flow]:
            app_hops[flow][hop] = {"hop": hop, "at_us": event["at_us"], "pid": event.get("pid"), "tid": event.get("tid"),
                                   "age_us": fields.get("age_us")}
    return app_hops


def render_for(renders, hop):
    """The ghostty.render slice on the thread of `hop` (the renderer's key.echo.renderer.taken) that holds it, else
    the first that begins after it there; None when that thread drew no frame."""
    frames = renders.get((hop["pid"], hop["tid"]))
    if not frames:
        return None
    index = bisect.bisect_right(frames["starts"], hop["at_us"]) - 1
    if index >= 0 and frames["rows"][index]["end_us"] >= hop["at_us"]:
        return frames["rows"][index]
    return frames["rows"][index + 1] if index + 1 < len(frames["rows"]) else None


def assemble_flows(app_events, records, renders=()):
    """One entry per key press the app opened that reached a terminal: its hops in causal order, each {hop, at_us,
    pid, tid}, the hops it misses, the flow-0 hops it could not place (`ambiguous`), whether it is complete (every
    hop of FLOW_HOPS but FLOW_OPTIONAL, one alternative each), whether its echo is fully measured (ECHO_REQUIRED)
    and which hops a window placed (`windowed`).

    A record with the press's flow id is exact: it always wins. A flow-0 record carries only its terminal; only an
    old recording's (CMUX_TRACE_FLOWS files, never a ring's) is placed by windows, and only for a stage the press has
    no exact record of. The presses sent to one terminal (daemon.send.write with their flow id) are taken in send
    order; for each flow-0 stage, a press's window runs from its own anchor (the stage's cause) up to the next
    press's anchor on that terminal, and no later than the press's own decoded output. The press takes the record
    only when the window holds exactly one and the press before placed its own record of that stage; otherwise
    (none, two, or one that may be the press before's late one: keys typed faster than their echo) the stage stays
    missing and `ambiguous` says why. A record goes to one press at most.

    `renders` (ring_flow_inputs) gives the press its ghostty.render (the frame on the thread its
    key.echo.renderer.taken hop names) and that frame's frame.gpu_done."""
    app_hops = app_key_hops(app_events)
    by_flow = collections.defaultdict(dict)
    by_terminal = collections.defaultdict(list)
    for record in records:
        if record["flow"]:
            by_flow[record["flow"]].setdefault(record["hop"], record)
        elif not record.get("ring"):
            by_terminal[(record["hop"], record["terminal"])].append(record)
    frames = collections.defaultdict(lambda: {"starts": [], "rows": []})
    for render in sorted(renders, key=lambda r: r["start_us"]):
        frames[(render["pid"], render["tid"])]["starts"].append(render["start_us"])
        frames[(render["pid"], render["tid"])]["rows"].append(render)
    presses = []
    for flow in sorted(app_hops, key=lambda f: app_hops[f].get("app.key.dispatch", {"at_us": 0})["at_us"]):
        hops = app_hops[flow]
        # A press that never reached a terminal (a chord the key router ran as an action) has no echo to follow.
        if "app.key.dispatch" not in hops or not (any(h in hops for h in FLOW_AT_TERMINAL) or flow in by_flow):
            continue
        found = dict(hops)
        for hop, record in by_flow.get(flow, {}).items():
            found.setdefault(hop, {"hop": hop, "at_us": record["at_us"], "pid": record["pid"], "tid": record["tid"]})
        renderer = found.get("key.echo.renderer.taken")
        render = render_for(frames, renderer) if renderer else None
        if render:
            found.setdefault("ghostty.render", {"hop": "ghostty.render", "at_us": render["start_us"],
                                                "pid": render["pid"], "tid": render["tid"]})
            if render["gpu_done"]:
                done = render["gpu_done"]
                found.setdefault("frame.gpu_done", {"hop": "frame.gpu_done", "at_us": done["at_us"],
                                                    "pid": done["pid"], "tid": done["tid"]})
        terminal = (by_flow.get(flow, {}).get("daemon.send.write") or {}).get("terminal")
        presses.append({"flow": flow, "terminal": terminal, "found": found, "groups": {}, "ambiguous": {}, "early": [],
                        "windowed": [], "bound": (found.get("app.output.decoded") or {}).get("at_us", float("inf"))})
    on_terminal = collections.defaultdict(list)
    for press in presses:
        if press["terminal"]:
            on_terminal[press["terminal"]].append(press)
    for terminal, sent in on_terminal.items():
        sent.sort(key=lambda p: p["found"]["daemon.send.write"]["at_us"])
        for group, alternatives, anchor_name in FLOW0_STAGES:
            rows = sorted((r for hop in alternatives for r in by_terminal.get((hop, terminal), [])),
                          key=lambda r: r["at_us"])
            times = [r["at_us"] for r in rows]
            causes = [p["groups"].get(anchor_name) or p["found"].get(anchor_name) for p in sent]
            anchors = [cause and cause["at_us"] for cause in causes]
            taken, previous_placed, placed_at = set(), True, float("-inf")
            for index, press in enumerate(sent):
                exact = next((press["found"][hop] for hop in alternatives if hop in press["found"]), None)
                if exact:
                    press["groups"][group] = exact
                    previous_placed, placed_at = True, exact["at_us"]
                    continue
                anchor = anchors[index]
                if anchor is None:
                    previous_placed = False
                    continue
                upper = next((a for a in anchors[index + 1:] if a is not None), float("inf"))
                lo, hi = bisect.bisect_left(times, anchor), bisect.bisect_left(times, upper)
                candidates = [r for r in rows[lo:hi] if r["at_us"] <= press["bound"] and id(r) not in taken]
                if len(candidates) == 1 and previous_placed:
                    record = candidates[0]
                    taken.add(id(record))
                    entry = {"hop": record["hop"], "at_us": record["at_us"], "pid": record["pid"], "tid": record["tid"]}
                    press["found"][record["hop"]] = press["groups"][group] = entry
                    press["windowed"].append(record["hop"])
                    previous_placed, placed_at = True, record["at_us"]
                    continue
                if candidates:
                    press["ambiguous"]["|".join(alternatives)] = {"candidates": len(candidates),
                                                                  "earlier_unplaced": not previous_placed}
                elif previous_placed and press["bound"] != float("inf"):
                    # The echo came back but the window is empty: one record of the stage after the press before's
                    # own and before this press's cause can only be this press's, stamped off the clock.
                    early = [r for r in rows[bisect.bisect_right(times, placed_at):lo] if id(r) not in taken]
                    if len(early) == 1:
                        record = early[0]
                        press["early"].append({"hop": record["hop"], "at_us": record["at_us"], "pid": record["pid"],
                                               "tid": record["tid"], "cause": causes[index]})
                previous_placed = False
    flows = []
    for press in presses:
        found = press["found"]
        chain, missing = [], []
        for alternatives in FLOW_HOPS:
            present = [found[hop] for hop in alternatives if hop in found]
            if present:
                chain.append(present[0])
            elif not set(alternatives) <= FLOW_OPTIONAL:
                missing.append("|".join(alternatives))
        chain.sort(key=lambda h: h["at_us"])
        flows.append({"flow": press["flow"], "target": KEY_TARGET_TERMINAL, "terminal": press["terminal"], "hops": chain,
                      "missing": missing, "ambiguous": press["ambiguous"], "early": press["early"],
                      "complete": not missing, "windowed": press["windowed"],
                      "echo_complete": all(any(hop in found for hop in need) for need in ECHO_REQUIRED)})
    return flows


def flow_warnings(app_events, records, flows):
    """Why a recording with flow data assembled no (or no joined) press, in words for the summary: the app's
    key.flow hops absent, no press at a terminal, or no daemon record carrying a press's flow id."""
    warnings = []
    if records and not app_events:
        warnings.append(f"{len(records)} daemon/host/holder flow records but no app `key.flow` signpost: the app's "
                        f"flow hops (TypingLatencyProbe key.flow, CMUX_TRACE_FLOWS) are not in this build, so no "
                        f"press can assemble")
    elif app_events and not flows:
        warnings.append(f"{len(app_events)} app `key.flow` events but no press reached a terminal (no "
                        f"{' / '.join(FLOW_AT_TERMINAL)} hop)")
    pressed = {f["flow"] for f in flows}
    if flows and not any(r["flow"] in pressed for r in records):
        sends = sum(1 for r in records if r["hop"] == "daemon.send.write")
        warnings.append(f"{len(flows)} presses but no daemon record carries a press's flow id ({sends} "
                        f"daemon.send.write records with flow 0: the app's `send` request has no `flow`), so "
                        f"nothing past the app joins a press")
    return warnings


def flow_events(flows, tracks, lane_names, started=frozenset()):
    """One slice per hop on a `key flow` track of the hop's process, from the hop to the next hop of the press,
    chained by Perfetto flow arrows (JSON flow v2: `bind_id`, `flow_out`, `flow_in`). A press whose flow id is
    in `started` (its `input latency` slice opened the arrow) takes it in at its first hop too."""
    events, lanes = [], collections.defaultdict(Lanes)
    for entry in flows:
        hops = entry["hops"]
        for index, hop in enumerate(hops):
            # Rounded to the ns, as the importer reads them: unrounded, a hop's end can pass the next hop's
            # start by a float ulp on the same lane (slice_spill_overlapping_complete_event).
            end = round(hops[index + 1]["at_us"] if index + 1 < len(hops) else hop["at_us"] + 1.0, 3)
            start = round(hop["at_us"], 3)
            pid = hop["pid"]
            lane = lanes[pid].place(start, max(end, start + 1.0))
            tid = tracks.tid(pid, ("key flow", lane))
            lane_names[(pid, tid)] = "key flow" + (f" {lane + 1}" if lane else "")
            event = {"ph": "X", "pid": pid, "tid": tid, "ts": start, "dur": round(max(end - start, 1.0), 3), "name": hop["hop"],
                     "cat": "key.flow", "bind_id": f"0x{entry['flow']:x}",
                     "args": {"flow": f"0x{entry['flow']:x}", "thread": hop.get("tid"),
                              "to_next_ms": round((end - start) / 1000, 3), "complete": entry["complete"]}}
            if index + 1 < len(hops):
                event["flow_out"] = True
            if index or entry["flow"] in started:
                event["flow_in"] = True
            events.append(event)
    return events


# A key press starts at the app's dispatch, its echo frame commits at the app's commit (a complete press always
# has it) and shows at the estimated present (a Release ring hop, so a press may lack it).
KEY_START_HOP = "app.key.dispatch"
KEY_COMMIT_HOP = "app.frame.commit"
KEY_PRESENT_HOP = "frame.present_estimate"


def press_latencies(entry):
    """One press's times in ms: each hop's time from its latest cause the press has (CLOCK_CAUSES through
    present_causes, so a join such as the present counts from max(commit, gpu_done)), key to the echo frame's
    commit, and key to that frame's estimated present (None without the hop)."""
    at = {h["hop"]: h["at_us"] for h in entry["hops"]}
    steps = []
    for hop in entry["hops"]:
        causes = present_causes(hop["hop"], at)
        if causes:
            steps.append((hop["hop"], (hop["at_us"] - max(at[c] for c in causes)) / 1000))
    start = at.get(KEY_START_HOP)
    since_key = lambda end: None if start is None or end is None else (end - start) / 1000
    return steps, since_key(at.get(KEY_COMMIT_HOP)), since_key(at.get(KEY_PRESENT_HOP))


def flow_percentiles(flows):
    """Over the complete presses, per target (what the key went to; assemble_flows builds only
    KEY_TARGET_TERMINAL presses): key to commit, key to the estimated present and each hop from its cause, as
    pct() rows. A target with no present hop has None there (a recording without frame.present_estimate)."""
    commits, presents = collections.defaultdict(list), collections.defaultdict(list)
    steps = collections.defaultdict(lambda: collections.defaultdict(list))
    for entry in flows:
        if not entry["complete"]:
            continue
        target = entry["target"]
        hops, to_commit, to_present = press_latencies(entry)
        for hop, ms in hops:
            steps[target][hop].append(ms)
        if to_commit is not None:
            commits[target].append(to_commit)
        if to_present is not None:
            presents[target].append(to_present)
    targets = sorted(set(commits) | set(presents) | set(steps))
    return {"key_to_commit_ms": {t: pct(commits[t]) for t in targets},
            "key_to_present_estimate_ms": {t: pct(presents[t]) for t in targets},
            "hop_ms": {t: {hop: pct(values) for hop, values in steps[t].items()} for t in targets}}


def flow_summary(flows, dropped, warnings=()):
    """The presses and how many are complete (their percentiles are flow_percentiles'); the incomplete presses
    with what they miss, which flow-0 hops were ambiguous and which were stamped before their cause (`early`);
    and `warnings` (flow_warnings) when the recording's flow data could not assemble."""
    return {"presses": len(flows), "complete": sum(1 for f in flows if f["complete"]),
            "echo_complete": sum(1 for f in flows if f.get("echo_complete")),
            "windowed_presses": sum(1 for f in flows if f.get("windowed")),
            "incomplete": [{"flow": f"0x{f['flow']:x}", "missing": f["missing"], "ambiguous": f.get("ambiguous") or {},
                            "early": [e["hop"] for e in f.get("early") or []]}
                           for f in flows if not f["complete"]][:10],
            "dropped_records": dropped, "warnings": list(warnings),
            "flows": [{"flow": f"0x{f['flow']:x}", "target": f["target"], "terminal": f["terminal"],
                       "complete": f["complete"], "echo_complete": f.get("echo_complete", False),
                       "windowed": f.get("windowed") or [],
                       "hops": [{"hop": h["hop"], "at_us": round(h["at_us"], 1), "pid": h["pid"]} for h in f["hops"]]}
                      for f in flows[:60]]}


# ---------------------------------------------------------------- clock order and request links

# A daemon request's flow records (task 103: both sides derive the flow id from the app's pid and the request
# id, no wire change): flow-out (`s`) at the app's send and at the daemon's reply, flow-in (`f`) at the daemon's
# receive and at the app's reply-receive. Perfetto counts the same break as `flow_end_without_start`
# (src/trace_processor/storage/stats.h); here it is a request the daemon never received.
REQUEST_FLOW_NAME = "daemon.request"
# Sources stamp whole microseconds or finer and some are rounded to the us: an effect up to this much earlier
# than its cause is rounding, not a clock error.
CLOCK_ORDER_SLACK_US = 1.0


def request_flows(records):
    """The daemon requests' flow records (REQUEST_FLOW_NAME with phase `s` or `f` and a flow id) by flow id, each
    list in time order."""
    by_flow = collections.defaultdict(list)
    for record in records:
        if record.get("hop") == REQUEST_FLOW_NAME and record.get("ph") in ("s", "f") and record.get("flow"):
            by_flow[record["flow"]].append(record)
    for rows in by_flow.values():
        rows.sort(key=lambda r: r["at_us"])
    return by_flow


def clock_order_violations(flows, request_records):
    """One entry per hop that is earlier than a cause: a key press's hop before a hop CLOCK_CAUSES says it
    follows, a flow-0 record stamped before the cause of its stage (assemble_flows' `early`: off the clock, it
    never joined the press), and a request's flow-in before every flow-out of another process (the daemon's
    receive before the app's send, the app's reply-receive before the daemon's reply). A flow-in with no flow-out
    of another process is an unlinked request (request_flow_summary), not a clock error."""
    violations = []

    def key_violation(entry, hop, late):
        violations.append({"kind": "key", "flow": f"0x{entry['flow']:x}", "target": entry["target"],
                           "hop": hop["hop"], "pid": hop.get("pid"), "at_us": round(hop["at_us"], 3),
                           "before": [{"hop": c["hop"], "pid": c.get("pid"), "at_us": round(c["at_us"], 3)} for c in late],
                           "by_us": round(max(c["at_us"] for c in late) - hop["at_us"], 3)})

    for entry in flows:
        at = {h["hop"]: h for h in entry["hops"]}
        for hop in entry["hops"]:
            late = [at[c] for c in present_causes(hop["hop"], at) if hop["at_us"] < at[c]["at_us"] - CLOCK_ORDER_SLACK_US]
            if late:
                key_violation(entry, hop, late)
        for record in entry.get("early") or []:
            if record["at_us"] < record["cause"]["at_us"] - CLOCK_ORDER_SLACK_US:
                key_violation(entry, record, [record["cause"]])
    for flow, rows in request_flows(request_records).items():
        for row in rows:
            if row["ph"] != "f":
                continue
            outs = [r for r in rows if r["ph"] == "s" and r.get("pid") != row.get("pid")]
            if outs and all(row["at_us"] < r["at_us"] - CLOCK_ORDER_SLACK_US for r in outs):
                cause = outs[0]
                violations.append({"kind": "request", "flow": f"0x{flow:x}", "hop": "flow-in", "pid": row.get("pid"),
                                   "at_us": round(row["at_us"], 3),
                                   "before": [{"hop": "flow-out", "pid": cause.get("pid"),
                                               "at_us": round(cause["at_us"], 3)}],
                                   "by_us": round(cause["at_us"] - row["at_us"], 3)})
    return violations


def request_flow_summary(request_records):
    """How many daemon requests link across processes. A request is a flow id with a flow-out; it is linked when
    another process has a flow-in on it (the daemon received it), and a round trip when two processes have both
    (the reply came back). `request_flow_linked` is the linked percentage, None without request records (a
    recording from before task 103 has none to link, which is not 0%)."""
    requests = linked = round_trips = 0
    unlinked = []
    for flow, rows in request_flows(request_records).items():
        outs = {r.get("pid") for r in rows if r["ph"] == "s"}
        ins = {r.get("pid") for r in rows if r["ph"] == "f"}
        if not outs:
            continue
        requests += 1
        if any(i != o for i in ins for o in outs):
            linked += 1
            round_trips += len(outs & ins) >= 2
        else:
            unlinked.append(f"0x{flow:x}")
    return {"request_flow_linked": round(100.0 * linked / requests, 1) if requests else None,
            "request_flows": {"requests": requests, "linked": linked, "round_trips": round_trips,
                              "unlinked": unlinked[:10]}}


def clock_report(flows, request_records):
    """The summary's clock fields: the violation count, what was checked (the complete presses: an incomplete one
    misses hops whose order nothing checked, though its `early` records still count) and the first violations."""
    violations = clock_order_violations(flows, request_records)
    complete = sum(1 for f in flows if f["complete"])
    return {"clock_order_violations": len(violations),
            "clock_order": {"checked_presses": complete, "unchecked_presses": len(flows) - complete,
                            "checked_requests": len(request_flows(request_records)), "violations": violations[:20]}}


def violation_text(violation):
    """One clock-order violation in words."""
    before = ", ".join(f"{c['hop']} (pid {c['pid']})" for c in violation["before"])
    return (f"{violation['kind']} {violation['flow']}: {violation['hop']} (pid {violation['pid']}) "
            f"{violation['by_us']} us before {before}")


def clock_text(code, report):
    """check-clock's report in words."""
    checked = report["clock_order"]
    verdict = {0: "ok", 1: "FAILED", 2: "nothing to check"}[code]
    return "\n".join([f"trace: clock order {verdict}: {report['clock_order_violations']} violation(s) in "
                      f"{checked['checked_presses']} complete key presses ({checked['unchecked_presses']} incomplete, "
                      f"not checked) and {checked['checked_requests']} daemon requests"]
                     + [f"  {violation_text(v)}" for v in checked["violations"]])


def ring_request_records(rings):
    """The daemon requests' flow records in v1 trace rings (read_rings), as read_flow_records gives them: a
    REQUEST_FLOW_NAME flow out (`s`) or in (`f`) carries its flow id in arg1, as every ring flow record does."""
    return [{"hop": REQUEST_FLOW_NAME, "ph": record["phase"], "flow": record["arg1"], "terminal": "",
             "pid": ring["info"]["pid"], "tid": ring_record_tid(ring, record), "at_us": record["t_ns"] / 1000.0}
            for ring in rings for record in ring["records"]
            if record["name"] == REQUEST_FLOW_NAME and record["phase"] in ("s", "f") and record["arg1"]]


def load_flow_inputs(out, signposts, rings=()):
    """What build() and check-clock assemble from one recording, read once in one place so both see the same
    presses and requests: (the app's key.flow events, the flow records a key press can join, the daemon
    requests' flow records, the dropped counts, the ghostty.render frames). `signposts` is read_signposts' result
    for OUT; `rings` are the recording's v1 trace rings (read_rings). The rings' records carry exact flow ids; the
    signposts and CMUX_TRACE_FLOWS files of an old recording come after them."""
    ring_app, ring_records, renders = ring_flow_inputs(rings)
    records, dropped = read_flow_records(out)
    app_events = ring_app + [e for e in signposts["events"] if e["name"] == "key.flow"]
    key_records = ring_records + [r for r in records if r["hop"] != REQUEST_FLOW_NAME]
    request_records = [r for r in records if r["hop"] == REQUEST_FLOW_NAME] + ring_request_records(rings)
    return app_events, key_records, request_records, dropped, renders


def check_clock(out, rings=None):
    """`check-clock DIR`: the clock order of DIR's key presses and daemon requests (load_flow_inputs, as build()
    reads them; `rings` defaults to DIR's, read_rings), without rebuilding the trace; also DIR/clock-check.json.
    Returns (exit code, report): 1 on a violation; 2 when DIR has no complete press and no request (nothing was
    checked); else 0."""
    signposts = read_signposts(os.path.join(out, "signposts.ndjson"))
    if rings is None:
        rings = read_rings(out)[0]
    app_events, key_records, request_records, _, renders = load_flow_inputs(out, signposts, rings)
    report = {**clock_report(assemble_flows(app_events, key_records, renders), request_records),
              "signpost_clock": signposts["clock"]}
    write_json(os.path.join(out, "clock-check.json"), report)
    if report["clock_order_violations"]:
        return 1, report
    checked = report["clock_order"]["checked_presses"] or report["clock_order"]["checked_requests"]
    return (0 if checked else 2), report


# ---------------------------------------------------------------- input latency (Chrome's EventLatency)

# InputLatencyTracker (CmuxNextInput) emits one `input.latency` signpost event per closed slot, numbers only
# (Signposter.event(_:_:) with an InputLatencySignpostMessage): `kind target entry source vrr coalesced frame gen_ns`,
# then each stage as microseconds after gen_ns, -1 when the slot skipped it. kind, target, entry and source are the
# raw values (case order) of CmuxNextInputCore's InputEventKind, InputTarget, InputEntrypoint and
# InputPresentationSource. gen_ns is CLOCK_UPTIME_RAW ns (NSEvent.timestamp's clock), the trace clock already.
INPUT_KINDS = ("keyPress", "keyRelease", "flags", "mousePress", "mouseRelease", "pointerMove", "drag", "scrollBegin",
               "scrollFirstUpdate", "scrollUpdate", "scrollMomentum", "scrollEnd", "magnify")
INPUT_KEY_KINDS = ("keyPress", "keyRelease")
INPUT_TARGETS = ("terminal", "textView", "chromiumPage", "webkitPage", "agentPane", "layout", "sidebar", "palette",
                 "other")
INPUT_ENTRYPOINTS = ("person", "automation")
INPUT_SOURCES = ("estimatedVsync", "metalPresented", "hostFeedback", "pageEstimated", "extrapolatedVsync",
                 "nominalRefresh")
# (stage, message field) in InputStage order after `generated` (gen_ns itself). `last_gen_us`, the newest coalesced
# event, is an argument, not a stage boundary: Chrome's EventLatency starts at the oldest coalesced event.
INPUT_STAGES = (("arrived_main", "arrived_us"), ("dispatch_start", "dispatch_start_us"),
                ("text_input_start", "ti_start_us"), ("text_input_end", "ti_end_us"),
                ("dispatch_end", "dispatch_end_us"), ("main_commit", "commit_us"),
                ("content_submitted", "content_us"), ("daemon_received", "daemon_us"), ("pty_written", "pty_us"),
                ("echo_read", "echo_read_us"), ("echo_sent", "echo_sent_us"), ("presented", "presented_us"))
INPUT_STAGE_ORDER = ("generated",) + tuple(stage for stage, _ in INPUT_STAGES)
# Every message field in the order Signposter.event(_:_:) writes them (the self-test reads them from the Swift).
INPUT_MESSAGE_FIELDS = ("kind", "target", "entry", "source", "vrr", "coalesced", "frame", "gen_ns", "last_gen_us") \
    + tuple(field for _, field in INPUT_STAGES)
INPUT_TRACK = "input latency"
# TypingLatencyProbe takes a key's `app.key.dispatch` age just before it writes the hop, so the hop's time minus
# its age is the key's OS timestamp plus that write (microseconds); keys are milliseconds apart.
INPUT_FLOW_MATCH_US = 1000.0


def camel(stage):
    return "".join(part.capitalize() for part in stage.split("_"))


def input_int(fields, key, default=-1):
    try:
        return int(fields.get(key, default))
    except ValueError:
        return default


def input_name(names, raw):
    """The case name of an enum raw value; `unknown#<raw>` for a case this script does not know yet."""
    return names[raw] if 0 <= raw < len(names) else f"unknown#{raw}"


def input_latency_slots(signposts):
    """The tracker's closed slots from read_signposts' events: {pid, generated_ns, stages: {stage: ns}, kind, target,
    entrypoint, source, update, vrr, coalesced, last_generated_ns}. A slot with no gen_ns cannot be placed and is
    counted in `unplaced`."""
    slots, unplaced = [], 0
    for event in signposts["events"]:
        if event["name"] != "input.latency":
            continue
        fields = signposts_lib.fields(event.get("message") or "")
        generated = input_int(fields, "gen_ns", 0)
        if generated <= 0:
            unplaced += 1
            continue
        stages = {"generated": generated}
        for stage, field in INPUT_STAGES:
            offset = input_int(fields, field)
            if offset >= 0:
                stages[stage] = generated + offset * 1000
        last = input_int(fields, "last_gen_us")
        slots.append({"pid": event.get("pid"), "generated_ns": generated, "stages": stages,
                      "kind": input_name(INPUT_KINDS, input_int(fields, "kind")),
                      "target": input_name(INPUT_TARGETS, input_int(fields, "target")),
                      "entrypoint": input_name(INPUT_ENTRYPOINTS, input_int(fields, "entry")),
                      "source": input_name(INPUT_SOURCES, input_int(fields, "source")),
                      "update": input_int(fields, "frame", 0) == 1, "vrr": input_int(fields, "vrr", 0) == 1,
                      "coalesced": input_int(fields, "coalesced", 1),
                      "last_generated_ns": generated + last * 1000 if last >= 0 else None})
    slots.sort(key=lambda s: s["generated_ns"])
    return slots, unplaced


def input_flow_links(slots, flows):
    """{index of a key slot: (flow id, its `app.key.dispatch` hop's time in us)} for each key.flow chain whose
    dispatch hop is that key: the same process and, within INPUT_FLOW_MATCH_US, the same OS timestamp (the hop's
    time minus its age). Each chain bisects into its process's key slots sorted by generated time, so a recording
    costs O((slots + chains) log slots). The nearest pair links first and each slot and chain links once."""
    keys = collections.defaultdict(lambda: ([], []))  # pid -> (generated us, slot index), in generated order
    for index, slot in enumerate(slots):
        if slot["kind"] == "keyPress":
            at, indices = keys[slot["pid"]]
            at.append(slot["generated_ns"] / 1000.0)
            indices.append(index)
    pairs = []
    for flow in flows:
        dispatch = next((h for h in flow["hops"] if h["hop"] == "app.key.dispatch"), None)
        try:
            event_us = dispatch["at_us"] - float(dispatch.get("age_us"))
        except (TypeError, ValueError):
            continue
        if dispatch["pid"] not in keys:
            continue
        at, indices = keys[dispatch["pid"]]
        lo = bisect.bisect_left(at, event_us - INPUT_FLOW_MATCH_US)
        hi = bisect.bisect_right(at, event_us + INPUT_FLOW_MATCH_US)
        pairs += [(abs(event_us - at[i]), indices[i], flow["flow"], dispatch["at_us"]) for i in range(lo, hi)]
    links, taken = {}, set()
    for _, index, flow, hop_us in sorted(pairs):
        if index not in links and flow not in taken:
            links[index] = (flow, hop_us)
            taken.add(flow)
    return links


def input_stage_spans(slot):
    """(start_ns, end_ns, [(name, start_ns, end_ns)], out_of_order): the slot's slice from `generated` to
    `presented` (to its last stage when it closed unpresented) and one child per step between consecutive
    stages it has, ordered by time, named `<From>To<To>` as Chrome's EventLatency breakdown names its stages
    (cc/metrics/event_latency_tracing_recorder.cc). A skipped stage joins its neighbours into one child; a stage
    outside [generated, end] is left out and counted, so every child nests in the slice."""
    stages = slot["stages"]
    start = stages["generated"]
    present = [(stages[s], INPUT_STAGE_ORDER.index(s), s) for s in INPUT_STAGE_ORDER if s in stages]
    end = stages.get("presented") or max(at for at, _, _ in present)
    inside = sorted(p for p in present if start <= p[0] <= end)
    children = [(f"{camel(a)}To{camel(b)}", a_at, b_at)
                for (a_at, _, a), (b_at, _, b) in zip(inside, inside[1:]) if b_at > a_at]
    return start, end, children, len(present) - len(inside)


def input_latency_events(slots, app_pid, tracks, lane_names, links):
    """One `EventLatency <kind> <target>` slice per slot on an `input latency` track of its process, with its
    stage children nested inside. Overlapping slots (a key typed before the previous one presented) go to the
    next lane: a slot never nests in another (Lanes would nest one held inside another's span, and their stage
    children would then cross). Times are whole us written with 3 decimals, so the JSON text is exact and the last
    child ends where the slice ends. A slot in `links` (input_flow_links) starts its key.flow chain's arrow from the
    stage that ends at its dispatch hop."""
    us = lambda ns: round(ns / 1000.0, 3)
    events, lane_ends = [], collections.defaultdict(list)
    for index, slot in enumerate(slots):
        start_ns, end_ns, children, out_of_order = input_stage_spans(slot)
        end_ns = max(end_ns, start_ns + 1000)
        pid = slot["pid"] or app_pid
        ends = lane_ends[pid]
        lane = next((i for i, at in enumerate(ends) if at <= start_ns), len(ends))
        ends[lane:lane + 1] = [end_ns]
        tid = tracks.tid(pid, (INPUT_TRACK, lane))
        lane_names[(pid, tid)] = INPUT_TRACK + (f" {lane + 1}" if lane else "")
        args = {"kind": slot["kind"], "target": slot["target"], "entrypoint": slot["entrypoint"],
                "presentation_source": slot["source"], "variable_refresh": slot["vrr"],
                "caused_frame_update": slot["update"], "presented": "presented" in slot["stages"],
                "coalesced": slot["coalesced"], "total_ms": round((end_ns - start_ns) / 1e6, 3),
                "skipped_stages": [s for s in INPUT_STAGE_ORDER if s not in slot["stages"]],
                "stages_out_of_order": out_of_order}
        if slot["last_generated_ns"] is not None:
            args["oldest_to_newest_coalesced_ms"] = round((slot["last_generated_ns"] - start_ns) / 1e6, 3)
        parent = {"ph": "X", "pid": pid, "tid": tid, "ts": us(start_ns), "dur": us(end_ns - start_ns),
                  "name": f"EventLatency {slot['kind']} {slot['target']}", "cat": "input.latency", "args": args}
        stage_events = [{"ph": "X", "pid": pid, "tid": tid, "ts": us(a), "dur": us(b - a), "name": name,
                         "cat": "input.latency.stage", "args": {"ms": round((b - a) / 1e6, 3)}} for name, a, b in children]
        if index in links:
            flow, hop_us = links[index]
            args["flow"] = f"0x{flow:x}"
            # Perfetto draws an arrow from its source's end to its target's start: it leaves the last stage that
            # ended by the dispatch hop (ArrivedMainToDispatchStart when the slot has it), never the whole slice,
            # whose end is the frame presented well after the hop.
            source = next((e for e in reversed(stage_events or [parent]) if e["ts"] + e["dur"] <= hop_us),
                          (stage_events or [parent])[0])
            source.update({"bind_id": f"0x{flow:x}", "flow_out": True})
        events.append(parent)
        events += stage_events
    return events


def input_latency_summary(slots, unplaced, links):
    """generated -> presented per kind x target x presentation source (ms, p50/p95/p99/max) and each stage
    child's time, over the person's presented slots that changed the frame (keys always count, as Chrome's
    caused_frame_update keeps them). Automation, unpresented and no-update slots are counted, not folded in;
    `linked_to_key_flow` counts the key slots joined to their key.flow chain."""
    rows = collections.defaultdict(lambda: {"total": [], "stages": collections.defaultdict(list)})
    counts = collections.Counter(slots=len(slots), unplaced=unplaced, linked_to_key_flow=len(links))
    for slot in slots:
        if slot["entrypoint"] == "automation":
            counts["automation"] += 1
            continue
        if "presented" not in slot["stages"]:
            counts["unpresented"] += 1
            continue
        if not slot["update"] and slot["kind"] not in INPUT_KEY_KINDS:
            counts["no_update"] += 1
            continue
        start, end, children, out_of_order = input_stage_spans(slot)
        counts["stages_out_of_order"] += out_of_order
        row = rows[f"{slot['kind']} {slot['target']} {slot['source']}"]
        row["total"].append((end - start) / 1e6)
        for name, a, b in children:
            row["stages"][name].append((b - a) / 1e6)
    return {**counts, "rows": {key: {"total_ms": pct(row["total"]),
                                     "stage_ms": {name: pct(values) for name, values in row["stages"].items()}}
                               for key, row in sorted(rows.items())}}


# ---------------------------------------------------------------- Chromium's EventLatency joined to cmux's keys

# Chromium begins a key's EventLatency slice at the event's kGenerated time (cc/metrics/
# event_latency_tracing_recorder.cc: TRACE_EVENT_BEGIN at the kGenerated dispatch-stage timestamp), which on macOS is
# the NSEvent's own timestamp (ui/events/base_event_utils.cc, EventTimeStampFromSeconds) on base::TimeTicks, mach time:
# the trace clock. InputLatencyTracker keeps the same NSEvent timestamp as gen_ns, so a key cmux handed to a page and
# Chromium's EventLatency of that key start at the same instant.
CHROMIUM_LATENCY_NAME = "EventLatency"
CHROMIUM_KEY_TYPES = frozenset(("keypressed", "rawkeydown", "keydown"))  # EventType names, lower case, letters only
CHROMIUM_JOIN_US = 1.0  # Chromium's JSON gives ts in whole microseconds; gen_ns is nanoseconds


def event_latency_type(args):
    """An EventLatency's event type: the proto's `event_latency.event_type` as Chromium's JSON writes it, or an older
    build's `data.event_type` or `event` argument."""
    for path in (("event_latency", "event_type"), ("data", "event_type"), ("event_type",), ("event",)):
        value = args
        for key in path:
            value = value.get(key) if isinstance(value, dict) else None
        if value:
            return str(value)
    return ""


def chromium_key_latencies(chrome):
    """Chromium's EventLatency slices of key-downs, on the trace clock: [{ts_us, end_us, type, event}] by ts. A slice
    is a complete event (X), an async pair (b/e, matched by process, id and name; its stage children share the id
    under their own names) or a B/E pair on its thread; `event` is the begin, which carries the type."""
    spans, opened, stacks = [], {}, collections.defaultdict(list)
    for e in chrome:
        if e.get("name") != CHROMIUM_LATENCY_NAME or "ts" not in e:
            continue
        phase, ts = e.get("ph"), float(e["ts"])
        ident = e.get("id") or (e.get("id2") or {}).get("local") or (e.get("id2") or {}).get("global")
        if phase == "X":
            spans.append((e, ts, ts + float(e.get("dur") or 0)))
        elif phase == "b":
            opened[(e.get("pid"), str(ident))] = (e, ts)
        elif phase == "e" and (e.get("pid"), str(ident)) in opened:
            begin, start = opened.pop((e.get("pid"), str(ident)))
            spans.append((begin, start, ts))
        elif phase == "B":
            stacks[(e.get("pid"), e.get("tid"))].append((e, ts))
        elif phase == "E" and stacks[(e.get("pid"), e.get("tid"))]:
            begin, start = stacks[(e.get("pid"), e.get("tid"))].pop()
            spans.append((begin, start, ts))
    rows = []
    for begin, start, end in spans:
        kind = event_latency_type(begin.get("args") or {})
        if re.sub(r"[^a-z]", "", kind.lower()) in CHROMIUM_KEY_TYPES:
            rows.append({"ts_us": start, "end_us": end, "type": kind, "event": begin})
    rows.sort(key=lambda r: r["ts_us"])
    return rows


def chromium_key_links(app_events, slots, latencies):
    """Each Chromium key EventLatency joined to the cmux key it measures. One NSEvent key-down becomes a RawKeyDown
    and a Char WebInputEvent, both ui KEY_PRESSED (ui/events/blink/blink_event_util.cc WebEventTypeToEventType), so
    Chromium can write two key EventLatency slices with one kGenerated. The slices that share a kGenerated are one
    key event: it joins one cmux key, the closest pair first, and each of its slices links to that key:
    - exact: an input.latency keyPress slot whose gen_ns (the NSEvent timestamp) equals the kGenerated within
      CHROMIUM_JOIN_US; the slot's key.flow press (input_flow_links) names the flow;
    - else a key.flow press without a slot, by its dispatch hop minus its age, within INPUT_FLOW_MATCH_US.
    Each link: {flow, generated_us, exact, slot, latency, primary}. Per key, `primary` marks the slice that ends
    last: the frame that shows the character. A joined slice's begin gets a `cmux` argument (its flow and how it
    joined), which the trace shows on the Chromium slice."""
    hops = app_key_hops(app_events)
    presses = [{"flow": flow, "hops": [hop["app.key.dispatch"]]} for flow, hop in hops.items() if "app.key.dispatch" in hop]
    slot_flows = input_flow_links(slots, presses)
    keys, with_slot = [], set()
    for index, slot in enumerate(slots):
        if slot["kind"] == "keyPress":
            flow = slot_flows.get(index, (None, None))[0]
            with_slot.add(flow)
            keys.append((slot["generated_ns"] / 1000.0, True, index, flow))
    for press in presses:
        dispatch = press["hops"][0]
        try:
            at = dispatch["at_us"] - float(dispatch.get("age_us"))
        except (TypeError, ValueError):
            continue
        if press["flow"] not in with_slot:
            keys.append((at, False, None, press["flow"]))
    keys.sort(key=lambda k: k[0])
    times = [k[0] for k in keys]
    events = collections.defaultdict(list)  # kGenerated (us, as Chromium's JSON gives it) -> that key event's slices
    for latency in latencies:
        events[latency["ts_us"]].append(latency)
    pairs = []
    for ts in events:
        lo = bisect.bisect_left(times, ts - INPUT_FLOW_MATCH_US)
        hi = bisect.bisect_right(times, ts + INPUT_FLOW_MATCH_US)
        for key in range(lo, hi):
            at, exact, _, _ = keys[key]
            gap = abs(at - ts)
            if gap <= (CHROMIUM_JOIN_US if exact else INPUT_FLOW_MATCH_US):
                pairs.append((not exact, gap, ts, key))
    links, joined, used = [], set(), set()
    for _, _, ts, key in sorted(pairs):
        if ts in joined or key in used:
            continue
        joined.add(ts)
        used.add(key)
        at, exact, slot, flow = keys[key]
        slices = events[ts]
        last = max(slices, key=lambda latency: latency["end_us"])
        for latency in slices:
            latency["event"].setdefault("args", {})["cmux"] = {"flow": f"0x{flow:x}" if flow else None,
                                                               "join": "exact" if exact else "dispatch_minus_age",
                                                               "generated_us": round(at, 3)}
            links.append({"flow": flow, "generated_us": at, "exact": exact, "slot": slot, "latency": latency,
                          "primary": latency is last})
    links.sort(key=lambda link: (link["generated_us"], not link["primary"]))
    return links


def chromium_join_summary(latencies, links, slots):
    """How many of Chromium's key EventLatency slices joined a cmux key, per event type; how many keys joined and how
    (exact, with a flow); and per joined key, its primary slice's generated -> end (Chromium) next to cmux's own
    generated -> presented for that key (ms, p50/p95/p99/max)."""
    chromium_ms, cmux_ms, rows = [], [], []
    by_type = collections.defaultdict(lambda: {"latencies": 0, "linked": 0})
    for latency in latencies:
        by_type[latency["type"]]["latencies"] += 1
    for link in links:
        latency = link["latency"]
        by_type[latency["type"]]["linked"] += 1
        total = (latency["end_us"] - latency["ts_us"]) / 1000.0
        own = None
        if link["slot"] is not None:
            start, end, _, _ = input_stage_spans(slots[link["slot"]])
            own = (end - start) / 1e6
        if link["primary"]:
            chromium_ms.append(total)
            if own is not None:
                cmux_ms.append(own)
        rows.append({"flow": f"0x{link['flow']:x}" if link["flow"] else None, "exact": link["exact"],
                     "generated_us": round(link["generated_us"], 3), "type": latency["type"],
                     "primary": link["primary"], "chromium_total_ms": round(total, 3),
                     "cmux_total_ms": None if own is None else round(own, 3)})
    keys = [link for link in links if link["primary"]]
    return {"key_latencies": len(latencies), "linked": len(links), "keys": len(keys),
            "exact": sum(1 for link in keys if link["exact"]), "with_flow": sum(1 for link in keys if link["flow"]),
            "by_type": dict(by_type), "chromium_total_ms": pct(chromium_ms), "cmux_total_ms": pct(cmux_ms),
            "links": rows[:60]}


# ---------------------------------------------------------------- startup trace files (launch scenarios)

def read_trace_file(path):
    """(events, truncated) of a Chrome Trace Event JSON file: an object with `traceEvents` or a bare array. A file
    cut short (StartupTrace flushes 64 KiB chunks, so a crash or a kill leaves whole chunks and no closing bracket;
    Chromium's `--trace-startup` file likewise) gives every whole event before the cut."""
    try:
        with open(path, errors="replace") as f:
            text = f.read()
    except OSError:
        return [], False
    try:
        data = json.loads(text)
        events = data.get("traceEvents") if isinstance(data, dict) else data
        return [e for e in events or [] if isinstance(e, dict)], False
    except json.JSONDecodeError:
        pass
    key = text.find('"traceEvents"')
    start = text.find("[", key if key >= 0 else 0)
    if start < 0:
        return [], True
    decoder, events, at = json.JSONDecoder(), [], start + 1
    while True:
        while at < len(text) and text[at] in " \t\r\n,":
            at += 1
        if at >= len(text) or text[at] == "]":
            break
        try:
            value, at = decoder.raw_decode(text, at)
        except json.JSONDecodeError:
            break  # the event the cut went through
        if isinstance(value, dict):
            events.append(value)
    return events, True


def complete_slices(events):
    """B/E pairs as X slices (per pid and tid, innermost first), so every source nests the same way on its track.
    An E with no B is dropped; a B with no E (the file was cut) ends at the file's last time, marked unfinished."""
    timed = [e for e in events if isinstance(e.get("ts"), (int, float))]
    last = max((float(e["ts"]) + float(e.get("dur") or 0) for e in timed), default=0.0)
    out, begun = [], collections.defaultdict(list)
    for e in events:
        phase = e.get("ph")
        if phase in ("B", "E") and not isinstance(e.get("ts"), (int, float)):
            continue
        key = (e.get("pid"), e.get("tid"))
        if phase == "B":
            begun[key].append(e)
        elif phase == "E":
            if begun[key]:
                b = begun[key].pop()
                out.append({**b, "ph": "X", "dur": max(0.0, float(e["ts"]) - float(b["ts"])),
                            "args": {**(b.get("args") or {}), **(e.get("args") or {})}})
        else:
            out.append(e)
    for stack in begun.values():
        for b in stack:
            out.append({**b, "ph": "X", "dur": max(0.0, last - float(b["ts"])),
                        "args": {**(b.get("args") or {}), "unfinished": True}})
    return out


def startup_source(name):
    """Which process wrote a file of DIR/startup, from its name: the app's StartupTrace (STARTUP_APP_FILE), the
    daemon's startup marks, or Chromium's `--trace-startup` file (p08-startup 099)."""
    if name == STARTUP_APP_FILE:
        return "app"
    lower = name.lower()
    if "daemon" in lower or "tui" in lower:
        return "daemon"
    if "cef" in lower or "chrom" in lower:
        return "chromium"
    return os.path.splitext(name)[0]


def mark_name(event):
    """The launch mark an instant stands for: its `mark` argument, else its name."""
    return (event.get("args") or {}).get("mark") or event.get("name")


def launch_marks(signposts, app_pid):
    """{mark: {"ms": since process start, "at_us": CLOCK_UPTIME_RAW}} from the app's `launch.mark` signpost events
    (LaunchSignposts: `<name> ms=<ms>`), the first of each name."""
    marks = {}
    for event in signposts["events"]:
        if event["name"] != "launch.mark" or (app_pid is not None and event["pid"] not in (None, app_pid)):
            continue
        name, _, rest = (event.get("message") or "").partition(" ")
        try:
            ms = float(signposts_lib.fields(rest).get("ms"))
        except (TypeError, ValueError):
            continue
        if name:
            marks.setdefault(name, {"ms": ms, "at_us": event["at_us"]})
    return marks


def launch_process_start(marks):
    """The app's process start on CLOCK_UPTIME_RAW from its launch marks: each mark is emitted at or after the time it
    names (`at_us - ms`, a mark handed over from another thread later), so the earliest bound is the start."""
    return min((m["at_us"] - m["ms"] * 1000 for m in marks.values()), default=None)


def launch_mark_times(marks):
    """{mark: the CLOCK_UPTIME_RAW us the mark names}: process start + its ms, not the signpost's emission time (the
    app emits the daemon's `daemon.*` marks when an identify reply hands them over, well after the daemon reached
    them)."""
    start = launch_process_start(marks)
    return {} if start is None else {name: start + mark["ms"] * 1000 for name, mark in marks.items()}


def startup_clock(events, mark_at, window, prefix=""):
    """(offset_us, how, warning) for one startup file, by the trace's clock rule: every source is CLOCK_UPTIME_RAW in
    us (StartupTrace writes it; Chromium's TimeTicks is mach_absolute_time), checked rather than assumed. The launch
    marks a file shares with the signposts (instants of the same mark, against the time the mark names:
    launch_mark_times) give the offset: 0 within 1 ms (the same clock), else their median, as the Chromium trace's
    clock_sync check does. A daemon file's marks are the app's `daemon.<mark>` (`prefix`: the app maps the daemon's
    startup_marks so, p08-startup 093). A file with no shared mark stays put and is named when its events fall more
    than 1 s outside the window."""
    diffs = [mark_at[prefix + mark_name(e)] - float(e["ts"]) for e in events
             if e.get("ph") in INSTANT_PHASES and isinstance(e.get("ts"), (int, float))
             and prefix + str(mark_name(e)) in mark_at]
    if diffs:
        raw = statistics.median(diffs)
        if abs(raw) <= 1000:
            return 0.0, f"CLOCK_UPTIME_RAW ({len(diffs)} launch marks within {abs(raw):.0f} us of the signposts)", None
        return raw, f"launch marks ({len(diffs)} shared)", (f"its clock is {raw / 1000:.1f} ms off the signposts': moved "
                                                           f"by the median of {len(diffs)} shared launch marks")
    times = [float(e["ts"]) for e in events if e.get("ph") != "M" and isinstance(e.get("ts"), (int, float))]
    start, end = window
    if times and start is not None and end is not None and (min(times) < start - 1e6 or max(times) > end + 1e6):
        return 0.0, "CLOCK_UPTIME_RAW (assumed: no shared launch mark)", (
            f"its events run from {(min(times) - start) / 1e6:+.1f} s to {(max(times) - start) / 1e6:+.1f} s of the "
            f"window's start: not CLOCK_UPTIME_RAW us, or another launch's")
    return 0.0, "CLOCK_UPTIME_RAW (assumed: no shared launch mark)", None


MAIN_THREAD_NAMES = ("main", "main thread", "com.apple.main-thread")


def startup_main_tracks(events):
    """The (pid, tid) tracks of the app's main thread in its StartupTrace file: the thread it names main, the one its
    main-thread turns are on, else the one its launch milestones are on (the main thread's path)."""
    named = {(e.get("pid"), e.get("tid")) for e in events if e.get("ph") == "M" and e.get("name") == "thread_name"
             and str((e.get("args") or {}).get("name") or "").strip().lower() in MAIN_THREAD_NAMES}
    turns = {(e.get("pid"), e.get("tid")) for e in events if e.get("ph") == "X" and is_turn(e)}
    if named or turns:
        return named | turns
    return {(e.get("pid"), e.get("tid")) for e in events
            if e.get("ph") in INSTANT_PHASES and mark_name(e) in LAUNCH_MILESTONES}


def top_level(slices):
    """The X slices no other slice of their track contains (a child's time is its parent's already)."""
    out, ends = [], {}
    for e in sorted(slices, key=lambda e: (float(e["ts"]), -float(e.get("dur") or 0))):
        key, end = (e.get("pid"), e.get("tid")), float(e["ts"]) + float(e.get("dur") or 0)
        if key in ends and end <= ends[key]:
            continue
        ends[key] = end
        out.append(e)
    return out


def startup_files(out, signposts, app_pid, window):
    """Every startup trace in DIR/startup on the trace clock: (events, {file: info}, app), where `app` is the app's
    StartupTrace file alone: {"events": its events, "main": its main-thread tracks}. Process names come from the
    trace's roles; each thread is named `startup <source>: <thread>`."""
    folder = os.path.join(out, STARTUP_DIR)
    mark_at = launch_mark_times(launch_marks(signposts, app_pid))
    events, files, app = [], {}, {"events": [], "main": set()}
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if not name.endswith(".json"):
            continue
        source = startup_source(name)
        raw, truncated = read_trace_file(os.path.join(folder, name))
        raw = complete_slices(raw)
        offset, how, warning = startup_clock(raw, mark_at, window, "daemon." if source == "daemon" else "")
        named, kept = set(), []
        for e in raw:
            if e.get("ph") == "M" and e.get("name") in ("process_name", "process_sort_index", "process_labels"):
                continue  # the trace names every process by its cmux role
            e = dict(e)
            if e.get("pid") is None and source == "app":
                e["pid"] = app_pid
            if e.get("pid") is None:
                continue
            e.setdefault("tid", 0)
            if e.get("ph") == "M":
                if e.get("name") == "thread_name":
                    e["args"] = {"name": f"startup {source}: {(e.get('args') or {}).get('name')}"}
                    named.add((e["pid"], e["tid"]))
            elif isinstance(e.get("ts"), (int, float)):
                e["ts"] = float(e["ts"]) + offset
            else:
                continue
            kept.append(e)
        for pid, tid in sorted({(e["pid"], e["tid"]) for e in kept} - named, key=str):
            kept.append({"ph": "M", "pid": pid, "tid": tid, "name": "thread_name",
                         "args": {"name": f"startup {source}"}})
        events += kept
        if source == "app":
            # The tracks are read before the threads are renamed `startup app: <name>` (the same pid and tid).
            app = {"events": app["events"] + kept, "main": app["main"] | startup_main_tracks(
                [dict(e, pid=app_pid if e.get("pid") is None else e.get("pid"), tid=e.get("tid", 0)) for e in raw])}
        files[name] = {"source": source, "events": len(kept), "truncated": truncated, "clock": how,
                       "offset_us": round(offset, 1), "warning": warning,
                       "pids": sorted({e["pid"] for e in kept if isinstance(e["pid"], int)})}
    return events, files, app


# ---------------------------------------------------------------- launch summary

def is_turn(event):
    """A StartupTrace main-thread turn (p08-startup 004 records turns over 1 ms from the watchdog's sink)."""
    return event.get("cat") in ("turn", "main_turn", "main.turn") or str(event.get("name") or "").startswith("main.turn")


def launch_summary(meta, signposts, samples, offset_us, app_pid, threads_by_pid, stalls, app_trace, hangs_dropped=None):
    """The launch section of the summary: milestones, the critical path between them, the top main-thread frames
    before the first frame, and every main-thread turn of LAUNCH_TURN_MS or more. `app_trace` is the app's
    StartupTrace file (startup_files): its tasks count only on its main-thread tracks, never a lane job's background
    thread or the Chromium `--trace-startup` file's threads of the same process."""
    marks = launch_marks(signposts, app_pid)
    app_events = [e for e in app_trace["events"] if e.get("pid") == app_pid and e.get("ph") != "M"]
    instants = {}
    for e in app_events:
        if e.get("ph") in INSTANT_PHASES:
            instants.setdefault(mark_name(e), float(e["ts"]))
    # Process start on the trace clock: StartupTrace's own `process_start` (kinfo p_starttime), else the earliest
    # signpost minus its ms (a mark is emitted at or after the time it names, so the earliest bound is the best).
    if "process_start" in instants:
        process_start, process_start_from = instants["process_start"], "startup trace"
    elif marks:
        process_start, process_start_from = launch_process_start(marks), "launch marks"
    else:
        process_start, process_start_from = None, "none"
    milestones = {"process_start": {"ms": 0.0, "from": process_start_from}}
    for name, mark in marks.items():
        milestones.setdefault(name, {"ms": mark["ms"], "from": "signposts"})
    if process_start is not None:
        for name, ts in instants.items():
            milestones.setdefault(name, {"ms": (ts - process_start) / 1000, "from": "startup trace"})
    timings = meta.get("timings") if isinstance(meta.get("timings"), dict) else {}
    for name, ms in (timings.get("launch_ms_since_process_start") or {}).items():
        if isinstance(ms, (int, float)):
            milestones.setdefault(name, {"ms": float(ms), "from": "debug.timings"})
    at = (lambda ms: process_start + ms * 1000) if process_start is not None else (lambda ms: None)
    window_end = meta.get("window_end_us")
    main_tid = next((t for t, n in (threads_by_pid.get(app_pid) or {}).items() if n.startswith("Main Thread")), None)
    main = sorted((t / 1000.0 + offset_us, w / 1000.0, frames) for t, w, thread, frames in samples
                  if thread.get("pid") == app_pid and thread.get("tid") == main_tid)
    main_times = [r[0] for r in main]

    def main_samples(a, b):
        if a is None or b is None:
            return []
        return main[bisect.bisect_left(main_times, a):bisect.bisect_right(main_times, b)]

    tasks = top_level([e for e in app_events if e.get("ph") == "X" and not is_turn(e)
                       and (e.get("pid"), e.get("tid")) in app_trace["main"]])

    def tasks_during(a, b, limit=3):
        overlap = collections.Counter()
        for e in tasks:
            lo, hi = max(a, float(e["ts"])), min(b, float(e["ts"]) + float(e.get("dur") or 0))
            if hi > lo:
                overlap[str(e.get("name"))] += hi - lo
        return [{"task": k[:120], "ms": round(v / 1000, 1)} for k, v in overlap.most_common(limit)]

    def frames_of(rows, limit):
        """[{frame, ms inclusive, self_ms}] of the interesting frames of sampled stacks (leaf first; weights in us)."""
        inclusive, own = collections.Counter(), collections.Counter()
        for _, weight, frames in rows:
            for frame in set(frames):
                if interesting(frame):
                    inclusive[frame] += weight
            leaf = next((f for f in frames if interesting(f)), None)
            if leaf:
                own[leaf] += weight
        ranked = sorted(inclusive.items(), key=lambda kv: (-kv[1], kv[0]))[:limit]  # ties by name: a stable summary
        return [{"frame": f[:180], "ms": round(us / 1000, 1), "self_ms": round(own.get(f, 0.0) / 1000, 1)}
                for f, us in ranked]

    # The critical path: the launch milestones the run has, in the order they happened, each step with what filled it.
    path_marks = sorted(((n, m["ms"]) for n, m in milestones.items() if n in LAUNCH_MILESTONES), key=lambda x: x[1])
    critical = []
    for (a, a_ms), (b, b_ms) in zip(path_marks, path_marks[1:]):
        start, end = at(a_ms), at(b_ms)
        inside = main_samples(start, end)
        critical.append({"from": a, "to": b, "at_ms": round(a_ms, 1), "ms": round(b_ms - a_ms, 1),
                         "main_cpu_ms": round(sum(w for _, w, _ in inside) / 1000, 1), "frames": frames_of(inside, 3),
                         "tasks": tasks_during(start, end) if start is not None else []})
    if critical:
        max(critical, key=lambda step: step["ms"])["longest"] = True

    def step_at(ms):
        return next((f"{s['from']} -> {s['to']}" for s in critical if s["at_ms"] <= ms < s["at_ms"] + s["ms"]), None)

    first_frame = milestones.get(FIRST_FRAME_MARK)
    until = at(first_frame["ms"]) if first_frame else window_end
    top = frames_of(main_samples(process_start, until), LAUNCH_TOP_FRAMES)
    # Main-thread turns of LAUNCH_TURN_MS or more: the watchdog's (its threshold is LAUNCH_TURN_MS in a launch),
    # StartupTrace's that no watchdog record covers, else busy runs of the main thread's samples.
    begin = process_start if process_start is not None else meta.get("window_start_us")
    turns = []
    for s in stalls:
        if s["kind"] in ("stall", "over_budget") and s["ms"] >= LAUNCH_TURN_MS and begin is not None and \
                begin <= s["start_us"] <= (window_end or float("inf")):
            frames = [f for f in s["frames"] if interesting(re.sub(r"^\S+ ", "", str(f)))][:6]
            turns.append({"start_us": s["start_us"], "ms": s["ms"], "cpu_ms": s["cpu_ms"], "source": "watchdog",
                          "frames": frames})
    for e in app_events:
        if e.get("ph") == "X" and is_turn(e) and float(e.get("dur") or 0) >= LAUNCH_TURN_MS * 1000:
            start = float(e["ts"])
            if not any(t["start_us"] - 1000 <= start <= t["start_us"] + t["ms"] * 1000 for t in turns):
                turns.append({"start_us": start, "ms": float(e["dur"]) / 1000, "cpu_ms": None, "source": "startup trace",
                              "frames": []})
    if not turns:
        run = []
        for row in main + [(float("inf"), 0, ())]:
            if run and row[0] - (run[-1][0] + run[-1][1]) > 1.5 * max(run[-1][1], 1):
                a, b = run[0][0], run[-1][0] + run[-1][1]
                if b - a >= LAUNCH_TURN_MS * 1000 and (begin is None or a >= begin):
                    turns.append({"start_us": a, "ms": (b - a) / 1000, "cpu_ms": (b - a) / 1000, "source": "samples",
                                  "frames": []})
                run = []
            run.append(row)
    rows = []
    for turn in sorted(turns, key=lambda t: t["start_us"]):
        end = turn["start_us"] + turn["ms"] * 1000
        at_ms = (turn["start_us"] - process_start) / 1000 if process_start is not None else None
        sampled = [x["frame"] for x in frames_of(main_samples(turn["start_us"], end), 4)]
        rows.append({"at_ms": None if at_ms is None else round(at_ms, 1), "ms": round(turn["ms"], 1),
                     "cpu_ms": None if turn["cpu_ms"] is None else round(turn["cpu_ms"], 1), "source": turn["source"],
                     "step": None if at_ms is None else step_at(at_ms), "frames": turn["frames"] or sampled,
                     "tasks": tasks_during(turn["start_us"], end, 2)})
    return {
        "temperature": (meta.get("launch") or {}).get("temperature"), "process_start_from": process_start_from,
        "milestones": [{"name": n, "ms": round(m["ms"], 1), "from": m["from"]}
                       for n, m in sorted(milestones.items(), key=lambda kv: kv[1]["ms"])],
        "first_frame_ms": round(first_frame["ms"], 1) if first_frame else None,
        "startup_complete_ms": round(milestones[STARTUP_COMPLETE_MARK]["ms"], 1)
        if STARTUP_COMPLETE_MARK in milestones else None,
        "critical_path": critical, "main_samples": len(main),
        "top_main_frames": top, "top_main_frames_until": FIRST_FRAME_MARK if first_frame else "the window's end",
        "turns": rows, "turn_ms": LAUNCH_TURN_MS, "run": meta.get("launch"), "hangs_dropped": hangs_dropped,
    }


def launch_text(launch, files):
    """The launch section of SUMMARY.txt."""
    lines = [f"Launch ({launch.get('temperature')}): first frame {launch.get('first_frame_ms')} ms, "
             f"{STARTUP_COMPLETE_MARK} {launch.get('startup_complete_ms')} ms since process start (process start from "
             f"{launch.get('process_start_from')}); {launch.get('main_samples')} main-thread samples"]
    run = launch.get("run") or {}
    if run.get("temperature") == "cold":
        lines.append(f"  cold: {run.get('stopped')} process(es) of the bundle stopped ({run.get('killed')} after SIGKILL), "
                     f"file cache purged {run.get('purged')}")
    lines.append("  milestones (ms since process start): " +
                 ", ".join(f"{m['name']} {m['ms']}" for m in launch.get("milestones") or []))
    lines.append("Critical path (main thread, milestone to milestone; * the longest step):")
    if not launch.get("critical_path"):
        lines.append("  none: fewer than two launch milestones were recorded")
    for step in launch.get("critical_path") or []:
        what = "; ".join(f"{f['frame'][:80]} {f['ms']} ms" for f in step["frames"])
        tasks = "; ".join(f"{t['task'][:60]} {t['ms']} ms" for t in step["tasks"])
        lines.append(f"  {'*' if step.get('longest') else ' '} {step['from']} -> {step['to']}: {step['ms']} ms at "
                     f"+{step['at_ms']} ms, main cpu {step['main_cpu_ms']} ms" + (f"; {what}" if what else "")
                     + (f"; tasks: {tasks}" if tasks else ""))
    lines.append(f"Top {LAUNCH_TOP_FRAMES} main-thread frames before {launch.get('top_main_frames_until')} "
                 f"(ms inclusive / self):")
    for row in launch.get("top_main_frames") or []:
        lines.append(f"  {row['ms']:8} / {row['self_ms']:<8} {row['frame'][:120]}")
    turns = launch.get("turns") or []
    dropped = launch.get("hangs_dropped")
    lines.append(f"Main-thread turns of {launch.get('turn_ms')} ms or more ({len(turns)}; watchdog records dropped "
                 f"{dropped}):")
    if dropped:
        lines.append(f"  WARNING: the watchdog ring dropped its {dropped} oldest record(s) before the drain: the "
                     "earliest turns of the launch are missing from this list")
    for turn in turns:
        lines.append(f"  +{turn['at_ms']} ms: {turn['ms']} ms" + (f", cpu {turn['cpu_ms']} ms" if turn["cpu_ms"] is not None else "")
                     + f" [{turn['source']}]" + (f" in {turn['step']}" if turn["step"] else "")
                     + (": " + " < ".join(str(f)[:80] for f in turn["frames"][:4]) if turn["frames"] else "")
                     + ("; tasks: " + "; ".join(t["task"][:60] for t in turn["tasks"]) if turn["tasks"] else ""))
    for name, info in (files or {}).items():
        lines.append(f"  startup file {name}: {info['source']}, {info['events']} events"
                     + (", TRUNCATED (whole events before the cut kept)" if info["truncated"] else "")
                     + f", clock {info['clock']}" + (f"; WARNING: {info['warning']}" if info.get("warning") else ""))
    if not files:
        lines.append(f"  no startup trace files in {STARTUP_DIR}/ (an app before StartupTrace, or CMUX_TRACE_STARTUP "
                     f"not read)")
    return lines


def build(out):
    """Merges every raw file in `out` into trace.json.gz and returns the summary (also summary.json, SUMMARY.txt)."""
    meta = read_json(os.path.join(out, "meta.json"), {}) or {}
    processes = read_json(os.path.join(out, "processes.json"), {}) or {}
    known = {}
    for snapshot in ("start", "end"):
        for pid, info in (processes.get(snapshot) or {}).items():
            known[int(pid)] = info
    signposts = read_signposts(os.path.join(out, "signposts.ndjson"))
    toc = parse_toc(os.path.join(out, "xctrace-toc.xml"))
    unreadable = {}

    def table(schema, reader, *args):
        """One exported table's rows, or None without the file. A file that does not parse (an export of a
        trace.py before the part files, a disk that filled) is skipped and named in the summary."""
        path = os.path.join(out, f"xctrace-{schema}.xml")
        if not os.path.exists(path):
            return None
        try:
            return reader(path, *args)
        except ET.ParseError as error:
            unreadable[schema] = f"{error} (delete {os.path.basename(path)} and run `trace.py export` again)"
            note(f"xctrace {schema} table does not parse, skipped: {error}")
            return None

    signpost_stats = {}
    xc_signposts = table("os-signpost", xctrace_signposts, signpost_stats)
    offset_us, offset_how, clock_warning = xctrace_offset_us(xc_signposts, toc, signposts["intervals"], meta,
                                                             signpost_stats)
    samples = table("time-profile", time_profile_samples)
    # The recording's tables that trace.py reads but this directory has no export of: a flame chart or a syscall
    # track that is empty because its table is missing says so (trace.py exports no other sample table).
    missing = missing_tables(out) if toc["schemas"] else []
    if toc["schemas"] and "time-profile" not in toc["schemas"]:
        missing.append(f"time-profile (not in the recording; its tables: {', '.join(toc['schemas'][:12])})")
    samples = samples or []
    states = table("syscall", syscall_waits) or []
    # Processes and threads the trace names.
    names, threads_by_pid = {}, collections.defaultdict(dict)
    for _, _, thread, _ in samples:
        if thread.get("pid") is not None:
            names.setdefault(thread["pid"], thread.get("process") or "")
            threads_by_pid[thread["pid"]][thread["tid"]] = thread.get("name") or ""
    roles = {}
    for pid, name in names.items():
        roles[pid] = (known.get(pid) or {}).get("role") or role_from_name(name)
    for pid, info in known.items():
        roles.setdefault(pid, info["role"])
    app_pid, app_pid_from = find_app_pid(meta, known, roles, signposts["intervals"])
    if app_pid is not None:
        roles[app_pid] = "app"
    daemon_pid = next((p for p, i in sorted(known.items()) if i["role"] == "daemon" and " server" in i["command"]), None) \
        or next((p for p, r in roles.items() if r == "daemon"), None) or 1
    flame_roles = set(ROLE_ORDER) - {"other"}
    keep = lambda thread: roles.get(thread.get("pid"), "other") in flame_roles
    chrome, chrome_info = chromium_events(out, threads_by_pid)
    # The launch scenarios' startup traces (the app's StartupTrace, the daemon's, Chromium's), on the trace clock.
    startup, startup_info, app_trace = startup_files(out, signposts, app_pid,
                                                     (meta.get("window_start_us"), meta.get("window_end_us")))
    os_tids = {thread.get("tid") for _, _, thread, _ in samples} | {thread.get("tid") for _, _, thread, _, _ in states} \
        | {e.get("tid") for e in chrome} | {e.get("tid") for e in startup}
    os_tids = {t for t in os_tids if isinstance(t, int)}
    tracks = SyntheticTracks(os_tids)
    events = flame_events(samples, offset_us, keep)
    # The Release trace rings of every role (`record --release`, or rings put in OUT), on their own tracks.
    rings, rings_unreadable = read_rings(out)
    lane_names = {}
    ring_trace, ring_unpaired = ring_events(rings, tracks, lane_names)
    events += ring_trace
    for ring in rings:
        roles.setdefault(ring["info"]["pid"], ring["info"]["role"])
    # Key-press flows: the app's key.flow hops and the flow records of the daemon, hosts and holder; the daemon
    # requests' flow records (check-clock reads the same through load_flow_inputs).
    flow_signposts, key_records, request_records, flow_dropped, renders = load_flow_inputs(out, signposts, rings)
    key_flows = assemble_flows(flow_signposts, key_records, renders)
    flow_gaps = flow_warnings(flow_signposts, key_records, key_flows)
    # Input latency: one slice per closed slot, generated -> presented; a key's slice opens its key.flow chain's arrow.
    input_slots, input_unplaced = input_latency_slots(signposts)
    input_links = input_flow_links(input_slots, key_flows)
    # Chromium's key EventLatency slices joined to cmux's keys (their begins carry the join before they are placed).
    chromium_latencies = chromium_key_latencies(chrome)
    chromium_links = chromium_key_links(flow_signposts, input_slots, chromium_latencies)
    # Signposts, on per-category lanes of their process.
    lanes = collections.defaultdict(Lanes)
    for interval in signposts["intervals"]:
        pid = interval["pid"] or app_pid
        category = interval["category"] or "signpost"
        lane = lanes[(pid, category)].place(interval["start_us"], interval["end_us"])
        tid = tracks.tid(pid, ("signposts", category, lane))
        lane_names[(pid, tid)] = f"signposts {category}" + (f" {lane + 1}" if lane else "")
        detail = interval["fields"].get("id") or interval["fields"].get("kind") or ""
        events.append({"ph": "X", "pid": pid, "tid": tid, "ts": interval["start_us"], "dur": interval["end_us"] - interval["start_us"],
                       "name": f"{interval['name']} {detail}".strip(), "cat": f"signpost.{category}",
                       "args": {"begin": interval["message"], "end": interval["end_message"], "thread": interval["tid"]}})
    for event in signposts["events"]:
        pid = event["pid"] or app_pid
        tid = tracks.tid(pid, ("signposts", event["category"] or "signpost", "events"))
        lane_names.setdefault((pid, tid), f"signposts {event['category']}")
        events.append({"ph": "i", "s": "t", "pid": pid, "tid": tid, "ts": event["at_us"], "name": event["name"],
                       "cat": f"signpost.{event['category']}", "args": {"message": event["message"]}})
    # Watchdog stalls.
    hangs = read_json(os.path.join(out, "hangs.json"), {}) or {}
    stall_records = []
    stall_lanes = Lanes()
    for record in hangs.get("records") or []:
        start = float(record.get("start_uptime_ns") or 0) / 1000.0
        duration = float(record.get("duration_ms") or 0) * 1000.0
        if not start:
            continue
        lane = stall_lanes.place(start, start + duration)
        tid = tracks.tid(app_pid, ("watchdog stalls", lane))
        lane_names[(app_pid, tid)] = "watchdog stalls"
        kind = record.get("kind") or "stall"
        events.append({"ph": "X", "pid": app_pid, "tid": tid, "ts": start, "dur": duration, "cat": "watchdog",
                       "name": f"{kind} {duration / 1000:.0f} ms (cpu {float(record.get('cpu_ms') or 0):.0f} ms)",
                       "args": {"frames": (record.get("frames") or [])[:40], "cpu_ms": record.get("cpu_ms")}})
        stall_records.append({"start_us": start, "end_us": start + duration, "ms": duration / 1000.0, "kind": kind,
                              "cpu_ms": float(record.get("cpu_ms") or 0), "frames": record.get("frames") or []})
    # System Trace: system calls of 1 ms or more in the bundle's threads (off CPU: the stack says on what), on a
    # track beside their thread. The run loop's and the workqueue's idle waits are not waits for work.
    blocked = []
    for start, duration, thread, call, stack in states:
        if not keep(thread):
            continue
        reason = wait_class(list(stack)) if stack else "unknown"
        if reason == "idle":
            continue
        ts = start / 1000.0 + offset_us
        state_tid = tracks.tid(thread["pid"], ("syscalls", thread["tid"]))
        lane_names[(thread["pid"], state_tid)] = f"{thread.get('name') or thread['tid']} syscalls"
        events.append({"ph": "X", "pid": thread["pid"], "tid": state_tid, "ts": ts, "dur": duration / 1000.0,
                       "cat": "syscall", "name": f"{call}: {reason}", "args": {"stack": list(stack)[:30]}})
        blocked.append({"pid": thread["pid"], "tid": thread["tid"], "thread": thread.get("name"), "start_us": ts,
                        "end_us": ts + duration / 1000.0, "call": call, "class": reason, "stack": list(stack)[:30]})
    # Daemon spans, Chromium, the driver.
    span_events, span_info, span_rows = daemon_span_events(out, daemon_pid, tracks)
    lane_names.update(span_info.pop("track_names"))
    events += span_events
    events += chromium_on_own_tracks(chrome, samples, tracks)
    events += chromium_on_own_tracks(startup, samples, tracks, kind="startup")
    for info in startup_info.values():  # a process only a startup file names (no ps snapshot, no samples)
        for pid in info["pids"]:
            roles.setdefault(pid, {"app": "app", "daemon": "daemon"}.get(info["source"], "bundle-other"))
    driver = read_json(os.path.join(out, "driver.json"), []) or []
    driver_lanes = collections.defaultdict(Lanes)
    for item in driver:
        start, end = item.get("start_us"), item.get("end_us") or item.get("start_us")
        if start is None:
            continue
        lane = driver_lanes[item["kind"]].place(start, end)
        tid = tracks.tid(DRIVER_PID, ("driver", item["kind"], lane))
        lane_names[(DRIVER_PID, tid)] = f"driver {item['kind']}" + (f" {lane + 1}" if lane else "")
        events.append({"ph": "X", "pid": DRIVER_PID, "tid": tid, "ts": start, "dur": max(1.0, end - start),
                       "cat": "driver", "name": item["name"], "args": item.get("args") or {}})
    events += input_latency_events(input_slots, app_pid, tracks, lane_names, input_links)
    events += flow_events(key_flows, tracks, lane_names, frozenset(flow for flow, _ in input_links.values()))
    for pid in {r["pid"] for r in key_records + request_records if r.get("pid")}:
        roles.setdefault(pid, (known.get(pid) or {}).get("role") or "bundle-other")
    # Metadata: names and order.
    meta_events = [{"ph": "M", "pid": DRIVER_PID, "name": "process_name", "args": {"name": "scenario driver"}},
                   {"ph": "M", "pid": DRIVER_PID, "name": "process_sort_index", "args": {"sort_index": -1}}]
    pids = {e.get("pid") for e in events if e.get("pid") is not None} - {DRIVER_PID}
    for pid in pids:
        role = roles.get(pid, "other")
        name = names.get(pid) or (known.get(pid) or {}).get("command", "").split("/")[-1][:60] or str(pid)
        meta_events.append({"ph": "M", "pid": pid, "name": "process_name", "args": {"name": f"{role}: {name}"}})
        meta_events.append({"ph": "M", "pid": pid, "name": "process_sort_index",
                            "args": {"sort_index": ROLE_ORDER.index(role) if role in ROLE_ORDER else len(ROLE_ORDER)}})
    for pid, threads in threads_by_pid.items():
        for tid, name in threads.items():
            meta_events.append({"ph": "M", "pid": pid, "tid": tid, "name": "thread_name", "args": {"name": name or str(tid)}})
            if name.startswith("Main Thread"):
                meta_events.append({"ph": "M", "pid": pid, "tid": tid, "name": "thread_sort_index", "args": {"sort_index": -10}})
    for (pid, tid), name in lane_names.items():
        meta_events.append({"ph": "M", "pid": pid, "tid": tid, "name": "thread_name", "args": {"name": name}})
        meta_events.append({"ph": "M", "pid": pid, "tid": tid, "name": "thread_sort_index", "args": {"sort_index": -20}})
    trace_path = os.path.join(out, "trace.json.gz")
    with gzip.open(trace_path, "wt") as f:
        f.write('{"displayTimeUnit":"ms","traceEvents":[\n')
        first = True
        for event in meta_events + events:
            if not first:
                f.write(",\n")
            f.write(json.dumps(event, separators=(",", ":"), default=str))
            first = False
        f.write("\n],\"metadata\":" + json.dumps({k: meta.get(k) for k in ("host", "macos", "tag", "scenario", "seconds",
                                                                            "recorder")}) + "}\n")
    summary = summarize(meta, roles, app_pid, samples, offset_us, signposts, stall_records, blocked, span_rows, chrome,
                        chrome_info, threads_by_pid)
    summary["key_flows"] = flow_summary(key_flows, flow_dropped, flow_gaps)
    summary.update(flow_percentiles(key_flows))
    summary.update(clock_report(key_flows, request_records))
    summary.update(request_flow_summary(request_records))
    summary["input_latency"] = input_latency_summary(input_slots, input_unplaced, input_links)
    summary["chromium_event_latency"] = chromium_join_summary(chromium_latencies, chromium_links, input_slots)
    summary["rings"] = {"files": [ring["info"] for ring in rings], "unreadable": rings_unreadable,
                        "unpaired": ring_unpaired}
    if meta.get("scenario") in LAUNCH_SCENARIOS:
        summary["launch"] = launch_summary(meta, signposts, samples, offset_us, app_pid, threads_by_pid, stall_records,
                                           app_trace, hangs.get("dropped"))
    summary["sources"] = {
        "trace": trace_path, "trace_bytes": os.path.getsize(trace_path), "events": len(events),
        "samples": len(samples), "sampled_processes": len(names), "xctrace_clock": offset_how,
        "app_pid": app_pid, "app_pid_from": app_pid_from, "missing_tables": missing,
        "os_tids_over_uint32": sorted(t for t in os_tids if not 0 <= t < 1 << 32)[:8],
        "xctrace_clock_warning": clock_warning, "unreadable_tables": unreadable, "signpost_clock": signposts["clock"],
        "signpost_intervals": len(signposts["intervals"]), "signposts_lost": signposts["lost"],
        "system_trace_states": len(states), "hang_records": len(stall_records), "hangs_dropped": hangs.get("dropped"),
        "daemon_span_lines": span_info["lines"], "chromium": chrome_info, "processes": dict(collections.Counter(roles.values())),
        "sample_files": sorted(p for p in os.listdir(out) if p.startswith("sample-")),
        "startup_files": startup_info,
    }
    write_json(os.path.join(out, "summary.json"), summary)
    with open(os.path.join(out, "SUMMARY.txt"), "w") as f:
        f.write(summary_text(summary) + "\n")
    return summary


# ---------------------------------------------------------------- summary

IDLE_MARKERS = ("__CFRunLoopServiceMachPort", "__workq_kernreturn", "start_wqthread", "_dispatch_mgr_invoke",
                "-[NSCondition wait]", "kevent_id")
WAIT_CLASSES = [  # (class, markers in any frame of the stack), first match wins
    ("lock", ("psynch_mutexwait", "__ulock_wait", "os_unfair_lock_lock_slow", "_pthread_mutex_firstfit_lock_slow",
              "_dispatch_sync_f_slow", "__DISPATCH_WAIT_FOR_QUEUE__", "_dispatch_sema", "semaphore_wait",
              "__psynch_cvwait", "_pthread_cond_wait")),
    ("daemon", ("DaemonClient", "DaemonConnection", "CmuxNextDaemon", "cmux_tui", "TUIClient")),
    ("cef", ("CefDoMessageLoopWork", "cmux_shim_", "CEFShim", "Chromium Embedded Framework", "libcef", "CEFRuntime",
             "CEFHostView", "content::", "base::MessagePump")),
    ("windowserver", ("CA::Transaction::commit", "CA::Context::commit", "SLSTransaction", "CGSSession", "_CGS",
                      "SkyLight", "CA::Render::")),
    ("xpc", ("xpc_connection_send_message_with_reply_sync", "NSXPCConnection", "_xpc_")),
    ("io", ("fsync", "__open", "__pread", "__write_nocancel", "__read_nocancel", "getattrlist", "__stat", "fcntl")),
    ("ghostty", ("ghostty_", "GhosttyKit", "Ghostty")),
]
GENERIC = ("start", "main", "NSApplicationMain", "-[NSApplication run]", "_DPSNextEvent", "CFRunLoopRun", "__CFRunLoop",
           "_CFRunLoopRun", "-[NSApplication(NSEvent) _nextEventMatchingEventMask", "_BlockUntilNextEventMatchingListInMode",
           "ReceiveNextEventCommon", "RunCurrentEventLoopInMode", "_dispatch_main_queue", "_dispatch_", "?", "0x",
           "_DPSBlockUntilNextEventMatchingListInMode", "-[NSApplication(NSEventRouting)", "CmuxNextApp.main()", "dyld",
           "thread_start", "_pthread_start", "__CFRUNLOOP", "static CmuxNextApp", "CFRunLoopRunSpecific")


def wait_class(frames):
    """What a stack (leaf first) waits on. `idle` when one of its 8 leaf-most frames is a run loop or workqueue park
    (a thread with nothing to do, not a wait inside work)."""
    if any(any(marker in str(f) for marker in IDLE_MARKERS) for f in list(frames)[:8]):
        return "idle"
    joined = "\n".join(str(f) for f in frames)
    for name, markers in WAIT_CLASSES:
        if any(marker in joined for marker in markers):
            return name
    return "other"


def interesting(frame):
    frame = str(frame)
    return not frame.startswith(GENERIC) and not re.match(r"^(\S+ )?\+0x|^[0-9a-f]+$", frame)


def top_frames(stacks, limit=6):
    """The most common non-generic frames over `stacks` (each leaf first): inclusive counts, deepest first."""
    counts = collections.Counter()
    for frames in stacks:
        for frame in set(frames):
            if interesting(frame):
                counts[frame] += 1
    return counts.most_common(limit)


def summarize(meta, roles, app_pid, samples, offset_us, signposts, stalls, blocked, span_rows, chrome, chrome_info,
              threads_by_pid):
    start = meta.get("window_start_us") or 0
    main_tid = next((t for t, n in (threads_by_pid.get(app_pid) or {}).items() if n.startswith("Main Thread")), None)
    main = [(t / 1000.0 + offset_us, w / 1000.0, frames) for t, w, thread, frames in samples
            if thread.get("pid") == app_pid and thread.get("tid") == main_tid]
    main.sort(key=lambda r: r[0])
    main_times = [r[0] for r in main]

    def main_samples(a, b):
        lo, hi = bisect.bisect_left(main_times, a), bisect.bisect_right(main_times, b)
        return main[lo:hi]

    browser_main = []
    os_thread = chrome_info.get("os_thread") or {}
    for e in chrome:
        if e.get("pid") == app_pid and e.get("ph") == "X" and e.get("dur") and \
                os_thread.get(f"{e.get('pid')}:{e.get('tid')}") == main_tid:
            browser_main.append(e)

    def chromium_during(a, b, limit=4):
        overlap = collections.Counter()
        for e in browser_main:
            lo, hi = max(a, e["ts"]), min(b, e["ts"] + e["dur"])
            if hi > lo:
                src = (e.get("args") or {}).get("src_func") or (e.get("args") or {}).get("src_file") or ""
                overlap[f"{e.get('name')}" + (f" ({src})" if src else "")] += hi - lo
        return [{"event": k[:160], "ms": round(v / 1000, 1)} for k, v in overlap.most_common(limit)]

    actions = [i for i in signposts["intervals"] if i["pid"] == app_pid and i["name"] in ("action.perform", "action.commit")]
    spans = [i for i in signposts["intervals"] if i["pid"] == app_pid and i["name"] in STALL_DURING_SPANS]

    def actions_during(a, b):
        found = []
        for i in spans:
            if i["start_us"] < b and i["end_us"] > a:
                detail = i["fields"].get("id") or i["fields"].get("kind") or ""
                label = " ".join(part for part in (i["name"], detail, "missed" if i["missed"] else "") if part)
                found.append(f"{label} ({i['ms']:.1f} ms)")
        return sorted(set(found))[:6]

    # Main-thread stalls: the watchdog's records, else busy runs of the main thread's samples.
    candidates = []
    for s in stalls:
        if s["kind"] != "stall":
            continue
        candidates.append({"source": "watchdog", **s})
    if not candidates:
        run = []
        for row in main + [(float("inf"), 0, ())]:
            if run and row[0] - (run[-1][0] + run[-1][1]) > 1.5 * max(run[-1][1], 1):
                a, b = run[0][0], run[-1][0] + run[-1][1]
                if b - a >= 8000:
                    candidates.append({"source": "samples", "start_us": a, "end_us": b, "ms": (b - a) / 1000,
                                       "kind": "busy", "cpu_ms": (b - a) / 1000, "frames": []})
                run = []
            run.append(row)
    candidates.sort(key=lambda s: -s["ms"])
    top = []
    for s in candidates[:5]:
        inside = main_samples(s["start_us"], s["end_us"])
        on_cpu = sum(w for _, w, _ in inside) / 1000.0
        cpu = s["cpu_ms"] if s["source"] == "watchdog" else on_cpu
        waiting = cpu < 0.5 * s["ms"]
        frames = [f for f in s["frames"] if interesting(re.sub(r"^\S+ ", "", str(f)))][:12]
        top.append({"at_s": round((s["start_us"] - start) / 1e6, 3), "ms": round(s["ms"], 1), "cpu_ms": round(cpu, 1),
                    "source": s["source"], "waiting": waiting,
                    "wait_class": wait_class(s["frames"] or [f for _, _, st in inside for f in st]) if waiting else None,
                    "watchdog_stack": frames,
                    "sampled_frames": [{"frame": f[:180], "samples": n} for f, n in top_frames([st for _, _, st in inside])],
                    "sampled_leaf": [{"frame": f[:180], "samples": n} for f, n in collections.Counter(
                        next((x for x in st if interesting(x)), "?") for _, _, st in inside).most_common(3)],
                    "actions": actions_during(s["start_us"], s["end_us"]),
                    "chromium_main_thread": chromium_during(s["start_us"], s["end_us"])})
    # Input to commit per action: perf-signposts.py's rows (one parser for the same signposts).
    app_intervals = [i for i in signposts["intervals"] if i["pid"] == app_pid and i["category"] == "action"]
    rows = signposts_lib.summarize(app_intervals)
    per_action = collections.defaultdict(dict)
    for row in rows:
        if row["name"] in ("action.input_to_commit", "action.commit", "action.perform", "action.commit.missed"):
            per_action[row["detail"]][row["name"]] = {k: row[k] for k in ("count", "p50_ms", "p95_ms", "p99_ms", "max_ms")}
    # Cross-process waits: the main thread off CPU inside an action's perform (no samples while it ran).
    waits = collections.defaultdict(lambda: {"count": 0, "ms": 0.0, "max_ms": 0.0, "example": None})
    for i in actions:
        if i["name"] != "action.perform" or i["ms"] < 2 or i["nested_loop"] or not main:  # a nested loop waits for the person
            continue
        on = sum(w for _, w, _ in main_samples(i["start_us"], i["end_us"])) / 1000.0
        off = i["ms"] - on
        if off < 2:
            continue
        overlapping = [b for b in blocked if b["pid"] == app_pid and b["tid"] == main_tid and b["start_us"] < i["end_us"]
                       and b["end_us"] > i["start_us"]]
        stall = next((s for s in stalls if s["start_us"] < i["end_us"] and s["end_us"] > i["start_us"]), None)
        cls = overlapping[0]["class"] if overlapping else wait_class(stall["frames"]) if stall else "unattributed"
        entry = waits[cls]
        entry["count"] += 1
        entry["ms"] += off
        if off > entry["max_ms"]:
            entry["max_ms"] = off
            entry["example"] = f"{i['fields'].get('id')} at +{(i['start_us'] - start) / 1e6:.2f} s: {off:.1f} of {i['ms']:.1f} ms off CPU"
    for s in stalls:
        if s["kind"] == "stall" and s["cpu_ms"] < 0.5 * s["ms"]:
            entry = waits["stall:" + wait_class(s["frames"])]
            entry["count"] += 1
            entry["ms"] += s["ms"] - s["cpu_ms"]
            if s["ms"] > entry["max_ms"]:
                entry["max_ms"] = s["ms"]
                entry["example"] = f"+{(s['start_us'] - start) / 1e6:.2f} s: {s['ms']:.0f} ms, cpu {s['cpu_ms']:.0f} ms: " + \
                    " < ".join(str(f) for f in s["frames"][:6])
    main_blocked = collections.Counter()
    for b in blocked:
        if b["pid"] == app_pid and b["tid"] == main_tid:
            main_blocked[b["class"]] += b["end_us"] - b["start_us"]
    daemon = []
    for row in span_rows:
        try:
            span = json.loads(row["line"])
        except (ValueError, KeyError):
            continue
        if not str(span.get("label", "")).endswith(".follow"):
            daemon.append((float(span.get("total_us") or 0) / 1000.0, span.get("label")))
    daemon.sort(reverse=True)
    by_role = collections.Counter()
    for t, w, thread, _ in samples:
        by_role[roles.get(thread.get("pid"), "other")] += w / 1e6
    # None when the window never started (a stage before it failed): the stop path stamps the end anyway.
    window_s = None if meta.get("window_start_us") is None else max(1e-9, ((meta.get("window_end_us") or start) - start) / 1e6)
    return {
        "host": meta.get("host"), "macos": meta.get("macos"), "tag": meta.get("tag"), "scenario": meta.get("scenario"),
        "scenario_label": meta.get("scenario_label"),
        "window_s": None if window_s is None else round(window_s, 1), "load_at_start": meta.get("load_at_start"), "stress": meta.get("stress"), "typed_pane": meta.get("typed_pane"), "storm_ops": meta.get("storm_ops"),
        "light": meta.get("light"), "storm_targets": meta.get("storm_targets"),
        "keys": meta.get("keys"), "chords": meta.get("chords"), "key_to_frame_ms": meta.get("key_to_frame_ms"),
        "frames": meta.get("frames"), "cef": meta.get("cef"), "window_state": meta.get("window_state"),
        "window_state_end": meta.get("window_state_end"),
        "window": meta.get("window"), "launched_env": meta.get("launched_env"),
        "errors": meta.get("errors") or [], "warnings": meta.get("warnings") or [],
        "top_stalls": top, "stall_count": len([s for s in stalls if s["kind"] == "stall"]),
        "actions": dict(per_action),
        "waits": {k: {**v, "ms": round(v["ms"], 1), "max_ms": round(v["max_ms"], 1)} for k, v in waits.items()},
        "main_thread_blocked_ms": {k: round(v / 1000, 1) for k, v in main_blocked.items()},
        "daemon_slowest": [{"ms": round(ms, 2), "label": label} for ms, label in daemon[:5]],
        "daemon_spans": len(daemon),
        "cpu_s_by_role": {k: round(v, 2) for k, v in by_role.most_common()},
        "unobserved": unobserved(roles, signposts, span_rows),
    }


def unobserved(roles, signposts, span_rows):
    """Processes on the path whose own spans the trace lacks (only their sampled stacks show)."""
    gaps = []
    present = set(roles.values())
    if "daemon" in present:
        gaps.append("daemon: debug spans cover terminal, workspace, pane and tab creates only; every other request "
                    "(snapshot, workspace update or move, status, input, attach) has no span, and span lines carry no "
                    "clock (placed by arrival)")
    for role in ("holder", "terminal-host", "acpmux"):
        if role in present:
            gaps.append(f"{role}: no spans or signposts")
    return gaps


def summary_text(s):
    lines = [f"TRACE {s.get('scenario_label') or s.get('scenario')} on {s.get('host')} (macOS {s.get('macos')}), tag {s.get('tag')}, "
             + (f"window {s['window_s']} s" if s.get('window_s') is not None else "no window (it never started)")
             + f", load average at start {s.get('load_at_start')}"
             + (f", exit code {s['exit_code']}" if s.get("exit_code") is not None else "")]
    if s.get("terminated") is not None:
        lines.append(f"  TERMINATED by a signal (exit {s['terminated']}): recorders and app stopped; the export and "
                     f"the trace build did not run or were cut (recording.trace, if any, is kept)")
    if s.get("timed_out"):
        lines.append(f"  INCOMPLETE: stage(s) {', '.join(s['timed_out'])} passed their bound; the trace holds what was recorded")
    for error in s.get("errors") or []:
        lines.append(f"  ERROR: stage {error.get('stage')} failed: {error.get('error')}")
    for warning in s.get("warnings") or []:
        lines.append(f"  WARNING: {warning}")
    if s.get("no_trace"):
        lines.append(f"  no trace file: {s['no_trace']}")
    if s.get("wrapped"):
        lines.append(f"  wrapped command stopped: {s['wrapped']}")
    if s.get("command_exit") is not None:
        lines.append(f"  wrapped command exit {s['command_exit']}")
    if s.get("stages"):
        lines.append("  stages (s): " + ", ".join(f"{x['stage']} {x['seconds']}" + (" TIMED OUT" if x["timed_out"] else "")
                                             + (" FAILED" if x.get("error") else "") for x in s["stages"]))
    src = s.get("sources") or {}
    if src:
        lines.append(f"  file {src.get('trace')} ({(src.get('trace_bytes') or 0) / 1e6:.1f} MB, {src.get('events')} events); "
                     f"open it in https://ui.perfetto.dev")
        lines.append(f"  sources: {src.get('samples')} stack samples over {src.get('sampled_processes')} processes "
                     f"(clock: {src.get('xctrace_clock')}); {src.get('signpost_intervals')} signpost intervals "
                     f"(lost {src.get('signposts_lost')}); {src.get('hang_records')} watchdog records; "
                     f"{src.get('daemon_span_lines')} daemon span lines; {((src.get('chromium') or {}).get('events'))} Chromium events; "
                     f"{src.get('system_trace_states')} System Trace syscall waits")
        if src.get("xctrace_clock_warning"):
            lines.append(f"  WARNING: {src['xctrace_clock_warning']}")
        if (src.get("signpost_clock") or {}).get("warning"):
            lines.append(f"  WARNING: {src['signpost_clock']['warning']}")
        for schema, error in (src.get("unreadable_tables") or {}).items():
            lines.append(f"  WARNING: xctrace table {schema} skipped: {error}")
        if src.get("missing_tables"):
            lines.append(f"  WARNING: xctrace tables not exported: {', '.join(src['missing_tables'])} (their tracks are "
                         f"empty; `trace.py export DIR` again while recording.trace is there)")
        if src.get("os_tids_over_uint32"):
            lines.append(f"  WARNING: OS thread ids over 2^32 ({src['os_tids_over_uint32']}): Perfetto puts their "
                         f"slices on the process track")
        if src.get("app_pid_from") not in (None, "launched"):
            lines.append(f"  app pid {src.get('app_pid')} (from {src.get('app_pid_from')})")
    env = s.get("launched_env")
    state = s.get("window_state") or {}
    window = s.get("window") or {}
    if env is not None or state or window:
        no_activate = "set" if isinstance(env, dict) and "CMUX_NEXT_NO_ACTIVATE" in env else "unset" if env is not None else "?"
        end = s.get("window_state_end") or {}
        lines.append(f"  window key {state.get('window_key')}" + (f" at the start, {end.get('window_key')} at the end"
                                                                  if end else "")
                     + f" (CMUX_NEXT_NO_ACTIVATE {no_activate}); placement "
                     f"{window.get('window_problem') or ('on its screen' if window else 'by the STRESS builder')}"
                     + (f", bottom Dock over {window['dock_overlap_pt']} pt" if window.get("dock_overlap_pt") else ""))
    if s.get("light"):
        lines.append(f"  light session: {s['light']}")
    if s.get("stress"):
        st = s["stress"]
        lines.append(f"  STRESS: {st.get('workspaces')} workspaces, {st.get('measured_panes')} panes, tabs {st.get('measured_tabs')}, "
                     f"{st.get('busy_terminals')} busy terminals" + (f"; NOT the STRESS shape: {st['shape_error']}" if st.get("shape_error") else ""))
    typed = s.get("typed_pane") or {}
    if typed:
        lines.append(f"  typed pane: {typed.get('before')} -> {typed.get('after')}"
                     + ("" if typed.get("quiet") else " (NOT a quiet terminal: key-press flows may join the busy output)"))
    if s.get("storm_ops") is not None:
        lines.append(f"  storm ops {s.get('storm_ops')}, keys {s.get('keys')}, chords {s.get('chords')}, "
                     f"key to frame {s.get('key_to_frame_ms')}")
    frames = s.get("frames") if isinstance(s.get("frames"), dict) else {}
    if frames:
        keys = ("refresh_ms", "frames", "p50_ms", "p95_ms", "max_ms", "missed", "main_p95_ms", "main_max_ms")
        lines.append("  display frames: " + ", ".join(f"{k} {round(frames[k], 2) if isinstance(frames.get(k), float) else frames.get(k)}"
                                                    for k in keys if k in frames))
    if s.get("cef"):
        cef = s["cef"]
        if "valid" in cef:
            lines.append(f"  chromium valid: {cef['valid']}" + (f" ({'; '.join(cef['problems'])})" if cef.get("problems") else ""))
        else:
            lines.append("  chromium valid: unknown (recorded by a trace.py before the debug.cef parse)")
    if s.get("storm_targets"):
        lines.append(f"  storm targets: {s['storm_targets']}")
    lines.append(f"  CPU seconds by process role: {s.get('cpu_s_by_role')}")
    if s.get("launch"):
        lines += launch_text(s["launch"], (s.get("sources") or {}).get("startup_files"))
    lines.append(f"Top main-thread stalls ({s.get('stall_count')} over the watchdog threshold):")
    for n, stall in enumerate(s.get("top_stalls") or [], 1):
        how = f"waiting ({stall['wait_class']})" if stall["waiting"] else "busy"
        lines.append(f" {n}. {stall['ms']} ms at +{stall['at_s']} s, cpu {stall['cpu_ms']} ms, {how} [{stall['source']}]")
        if stall["actions"]:
            lines.append(f"    during: {'; '.join(stall['actions'])}")
        if stall["watchdog_stack"]:
            lines.append("    watchdog stack: " + " < ".join(str(f)[:90] for f in stall["watchdog_stack"][:8]))
        if stall["sampled_frames"]:
            lines.append("    sampled: " + "; ".join(f"{x['frame'][:90]} x{x['samples']}" for x in stall["sampled_frames"][:5]))
        if stall["sampled_leaf"]:
            lines.append("    leaf: " + "; ".join(f"{x['frame'][:90]} x{x['samples']}" for x in stall["sampled_leaf"]))
        if stall["chromium_main_thread"]:
            lines.append("    chromium on main: " + "; ".join(f"{x['event']} {x['ms']} ms" for x in stall["chromium_main_thread"]))
    lines.append("Input to commit per action (ms, p50/p95/p99/max, n):")
    for action, rows in sorted((s.get("actions") or {}).items(), key=lambda kv: -((kv[1].get("action.commit") or {}).get("p95_ms") or 0)):
        if action == "*":
            continue
        i2c = rows.get("action.input_to_commit") or {}
        commit = rows.get("action.commit") or {}
        perform = rows.get("action.perform") or {}
        lines.append(f"  {action:32} input->commit {i2c.get('p50_ms', '-')}/{i2c.get('p95_ms', '-')}/"
                     f"{i2c.get('p99_ms', '-')}/{i2c.get('max_ms', '-')} "
                     f"n={i2c.get('count', 0)}  commit {commit.get('p50_ms', '-')}/{commit.get('p95_ms', '-')}/"
                     f"{commit.get('p99_ms', '-')}  "
                     f"perform {perform.get('p50_ms', '-')}/{perform.get('p95_ms', '-')}/{perform.get('p99_ms', '-')}"
                     + (f"  missed {rows['action.commit.missed']['count']}" if rows.get("action.commit.missed") else ""))
    flows = s.get("key_flows") or {}
    if flows.get("presses") or flows.get("warnings"):
        if flows.get("presses"):
            lines.append(f"Key-press flows: {flows['complete']} of {flows['presses']} presses complete; "
                         f"{flows.get('echo_complete', 0)} with every echo hop, {flows.get('windowed_presses', 0)} "
                         f"placed by windows (an old recording's flow-0 records)")
        else:
            lines.append("Key-press flows: 0 presses assembled")
        for warning in flows.get("warnings") or []:
            lines.append(f"  WARNING: {warning}")
        for target in sorted(set(s.get("key_to_commit_ms") or {}) | set(s.get("hop_ms") or {})):
            for kind, label in (("key_to_commit_ms", "key to the echo frame's commit"),
                                ("key_to_present_estimate_ms", "key to its present (est.)")):
                row = (s.get(kind) or {}).get(target)
                if row:
                    lines.append(f"  {target} {label}: {row['p50']}/{row['p95']}/{row['p99']}/{row['max']} ms "
                                 f"(p50/p95/p99/max, n={row['n']})")
            hops = (s.get("hop_ms") or {}).get(target) or {}
            for alternatives in FLOW_HOPS[1:]:
                for hop in alternatives:
                    row = hops.get(hop)
                    if row:
                        lines.append(f"    {hop:34} +{row['p50']}/{row['p95']}/{row['p99']}/{row['max']} ms after "
                                     f"its cause (p50/p95/p99/max, n={row['n']})")
        for entry in flows.get("incomplete") or []:
            why = "".join(f"; ambiguous {hop} ({row['candidates']} candidate(s)"
                          + (", the press before has none of its own" if row.get("earlier_unplaced") else "") + ")"
                          for hop, row in (entry.get("ambiguous") or {}).items())
            why += "".join(f"; {hop} stamped before its cause" for hop in entry.get("early") or [])
            lines.append(f"  incomplete {entry['flow']}: missing {', '.join(entry['missing'])}{why}")
        if flows.get("dropped_records"):
            lines.append(f"  flow records dropped (queue full): {flows['dropped_records']}")
    if s.get("clock_order_violations"):
        lines.append(f"Clock order: {s['clock_order_violations']} hop(s) earlier than their cause "
                     f"(a source is off CLOCK_UPTIME_RAW; `trace.py check-clock DIR` lists them):")
        lines += [f"  {violation_text(v)}" for v in (s.get("clock_order") or {}).get("violations", [])[:5]]
    requests = s.get("request_flows") or {}
    if requests.get("requests"):
        lines.append(f"Daemon request flows: {requests['linked']} of {requests['requests']} linked "
                     f"({s.get('request_flow_linked')}%), {requests['round_trips']} round trips")
    latency = s.get("input_latency") or {}
    if latency.get("slots") or latency.get("unplaced"):
        lines.append(f"Input latency, generated -> presented (ms p50/p95/p99/max): {latency['slots']} slots; not folded "
                     + ", ".join(f"{name} {latency.get(name, 0)}" for name in
                                 ("automation", "unpresented", "no_update", "unplaced", "stages_out_of_order")))
        by_p95 = sorted((latency.get("rows") or {}).items(), key=lambda kv: -kv[1]["total_ms"]["p95"])
        for key, row in by_p95:
            total = row["total_ms"]
            lines.append(f"  {key:44} {total['p50']}/{total['p95']}/{total['p99']}/{total['max']} n={total['n']}")
            slowest = sorted(row["stage_ms"].items(), key=lambda kv: -kv[1]["p95"])[:3]
            lines.append("    slowest stages (p95): " + "; ".join(f"{name} {r['p95']}" for name, r in slowest))
    joined = s.get("chromium_event_latency") or {}
    if joined.get("key_latencies"):
        chromium, own = joined.get("chromium_total_ms") or {}, joined.get("cmux_total_ms") or {}
        types = ", ".join(f"{kind} {row['linked']}/{row['latencies']}"
                          for kind, row in sorted((joined.get("by_type") or {}).items()))
        lines.append(f"Chromium EventLatency (keys): {joined['linked']} of {joined['key_latencies']} joined to a cmux key "
                     f"({types}); {joined.get('keys', joined['linked'])} keys, {joined['exact']} on the NSEvent "
                     f"timestamp, {joined['with_flow']} with a key.flow; Chromium total (the slice that ends last) "
                     f"p50/p95/max {chromium.get('p50')}/{chromium.get('p95')}/{chromium.get('max')} ms, cmux "
                     f"generated -> presented {own.get('p50')}/{own.get('p95')}/{own.get('max')} ms")
    rings = s.get("rings") or {}
    if rings.get("files") or rings.get("unreadable"):
        lines.append(f"Trace rings: {len(rings.get('files') or [])} read: "
                     + ", ".join(f"{r['role']} {r['pid']} {r['kind']} {r['records']} records"
                                 + "".join(f" {key} {r[key]}" for key in RING_COUNTERS if r.get(key))
                                 for r in rings.get("files") or []))
        for name, why in (rings.get("unreadable") or {}).items():
            lines.append(f"  WARNING: ring {name} not read: {why}")
        if rings.get("unpaired"):
            lines.append(f"  unpaired ring records: {rings['unpaired']}")
    lines.append("Cross-process waits (main thread off CPU):")
    for cls, w in sorted((s.get("waits") or {}).items(), key=lambda kv: -kv[1]["ms"]):
        lines.append(f"  {cls:22} {w['count']:4} x, {w['ms']} ms total, max {w['max_ms']} ms; e.g. {w['example']}")
    if s.get("main_thread_blocked_ms"):
        lines.append(f"  main thread blocked (System Trace) by class, ms: {s['main_thread_blocked_ms']}")
    if s.get("daemon_slowest"):
        lines.append(f"  slowest daemon spans ({s.get('daemon_spans')}): " +
                     "; ".join(f"{d['label']} {d['ms']} ms" for d in s["daemon_slowest"]))
    for gap in s.get("unobserved") or []:
        lines.append(f"  no spans: {gap}")
    return "\n".join(lines)


# ---------------------------------------------------------------- Perfetto import check

# The tracks that must import as their own thread tracks, by name prefix (the synthetic tracks build() names).
IMPORT_TRACKS = ("signposts ", "watchdog stalls", "daemon spans", "key flow", "input latency", "ring ")
IMPORT_QUERY_FLOWS = """
select count(*) as flows from flow f join slice s on s.id = f.slice_out where s.category in ('key.flow', 'input.latency.stage')
"""
IMPORT_QUERY_TRACKS = """
select p.pid as pid, t.tid as tid, t.name as name, count(s.id) as slices
from thread t left join process p using (upid)
left join thread_track tt using (utid) left join slice s on s.track_id = tt.id
group by t.utid
"""
IMPORT_QUERY_STATS = """
select name, idx, severity, source, value from stats where value > 0 and severity in ('error', 'data_loss')
"""
IMPORT_TIMEOUT_S = 600  # one trace_processor_shell query over a trace of up to a few hundred MB


def expected_slices(events):
    """{(pid, tid): slices} the JSON importer must make: complete (X), begin (B) and thread-scoped instant
    (i / I without s, or s=t) events. Also {(pid, tid): thread name}."""
    slices, names = collections.Counter(), {}
    for e in events:
        ph, key = e.get("ph"), (e.get("pid"), e.get("tid"))
        if ph == "M" and e.get("name") == "thread_name":
            names[key] = (e.get("args") or {}).get("name")
        elif ph in ("X", "B") or (ph in ("i", "I") and e.get("s", "t") == "t"):
            slices[key] += 1
    return slices, names


def run_query(trace_processor, trace, sql):
    """Rows (dicts) of one SQL query through `trace_processor_shell -q`, which prints the result as CSV."""
    import csv, io
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as f:
        f.write(sql)
        query = f.name
    try:
        done = subprocess.run([trace_processor, "-q", query, trace], capture_output=True, text=True,
                              timeout=IMPORT_TIMEOUT_S)
    finally:
        os.unlink(query)
    if done.returncode != 0:
        raise RuntimeError(f"trace_processor_shell exited {done.returncode}: {done.stderr[-600:]}")
    lines = [l for l in done.stdout.splitlines() if l.strip()]
    start = next((i for i, l in enumerate(lines) if l.startswith('"')), None)  # the header row; logs come before it
    if start is None:
        raise RuntimeError(f"trace_processor_shell printed no CSV header: {done.stdout[:600]!r} {done.stderr[-300:]!r}")
    return list(csv.DictReader(io.StringIO("\n".join(lines[start:]))))


def check_import(out, trace_processor):
    """Loads OUT/trace.json.gz with trace_processor_shell (Perfetto's importer, the one ui.perfetto.dev runs)
    and checks that every signposts, watchdog-stalls and daemon-spans track imports as its own named thread
    track with every slice the JSON holds, and that the importer reports no error or data loss. Writes
    OUT/import-check.json; returns (ok, report)."""
    trace = os.path.join(out, "trace.json.gz")
    with gzip.open(trace, "rt") as f:
        events = json.load(f)["traceEvents"]
    want, names = expected_slices(events)
    rows = run_query(trace_processor, trace, IMPORT_QUERY_TRACKS)
    got = {}
    for row in rows:
        try:
            got[(int(row["pid"]), int(row["tid"]))] = (row["name"], int(row["slices"]))
        except (TypeError, ValueError, KeyError):
            continue
    stats = run_query(trace_processor, trace, IMPORT_QUERY_STATS)
    # Each key-press chain of n hop slices is n - 1 arrows (flow_out on all but the last, flow_in on all but the first);
    # a chain linked from an EventLatency slot is n, its first arrow leaving the slot's dispatch stage.
    want_flows = sum(1 for e in events if e.get("flow_out"))
    got_flows = int((run_query(trace_processor, trace, IMPORT_QUERY_FLOWS) or [{"flows": 0}])[0].get("flows") or 0)
    problems, tracks = [], []
    if got_flows != want_flows:
        problems.append(f"{want_flows} key-flow and input-latency arrows in the JSON, {got_flows} imported")
    for key, name in sorted(names.items(), key=lambda kv: str(kv)):
        if not (name or "").startswith(IMPORT_TRACKS):
            continue
        imported = got.get(key)
        tracks.append({"pid": key[0], "tid": key[1], "name": name, "json_slices": want.get(key, 0),
                       "imported": imported})
        if imported is None:
            problems.append(f"{name} (pid {key[0]} tid {key[1]}) is not a thread in the import")
        elif imported[0] != name:
            problems.append(f"{name} imported as {imported[0]!r}")
        elif imported[1] != want.get(key, 0):
            problems.append(f"{name}: {want.get(key, 0)} slices in the JSON, {imported[1]} imported")
    kinds = {prefix.strip(): sum(1 for t in tracks if t["name"].startswith(prefix)) for prefix in IMPORT_TRACKS}
    utids = {(t["pid"], t["tid"]) for t in tracks}
    if len(utids) != len(tracks):
        problems.append("two named tracks share one thread")
    for row in stats:
        problems.append(f"importer stat {row.get('name')}[{row.get('idx')}] = {row.get('value')} ({row.get('severity')})")
    report = {"ok": not problems, "problems": problems, "tracks_by_kind": kinds, "flows": {"json": want_flows, "imported": got_flows},
              "tracks": tracks, "stats": stats,
              "threads_imported": len(got), "events": len(events)}
    write_json(os.path.join(out, "import-check.json"), report)
    return not problems, report


# ---------------------------------------------------------------- self-test

TP_XML = """<?xml version="1.0"?><trace-query-result><node xpath="x"><schema name="time-profile"/>
<row><sample-time id="1" fmt="00:00.001">1000000</sample-time><thread id="2" fmt="Main Thread  0x1a (cmux DEV, pid: 42)"><tid id="3" fmt="0x1a">26</tid><process id="4" fmt="cmux DEV (42)"><pid id="5" fmt="42">42</pid></process></thread><weight id="6" fmt="1.00 ms">1000000</weight><backtrace id="7"><frame id="8" name="leafA"/><frame id="9" name="mid"/><frame id="10" name="main"/></backtrace></row>
<row><sample-time id="11" fmt="00:00.002">2000000</sample-time><thread ref="2"/><weight ref="6"/><backtrace id="12"><frame id="13" name="leafB"/><frame ref="9"/><frame ref="10"/></backtrace></row>
<row><sample-time id="14" fmt="00:00.010">10000000</sample-time><thread ref="2"/><weight ref="6"/><backtrace ref="12"/></row>
</node></trace-query-result>"""


def catalog_span_lines(spans):
    """`log stream --signpost` lines of the app's catalog spans: (category, name, id, begin ns, end ns, begin message,
    end message) each."""
    lines = []
    for category, name, signpost_id, begin, end, begin_message, end_message in spans:
        for kind, at, message in (("begin", begin, begin_message), ("end", end, end_message)):
            lines.append(json.dumps({"eventType": "signpostEvent", "subsystem": SUBSYSTEM, "category": category,
                                     "signpostName": name, "signpostID": signpost_id, "signpostType": kind,
                                     "processID": 42, "machTimestamp": at, "eventMessage": message}))
    return "".join(line + "\n" for line in lines)


# Inside the fixture's 40 ms stall at 1.0 s: a palette open's main-thread slice, a warm tab switch, and a cold one
# that a later switch superseded (`commit=missed`): it still names the stall, labeled missed.
FIXTURE_CATALOG_SPANS = [
    ("stall", "stall.palette_open", 30, 1_000_000_000, 1_012_000_000, "", ""),
    ("switch", "switch.tab", 31, 1_000_500_000, 1_020_000_000, "kind=warm", ""),
    ("switch", "switch.tab", 32, 1_001_000_000, 1_030_000_000, "kind=cold", "commit=missed"),
]


def build_fixture(out, slept_us=None):
    """Raw files of a small recording in `out` (hand-written shapes), then `build(out)`: its summary. With
    `slept_us`, the host slept that long since boot: the signposts' machTimestamps are mach_continuous_time
    (that much ahead of CLOCK_UPTIME_RAW, as `log` writes them, with the clock line SignpostStream writes) and
    an xctrace os-signpost table holds the same begin events (the xctrace clock is aligned to them)."""
    sample = signposts_lib.SAMPLE.replace('"processID":1', '"processID":42') + catalog_span_lines(FIXTURE_CATALOG_SPANS)
    if slept_us is not None:
        sample = re.sub(r'"machTimestamp":(\d+)', lambda m: f'"machTimestamp":{int(int(m.group(1)) + slept_us * 1000)}',
                        sample)
        sample = sample.replace("#timebase 1/1\n", f"#timebase 1/1\n#continuous-minus-uptime-us {slept_us}\n", 1)
        # xctrace time 0 is uptime 0 here: its begin events at the signposts' uptimes.
        rows = "".join(f'<row><time>{t}</time><event-type fmt="Begin"/><name fmt="{name}"/><subsystem fmt="{SUBSYSTEM}"/></row>'
                       for t, name in ((1_000_000_000, "action.commit"), (1_000_000_000, "action.perform"),
                                       (2_000_000_000, "action.commit")))
        open(os.path.join(out, "xctrace-os-signpost.xml"), "w").write(
            f'<?xml version="1.0"?><trace-query-result><node><schema name="os-signpost"/>{rows}</node></trace-query-result>')
    open(os.path.join(out, "signposts.ndjson"), "w").write(sample)
    write_json(os.path.join(out, "meta.json"), {"app_pid": 42, "window_start_us": 900000.0, "window_end_us": 9e6,
                                                 "scenario": "self-test"})
    write_json(os.path.join(out, "hangs.json"), {"records": [
        {"sequence": 1, "kind": "stall", "start_uptime_ns": 1_000_000_000, "duration_ms": 40, "cpu_ms": 2,
         "frames": ["libsystem_kernel.dylib __psynch_mutexwait + 8", "CmuxNextApp Foo.bar() + 10"]}]})
    open(os.path.join(out, "daemon-spans-stamped.jsonl"), "w").write(json.dumps(
        {"at_us": 5000.0, "line": json.dumps({"label": "new-tab", "total_us": 3000, "marks": [["a", 1000], ["b", 2500]]})}) + "\n")
    write_json(os.path.join(out, "chromium-trace.json"), {"traceEvents": [
        {"ph": "M", "pid": 42, "tid": 259, "name": "thread_name", "args": {"name": "CrBrowserMain"}},
        {"ph": "c", "pid": 42, "tid": 259, "name": "clock_sync", "ts": 500.0, "args": {"sync_id": "s"}},
        {"ph": "X", "pid": 42, "tid": 259, "name": "ThreadControllerImpl::RunTask", "ts": 1001000.0, "dur": 5000.0,
         "args": {"src_func": "OnFrame"}}]})
    write_json(os.path.join(out, "chromium-clock.json"), {"sync_id": "s", "before_us": 499.0, "after_us": 501.0})
    write_json(os.path.join(out, "driver.json"), [{"kind": "key", "name": "key a", "start_us": 1000.0, "end_us": 1500.0}])
    # Two main-thread samples inside the stall (at 1.001 s and 1.002 s on the trace clock).
    open(os.path.join(out, "xctrace-time-profile.xml"), "w").write(
        TP_XML.replace(">1000000</sample-time>", ">1001000000</sample-time>").replace(">2000000</sample-time>", ">1002000000</sample-time>"))
    return build(out)


def check_parsers_and_merge():
    """The hand-written export shapes (not a real xctrace export): refs, thread fmt, leaf-first frames, the
    flame slices, lanes, roles, wait classes, and a whole build from raw files."""
    with tempfile.TemporaryDirectory() as out:
        path = os.path.join(out, "tp.xml")
        open(path, "w").write(TP_XML)
        samples = time_profile_samples(path)
        assert len(samples) == 3, samples
        assert samples[0][2] == {"tid": 26, "name": "Main Thread", "pid": 42, "process": "cmux DEV"}, samples[0]
        assert samples[1][3] == ("leafB", "mid", "main"), samples[1]
        events = flame_events(samples, 100.0, lambda t: True)
        by = collections.defaultdict(list)
        for e in events:
            by[e["name"]].append((e["ts"], e["dur"]))
        # main and mid run 0-3 ms (two adjacent samples), then the thread is off CPU until 10 ms.
        assert by["main"] == [(1100.0, 2000.0), (10100.0, 1000.0)], by
        assert by["leafA"] == [(1100.0, 1000.0)] and by["leafB"][0] == (2100.0, 1000.0), by
        # Of the slices that start together on a thread, the caller (the longest) comes first: an importer that
        # keeps the file's order for equal times nests them.
        first_dur = {}
        for e in events:
            first_dur.setdefault((e["pid"], e["tid"], e["ts"]), e["dur"])
            assert e["dur"] <= first_dur[(e["pid"], e["tid"], e["ts"])], events
        # A Chromium thread id that is also a sampled thread's id moves to a track of its own.
        moved = chromium_on_own_tracks([{"ph": "X", "pid": 42, "tid": 26, "ts": 0, "dur": 1},
                                        {"ph": "X", "pid": 42, "tid": 7, "ts": 0, "dur": 1}], samples, SyntheticTracks({26, 7}))
        assert moved[0]["tid"] not in (26, 7) and moved[1]["tid"] == 7, moved
        # A Chromium child that ends after its parent ends with it.
        nested = chromium_on_own_tracks([{"ph": "X", "pid": 9, "tid": 1, "ts": 0, "dur": 10},
                                         {"ph": "X", "pid": 9, "tid": 1, "ts": 5, "dur": 6}], [], SyntheticTracks(set()))
        assert nested[1]["dur"] == 5, nested
        lanes = Lanes()
        assert [lanes.place(0, 10), lanes.place(1, 5), lanes.place(4, 12), lanes.place(11, 13)] == [0, 0, 1, 0]
        bundle = "/x/cmux DEV t.app"
        assert role_of(bundle + "/Contents/MacOS/cmux DEV", bundle) == "app"
        assert role_of(bundle + "/Contents/Resources/bin/cmux-tui server run --session s", bundle) == "daemon"
        assert role_of(bundle + "/Contents/Resources/bin/cmux-tui-host __holder --x", bundle) == "holder"
        assert role_of(bundle + "/Contents/Frameworks/cmux DEV Helper (Renderer).app/Contents/MacOS/x --type=renderer", bundle) == "cef-renderer"
        assert role_of(bundle + "/Contents/Resources/bin/cmux workspace x", bundle) == "cli"
        assert role_of("/usr/bin/true", bundle) is None
        assert wait_class(["__psynch_mutexwait", "DaemonClient.send"]) == "lock"
        assert wait_class(["read", "DaemonClient.request"]) == "daemon"
        assert wait_class(["mach_msg2_trap", "CA::Transaction::commit()"]) == "windowserver"
        summary = build_fixture(out)
        with gzip.open(os.path.join(out, "trace.json.gz"), "rt") as f:
            trace = json.load(f)
        names = [e.get("name") for e in trace["traceEvents"]]
        assert "action.commit tab.new" in names and "daemon new-tab" in names and "b" in names, names
        assert any(str(n).startswith("stall 40 ms") for n in names), names
        assert summary["top_stalls"][0]["ms"] == 40.0 and summary["top_stalls"][0]["waiting"], summary["top_stalls"]
        assert summary["top_stalls"][0]["wait_class"] == "lock", summary["top_stalls"]
        # The catalog spans the stall happened inside name it; a superseded switch (commit=missed) did its
        # main-thread work too, so it names it, labeled missed.
        during = summary["top_stalls"][0]["actions"]
        assert "stall.palette_open (12.0 ms)" in during and "switch.tab warm (19.5 ms)" in during, during
        assert "action.commit tab.new (6.0 ms)" in during and "switch.tab cold missed (29.0 ms)" in during, during
        # On their category's lanes of the app.
        lanes = {e.get("name"): e.get("cat") for e in trace["traceEvents"]}
        assert lanes.get("stall.palette_open") == "signpost.stall" and lanes.get("switch.tab warm") == "signpost.switch", lanes
        assert summary["actions"]["tab.new"]["action.input_to_commit"]["p50_ms"] == 7.5, summary["actions"]
        # Each action row carries p99 next to p95 (perf-signposts' perf_stats rows), and the text prints it.
        assert summary["actions"]["tab.new"]["action.commit"]["p99_ms"] == 6.0, summary["actions"]
        assert "input->commit 7.5/7.5/7.5/7.5 n=1  commit 6.0/6.0/6.0" in summary_text(summary), summary_text(summary)
        assert summary["waits"]["stall:lock"]["count"] == 1 and "unattributed" not in summary["waits"], summary["waits"]
        span = next(e for e in trace["traceEvents"] if e.get("name") == "daemon new-tab")
        assert span["ts"] == 2000.0 and span["dur"] == 3000.0, span
        # Every synthetic track has a name (Perfetto shows an unnamed one as "Thread <tid>").
        named = {(e.get("pid"), e.get("tid")): e["args"]["name"] for e in trace["traceEvents"]
                 if e.get("ph") == "M" and e.get("name") == "thread_name"}
        assert named.get((span["pid"], span["tid"])) == "daemon spans", named
        assert summary["sources"]["chromium"]["clock"]["offset_us"] == 0.0, summary["sources"]["chromium"]
        assert summary["top_stalls"][0]["chromium_main_thread"][0]["event"].startswith("ThreadControllerImpl::RunTask (OnFrame)"), summary
        task = next(e for e in trace["traceEvents"] if e.get("name") == "ThreadControllerImpl::RunTask")
        assert task["tid"] == 259, task
        assert {"frame": "mid", "samples": 2} in summary["top_stalls"][0]["sampled_frames"], summary["top_stalls"]
        summary_text(summary)


# A host's sleep since boot as one fleet mini had it (mac26, 2026-10-24: `log` machTimestamp minus the watchdog's
# CLOCK_UPTIME_RAW stall ends, 20 stalls, all within 0.1 ms of this).
SLEPT_US = 259183.7023e6


def check_signpost_clock():
    """`log` stamps machTimestamp with mach_continuous_time, which counts the host's sleep; every other source
    is on CLOCK_UPTIME_RAW. On a host that slept since boot the signposts (and the xctrace samples aligned to
    them) must still land on the stall, key and Chromium events they happened with."""
    with tempfile.TemporaryDirectory() as out:
        sample = signposts_lib.SAMPLE.replace('"processID":1', '"processID":42')
        sample = re.sub(r'"machTimestamp":(\d+)', lambda m: f'"machTimestamp":{int(int(m.group(1)) + SLEPT_US * 1000)}',
                        sample)
        sample = sample.replace("#timebase 1/1\n", f"#timebase 1/1\n#continuous-minus-uptime-us {SLEPT_US}\n", 1)
        open(os.path.join(out, "signposts.ndjson"), "w").write(sample)
        parsed = read_signposts(os.path.join(out, "signposts.ndjson"))
        begin = min(i["start_us"] for i in parsed["intervals"])
        assert begin == 1_000_000.0, begin
        assert parsed["clock"]["warning"] is None, parsed["clock"]
        # Without the clock line the times cannot be put on CLOCK_UPTIME_RAW: say so.
        open(os.path.join(out, "signposts.ndjson"), "w").write(sample.replace(f"#continuous-minus-uptime-us {SLEPT_US}\n", ""))
        assert "mach_continuous_time" in (read_signposts(os.path.join(out, "signposts.ndjson"))["clock"]["warning"] or "")
        # A sleep during the recording (the end line differs): say so.
        open(os.path.join(out, "signposts.ndjson"), "w").write(sample + f"#continuous-minus-uptime-us-end {SLEPT_US + 5e6}\n")
        assert "slept" in (read_signposts(os.path.join(out, "signposts.ndjson"))["clock"]["warning"] or "")
    with tempfile.TemporaryDirectory() as out:
        summary = build_fixture(out, slept_us=SLEPT_US)
        with gzip.open(os.path.join(out, "trace.json.gz"), "rt") as f:
            trace = json.load(f)
        commit = next(e for e in trace["traceEvents"] if e.get("name") == "action.commit tab.new")
        stall = next(e for e in trace["traceEvents"] if str(e.get("name")).startswith("stall 40 ms"))
        assert commit["ts"] == stall["ts"] == 1_000_000.0, (commit, stall)
        assert "action.commit tab.new (6.0 ms)" in summary["top_stalls"][0]["actions"], summary["top_stalls"]
        assert summary["sources"]["signpost_clock"]["warning"] is None, summary["sources"]
        # The xctrace samples are aligned to the signposts: still inside the stall.
        assert {"frame": "mid", "samples": 2} in summary["top_stalls"][0]["sampled_frames"], summary["top_stalls"]
        summary_text(summary)


def check_stage_bounds():
    """A stage past its bound ends at its bound (the blocking call raises), runs its cleanup and is recorded; a
    non-fatal one lets the recording go on, a fatal one re-raises."""
    meta, lines, cleaned = {}, [], []
    stages = Stages(meta, heartbeat_s=0.1, log=lines.append)
    started = time.monotonic()
    with stages.run("window", bound=0.3, on_abort=lambda: cleaned.append("window")):
        time.sleep(5)
    assert time.monotonic() - started < 2, "the stage did not end at its bound"
    assert meta["timed_out"] == ["window"] and cleaned == ["window"], (meta, cleaned)
    assert any("still running" in line for line in lines) and any("PASSED ITS BOUND" in line for line in lines), lines
    try:
        with stages.run("launch", bound=0.2, fatal=True):
            time.sleep(5)
        raise AssertionError("a fatal stage past its bound must re-raise")
    except StageTimeout as error:
        assert error.name == "launch", error
    with stages.run("build", bound=5):
        pass
    assert [x["timed_out"] for x in meta["stages"]] == [True, True, False], meta["stages"]
    assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0), "a stage left its timer armed"
    assert "INCOMPLETE: stage(s) window, launch" in summary_text({"timed_out": meta["timed_out"], "stages": meta["stages"]})


def check_stage_errors():
    """Review 1: an error that is not a timeout (a CDP RuntimeError, a socket timeout, a failed launch) is
    recorded, its cleanup runs and a non-fatal stage lets the recording go on; a fatal one re-raises; a
    signal's SystemExit passes through unrecorded."""
    meta, cleaned = {}, []
    stages = Stages(meta, heartbeat_s=60, log=lambda line: None)
    with stages.run("chromium-stop", bound=5, on_abort=lambda: cleaned.append("closed")):
        raise RuntimeError("CDP error -32000: Tracing is not started")
    assert cleaned == ["closed"], cleaned
    assert meta["errors"] and meta["errors"][0]["stage"] == "chromium-stop" and "Tracing" in meta["errors"][0]["error"], meta
    assert meta["stages"][-1].get("error") and not meta["timed_out"], meta
    with stages.run("stop-signposts", bound=5):
        raise TimeoutError("timed out")  # socket.timeout
    try:
        with stages.run("launch", bound=5, fatal=True):
            raise LaunchError("tag-in-use", {"detail": "an app of the tag runs"})
        raise AssertionError("a fatal stage's error must re-raise")
    except LaunchError as error:
        stages.note_error("record", error)  # the run records it again: once only
    try:
        with stages.run("window", bound=5):
            raise SystemExit(143)
        raise AssertionError("a signal's SystemExit must pass through")
    except SystemExit as error:
        assert error.code == 143
    assert [e["stage"] for e in meta["errors"]] == ["chromium-stop", "stop-signposts", "launch"], meta["errors"]
    assert "ERROR: stage chromium-stop failed" in summary_text({"errors": meta["errors"]})


def check_hold_defers_the_bound():
    """Review 1: a bound that fires between a spawn and its assignment raises only once the child is held."""
    meta = {}
    stages = Stages(meta, heartbeat_s=60, log=lambda line: None)
    held = []
    try:
        with stages.run("recorders-start", bound=0.2, fatal=True):
            with stages.hold():
                time.sleep(0.5)  # the alarm fires in here
                held.append("child")
            raise AssertionError("the deferred bound must raise when the hold ends")
    except StageTimeout:
        pass
    assert held == ["child"] and meta["timed_out"] == ["recorders-start"], (held, meta)


class FakeSource:
    """A recorder stand-in for the stop path: `behavior` is ok, raise or hang."""

    def __init__(self, name, log, behavior="ok"):
        self.name, self.log, self.behavior, self.path = name, log, behavior, "/nonexistent/chromium-trace.json"

    def stop(self):
        self.log.append(f"{self.name} stop")
        if self.behavior == "raise":
            raise RuntimeError("CDP error: tracingComplete never came")
        if self.behavior == "hang":
            time.sleep(5)
        return True

    def kill(self):
        self.log.append(f"{self.name} kill")

    close = kill


def fake_opts(**overrides):
    import types
    values = dict(command=None, seconds=1, seconds_cap=10, system_trace=False, keep=False, keep_recording=False,
                  storm_hz=0, app=None, socket=None, scenario="light-storm", key_interval=0.1, chord_every=0,
                  release=False, no_cef=False)
    values.update(overrides)
    return types.SimpleNamespace(**values)


def quiet_recording(out, recorder="sample", **overrides):
    meta = {"host": "self-test", "scenario": "self-test", "sources": {}, "warnings": []}
    stages = Stages(meta, heartbeat_s=60, log=lambda line: None)
    return Recording(fake_opts(**overrides), out, meta, stages, None, recorder)


def check_stop_survives_a_failing_source():
    """Review 1: a source whose stop raises (a CDP error) or hangs is recorded and killed, every other source
    still stops, and the summary (SUMMARY.txt with an ERROR line) and exit code 3 are still written."""
    saved = STAGE_BOUNDS_S["stop-spans"]
    STAGE_BOUNDS_S["stop-spans"] = 0.3
    try:
        with tempfile.TemporaryDirectory() as out:
            log = []
            rec = quiet_recording(out)
            rec.chromium = FakeSource("chromium", log, "raise")
            rec.hangs = FakeSource("hangs", log)
            rec.spans = FakeSource("spans", log, "hang")
            rec.signposts = FakeSource("signposts", log)
            rec.stop()
            assert log == ["chromium stop", "chromium kill", "hangs stop", "spans stop", "spans kill", "signposts stop"], log
            assert [e["stage"] for e in rec.meta["errors"]] == ["chromium-stop"], rec.meta["errors"]
            assert rec.meta["timed_out"] == ["stop-spans"], rec.meta["timed_out"]
            rec.finish()
            text = open(os.path.join(out, "SUMMARY.txt")).read()
            assert "ERROR: stage chromium-stop failed" in text and "INCOMPLETE: stage(s) stop-spans" in text, text
            assert rec.exit_code() == 3 and read_json(os.path.join(out, "summary.json"))["exit_code"] == 3
    finally:
        STAGE_BOUNDS_S["stop-spans"] = saved


def check_record_ends_cleanly():
    """Review 1: an error outside any stage still stops every source and writes SUMMARY.txt with exit 3; a
    signal's SystemExit (TagTeardown's SIGTERM handler) stops every source, writes SUMMARY.txt without an
    export and exits 128 + N. A --release recording's `cmux trace record` is one of those sources: its stop
    collects it."""
    for raised, code, line in ((RuntimeError("size_window: the display cannot hold STRESS"), 3, "ERROR: stage record failed"),
                               (SystemExit(143), 143, "TERMINATED by a signal (exit 143)")):
        with tempfile.TemporaryDirectory() as out:
            log = []
            rec = quiet_recording(out, release=True)
            rec.signposts = FakeSource("signposts", log)
            rec.release = ReleaseTrace(fake_trace_cli(out, 'echo "Recording for 1 s" >&2\n: > "$out/app-1.recording.cmxtrace"\n'),
                                       "s", out, 1, chromium=False)
            assert rec.release.start(start_s=10)

            def setup(error=raised):
                raise error
            rec.setup_and_window = setup
            previous = {number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGHUP)}
            try:
                assert rec.record() == code
            finally:
                for number, handler in previous.items():
                    signal.signal(number, handler)
            assert log == ["signposts stop"], log
            done = rec.meta["sources"]["release_trace"]
            assert done["exit"] == 0 and done["files"] == ["app-1.recording.cmxtrace"], done
            text = open(os.path.join(out, "SUMMARY.txt")).read()
            assert line in text, text


def check_xctrace_held_before_start():
    """Review 1: when recorders-start passes its bound inside xctrace's start, the stop path still reaches that
    xctrace (it is held before its process starts) and ends it."""

    class SlowXcTrace:
        made = []

        def __init__(self, out, system_trace=False, cap_s=0):
            self.events, self.attach = [], None
            SlowXcTrace.made.append(self)

        def start(self, hold=contextlib.nullcontext):
            with hold():
                self.events.append("spawned")
            time.sleep(5)  # xctrace waits for an authorization prompt nobody answers

        def interrupt(self):
            self.events.append("interrupt")

        def stop(self):
            self.events.append("stop")
            return False

        def kill(self):
            self.events.append("kill")

    with tempfile.TemporaryDirectory() as out:
        rec = quiet_recording(out, recorder="xctrace")
        rec.xctrace_factory = SlowXcTrace
        try:
            with rec.stages.run("recorders-start", bound=0.3, fatal=True):
                rec.start_xctrace()
        except StageTimeout:
            pass
        assert rec.xc is SlowXcTrace.made[0], (rec.xc, SlowXcTrace.made)
        rec.stop()
        assert rec.xc.events == ["spawned", "interrupt", "stop"], rec.xc.events


def check_wrapped_group_ends():
    """Review 1: a wrapped command that passes the window's bound ends with every process of its group (a
    child it started, as a wrapper starts its app); a group that ignores SIGTERM gets SIGKILL after the grace;
    the run's exit code carries the command's own exit."""
    meta = {}
    stages = Stages(meta, heartbeat_s=60, log=lambda line: None)
    wrapped = WrappedCommand(["/bin/sh", "-c", "sleep 30 & sleep 30"], grace=5)
    started = time.monotonic()
    with stages.run("window", bound=0.5, on_abort=lambda: meta.update(wrapped=wrapped.stop())):
        wrapped.start(hold=stages.hold)
        wrapped.wait()
    assert wrapped.members() == [], f"processes of the wrapped group still run: {wrapped.members()}"
    assert meta["wrapped"]["signalled"] and time.monotonic() - started < 4, meta
    with tempfile.TemporaryDirectory() as scratch:
        ready = os.path.join(scratch, "ready")
        os.mkfifo(ready)
        stubborn = WrappedCommand(["/bin/sh", "-c", 'trap "" TERM; sleep 30 & echo ready > "$0"; wait', ready], grace=0.5,
                                  orphan_grace=0.5)
        stubborn.start()
        with open(ready) as fifo:  # the shell ignores TERM and has started its child once it writes here
            fifo.read()
        record = stubborn.stop()
    assert stubborn.members() == [] and record["killed"], (stubborn.members(), record)
    assert stubborn.stop() is None, "a second stop of an ended group does nothing"
    # Review 2: the command gets SIGTERM first and ends its own teardown (a wrapper's BenchApp.stop quits its app
    # with debug.quit) before the rest of its group (that app) gets SIGTERM.
    with tempfile.TemporaryDirectory() as scratch:
        ready, order = os.path.join(scratch, "ready"), os.path.join(scratch, "order")
        os.mkfifo(ready)
        child = 'trap "echo app-term >> $1; exit 0" TERM; sleep 30 & echo ready > "$0"; wait'
        leader = ('trap "sleep 0.5; echo wrapper-teardown-done >> $1; exit 0" TERM; '
                  '/bin/sh -c \'%s\' "$0" "$1" & wait' % child)
        polite = WrappedCommand(["/bin/sh", "-c", leader, ready, order], grace=5, orphan_grace=5)
        polite.start()
        with open(ready) as fifo:  # the app stand-in has its TERM trap
            fifo.read()
        polite.stop()
        assert open(order).read().split() == ["wrapper-teardown-done", "app-term"], open(order).read()
        assert polite.members() == [], polite.members()
    with tempfile.TemporaryDirectory() as out:
        rec = quiet_recording(out)
        rec.meta.update(timed_out=[], errors=[], command_exit=2)
        assert rec.exit_code() == 2
        rec.meta["command_exit"] = -15
        assert rec.exit_code() == 143
        rec.meta["timed_out"] = ["window"]
        assert rec.exit_code() == 3


FAKE_XCTRACE = r'''
import os, sys, time
args = sys.argv[1:]
mode = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "mode")).read().strip()
if "--toc" in args:
    sys.stdout.write('<?xml version="1.0"?><trace-toc><run number="1"><info><summary><start-date>2026-10-23T10:00:00.250-07:00</start-date></summary></info><data><table schema="time-profile"/><table schema="os-signpost"/></data></run></trace-toc>')
    sys.exit(0)
output = args[args.index("--output") + 1]
if "os-signpost" in args[args.index("--xpath") + 1]:
    open(output, "w").write('<?xml version="1.0"?><trace-query-result><node><schema name="os-signpost"/></node></trace-query-result>')
    sys.exit(0)
open(output, "w").write('<?xml version="1.0"?><trace-query-result><node><row><sample-time>1')  # cut short
if mode == "hang":
    time.sleep(30)
sys.exit(1)
'''


def check_export_part_files():
    """Review 1: a table export that exits nonzero or is killed by the export stage's bound leaves no file (no
    partial XML that a later build or `trace.py export` would reuse); a complete one is kept; a broken table
    left by an older run is skipped by the build, not fatal."""
    with tempfile.TemporaryDirectory() as tools, tempfile.TemporaryDirectory() as out:
        fake = os.path.join(tools, "fake_xctrace.py")
        open(fake, "w").write(FAKE_XCTRACE)
        open(os.path.join(tools, "mode"), "w").write("fail")
        os.makedirs(os.path.join(out, "recording.trace"))
        exported = export_xctrace(out, xctrace=(sys.executable, "-I", fake))
        assert set(exported) == {"os-signpost"}, exported
        leftovers = [f for f in os.listdir(out) if f.endswith(".part.xml") or f == "xctrace-time-profile.xml"]
        assert not leftovers, leftovers
        open(os.path.join(tools, "mode"), "w").write("hang")
        meta = {}
        stages = Stages(meta, heartbeat_s=60, log=lambda line: None)
        with stages.run("export", bound=1.0):
            export_xctrace(out, xctrace=(sys.executable, "-I", fake))
        assert meta["timed_out"] == ["export"], meta
        leftovers = [f for f in os.listdir(out) if f.endswith(".part.xml") or f == "xctrace-time-profile.xml"]
        assert not leftovers, leftovers
        # An older run's broken table: the build skips it and says so.
        open(os.path.join(out, "xctrace-time-profile.xml"), "w").write('<?xml version="1.0"?><trace-query-result><node><row>')
        summary = build(out)
        assert "time-profile" in summary["sources"]["unreadable_tables"], summary["sources"]
        assert "xctrace table time-profile skipped" in summary_text(summary)
        os.unlink(os.path.join(out, "xctrace-time-profile.xml"))
        # Review 2: the run keeps recording.trace (the only source of the missing table) after a failed table
        # export, so `trace.py export DIR` can export it again; the summary names the missing table.
        open(os.path.join(tools, "mode"), "w").write("fail")
        assert missing_tables(out) == ["time-profile"], missing_tables(out)
        rec = quiet_recording(out, recorder="xctrace")
        rec.xctrace_tool = (sys.executable, "-I", fake)
        rec.meta.update(stages=[], timed_out=[], errors=[])
        summary = rec.finish()
        assert os.path.isdir(os.path.join(out, "recording.trace")), "recording.trace was removed after a failed export"
        assert any("recording.trace is kept" in w for w in rec.meta["warnings"]), rec.meta["warnings"]
        assert "xctrace tables not exported: time-profile" in open(os.path.join(out, "SUMMARY.txt")).read()


def check_xctrace_clock():
    """Review 1: the xctrace clock from matched signposts; a count mismatch falls back to the start date and
    says why; the start date's precision comes from its digits; the recorder start is the last resort; a
    string column given only as fmt still reads."""
    xc = [(1_000_000 * i, "action.perform", "Begin", i) for i in (1, 2, 3)]
    log = [{"name": "action.perform", "start_us": 1000.0 * i + 5000.0} for i in (1, 2, 3)]
    offset, how, warning = xctrace_offset_us(xc, {}, log, {})
    assert offset == 5000.0 and how.startswith("signposts (3 matched") and warning is None, (offset, how, warning)
    wall = 1_800_000_000.0
    meta = {"xctrace": {"started_us": 1e6, "started_wall": wall}}
    from datetime import datetime, timezone
    date = datetime.fromtimestamp(wall - 0.5, timezone.utc).isoformat(timespec="milliseconds")
    offset, how, warning = xctrace_offset_us(xc, {"start_date": date}, log[:2], meta, {"rows": 3, "columns": ["name"]})
    assert abs(offset - 500000.0) < 1 and how == "start date (about 1 ms)", (offset, how)
    assert warning and "counts differ: action.perform 3 vs 2" in warning, warning
    whole = datetime.fromtimestamp(wall - 1, timezone.utc).isoformat(timespec="seconds")
    assert xctrace_offset_us(None, {"start_date": whole}, log, meta)[1:] == ("start date (about 1 s)", None)
    assert xctrace_offset_us(None, {}, log, meta)[:2] == (1e6, "recorder start (about 100 ms)")
    with tempfile.TemporaryDirectory() as out:
        path = os.path.join(out, "sp.xml")
        open(path, "w").write(
            '<?xml version="1.0"?><trace-query-result><node><schema name="os-signpost"/>'
            f'<row><time id="1">7000</time><event-type id="2" fmt="Begin"/><name id="3" fmt="action.perform"/>'
            f'<subsystem id="4" fmt="{SUBSYSTEM}"/></row>'
            '<row><time>8000</time><event-type ref="2"/><name ref="3"/><subsystem id="5" fmt="com.apple.other"/></row>'
            '</node></trace-query-result>')
        stats = {}
        assert xctrace_signposts(path, stats) == [(7000, "action.perform", "Begin", None)], stats
        assert stats["rows"] == 2 and stats["cmux_rows"] == 1 and "subsystem" in stats["columns"], stats
        # Review 2: cells keyed by the schema's mnemonics in column order, not by their tag (the engineering
        # type): two `string` columns stay apart, and a `<sentinel/>` (an empty cell) keeps the order.
        open(path, "w").write(
            '<?xml version="1.0"?><trace-query-result><node><schema name="os-signpost">'
            '<col><mnemonic>time</mnemonic><engineering-type>event-time</engineering-type></col>'
            '<col><mnemonic>event-type</mnemonic><engineering-type>string</engineering-type></col>'
            '<col><mnemonic>identifier</mnemonic><engineering-type>uint64</engineering-type></col>'
            '<col><mnemonic>subsystem</mnemonic><engineering-type>string</engineering-type></col>'
            '<col><mnemonic>name</mnemonic><engineering-type>string</engineering-type></col></schema>'
            '<row><event-time id="1">9000</event-time><string id="2">Begin</string><sentinel/>'
            f'<string id="3">{SUBSYSTEM}</string><string id="4">action.commit</string></row>'
            '</node></trace-query-result>')
        assert xctrace_signposts(path) == [(9000, "action.commit", "Begin", None)], list(xctrace_rows(path))


def check_cef_validity():
    """Review 1: debug.cef always carries `unavailable: null` and `fallback: null`, so a healthy reply is valid; a fallback, an unavailable reason or a state other than ready is not."""
    healthy = {"state": "ready", "unavailable": None, "fallback": None, "pump": {"long_work_runs": 0},
               "default_engine": "chromium"}
    assert cef_validity(healthy) == {"valid": True, "problems": [], "state": "ready",
                                     "excerpt": json.dumps(healthy)[:400]}, cef_validity(healthy)
    fallback = dict(healthy, fallback={"count": 2, "reason": "startFailed", "source": "newTab", "notified": True})
    assert not cef_validity(fallback)["valid"] and "WebKit fallbacks" in cef_validity(fallback)["problems"][0]
    assert not cef_validity(dict(healthy, unavailable="downloading"))["valid"]
    assert not cef_validity(dict(healthy, state="idle"))["valid"]
    assert not cef_validity({"error": "timed out"})["valid"]
    assert "chromium valid: True" in summary_text({"cef": cef_validity(healthy)})
    assert "chromium valid: False (WebKit fallbacks" in summary_text({"cef": cef_validity(fallback)})


def check_bound_inside_a_swallowing_wait():
    """Review 2: the build stages spend their time in perf-stress-session.py's `wait()`, whose predicate runs
    under `except Exception`. The bound must still end the stage at its bound there (StageTimeout is a
    BaseException), not after the sum of the inner timeouts."""
    meta = {}
    stages = Stages(meta, heartbeat_s=60, log=lambda line: None)
    started = time.monotonic()
    with stages.run("stress-build", bound=0.3):
        stress_lib.wait(lambda: time.sleep(5), 30)
    assert time.monotonic() - started < 2, f"the stage ran {time.monotonic() - started:.1f} s past its 0.3 s bound"
    assert meta["timed_out"] == ["stress-build"], meta


def check_signal_after_the_stop():
    """Review 2: a SIGTERM during the export or the build (after the recorders and the app stopped) ends the run
    then, with exit 128 + N, instead of waiting for the export and build and exiting 0 or 3."""
    with tempfile.TemporaryDirectory() as out:
        rec = quiet_recording(out, recorder="xctrace")
        rec.setup_and_window = lambda: None
        exported = []

        def finish():
            os.kill(os.getpid(), signal.SIGTERM)  # a fleet cancel while the export runs
            exported.append("went on past the signal")
            return None
        rec.finish = finish
        previous = {number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGHUP)}
        try:
            code = rec.record()
        finally:
            for number, handler in previous.items():
                signal.signal(number, handler)
        assert code == 128 + signal.SIGTERM and not exported, (code, exported)
        assert read_json(os.path.join(out, "summary.json"))["exit_code"] == 128 + signal.SIGTERM
        rec.meta["errors"] = [{"stage": "x", "error": "y"}]
        assert rec.exit_code() == 128 + signal.SIGTERM, "a signal's exit code wins over 3"


FAKE_XCTRACE_RECORD = r"""
import os, signal, sys, time
log, saving = sys.argv[1], sys.argv[3]
count = []

def on_int(_signum, _frame):
    count.append(1)
    open(log, "a").write("SIGINT\n")
    if len(count) > 1:
        open(log, "a").write("ABORTED THE SAVE\n")
        sys.exit(2)
signal.signal(signal.SIGINT, on_int)
print("Starting recording", flush=True)
while not count:
    signal.pause()
with open(saving, "w") as fifo:  # tells the test the first SIGINT was handled and the save began
    fifo.write("saving")
time.sleep(1.0)  # processes and saves the recording; a second Ctrl-C here aborts it
os.makedirs(sys.argv[2], exist_ok=True)
open(log, "a").write("saved\n")
"""


def check_xctrace_gets_one_sigint():
    """Review 2: the stop path ends the recording at the window's end and waits for the save minutes later; the
    stand-in xctrace aborts its save on a second SIGINT, as Ctrl-C twice may, so it must get exactly one."""
    with tempfile.TemporaryDirectory() as tools, tempfile.TemporaryDirectory() as out:
        fake = os.path.join(tools, "fake_xctrace_record.py")
        open(fake, "w").write(FAKE_XCTRACE_RECORD)
        log, saving = os.path.join(tools, "log"), os.path.join(tools, "saving")
        os.mkfifo(saving)
        xc = XcTrace(out)
        xc.command = lambda: [sys.executable, "-I", fake, log, xc.path, saving]
        xc.start(timeout=10)
        xc.interrupt()  # the xctrace-end stage
        with open(saving) as fifo:  # the stand-in handled that SIGINT and is inside its save
            fifo.read()
        assert xc.stop(timeout=10), open(log).read()
        assert open(log).read().split() == ["SIGINT", "saved"], open(log).read()


def check_synthetic_tids_fit_uint32():
    """Review 2: Perfetto's JSON importer reads pid and tid as uint32; a synthetic track id over it falls back
    onto the process track, where slices of different tracks overlap and are dropped. Every pid and tid in a
    built trace fits in 31 bits, and no synthetic track takes an id an OS thread uses."""
    tracks = SyntheticTracks({SYNTHETIC_TID_BASE, SYNTHETIC_TID_BASE + 1})
    assert tracks.tid(1, "a") == SYNTHETIC_TID_BASE + 2 and tracks.tid(1, "a") == SYNTHETIC_TID_BASE + 2
    assert tracks.tid(1, "b") == SYNTHETIC_TID_BASE + 3 and tracks.tid(2, "a") == SYNTHETIC_TID_BASE + 4
    with tempfile.TemporaryDirectory() as out:
        build_fixture(out)
        with gzip.open(os.path.join(out, "trace.json.gz"), "rt") as f:
            trace = json.load(f)
        ids = [(e.get("name"), key, e[key]) for e in trace["traceEvents"] for key in ("pid", "tid") if key in e]
        over = [x for x in ids if not (isinstance(x[2], int) and 0 <= x[2] < 1 << 31)]
        assert not over, over[:6]
        synthetic = {e["tid"] for e in trace["traceEvents"] if e.get("cat") in ("watchdog", "daemon.spans", "driver")
                     or str(e.get("cat", "")).startswith("signpost.")}
        assert synthetic and not synthetic & {26, 259}, synthetic


def check_cli_named_cmux_is_not_the_app():
    """Review 2: the bundled CLI's process is named `cmux`; a storm's CLI processes are in no ps snapshot. In
    wrap mode (no app pid in meta) a CLI process sampled before the app must not become the app: the app is
    the process that emitted the action signposts, and the CLI's CPU counts as `cli`."""
    assert role_from_name("cmux") == "cli" and role_from_name("cmux DEV trc") == "app"
    with tempfile.TemporaryDirectory() as out:
        cli = TP_XML.replace("Main Thread  0x1a (cmux DEV, pid: 42)", "Main Thread  0x2b (cmux, pid: 7)") \
            .replace('fmt="cmux DEV (42)"><pid id="5" fmt="42">42</pid>', 'fmt="cmux (7)"><pid id="5" fmt="7">7</pid>') \
            .replace('fmt="0x1a">26</tid>', 'fmt="0x2b">43</tid>')
        app = TP_XML.replace('id="', 'id="a')
        app = app.replace('ref="', 'ref="a')
        rows = lambda xml: xml.split('<schema name="time-profile"/>', 1)[1].rsplit("</node>", 1)[0]
        open(os.path.join(out, "xctrace-time-profile.xml"), "w").write(
            '<?xml version="1.0"?><trace-query-result><node xpath="x"><schema name="time-profile"/>'
            + rows(cli) + rows(app) + "</node></trace-query-result>")
        open(os.path.join(out, "signposts.ndjson"), "w").write(signposts_lib.SAMPLE.replace('"processID":1', '"processID":42'))
        write_json(os.path.join(out, "meta.json"), {"scenario": "wrap", "window_start_us": 0.0, "window_end_us": 9e6})
        summary = build(out)
        assert summary["sources"]["app_pid"] == 42 and summary["sources"]["app_pid_from"] == "action signposts", summary["sources"]
        assert summary["cpu_s_by_role"].get("cli") and summary["actions"].get("tab.new"), summary


def check_refuses_a_running_bundle():
    """Review 2: the stop path ends the bundle's processes and cannot tell this run's from older ones, so a run
    whose bundle already has a process (another job's app or daemons, a person's app) refuses to start and
    signals nothing."""
    with tempfile.TemporaryDirectory() as scratch, tempfile.TemporaryDirectory() as out:
        bundle = os.path.realpath(os.path.join(scratch, "cmux DEV other.app"))
        os.makedirs(os.path.join(bundle, "Contents/Resources/bin"))
        other = subprocess.Popen([os.path.join(bundle, "Contents/Resources/bin/cmux-tui"), "30"], executable="/bin/sleep")
        try:
            meta = {"host": "self-test", "scenario": "self-test", "sources": {}, "warnings": []}
            rec = Recording(fake_opts(command=["/usr/bin/true"]), out, meta, Stages(meta, 60, lambda line: None),
                            bundle, "sample")
            previous = {number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGHUP)}
            try:
                code = rec.record()
            finally:
                for number, handler in previous.items():
                    signal.signal(number, handler)
            assert code == 3 and "bundle-in-use" in meta["errors"][0]["error"], meta["errors"]
            assert rec.wrapped is None and other.poll() is None, "a process this run did not start was signalled"
            assert other.pid in rec.processes["before"], rec.processes
            text = open(os.path.join(out, "SUMMARY.txt")).read()
            assert "no window (it never started)" in text, text
        finally:
            other.kill()
            other.wait()


def check_import_with_a_fake_trace_processor():
    """check_import counts what the JSON importer must make and compares it with what trace_processor_shell
    reports: a track with a dropped slice, an importer stat and a missing track each fail it."""
    with tempfile.TemporaryDirectory() as out:
        events = [{"ph": "M", "pid": 1, "tid": 7, "name": "thread_name", "args": {"name": "signposts action"}},
                  {"ph": "M", "pid": 1, "tid": 8, "name": "thread_name", "args": {"name": "watchdog stalls"}},
                  {"ph": "M", "pid": 2, "tid": 9, "name": "thread_name", "args": {"name": "daemon spans"}},
                  {"ph": "M", "pid": 1, "tid": 5, "name": "thread_name", "args": {"name": "Main Thread"}},
                  {"ph": "X", "pid": 1, "tid": 7, "ts": 1, "dur": 2, "name": "a"},
                  {"ph": "X", "pid": 1, "tid": 7, "ts": 1, "dur": 1, "name": "b"},
                  {"ph": "i", "s": "t", "pid": 1, "tid": 8, "ts": 1, "name": "c"},
                  {"ph": "i", "s": "g", "pid": 1, "tid": 8, "ts": 1, "name": "global"},
                  {"ph": "X", "pid": 2, "tid": 9, "ts": 1, "dur": 2, "name": "d"},
                  {"ph": "X", "pid": 1, "tid": 5, "ts": 1, "dur": 2, "name": "e"},
                  # One EventLatency slot whose dispatch stage opens the arrow into a two-hop key.flow chain: 2 arrows.
                  {"ph": "M", "pid": 1, "tid": 10, "name": "thread_name", "args": {"name": "input latency"}},
                  {"ph": "M", "pid": 1, "tid": 11, "name": "thread_name", "args": {"name": "key flow"}},
                  {"ph": "X", "pid": 1, "tid": 10, "ts": 10, "dur": 8, "name": "EventLatency keyPress terminal",
                   "cat": "input.latency"},
                  {"ph": "X", "pid": 1, "tid": 10, "ts": 10, "dur": 1, "name": "GeneratedToDispatchStart",
                   "cat": "input.latency.stage", "bind_id": "0x1", "flow_out": True},
                  {"ph": "X", "pid": 1, "tid": 10, "ts": 11, "dur": 7, "name": "DispatchStartToPresented",
                   "cat": "input.latency.stage"},
                  {"ph": "X", "pid": 1, "tid": 11, "ts": 11, "dur": 2, "name": "app.key.dispatch", "cat": "key.flow",
                   "bind_id": "0x1", "flow_in": True, "flow_out": True},
                  {"ph": "X", "pid": 1, "tid": 11, "ts": 13, "dur": 1, "name": "app.key.terminal", "cat": "key.flow",
                   "bind_id": "0x1", "flow_in": True},
                  # A ring thread's slice and the flow record inside it (ring_events).
                  {"ph": "M", "pid": 2, "tid": 12, "name": "thread_name", "args": {"name": "ring main"}},
                  {"ph": "X", "pid": 2, "tid": 12, "ts": 20, "dur": 4, "name": "daemon.request", "cat": "ring"},
                  {"ph": "i", "s": "t", "pid": 2, "tid": 12, "ts": 21, "name": "key.echo.line_out", "cat": "ring.flow"}]
        with gzip.open(os.path.join(out, "trace.json.gz"), "wt") as f:
            json.dump({"traceEvents": events}, f)
        fake = os.path.join(out, "trace_processor_shell")

        def write_fake(track_rows, stat_rows, flow_rows='"flows"\n2\n'):
            with open(fake, "w") as f:
                f.write("#!/bin/sh\n"
                        "if grep -q 'from stats' \"$2\"; then cat <<'EOF'\n" + stat_rows + "EOF\n"
                        "elif grep -q 'from flow' \"$2\"; then cat <<'EOF'\n" + flow_rows + "EOF\n"
                        "else cat <<'EOF'\n" + track_rows + "EOF\nfi\n")
            os.chmod(fake, 0o755)

        header = 'Loading trace: 0.01 MB\n"pid","tid","name","slices"\n'
        good = header + ('1,7,"signposts action",2\n1,8,"watchdog stalls",1\n2,9,"daemon spans",1\n1,5,"Main Thread",1\n'
                         '1,10,"input latency",3\n1,11,"key flow",2\n2,12,"ring main",2\n')
        no_stats = '"name","idx","severity","source","value"\n'
        write_fake(good, no_stats)
        ok, report = check_import(out, fake)
        assert ok and report["tracks_by_kind"] == {"signposts": 1, "watchdog stalls": 1, "daemon spans": 1, "key flow": 1,
                                                   "input latency": 1, "ring": 1}, report
        assert report["flows"] == {"json": 2, "imported": 2}, report["flows"]
        write_fake(good, no_stats, '"flows"\n1\n')
        ok, report = check_import(out, fake)
        assert not ok and report["problems"] == ["2 key-flow and input-latency arrows in the JSON, 1 imported"], report
        write_fake(good.replace('"input latency",3', '"input latency",2'), no_stats)
        ok, report = check_import(out, fake)
        assert not ok and "input latency: 3 slices in the JSON, 2 imported" in report["problems"][0], report["problems"]
        write_fake(good.replace('"signposts action",2', '"signposts action",1'), no_stats)
        ok, report = check_import(out, fake)
        assert not ok and "2 slices in the JSON, 1 imported" in report["problems"][0], report["problems"]
        write_fake(good, no_stats + '"json_parser_failure","[NULL]","error","trace",3\n')
        ok, report = check_import(out, fake)
        assert not ok and "json_parser_failure" in report["problems"][0], report["problems"]
        write_fake(good.replace('2,9,"daemon spans",1\n', ""), no_stats)
        ok, report = check_import(out, fake)
        assert not ok and "daemon spans (pid 2 tid 9) is not a thread" in report["problems"][0], report["problems"]


# The `key.flow` hops TypingLatencyProbe emits for one terminal key press, in order (Mark.hop for the marks,
# keyReachedTerminal() in TerminalSurfaceView.keyDown, closeAtCommit's app.frame.commit). app.key.dispatched
# and app.key.commit are emitted too and are not FLOW_HOPS: the assembly must ignore them.
APP_KEY_HOPS = ("app.key.dispatch", "app.key.terminal", "app.key.dispatched", "app.key.commit", "app.io_write", "app.send")
APP_ECHO_HOPS = ("app.output.decoded", "app.output.received", "app.output.parsed", "app.frame.contents", "app.frame.commit")


def flow_fixture_event(flow, hop, at, tid=1):
    """One app `key.flow` signpost event as read_signposts gives it."""
    return {"name": "key.flow", "pid": 10, "tid": tid, "at_us": at, "message": f"hop={hop} flow={flow} age_us=5"}


def flow_fixture_record(hop, at, flow=0, terminal="aa", pid=20):
    """One daemon/host/holder flow record as read_flow_records gives it."""
    return {"hop": hop, "flow": flow, "terminal": terminal, "pid": pid, "tid": 7, "at_us": at}


def check_key_flows():
    """A press through the host model and one through the holder model assemble into complete chains on one
    clock, the flow-0 hops of a busy other terminal never join them, a press whose echo never came back is
    incomplete and names its missing hops, and the chain becomes hop slices joined by n - 1 flow arrows."""
    app, rec = flow_fixture_event, flow_fixture_record
    a, b, c = (10 << 32) | 1, (10 << 32) | 2, (10 << 32) | 3
    app_events = []
    for flow, base in ((a, 1000.0), (b, 5000.0), (c, 9000.0)):
        for i, hop in enumerate(APP_KEY_HOPS):
            app_events.append(app(flow, hop, base + i))
    for flow, base in ((a, 1100.0), (b, 5100.0)):
        for i, hop in enumerate(APP_ECHO_HOPS):
            app_events.append(app(flow, hop, base + 10 * i))
    records = [
        # Press a: the __terminal-host model (the daemon's written mark before the host's write: no order needed).
        rec("daemon.send.write", 1010, a), rec("daemon.send.written", 1012, a), rec("host.pty.write", 1015, pid=30),
        rec("host.pty.read", 1040, pid=30), rec("daemon.output.host", 1050), rec("daemon.output.attach", 1060),
        # A busy other terminal: its reads must never join.
        rec("host.pty.read", 1020, terminal="bb", pid=31), rec("daemon.output.host", 1021, terminal="bb"),
        # Press b: the holder model.
        rec("daemon.send.write", 5010, b), rec("daemon.pty.write", 5011), rec("daemon.send.written", 5012, b),
        rec("holder.pty.read", 5030, pid=40), rec("daemon.output.holder", 5040), rec("daemon.output.attach", 5050),
        # Press c: sent, written, never echoed.
        rec("daemon.send.write", 9010, c), rec("host.pty.write", 9015, pid=30), rec("daemon.send.written", 9016, c),
    ]
    chord = (10 << 32) | 9  # a chord the key router ran: dispatched, never at a terminal
    for i, hop in enumerate(("app.key.dispatch", "app.key.dispatched", "app.key.commit")):
        app_events.append(app(chord, hop, 7000.0 + i))
    flows = assemble_flows(app_events, records)
    by = {f["flow"]: f for f in flows}
    assert chord not in by, "a press that never reached a terminal was counted as a flow"
    assert by[a]["complete"] and by[b]["complete"], [(hex(f["flow"]), f["missing"]) for f in flows]
    hops_a = [h["hop"] for h in by[a]["hops"]]
    assert "host.pty.read" in hops_a and by[a]["hops"][hops_a.index("host.pty.read")]["pid"] == 30, by[a]
    assert all(h["at_us"] != 1020 and h["at_us"] != 1021 for h in by[a]["hops"]), "the busy terminal's output joined"
    assert "holder.pty.read" in [h["hop"] for h in by[b]["hops"]], by[b]
    assert not by[c]["complete"] and "host.pty.read|holder.pty.read" in by[c]["missing"], by[c]["missing"]
    assert [h["at_us"] for h in by[a]["hops"]] == sorted(h["at_us"] for h in by[a]["hops"])
    names = {}
    events = flow_events(flows, SyntheticTracks(set()), names)
    chain = [e for e in events if e["bind_id"] == f"0x{a:x}"]
    assert len(chain) == len(by[a]["hops"]) == 15, len(chain)
    assert sum(1 for e in chain if e.get("flow_out")) == 14 and sum(1 for e in chain if e.get("flow_in")) == 14
    assert not chain[0].get("flow_in") and not chain[-1].get("flow_out")
    assert set(names.values()) == {"key flow"}, names
    summary = flow_summary(flows, {})
    assert summary["presses"] == 3 and summary["complete"] == 2, summary
    rows = flow_percentiles(flows)
    assert rows["key_to_commit_ms"]["terminal"]["n"] == 2 and rows["hop_ms"]["terminal"]["daemon.send.write"]["n"] == 2, rows



def check_flow_hops_are_exclusive():
    """Keys typed faster than their echo (the Typist sends one every 0.12 s and does not wait; the STRESS tail
    echoes slower): no flow-0 record joins two presses; a press whose window (its anchor up to the next press's
    anchor on the same terminal) holds no candidate or two is incomplete; and a lone candidate that the press
    before may still own (it found none in its own window) does not complete the later press."""
    app, rec = flow_fixture_event, flow_fixture_record
    p1, p2, p3, p4 = ((10 << 32) | n for n in (1, 2, 3, 4))
    app_events = []
    for flow, base in ((p1, 1000.0), (p2, 1120.0), (p3, 3000.0), (p4, 3120.0)):
        for i, hop in enumerate(APP_KEY_HOPS):
            app_events.append(app(flow, hop, base + i))
    # The probe closes p1 and p3 unfinished when the next key comes: only p2 and p4 get the app's echo hops.
    for flow, base in ((p2, 1300.0), (p4, 3300.0)):
        for i, hop in enumerate(APP_ECHO_HOPS):
            app_events.append(app(flow, hop, base + 10 * i))
    records = [
        # p1 and p2 are both written before p1's echo comes back; then both echoes come.
        rec("daemon.send.write", 1010, p1), rec("daemon.send.written", 1012, p1), rec("host.pty.write", 1015, pid=30),
        rec("daemon.send.write", 1130, p2), rec("daemon.send.written", 1132, p2), rec("host.pty.write", 1135, pid=30),
        rec("host.pty.read", 1200, pid=30), rec("daemon.output.host", 1202), rec("daemon.output.attach", 1204),
        rec("host.pty.read", 1210, pid=30), rec("daemon.output.host", 1212), rec("daemon.output.attach", 1214),
        # p3's echo comes after p4's write, and p4's echo never comes: the one read is p3's, not p4's.
        rec("daemon.send.write", 3010, p3), rec("host.pty.write", 3015, pid=30),
        rec("daemon.send.write", 3130, p4), rec("host.pty.write", 3135, pid=30),
        rec("host.pty.read", 3200, pid=30), rec("daemon.output.host", 3202), rec("daemon.output.attach", 3204),
    ]
    flows = assemble_flows(app_events, records)
    by = {f["flow"]: f for f in flows}
    assert set(by) == {p1, p2, p3, p4}, [hex(f) for f in by]
    owners = collections.defaultdict(list)
    for entry in flows:
        for hop in entry["hops"]:
            if hop["hop"] in FLOW_ANCHOR:
                owners[(hop["hop"], hop["at_us"])].append(hex(entry["flow"]))
    shared = {key: who for key, who in owners.items() if len(who) > 1}
    assert not shared, f"flow-0 records joined two presses: {shared}"
    assert not any(by[f]["complete"] for f in by), [(hex(f), by[f]["missing"], by[f].get("ambiguous")) for f in by]
    pty_read = "host.pty.read|holder.pty.read"
    # p1: nothing between its write and p2's write. p2: two reads before its decoded output: whose is whose?
    assert pty_read in by[p1]["missing"], by[p1]
    assert (by[p2].get("ambiguous") or {}).get(pty_read, {}).get("candidates") == 2, by[p2]
    # p4: one read in its window, but p3 found none in its own: the read may be p3's.
    assert (by[p4].get("ambiguous") or {}).get(pty_read, {}).get("earlier_unplaced"), by[p4]
    # Each press still owns its write: p2's host.pty.write is 1135, never p1's 1015.
    assert {h["hop"]: h["at_us"] for h in by[p2]["hops"]}.get("host.pty.write") == 1135, by[p2]
    summary = flow_summary(flows, {})
    assert summary["presses"] == 4 and summary["complete"] == 0, summary
    assert flow_percentiles(flows)["key_to_commit_ms"] == {}
    assert any(entry.get("ambiguous") for entry in summary["incomplete"]), summary["incomplete"]
    assert "ambiguous" in summary_text({"key_flows": summary}), summary_text({"key_flows": summary})


def check_flow_gaps_warn():
    """A recording whose presses cannot assemble says why instead of printing nothing: daemon flow records but no
    app key.flow signposts (the app's flow hops are not in the build), presses whose flow id never reached the
    daemon (a `send` without `flow`); and a press with the app's terminal hops but no app.key.terminal is
    reported incomplete, not dropped."""
    app, rec = flow_fixture_event, flow_fixture_record
    # End to end through build(): the daemon's send records (flow 0: no client set `flow`) and no key.flow event.
    with tempfile.TemporaryDirectory() as out:
        os.makedirs(os.path.join(out, "flows"))
        with open(os.path.join(out, "flows", "flows-20.jsonl"), "w") as f:
            for n in range(3):
                for i, hop in enumerate(("daemon.send.write", "host.pty.write", "daemon.send.written")):
                    f.write(json.dumps({"hop": hop, "flow": 0, "terminal": "aa", "pid": 20, "tid": 7,
                                        "t_ns": (1_000_000 + 1000 * n + i) * 1000}) + "\n")
        summary = build_fixture(out)
        warnings = summary["key_flows"].get("warnings") or []
        assert any("key.flow" in w for w in warnings), summary["key_flows"]
        text = open(os.path.join(out, "SUMMARY.txt")).read()
        assert "Key-press flows: 0 presses" in text and "WARNING" in text.split("Key-press flows")[1], text
    # A press that reached Ghostty (app.io_write, app.send) but has no app.key.terminal hop is a press, and the
    # optional hop is not what it misses; a whole chain without it is complete.
    p1, p2 = (10 << 32) | 1, (10 << 32) | 2
    events = [app(p1, hop, 1000.0 + i) for i, hop in enumerate(APP_KEY_HOPS) if hop != "app.key.terminal"]
    events += [app(p1, hop, 1100.0 + 10 * i) for i, hop in enumerate(APP_ECHO_HOPS)]
    records = [rec("daemon.send.write", 1010, p1), rec("host.pty.write", 1015, pid=30),
               rec("daemon.send.written", 1016, p1), rec("host.pty.read", 1040, pid=30), rec("daemon.output.host", 1050),
               rec("daemon.output.attach", 1060)]
    flows = assemble_flows(events, records)
    assert [f["flow"] for f in flows] == [p1] and flows[0]["complete"], flows
    assert flow_percentiles(flows)["key_to_commit_ms"]["terminal"]["n"] == 1
    # Presses whose flow id no daemon record carries: the send had no `flow`, so nothing past the app can join.
    events = [app(p2, hop, 2000.0 + i) for i, hop in enumerate(APP_KEY_HOPS)]
    records = [rec("daemon.send.write", 2010), rec("host.pty.write", 2015)]
    flows = assemble_flows(events, records)
    warnings = flow_warnings(events, records, flows)
    assert any("flow id" in w and "daemon.send.write" in w for w in warnings), warnings
    assert flow_warnings([], [], []) == [], "a recording without flows warns about nothing"


def reference_row(values):
    """pct()'s row from perf_stats.pct, for the self-test (perf-lab/tests/test_perf_stats.py checks pct itself)."""
    quantiles = {"p50": 0.50, "p95": 0.95, "p99": 0.99, "max": 1.0}
    return {"n": len(values), **{key: round(perf_stats.pct(values, q), 2) for key, q in quantiles.items()}}


def check_percentiles():
    """pct() is perf_stats' linear interpolation, rounded to 0.01: fixed vectors (the old nearest-rank pct gave
    50/95/99 and 5/10/10 on the first two) and random samples with ties match it, and an empty sample is None."""
    import random
    assert pct([]) is None
    assert pct(list(range(1, 101))) == {"n": 100, "p50": 50.5, "p95": 95.05, "p99": 99.01, "max": 100}, \
        pct(list(range(1, 101)))
    assert pct(list(range(1, 11))) == {"n": 10, "p50": 5.5, "p95": 9.55, "p99": 9.91, "max": 10}, pct(list(range(1, 11)))
    assert pct([7.0]) == {"n": 1, "p50": 7.0, "p95": 7.0, "p99": 7.0, "max": 7.0}
    rng = random.Random(24)
    for n in (2, 3, 19, 20, 21, 99, 100, 101, 199, 200, 201, 1000):
        values = [round(rng.lognormvariate(1.0, 0.8), 2) for _ in range(n)] + [3.0] * (n // 7)
        row, expected = pct(values), reference_row(values)
        assert row == expected, (n, row, expected)


def complete_press(flow, base, extra=(), moved=None):
    """A press through the host model on terminal `aa` as (app events, records), every hop `base` + a step. `extra`
    adds app hops (name, offset); `moved` gives a hop (by name) another offset, the planted clock error."""
    app, rec = flow_fixture_event, flow_fixture_record
    offsets = dict([(hop, i) for i, hop in enumerate(APP_KEY_HOPS)]
                   + [(hop, 100 + 10 * i) for i, hop in enumerate(APP_ECHO_HOPS)] + list(extra))
    offsets.update(moved or {})
    events = [app(flow, hop, base + offset) for hop, offset in offsets.items()]
    records = [rec("daemon.send.write", base + 10, flow), rec("daemon.send.written", base + 12, flow),
               rec("host.pty.write", base + 15, pid=30), rec("host.pty.read", base + 40, pid=30),
               rec("daemon.output.host", base + 50), rec("daemon.output.attach", base + 60)]
    return events, records


def request_record(flow, ph, at, pid):
    """One daemon request flow record (task 103) as read_flow_records gives it."""
    return {"hop": REQUEST_FLOW_NAME, "ph": ph, "flow": flow, "terminal": "", "pid": pid, "tid": 1, "at_us": at}


def check_clock_order_and_percentiles():
    """Key to commit and key to the estimated present per target match the reference percentiles, and every hop's
    time from its cause is >= 0 on in-order presses (the present from max(commit, gpu_done)); complete presses on
    one clock have 0 clock-order violations, and one planted hop before its cause gives exactly 1 (an app hop, a
    daemon hop carrying the flow id, a present before its commit, a host's PTY write or read off the clock); the
    daemon may read a send before the app's app.send mark; a request whose daemon receive comes before the app's
    send gives 1; request_flow_linked counts the requests another process received."""
    # The app's echo hops are at +100 (decoded) to +130 (contents) and +140 (commit): Ghostty renders between the
    # parse and the contents, the GPU ends after the render, the present is a vsync after the commit.
    frame = (("ghostty.render", 125), ("frame.gpu_done", 128), ("frame.present_estimate", 150))
    events, records = [], []
    for n in range(40):
        # The commit moves with n and the present is 10 to 44 us after it, so the two percentiles differ; on every
        # tenth press the GPU ends after the commit, and the present then follows the GPU.
        commit, present = 140 + n, 150 + n + 17 * (n % 3)
        gpu_done = commit + 5 if n % 10 == 0 else 128
        e, r = complete_press((10 << 32) | (n + 1), 10_000.0 * (n + 1), extra=frame, moved={
            "app.frame.commit": commit, "frame.gpu_done": gpu_done, "frame.present_estimate": present})
        events += e
        records += r
    flows = assemble_flows(events, records)
    assert len(flows) == 40 and all(f["complete"] and f["target"] == KEY_TARGET_TERMINAL for f in flows), \
        [(hex(f["flow"]), f["missing"]) for f in flows if not f["complete"]]
    rows = flow_percentiles(flows)
    commits = [(140 + n) / 1000 for n in range(40)]
    presents = [(150 + n + 17 * (n % 3)) / 1000 for n in range(40)]
    for kind, values in (("key_to_commit_ms", commits), ("key_to_present_estimate_ms", presents)):
        row, expected = rows[kind]["terminal"], reference_row(values)
        assert row == expected, (kind, row, expected)
    hops = rows["hop_ms"]["terminal"]
    handoffs = RING_HOPS - {"ghostty.render", "frame.gpu_done", "frame.present_estimate"}
    assert set(hops) == {hop for alternatives in FLOW_HOPS[1:] for hop in alternatives[:1]} - handoffs, \
        sorted(hops)
    negative = {hop: row for hop, row in hops.items() if min(row[key] for key in ("p50", "p95", "p99", "max")) < 0}
    assert not negative, negative
    steps = [dict(press_latencies(entry)[0]) for entry in flows]
    assert min(min(s.values()) for s in steps) >= 0, steps
    # The present counts from the later of the commit and the GPU's end: 10 us after the commit at +140 (n = 0,
    # gpu_done +145: 5 us after it), and the GPU from the render.
    assert steps[0]["frame.present_estimate"] == 0.005 and steps[1]["frame.present_estimate"] == 0.027, steps[:2]
    assert steps[1]["frame.gpu_done"] == 0.003 and steps[1]["app.frame.contents"] == 0.005, steps[1]
    # One step per hop: the daemon's write counts from the app's io_write, as does the app's own send mark.
    assert steps[1]["daemon.send.write"] == 0.006 and steps[1]["app.send"] == 0.001, steps[1]
    report = clock_report(flows, [])
    assert report["clock_order_violations"] == 0 and report["clock_order"]["checked_presses"] == 40, report
    assert set(flow_summary(flows, {})) >= {"presses", "complete", "incomplete"}
    assert not set(flow_summary(flows, {})) & set(rows), "flow_summary repeats flow_percentiles' rows"
    # A press without the Release ring's frame hops is still complete, with no present.
    e, r = complete_press((10 << 32) | 99, 900_000.0)
    lone = assemble_flows(e, r)
    assert lone[0]["complete"] and flow_percentiles(lone)["key_to_present_estimate_ms"] == {"terminal": None}
    # Per target: rows are keyed by each press's target (only terminal presses assemble today).
    other = dict(lone[0], target="chromiumPage")
    assert sorted(flow_percentiles(lone + [other])["key_to_commit_ms"]) == ["chromiumPage", "terminal"]
    # The app's send mark comes after its socket write returns: the daemon may read and stamp first.
    e, r = complete_press((10 << 32) | 6, 50_000.0, moved={"app.send": 30})
    assert clock_order_violations(assemble_flows(e, r), []) == []
    # Planted: one hop before its cause, each kind on its own press.
    planted = [
        ({"app.output.parsed": 105}, "app.output.parsed"),  # parsed (105) before received (110)
        ({"app.send": -5}, "app.send"),  # the app's send before its io_write (+4)
        ({"frame.present_estimate": 130}, "frame.present_estimate"),  # shown before the commit (140) and the GPU
    ]
    for moved, hop in planted:
        e, r = complete_press((10 << 32) | 7, 50_000.0, extra=frame, moved=moved)
        found = clock_order_violations(assemble_flows(e, r), [])
        assert len(found) == 1 and found[0]["hop"] == hop and found[0]["kind"] == "key", (hop, found)
    e, r = complete_press((10 << 32) | 8, 50_000.0)
    r[0]["at_us"] = 50_000.0 + 1  # the daemon's daemon.send.write (flow id) 3 us before the app's io_write (+4)
    found = clock_order_violations(assemble_flows(e, r), [])
    assert [v["hop"] for v in found] == ["daemon.send.write"] and found[0]["pid"] == 20, found
    # A host off the clock: its flow-0 record lands before its cause, so no window holds it; it is still 1.
    for index, at, cause in ((2, 5, "daemon.send.write"), (3, 12, "host.pty.write")):
        e, r = complete_press((10 << 32) | 9, 50_000.0)
        r[index]["at_us"] = 50_000.0 + at
        press = assemble_flows(e, r)
        found = clock_order_violations(press, [])
        assert not press[0]["complete"] and [(v["hop"], v["before"][0]["hop"]) for v in found] == \
            [(r[index]["hop"], cause)], (r[index]["hop"], found)
        report = clock_report(press, [])
        assert report["clock_order"]["checked_presses"] == 0 and report["clock_order"]["unchecked_presses"] == 1
    # Requests: a round trip, one the daemon never received, and one received before it was sent.
    app_pid, daemon_pid = 10, 20
    requests = [request_record(1, "s", 100, app_pid), request_record(1, "f", 110, daemon_pid),
                request_record(1, "s", 120, daemon_pid), request_record(1, "f", 130, app_pid),
                request_record(2, "s", 200, app_pid),
                request_record(3, "s", 300, app_pid), request_record(3, "f", 290, daemon_pid)]
    found = clock_order_violations([], requests)
    assert len(found) == 1 and found[0]["kind"] == "request" and found[0]["flow"] == "0x3", found
    linked = request_flow_summary(requests)
    assert linked["request_flow_linked"] == 66.7 and linked["request_flows"]["round_trips"] == 1, linked
    assert linked["request_flows"]["unlinked"] == ["0x2"], linked
    assert request_flow_summary([])["request_flow_linked"] is None


def key_flow_ndjson(events):
    """flow_fixture_event events as `log stream --signpost --style ndjson` writes them (timebase 1/1: the
    machTimestamp is ns; no sleep since boot), for read_signposts."""
    lines = ["#timebase 1/1", "#continuous-minus-uptime-us 0"]
    for index, event in enumerate(events):
        lines.append(json.dumps({"eventType": "signpostEvent", "subsystem": "com.cmuxterm.app.next", "category": "keyFlow",
                                 "signpostName": "key.flow", "signpostID": 200 + index, "signpostType": "event",
                                 "processID": event["pid"], "threadID": event["tid"],
                                 "machTimestamp": int(event["at_us"] * 1000), "eventMessage": event["message"]}))
    return "\n".join(lines) + "\n"


def check_clock_command():
    """`check-clock DIR` reads DIR as build() does (load_flow_inputs): exit 1 with a planted out-of-order request
    or a key press whose host wrote the PTY before the daemon's send, 0 when every hop follows its cause, 2 with
    nothing to check; a ring-only (Release) recording's requests are checked too; build() writes the same fields
    into summary.json, once."""
    def write(out, rows, keys=()):
        os.makedirs(os.path.join(out, "flows"), exist_ok=True)
        with open(os.path.join(out, "flows", "flows-20.jsonl"), "w") as f:
            for flow, ph, at, pid in rows:
                f.write(json.dumps({"hop": REQUEST_FLOW_NAME, "ph": ph, "flow": flow, "pid": pid, "tid": 1,
                                    "t_ns": int(at * 1000)}) + "\n")
            for record in keys:
                f.write(json.dumps({"hop": record["hop"], "flow": record["flow"], "terminal": record["terminal"],
                                    "pid": record["pid"], "tid": record["tid"], "t_ns": int(record["at_us"] * 1000)}) + "\n")
    good = [(1, "s", 1000, 10), (1, "f", 1010, 20), (1, "s", 1020, 20), (1, "f", 1030, 10)]
    with tempfile.TemporaryDirectory() as out:
        assert check_clock(out)[0] == 2
        write(out, good)
        code, report = check_clock(out)
        assert code == 0 and report["clock_order"]["checked_requests"] == 1, report
        # A key press in order, then the same press with its host's PTY write before the daemon's send.
        events, records = complete_press((10 << 32) | 1, 5000.0)
        open(os.path.join(out, "signposts.ndjson"), "w").write(key_flow_ndjson(events))
        write(out, good, records)
        code, report = check_clock(out)
        assert code == 0 and report["clock_order"]["checked_presses"] == 1, report
        records[2]["at_us"] = 5000.0 + 5
        write(out, good, records)
        code, report = check_clock(out)
        assert code == 1 and [v["hop"] for v in report["clock_order"]["violations"]] == ["host.pty.write"], report
        write(out, good + [(2, "s", 2000, 10), (2, "f", 1990, 20)])
        os.remove(os.path.join(out, "signposts.ndjson"))
        command = subprocess.run([sys.executable, os.path.abspath(__file__), "check-clock", out],
                                 capture_output=True, text=True, timeout=60)
        assert command.returncode == 1 and "1 violation(s)" in command.stdout, (command.returncode, command.stdout,
                                                                                 command.stderr[-600:])
        assert read_json(os.path.join(out, "clock-check.json"))["clock_order_violations"] == 1
        summary = build_fixture(out)
        assert summary["clock_order_violations"] == 1 and summary["request_flow_linked"] == 100.0, \
            {k: summary.get(k) for k in ("clock_order_violations", "request_flow_linked", "request_flows")}
        assert "key_to_present_estimate_ms" in summary and "key_to_commit_ms" in summary and "hop_ms" in summary
        assert not {"key_to_commit_ms", "key_to_present_estimate_ms", "hop_ms"} & set(summary["key_flows"])
        assert summary["key_flows"]["presses"] == 0, "a request's flow records were read as a key press's"
        assert "Clock order: 1 hop(s)" in open(os.path.join(out, "SUMMARY.txt")).read()
    # A Release recording: no signposts and no flows/ files, only the rings (023's read_rings shape).
    ring_record = lambda phase, flow, t_us: {"phase": phase, "name": REQUEST_FLOW_NAME, "t_ns": int(t_us * 1000),
                                             "arg0": 0, "arg1": flow, "thread": (1, 0), "flags": 0}
    rings = [{"info": {"pid": 10, "role": "app"}, "threads": {},
              "records": [ring_record("s", 5, 100), ring_record("f", 5, 130)]},
             {"info": {"pid": 20, "role": "daemon"}, "threads": {},
              "records": [ring_record("f", 5, 90), ring_record("s", 5, 120),
                          {**ring_record("I", 0, 95), "name": "daemon.request"}]}]
    with tempfile.TemporaryDirectory() as out:
        code, report = check_clock(out, rings)
        assert code == 1 and report["clock_order"]["checked_requests"] == 1, report
        assert [(v["kind"], v["pid"]) for v in report["clock_order"]["violations"]] == [("request", 20)], report
        rings[1]["records"][0]["t_ns"] = 110_000
        assert check_clock(out, rings)[0] == 0
        assert request_flow_summary(load_flow_inputs(out, read_signposts(""), rings)[2])["request_flow_linked"] == 100.0


def check_focus_quiet_terminal():
    """The keys move to a quiet terminal and the summary names both panes; a focus that fails or raises is a
    warning, never the end of the build (review of flows3)."""
    class FakeStress:
        def __init__(self, focus_raises=False, focus_moves=True):
            self.busy, self.measured, self.focus = ["t1"], "w", "p1"
            self.focus_raises, self.focus_moves = focus_raises, focus_moves

        def topology(self):
            return {"focus": {"pane": self.focus}}

        def workspace(self, _id):
            return {}

        def panes(self, _workspace):
            return [{"id": "p1", "tabs": [{"kind": "terminal", "selected": True, "id": "t1"}]},
                    {"id": "p2", "tabs": [{"kind": "terminal", "selected": True, "id": "t2"}]}]

        def focus_pane(self, pane):
            if self.focus_raises:
                raise RuntimeError("socket closed")
            if self.focus_moves:
                self.focus = pane

    import io
    with tempfile.TemporaryDirectory() as out:
        with contextlib.redirect_stdout(io.StringIO()):
            rec = quiet_recording(out)
            rec.stress = FakeStress()
            rec.focus_quiet_terminal()
            assert rec.meta["typed_pane"] == {"before": "p1", "after": "p2", "quiet": True}, rec.meta
            assert not rec.meta["warnings"], rec.meta["warnings"]
            rec = quiet_recording(out)
            rec.stress = FakeStress(focus_raises=True)
            rec.focus_quiet_terminal()
            assert rec.meta["typed_pane"]["quiet"] is False and "socket closed" in rec.meta["warnings"][0], rec.meta
            rec = quiet_recording(out)
            rec.stress = FakeStress(focus_moves=False)
            rec.focus_quiet_terminal()
            assert rec.meta["typed_pane"] == {"before": "p1", "after": "p1", "quiet": False}, rec.meta
            assert "did not move" in rec.meta["warnings"][0], rec.meta["warnings"]
    text = summary_text({"typed_pane": {"before": "p1", "after": "p1", "quiet": False}})
    assert "typed pane: p1 -> p1 (NOT a quiet terminal" in text, text


def check_input_latency_slices():
    """Case 'input latency slices', end to end through build() on trace_fixtures' input.latency recording (the
    message InputLatencySignpostMessage writes): one slice per placed slot from generated to presented (to its last
    stage when unpresented) on an `input latency` track, named by its kind and target, a child per step between the
    stages it has (a skipped stage joins its neighbours; a stage outside the slice is left out), every child inside
    its slice with no gap and no overlap, slots that overlap in time on separate lanes, the terminal key's slice
    opening the arrow into the key.flow chain with its OS timestamp (a chain 1.5 ms off stays apart), and the summary
    per kind x target x presentation source over the person's presented, frame-changing slots."""
    fixtures = load("trace_fixtures", "trace_fixtures.py")
    with tempfile.TemporaryDirectory() as out:
        open(os.path.join(out, "signposts.ndjson"), "w").write(fixtures.input_latency_ndjson())
        write_json(os.path.join(out, "meta.json"), {"app_pid": fixtures.INPUT_PID, "scenario": "self-test"})
        summary = build(out)
        with gzip.open(os.path.join(out, "trace.json.gz"), "rt") as f:
            trace = json.load(f)["traceEvents"]
    names = {(e["pid"], e["tid"]): e["args"]["name"] for e in trace if e.get("name") == "thread_name"}
    slices = sorted((e for e in trace if e.get("cat") == "input.latency"), key=lambda e: e["ts"])
    stages = [e for e in trace if e.get("cat") == "input.latency.stage"]
    placed = [s for s in fixtures.INPUT_SLOTS if s["gen_ns"]]
    assert len(slices) == len(placed), [s["name"] for s in slices]
    full, text_key, click, held, scroll, scripted, no_echo, text_key_2, unknown = slices
    assert {names[(s["pid"], s["tid"])] for s in slices} == {"input latency", "input latency 2"}, names
    ms = lambda e: e["dur"] / 1000
    assert full["name"] == "EventLatency keyPress terminal" and full["ts"] == 5_000_000.0 and ms(full) == 12, full
    assert full["args"]["presentation_source"] == "estimatedVsync" and full["args"]["skipped_stages"] == [], full
    assert full["args"]["entrypoint"] == "person" and full["args"]["coalesced"] == 1, full["args"]
    children = lambda s: sorted((e for e in stages if (e["pid"], e["tid"]) == (s["pid"], s["tid"])
                                 and s["ts"] <= e["ts"] and e["ts"] + e["dur"] <= s["ts"] + s["dur"]),
                                key=lambda e: e["ts"])
    assert [e["name"] for e in children(full)] == [
        "GeneratedToArrivedMain", "ArrivedMainToDispatchStart", "DispatchStartToTextInputStart",
        "TextInputStartToTextInputEnd", "TextInputEndToDispatchEnd", "DispatchEndToDaemonReceived",
        "DaemonReceivedToPtyWritten", "PtyWrittenToEchoRead", "EchoReadToEchoSent", "EchoSentToMainCommit",
        "MainCommitToContentSubmitted", "ContentSubmittedToPresented"], [e["name"] for e in children(full)]
    for slot in slices:
        kids = children(slot)
        assert kids, slot
        # Contiguous, inside the slice, first at generated, last at the slice's end: they nest and tile it.
        assert kids[0]["ts"] == slot["ts"] and round(kids[-1]["ts"] + kids[-1]["dur"], 3) == round(slot["ts"] + slot["dur"], 3), slot
        assert all(round(a["ts"] + a["dur"], 3) == b["ts"] for a, b in zip(kids, kids[1:])), [(k["name"], k["ts"]) for k in kids]
    assert len(stages) == sum(len(children(s)) for s in slices), "a stage child outside its slot's slice"
    assert click["name"] == "EventLatency mousePress chromiumPage" and click["args"]["variable_refresh"], click
    assert "dispatch_start" in click["args"]["skipped_stages"] and click["args"]["coalesced"] == 3, click
    assert [e["name"] for e in children(click)] == [
        "GeneratedToArrivedMain", "ArrivedMainToDispatchEnd", "DispatchEndToMainCommit", "MainCommitToPresented"]
    assert click["args"]["oldest_to_newest_coalesced_ms"] == 2.0, click["args"]
    assert ms(text_key) == 8 and text_key["args"]["stages_out_of_order"] == 1, text_key
    assert (text_key["pid"], text_key["tid"]) != (full["pid"], full["tid"]), "two overlapping slots share a lane"
    assert (held["pid"], held["tid"]) != (click["pid"], click["tid"]), "a slot nested in another's slice"
    assert scroll["name"] == "EventLatency scrollUpdate layout" and not scroll["args"]["caused_frame_update"], scroll
    assert scripted["args"]["entrypoint"] == "automation", scripted
    assert not no_echo["args"]["presented"] and ms(no_echo) == 0.9, no_echo
    assert unknown["name"] == "EventLatency unknown#200 other", unknown
    # The terminal key's dispatch stage opens the arrow its key.flow chain takes in, forward in time: Perfetto draws
    # it from the source's end, so the source ends by the first hop (the whole slice ends at presented, 12 ms on).
    # The stray chain stays unlinked.
    linked = f"0x{fixtures.INPUT_FLOW:x}"
    sources = [e for e in trace if e.get("flow_out") and e.get("bind_id") == linked and e.get("cat") != "key.flow"]
    assert [e["name"] for e in sources] == ["ArrivedMainToDispatchStart"] and full["args"]["flow"] == linked, sources
    assert not full.get("flow_out") and not full.get("bind_id"), full
    hops = sorted((e for e in trace if e.get("cat") == "key.flow" and e.get("bind_id") == linked), key=lambda e: e["ts"])
    assert hops and hops[0].get("flow_in"), hops
    assert sources[0]["ts"] + sources[0]["dur"] <= hops[0]["ts"], ("the arrow runs backward in time", sources, hops[0])
    stray = [e for e in trace if e.get("cat") == "key.flow" and e.get("bind_id") == f"0x{fixtures.INPUT_STRAY_FLOW:x}"]
    assert stray and not stray[0].get("flow_in"), stray
    assert sum(1 for e in slices + stages if e.get("flow_out")) == 1, "an unlinked slot opened an arrow"
    latency = summary["input_latency"]
    assert (latency["slots"], latency["unplaced"], latency["automation"], latency["unpresented"], latency["no_update"],
            latency["linked_to_key_flow"]) == (len(placed), 1, 1, 1, 1, 1), latency
    rows = latency["rows"]
    assert set(rows) == {"keyPress terminal estimatedVsync", "keyPress textView metalPresented",
                         "mousePress chromiumPage pageEstimated", "unknown#200 other nominalRefresh"}, rows
    text_view = rows["keyPress textView metalPresented"]["total_ms"]
    assert (text_view["n"], text_view["p50"], text_view["p99"], text_view["max"]) == (2, 9.0, 9.98, 10.0), text_view
    assert rows["keyPress terminal estimatedVsync"]["stage_ms"]["PtyWrittenToEchoRead"]["p95"] == 1.0, rows
    assert rows["mousePress chromiumPage pageEstimated"]["total_ms"]["n"] == 2, rows
    text = summary_text(summary)
    assert "Input latency, generated -> presented" in text and "keyPress textView metalPresented" in text, text


INPUT_SWIFT = os.path.join(os.path.dirname(os.path.dirname(HERE)), "Packages", "macOS", "CmuxNext", "Sources")


def swift_enum_cases(path, enum):
    """The cases of `enum` in the Swift file at `path`, in declaration (raw value) order."""
    text = open(path).read()
    match = re.search(rf"^(?:public )?enum {enum}\b.*?\n(.*?)^}}", text, re.S | re.M)
    assert match, f"no enum {enum} in {path}"
    return tuple(case.strip() for line in re.findall(r"^    case ([\w, ]+)$", match.group(1), re.M)
                 for case in line.split(","))


def swift_input_latency_fields(path):
    """The `name=` keys of the input.latency message, in the order Signposter.event(_:_:) formats them; None when the
    file has no such emitter yet (a tree before p04-input-004)."""
    text = open(path).read()
    match = re.search(r"func event\(_ name: SignpostName, _ message: InputLatencySignpostMessage\)(.*?)\n    }", text, re.S)
    return tuple(re.findall(r"(\w+)=\\\(message\.", match.group(1))) if match else None


def check_input_tables_match_the_swift(swift_root=INPUT_SWIFT):
    """Case 'input latency tables', against the Swift that writes the signpost: the kind, target, entrypoint and
    presentation source names are CmuxNextInputCore's case lists in raw value order, and the message fields are
    Signposter.event(_:_:)'s keys in its order, for trace.py and for trace_fixtures' recording alike. A case
    inserted or reordered, or a field renamed, in the Swift fails here, not as wrong names or a silent -1 stage.
    Returns a note when the tree has no input.latency emitter yet: the parser then has no Swift to drift from."""
    core = os.path.join(swift_root, "CmuxNextInputCore")
    kinds = os.path.join(core, "InputEventKind.swift")
    for enum, names in (("InputEventKind", INPUT_KINDS), ("InputTarget", INPUT_TARGETS),
                        ("InputEntrypoint", INPUT_ENTRYPOINTS)):
        assert swift_enum_cases(kinds, enum) == names, (enum, swift_enum_cases(kinds, enum), names)
    fields = swift_input_latency_fields(os.path.join(swift_root, "CmuxNextSignposts", "Signposter.swift"))
    if fields is None:
        return "no input.latency emitter in this tree (p04-input-004): fields and sources not compared"
    sources = swift_enum_cases(os.path.join(core, "InputPresentationSource.swift"), "InputPresentationSource")
    assert sources == INPUT_SOURCES, (sources, INPUT_SOURCES)
    fixtures = load("trace_fixtures", "trace_fixtures.py")
    assert fields == INPUT_MESSAGE_FIELDS == fixtures.INPUT_FIELDS, (fields, INPUT_MESSAGE_FIELDS, fixtures.INPUT_FIELDS)
    return None


REPO = os.path.dirname(os.path.dirname(HERE))
RING_GOLDEN = os.path.join(REPO, "Packages", "macOS", "CmuxNext", "Tests", "CmuxNextTraceTests", "Fixtures",
                           "ring-v1-golden.cmxtrace")
RUST_CRATES = os.path.join(REPO, "cmux-tui", "crates")
RUST_CATALOG = os.path.join(RUST_CRATES, "cmux-trace", "src", "names.rs")
RUST_CLI_TRACE = os.path.join(RUST_CRATES, "cmux-tui", "src", "cli", "trace.rs")


def ring_fixture(pid=20, role=2, names=(), threads=(), records=(), chunk_count=8, start_ns=1000, start_cursor=0,
                 version=RING_VERSION, kind=2):
    """(bytes, record offsets) of a ring v1 laid out as trace.md says, for the self-test: `names` are the name
    entries from id 1, `threads` the thread entries (tid, qos, name, generation), and `records` (thread index, t_ns,
    name id, phase, flags, arg0, arg1) are written in order, each thread into its own chunks (31 records each, claimed
    from `start_cursor` on). A thread's last chunk stays owned (odd lap_seq), as in a live ring."""
    names_at, threads_at, chunks_at = RING_HEADER_BYTES, RING_HEADER_BYTES + 64 * RING_ENTRY_BYTES, 2 * RING_PAGE_BYTES
    data = bytearray(chunks_at + chunk_count * RING_CHUNK_BYTES)
    for index, text in enumerate(names, 1):
        at, raw = names_at + index * RING_ENTRY_BYTES, text.encode()
        struct.pack_into("<IHBBB", data, at, RING_PUBLISHED, index, 1, 0, len(raw))
        data[at + 9:at + 9 + len(raw)] = raw
    for index, (tid, qos, name, generation) in enumerate(threads):
        at, raw = threads_at + index * RING_ENTRY_BYTES, name.encode()
        struct.pack_into("<IIQBB", data, at, 2, generation, tid, qos, len(raw))
        data[at + 18:at + 18 + len(raw)] = raw
    codes = {code: value for value, code in RING_PHASES.items()}
    cursor, owned, offsets = start_cursor, {}, []
    for thread, t_ns, name, phase, flags, arg0, arg1 in records:
        chunk = owned.get(thread)
        if chunk is None or chunk["used"] == 31:
            if chunk:
                struct.pack_into("<Q", data, chunks_at + chunk["index"] * RING_CHUNK_BYTES + 8, 2 * chunk["lap"] + 2)
            chunk = owned[thread] = {"index": cursor % chunk_count, "lap": cursor // chunk_count, "used": 0}
            cursor += 1
            generation = threads[thread][3] if thread < len(threads) else 0
            RING_CHUNK_HEAD.pack_into(data, chunks_at + chunk["index"] * RING_CHUNK_BYTES, thread, generation,
                                      2 * chunk["lap"] + 1, 0)
        chunk["used"] += 1
        at = chunks_at + chunk["index"] * RING_CHUNK_BYTES + chunk["used"] * RING_RECORD.size
        RING_RECORD.pack_into(data, at, t_ns, (2 * chunk["lap"] + 2) & 0xFFFF_FFFF, name, codes[phase], flags, arg0, arg1)
        offsets.append(at)
    header = dict.fromkeys(RING_HEADER_FIELDS, 0)
    header.update(magic=RING_MAGIC, version=version, header_bytes=RING_HEADER_BYTES, pid=pid, role=role, ring_kind=kind,
                  clock_domain=1, start_uptime_ns=start_ns, boot_session_uuid=bytes(16), build_uuid=bytes(16),
                  build_version=b"self-test", chunk_bytes=RING_CHUNK_BYTES, chunk_count=chunk_count,
                  chunks_offset=chunks_at, chunk_cursor=cursor, name_table_offset=names_at, name_capacity=64,
                  name_cursor=len(names) + 1, thread_table_offset=threads_at, thread_capacity=256,
                  thread_cursor=len(threads), recording_start_cursor=start_cursor)
    RING_HEADER.pack_into(data, 0, *(header[key] for key in RING_HEADER_FIELDS))
    return data, offsets


def check_ring_reads_the_golden_file():
    """Case 'ring parse', against the writers: the golden ring the Rust and Swift writers both pin
    (ring-v1-golden.cmxtrace) decodes here to what cmux-trace/tests/ring.rs reads from it: the interned name, both
    threads (exited), the first 8 records' phases and flags, 38 records, and the header's fields."""
    with open(RING_GOLDEN, "rb") as f:
        ring = decode_ring(f.read(), RING_GOLDEN)
    header = ring["header"]
    assert (header["pid"], ring["info"]["role"], ring["info"]["kind"], ring["info"]["clock"]) == \
        (4242, "daemon", "blackbox", "uptime_raw"), ring["info"]
    assert header["build_version"] == "1.2.3 (45) abcdef0" and header["chunk_count"] == 4, header
    assert header["chunk_cursor"] == 3 and header["name_cursor"] == 5, header
    assert ring["names"][4] == "cmux.io.read", ring["names"]
    threads = [(t["tid"], t["qos"], t["name"], t["state"]) for _, t in sorted(ring["threads"].items())]
    assert threads == [(101, 0x21, "main", 3), (202, 0x19, "cmux-io", 3)], threads
    first = [(r["t_ns"], r["phase"], r["flags"]) for r in ring["records"][:8]]
    assert first == [(1000, "B", 0), (1050, "b", 1), (1100, "s", 0), (1150, "f", 0), (1200, "E", 0), (1300, "e", 1),
                     (1350, "C", 3), (1375, "I", 0)], first
    assert len(ring["records"]) == 38 and ring["records"][7]["name"] == "cmux.io.read", ring["records"][7]
    assert [ring_thread(ring, r["thread"])[1] for r in ring["records"][:2]] == ["main", "cmux-io"]


def check_ring_parse():
    """Case 'ring parse': only published records of this recording decode (a torn slot, a record from before the
    recording's start time and a chunk of an earlier recording's lap are dropped), records merge by time across
    threads, a chunk of an entry's earlier occupant is named by index and generation, an unknown version, a bad
    magic and a truncated file are refused, and ring_events pairs B/E and AB/AE into slices and counts the rest."""
    names = ("daemon.request", "task.run", "control.request", "frame.tick")
    threads = ((101, 0x21, "main", 0), (102, 0x19, "io", 1))
    records = [(0, 2000, 2, "B", 0, 0, 0), (1, 2100, 1, "b", 1, 7, 0xA1), (0, 2200, 2, "B", 0, 0, 0),
               (0, 2300, 2, "E", 0, 0, 0), (1, 2350, 1, "b", 1, 7, 0xA2), (0, 2400, 2, "E", 0, 0, 0),
               (1, 2500, 1, "e", 1, 0, 0xA1), (1, 2600, 1, "e", 1, 0, 0xA2), (0, 2700, 4, "I", 0, 1, 2),
               (0, 2800, 3, "C", 1, (1 << 64) - 5, 9), (0, 2900, 2, "E", 0, 0, 0),  # an E whose B is gone
               (1, 2950, 2, "B", 0, 0, 0),  # a B never ended
               (0, 900, 4, "I", 0, 0, 0),  # before the recording's start time
               (0, 3000, 4, "I", 0, 0, 0)]  # torn below
    data, offsets = ring_fixture(names=names, threads=threads, records=records, start_cursor=8)
    struct.pack_into("<I", data, offsets[-1] + 8, 2 * 1 + 1)  # its writer is still inside it: an odd seq
    # A chunk an earlier recording left (lap 0 < start lap 1): every record in it is whole, and none is this one's.
    old = 2 * RING_PAGE_BYTES + 7 * RING_CHUNK_BYTES
    RING_CHUNK_HEAD.pack_into(data, old, 0, 0, 2, 31)
    RING_RECORD.pack_into(data, old + 32, 5000, 2, 4, 0x49, 0, 0, 0)
    ring = decode_ring(bytes(data), "fixture")
    times = [r["t_ns"] for r in ring["records"]]
    assert times == [2000, 2100, 2200, 2300, 2350, 2400, 2500, 2600, 2700, 2800, 2900, 2950], times
    assert ring["info"]["records"] == 12 and ring["info"]["role"] == "daemon", ring["info"]
    # Thread 1's entry was taken again (generation 1) after its chunk was claimed under generation 1: it names "io";
    # a chunk claimed under generation 0 names the entry's earlier occupant.
    assert ring_thread(ring, (1, 1)) == (102, "io") and ring_thread(ring, (1, 0)) == (None, "thread 1 (generation 0)")
    lane_names = {}
    events, unpaired = ring_events([ring], SyntheticTracks(set()), lane_names)
    slices = sorted((e["name"], e["ts"], e["dur"]) for e in events if e["ph"] == "X")
    assert slices == [("daemon.request", 2.1, 0.4), ("daemon.request", 2.35, 0.25), ("task.run", 2.0, 0.4),
                      ("task.run", 2.2, 0.1)], slices
    assert unpaired == {"end_without_begin": 1, "begin_without_end": 1}, unpaired
    counter = next(e for e in events if e["ph"] == "C")
    assert counter["args"] == {"value": -5}, counter
    assert sorted(set(lane_names.values())) == ["ring async daemon.request", "ring async daemon.request 2",
                                                "ring main"], lane_names
    # The same process's black box: its thread 0 is another OS thread than the recording's thread 0, and its async
    # slice overlaps the recording's two. Each ring's threads get their own tracks, and one set of lanes takes the
    # async slices of both rings, so no track holds two slices that overlap without nesting.
    box = decode_ring(bytes(ring_fixture(names=names, threads=((201, 0x19, "worker", 0),), kind=1, records=[
        (0, 2050, 1, "b", 1, 0, 0xB1), (0, 2150, 2, "B", 0, 0, 0), (0, 2450, 2, "E", 0, 0, 0),
        (0, 2550, 1, "e", 1, 0, 0xB1)])[0]), "box")
    lane_names = {}
    events, unpaired = ring_events([ring, box], SyntheticTracks(set()), lane_names)
    assert {"ring main (recording)", "ring worker (blackbox)"} <= set(lane_names.values()), lane_names
    by_track = collections.defaultdict(list)
    for e in events:
        if e["ph"] == "X":
            by_track[e["tid"]].append((e["ts"], e["ts"] + e["dur"], e["name"]))
    assert sum(1 for spans in by_track.values() if any(name == "task.run" for _, _, name in spans)) == 2, by_track
    for spans in by_track.values():
        open_ends = []
        for start, end, _ in sorted(spans, key=lambda s: (s[0], -s[1])):
            open_ends = [e for e in open_ends if e > start]
            assert not open_ends or end <= open_ends[-1], ("overlap without nesting", spans)
            open_ends.append(end)
    assert unpaired == {"end_without_begin": 1, "begin_without_end": 1}, unpaired
    for broken, why in ((ring_fixture(version=2)[0], "version 2"), (b"NOTARING" + bytes(300), "bad magic"),
                        (ring_fixture()[0][:4096], "truncated")):
        try:
            decode_ring(bytes(broken))
            raise AssertionError(f"a ring with {why} decoded")
        except RingError as error:
            assert why.split()[0] in str(error), (why, error)


# The names a press's ring records use (each ring holds its own table; these fixtures give each the same one).
FLOW_RING_NAMES = ("key.flow", "ghostty.render", "frame.gpu_done", "frame.present_estimate", *ECHO_HANDOFFS,
                   *sorted(LEGACY_FLOW_HOPS))
FLOW_RING_ID = {name: index for index, name in enumerate(FLOW_RING_NAMES, 1)}
FLOW_APP_PID, FLOW_DAEMON_PID, FLOW_HOST_PID = 10, 20, 30
# A real 16-byte terminal id with a leading zero byte: the JSONL records carry its 32 hex digits, the rings its
# terminal key (the first 8 bytes, big-endian), whose plain hex would drop the leading zeros.
FLOW_TERMINAL = "00a1b2c3d4e5f60718293a4b5c6d7e8f"
FLOW_TERMINAL_KEY = int(FLOW_TERMINAL[:16], 16)
FLOW_THREADS = ((100, 0x21, "main", 0), (101, 0x2F, "renderer", 0), (102, 0x19, "io", 0))


def flow_press_records(flow, base, gpu_done_at=None, legacy=("host.pty.write",), skip=()):
    """{pid: [record]} of one terminal key press written to the app's, daemon's and host's rings, every hop with its
    flow id, base (ns) the press's dispatch. A daemon, host or holder hop is written as cmux-flow-trace writes it: an
    `f` record then, 0.3 us later, an `s` record with the flow id. The hops in `skip` are left out; the `legacy` hops
    are written as an old recording's CMUX_TRACE_FLOWS records instead (flow 0 when the hop has none: returned under
    the key "jsonl")."""
    out = collections.defaultdict(list)
    at = lambda us: base + int(us * 1000)
    key = lambda pid, thread, us, name, phase, arg0, arg1, flags=0: out[pid].append(
        (thread, at(us), FLOW_RING_ID[name], phase, flags, arg0, arg1))
    codes = {hop: code for code, hop in KEY_FLOW_CODES.items()}
    app = lambda us, hop, thread=0: key(FLOW_APP_PID, thread, us, "key.flow", "s" if hop == "app.key.dispatch" else "f",
                                        codes[hop] | (50 << 8), flow)
    echo = lambda pid, us, short, phase, thread=0: key(pid, thread, us, f"key.echo.{short}", phase, FLOW_TERMINAL_KEY,
                                                       flow)

    def hop(pid, us, name):
        if name in legacy:
            out["jsonl"].append({"hop": name, "flow": flow if name.startswith("daemon.send") else 0,
                                 "terminal": FLOW_TERMINAL, "pid": pid, "tid": 7, "t_ns": at(us)})
            return
        key(pid, 0, us, name, "f", FLOW_TERMINAL_KEY, flow)
        key(pid, 0, us + 0.3, name, "s", FLOW_TERMINAL_KEY, flow)
    for us, name in ((0, "app.key.dispatch"), (1, "app.key.terminal"), (2, "app.io_write"), (3, "app.send")):
        app(us, name)
    hop(FLOW_DAEMON_PID, 10, "daemon.send.write")
    hop(FLOW_DAEMON_PID, 12, "daemon.send.written")
    hop(FLOW_HOST_PID, 15, "host.pty.write")
    hop(FLOW_HOST_PID, 40, "host.pty.read")
    steps = [(FLOW_HOST_PID, 41, "host_pty_read", "s", 0), (FLOW_HOST_PID, 42, "host_pty_read", "f", 1),
             (FLOW_HOST_PID, 43, "host_client_write", "s", 1), (FLOW_DAEMON_PID, 44, "host_client_write", "f", 1),
             (FLOW_DAEMON_PID, 45, "daemon_frames", "s", 1), (FLOW_DAEMON_PID, 46, "daemon_frames", "f", 2)]
    for pid, us, short, phase, thread in steps:
        echo(pid, us, short, phase, thread)
    hop(FLOW_DAEMON_PID, 47, "daemon.output.host")
    for us, short in ((48, "surface_parse"), (50, "attach_encode")):
        echo(FLOW_DAEMON_PID, us, short, "s", 2)
        echo(FLOW_DAEMON_PID, us + 1, short, "f", 2)
    hop(FLOW_DAEMON_PID, 52, "daemon.output.attach")
    echo(FLOW_DAEMON_PID, 53, "line_out", "s", 2)
    echo(FLOW_APP_PID, 54, "line_out", "f", 2)
    echo(FLOW_APP_PID, 55, "app_transport_read", "s", 2)
    app(56, "app.output.decoded", 2)
    echo(FLOW_APP_PID, 57, "app_transport_read", "f", 0)
    echo(FLOW_APP_PID, 58, "main_actor", "s", 2)
    echo(FLOW_APP_PID, 59, "main_actor", "f", 0)
    app(60, "app.output.received")
    echo(FLOW_APP_PID, 61, "output_lane", "s", 0)
    echo(FLOW_APP_PID, 62, "output_lane", "f", 0)
    app(63, "app.output.parsed")
    echo(FLOW_APP_PID, 64, "renderer", "s", 0)
    echo(FLOW_APP_PID, 65, "renderer", "f", 1)
    key(FLOW_APP_PID, 1, 65.5, "ghostty.render", "B", 0x5, 0)
    key(FLOW_APP_PID, 1, 70, "ghostty.render", "E", 0x5, 0)
    echo(FLOW_APP_PID, 70.5, "gpu_done", "s", 1)
    done = 75 if gpu_done_at is None else gpu_done_at  # what follows the GPU's completion waits for it
    key(FLOW_APP_PID, 1, done, "frame.gpu_done", "I", 0x5, 0)
    echo(FLOW_APP_PID, done + 1, "gpu_done", "f", 0)
    echo(FLOW_APP_PID, done + 2, "contents", "s", 0)
    app(done + 3, "app.frame.contents")
    echo(FLOW_APP_PID, done + 4, "contents", "f", 0)
    app(done + 5, "app.frame.commit")
    key(FLOW_APP_PID, 0, done + 15, "frame.present_estimate", "I", flow, 0, RING_FLAG_ESTIMATED)
    for pid in list(out):
        if pid != "jsonl":
            out[pid] = [r for r in out[pid] if FLOW_RING_NAMES[r[2] - 1] not in skip]
    return out


def flow_recording(out, presses, extra=(), folders=None):
    """Writes the presses' rings (one per process, each thread's records in time order) into OUT/rings, or the
    folder under OUT that `folders` gives the process, and their legacy records into OUT/flows/flows-1.jsonl;
    returns the decoded rings."""
    by_pid = collections.defaultdict(list)
    for press in presses:
        for pid, rows in press.items():
            by_pid[pid] += rows
    roles = {FLOW_APP_PID: 1, FLOW_DAEMON_PID: 2, FLOW_HOST_PID: 4}
    for pid, role in roles.items():
        rows = sorted(by_pid.get(pid, []) + [r for p, r in extra if p == pid], key=lambda r: r[1])
        data, _ = ring_fixture(pid=pid, role=role, names=FLOW_RING_NAMES, threads=FLOW_THREADS, records=rows,
                               chunk_count=16, start_ns=1)
        folder = os.path.join(out, (folders or {}).get(pid, RELEASE_DIR))
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, f"{RING_ROLES[role]}-{pid}.recording.cmxtrace"), "wb") as f:
            f.write(data)
    if by_pid.get("jsonl"):
        os.makedirs(os.path.join(out, "flows"), exist_ok=True)
        with open(os.path.join(out, "flows", "flows-1.jsonl"), "w") as f:
            for row in by_pid["jsonl"]:
                f.write(json.dumps(row) + "\n")
    return read_rings(out)[0]


def flows_of(out, rings):
    app_events, records, renders = ring_flow_inputs(rings)
    legacy, _ = read_flow_records(out)
    return {f["flow"]: f for f in assemble_flows(app_events, records + legacy, renders)}


def check_exact_flows():
    """Case 'exact flow': two presses to one terminal, the second typed before the first's echo came back (windows
    cannot tell their echoes apart: check_flow_hops_are_exclusive), assemble from the rings alone by their flow ids:
    both complete, no hop placed by a window, every echo handoff, ghostty.render, frame.gpu_done and
    frame.present_estimate present. The first press's GPU completion comes after the second frame began drawing,
    and still goes to the first frame (one command queue: frames complete in order)."""
    p1, p2 = (10 << 32) | 1, (10 << 32) | 2
    with tempfile.TemporaryDirectory() as out:
        rings = flow_recording(out, [flow_press_records(p1, 1_000_000, gpu_done_at=97, legacy=()),
                                     flow_press_records(p2, 1_030_000, legacy=())])
        assert [r["info"]["role"] for r in rings] == ["app", "daemon", "terminal-host"], [r["info"] for r in rings]
        by = flows_of(out, rings)
        assert set(by) == {p1, p2}, [hex(f) for f in by]
        for flow in (p1, p2):
            entry = by[flow]
            assert entry["complete"] and entry["echo_complete"] and not entry["windowed"], (hex(flow), entry["missing"])
            hops = {h["hop"]: h for h in entry["hops"]}
            assert {"ghostty.render", "frame.gpu_done", "frame.present_estimate", "key.echo.contents.taken"} <= set(hops)
            assert hops["ghostty.render"]["tid"] == 101 and hops["app.key.dispatch"]["pid"] == FLOW_APP_PID, hops
        at = lambda flow, hop: next(h["at_us"] for h in by[flow]["hops"] if h["hop"] == hop)
        # p2's frame began drawing at 1095.5 us; p1's frame completed at 1097 us, p2's at 1105 us.
        assert (at(p1, "frame.gpu_done"), at(p2, "frame.gpu_done")) == (1097.0, 1105.0)
        # A cmux-flow-trace hop's time is its `f` record's, not the `s` 0.3 us after it.
        assert at(p1, "host.pty.read") == 1040.0 and at(p2, "host.pty.read") == 1070.0
        assert at(p1, "host.pty.write") == 1015.0 and at(p1, "daemon.output.attach") == 1052.0
        assert at(p1, "app.key.dispatch") == 1000.0 and at(p1, "frame.present_estimate") == 1112.0
        assert at(p2, "frame.present_estimate") == 1120.0
        assert by[p1]["terminal"] == FLOW_TERMINAL[:16], by[p1]["terminal"]
        # Every hop, the ring's handoffs included, follows its causes (CLOCK_CAUSES): no step is negative and the
        # clock-order check finds nothing.
        for flow in (p1, p2):
            backwards = [(hop, step) for hop, step in press_latencies(by[flow])[0] if step < 0]
            assert not backwards, (hex(flow), backwards)
        assert clock_order_violations(list(by.values()), []) == []
        summary = flow_summary(list(by.values()), {})
        assert summary["complete"] == summary["echo_complete"] == 2 and summary["windowed_presses"] == 0, summary
        hop_ms = flow_percentiles(list(by.values()))["hop_ms"]["terminal"]
        assert hop_ms["frame.present_estimate"]["n"] == 2 and hop_ms["key.echo.contents.taken"]["n"] == 2, hop_ms.keys()


def check_mixed_flows():
    """Case 'mixed': a recording with rings and an old process's CMUX_TRACE_FLOWS file, as the DEBUG record path
    leaves it: the new daemon's ring in OUT/flows next to an old host's flows-<pid>.jsonl. The file's terminal is the
    full 32-digit id, the rings' its terminal key (with a leading zero byte). The PTY write the host wrote only to
    the file (flow 0) is placed by its window on the terminal of the press's ring daemon.send.write; a stage with an
    exact ring record keeps it even when the file has another candidate in the window; a ring record with flow 0 is
    never placed by a window; and the whole recording builds into one trace with the rings' tracks and a summary that
    says what it read, each ring once though a copy of one is in OUT too."""
    p1 = (10 << 32) | 1
    with tempfile.TemporaryDirectory() as out:
        press = flow_press_records(p1, 1_000_000, legacy=("host.pty.write",))
        # The file's own read of the echo, 2 us after the ring's: the exact one wins.
        press["jsonl"].append({"hop": "host.pty.read", "flow": 0, "terminal": FLOW_TERMINAL, "pid": 30,
                               "tid": 7, "t_ns": 1_042_000})
        # A ring PTY write with no flow (a host without WRITE_FLOW, cmux-flow-trace's `I`): not a window candidate.
        extra = [(FLOW_HOST_PID, (0, 1_016_000, FLOW_RING_ID["host.pty.write"], "I", 0, FLOW_TERMINAL_KEY, 0))]
        rings = flow_recording(out, [press], extra, folders={FLOW_DAEMON_PID: "flows"})
        assert [r["info"]["role"] for r in rings] == ["app", "terminal-host", "daemon"], [r["info"] for r in rings]
        assert os.path.dirname(rings[2]["info"]["path"]) == os.path.join(out, "flows"), rings[2]["info"]
        shutil.copy(rings[1]["info"]["path"], os.path.join(out, "host-copy.cmxtrace"))
        by = flows_of(out, rings)
        entry = by[p1]
        hops = {h["hop"]: h["at_us"] for h in entry["hops"]}
        assert entry["terminal"] == FLOW_TERMINAL[:16], entry["terminal"]
        assert entry["complete"] and entry["echo_complete"], entry["missing"]
        assert entry["windowed"] == ["host.pty.write"] and hops["host.pty.write"] == 1015.0, (entry["windowed"], hops)
        assert hops["host.pty.read"] == 1040.0 and hops["daemon.send.write"] == 1010.0, hops
        write_json(os.path.join(out, "meta.json"), {"app_pid": FLOW_APP_PID, "scenario": "self-test"})
        summary = build(out)
        assert len(summary["rings"]["files"]) == 3 and not summary["rings"]["unreadable"], summary["rings"]
        flows = summary["key_flows"]
        assert flows["presses"] == flows["complete"] == flows["echo_complete"] == flows["windowed_presses"] == 1, flows
        with gzip.open(os.path.join(out, "trace.json.gz"), "rt") as f:
            events = json.load(f)["traceEvents"]
        tracks = {e["args"]["name"] for e in events if e.get("name") == "thread_name"}
        assert {"ring main", "ring renderer", "ring io", "key flow"} <= tracks, tracks
        render = [e for e in events if e.get("cat") == "ring" and e.get("name") == "ghostty.render"]
        assert len(render) == 1 and render[0]["dur"] == 4.5, render
        text = summary_text(summary)
        assert "Trace rings: 3 read" in text and "1 with every echo hop, 1 placed by windows" in text, text


def check_chromium_join():
    """Case 'Chromium join': Chromium's key EventLatency slices join cmux's keys. One begins at a keyPress slot's
    NSEvent timestamp (gen_ns, to the microsecond Chromium's JSON keeps): exact, and the slot's key.flow press names
    the flow. A second KEY_PRESSED slice at the same kGenerated (the Char of that RawKeyDown) joins the same key and,
    as the one that ends last, is the key's primary slice, the one its Chromium total measures, in either JSON order.
    One begins near a press that has no slot: joined by its dispatch hop minus its age. A mouse EventLatency and a
    key one 2 us off a slot's timestamp do not join. The joined begins carry the flow, and the summary counts them
    per type and per key."""
    f1, f3 = (10 << 32) | 1, (10 << 32) | 3
    slot = lambda gen, presented: {"pid": 10, "generated_ns": gen, "kind": "keyPress", "target": "chromiumPage",
                                   "entrypoint": "person", "source": "pageEstimated", "update": True, "vrr": False,
                                   "coalesced": 1, "last_generated_ns": None,
                                   "stages": {"generated": gen, "dispatch_start": gen + 200_000, "presented": presented}}
    slots = [slot(5_000_000_123, 5_000_000_123 + 9_000_000), slot(6_000_000_000, 6_000_000_000 + 9_000_000)]
    app_events = [flow_fixture_event(f1, "app.key.dispatch", 5_000_300.0), flow_fixture_event(f3, "app.key.dispatch",
                                                                                              7_000_405.0)]
    chrome = [{"ph": "b", "pid": 42, "tid": 1, "cat": "cc,benchmark,input", "name": "EventLatency", "id2": {"local": "0x1"},
               "ts": 5_000_000.0, "args": {"event_latency": {"event_type": "KEY_PRESSED"}}},
              {"ph": "b", "pid": 42, "tid": 1, "cat": "cc,benchmark,input", "name": "GenerationToRendererCompositor",
               "id2": {"local": "0x1"}, "ts": 5_000_000.0},
              {"ph": "e", "pid": 42, "tid": 1, "cat": "cc,benchmark,input", "name": "EventLatency", "id2": {"local": "0x1"},
               "ts": 5_012_000.0},
              {"ph": "X", "pid": 42, "tid": 1, "name": "EventLatency", "ts": 5_500_000.0, "dur": 9000.0,
               "args": {"event_latency": {"event_type": "MOUSE_PRESSED"}}},
              {"ph": "X", "pid": 42, "tid": 1, "name": "EventLatency", "ts": 6_000_002.0, "dur": 9000.0,
               "args": {"event_latency": {"event_type": "KEY_PRESSED"}}},
              {"ph": "B", "pid": 42, "tid": 2, "name": "EventLatency", "ts": 7_000_050.0, "args": {"event": "KeyPressed"}},
              {"ph": "E", "pid": 42, "tid": 2, "name": "EventLatency", "ts": 7_011_050.0},
              {"ph": "X", "pid": 42, "tid": 1, "name": "EventLatency", "ts": 5_000_000.0, "dur": 15000.0,
               "args": {"event_latency": {"event_type": "KEY_PRESSED"}}}]
    latencies = chromium_key_latencies(chrome)
    assert [(l["ts_us"], l["type"]) for l in latencies] == [(5_000_000.0, "KEY_PRESSED"), (5_000_000.0, "KEY_PRESSED"),
                                                             (6_000_002.0, "KEY_PRESSED"), (7_000_050.0, "KeyPressed")], \
        latencies
    reverse = chromium_key_links(app_events, slots, latencies[::-1])
    assert [(l["latency"]["end_us"], l["primary"]) for l in reverse] == [(5_015_000.0, True), (5_012_000.0, False),
                                                                          (7_011_050.0, True)], reverse
    links = chromium_key_links(app_events, slots, latencies)
    got = [(l["flow"], l["exact"], l["slot"], l["latency"]["end_us"], l["primary"]) for l in links]
    assert got == [(f1, True, 0, 5_015_000.0, True), (f1, True, 0, 5_012_000.0, False),
                   (f3, False, None, 7_011_050.0, True)], got
    joined = {"flow": f"0x{f1:x}", "join": "exact", "generated_us": 5_000_000.123}
    assert chrome[0]["args"]["cmux"] == chrome[7]["args"]["cmux"] == joined, (chrome[0], chrome[7])
    assert "cmux" not in chrome[4]["args"], chrome[4]
    summary = chromium_join_summary(latencies, links, slots)
    assert (summary["key_latencies"], summary["linked"], summary["keys"], summary["exact"], summary["with_flow"]) == \
        (4, 3, 2, 1, 2), summary
    assert summary["by_type"] == {"KEY_PRESSED": {"latencies": 3, "linked": 2},
                                  "KeyPressed": {"latencies": 1, "linked": 1}}, summary["by_type"]
    assert summary["chromium_total_ms"]["max"] == 15.0 and summary["chromium_total_ms"]["n"] == 2, summary
    assert summary["cmux_total_ms"]["n"] == 1, summary
    text = summary_text({"chromium_event_latency": summary})
    assert "3 of 4 joined to a cmux key (KEY_PRESSED 2/3, KeyPressed 1/1); 2 keys, 1 on the NSEvent timestamp" in text, \
        text


def check_key_flow_codes_match_the_swift(swift_root=INPUT_SWIFT, catalog=RUST_CATALOG):
    """Ring hop numbers and names against the writers: KEY_FLOW_CODES is KeyFlowHop's traceCode table (case to raw
    value to code), and every catalog name trace.py joins on (key.flow, the 12 key.echo handoffs, ghostty.render,
    frame.gpu_done, frame.present_estimate) is in the Rust catalog that every ring starts with."""
    with open(os.path.join(swift_root, "CmuxNextSignposts", "KeyFlowHop.swift")) as f:
        source = f.read()
    raw = dict(re.findall(r'case (\w+) = "([^"]+)"', source))
    codes = {int(code): raw[case] for case, code in re.findall(r"case \.(\w+): (\d+)\b", source) if case in raw}
    assert codes == KEY_FLOW_CODES, (codes, KEY_FLOW_CODES)
    with open(catalog) as f:
        names = set(re.findall(r'name\(\d+, \w+, "([^"]+)"\)', f.read()))
    wanted = {"key.flow", "ghostty.render", "frame.gpu_done", "frame.present_estimate", *ECHO_HANDOFFS}
    assert wanted <= names, sorted(wanted - names)


def check_flow_hop_names_match_the_rust(crates=RUST_CRATES):
    """The hop names trace.py reads from the daemon's, hosts' and holder's rings and files against their writer:
    every name a `cmux_flow_trace::hop` / `hop_id` call site passes is in LEGACY_FLOW_HOPS, and once cmux-flow-trace
    interns them in the ring (p09-observability 011), its `hop_name` table is exactly LEGACY_FLOW_HOPS."""
    calls = set()
    for crate in sorted(os.listdir(crates)):
        for root, _, files in os.walk(os.path.join(crates, crate, "src")):
            for name in files:
                if name.endswith(".rs"):
                    with open(os.path.join(root, name), errors="replace") as f:
                        calls |= set(re.findall(r'cmux_flow_trace::hop(?:_id)?\(\s*"([^"]+)"', f.read()))
    assert calls and calls <= LEGACY_FLOW_HOPS, sorted(calls - LEGACY_FLOW_HOPS)
    with open(os.path.join(crates, "cmux-flow-trace", "src", "lib.rs")) as f:
        table = set(re.findall(r'InternedName::new\(\s*"([^"]+)"', f.read())) - {"flow.hop.unknown"}
    if not table:
        return "cmux-flow-trace interns no hop names in this tree (p09-observability-011): call sites compared only"
    assert table == LEGACY_FLOW_HOPS, (sorted(table - LEGACY_FLOW_HOPS), sorted(LEGACY_FLOW_HOPS - table))
    return None


def fake_trace_cli(folder, script):
    """A `cmux` stand-in for `cmux trace record`: /bin/sh running `script` with $out the --out folder."""
    cli = os.path.join(folder, "cmux")
    with open(cli, "w") as f:
        f.write('#!/bin/sh\nwhile [ "$1" != "--out" ]; do shift; done\nout="$2"\n' + script)
    os.chmod(cli, 0o755)
    return cli


def check_release_trace(cli_source=RUST_CLI_TRACE):
    """`record --release`: the CLI call (`cmux trace record` with the window's length in whole seconds, OUT/rings,
    key flows and Chromium); its start waiting for the CLI's note that it records and counting the window from
    there, and returning False for a CLI that says nothing in time or ends saying nothing; its stop waiting for the
    CLI's window and returning its exit code, files and log; the Recording's stop path reporting a failed CLI; and
    the parser refusing --release where trace.start cannot run (wrap mode, a launch scenario) or past the CLI's
    --seconds limit, which is the CLI's own (cli/trace.rs) when this tree has it."""
    with tempfile.TemporaryDirectory() as out:
        cli = fake_trace_cli(out, 'echo "Recording for 22 s" >&2\nsleep 0.5\n: > "$out/app-1.recording.cmxtrace"\n'
                                  'echo recorded\n')
        release = ReleaseTrace(cli, "/tmp/s.sock", out, 22, chromium=True)
        assert release.command() == [cli, "--app-socket", "/tmp/s.sock", "trace", "record", "--seconds", "22", "--out",
                                     os.path.join(out, RELEASE_DIR), "--keys", "--chromium"], release.command()
        assert "--chromium" not in ReleaseTrace(cli, "s", out, 1, chromium=False).command()
        # `record --seconds 7.5`: the window and its 2 s of settle, in the whole seconds the CLI takes.
        assert ReleaseTrace(cli, "s", out, 7.5 + RELEASE_WINDOW_SETTLE_S, chromium=False).command()[6] == "10"
        assert release.start(start_s=10)
        assert 21 < release.remaining_s() <= 22, release.remaining_s()
        done = release.stop(collect_s=30)
        assert done["exit"] == 0 and done["files"] == ["app-1.recording.cmxtrace"], done
        assert "Recording for 22 s" in done["log_tail"] and "recorded" in done["log_tail"], done
    with tempfile.TemporaryDirectory() as out:
        silent = ReleaseTrace(fake_trace_cli(out, "sleep 30\n"), "s", out, 3, chromium=False)
        began = time.monotonic()
        assert not silent.start(start_s=0.3) and time.monotonic() - began < 5
        silent.kill()
        ended = ReleaseTrace(fake_trace_cli(out, "exit 2\n"), "s", out, 3, chromium=False)
        assert not ended.start(start_s=10)
        assert ended.stop(collect_s=10)["exit"] == 2
    with tempfile.TemporaryDirectory() as out:
        rec = quiet_recording(out, release=True)
        rec.release = ReleaseTrace(fake_trace_cli(out, 'echo "trace.start refused: already recording" >&2\nexit 3\n'),
                                   "s", out, 3, chromium=False)
        rec.release.start(start_s=10)
        rec.stop()
        assert rec.meta["sources"]["release_trace"]["exit"] == 3, rec.meta["sources"]
        assert any("exited 3" in w and "already recording" in w for w in rec.meta["warnings"]), rec.meta["warnings"]
    if os.path.exists(cli_source):
        with open(cli_source) as f:
            source = f.read()
        constants = {name: int(value) for name, value in re.findall(r"const (\w+): u32 = (\d+);", source)}
        assert constants["MAX_SECONDS_CAP"] - constants["STOP_SLACK_SECONDS"] == RELEASE_RECORD_MAX_S, constants
    largest = RELEASE_RECORD_MAX_S - RELEASE_WINDOW_SETTLE_S
    for argv, why in ((["--bundle", "b", "--release", "--", "true"], "stress-storm or light-storm"),
                      (["--app", "a", "--release", "--scenario", "launch-warm"], "stress-storm or light-storm"),
                      (["--app", "a", "--release", "--seconds", f"{largest + 0.5}"], f"at most {largest} s")):
        done = subprocess.run([sys.executable, os.path.abspath(__file__), "record", "--out", "/nonexistent", *argv],
                              capture_output=True, text=True, timeout=60)
        assert done.returncode == 2 and why in done.stderr, (argv, done.returncode, done.stderr[-300:])
    if not os.path.exists(cli_source):
        return f"no {os.path.relpath(cli_source, REPO)} in this tree (p09-observability-021): its --seconds limit not read"
    return None


FIXTURES = os.path.join(HERE, "tests", "trace-fixtures")


def check_real_xctrace_exports():
    """Real exports (scripts/cmux-next/trace_fixtures.py on a fleet Mac, one folder per Xcode major): the column
    tags time_profile_samples, xctrace_signposts, syscall_waits and parse_toc read are the ones xctrace writes.

    At least one folder must exist. Each folder present is checked; a missing major is not a failure: the fleet
    has no macOS 14 or 15 host today (every worker reports macos-26 or macos-27, 2026-10-24), so the Xcode 15 and
    16 sets are added when such a host exists. A syscall table with no rows (a System Trace that ended before
    its kernel tracing started) checks only its columns."""
    folders = sorted(d for d in os.listdir(FIXTURES) if d.startswith("xcode-")) if os.path.isdir(FIXTURES) else []
    assert folders, f"no real xctrace exports in {FIXTURES} (record them with trace_fixtures.py on a fleet Mac)"
    for folder in folders:
        where = os.path.join(FIXTURES, folder)
        emitter = read_json(os.path.join(where, "fixture.json"))["emitter"]
        toc = parse_toc(os.path.join(where, "profile-toc.xml"))
        assert {"time-profile", "os-signpost"} <= set(toc["schemas"]) and toc["start_date"], (folder, toc)
        assert "syscall" in parse_toc(os.path.join(where, "system-toc.xml"))["schemas"], folder
        samples = time_profile_samples(os.path.join(where, "time-profile.xml"))
        main = [x for x in samples if x[2].get("name") == "Main Thread" and isinstance(x[2].get("pid"), int)
                and isinstance(x[2].get("tid"), int)]
        assert main and all(x[1] > 0 for x in main), (folder, samples[:2])
        spin = [x for x in main if any(emitter["spin_function"] in str(f) for f in x[3])]
        # 20 rounds of 20 ms at 1 ms sampling: about 400 samples in the spin; half of that is a broken parse.
        assert len(spin) >= emitter["rounds"] * emitter["spin_ms"] // 2, (folder, len(spin), main[0][3][:5])
        stats = {}
        posts = xctrace_signposts(os.path.join(where, "os-signpost.xml"), stats)
        begins = [x for x in posts if x[1] == emitter["signpost"] and x[2].lower().startswith("begin")]
        ends = [x for x in posts if x[1] == emitter["signpost"] and x[2].lower().startswith("end")]
        assert len(begins) == len(ends) == emitter["rounds"], (folder, stats, posts[:3])
        assert all(isinstance(x[0], int) for x in begins), begins[:2]
        syscall = os.path.join(where, "syscall.xml")
        rows = sum(1 for _ in xctrace_rows(syscall))
        columns = re.findall(r"<mnemonic>([^<]+)</mnemonic>", open(syscall).read(4000))
        assert {"start", "thread", "call", "duration", "backtrace"} <= set(columns), (folder, columns)
        if rows:
            waits = syscall_waits(syscall)
            sleeps = [x for x in waits if x[2].get("name") == "Main Thread" and "semwait" in x[3]
                      and x[1] >= emitter["usleep_ms"] * 1_000_000 * 0.8]
            assert len(sleeps) >= emitter["rounds"] // 2, (folder, len(waits), [(x[3], x[1]) for x in waits[:5]])
        print(f"{folder}: {len(spin)} spin samples, {len(begins)} signpost intervals, {rows} syscall rows")


def check_launch_trace():
    """The launch fixture (trace_fixtures.write_launch_fixture; tests/test_trace_launch.py checks it in full): the
    startup files merge on one clock, a cut file keeps its whole events, and the summary has a critical path."""
    fixtures = load("trace_fixtures", "trace_fixtures.py")
    with tempfile.TemporaryDirectory() as out:
        fixtures.write_launch_fixture(out)
        launch = build(out)["launch"]
        assert launch["first_frame_ms"] == 240.0 and launch["critical_path"], launch
        assert [t["ms"] for t in launch["turns"]] == [12.0, 6.0], launch["turns"]
        files = read_json(os.path.join(out, "summary.json"))["sources"]["startup_files"]
        assert files["startup-cef.json"]["truncated"] and files["startup-daemon.json"]["offset_us"] == 2e6, files
        with open(os.path.join(out, "SUMMARY.txt")) as f:
            assert "Critical path" in f.read()


SELF_TESTS = [check_real_xctrace_exports, check_parsers_and_merge, check_stage_bounds, check_stage_errors,
              check_hold_defers_the_bound,
              check_stop_survives_a_failing_source, check_record_ends_cleanly, check_xctrace_held_before_start,
              check_wrapped_group_ends,
              check_export_part_files, check_xctrace_clock, check_cef_validity, check_bound_inside_a_swallowing_wait,
              check_signal_after_the_stop, check_xctrace_gets_one_sigint, check_synthetic_tids_fit_uint32,
              check_cli_named_cmux_is_not_the_app, check_refuses_a_running_bundle, check_signpost_clock,
              check_import_with_a_fake_trace_processor, check_key_flows, check_flow_hops_are_exclusive,
              check_flow_gaps_warn, check_percentiles, check_clock_order_and_percentiles, check_clock_command,
              check_focus_quiet_terminal, check_launch_trace, check_input_latency_slices,
              check_input_tables_match_the_swift, check_ring_reads_the_golden_file, check_ring_parse,
              check_exact_flows, check_mixed_flows, check_chromium_join, check_key_flow_codes_match_the_swift,
              check_flow_hop_names_match_the_rust, check_release_trace]


def self_test():
    """Runs every check on its own (one failure does not hide the next) and prints one line each."""
    import io
    failed = []
    for check in SELF_TESTS:
        captured = io.StringIO()
        try:
            with contextlib.redirect_stdout(captured):
                note = check()
            print(f"ok   {check.__name__}" + (f" ({note})" if isinstance(note, str) else ""))
        except (Exception, StageTimeout) as error:  # reported per check; the self-test exits 1
            failed.append(check.__name__)
            print(f"FAIL {check.__name__}: {type(error).__name__}: {str(error)[:600]}")
    print("self-test ok" if not failed else f"self-test FAILED: {', '.join(failed)}")
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="verb")
    rec = sub.add_parser("record", help="record a scenario (see the module doc)")
    where = rec.add_mutually_exclusive_group()
    where.add_argument("--app", help="a Debug `cmux DEV <tag>.app` to launch (not running)")
    where.add_argument("--bundle", help="wrap mode: the bundle whose processes the COMMAND's app runs")
    rec.add_argument("--socket", help="wrap mode: the debug socket of the app COMMAND launches (hang drain)")
    rec.add_argument("--out", required=True)
    rec.add_argument("--scenario", choices=["stress-storm", "light-storm", *LAUNCH_SCENARIOS], default="stress-storm")
    rec.add_argument("--seconds", type=float, default=20)
    rec.add_argument("--seconds-cap", type=float, default=600, help="wrap mode: the longest recording")
    rec.add_argument("--recorder", choices=["auto", "xctrace", "sample"], default="auto")
    rec.add_argument("--system-trace", action="store_true", help="System Trace (thread states, off-CPU reasons) as well")
    rec.add_argument("--no-cef", action="store_true", help="no DevTools port and no Chromium trace")
    rec.add_argument("--release", action="store_true",
                     help="record through the Release trace rings (`cmux trace record --keys --chromium`) instead of "
                          "the DEBUG knobs (flow files, daemon span file, DevTools port)")
    rec.add_argument("--cdp-port", type=int, default=0, help="the DevTools port (default: a free one)")
    rec.add_argument("--hang-ms", type=int, default=8)
    rec.add_argument("--storm-hz", type=float, default=10)
    rec.add_argument("--key-interval", type=float, default=0.12)
    rec.add_argument("--chord-every", type=int, default=10)
    rec.add_argument("--keep", action="store_true", help="leave the app running")
    rec.add_argument("--keep-recording", action="store_true", help="keep recording.trace (Instruments) after the export")
    rec.add_argument("command", nargs=argparse.REMAINDER)
    exp = sub.add_parser("export", help="rebuild DIR's trace and summary from its raw files")
    exp.add_argument("dir")
    show = sub.add_parser("summary", help="print DIR's summary")
    show.add_argument("dir")
    imp = sub.add_parser("check-import", help="load DIR/trace.json.gz with trace_processor_shell and check its tracks")
    imp.add_argument("dir")
    imp.add_argument("--trace-processor", required=True, help="a trace_processor_shell binary (Perfetto)")
    clock = sub.add_parser("check-clock", help="exit 1 when a hop of DIR's key presses or daemon requests is "
                                               "earlier than its cause")
    clock.add_argument("dir")
    opts = parser.parse_args()
    if opts.self_test:
        return self_test()
    if opts.verb == "record":
        if opts.command and opts.command[0] == "--":
            opts.command = opts.command[1:]
        if not opts.app and not opts.command:
            parser.error("record needs --app, or a COMMAND after --")
        if opts.command and opts.app:
            parser.error("wrap mode takes --bundle, not --app (the COMMAND launches the app)")
        if opts.release and (opts.command or opts.scenario in LAUNCH_SCENARIOS):
            parser.error("--release records a stress-storm or light-storm window (trace.start needs the running app)")
        if opts.release and math.ceil(opts.seconds + RELEASE_WINDOW_SETTLE_S) > RELEASE_RECORD_MAX_S:
            parser.error(f"--release records at most {RELEASE_RECORD_MAX_S - RELEASE_WINDOW_SETTLE_S} s "
                         f"(`cmux trace record --seconds` takes at most {RELEASE_RECORD_MAX_S})")
        return record(opts)
    if opts.verb == "export":
        export_xctrace(opts.dir)
        print(summary_text(build(opts.dir)))
        return 0
    if opts.verb == "check-import":
        ok, report = check_import(opts.dir, opts.trace_processor)
        print(f"trace: import check {'ok' if ok else 'FAILED'}: tracks {report['tracks_by_kind']}, "
              f"{report['threads_imported']} threads imported" + "".join(f"\n  {p}" for p in report["problems"]))
        return 0 if ok else 1
    if opts.verb == "check-clock":
        if not os.path.isdir(opts.dir):
            print(f"trace: no recording directory {opts.dir}", file=sys.stderr)
            return 2  # nothing to check; 1 means a violation
        code, report = check_clock(opts.dir)
        print(clock_text(code, report))
        return code
    if opts.verb == "summary":
        summary = read_json(os.path.join(opts.dir, "summary.json"))
        if summary is None:
            sys.exit(f"trace: no summary.json in {opts.dir}")
        print(summary_text(summary))
        return 0
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())

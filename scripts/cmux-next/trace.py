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
                   action.perform / action.commit / action.gate (CmuxNextSignposts) and the debug.* timings
                   (categories stalls, tab-switch, pane-focus), on per-category tracks of the emitting process
  stalls           the app's main-thread watchdog (`debug.hangs`, threshold --hang-ms): every stall with its
                   main-thread stack sample and CPU time, on a track of the app
  daemon spans     CMUX_TUI_DEBUG_SPANS (the daemon's create-path timing marks; set as CMUX_NEXT_TUI_DEBUG_SPANS on the app): each request's marks as
                   nested slices on a track of the daemon (placed by when its line was written; see the doc)
  chromium         Chromium's own trace over CDP (`Tracing.start` on the DevTools port the Debug build opens
                   with CMUX_NEXT_CEF_EXTRA_SWITCHES=remote-debugging-port=N), clock-checked with
                   Tracing.recordClockSyncMarker: browser, GPU and renderer threads, merged into the same
                   pids (thread ids mapped by name)
  driver           what the scenario did and when: every key sent, every CLI call of the storm

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
  trace.py record --app APP --out DIR [--scenario stress-storm|light-storm] [--seconds 20] [--system-trace]
                  [--recorder auto|xctrace|sample] [--no-cef] [--hang-ms 8] [--storm-hz 10]
  trace.py record --bundle APP --out DIR [--socket S] [--seconds-cap 600] -- python3 scripts/cmux-next/every-action-sweep.py ...
  trace.py export DIR          rebuild DIR/trace.json.gz and the summary from DIR's raw files
  trace.py summary DIR         print DIR's summary again
  trace.py check-import DIR --trace-processor BIN
                               load DIR/trace.json.gz with Perfetto's trace_processor_shell: every signposts,
                               watchdog-stalls and daemon-spans track is its own named thread track with all its
                               slices, and the importer reports no error or data loss (DIR/import-check.json)
  trace.py --self-test         check the parsers (hand-written export shapes, not yet a real xctrace export),
                               the merge, the clock alignment, the stage bounds, the stop path, the export,
                               the signals, the one SIGINT to xctrace, the uint32 track ids and the
                               signpost clock of a host that slept

Docs: plans/cmux-next/trace.md (how to record, open in ui.perfetto.dev, read it). Not a CI gate.
"""
import argparse, bisect, collections, contextlib, gzip, importlib.util, json, os, re, select, shutil, signal, statistics, \
    subprocess, sys, tempfile, threading, time
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import LaunchError  # noqa: E402  (a failed launch is a SystemExit subclass: a stage error, not a signal)

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
# Chromium categories: tasks (toplevel), input and frame latency, GPU and compositor frames, browser UI and
# navigation. Not mojom/ipc (one event per message: tens of MB a second with 40 pages animating) and not the
# devtools timeline. The ring buffer keeps the last CHROME_BUFFER_KB of events, so a long window stays bounded.
CHROME_CATEGORIES = [
    "toplevel", "benchmark", "input", "latencyInfo", "gpu", "viz", "cc", "ui", "views", "browser",
    "navigation", "loading", "blink.user_timing",
]
CHROME_BUFFER_KB = 128 * 1024
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


def pct(values):
    if not values:
        return None
    s = sorted(values)
    pick = lambda p: s[min(len(s) - 1, int(round((len(s) - 1) * p)))]
    return {"n": len(s), "p50": round(pick(0.5), 2), "p95": round(pick(0.95), 2), "max": round(s[-1], 2)}


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
    "launch": 180 + 10 + 60 + STAGE_MARGIN_S,
    "stress-build": 1800,    # measured 691 s on cmux-lawrence-2 (macOS 27.0.1), 2026-10-23
    # Not measured: about 13 actions (4 workspaces, 1 workspace shown and split, 5 tabs, window placement) where
    # the STRESS build ran about 200 in 691 s (3.5 s each on a loaded host), so ~45 s, plus a cold Chromium start
    # (the first Chromium tab), times 2.5.
    "light-build": 300,
    # 4 group creates (CLI_SETUP_S each), snapshot.get, debug.cef, debug.window_list.
    "storm-setup": 4 * CLI_SETUP_S + 2 * RPC_S + RPC_SHORT_S + STAGE_MARGIN_S,
    # log stream attach, xctrace start (and its --attach fallback), CDP connect and Tracing.start, debug.hangs clear.
    "recorders-start": LOG_ATTACH_S + 2 * XCTRACE_START_S + CDP_CONNECT_S + CDP_START_S + RPC_SHORT_S + STAGE_MARGIN_S,
    # Added to --seconds (or --seconds-cap): the window's 2 s of settle and the typist's and storm's joins (30 s each,
    # after the call each has in flight). Also xctrace's own --time-limit past the window.
    "window-margin": 2 + 30 + 30 + STAGE_MARGIN_S,
    "driver-stop": 30 + 30 + STAGE_MARGIN_S,   # the typist's and the storm's joins
    "wrap-stop": WRAP_STOP_S + STAGE_MARGIN_S,  # WrappedCommand.stop; its cleanup is the group's SIGKILL
    "teardown-rpc": RPC_S + STAGE_MARGIN_S,  # debug.frames stop, debug.timings
    "window-state": RPC_SHORT_S + STAGE_MARGIN_S,  # debug.window_list at the window's end
    # Tracing.end, then IO.read of at most a 128 MB buffer; every call bounded (not measured). A cut drops the
    # DevTools socket (no process of ours) and loses only the Chromium events.
    "chromium-stop": 600,
    "stop-hangs": 15 + RPC_SHORT_S + STAGE_MARGIN_S,  # the drain thread's join, the last drain
    "stop-spans": 1 + 10 + 10 + STAGE_MARGIN_S,  # tail -F: the last line's arrival, TERM and its exit, the reader's join
    "stop-sampler": SAMPLER_WAIT_S + 5 + STAGE_MARGIN_S,
    "stop-signposts": 15 + 15 + STAGE_MARGIN_S,  # log stream: SIGINT and its exit, the reader's join
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
    none; counts sequence gaps (records the ring dropped before a drain)."""

    def __init__(self, rpc, path):
        super().__init__(name="hangs", daemon=True)
        self.rpc, self.path = rpc, path
        self.records, self.after, self.gaps = [], 0, 0
        self.stop_flag = threading.Event()

    def drain(self):
        reply = self.rpc("debug.hangs", {"after": self.after}, timeout=10)
        if not isinstance(reply, dict) or reply.get("error"):
            return reply
        for record in reply.get("records") or []:
            sequence = int(record.get("sequence") or 0)
            if self.after and sequence > self.after + 1:
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
    `unavailable` and `fallback` (null when healthy) and the pump's `fallback_ms`, so their names alone say
    nothing."""
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
        # The app keeps only CMUX_NEXT_* launch knobs (LaunchIdentity strips every other inherited CMUX* variable):
        # the daemon launch passes these two on as CMUX_TRACE_FLOWS and CMUX_TUI_DEBUG_SPANS (DaemonDiagnosticKnobs),
        # and the daemon's terminal hosts and holder inherit them.
        env = {"CMUX_NEXT_HANG_THRESHOLD_MS": str(opts.hang_ms), "CMUX_NEXT_TYPING_PROBE": self.probe,
               "CMUX_NEXT_TUI_DEBUG_SPANS": self.spans, "CMUX_NEXT_TRACE_FLOWS": self.flows, "CMUX_NEXT_NO_ACTIVATE": None}
        self.cdp_port = None
        if not opts.no_cef:
            self.cdp_port = opts.cdp_port or free_port()
            env["CMUX_NEXT_CEF_EXTRA_SWITCHES"] = f"remote-debugging-port={self.cdp_port}:remote-allow-origins=*"
        self.bench = BenchApp(path, out=out, env=env, window=None, screen=None)

    def rpc(self, method, params=None, timeout=60):
        return self.bench.rpc(method, params, timeout)

    def cli_run(self, *args, timeout=120):
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        env["CMUX_NEXT_CONFIG_FILE"] = os.path.join(self.bench.scratch, "cmux.json")
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
        self.signposts = self.wrapped = self.storm = self.typist = self.stress = self.phase = None
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
        if self.app:
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
    time profile by name (Chromium's ids on macOS are Mach port names, not system thread ids)."""
    path = os.path.join(out, "chromium-trace.json")
    data = read_json(path)
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


def chromium_on_own_tracks(chrome, samples, tracks):
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
            e = dict(e, tid=tracks.tid(key[0], ("chromium", key[1])))
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


# ---------------------------------------------------------------- key-press flows

# The hops of one terminal key press in causal order (plans/cmux-next/trace.md, "Key-press flows"). A tuple
# lists the alternatives of one hop: the `__terminal-host` model, then the holder model (where the daemon writes
# the PTY itself and the holder only reads the echo). `app.*` hops are the app's `key.flow` signpost events
# (TypingLatencyProbe), carrying the flow id; `daemon.send.*` carry it from the `send` request; the others are
# flow 0 on the terminal the press went to (CMUX_TRACE_FLOWS records of the daemon, host and holder).
FLOW_HOPS = [
    ("app.key.dispatch",), ("app.key.terminal",), ("app.io_write",), ("app.send",),
    ("daemon.send.write",), ("host.pty.write", "daemon.pty.write"), ("daemon.send.written",),
    ("host.pty.read", "holder.pty.read"), ("daemon.output.host", "daemon.output.holder"), ("daemon.output.attach",),
    ("app.output.decoded",), ("app.output.received",), ("app.output.parsed",), ("app.frame.contents",), ("app.frame.commit",),
]
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
FLOW_OPTIONAL = {"app.key.terminal"}
# The hops that say the key router handed the press to a terminal (else it ran a chord: not a flow).
FLOW_AT_TERMINAL = ("app.key.terminal", "app.io_write", "app.send")
# The flow-0 stages in causal order: (group, alternatives, the group or hop each one's window starts at).
FLOW0_STAGES = [(FLOW_GROUP.get(alternatives[0], alternatives[0]), alternatives, FLOW_ANCHOR[alternatives[0]])
                for alternatives in FLOW_HOPS if alternatives[0] in FLOW_ANCHOR]


def read_flow_records(out):
    """The daemon's, hosts' and holder's CMUX_TRACE_FLOWS records (OUT/flows/flows-<pid>.jsonl), times in us,
    and the dropped counts each process reported."""
    records, dropped = [], {}
    folder = os.path.join(out, "flows")
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        with open(os.path.join(folder, name), errors="replace") as f:
            for line in f:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if "dropped" in row:
                    dropped[name] = row["dropped"]
                elif row.get("hop"):
                    records.append({"hop": row["hop"], "flow": int(row.get("flow") or 0), "terminal": row.get("terminal") or "",
                                    "pid": row.get("pid"), "tid": row.get("tid"), "at_us": float(row["t_ns"]) / 1000.0})
    return records, dropped


def assemble_flows(app_events, records):
    """One entry per key press the app opened that reached a terminal: its hops in causal order, each {hop, at_us,
    pid, tid}, the hops it misses, the flow-0 hops it could not place (`ambiguous`), and whether it is complete
    (every hop of FLOW_HOPS but FLOW_OPTIONAL, one alternative each).

    A flow-0 record carries only its terminal, so it is placed by windows. The presses sent to one terminal
    (daemon.send.write with their flow id) are taken in send order; for each flow-0 stage, a press's window runs
    from its own anchor (the stage's cause) up to the next press's anchor on that terminal, and no later than the
    press's own decoded output. The press takes the record only when the window holds exactly one and the press
    before placed its own record of that stage; otherwise (none, two, or one that may be the press before's late
    one: keys typed faster than their echo) the stage stays missing and `ambiguous` says why. A record goes to one
    press at most."""
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
    by_flow = collections.defaultdict(dict)
    by_terminal = collections.defaultdict(list)
    for record in records:
        if record["flow"]:
            by_flow[record["flow"]].setdefault(record["hop"], record)
        else:
            by_terminal[(record["hop"], record["terminal"])].append(record)
    presses = []
    for flow in sorted(app_hops, key=lambda f: app_hops[f].get("app.key.dispatch", {"at_us": 0})["at_us"]):
        hops = app_hops[flow]
        # A press that never reached a terminal (a chord the key router ran as an action) has no echo to follow.
        if "app.key.dispatch" not in hops or not (any(h in hops for h in FLOW_AT_TERMINAL) or flow in by_flow):
            continue
        found = dict(hops)
        for hop, record in by_flow.get(flow, {}).items():
            found.setdefault(hop, {"hop": hop, "at_us": record["at_us"], "pid": record["pid"], "tid": record["tid"]})
        terminal = (by_flow.get(flow, {}).get("daemon.send.write") or {}).get("terminal")
        presses.append({"flow": flow, "terminal": terminal, "found": found, "groups": {}, "ambiguous": {},
                        "bound": (found.get("app.output.decoded") or {}).get("at_us", float("inf"))})
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
            anchors = [(p["groups"].get(anchor_name) or p["found"].get(anchor_name) or {}).get("at_us") for p in sent]
            taken, previous_placed = set(), True
            for index, press in enumerate(sent):
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
                    previous_placed = True
                    continue
                if candidates:
                    press["ambiguous"]["|".join(alternatives)] = {"candidates": len(candidates),
                                                                  "earlier_unplaced": not previous_placed}
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
        flows.append({"flow": press["flow"], "terminal": press["terminal"], "hops": chain, "missing": missing,
                      "ambiguous": press["ambiguous"], "complete": not missing})
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


def flow_events(flows, tracks, lane_names):
    """One slice per hop on a `key flow` track of the hop's process, from the hop to the next hop of the press,
    chained by Perfetto flow arrows (JSON flow v2: `bind_id`, `flow_out`, `flow_in`)."""
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
            if index:
                event["flow_in"] = True
            events.append(event)
    return events


def flow_summary(flows, dropped, warnings=()):
    """Per hop: the time from the previous hop the press has (FLOW_HOPS order) over the complete presses; key to
    the frame's commit; the incomplete presses with what they miss and which flow-0 hops were ambiguous; and
    `warnings` (flow_warnings) when the recording's flow data could not assemble."""
    complete = [f for f in flows if f["complete"]]
    steps = collections.defaultdict(list)
    totals = []
    for entry in complete:
        at = {h["hop"]: h["at_us"] for h in entry["hops"]}
        ordered = [next(hop for hop in alternatives if hop in at) for alternatives in FLOW_HOPS
                   if any(hop in at for hop in alternatives)]
        for previous, hop in zip(ordered, ordered[1:]):
            steps[hop].append((at[hop] - at[previous]) / 1000)
        totals.append((at["app.frame.commit"] - at["app.key.dispatch"]) / 1000)
    return {"presses": len(flows), "complete": len(complete), "key_to_commit_ms": pct(totals),
            "hop_ms": {hop: pct(values) for hop, values in steps.items()},
            "incomplete": [{"flow": f"0x{f['flow']:x}", "missing": f["missing"], "ambiguous": f.get("ambiguous") or {}}
                           for f in flows if not f["complete"]][:10],
            "dropped_records": dropped, "warnings": list(warnings),
            "flows": [{"flow": f"0x{f['flow']:x}", "terminal": f["terminal"], "complete": f["complete"],
                       "hops": [{"hop": h["hop"], "at_us": round(h["at_us"], 1), "pid": h["pid"]} for h in f["hops"]]}
                      for f in flows[:60]]}


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
    os_tids = {thread.get("tid") for _, _, thread, _ in samples} | {thread.get("tid") for _, _, thread, _, _ in states} \
        | {e.get("tid") for e in chrome}
    os_tids = {t for t in os_tids if isinstance(t, int)}
    tracks = SyntheticTracks(os_tids)
    events = flame_events(samples, offset_us, keep)
    # Signposts, on per-category lanes of their process.
    lanes = collections.defaultdict(Lanes)
    lane_names = {}
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
    # Key-press flows: the app's key.flow hops and the daemon's, hosts' and holder's flow records.
    flow_records, flow_dropped = read_flow_records(out)
    flow_signposts = [e for e in signposts["events"] if e["name"] == "key.flow"]
    key_flows = assemble_flows(flow_signposts, flow_records)
    flow_gaps = flow_warnings(flow_signposts, flow_records, key_flows)
    events += flow_events(key_flows, tracks, lane_names)
    for pid in {r["pid"] for r in flow_records if r.get("pid")}:
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

    def actions_during(a, b):
        found = []
        for i in actions:
            if i["start_us"] < b and i["end_us"] > a:
                found.append(f"{i['name']} {i['fields'].get('id', '')} ({i['ms']:.1f} ms)")
        return sorted(set(found))[:4]

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
            per_action[row["detail"]][row["name"]] = {k: row[k] for k in ("count", "p50_ms", "p95_ms", "max_ms")}
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
    lines.append("Input to commit per action (ms, p50/p95/max, n):")
    for action, rows in sorted((s.get("actions") or {}).items(), key=lambda kv: -((kv[1].get("action.commit") or {}).get("p95_ms") or 0)):
        if action == "*":
            continue
        i2c = rows.get("action.input_to_commit") or {}
        commit = rows.get("action.commit") or {}
        perform = rows.get("action.perform") or {}
        lines.append(f"  {action:32} input->commit {i2c.get('p50_ms', '-')}/{i2c.get('p95_ms', '-')}/{i2c.get('max_ms', '-')} "
                     f"n={i2c.get('count', 0)}  commit {commit.get('p50_ms', '-')}/{commit.get('p95_ms', '-')}  "
                     f"perform {perform.get('p50_ms', '-')}/{perform.get('p95_ms', '-')}"
                     + (f"  missed {rows['action.commit.missed']['count']}" if rows.get("action.commit.missed") else ""))
    flows = s.get("key_flows") or {}
    if flows.get("presses") or flows.get("warnings"):
        total = flows.get("key_to_commit_ms") or {}
        if flows.get("presses"):
            lines.append(f"Key-press flows: {flows['complete']} of {flows['presses']} presses complete; key to the echo "
                         f"frame's commit p50 {total.get('p50')} p95 {total.get('p95')} max {total.get('max')} ms")
        else:
            lines.append("Key-press flows: 0 presses assembled")
        for warning in flows.get("warnings") or []:
            lines.append(f"  WARNING: {warning}")
        for alternatives in FLOW_HOPS[1:]:
            for hop in alternatives:
                row = (flows.get("hop_ms") or {}).get(hop)
                if row:
                    lines.append(f"  {hop:24} +{row['p50']}/{row['p95']}/{row['max']} ms (p50/p95/max, n={row['n']})")
        for entry in flows.get("incomplete") or []:
            why = "".join(f"; ambiguous {hop} ({row['candidates']} candidate(s)"
                          + (", the press before has none of its own" if row.get("earlier_unplaced") else "") + ")"
                          for hop, row in (entry.get("ambiguous") or {}).items())
            lines.append(f"  incomplete {entry['flow']}: missing {', '.join(entry['missing'])}{why}")
        if flows.get("dropped_records"):
            lines.append(f"  flow records dropped (queue full): {flows['dropped_records']}")
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
IMPORT_TRACKS = ("signposts ", "watchdog stalls", "daemon spans", "key flow")
IMPORT_QUERY_FLOWS = """
select count(*) as flows from flow f join slice s on s.id = f.slice_out where s.category = 'key.flow'
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
    # Each key-press chain of n hop slices is n - 1 arrows (flow_out on all but the last, flow_in on all but the first).
    want_flows = sum(1 for e in events if e.get("flow_out"))
    got_flows = int((run_query(trace_processor, trace, IMPORT_QUERY_FLOWS) or [{"flows": 0}])[0].get("flows") or 0)
    problems, tracks = [], []
    if got_flows != want_flows:
        problems.append(f"{want_flows} key-flow arrows in the JSON, {got_flows} imported")
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


def build_fixture(out, slept_us=None):
    """Raw files of a small recording in `out` (hand-written shapes), then `build(out)`: its summary. With
    `slept_us`, the host slept that long since boot: the signposts' machTimestamps are mach_continuous_time
    (that much ahead of CLOCK_UPTIME_RAW, as `log` writes them, with the clock line SignpostStream writes) and
    an xctrace os-signpost table holds the same begin events (the xctrace clock is aligned to them)."""
    sample = signposts_lib.SAMPLE.replace('"processID":1', '"processID":42')
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
        assert summary["actions"]["tab.new"]["action.input_to_commit"]["p50_ms"] == 7.5, summary["actions"]
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
                  storm_hz=0, app=None, socket=None, scenario="light-storm", key_interval=0.1, chord_every=0)
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
    export and exits 128 + N."""
    for raised, code, line in ((RuntimeError("size_window: the display cannot hold STRESS"), 3, "ERROR: stage record failed"),
                               (SystemExit(143), 143, "TERMINATED by a signal (exit 143)")):
        with tempfile.TemporaryDirectory() as out:
            log = []
            rec = quiet_recording(out)
            rec.signposts = FakeSource("signposts", log)

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
    """Review 1: debug.cef always carries `unavailable: null`, `fallback: null` and the pump's `fallback_ms`, so
    a healthy reply is valid; a fallback, an unavailable reason or a state other than ready is not."""
    healthy = {"state": "ready", "unavailable": None, "fallback": None, "pump": {"fallback_ms": 16.7},
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
                  {"ph": "X", "pid": 1, "tid": 5, "ts": 1, "dur": 2, "name": "e"}]
        with gzip.open(os.path.join(out, "trace.json.gz"), "wt") as f:
            json.dump({"traceEvents": events}, f)
        fake = os.path.join(out, "trace_processor_shell")

        def write_fake(track_rows, stat_rows, flow_rows='"flows"\n0\n'):
            with open(fake, "w") as f:
                f.write("#!/bin/sh\n"
                        "if grep -q 'from stats' \"$2\"; then cat <<'EOF'\n" + stat_rows + "EOF\n"
                        "elif grep -q 'from flow' \"$2\"; then cat <<'EOF'\n" + flow_rows + "EOF\n"
                        "else cat <<'EOF'\n" + track_rows + "EOF\nfi\n")
            os.chmod(fake, 0o755)

        header = 'Loading trace: 0.01 MB\n"pid","tid","name","slices"\n'
        good = header + '1,7,"signposts action",2\n1,8,"watchdog stalls",1\n2,9,"daemon spans",1\n1,5,"Main Thread",1\n'
        no_stats = '"name","idx","severity","source","value"\n'
        write_fake(good, no_stats)
        ok, report = check_import(out, fake)
        assert ok and report["tracks_by_kind"] == {"signposts": 1, "watchdog stalls": 1, "daemon spans": 1, "key flow": 0}, report
        write_fake(good.replace('"signposts action",2', '"signposts action",1'), no_stats)
        ok, report = check_import(out, fake)
        assert not ok and "2 slices in the JSON, 1 imported" in report["problems"][0], report["problems"]
        write_fake(good, no_stats + '"json_parser_failure","[NULL]","error","trace",3\n')
        ok, report = check_import(out, fake)
        assert not ok and "json_parser_failure" in report["problems"][0], report["problems"]
        write_fake(good.replace('2,9,"daemon spans",1\n', ""), no_stats)
        ok, report = check_import(out, fake)
        assert not ok and "daemon spans (pid 2 tid 9) is not a thread" in report["problems"][0], report["problems"]


# The `key.flow` hops TypingLatencyProbe emits for one terminal key press, in order (Mark.hopName for the marks,
# `hop("app.key.terminal")` in TerminalSurfaceView.keyDown, closeAtCommit's app.frame.commit). app.key.dispatched
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
    assert summary["key_to_commit_ms"]["n"] == 2 and summary["hop_ms"]["daemon.send.write"]["n"] == 2, summary



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
    assert summary["presses"] == 4 and summary["complete"] == 0 and summary["key_to_commit_ms"] is None, summary
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
    assert flow_summary(flows, {})["key_to_commit_ms"]["n"] == 1
    # Presses whose flow id no daemon record carries: the send had no `flow`, so nothing past the app can join.
    events = [app(p2, hop, 2000.0 + i) for i, hop in enumerate(APP_KEY_HOPS)]
    records = [rec("daemon.send.write", 2010), rec("host.pty.write", 2015)]
    flows = assemble_flows(events, records)
    warnings = flow_warnings(events, records, flows)
    assert any("flow id" in w and "daemon.send.write" in w for w in warnings), warnings
    assert flow_warnings([], [], []) == [], "a recording without flows warns about nothing"

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


SELF_TESTS = [check_real_xctrace_exports, check_parsers_and_merge, check_stage_bounds, check_stage_errors,
              check_hold_defers_the_bound,
              check_stop_survives_a_failing_source, check_record_ends_cleanly, check_xctrace_held_before_start,
              check_wrapped_group_ends,
              check_export_part_files, check_xctrace_clock, check_cef_validity, check_bound_inside_a_swallowing_wait,
              check_signal_after_the_stop, check_xctrace_gets_one_sigint, check_synthetic_tids_fit_uint32,
              check_cli_named_cmux_is_not_the_app, check_refuses_a_running_bundle, check_signpost_clock,
              check_import_with_a_fake_trace_processor, check_key_flows, check_flow_hops_are_exclusive,
              check_flow_gaps_warn, check_focus_quiet_terminal]


def self_test():
    """Runs every check on its own (one failure does not hide the next) and prints one line each."""
    import io
    failed = []
    for check in SELF_TESTS:
        captured = io.StringIO()
        try:
            with contextlib.redirect_stdout(captured):
                check()
            print(f"ok   {check.__name__}")
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
    rec.add_argument("--scenario", choices=["stress-storm", "light-storm"], default="stress-storm")
    rec.add_argument("--seconds", type=float, default=20)
    rec.add_argument("--seconds-cap", type=float, default=600, help="wrap mode: the longest recording")
    rec.add_argument("--recorder", choices=["auto", "xctrace", "sample"], default="auto")
    rec.add_argument("--system-trace", action="store_true", help="System Trace (thread states, off-CPU reasons) as well")
    rec.add_argument("--no-cef", action="store_true", help="no DevTools port and no Chromium trace")
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

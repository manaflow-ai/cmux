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
  daemon spans     CMUX_TUI_DEBUG_SPANS (the daemon's create-path timing marks): each request's marks as
                   nested slices on a track of the daemon (placed by when its line was written; see the doc)
  chromium         Chromium's own trace over CDP (`Tracing.start` on the DevTools port the Debug build opens
                   with CMUX_NEXT_CEF_EXTRA_SWITCHES=remote-debugging-port=N), clock-checked with
                   Tracing.recordClockSyncMarker: browser, GPU and renderer threads, merged into the same
                   pids (thread ids mapped by name)
  driver           what the scenario did and when: every key sent, every CLI call of the storm

Every source is on one clock: CLOCK_UPTIME_RAW (mach_absolute_time) in microseconds. It then prints a short
summary (also SUMMARY.txt and summary.json): the longest main-thread stalls with their stacks, input to commit
per action, and cross-process waits (main thread off CPU inside an action or a stall, by what it waited on:
the daemon, Chromium, a lock, WindowServer, disk, XPC).

Scenarios (record --scenario):
  stress-storm   build STRESS (perf-stress-session.py), then for --seconds: a CLI storm at --storm-hz (workspace
                 move, task status, group add, status pill, as sidebar-churn-typing.py does) while keys are
                 typed into the focused terminal every --key-interval s, with an action chord pair every
                 --chord-every keys (Cmd-T/Cmd-W, Cmd-D/Cmd-W, next/previous workspace) through `debug.key`
  light-storm    the same in the launch workspace, without STRESS
  -- COMMAND     wrap mode: record while COMMAND runs (the every-action sweep or sidebar-churn-typing.py, which
                 launch their own app): time profile and signposts only (COMMAND's app gets no CDP port, no
                 daemon spans and no hang drain; pass --socket S for the hang drain)

Usage (a fleet GUI host, never Lawrence's Mac):
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/trace.py record --app "$NX_APP" --out "$NX_ARTIFACTS/trace" --scenario stress-storm
  trace.py record --app APP --out DIR [--scenario stress-storm|light-storm] [--seconds 20] [--system-trace]
                  [--recorder auto|xctrace|sample] [--no-cef] [--hang-ms 8] [--storm-hz 10]
  trace.py record --bundle APP --out DIR [--socket S] [--seconds-cap 600] -- python3 scripts/cmux-next/every-action-sweep.py ...
  trace.py export DIR          rebuild DIR/trace.json.gz and the summary from DIR's raw files
  trace.py summary DIR         print DIR's summary again
  trace.py --self-test         check the parsers and the merge on built-in samples

Docs: plans/cmux-next/trace.md (how to record, open in ui.perfetto.dev, read it). Not a CI gate.
"""
import argparse, collections, gzip, importlib.util, json, os, re, signal, statistics, subprocess, sys, tempfile, threading, time
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
SUBSYSTEM = "com.cmuxterm.app.next"
SYNTHETIC_TID = 1 << 40  # tracks that are not OS threads (signpost lanes, daemon spans, stalls, driver)
DRIVER_PID = 0  # Perfetto shows pid 0 as its own process: the scenario driver's own events
FLAME_DEPTH = 120
EXPORT_TIMEOUT_S = 900  # one table export at most: a stuck export must not hold the GUI host (no export measured yet)  # root-most frames kept per sample (deeper Swift stacks are rare; the leaf is in args)
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


def uptime_us():
    """CLOCK_UPTIME_RAW (mach_absolute_time) in microseconds: the clock of every source in the trace."""
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW) / 1000.0


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

# Each stage of a recording has a bound. A stage that passes it ends the recording at once, loudly, and the
# trace and summary are still written from what was recorded (job 7 on 2026-10-23 sat silent for over an hour
# after its STRESS build). The bounds catch a hung stage; they are not expectations. Where a stage was
# measured the bound is about 2.5 times the measurement; otherwise it is the sum of the stage's own inner
# timeouts with a margin, so it fires only when an inner timeout failed to.
STAGE_BOUNDS_S = {
    "launch": 300,           # BenchApp.launch waits 180 s for the socket, then up to 10 s for a crash report
    "stress-build": 1800,    # measured 691 s on cmux-lawrence-2 (macOS 27.0.1), 2026-10-23
    "storm-setup": 180,      # 4 CLI calls and 2 socket reads, each bounded by its own timeout
    "recorders-start": 300,  # log stream attach 15 s, xctrace start 120 s (and 120 s for its fallback), CDP 20 s
    "window-margin": 120,    # added to --seconds: the typist and storm joins (30 s each) after the window
    "teardown-rpc": 60,      # debug.frames stop and debug.timings: 20 s socket timeouts
    "chromium-stop": 600,    # Tracing.end, then IO.read of at most a 128 MB buffer; every call bounded (not measured)
    "drains-stop": 120,      # hang drain, span follower, sampler and log stream joins (15 s each)
    "xctrace-save": 960,     # XcTrace.stop waits 900 s for xctrace to save
    "app-stop": 180,         # debug.quit, 30 s wait, TERM, 15 s, the tag teardown
    "export": 1800,          # every table export, each bounded by EXPORT_TIMEOUT_S
    "build": 900,            # the merge and the summary (Python over the exported XML)
}
HEARTBEAT_S = 60  # a stage that runs longer prints that it is still running once a minute


class StageTimeout(Exception):
    """A recording stage passed its bound (raised in the main thread by the stage's interval timer)."""

    def __init__(self, name, bound):
        super().__init__(f"stage {name} passed its bound of {bound:g} s")
        self.name, self.bound = name, bound


class Stages:
    """Runs each stage of a recording under its bound, with a heartbeat, and records it in `meta`.

    `run(name, bound)` arms SIGALRM for the bound (main thread only, one stage at a time): when it fires, the
    blocking call in the stage raises StageTimeout, `on_timeout` cleans up what the stage started, and the
    stage ends. A fatal stage re-raises (nothing after it can run); any other stage is noted and the recording
    goes on with its next stage.
    """

    def __init__(self, meta, heartbeat_s=HEARTBEAT_S, log=None):
        self.meta, self.heartbeat_s, self.log = meta, heartbeat_s, log or note
        meta.setdefault("stages", [])
        meta.setdefault("timed_out", [])
        self.active = None

    def _alarm(self, _signum, _frame):
        name, bound = self.active
        raise StageTimeout(name, bound)

    class _Run:
        def __init__(self, stages, name, bound, fatal, on_timeout):
            self.stages, self.name, self.bound, self.fatal, self.on_timeout = stages, name, bound, fatal, on_timeout

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
            seconds = round(time.monotonic() - self.started, 1)
            timed_out = isinstance(error, StageTimeout)
            stages.meta["stages"].append({"stage": self.name, "seconds": seconds, "bound_s": self.bound,
                                          "timed_out": timed_out})
            if not timed_out:
                return False
            stages.meta["timed_out"].append(self.name)
            stages.log(f"STAGE {self.name.upper()} PASSED ITS BOUND OF {self.bound:g} s: ending it; the trace and "
                       f"summary are written from what was recorded")
            if self.on_timeout:
                try:
                    self.on_timeout()
                except Exception as cleanup:  # the cleanup of a hung stage must not hide the timeout itself
                    stages.log(f"stage {self.name}: cleanup after the timeout failed: {cleanup!r}")
            return not self.fatal

    def run(self, name, bound=None, fatal=False, on_timeout=None):
        return self._Run(self, name, STAGE_BOUNDS_S[name] if bound is None else bound, fatal, on_timeout)


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
    if name.startswith("cmux DEV") or name.startswith("cmux NIGHTLY") or name == "cmux":
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
        self.path, self.proc, self.reader = path, None, None
        self.attached = threading.Event()

    def start(self, timeout=15):
        timebase = signposts_lib.local_timebase()
        self.file = open(self.path, "w")
        if timebase:
            self.file.write(f"#timebase {timebase[0]}/{timebase[1]}\n")
        self.proc = subprocess.Popen(["/usr/bin/log", "stream", "--signpost", "--style", "ndjson", "--predicate",
                                      f'subsystem == "{SUBSYSTEM}"'], stdout=subprocess.PIPE, text=True, bufsize=1)

        def drain():
            # Reads for the whole run: a full pipe would block `log stream` and logd would drop events.
            for line in self.proc.stdout:
                self.file.write(line)
                self.attached.set()
            self.attached.set()

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

    def command(self):
        template = "System Trace" if self.system_trace else "Time Profiler"
        target = ["--attach", str(self.attach)] if self.attach else ["--all-processes"]
        command = ["xcrun", "xctrace", "record", "--template", template, *target, "--output", self.path,
                   "--no-prompt", "--time-limit", f"{int(self.cap_s)}s"]
        extra = [] if self.system_trace else ["os_signpost", "Points of Interest"]  # System Trace has them
        for instrument in extra:
            command += ["--instrument", instrument]
        return command

    def start(self, timeout=120):
        if os.path.exists(self.path):
            subprocess.run(["rm", "-rf", self.path])
        log = open(self.log_path, "w")
        self.proc = subprocess.Popen(self.command(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)

        def read():
            for line in self.proc.stdout:
                log.write(line)
                log.flush()
                if "Starting recording" in line or "Ctrl-C to stop" in line:
                    self.started.set()
            log.close()
            self.ended.set()
            self.started.set()

        threading.Thread(target=read, name="xctrace", daemon=True).start()
        self.started.wait(timeout)
        if self.proc.poll() is not None:
            raise RuntimeError(f"xctrace record exited {self.proc.returncode}: {open(self.log_path).read()[-800:]}")
        self.started_us = uptime_us()
        self.started_wall = time.time()

    def interrupt(self):
        """Ends the recording now (SIGINT, as Ctrl-C); xctrace then processes and saves it (``stop`` waits)."""
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            self.interrupted_us = uptime_us()

    def kill(self):
        """Ends xctrace without saving (its save passed the bound)."""
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()

    def stop(self, timeout=900):
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

    def start(self, pids, seconds):
        for pid, role in pids:
            path = os.path.join(self.out, f"sample-{role}-{pid}.txt")
            self.procs.append((subprocess.Popen(["/usr/bin/sample", str(pid), str(max(1, int(seconds))), "1", "-mayDie",
                                                 "-file", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL),
                               path))

    def stop(self):
        for proc, _ in self.procs:
            try:
                proc.wait(timeout=120)
            except subprocess.TimeoutExpired:
                proc.terminate()


class FileFollower:
    """Follows a file that another process appends lines to (`tail -F`, kqueue driven), stamping each line
    with the time it arrived: the daemon's debug spans carry durations only, no clock."""

    def __init__(self, source, stamped):
        self.source, self.stamped, self.proc, self.thread = source, stamped, None, None

    def start(self):
        open(self.source, "a").close()
        self.out = open(self.stamped, "w")
        self.proc = subprocess.Popen(["/usr/bin/tail", "-F", "-n", "+1", self.source], stdout=subprocess.PIPE, text=True,
                                     bufsize=1, stderr=subprocess.DEVNULL)

        def read():
            for line in self.proc.stdout:
                line = line.strip()
                if line:
                    self.out.write(json.dumps({"at_us": uptime_us(), "line": line}) + "\n")
                    self.out.flush()

        self.thread = threading.Thread(target=read, name="spans", daemon=True)
        self.thread.start()

    def stop(self):
        time.sleep(0.3)  # the last line written before the stop reaches tail (one kqueue wakeup)
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            self.proc.wait(timeout=10)
        if self.thread:
            self.thread.join(timeout=10)
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
        self.join(timeout=15)
        self.drain()
        write_json(self.path, {"records": self.records, "dropped": self.gaps, "summary": getattr(self, "summary", None)})


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


def storm_setup(app, rpc, stress):
    """Groups for the storm and the workspace ids it rearranges (all but the shown one)."""
    groups = []
    for index in range(4):
        name = f"trace group {index}"
        if app.cli_run("workspace", "group", "create", "--name", name).returncode == 0:
            groups.append(name)
    topology = (rpc("snapshot.get") or {}).get("topology") or {}
    shown = (topology.get("focus") or {}).get("workspace")
    workspaces = [w["id"] for w in topology.get("workspaces") or [] if w.get("id") and w.get("id") != shown]
    return groups, workspaces


# ---------------------------------------------------------------- the app

class TraceApp:
    """The tagged app under trace: BenchApp plus the trace's environment and the bundled CLI."""

    def __init__(self, path, out, opts):
        from bench_launch import BenchApp
        self.spans = os.path.join(out, "daemon-spans.jsonl")
        self.probe = os.path.join(out, "typing.csv")
        env = {"CMUX_NEXT_HANG_THRESHOLD_MS": str(opts.hang_ms), "CMUX_NEXT_TYPING_PROBE": self.probe,
               "CMUX_TUI_DEBUG_SPANS": self.spans}
        self.cdp_port = None
        if not opts.no_cef:
            self.cdp_port = opts.cdp_port or free_port()
            env["CMUX_NEXT_CEF_EXTRA_SWITCHES"] = f"remote-debugging-port={self.cdp_port}:remote-allow-origins=*"
        self.bench = BenchApp(path, out=out, env=env, window=(80, 40, 1600, 1000))

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
    """Records one scenario; returns 0, or 3 when a stage passed its bound (the trace and summary still written)."""
    out = os.path.abspath(opts.out)
    os.makedirs(out, exist_ok=True)
    bundle = os.path.realpath(opts.app or opts.bundle).rstrip("/") if (opts.app or opts.bundle) else None
    meta = {"host": os.uname().nodename, "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True,
                                                                 text=True).stdout.strip(),
            "bundle": bundle, "scenario": "wrap" if opts.command else opts.scenario, "seconds": opts.seconds,
            "argv": sys.argv[1:], "recorder": None, "sources": {}}
    recorder = opts.recorder
    if recorder == "auto":
        recorder = "xctrace" if subprocess.run(["xcrun", "xctrace", "version"], capture_output=True).returncode == 0 else "sample"
    meta["recorder"] = recorder
    stages = Stages(meta)
    app = rpc = xc = sampler = spans = hangs = chromium = signposts = None
    groups, workspaces, driver_events, processes = [], [], [], {}
    frames_started, probe_before = None, 0
    try:
        try:
            if opts.app:
                app = TraceApp(opts.app, out, opts)
                with stages.run("launch", fatal=True):
                    app.bench.launch()
                rpc = app.rpc
                meta["app_pid"] = app.bench.process.pid
                meta["tag"] = app.bench.tag
                if opts.scenario == "stress-storm":
                    with stages.run("stress-build", fatal=True):
                        build_stress(rpc, meta)
                with stages.run("storm-setup", fatal=True):
                    groups, workspaces = storm_setup(app, rpc, opts.scenario == "stress-storm")
                    meta["cef"] = cef_validity(rpc)
            if opts.socket and not rpc:
                rpc = load("perf_stress_session", "perf-stress-session.py").socket_rpc(opts.socket)
            with stages.run("recorders-start", fatal=True,
                            on_timeout=lambda: xc and xc.interrupt()):
                note("recorders starting")
                processes["start"] = ps_snapshot(bundle)
                signposts = SignpostStream(os.path.join(out, "signposts.ndjson"))
                signposts.start()
                if recorder == "xctrace":
                    xc = start_xctrace(out, opts, meta)
                if app:
                    spans = FileFollower(app.spans, os.path.join(out, "daemon-spans-stamped.jsonl"))
                    spans.start()
                if rpc:
                    rpc("debug.hangs", {"clear": True})
                    hangs = HangDrain(rpc, os.path.join(out, "hangs.json"))
                    hangs.start()
                if app and app.cdp_port:
                    chromium = ChromiumTracer(app.cdp_port, out)
                    try:
                        chromium.start()
                    except (RuntimeError, OSError, ConnectionError) as error:
                        note(f"no Chromium trace: {error}")
                        meta["sources"]["chromium_error"] = str(error)[:300]
                        chromium = None
                if recorder == "sample":
                    sampler = Sampler(out)
                    pids = [(pid, info["role"]) for pid, info in processes["start"].items() if info["role"] in ("app", "daemon")]
                    sampler.start(pids, opts.seconds)
            meta["window_start_us"] = uptime_us()
            note(f"window starts: scenario {meta['scenario']} " +
                 (f"(at most {opts.seconds_cap:g} s)" if opts.command else f"for {opts.seconds:g} s"))
            meta["load_at_start"] = [round(x, 1) for x in os.getloadavg()]  # a loaded host stretches every number
            frames_started = rpc and rpc("debug.frames", {"action": "start"}, timeout=20)
            probe_before = len(read_probe(app.probe)) if app else 0
            bound = (opts.seconds_cap if opts.command else opts.seconds) + STAGE_BOUNDS_S["window-margin"]
            with stages.run("window", bound):
                run_window(opts, app, rpc, groups, workspaces, driver_events, meta)
        except StageTimeout:
            pass  # a fatal stage: Stages noted it; what was recorded is still written below
        finally:
            meta["window_end_us"] = uptime_us()
            if meta.get("window_start_us"):
                note("window ends")
            stop_recording(stages, opts, meta, app, rpc, xc, sampler, spans, hangs, chromium, signposts, frames_started,
                           probe_before, processes, bundle, driver_events, out)
    finally:
        write_json(os.path.join(out, "meta.json"), meta)
        if app and not opts.keep:
            with stages.run("app-stop"):
                app.bench.stop()
            write_json(os.path.join(out, "meta.json"), meta)
    if recorder == "xctrace":
        with stages.run("export"):
            export_xctrace(out)
        if not opts.keep_recording:
            subprocess.run(["rm", "-rf", os.path.join(out, "recording.trace")])  # GBs; the exported tables stay
    write_json(os.path.join(out, "meta.json"), meta)
    summary = None
    with stages.run("build"):
        summary = build(out)
    if summary is None:
        summary = {"timed_out": meta["timed_out"], "stages": meta["stages"]}
        write_json(os.path.join(out, "summary.json"), summary)
    else:
        # The build reads meta.json before the build stage ends; add its own row.
        summary["stages"], summary["timed_out"] = meta["stages"], meta["timed_out"]
        write_json(os.path.join(out, "summary.json"), summary)
        with open(os.path.join(out, "SUMMARY.txt"), "w") as f:
            f.write(summary_text(summary) + "\n")
    print(summary_text(summary), flush=True)
    return 3 if meta["timed_out"] else 0


def build_stress(rpc, meta):
    """STRESS through perf-stress-session.py; a session that misses the shape is traced and says so."""
    builder = load("perf_stress_session", "perf-stress-session.py")
    started = time.monotonic()
    meta["stress"] = builder.Stress(rpc, log=note).build(check=False)
    try:
        builder.Stress.check(meta["stress"])
    except builder.StressShapeError as error:
        # A trace of a session that is not quite STRESS still answers "why did this lag"; it says so.
        meta["stress"]["shape_error"] = str(error)[:600]
        note(f"STRESS shape: {error}")
    note(f"STRESS built in {time.monotonic() - started:.0f} s: {json.dumps(meta['stress'])}")


def start_xctrace(out, opts, meta):
    """Starts the all-process recording, or the app process only when xctrace refuses --all-processes."""
    xc = XcTrace(out, system_trace=opts.system_trace,
                 cap_s=(opts.seconds_cap if opts.command else opts.seconds) + STAGE_BOUNDS_S["window-margin"])
    try:
        xc.start()
    except RuntimeError as error:
        if not meta.get("app_pid"):
            raise
        note(f"{error}; recording the app process only")
        xc = XcTrace(out, system_trace=opts.system_trace, cap_s=opts.seconds + STAGE_BOUNDS_S["window-margin"])
        xc.attach = meta["app_pid"]
        xc.start()
    note(f"xctrace recording ({' '.join(xc.command()[3:7])})")
    meta["xctrace"] = {"command": xc.command(), "started_us": xc.started_us, "started_wall": xc.started_wall}
    return xc


def run_window(opts, app, rpc, groups, workspaces, driver_events, meta):
    """The measured window: the wrapped command, or the storm and the typist for --seconds."""
    if opts.command:
        note(f"wrap: running {' '.join(opts.command)[:200]}")
        meta["command_exit"] = subprocess.run(opts.command).returncode
        return
    storm = Storm(app.cli_run, workspaces, groups, opts.storm_hz, driver_events) if opts.storm_hz > 0 else None
    typist = Typist(rpc, opts.key_interval, opts.chord_every, driver_events)
    time.sleep(1.0)  # the recorders' first second is their own start-up cost; the scenario starts after it
    phase = {"kind": "phase", "name": f"scenario {opts.scenario}", "start_us": uptime_us(), "end_us": None, "args": {}}
    driver_events.append(phase)
    try:
        if storm:
            storm.start()
        typist.start()
        time.sleep(opts.seconds)  # the measured window itself
    finally:
        typist.stop()
        if storm:
            storm.stop()
        phase["end_us"] = uptime_us()
        meta["storm_ops"] = dict(storm.ops) if storm else {}
        meta["keys"] = typist.keys
        meta["chords"] = dict(typist.chords)
    time.sleep(1.0)  # the last action's frames and replies land inside the window


def stop_recording(stages, opts, meta, app, rpc, xc, sampler, spans, hangs, chromium, signposts, frames_started,
                   probe_before, processes, bundle, driver_events, out):
    """Stops every source, each stage under its own bound, so one hung source never holds the others."""
    if xc:
        # The recording ends with the window: every other source stops after it (the Chromium trace's transfer
        # takes minutes), and an all-process recording that ran through those minutes would take as long again
        # to save and export.
        xc.interrupt()
    if rpc and frames_started is not None:
        with stages.run("teardown-rpc"):
            meta["frames"] = rpc("debug.frames", {"action": "stop"}, timeout=20)
    if chromium:
        with stages.run("chromium-stop", on_timeout=chromium.close):
            note("chromium trace stopping")
            meta["sources"]["chromium"] = chromium.stop()
            note(f"chromium trace saved: {os.path.getsize(chromium.path) / 1e6:.0f} MB" if os.path.exists(chromium.path)
                 else "chromium trace: nothing saved")
    with stages.run("drains-stop"):
        for source in (hangs, spans, sampler, signposts):
            if source:
                source.stop()
    if xc:
        with stages.run("xctrace-save", on_timeout=xc.kill):
            note("xctrace stopping (it processes the recording before it saves)")
            started = time.monotonic()
            meta["sources"]["xctrace_saved"] = xc.stop()
            note(f"xctrace saved in {time.monotonic() - started:.0f} s")
    processes["end"] = ps_snapshot(bundle)
    write_json(os.path.join(out, "processes.json"), processes)
    write_json(os.path.join(out, "driver.json"), driver_events)
    if app and rpc and meta.get("window_start_us"):
        rows = read_probe(app.probe)[probe_before:]
        complete = [r for r in rows if r.get("complete") == "1" and r.get("contents_ms")]
        meta["key_to_frame_ms"] = pct([float(r["contents_ms"]) for r in complete])
        with stages.run("teardown-rpc"):
            meta["timings"] = rpc("debug.timings", timeout=20)


def cef_validity(rpc):
    """Measurement validity (perf-lead brief): Chromium really ran, no unavailable or fallback state."""
    reply = rpc("debug.cef", timeout=20)
    text = json.dumps(reply)[:200000] if reply is not None else ""
    return {"unavailable_or_fallback": bool(re.search(r"unavailable|fallback", text, re.I)),
            "excerpt": text[:400]}


def read_probe(path):
    import csv
    try:
        with open(path) as f:
            return list(csv.DictReader(f))
    except OSError:
        return []


# ---------------------------------------------------------------- xctrace export and parse

def export_xctrace(out):
    """Exports the recording's tables to XML files beside it (once; `export` reuses them)."""
    trace = os.path.join(out, "recording.trace")
    if not os.path.exists(trace):
        return {}
    toc_path = os.path.join(out, "xctrace-toc.xml")
    with open(toc_path, "w") as f:
        subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--toc"], stdout=f, stderr=subprocess.DEVNULL)
    toc = parse_toc(toc_path)
    exported = {}
    for schema in toc["schemas"]:
        if schema not in ("time-profile", "os-signpost", "syscall"):
            continue
        path = os.path.join(out, f"xctrace-{schema}.xml")
        if not os.path.exists(path):
            try:
                subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                                f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]', "--output", path],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=EXPORT_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                note(f"export of {schema} took over {EXPORT_TIMEOUT_S} s; the trace has no {schema} table")
                if os.path.exists(path):
                    os.unlink(path)  # a partial XML file would not parse
        if os.path.exists(path):
            exported[schema] = path
            note(f"exported {schema}: {os.path.getsize(path) / 1e6:.0f} MB")
    return exported


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


THREAD_FMT = re.compile(r"^(.*?)\s+0x[0-9a-fA-F]+\s*\((.*?)(?:,\s*pid:\s*(\d+))?\)\s*$")


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
    """The rows of one exported table, each {column tag: value}, with `ref` attributes resolved. Streams: a
    table of a million samples never sits in memory as XML."""
    ids, vals, node = {}, {}, None
    for event, elem in ET.iterparse(path, events=("start", "end")):
        if event == "start":
            if elem.tag == "node":
                node = elem
                ids.clear()  # each exported table numbers its ids from 1
            continue
        if elem.tag == "row":
            row = {}
            for child in elem:
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
        t = scalar(row.get("sample-time"))
        weight = scalar(row.get("weight")) or 1_000_000
        stack = row.get("backtrace") or row.get("tagged-backtrace") or row.get("kperf-bt") or ()
        if not isinstance(t, int):
            continue
        samples.append((t, weight if isinstance(weight, int) else 1_000_000, thread, stack if isinstance(stack, tuple) else ()))
    return samples


def xctrace_signposts(path):
    """[(t_ns, name, event type, message)] of the cmux subsystem from the os-signpost table, for the clock."""
    found = []
    for row in xctrace_rows(path):
        subsystem = scalar(row.get("subsystem"))
        if subsystem != SUBSYSTEM:
            continue
        t = scalar(row.get("time") or row.get("event-time") or row.get("start"))
        name = scalar(row.get("name") or row.get("signpost-name"))
        kind = scalar(row.get("event-type"))
        identifier = scalar(row.get("identifier") or row.get("signpost-identifier") or row.get("os-signpost-identifier"))
        if isinstance(t, int) and name:
            found.append((t, str(name), str(kind or ""), identifier))
    return found


def syscall_waits(path, min_ns=1_000_000):
    """[(start_ns, duration_ns, thread dict, syscall, backtrace leaf first)] of System Trace's syscall table: the
    calls of 1 ms or longer (a thread inside one is off CPU, and the stack says what it waits for)."""
    found = []
    for row in xctrace_rows(path):
        thread = row.get("thread")
        start = scalar(row.get("start-time"))
        duration = scalar(row.get("duration"))
        if not (isinstance(thread, dict) and isinstance(start, int) and isinstance(duration, int)) or duration < min_ns:
            continue
        call = row.get("syscall")
        call = (call[1] or call[0]) if isinstance(call, tuple) else str(call or "")
        stack = row.get("backtrace") or ()
        found.append((start, duration, thread, str(call), stack if isinstance(stack, tuple) else ()))
    return found


def xctrace_offset_us(out, toc, signposts, meta):
    """Microseconds to add to an xctrace time (ns since its start / 1000) for CLOCK_UPTIME_RAW: from the same
    signposts in both recordings (begin events matched by name in order), else the recording's start date."""
    path = os.path.join(out, "xctrace-os-signpost.xml")
    if os.path.exists(path) and signposts:
        xc = sorted((t, n, k) for t, n, k, _ in xctrace_signposts(path) if k.lower().startswith("begin"))
        by_name = collections.defaultdict(list)
        for t, name, _ in xc:
            by_name[name].append(t / 1000.0)
        log = collections.defaultdict(list)
        for interval in signposts:
            log[interval["name"]].append(interval["start_us"])
        candidates = []
        for name, xs in by_name.items():
            ls = sorted(log.get(name) or [])
            if len(ls) == len(xs):
                candidates += [l - x for l, x in zip(ls, xs)]
        if len(candidates) >= 3:
            median = statistics.median(candidates)
            spread = max(abs(c - median) for c in candidates)
            if spread < 2000:
                return median, f"signposts ({len(candidates)} matched, spread {spread:.0f} us)"
    started = (meta.get("xctrace") or {}).get("started_us")
    if toc.get("start_date") and started:
        from datetime import datetime
        try:
            start_wall = datetime.fromisoformat(toc["start_date"].replace("Z", "+00:00")).timestamp()
            wall = meta["xctrace"]["started_wall"]
            return started - (wall - start_wall) * 1e6, "start date (about 1 ms)"
        except (ValueError, KeyError):
            pass
    if started:
        return started, "recorder start (about 100 ms)"
    return 0.0, "none"


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


def read_signposts(path):
    """Signpost intervals and events with absolute times (us) from a saved `log stream --signpost` file."""
    numer = denom = 0
    timebase = signposts_lib.local_timebase()
    if timebase:
        numer, denom = timebase
    open_intervals, intervals, events, lost = {}, [], [], 0
    try:
        lines = open(path).read().splitlines()
    except OSError:
        return {"intervals": [], "events": [], "lost": 0, "unpaired": 0}
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
        at = mach * numer / denom / 1000.0
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
    return {"intervals": intervals, "events": events, "lost": lost, "unpaired": len(open_intervals)}


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
                    events.append({"ph": "X", "pid": pid, "tid": tid, "ts": round(start, 3), "dur": round(at - start, 3),
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


def daemon_span_events(out, daemon_pid):
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
        tid = SYNTHETIC_TID + 100 + lane
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
    return events, {"lines": lines, "lanes": len(lanes.stacks)}, rows


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
    offset_us, offset_how = xctrace_offset_us(out, toc, signposts["intervals"], meta)
    samples = []
    tp = next((os.path.join(out, f"xctrace-{s}.xml") for s in ("time-profile", "time-sample")
               if os.path.exists(os.path.join(out, f"xctrace-{s}.xml"))), None)
    if tp:
        samples = time_profile_samples(tp)
    states = []
    if os.path.exists(os.path.join(out, "xctrace-syscall.xml")):
        states = syscall_waits(os.path.join(out, "xctrace-syscall.xml"))
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
    app_pid = meta.get("app_pid") or next((p for p, r in roles.items() if r == "app"), None)
    daemon_pid = next((p for p, i in sorted(known.items()) if i["role"] == "daemon" and " server" in i["command"]), None) \
        or next((p for p, r in roles.items() if r == "daemon"), None) or 1
    flame_roles = set(ROLE_ORDER) - {"other"}
    keep = lambda thread: roles.get(thread.get("pid"), "other") in flame_roles
    events = flame_events(samples, offset_us, keep)
    # Signposts, on per-category lanes of their process.
    lanes = collections.defaultdict(Lanes)
    lane_names = {}
    categories = {}  # category -> its block of 64 synthetic thread ids (stable across runs, unlike hash())
    category_tid = lambda category: SYNTHETIC_TID + 1000 + 64 * categories.setdefault(category, len(categories))
    for interval in signposts["intervals"]:
        pid = interval["pid"] or app_pid
        category = interval["category"] or "signpost"
        lane = lanes[(pid, category)].place(interval["start_us"], interval["end_us"])
        tid = category_tid(category) + min(lane, 62)
        lane_names[(pid, tid)] = f"signposts {category}" + (f" {lane + 1}" if lane else "")
        detail = interval["fields"].get("id") or interval["fields"].get("kind") or ""
        events.append({"ph": "X", "pid": pid, "tid": tid, "ts": interval["start_us"], "dur": interval["end_us"] - interval["start_us"],
                       "name": f"{interval['name']} {detail}".strip(), "cat": f"signpost.{category}",
                       "args": {"begin": interval["message"], "end": interval["end_message"], "thread": interval["tid"]}})
    for event in signposts["events"]:
        pid = event["pid"] or app_pid
        tid = category_tid(event["category"] or "signpost") + 63
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
        tid = SYNTHETIC_TID + 200 + lane
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
    state_tracks = {}
    for start, duration, thread, call, stack in states:
        if not keep(thread):
            continue
        reason = wait_class(list(stack)) if stack else "unknown"
        if reason == "idle":
            continue
        ts = start / 1000.0 + offset_us
        key = (thread["pid"], thread["tid"])
        state_tid = state_tracks.setdefault(key, SYNTHETIC_TID + 5000 + len(state_tracks))
        lane_names[(thread["pid"], state_tid)] = f"{thread.get('name') or thread['tid']} syscalls"
        events.append({"ph": "X", "pid": thread["pid"], "tid": state_tid, "ts": ts, "dur": duration / 1000.0,
                       "cat": "syscall", "name": f"{call}: {reason}", "args": {"stack": list(stack)[:30]}})
        blocked.append({"pid": thread["pid"], "tid": thread["tid"], "thread": thread.get("name"), "start_us": ts,
                        "end_us": ts + duration / 1000.0, "call": call, "class": reason, "stack": list(stack)[:30]})
    # Daemon spans, Chromium, the driver.
    span_events, span_info, span_rows = daemon_span_events(out, daemon_pid)
    events += span_events
    chrome, chrome_info = chromium_events(out, threads_by_pid)
    events += chrome
    driver = read_json(os.path.join(out, "driver.json"), []) or []
    driver_lanes = collections.defaultdict(Lanes)
    for item in driver:
        start, end = item.get("start_us"), item.get("end_us") or item.get("start_us")
        if start is None:
            continue
        lane = driver_lanes[item["kind"]].place(start, end)
        tid = SYNTHETIC_TID + 300 + 20 * ["phase", "key", "cli"].index(item["kind"]) + lane
        lane_names[(DRIVER_PID, tid)] = f"driver {item['kind']}" + (f" {lane + 1}" if lane else "")
        events.append({"ph": "X", "pid": DRIVER_PID, "tid": tid, "ts": start, "dur": max(1.0, end - start),
                       "cat": "driver", "name": item["name"], "args": item.get("args") or {}})
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
    summary["sources"] = {
        "trace": trace_path, "trace_bytes": os.path.getsize(trace_path), "events": len(events),
        "samples": len(samples), "sampled_processes": len(names), "xctrace_clock": offset_how,
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

    import bisect

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
    window_s = max(1e-9, ((meta.get("window_end_us") or start) - start) / 1e6)
    return {
        "host": meta.get("host"), "macos": meta.get("macos"), "tag": meta.get("tag"), "scenario": meta.get("scenario"),
        "window_s": round(window_s, 1), "load_at_start": meta.get("load_at_start"), "stress": meta.get("stress"), "storm_ops": meta.get("storm_ops"),
        "keys": meta.get("keys"), "chords": meta.get("chords"), "key_to_frame_ms": meta.get("key_to_frame_ms"),
        "frames": meta.get("frames"), "cef": meta.get("cef"),
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
    lines = [f"TRACE {s.get('scenario')} on {s.get('host')} (macOS {s.get('macos')}), tag {s.get('tag')}, window {s.get('window_s')} s, "
             f"load average at start {s.get('load_at_start')}"]
    if s.get("timed_out"):
        lines.append(f"  INCOMPLETE: stage(s) {', '.join(s['timed_out'])} passed their bound; the trace holds what was recorded")
    if s.get("stages"):
        lines.append("  stages (s): " + ", ".join(f"{x['stage']} {x['seconds']}" + (" TIMED OUT" if x["timed_out"] else "")
                                             for x in s["stages"]))
    src = s.get("sources") or {}
    lines.append(f"  file {src.get('trace')} ({(src.get('trace_bytes') or 0) / 1e6:.1f} MB, {src.get('events')} events); "
                 f"open it in https://ui.perfetto.dev")
    lines.append(f"  sources: {src.get('samples')} stack samples over {src.get('sampled_processes')} processes "
                 f"(clock: {src.get('xctrace_clock')}); {src.get('signpost_intervals')} signpost intervals "
                 f"(lost {src.get('signposts_lost')}); {src.get('hang_records')} watchdog records; "
                 f"{src.get('daemon_span_lines')} daemon span lines; {((src.get('chromium') or {}).get('events'))} Chromium events; "
                 f"{src.get('system_trace_states')} System Trace syscall waits")
    if s.get("stress"):
        st = s["stress"]
        lines.append(f"  STRESS: {st.get('workspaces')} workspaces, {st.get('measured_panes')} panes, tabs {st.get('measured_tabs')}, "
                     f"{st.get('busy_terminals')} busy terminals" + (f"; NOT the STRESS shape: {st['shape_error']}" if st.get("shape_error") else ""))
    if s.get("storm_ops") is not None:
        lines.append(f"  storm ops {s.get('storm_ops')}, keys {s.get('keys')}, chords {s.get('chords')}, "
                     f"key to frame {s.get('key_to_frame_ms')}")
    frames = s.get("frames") if isinstance(s.get("frames"), dict) else {}
    if frames:
        keys = ("refresh_ms", "frames", "p50_ms", "p95_ms", "max_ms", "missed", "main_p95_ms", "main_max_ms")
        lines.append("  display frames: " + ", ".join(f"{k} {round(frames[k], 2) if isinstance(frames.get(k), float) else frames.get(k)}"
                                                    for k in keys if k in frames))
    if s.get("cef"):
        lines.append(f"  chromium valid: {not s['cef'].get('unavailable_or_fallback')}")
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


# ---------------------------------------------------------------- self-test

def self_test():
    with tempfile.TemporaryDirectory() as out:
        # A Time Profiler export shape: refs, thread fmt, leaf-first frames.
        xml = """<?xml version="1.0"?><trace-query-result><node xpath="x"><schema name="time-profile"/>
<row><sample-time id="1" fmt="00:00.001">1000000</sample-time><thread id="2" fmt="Main Thread  0x1a (cmux DEV, pid: 42)"><tid id="3" fmt="0x1a">26</tid><process id="4" fmt="cmux DEV (42)"><pid id="5" fmt="42">42</pid></process></thread><weight id="6" fmt="1.00 ms">1000000</weight><backtrace id="7"><frame id="8" name="leafA"/><frame id="9" name="mid"/><frame id="10" name="main"/></backtrace></row>
<row><sample-time id="11" fmt="00:00.002">2000000</sample-time><thread ref="2"/><weight ref="6"/><backtrace id="12"><frame id="13" name="leafB"/><frame ref="9"/><frame ref="10"/></backtrace></row>
<row><sample-time id="14" fmt="00:00.010">10000000</sample-time><thread ref="2"/><weight ref="6"/><backtrace ref="12"/></row>
</node></trace-query-result>"""
        path = os.path.join(out, "tp.xml")
        open(path, "w").write(xml)
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
        # Lanes nest or split.
        lanes = Lanes()
        assert [lanes.place(0, 10), lanes.place(1, 5), lanes.place(4, 12), lanes.place(11, 13)] == [0, 0, 1, 0]
        # Roles.
        bundle = "/x/cmux DEV t.app"
        assert role_of(bundle + "/Contents/MacOS/cmux DEV", bundle) == "app"
        assert role_of(bundle + "/Contents/Resources/bin/cmux-tui server run --session s", bundle) == "daemon"
        assert role_of(bundle + "/Contents/Resources/bin/cmux-tui-host __holder --x", bundle) == "holder"
        assert role_of(bundle + "/Contents/Frameworks/cmux DEV Helper (Renderer).app/Contents/MacOS/x --type=renderer", bundle) == "cef-renderer"
        assert role_of(bundle + "/Contents/Resources/bin/cmux workspace x", bundle) == "cli"
        assert role_of("/usr/bin/true", bundle) is None
        # Wait classes.
        assert wait_class(["__psynch_mutexwait", "DaemonClient.send"]) == "lock"
        assert wait_class(["read", "DaemonClient.request"]) == "daemon"
        assert wait_class(["mach_msg2_trap", "CA::Transaction::commit()"]) == "windowserver"
        # A whole build from raw files: signposts, hangs, spans, Chromium, driver.
        open(os.path.join(out, "signposts.ndjson"), "w").write(signposts_lib.SAMPLE.replace('"processID":1', '"processID":42'))
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
            xml.replace(">1000000</sample-time>", ">1001000000</sample-time>").replace(">2000000</sample-time>", ">1002000000</sample-time>"))
        summary = build(out)
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
        assert summary["sources"]["chromium"]["clock"]["offset_us"] == 0.0, summary["sources"]["chromium"]
        # Chromium's main-thread task is named in the stall (CrBrowserMain is the app's Main Thread), on its own track.
        assert summary["top_stalls"][0]["chromium_main_thread"][0]["event"].startswith("ThreadControllerImpl::RunTask (OnFrame)"), summary
        task = next(e for e in trace["traceEvents"] if e.get("name") == "ThreadControllerImpl::RunTask")
        assert task["tid"] == 259, task
        assert {"frame": "mid", "samples": 2} in summary["top_stalls"][0]["sampled_frames"], summary["top_stalls"]
        print(summary_text(summary))
    # Stages: a stage past its bound ends at its bound (the blocking call raises), runs its cleanup and is recorded;
    # a non-fatal one lets the recording go on, a fatal one re-raises.
    meta, lines, cleaned = {}, [], []
    stages = Stages(meta, heartbeat_s=0.1, log=lines.append)
    started = time.monotonic()
    with stages.run("window", bound=0.3, on_timeout=lambda: cleaned.append("window")):
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
    print("self-test ok")
    return 0


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

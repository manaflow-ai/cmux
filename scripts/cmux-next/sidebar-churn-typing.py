#!/usr/bin/env python3
"""Terminal typing while the sidebar rearranges (Lawrence 2026-10-23: "there is a lot of lag in terminal,
when stuff in sidebar rearranges, we need to completely get rid of this lag case from first principles").

Launches the tagged app itself on a GUI host (no activation, a scratch cmux.json, an isolated Chief home,
the typing probe on, the hang watchdog at 8 ms), grows the sidebar to --workspaces workspaces over
--groups groups, and opens one more workspace whose terminal runs `cat` (the tty echoes each key). Then,
with that terminal focused, it types --samples keys in each phase:

  idle    nothing else happens
  churn   a second thread rearranges the sidebar at --churn-hz through the app's own CLI, as agents do:
          a workspace moves to the top, a task status changes, a workspace changes group, a status pill
          changes (round robin over random workspaces other than the typed one)

--input real (the number to quote): each key is a real key-down and key-up posted at the HID event tap
(CGEventPost), so it takes a person's path: the window server, the app's event queue, AppKit dispatch, and
the scheduler's pending-input check (SessionInputPending) that makes budgeted batches yield to it. The app
runs frontmost for that (no CMUX_NEXT_NO_ACTIVATE), so the job must own the GUI session and have the input
(Accessibility) grant: `nx-remote --needs input` or a whole mini. The probe's `contents_ms` is the event's
HID time to the frame that shows the echo.
--input debug (default, for hosts without an input grant): each key is `debug.key` with the client's send
time as the event's timestamp (CLOCK_UPTIME_RAW). It goes through the control socket's injected-input lane,
not the event queue, so it does not measure what a person's key waits for: never quote it as key latency. Per phase it reports key-to-frame p50/p95/max, the main-thread
hangs over 8 ms (`debug.hangs`: count, max, frames over 8.3 ms), the frame intervals (`debug.frames`), the
sidebar's own counters (`debug.sidebar_perf`) and, with --trace, a Time Profiler of the churn phase (main
thread top frames).

  sidebar-churn-typing.py --app APP --tag TAG --out DIR [--json DIR/report.json] [--workspaces 150]
      [--samples 120] [--churn-hz 10] [--trace] [--gate-p95-ms 8] [--session light|stress]

--session stress builds the STRESS session (perf-stress-session.py: 60 workspaces, the measured one 4 x 3 panes with
nested splits, 6 tabs each, Chromium pages, 10 busy terminals) instead of the --workspaces empty ones; the typed
terminal is the measured workspace's last pane, and the churn rearranges STRESS's 59 other workspaces. STRESS needs
a 1920 x 1080 main display (split-spring.sh --vdisplay=120). The report quotes the built shape (`stress_session`).

--gate-p95-ms: exit 1 when the churn phase's key-to-frame p95 is over that many ms, or over the idle
phase's p95 by more than --gate-delta-ms (default 2). --task-diagnostics: launch with
CMUX_NEXT_MAIN_TASK_DIAGNOSTICS=1, so debug.hangs also lists scheduled tasks past their class budget with a
stack; it wakes the watchdog per task and suspends the main thread per over-budget task, so it perturbs the
numbers: the report marks the run `perturbed`, and no latency number is quoted from such a run. --gate-stall-ms: exit 1 when a churn phase has a main-thread
stall (debug.hangs, threshold 8 ms) longer than that (plans/cmux-next/main-thread-budget.md: < 8 ms). Each phase also
records the main-thread scheduler's budget counters (debug.main_budget) and, with --task-diagnostics, the tasks that
ran past their class budget with their stacks (debug.hangs over_budget). Fleet (an owned mini with a console; the step builds the app):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \
    --artifact artifacts/split-spring/report.json --arg=--suite=sidebar-churn [--arg=--trace] [--arg=--gate-p95-ms=8]
"""
import argparse, csv, glob, json, os, random, shutil, socket, statistics, subprocess, sys, tempfile, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp, LaunchError  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--workspaces", type=int, default=150)
parser.add_argument("--groups", type=int, default=8)
parser.add_argument("--samples", type=int, default=120)
parser.add_argument("--interval", type=float, default=0.12, help="seconds between keys (wider than one echo)")
parser.add_argument("--churn-hz", type=float, default=10.0)
parser.add_argument("--rounds", type=int, default=1, help="idle/churn pairs, interleaved")
parser.add_argument("--trace", action="store_true", help="Time Profiler over the first churn phase")
parser.add_argument("--gate-p95-ms", type=float)
parser.add_argument("--gate-delta-ms", type=float, default=2.0)
parser.add_argument("--gate-stall-ms", type=float, help="also exit 1 when a churn phase's longest main-thread stall is over this many ms")
parser.add_argument("--keep", action="store_true", help="leave the app running")
parser.add_argument("--input", choices=["debug", "real"], default="debug",
                    help="real: HID-tap key events through the event queue (needs the input grant); debug: debug.key over the socket")
parser.add_argument("--session", choices=["light", "stress"], default="light",
                    help="light: --workspaces empty workspaces and a typing workspace; stress: the STRESS session "
                         "(perf-stress-session.py), the typed terminal in its measured workspace, the churn over its "
                         "59 other workspaces")
parser.add_argument("--task-diagnostics", action="store_true",
                    help="record over-budget scheduled tasks with stacks (perturbs the numbers; the report says so)")
opts = parser.parse_args()
OUT = os.path.abspath(opts.out)
os.makedirs(os.path.join(OUT, "traces"), exist_ok=True)
HERE = os.path.dirname(os.path.abspath(__file__))
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"churn-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
PROBE = os.path.join(OUT, "typing.csv")
APP_CLI = os.path.join(opts.app, "Contents/Resources/bin/cmux")
WINDOW = (40, 40, 1200, 900)
STATUSES = ["todo", "working", "needs-attention", "review", "done"]
# The most one `xctrace export` may take (a 25 s Time Profiler trace exports in well under a minute).
TRACE_EXPORT_TIMEOUT_S = 300
results = {"tag": opts.tag, "host": os.uname().nodename, "opts": vars(opts), "log": [], "phases": [],
           "input": opts.input, "session": opts.session, "perturbed": bool(opts.task_diagnostics)}


def note(text):
    print(text, flush=True)
    results["log"].append(text)


def rpc(method, params=None, timeout=60):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def cli(*args, timeout=120):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    env["CMUX_NEXT_CONFIG_FILE"] = CONFIG
    try:
        done = subprocess.run([APP_CLI, "--app-socket", SOCKET, *args], env=env, capture_output=True, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        note(f"cli {' '.join(args)[:120]} -> timed out after {timeout} s")
        return subprocess.CompletedProcess(args, 124, "", "timeout")
    if done.returncode != 0:
        note(f"cli {' '.join(args)[:120]} -> {done.returncode} {(done.stdout + done.stderr).strip()[-200:]}")
    return done


def wait(predicate, seconds, step=0.25):
    end = time.time() + seconds
    while time.time() < end:  # bounded wait for the live app
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def workspaces():
    snap = rpc("snapshot.get") or {}
    topo = snap.get("topology") or snap
    return topo.get("workspaces") or []


def pct(values):
    if not values:
        return None
    s = sorted(values)
    pick = lambda p: s[min(len(s) - 1, int(round((len(s) - 1) * p)))]
    return {"n": len(s), "p50": round(pick(0.5), 2), "p95": round(pick(0.95), 2), "p99": round(pick(0.99), 2),
            "max": round(s[-1], 2), "mean": round(statistics.fmean(s), 2)}


def probe_rows():
    try:
        with open(PROBE) as handle:
            return list(csv.DictReader(handle))
    except OSError:
        return []


def load_stress():
    """scripts/cmux-next/perf-stress-session.py, the shared STRESS builder."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------- churn
class Churn(threading.Thread):
    """Rearranges the sidebar at `hz` until stopped: move to top, task status, group change, status pill."""

    def __init__(self, ids, groups, hz):
        super().__init__(daemon=True)
        self.ids, self.groups, self.period = ids, groups, 1.0 / hz
        self.stop_flag = threading.Event()
        self.ops = {"move": 0, "task": 0, "group": 0, "pill": 0}
        self.cli_ms = []

    def run(self):
        kinds = list(self.ops)
        index = 0
        rng = random.Random(7)
        while not self.stop_flag.is_set():
            t0 = time.perf_counter()
            kind = kinds[index % len(kinds)]
            index += 1
            ws = rng.choice(self.ids)
            if kind == "move":
                cli("workspace", ws, "move", "--index", "0", timeout=20)
            elif kind == "task":
                cli("workspace", ws, "update", "--task-status", rng.choice(STATUSES), timeout=20)
            elif kind == "group":
                cli("workspace", "group", rng.choice(self.groups), "add", "--workspace", ws, "--index", "0", timeout=20)
            else:
                cli("workspace", ws, "status", "set", "bench", f"step {index}", timeout=20)
            self.ops[kind] += 1
            spent = time.perf_counter() - t0
            self.cli_ms.append(spent * 1000)
            rest = self.period - spent
            if rest > 0:
                self.stop_flag.wait(rest)  # the churn's pace

    def stop(self):
        self.stop_flag.set()
        self.join(timeout=30)


# ---------------------------------------------------------------- profiling
def trace_start(pid, name, seconds):
    path = os.path.join(OUT, "traces", f"{name}.trace")
    if os.path.exists(path):
        shutil.rmtree(path)
    proc = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Time Profiler", "--attach", str(pid),
                             "--time-limit", f"{seconds}s", "--output", path, "--no-prompt"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(4)  # the recorder attaches
    return proc, path


def main_thread_profile(path):
    import xml.etree.ElementTree as ET
    if not os.path.exists(path):
        return None
    # Each export is bounded: an `xctrace export` that never returns held a fleet host silent until the step's
    # watchdog killed it (2026-10-24, cmux20-bench), losing the phases already measured. A timed-out export
    # gives the report an error entry, and the key and hang numbers still land.
    try:
        toc = subprocess.run(["xcrun", "xctrace", "export", "--input", path, "--toc"], capture_output=True, text=True,
                             timeout=TRACE_EXPORT_TIMEOUT_S).stdout
        schema = "time-profile" if 'schema="time-profile"' in toc else "time-sample"
        xml = subprocess.run(["xcrun", "xctrace", "export", "--input", path, "--xpath",
                              f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'], capture_output=True, text=True,
                             timeout=TRACE_EXPORT_TIMEOUT_S).stdout
    except subprocess.TimeoutExpired:
        note(f"trace export timed out after {TRACE_EXPORT_TIMEOUT_S} s: {path}")
        return {"error": f"export timed out after {TRACE_EXPORT_TIMEOUT_S} s"}
    try:
        root = ET.fromstring(xml)
    except ET.ParseError as error:
        return {"error": f"export: {error}"}
    ids = {}

    def resolve(element):
        ref = element.get("ref")
        if ref is not None:
            return ids.get(ref, element)
        if element.get("id") is not None:
            ids[element.get("id")] = element
        for child in element:
            resolve(child)
        return element

    inclusive, leaf, samples = {}, {}, 0
    # For a few frames: who called them and what they called, so a hot generic frame names its owner.
    focus = ("generateAccessList", "Array._makeMutableAndUnique", "withObservationTracking<", "SidebarSameTurn.observe",
             "DaemonStore.applyBatch", "stepTransactionFlush", "SidebarListView.reload", "ObservationStream.LegacyIterator.track",
             "FrameBatcher.drain", "publishNow", "reconcileMembership", "SidebarRowIndex.patching")
    callers, callees = {}, {}
    for row in root.iter("row"):
        thread = backtrace = None
        for child in row:
            node = resolve(child)
            if child.tag == "thread":
                thread = node
            elif child.tag in ("backtrace", "tagged-backtrace"):
                backtrace = node
        if thread is None or backtrace is None or "Main Thread" not in (thread.get("fmt") or ""):
            continue
        samples += 1
        bt = backtrace if backtrace.tag == "backtrace" else next(iter(backtrace.iter("backtrace")), backtrace)
        frames = [resolve(f).get("name") or "?" for f in bt.iter("frame")]
        if frames:
            leaf[frames[0]] = leaf.get(frames[0], 0) + 1
        for name in set(frames):
            inclusive[name] = inclusive.get(name, 0) + 1
        seen = set()
        for i, name in enumerate(frames):  # leaf first
            key = next((f for f in focus if f in name), None)
            if key is None or key in seen:
                continue
            seen.add(key)  # the outermost-but-first occurrence per sample: one count each
            up = frames[i + 1] if i + 1 < len(frames) else "-"
            down = frames[i - 1] if i > 0 else "(self)"
            callers.setdefault(key, {})[up[:160]] = callers.setdefault(key, {}).get(up[:160], 0) + 1
            callees.setdefault(key, {})[down[:160]] = callees.setdefault(key, {}).get(down[:160], 0) + 1
    generic = ("main", "start", "NSApplicationMain", "-[NSApplication run]", "_DPSNextEvent", "CFRunLoopRun", "__CFRunLoop",
               "_CFRunLoopRun", "-[NSApplication(NSEvent) _nextEventMatchingEventMask", "_BlockUntilNextEventMatchingListInMode",
               "ReceiveNextEventCommon", "RunCurrentEventLoopInMode", "_dispatch_main_queue", "__CFRUNLOOP", "_dispatch_", "?",
               "_DPSBlockUntilNextEventMatchingListInMode", "-[NSApplication(NSEventRouting)", "CmuxNextApp.main()")
    top = [{"frame": n[:220], "samples": c, "pct": round(100.0 * c / samples, 1) if samples else 0}
           for n, c in sorted(inclusive.items(), key=lambda kv: -kv[1]) if not n.startswith(generic)][:80]
    top_of = lambda table: {k: sorted(v.items(), key=lambda kv: -kv[1])[:8] for k, v in table.items()}
    return {"main_samples": samples, "top_inclusive": top, "callers": top_of(callers), "callees": top_of(callees),
            "top_leaf": [{"frame": n[:220], "samples": c} for n, c in sorted(leaf.items(), key=lambda kv: -kv[1])[:30]]}


# ---------------------------------------------------------------- phases
SAMPLED = []


def sample_main(pid, label):
    """`sample` of the app for 2 s when a key stalls: the main thread's stack names what holds it."""
    path = os.path.join(OUT, f"stall-{label}-{len(SAMPLED)}.txt")
    subprocess.run(["sample", str(pid), "2", "-file", path], capture_output=True, timeout=60)
    SAMPLED.append(path)
    try:
        # The report is the step's one artifact: keep the main thread's part of the sample in it.
        text = open(path, errors="replace").read()
        start = text.find("Thread_")
        results.setdefault("stall_samples", []).append({"label": label, "text": text[start:start + 40000] if start >= 0 else text[:40000]})
    except OSError:
        pass
    note(f"stall sample: {os.path.basename(path)}")


# ANSI virtual key codes (Carbon kVK_ANSI_*) for the typed keys.
KEYCODES = {"a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
            "m": 46, "return": 36}
_CG = None


def post_real_key(key):
    """One real key press at the HID event tap: the window server queues it for the frontmost app, which
    dispatches it from its event queue like a person's key (SessionInputPending sees it until then)."""
    global _CG
    import ctypes, ctypes.util
    if _CG is None:
        _CG = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))
        _CG.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
        _CG.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
        _CG.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        _CG.CFRelease.argtypes = [ctypes.c_void_p]
    for down in (True, False):
        event = _CG.CGEventCreateKeyboardEvent(None, KEYCODES[key], down)
        _CG.CGEventPost(0, event)  # kCGHIDEventTap
        _CG.CFRelease(event)


def bring_front(pid):
    """Makes the app frontmost (real keys go to the frontmost app's key window)."""
    subprocess.run(["osascript", "-e",
                    f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true'],
                   capture_output=True, timeout=30)


def type_keys(count, pid=None, label="warmup"):
    """Types `count` keys; returns the per-key round trips (ms). A key whose RPC takes over 2 s is a stall:
    the first three get a `sample` of the app, and the phase ends after 10 of them or 4x its planned time."""
    keys = "abcdefghijklmnopqrstuvwxyz"
    trips, stalls = [], 0
    deadline = time.monotonic() + max(30.0, 4 * count * opts.interval)
    for index in range(count):
        t0 = time.perf_counter()
        key = "return" if index % 50 == 49 else keys[index % len(keys)]
        if opts.input == "real":
            post_real_key(key)
            reply = None
        else:
            reply = rpc("debug.key", {"key": key, "timestamp": time.clock_gettime(time.CLOCK_UPTIME_RAW)}, timeout=10)
        trip = (time.perf_counter() - t0) * 1000
        trips.append(trip)
        if trip > 2000 or (isinstance(reply, dict) and reply.get("error")):
            stalls += 1
            note(f"{label}: key {index} took {trip:.0f} ms ({json.dumps(reply)[:120]})")
            if pid and stalls <= 3:
                sample_main(pid, label)
        if index % 30 == 29:
            note(f"{label}: {index + 1}/{count} keys")
        if stalls >= 10 or time.monotonic() > deadline:
            note(f"{label}: stopped after {index + 1} keys ({stalls} stalls)")
            break
        rest = opts.interval - (time.perf_counter() - t0)
        if rest > 0:
            time.sleep(rest)  # one key in flight at a time
    time.sleep(0.5)  # the last echo lands
    return trips, stalls


def phase(name, pid, ids, groups, churn_hz, trace=False):
    rows_before = len(probe_rows())
    rpc("debug.hangs", {"clear": True})
    rpc("debug.main_budget", {"reset": True})
    rpc("debug.sidebar_perf", {"reset": True})
    rpc("debug.frames", {"action": "start"})
    churn = None
    tracer = None
    if trace:
        seconds = int(opts.samples * opts.interval + 8)
        tracer = trace_start(pid, f"{name}", seconds)
    if churn_hz > 0:
        churn = Churn(ids, groups, churn_hz)
        churn.start()
        time.sleep(1.0)  # the churn is running before the first key
    t0 = time.monotonic()
    trips, stalls = type_keys(opts.samples, pid, name)
    wall = time.monotonic() - t0
    if churn:
        churn.stop()
    frames = rpc("debug.frames", {"action": "stop"}, timeout=20)
    hangs = rpc("debug.hangs", {"limit": 12}, timeout=20)
    perf = rpc("debug.sidebar_perf", timeout=20)
    budget = rpc("debug.main_budget", timeout=20)
    rows = probe_rows()[rows_before:]
    complete = [r for r in rows if r.get("complete") == "1" and r.get("contents_ms")]
    entry = {
        "phase": name, "churn_hz": churn_hz, "wall_s": round(wall, 1),
        "keys": len(trips), "stalled_keys": stalls, "key_rpc_ms": pct(trips), "probe_rows": len(rows), "complete": len(complete),
        "key_to_frame_ms": pct([float(r["contents_ms"]) for r in complete]),
        "key_to_dispatch_ms": pct([float(r["dispatch_start_ms"]) for r in complete if r.get("dispatch_start_ms")]),
        "parsed_to_frame_ms": pct([float(r["contents_ms"]) - float(r["output_parsed_ms"]) for r in complete if r.get("output_parsed_ms")]),
        "hangs": {k: hangs.get(k) for k in ("count", "busy_count", "max_ms", "total_ms", "long_frames", "frames_over_8_3ms", "max_gap_ms")}
        if isinstance(hangs, dict) else hangs,
        "hang_records": (hangs or {}).get("records") if isinstance(hangs, dict) else None,
        "over_budget_count": (hangs or {}).get("over_budget_count") if isinstance(hangs, dict) else None,
        "over_budget": (hangs or {}).get("over_budget") if isinstance(hangs, dict) else None,
        "main_budget": budget,
        "frames": frames, "sidebar_perf": perf,
    }
    if churn:
        entry["churn_ops"] = churn.ops
        entry["churn_ops_per_s"] = round(sum(churn.ops.values()) / max(wall, 0.001), 1)
        entry["churn_cli_ms"] = pct(churn.cli_ms)
    if tracer:
        proc, path = tracer
        try:
            proc.communicate(timeout=opts.samples * opts.interval + 200)
        except subprocess.TimeoutExpired:
            proc.terminate()
        entry["profile"] = main_thread_profile(path)
        entry["trace"] = os.path.relpath(path, OUT)
    k = entry["key_to_frame_ms"] or {}
    h = entry["hangs"] if isinstance(entry["hangs"], dict) else {}
    note(f"{name}: key-to-frame p50 {k.get('p50')} p95 {k.get('p95')} max {k.get('max')} ms (n={k.get('n')}); "
         f"hangs {h.get('count')} max {h.get('max_ms')} ms; churn {entry.get('churn_ops_per_s')} ops/s")
    results["phases"].append(entry)
    return entry


def main():
    global SOCKET, CONFIG
    # One launch path for GUI benches (bench_launch.py): the console-session check, the tag's socket in the state
    # folder, and the reason when the app does not come up. The bench's own environment on top of its defaults.
    env = {"CMUX_NEXT_TYPING_PROBE": PROBE, "CMUX_NEXT_HANG_THRESHOLD_MS": "8"}
    if opts.input != "debug":
        env["CMUX_NEXT_NO_ACTIVATE"] = None  # a real key needs the app frontmost; injected keys need no focus
    if opts.task_diagnostics:
        env["CMUX_NEXT_MAIN_TASK_DIAGNOSTICS"] = "1"
    bench = BenchApp(opts.app, out=OUT, config={"appearance": {"theme": "Catppuccin Mocha"}}, window=WINDOW, log_name="app.log",
                     env=env)
    results["load_at_start"] = os.getloadavg()
    made = []
    groups = []
    try:
        try:
            bench.launch(timeout=180)
        except LaunchError as error:
            results["launch_failure"] = {"reason": error.reason, "detail": error.report.get("detail")}
            raise
        app, SOCKET, CONFIG = bench.process, bench.socket, os.path.join(bench.scratch, "cmux.json")
        t0 = time.monotonic()
        builder = None
        if opts.session == "stress":
            builder = load_stress().Stress(rpc, log=note)
            results["stress_session"] = builder.build()
            print("STRESS-SESSION " + json.dumps(results["stress_session"]), flush=True)
        for g in range(opts.groups):
            name = f"churn group {g:02d}"
            cli("workspace", "group", "create", "--name", name)
            groups.append(name)
        if builder:
            ids = list(builder.background)  # STRESS's 59 other workspaces are the ones that rearrange
        else:
            for i in range(opts.workspaces):
                ref = cli("workspace", "create", "--empty", "--name", f"churn {i:04d}").stdout.strip()
                if ref:
                    made.append(ref)
            by_name = {w.get("name") or w.get("title"): w.get("id") for w in workspaces()}
            ids = [by_name[n] for n in (f"churn {i:04d}" for i in range(opts.workspaces)) if by_name.get(n)]
        for index, ws in enumerate(ids):
            if index % 4 != 3:
                cli("workspace", "group", groups[index % len(groups)], "add", "--workspace", ws)
        note(f"{opts.session}: {len(ids)} churned workspaces in {len(groups)} groups in {time.monotonic() - t0:.1f} s")
        if builder:
            # The typed terminal: the selected terminal of the measured workspace's last pane (the busy output runs
            # in its first 10 panes), turned into `cat` so the tty echoes each key; the grid stays on screen.
            typed_id = builder.measured
            pane = builder.panes(builder.workspace(typed_id))[-1]
            terminal = next((t for t in pane.get("tabs") or [] if t.get("kind") == "terminal" and t.get("selected")), None)
            if terminal is None:
                sys.exit(f"STRESS: the measured workspace's last pane {pane.get('id')} shows no terminal")
            builder.send(terminal["id"], "exec cat\r")
            builder.show(typed_id)
            builder.focus_pane(pane["id"])
        else:
            typed = cli("workspace", "create", "--name", "typing", "--focus", "--shell", "exec cat").stdout.strip()
            by_name = {w.get("name") or w.get("title"): w.get("id") for w in workspaces()}
            typed_id = by_name.get("typing") or typed
            cli("workspace", typed_id, "focus")
        rpc("debug.mouse", {"x": 900, "y": 450, "action": "hover"})  # the pointer rests over the terminal, not the list
        if opts.input == "real":
            bring_front(app.pid)
        time.sleep(4)
        results["setup"] = {"workspaces": len(ids), "groups": len(groups), "typing": typed_id}
        rows_before_warmup = len(probe_rows())
        type_keys(10)  # warm-up
        if opts.input == "real" and len(probe_rows()) <= rows_before_warmup:
            sys.exit("--input real: no key reached the app (not frontmost, or this session has no input grant)")
        for r in range(opts.rounds):
            phase(f"idle-{r}", app.pid, ids, groups, 0, trace=opts.trace and r == 0)
            phase(f"churn-{r}", app.pid, ids, groups, opts.churn_hz, trace=opts.trace and r == 0)
    finally:
        idle = [p for p in results["phases"] if p["churn_hz"] == 0 and p.get("key_to_frame_ms")]
        churn = [p for p in results["phases"] if p["churn_hz"] > 0 and p.get("key_to_frame_ms")]
        summary = {}
        if idle and churn:
            summary = {"idle_p95_ms": max(p["key_to_frame_ms"]["p95"] for p in idle),
                       "churn_p95_ms": max(p["key_to_frame_ms"]["p95"] for p in churn),
                       "idle_p50_ms": statistics.median(p["key_to_frame_ms"]["p50"] for p in idle),
                       "churn_p50_ms": statistics.median(p["key_to_frame_ms"]["p50"] for p in churn),
                       "churn_max_ms": max(p["key_to_frame_ms"]["max"] for p in churn),
                       "churn_hangs": sum((p["hangs"] or {}).get("count") or 0 for p in churn if isinstance(p["hangs"], dict)),
                       "churn_hang_max_ms": max(((p["hangs"] or {}).get("max_ms") or 0) for p in churn if isinstance(p["hangs"], dict))}
        results["summary"] = summary
        note(f"summary: {json.dumps(summary)}")
        report = opts.json or os.path.join(OUT, "report.json")
        with open(report, "w") as f:
            json.dump(results, f, indent=1, default=str)
        if not opts.keep:
            bench.stop()
    if opts.gate_stall_ms is not None and summary and summary["churn_hang_max_ms"] > opts.gate_stall_ms:
        sys.exit(f"gate: churn main-thread stall {summary['churn_hang_max_ms']} ms is over {opts.gate_stall_ms} ms")
    if opts.gate_p95_ms is not None and summary:
        over = summary["churn_p95_ms"] > opts.gate_p95_ms or summary["churn_p95_ms"] - summary["idle_p95_ms"] > opts.gate_delta_ms
        if over:
            sys.exit(f"gate: churn p95 {summary['churn_p95_ms']} ms (idle {summary['idle_p95_ms']} ms) is over "
                     f"{opts.gate_p95_ms} ms or idle + {opts.gate_delta_ms} ms")


main()

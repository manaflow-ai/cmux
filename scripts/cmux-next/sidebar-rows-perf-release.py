#!/usr/bin/env python3
"""Sidebar scroll hitches with ticking rows, for a Release (or Debug) tagged app, with a real pointer.

  nx-remote --needs input --input-reason "real wheel scroll in the sidebar" --input-minutes 20 \
      --app-from-fleet cmux --tag <tag> --ref <sha> -- \
      'python3 -I scripts/cmux-next/sidebar-rows-perf-release.py --label <label>'

A Release build serves no `debug.*` socket method, so this script uses only the CLI (workspace
create/list, terminal list/write), cua-driver (window, wheel input, accessibility reads) and
xctrace. It launches `$NX_APP` itself (the window at 40,40 1100x820 on the last screen), makes
`--count` workspaces (`--ticking` with a terminal, the others empty), and then, for each mode
(ticks off, ticks on), records `--repeats` Animation Hitches traces of one gesture each: a
sweep of real wheel events down the sidebar and back up (cua-driver `scroll`, `--steps` calls
of `--notches` line notches each way). In the ticks-on mode every ticking terminal reports OSC
7501 every `--tick-ms`, alternating working and idle. Also measured: the app's CPU per tick in a
tick window without input, and that the wheel moves the list (the accessibility row titles
before and after an untraced sweep). Writes release-<label>.json to --out (default
$NX_ARTIFACTS) and quits the app with $NX_APP_STOP.
"""
import argparse, json, os, re, shutil, statistics, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor

parser = argparse.ArgumentParser()
parser.add_argument("--label", default="run")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--count", type=int, default=1000)
parser.add_argument("--ticking", type=int, default=50)
parser.add_argument("--tick-ms", type=int, default=250)
parser.add_argument("--repeats", type=int, default=5)
parser.add_argument("--steps", type=int, default=20, help="wheel calls per direction in one gesture")
parser.add_argument("--notches", type=int, default=4, help="line notches per wheel call")
parser.add_argument("--profile-runs", type=int, default=2, help="per mode: export the Time Profiler of this many runs")
opts = parser.parse_args()

HERE = os.path.dirname(os.path.abspath(__file__))
APP, TAG, STOP = os.environ.get("NX_APP"), os.environ.get("NX_APP_TAG", ""), os.environ.get("NX_APP_STOP")
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.environ.get("NX_APP_CLI") or (APP and os.path.join(APP, "Contents/Resources/bin/cmux"))
CUA = os.path.expanduser("~/.local/bin/cua-driver")
if not APP or not STOP:
    sys.exit("run inside `nx-remote --needs input --app-from-fleet cmux` (NX_APP, NX_APP_STOP)")
if not os.access(CUA, os.X_OK):
    sys.exit("needs ~/.local/bin/cua-driver (nx-remote --needs input on a GUI host)")
# A fresh cua-driver session label per run, started with start_session (an ended label is refused).
CUA_SESSION = f"sbperf3-{os.getpid()}-{int(time.time())}"
SCRATCH = tempfile.mkdtemp(prefix=f"sbperf3-{TAG}-")
CONFIG, GHOSTTY = os.path.join(SCRATCH, "cmux.json"), os.path.join(SCRATCH, "ghostty")
open(GHOSTTY, "w").write("")
open(CONFIG, "w").write("{}")
os.makedirs(opts.out, exist_ok=True)
summary = {"label": opts.label, "tag": TAG, "count": opts.count, "ticking": opts.ticking, "tick_ms": opts.tick_ms,
           "steps": opts.steps, "notches": opts.notches}
failures = []
TICK_RUN_S = 25  # a ticks-mode run: attach (5 s) + gesture + stop, inside the tick programs' time


def note(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def cli(*args, timeout=60):
    env = dict(os.environ, CMUX_TAG=TAG)
    try:
        return subprocess.run([CLI, "--app-socket", SOCKET, *args], env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, 124, "", "timeout")


def cua(tool, args, timeout=60):
    out = subprocess.run([CUA, "call", tool, json.dumps({"session": CUA_SESSION, **args})], capture_output=True, text=True,
                         timeout=timeout)
    try:
        return json.loads(out.stdout)
    except ValueError:
        return {"error": (out.stdout + out.stderr)[-400:]}


def wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded harness wait for app startup / listing
        value = predicate()
        if value:
            return value
        time.sleep(0.5)
    return None


def app_pid():
    """The process that holds the tag's socket (an `open -n` command line need not name the bundle path),
    else the newest process running the bundle's binary."""
    for command in (["lsof", "-t", SOCKET], ["pgrep", "-n", "-f", os.path.join(os.path.realpath(APP), "Contents/MacOS")],
                    ["pgrep", "-n", "-f", os.path.join(APP, "Contents/MacOS")]):
        found = [int(p) for p in subprocess.run(command, capture_output=True, text=True).stdout.split() if int(p) != os.getpid()]
        if found:
            return found[0]
    return None


def cpu_ns(pid):
    sys.path.insert(0, HERE)
    from bench_idle import usage  # noqa: E402
    sample = usage(pid) if pid else None
    return sample[0] if sample else None


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(p / 100 * len(ordered)))], 2)


def perf_names():
    out = cli("--json", "workspace", "list", timeout=120)
    return set(re.findall(r'"(perf-(?:tick-)?\d+)"', out.stdout or ""))


def launch():
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = ["CMUX_NEXT_NO_ACTIVATE=1", "CMUX_NEXT_SOCKET_MODE=automation", "CMUX_NEXT_TEST_WINDOW_SCREEN=last",
           f"CMUX_NEXT_CONFIG_FILE={CONFIG}", f"CMUX_NEXT_GHOSTTY_CONFIG={GHOSTTY}", "CMUX_NEXT_TEST_WINDOW_FRAME=40,40,1100,820"]
    subprocess.run(["open", "-n", APP, *[arg for pair in env for arg in ("--env", pair)]], check=True)
    if not wait(lambda: os.path.exists(SOCKET) and cli("--json", "workspace", "list").returncode == 0, 120):
        sys.exit("FAIL the tagged app did not come up")


def make_workspaces():
    have = perf_names()
    # The ticking workspaces of an earlier run of this tag kept their state, but their terminals exited
    # with that app session: close them, so this run makes them again with live shells.
    old_ticking = sorted(n for n in have if n.startswith("perf-tick-"))
    if old_ticking:
        with ThreadPoolExecutor(max_workers=8) as pool:
            closed = list(pool.map(lambda n: cli("workspace", n, "close"), old_ticking))
        bad = [r.stderr.strip()[-160:] for r in closed if r.returncode != 0]
        note(not bad, f"closed {len(old_ticking)} ticking workspaces of an earlier run ({bad[:2]})")
        have = perf_names()
        summary["ticking_left_after_close"] = len([n for n in have if n.startswith("perf-tick-")])
    ticking = [f"perf-tick-{i:02d}" for i in range(opts.ticking) if f"perf-tick-{i:02d}" not in have]
    empty = [f"perf-{i:04d}" for i in range(opts.count - opts.ticking) if f"perf-{i:04d}" not in have]
    start = time.monotonic()
    with ThreadPoolExecutor(max_workers=8) as pool:
        # The ticking ones first, so they list near the top, where the window shows rows.
        results = list(pool.map(lambda n: cli("workspace", "create", "--name", n), ticking))
        results += list(pool.map(lambda n: cli("workspace", "create", "--empty", "--name", n), empty))
    bad = [r.stderr.strip()[-160:] for r in results if r.returncode != 0]
    note(not bad, f"created {len(results)} workspaces in {time.monotonic() - start:.0f} s ({bad[:3]})")
    listed = wait(lambda: (lambda n: n if len(n) >= opts.count else None)(perf_names()), 300) or perf_names()
    summary["listed"] = len(listed)
    note(len(listed) >= opts.count, f"the app lists {len(listed)} of {opts.count} perf workspaces")


def ticking_terminals():
    terms = []
    try:
        data = json.loads(cli("--json", "terminal", "list").stdout)
        for item in (data.get("terminals") if isinstance(data, dict) else data) or []:
            ident = next((v for v in item.values() if isinstance(v, str) and v.startswith("term_")), None)
            if ident and "perf-tick-" in json.dumps(item):
                terms.append(ident)
    except (ValueError, AttributeError):
        pass
    if not terms:  # other output shape: every terminal (the ticking ones and the first window's)
        listed = cli("terminal", "list")
        terms = [word for word in listed.stdout.split() if word.startswith("term_")]
        print(f"terminal list fallback: {len(terms)} terminals; {(listed.stdout or listed.stderr)[:300]!r}", flush=True)
    return terms


def start_ticks(terms, seconds):
    """Each ticking terminal reports OSC 7501 every --tick-ms for `seconds` (then idle; it ends by itself)."""
    ticks_each = int(seconds * 1000 / opts.tick_ms)
    loop = (f"i=0; while [ $i -lt {ticks_each} ]; do if [ $((i % 2)) = 0 ]; then s=working; else s=idle; fi; "
            f"printf '\\033]7501;state=%s\\033\\\\' $s; sleep {opts.tick_ms / 1000}; i=$((i + 1)); done; "
            f"printf '\\033]7501;state=idle\\033\\\\'\n")
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda t: cli("terminal", t, "write", "--text", loop), terms))
    return ticks_each * len(terms)


class Target:
    pid = window_id = None
    scale = 1.0
    point = screen_point = (0, 0)

    @classmethod
    def find(cls):
        pid = app_pid()
        if not pid:
            sys.exit(f"FAIL no process for the tagged app (socket {SOCKET})")
        started = cua("start_session", {})
        if isinstance(started, dict) and started.get("error"):
            sys.exit(f"FAIL cua-driver start_session: {json.dumps(started)[:300]}")
        listed = {}
        windows = wait(lambda: [w for w in (listed.update(cua("list_windows", {"pid": pid})) or listed.get("windows") or [])
                                if w.get("is_on_screen") and w.get("pid", pid) == pid], 30)
        if not windows:
            sys.exit(f"FAIL cua-driver lists no on-screen window for pid {pid}: {json.dumps(listed)[:400]}")
        main = max(windows, key=lambda w: w["bounds"]["width"] * w["bounds"]["height"])
        shot = os.path.join(SCRATCH, "window.png")
        cua("get_window_state", {"pid": pid, "window_id": main["window_id"], "screenshot_out_file": shot}, timeout=120)
        width = int.from_bytes(open(shot, "rb").read()[16:20], "big") if os.path.exists(shot) else 0
        cls.pid, cls.window_id = pid, main["window_id"]
        cls.scale = width / main["bounds"]["width"] if width else 1.0
        # The sidebar's row list: left column, below the window chrome.
        cls.point = (110 * cls.scale, 430 * cls.scale)
        cls.screen_point = (main["bounds"]["x"] + 110, main["bounds"]["y"] + 430)
        # Front once, so every wheel call can go in the background (no activation per call).
        cua("bring_to_front", {"pid": pid})
        print(f"cua target pid={pid} window={cls.window_id} bounds={main['bounds']} scale={cls.scale:.3f}", flush=True)


def row_titles():
    # With a screenshot: a pixel wheel call needs the screenshot context of the last window state.
    reply = cua("get_window_state", {"pid": Target.pid, "window_id": Target.window_id, "query": "perf-",
                                     "screenshot_out_file": os.path.join(SCRATCH, "rows.png")}, timeout=120)
    text = json.dumps(reply)
    return set(re.findall(r"perf-(?:tick-)?\d+", text))


def ground():
    """A fresh screenshot context for the pixel wheel calls (cua-driver refuses them without one)."""
    reply = cua("get_window_state", {"pid": Target.pid, "window_id": Target.window_id, "max_elements": 1,
                                     "screenshot_out_file": os.path.join(SCRATCH, "ground.png")}, timeout=120)
    if not isinstance(reply, dict) or reply.get("error") or reply.get("code"):
        sys.exit(f"FAIL cua-driver get_window_state: {json.dumps(reply)[:300]}")


WHEEL = {"by": "line"}  # the variant that moved the list (chosen by find_wheel)


class HIDWheel:
    """Real wheel events at the window server (CGEventPost to the HID tap, as a mouse wheel does), at the
    sidebar point in screen coordinates; the window is in front (bring_to_front once), so no activation
    per event. 60 events a second, `--notches` lines each."""
    cg = None

    @classmethod
    def load(cls):
        import ctypes, ctypes.util
        cg = ctypes.CDLL(ctypes.util.find_library("CoreGraphics") or "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        cg.CGEventCreateScrollWheelEvent2.restype = ctypes.c_void_p
        cg.CGEventCreateScrollWheelEvent2.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32,
                                                      ctypes.c_int32, ctypes.c_int32]
        cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p

        class Point(ctypes.Structure):
            _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]

        cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, Point, ctypes.c_uint32]
        cg.CGEventSetLocation.argtypes = [ctypes.c_void_p, Point]
        cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        cls.cg, cls.Point = cg, Point
        cls.CFRelease = ctypes.CDLL(ctypes.util.find_library("CoreFoundation")).CFRelease
        cls.CFRelease.argtypes = [ctypes.c_void_p]

    @classmethod
    def sweep(cls, direction, events):
        if cls.cg is None:
            cls.load()
        cg, at = cls.cg, cls.Point(*Target.screen_point)
        move = cg.CGEventCreateMouseEvent(None, 5, at, 0)  # kCGEventMouseMoved: the pointer over the sidebar
        cg.CGEventPost(0, move)
        cls.CFRelease(move)
        delta = opts.notches if direction == "up" else -opts.notches
        for _ in range(events):
            event = cg.CGEventCreateScrollWheelEvent2(None, 1, 1, delta, 0, 0)  # kCGScrollEventUnitLine
            cg.CGEventSetLocation(event, at)
            cg.CGEventPost(0, event)  # kCGHIDEventTap
            cls.CFRelease(event)
            time.sleep(1 / 60)  # harness: wheel event rate
        return []


def sweep(direction, steps=None):
    if WHEEL.get("hid"):
        return HIDWheel.sweep(direction, (steps or opts.steps) * 6)
    replies = []
    for _ in range(steps or opts.steps):
        r = cua("scroll", {"pid": Target.pid, "window_id": Target.window_id, "x": Target.point[0], "y": Target.point[1],
                           "direction": direction, "amount": opts.notches, **WHEEL})
        replies.append(r)
    summary.setdefault("wheel_reply_sample", json.dumps(replies[0])[:400] if replies else None)
    return [r for r in replies if not isinstance(r, dict) or r.get("error") or r.get("code")]


def find_wheel():
    """The first wheel variant whose sweep changes the visible rows (background first: no activation per call)."""
    tried = []
    for variant in ({"hid": True}, {"by": "line"}):
        WHEEL.clear()
        WHEEL.update(variant)
        before = row_titles()
        if not tried and os.path.exists(os.path.join(SCRATCH, "rows.png")):
            shutil.copy(os.path.join(SCRATCH, "rows.png"), os.path.join(opts.out, f"{opts.label}-window.png"))
        bad = sweep("down", 6)
        after = row_titles()
        sweep("up", 6)
        row_titles()
        moved = bool(after - before)
        tried.append({"variant": dict(variant), "before": len(before), "new_after": len(after - before), "moved": moved,
                      "errors": [json.dumps(b)[:200] for b in bad[:2]]})
        print(f"wheel variant {variant}: {tried[-1]}", flush=True)
        if moved:
            break
    summary["wheel_variants"] = tried
    return tried[-1]["moved"]


def export_table(trace, schema):
    import xml.etree.ElementTree as ET
    xml = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                          f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'], capture_output=True, text=True).stdout
    root = ET.fromstring(xml)
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

    for row in root.iter("row"):
        yield [(child.tag, resolve(child)) for child in row], ids


def hitches(trace, pid):
    durations, updates = [], []
    try:
        for schema, sink in (("hitches", durations), ("hitches-updates", updates)):
            for cells, _ in export_table(trace, schema):
                process = next((n for t, n in cells if t == "process"), None)
                duration = next((n for t, n in cells if t == "duration"), None)
                if process is None or f"({pid})" not in (process.get("fmt") or ""):
                    continue
                if duration is not None and (duration.text or "").isdigit():
                    sink.append(int(duration.text) / 1e6)
    except Exception as error:  # noqa: BLE001 (export failures are reported, the run goes on)
        return {"error": f"export: {error}"}
    return {"hitches": len(durations), "total_ms": round(sum(durations), 1), "max_ms": round(max(durations), 2) if durations else None,
            "app_updates": len(updates), "update_p50_ms": percentile(updates, 50), "update_p90_ms": percentile(updates, 90),
            "updates_over_8_3_ms": len([u for u in updates if u > 8.34])}


GENERIC = ("main", "start", "NSApplicationMain", "-[NSApplication run]", "_DPSNextEvent", "CFRunLoopRun", "__CFRunLoop",
           "_CFRunLoopRun", "-[NSApplication(NSEvent) _nextEventMatchingEventMask", "_BlockUntilNextEventMatchingListInMode",
           "ReceiveNextEventCommon", "RunCurrentEventLoopInMode", "_dispatch_main_queue", "__CFRUNLOOP", "_dispatch_", "?",
           "_DPSBlockUntilNextEventMatchingListInMode", "-[NSApplication(NSEventRouting)", "swift_job_run",
           "swift::runJobInEstablishedExecutorContext")


def main_thread_profile(trace):
    """Main-thread Time Profiler samples of the trace: top inclusive and leaf frames."""
    inclusive, leaf, total = {}, {}, 0
    try:
        for cells, ids in export_table(trace, "time-profile"):
            thread = next((n for t, n in cells if t == "thread"), None)
            if thread is None or "Main Thread" not in (thread.get("fmt") or ""):
                continue
            bt = next((n for t, n in cells if t in ("backtrace", "tagged-backtrace")), None)
            if bt is not None and bt.tag != "backtrace":
                bt = next(iter(bt.iter("backtrace")), bt)
            frames = [ids.get(f.get("ref"), f).get("name") or "?" for f in bt.iter("frame")] if bt is not None else []
            total += 1
            if frames:
                leaf[frames[0]] = leaf.get(frames[0], 0) + 1
            for name in set(frames):
                inclusive[name] = inclusive.get(name, 0) + 1
    except Exception as error:  # noqa: BLE001
        return {"error": f"export: {error}"}

    def top(counter, limit):
        return [{"frame": n[:200], "samples": c, "pct": round(100.0 * c / total, 1) if total else 0}
                for n, c in sorted(counter.items(), key=lambda kv: -kv[1]) if not n.startswith(GENERIC)][:limit]

    return {"main_samples": total, "top_inclusive": top(inclusive, 60), "top_leaf": top(leaf, 30)}


def record(name, ticks, terms, profile):
    path = os.path.join(SCRATCH, "traces", f"{opts.label}-{name}.trace")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    shutil.rmtree(path, ignore_errors=True)
    tick_end = None
    if ticks:
        start_ticks(terms, TICK_RUN_S)
        tick_end = time.monotonic() + TICK_RUN_S
        time.sleep(1)  # harness: the tick programs are running before the recorder attaches
    # The recorder's ktrace intermediates (1-12 GB each) go to a temp dir of this run, removed after the export.
    attach_at = time.time()
    xct_tmp = os.path.join(SCRATCH, "xctrace-tmp")
    os.makedirs(xct_tmp, exist_ok=True)
    proc = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Animation Hitches", "--attach", str(Target.pid),
                             "--time-limit", "60s", "--output", path, "--no-prompt"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=dict(os.environ, TMPDIR=xct_tmp + "/"))
    ground()
    time.sleep(4)  # harness: the recorder attaches before the gesture
    began = time.monotonic()
    bad = sweep("down") + sweep("up")
    gesture_s = round(time.monotonic() - began, 2)
    time.sleep(1)
    proc.send_signal(2)  # SIGINT ends the recording and writes the trace
    try:
        out, _ = proc.communicate(timeout=240)
    except subprocess.TimeoutExpired:
        proc.terminate()
        out = "timeout"
    result = {"name": name, "gesture_s": gesture_s, "wheel_errors": [json.dumps(b)[:200] for b in bad[:3]],
              "xctrace_exit": proc.returncode}
    if not os.path.exists(path):
        shutil.rmtree(xct_tmp, ignore_errors=True)
        result["error"] = f"no trace: {(out or '')[-300:]}"
        return result
    result.update(hitches(path, Target.pid))
    if profile:
        result["profile"] = main_thread_profile(path)
    # Report (never delete: other jobs' files) ktrace intermediates that still landed in the default temp dir.
    default_tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    leaked = [f for f in (os.listdir(default_tmp) if os.path.isdir(default_tmp) else [])
              if f.startswith("instruments") and f.endswith(".ktrace") and os.path.getmtime(os.path.join(default_tmp, f)) >= attach_at - 5]
    result["default_tmp_ktrace_since_start"] = len(leaked)
    # Those are this recording's (an input job runs alone in the GUI session): remove the ones no process holds open.
    for name in leaked:
        path_k = os.path.join(default_tmp, name)
        if not subprocess.run(["lsof", "-t", path_k], capture_output=True, text=True).stdout.strip():
            try:
                os.unlink(path_k)
            except OSError:
                pass
    # Keep only the numbers: the trace and the recorder's intermediates are removed (host disk).
    shutil.rmtree(path, ignore_errors=True)
    shutil.rmtree(xct_tmp, ignore_errors=True)
    if tick_end:
        time.sleep(max(0.0, tick_end - time.monotonic()) + 1)  # harness: the tick programs end before the next run
    print(f"{name}: {json.dumps({k: v for k, v in result.items() if k != 'profile'})}", flush=True)
    return result


launch()
try:
    make_workspaces()
    Target.find()
    terms = ticking_terminals()
    summary["ticking_terminals"] = len(terms)
    note(len(terms) >= opts.ticking, f"{len(terms)} ticking terminals")
    # The wheel moves the list (untraced sweep).
    summary["wheel_moves_list"] = find_wheel()
    note(summary["wheel_moves_list"], f"the wheel moves the list ({summary['wheel_variants'][-1]})")
    if not summary["wheel_moves_list"]:
        sys.exit("FAIL the wheel does not move the list: no gesture to measure")
    # CPU per tick, no input (10 s).
    pid = Target.pid
    cpu0 = cpu_ns(pid)
    t0 = time.monotonic()
    ticks = start_ticks(terms, 10)
    time.sleep(11)  # harness: the measured tick window
    cpu1 = cpu_ns(pid)
    summary["tick_window"] = {"seconds": round(time.monotonic() - t0, 1), "ticks": ticks,
                              "app_cpu_us_per_tick": round((cpu1 - cpu0) / 1000 / ticks, 1) if cpu0 and cpu1 and ticks else None,
                              "app_cpu_pct": round((cpu1 - cpu0) / 1e9 / (time.monotonic() - t0) * 100, 1) if cpu0 and cpu1 else None}
    print(f"tick window: {summary['tick_window']}", flush=True)
    time.sleep(2)
    runs = {"noticks": [], "ticks": []}
    for i in range(opts.repeats):
        for mode in ("noticks", "ticks"):
            runs[mode].append(record(f"{mode}-{i}", mode == "ticks", terms, i < opts.profile_runs))
            time.sleep(2)  # harness: settle between runs
    summary["runs"] = runs
    for mode, rs in runs.items():
        valid = [r for r in rs if "total_ms" in r and r.get("app_updates", 0) > 0 and not r.get("wheel_errors")]
        totals = [r["total_ms"] for r in valid]
        summary[mode] = {"valid": len(valid), "hitch_total_ms": totals,
                         "median_ms": statistics.median(totals) if totals else None,
                         "min_ms": min(totals) if totals else None, "max_ms": max(totals) if totals else None,
                         "update_p50_ms": statistics.median([r["update_p50_ms"] for r in valid if r.get("update_p50_ms")] or [0])}
        print(f"{mode}: {summary[mode]}", flush=True)
finally:
    summary["failures"] = failures
    with open(os.path.join(opts.out, f"release-{opts.label}.json"), "w") as fh:
        json.dump(summary, fh, indent=1)
    subprocess.run([STOP], check=False)
    cua("end_session", {})
    shutil.rmtree(SCRATCH, ignore_errors=True)
sys.exit(1 if failures else 0)

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
parser.add_argument("--b-fleet-job", help="A/B in one job: the fleet build job of the second app (installed here)")
parser.add_argument("--b-tag", help="the second app's tag")
parser.add_argument("--b-app", help="A/B: the second app's installed bundle (instead of --b-fleet-job)")
parser.add_argument("--b-label", default="b")
parser.add_argument("--clean", action="store_true",
                    help="one app at a time in the same frame: each run launches the app, records, and quits it (the others are"
                         " not running); the order of the apps and modes alternates each round")
parser.add_argument("--frame", default="40,40,1100,820", help="--clean: the window frame (points, top-left, last screen) of every app")
parser.add_argument("--floors", default="plain",
                    help="--clean: host floor variants (scripts/cmux-next/sidebar-scroll-floor.swift), comma list of plain, vib"
                         " (behind-window sidebar material), vibfade (material + edge-fade mask), fade (edge-fade mask), optout"
                         " (scrollWheel override: no responsive scrolling), optoutfade; empty = none")
parser.add_argument("--modes", default="noticks,ticks", help="--clean: the modes each cmux run records")
parser.add_argument("--round-offset", type=int, default=0,
                    help="--clean: the first round's number (an odd offset starts with the reversed order, for a second job)")
parser.add_argument("--variants", default="",
                    help="--clean: more runs of the first app with extra launch env, 'label:KEY=V,KEY2=V;label2:KEY=V'"
                         " (each variant is one more app in the rotation; it shares the tag's workspaces)")
parser.add_argument("--floor-frames", default="",
                    help="--clean: extra frames for the plain floor (a window position probe), separated by ';'")
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


def quit_app(sock):
    """The in-app quit (action.run quitEndSessions, as NX_APP_STOP asks it) of the app serving `sock`."""
    import socket as so
    try:
        with so.socket(so.AF_UNIX, so.SOCK_STREAM) as conn:
            conn.settimeout(20)
            conn.connect(sock)
            conn.sendall((json.dumps({"id": 1, "method": "action.run", "params": {"id": "quitEndSessions"}}) + "\n").encode())
            conn.recv(65536)
        return True
    except OSError:
        return False


def launch(frame="40,40,1100,820"):
    # A copy of this tag left running by a cancelled run of this script: quit it first (never a kill).
    if os.path.exists(SOCKET) and quit_app(SOCKET):
        wait(lambda: app_pid() is None, 60)
        print(f"quit a leftover {TAG} app", flush=True)
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = [*EXTRA_ENV, "CMUX_NEXT_NO_ACTIVATE=1", "CMUX_NEXT_SOCKET_MODE=automation", "CMUX_NEXT_TEST_WINDOW_SCREEN=last",
           f"CMUX_NEXT_CONFIG_FILE={CONFIG}", f"CMUX_NEXT_GHOSTTY_CONFIG={GHOSTTY}", f"CMUX_NEXT_TEST_WINDOW_FRAME={frame}"]
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

    bounds = None

    @classmethod
    def find(cls, pid=None):
        pid = pid or app_pid()
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
        cls.pid, cls.window_id, cls.bounds = pid, main["window_id"], main["bounds"]
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
            if not event:
                return [{"error": "CGEventCreateScrollWheelEvent2 returned NULL"}]
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
    # Below -[NSViewBackingLayer display] (AppKit's drawRect/updateLayer) and CA's layer display: what draws.
    under = {"-[NSViewBackingLayer display]": {}, "CA::Layer::display_if_needed(CA::Transaction*)": {},
             "-[NSView translateOriginToPoint:]": {}, "-[NSView _postBoundsChangeNotification]": {}, "FrameBatcher.drain()": {},
             "-[NSView layoutSubtreeIfNeeded]": {}, "CA::Context::commit_transaction(CA::Transaction*, double, double*)": {}}
    under_total = dict.fromkeys(under, 0)
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
            for root, counter in under.items():
                if root in frames:
                    under_total[root] += 1
                    for name in set(frames[:frames.index(root)]):
                        counter[name] = counter.get(name, 0) + 1
    except Exception as error:  # noqa: BLE001
        return {"error": f"export: {error}"}

    def top(counter, limit):
        return [{"frame": n[:200], "samples": c, "pct": round(100.0 * c / total, 1) if total else 0}
                for n, c in sorted(counter.items(), key=lambda kv: -kv[1]) if not n.startswith(GENERIC)][:limit]

    return {"main_samples": total, "top_inclusive": top(inclusive, 60), "top_leaf": top(leaf, 30),
            "under": {root: {"samples": under_total[root],
                             "top": [{"frame": n[:200], "samples": c} for n, c in sorted(counter.items(), key=lambda kv: -kv[1])][:50]}
                      for root, counter in under.items()}}


def hitch_details(trace, pid, limit=12):
    """The trace's table schemas and every column of the longest hitches of `pid` (what kind of frame was late)."""
    toc = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--toc"], capture_output=True, text=True).stdout
    schemas = sorted(set(re.findall(r'schema="([^"]+)"', toc)))
    rows = []
    try:
        for cells, _ in export_table(trace, "hitches"):
            process = next((n for t, n in cells if t == "process"), None)
            if process is None or f"({pid})" not in (process.get("fmt") or ""):
                continue
            rows.append({t: (n.get("fmt") or n.text or "")[:120] for t, n in cells})
    except Exception as error:  # noqa: BLE001
        return {"schemas": schemas, "error": f"export: {error}"}
    rows.sort(key=lambda r: -float(re.sub(r"[^0-9.]", "", r.get("duration", "0")) or 0))
    return {"schemas": schemas, "longest": rows[:limit]}


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
    # This recording's ktrace intermediates: the files the recorder holds open now (removed after the export).
    held = subprocess.run(["lsof", "-p", str(proc.pid), "-Fn"], capture_output=True, text=True).stdout.splitlines()
    mine = {line[1:] for line in held if line.startswith("n") and os.path.basename(line[1:]).startswith("instruments")
            and line.endswith(".ktrace")}
    load_before = [round(x, 2) for x in os.getloadavg()]  # host load (other lanes' jobs run beside an input job)
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
    result = {"name": name, "gesture_s": gesture_s, "bounds": Target.bounds, "load_before": load_before,
              "load_after": [round(x, 2) for x in os.getloadavg()], "wheel_errors": [json.dumps(b)[:200] for b in bad[:3]],
              "xctrace_exit": proc.returncode}
    if not os.path.exists(path):
        shutil.rmtree(xct_tmp, ignore_errors=True)
        result["error"] = f"no trace: {(out or '')[-300:]}"
        return result
    result.update(hitches(path, Target.pid))
    if profile:
        result["profile"] = main_thread_profile(path)
        result["hitch_details"] = hitch_details(path, Target.pid)
    # Remove this recording's own ktrace intermediates (attributed above by the recorder's open files), once closed.
    removed = 0
    for path_k in mine:
        if os.path.exists(path_k) and not subprocess.run(["lsof", "-t", path_k], capture_output=True, text=True).stdout.strip():
            try:
                os.unlink(path_k)
                removed += 1
            except OSError:
                pass
    result["ktrace_removed"] = removed
    # Keep only the numbers: the trace and the recorder's intermediates are removed (host disk).
    shutil.rmtree(path, ignore_errors=True)
    shutil.rmtree(xct_tmp, ignore_errors=True)
    if tick_end:
        time.sleep(max(0.0, tick_end - time.monotonic()) + 1)  # harness: the tick programs end before the next run
    print(f"{name}: {json.dumps({k: v for k, v in result.items() if k != 'profile'})}", flush=True)
    return result


EXTRA_ENV = []


def use(app):
    """Points the module's app globals (APP, TAG, SOCKET, CLI, Target, EXTRA_ENV) at `app`."""
    global APP, TAG, SOCKET, CLI, EXTRA_ENV
    EXTRA_ENV = list(app.get("env") or [])
    APP, TAG, SOCKET, CLI = app["app"], app["tag"], app["socket"], app["cli"]
    if app.get("target"):
        Target.pid, Target.window_id, Target.scale, Target.point, Target.screen_point = app["target"]


def install_b():
    """The second app of an A/B job: the fleet artifact of --b-fleet-job, unpacked and signed ad hoc here."""
    ci = os.path.expanduser("~/.local/bin/cmux-ci")
    zpath, dest = os.path.join(SCRATCH, "b.zip"), os.path.join(SCRATCH, "b")
    got = subprocess.run([ci, "artifact", opts.b_fleet_job, zpath], capture_output=True, text=True, timeout=900)
    if got.returncode != 0:
        sys.exit(f"FAIL cmux-ci artifact {opts.b_fleet_job}: {got.stderr[-300:]}")
    os.makedirs(dest, exist_ok=True)
    subprocess.run(["/usr/bin/ditto", "-x", "-k", zpath, dest], check=True)
    os.unlink(zpath)
    app = os.path.join(dest, f"cmux DEV {opts.b_tag}.app")
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", app], capture_output=True, check=True)
    return {"label": opts.b_label, "app": app, "tag": opts.b_tag, "socket": f"/tmp/cmux-debug-{opts.b_tag}.sock",
            "cli": os.path.join(app, "Contents/Resources/bin/cmux"), "frame": "760,40,740,820"}


def stop_b(app):
    """Quits the B app as NX_APP_STOP quits A: the in-app quit, then its terminal server."""
    if not quit_app(app["socket"]):
        print("B quit: no reply", flush=True)
    wait(lambda: not os.path.exists(app["socket"]) or app_pid() is None, 30)
    tui = os.path.join(app["app"], "Contents/Resources/bin/cmux-tui")
    if os.access(tui, os.X_OK):
        subprocess.run([tui, "--session", f"cmux-app-{app['tag']}", "server", "stop", "--end-terminals"],
                       capture_output=True, timeout=60)


def scrollbar_values():
    """AXValue of each scroll bar in the window, by x (the sidebar's is the leftmost)."""
    reply = cua("get_window_state", {"pid": Target.pid, "window_id": Target.window_id,
                                     "screenshot_out_file": os.path.join(SCRATCH, "bars.png")}, timeout=120)
    bars = []

    def walk(node):
        if isinstance(node, dict):
            if node.get("role") == "AXScrollBar" and node.get("value") not in (None, ""):
                bars.append(((node.get("frame") or {}).get("x", 0), node.get("value")))
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(reply)
    return [v for _, v in sorted(bars, key=lambda b: float(b[0] or 0))]


def prepare(app):
    use(app)
    launch(app["frame"])
    make_workspaces()
    Target.find()
    app["target"] = (Target.pid, Target.window_id, Target.scale, Target.point, Target.screen_point)
    app["terms"] = ticking_terminals()
    note(len(app["terms"]) >= opts.ticking, f"{app['label']}: {len(app['terms'])} ticking terminals")
    WHEEL.clear()
    WHEEL.update({"hid": True})
    # The HID wheel reaches this app's sidebar: its scroll bar moves after a sweep down (and back after up).
    before = scrollbar_values()
    sweep("down", 6)
    after = scrollbar_values()
    sweep("up", 6)
    ground()
    app["wheel_check"] = {"before": before[:3], "after": after[:3], "moved": bool(after) and after[:1] != before[:1]}
    note(app["wheel_check"]["moved"], f"{app['label']}: the wheel moves the sidebar ({app['wheel_check']})")
    # CPU per tick, no input (10 s).
    cpu0 = cpu_ns(Target.pid)
    t0 = time.monotonic()
    ticks = start_ticks(app["terms"], 10)
    time.sleep(11)  # harness: the measured tick window
    cpu1 = cpu_ns(Target.pid)
    app["tick_window"] = {"seconds": round(time.monotonic() - t0, 1), "ticks": ticks,
                          "app_cpu_us_per_tick": round((cpu1 - cpu0) / 1000 / ticks, 1) if cpu0 and cpu1 and ticks else None,
                          "app_cpu_pct": round((cpu1 - cpu0) / 1e9 / (time.monotonic() - t0) * 100, 1) if cpu0 and cpu1 else None}
    print(f"{app['label']} tick window: {app['tick_window']}", flush=True)


def pty_count():
    """PTYs in use on the host (/dev/ttys*), logged before and after (950 workspaces per app have no terminal)."""
    return len([n for n in os.listdir("/dev") if n.startswith("ttys")])


def build_floor():
    """The host floor app (no cmux code), compiled here from scripts/cmux-next/sidebar-scroll-floor.swift."""
    exe = os.path.join(SCRATCH, "sidebar-scroll-floor")
    built = subprocess.run(["xcrun", "swiftc", "-O", "-o", exe, os.path.join(HERE, "sidebar-scroll-floor.swift")],
                           capture_output=True, text=True, timeout=900)
    if built.returncode != 0:
        sys.exit(f"FAIL floor build: {built.stderr[-400:]}")
    return exe


def floor_run(exe, variant, frame, label, i):
    """One plain-scroll gesture over the floor app in `frame`; the app quits after it."""
    flags = {"plain": [], "vib": ["--vibrancy"], "vibfade": ["--vibrancy", "--fade"], "fade": ["--fade"],
             "optout": ["--opt-out"], "optoutfade": ["--opt-out", "--fade"]}[variant]
    proc = subprocess.Popen([exe, "--frame", frame, "--screen", "last", "--rows", str(opts.count), *flags],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    try:
        ready = proc.stdout.readline().strip()
        if not ready.startswith("ready"):
            return {"name": f"{label}-noticks-{i}", "error": f"floor did not start: {ready!r}"}
        Target.find(proc.pid)
        quiet = wait_quiet(proc.pid)
        point_x, point_y = Target.bounds["x"] + 110, Target.bounds["y"] + 430
        Target.point, Target.screen_point = (110 * Target.scale, 430 * Target.scale), (point_x, point_y)
        time.sleep(2)  # harness: the window is on screen and idle before the recorder attaches
        result = record(f"{label}-noticks-{i}", False, [], False)
        result["quiet"] = quiet
        return result
    finally:
        proc.stdin.close()  # the floor quits when its stdin ends
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.terminate()  # our own child process (exact pid)
            proc.wait(timeout=30)


def wait_quiet(pid, below_pct=4.0, limit_s=120):
    """Waits until the app's CPU stays under `below_pct` for 2 one-second windows in a row (startup, state load and
    workspace churn done), at most `limit_s`. Returns the seconds waited and the last window's CPU %."""
    started, calm, pct = time.monotonic(), 0, None
    while time.monotonic() - started < limit_s and calm < 2:  # harness: bounded wait for an idle app
        c0, t0 = cpu_ns(pid), time.monotonic()
        time.sleep(1)
        c1 = cpu_ns(pid)
        if c0 is None or c1 is None:
            break
        pct = round((c1 - c0) / 1e9 / (time.monotonic() - t0) * 100, 1)
        calm = calm + 1 if pct < below_pct else 0
    return {"seconds": round(time.monotonic() - started, 1), "cpu_pct": pct, "quiet": calm >= 2}


def cmux_runs(app, i, first):
    """Launches `app` in --frame, records both modes (order flipped by round), quits it."""
    use(app)
    launch(opts.frame)
    make_workspaces()
    Target.find()
    app["terms"] = ticking_terminals()
    note(len(app["terms"]) >= opts.ticking, f"{app['label']} round {i}: {len(app['terms'])} ticking terminals")
    WHEEL.clear()
    WHEEL.update({"hid": True})
    out = {}
    if first and "ticks" in opts.modes.split(","):
        cpu0, t0 = cpu_ns(Target.pid), time.monotonic()
        ticks = start_ticks(app["terms"], 10)
        time.sleep(11)  # harness: the measured tick window (no input)
        cpu1 = cpu_ns(Target.pid)
        app["tick_window"] = {"ticks": ticks, "app_cpu_us_per_tick": round((cpu1 - cpu0) / 1000 / ticks, 1)
                              if cpu0 and cpu1 and ticks else None}
        print(f"{app['label']} tick window: {app['tick_window']}", flush=True)
    modes = [m for m in opts.modes.split(",") if m]
    for mode in (modes if i % 2 == 0 else modes[::-1]):
        quiet = wait_quiet(Target.pid)
        print(f"{app['label']} {mode} {i}: quiet {quiet}", flush=True)
        out[mode] = record(f"{app['label']}-{mode}-{i}", mode == "ticks", app["terms"], i - opts.round_offset < opts.profile_runs)
        out[mode]["quiet"] = quiet
        time.sleep(2)  # harness: settle between runs
    stop_b(app)
    note(app_pid() is None, f"{app['label']} round {i}: the app quit")
    return out


def run_clean(apps):
    """One app on screen at a time, all in the same frame; floors (no cmux code) in the same frame too."""
    floors = [v for v in opts.floors.split(",") if v]
    extra = [f for f in opts.floor_frames.split(";") if f]
    exe = build_floor() if floors or extra else None
    items = [("cmux", app) for app in apps] + [("floor", (v, opts.frame, f"floor-{v}")) for v in floors]
    items += [("floor", ("plain", f, "floor-at-" + f.replace(",", "_"))) for f in extra]
    runs = {}
    for i in range(opts.round_offset, opts.round_offset + opts.repeats):
        order = items if i % 2 == 0 else items[::-1]
        print(f"round {i}: {[it[1]['label'] if it[0] == 'cmux' else it[1][2] for it in order]}", flush=True)
        for kind, item in order:
            if kind == "cmux":
                for mode, result in cmux_runs(item, i, i == opts.round_offset).items():
                    runs.setdefault(item["label"], {}).setdefault(mode, []).append(result)
            else:
                variant, frame, label = item
                runs.setdefault(label, {}).setdefault("noticks", []).append(floor_run(exe, variant, frame, label, i))
            time.sleep(2)  # harness: settle between apps
    return runs


def summarize(runs, apps):
    for label, modes in runs.items():
        app = next((a for a in apps if a["label"] == label), {})
        out = summary.setdefault("apps", {}).setdefault(label, {"tag": app.get("tag"), "tick_window": app.get("tick_window")})
        for mode, rs in modes.items():
            valid = [r for r in rs if "total_ms" in r and not r.get("wheel_errors")
                     and r.get("app_updates", 0) >= 60 * r.get("gesture_s", 0)]
            totals = [r["total_ms"] for r in valid]
            out[mode] = {"valid": len(valid), "hitch_total_ms": totals, "hitches": [r.get("hitches") for r in valid],
                         "median_ms": statistics.median(totals) if totals else None,
                         "min_ms": min(totals) if totals else None, "max_ms": max(totals) if totals else None,
                         "update_p50_ms": statistics.median([r["update_p50_ms"] for r in valid if r.get("update_p50_ms")] or [0]),
                         "bounds": sorted({json.dumps(r.get("bounds"), sort_keys=True) for r in rs})}
            print(f"{label} {mode}: {out[mode]}", flush=True)


import signal
signal.signal(signal.SIGTERM, lambda *_: sys.exit("FAIL ended by SIGTERM (job cancel or input cap)"))
summary["ptys_before"] = pty_count()
print(f"ptys in use before: {summary['ptys_before']}", flush=True)
A = {"label": opts.label, "app": APP, "tag": TAG, "socket": SOCKET, "cli": CLI,
     "frame": "10,40,740,820" if opts.b_fleet_job else "40,40,1100,820"}
apps = [A]
try:
    if opts.b_app:
        apps.append({"label": opts.b_label, "app": opts.b_app, "tag": opts.b_tag, "socket": f"/tmp/cmux-debug-{opts.b_tag}.sock",
                     "cli": os.path.join(opts.b_app, "Contents/Resources/bin/cmux"), "frame": opts.frame})
    elif opts.b_fleet_job:
        apps.append(install_b())
    if opts.clean:
        A["frame"] = opts.frame
        for app in apps[1:]:
            app["frame"] = opts.frame
        for spec in [v for v in opts.variants.split(";") if v.strip()]:
            name, _, env = spec.partition(":")
            apps.append(dict(A, label=name.strip(), env=[e for e in env.split(",") if e]))
        summary["method"] = {"clean": True, "variants": opts.variants, "frame": opts.frame, "floors": opts.floors, "floor_frames": opts.floor_frames}
        runs = run_clean(apps)
        summary["runs"] = runs
        summarize(runs, apps)
    else:
        for app in apps:
            prepare(app)
        runs = {app["label"]: {"noticks": [], "ticks": []} for app in apps}
        for i in range(opts.repeats):
            # Interleaved, the order flipped each round, so host drift lands on both apps alike.
            for app in (apps if i % 2 == 0 else apps[::-1]):
                use(app)
                cua("bring_to_front", {"pid": Target.pid})
                time.sleep(1)  # harness: the window is in front before the recorder attaches
                for mode in (("noticks", "ticks") if i % 2 == 0 else ("ticks", "noticks")):
                    runs[app["label"]][mode].append(record(f"{app['label']}-{mode}-{i}", mode == "ticks", app["terms"], i < opts.profile_runs))
                    time.sleep(2)  # harness: settle between runs
        summary["runs"] = runs
        for app in apps:
            out = summary.setdefault("apps", {}).setdefault(app["label"], {"tag": app["tag"], "tick_window": app.get("tick_window")})
            for mode, rs in runs[app["label"]].items():
                valid = [r for r in rs if "total_ms" in r and not r.get("wheel_errors")
                         and r.get("app_updates", 0) >= 60 * r.get("gesture_s", 0)]
                totals = [r["total_ms"] for r in valid]
                out[mode] = {"valid": len(valid), "hitch_total_ms": totals,
                             "median_ms": statistics.median(totals) if totals else None,
                             "min_ms": min(totals) if totals else None, "max_ms": max(totals) if totals else None,
                             "update_p50_ms": statistics.median([r["update_p50_ms"] for r in valid if r.get("update_p50_ms")] or [0])}
                print(f"{app['label']} {mode}: {out[mode]}", flush=True)
finally:
    summary["failures"] = failures
    with open(os.path.join(opts.out, f"release-{opts.label}.json"), "w") as fh:
        json.dump(summary, fh, indent=1)
    b_alive = False
    for app in apps[1:]:
        try:
            use(app)
            stop_b(app)
            b_alive = b_alive or app_pid() is not None
        except Exception as error:  # noqa: BLE001 (cleanup goes on)
            print(f"B stop: {error}", flush=True)
            b_alive = True
    use(A)
    subprocess.run([STOP], check=False)
    try:
        cua("end_session", {})
    except Exception:  # noqa: BLE001
        pass
    summary["ptys_after"] = pty_count()
    print(f"ptys in use after: {summary['ptys_after']}", flush=True)
    with open(os.path.join(opts.out, f"release-{opts.label}.json"), "w") as fh:
        json.dump(summary, fh, indent=1)
    if b_alive:
        print(f"B app still runs: its bundle stays in {SCRATCH} (no kill on build hosts)", flush=True)
    else:
        shutil.rmtree(SCRATCH, ignore_errors=True)
sys.exit(1 if failures else 0)

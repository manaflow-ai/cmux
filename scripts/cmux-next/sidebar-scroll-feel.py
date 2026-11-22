#!/usr/bin/env python3
"""How the sidebar list feels to scroll, with real trackpad input (Leo 2026-11-12: "there is noticeably much, much
faster, like, immediate scroll up and down [in the agent chat] ... Sidebar, though, still kind of a little bit whack,
which is funny because of how fast the agent chat area is").

Launches the tagged app frontmost on a GUI host (a scratch cmux.json, a fresh tag state), grows the sidebar to
--workspaces empty workspaces over --groups groups, then for each phase posts --flicks real trackpad flicks over the
sidebar at the HID event tap (CGEventPost scroll events with gesture and momentum phases, as a trackpad sends: the
window server, the app's event queue, and AppKit's responsive scrolling, which moves the clip off the main thread):

  quiet   nothing else runs
  stall   the main thread is busy --stall-ms every --stall-every-ms (`debug.stall`), the way a busy app's main
          thread is (Leo's NIGHTLY on 2026-11-12 logged 1,003 main-thread stalls of 100-250 ms and 668 of 50-100 ms
          in a day, HangReports stallHistogram)
  ticks   agent status changes on --tick-workspaces workspaces at --tick-hz through the app's CLI

Per phase it reports the sidebar counters (`debug.sidebar_perf`), most of all `blank_rows` (rows that were in view
with no row view when the main thread caught up: rows shown empty) and `blank_passes`; the display frame intervals
(`debug.frames`); the main-thread time per row patch (`main_ns`, `row_patches`) for the ticks; and that the list moved.
It also times the first paint: the app is quit and launched again over the same workspaces, and the time from the
spawn to the first `debug.sidebar_rows` answer that lists realized rows is `first_rows_s`.

  sidebar-scroll-feel.py --app APP --tag TAG --out DIR [--workspaces 150] [--groups 8] [--flicks 8]

Needs the GUI session (`--input hid` also the post-event grant and the app in front): an owned mini through
split-spring.sh's suite (it builds the app at the ref):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \
    --artifact artifacts/split-spring/report.json --arg=--config=bench --arg=--suite=sidebar-scroll-feel
Writes --json (default DIR/report.json).
"""
import argparse, ctypes, ctypes.util, json, os, statistics, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp, LaunchError  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json", help="the report's path (default OUT/report.json)")
parser.add_argument("--workspaces", type=int, default=150)
parser.add_argument("--groups", type=int, default=8)
parser.add_argument("--input", choices=("wheel-rpc", "hid"), default="wheel-rpc")
parser.add_argument("--flicks", type=int, default=8, help="flicks per phase, alternating down and up")
parser.add_argument("--phases", default="quiet,stall,ticks")
parser.add_argument("--stall-ms", type=int, default=120)
parser.add_argument("--stall-every-ms", type=int, default=350)
parser.add_argument("--tick-hz", type=float, default=10.0)
parser.add_argument("--tick-workspaces", type=int, default=20)
parser.add_argument("--no-first-paint", action="store_true")
opts, _ignored = parser.parse_known_args()  # split-spring.sh passes its own options too
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
WINDOW = (40, 40, 1200, 900)
results = {"tag": opts.tag, "host": os.uname().nodename, "opts": vars(opts), "phases": {}, "log": []}
bench = None


def note(text):
    print(text, flush=True)
    results["log"].append(text)


def rpc(method, params=None, timeout=60):
    return bench.rpc(method, params, timeout=timeout)


def cli(*args, timeout=60):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    env["CMUX_NEXT_CONFIG_FILE"] = os.path.join(bench.scratch, "cmux.json")
    try:
        return subprocess.run([bench.cli, "--app-socket", bench.socket, *args], env=env, capture_output=True, text=True,
                              timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, 124, "", "timeout")


def pct(values):
    if not values:
        return None
    s = sorted(values)
    pick = lambda p: s[min(len(s) - 1, int(round((len(s) - 1) * p)))]
    return {"n": len(s), "p50": round(pick(0.5), 2), "p95": round(pick(0.95), 2), "p99": round(pick(0.99), 2),
            "max": round(s[-1], 2), "mean": round(statistics.fmean(s), 2)}


# Real trackpad input at the HID event tap.
CG = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))
CG.CGEventCreateScrollWheelEvent2.restype = ctypes.c_void_p
CG.CGEventCreateScrollWheelEvent2.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32,
                                              ctypes.c_int32, ctypes.c_int32]
CG.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
CG.CGEventCreateMouseEvent.restype = ctypes.c_void_p


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


CG.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
CG.CGEventSetLocation.argtypes = [ctypes.c_void_p, CGPoint]
CG.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
CG.CFRelease.argtypes = [ctypes.c_void_p]
FIELD_CONTINUOUS, FIELD_PHASE, FIELD_MOMENTUM = 88, 99, 123  # kCGScrollWheelEventIsContinuous, ScrollPhase, MomentumPhase
PHASE_BEGAN, PHASE_CHANGED, PHASE_ENDED = 1, 2, 4
MOMENTUM_BEGIN, MOMENTUM_CONTINUE, MOMENTUM_END = 1, 2, 3


def move_pointer(point):
    event = CG.CGEventCreateMouseEvent(None, 5, CGPoint(*point), 0)  # kCGEventMouseMoved
    CG.CGEventPost(0, event)
    CG.CFRelease(event)


def scroll_event(point, dy, phase=0, momentum=0):
    event = CG.CGEventCreateScrollWheelEvent2(None, 0, 1, int(dy), 0, 0)  # kCGScrollEventUnitPixel, one wheel
    CG.CGEventSetIntegerValueField(event, FIELD_CONTINUOUS, 1)
    CG.CGEventSetIntegerValueField(event, FIELD_PHASE, phase)
    CG.CGEventSetIntegerValueField(event, FIELD_MOMENTUM, momentum)
    CG.CGEventSetLocation(event, CGPoint(*point))
    CG.CGEventPost(0, event)
    CG.CFRelease(event)


def flick(point, direction):
    """One trackpad flick: a real HID gesture when the app can get one (`--input hid`), else (the default) three
    quick trackpad gestures of 4 events, 40 pt each, through `debug.sidebar_wheel`, which hands them to the window's
    own `sendEvent` as the window server would. Events posted from outside never reach a background app, and a bench
    host's step has no front app or post-event grant to rely on. A main-thread stall lands between the gestures, as
    one lands inside a real flick. `direction` -1 shows later rows (content moves up), +1 earlier rows."""
    if opts.input == "hid":
        hz = 1 / 120
        scroll_event(point, 0, phase=PHASE_BEGAN)
        time.sleep(hz)
        for _ in range(6):
            scroll_event(point, 40 * direction, phase=PHASE_CHANGED)
            time.sleep(hz)
        scroll_event(point, 0, phase=PHASE_ENDED)
        velocity = 60.0
        scroll_event(point, velocity * direction, momentum=MOMENTUM_BEGIN)
        while velocity > 1:
            time.sleep(hz)
            velocity *= 0.95
            scroll_event(point, velocity * direction, momentum=MOMENTUM_CONTINUE)
        scroll_event(point, 0, momentum=MOMENTUM_END)
        return
    for _ in range(3):
        reply = rpc("debug.sidebar_wheel", {"x": 130, "y": WINDOW[3] / 2, "dy": 40 * direction, "count": 4,
                                            "trackpad": True, "interval_ms": 8}, timeout=30) or {}
        if not reply.get("sent"):
            note(f"debug.sidebar_wheel sent nothing: {json.dumps(reply)[:200]}")
        time.sleep(0.03)


FRONT_SWIFT = r"""
import AppKit
let pid = pid_t(CommandLine.arguments[1])!
NSRunningApplication(processIdentifier: pid)?.activate()
let until = Date().addingTimeInterval(5)
while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, Date() < until {
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))  // harness: wait for the front app
}
print(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
"""


def bring_front(pid):
    """Make the bench app the front app (AppKit's activate, not System Events: its Automation prompt hangs a
    headless bench). Scroll events go to the window under the pointer either way, so a miss is only noted."""
    try:
        r = subprocess.run(["swift", "-", str(pid)], input=FRONT_SWIFT, capture_output=True, text=True, timeout=120)
        front = r.stdout.strip().endswith("true")
    except (OSError, subprocess.TimeoutExpired):
        front = False
    if not front:
        print(f"bring_front: pid {pid} is not the front app; flicks still go to the window under the pointer",
              file=sys.stderr)
    return front


def sidebar_window():
    windows = (rpc("debug.sidebar_rows", timeout=120) or {}).get("windows") or []
    return max(windows, key=lambda w: len(w.get("rows") or []), default=None)


def realized_titles():
    window = sidebar_window() or {}
    return [r.get("title") for r in window.get("rows") or [] if r.get("view_frame")]


class Staller(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.stop_flag = threading.Event()
        self.count = 0

    def run(self):
        while not self.stop_flag.is_set():
            rpc("debug.stall", {"ms": opts.stall_ms}, timeout=10)
            self.count += 1
            self.stop_flag.wait(max(0, opts.stall_every_ms - opts.stall_ms) / 1000)

    def stop(self):
        self.stop_flag.set()
        self.join(timeout=10)


class Ticker(threading.Thread):
    def __init__(self, ids):
        super().__init__(daemon=True)
        self.ids, self.stop_flag, self.count = ids, threading.Event(), 0

    def run(self):
        states = ["working", "waiting", "working", "done"]
        while not self.stop_flag.is_set():
            t0 = time.perf_counter()
            cli("workspace", self.ids[self.count % len(self.ids)], "status", "set", "agent",
                states[(self.count // len(self.ids)) % len(states)], timeout=20)
            self.count += 1
            self.stop_flag.wait(max(0, 1 / opts.tick_hz - (time.perf_counter() - t0)))

    def stop(self):
        self.stop_flag.set()
        self.join(timeout=30)


def run_phase(name, point, ids):
    load = Staller() if name == "stall" else Ticker(ids[:opts.tick_workspaces]) if name == "ticks" else None
    before = realized_titles()
    rpc("debug.sidebar_perf", {"reset": True})
    rpc("debug.frames", {"action": "start"})
    if load:
        load.start()
        time.sleep(1)
    t0 = time.monotonic()
    for index in range(opts.flicks):
        flick(point, -1 if index % 2 == 0 else 1)
        time.sleep(0.3)
    seconds = time.monotonic() - t0
    if load:
        load.stop()
    frames = rpc("debug.frames", {"action": "stop"}) or {}
    counters = rpc("debug.sidebar_perf", {"reset": True}) or {}
    moved = before != realized_titles()
    picked = {k: counters.get(k) for k in ("blank_rows", "blank_passes", "scroll_realizes", "row_configures", "row_patches",
                                            "row_views_made", "list_reloads", "main_ns")}
    phase = {"seconds": round(seconds, 2), "counters": picked, "moved": moved,
             "blank_rows_per_flick": round((picked.get("blank_rows") or 0) / opts.flicks, 2),
             "frames": {k: frames.get(k) for k in ("count", "p50_ms", "p95_ms", "p99_ms", "max_ms", "missed", "refresh_ms")
                        if k in frames},
             "load_events": getattr(load, "count", 0)}
    if name == "ticks" and picked.get("row_patches"):
        phase["main_us_per_patch"] = round((picked.get("main_ns") or 0) / 1000 / picked["row_patches"], 1)
    results["phases"][name] = phase
    note(f"{name}: {json.dumps(phase)}")


def launch():
    global bench
    env = {"CMUX_NEXT_NO_ACTIVATE": None}
    bench = BenchApp(opts.app, out=OUT, config={"appearance": {"theme": "Catppuccin Mocha"}}, window=WINDOW,
                     log_name="app.log", env=env, fresh_state=bench is None)
    bench.launch(timeout=180)
    return bench


def first_paint():
    """Quits the app and launches it again over the same saved workspaces: spawn to the first realized rows."""
    bench.stop()
    os.environ["BENCH_LAUNCH_KEEP_STATE"] = "1"
    launch()
    spawn = bench.launched_at
    deadline = time.time() + 60
    while time.time() < deadline:  # bounded wait for the first realized rows
        if len(realized_titles()) >= 10:
            results["first_rows_s"] = round(time.time() - spawn, 3)
            break
        time.sleep(0.05)
    results["first_paint_ready_s"] = bench.ready_seconds
    note(f"first paint: rows {results.get('first_rows_s')} s, socket {bench.ready_seconds} s")


def main():
    try:
        launch()
    except LaunchError as error:
        results["launch_failure"] = {"reason": error.reason}
        raise
    try:
        groups = []
        for g in range(opts.groups):
            name = f"feel group {g:02d}"
            cli("workspace", "group", "create", "--name", name)
            groups.append(name)
        for i in range(opts.workspaces):
            cli("workspace", "create", "--empty", "--name", f"feel {i:04d} agent workspace with a longer title")
        snap = rpc("snapshot.get") or {}
        listed = (snap.get("topology") or snap).get("workspaces") or []
        ids = [w.get("id") for w in listed if str(w.get("name") or w.get("title") or "").startswith("feel ")]
        for index, ws in enumerate(ids):
            if groups and index % 4 != 3:
                cli("workspace", "group", groups[index % len(groups)], "add", "--workspace", ws)
            if index % 3 == 0:
                cli("workspace", ws, "status", "set", "agent", "working")
        note(f"setup: {len(ids)} workspaces, {len(groups)} groups")
        results["setup"] = {"workspaces": len(ids), "groups": len(groups)}
        bring_front(bench.process.pid)
        time.sleep(3)
        # The sidebar's middle, in global display points (top-left origin): the window is at WINDOW on the main display.
        point = (WINDOW[0] + 130, WINDOW[1] + WINDOW[3] / 2)
        move_pointer(point)
        time.sleep(0.5)
        for name in [p for p in opts.phases.split(",") if p]:
            run_phase(name, point, ids)
        if not opts.no_first_paint:
            first_paint()
    finally:
        with open(opts.json or os.path.join(OUT, "report.json"), "w") as f:
            json.dump(results, f, indent=1, default=str)
        if bench:
            bench.stop()
    print("SIDEBAR-SCROLL-FEEL " + json.dumps({"phases": results["phases"], "first_rows_s": results.get("first_rows_s")}))


if __name__ == "__main__":
    main()

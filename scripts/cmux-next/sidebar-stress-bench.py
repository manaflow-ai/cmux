#!/usr/bin/env python3
"""Sidebar stress and lag bench (hq-2d, Lawrence 2026-10-14: "scrolling lags"; "imagine a ton of
workspaces").

Launches the tagged app itself on a GUI host (no activation, a scratch cmux.json, an isolated Chief
home; it never opens Home or the Chief pane), then grows the sidebar to each size in --sizes (default
100, 500, 1000 workspaces), spread over groups, some pinned. About 5% of the workspaces run a shell
loop that prints OSC 7501 working records with a new progress every 250 ms (real terminal output);
the other workspaces have no terminal (`create-workspace`, no PTY: the host has a few hundred PTYs).

Per size it measures:
  memory        phys_footprint of the app (proc_pid_rusage)
  cpu idle      app CPU share over 10 s, tickers paused (their rows still show working)
  cpu ticks     app CPU share over 10 s, tickers running; main-thread time per tick (Time Profiler)
  scroll        a trackpad gesture over the whole list and back (`debug.mouse` scroll, 60 events/s):
                display frame intervals (`debug.frames`), per-event handling time (RPC round trip
                minus a no-op RPC), Time Profiler main-thread top frames
  switch        clicks on visible workspace rows: time until the main thread answers the next RPC
                (the selection is applied and drawn by then) and the frame intervals
  drag          a row dragged over the list (`debug.mouse` down, then one dragged event per RPC):
                main-thread time per mouse-move (Time Profiler) and frame intervals
Traces go to OUT/traces/*.trace; OUT/results.json holds every number and the top main-thread frames.

Usage (nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA):
  sidebar-stress-bench.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS/stress" [--sizes 100,500,1000]
"""
import argparse, glob, json, os, shutil, socket, statistics, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--sizes", default="100,500,1000")
parser.add_argument("--groups", type=int, default=10)
parser.add_argument("--tick-share", type=float, default=0.05)
parser.add_argument("--tickers", type=int, default=0, help="exact number of ticking workspaces (overrides --tick-share)")
parser.add_argument("--scenarios", default="ticks,scroll,scroll_ticking,switch,drag,hitches",
                    help="which scenarios to run per size; add switch_matrix for the workspace switch matrix")
parser.add_argument("--switches", type=int, default=16, help="switch_matrix: switches per input and kind")
parser.add_argument("--no-trace", action="store_true")
parser.add_argument("--stop", action="store_true", help="quit the launched app at the end (jobs without $NX_APP_STOP)")
opts = parser.parse_args()
OUT = os.path.abspath(opts.out)
os.makedirs(os.path.join(OUT, "traces"), exist_ok=True)
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_idle import usage  # noqa: E402
from bench_launch import launch_app  # noqa: E402

SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"sbstress-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
FLAG = os.path.join(SCRATCH, "ticking")
DEBUG_CLI = os.path.join(HERE, "..", "cmux-debug-cli.sh")
APP_CLI = os.path.join(opts.app, "Contents/Resources/bin/cmux")
WINDOW = (40, 40, 1000, 900)
TICK_S = 0.25
results = {"tag": opts.tag, "app": opts.app, "host": os.uname().nodename, "window": WINDOW, "sizes": {}, "log": []}


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


def timed_rpc(method, params=None):
    t0 = time.perf_counter()
    reply = rpc(method, params)
    return (time.perf_counter() - t0) * 1000, reply


def cli(*args, quiet=True):
    """The tagged app's own CLI, routed through the app's socket (`--app-socket`, as perf-gate.py runs it): it
    reaches the app's own daemon session whatever this host's cmux environment holds."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    env["CMUX_NEXT_CONFIG_FILE"] = CONFIG
    done = subprocess.run([APP_CLI, "--app-socket", SOCKET, *args], env=env, capture_output=True, text=True, timeout=120,
                          stdin=subprocess.DEVNULL)
    if not quiet or done.returncode != 0:
        note(f"cli {' '.join(args)[:160]} -> {done.returncode} {(done.stdout + done.stderr).strip()[-200:]}")
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


def action(name, args=None, target=None, focus=False):
    params = {"action": name, "args": args or {}, "focus": focus, "origin": "script"}
    if target:
        params["target"] = target
    return rpc("action.run", params)


def sidebar():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return windows[0] if windows else {}


def workspace_rows():
    return [r for r in sidebar().get("rows") or [] if str(r.get("key", "")).startswith("workspace(")]


def topology():
    snap = rpc("snapshot.get") or {}
    return snap.get("topology") or snap


def percentiles(values):
    if not values:
        return {}
    s = sorted(values)
    pick = lambda p: s[min(len(s) - 1, int(round((len(s) - 1) * p)))]
    return {"n": len(s), "p50": round(pick(0.5), 3), "p95": round(pick(0.95), 3), "p99": round(pick(0.99), 3),
            "max": round(s[-1], 3), "mean": round(statistics.fmean(s), 3)}


def cpu_share(pid, seconds):
    before, t0 = usage(pid), time.monotonic()
    time.sleep(seconds)  # the measurement window itself
    after, wall = usage(pid), time.monotonic() - t0
    if not before or not after:
        return None
    return {"cpu_pct": round(100.0 * (after[0] - before[0]) / (wall * 1e9), 2), "wakeups_per_s": round((after[1] - before[1]) / wall, 1),
            "footprint_mb": round(after[2] / 1048576, 1)}


# ---------------------------------------------------------------- profiling
class Trace:
    """A Time Profiler (or other template) recording attached to the app for the `with` body."""

    def __init__(self, pid, name, seconds, template="Time Profiler"):
        self.path = os.path.join(OUT, "traces", f"{name}.trace")
        self.pid, self.seconds, self.template, self.proc = pid, seconds, template, None

    def __enter__(self):
        if opts.no_trace:
            return self
        if os.path.exists(self.path):
            shutil.rmtree(self.path)
        self.proc = subprocess.Popen(["xcrun", "xctrace", "record", "--template", self.template, "--attach", str(self.pid),
                                      "--time-limit", f"{self.seconds}s", "--output", self.path, "--no-prompt"],
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        time.sleep(4)  # the recorder attaches
        return self

    def __exit__(self, *exc):
        if self.proc:
            try:
                out, _ = self.proc.communicate(timeout=self.seconds + 180)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                out = "timeout"
            if self.proc.returncode != 0:
                note(f"xctrace {self.template} exit {self.proc.returncode}: {(out or '')[-300:]}")
        return False


SUSPECTS = {
    "SidebarBridge (all)": ["SidebarBridge"],
    "SidebarBridge.liveSections/sections": ["SidebarBridge.liveSections", "SidebarBridge.sections"],
    "SidebarMapping": ["SidebarMapping"],
    "StatusMapping": ["StatusMapping"],
    "SidebarSection ==": ["SidebarSection.==", "SidebarSection.__derived", "SidebarWorkspace.==", "SidebarWorkspace.__derived"],
    "SidebarLayout.make": ["SidebarLayout.make"],
    "SidebarListView.reload": ["SidebarListView.reload"],
    "SidebarListView.apply": ["SidebarListView.apply"],
    "RustSidebarClient / JSON FFI": ["RustSidebarClient", "cmux_layout_reducer_json"],
    "JSONEncoder/Decoder": ["JSONEncoder", "JSONDecoder"],
    "MachineRegistry.workspace(id:)": ["MachineRegistry.workspace"],
    "WindowProfiles": ["WindowProfiles"],
    "PersonalSidebar": ["PersonalSidebar."],
    "PersonalSidebarPlanner": ["PersonalSidebarPlanner"],
    "SidebarLayoutService (sidebar_layout.get)": ["SidebarLayoutService"],
    "SessionStateStore.apply/overlay": ["SessionStateStore"],
    "DaemonStore apply": ["DaemonStore.apply"],
    "Observation tracking": ["withObservationTracking", "ObservationRegistrar"],
    "SwiftUI / AttributeGraph": ["SwiftUI", "AttributeGraph", "AG::"],
    "CoreAnimation commit": ["CA::Transaction::commit"],
    "AppKit layout/display": ["-[NSView layout", "_layoutSubtreeIfNeeded", "displayIfNeeded", "-[NSView _layoutSubtree"],
    "WorkspaceRowView.configure": ["WorkspaceRowView.configure"],
    "SidebarRowViewPool": ["SidebarRowViewPool"],
}


def main_thread_profile(trace):
    """Main-thread sample counts by frame (inclusive and leaf) and the suspects' shares."""
    import xml.etree.ElementTree as ET
    if opts.no_trace or not os.path.exists(trace):
        return None
    toc = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--toc"], capture_output=True, text=True).stdout
    schema = "time-profile" if 'schema="time-profile"' in toc else "time-sample"
    xml = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                          f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'], capture_output=True, text=True).stdout
    try:
        root = ET.fromstring(xml)
    except ET.ParseError as error:
        return {"error": f"export: {error}", "bytes": len(xml)}
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

    inclusive, leaf, samples, all_samples = {}, {}, 0, 0
    for row in root.iter("row"):
        thread = backtrace = None
        for child in row:
            node = resolve(child)
            if child.tag == "thread":
                thread = node
            elif child.tag in ("backtrace", "tagged-backtrace"):
                backtrace = node
        all_samples += 1
        if thread is None or backtrace is None or "Main Thread" not in (thread.get("fmt") or ""):
            continue
        samples += 1
        bt = backtrace if backtrace.tag == "backtrace" else next(iter(backtrace.iter("backtrace")), backtrace)
        if bt is None:
            continue
        frames = [resolve(f).get("name") or "?" for f in bt.iter("frame")]
        if frames:
            leaf[frames[0]] = leaf.get(frames[0], 0) + 1
        for name in set(frames):
            inclusive[name] = inclusive.get(name, 0) + 1
    generic = ("main", "start", "NSApplicationMain", "-[NSApplication run]", "_DPSNextEvent", "CFRunLoopRun", "__CFRunLoop",
               "_CFRunLoopRun", "-[NSApplication(NSEvent) _nextEventMatchingEventMask", "_BlockUntilNextEventMatchingListInMode",
               "ReceiveNextEventCommon", "RunCurrentEventLoopInMode", "_dispatch_main_queue", "__CFRUNLOOP", "_dispatch_", "?",
               "_DPSBlockUntilNextEventMatchingListInMode", "-[NSApplication(NSEventRouting)", "withExtendedLifetime",
               "__debug_main_executable_dylib_entry_point", "partial apply for closure #1 in CmuxNextApp.main()",
               "closure #1 in CmuxNextApp.main()", "CmuxNextApp.main()")
    top = [{"frame": n[:200], "samples": c, "pct": round(100.0 * c / samples, 1) if samples else 0}
           for n, c in sorted(inclusive.items(), key=lambda kv: -kv[1]) if not n.startswith(generic) and "main" != n][:60]
    suspects = {}
    for label, needles in SUSPECTS.items():
        hit = {n for n in inclusive if any(k in n for k in needles)}
        # A sample can hold several matching frames: count the max frame as a lower bound.
        count = max((inclusive[n] for n in hit), default=0)
        suspects[label] = {"samples_max_frame": count, "pct": round(100.0 * count / samples, 1) if samples else 0,
                           "frames": sorted(hit, key=lambda n: -inclusive[n])[:4]}
    return {"main_samples": samples, "all_samples": all_samples, "schema": schema, "top_inclusive": top,
            "top_leaf": [{"frame": n[:200], "samples": c} for n, c in sorted(leaf.items(), key=lambda kv: -kv[1])[:30]],
            "suspects": suspects}


# ---------------------------------------------------------------- building the sidebar
made = {"workspaces": [], "tickers": [], "groups": [], "pinned": []}
LOOP = ("while :; do for p in 5 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95; do "
        f"[ -e '{FLAG}' ] && printf '\\033]7501;state=working:progress=%d\\033\\\\' $p; sleep {TICK_S}; done; done")


def create_plain(name):
    """A workspace with no terminal (`workspace create --empty`: no PTY)."""
    done = cli("workspace", "create", "--empty", "--name", name)
    return done.stdout.strip() or None


def create_ticker(name):
    done = cli("workspace", "create", "--name", name, "--shell", LOOP)
    return done.stdout.strip() or name


def grow(target):
    """Adds workspaces until the sidebar holds `target`, ~tick-share of them tickers, spread over groups."""
    have = len(made["workspaces"])
    want_tickers = opts.tickers or max(1, round(target * opts.tick_share))
    t0 = time.monotonic()
    for i in range(have, target):
        name = f"ws {i:04d}"
        if len(made["tickers"]) < want_tickers and (i % max(1, round(1 / opts.tick_share)) == 0 or target - i <= want_tickers - len(made["tickers"])):
            ref = create_ticker(name + " tick")
            made["tickers"].append(ref)
            name += " tick"
        else:
            ref = create_plain(name)
        made["workspaces"].append({"name": name, "ref": ref})
    note(f"created {target - have} workspaces in {time.monotonic() - t0:.1f} s")
    wait(lambda: len(workspace_rows()) >= target * 0.95 or None, 60, 1.0)
    rows = workspace_rows()
    note(f"sidebar workspace rows: {len(rows)} (target {target})")
    # Groups: the first 80% of the new workspaces go round-robin into --groups groups.
    t0 = time.monotonic()
    if not made["groups"]:
        for g in range(opts.groups):
            gname = f"group {g:02d}"
            cli("workspace", "group", "create", "--name", gname)
            made["groups"].append(gname)
    ids = {r.get("title"): r for r in rows}
    topo = {w.get("name") or w.get("title"): w.get("id") for w in topology().get("workspaces") or []}
    placed = 0
    for index, ws in enumerate(made["workspaces"][have:target]):
        if index % 5 == 4:
            continue  # loose
        ws_id = topo.get(ws["name"])
        if not ws_id:
            continue
        gname = made["groups"][index % len(made["groups"])]
        if cli("workspace", "group", gname, "add", "--workspace", ws_id).returncode == 0:
            placed += 1
    note(f"grouped {placed} workspaces in {time.monotonic() - t0:.1f} s")
    # Pins: a few, never more than 12.
    pins = min(12, max(3, target // 100))
    for ws in made["workspaces"][len(made["pinned"]):]:
        if len(made["pinned"]) >= pins:
            break
        ws_id = topo.get(ws["name"])
        if ws_id:
            action("palette.toggleWorkspacePin", target=f"workspace:{ws_id}")
            made["pinned"].append(ws_id)
    time.sleep(3)  # the sidebar settles


def close_scratch(why):
    """Closes this script's workspaces ("ws NNNN", from this or an earlier run of the tag) and resets the
    sidebar layout; it never touches a workspace with another name."""
    ticking(False)
    rpc("action.run", {"action": "sidebar.layout.reset", "args": {"confirm": True}, "origin": "script"})  # destructive: needs confirm
    closed = 0
    for w in topology().get("workspaces") or []:
        name = w.get("name") or w.get("title") or ""
        if name.startswith("ws ") and w.get("id") and cli("workspace", w["id"], "close").returncode == 0:
            closed += 1
    for gname in made["groups"] or [f"group {g:02d}" for g in range(opts.groups)]:
        cli("workspace", "group", gname, "delete")
    note(f"{why}: closed {closed} scratch workspaces")
    return closed


def ticking(on):
    if on:
        open(FLAG, "w").close()
    elif os.path.exists(FLAG):
        os.unlink(FLAG)


# ---------------------------------------------------------------- scenarios
def frames(action_name):
    return rpc("debug.frames", {"action": action_name})


def noop_ms(count=30):
    return percentiles([timed_rpc("debug.frames", {"action": "read"})[0] for _ in range(count)])


def list_point():
    rows = workspace_rows()
    if not rows:
        return 120, 400
    f = rows[0]["window_frame"]
    return f["x"] + f["width"] / 2, 450


def scroll_gesture(events=150, dy=-40.0):
    """One trackpad gesture of `events` scroll events at 60 Hz; per-event handling times."""
    x, y = list_point()
    times = []
    phases = ["began"] + ["changed"] * (events - 2) + ["ended"]
    for phase in phases:
        t0 = time.perf_counter()
        ms, reply = timed_rpc("debug.mouse", {"action": "scroll", "x": x, "y": y, "dy": dy, "phase": phase})
        times.append(ms)
        rest = 1 / 60 - (time.perf_counter() - t0)
        if rest > 0:
            time.sleep(rest)  # 60 events per second, as a trackpad sends them
    return times


def scroll_to_top():
    x, y = list_point()
    for _ in range(3):
        rpc("debug.mouse", {"action": "scroll", "x": x, "y": y, "dy": 100000, "phase": "began"})
        rpc("debug.mouse", {"action": "scroll", "x": x, "y": y, "dy": 0, "phase": "ended"})


def scenario_scroll(pid, size, label, trace=True):
    scroll_to_top()
    time.sleep(1)
    frames("start")
    handle = []
    tr = Trace(pid, f"{size}-{label}", 22) if trace else None
    if tr:
        tr.__enter__()
    t0 = time.monotonic()
    handle += scroll_gesture(300, -60.0)  # down
    handle += scroll_gesture(300, 60.0)   # back up
    wall = time.monotonic() - t0
    stats = frames("stop")
    if tr:
        tr.__exit__(None, None, None)
    return {"frames": stats, "event_rpc_ms": percentiles(handle), "events": len(handle), "wall_s": round(wall, 2),
            "trace": os.path.relpath(tr.path, OUT) if tr else None, "profile": main_thread_profile(tr.path) if tr else None}


def scenario_ticks(pid, size):
    ticking(False)
    time.sleep(2)
    idle = cpu_share(pid, 10)
    ticking(True)
    time.sleep(2)
    busy = cpu_share(pid, 10)
    frames("start")
    tr = Trace(pid, f"{size}-ticks", 12)
    tr.__enter__()
    t0 = time.monotonic()
    tr.__exit__(None, None, None)
    wall = time.monotonic() - t0
    stats = frames("stop")
    profile = main_thread_profile(tr.path)
    ticks = len(made["tickers"]) * (min(wall, 12) / TICK_S)
    per_tick = None
    if profile and profile.get("main_samples"):
        per_tick = round(profile["main_samples"] / ticks, 3) if ticks else None  # 1 ms per Time Profiler sample
    return {"tickers": len(made["tickers"]), "tick_hz_each": 1 / TICK_S, "idle": idle, "ticking": busy,
            "trace_window_s": 12, "ticks_in_trace": round(ticks), "main_ms_per_tick": per_tick,
            "main_ms_per_s": round(profile["main_samples"] / 12, 1) if profile and profile.get("main_samples") else None,
            "frames_while_ticking": stats, "trace": os.path.relpath(tr.path, OUT), "profile": profile}


def scenario_switch(pid, size, count=24):
    scroll_to_top()
    time.sleep(1)
    rows = [r for r in workspace_rows() if r["window_frame"]["y"] > 60 and r["window_frame"]["y"] + r["window_frame"]["height"] < WINDOW[3] - 80]
    if len(rows) < 2:
        return {"error": "fewer than two visible rows"}
    a, b = rows[2] if len(rows) > 2 else rows[0], rows[-2]
    lat = []
    frames("start")
    tr = Trace(pid, f"{size}-switch", 18)
    tr.__enter__()
    for i in range(count):
        row = (a, b)[i % 2]
        f = row["window_frame"]
        t0 = time.perf_counter()
        rpc("debug.mouse", {"action": "click", "x": f["x"] + 60, "y": f["y"] + f["height"] / 2})
        rpc("debug.frames", {"action": "read"})  # answered once the main thread has handled the click and its render
        lat.append((time.perf_counter() - t0) * 1000)
        time.sleep(0.35)
    stats = frames("stop")
    tr.__exit__(None, None, None)
    selected = [r.get("title") for r in workspace_rows() if r.get("selected")]
    return {"clicks": count, "click_to_idle_ms": percentiles(lat), "noop_rpc_ms": noop_ms(), "frames": stats,
            "selected_after": selected[:3], "trace": os.path.relpath(tr.path, OUT), "profile": main_thread_profile(tr.path)}

def switch_targets():
    """Two terminal and two Chromium workspaces at the top of the sidebar (Cmd-1..4), made once:
    positions 1-2 Chromium (a page each), 3-4 terminal (a shell each)."""
    if made.get("switch_targets"):
        return made["switch_targets"]
    refs = {}
    for name in ("sw term b", "sw term a"):
        refs[name] = cli("workspace", "create", "--name", name).stdout.strip() or name
    for index, name in enumerate(("sw chromium b", "sw chromium a")):
        refs[name] = cli("workspace", "create", "--name", name).stdout.strip() or name
        path = os.path.join(SCRATCH, f"switch-page-{index}.html")
        open(path, "w").write("<!doctype html><title>p</title><body style='font:14px system-ui'>" +
                              "".join(f"<p>row {i} <b>bold</b> <code>code</code></p>" for i in range(400)) + "</body>")
        action("goToWorkspace", {"workspace": refs[name]}, focus=True)
        time.sleep(0.5)
        reply = action("openBrowser.chromium", {"url": "file://" + path}, focus=True)
        if isinstance(reply, dict) and reply.get("error"):
            note(f"switch matrix: openBrowser.chromium: {reply['error']}")
        time.sleep(2)
    # Move to top in reverse so the order is chromium a, chromium b, term a, term b.
    for name in ("sw term b", "sw term a", "sw chromium b", "sw chromium a"):
        action("palette.moveWorkspaceToTop", target={"kind": "workspace", "id": refs[name]})
        time.sleep(0.3)
    made["switch_targets"] = refs
    time.sleep(2)
    return refs


def selected_title():
    return next((r.get("title") for r in workspace_rows() if r.get("selected")), None)


def scenario_switch_matrix(pid, size):
    """Workspace switch, input to the main thread idle after the switch drew, and the longest frame
    of the switch, per input (click on the row, Cmd-1..4, Ctrl-Cmd-] / [) and per kind (terminal,
    Chromium page) while the tickers tick. Old builds answer every call it makes."""
    refs = switch_targets()
    scroll_to_top()
    time.sleep(1)
    ticking(True)
    time.sleep(2)
    out = {"tickers": len(made["tickers"])}
    rows = {r.get("title"): r for r in workspace_rows()}
    order = [r.get("title") for r in workspace_rows()[:4]]
    out["top_rows"] = order
    pairs = {"chromium": ("sw chromium a", "sw chromium b", 1), "terminal": ("sw term a", "sw term b", 3)}
    probe = rpc("debug.workspace_switch", {"action": "stop"})  # an older build answers with an error
    timed = isinstance(probe, dict) and "recording" in probe
    out["app_timer"] = timed
    tr = Trace(pid, f"{size}-switch-matrix", 4 + 3 * 2 * opts.switches * 0.45 + 10)
    tr.__enter__()
    for kind, (a, b, first) in pairs.items():
        for how in ("click", "cmd_digit", "next_prev"):
            lat, longest, wrong = [], [], 0
            action("goToWorkspace", {"workspace": refs[a]}, focus=True)
            time.sleep(0.6)
            if timed:
                rpc("debug.workspace_switch", {"action": "start"})
            for i in range(opts.switches):
                to_b = i % 2 == 0
                target = b if to_b else a
                if how == "click":
                    f = (rows.get(target) or {}).get("window_frame")
                    if not f:
                        break
                    send = lambda: rpc("debug.mouse", {"action": "click", "x": f["x"] + 60, "y": f["y"] + f["height"] / 2})  # noqa: E731
                elif how == "cmd_digit":
                    digit = str(first + (1 if to_b else 0))
                    send = lambda: rpc("debug.key", {"key": digit, "modifiers": ["command"]})  # noqa: E731
                else:
                    key = "]" if to_b else "["
                    send = lambda: rpc("debug.key", {"key": key, "modifiers": ["control", "command"]})  # noqa: E731
                frames("start")
                t0 = time.perf_counter()
                send()
                rpc("debug.frames", {"action": "read"})  # answered once the main thread handled the input and its render
                lat.append((time.perf_counter() - t0) * 1000)
                time.sleep(0.25)
                stats = frames("stop") or {}
                if isinstance(stats.get("max_ms"), (int, float)):
                    longest.append(stats["max_ms"])
                if i % 4 == 3 and selected_title() != target:
                    wrong += 1
                time.sleep(0.2)
            entry = {"switches": len(lat), "input_to_idle_ms": percentiles(lat),
                     "longest_frame_ms": percentiles(longest), "wrong_selection_checks": wrong}
            if timed:
                samples = (rpc("debug.workspace_switch", {"action": "stop"}) or {}).get("switches") or []
                entry["app_samples"] = samples
                commit = [x["commit_ms"] + x.get("input_ms", 0) for x in samples if isinstance(x.get("commit_ms"), (int, float))]
                entry["input_to_commit_ms"] = percentiles(commit)
                for stage in ("input", "park", "content", "sidebar", "root", "theme", "did_show", "apply", "commit"):
                    vals = [x[stage + "_ms"] for x in samples if isinstance(x.get(stage + "_ms"), (int, float))]
                    if vals:
                        entry.setdefault("stages_ms", {})[stage] = percentiles(vals)
            out[f"{kind}.{how}"] = entry
            note(f"switch matrix {kind} {how}: {out[f'{kind}.{how}']['input_to_idle_ms']}")
    tr.__exit__(None, None, None)
    ticking(False)
    out["trace"] = os.path.relpath(tr.path, OUT)
    out["profile"] = main_thread_profile(tr.path)
    return out


def scenario_drag(pid, size, moves=180):
    scroll_to_top()
    time.sleep(1)
    rows = [r for r in workspace_rows() if r["window_frame"]["y"] > 80 and r["window_frame"]["y"] < WINDOW[3] - 120]
    if len(rows) < 4:
        return {"error": "fewer than four visible rows"}
    src = rows[1]["window_frame"]
    x, y = src["x"] + 60, src["y"] + src["height"] / 2
    top, bottom = rows[0]["window_frame"]["y"] + 4, rows[-1]["window_frame"]["y"] + rows[-1]["window_frame"]["height"] - 4
    frames("start")
    tr = Trace(pid, f"{size}-drag", 16)
    tr.__enter__()
    # One batch first: the press and 12 dragged events past the drag threshold (as sidebar-reorder-e2e.py
    # holds a drag); a lone posted press followed by later moves does not start the sidebar's drag.
    cur = y + 30
    rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": cur, "steps": 12, "release": False})
    times, dragging = [], None
    step = (bottom - top) / (moves / 2)
    for i in range(moves):
        nxt = cur + (step if i < moves / 2 else -step)
        t0 = time.perf_counter()
        ms, _ = timed_rpc("debug.mouse", {"action": "drag", "x": x, "y": cur, "to_x": x + 2, "to_y": nxt, "steps": 1, "press": False, "release": False})
        times.append(ms)
        cur = nxt
        if i == 10:
            dragging = sidebar().get("dragging")
        rest = 1 / 60 - (time.perf_counter() - t0)
        if rest > 0:
            time.sleep(rest)  # 60 mouse-moves per second
    rpc("debug.mouse", {"action": "up", "x": x, "y": cur})
    stats = frames("stop")
    tr.__exit__(None, None, None)
    profile = main_thread_profile(tr.path)
    per_move = round(profile["main_samples"] / moves, 3) if profile and profile.get("main_samples") else None
    time.sleep(1)
    action("undo")  # a drop may have moved the row; put it back
    return {"moves": moves, "drag_engaged": dragging, "post_rpc_ms": percentiles(times), "main_ms_per_move_upper_bound": per_move,
            "frames": stats, "trace": os.path.relpath(tr.path, OUT), "profile": profile}


def scenario_hitches(pid, size):
    """The scroll again under the Animation Hitches template (frame-level hitch detection)."""
    scroll_to_top()
    tr = Trace(pid, f"{size}-scroll-hitches", 10, template="Animation Hitches")  # about 90 MB per second of trace
    tr.__enter__()
    frames("start")
    scroll_gesture(300, -60.0)
    stats = frames("stop")
    tr.__exit__(None, None, None)
    toc = ""
    if os.path.exists(tr.path):
        toc = subprocess.run(["xcrun", "xctrace", "export", "--input", tr.path, "--toc"], capture_output=True, text=True).stdout
    tables = sorted(set(part.split('"')[0] for part in toc.split('schema="')[1:]))
    hitches = None
    if "hitches" in tables:
        import xml.etree.ElementTree as ET
        xml = subprocess.run(["xcrun", "xctrace", "export", "--input", tr.path, "--xpath",
                              '/trace-toc/run[@number="1"]/data/table[@schema="hitches"]'], capture_output=True, text=True).stdout
        ids, durations, ours = {}, [], 0
        try:
            for row in ET.fromstring(xml).iter("row"):
                cells = []
                for cell in row:
                    if cell.get("id"):
                        ids[cell.get("id")] = cell
                    cells.append(ids.get(cell.get("ref"), cell) if cell.get("ref") else cell)
                duration = next((c for c in cells if c.tag == "duration"), None)
                process = next((c for c in cells if c.tag == "process"), None)
                if process is not None and str(pid) in (process.get("fmt") or ""):
                    ours += 1
                    if duration is not None and (duration.text or "").isdigit():
                        durations.append(int(duration.text) / 1e6)
            hitches = {"rows_for_app": ours, "duration_ms": percentiles(durations), "total_ms": round(sum(durations), 1)}
        except ET.ParseError as error:
            hitches = {"error": str(error)}
    return {"frames": stats, "trace": os.path.relpath(tr.path, OUT), "hitches": hitches}


def main():
    global SOCKET
    sizes = [int(s) for s in opts.sizes.split(",")]
    with open(CONFIG, "w") as f:
        json.dump({"appearance": {"theme": "Catppuccin Mocha"}}, f)
    open(GHOSTTY, "w").write("")
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY, "CMUX_NEXT_CHIEF_ISOLATED": "1",
           "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"), "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(map(str, WINDOW))}
    results["load_at_start"] = os.getloadavg()
    # One launch path (bench_launch.py): socket in the state folder, bench env, the reason when it does not come up.
    app, SOCKET = launch_app(opts.app, env, os.path.join(OUT, "app.log"), timeout=180)
    note(f"launched pid {app.pid}")
    try:
        # A fresh profile may open on Home with no workspace yet: make one, so the list has a row to measure.
        if not wait(workspace_rows, 15):
            cli("workspace", "create", "--name", "bench start")
            if not wait(workspace_rows, 60):
                sys.exit(f"the sidebar lists no workspace row: {json.dumps(sidebar())[:600]}")
        time.sleep(3)
        results["stale_closed"] = close_scratch("before")
        time.sleep(2)
        results["baseline"] = {"rows": len(workspace_rows()), "cpu": cpu_share(app.pid, 5), "noop_rpc_ms": noop_ms()}
        for size in sizes:
            note(f"== size {size} (load {os.getloadavg()})")
            grow(size)
            listed = len(topology().get("workspaces") or [])
            note(f"workspaces in the app: {listed}")
            if listed < size * 0.9:
                sys.exit(f"the app holds {listed} workspaces, not {size}: the bench cannot measure this size")
            action("showMainWindow")
            rpc("debug.mouse", {"x": 900, "y": 450, "action": "hover"})
            time.sleep(2)
            entry = {"rows_listed": len(workspace_rows()), "load": os.getloadavg(), "noop_rpc_ms": noop_ms()}
            entry["memory"] = cpu_share(app.pid, 3)
            want = set(opts.scenarios.split(","))
            if "ticks" in want:
                entry["ticks"] = scenario_ticks(app.pid, size)
            ticking(False)
            time.sleep(1)
            if "scroll" in want:
                entry["scroll"] = scenario_scroll(app.pid, size, "scroll")
            if "scroll_ticking" in want:
                ticking(True)
                entry["scroll_while_ticking"] = scenario_scroll(app.pid, size, "scroll-ticking", trace=False)
                ticking(False)
            if "switch" in want:
                entry["switch"] = scenario_switch(app.pid, size)
            if "switch_matrix" in want:
                entry["switch_matrix"] = scenario_switch_matrix(app.pid, size)
            if "drag" in want:
                entry["drag"] = scenario_drag(app.pid, size)
            if "hitches" in want:
                entry["hitches"] = scenario_hitches(app.pid, size)
            entry["hangs"] = rpc("debug.hangs", {})
            results["sizes"][str(size)] = entry
            with open(os.path.join(OUT, "results.json"), "w") as f:
                json.dump(results, f, indent=1, default=str)
            note(f"size {size}: done")
        # A second window: does a status tick cost scale with windows?
        if not opts.no_trace:
            action("newWindow")
            time.sleep(3)
            ticking(True)
            tr = Trace(app.pid, f"{sizes[-1]}-ticks-2windows", 12)
            tr.__enter__()
            tr.__exit__(None, None, None)
            prof = main_thread_profile(tr.path)
            ticks = len(made["tickers"]) * 12 / TICK_S
            results["two_windows_ticks"] = {"main_ms_per_tick": round(prof["main_samples"] / ticks, 3) if prof and prof.get("main_samples") else None,
                                            "cpu": cpu_share(app.pid, 10), "trace": os.path.relpath(tr.path, OUT), "profile": prof}
            ticking(False)
        results["cleanup_closed"] = close_scratch("after")
    finally:
        ticking(False)
        results["made"] = {k: len(v) for k, v in made.items()}
        with open(os.path.join(OUT, "results.json"), "w") as f:
            json.dump(results, f, indent=1, default=str)
        if opts.stop:
            reply = rpc("action.run", {"action": "quitEndSessions", "origin": "script"})
            note(f"quitEndSessions -> {json.dumps(reply)[:160]}")
            try:
                app.wait(timeout=30)
            except subprocess.TimeoutExpired:
                app.terminate()


main()

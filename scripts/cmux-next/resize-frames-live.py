#!/usr/bin/env python3
"""Live-resize frame-time bench on the GUI host (Leo, cosmic-gray 2026-10-13).

  resize-frames-live.py --tag <tag> --out DIR [--steps 150] [--sample]

Launches the tagged app (no activation, automation socket, own config), opens a
layout with the sidebar, a terminal and a New Tab page (a web view) side by
side, then live-resizes the window: the bottom-right corner pressed and dragged
one `debug.mouse` event per 120 Hz frame (`--steps` events per drag), out by
300 x 150 points and back, twice. AppKit's own resize tracking reads the events
(`inLiveResize` holds) and the user's pointer never moves. `debug.frames`
records display-link intervals throughout. Reports frame intervals (p50, p95,
p99, max, missed vsyncs) and each event's round trip, which waits for the main
thread; `--sample` also runs `sample` on the app (sample.txt). Kills only the
app it started.
"""
import argparse, glob, json, os, plistlib, signal, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--steps", type=int, default=150)
parser.add_argument("--sample", action="store_true")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = next(iter(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV*.app"))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
START = [80, 80, 1100, 720]


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def pct(values, p):
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * p)))], 2) if ordered else None


def focused_pane():
    windows = (rpc("debug.focus") or {}).get("windows") or [{}]
    return windows[0].get("layout_focused_pane")


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config,
       "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(map(str, START))}
log = open(os.path.join(opts.out, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
report = {"tag": opts.tag, "pid": app.pid}
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 120):
        sys.exit("app did not come up")
    time.sleep(2)
    report["identify"] = rpc("system.identify")
    # Sidebar shown, a terminal workspace, and a New Tab page (a web view) split beside it.
    report["setup"] = [rpc("action.run", {"action": "newTab", "focus": True})]
    time.sleep(2)
    pane = focused_pane()
    report["setup"].append(rpc("action.run", {"action": "splitRight", "focus": True, "target": f"pane:{pane}" if pane else None}))
    time.sleep(1.5)
    pane = focused_pane()
    report["setup"].append(rpc("action.run", {"action": "newTab.page", "focus": True, "target": f"pane:{pane}" if pane else None}))
    time.sleep(4)

    sampler = None
    if opts.sample:
        sampler = subprocess.Popen(["/usr/bin/sample", str(app.pid), "8", "1",
                                    "-file", os.path.join(opts.out, "sample.txt")],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.5)
    def size():
        layers = ((rpc("debug.layers") or {}).get("windows") or [{}])[0]
        return layers.get("frame")

    rpc("debug.frames", {"action": "start"})
    # A live resize at the pace of a real drag: the bottom-right corner pressed once, then one
    # `debug.mouse` drag event per 120 Hz frame (press and release held open), out by 300 x 150
    # points and back, twice. AppKit's own resize tracking reads them (inLiveResize); the top-left
    # corner stays put, so window-local points from the top-left are the pointer's screen offsets.
    rounds, latencies, period = [], [], 1 / 120
    for out in (True, False, True, False):
        before = size()
        w, h = before[2], before[3]
        dx, dy = (300, 150) if out else (-300, -150)
        x0, y0 = w - 1, h - 1
        rpc("debug.mouse", {"action": "down", "x": x0, "y": y0})
        started = time.monotonic()
        for step in range(1, opts.steps + 1):
            t = step / opts.steps
            x, y = x0 + dx * t, y0 + dy * t
            t0 = time.monotonic()
            rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1, "press": False, "release": False})
            latencies.append((time.monotonic() - t0) * 1000)
            next_at = started + step * period
            if next_at > time.monotonic():
                time.sleep(next_at - time.monotonic())
        rpc("debug.mouse", {"action": "up", "x": x0 + dx, "y": y0 + dy})
        time.sleep(0.5)
        rounds.append({"before": before, "after": size(), "wall_s": round(time.monotonic() - started, 2)})
    report["frames"] = rpc("debug.frames", {"action": "stop"})
    if sampler:
        sampler.wait(60)
    resized = all(r["before"] and r["after"] and r["before"][2] != r["after"][2] for r in rounds)
    report["steps"] = {"rounds": rounds, "resized": resized, "events": len(latencies),
                       "event_rpc_ms": {"p50": pct(latencies, 0.5), "p95": pct(latencies, 0.95), "p99": pct(latencies, 0.99),
                                        "max": round(max(latencies), 2)}}
    print(json.dumps({"steps": report["steps"], "frames": report["frames"]}, indent=1), flush=True)
finally:
    app.send_signal(signal.SIGTERM)
    try:
        app.wait(15)
    except subprocess.TimeoutExpired:
        app.kill()
with open(os.path.join(opts.out, "report.json"), "w") as f:
    json.dump(report, f, indent=1)

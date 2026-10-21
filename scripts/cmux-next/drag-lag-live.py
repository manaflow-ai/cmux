#!/usr/bin/env python3
"""Drag lag on a fleet-built app: column edge, tab and sidebar row drags at a fast hand pace.

  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA \
    -- python3 scripts/cmux-next/drag-lag-live.py --out "$NX_ARTIFACTS"

Lawrence 2026-10-18: "I just saw an error about moving panes around... when I was dragging stuff
around, it was insanely laggy." Each drag sends one `debug.mouse` move per 1/120 s. `debug.mouse`
runs on the main actor and dispatches the event before it replies, so each reply's time is that
move's main-thread work plus any main-thread backlog. After the column drag, one daemon round-trip
(`list-workspaces` through the app socket) shows how far the daemon fell behind. The app's own
log is read for `timed out` errors. Prints one JSON summary; writes it to OUT/drag-lag.json.
"""
import argparse, json, os, socket, statistics, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--moves", type=int, default=120)
opts = parser.parse_args()
APP = os.environ.get("NX_APP")
TAG = os.environ.get("NX_APP_TAG", "")
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.environ.get("NX_APP_CLI") or (APP and os.path.join(APP, "Contents/Resources/bin/cmux"))
STOP = os.environ.get("NX_APP_STOP")
if not APP:
    sys.exit("run inside `nx-remote --needs gui --app-from-fleet cmux` (NX_APP)")
SCRATCH = tempfile.mkdtemp(prefix=f"drag-lag-{TAG}-")
CONFIG, GHOSTTY = os.path.join(SCRATCH, "cmux.json"), os.path.join(SCRATCH, "ghostty")
open(GHOSTTY, "w").write("")
open(CONFIG, "w").write("{}")
os.makedirs(opts.out, exist_ok=True)
SUMMARY = {"tag": TAG}


def rpc(method, params=None, timeout=30):
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
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def env():
    return {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "CMUX_QUIET": "1"}


def cli(*args):
    out = subprocess.run([CLI, "--app-socket", SOCKET, *args], capture_output=True, text=True, timeout=60, env=env())
    return (out.stdout + out.stderr).strip()


def daemon_round_trip():
    """One daemon command through the app socket (the bundled cmux-tui's `raw operation`): its wall time in ms."""
    tui = os.path.join(os.path.dirname(CLI), "cmux-tui")
    started = time.monotonic()
    out = subprocess.run([tui, "--app-socket", SOCKET, "--json", "raw", "operation", "workspace.list",
                          "--params-json", '{"machine":"current","session":"current"}'],
                         capture_output=True, text=True, timeout=60, env=env())
    result = {"ms": round((time.monotonic() - started) * 1000, 1), "ok": out.returncode == 0}
    if out.returncode != 0:
        result["error"] = (out.stdout + out.stderr)[:200]
    return result


class DaemonProbe:
    """Daemon round-trips every 150 ms on a thread while a drag runs (and for `tail` seconds after)."""

    def __init__(self):
        self.samples, self.stop = [], threading.Event()
        self.thread = threading.Thread(target=self.loop, daemon=True)

    def loop(self):
        while not self.stop.is_set():
            self.samples.append(daemon_round_trip())
            self.stop.wait(0.15)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join(70)

    def summary(self):
        ok = [s["ms"] for s in self.samples if s["ok"]]
        failed = [s for s in self.samples if not s["ok"]]
        result = {"probes": len(self.samples), "failed": len(failed), **{k: v for k, v in stats(ok).items() if k != "n"}}
        if failed:
            result["first_error"] = failed[0].get("error")
        return result


def wait(predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)  # test harness polling a live app
    return None


def action(name, **params):
    return rpc("action.run", {"action": name, **params})


def stats(samples):
    if not samples:
        return {"n": 0}
    ordered = sorted(samples)
    pick = lambda q: ordered[min(len(ordered) - 1, int(q * len(ordered)))]
    return {"n": len(samples), "p50_ms": round(statistics.median(samples), 2), "p95_ms": round(pick(0.95), 2),
            "max_ms": round(ordered[-1], 2), "over_16ms": sum(1 for s in samples if s > 16.7)}


def paced_drag(x, y, to_x, to_y, moves):
    """A held drag: one `debug.mouse` move per 1/120 s (a fast hand), timing each reply."""
    mouse = lambda **p: rpc("debug.mouse", p)
    if "error" in (mouse(action="drag", x=x, y=y, to_x=x, to_y=y, steps=1, release=False) or {}):
        return {"error": "could not press"}
    last, times = (x, y), []
    try:
        for move in range(1, moves + 1):
            point = (x + (to_x - x) * move / moves, y + (to_y - y) * move / moves)
            started = time.monotonic()
            mouse(action="drag", x=last[0], y=last[1], to_x=point[0], to_y=point[1], steps=1, press=False, release=False)
            times.append((time.monotonic() - started) * 1000)
            last = point
            time.sleep(max(0, 1 / 120 - times[-1] / 1000))  # test harness: pointer pace
    finally:
        mouse(action="drag", x=last[0], y=last[1], to_x=last[0], to_y=last[1], steps=1, press=False, release=True)
    return stats(times)


def launch():
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    pairs = ["CMUX_NEXT_NO_ACTIVATE=1", "CMUX_NEXT_SOCKET_MODE=automation", "CMUX_NEXT_TEST_WINDOW_SCREEN=last",
             f"CMUX_NEXT_CONFIG_FILE={CONFIG}", f"CMUX_NEXT_GHOSTTY_CONFIG={GHOSTTY}", "CMUX_NEXT_TEST_WINDOW_FRAME=40,40,1280,760",
             "ACPMUX_AGENT_LAUNCH=deny", "NX_REMOTE=1"]
    subprocess.run(["open", "-n", APP, *[arg for pair in pairs for arg in ("--env", pair)]], check=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 120):
        sys.exit("FAIL the app did not come up")
    time.sleep(2)  # test harness: let the window settle


def column_edges():
    windows = (rpc("debug.layers") or {}).get("windows") or [{}]
    layer = windows[0]
    height = (layer.get("frame") or [0, 0, 0, 720])[3]
    return sorted((x + w / 2, height - (y + h / 2)) for x, y, w, h in layer.get("divider_areas_in_window") or [] if h > w)


def strips():
    return (rpc("debug.tab_drag") or {}).get("strips") or []


def sidebar_rows():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or [{}]
    return [r for r in windows[0].get("rows") or [] if str(r.get("key", "")).startswith("workspace(") and r.get("window_frame")]


def center(frame):
    if isinstance(frame, dict):
        return frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2
    x, y, w, h = frame
    return x + w / 2, y + h / 2


def app_errors(since):
    pid = subprocess.run(["pgrep", "-n", "-f", f"{os.path.basename(APP)}/Contents/MacOS"], capture_output=True, text=True).stdout.strip()
    if not pid:
        return {}
    out = subprocess.run(["log", "show", "--start", since, "--style", "compact", "--predicate", f"processID == {pid} AND messageType >= 16"],
                         capture_output=True, text=True, timeout=120).stdout
    lines = [line for line in out.splitlines() if "timed out" in line]
    return {"timed_out": len(lines), "set_viewport_pane_width_timed_out": sum("set-viewport-pane-width" in l for l in lines),
            "sample": lines[-3:]}


launch()
since = time.strftime("%Y-%m-%d %H:%M:%S")
try:
    for index in range(30):
        cli("workspace", "create", "--name", f"Workspace {index:02d}")
    action("newTab", focus=True)
    time.sleep(2)
    for _ in range(4):
        action("newColumn", focus=True)
        time.sleep(1.5)
    action("splitRight", focus=True)
    time.sleep(1.5)
    action("newSurface", focus=True)
    time.sleep(2)
    SUMMARY["daemon_idle"] = daemon_round_trip()

    edges = wait(column_edges, 20)
    if edges:
        x, y = edges[0]
        with DaemonProbe() as probe:
            SUMMARY["column_drag"] = paced_drag(x, y, x + 240, y, opts.moves)
            SUMMARY["column_drag_back"] = paced_drag(x + 240, y, x, y, opts.moves)
            time.sleep(3)
        SUMMARY["daemon_during_and_3s_after_column_drags"] = probe.summary()
    else:
        SUMMARY["column_drag"] = {"error": "no column edge"}

    two = next((s for s in strips() if len(s.get("tabs") or []) >= 2), None)
    others = [s for s in strips() if s is not two]
    if two and others:
        tab = (two.get("tabs") or [])[-1]
        frame = tab.get("frame") or tab.get("window_frame")
        target = others[0].get("frame") or others[0].get("window_frame")
        if frame and target:
            sx, sy = center(frame)
            tx, ty = center(target)
            with DaemonProbe() as probe:
                SUMMARY["tab_drag"] = paced_drag(sx, sy, tx, ty + 200, opts.moves)
                time.sleep(2)
            SUMMARY["daemon_during_tab_drag"] = probe.summary()
    SUMMARY.setdefault("tab_drag", {"error": f"no two-tab strip: {json.dumps(strips())[:400]}"})

    rows = sidebar_rows()
    if len(rows) >= 8:
        frame = rows[1].get("window_frame")
        far = rows[-1].get("window_frame")
        if frame and far:
            sx, sy = center(frame)
            _, ty = center(far)
            with DaemonProbe() as probe:
                SUMMARY["sidebar_drag"] = paced_drag(sx, sy, sx, ty, opts.moves)
                time.sleep(2)
            SUMMARY["daemon_during_sidebar_drag"] = probe.summary()
    SUMMARY.setdefault("sidebar_drag", {"error": f"rows={len(rows)}"})
    time.sleep(2)
    SUMMARY["app_errors"] = app_errors(since)
finally:
    if STOP:
        subprocess.run([STOP])
with open(os.path.join(opts.out, "drag-lag.json"), "w") as f:
    json.dump(SUMMARY, f, indent=1)
print(json.dumps(SUMMARY, indent=1))

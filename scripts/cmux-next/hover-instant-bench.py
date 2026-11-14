#!/usr/bin/env python3
"""Sidebar row hover card: how long from the pointer's arrival on a row to the card (goal sidebar-hover-instant,
Leo 2026-11-01: "i need these hover previews to appear a hell of a lot faster than they do now").

  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \\
    --ref <sha> --artifact artifacts/split-spring/report.json --arg=--config=bench --arg=--suite=hover-instant

Launches the tagged app (a bench build: `debug.hover_cards` is registered only with CMUX_BENCH_HOOKS or in Debug),
fills the sidebar to each --workspaces count, and for --samples rows per count moves the real pointer onto the row
and reads `debug.hover_cards` until the row's card shows. The real pointer moves by the first route that works:
mouse moves this step posts itself (pointer-probe.swift; needs an Accessibility grant for this process, which a
binary compiled per run never has), then CuaDriver's `move_cursor` (desktop scope, foreground delivery) through its
daemon, which holds the host's Accessibility grant. Each route is checked by reading the pointer back. Only when
neither moves it does the bench say why for each and move a synthetic pointer through the windows' tracking areas
instead (`debug.pointer_hover`); the report's `input` and `pointer_route` say which ran. Per sample: the last move
to pending and to shown (ms); on a miss (no card in 2 s) the coordinator's whole report. Writes --json.
"""
import argparse, json, os, plistlib, queue, socket, statistics, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import LaunchError, launch_app  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402
from safe_log import safe_print  # noqa: E402  (a line in a cleanup path never skips the kill)

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", default=None)
parser.add_argument("--json", default=None)
parser.add_argument("--workspaces", default="10,200")
parser.add_argument("--samples", type=int, default=10)
parser.add_argument("--input", choices=("real", "synthetic"), default="real")
opts, _ = parser.parse_known_args()
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = opts.out or tempfile.mkdtemp(prefix="hover-instant-")
os.makedirs(OUT, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
REPORT = {"suite": "hover-instant", "cells": [], "input": opts.input, "notes": []}


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


def wait(check, seconds, step=0.05):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait on the app's state
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def cards():
    reply = rpc("debug.hover_cards", timeout=5)
    return reply if isinstance(reply, dict) else {}


def main_window():
    for entry in (rpc("debug.window_list") or {}).get("windows") or []:
        if entry.get("kind") == "main" and entry.get("visible"):
            return entry
    return None


def workspace_count():
    snap = rpc("snapshot.get", timeout=60)
    return len(((snap.get("topology") or {}) if isinstance(snap, dict) else {}).get("workspaces") or [])


def rows():
    """The visible workspace rows: (key, window point at the row's middle, window frame)."""
    found = []
    for row in ((rpc("debug.sidebar_rows") or {}).get("windows") or [{}])[0].get("rows") or []:
        if not str(row.get("key", "")).startswith("workspace") or not row.get("in_list"):
            continue
        f = row["window_frame"]
        f = [f["x"], f["y"], f["width"], f["height"]] if isinstance(f, dict) else list(f)
        found.append((row["key"], [f[0] + f[2] / 2, f[1] + f[3] / 2], f))
    return found


# --- pointer ------------------------------------------------------------------------------------
PROBE = os.path.join(tempfile.mkdtemp(prefix="pointer-probe-"), "pointer-probe")
SCREEN_H = 0.0


def probe(*args, timeout=20):
    return subprocess.run([PROBE, *map(str, args)], capture_output=True, text=True, timeout=timeout).stdout.strip()


def to_screen(point):
    """A window point from the top left to a screen point from the top left."""
    f = (main_window() or {}).get("frame") or {}
    return (f.get("x", 0) + point[0], SCREEN_H - (f.get("y", 0) + f.get("height", 0)) + point[1])


def where():
    try:
        return tuple(map(float, probe("where").split()))
    except ValueError:
        return None


LAST_POINT = {}
ROUTE = None  # the real pointer route that moved the pointer: "posted" (pointer-probe) or "cua" (CuaDriver)
CUA_CANDIDATES = (os.path.expanduser("~/.local/bin/cua-driver"),
                  "/Applications/CuaDriver.app/Contents/MacOS/cua-driver")
CUA_PATH = next((p for p in CUA_CANDIDATES if os.access(p, os.X_OK)), None)


class Cua:
    """One `cua-driver mcp` stdio session to the CuaDriver daemon, which holds the host's Accessibility grant: a
    move is one JSON line each way, not a process per move (gui-session-sweep.py's route)."""

    def __init__(self, path):
        self.p = subprocess.Popen([path, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True)
        self.lines = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()
        self.n = 0
        try:
            self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "hover-instant-bench", "version": "1"}})
            self.rpc("notifications/initialized", notify=True)
        except (OSError, RuntimeError):
            self.close()
            raise

    def read(self):
        for line in self.p.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def rpc(self, method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            self.n += 1
            msg["id"] = self.n
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()
        if notify:
            return None
        while True:  # bounded: 60 s per answer, and an ended driver closes stdout
            try:
                line = self.lines.get(timeout=60)
            except queue.Empty:
                raise RuntimeError(f"cua-driver mcp: no answer to {method} in 60 s") from None
            if not line:
                raise RuntimeError("cua-driver mcp ended")
            try:
                reply = json.loads(line)
            except ValueError:
                continue
            if reply.get("id") == self.n:
                return reply

    def call(self, tool, args):
        """The tool's answer (structuredContent when there is one); RuntimeError when it failed or refused."""
        reply = self.rpc("tools/call", {"name": tool, "arguments": args})
        result = reply.get("result") or {}
        inner = result.get("structuredContent") if isinstance(result.get("structuredContent"), dict) else {}
        if (reply.get("error") or not result or result.get("isError")
                or "refused" in (inner.get("status"), inner.get("effect"))):
            text = " ".join(c.get("text", "") for c in result.get("content") or [] if isinstance(c, dict))
            raise RuntimeError(f"cua-driver {tool}: {(reply.get('error') or text or result)!s}"[-300:])
        return inner or result

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            self.p.kill()  # the exact PID this script started
            self.p.wait()


CUA = None
CUA_SCALE = 1.0


def cua_move(x, y):
    """The real pointer to screen point (x, y) (top left) through CuaDriver: desktop scope takes the main display's
    screenshot pixels; foreground delivery because the bench app is never in front on a fleet step and nobody
    uses a bench host's screen."""
    CUA.call("move_cursor", {"scope": "desktop", "delivery_mode": "foreground",
                             "x": round(x * CUA_SCALE), "y": round(y * CUA_SCALE)})


def move_path(start, end, steps):
    """Moves from `start` to `end` (window points), `steps` moves about 120 Hz apart; returns the monotonic time
    the last move landed."""
    if opts.input == "synthetic":
        height = ((main_window() or {}).get("frame") or {}).get("height", 0)
        for i in range(1, steps + 1):
            x = start[0] + (end[0] - start[0]) * i / steps
            y = start[1] + (end[1] - start[1]) * i / steps
            LAST_POINT.update(window_top_left=[x, y], sent=[x, height - y], height=height,
                              reply=rpc("debug.pointer_hover", {"point": [x, height - y]}))
        return time.monotonic()
    (x0, y0), (x1, y1) = to_screen(start), to_screen(end)
    if ROUTE == "cua":
        for i in range(1, steps + 1):
            if i > 1:
                time.sleep(0.008)  # test harness: a mouse reports about every 8 ms
            try:
                cua_move(x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps)
            except (OSError, RuntimeError) as error:  # one refused move ends no run; the sample shows a miss
                if len(REPORT["notes"]) < 20:
                    REPORT["notes"].append(f"move failed: {error}")
        return time.monotonic()
    probe("path", x0, y0, x1, y1, steps)
    return time.monotonic()


def landed(target):
    at = where()
    return at, bool(at and abs(at[0] - target[0]) < 2 and abs(at[1] - target[1]) < 2)


def real_input_works():
    """Picks the first real pointer route that moves the pointer (read back with pointer-probe where, which needs
    no grant) and returns None; else why each route failed."""
    global ROUTE, CUA, CUA_SCALE
    f = (main_window() or {}).get("frame") or {}
    target = to_screen([f.get("width", 800) * 0.6, f.get("height", 600) * 0.5])
    run = subprocess.run([PROBE, "move", str(target[0]), str(target[1])], capture_output=True, text=True, timeout=20)
    at, ok = landed(target)
    if ok:
        ROUTE = "posted"
        return None
    why = [f"pointer-probe move {target[0]:.0f} {target[1]:.0f}: exit {run.returncode}, "
           f"stderr {run.stderr.strip()[-300:]!r}, pointer after {at}"]
    if not CUA_PATH:
        return "; ".join(why + [f"no cua-driver at {' or '.join(CUA_CANDIDATES)}"])
    try:
        CUA = Cua(CUA_PATH)
        CUA_SCALE = float(CUA.call("get_screen_size", {}).get("scale_factor") or 1.0)
        # Off the target first, so a pointer already there does not pass the check.
        cua_move(target[0] - 40, target[1])
        cua_move(target[0], target[1])
        at, ok = landed(target)
        if ok:
            ROUTE = "cua"
            return None
        why.append(f"cua-driver move_cursor {target[0]:.0f} {target[1]:.0f} (scale {CUA_SCALE:g}): "
                   f"pointer after {at}")
    except (OSError, RuntimeError, ValueError) as error:
        why.append(f"cua-driver at {CUA_PATH}: {error}")
    return "; ".join(why)


def activate():
    if (rpc("debug.focus") or {}).get("app_active"):
        return True
    if CUA_PATH:
        done = subprocess.run([CUA_PATH, "call", "bring_to_front", json.dumps({"pid": APP_PID})], capture_output=True,
                              text=True, timeout=60)
        if done.returncode and not REPORT.get("activate_error"):
            REPORT["activate_error"] = f"exit {done.returncode}: {(done.stderr or done.stdout).strip()[-300:]}"
    return bool(wait(lambda: (rpc("debug.focus") or {}).get("app_active"), 3))


def pct(values, q):
    values = sorted(values)
    return round(values[min(len(values) - 1, int(round(q * (len(values) - 1))))], 1) if values else None


# --- one sample -----------------------------------------------------------------------------------
def sample(count, index, key, point, frame):
    off = [frame[0] + frame[2] + 260, point[1]]  # right of the sidebar, in the content, at the row's height
    move_path(point, off, 3)
    wait(lambda: cards().get("phase") == "idle", 3)
    time.sleep(0.45)  # test harness: past the quick-reshow window, so the card opens cold
    activate()
    start = [frame[0] + frame[2] + 40, point[1]]
    move_path(off, start, 3)
    last = move_path(start, point, 6)  # onto the row from its right edge, as a hand comes off the content
    pending = shown = None
    report = {}
    deadline = last + 2.0
    while time.monotonic() < deadline:  # bounded: 2 s per sample
        report = cards()
        now = time.monotonic()
        if pending is None and report.get("pending_target", "-") != "-":
            pending = (now - last) * 1000
        if report.get("card_showing") == "true" and report.get("shown_target", "-") != "-":
            shown = (now - last) * 1000
            break
        time.sleep(0.005)  # test harness: about one read per frame
    run = {"workspaces": count, "round": index, "row": key, "pending_ms": pending and round(pending, 1),
           "shown_ms": shown and round(shown, 1), "target": report.get("shown_target")}
    if shown is None:
        run["miss"] = {k: v for k, v in report.items() if k != "card_text"}
        run["pointer"] = where() if opts.input == "real" else None
        if report.get("last_hit", "-") == "-":
            # A coordinate mismatch or a source refusing the hit: the row's frame against the point the move used,
            # and every visible row's frame now.
            run["row_frame"] = frame
            run["point"] = dict(LAST_POINT) if opts.input == "synthetic" else to_screen(point)
            run["rows_now"] = [(k, f) for k, _, f in rows()][:12]
    run["active"] = (rpc("debug.focus") or {}).get("app_active")
    print(f"   {count}w #{index} {key}: active {run['active']} pending {run['pending_ms']} shown {run['shown_ms']}"
          + (f" MISS {json.dumps(run.get('miss'))[:600]}" if shown is None else "")
          + (f" ROW {run['row_frame']} POINT {json.dumps(run['point'])[:400]} ROWS {json.dumps(run['rows_now'][:4])}"
             if "row_frame" in run else ""), flush=True)
    return run


def fill(count):
    for _ in range(count * 2):  # bounded: a create that never lands must not hang the step
        have = workspace_count()
        if have >= count:
            return True
        rpc("action.run", {"action": "workspace.newAtBottom", "args": {}, "focus": False, "origin": "script"}, timeout=60)
        if not wait(lambda: workspace_count() > have, 10, step=0.1):
            return False
    return workspace_count() >= count


# --- run ----------------------------------------------------------------------------------------
APP = opts.app.rstrip("/")
SCRATCH = tempfile.mkdtemp(prefix=f"hover-instant-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
teardown = TagTeardown(APP)
teardown.install()
app = None
APP_PID = None
status = 1
try:
    subprocess.run(["xcrun", "swiftc", "-O", os.path.join(HERE, "pointer-probe.swift"), "-o", PROBE], check=True)
    SCREEN_H = float(probe("screen") or 0)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_CHIEF_ISOLATED": "1",
           "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720",
           # A fleet step cannot activate the app (no LaunchServices session): WindowPlacement.noActivate counts it as
           # active and the coordinator hit-tests against its own windows.
           "CMUX_NEXT_NO_ACTIVATE": "1"}
    try:
        app, SOCKET = launch_app(APP, env, os.path.join(OUT, f"app-{opts.tag}.log"), timeout=180,
                                 on_start=lambda p: globals().__setitem__("APP_PID", p.pid))
    except LaunchError as error:
        REPORT["notes"].append(f"launch failed: {error}")
        raise SystemExit(1)
    APP_PID = app.pid
    REPORT["macos"] = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    REPORT["host"] = subprocess.run(["hostname", "-s"], capture_output=True, text=True).stdout.strip()
    REPORT["active_at_start"] = activate()
    why = real_input_works() if opts.input == "real" else None
    if why:
        REPORT["notes"].append(f"real input fell back to synthetic: {why}")
        safe_print(f"real input fell back to synthetic: {why}", flush=True)
        opts.input = REPORT["input"] = "synthetic"
    REPORT["pointer_route"] = {"posted": "pointer-probe posted moves", "cua": "cua-driver move_cursor"}.get(ROUTE) \
        if opts.input == "real" else "debug.pointer_hover"
    report = cards()
    REPORT["defaults"] = {k: report.get(k) for k in ("enabled", "delay_ms", "sources", "monitor", "suppressions", "quiet")}
    safe_print(f"app pid {APP_PID}, input {opts.input} ({REPORT['pointer_route']}), "
               f"active {REPORT['active_at_start']}, window "
               f"{(main_window() or {}).get('frame')}, cards {REPORT['defaults']}", flush=True)
    for count in [int(c) for c in opts.workspaces.split(",") if c]:
        if not fill(count):
            REPORT["notes"].append(f"the app stopped making workspaces before {count}")
            break
        visible = wait(lambda: rows() if len(rows()) >= 2 else None, 10) or []
        runs = [sample(count, i, *visible[i % len(visible)]) for i in range(opts.samples)] if visible else []
        shown = [r["shown_ms"] for r in runs if r["shown_ms"] is not None]
        pending = [r["pending_ms"] for r in runs if r["pending_ms"] is not None]
        cell = {"workspaces": count, "rows_visible": len(visible), "samples": len(runs), "shown": len(shown),
                "shown_p50": pct(shown, 0.5), "shown_p95": pct(shown, 0.95),
                "pending_p50": pct(pending, 0.5), "pending_p95": pct(pending, 0.95),
                "median": statistics.median(shown) if shown else None, "runs": runs}
        REPORT["cells"].append(cell)
        safe_print(f"{count} workspaces: {len(shown)}/{len(runs)} shown, last move to shown p50 {cell['shown_p50']} "
                   f"p95 {cell['shown_p95']} ms, to pending p50 {cell['pending_p50']} ms", flush=True)
    status = 0 if REPORT["cells"] and all(c["shown"] for c in REPORT["cells"]) else 1
finally:
    if CUA is not None:
        CUA.close()
    if app is not None:
        rpc("action.run", {"action": "quitEndSessions", "origin": "script"}, timeout=10)
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            app.kill()  # the exact PID this script started
            app.wait()
    teardown.end()
    if opts.json:
        with open(opts.json, "w") as f:
            json.dump(REPORT, f, indent=1)
sys.exit(status)

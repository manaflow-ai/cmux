#!/usr/bin/env python3
"""Sidebar row hover card: how long from the pointer's arrival on a row to the card (goal sidebar-hover-instant,
Leo 2026-11-01: "i need these hover previews to appear a hell of a lot faster than they do now").

  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \\
    --ref <sha> --artifact artifacts/split-spring/report.json --arg=--config=bench --arg=--suite=hover-instant

Launches the tagged app (a bench build: `debug.hover_cards` is registered only with CMUX_BENCH_HOOKS or in Debug),
fills the sidebar to each --workspaces count, and for --samples rows per count moves the real pointer onto the row
with posted mouse moves (pointer-probe.swift; needs the host's Accessibility grant) and reads `debug.hover_cards`
until the row's card shows. When a posted move does not move the pointer (no grant) it says so and moves a
synthetic pointer through the windows' tracking areas instead (`debug.pointer_hover`). Per sample: the last move to
pending and to shown (ms); on a miss (no card in 2 s) the coordinator's whole report. Writes --json.
"""
import argparse, json, os, plistlib, socket, statistics, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import LaunchError, launch_app  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402

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


def move_path(start, end, steps):
    """Moves from `start` to `end` (window points), `steps` moves about 120 Hz apart; returns the monotonic time
    the last move was posted."""
    if opts.input == "synthetic":
        height = ((main_window() or {}).get("frame") or {}).get("height", 0)
        for i in range(1, steps + 1):
            x = start[0] + (end[0] - start[0]) * i / steps
            y = start[1] + (end[1] - start[1]) * i / steps
            rpc("debug.pointer_hover", {"point": [x, height - y]})
        return time.monotonic()
    (x0, y0), (x1, y1) = to_screen(start), to_screen(end)
    probe("path", x0, y0, x1, y1, steps)
    return time.monotonic()


def real_input_works():
    """A posted move moves the pointer (the step's process holds the Accessibility grant)."""
    f = (main_window() or {}).get("frame") or {}
    target = to_screen([f.get("width", 800) * 0.6, f.get("height", 600) * 0.5])
    probe("move", target[0], target[1])
    at = where()
    return bool(at) and abs(at[0] - target[0]) < 2 and abs(at[1] - target[1]) < 2


def activate():
    if (rpc("debug.focus") or {}).get("app_active"):
        return True
    cua = os.path.expanduser("~/.local/bin/cua-driver")
    if os.path.exists(cua):
        subprocess.run([cua, "call", "bring_to_front", json.dumps({"pid": APP_PID})], capture_output=True, text=True,
                       timeout=60)
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
        run["focus"] = {k: v for k, v in (rpc("debug.focus") or {}).items() if k in ("app_active", "key_window", "main_window")}
    print(f"   {count}w #{index} {key}: pending {run['pending_ms']} shown {run['shown_ms']}"
          + (f" MISS {json.dumps(run.get('miss'))[:600]}" if shown is None else ""), flush=True)
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
           # As a person's app: it takes focus, so cards need it active and real moves reach its window.
           "CMUX_NEXT_NO_ACTIVATE": None}
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
    if opts.input == "real" and not real_input_works():
        REPORT["notes"].append("a posted mouse move did not move the pointer (no Accessibility grant): synthetic input")
        opts.input = REPORT["input"] = "synthetic"
    report = cards()
    REPORT["defaults"] = {k: report.get(k) for k in ("enabled", "delay_ms", "sources", "monitor", "suppressions", "quiet")}
    print(f"app pid {APP_PID}, input {opts.input}, active {REPORT['active_at_start']}, window "
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
        print(f"{count} workspaces: {len(shown)}/{len(runs)} shown, last move to shown p50 {cell['shown_p50']} "
              f"p95 {cell['shown_p95']} ms, to pending p50 {cell['pending_p50']} ms", flush=True)
    status = 0 if REPORT["cells"] and all(c["shown"] for c in REPORT["cells"]) else 1
finally:
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

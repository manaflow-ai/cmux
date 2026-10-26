#!/usr/bin/env python3
"""Measure native workspace-menu hover latency on the same tagged app harness.

The run uses a real window-server right-click and pointer moves through the menu with
``cua-driver``. The DEBUG-only ``debug.menu_trace`` endpoint timestamps AppKit's
``NSMenuDelegate.menu(_:willHighlight:)`` callback and counts ``validateMenuItem`` calls.
``debug.hangs`` is cleared before each traversal and returned with the latency samples.

Run on a leased GUI host for both instrumented refs (the red ref and the candidate):

  nx-remote --needs gui --needs input --app-from-fleet cmux --tag T --ref INSTRUMENTED_SHA \
    -- python3 scripts/cmux-next/context-menu-hover-latency.py --out "$NX_ARTIFACTS/T"

The instrumented ref must contain the same DEBUG-only tracing commit on top of each source
ref. The script refuses to report timings when the AX tree has no menu-item frames or when
AppKit never reports a highlight, so a missing GUI surface cannot become fake data.
"""
import argparse
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--app", default=os.environ.get("NX_APP"))
parser.add_argument("--tag", default=os.environ.get("NX_APP_TAG"))
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", tempfile.mkdtemp(prefix="cmux-menu-hover-")))
parser.add_argument("--runs", type=int, default=5)
parser.add_argument("--workspace", default="hover-me")
parser.add_argument("--wait-seconds", type=float, default=30)
opts = parser.parse_args()

if not opts.app or not opts.tag:
    sys.exit("context-menu-hover-latency.py: --app and --tag (or NX_APP and NX_APP_TAG) are required")
CUA = os.environ.get("CUA_DRIVER", os.path.expanduser("~/.local/bin/cua-driver"))
if not os.access(CUA, os.X_OK):
    sys.exit("context-menu-hover-latency.py: run with nx-remote --needs input (cua-driver missing)")
os.makedirs(opts.out, exist_ok=True)
SOCKET = os.environ.get("NX_APP_SOCKET", f"/tmp/cmux-debug-{opts.tag}.sock")
CLI = os.environ.get("NX_APP_CLI", os.path.join(opts.app, "Contents/Resources/bin/cmux"))
SCRATCH = tempfile.mkdtemp(prefix=f"menu-hover-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
open(CONFIG, "w").write("{}")
open(GHOSTTY, "w").write("")
CUA_SESSION = f"menu-hover-{opts.tag}-{os.getpid()}"


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


def cua(tool, args, timeout=60):
    done = subprocess.run([CUA, "call", tool, json.dumps({"session": CUA_SESSION, **args})],
                          capture_output=True, text=True, timeout=timeout)
    try:
        return json.loads(done.stdout)
    except ValueError:
        return {"error": (done.stdout + done.stderr)[-500:]}


def wait(predicate, seconds=None):
    deadline = time.monotonic() + (seconds if seconds is not None else opts.wait_seconds)
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    return None


def cli(*args):
    env = {"HOME": os.environ.get("HOME", "/tmp"), "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp")}
    return subprocess.run([CLI, "--app-socket", SOCKET, *args], env=env, capture_output=True, text=True, timeout=60)


def first_window(pid):
    windows = cua("list_windows", {"pid": pid}).get("windows") or []
    # nx-remote's app is a different process; choose the largest titled on-screen window.
    windows = [w for w in windows if w.get("is_on_screen")]
    return max(windows, key=lambda w: (w.get("bounds") or {}).get("width", 0) * (w.get("bounds") or {}).get("height", 0), default=None)


def app_pid():
    found = subprocess.run(["lsof", "-t", SOCKET], capture_output=True, text=True).stdout.split()
    if found:
        return int(found[0])
    return int(subprocess.run(["pgrep", "-n", "-f", os.path.join(opts.app, "Contents/MacOS")],
                              capture_output=True, text=True).stdout.strip())


def json_frame(value):
    if isinstance(value, dict):
        for key in ("frame", "bounds", "rect", "AXFrame"):
            candidate = value.get(key)
            if isinstance(candidate, dict) and all(k in candidate for k in ("x", "y")):
                width = candidate.get("width", candidate.get("w"))
                height = candidate.get("height", candidate.get("h"))
                if width is not None and height is not None:
                    return {"x": float(candidate["x"]), "y": float(candidate["y"]),
                            "width": float(width), "height": float(height)}
            if isinstance(candidate, list) and len(candidate) == 4:
                return dict(zip(("x", "y", "width", "height"), map(float, candidate)))
    return None


def role(value):
    if not isinstance(value, dict):
        return ""
    return str(value.get("role") or value.get("AXRole") or value.get("type") or "")


def title(value):
    if not isinstance(value, dict):
        return ""
    return str(value.get("title") or value.get("AXTitle") or value.get("label") or "")


def menu_items(state):
    """Find direct menu-item frames in the native AX tree returned by cua-driver."""
    found = []

    def walk(value, in_menu=False):
        if isinstance(value, dict):
            current_role = role(value)
            current_menu = in_menu or current_role in ("AXMenu", "menu")
            if current_menu and (current_role in ("AXMenuItem", "menuitem") or "menuitem" in current_role.lower()) and title(value):
                frame = json_frame(value)
                if frame:
                    found.append({"title": title(value), "frame": frame, "enabled": value.get("enabled", value.get("AXEnabled", True)),
                                  "node": value})
            for child in value.values():
                walk(child, current_menu)
        elif isinstance(value, list):
            for child in value:
                walk(child, in_menu)

    for key in ("elements", "tree", "accessibility_tree", "ax_tree"):
        walk(state.get(key), False)
    # A tree-markdown fallback gives names for diagnostics, but deliberately cannot fabricate frames.
    if not found:
        names = re.findall(r'AXMenuItem "([^"]+)"', state.get("tree_markdown", ""))
        if names:
            raise RuntimeError("AX tree exposed menu titles but no item frames: " + repr(names[:8]))
    return found


def centers(items, window):
    """Convert AX screen frames to desktop pixels for cua-driver move_cursor."""
    scale = float((cua("get_screen_size", {}) or {}).get("scale_factor") or 2.0)
    return [(item, ((item["frame"]["x"] + item["frame"]["width"] / 2) * scale,
                   (item["frame"]["y"] + item["frame"]["height"] / 2) * scale)) for item in items]


def trace(reset=False):
    result = rpc("debug.menu_trace", {"reset": reset}, timeout=5)
    if not isinstance(result, dict) or "samples" not in result:
        raise RuntimeError("instrumented DEBUG build lacks debug.menu_trace: " + repr(result)[:300])
    return result


def action_id(sample):
    return sample.get("action") or sample.get("item")


def percentile(values, p):
    if not values:
        return None
    values = sorted(values)
    return round(values[min(len(values) - 1, int(p * (len(values) - 1)))], 3)


def run_once(pid, window):
    rows = rpc("debug.sidebar_rows") or {}
    all_rows = [r for w in rows.get("windows", []) for r in w.get("rows", [])]
    row = next((r for r in all_rows if r.get("title") == opts.workspace and r.get("window_frame")), None)
    if not row:
        raise RuntimeError(f"workspace row {opts.workspace!r} has no debug frame")
    frame = row["window_frame"]
    state = cua("get_window_state", {"pid": pid, "window_id": window["window_id"], "include_screenshot": False})
    scale = float(state.get("screenshot_scale") or 1.0)
    x = round((frame["x"] + frame["width"] / 2) * scale)
    y = round((frame["y"] + frame["height"] / 2) * scale)
    rpc("debug.hangs", {"clear": True})
    trace(reset=True)
    clicked = time.monotonic()
    right = cua("right_click", {"pid": pid, "window_id": window["window_id"], "x": x, "y": y, "delivery_mode": "foreground"})
    if right.get("error") or right.get("code"):
        raise RuntimeError("right_click failed: " + repr(right))
    first = wait(lambda: trace().get("samples"), 5)
    if not first:
        raise RuntimeError("AppKit never reported the menu's initial highlight")
    menu_state = cua("get_window_state", {"pid": pid, "window_id": window["window_id"], "max_elements": 5000,
                                           "include_screenshot": False})
    items = menu_items(menu_state)
    if not items:
        raise RuntimeError("open menu has no AX item frames")
    samples = []
    previous_validations = 0
    for item, px, py in centers(items, window):
        if item.get("enabled") is False:
            continue
        trace(reset=True)
        started = time.monotonic()
        moved = cua("move_cursor", {"x": round(px), "y": round(py), "scope": "desktop"})
        if moved.get("error") or moved.get("code"):
            raise RuntimeError("move_cursor failed: " + repr(moved))
        observed = wait(lambda: trace().get("samples"), 2)
        if not observed:
            raise RuntimeError(f"no willHighlight callback for menu item {item['title']!r}")
        hit = next((sample for sample in observed if action_id(sample) == item["title"] or sample.get("item") == item["title"]), observed[-1])
        # App and Python both use monotonic uptime; callback uptime avoids polling and AX-read costs.
        latency = (float(hit["uptime"]) - started) * 1000
        current_validations = int(trace().get("validations", 0))
        samples.append({"item": item["title"], "latency_ms": round(latency, 3),
                        "validation_calls": current_validations - previous_validations})
        previous_validations = current_validations
    cua("press_key", {"pid": pid, "window_id": window["window_id"], "key": "escape", "delivery_mode": "foreground"})
    time.sleep(0.15)
    hangs = rpc("debug.hangs", {}, timeout=5) or {}
    return {"open_ms": round((float(first[0]["uptime"]) - clicked) * 1000, 3),
            "items": samples, "validations": int(trace().get("validations", 0)),
            "hangs": hangs}


def main():
    if not os.path.exists(SOCKET):
        env = ["CMUX_NEXT_NO_ACTIVATE=1", "CMUX_NEXT_SOCKET_MODE=automation", f"CMUX_NEXT_CONFIG_FILE={CONFIG}",
               f"CMUX_NEXT_GHOSTTY_CONFIG={GHOSTTY}", "CMUX_NEXT_TEST_WINDOW_SCREEN=last", "CMUX_NEXT_TEST_WINDOW_FRAME=40,40,1100,820"]
        subprocess.run(["open", "-n", opts.app, *[arg for pair in env for arg in ("--env", pair)]], check=True)
        if not wait(lambda: os.path.exists(SOCKET), opts.wait_seconds):
            raise RuntimeError("tagged app did not create its debug socket")
        time.sleep(1.5)  # test harness: let the first window and sidebar paint
    pid = app_pid()
    session = cua("start_session", {})
    if session.get("error"):
        raise RuntimeError("cua start_session failed: " + repr(session))
    window = wait(lambda: first_window(pid), 30)
    if not window:
        raise RuntimeError("no on-screen tagged cmux window")
    cli("workspace", "create", "--empty", "--name", opts.workspace)
    if not wait(lambda: any(r.get("title") == opts.workspace and r.get("window_frame")
                            for w in (rpc("debug.sidebar_rows") or {}).get("windows", []) for r in w.get("rows", [])), 30):
        raise RuntimeError("workspace fixture did not appear")
    runs = [run_once(pid, window) for _ in range(opts.runs)]
    latencies = [entry["latency_ms"] for run in runs for entry in run["items"]]
    report = {"tag": opts.tag, "pid": pid, "runs": runs,
              "latency_ms": {"samples": len(latencies), "p50": percentile(latencies, .50),
                             "p95": percentile(latencies, .95), "max": round(max(latencies), 3) if latencies else None},
              "validation_calls": [run["validations"] for run in runs],
              "main_thread_stalls": [{"max_ms": run["hangs"].get("max_ms", 0), "records": run["hangs"].get("records", [])}
                                     for run in runs]}
    path = os.path.join(opts.out, "context-menu-hover-latency.json")
    json.dump(report, open(path, "w"), indent=2)
    print(json.dumps(report, indent=2))


try:
    main()
except (RuntimeError, subprocess.SubprocessError, ValueError) as error:
    print(f"HARNESS ERROR: {error}", file=sys.stderr)
    sys.exit(2)

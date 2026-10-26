#!/usr/bin/env python3
"""Record a real cold-launch Cmd-N sidebar transition.

With --app, an isolated tagged build is launched once to seed three workspaces,
quit with sessions kept, and launched again. The second launch must restore the
middle workspace focused. With --socket, attach to a caller-owned cold launch.
The transition is driven by debug.new_tab frame_strip (the real Cmd-N key path),
while debug.sidebar_rows motion and debug.frames record display cadence and row
positions. No pixels are synthesized.
"""
import argparse
import json
import os
import socket
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--socket", help="socket of a caller-owned cold launch")
parser.add_argument("--app", help="tagged DEV .app; launches and restores an isolated state")
parser.add_argument("--out", required=True)
parser.add_argument("--head", default="", help="source SHA recorded in the receipt")
parser.add_argument("--cold-launch-id", default="", help="caller receipt/ID proving the socket is a cold launch")
parser.add_argument("--placement", choices=("afterCurrent", "top", "bottom"), default="afterCurrent")
parser.add_argument("--duration-ms", type=float, default=700)
parser.add_argument("--min-workspaces", type=int, default=3)
args = parser.parse_args()
if bool(args.socket) == bool(args.app):
    parser.error("pass exactly one of --socket or --app")
if args.socket and not args.cold_launch_id:
    parser.error("--socket requires --cold-launch-id (the caller's cold-launch provenance)")

OUT = Path(args.out).resolve()
OUT.mkdir(parents=True, exist_ok=True)
SOCKET = args.socket
bench = None


def rpc(method, params=None, timeout=60):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(SOCKET)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf or b"{}")
        return reply.get("result") if reply.get("ok", "result" in reply) else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def sidebar():
    report = rpc("debug.sidebar_rows") or {}
    windows = report.get("windows") or []
    return windows[0] if windows else {}


def workspace_rows(report=None):
    report = report or sidebar()
    return [r for r in report.get("rows") or [] if str(r.get("key", "")).startswith("workspace(")]


def ordered(rows):
    def y(row):
        frame = row.get("window_frame") or {}
        return float(frame.get("y", 0))
    return sorted(rows, key=y)


def selected_index(rows):
    rows = ordered(rows)
    return next((i for i, row in enumerate(rows) if row.get("selected")), None)


def wait_for(label, predicate, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise RuntimeError(f"{label} timed out after {timeout}s")


def action(name, args=None, timeout=60):
    result = rpc("action.run", {"action": name, "args": args or {}, "origin": "script", "focus": True}, timeout)
    if isinstance(result, dict) and result.get("error"):
        raise RuntimeError(f"{name}: {result['error']}")
    return result


def save_json(name, value):
    path = OUT / name
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    return str(path)


def launch_and_seed(app_path):
    global SOCKET, bench
    here = Path(__file__).resolve().parent
    sys.path.insert(0, str(here))
    from bench_launch import BenchApp

    config = {"workspaces": {"newPlacement": args.placement}}
    bench = BenchApp(app_path, out=str(OUT), config=config, fresh_state=True, teardown=False)
    bench.launch(timeout=180)
    SOCKET = bench.socket
    wait_for("initial workspace", lambda: len(workspace_rows()) >= 1)
    seed_rows[:] = workspace_rows()
    while len(seed_rows) < args.min_workspaces:
        before_count = len(seed_rows)
        action("workspace.newAtBottom")
        wait_for("workspace row", lambda: len(workspace_rows()) >= before_count + 1)
        seed_rows[:] = workspace_rows()
    rows = ordered(workspace_rows())
    middle = len(rows) // 2
    action("selectWorkspaceByNumber", {"index": middle + 1})
    wait_for("middle workspace selection", lambda: selected_index(workspace_rows()) == middle)
    save_json("seed.json", {"windows": rpc("debug.windows"), "sidebar": sidebar()})
    # Keep the daemon sessions/layout, then relaunch the same isolated tag.
    reply = rpc("debug.quit", {"fixture_quit": "keep"}, timeout=30)
    if isinstance(reply, dict) and reply.get("error"):
        raise RuntimeError(f"quit keep: {reply['error']}")
    wait_for("seed app quit", lambda: bench.process.poll() is not None, timeout=60)
    bench2 = BenchApp(app_path, out=str(OUT), config=config, fresh_state=False, teardown=False)
    bench2.launch(timeout=180)
    bench = bench2
    SOCKET = bench.socket
    if bench.socket != bench2.socket or bench.tag != bench2.tag:
        raise RuntimeError("relaunch changed the isolated tag/socket; cold restore is unproven")


seed_rows = []
try:
    launch_proof = {"mode": "app", "cold_launch_id": "bench-fresh-state-relaunch"} if args.app else {"mode": "socket", "cold_launch_id": args.cold_launch_id}
    if args.app:
        launch_and_seed(args.app)
        launch_proof.update({"tag": bench.tag, "socket": bench.socket, "state_root": bench.state_root(),
                             "home": bench.environment().get("HOME")})
        cold_new_tab = rpc("debug.new_tab", {"action": "state"}) or {}
        if cold_new_tab.get("openings"):
            raise RuntimeError(f"relaunch has prior Cmd-N openings: {cold_new_tab.get('openings')}")
        launch_proof["new_tab_state"] = cold_new_tab
    else:
        wait_for("cold app socket", lambda: bool((rpc("debug.windows") or {}).get("windows")), timeout=180)

    before_sidebar = sidebar()
    before_rows = ordered(workspace_rows(before_sidebar))
    if len(before_rows) < args.min_workspaces:
        raise RuntimeError(f"restored {len(before_rows)} workspaces; need {args.min_workspaces}")
    before_selected = selected_index(before_rows)
    expected_middle = len(before_rows) // 2
    if before_selected != expected_middle:
        raise RuntimeError(f"restored selection index {before_selected}; expected middle index {expected_middle}")
    save_json("before-sidebar.json", before_sidebar)
    save_json("before-windows.json", rpc("debug.windows"))
    save_json("before-surfaces.json", rpc("debug.surfaces"))

    strip_dir = OUT / "frame-strip"
    strip_dir.mkdir(parents=True, exist_ok=True)
    rpc("debug.window_snapshot", {"kind": "main", "path": str(OUT / "before.png")})
    rpc("debug.sidebar_rows", {"motion": "start"})
    rpc("debug.frames", {"action": "start"})
    save_json("pre-key.json", {"sidebar": sidebar(), "windows": rpc("debug.windows"), "surfaces": rpc("debug.surfaces")})
    strip = rpc("debug.new_tab", {"action": "frame_strip", "key": "n", "modifiers": ["command"],
                                  "dir": str(strip_dir), "duration_ms": args.duration_ms}, timeout=120)
    frames = rpc("debug.frames", {"action": "stop", "raw": True}, timeout=30)
    motion = rpc("debug.sidebar_rows", {"motion": "stop"}, timeout=60)
    after_sidebar = sidebar()
    after_rows = ordered(workspace_rows(after_sidebar))
    save_json("after-sidebar.json", after_sidebar)
    save_json("after-windows.json", rpc("debug.windows"))
    save_json("after-surfaces.json", rpc("debug.surfaces"))
    rpc("debug.window_snapshot", {"kind": "main", "path": str(OUT / "after.png")})

    before_keys = {r.get("key") for r in before_rows}
    motion_frames = (motion or {}).get("frames") or []
    observed_keys = []
    for frame in motion_frames:
        for key in (frame.get("views") or {}):
            if key.startswith("workspace(") and key not in before_keys and key not in observed_keys:
                observed_keys.append(key)
    new_keys = observed_keys + [r.get("key") for r in after_rows if r.get("key") not in before_keys and r.get("key") not in observed_keys]
    positions = []
    for index, frame in enumerate(motion_frames):
        views = frame.get("views") or {}
        visible = {key: box for key, box in views.items() if key.startswith("workspace(") and
                   (len(box) < 5 or box[4] > 0.02)}
        keys = sorted(visible, key=lambda key: (visible[key][1], key))
        for key in new_keys:
            if key in keys:
                box = visible[key]
                positions.append({"frame": index, "index": keys.index(key), "key": key,
                                  "y": box[1], "opacity": box[4] if len(box) > 4 else 1})
    expected_index = before_selected + 1 if args.placement == "afterCurrent" else (0 if args.placement == "top" else len(before_rows))
    first_index = positions[0]["index"] if positions else None
    receipt = {
        "head": args.head,
        "app": args.app,
        "socket": SOCKET,
        "launch_proof": launch_proof,
        "placement": args.placement,
        "before": {"workspaces": len(before_rows), "selected_index": before_selected, "rows": before_rows},
        "after": {"workspaces": len(after_rows), "rows": after_rows, "new_keys": new_keys},
        "expected_new_index": expected_index,
        "new_row_positions": positions,
        "first_painted_index": first_index,
        "first_painted_after_current": first_index == expected_index,
        "row_stayed_at_expected_index": bool(positions) and all(p["index"] == expected_index for p in positions),
        "motion_frames": len(motion_frames),
        "display_probe": frames,
        "frame_strip": strip,
        "artifacts": {"before": "before.png", "after": "after.png", "frame_strip": "frame-strip"},
    }
    save_json("receipt.json", receipt)
    if not strip or (isinstance(strip, dict) and strip.get("error")):
        raise RuntimeError(f"frame_strip failed: {strip}")
    if not positions or first_index != expected_index or any(p["index"] != expected_index for p in positions):
        raise RuntimeError(f"first painted row index {first_index}; expected {expected_index}")
    print(json.dumps({"ok": True, "receipt": str(OUT / "receipt.json"), "first_painted_index": first_index,
                      "expected_index": expected_index, "motion_frames": len(motion_frames)}, sort_keys=True))
finally:
    if bench is not None and getattr(bench, "process", None) is not None and bench.process.poll() is None:
        bench.stop()

#!/usr/bin/env python3
"""Record a real cold-launch Cmd-N sidebar transition in an isolated fixture.

The harness launches a tagged DEV/bench app in an isolated state, seeds three
workspaces, quits while keeping sessions, and relaunches the same tag. The
relaunch must restore the middle workspace focused. Cmd-N is sent through the
real debug.new_tab frame_strip path while debug.sidebar_rows motion and
DebugFrameProbe record native display timing and row positions. Artifacts stay
local; run the trusted PR-media privacy OCR before publishing any media.
"""
import argparse
import json
import socket
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True, help="tagged DEV .app; launches and restores an isolated state")
parser.add_argument("--out", required=True, help="local output directory; no upload is performed")
parser.add_argument("--head", required=True, help="exact source SHA recorded in the receipt")
parser.add_argument("--placement", choices=("afterCurrent", "top", "bottom"), default="afterCurrent")
parser.add_argument("--duration-ms", type=float, default=700)
parser.add_argument("--min-workspaces", type=int, default=3)
args = parser.parse_args()

OUT = Path(args.out).resolve()
OUT.mkdir(parents=True, exist_ok=True)
SOCKET = None
bench = None
motion_started = False
display_started = False
motion = None
display = None
stop_errors = []


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
        if not buf:
            raise RuntimeError(f"{method}: empty response")
        reply = json.loads(buf)
        if not isinstance(reply, dict) or reply.get("id") != 1:
            raise RuntimeError(f"{method}: invalid response envelope")
        if reply.get("ok") is not True or "error" in reply or "result" not in reply:
            raise RuntimeError(f"{method}: unsuccessful response: {reply!r}")
        return reply["result"]
    except (OSError, ValueError) as error:
        raise RuntimeError(f"{method}: {error}") from error


def require_result(method, params=None, timeout=60, allow_null=False):
    result = rpc(method, params, timeout)
    if isinstance(result, dict) and result.get("error"):
        raise RuntimeError(f"{method}: {result['error']}")
    if result is None and not allow_null:
        raise RuntimeError(f"{method}: missing result")
    return result


def sidebar():
    report = rpc("debug.sidebar_rows") or {}
    windows = report.get("windows") or []
    return windows[0] if windows else {}


def workspace_rows(report=None):
    report = report or sidebar()
    return [r for r in report.get("rows") or [] if str(r.get("key", "")).startswith("workspace(")]


def ordered(rows):
    return sorted(rows, key=lambda row: float((row.get("window_frame") or {}).get("y", 0)))


def selected_index(rows):
    return next((i for i, row in enumerate(ordered(rows)) if row.get("selected")), None)


def wait_for(label, predicate, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise RuntimeError(f"{label} timed out after {timeout}s")


def action(name, arguments=None, timeout=60):
    return require_result("action.run", {"action": name, "args": arguments or {}, "origin": "script", "focus": True}, timeout)


def save_json(name, value):
    path = OUT / name
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    return str(path)


def stop_probes():
    """Stop every started native probe, retaining failures for a fail-closed result."""
    global motion_started, display_started, motion, display
    if display_started:
        try:
            display = require_result("debug.frames", {"action": "stop", "raw": True}, timeout=30)
        except Exception as error:  # stop the other probe even when this one fails
            stop_errors.append(str(error))
        finally:
            display_started = False
    if motion_started:
        try:
            motion = require_result("debug.sidebar_rows", {"motion": "stop"}, timeout=60)
        except Exception as error:
            stop_errors.append(str(error))
        finally:
            motion_started = False
    if stop_errors:
        raise RuntimeError("probe stop failed: " + "; ".join(stop_errors))


def launch_and_seed(app_path):
    """Launch, seed, keep, relaunch, and return proof of two distinct processes."""
    global SOCKET, bench
    here = Path(__file__).resolve().parent
    sys.path.insert(0, str(here))
    from bench_launch import BenchApp

    config = {"workspaces": {"newPlacement": args.placement}}
    bench = BenchApp(app_path, out=str(OUT), config=config, fresh_state=True, teardown=False)
    bench.launch(timeout=180)
    first_tag = bench.tag
    first_socket = bench.socket
    first_pid = bench.process.pid
    first_state_root = bench.state_root()
    first_home = bench.environment().get("HOME")
    SOCKET = first_socket

    wait_for("initial workspace", lambda: len(workspace_rows()) >= 1)
    seed_rows = ordered(workspace_rows())
    while len(seed_rows) < args.min_workspaces:
        before_count = len(seed_rows)
        action("workspace.newAtBottom")
        wait_for("workspace row", lambda: len(workspace_rows()) >= before_count + 1)
        seed_rows = ordered(workspace_rows())
    middle = len(seed_rows) // 2
    frame = seed_rows[middle].get("window_frame") or {}
    require_result("debug.mouse", {"action": "click", "x": frame["x"] + frame["width"] / 2,
                                    "y": frame["y"] + frame["height"] / 2})
    wait_for("middle workspace selection", lambda: selected_index(workspace_rows()) == middle)
    seed_keys = [row.get("key") for row in seed_rows]
    save_json("seed.json", {"windows": require_result("debug.windows"), "sidebar": sidebar()})

    # Keep daemon sessions/layout, then relaunch the same isolated tag.
    require_result("debug.quit", {"fixture_quit": "keep"}, timeout=30, allow_null=True)
    wait_for("seed app quit", lambda: bench.process.poll() is not None, timeout=60)
    bench2 = BenchApp(app_path, out=str(OUT), config=config, fresh_state=False, teardown=False)
    bench2.launch(timeout=180)
    second_tag = bench2.tag
    second_socket = bench2.socket
    second_pid = bench2.process.pid
    second_state_root = bench2.state_root()
    second_home = bench2.environment().get("HOME")
    if first_tag != second_tag or first_socket != second_socket or first_state_root != second_state_root:
        raise RuntimeError("relaunch changed fixture tag/socket/state identity")
    if first_home != second_home or first_pid == second_pid:
        raise RuntimeError("relaunch did not create a distinct process in the same isolated HOME")
    bench = bench2
    SOCKET = second_socket
    def restored_seed_rows():
        rows = ordered(workspace_rows())
        keys = [row.get("key") for row in rows]
        return rows if len(rows) >= len(seed_keys) and set(seed_keys).issubset(keys) else None
    restored_rows = wait_for("restored workspace rows", restored_seed_rows, timeout=60)
    restored_keys = [row.get("key") for row in restored_rows]
    return {
        "mode": "app_fixture",
        "tag": second_tag,
        "socket": second_socket,
        "state_root": second_state_root,
        "home": second_home,
        "first_pid": first_pid,
        "second_pid": second_pid,
        "seed_workspace_keys": seed_keys,
        "restored_workspace_keys": restored_keys,
    }


try:
    launch_proof = launch_and_seed(args.app)
    cold_new_tab = require_result("debug.new_tab", {"action": "state"})
    if cold_new_tab.get("openings"):
        raise RuntimeError(f"relaunch has prior Cmd-N openings: {cold_new_tab['openings']}")
    launch_proof["new_tab_state"] = cold_new_tab

    before_sidebar = sidebar()
    before_rows = ordered(workspace_rows(before_sidebar))
    if len(before_rows) < args.min_workspaces:
        raise RuntimeError(f"restored {len(before_rows)} workspaces; need {args.min_workspaces}")
    before_selected = selected_index(before_rows)
    expected_middle = len(before_rows) // 2
    if before_selected != expected_middle:
        raise RuntimeError(f"restored selection index {before_selected}; expected middle index {expected_middle}")
    save_json("before-sidebar.json", before_sidebar)
    save_json("before-windows.json", require_result("debug.windows"))
    save_json("before-surfaces.json", require_result("debug.surfaces"))

    strip_dir = OUT / "frame-strip"
    strip_dir.mkdir(parents=True, exist_ok=True)
    require_result("debug.window_snapshot", {"kind": "main", "path": str(OUT / "before.png")}, allow_null=True)
    require_result("debug.sidebar_rows", {"motion": "start"}, allow_null=True)
    motion_started = True
    require_result("debug.frames", {"action": "start"}, allow_null=True)
    display_started = True
    save_json("pre-key.json", {"sidebar": sidebar(), "windows": require_result("debug.windows"),
                                "surfaces": require_result("debug.surfaces")})
    try:
        strip = require_result("debug.new_tab", {"action": "frame_strip", "key": "n", "modifiers": ["command"],
                                                 "dir": str(strip_dir), "duration_ms": args.duration_ms}, timeout=120)
    finally:
        stop_probes()

    after_sidebar = sidebar()
    after_rows = ordered(workspace_rows(after_sidebar))
    save_json("after-sidebar.json", after_sidebar)
    save_json("after-windows.json", require_result("debug.windows"))
    save_json("after-surfaces.json", require_result("debug.surfaces"))
    require_result("debug.window_snapshot", {"kind": "main", "path": str(OUT / "after.png")}, allow_null=True)

    motion_frames = (motion or {}).get("frames") if isinstance(motion, dict) else None
    if not isinstance(motion_frames, list) or not motion_frames:
        raise RuntimeError("debug.sidebar_rows motion returned no native frames")
    motion_times = [frame.get("t") for frame in motion_frames]
    if any(not isinstance(t, (int, float)) or isinstance(t, bool) for t in motion_times):
        raise RuntimeError("motion frames missing native t timestamps")
    if any(b <= a for a, b in zip(motion_times, motion_times[1:])):
        raise RuntimeError("motion frame t timestamps are not strictly monotonic")
    if not isinstance(display, dict) or not isinstance(display.get("frames"), int) or display["frames"] <= 0:
        raise RuntimeError("debug.frames returned no native display frames")
    strip_frames = strip.get("frames") if isinstance(strip, dict) else None
    if not isinstance(strip_frames, list) or not strip_frames:
        raise RuntimeError("frame_strip returned no native composited frames")
    strip_ms = [frame.get("ms") for frame in strip_frames]
    if any(not isinstance(ms, (int, float)) or isinstance(ms, bool) for ms in strip_ms):
        raise RuntimeError("frame_strip frames missing native ms timestamps")
    if any(b < a for a, b in zip(strip_ms, strip_ms[1:])):
        raise RuntimeError("frame_strip ms timestamps are not monotonic")
    save_json("fullmotion.json", motion)
    save_json("display-probe.json", display)
    save_json("frame-strip.json", strip)

    before_keys = {row.get("key") for row in before_rows}
    observed_keys = []
    for native_frame in motion_frames:
        for key in (native_frame.get("views") or {}):
            if key.startswith("workspace(") and key not in before_keys and key not in observed_keys:
                observed_keys.append(key)
    new_keys = observed_keys + [row.get("key") for row in after_rows
                                if row.get("key") not in before_keys and row.get("key") not in observed_keys]
    positions = []
    for sample_index, native_frame in enumerate(motion_frames):
        views = native_frame.get("views") or {}
        visible = {key: box for key, box in views.items() if key.startswith("workspace(") and
                   (len(box) < 5 or box[4] > 0.02)}
        keys = sorted(visible, key=lambda key: (visible[key][1], key))
        for key in new_keys:
            if key in keys:
                box = visible[key]
                positions.append({"sample_index": sample_index, "native_t": native_frame["t"],
                                  "index": keys.index(key), "key": key, "y": box[1],
                                  "opacity": box[4] if len(box) > 4 else 1})
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
        "display_probe": display,
        "frame_strip": strip,
        "artifacts": {"before": "before.png", "after": "after.png", "frame_strip": "frame-strip",
                      "full_motion": "fullmotion.json", "display_probe": "display-probe.json",
                      "frame_strip_report": "frame-strip.json"},
    }
    save_json("receipt.json", receipt)
    if not positions or first_index != expected_index or any(p["index"] != expected_index for p in positions):
        raise RuntimeError(f"first painted row index {first_index}; expected {expected_index}")
    print(json.dumps({"ok": True, "receipt": str(OUT / "receipt.json"), "first_painted_index": first_index,
                      "expected_index": expected_index, "motion_frames": len(motion_frames)}, sort_keys=True))
finally:
    if display_started or motion_started:
        try:
            stop_probes()
        except Exception:
            pass
    if bench is not None and getattr(bench, "process", None) is not None and bench.process.poll() is None:
        bench.stop()

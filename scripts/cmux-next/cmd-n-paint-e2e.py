#!/usr/bin/env python3
"""Cmd-N and Cmd-T paint stable on a running tagged build (bd cx-8g3sn).

A new workspace (Cmd-N) or tab (Cmd-T) opens on the New Tab page with no blank or
intermediate frame: the window as the window server composited it, read frame after frame
around the key (`debug.new_tab` frame_strip), changes outside the pane's content area in one
step (each frame equals the one before the key or the settled one), and the content area never
shows one flat color. Fails on any such frame and prints where the frame strips are.

The app runs already (a capture slot: `capture-host launch`), with its debug socket.

Usage: cmd-n-paint-e2e.py --socket <path> [--runs 3] [--keys n,t] [--out DIR]
"""
import argparse, json, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--keys", default="n,t", help="Command-<key> openings to check, comma separated")
parser.add_argument("--out", default="/tmp/cmd-n-paint", help="where the app writes each run's frames")
parser.add_argument("--duration-ms", type=float, default=700)
opts = parser.parse_args()


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
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


def wait(label, predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)  # test harness wait, not app code
    sys.exit(f"FAIL {label} (timed out after {timeout:.0f} s)")


def spare_ready():
    # No-activate slots have no key window: park the spare in window 0 as a key change does.
    rpc("debug.new_tab", {"action": "retarget"})
    state = rpc("debug.new_tab", {"action": "state"}) or {}
    return any(s.get("ready") for s in state.get("spares") or [])


failures = []
for run in range(opts.runs):
    for key in opts.keys.split(","):
        wait(f"a ready spare before Cmd-{key.upper()}", spare_ready, 30)
        time.sleep(0.5)  # test harness wait: the window settles (caret, hover) before the strip
        out = f"{opts.out}/cmd-{key}-{run}"
        reply = rpc("debug.new_tab", {"action": "frame_strip", "key": key, "dir": out, "duration_ms": opts.duration_ms}) or {}
        if "error" in reply:
            sys.exit(f"FAIL frame_strip Cmd-{key.upper()}: {reply}")
        bad = [f for f in reply["frames"] if f["intermediate"] or f["blank"]]
        print(f"Cmd-{key.upper()} run {run}: {reply['frame_count']} frames every {reply['mean_interval_ms']:.1f} ms, "
              f"intermediate={reply['intermediate']:.0f} blank={reply['blank']:.0f} strip={out}/strip.png", flush=True)
        for frame in bad:
            print(f"  {frame['file']} at {frame['ms']:+.0f} ms: outside differs {frame['outside_vs_before']:.3f} from before, "
                  f"{frame['outside_vs_final']:.3f} from final, blank={frame['blank']}", flush=True)
        if bad:
            failures.append(f"Cmd-{key.upper()} run {run}")
        # Back to one workspace and tab: Cmd-W closes the new tab (and with it a new workspace).
        rpc("debug.key", {"key": "w", "modifiers": ["command"]})
        time.sleep(0.5)  # test harness wait

if failures:
    sys.exit(f"FAIL blank or intermediate frames: {', '.join(failures)}")
print("PASS no blank or intermediate frame")

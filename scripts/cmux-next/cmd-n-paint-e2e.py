#!/usr/bin/env python3
"""Cmd-N and Cmd-T paint stable on a running tagged build (bd cx-8g3sn).

A new workspace (Cmd-N) or tab (Cmd-T) opens on the New Tab page, the prewarmed spare handed
over (no page loads for it), with no blank or intermediate frame: the window as the window
server composited it, read frame after frame around the key (`debug.new_tab` frame_strip),
changes outside the pane's content area and its tab strip (whose tabs slide) in one step (each frame equals the one before the key
or the settled one), the content area too (Leo 2026-10-13: the New Tab frame drawn under the
adopted page showed one frame on another background), and the content area never turns one flat
color it was not before the key.
Fails on any such frame and prints where the frame strips are.

`--cold` (bd cx-ec99): the first Cmd-N goes the moment the app answers on its socket after launch,
with no wait for a ready spare, and its content area must never turn flat (the person sees the
New Tab page's frame, never an empty pane, while its page loads). Start this script before the app.

The app runs already (a capture slot: `capture-host launch`), with its debug socket.

Usage: cmd-n-paint-e2e.py --socket <path> [--runs 3] [--keys n,t] [--out DIR] [--cold]
"""
import argparse, json, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--keys", default="n,t", help="Command-<key> openings to check, comma separated")
parser.add_argument("--out", default="/tmp/cmd-n-paint", help="where the app writes each run's frames")
parser.add_argument("--duration-ms", type=float, default=700)
parser.add_argument("--cold", action="store_true", help="the first Cmd-N right after launch: no ready spare, no blank frame")
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
        if key == "t":
            # Cmd-T on a New Tab page only focuses it: open from a terminal tab (Control-`).
            rpc("debug.key", {"key": "`", "modifiers": ["control"]})
            time.sleep(1.0)  # test harness wait: the terminal tab shows
        cold = opts.cold and run == 0
        if cold:
            wait("the app's socket", lambda: "error" not in (rpc("debug.new_tab", {"action": "state"}, timeout=5) or {"error": "no reply"}), 60)
            rpc("debug.new_tab", {"action": "retarget"})
        else:
            wait(f"a ready spare before Cmd-{key.upper()}", spare_ready, 30)
            time.sleep(0.5)  # test harness wait: the window settles (caret, hover) before the strip
        openings = len((rpc("debug.new_tab", {"action": "state"}) or {}).get("openings") or [])
        out = f"{opts.out}/cmd-{key}-{run}"
        reply = rpc("debug.new_tab", {"action": "frame_strip", "key": key, "dir": out, "duration_ms": opts.duration_ms}) or {}
        if "error" in reply:
            sys.exit(f"FAIL frame_strip Cmd-{key.upper()}: {reply}")
        # Right after launch the sidebar may lead the content by a frame; the pane must never be empty.
        bad = [f for f in reply["frames"] if f["blank"] or ((f["intermediate"] or f.get("content_intermediate")) and not cold)]
        # The page is the prewarmed spare, handed over, not a page loaded for this opening.
        recorded = (rpc("debug.new_tab", {"action": "state"}) or {}).get("openings") or []
        opening = recorded[-1] if len(recorded) > openings else {}
        if not opening.get("spare") and not cold:
            failures.append(f"Cmd-{key.upper()} run {run} (no spare adopted: {opening or 'no opening'})")
        print(f"Cmd-{key.upper()} run {run}{' (cold)' if cold else ''}: spare={bool(opening.get('spare'))} {reply['frame_count']} frames every {reply['mean_interval_ms']:.1f} ms, "
              f"intermediate={reply['intermediate']:.0f} content_intermediate={reply.get('content_intermediate', 0):.0f} "
              f"strip_motion={reply.get('strip_intermediate', 0):.0f} "
              f"blank={reply['blank']:.0f} strip={out}/strip.png", flush=True)
        if reply.get("spans"):
            print("  marks: " + ", ".join(f"{span['name']} {span['ms']:+.0f} ms" for span in reply["spans"]), flush=True)
        for frame in bad:
            print(f"  {frame['file']} at {frame['ms']:+.0f} ms: outside differs {frame['outside_vs_before']:.3f} from before, "
                  f"{frame['outside_vs_final']:.3f} from final, content between={frame.get('content_intermediate')}, blank={frame['blank']}", flush=True)
        if bad:
            failures.append(f"Cmd-{key.upper()} run {run}")
        # Back to one workspace and tab: Cmd-W closes the new tab (and with it a new workspace).
        rpc("debug.key", {"key": "w", "modifiers": ["command"]})
        time.sleep(0.5)  # test harness wait

if failures:
    sys.exit(f"FAIL blank or intermediate frames: {', '.join(failures)}")
print("PASS no blank or intermediate frame")

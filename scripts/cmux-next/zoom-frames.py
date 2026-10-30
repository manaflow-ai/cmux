#!/usr/bin/env python3
"""Zoom and unzoom frame budget on a running tagged app (slot tier).

Builds a 2x2 grid, a 3x3 grid and a deep chain of alternating splits, each in
a fresh workspace, then zooms and unzooms the focused pane several times. For
each one it reports the display's missed vsyncs and frame intervals
(`debug.frames`) and the layout's main-thread work per frame (`debug.motion`
`work.layout`). Leo 2026-10-13's budget: 0 missed frames at 120 Hz and under
4 ms of main-thread work per frame.

Usage: zoom-frames.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--repeat 5] [--json OUT]
Exit 1 when a run misses the budget (with --strict).
"""
import argparse, json, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--repeat", type=int, default=5)
parser.add_argument("--json")
parser.add_argument("--strict", action="store_true", help="exit 1 when a run misses the budget")
parser.add_argument("--layout", action="append", default=[], help="2x2, 3x3 or chain (default: all)")
opts = parser.parse_args()


def rpc(method, params=None, timeout=30):
    """One request on the app's control socket (line JSON)."""
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


def action(name, settle=0.8):
    reply = rpc("action.run", {"action": name})
    time.sleep(settle)  # test harness: the layout settles before the next step
    return reply


def grid(rows, columns):
    """Columns by splitting right, then rows in each column, all equal."""
    for _ in range(columns - 1):
        action("splitRight")
    for column in range(columns):
        for _ in range(rows - 1):
            action("splitDown")
        for _ in range(rows - 1):
            action("focusUp", 0.3)
        if column < columns - 1:
            action("focusLeft", 0.3)
    action("equalizeSplits")
    # The pane to zoom: top-left in a 2x2 (its opposite corner is bottom-right), the center in a 3x3.
    if rows == 3:
        action("focusRight", 0.3)
        action("focusDown", 0.3)


def chain(depth=6):
    for index in range(depth):
        action("splitRight" if index % 2 == 0 else "splitDown")


LAYOUTS = {"2x2": lambda: grid(2, 2), "3x3": lambda: grid(3, 3), "chain": chain}


def measure(name):
    rpc("debug.motion", {"action": "speed", "value": "fast"})
    rpc("debug.motion", {"action": "start"})
    rpc("debug.frames", {"action": "start"})
    reply = rpc("action.run", {"action": "toggleSplitZoom"})
    time.sleep(0.9)  # test harness: the zoom settles (rest is under 0.4 s)
    frames = rpc("debug.frames", {"action": "stop"})
    motion = rpc("debug.motion", {"action": "stop"})
    work = (motion.get("work") or {}).get("layout", {}) if isinstance(motion, dict) else {}
    spans = [s for s in (motion.get("spans") or []) if s.get("name") == "layout"] if isinstance(motion, dict) else []
    return {"name": name, "action": reply, "frames": frames, "work": work, "layout_spans_ms": [s.get("ms") for s in spans],
            "speed": motion.get("speed") if isinstance(motion, dict) else None}


results, failed = [], False
for layout in opts.layout or list(LAYOUTS):
    rpc("action.run", {"action": "workspace.newAtBottom"})
    time.sleep(1.0)  # test harness: the workspace settles
    LAYOUTS[layout]()
    for attempt in range(opts.repeat):
        for name in ("zoom", "unzoom"):
            run = measure(f"{layout}/{name}#{attempt + 1}")
            frames, work = run["frames"] if isinstance(run["frames"], dict) else {}, run["work"]
            ok = frames.get("missed", 1) == 0 and work.get("max_ms", 99) < 4
            failed |= not ok
            results.append(run)
            print(f"{run['name']:>16}  refresh {frames.get('refresh_ms', 0):.2f} ms  missed {frames.get('missed')}  "
                  f"p99 {frames.get('p99_ms', 0):.2f} ms  max {frames.get('max_ms', 0):.2f} ms  "
                  f"layout work p50 {work.get('p50_ms')} p95 {work.get('p95_ms')} max {work.get('max_ms')} ms "
                  f"({work.get('frames')} frames)  span {run['layout_spans_ms']}  {'ok' if ok else 'OVER'}", flush=True)
            time.sleep(0.4)  # test harness: idle between runs

if opts.json:
    with open(opts.json, "w") as handle:
        json.dump(results, handle, indent=1)
sys.exit(1 if failed and opts.strict else 0)

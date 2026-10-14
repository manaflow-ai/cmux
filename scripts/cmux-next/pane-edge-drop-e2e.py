#!/usr/bin/env python3
"""Live check: a tab dropped at once on a pane's bottom edge splits the pane below (cx-jin7d).

The golden split-drag case `edge.new-split-below` (classic's bonsplit passes it): a tab dragged
from the strip to a pane's bottom edge band and released there makes a new pane below with
that tab. cmux NEXT used to join the pane instead unless the pointer rested on the edge for
`tabDrag.splitDwell`; the dwell is opt-in (default 0) since cx-imr7n.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket, opens a workspace with two terminal tabs and splits it right (`action.run`), the
golden case's layout, drags the left pane's second tab with `debug.mouse` at hand pace (0.7 s, one move per frame) to 90% down
the right pane and releases on arrival, then reads the strips (`debug.tab_drag`) and pane borders (`debug.pane_chrome`). It
never launches or quits the app.

Usage: pane-edge-drop-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock
Exit status 0 when every check passes.
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
ROWS = []


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


def action(name, args=None, focus=False):
    return rpc("action.run", {"action": name, "args": args or {}, "focus": focus})


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def strips():
    """The first window's visible strips (debug.mouse coordinates)."""
    windows = (rpc("debug.windows") or {}).get("windows") or []
    first = windows[0].get("id") if windows else None
    return [s for s in (rpc("debug.tab_drag") or {}).get("strips") or [] if first is None or s.get("window") == first]


def border(pane):
    for window in (rpc("debug.pane_chrome") or {}).get("windows") or []:
        for entry in window.get("panes") or []:
            if entry.get("pane") == pane:
                return entry.get("border")
    return None


def center(frame):
    x, y, w, h = frame
    return x + w / 2, y + h / 2


def mouse(**params):
    return rpc("debug.mouse", params)


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def two_tab_strip():
    """A shown workspace whose only pane has two tabs; returns that strip."""
    print("newTab (workspace):", action("newTab", focus=True), flush=True)
    single = wait(lambda: [s for s in strips() if len(s.get("tabs") or []) == 1] and len(strips()) == 1, 15)
    if not single:
        sys.exit(f"no single-pane workspace: {json.dumps(strips())[:600]}")
    print("newSurface:", action("newSurface", focus=True), flush=True)
    found = wait(lambda: next((s for s in strips() if len(s.get("tabs") or []) == 2), None), 15)
    if not found or len(strips()) != 1:
        sys.exit(f"no pane with two tabs: {json.dumps(strips())[:600]}")
    time.sleep(1)  # test harness: the strip settles
    return found


def paced_drag(x, y, to_x, to_y, seconds=0.7):
    """A drag at hand pace, as the golden case's real HID one (0.7 s): one `debug.mouse` move
    per display frame along a straight line, released where it arrives (a burst of events in
    one call reaches the drop all at once, which a hand never does)."""
    frames = max(2, int(seconds * 60))
    if "error" in (mouse(action="drag", x=x, y=y, to_x=x, to_y=y, steps=1, release=False) or {}):
        sys.exit("debug.mouse could not press")
    last, released = (x, y), False
    try:
        for frame in range(1, frames + 1):
            point = (x + (to_x - x) * frame / frames, y + (to_y - y) * frame / frames)
            reply = mouse(action="drag", x=last[0], y=last[1], to_x=point[0], to_y=point[1], steps=1, press=False,
                          release=frame == frames)
            if "error" in (reply or {}):
                sys.exit(f"debug.mouse failed mid-drag: {reply}")
            released, last = frame == frames, point
            time.sleep(1 / 60)  # test harness: pointer pace
    finally:
        if not released:  # never leave the button down for the next script on the slot
            mouse(action="drag", x=last[0], y=last[1], to_x=last[0], to_y=last[1], steps=1, press=False)
    return {"frames": frames}


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    two_tab_strip()
    # The golden case's layout: two panes side by side, the left one with two tabs.
    print("splitRight:", action("splitRight", focus=True), flush=True)
    pair = wait(lambda: (lambda ss: ss if len(ss) == 2 and sorted(len(s.get("tabs") or []) for s in ss) == [1, 2] else None)(strips()), 15)
    if not pair:
        sys.exit(f"no side-by-side pair: {json.dumps(strips())[:600]}")
    time.sleep(1)  # test harness: the split settles
    source = next(s for s in pair if len(s["tabs"]) == 2)
    target = next(s for s in pair if len(s["tabs"]) == 1)
    rect = border(target.get("pane"))
    if not rect:
        sys.exit(f"no content border for pane {target.get('pane')}")
    x, y, w, h = rect
    sx, sy = center(source["tabs"][1]["frame"])
    ex, ey = x + w / 2, y + h * 0.9  # the golden case's point: 90% down the other pane
    print("drag to the other pane's bottom edge at hand pace:", paced_drag(sx, sy, ex, ey), flush=True)
    wait(lambda: len(strips()) == 3, 10)
    after = strips()
    panes = [border(s.get("pane")) for s in after]
    # The new pane: neither the source nor the target, under the target, holding the one moved tab.
    new = [s for s in after if s.get("pane") not in (source.get("pane"), target.get("pane"))]
    moved = new[0] if len(new) == 1 else {}
    split_rect, target_rect = border(moved.get("pane")), border(target.get("pane"))
    ok = (len(after) == 3 and bool(split_rect) and bool(target_rect) and split_rect[1] > target_rect[1]
          and len(moved.get("tabs") or []) == 1 and all(len(s.get("tabs") or []) == 1 for s in after))
    row("a drop on another pane's bottom edge splits it", "a new pane below the target with the moved tab",
        f"panes {len(panes)}: {panes}; new {split_rect} below target {target_rect}", ok)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "pane-edge-drop.png")})

main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)

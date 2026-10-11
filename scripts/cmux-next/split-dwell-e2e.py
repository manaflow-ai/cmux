#!/usr/bin/env python3
"""Live check of the drag-to-split dwell (cmuxterm-hq#1829, cx-jfo7) on a running tagged cmux-next build.

A tab dragged onto a pane's edge splits that pane only once the pointer has rested on the edge
for the split dwell (`tabDrag.splitDwell`); before that the drop joins the pane, so a quick
drag that passes or touches an edge does not split. A pointer held still on the edge sees the
split preview once the dwell passes, and its release splits.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket, opens a workspace with two terminal tabs (`action.run`),
reads the strip's tabs (`debug.tab_drag`) and the pane's content border (`debug.pane_chrome`),
drags the second tab with `debug.mouse` (held open with `release: false`), and reads the drag's
preview (`debug.tab_drag` `winner`). It never launches or quits the app.

Usage: split-dwell-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
ROWS = []
DWELL = 0.25  # tabDrag.splitDwell's default


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


def winner():
    return str((rpc("debug.tab_drag") or {}).get("winner"))


def splits(text):
    return "newSplit" in text or "newColumn" in text


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


def edge_point(strip):
    rect = border(strip.get("pane"))
    if not rect:
        sys.exit(f"no content border for pane {strip.get('pane')}")
    x, y, w, h = rect
    return x + w - 20, y + h / 2


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)

    # A quick drag onto the pane's right edge, released at once, joins the pane: no split.
    strip = two_tab_strip()
    sx, sy = center(strip["tabs"][1]["frame"])
    ex, ey = edge_point(strip)
    print("quick drag:", mouse(action="drag", x=sx, y=sy, to_x=ex, to_y=ey, steps=12), flush=True)
    time.sleep(1.5)  # test harness: a split would show by now
    panes = len(strips())
    row("a quick drop on a pane's edge does not split it", "still one pane", f"panes {panes}", panes == 1)

    # The same drag held on the edge: the preview joins at first, splits after the dwell,
    # and the release splits the pane.
    strip = two_tab_strip()
    sx, sy = center(strip["tabs"][1]["frame"])
    ex, ey = edge_point(strip)
    mouse(action="drag", x=sx, y=sy, to_x=ex, to_y=ey, steps=12, release=False)
    # The posted events reach the drag shortly after debug.mouse answers: the first preview.
    early = str(wait(lambda: (lambda w: w if w != "None" else None)(winner()), 2, step=0.02))
    time.sleep(DWELL + 0.5)  # test harness: rest past the dwell
    late = winner()
    print("release:", mouse(action="drag", x=ex, y=ey, to_x=ex, to_y=ey, steps=1, press=False), flush=True)
    split = wait(lambda: len(strips()) == 2, 10)
    row("a pointer on a pane's edge previews a join before the dwell", "winner joins the pane (a strip)",
        f"winner {early}", early.startswith("strip(") and not splits(early))
    row("held past the dwell, the edge previews a split and the release splits", "winner newSplit; two panes",
        f"winner {late}; panes {len(strips())}", splits(late) and bool(split))
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "split-dwell.png")})


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)

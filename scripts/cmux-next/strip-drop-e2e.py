#!/usr/bin/env python3
"""Live check: a tab dropped on another pane's strip lands on the side of the tab the pointer is on (cx-6ggef).

The golden split-drag case `move.to-other-pane` (classic's bonsplit passes it): a tab dragged
from one pane onto the right end of the other pane's last tab lands after that tab, and on its
left end, before it. cmux NEXT took the drop point for the middle of a phantom tab as wide as the
strip's standard width, so most of a narrow tab (and the gap past it) read as "before".

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket, opens a workspace with three terminal tabs and splits it
right (`action.run`), then drags a left tab with paced `debug.mouse` moves (0.7 s, one per
frame) onto the right pane's tab, at 85% of its width and then (with another left tab) at 15%,
and reads the tab order of the right pane (`snapshot.get`); then again with one-letter tab titles
(`renameTab`), whose tabs draw narrower than the strip's even share. It never launches or quits the app.

Usage: strip-drop-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock
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


def tab_ids(pane):
    """The tab ids of `pane`, in strip order (snapshot.get)."""
    topo = (rpc("snapshot.get") or {}).get("topology") or {}
    return [t["id"] for w in topo.get("workspaces") or [] for sc in w.get("screens") or [] for p in sc.get("panes") or []
            if p.get("id") == pane for t in p.get("tabs") or []]


def drop_on(source_pane, target_pane, fraction):
    """Drags the first tab of `source_pane` onto the first tab of `target_pane`, at `fraction` of its
    width; returns (moved id, target tab id, the target's tabs after)."""
    by_pane = {s.get("pane"): s for s in strips()}
    source, target = by_pane[source_pane], by_pane[target_pane]
    moved, anchor = tab_ids(source_pane)[0], tab_ids(target_pane)[0]
    sx, sy = center(source["tabs"][0]["frame"])
    tx, ty, tw, th = target["tabs"][0]["frame"]
    paced_drag(sx, sy, tx + tw * fraction, ty + th / 2)
    wait(lambda: moved in tab_ids(target_pane), 10)
    time.sleep(0.5)  # test harness: the strip settles
    return moved, anchor, tab_ids(target_pane)


def rename(tab, name):
    rpc("action.run", {"action": "renameTab", "args": {"name": name}, "target": f"tab:{tab}"})


def drops(short):
    """One workspace's two drops; `short` renames the tabs to one letter, so the target tab is
    narrower than the strip's even share (its title fits it)."""
    label = " (one-letter titles)" if short else ""
    two_tab_strip()
    print("newSurface:", action("newSurface", focus=True), flush=True)
    wait(lambda: any(len(s.get("tabs") or []) == 3 for s in strips()), 15)
    print("splitRight:", action("splitRight", focus=True), flush=True)
    pair = wait(lambda: (lambda ss: ss if len(ss) == 2 and sorted(len(s.get("tabs") or []) for s in ss) == [1, 3] else None)(strips()), 15)
    if not pair:
        sys.exit(f"no side-by-side pair: {json.dumps(strips())[:600]}")
    source = next(s for s in pair if len(s["tabs"]) == 3)["pane"]
    target = next(s for s in pair if len(s["tabs"]) == 1)["pane"]
    if short:
        for tab, name in zip(tab_ids(source) + tab_ids(target), ["A", "B", "C", "T"]):
            rename(tab, name)
    time.sleep(1)  # test harness: the split and titles settle
    print("target tab:", next(s for s in strips() if s.get("pane") == target)["tabs"][0]["frame"], flush=True)

    moved, anchor, after = drop_on(source, target, 0.85)
    row("a drop on the right end of the other pane's tab lands after it" + label, f"[{anchor[-6:]}, {moved[-6:]}]",
        [t[-6:] for t in after], after == [anchor, moved])

    moved, anchor, after = drop_on(source, target, 0.15)
    row("a drop on the left end of the other pane's first tab lands before it" + label, f"{moved[-6:]} first, then {anchor[-6:]}",
        [t[-6:] for t in after], after[:2] == [moved, anchor])


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    drops(short=False)
    drops(short=True)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "strip-drop.png")})

main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)

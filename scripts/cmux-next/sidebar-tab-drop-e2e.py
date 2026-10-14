#!/usr/bin/env python3
"""Live check: a tab dropped on a sidebar workspace row moves into that workspace (cx-8g6ez).

The golden split-drag case `workspace.via-sidebar` (classic passes it): a tab dragged from a
pane's strip onto the center of another workspace's sidebar row joins that workspace. On the
way the pointer crosses the slot between that row and the one above it; on cmux NEXT that
slot used to open a new-workspace gap at once, which slid the row down out from under the
pointer, so the drop on the row's old center made a new workspace.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket, opens a target workspace and a source workspace with
two terminal tabs (`action.run`), reads the strip (`debug.tab_drag`) and the sidebar rows
(`debug.sidebar_rows`), drags the source's second tab with `debug.mouse` through the slot
above the target row (a brief pass, as a hand crossing it) onto the row's center and releases,
then reads the workspaces (`snapshot.get`). It never launches or quits the app.

Usage: sidebar-tab-drop-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock
Exit status 0 when every check passes.
"""
import argparse, json, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", default="/tmp", help="unused; accepted for capture drivers")
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


def action(name, args=None, focus=True):
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


def created_workspace(reply):
    return next((c for c in (reply or {}).get("created") or [] if c.startswith("ws_")), None)


def workspaces():
    """Workspace id -> its tab ids (snapshot.get), in the first window."""
    topo = (rpc("snapshot.get") or {}).get("topology") or {}
    out = {}
    for w in topo.get("workspaces") or []:
        out[w["id"]] = [t["id"] for s in (w.get("screens") or [])[:1] for p in s.get("panes") or [] if not p.get("dock")
                        for t in p.get("tabs") or []]
    return out


def strips():
    windows = (rpc("debug.windows") or {}).get("windows") or []
    first = windows[0].get("id") if windows else None
    return [s for s in (rpc("debug.tab_drag") or {}).get("strips") or [] if first is None or s.get("window") == first]


def name_of(workspace):
    topo = (rpc("snapshot.get") or {}).get("topology") or {}
    return next((w.get("name") for w in topo.get("workspaces") or [] if w["id"] == workspace), None)


def sidebar_row(workspace):
    """The first window's sidebar row of `workspace` (by its name; the sidebar keys rows by
    another id): [x, y, w, h] in debug.mouse coordinates."""
    name = name_of(workspace)
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    for row in (windows[0].get("rows") or []) if windows else []:
        if name and row.get("title") == name and row.get("key", "").startswith("workspace("):
            f = row.get("window_frame") or {}
            return [f["x"], f["y"], f["width"], f["height"]]
    return None


def mouse(**params):
    return rpc("debug.mouse", params)


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    target = created_workspace(action("workspace.newAtBottom"))
    time.sleep(1.0)  # test harness: the workspace settles
    source = created_workspace(action("workspace.newAtBottom"))
    time.sleep(1.0)  # test harness: the workspace settles
    action("newSurface")
    if not (target and source):
        sys.exit("could not open the two workspaces")
    strip = wait(lambda: next((s for s in strips() if len(s.get("tabs") or []) == 2), None), 15)
    rect = wait(lambda: sidebar_row(target), 10)
    if not strip or not rect:
        rows = ((rpc("debug.sidebar_rows") or {}).get("windows") or [{}])[0].get("rows") or []
        sys.exit(f"no two-tab strip or no target row {target}: rows {[(r.get('key'), r.get('title')) for r in rows]}")
    before = workspaces()
    moving = strip["tabs"][1]
    x, y, w, h = moving["frame"]
    sx, sy = x + w / 2, y + h / 2
    rx, ry, rw, rh = rect
    cx, cy = rx + rw / 2, ry + rh / 2
    slot_y = ry + 2  # the slot between the target row and the row above it
    # Press on the tab, carry it into the sidebar through the slot above the target row
    # (a brief pass, 80 ms), then onto the row's center, and release there.
    mouse(action="drag", x=sx, y=sy, to_x=cx, to_y=slot_y, steps=12, release=False)
    time.sleep(0.08)  # test harness: a hand passing through the slot
    mouse(action="drag", x=cx, y=slot_y, to_x=cx, to_y=cy, steps=4, press=False, release=False)
    time.sleep(0.1)  # test harness: the pointer settles on the row
    mouse(action="drag", x=cx, y=cy, to_x=cx, to_y=cy, steps=1, press=False)
    after = wait(lambda: (lambda now: now if now != before else None)(workspaces()), 5) or workspaces()
    new = [w for w in after if w not in before]
    target_tabs = after.get(target, [])
    row("no new workspace", f"{len(before)} workspaces", f"{len(after)} workspaces, new {new}", not new)
    row("the tab joins the workspace whose row it was dropped on", f"{target} holds 2 tabs",
        f"{target} holds {len(target_tabs)}; source holds {len(after.get(source, []))}", len(target_tabs) == 2)


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)

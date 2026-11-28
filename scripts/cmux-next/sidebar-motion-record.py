#!/usr/bin/env python3
"""Record sidebar row motion on a running tagged cmux-next build (cx-bqm6).

Each scenario starts `debug.window_record` (the window as composited, one JPEG
per display frame plus frames.json), runs one sidebar change through the
control socket, and keeps the frames in OUT/<scenario>/. `sidebar.json` holds
the sidebar's width in window points, for cropping. Scenarios run with default
settings: new workspace, new workspace below, move workspace up and down, move
to a new group, group up, a row drag reorder and a drag onto a workspace
(`debug.mouse`). Show Tabs Under Workspaces is off by default, so it is turned
on only for the tab-row scenarios (a tab row insert, and a drag with a
workspace's tab rows on its card) and off again after them. The drag onto a
workspace runs last: its drop opens the new group's name editor. The setting
lives in the user's cmux.json, which a capture mini's slots share, so the
script sets it rather than toggling it, and unsets it at the start and the
end. The script attaches to an app already running (a capture slot's
`capture-host launch`, or a tagged build) through its debug socket and never
launches or quits it.

Strips: scripts/cmux-next/motion-frame-strip.py OUT SCENARIO [EVERY] [COUNT].

Usage: sidebar-motion-record.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock --out DIR [--only NAME ...]
"""
import argparse, json, os, re, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", required=True)
parser.add_argument("--only", action="append", default=[])
parser.add_argument("--seconds", type=float, default=1.5)
parser.add_argument("--reduce-motion", action="store_true", help="Reduce Motion on, in memory")
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


def action(name, target=None):
    params = {"action": name}
    if target:
        params["target"] = target
    return rpc("action.run", params)


def sidebar():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return windows[0] if windows else {}


def rows(kind):
    return [r for r in sidebar().get("rows") or [] if str(r.get("key", "")).startswith(kind + "(")]


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def center(row):
    frame = row.get("window_frame") or {}
    return frame.get("x", 0) + frame.get("width", 0) / 2, frame.get("y", 0) + frame.get("height", 0) / 2


def drag_onto(dragged, target):
    """Drags `dragged` down toward `target` a step at a time and releases
    once the card's head (the grabbed row, centred on the pointer) sits
    mid-row on a loose workspace, the band where a drop groups
    (SidebarGroupBand)."""
    x, y = center(dragged)
    _, target_y = center(target)
    to = target_y - 40
    rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": to, "steps": 20, "release": False})
    for _ in range(60):
        over = [r for r in sidebar().get("rows") or [] if str(r.get("key", "")).startswith("workspace(")
                and r.get("key") != dragged.get("key") and not r.get("group") and not r.get("suppressed")]
        hit = next((r for r in over if 0.4 <= (to - (r.get("window_frame") or {}).get("y", 0))
                    / max(1, (r.get("window_frame") or {}).get("height", 1)) <= 0.6), None)
        if hit:
            break
        rpc("debug.mouse", {"action": "drag", "x": x, "y": to, "to_x": x, "to_y": to + 2, "steps": 1, "press": False, "release": False})
        to += 2
    print(f"drag-onto: released at {to} over {hit and hit.get('title')}", flush=True)
    time.sleep(0.3)  # test harness: the onto highlight shows before the drop
    return rpc("debug.mouse", {"action": "up", "x": x, "y": to})


def record(name, trigger, seconds=None):
    seconds = seconds or opts.seconds
    if opts.only and name not in opts.only:
        return
    directory = os.path.join(opts.out, name)
    os.makedirs(directory, exist_ok=True)
    started = rpc("debug.window_record", {"dir": directory, "seconds": seconds})
    time.sleep(0.15)  # test harness: a few still frames before the change
    reply = trigger()
    time.sleep(seconds + 0.6)  # test harness: the recording stops by itself
    frames = len([f for f in os.listdir(directory) if f.endswith(".jpg")])
    print(f"{name}: {frames} frames; record={json.dumps(started)[:120]} reply={json.dumps(reply)[:160]}", flush=True)
    time.sleep(0.5)  # test harness: let the list settle before the next scenario


def set_tab_rows(on):
    """Show Tabs Under Workspaces on, or back to its default (off, the key
    unset). Set, not toggled: the cmux.json a capture mini's slots share
    may hold another run's choice."""
    if on:
        rpc("settings.set", {"path": "sidebar.showWorkspaceTabs", "value": True})
    else:
        rpc("settings.unset", {"path": "sidebar.showWorkspaceTabs"})
    wait(lambda: bool(rows("tab")) == on, 5)
    time.sleep(0.5)  # test harness: the list settles


def drag_reorder(suffix=""):
    """A loose workspace dropped between two others: a reorder."""
    workspace_rows = [r for r in rows("workspace") if not r.get("group")]
    if len(workspace_rows) >= 5:
        x, y = center(workspace_rows[1])
        to_y = (workspace_rows[4].get("window_frame") or {}).get("y", 0) - 2
        record("drag-reorder" + suffix, lambda: rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": to_y, "steps": 30}))
        time.sleep(0.5)  # test harness: the drop settles


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    os.makedirs(opts.out, exist_ok=True)
    # Capture slots can launch with ui.animationSpeed "off"; record at "fast" (in memory only).
    rpc("debug.motion", {"action": "speed", "value": "fast"})
    if opts.reduce_motion:
        rpc("debug.motion", {"action": "reduce", "value": True})
    set_tab_rows(False)  # the default
    action("workspace.selectFirst")
    while len(rows("workspace")) < 6:
        action("newTab")
        time.sleep(0.4)  # test harness: one workspace at a time
    action("workspace.selectFirst")
    time.sleep(1.0)  # test harness: the list settles
    frames = [r.get("window_frame") or {} for r in sidebar().get("rows") or []]
    width = max((f.get("x", 0) + f.get("width", 0) for f in frames), default=260) + 12
    with open(os.path.join(opts.out, "sidebar.json"), "w") as handle:
        json.dump({"width": width, "rows": sidebar().get("rows")}, handle)

    record("new-workspace", lambda: action("newTab"))
    record("new-workspace-below", lambda: (action("workspace.selectFirst"), action("workspace.newBelow"))[1])
    record("move-down", lambda: action("moveWorkspaceDown"))
    record("move-up", lambda: action("moveWorkspaceUp"))
    record("new-group", lambda: action("workspace.moveToNewGroup"))
    record("group-up", lambda: action("workspaceGroup.moveUp"))
    drag_reorder()
    # Tab rows only for these scenarios, and off again after them.
    set_tab_rows(True)
    try:
        action("workspace.selectFirst")
        time.sleep(0.5)  # test harness: selection settles
        record("new-tab-row", lambda: action("newSurface"))
        drag_reorder("-tab-rows")
    finally:
        set_tab_rows(False)
    # Last: a drop onto a workspace groups the two and opens the group's
    # name editor, which a scenario after it would record over.
    workspace_rows = [r for r in rows("workspace") if not r.get("group")]
    if len(workspace_rows) >= 4:
        record("drag-onto", lambda: drag_onto(workspace_rows[1], workspace_rows[3]), seconds=3)
    print("\nRESULT PASS (recorded)")


try:
    main()
finally:
    if opts.reduce_motion:
        rpc("debug.motion", {"action": "reduce", "value": None})

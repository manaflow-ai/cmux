#!/usr/bin/env python3
"""Record sidebar row motion on a running tagged cmux-next build (cx-bqm6).

Each scenario starts `debug.window_record` (the window as composited, one JPEG
per display frame plus frames.json), runs one sidebar change through the
control socket, and keeps the frames in OUT/<scenario>/. `sidebar.json` holds
the sidebar's width in window points, for cropping. Scenarios: new workspace,
new workspace below, a tab row insert (Show Tabs Under Workspaces on), move
workspace up and down, move to a new group, group up, and a row drag reorder
(`debug.mouse`). The script attaches to an app already running (a capture
slot's `capture-host launch`, or a tagged build) through its debug socket and
never launches or quits it.

Strips: scripts/cmux-next/motion-frame-strip.py OUT SCENARIO [EVERY] [COUNT].

Usage: sidebar-motion-record.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock --out DIR [--only NAME ...]
"""
import argparse, json, os, re, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", required=True)
parser.add_argument("--only", action="append", default=[])
parser.add_argument("--seconds", type=float, default=1.5)
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


def record(name, trigger):
    if opts.only and name not in opts.only:
        return
    directory = os.path.join(opts.out, name)
    os.makedirs(directory, exist_ok=True)
    started = rpc("debug.window_record", {"dir": directory, "seconds": opts.seconds})
    time.sleep(0.15)  # test harness: a few still frames before the change
    reply = trigger()
    time.sleep(opts.seconds + 0.6)  # test harness: the recording stops by itself
    frames = len([f for f in os.listdir(directory) if f.endswith(".jpg")])
    print(f"{name}: {frames} frames; record={json.dumps(started)[:120]} reply={json.dumps(reply)[:160]}", flush=True)
    time.sleep(0.5)  # test harness: let the list settle before the next scenario


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    os.makedirs(opts.out, exist_ok=True)
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
    if not rows("tab"):
        action("sidebar.workspaceTabs.toggle")
        time.sleep(1.0)  # test harness: tab rows appear
    action("workspace.selectFirst")
    time.sleep(0.5)  # test harness: selection settles
    record("new-tab-row", lambda: action("newSurface"))
    workspace_rows = rows("workspace")
    if len(workspace_rows) >= 3:
        x, y = center(workspace_rows[0])
        _, to_y = center(workspace_rows[2])
        record("drag-reorder", lambda: rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": to_y + 4, "steps": 30}))
    print("\nRESULT PASS (recorded)")


main()

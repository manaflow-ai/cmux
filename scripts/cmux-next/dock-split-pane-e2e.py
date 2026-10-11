#!/usr/bin/env python3
"""Live check that Dock Column works on a pane of a split (cx-39lm) on a running tagged cmux-next DEBUG build.

A screen stored as one split tree is its implicit column, which must keep scrolling, so Dock Column
(and Dock Column Left) moves the pane's tab into a new docked column. When that tab is its pane's
only tab, the move must be anchored at another pane of the column: the daemon refuses a pane's only
tab leaving through its own pane, and the action answered 'move-tab-to-column failed'.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket. For each action it opens a workspace (`action.run`),
splits it with Cmd-D (`debug.key`), runs the action on the new pane, and checks that the action
succeeds and that the tab now sits in a docked column (`column.undock` on its pane succeeds). It
never launches or quits the app.

Usage: dock-split-pane-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock
Exit status 0 when every check passes.
"""
import argparse, json, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
ROWS = []


def rpc(method, params=None, timeout=40):
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


def topology():
    snap = rpc("snapshot.get") or {}
    return (snap.get("topology") or snap) if isinstance(snap, dict) else {}


def focused_workspace():
    return (topology().get("focus") or {}).get("workspace")


def panes(workspace):
    """[(pane id, [tab ids])] of the workspace's screens."""
    for ws in topology().get("workspaces", []):
        if ws.get("id") == workspace:
            return [(p.get("id"), [t.get("id") for t in p.get("tabs", [])])
                    for screen in ws.get("screens", []) for p in screen.get("panes", [])]
    return []


def pane_of(workspace, tab):
    return next((pane for pane, tabs in panes(workspace) if tab in tabs), None)


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def dock_split_pane(action):
    print("new workspace:", json.dumps(rpc("action.run", {"action": "workspace.newAtBottom", "focus": True}))[:200], flush=True)
    workspace = wait(focused_workspace, 15)
    if not wait(lambda: len(panes(workspace)) == 1, 15):
        sys.exit(f"no single-pane workspace: {json.dumps(panes(workspace))[:600]}")
    print("split:", rpc("debug.key", {"key": "d", "modifiers": ["command"]}), flush=True)
    if not wait(lambda: len(panes(workspace)) == 2, 15):
        sys.exit(f"Cmd-D made no split: {json.dumps(panes(workspace))[:600]}")
    time.sleep(1.5)  # test harness: the split settles
    pane, tabs = panes(workspace)[-1]
    tab = tabs[0]
    ran = rpc("action.run", {"action": action, "target": f"pane:{pane}", "origin": "script"})
    print(f"{action}:", json.dumps(ran)[:400], flush=True)
    row(f"{action} on a split pane's only tab succeeds", "no error", json.dumps(ran.get("error"))[:200], "error" not in ran)
    moved = wait(lambda: (lambda p: p if p and p != pane else None)(pane_of(workspace, tab)), 10)
    undock = rpc("action.run", {"action": "column.undock", "target": f"pane:{moved or pane}", "origin": "script"})
    row(f"{action} leaves the tab in a docked column", "column.undock on its pane succeeds",
        f"pane {moved}: {json.dumps(undock.get('error'))[:200]}", bool(moved) and "error" not in undock)


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    for action in ("column.dock", "column.dockLeft"):
        dock_split_pane(action)
    rpc("debug.window_snapshot", {"path": f"{opts.out}/dock-split-pane.png"})


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)

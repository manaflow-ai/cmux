#!/usr/bin/env python3
"""Live check of rapid switching (briefs/rapid-switch-1009) on a running tagged cmux-next build.

Previous / Next on the browser-style keys: a focused pane with 2+ tabs steps its tabs, wrapping
inside the pane; any other focus (a 1-tab pane, a field, nothing) steps the sidebar rows. The
script attaches to an app already running (a capture slot's `capture-host launch`, or a tagged
build) through its debug socket, makes two workspaces, presses the real chords through
`debug.key` and reads the window's sidebar selection (`debug.sidebar_rows`) and the focused
pane's selected tab (`debug.surfaces`). With --tab-rows it also turns Show Tabs Under Workspaces
on and checks that Next walks a workspace's tab rows one at a time. It never launches or quits
the app.

Usage: rapid-switch-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--tab-rows", action="store_true",
                    help="also check that, with Show Tabs Under Workspaces on, Next walks a workspace's tab rows")
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


def wait(check, seconds, step=0.5):
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


def action(name, args=None):
    return rpc("action.run", {"action": name, "args": args or {}})


def key(name, modifiers):
    """A chord through the window's real key path; the reply names the action that took it."""
    reply = rpc("debug.key", {"key": name, "modifiers": modifiers})
    time.sleep(0.5)  # test harness: the switch settles
    return reply if isinstance(reply, dict) else {}


def sidebar():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return windows[0] if windows else {}


def selected():
    """The window's selected sidebar rows, or the active top item (Home, App Store)."""
    window = sidebar()
    active = [item.get("id") for item in window.get("items") or [] if item.get("active")]
    return tuple(window.get("selection") or []) or tuple(active)


def workspace_rows():
    return [row for row in sidebar().get("rows") or [] if str(row.get("key", "")).startswith("workspace(")]


def focused_pane():
    panes = [p for w in (rpc("debug.surfaces").get("windows") or []) for p in w.get("panes", [])]
    return next((p for p in panes if p.get("focused")), None) or {}


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def setup():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    before = len(workspace_rows())
    for _ in range(2):
        print("newTab:", action("newTab"), flush=True)
    if not wait(lambda: len(workspace_rows()) >= before + 2, 30):
        sys.exit(f"no new workspaces: {json.dumps(sidebar())[:800]}")
    # Show the first workspace with the keyboard in it: every new workspace holds one tab.
    action("selectWorkspaceByNumber", {"index": 1})
    wait(lambda: selected() and focused_pane().get("selected_tab"), 15)
    time.sleep(1)  # test harness: focus lands in the shown pane


def tab_rows():
    """Next from a 1-tab pane stops at each listed tab row: a workspace split into two 1-tab
    panes is two stops, not one."""
    if not any(str(r.get("key", "")).startswith("tab(") for r in sidebar().get("rows") or []):
        print("workspace tabs toggle:", action("sidebar.workspaceTabs.toggle"), flush=True)
    if not wait(lambda: any(str(r.get("key", "")).startswith("tab(") for r in sidebar().get("rows") or []), 15):
        row("tab rows listed", "Show Tabs Under Workspaces lists tab rows", "no tab rows", False)
        return
    action("selectWorkspaceByNumber", {"index": 2})
    wait(lambda: focused_pane().get("selected_tab"), 15)
    split = selected()
    print("splitRight:", action("splitRight"), flush=True)
    wait(lambda: len([r for r in sidebar().get("rows") or [] if str(r.get("key", "")).startswith("tab(")]) >= 4, 15)
    action("selectWorkspaceByNumber", {"index": 1})
    wait(lambda: selected() and selected() != split, 15)
    time.sleep(1)  # test harness: focus lands in the shown pane
    reply = key("}", ["cmd"])
    first = (selected(), focused_pane().get("selected_tab"))
    reply2 = key("}", ["cmd"])
    second = (selected(), focused_pane().get("selected_tab"))
    row("tab rows: Next lands on the split workspace", f"row {split}", f"action={reply.get('action')} {first}",
        first[0] == split)
    row("tab rows: Next walks to its other tab row", "same workspace, the other pane's tab",
        f"action={reply2.get('action')} {first} -> {second}", second[0] == split and second[1] != first[1])


def main():
    setup()
    if opts.tab_rows:
        tab_rows()
        action("selectWorkspaceByNumber", {"index": 1})
        time.sleep(1)  # test harness: focus lands in the shown pane
    start = selected()
    reply = key("}", ["cmd"])
    after = selected()
    row("1-tab pane: Cmd-Shift-] steps the sidebar", "navigate.next; another row selected",
        f"action={reply.get('action')} {start} -> {after}", reply.get("action") == "navigate.next" and after and after != start)
    reply = key("{", ["cmd"])
    back = selected()
    row("1-tab pane: Cmd-Shift-[ steps back", "navigate.previous; the first row again",
        f"action={reply.get('action')} {after} -> {back}", reply.get("action") == "navigate.previous" and back == start)

    print("newSurface:", action("newSurface"), flush=True)
    wait(lambda: focused_pane().get("selected_tab"), 15)
    time.sleep(1)  # test harness: the new tab takes focus
    workspace, first = selected(), focused_pane().get("selected_tab")
    tabs = [first]
    for _ in range(2):
        reply = key("}", ["cmd"])
        tabs.append(focused_pane().get("selected_tab"))
        row("2-tab pane: Cmd-Shift-] stays in the pane", "navigate.next; same row, the pane's other tab",
            f"action={reply.get('action')} row {workspace} -> {selected()} tab {tabs[-2]} -> {tabs[-1]}",
            reply.get("action") == "navigate.next" and selected() == workspace and tabs[-1] != tabs[-2])
    row("2-tab pane: Next wraps inside the pane", "two presses come back to the first tab", f"tabs {tabs}", tabs[2] == tabs[0])
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "rapid-switch.png")})


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)

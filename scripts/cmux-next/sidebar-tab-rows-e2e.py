#!/usr/bin/env python3
"""Live check of first-class sidebar tab rows (briefs/rapid-switch-1009 item 3) on a running tagged
cmux-next build.

With Show Tabs Under Workspaces on, a tab row's right-click opens the tab's menu, not its
workspace's, dragging a tab row onto the top edge of another tab row moves it before that tab,
and dragging a tab row onto the sidebar gap after its workspace moves that tab into a new
workspace. The script attaches to an app already running (a capture slot's
`capture-host launch`, or a tagged build) through its debug socket, makes a workspace with two
tabs, reads both rows' menus (`debug.sidebar_rows` `menu_x`/`menu_y`, the list's own menu path,
never shown), drags the second tab row with `debug.mouse` and reads the rows again. It never
launches or quits the app.

Usage: sidebar-tab-rows-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--out DIR]
Exit status 0 when every check passes.
"""
from collections import Counter
import argparse, json, os, re, socket, sys, time

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


def sidebar():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return windows[0] if windows else {}


def rows(kind):
    return [r for r in sidebar().get("rows") or [] if str(r.get("key", "")).startswith(kind + "(")]


def key_ids(row_):
    """(workspace, tab) ids from a row key: `tab(<ws>, <tab>)`, `workspace(<ws>)`, or their
    `WorkspaceID(rawValue: "…")` / `TabID(rawValue: "…")` spellings."""
    match = re.match(r'(?:tab|workspace)\((.*)\)$', str(row_.get("key", "")))
    parts = [re.sub(r'^\w+\(rawValue: "(.*)"\)$', r'\1', part.strip()) for part in match.group(1).split(",")] if match else []
    return (parts + [None, None])[:2]


def workspace_of(row_):
    return key_ids(row_)[0]


def tab_of(row_):
    return key_ids(row_)[1]


def center(row_):
    frame = row_.get("window_frame") or {}
    return frame.get("x", 0) + frame.get("width", 0) / 2, frame.get("y", 0) + frame.get("height", 0) / 2


def menu_at(row_):
    x, y = center(row_)
    return (rpc("debug.sidebar_rows", {"menu_x": x, "menu_y": y}) or {}).get("menu")


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def setup():
    """A shown workspace with two tabs, listed as two tab rows. Returns its id."""
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    if not rows("tab"):
        print("workspace tabs toggle:", action("sidebar.workspaceTabs.toggle"), flush=True)
    if not wait(lambda: rows("tab"), 15):
        sys.exit(f"no tab rows: {json.dumps(sidebar())[:800]}")
    print("newTab:", action("newTab"), flush=True)
    action("workspace.selectFirst")
    wait(lambda: sidebar().get("selection"), 15)
    counts = Counter(workspace_of(r) for r in rows("tab"))  # the selection names a row; ids come from row keys
    print("newSurface:", action("newSurface"), flush=True)
    grown = lambda: next((w for w, n in Counter(workspace_of(r) for r in rows("tab")).items() if n > counts[w] and n >= 2), None)
    shown = wait(grown, 15)
    if not shown:
        sys.exit(f"no workspace gained a second tab row: {[r.get('key') for r in rows('tab')]}")
    time.sleep(1)  # test harness: the list settles
    return shown


def main():
    shown = setup()
    tabs = [r for r in rows("tab") if workspace_of(r) == shown]
    workspace = next((r for r in rows("workspace") if workspace_of(r) == shown), None)
    tab_menu, workspace_menu = menu_at(tabs[-1]), workspace and menu_at(workspace)
    row("tab row right-click opens the tab's menu", "a menu unlike the workspace row's",
        f"tab={tab_menu} workspace={workspace_menu}", bool(tab_menu) and tab_menu != workspace_menu)

    # Reorder: the second tab row dropped on the first row's top edge goes before it.
    first, second = tab_of(tabs[0]), tab_of(tabs[1])
    x, y = center(tabs[1])
    top = tabs[0]["window_frame"]["y"] + tabs[0]["window_frame"]["height"] * 0.12
    print("reorder drag:", rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": top, "steps": 16}), flush=True)
    order = lambda: [tab_of(r) for r in rows("tab") if workspace_of(r) == shown]
    reordered = wait(lambda: order()[:2] == [second, first], 15)
    row("dragging a tab row onto another tab row's top edge moves it before that tab", f"{[second, first]} under {shown}",
        f"{order()}; tab {second} under {next((workspace_of(r) for r in rows('tab') if tab_of(r) == second), None)}", bool(reordered))
    time.sleep(1)  # test harness: the list settles
    tabs = [r for r in rows("tab") if workspace_of(r) == shown]

    dragged = tab_of(tabs[-1])
    before = {workspace_of(r) for r in rows("workspace")}
    ordered = sidebar().get("rows") or []
    index = next(i for i, r in enumerate(ordered) if r.get("key") == tabs[-1].get("key"))
    x, y = center(tabs[-1])
    bottom = tabs[-1]["window_frame"]["y"] + tabs[-1]["window_frame"]["height"]
    following = ordered[index + 1]["window_frame"]["y"] if index + 1 < len(ordered) else bottom + 8
    gap = (bottom + following) / 2
    print("drag:", rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": gap, "steps": 16}), flush=True)
    moved = wait(lambda: next((workspace_of(r) for r in rows("tab") if tab_of(r) == dragged and workspace_of(r) not in before), None), 15)
    row("dragging a tab row onto the gap makes a new workspace with that tab", f"tab {dragged} under a new workspace",
        f"now under {moved}; workspaces {len(before)} -> {len(rows('workspace'))}", moved is not None)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "sidebar-tab-rows.png")})


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)

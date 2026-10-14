#!/usr/bin/env python3
"""Live check of the sidebar's right-click group rows and of groups across a relaunch (cx-j0it1).

Lawrence 2026-10-14: "my groups UI is lost". PR #19754 moved the workspace menu's group rows
into More, and Move to Group (a choices submenu) was left out with zero groups. This script reads
each right-click menu through `debug.sidebar_rows {menu_x, menu_y}`: the titles the list's own
`menu(for:)` builds for a right-click at that row, without showing the menu. Then it runs the
rows' actions on the same targets the menu items carry.

  --phase setup   three new workspaces; with no group, the workspace menu has Move to Group with
                  New Group at its end and no Remove from Group; New Group makes a group of the
                  first workspace; the second workspace's Move to Group lists that group and
                  moves it in; the grouped row's menu has Remove from Group, the ungrouped one
                  does not; collapse hides the members, expand shows them. Writes --state.
  --phase verify  (after the app quit and launched again) the group from --state is listed with
                  both members in it, and Move to Group still lists it.

Attaches to an app already running (a tagged build) through its debug socket; never launches or
quits it. Window images come from `debug.window_snapshot` into --out.

Usage: sidebar-group-menu-live.py --socket /tmp/cmux-debug-<tag>.sock --phase setup|verify --state FILE [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--phase", choices=["setup", "verify"], required=True)
parser.add_argument("--state", required=True)
parser.add_argument("--out", default="/tmp")
parser.add_argument("--capture-pid", type=int, help="with $NX_CAPTURE: real right-clicks, captured with their open menu")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
ROWS = []
GROUP_NAME = f"Groups proof {int(time.time()) % 100000}"
NEW_GROUP, REMOVE, GROUP_SELECTED = "Move Workspace to New Group", "Remove Workspace from Group", "Group Selected Workspaces"


def move_row(top, subs):
    """The Move to Group row's title ("Move Workspace to Group"): a top-level submenu."""
    return next((t for t in top if "to Group" in t and t in subs), None)


def line_json(path, request, timeout):
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(timeout)
    conn.connect(path)
    conn.sendall((json.dumps(request) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = conn.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    conn.close()
    return json.loads(buf)


def rpc(method, params=None, timeout=30):
    try:
        reply = line_json(opts.socket, {"id": 1, "method": method, "params": params or {}}, timeout)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def action(name, args=None, target=None, focus=True):
    params = {"action": name, "args": args or {}, "focus": focus}
    if target:
        params["target"] = target
    return rpc("action.run", params)


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


def rows():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return (windows[0].get("rows") or []) if windows else []


def key_id(key):
    key = str(key)
    return key[key.find("(") + 1:key.rfind(")")].strip('"') if "(" in key else key


def row_by_id(sidebar_id):
    return next((r for r in rows() if str(r.get("key", "")).startswith("workspace(") and key_id(r["key"]) == sidebar_id), None)


def header(group):
    return next((r for r in rows() if str(r.get("key", "")).startswith("group(") and group in str(r.get("key"))), None)


def shown(sidebar_id):
    r = row_by_id(sidebar_id)
    return bool(r) and r.get("in_list") is not False and not r.get("suppressed")


def menu_at(r):
    """The right-click menu at the row's center: top-level titles and each submenu's titles."""
    frame = r["window_frame"]
    reply = rpc("debug.sidebar_rows", {"menu_x": frame["x"] + frame["width"] / 2, "menu_y": frame["y"] + frame["height"] / 2}) or {}
    return reply.get("menu") or [], reply.get("submenus") or {}


def check(name, expected, observed, ok):
    ROWS.append(bool(ok))
    print(f"{'PASS' if ok else 'FAIL'} | {name} | {expected} | {observed}", flush=True)


def right_click_shot(r, name):
    """A real right-click on the row (debug.mouse), its open menu captured by $NX_CAPTURE, then Escape."""
    capture = os.environ.get("NX_CAPTURE")
    if not (capture and opts.capture_pid and r):
        return
    frame = r["window_frame"]
    rpc("debug.mouse", {"x": frame["x"] + frame["width"] / 2, "y": frame["y"] + frame["height"] / 2, "action": "click", "button": "right"}, timeout=5)
    time.sleep(1.5)  # test harness: the menu opens
    try:
        shot = subprocess.run(["bash", capture, "shot", "--pid", str(opts.capture_pid), "--with-popups", "--out", os.path.join(opts.out, f"{name}.png")],
                              capture_output=True, text=True, timeout=60)
        if shot.returncode:
            print(f"WARN | capture {name} exit {shot.returncode}: {shot.stderr.strip()[:200]}", flush=True)
    except subprocess.TimeoutExpired:
        print(f"WARN | capture {name} timed out", flush=True)
    rpc("debug.key", {"key": "escape"}, timeout=5)
    time.sleep(0.8)  # test harness: the menu closes


def snapshot(name):
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{name}.png")})


def workspace_keys():
    return {r["key"] for r in rows() if str(r.get("key", "")).startswith("workspace(")}


def new_workspace():
    """A new workspace at the bottom of the list: its sidebar id (the row that was not there)."""
    before = workspace_keys()
    action("workspace.newAtBottom")
    wait(lambda: workspace_keys() - before, 20)
    time.sleep(1.5)  # test harness: a placeholder row takes the workspace's id once the daemon lists it
    made = wait(lambda: workspace_keys() - before, 10)
    if not made:
        sys.exit("no new workspace row")
    return key_id(sorted(made)[0])


def setup():
    w1, w2, w3 = new_workspace(), new_workspace(), new_workspace()
    print("workspaces:", w1, w2, w3, flush=True)
    has_groups = any(str(r.get("key", "")).startswith("group(") for r in rows())

    top, subs = menu_at(row_by_id(w1))
    move = move_row(top, subs)
    print("workspace menu (ungrouped):", top, subs.get(move), flush=True)
    check("An ungrouped workspace's menu has Move to Group at the top level", "Move Workspace to Group", top, move is not None)
    check("Move to Group ends with New Group" + ("" if has_groups else " (zero groups)"), NEW_GROUP,
          subs.get(move), (subs.get(move) or [None])[-1] == NEW_GROUP)
    check("An ungrouped workspace's menu has no Remove from Group", f"no {REMOVE}", top, REMOVE not in top)
    check("One selected workspace: no Group Selected Workspaces", f"no {GROUP_SELECTED}", top, GROUP_SELECTED not in top)
    snapshot("1-ungrouped")
    right_click_shot(row_by_id(w1), "menu-1-zero-groups")

    # New Group, as the trailer row runs it (a name skips the name editor).
    print("New Group:", action("workspace.moveToNewGroup", {"name": GROUP_NAME}, target=f"workspace:{w1}"), flush=True)
    group = wait(lambda: (row_by_id(w1) or {}).get("group"), 10)
    check("New Group puts the workspace in a new group", "a group", group, bool(group) and header(group) is not None)
    if not group:
        return None

    top, subs = menu_at(row_by_id(w2))
    listed = subs.get(move_row(top, subs)) or []
    check("Move to Group lists the new group, then New Group", f"[... {GROUP_NAME}, -, {NEW_GROUP}]", listed,
          GROUP_NAME in listed and listed[-1] == NEW_GROUP)
    print("Move to Group:", action("moveWorkspaceToGroup", {"group": group}, target=f"workspace:{w2}"), flush=True)
    moved = wait(lambda: (row_by_id(w2) or {}).get("group") == group, 10)
    check("Move to Group > the group moves the workspace in", group, (row_by_id(w2) or {}).get("group"), moved)

    top, subs = menu_at(row_by_id(w1))
    check("A grouped workspace's menu has Remove from Group at the top level", REMOVE, top, REMOVE in top)
    own = subs.get(move_row(top, subs)) or []
    check("A grouped workspace's Move to Group does not list its own group", f"no {GROUP_NAME}", own, GROUP_NAME not in own)
    top, _ = menu_at(row_by_id(w3))
    check("An ungrouped workspace's menu still has no Remove from Group", f"no {REMOVE}", top, REMOVE not in top)

    snapshot("2-grouped")
    right_click_shot(row_by_id(w1), "menu-2-grouped-row")
    right_click_shot(row_by_id(w3), "menu-3-ungrouped-row")
    target = f"workspace-group:{group}"
    action("workspaceGroup.collapse", target=target)
    check("Collapse hides the group's workspaces", "both members hidden",
          [shown(w1), shown(w2)], wait(lambda: not shown(w1) and not shown(w2), 10))
    snapshot("3-collapsed")
    action("workspaceGroup.expand", target=target)
    check("Expand shows them again", "both members shown", [shown(w1), shown(w2)], wait(lambda: shown(w1) and shown(w2), 10))
    titles = [(row_by_id(w) or {}).get("title") for w in (w1, w2)]
    return {"group": group, "name": GROUP_NAME, "members": [w1, w2], "titles": titles, "outside": w3}


def verify():
    """After a relaunch: the group's header is listed and its members (by title; ids may be new) are in it."""
    with open(opts.state) as f:
        state = json.load(f)
    group, titles, name = state["group"], state["titles"], state["name"]
    check("After a relaunch the group is listed", f"header {group}", bool(wait(lambda: header(group), 30)), header(group) is not None)
    def members():
        return sorted(str(r.get("title")) for r in rows() if str(r.get("key", "")).startswith("workspace(") and r.get("group") == group)
    ok = wait(lambda: members() == sorted(str(t) for t in titles), 15)
    check("After a relaunch both workspaces are in the group", sorted(titles), members(), ok)
    outside = next((r for r in rows() if str(r.get("key", "")).startswith("workspace(") and r.get("group") is None), None)
    top, subs = menu_at(outside) if outside else ([], {})
    listed = subs.get(move_row(top, subs)) or []
    check("After a relaunch Move to Group still lists the group", name, listed, name in listed)
    snapshot("4-relaunched")


if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 90):
    sys.exit("the app does not answer on " + opts.socket)
time.sleep(2)  # test harness: the restored sidebar settles after launch
if opts.phase == "setup":
    state = setup()
    if state:
        with open(opts.state, "w") as f:
            json.dump(state, f)
else:
    verify()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)

#!/usr/bin/env python3
"""Live check of New Workspace Like This (cmuxterm-hq#1829, cx-rrvi) on a running tagged cmux-next build.

`workspace.newLikeThis` opens a workspace like the target one: in its directory, right below it
(so in its group) and with a first tab of the same kind (a terminal, or the New Tab page). It
folds New Workspace in This Group and in Same Directory: their ids still run it, and a workspace
row's New menu offers New Workspace Like This in their place.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket. It runs actions the way the palette does (`action.run`),
presses Cmd-N as the user does (`debug.key`: a person's new workspace opens on the New Tab page),
reads workspaces and tabs through the daemon socket's `list-workspaces`, the sidebar order and a
row's menu through `debug.sidebar_rows`, and asks the app whether the focused tab is the New Tab
page (`debug.new_tab` `field`; the page is a daemon browser tab too). It never launches or quits
the app.

Usage: new-workspace-like-this-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--daemon-socket PATH] [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--daemon-socket", help="the app's daemon socket (default: derived from --socket)")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
ROWS = []


def line_json(path, request, timeout):
    """One line-JSON request and its reply line."""
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
    """One request on the app's control socket (line JSON)."""
    try:
        reply = line_json(opts.socket, {"id": 1, "method": method, "params": params or {}}, timeout)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def action(name, args=None, focus=False, target=None):
    params = {"action": name, "args": args or {}, "focus": focus}
    if target:
        params["target"] = target
    return rpc("action.run", params)


def daemon_socket():
    if opts.daemon_socket:
        return opts.daemon_socket
    temp = os.environ.get("TMPDIR") or subprocess.run(
        ["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    session = os.path.basename(opts.socket).replace("cmux-debug-", "cmux-app-", 1)
    return os.path.join(temp, f"cmux-tui-{os.getuid()}", session)


def workspaces():
    snapshot = line_json(daemon_socket(), {"id": 1, "cmd": "list-workspaces"}, 30)
    return (snapshot.get("data") or {}).get("workspaces") or []


def ids(entry):
    """Every string id the daemon gives a workspace (the sidebar keys rows by one of them)."""
    return {v for k, v in entry.items() if isinstance(v, str) and ("id" in k or k == "key") and v}


def first_tab(entry):
    for screen in entry.get("screens") or []:
        for pane in screen.get("panes") or []:
            for tab in pane.get("tabs") or []:
                return tab
    return None


def new_workspaces(before):
    return [w for w in workspaces() if not ids(w) & before]


def known():
    return set().union(*(ids(w) for w in workspaces()))


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


def workspace_rows():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    rows = windows[0].get("rows") or [] if windows else []
    return [r for r in rows if str(r.get("key", "")).startswith("workspace(")]


def row_index(entry, rows):
    return next((i for i, r in enumerate(rows) if any(i_d in str(r.get("key")) for i_d in ids(entry))), None)


def shows_new_tab_page():
    return "error" not in (rpc("debug.new_tab", {"action": "field"}) or {"error": True})


def target_of(entry):
    """An action target for a workspace: its public id."""
    return "workspace:" + next((v for v in sorted(ids(entry)) if v.startswith("ws_")), sorted(ids(entry))[0])


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def like_this(anchor, name="workspace.newLikeThis", focus=False):
    before = known()
    reply = action(name, focus=focus, target=target_of(anchor))
    made = wait(lambda: new_workspaces(before), 20)
    return reply, (made or [None])[0]


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)

    # A terminal workspace in a group, with another workspace below it in that group.
    before = known()
    print("workspace.newAtBottom:", action("workspace.newAtBottom"), flush=True)
    anchor = (wait(lambda: new_workspaces(before), 20) or [None])[0]
    if not anchor:
        sys.exit("no workspace opened")
    print("anchor:", {k: v for k, v in anchor.items() if not isinstance(v, (list, dict))}, flush=True)
    print("workspace.moveToNewGroup:", action("workspace.moveToNewGroup", {"name": "like this e2e"}, target=target_of(anchor)), flush=True)
    time.sleep(1)  # test harness: the group lists
    before = known()
    print("workspace.newBelow:", action("workspace.newBelow", target=target_of(anchor)), flush=True)
    wait(lambda: new_workspaces(before), 20)
    time.sleep(1)  # test harness: the sidebar settles
    anchor = next(w for w in workspaces() if ids(w) & ids(anchor))
    cwd = (first_tab(anchor) or {}).get("cwd")

    reply, made = like_this(anchor)
    time.sleep(1)  # test harness: the slot is applied once the daemon lists it
    rows = workspace_rows()
    at, made_at = row_index(anchor, rows), made and row_index(made, rows)
    tab = made and wait(lambda: first_tab(next(w for w in workspaces() if ids(w) & ids(made))), 10)
    row("New Workspace Like This on a grouped terminal workspace", f"right below it (in its group); a terminal in {cwd}",
        f"reply {reply}; rows {at} -> {made_at}; first tab {tab and (tab.get('kind'), tab.get('cwd'))}",
        made is not None and at is not None and made_at == at + 1 and bool(tab) and tab.get("kind") == "pty" and tab.get("cwd") == cwd)

    # The New Tab page as the first tab: a person's Cmd-N.
    before = known()
    print("Cmd-N:", rpc("debug.key", {"key": "n", "modifiers": ["command"]}), flush=True)
    page_ws = (wait(lambda: new_workspaces(before), 20) or [None])[0]
    time.sleep(1)  # test harness
    page_first = wait(lambda: shows_new_tab_page(), 10)
    if page_ws and page_first:
        reply, made = like_this(page_ws, focus=True)
        time.sleep(2)  # test harness: the new workspace shows its page
        page = wait(shows_new_tab_page, 10)
        tab = made and first_tab(next(w for w in workspaces() if ids(w) & ids(made)))
        row("New Workspace Like This on a New Tab page workspace opens on the New Tab page", "the focused tab is the New Tab page",
            f"reply {reply}; first tab {tab and (tab.get('kind'), tab.get('url'))}; New Tab page {page}", bool(made) and bool(page))
    else:
        row("New Workspace Like This on a New Tab page workspace opens on the New Tab page", "a Cmd-N workspace on the New Tab page",
            f"Cmd-N workspace {page_ws and sorted(ids(page_ws))}; New Tab page {page_first}", False)

    for old in ("workspace.newInSameDirectory", "workspace.newInGroup"):
        reply, made = like_this(anchor, name=old)
        row(f"the old id {old} runs New Workspace Like This", "no error; runs workspace.newLikeThis",
            f"reply {reply}", "error" not in (reply or {}) and (reply or {}).get("action") == "workspace.newLikeThis")

    rows = workspace_rows()
    at = row_index(anchor, rows)
    menu, folder = None, None
    if at is not None:
        frame = rows[at].get("window_frame") or {}
        x, y = frame.get("x", 0) + frame.get("width", 0) / 2, frame.get("y", 0) + frame.get("height", 0) / 2
        reply = rpc("debug.sidebar_rows", {"menu_x": x, "menu_y": y}) or {}
        menu, folder = reply.get("menu"), (reply.get("submenus") or {}).get("New")
    # Its New folder: the menu's top level is capped at twelve rows (ActionSurfaceParityTests).
    row("a workspace row's New menu offers New Workspace Like This, not the actions it folds",
        "'New Workspace Like This' first under New; no 'in This Group' or 'in Same Directory'", f"menu {menu}; New {folder}",
        bool(folder) and folder[0] == "New Workspace Like This"
        and not any(t in ("New Workspace in This Group", "New Workspace in Same Directory") for t in folder))
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "new-workspace-like-this.png")})


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)

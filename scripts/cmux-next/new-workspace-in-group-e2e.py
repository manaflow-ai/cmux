#!/usr/bin/env python3
"""Live check that a new workspace opened from inside a sidebar group lands in that group (cx-caoh).

When the window shows a workspace in a group, every new workspace whose entry point names no place
joins that group, whatever `workspaces.newPlacement` says (`top`: first in the group, the default;
`afterCurrent`: right after the current workspace; `bottom`: last in the group). Outside a group
the setting keeps its old meaning. Explicit places (New Workspace at Top or at Bottom, a drop on a
sidebar gap) still win.

Each entry point is one check, run under each `workspaces.newPlacement` value:
  Cmd-N (`debug.key`), the sidebar's + (`debug.mouse` on `debug.sidebar_rows` `new_button`),
  New Workspace from the palette (`action.run` `newTab` with focus), `cmux workspace new` (the
  same action without focus or a window), New <Kind> Tab with `newTerminal.opensWorkspace` on,
  a link opened in a new workspace (`browser.link.openInNewWorkspace`), an agent-opened workspace
  (`agent.openSessionWorkspace`; its workspace is made before the session is looked up), and New
  Workspace Like This.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket, reads new workspaces through the daemon socket's
`list-workspaces` and each row's group through `debug.sidebar_rows` (`group`). It restores the
settings it changes and never launches or quits the app.

Usage: new-workspace-in-group-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--daemon-socket PATH] [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--daemon-socket", help="the app's daemon socket (default: derived from --socket)")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
ROWS = []
SETTINGS = {"workspaces.newPlacement": None, "newTerminal.opensWorkspace": None}


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


def known():
    return set().union(*(ids(w) for w in workspaces()))


def new_workspaces(before):
    return [w for w in workspaces() if not ids(w) & before]


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


def windows():
    return (rpc("debug.sidebar_rows") or {}).get("windows") or []


def row_of(entry):
    """The workspace's row in the first window that lists it."""
    for window in windows():
        rows = [r for r in window.get("rows") or [] if str(r.get("key", "")).startswith("workspace(")]
        found = next((r for r in rows if any(i in str(r.get("key")) for i in ids(entry))), None)
        if found:
            return found
    return None


def group_of(entry):
    found = row_of(entry)
    return found and found.get("group")


def target_of(entry):
    """An action target for a workspace: its public id."""
    return "workspace:" + next((v for v in sorted(ids(entry)) if v.startswith("ws_")), sorted(ids(entry))[0])


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def setting(path, value):
    if SETTINGS[path] is None:
        SETTINGS[path] = rpc("settings.get", {"path": path}) or {}
    print(f"set {path}={value}:", rpc("settings.set", {"path": path, "value": value}), flush=True)
    time.sleep(1)  # test harness: the config reloads


def put_back(path):
    saved = SETTINGS[path]
    if saved is None or "error" in saved:
        return  # never read: leave the user's value alone
    previous = saved.get("value") if isinstance(saved, dict) else None
    if previous is None:
        rpc("settings.unset", {"path": path})
    else:
        rpc("settings.set", {"path": path, "value": previous})
    time.sleep(1)  # test harness: the config reloads


def restore():
    for path in SETTINGS:
        put_back(path)


def select(anchor):
    """Shows the anchor, as the palette's Go to Workspace does; exits when it cannot."""
    key = str((row_of(anchor) or {}).get("key", ""))
    sidebar_id = key[key.find("(") + 1:key.rfind(")")].strip('"') if "(" in key else target_of(anchor).split(":", 1)[1]
    reply = action("goToWorkspace", {"workspace": sidebar_id}, focus=True)
    if not wait(lambda: (row_of(anchor) or {}).get("selected"), 5):
        sys.exit(f"could not select the anchor workspace: {reply}")


def click_new_button():
    frame = next((w.get("new_button") for w in windows() if w.get("new_button")), None)
    if not frame:
        return {"error": "no + button in the sidebar"}
    x, y = frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2
    return rpc("debug.mouse", {"x": x, "y": y, "action": "click"})


PATHS = [
    ("Cmd-N", lambda anchor: rpc("debug.key", {"key": "n", "modifiers": ["command"]})),
    ("the sidebar's +", lambda anchor: click_new_button()),
    ("New Workspace in the palette", lambda anchor: action("newTab", focus=True)),
    ("cmux workspace new (no window, no focus)", lambda anchor: action("newTab")),
    ("New <Kind> Tab with newTerminal.opensWorkspace", lambda anchor: action("newTab.ofKind", focus=True)),
    ("a link opened in a new workspace", lambda anchor: action("browser.link.openInNewWorkspace", {"url": "about:blank"}, focus=True)),
    ("an agent-opened workspace (agent.openSessionWorkspace)",
     lambda anchor: action("agent.openSessionWorkspace", {"session": "cx-caoh-e2e-no-session", "name": "agent e2e"})),
    ("New Workspace Like This", lambda anchor: action("workspace.newLikeThis", focus=True, target=target_of(anchor))),
]


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)

    # A terminal workspace in a group of its own.
    before = known()
    print("workspace.newAtBottom:", action("workspace.newAtBottom"), flush=True)
    anchor = (wait(lambda: new_workspaces(before), 20) or [None])[0]
    if not anchor:
        sys.exit("no workspace opened")
    print("workspace.moveToNewGroup:", action("workspace.moveToNewGroup", {"name": "in group e2e"}, target=target_of(anchor)), flush=True)
    group = wait(lambda: group_of(anchor), 10)
    if not group:
        sys.exit("the anchor workspace did not join a group")
    print("group:", group, flush=True)

    for placement in ("top", "afterCurrent", "bottom"):
        setting("workspaces.newPlacement", placement)
        for name, run in PATHS:
            if "opensWorkspace" in name:
                setting("newTerminal.opensWorkspace", True)
            select(anchor)
            before = known()
            reply = run(anchor)
            made = (wait(lambda: new_workspaces(before), 20) or [None])[0]
            joined = made and wait(lambda: group_of(made) == group, 5)
            row(f"{name}, newPlacement {placement}", f"a new workspace in group {group}",
                f"reply {reply}; new {made and sorted(ids(made))}; its group {made and group_of(made)}", bool(made) and bool(joined))
            if "opensWorkspace" in name:
                put_back("newTerminal.opensWorkspace")

    # An explicit place still wins: New Workspace at Bottom leaves the group.
    select(anchor)
    before = known()
    reply = action("workspace.newAtBottom", focus=True)
    made = (wait(lambda: new_workspaces(before), 20) or [None])[0]
    listed = made and wait(lambda: row_of(made), 10)
    time.sleep(1)  # test harness: the slot is applied once the daemon lists it
    row("New Workspace at Bottom (an explicit place)", "a new workspace listed outside the group",
        f"reply {reply}; row {bool(listed)}; its group {made and group_of(made)}",
        bool(listed) and row_of(made) is not None and group_of(made) is None)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "new-workspace-in-group.png")})


try:
    main()
finally:
    restore()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)

#!/usr/bin/env python3
"""Live check that a notification shows in the sidebar the way classic's did (hq#1870 P1 #11,
cx-sv425), on a running tagged cmux-next build.

Classic shows the latest unread notification's text under its workspace's row
(`sidebar.showNotificationMessage`, on by default; in cmux NEXT `sidebar.workspaceRow.notification`,
off by default, so the row stays one line and the hover card says the text) and moves the workspace to the top of the
unpinned rows (`app.reorderOnNotification`, on by default). The script makes two workspaces,
leaves the one it selects alone, posts a notification to the other (the bottom row) through the
daemon, as `cmux notify` does, and reads the rows back from `debug.sidebar_rows`: the notified
workspace is the top row and its row stays one line. A notification for the
workspace the user is looking at moves nothing.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket, and never launches or quits the app. The daemon socket
defaults to the app's session, `cmux-app-<tag>[-capslot<N>].sock` in the user's `cmux-tui-<uid>`
temp folder.

Usage: sidebar-notification-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--daemon-socket PATH]
Exit status 0 when every check passes.
"""
import argparse, json, os, socket, subprocess, sys, time, uuid

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--daemon-socket", help="the app's daemon socket (default: derived from --socket)")
opts = parser.parse_args()
RESULTS = []


def line_json(path, request, timeout=30):
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


def rpc(method, params=None):
    """One request on the app's control socket."""
    try:
        reply = line_json(opts.socket, {"id": 1, "method": method, "params": params or {}})
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def daemon_socket():
    if opts.daemon_socket:
        return opts.daemon_socket
    temp = os.environ.get("TMPDIR") or subprocess.run(
        ["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    session = os.path.basename(opts.socket).replace("cmux-debug-", "cmux-app-", 1)
    return os.path.join(temp, f"cmux-tui-{os.getuid()}", session)


def daemon(cmd, **params):
    return line_json(daemon_socket(), {"id": 1, "cmd": cmd, **params})


def workspaces():
    """The daemon's workspaces by name."""
    data = daemon("list-workspaces").get("data") or {}
    return {entry.get("name"): entry for entry in data.get("workspaces") or []}


def first_surface(workspace):
    for screen in workspace.get("screens") or []:
        for pane in screen.get("panes") or []:
            for tab in pane.get("tabs") or []:
                if tab.get("surface") is not None:
                    return tab["surface"]
    return None


def sidebar():
    """The first window's workspace rows (titled) and its selection."""
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    if not windows:
        return [], []
    return [row for row in windows[0].get("rows") or [] if row.get("title")], windows[0].get("selection") or []


def titles(rows):
    return [row.get("title") for row in rows]


def check(name, ok, detail=""):
    RESULTS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} {name} {detail}".rstrip(), flush=True)
    return ok


def wait_rows(predicate, seconds=6.0):
    deadline = time.time() + seconds
    rows, selection = sidebar()
    while time.time() < deadline and not predicate(rows):
        time.sleep(0.25)
        rows, selection = sidebar()
    return rows, selection


def settled(seconds=2.0, limit=15.0):
    """The rows once their order holds for `seconds` (a new workspace's placement lands late)."""
    deadline = time.time() + limit
    rows, selection = sidebar()
    stable_since = time.time()
    while time.time() < deadline:
        time.sleep(0.25)
        now, now_selection = sidebar()
        if titles(now) != titles(rows) or now_selection != selection:
            rows, selection, stable_since = now, now_selection, time.time()
        elif time.time() - stable_since >= seconds:
            break
    return rows, selection


def main():
    run = uuid.uuid4().hex[:6]
    names = [f"notif-{run}-{n}" for n in ("a", "b", "c")]
    for name in names:
        created = daemon("new-workspace", name=name)
        if not check(f"created workspace {name}", bool(created.get("ok")), str(created.get("error") or "")):
            return 1
    rows, selection = wait_rows(lambda rows: all(name in titles(rows) for name in names))
    if not check("the new workspaces have rows", all(name in titles(rows) for name in names), str(titles(rows))):
        return 1
    rows, selection = settled()
    # The bottom new row that is not selected: a notification there must move it up.
    target = next((row.get("title") for row in reversed(rows)
                   if row.get("title") in names and row.get("title") not in selection), None)
    if not check("a new workspace is not selected", target is not None, f"selection={selection}"):
        return 1
    before = titles(rows)
    surface = first_surface(workspaces().get(target) or {})
    body = f"build {run} finished"
    posted = daemon("notify", title="sidebar e2e", body=body, surface=surface)
    check("the daemon took the notification", bool(posted.get("ok")), str(posted.get("error") or ""))

    rows, _ = wait_rows(lambda rows: titles(rows)[:1] == [target])
    after = titles(rows)
    check("the notified workspace moves to the top row", after[:1] == [target],
          f"before={before.index(target)} after={after.index(target) if target in after else None} rows={after}")
    # The row stays one line by default (Leo 2026-10-14); the text reads in its hover card, and
    # `sidebar.workspaceRow.notification` draws it under the row as classic did.
    row = next((r for r in rows if r.get("title") == target), {})
    check("its row stays one line, without the notification's text", body not in str(row.get("detail")),
          f"detail={row.get('detail')!r}")

    # A notification for the selected workspace (the one in view) leaves the order alone.
    _, selection = sidebar()
    viewed = workspaces().get(selection[0]) if selection else None
    if viewed and first_surface(viewed) is not None:
        rows, _ = sidebar()
        order = titles(rows)
        daemon("notify", title="sidebar e2e", body=f"viewed {run}", surface=first_surface(viewed))
        time.sleep(2.0)
        rows, _ = sidebar()
        check("a notification for the workspace in view moves nothing", titles(rows) == order,
              f"before={order} after={titles(rows)}")

    for name in names:
        workspace = workspaces().get(name)
        if workspace:
            daemon("close-workspace", workspace=workspace.get("id"))
    passed = sum(RESULTS)
    print(f"RESULT {passed}/{len(RESULTS)}", flush=True)
    return 0 if passed == len(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())

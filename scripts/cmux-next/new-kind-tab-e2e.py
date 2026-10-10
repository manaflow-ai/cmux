#!/usr/bin/env python3
"""Live check of New <Kind> Tab (cmuxterm-hq#1829, cx-9r5w) on a running tagged cmux-next build.

`newTab.ofKind` opens a tab of the selected tab's kind whatever `tabs.newTabKind` says: on a
browser tab it opens a browser tab on that tab's engine, while Cmd-T (`newTab.default`) opens the
New Tab page under the default setting. The old id `newTab.sameKind` still runs Cmd-T's action,
so keybindings and scripts keep working. A browser tab's menu titles the action by its kind
("New Browser Tab").

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket. It runs actions the way the palette does (`action.run`,
with `focus` so a run may select what it opens), presses Cmd-T as the user does (`debug.key`; a
script's `newTab.default` takes the selected tab's kind), reads tabs through the daemon socket's
`list-workspaces`, asks the app whether the focused tab is the New Tab page (`debug.new_tab`
`field`: the New Tab page and agent chats are daemon browser tabs too), and reads the browser tab
row's menu (`debug.sidebar_rows` `menu_x`/`menu_y`, with Show Tabs Under Workspaces on). It never
launches or quits the app.

Usage: new-kind-tab-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--daemon-socket PATH] [--out DIR]
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


def daemon_tabs():
    snapshot = line_json(daemon_socket(), {"id": 1, "cmd": "list-workspaces"}, 30)
    return [tab for entry in (snapshot.get("data") or {}).get("workspaces") or []
            for screen in entry.get("screens") or [] for pane in screen.get("panes") or []
            for tab in pane.get("tabs") or []]


def tab(tab_id):
    return next((t for t in daemon_tabs() if t.get("tab_resource_id") == tab_id), None)


def created(reply):
    ids = (reply or {}).get("created") or []
    return ids[0] if ids else None


def shows_new_tab_page():
    """The focused pane shows the New Tab page (or an agent chat), not a web page or terminal."""
    return "error" not in (rpc("debug.new_tab", {"action": "field"}) or {"error": True})


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


def sidebar():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return windows[0] if windows else {}


def tab_rows():
    return [r for r in sidebar().get("rows") or [] if str(r.get("key", "")).startswith("tab(")]


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    print("newTab (workspace):", action("newTab", focus=True), flush=True)
    time.sleep(1)  # test harness: the workspace mounts
    reply = action("openBrowser", {"url": "about:blank"}, focus=True)
    print("openBrowser:", reply, flush=True)
    browser_id = created(reply)
    browser = wait(lambda: tab(browser_id), 20)
    if not browser:
        sys.exit("no browser tab opened")
    time.sleep(1)  # test harness: the browser tab is selected
    print("browser tab:", browser.get("kind"), browser.get("browser_engine"), browser.get("url"), flush=True)

    reply = action("newTab.ofKind", focus=True)
    opened = wait(lambda: tab(created(reply)), 15)
    time.sleep(1)  # test harness: the new tab is selected
    page = shows_new_tab_page()
    row("New <Kind> Tab on a browser tab opens a browser tab on its engine",
        f"a browser tab on {browser.get('browser_engine')}, not the New Tab page",
        f"reply {reply}; opened {opened and (opened.get('kind'), opened.get('browser_engine'), opened.get('url'))}; New Tab page {page}",
        bool(opened) and opened.get("kind") == "browser" and opened.get("browser_engine") == browser.get("browser_engine") and not page)

    # Cmd-T as the user presses it (debug.key: the key router, user origin) on a browser tab
    # opens the New Tab page under tabs.newTabKind's default ("page"). The slot's config may
    # name another kind, so the check sets the default and restores it.
    saved = rpc("settings.get", {"path": "tabs.newTabKind"})
    print("tabs.newTabKind was:", saved, "set:", rpc("settings.set", {"path": "tabs.newTabKind", "value": "page"}), flush=True)
    time.sleep(1)  # test harness: the config reloads
    print("select the browser tab:", action("tab.focus", focus=True, target="tab:" + browser_id), flush=True)
    time.sleep(1)  # test harness
    before = {t.get("tab_resource_id") for t in daemon_tabs()}
    print("Cmd-T:", rpc("debug.key", {"key": "t", "modifiers": ["command"]}), flush=True)
    new = wait(lambda: [t for t in daemon_tabs() if t.get("tab_resource_id") not in before], 15)
    page = wait(shows_new_tab_page, 10)
    row("Cmd-T on a browser tab still opens the New Tab page", "one new tab; the focused pane shows the New Tab page",
        f"new {[(t.get('kind'), t.get('browser_engine'), t.get('url')) for t in new or []]}; New Tab page {page}",
        bool(new) and len(new) == 1 and bool(page))
    previous = (saved or {}).get("value")
    if isinstance(previous, str) and previous != "page":
        rpc("settings.set", {"path": "tabs.newTabKind", "value": previous})
    elif previous is None:
        rpc("settings.unset", {"path": "tabs.newTabKind"})

    reply = action("newTab.sameKind")
    row("the old id newTab.sameKind runs Cmd-T's action", "no error; runs newTab.default",
        f"reply {reply}", "error" not in (reply or {}) and (reply or {}).get("action") == "newTab.default")

    if not tab_rows():
        print("workspace tabs toggle:", action("sidebar.workspaceTabs.toggle"), flush=True)
    wait(tab_rows, 15)
    time.sleep(1)  # test harness: the list settles
    browser_row = next((r for r in tab_rows() if browser_id in str(r.get("key"))), None)
    menu = None
    if browser_row:
        frame = browser_row.get("window_frame") or {}
        x, y = frame.get("x", 0) + frame.get("width", 0) / 2, frame.get("y", 0) + frame.get("height", 0) / 2
        menu = (rpc("debug.sidebar_rows", {"menu_x": x, "menu_y": y}) or {}).get("menu")
    row("a browser tab's menu offers New Browser Tab", "'New Browser Tab' in the menu",
        f"row {browser_row and browser_row.get('key')}; menu {menu}", bool(menu) and "New Browser Tab" in menu)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "new-kind-tab.png")})


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)

#!/usr/bin/env python3
"""Live check of the per-pane tab bar (cx-soza) on a running tagged cmux-next build.

Any pane can show or hide its horizontal tab bar: its own Show Tab Bar choice (`pane.toggleTabBar`),
else its kind's `tabs.tabBar.<terminal|browser|agent>` (Automatic hides it for an agent chat alone in
its column). Cmd-T follows the tab bar: a pane that shows it gets a tab, one that hides it a new
workspace. New Horizontal Tab (`newTab.horizontal`, no default key) turns the bar on and adds a tab.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a tagged
build) through its debug socket. It presses keys as the user does (`debug.key`), runs actions the way
the palette does (`action.run` with `focus`), reads workspaces and tabs from the daemon socket's
`list-workspaces`, and reads the shown pane's tab bar from `debug.pane_chrome` (`strip_hidden`,
`tab_bar_kind`, `tab_bar_choice`). Every step opens a workspace with one pane, so the window shows
one pane. It restores the settings it changes and never launches or quits the app.

Usage: pane-tab-bar-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--daemon-socket PATH] [--out DIR]
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


def workspaces():
    """{workspace id: (group, [tab ids])} from the daemon."""
    snapshot = line_json(daemon_socket(), {"id": 1, "cmd": "list-workspaces"}, 30)
    out = {}
    for entry in (snapshot.get("data") or {}).get("workspaces") or []:
        key = entry.get("workspace_resource_id") or entry.get("id") or entry.get("key")
        tabs = [t.get("tab_resource_id") for s in entry.get("screens") or [] for p in s.get("panes") or []
                for t in p.get("tabs") or []]
        out[json.dumps(key)] = (entry.get("group") or entry.get("group_id"), tabs)
    return out


NEEDS_PAGE = [True]  # a script's action.run opens a terminal tab, not the New Tab page
FOCUSED = [None]  # the workspace the user is in: the one the last step opened or grew


def opened(step):
    """Run `step`, then remember the workspace it opened as the focused one."""
    before = set(workspaces())
    reply = step()
    fresh = wait(lambda: [k for k in workspaces() if k not in before], 15)
    if fresh:
        FOCUSED[0] = fresh[0]
    time.sleep(2)  # test harness: the workspace mounts
    return reply


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def key(letter):
    return rpc("debug.key", {"key": letter, "modifiers": ["command"]})


def press(letter, case, expects):
    """Press Cmd-<letter>: "tab" (a tab in the focused workspace), "workspace" (a new workspace in
    the focused one's group) or "stay" (nothing new; the page already showing keeps the focus)."""
    before = workspaces()
    print(case, "Cmd-" + letter.upper() + ":", key(letter), flush=True)
    grew = lambda now: now if sum(len(t) for _, t in now.values()) > sum(len(t) for _, t in before.values()) else None
    changed = wait(lambda: grew(workspaces()), 4 if expects == "stay" else 15)
    time.sleep(1)  # test harness: the new tab is selected and its page mounts
    page = wait(shows_new_tab_page, 10)
    now = workspaces()
    new_ws = [k for k in now if k not in before]
    grown = [k for k in now if k in before and len(now[k][1]) > len(before[k][1])]
    home = before.get(FOCUSED[0])
    if expects == "tab":
        ok = bool(changed) and not new_ws and grown == [FOCUSED[0]] and (bool(page) or not NEEDS_PAGE[0])
        expected = "one new tab in the focused workspace, no new workspace; the New Tab page"
    elif expects == "stay":
        ok = not changed and not new_ws and not grown and bool(page)
        expected = "no new tab or workspace; the New Tab page keeps the focus"
    else:
        # The group as the daemon lists it (none for an ungrouped workspace): the same as the focused one's.
        ok = bool(changed) and len(new_ws) == 1 and not grown and bool(page) and home is not None and now[new_ws[0]][0] == home[0]
        expected = "one new workspace in the focused workspace's group, no tab in the old one; the New Tab page"
    observed = (f"focused group {home and home[0]}; new workspaces {[now[k][0] for k in new_ws]}; "
                f"grown {['focused' if k == FOCUSED[0] else 'other' for k in grown]}; New Tab page {page}")
    if new_ws:
        FOCUSED[0] = new_ws[0]
    row(case, expected, observed, ok)


def setting(path, value):
    saved = (rpc("settings.get", {"path": path}) or {}).get("value")
    print(path, "was:", saved, "set:", rpc("settings.set", {"path": path, "value": value}), flush=True)
    time.sleep(1)  # test harness: the config reloads
    return saved


def restore(path, saved):
    rpc("settings.unset", {"path": path}) if saved is None else rpc("settings.set", {"path": path, "value": saved})


def shown_pane():
    """The one pane the active window shows: its tab bar state."""
    windows = (rpc("debug.pane_chrome") or {}).get("windows") or []
    panes = (windows[0].get("panes") if windows else None) or []
    return panes[0] if len(panes) == 1 else {"error": f"{len(panes)} panes shown"}


def strip(case, hidden, kind=None, choice="any"):
    pane = wait(lambda: (lambda p: p if p.get("strip_hidden") is hidden else None)(shown_pane()), 10) or shown_pane()
    ok = pane.get("strip_hidden") is hidden and (kind is None or pane.get("tab_bar_kind") == kind) \
        and (choice == "any" or pane.get("tab_bar_choice") == choice)
    row(case, f"tab bar {'hidden' if hidden else 'shown'}" + (f", kind {kind}" if kind else "")
        + ("" if choice == "any" else f", choice {choice}"),
        f"hidden {pane.get('strip_hidden')}, kind {pane.get('tab_bar_kind')}, choice {pane.get('tab_bar_choice')} {pane.get('error') or ''}", ok)


def run(name, case, expects):
    """`action.run` as the palette runs it, checked like a key press."""
    press_with(lambda: action(name, focus=True), case, expects)


def press_with(step, case, expects):
    global key
    saved = key
    key = lambda _letter: step()
    NEEDS_PAGE[0] = False
    try:
        press("t", case, expects)
    finally:
        key = saved
        NEEDS_PAGE[0] = True


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    kind = setting("tabs.newTabKind", "page")
    swap = setting("tabs.swapCmdTAndCmdN", False)
    terminal = setting("tabs.tabBar.terminal", "auto")
    agent = setting("tabs.tabBar.agent", "auto")
    try:
        # An agent chat alone in its workspace hides its tab bar (Automatic), so Cmd-T opens a workspace.
        print("Cmd-I:", opened(lambda: key("i")), flush=True)
        strip("a lone agent chat hides its tab bar", True, kind="agent", choice=None)
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "pane-tab-bar-chat-hidden.png")})

        # Show Tab Bar on that chat: the bar shows, and Cmd-T adds a tab there.
        print("Show Tab Bar:", action("pane.toggleTabBar", focus=True), flush=True)
        strip("Show Tab Bar shows a chat's tab bar", False, kind="agent", choice=True)
        press("t", "Cmd-T on a chat that shows its tab bar opens a tab there", "tab")
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "pane-tab-bar-chat-shown.png")})
        # Hidden again (the pane now holds two tabs, which Automatic would show): Cmd-T opens a workspace.
        print("Show Tab Bar (off):", action("pane.toggleTabBar", focus=True), flush=True)
        strip("Show Tab Bar again hides it", True, choice=False)
        press("t", "Cmd-T on a pane that hides its tab bar opens a workspace", "workspace")

        # New Horizontal Tab on a lone chat: the bar turns on and the pane gets a tab.
        print("Cmd-I:", opened(lambda: key("i")), flush=True)
        strip("a second lone chat hides its tab bar", True, kind="agent")
        run("newTab.horizontal", "New Horizontal Tab opens a tab in the chat's pane", "tab")
        strip("New Horizontal Tab turned the tab bar on", False, choice=True)

        # The per-kind defaults.
        setting("tabs.tabBar.terminal", "never")
        print("newTab (workspace):", opened(lambda: action("newTab", focus=True)), flush=True)
        strip("tabs.tabBar.terminal never hides a terminal pane's tab bar", True, kind="terminal", choice=None)
        press("t", "Cmd-T on that terminal opens a workspace", "workspace")
        setting("tabs.tabBar.agent", "always")
        print("Cmd-I:", opened(lambda: key("i")), flush=True)
        strip("tabs.tabBar.agent always shows a lone chat's tab bar", False, kind="agent", choice=None)
        press("t", "Cmd-T on that chat opens a tab there", "tab")
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "pane-tab-bar.png")})
    finally:
        restore("tabs.tabBar.agent", agent)
        restore("tabs.tabBar.terminal", terminal)
        restore("tabs.swapCmdTAndCmdN", swap)
        restore("tabs.newTabKind", kind)


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)

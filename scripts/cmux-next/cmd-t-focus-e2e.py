#!/usr/bin/env python3
"""Live check of Cmd-T by focus (cx-xt5k) on a running tagged cmux-next build.

Cmd-T follows the focused pane. A pane with a tab strip (a terminal, a browser tab, the New Tab
page) gets a new tab in that pane. An agent chat, or a pane without a strip (a lone chat), gets a
new workspace in the current group instead. Both open the New Tab page. With
`tabs.swapCmdTAndCmdN` on, Cmd-T is always New Workspace and Cmd-N is always New Tab.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket. It presses keys as the user does (`debug.key`: the key
router, user origin), reads workspaces and tabs through the daemon socket's `list-workspaces`, and
asks the app whether the focused pane shows the New Tab page (`debug.new_tab` `field`). It
restores the settings it changes. It never launches or quits the app.

Usage: cmd-t-focus-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--daemon-socket PATH] [--out DIR]
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
    """Press Cmd-<letter> and check that it opened a tab in the focused workspace or a workspace."""
    before = workspaces()
    print(case, "Cmd-" + letter.upper() + ":", key(letter), flush=True)
    changed = wait(lambda: (lambda now: now if sum(len(t) for _, t in now.values()) > sum(len(t) for _, t in before.values()) else None)(workspaces()), 15)
    time.sleep(1)  # test harness: the new tab is selected and its page mounts
    page = wait(shows_new_tab_page, 10)
    now = changed or before
    new_ws = [k for k in now if k not in before]
    grown = [k for k in now if k in before and len(now[k][1]) > len(before[k][1])]
    if expects == "tab":
        ok = bool(changed) and not new_ws and len(grown) == 1 and bool(page)
        expected = "one new tab in the focused workspace, no new workspace; the New Tab page"
    else:
        home = now.get(FOCUSED[0])
        same_group = home is not None and all(now[k][0] == home[0] for k in new_ws)
        ok = bool(changed) and len(new_ws) == 1 and not grown and bool(page) and same_group
        expected = "one new workspace in the current group, no tab in the old one; the New Tab page"
    if new_ws:
        FOCUSED[0] = new_ws[0]
    row(case, expected, f"focused group {now.get(FOCUSED[0], (None,))[0]}; new workspaces {len(new_ws)} {[now[k][0] for k in new_ws]}; grown {len(grown)}; New Tab page {page}", ok)


def setting(path, value):
    saved = (rpc("settings.get", {"path": path}) or {}).get("value")
    print(path, "was:", saved, "set:", rpc("settings.set", {"path": path, "value": value}), flush=True)
    time.sleep(1)  # test harness: the config reloads
    return saved


def restore(path, saved):
    rpc("settings.unset", {"path": path}) if saved is None else rpc("settings.set", {"path": path, "value": saved})


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    kind = setting("tabs.newTabKind", "page")
    swap = setting("tabs.swapCmdTAndCmdN", False)
    try:
        # A script's workspace starts on a terminal: a pane with a tab strip.
        print("newTab (workspace):", opened(lambda: action("newTab", focus=True)), flush=True)
        press("t", "Cmd-T on a terminal opens a tab there", "tab")
        press("t", "Cmd-T on the New Tab page opens a tab there", "tab")
        reply = action("openBrowser", {"url": "about:blank"}, focus=True)
        wait(lambda: created(reply) and tab(created(reply)), 20)
        time.sleep(1)  # test harness: the browser tab is selected
        press("t", "Cmd-T on a browser tab opens a tab there", "tab")

        # Cmd-I: a new workspace whose only tab is an agent chat, with no tab strip.
        print("Cmd-I:", opened(lambda: key("i")), flush=True)
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "cmd-t-focus-chat.png")})
        press("t", "Cmd-T on an agent chat opens a workspace", "workspace")

        # The swap: Cmd-T is New Workspace and Cmd-N New Tab, on any focus.
        setting("tabs.swapCmdTAndCmdN", True)
        print("newTab (workspace):", opened(lambda: action("newTab", focus=True)), flush=True)
        press("t", "swapped: Cmd-T on a terminal opens a workspace", "workspace")
        press("n", "swapped: Cmd-N on the New Tab page opens a tab", "tab")
        restore("tabs.swapCmdTAndCmdN", swap)
        time.sleep(1)  # test harness: the config reloads
        press("n", "swap off again: Cmd-N opens a workspace", "workspace")
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "cmd-t-focus.png")})
    finally:
        restore("tabs.swapCmdTAndCmdN", swap)
        restore("tabs.newTabKind", kind)


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)

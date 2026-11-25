#!/usr/bin/env python3
"""Live check of Cmd-T by focus (cx-xt5k) on a running tagged cmux-next build.

Cmd-T opens a New Tab page in the current workspace from any focus: a terminal, a browser tab,
the New Tab page, also with the keyboard in its field (Leo 2026-10-10), and a lone agent chat
without a tab strip (Lawrence 2026-10-11, cx-04fy, replacing cx-xt5k's new workspace there). With `tabs.swapCmdTAndCmdN` on, Cmd-T is always New Workspace and
Cmd-N is always New Tab.

With the keyboard in the New Tab page's field (a web view), every bound app shortcut must reach
the key router, not the page: `debug.key` `dry_run` asks the router what it would run, for each
shortcut in `action.list`, without running it.

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
    """Press Cmd-<letter>: "tab" (a tab in the focused workspace) or "workspace" (a new workspace
    in the focused one's group)."""
    before = workspaces()
    print(case, "Cmd-" + letter.upper() + ":", key(letter), flush=True)
    grew = lambda now: now if sum(len(t) for _, t in now.values()) > sum(len(t) for _, t in before.values()) else None
    changed = wait(lambda: grew(workspaces()), 15)
    time.sleep(1)  # test harness: the new tab is selected and its page mounts
    page = wait(shows_new_tab_page, 10)
    now = workspaces()
    new_ws = [k for k in now if k not in before]
    grown = [k for k in now if k in before and len(now[k][1]) > len(before[k][1])]
    home = before.get(FOCUSED[0])
    if expects == "tab":
        ok = bool(changed) and not new_ws and grown == [FOCUSED[0]] and bool(page)
        expected = "one new tab in the focused workspace, no new workspace; the New Tab page"
    else:
        # The group as the daemon lists it (none for an ungrouped workspace): the same as the focused one's.
        ok = bool(changed) and len(new_ws) == 1 and not grown and bool(page) and home is not None and now[new_ws[0]][0] == home[0]
        expected = "one new workspace in the focused workspace's group, no tab in the old one; the New Tab page"
    observed = (f"focused group {home and home[0]}; new workspaces {[now[k][0] for k in new_ws]}; "
                f"grown {['focused' if k == FOCUSED[0] else 'other' for k in grown]}; New Tab page {page}")
    if new_ws:
        FOCUSED[0] = new_ws[0]
    row(case, expected, observed, ok)


def field_focused(case):
    focused = lambda: (lambda field: field if field.get("focused") is True else None)(rpc("debug.new_tab", {"action": "field"}) or {})
    field = wait(focused, 10) or rpc("debug.new_tab", {"action": "field"}) or {}
    row(case, "the New Tab field has the keyboard", json.dumps(field), field.get("focused") is True)


# Shortcuts that edit the focused field (the Edit menu's): a text field keeps them. Other chords
# a field also knows (Cmd-Left, Cmd-Delete, Cmd-Return) go to the app when the app binds them.
FIELD_KEYS = {"cmd+a", "cmd+c", "cmd+v", "cmd+x", "cmd+z", "cmd+shift+z"}
# debug.key's key for a config token: shifted symbols as their own character (it adds Shift).
SHIFTED = {"`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(",
           "0": ")", "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": '"', ",": "<", ".": ">", "/": "?"}
TYPABLE = set("abcdefghijklmnopqrstuvwxyz0123456789`-=[]\\;',./") | {
    "return", "escape", "tab", "space", "left", "right", "down", "up", "pageup", "pagedown", "home", "end", "delete"}


def debug_key_args(config):
    """debug.key params for a single-stroke `shortcut_config` such as "cmd+shift+t" or "cmd+,",
    else None (chord sequences, keys debug.key cannot type such as F-keys)."""
    if not config or " " in config:
        return None
    *mods, token = config.split("+")
    if token == "plus":
        token, mods = "+", [m for m in mods if m != "shift"]
    names = {"cmd": "command", "shift": "shift", "opt": "option", "ctrl": "control"}
    if any(m not in names for m in mods) or not ({"cmd", "ctrl"} & set(mods)):
        return None
    if token != "+" and token not in TYPABLE:
        return None
    if "shift" in mods and len(token) == 1 and (token.isalpha() or token in SHIFTED):
        token = token.upper() if token.isalpha() else SHIFTED[token]
        mods = [m for m in mods if m != "shift"]
    return {"key": token, "modifiers": [names[m] for m in mods]}


def sweep_shortcuts():
    """Every bound app shortcut (a Command or Control chord) reaches the key router while the
    New Tab field has the keyboard: the router would run that action, none goes to the page.
    `dry_run` asks the router's decision only (no chord sequences, no intercepts), so this
    proves the page cannot swallow a shortcut, not what each action then does."""
    # A build without `dry_run` would run every shortcut: send none unless the router answers dry.
    # The probe is End, which in a field only moves the caret if the build runs it.
    probe = rpc("debug.key", {"key": "end", "dry_run": True}) or {}
    if "decision" not in probe:
        row("every app shortcut reaches the router with the keyboard in the New Tab field",
            "debug.key dry_run answers", json.dumps(probe), False)
        return
    actions = (rpc("action.list", {"available_only": True}) or {}).get("actions") or []
    delivered, other, ran, skipped = [], [], 0, 0
    for entry in actions:
        config = entry.get("shortcut_config")
        args = debug_key_args(config)
        if args is None or config in FIELD_KEYS or entry.get("unavailable_reason"):
            skipped += 1
            continue
        verdict = rpc("debug.key", dict(args, dry_run=True)) or {}
        if not verdict.get("action"):
            delivered.append(f"{config} ({entry.get('id')}): {verdict.get('decision') or verdict.get('error')}")
            continue
        ran += 1
        if verdict["action"] != entry.get("id"):
            # Two actions on one chord: the router runs the one for this focus. Reported, not failed.
            other.append(f"{config}: {entry.get('id')} -> {verdict['action']}")
    row("every app shortcut reaches the router with the keyboard in the New Tab field",
        "each Command/Control shortcut runs an action, none goes to the page",
        f"{ran} routed, {skipped} skipped; shared chords {other or 'none'}; to the page: {delivered or 'none'}",
        ran > 0 and not delivered)


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
    swap = setting("tabs.swapCmdTAndCmdN", False)
    try:
        # A script's workspace starts on a terminal: a pane with a tab strip.
        print("newTab (workspace):", opened(lambda: action("newTab", focus=True)), flush=True)
        press("t", "Cmd-T on a terminal opens a tab there", "tab")
        # The New Tab page is a tab of a pane with a strip: Cmd-T opens another, also with the
        # keyboard in the page's field (a web view), and again from that one.
        field_focused("Cmd-T opened the New Tab page with the keyboard in its field")
        press("t", "Cmd-T with the keyboard in the New Tab field opens a tab there", "tab")
        field_focused("the new New Tab page has the keyboard in its field")
        press("t", "Cmd-T again from that New Tab field opens another tab", "tab")
        sweep_shortcuts()
        reply = action("openBrowser", {"url": "about:blank"}, focus=True)
        wait(lambda: created(reply) and tab(created(reply)), 20)
        time.sleep(1)  # test harness: the browser tab is selected
        press("t", "Cmd-T on a browser tab opens a tab there", "tab")

        # Cmd-I: a new workspace whose only tab is an agent chat, with no tab strip.
        print("Cmd-I:", opened(lambda: key("i")), flush=True)
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "cmd-t-focus-chat.png")})
        press("t", "Cmd-T on a lone agent chat opens a tab there", "tab")

        # The swap: Cmd-N is New Tab and Cmd-T New Workspace, on any focus.
        setting("tabs.swapCmdTAndCmdN", True)
        print("newTab (workspace):", opened(lambda: action("newTab", focus=True)), flush=True)
        press("n", "swapped: Cmd-N on a terminal opens a tab", "tab")
        press("t", "swapped: Cmd-T on the New Tab page opens a workspace", "workspace")
        restore("tabs.swapCmdTAndCmdN", swap)
        time.sleep(1)  # test harness: the config reloads
        press("n", "swap off again: Cmd-N opens a workspace", "workspace")
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "cmd-t-focus.png")})
    finally:
        restore("tabs.swapCmdTAndCmdN", swap)


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)

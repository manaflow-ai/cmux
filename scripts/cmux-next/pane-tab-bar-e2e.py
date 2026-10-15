#!/usr/bin/env python3
"""Live check of the per-pane tab bar (cx-soza) on a running tagged cmux-next build.

Every pane shows its horizontal tab bar: terminals, browsers, a lone agent chat with one tab, and a
chat in the left chat dock (cx-v4dmy, Lawrence 2026-10-15). The only way to hide it is the one toggle
(`pane.toggleTabBar`): it reads "Hide Tab Bar" in the palette and the pane's menu while the bar shows,
and "Show Tab Bar" while it is hidden (cx-5425v). The retired `tabs.tabBar.<kind>` settings load
without error from an old cmux.json and are ignored; `settings.set` refuses them. A lone chat still
moves into the left chat dock when a tool opens from it. New Horizontal Tab (`newTab.horizontal`)
turns the bar on and adds a tab.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a tagged
build) through its debug socket. It presses keys as the user does (`debug.key`), runs actions the way
the palette does (`action.run` with `focus`), reads workspaces and tabs from the daemon socket's
`list-workspaces`, reads the shown pane's tab bar from `debug.pane_chrome` (`strip_hidden`,
`tab_bar_choice`, `tab_bar_title`) and the palette row from `debug.palette.entries`. It restores the
settings and the cmux.json text it changes and never launches or quits the app.

Usage: pane-tab-bar-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--daemon-socket PATH] [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, json, os, re, socket, subprocess, sys, time

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


def shown_panes():
    """The panes the active window shows, with their tab bar state."""
    windows = (rpc("debug.pane_chrome") or {}).get("windows") or []
    return (windows[0].get("panes") if windows else None) or []


def shown_pane():
    """The one pane the active window shows: its tab bar state."""
    panes = shown_panes()
    return panes[0] if len(panes) == 1 else {"error": f"{len(panes)} panes shown"}


def palette_title():
    """The toggle's title in the palette's ranker input (`debug.palette.entries`)."""
    path = os.path.join(opts.out, "palette-entries.json")
    reply = rpc("debug.palette.entries", {"path": path})
    if "error" in (reply or {}):
        return f"error {reply['error']}"
    found = []

    def walk(node):
        if isinstance(node, dict):
            if str(node.get("id", "")).endswith("pane.toggleTabBar") and isinstance(node.get("entry"), dict):
                found.append(node["entry"].get("title"))
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    with open(path) as handle:
        walk(json.load(handle))
    return found[0] if found else "no row"


def strip(case, hidden, choice="any", pick=shown_pane, palette=False):
    title = "Show Tab Bar" if hidden else "Hide Tab Bar"
    pane = wait(lambda: (lambda p: p if p.get("strip_hidden") is hidden else None)(pick()), 10) or pick()
    in_palette = palette_title() if palette else None
    ok = pane.get("strip_hidden") is hidden and pane.get("tab_bar_title") == title \
        and (choice == "any" or pane.get("tab_bar_choice") == choice) and (not palette or in_palette == title)
    row(case, f"tab bar {'hidden' if hidden else 'shown'}, menu title {title!r}"
        + (f", palette title {title!r}" if palette else "") + ("" if choice == "any" else f", choice {choice}"),
        f"hidden {pane.get('strip_hidden')}, menu {pane.get('tab_bar_title')!r}, palette {in_palette!r}, "
        f"choice {pane.get('tab_bar_choice')} {pane.get('error') or ''}", ok)


def docked_chat():
    """The left chat dock's pane: two panes shown, the leftmost one."""
    panes = shown_panes()
    if len(panes) != 2:
        return {"error": f"{len(panes)} panes shown"}
    return min(panes, key=lambda p: p["cell"][0])


def snapshot(name):
    time.sleep(1.5)  # test harness: the strip change is laid out and drawn before the capture
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, name)})


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


def opened_workspace(step, case):
    """Run `step`; a row that it opened a new workspace."""
    before = set(workspaces())
    print(case, step(), flush=True)
    fresh = wait(lambda: [k for k in workspaces() if k not in before], 15)
    if fresh:
        FOCUSED[0] = fresh[0]
    time.sleep(2)  # test harness: the workspace mounts
    row(case, "a new workspace", f"new workspaces {len(fresh or [])}", bool(fresh))


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    swap = setting("tabs.swapCmdTAndCmdN", False)
    config = (rpc("settings.set", {"path": "tabs.swapCmdTAndCmdN", "value": False}) or {}).get("file")
    try:
        # Cmd-I in a terminal workspace docks a chat left (cx-ihyx2): the chat dock shows its tab bar.
        opened_workspace(lambda: action("newTab", focus=True), "New Workspace (script: a terminal)")
        strip("a new terminal pane shows its tab bar", False, choice=None, palette=True)
        print("Cmd-I:", key("i"), flush=True)
        strip("a chat in the left chat dock (one tab) shows its tab bar", False, choice=None, pick=docked_chat)
        snapshot("pane-tab-bar-chat-dock.png")

        # Close the terminal: the screen undocks and the chat is alone in its column, one tab.
        print("focusRight:", action("focusRight", focus=True), flush=True)
        print("closePane:", action("closePane", focus=True), flush=True)
        strip("a lone agent chat (one tab) shows its tab bar; the palette offers Hide Tab Bar", False,
              choice=None, palette=True)
        snapshot("pane-tab-bar-chat-default.png")

        # Hide Tab Bar hides it; the entry then reads Show Tab Bar, which shows it again.
        print("palette Hide Tab Bar:", action("pane.toggleTabBar", focus=True), flush=True)
        strip("Hide Tab Bar hides the lone chat's tab bar; the palette offers Show Tab Bar", True,
              choice=False, palette=True)
        snapshot("pane-tab-bar-chat-hidden.png")
        print("palette Show Tab Bar:", action("pane.toggleTabBar", focus=True), flush=True)
        strip("Show Tab Bar shows it again (the default, no choice)", False, choice=None, palette=True)
        snapshot("pane-tab-bar-chat-shown.png")

        # A tool opened from the lone chat still docks the chat left; the docked chat shows its tab bar.
        print("New Terminal Tab (Ctrl-`):", rpc("debug.key", {"key": "`", "modifiers": ["control"]}), flush=True)
        strip("a lone chat moves into the left chat dock on its first tool, tab bar shown", False,
              choice=None, pick=docked_chat)

        # A terminal pane: hidden, then New Horizontal Tab turns the bar on and adds a tab.
        opened_workspace(lambda: action("newTab", focus=True), "New Workspace (script: a terminal)")
        print("palette Hide Tab Bar:", action("pane.toggleTabBar", focus=True), flush=True)
        strip("Hide Tab Bar hides a terminal pane's tab bar", True, choice=False)
        run("newTab.horizontal", "New Horizontal Tab opens a tab in that pane", "tab")
        strip("New Horizontal Tab turned the tab bar on", False, choice=None)

        # The retired settings: settings.set refuses them; an old cmux.json that sets them still loads.
        refused = rpc("settings.set", {"path": "tabs.tabBar.agent", "value": "never"})
        row("settings.set tabs.tabBar.agent is refused as removed", "an error", str(refused)[:160],
            "error" in (refused or {}))
        if config and os.path.exists(config):
            with open(config) as handle:
                saved_text = handle.read()
            try:
                # cmux.json is JSONC: insert the old keys as text, inside "tabs" or a new "tabs".
                old = '"tabBar": {"terminal": "never", "browser": "always", "agent": "never"}'
                # The top-level "tabs" object only (two-space indent), never a nested one or a comment.
                match = re.search(r'^  "tabs"\s*:\s*\{', saved_text, re.M)
                if match:
                    after = saved_text[match.end():].lstrip()
                    text = saved_text[:match.end()] + " " + old + ("" if after.startswith("}") else ",") + saved_text[match.end():]
                else:
                    first = saved_text.index("{") + 1
                    text = saved_text[:first] + ' "tabs": {' + old + "}," + saved_text[first:]
                with open(config, "w") as handle:
                    handle.write(text)
                read = wait(lambda: (lambda r: r if (r or {}).get("value") == "never" else None)(
                    rpc("settings.get", {"path": "tabs.tabBar.agent"})), 15) or rpc("settings.get", {"path": "tabs.tabBar.agent"})
                row("the app re-read the old cmux.json (settings.get tabs.tabBar.agent)", "exists, \"never\"",
                    str(read)[:160], (read or {}).get("exists") is True and read.get("value") == "never")
                opened_workspace(lambda: action("newTab", focus=True), "New Workspace with an old tabs.tabBar in cmux.json")
                strip("an old cmux.json with tabs.tabBar never still shows the tab bar", False, choice=None)
                answer = rpc("settings.get", {"path": "tabs.swapCmdTAndCmdN"})
                row("the old cmux.json still loads (settings.get answers)", "no error", str(answer)[:160],
                    "error" not in (answer or {"error": 1}))
            finally:
                with open(config, "w") as handle:
                    handle.write(saved_text)
        else:
            row("cmux.json path from settings.set", "a file", str(config), False)
    finally:
        restore("tabs.swapCmdTAndCmdN", swap)


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)

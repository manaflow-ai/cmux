#!/usr/bin/env python3
"""Live check that the sidebar keys move between sidebar items from any focus.

By default, with no preset and no rebinding (Lawrence 2026-10-20):
  - Ctrl-Cmd-] selects the next sidebar item and Ctrl-Cmd-[ the previous one;
  - Cmd-1 to Cmd-8 select the nth item and Cmd-9 the last.
Cmd-Opt arrows focus panes (Ghostty's `goto_split`) and Ctrl-PageDown / PageUp have no cmux
default, so neither is checked here.
They win over the focused surface (the user's own Ghostty keybinds win over them, #22418): a terminal, the New Tab page's
field and an agent chat's composer, in a pane with one tab and in a pane with two (where the
old Previous / Next switched the pane's tabs). `--surfaces` adds terminal copy mode (which
takes every other key), a web page, the Settings page and Home (cx-9ce.18); their focus is
read from `context.keys`.

For each surface the script shows a start workspace of that kind, focuses it, presses each key,
and compares the selection with what the matching sidebar action (`nextSidebarTab`,
`prevSidebarTab`, `selectWorkspaceByNumber`) selects from the same start. A key that switches
the pane's tabs, or that the surface swallows, leaves a different selection.

Leo's two Karabiner paths (Cmd-Shift-] / [, Ctrl-Tab) now cycle the pane's tabs, so they are no
longer checked here (SEQUENCES is empty). They went in transition by transition with their timing (Cmd down,
Shift down, ] down ~5 ms apart; Ctrl down, Tab down ~270 ms later and held ~175 ms) through
`debug.key` `sequence`, which builds each as a CGEvent and posts it to the app's event queue.
Other keys go in as real key-downs through cua-driver (`--real`, the app frontmost on a whole mini,
APP_PID set) or through `debug.key` (the app's own dispatch). Either way each row also prints
the router's decision for the key in that focus (`debug.key` dry_run).

The script attaches to an app already running through its debug socket and never launches or
quits the app.

Usage: chrome-tab-keys-e2e.py --socket /tmp/cmux-debug-<tag>.sock [--real] [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, http.server, json, os, socket, subprocess, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--real", action="store_true", help="press real keys with cua-driver (APP_PID)")
parser.add_argument("--surfaces", default="terminal,terminal2,newtab,newtab2,composer",
                    help="also copymode, page, settings, home")
parser.add_argument("--tidy", action="store_true",
                    help="first close every other workspace (a tag's workspaces persist between launches)")
parser.add_argument("--keys", help="only these key labels, comma separated (e.g. Ctrl-Cmd-],Cmd-9)")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
ROWS = []

NEXT, PREV = "nextSidebarTab", "prevSidebarTab"
KEYS = [
    # Ctrl-Tab and Cmd-Shift-] / [ cycle the focused pane's tabs (Leo 2026-10-12, Lawrence
    # 2026-10-15), never workspaces: CtrlTabCyclesPaneTabsTests.
    ("Ctrl-Cmd-]", "]", ["ctrl", "cmd"], NEXT, None),
    ("Ctrl-Cmd-[", "[", ["ctrl", "cmd"], PREV, None),
    ("Cmd-1", "1", ["cmd"], "selectWorkspaceByNumber", 1),
    ("Cmd-2", "2", ["cmd"], "selectWorkspaceByNumber", 2),
    ("Cmd-9", "9", ["cmd"], "selectWorkspaceByNumber", 9),
]


def step(code, down, after=0):
    return {"key_code": code, "down": down, "after_ms": after}


# Leo's Karabiner virtual keyboard, transition by transition (ANSI key codes: 55 left_command,
# 56 left_shift, 59 left_control, 30 close_bracket, 33 open_bracket, 48 tab).
def karabiner_cmd_shift(bracket):
    return [step(55, True), step(56, True, 5), step(bracket, True, 5), step(bracket, False, 60),
            step(56, False, 5), step(55, False, 5)]


def karabiner_ctrl_tab(shift):
    held = [step(59, True)] + ([step(56, True, 5)] if shift else [])
    released = ([step(56, False, 5)] if shift else []) + [step(59, False, 5)]
    return held + [step(48, True, 270), step(48, False, 175)] + released


# Sent with `debug.key` `sequence` (the app's event queue, the timing above), in both modes.
# Leo's Karabiner sends Cmd-Shift-] / [ and Ctrl-Tab, which now cycle the pane's tabs, so no
# sequence selects a sidebar item; `karabiner_cmd_shift` / `karabiner_ctrl_tab` stay for a
# pane-tab check.
SEQUENCES = []


def rpc(method, params=None, timeout=30):
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


def wait(check, seconds, step=0.25):
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


def selected():
    """The window's selected sidebar item, by title."""
    window = sidebar()
    selection = window.get("selection") or []
    if selection:
        return selection[0]
    # A top item (Home and the other pinned pages) is no row: the active layout item names it.
    active = [i for i in window.get("items") or [] if i.get("active") and i.get("region") == "top"]
    if active:
        return "item:" + str(active[0].get("ref"))
    # Older builds: no `selection`; the selected row says so itself.
    return next((r.get("title") for r in window.get("rows") or [] if r.get("selected")), None)


def workspace_titles():
    return [r.get("title") for r in sidebar().get("rows") or [] if str(r.get("key", "")).startswith("workspace(")]


def run(action, args=None):
    return rpc("action.run", {"action": action, "args": args or {}, "focus": True})


def settle(before):
    """The selection once it stops changing (a key may move it a turn late)."""
    wait(lambda: selected() != before or None, 2)
    time.sleep(0.3)  # test harness: let a late second move show
    return selected()


def focus_kind():
    """Where the router thinks the keyboard is (dry run of a key nothing binds)."""
    reply = rpc("debug.key", {"key": "tab", "modifiers": ["ctrl"], "dry_run": True}) or {}
    return reply.get("focus") or reply.get("error")


def decision(key, modifiers):
    reply = rpc("debug.key", {"key": key, "modifiers": modifiers, "dry_run": True}) or {}
    return reply.get("action") or reply.get("decision") or reply.get("error")


CUA_KEYS = {"option": "option", "cmd": "cmd", "ctrl": "ctrl", "shift": "shift",
            "pagedown": "pagedown", "pageup": "pageup", "left": "left", "right": "right", "tab": "tab"}


WINDOW = []


def main_window():
    """The app's main window id for cua-driver (the app has several windows)."""
    if not WINDOW:
        done = subprocess.run(["cua-driver", "call", "list_windows", json.dumps({"pid": int(os.environ["APP_PID"])})],
                              capture_output=True, text=True, timeout=20)
        listed = json.loads(done.stdout or "{}")
        windows = [w for w in (listed.get("windows") if isinstance(listed, dict) else listed) or []
                   if w.get("pid") == int(os.environ["APP_PID"]) and w.get("is_on_screen")]
        windows.sort(key=lambda w: -((w.get("bounds") or {}).get("width", 0) * (w.get("bounds") or {}).get("height", 0)))
        WINDOW.append(windows[0]["window_id"] if windows else None)
    return WINDOW[0]


def press(key, modifiers):
    if not opts.real:
        reply = rpc("debug.key", {"key": key, "modifiers": modifiers}) or {}
        return f"{reply.get('handled_by')}:{reply.get('action')}"
    keys = [CUA_KEYS.get(m, m) for m in modifiers] + [CUA_KEYS.get(key, key)]
    payload = json.dumps({"pid": int(os.environ["APP_PID"]), "window_id": main_window(), "keys": keys,
                          "delivery_mode": "foreground"})
    done = subprocess.run(["cua-driver", "call", "hotkey", payload], capture_output=True, text=True, timeout=20)
    return "cua:" + (done.stdout.strip().replace("\n", " ")[:80] or done.stderr.strip()[:80])


def show(title):
    """Shows workspace `title` by stepping the sidebar (no select-by-id action exists)."""
    for _ in range(len(sidebar().get("rows") or []) + len(sidebar().get("items") or []) + 2):
        if selected() == title:
            return True
        before = selected()
        run(NEXT)
        wait(lambda: selected() != before or None, 3)
    return selected() == title


def context_keys():
    """The key window's context keys (`context.keys`): surfaceKind, terminal.copyMode, ..."""
    return (rpc("context.keys") or {}).get("keys") or {}


# The web page: a local server this script starts, with a text field to type in.
class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        # A title of its own per run: the page's title names its workspace.
        self.wfile.write(f"<!doctype html><title>keys {os.getpid()}</title><input autofocus>".encode())

    def log_message(self, *args):
        pass


def focus(surface):
    """Puts the keyboard in the shown workspace's surface; true once it is there."""
    if surface == "copymode":
        if not context_keys().get("terminal.copyMode"):
            run("toggleTerminalCopyMode")
        return wait(lambda: context_keys().get("terminal.copyMode") or None, 8)
    if surface in ("page", "settings", "home"):
        return wait(lambda: context_keys().get("surfaceKind") == surface or None, 8)
    if surface == "newtab":
        return wait(lambda: (rpc("debug.new_tab", {"action": "field"}) or {}).get("focused") is True, 8)
    if surface == "newtab2":
        return wait(lambda: (rpc("debug.new_tab", {"action": "field"}) or {}).get("focused") is True, 8)
    want = {"terminal": "terminal", "terminal2": "terminal", "composer": "agentpage"}[surface]
    if focus_kind() is None:
        return "unknown (this build's dry run names no focus)"  # older builds: trust the setup
    return wait(lambda: want in str(focus_kind()).lower() or None, 8)


def create(surface):
    """A workspace whose focus is `surface`; returns its sidebar title."""
    if surface == "home":
        run("sidebar.home.add")  # Home is a sidebar item by default; put it back if a run removed it
        run("home.show")
        return wait(lambda: context_keys().get("surfaceKind") == "home" and selected(), 10)
    before = set(workspace_titles())
    if surface in ("terminal", "terminal2", "copymode"):
        run("newTab", {"command": "/bin/cat"})  # a socket's new workspace is a terminal
    else:
        press("n", ["cmd"])  # a person's Cmd-N opens the New Tab page
    made = wait(lambda: [t for t in workspace_titles() if t not in before] or None, 20)
    if made and surface == "composer":
        # The New Tab page becomes a chat; its composer has the keyboard.
        wait(lambda: (rpc("debug.new_tab", {"action": "field"}) or {}).get("focused") is True, 10)
        print("new_chat", rpc("debug.agent_pane", {"action": "new_chat"}), flush=True)
        time.sleep(2)  # test harness: the page swaps to the chat
    if made and surface == "page":
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        print("openBrowser", run("openBrowser", {"url": f"http://127.0.0.1:{server.server_address[1]}/"}), flush=True)
        wait(lambda: context_keys().get("surfaceKind") == "page" or None, 15)
        time.sleep(1)  # test harness: the page's title renames the workspace
        made = [selected()]
    if made and surface == "settings":
        print("openSettings", run("openSettings"), flush=True)
        wait(lambda: context_keys().get("surfaceKind") == "settings" or None, 10)
        time.sleep(1)  # test harness: the tab's title may rename the workspace
        made = [selected()]
    if made and surface.endswith("2"):
        # A second tab in the pane: a key that switches the pane's tabs instead of the
        # sidebar item no longer looks right.
        print(f"{surface} second tab", run("newSurface"), flush=True)
        time.sleep(2)  # test harness: the tab opens and takes the keyboard
        if surface == "newtab2":
            run("prevSurface")  # back to the New Tab page, the pane's first tab
            time.sleep(1)  # test harness
    return made[0] if made else None


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    if opts.tidy:
        print("tidy", rpc("action.run", {"action": "palette.closeOtherWorkspaces", "args": {}, "focus": True,
                                         "confirm": True}), flush=True)
        wait(lambda: len(workspace_titles()) <= 1 or None, 30)
        print(f"tidy: {len(workspace_titles())} workspace(s) left", flush=True)
    create("newtab")  # a filler below the starts, so no start is the last item
    starts = {}
    for surface in opts.surfaces.split(","):
        starts[surface] = create(surface)
        print(f"{surface}: start workspace {starts[surface]}", flush=True)
    # Fillers above the starts (new workspaces go to the top by default), so no start is the
    # first, second or last item and every key must move the selection.
    for _ in range(3):
        create("newtab")
    print(f"sidebar: {[r.get('title') for r in sidebar().get('rows') or []]}", flush=True)

    for surface, start in starts.items():
        if not start:
            row(f"{surface}: start workspace", "created", None, False)
            continue
        cases = [(label, key, modifiers, action, index, None) for label, key, modifiers, action, index in KEYS]
        cases += [(label, key, modifiers, action, None, steps) for label, steps, key, modifiers, action in SEQUENCES]
        if opts.keys:
            cases = [case for case in cases if case[0] in opts.keys.split(",")]
        for label, key, modifiers, action, index, steps in cases:
            if not show(start):
                row(f"{surface} {label}", "start shown", selected(), False)
                continue
            run(action, {"index": index} if index else {})
            oracle = settle(start)
            show(start)
            focused = focus(surface)
            where, routed = focus_kind(), decision(key, modifiers)
            if steps:
                reply = rpc("debug.key", {"sequence": steps}) or {}
                delivered = f"sequence:{reply.get('scheduled')} in {reply.get('duration_ms')} ms {reply.get('error') or ''}"
                time.sleep(((reply.get("duration_ms") or 0) + 100) / 1000)  # test harness: the sequence plays out
            else:
                delivered = press(key, modifiers)
            got = settle(start)
            row(f"{surface} {label}", f"{action} -> {oracle}",
                f"{start} -> {got} (focused={bool(focused)} focus={where} router={routed} sent={delivered})",
                bool(focused) and oracle != start and got == oracle)

    path = os.path.join(opts.out, "chrome-tab-keys.json")
    with open(path, "w") as handle:
        json.dump(ROWS, handle)
    passed = sum(1 for r in ROWS if r["ok"])
    print(f"RESULT {passed}/{len(ROWS)}", flush=True)
    return 0 if passed == len(ROWS) else 1


def row(check, expected, observed, ok):
    ROWS.append({"check": check, "expected": expected, "observed": observed, "ok": ok})
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


if __name__ == "__main__":
    sys.exit(main())

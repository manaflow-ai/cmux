#!/usr/bin/env python3
"""Keyboard parity matrix (Leo 2026-10-12): the shortcuts Chrome, ChatGPT desktop and Claude
desktop share, pressed as real keys from every focus target of a running cmux-next.

Keys: Cmd-T, Cmd-W, Cmd-Shift-T, Cmd-L, Cmd-F, Cmd-K, Cmd-[ / Cmd-], Cmd-R, Cmd-comma, Cmd-1 and
Cmd-9, Esc (with the command palette open), Cmd-Shift-N, Cmd-I. Focus targets: a terminal, a
web page, the New Tab page's field, an agent chat's composer, Settings and the sidebar.

Each cell starts from a fresh workspace with the keyboard in its focus target, presses the key
(cua-driver `hotkey`, foreground: the app frontmost on a whole capture mini, APP_PID set; or
`--debug-key` for the app's own dispatch), and checks the effect a person would see:

  Cmd-T          a new tab opens with the New Tab page
  Cmd-W          the focused tab closes (a terminal running a program asks first)
  Cmd-Shift-T    the tab closed just before comes back
  Cmd-L          web page: the address bar; elsewhere: the New Tab page's field
  Cmd-F          web page: the find bar; elsewhere the key runs Find (the terminal's and the
                 chat's find bars and Settings' search field live in the session or page)
  Cmd-K          terminal: the screen clears; elsewhere: the agent chat search opens
  Cmd-[ / Cmd-]  web page: history back / forward; elsewhere: focus history back / forward
  Cmd-R          web page: reload; elsewhere the key runs Rename Tab (the tab strip's field)
  Cmd-comma      Settings opens
  Cmd-1 / Cmd-9  the first / last sidebar item
  Esc            the command palette closes and the keyboard returns
  Cmd-I          a new agent chat opens
  Cmd-Shift-N    a new window opens

"The key runs X" reads the router's last interception (`debug.key` `last`) after the real key.
Every row prints PASS or FAIL with the router's dry-run decision for that key in that focus, the
matrix goes to --out as matrix.md, and the last line is RESULT passed/total.

Usage: CMUX_SOCKET_PATH=... APP_PID=... keyboard-parity-e2e.py [--foci terminal,page,...]
       [--keys "Cmd-T,Cmd-W"] [--debug-key] [--out DIR]
"""
import argparse, http.server, json, os, socket, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"))
parser.add_argument("--foci", default="terminal,page,newtab,composer,settings,sidebar")
parser.add_argument("--keys", default="")
parser.add_argument("--debug-key", action="store_true", help="press through debug.key instead of real keys")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
MARK = "PARITYMARK"


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


def run(action, args=None):
    return rpc("action.run", {"action": action, "args": args or {}, "focus": True})


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


# The web page: a local server this script starts (and stops). Setup opens /a, then types /b in the
# address bar, so /a is a history entry to go back to (Chromium skips entries a script left without
# a user gesture). Each page reports `pageshow` (/shown/a, /shown/b), which also fires when
# Back or Forward restores it from the back/forward cache without a request, so the server's
# request log shows which page showed.
SHOWN = b"<script>addEventListener('pageshow',()=>fetch('/shown'+location.pathname+'?'+Date.now()))</script>"
PAGES = {"/a": b"<!doctype html><title>a</title><p>page a</p>" + SHOWN,
         "/b": b"<!doctype html><title>b</title><p>page b</p><input id=q>" + SHOWN}
REQUESTS = []


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        REQUESTS.append(self.path)
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(PAGES.get(self.path.split("?")[0], b""))

    def log_message(self, *args):
        pass


SERVER = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=SERVER.serve_forever, daemon=True).start()
PAGE_URL = f"http://127.0.0.1:{SERVER.server_address[1]}/a"


def fetched(path, since):
    """`path` was requested after the first `since` requests (the query string aside)."""
    return path in [r.split("?")[0] for r in REQUESTS[since:]]


def state():
    """The key window's focus and contents (debug.focus), plus the palette and window count."""
    report = rpc("debug.focus") or {}
    windows = report.get("windows") or []
    window = next((w for w in windows if w.get("is_key")), windows[0] if windows else {})
    model, appkit = window.get("model") or {}, window.get("appkit") or {}
    tabs = [t for pane in window.get("topology") or [] for t in pane.get("tabs") or []]
    selected = [pane.get("selected") for pane in window.get("topology") or [] if pane.get("pane") == model.get("pane")]
    return {"window": window.get("id"), "windows": len(windows), "resolved": model.get("resolved"),
            "tab": model.get("resolved_tab") or (selected[0] if selected else None), "target": model.get("target"),
            "overlays": model.get("overlays") or [], "responder": appkit.get("first_responder"),
            "classified": appkit.get("classified"), "tabs": tabs, "tab_ids": {t.split(":")[0] for t in tabs},
            "palette": ((report.get("context") or {}).get("palette_open")) is True}


def sidebar():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return windows[0] if windows else {}


def selected_item():
    window = sidebar()
    selection = window.get("selection") or []
    return selection[0] if selection else next((r.get("title") for r in window.get("rows") or [] if r.get("selected")), None)


def item_titles():
    return [r.get("title") for r in sidebar().get("rows") or [] if str(r.get("key", "")).startswith("workspace(")]


def terminal_text():
    return json.dumps(rpc("debug.surfaces", {"text": True}) or {})


# Real keys go to the app's largest on-screen window (cua-driver needs a window id).
CUA_KEYS = {"cmd": "cmd", "shift": "shift", "ctrl": "ctrl", "option": "option", "escape": "escape"}


def press(key, modifiers):
    if opts.debug_key:
        reply = rpc("debug.key", {"key": key, "modifiers": modifiers}) or {}
        return f"{reply.get('handled_by')}:{reply.get('action')}"
    keys = [CUA_KEYS.get(m, m) for m in modifiers] + [key]
    return cua("hotkey", {"keys": keys})


def cua(tool, args):
    """A cua-driver call with real input to the app's largest on-screen window."""
    pid = int(os.environ["APP_PID"])
    listed = json.loads(subprocess.run(["cua-driver", "call", "list_windows", json.dumps({"pid": pid})],
                                       capture_output=True, text=True, timeout=20).stdout or "{}")
    windows = [w for w in (listed.get("windows") if isinstance(listed, dict) else listed) or []
               if w.get("pid") == pid and w.get("is_on_screen")]
    windows.sort(key=lambda w: -((w.get("bounds") or {}).get("width", 0) * (w.get("bounds") or {}).get("height", 0)))
    if not windows:
        return "no window"
    payload = {"pid": pid, "window_id": windows[0]["window_id"], "delivery_mode": "foreground", **args}
    done = subprocess.run(["cua-driver", "call", tool, json.dumps(payload)], capture_output=True, text=True, timeout=20)
    return "cua:" + (done.stdout.strip().replace("\n", " ")[:60] or done.stderr.strip()[:60])


def last_key():
    """The action the router last took a key for (`debug.key` `last`)."""
    return rpc("debug.key", {"last": True}) or {}


def decision(key, modifiers):
    reply = rpc("debug.key", {"key": key, "modifiers": modifiers, "dry_run": True}) or {}
    return reply.get("action") or reply.get("decision") or reply.get("error")


# Focus targets. Each starts a fresh workspace (a person's Cmd-N opens the New Tab page).
def new_workspace():
    before = set(item_titles())
    press("n", ["cmd"]) if not opts.debug_key else run("newTab")
    made = wait(lambda: [t for t in item_titles() if t not in before] or None, 15)
    wait(lambda: state().get("resolved") == "agentPage" or None, 8)
    return made[0] if made else None


SETUP_WHY = []


def why(reason):
    """Records why a setup step failed, for the FAIL row."""
    SETUP_WHY.append(reason)
    return None


def setup(focus):
    """Puts the keyboard in `focus` in a fresh workspace; returns the cell's context or None."""
    if focus == "terminal":
        before = set(item_titles())
        run("newTab", {"command": f"/bin/sh -c 'echo {MARK}; exec cat'"})
        made = wait(lambda: [t for t in item_titles() if t not in before] or None, 15)
        ok = wait(lambda: state().get("resolved") == "terminal" or None, 10) and wait(lambda: MARK in terminal_text() or None, 10)
        return {"workspace": made[0] if made else None} if ok else None
    workspace = new_workspace()
    if not workspace:
        why(f"no new workspace (windows {state().get('windows')})")
        return None
    if focus == "newtab":
        ok = wait(lambda: (rpc("debug.new_tab", {"action": "field"}) or {}).get("focused") is True, 8)
    elif focus == "composer":
        rpc("debug.agent_pane", {"action": "new_chat"})
        ok = wait(lambda: state().get("resolved") == "agentPage" and
                  (rpc("debug.new_tab", {"action": "field"}) or {}).get("focused") is not True or None, 10)
    elif focus == "page":
        since = len(REQUESTS)
        run("openBrowser", {"url": PAGE_URL})
        ok = wait(lambda: fetched("/shown/a", since) or None, 15) or why("no /a")
        run("focusLocation")
        ok = ok and (wait(lambda: "addressBar" in str(state().get("target")) or None, 5)
                     or why(f"no address bar: {state().get('target')}"))
        if ok:
            cua("type_text", {"text": PAGE_URL[:-1] + "b"})
            cua("hotkey", {"keys": ["return"]})
        ok = ok and (wait(lambda: fetched("/shown/b", since) or None, 10) or why(f"no /b: {REQUESTS[since:]}"))
        ok = ok and (wait(lambda: state().get("resolved") == "browserPage" or None, 8)
                     or why(f"page not focused: {state().get('resolved')}"))
    elif focus == "settings":
        before = state()["tab_ids"]
        run("openSettings")
        ok = wait(lambda: state()["tab_ids"] - before and state().get("resolved") == "page" or None, 10)
    elif focus == "sidebar":
        tab = state().get("tab")
        run("focusSidebar")
        ok = wait(lambda: state().get("resolved") == "sidebar" or None, 8)
        return {"workspace": workspace, "tab": tab} if ok else None
    else:
        ok = False
    return {"workspace": workspace} if ok else None


# Checks: (pre, post, ctx) -> (ok, note).
def opened_new_tab(pre, post, ctx):
    new = post["tab_ids"] - pre["tab_ids"]
    return bool(new) and post["resolved"] == "agentPage", f"new={sorted(new)} resolved={post['resolved']}"


def closed_tab(pre, post, ctx):
    gone = ctx.get("tab") or pre["tab"]
    if gone not in post["tab_ids"]:
        return True, f"closed {gone}"
    # A terminal running a program asks first; the key reached Close Tab.
    dialogs = [d for d in (rpc("debug.dialog") or {}).get("dialogs") or [] if d.get("visible")]
    if dialogs:
        for d in dialogs:
            rpc("debug.dialog", {"id": d.get("id"), "press": "cancel"})
        return True, f"asks first: {dialogs[0].get('identifier') or dialogs[0].get('title')}"
    return False, f"{gone} still open, no confirmation"


def reopened(pre, post, ctx):
    new = post["tab_ids"] - pre["tab_ids"]
    return bool(new), f"new={sorted(new)}"


def location(pre, post, ctx):
    """A browser's address bar, a chat's composer, else the New Tab page's field (focusLocation)."""
    if ctx.get("focus") == "composer":
        composer = rpc("debug.agent_pane", {"action": "composer_focused"}) or {}
        return composer.get("focused") is True and post["resolved"] == "agentPage", f"composer={composer.get('focused')} resolved={post['resolved']}"
    if ctx.get("focus") == "page":
        text = f"{post['responder']} {post['classified']} {post['target']}".lower()
        return any(w in text for w in ("location", "omnibar", "address")), f"target={post['target']} responder={post['responder']}"
    field = rpc("debug.new_tab", {"action": "field"}) or {}
    return field.get("focused") is True, f"new tab field={field.get('focused')} resolved={post['resolved']}"


def ran(ctx, action):
    """The real key reached `action` and it ran (the router's interception after the key)."""
    last = ctx.get("last_after") or {}
    fresh = last.get("count") != (ctx.get("last_before") or {}).get("count")
    return fresh and last.get("action") == action and last.get("ran") is True, f"key ran {last.get('action') if fresh else 'nothing'} ({last.get('ran')})"


def find(pre, post, ctx):
    """A browser's find bar; a terminal's, a chat's find bar or Settings' search field, which
    live in the session or the page: the key ran Find."""
    if ctx.get("focus") == "page":
        return "find" in str(post["target"]).lower(), f"target={post['target']}"
    return ran(ctx, "find")


def cleared(pre, post, ctx):
    ok, note = ran(ctx, "terminal.clear")
    gone = bool(wait(lambda: MARK not in terminal_text() or None, 3))
    return ok and gone, f"{note}; {'screen cleared' if gone else 'marker still shown'}"


def chat_search(pre, post, ctx):
    ok, note = ran(ctx, "agentPane.searchChats")
    return ok and post["palette"], f"{note}; palette={post['palette']}"


def page_back(pre, post, ctx):
    ok = wait(lambda: fetched("/shown/a", ctx["requests"]) or None, 5)
    return bool(ok), f"loads after the key: {REQUESTS[ctx['requests']:]}"


def page_forward(pre, post, ctx):
    ok = wait(lambda: fetched("/shown/b", ctx["requests"]) or None, 5)
    return bool(ok), f"loads after the key: {REQUESTS[ctx['requests']:]}"


def page_reload(pre, post, ctx):
    ok = wait(lambda: fetched("/shown/b", ctx["requests"]) or None, 5)
    return bool(ok), f"loads after the key: {REQUESTS[ctx['requests']:]}"


def focus_moved(pre, post, ctx):
    moved = (post["tab"], post["resolved"]) != (pre["tab"], pre["resolved"])
    return moved, f"{pre['resolved']}:{pre['tab']} -> {post['resolved']}:{post['tab']}"


def focus_returned(pre, post, ctx):
    back = post["tab"] == ctx.get("start_tab") and post["resolved"] == ctx.get("start_resolved")
    return back, f"{pre['resolved']}:{pre['tab']} -> {post['resolved']}:{post['tab']} (start {ctx.get('start_tab')})"


def renaming(pre, post, ctx):
    """The tab's inline rename (the tab strip's field): the key ran Rename Tab."""
    return ran(ctx, "renameTab")


def settings_shown(pre, post, ctx):
    new = post["tab_ids"] - pre["tab_ids"]
    shown = post["resolved"] == "page" and (bool(new) or ctx.get("focus") == "settings")
    return shown, f"resolved={post['resolved']} new={sorted(new)}"


def selected_row(nth):
    """Whether the sidebar's `nth` item row (any kind: Home, a workspace) is the selected one."""
    rows = [r for r in sidebar().get("rows") or [] if r.get("key")]
    chosen = next((r for r in rows if r.get("selected")), None)
    want = rows[nth] if rows else None
    return bool(want) and chosen is not None and chosen.get("key") == want.get("key"), \
        f"selected={(chosen or {}).get('key')} wanted={(want or {}).get('key')}"


def first_item(pre, post, ctx):
    """The first item (Home when the sidebar shows it, which is not a keyed row): the key ran
    Select by Number and the selection left the start workspace."""
    ok, note = ran(ctx, "selectWorkspaceByNumber")
    rows = [r for r in sidebar().get("rows") or [] if r.get("key")]
    chosen = next((r.get("title") for r in rows if r.get("selected")), None)
    return ok and chosen != ctx.get("workspace"), f"{note}; selected={chosen} start={ctx.get('workspace')}"


def last_item(pre, post, ctx):
    return selected_row(-1)


def palette_closed(pre, post, ctx):
    back = not post["palette"] and post["tab"] == ctx.get("start_tab")
    return back, f"palette={post['palette']} tab={post['tab']} start={ctx.get('start_tab')}"


def new_window(pre, post, ctx):
    return post["windows"] == pre["windows"] + 1, f"windows {pre['windows']} -> {post['windows']}"


def agent_chat(pre, post, ctx):
    new = [t for t in post["tabs"] if t.split(":")[0] not in pre["tab_ids"]]
    return any(t.endswith(":agent") for t in new) or (post["palette"] and not pre["palette"]), f"new={new} palette={post['palette']}"


# Before-key preparation for keys that need it.
def prepare(name, focus, ctx):
    pre = state()
    ctx["start_tab"], ctx["start_resolved"], ctx["focus"] = pre["tab"], pre["resolved"], focus
    if name == "Cmd-Shift-T":
        # Close a second tab of this pane, then put the keyboard back where it was.
        before = state()["tab_ids"]
        run("newSurface")
        extra = wait(lambda: state()["tab_ids"] - before or None, 8)
        if extra:
            run("closeTab")
            wait(lambda: not (state()["tab_ids"] & extra) or None, 8)
        refocus(focus, ctx)
    elif name == "Cmd-]":
        since = len(REQUESTS)
        run("browserBack" if focus == "page" else "focusHistoryBack")
        if focus == "page":
            wait(lambda: fetched("/shown/a", since) or None, 5)
        time.sleep(0.5)  # test harness: the focus move settles
    elif name == "Esc":
        run("commandPalette")
        wait(lambda: state()["palette"] or None, 5)


def refocus(focus, ctx):
    if focus == "sidebar":
        run("focusSidebar")
        wait(lambda: state().get("resolved") == "sidebar" or None, 5)
    elif focus == "newtab":
        wait(lambda: (rpc("debug.new_tab", {"action": "field"}) or {}).get("focused") is True, 5)
    time.sleep(0.4)  # test harness


KEYS = [
    ("Cmd-T", "t", ["cmd"], {"*": ("New Tab page", opened_new_tab)}),
    ("Cmd-W", "w", ["cmd"], {"*": ("tab closes", closed_tab)}),
    ("Cmd-Shift-T", "t", ["cmd", "shift"], {"*": ("closed tab reopens", reopened)}),
    ("Cmd-L", "l", ["cmd"], {"*": ("location field", location)}),
    ("Cmd-F", "f", ["cmd"], {"*": ("find opens", find)}),
    ("Cmd-K", "k", ["cmd"], {"terminal": ("screen clears", cleared), "*": ("chat search opens", chat_search)}),
    ("Cmd-[", "[", ["cmd"], {"page": ("history back", page_back), "*": ("focus back", focus_moved)}),
    ("Cmd-]", "]", ["cmd"], {"page": ("history forward", page_forward), "*": ("focus forward", focus_returned)}),
    ("Cmd-R", "r", ["cmd"], {"page": ("reload", page_reload), "*": ("rename tab", renaming)}),
    ("Cmd-,", ",", ["cmd"], {"*": ("Settings", settings_shown)}),
    ("Cmd-1", "1", ["cmd"], {"*": ("first item", first_item)}),
    ("Cmd-9", "9", ["cmd"], {"*": ("last item", last_item)}),
    ("Esc", "escape", [], {"*": ("palette closes", palette_closed)}),
    ("Cmd-I", "i", ["cmd"], {"*": ("new agent chat", agent_chat)}),
    ("Cmd-Shift-N", "n", ["cmd", "shift"], {"*": ("new window", new_window)}),
]


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + str(opts.socket))
    wanted = [k.strip() for k in opts.keys.split(",") if k.strip()]
    keys = [k for k in KEYS if not wanted or k[0] in wanted]
    foci = [f.strip() for f in opts.foci.split(",") if f.strip()]
    # Filler items, so Cmd-1 and Cmd-9 always move the selection.
    for _ in range(2):
        new_workspace()
    results = {}
    for focus in foci:
        for name, key, modifiers, expectations in keys:
            label, check = expectations.get(focus) or expectations["*"]
            ctx = setup(focus) or setup(focus)
            if ctx is None:
                results[(name, focus)] = (False, label)
                print(f"FAIL | {focus:8} | {name:11} | {label} | setup failed (focus {state().get('resolved')}; {' / '.join(SETUP_WHY[-2:])})", flush=True)
                continue
            prepare(name, focus, ctx)
            routed = decision(key, modifiers)
            pre = state()
            ctx["requests"] = len(REQUESTS)
            ctx["last_before"] = last_key()
            sent = press(key, modifiers)
            time.sleep(1.2)  # test harness: let the key's effect land
            ctx["last_after"] = last_key()
            post = state()
            try:
                ok, note = check(pre, post, ctx)
            except Exception as error:  # report, don't stop the matrix
                ok, note = False, f"check raised {error!r}"
            results[(name, focus)] = (ok, label)
            print(f"{'PASS' if ok else 'FAIL'} | {focus:8} | {name:11} | {label} | router={routed} | {note} | {sent}", flush=True)
            if name == "Cmd-Shift-N" and post["windows"] > pre["windows"]:
                run("closeWindow")
                wait(lambda: state()["windows"] == pre["windows"] or None, 8)
            if state()["palette"]:
                press("escape", [])
    header = "| Key | " + " | ".join(foci) + " |"
    lines = [header, "| --- |" + " --- |" * len(foci)]
    for name, *_ in keys:
        lines.append(f"| {name} | " + " | ".join(("✅" if results[(name, f)][0] else "❌") for f in foci) + " |")
    matrix = "\n".join(lines)
    print(matrix, flush=True)
    with open(os.path.join(opts.out, "matrix.md"), "w") as out:
        out.write(matrix + "\n")
    passed = sum(ok for ok, _ in results.values())
    print(f"RESULT {passed}/{len(results)}", flush=True)
    SERVER.shutdown()


if __name__ == "__main__":
    main()

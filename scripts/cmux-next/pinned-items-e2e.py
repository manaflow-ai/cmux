#!/usr/bin/env python3
"""Pinned items end to end on a no-activate tagged build (PINNED-ITEMS-END-TO-END, cx-lle).

Drives the app only through its debug socket, like a user and like the CLI:

- workspace tiles and top rows: pin, Add to Top, the row and tile menu titles;
- Home leaves the top rows and comes back;
- the user's pins and Home edits are undo steps: the palette or the main menu runs them, Cmd-Z undoes;
- Chrome-style pinned tabs: a pinned tab moves first, Close Other Tabs keeps it, Cmd-W keeps it;
- everything survives an app restart (the daemon keeps running) and a full restart (daemon stopped).

Each check prints PASS or FAIL; the exit code is the number of failed checks. Window snapshots go to
--out. Run on the GUI host (cmux-lawrence-2) inside `nx-remote --needs gui`, never on the laptop.

Usage: pinned-items-e2e.py --tag <fresh tag> [--out DIR] [--app PATH]
"""
import argparse, glob, json, os, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--app", help="the tagged app (default: the tag's DerivedData build)")
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/*.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
SCRATCH = tempfile.mkdtemp(prefix=f"pins-{opts.tag}-")
CONFIG, GHOSTTY = os.path.join(SCRATCH, "cmux.json"), os.path.join(SCRATCH, "ghostty")
open(GHOSTTY, "w").write("")
open(CONFIG, "w").write("{}")
os.makedirs(opts.out, exist_ok=True)
FAILED = []


def say(line):
    print(line, flush=True)


def check(name, ok, detail=""):
    say(f"{'PASS' if ok else 'FAIL'} {name}" + (f": {detail}" if detail else ""))
    if not ok:
        FAILED.append(name)
    return ok


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
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


def run(action, args=None, target=None):
    params = {"action": action}
    if args:
        params["args"] = args
    if target:
        params["target"] = target
    reply = rpc("action.run", params)
    say(f"  action.run {action}: {json.dumps(reply)[:200]}")
    return reply if isinstance(reply, dict) else {}


def wait(label, predicate, timeout=15):
    """Polls `predicate` until it is truthy (test harness wait, not app code)."""
    deadline = time.time() + timeout
    value = None
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    say(f"  timed out: {label}")
    return value


def key(name, modifiers=(), target=None):
    params = {"key": name, "modifiers": list(modifiers)}
    if target:
        params["target"] = target
    reply = rpc("debug.key", params)
    say(f"  key {'+'.join(list(modifiers) + [name])}: {json.dumps(reply)[:160]}")
    return reply


def topology():
    return ((rpc("snapshot.get") or {}).get("topology")) or {}


def workspace(ws_id):
    return next((w for w in topology().get("workspaces", []) if w.get("id") == ws_id), None)


def tabs_of(ws_id):
    found = workspace(ws_id) or {}
    return [t for s in found.get("screens", []) for p in s.get("panes", []) for t in p.get("tabs", []) if t.get("kind") != "page"]


def sidebar():
    report = rpc("debug.sidebar_rows") or {}
    windows = report.get("windows") or [{}]
    return windows[0]


def items():
    return sidebar().get("items") or []


def item_for(ws_id):
    return next((i for i in items() if i.get("ref_kind") == "workspace" and i.get("ref", "").endswith(":" + ws_id)), None)


def has_home():
    return any(i.get("ref") == "cmux/home" for i in items())


def listed_titles():
    return [r.get("title") for r in sidebar().get("rows", []) if r.get("in_list") and r.get("title")]


def menu_at(frame):
    x, y = frame["x"] + min(40, frame["width"] / 2), frame["y"] + frame["height"] / 2
    reply = rpc("debug.sidebar_rows", {"menu_x": x, "menu_y": y}) or {}
    return [t for t in (reply.get("menu") or []) if t != "-"]


def toasts():
    return (rpc("debug.filepages") or {}).get("toasts") or []


def shot(name):
    for mode in ("light", "dark"):
        rpc("debug.appearance", {"mode": mode})
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{name}-{mode}.png")}, timeout=60)


def palette_run(query):
    """The user's palette: open it, type `query`, Return (origin user)."""
    key("p", ["command", "shift"])
    probe = os.path.join(opts.out, "palette.png")
    if not wait("palette opens", lambda: "error" not in (rpc("debug.palette.capture", {"path": probe}) or {"error": 1}), 5):
        return False
    for ch in query:
        key("space" if ch == " " else ch, target="palette")
    time.sleep(0.5)  # test harness: let the palette filter settle
    key("return", target="palette")
    return True


def launch():
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720", "CMUX_DEV_BACKEND_MODE": "local"}
    app = subprocess.Popen([BINARY], env=env, stdout=open(os.path.join(opts.out, "app.log"), "a"),
                           stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    up = wait("the tagged app comes up", lambda: os.path.exists(SOCKET) and topology().get("loaded"), 120)
    check("app launches", bool(up), f"pid {app.pid}")
    wait("the layout is served", lambda: bool(items()), 30)
    return app


def quit_app(app, how):
    """`how` = keep-sessions (the daemon keeps running) or end-sessions (it stops)."""
    action = {"keep-sessions": "quitKeepSessions", "end-sessions": "quitEndSessions"}[how]
    reply = rpc("action.run", {"action": action}, timeout=15)
    say(f"  quit {how}: {json.dumps(reply)[:160]}")
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        say(f"  app pid {app.pid} did not quit; SIGKILL that pid")
        app.kill()
        app.wait(timeout=10)


teardown = TagTeardown(APP, log=say)
teardown.install()
app = None
try:
    app = launch()
    # The sidebar layout must accept edits (the bundled daemon serves sidebar-layout-v1).
    check("Home starts in the top rows", has_home(), json.dumps([i.get("ref") for i in items()]))

    ws = {}
    for name in ("Alpha", "Beta", "Gamma"):
        # New Workspace needs no selected workspace (the window may show Home at launch).
        made = run("newTab", {"name": name})
        ws[name] = (made.get("created") or [None])[0]
    if not check("three named workspaces", bool(wait("rows named", lambda: {"Alpha", "Beta", "Gamma"} <= set(listed_titles()), 30)),
                 json.dumps(listed_titles())):
        raise SystemExit("setup failed")

    # Workspace tile (CLI origin) and a top row (Add to Top).
    run("palette.toggleWorkspacePin", target={"kind": "workspace", "id": ws["Alpha"]})
    tile = wait("Alpha tile", lambda: item_for(ws["Alpha"]))
    check("pin makes a workspace tile in sec_pinned", bool(tile) and tile.get("section") == "sec_pinned", json.dumps(tile))
    run("workspace.toggleTop", target={"kind": "workspace", "id": ws["Beta"]})
    row = wait("Beta top row", lambda: item_for(ws["Beta"]))
    check("Add to Top makes a top row", bool(row) and row.get("region") == "top" and row.get("section") != "sec_pinned", json.dumps(row))
    titles = listed_titles()
    check("tile and top row leave the workspace list", "Alpha" not in titles and "Beta" not in titles and "Gamma" in titles, json.dumps(titles))

    # Right-click titles: a list row offers Pin Workspace; a tile offers Unpin Workspace.
    gamma_row = next((r for r in sidebar().get("rows", []) if r.get("title") == "Gamma"), None)
    gamma_menu = menu_at(gamma_row["window_frame"]) if gamma_row else []
    check("row menu offers Pin Workspace", "Pin Workspace" in gamma_menu, json.dumps(gamma_menu))
    tile = item_for(ws["Alpha"])
    tile_menu = menu_at(tile["window_frame"]) if tile and tile.get("window_frame") else []
    check("tile menu offers Unpin Workspace", "Unpin Workspace" in tile_menu, json.dumps(tile_menu))
    home = next((i for i in items() if i.get("ref") == "cmux/home"), None)
    home_menu = menu_at(home["window_frame"]) if home and home.get("window_frame") else []
    say(f"  Home row menu: {json.dumps(home_menu)}")
    shot("1-tile-and-top-row")

    # The user's pin (main menu click path) is an undo step: Cmd-Z unpins.
    gamma_tabs = wait("Gamma's first tab", lambda: tabs_of(ws["Gamma"]))
    rpc("tab.focus", {"tab": gamma_tabs[0]["id"] if gamma_tabs else None})
    check("Gamma is the focused workspace", wait("Gamma focused", lambda: (topology().get("focus") or {}).get("workspace") == ws["Gamma"], 5) is True)
    menu = rpc("debug.menu_item", {"title": "Pin Workspace"})
    check("the main menu reads Pin Workspace for an unpinned workspace", "error" not in (menu or {"error": 1}), json.dumps(menu))
    pinned = wait("Gamma tile", lambda: item_for(ws["Gamma"]))
    check("user pin from the main menu makes a tile", bool(pinned))
    # A pin is not destructive: no toast (Lawrence 2026-10-18), only the undo step.
    check("user pin shows no toast", not wait("pin toast", toasts, 2), json.dumps(toasts()))
    shot("2-pin-no-toast")
    key("z", ["command"])
    check("Cmd-Z undoes the user's pin", wait("Gamma unpinned", lambda: item_for(ws["Gamma"]) is None, 5) is True)

    # Home leaves the top rows (CLI origin), then the user's palette re-adds it; Cmd-Z removes it again.
    run("sidebar.home.remove")
    check("Remove Home from Sidebar removes Home", wait("Home gone", lambda: not has_home(), 5) is True)
    palette_run("Add Home to Sidebar")
    check("user palette Add Home to Sidebar restores Home", wait("Home back", has_home, 5) is True)
    key("z", ["command"])
    check("Cmd-Z undoes Add Home", wait("Home gone again", lambda: not has_home(), 5) is True)

    # Chrome-style pinned tabs in Gamma: t1, t2, t3; pin t3 (CLI origin): it moves first.
    first = wait("Gamma's first tab", lambda: tabs_of(ws["Gamma"]))
    first_id = first[0]["id"] if first else None
    rpc("tab.focus", {"tab": first_id})
    run("newSurface", target={"kind": "tab", "id": first_id})
    run("newSurface", target={"kind": "tab", "id": first_id})
    tabs = wait("three tabs", lambda: (lambda t: t if len(t) >= 3 else None)(tabs_of(ws["Gamma"])))
    check("Gamma has three tabs", bool(tabs) and len(tabs) >= 3, json.dumps([t.get("id") for t in tabs or []]))
    t1, t2, t3 = [t["id"] for t in (tabs or [{}, {}, {}])[:3]] if tabs and len(tabs) >= 3 else (None, None, None)
    run("palette.toggleTabPin", target={"kind": "tab", "id": t3})
    order = wait("t3 pinned first", lambda: (lambda t: t if t and t[0]["id"] == t3 and t[0].get("pinned") else None)(tabs_of(ws["Gamma"])))
    check("a pinned tab moves first", bool(order), json.dumps([(t.get("id"), t.get("pinned")) for t in tabs_of(ws["Gamma"])]))
    shot("3-pinned-tab")

    # The user's tab pin (palette) is an undo step.
    rpc("tab.focus", {"tab": t2})
    palette_run("Pin/Unpin Tab")
    check("user tab pin from the palette pins it",
          bool(wait("t2 pinned", lambda: any(t["id"] == t2 and t.get("pinned") for t in tabs_of(ws["Gamma"])), 5)))
    key("z", ["command"])
    check("Cmd-Z undoes the user's tab pin",
          bool(wait("t2 unpinned", lambda: any(t["id"] == t2 and not t.get("pinned") for t in tabs_of(ws["Gamma"])), 5)))

    # Close Other Tabs keeps the pinned tab.
    run("closeOtherTabsInPane", target={"kind": "tab", "id": t2})
    left = wait("t1 closed", lambda: (lambda ids: ids if t1 not in ids else None)([t["id"] for t in tabs_of(ws["Gamma"])]), 10)
    check("Close Other Tabs keeps the pinned tab", bool(left) and t3 in left and t2 in left, json.dumps(left))

    # The user's Cmd-W on a pinned tab keeps it and selects the next tab.
    rpc("tab.focus", {"tab": t3})
    key("w", ["command"])
    time.sleep(1)  # test harness: a wrong close would land within this time
    ids = [t["id"] for t in tabs_of(ws["Gamma"])]
    check("Cmd-W keeps a pinned tab", t3 in ids, json.dumps(ids))

    # Restart the app only (the daemon keeps the sessions): everything stays.
    quit_app(app, "keep-sessions")
    app = launch()
    check("after an app restart: the tile stays", bool(item_for(ws["Alpha"])))
    check("after an app restart: the top row stays", bool(item_for(ws["Beta"])))
    check("after an app restart: Home stays removed", not has_home())
    check("after an app restart: the tab stays pinned", any(t["id"] == t3 and t.get("pinned") for t in tabs_of(ws["Gamma"])),
          json.dumps([(t.get("id"), t.get("pinned")) for t in tabs_of(ws["Gamma"])]))
    shot("4-after-app-restart")

    # A full restart (terminals end, the daemon stops; the layout reopens).
    quit_app(app, "end-sessions")
    app = launch()
    check("after a full restart: the tile stays", bool(item_for(ws["Alpha"])), json.dumps(items()))
    check("after a full restart: the top row stays", bool(item_for(ws["Beta"])))
    check("after a full restart: Home stays removed", not has_home())
    gamma = tabs_of(ws["Gamma"])
    check("after a full restart: Gamma keeps a pinned first tab", bool(gamma) and bool(gamma[0].get("pinned")),
          json.dumps([(t.get("id"), t.get("pinned")) for t in gamma]))
    shot("5-after-full-restart")

    # Leave the tag's layout as it started.
    run("sidebar.home.add")
    check("Add Home to Sidebar brings Home back", wait("Home back", has_home, 5) is True)
finally:
    if app and app.poll() is None:
        quit_app(app, "end-sessions")
    teardown.end()
    say(f"RESULT {len(FAILED)} failed: {json.dumps(FAILED)}")
sys.exit(min(len(FAILED), 100))

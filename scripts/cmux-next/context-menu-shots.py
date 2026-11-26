#!/usr/bin/env python3
"""Screenshots of cmux-next's right-click menus, open, for a before/after gallery (Lawrence 2026-10-22:
"need to fix all context menus such that it is very standard, need better icons for all too").

Launches the tagged app itself (no activation, a scratch cmux.json, an isolated Chief home), makes two
workspaces and a second tab, then opens each menu with a real right-click (`debug.mouse`) and captures
the window with the open menu ($NX_CAPTURE shot --with-popups), then Escape:

  plus           the tab bar's + (the menu in the screenshot Lawrence sent)
  tab            a tab
  strip          the empty tab bar (New Tab rows, then the pane's)
  terminal       the terminal
  sidebar-row    a workspace row in the sidebar
  sidebar-empty  the sidebar below its rows

Each menu's rows (titles, separators) go to context-menu-shots.json, from `debug.menu` where it answers.
Runs in dark and light (`--appearance dark,light`: Catppuccin Mocha and Latte, `debug.appearance`).

Usage (nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA):
  context-menu-shots.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS/shots"
Stop the app afterwards with "$NX_APP_STOP". Exit 0 when every menu was captured; 1 when one was not;
2 when the app did not come up.
"""
import argparse, json, os, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", default=os.environ.get("NX_APP"))
parser.add_argument("--tag", default=os.environ.get("NX_APP_TAG"))
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", tempfile.mkdtemp(prefix="context-menu-shots-")))
parser.add_argument("--appearance", default="dark,light")
opts = parser.parse_args()
if not opts.app or not opts.tag:
    sys.exit("context-menu-shots.py: --app and --tag (or NX_APP and NX_APP_TAG) are required")
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"ctxshots-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
CLI = os.path.join(opts.app, "Contents/Resources/bin/cmux")
CAPTURE = os.environ.get("NX_CAPTURE")
report = {"menus": {}, "missing": []}


def say(*parts):
    print(*parts, flush=True)


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
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def cli(*args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    env["CMUX_NEXT_CONFIG_FILE"] = CONFIG
    done = subprocess.run([CLI, "--app-socket", SOCKET, *args], env=env, capture_output=True, text=True, timeout=60)
    say("cli", " ".join(args), "->", done.returncode, (done.stdout + done.stderr).strip()[-200:])
    return done


def wait(predicate, seconds, step=0.25):
    """Test harness wait: polls a socket read until it holds or the bound ends."""
    end = time.time() + seconds
    while time.time() < end:
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def sidebar_rows():
    return [r for w in (rpc("debug.sidebar_rows") or {}).get("windows") or [] for r in w.get("rows") or []]


def first_pane():
    windows = (rpc("debug.pane_chrome") or {}).get("windows") or []
    panes = windows[0].get("panes") if windows else None
    return (windows[0], panes[0]) if panes else (None, None)


def png_width(path):
    """The PNG's width from its IHDR chunk (0 when unreadable)."""
    try:
        with open(path, "rb") as f:
            head = f.read(24)
        return int.from_bytes(head[16:20], "big") if head[:8] == b"\x89PNG\r\n\x1a\n" else 0
    except OSError:
        return 0


def right_click(name, x, y, attempts=3):
    """A real right-click at window point (x, y) (top-left origin), the open menu captured, then Escape.
    A capture without the menu (a sliver: the menu window was not up yet) is taken again."""
    path = os.path.join(opts.out, f"{name}.png")
    for attempt in range(attempts):
        say(f"{name}: right-click at ({x:.0f}, {y:.0f})", json.dumps(rpc("debug.mouse", {"x": x, "y": y, "action": "click", "button": "right"}, timeout=5)))
        time.sleep(1.2 + attempt)  # test harness: the menu opens and its highlight fades in
        report["menus"][name] = rpc("debug.menu", timeout=5)
        if CAPTURE:
            done = subprocess.run(["bash", CAPTURE, "shot", "--pid", str(app.pid), "--with-popups", "--out", path],
                                  capture_output=True, text=True, timeout=90)
            say(f"{name}: capture", done.returncode, (done.stdout + done.stderr).strip()[-160:])
        else:
            rpc("debug.window_snapshot", {"path": path})
        rpc("debug.key", {"key": "escape"}, timeout=5)
        time.sleep(0.6)  # test harness: the menu closes
        if png_width(path) >= 200:
            return
    report["missing"].append(name)


def shoot_all(suffix):
    window, pane = first_pane()
    if not pane:
        report["missing"].append(f"panes{suffix}")
        say("no pane in debug.pane_chrome", json.dumps(rpc("debug.pane_chrome"))[:400])
        return
    strip, border = as_rect(pane["strip"]), as_rect(pane["border"])
    slots = pane.get("tab_slots") or []
    toolbar = as_rect((pane.get("toolbar") or {}).get("frame"))
    mid_y = strip["y"] + strip["height"] / 2
    tabs_end = strip["x"] + (max((s[0] + s[1]) for s in slots) if slots else 0)
    # The + sits right after the last tab.
    right_click(f"plus{suffix}", tabs_end + 14, mid_y)
    if slots:
        right_click(f"tab{suffix}", strip["x"] + slots[0][0] + slots[0][1] / 2, mid_y)
    strip_end = (toolbar["x"] if toolbar else strip["x"] + strip["width"]) - 24
    if strip_end > tabs_end + 60:
        right_click(f"strip{suffix}", strip_end, mid_y)
    right_click(f"terminal{suffix}", border["x"] + border["width"] / 2, border["y"] + border["height"] / 2)
    rows = [r for r in sidebar_rows() if str(r.get("key", "")).startswith("workspace(") and r.get("window_frame")]
    if rows:
        f = rows[0]["window_frame"]
        right_click(f"sidebar-row{suffix}", f["x"] + f["width"] / 2, f["y"] + f["height"] / 2)
    sidebar = as_rect(window.get("sidebar"))
    if sidebar and sidebar.get("width", 0) > 40:
        right_click(f"sidebar-empty{suffix}", sidebar["x"] + sidebar["width"] / 2, sidebar["y"] + sidebar["height"] - 60)


def as_rect(r):
    """debug.pane_chrome's [x, y, width, height] (window points, top-left origin) as a dict."""
    if isinstance(r, list) and len(r) == 4:
        return {"x": r[0], "y": r[1], "width": r[2], "height": r[3]}
    return r if isinstance(r, dict) else None


def rect_ok(r):
    r = as_rect(r)
    return bool(r) and r.get("width", 0) > 0


app = None
code = 0
try:
    with open(CONFIG, "w") as f:
        json.dump({}, f)
    open(GHOSTTY, "w").write("")
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY, "CMUX_NEXT_CHIEF_ISOLATED": "1",
           "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"), "CMUX_NEXT_TEST_WINDOW_FRAME": "60,60,1100,700"}
    log = open(os.path.join(opts.out, "app.log"), "a")
    app = subprocess.Popen([os.path.join(opts.app, "Contents/MacOS/cmux DEV")], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    say("launched pid", app.pid)
    if not wait(lambda: os.path.exists(SOCKET) and sidebar_rows(), 180):
        say("the tagged app did not come up")
        code = 2
        raise SystemExit
    cli("workspace", "current", "rename", "cmux")
    cli("workspace", "create", "--name", "docs")
    rpc("action.run", {"action": "newSurface", "args": {}, "origin": "script"})
    wait(lambda: rect_ok((first_pane()[1] or {}).get("strip")), 30)
    time.sleep(1.5)  # test harness: the tabs and the terminal paint
    for appearance in [a for a in opts.appearance.split(",") if a]:
        theme = {"light": "Catppuccin Latte", "dark": "Catppuccin Mocha"}.get(appearance)
        if theme:
            rpc("settings.set", {"path": "appearance.theme", "value": theme})
        say("appearance", appearance, json.dumps(rpc("debug.appearance", {"mode": appearance}))[:200])
        time.sleep(1.0)  # test harness: the window repaints in the appearance
        shoot_all(f"-{appearance}")
finally:
    json.dump(report, open(os.path.join(opts.out, "context-menu-shots.json"), "w"), indent=1)
    if app is not None:
        say("the job's NX_APP_STOP stops the app (pid %d)" % app.pid)
if code == 0 and report["missing"]:
    code = 1
say("RESULT:", "PASS" if code == 0 else f"FAIL {code} missing {report['missing']}")
sys.exit(code)

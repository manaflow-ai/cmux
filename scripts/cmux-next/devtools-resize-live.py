#!/usr/bin/env python3
"""Live check: dragging the divider of docked Chrome DevTools resizes it, and the size stays
with the tab (cx-d0d.45, R118).

  scripts/cmux-next/devtools-resize-live.py --tag <tag> [--out DIR] [--app PATH]

Launches the tagged app, opens a Chromium tab on a local page and its DevTools (docked)
and drags the divider. By default the app is active and the drag is a real mouse:
cua-driver's, through the window server, where the Chromium page and DevTools windows
must leave the divider to cmux (after a click in DevTools, as when using it). With
--background the app is never activated, so its window is not key (a drag on a window
behind another app's), and the drag is delivered in the app (`debug.mouse`). Checks:

  1. the drag resizes DevTools by about the drag;
  2. a second tab's DevTools takes its own size and the first tab keeps its own;
  3. closing and reopening DevTools keeps the tab's size.

GUI host only (a capture mini). The app is quit and the tag's daemons stopped at the
end. Exits 1 when a check fails.
"""
import argparse, base64, functools, glob, http.server, json, os, plistlib, socket, struct, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="devtools-resize-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--background", action="store_true", help="never activate the app; drag in the app")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
CUA = os.path.expanduser("~/.local/bin/cua-driver")
DRAG = 120  # points
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


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


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    return None


def wait_for(predicate, what, seconds=20):
    value = quiet_wait(predicate, seconds)
    check(bool(value), what)
    return value


def windows():
    report = rpc("debug.focus") or {}
    return report.get("windows") or [] if isinstance(report, dict) else []


def focused_pane(window):
    entry = next((w for w in windows() if w.get("id") == window), None)
    return ((entry or {}).get("model") or {}).get("pane")


def layout():
    report = rpc("debug.cef.devtools_layout") or {}
    return report if isinstance(report, dict) else {}


def docked():
    now = layout()
    return now if now.get("open") and now.get("grab") and now.get("devtools_frame") else None


def extent(now):
    """DevTools' size along its dock axis, in points."""
    frame = now["devtools_frame"]
    return frame[2] if now.get("dock") in ("left", "right") else frame[3]


def cua(tool, params):
    try:
        out = subprocess.run([CUA, "call", tool, json.dumps(params)], capture_output=True, text=True, timeout=60).stdout
        return json.loads(out)
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        return {"error": str(error)}


def png_width(b64):
    data = base64.b64decode(b64[:200] + "=" * (-len(b64[:200]) % 4))
    return struct.unpack(">I", data[16:20])[0] if data[:8] == b"\x89PNG\r\n\x1a\n" else None


def target(now, grow):
    """The divider's grab center and where the drag ends (DevTools `grow` points larger), in
    window points from the top left."""
    x, y, w, h = now["grab"]
    start = (x + w / 2, y + h / 2)
    end = {"bottom": (start[0], start[1] - grow), "right": (start[0] - grow, start[1]),
           "left": (start[0] + grow, start[1])}[now["dock"]]
    return start, end


def real_drag(now, grow):
    """cua-driver's drag (window-local screenshot pixels)."""
    found = [w for w in (cua("list_windows", {"pid": app.pid}).get("windows") or []) if w.get("title") == "cmux"]
    if not found:
        return print("cua-driver lists no cmux window", flush=True)
    window_id = found[0]["window_id"]
    state = cua("get_window_state", {"pid": app.pid, "window_id": window_id, "include_accessibility_tree": False})
    width = png_width(state.get("screenshot_png_b64") or "")
    scale = (width / now["window_frame"][2]) if width else 1.0
    titlebar = now["window_frame"][3] - now["content_height"]
    (sx, sy), (ex, ey) = target(now, grow)
    params = {"pid": app.pid, "window_id": window_id, "from_x": round(sx * scale), "from_y": round((sy + titlebar) * scale),
              "to_x": round(ex * scale), "to_y": round((ey + titlebar) * scale), "delivery_mode": "foreground"}
    # A click in DevTools first, as when using it: its window takes key from cmux's.
    tools = now["devtools_frame"]
    click = {"pid": app.pid, "window_id": window_id, "x": round((tools[0] + tools[2] / 2) * scale),
             "y": round((tools[1] + tools[3] / 2 + titlebar) * scale), "delivery_mode": "foreground"}
    cua("click", click)
    time.sleep(1)
    print("after a click in DevTools: cmux window key", layout().get("window_key"), flush=True)
    print("cua drag", params, json.dumps(cua("drag", params))[:300], flush=True)


def synthesized_drag(now, grow, window):
    (sx, sy), (ex, ey) = target(now, grow)
    for action, extra in (("down", {"x": sx, "y": sy}), ("drag", {"x": sx, "y": sy, "to_x": ex, "to_y": ey, "press": False, "release": False}),
                          ("up", {"x": ex, "y": ey})):
        print("synthesized", action, rpc("debug.mouse", {"window": window, "action": action, **extra}), flush=True)


def serve():
    root = tempfile.mkdtemp(prefix="devtools-page-")
    with open(os.path.join(root, "index.html"), "w") as f:
        f.write("<!doctype html><title>devtools resize</title><h1>DevTools resize</h1>")
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
    handler.log_message = lambda *args: None
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/index.html"


APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
# DevTools starts from the last size used (user defaults): start from the default.
subprocess.run(["defaults", "delete", INFO["CFBundleIdentifier"], "CmuxNextBrowser.devToolsLayout"], capture_output=True)
SCRATCH = tempfile.mkdtemp(prefix=f"devtools-resize-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
teardown = TagTeardown(APP)
teardown.install()
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation",
    "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800", **({"CMUX_NEXT_NO_ACTIVATE": "1"} if opts.background else {})},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, out {opts.out}", flush=True)
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), "app socket", 180)
    if not windows():
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    window = (wait_for(lambda: windows(), "a window", 60) or [{}])[0].get("id")
    if not quiet_wait(lambda: focused_pane(window), 15):
        rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})
    wait_for(lambda: focused_pane(window), "a focused pane", 60)
    url = serve()
    if not opts.background and not os.path.exists(CUA):
        sys.exit(f"no {CUA}: run on a capture mini, or pass --background")

    def open_tab():
        """A new Chromium tab with DevTools docked; its id and layout, or None."""
        reply = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True})
        tab = (reply.get("created") or [None])[0]
        wait_for(lambda: (rpc("browser.page.eval", {"script": "document.title", "tab": tab}) or {}).get("value") == "devtools resize",
                 "the page loads", 60)
        rpc("action.run", {"action": "toggleBrowserDeveloperTools", "origin": "script"})
        if not wait_for(docked, "DevTools opens docked", 30):
            return None, None
        time.sleep(2)
        return tab, layout()


    def drag(before, grow, what):
        """Drags the shown tab's divider; the layout after, or None when DevTools did not resize."""
        if opts.background:
            check(before.get("window_key") is False, "the window is not key")
            synthesized_drag(before, grow, window)
        else:
            real_drag(before, grow)
        after = quiet_wait(lambda: (lambda now: now if now.get("grab") and abs(extent(now) - extent(before)) >= abs(grow) / 2 else None)(layout()), 5)
        size = extent(after or layout())
        check(abs(size - extent(before) - grow) <= 24, f"{what} resizes DevTools by about {grow} pt ({extent(before)} -> {size})")
        return after


    def fraction(now):
        return now["right_fraction" if now.get("dock") in ("left", "right") else "bottom_fraction"]


    # 1. A drag on the divider.
    first, before = open_tab()
    moved = before and drag(before, DRAG, "a drag on the divider" if opts.background else "a real drag on the divider")
    if moved:
        # 2. Sizes per tab.
        second, other = open_tab()
        if other:
            check(abs(extent(other) - extent(moved)) <= 2, f"a new tab's DevTools starts at the last size ({extent(other)})")
            resized = drag(other, -DRAG, "a drag in the second tab")
            kept = (rpc("debug.cef.devtools_layout", {"tab": first}) or {})
            check(resized and abs(fraction(kept) - fraction(moved)) < 0.005,
                  f"the first tab keeps its own size ({fraction(moved):.3f} -> {fraction(kept):.3f})")
            rpc("action.run", {"action": "closeTab", "origin": "script"})
            wait_for(lambda: (layout().get("grab") and layout()), "the first tab shows again", 20)
        # 3. The size stays with the tab when DevTools reopens.
        rpc("action.run", {"action": "toggleBrowserDeveloperTools", "origin": "script"})
        wait_for(lambda: not layout().get("open"), "DevTools closes", 20)
        rpc("action.run", {"action": "toggleBrowserDeveloperTools", "origin": "script"})
        if wait_for(docked, "DevTools reopens docked", 30):
            time.sleep(1)
            check(abs(extent(layout()) - extent(moved)) <= 2, f"reopened DevTools keeps its size ({extent(moved)} -> {extent(layout())})")
finally:
    rpc("action.run", {"action": "quitEndSessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
    teardown.end()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)

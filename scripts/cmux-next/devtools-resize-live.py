#!/usr/bin/env python3
"""Live check: dragging the divider of docked Chrome DevTools resizes it, and the size stays
with the tab (cx-d0d.45, R118).

  scripts/cmux-next/devtools-resize-live.py --tag <tag> [--out DIR] [--app PATH]

Launches the tagged app (active: real input goes to the frontmost app; automation socket,
empty config), opens a Chromium tab on a local page and its DevTools (docked), clicks in
DevTools (its window takes key) and drags the divider with a real mouse: cua-driver's
drag, which goes through the window server, where the Chromium page and DevTools windows
must leave the divider to cmux. Without cua-driver the drag is
synthesized in the app (`debug.mouse`), which shows the resize but not the routing, and
says so. Checks:

  1. the drag moves the divider: DevTools grows by about the drag;
  2. closing and reopening DevTools keeps the new size.

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


def target(now):
    """The divider's grab center and where the drag ends, in window points from the top left."""
    x, y, w, h = now["grab"]
    start = (x + w / 2, y + h / 2)
    end = {"bottom": (start[0], start[1] - DRAG), "right": (start[0] - DRAG, start[1]),
           "left": (start[0] + DRAG, start[1])}[now["dock"]]
    return start, end


def real_drag(now):
    """cua-driver's drag (window-local screenshot pixels); False when it cannot be sent."""
    if not os.path.exists(CUA):
        return False
    found = [w for w in (cua("list_windows", {"pid": app.pid}).get("windows") or []) if w.get("title") == "cmux"]
    if not found:
        print("note: cua-driver lists no cmux window", flush=True)
        return False
    window_id = found[0]["window_id"]
    state = cua("get_window_state", {"pid": app.pid, "window_id": window_id, "include_accessibility_tree": False})
    width = png_width(state.get("screenshot_png_b64") or "")
    scale = (width / now["window_frame"][2]) if width else 1.0
    titlebar = now["window_frame"][3] - now["content_height"]
    (sx, sy), (ex, ey) = target(now)
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
    return True


def synthesized_drag(now, window):
    (sx, sy), (ex, ey) = target(now)
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
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"},
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
    print("open", rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True}), flush=True)
    wait_for(lambda: (rpc("browser.page.eval", {"script": "document.title"}) or {}).get("value") == "devtools resize",
             "the page loads", 60)
    print("devtools", rpc("action.run", {"action": "toggleBrowserDeveloperTools", "origin": "script"}), flush=True)
    before = wait_for(docked, "DevTools opens docked", 30)
    if before:
        time.sleep(2)
        before = layout()
        print("before", json.dumps(before), flush=True)

        # 1. A drag on the divider.
        real = real_drag(before)
        moved = quiet_wait(lambda: (lambda now: now if now.get("grab") and abs(extent(now) - extent(before)) >= DRAG / 2 else None)(layout()), 5)
        if real:
            print("after real drag", json.dumps(layout()), flush=True)
            check(bool(moved) and abs(extent(moved) - extent(before) - DRAG) <= 24,
                  f"a real drag on the divider resizes DevTools by about {DRAG} pt "
                  f"({extent(before)} -> {extent(moved) if moved else extent(layout())})")
        if not moved:
            synthesized_drag(before, window)
            moved = quiet_wait(lambda: (lambda now: now if abs(extent(now) - extent(before)) >= DRAG / 2 else None)(layout()), 5)
            print("after synthesized drag", json.dumps(layout()), flush=True)
            check(bool(moved), f"a drag delivered in the app resizes DevTools ({extent(before)} -> {extent(layout())})"
                  + ("" if real else " (no real mouse: cua-driver missing)"))
        if moved:
            # 2. The size stays with the tab.
            size = extent(moved)
            rpc("action.run", {"action": "toggleBrowserDeveloperTools", "origin": "script"})
            wait_for(lambda: not layout().get("open"), "DevTools closes", 20)
            rpc("action.run", {"action": "toggleBrowserDeveloperTools", "origin": "script"})
            reopened = wait_for(docked, "DevTools reopens docked", 30)
            if reopened:
                time.sleep(1)
                check(abs(extent(layout()) - size) <= 2, f"reopened DevTools keeps its size ({size} -> {extent(layout())})")
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

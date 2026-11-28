#!/usr/bin/env python3
"""Live check: File > Print… of a web page in both engines (cx-d0d.20), and a WebKit page's own
window.print() (cx-d0d.64).

  scripts/cmux-next/print-live.py --tag <tag> [--out DIR] [--app PATH] [--engines chromium,webkit]

Launches the tagged app (no activation, automation socket, empty config), serves a test
page and runs the Print… action (`browserPrint`, the File menu's and the palette's) on it:

  - Chromium: its print preview opens over the page (a Chromium dialog window attached to
    the page window), as the page's own window.print() does; closing the tab closes it;
  - WebKit: the system print panel opens as a sheet on the tab's window. Then the page's own
    window.print() opens it too, and its script goes on once Escape cancels the panel.

Nothing is printed: the panels are left open and the app is quit at the end. Snapshots of
what opened go to --out. GUI host only (a capture mini). Exits 1 when a check fails.
"""
import argparse, functools, glob, http.server, json, os, plistlib, socket, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="print-live-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--engines", default="chromium,webkit")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
PAGE = """<!doctype html><title>print test</title><h1>Print me</h1><p>cmux print test page.</p>
"""
failures = []
TAB = None


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
    result = reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    return result if isinstance(result, dict) else {"value": result}


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
    return rpc("debug.focus").get("windows") or []


def focused_pane(window):
    entry = next((w for w in windows() if w.get("id") == window), None)
    return ((entry or {}).get("model") or {}).get("pane")


def page(script):
    return rpc("browser.page.eval", {"script": script, **({"tab": TAB} if TAB else {})}).get("value")


def prompts(respond=None):
    reply = rpc("debug.browser.prompts", {**({"tab": TAB} if TAB else {}), **({"respond": respond} if respond else {})})
    if respond:
        print("respond", respond, reply, flush=True)
    return reply.get("prompts") or []


def run(engine, script, gesture=True):
    """Runs `script` in the page, with a user gesture unless `gesture` is False; whether it ran."""
    if engine == "chromium":
        reply = rpc("debug.cef.devtools", {"method": "Runtime.evaluate", "params": {"expression": script, "userGesture": gesture}})
        ok = "error" not in reply and "exceptionDetails" not in json.dumps(reply)
    else:
        ok = page(script) is not None
    if not ok:
        print("note: the script did not run:", script, flush=True)
    return ok


def window_list():
    reply = rpc("debug.window_list")
    if "error" in reply:
        check(False, f"debug.window_list answers ({reply})")
    return reply.get("windows") or []


def snapshot(window, name):
    rpc("debug.window_snapshot", {"window": window["id"], "path": os.path.join(opts.out, name + ".png")}, timeout=30)


def print_page(engine):
    reply = rpc("action.run", {"action": "browserPrint", "origin": "script"})
    check("error" not in reply, f"{engine}: the Print… action runs ({reply})")


def chromium_preview():
    """Chromium's print preview: a visible Chromium dialog window over the page window."""
    windows = window_list()
    pages = {w["id"] for w in windows if w.get("kind") == "CefNSWindow"}
    return [w for w in windows if w.get("visible") and w.get("kind") == "NativeWidgetMacNSWindow" and w.get("parent") in pages]


def sheets(main):
    return [w for w in window_list() if w.get("visible") and w.get("kind") == "sheet" and w.get("parent") == main]


def run_engine(engine):
    global TAB
    print(f"== {engine}", flush=True)
    url = serve()
    action = "openBrowser.chromium" if engine == "chromium" else "openBrowser.webkit"
    TAB = (rpc("action.run", {"action": action, "args": {"url": url}, "focus": True}).get("created") or [None])[0]
    if not wait_for(lambda: page("document.readyState === 'complete' && !!document.querySelector('h1')"), f"{engine}: the page loads", 60):
        return
    time.sleep(1)
    main = next((w["id"] for w in window_list() if w.get("kind") == "main"), None)
    if engine == "chromium":
        check(not chromium_preview(), f"{engine}: no print preview before Print…")
        print_page(engine)
        shown = quiet_wait(chromium_preview, 10)
        check(bool(shown), f"{engine}: Print… opens Chromium's print preview over the page ({window_list()})")
        if shown:
            time.sleep(2)
            snapshot(shown[0], "chromium-print-preview")
        rpc("action.run", {"action": "closeTab", "origin": "script"})
        check(bool(quiet_wait(lambda: not chromium_preview(), 10)), f"{engine}: closing the tab closes the preview")
    else:
        check(not sheets(main), f"{engine}: no sheet before Print…")
        print_page(engine)
        shown = quiet_wait(lambda: sheets(main), 10)
        check(bool(shown), f"{engine}: Print… opens the system print panel as a sheet on the window ({window_list()})")
        if shown:
            time.sleep(1)
            snapshot(shown[0], "webkit-print-panel")
            snapshot(next(w for w in window_list() if w["id"] == main), "webkit-window")
        rpc("debug.key", {"key": "escape"})
        check(bool(quiet_wait(lambda: not sheets(main), 10)), f"{engine}: Escape cancels the print panel")
        # window.print() blocks the page until the panel ends: called from a timer so the
        # eval answers, with the title set after it returns (the page cannot answer an
        # eval while blocked, so "printed" only after Escape shows it waited).
        page("setTimeout(() => { window.print(); document.title = 'printed'; }, 0); true")
        shown = quiet_wait(lambda: sheets(main), 10)
        check(bool(shown), f"{engine}: the page's window.print() opens the system print panel ({window_list()})")
        if shown:
            time.sleep(1)
            snapshot(shown[0], "webkit-window-print-panel")
            rpc("debug.key", {"key": "escape"})
            check(bool(quiet_wait(lambda: not sheets(main), 10)), f"{engine}: Escape cancels the page's print panel")
            check(bool(quiet_wait(lambda: page("document.title") == "printed", 10)),
                  f"{engine}: the page's script goes on after the panel ({page('document.title')!r})")
    TAB = None


def serve():
    root = tempfile.mkdtemp(prefix="print-page-")
    with open(os.path.join(root, "index.html"), "w") as f:
        f.write(PAGE)
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
SCRATCH = tempfile.mkdtemp(prefix=f"print-live-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
teardown = TagTeardown(APP)
teardown.install()
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_NO_ACTIVATE": "1",
    "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, out {opts.out}", flush=True)
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), "app socket", 180)
    if not windows():
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    window = (wait_for(lambda: windows(), "a window", 60) or [{}])[0].get("id")
    if not quiet_wait(lambda: focused_pane(window), 15):
        rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})
    wait_for(lambda: focused_pane(window), "a focused pane", 60)
    for engine in opts.engines.split(","):
        run_engine(engine)
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

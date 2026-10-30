#!/usr/bin/env python3
"""Live check: Reopen Closed Tab after a relaunch keeps a browser tab's Back history, in both engines (cx-d0d.11).

  scripts/cmux-next/reopen-closed-history-live.py --tag <tag> [--out DIR] [--app PATH]

A Chrome user who closes a tab, quits, reopens the browser and presses
Cmd-Shift-T expects the tab back with Back to the page before. A local
server serves two pages per tab: A, which goes on to B by itself the
first time, and B. Later loads of A stay on A, so only cmux can bring Back
back. Every page reports its own path to the server (nothing reads a page
through the socket). For a WebKit tab and a Chromium tab:
  1. in the session: the tab reaches B, the person closes it (closeTab)
     and reopens it (Reopen Last Closed Tab) at B; Back goes to A and a
     second Back loads nothing (the app's in-memory history and the
     daemon's copy are not stacked: no Back entry twice);
  2. across a relaunch: a new tab reaches B and the person closes it; after
     the quit and relaunch, Reopen Last Closed Tab brings it back at B and
     Back goes to A.

Quits through the quit action (the daemon keeps the closed history),
relaunches, then quits the app through the socket (by PID if it hangs) and
stops the tag's daemons.
"""
import argparse, glob, http.server, json, os, plistlib, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="reopen-closed-history-live-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"reopen-closed-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
failures = []
RUN = os.urandom(4).hex()
ENGINES = ("webkit", "chromium")

reports = {}  # engine -> the latest {path, chromium} its tab reported
served = set()  # paths served once already
lock = threading.Lock()


def page_html(path, engine, name, phase):
    """A reports itself and, the first time, goes on to B; B reports itself."""
    with lock:
        first = path not in served
        served.add(path)
    act = f"setTimeout(() => location.href = '/b-{engine}-{RUN}-{phase}', 800);" if first and name == "a" else ""
    return f"""<!doctype html><title>{name.upper()} {engine} {RUN}</title>
<body>{name.upper()} {engine}
<script>{act}
const load = Math.random().toString(36).slice(2);
setInterval(() => navigator.sendBeacon('/report', JSON.stringify({{engine: '{engine}', path: location.pathname, load: load, chromium: /Chrome\\//.test(navigator.userAgent)}})), 250);
</script>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.strip("/").split("-")
        name, engine, phase = (parts[0], parts[1], parts[-1]) if len(parts) == 4 else ("", "", "")
        if name not in ("a", "b") or engine not in ENGINES:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = page_html(self.path, engine, name, phase).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            report = json.loads(data)
            reports[report.get("engine")] = report
        except ValueError:
            pass
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
ORIGIN = f"http://127.0.0.1:{server.server_port}"


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def cli(*args, timeout=30):
    return subprocess.run([CLI, "--app-socket", SOCKET, *args], capture_output=True, text=True, timeout=timeout, env=CLI_ENV)


def rpc(method, params=None):
    try:
        r = cli("--json", "app", "call", method, json.dumps(params or {}))
    except subprocess.TimeoutExpired:
        return {"error": f"{method} timed out"}  # a hung app is a FAIL line, and cleanup still runs
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def wait_for(predicate, what, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    check(False, f"timed out: {what}")
    return None



def to_workspace():
    """Leaves a top page (Home shows at first launch; a page has no tabs) for a workspace with a pane."""
    rpc("action.run", {"action": "workspace.selectFirst"})
    rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})
    time.sleep(1)  # the workspace's pane comes up


def at(engine, path):
    report = reports.get(engine) or {}
    # The engine that rendered the page, not just the one asked for.
    if report.get("path") != path or report.get("chromium") != (engine == "chromium"):
        return None
    return report


def tab_at(path):
    tabs = rpc("browser.page.tabs", {"all": True}).get("tabs") or []
    return next((t for t in tabs if path in (t.get("url") or "")), None)


def open_to_b(engine, phase):
    """A new tab of `engine` at A, which goes on to B; B's path."""
    b = f"/b-{engine}-{RUN}-{phase}"
    rpc("action.run", {"action": f"openBrowser.{engine}", "args": {"url": f"{ORIGIN}/a-{engine}-{RUN}-{phase}"}, "focus": True})
    check(wait_for(lambda: at(engine, b), f"{engine}: A goes on to B", 30) is not None,
          f"{engine}: the tab reaches B ({reports.get(engine)})")
    time.sleep(2)  # the history write-back's debounce
    check(tab_at(b) is not None, f"{engine}: the tab at B is listed")
    return b


def close(engine, tab, path):
    rpc("action.run", {"action": "tab.focus", "target": f"tab:{tab['id']}", "focus": True})
    reply = rpc("debug.toast", {"perform": "closeTab"})
    check(reply.get("performed") is True, f"{engine}: a person's Close Tab runs ({reply})")
    check(wait_for(lambda: tab_at(path) is None, f"{engine}: the tab closes", 10) is not None,
          f"{engine}: the tab is closed")


app = None


def launch():
    global app
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    app = subprocess.Popen([BINARY], env={**BASE_ENV, "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
                                          "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": EMPTY_GHOSTTY},
                           stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT)
    print(f"app pid {app.pid}, scratch {SCRATCH}, origin {ORIGIN}, out {opts.out}", flush=True)
    return wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), "app socket", 120)


def end(action):
    rpc("action.run", {"action": action} if action != "quit" else {"id": "quit"})
    try:
        app.wait(timeout=30)
    except subprocess.TimeoutExpired:
        app.kill()  # the PID launched above, never a pattern
        app.wait()


write(CONFIG, "{}\n")
EMPTY_GHOSTTY = os.path.join(SCRATCH, "ghostty-config")
write(EMPTY_GHOSTTY, "")
teardown = TagTeardown(APP)
teardown.install()
try:
    launch()
    to_workspace()
    # In the session: the app's own copy restores the tab, and the daemon's
    # copy is not stacked on it (no Back entry twice).
    for engine in ENGINES:
        b = open_to_b(engine, "s")
        tab = tab_at(b)
        if tab is None:
            continue
        close(engine, tab, b)
        reply = rpc("debug.toast", {"perform": "reopenClosedBrowserPanel"})
        check(reply.get("performed") is True, f"{engine}: a person's Reopen Last Closed Tab runs in the session ({reply})")
        check(wait_for(lambda: at(engine, b), f"{engine}: the tab reopens at B", 30) is not None,
              f"{engine}: the tab reopened in the session shows B ({reports.get(engine)})")
        time.sleep(1)  # the saved history reaches the page
        rpc("debug.toast", {"perform": "browserBack"})
        a = b.replace("/b-", "/a-")
        first = wait_for(lambda: at(engine, a), f"{engine}: Back reaches A in the session", 15)
        check(first is not None, f"{engine}: Back after an in-session reopen goes to A ({reports.get(engine)})")
        if first is not None:
            rpc("debug.toast", {"perform": "browserBack"})
            time.sleep(3)  # a duplicated A entry would load again by now
            again = reports.get(engine) or {}
            check(again.get("path") == a and again.get("load") == first.get("load"),
                  f"{engine}: a second Back loads nothing, A is not listed twice ({again})")
        tab = tab_at(a)
        if tab is not None:
            close(engine, tab, a)
    # Across a relaunch: only the daemon's copy is left.
    for engine in ENGINES:
        b = open_to_b(engine, "r")
        tab = tab_at(b)
        if tab is not None:
            close(engine, tab, b)
    end("quit")
    reports.clear()
    launch()
    # Newest first: the Chromium tab, then the WebKit one.
    for engine in reversed(ENGINES):
        b = f"/b-{engine}-{RUN}-r"
        reply = rpc("debug.toast", {"perform": "reopenClosedBrowserPanel"})
        check(reply.get("performed") is True, f"{engine}: a person's Reopen Last Closed Tab runs ({reply})")
        check(wait_for(lambda: at(engine, b), f"{engine}: the reopened tab shows B", 30) is not None,
              f"{engine}: the reopened tab shows B ({reports.get(engine)})")
        time.sleep(1)  # the saved history reaches the page
        tab = tab_at(b)
        if tab is not None:  # the reopened tab may sit in the window its group closed in
            rpc("action.run", {"action": "tab.focus", "target": f"tab:{tab['id']}", "focus": True})
        reply = rpc("debug.toast", {"perform": "browserBack"})
        check(reply.get("performed") is True, f"{engine}: a person's Back runs ({reply})")
        check(wait_for(lambda: at(engine, b.replace("/b-", "/a-")), f"{engine}: Back reaches A", 15) is not None,
              f"{engine}: Back after reopening goes to A ({reports.get(engine)})")
finally:
    if app and app.poll() is None:
        end("quitEndSessions")
    teardown.end()
    server.shutdown()
    server.server_close()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)

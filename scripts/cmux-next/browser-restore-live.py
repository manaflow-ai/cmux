#!/usr/bin/env python3
"""Live check: browser tabs keep Back and scroll across a relaunch, in both engines (cx-d0d.71).

  scripts/cmux-next/browser-restore-live.py --tag <tag> [--out DIR] [--app PATH]

A Chrome user who quits and reopens expects each tab where it was: the page,
how far it was scrolled, and Back to the page before. A local server serves
two pages per engine: A, which goes on to B by itself the first time, and
B, a tall page that scrolls itself down the first time. Later loads do
neither, so only cmux can bring the scroll position and Back back. Every
page reports its own path and scroll position to the server (nothing reads
a page through the socket). For a WebKit tab and a Chromium tab:
  1. after the quit and relaunch, the tab shows B, scrolled where it was;
  2. Back (the person's browserBack) goes to A.

Quits through the quit action (the daemon keeps the tabs), relaunches, then
quits the app through the socket (by PID if it hangs) and stops the tag's daemons.
"""
import argparse, glob, http.server, json, os, plistlib, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="browser-restore-live-"))
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
SCRATCH = tempfile.mkdtemp(prefix=f"browser-restore-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
failures = []
RUN = os.urandom(4).hex()
SCROLL = 1500
ENGINES = ("webkit", "chromium")

reports = {}  # engine -> the latest {path, scrollY} its tab reported
served = set()  # (engine, page) served once already
lock = threading.Lock()


def page_html(engine, name):
    """A reports itself and, the first time, goes on to B; B is tall and, the first time, scrolls down."""
    with lock:
        first = (engine, name) not in served
        served.add((engine, name))
    act = ""
    if first and name == "a":
        act = f"setTimeout(() => location.href = '/b-{engine}-{RUN}', 800);"
    if first and name == "b":
        act = f"addEventListener('load', () => setTimeout(() => scrollTo(0, {SCROLL}), 300));"
    return f"""<!doctype html><title>{name.upper()} {engine} {RUN}</title>
<body style="margin:0"><div style="height:{6000 if name == 'b' else 400}px">{name.upper()} {engine}</div>
<script>{act}
setInterval(() => navigator.sendBeacon('/report', JSON.stringify({{engine: '{engine}', path: location.pathname, scrollY: scrollY, chromium: /Chrome\\//.test(navigator.userAgent)}})), 250);
</script>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name, engine = self.path.strip("/").split("-")[:2] if "-" in self.path else ("", "")
        if name not in ("a", "b") or engine not in ENGINES:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = page_html(engine, name).encode()
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


def at(engine, path, scrolled=None):
    report = reports.get(engine) or {}
    # The engine that rendered the page, not just the one asked for.
    if report.get("path") != path or report.get("chromium") != (engine == "chromium"):
        return None
    if scrolled is not None and abs((report.get("scrollY") or 0) - scrolled) > 50:
        return None
    return report


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
    for engine in ENGINES:
        rpc("action.run", {"action": f"openBrowser.{engine}", "args": {"url": f"{ORIGIN}/a-{engine}-{RUN}"}, "focus": True})
        check(wait_for(lambda: at(engine, f"/b-{engine}-{RUN}", SCROLL), f"{engine}: A goes on to B, which scrolls down", 30) is not None,
              f"{engine}: the tab reaches B scrolled down ({reports.get(engine)})")
    time.sleep(2)  # the history write-back's debounce
    end("quit")
    reports.clear()
    launch()
    tabs = rpc("browser.page.tabs", {"all": True}).get("tabs") or []
    print("note: tabs after relaunch", [(t.get("id"), t.get("url")) for t in tabs], flush=True)
    for engine in ENGINES:
        tab = next((t for t in tabs if f"/b-{engine}-{RUN}" in (t.get("url") or "")), None)
        check(tab is not None, f"{engine}: the tab comes back at B ({tabs})")
        if tab is None:
            continue
        rpc("action.run", {"action": "tab.focus", "target": f"tab:{tab['id']}", "focus": True})
        check(wait_for(lambda: at(engine, f"/b-{engine}-{RUN}"), f"{engine}: B loads again", 30) is not None,
              f"{engine}: the restored tab shows B ({reports.get(engine)})")
        check(wait_for(lambda: at(engine, f"/b-{engine}-{RUN}", SCROLL), f"{engine}: B scrolls back", 10) is not None,
              f"{engine}: the restored tab scrolls back to where it was ({reports.get(engine)})")
        reply = rpc("debug.toast", {"perform": "browserBack"})
        check(reply.get("performed") is True, f"{engine}: a person's Back runs ({reply})")
        check(wait_for(lambda: at(engine, f"/a-{engine}-{RUN}"), f"{engine}: Back reaches A", 15) is not None,
              f"{engine}: Back after the relaunch goes to A ({reports.get(engine)})")
finally:
    if app and app.poll() is None:
        end("quitEndSessions")
    teardown.end()
    server.shutdown()
    server.server_close()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)

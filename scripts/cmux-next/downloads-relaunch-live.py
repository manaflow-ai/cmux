#!/usr/bin/env python3
"""Live check: the Downloads list is kept across a relaunch, without incognito downloads (cx-d0d.72).

  scripts/cmux-next/downloads-relaunch-live.py --tag <tag> [--out DIR] [--app PATH]

Chrome keeps finished downloads in its Downloads list after a restart. A
local server serves small attachment files. A WebKit tab and a Chromium tab
each download one, and a tab of an incognito window downloads a third
(its record naming no address shows the window is incognito).
After the quit and relaunch, `debug.downloads` (DEBUG builds; the rows the
Downloads menu shows):
  1. lists the WebKit and the Chromium download, finished, with the same
     file and size;
  2. never lists the incognito download.

Quits through the quit action, relaunches, then quits the app through the
socket (by PID if it hangs), stops the tag's daemons and deletes the
downloaded files.
"""
import argparse, glob, http.server, json, os, plistlib, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="downloads-relaunch-live-"))
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
SCRATCH = tempfile.mkdtemp(prefix=f"downloads-relaunch-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
failures = []
RUN = os.urandom(4).hex()
BODY = os.urandom(64 << 10)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.split("?")[0].rsplit("/", 1)[-1]
        if name == f"page-{RUN}.html":
            body = b"<!doctype html><title>page</title>page"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if not name.endswith(f"-{RUN}.bin"):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{name}"')
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

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


def downloads():
    return rpc("debug.downloads").get("downloads") or []


def row(name):
    return next((d for d in downloads() if d.get("filename") == name), None)


def download(action, name, what):
    rpc("action.run", {"action": action, "args": {"url": f"{ORIGIN}/{name}"}, "focus": True})
    done = wait_for(lambda: (r := row(name)) and r.get("status") != "inProgress" and r, f"{what}: the download ends", 30)
    check(bool(done) and done.get("status") == "finished", f"{what}: the download finishes ({done})")
    if done and done.get("destination"):
        written.append(done["destination"])
    return done


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


written = []
write(CONFIG, "{}\n")
EMPTY_GHOSTTY = os.path.join(SCRATCH, "ghostty-config")
write(EMPTY_GHOSTTY, "")
teardown = TagTeardown(APP)
teardown.install()
try:
    launch()
    to_workspace()
    kept = {}
    for engine in ("webkit", "chromium"):
        name = f"{engine}-{RUN}.bin"
        done = download(f"openBrowser.{engine}", name, engine)
        if done:
            kept[name] = done
    secret = f"incognito-{RUN}.bin"
    rpc("action.run", {"action": "newIncognitoWindow", "focus": True})
    time.sleep(2)  # the incognito window comes up
    rpc("action.run", {"action": "openBrowser.webkit", "args": {"url": f"{ORIGIN}/page-{RUN}.html"}, "focus": True})
    time.sleep(2)
    # An incognito tab's daemon record never names its page (about:blank);
    # a normal tab's does: so the window is incognito.
    tabs = rpc("browser.page.tabs", {"all": True}).get("tabs") or []
    check(any(f"/webkit-{RUN}.bin" in (t.get("url") or "") for t in tabs)
          and not any(f"/page-{RUN}.html" in (t.get("url") or "") for t in tabs)
          and any(t.get("focused") and t.get("url") == "about:blank" for t in tabs),
          f"the new window is incognito: its page's record names no address ({tabs})")
    download("openBrowser.webkit", secret, "incognito")
    end("quit")
    launch()
    after = downloads()
    print("note: rows after relaunch", [(d.get("filename"), d.get("status")) for d in after], flush=True)
    for name, before in kept.items():
        found = next((d for d in after if d.get("filename") == name), None)
        check(found is not None and found.get("status") == "finished"
              and found.get("destination") == before.get("destination") and found.get("received") == before.get("received"),
              f"{name}: the finished download is listed after the relaunch ({found})")
    check(not any(d.get("filename") == secret for d in after), f"the incognito download is not listed after the relaunch ({after})")
finally:
    if app and app.poll() is None:
        end("quitEndSessions")
    teardown.end()
    server.shutdown()
    server.server_close()
    for path in written:
        if path and os.path.isfile(path) and RUN in os.path.basename(path):
            os.remove(path)

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)

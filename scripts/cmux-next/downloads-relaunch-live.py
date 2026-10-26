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

Every launch goes through bench_launch.BenchApp (the bench env, a scratch
cmux.json and Ghostty config, the window on the last screen, the GUI-session
check). It may activate (the downloads are focused actions) and stays an
isolated launch (CMUX_NEXT_ISOLATED_LAUNCH). Quits through the quit action and
relaunches on the same tag with its saved state (launch_journey_report.relaunch),
then BenchApp.stop quits the app (by PID if it hangs) and ends the tag's
daemons; the downloaded files are deleted. A correctness check: it measures
nothing, so it writes no result-v1.
"""
import argparse, glob, http.server, json, os, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
import launch_journey_report as journey  # noqa: E402
from bench_launch import BenchApp  # noqa: E402

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
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
# One BenchApp for both launches: the second is a relaunch on the same tag.
BENCH = BenchApp(APP, out=opts.out, config={}, window=None, screen="last", log_name="app.log",
                 env={"CMUX_NEXT_NO_ACTIVATE": None, "CMUX_NEXT_ISOLATED_LAUNCH": "1"})
if BENCH.tag != opts.tag:
    sys.exit(f"--tag {opts.tag} is not the tag of {APP} ({BENCH.tag})")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
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


def cli(*args, timeout=30):
    env = {**BASE_ENV, "CMUX_SOCKET_PATH": BENCH.socket, "CMUX_QUIET": "1"}
    return subprocess.run([CLI, "--app-socket", BENCH.socket, *args], capture_output=True, text=True, timeout=timeout,
                          env=env)


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


def launch(first):
    """The first launch, or the relaunch on the same tag; raises LaunchError (a SystemExit) with the reason when the
    app does not come up."""
    if first:
        BENCH.launch(timeout=120)
        journey.remember(BENCH)
    else:
        journey.relaunch(BENCH, timeout=120)
    print(f"app pid {BENCH.process.pid}, origin {ORIGIN}, out {opts.out}", flush=True)
    return wait_for(lambda: "error" not in rpc("debug.focus"), "app socket", 120)


def end(action):
    app = BENCH.process
    rpc("action.run", {"action": action} if action != "quit" else {"id": "quit"})
    try:
        app.wait(timeout=30)
    except subprocess.TimeoutExpired:
        app.kill()  # the PID launched above, never a pattern
        app.wait()


written = []
try:
    launch(first=True)
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
    launch(first=False)
    after = downloads()
    print("note: rows after relaunch", [(d.get("filename"), d.get("status")) for d in after], flush=True)
    for name, before in kept.items():
        found = next((d for d in after if d.get("filename") == name), None)
        check(found is not None and found.get("status") == "finished"
              and found.get("destination") == before.get("destination") and found.get("received") == before.get("received"),
              f"{name}: the finished download is listed after the relaunch ({found})")
    check(not any(d.get("filename") == secret for d in after), f"the incognito download is not listed after the relaunch ({after})")
finally:
    BENCH.stop()  # debug.quit ending the sessions (TERM, then KILL of its own PID), then the tag's daemons
    server.shutdown()
    server.server_close()
    for path in written:
        if path and os.path.isfile(path) and RUN in os.path.basename(path):
            os.remove(path)

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)

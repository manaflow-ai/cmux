#!/usr/bin/env python3
"""Live check: the Downloads menu's Pause, Resume and Retry in both engines (cx-d0d.69).

  scripts/cmux-next/downloads-live.py --tag <tag> [--out DIR] [--app PATH]

A local server serves a slow file (Range requests honoured, as a real server's)
and a file whose first response breaks off partway. In a WebKit tab and in a
Chromium tab:
  1. the slow download can pause (no bytes arrive while paused), resume (WebKit
     with a Range request for the rest), and lands whole;
  2. the broken download fails, offers Retry, and a retry lands whole in its
     place in the list;
  3. (Chromium) a download Chromium resumes by itself after the connection
     breaks continues in its row and file, with no automatic-downloads question.
`debug.downloads` (DEBUG builds) lists the App's downloads list and runs the
Downloads menu's Pause, Resume and Retry on a row, as a click there does.

Quits the app through the socket (by PID if it hangs), stops the tag's daemons and deletes the downloaded files at the end.
"""
import argparse, glob, hashlib, http.server, json, os, plistlib, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="downloads-live-"))
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
SCRATCH = tempfile.mkdtemp(prefix=f"downloads-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
failures = []
RUN = os.urandom(4).hex()

SIZE = 3 << 20
CHUNK = 32 << 10
BODY = hashlib.sha256(RUN.encode()).digest() * (SIZE // 32)
DIGEST = hashlib.sha256(BODY).hexdigest()
ETAG = f'"{DIGEST[:16]}"'
served = {}  # path -> full (no Range) responses so far
requests = []  # (seconds, path, Range header) of every request, for a failure's note
lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        path = self.path.split("?")[0]
        name = path.rsplit("/", 1)[-1]
        ranged = self.headers.get("Range")
        requests.append((round(time.monotonic(), 1), path, ranged))
        with lock:
            count = served.get(path, 0)
            if not ranged:
                served[path] = count + 1
        # A resumable file breaks off once and then serves its rest to a Range request.
        broken_once = path.startswith("/resumable-") and count == 0 and not ranged
        if path.startswith("/broken-") and ranged:
            # No partial resume of the broken file (Chromium resumes an
            # interrupted download by itself): it fails for good.
            return self.plain(500)
        start = 0
        if ranged and ranged.startswith("bytes=") and self.headers.get("If-Range", ETAG) == ETAG:
            start = int(ranged[6:].split("-")[0] or 0)
        self.send_response(206 if start else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{name}"')
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", ETAG)
        self.send_header("Last-Modified", "Mon, 05 Oct 2026 00:00:00 GMT")
        self.send_header("Content-Length", str(SIZE - start))
        if start:
            self.send_header("Content-Range", f"bytes {start}-{SIZE - 1}/{SIZE}")
        self.end_headers()
        slow = path.startswith("/slow-")
        broken = (path.startswith("/broken-") and count == 0) or broken_once
        offset = start
        try:
            while offset < SIZE:
                if broken and offset >= SIZE // 4:
                    self.close_connection = True
                    self.connection.shutdown(2)  # breaks off mid-body
                    return
                self.wfile.write(BODY[offset:offset + CHUNK])
                offset += CHUNK
                if slow:
                    time.sleep(0.06)  # about 6 s in all
        except OSError:
            pass

    def plain(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
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


def downloads(**params):
    return rpc("debug.downloads", params).get("downloads") or []


def row(name, newest=True):
    found = [d for d in downloads() if d.get("filename") == name]
    return (found[-1] if newest else found[0]) if found else None


def landed(item):
    """The finished row's file holds every byte the server sent."""
    path = item.get("destination") or ""
    if not os.path.isfile(path):
        return False
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest() == DIGEST


written = []
write(CONFIG, "{}\n")
EMPTY_GHOSTTY = os.path.join(SCRATCH, "ghostty-config")
write(EMPTY_GHOSTTY, "")
teardown = TagTeardown(APP)
teardown.install()
app = subprocess.Popen([BINARY], env={**BASE_ENV, "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
                                      "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": EMPTY_GHOSTTY},
                       stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT)
print(f"app pid {app.pid}, scratch {SCRATCH}, origin {ORIGIN}, out {opts.out}", flush=True)
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), "app socket", 120)
    to_workspace()
    check("error" not in rpc("debug.downloads"), f"debug.downloads answers ({rpc('debug.downloads')})")
    for engine in ("webkit", "chromium"):
        slow = f"slow-{engine}-{RUN}.bin"
        rpc("action.run", {"action": f"openBrowser.{engine}", "args": {"url": f"{ORIGIN}/{slow}"}, "focus": True})
        item = wait_for(lambda: (r := row(slow)) and r.get("received", 0) > 0 and r, f"{engine}: the slow download runs", 30)
        if item:
            check(item.get("canPause") is True, f"{engine}: a running download can pause ({item})")
            downloads(pause=item["id"])
            paused = wait_for(lambda: (r := row(slow)) and r.get("paused") and r, f"{engine}: the download pauses", 10)
            if paused:
                time.sleep(1)  # in-flight bytes settle
                before = row(slow).get("received")
                time.sleep(2)
                after = row(slow)
                check(after.get("paused") and after.get("received") == before and after.get("status") == "inProgress",
                      f"{engine}: no bytes arrive while paused ({before} then {after})")
                downloads(resume=item["id"])
            done = wait_for(lambda: (r := row(slow)) and r.get("status") != "inProgress" and r, f"{engine}: the slow download ends", 60)
            if done:
                written.append(done.get("destination"))
                check(done.get("status") == "finished" and landed(done), f"{engine}: the resumed download lands whole ({done})")
                if engine == "webkit":
                    # WebKit's Pause cancels with resume data; Chromium's holds the connection open.
                    ranges = [r for _, p, r in requests if p == f"/{slow}" and r]
                    check(bool(ranges), f"{engine}: Resume asks for the rest, not the whole file again ({ranges})")

        broken = f"broken-{engine}-{RUN}.bin"
        rpc("action.run", {"action": f"openBrowser.{engine}", "args": {"url": f"{ORIGIN}/{broken}"}, "focus": True})
        failed = wait_for(lambda: (r := row(broken)) and r.get("status") not in (None, "inProgress") and r, f"{engine}: the broken download ends", 60)
        if not failed:
            print("note: broken row", row(broken), "prompts", rpc("debug.browser.prompts"), "requests", requests[-8:], flush=True)
        if failed:
            check(failed.get("status") == "failed", f"{engine}: the broken download fails ({failed})")
            check(failed.get("canRetry") is True, f"{engine}: a failed download offers Retry ({failed})")
            downloads(retry=failed["id"])
            retried = wait_for(lambda: (r := row(broken)) and r.get("id") != failed["id"] and r.get("status") != "inProgress" and r,
                               f"{engine}: the retry ends", 60)
            if retried:
                written.append(retried.get("destination"))
                check(retried.get("status") == "finished" and landed(retried), f"{engine}: the retry lands whole ({retried})")
                rows = [d for d in downloads() if d.get("filename", "").startswith(f"broken-{engine}-{RUN}")]
                check(len(rows) == 1, f"{engine}: the retry takes the failed row's place ({rows})")
    # Chromium resumes an interrupted download by itself: it continues in its row,
    # into its file, with no automatic-downloads question.
    resumable = f"resumable-chromium-{RUN}.bin"
    rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": f"{ORIGIN}/{resumable}"}, "focus": True})
    done = wait_for(lambda: (r := row(resumable)) and r.get("status") != "inProgress" and r, "chromium: the resumable download ends", 60)
    if done:
        written.append(done.get("destination"))
        rows = [d for d in downloads() if d.get("filename", "").startswith(f"resumable-chromium-{RUN}")]
        resumed = [r for _, p, r in requests if p == f"/{resumable}" and r]
        check(done.get("status") == "finished" and landed(done) and len(rows) == 1 and resumed,
              f"chromium: Chromium's own resume lands whole in one row ({rows}, ranges {resumed})")
        prompts = rpc("debug.browser.prompts").get("prompts") or []
        check(not any("automaticDownloads" in p.get("kind", "") for p in prompts), f"chromium: its resume asks nothing ({prompts})")
finally:
    rpc("action.run", {"action": "quitEndSessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the PID launched above, never a pattern
    teardown.end()
    server.shutdown()
    for path in written:
        if path and os.path.isfile(path) and RUN in os.path.basename(path):
            os.remove(path)

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)

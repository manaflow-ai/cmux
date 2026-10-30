#!/usr/bin/env python3
"""Live check: a PDF link opens in the tab, in both engines (cx-d0d.70).

  scripts/cmux-next/pdf-live.py --tag <tag> [--out DIR] [--app PATH]

A daily Chrome user opens PDFs in the browser. A local server serves a small
PDF inline (Content-Type application/pdf). In a WebKit tab and in a Chromium
tab:
  1. the tab shows the PDF: its document is the PDF (`document.contentType`),
     in Chromium its PDF viewer loads it (the tab takes the PDF's own title);
     a screenshot of each tab is kept in --out;
  2. nothing is downloaded: no file of that name lands in ~/Downloads.

Quits the app through the socket (by PID if it hangs) and stops the tag's daemons at the end.
"""
import argparse, base64, glob, http.server, json, os, plistlib, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="pdf-live-"))
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
SCRATCH = tempfile.mkdtemp(prefix=f"pdf-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
DOWNLOADS = os.path.expanduser("~/Downloads")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
failures = []
RUN = os.urandom(4).hex()
TAB = None


def pdf(text):
    """A one-page PDF that shows `text`."""
    stream = f"BT /F1 24 Tf 72 720 Td ({text}) Tj ET".encode()
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
               b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
               f"<< /Title (cmux PDF {RUN}) >>".encode()]
    body, offsets = b"%PDF-1.4\n", []
    for number, content in enumerate(objects, 1):
        offsets.append(len(body))
        body += b"%d 0 obj\n" % number + content + b"\nendobj\n"
    xref = len(body)
    body += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    body += b"".join(b"%010d 00000 n \n" % offset for offset in offsets)
    body += b"trailer\n<< /Size %d /Root 1 0 R /Info 6 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return body


PDF = pdf(f"cmux PDF {RUN}")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/pdf")
        self.send_header("Content-Length", str(len(PDF)))
        self.end_headers()
        self.wfile.write(PDF)

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


def tab_title():
    """The tab's title as the engine reports it (the PDF viewer sets it from its own frame)."""
    return rpc("browser.page.state", {"tab": TAB}).get("title")


def page(script):
    return rpc("browser.page.eval", {"script": script, **({"tab": TAB} if TAB else {})}).get("value")


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
    for engine in ("webkit", "chromium"):
        name = f"doc-{engine}-{RUN}.pdf"
        reply = rpc("action.run", {"action": f"openBrowser.{engine}", "args": {"url": f"{ORIGIN}/{name}"}, "focus": True})
        TAB = (reply.get("created") or [None])[0]
        check(TAB is not None, f"{engine}: a tab opens on the PDF ({reply})")
        if TAB is None:
            continue  # page() would read whichever tab has focus
        kind = wait_for(lambda: page("document.contentType") == "application/pdf" and "application/pdf",
                        f"{engine}: the tab's document is the PDF", 30)
        check(kind is not None, f"{engine}: the PDF shows in the tab ({page('[document.contentType, location.href, document.title]')})")
        if engine == "chromium":
            # Chromium's PDF viewer names the tab after the PDF's own title once PDFium has loaded it.
            title = wait_for(lambda: tab_title() == f"cmux PDF {RUN}", "chromium: the PDF viewer loads the PDF", 30)
            check(title is not None, f"chromium: Chromium's PDF viewer loads the PDF ({rpc('browser.page.state', {'tab': TAB})})")
        shot = rpc("browser.page.screenshot", {"tab": TAB})
        if isinstance(shot, dict) and shot.get("png_base64"):
            with open(os.path.join(opts.out, f"{engine}-pdf.png"), "wb") as f:
                f.write(base64.b64decode(shot["png_base64"]))
        else:
            print(f"note: {engine}: no screenshot ({shot.get('error') if isinstance(shot, dict) else shot})", flush=True)
        time.sleep(3)  # a download would have landed by now
        landed = [f for f in os.listdir(DOWNLOADS) if RUN in f] if os.path.isdir(DOWNLOADS) else []
        check(not landed, f"{engine}: the PDF is not downloaded ({landed})")
finally:
    rpc("action.run", {"action": "quitEndSessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the PID launched above, never a pattern
    teardown.end()
    server.shutdown()
    server.server_close()
    # A PDF downloaded by mistake carries this run's id; nothing else is touched.
    for name in (os.listdir(DOWNLOADS) if os.path.isdir(DOWNLOADS) else []):
        if RUN in name:
            os.remove(os.path.join(DOWNLOADS, name))

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)

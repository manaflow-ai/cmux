#!/usr/bin/env python3
"""Render check of the trimmed CEF paks (cef-pak-drop.py) in a built, tagged cmux-next app.

Launches the tagged app itself (no activation, scratch config: Chromium is the default
engine), opens one Chromium tab and visits the pages cmux keeps: a plain page, a PDF, an
error page, a permission prompt, a download, Settings sections, Extensions, Downloads,
Version, Policy, print preview and DevTools, plus the routed pages (History, Bookmarks,
New Tab). For each it saves a page screenshot and a screen capture, and reads the page:
its text through shadow roots, and on a WebUI page every loadTimeData string that is
empty (a string the trim emptied that the page still reads shows up here).

  cef-pak-render-check.py --tag T --app "<...>/cmux DEV T.app" --out DIR
Fleet: scripts/measure/cef-pak-render.sh builds the app and runs this.
The report is DIR/report.json; it always exits 0 once the app came up, so the
artifact comes back; read the report and the screenshots.
"""
import argparse, http.server, json, os, socketserver, subprocess, sys, tempfile, threading, time, zlib

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
opts = parser.parse_args()
TAG, APP, OUT = opts.tag, os.path.abspath(opts.app.rstrip("/")), os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next(p for p in sorted(os.listdir(os.path.join(APP, "Contents/MacOS"))) if not p.endswith(".dylib"))
BINARY = os.path.join(APP, "Contents/MacOS", BINARY)
SCRATCH = tempfile.mkdtemp(prefix=f"cef-pak-render-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
CLI_ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1", "CMUX_TAG": TAG,
           "CMUX_BUNDLE_ID": f"com.cmuxterm.app.debug.{TAG}", "CMUX_BUNDLED_CLI_PATH": CLI}


def pdf_bytes():
    """A one-page PDF that says 'cef pak render check'."""
    text = b"BT /F1 24 Tf 72 700 Td (cef pak render check) Tj ET"
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            b"<< /Length %d >>\nstream\n" % len(text) + text + b"\nendstream",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    out, offsets = b"%PDF-1.4\n", []
    for i, body in enumerate(objs, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1) + b"".join(b"%010d 00000 n \n" % o for o in offsets)
    return out + b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)


FILES = {
    "/page.html": ("text/html", b"<!doctype html><title>plain page</title><h1>A plain page</h1>"
                   + b"".join(b"<p>line %d of a plain page</p>" % i for i in range(20))),
    "/doc.pdf": ("application/pdf", pdf_bytes()),
    "/perm.html": ("text/html", b"<!doctype html><title>permission</title><h1>Camera permission</h1>"
                   b"<script>navigator.mediaDevices.getUserMedia({video:true}).catch(e=>document.title='denied '+e)</script>"
                   b"<script>navigator.geolocation.getCurrentPosition(()=>{},()=>{})</script>"),
    "/file.bin": ("application/octet-stream", zlib.compress(b"cef pak render check " * 4096)),
}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        kind, body = FILES.get(self.path, ("text/plain", None))
        self.send_response(200 if body is not None else 404)
        self.send_header("Content-Type", kind)
        if self.path == "/file.bin":
            self.send_header("Content-Disposition", "attachment; filename=cef-pak-render.bin")
        body = body if body is not None else b"not found"
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_address[1]}"


def cli(*args, timeout=60):
    try:
        done = subprocess.run([CLI, *args], env=CLI_ENV, capture_output=True, text=True, timeout=timeout)
        return done.returncode, (done.stdout + done.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def wait(check, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def rpc(method, params=None):
    import socket
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30)
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
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


# Text through shadow roots, and the empty strings of a WebUI page's loadTimeData.
READ_PAGE = """(() => {
  const parts = [];
  const walk = (node) => {
    if (!node) return;
    if (node.nodeType === 3) { const t = node.textContent.trim(); if (t) parts.push(t); return; }
    if (node.nodeType !== 1 && node.nodeType !== 11) return;
    if (node.nodeType === 1 && ['SCRIPT', 'STYLE', 'TEMPLATE'].includes(node.tagName)) return;
    if (node.shadowRoot) walk(node.shadowRoot);
    for (const child of node.childNodes) walk(child);
  };
  walk(document.body);
  const text = parts.join(' ');
  let empty = null;
  try {
    const data = (window.loadTimeData && (loadTimeData.data_ || loadTimeData.data)) || null;
    if (data) empty = Object.keys(data).filter((k) => data[k] === '');
  } catch (e) { empty = ['<error ' + e + '>']; }
  return JSON.stringify({url: location.href, title: document.title, chars: text.length,
                         text: text.slice(0, 600), empty_strings: empty});
})()"""


def screen(name):
    path = os.path.join(OUT, f"{name}-screen.png")
    subprocess.run(["screencapture", "-x", path], capture_output=True, timeout=30)
    return path if os.path.exists(path) else None


def visit(name, url, settle=4.0):
    row = {"name": name, "url": url}
    row["navigate"] = cli("browser", "page", "navigate", url)
    cli("browser", "page", "wait", "--load-state", "complete", "--timeout-ms", "15000", timeout=30)
    time.sleep(settle)  # test harness: WebUI pages render after load
    code, out = cli("browser", "page", "eval", READ_PAGE)
    try:
        row["page"] = json.loads(json.loads(out)) if out.startswith('"') else json.loads(out)
    except ValueError:
        row["page"] = {"eval": [code, out[:600]]}
    row["state"] = cli("browser", "page", "state")[1][:400]
    shot = os.path.join(OUT, f"{name}.png")
    row["screenshot"] = cli("browser", "page", "screenshot", "--out", shot)[0] == 0 and shot
    row["screen"] = screen(name)
    print(json.dumps({k: v for k, v in row.items() if k != "page"}), json.dumps(row.get("page"))[:400], flush=True)
    return row


def key(k, modifiers):
    window = ((rpc("debug.windows") or {}).get("windows") or [{}])[0].get("id")
    return rpc("debug.key", {"key": k, "modifiers": modifiers, "window": window, "target": "page"})


def main():
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900"}
    log = open(os.path.join(OUT, f"app-{TAG}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    report = {"tag": TAG, "host": os.uname().nodename, "base": BASE, "rows": []}
    try:
        if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
            print("the tagged app did not come up", flush=True)
            return False
        time.sleep(3)  # test harness: first workspace
        report["open"] = cli("browser", "open", BASE + "/page.html")
        time.sleep(5)  # test harness: CEF starts and the first page loads
        report["ua"] = cli("browser", "page", "eval", "navigator.userAgent")
        rows = report["rows"]
        for name, url in (("plain", BASE + "/page.html"), ("pdf", BASE + "/doc.pdf"),
                          ("error-page", "http://127.0.0.1:9/"), ("permission", BASE + "/perm.html"),
                          ("settings-content", "chrome://settings/content"), ("settings-appearance", "chrome://settings/appearance"),
                          ("settings-privacy", "chrome://settings/privacy"), ("settings-autofill", "chrome://settings/autofill"),
                          ("extensions", "chrome://extensions/"), ("downloads", "chrome://downloads/"),
                          ("version", "chrome://version/"), ("policy", "chrome://policy/"), ("flags", "chrome://flags/"),
                          ("history-routed", "chrome://history/"), ("bookmarks-routed", "chrome://bookmarks/"),
                          ("newtab", "chrome://newtab/"), ("new-tab-page-dropped", "chrome://new-tab-page/")):
            rows.append(visit(name, url))
        # A download, then the Downloads page that lists it.
        cli("browser", "page", "navigate", BASE + "/file.bin")
        report["download"] = cli("browser", "page", "download", "wait", "--timeout-ms", "20000", timeout=40)
        rows.append(visit("downloads-after", "chrome://downloads/"))
        # Print preview (Cmd-P) over a plain page, and DevTools (Cmd-Opt-I).
        visit("plain-again", BASE + "/page.html", settle=1.0)
        report["print_key"] = key("p", ["command"])
        time.sleep(6)  # test harness: print preview renders its first page
        report["print_screen"] = screen("print-preview")
        key("Escape", [])
        time.sleep(1)
        report["devtools_key"] = key("i", ["command", "option"])
        time.sleep(6)  # test harness: DevTools loads its frontend
        report["devtools_screen"] = screen("devtools")
        report["cef"] = rpc("debug.cef")
        return True
    finally:
        json.dump(report, open(os.path.join(OUT, "report.json"), "w"), indent=1)
        app.terminate()
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
        server.shutdown()


sys.exit(0 if main() else 1)

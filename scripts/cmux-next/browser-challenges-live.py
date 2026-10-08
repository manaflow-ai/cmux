#!/usr/bin/env python3
"""HTTP sign-in sheet and certificate interstitial in a WebKit tab (live check, cx-d0d.21).

Starts two local servers on 127.0.0.1: HTTPS with a fresh self-signed
certificate, and HTTP with basic auth (user "ada", a random password). Launches
the tagged app (no activation, automation socket) once per theme, opens each
URL in a WebKit tab (`action.run openBrowser.webkit`), and writes window
snapshots: the interstitial (Back to Safety, Proceed hidden), the sign-in sheet
with "Remember password", and the page after sign-in. The second launch checks
that the remembered password signs in again without a sheet.

  scripts/cmux-next/browser-challenges-live.py --tag <tag> [--out DIR]

Run it only on a fleet GUI host (it opens a window). Exit 1 on any failure.
"""
import argparse, base64, glob, http.server, json, os, plistlib, secrets, socket, ssl, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="browser-challenges-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
TMP = os.environ.get("TMPDIR", "/tmp")
WORK = tempfile.mkdtemp(prefix="browser-challenges-srv-")
PASSWORD = secrets.token_hex(8)
failures, notes = [], []


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Page(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def page(self, text):
        body = f"<html><body style='font:20px -apple-system'>{text}</body></html>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Secure(Page):
    def do_GET(self):
        self.page("self-signed page")


REQUESTS = []


class Basic(Page):
    def do_GET(self):
        want = "Basic " + base64.b64encode(f"ada:{PASSWORD}".encode()).decode()
        REQUESTS.append({"t": round(time.time(), 2), "port": self.server.server_address[1], "path": self.path,
                         "auth": "none" if not self.headers.get("Authorization") else
                                 ("right" if self.headers.get("Authorization") == want else "wrong")})
        if self.headers.get("Authorization") == want:
            self.page("signed in as ada")
            return
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="cmux test"')
        self.send_header("Content-Length", "0")
        self.end_headers()


def serve(handler, port, tls=False):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    if tls:
        cert, key = os.path.join(WORK, "cert.pem"), os.path.join(WORK, "key.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost",
                        "-keyout", key, "-out", cert], check=True, capture_output=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def rpc(method, params=None):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(60)
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


def wait(predicate, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def snap(name):
    path = os.path.join(opts.out, f"{name}.png")
    reply = rpc("debug.window_snapshot", {"path": path})
    if not os.path.exists(path):
        failures.append(f"snapshot {name}: {json.dumps(reply)[:300]}")
    return path


def action(name, args=None):
    # focus: true, so user-origin view changes are allowed (a fresh tag shows Home).
    return rpc("action.run", {"action": name, "args": args or {}, "focus": True})


def open_webkit(url):
    return action("openBrowser.webkit", {"url": url})


def auth_dialog():
    dialogs = (rpc("debug.dialog") or {}).get("dialogs") or []
    return next((d for d in dialogs if d.get("identifier") == "browser.dialog.httpAuth" and d.get("visible")), None)


def run(theme, basic_port, remembered_port=None):
    config = os.path.join(opts.out, f"cmux-{theme.replace(' ', '-')}.json")
    with open(config, "w") as f:
        json.dump({"appearance": {"theme": theme}}, f)
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    log = open(os.path.join(opts.out, "app.log"), "a")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": TMP, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
           "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
           "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,760"}
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    tag = theme.split()[-1].lower()
    try:
        if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 90):
            failures.append(f"{theme}: tagged app did not come up")
            return
        # A workspace of its own (`newTab` is New Workspace): Home has no pane for a tab.
        notes.append({"theme": theme, "workspace": action("newTab")})
        time.sleep(3)
        notes.append({"theme": theme, "open": open_webkit(f"https://localhost:{SECURE_PORT}/")})
        time.sleep(6)
        snap(f"interstitial-{tag}")
        if remembered_port:
            # The previous run checked "Remember password" for this server and its
            # tab is restored: it must sign in without a sheet.
            started = time.time()
            if not wait(lambda: any(r["port"] == remembered_port and r["auth"] == "right" and r["t"] >= started - 30
                                    for r in REQUESTS), 20):
                failures.append(f"{theme}: the remembered password was not sent after a relaunch")
            if auth_dialog():
                failures.append(f"{theme}: a sign-in sheet asked again for the remembered server")
        notes.append({"theme": theme, "open": open_webkit(f"http://localhost:{basic_port}/")})
        dialog = wait(auth_dialog, 30)
        if not dialog:
            failures.append(f"{theme}: no sign-in sheet: {json.dumps(rpc('debug.dialog'))[:400]}")
            return
        values = dialog.get("values") or {}
        if values.get("remember") is not False:
            failures.append(f"{theme}: Remember is not an unchecked box: {values}")
        if dialog.get("scope") == "app":
            failures.append(f"{theme}: the sign-in sheet is app-modal")
        notes.append({"theme": theme, "dialog": {k: dialog.get(k) for k in ("title", "scope", "lines")}})
        rpc("debug.dialog", {"id": dialog["id"], "set": {"user": "ada", "password": PASSWORD, "remember": True}})
        snap(f"signin-sheet-{tag}")
        rpc("debug.dialog", {"id": dialog["id"], "press": "sign-in"})
        time.sleep(4)
        again = auth_dialog()
        notes.append({"theme": theme, "after_sign_in": rpc("debug.dialog"), "requests": list(REQUESTS)})
        if again:
            failures.append(f"{theme}: the sign-in sheet came back after a correct password: {json.dumps(again)[:400]}")
        snap(f"signed-in-{tag}")
    finally:
        rpc("action.run", {"action": "quitEndSessions"})
        try:
            app.wait(30)
        except subprocess.TimeoutExpired:
            app.terminate()
            app.wait(20)


SECURE_PORT, DARK_PORT, LIGHT_PORT = free_port(), free_port(), free_port()
servers = [serve(Secure, SECURE_PORT, tls=True), serve(Basic, DARK_PORT), serve(Basic, LIGHT_PORT)]
try:
    run("Builtin Dark", DARK_PORT)
    run("Builtin Light", LIGHT_PORT, remembered_port=DARK_PORT)
finally:
    for server in servers:
        server.shutdown()
with open(os.path.join(opts.out, "browser-challenges-live.json"), "w") as f:
    json.dump({"pass": not failures, "failures": failures, "notes": notes}, f, indent=1)
for failure in failures:
    print(f"FAIL {failure}")
print("PASS" if not failures else "FAIL", f"(evidence {opts.out})")
sys.exit(0 if not failures else 1)

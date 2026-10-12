#!/usr/bin/env python3
"""Live check: a Chromium tab shows cmux's own error pages, as a WebKit tab does (cx-zjcq).

  scripts/cmux-next/error-pages-live.py --tag <tag> [--out DIR] [--app PATH] [--engines chromium,webkit]

Launches the tagged app (no activation, automation socket, empty config) and, for each
engine, reads what the pane shows over the page (`debug.browser.page_status`):

  1. a host that does not resolve shows cmux's error page (Chromium: with its
     ERR_NAME_NOT_RESOLVED code), not Chromium's own error page;
  2. a self-signed https server at 127.0.0.1 shows cmux's certificate warning, not
     Chromium's interstitial; Proceed loads the page;
  3. the same server as localhost (a name, which HSTS could cover) shows cmux's
     warning too; Proceed loads the page in WebKit, and in Chromium hands the decision
     to Chromium's own interstitial (it enforces HSTS, which cmux cannot see).

The test certificate is made with /usr/bin/openssl in a scratch directory. GUI host only
(a capture mini). The app is quit and the tag's daemons stopped at the end. Exits 1 when
a check fails.
"""
import argparse, ssl, functools, glob, http.server, json, os, plistlib, socket, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="error-pages-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--engines", default="chromium,webkit")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
PAGE = """<!doctype html><title>secure test</title><h1>Reached the page</h1>
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


def page_status(**params):
    """What the pane shows; {} until the tab answers (a tab still being made)."""
    reply = rpc("debug.browser.page_status", {**({"tab": TAB} if TAB else {}), **params})
    return reply if "certificate" in reply else {}


def shown_error():
    status = page_status()
    return status.get("error") if isinstance(status.get("error"), str) and status.get("error") else None


def open_tab(engine, url):
    global TAB
    action = "openBrowser.chromium" if engine == "chromium" else "openBrowser.webkit"
    TAB = (rpc("action.run", {"action": action, "args": {"url": url}, "focus": True}).get("created") or [None])[0]


def close_tab():
    global TAB
    rpc("action.run", {"action": "closeTab", "origin": "script"})
    TAB = None
    time.sleep(1)


def https_server():
    """A self-signed https server for 127.0.0.1 and localhost; its port."""
    scratch = tempfile.mkdtemp(prefix="error-pages-tls-")
    config = os.path.join(scratch, "openssl.cnf")
    with open(config, "w") as f:
        f.write("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n"
                "[ext]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n")
    key, cert = os.path.join(scratch, "key.pem"), os.path.join(scratch, "cert.pem")
    subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-config", config,
                    "-keyout", key, "-out", cert], check=True, capture_output=True)
    root = tempfile.mkdtemp(prefix="error-pages-page-")
    with open(os.path.join(root, "index.html"), "w") as f:
        f.write(PAGE)
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
    handler.log_message = lambda *args: None
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


def reached():
    return page("document.title") == "secure test"


def nested_holes(status):
    """Holes of the Chromium page window inside another one: an even-odd mask cancels them
    (the page then covers cmux's view)."""
    holes = json.loads(status.get("holes") or "[]")
    inside = lambda a, b: a[0] >= b[0] and a[1] >= b[1] and a[0] + a[2] <= b[0] + b[2] and a[1] + a[3] <= b[1] + b[3]
    return [a for i, a in enumerate(holes) for j, b in enumerate(holes) if i != j and inside(a, b)]


def stays_shown(engine, what, predicate):
    """cmux's page is still there after Chromium committed its own page under it."""
    time.sleep(2)
    status = page_status()
    check(predicate(status), f"{engine}: {what} stays shown ({status})")
    if engine == "chromium":
        check(not nested_holes(status), f"{engine}: {what}: no page window hole is inside another ({status.get('holes')})")


def run_engine(engine, port):
    print(f"== {engine}", flush=True)

    # 1. A host that does not resolve.
    open_tab(engine, "http://cmux-zjcq-test.invalid/")
    shown = quiet_wait(shown_error, 30)
    check(bool(shown), f"{engine}: an unresolvable host shows cmux's error page ({page_status()})")
    if engine == "chromium":
        check(bool(shown) and "ERR_NAME_NOT_RESOLVED" in shown, f"{engine}: the error page names the error ({shown!r})")
    if shown:
        stays_shown(engine, "the error page", lambda status: bool(status.get("error")))
    close_tab()

    # 2. and 3. A self-signed certificate: an IP address, then a name.
    for host in ["127.0.0.1", "localhost"]:
        url = f"https://{host}:{port}/index.html"
        open_tab(engine, url)
        warned = quiet_wait(lambda: page_status().get("certificate") == "1", 30)
        check(bool(warned), f"{engine}: {host}'s untrusted certificate shows cmux's certificate warning ({page_status()})")
        if warned:
            stays_shown(engine, f"{host}'s certificate warning", lambda status: status.get("certificate") == "1")
            # Proceed is a person's action (refused over action.run): press the button.
            reply = page_status(press="proceed")
            check(reply.get("pressed") == "1", f"{engine}: Proceed runs on {host} ({reply})")
            if engine == "chromium" and host == "localhost":
                gone = quiet_wait(lambda: page_status().get("enginePage") == "1" and not shown_error(), 20)
                check(bool(gone), f"{engine}: Proceed on a name hands over to Chromium's interstitial ({page_status()})")
            else:
                ok = quiet_wait(reached, 30)
                check(bool(ok) and page_status() and not shown_error(), f"{engine}: Proceed on {host} loads the page ({page_status()})")
        close_tab()


APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
SCRATCH = tempfile.mkdtemp(prefix=f"error-pages-{opts.tag}-")
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
    port = https_server()
    for engine in opts.engines.split(","):
        run_engine(engine, port)
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

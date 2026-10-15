#!/usr/bin/env python3
"""Live check: a Chromium tab shows Chromium's own error pages, a WebKit tab cmux's (cx-zjcq).

  scripts/cmux-next/error-pages-live.py --tag <tag> [--out DIR] [--app PATH] [--engines chromium,webkit]

Lawrence 2026-10-13: Chromium tabs show Chrome's own pages. Launches the tagged app (no
activation, automation socket, empty config) and, for each engine, samples what the pane
shows over the page (`debug.browser.page_status`) every 0.1 s and what the page is
(`browser.page.eval`):

Chromium tab: a host that does not resolve, a refused connection, a self-signed https
server at 127.0.0.1 and https://expired.badssl.com show Chromium's own page (its net
error page, its "Privacy error" certificate interstitial) and cmux's page shows at no
sample (sampling, about every 0.1-0.3 s, cannot catch a one-frame flash; the window
snapshots show the pages). The Chromium checks read the debug socket only: a
browser.page.* call makes a tab agent-driven. An agent-driven tab shows cmux's
certificate warning instead (only a person can Proceed there), and an agent's Proceed
action does not load the page.

WebKit tab (WebKit draws no error page): the same host, the self-signed server and
expired.badssl.com show cmux's error page or certificate warning; Proceed loads the page.

The test certificate is made with /usr/bin/openssl in a scratch directory. GUI host only
(cmux-lawrence-2). Window snapshots (kind main) go to --out. The app is quit and the
tag's daemons stopped at the end. Exits 1 when a check fails.
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


def open_tab(engine, url, agent=False):
    """A tab a person opens (origin remote), or, with `agent`, one an agent opens (origin
    cli: agent-driven before its page exists)."""
    global TAB
    action = "openBrowser.chromium" if engine == "chromium" else "openBrowser.webkit"
    params = {"action": action, "args": {"url": url}, "focus": True}
    if not agent:
        params["origin"] = "remote"
    TAB = (rpc("action.run", params).get("created") or [None])[0]


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


def snap(name):
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, f"{name}.png")}, timeout=60)


def cmux_page_shown(status):
    return bool(status.get("error")) or status.get("certificate") == "1"


def watch(seconds, done):
    """Samples the pane every 0.1 s until `done()` or `seconds`; returns (done seconds or None,
    cmux page seen at any sample)."""
    start = time.monotonic()
    seen_cmux = False
    while time.monotonic() - start < seconds:  # bounded sampling of the app's own state
        if cmux_page_shown(page_status()):
            seen_cmux = True
        if done():
            return time.monotonic() - start, seen_cmux
        time.sleep(0.1)
    return None, seen_cmux


def free_port():
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


def chromium_page(code, title):
    """Chromium's own page for the failed load: the engine-page flag, the error code in the
    tab's navigation events and the page's title. Read through the debug socket only: a
    browser.page.* call would make the tab agent-driven."""
    status = page_status()
    return (status.get("enginePage") == "1" and f"loadError({code}," in (status.get("events") or "")
            and (title is None or status.get("title") == title) and not cmux_page_shown(status))


def run_chromium(port):
    print("== chromium", flush=True)
    cases = [("nxdomain", "http://cmux-zjcq-test.invalid/", -105, None),
             ("refused", f"http://127.0.0.1:{free_port()}/", -102, None),
             ("self-signed", f"https://127.0.0.1:{port}/index.html", -202, "Privacy error"),
             ("expired", "https://expired.badssl.com/", -201, "Privacy error")]
    for name, url, code, title in cases:
        open_tab("chromium", url)
        took, seen_cmux = watch(15, lambda: chromium_page(code, title))
        snap(f"chromium-{name}")
        check(took is not None, f"chromium: {name} shows Chromium's own page (code {code}, title {title!r}): "
              f"{'%.2f s' % took if took is not None else 'not shown'} ({page_status()})")
        check(not seen_cmux, f"chromium: {name}: cmux's page never showed")
        _, late = watch(2, lambda: False)
        check(not late and page_status().get("enginePage") == "1", f"chromium: {name}: still Chromium's page 2 s later ({page_status()})")
        close_tab()
    # An agent-driven tab gets cmux's certificate warning: an agent's page script could
    # press Proceed in Chromium's interstitial; only a person presses cmux's Proceed.
    open_tab("chromium", f"https://127.0.0.1:{port}/index.html", agent=True)
    took, seen_chromium = None, False
    start = time.monotonic()
    while time.monotonic() - start < 30:  # bounded sampling of the app's own state
        status = page_status()
        seen_chromium = seen_chromium or status.get("enginePage") == "1"
        if status.get("certificate") == "1":
            took = time.monotonic() - start
            break
        time.sleep(0.1)
    snap("chromium-agent-driven-self-signed")
    check(took is not None and not seen_chromium,
          f"chromium: an agent-driven tab shows cmux's certificate warning, never Chromium's interstitial ({page_status()})")
    reply = rpc("action.run", {"action": "browser.certificateWarning.proceed", "focus": True})
    check("Only a person" in json.dumps(reply), f"chromium: an agent's Proceed is refused as a person-only action ({json.dumps(reply)[:300]})")
    check(quiet_wait(reached, 5) is None, "chromium: the page does not load after an agent's Proceed")
    close_tab()


def run_webkit(port):
    print("== webkit", flush=True)
    open_tab("webkit", "http://cmux-zjcq-test.invalid/")
    shown = quiet_wait(shown_error, 30)
    snap("webkit-nxdomain")
    check(bool(shown), f"webkit: an unresolvable host shows cmux's error page ({page_status()})")
    close_tab()
    for name, url, proceeds in [("self-signed", f"https://127.0.0.1:{port}/index.html", True),
                                ("expired", "https://expired.badssl.com/", False)]:
        open_tab("webkit", url)
        warned = quiet_wait(lambda: page_status().get("certificate") == "1", 30)
        snap(f"webkit-{name}")
        check(bool(warned), f"webkit: {name} shows cmux's certificate warning ({page_status()})")
        if warned and proceeds:
            # Proceed is a person's action (refused over action.run): press the button.
            reply = page_status(press="proceed")
            check(reply.get("pressed") == "1", f"webkit: Proceed runs ({reply})")
            ok = quiet_wait(reached, 30)
            check(bool(ok) and not shown_error(), f"webkit: Proceed loads the page ({page_status()})")
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
        (run_chromium if engine == "chromium" else run_webkit)(port)
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

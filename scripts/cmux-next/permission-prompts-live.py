#!/usr/bin/env python3
"""Live check: location and notification permission prompts in both engines (cx-d0d.25), and
WebKit web notifications as cmux banners (cx-d0d.63).

  scripts/cmux-next/permission-prompts-live.py --tag <tag> [--out DIR] [--app PATH] [--engines chromium,webkit]

Launches the tagged app (no activation, automation socket, empty config) and serves a test
page (a new port, so a new origin, every run). For each engine:

  1. `getCurrentPosition` asks in the page's prompt bar (not a dialog, not a hang);
     Block fails it with PERMISSION_DENIED, and after a reload a second request
     fails at once with no prompt: the answer is remembered for the site;
  2. WebKit: `Notification.requestPermission()` asks in the prompt bar; Allow
     grants it, and after a reload it is granted with no prompt. A notification the page
     makes before that shows no banner; after it, `new Notification(...)` shows a cmux
     banner on the page's tab (title, the site, the body), and a click on the banner runs
     the page's `onclick`. Chromium has
     no web notifications (`disable-notifications`: DesktopNotifier owns the app's one
     macOS notification authorization), so the page sees no `Notification`.

Location is only ever denied: allowing it would raise the macOS location prompt on the
host. GUI host only (a capture mini). The app is quit and the tag's daemons stopped at
the end. Exits 1 when a check fails.
"""
import argparse, functools, glob, http.server, json, os, plistlib, socket, subprocess, sys, tempfile, threading, time, urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="permission-prompts-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--engines", default="chromium,webkit")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
PAGE = """<!doctype html><title>permission prompts</title>
<script>
window.geo = "idle";
function locate() {
  window.geo = "pending";
  navigator.geolocation.getCurrentPosition(() => { window.geo = "granted"; },
    (e) => { window.geo = "error " + e.code; }, {timeout: 60000});
}
window.notify = "idle";
window.clicked = 0;
function notifyNow(title) {
  const n = new Notification(title, {body: "from the page"});
  n.onclick = () => { window.clicked += 1; };
  return true;
}
function askNotify() {
  window.notify = "pending";
  Notification.requestPermission().then((p) => { window.notify = p; }, (e) => { window.notify = "error " + e; });
}
// ?notify=<title> makes a notification once loaded; ?embed=<url> loads <url> in an iframe.
const query = new URLSearchParams(location.search);
addEventListener("load", () => {
  if (query.get("notify")) notifyNow(query.get("notify"));
  if (query.get("embed")) {
    const frame = document.createElement("iframe");
    frame.src = query.get("embed");
    document.body.appendChild(frame);
  }
});
</script>
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


def prompts(respond=None):
    reply = rpc("debug.browser.prompts", {**({"tab": TAB} if TAB else {}), **({"respond": respond} if respond else {})})
    if respond:
        print("respond", respond, reply, flush=True)
    return reply.get("prompts") or []


def run(engine, script, gesture=True):
    """Runs `script` in the page, with a user gesture unless `gesture` is False; whether it ran."""
    if engine == "chromium":
        reply = rpc("debug.cef.devtools", {"method": "Runtime.evaluate", "params": {"expression": script, "userGesture": gesture}})
        ok = "error" not in reply and "exceptionDetails" not in json.dumps(reply)
    else:
        ok = page(script) is not None
    if not ok:
        print("note: the script did not run:", script, flush=True)
    return ok


def permission_prompts(kind):
    reply = rpc("debug.browser.prompts", {"tab": TAB} if TAB else {})
    if "error" in reply:
        check(False, f"debug.browser.prompts answers ({reply})")
    return [p for p in reply.get("prompts") or [] if kind in p.get("kind", "")]


def state(name):
    return page(f"window.{name}")


def settled(name):
    """The page's `window.<name>` once its request has an answer."""
    return quiet_wait(lambda: state(name) not in ("idle", "pending", None) and state(name), 10)


def load(engine, url):
    """Opens `url` in a new tab of `engine`, or reloads the open one."""
    global TAB
    if TAB is None:
        action = "openBrowser.chromium" if engine == "chromium" else "openBrowser.webkit"
        TAB = (rpc("action.run", {"action": action, "args": {"url": url}, "focus": True}).get("created") or [None])[0]
    else:
        page("location.reload(); true")
        time.sleep(1)
    ok = wait_for(lambda: page("document.readyState === 'complete' && window.geo === 'idle'"), f"{engine}: the page loads", 60)
    time.sleep(1)
    return ok


def banners():
    return rpc("debug.notifications").get("banners") or []


def banner(title):
    return next((b for b in banners() if (b.get("subtitle") or "").split(" · ")[0] == title), None)


def run_engine(engine):
    global TAB
    print(f"== {engine}", flush=True)
    url = serve()
    if not load(engine, url):
        return

    # 1. Location asks in the bar; Block is remembered for the site.
    check(run(engine, "locate(); true"), f"{engine}: the page requests the location")
    shown = quiet_wait(lambda: permission_prompts("location"), 10)
    check(bool(shown), f"{engine}: a location request asks in the prompt bar ({prompts()}, geo {state('geo')})")
    if shown:
        prompts("deny")
        got = settled("geo")
        check(got == "error 1", f"{engine}: Block fails the request with PERMISSION_DENIED ({got})")
        load(engine, url)
        run(engine, "locate(); true")
        got = settled("geo")
        check(got == "error 1" and not permission_prompts("location"),
              f"{engine}: after a reload the site is refused at once, with no prompt ({got}, {prompts()})")

    # 2. Notifications.
    if engine == "chromium":
        check(page("typeof Notification") == "undefined", f"{engine}: the page has no web notifications (by design)")
    else:
        check(run(engine, "notifyNow('cmux early')"), f"{engine}: the page makes a notification before asking")
        time.sleep(2)
        check(banner("cmux early") is None, f"{engine}: a notification without permission shows no banner ({banners()})")
        check(run(engine, "askNotify(); true"), f"{engine}: the page requests notifications")
        shown = quiet_wait(lambda: permission_prompts("notifications"), 10)
        check(bool(shown), f"{engine}: a notification request asks in the prompt bar ({prompts()}, notify {state('notify')})")
        if shown:
            prompts("allow")
            got = settled("notify")
            check(got == "granted", f"{engine}: Allow grants notifications ({got})")
            load(engine, url)
            got = page("Notification.permission")
            check(got == "granted", f"{engine}: after a reload the page reads its permission as granted without asking ({got})")
            run(engine, "askNotify(); true")
            got = settled("notify")
            check(got == "granted" and not permission_prompts("notifications"),
                  f"{engine}: after a reload notifications are granted with no prompt ({got}, {prompts()})")
            check(run(engine, "notifyNow('cmux web notification')"), f"{engine}: the page makes a notification")
            shown = quiet_wait(lambda: banner("cmux web notification"), 10)
            check(bool(shown) and "127.0.0.1" in shown.get("body", "") and "from the page" in shown.get("body", ""),
                  f"{engine}: a granted page's notification shows a cmux banner with its site ({shown}, {banners()})")
            if shown:
                rpc("debug.notifications", {"action": "click", "id": shown["id"], "surface": shown.get("surface")})
                check(bool(quiet_wait(lambda: state("clicked") == 1, 10)),
                      f"{engine}: clicking the banner runs the page's onclick ({state('clicked')})")
                # The next document numbers its notifications afresh: an old banner must not reach them.
                load(engine, url)
                check(run(engine, "notifyNow('cmux second'); true"), f"{engine}: the reloaded page makes a notification")
                second = quiet_wait(lambda: banner("cmux second"), 10)
                check(bool(second), f"{engine}: the reloaded page's notification shows a banner ({banners()})")
                rpc("debug.notifications", {"action": "click", "id": shown["id"], "surface": shown.get("surface")})
                time.sleep(2)
                check(state("clicked") == 0, f"{engine}: the earlier page's banner runs nothing in the reloaded page ({state('clicked')})")
            # A frame of the allowed site inside another site's page: no banner (Chrome refuses
            # notifications from cross-origin frames).
            other = url.replace("127.0.0.1", "localhost") + "?embed=" + urllib.parse.quote(url + "?notify=cmux%20framed")
            page(f"location.href = {json.dumps(other)}; true")
            wait_for(lambda: page("location.hostname === 'localhost' && document.readyState === 'complete'"),
                     f"{engine}: the embedding page loads", 30)
            time.sleep(3)
            check(banner("cmux framed") is None, f"{engine}: an allowed site framed in another site shows no banner ({banners()})")

    rpc("action.run", {"action": "closeTab", "origin": "script"})
    TAB = None


def serve():
    root = tempfile.mkdtemp(prefix="permission-prompts-page-")
    with open(os.path.join(root, "index.html"), "w") as f:
        f.write(PAGE)
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
    handler.log_message = lambda *args: None
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/index.html"


APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
SCRATCH = tempfile.mkdtemp(prefix=f"permission-prompts-{opts.tag}-")
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
    for engine in opts.engines.split(","):
        run_engine(engine)
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

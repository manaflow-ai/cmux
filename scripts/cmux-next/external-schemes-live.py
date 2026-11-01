#!/usr/bin/env python3
"""Live check: a page's links to other apps in both engines (cx-d0d.22).

  scripts/cmux-next/external-schemes-live.py --tag <tag> [--out DIR] [--app PATH] [--engines chromium,webkit]

Launches the tagged app (no activation, automation socket, empty config) as a recording
build (`CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS=1`): links that would open another app are
recorded instead (`debug.browser.external_opens`), so no app starts. Serves a page with
links to mailto:, to an app scheme that is not well known (System Settings,
x-apple.systempreferences:) and to a scheme no app opens, and clicks them with a user
gesture (Chromium: DevTools `Runtime.evaluate` with `userGesture`; WebKit: the page,
which runs the app's scripts as a gesture). For each engine:

  1. a mailto: link opens in its app at once, with no prompt;
  2. the System Settings link asks first, in the page's prompt bar (not a dialog):
     Cancel opens nothing; Open (this time) opens it; asked again, Open with
     "Always allow" opens it, and the next click opens it with no prompt;
  3. a link to a scheme no app opens does nothing and asks nothing;
  4. a script that sets location to mailto: without a click opens nothing.
  5. a cmux sign-in callback from a script or an HTTP redirect asks before
     delivering the exact callback to its registered app; Cancel delivers nothing.

GUI host only (a capture mini). The app is quit and the tag's daemons stopped at the
end. Exits 1 when a check fails.
"""
import argparse, functools, glob, http.server, json, os, plistlib, socket, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="external-schemes-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--engines", default="chromium,webkit")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
MAIL = "mailto:someone@example.com"
SETTINGS = "x-apple.systempreferences:com.apple.preference.security"
NOBODY = "cmux-no-handler-test:x"
PAGE = f"""<!doctype html><title>external schemes</title>
<script>window.clicks = 0; addEventListener("click", () => window.clicks++, true);</script>
<a id="mail" href="{MAIL}">mail</a> <a id="settings" href="{SETTINGS}">settings</a> <a id="nobody" href="{NOBODY}">nobody</a>
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


def opens():
    reply = rpc("debug.browser.external_opens")
    if "error" in reply:
        check(False, f"debug.browser.external_opens answers ({reply})")
    return reply.get("urls") or []


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


def click(engine, link):
    """Clicks `link` with a user gesture; checks the page saw the click (it is still there)."""
    before = page("window.clicks")
    ran = run(engine, f"document.getElementById({json.dumps(link)}).click(); true")
    seen = quiet_wait(lambda: isinstance(before, int) and (page("window.clicks") or 0) > before, 5)
    check(ran and bool(seen), f"{engine}: the page takes the click on #{link} (and is still there)")


def settled_opens(count_before, seconds=3):
    """The URLs opened after the first `count_before`, once nothing new comes for a moment."""
    time.sleep(seconds)
    return opens()[count_before:]


def asked():
    reply = rpc("debug.browser.prompts", {"tab": TAB} if TAB else {})
    if "error" in reply:
        check(False, f"debug.browser.prompts answers ({reply})")
    return [p for p in reply.get("prompts") or [] if "openExternalApp" in p.get("kind", "")]


def run_engine(engine):
    global TAB
    print(f"== {engine}", flush=True)
    # Its own origin: "Always allow" holds for the site in both engines.
    url = serve()
    action = "openBrowser.chromium" if engine == "chromium" else "openBrowser.webkit"
    opened = rpc("action.run", {"action": action, "args": {"url": url}, "focus": True})
    TAB = (opened.get("created") or [None])[0]
    if not wait_for(lambda: page("document.readyState === 'complete' && !!document.getElementById('mail')"),
                    f"{engine}: the page loads", 60):
        return
    time.sleep(1)

    # 4. A script, not a click (first: a click before it would leave Chromium's user activation on).
    before = len(opens())
    # Page eval runs as an agent gesture and leaves Chromium transient activation.
    # A fresh document runs its own onload script before any agent evaluation.
    rpc("browser.page.navigate", {"tab": TAB, "url": url.replace("index.html", "script-mail")})
    got = settled_opens(before)
    check(got == [] and not asked(), f"{engine}: a script's mailto: navigation opens nothing ({got})")

    # Classic's browser fallback returns by HTTP redirect, without a gesture.
    # Record the app open so fixture tokens never reach a real sign-in attempt.
    before = len(opens())
    rpc("browser.page.navigate", {"tab": TAB, "url": url.replace("index.html", "script-callback")})
    scripted_prompt = wait_for(asked, f"{engine}: a scripted sign-in return asks before opening its app", 10)
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, f"{engine}-scripted-return.png")})
    if scripted_prompt:
        check(len(opens()) == before, f"{engine}: the callback waits for consent")
        prompts("cancel")
        check(len(opens()) == before and not asked(), f"{engine}: cancelling delivers no callback")

    before = len(opens())
    rpc("browser.page.navigate", {"tab": TAB, "url": url.replace("index.html", "redirect")})
    redirect_prompt = wait_for(asked, f"{engine}: an HTTP sign-in redirect asks before opening its app", 10)
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, f"{engine}-http-return.png")})
    if redirect_prompt:
        check(len(opens()) == before, f"{engine}: a redirect cannot open an app without consent")
        prompts("allowOnce")
        wait_for(lambda: opens()[before:] == [CALLBACK],
                 f"{engine}: Open delivers the complete sign-in callback exactly once", 10)
    check(page("!!document.getElementById('mail')") is True,
          f"{engine}: a sign-in return preserves the page instead of showing a scheme error")

    # 1. mailto: opens at once.
    before = len(opens())
    click(engine, "mail")
    got = settled_opens(before)
    check(got == [MAIL] and not asked(), f"{engine}: a mailto: link opens in its app with no prompt ({got}, prompts {prompts()})")

    # 2. Another app's scheme asks first, in the prompt bar.
    before = len(opens())
    click(engine, "settings")
    shown = quiet_wait(asked, 10)
    check(bool(shown) and "System Settings" in shown[0]["kind"],
          f"{engine}: a System Settings link asks first, in the prompt bar ({prompts()})")
    check(settled_opens(before, 1) == [], f"{engine}: nothing opens while it asks")
    if shown:
        prompts("cancel")
        check(settled_opens(before) == [] and not asked(), f"{engine}: Cancel opens nothing")
        click(engine, "settings")
        if wait_for(asked, f"{engine}: it asks again", 10):
            prompts("allowOnce")
            check(settled_opens(before) == [SETTINGS], f"{engine}: Open opens it")
        before = len(opens())
        click(engine, "settings")
        if wait_for(asked, f"{engine}: Open without Always allow asks again next time", 10):
            prompts("allow")
            check(settled_opens(before) == [SETTINGS], f"{engine}: Open with Always allow opens it")
        before = len(opens())
        click(engine, "settings")
        got = settled_opens(before)
        check(got == [SETTINGS] and not asked(), f"{engine}: after Always allow it opens with no prompt ({got})")

    # 3. A scheme no app opens: nothing.
    before = len(opens())
    click(engine, "nobody")
    got = settled_opens(before)
    check(got == [] and not asked(), f"{engine}: a scheme no app opens does nothing and asks nothing ({got}, {prompts()})")
    check(page("!!document.getElementById('mail')") is True, f"{engine}: the page is still there (no error page over it)")

    rpc("action.run", {"action": "closeTab", "origin": "script"})
    TAB = None


def serve():
    root = tempfile.mkdtemp(prefix="external-schemes-page-")
    with open(os.path.join(root, "index.html"), "w") as f:
        f.write(PAGE + '<a id="redirect" href="/redirect">return to cmux</a>')

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            if self.path in ("/script-mail", "/script-callback"):
                target = MAIL if self.path == "/script-mail" else CALLBACK
                body = (PAGE + "<script>addEventListener('load', () => { location.href = "
                        + json.dumps(target) + "; });</script>").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif self.path == "/redirect":
                self.send_response(302)
                self.send_header("Location", CALLBACK)
                self.end_headers()
            else:
                super().do_GET()

        def log_message(self, *args):
            pass

    handler = functools.partial(Handler, directory=root)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/index.html"


APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
callback_scheme = next((scheme for entry in INFO.get("CFBundleURLTypes", [])
                        for scheme in entry.get("CFBundleURLSchemes", [])
                        if scheme.startswith("cmux-dev-")), None)
if not callback_scheme:
    sys.exit("the fixture requires a tagged cmux-dev callback scheme")
CALLBACK = (f"{callback_scheme}://auth-callback?stack_refresh=fixture-refresh"
            "&stack_access=fixture-access&cmux_auth_state=fixture-state")
# Register only this test's unique tag, without changing any default handler.
subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                "-f", APP], check=True)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
# "Always allow" choices persist in user defaults: start without any.
subprocess.run(["defaults", "delete", INFO["CFBundleIdentifier"], "CmuxNextBrowser.externalSchemes"], capture_output=True)
SCRATCH = tempfile.mkdtemp(prefix=f"external-schemes-{opts.tag}-")
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
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800", "CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS": "1"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, out {opts.out}", flush=True)
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), "app socket", 180)
    check("error" not in rpc("debug.browser.external_opens"), "the build records external opens")
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

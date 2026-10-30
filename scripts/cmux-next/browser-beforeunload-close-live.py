#!/usr/bin/env python3
"""Live check: a person's close of a Chromium tab runs the page's beforeunload first (Chrome parity).

The 2026-10-20 nightly closed such a tab at once, then showed Chromium's own app-modal "Leave
site?" alert with no tab behind it; its Stay button sent -cancelTerminate: to NSApp and the app
raised on the main thread and hung. A local page installs a beforeunload handler; a click on the
page (`debug.mouse` target page) gives it the user activation Chromium requires before it asks.
Scenarios, each through the app's own paths:

  1. Cmd-W (`debug.key`, a person's key): the tab stays and a cmux dialog
     (`browser.dialog.beforeunload`) asks in it. A second Cmd-W keeps the tab and the one question.
  2. Cancel (the dialog's button, `debug.dialog press`): the tab stays, its page still answers
     (`browser.page.eval`) and the app answers its socket (no hang).
  3. Cmd-W again, then Leave: the tab closes, no question is left.
  4. An automation close (`action.run closeTab`, origin script) of an armed page closes it with
     no question.

  scripts/cmux-next/browser-beforeunload-close-live.py [--app PATH] [--out DIR]

GUI host only, through `nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA` (uses
$NX_APP, $NX_APP_SOCKET, $NX_APP_STOP). Launches the app without activation and stops it at the
end. Writes window snapshots and verdict.json to --out. Exit 1 when a check fails.
"""
import argparse, http.server, json, os, plistlib, socket, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", default=os.environ.get("NX_APP"))
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="beforeunload-"))
opts = parser.parse_args()
if not opts.app:
    sys.exit("pass --app or run under nx-remote --app-from-fleet ($NX_APP)")
os.makedirs(opts.out, exist_ok=True)
with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(opts.app, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
TAG = os.environ.get("NX_APP_TAG") or os.path.basename(opts.app).removeprefix("cmux DEV ").removesuffix(".app")
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{TAG}.sock"
failures, checks = [], []

PAGE = b"""<!doctype html><html><head><title>bu-ready</title></head>
<body style="margin:0;height:100vh;font:24px -apple-system;display:grid;place-items:center">
<p id="state">click anywhere</p>
<script>
window.addEventListener('beforeunload', e => { e.preventDefault(); e.returnValue = ''; });
document.addEventListener('mousedown', () => { document.title = 'activated'; });
</script></body></html>"""


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    checks.append({"check": what, "ok": bool(ok)})
    if not ok:
        failures.append(what)
    return ok


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
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def wait(predicate, seconds, step=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # test harness: bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def js(expression):
    reply = rpc("browser.page.eval", {"script": expression}) or {}
    return reply.get("value") if isinstance(reply, dict) else None


def focus():
    """(resolved tab, every tab id of the first window)."""
    windows = (rpc("debug.focus") or {}).get("windows") or []
    if not windows:
        return None, set()
    tabs = {t.rsplit(":", 1)[0] for p in windows[0].get("topology") or [] for t in p.get("tabs") or []}
    return (windows[0].get("model") or {}).get("resolved_tab"), tabs


def has_tab(tab):
    return tab in focus()[1]


def questions():
    """The visible beforeunload dialogs."""
    return [d for d in (rpc("debug.dialog") or {}).get("dialogs") or []
            if d.get("identifier") == "browser.dialog.beforeunload" and d.get("visible")]


def snapshot(name):
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, name + ".png")})


def serve():
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(PAGE)))
            self.end_headers()
            self.wfile.write(PAGE)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/"


def open_armed_tab(url, label):
    """A Chromium tab on the page, activated by a click; its tab id."""
    rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True})
    if not check(wait(lambda: js("document.title") == "bu-ready", 90), f"{label}: the page loads in a Chromium tab"):
        return None
    tab = wait(lambda: focus()[0], 10)
    clicked = rpc("debug.mouse", {"target": "page"})
    check(wait(lambda: js("document.title") == "activated", 10), f"{label}: a click on the page activates it ({clicked})")
    return tab


app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_NO_ACTIVATE": "1",
    "ACPMUX_AGENT_LAUNCH": "deny", "NX_REMOTE": "1",
    "CMUX_NEXT_TEST_WINDOW_FRAME": "60,60,1100,760"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
try:
    check(wait(lambda: "error" not in (rpc("debug.focus") or {"error": 1}), 180), "app socket")
    if not wait(lambda: focus()[0], 15):
        rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})
    check(wait(lambda: focus()[0], 60), "a focused tab")
    url = serve()

    # 1. A person's Cmd-W asks in the tab; the tab stays. A second Cmd-W changes nothing.
    tab = open_armed_tab(url, "person")
    if tab:
        rpc("debug.key", {"key": "w", "modifiers": ["cmd"]})
        asked = wait(questions, 10)
        snapshot("1-asked")
        check(asked, "Cmd-W shows the beforeunload question")
        check(has_tab(tab), "the tab stays while the page asks")
        rpc("debug.key", {"key": "w", "modifiers": ["cmd"]})
        time.sleep(1.5)  # test harness: a wrong second close would land within this
        check(has_tab(tab) and len(questions()) == 1, "a second Cmd-W keeps the tab and one question")

        # 2. Cancel: the tab stays and works; the app answers.
        pressed = rpc("debug.dialog", {"press": "cancel"})
        check(wait(lambda: not questions(), 5), f"Cancel ends the question ({str(pressed)[:120]})")
        time.sleep(1.5)  # test harness: a close that ignored Cancel would land within this
        snapshot("2-stayed")
        check(has_tab(tab), "Cancel keeps the tab")
        check(js("1 + 1") == 2 and js("document.title") == "activated", "the kept page still answers")
        check("error" not in (rpc("debug.focus", timeout=5) or {"error": 1}), "the app answers its socket after Cancel")

        # 3. Cmd-W again, then Leave: the tab closes.
        rpc("debug.key", {"key": "w", "modifiers": ["cmd"]})
        check(wait(questions, 10), "Cmd-W asks again")
        rpc("debug.dialog", {"press": "ok"})
        check(wait(lambda: not has_tab(tab), 10), "Leave closes the tab")
        check(not questions(), "no question is left after Leave")
        snapshot("3-left")

    # 4. An automation close never asks.
    tab = open_armed_tab(url, "automation")
    if tab:
        rpc("action.run", {"action": "closeTab", "target": "tab:%s" % tab, "origin": "script"})
        check(wait(lambda: not has_tab(tab), 10), "an automation close closes the armed tab")
        check(not questions(), "an automation close shows no question")
    check("error" not in (rpc("debug.focus", timeout=5) or {"error": 1}), "the app answers its socket at the end")
finally:
    stop = os.environ.get("NX_APP_STOP")
    if stop:
        subprocess.run([stop], timeout=120)
    else:
        rpc("action.run", {"action": "quitEndSessions"})
    with open(os.path.join(opts.out, "verdict.json"), "w") as handle:
        json.dump({"checks": checks, "failures": failures}, handle, indent=1)
print("verdict:", "PASS" if not failures else "FAIL %s" % failures, flush=True)
sys.exit(1 if failures else 0)

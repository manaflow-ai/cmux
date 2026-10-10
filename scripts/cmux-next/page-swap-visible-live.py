#!/usr/bin/env python3
"""Live check: a page swapped into a visible tab is shown and started (cx-8nvn).

  scripts/cmux-next/page-swap-visible-live.py --tag <tag> [--out DIR]

GUI host only (cmux-lawrence-2 or the M1 Max through nx-remote), never a developer laptop.
`TabContentCache.swapPage` replaces a tab's page in place (an app page becomes a web page, a
remote view's confirm notice becomes its session). The tab's lifecycle does not change, so the
replacement must learn at once that it is on screen. Checks:
1. `cmux://remote-view?host=mock` opened by automation asks first; Connect (`debug.remote_view
   connect`, the button's closure) swaps in the session page, which must be visible and decode
   the test desktop's frames.
2. A visible web tab that navigates to `cmux://bookmarks` and back to a web page loads both
   pages (`browser.page.state` title), so the other swap paths still work.
Ends with quitEndSessions and the tag teardown.
"""
import argparse, glob, http.server, json, os, plistlib, signal, socket, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--min-frames", type=int, default=10)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="page-swap-live-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = next(iter(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
MOCK = "cmux://remote-view?host=mock&target=display:1&mode=view"


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = "swap two" if self.path.startswith("/two") else "swap one"
        body = f"<!doctype html><html><head><title>{name}</title></head><body>{name}</body></html>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_address[1]}"


def rpc(method, params=None):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(60)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
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


def tabs():
    reply = rpc("debug.remote_view", {"action": "state"})
    return reply.get("tabs") or [] if isinstance(reply, dict) else []


def tab_where(test):
    return next((t for t in tabs() if test(t)), None)


def title(tab, want):
    state = rpc("browser.page.state", {"tab": tab})
    return state if isinstance(state, dict) and state.get("title") == want else None


report = {"steps": {}}
failures = []


def step(name, ok, evidence):
    report["steps"][name] = {"ok": bool(ok), "evidence": evidence}
    if not ok:
        failures.append(name)
    print(("PASS " if ok else "FAIL ") + name, json.dumps(evidence)[:800], flush=True)


if os.path.exists(SOCKET):
    if "error" not in rpc("debug.focus"):
        sys.exit(f"an app with tag {opts.tag} is running; use another tag")
    os.unlink(SOCKET)
config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config,
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,820"}
teardown = TagTeardown(APP)
teardown.install()
log = open(os.path.join(opts.out, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
report["pid"] = app.pid
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 120):
        sys.exit("app did not come up")
    # 1. Remote view: Connect swaps the confirm notice for the session page.
    for index in range(1, 10):
        rpc("action.run", {"action": "selectWorkspaceByNumber", "args": {"index": index}})
        report["open"] = wait(lambda: (lambda r: r if "error" not in r else None)(
            rpc("debug.remote_view", {"action": "open", "url": MOCK})), 3)
        if report["open"]:
            break
    asked = wait(lambda: tab_where(lambda t: t.get("confirm")), 30)
    report["connect"] = rpc("debug.remote_view", {"action": "connect", "tab": (asked or {}).get("tab", "")})

    def started():
        row = tab_where(lambda t: (t.get("session") or {}).get("visible"))
        return row if row and ((row.get("session") or {}).get("decoded") or 0) >= opts.min_frames else None

    shown = wait(started, 30)
    step("Connect swaps in a session page that is visible and decodes frames", asked and shown,
         {"asked": asked, "connect": report["connect"], "tabs": tabs()})
    # 2. A visible web tab: web -> app page (bookmarks) -> web page, each loads.
    opened = rpc("browser.open_split", {"url": BASE + "/one", "focus": True})
    tab = opened.get("tab_id") if isinstance(opened, dict) else None
    one = tab and wait(lambda: title(tab, "swap one"), 30)
    if tab:
        rpc("browser.page.navigate", {"tab": tab, "url": "cmux://bookmarks"})
        wait(lambda: (rpc("browser.page.state", {"tab": tab}) or {}).get("url", "").startswith("cmux://bookmarks"), 15)
        rpc("browser.page.navigate", {"tab": tab, "url": BASE + "/two"})
    two = tab and wait(lambda: title(tab, "swap two"), 30)
    step("a visible web tab swaps to an app page and back and both web pages load", one and two,
         {"opened": opened, "one": one, "two": two})
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "window.png")})
finally:
    report["final_state"] = tabs()
    print("quit", rpc("action.run", {"id": "quitEndSessions"}), flush=True)
    try:
        app.wait(30)
    except subprocess.TimeoutExpired:
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    teardown.end()
    server.shutdown()
    report["failures"] = failures
    with open(os.path.join(opts.out, "page-swap-live.json"), "w") as f:
        json.dump(report, f, indent=1)
print(json.dumps({"failures": failures, "out": opts.out}))
sys.exit(1 if failures else 0)

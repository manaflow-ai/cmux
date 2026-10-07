#!/usr/bin/env python3
"""Live check: Open Remote Browser Tab (Local Host) against the real remote browser host.

  scripts/cmux-next/remote-browser-local-live.py --tag <tag> --host-app <cmux-remote-browser-host.app> [--out DIR]

Fleet GUI host only (cmux-lawrence-2), never a developer laptop. Launches the tagged app
(no activation, automation socket, CMUX_NEXT_RB_HOST=--host-app), serves a local test page,
and drives the shared open path through `debug.remote_browser` `open_local`. Checks, each with
an in-process window snapshot: the page renders and its title arrives (rb.page); a typed URL
loads (the omnibar path) and Back returns (rb.history); hover reports a pointer cursor
(rb.cursor); the wheel scrolls the page; right-click opens a native menu; a <select> near the
bottom edge opens a native menu and the chosen item reaches the page; a date input opens a
popup surface; a target=_blank link opens a second remote tab on its own host (rb.open_tab);
closing a tab stops its host. Ends with quitEndSessions and the tag teardown.
"""
import argparse, glob, http.server, json, os, plistlib, signal, socket, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--host-app", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="rb-local-live-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = next(iter(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"

# Page 1: a pointer link, a long body (wheel), a select near the bottom edge, a date input,
# and a target=_blank link. The title reports what happened, so rb.page carries the result.
PAGE1 = """<!doctype html><html><head><title>rb one</title><style>
body{margin:0;font:16px sans-serif;background:#f4f4f4;height:3000px}
a{display:block;margin:12px;font-size:20px} #sel{position:fixed;left:20px;bottom:12px}
#date{position:fixed;left:260px;top:120px}</style></head><body>
<a id="hover" href="/two" style="cursor:pointer">hover link</a>
<a id="blank" href="/two?blank" target="_blank">new tab link</a>
<input id="date" type="date">
<select id="sel" onchange="document.title='rb selected '+this.value">
<option value="a">Alpha</option><option value="b">Bravo</option><option value="c">Charlie</option></select>
<script>addEventListener('scroll',()=>{document.title='rb scrolled '+Math.round(scrollY)})</script>
</body></html>"""
PAGE2 = "<!doctype html><html><head><title>rb two</title></head><body style='background:#dfe'>page two</body></html>"


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = (PAGE2 if self.path.startswith("/two") else PAGE1).encode()
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


def rb(action, **params):
    return rpc("debug.remote_browser", {"action": action, **params})


def sessions():
    state = rb("state")
    return state.get("sessions") or [] if isinstance(state, dict) else []


def session_where(test):
    return next((s for s in sessions() if test(s)), None)


def title_is(prefix):
    return lambda: session_where(lambda s: (s.get("title") or "").startswith(prefix))


report = {"steps": {}}
failures = []
shots = []


def step(name, ok, evidence):
    report["steps"][name] = {"ok": bool(ok), "evidence": evidence}
    if not ok:
        failures.append(name)
    print(("PASS " if ok else "FAIL ") + name, json.dumps(evidence)[:400], flush=True)


def shot(name):
    path = os.path.join(opts.out, f"{len(shots):02d}-{name}.png")
    rpc("debug.window_snapshot", {"kind": "main", "path": path})
    shots.append(path)


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config,
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,820", "CMUX_NEXT_RB_HOST": os.path.abspath(opts.host_app)}
teardown = TagTeardown(APP)
teardown.install()
log = open(os.path.join(opts.out, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
report["pid"] = app.pid
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 120):
        sys.exit("app did not come up")
    # The palette's registry path (`action.run`), the same one the palette runs.
    # A fresh app shows Home; a Chromium tab gives the window a focused workspace pane.
    report["seed"] = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": BASE + "/two"}, "focus": True})
    wait(lambda: "error" not in rpc("browser.page.state"), 45)
    # It takes no arguments: the tab starts on the default page, then the typed-URL path loads the test page.
    report["open"] = rpc("action.run", {"action": "remote.openLocalBrowserTab", "focus": True})
    if "error" in report["open"]:
        # A no-activation test app has no focused pane; the debug verb runs the same openLocal
        # in the first window's pane.
        report["open_debug"] = rb("open_local")
    opened = wait(lambda: session_where(lambda s: s.get("title")), 120)
    shot("start-page")
    if opened:
        rb("navigate", tab=opened["tab"], url=BASE + "/")
    first = wait(title_is("rb one"), 60)
    state = rb("state")
    hosts = state.get("local_hosts") or []
    shot("page")
    step("palette path opens a local host tab and the page renders (rb.page title)",
         first and len(hosts) == 1, {"open": report["open"], "session": first, "hosts": hosts})
    tab1 = first and first["tab"]

    # Hover over the pointer link: rb.cursor.
    rb("move", tab=tab1, x=60, y=24)
    hover = wait(lambda: session_where(lambda s: s["tab"] == tab1 and s.get("cursor") == "pointer"), 15)
    step("hover reports the page's pointer cursor (rb.cursor)", hover, {"session": hover or session_where(lambda s: s["tab"] == tab1)})
    rb("move", tab=tab1, x=600, y=500)

    # Wheel: the page scrolls and reports scrollY in its title.
    rb("scroll", tab=tab1, x=600, y=400, dy=-400)
    scrolled = wait(title_is("rb scrolled"), 15)
    shot("scrolled")
    step("the wheel scrolls the page", scrolled, {"session": scrolled})

    # Right-click: a native menu with the page's items.
    rb("click", tab=tab1, x=600, y=300, button="right")
    menu = wait(lambda: session_where(lambda s: s["tab"] == tab1 and s.get("menu")), 15)
    shot("context-menu")
    rb("menu_cancel", tab=tab1)
    step("right-click opens a native menu (rb.menu)", menu, {"menu": menu and menu.get("menu")})

    # Select near the bottom edge: a native menu; choosing Charlie reaches the page.
    height = int(((first or {}).get("frame") or "0x600").split("x")[1])
    rb("click", tab=tab1, x=60, y=height - 22, button="left")
    select = wait(lambda: session_where(lambda s: s["tab"] == tab1 and s.get("menu")), 15)
    shot("select")
    chosen = rb("menu_choose", tab=tab1, index=2) if select else None
    picked = wait(title_is("rb selected c"), 15)
    step("a <select> near the bottom edge opens a native menu and the choice reaches the page",
         select and picked, {"menu": select and select.get("menu"), "chosen": chosen, "session": picked})

    # Date input: a popup surface on its own stream.
    rb("click", tab=tab1, x=300, y=130, button="left")
    popup = wait(lambda: session_where(lambda s: s["tab"] == tab1 and s.get("surfaces")), 15)
    shot("date-picker")
    step("a date input opens a popup surface (rb.surface.show)", popup, {"surfaces": popup and popup.get("surfaces")})
    rb("click", tab=tab1, x=900, y=600, button="left")

    # Typed URL (the omnibar's BrowserTab.load) and Back.
    rb("navigate", tab=tab1, url=BASE + "/two")
    two = wait(title_is("rb two"), 30)
    shot("navigated")
    back = rb("history", tab=tab1, op="back")
    returned = wait(title_is("rb "), 30) and wait(lambda: session_where(
        lambda s: s["tab"] == tab1 and (s.get("title") or "").startswith("rb") and s.get("title") != "rb two"), 30)
    step("a typed URL loads (rb.navigate) and Back returns (rb.history)", two and returned,
         {"two": two, "back": back, "after": returned})

    # target=_blank: a second remote tab on its own host.
    rb("click", tab=tab1, x=60, y=60, button="left")
    second = wait(lambda: len(sessions()) >= 2 and len(rb("state").get("local_hosts") or []) >= 2, 60)
    state = rb("state")
    shot("new-tab")
    step("a target=_blank link opens a remote tab on its own host (rb.open_tab)", second,
         {"sessions": state.get("sessions"), "hosts": state.get("local_hosts")})

    # Closing the focused (new) tab stops its host.
    before = state.get("local_hosts") or []
    rpc("action.run", {"action": "closeTab"})
    after = wait(lambda: (lambda h: h if len(h) < len(before) else None)(rb("state").get("local_hosts") or []), 30)
    gone = [h for h in before if h not in (after or [])]
    exited = gone and wait(lambda: subprocess.run(["/bin/kill", "-0", str(gone[0]["pid"])],
                                                  capture_output=True).returncode != 0, 30)
    step("closing a tab stops its host (stdin lifeline)", after is not None and exited,
         {"before": before, "after": after, "stopped": gone})
finally:
    report["final_state"] = rb("state")
    host_pids = [h["pid"] for h in (report["final_state"].get("local_hosts") or [])] \
        if isinstance(report["final_state"], dict) else []
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
    # The app's exit closes every lifeline, so no host outlives it.
    alive = [pid for pid in host_pids if not wait(lambda pid=pid: subprocess.run(
        ["/bin/kill", "-0", str(pid)], capture_output=True).returncode != 0, 30)]
    step("quitting the app stops every remaining host", not alive, {"hosts": host_pids, "alive": alive})
report["failures"] = failures
report["screenshots"] = shots
with open(os.path.join(opts.out, "rb-local-live.json"), "w") as f:
    json.dump(report, f, indent=1)
print("PASS" if not failures else "FAIL " + ", ".join(failures), f"(evidence {opts.out}/rb-local-live.json)")
sys.exit(0 if not failures else 1)

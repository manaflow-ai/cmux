#!/usr/bin/env python3
"""Live check: a hibernated Chromium tab comes back exactly as it was (perf100 browser lane).

  scripts/cmux-next/hibernation-restore-live.py --app PATH [--out DIR]

Hibernation closes a hidden page's engine page to free its renderer and recreates it from the saved
history when the tab shows again (plans/cmux-next/tab-lifecycle.md). A person must not see a
difference. A local server serves A, which goes on to B by itself the first time, and B, a tall page
that the first time scrolls down and writes sessionStorage. Then the script types into B's input and
textarea (browser.page.fill), shows another tab, and runs the person's Hibernate Tab action on B.
When B shows again, each item is checked and printed as a row of the restore table:

  url        B, not A or a new page;
  scroll     scrollY where it was;
  back       Back goes to A (history kept);
  forward    after Back, Forward comes back to B;
  input      the unsent text in <input> and <textarea> (Chromium restores form state from history);
  session    sessionStorage of the tab;
  renderer   the page really was recreated (a new document: its load counter went up).

Every page reports its own state to the server (nothing reads a page through the socket). The person's
Hibernate Tab skips the busy probe, so the typed text is the strictest case: the automatic path keeps a
page with edited fields awake instead (`edited_form`). Quits the app through the socket, then ends the
tag's daemons (TagTeardown). Exits 1 when a check fails.
"""
import argparse, http.server, json, os, plistlib, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True, help="tagged .app")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="hibernation-restore-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = os.path.realpath(opts.app)
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
TAG = INFO["CFBundleIdentifier"].rsplit(".", 1)[-1]
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
SCRATCH = tempfile.mkdtemp(prefix="hibernation-restore-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
EMPTY_GHOSTTY = os.path.join(SCRATCH, "ghostty-config")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
RUN = os.urandom(4).hex()
SCROLL = 1500
TYPED = f"typed-{RUN}"
failures = []
rows = []
report = {}  # the latest state B or A reported
loads = {"a": 0, "b": 0}
lock = threading.Lock()


def page(name):
    with lock:
        loads[name] += 1
        first = loads[name] == 1
    tell = ("const tell=()=>fetch('/report',{method:'POST',body:JSON.stringify({path:location.pathname,"
            "scrollY:Math.round(scrollY),f:(document.getElementById('f')||{}).value,t:(document.getElementById('t')||{}).value,"
            "session:sessionStorage.getItem('k'),load:%d})});addEventListener('scroll',tell);addEventListener('input',tell);"
            "addEventListener('pageshow',()=>{tell();setTimeout(tell,700)});" % loads[name])
    if name == "a":
        go = f"setTimeout(()=>location.href='/b-{RUN}',300);" if first else ""
        return f"<title>A</title><body><h1>A</h1><script>{tell}{go}</script>"
    act = (f"sessionStorage.setItem('k','{RUN}');addEventListener('load',()=>setTimeout(()=>scrollTo(0,{SCROLL}),200));"
           if first else "")
    return ("<title>B</title><body style='height:6000px'><h1>B</h1><input id=f><textarea id=t></textarea>"
            f"<script>{tell}{act}</script>")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        name = {f"/a-{RUN}": "a", f"/b-{RUN}": "b"}.get(self.path)
        if name is None:
            body = b"<title>other</title><body>other tab"
        else:
            body = page(name).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802
        data = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        with lock:
            report.clear()
            report.update(data)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
ORIGIN = f"http://127.0.0.1:{server.server_port}"


def check(ok, what, row=None):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if row:
        rows.append({"item": row, "kept": bool(ok), "detail": what})
    if not ok:
        failures.append(what)


def rpc(method, params=None, timeout=30):
    try:
        r = subprocess.run([CLI, "--app-socket", SOCKET, "--json", "app", "call", method, json.dumps(params or {})],
                           capture_output=True, text=True, timeout=timeout, env=CLI_ENV)
    except subprocess.TimeoutExpired:
        return {"error": f"{method} timed out"}
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def wait_for(predicate, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    return None


def at(path, **want):
    with lock:
        state = dict(report)
    if state.get("path") != path:
        return None
    for key, value in want.items():
        if key == "scrollY":
            if abs((state.get("scrollY") or 0) - value) > 50:
                return None
        elif state.get(key) != value:
            return None
    return state


def hibernation():
    return rpc("debug.surfaces").get("hibernation") or {}


B = f"/b-{RUN}"
A = f"/a-{RUN}"
with open(CONFIG, "w") as f:
    f.write("{}\n")
with open(EMPTY_GHOSTTY, "w") as f:
    f.write("")
teardown = TagTeardown(APP)
teardown.install()
app = None
try:
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    app = subprocess.Popen([BINARY], env={**BASE_ENV, "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
                                          "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": EMPTY_GHOSTTY},
                           stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT)
    print(f"app pid {app.pid}, origin {ORIGIN}, out {opts.out}", flush=True)
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 120)
    rpc("action.run", {"action": "workspace.selectFirst"})
    rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": ORIGIN + A}, "focus": True}, timeout=60)
    tab = (opened.get("created") or [None])[0]
    check(bool(tab), f"a Chromium tab opens ({opened})")
    check(wait_for(lambda: at(B, scrollY=SCROLL, session=RUN), 30) is not None, f"A goes on to B, which scrolls down ({report})")
    for selector in ("#f", "#t"):
        reply = rpc("browser.page.fill", {"tab": tab, "selector": selector, "text": TYPED})
        check("error" not in reply, f"fill {selector} ({reply})")
    check(wait_for(lambda: at(B, f=TYPED, t=TYPED), 10) is not None, f"B reports the typed text ({report})")
    before_load = report.get("load")
    rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": ORIGIN + "/other"}, "focus": True}, timeout=60)
    time.sleep(1)  # the pane shows the other tab
    reply = rpc("action.run", {"action": "hibernateTab", "target": f"tab:{tab}"})
    check("error" not in reply, f"Hibernate Tab runs ({reply})")
    slept = wait_for(lambda: tab in (hibernation().get("hibernated") or []), 30)
    check(bool(slept), f"B hibernates ({hibernation()})")
    with lock:
        report.clear()
    t0 = time.monotonic()
    rpc("action.run", {"action": "tab.focus", "target": f"tab:{tab}", "focus": True})
    back_at_b = wait_for(lambda: at(B), 30)
    restore_ms = round((time.monotonic() - t0) * 1000)
    check(back_at_b is not None, f"B shows again after the wake ({report}, {restore_ms} ms)", "url")
    check((report.get("load") or 0) > (before_load or 0), f"B is a new document ({before_load} -> {report.get('load')})", "renderer")
    wait_for(lambda: at(B, scrollY=SCROLL), 10)
    check(at(B, scrollY=SCROLL) is not None, f"scrollY comes back to {SCROLL} ({report.get('scrollY')})", "scroll")
    check(report.get("f") == TYPED, f"<input> keeps the unsent text ({report.get('f')!r})", "input")
    check(report.get("t") == TYPED, f"<textarea> keeps the unsent text ({report.get('t')!r})", "textarea")
    check(report.get("session") == RUN, f"sessionStorage stays ({report.get('session')!r})", "session")
    reply = rpc("debug.toast", {"perform": "browserBack"})
    check(wait_for(lambda: at(A), 15) is not None, f"Back goes to A ({reply}, {report})", "back")
    reply = rpc("debug.toast", {"perform": "browserForward"})
    check(wait_for(lambda: at(B), 15) is not None, f"Forward comes back to B ({reply}, {report})", "forward")
    rows.append({"item": "restore_ms", "kept": True, "detail": restore_ms})
finally:
    with open(os.path.join(opts.out, "hibernation-restore.json"), "w") as f:
        json.dump({"rows": rows, "failures": failures}, f, indent=1)
    if app and app.poll() is None:
        rpc("action.run", {"action": "quitEndSessions"})
        try:
            app.wait(timeout=30)
        except subprocess.TimeoutExpired:
            app.kill()  # the PID launched above, never a pattern
            app.wait()
    teardown.end()
    server.shutdown()
    server.server_close()

print("restore table:", json.dumps(rows), flush=True)
print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)

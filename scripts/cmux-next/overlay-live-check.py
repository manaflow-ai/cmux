#!/usr/bin/env python3
"""Live check: the overlay host panel stays above Chromium page windows, without reorder churn.

  scripts/cmux-next/overlay-live-check.py --tag <tag> [--idle 10] [--out DIR]

Launches the tagged app (no activation, automation socket), opens a Chromium
tab on a local page, and reads `debug.layers` right after the load and again
after --idle seconds: the overlay must be above every page window, the layers
consistent, the reorder count flat while idle, and no child-window violation
recorded. Also saves `debug.window_list` and a window snapshot. Fleet GUI host only.

--in-tree on checks in-tree pages instead (plans/cmux-next/in-tree-pages.md): no overlay panel and no page child
window at all (placement inWindow), the page listed in page_views with widget_drawing 0, reorders and divider catcher
updates flat while idle, no child-window violation. --in-tree off runs today's check with the switch off.
"""
import argparse, glob, http.server, json, os, plistlib, signal, socket, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--idle", type=float, default=10.0)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="overlay-live-"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import in_tree_mode  # noqa: E402
in_tree_mode.add_argument(parser)
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = next(iter(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
TITLE = "overlay live page"


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"<html><head><title>{TITLE}</title></head><body style='background:#c33'>red page</body></html>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()


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


def window_layers():
    layers = rpc("debug.layers")
    windows = layers.get("windows") if isinstance(layers, dict) else None
    return (windows or [{}])[0], layers


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720"}
in_tree_mode.apply(opts.in_tree, env)
log = open(os.path.join(opts.out, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
report = {"pid": app.pid}
failures = []
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 90):
        sys.exit("app did not come up")
    page = f"http://127.0.0.1:{server.server_address[1]}/"
    report["open"] = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": page}, "focus": True})
    report["state"] = wait(lambda: (lambda s: s if s.get("title") == TITLE else None)(rpc("browser.page.state")), 45)
    time.sleep(2)
    status = in_tree_mode.read(rpc)
    report.update(in_tree_mode.record(opts.in_tree, status))
    problem = in_tree_mode.mismatch(opts.in_tree, status)
    if problem:
        failures.append(problem)
    in_tree = status == "on"
    first, _ = window_layers()
    time.sleep(opts.idle)
    second, full = window_layers()
    fields = ("placement", "overlay_above_content", "consistent", "reorders", "child_windows", "child_window_violations",
              "in_tree", "page_views", "widget_drawing", "divider_catcher_updates")
    report["layers_loaded"] = {k: first.get(k) for k in fields}
    report["layers_idle"] = {k: second.get(k) for k in fields}
    report["window_list"] = rpc("debug.window_list")
    report["snapshot"] = rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "window.png")})
    with open(os.path.join(opts.out, "debug-layers.json"), "w") as f:
        json.dump(full, f, indent=1)
    if not report["state"]:
        failures.append("the page title did not arrive")
    if in_tree:
        if second.get("placement") != "inWindow" or second.get("overlay_panel") is not None:
            failures.append(f"in-tree pages: an overlay panel is attached (placement {second.get('placement')})")
        if any(c.get("role") == "content" and c.get("visible") for c in second.get("child_windows") or []):
            failures.append("in-tree pages: a page child window is on screen")
        if not second.get("page_views"):
            failures.append("in-tree pages: no page view in the window's tree")
        if second.get("widget_drawing") != 0:
            failures.append(f"in-tree pages: {second.get('widget_drawing')} headless widget(s) still draw")
        if (second.get("divider_catcher_updates") or 0) != (first.get("divider_catcher_updates") or 0):
            failures.append("in-tree pages: divider catcher updates grew while idle")
    elif second.get("placement") != "overlayWindow" or second.get("overlay_above_content") is not True:
        failures.append("the overlay is not above the page window")
    if second.get("consistent") is not True:
        failures.append("debug.layers is not consistent")
    if (second.get("reorders") or 0) != (first.get("reorders") or 0):
        failures.append(f"reorders grew while idle: {first.get('reorders')} -> {second.get('reorders')}")
    if second.get("child_window_violations"):
        failures.append(f"child-window violations: {second.get('child_window_violations')}")
finally:
    if app.poll() is None:
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    server.shutdown()
report["failures"] = failures
with open(os.path.join(opts.out, "overlay-live.json"), "w") as f:
    json.dump(report, f, indent=1)
print(json.dumps({"loaded": report.get("layers_loaded"), "idle": report.get("layers_idle")})[:1500])
for failure in failures:
    print("FAIL", failure)
print("PASS" if not failures else "FAIL", f"(evidence {opts.out}/overlay-live.json)")
sys.exit(0 if not failures else 1)

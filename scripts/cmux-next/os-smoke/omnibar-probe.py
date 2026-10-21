#!/usr/bin/env python3
"""Omnibar text-selection probe for one cmux-next DEV build, INSIDE a disposable
Tart VM (stdlib only). The guest half of `run.sh` when OS_SMOKE_PROBE=omnibar-probe.py:
the same script on macOS 15 and 26 guests shows whether the omnibar draws its
selection highlight (report 2026-10-20: "highlighting stuff in omnibar in
sequoia is broken").

It launches the app like guest-probe.py, but lets it activate (a selection draws
in its emphasized color only in the key window), opens a WebKit tab on a local
page, then:

1. rest: a screen capture and `debug.omnibar` before any click;
2. focus: one press on the omnibar text (Chrome's focusing click selects all);
3. drag: a press-drag over part of the text.

After each step it writes `debug.omnibar` (model and field-editor selection,
`editor` text system, key window, resolved selection color, `field_frame`) and a
screencapture of the guest display (real pixels, what the user sees) plus a
`debug.window_snapshot`. Writes OUT/omnibar.json and prints OMNIBAR lines.
Exit: 0 ran, 1 the app died or never showed a window, 3 release build (no debug.*).

Usage: omnibar-probe.py APP_PATH OUT_DIR
"""
import http.server, json, os, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
# The launch helpers (socket path, rpc, wait) of guest-probe.py, without its steps.
_src = open(os.path.join(HERE, "guest-probe.py")).read()
exec(compile(_src[:_src.index("# 1. OS gate")], "guest-probe.py", "exec"))

report = {"guest_os": guest_os, "guest_build": result["guest_build"], "app": os.path.basename(APP), "steps": {}}


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>%s</title><body style='font:40px sans-serif'>omnibar selection probe</body>" % TITLE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
PAGE = "http://127.0.0.1:%d/omnibar/selection-probe?q=highlight" % server.server_address[1]


def capture(name, omnibar):
    """Real pixels of the field (screencapture -R, padded), printed base64 into the
    step log (an os-smoke step returns no artifact): OMNIBAR-PNG <name> <base64>."""
    path = os.path.join(OUT, name + ".png")
    rect = ((omnibar or {}).get("editor") or {}).get("screen_rect")
    if not rect:
        rect = "40,40,1200,140"
    x, y, w, h = (float(v) for v in rect.split(","))
    region = "%d,%d,%d,%d" % (x - 12, y - 8, w + 24, h + 16)
    subprocess.run(["/usr/sbin/screencapture", "-x", "-t", "png", "-R", region, path], capture_output=True, timeout=60)
    subprocess.run(["/usr/sbin/screencapture", "-x", "-t", "png", os.path.join(OUT, name + "-full.png")], capture_output=True, timeout=60)
    if os.path.exists(path):
        import base64
        print("OMNIBAR-PNG %s %s" % (name, base64.b64encode(open(path, "rb").read()).decode()), flush=True)
    return os.path.exists(path)


def record(name, omnibar):
    report["steps"][name] = omnibar
    keep = {k: (omnibar or {}).get(k) for k in ("phase", "has_focus", "field_text", "field_selection", "field_editor_active", "editor", "field_frame", "error")}
    print("OMNIBAR %-6s %s" % (name, json.dumps(keep)), flush=True)


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
scratch = tempfile.mkdtemp(prefix="os-smoke-")
open(os.path.join(scratch, "cmux.json"), "w").write("{}\n")
open(os.path.join(scratch, "ghostty"), "w").write("")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"), "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(scratch, "ghostty"),
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
log = open(os.path.join(OUT, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
alive = lambda: app.poll() is None
code = 0
try:
    if not wait(windows_now, LAUNCH_DEADLINE, alive) or not alive():
        print("OMNIBAR FAIL no window", flush=True)
        code = 1
    elif not debug_router():
        print("OMNIBAR skip release build", flush=True)
        code = 3
    else:
        opened = rpc("action.run", {"action": "openBrowser", "args": {"url": PAGE, "engine": "webkit"}, "focus": True})
        state = wait(lambda: (lambda s: s if isinstance(s, dict) and s.get("title") == TITLE else None)(rpc("browser.page.state")), TAB_DEADLINE, alive)
        report["open"] = {"run": opened, "state": state}
        wait(lambda: False, 2, alive)
        rest = rpc("debug.omnibar")
        record("rest", rest)
        # The focusing press: Chrome selects the whole URL.
        rpc("debug.omnibar_mouse", {"character": 5})
        wait(lambda: False, 1.5, alive)
        focus = rpc("debug.omnibar")
        record("focus", focus)
        capture("focus", focus)
        # A press-drag over part of the text (debug.omnibar_mouse reads the editor's
        # TextKit 1 layout for the points, so this step runs last).
        rpc("debug.omnibar_mouse", {"character": 10, "drag_to": 22})
        wait(lambda: False, 1.5, alive)
        drag = rpc("debug.omnibar")
        record("drag", drag)
        capture("drag", drag)
        report["windows"] = windows_now()
finally:
    if alive():
        app.terminate()
        try:
            app.wait(15)
        except subprocess.TimeoutExpired:
            app.kill()
    server.shutdown()
    with open(os.path.join(OUT, "omnibar.json"), "w") as f:
        json.dump(report, f, indent=1)
sys.exit(code)

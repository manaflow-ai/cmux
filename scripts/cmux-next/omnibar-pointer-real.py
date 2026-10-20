#!/usr/bin/env python3
"""Real-pointer check: the browser omnibar's cursor and the navigation buttons' tooltips (`OmnibarPointer`).

  nx-remote --needs input --app-from-fleet cmux --tag TAG --ref SHA -- \\
    'python3 scripts/cmux-next/omnibar-pointer-real.py --tag TAG --app "$NX_APP"'

Input host only: it moves the real pointer with mouse-moved events along a path, as a mouse sends
them, and drags with real press, drag and release events (`pointer-probe.swift`, built here with
swiftc; the input job's SSH path has the Accessibility grant that posting needs), clicks through
cua-driver (desktop scope), and reads the cursor on screen. `--moves warp` moves with cua-driver's
warp instead, which sends the app no move event (it does not model a mouse). The app is launched
active with an empty config. For a Chromium tab, a WebKit tab (a local test page) and a New Tab page:

  1. a real click on the page gives the page the keyboard (a Chromium page window then has the key:
     printed from `debug.window_list`);
  2. the real pointer over the omnibar's text, above it and past its end shows the I-beam; over the
     page-info chip and Reload the arrow; a still pointer over the text keeps the I-beam while the
     page reloads and while the page sets its own cursor;
  3. Back, Forward and Reload show no tooltip (no visible TooltipPanel); the More button shows one
     (printed, the control);
  4. a real click on the omnibar focuses it, and the I-beam stays over the text area;
  5. the app answers after every step (it does not crash on pointer moves);
  6. a page link under the real pointer shows its hover, and the hover clears when the pointer moves
     up into the toolbar (the page gets its exit, the toolbar its I-beam);
  7. a real drag that starts in the page text and ends over the omnibar keeps selecting (the
     selection reaches the text above the press).

The page is a local test page (link at the top, two lines of text), served here.

Exits 1 when a check fails.
"""
import argparse, functools, glob, http.server, json, os, plistlib, socket, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402
from bench_idle import usage  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--cua", default=os.path.expanduser("~/.local/bin/cua-driver"))
parser.add_argument("--moves", choices=("real", "warp"), default="real",
                    help="real: posted mouse-moved events along a path (pointer-probe path); warp: cua move_cursor (no move events)")
parser.add_argument("--quick", action="store_true", help="only the at-rest cursor checks (and the still pointer over a reloading page)")
parser.add_argument("--idle-seconds", type=float, default=0,
                    help="Chromium tab at rest: the app's CPU and wakeups over this many seconds with the pointer still on the text")
parser.add_argument("--env", action="append", default=[], help="K=V passed to the app (repeatable)")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="omnibar-real-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def call(method, params=None, timeout=30):
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
        return json.loads(buf)
    except (OSError, ValueError) as error:
        return {"ok": False, "error": {"code": "socket", "message": str(error)}}


def rpc(method, params=None):
    reply = call(method, params)
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's or the window server's state
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    return None


PROBE = os.path.join(tempfile.mkdtemp(prefix="pointer-probe-"), "pointer-probe")
subprocess.run(["xcrun", "swiftc", "-O", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pointer-probe.swift"),
                "-o", PROBE], check=True)


def probe(*args):
    return subprocess.run([PROBE, *map(str, args)], capture_output=True, text=True, timeout=20).stdout.strip()


SCREEN_H = float(probe("screen"))


def cua(tool, params):
    try:
        out = subprocess.run([opts.cua, "call", tool, json.dumps(params)], capture_output=True, text=True, timeout=60).stdout
        return json.loads(out)
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        return {"error": str(error)}


SCALE = float(cua("get_screen_size", {}).get("scale_factor") or 2.0)


def alive():
    return "error" not in (rpc("debug.focus") or {"error": 1})


def main_window():
    for entry in (rpc("debug.window_list") or {}).get("windows") or []:
        if entry.get("kind") == "main" and entry.get("visible"):
            return entry
    return None


def to_screen(point):
    """A window point from the top left (debug.omnibar's frames) to a screen point from the top left."""
    f = (main_window() or {}).get("frame") or {}
    return (f.get("x", 0) + point[0], SCREEN_H - (f.get("y", 0) + f.get("height", 0)) + point[1])


def app_active():
    return bool((rpc("debug.focus") or {}).get("app_active"))


def activate():
    if not app_active():
        cua("bring_to_front", {"pid": app.pid})
        quiet_wait(app_active, 3)


def real_move(x, y):
    """Moves the pointer to screen point (x, y) (top left). `real`: mouse-moved events along a path,
    as a mouse sends them; `warp`: cua-driver warps the pointer (the app gets no move event)."""
    if opts.moves == "warp":
        cua("move_cursor", {"x": round(x * SCALE), "y": round(y * SCALE), "scope": "desktop"})
        return
    try:
        x0, y0 = map(float, probe("where").split())
    except ValueError:
        x0, y0 = x, y
    probe("path", x0, y0, x, y, 8)


def move(point):
    x, y = to_screen(point)
    real_move(x - 3, y)  # two moves, so the window server sends a move event at the point
    real_move(x, y)
    at = cua("get_cursor_position", {})
    pos = (at.get("x"), at.get("y")) if isinstance(at, dict) else at
    probe_report = (rpc("debug.omnibar", {"window": WINDOW, "probe_x": point[0], "probe_y": point[1]}) or {}).get("pointer") or {}
    report = (omnibar().get("pointer") or {})
    print(f"   t={time.monotonic():.3f} region {probe_report.get('probe_region')}; move to window {tuple(round(v) for v in point)} = screen ({x:.0f}, {y:.0f}); pointer at {pos}; "
          f"row set {report.get('tracked_cursor')}, bar hover {report.get('bar_hovering')}, buttons {report.get('hovered_buttons')}",
          flush=True)


def click(point):
    activate()
    x, y = to_screen(point)
    real_move(x, y)
    reply = cua("click", {"x": round(x * SCALE), "y": round(y * SCALE), "scope": "desktop"})
    print(f"   click at screen ({x:.0f}, {y:.0f}):", (reply.get("summary") if isinstance(reply, dict) else None) or str(reply)[:160],
          flush=True)


def cursor_at(point, want):
    move(point)
    got = quiet_wait(lambda: probe("cursor") == want and want, 2) or probe("cursor")
    x, y = to_screen(point)
    owner = "" if got == want else f"; window at the point: {probe('owner', x, y)}"
    print(f"   t={time.monotonic():.3f} screen cursor {got}{owner}", flush=True)
    return got


def windows_report():
    rows = (rpc("debug.window_list") or {}).get("windows") or []
    return [(w.get("class"), w.get("kind"), w.get("key")) for w in rows if w.get("visible")]


def tooltip_shown():
    rows = (rpc("debug.window_list") or {}).get("windows") or []
    return any(w.get("visible") and "Tooltip" in (w.get("class") or "") for w in rows)


def omnibar():
    reply = rpc("debug.omnibar", {"window": WINDOW}) or {}
    return reply if isinstance(reply, dict) else {}


def center(rect, dy=0.0):
    x, y, w, h = rect
    return (x + w / 2, y + h / 2 + dy)


PAGE_HTML = """<!doctype html><title>pointer</title>
<style>body{margin:0;font:18px -apple-system,sans-serif} a{display:block;padding:8px 14px} a:hover{background:#fd0} p{margin:14px}</style>
<a id=lnk href="#x">TOPLINK hover target</a>
<p id=t1>TOPLINE alpha beta gamma delta</p>
<p id=t2>SECOND line epsilon zeta eta theta iota kappa lambda mu</p>
<div style="height:1600px"></div>
<script>window.lastMove=null;addEventListener('mousemove',e=>{lastMove=[e.clientX,e.clientY]},true)</script>"""


def serve():
    root = tempfile.mkdtemp(prefix="omnibar-page-")
    with open(os.path.join(root, "index.html"), "w") as f:
        f.write(PAGE_HTML)
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
    handler.log_message = lambda *args: None
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/index.html"


def page_eval(script):
    reply = call("browser.page.eval", {"script": script})
    return (reply.get("result") or {}).get("value") if reply.get("ok") else {"error": reply.get("error")}


def page_origin(page_point):
    """The page viewport's origin in window points: a real move into the page, then the page's own
    record of that move's client point."""
    page_eval("lastMove=null")
    move(page_point)
    got = quiet_wait(lambda: (lambda v: v if isinstance(v, list) else None)(page_eval("lastMove")), 3)
    return (page_point[0] - got[0], page_point[1] - got[1]) if got else None


def element_center(origin, element_id):
    rect = page_eval(f"(r=>[r.x,r.y,r.width,r.height])(document.getElementById('{element_id}').getBoundingClientRect())")
    if not isinstance(rect, list):
        return None
    return (origin[0] + rect[0] + min(rect[2], 160) / 2, origin[1] + rect[1] + rect[3] / 2)


def real_drag(start, end):
    """A real press, left-drag events along a line and a release (pointer-probe drag); window points."""
    activate()
    (x0, y0), (x1, y1) = to_screen(start), to_screen(end)
    real_move(x0, y0)
    probe("drag", x0, y0, x1, y1, 30)
    print(f"   drag from screen ({x0:.0f}, {y0:.0f}) to ({x1:.0f}, {y1:.0f})", flush=True)


def idle_report(engine, text):
    """The app's CPU share and wakeups per second while the pointer rests on the omnibar text and the
    page has the keyboard (proc_pid_rusage at the start and end, as bench_idle.py)."""
    move(center(text))
    time.sleep(3.0)  # settle: the move's own work ends
    start, began = usage(app.pid), time.monotonic()
    time.sleep(opts.idle_seconds)
    end, elapsed = usage(app.pid), time.monotonic() - began
    if not (start and end):
        return check(False, f"{engine}: the idle sample reads the app's usage")
    cpu = (end[0] - start[0]) / (elapsed * 1e9) * 100
    wakeups = (end[1] - start[1]) / elapsed
    print(f"IDLE {engine} pointer still on the omnibar text, page has the keyboard, {elapsed:.1f} s: "
          f"app CPU {cpu:.3f}%, {wakeups:.2f} wakeups/s (env {opts.env})", flush=True)


def still_pointer_checks(engine, text):
    """The pointer rests on the omnibar text and does not move while the page reloads, and while
    the page sets its own cursor."""
    got = cursor_at(center(text), "iBeam")
    call("browser.page.eval", {"script": "location.reload(); 1"})
    time.sleep(2.0)  # the reload's own cursor changes land while the pointer stays still
    now = probe("cursor")
    print(f"   t={time.monotonic():.3f} screen cursor {now} (still pointer, after a reload)", flush=True)
    check(now == "iBeam", f"{engine} at rest, still pointer over the text while the page reloads: iBeam (screen shows {now})")
    call("browser.page.eval", {"script": "document.documentElement.style.cursor='progress'; 1"})
    time.sleep(1.0)
    now = probe("cursor")
    check(now == "iBeam", f"{engine} at rest, still pointer over the text while the page sets its cursor: iBeam (screen shows {now})")
    call("browser.page.eval", {"script": "document.documentElement.style.cursor=''; 1"})


def page_checks(engine, frames, page):
    """Hover of a page link and a drag-select that leaves the page into the toolbar."""
    bar, text = frames["bar"], frames["text"]
    origin = page_origin(page)
    print(f"{engine}: page viewport origin in the window {origin}", flush=True)
    if not origin:
        return check(False, f"{engine}: the page reports a real pointer move (viewport origin)")
    link = element_center(origin, "lnk")
    move(center(text))
    move(link)
    check(bool(quiet_wait(lambda: page_eval("lnk.matches(':hover')") is True, 3)),
          f"{engine}: the page link shows its hover under the real pointer")
    got = cursor_at(center(text), "iBeam")
    check(got == "iBeam", f"{engine}: I-beam over the text after the pointer leaves a hovered link (screen shows {got})")
    check(bool(quiet_wait(lambda: page_eval("lnk.matches(':hover')") is False, 3)),
          f"{engine}: the link hover clears when the pointer moves up into the toolbar")
    page_eval("getSelection().removeAllRanges()")
    second = element_center(origin, "t2")
    real_drag(second, (text[0] + text[2] / 2, bar[1] + bar[3] / 2))
    selected = page_eval("getSelection().toString()") or ""
    print(f"{engine}: selection after the drag: {str(selected)[:120]!r}", flush=True)
    check(isinstance(selected, str) and "TOPLINE" in selected and "SECOND" in selected,
          f"{engine}: a drag from the page text up over the omnibar keeps selecting")
    page_eval("getSelection().removeAllRanges()")
    click(page)
    quiet_wait(lambda: not omnibar().get("has_focus"), 3)


APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SCRATCH = tempfile.mkdtemp(prefix=f"omnibar-real-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
teardown = TagTeardown(APP)
teardown.install()
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": CONFIG,
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800", **dict(kv.split("=", 1) for kv in opts.env)},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, out {opts.out}, screen height {SCREEN_H}, scale {SCALE}", flush=True)

WINDOW = None
try:
    quiet_wait(lambda: os.path.exists(SOCKET) and alive(), 180)
    focus = rpc("debug.focus") or {}
    if not focus.get("windows"):
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    WINDOW = ((quiet_wait(lambda: (rpc("debug.focus") or {}).get("windows"), 60) or [{}])[0]).get("id")
    # Low on the screen, clear of the top right where notification banners show over the toolbar's end.
    rpc("debug.window_frame", {"window": WINDOW, "frame": [40, 40, 1100, 680]})
    activate()
    print("app active:", app_active(), "main window:", (main_window() or {}).get("frame"), flush=True)
    PAGE_URL = serve()
    for engine in ("chromium", "webkit"):
        print(f"--- {engine} tab", rpc("action.run", {"action": f"openBrowser.{engine}", "args": {"url": PAGE_URL},
                                                    "focus": True}), flush=True)
        def laid_out():  # the toolbar laid out at the window's top (not a zero frame at the origin)
            got = (omnibar().get("pointer") or {}).get("frames") or {}
            bar_now = got.get("bar") or [0, 999, 0, 0]
            return got.get("text_area") and bar_now[2] > 200 and bar_now[1] < 120 and got
        frames = quiet_wait(laid_out, 90) or {}
        print(f"{engine}: frames {json.dumps(frames)}", flush=True)
        quiet_wait(lambda: omnibar().get("text"), 30)
        bar, text, area = frames.get("bar"), frames.get("text"), frames.get("text_area")
        if not (bar and text and area):
            check(False, f"{engine}: the omnibar reports its frames: {frames}")
            continue
        page = (bar[0] + bar[2] / 2, bar[1] + bar[3] + 250)
        click(page)
        quiet_wait(lambda: not omnibar().get("has_focus"), 3)
        print(f"{engine}: windows after a click on the page (class, kind, key): {windows_report()}", flush=True)
        points = {
            "the text": (center(text), "iBeam"),
            "the bar above the text": ((text[0] + text[2] / 2, bar[1] + 1.5), "iBeam"),
            "past the end of the text": ((area[0] + area[2] - 4, bar[1] + bar[3] / 2), "iBeam"),
        }
        if frames.get("chip"):
            points["the page-info chip"] = (center(frames["chip"]), "arrow")
        reload_id = next((name for name in frames if name.endswith("reload")), None)
        if reload_id:
            points["Reload"] = (center(frames[reload_id]), "arrow")
        for name, (point, want) in points.items():
            got = cursor_at(point, want)
            check(got == want, f"{engine} at rest, page has the keyboard: {want} over {name} (screen shows {got})")
        check(alive(), f"{engine}: the app answers after the pointer moves")
        if opts.idle_seconds and engine == "chromium":
            idle_report(engine, text)
        still_pointer_checks(engine, text)
        if opts.quick:
            continue
        page_checks(engine, frames, page)
        check(alive(), f"{engine}: the app answers after the hover and drag checks")
        # The after-move hook's cost (DEBUG `move_hook`, ArrowCursorView.pointerDidMove past its
        # first check): a sweep of real moves across the toolbar and the page.
        before = (omnibar().get("pointer") or {}).get("move_hook") or {}
        for i in range(24):
            real_move(*to_screen((bar[0] + (i % 12) * bar[2] / 12, bar[1] + bar[3] / 2 if i < 12 else page[1])))
        after = (omnibar().get("pointer") or {}).get("move_hook") or {}
        calls = (after.get("calls") or 0) - (before.get("calls") or 0)
        print(f"{engine}: move hook past its first check: {calls} calls in a 24-move sweep; mean over the run "
              f"{after.get('mean_ns', 0):.0f} ns (key window {'a child page window' if engine == 'chromium' else 'top-level: early return'})",
              flush=True)
        for name in ("back", "forward", "reload"):
            ident = next((n for n in frames if n.endswith("." + name)), None)
            if ident:
                move(center(frames[ident]))
                shown = quiet_wait(tooltip_shown, 1.5)
                check(not shown, f"{engine}: no tooltip over {name.capitalize()}")
        overflow = next((n for n in frames if n.endswith("overflow")), None)
        if overflow:
            move(center(frames[overflow]))
            print(f"{engine}: tooltip over More (the control, kept): {bool(quiet_wait(tooltip_shown, 1.5))}", flush=True)
        click(center(text))
        check(bool(quiet_wait(lambda: omnibar().get("has_focus"), 3)), f"{engine}: a real click on the text focuses the omnibar")
        for name in ("the text", "the bar above the text"):
            point, want = points[name]
            got = cursor_at(point, want)
            check(got == want, f"{engine} while editing: {want} over {name} (screen shows {got})")
        rpc("debug.key", {"window": WINDOW, "key": "escape"})
        rpc("debug.key", {"window": WINDOW, "key": "escape"})
        check(alive(), f"{engine}: the app answers after the editing checks")
    print("--- New Tab page", rpc("action.run", {"action": "newTab.page", "focus": True}), flush=True)
    for point in ((600, 20), (600, 44), (300, 44), (600, 300), (40, 400)):
        move(point)
    check(alive(), "New Tab page: the app answers after the pointer moves over it")
finally:
    rpc("debug.quit", {"fixture_quit": "end-sessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
    teardown.end()

with open(os.path.join(opts.out, "app.log"), errors="replace") as f:
    log = f.read()
if "cursor trace installed" in log:
    print(f"trace: the app got {log.count('] event moved ')} mouseMoved, {log.count('] event entered ')} mouseEntered, "
          f"{log.count('] event cursorUpdate ')} cursorUpdate events (moves: {opts.moves})", flush=True)
print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)

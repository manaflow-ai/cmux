#!/usr/bin/env python3
"""Real-pointer check: the browser omnibar's cursor and the navigation buttons' tooltips (`OmnibarPointer`).

  nx-remote --needs input --app-from-fleet cmux --tag TAG --ref SHA -- \\
    'python3 scripts/cmux-next/omnibar-pointer-real.py --tag TAG --app "$NX_APP"'

Input host only: it moves the real pointer and clicks through cua-driver (desktop scope; its
Accessibility grant posts the events) and reads the cursor on screen (`pointer-probe.swift`, built
here with swiftc). The app is launched active with an empty config. For a Chromium tab, a WebKit
tab and a New Tab page:

  1. a real click on the page gives the page the keyboard (a Chromium page window then has the key:
     printed from `debug.window_list`);
  2. the real pointer over the omnibar's text, above it and past its end shows the I-beam; over the
     page-info chip and Reload the arrow;
  3. Back, Forward and Reload show no tooltip (no visible TooltipPanel); the More button shows one
     (printed, the control);
  4. a real click on the omnibar focuses it, and the I-beam stays over the text area;
  5. the app answers after every step (it does not crash on pointer moves).

Exits 1 when a check fails.
"""
import argparse, glob, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--cua", default=os.path.expanduser("~/.local/bin/cua-driver"))
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
    cua("move_cursor", {"x": round(x * SCALE), "y": round(y * SCALE), "scope": "desktop"})


def move(point):
    x, y = to_screen(point)
    real_move(x - 3, y)  # two moves, so the window server sends a move event at the point
    real_move(x, y)
    at = cua("get_cursor_position", {})
    pos = (at.get("x"), at.get("y")) if isinstance(at, dict) else at
    probe_report = (rpc("debug.omnibar", {"window": WINDOW, "probe_x": point[0], "probe_y": point[1]}) or {}).get("pointer") or {}
    report = (omnibar().get("pointer") or {})
    print(f"   region {probe_report.get('probe_region')}; move to window {tuple(round(v) for v in point)} = screen ({x:.0f}, {y:.0f}); pointer at {pos}; "
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
    return quiet_wait(lambda: probe("cursor") == want and want, 2) or probe("cursor")


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
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, out {opts.out}, screen height {SCREEN_H}, scale {SCALE}", flush=True)

WINDOW = None
try:
    quiet_wait(lambda: os.path.exists(SOCKET) and alive(), 180)
    focus = rpc("debug.focus") or {}
    if not focus.get("windows"):
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    WINDOW = ((quiet_wait(lambda: (rpc("debug.focus") or {}).get("windows"), 60) or [{}])[0]).get("id")
    activate()
    print("app active:", app_active(), "main window:", (main_window() or {}).get("frame"), flush=True)
    for engine in ("chromium", "webkit"):
        print(f"--- {engine} tab", rpc("action.run", {"action": f"openBrowser.{engine}", "args": {"url": "https://example.com/"},
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

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)

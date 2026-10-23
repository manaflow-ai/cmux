#!/usr/bin/env python3
"""Chromium layer hosting (fork API 26) works in a real window: pixels, orientation, mouse, keys, scroll, drag.

Launches a tagged cmux-next app (scratch config, no activation) with `browserResize.layerHosting` set by --mode,
opens a probe page in a Chromium tab and checks:

Input is real HID events (CGEventPost: the pointer moves on the fleet host), because the point is that the
WindowServer still routes the mouse and keys to the transparent page window; debug.mouse would post into the cmux
window and skip that. The python process needs the host's event-posting permission (a FAIL row says so).

  hosted      debug.cef tracker.hosted_pages >= 1 (on) or == 0 (off)
  pixels      the page's red top bar shows above its blue bottom bar (the hosted layer is the right way up), in the
              app's own window image (`pixels.window`) and in a screencapture of the page rect (`pixels.screen`);
              either can be blank on a host without Screen Recording for that process
  click       a debug.mouse click in the middle of the page reaches the page's button (the transparent page window
              still takes the mouse)
  keys        debug.key text typed after a click in the page's input lands in it
  scroll      a debug.mouse scroll over the page scrolls it
  drag        a debug.mouse drag inside the page fires the page's pointer events (mousedown, moves, mouseup)
  context     a right click opens Chromium's context menu (the page sees a contextmenu event)

Each row prints PASS or FAIL; OUT/verify-<mode>.json holds them and the snapshot. IME, accessibility, DevTools,
popups and full screen are not covered here (see the design doc's feature table).

Run on a GUI fleet host, never a laptop:
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/cef-layer-verify.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS" --mode on
"""
import argparse, ctypes, glob, json, os, pathlib, signal, socket, struct, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default="/tmp")
parser.add_argument("--mode", default="on", choices=["on", "off"])
parser.add_argument("--keep", action="store_true", help="leave the app running")
opts = parser.parse_args()

TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"cef-layer-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
TUNABLES = os.path.join(SCRATCH, "debug-tunables.json")
json.dump({"version": 1, "values": {"browserResize.layerHosting": opts.mode == "on"}}, open(TUNABLES, "w"))
WINDOW = (80, 80, 1400, 900)
ROWS, TAB = [], {}

PAGE = """<!doctype html><meta charset=utf-8><title>layer probe</title>
<style>html,body{margin:0;height:100%;background:#20a040;font:16px system-ui}
#top{position:fixed;top:0;left:0;right:0;height:40px;background:#ff0000}
#bottom{position:fixed;bottom:0;left:0;right:0;height:40px;background:#0000ff}
#mid{position:fixed;left:10%;right:10%;top:calc(50% - 60px);height:120px;display:flex;gap:10px}
button,input{flex:1;font-size:20px}#tall{height:4000px}</style>
<div id=top></div><div id=bottom></div>
<div id=mid><button id=b onclick="window.__clicks=(window.__clicks||0)+1">click</button><input id=t></div>
<div id=tall></div>
<script>window.__events=[];for(const t of ['mousedown','mousemove','mouseup','contextmenu'])
addEventListener(t,e=>{if(t!=='mousemove'||e.buttons)window.__events.push(t)},true)</script>"""


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
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def action(name, args=None, timeout=60):
    return rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"}, timeout=timeout)


def wait(check, seconds, step=0.2):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def page(script):
    reply = rpc("browser.page.eval", {"script": script, **({"tab": TAB["tab"]} if TAB.get("tab") else {})}, timeout=20)
    if isinstance(reply, dict) and reply.get("tab"):
        TAB.setdefault("tab", reply["tab"])
    return reply.get("value") if isinstance(reply, dict) and "error" not in reply else None


def row(check, ok, observed):
    ROWS.append({"check": check, "ok": bool(ok), "observed": observed})
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {observed}", flush=True)


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class CGRect(ctypes.Structure):
    _fields_ = [("origin", CGPoint), ("size", CGPoint)]


CG = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
CF = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
CG.CGEventCreateMouseEvent.restype = ctypes.c_void_p
CG.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
CG.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
CG.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
CG.CGEventCreateScrollWheelEvent.restype = ctypes.c_void_p
CG.CGEventCreateScrollWheelEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32]
CG.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
CG.CGMainDisplayID.restype = ctypes.c_uint32
CG.CGDisplayBounds.restype = CGRect
CG.CGDisplayBounds.argtypes = [ctypes.c_uint32]
CF.CFRelease.argtypes = [ctypes.c_void_p]
KEYCODES = {"a": 0, "b": 11, "c": 8, "escape": 53}


def post(event):
    CG.CGEventPost(0, event)  # kCGHIDEventTap
    CF.CFRelease(event)
    time.sleep(0.02)  # test harness: the WindowServer delivers in order


def hid_mouse(kind, point, button=0):
    post(CG.CGEventCreateMouseEvent(None, kind, CGPoint(*point), button))


def hid_click(point, right=False):
    down, up = (3, 4) if right else (1, 2)
    hid_mouse(5, point)
    hid_mouse(down, point, 1 if right else 0)
    hid_mouse(up, point, 1 if right else 0)


def hid_key(name):
    for down in (True, False):
        post(CG.CGEventCreateKeyboardEvent(None, KEYCODES[name], down))


def screen_point(fx=0.5, fy=0.5):
    """A point of the page in global display coordinates (top-left origin), from debug.layers host_screen_rect."""
    main = CG.CGDisplayBounds(CG.CGMainDisplayID())
    for window in (rpc("debug.layers") or {}).get("windows") or []:
        for browser in window.get("browsers") or []:
            host = browser.get("host_screen_rect")
            if host:
                hx, hy, hw, hh = host
                return hx + hw * fx, main.size.y - (hy + hh * (1 - fy))
    return None


def page_point(fx=0.5, fy=0.5):
    """A point of the page in the window's top-left points (debug.layers host_screen_rect)."""
    layers = rpc("debug.layers") or {}
    for window in layers.get("windows") or []:
        wx, wy, ww, wh = window.get("frame") or [0, 0, 0, 0]
        for browser in window.get("browsers") or []:
            host = browser.get("host_screen_rect")
            if host:
                hx, hy, hw, hh = host
                return hx - wx + hw * fx, (wy + wh) - (hy + hh * (1 - fy)), window
    return None


def snapshot_bars(path):
    """(rows with the red bar, rows with the blue bar) of the snapshot, top to bottom."""
    bmp = path + ".bmp"
    subprocess.run(["sips", "-s", "format", "bmp", path, "--out", bmp], capture_output=True, timeout=60)
    data = open(bmp, "rb").read()
    offset, width, height, bpp = struct.unpack_from("<I", data, 10)[0], *struct.unpack_from("<iiHH", data, 18)[:2], struct.unpack_from("<H", data, 28)[0]
    stride = ((width * bpp + 31) // 32) * 4
    step = bpp // 8
    red, blue = [], []
    for y in range(0, abs(height), 2):
        line = y if height < 0 else abs(height) - 1 - y  # BMP rows are bottom-up unless height < 0
        base = offset + line * stride
        counts = [0, 0]
        for x in range(0, width, 8):
            b, g, r = data[base + x * step], data[base + x * step + 1], data[base + x * step + 2]
            if r > 200 and g < 60 and b < 60:
                counts[0] += 1
            elif b > 200 and r < 60 and g < 60:
                counts[1] += 1
        if counts[0] * 8 > width * 0.3:
            red.append(y)
        if counts[1] * 8 > width * 0.3:
            blue.append(y)
    return red, blue


def main():
    global SOCKET
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_DEBUG_TUNABLES_FILE": TUNABLES,
           "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(str(v) for v in WINDOW)}
    os.makedirs(opts.out, exist_ok=True)
    log = open(os.path.join(opts.out, f"app-{TAG}-{opts.mode}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    state_socket = os.path.expanduser(f"~/.local/state/cmux/cmux-debug-{TAG}.sock")

    def up():
        global SOCKET
        for path in (f"/tmp/cmux-debug-{TAG}.sock", state_socket):
            if os.path.exists(path):
                SOCKET = path
                if (rpc("debug.windows") or {}).get("windows"):
                    return True
        return False
    try:
        if not wait(up, 120):
            row("launch", False, "the app did not come up")
            return
        time.sleep(4)  # test harness: launch work settles
        probe = os.path.join(SCRATCH, "probe.html")
        open(probe, "w").write(PAGE)
        opened = action("openBrowser.chromium", {"url": pathlib.Path(probe).as_uri()}, timeout=120)
        if not wait(lambda: page("document.readyState === 'complete' && document.title === 'layer probe'"), 60, 0.5):
            row("page", False, f"the probe never loaded: {json.dumps(opened)[:200]} cef {json.dumps(rpc('debug.cef'))[:300]}")
            return
        time.sleep(1.5)  # test harness: first frames settle
        cef = rpc("debug.cef") or {}
        tracker = cef.get("tracker") or {}
        hosted = tracker.get("hosted_pages", 0)
        row("hosted", hosted >= 1 if opts.mode == "on" else hosted == 0,
            {k: tracker.get(k) for k in ("hosted_pages", "hosting_refused")} | {"fork_api": cef.get("fork_api_version")})

        # Two images: the app's own composited window (no page images painted in, `webviews: false`; without
        # Screen Recording the window server may leave out the GPU process's layers) and screencapture of the
        # page's rect (what the display shows, when this process may record the screen).
        images = {}
        shot = os.path.join(opts.out, f"verify-{opts.mode}-window.png")
        reply = rpc("debug.window_snapshot", {"path": shot, "webviews": False}, timeout=60) or {}
        images["window"] = (shot, {k: reply.get(k) for k in ("method", "child_windows", "child_windows_failed")})
        rect = None
        for window in (rpc("debug.layers") or {}).get("windows") or []:
            for browser in window.get("browsers") or []:
                rect = rect or browser.get("host_screen_rect")
        if rect:
            main = CG.CGDisplayBounds(CG.CGMainDisplayID())
            x, y, w, h = rect
            screen = os.path.join(opts.out, f"verify-{opts.mode}-screen.png")
            subprocess.run(["screencapture", "-x", "-R", f"{int(x)},{int(main.size.y - y - h)},{int(w)},{int(h)}", screen],
                           capture_output=True, timeout=60)
            images["screen"] = (screen, {})
        for name, (path, info) in images.items():
            try:
                red, blue = snapshot_bars(path)
                row(f"pixels.{name}", red and blue and max(red) < min(blue),
                    {"red_rows": [min(red), max(red)] if red else None,
                     "blue_rows": [min(blue), max(blue)] if blue else None} | info)
            except (OSError, struct.error, IndexError) as error:
                row(f"pixels.{name}", False, f"image unreadable: {error}")

        point = screen_point(0.3, 0.5)
        if not point:
            row("click", False, "no page rect in debug.layers")
            return
        hid_click(point)  # the first click may only activate the app
        time.sleep(0.3)  # test harness: activation settles
        page("window.__clicks = 0")
        hid_click(point)
        clicks = wait(lambda: page("window.__clicks || 0"), 3)
        row("click", clicks == 1, {"clicks": clicks, "at": [round(v) for v in point],
                                   "note": None if clicks else "no click reached the page (or this process may not post events)"})

        hid_click(screen_point(0.7, 0.5))
        time.sleep(0.3)  # test harness: focus lands in the input
        for key in "abc":
            hid_key(key)
        value = wait(lambda: page("document.getElementById('t').value"), 3)
        row("keys", value == "abc", {"value": value, "active": page("document.activeElement && document.activeElement.id")})

        sp = screen_point(0.5, 0.8)
        hid_mouse(5, sp)
        for _ in range(10):
            post(CG.CGEventCreateScrollWheelEvent(None, 0, 1, -40))  # pixel units, one wheel
            time.sleep(1 / 60)  # test harness: one wheel event per frame
        scrolled = wait(lambda: page("window.scrollY"), 3)
        row("scroll", (scrolled or 0) > 0, {"scrollY": scrolled})

        page("window.__events = []")
        dp = screen_point(0.5, 0.75)
        hid_mouse(5, dp)
        hid_mouse(1, dp)
        for i in range(1, 9):
            hid_mouse(6, (dp[0] + 10 * i, dp[1]))
        hid_mouse(2, (dp[0] + 80, dp[1]))
        events = wait(lambda: page("window.__events.join(',')"), 3) or ""
        row("drag", "mousedown" in events and "mousemove" in events and "mouseup" in events, {"events": events[:120]})

        page("window.__events = []")
        hid_click(dp, right=True)
        events = wait(lambda: page("window.__events.join(',')"), 3) or ""
        row("context", "contextmenu" in events, {"events": events[:120]})
        hid_key("escape")
    finally:
        json.dump({"tag": TAG, "mode": opts.mode, "rows": ROWS}, open(os.path.join(opts.out, f"verify-{opts.mode}.json"), "w"), indent=2)
        if not opts.keep:
            rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
            try:
                app.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.kill(app.pid, signal.SIGKILL)
            subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                           env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)


main()
sys.exit(0 if ROWS and all(r["ok"] for r in ROWS) else 1)

#!/usr/bin/env python3
"""Chromium layer hosting (fork API 26) works in a real window: pixels, orientation, mouse, keys, scroll, drag.

Launches a tagged cmux-next app (scratch config, no activation) with `browserResize.layerHosting` set by --mode,
opens a probe page in a Chromium tab and checks:

Input is real HID events (CGEventPost: the pointer moves on the fleet host), because the point is that the
WindowServer still routes the mouse and keys to the transparent page window; debug.mouse would post into the cmux
window and skip that. The python process needs the host's event-posting permission (a FAIL row says so).

  valid       the page is Chromium: debug.cef shows no `unavailable` and no `fallback`, and windows.fork_api >= 26
              in mode on (below 26 the app never hosts, so an "on" number would be an "off" number)
  hosted      debug.cef tracker.hosted_pages >= 1 (on) or == 0 (off), read as soon as the first page of a new pane
              loaded (no tab switch first: the request made at window creation must host it by itself)
  hosted.fork the fork really moved the page's pixels, not only the app's view: debug.layers counts the CALayerHost
              layers (Chromium's GPU output) per shown page; on: >= 1 inside the context the pane hosts
              (`hosted_context_layer_hosts`; the pane's own tree always has the app's host, so it proves nothing) and 0
              in the page window's. The context count is >= 1 only once Chromium drew there, so a page window with 0
              before the first GPU frame or on the IOSurface fallback does not pass. off: 0 in the pane and >= 1 in the
              page window
  show.again  a shown page that hides and shows again (switch to a new workspace and back) shows its last frame at
              once: the red bar is above the blue one in a screencapture of the page rect taken right after the switch
              back, or in the app's window image (best effort: the capture follows the action's reply by a socket round
              trip, so a frame Chromium draws faster than that can pass). Not covered: whether the fork's deferred hide
              runs after the switch's commit (needs a fork counter)
  pixels      the page's red top bar shows above its blue bottom bar (the hosted layer is the right way up), in the
              app's own window image (`pixels.window`) and in a screencapture of the page rect (`pixels.screen`);
              either can be blank on a host without Screen Recording for that process
  resize.top  Split Down makes the page shorter; a screencapture of the page rect right after the action, while the
              pane still moves, and one after it settles show the red bar at the top edge (a frame of the old size
              anchored at the bottom would push it above the pane). Best effort: a capture takes tens of ms, so a
              stale frame shorter than that can pass
  click       an HID click in the middle of the page reaches the page's button (the transparent page window still
              takes the mouse)
  keys        HID keys typed after an HID click in the page's input land in it
  scroll      HID scroll wheel events over the page scroll it
  drag        an HID drag inside the page fires the page's pointer events (mousedown, moves, mouseup)
  context     an HID right click opens Chromium's context menu (the page sees a contextmenu event)
  select      (hid and cua input) a click on the page's <select> opens Chromium's select popup, a window of the app
              above it (CGWindowList, layer > 0, no grant needed); with --input cua its pixels are not blank in the
              display image; a click on its last item picks that option (the select's value changes)
  popup.*     a click on the page's button opens a window.open popup (debug.popups): `popup.hosted` hosted_pages grows
              by one (on) or stays 0 (off); `popup.pixels` its red bar shows above its blue bar, in the popup's own
              window image (debug.popups snapshot_dir) or, with --input cua, in the display image cut to its frame;
              `popup.click` a click on the popup's button reaches it (it posts a message to the opener)
  devtools.*  docked DevTools (devtools.openDocked): `devtools.hosted` hosted_pages grows by one (on) or stays 0 (off);
              `devtools.pixels` its area shows a drawn page (not one flat colour) in the display image (--input cua)
              or the app's window image; `devtools.click` a click in its area makes the DevTools page window key
              (debug.cef devtools child_windows), after a click on the page made the page's window key

--input cua drives every input and screen image through the CuaDriver daemon on the host (`cua-driver call`), which
holds Accessibility and Screen Recording on the capture minis, so a step whose own process has neither grant still
posts real events at screen points (desktop scope: the WindowServer routes them, as for hid) and reads the display
(get_desktop_state). The run records the daemon's `permissions status` in its facts; a host without the daemon or
its grants fails the input rows with the daemon's answer.

--checks hosted runs only `valid`, `hosted`, `hosted.fork` and `show.again` (cef-layer-ab.py's check of each mode). --tunables build sets the
tunable in the build's own debug-tunables.json (the path `debug.tunables` reports, which the benches read) instead
of a scratch file, and records that path.

Each row prints PASS or FAIL; OUT/verify-<mode>.json holds them, the debug.cef values and the tunables file. IME,
accessibility, extension popups and full screen are not covered here (see the design doc's feature table).

Run on a GUI fleet host, never a laptop:
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/cef-layer-verify.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS" --mode on
On a capture mini (CuaDriver granted), through the measure suite:
  cmux-ci run --class exclusive --measurement --label measure --display --target-worker cmux11s-Mac-mini.local \\
    --script scripts/measure/split-spring.sh --arg=--suite=cef-api30 --arg=--parts=verify-on-cua,verify-off-cua \\
    --ref SHA --artifact artifacts/split-spring/bundle.tar.gz
"""
import argparse, ctypes, glob, json, os, pathlib, signal, socket, struct, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default="/tmp")
parser.add_argument("--mode", default="on", choices=["on", "off"])
parser.add_argument("--keep", action="store_true", help="leave the app running")
parser.add_argument("--input", default="hid", choices=["hid", "debug", "cua"],
                    help="hid: real CGEvents (nx-remote --needs input); debug: debug.mouse/debug.key into the app's queue "
                         "(any GUI slot; proves the page window takes AppKit's events, not the WindowServer's routing); "
                         "cua: real events and display images through the host's CuaDriver daemon (capture minis)")
parser.add_argument("--cua-driver", default="/Applications/CuaDriver.app/Contents/MacOS/cua-driver")
parser.add_argument("--checks", default="all", choices=["all", "hosted"], help="hosted: only the valid, hosted, hosted.fork and show.again rows")
parser.add_argument("--tunables", default="scratch", choices=["scratch", "build"],
                    help="build: set the tunable in the build's own debug-tunables.json (what the benches read)")
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
# Left of the top-right corner, where macOS shows notification banners: one there (an iCloud alert on cmux11s) took the
# clicks meant for the page (step dc19047674621e1ae9bb11aa).
WINDOW = (40, 40, 1300, 900)
KEY = "browserResize.layerHosting"
LAYER_HOSTING_FORK_API = 26
ROWS, TAB, FACTS = [], {}, {}

PAGE = """<!doctype html><meta charset=utf-8><title>layer probe</title>
<style>html,body{margin:0;height:100%;background:#20a040;font:16px system-ui}
#top{position:fixed;top:0;left:0;right:0;height:40px;background:#ff0000}
#bottom{position:fixed;bottom:0;left:0;right:0;height:40px;background:#0000ff}
#mid{position:fixed;left:10%;right:10%;top:calc(50% - 60px);height:120px;display:flex;gap:10px}
#row2{position:fixed;left:10%;right:10%;top:calc(50% + 80px);height:60px;display:flex;gap:10px}
button,input,select{flex:1;font-size:20px}#tall{height:4000px}</style>
<div id=top></div><div id=bottom></div>
<div id=mid><button id=b onclick="window.__clicks=(window.__clicks||0)+1">click</button><input id=t></div>
<div id=row2><button id=pop onclick="window.open('popup.html','layerpopup','popup,width=520,height=420,left=220,top=180')">popup</button>
<select id=s><option value=a>alpha</option><option value=b>beta</option><option value=c>gamma</option></select></div>
<div id=tall></div>
<script>window.__events=[];for(const t of ['mousedown','mousemove','mouseup','contextmenu'])
addEventListener(t,e=>{if(t!=='mousemove'||e.buttons)window.__events.push(t)},true)
addEventListener('message',e=>{if(e.data==='popup-click')window.__popupClicks=(window.__popupClicks||0)+1})</script>"""
# The window.open popup (popup.html beside the probe): the same bars, and a button that tells the opener it was clicked
# (file pages are cross-origin to each other, so a message, not a shared global).
POPUP_PAGE = """<!doctype html><meta charset=utf-8><title>layer popup</title>
<style>html,body{margin:0;height:100%;background:#20a040;font:16px system-ui}
#top{position:fixed;top:0;left:0;right:0;height:40px;background:#ff0000}
#bottom{position:fixed;bottom:0;left:0;right:0;height:40px;background:#0000ff}
button{position:fixed;left:15%;right:15%;top:calc(50% - 40px);height:80px;font-size:20px}</style>
<div id=top></div><div id=bottom></div>
<button onclick="opener&&opener.postMessage('popup-click','*')">popup click</button>"""


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


DEBUG_MOUSE = {5: "move", 1: "down", 2: "up", 6: "drag", 3: "down", 4: "up"}
CUA = {}


def cua_env():
    """The daemon's socket is under the login's own home (~/Library/Caches/cua-driver); a fleet step runs with a HOME of
    its own, where the client finds no daemon."""
    import pwd
    return dict(os.environ, HOME=pwd.getpwuid(os.getuid()).pw_dir)


def cua(tool, args=None, timeout=30):
    """One CuaDriver tool call through the host's daemon (it holds the grants); its JSON answer, or {"error": ...}."""
    try:
        done = subprocess.run([opts.cua_driver, "call", tool, json.dumps(args or {})], capture_output=True, text=True,
                              timeout=timeout, env=cua_env())
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"error": f"cua-driver {tool}: {error}"}
    try:
        answer = json.loads(done.stdout) if done.stdout.strip() else None
    except ValueError:
        answer = None
    if done.returncode != 0 or not isinstance(answer, dict) or answer.get("isError") or answer.get("error"):
        failure = {"error": f"cua-driver {tool}: exit {done.returncode}: {(done.stderr.strip() or done.stdout.strip())[-300:]}"}
        CUA.setdefault("errors", []).append(failure["error"])
        return failure
    return answer


def cua_scale():
    """Desktop image pixels per point of the main display (get_screen_size), read once."""
    if "scale" not in CUA:
        size = cua("get_screen_size")
        CUA["scale"] = float(size.get("scale_factor") or 0) or 1.0
        CUA["screen"] = {k: size.get(k) for k in ("width", "height", "scale_factor")}
    return CUA["scale"]


def cua_px(point):
    """A global top-left point in desktop image pixels (the main display's origin is 0, 0)."""
    scale = cua_scale()
    return round(point[0] * scale), round(point[1] * scale)


def cua_mouse(kind, point):
    x, y = cua_px(point)
    if kind == 5:
        cua("move_cursor", {"scope": "desktop", "x": x, "y": y})
    elif kind in (1, 3):
        CUA["down"] = (x, y)
    elif kind == 6:
        CUA["drag_to"] = (x, y)
    elif kind in (2, 4):
        # A press and its release are one call: a click where the press was, or a drag from it to here.
        start = CUA.pop("down", (x, y))
        CUA.pop("drag_to", None)
        if start != (x, y):
            cua("drag", {"scope": "desktop", "from_x": start[0], "from_y": start[1], "to_x": x, "to_y": y,
                         "steps": 8, "duration_ms": 300})
        else:
            cua("click", {"scope": "desktop", "x": x, "y": y, "button": "right" if kind == 4 else "left"})


def to_window(point):
    """A global top-left display point in the cmux window's top-left points (debug.mouse)."""
    main = CG.CGDisplayBounds(CG.CGMainDisplayID())
    for window in (rpc("debug.layers") or {}).get("windows") or []:
        wx, wy, ww, wh = window.get("frame") or [0, 0, 0, 0]
        return point[0] - wx, point[1] - (main.size.y - wy - wh)
    return point


def hid_mouse(kind, point, button=0):
    if opts.input == "cua":
        cua_mouse(kind, point)
        return
    if opts.input == "debug":
        x, y = to_window(point)
        params = {"action": DEBUG_MOUSE[kind], "x": x, "y": y}
        if kind in (3, 4):
            params["button"] = "right"
        if kind == 6:
            params = {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1, "press": False, "release": False}
        rpc("debug.mouse", params)
        return
    post(CG.CGEventCreateMouseEvent(None, kind, CGPoint(*point), button))


def hid_click(point, right=False):
    down, up = (3, 4) if right else (1, 2)
    hid_mouse(5, point)
    hid_mouse(down, point, 1 if right else 0)
    hid_mouse(up, point, 1 if right else 0)


def hid_key(name):
    if opts.input == "cua":
        cua("press_key", {"scope": "desktop", "key": name})  # the frontmost app: the click before activated it
        time.sleep(0.02)  # test harness: keys in order
        return
    if opts.input == "debug":
        rpc("debug.key", {"key": name})
        return
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


def read_bmp(path):
    """The image as BMP bytes: (data, pixel offset, width, height, bytes per pixel, stride)."""
    bmp = path + ".bmp"
    subprocess.run(["sips", "-s", "format", "bmp", path, "--out", bmp], capture_output=True, timeout=60)
    data = open(bmp, "rb").read()
    os.remove(bmp)
    offset, width, height, bpp = struct.unpack_from("<I", data, 10)[0], *struct.unpack_from("<iiHH", data, 18)[:2], struct.unpack_from("<H", data, 28)[0]
    return data, offset, width, height, bpp // 8, ((width * bpp + 31) // 32) * 4


def bmp_line(height, y):
    return y if height < 0 else abs(height) - 1 - y  # BMP rows are bottom-up unless height < 0


def image_detail(path):
    """How many distinct colours (5 bits a channel) a sample of the image holds: 1-2 for a blank or flat area."""
    try:
        data, offset, width, height, step, stride = read_bmp(path)
    except (OSError, struct.error, IndexError):
        return 0
    colours = set()
    for y in range(0, abs(height), 4):
        base = offset + bmp_line(height, y) * stride
        for x in range(0, width, 4):
            b, g, r = data[base + x * step], data[base + x * step + 1], data[base + x * step + 2]
            colours.add((r >> 3, g >> 3, b >> 3))
    return len(colours)


def snapshot_bars(path):
    """(rows with the red bar, rows with the blue bar) of the snapshot, top to bottom."""
    data, offset, width, height, step, stride = read_bmp(path)
    red, blue = [], []
    for y in range(0, abs(height), 2):
        base = offset + bmp_line(height, y) * stride
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


def page_rect():
    for window in (rpc("debug.layers") or {}).get("windows") or []:
        for browser in window.get("browsers") or []:
            if browser.get("host_screen_rect"):
                return browser["host_screen_rect"]
    return None


def screen_image(rect, name):
    """A PNG of the display cut to RECT (AppKit screen points, y from the bottom) now, or None: screencapture, or with
    --input cua the CuaDriver daemon's display image (its own Screen Recording grant) cut with sips."""
    main = CG.CGDisplayBounds(CG.CGMainDisplayID())
    x, y, w, h = rect
    top = main.size.y - y - h
    path = os.path.join(os.path.realpath(opts.out), f"verify-{opts.mode}-{name}.png")  # CuaDriver refuses /tmp's symlink
    if os.path.exists(path):
        os.remove(path)
    if opts.input != "cua":
        subprocess.run(["screencapture", "-x", "-R", f"{int(x)},{int(top)},{int(w)},{int(h)}", path],
                       capture_output=True, timeout=60)
        return path if os.path.exists(path) else None
    full = path[:-4] + "-display.png"
    reply = cua("get_desktop_state", {"screenshot_out_file": full})
    if "error" in reply or not os.path.exists(full):
        FACTS.setdefault("capture_errors", []).append({name: reply.get("error") or "no display image"})
        return None
    scale = (float(reply.get("screenshot_width") or 0) / float(reply.get("screen_width") or 1)) or cua_scale()
    subprocess.run(["sips", "-c", str(round(h * scale)), str(round(w * scale)), "--cropOffset", str(round(top * scale)),
                    str(round(x * scale)), full, "--out", path], capture_output=True, timeout=60)
    os.remove(full)  # the whole display can show more than the app: keep only the cut
    return path if os.path.exists(path) else None


def capture_bars(name, rect=None):
    """(red rows, blue rows, image rows) of a display image of RECT (default the page rect) now, or None without a rect
    or image."""
    rect = rect or page_rect()
    if not rect:
        return None
    path = screen_image(rect, name)
    if not path:
        return None
    try:
        red, blue = snapshot_bars(path)
    except (OSError, struct.error, IndexError):
        return None
    info = subprocess.run(["sips", "-g", "pixelHeight", path], capture_output=True, text=True, timeout=30).stdout
    rows = next((int(line.split()[-1]) for line in info.splitlines() if "pixelHeight" in line), 0)
    return red, blue, rows


def write_build_tunable(path, value):
    """The build's own override file, after the app quit (its coalesced writer cannot race this)."""
    try:
        with open(path) as existing:
            data = json.load(existing)
    except (OSError, ValueError):
        data = {"version": 1, "values": {}}
    data.setdefault("values", {})[KEY] = value
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as out:
        json.dump(data, out, indent=2, sort_keys=True)


def check_valid_and_hosted():
    cef = rpc("debug.cef") or {}
    tracker = cef.get("tracker") or {}
    fork_api = (cef.get("windows") or {}).get("fork_api") or 0
    unavailable, fallback = cef.get("unavailable"), cef.get("fallback")
    hosted = tracker.get("hosted_pages", 0)
    FACTS.update({"fork_api": fork_api, "unavailable": unavailable, "fallback": fallback,
                  "hosted_pages": hosted, "hosting_refused": tracker.get("hosting_refused")})
    row("valid", unavailable is None and fallback is None and (opts.mode == "off" or fork_api >= LAYER_HOSTING_FORK_API),
        {"fork_api": fork_api, "unavailable": unavailable, "fallback": fallback})
    row("hosted", hosted >= 1 if opts.mode == "on" else hosted == 0,
        {"hosted_pages": hosted, "hosting_refused": tracker.get("hosting_refused"), "fork_api": fork_api})


def check_fork_hosted():
    """hosted.fork: the CALayerHost layers of each shown Chromium page are where the mode puts them."""
    def pages():
        rows = [b for w in (rpc("debug.layers") or {}).get("windows") or [] for b in w.get("browsers") or []
                if "page_window_layer_hosts" in b]
        if not rows:
            return None
        if opts.mode == "on":
            good = all((b.get("hosted_context_layer_hosts") or 0) >= 1 and b.get("page_window_layer_hosts") == 0 for b in rows)
        else:
            good = all(b.get("hosted_layer_hosts") == 0 and (b.get("page_window_layer_hosts") or 0) >= 1 for b in rows)
        return (good, rows) if good else None
    # Chromium's first GPU frame makes its CALayerHost: give it a moment, then report what is there.
    found = wait(pages, 5)
    rows = found[1] if found else [b for w in (rpc("debug.layers") or {}).get("windows") or [] for b in w.get("browsers") or []
                                   if "page_window_layer_hosts" in b]
    FACTS["layer_hosts"] = [{k: b.get(k) for k in ("pane", "hosted_layer_hosts", "hosted_context_layer_hosts",
                                                  "page_window_layer_hosts")} for b in rows]
    row("hosted.fork", bool(found), {"pages": FACTS["layer_hosts"],
                                     "note": None if rows else "no shown Chromium page in debug.layers (a build without the counts?)"})


def bars_ok(red, blue):
    return bool(red) and bool(blue) and max(red) < min(blue)


def check_show_again():
    """show.again: hide the page (a new workspace) and show it again; its last frame must show at once."""
    probe_ws = ((rpc("snapshot.get") or {}).get("topology") or {}).get("focus", {}).get("workspace")
    created = action("workspace.newAtBottom")
    if not wait(lambda: page_rect() is None, 5, 0.05):
        row("show.again", False, {"note": "the page still shows after workspace.newAtBottom", "reply": json.dumps(created)[:200]})
        return
    time.sleep(0.5)  # test harness: the hidden page window's deferred hide and Widget::Hide run
    # Back to the probe's own workspace (openBrowser.chromium may open the probe in a workspace of its own, so
    # selectFirst showed the launch's terminal workspace and every later row read no page).
    back = action("goToWorkspace", {"workspace": probe_ws}) if probe_ws else action("workspace.selectFirst")
    # Right after the reply: the screen first (what the display shows), then the app's own window image.
    screen = capture_bars("show-again-screen")
    shot = os.path.join(opts.out, f"verify-{opts.mode}-show-again-window.png")
    rpc("debug.window_snapshot", {"path": shot, "webviews": False}, timeout=60)
    try:
        window = snapshot_bars(shot)
    except (OSError, struct.error, IndexError):
        window = None
    observed = {name: ({"red_rows": [min(b[0]), max(b[0])] if b[0] else None,
                        "blue_rows": [min(b[1]), max(b[1])] if b[1] else None} if b else None)
                for name, b in (("screen", screen), ("window", window))}
    ok = bool(screen and bars_ok(screen[0], screen[1])) or bool(window and bars_ok(window[0], window[1]))
    row("show.again", ok, observed | {"reply": json.dumps(back)[:120]})
    # The new workspace stays (closing one asks to confirm); the probe's workspace is shown again for the rows after.
    wait(lambda: page_rect() is not None, 5, 0.05)


def app_windows(pid):
    """PID's on-screen windows (every process's for None), front to back: window, layer, pid, owner, bounds
    {x, y, width, height} in top-left points (CGWindowList: bounds, layers and owner names need no grant)."""
    vp = ctypes.c_void_p
    CG.CGWindowListCopyWindowInfo.restype = vp
    CG.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    CF.CFArrayGetCount.restype = ctypes.c_long
    CF.CFArrayGetCount.argtypes = [vp]
    CF.CFArrayGetValueAtIndex.restype = vp
    CF.CFArrayGetValueAtIndex.argtypes = [vp, ctypes.c_long]
    CF.CFDictionaryGetValue.restype = vp
    CF.CFDictionaryGetValue.argtypes = [vp, vp]
    CF.CFStringCreateWithCString.restype = vp
    CF.CFStringCreateWithCString.argtypes = [vp, ctypes.c_char_p, ctypes.c_uint32]
    CF.CFNumberGetValue.restype = ctypes.c_bool
    CF.CFNumberGetValue.argtypes = [vp, ctypes.c_int, vp]
    keys = {}

    def key(name):
        if name not in keys:
            keys[name] = CF.CFStringCreateWithCString(None, name.encode(), 0x08000100)
        return keys[name]

    def num(d, name):
        value, out = CF.CFDictionaryGetValue(d, key(name)), ctypes.c_double()
        return out.value if value and CF.CFNumberGetValue(value, 13, ctypes.byref(out)) else 0.0  # kCFNumberDoubleType

    array = CG.CGWindowListCopyWindowInfo(1 | 16, 0)  # on screen only, no desktop elements
    windows = []
    try:
        for i in range(CF.CFArrayGetCount(array) if array else 0):
            d = CF.CFArrayGetValueAtIndex(array, i)
            owner_pid = int(num(d, "kCGWindowOwnerPID"))
            if pid is not None and owner_pid != pid:
                continue
            b = CF.CFDictionaryGetValue(d, key("kCGWindowBounds"))
            name, text = CF.CFDictionaryGetValue(d, key("kCGWindowOwnerName")), ctypes.create_string_buffer(256)
            CF.CFStringGetCString.argtypes = [vp, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
            owner = text.value.decode(errors="replace") if name and CF.CFStringGetCString(name, text, 256, 0x08000100) else None
            windows.append({"window": int(num(d, "kCGWindowNumber")), "layer": int(num(d, "kCGWindowLayer")),
                            "pid": owner_pid, "owner": owner,
                            "bounds": {k: num(b, k[0].upper() + k[1:]) for k in ("x", "y", "width", "height")}})
    finally:
        if array:
            CF.CFRelease(array)
        for made in keys.values():
            if made:
                CF.CFRelease(made)
    return windows


def covering(point, pid):
    """The frontmost on-screen window of another process over POINT (owner name and layer), or None: a system banner
    there takes the click."""
    for window in app_windows(None):
        b = window["bounds"]
        if b["x"] <= point[0] < b["x"] + b["width"] and b["y"] <= point[1] < b["y"] + b["height"]:
            return None if window["pid"] == pid else {k: window[k] for k in ("owner", "layer", "bounds")}
    return None


def appkit_rect(rect):
    """[x, y, w, h] in AppKit screen points from a debug reply's rect ([x, y, w, h] or {x, y, width, height})."""
    return [rect["x"], rect["y"], rect["width"], rect["height"]] if isinstance(rect, dict) else list(rect)


def rect_center(rect, dy=0.0):
    """The global top-left point at the middle of an AppKit rect (dy points lower)."""
    main = CG.CGDisplayBounds(CG.CGMainDisplayID())
    x, y, w, h = appkit_rect(rect)
    return x + w / 2, main.size.y - (y + h / 2) + dy


def element_point(element_id):
    """The global point at the middle of the page element ELEMENT_ID (its client rect over the page's rect)."""
    where = page(f"(()=>{{const r=document.getElementById('{element_id}').getBoundingClientRect();"
                 "return JSON.stringify([(r.left+r.width/2)/innerWidth,(r.top+r.height/2)/innerHeight])})()")
    try:
        fx, fy = json.loads(where) if isinstance(where, str) else where
    except (TypeError, ValueError):
        FACTS.setdefault("element_point_misses", []).append({element_id: repr(where)[:120]})
        return None
    return screen_point(fx, fy)


def hosted_pages():
    return ((rpc("debug.cef") or {}).get("tracker") or {}).get("hosted_pages", 0)


def hosted_grew(before):
    """hosted_pages after a new Chromium page opened: one more (on) or still 0 (off), within 5 s; (ok, now)."""
    want = (lambda n: n >= before + 1) if opts.mode == "on" else (lambda n: n == 0)
    now = wait(lambda: (lambda n: n if want(n) else None)(hosted_pages()), 5)
    return (now is not None), (now if now is not None else hosted_pages())


def check_select(pid):
    """select: a click on the <select> opens Chromium's popup window; a click on its last item picks it."""
    if opts.input == "debug":
        row("select", False, {"note": "not run with --input debug: an open select popup's tracking holds the socket "
                                      "that debug.mouse goes through (use --input cua or hid)"})
        return
    page("document.getElementById('s').value = 'a'")
    point = element_point("s")
    if not point:
        row("select.popup", False, {"note": "no page point for the select"})
        return
    before = {w["window"] for w in app_windows(pid) if w["layer"] > 0}
    hid_click(point)
    time.sleep(1)  # test harness: the popup opens (its tracking holds the app's main thread: no socket call until it closes)
    menus = [w for w in app_windows(pid) if w["layer"] > 0 and w["window"] not in before]
    detail = None
    if menus and opts.input == "cua":
        main = CG.CGDisplayBounds(CG.CGMainDisplayID())
        b = menus[0]["bounds"]
        image = screen_image([b["x"], main.size.y - b["y"] - b["height"], b["width"], b["height"]], "select-popup")
        detail = image_detail(image) if image else 0
    row("select.popup", bool(menus) and (detail is None or detail > 8),
        {"at": [round(v) for v in point], "popup_windows": menus[:3], "colours": detail,
         "note": None if menus else "no new window of the app above layer 0 after the click"})
    if not menus:
        row("select.click", False, {"note": "no popup to click"})
        return
    # The last of three items: the menu's rows share its height less a few points of padding at each end.
    b, pad = menus[0]["bounds"], 6
    item = (b["height"] - 2 * pad) / 3
    hid_click((b["x"] + b["width"] / 2, b["y"] + b["height"] - pad - item / 2))
    time.sleep(0.5)  # test harness: the menu closes
    still = [w for w in app_windows(pid) if w["window"] == menus[0]["window"]]
    if still:
        hid_key("escape")
    value = wait(lambda: (lambda v: v if v and v != "a" else None)(page("document.getElementById('s').value")), 3)
    row("select.click", value == "c", {"value": value or page("document.getElementById('s').value"),
                                       "popup_still_open": bool(still)})


def popup_panel():
    panels = (rpc("debug.popups") or {}).get("panels") or []
    return next((p for p in panels if p.get("visible") and str(p.get("url") or "").endswith("popup.html")), None)


def check_popup():
    """popup.*: window.open from a click opens a popup window that hosts (or not, by mode), draws and takes a click."""
    before = hosted_pages()
    page("window.__popupClicks = 0")
    point = element_point("pop")
    if point:
        hid_click(point)
    panel = wait(popup_panel, 10, 0.25)
    if not panel:
        row("popup.open", False, {"at": point and [round(v) for v in point], "popups": json.dumps(rpc("debug.popups"))[:300]})
        return
    ok, now = hosted_grew(before)
    row("popup.hosted", ok, {"hosted_pages_before": before, "hosted_pages": now, "engine": panel.get("engine")})
    time.sleep(1.5)  # test harness: the popup's first frames
    snapshots = os.path.join(opts.out, f"verify-{opts.mode}-popup")
    panel = next((p for p in (rpc("debug.popups", {"snapshot_dir": snapshots}) or {}).get("panels") or []
                  if str(p.get("url") or "").endswith("popup.html")), panel)
    seen = {}
    if panel.get("snapshot"):
        try:
            seen["window"] = snapshot_bars(panel["snapshot"])
        except (OSError, struct.error, IndexError):
            seen["window"] = None
    if opts.input != "debug":
        bars = capture_bars("popup-screen", appkit_rect(panel["frame"]))
        seen["screen"] = bars[:2] if bars else None
    row("popup.pixels", any(b and bars_ok(b[0], b[1]) for b in seen.values()),
        {name: ({"red_rows": [min(b[0]), max(b[0])] if b[0] else None, "blue_rows": [min(b[1]), max(b[1])] if b[1] else None}
                if b else None) for name, b in seen.items()} | {"frame": panel.get("frame")})
    # The page's own window over the popup (a child window) when there is one, else the popup's middle under its bar.
    children = [c for c in panel.get("child_windows") or [] if c.get("visible")]
    target = rect_center(children[0]["frame"]) if children else rect_center(panel["frame"], 20)
    clicks, tries = None, 0
    for tries in (1, 2):  # the first click may only make the popup key
        hid_click(target)
        clicks = wait(lambda: page("window.__popupClicks || 0"), 2)
        if clicks:
            break
    row("popup.click", bool(clicks), {"clicks": clicks, "clicks_sent": tries, "at": [round(v) for v in target],
                                      "child_windows": children[:2]})
    rpc("debug.popups", {"action": "close"})
    wait(lambda: popup_panel() is None, 5)


def devtools_entry():
    return next((d for d in (rpc("debug.cef") or {}).get("devtools") or [] if d.get("open") and d.get("devtools_frame")), None)


def check_devtools():
    """devtools.*: docked DevTools hosts (or not, by mode), draws, and a click in it makes its page window key."""
    before = hosted_pages()
    reply = action("devtools.openDocked")
    entry = wait(devtools_entry, 15, 0.25)
    if not entry:
        row("devtools.open", False, {"reply": json.dumps(reply)[:200], "devtools": json.dumps((rpc("debug.cef") or {}).get("devtools"))[:300]})
        return
    ok, now = hosted_grew(before)
    row("devtools.hosted", ok, {"hosted_pages_before": before, "hosted_pages": now, "dock": entry.get("dock")})
    time.sleep(2.5)  # test harness: the DevTools front end loads and draws
    entry = devtools_entry() or entry
    image = screen_image(appkit_rect(entry["devtools_frame"]), "devtools-screen")
    detail = image_detail(image) if image else 0
    row("devtools.pixels", detail > 8, {"colours": detail, "devtools_frame": entry.get("devtools_frame"),
                                         "via": "cua" if opts.input == "cua" else "screencapture"})
    def devtools_key():
        found = devtools_entry()
        return found if found and any(c.get("devtools") and c.get("key") for c in found.get("child_windows") or []) else None
    if entry.get("page_frame"):
        hid_click(rect_center(entry["page_frame"]))  # the page's window key first
        wait(lambda: not devtools_key(), 2)
    # Opening DevTools can make its window key by itself: the click proves something only when it was not key before.
    key_before = bool(devtools_key())
    point = rect_center(entry["devtools_frame"])
    key = None
    for _ in (1, 2):  # the first click may only activate
        hid_click(point)
        key = wait(devtools_key, 2)
        if key:
            break
    final = key or devtools_entry() or {}
    row("devtools.click", bool(key) and not key_before,
        {"at": [round(v) for v in point], "key_before_click": key_before, "child_windows": (final.get("child_windows") or [])[:4],
         "note": "DevTools was key before the click (the page click did not take the key)" if key_before else None})
    action("devtools.close")


def main():
    global SOCKET
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
           "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(str(v) for v in WINDOW)}
    if opts.tunables == "scratch":
        env["CMUX_NEXT_DEBUG_TUNABLES_FILE"] = TUNABLES
    os.makedirs(opts.out, exist_ok=True)
    # An empty saved session, as every bench launch (bench_launch.py start_fresh): a session an earlier bench left
    # (the STRESS layout) put the probe in a small pane of one of 60 workspaces, and workspace.selectFirst went elsewhere.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from bench_launch import BenchApp
    bench = BenchApp(APP, out=opts.out)
    if not os.environ.get("BENCH_LAUNCH_KEEP_STATE"):
        bench.start_fresh()
    if opts.tunables == "build":
        # The launch reads the build's file: give it this mode before the first page (a page shown at launch with the
        # last run's value would count as hosted in mode off). A build that keeps its app names reads another path
        # (DebugSettingsService.fileURL); the live `set` below still decides that launch's mode.
        FACTS["tunables_prelaunch"] = os.path.join(bench.state_root(), "debug-tunables.json")
        write_build_tunable(FACTS["tunables_prelaunch"], opts.mode == "on")
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
        if opts.tunables == "build":
            # The benches launch with no override: they read this file. Set the value live for this launch too.
            state = rpc("debug.tunables", {"action": "set", "key": KEY, "value": opts.mode == "on"}) or {}
            if not state.get("file"):  # `set` answers with the tunable's row; the file is in the state
                FACTS["tunables_set"] = state
                state = rpc("debug.tunables", {"action": "state"}) or {}
            FACTS["tunables_file"] = state.get("file")
            FACTS["tunables_prelaunch_matched"] = FACTS.get("tunables_prelaunch") == state.get("file")
            if not state.get("file"):
                row("tunables", False, f"debug.tunables gave no file: {json.dumps(state)[:200]}")
                return
        probe = os.path.join(SCRATCH, "probe.html")
        open(probe, "w").write(PAGE)
        open(os.path.join(SCRATCH, "popup.html"), "w").write(POPUP_PAGE)
        if opts.input == "cua":
            status = subprocess.run([opts.cua_driver, "permissions", "status"], capture_output=True, text=True, timeout=30,
                                    env=cua_env())
            FACTS["cua"] = {"permissions": (status.stdout or status.stderr).strip()[:400], "screen": (cua_scale(), CUA.get("screen"))[1]}
        opened = action("openBrowser.chromium", {"url": pathlib.Path(probe).as_uri()}, timeout=120)
        if not wait(lambda: page("document.readyState === 'complete' && document.title === 'layer probe'"), 60, 0.5):
            row("page", False, f"the probe never loaded: {json.dumps(opened)[:200]} cef {json.dumps(rpc('debug.cef'))[:300]}")
            return
        # Right after the first page of the new pane loaded, before anything shows a tab again.
        check_valid_and_hosted()
        check_fork_hosted()
        check_show_again()
        if opts.checks == "hosted":
            return
        time.sleep(1.5)  # test harness: first frames settle

        # Two images: the app's own composited window (no page images painted in, `webviews: false`; without
        # Screen Recording the window server may leave out the GPU process's layers) and screencapture of the
        # page's rect (what the display shows, when this process may record the screen).
        images = {}
        shot = os.path.join(opts.out, f"verify-{opts.mode}-window.png")
        reply = rpc("debug.window_snapshot", {"path": shot, "webviews": False}, timeout=60) or {}
        images["window"] = (shot, {k: reply.get(k) for k in ("method", "child_windows", "child_windows_failed")})
        rect = page_rect()
        if rect:
            screen = screen_image(rect, "screen")
            images["screen"] = (screen or os.path.join(opts.out, f"verify-{opts.mode}-screen.png"), {"via": opts.input if opts.input == "cua" else "screencapture"})
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
        row("click", clicks == 1, {"clicks": clicks, "at": [round(v) for v in point], "covered_by": covering(point, app.pid),
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
            if opts.input == "cua":
                x, y = cua_px(sp)
                cua("scroll", {"scope": "desktop", "x": x, "y": y, "direction": "down", "amount": 3, "by": "line"})
            elif opts.input == "debug":
                x, y = to_window(sp)
                rpc("debug.mouse", {"action": "scroll", "x": x, "y": y, "dy": -40})
            else:
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
        if opts.input != "debug":
            # An open context menu's tracking holds the app's main thread, so the socket answers only once it closes.
            time.sleep(1)  # test harness: the menu opens
            hid_key("escape")
        events = wait(lambda: page("window.__events.join(',')"), 3) or ""
        row("context", "contextmenu" in events, {"events": events[:120]})
        if opts.input == "debug":
            hid_key("escape")

        check_select(app.pid)
        check_popup()
        check_devtools()

        # The page gets shorter: its red bar must stay at the top edge while Chromium catches up and after.
        action("splitDown")
        moving = capture_bars("resize-moving")
        time.sleep(1.2)  # test harness: the split's spring lands
        settled = capture_bars("resize-settled")

        def at_top(bars):
            if not bars:
                return False
            red, blue, rows = bars
            return bool(red) and min(red) <= max(8, rows * 0.05) and (not blue or max(red) < min(blue))
        row("resize.top", at_top(moving) and at_top(settled),
            {name: ({"red_rows": [min(b[0]), max(b[0])] if b[0] else None, "rows": b[2]} if b else None)
             for name, b in (("moving", moving), ("settled", settled))})
    finally:
        if not opts.keep:
            rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
            try:
                app.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.kill(app.pid, signal.SIGKILL)
            subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                           env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
        if opts.tunables == "build" and FACTS.get("tunables_file") and not opts.keep:
            write_build_tunable(FACTS["tunables_file"], opts.mode == "on")
        json.dump({"tag": TAG, "mode": opts.mode, "rows": ROWS, "facts": FACTS},
                  open(os.path.join(opts.out, f"verify-{opts.mode}.json"), "w"), indent=2)


main()
sys.exit(0 if ROWS and all(r["ok"] for r in ROWS) else 1)

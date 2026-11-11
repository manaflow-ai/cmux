#!/usr/bin/env python3
"""Real pointer drags of pictures and files from other apps into Home's message box (Lawrence 2026-10-20:
"I want people to drag images into Chief properly").

  nx-remote --needs input --input-reason "real CGEvent drags from Finder, Chrome, Safari, Preview and the screenshot thumbnail into Home" \
    --input-minutes 20 --app-from-fleet cmux --tag T --ref SHA -- \
    python3 scripts/cmux-next/home-image-drop-proof.py --app "$NX_APP" --out "$NX_ARTIFACTS/drop"

Launches the tagged app (classic Home, automation socket, no activation, window on the right half of the
main screen), opens the DEBUG Home fixture (the real native transcript over a HomeStore over the mock
owner) and, per source, puts the source app's window on the left half and drags with real CGEvents at the
HID tap (mouse down on the source, about 40 drag moves, a hold over Home, mouse up):

  finder-*        a file from a Finder window (png, jpg, heic, gif, pdf; `multi`: all five at once)
  screenshot      the floating thumbnail after Cmd+Shift+3 (a file promise)
  chrome, safari  an <img> that fills a local page (http://127.0.0.1)
  cmux-browser    the same page in a cmux browser tab of the tagged app (its own window)
  preview         Preview's Select All, dragged from the picture

Per case it records the draft as Home holds it when the app reports it (`debug.home.drive geometry`:
draftAttachments, dropPending, dropHighlighted on newer builds), a window snapshot while the pointer holds over Home (the drop highlight), the draft after
the drop, and then sends the draft (`debug.home.drive send`): a send that goes with attachments lists them
in the transcript rows. Writes OUT/result.json and OUT/*.png. Photos needs a library item and is not
covered (the host's library is empty). Cleans up what it opened (its Chrome profile instance, the Safari
tab, the Finder and Preview windows, the screenshot file) and stops the app.
"""
import argparse, ctypes, ctypes.util, glob, json, os, shutil, socket, struct, subprocess, sys, threading, time, zlib

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--only", default="", help="comma-separated case names (default: all)")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = opts.app
TAG = os.environ.get("NX_APP_TAG") or os.path.basename(APP).removesuffix(".app").split(" ")[-1]
SOCK = f"/tmp/cmux-debug-{TAG}.sock"
STOP = os.environ.get("NX_APP_STOP")
CLI = os.environ.get("NX_APP_CLI")
HOME = os.environ["HOME"]
CUA = os.path.expanduser("~/.local/bin/cua-driver")
SRC = f"/tmp/hidp-{TAG}"
R = {"tag": TAG, "cases": {}, "setup": {}}
APP_FRAME = (760, 40, 740, 860)  # x, y (top-left of the visible frame), w, h
SOURCE_FRAME = {"x": 0, "y": 60, "width": 720, "height": 760}


def say(*parts):
    print(*parts, flush=True)


def save():
    with open(os.path.join(opts.out, "result.json"), "w") as f:
        json.dump(R, f, indent=1, default=str)


def rpc(method, params=None, timeout=30):
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(timeout); c.connect(SOCK)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            ch = c.recv(1 << 20)
            if not ch:
                break
            buf += ch
        c.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok", True) and "result" in reply else reply
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def until(fn, seconds, step=0.25):
    end = time.time() + seconds
    value = fn()
    while not value and time.time() < end:
        time.sleep(step)  # harness wait for another process, not app code
        value = fn()
    return value


def cua(tool, args, timeout=60):
    try:
        p = subprocess.run([CUA, "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"error": "timeout"}
    try:
        return json.loads(p.stdout)
    except ValueError:
        return {"error": (p.stdout + p.stderr)[-600:]}


def windows():
    found = cua("list_windows", {})
    return found.get("windows") or (found.get("structuredContent") or {}).get("windows") or []


def window(app_part, title_part=None, on_screen=True):
    for w in windows():
        if app_part.lower() in (w.get("app_name") or "").lower() and (title_part is None or title_part.lower() in (w.get("title") or "").lower()):
            if not on_screen or w.get("is_on_screen"):
                return w
    return None


def frame(w, frame=SOURCE_FRAME):
    return cua("set_window_frame", {"pid": w["pid"], "window_id": w["window_id"], **frame})


def center(w):
    b = w["bounds"]
    return b["x"] + b["width"] / 2, b["y"] + b["height"] / 2


def find_elements(obj):
    if isinstance(obj, dict):
        if isinstance(obj.get("elements"), list):
            return obj
        for v in obj.values():
            r = find_elements(v)
            if r:
                return r
    return None


def element_point(w, name):
    """Screen point of the element of `w` labelled `name` (Finder icons): window bounds + frame / scale."""
    state = cua("get_window_state", {"pid": w["pid"], "window_id": w["window_id"], "query": name, "max_image_dimension": 0}, timeout=90)
    body = find_elements(state) or {}
    scale = body.get("screenshot_scale") or state.get("screenshot_scale") or 2
    bounds = body.get("window_bounds") or w["bounds"]
    best = None
    for e in body.get("elements") or []:
        label = (e.get("label") or "") + "|" + str(e.get("value") or "")
        f = e.get("frame") or {}
        if name in label and f.get("w", 0) > 4 and f.get("h", 0) > 4:
            rank = 0 if "image" in (e.get("role") or "").lower() else 1
            if best is None or rank < best[0]:
                best = (rank, f, e.get("role"))
    if not best:
        return None, {"elements": len(body.get("elements") or []), "scale": scale}
    f = best[1]
    # Element frames are screen points (top-left origin), not screenshot pixels: a Finder icon at
    # window-local pixels/2 landed in the sidebar (the first run on 2026-10-20 dragged nothing).
    return (f["x"] + f["w"] / 2, f["y"] + f["h"] / 2), {"role": best[2], "frame": f, "scale": scale, "bounds": bounds}


def close_window(w):
    """Clicks `w`'s own close button through accessibility (never a key to whatever app is in front)."""
    if not w:
        return False
    state = cua("get_window_state", {"pid": w["pid"], "window_id": w["window_id"], "include_screenshot": False, "max_depth": 4})
    body = find_elements(state) or {}
    for e in body.get("elements") or []:
        label = ((e.get("label") or "") + " " + (e.get("role") or "") + " " + str(e.get("subrole") or "")).lower()
        if "close" in label and "button" in label and e.get("element_token"):
            r = cua("click", {"pid": w["pid"], "window_id": w["window_id"], "element_token": e["element_token"]})
            return "error" not in r
    return False


def front(pid):
    cua("bring_to_front", {"pid": pid})


# --- CoreGraphics input (the SSH session has the Accessibility grant) ---
cg = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))


class P(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, P, ctypes.c_uint32]
cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
cg.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
cg.CFRelease.argtypes = [ctypes.c_void_p]
CMD, SHIFT = 0x100000, 0x20000


cg.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
CLICK_STATE = 1  # kCGMouseEventClickState


def mouse(kind, x, y):
    e = cg.CGEventCreateMouseEvent(None, kind, P(x, y), 0)
    if kind in (1, 2, 6):  # down, up, dragged: a single click's press
        cg.CGEventSetIntegerValueField(e, CLICK_STATE, 1)
    cg.CGEventPost(0, e)
    cg.CFRelease(e)


def key(code, flags=0):
    for down in (True, False):
        e = cg.CGEventCreateKeyboardEvent(None, code, down)
        if flags:
            cg.CGEventSetFlags(e, flags)
        cg.CGEventPost(0, e)
        cg.CFRelease(e)
        time.sleep(0.05)  # human-like key interval for the window server


def click(x, y):
    mouse(5, x, y); time.sleep(0.1)
    mouse(1, x, y); time.sleep(0.08)
    mouse(2, x, y); time.sleep(0.2)  # human-like press interval for the window server


def drag(src, dst, during=None, steps=40):
    """A real drag: down on src, small moves (the source starts its drag session after a few points), a hold
    over dst (`during` runs there: the snapshot of the drop highlight), up."""
    (sx, sy), (dx, dy) = src, dst
    mouse(5, sx, sy); time.sleep(0.15)
    mouse(1, sx, sy); time.sleep(0.35)  # press and hold: Finder and the thumbnail start a drag after a short hold
    for i in range(1, 6):
        mouse(6, sx + i * 2, sy + i * 2); time.sleep(0.03)
    for i in range(1, steps + 1):
        t = i / steps
        mouse(6, sx + (dx - sx) * t, sy + (dy - sy) * t); time.sleep(0.025)
    for i in range(6):
        mouse(6, dx + (i % 2), dy); time.sleep(0.08)  # small moves over Home: draggingUpdated
    held = during() if during else None
    mouse(6, dx, dy); time.sleep(0.1)
    mouse(2, dx, dy)
    return held


# --- sources ---
def png_bytes(w=480, h=360):
    rows = b""
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            c = ((x // 40) + (y // 40)) % 2
            row += bytes([255 if c else 30, (x * 255) // w, (y * 255) // h])
        rows += bytes(row)
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def make_sources():
    shutil.rmtree(SRC, ignore_errors=True)
    os.makedirs(SRC)
    base = os.path.join(SRC, "hidp-pic.png")
    open(base, "wb").write(png_bytes())
    made = {"png": base}
    for ext, fmt in (("jpg", "jpeg"), ("heic", "heic"), ("gif", "gif"), ("pdf", "pdf")):
        out = os.path.join(SRC, f"hidp-pic.{ext}")
        p = subprocess.run(["sips", "-s", "format", fmt, base, "--out", out], capture_output=True, text=True)
        if os.path.exists(out):
            made[ext] = out
        else:
            R["setup"][f"sips-{ext}"] = (p.stdout + p.stderr)[-300:]
    for ext, path in made.items():
        d = os.path.join(SRC, f"finder-{ext}"); os.makedirs(d)
        shutil.copy(path, os.path.join(d, os.path.basename(path)))
    multi = os.path.join(SRC, "finder-multi"); os.makedirs(multi)
    for path in made.values():
        shutil.copy(path, os.path.join(multi, os.path.basename(path)))
    web = os.path.join(SRC, "web"); os.makedirs(web)
    shutil.copy(base, os.path.join(web, "hidp-web.png"))
    open(os.path.join(web, "index.html"), "w").write(
        "<!doctype html><title>hidp page</title><style>html,body{margin:0;height:100%;overflow:hidden}"
        "img{display:block;width:100vw;height:100vh;object-fit:cover}</style><img src='hidp-web.png' alt='hidp'>")
    R["setup"]["files"] = sorted(made)
    return made


def serve():
    import http.server, socketserver, functools
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=os.path.join(SRC, "web"))
    handler.log_message = lambda *a: None
    server = socketserver.TCPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}/"


# --- the app ---
HOME_WID = []
APP_PID = [None]


def home_window():
    """The tagged app's Home window: the one recorded at setup, else the app's largest on-screen window."""
    listed = windows()
    # Only this job's app: another lane's tagged app can stay on screen (a401-webviews-v5 on 2026-10-21).
    mine = [x for x in listed if x.get("pid") == APP_PID[0] or (x.get("app_name") or "") == f"cmux DEV {TAG}"]
    if HOME_WID:
        found = next((x for x in mine if x.get("window_id") == HOME_WID[0]), None)
        if found:
            return found
    shown = [x for x in mine if x.get("is_on_screen") and (x.get("bounds") or {}).get("width", 0) > 300]
    if not shown:
        R.setdefault("home-window-misses", []).append([{k: x.get(k) for k in ("app_name", "pid", "window_id", "is_on_screen", "bounds", "title")}
                                                       for x in listed][:12])
    return max(shown, key=lambda x: x["bounds"]["width"] * x["bounds"]["height"]) if shown else None


def home_point(where="transcript"):
    w = until(home_window, 10)
    if not w:
        return None
    b = w["bounds"]
    if where == "field":
        return b["x"] + b["width"] * 0.5, b["y"] + b["height"] - 40
    return b["x"] + b["width"] * 0.5, b["y"] + b["height"] * 0.45


def draft():
    """The draft's attachment count, drops on their way and the drop highlight (`geometry`, newer builds)."""
    g = (rpc("debug.home.drive", {"action": "geometry"}) or {}).get("geometry") or {}
    if "draftAttachments" not in g:
        return {"ok": False, "error": "this build reports no draft"}
    return {"ok": True, "attachments": int(g["draftAttachments"]), "pending": int(g.get("dropPending", 0)),
            "highlighted": g.get("dropHighlighted") == 1}


def rows():
    r = rpc("debug.home.drive", {"action": "rows"}) or {}
    return [(x.get("kind"), x.get("key"), x.get("outgoing")) for x in r.get("rows") or []]


def run_case(name, source_pid, src_point, where="transcript", cleanup=None, refront=True):
    case = {"where": where}
    R["cases"][name] = case
    try:
        dst = home_point(where)
        if not src_point or not dst:
            case["error"] = "not located: source %s, Home %s" % (src_point, dst)
            return
        case["src"], case["dst"] = src_point, dst
        # Home's window above every other app's window, then the source's window (on the left half) above it.
        hw = home_window()
        if hw and refront:
            front(hw["pid"])
        if source_pid:
            front(source_pid)
        before_rows = rows()
        shot = os.path.join(opts.out, f"{name}-hover.png")
        t0 = time.time()
        held = drag(src_point, dst, during=lambda: {"draft": draft(), "snapshot": rpc("debug.window_snapshot", {"kind": "main", "path": shot}, 20)})
        case["hover"] = held
        case["drop_s"] = round(time.time() - t0, 2)
        # The draft after the drop: its attachments once prepared (newer builds; an older build answers
        # no draft, so this waits out the 15 s and the send below says what attached).
        want = 5 if name.startswith("finder-multi") else 1
        settled = until(lambda: (d := draft()) and isinstance(d, dict) and d.get("ok") and not d.get("pending")
                        and (d.get("attachments") or 0) >= want and d, 15)
        case["draft"] = settled or draft()
        rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, f"{name}-after.png")}, 20)
        sent = rpc("debug.home.drive", {"action": "send"})
        case["send"] = sent
        until(lambda: len(rows()) > len(before_rows), 6)
        after_rows = rows()
        case["new_rows"] = [r for r in after_rows if r not in before_rows]
        case["new_outgoing_attachment_rows"] = [r for r in case["new_rows"] if r[2] and r[0] not in ("text", "status", "typing")]
    except Exception as error:  # a case never stops the run
        case["exception"] = repr(error)
    finally:
        if cleanup:
            try:
                cleanup()
            except Exception as error:
                case["cleanup_exception"] = repr(error)
        say(name, json.dumps({k: case.get(k) for k in ("error", "draft", "send", "new_outgoing_attachment_rows", "exception")}, default=str)[:900])
        save()


def finder_window(folder):
    """The Finder window of the job's folder `folder`, framed on the left half (waits for the frame:
    an icon located before the resize lands moves with the relayout)."""
    for stale in [x for x in windows() if (x.get("app_name") or "") == "Finder" and (x.get("title") or "").startswith("finder-")]:
        close_window(stale)  # the job's own earlier folders (their windows can cover the next icon)
    subprocess.run(["open", "-a", "Finder", os.path.join(SRC, folder)])
    w = until(lambda: window("Finder", folder), 10)
    if not w:
        return None
    frame(w)

    def framed():
        x = window("Finder", folder)
        b = (x or {}).get("bounds") or {}
        return x if x and abs(b.get("x", -99) - SOURCE_FRAME["x"]) < 3 and abs(b.get("width", 0) - SOURCE_FRAME["width"]) < 3 else None
    return until(framed, 5) or window("Finder", folder) or w


def finder_case(ext):
    d = os.path.join(SRC, f"finder-{ext}")
    if not os.path.isdir(d):
        R["cases"][f"finder-{ext}"] = {"error": "no source file"}; return
    w = finder_window(f"finder-{ext}")
    if not w:
        R["cases"][f"finder-{ext}"] = {"error": "no Finder window"}; return
    name = "hidp-pic.png" if ext == "multi" else f"hidp-pic.{ext}"
    point, how = until(lambda: (r := element_point(w, name)) and r[0] and r, 10) or (None, None)
    R["setup"][f"finder-{ext}-locate"] = how
    if point and ext == "multi":
        front(w["pid"])
        click(*point)
        if window("Finder", f"finder-{ext}"):
            key(0, CMD)  # Cmd+A: every file in the folder (Finder is in front: the click went there)
    def cleanup():
        close_window(window("Finder", f"finder-{ext}"))
    run_case(f"finder-{ext}", w["pid"], point, cleanup=cleanup)


def screenshot_case():
    desktop = os.path.join(HOME, "Desktop")
    before = set(glob.glob(os.path.join(desktop, "Screenshot*")))
    hw = home_window()
    if hw:
        front(hw["pid"])  # before the shortcut: the thumbnail lives about 5 s
    key(20, CMD | SHIFT)  # Cmd+Shift+3: the whole screen, with the floating thumbnail
    # The floating thumbnail is a panel above layer 0 (list_windows does not list it): it sits at the
    # bottom right of the main screen, about 20 pt in, about 200 x 130 pt, for about 5 s. Wait for the file
    # (written when the thumbnail shows), then drag from the thumbnail's middle at once.
    until(lambda: set(glob.glob(os.path.join(desktop, "Screenshot*"))) - before, 8, 0.1)
    size = cua("get_screen_size", {})
    width = size.get("width") or (size.get("structuredContent") or {}).get("width") or 1512
    height = size.get("height") or (size.get("structuredContent") or {}).get("height") or 982
    point = (width - 20 - 100, height - 20 - 65)
    R["setup"]["screenshot-point"] = {"screen": [width, height], "point": point,
                                      "file": sorted(set(glob.glob(os.path.join(desktop, "Screenshot*"))) - before)}

    def cleanup():
        for path in set(glob.glob(os.path.join(desktop, "Screenshot*"))) - before:
            os.remove(path)
    run_case("screenshot", None, point, cleanup=cleanup, refront=False)


def chrome_case(url):
    profile = os.path.join(SRC, "chrome-profile")
    subprocess.run(["open", "-na", "Google Chrome", "--args", f"--user-data-dir={profile}", "--no-first-run",
                    "--no-default-browser-check", "--window-position=0,60", "--window-size=720,760", "--new-window", url])
    w = until(lambda: window("Chrome", "hidp page"), 20)
    if w:
        frame(w)
        w = window("Chrome", "hidp page") or w

    def cleanup():
        # The job's own profile instance quits itself (chrome://quit); no other Chrome is touched.
        subprocess.run(["open", "-na", "Google Chrome", "--args", f"--user-data-dir={profile}", "chrome://quit"])
    x, y = center(w) if w else (None, None)
    run_case("chrome", w["pid"] if w else None, (x, y + 50) if w else None, cleanup=cleanup)


def safari_case(url):
    old = window("Safari")
    subprocess.run(["open", "-a", "Safari", url])
    w = until(lambda: window("Safari", "hidp page"), 20)
    original = dict(w["bounds"]) if w else None
    if w:
        frame(w)
        w = window("Safari", "hidp page") or w

    def cleanup():
        sw = window("Safari", "hidp page")
        if sw and not old:
            close_window(sw)  # the job opened this window
        elif sw and original:
            # The tab opened in an existing window: it stays (its window's other tabs are not the job's).
            frame(sw, {"x": original["x"], "y": original["y"], "width": original["width"], "height": original["height"]})
    x, y = center(w) if w else (None, None)
    R["setup"]["safari-had-window"] = bool(old)
    run_case("safari", w["pid"] if w else None, (x, y + 50) if w else None, cleanup=cleanup)


def preview_case():
    path = os.path.join(SRC, "preview-src.png")
    shutil.copy(os.path.join(SRC, "hidp-pic.png"), path)
    subprocess.run(["open", "-a", "Preview", path])
    w = until(lambda: window("Preview", "preview-src"), 15)
    if w:
        frame(w)
        w = window("Preview", "preview-src") or w
        cua("bring_to_front", {"pid": w["pid"]})
        key(0, CMD)  # Select All: the drag carries the selection's picture

    def cleanup():
        close_window(window("Preview", "preview-src"))
    x, y = center(w) if w else (None, None)
    run_case("preview", w["pid"] if w else None, (x, y + 20) if w else None, cleanup=cleanup)


def cmux_browser_case(url):
    """A cmux browser tab in a second window of the tagged app, on the left half."""
    tries = {}
    import uuid
    tries["newWindow"] = rpc("action.run", {"action": "newWindow", "args": {}, "wait": True, "focus": True, "origin": "script",
                                            "idempotency_key": f"mutation_{uuid.uuid4().hex}"}, 60)
    created = ((tries["newWindow"] or {}).get("created") or [None])[0] if isinstance(tries["newWindow"], dict) else None
    params = {"url": url, "focus": True, "idempotency_key": f"mutation_{uuid.uuid4().hex}"}
    if created:
        params["workspace_id"] = created  # the new window's workspace, not the Home window's
    tries["open"] = rpc("browser.open_split", params, 40)
    R["setup"]["cmux-browser"] = tries
    ours = lambda x: x.get("pid") == APP_PID[0] or (x.get("app_name") or "") == f"cmux DEV {TAG}"
    w = until(lambda: next((x for x in windows() if ours(x) and "hidp page" in (x.get("title") or "")), None), 15)
    if not w:
        # The browser window's title is the workspace's: the newest app window that is not the Home window.
        mine = [x for x in windows() if ours(x) and x.get("is_on_screen") and (x.get("bounds") or {}).get("width", 0) > 300
                and x.get("window_id") not in HOME_WID]
        w = mine[0] if mine else None
    if w:
        frame(w)
        w = next((x for x in windows() if x.get("window_id") == w["window_id"]), w)
    x, y = center(w) if w else (None, None)
    run_case("cmux-browser", None, (x, y + 60) if w else None, cleanup=lambda: close_window(w) if w else None)


cases = [c for c in opts.only.split(",") if c] or ["finder-png", "finder-jpg", "finder-heic", "finder-gif", "finder-pdf", "finder-multi",
                                                   "finder-png@field", "screenshot", "chrome", "safari", "preview", "cmux-browser"]
make_sources()
server, url = serve()
R["setup"]["url"] = url
if os.path.exists(SOCK):
    os.unlink(SOCK)
env = {"HOME": HOME, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SHELL": "/bin/zsh",
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "0", "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(map(str, APP_FRAME)),
       "CMUX_DEV_BACKEND_MODE": "local", "CMUX_NEXT_CLASSIC_HOME": "1", "ACPMUX_AGENT_LAUNCH": "deny", "NX_REMOTE": "1"}
proc = subprocess.Popen([os.path.join(APP, "Contents/MacOS/cmux DEV")], env=env, cwd=opts.out, stdin=subprocess.DEVNULL,
                        stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
APP_PID[0] = proc.pid
code = 1
try:
    up = until(lambda: isinstance(r := rpc("debug.home"), dict) and "classic" in r and r, 120)
    R["setup"]["home"] = {k: up.get(k) for k in ("classic", "available")} if up else None
    inbox = until(lambda: (r := rpc("debug.home.api", {"call": "inbox"})) and isinstance(r, dict) and "conversations" in r, 180)
    R["setup"]["fixture"] = rpc("debug.home_native_fixture.open", {"new": True})
    R["setup"]["texts"] = bool(until(lambda: (rpc("debug.home.drive", {"action": "texts"}) or {}).get("texts"), 60))
    R["setup"]["draft-api"] = draft()
    hw = until(home_window, 20)
    if hw:
        HOME_WID.append(hw["window_id"])
    R["setup"]["home-window"] = hw
    for case in cases:
        if case.startswith("finder-"):
            ext, _, where = case[len("finder-"):].partition("@")
            if where:
                # the same file, dropped on the message box itself
                w = finder_window(f"finder-{ext}")
                point = (element_point(w, f"hidp-pic.{ext}")[0] if w else None)

                def cleanup(ext=ext):
                    close_window(window("Finder", f"finder-{ext}"))
                run_case(case, w["pid"] if w else None, point, where=where, cleanup=cleanup)
            else:
                finder_case(ext)
        elif case == "screenshot":
            screenshot_case()
        elif case == "chrome":
            chrome_case(url)
        elif case == "safari":
            safari_case(url)
        elif case == "preview":
            preview_case()
        elif case == "cmux-browser":
            cmux_browser_case(url)
    code = 0
finally:
    save()
    server.shutdown()
    if STOP:
        subprocess.run(["bash", "-c", STOP], timeout=120)
    say(json.dumps({k: {"draft": (v.get("draft") or {}).get("attachments") if isinstance(v.get("draft"), dict) else None,
                        "rows": v.get("new_outgoing_attachment_rows"), "error": v.get("error")} for k, v in R["cases"].items()}, default=str))
sys.exit(code)

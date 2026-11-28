#!/usr/bin/env python3
"""Live check: Chromium popup widgets in a local Chromium tab take real mouse and keyboard input
(cx-d0d.66).

  scripts/cmux-next/chromium-popups-live.py --tag <tag> [--out DIR] [--app PATH]

Launches the tagged app (activated: real input needs the front app), opens a local page in a
Chromium tab and drives Chromium's popup widgets with REAL input through cua-driver: clicks
and pointer moves at screen positions (scope desktop, the window server routes them) and HID
key presses in the app (`debug.key` to the page). No JavaScript click. Checks:

  1. <datalist>: a real click on the first suggestion fills the input;
  2. <datalist>: the real pointer moved over the second suggestion, then Return, fills it (hover);
  3. <datalist>: Down keys and Return fill a suggestion (keyboard; keys go in the app, `debug.key`);
  4. <select>: a real click on the third item of the popup selects it;
  5. autocomplete (Chromium's form history, the same popup as autofill): after one real
     submission, a real click on the saved entry fills the field.

Each popup is found by its window (CGWindowList of the app's process: the popup is a separate
window above the page), and its screen is saved with cua-driver's desktop capture. The page
reads its values back (browser.page.eval). GUI host with cua-driver only (cmux-lawrence-2).
The app is quit and the tag's daemons stopped at the end. Exits 1 when a check fails.
"""
import argparse, base64, functools, glob, http.server, json, os, plistlib, socket, subprocess, sys, tempfile, threading, time
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="chromium-popups-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--idle-cpu", type=float, default=0,
                    help="instead of the popup checks: open 3 Chromium tabs on the static page, settle 20 s, and "
                         "measure the app's and its helpers' CPU over this many seconds (ps cputime)")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
CUA = os.path.expanduser("~/.local/bin/cua-driver")
OPTIONS = ["alpha", "bravo", "charlie"]
SAVED = "proof@example.com"
failures = []

PAGE = """<!doctype html><title>popups</title>
<style>body{font:16px -apple-system;margin:360px 24px 24px} input,select{font-size:16px;width:280px;margin:14px 0;display:block}
button{font-size:14px}</style>
<form id=f action="/done" method=get>
<input id=auto name=email autocomplete=email placeholder="email"><button>Send</button>
</form>
<form onsubmit="return false">
<input id=list list=opts placeholder="datalist" autocomplete=off>
<datalist id=opts><option value=alpha><option value=bravo><option value=charlie></datalist>
<select id=sel><option>one</option><option>two</option><option>three</option></select>
</form>"""

CGWIN = r"""
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var out: [[String: Any]] = []
for w in list {  // front to back
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    out.append(["id": w[kCGWindowNumber as String] as? Int ?? 0, "layer": w[kCGWindowLayer as String] as? Int ?? 0,
                "pid": Int(w[kCGWindowOwnerPID as String] as? Int32 ?? 0), "owner": w[kCGWindowOwnerName as String] as? String ?? "",
                "x": b["X"] as? Double ?? 0, "y": b["Y"] as? Double ?? 0,
                "w": b["Width"] as? Double ?? 0, "h": b["Height"] as? Double ?? 0])
}
print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
"""


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


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
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    return None


def wait_for(predicate, what, seconds=20):
    value = quiet_wait(predicate, seconds)
    check(bool(value), what)
    return value


def cua(tool, params):
    try:
        out = subprocess.run([CUA, "call", tool, json.dumps(params)], capture_output=True, text=True, timeout=60).stdout
        return json.loads(out)
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        return {"error": str(error)}


def js(expression):
    reply = rpc("browser.page.eval", {"script": expression}) or {}
    return reply.get("value") if isinstance(reply, dict) else None


def cg_all():
    """Every on-screen window, front to back (CGWindowList, top-left points)."""
    out = subprocess.run(["swift", CGWIN_FILE], capture_output=True, text=True, timeout=120).stdout
    try:
        return json.loads(out)
    except ValueError:
        return []


def cg_windows():
    return [w for w in cg_all() if w.get("pid") == app.pid]


def front_owner(point):
    """The owner of the frontmost window under `point` (layer > 25 is the menu bar, Dock and alerts)."""
    x, y = point
    for w in cg_all():
        if w.get("owner") in ("Notification Center", "Window Server"):
            continue  # full-screen transparent windows that pass clicks through
        if w["w"] > 0 and w["x"] <= x < w["x"] + w["w"] and w["y"] <= y < w["y"] + w["h"] and w["layer"] < 1000:
            return w
    return None


def raise_app():
    cua("bring_to_front", {"pid": app.pid})
    if WINDOW_ID:
        rpc("debug.window.focus", {"window": WINDOW_ID})
    time.sleep(0.6)


def page_origin():
    """The page's top-left on screen, in points (top-left origin)."""
    geo = js("JSON.stringify([window.screenX, window.screenY, window.outerHeight - window.innerHeight])")
    x, y, top = json.loads(geo) if geo else (0, 0, 0)
    return x, y + top


def element_center(element_id):
    rect = js(f"JSON.stringify(document.getElementById('{element_id}').getBoundingClientRect())")
    r = json.loads(rect) if rect else {"x": 0, "y": 0, "width": 0, "height": 0}
    ox, oy = page_origin()
    return ox + r["x"] + r["width"] / 2, oy + r["y"] + r["height"] / 2


def app_active():
    return bool((rpc("debug.focus") or {}).get("app_active"))


def real_click(point):
    x, y = point
    # A click on an inactive app's window only activates it (another GUI job on the host may have
    # activated its own app): the app must be active before every click.
    if not app_active():
        cua("bring_to_front", {"pid": app.pid})
        if not quiet_wait(app_active, 3):
            print(f"note: the app is not active before the click at ({x:.0f}, {y:.0f})", flush=True)
            OCCLUDED.append(f"({x:.0f}, {y:.0f}) with the app inactive")
    top = front_owner(point)
    if top and top.get("pid") != app.pid:
        print(f"note: ({x:.0f}, {y:.0f}) is under {top.get('owner')} (pid {top.get('pid')}); raising the app", flush=True)
        raise_app()
        top = front_owner(point)
        if top and top.get("pid") != app.pid:
            OCCLUDED.append(f"({x:.0f}, {y:.0f}) under {top.get('owner')}")
    reply = cua("click", {"x": round(x * SCALE), "y": round(y * SCALE), "scope": "desktop"})
    print(f"real click at ({x:.0f}, {y:.0f}) pt on window {top and top.get('id')} ({top and top.get('owner')}):",
          (reply.get("summary") or json.dumps(reply))[:120], flush=True)
    time.sleep(0.3)
    mice = [e for e in ((rpc("debug.journal", {"last": 12}) or {}).get("entries") or []) if "mouse" in json.dumps(e)]
    print("  journal (mouse):", json.dumps(mice[-2:])[:400], flush=True)


def real_move(point):
    x, y = point
    cua("move_cursor", {"x": round(x * SCALE), "y": round(y * SCALE), "scope": "desktop"})


def page_key(key, modifiers=None):
    """A key-down delivered in the app to the page window (`debug.key`, target page): the keyboard
    path. Clicks stay real input."""
    reply = rpc("debug.key", {"key": key, "modifiers": modifiers or [], "target": "page"})
    if isinstance(reply, dict) and reply.get("error"):
        print("debug.key", key, json.dumps(reply)[:200], flush=True)


def capture(name):
    path = os.path.join(opts.out, f"{name}.png")
    reply = cua("get_desktop_state", {"screenshot_out_file": path})
    print("capture", name, "ok" if os.path.exists(path) else json.dumps(reply)[:160], flush=True)


def popup_window(before):
    """A new window of the app's process above the page: the popup (CGWindowList, top-left points)."""
    fresh = [w for w in cg_windows() if w["id"] not in before and w["h"] > 10 and w["w"] > 40]
    fresh.sort(key=lambda w: -w["layer"])
    return fresh[0] if fresh else None


def rows_of(window, count, pad=4.0):
    """Centers of `count` equal rows inside `window`, in screen points."""
    inner = window["h"] - 2 * pad
    # Near the left edge: other apps' windows on a shared host tend to cover the right side.
    return [(window["x"] + min(40.0, window["w"] / 3), window["y"] + pad + inner * (i + 0.5) / count) for i in range(count)]


def diagnose(name):
    report = {"window_list": rpc("debug.window_list"), "cg": cg_windows()}
    with open(os.path.join(opts.out, f"{name}-windows.json"), "w") as f:
        json.dump(report, f, indent=1)
    for w in (report["window_list"] or {}).get("windows", []):
        if w.get("visible"):
            print("  window", {k: w.get(k) for k in ("id", "class", "level", "ignores_mouse", "key", "parent", "frame")}, flush=True)


def open_popup(element_id, opener):
    """Opens the popup of `element_id` with real input; the popup window or None."""
    before = {w["id"] for w in cg_windows()}
    opener()
    popup = quiet_wait(lambda: popup_window(before), 8)
    if not popup:  # a first click right after the page loads can only focus the field: once more
        print(f"note: no popup for {element_id} yet; opening it again", flush=True)
        opener()
        popup = quiet_wait(lambda: popup_window(before), 8)
    return popup


def reset(element_id, value=""):
    js(f"(() => {{ const e = document.getElementById('{element_id}'); e.value = {json.dumps(value)}; e.blur(); return true }})()")
    time.sleep(0.3)


def value(element_id):
    return js(f"document.getElementById('{element_id}').value")


def bundle_cpu():
    """{pid: (cpu seconds, command)} of every process whose executable is inside the app bundle."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,time=,command="], capture_output=True, text=True).stdout
    roots = (os.path.realpath(APP), os.path.abspath(APP))
    found = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3 or not parts[2].startswith(roots):
            continue
        clock = parts[1].replace("-", ":").split(":")  # [[dd-]hh:]mm:ss.cc
        seconds = 0.0
        for field in clock:
            seconds = seconds * 60 + float(field)
        found[int(parts[0])] = (seconds, os.path.basename(parts[2].split(" --")[0]))
    return found


def measure_idle_cpu(url, seconds):
    for _ in range(3):
        rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True})
        time.sleep(3)
    time.sleep(20)  # settle: page loads, warm-up timers
    before, start = bundle_cpu(), time.monotonic()
    time.sleep(seconds)  # the measurement window (wall clock), not app synchronization
    after, wall = bundle_cpu(), time.monotonic() - start
    rows, total = [], 0.0
    for pid, (cpu, name) in after.items():
        used = cpu - before.get(pid, (0.0, name))[0]
        total += used
        rows.append({"pid": pid, "process": name, "cpu_percent": round(100 * used / wall, 3)})
    rows.sort(key=lambda r: -r["cpu_percent"])
    result = {"seconds": round(wall, 1), "total_cpu_percent": round(100 * total / wall, 3), "processes": rows}
    with open(os.path.join(opts.out, "idle-cpu.json"), "w") as f:
        json.dump(result, f, indent=1)
    print(f"idle CPU over {wall:.0f} s with 3 Chromium tabs: total {result['total_cpu_percent']}%", flush=True)
    for row in rows[:8]:
        print("  ", row, flush=True)


def serve():
    root = tempfile.mkdtemp(prefix="popups-page-")
    for name in ("index.html", "done"):
        with open(os.path.join(root, name), "w") as f:
            f.write(PAGE if name == "index.html" else "<!doctype html><title>done</title>submitted")

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith("/done"):
                self.path = "/done"
            return super().do_GET()

        def guess_type(self, path):
            return "text/html"

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=root))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/index.html"


APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
if not os.path.exists(CUA):
    sys.exit(f"no {CUA}: run on a GUI host with cua-driver")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
SCRATCH = tempfile.mkdtemp(prefix=f"chromium-popups-{opts.tag}-")
CGWIN_FILE = os.path.join(SCRATCH, "cgwin.swift")
with open(CGWIN_FILE, "w") as f:
    f.write(CGWIN)
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
SCALE = float(cua("get_screen_size", {}).get("scale_factor") or 2.0)
teardown = TagTeardown(APP)
teardown.install()
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation",
    "CMUX_NEXT_TEST_WINDOW_SCREEN": "main", "CMUX_NEXT_CONFIG_FILE": CONFIG,
    "CMUX_NEXT_TEST_WINDOW_FRAME": "60,60,1100,760"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, scale {SCALE}, out {opts.out}", flush=True)
MAIN_WINDOW = None
PAGE_WINDOW = None
WINDOW_ID = None
OCCLUDED = []
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), "app socket", 180)
    if not quiet_wait(lambda: (rpc("debug.surfaces") or {}).get("windows"), 30):
        rpc("action.run", {"action": "newWindow", "origin": "script"})

    def focused_pane():
        for window in (rpc("debug.surfaces") or {}).get("windows") or []:
            for pane in window.get("panes") or []:
                if pane.get("focused"):
                    return pane
        return None

    # A launch can open on Home with no workspace: make one, so openBrowser has a pane.
    if not quiet_wait(focused_pane, 15):
        print("run newTab", rpc("action.run", {"action": "newTab", "origin": "script", "focus": True}), flush=True)
    wait_for(focused_pane, "a focused pane", 60)
    url = serve()
    if opts.idle_cpu:
        measure_idle_cpu(url, opts.idle_cpu)
        raise SystemExit(0)
    reply = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True})
    print("openBrowser.chromium", json.dumps(reply)[:200], flush=True)
    wait_for(lambda: js("document.title") == "popups", "the local page loads in a Chromium tab", 90)
    found = [w for w in (cua("list_windows", {"pid": app.pid}).get("windows") or []) if w.get("title") == "cmux"]
    MAIN_WINDOW = found[0]["window_id"] if found else None
    WINDOW_ID = (((rpc("debug.focus") or {}).get("windows") or [{}])[0]).get("id")
    pages = [w for w in ((rpc("debug.window_list") or {}).get("windows") or []) if w.get("class") == "CefNSWindow" and w.get("visible")]
    PAGE_WINDOW = max(pages, key=lambda w: w["frame"]["width"] * w["frame"]["height"])["id"] if pages else None
    print("windows: main", MAIN_WINDOW, "page", PAGE_WINDOW, "state id", WINDOW_ID, flush=True)
    raise_app()
    time.sleep(1.0)
    print("snapshot", rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "0-page.png")}), flush=True)
    print("page origin", page_origin(), "datalist input at", element_center("list"), flush=True)

    # 1. <datalist>: a real click on the first suggestion.
    def open_datalist():
        real_click(element_center("list"))
        time.sleep(0.4)
        page_key("down")

    popup = open_popup("list", open_datalist)
    check(bool(popup), f"the datalist popup opens as its own window: {popup}")
    if popup:
        capture("1-datalist-open")
        diagnose("1-datalist-open")
        real_click(rows_of(popup, len(OPTIONS))[0])
        filled = quiet_wait(lambda: value("list") or None, 4)
        check(filled == OPTIONS[0], f"a real click on the first datalist row fills it: {filled!r}")
        capture("1-datalist-clicked")

    # 2. Hover, then Return.
    reset("list")
    popup = open_popup("list", open_datalist)
    if popup:
        real_move(rows_of(popup, len(OPTIONS))[1])
        time.sleep(0.6)
        page_key("return")
        filled = quiet_wait(lambda: value("list") or None, 4)
        check(filled == OPTIONS[1], f"the pointer over the second row, then Return, fills it: {filled!r}")
    else:
        check(False, "the datalist popup opens again for the hover check")

    # 3. Keyboard only.
    reset("list")
    popup = open_popup("list", open_datalist)
    if popup:
        real_move((popup["x"] + popup["w"] + 200, popup["y"] + popup["h"] + 200))  # the pointer off the popup
        for _ in range(2):
            page_key("down")
            time.sleep(0.2)
        page_key("return")
        filled = quiet_wait(lambda: value("list") or None, 4)
        check(filled in OPTIONS, f"Down keys and Return fill a datalist row: {filled!r}")
    else:
        check(False, "the datalist popup opens again for the keyboard check")

    # 4. <select>: a real click on the third item.
    reset("list")
    popup = open_popup("sel", lambda: real_click(element_center("sel")))
    check(bool(popup), f"the select popup opens: {popup}")
    if popup:
        capture("4-select-open")
        diagnose("4-select-open")
        real_click(rows_of(popup, 3, pad=5.0)[2])
        chosen = quiet_wait(lambda: (lambda v: v if v and v != "one" else None)(value("sel")), 4)
        check(chosen == "three", f"a real click on the third select item selects it: {chosen!r}")

    # 5. Autocomplete: one submission typed with keys saves the entry (setup: the field takes focus
    #    from the page, so a pointer elsewhere on a shared host cannot steal it), then a real click
    #    on the saved entry fills the field.
    js("(() => { document.getElementById('auto').focus(); return true })()")
    time.sleep(0.4)
    for character in SAVED:
        page_key(character)
    typed = value("auto")
    print("typed into the autofill field:", repr(typed), flush=True)
    page_key("return")
    wait_for(lambda: js("document.title") == "done", "the form submits", 20)
    rpc("browser.page.navigate", {"url": url})
    wait_for(lambda: js("document.title") == "popups", "the page loads again", 30)

    def open_autocomplete():
        real_click(element_center("auto"))
        time.sleep(0.4)
        page_key("down")

    popup = open_popup("auto", open_autocomplete)
    check(bool(popup), f"the autocomplete popup opens: {popup}")
    if popup:
        capture("5-autocomplete-open")
        diagnose("5-autocomplete-open")
        real_click(rows_of(popup, 1)[0])
        filled = quiet_wait(lambda: value("auto") or None, 4)
        check(filled == typed and bool(typed), f"a real click on the saved entry fills the field: {filled!r}")
finally:
    rpc("action.run", {"action": "quitEndSessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
    teardown.end()

if OCCLUDED:
    print("note: real clicks landed under other apps' windows:", OCCLUDED, flush=True)
print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)

#!/usr/bin/env python3
"""Chromium's native UI on a page in a real window (p03-rendering-046): one row per kind, with a capture.

Launches a tagged cmux-next app (scratch config, no activation), opens a probe page in a Chromium tab and drives
each kind of native UI with real HID events (CGEventPost; the pointer moves on the fleet host). The row names are
`CEFNativeWidget.checkName` (CEFNativeWidget.swift), in its order; its `route` says where each kind should show
on a page attached to its host view (Track B):

  select         an HID click opens the <select> menu (WebMenuRunner's NSMenu in the page's view); Down, Return
                 pick the second option: the page's value changes
  context-menu   an HID right click: the page sees `contextmenu` and cmux's menu shows (capture); Escape
  autofill       a <datalist> input: typing opens Chromium's dropdown (an autofill popup, a views::Widget of the
                 page window); Down, Return fill it, and a page window shows for it: a visible content child
                 window of the cmux window while it is open, or debug.cef page_window_widget_shows_by_kind["2"]
                 grows (the per-widget fallback, whose fork side is not written yet: this row fails until it is)
  color-picker   an HID click on <input type=color> shows the shared NSColorPanel (debug.window_list)
  date-picker    a button calls showPicker() on <input type=date>: a new visible RenderWidgetPopupWindow shows
                 (Chromium's PopupWindowMac, debug.window_list); Escape closes it
  print-preview  a button calls window.print(): Chromium's print preview shows, as a new visible
                 NativeWidgetMacNSWindow (a views dialog) or a page-window widget of kind 5
                 (page_window_widget_shows_by_kind["5"]); a system print panel does not count. Escape
  ime            Option-E then E on the US layout (a dead key: marked text, then commit): the input reads "é" and
                 the page saw compositionstart (the page's view is the NSTextInputClient; cmux adds none)
  file-drop-in   PERSON: the run prints a prompt and waits (--drop-wait, 60 s) for a person to drag a file from
                 Finder onto the drop zone; the zone lists its name (CEFFileDragRelay on the host view, its scope
                 rules unchanged). It fails on timeout
  link-drag-out  an HID drag of the page's link: the page sees dragstart and dragend (the drag session ran)
  accessibility  ax-tour.sh --dump of the app finds the page's button by its accessible name (AX turns on for it)
  tooltip        the pointer rests on an element with a title: a tooltip window of the app shows (debug.window_list)
  cursor         REVIEW: the pointer over the `cursor: pointer` box; the capture (with the cursor) shows a hand

Before the tour, the `attached` row checks DC8b on the probe page: no visible content child window of the cmux
window (debug.layers `child_windows`, role `content`), so the page is attached to its host view (Track B, 044 and
045). Also recorded (`facts`): those child windows before and after the tour and the debug.cef tracker counters.
Each row records `observed_route` where the run can tell it (`CEFNativeWidgetRoute`: chromiumView, host,
pageWindow): the value that sets `CEFNativeWidget.route`.

A REVIEW row (context-menu, cursor) is `pending-review` after the run, and the run fails: a person looks at its
capture and confirms it in a second step, so a run never claims what nobody saw:
  cef-native-ui-live.py --confirm OUT/native-ui.json --rows context-menu,cursor
sets `checked_by_person` on those rows and passes each whose automatic part passed. Each row writes
OUT/native-ui-<row>.png (a screencapture of the window with the cursor) and OUT/native-ui.json holds every row.

Run on a GUI fleet host with input, never a laptop:
  nx-remote --needs gui --needs input --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/cef-native-ui-live.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS"
"""
import argparse, ctypes, glob, json, os, pathlib, signal, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app")
parser.add_argument("--tag")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--only", default="", help="comma-separated rows to run (default: all)")
parser.add_argument("--drop-wait", type=float, default=60, help="seconds file-drop-in waits for a person's drop")
parser.add_argument("--keep", action="store_true", help="leave the app running")
parser.add_argument("--confirm", metavar="NATIVE_UI_JSON",
                    help="after a person reviewed the captures: mark --rows as checked in that run's record, then exit")
parser.add_argument("--rows", default="", help="with --confirm: comma-separated REVIEW rows the person checked")
opts = parser.parse_args()


def confirm(path, names):
    """The second step of a REVIEW row: a person looked at that run's capture, so the row is checked now."""
    record = json.load(open(path))
    reviewable = {r["check"] for r in record["rows"] if r.get("review")}
    if not names or not names <= reviewable:
        sys.exit(f"--rows must name REVIEW rows of {path} ({sorted(reviewable)}), got {sorted(names)}")
    for r in record["rows"]:
        if r["check"] in names:
            r["observed"]["checked_by_person"] = True
            r["ok"] = bool(r["observed"].get("automatic_ok"))
            r["status"] = "pass" if r["ok"] else "fail"
    json.dump(record, open(path, "w"), indent=2)
    print(json.dumps([{k: r.get(k) for k in ("check", "status")} for r in record["rows"]]))
    sys.exit(0 if all(r["ok"] for r in record["rows"]) else 1)


if opts.confirm:
    confirm(opts.confirm, {name for name in opts.rows.split(",") if name})
if not opts.app or not opts.tag:
    parser.error("--app and --tag are required for a run")

TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = tempfile.mkdtemp(prefix=f"cef-native-ui-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
WINDOW = (80, 80, 1400, 900)
ORDER = ["select", "context-menu", "autofill", "color-picker", "date-picker", "print-preview", "ime",
         "file-drop-in", "link-drag-out", "accessibility", "tooltip", "cursor"]
ONLY = {name for name in opts.only.split(",") if name}
ROWS, TAB, FACTS = [], {}, {}

# Every control sits at a fixed fraction of the page (fx, fy), so the HID points need no layout read.
PAGE = """<!doctype html><meta charset=utf-8><title>native ui probe</title>
<style>html,body{margin:0;height:100%;font:16px system-ui;background:#f4f4f4}
.c{position:fixed;width:18%;height:44px;transform:translate(-50%,-50%);font-size:16px;box-sizing:border-box}
#drop{border:2px dashed #888;display:flex;align-items:center;justify-content:center}
#hand{cursor:pointer;background:#c8e0ff}</style>
<select id=sel class=c style="left:15%;top:15%"><option>one<option>two<option>three</select>
<input id=dl class=c list=fruits style="left:40%;top:15%" autocomplete=off>
<datalist id=fruits><option value=apple><option value=apricot></datalist>
<input id=col type=color class=c style="left:65%;top:15%">
<input id=dt type=date class=c style="left:15%;top:35%">
<button id=pick class=c style="left:40%;top:35%" onclick="dt.showPicker()">pick a date</button>
<button id=prn class=c style="left:65%;top:35%" onclick="print()">print</button>
<input id=ime class=c style="left:15%;top:55%">
<div id=drop class=c style="left:40%;top:55%;height:80px">drop a file here</div>
<a id=lnk class=c href="https://example.com/dragged" style="left:65%;top:55%">drag this link</a>
<button id=ax class=c style="left:15%;top:75%" aria-label="AX probe button">ax</button>
<div id=tip class=c title="native ui tooltip" style="left:40%;top:75%;background:#ffe">hover for a tooltip</div>
<div id=hand class=c style="left:65%;top:75%">pointer cursor</div>
<script>window.__events=[];
for(const t of ['contextmenu','compositionstart','compositionend','dragstart','dragend'])
addEventListener(t,e=>window.__events.push(t),true);
drop.addEventListener('dragover',e=>e.preventDefault());
drop.addEventListener('drop',e=>{e.preventDefault();drop.textContent=[...e.dataTransfer.files].map(f=>f.name).join(',')||'none'});
</script>"""
POINTS = {"select": (0.15, 0.15), "datalist": (0.40, 0.15), "color": (0.65, 0.15), "pick": (0.40, 0.35),
          "print": (0.65, 0.35), "ime": (0.15, 0.55), "drop": (0.40, 0.55), "link": (0.65, 0.55),
          "tooltip": (0.40, 0.75), "hand": (0.65, 0.75), "blank": (0.90, 0.92)}


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
CG.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
CG.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
CG.CGMainDisplayID.restype = ctypes.c_uint32
CG.CGDisplayBounds.restype = CGRect
CG.CGDisplayBounds.argtypes = [ctypes.c_uint32]
CF.CFRelease.argtypes = [ctypes.c_void_p]
KEYCODES = {"a": 0, "e": 14, "p": 35, "return": 36, "escape": 53, "down": 125}
OPTION = 0x80000  # kCGEventFlagMaskAlternate


def post(event):
    CG.CGEventPost(0, event)  # kCGHIDEventTap
    CF.CFRelease(event)
    time.sleep(0.02)  # test harness: the WindowServer delivers in order


def mouse(kind, point, button=0):
    post(CG.CGEventCreateMouseEvent(None, kind, CGPoint(*point), button))


def click(point, right=False):
    down, up = (3, 4) if right else (1, 2)
    mouse(5, point)
    mouse(down, point, 1 if right else 0)
    mouse(up, point, 1 if right else 0)


def key(name, flags=0):
    for down in (True, False):
        event = CG.CGEventCreateKeyboardEvent(None, KEYCODES[name], down)
        if flags:
            CG.CGEventSetFlags(event, flags)
        post(event)


def page_rect():
    for window in (rpc("debug.layers") or {}).get("windows") or []:
        for browser in window.get("browsers") or []:
            if browser.get("host_screen_rect"):
                return browser["host_screen_rect"]
    return None


def at(name):
    """A control of the probe in global display coordinates (top-left origin), from the page's host rect."""
    rect = page_rect()
    if not rect:
        return None
    main = CG.CGDisplayBounds(CG.CGMainDisplayID())
    fx, fy = POINTS[name]
    hx, hy, hw, hh = rect
    return hx + hw * fx, main.size.y - (hy + hh * (1 - fy))


def capture(name):
    """A screencapture of the app's window rect, with the cursor (-C), for the row's record."""
    path = os.path.join(opts.out, f"native-ui-{name}.png")
    main = CG.CGDisplayBounds(CG.CGMainDisplayID())
    x, y, w, h = WINDOW
    for window in (rpc("debug.layers") or {}).get("windows") or []:
        wx, wy, ww, wh = window.get("frame") or WINDOW
        x, y, w, h = wx, main.size.y - wy - wh, ww, wh
        break
    subprocess.run(["screencapture", "-x", "-C", "-R", f"{int(x)},{int(y)},{int(w)},{int(h)}", path],
                   capture_output=True, timeout=60)
    return path if os.path.exists(path) else None


def windows():
    return (rpc("debug.window_list") or {}).get("windows") or []


def visible_ids():
    return {w.get("id") for w in windows() if w.get("visible")}


def content_children():
    """Visible content child windows of the cmux windows (page windows ordered in; debug.layers `child_windows`)."""
    return sum(1 for window in (rpc("debug.layers") or {}).get("windows") or []
               for child in window.get("child_windows") or [] if child.get("role") == "content" and child.get("visible"))


def tracker():
    return (rpc("debug.cef") or {}).get("tracker") or {}


def widget_shows(kind):
    """Page-window widget shows of fork kind `kind` (a CEFNativeWidget raw value) so far."""
    return (tracker().get("page_window_widget_shows_by_kind") or {}).get(str(kind), 0)


def row(name, ok, observed, review=None, capture_it=True):
    """One record. A REVIEW row stays pending until `--confirm` (a person looked at this run's capture)."""
    if capture_it:
        observed = dict(observed, capture=capture(name))
    if review is not None:
        observed = dict(observed, review=review, automatic_ok=bool(ok), checked_by_person=False)
        status = "pending-review" if ok else "fail"
        ok = False
    else:
        status = "pass" if ok else "fail"
    ROWS.append({"check": name, "ok": bool(ok), "status": status, "review": review is not None, "observed": observed})
    print(f"{status.upper()} | {name} | {json.dumps(observed)[:400]}", flush=True)


def events():
    return page("window.__events.join(',')") or ""


def reset():
    key("escape")
    click(at("blank"))
    page("window.__events = []")
    time.sleep(0.3)  # test harness: a closing popup or menu ends its tracking loop


def check_select():
    click(at("select"))
    time.sleep(0.6)  # test harness: the menu opens
    shot = capture("select-open")
    key("down")
    key("return")
    value = wait(lambda: page("sel.value === 'two' ? sel.value : ''"), 3)
    row("select", value == "two", {"value": page("sel.value"), "open_capture": shot})


def check_context_menu():
    click(at("blank"), right=True)
    seen = wait(lambda: "contextmenu" in events(), 3)
    time.sleep(0.4)  # test harness: cmux's menu shows
    row("context-menu", bool(seen), {"events": events(), "observed_route": "host"},
        review="cmux's page menu shows at the pointer in the capture")
    key("escape")


def check_autofill():
    before = widget_shows(2)
    click(at("datalist"))
    time.sleep(0.3)  # test harness: focus lands in the input
    key("a")
    key("p")
    time.sleep(0.8)  # test harness: Chromium's dropdown opens
    shot = capture("autofill-open")
    during = content_children()
    shows = widget_shows(2) - before
    key("down")
    key("return")
    value = wait(lambda: page("dl.value.length > 2 ? dl.value : ''"), 3)
    page_window = during >= 1 or shows >= 1
    row("autofill", value in ("apple", "apricot") and page_window,
        {"value": page("dl.value"), "page_window_widget_shows": shows, "content_children_open": during,
         "observed_route": "pageWindow" if page_window else None, "open_capture": shot})


def check_window_opens(name, point, expect, widget_kind=None):
    """A click at `point` shows a new visible app window `expect` accepts (debug.window_list), or a page-window
    widget of fork kind `widget_kind`; the row records which one matched. Escape closes it."""
    before = visible_ids()
    shows_before = widget_shows(widget_kind) if widget_kind is not None else 0
    click(at(point))
    opened = wait(lambda: [w for w in windows() if w.get("visible") and w.get("id") not in before and expect(w)], 5)
    shows = widget_shows(widget_kind) - shows_before if widget_kind is not None else 0
    matched = "page-window-widget" if shows > 0 else (opened[0].get("class") if opened else None)
    row(name, bool(opened) or shows > 0,
        {"opened": [{k: w.get(k) for k in ("class", "kind", "parent", "level")} for w in opened or []],
         "page_window_widget_shows": shows, "matched": matched,
         "observed_route": "pageWindow" if shows > 0 else ("chromiumView" if opened else None)})
    # Escape closes the date picker and print preview; the color panel stays open (it changes no later row).
    key("escape")


def check_ime():
    click(at("ime"))
    time.sleep(0.3)  # test harness: focus lands in the input
    page("ime.value = ''; window.__events = []")
    key("e", OPTION)
    key("e")
    value = wait(lambda: page("ime.value"), 3)
    row("ime", value == "é" and "compositionstart" in events(),
        {"value": value, "events": events(), "input_source": FACTS.get("input_source")})


def check_file_drop_in():
    default = "drop a file here"
    print(f"PERSON | file-drop-in | drag a file from Finder onto '{default}' within {opts.drop_wait:.0f} s", flush=True)

    def dropped():
        text = page("drop.textContent")
        return text if text and text != default else None
    zone = wait(dropped, opts.drop_wait, 0.5)
    row("file-drop-in", bool(zone) and zone != "none",
        {"zone": zone or page("drop.textContent"), "waited_s": opts.drop_wait,
         "observed_route": "host" if zone and zone != "none" else None})


def check_link_drag_out():
    start = at("link")
    mouse(5, start)
    mouse(1, start)
    for step in range(1, 16):
        mouse(6, (start[0] - 12 * step, start[1] + 6 * step))
        time.sleep(1 / 60)  # test harness: one drag event per frame
    mouse(2, (start[0] - 180, start[1] + 90))
    seen = wait(lambda: "dragend" in events(), 3)
    row("link-drag-out", bool(seen) and "dragstart" in events(), {"events": events()})


def check_accessibility():
    dump = subprocess.run([os.path.join(HERE, "ax-tour.sh"), "--tag", TAG, "--dump"],
                          capture_output=True, text=True, timeout=180)
    found = "AX probe button" in dump.stdout
    path = os.path.join(opts.out, "native-ui-ax-dump.txt")
    open(path, "w").write(dump.stdout + dump.stderr)
    row("accessibility", found, {"dump": path, "exit": dump.returncode})


def check_tooltip():
    before = visible_ids()
    mouse(5, at("tooltip"))
    opened = wait(lambda: [w for w in windows() if w.get("visible") and w.get("id") not in before
                           and "ToolTip" in (w.get("class") or "")], 5)
    row("tooltip", bool(opened), {"opened": [w.get("class") for w in opened or []]})


def check_cursor():
    mouse(5, at("hand"))
    time.sleep(0.5)  # test harness: the cursor updates
    row("cursor", True, {"observed_route": "chromiumView"},
        review="the capture shows a pointing-hand cursor over 'pointer cursor'")


CHECKS = {
    "select": check_select,
    "context-menu": check_context_menu,
    "autofill": check_autofill,
    "color-picker": lambda: check_window_opens("color-picker", "color", lambda w: "ColorPanel" in (w.get("class") or "")),
    # Chromium's PopupWindowMac is a RenderWidgetPopupWindow (content/app_shim_remote_cocoa/popup_window_mac.mm).
    "date-picker": lambda: check_window_opens("date-picker", "pick",
                                              lambda w: "RenderWidgetPopupWindow" in (w.get("class") or "")),
    # Print preview is a views dialog (NativeWidgetMacNSWindow) or a page-window widget of kind 5, never NSPrintPanel.
    "print-preview": lambda: check_window_opens("print-preview", "print",
                                                lambda w: "NativeWidgetMacNSWindow" in (w.get("class") or ""),
                                                widget_kind=5),
    "ime": check_ime,
    "file-drop-in": check_file_drop_in,
    "link-drag-out": check_link_drag_out,
    "accessibility": check_accessibility,
    "tooltip": check_tooltip,
    "cursor": check_cursor,
}


def main():
    global SOCKET
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
           "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(str(v) for v in WINDOW)}
    os.makedirs(opts.out, exist_ok=True)
    log = open(os.path.join(opts.out, f"app-{TAG}-native-ui.log"), "a")
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
            ROWS.append({"check": "launch", "ok": False, "observed": "the app did not come up"})
            return
        time.sleep(4)  # test harness: launch work settles
        probe = os.path.join(SCRATCH, "probe.html")
        open(probe, "w").write(PAGE)
        action("openBrowser.chromium", {"url": pathlib.Path(probe).as_uri()}, timeout=120)
        if not wait(lambda: page("document.readyState === 'complete' && document.title === 'native ui probe'"), 60, 0.5):
            ROWS.append({"check": "page", "ok": False, "observed": f"the probe never loaded: {json.dumps(rpc('debug.cef'))[:300]}"})
            return
        time.sleep(1.5)  # test harness: first frames settle
        sources = subprocess.run(["defaults", "read", "com.apple.HIToolbox", "AppleCurrentKeyboardLayoutInputSourceID"],
                                 capture_output=True, text=True, timeout=10)
        FACTS["input_source"] = sources.stdout.strip() or None
        FACTS["content_children_before"] = content_children()
        FACTS["tracker_before"] = tracker()
        # DC8b: the probe page is attached to its host view (Track B): no page window ordered in.
        row("attached", FACTS["content_children_before"] == 0,
            {"content_children": FACTS["content_children_before"]}, capture_it=False)
        click(at("blank"))  # the first click may only activate the app
        time.sleep(0.3)  # test harness: activation settles
        for name in ORDER:
            if ONLY and name not in ONLY:
                continue
            reset()
            try:
                CHECKS[name]()
            except (TypeError, OSError, subprocess.SubprocessError) as error:
                row(name, False, {"error": str(error)})
        FACTS["content_children_after"] = content_children()
        FACTS["tracker_after"] = tracker()
    finally:
        if not opts.keep:
            rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
            try:
                app.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.kill(app.pid, signal.SIGKILL)
            subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                           env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
        json.dump({"tag": TAG, "rows": ROWS, "facts": FACTS}, open(os.path.join(opts.out, "native-ui.json"), "w"), indent=2)


main()
sys.exit(0 if ROWS and all(r["ok"] for r in ROWS) else 1)

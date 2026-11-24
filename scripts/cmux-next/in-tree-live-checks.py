#!/usr/bin/env python3
"""Live checks of in-tree Chromium pages in a launched tagged cmux-next app (plans/cmux-next/in-tree-pages.md).

Launches the app (no activation, automation socket, scratch config) with `CMUX_IN_TREE_PAGES` set by --in-tree, opens a
terminal beside a Chromium page and checks:

  mode       debug.cef in_tree is what --in-tree asked for (on: "on"; off: "off" or absent)
  census     (C2) debug.layers per window: no visible page child window (role content), no child-window violation, no
             overlay panel; with in-tree on every shown page is listed in page_views with widget_drawing 0; the reorder
             and divider catcher counters stay flat over --idle seconds
  focus      (C7) the page calls window.focus() and input.focus() every 20 ms and on blur; with the terminal focused, a
             40-character marker typed key by key (debug.key, the key router and the responder chain) arrives whole in
             the terminal (surface.read_text) and the page sees none of its keys
  shortcuts  (C9) with the page focused (a click in its input): the key router claims Cmd-T, Cmd-W, Cmd-D, Cmd-Shift-P
             (dry run), and real Cmd-T opens a tab, Cmd-W closes it, Cmd-Shift-P opens the palette
  two_pages  a second page in the terminal's pane: both pages show at once (in tree: both pages' views in the window),
             and a page click plus keys in each reach that page alone; two-pages*.png are the window's snapshots
  prompts    (C16) alert, confirm, prompt, an <input type=file> click and a download each show something (a dialog, a
             panel, a window, a popup or a download record) instead of being cancelled in silence
  file_after_popup
             (also with prompts) a window.open popup's <input type=file> shows its sheet on the popup window, the popup
             closes while that sheet is up, and then the opener's chooser must still work: a sheet shows, a new request
             reaches the app (debug.cef file_dialogs.received grows), Escape delivers 'cancel' to the page, and a
             second chooser does the same (other-Mac run on 6e420b7b: every later chooser of that app cancelled at once)

  reveal     the window leaves the screen for --reveal-hidden seconds and comes back, without activating the app
             (debug.page_reveal): `hide` hides the app (as a switch to another app with the window covered, the user's
             recording on 34f21f2f), `cover` orders an opaque window of the app over it; then again with a docked
             DevTools open. reveal.<mode>.layers fails when the page's compositor layers (CALayerHost context ids)
             are replaced after the window shows again: the page's compositor went away while hidden, so its view
             showed only the page's background until the new compositor's first frame (`replaced_ms`).
             reveal.<mode>.pixels samples the window's real pixels (CuaDriver window captures, the daemon's Screen
             Recording grant) from before the show to 2.5 s after: the page has a yellow block on its blue
             background, and a frame after the show with the blue background but no yellow is a background-only
             (blank) frame and fails the row. INFO when the host gives no captures.

Regression rows (in-tree-regressions.md: one per bug found in real use; each detail names its `bug` and `pass_if`), on
a layout probe page (five fixed targets, a log of the viewport every display frame and of every click) in the page's
pane beside the terminal:

  pane_fit        (13) after a wheel scroll, innerWidth/innerHeight and visualViewport equal the page view's size
                  (debug.layers page_views) within 1 pt; a page click (debug.mouse target page) and a window click
                  (debug.mouse at the window point) at each target's centre hit it, inside its rect within 1 pt, with
                  elementFromPoint == event.target. pane_fit.paint.split and .resized: in a window capture (the window
                  server's pixels) the page's magenta top band starts at the view's top and its cyan bottom band ends
                  at the view's bottom, within 2 pt, after the split and after the window went 200 pt shorter and 100
                  pt taller; pane_fit.layers.*: every layer above the page's CALayerHost is its view's size
  divider_resize  (11) a divider drag beside the page: at most 2 missed display frames, p95 within 1.5 refresh
                  intervals, the page follows during the drag (>= 10 widths) and fits the pane <= 100 ms after it settles
  window_resize   (11) the window's corner dragged out and back: the same frame budget and settle rule
  fullscreen      (12) enter and exit: no pinch scale or devicePixelRatio change in any frame, the page view never
                  larger than its start and end size or outside the window, the page fits the pane <= 100 ms after it
  pane_zoom       (14) Cmd-Shift-Return zoom and unzoom of the page's pane: area >= 1.3x, then back within 1 pt; one
                  page view, no panel or page window, the page fits <= 100 ms after the pane; pane_fit.paint.zoom and
                  .unzoom: the page's real pixels fill its view after each
  popup_float     (10) a 520 x 420 window.open popup has inner 520 x 420 within 2 pt and a window smaller than the
                  screen, with the opener windowed and in full screen
  zoom_motion     (sweep D2) two pages side by side, Cmd-Shift-Return and back with window captures: B's pane never
                  bare background (blank) during the zoom; from 300 ms A's band at its top, A never drawn inside B
  grid_resize     (sweep D5) four pages in a grid, the window 400 x 200 pt smaller in 45 steps at 60 Hz and back: in
                  every captured frame each page's top band is at its view's top; settled paint rows per page
  omnibar_narrow  (15) at pane widths 480/360/300/260 with a long URL, the omnibar text area ends before every icon
                  to its right in the bar, and the bar stays in the toolbar

Every row prints `PASS|FAIL|INFO | name | detail`; --json writes the rows and the raw readouts. Exits 0 when no row
fails. The app is quit at the end. Fleet GUI host only (debug.key needs no event-posting grant).
"""
import argparse, http.server, json, os, plistlib, signal, socket, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", default=tempfile.mkdtemp(prefix="in-tree-live-"))
parser.add_argument("--json")
parser.add_argument("--in-tree", dest="in_tree", choices=["on", "off"], default="on")
parser.add_argument("--idle", type=float, default=8.0)
parser.add_argument("--checks", default="mode,census,focus,shortcuts,prompts,file_after_popup,pane_fit,divider_resize,"
                    "window_resize,fullscreen,pane_zoom,popup_float,omnibar_narrow,zoom_motion,grid_resize,two_pages,reveal",
                    help="comma-separated; `regressions` names every row of in-tree-regressions.md (bugs 4, 9 to 15)")
parser.add_argument("--reveal-hidden", dest="reveal_hidden", type=float, default=10.0,
                    help="reveal: seconds the window stays off the screen")
parser.add_argument("--close-popup", dest="close_popup", choices=["script", "window"], default="script",
                    help="file_after_popup: the popup closes itself (window.close() from its opener) or its window closes")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
CHECKS = set(opts.checks.split(","))
if "regressions" in CHECKS:  # in-tree-regressions.md: the live rows of the bugs found in real use
    CHECKS |= {"mode", "prompts", "file_after_popup", "reveal", "pane_fit", "divider_resize", "window_resize", "fullscreen",
               "pane_zoom", "popup_float", "omnibar_narrow", "zoom_motion", "grid_resize"}
with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(opts.app, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
ROWS, RAW = [], {}
RECORD_UNTIL = [0.0]
MARKER = "intreefocus0123456789abcdefghijklmnopqrs"  # 40 characters, keys debug.key types by name
assert len(MARKER) == 40

PAGE = """<!doctype html><html><head><title>in-tree probe</title></head>
<body style="background:#246;color:#fff;font:16px sans-serif">
<input id="field" style="font-size:20px;width:300px" placeholder="probe field">
<input id="file" type="file" onclick="window.__file.push('click')" oncancel="window.__file.push('cancel')" onchange="window.__file.push('change')"> <a id="dl" href="/download" download="in-tree-probe.txt">download</a>
<button id="pop" style="font-size:20px" onclick="window.__pop = window.open('/popup', 'probepopup', 'width=520,height=420')">popup</button>
<pre id="log"></pre>
<script>
window.__keys = []; window.__steal = 0; window.__results = {}; window.__file = []; window.__popupFile = [];
const field = document.getElementById('field');
field.addEventListener('keydown', e => window.__keys.push(e.key));
document.addEventListener('keydown', e => { if (e.target !== field) window.__keys.push('doc:' + e.key); });
window.startSteal = () => {
  const steal = () => { window.__steal++; window.focus(); field.focus(); };
  window.__stealTimer = setInterval(steal, 20);
  window.addEventListener('blur', steal);
  return true;
};
window.stopSteal = () => { clearInterval(window.__stealTimer); return window.__steal; };
window.later = (name, f) => { setTimeout(() => { try { window.__results[name] = String(f()); } catch (e) { window.__results[name] = 'error ' + e; } }, 50); return true; };
</script></body></html>"""


# The popup's page is one file input over the whole page (a click anywhere opens its chooser); it reports to its opener.
POPUP = """<!doctype html><html><head><title>in-tree popup</title></head><body style="margin:0;background:#462">
<input id="file" type="file" style="position:fixed;left:0;top:0;width:100vw;height:100vh;opacity:0.6"
 onclick="window.opener.__popupFile.push('click')" oncancel="window.opener.__popupFile.push('cancel')">
<script>window.opener.__popupFile.push('ready');</script></body></html>"""


# The regression rows' page (in-tree-regressions.md, bugs 10 to 15): a tall page (it scrolls), five fixed 24 x 24
# targets (corners and centre), a popup button, a log of every display frame's viewport (window.__vp: Date.now(),
# innerWidth, innerHeight, visualViewport width, height and scale, devicePixelRatio) and of every click (window.__clicks:
# the target hit, where the click landed against that target's own rect, and whether elementFromPoint at the click's
# client point is event.target).
LAYOUT = """<!doctype html><html><head><title>in-tree layout probe</title><style>
body{margin:0;background:#246;color:#fff;font:14px sans-serif} .t{position:fixed;width:24px;height:24px;padding:0;border:0;background:#fc3}
#tl{left:8px;top:8px} #tr{right:8px;top:8px} #bl{left:8px;bottom:8px} #br{right:8px;bottom:8px} #c{left:calc(50% - 12px);top:calc(50% - 12px)}
.row{height:40px;border-bottom:1px solid #357;padding-left:48px;line-height:40px}
#pop{position:fixed;left:48px;top:8px;font-size:14px}
.band{position:fixed;left:0;right:0;height:4px;pointer-events:none;z-index:5} #topband{top:0;background:#f0f} #botband{bottom:0;background:#0ff}
</style></head><body>
<div class="band" id="topband"></div><div class="band" id="botband"></div>
<button class="t" id="tl" data-t="tl"></button><button class="t" id="tr" data-t="tr"></button><button class="t" id="bl" data-t="bl"></button>
<button class="t" id="br" data-t="br"></button><button class="t" id="c" data-t="c"></button>
<button id="pop" onclick="window.__pop = window.open('/popup?float', 'floatpopup', 'width=520,height=420')">popup 520x420</button>
<div id="rows"></div>
<script>
window.__popupFile = []; window.__vp = []; window.__clicks = [];
{ const c = new URLSearchParams(location.search).get('c'); if (c && /^[0-9a-f]{6}$/i.test(c)) document.body.style.background = '#' + c; }
const rows = document.getElementById('rows');
for (let i = 0; i < 120; i++) { const d = document.createElement('div'); d.className = 'row'; d.textContent = 'row ' + i; rows.appendChild(d); }
const vv = window.visualViewport;
window.viewport = () => JSON.stringify({w: innerWidth, h: innerHeight, vw: vv ? vv.width : null, vh: vv ? vv.height : null,
  scale: vv ? vv.scale : null, dpr: devicePixelRatio, sy: scrollY, cw: document.documentElement.clientWidth,
  ch: document.documentElement.clientHeight});
(function frame() {
  if (window.__vp.length > 30000) window.__vp.splice(0, 10000);
  window.__vp.push([Date.now(), innerWidth, innerHeight, vv ? vv.width : 0, vv ? vv.height : 0, vv ? vv.scale : 1, devicePixelRatio]);
  requestAnimationFrame(frame);
})();
window.vpSince = t => JSON.stringify(window.__vp.filter(e => e[0] >= t));
window.targetCenters = () => JSON.stringify(Object.fromEntries([...document.querySelectorAll('[data-t]')].map(b => {
  const r = b.getBoundingClientRect(); return [b.dataset.t, [r.x + r.width / 2, r.y + r.height / 2]]; })));
document.addEventListener('click', e => {
  const t = e.target.closest ? e.target.closest('[data-t]') : null;
  const r = (t || e.target).getBoundingClientRect();
  window.__clicks.push({id: t ? t.dataset.t : null, target: e.target.id || e.target.tagName, x: e.clientX, y: e.clientY,
    rect: [r.x, r.y, r.width, r.height],
    inside: e.clientX >= r.x && e.clientX <= r.x + r.width && e.clientY >= r.y && e.clientY <= r.y + r.height,
    efp_same: document.elementFromPoint(e.clientX, e.clientY) === e.target});
}, true);
window.layoutReady = true;
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/download"):
            body, kind = b"in-tree download probe\n", "application/octet-stream"
        elif self.path.startswith("/layout"):
            body, kind = LAYOUT.encode(), "text/html"
        elif self.path.startswith("/popup"):
            body, kind = POPUP.encode(), "text/html"
        else:
            body, kind = PAGE.encode(), "text/html"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{server.server_address[1]}/"


def rpc(method, params=None, timeout=60):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
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


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def row(verdict, name, detail):
    if verdict is True:
        verdict = "PASS"
    elif verdict is False:
        verdict = "FAIL"
    ROWS.append({"verdict": verdict, "name": name, "detail": detail})
    print(f"{verdict} | {name} | {json.dumps(detail, default=str)[:600]}", flush=True)


def record(name, seconds=12):
    """Video proof: the window, as the window server composites it, once per display frame for `seconds` (at most 12),
    as JPEG frames in OUT/video-NAME (debug.window_record); the suite turns each folder into an mp4."""
    folder = os.path.join(opts.out, f"video-{name}")
    os.makedirs(folder, exist_ok=True)
    # One recording per app: wait out the one before (live step e7d15ed8 lost two_pages' video to prompts').
    left = RECORD_UNTIL[0] - time.time()
    if left > 0:
        time.sleep(left + 0.2)  # test harness: the previous recording ends by itself
    RAW.setdefault("recordings", {})[name] = rpc("debug.window_record", {"dir": folder, "seconds": seconds})
    RECORD_UNTIL[0] = time.time() + seconds


def action(name, args=None, target=None):
    params = {"action": name, "focus": True, "origin": "script"}
    if args:
        params["args"] = args
    if target:
        params["target"] = target
    return rpc("action.run", params)


def page_eval(script, tab=None):
    params = {"script": script}
    if tab:
        params["tab"] = tab
    reply = rpc("browser.page.eval", params, timeout=20)
    return reply if isinstance(reply, dict) else {"error": reply}


def windows():
    layers = rpc("debug.layers")
    return (layers.get("windows") if isinstance(layers, dict) else None) or []


def census(label):
    ws = windows()
    out = {"windows": len(ws), "per_window": []}
    for w in ws:
        out["per_window"].append({
            "placement": w.get("placement"), "overlay_panel": w.get("overlay_panel"),
            "page_views": len(w.get("page_views") or []),
            "content_child_windows": sum(1 for c in w.get("child_windows") or [] if c.get("role") == "content" and c.get("visible")),
            "child_windows": [{k: c.get(k) for k in ("role", "visible")} for c in w.get("child_windows") or []],
            "violations": w.get("child_window_violations") or [],
            "reorders": w.get("reorders"), "divider_catcher_updates": w.get("divider_catcher_updates"),
            "browsers": [{k: b.get(k) for k in ("pane", "engine", "presentation", "rwhv_in_window", "widget_drawing",
                                                 "headless_window_visible")} for b in w.get("browsers") or []],
        })
    cef = rpc("debug.cef")
    out["cef_in_tree"] = cef.get("in_tree") if isinstance(cef, dict) else None
    out["cef_widget_drawing"] = cef.get("widget_drawing") if isinstance(cef, dict) else None
    RAW[f"census_{label}"] = {"layers": ws, "cef": cef}
    return out


def daemon_socket():
    temp = os.environ.get("TMPDIR") or subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    return os.path.join(temp, f"cmux-tui-{os.getuid()}", f"cmux-app-{opts.tag}.sock")


def tab_count():
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30)
        conn.connect(daemon_socket())
        conn.sendall((json.dumps({"id": 1, "cmd": "list-workspaces"}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        data = json.loads(buf).get("data") or {}
        return sum(len(p.get("tabs") or []) for e in data.get("workspaces") or [] for s in e.get("screens") or []
                   for p in s.get("panes") or [])
    except (OSError, ValueError):
        surfaces = rpc("debug.surfaces")
        items = surfaces.get("surfaces") if isinstance(surfaces, dict) else None
        return len(items) if isinstance(items, list) else None


def terminal_text():
    reply = rpc("surface.read_text")
    return reply.get("text", "") if isinstance(reply, dict) else ""


CUA_DRIVER = next((c for c in ("/Applications/CuaDriver.app/Contents/MacOS/cua-driver", os.path.expanduser("~/.local/bin/cua-driver"))
                   if os.path.exists(c)), None)


def cua(tool, args):
    """One CuaDriver call through the host's daemon (under the login's own home, not the step's HOME)."""
    if not CUA_DRIVER:
        return {"error": "no cua-driver"}
    import pwd
    try:
        done = subprocess.run([CUA_DRIVER, "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=60,
                              env=dict(os.environ, HOME=pwd.getpwuid(os.getuid()).pw_dir))
        return json.loads(done.stdout) if done.stdout.strip() else {"error": done.stderr[-300:]}
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        return {"error": repr(error)}


def elements(obj):
    if isinstance(obj, dict):
        if isinstance(obj.get("elements"), list):
            return obj["elements"]
        for v in obj.values():
            found = elements(v)
            if found:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = elements(v)
            if found:
                return found
    return []


def cancel_sheet():
    """The person's Cancel on the shown Open sheet: an accessibility press on its Cancel button (CuaDriver, no focus
    taken), else Escape to the app. Returns how."""
    sheet = next((w for w in sheets() if w["visible"]), None)
    pid = RAW.get("pid")
    if sheet and pid and CUA_DRIVER:
        state = cua("get_window_state", {"pid": pid, "window_id": int(sheet["id"]), "include_screenshot": False,
                                         "max_depth": 40, "max_elements": 3000})
        button = next((e for e in elements(state) if "button" in str(e.get("role", "")).lower()
                       and "Cancel" in (str(e.get("label") or "") + str(e.get("title") or "")) and e.get("element_token")), None)
        if button:
            pressed = cua("click", {"pid": pid, "window_id": int(sheet["id"]), "element_token": button["element_token"]})
            if not (isinstance(pressed, dict) and (pressed.get("isError") or pressed.get("error"))):
                return "ax_cancel"
        RAW.setdefault("cancel_sheet_misses", []).append({"sheet": sheet, "elements": len(elements(state)),
                                                          "state": json.dumps(state)[:300]})
    rpc("debug.key", {"key": "escape"})
    return "escape"


def file_dialogs():
    reply = (rpc("debug.cef") or {}).get("file_dialogs") or {}
    return dict(reply, received=int(reply.get("received") or 0))


def sheets():
    """The app's open panels and sheets (shown or not), with their parent window: an Open panel left on a closed window
    shows here."""
    return [{k: w.get(k) for k in ("id", "kind", "title", "visible", "parent", "class")}
            for w in ((rpc("debug.window_list") or {}).get("windows") or [])
            if w.get("kind") == "sheet" or "OpenPanel" in str(w.get("class")) or w.get("title") == "Open"]


def popup_index():
    panels = (rpc("debug.popups") or {}).get("panels") or []
    return next((i for i, p in enumerate(panels) if "/popup" in str(p.get("url") or "") and p.get("visible")), None)


def page_list(name, tab):
    value = page_eval(f"JSON.stringify(window.{name})", tab).get("value")
    try:
        return json.loads(value) if isinstance(value, str) else []
    except ValueError:
        return []


def click_file_input(tab):
    rect = page_eval("JSON.stringify((r => [r.x + r.width / 2, r.y + r.height / 2])("
                     "document.getElementById('file').getBoundingClientRect()))", tab)
    try:
        x, y = json.loads(rect["value"])
        return {"rect": [x, y], "click": rpc("debug.mouse", {"target": "page", "x": x, "y": y})}
    except Exception as error:
        return {"error": repr(error), "rect": rect}


def opener_chooser(tab, label):
    """One chooser in the opener: a page click on its file input must show a visible sheet and reach the app; Escape
    must cancel it and the page must get 'cancel'."""
    action("tab.focus", target=f"tab:{tab}")
    page_eval("window.__file = []; true", tab)
    before = file_dialogs()
    fired = click_file_input(tab)
    shown = wait(lambda: (lambda d, s: (d, s) if d["received"] > before["received"] and any(w["visible"] for w in s) else None)(
        file_dialogs(), sheets()), 6)
    after, now_sheets = (shown if shown else (file_dialogs(), sheets()))
    if label == "first":
        rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "file-after-popup-opener-sheet.png")})
    escape = cancel_sheet()
    cancelled = wait(lambda: "cancel" in page_list("__file", tab), 4)
    if not cancelled and any(w["visible"] for w in sheets()):
        cancel_sheet()  # again, so a later step starts with no sheet
    return {"sheet_shown": bool(shown), "request_reached_app": after["received"] > before["received"],
            "page_got_cancel": bool(cancelled), "received": [before["received"], after["received"]],
            "answered": file_dialogs().get("answered"), "last": after.get("last"), "input_events": page_list("__file", tab),
            "sheets": now_sheets, "fired": fired, "escape": escape}


def file_after_popup(tab):
    """prompts.file_after_popup: a popup's chooser closed with its popup must not break later choosers (6e420b7b)."""
    record("file_after_popup")
    action("tab.focus", target=f"tab:{tab}")
    page_eval("window.__popupFile = []; true", tab)
    rect = page_eval("JSON.stringify((r => [r.x + r.width / 2, r.y + r.height / 2])("
                     "document.getElementById('pop').getBoundingClientRect()))", tab)
    try:
        x, y = json.loads(rect["value"])
        opened = rpc("debug.mouse", {"target": "page", "x": x, "y": y})
    except Exception as error:
        opened = {"error": repr(error), "rect": rect}
    index = wait(lambda: (lambda i: i + 1 if i is not None and "ready" in page_list("__popupFile", tab) else None)(popup_index()), 15)
    if not index:
        row(False, "prompts.file_after_popup.popup", {"open_click": opened, "popups": json.dumps(rpc("debug.popups"))[:400],
                                                      "popup_events": page_list("__popupFile", tab)})
        return
    time.sleep(1.0)  # test harness: the popup moves into its own window and draws
    index = popup_index()
    before = file_dialogs()
    clicked = rpc("debug.mouse", {"target": "page", "popup": index})
    shown = wait(lambda: (lambda d, s: (d, s) if d["received"] > before["received"] and any(w["visible"] for w in s) else None)(
        file_dialogs(), sheets()), 6)
    rpc("debug.popups", {"snapshot_dir": os.path.join(opts.out, "file-after-popup-popups")})
    popup_sheet = {"click": clicked, "sheet_shown": bool(shown), "file_dialogs": file_dialogs(), "sheets": sheets(),
                   "popup_events": page_list("__popupFile", tab)}
    RAW["file_after_popup_popup_sheet"] = popup_sheet
    # debug.mouse names the window it clicked: the popup's, else it fell through to the focused pane's page.
    on_popup = isinstance(clicked, dict) and clicked.get("window") == f"popup-{index}"
    row(bool(shown) and on_popup, "prompts.file_after_popup.popup_sheet", popup_sheet)
    if not shown:
        rpc("debug.key", {"key": "escape"})
        rpc("debug.popups", {"action": "close"})
        return
    # Close the popup while its sheet is up.
    if opts.close_popup == "script":
        closed_by = page_eval("window.__pop.close(); true", tab)
    else:
        closed_by = rpc("debug.popups", {"action": "close"})
    gone = wait(lambda: popup_index() is None, 8)
    time.sleep(1.5)  # test harness: the popup's browser closes (OnBeforeClose cancels its pending chooser)
    after_close = {"closed_by": opts.close_popup, "close": closed_by, "popup_gone": gone is not None,
                   "file_dialogs": file_dialogs(), "sheets": sheets(), "popup_events": page_list("__popupFile", tab)}
    RAW["file_after_popup_closed"] = after_close
    row("INFO", "prompts.file_after_popup.closed", after_close)
    for label in ("first", "second"):
        result = opener_chooser(tab, label)
        RAW[f"file_after_popup_opener_{label}"] = result
        row(result["sheet_shown"] and result["request_reached_app"] and result["page_got_cancel"],
            f"prompts.file_after_popup.opener_{label}", result)
        time.sleep(0.5)  # test harness: the sheet closes


def png_rgb(path):
    """(width, height, rows of RGB bytes) of an 8-bit non-interlaced PNG (RGB or RGBA), without PIL."""
    import struct, zlib
    data = open(path, "rb").read()
    pos, idat, width = 8, b"", 0
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color = struct.unpack(">IIBB", body[:10])
            if depth != 8 or color not in (2, 6):
                raise ValueError(f"png depth {depth} color {color}")
            channels = 3 if color == 2 else 4
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    raw, stride, rows, prev = zlib.decompress(idat), width * channels, [], bytearray(width * channels)
    for y in range(height):
        start = y * (stride + 1)
        kind, line = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if kind == 1:
                line[i] = (line[i] + a) & 255
            elif kind == 2:
                line[i] = (line[i] + b) & 255
            elif kind == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif kind == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line if channels == 3 else bytes(v for j, v in enumerate(line) if j % 4 != 3)))
        prev = line
    return width, height, rows


def probe_colors(path):
    """Counts of the reveal probe's colours in a window capture: the yellow block and the page's blue (#246)."""
    width, height, rows = png_rgb(path)
    yellow = blue = 0
    for row_bytes in rows[::2]:
        for i in range(0, len(row_bytes), 6):
            r, g, b = row_bytes[i], row_bytes[i + 1], row_bytes[i + 2]
            if r > 200 and g > 200 and b < 90:
                yellow += 1
            elif abs(r - 0x22) < 14 and abs(g - 0x44) < 14 and abs(b - 0x66) < 14:
                blue += 1
    return {"yellow": yellow, "blue": blue, "w": width, "h": height}


def main_window_id(pid):
    listed = cua("list_windows", {})
    wins = [w for w in (listed.get("windows") or []) if w.get("pid") == pid and w.get("bounds")]
    wins.sort(key=lambda w: -w["bounds"]["width"] * w["bounds"]["height"])
    return wins[0]["window_id"] if wins else None


class PixelSampler:
    """Window captures in a loop on two threads (each CuaDriver call is a process), timestamped, until stop()."""

    def __init__(self, folder, pid):
        self.folder, self.pid, self.frames, self.errors = folder, pid, [], []
        os.makedirs(folder, exist_ok=True)
        self.window = main_window_id(pid) if CUA_DRIVER else None
        self.running, self.threads, self.count = False, [], 0
        self.lock = threading.Lock()

    def start(self):
        if not self.window:
            return False
        self.running = True
        for _ in range(2):
            thread = threading.Thread(target=self.loop, daemon=True)
            thread.start()
            self.threads.append(thread)
        return True

    def loop(self):
        while self.running:
            with self.lock:
                self.count += 1
                path = os.path.join(self.folder, f"cap-{self.count:04d}.png")
            started = time.time()
            reply = cua("get_window_state", {"pid": self.pid, "window_id": self.window, "include_accessibility_tree": False,
                                              "screenshot_out_file": path, "max_image_dimension": 640})
            ended = time.time()
            if os.path.exists(path):
                self.frames.append({"path": path, "t": (started + ended) / 2, "spread": ended - started})
            else:
                self.errors.append(str(reply)[:200])
                time.sleep(0.05)  # test harness: a capture of a window off the screen fails at once

    def stop(self):
        self.running = False
        for thread in self.threads:
            thread.join(timeout=10)


def reveal(tab, mode, label):
    """reveal.<label>: the window leaves the screen (`hide` or `cover`) and comes back; the page must show its last frame
    at once, never only its background (in-tree 34f21f2f: about 200 ms of the page's background colour)."""
    page_eval("(() => { document.body.style.background = '#246'; let b = document.getElementById('revealprobe'); if (!b) { b = document.createElement('div');"
              " b.id = 'revealprobe'; b.style.cssText = 'position:fixed;left:40px;top:120px;width:360px;height:260px;"
              "background:#ff0;z-index:9'; document.body.appendChild(b); } return true; })()", tab)
    time.sleep(1.0)  # test harness: the block draws
    pid = RAW.get("pid")
    sampler = PixelSampler(os.path.join(opts.out, f"reveal-{label}"), pid)
    baseline = None
    if sampler.window:
        shot = os.path.join(sampler.folder, "baseline.png")
        cua("get_window_state", {"pid": pid, "window_id": sampler.window, "include_accessibility_tree": False,
                                 "screenshot_out_file": shot, "max_image_dimension": 640})
        if os.path.exists(shot):
            try:
                baseline = probe_colors(shot)
            except Exception as error:
                baseline = {"error": repr(error)}
    off, on = ("hide", "show") if mode == "hide" else ("cover", "uncover")
    left = rpc("debug.page_reveal", {"action": off})
    time.sleep(1.5)  # test harness: the window's occlusion reaches Chromium
    visibility = page_eval("document.visibilityState", tab).get("value")
    time.sleep(max(0.0, opts.reveal_hidden - 2.0))  # the person is in another app
    sampling = sampler.start()
    time.sleep(0.5)  # test harness: captures of the hidden window run before the show
    shown_at = time.time()
    back = rpc("debug.page_reveal", {"action": on})
    time.sleep(2.5)  # test harness: the page's next frames
    sampler.stop()
    samples = (rpc("debug.page_reveal", {"action": "samples"}) or {}).get("samples") or {}
    layers = samples.get("reveal") or {}
    RAW[f"reveal_{label}"] = {"left": left, "back": back, "visibility_while_hidden": visibility, "samples": samples}
    replaced = layers.get("replaced_ms")
    detail = {"mode": mode, "visibility_while_hidden": visibility, "replaced_ms": replaced,
              "ids_before": layers.get("ids_before"), "ids_visible": layers.get("ids_visible"),
              "ids_last": layers.get("ids_last"), "visible_ms_after_show": layers.get("visible_ms_after_show")}
    if not layers.get("ids_before"):
        row("INFO", f"reveal.{label}.layers", dict(detail, note="no remote page layer in the main window"))
    else:
        row(replaced is None, f"reveal.{label}.layers", detail)
    if not sampling or baseline is None or not isinstance(baseline, dict) or not baseline.get("yellow"):
        row("INFO", f"reveal.{label}.pixels", {"captures": "none" if not sampling else len(sampler.frames),
                                               "baseline": baseline, "errors": sampler.errors[:3]})
        return
    frames = []
    for frame in sorted(sampler.frames, key=lambda f: f["t"]):
        try:
            colors = probe_colors(frame["path"])
        except Exception as error:
            colors = {"error": repr(error)}
        frames.append(dict(colors, ms=round((frame["t"] - shown_at) * 1000), spread_ms=round(frame["spread"] * 1000),
                           file=os.path.basename(frame["path"])))
    after = [f for f in frames if f["ms"] > 0 and "error" not in f]
    # Background only: the page's blue shows (the window is back) and its yellow block does not.
    blank = [f for f in after if f["blue"] > 0.3 * max(1, baseline["blue"]) and f["yellow"] < 0.2 * baseline["yellow"]]
    drawn = [f for f in after if f["yellow"] >= 0.6 * baseline["yellow"]]
    RAW[f"reveal_{label}"]["pixels"] = {"baseline": baseline, "frames": frames}
    pixel_detail = {"baseline": baseline, "captures_after_show": len(after), "drawn": len(drawn),
                    "background_only": [(f["ms"], f["file"]) for f in blank][:12],
                    "first_drawn_ms": drawn[0]["ms"] if drawn else None}
    if not after:
        row("INFO", f"reveal.{label}.pixels", pixel_detail)
    else:
        row(not blank and bool(drawn), f"reveal.{label}.pixels", pixel_detail)


# ---- Regression rows for bugs 10 to 15 (in-tree-regressions.md). Each names its bug and its PASS condition. ----

FIT_PX = 1.0        # the page's viewport equals its view's size within this many points
LAG_MS = 100        # the page reaches the pane's final size at most this long after the pane does
HIT_PX = 1.0        # a click lands within this many points of where it was sent


def page_json(script, tab):
    value = page_eval(script, tab).get("value")
    try:
        return json.loads(value) if isinstance(value, str) else None
    except ValueError:
        return None


def main_layers():
    return (windows() or [{}])[0]


def page_pane(tab):
    """The pane whose tabs list `tab` (debug.focus topology)."""
    focus = rpc("debug.focus") or {}
    # Older apps list the topology at the top; newer ones per window.
    topology = focus.get("topology") or [p for w in focus.get("windows") or [] for p in w.get("topology") or []]
    for pane in topology:
        if any(str(t).split(":", 1)[0] == str(tab) for t in pane.get("tabs") or []):
            return pane.get("pane")
    return None


def page_view(pane, layers=None):
    """The in-tree page view of `pane` in the main window: its frame [x, y, w, h] in window points from the bottom left,
    or None (mode off, or no view: the rows that need it say INFO)."""
    layers = layers or main_layers()
    views = [v for v in layers.get("page_views") or [] if not v.get("parked") and (pane is None or v.get("pane") == pane)]
    return views[0].get("frame_in_window") if views else None


def content_height(layers=None):
    frame = (layers or main_layers()).get("frame") or [0, 0, 0, 0]
    return frame[3]  # full-size content view: the content is the whole window


def fits(viewport, frame, px=FIT_PX):
    return bool(viewport and frame) and abs(viewport["w"] - frame[2]) <= px and abs(viewport["h"] - frame[3]) <= px


def track(pane, tab, trigger, seconds=6.0, quiet=0.6):
    """Run `trigger` and sample the page view's frame (debug.layers) until it has not changed for `quiet` s. Returns
    {t0_ms, samples: [(ms, frame, window_frame)], final, pane_final_ms, page_final_ms, lag_ms, vp}: pane_final_ms is when
    the view took its final size, page_final_ms when the page's viewport (its rAF log) took the same size for good."""
    page_eval("window.__vp = []; true", tab)
    t0 = time.time()
    reply = trigger()
    samples, last, quiet_since = [], None, time.time()
    while time.time() - t0 < seconds:
        layers = main_layers()
        frame = page_view(pane, layers)
        samples.append((round((time.time() - t0) * 1000), frame, layers.get("frame")))
        if frame != last:
            last, quiet_since = frame, time.time()
        elif time.time() - quiet_since > quiet:
            break
        time.sleep(0.016)  # test harness: one sample a display frame
    final = samples[-1][1] if samples else None
    pane_final_ms = None
    for ms, frame, _ in reversed(samples):
        if frame != final:
            break
        pane_final_ms = ms
    vp = page_json(f"window.vpSince({int(t0 * 1000)})", tab) or []
    page_final_ms = None
    if final:
        for entry in reversed(vp):
            if abs(entry[1] - final[2]) > FIT_PX or abs(entry[2] - final[3]) > FIT_PX:
                break
            page_final_ms = entry[0] - t0 * 1000
    lag = None if page_final_ms is None or pane_final_ms is None else round(page_final_ms - pane_final_ms)
    return {"reply": str(reply)[:200], "t0_ms": int(t0 * 1000), "samples": samples, "final": final,
            "pane_final_ms": pane_final_ms, "page_final_ms": None if page_final_ms is None else round(page_final_ms),
            "lag_ms": lag, "vp": vp}


def zoom_glitch(vp):
    """Frames of the page's rAF log with a pinch scale other than 1 or a device pixel ratio other than its first."""
    if not vp:
        return []
    dpr = vp[0][6]
    return [e for e in vp if abs(e[5] - 1) > 1e-3 or e[6] != dpr][:8]


def overshoot(samples, start, final):
    """Samples where the page view is larger than both its start and final size, or leaves the window."""
    bad = []
    for ms, frame, window in samples:
        if not frame or not start or not final:
            continue
        if frame[2] > max(start[2], final[2]) + FIT_PX or frame[3] > max(start[3], final[3]) + FIT_PX:
            bad.append((ms, frame, "larger than start and end"))
        elif window and (frame[0] < -FIT_PX or frame[1] < -FIT_PX or frame[0] + frame[2] > window[2] + FIT_PX
                         or frame[1] + frame[3] > window[3] + FIT_PX):
            bad.append((ms, frame, "outside the window"))
    return bad[:8]


def vertical_divider_near(x_page_left, layers=None):
    """The vertical divider nearest the page view's left edge: (x, y) in window points from the top left."""
    layers = layers or main_layers()
    height = content_height(layers)
    cands = [(x + w / 2, height - (y + h / 2)) for x, y, w, h in layers.get("divider_areas_in_window") or [] if h > w]
    return min(cands, key=lambda c: abs(c[0] - x_page_left)) if cands else None


def drag_divider(divider, dx, steps=40, hz=60.0):
    x0, y0 = divider
    rpc("debug.mouse", {"action": "down", "x": x0, "y": y0})
    x, started = x0, time.monotonic()
    for i in range(1, steps + 1):
        nx = x0 + dx * i / steps
        rpc("debug.mouse", {"action": "drag", "x": x, "y": y0, "to_x": nx, "to_y": y0, "steps": 1, "press": False, "release": False})
        x = nx
        next_at = started + i / hz
        if next_at > time.monotonic():
            time.sleep(next_at - time.monotonic())  # test harness: one event a display frame, as a hand drags
    return rpc("debug.mouse", {"action": "up", "x": x, "y": y0})


def frames_ok(frames):
    """A drag's display-link intervals: at most 2 missed frames and p95 within 1.5 refresh intervals."""
    if not isinstance(frames, dict) or "error" in frames or not frames.get("frames"):
        return False
    refresh = frames.get("refresh_ms") or 16.7
    return (frames.get("missed") or 0) <= 2 and (frames.get("p95_ms") or 0) <= 1.5 * refresh


def frame_detail(frames):
    return {k: (frames or {}).get(k) for k in ("frames", "refresh_ms", "p50_ms", "p95_ms", "max_ms", "missed")} \
        if isinstance(frames, dict) else frames


def is_full_screen():
    g = rpc("debug.window_transition", {"action": "geometry"})
    return isinstance(g, list) and bool(g) and g[0].get("full_screen") is True


def open_layout(tab, query=""):
    page_eval(f"location.href = {json.dumps(URL + 'layout' + query)}; true", tab)
    return wait(lambda: page_eval("window.layoutReady === true", tab).get("value") is True, 30, 0.3)


PAINT_PX = 2.0      # the page's painted top and bottom edges sit within this many points of its view's


def band_rows(path, columns):
    """Per image column (pixels), the first row of the layout page's magenta top band and the last row of its cyan
    bottom band, or None where that band does not show."""
    width, height, rows = png_rgb(path)
    out = []
    for x in columns:
        x = max(0, min(width - 1, int(x)))
        top = bottom = None
        for y in range(height):
            r, g, b = rows[y][3 * x], rows[y][3 * x + 1], rows[y][3 * x + 2]
            if top is None and r > 200 and g < 90 and b > 200:
                top = y
            if r < 90 and g > 200 and b > 200:
                bottom = y
        out.append((top, bottom))
    return width, height, out


def check_paint(pane, label):
    """pane_fit.paint.<label> (bug 13): the page's pixels sit in its view. A window capture (CuaDriver, the window
    server's real pixels) must show the layout page's 4 pt magenta top band starting at the view's top edge and its cyan
    bottom band ending at the view's bottom edge, within PAINT_PX, in three columns. The user's recordings showed the top
    of the page above the pane (the band gone) and the bottom of the pane unpainted (the cyan band high).
    pane_fit.layers.<label>: debug.layers' geometry of the page view: every layer holding the page's pixels covers its
    view (`fits`)."""
    layers = main_layers()
    frame, window = page_view(pane, layers), layers.get("frame")
    view = next((v for v in layers.get("page_views") or [] if not v.get("parked") and v.get("pane") == pane), {})
    try:
        geometry = json.loads(view.get("geometry") or "null")
    except ValueError:
        geometry = None
    if geometry is None:
        row("INFO", f"pane_fit.layers.{label}", {"note": "no geometry in debug.layers (an older app)"})
    else:
        row(geometry.get("fits") is True, f"pane_fit.layers.{label}",
            {"bug": 13, "misfits": geometry.get("misfits"), "page_view": frame,
             "pass_if": "every layer above the page's CALayerHost is its view's size at its origin"})
    RAW[f"pane_fit_geometry_{label}"] = geometry
    pid, wid = RAW.get("pid"), main_window_id(RAW.get("pid")) if CUA_DRIVER else None
    shot = os.path.join(opts.out, f"pane-fit-{label}.png")
    if not frame or not window or not wid:
        row("INFO", f"pane_fit.paint.{label}", {"note": "no page view, window or capture", "frame": frame, "cua": bool(CUA_DRIVER)})
        return
    cua("get_window_state", {"pid": pid, "window_id": wid, "include_accessibility_tree": False,
                             "screenshot_out_file": shot, "max_image_dimension": 4000})
    if not os.path.exists(shot):
        row("INFO", f"pane_fit.paint.{label}", {"note": "no capture"})
        return
    width, height, _ = band_rows(shot, [])
    sx, sy = width / window[2], height / window[3]
    x, y, w, h = frame
    view_top, view_bottom = window[3] - (y + h), window[3] - y  # points from the window's top
    columns = [(x + w * f) * sx for f in (0.3, 0.5, 0.7)]
    _, _, found = band_rows(shot, columns)
    edges = [{"top": None if t is None else round(t / sy, 1), "bottom": None if b is None else round((b + 1) / sy, 1)}
             for t, b in found]
    seen = [e for e in edges if e["top"] is not None or e["bottom"] is not None]
    detail = {"bug": 13, "view_top": round(view_top, 1), "view_bottom": round(view_bottom, 1), "edges": edges,
              "scale": [round(sx, 3), round(sy, 3)], "capture": os.path.basename(shot),
              "pass_if": f"magenta top band starts and cyan bottom band ends within {PAINT_PX} pt of the view's edges"}
    if not seen:
        row("INFO", f"pane_fit.paint.{label}", dict(detail, note="neither band in the capture (no page pixels for this host)"))
        return
    ok = abs(sx - sy) < 0.02 and all(e["top"] is not None and e["bottom"] is not None and abs(e["top"] - view_top) <= PAINT_PX
                                     and abs(e["bottom"] - view_bottom) <= PAINT_PX for e in edges)
    row(ok, f"pane_fit.paint.{label}", detail)


def set_window_height(delta):
    """debug.window_frame: the window `delta` points taller (negative: shorter), its top edge kept."""
    frame = main_layers().get("frame")
    if not frame:
        return None
    reply = rpc("debug.window_frame", {"frame": [frame[0], frame[1] - delta, frame[2], frame[3] + delta]})
    time.sleep(1.0)  # test harness: the page takes the new size and draws
    return reply


def check_pane_fit(tab, pane):
    """Bug 13: after the split and a scroll, the page's innerWidth/innerHeight and visualViewport equal its view's size
    within 1 pt, and a click at each of five targets' centres (a page click, then a window click at the same point)
    hits that target: event.target is the target, the click is inside its rect within 1 pt, elementFromPoint agrees.
    Its paint rows (check_paint) run after the split, and again after the window was made 200 pt shorter and then
    100 pt taller (the person's recordings: the page's offset grew with every size it went through)."""
    check_paint(pane, "split")
    start = main_layers().get("frame")
    RAW["pane_fit_resize"] = [set_window_height(-200), set_window_height(100)]
    check_paint(pane, "resized")
    layers = main_layers()
    frame = page_view(pane, layers)
    if not frame:
        row("INFO", "pane_fit", {"note": "no in-tree page view for the pane", "pane": pane})
        return
    height = content_height(layers)
    # A wheel scroll over the page's centre (window point), as a person scrolls; a script scroll if it did not move.
    cx, cy = frame[0] + frame[2] / 2, height - (frame[1] + frame[3] / 2)
    scroll = rpc("debug.mouse", {"action": "scroll", "x": cx, "y": cy, "dx": 0, "dy": -400})
    time.sleep(0.6)  # test harness: the scroll lands
    viewport = page_json("window.viewport()", tab) or {}
    scrolled_by = "wheel"
    if not viewport.get("sy"):
        page_eval("window.scrollBy(0, 400); true", tab)
        time.sleep(0.3)  # test harness: the scroll lands
        viewport, scrolled_by = page_json("window.viewport()", tab) or {}, "script (the wheel did not scroll)"
    frame = page_view(pane)
    vv_ok = viewport.get("vh") is not None and abs(viewport["vh"] - frame[3]) <= FIT_PX and abs(viewport["vw"] - frame[2]) <= FIT_PX
    row(fits(viewport, frame) and vv_ok and bool(viewport.get("sy")), "pane_fit.viewport",
        {"bug": 13, "viewport": viewport, "page_view": frame, "scroll": scroll, "scrolled_by": scrolled_by,
         "pass_if": "|innerW-viewW|,|innerH-viewH|,|vv-view| <= 1 pt after a scroll"})
    centres = page_json("window.targetCenters()", tab) or {}
    for route in ("page", "window"):
        page_eval("window.__clicks = []; true", tab)
        sent = {}
        for name, (x, y) in centres.items():
            if route == "page":
                sent[name] = rpc("debug.mouse", {"target": "page", "pane": pane, "x": x, "y": y})
            else:
                sent[name] = rpc("debug.mouse", {"x": frame[0] + x, "y": height - (frame[1] + frame[3]) + y})
            time.sleep(0.15)  # test harness: the click reaches the renderer
        time.sleep(0.4)  # test harness: the last click lands
        clicks = page_json("JSON.stringify(window.__clicks)", tab) or []
        misses = []
        for name, (x, y) in centres.items():
            got = next((c for c in clicks if c.get("id") == name), None)
            if not got or not got["inside"] or not got["efp_same"] or abs(got["x"] - x) > HIT_PX or abs(got["y"] - y) > HIT_PX:
                misses.append({"target": name, "sent": [round(x, 1), round(y, 1)], "got": got})
        stray = [c for c in clicks if c.get("id") is None]
        row(len(centres) == 5 and not misses and not stray, f"pane_fit.click.{route}",
            {"bug": 13, "misses": misses, "stray_clicks": stray[:5], "clicks": len(clicks),
             "pass_if": "each of 5 targets hit, inside its rect, within 1 pt, elementFromPoint == event.target"})
    if start:
        rpc("debug.window_frame", {"frame": start})
        time.sleep(0.6)  # test harness: the window is back at its first frame for the rows after


def check_divider_resize(tab, pane):
    """Bug 11 (divider): a 40-step divider drag at 60 Hz beside the page misses at most 2 display frames (p95 within
    1.5 refresh intervals), the page's viewport follows during the drag (at least 10 distinct widths in its rAF log),
    and after the release the page takes the pane's final size within LAG_MS of the pane."""
    layers = main_layers()
    frame = page_view(pane, layers)
    divider = vertical_divider_near(frame[0], layers) if frame else None
    if not frame or not divider:
        row("INFO", "divider_resize", {"note": "no page view or no divider", "frame": frame})
        return
    record("divider_resize", 8)
    rpc("debug.frames", {"action": "start"})
    result = track(pane, tab, lambda: (drag_divider(divider, -160), drag_divider((divider[0] - 160, divider[1]), 160)), 10)
    frames = rpc("debug.frames", {"action": "stop"})
    widths = {e[1] for e in result["vp"]}
    row(frames_ok(frames), "divider_resize.frames", {"bug": 11, "frames": frame_detail(frames),
                                                      "pass_if": "missed <= 2 and p95 <= 1.5 x refresh"})
    row(len(widths) >= 10, "divider_resize.follows", {"bug": 11, "distinct_page_widths": len(widths),
                                                       "pass_if": ">= 10 distinct innerWidth values during the drag"})
    viewport = page_json("window.viewport()", tab)
    row(result["lag_ms"] is not None and result["lag_ms"] <= LAG_MS and fits(viewport, result["final"]), "divider_resize.settle",
        {"bug": 11, "lag_ms": result["lag_ms"], "viewport": viewport, "page_view": result["final"],
         "pass_if": f"page matches the pane <= {LAG_MS} ms after the pane settles, then within 1 pt"})


def check_window_resize(tab, pane):
    """Bug 11 (window edge): the bottom-right corner dragged out by 240 x 120 and back at 120 Hz misses at most 2
    display frames (p95 within 1.5 refresh intervals) and the page takes its view's final size within LAG_MS."""
    layers = main_layers()
    window = layers.get("frame")
    if not window or not page_view(pane, layers):
        row("INFO", "window_resize", {"note": "no window frame or page view"})
        return
    record("window_resize", 8)
    w, h = window[2], window[3]

    def corner(dx, dy, steps=60):
        x0, y0 = w - 1, h - 1
        rpc("debug.mouse", {"action": "down", "x": x0, "y": y0})
        started = time.monotonic()
        for i in range(1, steps + 1):
            x, y = x0 + dx * i / steps, y0 + dy * i / steps
            rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1, "press": False, "release": False})
            next_at = started + i / 120
            if next_at > time.monotonic():
                time.sleep(next_at - time.monotonic())  # test harness: one event a 120 Hz frame
        return rpc("debug.mouse", {"action": "up", "x": x0 + dx, "y": y0 + dy})

    rpc("debug.frames", {"action": "start"})
    out = track(pane, tab, lambda: corner(240, 120), 8)
    back = track(pane, tab, lambda: corner(-240, -120), 8)
    frames = rpc("debug.frames", {"action": "stop"})
    row(frames_ok(frames), "window_resize.frames", {"bug": 11, "frames": frame_detail(frames),
                                                     "window_before": window, "window_after": main_layers().get("frame"),
                                                     "pass_if": "missed <= 2 and p95 <= 1.5 x refresh"})
    viewport = page_json("window.viewport()", tab)
    lags = [out["lag_ms"], back["lag_ms"]]
    row(all(l is not None and l <= LAG_MS for l in lags) and fits(viewport, back["final"]), "window_resize.settle",
        {"bug": 11, "lag_ms": lags, "viewport": viewport, "page_view": back["final"],
         "pass_if": f"page matches the pane <= {LAG_MS} ms after each drag ends, then within 1 pt"})


def check_fullscreen(tab, pane):
    """Bug 12: entering and leaving full screen (toggleFullScreen), the page never shows a pinch scale or a changed
    device pixel ratio (the temporary zoom of every view), its view never grows past both its start and end size or
    leaves the window (overflow), and the page takes the pane's final size within LAG_MS of the pane."""
    start = page_view(pane)
    if not start:
        row("INFO", "fullscreen", {"note": "no in-tree page view"})
        return
    record("fullscreen", 12)
    for direction in ("enter", "exit"):
        before = page_view(pane)
        result = track(pane, tab, lambda: action("toggleFullScreen"), 8, quiet=0.8)
        wait(lambda: is_full_screen() == (direction == "enter"), 5)
        viewport = page_json("window.viewport()", tab)
        glitches, over = zoom_glitch(result["vp"]), overshoot(result["samples"], before, result["final"])
        rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, f"fullscreen-{direction}.png")})
        row(not glitches, f"fullscreen.{direction}.no_zoom", {"bug": 12, "glitch_frames": glitches,
                                                              "pass_if": "visualViewport.scale 1 and devicePixelRatio unchanged every frame"})
        row(not over, f"fullscreen.{direction}.no_overflow", {"bug": 12, "samples": over, "before": before, "final": result["final"],
                                                              "pass_if": "page view never larger than start and end, never outside the window"})
        row(result["lag_ms"] is not None and result["lag_ms"] <= LAG_MS and fits(viewport, result["final"]),
            f"fullscreen.{direction}.page_follows",
            {"bug": 12, "lag_ms": result["lag_ms"], "pane_final_ms": result["pane_final_ms"], "viewport": viewport,
             "page_view": result["final"], "full_screen": is_full_screen(),
             "pass_if": f"page matches the pane <= {LAG_MS} ms after the pane settles, then within 1 pt"})
    if is_full_screen():
        action("toggleFullScreen")
        wait(lambda: not is_full_screen(), 5)


def check_pane_zoom(tab, pane):
    """Bug 14: Cmd-Shift-Enter (toggleSplitZoom) on the page's pane: zoomed, the page's view is at least 1.3x its
    area, exactly one page view shows, no page child window or overlay panel, and the page fits its view within 1 pt
    within LAG_MS of the pane; unzoomed, the view is back to its first frame within 1 pt and the page fits it."""
    before = page_view(pane)
    if not before:
        row("INFO", "pane_zoom", {"note": "no in-tree page view"})
        return
    record("pane_zoom", 8)
    action("tab.focus", target=f"tab:{tab}")
    time.sleep(0.3)  # test harness: focus lands
    for direction in ("zoom", "unzoom"):
        result = track(pane, tab, lambda: rpc("debug.key", {"key": "return", "modifiers": ["command", "shift"]}), 6)
        layers = main_layers()
        shown = [v for v in layers.get("page_views") or [] if not v.get("parked")]
        viewport = page_json("window.viewport()", tab)
        final = result["final"]
        clean = layers.get("overlay_panel") is None and not layers.get("child_window_violations") \
            and not any(c.get("role") == "content" and c.get("visible") for c in layers.get("child_windows") or [])
        if direction == "zoom":
            sized = bool(final) and final[2] * final[3] >= 1.3 * before[2] * before[3]
        else:
            sized = bool(final) and all(abs(a - b) <= FIT_PX for a, b in zip(final, before))
        rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, f"pane-{direction}.png")})
        check_paint(pane, direction)
        row(sized and len(shown) == 1 and clean and fits(viewport, final) and result["lag_ms"] is not None
            and result["lag_ms"] <= LAG_MS and not zoom_glitch(result["vp"]), f"pane_zoom.{direction}",
            {"bug": 14, "before": before, "final": final, "shown_page_views": len(shown), "clean": clean,
             "viewport": viewport, "lag_ms": result["lag_ms"], "glitches": zoom_glitch(result["vp"]),
             "pass_if": "zoom: area >= 1.3x; unzoom: back within 1 pt; one page view, no panel/page window, page fits <= 100 ms"})


def check_popup_float(tab, pane):
    """Bug 10: a window.open popup asking for 520 x 420 floats at that size: its page's innerWidth/innerHeight are 520
    x 420 within 2 pt and its window is smaller than the screen's visible frame, with the opener windowed and with the
    opener in full screen (the popup must not join it as a full-screen window)."""
    for mode in ("windowed", "opener_fullscreen"):
        if mode == "opener_fullscreen":
            action("toggleFullScreen")
            if not wait(is_full_screen, 6):
                row(False, "popup_float.opener_fullscreen", {"bug": 10, "note": "the window did not enter full screen"})
                continue
            time.sleep(1.0)  # test harness: the full-screen space settles
        rpc("debug.popups", {"action": "close"})
        centre = page_json("JSON.stringify((r => [r.x + r.width / 2, r.y + r.height / 2])(document.getElementById('pop').getBoundingClientRect()))", tab)
        click = rpc("debug.mouse", {"target": "page", "pane": pane, "x": centre[0], "y": centre[1]}) if centre else None
        opened = wait(lambda: popup_index() is not None, 8)
        time.sleep(1.0)  # test harness: the popup settles at its size
        panels = (rpc("debug.popups") or {}).get("panels") or []
        panel = next((p for p in panels if "/popup" in str(p.get("url") or "")), None)
        inner = page_json("JSON.stringify(window.__pop ? [window.__pop.innerWidth, window.__pop.innerHeight] : null)", tab)
        layers = main_layers()
        screen = layers.get("screen_visible_frame") or layers.get("screen_frame")
        frame = (panel or {}).get("frame")
        if isinstance(frame, dict):  # debug.popups frames are {x, y, width, height}
            frame = [frame.get("x"), frame.get("y"), frame.get("width"), frame.get("height")]
        floats = bool(frame and screen) and frame[2] < screen[2] - 40 and frame[3] < screen[3] - 40
        sized = bool(inner) and abs(inner[0] - 520) <= 2 and abs(inner[1] - 420) <= 2
        if panel:
            rpc("debug.popups", {"snapshot_dir": os.path.join(opts.out, f"popup-{mode}")})
        row(bool(opened) and floats and sized, f"popup_float.{mode}",
            {"bug": 10, "click": click, "popup_frame": frame, "screen_visible_frame": screen, "popup_inner": inner,
             "opener_full_screen": is_full_screen(), "pass_if": "popup inner 520x420 within 2 pt, window smaller than the screen"})
        rpc("debug.popups", {"action": "close"})
        time.sleep(0.5)  # test harness: the popup closes
    if is_full_screen():
        action("toggleFullScreen")
        wait(lambda: not is_full_screen(), 6)


def check_omnibar_narrow(tab, pane):
    """Bug 15: with a long URL, at page-pane widths 480, 360, 300 and 260 pt (divider drags), the omnibar's text area
    (and its field) ends before every icon to its right inside the bar, starts after every icon to its left, and the
    bar stays inside the toolbar (debug.omnibar pointer frames, window points from the top left)."""
    layers = main_layers()
    frame = page_view(pane, layers)
    if not frame:
        row("INFO", "omnibar_narrow", {"note": "no in-tree page view"})
        return
    for width in (480, 360, 300, 260):
        layers = main_layers()
        frame = page_view(pane, layers)
        divider = vertical_divider_near(frame[0], layers) if frame else None
        if divider and abs(frame[2] - width) > 4:
            drag_divider(divider, frame[2] - width, steps=10)
            time.sleep(0.8)  # test harness: the pane settles
        frame = page_view(pane)
        report = rpc("debug.omnibar", {"pane": pane}) or {}
        frames = ((report.get("pointer") or {}).get("frames")) or {}
        text, area, bar, toolbar = frames.get("text"), frames.get("text_area"), frames.get("bar"), frames.get("toolbar")
        problems = []
        if not (area and bar):
            problems.append("no text_area or bar frame")
        else:
            for name, f in frames.items():
                if name in ("text", "text_area", "bar", "toolbar"):
                    continue
                inside = f[0] >= bar[0] - 0.5 and f[0] + f[2] <= bar[0] + bar[2] + 0.5 and f[1] < bar[1] + bar[3] and f[1] + f[3] > bar[1]
                if not inside or f[2] <= 0:
                    continue
                for label, r in (("text_area", area), ("text", text)):
                    if not r:
                        continue
                    if f[0] >= r[0] and r[0] + r[2] > f[0] + 0.5:
                        problems.append(f"{label} runs under {name} by {round(r[0] + r[2] - f[0], 1)} pt")
                    if f[0] + f[2] <= r[0] + r[2] and f[0] < r[0] and f[0] + f[2] > r[0] + 0.5:
                        problems.append(f"{name} overlaps the start of {label}")
            if toolbar and bar[0] + bar[2] > toolbar[0] + toolbar[2] + 0.5:
                problems.append("bar past the toolbar's right edge")
        rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, f"omnibar-{width}.png")})
        row(not problems, f"omnibar_narrow.{width}",
            {"bug": 15, "pane_width": frame[2] if frame else None, "problems": problems[:6],
             "frames": {k: v for k, v in frames.items()}, "text": report.get("text"),
             "pass_if": "text area ends before every icon to its right in the bar; bar inside the toolbar"})


# ---- Motion paint rows (QA sweep 06675353 D2 and D5): the page's real pixels in every captured frame of a zoom and a
# window resize, judged against the page views' frames that debug.layers gave around each capture. ----

PAGE_A_BG, PAGE_B_BG = (0x22, 0x44, 0x66), (0x66, 0x44, 0x22)


def near(px, rgb, tol=16):
    return all(abs(a - b) <= tol for a, b in zip(px, rgb))


class MotionCapture:
    """Window captures (CuaDriver, the window server's pixels) on two threads and debug.layers samples on a third, all
    stamped against one clock, until stop(). Each capture is judged against the layer samples taken while it ran."""

    def __init__(self, folder):
        self.folder = folder
        os.makedirs(folder, exist_ok=True)
        self.pid = RAW.get("pid")
        self.window = main_window_id(self.pid) if CUA_DRIVER else None
        self.frames, self.samples, self.running, self.threads, self.count = [], [], False, [], 0
        self.lock = threading.Lock()

    def start(self):
        if not self.window:
            return False
        self.running = True
        self.threads = [threading.Thread(target=self._capture, daemon=True) for _ in range(2)]
        self.threads.append(threading.Thread(target=self._layers, daemon=True))
        for thread in self.threads:
            thread.start()
        return True

    def _capture(self):
        while self.running:
            with self.lock:
                self.count += 1
                path = os.path.join(self.folder, f"cap-{self.count:04d}.png")
            started = time.time()
            cua("get_window_state", {"pid": self.pid, "window_id": self.window, "include_accessibility_tree": False,
                                     "screenshot_out_file": path, "max_image_dimension": 1000})
            ended = time.time()
            if os.path.exists(path):
                self.frames.append({"path": path, "t0": started, "t1": ended})

    def _layers(self):
        while self.running:
            t = time.time()
            layers = main_layers()
            views = {v.get("pane"): v.get("frame_in_window") for v in layers.get("page_views") or [] if not v.get("parked")}
            self.samples.append({"t": t, "window": layers.get("frame"), "views": views})
            time.sleep(0.008)  # test harness: about two layer reads a display frame

    def stop(self):
        self.running = False
        for thread in self.threads:
            thread.join(timeout=15)

    def around(self, frame, slack=0.03):
        return [s for s in self.samples if frame["t0"] - slack <= s["t"] <= frame["t1"] + slack and s["window"]]


def top_band_ok(rows, width, sx, sy, window, view):
    """Whether the page's magenta top band starts at `view`'s top edge (window points, bottom-left), within PAINT_PX + 1
    pt, in the columns at 30, 50 and 70% of the view; and those columns' first band rows, for the detail."""
    x, y, w, h = view
    top = window[3] - (y + h)
    found = []
    for f in (0.3, 0.5, 0.7):
        col = max(0, min(width - 1, int((x + w * f) * sx)))
        first = None
        y0, y1 = max(0, int((top - 24) * sy)), min(len(rows), int((top + 24) * sy))
        for yy in range(y0, y1):
            r, g, b = rows[yy][3 * col], rows[yy][3 * col + 1], rows[yy][3 * col + 2]
            if r > 200 and g < 90 and b > 200:
                first = round(yy / sy, 1)
                break
        found.append(first)
    ok = all(v is not None and abs(v - top) <= PAINT_PX + 1 for v in found)
    return ok, {"view_top": round(top, 1), "band_top": found}


def region_colors(rows, width, sx, sy, window, view, colors):
    """Share of sampled pixels in `view` (window points) near each of `colors`."""
    x, y, w, h = view
    top = window[3] - (y + h)
    counts, total = [0] * len(colors), 0
    for yy in range(int((top + 30) * sy), int((top + h - 4) * sy), 6):
        if yy < 0 or yy >= len(rows):
            continue
        for xx in range(int((x + 4) * sx), int((x + w - 4) * sx), 6):
            if xx < 0 or xx >= width:
                continue
            px = rows[yy][3 * xx:3 * xx + 3]
            total += 1
            for i, c in enumerate(colors):
                if near(px, c):
                    counts[i] += 1
    return [round(c / total, 3) if total else 0 for c in counts]


def judge_frames(cap, t_start, panes, pane_rules):
    """Each capture after t_start, against the layer samples around it: pane_rules(frame, rows, width, sx, sy, sample)
    returns a list of problems (empty: the frame is right for some sample taken while it ran)."""
    bad, judged = [], 0
    for frame in sorted(cap.frames, key=lambda f: f["t0"]):
        if frame["t0"] < t_start:
            continue
        samples = cap.around(frame)
        if not samples:
            continue
        try:
            width, height, rows = png_rgb(frame["path"])
        except Exception as error:
            bad.append({"file": os.path.basename(frame["path"]), "error": repr(error)})
            continue
        # Only samples of the window at the capture's own size judge it (the window changes size at 60 Hz in a resize,
        # a capture takes longer); a capture no sample matches is not judged.
        sized = [smp for smp in samples if abs(width / smp["window"][2] - height / smp["window"][3]) <= 0.02]
        if not sized:
            continue
        judged += 1
        best = None
        for sample in sized:
            window = sample["window"]
            sx, sy = width / window[2], height / window[3]
            problems = pane_rules(rows, width, sx, sy, sample)
            if not problems:
                best = None
                break
            best = problems if best is None or len(problems) < len(best) else best
        if best:
            bad.append({"ms": round((frame["t0"] - t_start) * 1000), "file": os.path.basename(frame["path"]), "problems": best[:3]})
    return judged, bad


def open_page_in(pane_tab, query):
    """Opens the layout page (`query`) as a new tab in the pane of `pane_tab`; its tab id or None."""
    action("tab.focus", target=f"tab:{pane_tab}")
    time.sleep(0.4)  # test harness: focus lands
    action("openBrowser.chromium", {"url": URL + "layout?" + query})
    got = wait(lambda: (lambda r: r if r.get("value") is True else None)(
        page_eval(f"location.search === '?{query}' && window.layoutReady === true")), 60, 0.5)
    return got.get("tab") if got else None


def check_zoom_motion(tab, pane):
    """QA sweep D2: two layout pages side by side (A #246, B #642), Cmd-Shift-Return on A and back, with window captures
    through each. zoom_motion.zoom: no frame shows B's pane area as its bare background without its page (B blank while
    A grows), and from 300 ms after the trigger (the zoom spring is about 220 ms) A's top band is at A's view top.
    zoom_motion.unzoom: from 300 ms after the trigger, A's colour never shows inside B's view (A drawn at its zoomed size
    over B) and both pages' top bands are at their views' tops."""
    terminal_tab = next((c for c in ((RAW.get("split") or {}).get("created") or []) if str(c).startswith("tab_")), None)
    if not terminal_tab or not page_view(pane):
        row("INFO", "zoom_motion", {"note": "no terminal pane or no page view", "terminal_tab": terminal_tab})
        return
    page_eval("document.body.style.background = '#246'; true", tab)
    b_tab = open_page_in(terminal_tab, "zoomb&c=664422")
    b_pane = page_pane(b_tab) if b_tab else None
    RAW["zoom_motion_b"] = {"tab": b_tab, "pane": b_pane}
    if not b_pane or not page_view(b_pane):
        row(False, "zoom_motion.setup", {"b_tab": b_tab, "b_pane": b_pane})
        return
    time.sleep(1.0)  # test harness: both pages draw
    before = {"a": page_view(pane), "b": page_view(b_pane)}
    action("tab.focus", target=f"tab:{tab}")
    time.sleep(0.4)  # test harness: focus lands
    for direction in ("zoom", "unzoom"):
        cap = MotionCapture(os.path.join(opts.out, f"zoom-motion-{direction}"))
        if not cap.start():
            row("INFO", f"zoom_motion.{direction}", {"note": "no window captures on this host"})
            return
        time.sleep(0.3)  # test harness: captures from before the trigger
        t_start = time.time()
        rpc("debug.key", {"key": "return", "modifiers": ["command", "shift"]})
        time.sleep(1.5)  # test harness: the zoom and its spring end, then settled frames
        cap.stop()

        def rules(rows, width, sx, sy, sample, direction=direction, t_start=t_start):
            problems, window, views = [], sample["window"], sample["views"]
            late = sample["t"] - t_start > 0.3
            a, b = views.get(pane), views.get(b_pane)
            if direction == "zoom":
                region = before["b"]
                share = region_colors(rows, width, sx, sy, window, region, [PAGE_A_BG, PAGE_B_BG])
                band, _ = top_band_ok(rows, width, sx, sy, window, region)
                if share[1] > 0.6 and not band and b is not None:
                    problems.append({"b_blank": share})
                if late and a:
                    ok, detail = top_band_ok(rows, width, sx, sy, window, a)
                    if not ok:
                        problems.append(dict(detail, page="a"))
            elif late:
                if b:
                    share = region_colors(rows, width, sx, sy, window, b, [PAGE_A_BG, PAGE_B_BG])
                    if share[0] > 0.02:
                        problems.append({"a_over_b": share})
                for name, view in (("a", a), ("b", b)):
                    if view:
                        ok, detail = top_band_ok(rows, width, sx, sy, window, view)
                        if not ok:
                            problems.append(dict(detail, page=name))
            return problems

        judged, bad = judge_frames(cap, t_start, [pane, b_pane], rules)
        RAW[f"zoom_motion_{direction}"] = {"judged": judged, "bad": bad, "samples": len(cap.samples)}
        if not judged:
            row("INFO", f"zoom_motion.{direction}", {"note": "no capture matched a layer sample", "captures": len(cap.frames)})
            continue
        row(not bad, f"zoom_motion.{direction}",
            {"bug": "sweep D2", "judged": judged, "bad_frames": len(bad), "first_bad": bad[:4], "before": before,
             "pass_if": "zoom: B never blank, A's top band at its top from 300 ms; unzoom: from 300 ms A never inside B, both bands at the top"})
    RAW["zoom_motion_tabs"] = [tab, b_tab]


def check_grid_resize(tab, pane):
    """QA sweep D5: a 2x2 grid of layout pages; the window goes 400 x 200 pt smaller in 45 steps at 60 Hz and back, the
    way Rectangle or a person's edge drag sets frames, with window captures through it. grid_resize.top: in every
    captured frame, each page's magenta top band starts at its view's top within 3 pt (the sweep saw every page drawn
    15 to 20 pt high, its top under the omnibar, for about 1 s while the window grew back). grid_resize.settle: 1 s after
    the last step, check_paint's band rows for each page."""
    b_tab = (RAW.get("zoom_motion_b") or {}).get("tab")
    if not b_tab:
        terminal_tab = next((c for c in ((RAW.get("split") or {}).get("created") or []) if str(c).startswith("tab_")), None)
        b_tab = open_page_in(terminal_tab, "gridb&c=664422") if terminal_tab else None
    tabs = [tab, b_tab]
    for source, query in ((tab, "gridc&c=225522"), (b_tab, "gridd&c=442266")):
        if not source:
            break
        action("tab.focus", target=f"tab:{source}")
        time.sleep(0.3)  # test harness: focus lands
        split = action("splitDown")
        created = next((c for c in (split or {}).get("created") or [] if str(c).startswith("tab_")), None)
        time.sleep(1.0)  # test harness: the new pane's terminal attaches
        tabs.append(open_page_in(created, query) if created else None)
    panes = [page_pane(t) if t else None for t in tabs]
    RAW["grid_resize_setup"] = {"tabs": tabs, "panes": panes}
    if not all(panes) or len(set(panes)) != 4 or not all(page_view(p) for p in panes):
        row(False, "grid_resize.setup", {"tabs": tabs, "panes": panes})
        return
    time.sleep(1.5)  # test harness: four pages draw
    start = main_layers().get("frame")
    top = start[1] + start[3]
    steps = [[start[0], top - (start[3] - 200 * k / 45), start[2] - 400 * k / 45, start[3] - 200 * k / 45] for k in range(1, 46)]
    steps += steps[::-1][1:] + [start]
    cap = MotionCapture(os.path.join(opts.out, "grid-resize"))
    if not cap.start():
        row("INFO", "grid_resize.top", {"note": "no window captures on this host"})
        return
    record("grid_resize", 6)
    time.sleep(0.3)  # test harness: captures from before the first step
    t_start = time.time()
    for i, frame in enumerate(steps):
        rpc("debug.window_frame", {"frame": frame})
        next_at = t_start + (i + 1) / 60
        if next_at > time.time():
            time.sleep(next_at - time.time())  # test harness: one frame a display refresh, as a drag sets them
    time.sleep(1.5)  # test harness: the pages settle
    cap.stop()

    def rules(rows, width, sx, sy, sample):
        problems = []
        for p in panes:
            view = sample["views"].get(p)
            if not view:
                continue
            ok, detail = top_band_ok(rows, width, sx, sy, sample["window"], view)
            if not ok:
                problems.append(dict(detail, pane=p))
        return problems

    judged, bad = judge_frames(cap, t_start, panes, rules)
    RAW["grid_resize"] = {"judged": judged, "bad": bad, "samples": len(cap.samples), "steps": len(steps)}
    if not judged:
        row("INFO", "grid_resize.top", {"note": "no capture matched a layer sample", "captures": len(cap.frames)})
    else:
        row(not bad, "grid_resize.top",
            {"bug": "sweep D5", "judged": judged, "bad_frames": len(bad), "first_bad": bad[:4],
             "pass_if": "each page's top band at its view's top within 3 pt in every captured frame of the resize"})
    for i, p in enumerate(panes):
        check_paint(p, f"grid{i}")


REGRESSION_CHECKS = ("pane_fit", "divider_resize", "window_resize", "fullscreen", "pane_zoom", "popup_float", "omnibar_narrow",
                     "zoom_motion", "grid_resize")


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1300,860",
       "CMUX_IN_TREE_PAGES": "1" if opts.in_tree == "on" else "0"}
# Through bench_launch (fresh saved state, a refusal when another app of the tag runs, and a refusal when the app comes
# up in the other in-tree mode): a bare Popen answered by a leftover app of the tag reported in_tree off with
# CMUX_IN_TREE_PAGES=1 (step verify-live-e67776ff-cmux19).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import launch_app  # noqa: E402
app = None
try:
    try:
        app, SOCKET = launch_app(opts.app, env, os.path.join(opts.out, "app.log"), timeout=120,
                                 on_start=lambda p: RAW.__setitem__("pid", p.pid))
    except SystemExit as error:  # bench_launch's LaunchError (it printed its report)
        row(False, "launch", str(error)[:300])
        raise SystemExit
    time.sleep(2)  # test harness: the first terminal attaches
    terminal_tab = (rpc("debug.focus") or {})
    RAW["focus_at_launch"] = terminal_tab
    opened = action("openBrowser.chromium", {"url": URL})
    RAW["open"] = opened
    ready = wait(lambda: (lambda r: r if r.get("value") is True else None)(page_eval("document.readyState === 'complete' && !!window.startSteal")), 60, 0.5)
    page_tab = ready.get("tab") if ready else None
    RAW["page_tab"] = page_tab
    if not page_tab:
        row(False, "page", {"open": opened, "cef": rpc("debug.cef")})
        raise SystemExit
    # Terminal on the left, page on the right: split the page's pane and put a terminal in the new pane.
    RAW["split"] = action("splitRight")
    time.sleep(1.5)  # test harness: the new pane's terminal attaches
    focus_after_split = rpc("debug.focus")
    RAW["focus_after_split"] = focus_after_split

    status = (rpc("debug.cef") or {}).get("in_tree")
    if "mode" in CHECKS:
        row(status == "on" if opts.in_tree == "on" else status in ("off", None), "mode", {"asked": opts.in_tree, "in_tree": status})

    if "census" in CHECKS:
        first = census("loaded")
        time.sleep(opts.idle)
        second = census("idle")
        pw1, pw2 = first["per_window"], second["per_window"]
        no_page_windows = all(w["content_child_windows"] == 0 for w in pw2)
        no_violations = all(not w["violations"] for w in pw2)
        flat = [(a["reorders"], b["reorders"], a["divider_catcher_updates"], b["divider_catcher_updates"]) for a, b in zip(pw1, pw2)]
        flat_ok = all(r1 == r2 and d1 == d2 for r1, r2, d1, d2 in flat)
        if opts.in_tree == "on":
            browsers = [b for w in pw2 for b in w["browsers"] if b.get("engine") is not None]
            in_tree_pages = bool(browsers) and all(b.get("presentation") == "in_tree" and b.get("widget_drawing") == 0 for b in browsers)
            listed = sum(w["page_views"] for w in pw2) >= len(browsers) > 0
            no_panel = all(w["overlay_panel"] is None for w in pw2)
            row(no_page_windows and no_violations and in_tree_pages and listed and no_panel and flat_ok, "census",
                {"idle": second, "flat(reorders,catcher)": flat})
        else:
            row("INFO", "census", {"idle": second, "flat(reorders,catcher)": flat})
            row(no_violations and flat_ok, "census.flat", {"violations": [w["violations"] for w in pw2], "flat": flat})

    if "focus" in CHECKS:
        record("focus")
        # The new pane (the terminal) has the keyboard after the split; the page starts stealing.
        RAW["steal_start"] = page_eval("window.startSteal()", page_tab)
        time.sleep(0.5)  # test harness: the page's timer runs a few times before the first key
        before = terminal_text()
        focus_before = rpc("debug.focus")
        replies = []
        for ch in MARKER:
            replies.append(rpc("debug.key", {"key": ch}))
            time.sleep(0.02)  # test harness: the page's 20 ms timer interleaves with the keys
        arrived = wait(lambda: MARKER in terminal_text(), 5, 0.2)
        steals = page_eval("window.stopSteal()", page_tab).get("value")
        page_keys = page_eval("JSON.stringify(window.__keys)", page_tab).get("value")
        after = terminal_text()
        focus_after = rpc("debug.focus")
        RAW["focus_check"] = {"focus_before": focus_before, "focus_after": focus_after, "key_replies": replies[:3]}
        tail = after[-400:]
        row(bool(arrived) and page_keys in ("[]", None), "focus.marker",
            {"marker_whole_in_terminal": bool(arrived), "page_steal_calls": steals, "page_keys": page_keys,
             "terminal_tail": tail.replace(before[-200:], "")[-160:]})
        rpc("debug.key", {"key": "u", "modifiers": ["control"]})

    if "shortcuts" in CHECKS:
        record("shortcuts")
        # Focus the page: its tab, then a click in its field (debug.mouse into the page's pane is not needed: tab.focus
        # with focus makes the page the first responder, and field.focus() puts the caret in the field).
        RAW["page_focus"] = action("tab.focus", target=f"tab:{page_tab}")
        page_eval("document.getElementById('field').focus(); true", page_tab)
        time.sleep(0.4)  # test harness: focus lands
        focus = rpc("debug.focus")
        has_focus = page_eval("document.hasFocus()", page_tab).get("value")
        RAW["shortcut_focus"] = focus
        row("INFO", "shortcuts.page_focus", {"document_hasFocus": has_focus, "debug.focus": json.dumps(focus)[:300]})
        dry = {}
        for name, args in (("cmd-t", {"key": "t", "modifiers": ["command"]}), ("cmd-w", {"key": "w", "modifiers": ["command"]}),
                           ("cmd-d", {"key": "d", "modifiers": ["command"]}), ("cmd-shift-p", {"key": "P", "modifiers": ["command"]})):
            dry[name] = rpc("debug.key", dict(args, dry_run=True))
        RAW["shortcut_dry"] = dry
        # The router claims a shortcut only with a `.run` decision, whose action id it names; anything else lets the
        # key go on to the responder chain (the page).
        row(all(isinstance(v, dict) and isinstance(v.get("action"), str) and v.get("action") for v in dry.values()),
            "shortcuts.dry_run", {k: {"action": (v or {}).get("action"), "decision": str((v or {}).get("decision"))[:80],
                                      "focus": (v or {}).get("focus")} for k, v in dry.items()})
        tabs0 = tab_count()
        rpc("debug.key", {"key": "t", "modifiers": ["command"]})
        tabs1 = wait(lambda: (lambda n: n if n is not None and tabs0 is not None and n > tabs0 else None)(tab_count()), 8)
        row(bool(tabs1), "shortcuts.cmd_t", {"tabs_before": tabs0, "tabs_after": tabs1 or tab_count()})
        if tabs1:
            rpc("debug.key", {"key": "w", "modifiers": ["command"]})
            tabs2 = wait(lambda: (lambda n: n if n is not None and n < tabs1 else None)(tab_count()), 8)
            row(bool(tabs2), "shortcuts.cmd_w", {"tabs_before": tabs1, "tabs_after": tabs2 or tab_count()})
        # The palette from the page.
        action("tab.focus", target=f"tab:{page_tab}")
        page_eval("document.getElementById('field').focus(); true", page_tab)
        time.sleep(0.3)  # test harness: focus lands
        opens0 = len((rpc("debug.timings") or {}).get("palette_opens") or [])
        rpc("debug.key", {"key": "P", "modifiers": ["command"]})
        opened_palette = wait(lambda: len((rpc("debug.timings") or {}).get("palette_opens") or []) > opens0, 5)
        row(bool(opened_palette), "shortcuts.palette", {"palette_opens_before": opens0})
        rpc("debug.key", {"key": "escape", "target": "palette"})
        time.sleep(0.3)  # test harness: the palette closes

    if "prompts" in CHECKS:
        record("prompts")
        def snapshot():
            return {"dialog": rpc("debug.dialog"), "popups": rpc("debug.popups"),
                    # kind, title and visibility: the open panel is made ahead (MadeAheadOpenPanel) and sits hidden
                    # in the window list until a chooser shows it as a sheet, so only `visible` changes.
                    "window_list": sorted((str(w.get("kind")), w.get("title") or "", bool(w.get("visible")),
                                           w.get("parent") is not None)
                                          for w in ((rpc("debug.window_list") or {}).get("windows") or []))}
        for name, script in (("alert", "window.later('alert', () => alert('in-tree alert'))"),
                             ("confirm", "window.later('confirm', () => confirm('in-tree confirm'))"),
                             ("prompt", "window.later('prompt', () => prompt('in-tree prompt', 'x'))"),
                             ("file", "document.getElementById('file').click(); true"),
                             ("download", "document.getElementById('dl').click(); true")):
            action("tab.focus", target=f"tab:{page_tab}")
            base = snapshot()
            if name == "file":
                # A chooser needs a user gesture: a script's click() is dropped by Chromium, so click the input with a
                # page click (debug.mouse target page) at its center, in the focused pane's page.
                rect = page_eval("JSON.stringify((r => [r.x + r.width / 2, r.y + r.height / 2])("
                                 "document.getElementById('file').getBoundingClientRect()))", page_tab)
                try:
                    x, y = json.loads(rect["value"] if isinstance(rect, dict) else rect)
                    fired = {"rect": [x, y], "click": rpc("debug.mouse", {"target": "page", "x": x, "y": y})}
                except Exception as error:
                    fired = {"error": repr(error), "rect": rect}
            else:
                fired = page_eval(script, page_tab)
            time.sleep(1.5)  # test harness: the prompt shows
            shown = snapshot()
            changed = json.dumps(shown, sort_keys=True, default=str) != json.dumps(base, sort_keys=True, default=str)
            RAW[f"prompt_{name}"] = {"before": base, "after": shown, "fired": fired}
            detail = {"fired": fired, "after": json.dumps(shown, default=str)[:400]}
            if name == "file":
                # The chooser shows as a sheet on the cmux window (in tree: cmux's open panel) or as a panel.
                new = [w for w in shown["window_list"] if w[2] and w not in base["window_list"]]
                detail["new_visible_windows"] = new
                changed = changed and bool(new)
            if name == "file":
                # Does this host's panel service give a live panel at all? (cmux answers a chooser with cancel when its
                # panel comes back dead: MadeAheadOpenPanel.panel() nil.) Same app, a panel shown and cancelled.
                rpc("debug.key", {"key": "escape"})
                time.sleep(0.5)  # test harness: any sheet closes
                detail["host_panel_probe"] = rpc("debug.open_panel_bench", {"mode": "fresh"}, timeout=90)
                detail["app_file_dialogs"] = (rpc("debug.cef") or {}).get("file_dialogs")
                detail["input_events"] = page_eval("JSON.stringify(window.__file)", page_tab).get("value")
                detail["user_activation"] = page_eval("navigator.userActivation && navigator.userActivation.hasBeenActive", page_tab).get("value")
            row(changed, f"prompts.{name}", detail)
            rpc("debug.key", {"key": "escape"})
            time.sleep(0.5)  # test harness: the prompt closes
        RAW["prompt_results"] = page_eval("JSON.stringify(window.__results)", page_tab)
    if "file_after_popup" in CHECKS:
        file_after_popup(page_tab)
    if CHECKS & set(REGRESSION_CHECKS):
        # Bugs 10 to 15 (in-tree-regressions.md) on the layout probe page (a long query: the omnibar's text is long),
        # in the page's pane beside the terminal; the probe page comes back after for the rows below.
        action("tab.focus", target=f"tab:{page_tab}")
        layout_ready = open_layout(page_tab, "?" + "long-url-segment-" * 12)
        pane = page_pane(page_tab)
        RAW["regressions_pane"] = pane
        if not layout_ready or not pane:
            row(False, "regressions.setup", {"layout_ready": layout_ready, "pane": pane})
        else:
            time.sleep(0.5)  # test harness: the layout page draws
            for name, run in (("pane_fit", check_pane_fit), ("divider_resize", check_divider_resize),
                              ("window_resize", check_window_resize), ("fullscreen", check_fullscreen),
                              ("pane_zoom", check_pane_zoom), ("popup_float", check_popup_float),
                              ("omnibar_narrow", check_omnibar_narrow),
                              # Last: they open more pages and split the window into a grid.
                              ("zoom_motion", check_zoom_motion), ("grid_resize", check_grid_resize)):
                if name in CHECKS:
                    try:
                        run(page_tab, pane)
                    except Exception as error:  # one broken row never hides the others
                        row(False, f"{name}.error", {"error": repr(error)[:300]})
        page_eval(f"location.href = {json.dumps(URL)}; true", page_tab)
        wait(lambda: page_eval("document.readyState === 'complete' && !!window.startSteal", page_tab).get("value") is True, 30, 0.3)
    if "two_pages" in CHECKS:
        record("two_pages")
        # Two Chromium pages side by side in one workspace: the terminal's pane (left) gets a second page, so both panes
        # show a page at once. Each must be in tree (its view in the cmux window, drawing), and a click and keys in each
        # must reach that page alone.
        page_eval("document.body.style.background = '#642'; document.title = 'page A'; true", page_tab)
        # The terminal's tab (made by the split): focus it so the second page opens in that pane, beside the first.
        terminal_tab = next((c for c in ((RAW.get("split") or {}).get("created") or []) if str(c).startswith("tab_")), None)
        RAW["two_terminal_tab"] = terminal_tab
        if terminal_tab:
            action("tab.focus", target=f"tab:{terminal_tab}")
        time.sleep(0.4)  # test harness: focus lands
        RAW["two_open"] = action("openBrowser.chromium", {"url": URL + "?b"})
        second = wait(lambda: (lambda r: r if r.get("value") is True and r.get("tab") not in (None, page_tab) else None)(
            page_eval("location.search === '?b' && document.readyState === 'complete'")), 60, 0.5)
        second_tab = second.get("tab") if second else None
        RAW["second_tab"] = second_tab
        if not second_tab:
            row(False, "two_pages.open", {"open": RAW["two_open"]})
        else:
            page_eval("document.body.style.background = '#264'; document.title = 'page B'; true", second_tab)
            time.sleep(1.0)  # test harness: both pages draw
            shot = rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "two-pages.png")})
            both = census("two_pages")
            browsers = [b for w in both["per_window"] for b in w["browsers"] if b.get("engine") is not None]
            panes = {b.get("pane") for b in browsers}
            if opts.in_tree == "on":
                ok = len(panes) >= 2 and all(b.get("presentation") == "in_tree" and b.get("rwhv_in_window") for b in browsers)
            else:
                ok = len(panes) >= 2
            row(ok, "two_pages.shown", {"panes": sorted(map(str, panes)), "browsers": browsers, "snapshot": shot})
            typed = {}
            for label, tab, text in (("A", page_tab, "left"), ("B", second_tab, "right")):
                page_eval("window.__keys = []; true", tab)
                action("tab.focus", target=f"tab:{tab}")
                rect = page_eval("JSON.stringify((r => [r.x + r.width / 2, r.y + r.height / 2])("
                                 "document.getElementById('field').getBoundingClientRect()))", tab)
                try:
                    x, y = json.loads(rect.get("value"))
                    click = rpc("debug.mouse", {"target": "page", "x": x, "y": y})
                except Exception as error:
                    click = {"error": repr(error)}
                time.sleep(0.3)  # test harness: the click focuses the field
                for ch in text:
                    rpc("debug.key", {"key": ch})
                time.sleep(0.4)  # test harness: the keys reach the page
                typed[label] = {"click": click, "value": page_eval("document.getElementById('field').value", tab).get("value")}
            row(typed["A"]["value"] == "left" and typed["B"]["value"] == "right", "two_pages.input", typed)
            rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "two-pages-typed.png")})
    if "reveal" in CHECKS:
        record("reveal")
        action("tab.focus", target=f"tab:{page_tab}")
        reveal(page_tab, "hide", "hide")
        reveal(page_tab, "cover", "cover")
        # As in the person's recording: a docked DevTools open in the page's pane.
        action("tab.focus", target=f"tab:{page_tab}")
        RAW["reveal_devtools_open"] = action("devtools.openDocked")
        time.sleep(3.0)  # test harness: the DevTools frontend loads and draws
        reveal(page_tab, "hide", "hide_devtools")
    RAW["snapshot"] = rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "window.png")})
except SystemExit:
    pass
finally:
    try:
        if app is not None:
            rpc("debug.quit", timeout=10)
            app.wait(timeout=15)
    except Exception:
        app.send_signal(signal.SIGKILL)
    server.shutdown()
failed = [r for r in ROWS if r["verdict"] == "FAIL"]
report = {"in_tree_requested": opts.in_tree, "rows": ROWS, "failed": len(failed), "raw": RAW}
with open(opts.json or os.path.join(opts.out, "in-tree-live.json"), "w") as f:
    json.dump(report, f, indent=1, default=str)
print(f"in-tree-live-checks: {len(ROWS) - len(failed)} of {len(ROWS)} rows pass (in-tree {opts.in_tree})", flush=True)
sys.exit(1 if failed else 0)

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
                  elementFromPoint == event.target
  divider_resize  (11) a divider drag beside the page: at most 2 missed display frames, p95 within 1.5 refresh
                  intervals, the page follows during the drag (>= 10 widths) and fits the pane <= 100 ms after it settles
  window_resize   (11) the window's corner dragged out and back: the same frame budget and settle rule
  fullscreen      (12) enter and exit: no pinch scale or devicePixelRatio change in any frame, the page view never
                  larger than its start and end size or outside the window, the page fits the pane <= 100 ms after it
  live_resize     (17 to 21) by pixels, the app's own recorder (debug.motion record_*, one device row through the
                  page; the layout page's cyan left and magenta right edge strips): every composited frame of three
                  divider drags, three window corner drags, full screen enter and exit and a workspace switch is right,
                  gutter (stale narrower), clipped (stale wider) or blank; rows give the counts, the longest wrong run,
                  frames per second and gaps over 50 ms while moving, and the settle time after the input
  pane_zoom       (14) Cmd-Shift-Return zoom and unzoom of the page's pane: area >= 1.3x, then back within 1 pt; one
                  page view, no panel or page window, the page fits <= 100 ms after the pane
  popup_float     (10) a 520 x 420 window.open popup has inner 520 x 420 within 2 pt and a window smaller than the
                  screen, with the opener windowed and in full screen
  omnibar_narrow  (15) at pane widths 480/360/300/260/200 with a long URL, the omnibar text area ends before every icon
                  to its right in the bar, and the bar stays in the toolbar
  key_route       (23) the page focused by tab.focus from the terminal, no click: its view is the first responder, a
                  real letter reaches it, real Cmd-Shift-Return zooms and unzooms its pane, real Cmd-D splits it (real
                  keys: debug.key `sequence`, the app's event queue)
  element_fullscreen
                  (24) on the fs page, a page click on a button calls requestFullscreen() on a div (exit: a real Escape),
                  on a <video> (exit: document.exitFullscreen()) and on the div with the window already in full screen
                  (exit: Escape; the window stays in full screen): document.fullscreenElement is the element, the window
                  is in full screen, the page view fills the window within 2 pt, :fullscreen CSS applies and
                  fullscreenchange fires; after the exit the window and every page view frame are back exactly (0.5 pt).
                  The cmux window is made key first (debug.key `key_window`, no activation), as a person's click makes
                  it; `element_fullscreen.unfocused` (INFO) is the same click with no key window, the sweep's state

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
                    "window_resize,fullscreen,resize_hitch,live_resize,divider_load,window_move,tab_spam,pane_zoom,popup_float,omnibar_narrow,key_route,element_fullscreen,"
                    "two_pages,reveal",
                    help="comma-separated; `regressions` names every row of in-tree-regressions.md (bugs 4, 9 to 15)")
parser.add_argument("--reveal-hidden", dest="reveal_hidden", type=float, default=10.0,
                    help="reveal: seconds the window stays off the screen")
parser.add_argument("--close-popup", dest="close_popup", choices=["script", "window"], default="script",
                    help="file_after_popup: the popup closes itself (window.close() from its opener) or its window closes")
parser.add_argument("--app-env", dest="app_env", action="append", default=[],
                    help="KEY=VALUE for the launched app's environment (repeatable), e.g. CMUX_CEF_RESIZE_FENCE_MS=500")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
CHECKS = set(opts.checks.split(","))
if "regressions" in CHECKS:  # in-tree-regressions.md: the live rows of the bugs found in real use
    CHECKS |= {"mode", "prompts", "file_after_popup", "reveal", "pane_fit", "divider_resize", "window_resize", "fullscreen",
               "resize_hitch", "live_resize", "divider_load", "window_move", "tab_spam", "pane_zoom", "popup_float", "omnibar_narrow", "key_route", "element_fullscreen"}
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
#edgeL{position:fixed;left:0;top:0;bottom:0;width:8px;background:#0ff;z-index:5} #edgeR{position:fixed;right:0;top:0;bottom:0;width:8px;background:#f0f;z-index:5}
</style></head><body>
<button class="t" id="tl" data-t="tl"></button><button class="t" id="tr" data-t="tr"></button><button class="t" id="bl" data-t="bl"></button>
<button class="t" id="br" data-t="br"></button><button class="t" id="c" data-t="c"></button>
<div id="edgeL"></div><div id="edgeR"></div>
<button id="pop" onclick="window.__pop = window.open('/popup?float', 'floatpopup', 'width=520,height=420')">popup 520x420</button>
<div id="rows"></div>
<script>
window.__popupFile = []; window.__vp = []; window.__clicks = [];
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
if (location.search.indexOf('heavy') >= 0) {
  // The user's heavy page (defects.md 8): a canvas over the whole viewport, hundreds of moving shapes each frame, so the
  // renderer's frame at a new size costs what a busy page's does. Behind the edge strips, which stay on top.
  const c = document.createElement('canvas'); c.id = 'heavy';
  c.style.cssText = 'position:fixed;left:0;top:0;width:100vw;height:100vh;z-index:1;pointer-events:none';
  document.body.appendChild(c);
  const ctx = c.getContext('2d'); const dots = [];
  for (let i = 0; i < 1500; i++) dots.push([Math.random(), Math.random(), Math.random() * 6.28, 2 + Math.random() * 10]);
  (function draw(t) {
    if (c.width !== innerWidth * devicePixelRatio || c.height !== innerHeight * devicePixelRatio) {
      c.width = innerWidth * devicePixelRatio; c.height = innerHeight * devicePixelRatio;
    }
    ctx.clearRect(0, 0, c.width, c.height);
    for (const d of dots) {
      const x = (d[0] + Math.sin(t / 900 + d[2]) * 0.05) * c.width, y = (d[1] + Math.cos(t / 700 + d[2]) * 0.05) * c.height;
      ctx.fillStyle = 'hsla(' + ((d[2] * 57 + t / 20) % 360) + ',70%,55%,0.35)';
      ctx.beginPath(); ctx.arc(x, y, d[3] * devicePixelRatio, 0, 6.28); ctx.fill();
    }
    requestAnimationFrame(draw);
  })(0);
}
window.layoutReady = true;
</script></body></html>"""


# The element full screen page (in-tree-regressions.md bug 24, sweep-06675353 D9): a red box that turns green under
# :fullscreen, a <video>, and a button for each that calls requestFullscreen() from its click. window.fsState() reports
# the fullscreen element, the viewport, the box's computed colour and the log of results and fullscreenchange events.
FS = """<!doctype html><html><head><title>in-tree fs probe</title><style>
body{margin:0;background:#246;color:#fff;font:14px sans-serif} button{font-size:16px;margin:8px}
#box{width:300px;height:200px;background:rgb(204,51,51)} #box:fullscreen{background:rgb(51,204,51)}
#vid{width:320px;height:180px;background:#000;display:block}
</style></head><body>
<button id="fsbox">Fullscreen box</button><button id="fsvid">Fullscreen video</button>
<div id="box">box</div><video id="vid" muted playsinline></video>
<script>
window.__fs = [];
const log = (...a) => window.__fs.push([Date.now()].concat(a));
document.addEventListener('fullscreenchange', () => log('change', document.fullscreenElement ? document.fullscreenElement.id : null));
document.addEventListener('fullscreenerror', e => log('fserror', e.target.id || e.target.tagName));
document.addEventListener('keydown', e => log('keydown', e.key), true);
const ask = id => () => { log('click', id, navigator.userActivation.isActive);
  document.getElementById(id).requestFullscreen().then(() => log('ok', id), e => log('err', id, String(e))); };
document.getElementById('fsbox').onclick = ask('box');
document.getElementById('fsvid').onclick = ask('vid');
window.fsState = () => JSON.stringify({el: document.fullscreenElement ? document.fullscreenElement.id : null,
  w: innerWidth, h: innerHeight, box_bg: getComputedStyle(document.getElementById('box')).backgroundColor,
  log: window.__fs.slice(-12)});
window.buttonCentre = id => JSON.stringify((r => [r.x + r.width / 2, r.y + r.height / 2])(document.getElementById(id).getBoundingClientRect()));
window.fsReady = true;
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/download"):
            body, kind = b"in-tree download probe\n", "application/octet-stream"
        elif self.path.startswith("/layout"):
            body, kind = LAYOUT.encode(), "text/html"
        elif self.path.startswith("/fs"):
            body, kind = FS.encode(), "text/html"
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


PAGE_EVAL_FAILURES = []  # (script, reply) of page_json reads that gave no JSON: a row's null viewport names its cause


def page_json(script, tab):
    reply = page_eval(script, tab)
    value = reply.get("value")
    try:
        if isinstance(value, str):
            return json.loads(value)
    except ValueError:
        pass
    PAGE_EVAL_FAILURES.append((script[:60], str(reply)[:300]))
    del PAGE_EVAL_FAILURES[:-20]
    return None


def main_layers():
    return (windows() or [{}])[0]


def page_pane(tab):
    """The pane whose tabs list `tab` (debug.focus topology)."""
    focus = rpc("debug.focus") or {}
    # debug.focus lists each window's topology (windows[].topology); a top-level list is read too.
    for pane in (focus.get("topology") or []) + [p for w in focus.get("windows") or [] for p in w.get("topology") or []]:
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
    failed_before = len(PAGE_EVAL_FAILURES)
    vp = page_json(f"window.vpSince({int(t0 * 1000)})", tab) or []
    vp_reply = PAGE_EVAL_FAILURES[-1][1] if len(PAGE_EVAL_FAILURES) > failed_before else None
    page_final_ms = None
    if final:
        for entry in reversed(vp):
            if abs(entry[1] - final[2]) > FIT_PX or abs(entry[2] - final[3]) > FIT_PX:
                break
            page_final_ms = entry[0] - t0 * 1000
    lag = None if page_final_ms is None or pane_final_ms is None else round(page_final_ms - pane_final_ms)
    return {"reply": str(reply)[:200], "t0_ms": int(t0 * 1000), "samples": samples, "final": final,
            "pane_final_ms": pane_final_ms, "page_final_ms": None if page_final_ms is None else round(page_final_ms),
            "lag_ms": lag, "vp": vp, "vp_reply": vp_reply}


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


def check_pane_fit(tab, pane):
    """Bug 13: after the split and a scroll, the page's innerWidth/innerHeight and visualViewport equal its view's size
    within 1 pt, and a click at each of five targets' centres (a page click, then a window click at the same point)
    hits that target: event.target is the target, the click is inside its rect within 1 pt, elementFromPoint agrees."""
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
        failed_before = len(PAGE_EVAL_FAILURES)
        viewport = page_json("window.viewport()", tab)
        # The page's own reply when it gave no viewport (a null viewport was the harness or the page; a6372332 could not tell).
        eval_reply = PAGE_EVAL_FAILURES[-1][1] if len(PAGE_EVAL_FAILURES) > failed_before else None
        glitches, over = zoom_glitch(result["vp"]), overshoot(result["samples"], before, result["final"])
        rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, f"fullscreen-{direction}.png")})
        # An empty rAF log is no evidence of no zoom (a6372332's enter passed with nothing read): INFO, never PASS.
        row("INFO" if not result["vp"] else (not glitches), f"fullscreen.{direction}.no_zoom",
            {"bug": 12, "glitch_frames": glitches, "vp_entries": len(result["vp"]),
             "pass_if": "visualViewport.scale 1 and devicePixelRatio unchanged every frame (INFO when the page logged no frame)"})
        row(not over, f"fullscreen.{direction}.no_overflow", {"bug": 12, "samples": over, "before": before, "final": result["final"],
                                                              "pass_if": "page view never larger than start and end, never outside the window"})
        row(result["lag_ms"] is not None and result["lag_ms"] <= LAG_MS and fits(viewport, result["final"]),
            f"fullscreen.{direction}.page_follows",
            {"bug": 12, "lag_ms": result["lag_ms"], "pane_final_ms": result["pane_final_ms"], "viewport": viewport,
             "viewport_eval_reply": eval_reply, "vp_entries": len(result["vp"]), "vp_reply": result.get("vp_reply"),
             "page_view": result["final"], "full_screen": is_full_screen(),
             "pass_if": f"page matches the pane <= {LAG_MS} ms after the pane settles, then within 1 pt"})
    if is_full_screen():
        action("toggleFullScreen")
        wait(lambda: not is_full_screen(), 5)


# ---- Live resize by pixels (in-tree-regressions.md bugs 17 to 21; the user's recordings, defects 5 to 10) ----
# The app's own ScreenCaptureKit recorder (`debug.motion` record_*: what the window server composites, every frame, no
# main-thread work per frame) keeps one device-pixel row through the middle of the page. The layout page has a cyan
# strip on its left edge and a magenta strip on its right edge, on its blue background. A frame is classified:
#   right    cyan, then the page, then magenta, and no page blue right after the magenta (the page fills its pane)
#   gutter   page blue right after the magenta: the page is narrower than its pane (a stale, smaller frame)
#   clipped  cyan but no magenta: the page is wider than its pane (a stale, larger frame, cut at the pane's edge)
#   blank    neither strip: no page content in the row (the pane's backdrop, or nothing)

def _is_cyan(p):
    return p[0] < 90 and p[1] > 180 and p[2] > 180


def _is_magenta(p):
    return p[0] > 180 and p[1] < 90 and p[2] > 180


def _is_page_blue(p):
    return abs(p[0] - 0x22) < 24 and abs(p[1] - 0x44) < 24 and abs(p[2] - 0x66) < 24


def _runs(pixels, test, lo, hi, min_len):
    runs, start = [], None
    for x in range(lo, hi):
        if test(pixels[x]):
            if start is None:
                start = x
        elif start is not None:
            if x - start >= min_len:
                runs.append((start, x))
            start = None
    if start is not None and hi - start >= min_len:
        runs.append((start, hi))
    return runs


def classify_row(pixels, lo, hi, scale):
    """One frame's row (RGB tuples) between device columns lo and hi: right, gutter, clipped or blank (see above)."""
    strip = max(3, int(8 * scale) - 3)
    cyan = [r for r in _runs(pixels, _is_cyan, lo, hi, strip) if r[1] < hi and _is_page_blue(pixels[min(hi - 1, r[1] + 1)])]
    magenta = [r for r in _runs(pixels, _is_magenta, lo, hi, strip) if r[0] > lo and _is_page_blue(pixels[r[0] - 2])]
    if not cyan and not magenta:
        return "blank", None
    if not magenta:
        return "clipped", None
    end = magenta[-1][1]
    after = [pixels[x] for x in range(end + 1, min(hi, end + int(6 * scale)))]
    if after and sum(1 for p in after if _is_page_blue(p)) >= max(2, len(after) // 2):
        return "gutter", end
    return "right", end


def read_scan(path):
    """The recorder's scan file: (header, [(host seconds, [row pixels as RGB tuples])])."""
    import struct
    with open(path, "rb") as f:
        data = f.read()
    nl = data.index(b"\n")
    header = json.loads(data[:nl])
    width, height, rows, cols = header["width"], header["height"], header["rows"], header["columns"]
    size = 8 + 4 * (len(rows) * width + len(cols) * height)
    frames, pos = [], nl + 1
    while pos + size <= len(data):
        t = struct.unpack("<d", data[pos:pos + 8])[0]
        lines, at = [], pos + 8
        for _ in rows:
            raw = data[at:at + 4 * width]
            lines.append([(raw[i + 2], raw[i + 1], raw[i]) for i in range(0, len(raw), 4)])  # BGRA -> RGB
            at += 4 * width
        frames.append((t, lines))
        pos += size
    return header, frames


def pixel_record(name, seconds, filter_kind="display"):
    """Starts the app's recorder with one row through the middle of the page (device pixels from the window's top left).
    Returns {path, scale, row, x_lo} or {"error"}."""
    layers = main_layers()
    win = layers.get("frame") or [0, 0, 0, 0]
    views = [v for v in layers.get("page_views") or [] if not v.get("parked")]
    if not views:
        return {"error": "no page view"}
    frame = views[0].get("frame_in_window")
    folder = os.path.join(opts.out, f"pixels-{name}")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"{name}.mov")
    probe = rpc("debug.motion", {"action": "record_read"})
    if isinstance(probe, dict) and probe.get("capturing"):
        # A recording an earlier row left running (one whose start never reported capturing): end it, or every later
        # row fails with "a recording is running" (live step a6372332).
        rpc("debug.motion", {"action": "record_stop"})
        wait(lambda: (rpc("debug.motion", {"action": "record_read"}) or {}).get("written"), 30, 0.25)
    scale = 2.0
    y_pt = win[3] - (frame[1] + frame[3] / 2)
    started = rpc("debug.motion", {"action": "record_start", "path": path, "seconds": seconds, "mbps": 60,
                                   "rows": [int(y_pt * scale)], "columns": [], "filter": filter_kind})
    if not isinstance(started, dict) or started.get("error"):
        return {"error": f"record_start: {started}", "read": probe}
    scale = started.get("scale") or scale
    if abs(scale - 2.0) > 1e-6:  # the row was asked in 2x pixels; ask again at the real scale
        rpc("debug.motion", {"action": "record_stop"})
        wait(lambda: (rpc("debug.motion", {"action": "record_read"}) or {}).get("written"), 30)
        started = rpc("debug.motion", {"action": "record_start", "path": path, "seconds": seconds, "mbps": 60,
                                       "rows": [int(y_pt * scale)], "columns": [], "filter": filter_kind})
    ok = wait(lambda: (lambda r: r if isinstance(r, dict) and (r.get("capturing") or r.get("error")) else None)(
        rpc("debug.motion", {"action": "record_read"})), 30, 0.05)
    if not ok or not ok.get("capturing"):
        last = rpc("debug.motion", {"action": "record_read"})
        # It never reported capturing: stop it anyway, so the next row can start its own.
        rpc("debug.motion", {"action": "record_stop"})
        wait(lambda: (rpc("debug.motion", {"action": "record_read"}) or {}).get("written"), 30, 0.25)
        return {"error": f"recorder did not start in 30 s: {ok}; last read {str(last)[:300]}"}
    return {"path": path, "scale": scale, "row": int(y_pt * scale), "frame": frame, "window": win}


def pixel_stop(rec):
    rpc("debug.motion", {"action": "record_stop"})
    read = wait(lambda: (lambda r: r if isinstance(r, dict) and (r.get("written") or r.get("error")) else None)(
        rpc("debug.motion", {"action": "record_read"})), 60, 0.25) or {}
    return read


def pixel_verdict(rec, spans, x_lo_pt, settle_after):
    """Classifies every complete frame inside `spans` ([(start, end)] in time.monotonic seconds, the same host clock as
    the recorder's) and after the last span's end for `settle_after` s. Returns counts, the longest run of wrong frames,
    the gaps between complete frames over 50 ms while moving (stalls), and the settle time after the last span."""
    scan = rec["path"] + ".scan"
    if not os.path.exists(scan):
        return {"error": "no scan file", "path": scan}
    header, frames = read_scan(scan)
    scale = rec["scale"]
    lo = max(0, int(x_lo_pt * scale))
    hi = header["width"]
    first, last_end = spans[0][0], spans[-1][1]
    classes, moving_times, wrong_runs, run, examples = {}, [], [], 0, []
    settle_ms, last_wrong_t = None, None
    timeline = []
    for t, lines in frames:
        if t < first - 0.1 or t > last_end + settle_after:
            continue
        kind, _ = classify_row(lines[0], lo, hi, scale)
        timeline.append((round((t - first) * 1000, 1), kind))
        classes[kind] = classes.get(kind, 0) + 1
        if any(a <= t <= b for a, b in spans):
            moving_times.append(t)
        if kind != "right":
            run += 1
            last_wrong_t = t
            if len(examples) < 12:
                examples.append((round((t - first) * 1000, 1), kind))
        else:
            if run:
                wrong_runs.append(run)
            run = 0
    if run:
        wrong_runs.append(run)
    if last_wrong_t is None or last_wrong_t <= last_end:
        settle_ms = 0.0
    else:
        settle_ms = round((last_wrong_t - last_end) * 1000, 1)
    gaps = [round((b - a) * 1000, 1) for a, b in zip(moving_times, moving_times[1:])]
    total = sum(classes.values())
    moving_s = sum(b - a for a, b in spans)
    return {"frames": total, "classes": classes, "wrong": total - classes.get("right", 0),
            "blank": classes.get("blank", 0), "longest_wrong_run": max(wrong_runs or [0]),
            "moving_fps": round(len(moving_times) / moving_s, 1) if moving_s > 0 else None,
            "stalls_over_50ms": sum(1 for g in gaps if g > 50), "gap_p50_ms": sorted(gaps)[len(gaps) // 2] if gaps else None,
            "gap_max_ms": max(gaps) if gaps else None, "settle_ms_after_input": settle_ms,
            "examples": examples, "timeline": timeline[:400]}



WORK_KEYS = ("layout_root_layouts", "pane_chrome_updates", "pane_snapshots", "terminal_window_updates")
TRACKER_KEYS = ("clip_reads", "geometry_posts", "geometry_skips", "fences", "fence_joined", "fence_presented", "fence_missed",
                "fences_expired")


def work_counters():
    """The app's per-layout work counters (debug.layout_counters) and the fork tracker's (debug.cef tracker)."""
    layout = rpc("debug.layout_counters") or {}
    tracker = (rpc("debug.cef") or {}).get("tracker") or {}
    out = {k: layout.get(k) for k in WORK_KEYS if isinstance(layout, dict)}
    out.update({f"tracker.{k}": tracker.get(k) for k in TRACKER_KEYS if isinstance(tracker, dict)})
    return out


def work_delta(before, after):
    return {k: (after.get(k) - before.get(k)) if isinstance(after.get(k), (int, float)) and isinstance(before.get(k), (int, float))
            else None for k in after}


def check_live_resize(tab, pane):
    """Bugs 17 to 21 by pixels: a divider drag, a window corner drag, full screen enter and exit, a window move and a
    workspace switch, each recorded by the app's own recorder, every composited frame classified (classify_row)."""
    frame = page_view(pane)
    if not frame:
        row("INFO", "live_resize", {"note": "no in-tree page view"})
        return
    page_eval("window.scrollTo(0, 0); window.__token = Math.random(); true", tab)
    token = page_eval("String(window.__token)", tab).get("value")
    time.sleep(1.2)  # test harness: overlay scroll bars fade before the recording
    layers = main_layers()
    divider = vertical_divider_near(frame[0], layers)
    window = layers.get("frame")
    rounds = 3

    # Divider: three out-and-back drags of 160 pt at 60 Hz (the user's oscillating drag, V6 14-24 s).
    if divider:
        rec = pixel_record("divider", 20)
        if rec.get("error"):
            row(False, "live_resize.divider.pixels", {"bug": 18, "error": rec["error"]})
        else:
            time.sleep(0.3)  # test harness: the recorder's first frames at rest
            rpc("debug.frames", {"action": "start"})
            work0 = work_counters()
            spans = []
            for _ in range(rounds):
                a = time.monotonic()
                drag_divider(divider, -160)
                drag_divider((divider[0] - 160, divider[1]), 160)
                spans.append((a, time.monotonic()))
            app_frames = rpc("debug.frames", {"action": "stop"})
            work = work_delta(work0, work_counters())
            time.sleep(0.8)  # test harness: the settle is in the recording
            read = pixel_stop(rec)
            v = pixel_verdict(rec, spans, frame[0] - 170, 0.7)
            RAW["live_resize_divider"] = {"verdict": v, "read": read, "app_frames": app_frames, "work": work}
            row(not v.get("error") and v["blank"] == 0 and v["wrong"] <= 0.1 * max(1, v["frames"]) and v["stalls_over_50ms"] == 0
                and v["settle_ms_after_input"] <= LAG_MS,
                "live_resize.divider.pixels",
                {"bug": 18, **{k: v.get(k) for k in ("frames", "classes", "wrong", "blank", "longest_wrong_run", "moving_fps",
                                                      "stalls_over_50ms", "gap_p50_ms", "gap_max_ms", "settle_ms_after_input",
                                                      "examples", "error")},
                 "app_frames": frame_detail(app_frames), "work": work,
                 "pass_if": "no blank frame, wrong <= 10% of frames, no gap over 50 ms between composited frames while "
                            f"dragging, page right <= {LAG_MS} ms after the drag"})

    # Window corner: three out-and-back drags of 240 x 120 pt at 120 Hz (V6 1.8-10.3 s).
    if window:
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

        rec = pixel_record("window", 20)
        if rec.get("error"):
            row(False, "live_resize.window.pixels", {"bug": 19, "error": rec["error"]})
        else:
            time.sleep(0.3)  # test harness: the recorder's first frames at rest
            rpc("debug.frames", {"action": "start"})
            work0 = work_counters()
            spans = []
            for _ in range(rounds):
                a = time.monotonic()
                corner(240, 120)
                corner(-240, -120)
                spans.append((a, time.monotonic()))
            app_frames = rpc("debug.frames", {"action": "stop"})
            work = work_delta(work0, work_counters())
            time.sleep(0.8)  # test harness: the settle is in the recording
            read = pixel_stop(rec)
            v = pixel_verdict(rec, spans, frame[0] - 10, 0.7)
            RAW["live_resize_window"] = {"verdict": v, "read": read, "app_frames": app_frames, "work": work,
                                         "window_after": main_layers().get("frame")}
            row(not v.get("error") and v["blank"] == 0 and v["wrong"] <= 0.1 * max(1, v["frames"]) and v["stalls_over_50ms"] == 0
                and v["settle_ms_after_input"] <= LAG_MS,
                "live_resize.window.pixels",
                {"bug": 19, **{k: v.get(k) for k in ("frames", "classes", "wrong", "blank", "longest_wrong_run", "moving_fps",
                                                      "stalls_over_50ms", "gap_p50_ms", "gap_max_ms", "settle_ms_after_input",
                                                      "examples", "error")},
                 "app_frames": frame_detail(app_frames), "work": work,
                 "pass_if": "no blank frame, wrong <= 10% of frames, no gap over 50 ms while dragging, page right "
                            f"<= {LAG_MS} ms after the drag"})

    # Full screen enter and exit (V2): the transition's frames, then the page must be right within LAG_MS of its end.
    for direction in ("enter", "exit"):
        rec = pixel_record(f"fullscreen-{direction}", 12)
        if rec.get("error"):
            row(False, f"live_resize.fullscreen.{direction}.pixels", {"bug": 17, "error": rec["error"]})
            continue
        time.sleep(0.3)  # test harness: frames at rest
        rpc("debug.frames", {"action": "start"})
        a = time.monotonic()
        action("toggleFullScreen")
        done = wait(lambda: is_full_screen() == (direction == "enter"), 6, 0.02)
        b = time.monotonic()
        time.sleep(1.2)  # test harness: the settle is in the recording
        app_frames = rpc("debug.frames", {"action": "stop"})
        read = pixel_stop(rec)
        v = pixel_verdict(rec, [(a, b)], 0, 1.1)
        RAW[f"live_resize_fullscreen_{direction}"] = {"verdict": v, "read": read, "transition_s": round(b - a, 3),
                                                      "app_frames": app_frames}
        longest = (app_frames or {}).get("max_ms") if isinstance(app_frames, dict) else None
        row(not v.get("error") and bool(done) and v["blank"] == 0 and v["settle_ms_after_input"] <= LAG_MS
            and longest is not None and longest <= 250,
            f"live_resize.fullscreen.{direction}.pixels",
            {"bug": 17, "transition_ms": round((b - a) * 1000), **{k: v.get(k) for k in (
                "frames", "classes", "wrong", "blank", "longest_wrong_run", "settle_ms_after_input", "examples", "error")},
             "app_frames": frame_detail(app_frames),
             "pass_if": f"no blank frame; the page right <= {LAG_MS} ms after the window reports the new state; no app "
                        "frame interval over 250 ms (sweep D4: 1035 ms)"})
        time.sleep(0.5)  # test harness: rest between the two transitions
    if is_full_screen():
        action("toggleFullScreen")
        wait(lambda: not is_full_screen(), 6)

    # Workspace switch away and back (V6 53.5 s, 59.3 s): the page keeps its document (no reload) and draws at once.
    rec = pixel_record("switch", 12)
    if rec.get("error"):
        row(False, "live_resize.switch.pixels", {"bug": 21, "error": rec["error"]})
    else:
        def shown():  # the window's shown workspace (debug.focus), so the row names where each switch went
            w = ((rpc("debug.focus") or {}).get("windows") or [{}])[0]
            return {"workspace": w.get("workspace"), "name": w.get("workspace_name")}

        home_of_page = shown()
        made = action("workspace.newAtBottom")
        wait(lambda: page_eval("document.visibilityState", tab).get("value") == "hidden", 5, 0.05)
        away = shown()
        time.sleep(1.5)  # test harness: the other workspace shows for a while
        a = time.monotonic()
        # A launch that comes up on Home puts the page in Home's workspace, which the sidebar does not list: there
        # workspace.selectFirst/selectLast both pick the new workspace and the page never shows again (other-Mac runs
        # 2026-11-24: 10 of 10 failing switch rows launched on Home, 4 of 4 passing ones on a sidebar workspace).
        on_home = home_of_page.get("name") == "Home"
        back = action("home.show" if on_home else "workspace.selectFirst")
        if page_eval("document.visibilityState", tab).get("value") == "hidden":
            wait(lambda: page_eval("document.visibilityState", tab).get("value") == "visible", 1.0, 0.05)
        if not on_home and page_eval("document.visibilityState", tab).get("value") == "hidden":
            back = action("workspace.selectLast")
        b = time.monotonic()
        returned = shown()
        time.sleep(1.5)  # test harness: frames after the switch back
        read = pixel_stop(rec)
        v = pixel_verdict(rec, [(a, b)], frame[0] - 10, 1.4)
        after = page_eval("String(window.__token)", tab).get("value")
        # Only frames after the switch back count: before it the other workspace shows (no page in the row).
        late = [k for ms, k in v.get("timeline", []) if ms >= (b - a) * 1000 + 50]
        blank_after = sum(1 for k in late if k == "blank")
        RAW["live_resize_switch"] = {"verdict": v, "read": read, "new": made, "back": back, "page_workspace": home_of_page,
                                     "away": away, "returned": returned}
        came_back = returned.get("workspace") == home_of_page.get("workspace")
        row(after == token and blank_after == 0 and came_back and not v.get("error"), "live_resize.switch.pixels",
            {"bug": 21, "page_workspace": home_of_page, "away": away, "returned": returned, "came_back": came_back,
             "switch_back": "home.show" if on_home else "workspace.selectFirst",
             "same_document": after == token, "blank_frames_after_switch": blank_after,
             "frames_after_switch": len(late), "classes_after_switch": {k: late.count(k) for k in set(late)},
             "error": v.get("error"),
             "pass_if": "the page's document survives (no reload) and no blank frame after the switch back"})


def check_tab_spam(tab, pane):
    """Sweep D8: Cmd-Shift-L (openBrowser) 10x at 80 ms from the focused page. The recorder keeps one device row through
    the pane's omnibar; a frame whose omnibar row is much darker than at rest (mean luminance under 0.6x the first
    frames') shows no omnibar row. Rows: frames without the omnibar, and debug.frames over the spam."""
    report = rpc("debug.omnibar", {"pane": pane}) or {}
    bar = ((report.get("pointer") or {}).get("frames") or {}).get("bar")
    layers = main_layers()
    win = layers.get("frame") or [0, 0, 0, 0]
    if not bar:
        row("INFO", "tab_spam", {"note": "no omnibar frame", "omnibar": str(report)[:200]})
        return
    folder = os.path.join(opts.out, "pixels-tab-spam")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "tab-spam.mov")
    y_pt = bar[1] + bar[3] / 2
    started = rpc("debug.motion", {"action": "record_start", "path": path, "seconds": 8, "mbps": 60, "rows": [int(y_pt * 2)], "columns": []})
    if not isinstance(started, dict) or started.get("error"):
        row(False, "tab_spam", {"bug": 22, "error": f"record_start: {started}"})
        return
    scale = started.get("scale") or 2.0
    wait(lambda: (rpc("debug.motion", {"action": "record_read"}) or {}).get("capturing"), 10, 0.05)
    action("tab.focus", target=f"tab:{tab}")
    time.sleep(0.6)  # test harness: frames at rest
    rpc("debug.frames", {"action": "start"})
    a = time.monotonic()
    shows, stop = [], threading.Event()

    def sample_shows():
        # What the pane shows (debug.pane_chrome panes[].shows), each display frame, so a frame without the omnibar row
        # names its cause: no content installed, a hidden or clear content view, or a paint hold's kept view.
        while not stop.is_set():
            t = time.monotonic()
            report = rpc("debug.pane_chrome", timeout=5) or {}
            for window in report.get("windows") or []:
                for p in window.get("panes") or []:
                    if p.get("pane") == pane and p.get("shows"):
                        shows.append((round((t - a) * 1000), p["shows"]))
            time.sleep(0.008)  # test harness: about one sample a display frame

    sampler = threading.Thread(target=sample_shows, daemon=True)
    sampler.start()
    for _ in range(10):
        rpc("debug.key", {"key": "l", "modifiers": ["command", "shift"]})
        time.sleep(0.08)  # test harness: the sweep's 80 ms key spacing
    b = time.monotonic()
    time.sleep(1.5)  # test harness: the last tab settles
    stop.set()
    sampler.join(timeout=5)
    app_frames = rpc("debug.frames", {"action": "stop"})
    pixel_stop({"path": path})
    scan = path + ".scan"
    detail = {"bug": 22, "app_frames": frame_detail(app_frames)}
    if not os.path.exists(scan):
        row(False, "tab_spam", dict(detail, error="no scan file"))
        return
    _, frames = read_scan(scan)
    lo, hi = int(bar[0] * scale), int((bar[0] + bar[2]) * scale)

    def lum(line):
        px = line[lo:hi] or [(0, 0, 0)]
        return sum(0.2126 * r + 0.7152 * g + 0.0722 * b_ for r, g, b_ in px) / len(px)

    rest = [lum(l[0]) for t, l in frames if t < a]
    base = sorted(rest)[len(rest) // 2] if rest else None
    during = [(round((t - a) * 1000), round(lum(l[0]), 1)) for t, l in frames if a <= t <= b + 1.5]
    gone = [d for d in during if base and d[1] < 0.6 * base]
    longest = (app_frames or {}).get("max_ms") if isinstance(app_frames, dict) else None
    def brief(sh):
        c = sh.get("content") or {}
        return {"content": c.get("class"), "hidden": c.get("hidden"), "alpha": c.get("alpha"), "installed": sh.get("hosts_content"),
                "kept": (sh.get("kept") or {}).get("class"), "host": [(v["class"], v["alpha"], v["hidden"]) for v in sh.get("host_subviews") or []]}
    bare = [(ms, brief(sh)) for ms, sh in shows
            if not sh.get("hosts_content") or (sh.get("content") or {}).get("hidden") or (sh.get("content") or {}).get("alpha", 1) < 0.99]
    RAW["tab_spam"] = {"shows": shows, "during": during}
    row(bool(base) and not gone and longest is not None and longest <= 50, "tab_spam",
        dict(detail, rest_luminance=base, frames=len(during), omnibar_gone_frames=len(gone), examples=gone[:10],
             shows_samples=len(shows), bare_pane_samples=len(bare), bare_examples=bare[:6],
             pass_if="no frame without the omnibar row; no app frame interval over 50 ms (sweep D8: 159 ms)"))


def check_window_move(tab, pane):
    """Defect 9 (bug 20): the window moved 300 pt right and back in 60 steps a way (debug.window_frame, the app's own
    setFrame: no focus, as Rectangle moves it), recorded by the app's recorder with the window filter so the row is in
    the window's own coordinates. A page that lags or floats apart from its window shows its strips at another x than
    the window's own page edge: every frame is classified as for live_resize."""
    layers = main_layers()
    window = layers.get("frame")
    frame = page_view(pane, layers)
    if not window or not frame:
        row("INFO", "window_move", {"note": "no window frame or page view"})
        return
    page_eval("window.scrollTo(0, 0); true", tab)
    time.sleep(0.8)  # test harness: overlay scroll bars fade
    rec = pixel_record("window-move", 12, "window")
    if rec.get("error"):
        row(False, "window_move.pixels", {"bug": 20, "error": rec["error"]})
        return
    time.sleep(0.3)  # test harness: frames at rest
    rpc("debug.frames", {"action": "start"})
    work0 = work_counters()
    x0, y0, w, h = window
    a = time.monotonic()
    for dx in list(range(5, 305, 5)) + list(range(300, -5, -5)):
        rpc("debug.window_frame", {"frame": [x0 + dx, y0, w, h]})
        time.sleep(1 / 120)  # test harness: one move a 120 Hz frame, as a drag
    b = time.monotonic()
    time.sleep(0.8)  # test harness: the settle is in the recording
    app_frames = rpc("debug.frames", {"action": "stop"})
    work = work_delta(work0, work_counters())
    read = pixel_stop(rec)
    v = pixel_verdict(rec, [(a, b)], frame[0] - 10, 0.7)
    RAW["window_move"] = {"verdict": v, "read": read, "app_frames": app_frames, "work": work}
    row(not v.get("error") and v["wrong"] == 0 and v["settle_ms_after_input"] <= LAG_MS, "window_move.pixels",
        {"bug": 20, **{k: v.get(k) for k in ("frames", "classes", "wrong", "blank", "longest_wrong_run", "moving_fps",
                                              "stalls_over_50ms", "gap_max_ms", "settle_ms_after_input", "examples", "error")},
         "app_frames": frame_detail(app_frames), "work": work, "read_filter": (read or {}).get("filter"),
         "pass_if": "no wrong frame (the page right against its window's own page edge in every frame) while the window moves"})


SAMPLE_MARKERS = {  # main-thread stack frames to count in a sample of a live resize (resize_hitch)
    "chromium_precommit_wait": "CATransactionCoordinator::PreCommitHandler",
    "chromium_wait_task": "WaitForSingleTaskToRun",
    "chromium_postcommit": "CATransactionCoordinator::PostCommitHandler",
    "ca_commit": "CA::Transaction::commit",
    "appkit_live_resize": "_resizeWithEvent",
    "window_server_sync": "_NSWindowSyncResize",
    # A synchronous window-server query (NSApp orderedWindows and friends) waiting for the server's CA transaction:
    # the other Mac's ~500 ms in-tree frame, from a delayed perform in CEF (2026-11-24).
    "window_server_query_sync": "SLSConnectionSynchronizeSLSCATransaction",
    "ordered_windows": "_orderedWindowsWithPanels",
    "appkit_edge_resize": "resizedFromEdge",
    "shell_set_frame": "ShellWindow.setFrame",
    "cg_sync": "CGSSync",
    "cef_pump": "CefDoMessageLoopWork",
    "layout": "layoutSubtreeIfNeeded",
    "display": "displayIfNeeded",
}


def main_thread_counts(text):
    """Per marker, the largest sample count of a main-thread line containing it (the samples that passed through that
    frame), and the main thread's total. Reads `sample`'s call graph: the main thread's block is the one naming
    com.apple.main-thread, up to the next thread's header."""
    import re
    lines = text.splitlines()
    # With in-tree pages off, Chromium names the main thread CrBrowserMain (other-Mac BEFORE OFF sample, 2026-11-24).
    start = next((i for i, l in enumerate(lines) if "com.apple.main-thread" in l or re.search(r"\d+ Thread_\d+: CrBrowserMain", l)), None)
    if start is None:
        return {"error": "no main thread in the sample"}
    total = None
    try:
        total = int(lines[start].split()[0])
    except (ValueError, IndexError):
        pass
    # Each thread of the call graph starts with "<count> Thread_<id>" at the graph's first indent.
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"^\s{0,6}\d+ Thread_", lines[i])
                or lines[i].startswith(("Total number", "Binary Images", "Sort by top of stack"))), len(lines))
    block = lines[start:end]
    counts = {}
    for name, marker in SAMPLE_MARKERS.items():
        best = 0
        for l in block:
            if marker in l:
                tok = l.replace("+", " ").replace("!", " ").replace(":", " ").replace("|", " ").split()
                n = next((int(t) for t in tok if t.isdigit()), 0)
                best = max(best, n)
        counts[name] = best
    top = []
    if "Sort by top of stack" in text:
        tail = text.split("Sort by top of stack", 1)[1].splitlines()[1:]
        for l in tail:
            parts = l.strip().rsplit(None, 1)
            if len(parts) == 2 and parts[1].isdigit():
                top.append((parts[0][:120], int(parts[1])))
            if len(top) >= 15:
                break
    return {"main_samples": total, "counts": counts, "top_of_stack": top}


def check_resize_hitch(tab, pane):
    """Defect 7 (bug 19): the main thread during three out-and-back window corner drags, in either in-tree mode (no page
    view needed): debug.frames (the longest frame, p95, missed), and `sample` of the app at 1 ms for the drags, with the
    main thread's samples in Chromium's pre-commit wait (CATransactionCoordinator), Core Animation's commit, AppKit's
    live resize loop and the window server's sync. The other Mac saw a ~500 ms frame in every corner drag of every
    build (Chromium's kUIPaintTimeout is 500 ms)."""
    window = main_layers().get("frame")
    pid = RAW.get("pid")
    if not window or not pid:
        row("INFO", "resize_hitch", {"note": "no window frame or pid"})
        return
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

    path = os.path.join(opts.out, "resize-hitch.sample.txt")
    seconds = 7
    sample_log = []
    try:
        sampler = subprocess.Popen(["/usr/bin/sample", str(pid), str(seconds), "1", "-mayDie", "-file", path],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        attached = threading.Event()

        def read_sampler():
            for line in sampler.stdout:
                sample_log.append(line.rstrip())
                if line.startswith("Sampling process"):
                    attached.set()
            attached.set()

        threading.Thread(target=read_sampler, daemon=True).start()
        # sample prints "Sampling process N for S seconds ..." when it starts sampling; attaching to a CEF app can take
        # seconds, and a fixed 0.5 s let the drags finish before it began (other-Mac BEFORE ON sample: 4540 of 4549
        # main-thread samples idle in mach_msg while debug.frames saw a 507 ms frame).
        t_attach = time.monotonic()
        attached.wait(30)
        RAW["resize_hitch_attach_s"] = round(time.monotonic() - t_attach, 3)
    except OSError as error:
        sampler = None
        RAW["resize_hitch_sample_error"] = repr(error)
    time.sleep(0.3)  # test harness: a few idle samples before the first drag
    rpc("debug.layout_counters", {"reset": True})  # resize_steps from here (builds with ResizeStepTimes)
    rpc("debug.frames", {"action": "start"})
    work0 = work_counters()
    started = time.monotonic()
    for _ in range(3):
        corner(240, 120)
        corner(-240, -120)
    drag_s = round(time.monotonic() - started, 2)
    app_frames = rpc("debug.frames", {"action": "stop"})
    work = work_delta(work0, work_counters())
    sample_err = None
    if sampler:
        try:
            sampler.wait(timeout=seconds + 30)
            sample_err = "\n".join(sample_log[-5:])
        except subprocess.TimeoutExpired:
            sampler.kill()
            sample_err = "sample timed out"
    parsed = {"error": f"no sample file: {(sample_err or '')[-300:]}"}
    if os.path.exists(path):
        with open(path, errors="replace") as f:
            parsed = main_thread_counts(f.read())
    steps = (rpc("debug.layout_counters") or {}).get("resize_steps")
    RAW["resize_hitch"] = {"app_frames": app_frames, "work": work, "sample": parsed, "drag_s": drag_s, "resize_steps": steps}
    longest = (app_frames or {}).get("max_ms") if isinstance(app_frames, dict) else None
    row(longest is not None and longest <= 50, "resize_hitch",
        {"bug": 19, "in_tree": opts.in_tree, "drag_s": drag_s, "app_frames": frame_detail(app_frames), "work": work,
         "resize_steps": {n: {m: v.get(m) for m in ("steps", "p50_ms", "p95_ms", "max_ms", "total_ms", "slowest")} for n, v in steps.items()} if isinstance(steps, dict) else steps,
         "sample": parsed, "sample_file": os.path.basename(path), "sample_attach_s": RAW.get("resize_hitch_attach_s"),
         "pass_if": "no app frame over 50 ms during the corner drags; the sample names what the main thread does"})


def check_divider_load(tab, pane):
    """The divider fence's quality and frame-rate cost on a light page and a heavy one (the user's animating canvas):
    the same three out-and-back divider drags as live_resize.divider, recorded by the app's recorder, each frame
    classified, with debug.frames and the fence counters, once on the layout page and once with its heavy canvas.
    No pass rule: a measurement row (INFO) for the fence wait's tradeoff; run it with and without
    CMUX_CEF_RESIZE_FENCE_MS (--app-env) to compare the half-frame cap with a long wait."""
    results = {}
    for load, query in (("light", "?divload"), ("heavy", "?divload-heavy")):
        if not open_layout(tab, query):
            results[load] = {"error": "layout page did not load"}
            continue
        time.sleep(1.5)  # test harness: the page draws (the heavy canvas starts)
        layers = main_layers()
        frame = page_view(pane, layers)
        divider = vertical_divider_near(frame[0], layers) if frame else None
        if not frame or not divider:
            results[load] = {"error": "no page view or divider", "frame": frame}
            continue
        rec = pixel_record(f"divider-{load}", 20)
        if rec.get("error"):
            results[load] = {"error": rec["error"]}
            continue
        time.sleep(0.3)  # test harness: frames at rest
        rpc("debug.frames", {"action": "start"})
        work0 = work_counters()
        spans = []
        for _ in range(3):
            a = time.monotonic()
            drag_divider(divider, -160)
            drag_divider((divider[0] - 160, divider[1]), 160)
            spans.append((a, time.monotonic()))
        app_frames = rpc("debug.frames", {"action": "stop"})
        work = work_delta(work0, work_counters())
        time.sleep(0.8)  # test harness: the settle is in the recording
        pixel_stop(rec)
        v = pixel_verdict(rec, spans, frame[0] - 170, 0.7)
        results[load] = {k: v.get(k) for k in ("frames", "classes", "wrong", "blank", "longest_wrong_run", "moving_fps",
                                                "stalls_over_50ms", "gap_p50_ms", "gap_max_ms", "settle_ms_after_input", "error")}
        results[load]["app_frames"] = frame_detail(app_frames)
        results[load]["fences"] = {k: work.get(f"tracker.{k}") for k in ("fences", "fence_joined", "fence_presented", "fence_missed", "fences_expired")}
    RAW["divider_load"] = results
    row("INFO", "divider_load", {"app_env": opts.app_env, **results,
                                 "note": "measurement: divider fence quality (wrong frames, presented) against frame rate "
                                         "(moving_fps, app p95/max), light and heavy page"})


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
    """Bug 15: with a long URL, at page-pane widths 480, 360, 300, 260 and 200 pt (divider drags), the omnibar's text area
    (and its field) ends before every icon to its right inside the bar, starts after every icon to its left, and the
    bar stays inside the toolbar (debug.omnibar pointer frames, window points from the top left)."""
    layers = main_layers()
    frame = page_view(pane, layers)
    if not frame:
        row("INFO", "omnibar_narrow", {"note": "no in-tree page view"})
        return
    # The chip's natural (label) width: its widest frame in the run, from the widest pane first. debug.omnibar reports
    # frames only, no intrinsic size, so a chip that still shows its label (wider than the icon-only chip) but is
    # narrower than that is a clipped label ("Not secu", other Mac BEFORE 2026-11-24).
    chip_natural = [0.0]
    CHIP_ICON_ONLY_PT = 30  # the icon-only chip is 22.5 pt; any label makes it wider
    MIN_TEXT_PT = 40  # a URL field narrower than this shows a letter or two ("h.", 4 pt on BEFORE at 260 pt)
    for width in (480, 360, 300, 260, 200):
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
            chip = frames.get("chip")
            if chip:
                chip_natural[0] = max(chip_natural[0], chip[2])
                if CHIP_ICON_ONLY_PT < chip[2] < chip_natural[0] - 1:
                    problems.append(f"chip label clipped: {round(chip[2], 1)} pt of its {round(chip_natural[0], 1)} pt")
            if text and text[2] < MIN_TEXT_PT:
                problems.append(f"URL field {round(text[2], 1)} pt wide (< {MIN_TEXT_PT} pt)")
        rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, f"omnibar-{width}.png")})
        row(not problems, f"omnibar_narrow.{width}",
            {"bug": 15, "pane_width": frame[2] if frame else None, "problems": problems[:6],
             "frames": {k: v for k, v in frames.items()}, "text": report.get("text"),
             "chip_natural_pt": chip_natural[0],
             "pass_if": "text area ends before every icon to its right in the bar; bar inside the toolbar; the chip shows its "
                        "whole label or only its icon; the URL field at least 40 pt wide"})


KEY_CODES = {"command": 55, "shift": 56, "return": 36, "d": 2, "z": 6, "escape": 53}


def real_keys(keys):
    """Plays `keys` (modifier names, then one key) as a keyboard's raw transitions through the app's event queue
    (debug.key `sequence`: NSApp.postEvent, nextEvent, sendEvent, the key window), the path a real key takes, not the
    key router's own entry that `debug.key` without `sequence` calls. The keys go to whatever window is key now, as a
    person's do: no window is made key for them."""
    steps = [{"key_code": KEY_CODES[k], "down": True, "after_ms": 0 if i == 0 else 8} for i, k in enumerate(keys)]
    steps += [{"key_code": KEY_CODES[k], "down": False, "after_ms": 30 if i == 0 else 8} for i, k in enumerate(reversed(keys))]
    reply = rpc("debug.key", {"sequence": steps})
    time.sleep(0.25 + (reply.get("duration_ms") or 0) / 1000 if isinstance(reply, dict) else 0.5)  # test harness: the sequence plays
    return reply


def focus_facts():
    """What has the keys: the app's key window, the main window's first responder and its classification, the model's
    resolved target, and the in-tree gate's counters (debug.focus)."""
    focus = rpc("debug.focus") or {}
    window = (focus.get("windows") or [{}])[0]
    appkit, model = window.get("appkit") or {}, window.get("model") or {}
    return {"key_window": focus.get("key_window"), "app_active": focus.get("app_active"), "is_key": window.get("is_key"),
            "first_responder": appkit.get("first_responder"), "classified": appkit.get("classified"),
            "resolved": model.get("resolved"), "resolved_pane": model.get("resolved_pane"),
            "panes": len(window.get("topology") or []), "in_tree": focus.get("in_tree"),
            "creation_hold": window.get("creation_hold"), "mismatches": window.get("mismatches")}


def viewport_area(tab):
    v = page_json("window.viewport()", tab)
    return (v["w"] * v["h"]) if v else None


def check_key_route(tab, pane):
    """Bug 23 (sweep-06675353 D1): the page gets the keyboard by an action, with no click (tab.focus, the route of
    Cmd-Opt-arrow and a tab switch), from the terminal beside it. Then: the page's view is the window's first responder
    (a programmatic focus gives the page the keys exactly as a click does), a real letter reaches the page, real
    Cmd-Shift-Return zooms its pane and again unzooms it, and real Cmd-D splits it. Real keys: debug.key `sequence`
    (the app's event queue and sendEvent), never the router's own entry. In tree before the fix the gate refused the
    page (`gate_last_refusal` "no input event or focus route") and the shortcuts did nothing until a click."""
    # The cmux window is the key window, as for a person working in it (no-activate runs start with none).
    window_id = (((rpc("debug.focus") or {}).get("windows") or [{}])[0]).get("id")
    RAW["key_route_window_focus"] = rpc("debug.window.focus", {"window": window_id})
    terminal_tab = next((c for c in ((RAW.get("split") or {}).get("created") or []) if str(c).startswith("tab_")), None)
    if terminal_tab:
        action("tab.focus", target=f"tab:{terminal_tab}")
        time.sleep(0.5)  # test harness: the terminal takes the keys
    RAW["key_route_focus_terminal"] = focus_facts()
    page_eval("window.__k = []; if (!window.__kOn) { window.__kOn = true;"
              " document.addEventListener('keydown', e => window.__k.push(e.key), true); } true", tab)
    action("tab.focus", target=f"tab:{tab}")
    time.sleep(0.6)  # test harness: focus lands
    facts = focus_facts()
    RAW["key_route_focus"] = facts
    on = opts.in_tree == "on"
    # The keys stay with the cmux window (in tree) or its page's child window (off): never a window no cmux window
    # owns, such as an in-tree page's headless Chromium window.
    keys_home = facts["key_window"] in (("ShellWindow",) if on else ("ShellWindow", "CefNSWindow"))
    page_responder = keys_home and facts["resolved"] == "browserPage" \
        and (not on or ("RenderWidgetHostView" in str(facts["first_responder"]) and facts["is_key"]))
    row(page_responder, "key_route.responder",
        {"bug": 23, "facts": facts, "before": RAW["key_route_focus_terminal"], "window_focus": RAW["key_route_window_focus"],
         "pass_if": "after tab.focus with no click the cmux window keeps the keys and the page's view is its first responder"})
    real_keys(["z"])
    keys = page_json("JSON.stringify(window.__k)", tab)
    row(keys == ["z"], "key_route.page_key",
        {"bug": 23, "page_keys": keys, "facts": focus_facts(), "pass_if": "a real z reaches the page's document"})
    last0 = rpc("debug.key", {"last": True})
    area0 = viewport_area(tab)
    record("key_route", 8)
    for direction in ("zoom", "unzoom"):
        reply = real_keys(["command", "shift", "return"])
        time.sleep(0.8)  # test harness: the zoom spring settles
        area = viewport_area(tab)
        if direction == "zoom":
            ok = bool(area and area0) and area >= 1.3 * area0
        else:
            ok = bool(area and area0) and abs(area - area0) <= 0.05 * area0
        row(ok, f"key_route.{direction}",
            {"bug": 23, "viewport_area_before": area0, "viewport_area": area, "sequence": reply,
             "router_last_before": last0, "router_last": rpc("debug.key", {"last": True}), "facts": focus_facts(),
             "pass_if": "real Cmd-Shift-Return after tab.focus: zoom area >= 1.3x, unzoom back within 5%"})
    action("tab.focus", target=f"tab:{tab}")
    time.sleep(0.4)  # test harness: focus lands
    panes0 = focus_facts()["panes"]
    reply = real_keys(["command", "d"])
    panes = wait(lambda: (lambda n: n if n > panes0 else None)(focus_facts()["panes"]), 6)
    row(bool(panes), "key_route.split",
        {"bug": 23, "panes_before": panes0, "panes_after": panes or focus_facts()["panes"], "sequence": reply,
         "router_last": rpc("debug.key", {"last": True}), "facts": focus_facts(),
         "pass_if": "real Cmd-D after tab.focus adds a pane"})
    if panes:
        action("closePane")  # the new pane has the focus; the page's pane stays
        time.sleep(1.0)  # test harness: the pane closes


def page_views_frames(layers=None):
    """Every shown (unparked) page view's frame in the main window, by pane."""
    return {str(v.get("pane")): v.get("frame_in_window") for v in (layers or main_layers()).get("page_views") or [] if not v.get("parked")}


def same_frame(a, b, px=0.5):
    return bool(a and b) and len(a) == len(b) and all(abs(x - y) <= px for x, y in zip(a, b))


def make_key():
    """The cmux window (in tree) or the page's window (off) becomes the app's key window without activating the app,
    as a person's click into the page makes it: a Shift tap through the app's event queue with debug.key `key_window`."""
    steps = [{"key_code": KEY_CODES["shift"], "down": True, "after_ms": 0}, {"key_code": KEY_CODES["shift"], "down": False, "after_ms": 20}]
    reply = rpc("debug.key", {"sequence": steps, "key_window": "shell" if opts.in_tree == "on" else "page"})
    time.sleep(0.3)  # test harness: the tap plays and the key status reaches the page's view
    return reply


def check_element_fullscreen(tab, pane):
    """Bug 24 (sweep-06675353 D9): element full screen from a page click. requestFullscreen() on a div rejected
    "TypeError: not granted" in both modes; Chrome gives the element the window's content (tab fullscreen), enters
    the window's full screen when it is not there and leaves it on exit, and Escape exits. Per variant: the element is
    document.fullscreenElement, the window is in full screen, the page view fills the window within 2 pt, :fullscreen
    applies (box), fullscreenchange fired; after the exit no fullscreen element and the window frame, its full screen
    state and every page view frame equal the start within 0.5 pt."""
    page_eval(f"location.href = {json.dumps(URL + 'fs')}; true", tab)
    if not wait(lambda: page_eval("window.fsReady === true", tab).get("value") is True, 30, 0.3):
        row(False, "element_fullscreen.setup", {"bug": 24, "note": "the fs page did not load"})
        return
    time.sleep(0.5)  # test harness: the fs page draws

    def state():
        return page_json("window.fsState()", tab) or {}

    def click(button):
        centre = page_json(f"window.buttonCentre({json.dumps(button)})", tab)
        return rpc("debug.mouse", {"target": "page", "pane": pane, "x": centre[0], "y": centre[1]}) if centre else {"error": "no button"}

    def settle(predicate, seconds=6.0):
        """Waits for `predicate` and then for the page view to hold still for 0.5 s."""
        ok = wait(predicate, seconds, 0.1)
        last, since, end = None, time.time(), time.time() + 4
        while time.time() < end:
            frame = page_view(pane)
            if frame != last:
                last, since = frame, time.time()
            elif time.time() - since > 0.5:
                break
            time.sleep(0.05)  # test harness: one sample a few display frames
        return ok

    # The sweep's state: the same click with no key window (an agent launch never activates the app).
    facts0 = focus_facts()
    click("fsbox")
    time.sleep(1.0)  # test harness: the request resolves
    st = state()
    row("INFO", "element_fullscreen.unfocused", {"bug": 24, "state": st, "facts": facts0,
                                                  "note": "Chromium refuses fullscreen to a view without focus (kSuppressFullscreenFromUnfocusedView)"})
    if st.get("el"):
        page_eval("document.exitFullscreen(); true", tab)
        settle(lambda: not state().get("el") and not is_full_screen())

    for variant, button, element, exit_by, window_fs in (("box", "fsbox", "box", "escape", False),
                                                         ("video", "fsvid", "vid", "api", False),
                                                         ("box_in_fs", "fsbox", "box", "escape", True)):
        if window_fs:
            action("toggleFullScreen")
            if not wait(is_full_screen, 8):
                row(False, f"element_fullscreen.{variant}.setup", {"bug": 24, "note": "the window did not enter full screen"})
                continue
            time.sleep(1.5)  # test harness: the full-screen Space settles
        layers0 = main_layers()
        start = {"window": layers0.get("frame"), "full_screen": is_full_screen(), "views": page_views_frames(layers0)}
        record(f"element_fullscreen_{variant}", 10)
        key = make_key()
        sent = click(button)
        entered = settle(lambda: state().get("el") == element and is_full_screen())
        layers = main_layers()
        st, window, view = state(), layers.get("frame"), page_view(pane, layers)
        fills = bool(window and view) and abs(view[0]) <= 2 and abs(view[1]) <= 2 and abs(view[2] - window[2]) <= 2 \
            and abs(view[3] - window[3]) <= 2 and abs((st.get("w") or 0) - window[2]) <= 2 and abs((st.get("h") or 0) - window[3]) <= 2
        css = element != "box" or st.get("box_bg") == "rgb(51, 204, 51)"
        changed = any(e[1] == "change" and e[2] == element for e in st.get("log") or [])
        rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, f"element-fullscreen-{variant}.png")})
        row(bool(entered) and fills and css and changed, f"element_fullscreen.{variant}.enter",
            {"bug": 24, "state": st, "window": window, "page_view": view, "full_screen": is_full_screen(), "click": sent,
             "key": key, "facts": focus_facts(),
             "pass_if": "fullscreenElement is the element, window in full screen, page view fills the window within 2 pt, "
                        ":fullscreen applies, fullscreenchange fired"})
        if exit_by == "escape":
            # A real Escape through the app's event queue to the key window that holds the page.
            how = rpc("debug.key", {"sequence": [{"key_code": KEY_CODES["escape"], "down": True, "after_ms": 0},
                                                 {"key_code": KEY_CODES["escape"], "down": False, "after_ms": 40}],
                                    "key_window": "shell" if opts.in_tree == "on" else "page"})
        else:
            how = page_eval("document.exitFullscreen().then(() => true, e => String(e))", tab)
        left = settle(lambda: not state().get("el") and is_full_screen() == start["full_screen"])
        time.sleep(0.5)  # test harness: the layout settles after the exit
        layers = main_layers()
        end = {"window": layers.get("frame"), "full_screen": is_full_screen(), "views": page_views_frames(layers)}
        restored = end["full_screen"] == start["full_screen"] and same_frame(end["window"], start["window"]) \
            and end["views"].keys() == start["views"].keys() and all(same_frame(end["views"][k], start["views"][k]) for k in start["views"])
        rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, f"element-fullscreen-{variant}-exit.png")})
        row(bool(left) and restored, f"element_fullscreen.{variant}.exit_{exit_by}",
            {"bug": 24, "state": state(), "start": start, "end": end, "exit": how,
             "pass_if": "no fullscreen element; window frame, full screen state and every page view frame as at the start (0.5 pt)"})
        if st.get("el") and state().get("el"):  # the exit did not take: leave for the next variant
            page_eval("document.exitFullscreen(); true", tab)
            settle(lambda: not state().get("el"))
        if is_full_screen():  # back to a windowed window for the next variant
            action("toggleFullScreen")
            wait(lambda: not is_full_screen(), 8)
            time.sleep(1.0)  # test harness: the window settles


REGRESSION_CHECKS = ("pane_fit", "divider_resize", "window_resize", "fullscreen", "resize_hitch", "live_resize", "divider_load", "window_move", "tab_spam", "pane_zoom",
                     "popup_float", "omnibar_narrow", "key_route", "element_fullscreen")


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1300,860",
       "CMUX_IN_TREE_PAGES": "1" if opts.in_tree == "on" else "0"}
for pair in opts.app_env:
    key, _, val = pair.partition("=")
    if key:
        env[key] = val
RAW["app_env"] = opts.app_env
# Through bench_launch (fresh saved state, a refusal when another app of the tag runs, and a refusal when the app comes
# up in the other in-tree mode): a bare Popen answered by a leftover app of the tag reported in_tree off with
# CMUX_IN_TREE_PAGES=1 (step verify-live-e67776ff-cmux19).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import bundle_id, launch_app  # noqa: E402


def clear_run_marker(app_path):
    """Removes the app's crash run marker (`AppRunMarker`: run.json, run.signal and run.exception in Application
    Support/cmux-next/<bundle id>), only those three files of this app's own bundle id. The harness ends each run with
    debug.quit and a kill after its wait, which can leave the marker, and the next launch of the tag then showed "cmux
    restarted after a problem" over every still (other Mac, 2026-11-24: every launch 07:18 to 07:59 logged "previous run
    ended unexpectedly signal=0"). A real crash of this run still leaves its marker, its report and its log line."""
    bid = bundle_id(app_path)
    if not bid:
        return {"error": "no bundle id"}
    safe = "".join(c if c.isalnum() or c in ".-" else "_" for c in bid)
    folder = os.path.join(os.path.expanduser("~/Library/Application Support/cmux-next"), safe)
    removed = []
    for name in ("run.json", "run.signal", "run.exception"):
        path = os.path.join(folder, name)
        if os.path.isfile(path):
            os.unlink(path)
            removed.append(name)
    return {"folder": folder, "removed": removed}


RAW["run_marker_cleared"] = clear_run_marker(opts.app)
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
    # Chromium first: a step whose app has no Chromium runtime (the fleet's download failed: no credentials, the
    # store's 503) stops here in seconds and says so, instead of a `page` FAIL after a 60 s wait with every row unrun
    # (step 055f2175: "Chromium is not available in this build", unavailable notBundled).
    cef_word = rpc("debug.cef") or {}
    unavailable = cef_word.get("unavailable") if isinstance(cef_word, dict) else None
    if unavailable:
        RAW["cef_at_launch"] = cef_word
        row("FAIL", "rig.no_chromium", {"note": "the app has no Chromium runtime: no row can run (a rig limit, not a "
                                                 "product result); run on a host whose app has the runtime",
                                        "unavailable": unavailable, "runtime": cef_word.get("runtime")})
        raise SystemExit
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
                              ("resize_hitch", check_resize_hitch), ("live_resize", check_live_resize), ("divider_load", check_divider_load),
                              ("pane_zoom", check_pane_zoom), ("popup_float", check_popup_float),
                              ("omnibar_narrow", check_omnibar_narrow), ("window_move", check_window_move), ("tab_spam", check_tab_spam),
                              ("key_route", check_key_route), ("element_fullscreen", check_element_fullscreen)):
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
RAW["page_eval_failures"] = PAGE_EVAL_FAILURES
report = {"in_tree_requested": opts.in_tree, "rows": ROWS, "failed": len(failed), "raw": RAW}
with open(opts.json or os.path.join(opts.out, "in-tree-live.json"), "w") as f:
    json.dump(report, f, indent=1, default=str)
print(f"in-tree-live-checks: {len(ROWS) - len(failed)} of {len(ROWS)} rows pass (in-tree {opts.in_tree})", flush=True)
sys.exit(1 if failed else 0)

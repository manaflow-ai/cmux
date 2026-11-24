#!/usr/bin/env python3
"""Coverage rows for in-tree Chromium pages: every browser path and the tab/pane/window paths next to it that
in-tree-live-checks.py and cef-layer-verify.py do not check (in-tree-coverage.md is the matrix; each MISSING row
there that can run headlessly is a group here).

Launches the tagged app (no activation, automation socket, scratch config, CMUX_IN_TREE_PAGES by --in-tree), opens
in-tree-coverage-site/cov.html in a Chromium page beside a terminal, and runs the groups in --checks:

  nav            history: browserBack/browserForward actions, real Cmd-[ / Cmd-], a two-finger (phased scroll) swipe
  reload_stop    browserReload and real Cmd-R reload the page (sessionStorage load count); browserStop leaves a slow
                 navigation (the server holds /slow 10 s) on the old page
  omnibar        debug.omnibar_type commits a typed URL; typing a prefix of a visited URL shows suggestion rows
  find           real Cmd-F, typed text and Return select the match in the page (getSelection)
  zoom           real Cmd-= / Cmd-- / Cmd-0 and the zoom actions change devicePixelRatio and back; a Ctrl-wheel reaches
                 the page with ctrlKey
  clipboard      a double click and a drag select page text; real Cmd-C puts the selection on the pasteboard; real
                 Cmd-V pastes the pasteboard into a page field
  dnd            an HTML5 drag (draggable element onto a drop target) inside the page
  context_menu   a right click on page text and on a link shows the page menu (debug.menu) and the page sees
                 contextmenu; a DevTools right click (Input.dispatchMouseEvent) as the mode-neutral route
  dialogs        alert/confirm/prompt answered through debug.dialog (OK, Cancel, typed text reach the page);
                 beforeunload: a reload asks, Cancel stays, Leave reloads
  choosers       <input multiple>, webkitdirectory and showSaveFilePicker each show a sheet that reaches the app and
                 cancel back to the page; browser.page.upload delivers two real files through the chooser
  downloads      a link download and a blob download finish with the right bytes in the downloads folder
  popups         window.open popup: closed by its opener and by itself (debug.popups count back, opener sees closed);
                 a target=_blank link opens a tab, not a popup
  devtools_dock  DevTools docked bottom, docked right, undocked into a window, closed: the frames and the page fit
  media_perms    getUserMedia camera and microphone ask in the prompt bar; Block fails with NotAllowedError
  http_auth      a 401 Basic page asks (browser.dialog.httpAuth): Cancel shows the 401 body, Sign In loads the page
  hover          a pointer move over a link/box fires mouseover and :hover, mouseout on leave; the cursor is a hand
                 over the link and an I-beam over text (debug.cursor)
  pointer_lock   a click whose handler asks for pointer lock gets it; a real Escape releases it
  scroll         a wheel over a nested scroller scrolls it, not the page
  video          a canvas stream and a recorded WebM both play (requestVideoFrameCallback frames, currentTime)
  ime            DevTools Input.imeSetComposition + insertText reach a focused field (renderer side only)
  ax             the window's accessibility tree (CuaDriver, the daemon's grant) reaches the page's button and heading
  focus_routes   real Cmd-Opt-arrow from the terminal gives the page the keys and back; real keys after a page click
  shortcuts      with the page focused by a click: each cmux shortcut as a real key (debug.key sequence), its router
                 action (dry run) and its effect
  tab_switch     a second page tab in the same pane: hidden while behind, back by tab.focus and by real Ctrl-Tab with
                 its document and state, one shown page view that fits
  pane_close     a page in a second pane closes with its pane: no unplaced view, the other page fits
  window_move    a programmatic and an Accessibility move: the page view keeps its frame and the page's screenX/Y follow
  minimize       minimizeWindow hides the page (visibilityState) and showMainWindow restores it drawn and responsive
  tab_move       a tab dragged to another pane (debug.mouse on its strip), moved to a new split and to a new window
  crash          SIGKILL of the page's renderer shows the sad tab; its Reload brings the page back in tree
  memory50       50 page tabs opened then closed: all load, the footprint and helper count come back near the start

Every row prints `PASS|FAIL|INFO | name | detail` (detail has `pass_if`); INFO means the row could not apply (a rig
limit, named in `note`), never a pass. --json writes rows and raw readouts; window snapshots and recordings land in
--out. Exits 0 when no row fails. Fleet display worker only (no focus taken: debug.key `key_window` makes the cmux
window key without activating the app).
"""
import argparse, base64, hashlib, http.server, json, os, plistlib, signal, socket, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.join(HERE, "in-tree-coverage-site")
# Risky groups last: a context menu can hold the main thread, tab_move opens a window, crash kills the renderer.
ALL = ("nav,reload_stop,omnibar,find,zoom,clipboard,dnd,dialogs,choosers,downloads,popups,devtools_dock,"
       "media_perms,http_auth,hover,pointer_lock,scroll,video,ime,ax,focus_routes,shortcuts,tab_switch,pane_close,"
       "window_move,minimize,context_menu,tab_move,crash,memory50")
TIMEOUTS = [0]
parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", default=tempfile.mkdtemp(prefix="in-tree-coverage-"))
parser.add_argument("--json")
parser.add_argument("--in-tree", dest="in_tree", choices=["on", "off"], default="on")
parser.add_argument("--checks", default=ALL)
parser.add_argument("--tabs", type=int, default=50, help="memory50: tabs to open")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
CHECKS = [c for c in opts.checks.split(",") if c]
ON = opts.in_tree == "on"
with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(opts.app, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
ROWS, RAW = [], {}
DOWNLOADS = os.path.join(opts.out, "downloads")
os.makedirs(DOWNLOADS, exist_ok=True)
TOKEN = hashlib.sha1(str(time.time()).encode()).hexdigest()[:10]
DL_BYTES = bytes((i * 7 + 3) % 251 for i in range(65536))
SERVER_LOG = []

# Virtual key codes (ANSI) for debug.key `sequence`.
KC = {"command": 55, "shift": 56, "option": 58, "control": 59, "return": 36, "escape": 53, "tab": 48, "left": 123,
      "right": 124, "up": 126, "down": 125, "a": 0, "c": 8, "d": 2, "f": 3, "i": 34, "l": 37, "n": 45, "p": 35, "q": 12,
      "r": 15, "t": 17, "v": 9, "w": 13, "x": 7, "z": 6, "1": 18, "=": 24, "-": 27, "0": 29, "[": 33, "]": 30, "k": 40}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        SERVER_LOG.append([time.time(), self.path])
        if path == "/slow":
            try:
                time.sleep(10)
                self.reply(b"<!doctype html><title>slow</title>slow page", "text/html")
            except OSError:
                SERVER_LOG.append([time.time(), "slow aborted"])
            return
        if path.startswith("/auth"):
            auth = self.headers.get("Authorization") or ""
            if auth.startswith("Basic ") and base64.b64decode(auth[6:]).decode(errors="replace") == "cmux:pw-123":
                return self.reply(b"<!doctype html><title>authed</title><p id=a>authed:cmux</p>", "text/html")
            body = b"<!doctype html><title>401</title><p id=a>auth-required-401</p>"
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="cmux coverage"')
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path.startswith("/dl/"):
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="cov-download.bin"')
            self.send_header("Content-Length", str(len(DL_BYTES)))
            self.end_headers()
            self.wfile.write(DL_BYTES)
            return
        name = os.path.basename(path) or "cov.html"
        file = os.path.join(SITE, name)
        if not os.path.isfile(file):
            file = os.path.join(SITE, "cov.html")
        with open(file, "rb") as f:
            self.reply(f.read(), "text/html")

    def reply(self, body, kind):
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


def cov_url(n):
    return f"{URL}cov.html?n={n}&token={TOKEN}"


# ---- socket and app helpers (as in-tree-live-checks.py) ----

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
        TIMEOUTS[0] = 0
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        if "timed out" in str(error):
            TIMEOUTS[0] += 1
            if TIMEOUTS[0] >= 4:  # the app stopped answering: stop here rather than wait out every later call
                RAW["app_stopped_answering"] = {"method": method, "at": time.time()}
                row(False, "app.answers", {"method": method, "pass_if": "the app answers its socket (4 timeouts in a row)"})
                raise SystemExit
        return {"error": str(error)}


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = predicate()
        except Exception:  # a probe that throws is not true yet
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def row(verdict, name, detail):
    if verdict is True:
        verdict = "PASS"
    elif verdict is False or verdict is None:
        verdict = "FAIL"
    ROWS.append({"verdict": verdict, "name": name, "detail": detail})
    print(f"{verdict} | {name} | {json.dumps(detail, default=str)[:700]}", flush=True)


def info_off(name, why, **detail):
    row("INFO", name, dict(detail, note=f"rig: {why}"))


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


def val(script, tab):
    return page_eval(script, tab).get("value")


def pj(script, tab):
    value = val(script, tab)
    try:
        return json.loads(value) if isinstance(value, str) else None
    except ValueError:
        return None


def snap(name):
    return rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, f"{name}.png")})


RECORD_UNTIL = [0.0]


def record(name, seconds=8):
    folder = os.path.join(opts.out, f"video-{name}")
    os.makedirs(folder, exist_ok=True)
    left = RECORD_UNTIL[0] - time.time()
    if left > 0:
        time.sleep(left + 0.2)  # test harness: one recording at a time per app
    RAW.setdefault("recordings", {})[name] = rpc("debug.window_record", {"dir": folder, "seconds": seconds})
    RECORD_UNTIL[0] = time.time() + seconds


def windows():
    layers = rpc("debug.layers")
    return (layers.get("windows") if isinstance(layers, dict) else None) or []


def main_layers():
    return (windows() or [{}])[0]


def focus_facts():
    focus = rpc("debug.focus") or {}
    window = (focus.get("windows") or [{}])[0]
    appkit, model = window.get("appkit") or {}, window.get("model") or {}
    return {"key_window": focus.get("key_window"), "first_responder": appkit.get("first_responder"),
            "resolved": model.get("resolved"), "resolved_pane": model.get("resolved_pane"),
            "panes": len(window.get("topology") or []), "context": focus.get("context")}


def topology():
    focus = rpc("debug.focus") or {}
    return [p for w in focus.get("windows") or [] for p in w.get("topology") or []]


def page_pane(tab):
    for pane in topology():
        if any(str(t).split(":", 1)[0] == str(tab) for t in pane.get("tabs") or []):
            return pane.get("pane")
    return None


def page_view(pane, layers=None):
    layers = layers or main_layers()
    views = [v for v in layers.get("page_views") or [] if not v.get("parked") and (pane is None or v.get("pane") == pane)]
    return views[0].get("frame_in_window") if views else None


def unplaced(layers=None):
    out = []
    for w in ([layers] if layers else windows()):
        out += [v for v in w.get("page_views") or [] if v.get("parking") == "unplaced"]
    return out


def fits(tab, pane, px=1.0):
    vp = pj("JSON.stringify({w: innerWidth, h: innerHeight})", tab)
    frame = page_view(pane)
    if not ON:
        return {"ok": bool(vp), "viewport": vp, "page_view": None}
    ok = bool(vp and frame) and abs(vp["w"] - frame[2]) <= px and abs(vp["h"] - frame[3]) <= px
    return {"ok": ok, "viewport": vp, "page_view": frame}


def window_point(tab, pane, selector):
    """A page element's centre as a debug.mouse window point (top-left window points); None with the mode off (no
    in-tree page view: the page is a child window the cmux window's events never reach)."""
    c = pj(f"window.centre({json.dumps(selector)})", tab)
    layers = main_layers()
    frame = page_view(pane, layers)
    if not c or not frame:
        return None
    height = (layers.get("frame") or [0, 0, 0, 0])[3]
    return [frame[0] + c[0], height - (frame[1] + frame[3]) + c[1]]


def page_click(tab, pane, selector, **extra):
    """A left click on the element through debug.mouse target page (both modes: the page's own view)."""
    c = pj(f"window.centre({json.dumps(selector)})", tab)
    if not c:
        return {"error": f"no element {selector}"}
    return rpc("debug.mouse", dict({"target": "page", "pane": pane, "x": c[0], "y": c[1]}, **extra))


def make_key():
    steps = [{"key_code": KC["shift"], "down": True, "after_ms": 0}, {"key_code": KC["shift"], "down": False, "after_ms": 20}]
    reply = rpc("debug.key", {"sequence": steps, "key_window": "shell" if ON else "page"})
    time.sleep(0.3)  # test harness: the tap plays and the key status lands
    return reply


def real_keys(keys):
    """Modifiers then one key as raw transitions through the app's event queue (debug.key sequence)."""
    steps = [{"key_code": KC[k], "down": True, "after_ms": 0 if i == 0 else 8} for i, k in enumerate(keys)]
    steps += [{"key_code": KC[k], "down": False, "after_ms": 30 if i == 0 else 8} for i, k in enumerate(reversed(keys))]
    reply = rpc("debug.key", {"sequence": steps})
    time.sleep(0.25 + ((reply.get("duration_ms") or 0) / 1000 if isinstance(reply, dict) else 0.25))  # test harness
    return reply


def dry(key, modifiers):
    reply = rpc("debug.key", {"key": key, "modifiers": modifiers, "dry_run": True})
    return (reply or {}).get("action") if isinstance(reply, dict) else None


def page_ready(tab, n=None, seconds=30):
    check = "window.covReady === true" + (f" && new URLSearchParams(location.search).get('n') === {json.dumps(n)}" if n else "")
    return wait(lambda: val(check, tab) is True, seconds, 0.3)


def navigate(tab, n):
    page_eval(f"location.href = {json.dumps(cov_url(n))}; true", tab)
    return page_ready(tab, n)


def events_since(tab, t0):
    return pj(f"window.evSince({int(t0 * 1000)})", tab) or []


def focus_page(tab, pane):
    """The page focused as a person does: its tab, the cmux window key, a click on a blank part of the page."""
    action("tab.focus", target=f"tab:{tab}")
    time.sleep(0.3)  # test harness: focus lands
    make_key()
    page_click(tab, pane, "#axh")
    time.sleep(0.3)  # test harness: the click lands
    return focus_facts()


def tab_count():
    surfaces = rpc("debug.tab_drag")
    return sum(len(s.get("tabs") or []) for s in (surfaces or {}).get("strips") or []) if isinstance(surfaces, dict) else None


def sheets():
    return [{k: w.get(k) for k in ("id", "kind", "title", "visible", "parent", "class")}
            for w in ((rpc("debug.window_list") or {}).get("windows") or [])
            if w.get("kind") == "sheet" or "OpenPanel" in str(w.get("class")) or "SavePanel" in str(w.get("class"))
            or w.get("title") in ("Open", "Save")]


def file_dialogs():
    reply = (rpc("debug.cef") or {}).get("file_dialogs") or {}
    return dict(reply, received=int(reply.get("received") or 0))


CUA_DRIVER = next((c for c in ("/Applications/CuaDriver.app/Contents/MacOS/cua-driver", os.path.expanduser("~/.local/bin/cua-driver"))
                   if os.path.exists(c)), None)


def cua(tool, args):
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


def main_window_id():
    listed = cua("list_windows", {})
    wins = [w for w in (listed.get("windows") or []) if w.get("pid") == RAW.get("pid") and w.get("bounds")]
    wins.sort(key=lambda w: -w["bounds"]["width"] * w["bounds"]["height"])
    return wins[0]["window_id"] if wins else None


def cancel_sheet():
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
    rpc("debug.key", {"key": "escape"})
    return "escape"


def dialogs(identifier=None):
    listed = (rpc("debug.dialog") or {}).get("dialogs") or []
    return [d for d in listed if d.get("visible") and (identifier is None or d.get("identifier") == identifier)]


def guard(name, fn, *args):
    try:
        fn(*args)
    except Exception as error:  # one broken group never hides the others
        import traceback
        row(False, f"{name}.error", {"error": repr(error)[:300], "trace": traceback.format_exc()[-600:]})


# ---- groups ----

def g_nav(tab, pane):
    navigate(tab, "h1")
    navigate(tab, "h2")
    n = lambda: val("new URLSearchParams(location.search).get('n')", tab)
    action("tab.focus", target=f"tab:{tab}")
    action("browserBack")
    back = wait(lambda: n() == "h1", 8)
    row(bool(back), "nav.back_action", {"n": n(), "pass_if": "browserBack from ?n=h2 shows ?n=h1 within 8 s"})
    action("browserForward")
    fwd = wait(lambda: n() == "h2", 8)
    row(bool(fwd), "nav.forward_action", {"n": n(), "pass_if": "browserForward shows ?n=h2 again within 8 s"})
    page_ready(tab, "h2")
    focus_page(tab, pane)
    claimed = dry("[", ["command"])
    real_keys(["command", "["])
    kb = wait(lambda: n() == "h1", 8)
    row(bool(kb), "nav.back_key", {"n": n(), "router": claimed, "facts": focus_facts(),
                                    "pass_if": "real Cmd-[ with the page focused by a click goes back within 8 s"})
    page_ready(tab, "h1")
    focus_page(tab, pane)
    claimed = dry("]", ["command"])
    real_keys(["command", "]"])
    kf = wait(lambda: n() == "h2", 8)
    row(bool(kf), "nav.forward_key", {"n": n(), "router": claimed, "pass_if": "real Cmd-] goes forward within 8 s"})
    page_ready(tab, "h2")
    # Two-finger swipe right (back): a phased trackpad scroll over the page, as the trackpad sends.
    point = window_point(tab, pane, "#tall")
    if not point:
        return info_off("nav.swipe_back", "no in-tree page view: debug.mouse scroll reaches only the cmux window")
    make_key()
    replies = [rpc("debug.mouse", {"action": "scroll", "x": point[0], "y": point[1], "dx": 0, "dy": 0, "phase": "began"})]
    for _ in range(14):
        replies.append(rpc("debug.mouse", {"action": "scroll", "x": point[0], "y": point[1], "dx": 40, "dy": 0, "phase": "changed"}))
        time.sleep(0.016)  # test harness: one event a display frame, as a trackpad sends
    replies.append(rpc("debug.mouse", {"action": "scroll", "x": point[0], "y": point[1], "dx": 0, "dy": 0, "phase": "ended"}))
    sw = wait(lambda: n() == "h1", 6)
    row(bool(sw), "nav.swipe_back", {"n": n(), "delivered_to": [r.get("delivered_to") for r in replies[:3] if isinstance(r, dict)],
                                      "note": "synthetic phased scroll; history swipe also needs trackSwipeEvent from a real "
                                              "gesture: FAIL in both modes means the rig, FAIL in one mode only is a defect",
                                      "pass_if": "a 560 pt rightward phased scroll goes back within 6 s"})


def g_reload_stop(tab, pane):
    navigate(tab, "rl")
    loads = lambda: int(val("Number(sessionStorage.loads || 0)", tab) or 0)
    l0 = loads()
    action("tab.focus", target=f"tab:{tab}")
    action("browserReload")
    ok = wait(lambda: loads() > l0 and val("window.covReady === true", tab) is True, 10)
    row(bool(ok), "reload.action", {"loads": [l0, loads()], "pass_if": "browserReload loads the page again within 10 s"})
    l1 = loads()
    focus_page(tab, pane)
    claimed = dry("r", ["command"])
    real_keys(["command", "r"])
    ok = wait(lambda: loads() > l1 and val("window.covReady === true", tab) is True, 10)
    row(bool(ok) if claimed == "browserReload" else ("INFO" if not ok else True), "reload.key",
        {"loads": [l1, loads()], "router": claimed,
         "pass_if": "real Cmd-R reloads the focused page when the router maps it to browserReload (else INFO)"})
    page_ready(tab, "rl")
    page_eval(f"location.href = {json.dumps(URL + 'slow?x=1')}; true", tab)
    time.sleep(1.0)  # test harness: the slow request is in flight
    stopped = action("browserStop")
    time.sleep(11)  # test harness: past the server's 10 s hold
    path = val("location.pathname", tab)
    alive = val("window.covReady === true", tab)
    row(path != "/slow" and alive is True, "stop.action",
        {"path": path, "page_alive": alive, "stop": str(stopped)[:120], "server": [e[1] for e in SERVER_LOG[-4:]],
         "pass_if": "browserStop 1 s into a 10 s navigation leaves the old page shown and live"})
    navigate(tab, "main")


def g_omnibar(tab, pane):
    action("tab.focus", target=f"tab:{tab}")
    typed = rpc("debug.omnibar_type", {"text": cov_url("omni"), "commit": True, "pane": pane})
    ok = page_ready(tab, "omni", 15)
    row(bool(ok), "omnibar.commit", {"typed": str(typed)[:200], "pass_if": "a URL typed in the omnibar and Return loads it"})
    typed = rpc("debug.omnibar_type", {"text": "127.0.0.1", "commit": False, "pane": pane})
    shown = wait(lambda: (rpc("debug.omnibar", {"pane": pane}) or {}).get("rows"), 5)
    omni = rpc("debug.omnibar", {"pane": pane}) or {}
    snap("omnibar-suggestions")
    row(bool(shown), "omnibar.suggestions",
        {"rows": (omni.get("rows") or [])[:6], "phase": omni.get("phase"), "field_text": omni.get("field_text"),
         "pass_if": "typing a prefix of visited URLs shows at least one suggestion row within 5 s"})
    rpc("debug.key", {"key": "escape"})
    rpc("debug.key", {"key": "escape"})
    navigate(tab, "main")


def g_find(tab, pane):
    focus_page(tab, pane)
    page_eval("getSelection().removeAllRanges(); true", tab)
    claimed = dry("f", ["command"])
    real_keys(["command", "f"])
    time.sleep(0.6)  # test harness: the find bar opens
    facts = focus_facts()
    for ch in "needle":
        rpc("debug.key", {"key": ch})
    time.sleep(0.8)  # test harness: the find runs
    snap("find-open")
    rpc("debug.key", {"key": "return"})
    time.sleep(0.4)  # test harness: next match
    real_keys(["escape"])
    time.sleep(0.5)  # test harness: the bar closes and the match becomes the selection
    sel = val("String(getSelection())", tab)
    row(sel == "needle", "find.key", {"selection": sel, "router": claimed, "facts_while_open": facts,
                                       "pass_if": "real Cmd-F, 'needle', Return, Escape leaves the match selected in the page"})


def g_zoom(tab, pane):
    dpr = lambda: val("devicePixelRatio", tab)
    focus_page(tab, pane)
    d0 = dpr()
    steps = []
    for keys, want in ((["command", "="], "up"), (["command", "-"], "back"), (["command", "0"], "reset")):
        claimed = dry(keys[-1], ["command"])
        real_keys(keys)
        time.sleep(0.8)  # test harness: the zoom applies
        steps.append({"key": "+".join(keys), "router": claimed, "dpr": dpr()})
    up, back, reset = (s["dpr"] for s in steps)
    ok = isinstance(d0, (int, float)) and isinstance(up, (int, float)) and up > d0 + 0.05 and abs((reset or 0) - d0) < 0.01
    row(ok, "zoom.keys", {"dpr0": d0, "steps": steps, "pass_if": "real Cmd-= raises devicePixelRatio; Cmd-0 restores it"})
    action("tab.focus", target=f"tab:{tab}")
    action("browserZoomIn")
    time.sleep(0.8)  # test harness: the zoom applies
    zin = dpr()
    action("browserZoomReset")
    time.sleep(0.8)  # test harness
    zr = dpr()
    row(isinstance(zin, (int, float)) and zin > (d0 or 0) + 0.05 and abs((zr or 0) - (d0 or 0)) < 0.01, "zoom.actions",
        {"dpr0": d0, "zoom_in": zin, "reset": zr, "fits": fits(tab, pane), "pass_if": "browserZoomIn raises dpr, browserZoomReset restores it"})
    point = window_point(tab, pane, "#tall")
    if not point:
        return info_off("zoom.ctrl_wheel", "no in-tree page view for a window-point wheel")
    t0 = time.time()
    rpc("debug.mouse", {"action": "scroll", "x": point[0], "y": point[1], "dx": 0, "dy": -120, "modifiers": ["ctrl"]})
    time.sleep(0.6)  # test harness: the wheel lands
    wheels = [e for e in events_since(tab, t0) if e[1] == "wheel"]
    row(any(e[3] is True for e in wheels), "zoom.ctrl_wheel",
        {"wheels": wheels[:4], "dpr_after": dpr(), "scale": val("visualViewport.scale", tab),
         "note": "pinch (magnify events) has no debug.mouse route", "pass_if": "a Ctrl-wheel reaches the page with ctrlKey"})
    action("browserZoomReset")


def g_clipboard(tab, pane):
    focus_page(tab, pane)
    point = window_point(tab, pane, "#sel")
    if point:
        page_eval("getSelection().removeAllRanges(); true", tab)
        rpc("debug.mouse", {"action": "double_click", "x": point[0], "y": point[1]})
        time.sleep(0.5)  # test harness: the clicks land
        sel = val("String(getSelection())", tab)
        row(sel == "cmuxselectword", "select.double_click", {"selection": sel, "pass_if": "a double click selects the word"})
        start, end = window_point(tab, pane, "#textp"), None
        rect = pj("window.centre('#textp')", tab)
        if start and rect:
            x0 = start[0] - rect[2] / 2 + 4
            page_eval("getSelection().removeAllRanges(); true", tab)
            rpc("debug.mouse", {"action": "drag", "x": x0, "y": start[1], "to_x": x0 + min(rect[2] - 8, 260), "to_y": start[1], "steps": 20})
            time.sleep(0.5)  # test harness: the drag lands
            sel = val("String(getSelection())", tab) or ""
            row(len(sel) >= 15, "select.drag", {"selection": sel[:80], "pass_if": "a 260 pt mouse drag over text selects >= 15 characters"})
    else:
        info_off("select.double_click", "no in-tree page view for window-point mouse events")
        info_off("select.drag", "no in-tree page view for window-point mouse events")
    # Copy: the page selects its token paragraph, a real Cmd-C copies it.
    subprocess.run(["pbcopy"], input=b"before-copy", timeout=10)
    focus_page(tab, pane)
    page_eval("(() => { const r = document.createRange(); r.selectNodeContents(document.getElementById('copysrc'));"
              " getSelection().removeAllRanges(); getSelection().addRange(r); return true; })()", tab)
    claimed = dry("c", ["command"])
    real_keys(["command", "c"])
    time.sleep(0.5)  # test harness: the copy lands on the pasteboard
    board = subprocess.run(["pbpaste"], capture_output=True, text=True, timeout=10).stdout
    row(board.strip() == f"cmuxcopy-{TOKEN}", "clipboard.copy_key", {"pasteboard": board[:60], "router": claimed,
                                                                      "pass_if": "real Cmd-C puts the page selection on the pasteboard"})
    subprocess.run(["pbcopy"], input=f"pasted-{TOKEN}".encode(), timeout=10)
    page_eval("document.getElementById('field').value = ''; true", tab)
    action("tab.focus", target=f"tab:{tab}")
    make_key()
    page_click(tab, pane, "#field")
    time.sleep(0.3)  # test harness: the field takes the caret
    real_keys(["command", "v"])
    time.sleep(0.5)  # test harness: the paste lands
    got = val("document.getElementById('field').value", tab)
    row(got == f"pasted-{TOKEN}", "clipboard.paste_key", {"field": got, "pass_if": "real Cmd-V pastes the pasteboard into the page field"})


def g_dnd(tab, pane):
    src, dst = window_point(tab, pane, "#src"), window_point(tab, pane, "#dst")
    if not src or not dst:
        return info_off("dnd.html5", "no in-tree page view for window-point mouse events")
    focus_page(tab, pane)
    t0 = time.time()
    rpc("debug.mouse", {"action": "down", "x": src[0], "y": src[1]})
    for i in range(1, 25):
        x, y = src[0] + (dst[0] - src[0]) * i / 24, src[1] + (dst[1] - src[1]) * i / 24
        rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1, "press": False, "release": False})
        time.sleep(0.016)  # test harness: one move a display frame
    rpc("debug.mouse", {"action": "up", "x": dst[0], "y": dst[1]})
    time.sleep(1.0)  # test harness: the drop lands
    got = [e[1:] for e in events_since(tab, t0) if e[1] in ("dragstart", "dragenter", "drop", "dragend")]
    row(any(e[0] == "drop" for e in got), "dnd.html5",
        {"events": got[:10], "note": "Chromium starts an AppKit drag session; FAIL with dragstart but no drop in both modes is "
                                     "the rig (the session tracks the real pointer, not posted events)",
         "pass_if": "dragging #src onto #dst fires dragstart and drop"})
    rpc("debug.key", {"key": "escape"})


def g_context_menu(tab, pane):
    for name, selector in (("text", "#textp"), ("link", "#lnk")):
        point = window_point(tab, pane, selector)
        if not point:
            info_off(f"context_menu.{name}", "no in-tree page view for a window-point right click")
            continue
        focus_page(tab, pane)
        t0 = time.time()
        rpc("debug.mouse", {"action": "click", "button": "right", "x": point[0], "y": point[1]})
        menu = wait(lambda: (lambda m: m if m.get("open") else None)(rpc("debug.menu", timeout=10) or {}), 5)
        snap(f"context-menu-{name}")
        seen = [e[1:] for e in events_since(tab, t0) if e[1] == "contextmenu"]
        items = (menu or {}).get("items") or []
        want = "Open Link in New Tab" if name == "link" else "Reload"
        row(bool(menu) and bool(seen) and any(want.lower() in str(i).lower() for i in items), f"context_menu.{name}",
            {"items": items[:20], "page_contextmenu": seen[:2],
             "pass_if": f"a right click shows the page menu with '{want}' and the page sees contextmenu"})
        rpc("debug.menu", {"dismiss": True}, timeout=10)
        time.sleep(0.4)  # test harness: the menu closes
    # The mode-neutral route: a trusted DevTools right click (both modes).
    action("tab.focus", target=f"tab:{tab}")
    c = pj("window.centre('#textp')", tab)
    t0 = time.time()
    for kind in ("mousePressed", "mouseReleased"):
        rpc("debug.cef.devtools", {"method": "Input.dispatchMouseEvent",
                                   "params": {"type": kind, "x": c[0], "y": c[1], "button": "right", "clickCount": 1}})
    menu = wait(lambda: (lambda m: m if m.get("open") else None)(rpc("debug.menu", timeout=10) or {}), 5)
    seen = [e[1:] for e in events_since(tab, t0) if e[1] == "contextmenu"]
    row(bool(menu) and bool(seen), "context_menu.devtools", {"items": ((menu or {}).get("items") or [])[:12], "page_contextmenu": seen[:2],
                                                              "pass_if": "a DevTools right click shows the page menu"})
    rpc("debug.menu", {"dismiss": True}, timeout=10)


def answer_dialog(identifier, press=None, fields=None, seconds=5):
    shown = wait(lambda: dialogs(identifier), seconds)
    if not shown:
        return None, None
    d = shown[-1]
    if fields:
        rpc("debug.dialog", {"id": d["id"], "set": fields})
    reply = rpc("debug.dialog", {"id": d["id"], "press": press}) if press else None
    return d, reply


def g_dialogs(tab, pane):
    action("tab.focus", target=f"tab:{tab}")
    cases = (("alert", "alert('cov alert')", "ok", None, "undefined"),
             ("confirm_ok", "confirm('cov confirm')", "ok", None, "true"),
             ("confirm_cancel", "confirm('cov confirm')", "cancel", None, "false"),
             ("prompt_text", "prompt('cov prompt', 'x')", "ok", {"text": f"typed-{TOKEN}"}, f"typed-{TOKEN}"),
             ("prompt_cancel", "prompt('cov prompt', 'x')", "cancel", None, "null"))
    for name, script, press, fields, want in cases:
        page_eval(f"window.__results = {{}}; window.later('r', () => {script}); true", tab)
        d, reply = answer_dialog("browser.dialog.javascript", press, fields)
        if name == "alert":
            snap("dialog-alert")
        got = wait(lambda: (pj("JSON.stringify(window.__results)", tab) or {}).get("r"), 5)
        row(got == want, f"dialog.{name}", {"shown": bool(d), "lines": (d or {}).get("lines"), "pressed": reply and reply.get("pressed"),
                                             "page_got": got, "pass_if": f"the dialog shows; {press} gives the page {want}"})
        if not d:
            rpc("debug.dialog", {"dismiss": True})
    # beforeunload needs sticky activation: a page click first.
    navigate(tab, "bu")
    page_click(tab, pane, "#axh")
    time.sleep(0.3)  # test harness: the click gives the page activation
    page_eval("window.__stay = 'kept'; window.armUnload()", tab)
    loads = lambda: int(val("Number(sessionStorage.loads || 0)", tab) or 0)
    l0 = loads()
    action("tab.focus", target=f"tab:{tab}")
    action("browserReload")
    d, reply = answer_dialog("browser.dialog.beforeunload", "cancel", seconds=6)
    snap("dialog-beforeunload")
    time.sleep(1.0)  # test harness: a reload that went ahead would have started
    row(bool(d) and val("window.__stay", tab) == "kept" and loads() == l0, "dialog.beforeunload_stay",
        {"shown": bool(d), "title": (d or {}).get("title"), "stay": val("window.__stay", tab),
         "pass_if": "a reload of a page with a beforeunload handler asks; Cancel keeps the page (no reload)"})
    action("browserReload")
    d, reply = answer_dialog("browser.dialog.beforeunload", "ok", seconds=6)
    ok = wait(lambda: loads() > l0 and val("window.covReady === true", tab) is True, 8)
    row(bool(d) and bool(ok), "dialog.beforeunload_leave", {"shown": bool(d), "loads": [l0, loads()],
                                                            "pass_if": "the second reload asks again; Reload reloads"})
    if not ok:
        rpc("debug.dialog", {"dismiss": True})
        page_eval("window.onbeforeunload = null; true", tab)
    navigate(tab, "main")


def chooser(tab, pane, selector, label, mode_word):
    action("tab.focus", target=f"tab:{tab}")
    make_key()
    before = file_dialogs()
    t0 = time.time()
    click = page_click(tab, pane, selector)
    shown = wait(lambda: (lambda d, s: (d, s) if d["received"] > before["received"] and any(w["visible"] for w in s) else None)(
        file_dialogs(), sheets()), 6)
    snap(f"chooser-{label}")
    after = file_dialogs()
    how = cancel_sheet()
    if label == "save":
        cancelled = wait(lambda: any(e[1] == "save" and e[2] == "error" for e in events_since(tab, t0)), 5)
    else:
        cancelled = wait(lambda: any(e[1] == "file" and e[3] == "cancel" for e in events_since(tab, t0)), 5)
    if any(w["visible"] for w in sheets()):
        cancel_sheet()
    row(bool(shown) and bool(cancelled), f"chooser.{label}",
        {"sheet_shown": bool(shown), "received": [before["received"], after["received"]], "last": after.get("last"),
         "answered": file_dialogs().get("answered"), "cancel_by": how, "click": click,
         "events": [e[1:] for e in events_since(tab, t0)][:6],
         "pass_if": f"a click on the {mode_word} chooser shows a sheet that reaches the app; Cancel reaches the page"})


def g_choosers(tab, pane):
    chooser(tab, pane, "#fm", "multiple", "multiple-file")
    chooser(tab, pane, "#fd", "directory", "directory")
    chooser(tab, pane, "#save", "save", "save (showSaveFilePicker)")
    files = []
    for i, size in enumerate((1234, 4321)):
        path = os.path.join(opts.out, f"upload-{i}.txt")
        with open(path, "wb") as f:
            f.write(b"u" * size)
        files.append(path)
    t0 = time.time()
    reply = rpc("browser.page.upload", {"tab": tab, "selector": "#fm", "files": files}, timeout=60)
    got = wait(lambda: next((e for e in events_since(tab, t0) if e[1] == "file" and e[2] == "fm" and e[3] == "change"), None), 10)
    row(bool(got) and sorted(got[4]) == sorted([[os.path.basename(p), s] for p, s in zip(files, (1234, 4321))]), "chooser.upload_multiple",
        {"reply": str(reply)[:200], "change": got, "pass_if": "browser.page.upload puts both files (names and sizes) in the multiple input"})


def g_downloads(tab, pane):
    for label, selector, name, want in (("link", "#dl", "cov-download.bin", DL_BYTES),
                                        ("blob", "#dlblob", "cov-blob.txt", f"blob-content-{TOKEN}".encode())):
        action("tab.focus", target=f"tab:{tab}")
        before = {d.get("id") for d in (rpc("debug.downloads") or {}).get("downloads") or []}
        page_click(tab, pane, selector)
        done = wait(lambda: next((d for d in (rpc("debug.downloads") or {}).get("downloads") or []
                                  if d.get("id") not in before and d.get("status") in ("finished", "failed", "cancelled", "blocked")), None), 15)
        dest = (done or {}).get("destination") or os.path.join(DOWNLOADS, name)
        data = open(dest, "rb").read() if dest and os.path.isfile(dest) else None
        row(bool(done) and done.get("status") == "finished" and data == want, f"download.{label}",
            {"row": done, "bytes": len(data) if data is not None else None, "want_bytes": len(want),
             "folder": (rpc("debug.downloads") or {}).get("folder"),
             "pass_if": "the download finishes and the file holds exactly the served bytes"})


def popups():
    return [p for p in (rpc("debug.popups") or {}).get("panels") or [] if "popup-close" in str(p.get("url") or "") and p.get("visible")]


def g_popups(tab, pane):
    for how in ("opener", "self"):
        action("tab.focus", target=f"tab:{tab}")
        make_key()
        t0 = time.time()
        page_click(tab, pane, "#popc")
        opened = wait(lambda: popups() and any(e[1] == "popup" and e[2] == "ready" for e in events_since(tab, t0)), 15)
        if not opened:
            row(False, f"popup.close_{how}", {"popups": str(rpc("debug.popups"))[:300], "events": events_since(tab, t0)[:6],
                                              "pass_if": "the popup opens"})
            continue
        time.sleep(1.0)  # test harness: the popup draws
        rpc("debug.popups", {"snapshot_dir": os.path.join(opts.out, f"popup-{how}")})
        if how == "opener":
            page_eval("window.__popc.close(); true", tab)
        else:
            index = next((i for i, p in enumerate((rpc("debug.popups") or {}).get("panels") or []) if "popup-close" in str(p.get("url"))), 0)
            rpc("debug.mouse", {"target": "page", "popup": index})
        gone = wait(lambda: not popups(), 8)
        closed = val("!!(window.__popc && window.__popc.closed)", tab)
        layers = main_layers()
        row(bool(gone) and closed is True and not unplaced(layers), f"popup.close_{how}",
            {"popups_left": len(popups()), "opener_sees_closed": closed, "unplaced": unplaced(layers),
             "pass_if": f"a popup closed by {'its opener' if how == 'opener' else 'its own window.close()'} goes away within 8 s, "
                        "the opener sees closed, no page view left unplaced"})
        if not gone:
            rpc("debug.popups", {"action": "close"})
    n0 = tab_count()
    p0 = len((rpc("debug.popups") or {}).get("panels") or [])
    page_click(tab, pane, "#blank")
    more = wait(lambda: (lambda n: n if n is not None and n0 is not None and n > n0 else None)(tab_count()), 8)
    row(bool(more) and len((rpc("debug.popups") or {}).get("panels") or []) == p0, "popup.blank_link_tab",
        {"tabs": [n0, tab_count()], "pass_if": "a target=_blank link opens a tab, not a popup window"})
    created = wait(lambda: next((r.get("tab") for r in [page_eval("new URLSearchParams(location.search).get('n') === 'blank'")]
                                 if r.get("value") is True and r.get("tab") != tab), None), 5)
    if created:
        action("closeTab", target=f"tab:{created}")
    RAW["blank_tab"] = {"created": created}
    action("tab.focus", target=f"tab:{tab}")


def g_devtools_dock(tab, pane):
    def state():
        for d in (rpc("debug.cef") or {}).get("devtools") or []:
            if d.get("pane") == pane:
                return d
        return {}

    results = {}
    for name, act in (("dock_bottom", "devtools.openDocked"), ("dock_right", "devtools.openDockedRight"),
                      ("undock", "devtools.openInWindow"), ("close", "devtools.close")):
        win0 = [w for w in (rpc("debug.window_list") or {}).get("windows") or [] if w.get("visible")]
        action("tab.focus", target=f"tab:{tab}")
        reply = action(act)
        time.sleep(3.0)  # test harness: the DevTools frontend loads and lays out
        st = state()
        page, dev = st.get("page_frame"), st.get("devtools_frame")
        win1 = [w for w in (rpc("debug.window_list") or {}).get("windows") or [] if w.get("visible")]
        fit = fits(tab, pane)
        snap(f"devtools-{name}")
        if name == "dock_bottom":
            ok = st.get("open") is True and bool(page and dev) and dev[1] + dev[3] <= page[1] + 1 and abs(dev[2] - page[2]) <= 2
            want = "open, the DevTools area under the page, as wide as it"
        elif name == "dock_right":
            ok = st.get("open") is True and bool(page and dev) and dev[0] >= page[0] + page[2] - 1 and abs(dev[3] - page[3]) <= 2
            want = "open, the DevTools area right of the page, as tall as it"
        elif name == "undock":
            new = [w for w in win1 if w.get("id") not in {x.get("id") for x in win0}]
            ok = st.get("open") is True and not dev and bool(new)
            want = "open in a new visible window, no docked area"
        else:
            ok = st.get("open") is False and not dev
            want = "closed, no DevTools area"
        if ON:
            ok = ok and fit["ok"]
            want += "; the page's viewport equals its view within 1 pt"
        results[name] = st
        row(ok, f"devtools.{name}", {"reply": str(reply)[:120], "state": {k: st.get(k) for k in ("open", "dock", "page_frame", "devtools_frame")},
                                     "fit": fit, "new_windows": [w.get("class") for w in win1 if w not in win0][:4], "pass_if": want})


def g_media_perms(tab, pane):
    navigate(tab, "media")
    action("tab.focus", target=f"tab:{tab}")
    for kind, constraint in (("camera", "{video: true}"), ("microphone", "{audio: true}")):
        page_eval("window.__media = 'pending'; true", tab)
        rpc("debug.cef.devtools", {"method": "Runtime.evaluate", "params": {
            "expression": f"navigator.mediaDevices.getUserMedia({constraint}).then(s => {{ window.__media = 'granted'; s.getTracks().forEach(t => t.stop()); }},"
                          f" e => {{ window.__media = 'error ' + e.name; }}); true", "userGesture": True}})
        asked = wait(lambda: [p for p in (rpc("debug.browser.prompts", {"tab": tab}) or {}).get("prompts") or []
                              if kind in json.dumps(p).lower() or "media" in json.dumps(p).lower()], 6)
        snap(f"permission-{kind}")
        if asked:
            rpc("debug.browser.prompts", {"tab": tab, "respond": "deny"})
        got = wait(lambda: (lambda v: v if v != "pending" else None)(val("window.__media", tab)), 6)
        row(bool(asked) and got == "error NotAllowedError", f"permission.{kind}",
            {"prompts": json.dumps(asked)[:300] if asked else None, "page_got": got,
             "pass_if": f"getUserMedia {kind} asks in the prompt bar; Block fails it with NotAllowedError (Allow would raise the "
                        "host's macOS prompt, so it is never pressed)"})
    navigate(tab, "main")


def g_http_auth(tab, pane):
    for press, want in (("cancel", "auth-required-401"), ("sign-in", "authed:cmux")):
        action("tab.focus", target=f"tab:{tab}")
        page_eval(f"location.href = {json.dumps(URL + 'auth?p=' + press)}; true", tab)
        d, reply = answer_dialog("browser.dialog.httpAuth", press, {"user": "cmux", "password": "pw-123"} if press == "sign-in" else None, 8)
        if press == "cancel":
            snap("http-auth")
        got = wait(lambda: (lambda v: v if v and v.startswith(("auth", "authed")) else None)(val("(document.getElementById('a') || {}).textContent", tab)), 8)
        row(bool(d) and got == want, f"http_auth.{press}", {"shown": bool(d), "lines": (d or {}).get("lines"), "page": got,
                                                             "pass_if": f"a 401 Basic page asks; {press} shows '{want}'"})
        if not d:
            rpc("debug.dialog", {"dismiss": True})
    navigate(tab, "main")


def g_hover(tab, pane):
    focus_page(tab, pane)
    for name, selector, cursor_want in (("link", "#lnk", "pointing"), ("box", "#hover", None), ("text", "#textp", "ibeam")):
        point = window_point(tab, pane, selector)
        if not point:
            info_off(f"hover.{name}", "no in-tree page view for window-point pointer moves")
            continue
        t0 = time.time()
        rpc("debug.mouse", {"action": "move", "x": point[0] - 2, "y": point[1]})
        rpc("debug.mouse", {"action": "move", "x": point[0], "y": point[1]})
        time.sleep(0.5)  # test harness: the move reaches the renderer
        over = [e[1:] for e in events_since(tab, t0) if e[1] == "over" and e[2] == selector[1:]]
        hovered = val(f"document.querySelector({json.dumps(selector)}).matches(':hover')", tab)
        cursor = rpc("debug.cursor") or {}
        ok = bool(over) and hovered is True
        detail = {"mouseover": over[:2], "hover": hovered, "cursor": cursor, "pass_if": "a pointer move over it fires mouseover and :hover"}
        if cursor_want:
            ok = ok and cursor_want in json.dumps(cursor).lower().replace("-", "").replace("_", "").replace(" ", "")
            detail["pass_if"] += f"; debug.cursor names a {cursor_want} cursor"
        row(ok, f"hover.{name}", detail)
    point = window_point(tab, pane, "#tall")
    if point:
        t0 = time.time()
        rpc("debug.mouse", {"action": "move", "x": point[0], "y": point[1]})
        time.sleep(0.5)  # test harness
        outs = [e[1:] for e in events_since(tab, t0) if e[1] == "out"]
        row(bool(outs) and val("document.querySelector('#textp').matches(':hover')", tab) is False, "hover.leave",
            {"mouseout": outs[:2], "pass_if": "moving off the last hovered element fires mouseout and drops :hover"})


def g_pointer_lock(tab, pane):
    focus_page(tab, pane)
    t0 = time.time()
    page_click(tab, pane, "#lockbtn")
    got = wait(lambda: val("document.pointerLockElement && document.pointerLockElement.id", tab) == "lockbtn", 5)
    evs = [e[1:] for e in events_since(tab, t0) if e[1] in ("pointerlockchange", "pointerlockerror", "lockerr")]
    snap("pointer-lock")
    row(bool(got), "pointer_lock.enter", {"events": evs[:4], "facts": focus_facts(),
                                          "pass_if": "a click whose handler asks for pointer lock gets it within 5 s"})
    if got:
        rpc("debug.key", {"sequence": [{"key_code": KC["escape"], "down": True, "after_ms": 0},
                                       {"key_code": KC["escape"], "down": False, "after_ms": 40}],
                          "key_window": "shell" if ON else "page"})
        left = wait(lambda: val("document.pointerLockElement === null", tab) is True, 5)
        row(bool(left), "pointer_lock.exit_escape", {"pass_if": "a real Escape releases pointer lock within 5 s"})
        if not left:
            page_eval("document.exitPointerLock(); true", tab)


def g_scroll(tab, pane):
    page_eval("window.scrollTo(0, 0); document.getElementById('nested').scrollTop = 0; true", tab)
    point = window_point(tab, pane, "#nested")
    if not point:
        return info_off("scroll.nested", "no in-tree page view for a window-point wheel")
    rpc("debug.mouse", {"action": "scroll", "x": point[0], "y": point[1], "dx": 0, "dy": -120})
    time.sleep(0.6)  # test harness: the wheel lands
    inner, page_y = val("document.getElementById('nested').scrollTop", tab), val("scrollY", tab)
    row(isinstance(inner, (int, float)) and inner > 0 and page_y == 0, "scroll.nested",
        {"nested_scrollTop": inner, "page_scrollY": page_y, "pass_if": "a wheel over the nested scroller scrolls it and not the page"})
    point = window_point(tab, pane, "#tall")
    rpc("debug.mouse", {"action": "scroll", "x": point[0], "y": point[1], "dx": 0, "dy": -300})
    time.sleep(0.6)  # test harness
    row((val("scrollY", tab) or 0) > 0, "scroll.page", {"page_scrollY": val("scrollY", tab),
                                                       "note": "momentum (momentumPhase) has no debug.mouse field",
                                                       "pass_if": "a wheel over the page body scrolls the page"})
    page_eval("window.scrollTo(0, 0); true", tab)


def g_video(tab, pane):
    page_eval("window.startVideo()", tab)
    time.sleep(4.0)  # test harness: 1.5 s of recording, then the WebM plays
    s0 = pj("window.videoState()", tab) or {}
    time.sleep(2.0)  # test harness: two seconds of playback
    s1 = pj("window.videoState()", tab) or {}
    snap("video")
    row((s1.get("vf", 0) - s0.get("vf", 0)) >= 30 and (s1.get("t1") or 0) > (s0.get("t1") or 0) + 1.5, "video.stream",
        {"before": s0, "after": s1, "pass_if": "a canvas-stream <video> presents >= 30 frames and advances >= 1.5 s in 2 s"})
    row((s1.get("vf2", 0) - s0.get("vf2", 0)) >= 20 and not s1.get("err2") and s1.get("paused2") is False, "video.webm_decode",
        {"before": s0, "after": s1, "pass_if": "a recorded WebM plays: >= 20 presented frames in 2 s, no media error"})


def g_ime(tab, pane):
    action("tab.focus", target=f"tab:{tab}")
    page_eval("document.getElementById('field').value = ''; document.getElementById('field').focus(); true", tab)
    t0 = time.time()
    for method, params in (("Input.imeSetComposition", {"text": "にほ", "selectionStart": 2, "selectionEnd": 2}),
                           ("Input.imeSetComposition", {"text": "にほん", "selectionStart": 3, "selectionEnd": 3}),
                           ("Input.insertText", {"text": "日本"})):
        rpc("debug.cef.devtools", {"method": method, "params": params})
        time.sleep(0.2)  # test harness: each composition step lands
    got = val("document.getElementById('field').value", tab)
    comp = [e[1] for e in events_since(tab, t0) if e[1].startswith("composition")]
    row(got == "日本" and "compositionstart" in comp and "compositionend" in comp, "ime.renderer",
        {"field": got, "events": comp, "note": "the renderer's IME path only; AppKit's NSTextInputClient route (setMarkedText on the "
                                                "page's view) has no debug hook",
         "pass_if": "a composition then commit leaves the committed text and composition events"})


def g_ax(tab, pane):
    if not CUA_DRIVER:
        return info_off("ax.page_tree", "no CuaDriver on this host")
    window = main_window_id()
    found = None
    for attempt in range(4):
        state = cua("get_window_state", {"pid": RAW.get("pid"), "window_id": window, "include_screenshot": False,
                                         "max_depth": 80, "max_elements": 8000})
        els = elements(state)
        text = lambda e: (str(e.get("label") or "") + " " + str(e.get("title") or "") + " " + str(e.get("value") or "")).lower()
        button = [e for e in els if "cmux ax probe button" in text(e)]
        heading = [e for e in els if "ax probe heading" in text(e)]
        web = [e for e in els if "webarea" in str(e.get("role", "")).lower()]
        found = {"elements": len(els), "button": button[:1], "heading": heading[:1], "web_areas": len(web), "attempt": attempt,
                 "error": state.get("error") if isinstance(state, dict) else None}
        if button and heading:
            break
        time.sleep(1.5)  # test harness: Chromium turns its accessibility tree on at the first query
    row(bool(found["button"]) and bool(found["heading"]), "ax.page_tree",
        dict(found, pass_if="the window's accessibility tree has the page's labelled button and heading"))


def g_focus_routes(tab, pane, terminal_tab):
    if not terminal_tab:
        return row("INFO", "focus_route.cmd_opt_arrow", {"note": "no terminal tab"})
    action("tab.focus", target=f"tab:{terminal_tab}")
    time.sleep(0.4)  # test harness: the terminal takes the keys
    make_key()
    page_eval("window.__k = []; true", tab)
    term_pane = page_pane(terminal_tab)
    frames = {s.get("pane"): s.get("frame") for s in (rpc("debug.tab_drag") or {}).get("strips") or []}
    page_x, term_x = (frames.get(pane) or [0])[0], (frames.get(term_pane) or [0])[0]
    to_page, to_term = ("left", "right") if page_x < term_x else ("right", "left")
    real_keys(["command", "option", to_page])
    time.sleep(0.4)  # test harness: focus moves
    facts = focus_facts()
    real_keys(["q"])
    keys = pj("JSON.stringify(window.__k)", tab)
    row(facts.get("resolved") == "browserPage" and keys == ["q"], "focus_route.cmd_opt_arrow_in",
        {"facts": facts, "page_keys": keys, "page_x": page_x, "terminal_pane": term_pane,
         "pass_if": f"real Cmd-Opt-{to_page} from the terminal gives the page the keys: a real q reaches it"})
    page_eval("window.__k = []; true", tab)
    real_keys(["command", "option", to_term])
    time.sleep(0.4)  # test harness
    facts = focus_facts()
    real_keys(["x"])
    keys = pj("JSON.stringify(window.__k)", tab)
    row(facts.get("resolved") != "browserPage" and keys == [], "focus_route.cmd_opt_arrow_out",
        {"facts": facts, "page_keys": keys, "pass_if": f"real Cmd-Opt-{to_term} moves the keys to the terminal: the page gets none"})
    rpc("debug.key", {"key": "u", "modifiers": ["control"]})
    focus_page(tab, pane)
    page_eval("window.__k = []; true", tab)
    page_click(tab, pane, "#field")
    time.sleep(0.3)  # test harness
    real_keys(["k"])
    keys = pj("JSON.stringify(window.__k)", tab)
    row(keys == ["k"], "focus_route.click_real_key", {"page_keys": keys, "facts": focus_facts(),
                                                      "pass_if": "after a page click a real k reaches the page"})


def g_shortcuts(tab, pane):
    def palette_opens():
        return len((rpc("debug.timings") or {}).get("palette_opens") or [])

    def area():
        v = pj("JSON.stringify({w: innerWidth, h: innerHeight})", tab)
        return v["w"] * v["h"] if v else 0

    sweep = [
        ("cmd+t", ["command", "t"], lambda s: (tab_count() or 0) > s["tabs"], lambda s: action("closeTab")),
        ("cmd+d", ["command", "d"], lambda s: focus_facts()["panes"] > s["panes"], lambda s: action("closePane")),
        ("cmd+shift+d", ["command", "shift", "d"], lambda s: focus_facts()["panes"] > s["panes"], lambda s: action("closePane")),
        ("cmd+shift+return", ["command", "shift", "return"], lambda s: area() >= 1.3 * s["area"], lambda s: action("toggleSplitZoom")),
        ("cmd+shift+p", ["command", "shift", "p"], lambda s: palette_opens() > s["palette"],
         lambda s: rpc("debug.key", {"key": "escape", "target": "palette"})),
        ("cmd+l", ["command", "l"], lambda s: (rpc("debug.omnibar", {"pane": pane}) or {}).get("has_focus") is True,
         lambda s: rpc("debug.key", {"key": "escape"})),
        ("cmd+r", ["command", "r"], lambda s: int(val("Number(sessionStorage.loads || 0)", tab) or 0) > s["loads"], None),
        ("cmd+=", ["command", "="], lambda s: (val("devicePixelRatio", tab) or 0) > s["dpr"] + 0.05, lambda s: action("browserZoomReset")),
        # The new window is closed by its own id: an untargeted closeWindow could close the page's window.
        ("cmd+n", ["command", "n"], lambda s: len(windows()) > len(s["window_ids"]),
         lambda s: [action("closeWindow", target=f"window:{w.get('id')}") for w in windows() if w.get("id") not in s["window_ids"]]),
        ("cmd+opt+i", ["command", "option", "i"], lambda s: any(d.get("open") for d in (rpc("debug.cef") or {}).get("devtools") or []),
         lambda s: action("devtools.close")),
        ("cmd+shift+]", ["command", "shift", "]"], None, None),
        ("ctrl+tab", ["control", "tab"], None, None),
        ("cmd+1", ["command", "1"], None, None),
        ("cmd+w", ["command", "w"], None, None),
    ]
    for name, keys, effect, undo in sweep:
        navigate(tab, "main") if name == "cmd+r" else None
        action("tab.focus", target=f"tab:{tab}")
        time.sleep(0.2)  # test harness
        facts = focus_page(tab, pane)
        mods = [k for k in keys[:-1]]
        claimed = dry(keys[-1] if keys[-1] not in ("return", "tab") else keys[-1], mods)
        if name == "cmd+w":
            # Never close the page itself: the dry run is the check.
            row("INFO" if claimed else False, f"shortcut.{name}", {"router": claimed, "facts": facts,
                                                                    "pass_if": "dry run only: the router claims Cmd-W with the page focused"})
            continue
        if effect is None:
            row(bool(claimed) if claimed is not None else "INFO", f"shortcut.{name}",
                {"router": claimed, "facts": facts, "pass_if": "the router claims the chord with the page focused (dry run; no effect check)"})
            continue
        s = {"tabs": tab_count() or 0, "panes": facts["panes"], "area": area(), "palette": palette_opens(),
             "loads": int(val("Number(sessionStorage.loads || 0)", tab) or 0), "dpr": val("devicePixelRatio", tab) or 0,
             "window_ids": [w.get("id") for w in windows()]}
        reply = real_keys(keys)
        ok = wait(lambda: effect(s), 5)
        row(bool(ok), f"shortcut.{name}", {"router": claimed, "before": s, "sequence": str(reply)[:120], "facts_before": facts,
                                           "facts_after": focus_facts(), "pass_if": f"real {name} with the page focused by a click acts"})
        if ok and undo:
            undo(s)
            time.sleep(0.8)  # test harness: the undo settles
        page_ready(tab, None, 10)


def g_tab_switch(tab, pane):
    page_eval(f"window.__mark = 'A-{TOKEN}'; true", tab)
    action("tab.focus", target=f"tab:{tab}")
    opened = action("openBrowser.chromium", {"url": cov_url("B")})
    second = wait(lambda: (lambda r: r.get("tab") if r.get("value") is True and r.get("tab") not in (None, tab) else None)(
        page_eval("new URLSearchParams(location.search).get('n') === 'B' && window.covReady === true")), 30, 0.5)
    RAW["tab_switch_second"] = {"open": opened, "tab": second}
    if not second:
        return row(False, "tab_switch.open", {"open": str(opened)[:200]})
    same_pane = page_pane(second) == pane
    hidden = wait(lambda: val("document.visibilityState", tab) == "hidden", 5)
    row(same_pane and bool(hidden), "tab_switch.behind", {"same_pane": same_pane, "A_visibility": val("document.visibilityState", tab),
                                                           "pass_if": "a second page tab in the pane hides the first (visibilityState hidden)"})
    action("tab.focus", target=f"tab:{tab}")
    back = wait(lambda: val("document.visibilityState", tab) == "visible", 5)
    time.sleep(0.4)  # test harness: the page view settles
    layers = main_layers()
    shown = [v for v in layers.get("page_views") or [] if v.get("pane") == pane and not v.get("parked")]
    fit = fits(tab, pane)
    snap("tab-switch-back")
    row(bool(back) and val("window.__mark", tab) == f"A-{TOKEN}" and (not ON or len(shown) == 1) and fit["ok"]
        and val("document.visibilityState", second) == "hidden", "tab_switch.action",
        {"mark": val("window.__mark", tab), "shown_views_in_pane": len(shown), "fit": fit, "unplaced": unplaced(layers),
         "pass_if": "tab.focus back: A visible with its document, B hidden, one shown page view in the pane that fits"})
    focus_page(tab, pane)
    claimed = dry("tab", ["control"])
    real_keys(["control", "tab"])
    went = wait(lambda: val("document.visibilityState", second) == "visible", 5)
    page_eval("window.__k = []; true", second)
    real_keys(["z"])
    keys = pj("JSON.stringify(window.__k)", second)
    row(bool(went) and keys == ["z"], "tab_switch.key",
        {"router": claimed, "B_visibility": val("document.visibilityState", second), "B_keys": keys,
         "pass_if": "real Ctrl-Tab shows the next tab and a real key then reaches it"})
    RAW["second_tab"] = second


def g_pane_close(tab, pane):
    action("tab.focus", target=f"tab:{tab}")
    action("splitDown")
    time.sleep(1.2)  # test harness: the new pane's terminal attaches
    opened = action("openBrowser.chromium", {"url": cov_url("PC")})
    other = wait(lambda: (lambda r: r.get("tab") if r.get("value") is True and r.get("tab") not in (None, tab) else None)(
        page_eval("new URLSearchParams(location.search).get('n') === 'PC' && window.covReady === true")), 30, 0.5)
    if not other:
        return row(False, "pane_close.page", {"open": str(opened)[:200]})
    views0 = len([v for v in main_layers().get("page_views") or [] if not v.get("parked")])
    action("tab.focus", target=f"tab:{other}")
    time.sleep(0.3)  # test harness: its pane is focused
    action("closePane")
    gone = wait(lambda: page_pane(other) is None, 6)
    time.sleep(0.8)  # test harness: the layout settles
    layers = main_layers()
    views1 = len([v for v in layers.get("page_views") or [] if not v.get("parked")])
    fit = fits(tab, pane)
    snap("pane-close")
    row(bool(gone) and not unplaced(layers) and fit["ok"] and (not ON or views1 == views0 - 1), "pane_close.page",
        {"views": [views0, views1], "unplaced": unplaced(layers), "fit": fit,
         "pass_if": "closing a page's pane removes its page view (none unplaced) and the remaining page fits its pane"})


def g_window_move(tab, pane):
    layers = main_layers()
    frame = layers.get("frame")
    view0 = page_view(pane, layers)
    s0 = pj("JSON.stringify([screenX, screenY])", tab)
    for name, call in (("programmatic", lambda f: rpc("debug.window_frame", {"frame": [f[0] + 60, f[1] - 40, f[2], f[3]]})),
                       ("ax", lambda f: rpc("debug.window.ax_set_frame", {"frames": [[f[0] + 120, 80, f[2], f[3]]]}, timeout=30))):
        before = main_layers().get("frame")
        s_before = pj("JSON.stringify([screenX, screenY])", tab)
        reply = call(before)
        if isinstance(reply, dict) and reply.get("error"):
            info_off(f"window_move.{name}", "the move call was refused", reply=str(reply)[:200])
            continue
        time.sleep(0.8)  # test harness: the move lands and the page learns its new position
        after = main_layers().get("frame")
        s_after = pj("JSON.stringify([screenX, screenY])", tab)
        view = page_view(pane)
        moved = bool(before and after) and (abs(after[0] - before[0]) > 1 or abs(after[1] - before[1]) > 1)
        dx = (after[0] - before[0]) if moved else 0
        follows = bool(s_before and s_after) and abs((s_after[0] - s_before[0]) - dx) <= 2
        same_view = not ON or (view and view0 and all(abs(a - b) <= 0.5 for a, b in zip(view, view0)))
        snap(f"window-move-{name}")
        row(moved and follows and bool(same_view), f"window_move.{name}",
            {"frame_before": before, "frame_after": after, "screen_before": s_before, "screen_after": s_after,
             "page_view": view, "page_view_start": view0, "reply": str(reply)[:160],
             "pass_if": "the window moves; the page's screenX follows by the same dx within 2 pt; its view keeps its frame"})
    rpc("debug.window_frame", {"frame": frame})
    RAW["window_move_start_screen"] = s0


def g_minimize(tab, pane):
    def mini():
        return next((w.get("miniaturized") for w in (rpc("debug.window_list") or {}).get("windows") or [] if w.get("kind") == "main"), None)

    page_eval("window.__vis = []; document.addEventListener('visibilitychange', () => window.__vis.push(document.visibilityState)); true", tab)
    reply = action("minimizeWindow")
    down = wait(lambda: mini() is True, 6)
    hidden = wait(lambda: val("document.visibilityState", tab) == "hidden", 6)
    row(bool(down) and bool(hidden), "minimize.hidden", {"miniaturized": mini(), "visibility": val("document.visibilityState", tab),
                                                          "reply": str(reply)[:120],
                                                          "pass_if": "minimizeWindow minimizes and the page becomes hidden"})
    time.sleep(2.0)  # test harness: minimized for a while
    rpc("debug.page_reveal", {"action": "samples"})
    reply = action("showMainWindow")
    up = wait(lambda: mini() is False, 8)
    visible = wait(lambda: val("document.visibilityState", tab) == "visible", 6)
    time.sleep(0.8)  # test harness: the window settles
    fit = fits(tab, pane)
    snap("minimize-restore")
    row(bool(up) and bool(visible) and fit["ok"] and val("window.covReady === true", tab) is True, "minimize.restore",
        {"miniaturized": mini(), "visibility_log": val("JSON.stringify(window.__vis)", tab), "fit": fit, "reply": str(reply)[:120],
         "pass_if": "showMainWindow restores it, the page is visible, live and fits its view"})


def g_tab_move(tab, pane, terminal_tab):
    second = RAW.get("second_tab")
    if not second:
        action("tab.focus", target=f"tab:{tab}")
        action("openBrowser.chromium", {"url": cov_url("B")})
        second = wait(lambda: (lambda r: r.get("tab") if r.get("value") is True and r.get("tab") not in (None, tab) else None)(
            page_eval("new URLSearchParams(location.search).get('n') === 'B' && window.covReady === true")), 30, 0.5)
    if not second:
        return row(False, "tab_move.setup", {"note": "no second page tab"})
    page_eval(f"window.__mark = 'B-{TOKEN}'; document.title = 'COVB'; true", second)
    time.sleep(0.5)  # test harness: the tab label takes the title
    # 1. Drag the tab from its strip onto the terminal's pane.
    strips = (rpc("debug.tab_drag") or {}).get("strips") or []
    src = next(((s, t) for s in strips for t in s.get("tabs") or [] if "COVB" in str(t.get("label"))), None)
    term_pane = page_pane(terminal_tab) if terminal_tab else None
    target = None
    layers = main_layers()
    height = (layers.get("frame") or [0, 0, 0, 0])[3]
    for s in strips:
        if s.get("pane") == term_pane:
            f = s.get("frame")
            target = [f[0] + f[2] / 2, f[1] + 200]
    if src and target:
        f = src[1]["frame"]
        start = [f[0] + f[2] / 2, f[1] + f[3] / 2]
        rpc("debug.mouse", {"action": "down", "x": start[0], "y": start[1]})
        for i in range(1, 31):
            x, y = start[0] + (target[0] - start[0]) * i / 30, start[1] + (target[1] - start[1]) * i / 30
            rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1, "press": False, "release": False})
            time.sleep(0.016)  # test harness: one move a display frame
        rpc("debug.mouse", {"action": "up", "x": target[0], "y": target[1]})
        moved = wait(lambda: page_pane(second) == term_pane, 6)
        time.sleep(0.6)  # test harness: the page settles in its new pane
        fit = fits(second, page_pane(second))
        snap("tab-move-drag")
        row(bool(moved) and val("window.__mark", second) == f"B-{TOKEN}" and fit["ok"], "tab_move.drag_to_pane",
            {"pane_now": page_pane(second), "want_pane": term_pane, "mark": val("window.__mark", second), "fit": fit,
             "pass_if": "a tab dragged from its strip onto another pane moves there with its document and fits"})
    else:
        row("INFO", "tab_move.drag_to_pane", {"note": "no strip tab or target pane found", "strips": str(strips)[:300]})
    # 2. Move to a new split.
    before = page_pane(second)
    action("tab.moveToNewSplit", target=f"tab:{second}")
    moved = wait(lambda: page_pane(second) not in (None, before), 6)
    time.sleep(0.6)  # test harness
    fit = fits(second, page_pane(second))
    row(bool(moved) and val("window.__mark", second) == f"B-{TOKEN}" and fit["ok"], "tab_move.new_split",
        {"pane": [before, page_pane(second)], "fit": fit, "pass_if": "tab.moveToNewSplit moves it with its document and it fits"})
    # 3. Move to a new window.
    n0 = len(windows())
    action("tab.moveToNewWindow", target=f"tab:{second}")
    two = wait(lambda: len(windows()) > n0, 8)
    time.sleep(1.2)  # test harness: the new window shows and the page attaches
    ws = windows()
    other = next((w for w in ws[1:] if any(not v.get("parked") for v in w.get("page_views") or [])), ws[-1] if ws else {})
    views = [v for v in other.get("page_views") or [] if not v.get("parked")]
    browsers = other.get("browsers") or []
    in_tree = not ON or (bool(views) and all(b.get("presentation") == "in_tree" for b in browsers if b.get("engine")))
    page_eval("window.__k = []; true", second)
    click = rpc("debug.mouse", {"target": "page", "window": other.get("id"), "x": 40, "y": 40})
    alive = val("window.__mark", second)
    vp = pj("JSON.stringify({w: innerWidth, h: innerHeight})", second)
    fit_ok = not ON or bool(views and vp and abs(views[0]["frame_in_window"][2] - vp["w"]) <= 1 and abs(views[0]["frame_in_window"][3] - vp["h"]) <= 1)
    rpc("debug.window_snapshot", {"kind": "main", "window": other.get("id"), "path": os.path.join(opts.out, "tab-move-window.png")})
    row(bool(two) and alive == f"B-{TOKEN}" and in_tree and fit_ok and not unplaced(), "tab_move.new_window",
        {"windows": [n0, len(ws)], "mark": alive, "views": views[:2], "viewport": vp, "click": str(click)[:120],
         "unplaced": unplaced(), "pass_if": "tab.moveToNewWindow: a second window holds the page (in tree with the mode on) with its "
                                            "document, fitting its view, no unplaced view anywhere"})
    action("closeWindow", target=f"window:{other.get('id')}" if other.get("id") else None)
    time.sleep(1.0)  # test harness: the window closes


def g_crash(tab, pane):
    navigate(tab, "crash")
    report = rpc("renderers.list", {"interval_ms": 0}, timeout=30) or {}
    page = next((p for p in report.get("pages") or [] if "n=crash" in str(p.get("url"))), None)
    clients = set((page or {}).get("renderer_clients") or [])
    helper = next((h for h in report.get("helpers") or [] if h.get("client") in clients), None)
    if not helper:
        return row(False, "crash.sad_tab", {"note": "no renderer pid for the page", "report": json.dumps(report)[:400]})
    os.kill(int(helper["pid"]), signal.SIGKILL)
    gone = wait(lambda: (rpc("debug.browser.page_status", {"tab": tab}) or {}).get("gone") == "1", 8)
    status = rpc("debug.browser.page_status", {"tab": tab}) or {}
    snap("crash-sad-tab")
    layers = main_layers()
    row(bool(gone) and not unplaced(layers), "crash.sad_tab",
        {"pid": helper["pid"], "gone_text": status.get("gone_text"), "unplaced": unplaced(layers),
         "pass_if": "SIGKILL of the page's renderer shows the sad tab within 8 s, no page view left unplaced"})
    pressed = rpc("debug.browser.page_status", {"tab": tab, "press": "reload"})
    back = page_ready(tab, None, 20)
    time.sleep(0.8)  # test harness: the page draws
    layers = main_layers()
    browsers = [b for b in layers.get("browsers") or [] if b.get("pane") == pane]
    in_tree = not ON or any(b.get("presentation") == "in_tree" and b.get("rwhv_in_window") for b in browsers)
    fit = fits(tab, pane)
    snap("crash-reloaded")
    row(bool(back) and (rpc("debug.browser.page_status", {"tab": tab}) or {}).get("gone") == "0" and in_tree and fit["ok"], "crash.reload",
        {"pressed": pressed, "browsers": browsers[:2], "fit": fit,
         "pass_if": "the sad tab's Reload loads the page again, in tree with the mode on, fitting its view"})


def g_memory50(tab, pane):
    def footprint():
        return (rpc("debug.cef") or {}).get("footprint_mb")

    def family_rss():
        out = subprocess.run(["ps", "-axo", "pid=,ppid=,rss="], capture_output=True, text=True).stdout.split("\n")
        rows = [tuple(int(x) for x in l.split()) for l in out if len(l.split()) == 3]
        kids, total, n, todo = {}, 0, 0, [RAW.get("pid")]
        for pid, ppid, rss in rows:
            kids.setdefault(ppid, []).append((pid, rss))
        seen = set()
        while todo:
            p = todo.pop()
            if p in seen or p is None:
                continue
            seen.add(p)
            for child, rss in kids.get(p, []):
                total += rss
                n += 1
                todo.append(child)
        own = next((rss for pid, _, rss in rows if pid == RAW.get("pid")), 0)
        return round((total + own) / 1024), n + 1

    def helpers():
        return len((rpc("renderers.list", {"interval_ms": 0}, timeout=30) or {}).get("helpers") or [])

    action("workspace.newAtBottom")
    time.sleep(2.0)  # test harness: the new workspace's terminal attaches
    base = {"footprint_mb": footprint(), "rss_mb": family_rss(), "helpers": helpers()}
    made, t0 = [], time.time()
    for i in range(opts.tabs):
        reply = action("openBrowser.chromium", {"url": cov_url(f"m{i}")})
        made += [c for c in (reply or {}).get("created") or [] if str(c).startswith("tab_")]
        time.sleep(0.05)  # test harness: an 80 ms person pace is slower; this is the spam case
    loaded = wait(lambda: sum(1 for p in (rpc("renderers.list", {"interval_ms": 0}, timeout=30) or {}).get("pages") or []
                              if "n=m" in str(p.get("url"))) >= opts.tabs, 120, 1.0)
    if not made:  # the open replies named no tab: the pages' own tabs (renderers.list owners)
        pages = (rpc("renderers.list", {"interval_ms": 0}, timeout=30) or {}).get("pages") or []
        made = [(p.get("owner") or {}).get("tab") for p in pages if "n=m" in str(p.get("url")) and (p.get("owner") or {}).get("tab")]
    open_s = round(time.time() - t0, 1)
    peak = {"footprint_mb": footprint(), "rss_mb": family_rss(), "helpers": helpers(), "open_s": open_s, "tabs_made": len(made)}
    snap("memory50-open")
    row(bool(loaded), "memory50.open", {"base": base, "peak": peak, "pass_if": f"all {opts.tabs} page tabs load within 120 s"})
    for t in made:
        action("closeTab", target=f"tab:{t}")
        time.sleep(0.03)  # test harness: a close a frame or so
    time.sleep(15)  # test harness: renderers exit and memory returns
    after = {"footprint_mb": footprint(), "rss_mb": family_rss(), "helpers": helpers()}
    left = sum(1 for p in (rpc("renderers.list", {"interval_ms": 0}, timeout=30) or {}).get("pages") or [] if "n=m" in str(p.get("url")))
    ok = left == 0 and not unplaced() and isinstance(after["footprint_mb"], (int, float)) and isinstance(base["footprint_mb"], (int, float)) \
        and after["footprint_mb"] <= base["footprint_mb"] + 60 and after["rss_mb"][0] <= base["rss_mb"][0] * 1.15 + 100 \
        and after["helpers"] <= base["helpers"] + 2
    row(ok, "memory50.closed", {"base": base, "peak": peak, "after": after, "pages_left": left, "unplaced": unplaced(),
                                "pass_if": "after closing them and 15 s: no page left, footprint <= base + 60 MB, family RSS <= "
                                           "base x 1.15 + 100 MB, renderer helpers <= base + 2"})
    action("workspace.selectFirst")
    time.sleep(1.0)  # test harness


# ---- run ----

if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1300,860",
       "CMUX_NEXT_DOWNLOADS_DIR": DOWNLOADS, "CMUX_IN_TREE_PAGES": "1" if ON else "0"}
sys.path.insert(0, HERE)
from bench_launch import launch_app  # noqa: E402
app = None
GROUPS = {"nav": g_nav, "reload_stop": g_reload_stop, "omnibar": g_omnibar, "find": g_find, "zoom": g_zoom, "clipboard": g_clipboard,
          "dnd": g_dnd, "context_menu": g_context_menu, "dialogs": g_dialogs, "choosers": g_choosers, "downloads": g_downloads,
          "popups": g_popups, "devtools_dock": g_devtools_dock, "media_perms": g_media_perms, "http_auth": g_http_auth,
          "hover": g_hover, "pointer_lock": g_pointer_lock, "scroll": g_scroll, "video": g_video, "ime": g_ime, "ax": g_ax,
          "shortcuts": g_shortcuts, "tab_switch": g_tab_switch, "pane_close": g_pane_close, "window_move": g_window_move,
          "minimize": g_minimize, "crash": g_crash, "memory50": g_memory50}
try:
    try:
        app, SOCKET = launch_app(opts.app, env, os.path.join(opts.out, "app.log"), timeout=120,
                                 on_start=lambda p: RAW.__setitem__("pid", p.pid))
    except SystemExit as error:
        row(False, "launch", str(error)[:300])
        raise SystemExit
    time.sleep(2)  # test harness: the first terminal attaches
    RAW["open"] = action("openBrowser.chromium", {"url": cov_url("main")})
    ready = wait(lambda: (lambda r: r if r.get("value") is True else None)(page_eval("window.covReady === true")), 60, 0.5)
    page_tab = ready.get("tab") if ready else None
    if not page_tab:
        row(False, "page", {"open": RAW["open"], "cef": rpc("debug.cef")})
        raise SystemExit
    RAW["split"] = action("splitRight")
    time.sleep(1.5)  # test harness: the new pane's terminal attaches
    terminal_tab = next((c for c in (RAW["split"] or {}).get("created") or [] if str(c).startswith("tab_")), None)
    status = (rpc("debug.cef") or {}).get("in_tree")
    row(status == "on" if ON else status in ("off", None), "mode", {"asked": opts.in_tree, "in_tree": status})
    pane = page_pane(page_tab)
    RAW["pane"], RAW["page_tab"], RAW["terminal_tab"] = pane, page_tab, terminal_tab
    for name in CHECKS:
        print(f"== coverage group {name}", flush=True)
        if name in ("focus_routes", "tab_move"):
            guard(name, {"focus_routes": g_focus_routes, "tab_move": g_tab_move}[name], page_tab, pane, terminal_tab)
        elif name in GROUPS:
            guard(name, GROUPS[name], page_tab, pane)
        else:
            row(False, f"{name}.unknown", {"note": "no such group"})
        # Every group leaves the page on its main URL in its pane, the window windowed.
        if name not in ("memory50",):
            if val("window.covReady === true", page_tab) is not True or val("new URLSearchParams(location.search).get('n')", page_tab) != "main":
                navigate(page_tab, "main")
    snap("window-end")
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
with open(opts.json or os.path.join(opts.out, "in-tree-coverage.json"), "w") as f:
    json.dump({"in_tree_requested": opts.in_tree, "rows": ROWS, "failed": len(failed), "raw": RAW}, f, indent=1, default=str)
print(f"in-tree-coverage-checks: {len(ROWS) - len(failed)} of {len(ROWS)} rows pass, {len(failed)} fail (in-tree {opts.in_tree})", flush=True)
sys.exit(1 if failed else 0)

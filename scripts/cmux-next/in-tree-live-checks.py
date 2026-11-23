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
  prompt_keys
             with the page's field focused, the page calls prompt(): keys typed at once (debug.key into the window's
             first responder, as the person's keys go) must land in the prompt's field with no click on it, and Return
             must answer the page with them (in tree: cmux's dialog; off: Chromium's own dialog, INFO only, since a
             no-activate app has no key window for its keys)
  fullscreen after toggleFullScreen: a page click (debug.mouse target page) on the field and keys (debug.key) reach the
             page; `fullscreen.real` (INFO) posts a real click and keys to the app's pid through CuaDriver, with the
             app inactive and its full-screen window on its own Space (CMUX_NEXT_NO_ACTIVATE), and says what landed
  file_after_popup
             (also with prompts) a window.open popup's <input type=file> shows its sheet on the popup window, the popup
             closes while that sheet is up, and then the opener's chooser must still work: a sheet shows, a new request
             reaches the app (debug.cef file_dialogs.received grows), Escape delivers 'cancel' to the page, and a
             second chooser does the same (other-Mac run on 6e420b7b: every later chooser of that app cancelled at once)

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
parser.add_argument("--checks", default="mode,census,focus,shortcuts,prompts,prompt_keys,file_after_popup,fullscreen,two_pages")
parser.add_argument("--close-popup", dest="close_popup", choices=["script", "window"], default="script",
                    help="file_after_popup: the popup closes itself (window.close() from its opener) or its window closes")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
CHECKS = set(opts.checks.split(","))
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


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/download"):
            body, kind = b"in-tree download probe\n", "application/octet-stream"
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
    if "prompt_keys" in CHECKS:
        record("prompt_keys")
        action("tab.focus", target=f"tab:{page_tab}")
        page_eval("window.__keys = []; delete window.__results.prompt_keys; document.getElementById('field').value = '';"
                  " document.getElementById('field').focus(); true", page_tab)
        time.sleep(0.3)  # test harness: focus lands in the page's field
        windows0 = {w.get("id") for w in ((rpc("debug.window_list") or {}).get("windows") or []) if w.get("visible")}
        page_eval("window.later('prompt_keys', () => prompt('in-tree prompt keys', ''))", page_tab)
        shown = wait(lambda: [d for d in (rpc("debug.dialog") or {}).get("dialogs") or [] if d.get("visible")], 5)
        new_windows = [{k: w.get(k) for k in ("kind", "class", "title", "key", "parent")} for w in
                       ((rpc("debug.window_list") or {}).get("windows") or []) if w.get("visible") and w.get("id") not in windows0]
        focus = rpc("debug.focus") or {}
        RAW["prompt_keys_focus"] = focus
        responders = [((w.get("appkit") or {}).get("first_responder")) for w in focus.get("windows") or [] if isinstance(w, dict)]
        typed = [rpc("debug.key", {"key": ch}) for ch in "abc"]
        time.sleep(0.4)  # test harness: the keys land
        dialogs = [d for d in (rpc("debug.dialog") or {}).get("dialogs") or [] if d.get("visible")]
        value = (dialogs[0].get("values") or {}).get("text") if dialogs else None
        page_keys = page_eval("JSON.stringify(window.__keys)", page_tab).get("value")
        detail = {"dialog_shown": bool(shown), "first_responder_at_show": responders, "dialog_text": value,
                  "focus_log": [json.dumps(c)[:260] for c in ((rpc("debug.focus_log", {"limit": 10}) or {}).get("changes") or [])],
                  "page_keys": page_keys, "new_windows": new_windows,
                  "key_replies": [{k: (r or {}).get(k) for k in ("handled_by", "window_kind")} for r in typed]}
        if dialogs:
            rpc("debug.key", {"key": "return"})
            answered = wait(lambda: (page_eval("JSON.stringify(window.__results.prompt_keys)", page_tab) or {}).get("value") not in (None, "undefined") and
                            page_eval("window.__results.prompt_keys", page_tab).get("value"), 4)
            detail["page_got"] = answered
            ok = bool(shown) and value == "abc" and answered == "abc"
        else:
            detail["page_got"] = None
            ok = False
        if opts.in_tree == "on":
            row(ok, "prompts.prompt_keys", detail)
        else:
            row("INFO", "prompts.prompt_keys", detail)
        rpc("debug.key", {"key": "escape"})
        time.sleep(0.5)  # test harness: a prompt left open closes
    if "fullscreen" in CHECKS:
        record("fullscreen")
        action("tab.focus", target=f"tab:{page_tab}")
        def main_frame():
            return next((w.get("frame") for w in windows()), None)
        before = main_frame()
        RAW["fullscreen_toggle"] = action("toggleFullScreen")
        full = wait(lambda: (lambda f: f if f and f != before else None)(main_frame()), 10, 0.5)
        time.sleep(1.5)  # test harness: the Space transition ends
        focus = rpc("debug.focus") or {}
        state = {"frame_before": before, "frame_full": full, "app_active": focus.get("app_active"), "key_window": focus.get("key_window"),
                 "window_list_kinds": sorted({str(w.get("kind")) for w in ((rpc("debug.window_list") or {}).get("windows") or [])})}
        rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "fullscreen.png")})
        if not full:
            row(False, "fullscreen.enter", state)
        else:
            rect = page_eval("JSON.stringify((r => [r.x + r.width / 2, r.y + r.height / 2])("
                             "document.getElementById('field').getBoundingClientRect()))", page_tab)
            page_eval("window.__keys = []; document.getElementById('field').value = ''; document.activeElement && document.activeElement.blur(); true", page_tab)
            try:
                x, y = json.loads(rect.get("value"))
                click = rpc("debug.mouse", {"target": "page", "x": x, "y": y})
            except Exception as error:
                x = y = None
                click = {"error": repr(error)}
            time.sleep(0.3)  # test harness: the click focuses the field
            # Off, the page is a child window that a never-active app never makes key: its keys go to it by name.
            for ch in "full":
                rpc("debug.key", {"key": ch, **({} if opts.in_tree == "on" else {"target": "page"})})
            value = wait(lambda: (lambda v: v if v == "full" else None)(page_eval("document.getElementById('field').value", page_tab).get("value")), 3)
            row(value == "full", "fullscreen.input", dict(state, click=click, value=value or page_eval("document.getElementById('field').value", page_tab).get("value")))
            # Real input as the verifier posted it: to the app's pid, the app never active, its window on its own Space.
            pid = RAW.get("pid")
            real = {"cua": bool(CUA_DRIVER)}
            if CUA_DRIVER and pid and x is not None:
                page_eval("window.__keys = []; document.getElementById('field').value = ''; document.activeElement && document.activeElement.blur(); true", page_tab)
                wins = cua("list_windows", {"pid": pid})
                real["windows"] = json.dumps(wins)[:300]
                win_id = next((int(w["id"]) for w in ((rpc("debug.window_list") or {}).get("windows") or [])
                               if w.get("kind") == "main" and w.get("visible")), None)
                # The field's point in the window (top-left points): the page's origin in the window plus the field.
                layer = next((w for w in ((rpc("debug.layers") or {}).get("windows") or [])), {})
                host = next((b.get("host_screen_rect") for b in layer.get("browsers") or [] if b.get("host_screen_rect")), None)
                wf = layer.get("frame")
                if host and wf:
                    wx, wy = host[0] - wf[0] + x, (wf[1] + wf[3]) - (host[1] + host[3]) + y
                    real["click"] = cua("click", {"pid": pid, "window_id": win_id, "x": wx, "y": wy})
                    time.sleep(0.3)  # test harness: the click lands
                    real["type"] = cua("type_text", {"pid": pid, "window_id": win_id, "text": "real"})
                    time.sleep(0.5)  # test harness: the keys land
                real["value"] = page_eval("document.getElementById('field').value", page_tab).get("value")
                real["page_active_element"] = page_eval("document.activeElement && document.activeElement.id", page_tab).get("value")
                real["app_active"] = (rpc("debug.focus") or {}).get("app_active")
            row("INFO", "fullscreen.real", {k: (json.dumps(v)[:300] if isinstance(v, (dict, list)) else v) for k, v in real.items()})
        action("toggleFullScreen")
        wait(lambda: (lambda f: f if f == before else None)(main_frame()), 10, 0.5)
        time.sleep(1.5)  # test harness: the Space transition back ends
    if "file_after_popup" in CHECKS:
        file_after_popup(page_tab)
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

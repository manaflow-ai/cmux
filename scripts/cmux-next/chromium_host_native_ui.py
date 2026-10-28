"""The `--native-ui` rows of chromium-host-bench.py (p01-process-060, 062, 066, 069): Chromium's native UI from the Chromium
host, drawn by cmux. `--native-ui` runs every row; `--native-ui select,date` only those.

  select            <select>: a click opens a cmux menu with its options (POPUP_MENU, ChromiumHostPopupMenus,
                    feature `chromiumHostPopupMenus`; `debug.menu` lists it) while cmux, never the host, is the
                    frontmost app; choosing an option through the menu changes the page's value with one change
                    event, and a dismissed menu changes nothing. Without cmux popup menus (`debug.cef`
                    `host_popup_menus` false: host mode not live, the feature off, or a fork below API 31) the row
                    says so and fails.
  context_menu      a right click on an empty spot of the page opens cmux's page menu with Chromium's rows
                    (CONTEXT_MENU JSON; `debug.menu` lists it) while cmux is the frontmost app; choosing Chromium's
                    Reload there reloads the page (context_menu_done with the row's command), and a dismissed menu
                    (context_menu_done -1) runs nothing and lets the next right click open a menu again.
  download          a click on a `download` link: the App's downloads list gets a row (DOWNLOAD_STARTED,
                    download_continue with cmux's path, DOWNLOAD_PROGRESS, DOWNLOAD_DONE) that finishes in the
                    Downloads folder with the link's bytes; the row removes the file after.
                    Without host mode (`debug.cef` `backend` not `host`) both say so and fail.

The other rows are Chromium's widgets with a WebContents, made by the Chromium host and shown by cmux from their
layer contexts (ChromiumHostWidgetHost, feature `chromiumHostWidgets`), one row per widget kind:

  date              <input type=date>: a click opens the picker, an InitAsPopup page popup (`page_popup`)
  datalist          <input list>: a click and a key open the suggestions, a page popup (`page_popup`)
  popup_window      window.open(..., 'popup'): the window's pixels fill its cmux pane (`popup_window`)
  devtools_docked   devtools.openDocked: the frontend fills the docked DevTools area (`devtools`)
  devtools_window   devtools.openInWindow: the frontend in its own window (`devtools_window`, or `devtools` in
                    cmux's DevTools window)
  extension_popup   a click on a test extension's action: its popup in a cmux panel (`extension_popup`)
  side_panel        a click on a side panel extension's action: the panel's page over its tab (`side_panel`)
  autofill,         a page's suggestions in cmux's own list (chromium_host_suggestions.py, p01-process-061, feature
  password          `chromiumHostSuggestions`); with it on, the datalist row's options come in that list too

Each widget row passes when `debug.cef` `host_widgets` lists a shown widget of its kind with a non-empty screen frame
within the row's deadline; it records the widget and how long it took to show. Without a widget host (`host_widgets`
null: host mode not live in this build, or the feature off) every widget row says so and the mode fails: it could not
run.

The permission rows (p01-process-062, feature `chromiumPermissionPromptsFromData`) run on a page served from
http://127.0.0.1. That is a secure context with a real origin; a file: page has no origin for the prompt bar. They use
Chromium's fake camera and microphone (`use-fake-device-for-media-stream` in CMUX_NEXT_CEF_EXTRA_SWITCHES), because a
fleet Mac has no camera:

  permission_camera         getUserMedia({video}): Block gives the page NotAllowedError
  permission_microphone     getUserMedia({audio}): Block gives the page NotAllowedError
  permission_location       geolocation.getCurrentPosition: Block gives the page PERMISSION_DENIED (code 1)
  permission_notifications  Notification.requestPermission: Block gives the page "denied"

Each row starts the request in the page and waits for cmux's prompt bar to ask it (`debug.browser.prompts`, Debug
builds). While the question shows, it counts the on-screen windows of the app's child processes (pass: 0, so no
Chromium bubble and no host window). Then it answers Block as the bar's button does and reads the page's result.
The rows answer Block, never Allow: an Allow asks macOS for the camera, microphone or location in cmux's name, and
that system dialog belongs to the TCC rows of task p01-process-089 on each macOS version. Chromium keeps notifications
off (CEFSwitches passes disable-notifications, because DesktopNotifier owns cmux's one macOS notification grant) until
Chromium's notification display goes to cmux. Until then the notifications row reports that the page has no
Notification API, and it fails.
"""
import http.server
import json
import os
import threading
import time

import chromium_host_suggestions as suggestions

PAGE = """<!doctype html><meta charset=utf-8><title>native ui probe</title>
<style>body{margin:0;font:16px system-ui} input,button,select{position:fixed;left:40px;width:240px;height:32px;font-size:16px}</style>
<input id=date type=date style="top:40px">
<input id=list list=opts autocomplete=off style="top:100px">
<datalist id=opts><option value=alpha><option value=bravo><option value=charlie></datalist>
<button id=pop style="top:160px" onclick="window.open('about:blank#native-ui-popup', '', 'popup,width=420,height=320')">popup</button>
<select id=sel style="top:220px" onchange="window.selectChanges = (window.selectChanges || 0) + 1">
<option>alpha<option>bravo<option>charlie</select>
<a id=dl href="data:text/plain;charset=utf-8,native-ui-download" download="native-ui-download.txt"
 style="position:fixed;left:40px;top:340px;font-size:16px">download</a>
""" + suggestions.FIELDS

# The permission rows, on their own served page.
PERMISSION_ROW_NAMES = ("permission_camera", "permission_microphone", "permission_location", "permission_notifications")
# Every row, in the order they run.
ROWS = ("select", "context_menu", "download", "date", "datalist", "popup_window", "devtools_docked", "devtools_window",
        "extension_popup", "side_panel", *suggestions.ROWS, *PERMISSION_ROW_NAMES)
# The rows cmux draws itself: no hosted widget, no suggestion list.
CMUX_ROWS = ("select", "context_menu", "download")
SELECT_OPTIONS = ["alpha", "bravo", "charlie"]
# Chromium's page menu row the context_menu row chooses (IDS_CONTENT_CONTEXT_RELOAD), and the page's proof that it ran:
# the marker set before the menu is gone and the last navigation was a reload.
MENU_RELOAD = "Reload"
RELOADED = ("(() => !window.__menuMarker && document.readyState === 'complete' && "
            "performance.getEntriesByType('navigation')[0].type === 'reload')()")
SET_MARKER = "(() => { window.__menuMarker = 1; return true; })()"
MARKER_STAYS = "window.__menuMarker === 1"
PROBE_LOADED = "document.readyState === 'complete' && !!document.getElementById('pop')"
# The download link's file name and bytes (PAGE's #dl).
DOWNLOAD_NAME = "native-ui-download"
DOWNLOAD_BYTES = b"native-ui-download"

EXTENSIONS = (
    ("Native UI Popup", {"action": {"default_popup": "popup.html"}}),
    ("Native UI Side Panel", {"action": {}, "permissions": ["sidePanel"], "side_panel": {"default_path": "panel.html"},
                              "background": {"service_worker": "background.js"}}),
)

# How long a widget may take to show after the input that opens it.
SHOW_DEADLINE_S = 10.0

PERMISSION_PAGE = """<!doctype html><meta charset=utf-8><title>permission probe</title>
<script>
window.__perm = {};
function settle(name, state, detail) { window.__perm[name] = Object.assign({state}, detail || {}); }
function ask(name) {
  settle(name, "pending");
  const media = c => navigator.mediaDevices.getUserMedia(c).then(
    s => { s.getTracks().forEach(t => t.stop()); settle(name, "granted"); },
    e => settle(name, "error", {name: e.name, message: String(e.message || "")}));
  if (name === "camera") return media({video: true});
  if (name === "microphone") return media({audio: true});
  if (name === "location") return navigator.geolocation.getCurrentPosition(
    () => settle(name, "granted"), e => settle(name, "error", {code: e.code, message: String(e.message || "")}),
    {timeout: 60000});
  if (name === "notifications") {
    if (typeof Notification === "undefined") return settle(name, "unavailable");
    return Notification.requestPermission().then(r => settle(name, "answered", {result: r}));
  }
}
</script><p>permission probe</p>
"""

# (row, the request's name in PERMISSION_PAGE, a word of cmux's prompt kind, whether the page's result is Block's).
PERMISSION_ROWS = (
    ("permission_camera", "camera", "camera", lambda r: r.get("state") == "error" and r.get("name") == "NotAllowedError"),
    ("permission_microphone", "microphone", "microphone",
     lambda r: r.get("state") == "error" and r.get("name") == "NotAllowedError"),
    ("permission_location", "location", "location", lambda r: r.get("state") == "error" and r.get("code") == 1),
    ("permission_notifications", "notifications", "notifications", lambda r: r.get("result") == "denied"),
)

# How long the prompt bar may take to ask after the page's request, and the page to hear the answer.
PROMPT_DEADLINE_S = 10.0
ANSWER_DEADLINE_S = 10.0


def serve_permission_page():
    """PERMISSION_PAGE on http://127.0.0.1:<free port>/ from a daemon thread that ends with the bench: its URL."""
    body = PERMISSION_PAGE.encode()

    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, name="permission-page", daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/"


def write_extensions(root):
    """Unpacked MV3 test extensions (CMUX_NEXT_CEF_LOAD_EXTENSIONS): an action popup and a side panel."""
    paths = []
    for index, (name, extra) in enumerate(EXTENSIONS):
        folder = os.path.join(root, f"native-ui-ext{index}")
        os.makedirs(folder, exist_ok=True)
        manifest = {"manifest_version": 3, "name": name, "version": "1.0", **extra}
        with open(os.path.join(folder, "manifest.json"), "w") as f:
            json.dump(manifest, f)
        for page in ("popup.html", "panel.html"):
            with open(os.path.join(folder, page), "w") as f:
                f.write(f"<!doctype html><title>{name}</title><body style='width:280px;height:180px'><p>{name}</p>")
        if "background" in manifest:
            with open(os.path.join(folder, "background.js"), "w") as f:
                f.write("chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: true});\n")
        paths.append(folder)
    return paths


def launch_env(extension_paths):
    """What the app needs for these rows: the features, the test extensions, and Chromium's fake capture devices."""
    return {"CMUX_ENABLE_FEATURES": "chromiumHostWidgets,chromiumHostPopupMenus,chromiumHostSuggestions,"
                                    "chromiumPermissionPromptsFromData",
            "CMUX_NEXT_CEF_LOAD_EXTENSIONS": ":".join(extension_paths),
            "CMUX_NEXT_CEF_EXTRA_SWITCHES": "use-fake-device-for-media-stream"}


def rows_named(names, rows=ROWS):
    """`--native-ui`'s value as the rows to run, in `rows` order: all for "", else the comma-separated names. Raises
    ValueError for a name that is no row."""
    wanted = [name.strip() for name in (names or "").split(",") if name.strip()]
    unknown = sorted(set(wanted) - set(rows))
    if unknown:
        raise ValueError(f"no native-ui row {', '.join(unknown)} (rows: {', '.join(rows)})")
    return [row for row in rows if not wanted or row in wanted]


def host_widgets(rpc):
    """`debug.cef` `host_widgets`: None without a widget host, else the widgets shown now."""
    return (rpc("debug.cef") or {}).get("host_widgets")


def shown(rpc, kinds):
    """The first shown widget of one of `kinds` with a non-empty frame, or None."""
    for widget in host_widgets(rpc) or []:
        frame = widget.get("frame") or [0, 0, 0, 0]
        if widget.get("kind") in kinds and widget.get("shown") and frame[2] > 0 and frame[3] > 0:
            return widget
    return None


def wait_shown(rpc, wait, kinds):
    started = time.time()
    widget = wait(lambda: shown(rpc, kinds), SHOW_DEADLINE_S)
    return {"ok": widget is not None, "widget": widget, "show_ms": round((time.time() - started) * 1000, 1) if widget else None,
            "host_widgets": None if widget else host_widgets(rpc)}


def open_menu(rpc):
    """`debug.menu` while a cmux menu is open, else None."""
    menu = rpc("debug.menu") or {}
    return menu if menu.get("open") else None


def select_row(rpc, wait, page_eval, click, front, app_pid):
    """A <select> opens a cmux menu (task 060); the host never becomes the frontmost app; a choice changes the page
    once and a dismissal not at all."""
    if not (rpc("debug.cef") or {}).get("host_popup_menus"):
        return {"ok": False, "not_run": "no cmux popup menus: host mode is not live in this build, chromiumHostPopupMenus "
                                        "is off, or the host's Chromium fork is below API 31 (p01-process-178)"}
    page_eval("(() => { document.getElementById('sel').value = 'alpha'; window.selectChanges = 0; return true; })()")
    started = time.time()
    click("sel")
    menu = wait(lambda: open_menu(rpc), SHOW_DEADLINE_S)
    row = {"items": (menu or {}).get("items"), "show_ms": round((time.time() - started) * 1000, 1) if menu else None}
    if not menu:
        row.update(ok=False, error="no cmux menu opened for the <select>")
        return row
    # Read while the menu is open: the frontmost app is cmux, not the Chromium host.
    row["front_pid"], row["app_pid"] = front(), app_pid
    row["host_never_front"] = row["front_pid"] is not None and row["front_pid"] == app_pid
    rpc("debug.menu", {"choose": "bravo"})
    chose = "document.getElementById('sel').value === 'bravo' && window.selectChanges === 1"
    row["chose"] = bool(wait(lambda: page_eval(chose), 5))
    # Opened again and dismissed: the value and the change count stay.
    click("sel")
    reopened = wait(lambda: open_menu(rpc), SHOW_DEADLINE_S)
    rpc("debug.menu", {"dismiss": True})
    closed = wait(lambda: open_menu(rpc) is None, 5)
    time.sleep(0.3)  # test harness: a change event the dismissal might wrongly send has reached the page
    row["dismissed"] = bool(reopened) and bool(closed) and bool(page_eval(chose))
    row["ok"] = row["items"] == SELECT_OPTIONS and row["host_never_front"] and row["chose"] and row["dismissed"]
    return row


def host_mode(rpc):
    """None when Chromium runs in the Chromium Host, else why the host rows cannot run."""
    backend = (rpc("debug.cef") or {}).get("backend")
    return None if backend == "host" else f"host mode is not live in this build (debug.cef backend {backend!r})"


def menu_after(rpc, wait, right_click):
    """A right click on the page, then the cmux menu it opened (`debug.menu`), or None."""
    if right_click() is False:
        return None
    return wait(lambda: open_menu(rpc), SHOW_DEADLINE_S)


def dismiss_menu(rpc, wait):
    rpc("debug.menu", {"dismiss": True})
    return wait(lambda: open_menu(rpc) is None, 5)


def context_menu_row(rpc, wait, page_eval, right_click, front, app_pid):
    """Chromium's page menu from the host in cmux's menu (task 069): its rows arrive (CONTEXT_MENU), a chosen row runs
    in the host (context_menu_done with its command), a dismissed menu runs nothing and the page opens the next one."""
    reason = host_mode(rpc) or (None if right_click else "the bench gave no way to right-click the page")
    if reason:
        return {"ok": False, "not_run": reason}
    page_eval(SET_MARKER)
    started = time.time()
    menu = menu_after(rpc, wait, right_click)
    row = {"items": (menu or {}).get("items"), "show_ms": round((time.time() - started) * 1000, 1) if menu else None}
    if not menu:
        row.update(ok=False, error="no cmux menu opened for the right click")
        return row
    # Read while the menu is open: the frontmost app is cmux, not the Chromium host.
    row["front_pid"], row["app_pid"] = front(), app_pid
    row["host_never_front"] = row["front_pid"] is not None and row["front_pid"] == app_pid
    if MENU_RELOAD not in (row["items"] or []):
        dismiss_menu(rpc, wait)
        row.update(ok=False, error=f"the menu has no {MENU_RELOAD!r} row: CONTEXT_MENU's items did not reach it")
        return row
    rpc("debug.menu", {"choose": MENU_RELOAD})
    row["chose"] = bool(wait(lambda: page_eval(RELOADED), SHOW_DEADLINE_S))
    # Dismissed: nothing runs, and Chromium, told the menu ended, shows the next one.
    page_eval(SET_MARKER)
    shown = menu_after(rpc, wait, right_click)
    closed = dismiss_menu(rpc, wait)
    time.sleep(0.3)  # test harness: a command the dismissal might wrongly run has reached the page
    row["dismissed"] = bool(shown) and bool(closed) and bool(page_eval(MARKER_STAYS))
    row["reopened"] = bool(menu_after(rpc, wait, right_click))
    dismiss_menu(rpc, wait)
    row["ok"] = row["host_never_front"] and row["chose"] and row["dismissed"] and row["reopened"]
    return row


def downloads_list(rpc):
    """`debug.downloads`' rows, or None without the App's downloads list."""
    reply = rpc("debug.downloads")
    return reply.get("downloads") if isinstance(reply, dict) else None


def download_row(rpc, wait, click, front, app_pid):
    """A page's download through the host (task 069): DOWNLOAD_STARTED reaches the App's list, cmux's path goes back
    (download_continue) and the file lands there with the link's bytes. Removes the file after."""
    reason = host_mode(rpc)
    if reason:
        return {"ok": False, "not_run": reason}
    before = downloads_list(rpc)
    if before is None:
        return {"ok": False, "not_run": "no downloads list (debug.downloads): not a DEBUG or bench build"}
    known = {item.get("id") for item in before}

    def ended():
        return next((item for item in downloads_list(rpc) or [] if item.get("id") not in known
                     and (item.get("filename") or "").startswith(DOWNLOAD_NAME) and item.get("status") != "inProgress"),
                    None)
    started = time.time()
    click("dl")
    item = wait(ended, SHOW_DEADLINE_S)
    row = {"download": item, "done_ms": round((time.time() - started) * 1000, 1) if item else None,
           "front_pid": front(), "app_pid": app_pid}
    row["host_never_front"] = row["front_pid"] is not None and row["front_pid"] == app_pid
    if not item:
        row.update(ok=False, error="no download row ended for the link")
        return row
    destination = item.get("destination")
    row["bytes_ok"] = False
    if item.get("status") == "finished" and destination and os.path.isfile(destination):
        with open(destination, "rb") as f:
            row["bytes_ok"] = f.read() == DOWNLOAD_BYTES
        os.remove(destination)
    row["ok"] = item.get("status") == "finished" and row["bytes_ok"] and row["host_never_front"]
    return row


def prompts(rpc):
    """The focused tab's pending prompts (`debug.browser.prompts`), or None where that call does not answer."""
    reply = rpc("debug.browser.prompts")
    return reply.get("prompts") if isinstance(reply, dict) and isinstance(reply.get("prompts"), list) else None


def asked(rpc, word):
    """The first pending permission prompt whose kind names `word`, or None."""
    for prompt in prompts(rpc) or []:
        kind = str(prompt.get("kind") or "").lower()
        if kind.startswith("permission(") and word in kind:
            return prompt
    return None


def permission_row(rpc, wait, page_eval, host_windows, name, word, blocked):
    """One permission request: cmux asks it, no child process shows a window, and Block reaches the page."""
    for _ in range(5):  # a question an earlier row left open is not this row's
        if not prompts(rpc):
            break
        rpc("debug.browser.prompts", {"respond": "cancel"})
    result = lambda: page_eval(f"window.__perm && window.__perm[{json.dumps(name)}]") or {}
    page_eval(f"ask({json.dumps(name)}), true")
    if result().get("state") == "unavailable":
        return {"ok": False, "not_run": f"the page has no {name} API: Chromium runs with disable-notifications "
                                        "(CEFSwitches) until its notification display goes to cmux's DesktopNotifier"}
    started = time.time()
    prompt = wait(lambda: asked(rpc, word), PROMPT_DEADLINE_S)
    row = {"prompt": prompt, "prompt_ms": round((time.time() - started) * 1000, 1) if prompt else None}
    windows = host_windows()
    row["child_windows_on_screen"] = {"count": None if windows is None else len(windows), "windows": (windows or [])[:8]}
    if prompt is None:
        row.update(ok=False, page=result(), prompts=prompts(rpc))
        return row
    row["responded"] = (rpc("debug.browser.prompts", {"respond": "deny"}) or {}).get("responded")
    page = wait(lambda: (lambda r: r if r.get("state") not in (None, "pending") else None)(result()), ANSWER_DEADLINE_S)
    row["page"] = page or result()
    row["ok"] = windows == [] and row["responded"] is True and bool(page) and blocked(page)
    return row


def permission_rows(rpc, wait, page_eval, permission_url, host_windows, names=PERMISSION_ROW_NAMES,
                    on_row=lambda name, row: row):
    """The permission rows of `names` on the served page, each `not_run` where the build or the bench cannot run them.
    `host_windows()` lists the on-screen windows (alpha > 0) of the app's child processes (the Chromium Host and its
    helpers), or None when the window server cannot be read. `on_row(name, row)` runs right after each row and returns
    the row to keep (run's)."""
    ordered = [row for row in PERMISSION_ROW_NAMES if row in names]
    if not permission_url or host_windows is None:
        return {name: on_row(name, {"ok": False, "not_run": "the bench gave no permission page or no way to list the "
                                                            "app's child windows"}) for name in ordered}
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": permission_url}, "focus": True,
                                "origin": "script"}, timeout=120)
    if not wait(lambda: page_eval("document.readyState === 'complete' && typeof ask === 'function'"), 60, 0.5):
        error = f"the permission probe never loaded: {json.dumps(opened)[:200]}"
        return {name: on_row(name, {"ok": False, "error": error}) for name in ordered}
    if prompts(rpc) is None:
        reason = "debug.browser.prompts does not answer: these rows answer the prompt bar through it, in a Debug build"
        return {name: on_row(name, {"ok": False, "not_run": reason}) for name in ordered}
    return {row: on_row(row, permission_row(rpc, wait, page_eval, host_windows, name, word, blocked))
            for row, name, word, blocked in PERMISSION_ROWS if row in names}


def run(rpc, wait, page_eval, url, rows_to_run=ROWS, front=lambda: None, app_pid=None, right_click=None,
        permission_url=None, host_windows=None, on_row=lambda name, row: row):
    """`rows_to_run` (rows_named), one at a time in ROWS order: the probe rows in one probe tab, then the permission
    rows on their served page; `front` gives the frontmost app's pid, `app_pid` is cmux's; `right_click` right-clicks
    an empty spot of the page and returns False when it could not (None: the context_menu row cannot run);
    `permission_url` is serve_permission_page()'s and `host_windows` permission_rows'. `on_row(name, row)` runs right
    after each row and returns the row to keep (the bench adds the host's window lines the row caused). A probe that
    never loads fails each probe row. Returns (rows, ok)."""
    rows = {}
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"}, timeout=120)
    if not wait(lambda: page_eval(PROBE_LOADED), 60, 0.5):
        error = f"the probe never loaded: {json.dumps(opened)[:200]}"
        rows = {name: on_row(name, {"ok": False, "error": error})
                for name in ROWS if name in rows_to_run and name not in PERMISSION_ROW_NAMES}
        permission_names = [row for row in rows_to_run if row in PERMISSION_ROW_NAMES]
        if permission_names:
            rows.update(permission_rows(rpc, wait, page_eval, permission_url, host_windows, permission_names,
                                        on_row=on_row))
        return rows, False

    def center(element):
        rect = page_eval(f"(() => {{ const r = document.getElementById('{element}').getBoundingClientRect(); "
                         f"return [r.x + r.width / 2, r.y + r.height / 2]; }})()")
        return {"x": rect[0], "y": rect[1]} if rect else {}

    def click(element):
        rpc("debug.mouse", {"target": "page", **center(element)})

    def dismiss_page_popup():
        rpc("debug.key", {"target": "page", "key": "escape"})
        wait(lambda: shown(rpc, ("page_popup",)) is None, 5)

    widget_host = None
    for name in ROWS:
        if name not in rows_to_run or name in PERMISSION_ROW_NAMES:
            continue
        if name == "select":
            row = select_row(rpc, wait, page_eval, click, front, app_pid)
        elif name == "context_menu":
            row = context_menu_row(rpc, wait, page_eval, right_click, front, app_pid)
            wait(lambda: page_eval(PROBE_LOADED), 60, 0.5)  # the row reloaded the probe
        elif name == "download":
            row = download_row(rpc, wait, click, front, app_pid)
        elif name in suggestions.ROWS:
            row = suggestions.run(rpc, wait, page_eval, click, [name])[name]
        else:
            if widget_host is None:
                widget_host = host_widgets(rpc) is not None
            if widget_host:
                row = run_widget_rows(rpc, wait, click, dismiss_page_popup, [name])[name]
            else:
                row = {"ok": False,
                       "not_run": "no widget host: host mode is not live in this build (task 080) or chromiumHostWidgets is off"}
        rows[name] = on_row(name, row)
    permission_names = [row for row in rows_to_run if row in PERMISSION_ROW_NAMES]
    if permission_names:
        rows.update(permission_rows(rpc, wait, page_eval, permission_url, host_windows, permission_names, on_row=on_row))
    return rows, all(row.get("ok") for row in rows.values())


def run_widget_rows(rpc, wait, click, dismiss_page_popup, names):
    """The hosted widget rows of `names`, in ROWS order."""
    rows = {}
    if "date" in names:
        click("date")
        rows["date"] = wait_shown(rpc, wait, ("page_popup",))
        dismiss_page_popup()

    if "datalist" in names:
        click("list")
        rpc("debug.key", {"target": "page", "key": "a"})
        rows["datalist"] = suggestions.datalist(rpc, wait) if suggestions.drawn(rpc) else wait_shown(rpc, wait, ("page_popup",))
        dismiss_page_popup()

    if "popup_window" in names:
        click("pop")
        rows["popup_window"] = wait_shown(rpc, wait, ("popup_window",))

    devtools = ("devtools", "devtools_window")
    if "devtools_docked" in names:
        rpc("action.run", {"action": "devtools.openDocked", "origin": "script"})
        rows["devtools_docked"] = wait_shown(rpc, wait, ("devtools",))
        # Closed first, so a DevTools shown next is the window's (a host's own window, or the frontend in cmux's).
        rpc("action.run", {"action": "devtools.close", "origin": "script"})
        wait(lambda: shown(rpc, devtools) is None, 5)
    if "devtools_window" in names:
        rpc("action.run", {"action": "devtools.openInWindow", "origin": "script"})
        rows["devtools_window"] = wait_shown(rpc, wait, devtools)
        rpc("action.run", {"action": "devtools.close", "origin": "script"})

    ids = {e.get("name"): e.get("id") for e in (rpc("browser.extensions") or {}).get("extensions") or []}
    for row, (name, _), kind in (("extension_popup", EXTENSIONS[0], "extension_popup"), ("side_panel", EXTENSIONS[1], "side_panel")):
        if row not in names:
            continue
        if not ids.get(name):
            rows[row] = {"ok": False, "error": f"the test extension {name!r} did not load", "extensions": sorted(ids)}
            continue
        rpc("debug.extensions.click", {"extension": ids[name]})
        rows[row] = wait_shown(rpc, wait, (kind,))
        if kind == "extension_popup":
            rpc("debug.extensions.popup", {"hide": True})
    return rows

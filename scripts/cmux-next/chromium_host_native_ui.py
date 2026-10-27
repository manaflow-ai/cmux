"""The `--native-ui` rows of chromium-host-bench.py (p01-process-060, 066, 067, 069): Chromium's native UI from the Chromium
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

The last row leaves the probe page for an https site (a new Chromium tab), so it runs after the others:

  passkey           p01-process-067 (feature `chromiumHostPasskeys`): on PASSKEY_SITE (https: WebAuthn needs a secure
                    origin), a modal navigator.credentials.get with an allow list of one iCloud Keychain id reaches cmux
                    as a WEBAUTHN GET (`debug.cef` `host_passkeys` `gets`, counted from after the page load, so the
                    load's conditional LIST is not it), passes every check of cmux to the system sheet (`sheets`, no
                    `refused_*`), and ends with the system's answer (`answered`) or the page's abort after the sheet
                    (`cancels`); the page sees the outcome. Needs a signed build with the browser passkey entitlement
                    (`handler_set` 1; a tagged DEV build has none, K18) and fork API 31. It proves the relay, not a
                    sign-in: no credential signs, so the client data byte check is not reached (passkeys.md 3.9.5).

Each widget row passes when `debug.cef` `host_widgets` lists a shown widget of its kind with a non-empty screen frame
within the row's deadline; it records the widget and how long it took to show. Without a widget host (`host_widgets`
null: host mode not live in this build, or the feature off) every widget row says so and the mode fails: it could not
run.
"""
import json
import os
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

# Every row, in the order they run.
ROWS = ("select", "context_menu", "download", "date", "datalist", "popup_window", "devtools_docked", "devtools_window",
        "extension_popup", "side_panel", *suggestions.ROWS, "passkey")
# The rows cmux draws itself: no hosted widget, no suggestion list.
CMUX_ROWS = ("select", "context_menu", "download")
# The row that relays an iCloud Keychain request to cmux (p01-process-067): no widget; it opens its own tab, so it runs last.
PASSKEY_ROW = "passkey"
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

# The passkey row's page: an https origin whose host is the rp id.
PASSKEY_SITE = "https://webauthn.io/"

# Starts a modal get for a credential id no authenticator has, so nothing signs; the page keeps the outcome.
PASSKEY_GET = """(() => {
  const abort = new AbortController();
  window.__cmuxPasskey = {abort, outcome: null};
  const id = new Uint8Array(32); crypto.getRandomValues(id);
  const challenge = new Uint8Array(32); crypto.getRandomValues(challenge);
  navigator.credentials.get({signal: abort.signal, publicKey: {challenge, rpId: location.hostname, userVerification: 'preferred',
    allowCredentials: [{type: 'public-key', id, transports: ['internal', 'hybrid']}], timeout: 60000}})
    .then(() => { window.__cmuxPasskey.outcome = 'resolved'; }, (e) => { window.__cmuxPasskey.outcome = e.name; });
  return true;
})()"""



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
    """What the app needs for these rows: the features, and the test extensions."""
    return {"CMUX_ENABLE_FEATURES": "chromiumHostWidgets,chromiumHostPopupMenus,chromiumHostSuggestions,chromiumHostPasskeys",
            "CMUX_NEXT_CEF_LOAD_EXTENSIONS": ":".join(extension_paths)}


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


def host_passkeys(rpc):
    """`debug.cef` `host_passkeys`: None without the relay, else its counters (never a request's content)."""
    return (rpc("debug.cef") or {}).get("host_passkeys")


def new_refusals(before, after):
    """The `refused_*` counters that rose from BEFORE to AFTER, by how much."""
    return {key: value - before.get(key, 0) for key, value in after.items()
            if key.startswith("refused_") and value > before.get(key, 0)}


def rose(before, after, key):
    return after.get(key, 0) > before.get(key, 0)


def sheet_or_end(before, now):
    """The GET showed the system sheet, or ended without one (a refusal or an answer)."""
    return rose(before, now, "sheets") or answered_gets(before, now) > 0 or bool(new_refusals(before, now))


def answered_gets(before, after):
    """Answers that were not a LIST's: a LIST (conditional autofill) ends answered or refused, so answers beyond the
    LISTs counted are the GET's."""
    def grew(key):
        return after.get(key, 0) - before.get(key, 0)
    return grew("answered") - grew("lists")


def passkey_verdict(before, asked, at_sheet, after, outcome):
    """Whether the row passed, from the counters BEFORE the GET, AT_SHEET (when the sheet showed or the wait ended)
    and AFTER it settled: the GET reached cmux, reached the system sheet with no refusal, and ended with the system's
    answer or the page's abort after the sheet."""
    sheet = rose(before, at_sheet, "sheets")
    settled = answered_gets(before, after) > 0 or rose(at_sheet, after, "cancels")
    return bool(asked) and sheet and not new_refusals(before, after) and settled and outcome is not None


def passkey_row(rpc, wait, page_eval):
    """The passkey row (p01-process-067)."""
    relay = host_passkeys(rpc)
    if relay is None:
        return {"ok": False, "not_run": "no passkey relay: host mode is not live in this build or chromiumHostPasskeys is off"}
    if not relay.get("handler_set"):
        return {"ok": False, "not_run": "the host has no iCloud Keychain handler: an unsigned build (K18) or fork API < 31",
                "host_passkeys": relay}
    rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": PASSKEY_SITE}, "focus": True, "origin": "script"}, timeout=120)
    if not wait(lambda: page_eval("document.readyState === 'complete' && location.protocol === 'https:'"), 60, 0.5):
        return {"ok": False, "error": f"{PASSKEY_SITE} did not load"}
    before = host_passkeys(rpc) or {}
    started = time.time()
    page_eval(PASSKEY_GET)
    asked = wait(lambda: rose(before, host_passkeys(rpc) or {}, "gets"), SHOW_DEADLINE_S)
    request_ms = round((time.time() - started) * 1000, 1) if asked else None
    # The sheet, or the end without one (a refusal or an answer before it): only then does the page abort.
    wait(lambda: sheet_or_end(before, host_passkeys(rpc) or {}), SHOW_DEADLINE_S)
    at_sheet = host_passkeys(rpc) or {}
    page_eval("window.__cmuxPasskey && window.__cmuxPasskey.abort.abort()")
    outcome = wait(lambda: page_eval("window.__cmuxPasskey && window.__cmuxPasskey.outcome"), SHOW_DEADLINE_S)
    after = host_passkeys(rpc) or {}
    return {"ok": passkey_verdict(before, asked, at_sheet, after, outcome), "request_ms": request_ms, "page_outcome": outcome,
            "refused": new_refusals(before, after), "host_passkeys": after,
            "proves": "the relay to the system sheet, not a sign-in (passkeys.md 3.9.5)"}


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


def run(rpc, wait, page_eval, url, rows_to_run=ROWS, front=lambda: None, app_pid=None, right_click=None):
    """`rows_to_run` (rows_named); `front` gives the frontmost app's pid, `app_pid` is cmux's; `right_click` right-clicks
    an empty spot of the page and returns False when it could not (None: the context_menu row cannot run). Returns
    (rows, ok)."""
    rows = {}
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"}, timeout=120)
    if not wait(lambda: page_eval(PROBE_LOADED), 60, 0.5):
        return {"error": f"the probe never loaded: {json.dumps(opened)[:200]}"}, False

    def center(element):
        rect = page_eval(f"(() => {{ const r = document.getElementById('{element}').getBoundingClientRect(); "
                         f"return [r.x + r.width / 2, r.y + r.height / 2]; }})()")
        return {"x": rect[0], "y": rect[1]} if rect else {}

    def click(element):
        rpc("debug.mouse", {"target": "page", **center(element)})

    def dismiss_page_popup():
        rpc("debug.key", {"target": "page", "key": "escape"})
        wait(lambda: shown(rpc, ("page_popup",)) is None, 5)

    if "select" in rows_to_run:
        rows["select"] = select_row(rpc, wait, page_eval, click, front, app_pid)
    if "context_menu" in rows_to_run:
        rows["context_menu"] = context_menu_row(rpc, wait, page_eval, right_click, front, app_pid)
        wait(lambda: page_eval(PROBE_LOADED), 60, 0.5)  # the row reloaded the probe
    if "download" in rows_to_run:
        rows["download"] = download_row(rpc, wait, click, front, app_pid)
    widget_rows = [row for row in rows_to_run if row not in CMUX_ROWS and row not in suggestions.ROWS and row != PASSKEY_ROW]
    if widget_rows:
        if host_widgets(rpc) is None:
            reason = "no widget host: host mode is not live in this build (task 080) or chromiumHostWidgets is off"
            rows.update({name: {"ok": False, "not_run": reason} for name in widget_rows})
        else:
            rows.update(run_widget_rows(rpc, wait, click, dismiss_page_popup, widget_rows))
    suggestion_rows = [row for row in rows_to_run if row in suggestions.ROWS]
    if suggestion_rows:
        rows.update(suggestions.run(rpc, wait, page_eval, click, suggestion_rows))
    if PASSKEY_ROW in rows_to_run:
        rows[PASSKEY_ROW] = passkey_row(rpc, wait, page_eval)
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

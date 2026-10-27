"""The `--native-ui` rows of chromium-host-bench.py (p01-process-060, 066): Chromium's native UI from the Chromium
host, drawn by cmux. `--native-ui` runs every row; `--native-ui select,date` only those.

  select            <select>: a click opens a cmux menu with its options (POPUP_MENU, ChromiumHostPopupMenus,
                    feature `chromiumHostPopupMenus`; `debug.menu` lists it) while cmux, never the host, is the
                    frontmost app; choosing an option through the menu changes the page's value with one change
                    event, and a dismissed menu changes nothing. Without cmux popup menus (`debug.cef`
                    `host_popup_menus` false: host mode not live, the feature off, or a fork below API 31) the row
                    says so and fails.

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
""" + suggestions.FIELDS

# Every row, in the order they run.
ROWS = ("select", "date", "datalist", "popup_window", "devtools_docked", "devtools_window", "extension_popup",
        "side_panel", *suggestions.ROWS)
SELECT_OPTIONS = ["alpha", "bravo", "charlie"]

EXTENSIONS = (
    ("Native UI Popup", {"action": {"default_popup": "popup.html"}}),
    ("Native UI Side Panel", {"action": {}, "permissions": ["sidePanel"], "side_panel": {"default_path": "panel.html"},
                              "background": {"service_worker": "background.js"}}),
)

# How long a widget may take to show after the input that opens it.
SHOW_DEADLINE_S = 10.0


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
    return {"CMUX_ENABLE_FEATURES": "chromiumHostWidgets,chromiumHostPopupMenus,chromiumHostSuggestions",
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


def run(rpc, wait, page_eval, url, rows_to_run=ROWS, front=lambda: None, app_pid=None, on_row=lambda name, row: row):
    """`rows_to_run` (rows_named), one at a time in ROWS order in one probe tab; `front` gives the frontmost app's pid,
    `app_pid` is cmux's. `on_row(name, row)` runs right after each row and returns the row to keep (the bench adds the
    host's window lines the row caused). A probe that never loads fails each row. Returns (rows, ok)."""
    rows = {}
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"}, timeout=120)
    if not wait(lambda: page_eval("document.readyState === 'complete' && !!document.getElementById('pop')"), 60, 0.5):
        error = f"the probe never loaded: {json.dumps(opened)[:200]}"
        rows = {name: on_row(name, {"ok": False, "error": error}) for name in ROWS if name in rows_to_run}
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
        if name not in rows_to_run:
            continue
        if name == "select":
            row = select_row(rpc, wait, page_eval, click, front, app_pid)
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

"""The `--native-ui` rows of chromium-host-bench.py (p01-process-066): Chromium's widgets with a WebContents, made
by the Chromium host and shown by cmux from their layer contexts (ChromiumHostWidgetHost, feature
`chromiumHostWidgets`), one row per widget kind:

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

Each row passes when `debug.cef` `host_widgets` lists a shown widget of its kind with a non-empty screen frame
within the row's deadline; it records the widget and how long it took to show. Without a widget host (`host_widgets`
null: host mode not live in this build, or the feature off) every row says so and the mode fails: it could not run.
"""
import json
import os
import time

import chromium_host_suggestions as suggestions

PAGE = """<!doctype html><meta charset=utf-8><title>native ui probe</title>
<style>body{margin:0;font:16px system-ui} input,button{position:fixed;left:40px;width:240px;height:32px;font-size:16px}</style>
<input id=date type=date style="top:40px">
<input id=list list=opts autocomplete=off style="top:100px">
<datalist id=opts><option value=alpha><option value=bravo><option value=charlie></datalist>
<button id=pop style="top:160px" onclick="window.open('about:blank#native-ui-popup', '', 'popup,width=420,height=320')">popup</button>
""" + suggestions.FIELDS

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
    """What the app needs for these rows: the feature, and the test extensions."""
    return {"CMUX_ENABLE_FEATURES": "chromiumHostWidgets,chromiumHostSuggestions",
            "CMUX_NEXT_CEF_LOAD_EXTENSIONS": ":".join(extension_paths)}


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


def run(rpc, wait, page_eval, url):
    """Every row; returns (rows, ok)."""
    rows = {}
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"}, timeout=120)
    if not wait(lambda: page_eval("document.readyState === 'complete' && !!document.getElementById('pop')"), 60, 0.5):
        return {"error": f"the probe never loaded: {json.dumps(opened)[:200]}"}, False
    if host_widgets(rpc) is None:
        reason = "no widget host: host mode is not live in this build (task 080) or chromiumHostWidgets is off"
        return {name: {"ok": False, "not_run": reason} for name in
                ("date", "datalist", "popup_window", "devtools_docked", "devtools_window", "extension_popup", "side_panel",
                 *suggestions.ROWS)}, False

    def center(element):
        rect = page_eval(f"(() => {{ const r = document.getElementById('{element}').getBoundingClientRect(); "
                         f"return [r.x + r.width / 2, r.y + r.height / 2]; }})()")
        return {"x": rect[0], "y": rect[1]} if rect else {}

    def click(element):
        rpc("debug.mouse", {"target": "page", **center(element)})

    def dismiss_page_popup():
        rpc("debug.key", {"target": "page", "key": "escape"})
        wait(lambda: shown(rpc, ("page_popup",)) is None, 5)

    click("date")
    rows["date"] = wait_shown(rpc, wait, ("page_popup",))
    dismiss_page_popup()

    click("list")
    rpc("debug.key", {"target": "page", "key": "a"})
    rows["datalist"] = suggestions.datalist(rpc, wait) if suggestions.drawn(rpc) else wait_shown(rpc, wait, ("page_popup",))
    dismiss_page_popup()

    click("pop")
    rows["popup_window"] = wait_shown(rpc, wait, ("popup_window",))

    devtools = ("devtools", "devtools_window")
    rpc("action.run", {"action": "devtools.openDocked", "origin": "script"})
    rows["devtools_docked"] = wait_shown(rpc, wait, ("devtools",))
    # Closed first, so a DevTools shown next is the window's (a host's own window, or the frontend in cmux's).
    rpc("action.run", {"action": "devtools.close", "origin": "script"})
    wait(lambda: shown(rpc, devtools) is None, 5)
    rpc("action.run", {"action": "devtools.openInWindow", "origin": "script"})
    rows["devtools_window"] = wait_shown(rpc, wait, devtools)
    rpc("action.run", {"action": "devtools.close", "origin": "script"})

    ids = {e.get("name"): e.get("id") for e in (rpc("browser.extensions") or {}).get("extensions") or []}
    for row, (name, _), kind in (("extension_popup", EXTENSIONS[0], "extension_popup"), ("side_panel", EXTENSIONS[1], "side_panel")):
        if not ids.get(name):
            rows[row] = {"ok": False, "error": f"the test extension {name!r} did not load", "extensions": sorted(ids)}
            continue
        rpc("debug.extensions.click", {"extension": ids[name]})
        rows[row] = wait_shown(rpc, wait, (kind,))
        if kind == "extension_popup":
            rpc("debug.extensions.popup", {"hide": True})
    rows.update(suggestions.run(rpc, wait, page_eval, click))
    return rows, all(row.get("ok") for row in rows.values())

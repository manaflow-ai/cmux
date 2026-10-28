"""The chooser, external protocol, Web Share and picture-in-picture rows of chromium-host-bench.py `--native-ui`
(p01-process-228): Chromium UI that would open a window in the Chromium host, each answered by cmux while the host is
never the frontmost app and owns no visible window (chromium_host_native_ui_dialogs.host_ui_clear).

  color            <input type=color>: a click opens cmux's color panel (`debug.cef` `host_choosers.color_open`,
                   feature `chromiumHostChoosers`); a pick through it (`color_chooser_pick`) reaches the page as an
                   `input` event with that value, and the panel's close (`color_chooser_close`) as its `change`.
  device_chooser   navigator.usb.requestDevice(): cmux's device chooser (`debug.dialog`, browser.chromiumHost.
                   deviceChooser) shows over the tab; its Cancel rejects the page's promise (NotFoundError). Needs no
                   device: a chooser with no rows is the case every Mac can run.
  screen_share     getDisplayMedia(): cmux's picker (browser.chromiumHost.screenShare) lists what the page may share;
                   its Cancel rejects the page's promise (NotAllowedError). On 14/15 the TCC prompt for Screen &
                   System Audio Recording names cmux (run it through scripts/cmux-next/os-matrix.sh).
  external_protocol  a link to ssh:// (an app handles it, and it is not a well-known scheme): cmux's prompt asks in the
                   tab (`debug.browser.prompts`, Debug builds); Open once opens it (recorded:
                   CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS=1) and Chromium's own dialog never shows in the host.
  web_share        navigator.share(): skipped, out of p01-process-228's acceptance. Fork API 31 has no share handler
                   (p01-process-227 added none), so the host has no data to send cmux's NSSharingServicePicker: the
                   fork's handler is p01-process-228b and cmux's side p01-process-228c (WEB_SHARE_TASK), which runs it.
  video_pip        video.requestPictureInPicture(): a `video_pip` hosted widget in cmux's floating panel (`debug.cef`
                   `host_widgets`, feature chromiumHostWidgets); exitPictureInPicture takes it down.
  document_pip     documentPictureInPicture.requestWindow(): a `document_pip` hosted widget in cmux's panel.

Each row records how long its UI took to show and the host check while it showed.
"""
import json
import time

import chromium_host_native_ui_dialogs as dialogs

ROWS = ("color", "device_chooser", "screen_share", "external_protocol", "web_share", "video_pip", "document_pip")
# What the app needs for these rows (the PiP rows also need chromiumHostWidgets, chromium_host_native_ui.launch_env).
FEATURES = "chromiumHostChoosers"
ENV = {"CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS": "1"}
SHOW_DEADLINE_S = 10.0
DEVICE_DIALOG = "browser.chromiumHost.deviceChooser"
SHARE_DIALOG = "browser.chromiumHost.screenShare"
EXTERNAL_URL = "ssh://native-ui.invalid"
# The task that builds the web_share row; until it lands, the row is skipped.
WEB_SHARE_TASK = "p01-process-228c"

PAGE = """<!doctype html><meta charset=utf-8><title>chooser probe</title>
<style>body{margin:0;font:16px system-ui} input,button,a,video{position:fixed;left:40px;width:240px;height:32px}</style>
<input id=color type=color value="#000000" style="top:40px">
<button id=usb style="top:100px">usb</button>
<button id=share style="top:160px">share</button>
<a id=ext href="%s" style="top:220px">ssh</a>
<button id=webshare style="top:280px">web share</button>
<button id=pip style="top:340px">pip</button>
<button id=docpip style="top:400px">document pip</button>
<video id=video muted playsinline style="top:460px;height:120px"></video>
<script>
window.result = {};
const record = (name, promise) => promise.then(() => { window.result[name] = 'ok'; },
                                                e => { window.result[name] = (e && e.name) || String(e); });
const color = document.getElementById('color');
window.colorInputs = []; window.colorChanges = 0;
color.addEventListener('input', () => window.colorInputs.push(color.value));
color.addEventListener('change', () => { window.colorChanges += 1; });
document.getElementById('usb').onclick = () => record('usb', navigator.usb.requestDevice({filters: []}));
document.getElementById('share').onclick = () => record('share', navigator.mediaDevices.getDisplayMedia({video: true}));
document.getElementById('webshare').onclick = () => record('webshare', navigator.share({title: 'probe', url: location.href}));
const canvas = document.createElement('canvas'); canvas.width = 320; canvas.height = 180;
const ctx = canvas.getContext('2d'); let frame = 0;
setInterval(() => { ctx.fillStyle = frame++ %% 2 ? '#246' : '#642'; ctx.fillRect(0, 0, 320, 180); }, 100);
const video = document.getElementById('video'); video.srcObject = canvas.captureStream(10); video.play();
document.getElementById('pip').onclick = () => record('pip', video.requestPictureInPicture());
document.getElementById('docpip').onclick = () => record('docpip',
  documentPictureInPicture.requestWindow({width: 360, height: 240}).then(w => { window.docPip = w; }));
</script>
""" % EXTERNAL_URL


def choosers(rpc, **params):
    """`debug.cef` `host_choosers` (after the params' action, if any): None while cmux shows none of the host's."""
    return (rpc("debug.cef", params) or {}).get("host_choosers")


def visible_dialog(rpc, identifier):
    return next((d for d in (rpc("debug.dialog") or {}).get("dialogs") or []
                 if d.get("identifier") == identifier and d.get("visible")), None)


def widget(rpc, kind):
    for shown in (rpc("debug.cef") or {}).get("host_widgets") or []:
        frame = shown.get("frame") or [0, 0, 0, 0]
        if shown.get("kind") == kind and shown.get("shown") and frame[2] > 0 and frame[3] > 0:
            return shown
    return None


class Page:
    """The probe tab: clicks by element id and the page's results."""

    def __init__(self, rpc, wait, page_eval):
        self.rpc, self.wait, self.page_eval = rpc, wait, page_eval

    def click(self, element):
        rect = self.page_eval(f"(() => {{ const r = document.getElementById('{element}').getBoundingClientRect(); "
                              f"return [r.x + r.width / 2, r.y + r.height / 2]; }})()") or [0, 0]
        self.rpc("debug.mouse", {"target": "page", "x": rect[0], "y": rect[1]})

    def result(self, name, deadline=5):
        return self.wait(lambda: self.page_eval(f"window.result[{json.dumps(name)}] || null"), deadline)

    def timed(self, check, deadline=SHOW_DEADLINE_S):
        started = time.time()
        shown = self.wait(check, deadline)
        return shown, round((time.time() - started) * 1000, 1) if shown else None


def not_drawn(reason):
    return {"ok": False, "not_run": reason}


def skipped(reason, task):
    """A row another task builds: reported with that task, and neither passed nor failed."""
    return {"skipped": reason, "task": task}


def color_row(page, clear):
    if choosers(page.rpc) is None:
        return not_drawn("no cmux choosers: host mode is not live in this build, chromiumHostChoosers is off, or the "
                         "host's fork is below API 31 (p01-process-178)")
    page.click("color")
    shown, show_ms = page.timed(lambda: (choosers(page.rpc) or {}).get("color_open"))
    row = {"show_ms": show_ms, "host": clear()}
    choosers(page.rpc, color_chooser_pick=0x336699)
    row["live"] = bool(shown) and bool(page.wait(lambda: page.page_eval("window.colorInputs.slice(-1)[0] || ''") == "#336699", 5))
    choosers(page.rpc, color_chooser_close=True)
    row["closed"] = bool(page.wait(lambda: page.page_eval("window.colorChanges") == 1, 5)) and \
        not (choosers(page.rpc) or {}).get("color_open")
    row["ok"] = bool(shown) and row["host"]["clear"] and row["live"] and row["closed"]
    return row


def dialog_row(page, clear, button, identifier, result, expected):
    if choosers(page.rpc) is None:
        return not_drawn("no cmux choosers: host mode is not live in this build or chromiumHostChoosers is off")
    page.click(button)
    shown, show_ms = page.timed(lambda: visible_dialog(page.rpc, identifier))
    row = {"show_ms": show_ms, "host": clear(), "dialog": shown and {k: shown.get(k) for k in ("title", "lines", "buttons")}}
    page.rpc("debug.dialog", {"id": shown.get("id"), "press": "cancel"} if shown else {"dismiss": True})
    row["result"] = page.result(result)
    row["ok"] = bool(shown) and row["host"]["clear"] and row["result"] == expected and not visible_dialog(page.rpc, identifier)
    return row


def external_protocol_row(page, clear):
    if page.rpc("debug.browser.prompts") is None:
        return not_drawn("debug.browser.prompts answers only in a Debug build")
    page.rpc("debug.browser.external_opens", {"clear": True})
    page.click("ext")
    asked = lambda: next((p for p in (page.rpc("debug.browser.prompts") or {}).get("prompts") or []  # noqa: E731
                          if "openExternalApp" in (p.get("kind") or "")), None)
    shown, show_ms = page.timed(asked)
    row = {"show_ms": show_ms, "host": clear()}
    if not shown:
        row.update(ok=False, error="no cmux prompt for ssh:// (no app on this Mac handles it, or the link never left the host)")
        return row
    page.rpc("debug.browser.prompts", {"respond": "allowOnce"})
    opened = page.wait(lambda: EXTERNAL_URL in ((page.rpc("debug.browser.external_opens") or {}).get("urls") or []), 5)
    row["opened"] = bool(opened)
    row["ok"] = row["host"]["clear"] and row["opened"]
    return row


def web_share_row(page, clear):
    return skipped("fork API 31 has no Web Share handler (p01-process-227 added none): the host cannot hand "
                   "navigator.share's data to cmux's NSSharingServicePicker, so Chromium's own picker would open in it",
                   WEB_SHARE_TASK)


def pip_row(page, clear, button, kind, exit_script):
    if (page.rpc("debug.cef") or {}).get("host_widgets") is None:
        return not_drawn("no widget host: host mode is not live in this build or chromiumHostWidgets is off")
    page.click(button)
    shown, show_ms = page.timed(lambda: widget(page.rpc, kind))
    row = {"show_ms": show_ms, "host": clear(), "widget": shown}
    page.page_eval(exit_script)
    row["closed"] = bool(page.wait(lambda: widget(page.rpc, kind) is None, 5))
    row["ok"] = bool(shown) and row["host"]["clear"] and row["closed"]
    return row


RUNNERS = {
    "color": color_row,
    "device_chooser": lambda page, clear: dialog_row(page, clear, "usb", DEVICE_DIALOG, "usb", "NotFoundError"),
    "screen_share": lambda page, clear: dialog_row(page, clear, "share", SHARE_DIALOG, "share", "NotAllowedError"),
    "external_protocol": external_protocol_row,
    "web_share": web_share_row,
    "video_pip": lambda page, clear: pip_row(page, clear, "pip", "video_pip",
                                             "(() => { document.exitPictureInPicture(); return true; })()"),
    "document_pip": lambda page, clear: pip_row(page, clear, "docpip", "document_pip",
                                                "(() => { window.docPip && window.docPip.close(); return true; })()"),
}


def run(rpc, wait, page_eval, url, host_pid, front, windows, rows_to_run=ROWS, on_row=lambda name, row: row):
    """The rows of `rows_to_run`, in ROWS order, on the probe page at `url` (PAGE). `host_pid`, `front` and `windows`
    are chromium-host-bench.py's (chromium_host_native_ui_dialogs.run). `on_row(name, row)` runs right after each row
    and returns the row to keep. Returns (rows, ok); a not_run row is not ok, a skipped row (another task's) counts
    neither way."""
    rows = {}
    wanted = [name for name in ROWS if name in rows_to_run]
    if not wanted:
        return rows, True
    clear = lambda: dialogs.host_ui_clear(host_pid, front, windows)  # noqa: E731
    if not dialogs.open_page(rpc, wait, page_eval, url, "chooser probe"):
        return {name: {"ok": False, "error": "the chooser probe never loaded"} for name in wanted}, False
    page = Page(rpc, wait, page_eval)
    for name in wanted:
        try:
            rows[name] = RUNNERS[name](page, clear)
        except Exception as error:  # noqa: BLE001 - a row's failure is that row's result
            rows[name] = {"ok": False, "error": f"{type(error).__name__}: {error}"[:300]}
        rows[name] = on_row(name, rows[name])
    return rows, all(row.get("ok") for row in rows.values() if "skipped" not in row)


if __name__ == "__main__":
    print(json.dumps({"rows": ROWS, "features": FEATURES}))

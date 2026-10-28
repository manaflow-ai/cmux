#!/usr/bin/env python3
"""chromium_host_native_ui_choosers.py, the chooser and picture-in-picture rows of chromium-host-bench.py --native-ui
(p01-process-228), against a fake app: the color panel's live pick and close, the device chooser's and screen-share
picker's Cancel, the external protocol prompt's Open once, both picture-in-picture widgets, and Web Share as not run.
A correct app passes those rows; an app with no cmux choosers, a pick that never reaches the page, a host that shows a
window or a chooser that never shows each fail the row they break. Runs anywhere (no app).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_native_ui_choosers.py"""
import os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_native_ui_choosers as choosers  # noqa: E402

APP_PID, HOST_PID = 100, 200


class FakeApp:
    """The app as the rows see it. `drawn` False: cmux shows no host chooser (host_choosers null); `drops_pick`: a
    pick never reaches the page; `host_window`: the host shows a window; `no_dialogs`: a click opens no chooser."""

    def __init__(self, drawn=True, drops_pick=False, host_window=False, no_dialogs=False):
        self.drawn, self.drops_pick, self.host_window, self.no_dialogs = drawn, drops_pick, host_window, no_dialogs
        self.title = ""
        self.color_open = False
        self.color_inputs, self.color_changes = [], 0
        self.dialog = None
        self.result = {}
        self.prompts, self.opened = [], []
        self.widgets = []

    def front(self):
        return APP_PID

    def windows(self, pid):
        return [{"alpha": 1.0}] if pid == HOST_PID and self.host_window else []

    def page_eval(self, script):
        if script == "document.title":
            return self.title
        if "getBoundingClientRect" in script:
            self.last_click = script.split("getElementById('")[1].split("'")[0]
            return [100, 50]
        if script.startswith("window.colorInputs"):
            return self.color_inputs[-1] if self.color_inputs else ""
        if script == "window.colorChanges":
            return self.color_changes
        if script.startswith("window.result["):
            return self.result.get(script.split('"')[1])
        if "exitPictureInPicture" in script or "docPip" in script:
            self.widgets = []
            return True
        return None

    def rpc(self, method, params=None, timeout=30):
        params = params or {}
        if method == "action.run":
            self.title = "chooser probe"
            return {}
        if method == "debug.mouse":
            self.click(self.last_click)
            return {}
        if method == "debug.cef":
            if "color_chooser_pick" in params and self.color_open and not self.drops_pick:
                self.color_inputs.append("#%06x" % params["color_chooser_pick"])
            if params.get("color_chooser_close") and self.color_open:
                self.color_open, self.color_changes = False, self.color_changes + 1
            report = {"color_open": self.color_open, "device_choosers": 0, "screen_shares": 0, "answers": 0}
            return {"host_choosers": report if self.drawn else None, "host_widgets": self.widgets}
        if method == "debug.dialog":
            if params.get("press") == "cancel" and self.dialog:
                self.result[{choosers.DEVICE_DIALOG: "usb", choosers.SHARE_DIALOG: "share"}[self.dialog]] = \
                    {choosers.DEVICE_DIALOG: "NotFoundError", choosers.SHARE_DIALOG: "NotAllowedError"}[self.dialog]
                self.dialog = None
            dialogs = [{"id": 1, "identifier": self.dialog, "visible": True, "title": "t"}] if self.dialog else []
            return {"dialogs": dialogs}
        if method == "debug.browser.prompts":
            if params.get("respond") == "allowOnce" and self.prompts:
                self.prompts, self.opened = [], self.opened + [choosers.EXTERNAL_URL]
            return {"prompts": self.prompts}
        if method == "debug.browser.external_opens":
            urls = list(self.opened)
            if params.get("clear"):
                self.opened = []
            return {"urls": urls}
        return {}

    def click(self, element):
        if self.no_dialogs:
            return
        if element == "color" and self.drawn:
            self.color_open = True
        elif element == "usb" and self.drawn:
            self.dialog = choosers.DEVICE_DIALOG
        elif element == "share" and self.drawn:
            self.dialog = choosers.SHARE_DIALOG
        elif element == "ext":
            self.prompts = [{"kind": "openExternalApp(app: \"Terminal\", scheme: \"ssh\")", "origin": ""}]
        elif element == "pip":
            self.widgets = [{"kind": "video_pip", "shown": True, "frame": [0, 0, 320, 180]}]
        elif element == "docpip":
            self.widgets = [{"kind": "document_pip", "shown": True, "frame": [0, 0, 360, 240]}]


def instant_wait(check, seconds, step=0.1):
    for _ in range(3):
        value = check()
        if value:
            return value
    return None


ALL_BUT_SHARE = tuple(row for row in choosers.ROWS if row != "web_share")


def run(app, rows=ALL_BUT_SHARE):
    return choosers.run(app.rpc, instant_wait, app.page_eval, "file:///probe.html", lambda: HOST_PID, app.front,
                        app.windows, rows_to_run=rows)


class ChooserRowsTests(unittest.TestCase):
    def test_a_correct_app_passes_each_row(self):
        rows, ok = run(FakeApp())
        self.assertTrue(ok, rows)
        self.assertEqual(set(rows), set(ALL_BUT_SHARE))
        self.assertTrue(rows["color"]["live"] and rows["color"]["closed"])
        self.assertEqual(rows["device_chooser"]["result"], "NotFoundError")
        self.assertEqual(rows["screen_share"]["result"], "NotAllowedError")
        self.assertTrue(rows["external_protocol"]["opened"])
        self.assertEqual(rows["video_pip"]["widget"]["kind"], "video_pip")

    def test_web_share_is_skipped_with_its_task(self):
        rows, ok = run(FakeApp(), rows=("web_share",))
        self.assertTrue(ok, "a skipped row does not fail the run")
        self.assertIn("skipped", rows["web_share"])
        self.assertEqual(rows["web_share"]["task"], choosers.WEB_SHARE_TASK)
        self.assertNotIn("ok", rows["web_share"])

    def test_the_full_run_passes_with_web_share_skipped(self):
        rows, ok = run(FakeApp(), rows=choosers.ROWS)
        self.assertTrue(ok, rows)
        self.assertEqual(set(rows), set(choosers.ROWS))

    def test_a_failed_row_still_fails_the_run_beside_a_skipped_one(self):
        rows, ok = run(FakeApp(drops_pick=True), rows=("color", "web_share"))
        self.assertFalse(ok)
        self.assertFalse(rows["color"]["ok"])

    def test_no_cmux_choosers_fails_their_rows_as_not_run(self):
        rows, ok = run(FakeApp(drawn=False), rows=("color", "device_chooser", "screen_share"))
        self.assertFalse(ok)
        for name in ("color", "device_chooser", "screen_share"):
            self.assertIn("not_run", rows[name], name)

    def test_a_pick_that_never_reaches_the_page_fails_the_color_row(self):
        rows, ok = run(FakeApp(drops_pick=True), rows=("color",))
        self.assertFalse(ok)
        self.assertFalse(rows["color"]["live"])

    def test_a_host_window_fails_every_row(self):
        rows, ok = run(FakeApp(host_window=True))
        self.assertFalse(ok)
        for name, row in rows.items():
            self.assertFalse(row["host"]["clear"], name)
            self.assertFalse(row["ok"], name)

    def test_a_chooser_that_never_shows_fails_its_row(self):
        rows, ok = run(FakeApp(no_dialogs=True))
        self.assertFalse(ok)
        for name, row in rows.items():
            self.assertFalse(row["ok"], name)

    def test_the_probe_page_names_its_external_url(self):
        self.assertIn(choosers.EXTERNAL_URL, choosers.PAGE)
        self.assertNotIn("%%", choosers.PAGE)


if __name__ == "__main__":
    unittest.main()

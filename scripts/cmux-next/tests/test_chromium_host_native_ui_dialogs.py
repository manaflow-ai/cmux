#!/usr/bin/env python3
"""chromium_host_native_ui_dialogs.py, the page dialog rows of chromium-host-bench.py --native-ui (p01-process-064,
065), against a fake app: the file picker's choice and cancel, the beforeunload question's Cancel and Leave, the hang
card's Wait and Exit page, File > Print (the print row) and the page's own window.print() (the print_page row)
through cmux's print panel, and the host check (never frontmost, no visible window). A correct app passes those rows;
an app with no cmux picker, one whose picker loses the chosen path, a host that shows a window or comes to the front, a
close that does not ask, a page whose window.print() never reaches cmux (Chromium's preview in the host) and one whose
window.print() returns before its panel ended each fail the row they break; a host without the fork's page-print hook
leaves the print_page row not run, owned by p01-process-242, and the print row passes. Runs anywhere (no app, no openssl needed: the
certificate row is covered by the live bench only).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_native_ui_dialogs.py"""
import os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_native_ui_dialogs as dialogs  # noqa: E402

APP_PID, HOST_PID = 100, 200


class FakeApp:
    """The app as the rows see it. `picker` False: no cmux picker (host_file_dialogs null); `drops_path`: a choice
    reaches the page with no file; `host_window`: the host shows a window; `host_front`: the host is frontmost;
    `closes_at_once`: a person's close closes the tab with no question; `panel` False: no cmux print panel
    (host_print null); `page_preview`: the page's window.print() opens Chromium's preview in the host, never cmux's
    panel; `page_returns_early`: it reaches cmux's panel but returns at once, before the panel ends; `page_hook` False:
    the host's fork has no page-print hook (host_print's page_hook)."""

    def __init__(self, picker=True, drops_path=False, host_window=False, host_front=False, closes_at_once=False,
                 panel=True, page_preview=False, page_returns_early=False, page_hook=True):
        self.picker, self.drops_path, self.closes_at_once = picker, drops_path, closes_at_once
        self.panel, self.page_preview, self.page_returns_early = panel, page_preview, page_returns_early
        self.prints = {"asked": 0, "printed": 0, "shown": 0, "failed": 0, "showing": False, "page_asked": 0,
                       "page_ended": 0, "page_hook": page_hook}
        self.page_waiting = False
        self.host_window, self.host_front = host_window, host_front
        self.title, self.page = "", None
        self.asked = self.answered = self.waiting = 0
        self.chosen, self.cancels = [], 0
        self.tabs, self.focused, self.question = set(), None, False
        self.unresponsive = self.gone = False
        self.reads_to_hang = 0

    # The bench's seams.
    def front(self):
        return HOST_PID if self.host_front else APP_PID

    def windows(self, pid):
        return [{"alpha": 1.0, "layer": 0}] if pid == HOST_PID and self.host_window else []

    def page_eval(self, script):
        if script == "document.title":
            return self.title
        if "getBoundingClientRect" in script:
            return [160, 56]
        if script == "window.chosen.join('|')":
            return "|".join(self.chosen)
        if script == "window.cancels":
            return self.cancels
        return None

    def rpc(self, method, params=None, timeout=30):
        params = params or {}
        if method == "action.run" and params.get("action") == "openBrowser.chromium":
            self.page = params["args"]["url"]
            tab = f"tab{len(self.tabs)}"
            self.tabs.add(tab)
            self.focused = tab
            self.title = {"native-ui-file.html": "file probe", "native-ui-unload.html": "unload probe",
                          "native-ui-hang.html": "hang probe",
                          "native-ui-print.html": "print probe"}.get(os.path.basename(self.page), "")
            return {"created": [tab]}
        if method == "debug.cef":
            if "file_dialog_choose" in params and self.waiting:
                self.waiting, self.answered = 0, self.answered + 1
                if not self.drops_path:
                    self.chosen = [os.path.basename(p) for p in params["file_dialog_choose"]]
            if params.get("file_dialog_cancel") and self.waiting:
                self.waiting, self.answered, self.cancels = 0, self.answered + 1, self.cancels + 1
            if params.get("print_cancel") and self.prints["showing"]:
                self.prints["showing"] = False
                if self.page_waiting:
                    self.end_page_print()
            report = {"asked": self.asked, "answered": self.answered, "waiting": self.waiting} if self.picker else None
            return {"host_file_dialogs": report, "host_print": dict(self.prints) if self.panel else None}
        if method == "action.run" and params.get("action") == "browserPrint" and self.panel:
            self.show_panel()
            return {}
        if method == "debug.mouse":
            if self.title == "file probe" and self.picker:
                self.asked, self.waiting = self.asked + 1, 1
            elif self.title == "unload probe":
                self.title = "unload armed"
            elif self.title == "hang probe":
                self.unresponsive = True
            elif self.title == "print probe" and self.page_preview:
                self.host_window = True
            elif self.title == "print probe" and self.panel:
                self.prints["page_asked"] += 1
                self.page_waiting = True
                self.show_panel()
                if self.page_returns_early:
                    self.end_page_print()
            return {"delivered": 2}
        if method == "debug.focus":
            return {"windows": [{"model": {"resolved_tab": self.focused},
                                 "topology": [{"tabs": [f"{t}:browser" for t in sorted(self.tabs)]}]}]}
        if method == "debug.key" and params.get("key") == "w":
            if self.closes_at_once:
                self.tabs.discard(self.focused)
            else:
                self.question = True
            return {}
        if method == "debug.dialog":
            if params.get("press") == "cancel":
                self.question = False
            elif params.get("press") == "ok" and self.question:
                self.question = False
                self.tabs.discard(self.focused)
            return {"dialogs": [{"identifier": dialogs.QUESTION, "visible": True}] if self.question else []}
        if method == "debug.browser.page_status":
            press = params.get("press")
            pressed = False
            if press == "wait" and self.unresponsive:
                self.unresponsive, pressed, self.reads_to_hang = False, True, 2
            elif press == "exit" and self.unresponsive:
                self.unresponsive, self.gone, pressed = False, True, True
            elif self.title == "hang probe" and not self.gone and not self.unresponsive:
                # The page still hangs: Chromium asks again after its timer ran once more.
                self.reads_to_hang -= 1
                self.unresponsive = self.reads_to_hang <= 0
            return {"gone": "1" if self.gone else "0", "unresponsive": "1" if self.unresponsive else "0",
                    "pressed": "1" if pressed else "0", "enginePage": "0", "certificate": "0", "title": self.title}
        return {}

    def show_panel(self):
        for key in ("asked", "printed", "shown"):
            self.prints[key] += 1
        self.prints["showing"] = True

    def end_page_print(self):
        self.page_waiting = False
        self.prints["page_ended"] += 1
        self.title = "print returned"


def instant_wait(check, seconds, step=0.1):
    for _ in range(3):
        value = check()
        if value:
            return value
    return None


def run(app, rows=("file_picker", "beforeunload", "unresponsive")):
    with tempfile.TemporaryDirectory() as out:
        return dialogs.run(app.rpc, instant_wait, app.page_eval, out, lambda: HOST_PID, app.front, app.windows,
                           rows_to_run=rows)


class DialogRowsTests(unittest.TestCase):
    def setUp(self):
        self.sleep = dialogs.time.sleep
        dialogs.time.sleep = lambda seconds: None

    def tearDown(self):
        dialogs.time.sleep = self.sleep

    def test_a_correct_app_passes_each_row(self):
        rows, ok = run(FakeApp())
        self.assertTrue(ok, rows)
        self.assertEqual(set(rows), {"file_picker", "beforeunload", "unresponsive"})
        self.assertTrue(rows["file_picker"]["chose"] and rows["file_picker"]["cancelled"])

    def test_no_cmux_picker_fails_the_file_row_as_not_run(self):
        rows, ok = run(FakeApp(picker=False), rows=("file_picker",))
        self.assertFalse(ok)
        self.assertIn("not_run", rows["file_picker"])

    def test_a_lost_path_fails_the_file_row(self):
        rows, ok = run(FakeApp(drops_path=True), rows=("file_picker",))
        self.assertFalse(ok)
        self.assertFalse(rows["file_picker"]["chose"])

    def test_a_host_window_or_a_frontmost_host_fails_every_row(self):
        for app in (FakeApp(host_window=True), FakeApp(host_front=True)):
            rows, ok = run(app)
            self.assertFalse(ok)
            for name, row in rows.items():
                self.assertFalse(row["host"]["clear"], name)
                self.assertFalse(row["ok"], name)

    def test_a_close_that_never_asks_fails_the_beforeunload_row(self):
        rows, ok = run(FakeApp(closes_at_once=True), rows=("beforeunload",))
        self.assertFalse(ok)
        self.assertFalse(rows["beforeunload"]["asked"])

    def test_host_ui_clear_needs_a_readable_window_list_and_a_host(self):
        self.assertFalse(dialogs.host_ui_clear(lambda: None, lambda: APP_PID, lambda pid: [])["clear"])
        self.assertFalse(dialogs.host_ui_clear(lambda: HOST_PID, lambda: APP_PID, lambda pid: None)["clear"])
        hidden = [{"alpha": 0.0}]
        self.assertTrue(dialogs.host_ui_clear(lambda: HOST_PID, lambda: APP_PID, lambda pid: hidden)["clear"])

    def test_both_prints_go_through_cmuxs_panel(self):
        rows, ok = run(FakeApp(), rows=("print", "print_page"))
        self.assertTrue(ok, rows)
        self.assertTrue(rows["print"]["ok"] and rows["print_page"]["returned"], rows)

    def test_no_print_panel_fails_both_print_rows_as_not_run(self):
        rows, ok = run(FakeApp(panel=False), rows=("print", "print_page"))
        self.assertFalse(ok)
        self.assertIn("not_run", rows["print"])
        self.assertIn("not_run", rows["print_page"])

    def test_a_host_without_the_page_print_hook_leaves_the_page_row_to_its_fork_task(self):
        rows, ok = run(FakeApp(page_hook=False, page_preview=True), rows=("print", "print_page"))
        self.assertFalse(ok)
        self.assertTrue(rows["print"]["ok"], rows)
        self.assertIn("not_run", rows["print_page"])
        self.assertEqual(rows["print_page"]["owner"], "p01-process-242")

    def test_a_window_print_that_opens_chromiums_preview_fails_the_page_row(self):
        rows, ok = run(FakeApp(page_preview=True), rows=("print", "print_page"))
        self.assertFalse(ok)
        self.assertTrue(rows["print"]["ok"], rows)
        self.assertIsNone(rows["print_page"]["show_ms"])
        self.assertFalse(rows["print_page"]["host"]["clear"])

    def test_a_window_print_that_returns_before_its_panel_ends_fails_the_page_row(self):
        rows, ok = run(FakeApp(page_returns_early=True), rows=("print_page",))
        self.assertFalse(ok)
        self.assertEqual(rows["print_page"]["ended_while_showing"], 1)
        self.assertFalse(rows["print_page"]["returned"])

    def test_a_row_that_raises_is_that_rows_failure(self):
        app = FakeApp()

        def broken(*args, **kwargs):
            raise RuntimeError("socket gone")
        app.rpc = broken
        rows, ok = run(app, rows=("beforeunload",))
        self.assertFalse(ok)
        self.assertIn("socket gone", rows["beforeunload"]["error"])


if __name__ == "__main__":
    unittest.main()

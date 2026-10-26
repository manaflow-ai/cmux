#!/usr/bin/env python3
"""chromium_host_native_ui.py, the --native-ui rows of chromium-host-bench.py, against a fake app: the select row
(p01-process-060) passes when a click on the <select> opens a cmux menu with its options while cmux is frontmost, a
choice through `debug.menu` changes the page once and a dismissal not at all; it fails when the host shows the menu
(frontmost), when no cmux menu opens (Chromium's own menu in the host), when a dismissal changes the value, and
without cmux popup menus. `--native-ui select` runs that row alone. Runs anywhere (no app).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_native_ui.py"""
import os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_native_ui as native  # noqa: E402

APP_PID, HOST_PID = 100, 200


class FakeApp:
    """The app as the select row sees it. `menus` off: no cmux popup menus (`debug.cef`); `host_menu`: the host
    shows Chromium's own menu (it is frontmost, `debug.menu` sees nothing); `dismiss_chooses`: a dismissal sends a
    change as a choice of the first other option would."""

    def __init__(self, menus=True, host_menu=False, dismiss_chooses=False):
        self.menus, self.host_menu, self.dismiss_chooses = menus, host_menu, dismiss_chooses
        self.open = False
        self.value, self.changes = "alpha", 0
        self.methods = []

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        self.methods.append(method)
        if method == "action.run":
            return {"ok": True}
        if method == "debug.cef":
            return {"host_popup_menus": self.menus, "host_widgets": None}
        if method == "debug.mouse":
            self.open = True
            return {"ok": True}
        if method == "debug.menu":
            if not self.open or self.host_menu:
                return {"open": False}
            reply = {"open": True, "items": list(native.SELECT_OPTIONS)}
            if params.get("choose"):
                self.choose(params["choose"])
                self.open = False
            elif params.get("dismiss"):
                if self.dismiss_chooses:
                    self.choose("charlie")
                self.open = False
            return reply
        raise AssertionError(f"unexpected method {method}")

    def choose(self, value):
        if value != self.value:
            self.value, self.changes = value, self.changes + 1

    def front(self):
        return HOST_PID if self.open and self.host_menu else APP_PID

    def page_eval(self, script):
        if "readyState" in script:
            return True
        if "getBoundingClientRect" in script:
            return [160, 236]
        if "selectChanges = 0" in script:
            self.value, self.changes = "alpha", 0
            return True
        if "selectChanges ===" in script:
            return self.value == "bravo" and self.changes == 1
        raise AssertionError(f"unexpected script {script}")


def instant(check, seconds, step=0.1):
    """The bench's wait() for a fake app that changes only on calls: one read."""
    return check() or None


def run(app, rows=("select",)):
    return native.run(app.rpc, instant, app.page_eval, "file:///native-ui.html", rows_to_run=list(rows), front=app.front,
                      app_pid=APP_PID)


class SelectRowTest(unittest.TestCase):
    def test_a_cmux_menu_passes(self):
        app = FakeApp()
        rows, ok = run(app)
        self.assertTrue(ok, rows)
        row = rows["select"]
        self.assertEqual(row["items"], native.SELECT_OPTIONS)
        self.assertTrue(row["host_never_front"] and row["chose"] and row["dismissed"])
        self.assertEqual(app.value, "bravo")
        self.assertEqual(app.changes, 1)

    def test_the_hosts_own_menu_fails(self):
        rows, ok = run(FakeApp(host_menu=True))
        self.assertFalse(ok)
        self.assertIn("error", rows["select"])

    def test_a_host_that_is_frontmost_fails(self):
        app = FakeApp()
        app.front = lambda: HOST_PID
        rows, ok = run(app)
        self.assertFalse(ok)
        self.assertFalse(rows["select"]["host_never_front"])
        self.assertEqual(rows["select"]["front_pid"], HOST_PID)

    def test_a_dismissal_that_changes_the_value_fails(self):
        rows, ok = run(FakeApp(dismiss_chooses=True))
        self.assertFalse(ok)
        self.assertTrue(rows["select"]["chose"])
        self.assertFalse(rows["select"]["dismissed"])

    def test_without_cmux_popup_menus_the_row_does_not_run(self):
        app = FakeApp(menus=False)
        rows, ok = run(app)
        self.assertFalse(ok)
        self.assertIn("not_run", rows["select"])
        self.assertNotIn("debug.mouse", app.methods)

    def test_the_select_row_alone_runs_no_widget_row(self):
        rows, _ = run(FakeApp())
        self.assertEqual(list(rows), ["select"])

    def test_widget_rows_without_a_widget_host_do_not_run(self):
        rows, ok = run(FakeApp(), rows=native.ROWS)
        self.assertFalse(ok)
        self.assertEqual(list(rows), list(native.ROWS))
        self.assertTrue(rows["select"]["ok"])
        self.assertTrue(all("not_run" in rows[name] for name in native.ROWS if name != "select"))


class RowsNamedTest(unittest.TestCase):
    def test_names_pick_rows_in_order(self):
        self.assertEqual(native.rows_named(""), list(native.ROWS))
        self.assertEqual(native.rows_named("select"), ["select"])
        self.assertEqual(native.rows_named("date, select"), ["select", "date"])

    def test_an_unknown_row_is_refused(self):
        with self.assertRaises(ValueError):
            native.rows_named("select,combobox")

    def test_the_probe_page_has_the_select(self):
        self.assertIn("<select id=sel", native.PAGE)
        for option in native.SELECT_OPTIONS:
            self.assertIn(f"<option>{option}", native.PAGE)
        self.assertIn("chromiumHostPopupMenus", native.launch_env([])["CMUX_ENABLE_FEATURES"])


if __name__ == "__main__":
    unittest.main()

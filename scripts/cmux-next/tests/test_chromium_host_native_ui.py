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


class FakeHostApp:
    """The app as the context_menu and download rows see it (task 069), in host mode unless `backend` says otherwise.
    `menu_rows`: the page menu's titles (Chromium's arrive only when CONTEXT_MENU's items do); `stuck`: a dismissed
    menu never reaches Chromium (context_menu_done lost), so no next menu opens; `dismiss_runs`: a dismissal runs a
    command (the page reloads); `download_status` and `download_bytes`: how the link's download ends."""

    def __init__(self, tmp, backend="host", menu_rows=("Back", "Forward", "Reload", "-", "Inspect"), stuck=False,
                 dismiss_runs=False, download_status="finished", download_bytes=native.DOWNLOAD_BYTES):
        self.tmp, self.backend, self.menu_rows, self.stuck = tmp, backend, list(menu_rows), stuck
        self.dismiss_runs, self.download_status, self.download_bytes = dismiss_runs, download_status, download_bytes
        self.open, self.waiting_done = False, False
        self.marker, self.reloads = False, 0
        self.downloads = [{"id": "old", "filename": "older.zip", "status": "finished"}]
        self.right_clicks, self.methods = 0, []

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        self.methods.append(method)
        if method == "action.run":
            return {"ok": True}
        if method == "debug.cef":
            return {"backend": self.backend, "host_popup_menus": True, "host_widgets": None}
        if method == "debug.mouse":
            self.download()
            return {"ok": True}
        if method == "debug.downloads":
            return {"downloads": list(self.downloads)}
        if method == "debug.menu":
            if not self.open:
                return {"open": False}
            reply = {"open": True, "items": list(self.menu_rows)}
            if params.get("choose"):
                if params["choose"] == "Reload":
                    self.reload()
                self.open, self.waiting_done = False, False
            elif params.get("dismiss"):
                if self.dismiss_runs:
                    self.reload()
                self.open, self.waiting_done = False, self.stuck
            return reply
        raise AssertionError(f"unexpected method {method}")

    def right_click(self):
        self.right_clicks += 1
        # Chromium shows no next menu until the last one was ended.
        if not self.waiting_done:
            self.open = True
        return True

    def reload(self):
        self.marker, self.reloads = False, self.reloads + 1

    def download(self):
        path = os.path.join(self.tmp, native.DOWNLOAD_NAME + ".txt")
        with open(path, "wb") as f:
            f.write(self.download_bytes)
        self.downloads.append({"id": "new", "filename": native.DOWNLOAD_NAME + ".txt", "status": self.download_status,
                               "destination": path})

    def front(self):
        return APP_PID

    def page_eval(self, script):
        if script == native.PROBE_LOADED or "getBoundingClientRect" in script:
            return True if "readyState" in script else [60, 290]
        if script == native.SET_MARKER:
            self.marker = True
            return True
        if script == native.RELOADED:
            return not self.marker and self.reloads > 0
        if script == native.MARKER_STAYS:
            return self.marker
        raise AssertionError(f"unexpected script {script}")


class HostRowsTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp(prefix="native-ui-069-")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_rows(self, app, rows=("context_menu", "download")):
        return native.run(app.rpc, instant, app.page_eval, "file:///native-ui.html", rows_to_run=list(rows),
                          front=app.front, app_pid=APP_PID, right_click=app.right_click)

    def test_the_page_menu_and_a_download_pass_in_host_mode(self):
        app = FakeHostApp(self.tmp)
        rows, ok = self.run_rows(app)
        self.assertTrue(ok, rows)
        menu = rows["context_menu"]
        self.assertTrue(menu["chose"] and menu["dismissed"] and menu["reopened"] and menu["host_never_front"])
        self.assertEqual(app.reloads, 1)
        self.assertTrue(rows["download"]["bytes_ok"])
        self.assertFalse(os.path.exists(os.path.join(self.tmp, native.DOWNLOAD_NAME + ".txt")), "the row left the file")

    def test_a_menu_without_chromiums_rows_fails(self):
        rows, ok = self.run_rows(FakeHostApp(self.tmp, menu_rows=("Open Link in New Tab",)), rows=("context_menu",))
        self.assertFalse(ok)
        self.assertIn("error", rows["context_menu"])

    def test_a_dismissal_chromium_never_hears_fails(self):
        rows, ok = self.run_rows(FakeHostApp(self.tmp, stuck=True), rows=("context_menu",))
        self.assertFalse(ok)
        self.assertTrue(rows["context_menu"]["dismissed"])
        self.assertFalse(rows["context_menu"]["reopened"])

    def test_a_dismissal_that_runs_a_command_fails(self):
        rows, ok = self.run_rows(FakeHostApp(self.tmp, dismiss_runs=True), rows=("context_menu",))
        self.assertFalse(ok)
        self.assertFalse(rows["context_menu"]["dismissed"])

    def test_a_failed_or_wrong_download_fails(self):
        rows, ok = self.run_rows(FakeHostApp(self.tmp, download_status="failed"), rows=("download",))
        self.assertFalse(ok)
        rows, ok = self.run_rows(FakeHostApp(self.tmp, download_bytes=b"other"), rows=("download",))
        self.assertFalse(ok)
        self.assertFalse(rows["download"]["bytes_ok"])

    def test_every_row_goes_through_on_row_in_order(self):
        app = FakeHostApp(self.tmp)
        seen = []

        def on_row(name, row):
            seen.append(name)
            return {**row, "seen": True}
        names = ("context_menu", "download", "date", "autofill")
        rows, ok = native.run(app.rpc, instant, app.page_eval, "file:///native-ui.html", rows_to_run=list(names),
                              front=app.front, app_pid=APP_PID, right_click=app.right_click, on_row=on_row)
        self.assertEqual(seen, list(names), "each row once, in ROWS order, the 069 rows with their own runners")
        self.assertEqual(list(rows), list(names))
        self.assertTrue(all(row["seen"] for row in rows.values()))
        self.assertTrue(rows["context_menu"]["ok"] and rows["download"]["ok"], rows)
        self.assertIn("not_run", rows["date"], "no widget host")
        self.assertFalse(ok)

    def test_without_host_mode_the_rows_do_not_run(self):
        app = FakeHostApp(self.tmp, backend="inProcess")
        rows, ok = self.run_rows(app)
        self.assertFalse(ok)
        self.assertIn("not_run", rows["context_menu"])
        self.assertIn("not_run", rows["download"])
        self.assertEqual(app.right_clicks, 0)
        self.assertNotIn("debug.mouse", app.methods)


class RowsNamedTest(unittest.TestCase):
    def test_names_pick_rows_in_order(self):
        self.assertEqual(native.rows_named(""), list(native.ROWS))
        self.assertEqual(native.rows_named("select"), ["select"])
        self.assertEqual(native.rows_named("date, select"), ["select", "date"])
        self.assertEqual(native.rows_named("download,context_menu"), ["context_menu", "download"])

    def test_an_unknown_row_is_refused(self):
        with self.assertRaises(ValueError):
            native.rows_named("select,combobox")

    def test_the_probe_page_has_the_select(self):
        self.assertIn("<select id=sel", native.PAGE)
        for option in native.SELECT_OPTIONS:
            self.assertIn(f"<option>{option}", native.PAGE)
        self.assertIn("chromiumHostPopupMenus", native.launch_env([])["CMUX_ENABLE_FEATURES"])
        self.assertIn(f'download="{native.DOWNLOAD_NAME}.txt"', native.PAGE)
        self.assertIn(f"data:text/plain;charset=utf-8,{native.DOWNLOAD_BYTES.decode()}", native.PAGE)


if __name__ == "__main__":
    unittest.main()

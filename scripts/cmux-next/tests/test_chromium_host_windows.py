#!/usr/bin/env python3
"""chromium_host_windows.py and chromium-host-bench.py --native-ui --list-failing (p01-process-068), with no app: the
host's BLOCKED_WIDGET and UNEXPECTED_WINDOW lines (host_blocked_widgets.h's format) are parsed out of app log lines,
counted per row by Views class and owner, and a row fails on any unexpected window or a blocked widget whose last line
is not a dismissal (refused, close-failed), owned by a cmux UI or not, or that was held (a permission prompt), and on
any host window the window server shows. Through the bench: the page rows (the 069 context_menu and download rows with
them, given a right click) share one probe tab, each row gets only the lines written while it ran and the host's
visible windows at its end, a window no line names still fails its row, a late line still fails the whole run, a probe
that never loads fails each of its rows by name, and --list-failing names each failing row.
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_windows.py"""
import contextlib, importlib.util, io, os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_native_ui  # noqa: E402
import chromium_host_native_ui_choosers  # noqa: E402
import chromium_host_native_ui_dialogs  # noqa: E402
import chromium_host_windows as windows  # noqa: E402

# The modules are shared by every load of the bench: each test patches their run and tearDown puts these back.
REAL_RUNS = (chromium_host_native_ui.run, chromium_host_native_ui_dialogs.run, chromium_host_native_ui_choosers.run)

PREFIX = "[12:00:01.5] cmux-chromium-host: "
DISMISSED = (PREFIX + "BLOCKED_WIDGET browser=7 widget=11 kind=0 class=JavaScriptTabModalDialogViewViews "
             "rect=10,20,300,120 visible=1 owner=js-dialog action=dismissed")
POPUP = PREFIX + "BLOCKED_WIDGET browser=7 widget=12 kind=3 class=- rect=0,0,10,10 visible=1 owner=none action=dismissed"
REFUSED = PREFIX + "BLOCKED_WIDGET browser=0 widget=13 kind=0 class=Odd rect=0,0,1,1 visible=1 owner=none action=refused"
OWNED_REFUSED = (PREFIX + "BLOCKED_WIDGET browser=7 widget=14 kind=0 class=PermissionPromptBubbleOneOriginView "
                 "rect=0,0,1,1 visible=1 owner=permission-prompt action=refused")
CLOSE_FAILED = (PREFIX + "BLOCKED_WIDGET browser=7 widget=16 kind=0 class=FindBarView rect=0,0,1,1 visible=1 "
                "owner=find action=close-failed")
WINDOW = PREFIX + "UNEXPECTED_WINDOW class=NSPanel title=1a2b3c4d action=ordered-out"
HELD = (PREFIX + "BLOCKED_WIDGET browser=7 widget=17 kind=0 class=PermissionPromptBubbleOneOriginView "
        "rect=0,0,1,1 visible=1 owner=permission-prompt action=held")
HELD_GONE = HELD.replace("action=held", "action=gone")
ON_SCREEN = {"layer": 0, "alpha": 1.0, "bounds": [10, 10, 300, 200]}


def load_bench():
    spec = importlib.util.spec_from_file_location("chromium_host_bench", os.path.join(HERE, "..", "chromium-host-bench.py"))
    bench = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bench)
    return bench


class ParseTests(unittest.TestCase):
    def test_lines(self):
        self.assertEqual(windows.parse(DISMISSED), {
            "what": "BLOCKED_WIDGET", "browser": "7", "widget": "11", "kind": "0",
            "class": "JavaScriptTabModalDialogViewViews", "rect": "10,20,300,120", "visible": "1",
            "owner": "js-dialog", "action": "dismissed"})
        self.assertEqual(windows.parse(WINDOW),
                         {"what": "UNEXPECTED_WINDOW", "class": "NSPanel", "title": "1a2b3c4d", "action": "ordered-out"})
        self.assertIsNone(windows.parse(PREFIX + "a window became key: NSWindow"))
        self.assertIsNone(windows.parse("BLOCKED_WIDGET"))

    def test_count(self):
        block = windows.count([DISMISSED, POPUP, "noise", DISMISSED.replace("widget=11", "widget=15")])
        self.assertTrue(block["ok"])
        self.assertEqual(block["blocked_widgets"], 3)
        self.assertEqual(block["blocked_by_class"], {"JavaScriptTabModalDialogViewViews": 2, "-": 1})
        self.assertEqual(block["blocked_by_owner"], {"js-dialog": 2, "none": 1})
        self.assertEqual(block["unexpected_windows"], 0)

    def test_failures(self):
        self.assertFalse(windows.count([WINDOW])["ok"], "an unexpected window fails")
        refused = windows.count([REFUSED])
        self.assertFalse(refused["ok"], "a refused widget no cmux UI owns fails")
        self.assertEqual([w["widget"] for w in refused["unhandled_widgets"]], ["13"])
        owned = windows.count([OWNED_REFUSED])
        self.assertFalse(owned["ok"], "a refused widget fails though a cmux UI owns its kind: no widget is routed")
        self.assertEqual([w["widget"] for w in owned["unhandled_widgets"]], ["14"])
        self.assertFalse(windows.count([CLOSE_FAILED])["ok"], "a close the fork did not know fails")
        held = windows.count([HELD])
        self.assertFalse(held["ok"], "a held permission prompt fails: no one saw the request")
        self.assertEqual(held["blocked_by_owner"], {"permission-prompt": 1})
        self.assertFalse(windows.count([HELD, HELD_GONE])["ok"], "held, then ended by Chromium: still unhandled")
        self.assertTrue(windows.count([HELD_GONE])["ok"], "a row that sees only the end of an earlier row's prompt")

    def test_on_screen_windows(self):
        self.assertEqual(windows.visible([ON_SCREEN, {"alpha": 0.0}, {"alpha": None}]), [ON_SCREEN])
        self.assertIsNone(windows.visible(None))
        shown = windows.count([], [ON_SCREEN])
        self.assertFalse(shown["ok"], "a host window on screen fails with no host line naming it")
        self.assertEqual(shown["on_screen_windows"], [ON_SCREEN])
        self.assertIn("1 host windows on screen", windows.summary(shown))
        unread = windows.count([], None)
        self.assertFalse(unread["ok"], "an unreadable window list proves nothing")
        self.assertIn("could not be read", windows.summary(unread))
        self.assertTrue(windows.count([], [])["ok"])

    def test_refused_then_dismissed(self):
        later = REFUSED.replace("action=refused", "action=dismissed")
        block = windows.count([REFUSED, POPUP, later])
        self.assertTrue(block["ok"], "a refused widget that hid at last counts by its last line")
        self.assertEqual(block["blocked_widgets"], 2, "one widget, two lines: counted once")
        self.assertEqual(block["blocked_by_class"], {"-": 1, "Odd": 1})
        self.assertFalse(windows.count([later, REFUSED])["ok"], "the last line decides")

    def test_checked(self):
        row = windows.checked({"ok": True, "show_ms": 3}, [WINDOW])
        self.assertFalse(row["ok"])
        self.assertIn("1 unexpected host windows", row["host_windows_failed"])
        self.assertEqual(windows.checked({"ok": False, "error": "x"}, [])["error"], "x")
        self.assertTrue(windows.checked({"ok": True}, [DISMISSED])["ok"])

    def test_failing(self):
        rows = {"select": {"ok": True}, "date": {"ok": False, "not_run": "no widget host"},
                "alert": windows.checked({"ok": True}, [WINDOW]), "side_panel": {"ok": False, "error": "no probe"}}
        self.assertEqual(windows.failing(rows), [("date", "no widget host"), ("alert", rows["alert"]["host_windows_failed"]),
                                                 ("side_panel", "no probe")])

    def test_cursor_whole_lines(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "app.log")
            with open(path, "w") as log:
                log.write("before\n")
            cursor = windows.LogCursor(path)
            with open(path, "a") as log:
                log.write(DISMISSED + "\n" + WINDOW[:20])
            self.assertEqual(cursor.take(), [DISMISSED])
            with open(path, "a") as log:
                log.write(WINDOW[20:] + "\n")
            self.assertEqual(cursor.take(), [WINDOW])
            self.assertEqual(cursor.take(), [])
        self.assertEqual(windows.LogCursor(None).take(), [])


class BenchTests(unittest.TestCase):
    """native_ui_rows and print_failing of the bench, with fake row modules that write host lines to a fake log."""

    def setUp(self):
        self.bench = load_bench()
        self.root = tempfile.TemporaryDirectory()
        self.log = os.path.join(self.root.name, "app.log")
        open(self.log, "w").close()
        self.bench.APP_LOG["path"] = self.log
        self.bench.RESULT = {"modes": {}, "notes": []}
        self.lines = {}  # row -> lines its run writes
        self.results = {}  # row -> the row its run returns (default {"ok": True})
        self.ran = []
        self.calls = []  # (module, rows) per run call: one probe per module
        self.page_kwargs = {}
        self.on_screen = {}  # row -> the host's visible windows at its end
        self.current = [None]
        self.bench.host_on_screen = lambda: list(self.on_screen.get(self.current[0], []))

        def fake(module, order):
            def run(*_a, rows_to_run, on_row, **kwargs):
                self.calls.append((module, list(rows_to_run)))
                if module == "page":
                    self.page_kwargs = kwargs
                rows = {}
                for name in order:
                    if name not in rows_to_run:
                        continue
                    self.ran.append(name)
                    self.current[0] = name
                    with open(self.log, "a") as log:
                        log.writelines(line + "\n" for line in self.lines.get(name, []))
                    rows[name] = on_row(name, dict(self.results.get(name, {"ok": True})))
                self.current[0] = None
                return rows, True
            return run

        self.bench.chromium_host_native_ui.run = fake("page", self.bench.chromium_host_native_ui.ROWS)
        self.bench.chromium_host_native_ui_dialogs.run = fake("dialogs", self.bench.chromium_host_native_ui_dialogs.ROWS)
        self.bench.chromium_host_native_ui_choosers.run = fake("choosers", self.bench.chromium_host_native_ui_choosers.ROWS)

    def tearDown(self):
        (chromium_host_native_ui.run, chromium_host_native_ui_dialogs.run,
         chromium_host_native_ui_choosers.run) = REAL_RUNS
        self.root.cleanup()

    def run_bench(self, names, rpc=None):
        self.bench.opts = self.bench.parse(["--app", "x", "--out", self.root.name, "--native-ui", names, "--list-failing"])
        rows, ok = self.bench.native_ui_rows(rpc, "file:///probe", "file:///choosers", 1)
        self.bench.RESULT["modes"]["native_ui"] = rows
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.bench.print_failing(self.bench.RESULT)
        return rows, ok, out.getvalue().splitlines()

    def test_rows_get_their_own_lines(self):
        self.lines = {"date": [POPUP], "file_picker": [WINDOW]}
        rows, ok, printed = self.run_bench("select,date,file_picker")
        self.assertEqual(self.ran, ["select", "date", "file_picker"], "each row runs, in order")
        self.assertEqual(self.calls, [("page", ["select", "date"]), ("dialogs", ["file_picker"])],
                         "the page rows share one probe: one run call per module")
        self.assertFalse(ok)
        self.assertTrue(rows["select"]["ok"])
        self.assertTrue(rows["date"]["ok"])
        self.assertEqual(rows["date"]["host_windows"]["blocked_by_class"], {"-": 1})
        self.assertFalse(rows["file_picker"]["ok"])
        self.assertEqual(self.bench.RESULT["host_windows"]["unexpected_windows"], 1)
        self.assertEqual([line.split(":")[0] for line in printed],
                         ["FAILING native_ui.file_picker", "FAILING native_ui.host_windows"])

    def test_chooser_rows_get_their_own_lines_and_a_skipped_row_counts_neither_way(self):
        self.lines = {"color": [DISMISSED], "web_share": [], "device_chooser": [WINDOW]}
        self.results = {"web_share": {"skipped": "no Web Share handler", "task": "p01-process-228c"}}
        rows, ok, printed = self.run_bench("select,color,device_chooser,web_share")
        self.assertEqual(self.calls, [("page", ["select"]), ("choosers", ["color", "device_chooser", "web_share"])])
        self.assertTrue(rows["color"]["ok"])
        self.assertFalse(rows["device_chooser"]["ok"], "a chooser row's own unexpected window fails it")
        self.assertIn("skipped", rows["web_share"])
        self.assertFalse(ok)
        self.assertEqual([line.split(":")[0] for line in printed],
                         ["FAILING native_ui.device_chooser", "FAILING native_ui.host_windows"])
        self.lines = {"color": [DISMISSED]}
        self.calls, self.ran = [], []
        self.bench.RESULT = {"modes": {}, "notes": []}
        rows, ok, printed = self.run_bench("color,web_share")
        self.assertTrue(ok, rows)
        self.assertEqual(printed, ["FAILING none"])

    def test_context_menu_and_download_rows(self):
        self.lines = {"context_menu": [POPUP], "download": [DISMISSED]}
        rows, ok, printed = self.run_bench("select,context_menu,download,date")
        self.assertEqual(self.ran, ["select", "context_menu", "download", "date"])
        self.assertEqual(self.calls, [("page", ["select", "context_menu", "download", "date"])])
        self.assertTrue(callable(self.page_kwargs.get("right_click")), "the page rows get the bench's right click")
        self.assertTrue(ok, rows)
        self.assertEqual(rows["context_menu"]["host_windows"]["blocked_by_class"], {"-": 1})
        self.assertEqual(printed, ["FAILING none"])

    def test_a_window_no_line_names_fails_its_row(self):
        self.on_screen = {"date": [ON_SCREEN]}
        rows, ok, printed = self.run_bench("select,date")
        self.assertFalse(ok)
        self.assertTrue(rows["select"]["ok"])
        self.assertFalse(rows["date"]["ok"])
        self.assertEqual(rows["date"]["host_windows"]["on_screen_windows"], [ON_SCREEN])
        self.assertIn("1 host windows on screen", rows["date"]["host_windows_failed"])
        self.assertEqual([line.split(":")[0] for line in printed], ["FAILING native_ui.date"])

    def test_clean_run(self):
        self.lines = {"date": [DISMISSED, POPUP]}
        rows, ok, printed = self.run_bench("select,date")
        self.assertTrue(ok)
        self.assertEqual(self.bench.RESULT["host_windows"]["blocked_widgets"], 2)
        self.assertEqual(printed, ["FAILING none"])

    def test_owned_refused_fails_its_row(self):
        self.lines = {"date": [OWNED_REFUSED]}
        rows, ok, printed = self.run_bench("select,date")
        self.assertFalse(ok)
        self.assertFalse(rows["date"]["ok"], "an owned widget that still shows is not handled by its owner label")
        self.assertEqual([line.split(":")[0] for line in printed],
                         ["FAILING native_ui.date", "FAILING native_ui.host_windows"])

    def test_probe_failure_names_each_row(self):
        native_ui = self.bench.chromium_host_native_ui
        native_ui.run = REAL_RUNS[0]
        rpc = lambda method, params=None, timeout=None: {"opened": method}  # noqa: E731
        never = lambda *_a, **_k: False  # noqa: E731
        self.bench.wait = never
        self.bench.page_eval = lambda *_a, **_k: None
        rows, ok, printed = self.run_bench("select,date,autofill", rpc=rpc)
        self.assertFalse(ok)
        self.assertEqual(sorted(rows), ["autofill", "date", "select"])
        self.assertTrue(all(rows[name]["error"].startswith("the probe never loaded") for name in rows))
        self.assertEqual([line.split(":")[0] for line in printed],
                         ["FAILING native_ui.select", "FAILING native_ui.date", "FAILING native_ui.autofill"])

    def test_line_after_the_last_row_fails_the_run(self):
        take = self.bench.chromium_host_windows.LogCursor.take
        calls = []

        def take_then_write(cursor):
            calls.append(1)
            got = take(cursor)
            if len(calls) == 1:  # the row's own take is done: the host writes its line just after
                with open(self.log, "a") as log:
                    log.write(REFUSED + "\n")
            return got
        self.bench.chromium_host_windows.LogCursor.take = take_then_write
        try:
            rows, ok, printed = self.run_bench("select")
        finally:
            self.bench.chromium_host_windows.LogCursor.take = take
        self.assertTrue(rows["select"]["ok"])
        self.assertFalse(ok, "the whole run's count still sees the late line")
        self.assertEqual(printed[0].split(":")[0], "FAILING native_ui.host_windows")


if __name__ == "__main__":
    unittest.main()

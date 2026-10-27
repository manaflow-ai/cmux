#!/usr/bin/env python3
"""chromium_host_windows.py and chromium-host-bench.py --native-ui --list-failing (p01-process-068), with no app: the
host's BLOCKED_WIDGET and UNEXPECTED_WINDOW lines (host_blocked_widgets.h's format) are parsed out of app log lines,
counted per row by Views class and owner, and a row fails on any unexpected window or a blocked widget that was
neither dismissed nor owned by a cmux UI. Through the bench: each row runs on its own and gets only the lines written
while it ran, a late line still fails the whole run, and --list-failing names each failing row.
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_windows.py"""
import contextlib, importlib.util, io, os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_windows as windows  # noqa: E402

PREFIX = "[12:00:01.5] cmux-chromium-host: "
DISMISSED = (PREFIX + "BLOCKED_WIDGET browser=7 widget=11 kind=0 class=JavaScriptTabModalDialogViewViews "
             "rect=10,20,300,120 visible=1 owner=js-dialog action=dismissed")
POPUP = PREFIX + "BLOCKED_WIDGET browser=7 widget=12 kind=3 class=- rect=0,0,10,10 visible=1 owner=none action=dismissed"
REFUSED = PREFIX + "BLOCKED_WIDGET browser=0 widget=13 kind=0 class=Odd rect=0,0,1,1 visible=1 owner=none action=refused"
OWNED_REFUSED = (PREFIX + "BLOCKED_WIDGET browser=7 widget=14 kind=0 class=PermissionPromptBubbleOneOriginView "
                 "rect=0,0,1,1 visible=1 owner=permission-prompt action=refused")
WINDOW = PREFIX + "UNEXPECTED_WINDOW class=NSPanel title=1a2b3c4d action=ordered-out"


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
        self.assertTrue(windows.count([OWNED_REFUSED])["ok"], "a refused widget a cmux UI owns passes")

    def test_checked(self):
        row = windows.checked({"ok": True, "show_ms": 3}, [WINDOW])
        self.assertFalse(row["ok"])
        self.assertIn("1 unexpected host windows", row["host_windows_failed"])
        self.assertEqual(windows.checked({"ok": False, "error": "x"}, [])["error"], "x")
        self.assertTrue(windows.checked({"ok": True}, [DISMISSED])["ok"])

    def test_failing(self):
        rows = {"select": {"ok": True}, "date": {"ok": False, "not_run": "no widget host"},
                "alert": windows.checked({"ok": True}, [WINDOW]), "error": "the probe never loaded"}
        self.assertEqual([name for name, _ in windows.failing(rows)], ["date", "alert", "error"])

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
        self.ran = []

        def run_rows(rows_to_run):
            (name,) = rows_to_run
            self.ran.append(name)
            with open(self.log, "a") as log:
                log.writelines(line + "\n" for line in self.lines.get(name, []))
            return {name: {"ok": True}}, True

        self.bench.chromium_host_native_ui.run = lambda *a, rows_to_run, **k: run_rows(rows_to_run)
        self.bench.chromium_host_native_ui_dialogs.run = lambda *a, rows_to_run, **k: run_rows(rows_to_run)

    def tearDown(self):
        self.root.cleanup()

    def run_bench(self, names):
        self.bench.opts = self.bench.parse(["--app", "x", "--out", self.root.name, "--native-ui", names, "--list-failing"])
        rows, ok = self.bench.native_ui_rows(None, "file:///probe", 1)
        self.bench.RESULT["modes"]["native_ui"] = rows
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.bench.print_failing(self.bench.RESULT)
        return rows, ok, out.getvalue().splitlines()

    def test_rows_get_their_own_lines(self):
        self.lines = {"date": [POPUP], "file_picker": [WINDOW]}
        rows, ok, printed = self.run_bench("select,date,file_picker")
        self.assertEqual(self.ran, ["select", "date", "file_picker"], "each row runs on its own, in order")
        self.assertFalse(ok)
        self.assertTrue(rows["select"]["ok"])
        self.assertTrue(rows["date"]["ok"])
        self.assertEqual(rows["date"]["host_windows"]["blocked_by_class"], {"-": 1})
        self.assertFalse(rows["file_picker"]["ok"])
        self.assertEqual(self.bench.RESULT["host_windows"]["unexpected_windows"], 1)
        self.assertEqual([line.split(":")[0] for line in printed],
                         ["FAILING native_ui.file_picker", "FAILING native_ui.host_windows"])

    def test_clean_run(self):
        self.lines = {"date": [DISMISSED, OWNED_REFUSED]}
        rows, ok, printed = self.run_bench("select,date")
        self.assertTrue(ok)
        self.assertEqual(self.bench.RESULT["host_windows"]["blocked_widgets"], 2)
        self.assertEqual(printed, ["FAILING none"])

    def test_line_after_the_last_row_fails_the_run(self):
        def late(*_a, rows_to_run, **_k):
            self.ran.append(rows_to_run[0])
            return {rows_to_run[0]: {"ok": True}}, True
        self.bench.chromium_host_native_ui.run = late
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

#!/usr/bin/env python3
"""new_surface_screen.py: each take runs in an active app whose shell window is the key window, or it does not run.

No app, no display, no fleet: the app is test_key_tabs_screen.py's function. It is not active at its launch, it
becomes active (and its window the key window) when `debug.window.focus` asks with `activate`, and it says both in
its `debug.focus` answer. So this proves that the tool asks one time, before its first case, what it reads before
each recording and when it ends the run, not that an app on a Mac becomes active by that call.

    python3 -I scripts/cmux-next/tests/test_screen_active_app.py
"""
import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # the imports leave no cache folder in the checkout
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_close_tab_screen as close  # noqa: E402
import test_key_tabs_screen as tabs  # noqa: E402

new_surface_screen = close.new_surface_screen
ASK = {"window": "window-1", "activate": True}


class App(tabs.KeyTabsApp):
    """The app of the tabs' tests, which keeps each call's name in order (`names`). `lost_after`: the number of the
    recording after which the app is not active again (another app took the screen). `key`: False for an app that
    becomes active with a window that is not its key window. `windows`: False for an app that lists no window."""

    def __init__(self, folder, **more):
        super().__init__(folder, **more)
        self.names, self.lost_after, self.key, self.windows = [], None, True, True

    def rpc(self, method, params=None, timeout=30):
        action = (params or {}).get("action")
        self.names.append(method if method != "debug.new_tab" else action)
        if method == "debug.focus" and not self.windows:
            return {"app_active": self.active, "windows": []}
        reply = super().rpc(method, params, timeout)
        if method == "debug.window.focus" and not self.key:
            self.is_key = False
            reply = {"key": None, "front": "window-1"}
        if action == "frame_strip" and self.strips == self.lost_after:
            self.active = self.is_key = False
        return reply


class ActiveAppTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="screen-active-app-test-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.folder, ignore_errors=True))

    def run_mode(self, app, **changed):
        screen = new_surface_screen.Screen(close.options(self.folder, **changed), app.rpc, app.tools(), sleep=app.pause,
                                           make_session=lambda *asked: {}, clock=app.clock, start=app.start)
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report = screen.run()
        return report, said.getvalue()

    def test_the_tool_asks_one_time_for_the_active_app_before_its_first_case(self):
        app = App(self.folder)
        report, said = self.run_mode(app, keys="t,w", gaps="0", close_cases="idle,hold")
        self.assertEqual(app.window_calls, [ASK])
        asked = app.names.index("debug.window.focus")
        self.assertTrue(all(asked < app.names.index(call) for call in ("frame_strip", "debug.key")), app.names)
        self.assertEqual(report.get("activation"), {"by": "debug.window.focus", "asked": ASK, "reply": {"key": "window-1", "front": "window-1"},
                                                    "app_active": True, "shell_window_is_key": True, "reads": 1, "seconds": 0.0})
        # Each row says the app's own answer, read directly before its recording.
        self.assertEqual([(row.get("app_active"), row.get("shell_window_is_key"), row["invalid"]) for row in report["rows"]], [(True, True, [])] * 3)
        # The head: the app, the workspace of the keys, and how long the app took to become active.
        self.assertEqual(report["head"][:3], ["the app was active: yes",
                                              "the key's workspace: the workspace that the app showed at its launch (the tool asked for no other)",
                                              "the ask for the active app: 1 reads of the app's answer, 0 s from the ask to the answer"])
        # Then the rows that the recorder lost in each case, and the app's settings lines (test_screen_window_look.py).
        self.assertEqual(report["head"][3], "rows lost to the recorder (INVALID by `no-row` or `refresh`, a fault of the tool's yield): "
                                            "cmd-t/idle 0 of 1; cmd-w/idle 0 of 1; cmd-w/100 ms after a hold of the New Tab key "
                                            "(6 key-downs: 1 and 5 repeats with the repeat flag) 0 of 1")
        self.assertIn("NEW-SURFACE-SCREEN-HEAD " + "; ".join(report["head"]), said.splitlines())
        self.assertEqual(report["cases"]["cmd-w/idle"]["active"], {"app_active": {"yes": 1, "of": 1}, "shell_window_is_key": {"yes": 1, "of": 1}})

    def test_an_app_that_does_not_become_active_ends_the_run_before_a_case(self):
        app = App(self.folder)
        app.takes_focus = False
        report, said = self.run_mode(app, keys="n,t,w", gaps="0")
        self.assertEqual(report.get("stopped"), 'active: after debug.window.focus {"window": "window-1", "activate": true} the app says '
                                                'app_active=false and its window says is_key=false (the call\'s reply: {"key": null, "front": '
                                                '"window-1"}): no tab made, no case recorded')
        self.assertEqual((app.window_calls, report["rows"], report["cases"], report["exit_code"]), ([ASK], [], {}, new_surface_screen.STOPPED_EXIT))
        self.assertEqual([call for call in app.names if call in ("frame_strip", "debug.key", "action.run")], [])
        self.assertEqual(report["head"][0], "the app was active: no")
        self.assertEqual(said.splitlines()[-1], f"NEW-SURFACE-SCREEN report only: 0 rows, 0 INVALID, 0 pictures kept; STOPPED {report['stopped']}")
        # The tool reads the app's answer again for a time before it ends the run, and it asks one time only.
        self.assertEqual((report["activation"]["reads"], report["activation"].get("seconds")), (new_surface_screen.ACTIVE_READS, 9.8))
        self.assertEqual(report["head"][2], "the ask for the active app: 50 reads of the app's answer, 9.8 s from the ask to the answer")

    def test_an_active_app_whose_window_is_not_the_key_window_ends_the_run(self):
        app = App(self.folder)
        app.key = False
        report, _ = self.run_mode(app, keys="w")
        self.assertIn("the app says app_active=true and its window says is_key=false", report.get("stopped", ""))
        self.assertEqual((report["rows"], app.strips), ([], 0))

    def test_an_app_that_lists_no_window_ends_the_run_with_no_ask(self):
        app = App(self.folder)
        app.windows = False
        report, _ = self.run_mode(app, keys="t", gaps="0")
        self.assertEqual(report.get("stopped"), "active: the app lists no window (debug.focus): no tab made, no case recorded")
        self.assertEqual((app.window_calls, report["rows"], app.strips), ([], [], 0))
        self.assertEqual(report["head"][2], "the ask for the active app: not made")

    def test_a_hold_in_an_app_that_is_not_active_is_invalid_and_in_another_case_it_is_a_fact(self):
        app = App(self.folder)
        app.lost_after = 1  # after the first recording the app is not active
        report, said = self.run_mode(app, keys="t,w", gaps="0", close_cases="idle,hold")
        rows = report["rows"]
        self.assertEqual([(row["label"], row.get("app_active"), row.get("shell_window_is_key")) for row in rows],
                         [("cmd-t-idle-0", True, True), ("cmd-w-idle-0", False, False), ("cmd-w-hold100-0", False, False)])
        self.assertEqual((rows[0]["invalid"], rows[1]["invalid"]), ([], []))
        self.assertEqual(rows[2]["invalid"], ["active: directly before the recording the app says app_active=false and its window says "
                                              "is_key=false: a hold's keys go to the key window of an active app"])
        self.assertEqual(len(app.window_calls), 1)  # no second ask: the row says what the app was
        self.assertEqual(report["head"][0], "the app was active: NOT IN EACH ROW (1 of 3 rows, by the app's answer before each recording)")
        line = next(line for line in said.splitlines() if "-ROW cmd-w-idle-0" in line)
        self.assertIn(" app_active=False shell_window_is_key=False", line)

    def test_a_hold_that_the_app_refused_in_an_app_that_is_not_active_says_both(self):
        app = App(self.folder)
        app.lost_after = 1
        app.refuse_sequence = "the shell window did not become key"
        report, _ = self.run_mode(app, keys="t,w", gaps="0", close_cases="hold")
        row = report["rows"][1]
        self.assertEqual((len(row["invalid"]), row["invalid"][0].split(":")[0], row.get("app_active")), (2, "active", False))
        self.assertEqual(row["invalid"][1], 'input: the app refused the hold\'s key sequence: "the shell window did not become key"')


if __name__ == "__main__":
    unittest.main()

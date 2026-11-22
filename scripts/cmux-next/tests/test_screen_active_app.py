#!/usr/bin/env python3
"""new_surface_screen.py: each take runs in a window that the app shows, in an app that takes no keyboard.

No app, no display, no fleet: the app is test_key_tabs_screen.py's function. It says in its `debug.focus` answer
whether it is active and whether its shell window is the key window, and in its `debug.window_list` answer what its
windows are; no call of the tool changes either. So this proves what the tool asks (one time, before its first
case, with no activation), what it reads before the first case, before each recording and after the last case,
which key window form it gives a read, when it ends the run and what it does not run, not what an app on a Mac
answers, nor that a recording of a window that the app shows has the screen's frames.

    python3 -I scripts/cmux-next/tests/test_screen_active_app.py
"""
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # the imports leave no cache folder in the checkout
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_close_tab_screen as close  # noqa: E402
import test_key_tabs_screen as tabs  # noqa: E402

base, new_surface_screen = close.base, close.new_surface_screen
ASK = {"window": "window-1"}
THIRD = "the ask for the window in front (no activation): "
FRAME = {"x": 40.0, "y": 230.0, "width": 1200.0, "height": 900.0}
# The tool's facts of one read of the app's windows, for the app of these tests as it is made.
WINDOW = {"main_windows": 1, "frame": FRAME, "visible": True, "miniaturized": False, "occluded": False, "key_child": None, "fault": None}
NOT_SHOWN = "the app's window is not shown as a take needs it (debug.window_list): "
# A page's child window in the app's list: a plain window (its kind is its class), the key window, a child of the shell window.
CHILD = {"id": 42, "kind": "PageWindow", "title": base.TITLE, "frame": {"x": 300.0, "y": 300.0, "width": 800.0, "height": 600.0},
         "visible": True, "parent": 41, "class": "PageWindow", "level": 0, "ignores_mouse": False, "key": True, "occluded": False,
         "miniaturized": False, "alpha": 1.0}
# The launch of the driver: no activation, and the window's place and size.
LAUNCHED = {"cli": "/app/bin/cmux", "env": {"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,900"}}
HOLD_NOT_RUN = "hold: a hold needs the key window, this launch gives none (the run's key window form: {}): not run, no recording"


class App(tabs.KeyTabsApp):
    """The app of the tabs' tests (active, its shell window the key window), which keeps each call's name in order
    (`names`). `lost_after`: the number of the recording after which the app is not active again (another app took
    the screen). `gone_after`: the number of the recording after which the app lists no window in `debug.focus`.
    `windows`: False for an app that lists no window there. `page`: the id of a page that the app's window names as
    the holder of the keys in a child window (`appkit.child_window_page`); `debug.focus` then names the class
    `PageWindow` as the app's key window. `second_key`: True for an app with a second window that is its key window.
    `changed_after`, `changed`: the number of the recording after which the shell window's entry in
    `debug.window_list` has the fields of `changed`. `list_s`: the seconds that one `debug.window_list` call takes."""

    def __init__(self, folder, **more):
        super().__init__(folder, **more)
        self.names, self.lost_after, self.gone_after, self.windows = [], None, None, True
        self.page, self.second_key = None, False
        self.changed_after, self.changed, self.list_s = None, {}, 0.0

    def rpc(self, method, params=None, timeout=30):
        action = (params or {}).get("action")
        self.names.append(method if method != "debug.new_tab" else action)
        if method == "debug.focus" and not self.windows:
            return {"app_active": self.active, "windows": []}
        if method == "debug.window_list":
            self.now += self.list_s
        reply = super().rpc(method, params, timeout)
        if method == "debug.focus" and self.page:
            reply["windows"][0]["appkit"] = {"first_responder": None, "child_window_page": self.page}
            reply["key_window"] = "PageWindow" if self.active and not self.second_key else None
        if method == "debug.focus" and self.second_key:
            reply["windows"].append({"id": "window-2", "is_key": True})
        if action == "frame_strip" and self.strips == self.lost_after:
            self.active = self.is_key = False
        if action == "frame_strip" and self.strips == self.gone_after:
            self.windows = False
        if action == "frame_strip" and self.strips == self.changed_after:
            self.shell_window.update(self.changed)
        return reply


def page_app(folder, child=CHILD):
    """An active app whose shell window is not the key window and names a page as the holder of the keys; `child`:
    the entry of that page's window in the app's list of windows (None: the list has no such window)."""
    app = App(folder)
    app.is_key, app.page, app.other_windows = False, "page-7", [dict(child)] if child else []
    return app


def not_active(folder):
    """An app that takes no keyboard: it is not active and it has no key window."""
    app = App(folder)
    app.active = app.is_key = False
    return app


class WindowFactTests(unittest.TestCase):
    def test_one_read_of_the_apps_windows_keeps_the_frame_and_3_words_of_the_one_main_window_and_no_title(self):
        app = App("no folder")
        fact = new_surface_screen.window_fact(app.window_list())
        self.assertEqual(fact, {name: value for name, value in WINDOW.items() if name != "fault"})
        self.assertIsNone(new_surface_screen.window_fault(fact))
        self.assertNotIn(base.TITLE, json.dumps(fact))

    def test_each_word_that_is_not_as_a_take_needs_it_is_a_fault_by_its_name(self):
        for field, value, said in (("occluded", True, "`occluded` is true"), ("visible", False, "`visible` is false"),
                                   ("miniaturized", True, "`miniaturized` is true"), ("occluded", None, "`occluded` is null")):
            with self.subTest(field=field, value=value):
                app = App("no folder")
                app.shell_window[field] = value
                self.assertEqual(new_surface_screen.window_fault(new_surface_screen.window_fact(app.window_list())), NOT_SHOWN + said)

    def test_no_answer_and_another_count_of_main_windows_than_one_are_faults(self):
        for reply, count in (({"error": {"code": "timeout"}}, 0), ("no answer", 0), ({"windows": [{"kind": "settings"}]}, 0),
                             ({"windows": [{"kind": "main"}, {"kind": "main"}, "not an entry"]}, 2)):
            with self.subTest(reply=reply):
                fact = new_surface_screen.window_fact(reply)
                self.assertEqual((fact["main_windows"], fact["frame"], fact["visible"]), (count, None, None))
                self.assertEqual(new_surface_screen.window_fault(fact), f"the app lists {count} windows of the kind `main` "
                                 "(debug.window_list): the tool names the measured window only in an app with one")

    def test_the_size_that_the_launch_asked_is_checked_only_for_a_launch_that_places_the_window(self):
        self.assertEqual(new_surface_screen.asked_size(LAUNCHED), [1200.0, 900.0])
        for launched in (None, {}, {"env": {"CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,900"}},  # the app reads it only with no activation
                         {"env": {"CMUX_NEXT_NO_ACTIVATE": "1"}}, {"env": {"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,wide,900"}},
                         {"env": {"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200"}}):
            with self.subTest(launched=launched):
                self.assertIsNone(new_surface_screen.asked_size(launched))
        fact = new_surface_screen.window_fact(App("no folder").window_list())
        self.assertIsNone(new_surface_screen.window_fault(fact, [1200.0, 900.0]))
        self.assertEqual(new_surface_screen.window_fault(fact, [1100.0, 720.0]),
                         NOT_SHOWN + "its frame is 1200 x 900 points, the launch asked for 1100 x 720")


class ActiveAppTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="screen-active-app-test-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.folder, ignore_errors=True))

    def run_mode(self, app, launched=None, **changed):
        screen = new_surface_screen.Screen(close.options(self.folder, **changed), app.rpc, app.tools(), sleep=app.pause,
                                           make_session=lambda *asked: {}, clock=app.clock, start=app.start)
        screen.launched = launched  # the driver's word about its launch (None: the driver launched no app)
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report = screen.run()
        return report, said.getvalue()

    def test_the_tool_asks_one_time_for_the_window_in_front_with_no_activation_before_its_first_case(self):
        app = App(self.folder)
        report, said = self.run_mode(app, keys="t,w", gaps="0", close_cases="idle,hold")
        self.assertEqual(app.window_calls, [ASK])  # no `activate`: the tool takes no keyboard
        asked = app.names.index("debug.window.focus")
        self.assertTrue(all(asked < app.names.index(call) for call in ("frame_strip", "debug.key")), app.names)
        # (R) the report: the form of the read, the app's answer before the ask, and the facts of the last read.
        self.assertEqual(report.get("activation"), {
            "by": "debug.window.focus", "asked": ASK, "reply": {"key": "window-1", "front": "window-1"},
            "app_active": True, "shell_window_is_key": True, "reads": 1, "seconds": 0.0, "form": "shell",
            "before": {"app_active": True, "shell_window_is_key": True},
            "at_the_end": {"key_window_form": "shell", "shown_tab_kind": "terminal", "child_window_page": None, "first_responder": None,
                           "app_windows": 1, "app_key_window": None, "keyboard_given_back": None}})
        # Each row says the app's own answer, read directly before its recording, and the form of the key window.
        self.assertEqual([(row.get("app_active"), row.get("shell_window_is_key"), row["invalid"]) for row in report["rows"]], [(True, True, [])] * 3)
        self.assertEqual(([row.get("key_window_form") for row in report["rows"]], report.get("key_window_form")), (["shell"] * 3, "shell"))
        self.assertEqual(report["cases"]["cmd-w/idle"].get("key_window_forms"), {"shell": 1})
        # In the form `shell` the hold runs: one key sequence, and the report has no word that it did not run.
        self.assertEqual((len(app.sequences), "not_run" in report["close"]["hold"]), (1, False))
        # The head: the app, the workspace of the keys, and the ask with the form of its read.
        self.assertEqual(report["head"][:3], ["the app was active: yes",
                                              "the key's workspace: the workspace that the app showed at its launch (the tool asked for no other)",
                                              THIRD + "1 reads of the app's answer, 0 s from the ask to the answer, the key window form: shell"])
        # Then the rows that the recorder lost in each case, and the app's settings lines (test_screen_window_look.py).
        self.assertEqual(report["head"][3], "rows lost to the recorder (INVALID by `no-row` or `refresh`, a fault of the tool's yield): "
                                            "cmd-t/idle 0 of 1; cmd-w/idle 0 of 1; cmd-w/100 ms after a hold of the New Tab key "
                                            "(6 key-downs: 1 and 5 repeats with the repeat flag) 0 of 1")
        self.assertIn("NEW-SURFACE-SCREEN-HEAD " + "; ".join(report["head"]), said.splitlines())
        self.assertEqual(report["cases"]["cmd-w/idle"]["active"], {"app_active": {"yes": 1, "of": 1}, "shell_window_is_key": {"yes": 1, "of": 1}})

    def test_an_app_that_is_not_active_runs_and_each_row_says_the_form_window_shown(self):
        # `app_active` is a fact of the report and no condition: a press row's key goes to the window by `debug.key`.
        app = not_active(self.folder)
        report, said = self.run_mode(app, launched=LAUNCHED, keys="t,w", gaps="0", close_cases="idle")
        self.assertIsNone(report.get("stopped"))
        self.assertEqual([(row.get("app_active"), row.get("shell_window_is_key"), row.get("key_window_form"), row["invalid"])
                          for row in report["rows"]], [(False, False, "window shown", [])] * 2)
        self.assertEqual((app.window_calls, report["activation"]["reads"], report["activation"]["form"], report["key_window_form"]),
                         ([ASK], 1, "window shown", "window shown"))
        self.assertEqual(report["activation"]["before"], {"app_active": False, "shell_window_is_key": False})
        self.assertEqual(report["cases"]["cmd-t/idle"]["key_window_forms"], {"window shown": 1})
        self.assertEqual(report["head"][0], "the app was active: no (0 of 2 rows, by the app's answer before each recording)")
        self.assertEqual(report["head"][2], THIRD + "1 reads of the app's answer, 0 s from the ask to the answer, the key window form: window shown")
        self.assertIn(" app_active=False shell_window_is_key=False key_window_form=window shown", next(
            line for line in said.splitlines() if "-ROW cmd-t-idle-0" in line))
        self.assertTrue(said.splitlines()[-1].startswith("NEW-SURFACE-SCREEN report only: 2 rows, 0 INVALID, "), said.splitlines()[-1])

    def test_the_report_keeps_the_frame_and_the_3_words_of_the_read_before_the_first_case_and_after_the_last_case(self):
        app = not_active(self.folder)
        report, said = self.run_mode(app, launched=LAUNCHED, keys="t,w", gaps="0", close_cases="idle")
        self.assertEqual(report.get("window"), {"asked_size": [1200.0, 900.0], "before_the_first_case": WINDOW, "after_the_last_case": WINDOW,
                                                "same": True})
        self.assertIn("NEW-SURFACE-SCREEN-WINDOW " + json.dumps(report["window"]), said.splitlines())
        # 2 reads of the app's windows in the run: before the first tab and case, and after the last recording.
        reads = [index for index, name in enumerate(app.names) if name == "debug.window_list"]
        strips = [index for index, name in enumerate(app.names) if name == "frame_strip"]
        self.assertEqual((len(reads), reads[0] < strips[0], reads[1] > strips[-1]), (2, True, True))
        # Never a title: not in the report, not in a printed line.
        self.assertNotIn(base.TITLE, json.dumps(report) + said)
        self.assertNotIn("title", json.dumps(report["window"]))

    def test_a_window_that_the_app_does_not_show_ends_the_run_before_a_tab_and_a_case(self):
        other = {**base.FakeApp("no folder", []).shell_window, "id": 43, "key": False}
        for field, value, said in (("occluded", True, NOT_SHOWN + "`occluded` is true"), ("visible", False, NOT_SHOWN + "`visible` is false"),
                                   ("miniaturized", True, NOT_SHOWN + "`miniaturized` is true"),
                                   ("kind", "settings", "the app lists 0 windows of the kind `main` (debug.window_list): the tool names the "
                                                        "measured window only in an app with one"),
                                   ("more", other, "the app lists 2 windows of the kind `main` (debug.window_list): the tool names the "
                                                   "measured window only in an app with one")):
            with self.subTest(field=field):
                app = not_active(self.folder)
                if field == "more":
                    app.other_windows = [value]
                else:
                    app.shell_window[field] = value
                report, printed = self.run_mode(app, launched=LAUNCHED, keys="t,w", gaps="0", key_tabs=[6])
                self.assertEqual(report.get("stopped"), 'window: after debug.window.focus {"window": "window-1"} ' + said + " (50 reads of the "
                                 'app\'s answer, 0.2 s apart; the call\'s reply: {"key": null, "front": "window-1"}; at the stop: '
                                 "app_active=false, is_key=false, shown tab terminal, child_window_page null, first responder null, 1 of the "
                                 "app's windows listed, the app's key window null, keyboard given back null): no tab made, no case recorded")
                self.assertEqual((app.window_calls, report["rows"], report["cases"], report["exit_code"]), ([ASK], [], {}, new_surface_screen.STOPPED_EXIT))
                self.assertEqual([call for call in app.names if call in ("frame_strip", "debug.key", "action.run")], [])
                self.assertEqual(printed.splitlines()[-1], f"NEW-SURFACE-SCREEN report only: 0 rows, 0 INVALID, 0 pictures kept; STOPPED {report['stopped']}")
                # The tool reads the app's answer again for a time before it ends the run, and it asks one time only.
                self.assertEqual((report["activation"]["reads"], report["activation"]["seconds"], report["activation"]["form"]),
                                 (new_surface_screen.ACTIVE_READS, 9.8, None))
                self.assertEqual(report["head"][2], THIRD + "50 reads of the app's answer, 9.8 s from the ask to the answer, the key window form: none")
                # The report keeps the read that ended the run, and it has no read after a last case.
                self.assertEqual((report["window"]["before_the_first_case"]["fault"], report["window"]["after_the_last_case"], report["window"]["same"]),
                                 (said, None, None))

    def test_a_window_of_another_size_than_the_launch_asked_ends_the_run(self):
        app = not_active(self.folder)
        app.shell_window["frame"] = {"x": 410.0, "y": 240.0, "width": 1100.0, "height": 720.0}
        report, _ = self.run_mode(app, launched=LAUNCHED, keys="t", gaps="0")
        self.assertIn(NOT_SHOWN + "its frame is 1100 x 720 points, the launch asked for 1200 x 900 (50 reads", report.get("stopped", ""))
        self.assertEqual((report["rows"], app.strips, report["window"]["asked_size"]), ([], 0, [1200.0, 900.0]))
        self.assertEqual(report["window"]["before_the_first_case"]["frame"], {"x": 410.0, "y": 240.0, "width": 1100.0, "height": 720.0})
        # An app that the driver did not launch has no asked size: the report keeps the frame, and the run goes on.
        app = not_active(self.folder)
        app.shell_window["frame"] = {"x": 410.0, "y": 240.0, "width": 1100.0, "height": 720.0}
        report, _ = self.run_mode(app, keys="t", gaps="0")
        self.assertEqual((report.get("stopped"), len(report["rows"]), report["window"]["asked_size"], report["window"]["same"]), (None, 1, None, True))

    def test_a_window_that_is_not_the_same_after_the_last_case_makes_each_row_of_the_take_invalid(self):
        for changed, why in (({"occluded": True}, NOT_SHOWN + "`occluded` is true"),
                             ({"frame": {**FRAME, "x": 700.0}}, "its frame or one of its 3 words is not the one of the read before the first case")):
            with self.subTest(changed=changed):
                app = not_active(self.folder)
                app.changed_after, app.changed = 1, changed
                report, said = self.run_mode(app, launched=LAUNCHED, keys="t,w", gaps="0", close_cases="idle")
                reason = f"window: the read after the last case: {why}: no row of the take says what the screen showed"
                self.assertEqual([row["invalid"] for row in report["rows"]], [[reason]] * 2)
                self.assertEqual((report["window"]["same"], report["window"]["before_the_first_case"], app.strips), (False, WINDOW, 2))
                self.assertEqual(report["window"]["after_the_last_case"], {**WINDOW, **changed, "fault": why if "occluded" in changed else None})
                # Each case's numbers are made again: no row of the take is in one.
                self.assertEqual([(case["n"], case["valid"], case["invalid"]) for case in report["cases"].values()], [(1, 0, ["window"])] * 2)
                lines = said.splitlines()
                self.assertIn(f"NEW-SURFACE-SCREEN WINDOW NOT THE SAME {reason}", lines)
                self.assertTrue(lines[-1].startswith("NEW-SURFACE-SCREEN report only: 2 rows, 2 INVALID, "), lines[-1])
                # A case's line comes again after the read, with its rows INVALID.
                again = [line for line in lines if line.startswith("NEW-SURFACE-SCREEN cmd-t/idle: ")]
                self.assertEqual(len(again), 2)
                self.assertTrue(again[1].endswith(" (AGAIN, after the read of the window after the last case)"), again[1])

    def test_the_hold_is_not_run_in_a_launch_that_gives_no_key_window(self):
        app = not_active(self.folder)
        report, said = self.run_mode(app, launched=LAUNCHED, keys="t,w", gaps="0", close_cases="idle,hold", runs=2)
        why = HOLD_NOT_RUN.format("window shown")
        hold = report["rows"][4:]
        self.assertEqual([(row["label"], row["invalid"], row.get("not_run")) for row in hold],
                         [("cmd-w-hold100-0", [why], True), ("cmd-w-hold100-1", [why], True)])
        # No call to the app for a hold's row: no key sequence, no recording, no tab, and no read before a recording.
        self.assertEqual((app.sequences, app.strips, [name for row in hold for name in row if name in ("app_active", "tabs_before", "frames")]),
                         ([], 4, []))
        self.assertEqual(app.names[len(app.names) - 1 - app.names[::-1].index("frame_strip"):].count("debug.key"), 0)
        self.assertEqual(report["close"]["hold"].get("not_run"), why)
        # The press rows of the run are as they are: 4 valid rows, and the hold's case has 2 rows and no valid one.
        self.assertEqual([row["invalid"] for row in report["rows"][:4]], [[]] * 4)
        case = report["cases"]["cmd-w/100 ms after a hold of the New Tab key (6 key-downs: 1 and 5 repeats with the repeat flag)"]
        self.assertEqual((case["n"], case["valid"], case["invalid"], case["key_window_forms"]), (2, 0, ["hold"], {}))
        self.assertIn("-ROW cmd-w-hold100-1: INVALID " + why, said)
        self.assertEqual(report["head"][0], "the app was active: no (0 of 4 rows, by the app's answer before each recording)")

    def test_a_page_with_the_keys_in_a_key_child_window_of_the_measured_window_is_the_form_page_child(self):
        # (C) the check: an active app, the shell window not key, a page that the window names as the holder of the
        # keys, and the app's list of windows has the key window: a plain child window of the measured window, of
        # the class that `debug.focus` names as the app's key window.
        app = page_app(self.folder)
        report, said = self.run_mode(app, keys="t", gaps="0")
        self.assertIsNone(report.get("stopped"))
        self.assertEqual([(row.get("app_active"), row.get("shell_window_is_key"), row.get("key_window_form"), row["invalid"])
                          for row in report["rows"]], [(True, False, "page child", [])])
        self.assertEqual((report["activation"]["form"], report["activation"]["reads"], report["key_window_form"]), ("page child", 1, "page child"))
        self.assertEqual(report["activation"]["at_the_end"], {
            "key_window_form": "page child", "shown_tab_kind": "terminal", "child_window_page": "page-7", "first_responder": None,
            "app_windows": 1, "app_key_window": "PageWindow", "keyboard_given_back": None})
        self.assertEqual(report["window"]["before_the_first_case"], {**WINDOW, "key_child": "PageWindow"})
        self.assertEqual(report["cases"]["cmd-t/idle"]["key_window_forms"], {"page child": 1})
        self.assertIn(" app_active=True shell_window_is_key=False key_window_form=page child", next(
            line for line in said.splitlines() if "-ROW cmd-t-idle-0" in line))
        self.assertNotIn(base.TITLE, json.dumps(report) + said)

    def test_a_named_page_with_no_proof_of_its_key_child_window_is_the_form_window_shown(self):
        # The window's own word (`appkit.child_window_page`) is a record of the focus, not the key window.
        # `listed`: the class that the tool keeps as the key child window of the measured window in the app's list.
        for name, child, listed in (("no such window in the app's list", None, None),
                                    ("a window that is not the key window", {**CHILD, "key": False}, None),
                                    ("a sheet", {**CHILD, "kind": "sheet"}, None), ("a child of another window", {**CHILD, "parent": 99}, None),
                                    ("a window with no parent", {**CHILD, "parent": None}, None),
                                    ("another class than the app's key window", {**CHILD, "kind": "OtherWindow", "class": "OtherWindow"}, "OtherWindow")):
            with self.subTest(name):
                app = page_app(self.folder, child)
                report, _ = self.run_mode(app, keys="t", gaps="0")
                self.assertEqual([(row.get("app_active"), row.get("shell_window_is_key"), row.get("key_window_form"), row["invalid"])
                                  for row in report["rows"]], [(True, False, "window shown", [])])
                self.assertEqual((report.get("stopped"), report["key_window_form"], report["window"]["before_the_first_case"]["key_child"]),
                                 (None, "window shown", listed))

    def test_a_page_named_in_an_app_that_is_not_active_is_the_form_window_shown(self):
        app = page_app(self.folder)
        app.active = False
        report, _ = self.run_mode(app, keys="t", gaps="0")
        self.assertEqual([(row.get("app_active"), row.get("key_window_form"), row["invalid"]) for row in report["rows"]], [(False, "window shown", [])])

    def test_a_page_named_while_a_second_cmux_window_is_key_ends_the_run(self):
        # 2 windows of the kind `main`: the tool does not know which one the app's list of windows means.
        app = page_app(self.folder)
        app.second_key, app.other_windows = True, [{**app.shell_window, "id": 43, "key": True}]
        report, _ = self.run_mode(app, keys="t", gaps="0")
        self.assertIn("the app lists 2 windows of the kind `main` (debug.window_list)", report.get("stopped", ""))
        self.assertIn('at the stop: app_active=true, is_key=false, shown tab terminal, child_window_page "page-7", first responder null, '
                      "2 of the app's windows listed,", report.get("stopped", ""))
        self.assertEqual((report["rows"], app.strips), ([], 0))

    def test_a_hold_with_the_keys_in_a_page_child_window_is_not_run(self):
        # A hold's sequence goes to the shell window as the key window: in each other form its rows are not run.
        app = page_app(self.folder)
        report, _ = self.run_mode(app, keys="t,w", gaps="0", close_cases="hold")
        row = report["rows"][1]
        self.assertEqual((row["invalid"], row.get("not_run"), app.sequences), ([HOLD_NOT_RUN.format("page child")], True, []))

    def test_an_app_that_lists_no_window_ends_the_run_with_no_ask(self):
        app = App(self.folder)
        app.windows = False
        report, _ = self.run_mode(app, keys="t", gaps="0")
        self.assertEqual(report.get("stopped"), "active: the app lists no window (debug.focus): no tab made, no case recorded")
        self.assertEqual((app.window_calls, report["rows"], app.strips, report.get("window")), ([], [], 0, None))
        self.assertEqual(report["head"][2], THIRD + "not made")

    def test_a_row_whose_read_lists_no_window_has_no_form_and_is_invalid(self):
        app = not_active(self.folder)
        app.gone_after = 1  # after the first recording the app lists no window
        report, said = self.run_mode(app, keys="t", gaps="0", runs=2)
        rows = report["rows"]
        self.assertEqual([(row["label"], row.get("key_window_form")) for row in rows], [("cmd-t-idle-0", "window shown"), ("cmd-t-idle-1", None)])
        self.assertEqual((rows[0]["invalid"], rows[1]["invalid"]), ([], [
            "form: directly before the recording the app listed no window (debug.focus): the row has no key window form"]))
        self.assertEqual(report["cases"]["cmd-t/idle"]["key_window_forms"], {"None": 1, "window shown": 1})
        self.assertIn("-ROW cmd-t-idle-1: INVALID form: ", said)

    def test_the_seconds_of_the_ask_are_to_the_apps_answer_and_have_no_time_of_the_read_of_the_windows(self):
        app = not_active(self.folder)
        app.list_s = 5.0
        report, _ = self.run_mode(app, keys="t", gaps="0")
        self.assertEqual((report["activation"]["reads"], report["activation"]["seconds"], len(report["rows"])), (1, 0.0, 1))

    def test_a_hold_in_an_app_that_is_not_active_again_is_invalid_and_in_another_case_it_is_a_fact(self):
        app = App(self.folder)
        app.lost_after = 1  # after the first recording the app is not active
        report, said = self.run_mode(app, keys="t,w", gaps="0", close_cases="idle,hold")
        rows = report["rows"]
        self.assertEqual([(row["label"], row.get("app_active"), row.get("shell_window_is_key"), row.get("key_window_form")) for row in rows],
                         [("cmd-t-idle-0", True, True, "shell"), ("cmd-w-idle-0", False, False, "window shown"),
                          ("cmd-w-hold100-0", False, False, "window shown")])
        self.assertEqual((rows[0]["invalid"], rows[1]["invalid"]), ([], []))
        self.assertEqual(rows[2]["invalid"], ["active: directly before the recording the app says app_active=false and its window says "
                                              "is_key=false: a hold's keys go to the key window of an active app"])
        self.assertEqual(len(app.window_calls), 1)  # no second ask: the row says what the app was
        self.assertEqual(report["head"][0], "the app was active: NOT IN EACH ROW (1 of 3 rows, by the app's answer before each recording)")
        # Rows of 2 forms are 2 states: the head says so beside the form of the run's first read.
        self.assertEqual(report["head"][2], THIRD + "1 reads of the app's answer, 0 s from the ask to the answer, the key window form: shell "
                                            "(NOT IN EACH ROW: 2 of 3 rows have another form or none; rows of 2 forms are 2 states, no pair)")
        line = next(line for line in said.splitlines() if "-ROW cmd-w-idle-0" in line)
        self.assertIn(" app_active=False shell_window_is_key=False", line)

    def test_a_hold_that_the_app_refused_in_an_app_that_is_not_active_again_says_both(self):
        app = App(self.folder)
        app.lost_after = 1
        app.refuse_sequence = "the shell window did not become key"
        report, _ = self.run_mode(app, keys="t,w", gaps="0", close_cases="hold")
        row = report["rows"][1]
        self.assertEqual((len(row["invalid"]), row["invalid"][0].split(":")[0], row.get("app_active")), (2, "active", False))
        self.assertEqual(row["invalid"][1], 'input: the app refused the hold\'s key sequence: "the shell window did not become key"')


if __name__ == "__main__":
    unittest.main()

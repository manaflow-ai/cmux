#!/usr/bin/env python3
"""new_surface_screen.py `--key-tabs`: the count of tabs of the key's workspace before a case, by the app's own list.

No app, no display, no fleet: the app is test_close_tab_screen.py's function with one pane's tabs, and here it also
takes the script actions that make a tab beside a named tab, lists a new tab under a provisional id for some reads,
and has a window that can become the key window. So this proves what the tool asks, in which order, how it counts
and what its report says, not that an app makes those tabs, nor what a key costs in a workspace of that many tabs.

    python3 -I scripts/cmux-next/tests/test_key_tabs_screen.py
"""
import argparse
import contextlib
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # the imports leave no cache folder in the checkout
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_close_tab_screen as close  # noqa: E402

base, new_surface_screen = close.base, close.new_surface_screen
KINDS = {"newSurface": "terminal", "openBrowser.chromium": "browser", "openBrowser.webkit": "browser"}
HOLD = "cmd-w/100 ms after a hold of the New Tab key (6 key-downs: 1 and 5 repeats with the repeat flag)"


class KeyTabsApp(close.CloseApp):
    """The app of the Close Tab tests, whose window has 2 panes: the key's pane with one terminal tab, and another
    pane with one terminal tab. A script action with a tab target makes a tab in that tab's pane and shows it."""

    def __init__(self, folder, **more):
        super().__init__(folder, **more)
        self.actions, self.window_calls, self.order = [], [], []  # each action, each window call, the calls' order
        self.is_key, self.takes_key = False, True  # the shell window is the key window; it becomes it when asked
        # `refuse_from`: the app refuses each action from this number on. `unlisted`: the numbers of the actions that
        # the app takes and whose tab it never lists. `provisional_reads`: the reads of the list in which a new tab
        # has its provisional id (`pending`: the reads that are left for a tab).
        self.refuse_from, self.unlisted, self.provisional_reads, self.pending = None, set(), 0, {}

    def listed(self, name):
        return f"pending_tab_{name}" if self.pending.get(name) else name

    def rpc(self, method, params=None, timeout=30):
        params = params or {}
        action = params.get("action")
        if method == "debug.focus":
            mine = {"pane": "pane-1", "selected": self.listed(self.shown),
                    "tabs": [f"{self.listed(name)}:{self.kinds[name]}" for name in self.ids]}
            other = {"pane": "pane-0", "selected": "far-0", "tabs": ["far-0:terminal"]}
            self.pending = {name: left - 1 for name, left in self.pending.items() if left > 1}
            window = {"id": "window-1", "is_key": self.is_key, "model": {"pane": "pane-1"}, "topology": [other, mine]}
            return {"windows": [window] if self.focus else []}
        if method == "debug.window.focus":
            self.window_calls.append(params)
            self.order.append("window")
            self.is_key = self.takes_key
            return {"key": "window-1" if self.is_key else None, "front": "window-1"}
        if method == "action.run":
            self.actions.append(params)
            self.order.append("action")
            target = str(params.get("target"))
            if self.refuse_from and len(self.actions) >= self.refuse_from:
                return {"error": {"code": "invalid_params", "message": "refused"}}
            if not target.startswith("tab:") or target[4:] not in self.ids or self.pending.get(target[4:]):
                return {"error": {"code": "invalid_params", "message": f"No tab matches {target}"}}
            if len(self.actions) in self.unlisted:
                return {}
            self.open(KINDS[action])
            if self.provisional_reads:
                self.pending[self.shown] = self.provisional_reads
            return {}
        if action == "frame_strip":
            self.order.append("strip")
        if action == "frame_strip" and params.get("key") == "t":
            # One New Tab key: a new tab in the key's pane, and a recording whose first frame is its last picture.
            self.strips += 1
            self.asked.append(params)
            self.open("newTab")
            self.openings.append({"spare": True, "ms": 1000.0 + len(self.openings)})
            reply = base.take([(base.NEW, base.ROW_NEW)] * 240, spans=[{"name": "newTab.open", "ms": 0.0, "duration_ms": 1.0}])
            os.makedirs(params["dir"], exist_ok=True)
            for frame in reply["frames"]:
                Path(params["dir"], frame["file"]).write_bytes(b"png")
            return reply
        return super().rpc(method, params, timeout)


def options(folder, **changed):
    return close.options(folder, **{**dict(keys="t,w", gaps="0", close_cases="idle,hold", key_tabs=[6, 84]), **changed})


class KeyTabsTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="key-tabs-screen-test-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.folder, ignore_errors=True))

    def run_mode(self, app, **changed):
        def make(socket_path, count, live, url, deadline, out):
            return {"asked_more": count, "live_shells": live, "maker_exit": 0, "maker_said_made": count, "seed_s": 0.0}
        screen = new_surface_screen.Screen(options(self.folder, **changed), app.rpc, app.tools(), sleep=app.pause, make_session=make,
                                           clock=app.clock, start=app.start)
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report = screen.run()
        self.assertIn("key_tabs", report, "new_surface_screen.py has no `--key-tabs`: the report says no count of the key's workspace's tabs")
        return report, said.getvalue()

    def test_the_tool_makes_the_keys_workspace_each_asked_count_of_tabs_and_half_of_them_are_pages(self):
        app = KeyTabsApp(self.folder)
        report, _ = self.run_mode(app)
        # The window has 2 terminal tabs at first. A page while the pages are less than half of the tabs, else a terminal.
        names = [params["action"] for params in app.actions]
        self.assertEqual(names[:4], ["openBrowser.chromium", "openBrowser.chromium", "newSurface", "openBrowser.chromium"])
        self.assertEqual((len(names), names.count("openBrowser.chromium"), names.count("newSurface")), (82, 42, 40))
        # Each action names the tab that it opens beside (the pane's shown tab), as a script, with the session's page address.
        self.assertEqual(app.actions[0], {"action": "openBrowser.chromium", "args": {"url": "http://127.0.0.1:9/"}, "focus": True,
                                          "origin": "script", "target": "tab:tab-0"})
        self.assertEqual(app.actions[2], {"action": "newSurface", "args": {}, "focus": True, "origin": "script", "target": "tab:tab-2"})
        sizes = report["key_tabs"]["sizes"]
        self.assertEqual([(size["asked"], size["tabs"], size["kinds"], size["panes"], size["added"], size["fault"]) for size in sizes],
                         [(6, 6, {"terminal": 3, "browser": 3}, 2, {"page": 3, "terminal": 1}, None),
                          (84, 84, {"terminal": 42, "browser": 42}, 2, {"page": 39, "terminal": 39}, None)])
        # Each case one time for each count, the smaller count first: the name and the label say the count that the app listed.
        self.assertEqual(list(report["cases"]), [f"{case}, {count} tabs in the key's workspace before the case"
                                                 for count in (6, 84) for case in ("cmd-t/idle", "cmd-w/idle", HOLD)])
        rows = report["rows"]
        self.assertEqual([row["label"] for row in rows], [f"cmd-{case}-tabs{count}-0" for count in (6, 84) for case in ("t-idle", "w-idle", "w-hold100")])
        self.assertEqual([row["invalid"] for row in rows], [[]] * 6)
        self.assertEqual([row["key_tabs"] for row in rows], [{"asked": 6, "had": 6}] * 3 + [{"asked": 84, "had": 84}] * 3)
        # At the key the workspace also has the case's own tabs: Control-`'s terminal tab, and the idle close's New Tab page.
        self.assertEqual([row["workspace_tabs_before"] for row in rows], [7, 8, 7, 85, 86, 85])
        self.assertEqual(rows[1]["workspace_kinds_before"], {"terminal": 4, "browser": 3, "newTab": 1})
        self.assertEqual(report["cases"][f"cmd-w/idle, 84 tabs in the key's workspace before the case"]["key_tabs"],
                         {"asked": 84, "had": 84, "workspace_tabs_before": {"min": 86, "max": 86}, "shell_window_is_key": {"yes": 1, "of": 1}})
        # Each case's own tabs are closed again, and no made tab: the key's pane has 83 of the 84 tabs.
        self.assertEqual(len(app.ids), 83)

    def test_the_report_says_the_count_that_the_app_had_and_not_the_count_asked(self):
        app = KeyTabsApp(self.folder)
        app.refuse_from = 3
        report, _ = self.run_mode(app, keys="t")
        sizes = report["key_tabs"]["sizes"]
        self.assertEqual([(size["asked"], size["tabs"], size["added"]) for size in sizes],
                         [(6, 4, {"page": 2, "terminal": 0}), (84, 4, {"page": 0, "terminal": 0})])
        self.assertTrue(sizes[0]["fault"].startswith("the app refused newSurface: "), sizes[0]["fault"])
        self.assertEqual(list(report["cases"]), ["cmd-t/idle, 4 tabs in the key's workspace before the case (6 asked)",
                                                 "cmd-t/idle, 4 tabs in the key's workspace before the case (84 asked)"])
        rows = report["rows"]
        self.assertEqual([row["label"] for row in rows], ["cmd-t-idle-tabs4of6-0", "cmd-t-idle-tabs4of84-0"])
        self.assertEqual([row["key_tabs"] for row in rows], [{"asked": 6, "had": 4}, {"asked": 84, "had": 4}])
        for row, asked in zip(rows, (6, 84)):
            self.assertEqual(len(row["invalid"]), 1, row["invalid"])
            self.assertTrue(row["invalid"][0].startswith(f"key-tabs: {asked} tabs asked, the app lists 4 (the app refused newSurface: "), row["invalid"])

    def test_a_made_tab_that_the_app_does_not_list_ends_the_making_and_the_rows_say_it(self):
        app = KeyTabsApp(self.folder)
        app.unlisted = {2}
        report, _ = self.run_mode(app, keys="t", key_tabs=[6])
        size = report["key_tabs"]["sizes"][0]
        self.assertEqual((size["tabs"], size["fault"], len(app.actions)), (3, "no new tab in the app's list 30 s after openBrowser.chromium", 2))
        self.assertEqual(report["rows"][0]["invalid"],
                         ["key-tabs: 6 tabs asked, the app lists 3 (no new tab in the app's list 30 s after openBrowser.chromium)"])

    def test_a_tab_with_a_provisional_id_is_no_made_tab_yet_and_no_target(self):
        app = KeyTabsApp(self.folder)
        app.provisional_reads = 2
        report, _ = self.run_mode(app, keys="t", key_tabs=[6])
        self.assertEqual([params["target"] for params in app.actions], ["tab:tab-0", "tab:tab-1", "tab:tab-2", "tab:tab-3"])
        size = report["key_tabs"]["sizes"][0]
        self.assertEqual((size["tabs"], size["fault"], report["rows"][0]["invalid"]), (6, None, []))

    def test_the_shell_window_is_made_the_key_window_before_the_first_tab_and_each_row_says_what_it_was(self):
        app = KeyTabsApp(self.folder)
        report, _ = self.run_mode(app, key_tabs=[6], close_cases="idle")
        self.assertEqual((app.window_calls, app.order[0], app.order.count("window")), ([{"window": "window-1"}], "window", 1))
        self.assertEqual(report["key_tabs"]["key_window"], {"by": "debug.window.focus", "window": "window-1",
                                                            "reply": {"key": "window-1", "front": "window-1"}})
        self.assertEqual([row["shell_window_is_key"] for row in report["rows"]], [True, True])
        # A window that did not become the key window is a fact of each row, and no fault of it.
        other = KeyTabsApp(self.folder)
        other.takes_key = False
        report, _ = self.run_mode(other, key_tabs=[6], close_cases="idle")
        self.assertEqual([(row["shell_window_is_key"], row["invalid"]) for row in report["rows"]], [(False, []), (False, [])])
        self.assertEqual(report["cases"]["cmd-w/idle, 6 tabs in the key's workspace before the case"]["key_tabs"]["shell_window_is_key"],
                         {"yes": 0, "of": 1})

    def test_a_rows_line_and_a_counts_line_say_the_tabs(self):
        _, said = self.run_mode(KeyTabsApp(self.folder), keys="t", key_tabs=[6])
        row = next(line for line in said.splitlines() if "-ROW cmd-t-idle-tabs6-0" in line)
        self.assertIn(" workspace_tabs_before=7 shell_window_is_key=True", row)
        size = next(line for line in said.splitlines() if line.startswith("NEW-SURFACE-SCREEN-KEY-TABS "))
        self.assertIn('"asked": 6', size)
        self.assertIn('"tabs": 6', size)

    def test_without_the_argument_the_tool_makes_no_tab_and_asks_for_no_key_window(self):
        app = KeyTabsApp(self.folder)
        screen = new_surface_screen.Screen(options(self.folder, key_tabs=[], close_cases="idle"), app.rpc, app.tools(), sleep=app.pause,
                                           make_session=lambda *asked: {}, clock=app.clock, start=app.start)
        with contextlib.redirect_stdout(io.StringIO()):
            report = screen.run()
        self.assertEqual((app.actions, app.window_calls), ([], []))
        self.assertEqual((list(report["cases"]), [row["label"] for row in report["rows"]]), (["cmd-t/idle", "cmd-w/idle"], ["cmd-t-idle-0", "cmd-w-idle-0"]))
        self.assertNotIn("key_tabs", report)
        self.assertEqual([name for row in report["rows"] for name in row if name in ("key_tabs", "workspace_tabs_before", "shell_window_is_key")], [])

    def test_the_argument_is_counts_that_rise(self):
        self.assertTrue(hasattr(new_surface_screen, "key_tabs"), "new_surface_screen.py has no `key_tabs`: the mode has no `--key-tabs`")
        parser = argparse.ArgumentParser()
        new_surface_screen.add_arguments(parser)
        self.assertEqual((parser.parse_args([]).key_tabs, parser.parse_args(["--key-tabs=6,84"]).key_tabs), ([], [6, 84]))
        for bad in ("84,6", "6,6", "0", "six", ","):
            with self.subTest(bad), self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                parser.parse_args([f"--key-tabs={bad}"])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""scripts/ci/launch_tti_check.py's pure parts: the round plan and the terminal reading from the typing probe's rows.

The terminal's interaction is the first complete probe row's echo frame (contents_ms) put on the launch clock: its
event_uptime_ns less the process start on the same clock, plus contents_ms. A row that never completed (closed by a
later key) gives no echo, and the first key the app wrote toward the pty (socket_submit_ms) is `accepted_ms`.
"""
from __future__ import annotations

import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import launch_tti_check as tti  # noqa: E402


class PlanTests(unittest.TestCase):
    def test_default_plan_has_install_update_warm_and_warm60_for_both_fronts(self):
        plan = tti.parse_plan(tti.DEFAULT_PLAN)
        self.assertEqual({(k, f) for k in tti.KINDS for f in tti.FRONTS}, set(plan))

    def test_unknown_kind_or_front_is_refused(self):
        for bad in ("hot:chat", "cold_install:home", "", "cold"):
            with self.assertRaises(ValueError, msg=bad):
                tti.parse_plan(bad)

    def test_staged_prewarm_plan_matches_the_updater_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "cmux.app"
            contents = app / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            (contents / "Resources" / "bin").mkdir(parents=True)
            (contents / "Frameworks" / "cmux Helper (GPU).app" / "Contents" / "MacOS").mkdir(parents=True)
            (contents / "Frameworks" / "cmux Helper (Renderer).app" / "Contents" / "MacOS").mkdir(parents=True)
            with open(contents / "Info.plist", "wb") as handle:
                plistlib.dump({"CFBundleExecutable": "cmux"}, handle)
            paths = [contents / "MacOS" / "cmux", contents / "Resources" / "bin" / "cmux",
                     contents / "Resources" / "bin" / "cmux-tui",
                     contents / "Frameworks" / "cmux Helper (GPU).app" / "Contents" / "MacOS" / "cmux Helper (GPU)",
                     contents / "Frameworks" / "cmux Helper (Renderer).app" / "Contents" / "MacOS" / "cmux Helper (Renderer)"]
            for path in paths:
                path.write_bytes(b"x")
                path.chmod(0o755)
            plan = tti.staged_prewarm_plan(app)
            self.assertEqual([(path.name, args) for path, args in plan], [
                ("cmux", ["--cmux-prewarm-launch"]), ("cmux", ["--version"]), ("cmux-tui", ["--version"]),
                ("cmux Helper (GPU)", ["--version"]), ("cmux Helper (Renderer)", ["--version"]),
                ("cmux", ["--cmux-prewarm-chromium"]),
            ])


class TerminalReadingTests(unittest.TestCase):
    START = 1_000_000_000_000  # process start, ns on CLOCK_UPTIME_RAW

    def row(self, at_ms, complete, submit="", contents=""):
        return {"event_uptime_ns": str(self.START + int(at_ms * 1e6)), "complete": complete,
                "socket_submit_ms": submit, "io_write_ms": "", "contents_ms": contents}

    def test_first_complete_row_gives_the_echo_on_the_launch_clock(self):
        rows = [self.row(900, "false"), self.row(940, "false", submit="3.0"), self.row(980, "true", "2.5", "12.0")]
        self.assertEqual({"accepted_ms": 943.0, "input_ms": 992.0}, tti.terminal_reading(rows, self.START))

    def test_no_complete_row_is_no_echo(self):
        rows = [self.row(900, "false", submit="2.0")]
        self.assertEqual({"accepted_ms": 902.0, "input_ms": None}, tti.terminal_reading(rows, self.START))

    def test_unknown_process_start_reads_nothing(self):
        self.assertEqual({"accepted_ms": None, "input_ms": None},
                         tti.terminal_reading([self.row(1, "true", "1", "2")], None))

    def test_split_names_the_time_before_main_apart_from_ours(self):
        self.assertEqual({"premain_ms": 573.0, "ours_ms": 497.0}, tti.split(1070.0, 573.0))
        self.assertEqual({"premain_ms": None, "ours_ms": None}, tti.split(1070.0, None))


class InAppPathTests(unittest.TestCase):
    """A runner without the PostEvent grant (post_access false) still measures the terminal: the app types its own key
    at its first frame (CMUX_NEXT_LAUNCH_TYPE_PROBE=1) and its launch marks time the key's echo."""

    MARKS = {"main_start": 210.0, "first_window_frame_committed": 640.0, "terminal.probe_key_typed": 641.0,
             "terminal_input_accepted": 655.5, "terminal_echo": 702.3}

    def test_no_grant_types_in_the_app_and_a_grant_posts(self):
        self.assertEqual("in_app", tti.input_path(False))
        self.assertEqual("posted", tti.input_path(True))
        self.assertEqual("in_app", tti.input_path(True, "in_app"))
        self.assertEqual("posted", tti.input_path(False, "posted"))
        env = tti.launch_env({"HOME": "/h"}, Path("/p.csv"), "in_app")
        self.assertEqual("1", env[tti.TYPE_PROBE_VARIABLE])
        self.assertEqual("/p.csv", env["CMUX_NEXT_TYPING_PROBE"])
        self.assertNotIn(tti.TYPE_PROBE_VARIABLE, tti.launch_env({"HOME": "/h"}, Path("/p.csv"), "posted"))

    def test_no_grant_terminal_round_is_measured_from_the_marks(self):
        reading = tti.in_app_terminal_reading(self.MARKS)
        self.assertEqual({"accepted_ms": 655.5, "input_ms": 702.3}, reading)
        row = {"post_access": False, "input": "in_app", **reading}
        self.assertEqual([], tti.round_failures("terminal", "in_app", row, self.MARKS, 30))

    def test_no_key_window_fails_the_round_and_says_so(self):
        marks = {"first_window_frame_committed": 640.0, "terminal.probe_no_key_window": 641.0}
        row = {"post_access": False, **tti.in_app_terminal_reading(marks)}
        self.assertIsNone(row["input_ms"])
        [why] = tti.round_failures("terminal", "in_app", row, marks, 30)
        self.assertIn("probe_no_key_window", why)

    def test_chat_without_the_composer_mark_fails_nothing_on_either_path(self):
        for path in ("posted", "in_app"):
            row = {"post_access": path == "posted", "input_ms": None, "no_mark": True}
            self.assertEqual([], tti.round_failures("chat", path, row, {}, 30))

    def test_posted_path_without_the_grant_still_fails(self):
        row = {"post_access": False, "input_ms": None}
        self.assertTrue(any("may not post keys" in f for f in tti.round_failures("terminal", "posted", row, {}, 30)))


class InputMarkTests(unittest.TestCase):
    def test_the_mark_is_decided_from_the_bundles_page_scripts(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "cmux.app"
            pages = app / "Contents" / "Resources" / "webviews" / "assets"
            pages.mkdir(parents=True)
            (pages / "pane.js").write_bytes(b"post('pane.painted', {})")
            self.assertFalse(tti.bundle_has_input_mark(app))
            (pages / "composer-chunk.js").write_bytes(b"x.post(\"pane.inputEchoed\")")
            self.assertTrue(tti.bundle_has_input_mark(app))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""scripts/ci/launch_tti_check.py's pure parts: the round plan and the terminal reading from the typing probe's rows.

The terminal's interaction is the first complete probe row's echo frame (contents_ms) put on the launch clock: its
event_uptime_ns less the process start on the same clock, plus contents_ms. A row that never completed (closed by a
later key) gives no echo, and the first key the app wrote toward the pty (socket_submit_ms) is `accepted_ms`.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import launch_tti_check as tti  # noqa: E402


class PlanTests(unittest.TestCase):
    def test_default_plan_has_cold_warm_and_warm60_for_both_fronts(self):
        plan = tti.parse_plan(tti.DEFAULT_PLAN)
        self.assertEqual({(k, f) for k in tti.KINDS for f in tti.FRONTS}, set(plan))

    def test_unknown_kind_or_front_is_refused(self):
        for bad in ("hot:chat", "cold:home", "", "cold"):
            with self.assertRaises(ValueError, msg=bad):
                tti.parse_plan(bad)


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


if __name__ == "__main__":
    unittest.main()

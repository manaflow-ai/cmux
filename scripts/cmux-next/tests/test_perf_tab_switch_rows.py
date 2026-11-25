#!/usr/bin/env python3
"""perf-budgets.py's tab-switch rows read only the scenario's own kind (cmux#24569).

tab-switch-matrix.py files each switch under the kind `debug.tab_switch` tagged: the content it showed, `cold`
(the tab's surface was not alive, so the pane emptied first) or `?` (untagged). From 2026-11-15 the terminal
scenario's switches came out `cold`, and the row read that bucket: the time to an empty pane, not to the terminal.
"""
import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("perf_budgets", ROOT / "scripts/cmux-next/perf-budgets.py")
pb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pb)


def stat(p50, p95):
    return {"p50": p50, "p90": p95, "p95": p95, "max": p95}


def scenario(kind, table):
    return {"kind": kind, "count": 10, "ctrl_tab": {"table": table}}


class TabSwitchRowTests(unittest.TestCase):
    def test_terminal_row_skips_the_cold_bucket(self):
        rep = {"scenarios": [scenario("terminal", {"cold": {"e2e": stat(12.23, 27.81)},
                                                   "terminal": {"e2e": stat(22.75, 25.18)}})]}
        self.assertEqual(pb.rows_tab_switch(rep)["tab_switch.terminal.10.e2e"], (22.75, 25.18))

    def test_a_scenario_without_its_own_bucket_has_no_value(self):
        # Every switch cold or untagged: no terminal switch was timed, so the row is incomplete, not 12.23.
        rep = {"scenarios": [scenario("terminal", {"?": {"e2e": stat(11.0, 20.0)},
                                                   "cold": {"e2e": stat(12.23, 27.81)}})]}
        self.assertEqual(pb.rows_tab_switch(rep)["tab_switch.terminal.10.e2e"], (None, None))

    def test_chromium_row_skips_the_workspace_terminal(self):
        # A chromium scenario's pane also holds the workspace's first terminal: its switches are not chromium ones.
        rep = {"scenarios": [scenario("chromium", {"chromium": {"e2e": stat(14.71, 21.63)},
                                                   "cold": {"e2e": stat(9.0, 30.0)},
                                                   "terminal": {"e2e": stat(30.0, 40.0)}})]}
        self.assertEqual(pb.rows_tab_switch(rep)["tab_switch.chromium.10.e2e"], (14.71, 21.63))

    def test_a_flat_table_still_reads(self):
        rep = {"scenarios": [scenario("terminal", {"e2e": stat(20.0, 24.0)})]}
        self.assertEqual(pb.rows_tab_switch(rep)["tab_switch.terminal.10.e2e"], (20.0, 24.0))


if __name__ == "__main__":
    unittest.main()

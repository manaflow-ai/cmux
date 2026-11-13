#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("workspace_scaling", ROOT / "scripts/cmux-next/workspace-scaling-bench.py")
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)


class WorkspaceScalingTests(unittest.TestCase):
    def test_percentiles_include_p99(self):
        result = bench.stats([1, 2, 3, 4, 5])
        self.assertEqual(result["p50"], 3.0)
        self.assertEqual(result["p95"], 4.8)
        self.assertEqual(result["p99"], 4.96)

    def test_warning_is_advisory_above_ten_percent(self):
        rows = [{"interaction": "sidebar_scroll", "workspaces": 100, "p95": 10},
                {"interaction": "sidebar_scroll", "workspaces": 1000, "p95": 11.1}]
        warning = bench.scaling_warnings(rows)
        self.assertEqual(len(warning), 1)
        self.assertEqual(warning[0]["baseline_workspaces"], 100)
        self.assertEqual(warning[0]["ratio"], 1.11)

    def test_flat_ratio_has_no_warning(self):
        rows = [{"interaction": "type", "workspaces": 1, "p95": 10},
                {"interaction": "type", "workspaces": 1000, "p95": 11}]
        self.assertEqual(bench.scaling_warnings(rows), [])

    def test_incomplete_probe_does_not_publish_rows(self):
        rows = bench.collect({1: {"invalid_probes": ["typing"], "typing": {"phases": []}}})
        self.assertFalse(any(row["interaction"] == "type" for row in rows))

    def test_all_missed_instant_samples_are_incomplete(self):
        report = {
            "summary": {"idle@1ws/new_workspace": {"visible_p50": None, "visible_p95": None}},
            "runs": [{"phase": "idle@1ws", "command": "new_workspace", "visible_ms": None}],
        }
        self.assertEqual(bench.instant_rows(report, 1), {})
        failures = bench.coverage_failures(bench.collect({1: {"instant": report}}))
        self.assertEqual(failures[0]["workspaces"], 1)
        self.assertIn("new_workspace", failures[0]["missing"])

    def test_summary_without_p95_is_incomplete(self):
        report = {"summary": {"idle@1ws/new_workspace": {"visible_p50": 3.0}}}
        self.assertEqual(bench.instant_rows(report, 1), {})

    def test_mixed_instant_samples_are_incomplete(self):
        report = {
            "summary": {"idle@1ws/new_workspace": {"visible_p50": 3.0, "visible_p95": 4.0, "missed": 1}},
            "runs": [
                {"phase": "idle@1ws", "command": "new_workspace", "visible_ms": 3.0},
                {"phase": "idle@1ws", "command": "new_workspace", "visible_ms": None},
            ],
        }
        self.assertEqual(bench.instant_rows(report, 1), {})

    def test_switch_uses_real_two_row_baseline(self):
        rows = [{"interaction": "switch", "workspaces": 100, "p95": 10},
                {"interaction": "switch", "workspaces": 1000, "p95": 11.1}]
        warning = bench.scaling_warnings(rows)
        self.assertEqual(warning[0]["baseline_workspaces"], 100)

    def test_sidebar_rows_reject_incomplete_frame_capture(self):
        report = {"sizes": {"100": {"scroll": {"frames": {
            "intervals_ms": [8.3], "frame_metrics": {"complete": False}}}}}}
        self.assertNotIn("sidebar_scroll", bench.sidebar_rows(report, 100))

    def test_single_workspace_switch_is_explicitly_undefined(self):
        rows = bench.collect({1: {"instant": {}, "sidebar": {}, "typing": {}}})
        switch = next(row for row in rows if row["interaction"] == "switch")
        self.assertEqual(switch["status"], "undefined")
        self.assertIsNone(switch["p95"])

    def test_empty_report_replay_is_incomplete(self):
        failures = bench.coverage_failures(bench.collect({1: {}, 100: {}, 1000: {}}))
        self.assertEqual([failure["workspaces"] for failure in failures], [1, 100, 1000])
        self.assertIn("new_workspace", failures[0]["missing"])

    def test_one_workspace_sidebar_is_undefined_without_probe_rows(self):
        rows = bench.collect({1: {"instant": {}, "typing": {}, "sidebar": {}}})
        sidebar = {row["interaction"]: row for row in rows if row["workspaces"] == 1}
        self.assertEqual(sidebar["sidebar_scroll"]["status"], "undefined")
        self.assertEqual(sidebar["switch"]["status"], "undefined")

    def test_non_object_probe_report_is_treated_as_missing(self):
        rows = bench.collect({1: {"instant": [], "sidebar": "bad", "typing": 3}})
        failures = bench.coverage_failures(rows)
        self.assertTrue(any(failure["workspaces"] == 1 for failure in failures))

    def test_malformed_nested_report_is_treated_as_missing(self):
        rows = bench.collect({1: {"instant": {"summary": "bad"},
                                  "sidebar": {"sizes": []},
                                  "typing": {"phases": ["bad"]}}})
        failures = bench.coverage_failures(rows)
        self.assertTrue(any(failure["workspaces"] == 1 for failure in failures))

    def test_raw_sidebar_report_replays_bootstrap_offset(self):
        report = {"sizes": {"99": {"scroll": {"frames": {
            "intervals_ms": [8.3], "frame_metrics": {"complete": True}},
            "switch": {"frames": {"frame_metrics": {"complete": True}},
                       "click_to_idle_ms": {"p50": 8, "p95": 9, "p99": 9}}}}}}
        rows = bench.collect({100: {"sidebar": report}})
        self.assertEqual({row["interaction"] for row in rows}, {"sidebar_scroll", "switch"})



import json  # noqa: E402
import sys  # noqa: E402
import tempfile  # noqa: E402

sys.path.insert(0, str(ROOT / "scripts/cmux-next"))
import bench_launch  # noqa: E402


class FakeTopology:
    """snapshot.get's workspace ids, with close-all-in-all-windows as the app runs it: every workspace but the home
    workspace closes (home_not_closable), and a run with nothing to close is refused."""

    def __init__(self, ids, home="ws-home", fail=False):
        self.ids, self.home, self.fail = list(ids), home, fail

    def read_ids(self):
        return list(self.ids)

    def close_all(self):
        if self.fail:
            return 1
        closable = [ws for ws in self.ids if ws != self.home]
        if not closable:
            return 1  # "nothing to close"
        self.ids = [ws for ws in self.ids if ws == self.home]
        return 0


class CloseAllWorkspacesTests(unittest.TestCase):
    """cmux#24569: workspace-scaling's instant probe exited 1 and its typing probe 2 at every size, because both
    waited for zero workspaces after close-all while the home workspace never closes."""

    def close(self, topology):
        clock = iter(range(1000))
        return bench_launch.close_all_workspaces(topology.read_ids, topology.close_all, settle=30, step=1,
                                                 clock=lambda: next(clock), sleep=lambda _s: None)

    def test_home_workspace_stays_and_is_not_counted(self):
        kept, done = self.close(FakeTopology(["ws-home", "ws-1", "ws-2"]))
        self.assertTrue(done)
        self.assertEqual(kept, frozenset({"ws-home"}))

    def test_only_home_left_is_a_done_close(self):
        kept, done = self.close(FakeTopology(["ws-home"]))
        self.assertTrue(done)
        self.assertEqual(kept, frozenset({"ws-home"}))

    def test_a_failed_close_of_real_workspaces_is_not_done(self):
        _kept, done = self.close(FakeTopology(["ws-home", "ws-1"], fail=True))
        self.assertFalse(done)


class WaitForCountTests(unittest.TestCase):
    """cmux#24569: the instant probe read snapshot.get once right after its last `workspace create` and stopped two
    short ("workspaces: 1 -> 98", "could not reach 100 workspaces (have 98)"): the published topology lags the
    daemon's replies."""

    def wait(self, counts, target):
        reads, clock = iter(counts), iter(range(1000))
        return bench_launch.wait_for_count(lambda: next(reads), target, settle=30, step=1,
                                           clock=lambda: next(clock), sleep=lambda _s: None)

    def test_lagging_topology_reaches_the_target(self):
        self.assertEqual(self.wait([98, 99, 100], 100), 100)

    def test_a_count_that_never_arrives_ends_at_the_deadline(self):
        self.assertEqual(self.wait([98] * 100, 100), 98)

    def test_probes_wait_for_their_seeded_count(self):
        """The typing probe exited 2 with actual_workspace_count 99 of 100 and 998 of 1000 after the instant probe's
        fix: its seeding read the count once too. Both probes run at import (argparse, the app), so this reads their
        source for the wait on `workspace_count`."""
        import ast
        for script in ("instant-new-surfaces-bench.py", "automation-typing-bench.py"):
            tree = ast.parse((ROOT / "scripts/cmux-next" / script).read_text())
            waits = [node for node in ast.walk(tree) if isinstance(node, ast.Call)
                     and getattr(node.func, "id", None) == "wait_for_count"
                     and node.args and getattr(node.args[0], "id", None) == "workspace_count"]
            self.assertTrue(waits, script)


class SidebarRowMismatchTests(unittest.TestCase):
    def test_short_list_names_the_failed_creates(self):
        report = {"sizes": {"999": {"rows_listed": 999, "create_failures": ["ws 0412"]}}}
        record = bench.sidebar_row_mismatch(report, 999, 1000)
        self.assertEqual(record["measured_rows"], 999)
        self.assertEqual(record["create_failures"], ["ws 0412"])
        self.assertEqual(record["create_failure_count"], 1)

    def test_full_list_is_no_record(self):
        self.assertIsNone(bench.sidebar_row_mismatch({"sizes": {"99": {"rows_listed": 100}}}, 99, 100))


class TypingReasonTests(unittest.TestCase):
    def test_missing_type_names_each_phase_and_the_log(self):
        """The typing probe exited 0 with no `type` row at 1, 100 and 1000 workspaces and the record said why not."""
        report = {"phases": [{"phase": "light-idle-0", "keys": 10, "complete": 0, "stalled_keys": 10,
                              "key_to_frame_ms": None}],
                  "setup": {"typing": None, "workspace_count": 1},
                  "log": ["light-idle-0: key 0 took 3 ms ({\"error\": \"no window\"})"]}
        self.assertEqual(bench.typing_rows(report, 1), {})
        reason = bench.typing_reason(report)
        self.assertEqual(reason["phases"], [{"phase": "light-idle-0", "keys": 10, "complete": 0, "stalled_keys": 10}])
        self.assertEqual(reason["setup"], {"typing": None, "workspace_count": 1})
        self.assertIn("no window", reason["log_tail"][-1])

    def test_empty_report_gives_no_reason(self):
        self.assertEqual(bench.typing_reason({}), {})


class ProbeReasonTests(unittest.TestCase):
    def test_failed_probe_names_its_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            report, log = Path(tmp, "report.json"), Path(tmp, "probe.log")
            report.write_text(json.dumps({"invalid": {"restored_workspaces": {"existing": 1}}}))
            log.write_text("line 1\nTraceback (most recent call last)\nSystemExit: could not clear\n")
            reason = bench.probe_reason(report, log)
            self.assertEqual(reason["invalid"], {"restored_workspaces": {"existing": 1}})
            self.assertEqual(reason["log_tail"][-1], "SystemExit: could not clear")

    def test_missing_report_and_log_give_no_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(bench.probe_reason(Path(tmp, "none.json"), Path(tmp, "none.log")), {})


if __name__ == "__main__":
    unittest.main()

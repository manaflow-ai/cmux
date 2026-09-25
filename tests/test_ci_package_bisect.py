"""Package bisect: log parsing, per-test verdicts, midpoints, and the CI overlay."""

import importlib.util
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/package_bisect.py"
SPEC = importlib.util.spec_from_file_location("package_bisect", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE  # dataclasses resolve annotations through it
SPEC.loader.exec_module(MODULE)

FAILING_LOG = """\
2026-09-25T08:44:02.1Z ✘ Test secondaryAggregationExcludesX() recorded an issue at A.swift:1:1: Expectation failed
2026-09-25T08:44:02.2Z ✘ Test secondaryAggregationExcludesX() failed after 0.001 seconds with 1 issue.
2026-09-25T08:44:02.3Z ✘ Test nextScope(signOutHook:) with 2 test cases failed after 6.808 seconds with 4 issues.
2026-09-25T08:44:02.4Z ✘ Test "chip keeps its anchor" failed after 4.377 seconds with 1 issue.
2026-09-25T08:44:02.5Z Test Case '-[CmuxMobileShellTests.LegacyTests testOld]' failed (0.1 seconds).
2026-09-25T08:44:02.6Z ✘ Suite MobileShellTests failed after 0.012 seconds with 2 issues.
2026-09-25T08:46:15.9Z ✘ Test run with 1317 tests in 115 suites failed after 133.660 seconds with 35 issues.
"""


def state(results, history=None):
    """results: list of failing-test sets (None = still pending), oldest first."""
    history = history or [f"{n:040x}" for n in range(1, 21)]
    shas = history[:: max(1, len(history) // len(results))][: len(results)]
    probes = {}
    for sha, failures in zip(shas, results):
        probe = MODULE.Probe(sha=sha, branch=f"b/{sha[:4]}")
        if failures is not None:
            probe.status = "done"
            probe.failures = sorted(failures)
        probes[sha] = probe
    return MODULE.State("Pkg", "", history[-1], history, list(history), probes), shas


class FailedTestsTests(unittest.TestCase):
    def test_collects_swift_testing_and_xctest_failures_without_summaries(self):
        self.assertEqual(
            MODULE.failed_tests(FAILING_LOG),
            {"secondaryAggregationExcludesX", "nextScope", '"chip keeps its anchor"', "testOld"},
        )

    def test_passing_run_is_an_empty_set(self):
        log = "2026-09-25T08:46:15Z ✔ Test run with 1317 tests in 115 suites passed after 90 seconds.\n"
        self.assertEqual(MODULE.failed_tests(log), set())

    def test_log_without_a_test_summary_is_an_error(self):
        self.assertIsNone(MODULE.failed_tests("error: compile failed\n"))


class VerdictTests(unittest.TestCase):
    def test_contiguous_failures_name_break_and_fix_windows(self):
        s, shas = state([set(), {"t"}, {"t"}, set()])
        verdict = MODULE.verdicts(s)["t"]
        self.assertFalse(verdict.flaky)
        self.assertEqual(verdict.broke, (shas[0], shas[1]))
        self.assertEqual(verdict.fixed, (shas[2], shas[3]))

    def test_failure_at_oldest_probe_has_no_break_window(self):
        s, _ = state([{"t"}, {"t"}])
        verdict = MODULE.verdicts(s)["t"]
        self.assertIsNone(verdict.broke)
        self.assertIsNone(verdict.fixed)

    def test_pass_between_failures_is_flaky(self):
        s, _ = state([{"t"}, set(), {"t"}])
        self.assertTrue(MODULE.verdicts(s)["t"].flaky)

    def test_pending_probes_do_not_count(self):
        s, shas = state([set(), None, {"t"}])
        self.assertEqual(MODULE.verdicts(s)["t"].broke, (shas[0], shas[2]))


class NextPointsTests(unittest.TestCase):
    def test_midpoint_splits_break_window_and_skips_probed(self):
        s, shas = state([set(), {"t"}])
        inside = MODULE.between(s, shas[0], shas[1])
        self.assertEqual(MODULE.next_points(s), [inside[len(inside) // 2]])

    def test_only_watched_commits_are_candidates(self):
        s, shas = state([set(), {"t"}])
        s.candidates = [shas[0], shas[1]]
        self.assertEqual(MODULE.next_points(s), [])

    def test_fix_windows_are_opt_in(self):
        s, _ = state([{"t"}, set()])
        self.assertEqual(MODULE.next_points(s), [])
        self.assertEqual(len(MODULE.next_points(s, include_fixed=True)), 1)


class OverlayTests(unittest.TestCase):
    def test_drops_only_the_package_job_lint_gate(self):
        workflow = (ROOT / MODULE.WORKFLOW_PATH).read_text()
        patched = MODULE.drop_lint_gate(workflow)
        head, _, package = patched.partition(f"\n  {MODULE.PACKAGE_JOB}:")
        self.assertEqual(head, workflow.partition(f"\n  {MODULE.PACKAGE_JOB}:")[0])
        self.assertNotIn(MODULE.LINT_GATE, package.split("\n  ios-simulator")[0])
        self.assertEqual(len(workflow) - len(patched), len(MODULE.LINT_GATE) - len("&& (true"))

    def test_overlay_paths_exist(self):
        for path in MODULE.OVERLAY_PATHS:
            self.assertTrue((ROOT / path).exists(), path)


if __name__ == "__main__":
    unittest.main()

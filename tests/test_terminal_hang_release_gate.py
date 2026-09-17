import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "gate", Path(__file__).resolve().parents[1] / "scripts/terminal-hang-release-gate.py"
)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class TerminalHangReleaseGateTests(unittest.TestCase):
    def sample(self, events, sessions=10000, transition="resize", phase="layout"):
        return dict(platform="macos", environment="production", start="a", end="b",
                    hang_events=events, sessions=sessions,
                    segments=[{"terminal.transition": transition, "terminal.phase": phase, "count()": events}])

    def test_rates_normalize_different_release_adoption(self):
        result = gate.evaluate(self.sample(100, 10000), self.sample(12, 2000))
        self.assertTrue(result["passed"])
        self.assertAlmostEqual(result["rate_ratio"], .6)

    def test_ios_cannot_pass_a_session_gate_without_session_collection(self):
        baseline, candidate = self.sample(100), self.sample(10)
        for sample in (baseline, candidate):
            sample.update(platform="ios", environment="ios-production")
        self.assertFalse(gate.evaluate(baseline, candidate)["passed"])

    def test_smaller_raw_count_can_still_be_a_regression(self):
        self.assertFalse(gate.evaluate(self.sample(100), self.sample(30, 1000))["passed"])

    def test_missing_sessions_does_not_pass(self):
        self.assertFalse(gate.evaluate(self.sample(100), self.sample(0, 0))["passed"])

    def test_unknown_phase_does_not_pass(self):
        result = gate.evaluate(self.sample(100), self.sample(2, phase="unknown"))
        self.assertFalse(result["passed"])
        self.assertEqual(result["candidate_unattributed_events"], 2)

    def test_mismatched_window_and_truncated_segments_do_not_pass(self):
        candidate = self.sample(10)
        candidate["end"] = "c"
        candidate["segments"] = []
        self.assertFalse(gate.evaluate(self.sample(100), candidate)["passed"])

    def test_zero_baseline_cannot_bless_a_new_hang(self):
        self.assertFalse(gate.evaluate(self.sample(0), self.sample(1))["passed"])

    def test_zero_events_need_enough_exposure(self):
        self.assertFalse(gate.evaluate(self.sample(1), self.sample(0))["passed"])
        self.assertTrue(gate.evaluate(self.sample(100), self.sample(0))["passed"])


if __name__ == "__main__":
    unittest.main()

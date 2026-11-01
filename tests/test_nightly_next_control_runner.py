from __future__ import annotations

import datetime as dt
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import nightly_next_control_runner as picker  # noqa: E402


class ControlRunnerPickerTests(unittest.TestCase):
    ENV = {
        "GITHUB_REPOSITORY": "manaflow-ai/cmux",
        "GITHUB_RUN_ATTEMPT": "1",
        "CI_SIDE_LANE_RUNNER": "glaeda-side-std-xcode-26.6",
    }

    def test_registered_online_idle_runner_is_selected(self):
        runners = [{"status": "online", "busy": False, "os": "macOS",
                    "labels": [{"name": "glaeda-side-std-xcode-26.6"}]}]
        self.assertEqual(picker.choose(self.ENV, lambda _: runners), "glaeda-side-std-xcode-26.6")

    def test_declared_canonical_linux_runner_is_selected_only_with_live_proof(self):
        env = {**self.ENV, "CI_SIDE_LANE_RUNNER": "", "LINUX_RUNNER": "cmux-fleet-linux-x64"}
        runners = [{"status": "online", "busy": False, "os": "Linux",
                    "labels": [{"name": "cmux-fleet-linux-x64"}]}]
        self.assertEqual(picker.choose(env, lambda _: runners), "cmux-fleet-linux-x64")

    def test_registered_but_busy_runner_is_not_selected(self):
        runners = [{"status": "online", "busy": True, "os": "macOS",
                    "labels": [{"name": "glaeda-side-std-xcode-26.6"}]}]
        ticks = iter((0.0, 180.0))
        self.assertEqual(picker.choose(self.ENV, lambda _: runners, lambda _: None, lambda: next(ticks)), "ubuntu-24.04")

    def test_unreadable_or_stale_observation_falls_back(self):
        ticks = iter((0.0, 180.0))
        self.assertEqual(picker.choose(self.ENV, lambda _: None, lambda _: None, lambda: next(ticks)), "ubuntu-24.04")

    def test_later_attempt_uses_measured_blacksmith_even_when_label_is_idle(self):
        env = {**self.ENV, "GITHUB_RUN_ATTEMPT": "2"}
        runners = [{"status": "online", "busy": False, "os": "macOS",
                    "labels": [{"name": "glaeda-side-std-xcode-26.6"}]}]
        self.assertEqual(picker.choose(env, lambda _: runners), "blacksmith-4vcpu-ubuntu-2404")

    def test_raw_untrusted_override_is_not_a_candidate(self):
        env = {**self.ENV, "CI_CONTROL_RUNNER": "unregistered-fleet", "CI_SIDE_LANE_RUNNER": ""}
        self.assertEqual(picker.candidates(env), ())

    def test_missing_and_stale_snapshots_are_not_capacity_proof(self):
        now = dt.datetime(2026, 11, 1, 0, 35, tzinfo=dt.timezone.utc)
        self.assertFalse(picker.fresh_snapshot(None, now))
        self.assertFalse(picker.fresh_snapshot({"generated_at": "2026-10-31T00:00:00Z", "pools": {}}, now))
        self.assertTrue(picker.fresh_snapshot({"generated_at": "2026-11-01T00:30:00Z", "pools": {}}, now))


if __name__ == "__main__":
    unittest.main()

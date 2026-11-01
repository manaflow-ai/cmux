#!/usr/bin/env python3
"""Live admission and bounded overflow for the fast-checks picker."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
SPEC = importlib.util.spec_from_file_location("fast_checks_runner", ROOT / "scripts/ci/fast_checks_runner.py")
assert SPEC and SPEC.loader
picker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(picker)


class FastChecksRunnerTests(unittest.TestCase):
    def test_live_idle_linux_fleet_runner_is_selected(self) -> None:
        rows = [{"status": "online", "busy": False, "os": "Linux",
                 "labels": [{"name": "cmux-fleet-linux-x64"}]}]
        self.assertEqual(picker.idle_runner(rows), "cmux-fleet-linux-x64")

    def test_busy_or_unlabelled_runner_does_not_count_as_live_capacity(self) -> None:
        rows = [
            {"status": "online", "busy": True, "os": "Linux", "labels": ["cmux-fleet-linux-x64"]},
            {"status": "online", "busy": False, "os": "Linux", "labels": ["other"]},
        ]
        self.assertEqual(picker.idle_runner(rows), "")

    def test_no_live_runner_falls_back_to_smallest_measured_blacksmith(self) -> None:
        now = iter((0.0, 0.0, 181.0))
        sleeps = []
        selected = picker.choose({"REQUESTED_RUNNER": ""}, read=lambda _env: [],
                                 sleep=lambda seconds: sleeps.append(seconds), clock=lambda: next(now))
        self.assertEqual(selected, "blacksmith-8vcpu-ubuntu-2404")
        self.assertEqual(sleeps, [15])

    def test_broker_requested_label_is_allowlisted(self) -> None:
        self.assertEqual(picker.choose({"REQUESTED_RUNNER": "blacksmith-16vcpu-ubuntu-2404"}, read=lambda _: []),
                         "blacksmith-16vcpu-ubuntu-2404")
        self.assertEqual(picker.fallback({"REQUESTED_RUNNER": "ubuntu-latest"}), "blacksmith-8vcpu-ubuntu-2404")


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""scripts/ci/cmux_machine_channel_lane.py pick: a free build lane, else the one that frees first (FREE_LANE)."""

from __future__ import annotations

import importlib.util
import sys
import unittest
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("lane", ROOT / "scripts/ci/cmux_machine_channel_lane.py")
lane = importlib.util.module_from_spec(spec)
sys.modules["lane"] = lane
spec.loader.exec_module(lane)

OWN = 999


def job(n, status, started="", target="x86_64", callee="build x86_64-unknown-linux-musl"):
    return {"name": f"build-machine-channel {target} lane {n} / {callee}", "status": status,
            "started_at": started or None, "created_at": "2026-11-27T13:00:00Z"}


class Fake:
    def __init__(self, jobs_by_run):
        self.jobs_by_run = jobs_by_run
        self.calls = []

    def __call__(self, path):
        self.calls.append(path)
        if path.startswith("actions/workflows/"):
            return {"workflow_runs": [{"id": r} for r in self.jobs_by_run]}
        run = int(path.split("/")[2])
        return {"jobs": self.jobs_by_run[run]}


class Pick(unittest.TestCase):
    def pick(self, jobs_by_run, run_number=7):
        return lane.pick(Fake(jobs_by_run), "feat-cmux-next", OWN, run_number)

    def test_nothing_in_flight_takes_lane_0(self):
        self.assertEqual(self.pick({}), 0)

    def test_free_lane_beats_parity(self):
        # Parity would send run 7 to lane 1, which is busy; lane 2 is idle.
        runs = {1: [job(0, "in_progress", "2026-11-27T13:00:00Z")],
                2: [job(1, "in_progress", "2026-11-27T13:05:00Z")]}
        self.assertEqual(self.pick(runs), 2)

    def test_all_busy_takes_the_oldest_build(self):
        runs = {1: [job(0, "in_progress", "2026-11-27T13:06:00Z")],
                2: [job(1, "in_progress", "2026-11-27T13:01:00Z")],
                3: [job(2, "in_progress", "2026-11-27T13:10:00Z")]}
        self.assertEqual(self.pick(runs), 1)

    def test_a_lane_with_a_waiting_build_is_passed_over(self):
        runs = {1: [job(0, "in_progress", "2026-11-27T13:06:00Z")],
                2: [job(1, "in_progress", "2026-11-27T13:01:00Z")],
                3: [job(2, "in_progress", "2026-11-27T13:10:00Z")],
                4: [job(1, "pending")]}
        self.assertEqual(self.pick(runs), 0)

    def test_queued_for_a_runner_holds_its_lane(self):
        runs = {1: [job(0, "queued")], 2: [job(1, "in_progress", "2026-11-27T13:01:00Z")]}
        self.assertEqual(self.pick(runs), 2)

    def test_aarch64_finished_jobs_and_own_run_do_not_hold(self):
        runs = {1: [job(0, "in_progress", "2026-11-27T13:00:00Z", target="aarch64",
                        callee="build aarch64-unknown-linux-musl")],
                2: [job(0, "completed", "2026-11-27T12:40:00Z")],
                OWN: [job(0, "queued")]}
        self.assertEqual(self.pick(runs), 0)

    def test_pull_request_names_have_no_lane(self):
        self.assertIsNone(lane.job_lane("build-machine-channel / build x86_64-unknown-linux-musl"))
        self.assertIsNone(lane.job_lane("does the machine channel need this commit"))
        self.assertEqual(lane.job_lane("build-machine-channel x86_64 lane 2 / select binary targets"), 2)

    def test_read_failure_falls_back_to_parity(self):
        def broken(path):
            raise urllib.error.URLError("down")
        self.assertEqual(lane.pick(broken, "feat-cmux-next", OWN, 8), 8 % lane.LANES)

    def test_workflow_groups_and_names_carry_the_lane(self):
        wf = (ROOT / ".github/workflows/cmux-machine-channel.yml").read_text()
        self.assertIn("scripts/ci/cmux_machine_channel_lane.py pick", wf)
        self.assertIn("format('build-machine-channel x86_64 lane {0}', needs.plan.outputs.lane)", wf)
        self.assertIn("lane{1}', github.ref, needs.plan.outputs.lane)", wf)
        self.assertNotIn("GITHUB_RUN_NUMBER % 2", wf)
        self.assertIn(f"GITHUB_RUN_NUMBER % {lane.LANES}", wf)


if __name__ == "__main__":
    unittest.main()

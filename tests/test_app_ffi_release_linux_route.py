#!/usr/bin/env python3
"""The app FFI release's Linux control jobs take the nightly lane's reserved label first, never the bulk route alone.

2026-11-19: runs 44600407530 and 44612287186 sat in "place the build" on vars.LINUX_RUNNER (cmux-fleet-linux-x64,
2,600 PR jobs queued, 0 idle runners) for hours; no FFI release published and the pin guard went 30 h stale. The
placement, rescue, publish and re-pin jobs now ask for cmux-gcp-nightly-x64 on attempts 1 and 2 (one-job JIT VMs
the HQ booter starts ahead of the PR lanes), behind the build's own switch vars.CI_RELEASE_PIN_SLOT.
"""
from __future__ import annotations

import unittest
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/app-ffi-release.yml"
REPIN = WORKFLOW.with_name("app-ffi-repin.yml")
LANE = "vars.CI_RELEASE_PIN_SLOT != 'off' && github.run_attempt <= 2 && 'cmux-gcp-nightly-x64'"
CONTROL_JOBS = ("placement", "rescue", "publish", "repin")


class FfiReleaseLinuxRoute(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]

    def test_control_jobs_take_the_nightly_lane_before_the_bulk_route(self) -> None:
        for name in CONTROL_JOBS:
            with self.subTest(job=name):
                runs_on = self.jobs[name]["runs-on"]
                self.assertIn(LANE, runs_on)
                self.assertLess(runs_on.index(LANE), runs_on.index("'cmux-linux'"))
                self.assertTrue(runs_on.startswith("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' ||"))

    def test_the_repin_workflow_takes_the_nightly_lane_first(self) -> None:
        runs_on = yaml.safe_load(REPIN.read_text())["jobs"]["repin"]["runs-on"]
        self.assertIn(LANE, runs_on)
        self.assertLess(runs_on.index(LANE), runs_on.index("'cmux-linux'"))

    def test_the_repin_jobs_outlast_one_healthy_repin_and_abort_a_stalled_fetch(self) -> None:
        # One healthy re-pin took about 8 min after a 1.5 min checkout (run 44655157417); at 10 min four runs timed
        # out and re-dispatched themselves (2026-11-20).
        for job in (self.jobs["repin"], yaml.safe_load(REPIN.read_text())["jobs"]["repin"]):
            self.assertGreaterEqual(int(job["timeout-minutes"]), 20)
            [step] = [s for s in job["steps"] if "publish-app-ffi-repin.sh" in str(s.get("run", ""))]
            self.assertEqual(step["env"]["GIT_HTTP_LOW_SPEED_LIMIT"], "1000")
            self.assertEqual(step["env"]["GIT_HTTP_LOW_SPEED_TIME"], "60")

    def test_the_compare_only_shadow_stays_off_the_reserved_lane(self) -> None:
        self.assertNotIn("cmux-gcp-nightly-x64", self.jobs["macos-cross-shadow"]["runs-on"])


if __name__ == "__main__":
    unittest.main()

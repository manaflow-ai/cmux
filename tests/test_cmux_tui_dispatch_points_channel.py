#!/usr/bin/env python3
"""A feat-cmux-next dispatch of cmux-tui-artifacts.yml moves the acpmux channel, as a push does.

Leo, 2026-11-25: "accelerate the shit out of efficiency improvements dev builds etc. they cannot be slow. do not
catch-22 yourselves." Pushes coalesce into one build an hour, so only a dispatch gets a merged acpmux fix to the
Linux hosts sooner; point-feat-channel ran on pushes only. The point script (tests/test_cmux_tui_point_channel.py)
records GITHUB_SHA, the run's own commit, moves only forward and only to a daemon-tested tree.
"""

import os
import unittest

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-tui-artifacts.yml")


class DispatchPointsChannel(unittest.TestCase):
    def setUp(self):
        with open(WORKFLOW, encoding="utf-8") as f:
            self.job = yaml.safe_load(f)["jobs"]["point-feat-channel"]

    def test_a_feat_cmux_next_dispatch_points_the_channel(self):
        cond = self.job["if"]
        self.assertIn("(github.event_name == 'push' || github.event_name == 'workflow_dispatch')", cond)
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", cond)

    def test_it_still_needs_the_daemon_tested_tree(self):
        self.assertIn("publish-tree-tested", self.job["needs"])
        self.assertIn("needs.publish-tree-tested.result != 'failure'", self.job["if"])
        run = "\n".join(s.get("run", "") for s in self.job["steps"])
        self.assertIn("scripts/ci/cmux-tui-point-channel.sh feat-cmux-next", run)


class MarkerJobPoints(unittest.TestCase):
    """The channel moves in the job that writes the daemon-tests marker, not a job after it (goal
    fleet-core-skew: run 45557717558 spent about 3 min between the marker and the channel write, mostly
    point-feat-channel's runner setup and checkout). point-feat-channel stays the fallback."""

    def setUp(self):
        with open(WORKFLOW, encoding="utf-8") as f:
            self.jobs = yaml.safe_load(f)["jobs"]
        self.marker = self.jobs["publish-tree-tested"]

    def test_the_point_follows_the_marker_in_the_same_job(self):
        steps = self.marker["steps"]
        runs = [s.get("run", "") for s in steps]
        mark = next(i for i, r in enumerate(runs) if "cmux-tui-mark-daemon-tested.sh" in r)
        point = next(i for i, r in enumerate(runs) if "cmux-tui-point-channel.sh feat-cmux-next" in r)
        self.assertGreater(point, mark)
        step = steps[point]
        self.assertTrue(step.get("continue-on-error"))
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", step["if"])
        self.assertIn("github.repository == 'manaflow-ai/cmux'", step["if"])
        self.assertIn('echo "pointed=true"', step["run"])
        self.assertLess(step["run"].index("cmux-tui-point-channel.sh"), step["run"].index("pointed=true"))
        self.assertEqual(self.marker["outputs"]["pointed"], "${{ steps.point.outputs.pointed }}")

    def test_the_point_job_runs_only_when_the_marker_job_did_not_point(self):
        cond = self.jobs["point-feat-channel"]["if"]
        self.assertIn("needs.publish-tree-tested.outputs.pointed != 'true'", cond)


if __name__ == "__main__":
    unittest.main()

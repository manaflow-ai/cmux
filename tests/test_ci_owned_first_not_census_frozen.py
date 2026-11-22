#!/usr/bin/env python3
"""Check the Linux routes used to build and test an artifact tree."""

from pathlib import Path
import unittest

import yaml


WORKFLOWS = Path(__file__).resolve().parents[1] / ".github" / "workflows"
OWNER = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
FORK_PR = "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository"


class TreeLinuxRoutes(unittest.TestCase):
    def test_tree_jobs_use_the_linux_label(self) -> None:
        jobs = yaml.safe_load((WORKFLOWS / "cmux-tui-artifacts.yml").read_text())["jobs"]
        for job in ("tree-preflight", "tree-owner-wait", "darwin-fallback-plan", "cmux-next-daemon-tests"):
            with self.subTest(job=job):
                self.assertEqual(jobs[job]["runs-on"], "${{ " + OWNER + "'cmux-linux' }}")
        for job in ("build", "build-linux"):
            with self.subTest(job=job):
                self.assertEqual(jobs[job]["with"]["linux_runner"], "cmux-linux")

    def test_package_jobs_keep_their_fork_routes(self) -> None:
        jobs = yaml.safe_load((WORKFLOWS / "cmux-tui-build-package.yml").read_text())["jobs"]
        targets = next(step for step in jobs["plan-build"]["steps"] if step.get("id") == "targets")
        for expr, size in ((jobs["plan-build"]["runs-on"], 2), (jobs["package"]["runs-on"], 16),
                           (targets["env"]["LINUX_RUNNER"], 16)):
            with self.subTest(expression=expr):
                self.assertEqual(expr, "${{ " + OWNER + FORK_PR
                                 + f" && 'blacksmith-{size}vcpu-ubuntu-2404' || 'cmux-linux' " + "}}")


if __name__ == "__main__":
    unittest.main()

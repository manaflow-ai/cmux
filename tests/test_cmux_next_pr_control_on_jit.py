#!/usr/bin/env python3
"""A same-repo pull request's cmux-next control hops start on the reserved PR control JIT label, ahead of PR CI.

The verdict of a PR head waits on five control jobs (push-head-preflight, portable-placement, path_route,
app-compile-placement, macos-placement), four deep, before its first test. Each took a shared RUNNER_POOLS Linux pool,
so each re-entered the PR queue: on 2026-11-20 the slowest open heads sat 4 to 25 h on macOS placement
(blacksmith-16vcpu-ubuntu-2404, 3,628 queued) or push head preflight (blacksmith-32vcpu-ubuntu-2404)
(cmuxterm-hq goals/pr-verdict-fast.md). cmux-gcp-pr-control-jit-x64 is served only by cmuxterm-hq gha-runners'
one-job JIT VMs, kept warm (PR_CONTROL_JIT_LABEL), and only these hops name it. Attempt 2 takes the old pools, the way
out if those runners are down.
"""
from __future__ import annotations

import unittest
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cmux-next.yml"
LABEL = "cmux-gcp-pr-control-jit-x64"
ARM = ("github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository && "
       f"github.run_attempt == 1 && '{LABEL}'")
FORK = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
PUSH = ("github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next' && github.run_attempt == 1 && "
        "'cmux-gcp-nightly-jit-x64' || ")
HOPS = ("push-head-preflight", "portable-placement", "path_route", "app-compile-placement", "macos-placement")


class PrControlOnJit(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]

    def test_each_hop_takes_the_label_on_a_same_repo_pr_attempt_1_after_fork_and_push(self) -> None:
        for name in HOPS:
            with self.subTest(job=name):
                head = self.jobs[name]["runs-on"].removeprefix("${{ ").removeprefix(FORK).removeprefix(PUSH)
                self.assertTrue(head.startswith(ARM), f"{name}: the PR control arm comes before any pool")

    def test_a_fork_never_reaches_the_label(self) -> None:
        for name in HOPS:
            with self.subTest(job=name):
                runs_on = self.jobs[name]["runs-on"]
                if runs_on.startswith("${{ " + FORK):
                    continue
                self.assertIn("head.repo.full_name == github.repository", runs_on)

    def test_only_the_hops_name_the_label(self) -> None:
        for name, job in self.jobs.items():
            with self.subTest(job=name):
                runs_on = str(job.get("runs-on", ""))
                self.assertEqual(runs_on.count(LABEL), 1 if name in HOPS else 0)
                self.assertEqual(runs_on.count(LABEL), runs_on.count(ARM))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""A same-repo pull request's cmux-next control hops start on cmux-linux, the persistent runner pool, on attempt 1.

The verdict of a PR head waits on four control jobs (push-head-preflight, path_route, app-compile-placement,
macos-placement), three deep, before its first test. Each took a shared RUNNER_POOLS Linux pool,
so each re-entered the PR queue: on 2026-11-20 the slowest open heads sat 4 to 25 h on macOS placement
(blacksmith-16vcpu-ubuntu-2404, 3,628 queued) or push head preflight (blacksmith-32vcpu-ubuntu-2404)
(cmuxterm-hq goals/pr-verdict-fast.md). cmux-gcp-pr-control-jit-x64 is served only by cmuxterm-hq's runner pool,
one-job JIT VMs with a warm floor (runner_pool.py PR_CONTROL_JIT_LABEL). A feat-cmux-next push's control jobs take it
too (#48261). Attempt 2 of a PR takes the old pools, the way out if those runners are down.

On 2026-11-21 that label queued 1,860 jobs (oldest about 2 h): each needs a fresh one-job VM, mints are capped at 60 a
minute and VM creates were refused, while the persistent pool had about 300 runners idle. No hop needs an ephemeral
runner, so each takes cmux-linux, the one label for every own-branch Linux job (cmuxterm-hq decisions/junctions.md).

The first landing (#47887) was reverted (#48183): the pool spent every create on a deep nightly backlog and the label
got none. cmuxterm-hq#15779 gives each label a fair first share of every tick's creates; after it, push control jobs on
this label started within 2 s.
"""
from __future__ import annotations

import unittest
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cmux-next.yml"
LABEL = "cmux-linux"
JIT_LABEL = "cmux-gcp-pr-control-jit-x64"
ARM = ("github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository && "
       f"github.run_attempt == 1 && '{LABEL}'")
FORK = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
PUSH = ("github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next' && github.run_attempt == 1 && "
        f"'{LABEL}' || ")
HOPS = ("push-head-preflight", "path_route", "app-compile-placement", "macos-placement")
# A hop with no attempt-2 pool left: its fork arms, then cmux-linux on every attempt.
ONE_LABEL_TAIL = f"|| '{LABEL}' }}}}"


def one_label(runs_on: str) -> bool:
    # The fork arm's own runner variable (scripts/ci/one_linux_label.py) is no pool.
    # The overflow switch (vars.CI_OVERFLOW_LINUX, scripts/ci/one_linux_label.py) names no pool either: unset, the tail is cmux-linux.
    runs_on = runs_on.replace(" || vars.CI_OVERFLOW_LINUX", "")
    return "vars." not in runs_on and runs_on.rstrip().endswith(ONE_LABEL_TAIL)


class PrControlOnJit(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]

    def test_each_hop_takes_the_pool_on_a_same_repo_pr_attempt_1_after_fork_and_push(self) -> None:
        for name in HOPS:
            with self.subTest(job=name):
                if one_label(self.jobs[name]["runs-on"]):
                    continue
                head = self.jobs[name]["runs-on"].removeprefix("${{ ").removeprefix(FORK).removeprefix(PUSH)
                self.assertTrue(head.startswith(ARM), f"{name}: the PR control arm comes before any pool")

    def test_a_fork_never_reaches_the_label(self) -> None:
        for name in HOPS:
            with self.subTest(job=name):
                runs_on = self.jobs[name]["runs-on"]
                if runs_on.startswith("${{ " + FORK):
                    continue
                self.assertIn("head.repo.full_name == github.repository", runs_on)

    def test_only_the_hops_send_a_pull_request_to_the_label(self) -> None:
        for name, job in self.jobs.items():
            with self.subTest(job=name):
                runs_on = str(job.get("runs-on", ""))
                if name in HOPS and one_label(runs_on):
                    # A one-label hop may keep its PR control arm: it names the same label as its tail.
                    self.assertLessEqual(runs_on.count(ARM), 1)
                else:
                    self.assertEqual(runs_on.count(ARM), 1 if name in HOPS else 0)

    def test_no_pull_request_arm_names_the_jit_label(self) -> None:
        jit_arm = ARM.replace(f"'{LABEL}'", f"'{JIT_LABEL}'")
        for name, job in self.jobs.items():
            with self.subTest(job=name):
                self.assertNotIn(jit_arm, str(job.get("runs-on", "")))


if __name__ == "__main__":
    unittest.main()

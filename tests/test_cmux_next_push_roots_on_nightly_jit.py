#!/usr/bin/env python3
"""A feat-cmux-next push's Linux control jobs start on the JIT-only control-hop label, ahead of PR CI.

Leo, 2026-11-18 (ask-2e27ea2c31): "can we just push a nightly as higher priority?". The push run gates the NEXT
nightly, and its placements read the same RUNNER_POOLS Linux pools as every PR run (3,122 jobs queued on
blacksmith-16vcpu-ubuntu-2404, 2026-11-20 02:01Z). cmux-gcp-pr-control-jit-x64 is served only by cmuxterm-hq
gha-runners' one-job JIT VMs, kept warm, for cmux-next.yml's control hops.

They first took cmux-gcp-nightly-jit-x64 (#47764). On 2026-11-20 they filled it: 333 jobs queued there and the
nightly's own pick-nightly-app-runner waited behind them (Leo: "then clearly the prioritization on teh nightly
didnt work"). That label serves nightly runs only, so no cmux-next.yml job names it.

On 2026-11-21 cmux-gcp-pr-control-jit-x64 queued 1,860 jobs (oldest about 2 h) while the persistent pool had about 300
runners idle, so every root that needs no ephemeral runner takes cmux-linux, the one label for every own-branch Linux
job (cmuxterm-hq decisions/junctions.md). compile-status and its handoff hold a statuses write App token and stay on
the one-job label (# ephemeral-required).
"""
from __future__ import annotations

import unittest
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cmux-next.yml"
JIT_LABEL = "cmux-gcp-pr-control-jit-x64"
POOL_LABEL = "cmux-linux"
PUSH = "github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next' && github.run_attempt == 1 && "
ARM = f"{PUSH}'{JIT_LABEL}'"
POOL_ARM = f"{PUSH}'{POOL_LABEL}'"
FORK = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
POOL_ROOTS = ("push-head-preflight", "macos-placement", "app-compile-placement",
              "release-compile-fast-admission", "dev-landing-place")
EPHEMERAL_ROOTS = ("compile-status", "compile-status-handoff")


class PushRootsOnControlJit(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]

    def test_each_root_takes_its_label_first_on_a_push_attempt_1(self) -> None:
        for names, arm in ((POOL_ROOTS, POOL_ARM), (EPHEMERAL_ROOTS, ARM)):
            for name in names:
                with self.subTest(job=name):
                    head = self.jobs[name]["runs-on"].removeprefix("${{ ").removeprefix(FORK)
                    self.assertTrue(head.startswith(arm), f"{name}: the push arm comes before any pool")

    def test_only_the_ephemeral_roots_name_the_jit_label_and_only_on_a_push_attempt_1(self) -> None:
        for name, job in self.jobs.items():
            runs_on = str(job.get("runs-on", ""))
            with self.subTest(job=name):
                self.assertEqual(runs_on.count(JIT_LABEL), runs_on.count(ARM))
                self.assertEqual(runs_on.count(ARM), 1 if name in EPHEMERAL_ROOTS else 0)

    def test_no_job_takes_the_nightly_jit_label(self) -> None:
        for name, job in self.jobs.items():
            with self.subTest(job=name):
                self.assertNotIn("cmux-gcp-nightly-jit-x64", str(job.get("runs-on", "")))


if __name__ == "__main__":
    unittest.main()

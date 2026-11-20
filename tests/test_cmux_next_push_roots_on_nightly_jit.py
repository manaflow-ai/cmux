#!/usr/bin/env python3
"""A feat-cmux-next push's Linux control jobs start on the JIT-only nightly label, ahead of PR CI.

Leo, 2026-11-18 (ask-2e27ea2c31): "can we just push a nightly as higher priority?". The push run gates the NEXT
nightly, and its placements read the same RUNNER_POOLS Linux pools as every PR run (3,122 jobs queued on
blacksmith-16vcpu-ubuntu-2404, 2026-11-20 02:01Z). cmux-gcp-nightly-jit-x64 is served only by cmuxterm-hq
gha-runners' one-job JIT VMs, kept warm, and no PR job names it.
"""
from __future__ import annotations

import unittest
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cmux-next.yml"
ARM = ("github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next' && github.run_attempt == 1 && "
       "'cmux-gcp-nightly-jit-x64'")
FORK = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
ROOTS = ("push-head-preflight", "portable-placement", "macos-placement", "app-compile-placement",
         "release-compile-fast-admission", "dev-landing-place", "compile-status", "compile-status-handoff")


class PushRootsOnNightlyJit(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]

    def test_each_root_takes_the_jit_label_first_on_a_push_attempt_1(self) -> None:
        for name in ROOTS:
            with self.subTest(job=name):
                head = self.jobs[name]["runs-on"].removeprefix("${{ ").removeprefix(FORK)
                self.assertTrue(head.startswith(ARM), f"{name}: the push arm comes before any pool")

    def test_only_a_feat_cmux_next_push_attempt_1_names_the_jit_label(self) -> None:
        for name, job in self.jobs.items():
            runs_on = str(job.get("runs-on", ""))
            with self.subTest(job=name):
                self.assertEqual(runs_on.count("cmux-gcp-nightly-jit-x64"), runs_on.count(ARM))


if __name__ == "__main__":
    unittest.main()

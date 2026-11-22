#!/usr/bin/env python3
"""A re-run cmux-tui build leg never keeps a 2 or 4 vCPU label its plan baked in.

"Re-run failed jobs" does not re-run a succeeded plan-build: the new attempt
reuses its matrix, runner included. On 2026-11-18 the pool writer's release
valve held linux_16 at 2 vCPU; runs planned then kept that label, and their
re-runs OOMed in the fat-LTO build for days (run 44293740637, attempts 1-3;
2026-11-19: 72 failed re-run legs, 1,544 runner-min). The build job's runs-on
reads the pool again for such a leg on attempt 2 and later.
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from test_ci_fork_runner_routing import fork_pull_request_gate_error  # noqa: E402
from test_ci_tui_routes_avoid_nightly_label import route  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-build-package.yml"
POOL_16 = "blacksmith-16vcpu-ubuntu-2404"
RETRY_MAC = "glaeda-side-std-xcode-26.6"


def runs_on() -> str:
    jobs = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]
    return jobs["build"]["runs-on"]


def label(attempt: int, runner: str, target: str = "x86_64-unknown-linux-musl", *, darwin_on_linux: bool = False,
          fork: bool = False, pool: str = POOL_16) -> str:
    context = {
        "github.run_attempt": attempt,
        "github.repository_owner": "manaflow-ai",
        "github.event_name": "pull_request" if fork else "push",
        "github.event.pull_request.head.repo.full_name": "someone/cmux" if fork else "manaflow-ai/cmux",
        "github.repository": "manaflow-ai/cmux",
        "inputs.macos_retry_runner": RETRY_MAC,
        "matrix.target": target,
        "matrix.runner": runner,
        "matrix.darwin_on_linux": darwin_on_linux,
        "vars.RUNNER_POOLS": json.dumps({"linux_16": pool}),
        "vars.RUNNER_POOLS.linux_16": pool,
    }
    return route(runs_on(), context)


class RerunLegRereadsPool(unittest.TestCase):
    def test_a_rerun_leg_on_a_small_blacksmith_label_takes_the_live_pool(self) -> None:
        for attempt in (2, 3):
            for small in ("blacksmith-2vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404"):
                self.assertEqual(label(attempt, small), POOL_16, (attempt, small))
                self.assertEqual(label(attempt, small, "aarch64-apple-darwin", darwin_on_linux=True), POOL_16)
                self.assertEqual(label(attempt, small, pool="cmux-fleet-linux-x64"), "cmux-fleet-linux-x64")

    def test_attempt_one_keeps_its_plan(self) -> None:
        for runner in ("blacksmith-2vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404", "cmux-gcp-lane-build-x64"):
            self.assertEqual(label(1, runner), runner)

    def test_a_rerun_keeps_a_label_with_enough_memory(self) -> None:
        for runner in ("blacksmith-8vcpu-ubuntu-2404", POOL_16, "blacksmith-32vcpu-ubuntu-2404",
                       "cmux-gcp-lane-build-x64", "cmux-gcp-nightly-x64", "ubuntu-24.04"):
            self.assertEqual(label(2, runner), runner)

    def test_a_rerun_mac_leg_still_takes_the_retry_runner(self) -> None:
        self.assertEqual(label(2, "glaeda-side-std-xcode-26.6", "aarch64-apple-darwin"), RETRY_MAC)

    def test_a_fork_rerun_never_reads_the_pool(self) -> None:
        for runner in ("blacksmith-2vcpu-ubuntu-2404", POOL_16):
            self.assertEqual(label(2, runner, fork=True, pool="cmux-fleet-linux-x64"), runner)
        self.assertIsNone(fork_pull_request_gate_error(f"    runs-on: {runs_on()}"))


if __name__ == "__main__":
    unittest.main()

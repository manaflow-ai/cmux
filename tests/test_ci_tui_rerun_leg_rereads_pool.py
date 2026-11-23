#!/usr/bin/env python3
"""Linux build retries keep their matrix runner. Native Mac retries may use the retry runner."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from test_ci_tui_routes_avoid_nightly_label import route  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-build-package.yml"
RETRY_MAC = "glaeda-side-std-xcode-26.6"


def runs_on() -> str:
    jobs = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]
    return jobs["build"]["runs-on"]


def label(attempt: int, runner: str, target: str = "x86_64-unknown-linux-musl", *, darwin_on_linux: bool = False) -> str:
    context = {
        "github.run_attempt": attempt,
        "inputs.macos_retry_runner": RETRY_MAC,
        "matrix.target": target,
        "matrix.runner": runner,
        "matrix.darwin_on_linux": darwin_on_linux,
    }
    return route(runs_on(), context)


class BuildLegRunner(unittest.TestCase):
    def test_linux_legs_keep_the_matrix_runner_on_every_attempt(self) -> None:
        for attempt in (1, 2):
            for runner in ("cmux-linux", "ubuntu-24.04", "blacksmith-16vcpu-ubuntu-2404"):
                with self.subTest(attempt=attempt, runner=runner):
                    self.assertEqual(label(attempt, runner), runner)
                    self.assertEqual(label(attempt, runner, "aarch64-apple-darwin", darwin_on_linux=True), runner)

    def test_only_a_native_mac_retry_takes_the_retry_runner(self) -> None:
        self.assertEqual(label(1, "macos-26", "aarch64-apple-darwin"), "macos-26")
        self.assertEqual(label(2, "macos-26", "aarch64-apple-darwin"), RETRY_MAC)


if __name__ == "__main__":
    unittest.main()

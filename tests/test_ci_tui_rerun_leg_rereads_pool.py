#!/usr/bin/env python3
"""A build leg's retry leaves the pool that failed it when its caller names a retry runner.

Native Mac legs take macos_retry_runner; Linux legs (musl, and macOS cross-linked on Linux) take
linux_retry_runner. With no retry runner set (every PR caller) a leg keeps its matrix runner.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from test_ci_tui_routes_avoid_nightly_label import route  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-build-package.yml"
CALLER = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"
RETRY_MAC = "glaeda-side-std-xcode-26.6"
RETRY_LINUX = "cmux-gcp-nightly-x64"
# The build legs' retry: the nightly's on-demand one-job JIT label, off the spot pool (cmuxterm-hq#36618).
RETRY_LINUX_BUILD = "cmux-gcp-nightly-jit-x64"


def runs_on() -> str:
    jobs = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]
    return jobs["build"]["runs-on"]


def label(
    attempt: int,
    runner: str,
    target: str = "x86_64-unknown-linux-musl",
    *,
    darwin_on_linux: bool = False,
    linux_retry: str = "",
) -> str:
    context = {
        "github.run_attempt": attempt,
        "inputs.macos_retry_runner": RETRY_MAC,
        "inputs.linux_retry_runner": linux_retry,
        "matrix.target": target,
        "matrix.runner": runner,
        "matrix.darwin_on_linux": darwin_on_linux,
    }
    return route(runs_on(), context)


class BuildLegRunner(unittest.TestCase):
    def test_linux_legs_keep_the_matrix_runner_without_a_linux_retry_runner(self) -> None:
        for attempt in (1, 2):
            for runner in ("cmux-linux", "ubuntu-24.04", "blacksmith-16vcpu-ubuntu-2404"):
                with self.subTest(attempt=attempt, runner=runner):
                    self.assertEqual(label(attempt, runner), runner)
                    self.assertEqual(label(attempt, runner, "aarch64-apple-darwin", darwin_on_linux=True), runner)

    def test_only_a_native_mac_retry_takes_the_mac_retry_runner(self) -> None:
        self.assertEqual(label(1, "macos-26", "aarch64-apple-darwin"), "macos-26")
        self.assertEqual(label(2, "macos-26", "aarch64-apple-darwin"), RETRY_MAC)
        self.assertEqual(label(2, "macos-26", "aarch64-apple-darwin", linux_retry=RETRY_LINUX), RETRY_MAC)

    def test_a_linux_retry_leaves_the_pool_that_failed_it(self) -> None:
        for target, on_linux in (
            ("x86_64-unknown-linux-musl", False),
            ("aarch64-unknown-linux-musl", False),
            ("aarch64-apple-darwin", True),
        ):
            with self.subTest(target=target):
                kw = {"darwin_on_linux": on_linux, "linux_retry": RETRY_LINUX}
                self.assertEqual(label(1, "cmux-linux", target, **kw), "cmux-linux")
                self.assertEqual(label(2, "cmux-linux", target, **kw), RETRY_LINUX)
                self.assertEqual(label(3, "cmux-linux", target, **kw), RETRY_LINUX)

    def test_nightly_callers_name_the_reserved_linux_retry_label(self) -> None:
        lines = CALLER.read_text(encoding="utf-8").splitlines()
        callers = [line for line in lines if line.strip().startswith("linux_retry_runner:")]
        self.assertGreaterEqual(len(callers), 2, "build-linux and build must pass linux_retry_runner")
        for line in callers:
            self.assertIn(f"'{RETRY_LINUX_BUILD}'", line)
            self.assertIn("github.repository_owner == 'manaflow-ai'", line)


class DaemonTestsRunner(unittest.TestCase):
    """cmux_next_ daemon tests gate publish-tree-tested, so a nightly promote waits on them too."""

    def label(self, attempt: int, event: str = "push", ref: str = "refs/heads/feat-cmux-next") -> str:
        jobs = yaml.load(CALLER.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]
        context = {
            "github.repository_owner": "manaflow-ai",
            "github.run_attempt": attempt,
            "github.event_name": event,
            "github.ref": ref,
        }
        return route(jobs["cmux-next-daemon-tests"]["runs-on"], context)

    def test_first_attempt_keeps_the_shared_pool(self) -> None:
        self.assertEqual(self.label(1), "cmux-linux")
        self.assertEqual(self.label(1, "workflow_dispatch"), "cmux-linux")

    def test_a_nightly_rerun_leaves_the_pool_that_failed_it(self) -> None:
        self.assertEqual(self.label(2), RETRY_LINUX)
        self.assertEqual(self.label(3, ref="refs/heads/nightly-next"), RETRY_LINUX)
        self.assertEqual(self.label(2, "workflow_dispatch", "refs/heads/main"), RETRY_LINUX)

    def test_a_pr_rerun_never_takes_the_reserved_label(self) -> None:
        self.assertEqual(self.label(2, "pull_request", "refs/pull/1/merge"), "cmux-linux")


if __name__ == "__main__":
    unittest.main()

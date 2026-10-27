#!/usr/bin/env python3
"""The warm nightly-next builder's git fetches are bounded and retried (scripts/ci/git_fetch_retry.py).

Run 40466772597 attempt 2 hung in `git fetch origin <sha>` for 62 min, then died
with "early EOF / fetch-pack: invalid index-pack output", killing the nightly.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import git_fetch_retry as retry  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
WARM_STEP = "Checkout build ref (warm nightly-next builder)"


class Run(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.sleeps: list[float] = []
        self.logs: list[str] = []

    def run_with(self, statuses: list[int], tries: int = 3, leave=None) -> tuple[int, list[list[str]]]:
        calls: list[list[str]] = []
        results = iter(statuses)

        def runner(command, timeout):
            calls.append(list(command))
            self.assertEqual(timeout, 600)
            if leave:
                leave()
            return next(results)

        status = retry.run(["git", "fetch", "origin", "abc"], tries=tries, timeout=600, repo=self.repo,
                           runner=runner, sleep=self.sleeps.append, log=self.logs.append)
        return status, calls

    def test_first_success_runs_once(self) -> None:
        status, calls = self.run_with([0])
        self.assertEqual((status, len(calls), self.sleeps), (0, 1, []))

    def test_every_try_sets_the_low_speed_abort(self) -> None:
        _, calls = self.run_with([128, 0])
        for call in calls:
            self.assertEqual(call[:5], ["git", "-c", f"http.lowSpeedLimit={retry.LOW_SPEED_BYTES}",
                                        "-c", f"http.lowSpeedTime={retry.LOW_SPEED_SECONDS}"])
            self.assertEqual(call[5:], ["fetch", "origin", "abc"])

    def test_failures_retry_with_backoff_then_give_up_with_the_last_status(self) -> None:
        status, calls = self.run_with([128, retry.TIMEOUT_EXIT, 128])
        self.assertEqual((status, len(calls)), (128, 3))
        self.assertEqual(self.sleeps, list(retry.BACKOFF_SECONDS))
        self.assertTrue(any("timed out" in line for line in self.logs))

    def test_a_retry_that_succeeds_returns_zero(self) -> None:
        status, calls = self.run_with([128, 0])
        self.assertEqual((status, len(calls), self.sleeps), (0, 2, [retry.BACKOFF_SECONDS[0]]))

    def test_a_failed_try_leaves_no_partial_pack_or_lock(self) -> None:
        git = self.repo / ".git"
        old_lock = git / "refs" / "remotes" / "origin" / "old.lock"
        old_lock.parent.mkdir(parents=True)
        old_lock.write_text("someone else's")
        os.utime(old_lock, (time.time() - 3600, time.time() - 3600))
        module = git / "modules" / "ghostty"
        (module / "objects" / "pack").mkdir(parents=True)
        (module / "HEAD").write_text("ref: refs/heads/main\n")

        def leave() -> None:
            (git / "objects" / "pack").mkdir(parents=True, exist_ok=True)
            (git / "objects" / "pack" / "tmp_pack_x").write_text("partial")
            (git / "shallow.lock").write_text("")
            (module / "objects" / "pack" / "tmp_idx_y").write_text("partial")

        self.run_with([128, 0], leave=leave)
        # The second try left them again and succeeded: only the failed try's leftovers were removed,
        # so check after a final failure instead.
        self.run_with([128], tries=1, leave=leave)
        self.assertEqual(list((git / "objects" / "pack").glob("tmp_*")), [])
        self.assertFalse((git / "shallow.lock").exists())
        self.assertEqual(list((module / "objects" / "pack").glob("tmp_*")), [])
        # A lock older than the try is not ours.
        self.assertTrue(old_lock.exists())

    def test_only_git_commands(self) -> None:
        with self.assertRaises(ValueError):
            retry.low_speed_command(["curl", "x"])


class RunOnce(unittest.TestCase):
    def test_a_hung_command_and_its_children_are_killed_at_the_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            marker = Path(temp) / "child-alive"
            script = f"(sleep 30; touch {marker}) & sleep 30"
            started = time.monotonic()
            status = retry.run_once(["sh", "-c", script], timeout=1)
            self.assertEqual(status, retry.TIMEOUT_EXIT)
            self.assertLess(time.monotonic() - started, 15)

    def test_the_exit_status_passes_through(self) -> None:
        self.assertEqual(retry.run_once(["sh", "-c", "exit 3"], timeout=10), 3)

    def test_the_cli_runs_a_real_git(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            subprocess.run(["git", "init", "-q", temp], check=True)
            result = subprocess.run([sys.executable, str(ROOT / "scripts/ci/git_fetch_retry.py"), "--tries", "1",
                                     "--timeout", "30", "--repo", temp, "--", "git", "-C", temp, "status", "--short"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)


class Workflow(unittest.TestCase):
    def test_the_warm_fetch_and_submodule_update_are_bounded(self) -> None:
        doc = yaml.safe_load(WORKFLOW.read_text())
        step = next(s for s in doc["jobs"]["build-nightly-app"]["steps"] if s.get("name") == WARM_STEP)
        script = step["run"]
        wrapped = "python3 scripts/ci/git_fetch_retry.py --tries 3 --timeout 600 -- \\\n"
        for command in ('git -c protocol.version=2 fetch --no-tags --no-recurse-submodules origin "$BUILD_SHA"',
                        "git -c protocol.version=2 -c core.hooksPath=/dev/null submodule update --init --force"
                        " --depth=1 --recursive"):
            with self.subTest(command=command):
                self.assertIn(wrapped + "  " + command, script)
                # Never also run bare.
                self.assertEqual(script.count(command), 1)


if __name__ == "__main__":
    unittest.main()

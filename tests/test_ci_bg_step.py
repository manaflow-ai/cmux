#!/usr/bin/env python3
"""scripts/ci/bg_step.sh: a step's command runs in the background and a later step takes its verdict.

ci-web.yml's react-apps-check shard 1 starts the merge driver test and the PR-scoped webview rules with it beside
the Oxlint step (they ran one after the other, about 10 of the shard's 14 minutes in run 45527661750). The wait
must block until the command ends, print its output, keep its exit status, and not be held open by a process the
command left behind.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/bg_step.sh"
WORKFLOW = ROOT / ".github/workflows/ci-web.yml"


class BgStepTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="bg-step-")
        self.env = {**os.environ, "BG_STEP_DIR": self.tmp.name}

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args, timeout=30):
        return subprocess.run(["bash", str(SCRIPT), *args], env=self.env, capture_output=True, text=True,
                              timeout=timeout)

    def test_start_returns_at_once_and_wait_takes_the_output_and_status(self):
        began = time.monotonic()
        started = self.run_script("start", "slow", "--", "bash", "-c", "sleep 1.5; echo from-the-check; exit 7")
        self.assertEqual(started.returncode, 0, started.stderr)
        self.assertLess(time.monotonic() - began, 1.0, "start must not wait for the command")
        waited = self.run_script("wait", "slow")
        self.assertGreaterEqual(time.monotonic() - began, 1.4, "wait returned before the command ended")
        self.assertEqual(waited.returncode, 7)
        self.assertIn("from-the-check", waited.stdout)

    def test_a_green_command_waits_green(self):
        self.assertEqual(self.run_script("start", "ok", "--", "true").returncode, 0)
        waited = self.run_script("wait", "ok")
        self.assertEqual(waited.returncode, 0, waited.stdout)

    def test_two_commands_overlap(self):
        began = time.monotonic()
        for name in ("a", "b"):
            self.assertEqual(self.run_script("start", name, "--", "sleep", "1.5").returncode, 0)
        for name in ("a", "b"):
            self.assertEqual(self.run_script("wait", name).returncode, 0)
        self.assertLess(time.monotonic() - began, 2.8, "the two commands ran one after the other")

    def test_a_process_left_behind_does_not_hold_the_wait(self):
        # The command backgrounds a long sleeper and exits: only the command's own end counts.
        pidfile = Path(self.tmp.name) / "sleeper.pid"
        self.assertEqual(self.run_script("start", "leaver", "--", "bash", "-c",
                                         f"sleep 30 >/dev/null 2>&1 & echo $! > {pidfile}; echo left").returncode, 0)
        began = time.monotonic()
        waited = self.run_script("wait", "leaver", timeout=20)
        self.assertEqual(waited.returncode, 0, waited.stdout)
        self.assertLess(time.monotonic() - began, 10)
        os.kill(int(pidfile.read_text()), 15)

    def test_wait_past_its_limit_fails(self):
        self.assertEqual(self.run_script("start", "stuck", "--", "sleep", "5").returncode, 0)
        waited = self.run_script("wait", "stuck", "1")
        self.assertEqual(waited.returncode, 1)
        self.assertIn("still running after 1s", waited.stdout)

    def test_wait_on_a_check_never_started_fails(self):
        waited = self.run_script("wait", "never")
        self.assertEqual(waited.returncode, 1)
        self.assertIn("never started", waited.stdout)

    def test_shard_one_starts_both_checks_before_the_oxlint_step_and_waits_after_it(self):
        workflow = WORKFLOW.read_text()
        block = workflow[workflow.index("  react-apps-check-shard:"):workflow.index("\n  react-apps-base-check:")]
        start = block.index("- name: Start the merge driver test and the PR-scoped webview rules")
        oxlint = block.index("- name: Check webviews (Oxlint, Oxfmt, source rules)")
        merge_wait = block.index("- name: Generated bundle merge driver")
        rules_wait = block.index("- name: Check PR-scoped webview rules")
        self.assertLess(block.index("- name: Build the web bundles"), start)
        self.assertLess(start, oxlint)
        self.assertLess(oxlint, merge_wait)
        self.assertLess(oxlint, rules_wait)
        self.assertLess(max(merge_wait, rules_wait), block.index("- name: Test webviews"))
        self.assertIn("bg_step.sh start merge-driver -- python3 tests/test_install_git_hooks.py", block)
        self.assertIn("bg_step.sh start pr-scoped-rules -- ./scripts/ci/pr_scoped_webviews_rules.sh", block)
        self.assertIn("run: ./scripts/ci/bg_step.sh wait merge-driver", block)
        self.assertIn("run: ./scripts/ci/bg_step.sh wait pr-scoped-rules", block)
        rules = (ROOT / "scripts/ci/pr_scoped_webviews_rules.sh").read_text()
        self.assertIn("scripts/ci/guards_new_reds.py --label \"PR-scoped webview rule\"", rules)


if __name__ == "__main__":
    unittest.main()

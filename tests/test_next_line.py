#!/usr/bin/env python3
"""scripts/ci/next_line.sh: a stacked cmux NEXT pull request is on the cmux NEXT line.

#23442 (2026-10-21) was stacked on another pull request's branch, so ci.yml's
`base.ref != 'feat-cmux-next'` let the main-only static preflight run, and it
went red on cmux NEXT's catalogs. The line comes from the base commit instead.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/next_line.sh"


def git(cwd, *arguments):
    environment = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
                   "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com", "GIT_CONFIG_GLOBAL": os.devnull}
    return subprocess.run(["git", *arguments], cwd=cwd, env=environment, check=True,
                          capture_output=True, text=True).stdout.strip()


class NextLineTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        base = Path(self.directory.name)
        self.origin = base / "origin"
        self.origin.mkdir()
        git(self.origin, "init", "-q", "-b", "main")
        git(self.origin, "config", "uploadpack.allowFilter", "true")
        git(self.origin, "config", "uploadpack.allowAnySHA1InWant", "true")
        (self.origin / "README.md").write_text("main\n")
        git(self.origin, "add", "README.md")
        git(self.origin, "commit", "-q", "-m", "main")
        self.main_sha = git(self.origin, "rev-parse", "HEAD")
        (self.origin / "plans/cmux-next").mkdir(parents=True)
        (self.origin / "plans/cmux-next/README.md").write_text("next\n")
        git(self.origin, "add", "plans")
        git(self.origin, "commit", "-q", "-m", "next")
        self.next_sha = git(self.origin, "rev-parse", "HEAD")
        self.clone = base / "clone"
        git(base, "clone", "-q", "--depth=1", "--branch", "main", f"file://{self.origin}", str(self.clone))

    def tearDown(self):
        self.directory.cleanup()

    def line(self, event, base_ref, base_sha):
        result = subprocess.run([str(SCRIPT), event, base_ref, base_sha], cwd=self.clone,
                                capture_output=True, text=True, check=True)
        return result.stdout.strip()

    def test_a_pull_request_into_feat_cmux_next_is_on_the_line(self):
        self.assertEqual(self.line("pull_request", "feat-cmux-next", ""), "true")

    def test_a_stacked_pull_request_whose_base_has_plans_cmux_next_is_on_the_line(self):
        # The clone only has main; the base commit is fetched, trees only.
        self.assertEqual(self.line("pull_request", "leo/parent-branch", self.next_sha), "true")

    def test_a_pull_request_into_main_or_a_main_stack_is_not(self):
        self.assertEqual(self.line("pull_request", "main", self.main_sha), "false")
        self.assertEqual(self.line("pull_request", "someone/main-stack", self.main_sha), "false")

    def test_other_events_are_not(self):
        self.assertEqual(self.line("merge_group", "", self.next_sha), "false")
        self.assertEqual(self.line("workflow_dispatch", "", ""), "false")

    def test_an_unreadable_base_runs_the_legacy_lanes(self):
        self.assertEqual(self.line("pull_request", "leo/x", "not-a-sha"), "false")
        self.assertEqual(self.line("pull_request", "leo/x", "0" * 40), "false")


if __name__ == "__main__":
    unittest.main()

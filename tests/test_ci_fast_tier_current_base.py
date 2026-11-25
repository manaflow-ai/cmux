#!/usr/bin/env python3
"""scripts/ci/fast_tier_current_base.py rebuilds a stale pull request merge on the base tip, and otherwise leaves it.

Each case builds a real remote and a depth-2 checkout of a merge commit, the way actions/checkout leaves a
pull_request run: the base moved on after the merge was made (the BrowserPageTunables case: the base's fix landed
while the run waited), the base did not move, the pull request conflicts with the new base, HEAD is no merge, the
remote is unreachable, and the checkout has tracked changes.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "fast_tier_current_base.py"
ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
       "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, env=ENV, check=True, capture_output=True, text=True).stdout.strip()


def commit(work: Path, files: dict[str, str], message: str) -> str:
    for name, text in files.items():
        (work / name).write_text(text)
    git(work, "add", "-A")
    git(work, "commit", "-q", "-m", message)
    return git(work, "rev-parse", "HEAD")


class FastTierCurrentBase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.remote = self.tmp / "remote.git"
        git(self.tmp, "init", "-q", "--bare", "-b", "base", str(self.remote))
        self.work = self.tmp / "work"
        git(self.tmp, "clone", "-q", str(self.remote), str(self.work))
        git(self.work, "checkout", "-q", "-b", "base")
        self.b0 = commit(self.work, {"app.txt": "import Browser?\nline\n", "lib.txt": "lib\n"}, "base with a red")
        git(self.work, "push", "-q", "origin", "base")
        git(self.work, "checkout", "-q", "-b", "pr")
        self.head = commit(self.work, {"feature.txt": "feature\n", "lib.txt": "lib\nmore\n"}, "the pull request")
        git(self.work, "checkout", "-q", "base")
        git(self.work, "merge", "-q", "--no-ff", "--no-edit", "pr")
        self.merge = git(self.work, "rev-parse", "HEAD")
        git(self.work, "push", "-q", "origin", f"{self.merge}:refs/pull/1/merge")
        git(self.work, "reset", "-q", "--hard", self.b0)

    def advance_base(self, files: dict[str, str]) -> str:
        tip = commit(self.work, files, "the base moves on")
        git(self.work, "push", "-q", "origin", "base")
        return tip

    def checkout_merge(self) -> Path:
        """A pull_request run's checkout: the merge ref at depth 2, as actions/checkout fetches it."""
        run = self.tmp / "run"
        git(self.tmp, "init", "-q", str(run))
        git(run, "remote", "add", "origin", f"file://{self.remote}")
        git(run, "fetch", "-q", "--no-tags", "--depth=2", "origin", "refs/pull/1/merge")
        git(run, "checkout", "-q", "--detach", "FETCH_HEAD")
        return run

    def run_script(self, run: Path, *extra: str) -> tuple[subprocess.CompletedProcess[str], dict[str, str]]:
        output = self.tmp / "out"
        output.write_text("")
        done = subprocess.run([sys.executable, str(SCRIPT), "--base-ref", "base", "--github-output", str(output),
                               *extra], cwd=run, env=ENV, capture_output=True, text=True)
        pairs = dict(line.split("=", 1) for line in output.read_text().splitlines())
        return done, pairs

    def test_stale_base_is_rebuilt_on_the_tip(self) -> None:
        run = self.checkout_merge()
        tip = self.advance_base({"app.txt": "import Browser\nline\n"})
        done, out = self.run_script(run)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(out, {"rebased": "true", "base": tip, "commit": git(run, "rev-parse", "HEAD")}, done.stdout)
        self.assertEqual(git(run, "rev-parse", "HEAD^1", "HEAD^2").split(), [tip, self.head])
        self.assertEqual((run / "app.txt").read_text(), "import Browser\nline\n", "the base's fix is built")
        self.assertEqual((run / "feature.txt").read_text(), "feature\n", "the pull request's change is built")
        self.assertEqual((run / "lib.txt").read_text(), "lib\nmore\n")
        self.assertEqual(git(run, "status", "--porcelain", "--untracked-files=no"), "")
        self.assertIn("Built on the tip of base", done.stdout)

    def test_three_way_apply_when_the_base_touched_the_same_file(self) -> None:
        run = self.checkout_merge()
        self.advance_base({"lib.txt": "header\nlib\n"})
        done, out = self.run_script(run)
        self.assertEqual(out.get("rebased"), "true", done.stdout)
        self.assertEqual((run / "lib.txt").read_text(), "header\nlib\nmore\n")

    def test_current_base_is_left_alone(self) -> None:
        run = self.checkout_merge()
        done, out = self.run_script(run)
        self.assertEqual((done.returncode, out), (0, {"rebased": "false"}))
        self.assertEqual(git(run, "rev-parse", "HEAD"), self.merge)
        self.assertIn("already on the tip", done.stdout)

    def test_conflict_keeps_the_runs_merge(self) -> None:
        run = self.checkout_merge()
        self.advance_base({"lib.txt": "other\n"})
        done, out = self.run_script(run)
        self.assertEqual((done.returncode, out), (0, {"rebased": "false"}))
        self.assertEqual(git(run, "rev-parse", "HEAD"), self.merge)
        self.assertEqual((run / "lib.txt").read_text(), "lib\nmore\n")
        self.assertIn("does not apply", done.stdout)

    def test_a_head_that_is_no_merge_is_left_alone(self) -> None:
        run = self.checkout_merge()
        git(run, "checkout", "-q", "--detach", "HEAD^1")
        self.advance_base({"app.txt": "fixed\n"})
        done, out = self.run_script(run)
        self.assertEqual((done.returncode, out), (0, {"rebased": "false"}))
        self.assertIn("not a two-parent merge", done.stdout)

    def test_an_unreachable_remote_keeps_the_runs_merge(self) -> None:
        run = self.checkout_merge()
        git(run, "remote", "set-url", "origin", f"file://{self.tmp}/missing.git")
        done, out = self.run_script(run)
        self.assertEqual((done.returncode, out), (0, {"rebased": "false"}))
        self.assertEqual(git(run, "rev-parse", "HEAD"), self.merge)

    def test_tracked_changes_keep_the_runs_merge(self) -> None:
        run = self.checkout_merge()
        self.advance_base({"app.txt": "fixed\n"})
        (run / "lib.txt").write_text("edited\n")
        done, out = self.run_script(run)
        self.assertEqual((done.returncode, out), (0, {"rebased": "false"}))
        self.assertEqual((run / "lib.txt").read_text(), "edited\n")


if __name__ == "__main__":
    unittest.main()

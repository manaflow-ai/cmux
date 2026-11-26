#!/usr/bin/env python3
"""scripts/ci/advisory-idle-step.sh, the controller's idle-class classic API guard step (CI v2 step 6, R8).

A local "remote" holds a base commit with the real guard and its config, a head that changes a path, and the
refs/pull/N/merge commit GitHub would make. The step runs in a clone at the base, as the controller starts it,
and its exit code is the verdict: 0 pass, 10 warn, 4 unknown, 2 bad arguments.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/advisory-idle-step.sh"
GUARD = ROOT / "scripts/ci/classic_api_guard.py"
CONFIG = ROOT / "scripts/ci/classic-auto-deploy.json"
PR = "41"


def git(cwd: Path, *args: str) -> str:
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t",
               GIT_COMMITTER_EMAIL="t@e", GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True,
                          env=env).stdout.strip()


class AdvisoryIdleStepTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.remote = self.tmp / "remote"
        work = self.tmp / "work"
        work.mkdir()
        git(work, "init", "-q", "-b", "main")
        (work / "scripts/ci").mkdir(parents=True)
        shutil.copy(GUARD, work / "scripts/ci/classic_api_guard.py")
        shutil.copy(CONFIG, work / "scripts/ci/classic-auto-deploy.json")
        (work / "README").write_text("base\n")
        git(work, "add", "-A")
        git(work, "commit", "-q", "-m", "base")
        self.base = git(work, "rev-parse", "HEAD")
        self.heads = {}
        for name, path in (("classic", "web/app/api/thing.ts"), ("plain", "docs/notes.txt")):
            git(work, "checkout", "-q", "-b", name, self.base)
            (work / path).parent.mkdir(parents=True, exist_ok=True)
            (work / path).write_text(name + "\n")
            git(work, "add", "-A")
            git(work, "commit", "-q", "-m", name)
            self.heads[name] = git(work, "rev-parse", "HEAD")
        git(work, "checkout", "-q", "main")
        git(self.tmp, "clone", "-q", "--bare", str(work), str(self.remote))
        self.work = work

    def merge_ref(self, head: str) -> None:
        """Point refs/pull/PR/merge at a merge of head into the base, as GitHub does."""
        git(self.work, "checkout", "-q", "--detach", self.base)
        git(self.work, "merge", "-q", "--no-ff", "-m", "merge", head)
        git(self.work, "push", "-q", "-f", str(self.remote), f"HEAD:refs/pull/{PR}/merge")

    def run_step(self, head: str, line: str = "0", *extra: str) -> subprocess.CompletedProcess:
        checkout = self.tmp / "step"
        if not checkout.exists():
            git(self.tmp, "clone", "-q", str(self.remote), str(checkout))
            git(checkout, "checkout", "-q", "--detach", self.base)
            (checkout / "scripts/ci/advisory-idle-step.sh").write_bytes(SCRIPT.read_bytes())
        return subprocess.run(["bash", "scripts/ci/advisory-idle-step.sh", "classic-api-guard", PR, head, line, *extra],
                              cwd=checkout, capture_output=True, text=True,
                              env=dict(os.environ, CMUX_ADVISORY_REMOTE=str(self.remote)))

    def test_a_classic_path_with_no_reason_warns(self) -> None:
        self.merge_ref(self.heads["classic"])
        out = self.run_step(self.heads["classic"])
        self.assertEqual(out.returncode, 10, out.stdout + out.stderr)
        self.assertIn("::warning::Changes a path classic auto-deploys", out.stdout)

    def test_a_reason_line_passes(self) -> None:
        self.merge_ref(self.heads["classic"])
        out = self.run_step(self.heads["classic"], "1")
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("Classic API change accepted", out.stdout)

    def test_no_classic_path_passes(self) -> None:
        self.merge_ref(self.heads["plain"])
        out = self.run_step(self.heads["plain"])
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("No classic auto-deployed API path changed", out.stdout)

    def test_a_merge_of_another_head_is_unknown(self) -> None:
        self.merge_ref(self.heads["plain"])
        out = self.run_step(self.heads["classic"])
        self.assertEqual(out.returncode, 4, out.stdout + out.stderr)

    def test_bad_arguments_are_refused(self) -> None:
        self.merge_ref(self.heads["plain"])
        for head, line in (("nothex", "0"), (self.heads["plain"], "2")):
            self.assertEqual(self.run_step(head, line).returncode, 2)


if __name__ == "__main__":
    unittest.main()

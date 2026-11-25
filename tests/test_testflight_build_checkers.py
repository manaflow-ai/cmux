#!/usr/bin/env python3
"""testflight-build.sh judges an archive with the built commit's checkers, not its own copies.

The cmux INTERNAL builder runs testflight-build.sh from rc/cnx-ios-builder, which moves only when
an admin fast-forwards it. From 2026-11-24 every nightly failed signing: the builder's stale
check-production-binary.sh still forbade the App Review demo's MockTerminalSession, which #47190
ships in every build and #53308 allowed on feat-cmux-next. This test runs the script's
built_checker against a scratch repo whose built commit carries a different checker than the
checkout, and checks that check_app calls both checkers through it.
"""
from __future__ import annotations

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "cmux-next-ios/scripts/testflight-build.sh"
CHECKER = "cmux-next-ios/scripts/check-production-binary.sh"


def function_body(name: str) -> str:
    text = SCRIPT.read_text()
    m = re.search(rf"^{name}\(\) \{{.*?^\}}$", text, re.S | re.M)
    assert m, f"{name} not found in {SCRIPT}"
    return m.group(0)


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True,
                          text=True).stdout.strip()


class BuiltCheckerTests(unittest.TestCase):
    def run_built_checker(self, repo: Path, sha: str, work: Path, rel: str) -> str:
        script = f'set -euo pipefail\nrepo={repo}\nsha={sha}\nwork={work}\n' \
                 f'{function_body("built_checker")}\nbuilt_checker {rel}\n'
        return subprocess.run(["bash", "-c", script], check=True, capture_output=True,
                              text=True).stdout.strip()

    def test_takes_the_built_commits_checker(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, work = Path(tmp) / "repo", Path(tmp) / "work"
            (repo / Path(CHECKER).parent).mkdir(parents=True)
            git(repo.parent, "init", "-q", str(repo))
            git(repo, "config", "user.email", "t@example.com")
            git(repo, "config", "user.name", "t")
            (repo / CHECKER).write_text("echo built\n")
            git(repo, "add", "-A")
            git(repo, "commit", "-qm", "built")
            built = git(repo, "rev-parse", "HEAD")
            # The builder checkout's own copy differs (it is older or newer than the build).
            (repo / CHECKER).write_text("echo builder\n")
            path = self.run_built_checker(repo, built, work, CHECKER)
            self.assertEqual(Path(path).read_text(), "echo built\n")
            self.assertTrue(path.startswith(str(work)))

    def test_falls_back_when_the_commit_lacks_it(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, work = Path(tmp) / "repo", Path(tmp) / "work"
            repo.mkdir()
            git(repo.parent, "init", "-q", str(repo))
            git(repo, "config", "user.email", "t@example.com")
            git(repo, "config", "user.name", "t")
            (repo / "README").write_text("x\n")
            git(repo, "add", "-A")
            git(repo, "commit", "-qm", "old")
            sha = git(repo, "rev-parse", "HEAD")
            self.assertEqual(self.run_built_checker(repo, sha, work, CHECKER), f"{repo}/{CHECKER}")

    def test_check_app_uses_built_checkers(self) -> None:
        body = function_body("check_app")
        self.assertIn("built_checker cmux-next-ios/scripts/check-production-binary.sh", body)
        self.assertIn("built_checker scripts/cmux-next/check-app-store-rules.py", body)
        self.assertNotIn('"$script_dir/check-production-binary.sh"', body)


if __name__ == "__main__":
    unittest.main()

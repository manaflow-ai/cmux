"""An owned Mac's re-used checkout never strands a "build-src" worktree.

Self-hosted runners keep the repository checkout between jobs while they empty
RUNNER_TEMP, so a worktree an earlier job added at "$RUNNER_TEMP/build-src" stays
registered after its folder is gone, and a plain `git worktree add` there fails
("is a missing but already registered worktree", exit 128). That failed the
cmux NIGHTLY-identity sign job of run 41250681368 on cmux14-glaeda-2, so the
legacy NIGHTLY feed (the one com.cmuxterm.app.nightly installs read) missed
build 4125068136801. Every such add must prune stale registrations first.
"""

from __future__ import annotations

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    ROOT / "scripts/ci/nightly-steps/legacy-identity-sign-build-source.sh",
    ROOT / "scripts/ci/nightly-steps/legacy-identity-verify-build-source.sh",
    ROOT / ".github/workflows/stable-next.yml",
]
ADD = re.compile(r'git worktree add\b[^\n]*"\$RUNNER_TEMP/build-src"')


def git(cwd: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(cwd), *args], text=True, capture_output=True, check=check)


class BuildSrcWorktreePruneTests(unittest.TestCase):
    def test_every_build_src_add_prunes_first(self) -> None:
        for path in SOURCES:
            text = path.read_text()
            adds = list(ADD.finditer(text))
            self.assertTrue(adds, f"{path.relative_to(ROOT)} no longer adds $RUNNER_TEMP/build-src")
            for match in adds:
                # The prune must be in the same step: within the lines just before the add.
                before = text[: match.start()].splitlines()[-8:]
                self.assertTrue(
                    any(line.strip() == "git worktree prune" for line in before),
                    f"{path.relative_to(ROOT)}: `{match.group(0)}` without a `git worktree prune` before it",
                )

    def test_prune_recovers_a_stale_registration(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            temp = Path(tmp) / "runner-temp"
            repo.mkdir()
            temp.mkdir()
            git(repo, "init", "-q")
            git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x")
            git(repo, "worktree", "add", "-q", "--detach", str(temp / "build-src"), "HEAD")
            # The runner empties RUNNER_TEMP between jobs; the registration stays.
            subprocess.run(["rm", "-rf", str(temp / "build-src")], check=True)
            stale = git(repo, "worktree", "add", "-q", "--detach", str(temp / "build-src"), "HEAD", check=False)
            self.assertNotEqual(stale.returncode, 0)
            self.assertIn("missing but already registered worktree", stale.stderr)
            git(repo, "worktree", "prune")
            git(repo, "worktree", "add", "-q", "--detach", str(temp / "build-src"), "HEAD")


if __name__ == "__main__":
    unittest.main()

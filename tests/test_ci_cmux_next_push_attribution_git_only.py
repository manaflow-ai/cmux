"""A rate-limited push attribution still names its suspects from local git (retro rb124e0f2)."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import cmux_next_push_attribution as attribution  # noqa: E402


def git(repo: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True,
                          text=True, env=env).stdout.strip()


class GitOnlySuspectsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "base (#1)")
        self.green = git(self.repo, "rev-parse", "HEAD")
        for subject in ("NEXT Cloud: name tabs (#55714)", "direct push fix", "other change (#55722)"):
            git(self.repo, "commit", "-q", "--allow-empty", "-m", subject)
        self.head = git(self.repo, "rev-parse", "HEAD")
        self.cwd = os.getcwd()
        os.chdir(self.repo)

    def tearDown(self) -> None:
        os.chdir(self.cwd)
        self.tmp.cleanup()

    def test_rate_limit_names_the_prs_after_last_known_green(self) -> None:
        summary = Path(self.tmp.name) / "summary.md"
        refused = subprocess.CalledProcessError(1, ["gh", "api"], stderr="gh: API rate limit exceeded for installation")
        argv = ["--repo", "o/r", "--run-id", "9", "--sha", self.head, "--last-known-green", self.green,
                "--summary", str(summary)]
        with mock.patch.object(attribution, "attribute", side_effect=refused), \
                mock.patch("builtins.print") as printed:
            self.assertEqual(attribution.main(argv), 0)
        lines = "\n".join(str(call.args[0]) for call in printed.call_args_list)
        self.assertIn("::warning title=cmux-next push attribution::", lines)
        self.assertIn("#55714, #55722", lines)
        self.assertIn("1 commits name no PR", lines)
        self.assertIn("#55714, #55722", summary.read_text(encoding="utf-8"))

    def test_unprovable_range_names_none(self) -> None:
        self.assertEqual(attribution.git_only_suspects(["--sha", self.head, "--last-known-green", "0" * 40]), [])

    def test_other_errors_still_raise(self) -> None:
        refused = subprocess.CalledProcessError(1, ["gh", "api"], stderr="HTTP 500")
        with mock.patch.object(attribution, "attribute", side_effect=refused):
            with self.assertRaises(subprocess.CalledProcessError):
                attribution.main(["--repo", "o/r", "--run-id", "9", "--sha", self.head])


if __name__ == "__main__":
    unittest.main()

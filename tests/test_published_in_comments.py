"""The "Shipped in" comment each release workflow leaves on its PRs."""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/published_in_comments.py"
spec = importlib.util.spec_from_file_location("published_in_comments", SCRIPT)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class PublishedInTests(unittest.TestCase):
    def test_pr_numbers_from_subject_suffix_once_each(self):
        subjects = ["fix: a (#12)", "feat: b (#11)", "revert fix: a (#12)", "safe-push train", "mentions (#9) mid subject", "c (#10) "]
        self.assertEqual(module.pr_numbers(subjects), [12, 11, 10])

    def test_first_build_creates_then_later_builds_append(self):
        nightly = module.build_line("nightly-next 2026101901", "https://x/n", "a" * 40)
        stable = module.build_line("v0.66.0", "https://x/v", "b" * 40)
        body = module.updated_body(None, nightly)
        self.assertTrue(body.startswith(module.MARKER))
        self.assertIn("`aaaaaaaaaa`", body)
        body = module.updated_body(body, stable)
        self.assertEqual(body.count("\n- "), 2)
        self.assertIsNone(module.updated_body(body, stable), "a rerun of the same build changes nothing")

    def test_dry_run_over_a_git_span(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
            run = lambda *args: subprocess.run(["git", "-C", directory, *args], check=True, capture_output=True, text=True, env=env).stdout.strip()
            run("init", "-q")
            run("commit", "-q", "--allow-empty", "-m", "old (#1)")
            since = run("rev-parse", "HEAD")
            run("commit", "-q", "--allow-empty", "-m", "fix: x (#2)")
            run("commit", "-q", "--allow-empty", "-m", "train commit")
            run("commit", "-q", "--allow-empty", "-m", "feat: y (#3)")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--repo", "o/r", "--since", since, "--head", "HEAD", "--name", "v1", "--url", "https://x", "--dry-run"],
                cwd=directory, capture_output=True, text=True,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([line.split(":")[0] for line in result.stdout.splitlines()[:-1]], ["#3", "#2"])
        self.assertIn("2 PRs, 2 written", result.stdout)

    def test_merged_in_history_is_not_commented(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
            run = lambda *args: subprocess.run(["git", "-C", directory, *args], check=True, capture_output=True, text=True, env=env).stdout.strip()
            run("init", "-q", "-b", "main")
            run("commit", "-q", "--allow-empty", "-m", "base (#100)")
            since = run("rev-parse", "HEAD")
            run("checkout", "-q", "--orphan", "other")
            run("commit", "-q", "--allow-empty", "-m", "another repo's PR (#5)")
            run("checkout", "-q", "main")
            run("merge", "-q", "--allow-unrelated-histories", "-m", "Merge other", "other")
            run("commit", "-q", "--allow-empty", "-m", "fix: x (#101)")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--repo", "o/r", "--since", since, "--head", "HEAD", "--name", "v1", "--url", "https://x", "--dry-run"],
                cwd=directory, capture_output=True, text=True,
            )
        self.assertEqual([line.split(":")[0] for line in result.stdout.splitlines()[:-1]], ["#101"])

    def test_marker_comment_and_rate_limit_detection(self):
        node = {"comments": {"nodes": [
            {"databaseId": 1, "body": module.MARKER + " old", "author": {"login": "someone"}},
            {"databaseId": 2, "body": module.MARKER + "\nShipped in:", "author": {"login": "github-actions"}},
        ]}}
        self.assertEqual(module.marker_comment(node)["id"], 2)
        self.assertIsNone(module.marker_comment({}))
        refusal = subprocess.CalledProcessError(1, "gh", stderr="HTTP 403: You have exceeded a secondary rate limit")
        self.assertTrue(module.rate_limited(refusal))
        self.assertFalse(module.rate_limited(subprocess.CalledProcessError(1, "gh", stderr="HTTP 404: Not Found")))

    def test_unreadable_span_never_fails_the_release(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--repo", "o/r", "--since", "nope", "--head", "HEAD", "--name", "v1", "--url", "https://x"],
                cwd=directory, capture_output=True, text=True,
            )
        self.assertEqual(result.returncode, 0)
        self.assertIn("cannot read", result.stderr)


if __name__ == "__main__":
    unittest.main()

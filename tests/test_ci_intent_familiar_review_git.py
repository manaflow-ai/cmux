"""The familiar-intent warning reads the pull request's patch with git, not the REST API.

Every workflow's GITHUB_TOKEN shares one hourly REST budget; listing a pull request's
files on every push spent about 155 calls an hour of it. This runs the workflow's real
git step against a local repository (no network, no GitHub) and checks it gives the
{filename, patch} list pulls.listFiles gave: merge base to head, hunks only.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/intent-familiar-review.yml"


def steps() -> list[dict]:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return document["jobs"]["warn"]["steps"]


def step(step_id: str) -> dict:
    return next(s for s in steps() if s.get("id") == step_id)


def git(cwd: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
    return subprocess.run(["git", "-C", str(cwd), *args], env=env, check=True,
                          capture_output=True, text=True).stdout.strip()


class GitPatch(unittest.TestCase):
    def setUp(self) -> None:
        self.assertIsNotNone(shutil.which("git"))
        self.assertIsNotNone(shutil.which("jq"))
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, True)
        src = self.dir / "src"
        src.mkdir()
        git(src, "init", "-q", "-b", "main")
        git(src, "config", "uploadpack.allowFilter", "true")
        git(src, "config", "uploadpack.allowAnySHA1InWant", "true")
        (src / "keep.swift").write_text("".join(f"line {i}\n" for i in range(40)))
        (src / "familiar.swift").write_text(
            "// @intent owner=@octo stability=familiar\nlet a = 1\nlet b = 2\n")
        (src / "gone.txt").write_text("bye\n")
        (src / "moved.txt").write_text("".join(f"same {i}\n" for i in range(20)))
        (src / "blob.bin").write_bytes(b"\x00\x01\x02")
        (src / "with space.txt").write_text("old\n")
        git(src, "add", "-A")
        git(src, "commit", "-q", "-m", "base")
        root = git(src, "rev-parse", "HEAD")
        git(src, "checkout", "-q", "-b", "pr")
        (src / "familiar.swift").write_text(
            "// @intent owner=@octo stability=familiar\nlet a = 10\nlet b = 2\n")
        (src / "gone.txt").unlink()
        (src / "moved.txt").rename(src / "renamed.txt")
        (src / "blob.bin").write_bytes(b"\x00\x01\x03")
        (src / "with space.txt").write_text("new\n")
        git(src, "add", "-A")
        git(src, "commit", "-q", "-m", "pr")
        self.head = git(src, "rev-parse", "HEAD")
        # The base moves on after the pull request branched: its change is not the PR's.
        git(src, "checkout", "-q", "main")
        (src / "keep.swift").write_text("base moved\n")
        git(src, "commit", "-q", "-am", "base moves")
        self.base = git(src, "rev-parse", "HEAD")
        self.assertNotEqual(root, self.base)
        self.src = src

    def run_step(self, *, body: str | None = "Body text") -> tuple[subprocess.CompletedProcess, list, str]:
        script = step("git-read")["run"]
        event = self.dir / "event.json"
        event.write_text(json.dumps({"pull_request": {"body": body}}))
        temp = self.dir / "runner-temp"
        temp.mkdir(exist_ok=True)
        env = {**os.environ, "BASE_SHA": self.base, "HEAD_SHA": self.head,
               "REPO_URL": f"file://{self.src}", "WORK": str(temp / "intent-git"),
               "FILES_JSON": str(temp / "intent-files.json"), "BODY_FILE": str(temp / "intent-body.md"),
               "GITHUB_EVENT_PATH": str(event)}
        result = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-c", script], env=env,
                                text=True, capture_output=True, timeout=60)
        files = json.loads((temp / "intent-files.json").read_text()) if result.returncode == 0 else []
        text = (temp / "intent-body.md").read_text() if result.returncode == 0 else ""
        return result, files, text

    def test_patch_matches_the_files_api_shape(self) -> None:
        result, files, body = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        by_name = {item["filename"]: item["patch"] for item in files}
        self.assertEqual(set(by_name), {"familiar.swift", "gone.txt", "renamed.txt", "blob.bin", "with space.txt"})
        familiar = by_name["familiar.swift"]
        self.assertTrue(familiar.startswith("@@ -1,3 +1,3 @@"), familiar)
        self.assertIn("-let a = 1", familiar)
        self.assertIn("+let a = 10", familiar)
        self.assertIn(" // @intent owner=@octo stability=familiar", familiar)
        self.assertNotIn("diff --git", familiar)
        self.assertTrue(by_name["gone.txt"].startswith("@@"))
        self.assertEqual(by_name["renamed.txt"], "")  # a pure rename has no hunks
        self.assertEqual(by_name["blob.bin"], "")  # a binary file has no patch
        self.assertEqual(body.strip(), "Body text")

    def test_base_changes_after_the_branch_point_are_not_the_prs(self) -> None:
        result, files, _ = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("keep.swift", {item["filename"] for item in files})

    def test_missing_body_is_empty(self) -> None:
        result, _, body = self.run_step(body=None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(body.strip(), "")

    def test_a_git_failure_fails_the_step(self) -> None:
        self.head = "0" * 40
        result, _, _ = self.run_step()
        self.assertNotEqual(result.returncode, 0)

    def test_the_api_listing_is_only_the_fallback(self) -> None:
        git_read = step("git-read")
        api_read = step("read")
        detect = step("detect")
        self.assertTrue(git_read.get("continue-on-error"))
        self.assertNotIn("gh api", git_read["run"])
        self.assertNotIn("api.github.com", git_read["run"])
        self.assertIn("steps.git-read.outcome != 'success'", api_read["if"])
        self.assertIn("listFiles", api_read["with"]["script"])
        self.assertIn("steps.git-read.outcome == 'success'", detect["if"])
        self.assertIn("steps.read.outcome == 'success'", detect["if"])
        names = [s.get("id") for s in steps()]
        self.assertLess(names.index("git-read"), names.index("read"))

    def test_nothing_from_the_head_runs(self) -> None:
        script = step("git-read")["run"]
        self.assertIn("--no-ext-diff", script)
        self.assertIn("--no-textconv", script)
        self.assertIn("init -q --bare", script)
        self.assertNotIn("checkout", script)
        # The trusted checkout stays the base's.
        checkout = steps()[0]
        self.assertEqual(checkout["with"]["ref"], "${{ github.event.pull_request.base.sha }}")


if __name__ == "__main__":
    unittest.main()

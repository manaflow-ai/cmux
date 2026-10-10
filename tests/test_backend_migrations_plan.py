"""backend-migrations.yml plan: a PR that does not touch backend/db/migrations
passes without the GitHub API. The installation's API quota ran out under load
and failed the plan on cmux-next UI PRs (#17602, #17609) that change no SQL."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/backend-migrations.yml"


def step_script() -> str:
    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    step = next(s for s in doc["jobs"]["plan"]["steps"] if s.get("name") == "Changed files and head migrations")
    return step["run"]


def git(cwd: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@e", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@e"}
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True, env=env).stdout.strip()


class PlanWithoutTheApi(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        src = self.tmp / "src"
        src.mkdir()
        git(src, "init", "-q", "-b", "main")
        git(src, "config", "uploadpack.allowAnySHA1InWant", "true")
        (src / "backend/db/migrations").mkdir(parents=True)
        (src / "backend/db/migrations/0001_init.sql").write_text("create table t (id int);\n")
        (src / "webviews").mkdir()
        (src / "webviews/App.tsx").write_text("base\n")
        git(src, "add", "-A")
        git(src, "commit", "-qm", "base")
        self.base = git(src, "rev-parse", "HEAD")
        git(src, "checkout", "-q", "-b", "pr")
        self.src = src
        # A gh that answers like the exhausted installation quota.
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text("#!/bin/sh\necho 'gh: API rate limit exceeded for installation. (HTTP 403)' >&2\nexit 1\n")
        (bin_dir / "gh").chmod(0o755)
        self.path = f"{bin_dir}:{os.environ['PATH']}"

    def run_plan(self, head: str) -> tuple[int, str, str]:
        work = self.tmp / "work"
        if work.exists():
            subprocess.run(["rm", "-rf", str(work)], check=True)
        work.mkdir()
        subprocess.run(["git", "clone", "-q", "--depth=1", f"file://{self.src}", str(work / "trusted"), "--branch", "main"], check=True)
        output = self.tmp / "output"
        output.write_text("")
        env = {**os.environ, "PATH": self.path, "GH_TOKEN": "t", "EVENT": "pull_request_target", "PR": "1",
               "BASE_SHA": self.base, "HEAD_SHA": head, "REPO": "o/r", "BASE_REF": "main",
               "GITHUB_OUTPUT": str(output)}
        result = subprocess.run(["bash", "-e", "-c", step_script()], cwd=work, env=env, capture_output=True, text=True)
        return result.returncode, output.read_text(), result.stdout + result.stderr

    def test_a_pr_without_migration_changes_needs_no_api(self):
        (self.src / "webviews/App.tsx").write_text("ui change\n")
        git(self.src, "commit", "-qam", "ui")
        code, output, log = self.run_plan(git(self.src, "rev-parse", "HEAD"))
        self.assertEqual(code, 0, log)
        self.assertIn("migrations=false", output)

    def test_a_pr_that_adds_a_migration_still_lists_its_files(self):
        (self.src / "backend/db/migrations/0002_more.sql").write_text("create table u (id int);\n")
        git(self.src, "add", "-A")
        git(self.src, "commit", "-qm", "migration")
        code, output, log = self.run_plan(git(self.src, "rev-parse", "HEAD"))
        # The listing goes through the API, which this gh refuses: the plan fails
        # closed rather than pass a migration it could not inspect.
        self.assertNotEqual(code, 0, log)
        self.assertNotIn("migrations=false", output)

    def test_unfetchable_head_without_migrations_uses_files_api(self):
        (self.tmp / "bin/gh").write_text("#!/bin/sh\nprintf 'modified\\twebviews/App.tsx\\t\\n'\n")
        code, output, log = self.run_plan("f" * 40)
        self.assertEqual(code, 0, log)
        self.assertIn("migrations=false", output)

    def test_unfetchable_head_with_migrations_fails_closed(self):
        (self.tmp / "bin/gh").write_text("#!/bin/sh\nprintf 'added\\tbackend/db/migrations/0002_more.sql\\t\\n'\n")
        code, output, log = self.run_plan("f" * 40)
        self.assertNotEqual(code, 0, log)
        self.assertIn("migrations=true", output)
        self.assertNotIn("migrations=false", output)


if __name__ == "__main__":
    unittest.main()

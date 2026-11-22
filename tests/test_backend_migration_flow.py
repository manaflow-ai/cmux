#!/usr/bin/env python3
"""Behavior of scripts/check-backend-migration-flow.py in a scratch Git repository."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "check-backend-migration-flow.py"


def sh(cwd, *args):
    subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True)


class BackendMigrationFlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.remote, self.repo = root / "remote.git", root / "work"
        sh(root, "git", "init", "-q", "--bare", "-b", "feat-cmux-next", str(self.remote))
        sh(root, "git", "init", "-q", "-b", "feat-cmux-next", str(self.repo))
        for k, v in (("user.email", "t@example.com"), ("user.name", "t"), ("commit.gpgsign", "false")):
            sh(self.repo, "git", "config", k, v)
        (self.repo / "backend/db/migrations").mkdir(parents=True)
        (self.repo / "backend/db/migrations/0001_init.sql").write_text("CREATE TABLE t (id text);\n")
        sh(self.repo, "git", "add", "-A")
        sh(self.repo, "git", "commit", "-qm", "init")
        sh(self.repo, "git", "remote", "add", "origin", str(self.remote))
        sh(self.repo, "git", "push", "-q", "origin", "feat-cmux-next")

    def tearDown(self):
        self.tmp.cleanup()

    def run_check(self, **env):
        clean = {k: v for k, v in os.environ.items() if k not in ("CI", "GITHUB_ACTIONS", "CMUX_BACKEND_MIGRATION_PR")}
        # No gh credentials: open_pr_base() finds no PR, as for a direct push.
        clean.update(GH_TOKEN="invalid", GH_CONFIG_DIR=self.tmp.name, **env)
        return subprocess.run([sys.executable, str(SCRIPT)], cwd=self.repo, env=clean, capture_output=True, text=True)

    def test_no_migration_change_passes(self):
        (self.repo / "README.md").write_text("x\n")
        self.assertEqual(self.run_check().returncode, 0)

    def test_new_migration_without_pr_fails(self):
        (self.repo / "backend/db/migrations/0002_add.sql").write_text("-- phase: expand\nALTER TABLE t ADD COLUMN n text;\n")
        sh(self.repo, "git", "add", "-A")
        sh(self.repo, "git", "commit", "-qm", "add")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("without an open PR", result.stderr)

    def test_override_for_a_pr_branch_passes(self):
        (self.repo / "backend/db/migrations/0002_add.sql").write_text("-- phase: expand\nALTER TABLE t ADD COLUMN n text;\n")
        self.assertEqual(self.run_check(CMUX_BACKEND_MIGRATION_PR="1").returncode, 0)

    def test_edit_to_shared_migration_fails_even_with_override(self):
        with (self.repo / "backend/db/migrations/0001_init.sql").open("a") as f:
            f.write("-- edited\n")
        result = self.run_check(CMUX_BACKEND_MIGRATION_PR="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("append-only", result.stderr)

    def test_ci_skips(self):
        (self.repo / "backend/db/migrations/0002_add.sql").write_text("x")
        self.assertEqual(self.run_check(CI="true").returncode, 0)


if __name__ == "__main__":
    unittest.main()

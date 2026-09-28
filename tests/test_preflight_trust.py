#!/usr/bin/env python3
"""Harmless marker regressions for code execution during an ordinary Git push."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import git_fixture_env  # disables git auto maintenance


SOURCE = Path(__file__).resolve().parents[1]
MARKER = '''import os
from pathlib import Path
Path(os.environ["CMUX_FIXTURE_MARKER"]).write_text("candidate code executed")
'''
CHECK_CALLER = '''import subprocess, sys
from pathlib import Path
subprocess.run([sys.executable, str(Path(__file__).with_name("candidate-check.py"))], check=True)
'''


class PreflightTrustTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-trust-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repository"
        self.repo.mkdir()
        self.remote = self.root / "remote.git"
        self.marker = self.root / "marker"
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        CMUX_FIXTURE_MARKER=str(self.marker), PYTHONDONTWRITEBYTECODE="1")
        git_fixture_env.without_auto_maintenance(self.env)
        self.git("init", "--quiet", "--initial-branch=main")
        self.git("config", "user.name", "Trust fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("init", "--quiet", "--bare", str(self.remote))
        self.git("remote", "add", "origin", str(self.remote))
        # Copy installed behavior, including the vulnerable hook when running
        # this regression against the before-fix source tree.
        for relative in ("scripts/git-hooks", "scripts/install-git-hooks.sh", "scripts/verify-push.py"):
            source, target = SOURCE / relative, self.repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, target)
            elif source.is_file():
                shutil.copyfile(source, target)
        for hook in (self.repo / "scripts/git-hooks").iterdir():
            hook.chmod(0o755)
        (self.repo / ".gitignore").write_text(".local/\n")
        self.commit("base")
        subprocess.run(["bash", "scripts/install-git-hooks.sh"], cwd=self.repo,
                       env=self.env, check=True, capture_output=True)

    def test_hook_installation_has_no_candidate_code_runner(self):
        """The installed hook set must never execute code from a pushed tree."""
        self.assertFalse((SOURCE / "scripts/git-hooks/pre-push").exists())
        self.assertFalse((SOURCE / "scripts/verify-push.py").exists())
        self.assertFalse((self.repo / "scripts/git-hooks/pre-push").exists())
        self.assertEqual(
            self.git("config", "--get", "core.hooksPath").stdout.strip(),
            "scripts/git-hooks",
        )

    def git(self, *args, check=True):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env,
                              text=True, capture_output=True, check=check)

    def commit(self, title):
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", title)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def prepare_candidate(self, indirect=False):
        if indirect:
            (self.repo / "scripts/verify-local.py").write_text(CHECK_CALLER)
            self.commit("existing wrapper")
        self.git("checkout", "--quiet", "-b", "candidate")
        runner = self.repo / "scripts/verify-local.py"
        if not indirect:
            runner.write_text(MARKER)
        if indirect:
            (self.repo / "scripts/candidate-check.py").write_text(MARKER)
        candidate = self.commit("candidate marker")
        self.git("checkout", "--quiet", "main")
        return candidate

    def test_push_does_not_execute_candidate_runner(self):
        sha = self.prepare_candidate()
        self.git("push", "origin", "candidate:refs/heads/candidate")
        self.assertFalse(self.marker.exists(), "push executed untrusted candidate runner on the host")
        self.assertIn(sha, self.git("ls-remote", "origin", "refs/heads/candidate").stdout)

    def test_push_does_not_execute_candidate_check_through_unchanged_wrapper(self):
        self.prepare_candidate(indirect=True)
        self.git("push", "origin", "candidate:refs/heads/candidate")
        self.assertFalse(self.marker.exists(), "trusted wrapper executed a candidate-controlled child")

    def test_annotated_tag_push_does_not_execute_candidate_code(self):
        sha = self.prepare_candidate()
        self.git("tag", "-a", "candidate-tag", sha, "-m", "fixture")
        self.git("push", "origin", "refs/tags/candidate-tag")
        self.assertFalse(self.marker.exists(), "tag push executed candidate code on the host")

    def test_push_without_checker_does_not_require_materializing_a_snapshot(self):
        before = self.git("status", "--porcelain").stdout
        self.git("push", "origin", "HEAD:refs/heads/main")
        self.assertFalse(self.marker.exists())
        self.assertFalse((self.repo / ".local/cmux-pre-push").exists())
        self.assertEqual(self.git("status", "--porcelain").stdout, before)


if __name__ == "__main__":
    unittest.main()

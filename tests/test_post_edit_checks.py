#!/usr/bin/env python3
"""Tests for scripts/ci/check-post-edit.sh and post_edit_checks.py: advisory, edited files only."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "scripts/ci/check-post-edit.sh"
CHECKS = ROOT / "scripts/ci/post_edit_checks.py"


class PostEditChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        self.git("init", "-q")
        (self.repo / "scripts/ci").mkdir(parents=True)
        shutil.copy(HOOK, self.repo / "scripts/ci/check-post-edit.sh")
        shutil.copy(CHECKS, self.repo / "scripts/ci/post_edit_checks.py")
        self.write("tests/test-execution.toml", '[[test]]\npath = "tests/test_registered.py"\nlane = "linux-guard"\n')
        self.write(".github/workflows/ok.yml", "name: ok\non: push\njobs: {}\n")
        self.write("Packages/macOS/CmuxNext/Sources/Big.swift", "let a = 1\n" * 450)
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "base")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True)

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def hook(self, *paths, payload=None):
        if payload is None:
            payload = {"tool_name": "Edit", "tool_input": {"file_path": str(self.repo / paths[0])}} if len(paths) == 1 \
                else {"tool_input": {"edits": [{"file_path": path} for path in paths]}}
        env = {**os.environ, "PATH": os.environ.get("PATH", "")}
        if not getattr(self, "actionlint", False):
            env["PATH"] = os.pathsep.join(p for p in env["PATH"].split(os.pathsep)
                                          if not (Path(p) / "actionlint").exists())
        result = subprocess.run(["bash", "scripts/ci/check-post-edit.sh"], cwd=self.repo, env=env,
                                input=json.dumps(payload), capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "", "warnings belong on stderr; Codex reads stdout as the hook's JSON")
        return result.stderr

    def test_a_workflow_that_does_not_parse_names_the_line(self):
        self.write(".github/workflows/broken.yml", "name: broken\non: push\njobs:\n  a:\n    steps: [\n")
        out = self.hook(".github/workflows/broken.yml")
        self.assertIn("warning: .github/workflows/broken.yml:", out)
        self.assertIn("does not parse", out)
        self.assertEqual(self.hook(".github/workflows/ok.yml"), "")

    @unittest.skipUnless(shutil.which("actionlint"), "actionlint is not installed")
    def test_actionlint_findings_are_reported_when_it_is_installed(self):
        self.actionlint = True
        self.write(".github/workflows/lint.yml",
                   "name: lint\non: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n"
                   "    steps:\n      - run: echo ${{ github.nope_not_a_context }}\n")
        out = self.hook(".github/workflows/lint.yml")
        self.assertIn("actionlint found", out)

    def test_a_new_unregistered_test_gets_the_registration_command(self):
        self.write("tests/test_new_thing.py", "print('ok')\n")
        out = self.hook("tests/test_new_thing.py")
        self.assertIn("tests/test_new_thing.py is a new test", out)
        self.assertIn("validate_test_execution_registry.py --write --only tests/test_new_thing.py", out)
        # Registered, or already on the base: nothing to say.
        self.write("tests/test_registered.py", "print('ok')\n")
        self.assertEqual(self.hook("tests/test_registered.py"), "")
        self.write("tests/test_old.py", "print('ok')\n")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "old test")
        self.write("tests/test_old.py", "print('edited')\n")
        self.assertEqual(self.hook("tests/test_old.py"), "")

    def test_god_file_warns_only_when_the_edit_grows_a_file_past_its_cap(self):
        small = "Packages/macOS/CmuxNext/Sources/Small.swift"
        self.write(small, "let a = 1\n" * 401)
        self.assertIn("over the 400-line cap (new file)", self.hook(small))
        # Already over the cap at HEAD: an edit that does not grow it says nothing; growing it warns.
        big = "Packages/macOS/CmuxNext/Sources/Big.swift"
        self.write(big, "let a = 1\n" * 440)
        self.assertEqual(self.hook(big), "")
        self.write(big, "let a = 1\n" * 460)
        self.assertIn("was 450 at HEAD", self.hook(big))
        # Outside the checked scopes, size is not this hook's business.
        self.write("docs/long.md", "x\n" * 5000)
        self.assertEqual(self.hook("docs/long.md"), "")

    def test_apply_patch_payloads_and_odd_input_never_fail(self):
        self.write(".github/workflows/broken.yml", "jobs: [\n")
        patch = {"tool_input": {"command": "*** Begin Patch\n*** Update File: .github/workflows/broken.yml\n"}}
        self.assertIn("does not parse", self.hook(payload=patch))
        for payload in ({}, {"tool_input": {"file_path": "/nonexistent/x.yml"}}, "not json"):
            result = subprocess.run(["bash", "scripts/ci/check-post-edit.sh"], cwd=self.repo,
                                    input=payload if isinstance(payload, str) else json.dumps(payload),
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_the_repository_hooks_run_it(self):
        claude = json.loads((ROOT / ".claude/settings.json").read_text())
        codex = json.loads((ROOT / ".codex/hooks.json").read_text())
        for config in (claude, codex):
            commands = [hook["command"] for entry in config["hooks"]["PostToolUse"] for hook in entry["hooks"]]
            self.assertTrue(any("scripts/ci/check-post-edit.sh" in command for command in commands), commands)
        codex_command = next(hook["command"] for entry in codex["hooks"]["PostToolUse"] for hook in entry["hooks"]
                             if "check-post-edit.sh" in hook["command"])
        self.assertIn("1>&2", codex_command)
        self.assertIn("printf '{}", codex_command)


if __name__ == "__main__":
    unittest.main()

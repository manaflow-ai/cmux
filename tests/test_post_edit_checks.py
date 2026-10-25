#!/usr/bin/env python3
"""Tests for scripts/ci/check-post-edit.sh and post_edit_checks.py: advisory, edited files only."""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COPIED = ("scripts/ci/check-post-edit.sh", "scripts/ci/post_edit_checks.py",
          "scripts/cmux-next/check-no-godfiles.sh", "scripts/cmux-next/godfile-baseline.tsv")
HAS_YAML = importlib.util.find_spec("yaml") is not None
PKG = "Packages/macOS/CmuxNext/Sources/CmuxNextThing"


class PostEditChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        self.git("init", "-q")
        for path in COPIED:
            (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / path, self.repo / path)
        (self.repo / "scripts/cmux-next/godfile-baseline.tsv").write_text("# empty baseline\n")
        self.write("tests/test-execution.toml", '[[test]]\npath = "tests/test_registered.py"\nlane = "linux-guard"\n')
        self.write(".github/workflows/ok.yml", "name: ok\non: push\njobs: {}\n")
        self.write(f"{PKG}/Big.swift", "let a = 1\n" * 450)
        self.commit("base")
        self.actionlint = False

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True)

    def commit(self, message):
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", message)

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def env(self):
        env = dict(os.environ)
        if not self.actionlint:
            env["PATH"] = os.pathsep.join(p for p in env.get("PATH", "").split(os.pathsep)
                                          if not (Path(p) / "actionlint").exists())
        return env

    def run_hook(self, payload, cwd=None):
        text = payload if isinstance(payload, str) else json.dumps(payload)
        result = subprocess.run(["bash", str(self.repo / "scripts/ci/check-post-edit.sh")], cwd=cwd or self.repo,
                                env=self.env(), input=text, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def hook(self, *paths, payload=None):
        """The context the agent receives (empty when there is nothing to say)."""
        if payload is None:
            payload = {"tool_name": "Edit", "tool_input": {"file_path": str(self.repo / paths[0])}}
        result = self.run_hook(payload)
        out = json.loads(result.stdout)  # exactly one JSON object, for both hook runners
        if out == {}:
            self.assertEqual(result.stderr, "")
            return ""
        self.assertEqual(out["hookSpecificOutput"]["hookEventName"], "PostToolUse")
        context = out["hookSpecificOutput"]["additionalContext"]
        self.assertTrue(result.stderr.strip(), "a readable copy goes to stderr")
        return context

    @unittest.skipUnless(HAS_YAML, "PyYAML is not installed")
    def test_a_workflow_that_does_not_parse_names_the_line(self):
        self.write(".github/workflows/broken.yml", "name: broken\non: push\njobs:\n  a:\n    steps: [\n")
        out = self.hook(".github/workflows/broken.yml")
        self.assertIn("warning: .github/workflows/broken.yml:", out)
        self.assertIn("does not parse", out)
        self.assertEqual(self.hook(".github/workflows/ok.yml"), "")

    @unittest.skipUnless(shutil.which("actionlint"), "actionlint is not installed")
    def test_actionlint_reports_only_problems_the_edit_added(self):
        self.actionlint = True
        bad_step = "      - run: echo ${{ github.nope_not_a_context }}\n"
        head = "name: lint\non: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n"
        self.write(".github/workflows/lint.yml", head + bad_step)
        self.assertIn("actionlint found 1 new problem", self.hook(".github/workflows/lint.yml"))
        # The same finding already on HEAD is not this edit's: an unrelated edit says nothing.
        self.commit("lint")
        self.write(".github/workflows/lint.yml", head + bad_step + "      - run: echo fine\n")
        self.assertEqual(self.hook(".github/workflows/lint.yml"), "")

    def test_a_new_unregistered_test_gets_the_registration_command(self):
        self.write("tests/test_new_thing.py", "print('ok')\n")
        out = self.hook("tests/test_new_thing.py")
        self.assertIn("tests/test_new_thing.py is a new test", out)
        self.assertIn("validate_test_execution_registry.py --write --only tests/test_new_thing.py", out)
        # Registered, or already on the base: nothing to say.
        self.write("tests/test_registered.py", "print('ok')\n")
        self.assertEqual(self.hook("tests/test_registered.py"), "")
        self.write("tests/test_old.py", "print('ok')\n")
        self.commit("old test")
        self.write("tests/test_old.py", "print('edited')\n")
        self.assertEqual(self.hook("tests/test_old.py"), "")

    def test_god_file_uses_ci_s_own_check_against_head(self):
        small = f"{PKG}/Small.swift"
        self.write(small, "let a = 1\n" * 450)
        self.assertIn("ratchet debt", self.hook(small))
        self.write(small, "let a = 1\n" * 500)
        self.assertIn("god-file check fails this", self.hook(small))
        # Already over the budget at HEAD and not grown by this edit: nothing.
        big = f"{PKG}/Big.swift"
        self.write(big, "let a = 1\n" * 440)
        self.assertEqual(self.hook(big), "")
        # CI does not measure Package.swift or files outside CmuxNext and cmux-tui.
        self.write("Packages/macOS/CmuxNext/Package.swift", "let a = 1\n" * 600)
        self.assertEqual(self.hook("Packages/macOS/CmuxNext/Package.swift"), "")
        self.write("docs/long.md", "x\n" * 5000)
        self.assertEqual(self.hook("docs/long.md"), "")

    def test_rust_test_tiers_follow_ci(self):
        fn = "// line\n"
        self.write("cmux-tui/bindings/examples/x/src/big.rs", fn * 1100)
        self.write("cmux-tui/src/foo_test.rs", fn * 10)
        self.commit("rust")
        # examples/ is a test tier (1500 lines); a foo_test.rs is not (1000 lines).
        self.write("cmux-tui/bindings/examples/x/src/big.rs", fn * 1150)
        self.assertNotIn("big.rs", self.hook("cmux-tui/bindings/examples/x/src/big.rs"))
        self.write("cmux-tui/src/foo_test.rs", "// x\n" * 1100)
        self.assertIn("foo_test.rs", self.hook("cmux-tui/src/foo_test.rs"))

    @unittest.skipUnless(HAS_YAML, "PyYAML is not installed")
    def test_apply_patch_payloads_relative_paths_and_odd_input(self):
        self.write(".github/workflows/broken.yml", "jobs: [\n")
        patch = {"tool_input": {"command": "*** Begin Patch\n*** Update File: .github/workflows/broken.yml\n"}}
        self.assertIn("does not parse", self.hook(payload=patch))
        # A relative path is resolved against the payload's cwd.
        self.assertIn("does not parse", self.hook(payload={"cwd": str(self.repo / ".github"),
                                                           "tool_input": {"file_path": "workflows/broken.yml"}}))
        for payload in ({}, {"tool_input": {"file_path": "/nonexistent/x.yml"}}, "not json"):
            result = self.run_hook(payload)
            self.assertEqual((result.stdout, result.stderr), ("{}\n", ""))
        # Run from a subdirectory, or outside any checkout, it still answers {}.
        self.assertEqual(self.run_hook({}, cwd=self.repo / "tests").stdout, "{}\n")
        with tempfile.TemporaryDirectory() as elsewhere:
            result = subprocess.run(["bash", str(self.repo / "scripts/ci/check-post-edit.sh")], cwd=elsewhere,
                                    input="{}", capture_output=True, text=True, timeout=60)
            self.assertEqual((result.returncode, result.stdout), (0, "{}\n"))

    def test_the_repository_hooks_run_it_and_answer_json(self):
        claude = json.loads((ROOT / ".claude/settings.json").read_text())
        codex = json.loads((ROOT / ".codex/hooks.json").read_text())
        commands = {}
        for name, config in (("claude", claude), ("codex", codex)):
            found = [hook["command"] for entry in config["hooks"]["PostToolUse"] for hook in entry["hooks"]
                     if "scripts/ci/check-post-edit.sh" in hook["command"]]
            self.assertEqual(len(found), 1, name)
            commands[name] = found[0]
        self.write("tests/test_new_thing.py", "print('ok')\n")
        payload = json.dumps({"tool_input": {"file_path": "tests/test_new_thing.py"}})
        env = {**self.env(), "CLAUDE_PROJECT_DIR": str(self.repo)}
        for name, command in commands.items():
            result = subprocess.run(["bash", "-c", command], cwd=self.repo / "tests", env=env, input=payload,
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, name)
            context = json.loads(result.stdout)["hookSpecificOutput"]["additionalContext"]
            self.assertIn("tests/test_new_thing.py is a new test", context, name)


if __name__ == "__main__":
    unittest.main()

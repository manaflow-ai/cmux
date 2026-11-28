#!/usr/bin/env python3
"""scripts/ci/oops/fixit_lint.py: a red web lint whose own safe fixes clear it writes the fixit-compile patch.

Leo, 2026-11-22: "should've been caught and fixed faster. hell, maybe even should've been automatic. how are our
fixit type things for lint errors and random bullshit?"
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "oops" / "fixit_lint.py"

# A fake web lint: --fix rewrites "BAD" to "ok" in every changed file (and touches a non-source file and a file the
# pull request does not change); a check is red while any changed file still says BAD, or FAKE_STILL_RED is set.
FAKE_LINT = r'''
import os, subprocess, sys
args = sys.argv[1:]
base = args[args.index("--base") + 1]
head = args[args.index("--head") + 1]
changed = [p for p in subprocess.run(["git", "diff", "--name-only", base, head], capture_output=True, text=True,
                                     check=True).stdout.splitlines() if p]
if "--fix" in args:
    for p in changed + ["untouched.ts"]:
        if os.path.exists(p):
            text = open(p).read()
            open(p, "w").write(text.replace("BAD", "ok"))
    open("notes.md", "a").write("fixed\n")
    sys.exit(0)
if os.environ.get("FAKE_STILL_RED"):
    sys.exit(1)
sys.exit(1 if any("BAD" in open(p).read() for p in changed if os.path.exists(p)) else 0)
'''


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True,
                          timeout=60).stdout.strip()


class FixitLintTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.out = self.root / "out"
        self.lint = self.root / "fake_lint.py"
        self.lint.write_text(FAKE_LINT)
        git(self.repo, "init", "-q", "-b", "main")
        for k, v in (("user.name", "t"), ("user.email", "t@example.com")):
            git(self.repo, "config", k, v)
        (self.repo / "untouched.ts").write_text("const a = 'BAD';\n")
        (self.repo / "notes.md").write_text("notes\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")
        (self.repo / "app.ts").write_text("export const x = 'BAD';\n")
        (self.repo / "notes.md").write_text("notes\nmore\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "head")
        self.merge = git(self.repo, "rev-parse", "HEAD")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_fix(self, **env: str) -> subprocess.CompletedProcess:
        full = {k: v for k, v in os.environ.items() if not k.startswith(("FIXIT_COMPILE", "GITHUB_"))}
        full.update({"FIXIT_COMPILE_HEAD_SHA": "a" * 40, **env})
        full = {k: v for k, v in full.items() if v != ""}
        return subprocess.run([sys.executable, str(SCRIPT), "run", "--base", self.base, "--merge", self.merge,
                               "--repo", str(self.repo), "--lint", str(self.lint), "--out", str(self.out),
                               "--seconds", "60"], capture_output=True, text=True, env=full, timeout=120)

    def assert_left_at_merge(self) -> None:
        self.assertEqual(git(self.repo, "rev-parse", "HEAD"), self.merge)
        self.assertEqual(git(self.repo, "status", "--porcelain", "--untracked-files=no"), "")

    def test_safe_fix_that_clears_the_red_writes_the_fixit_compile_patch(self) -> None:
        result = self.run_fix()
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads((self.out / "web-lint.json").read_text())
        self.assertEqual(record["fixer"], "fixit-compile")
        self.assertEqual(record["class"], "mechanical")
        self.assertEqual(record["files"], ["app.ts"])
        self.assertEqual(record["head_sha"], "a" * 40)
        self.assertEqual(record["compiled_sha"], self.merge)
        patch = (self.out / "web-lint.patch").read_text()
        self.assertIn("+export const x = 'ok';", patch)
        # Edits outside the pull request's source files never reach the patch.
        self.assertNotIn("notes.md", patch)
        self.assertNotIn("untouched.ts", patch)
        self.assertIn("CI_OOPS=", result.stdout)
        self.assert_left_at_merge()
        # The patch applies to the pull request's tree.
        subprocess.run(["git", "-C", str(self.repo), "apply", "--check", str(self.out / "web-lint.patch")],
                       check=True, timeout=60)

    def test_still_red_after_the_fix_writes_nothing(self) -> None:
        result = self.run_fix(FAKE_STILL_RED="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.out / "web-lint.patch").exists())
        self.assertIn("still red", result.stdout)
        self.assert_left_at_merge()

    def test_off_without_the_ci_head_sha(self) -> None:
        result = self.run_fix(FIXIT_COMPILE_HEAD_SHA="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("off", result.stdout)
        self.assertFalse(self.out.exists())
        self.assert_left_at_merge()

    def test_off_with_fixit_compile_zero(self) -> None:
        result = self.run_fix(FIXIT_COMPILE="0")
        self.assertIn("off", result.stdout)
        self.assertFalse(self.out.exists())

    def test_dirty_checkout_is_left_alone(self) -> None:
        (self.repo / "app.ts").write_text("export const x = 'mine';\n")
        result = self.run_fix()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("edits before the fix", result.stdout)
        self.assertEqual((self.repo / "app.ts").read_text(), "export const x = 'mine';\n")
        self.assertFalse(self.out.exists())


if __name__ == "__main__":
    unittest.main()

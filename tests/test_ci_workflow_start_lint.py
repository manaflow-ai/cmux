#!/usr/bin/env python3
"""scripts/ci/workflow_start_lint.py: only a finding the change adds fails, matched without positions.

The end-to-end case (cmux#55346's duplicate `continue-on-error`) runs when an actionlint binary is on PATH or in
$ACTIONLINT; the job in cmux-next-guards.yml installs one and passes it.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import workflow_start_lint as lint  # noqa: E402


def finding(path: str, line: int, kind: str, message: str) -> dict:
    return {"filepath": path, "line": line, "column": 9, "kind": kind, "message": message}


DUP = 'key "continue-on-error" is duplicated in element of "steps" section. previously defined at line:{},col:9'

# cmux#55346 at fed30dba, the step it doubled (cmux-next-size-budget.yml)
BROKEN = """\
name: size
on:
  workflow_call:
jobs:
  budget:
    runs-on: ubuntu-24.04
    steps:
      - name: Cache Bun package cache
        continue-on-error: true
        timeout-minutes: 3
        continue-on-error: true
        run: echo hi
"""
FIXED = BROKEN.replace("        continue-on-error: true\n        run:", "        run:")


class NewFindings(unittest.TestCase):
    def test_a_finding_already_on_the_base_never_fails(self) -> None:
        base = [finding("a.yml", 10, "expression", "property x is not defined")]
        head = [finding("a.yml", 14, "expression", "property x is not defined")]
        self.assertEqual(lint.new_findings(head, base), [])

    def test_a_moved_duplicate_key_matches_its_base_twin(self) -> None:
        base = [finding("a.yml", 275, "syntax-check", DUP.format(272))]
        head = [finding("a.yml", 301, "syntax-check", DUP.format(298))]
        self.assertEqual(lint.new_findings(head, base), [])

    def test_a_second_copy_of_a_base_finding_is_new(self) -> None:
        base = [finding("a.yml", 1, "expression", "m")]
        head = [finding("a.yml", 1, "expression", "m"), finding("a.yml", 9, "expression", "m")]
        self.assertEqual([f["line"] for f in lint.new_findings(head, base)], [9])

    def test_the_55346_duplicate_key_is_new_against_a_clean_base(self) -> None:
        head = [finding("cmux-next-size-budget.yml", 275, "syntax-check", DUP.format(272))]
        self.assertEqual(lint.new_findings(head, []), head)

    def test_the_annotation_names_the_file_and_line(self) -> None:
        text = lint.annotate(finding(".github/workflows/x.yml", 7, "syntax-check", "bad\nkey"))
        self.assertTrue(text.startswith("::error file=.github/workflows/x.yml,line=7,col=9,"))
        self.assertIn("bad%0Akey", text)


def actionlint() -> str | None:
    return os.environ.get("ACTIONLINT") or shutil.which("actionlint")


@unittest.skipUnless(actionlint(), "no actionlint binary (set ACTIONLINT)")
class EndToEnd(unittest.TestCase):
    def repo(self, base: str, head: str) -> Path:
        root = Path(tempfile.mkdtemp(prefix="workflow-start-lint-test-"))
        self.addCleanup(shutil.rmtree, root, True)
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
               "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        (root / "scripts" / "ci").mkdir(parents=True)
        shutil.copy(ROOT / "scripts" / "ci" / "workflow_start_lint.py", root / "scripts" / "ci")
        (root / ".github" / "workflows").mkdir(parents=True)
        wf = root / ".github" / "workflows" / "size.yml"
        subprocess.run(["git", "init", "-q"], cwd=root, check=True, env=env)
        for text in (base, head):
            wf.write_text(text)
            subprocess.run(["git", "add", "-A"], cwd=root, check=True, env=env)
            subprocess.run(["git", "commit", "-q", "-m", "c"], cwd=root, check=True, env=env)
        return root

    def run_lint(self, root: Path) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", "scripts/ci/workflow_start_lint.py", "--actionlint", actionlint()],
                              cwd=root, capture_output=True, text=True, timeout=120)

    def test_the_change_that_doubles_the_key_fails(self) -> None:
        proc = self.run_lint(self.repo(FIXED, BROKEN))
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn('"continue-on-error" is duplicated', proc.stdout)

    def test_a_head_that_only_carries_the_base_finding_passes(self) -> None:
        proc = self.run_lint(self.repo(BROKEN, BROKEN + "# a comment\n"))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_the_fix_passes(self) -> None:
        proc = self.run_lint(self.repo(BROKEN, FIXED))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)


if __name__ == "__main__":
    unittest.main()

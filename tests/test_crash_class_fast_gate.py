#!/usr/bin/env python3
"""The crash-class rules as a cmux-next fast gate: red only for findings the pull request adds.

cmux-next-crash-class.yml runs three checks: the crash-class concurrency rules
(scripts/ci/crash-class-gate.sh), unrecognized selectors (check-objc-selectors.py) and the
Chromium Objective-C contract (check-cef-objc-contract.py). It is not a fast gate, so
autoland and the merge hook never waited on it, and it was red on most pull requests on
2026-10-21. scripts/ci/crash_class_fast_gate.py runs all three on the merge: the concurrency
rules with `--pr` (already only the files the PR changes), and the two whole-tree checks on
the merge and, when one fails there, on BASE's exported tree, failing only on what the merge adds.

These tests run the gate in a temporary repository whose three checks are stand-ins that
print the findings listed in a file of the tree they are given.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "scripts/ci/crash_class_fast_gate.py"

# Each stand-in prints `<prefix>: <finding>` to stderr for every line of
# scripts/cmux-next/findings-<name>.txt under its --root, then a summary, and exits 1 when
# there was one. A line "CRASH" makes it exit 2 with no finding (a traceback, say).
CHECK = textwrap.dedent("""\
    import argparse, sys
    from pathlib import Path
    p = argparse.ArgumentParser()
    p.add_argument("--root", type=Path, default=Path("."))
    o = p.parse_args()
    data = o.root / "scripts/cmux-next/findings-{name}.txt"
    lines = [l for l in (data.read_text().splitlines() if data.exists() else []) if l]
    with open(Path.cwd() / "calls.log", "a") as log:
        log.write("{name} " + str(o.root.resolve()) + "\\n")
    if "CRASH" in lines:
        print("Traceback (most recent call last):", file=sys.stderr)
        sys.exit(2)
    for line in lines:
        print("{prefix}: " + line, file=sys.stderr)
    print(f"check-{name}: {{len(lines)}} failure(s)")
    sys.exit(1 if lines else 0)
""")
CRASH_CLASS = textwrap.dedent("""\
    #!/usr/bin/env bash
    echo "crash-class $*" >> calls.log
    if [ -s scripts/cmux-next/findings-concurrency.txt ]; then
      sed 's/^/concurrency: /' scripts/cmux-next/findings-concurrency.txt
      exit 1
    fi
    echo "check-concurrency: ok"
""")


def git(repo: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@t"}
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                          env=env).stdout.strip()


class CrashClassFastGate(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="crash-class-gate-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = self.tmp / "merge"
        self.base = self.tmp / "base"
        for tree in (self.repo, self.base):
            (tree / "scripts/cmux-next").mkdir(parents=True)
        (self.repo / "scripts/ci").mkdir(parents=True)
        (self.repo / "scripts/ci/crash-class-gate.sh").write_text(CRASH_CLASS)
        for name, prefix in (("objc-selectors", "objc-selectors"), ("cef-objc-contract", "cef-objc-contract")):
            (self.repo / f"scripts/cmux-next/check-{name}.py").write_text(CHECK.format(name=name, prefix=prefix))
        git(self.tmp, "init", "-q", str(self.repo))

    def findings(self, tree: Path, name: str, *lines: str) -> None:
        (tree / f"scripts/cmux-next/findings-{name}.txt").write_text("".join(f"{line}\n" for line in lines))

    def gate(self) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(GATE), "--base", str(self.base)], cwd=self.repo,
                              capture_output=True, text=True, timeout=60)

    def calls(self) -> list[str]:
        log = self.repo / "calls.log"
        return log.read_text().splitlines() if log.exists() else []

    def test_all_three_pass_on_the_merge_and_the_base_is_not_run(self):
        result = self.gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), ["crash-class --pr", f"objc-selectors {self.repo.resolve()}",
                                        f"cef-objc-contract {self.repo.resolve()}"])

    def test_the_concurrency_rules_run_pr_scoped_and_their_red_stands(self):
        self.findings(self.repo, "concurrency", "Packages/macOS/CmuxNext/Sources/A.swift:3: isolated deinit")
        result = self.gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("crash-class --pr", self.calls())
        self.assertIn("crash-class rules (concurrency)", result.stdout)

    def test_a_finding_the_base_already_has_passes_even_on_another_line(self):
        self.findings(self.repo, "objc-selectors", "Sources/V.swift:40: super.draggingEnded (draggingEnded:): probe needed")
        self.findings(self.base, "objc-selectors", "Sources/V.swift:12: super.draggingEnded (draggingEnded:): probe needed")
        result = self.gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"objc-selectors {self.base.resolve()}", self.calls())
        self.assertIn("already", result.stdout)

    def test_a_finding_the_merge_adds_fails_and_is_named(self):
        self.findings(self.base, "cef-objc-contract", "contract.json: NSApp foo: verdict unreviewed")
        self.findings(self.repo, "cef-objc-contract", "contract.json: NSApp foo: verdict unreviewed",
                      "contract.json: NSApp cancelTerminate: verdict implemented, but CmuxApplication declares none")
        result = self.gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("cancelTerminate", result.stdout)
        self.assertNotRegex(result.stdout, r"::error::.*NSApp foo")

    def test_a_second_copy_of_a_base_finding_is_new(self):
        line = "Sources/V.swift:1: super.mouseDown (mouseDown:): probe needed"
        self.findings(self.base, "objc-selectors", line)
        self.findings(self.repo, "objc-selectors", line, line.replace(":1:", ":9:"))
        self.assertEqual(self.gate().returncode, 1)

    def test_a_check_that_crashes_on_the_merge_fails(self):
        self.findings(self.repo, "objc-selectors", "CRASH")
        result = self.gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("did not run", result.stdout)

    def test_a_base_that_cannot_be_checked_fails_a_red_merge(self):
        self.findings(self.repo, "objc-selectors", "Sources/V.swift:1: super.mouseDown (mouseDown:): probe needed")
        self.findings(self.base, "objc-selectors", "CRASH")
        result = self.gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("cannot be compared", result.stdout)

    def test_every_check_runs_after_one_fails(self):
        self.findings(self.repo, "concurrency", "Packages/macOS/CmuxNext/Sources/A.swift:3: isolated deinit")
        self.gate()
        self.assertEqual(len([c for c in self.calls() if c.startswith(("objc-selectors", "cef-objc-contract"))]), 2)

    def test_it_runs_the_same_checks_as_the_crash_class_workflow(self):
        workflow = (ROOT / ".github/workflows/cmux-next-crash-class.yml").read_text()
        source = GATE.read_text()
        for script in ("scripts/ci/crash-class-gate.sh", "scripts/cmux-next/check-objc-selectors.py",
                       "scripts/cmux-next/check-cef-objc-contract.py"):
            self.assertIn(script, workflow)
            self.assertIn(script, source)

    def test_ci_runs_this_test(self):
        guards = (ROOT / ".github/workflows/cmux-next-guards.yml").read_text()
        self.assertIn("tests/test_crash_class_fast_gate.py", guards)


if __name__ == "__main__":
    unittest.main()

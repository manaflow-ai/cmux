#!/usr/bin/env python3
"""The iOS conventions diff gate must judge a change, not the state of main.

scripts/lint-ios-package-conventions.sh scans the whole repository. Running it
directly on pull requests is what #10409 complains about: one unrelated
violation on main turns every open PR red. scripts/ci/lint-ios-conventions-diff.sh
compares HEAD against the base and reports only the difference, which is what
makes the check safe to run per-PR.
"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
import git_fixture_env  # noqa: F401  (disables git auto maintenance)

ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "scripts/ci/lint-ios-conventions-diff.sh"


def _violation(rule, path, text):
    return f"ERROR   {rule:<28} {path}  {text}"


class ConventionsDiffGate(unittest.TestCase):
    def build(self, base_findings, head_findings, base_files=None, head_files=None):
        """A repo whose stub linter reports one set at base and another at HEAD."""
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(tmp)], check=False)
        (tmp / "scripts/ci").mkdir(parents=True)
        (tmp / "scripts/ci/lint-ios-conventions-diff.sh").write_bytes(GATE.read_bytes())
        os.chmod(tmp / "scripts/ci/lint-ios-conventions-diff.sh", 0o755)

        def write_stub(findings):
            body = "\n".join(f'echo "{line}"' for line in findings)
            stub = tmp / "scripts/lint-ios-package-conventions.sh"
            stub.write_text(f"#!/usr/bin/env bash\n{body}\nexit 0\n")
            os.chmod(stub, 0o755)

        git = lambda *a: subprocess.run(["git", "-C", str(tmp), *a], check=True,
                                        capture_output=True)
        git("init", "-q")
        git("config", "user.email", "t@example.com")
        git("config", "user.name", "t")
        def write_files(files):
            for name, text in (files or {}).items():
                path = tmp / name
                path.parent.mkdir(parents=True, exist_ok=True)
                if text is None:
                    path.unlink(missing_ok=True)
                else:
                    path.write_text(text)

        write_stub(base_findings)
        write_files(base_files)
        git("add", "-A")
        git("commit", "-qm", "base")
        base = subprocess.run(["git", "-C", str(tmp), "rev-parse", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()
        write_stub(head_findings)
        write_files(head_files)
        git("add", "-A")
        git("commit", "-qm", "head", "--allow-empty")
        return tmp, base

    def run_gate(self, base_findings, head_findings, base_files=None, head_files=None):
        tmp, base = self.build(base_findings, head_findings, base_files, head_files)
        return subprocess.run([str(tmp / "scripts/ci/lint-ios-conventions-diff.sh"), base],
                              capture_output=True, text=True, cwd=str(tmp))

    def test_pre_existing_violations_on_the_base_do_not_fail_a_change(self):
        """The #10409 case: main is dirty, the change adds nothing."""
        carried = [_violation("free-function", "Packages/iOS/A.swift:10", "func a()"),
                   _violation("lock", "Packages/iOS/B.swift:3", "let l = NSLock()")]
        result = self.run_gate(carried, carried)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("2 pre-existing", result.stdout)
        self.assertNotIn("NEW", result.stdout)

    def test_a_violation_the_change_introduces_fails_and_is_named(self):
        carried = [_violation("free-function", "Packages/iOS/A.swift:10", "func a()")]
        result = self.run_gate(carried, carried + [
            _violation("lock", "Packages/iOS/B.swift:3", "let l = NSLock()")])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("NEW", result.stdout)
        self.assertIn("Packages/iOS/B.swift", result.stdout)
        self.assertNotIn("Packages/iOS/A.swift", result.stdout.split("FAIL")[0])

    def test_moving_code_is_not_a_new_violation(self):
        """Findings key on (rule, file, text), so a line shift is not 'new'."""
        result = self.run_gate(
            [_violation("free-function", "Packages/iOS/A.swift:10", "func a()")],
            [_violation("free-function", "Packages/iOS/A.swift:870", "func a()")])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("NEW", result.stdout)

    def test_fixing_a_violation_still_passes(self):
        result = self.run_gate(
            [_violation("free-function", "Packages/iOS/A.swift:10", "func a()")], [])
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_an_unavailable_base_reports_rather_than_passing_silently(self):
        tmp, _ = self.build([], [_violation("lock", "Packages/iOS/B.swift:3", "NSLock()")])
        result = subprocess.run(
            [str(tmp / "scripts/ci/lint-ios-conventions-diff.sh"), "0" * 40],
            capture_output=True, text=True, cwd=str(tmp))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("unavailable", result.stdout + result.stderr)

    def test_a_missing_base_argument_is_a_usage_error(self):
        result = subprocess.run([str(GATE)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage", result.stderr)

    RATCHET = "scripts/lint-namespace-types-ratchet.txt"

    def test_an_entry_added_to_the_ratchet_fails(self):
        """A ratchet entry hides its type on both sides, so growth needs its own check."""
        result = self.run_gate([], [], {self.RATCHET: "# header\nA.swift:A\n"},
                               {self.RATCHET: "# header\nA.swift:A\nB.swift:B\n"})
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("GREW", result.stdout)
        self.assertIn("B.swift:B", result.stdout)

    def test_the_ratchet_may_shrink(self):
        result = self.run_gate([], [], {self.RATCHET: "A.swift:A\nB.swift:B\n"},
                               {self.RATCHET: "A.swift:A\n"})
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("GREW", result.stdout)

    def test_seeding_the_ratchet_is_not_growth(self):
        result = self.run_gate([], [], None, {self.RATCHET: "A.swift:A\n"})
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_an_entry_added_to_the_namespace_baseline_fails(self):
        baseline = "scripts/lint-namespace-types-baseline.txt"
        result = self.run_gate([], [], {baseline: "A.swift:A\n"}, {baseline: "A.swift:A\nC.swift:C\n"})
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("C.swift:C", result.stdout)

    def test_an_entry_added_to_the_general_baseline_fails(self):
        baseline = "scripts/lint-ios-package-conventions-baseline.txt"
        result = self.run_gate([], [], {baseline: "lock\tA.swift\tNSLock()\n"},
                               {baseline: "lock\tA.swift\tNSLock()\nlock\tB.swift\tNSLock()\n"})
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("B.swift", result.stdout)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Exercise scripts/static-analysis/gitleaks.sh's completion contract without credentials or network."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/static-analysis/gitleaks.sh"


class GitleaksCompletion(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "--allow-empty", "-qm", "fixture")
        self.out = self.root / "out"
        self.out.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        scanner = self.bin / "gitleaks-8.30.1"
        scanner.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
assert "--redact" in sys.argv
report = pathlib.Path(sys.argv[sys.argv.index("--report-path") + 1])
if os.environ.get("SCAN_WRITE", "1") == "1":
    report.write_text(os.environ.get("SCAN_REPORT", "[]"))
print(os.environ.get("SCAN_LOG", "INF scan finished"), file=sys.stderr)
sys.exit(int(os.environ.get("SCAN_EXIT", "0")))
''')
        scanner.chmod(0o755)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True,
                                       stderr=subprocess.PIPE, timeout=15).strip()

    def scan(self, **extra):
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("GITLEAKS_", "SCAN_"))}
        env.update(SA_TOOLS_DIR=str(self.bin), FAST_CHECKS_OUT=str(self.out),
                   GITLEAKS_RANGE="HEAD", **extra)
        return subprocess.run(["bash", str(SCRIPT)], cwd=self.repo, env=env,
                              text=True, capture_output=True, timeout=20)

    def assert_incomplete(self, result):
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("findings=unknown scan_status=incomplete", result.stdout)
        self.assertNotIn("findings=0", result.stdout)
        self.assertIn("no clean-history conclusion", result.stderr)
        self.assertIn("next:", result.stderr)

    def test_zero_exit_and_empty_report_with_git_errors_is_incomplete(self):
        for log in ("fatal: unable to read missing blob", "ERR git log failed",
                    "FTL cannot scan", "error: object unavailable"):
            with self.subTest(log=log):
                self.assert_incomplete(self.scan(SCAN_LOG=log))

    def test_crash_is_incomplete_even_with_a_report(self):
        self.assert_incomplete(self.scan(SCAN_EXIT="2"))

    def test_missing_report_cannot_reuse_previous_success(self):
        (self.out / "gitleaks.json").write_text("[]")
        (self.out / "gitleaks.txt").write_text("previous success")
        self.assert_incomplete(self.scan(SCAN_WRITE="0"))
        self.assertNotIn("previous success", (self.out / "gitleaks.txt").read_text())

    def test_invalid_report_is_incomplete(self):
        for report in ("", "{", "null", "{}", "[null]", "[{}]"):
            with self.subTest(report=report):
                self.assert_incomplete(self.scan(SCAN_REPORT=report))

    def test_completed_empty_scan_and_warning_are_not_errors(self):
        result = self.scan(SCAN_LOG="WRN no changes in requested range")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("findings=0 scan_status=completed", result.stdout)

    def test_findings_remain_report_only_for_the_ratchet_to_judge(self):
        report = [{"RuleID": "example", "Commit": "a" * 40, "File": "fixture.txt", "StartLine": 1}]
        result = self.scan(SCAN_REPORT=json.dumps(report))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("findings=1 scan_status=completed", result.stdout)
        self.assertEqual(json.loads((self.out / "gitleaks.json").read_text()), report)

    def test_full_history_on_a_shallow_checkout_is_incomplete(self):
        (self.repo / ".git/shallow").write_text(self.git("rev-parse", "HEAD") + "\n")
        result = self.scan(GITLEAKS_FULL="1")
        self.assert_incomplete(result)
        self.assertIn("shallow checkout", result.stderr)


if __name__ == "__main__":
    unittest.main()

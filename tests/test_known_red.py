"""tests/known_red.py: a skip against an issue skips until its checked-in date and fails from it on;
no tracked test skips against an issue without one.

    python3 -I tests/test_known_red.py
"""

from __future__ import annotations

import datetime as dt
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

# Loaded by path: `python3 -I` puts no script folder on sys.path.
_spec = importlib.util.spec_from_file_location("known_red", HERE / "known_red.py")
known_red = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(known_red)


def outcome(until: str, today: str) -> unittest.TestResult:
    class Case(unittest.TestCase):
        @known_red.known_red(41322, until, "line 7: red on the base", today=lambda: dt.date.fromisoformat(today))
        def test_red(self) -> None:
            raise AssertionError("the red test ran")

    result = unittest.TestResult()
    Case("test_red").run(result)
    return result


class KnownRed(unittest.TestCase):
    def test_before_its_date_it_skips_naming_the_issue_and_the_date(self) -> None:
        result = outcome("2026-12-02", "2026-12-01")
        self.assertEqual((len(result.failures), len(result.errors), len(result.skipped)), (0, 0, 1))
        reason = result.skipped[0][1]
        self.assertIn("https://github.com/manaflow-ai/cmux/issues/41322", reason)
        self.assertIn("2026-12-02", reason)
        self.assertIn("line 7: red on the base", reason)

    def test_from_its_date_on_it_fails_and_says_it_expired(self) -> None:
        for today in ("2026-12-02", "2027-03-01"):
            with self.subTest(today=today):
                result = outcome("2026-12-02", today)
                self.assertEqual((len(result.failures), len(result.skipped)), (1, 0))
                self.assertIn("known red past its expiry (2026-12-02)", result.failures[0][1])
                self.assertIn("issues/41322", result.failures[0][1])

    def test_audit_finds_a_bare_skip_against_an_issue(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "test_x.py"
            path.write_text('import unittest\n\nclass T(unittest.TestCase):\n'
                            '    @unittest.skip("red, see https://github.com/o/r/issues/5")\n'
                            '    def test_a(self):\n        pass\n\n'
                            '    @unittest.skip("macOS only")\n'
                            '    def test_b(self):\n        pass\n')
            self.assertEqual(known_red.audit([path]), [f"{path}:4"])

    def test_audit_reads_a_skip_reason_however_it_is_written(self) -> None:
        # cmux#41434 review: only literal positional reasons were read, so these skips slipped past.
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "test_x.py"
            path.write_text('import unittest\nfrom unittest import skip\n\nISSUE = 5\nSEE = "see #5"\n\n'
                            'class T(unittest.TestCase):\n'
                            '    @unittest.skip(reason="red, see #5")\n'                 # 8
                            '    def test_a(self):\n        pass\n\n'
                            '    @unittest.skip("red, " + "see #5")\n'                   # 12
                            '    def test_b(self):\n        pass\n\n'
                            '    @unittest.skip(f"red, see #{ISSUE}")\n'                  # 16
                            '    def test_c(self):\n        pass\n\n'
                            '    @unittest.skip(SEE)\n'                                   # 20
                            '    def test_d(self):\n        pass\n\n'
                            '    @skip("red, see #5")\n'                                  # 24
                            '    def test_e(self):\n        pass\n\n'
                            '    @unittest.skip(f"macOS only ({ISSUE} cores)")\n'         # 28
                            '    def test_f(self):\n        pass\n')
            self.assertEqual(known_red.audit([path]), [f"{path}:{n}" for n in (8, 12, 16, 20, 24)])

    def test_audit_fails_closed_on_a_skip_reason_it_cannot_read(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "test_x.py"
            path.write_text('import unittest\nfrom elsewhere import WHY\n\nclass T(unittest.TestCase):\n'
                            '    @unittest.skip(WHY)\n'
                            '    def test_a(self):\n        pass\n\n'
                            '    @unittest.skip(reason=" ".join(["red", "#5"]))\n'
                            '    def test_b(self):\n        pass\n')
            found = known_red.audit([path])
            self.assertEqual(found, [f"{path}:5: skip reason not readable", f"{path}:9: skip reason not readable"])

    def test_no_tracked_test_skips_against_an_issue_without_an_expiry(self) -> None:
        listed = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", ":(glob)**/test_*.py"],
                                capture_output=True, text=True, check=True).stdout.split("\0")
        paths = [ROOT / p for p in listed if p and (ROOT / p).is_file()]
        self.assertGreater(len(paths), 100)
        self.assertEqual(known_red.audit(paths), [],
                         "use tests/known_red.py's @known_red(issue, until, reason) for a skip against an issue")


if __name__ == "__main__":
    unittest.main()

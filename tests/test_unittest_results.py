#!/usr/bin/env python3
"""scripts/ci/unittest_results.py writes each test's verdict, and guards_new_reds.py charges a pull request only
with the tests red on it and not on its base (ci-web.yml's "Check PR-scoped webview rules": #48230's base finding
made that fixture red on every web-view pull request, #49118)."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "scripts/ci/unittest_results.py"
COMPARE = ROOT / "scripts/ci/guards_new_reds.py"

TESTS = '''import unittest
class Case(unittest.TestCase):
    def test_pass(self):
        pass
    def test_fail(self):
        self.fail("{fail}")
    def test_sub(self):
        with self.subTest(n=1):
            self.assertTrue({sub})
'''


class UnittestResults(unittest.TestCase):
    def results(self, folder, name, text):
        source = Path(folder) / f"{name}.py"
        source.write_text(text)
        out = Path(folder) / f"{name}.json"
        status = subprocess.run([sys.executable, str(RESULTS), str(source), str(out)], capture_output=True,
                                text=True).returncode
        return status, out, json.loads(out.read_text())

    def test_each_verdict_by_class_and_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            status, _, found = self.results(tmp, "head", TESTS.format(fail="red", sub="False"))
        self.assertEqual(status, 1)
        self.assertEqual(found, {"Case.test_pass": True, "Case.test_fail": False, "Case.test_sub": False,
                                 "_cmux_complete": True})

    def test_a_file_that_cannot_load_is_red_and_incomplete(self):
        with tempfile.TemporaryDirectory() as tmp:
            status, _, found = self.results(tmp, "broken", "raise SystemExit('no')\n")
        self.assertEqual(status, 1)
        self.assertFalse(found["_cmux_complete"])
        self.assertIn(False, found.values())

    def test_only_a_red_the_base_lacks_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            # test_fail is red on the base too (a base finding); test_sub is red only on the head.
            _, head, _ = self.results(tmp, "head", TESTS.format(fail="red", sub="False"))
            _, base, _ = self.results(tmp, "base", TESTS.format(fail="red", sub="True"))
            both = subprocess.run([sys.executable, str(COMPARE), "--label", "PR-scoped webview rule", str(head),
                                   str(base)], capture_output=True, text=True)
            self.assertEqual(both.returncode, 1, both.stdout)
            self.assertIn("red on this change::Case.test_sub", both.stdout)
            self.assertIn("red on the base too::Case.test_fail", both.stdout)
            _, head, _ = self.results(tmp, "head", TESTS.format(fail="red", sub="True"))
            base_only = subprocess.run([sys.executable, str(COMPARE), "--label", "PR-scoped webview rule",
                                        str(head), str(base)], capture_output=True, text=True)
            self.assertEqual(base_only.returncode, 0, base_only.stdout)


if __name__ == "__main__":
    unittest.main()

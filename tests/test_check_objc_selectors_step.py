#!/usr/bin/env python3
"""scripts/cmux-next/check-objc-selectors.sh, the fleet step wrapper of check-objc-selectors.py.

The controller allowlists the wrapper with three argument lists only (none, --probe,
--probe --write); the wrapper refuses any other, so a step cannot point the check at another
tree (--root, --source). With no arguments it runs the table check on this checkout.
"""
from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "scripts/cmux-next/check-objc-selectors.sh"
CHECK = ROOT / "scripts/cmux-next/check-objc-selectors.py"


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["/bin/bash", str(WRAPPER), *args], capture_output=True, text=True, cwd="/")


class CheckObjcSelectorsStepTests(unittest.TestCase):
    def test_refuses_arguments_outside_the_allowlist(self) -> None:
        for args in (["--root", "/tmp"], ["--source", "x"], ["--write"], ["--probe", "--write", "--list"],
                     ["--write", "--probe"], ["--probe --write"], ["--probe", ""]):
            with self.subTest(args=args):
                done = run(*args)
                self.assertEqual(done.returncode, 2, done.stderr)
                self.assertIn("arguments must be none, --probe, or --probe --write", done.stderr)

    def test_no_arguments_checks_this_checkout_from_any_directory(self) -> None:
        # From `/`, the wrapper still checks this checkout: the same summary and exit code as the check run
        # here directly, with super calls found (an empty or wrong --root reports 0 and exits 0).
        done = run()
        direct = subprocess.run([sys.executable, "-I", str(CHECK)], capture_output=True, text=True, cwd=ROOT)
        summary = re.search(r"check-objc-selectors: (\d+) super calls", done.stdout)
        self.assertIsNotNone(summary, done.stdout + done.stderr)
        self.assertGreater(int(summary.group(1)), 0, done.stdout)
        self.assertEqual(done.stdout, direct.stdout)
        self.assertEqual(done.returncode, direct.returncode, done.stderr)


if __name__ == "__main__":
    unittest.main()

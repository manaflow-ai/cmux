#!/usr/bin/env python3
"""scripts/cmux-next/check-objc-selectors.sh, the fleet step wrapper of check-objc-selectors.py.

The controller allowlists the wrapper with three argument lists only (none, --probe,
--probe --write); the wrapper refuses any other, so a step cannot point the check at another
tree (--root, --source). With no arguments it runs the table check on this checkout.
"""
from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "scripts/cmux-next/check-objc-selectors.sh"


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
        done = run()
        self.assertIn("check-objc-selectors: ", done.stdout, done.stderr)
        self.assertIn(done.returncode, (0, 1), done.stderr)


if __name__ == "__main__":
    unittest.main()

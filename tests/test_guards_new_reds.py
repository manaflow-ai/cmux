#!/usr/bin/env python3
"""scripts/ci/guards_new_reds.py fails only on guard steps a change turns red; the base's reds are warnings.

The ci guard group never ran for feat-cmux-next before cmux-next-guards.yml's job, and 24 of its 134 steps were
already red there (2026-10-21). A job red on every pull request would hide the red a change adds, so the job
compares each step's result on the head with the same runner's result on the base.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/guards_new_reds.py"


class NewReds(unittest.TestCase):
    def run_it(self, head, base):
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for name, results in (("head", head), ("base", base)):
                path = Path(tmp) / f"{name}.json"
                if results is not None:
                    path.write_text(json.dumps(results))
                paths.append(str(path))
            return subprocess.run([sys.executable, str(SCRIPT), *paths], capture_output=True, text=True)

    def test_a_step_red_only_on_the_head_fails(self):
        done = self.run_it({"lint": False, "wired": True}, {"lint": True, "wired": True})
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("::error title=Guard red on this change::lint", done.stdout)

    def test_a_step_red_on_the_base_too_is_a_warning(self):
        done = self.run_it({"lint": False, "wired": True}, {"lint": False, "wired": True})
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("::warning title=Guard red on the base too::lint", done.stdout)

    def test_a_new_step_that_fails_is_the_changes(self):
        done = self.run_it({"new step": False}, {})
        self.assertEqual(done.returncode, 1)

    def test_a_step_the_change_fixes_is_said(self):
        done = self.run_it({"lint": True}, {"lint": False})
        self.assertEqual(done.returncode, 0)
        self.assertIn("fixed by this change: lint", done.stdout)

    def test_no_base_results_means_every_red_is_the_changes(self):
        done = self.run_it({"lint": False}, None)
        self.assertEqual(done.returncode, 1)
        self.assertIn("no base results", done.stdout)

    def test_no_head_results_fails(self):
        done = self.run_it(None, {"lint": True})
        self.assertEqual(done.returncode, 1)


if __name__ == "__main__":
    unittest.main()

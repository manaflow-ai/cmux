#!/usr/bin/env python3
"""Rows the desktop bench writes are valid scorer rows (score.mjs) with the
right failure category."""
import json
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))


class TrialRowTest(unittest.TestCase):
    def test_categories(self):
        from cua_bench import trial_row
        self.assertNotIn("failure", trial_row(0, "d", True, [10, 20], True))
        self.assertEqual(trial_row(1, "d", False, [10], False)["failure"], "focus_stolen")
        self.assertEqual(trial_row(2, "d", False, [10], True, error="ax_cannot_complete")["failure"], "input")
        self.assertEqual(trial_row(3, "d", False, [10], True)["failure"], "not_landed")

    def test_display_match_ignores_direction_marks(self):
        from cua_bench import shows
        self.assertTrue(shows(["7 + 8", "‎15"], "15"))
        self.assertFalse(shows(["7 + 8", "78"], "15"))

    def test_rows_pass_the_scorer(self):
        from cua_bench import trial_row
        rows = [trial_row(0, "cua", True, [10, 20, 30], True), trial_row(1, "cua", False, [5], True)]
        script = (
            "import { summarize } from './score.mjs';"
            "const rows = JSON.parse(process.argv[1]);"
            "console.log(JSON.stringify(summarize(rows)));"
        )
        done = subprocess.run(["bun", "-e", script, json.dumps(rows)], cwd=HERE.parent, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        summary = json.loads(done.stdout)[0]
        self.assertEqual(summary["n"], 2)
        self.assertEqual(summary["failures"], {"not_landed": 1})
        self.assertEqual(summary["latency_ms"]["click"]["n"], 4)


if __name__ == "__main__":
    unittest.main()

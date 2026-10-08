#!/usr/bin/env python3
"""Behavioral regression checks for the CmuxLink bakeoff summary."""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BAKEOFF = ROOT / "plans" / "cmux-next" / "ios-next" / "bakeoff"
SCRIPT = BAKEOFF / "summarize.py"


class BakeoffSummaryTests(unittest.TestCase):
    def test_string_entries_group_by_filename_like_path_objects(self):
        # All three results have the same rig, but inbox-only is a separate
        # experiment. Only the two raw repeats should contribute to one row.
        names = ["v1-raw-r1.json", "v1-raw-r2.json", "v1-raw-inbox-only-r1.json"]
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for name in names:
                shutil.copyfile(BAKEOFF / "results" / "e1" / name, directory / name)
            manifest = directory / "manifest.json"

            def summarize(entries):
                manifest.write_text(json.dumps({
                    "schema": "cmux-link-bench-manifest/1",
                    "results": entries,
                }), encoding="utf-8")
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), str(manifest)],
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout

            string_output = summarize(names)
            object_output = summarize([{"path": name} for name in names])
            self.assertEqual(string_output, object_output)
            rows = [line.split(" | ")[:2] for line in string_output.splitlines()
                    if line.startswith("| v1-")]
            self.assertEqual(rows, [["| v1-raw", "2"], ["| v1-raw-inbox-only", "1"]])


if __name__ == "__main__":
    unittest.main()

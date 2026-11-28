#!/usr/bin/env python3
"""DaemonWireTypesPlugin's interpreter pick (cmux-tui/bindings/codegen/swift_app/pick-python.sh).

Xcode runs the plugin with PATH=/usr/bin:/bin, so it looks for a 3.10+ Python in fixed folders. Homebrew's
python@3.13, installed as another formula's dependency, links only `python3.13`, not `python3`: on 2026-11-27
aws-m4pro-1 and -3 had /opt/homebrew/bin/python3.13 and no python3, and every CmuxNext build there failed with
"DaemonWireTypesPlugin needs Python 3.10+" after the step's source and setup (6 package-test-lane steps, 10.7 failed
job-hours from 11-26 21:45Z to 11-27 12:30Z; hq REPAIR.md row of hq#32257). The pick takes a versioned
interpreter in those folders too.
"""
from __future__ import annotations

import os
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PICK = ROOT / "cmux-tui/bindings/codegen/swift_app/pick-python.sh"
FOLDERS = ("/opt/homebrew/bin", "/usr/local/bin", "/Library/Frameworks/Python.framework/Versions/Current/bin")


def pick_script() -> str:
    """pick-python.sh less its comments (they name the folders too, and must not be rewritten into the run)."""
    return "\n".join(l for l in PICK.read_text().split("\n") if not l.lstrip().startswith("#"))


FAKE = """#!/bin/sh
# A fake interpreter: the version probe answers VERSION_OK, a run prints which file ran.
if [ "$2" = "-c" ]; then exit {status}; fi
echo "ran $0 $*"
"""


class PickPythonTests(unittest.TestCase):
    def run_pick(self, interpreters: dict[str, dict[str, int]]) -> subprocess.CompletedProcess:
        """interpreters: {folder: {name: probe exit status (0: 3.10+)}}. Every fixed folder is moved under a temp
        root, and PATH holds no interpreter, so only the fixed folders can answer."""
        with tempfile.TemporaryDirectory() as tmp:
            script = pick_script()
            for folder in FOLDERS:
                moved = pathlib.Path(tmp) / folder.lstrip("/")
                moved.mkdir(parents=True)
                script = script.replace(folder, str(moved))
                for name, status in interpreters.get(folder, {}).items():
                    path = moved / name
                    path.write_text(FAKE.format(status=status))
                    path.chmod(0o755)
            empty = pathlib.Path(tmp) / "empty-path"
            empty.mkdir()
            return subprocess.run(["/bin/sh", "-c", script, "sh", "generate.py", "out"], capture_output=True,
                                  text=True, env={"PATH": str(empty)}, timeout=30)

    def test_homebrew_versioned_python_without_a_python3_link(self) -> None:
        result = self.run_pick({"/opt/homebrew/bin": {"python3.13": 0}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("python3.13 -I -B generate.py --out out", result.stdout)

    def test_usr_local_versioned_python(self) -> None:
        result = self.run_pick({"/usr/local/bin": {"python3.12": 0}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("python3.12", result.stdout)

    def test_a_python3_link_to_3_9_is_skipped_for_a_versioned_3_10(self) -> None:
        result = self.run_pick({"/opt/homebrew/bin": {"python3": 1, "python3.11": 0}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("python3.11", result.stdout)

    def test_no_3_10_names_the_fix(self) -> None:
        result = self.run_pick({"/opt/homebrew/bin": {"python3": 1}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("DaemonWireTypesPlugin needs Python 3.10+", result.stderr)


if __name__ == "__main__":
    unittest.main()

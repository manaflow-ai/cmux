#!/usr/bin/env python3
"""cu-driver-bench.sh copies the A/B into the guest with `git archive "$rev" PATHS`, and git archive
refuses a pathspec the rev lacks. #37003 removed scripts/build-cmux-cua.sh and skills/cmux-cua while
the script still named them, so every suite past the probe exited 4 ("could not copy the A/B into the
guest"). The paths it always sends must exist in the tree; any other path goes through the
existence-checked loop, never straight onto the git archive line.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/measure/cu-driver-bench.sh"


class CuDriverBenchArchivePaths(unittest.TestCase):
    def setUp(self) -> None:
        self.text = SCRIPT.read_text(encoding="utf-8")

    def test_always_sent_paths_exist(self) -> None:
        m = re.search(r"^archive_paths=\(([^)]*)\)", self.text, re.M)
        self.assertIsNotNone(m, "cu-driver-bench.sh no longer builds archive_paths")
        paths = m.group(1).split()
        self.assertTrue(paths)
        for p in paths:
            self.assertTrue((ROOT / p).exists(), f"cu-driver-bench.sh always archives {p}, which is gone")

    def test_archive_line_names_no_literal_path(self) -> None:
        lines = [l for l in self.text.splitlines() if re.match(r'\s*git archive "\$rev"', l)]
        self.assertTrue(lines, "no git archive line found")
        for line in lines:
            args = line.split('git archive "$rev"', 1)[1].split("|", 1)[0].split()
            self.assertEqual(args, ['"${archive_paths[@]}"'], f"literal paths on the archive line: {line.strip()}")


if __name__ == "__main__":
    sys.exit(unittest.main())

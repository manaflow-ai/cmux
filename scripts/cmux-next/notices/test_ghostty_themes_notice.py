#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for ghostty_themes_notice.py: the generated notice for the Ghostty
themes the app bundles (Resources/ghostty/themes, from iTerm2-Color-Schemes)."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
import ghostty_themes_notice as themes  # noqa: E402


class GhosttyThemesNoticeTest(unittest.TestCase):
    def test_the_checked_in_themes_match_the_record(self) -> None:
        section = themes.render(ROOT)
        self.assertTrue(section.startswith("<!-- notices-section: ghostty-themes -->\n## Ghostty themes\n"))
        record = json.loads((HERE / "ghostty-themes.json").read_text())
        self.assertIn(record["release"], section)
        self.assertIn(record["commit"], section)
        self.assertIn("Copyright (c) 2011 to Present Mark Badolato", section)

    def test_changed_themes_without_a_new_record_fail(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            shutil.copytree(ROOT / "Resources/ghostty/themes", root / "Resources/ghostty/themes")
            shutil.copytree(HERE, root / "scripts/cmux-next/notices", ignore=shutil.ignore_patterns("__pycache__"))
            shutil.copytree(ROOT / "cmux-tui/build-support/notices/ghostty/pinned-licenses", root / "cmux-tui/build-support/notices/ghostty/pinned-licenses")
            themes.render(root)
            (root / "Resources/ghostty/themes/New Theme").write_text("palette = 0=#000000\n")
            with self.assertRaises(themes.ThemesError):
                themes.render(root)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""cmux-tui release builds use fat LTO with one codegen unit.

The app ships bin/cmux-tui. With thin LTO and 16 codegen units the macOS arm64
release binary was 45.36 MB; fat LTO with one codegen unit makes it 34.26 MB,
for about 1m45s more release build time.
"""

from __future__ import annotations

import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class CmuxTuiReleaseProfileTest(unittest.TestCase):
    def test_release_profile_uses_fat_lto_and_one_codegen_unit(self):
        manifest = tomllib.loads((ROOT / "cmux-tui/Cargo.toml").read_text(encoding="utf-8"))
        release = manifest["profile"]["release"]
        self.assertEqual(release.get("lto"), "fat")
        self.assertEqual(release.get("codegen-units"), 1)


if __name__ == "__main__":
    unittest.main()

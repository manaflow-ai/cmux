#!/usr/bin/env python3
"""cmux-tui release builds use thin LTO; the three heavy crates get 16 codegen units.

Every cmux-tui tree build compiles this profile, and NEXT nightly waits on the
tree. Fat LTO in one codegen unit linked the cmux-tui binary on one core for
about 6 minutes per build leg. Thin LTO with one codegen unit per dependency
and 16 for cmux-tui, cmux-tui-core and acpmux took the cmux-tui group from 606
to 168 s on a 32 vCPU Linux box. Stripped cmux-tui grew 24%, and runtime stayed
within noise. Going back to fat LTO needs a fresh measurement: the build-time
cost lands on every nightly.
"""

from __future__ import annotations

import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEAVY_CRATES = ("cmux-tui", "cmux-tui-core", "acpmux")


class CmuxTuiReleaseProfileTest(unittest.TestCase):
    def setUp(self):
        manifest = tomllib.loads((ROOT / "cmux-tui/Cargo.toml").read_text(encoding="utf-8"))
        self.release = manifest["profile"]["release"]

    def test_release_profile_uses_thin_lto(self):
        self.assertEqual(self.release.get("lto"), "thin")
        self.assertEqual(self.release.get("codegen-units"), 1)

    def test_heavy_crates_get_parallel_codegen_units(self):
        packages = self.release.get("package", {})
        for crate in HEAVY_CRATES:
            with self.subTest(crate=crate):
                self.assertEqual(packages.get(crate, {}).get("codegen-units"), 16)

    def test_heavy_crates_are_workspace_packages(self):
        # A renamed crate would leave its override silently matching nothing.
        for crate in HEAVY_CRATES:
            with self.subTest(crate=crate):
                manifest = ROOT / "cmux-tui/crates" / crate / "Cargo.toml"
                package = tomllib.loads(manifest.read_text(encoding="utf-8"))["package"]
                self.assertEqual(package["name"], crate)


if __name__ == "__main__":
    unittest.main()

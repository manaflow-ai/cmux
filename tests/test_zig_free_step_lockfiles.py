#!/usr/bin/env python3
"""The fleet's Zig gate exempts two cmux-tui-rust-check.sh modes; keep them Zig-free.

The build-fleet controller (cmuxterm-hq build-fleet/cmd/controller/toolchain.go,
ciStepRequirements) places scripts/ci/cmux-tui-rust-check.sh only on hosts with
the Ghostty Zig pin, except its rd-host and optchat-chief modes. Those build
their own workspaces, and no crate in them builds libghostty-vt with Zig. If
either lockfile gains ghostty-vt-sys or ghostty-vt, those steps can land on a
host with an old Zig and fail: remove the mode from ZigFreeModes in hq first.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import zig_free_step_lockfiles as guard  # noqa: E402


class ZigFreeStepLockfilesTest(unittest.TestCase):
    def test_exempt_mode_lockfiles_have_no_ghostty_crate(self) -> None:
        self.assertEqual(set(guard.EXEMPT_MODE_LOCKFILES), {"rd-host", "optchat-chief"})
        for mode, rel in guard.EXEMPT_MODE_LOCKFILES.items():
            path = ROOT / rel
            self.assertTrue(path.is_file(), f"{mode}: {rel} is gone; revisit the hq ZigFreeModes exemption")
            found = guard.ghostty_crates(path.read_text())
            self.assertEqual(found, [], f"{mode}: {rel} now has {found}; remove {mode} from ZigFreeModes in cmuxterm-hq first")

    def test_a_lockfile_with_ghostty_is_caught(self) -> None:
        lock = (
            'version = 4\n\n[[package]]\nname = "anyhow"\nversion = "1.0.0"\n'
            'source = "registry+https://github.com/rust-lang/crates.io-index"\n\n'
            '[[package]]\nname = "ghostty-vt-sys"\nversion = "0.1.0"\n\n'
            '[[package]]\nname = "ghostty-vt"\nversion = "0.1.0"\ndependencies = ["ghostty-vt-sys"]\n'
        )
        self.assertEqual(guard.ghostty_crates(lock), ["ghostty-vt", "ghostty-vt-sys"])


if __name__ == "__main__":
    unittest.main()

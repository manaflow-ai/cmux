#!/usr/bin/env python3
"""scripts/ci/build_class.py: which changes need only a blaze (Rust) build, on the real tree."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from build_class import classify, classify_path  # noqa: E402
from cmux_next_route import app_ffi_inputs, scheme_phase_rust_inputs  # noqa: E402

# A daemon-only crate: neither a CCmuxAppFFI source nor an app scheme build-phase input.
DAEMON_RS = "cmux-tui/crates/cmux-tui/src/main.rs"


class BuildClassTests(unittest.TestCase):
    def test_daemon_crate_is_blaze(self):
        self.assertFalse(any(DAEMON_RS.startswith(p) for p in app_ffi_inputs(ROOT) + scheme_phase_rust_inputs(ROOT)))
        self.assertEqual(classify_path(ROOT, DAEMON_RS)[0], "blaze")

    def test_ffi_crate_is_app(self):
        self.assertEqual(classify_path(ROOT, "cmux-tui/crates/cmux-app-ffi/src/lib.rs")[0], "app")
        # Reached from cmux-app-ffi through a path dependency.
        self.assertEqual(classify_path(ROOT, "cmux-tui/crates/cmux-rd-proto/src/lib.rs")[0], "app")

    def test_scheme_phase_inputs_are_app(self):
        for path in ("cmux-tui/Cargo.lock", "cmux-tui/Cargo.toml", "cmux-tui/crates/cmux-git/src/lib.rs"):
            self.assertEqual(classify_path(ROOT, path)[0], "app", path)

    def test_cmux_tui_file_outside_a_crate_is_app(self):
        self.assertEqual(classify_path(ROOT, "cmux-tui/rustfmt.toml")[0], "app")

    def test_swift_and_docs(self):
        self.assertEqual(classify_path(ROOT, "Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift")[0], "app")
        self.assertEqual(classify_path(ROOT, "docs/ci/cmux-next-tiers.md")[0], "no-compile")
        self.assertEqual(classify_path(ROOT, "README.md")[0], "no-compile")
        # A crate can include_str! its README: the crate's build reads it.
        self.assertEqual(classify_path(ROOT, "cmux-tui/crates/cmux-tui/README.md")[0], "blaze")
        # An app resource image is an app build input (review finding F1 on #36567).
        icon = next(p for p in (ROOT / "Packages/macOS/CmuxNext/Sources").rglob("*.svg"))
        self.assertEqual(classify_path(ROOT, icon.relative_to(ROOT).as_posix())[0], "app")
        self.assertEqual(classify_path(ROOT, "docs/mdm/README.md")[0], "app")

    def test_change_takes_its_heaviest_file(self):
        self.assertEqual(classify(ROOT, [])["class"], "no-compile")
        self.assertEqual(classify(ROOT, ["docs/ci/cmux-next-tiers.md", DAEMON_RS])["class"], "blaze")
        self.assertEqual(classify(ROOT, [DAEMON_RS, "cmux-tui/Cargo.lock"])["class"], "app")


if __name__ == "__main__":
    unittest.main()

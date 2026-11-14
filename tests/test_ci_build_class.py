#!/usr/bin/env python3
"""scripts/ci/build_class.py: which changes need only Rust (blaze) builds, on the real tree."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from build_class import classify, classify_path, rust_workspaces  # noqa: E402

# A daemon-only crate: no Swift compile, app build phase or foreign-language build reads it.
DAEMON_RS = "cmux-tui/crates/cmux-tui/src/main.rs"


class BuildClassTests(unittest.TestCase):
    def test_daemon_crate_is_blaze(self):
        self.assertEqual(classify_path(ROOT, DAEMON_RS)[0], "blaze")
        self.assertEqual(rust_workspaces(ROOT, "cmux-tui/crates/cmux-tui"), ["cmux-tui"])
        self.assertEqual(classify_path(ROOT, "cmux-tui/crates/cmux-tui/README.md")[0], "blaze")

    def test_ffi_crate_is_app(self):
        self.assertEqual(classify_path(ROOT, "cmux-tui/crates/cmux-app-ffi/src/lib.rs")[0], "app")
        # Reached from cmux-app-ffi through a path dependency.
        self.assertEqual(classify_path(ROOT, "cmux-tui/crates/cmux-rd-proto/src/lib.rs")[0], "app")
        # The iOS FFI and the prebuilt xcframework a Package.swift names.
        self.assertEqual(classify_path(ROOT, "cmux-tui/crates/cmux-mobile-ffi/src/lib.rs")[0], "app")
        self.assertEqual(classify_path(ROOT, "cmux-tui/crates/cmux-terminal-client/src/lib.rs")[0], "app")

    def test_scheme_phase_inputs_are_app(self):
        for path in ("cmux-tui/Cargo.lock", "cmux-tui/Cargo.toml", "cmux-tui/crates/cmux-git/src/lib.rs"):
            self.assertEqual(classify_path(ROOT, path)[0], "app", path)

    def test_crate_outside_the_workspace_names_its_own_build(self):
        # cmux-tui excludes cmux-rd-host: it is its own workspace, built on its own (review F1 on
        # #36567). cmux-tui also compiles it, through a macOS-only path dependency.
        crate = "cmux-tui/crates/cmux-rd-host"
        self.assertEqual(rust_workspaces(ROOT, crate), ["cmux-tui", crate])
        self.assertIn(crate + ")", classify_path(ROOT, crate + "/src/main.rs")[1])

    def test_a_member_names_the_workspace_it_joins(self):
        # cmux-sdk-ffi has no [workspace] and sits inside cmux-tui's tree, but its manifest joins
        # ../cmux-app-ffi's workspace (package.workspace), which builds it with one lock.
        self.assertEqual(rust_workspaces(ROOT, "cmux-tui/crates/cmux-sdk-ffi"), ["cmux-tui/crates/cmux-app-ffi"])

    def test_external_rust_user_is_named(self):
        # optchat-chief path-depends on cmux-chief: its blaze build runs too.
        workspaces = rust_workspaces(ROOT, "cmux-tui/crates/cmux-chief")
        self.assertIn("cmux-tui", workspaces)
        self.assertTrue(any(w.startswith("Native/OptChat") for w in workspaces), workspaces)

    def test_everything_outside_crates_is_app(self):
        for path in ("cmux-tui/rustfmt.toml", "Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift",
                     "docs/remote-agents-and-cloud.md", "design/agent-icons/svg/claude.svg", "README.md"):
            self.assertEqual(classify_path(ROOT, path)[0], "app", path)

    def test_change_takes_its_heaviest_file(self):
        self.assertEqual(classify(ROOT, [])["class"], "none")
        self.assertEqual(classify(ROOT, [DAEMON_RS])["class"], "blaze")
        self.assertEqual(classify(ROOT, [DAEMON_RS, "cmux-tui/Cargo.lock"])["class"], "app")

    def test_a_refused_app_ffi_walk_builds_the_app(self):
        # Lead decision 2 (2026-11-11): build_class reads the walk through the router, whose side of a refused walk is
        # "an input": every cmux-tui path is then a CCmuxAppFFI source, so a daemon-only change builds the app too.
        import app_ffi_pin
        import cmux_next_route
        with mock.patch.object(app_ffi_pin, "listed",
                               side_effect=app_ffi_pin.Unresolved("a Rust string that does not end")), \
                mock.patch.dict(cmux_next_route._READ, clear=True):
            self.assertEqual(classify_path(ROOT, DAEMON_RS), ("app", "a CCmuxAppFFI source: the Swift compiles link it"))
            self.assertEqual(classify(ROOT, [DAEMON_RS])["class"], "app")


if __name__ == "__main__":
    unittest.main()

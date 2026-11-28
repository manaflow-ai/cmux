#!/usr/bin/env python3
"""A pull request that changes a crate the iOS Rust workspace depends on starts iOS link FFI on Linux.

cmux#65536 added a pub field to cmux-tui's cmux-cloud-handlers `Hint`; cmux-mobile-link-ffi builds `Hint` with a
struct literal, every iOS check skipped on the PR (no path in pr_router.json reached them), and feat-cmux-next
failed E0063 until cmux#65594. The dependency set comes from the Cargo.toml files (pr_router.expand_cargo_deps).
"""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import pr_router  # noqa: E402

WORKFLOW = "ios-link-ffi-linux.yml"
HINT = "cmux-tui/crates/cmux-cloud-handlers/src/wake_hint.rs"


def starts(files: list[str]) -> bool:
    config = pr_router.load_manifest()[WORKFLOW]
    return pr_router.matches_filter(config, files) and pr_router.reaches(config, files)


class IosFfiDeps(unittest.TestCase):
    def test_the_hint_change_starts_the_ffi_compile(self):
        self.assertTrue(starts([HINT]))

    def test_every_path_dependency_of_the_ios_workspace_starts_it(self):
        deps = pr_router._manifest_path_deps(Path("cmux-next-ios/rust/Cargo.toml"), ROOT)
        self.assertIsNotNone(deps)
        self.assertIn(Path("cmux-tui/crates/cmux-cloud-handlers"), deps)
        for directory in deps:
            self.assertTrue(starts([f"{directory.as_posix()}/src/lib.rs"]), directory)

    def test_an_unrelated_crate_does_not(self):
        self.assertFalse(starts(["cmux-tui/crates/cmux-rd-host/src/main.rs"]))
        self.assertFalse(starts(["docs/handbook/README.md"]))

    def test_a_new_dependency_is_covered_without_a_list(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for rel, text in {
                "ws/Cargo.toml": '[workspace]\nmembers=["a"]\n',
                "ws/a/Cargo.toml": '[package]\nname="a"\n[target.\'cfg(unix)\'.dependencies]\nb={path="../../b"}\n',
                "b/Cargo.toml": '[package]\nname="b"\n[dev-dependencies]\nc={path="../c"}\n',
                "c/Cargo.toml": '[package]\nname="c"\n',
            }.items():
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                (root / rel).write_text(text)
            config = pr_router.expand_cargo_deps({"paths": ["x/**"], "cargo_deps": ["ws/Cargo.toml"]}, root)
            self.assertEqual(set(config["paths"]), {"x/**", "ws/**", "ws/a/**", "b/**", "c/**", "ws/Cargo.lock"})

    def test_an_unreadable_manifest_falls_back_broad(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = pr_router.expand_cargo_deps(
                {"paths": ["x/**"], "cargo_deps": ["gone/Cargo.toml"], "cargo_deps_fallback_globs": ["cmux-tui/crates/**"]},
                Path(tmp))
            self.assertIn("cmux-tui/crates/**", config["paths"])


if __name__ == "__main__":
    unittest.main()

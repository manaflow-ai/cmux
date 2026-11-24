#!/usr/bin/env python3
"""cargo_target_strip.py keeps third-party build output and drops the workspace's own (fast-tier-cargo R2 cache)."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import cargo_target_strip as strip  # noqa: E402


def touch(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"x" * 16)


class StripTest(unittest.TestCase):
    def test_keeps_dependencies_and_drops_workspace_output(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            for profile in (target / "debug", target / "x86_64-unknown-linux-gnu" / "debug"):
                touch(profile / ".fingerprint" / "serde_json-0a1b2c" / "lib-serde_json")
                touch(profile / ".fingerprint" / "cmux-json-3d4e5f" / "lib-cmux_json")
                touch(profile / "build" / "ghostty-vt-sys-77aa" / "output")
                touch(profile / "build" / "libc-99bb" / "output")
                touch(profile / "deps" / "libserde_json-0a1b2c.rlib")
                touch(profile / "deps" / "libcmux_json-3d4e5f.rlib")
                touch(profile / "deps" / "cmux_json-3d4e5f.d")
                touch(profile / "deps" / "cmux_tui_core-aa11bb")
                touch(profile / "incremental" / "cmux_json-1" / "s")
                touch(profile / "cmux-tui")
                touch(profile / ".cargo-lock")
            strip.main([str(target), "--workspace-crates", "cmux-json", "ghostty-vt-sys", "cmux-tui-core", "cmux-tui"])
            for profile in (target / "debug", target / "x86_64-unknown-linux-gnu" / "debug"):
                self.assertTrue((profile / ".fingerprint" / "serde_json-0a1b2c").is_dir())
                self.assertTrue((profile / "build" / "libc-99bb").is_dir())
                self.assertTrue((profile / "deps" / "libserde_json-0a1b2c.rlib").is_file())
                for gone in (".fingerprint/cmux-json-3d4e5f", "build/ghostty-vt-sys-77aa",
                             "deps/libcmux_json-3d4e5f.rlib", "deps/cmux_json-3d4e5f.d",
                             "deps/cmux_tui_core-aa11bb", "incremental", "cmux-tui", ".cargo-lock"):
                    self.assertFalse((profile / gone).exists(), gone)

    def test_strips_the_cargo_groups_directories(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            profile = target / "groups" / "2" / "aarch64-apple-darwin" / "release"
            touch(profile / ".fingerprint" / "serde_json-0a1b2c" / "lib-serde_json")
            touch(profile / ".fingerprint" / "cmux-app-host-3d4e5f" / "lib-cmux_app_host")
            touch(profile / "deps" / "libserde_json-0a1b2c.rlib")
            touch(profile / "deps" / "cmux_app_host-3d4e5f.d")
            touch(profile / "cmux-app-host")
            strip.main([str(target), "--workspace-crates", "cmux-app-host"])
            self.assertTrue((profile / ".fingerprint" / "serde_json-0a1b2c").is_dir())
            self.assertTrue((profile / "deps" / "libserde_json-0a1b2c.rlib").is_file())
            self.assertFalse((profile / ".fingerprint" / "cmux-app-host-3d4e5f").exists())
            self.assertFalse((profile / "deps" / "cmux_app_host-3d4e5f.d").exists())
            self.assertFalse((profile / "cmux-app-host").exists())

    def test_missing_target_is_no_error(self) -> None:
        self.assertEqual(strip.main(["/nonexistent/target", "--workspace-crates", "x"]), 0)

    def test_stem(self) -> None:
        self.assertEqual(strip.stem("libcmux_json-3d4e5f.rlib"), "cmux_json")
        self.assertEqual(strip.stem("cmux-json-3d4e5f"), "cmux_json")
        self.assertEqual(strip.stem("libc-99bb"), "libc")  # a crate whose name starts with "lib"
        self.assertEqual(strip.stem("liblibc-99bb.rlib"), "libc")


if __name__ == "__main__":
    unittest.main()

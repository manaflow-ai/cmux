#!/usr/bin/env python3
"""cargo_target_strip.py keeps third-party build output and drops the workspace's own (fast-tier-cargo R2 cache)."""

from __future__ import annotations

import json
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

    def test_a_test_target_named_like_a_dependency_drops_only_its_binary(self) -> None:
        # cmux-tailnet-local's tests/http.rs is target `http`; the third-party http crate must stay.
        with tempfile.TemporaryDirectory() as tmp:
            profile = Path(tmp) / "debug"
            touch(profile / ".fingerprint" / "http-0a1b2c" / "lib-http")
            touch(profile / "deps" / "libhttp-0a1b2c.rlib")
            touch(profile / "deps" / "libhttp-0a1b2c.rmeta")
            touch(profile / "deps" / "http-0a1b2c.d")
            touch(profile / "deps" / "http-9f8e7d")
            touch(profile / ".fingerprint" / "cmux-tailnet-local-3d4e5f" / "test-integration-test-http")
            strip.main([str(Path(tmp)), "--workspace-crates", "cmux-tailnet-local",
                        "--workspace-binaries", "http", "cmux-tailnet-local"])
            for kept in (".fingerprint/http-0a1b2c", "deps/libhttp-0a1b2c.rlib", "deps/libhttp-0a1b2c.rmeta",
                         "deps/http-0a1b2c.d"):
                self.assertTrue((profile / kept).exists(), kept)
            for gone in ("deps/http-9f8e7d", ".fingerprint/cmux-tailnet-local-3d4e5f"):
                self.assertFalse((profile / gone).exists(), gone)

    def test_keep_leaves_a_workspace_package_whole(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            profile = Path(tmp) / "debug"
            touch(profile / ".fingerprint" / "ghostty-vt-sys-77aa" / "run-build-script-build-script-build")
            touch(profile / "build" / "ghostty-vt-sys-77aa" / "out" / "lib" / "libghostty-vt.a")
            touch(profile / "build" / "ghostty-vt-sys-55cc" / "build-script-build")
            touch(profile / "deps" / "libghostty_vt_sys-88dd.rlib")
            touch(profile / "deps" / "libghostty_vt-99ee.rlib")
            strip.main([str(Path(tmp)), "--workspace-crates", "ghostty-vt-sys", "ghostty-vt",
                        "--keep", "ghostty-vt-sys"])
            for kept in (".fingerprint/ghostty-vt-sys-77aa", "build/ghostty-vt-sys-77aa/out/lib/libghostty-vt.a",
                         "build/ghostty-vt-sys-55cc", "deps/libghostty_vt_sys-88dd.rlib"):
                self.assertTrue((profile / kept).exists(), kept)
            self.assertFalse((profile / "deps" / "libghostty_vt-99ee.rlib").exists())

    def test_cargo_metadata_splits_library_and_binary_names(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            metadata = Path(tmp) / "metadata.json"
            metadata.write_text(json.dumps({"packages": [{"name": "cmux-tailnet-local", "targets": [
                {"name": "cmux_tailnet_local", "kind": ["lib"]}, {"name": "http", "kind": ["test"]},
                {"name": "build-script-build", "kind": ["custom-build"]}]}]}))
            crates, binaries = strip.metadata_names(metadata)
            self.assertEqual(binaries, ["http"])
            self.assertIn("cmux-tailnet-local", crates)
            self.assertNotIn("http", crates)
            profile = Path(tmp) / "target" / "debug"
            touch(profile / ".fingerprint" / "http-0a1b2c" / "lib-http")
            touch(profile / "deps" / "libhttp-0a1b2c.rlib")
            touch(profile / "deps" / "http-9f8e7d")
            strip.main([str(Path(tmp) / "target"), "--cargo-metadata", str(metadata)])
            self.assertTrue((profile / "deps" / "libhttp-0a1b2c.rlib").exists())
            self.assertFalse((profile / "deps" / "http-9f8e7d").exists())

    def test_every_workflow_strips_with_cargo_metadata(self) -> None:
        # A hand-built --workspace-crates list that folds in target names deletes the third-party http and
        # digest (tests/http.rs, tests/digest.rs), so every restore of that R2 entry rebuilt 27 crates.
        root = Path(__file__).resolve().parents[1] / ".github"
        offenders = [
            f"{path.relative_to(root.parent)}:{n}"
            for path in sorted(root.rglob("*.yml"))
            for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1)
            if "cargo_target_strip.py" in line and "python3" in line and "--cargo-metadata" not in line
        ]
        self.assertEqual(offenders, [], "call cargo_target_strip.py with --cargo-metadata")

    def test_missing_target_is_no_error(self) -> None:
        self.assertEqual(strip.main(["/nonexistent/target", "--workspace-crates", "x"]), 0)

    def test_stem(self) -> None:
        self.assertEqual(strip.stem("libcmux_json-3d4e5f.rlib"), "cmux_json")
        self.assertEqual(strip.stem("cmux-json-3d4e5f"), "cmux_json")
        self.assertEqual(strip.stem("libc-99bb"), "libc")  # a crate whose name starts with "lib"
        self.assertEqual(strip.stem("liblibc-99bb.rlib"), "libc")


if __name__ == "__main__":
    unittest.main()

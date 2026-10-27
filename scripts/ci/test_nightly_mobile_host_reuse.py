#!/usr/bin/env python3
"""Portable regression tests; no Rust compiler, SDK or network needed."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("reuse", Path(__file__).with_name("nightly_mobile_host_reuse.py"))
reuse = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reuse)


class MobileReuseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nightly-mobile-reuse-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo"
        self.root.mkdir()
        self.patch = patch.object(reuse, "ROOT", self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        # run()'s default cwd is bound at import time; keep actual git isolated.
        original = reuse.run
        self.runner = patch.object(reuse, "run", side_effect=lambda *args, cwd=None: original(*args, cwd=cwd or self.root))
        self.runner.start()
        self.addCleanup(self.runner.stop)
        self.git("init", "-q")
        self.write("cmux-next-ios/rust/rust-toolchain.toml", '[toolchain]\nchannel="1.95.0"\n')
        self.write("cmux-next-ios/rust/src.rs", "source")
        self.write("cmux-tui/Cargo.toml", "manifest")
        self.write("scripts/cmux-next/build-mobile-host.sh", "recipe")
        self.write("scripts/ci/nightly_mobile_host_reuse.py", "reuse recipe")
        self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True).strip()

    def write(self, path, contents):
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(contents)
        return destination

    def commit(self):
        self.git("add", ".")
        self.git("-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "-qm", "fixture")

    def test_source_key_survives_unrelated_commits_but_changes_for_inputs(self):
        before = reuse.source_key("HEAD", "arm64")
        self.write("README.md", "unrelated")
        self.commit()
        self.assertEqual(before, reuse.source_key("HEAD", "arm64"))
        for path in ("cmux-next-ios/rust/src.rs", "cmux-tui/Cargo.toml",
                     "scripts/cmux-next/build-mobile-host.sh", ".cargo/config.toml"):
            self.write(path, "changed")
            self.commit()
            after = reuse.source_key("HEAD", "arm64")
            self.assertNotEqual(before, after, path)
            before = after
        self.assertNotEqual(before, reuse.source_key("HEAD", "arm64 x86_64"))

    def test_resolver_keys_the_selected_revision_without_checkout(self):
        before = reuse.source_key("HEAD", "arm64")
        old = self.git("rev-parse", "HEAD")
        self.write("cmux-next-ios/rust/src.rs", "changed")
        self.commit()
        self.assertEqual(before, reuse.source_key(old, "arm64"))
        self.assertNotEqual(before, reuse.source_key("HEAD", "arm64"))

    def test_toolchain_change_misses_but_source_change_keeps_compiler_cache(self):
        original = {"source": "a" * 64, "sdk": "26A123", "rustc": "1.95.0", "archs": "arm64"}
        for field in ("sdk", "rustc", "archs"):
            changed = dict(original, **{field: "different"})
            self.assertNotEqual(reuse.identity_key(original), reuse.identity_key(changed))
            self.assertNotEqual(reuse.toolchain_key(original), reuse.toolchain_key(changed))
        changed = dict(original, source="b" * 64)
        self.assertNotEqual(reuse.identity_key(original), reuse.identity_key(changed))
        self.assertEqual(reuse.toolchain_key(original), reuse.toolchain_key(changed))

    def test_dirty_or_mismatched_sources_never_get_a_builder_key(self):
        source = reuse.source_key("HEAD", "arm64")
        with self.assertRaisesRegex(ValueError, "differ"):
            reuse.identity("f" * 64, "arm64")
        self.write("cmux-next-ios/rust/src.rs", "dirty")
        with self.assertRaisesRegex(ValueError, "modified"):
            reuse.identity(source, "arm64")

    def test_hit_skips_build_and_corruption_rebuilds(self):
        cache = Path(self.temp.name) / "cache"
        output = Path(self.temp.name) / "out" / "host"
        key, compiler = "a" * 64, "b" * 64
        calls = []

        def fake_build(command, **kwargs):
            calls.append(command)
            env = kwargs["env"]
            self.assertIn(key, env["CMUX_NEXT_MOBILE_HOST_CACHE"])
            self.assertTrue(env["CMUX_NEXT_MOBILE_HOST_TARGET_DIR"].endswith(compiler))
            Path(env["CMUX_NEXT_MOBILE_HOST_CACHE"]).mkdir(parents=True)
            (cache / reuse.BINARY).write_bytes(b"built binary")
            (cache / f"{reuse.BINARY}.ref").write_text("original provenance")

        with patch.object(reuse.subprocess, "run", side_effect=fake_build):
            reuse.build(cache, output, key, compiler, "arm64")
            self.assertEqual(len(calls), 1)
            reuse.build(cache, output, key, compiler, "arm64")
            self.assertEqual(len(calls), 1, "a valid hit must skip the build")
            self.assertEqual(output.read_bytes(), b"built binary")
            self.assertTrue(os.access(output, os.X_OK))
            self.assertEqual(output.with_name("host.ref").read_text(), "original provenance")
            (cache / reuse.BINARY).write_bytes(b"corrupt")
            reuse.build(cache, output, key, compiler, "arm64")
            self.assertEqual(len(calls), 2)
        self.assertFalse(reuse.reusable(cache, "c" * 64))
        (cache / "manifest.json").write_text("[]")
        self.assertFalse(reuse.reusable(cache, key))

    def test_record_cannot_reuse_a_symlink_or_altered_provenance(self):
        cache = Path(self.temp.name) / "cache"
        cache.mkdir()
        binary, ref = cache / reuse.BINARY, cache / f"{reuse.BINARY}.ref"
        binary.write_bytes(b"binary")
        ref.write_text("provenance")
        key = "a" * 64
        (cache / "manifest.json").write_text(json.dumps({"key": key, "sha256": reuse.digest(binary.read_bytes()),
                                                        "ref_sha256": reuse.digest(ref.read_bytes())}))
        self.assertTrue(reuse.reusable(cache, key))
        ref.write_text("altered")
        self.assertFalse(reuse.reusable(cache, key))
        ref.write_text("provenance")
        other = cache / "other"
        binary.rename(other)
        binary.symlink_to(other)
        self.assertFalse(reuse.reusable(cache, key))


if __name__ == "__main__":
    unittest.main()

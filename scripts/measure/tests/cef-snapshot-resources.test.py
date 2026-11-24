#!/usr/bin/env python3
"""A substituted engine must never retain another build's V8 snapshots."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "cef_snapshot_resources", Path(__file__).resolve().parents[1] / "cef-snapshot-resources.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SnapshotPairingTests(unittest.TestCase):
    def test_replaces_all_snapshots_and_preserves_other_resources(self):
        with tempfile.TemporaryDirectory() as root:
            source, app = Path(root) / "source", Path(root) / "app"
            source.mkdir()
            app.mkdir()
            names = ["v8_context_snapshot.arm64.bin", "snapshot_blob.bin"]
            for name in names:
                (source / name).write_bytes(b"new build snapshot")
                (app / name).write_bytes(b"old build snapshot")
            (app / "resources.pak").write_bytes(b"shipped resources")
            receipt = module.pair_snapshots(source, app)
            self.assertEqual({r["name"] for r in receipt}, set(names))
            self.assertTrue(all(r["before_sha256"] != r["after_sha256"] for r in receipt))
            for name in names:
                self.assertEqual((app / name).read_bytes(), b"new build snapshot")
            self.assertEqual((app / "resources.pak").read_bytes(), b"shipped resources")

    def test_missing_snapshot_fails_before_mutating_app(self):
        with tempfile.TemporaryDirectory() as root:
            source, app = Path(root) / "source", Path(root) / "app"
            source.mkdir()
            app.mkdir()
            (app / "snapshot_blob.bin").write_bytes(b"old build snapshot")
            with self.assertRaises(ValueError):
                module.pair_snapshots(source, app)
            self.assertEqual((app / "snapshot_blob.bin").read_bytes(), b"old build snapshot")


if __name__ == "__main__":
    unittest.main()

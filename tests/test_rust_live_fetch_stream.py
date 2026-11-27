#!/usr/bin/env python3
"""rust-live.py's build-host pull: Builder.stream_codec() picks a stream both ends can run, pull_stream()
strips, packs and unpacks the binary in one ssh, and a failed stream leaves no partial file and drops
back to rsync. A fake ssh on PATH runs the remote command here, so this needs no second machine."""
import importlib.util
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("rust_live", ROOT / "scripts/cmux-next/rust-live.py")
rust_live = importlib.util.module_from_spec(spec)
sys.modules["rust_live"] = rust_live  # dataclasses look their module up here
spec.loader.exec_module(rust_live)

FAKE_SSH = '#!/bin/bash\nwhile [ "$1" = "-o" ]; do shift 2; done\nshift\nexec bash -c "$*"\n'


class PullStream(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "ssh").write_text(FAKE_SSH)
        (bin_dir / "ssh").chmod(0o755)
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "CMUX_RUST_LIVE_STATE_DIR": str(self.tmp / "state")}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.builder = rust_live.Builder(self.tmp, self.tmp / "state", "fakehost", None)
        self.built = self.tmp / "built"
        self.built.write_bytes(os.urandom(1 << 16) + b"cmux" * (1 << 18))

    def test_picks_a_codec_both_ends_have(self):
        codec = self.builder.stream_codec()
        self.assertIsNotNone(codec)
        self.assertIn(codec[1].split()[0], ("zstd", "gzip"))

    def test_stream_strips_and_brings_the_binary_back(self):
        staged = self.tmp / "staged"
        strip = f"cp {self.built} {self.built}.live"
        self.assertTrue(self.builder.pull_stream(self.builder.stream_codec(), strip, f"{self.built}.live", staged))
        self.assertEqual(staged.read_bytes(), self.built.read_bytes())
        self.assertFalse((self.tmp / "staged.partial").exists())

    def test_failed_stream_keeps_the_last_build_and_falls_back(self):
        staged = self.tmp / "staged"
        staged.write_bytes(b"last build")
        self.assertFalse(self.builder.pull_stream(self.builder.stream_codec(), "false", "/nonexistent", staged))
        self.assertEqual(staged.read_bytes(), b"last build")
        self.assertFalse((self.tmp / "staged.partial").exists())
        self.assertIsNone(self.builder.stream_codec())  # the rest of this run uses rsync

    def test_rsync_on_request(self):
        with mock.patch.dict(os.environ, {"CMUX_RUST_LIVE_FETCH": "rsync"}):
            builder = rust_live.Builder(self.tmp, self.tmp / "state", "fakehost", None)
            self.assertIsNone(builder.stream_codec())


if __name__ == "__main__":
    unittest.main()

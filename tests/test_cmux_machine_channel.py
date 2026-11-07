#!/usr/bin/env python3
"""The Cloud machine channel payload is the same whether it comes from the published manifest or
from this run's own Linux build.

point-machine-channel-early (cmux-tui-artifacts.yml) points the channel as soon as build-linux is
done, before publish writes cmux-tui/<sha>/manifest.json, so scripts/ci/cmux-machine-channel.py
takes each sha256 from the run's binaries (--binaries-dir) instead. Both ways it downloads every
binary from its URL and refuses one whose bytes differ, and both give the same payload key, so
the later point-machine-channel finds the channel current (web-ota-pointer.py newer) and keeps it.
Runs without network: the download is a local copy.
"""

import contextlib
import hashlib
import importlib.util
import io
import json
import pathlib
import shutil
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("cmux_machine_channel", ROOT / "scripts/ci/cmux-machine-channel.py")
channel = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(channel)

COMMIT = "a" * 40


class Payload(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.built = self.tmp / "built"   # this run's build-linux artifacts
        self.served = self.tmp / "served"  # what files.cmux.com/cmux-tui/<sha>/ serves
        self.built.mkdir()
        self.served.mkdir()
        self.sha = {}
        for target in channel.TARGETS:
            for name in channel.NAMES:
                published = f"{name}-{target}"
                data = f"{published} bytes".encode()
                (self.built / published).write_bytes(data)
                (self.served / published).write_bytes(data)
                self.sha[published] = hashlib.sha256(data).hexdigest()
        # An artifact the channel does not carry (acpmux rides the same artifact).
        (self.built / f"cmux-tui-acpmux-{channel.TARGETS[0]}").write_bytes(b"acpmux")

    def download(self, argv, check):
        url, out = argv[-1], argv[argv.index("-o") + 1]
        self.assertTrue(url.startswith(f"{channel.FILES}/{COMMIT}/"), url)
        shutil.copyfile(self.served / url.split("/")[-1].split("?")[0], out)

    def run_payload(self, source):
        out = self.tmp / f"payload-{len(list(self.tmp.iterdir()))}.json"
        argv = ["cmux-machine-channel.py", "payload", *source, "--commit", COMMIT, "--committed-at", "1700000000",
                "--download-dir", str(self.tmp / "dl"), "--out", str(out)]
        with mock.patch.object(channel.subprocess, "run", side_effect=self.download):
            channel.main(argv)
        return json.loads(out.read_text())

    def test_the_build_and_the_manifest_give_the_same_payload(self):
        manifest = self.tmp / "manifest.json"
        manifest.write_text(json.dumps({"commit": COMMIT, "binaries": self.sha}))
        early = self.run_payload(["--binaries-dir", str(self.built)])
        late = self.run_payload(["--manifest", str(manifest)])
        self.assertEqual(early["key"], late["key"])
        self.assertEqual(early["targets"], late["targets"])
        hook = early["targets"]["x86_64-unknown-linux-musl"]["cmux-tui-hook"]
        self.assertEqual(hook["url"], f"{channel.FILES}/{COMMIT}/cmux-tui-hook-x86_64-unknown-linux-musl")
        self.assertEqual(hook["sha256"], self.sha["cmux-tui-hook-x86_64-unknown-linux-musl"])

    def test_served_bytes_that_differ_from_the_build_are_refused(self):
        (self.served / "cmux-tui-aarch64-unknown-linux-musl").write_bytes(b"another build")
        with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()) as err:
            self.run_payload(["--binaries-dir", str(self.built)])
        self.assertEqual(raised.exception.code, 1)
        self.assertIn("does not have the expected sha256", err.getvalue())

    def test_a_missing_binary_is_refused(self):
        (self.built / "cmux-tui-hook-aarch64-unknown-linux-musl").unlink()
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()) as err:
            self.run_payload(["--binaries-dir", str(self.built)])
        self.assertIn("no sha256 for cmux-tui-hook-aarch64-unknown-linux-musl", err.getvalue())

    def test_one_source_only(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            channel.main(["x", "payload", "--manifest", "m", "--binaries-dir", "b", "--commit", COMMIT,
                          "--committed-at", "1", "--download-dir", "d", "--out", "o"])


if __name__ == "__main__":
    unittest.main()

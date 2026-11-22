#!/usr/bin/env python3
"""cmuxd-remote ships beside its binaries a THIRD_PARTY file with the Go
standard library texts and the license texts of every Go module it links
(scripts/remote_daemon_notices.py). A module or text that nobody reviewed
fails the release build."""

from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import remote_daemon_notices as rdn  # noqa: E402


class RemoteDaemonNoticesTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.review = rdn.load_review()
        self.modules = []
        for module, entry in sorted(self.review["modules"].items()):
            path, version = module.split("@")
            directory = self.tmp / module.replace("/", "_")
            directory.mkdir()
            for name, digest in entry["files"].items():
                text = FIXTURE_TEXTS[digest]
                (directory / name).write_bytes(text)
            self.modules.append(rdn.Module(path, version, directory))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_the_notice_names_go_and_every_linked_module(self) -> None:
        text = rdn.compose(self.modules, "go1.26.8", self.review)
        self.assertIn("Go standard library and runtime (go1.26.8)", text)
        self.assertIn((rdn.TEXTS / "go/LICENSE").read_text(), text)
        for module in ("github.com/creack/pty v1.1.24", "golang.org/x/sys v0.30.0", "nhooyr.io/websocket v1.8.17"):
            self.assertIn(module, text)
        self.assertIn("Anmol Sethi", text)
        self.assertIn("Keith Rarick", text)

    def test_an_unreviewed_module_fails(self) -> None:
        extra = self.tmp / "extra"
        extra.mkdir()
        (extra / "LICENSE").write_text("MIT\n")
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose([*self.modules, rdn.Module("example.com/new", "v1.0.0", extra)], "go1.26.8", self.review)
        self.assertIn("example.com/new@v1.0.0", str(raised.exception))

    def test_a_changed_module_text_fails(self) -> None:
        (self.modules[0].directory / next(iter(self.review["modules"][f"{self.modules[0].path}@{self.modules[0].version}"]["files"]))).write_text("edited\n")
        with self.assertRaises(rdn.NoticeError):
            rdn.compose(self.modules, "go1.26.8", self.review)

    def test_another_go_minor_version_fails(self) -> None:
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose(self.modules, "go1.27.0", self.review)
        self.assertIn("go1.27.0", str(raised.exception))

    def test_compose_is_deterministic(self) -> None:
        self.assertEqual(rdn.compose(self.modules, "go1.26.8", self.review),
                         rdn.compose(list(reversed(self.modules)), "go1.26.8", self.review))


# The reviewed texts, keyed by sha256, from the module cache (go mod download).
FIXTURE_TEXTS: dict[str, bytes] = {}


def _load_fixture_texts() -> None:
    for path in (ROOT / "tests/fixtures/remote-daemon-notices").glob("*"):
        data = path.read_bytes()
        FIXTURE_TEXTS[hashlib.sha256(data).hexdigest()] = data


_load_fixture_texts()

if __name__ == "__main__":
    unittest.main()

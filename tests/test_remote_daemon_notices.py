#!/usr/bin/env python3
"""cmuxd-remote ships beside its binaries a THIRD_PARTY file with the Go
standard library texts and the license texts of every Go module it links
(scripts/remote_daemon_notices.py). A module or text that nobody reviewed
fails the release build."""

from __future__ import annotations

import copy
import dataclasses
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
        for module in ("github.com/creack/pty v1.1.24", "golang.org/x/sys v0.44.0", "nhooyr.io/websocket v1.8.17"):
            self.assertIn(module, text)
        self.assertIn("Anmol Sethi", text)
        self.assertIn("Keith Rarick", text)

    def test_every_module_go_mod_requires_is_reviewed(self) -> None:
        # A module new to daemon/remote/go.mod needs a review entry. A version
        # bump does not (see the next tests): the texts are what is reviewed.
        go_mod = (ROOT / "daemon/remote/go.mod").read_text()
        block = go_mod.split("require (", 1)[1].split(")", 1)[0]
        required = [line.split()[0] for line in block.splitlines() if line.strip() and not line.strip().startswith("//")]
        self.assertTrue(required)
        reviewed = {key.rsplit("@", 1)[0] for key in self.review["modules"]}
        for path in required:
            self.assertIn(path, reviewed)

    def bumped(self, path: str, version: str) -> list:
        return [dataclasses.replace(m, version=version) if m.path == path else m for m in self.modules]

    def test_a_version_bump_with_the_reviewed_texts_is_approved(self) -> None:
        # 1c7138a0583 moved x/sys from v0.30.0 to v0.44.0 with byte-identical
        # LICENSE and PATENTS, and every nightly-next build failed until
        # review.json named the new version by hand.
        modules = self.bumped("golang.org/x/sys", "v0.99.0")
        text = rdn.compose(modules, "go1.26.8", self.review)
        self.assertIn("golang.org/x/sys v0.99.0", text)

    def test_a_version_bump_with_a_new_license_text_fails(self) -> None:
        modules = self.bumped("golang.org/x/sys", "v0.99.0")
        sys_module = next(m for m in modules if m.path == "golang.org/x/sys")
        (sys_module.directory / "LICENSE").write_text("relicensed\n")
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose(modules, "go1.26.8", self.review)
        self.assertIn("golang.org/x/sys@v0.99.0", str(raised.exception))

    def test_the_review_can_be_rewritten_for_the_linked_versions(self) -> None:
        modules = self.bumped("golang.org/x/sys", "v0.99.0")
        updated = rdn.updated_review(modules, self.review)
        self.assertIn("golang.org/x/sys@v0.99.0", updated["modules"])
        self.assertFalse([key for key in updated["modules"] if key.startswith("golang.org/x/sys@") and key != "golang.org/x/sys@v0.99.0"])
        self.assertEqual(updated["modules"]["golang.org/x/sys@v0.99.0"],
                         next(e for k, e in self.review["modules"].items() if k.startswith("golang.org/x/sys@")))
        rdn.compose(modules, "go1.26.8", updated)

    def go_root(self, **texts: bytes) -> Path:
        root = self.tmp / "goroot"
        root.mkdir(exist_ok=True)
        for name in self.review["go"]["files"]:
            (root / name).write_bytes(texts.get(name, (rdn.TEXTS / "go" / name).read_bytes()))
        return root

    def test_a_go_minor_bump_with_the_reviewed_texts_is_approved(self) -> None:
        text = rdn.compose(self.modules, "go1.27.3", self.review, go_root=self.go_root())
        self.assertIn("Go standard library and runtime (go1.27.3)", text)

    def test_a_go_minor_bump_with_a_new_license_text_fails(self) -> None:
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose(self.modules, "go1.27.3", self.review, go_root=self.go_root(LICENSE=b"other\n"))
        self.assertIn("go1.27.3", str(raised.exception))

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

    def test_a_go_minor_bump_with_an_added_license_file_fails(self) -> None:
        root = self.go_root()
        (root / "NOTICE").write_text("an unreviewed notice\n")
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose(self.modules, "go1.27.3", self.review, go_root=root)
        self.assertIn("go1.27.3", str(raised.exception))

    def test_a_failed_review_write_leaves_the_review_whole(self) -> None:
        review = self.tmp / "review.json"
        review.write_text("reviewed\n")
        saved = rdn.os.replace

        def fail(*_args):
            raise OSError("disk full")
        rdn.os.replace = fail
        try:
            with self.assertRaises(OSError):
                rdn.write_atomically(review, "rewritten\n")
        finally:
            rdn.os.replace = saved
        self.assertEqual(review.read_text(), "reviewed\n")
        self.assertEqual(sorted(p.name for p in self.tmp.iterdir() if p.name.startswith("review")), ["review.json"])
        rdn.write_atomically(review, "rewritten\n")
        self.assertEqual(review.read_text(), "rewritten\n")

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

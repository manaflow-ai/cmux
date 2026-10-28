#!/usr/bin/env python3
"""scripts/ci/publish-nightly-next-r2.py: the cmux NEXT feed's R2 critical path.

The enclosure rewrite touches only the names asked for (or, with --if-public, only
what the public base serves at the enclosure's length), and the feed write is a
compare-and-swap that never moves the feed to an older build.
"""
from __future__ import annotations

import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "publish-nightly-next-r2.py"
spec = importlib.util.spec_from_file_location("publish_nightly_next_r2", SCRIPT)
r2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r2)

GH = r2.GITHUB_PREFIX
BASE = "https://files-next.cmux.com/nightly-next/next"
ENV = {
    "NIGHTLY_NEXT_FEED_BASE": BASE,
    "NIGHTLY_NEXT_R2_BUCKET": "cmux-nightly-next",
    "NIGHTLY_NEXT_R2_PREFIX": "nightly-next/next/",
    "R2_ENDPOINT": "https://account.r2.cloudflarestorage.com",
}


def feed(*items: tuple[int, str, int]) -> str:
    body = "".join(
        f'<item><sparkle:version>{build}</sparkle:version><enclosure url="{url}" length="{length}" '
        f'sparkle:edSignature="sig"/></item>' for build, url, length in items)
    return ('<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            f"<channel>{body}</channel></rss>")


class RewriteTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        patcher = mock.patch.dict(os.environ, ENV)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, text: str) -> Path:
        path = Path(self.dir.name) / "appcast-arm64.xml"
        path.write_text(text, encoding="utf-8")
        return path

    def test_only_the_named_dmg_moves_to_r2(self) -> None:
        new, old = "cmux-nightly-next-macos-arm64-200.dmg", "cmux-nightly-next-macos-arm64-100.dmg"
        path = self.write(feed((200, GH + new, 5), (100, GH + old, 4)))
        self.assertEqual(r2.rewrite(path, {new}, False), 0)
        text = path.read_text()
        self.assertIn(f'url="{BASE}/{new}"', text)
        self.assertIn(f'url="{GH}{old}"', text)
        self.assertIn('sparkle:edSignature="sig"', text)

    def test_a_missing_name_fails(self) -> None:
        path = self.write(feed((100, GH + "cmux-nightly-next-macos-arm64-100.dmg", 4)))
        self.assertEqual(r2.rewrite(path, {"cmux-nightly-next-macos-arm64-200.dmg"}, False), 1)

    def test_if_public_moves_only_what_r2_serves_at_its_length(self) -> None:
        served = {f"{BASE}/cmux-nightly-next-macos-arm64-200.dmg": 5,
                  f"{BASE}/cmux-nightly-next-macos-arm64-200-100.delta": 999}
        path = self.write(feed((200, GH + "cmux-nightly-next-macos-arm64-200.dmg", 5),
                               (150, GH + "cmux-nightly-next-macos-arm64-200-100.delta", 3),
                               (100, GH + "cmux-nightly-next-macos-arm64-100.dmg", 4)))
        with mock.patch.object(r2, "public_length", side_effect=lambda url, attempts=5: served.get(url)):
            self.assertEqual(r2.rewrite(path, set(), True), 0)
        text = path.read_text()
        self.assertIn(f'url="{BASE}/cmux-nightly-next-macos-arm64-200.dmg"', text)
        # Wrong length on R2, or not on R2: the release URL stays.
        self.assertIn(f'url="{GH}cmux-nightly-next-macos-arm64-200-100.delta"', text)
        self.assertIn(f'url="{GH}cmux-nightly-next-macos-arm64-100.dmg"', text)

    def test_other_downloads_are_never_rewritten(self) -> None:
        other = "https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos-arm64-1.dmg"
        path = self.write(feed((1, other, 1)))
        self.assertEqual(r2.rewrite(path, set(), True), 0)
        self.assertIn(other, path.read_text())


class WriteFeedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        patcher = mock.patch.dict(os.environ, ENV)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.path = Path(self.dir.name) / "appcast-arm64.xml"
        self.path.write_text(feed((200, f"{BASE}/cmux-nightly-next-macos-arm64-200.dmg", 5)), encoding="utf-8")
        self.output = Path(self.dir.name) / "out"
        self.calls: list[list[str]] = []
        for name in ("guard_key",):
            p = mock.patch.object(r2, name, lambda key: None)
            p.start()
            self.addCleanup(p.stop)

    def run_with(self, lives: list[bytes | None], codes: list[int], same_build: bool = False) -> int:
        lives_iter, codes_iter = iter(lives), iter(codes)

        def fake_run(args, *rest, **kwargs):
            self.calls.append(args)
            return subprocess.CompletedProcess(args, next(codes_iter))

        with mock.patch.object(r2, "read_live", lambda key: next(lives_iter)), \
                mock.patch.object(r2.subprocess, "run", fake_run):
            return r2.write_feed(self.path, str(self.output), same_build)

    def test_a_newer_live_feed_is_left_alone(self) -> None:
        live = feed((300, "x", 1)).encode()
        self.assertEqual(self.run_with([live], []), 0)
        self.assertEqual(self.calls, [])
        self.assertIn("feed_written=false", self.output.read_text())

    def test_the_same_build_is_not_rewritten_by_the_first_publication(self) -> None:
        live = feed((200, "x", 1)).encode()
        self.assertEqual(self.run_with([live], []), 0)
        self.assertEqual(self.calls, [])

    def test_an_older_live_feed_is_replaced_only_while_it_has_the_bytes_read(self) -> None:
        live = feed((100, "x", 1)).encode()
        self.assertEqual(self.run_with([live], [0]), 0)
        args = self.calls[0]
        self.assertIn("--replace-sha256", args)
        self.assertEqual(args[args.index("--replace-sha256") + 1], hashlib.sha256(live).hexdigest())
        self.assertEqual(args[args.index("--key") + 1], "nightly-next/next/appcast-arm64.xml")
        self.assertIn("feed_written=true", self.output.read_text())

    def test_a_lost_race_reads_again_and_yields_to_a_newer_build(self) -> None:
        older, newer = feed((100, "x", 1)).encode(), feed((300, "x", 1)).encode()
        self.assertEqual(self.run_with([older, newer], [r2.CONFLICT]), 0)
        self.assertEqual(len(self.calls), 1)
        self.assertIn("feed_written=false", self.output.read_text())

    def test_no_live_feed_is_written_once(self) -> None:
        self.assertEqual(self.run_with([None], [0]), 0)
        self.assertIn("--write-once", self.calls[0])

    def test_an_upload_failure_fails(self) -> None:
        self.assertEqual(self.run_with([feed((100, "x", 1)).encode()], [1]), 1)

    def test_the_delta_revision_needs_the_live_feed_on_this_build(self) -> None:
        self.assertEqual(self.run_with([feed((300, "x", 1)).encode()], [], same_build=True), 0)
        self.assertEqual(self.run_with([feed((100, "x", 1)).encode()], [], same_build=True), 0)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.run_with([feed((200, "x", 1)).encode()], [0], same_build=True), 0)
        self.assertIn("--replace-sha256", self.calls[0])


class UploadTests(unittest.TestCase):
    def test_every_file_goes_up_at_once_and_each_failure_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, ENV):
            files = [Path(tmp) / f"cmux-nightly-next-macos-arm64-{n}.delta" for n in range(3)]
            for f in files:
                f.write_bytes(b"x")
            seen = []

            def fake_one(path: Path) -> str:
                seen.append(path.name)
                if path.name.endswith("1.delta"):
                    raise RuntimeError("boom")
                return path.name

            with mock.patch.object(r2, "upload_one", fake_one):
                self.assertEqual(r2.upload(files), 1)
            self.assertEqual(sorted(seen), sorted(f.name for f in files))


if __name__ == "__main__":
    unittest.main(verbosity=2)

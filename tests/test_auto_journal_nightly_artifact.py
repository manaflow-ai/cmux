#!/usr/bin/env python3
"""Provenance regressions: an app source cannot stand in for its daemon source."""
from __future__ import annotations

import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cmux-next/auto-journal-nightly-artifact.py"
spec = importlib.util.spec_from_file_location("journal_artifact", SCRIPT)
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)

BUILD = "4592220755201"


class FeedTests(unittest.TestCase):
    def feed(self, url=None, signature="signed"):
        url = url or f"https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-{BUILD}.dmg"
        return (f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                f'<channel><item><sparkle:version>{BUILD}</sparkle:version>'
                f'<enclosure url="{url}" length="123" sparkle:edSignature="{signature}"/>'
                '</item></channel></rss>').encode()

    def test_explicit_build_must_be_published_and_signed(self):
        self.assertEqual(artifact.pick_build(self.feed(), BUILD)["length"], "123")
        for xml, build in [(self.feed(), "4592220755202"), (self.feed(signature=""), BUILD),
                           (self.feed("https://example.com/nightly.dmg"), BUILD)]:
            with self.subTest(build=build, xml=xml), self.assertRaises(ValueError):
                artifact.pick_build(xml, build)


class AppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.old = self.commit("before journal support")
        self.required = self.commit("journal support")
        self.source = self.commit("app update")
        self.app = self.root / "cmux NIGHTLY.app"
        self.binary = self.app / "Contents/Resources/bin/cmux-tui"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b"signed daemon fixture")
        self.binary.chmod(0o755)
        self.version = self.binary.parent / "cmux-tui.version"
        self.version.write_text(f"commit={self.required}\n")
        self.plist = self.app / "Contents/Info.plist"
        with self.plist.open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "com.cmuxterm.app.nightly",
                          "CFBundleVersion": BUILD, "CMUXCommit": self.source[:7]}, handle)

    def git(self, *args):
        env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_AUTHOR_NAME="test", GIT_AUTHOR_EMAIL="test@example.invalid",
                   GIT_COMMITTER_NAME="test", GIT_COMMITTER_EMAIL="test@example.invalid")
        return subprocess.check_output(["git", "-C", str(self.repo),
                                        "-c", "core.hooksPath=/dev/null", *args],
                                       env=env, text=True, stderr=subprocess.DEVNULL).strip()

    def commit(self, message):
        self.git("commit", "--allow-empty", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def receipt(self):
        return artifact.app_receipt(self.app, BUILD, self.source, self.repo, self.required)

    def test_records_distinct_sources_and_actual_binary_hash(self):
        receipt = self.receipt()
        self.assertEqual(receipt["source_sha"], self.source)
        self.assertEqual(receipt["daemon_source_sha"], self.required)
        self.assertEqual(receipt["binary_sha256"], hashlib.sha256(self.binary.read_bytes()).hexdigest())
        self.binary.write_bytes(b"different binary")
        self.assertNotEqual(self.receipt()["binary_sha256"], receipt["binary_sha256"])

    def test_new_app_cannot_hide_daemon_missing_product_change(self):
        self.version.write_text(f"commit={self.old}\n")
        with self.assertRaises(subprocess.CalledProcessError):
            self.receipt()

    def test_wrong_app_build_is_rejected(self):
        with self.assertRaises(ValueError):
            artifact.app_receipt(self.app, "4592220755202", self.source, self.repo, self.required)

    def test_daemon_alias_cannot_escape_verified_app(self):
        outside = self.root / "foreign-daemon"
        self.binary.rename(outside)
        self.binary.symlink_to(outside)
        with self.assertRaises(ValueError):
            self.receipt()

    def test_app_receipt_does_not_itself_claim_signature_or_recovery_pass(self):
        receipt = self.receipt()
        self.assertNotIn("published", receipt)
        self.assertNotIn("status", receipt)


if __name__ == "__main__":
    unittest.main()

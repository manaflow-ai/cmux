#!/usr/bin/env python3
"""scripts/ci/quit_gamut_check.py's sparkle-update path: the pair feed and the shared Sparkle folder.

pair_feed: quit-gamut.sh pair=FROM,TO offers two nightlies the live feed may have dropped (a before/after of a fix
older than the feed's two builds), each signed by its published <dmg>.signature.json.

SparkleUpdate.prepare: the gamut boots the newer build in the private home before the first update round, and its
Sparkle makes the private Sparkle folder for real; prepare must still point it at the account's, where the installer
stages, or the pre-warm scans an empty folder ("no staged bundle", the first fleet runs of 2026-11-17).
"""
from __future__ import annotations

import os
import plistlib
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import nightly_next_launch_smoke as smoke_feed  # noqa: E402
import quit_gamut_check as gamut  # noqa: E402

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
LIVE = """<?xml version="1.0" encoding="utf-8"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0" xmlns:cmux="https://cmux.com/xml-namespaces/cmux">
    <channel>
        <title>cmux NIGHTLY</title>
        <item>
            <sparkle:channel>cmux-next</sparkle:channel>
            <title>1.0.0-nightly.4406374033401</title>
            <pubDate>Tue, 17 Nov 2026 02:35:52 -0800</pubDate>
            <sparkle:fullReleaseNotesLink>https://example.invalid/notes</sparkle:fullReleaseNotesLink>
            <sparkle:version>4406374033401</sparkle:version>
            <sparkle:shortVersionString>1.0.0-nightly.4406374033401</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-4406374033401.dmg" length="242481475" type="application/octet-stream" sparkle:edSignature="TEMPLATESIG=="/>
            <sparkle:deltas>
                <enclosure url="https://files-next.cmux.com/nightly-next/x.delta" sparkle:deltaFrom="4405686045401" length="9" type="application/octet-stream" sparkle:edSignature="DELTASIG=="/>
            </sparkle:deltas>
        <description>Changed: something</description>            <cmux:sourceCommit xmlns:cmux="https://cmux.com/xml-namespaces/cmux">8005881ef144162831fecf0ac32faa0511c977b9</cmux:sourceCommit>
        </item>
        <item>
            <sparkle:channel>cmux-next</sparkle:channel>
            <title>1.0.0-nightly.4405686045401</title>
            <sparkle:version>4405686045401</sparkle:version>
            <enclosure url="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-4405686045401.dmg" length="242888156" type="application/octet-stream" sparkle:edSignature="OLDSIG=="/>
        </item>
    </channel>
</rss>"""
SIGNED = {"4397060643101": {"edSignature": "FROMSIG==", "length": 242000001},
          "4399814061301": {"edSignature": "TOSIG==", "length": 242466475}}


class PairFeedTests(unittest.TestCase):
    def test_offers_exactly_the_pair_newest_first_with_their_own_signatures(self):
        feed = gamut.pair_feed(LIVE, SIGNED)
        items = ET.fromstring(feed.encode()).find("channel").findall("item")
        self.assertEqual([i.findtext(f"{{{SPARKLE}}}version") for i in items], ["4399814061301", "4397060643101"])
        for item, build in zip(items, ["4399814061301", "4397060643101"]):
            enclosure = item.find("enclosure")
            self.assertEqual(enclosure.get("url"), gamut.NIGHTLY_DMG.format(build=build))
            self.assertEqual(enclosure.get(f"{{{SPARKLE}}}edSignature"), SIGNED[build]["edSignature"])
            self.assertEqual(enclosure.get("length"), str(SIGNED[build]["length"]))
            self.assertEqual(item.findtext(f"{{{SPARKLE}}}shortVersionString"), f"1.0.0-nightly.{build}")
            self.assertEqual(item.findtext(f"{{{SPARKLE}}}channel"), "cmux-next")
            # The template build's deltas and source commit name another build: never copied.
            self.assertIsNone(item.find(f"{{{SPARKLE}}}deltas"))
            self.assertNotIn("sourceCommit", ET.tostring(item, encoding="unicode"))
        self.assertNotIn("4406374033401", feed)
        self.assertNotIn("TEMPLATESIG", feed)

    def test_the_launch_smoke_pick_reads_it_as_quit_gamut_sh_does(self):
        build, url, length, signature = smoke_feed.pick(gamut.pair_feed(LIVE, SIGNED))
        self.assertEqual((build, length, signature), (4399814061301, "242466475", "TOSIG=="))
        self.assertTrue(url.endswith("-4399814061301.dmg"))

    def test_refuses_a_build_without_a_signature(self):
        with self.assertRaises(ValueError):
            gamut.pair_feed(LIVE, {"4397060643101": {"edSignature": "", "length": 1}})
        with self.assertRaises(ValueError):
            gamut.pair_feed("<rss><channel></channel></rss>", SIGNED)

    def test_pair_feed_command_writes_the_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            live, out = Path(tmp) / "feed.xml", Path(tmp) / "pair.xml"
            live.write_text(LIVE)
            args = ["pair-feed", "--live", str(live), "--out", str(out)]
            for build, sig in SIGNED.items():
                (Path(tmp) / f"{build}.json").write_text(gamut.json.dumps(sig))
                args += ["--signature", f"{build}={Path(tmp) / f'{build}.json'}"]
            self.assertEqual(gamut.main(args), 0)
            self.assertEqual(smoke_feed.pick(out.read_text())[0], 4399814061301)


class SharedSparkleFolderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.account, self.home = base / "account", base / "private"
        self.account.mkdir()
        self.home.mkdir()
        self.bundle = base / "cmux NIGHTLY.app"
        (self.bundle / "Contents").mkdir(parents=True)
        with open(self.bundle / "Contents" / "Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "com.cmuxterm.app.nightly", "CFBundleExecutable": "cmux",
                           "CFBundleVersion": "4397060643101"}, handle)
        self.rel = Path("Library/Caches/com.cmuxterm.app.nightly/org.sparkle-project.Sparkle")

    def tearDown(self):
        self.tmp.cleanup()

    def prepare(self) -> None:
        with mock.patch.dict(os.environ, {"HOME": str(self.account)}):
            gamut.SparkleUpdate(self.home, self.bundle).prepare()

    def test_a_folder_the_first_launch_made_is_replaced_by_the_link(self):
        # What the newer build's boot leaves: a real private folder, with Sparkle's own subfolders.
        (self.home / self.rel / "Installation").mkdir(parents=True)
        self.prepare()
        private = self.home / self.rel
        self.assertTrue(private.is_symlink(), "the pre-warm would scan the private folder, not the installer's")
        self.assertEqual(private.resolve(), (self.account / self.rel).resolve())

    def test_no_folder_yet_and_a_second_prepare_keep_one_link(self):
        self.prepare()
        self.prepare()
        self.assertTrue((self.home / self.rel).is_symlink())
        self.assertEqual((self.home / self.rel).resolve(), (self.account / self.rel).resolve())


if __name__ == "__main__":
    unittest.main()

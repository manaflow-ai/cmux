#!/usr/bin/env python3
"""The stable legacy feed moves each existing install onto the right build.

Models Sparkle's item selection (Sparkle 2.9.5 SUAppcastDriver.m:481-535 and
SPUAppcastItemStateResolver.m:42-51,127-160; 2.8.1 parses neither
minimumUpdateVersion nor hardwareRequirements) over the composed feed.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/compose_stable_appcast.py"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

spec = importlib.util.spec_from_file_location("compose_stable_appcast", SCRIPT)
compose_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compose_module)


def appcast(dmg: str, version: str = "109", signature: str = "c2ln") -> str:
    # The shape scripts/sparkle_generate_appcast.sh emits (dry run 38110472793).
    return f"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>cmux</title>
        <item>
            <title>0.66.0</title>
            <sparkle:version>{version}</sparkle:version>
            <sparkle:shortVersionString>0.66.0</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="https://github.com/manaflow-ai/cmux/releases/download/v0.66.0/{dmg}" length="1" type="application/octet-stream" sparkle:edSignature="{signature}"/>
        </item>
    </channel>
</rss>"""


def sparkle_pick(feed_xml: str, *, sparkle_29: bool, native_intel: bool, host_version: str = "108") -> str:
    """Returns the DMG name Sparkle installs, or "" when it offers nothing."""
    candidates = []
    for item in ET.fromstring(feed_xml).iter("item"):
        if sparkle_29:
            minimum = item.findtext(f"{SPARKLE}minimumUpdateVersion")
            if minimum and int(minimum) > int(host_version):
                continue
            requirements = (item.findtext(f"{SPARKLE}hardwareRequirements") or "").split()
            if "arm64" in requirements and native_intel:
                continue
        candidates.append(item)
    best = None
    for item in candidates:
        # Equal versions keep the first item (SUAppcastDriver.m:529).
        if best is None or int(item.findtext(f"{SPARKLE}version")) > int(best.findtext(f"{SPARKLE}version")):
            best = item
    if best is None or int(best.findtext(f"{SPARKLE}version")) <= int(host_version):
        return ""
    return best.find("enclosure").get("url").rsplit("/", 1)[1]


class ComposeStableAppcastTest(unittest.TestCase):
    def compose(self):
        return compose_module.compose(
            appcast("cmux-macos.dmg"), appcast("cmux-macos-arm64.dmg"), appcast("cmux-macos-x86_64.dmg")
        )

    def test_existing_installs_land_on_their_architecture_in_one_update(self):
        legacy, _ = self.compose()
        # v0.64.2x and v0.65.x bundle Sparkle 2.9.3/2.9.5.
        self.assertEqual(sparkle_pick(legacy, sparkle_29=True, native_intel=False), "cmux-macos-arm64.dmg")
        self.assertEqual(sparkle_pick(legacy, sparkle_29=True, native_intel=True), "cmux-macos-x86_64.dmg")

    def test_sparkle_281_installs_stay_universal(self):
        legacy, _ = self.compose()
        # 2.8.1 cannot tell the architecture, so it must never be handed a thin build.
        self.assertEqual(sparkle_pick(legacy, sparkle_29=False, native_intel=True), "cmux-macos.dmg")
        self.assertEqual(sparkle_pick(legacy, sparkle_29=False, native_intel=False), "cmux-macos.dmg")

    def test_thin_installs_never_switch_architecture_on_their_own_feeds(self):
        _, arm64_feed = self.compose()
        self.assertEqual(sparkle_pick(arm64_feed, sparkle_29=True, native_intel=False), "cmux-macos-arm64.dmg")
        self.assertEqual(sparkle_pick(arm64_feed, sparkle_29=True, native_intel=True), "")
        x86_64_feed = appcast("cmux-macos-x86_64.dmg")
        self.assertEqual(sparkle_pick(x86_64_feed, sparkle_29=True, native_intel=True), "cmux-macos-x86_64.dmg")

    def test_legacy_feed_keeps_every_signature_and_item_order(self):
        legacy, _ = self.compose()
        items = list(ET.fromstring(legacy).iter("item"))
        self.assertEqual(
            [item.find("enclosure").get("url").rsplit("/", 1)[1] for item in items],
            ["cmux-macos.dmg", "cmux-macos-arm64.dmg", "cmux-macos-x86_64.dmg"],
        )
        for item in items:
            self.assertTrue(item.find("enclosure").get(f"{SPARKLE}edSignature"))

    def test_rejects_mismatched_versions_and_missing_signatures(self):
        with self.assertRaisesRegex(compose_module.AppcastError, "one sparkle:version"):
            compose_module.compose(
                appcast("cmux-macos.dmg"), appcast("cmux-macos-arm64.dmg", version="110"), appcast("cmux-macos-x86_64.dmg")
            )
        unsigned = appcast("cmux-macos-arm64.dmg").replace(' sparkle:edSignature="c2ln"', "")
        with self.assertRaisesRegex(compose_module.AppcastError, "edSignature"):
            compose_module.compose(appcast("cmux-macos.dmg"), unsigned, appcast("cmux-macos-x86_64.dmg"))
        with self.assertRaisesRegex(compose_module.AppcastError, "must enclose cmux-macos-x86_64.dmg"):
            compose_module.compose(appcast("cmux-macos.dmg"), appcast("cmux-macos-arm64.dmg"), appcast("cmux-macos.dmg"))

    def test_cli_writes_legacy_and_arm64_feeds(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            for name, dmg in (("u.xml", "cmux-macos.dmg"), ("a.xml", "cmux-macos-arm64.dmg"), ("x.xml", "cmux-macos-x86_64.dmg")):
                (path / name).write_text(appcast(dmg), encoding="utf-8")
            subprocess.run(
                [sys.executable, str(SCRIPT), "--universal", str(path / "u.xml"), "--arm64", str(path / "a.xml"),
                 "--x86_64", str(path / "x.xml"), "--out", str(path / "appcast.xml")],
                check=True,
            )
            self.assertEqual(len(list(ET.fromstring((path / "appcast.xml").read_text()).iter("item"))), 3)
            self.assertIn("<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>", (path / "a.xml").read_text())


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""appcast-phased-rollout.py phases only this release's item, and refuses what Sparkle would ignore."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/appcast-phased-rollout.py"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"

APPCAST = f"""<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="{SPARKLE}" version="2.0"><channel><title>cmux</title>
<item><title>1.0.0</title><pubDate>Mon, 23 Nov 2026 18:00:00 +0000</pubDate><sparkle:version>117</sparkle:version>
<enclosure url="https://github.com/manaflow-ai/cmux/releases/download/v1.0.0/cmux-macos.dmg" length="1" type="application/octet-stream" sparkle:edSignature="sig" /></item>
<item><title>0.65.2</title><pubDate>Tue, 27 Oct 2026 13:32:47 +0000</pubDate><sparkle:version>113</sparkle:version>
<enclosure url="https://github.com/manaflow-ai/cmux/releases/download/v0.65.2.2/cmux-macos-legacy.dmg" length="1" type="application/octet-stream" sparkle:edSignature="old" /></item>
</channel></rss>
"""


def intervals(path):
    return {i.findtext(f"{{{SPARKLE}}}version"): i.findtext(f"{{{SPARKLE}}}phasedRolloutInterval")
            for i in ET.parse(path).getroot().iter("item")}


class PhasedRolloutTest(unittest.TestCase):
    def run_script(self, path, *args):
        return subprocess.run([sys.executable, str(SCRIPT), str(path), *args], capture_output=True, text=True)

    def appcast(self, tmp, text=APPCAST):
        path = Path(tmp) / "appcast.xml"
        path.write_text(text)
        return path

    def test_only_this_releases_item_is_phased(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.appcast(tmp)
            result = self.run_script(path, "cmux-macos.dmg", "86400")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(intervals(path), {"117": "86400", "113": None})
            self.assertIn('sparkle:edSignature="sig"', path.read_text())

    def test_running_twice_changes_nothing_and_a_new_interval_replaces_the_old(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.appcast(tmp)
            self.run_script(path, "cmux-macos.dmg", "86400")
            once = path.read_bytes()
            self.assertEqual(self.run_script(path, "cmux-macos.dmg", "86400").returncode, 0)
            self.assertEqual(path.read_bytes(), once)
            self.assertEqual(self.run_script(path, "cmux-macos.dmg", "43200").returncode, 0)
            self.assertEqual(intervals(path)["117"], "43200")
            self.assertEqual(path.read_text().count("phasedRolloutInterval>"), 2)

    def test_refuses_what_sparkle_would_ignore_or_misread(self):
        with tempfile.TemporaryDirectory() as tmp:
            no_date = self.appcast(tmp, APPCAST.replace("<pubDate>Mon, 23 Nov 2026 18:00:00 +0000</pubDate>", ""))
            self.assertNotEqual(self.run_script(no_date, "cmux-macos.dmg", "86400").returncode, 0)
        for seconds in ("0", "-1", "1.5", "", "abc", "999999999"):
            with tempfile.TemporaryDirectory() as tmp:
                path = self.appcast(tmp)
                self.assertNotEqual(self.run_script(path, "cmux-macos.dmg", seconds).returncode, 0, seconds)
                self.assertEqual(path.read_text(), APPCAST)
        with tempfile.TemporaryDirectory() as tmp:
            path = self.appcast(tmp)
            self.assertNotEqual(self.run_script(path, "other.dmg", "86400").returncode, 0)
            self.assertNotEqual(self.run_script(path, "v1.0.0/cmux-macos.dmg", "86400").returncode, 0)


if __name__ == "__main__":
    unittest.main()

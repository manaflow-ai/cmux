#!/usr/bin/env python3
"""appcast-require-arm64.py offers the cmux-next DMG item to Apple silicon only.

Runs the script on an appcast shaped like release.yml's (this run's item plus a pinned legacy
item) and reads the result back as Sparkle does.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/appcast-require-arm64.py"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"

APPCAST = f"""<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="{SPARKLE}" version="2.0"><channel><title>cmux</title>
<item><title>1.0.0</title><sparkle:version>114</sparkle:version>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url="https://github.com/manaflow-ai/cmux/releases/download/v1.0.0/cmux-macos.dmg" length="1" type="application/octet-stream" sparkle:edSignature="sig" /></item>
<item><title>0.65.2</title><sparkle:version>113</sparkle:version>
<enclosure url="https://github.com/manaflow-ai/cmux/releases/download/v0.65.2.2/cmux-macos-legacy.dmg" length="1" type="application/octet-stream" sparkle:edSignature="old" /></item>
</channel></rss>
"""


def requirements(path):
    out = {}
    for item in ET.parse(path).getroot().iter("item"):
        element = item.find(f"{{{SPARKLE}}}hardwareRequirements")
        out[item.findtext(f"{{{SPARKLE}}}version")] = None if element is None else element.text
    return out


class AppcastRequireArm64Test(unittest.TestCase):
    def run_script(self, path):
        return subprocess.run([sys.executable, str(SCRIPT), str(path)], capture_output=True, text=True)

    def test_only_this_runs_item_requires_arm64(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "appcast.xml"
            path.write_text(APPCAST)
            result = self.run_script(path)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(requirements(path), {"114": "arm64", "113": None})
            # The EdDSA signature is untouched, so Sparkle still accepts the item.
            text = path.read_text()
            self.assertIn('sparkle:edSignature="sig"', text)

    def test_running_twice_changes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "appcast.xml"
            path.write_text(APPCAST)
            self.run_script(path)
            once = path.read_bytes()
            self.assertEqual(self.run_script(path).returncode, 0)
            self.assertEqual(path.read_bytes(), once)

    def test_refuses_an_appcast_without_this_runs_item(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "appcast.xml"
            path.write_text(APPCAST.replace("/cmux-macos.dmg", "/other.dmg"))
            self.assertNotEqual(self.run_script(path).returncode, 0)

    def test_an_rc_item_named_by_its_dmg_requires_arm64(self):
        # nightly.yml's cmux-next RC names its immutable DMG; older RC items keep their requirements.
        rc = APPCAST.replace("/v1.0.0/cmux-macos.dmg", "/rc/cmux-rc-macos-arm64-4500000000001.dmg")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "appcast-x86_64.xml"
            path.write_text(rc)
            result = subprocess.run([sys.executable, str(SCRIPT), str(path), "cmux-rc-macos-arm64-4500000000001.dmg"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(requirements(path), {"114": "arm64", "113": None})
            # Without the name, the default cmux-macos.dmg item is missing and the script refuses.
            self.assertNotEqual(self.run_script(path).returncode, 0)

    def test_refuses_a_path_as_the_dmg_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "appcast.xml"
            path.write_text(APPCAST)
            result = subprocess.run([sys.executable, str(SCRIPT), str(path), "v1.0.0/cmux-macos.dmg"],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""nightly-next is arm64-only: every item in its feeds names arm64 as a hardware requirement.

Sparkle offers an item carrying <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
only to Apple silicon, so an Intel Mac on macOS 26 that reads a nightly-next feed stays on its
last build instead of being offered an arm64 one.
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "scripts/ci/appcast_hardware_requirements.py"
FEED = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><title>New</title><sparkle:version>102</sparkle:version></item>
<item><title>Old</title><sparkle:hardwareRequirements>x86_64</sparkle:hardwareRequirements><sparkle:version>101</sparkle:version></item>
</channel></rss>
"""


class HardwareRequirements(unittest.TestCase):
    def run_tool(self, *args):
        return subprocess.run([sys.executable, str(TOOL), *args], capture_output=True, text=True)

    def test_every_item_requires_arm64_exactly_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            feed = Path(temporary) / "appcast.xml"
            feed.write_text(FEED)
            result = self.run_tool(str(feed), "arm64")
            self.assertEqual(result.returncode, 0, result.stderr)
            xml = feed.read_text()
            self.assertEqual(xml.count("<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>"), 2)
            self.assertNotIn("x86_64", xml)
            # Idempotent: a second pass (the delta republish) changes nothing.
            self.assertEqual(self.run_tool(str(feed), "arm64").returncode, 0)
            self.assertEqual(feed.read_text(), xml)

    def test_an_unknown_requirement_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            feed = Path(temporary) / "appcast.xml"
            feed.write_text(FEED)
            self.assertNotEqual(self.run_tool(str(feed), "arm64; rm").returncode, 0)
            self.assertEqual(feed.read_text(), FEED)

    def test_the_generator_applies_the_requirement_when_asked(self):
        script = (ROOT / "scripts/sparkle_generate_appcast.sh").read_text()
        self.assertIn('if [[ -n "${SPARKLE_HARDWARE_REQUIREMENTS:-}" ]]; then', script)
        self.assertIn("appcast_hardware_requirements.py", script)


if __name__ == "__main__":
    unittest.main()

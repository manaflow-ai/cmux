#!/usr/bin/env python3
"""Keep cmux-next onboarding's Bonjour probe aligned with the direct carrier."""

from __future__ import annotations

import plistlib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLIST = ROOT / "ios" / "Config" / "Info.plist"
PROBE = ROOT / "ios" / "CmuxiOS" / "Sources" / "CmuxiOSOnboarding" / "Model" / "LocalNetworkProbe.swift"


class CmuxNextIOSBonjourTests(unittest.TestCase):
    def test_probe_and_plist_advertise_only_direct_service(self) -> None:
        info = plistlib.loads(PLIST.read_bytes())
        self.assertEqual(info["NSBonjourServices"], ["_cmux._tcp"])
        source = PROBE.read_text(encoding="utf-8")
        self.assertIn('static let serviceType = "_cmux._tcp"', source)
        self.assertNotIn("_cmux-iroh._udp", source)


if __name__ == "__main__":
    unittest.main()

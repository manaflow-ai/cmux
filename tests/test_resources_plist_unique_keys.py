#!/usr/bin/env python3
"""Guard: no <dict> in a property list under Resources/ repeats a key.

Resources/Info.plist once carried two copies of about 25 top-level keys
(CFBundleVersion, every Sparkle SU* key, NSAppTransportSecurity, several usage
descriptions). CoreFoundation and plistlib both keep the last copy and drop
the rest without a warning, so editing the first copy of a key did nothing.
Two usage descriptions had already drifted apart that way. This test fails on
any repeated key in any dict, at any depth.

Usage:
    python3 tests/test_resources_plist_unique_keys.py
"""

from __future__ import annotations

import pathlib
import unittest
import xml.etree.ElementTree as ET

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
RESOURCES = REPO_ROOT / "Resources"


def duplicate_keys(xml_text: str) -> list[str]:
    """Return "path: key" for every key repeated within one <dict>."""
    root = ET.fromstring(xml_text)
    found: list[str] = []

    def walk(node: ET.Element, path: str) -> None:
        if node.tag == "dict":
            seen: set[str] = set()
            key = None
            for child in node:
                if child.tag == "key":
                    key = child.text or ""
                    if key in seen:
                        found.append(f"{path or '/'}: {key}")
                    seen.add(key)
                else:
                    walk(child, f"{path}/{key}")
        elif node.tag == "array":
            for index, child in enumerate(node):
                walk(child, f"{path}/{index}")
        else:
            for child in node:
                walk(child, path)

    walk(root, "")
    return found


def resource_plists() -> list[pathlib.Path]:
    return sorted(path for path in RESOURCES.rglob("*.plist") if path.is_file())


class ResourcesPlistUniqueKeysTests(unittest.TestCase):
    def test_detector_reports_repeated_keys(self) -> None:
        sample = """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>A</key><string>1</string>
  <key>B</key><dict><key>C</key><true/><key>C</key><false/></dict>
  <key>D</key><array><dict><key>E</key><string/></dict><dict><key>E</key><string/></dict></array>
  <key>A</key><string>2</string>
</dict></plist>"""
        self.assertEqual(duplicate_keys(sample), ["/B: C", "/: A"])

    def test_resource_plists_have_unique_keys(self) -> None:
        plists = resource_plists()
        self.assertTrue(plists, f"no .plist files found under {RESOURCES}")
        for path in plists:
            with self.subTest(plist=str(path.relative_to(REPO_ROOT))):
                self.assertEqual(
                    duplicate_keys(path.read_text(encoding="utf-8")),
                    [],
                    "a repeated key keeps only its last copy; delete the others",
                )


if __name__ == "__main__":
    unittest.main()

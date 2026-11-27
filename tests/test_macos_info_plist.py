#!/usr/bin/env python3
"""Regression checks for the macOS app's LaunchServices metadata."""

import pathlib
import plistlib
import unittest
import xml.etree.ElementTree as ET


ROOT = pathlib.Path(__file__).resolve().parents[1]
INFO_PLIST = ROOT / "Resources" / "Info.plist"


class InfoPlistTests(unittest.TestCase):
    def test_info_plist_has_one_exported_type_declarations_key(self) -> None:
        root = ET.parse(INFO_PLIST).getroot()
        dictionary = root.find("dict")
        self.assertIsNotNone(dictionary)
        keys = [element.text for element in dictionary if element.tag == "key"]
        self.assertEqual(keys.count("UTExportedTypeDeclarations"), 1)

    def test_info_plist_is_valid_and_keeps_drag_types(self) -> None:
        with INFO_PLIST.open("rb") as stream:
            info = plistlib.load(stream)
        identifiers = {
            declaration["UTTypeIdentifier"]
            for declaration in info["UTExportedTypeDeclarations"]
        }
        self.assertIn("com.cmux.cloud-sidebar-row", identifiers)
        self.assertIn("com.splittabbar.tabtransfer", identifiers)
        self.assertIn("com.cmux.sidebar-tab-reorder", identifiers)


if __name__ == "__main__":
    unittest.main()

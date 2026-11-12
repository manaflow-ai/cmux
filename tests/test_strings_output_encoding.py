#!/usr/bin/env python3
"""Compiled .strings ship as binary property lists.

Xcode compiles each String Catalog to UTF-8 .strings and then re-encodes them
with STRINGS_FILE_OUTPUT_ENCODING, which defaults to UTF-16. For cmux's own
catalogs that is 19.98 MiB in the app; binary property lists hold the same
keys in 11.20 MiB, and Foundation loads them the same way.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = (ROOT / "cmux.xcodeproj/project.pbxproj").read_text(encoding="utf-8")


def configuration_list(owner: str) -> list[str]:
    """Build configuration IDs of the list named `Build configuration list for <owner>`."""
    match = re.search(
        rf"^\t\t[0-9A-F]+ /\* Build configuration list for {re.escape(owner)} \*/ = \{{(.*?)^\t\t\}};",
        PROJECT,
        flags=re.M | re.S,
    )
    if not match:
        raise AssertionError(f"no build configuration list for {owner}")
    return re.findall(r"([0-9A-F]+) /\* \w+ \*/", match.group(1))


def build_settings(configuration: str) -> str:
    match = re.search(
        rf"^\t\t{configuration} /\* \w+ \*/ = \{{.*?buildSettings = \{{(.*?)^\t\t\t\}};",
        PROJECT,
        flags=re.M | re.S,
    )
    if not match:
        raise AssertionError(f"no build settings for {configuration}")
    return match.group(1)


class StringsOutputEncodingTest(unittest.TestCase):
    def test_project_compiles_strings_to_binary_property_lists(self):
        configurations = configuration_list('PBXProject "cmux"')
        self.assertEqual(len(configurations), 2)
        for configuration in configurations:
            self.assertRegex(
                build_settings(configuration),
                r"\n\t\t\t\tSTRINGS_FILE_OUTPUT_ENCODING = binary;\n",
                configuration,
            )

    def test_no_target_overrides_the_encoding(self):
        overrides = re.findall(r"STRINGS_FILE_OUTPUT_ENCODING = ([^;]+);", PROJECT)
        self.assertEqual(set(overrides), {"binary"})


if __name__ == "__main__":
    unittest.main()

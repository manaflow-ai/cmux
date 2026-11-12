#!/usr/bin/env python3
"""Guard: every entry in Resources/Localizable.xcstrings must live inside "strings".

The catalog is edited by hand (compact one-line entries appended near the end
of the file). Once, the "strings" object was closed before those appends, so
about 140 entries became *top-level* keys: still valid JSON, but the string
catalog compiler only reads "strings", so every one of those keys silently
fell back to its English defaultValue in every locale. This test fails on that
shape, on duplicate keys, and on entries without a localizations table.

Usage:
    python3 tests/test_localizable_xcstrings_structure.py
"""

from __future__ import annotations

import collections
import json
import pathlib
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
CATALOG = REPO_ROOT / "Resources" / "Localizable.xcstrings"
EXPECTED_TOP_LEVEL_KEYS = ["sourceLanguage", "strings", "version"]


def load_catalog(path: pathlib.Path) -> tuple[dict, list[str]]:
    duplicates: list[str] = []

    def pairs_hook(pairs: list[tuple[str, object]]) -> dict[str, object]:
        counts = collections.Counter(key for key, _ in pairs)
        duplicates.extend(key for key, count in counts.items() if count > 1)
        return dict(pairs)

    with path.open(encoding="utf-8") as handle:
        return json.load(handle, object_pairs_hook=pairs_hook), duplicates


class LocalizableXCStringsStructureTests(unittest.TestCase):
    def test_every_entry_lives_inside_strings(self) -> None:
        catalog, _ = load_catalog(CATALOG)
        stray = sorted(set(catalog) - set(EXPECTED_TOP_LEVEL_KEYS))
        self.assertEqual(
            stray,
            [],
            "string entries outside \"strings\" are ignored by the catalog compiler; "
            f"move them inside: {stray[:10]}",
        )
        self.assertEqual(sorted(catalog), EXPECTED_TOP_LEVEL_KEYS)
        self.assertEqual(catalog["sourceLanguage"], "en")

    def test_keys_are_unique(self) -> None:
        _, duplicates = load_catalog(CATALOG)
        self.assertEqual(duplicates, [], "duplicate keys resolve to whichever entry parses last")

    def test_entries_carry_localizations(self) -> None:
        catalog, _ = load_catalog(CATALOG)
        malformed = [
            key
            for key, entry in catalog["strings"].items()
            if not isinstance(entry, dict)
            or not isinstance(entry.get("localizations"), dict)
        ]
        self.assertEqual(malformed, [])


if __name__ == "__main__":
    unittest.main()

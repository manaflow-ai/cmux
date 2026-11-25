#!/usr/bin/env python3
"""scripts/ci/settings_catalog_keys.py: a schema text key missing from the catalog fails; a row's setting key does not."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import settings_catalog_keys as gate  # noqa: E402


def tree(root: Path, catalog: list[str]) -> None:
    source = root / gate.SOURCES
    source.mkdir(parents=True)
    (source / "x.json").write_text(json.dumps({"lists": [{"rows": [{
        "key": "experiments.thing",
        "title": {"key": "settings.experiments.thing", "text": "Thing"},
        "help": {"key": "settings.experiments.thing.help", "text": "Help"},
    }]}]}))
    path = root / gate.CATALOG
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"sourceLanguage": "en", "strings": {k: {} for k in catalog}}))


class SettingsCatalogKeysTests(unittest.TestCase):
    def test_missing_text_key_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tree(Path(tmp), ["settings.experiments.thing"])
            self.assertEqual(len(gate.missing(Path(tmp))), 1)
            self.assertEqual(gate.main(["--root", tmp]), 1)

    def test_every_text_key_passes_and_row_key_is_not_a_text(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tree(Path(tmp), ["settings.experiments.thing", "settings.experiments.thing.help"])
            self.assertEqual(gate.missing(Path(tmp)), [])
            self.assertEqual(gate.main(["--root", tmp]), 0)

    def test_repo_catalog_is_complete(self) -> None:
        self.assertEqual(gate.missing(ROOT), [])


if __name__ == "__main__":
    unittest.main()

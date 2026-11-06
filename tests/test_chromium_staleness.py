#!/usr/bin/env python3
"""The Chromium staleness guard fails a pin more than one Chrome stable release behind."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/cmux-next"))
import chromium_staleness as staleness


def answer(*versions):
    return {"versions": [{"version": v} for v in versions]}


class ChromiumStaleness(unittest.TestCase):
    def test_newest_stable_takes_the_highest_version_not_the_first(self):
        self.assertEqual(
            staleness.newest_stable(answer("156.0.8078.80", "157.0.8103.26", "156.0.8078.79")),
            "157.0.8103.26",
        )

    def test_two_majors_behind_is_stale(self):
        stale, report = staleness.verdict("155.0.8050.10", "157.0.8103.26")
        self.assertTrue(stale)
        self.assertIn("2 stable releases behind", report)

    def test_the_shipped_154_pin_is_stale_against_157(self):
        self.assertTrue(staleness.verdict("154.0.8037.58", "157.0.8103.26")[0])

    def test_one_major_behind_passes(self):
        self.assertFalse(staleness.verdict("156.0.8078.80", "157.0.8103.26")[0])

    def test_same_or_newer_major_passes(self):
        self.assertFalse(staleness.verdict("157.0.8103.26", "157.0.8103.26")[0])
        self.assertFalse(staleness.verdict("158.0.8150.1", "157.0.8103.26")[0])

    def test_bad_versions_are_refused(self):
        with self.assertRaises(ValueError):
            staleness.parse_version("154.0")
        with self.assertRaises(ValueError):
            staleness.newest_stable({"versions": []})

    def test_main_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp, "m.json")
            stable = Path(tmp, "s.json")
            stable.write_text(json.dumps(answer("157.0.8103.26")))
            manifest.write_text(json.dumps({"chromium": "154.0.8037.58"}))
            self.assertEqual(staleness.main(["--manifest", str(manifest), "--stable-json", str(stable)]), 1)
            manifest.write_text(json.dumps({"chromium": "156.0.8078.80"}))
            self.assertEqual(staleness.main(["--manifest", str(manifest), "--stable-json", str(stable)]), 0)
            stable.write_text("not json")
            self.assertEqual(staleness.main(["--manifest", str(manifest), "--stable-json", str(stable)]), 3)

    def test_the_repository_pin_parses(self):
        pinned = json.loads((ROOT / "scripts/cmux-next/cef-manifest.json").read_text())["chromium"]
        staleness.parse_version(pinned)


if __name__ == "__main__":
    unittest.main()

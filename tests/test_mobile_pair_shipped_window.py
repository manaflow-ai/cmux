#!/usr/bin/env python3
"""Behavioral checks for scripts/ci/mobile_pair_shipped_window.py."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/mobile_pair_shipped_window.py"
SPEC = importlib.util.spec_from_file_location("window", SCRIPT)
window = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(window)


class ShippedWindowTests(unittest.TestCase):
    def setUp(self):
        self.registry = json.loads(SCRIPT.with_suffix(".json").read_text())

    def test_seed_is_three_published_builds_each_direction(self):
        result = window.resolve(self.registry)
        self.assertEqual(len(result["include"]), 6)
        self.assertEqual({r["role"] for r in result["include"]}, {"host", "dial"})
        self.assertEqual(len(result["fingerprint"]), 64)

    def test_source_deduplication_keeps_all_release_ids(self):
        releases = self.registry["releases"]
        releases[1]["sha"] = releases[0]["sha"]
        result = window.resolve(self.registry)
        self.assertEqual(len(result["include"]), 5)
        self.assertEqual(result["include"][0]["release_ids"],
                         ["20261127140252", "20261127130434"])

    def test_count_is_releases_not_distinct_sources(self):
        for release in self.registry["releases"][:3]:
            release["sha"] = "a" * 40
        self.assertEqual(len(window.resolve(self.registry)["include"]), 4)

    def test_missing_platform_fails_closed(self):
        self.registry["releases"] = self.registry["releases"][:3]
        with self.assertRaisesRegex(ValueError, "mac: need 3"):
            window.resolve(self.registry)

    def test_successful_compilation_is_not_a_release(self):
        self.registry["releases"][0]["evidence"]["kind"] = "build-success"
        with self.assertRaisesRegex(ValueError, "not publication"):
            window.resolve(self.registry)

    def test_duplicate_release_does_not_fill_window(self):
        self.registry["releases"][1] = copy.deepcopy(self.registry["releases"][0])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            window.resolve(self.registry)

    def test_new_release_rolls_oldest_out_and_changes_fingerprint(self):
        before = window.resolve(self.registry)
        release = copy.deepcopy(self.registry["releases"][0])
        release.update(release_id="new-build", sha="f"*40,
                       published_at="2026-11-28T00:00:00Z")
        after = window.resolve(window.record(self.registry, release))
        self.assertNotEqual(before["fingerprint"], after["fingerprint"])
        self.assertEqual(after["include"][0]["sha"], "f"*40)
        self.assertNotIn("20261127025823",
                         [i for r in after["include"] for i in r["release_ids"]])

    def test_registry_order_does_not_change_fingerprint(self):
        before = window.resolve(self.registry)
        self.registry["releases"].reverse()
        self.assertEqual(before, window.resolve(self.registry))

    def test_rerun_is_idempotent_but_cannot_reassign_release(self):
        release = copy.deepcopy(self.registry["releases"][0])
        self.assertEqual(window.record(self.registry, release), self.registry)
        release["sha"] = "f"*40
        with self.assertRaisesRegex(ValueError, "cannot change"):
            window.record(self.registry, release)

    def test_malformed_receipts_fail_closed(self):
        for field, value in (("sha", "abc"), ("published_at", "2026-11-28"),
                             ("release_id", ""), ("evidence", None)):
            with self.subTest(field=field):
                registry = copy.deepcopy(self.registry)
                registry["releases"][0][field] = value
                with self.assertRaises(ValueError):
                    window.resolve(registry)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""chat_open_seed_cache.py: a template entry round-trips, a damaged or mismatched entry is dropped
and seeded again, a write is atomic, and pruning bounds the cache by age, count and size."""

from __future__ import annotations

import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import chat_open_seed_cache as sc  # noqa: E402


def template(sid="11111111-2222-3333-4444-555555555555", turns=2):
    return {"id": sid, "meta": f'{{"id": "{sid}"}}'.encode(),
            "events": {f"{i:06}.ndjson": f'{{"turn": {i}, "sid": "{sid}"}}\n'.encode() * 50 for i in range(turns)}}


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "cache")

    def tearDown(self):
        self.tmp.cleanup()

    def test_round_trip(self):
        entry = {"answered": template(), "closed": template("99999999-2222-3333-4444-555555555555")}
        self.assertTrue(sc.put(self.root, "store-abc", {}, entry, 3.0))
        self.assertEqual(sc.get(self.root, "store-abc"), entry)
        self.assertEqual([n for n in os.listdir(self.root) if n.startswith(sc.TMP_PREFIX)], [])

    def test_a_miss_is_none(self):
        self.assertIsNone(sc.get(self.root, "small-none"))

    def test_a_damaged_file_drops_the_entry(self):
        sc.put(self.root, "big-k", {"turns": 2}, {"big": template()}, 1.0)
        path = os.path.join(self.root, "big-k", "big", "events", "000001.ndjson")
        with open(path, "ab") as handle:
            handle.write(b"x")
        self.assertIsNone(sc.get(self.root, "big-k"))
        self.assertFalse(os.path.exists(os.path.join(self.root, "big-k")))

    def test_an_entry_under_another_key_is_dropped(self):
        sc.put(self.root, "small-a", {}, {"small": template()}, 1.0)
        os.rename(os.path.join(self.root, "small-a"), os.path.join(self.root, "small-b"))
        self.assertIsNone(sc.get(self.root, "small-b"))

    def test_keys_follow_every_input(self):
        base = sc.entry_key("big", {"turns": 10000}, "d1")
        self.assertEqual(base, sc.entry_key("big", {"turns": 10000}, "d1"))
        self.assertNotEqual(base, sc.entry_key("big", {"turns": 9999}, "d1"))
        self.assertNotEqual(base, sc.entry_key("big", {"turns": 10000}, "d2"))
        self.assertNotEqual(base, sc.entry_key("small", {"turns": 10000}, "d1"))

    def test_the_digest_covers_the_generator_and_the_store_schema(self):
        names = [os.path.relpath(p, sc.ROOT) for p in sc.source_files()]
        self.assertIn("scripts/cmux-next/chat_open_agent.py", names)
        self.assertIn("scripts/cmux-next/idle_cost_load.py", names)
        self.assertIn("cmux-tui/crates/acpmux/src/store.rs", names)
        self.assertTrue(any(n.startswith("cmux-tui/crates/acpmux/src/protocol/") for n in names))
        self.assertEqual(sc.source_digest(), sc.source_digest())

    def test_a_racing_writer_keeps_the_first_entry(self):
        self.assertTrue(sc.put(self.root, "small-k", {}, {"small": template()}, 1.0))
        self.assertTrue(sc.put(self.root, "small-k", {}, {"small": template()}, 1.0))
        self.assertIsNotNone(sc.get(self.root, "small-k"))
        self.assertEqual([n for n in os.listdir(self.root) if n.startswith(sc.TMP_PREFIX)], [])

    def test_prune_by_age_count_and_size(self):
        now = time.time()
        for i, age_days in enumerate([0, 1, 2, 8]):
            key = f"small-{i}"
            sc.put(self.root, key, {}, {"small": template()}, 1.0)
            used = now - age_days * 86400
            os.utime(os.path.join(self.root, key, "manifest.json"), (used, used))
        os.makedirs(os.path.join(self.root, sc.TMP_PREFIX + "old"))
        old = now - 2 * 86400
        os.utime(os.path.join(self.root, sc.TMP_PREFIX + "old"), (old, old))
        os.makedirs(os.path.join(self.root, "not-ours"))  # no manifest: never touched
        removed = sc.prune(self.root, now=now, max_entries=2)
        self.assertEqual(sorted(removed), sorted(["small-3", "small-2", sc.TMP_PREFIX + "old"]))
        self.assertEqual(sorted(os.listdir(self.root)), ["not-ours", "small-0", "small-1"])
        size = sc._size(os.path.join(self.root, "small-0"))
        self.assertEqual(sc.prune(self.root, now=now, max_bytes=size, keep=("small-1",)), ["small-0"])


if __name__ == "__main__":
    unittest.main()

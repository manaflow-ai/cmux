#!/usr/bin/env python3
"""chat_open_seed_cache.py: a template entry round-trips, a damaged or mismatched entry is dropped
and seeded again, a write is atomic, and pruning bounds the cache by age, count and size."""

from __future__ import annotations

import os
import sys
import tempfile
import time
import json
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import chat_open_seed_cache as sc  # noqa: E402


def template(sid="11111111-2222-3333-4444-555555555555", turns=2):
    return {"id": sid, "meta": f'{{"id": "{sid}"}}'.encode(),
            "events": {f"{i:06}.ndjson": f'{{"turn": {i}, "sid": "{sid}"}}\n'.encode() * 50 for i in range(turns)}}


def key(name, n=0):
    return sc.entry_key(name, {"n": n}, "digest")


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "cache")

    def tearDown(self):
        self.tmp.cleanup()

    def test_round_trip(self):
        entry = {"answered": template(), "closed": template("99999999-2222-3333-4444-555555555555")}
        self.assertTrue(sc.put(self.root, key("store"), {}, entry, 3.0))
        self.assertEqual(sc.get(self.root, key("store")), entry)
        self.assertEqual([n for n in os.listdir(self.root) if n.startswith(sc.TMP_PREFIX)], [])

    def test_a_miss_is_none(self):
        self.assertIsNone(sc.get(self.root, "small-none"))

    def test_a_damaged_file_drops_the_entry(self):
        sc.put(self.root, key("big"), {"turns": 2}, {"big": template()}, 1.0)
        path = os.path.join(self.root, key("big"), "big", "events", "000001.ndjson")
        with open(path, "ab") as handle:
            handle.write(b"x")
        self.assertIsNone(sc.get(self.root, key("big")))
        self.assertFalse(os.path.exists(os.path.join(self.root, key("big"))))

    def test_an_entry_under_another_key_is_dropped(self):
        sc.put(self.root, key("small", 1), {}, {"small": template()}, 1.0)
        os.rename(os.path.join(self.root, key("small", 1)), os.path.join(self.root, key("small", 2)))
        self.assertIsNone(sc.get(self.root, key("small", 2)))

    def test_a_malformed_manifest_is_a_miss(self):
        sc.put(self.root, key("small"), {}, {"small": template()}, 1.0)
        path = os.path.join(self.root, key("small"), "manifest.json")
        for templates in ([], {}, {"small": []}, {"small": {"id": "x", "meta": {}, "events": []}}, {"../x": {}},
                          {"small": {"id": 7, "meta": {"bytes": 1, "sha256": "0" * 64}, "events": {"0.ndjson": {"bytes": 1, "sha256": "0" * 64}}}},
                          {"small": {"id": "x", "meta": {"bytes": "1", "sha256": "0" * 64}, "events": {"0.ndjson": {"bytes": 1, "sha256": "0" * 64}}}},
                          {"small": {"id": "x", "meta": {"bytes": 1, "sha256": "0" * 64}, "events": {"0.ndjson": {"bytes": 1, "sha256": None}}}}):
            with open(path, "w") as handle:
                json.dump({"format": sc.FORMAT, "key": key("small"), "templates": templates}, handle)
            self.assertIsNone(sc.get(self.root, key("small")))
            os.makedirs(os.path.dirname(path), exist_ok=True)

    def test_an_unwritable_root_runs_uncached(self):
        blocker = os.path.join(self.tmp.name, "file")
        with open(blocker, "w") as handle:
            handle.write("x")
        root = os.path.join(blocker, "cache")  # under a file: makedirs fails
        self.assertFalse(sc.put(root, key("small"), {}, {"small": template()}, 1.0))
        self.assertIsNone(sc.get(root, key("small")))
        self.assertEqual(sc.prune(root), [])

    def test_prune_survives_a_folder_that_vanishes(self):
        os.makedirs(os.path.join(self.root, sc.TMP_PREFIX + "racing"))
        real = os.lstat

        def lstat(path, *a, **k):
            if path.endswith("racing"):
                raise FileNotFoundError(path)
            return real(path, *a, **k)

        with mock.patch.object(sc.os, "lstat", lstat):
            self.assertEqual(sc.prune(self.root), [])

    def test_the_worker_cache_root_comes_first(self):
        with mock.patch.dict(os.environ, {"CMUX_CI_CACHE_DIR": "/w"}, clear=False):
            os.environ.pop("CMUX_BENCH_SEED_CACHE", None)
            self.assertEqual(sc.default_root(), "/w/cmux-bench/chat-open")
            with mock.patch.dict(os.environ, {"CMUX_BENCH_SEED_CACHE": "/o"}):
                self.assertEqual(sc.default_root(), "/o")

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
        self.assertTrue(sc.put(self.root, key("small"), {}, {"small": template()}, 1.0))
        self.assertTrue(sc.put(self.root, key("small"), {}, {"small": template()}, 1.0))
        self.assertIsNotNone(sc.get(self.root, key("small")))
        self.assertEqual([n for n in os.listdir(self.root) if n.startswith(sc.TMP_PREFIX)], [])

    def test_prune_by_age_count_and_size(self):
        now = time.time()
        names = [key("small", i) for i in range(4)]
        for name, age_days in zip(names, [0, 1, 2, 8]):
            sc.put(self.root, name, {}, {"small": template()}, 1.0)
            used = now - age_days * 86400
            os.utime(os.path.join(self.root, name, "manifest.json"), (used, used))
        os.makedirs(os.path.join(self.root, sc.TMP_PREFIX + "old"))
        old = now - 2 * 86400
        os.utime(os.path.join(self.root, sc.TMP_PREFIX + "old"), (old, old))
        # Not ours, so never touched: no manifest; a manifest but not a key name; a key name whose manifest names another key.
        os.makedirs(os.path.join(self.root, "not-ours"))
        foreign = [os.path.join(self.root, "theirs"), os.path.join(self.root, key("other"))]
        for folder in foreign:
            os.makedirs(folder)
            with open(os.path.join(folder, "manifest.json"), "w") as handle:
                json.dump({"format": sc.FORMAT, "key": "something-else"}, handle)
            os.utime(os.path.join(folder, "manifest.json"), (now - 30 * 86400,) * 2)
        removed = sc.prune(self.root, now=now, max_entries=2)
        self.assertEqual(sorted(removed), sorted([names[3], names[2], sc.TMP_PREFIX + "old"]))
        self.assertEqual(sorted(os.listdir(self.root)), sorted(["not-ours", "theirs", key("other"), names[0], names[1]]))
        size = sc._size(os.path.join(self.root, names[0]))
        self.assertEqual(sc.prune(self.root, now=now, max_bytes=size, keep=(names[1],)), [names[0]])


if __name__ == "__main__":
    unittest.main()

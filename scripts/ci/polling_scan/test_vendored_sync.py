#!/usr/bin/env python3
"""The vendored polling judge must stay byte-identical to the cmuxterm-hq commit UPSTREAM.json records.

A local edit (or a partial copy) changes a file's git blob id, and this test fails, so the copy can only move
by re-copying from HQ and recording the new commit and blob ids."""

import hashlib
import json
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def blob_id(data: bytes) -> str:
    """git hash-object of data, without git."""
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


class VendoredSync(unittest.TestCase):
    def test_every_copy_matches_its_recorded_hq_blob(self):
        doc = json.loads((HERE / "UPSTREAM.json").read_text())
        self.assertRegex(doc["sha"], r"^[0-9a-f]{40}$")
        self.assertEqual(set(doc["blobs"]), {"block_polling.py", "polling_scan.py", "test_polling_scan.py"})
        for name, want in doc["blobs"].items():
            with self.subTest(name):
                got = blob_id((HERE / name).read_bytes())
                self.assertEqual(got, want, f"{name} differs from cmuxterm-hq {doc['sha'][:12]}:"
                                            f"{doc['path']}/{name}; re-copy it from HQ and update UPSTREAM.json")

    def test_blob_id_matches_git(self):
        self.assertEqual(blob_id(b""), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""The release body is an exact, idempotent publication record."""

import importlib.util
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "nightly_publication_marker", ROOT / "scripts/ci/nightly-publication-marker.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class NightlyPublicationMarkerTests(unittest.TestCase):
    SHA = "A" * 40

    def test_reads_exact_sha_marker_case_insensitively(self):
        body = f"before\n<!-- cmux-published-sha: {self.SHA} -->\nafter"
        self.assertEqual(MODULE.published_sha(body), self.SHA.lower())

    def test_missing_or_malformed_marker_does_not_claim_publication(self):
        self.assertIsNone(MODULE.published_sha("Published commit: `" + "a" * 40 + "`"))
        self.assertIsNone(MODULE.published_sha("<!-- cmux-published-sha: " + "a" * 39 + " -->"))


if __name__ == "__main__":
    unittest.main()

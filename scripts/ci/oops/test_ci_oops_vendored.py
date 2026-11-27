#!/usr/bin/env python3
"""The vendored ci-oops copy is cmuxterm-hq tools/ci-oops's, byte for byte (vendor.py writes this file too).
Run: python3 scripts/ci/oops/test_ci_oops_vendored.py"""
import hashlib
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import oops_core as core  # noqa: E402


class Vendored(unittest.TestCase):
    def test_core_block_is_hq_byte_for_byte(self):
        self.assertEqual(core.fingerprint(Path(core.__file__).read_text()), core.FINGERPRINT,
                         "oops_core's ci-oops block is cmuxterm-hq tools/ci-oops/oops_core.py's: change it there, then "
                         "run its vendor.py here")

    def test_every_file_matches_the_manifest(self):
        manifest = json.loads((HERE / "MANIFEST.json").read_text())
        for rel, digest in manifest["files"].items():
            self.assertEqual(hashlib.sha256((HERE / rel).read_bytes()).hexdigest(), digest,
                             f"{rel} differs from cmuxterm-hq's: vendor it again, never edit it here")

    def test_rules_load_and_are_sound(self):
        rules = []
        for path in sorted((HERE / "rules").glob("*.json")):
            data = json.loads(path.read_text())
            rules += data.get("rules", []) if isinstance(data, dict) else data
        self.assertEqual(core.validate_rules(rules), [])

    def test_runner_died_is_infra_and_swallowed(self):
        rules = []
        for path in sorted((HERE / "rules").glob("*.json")):
            data = json.loads(path.read_text())
            rules += data.get("rules", []) if isinstance(data, dict) else data
        got = core.classify({"job": "x", "log_tail": "##[error]The runner has received a shutdown signal."}, rules)
        self.assertEqual((got["class"], got["swallow"]), ("infra", True))


if __name__ == "__main__":
    unittest.main()

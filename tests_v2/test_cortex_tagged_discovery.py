#!/usr/bin/env python3
"""Execute the actual discovery predicate without CMUX, defaults or app registration."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class TaggedCortexDiscoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (ROOT / "Sources/CmuxExtensionSidebarSelection.swift").read_text()
        # Compile the production method verbatim; do not reimplement its policy.
        start = source.index("    static func isCortexBundle(")
        end = source.index("\n    static func isCortexActive(", start)
        predicate = source[start:end]
        harness = r'''
import Foundation
enum ActualDiscovery {
PREDICATE
}
let host = "com.cmuxterm.app.debug.cortex.management"
let canonical = "fr.yoyaku.cortex.dogfood.cortex-management.sessions"
let results: [String: Bool] = [
    "canonicalPair": ActualDiscovery.isCortexBundle(canonical, hostBundleID: host),
    "otherTag": ActualDiscovery.isCortexBundle(canonical, hostBundleID: "com.cmuxterm.app.debug.other.tag"),
    "productionHost": ActualDiscovery.isCortexBundle(canonical, hostBundleID: "com.cmuxterm.app"),
    "foreignHost": ActualDiscovery.isCortexBundle(canonical, hostBundleID: "dev.foreign.debug.cortex.management"),
    "missingHost": ActualDiscovery.isCortexBundle(canonical, hostBundleID: nil),
    "legacyTaggedForm": ActualDiscovery.isCortexBundle("fr.yoyaku.cortex.sessions.dogfood.cortex-management", hostBundleID: host),
    "embeddedPair": ActualDiscovery.isCortexBundle(host + ".sessions", hostBundleID: host),
    "otherEmbeddedPair": ActualDiscovery.isCortexBundle("com.cmuxterm.app.debug.other.tag.sessions", hostBundleID: host),
    "productionExtension": ActualDiscovery.isCortexBundle("fr.yoyaku.cortex.sessions", hostBundleID: "com.cmuxterm.app"),
    "debugExtension": ActualDiscovery.isCortexBundle("fr.yoyaku.cortex.sessions.debug", hostBundleID: "com.cmuxterm.app.debug"),
    "malformedTagsRejected": ["", "-cortex", "cortex-", "cortex--management", "Cortex-management", "cortex.management", "cortex_management", "cortex/management"].allSatisfy { tag in
        !ActualDiscovery.isCortexBundle("fr.yoyaku.cortex.dogfood." + tag + ".sessions", hostBundleID: host)
    },
    "missingSuffix": ActualDiscovery.isCortexBundle("fr.yoyaku.cortex.dogfood.cortex-management", hostBundleID: host),
    "extraSuffix": ActualDiscovery.isCortexBundle(canonical + ".extra", hostBundleID: host)
]
print(String(decoding: try JSONSerialization.data(withJSONObject: results), as: UTF8.self))
'''.replace("PREDICATE", predicate)
        with tempfile.TemporaryDirectory(prefix="cortex-discovery-") as directory:
            scratch = Path(directory)
            swift = scratch / "main.swift"
            swift.write_text(harness)
            binary = scratch / "discovery"
            subprocess.run(["arch", "-arm64", "xcrun", "swiftc", str(swift), "-o", str(binary)],
                           check=True, capture_output=True, text=True, timeout=120)
            run = subprocess.run(["arch", "-arm64", str(binary)], check=True, capture_output=True, text=True, timeout=10)
            cls.values = json.loads(run.stdout)

    def test_canonical_tagged_extension_matches_exact_native_host(self):
        self.assertTrue(self.values["canonicalPair"])

    def test_canonical_extension_rejects_cross_tag_and_foreign_hosts(self):
        self.assertFalse(self.values["otherTag"])
        self.assertFalse(self.values["foreignHost"])
        self.assertFalse(self.values["missingHost"])

    def test_production_host_rejects_tagged_dogfood_extension(self):
        self.assertFalse(self.values["productionHost"])

    def test_obsolete_tagged_identifier_is_not_a_discovery_alias(self):
        self.assertFalse(self.values["legacyTaggedForm"])

    def test_native_embedded_pair_remains_exact(self):
        self.assertTrue(self.values["embeddedPair"])
        self.assertFalse(self.values["otherEmbeddedPair"])

    def test_existing_production_and_debug_ids_remain_compatible(self):
        self.assertTrue(self.values["productionExtension"])
        self.assertTrue(self.values["debugExtension"])

    def test_malformed_tags_and_suffixes_do_not_match(self):
        self.assertTrue(self.values["malformedTagsRejected"])
        self.assertFalse(self.values["missingSuffix"])
        self.assertFalse(self.values["extraSuffix"])


if __name__ == "__main__":
    unittest.main()

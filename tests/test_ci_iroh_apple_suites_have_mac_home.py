#!/usr/bin/env python3
"""Every CmuxIrohTransport test suite that compiles only on Apple platforms runs on a Mac in relay-tls.yml.

swift-linux-packages.yml runs the CmuxIrohTransport package whole on Linux, and there a suite under
`#if canImport(IrohLib)` or `#if canImport(dnssd)` compiles to nothing. Before 2026-11-26 nine IrohLib suites
and the Bonjour browser ran on a Mac nowhere on a cmux NEXT pull request: the Mac package lane that listed
them does not run there. relay-tls.yml already builds the package on a Mac for those pull requests, so its
--filter carries every such suite. A new gated suite fails this test until it joins that filter.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "Packages/Shared/CmuxIrohTransport/Tests"
WORKFLOW = ROOT / ".github/workflows/relay-tls.yml"
GATE = re.compile(r"^#if canImport\((IrohLib|dnssd)\)", re.M)
SUITE = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:final\s+)?(?:struct|class)\s+(Cmx\w+Tests)\b", re.M)
FILTER = re.compile(r"swift test --package-path Packages/Shared/CmuxIrohTransport --filter '([^']+)'")


def gated_suites() -> set[str]:
    suites: set[str] = set()
    for path in TESTS.rglob("*.swift"):
        text = path.read_text()
        gate = GATE.search(text)
        if not gate:
            continue
        suites.update(SUITE.findall(text[gate.end():]))
    return suites


def mac_filter() -> re.Pattern[str]:
    found = FILTER.findall(WORKFLOW.read_text())
    if len(found) != 1:
        raise AssertionError(f"{WORKFLOW.name}: expected one CmuxIrohTransport swift test --filter, found {len(found)}")
    return re.compile(found[0])


class IrohAppleSuitesHaveMacHome(unittest.TestCase):
    def test_the_scan_finds_the_known_suites(self) -> None:
        suites = gated_suites()
        # The ten found on 2026-11-26; a rename or a new gated suite still passes this, a scan that misses one fails it.
        known = {
            "CmxIrohConnectionDiagnosticRecorderTests", "CmxIrohConnectionPathDiagnosticsTests",
            "CmxIrohCustomRelayLiveTests", "CmxIrohDiagnosticFailureTests", "CmxIrohDirectTransportGateTests",
            "CmxIrohLibEndpointCancellationTests", "CmxIrohLibEndpointTests", "CmxIrohPrivatePathTransportGateTests",
            "CmxIrohRelayDiagnosticObserverTests", "CmxIrohSystemBonjourBrowserTests",
        }
        self.assertGreaterEqual(len(suites & known), 8, sorted(known - suites))
        self.assertEqual(sorted(known - suites - self._renamed(known)), [])

    @staticmethod
    def _renamed(known: set[str]) -> set[str]:
        # A known suite whose file is gone was renamed or removed: not the scan's miss.
        return {k for k in known if not any(TESTS.rglob(f"{k}.swift"))}

    def test_every_gated_suite_is_in_the_relay_tls_filter(self) -> None:
        pattern = mac_filter()
        missing = sorted(s for s in gated_suites() if not pattern.search(s))
        self.assertEqual(missing, [], f"add these to {WORKFLOW.name}'s CmuxIrohTransport --filter")

    def test_the_filter_catches_a_new_suite_left_out(self) -> None:
        pattern = mac_filter()
        self.assertIsNone(pattern.search("CmxIrohSomethingNewTests"))


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)

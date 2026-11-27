#!/usr/bin/env python3
"""tests/relay_tls/Package.resolved pins iroh-ffi, which the relay TLS probe builds against.

tests/relay_tls/system_keychain.py builds its probe at that pin and stops at `next(...)` with StopIteration before
any trust check runs when the pin is missing (relay-tls.yml system-keychain, job 140005992203). The lock used to be
CmuxIrohTransport's; that package had no consumer and was deleted, so the probe keeps its own.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "tests" / "relay_tls" / "Package.resolved"


class RelayTLSProbeLockPinsIrohFFI(unittest.TestCase):
    def test_the_probe_lock_pins_iroh_ffi_at_an_exact_version(self) -> None:
        pins = {pin["identity"]: pin for pin in json.loads(LOCK.read_text())["pins"]}
        self.assertIn("iroh-ffi", pins, "tests/relay_tls/Package.resolved lost the iroh-ffi pin")
        pin = pins["iroh-ffi"]
        self.assertEqual(pin["location"], "https://github.com/manaflow-ai/iroh-ffi.git")
        self.assertTrue(pin["state"].get("version"), "the iroh-ffi pin names an exact version")
        self.assertTrue(pin["state"].get("revision"), "the iroh-ffi pin names a revision")

    def test_relay_tls_probe_reads_the_iroh_ffi_pin(self) -> None:
        script = (ROOT / "tests" / "relay_tls" / "system_keychain.py").read_text()
        self.assertIn('pin["identity"] == "iroh-ffi"', script)
        self.assertIn('Path(__file__).with_name("Package.resolved")', script)


if __name__ == "__main__":
    unittest.main()

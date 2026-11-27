#!/usr/bin/env python3
"""CmuxIrohTransport's Package.resolved pins every remote package its manifest names, in both shapes.

The manifest has an Apple shape (iroh-ffi's IrohLib) and a Linux shape (CMUX_SWIFTPM_TARGET_LINUX drops iroh-ffi
and adds swift-crypto). A lock file resolved in the Linux shape alone drops the iroh-ffi pin, and
tests/relay_tls/system_keychain.py, which builds its probe against that pin, stops at `next(...)` with
StopIteration before any trust check runs (relay-tls.yml system-keychain, job 140005992203). So the committed lock
keeps the union: each `url:`/`exact:` pair in Package.swift has a pin at that location and version.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Packages" / "Shared" / "CmuxIrohTransport"
# `.package(url: "...", exact: "...")`, over one line or several.
REMOTE = re.compile(r'\.package\(\s*url:\s*"([^"]+)",\s*exact:\s*"([^"]+)"\s*\)')


def identity(url: str) -> str:
    return url.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git").lower()


class IrohTransportLockPins(unittest.TestCase):
    def test_every_remote_package_in_either_shape_is_pinned_at_its_exact_version(self) -> None:
        wanted = {identity(url): (url, version) for url, version in REMOTE.findall((PACKAGE / "Package.swift").read_text())}
        self.assertIn("iroh-ffi", wanted, "Package.swift names iroh-ffi with `exact:`")
        self.assertIn("swift-crypto", wanted, "the Linux shape names swift-crypto with `exact:`")
        pins = {pin["identity"]: pin for pin in json.loads((PACKAGE / "Package.resolved").read_text())["pins"]}
        for name, (url, version) in sorted(wanted.items()):
            with self.subTest(name):
                self.assertIn(name, pins, f"Package.resolved lost the {name} pin: resolve in both shapes and keep the union")
                self.assertEqual(pins[name]["location"], url)
                self.assertEqual(pins[name]["state"].get("version"), version)

    def test_relay_tls_probe_reads_the_iroh_ffi_pin(self) -> None:
        script = (ROOT / "tests" / "relay_tls" / "system_keychain.py").read_text()
        self.assertIn('pin["identity"] == "iroh-ffi"', script)
        self.assertIn("CmuxIrohTransport/Package.resolved", script)


if __name__ == "__main__":
    unittest.main()

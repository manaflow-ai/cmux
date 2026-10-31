#!/usr/bin/env python3
"""Guard: cmux-tui ships no compiled-in webpki root list.

A compiled-in list (webpki-roots / webpki-root-certs) still trusts the
emSign (eMudhra) roots whose intermediate keys leaked on 2026-10-20
(issue manaflow-ai/cmux#25452). cmux-tui must verify TLS against the
platform trust store (rustls-native-certs via tokio-tungstenite's
`rustls-tls-native-roots`), which follows Apple's root removals.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TUI = ROOT / "cmux-tui"

BANNED_CRATES = ("webpki-roots", "webpki-root-certs")
BANNED_IDENTS = ("webpki_roots", "webpki_root_certs")
BANNED_FEATURE = "rustls-tls-webpki-roots"
EMSIGN_NAMES = (
    "emSign Root CA - G1",
    "emSign ECC Root CA - G3",
    "emSign Root CA - C1",
    "emSign ECC Root CA - C3",
)


def _manifests() -> list[Path]:
    return sorted(TUI.glob("Cargo.toml")) + sorted(TUI.glob("crates/*/Cargo.toml")) + sorted(
        TUI.glob("bindings/*/Cargo.toml")
    )


def _sources() -> list[Path]:
    return [p for p in TUI.rglob("*.rs") if "target" not in p.parts]


class NoBundledWebpkiRootsTests(unittest.TestCase):
    def test_lockfile_bundled_roots_have_no_live_dependents(self) -> None:
        # Only inert dependents may keep a bundled root crate in the lock:
        # iroh-relay (its root store is unused with iroh's platform-verifier
        # feature) and rustls-platform-verifier (wasm32-only dependency).
        allowed = {
            "webpki-roots": {"iroh-relay"},
            "webpki-root-certs": {"rustls-platform-verifier"},
        }
        lock = (TUI / "Cargo.lock").read_text(encoding="utf-8")
        offenders: list[str] = []
        for block in lock.split("[[package]]")[1:]:
            name_m = re.search(r'^name = "([^"]+)"', block, re.MULTILINE)
            if not name_m:
                continue
            pkg = name_m.group(1)
            for root, ok_dependents in allowed.items():
                if pkg in ok_dependents:
                    continue
                if re.search(rf'^ "{re.escape(root)}(?: [\d.]+)?",?$', block, re.MULTILINE):
                    offenders.append(f"{pkg} -> {root}")
        self.assertEqual(
            offenders,
            [],
            "cmux-tui still compiles a bundled root list "
            "(trusts emSign/eMudhra roots, #25452)",
        )

    def test_iroh_uses_platform_verifier(self) -> None:
        text = (TUI / "Cargo.toml").read_text(encoding="utf-8")
        iroh = re.search(r"^iroh = \{[^\n]*\}", text, re.MULTILINE)
        self.assertIsNotNone(iroh)
        self.assertIn('"platform-verifier"', iroh.group(0))

    def test_manifests_do_not_enable_bundled_roots(self) -> None:
        offenders: list[str] = []
        for manifest in _manifests():
            text = manifest.read_text(encoding="utf-8")
            for name in BANNED_CRATES:
                if re.search(rf"^{re.escape(name)}\s*=", text, re.MULTILINE) or re.search(
                    rf'package\s*=\s*"{re.escape(name)}"', text
                ):
                    offenders.append(f"{manifest.relative_to(ROOT)}: {name}")
            if BANNED_FEATURE in text:
                offenders.append(f"{manifest.relative_to(ROOT)}: {BANNED_FEATURE}")
        self.assertEqual(offenders, [])

    def test_sources_do_not_read_bundled_roots(self) -> None:
        offenders: list[str] = []
        for source in _sources():
            text = source.read_text(encoding="utf-8", errors="replace")
            for ident in BANNED_IDENTS:
                if ident in text:
                    offenders.append(f"{source.relative_to(ROOT)}: {ident}")
        self.assertEqual(offenders, [])

    def test_sources_do_not_name_emsign_roots(self) -> None:
        offenders: list[str] = []
        for source in _sources():
            text = source.read_text(encoding="utf-8", errors="replace")
            for name in EMSIGN_NAMES:
                if name in text:
                    offenders.append(f"{source.relative_to(ROOT)}: {name}")
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()

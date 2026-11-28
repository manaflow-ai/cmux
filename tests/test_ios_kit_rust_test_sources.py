#!/usr/bin/env python3
"""The ios-kit steps (ci/steps.toml ios-kit, ios-kit-macos) ignore a routed Rust crate's tests/, benches/ and examples/
sources: the FFI's release build never compiles them. This fails when a routed crate's library or build script reaches
one (#[path], include!, include_str!, include_bytes!), which would make the ignore hide a real input.

    python3 tests/test_ios_kit_rust_test_sources.py
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import ci_steps  # noqa: E402
import ios_fast_verdict as fv  # noqa: E402

REACH = re.compile(r"""(#\[path\s*=|include(?:_str|_bytes)?!\s*\()[^\n]*\b(tests|benches|examples)/""")


def routed_crates(step: ci_steps.Step) -> list[Path]:
    crates = []
    for parent in ("cmux-tui/crates", "cmux-tui/vendor", "cmux-next-ios/rust/crates"):
        base = ROOT / parent
        if not base.is_dir():
            continue
        for crate in sorted(p for p in base.iterdir() if (p / "Cargo.toml").is_file()):
            if fv.routes_ios(step, f"{parent}/{crate.name}/src/lib.rs"):
                crates.append(crate)
    return crates


class RustTestSources(unittest.TestCase):
    def test_library_never_reaches_test_sources(self) -> None:
        table = ci_steps.load()
        hits = []
        for name in ("ios-kit", "ios-kit-macos"):
            crates = routed_crates(table.steps[name])
            self.assertTrue(crates, name)
            for crate in crates:
                files = [crate / "build.rs"] if (crate / "build.rs").is_file() else []
                files += [f for f in (crate / "src").rglob("*.rs") if not f.name.endswith("tests.rs")]
                for f in files:
                    for line in f.read_text(errors="replace").splitlines():
                        if REACH.search(line) and "fixtures/" not in line:
                            hits.append(f"{f.relative_to(ROOT)}: {line.strip()}")
        self.assertEqual(hits, [], "a routed crate's library reads a tests/, benches/ or examples/ source; "
                                   "drop that ignore from ci/steps.toml's ios-kit steps")

    def test_test_sources_skip_and_inputs_stay(self) -> None:
        table = ci_steps.load()
        for name in ("ios-kit", "ios-kit-macos"):
            step = table.steps[name]
            for path in ("cmux-next-ios/rust/crates/cmux-mobile-link/tests/roaming.rs",
                         "cmux-next-ios/rust/crates/cmux-mobile-link/benches/x.rs",
                         "cmux-tui/crates/cmux-window-rules/tests/rules.rs",
                         "cmux-tui/crates/cmux-window-rules/examples/demo/main.rs"):
                self.assertFalse(fv.routes_ios(step, path), (name, path))
            for path in ("cmux-next-ios/rust/crates/cmux-mobile-link-ffi/tests/fixtures/connection_contract.json",
                         "cmux-next-ios/rust/crates/cmux-mobile-link/src/lib.rs",
                         "cmux-next-ios/rust/crates/cmux-mobile-link/Cargo.toml",
                         "cmux-tui/crates/cmux-window-rules/src/lib.rs",
                         "cmux-tui/Cargo.lock",
                         "cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileLinkTests/X.swift"):
                self.assertTrue(fv.routes_ios(step, path), (name, path))


if __name__ == "__main__":
    unittest.main()

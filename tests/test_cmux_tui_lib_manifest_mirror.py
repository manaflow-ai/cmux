"""cmux-tui-lib compiles cmux-tui/src/main.rs, so it needs every dependency that cmux-tui lists.

#60340 (2026-11-28 20:33Z) split cmux-tui's lib into cmux-tui-lib, which uses
cmux-tui/crates/cmux-tui/src/main.rs as its crate root. A PR that adds a crate for src/ code to
cmux-tui/crates/cmux-tui/Cargo.toml alone still builds cmux-tui, but cmux-tui-lib, the crate that
actually compiles src/, cannot find the crate. That happened twice within 15 minutes. #45927's
cmux-agent-screen-detection and cmux-cloud, and #64482's cmux-cloud-phone-acp, were each added
only to cmux-tui. Every cmux-tui Linux build on feat-cmux-next then failed with E0433 "cannot
find module or crate", for example build-machine-channel x86_64 lane 2 in job 141112247873 and
aarch64 lane 0 in job 141114697727. Any dependency cmux-tui lists, in [dependencies] or in a
target table, must also be in cmux-tui-lib. The only exception is cmux-tui-lib itself.

Stdlib only, no build: run python3 tests/test_cmux_tui_lib_manifest_mirror.py.
"""
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "cmux-tui/crates/cmux-tui/Cargo.toml"
LIB = ROOT / "cmux-tui/crates/cmux-tui-lib/Cargo.toml"


def deps(manifest: dict) -> set[tuple[str, str]]:
    out = {("", name) for name in manifest.get("dependencies", {})}
    for target, table in manifest.get("target", {}).items():
        out |= {(target, name) for name in table.get("dependencies", {})}
    return out


class CmuxTuiLibManifestMirror(unittest.TestCase):
    def test_lib_has_every_bin_dependency(self):
        bin_manifest = tomllib.loads(BIN.read_text())
        lib_manifest = tomllib.loads(LIB.read_text())
        self.assertEqual(lib_manifest["lib"]["path"], "../cmux-tui/src/main.rs")
        lib_deps = deps(lib_manifest)
        missing = sorted(
            f"{name} ({target or 'dependencies'})"
            for target, name in deps(bin_manifest) - lib_deps
            if name != "cmux-tui-lib"
        )
        self.assertEqual(
            missing,
            [],
            "cmux-tui/crates/cmux-tui-lib/Cargo.toml compiles cmux-tui/src/; add these there too "
            "(same table, same spec)",
        )


if __name__ == "__main__":
    unittest.main()

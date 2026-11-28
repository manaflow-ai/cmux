#!/usr/bin/env python3
"""cmux-tui-lib declares every dependency cmux-tui declares.

Both packages compile the same sources (cmux-tui/crates/cmux-tui/src): cmux-tui-lib builds
them as the `cmux_tui` library, cmux-tui holds the binaries and integration tests (#60340).
A crate the sources start using has to be in cmux-tui-lib's manifest. Three PRs added theirs
to cmux-tui's only (cmux-cloud-phone-acp in #64482; cmux-cloud and cmux-agent-screen-detection
in #45927), so cmux-tui-lib stopped compiling. The App Store shelf, which builds it, stayed
red on feat-cmux-next.
"""
import tomllib
import unittest
from pathlib import Path

CRATES = Path(__file__).resolve().parent.parent / "cmux-tui" / "crates"
# cmux-tui depends on the library itself; that is the one entry the library cannot have.
ONLY_IN_TUI = {"cmux-tui-lib"}


def dependency_names(manifest: Path) -> dict[str, str]:
    """Every normal dependency, top-level or per target: name -> the table that declares it."""
    data = tomllib.loads(manifest.read_text())
    names = {name: "[dependencies]" for name in data.get("dependencies", {})}
    for target, tables in data.get("target", {}).items():
        for name in tables.get("dependencies", {}):
            names.setdefault(name, f"[target.'{target}'.dependencies]")
    return names


def missing_from_lib(tui: dict[str, str], lib: dict[str, str]) -> list[str]:
    return sorted(f"{name} ({table})" for name, table in tui.items() if name not in lib and name not in ONLY_IN_TUI)


class TuiLibManifestDeps(unittest.TestCase):
    def test_lib_declares_every_cmux_tui_dependency(self):
        tui = dependency_names(CRATES / "cmux-tui" / "Cargo.toml")
        lib = dependency_names(CRATES / "cmux-tui-lib" / "Cargo.toml")
        missing = missing_from_lib(tui, lib)
        self.assertEqual(
            missing,
            [],
            "cmux-tui-lib compiles cmux-tui/src too: add these to "
            "cmux-tui/crates/cmux-tui-lib/Cargo.toml as cmux-tui declares them: " + ", ".join(missing),
        )

    def test_the_check_catches_the_base_red(self):
        # The 11-28 manifests: cmux-tui had the three crates, the library did not.
        tui = {"cmux-link": "[dependencies]", "cmux-cloud-phone-acp": "[dependencies]",
               "cmux-cloud": "[target.'cfg(unix)'.dependencies]", "cmux-tui-lib": "[dependencies]"}
        lib = {"cmux-link": "[dependencies]"}
        self.assertEqual(
            missing_from_lib(tui, lib),
            ["cmux-cloud ([target.'cfg(unix)'.dependencies])", "cmux-cloud-phone-acp ([dependencies])"],
        )


if __name__ == "__main__":
    unittest.main()

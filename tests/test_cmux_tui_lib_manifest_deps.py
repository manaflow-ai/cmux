#!/usr/bin/env python3
"""cmux-tui-lib declares every dependency cmux-tui declares.

Both packages compile the same sources (cmux-tui/crates/cmux-tui/src): cmux-tui-lib builds
them as the `cmux_tui` library, cmux-tui holds the binaries and integration tests (#60340).
A crate the sources start using has to be in cmux-tui-lib's manifest. Three PRs added theirs
to cmux-tui's only (cmux-cloud-phone-acp in #64482; cmux-cloud and cmux-agent-screen-detection
in #45927), so cmux-tui-lib stopped compiling. The App Store shelf, which builds it, stayed
red on feat-cmux-next. Dev-dependencies count too, where cmux-tui/src names the crate: the
library's unit tests compile the same `#[cfg(test)]` code (`cargo clippy --all-targets` on
cmux-tui-lib failed on cmux-view-rows, #65724). Dev-dependencies only tests/ uses stay
cmux-tui's.
"""
import tomllib
import unittest
from pathlib import Path

CRATES = Path(__file__).resolve().parent.parent / "cmux-tui" / "crates"
SOURCES = CRATES / "cmux-tui" / "src"
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


def dev_dependency_names(manifest: Path) -> dict[str, str]:
    """Every dev-dependency, top-level or per target: name -> the table that declares it."""
    data = tomllib.loads(manifest.read_text())
    names = {name: "[dev-dependencies]" for name in data.get("dev-dependencies", {})}
    for target, tables in data.get("target", {}).items():
        for name in tables.get("dev-dependencies", {}):
            names.setdefault(name, f"[target.'{target}'.dev-dependencies]")
    return names


def named_in_sources(names: dict[str, str], sources: str) -> dict[str, str]:
    """The entries whose crate path (dashes as underscores) the shared sources use."""
    return {name: table for name, table in names.items() if name.replace("-", "_") + "::" in sources}


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

    def test_lib_declares_every_dev_dependency_the_sources_use(self):
        sources = "\n".join(p.read_text() for p in SOURCES.rglob("*.rs"))
        tui = named_in_sources(dev_dependency_names(CRATES / "cmux-tui" / "Cargo.toml"), sources)
        manifest = CRATES / "cmux-tui-lib" / "Cargo.toml"
        lib = {**dependency_names(manifest), **dev_dependency_names(manifest)}
        missing = missing_from_lib(tui, lib)
        self.assertEqual(
            missing,
            [],
            "cmux-tui-lib's unit tests compile cmux-tui/src's #[cfg(test)] code too: add these to "
            "cmux-tui/crates/cmux-tui-lib/Cargo.toml as cmux-tui declares them: " + ", ".join(missing),
        )

    def test_the_dev_check_catches_the_clippy_red(self):
        # #65724's head: cmux-tui's dev table had cmux-view-rows, src/ used it, the library's did not.
        tui = {"cmux-view-rows": "[dev-dependencies]", "cmux-tui-test-modules": "[dev-dependencies]"}
        used = named_in_sources(tui, "#[cfg(test)]\ncmux_view_rows::frame_work::walked(1);")
        self.assertEqual(missing_from_lib(used, {}), ["cmux-view-rows ([dev-dependencies])"])

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

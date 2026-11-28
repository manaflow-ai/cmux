"""cmux-tui-lib compiles ../cmux-tui/src, so every crate that source uses must be a
dependency of cmux-tui-lib, not only of the cmux-tui package that holds the binaries.

#60340 split the library out; #45927 (cmux-cloud, the screen-detection plugin) and
#64482 (cmux-cloud-phone-acp) then added deps to cmux-tui only, and the Linux cross
seed (cmux machine channel cargo seed) failed with E0433 on cmux_cloud.
"""

import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CRATES = ROOT / "cmux-tui" / "crates"


def _runtime_deps(manifest: Path) -> dict[str, set[str]]:
    data = tomllib.loads(manifest.read_text())
    out = {"": set(data.get("dependencies", {}))}
    for target, table in data.get("target", {}).items():
        out[target] = set(table.get("dependencies", {}))
    return out


def test_every_cmux_tui_dependency_is_a_cmux_tui_lib_dependency():
    tui = _runtime_deps(CRATES / "cmux-tui" / "Cargo.toml")
    lib = _runtime_deps(CRATES / "cmux-tui-lib" / "Cargo.toml")
    missing = []
    for target, deps in tui.items():
        for dep in sorted(deps - {"cmux-tui-lib"}):
            if dep not in lib.get(target, set()):
                missing.append(f"[{'target.' + target + '.' if target else ''}dependencies] {dep}")
    assert not missing, (
        "cmux-tui-lib compiles cmux-tui/src but lacks these cmux-tui deps; add them to "
        "cmux-tui/crates/cmux-tui-lib/Cargo.toml under the same table:\n  " + "\n  ".join(missing)
    )

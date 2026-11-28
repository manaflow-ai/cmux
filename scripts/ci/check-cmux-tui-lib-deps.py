#!/usr/bin/env python3
"""cmux-tui-lib compiles cmux-tui's src/ (its [lib] path is ../cmux-tui/src/main.rs, #60340),
so every crate that src/ may name has to be a dependency of cmux-tui-lib. A dependency added
only to cmux-tui's manifest still builds `cargo check -p cmux-tui`'s tiny entry point but breaks
the program: `cannot find module or crate` in cmux-tui-lib (CMUX-570's cmux-cloud and
cmux-agent-screen-detection did this on feat-cmux-next, 11-28).

Fails when a dependency table of crates/cmux-tui/Cargo.toml names a crate the same table of
crates/cmux-tui-lib/Cargo.toml lacks. Exit 0 clean, 1 drift, 2 broken check.
"""
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11: nothing to read the manifests with.
    print("check-cmux-tui-lib-deps: skipped, needs Python 3.11+ (tomllib)")
    sys.exit(0)

ROOT = Path(__file__).resolve().parents[2] / "cmux-tui" / "crates"
# cmux-tui itself depends on the lib; its integration tests (tests/it) stay in cmux-tui.
ONLY_IN_BIN = {("dependencies", "", "cmux-tui-lib"), ("dev-dependencies", "", "cmux-tui-test-modules")}
TABLES = ("dependencies", "dev-dependencies", "build-dependencies")


def deps(path: Path) -> set[tuple[str, str, str]]:
    doc = tomllib.loads(path.read_text())
    out = {(t, "", n) for t in TABLES for n in doc.get(t, {})}
    for target, body in doc.get("target", {}).items():
        out |= {(t, target, n) for t in TABLES for n in body.get(t, {})}
    return out


def main() -> int:
    try:
        bin_deps = deps(ROOT / "cmux-tui" / "Cargo.toml")
        lib_deps = deps(ROOT / "cmux-tui-lib" / "Cargo.toml")
    except (OSError, tomllib.TOMLDecodeError) as err:
        print(f"check-cmux-tui-lib-deps: cannot read the manifests: {err}", file=sys.stderr)
        return 2
    missing = sorted(bin_deps - lib_deps - ONLY_IN_BIN)
    for table, target, name in missing:
        where = f"[target.{target!r}.{table}]" if target else f"[{table}]"
        print(f"::error file=cmux-tui/crates/cmux-tui-lib/Cargo.toml::{name} is in cmux-tui's {where} "
              f"but not cmux-tui-lib's; cmux-tui-lib compiles cmux-tui/src, add it there too")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())

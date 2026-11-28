#!/usr/bin/env python3
"""Print the acpmux lib test shards (crates/acpmux/build.rs `test_shards`) that hold the tests a
filter names, comma-separated, for ACPMUX_TEST_SHARD.

    acpmux-test-shards.py cmux_next_      ->  rest

Each in-crate test module of acpmux is declared under `#[cfg(all(test, acpmux_tests_<shard>))]`.
For every source file whose test functions' names contain the filter, this finds that gate: on the
inline `mod tests {` in the file itself, or on the `#[path = "..."]` declaration of the file in
another source file. It prints nothing when a matching test sits under no shard gate it can read
(a plain `#[cfg(test)]`), and the caller then compiles every shard, as an unset
ACPMUX_TEST_SHARD does. It never narrows past a test it cannot place.
"""

from __future__ import annotations

import pathlib
import re
import sys

GATE = re.compile(r"#\[cfg\(all\(test, acpmux_tests_(\w+)(?:, [^\n]*)?\)\)\]")


def shards_for(src: pathlib.Path, needle: str) -> set[str] | None:
    test_fn = re.compile(r"\bfn\s+\w*" + re.escape(needle) + r"\w*\s*\(")
    files = sorted(src.rglob("*.rs"))
    texts = {f: f.read_text(encoding="utf-8", errors="replace") for f in files}
    found: set[str] = set()
    for f, text in texts.items():
        if not test_fn.search(text):
            continue
        # An inline test module: the gate sits in this file, above a `mod ... {` before the test.
        first = test_fn.search(text).start()
        inline = [m for m in GATE.finditer(text) if m.start() < first]
        declared = []
        for other, other_text in texts.items():
            for m in re.finditer(r'#\[path\s*=\s*"([^"]+)"\]', other_text):
                if (other.parent / m.group(1)).resolve() == f.resolve() or (
                    other.parent / other.stem / m.group(1)
                ).resolve() == f.resolve():
                    gates = list(GATE.finditer(other_text[: m.start()]))
                    # The gate is the attribute line right above the #[path] (attributes stack).
                    if gates and other_text[gates[-1].end() : m.start()].strip() == "":
                        declared.append(gates[-1].group(1))
                    else:
                        return None
        # Declared by name (`mod persisted_format_tests;`) in its directory's module file.
        for parent in (f.parent / "mod.rs", f.parent / "lib.rs", f.parent.with_suffix(".rs")):
            if parent == f or parent not in texts:
                continue
            for m in re.finditer(
                r"((?:#\[[^\]]*\]\s*)*)(?:pub(?:\([^)]*\))?\s+)?mod\s+" + re.escape(f.stem) + r"\s*;",
                texts[parent],
            ):
                gate = GATE.search(m.group(1))
                if not gate:
                    return None
                declared.append(gate.group(1))
        if declared:
            found.update(declared)
        elif inline:
            found.update(m.group(1) for m in inline)
        else:
            return None
    return found


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = pathlib.Path(__file__).resolve().parents[2]
    shards = shards_for(root / "cmux-tui/crates/acpmux/src", sys.argv[1])
    if shards:
        print(",".join(sorted(shards)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

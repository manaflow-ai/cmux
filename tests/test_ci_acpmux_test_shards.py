#!/usr/bin/env python3
"""acpmux's in-crate test modules sit in shards, and the daemon gate compiles only the shard it runs.

Leo, 2026-11-23: "always be rethinkig why things are the way they are."

One rustc compiled acpmux's lib with all ~305k lines of its #[cfg(test)] modules and peaked past a
16 GiB machine before codegen. crates/acpmux/build.rs `test_shards` turns ACPMUX_TEST_SHARD
(hub, server, cli, rest) into cfg(acpmux_tests_<shard>), and each test module's gate names its
shard. This checks that:

- every test module declaration in the crate carries a shard gate (a plain #[cfg(test)] test module
  would compile and run in every shard);
- a module's shard is its top-level module's (hub, server, cli; everything else is rest);
- scripts/ci/acpmux-test-shards.py places the gate's cmux_next_ tests, and finds none outside it;
- scripts/ci/cmux-next-daemon-tests.sh sets ACPMUX_TEST_SHARD from it.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "cmux-tui/crates/acpmux/src"
SHARDS = {"hub", "server", "cli"}

TEST_MOD = re.compile(
    r"^\s*#\[cfg\(([^\n]*)\)\]\n((?:\s*#\[[^\]]*\]\n)*)\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*(?:;|\{)",
    re.M,
)


def is_test_module(name: str, attrs: str) -> bool:
    path = re.search(r'path\s*=\s*"([^"]+)"', attrs)
    return (
        name == "tests"
        or name.endswith("_tests")
        or bool(path and re.search(r"(^|/|_)tests?\.rs$", path.group(1)))
    )


def top_module(file: pathlib.Path) -> str:
    rel = file.relative_to(SRC)
    if len(rel.parts) > 1:
        return rel.parts[0]
    return rel.stem


def main() -> int:
    failures: list[str] = []
    gated = 0
    for file in sorted(SRC.rglob("*.rs")):
        if file.parts[len(SRC.parts)] == "bin":
            continue
        if file.name in ("lib.rs", "main.rs"):
            top = None
        else:
            top = top_module(file)
        text = file.read_text(encoding="utf-8")
        for m in TEST_MOD.finditer(text):
            cond, attrs, name = m.groups()
            if not re.match(r"test\b|all\(test\b", cond) or not is_test_module(name, attrs):
                continue
            line = text.count("\n", 0, m.start()) + 1
            where = f"{file.relative_to(ROOT)}:{line}"
            shard = re.match(r"all\(test, acpmux_tests_(\w+)\b", cond)
            if not shard:
                failures.append(f"{where}: test module `{name}` has no shard gate (write #[cfg(all(test, acpmux_tests_<shard>)...)])")
                continue
            gated += 1
            want = (name if top is None else top)
            want = want if want in SHARDS else "rest"
            if shard.group(1) != want:
                failures.append(f"{where}: test module `{name}` is in shard {shard.group(1)}, its top module's is {want}")
    if gated < 1000:
        failures.append(f"only {gated} gated test modules found; the scan no longer reads the crate")

    placed = subprocess.run(
        [sys.executable, str(ROOT / "scripts/ci/acpmux-test-shards.py"), "cmux_next_"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    if not placed or not set(placed.split(",")) <= SHARDS | {"rest"}:
        failures.append(f"acpmux-test-shards.py cmux_next_ printed {placed!r}, not a shard list")

    gate = (ROOT / "scripts/ci/cmux-next-daemon-tests.sh").read_text(encoding="utf-8")
    if "acpmux-test-shards.py cmux_next_" not in gate or "export ACPMUX_TEST_SHARD" not in gate:
        failures.append("cmux-next-daemon-tests.sh no longer sets ACPMUX_TEST_SHARD from acpmux-test-shards.py")

    build = (ROOT / "cmux-tui/crates/acpmux/build.rs").read_text(encoding="utf-8")
    for shard in sorted(SHARDS | {"rest"}):
        if f'"{shard}"' not in build:
            failures.append(f"build.rs test_shards does not name shard {shard}")

    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        return 1
    print(f"OK: {gated} acpmux test modules gated by shard; the daemon gate compiles {placed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

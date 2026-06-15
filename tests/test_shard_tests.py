#!/usr/bin/env python3
"""Behavioral guard for scripts/ci/shard_tests.py.

These cases pin the sharding contract that the macOS ``tests-shard`` matrix
depends on and that a source grep cannot prove:

* shard at the class/suite level (so each shard passes ~hundreds, not
  ~thousands, of ``-only-testing`` arguments — the >1000-argument list made
  ``xcodebuild test-without-building`` hang until the job timeout);
* group ``@Test(arguments:)`` parameterized swift-testing cases under their
  enclosing suite instead of dropping their non-identifier leaf;
* tolerate both ``Target/Class/method`` and ``Class/method`` enumeration
  formats, always emitting a ``Target/Class`` selector;
* keep the shards a disjoint partition whose union is the whole suite.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "shard_tests.py"

_spec = importlib.util.spec_from_file_location("shard_tests", SCRIPT)
shard_tests = importlib.util.module_from_spec(_spec)
assert _spec and _spec.loader
_spec.loader.exec_module(shard_tests)


def _enum_json(identifiers: list[str], noise: list[str]) -> dict:
    """Mimic the nested shape of xcodebuild -enumerate-tests json output."""
    return {
        "errors": list(noise),
        "values": [{"testIdentifier": ident} for ident in identifiers],
    }


def _run(payload: dict, *args: str) -> subprocess.CompletedProcess:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(payload, handle)
        path = handle.name
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--input", path, *args],
        capture_output=True,
        text=True,
    )


def _shard_lines(payload: dict, index: int, total: int, prefix: str = "cmuxTests") -> list[str]:
    result = _run(
        payload,
        "--shard-index",
        str(index),
        "--shard-total",
        str(total),
        "--target-prefix",
        prefix,
    )
    assert result.returncode == 0, f"shard {index}/{total} failed: {result.stderr}"
    return [line for line in result.stdout.splitlines() if line]


FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"ok - {name}")
    else:
        FAILURES.append(f"{name}: {detail}")
        print(f"FAIL - {name}: {detail}")


def test_unit_extraction_three_part() -> None:
    units, counts = shard_tests.extract_units(
        _enum_json(
            [
                "cmuxTests/AlphaTests/testOne",
                "cmuxTests/AlphaTests/testTwo",
                "cmuxTests/BetaSuite/caseOne",
                "cmuxTests/BetaSuite/paramCase(value:)",
                "cmuxTests/GammaTests/testThree",
            ],
            noise=[],
        ),
        target_prefix="cmuxTests",
    )
    check(
        "three-part identifiers collapse to class/suite units",
        units == ["cmuxTests/AlphaTests", "cmuxTests/BetaSuite", "cmuxTests/GammaTests"],
        str(units),
    )
    check(
        "parameterized swift-testing case grouped under its suite (not dropped)",
        counts.get("cmuxTests/BetaSuite") == 2,
        str(counts),
    )


def test_unit_extraction_two_part() -> None:
    units, _ = shard_tests.extract_units(
        _enum_json(
            ["AlphaTests/testOne", "BetaSuite/paramCase(value:)"],
            noise=[],
        ),
        target_prefix="cmuxTests",
    )
    check(
        "two-part identifiers get the target prefix re-applied",
        units == ["cmuxTests/AlphaTests", "cmuxTests/BetaSuite"],
        str(units),
    )


def test_noise_is_ignored() -> None:
    units, _ = shard_tests.extract_units(
        _enum_json(
            ["cmuxTests/AlphaTests/testOne"],
            noise=[
                "cmuxTests",  # bare target component
                "/Users/runner/work/cmux/cmux/file.swift",  # path
                "No system proxy is mirrored",  # swift-testing display name
                "",  # empty
            ],
        ),
        target_prefix="cmuxTests",
    )
    check(
        "non-identifier strings are ignored",
        units == ["cmuxTests/AlphaTests"],
        str(units),
    )


def test_shards_partition_the_suite() -> None:
    identifiers = [
        f"cmuxTests/Class{n:03d}Tests/test{m}"
        for n in range(50)
        for m in range(3)
    ]
    payload = _enum_json(identifiers, noise=[])

    total = 4
    all_units, _ = shard_tests.extract_units(payload, target_prefix="cmuxTests")

    seen: list[str] = []
    for index in range(1, total + 1):
        seen.extend(_shard_lines(payload, index, total))

    check(
        "shards are pairwise disjoint",
        len(seen) == len(set(seen)),
        f"{len(seen)} lines, {len(set(seen))} unique",
    )
    check(
        "union of shards equals the whole suite",
        sorted(seen) == all_units,
        f"{len(seen)} vs {len(all_units)} units",
    )

    # No shard should be wildly larger than another (round-robin balance).
    sizes = [len(_shard_lines(payload, i, total)) for i in range(1, total + 1)]
    check(
        "round-robin keeps shard sizes balanced",
        max(sizes) - min(sizes) <= 1,
        str(sizes),
    )


def test_print_count_reports_units() -> None:
    payload = _enum_json(
        [
            "cmuxTests/AlphaTests/testOne",
            "cmuxTests/AlphaTests/testTwo",
            "cmuxTests/BetaSuite/caseOne",
        ],
        noise=[],
    )
    result = _run(
        payload,
        "--shard-index",
        "1",
        "--shard-total",
        "4",
        "--target-prefix",
        "cmuxTests",
        "--print-count",
    )
    check(
        "--print-count prints the unique class/suite count",
        result.returncode == 0 and result.stdout.strip() == "2",
        f"rc={result.returncode} out={result.stdout!r}",
    )


def test_empty_enumeration_fails_loudly() -> None:
    result = _run(
        _enum_json([], noise=["cmuxTests"]),
        "--shard-index",
        "1",
        "--shard-total",
        "4",
        "--target-prefix",
        "cmuxTests",
    )
    check(
        "empty enumeration exits non-zero instead of silently selecting nothing",
        result.returncode != 0,
        f"rc={result.returncode}",
    )


def main() -> int:
    test_unit_extraction_three_part()
    test_unit_extraction_two_part()
    test_noise_is_ignored()
    test_shards_partition_the_suite()
    test_print_count_reports_units()
    test_empty_enumeration_fails_loudly()
    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed", file=sys.stderr)
        return 1
    print("\nall shard_tests.py checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

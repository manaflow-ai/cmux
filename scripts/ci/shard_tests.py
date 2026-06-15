#!/usr/bin/env python3
"""Partition the xcodebuild flat test enumeration into balanced shard subsets.

Reads the JSON produced by:

    xcodebuild ... -enumerate-tests -test-enumeration-style flat \
      -test-enumeration-format json \
      -test-enumeration-output-path <file> test-without-building

and prints the *class/suite* identifiers assigned to one shard, one per line.
The caller turns each line into an ``-only-testing:<id>`` argument.

Why shard at the class/suite level instead of per individual test:

``xcodebuild test-without-building`` hangs — it produces no output and runs no
tests until the job timeout — when handed on the order of a thousand
``-only-testing:`` arguments. The per-test slice of this suite is ~1100
selectors, and every shard timed out at 900s before launching a single test
(while the full suite, run with *no* ``-only-testing`` arguments, and the
focused regression gates, run with a handful, both work). Selecting whole
classes/suites keeps each shard's argument list to ~115 selectors, which
xcodebuild plans and launches normally.

Class/suite granularity also makes coverage robust: a ``@Test(arguments:)``
parameterized swift-testing case enumerates with a non-identifier leaf such as
``testFoo(value:)``. Selecting the enclosing ``@Suite`` runs every case without
ever having to parse — and possibly drop — that leaf. Class-level
``-only-testing:cmuxTests/SomeSuite`` selectors drive swift-testing ``@Suite``
types as well as XCTest classes.

Partitioning is deterministic: class/suite identifiers are sorted, then assigned
round-robin by index, so the union of all shards is exactly the full suite with
no gaps or overlaps regardless of enumeration order. Sorting groups same-prefix
(often same-subsystem, similarly expensive app-host) classes together and
round-robin then spreads those neighbours across distinct shards, which balances
the slow ``AppDelegateShortcutRoutingTests``-style classes without per-test
timing data.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any


def _collect(node: Any, out: list[str]) -> None:
    """Recursively gather every string in the enumeration JSON."""
    if isinstance(node, str):
        out.append(node)
    elif isinstance(node, dict):
        for value in node.values():
            _collect(value, out)
    elif isinstance(node, list):
        for item in node:
            _collect(item, out)


def _is_clean_component(text: str) -> bool:
    """True for a class/suite/function name (alnum plus ``_`` and a ``()`` suffix)."""
    return bool(text) and text.replace("()", "").replace("_", "").isalnum()


def unit_of(ident: str, target_prefix: str | None) -> str | None:
    """Map a flat test identifier to its class/suite ``-only-testing`` selector.

    Flat identifiers look like ``[Target/]Class/method`` (XCTest) or
    ``[Target/]Suite/case`` (swift-testing), where the ``method``/``case`` leaf
    may be a parameterized token such as ``testFoo(value:)`` that is not itself
    a clean identifier. Only the component *before* the leaf (the class/suite)
    is inspected, so parameterized cases are grouped under their suite rather
    than dropped.

    Returns ``Target/Class`` with the target prefix re-applied, or ``None`` when
    the string is not a test identifier (target name, file path, diagnostic).
    """
    if "/" not in ident:
        return None
    parts = ident.split("/")
    # Drop a leading test-target component when the enumeration includes one.
    # Different Xcode versions emit "Target/Class/method" or "Class/method";
    # both must collapse to the same "Target/Class" selector.
    if target_prefix and parts and parts[0] == target_prefix:
        parts = parts[1:]
    # A real flat identifier has at least "Class/method". A single remaining
    # component is target/file/diagnostic noise (or a bare suite node, which
    # also surfaces through its cases), so it is not a shardable unit.
    if len(parts) < 2:
        return None
    unit = parts[0]
    if not _is_clean_component(unit):
        return None
    return f"{target_prefix}/{unit}" if target_prefix else unit


def extract_units(data: Any, target_prefix: str | None) -> tuple[list[str], dict[str, int]]:
    """Return (sorted unique class/suite identifiers, per-unit enumerated-test count)."""
    raw: list[str] = []
    _collect(data, raw)
    counts: dict[str, int] = {}
    for ident in raw:
        unit = unit_of(ident, target_prefix)
        if unit is not None:
            counts[unit] = counts.get(unit, 0) + 1
    return sorted(counts), counts


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="enumerate-tests JSON path")
    parser.add_argument("--shard-index", type=int, required=True, help="1-based shard index")
    parser.add_argument("--shard-total", type=int, required=True, help="total shard count")
    parser.add_argument(
        "--target-prefix",
        default=None,
        help="test target component to strip/re-apply (e.g. cmuxTests)",
    )
    parser.add_argument(
        "--print-count",
        action="store_true",
        help="print the total class/suite count instead of a shard",
    )
    args = parser.parse_args(argv)

    if args.shard_total < 1 or not (1 <= args.shard_index <= args.shard_total):
        print(f"invalid shard {args.shard_index}/{args.shard_total}", file=sys.stderr)
        return 2

    with open(args.input, encoding="utf-8") as handle:
        data = json.load(handle)

    units, counts = extract_units(data, args.target_prefix)
    if not units:
        print("ERROR: no test class/suite identifiers extracted from enumeration", file=sys.stderr)
        return 2

    total_tests = sum(counts.values())
    if args.print_count:
        print(len(units))
        return 0

    index = args.shard_index - 1
    shard = [unit for n, unit in enumerate(units) if n % args.shard_total == index]
    shard_tests = sum(counts[unit] for unit in shard)
    sample = ", ".join(units[:3])
    print(
        f"shard {args.shard_index}/{args.shard_total}: "
        f"{len(shard)} of {len(units)} classes "
        f"(~{shard_tests} of {total_tests} enumerated tests); sample: {sample}",
        file=sys.stderr,
    )
    for unit in shard:
        print(unit)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

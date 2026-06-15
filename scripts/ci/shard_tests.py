#!/usr/bin/env python3
"""Partition the xcodebuild flat test enumeration into balanced shard subsets.

Reads the JSON produced by:

    xcodebuild ... -enumerate-tests -test-enumeration-style flat \
      -test-enumeration-format json \
      -test-enumeration-output-path <file> test-without-building

and prints the test identifiers assigned to one shard, one per line. The caller
turns each line into an ``-only-testing:<id>`` argument.

Partitioning is deterministic: identifiers are sorted, then assigned
round-robin by index, so the union of all shards is exactly the full suite with
no gaps or overlaps regardless of enumeration order. Sorting groups a class's
methods together, and round-robin then spreads those consecutive (often
similarly expensive app-host) methods evenly across shards, which balances the
slow ``AppDelegateShortcutRoutingTests``-style classes without needing per-test
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


def _looks_like_identifier(text: str) -> bool:
    """A flat test id is "Class/method" or "Target/Class/method" — no spaces."""
    if "/" not in text or any(c.isspace() for c in text):
        return False
    parts = text.split("/")
    if not (2 <= len(parts) <= 3):
        return False
    # Each component is an identifier, optionally with a "()" suffix on the
    # leaf (swift-testing renders cases that way in some Xcode versions).
    return all(part.replace("()", "").replace("_", "").isalnum() for part in parts if part)


def extract_identifiers(data: Any) -> list[str]:
    """Return sorted, de-duplicated flat test identifiers."""
    raw: list[str] = []
    _collect(data, raw)
    cleaned = {ident for ident in raw if _looks_like_identifier(ident)}
    return sorted(cleaned)


def normalize(identifiers: list[str], target_prefix: str | None) -> list[str]:
    """Ensure each identifier carries the test-target prefix -only-testing wants."""
    if not target_prefix:
        return identifiers
    prefix = target_prefix.rstrip("/") + "/"
    normalized = []
    for ident in identifiers:
        # Flat identifiers are "Target/Class/method" (2 slashes). If the target
        # is missing ("Class/method", 1 slash), prepend it.
        if ident.count("/") < 2 and not ident.startswith(prefix):
            normalized.append(prefix + ident)
        else:
            normalized.append(ident)
    return normalized


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="enumerate-tests JSON path")
    parser.add_argument("--shard-index", type=int, required=True, help="1-based shard index")
    parser.add_argument("--shard-total", type=int, required=True, help="total shard count")
    parser.add_argument(
        "--target-prefix",
        default=None,
        help="test target to prepend when an identifier omits it (e.g. cmuxTests)",
    )
    parser.add_argument(
        "--print-count",
        action="store_true",
        help="print the total identifier count instead of a shard",
    )
    args = parser.parse_args(argv)

    if args.shard_total < 1 or not (1 <= args.shard_index <= args.shard_total):
        print(f"invalid shard {args.shard_index}/{args.shard_total}", file=sys.stderr)
        return 2

    with open(args.input, encoding="utf-8") as handle:
        data = json.load(handle)

    identifiers = normalize(extract_identifiers(data), args.target_prefix)
    if not identifiers:
        print("ERROR: no test identifiers extracted from enumeration", file=sys.stderr)
        return 2

    if args.print_count:
        print(len(identifiers))
        return 0

    index = args.shard_index - 1
    shard = [t for n, t in enumerate(identifiers) if n % args.shard_total == index]
    print(
        f"shard {args.shard_index}/{args.shard_total}: "
        f"{len(shard)} of {len(identifiers)} tests",
        file=sys.stderr,
    )
    for ident in shard:
        print(ident)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

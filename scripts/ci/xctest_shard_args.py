#!/usr/bin/env python3
"""Emit stable xcodebuild -only-testing arguments for a cmuxTests shard."""

from __future__ import annotations

import argparse
import hashlib
import re
import shlex
import sys
from pathlib import Path


CLASS_RE = re.compile(r"\b(?:final\s+)?class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*XCTestCase\b")
ATTRIBUTE_ARGS = r"(?:\((?:[^()]|\([^()]*\))*\))?"
SWIFT_ATTRIBUTE = rf"@[A-Za-z_][A-Za-z0-9_]*{ATTRIBUTE_ARGS}"
TYPE_MODIFIER = r"(?:public|private|internal|fileprivate|open|final)"
TYPE_DECL_RE = re.compile(
    rf"""
    (?:
        (?:{SWIFT_ATTRIBUTE}|{TYPE_MODIFIER})
        \s+
    )*
    (?:struct|class|actor|enum)\s+([A-Za-z_][A-Za-z0-9_]*)\b
    """,
    re.VERBOSE,
)
EXTENSION_RE = re.compile(r"\bextension\s+([A-Za-z_][A-Za-z0-9_]*)\b")
SUITE_RE = re.compile(
    rf"""
    @Suite{ATTRIBUTE_ARGS}
    (?:
        \s+
        (?:
            {SWIFT_ATTRIBUTE}
            |
            {TYPE_MODIFIER}
        )
    )*
    \s+
    (?:struct|class)\s+([A-Za-z_][A-Za-z0-9_]*)\b
    """,
    re.VERBOSE,
)
TEST_METHOD_RE = re.compile(r"\bfunc\s+(test[A-Za-z0-9_]+)\s*\(")
SWIFT_TEST_ATTRIBUTE_RE = re.compile(r"@Test\b")


def find_matching_brace(source: str, open_index: int) -> int:
    depth = 0
    index = open_index
    while index < len(source):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return len(source)


def discover_xctest_identifiers(tests_dir: Path, module: str) -> list[str]:
    identifiers: list[str] = []
    for path in sorted(tests_dir.glob("*.swift")):
        source = path.read_text(encoding="utf-8")
        for match in SUITE_RE.finditer(source):
            identifiers.append(f"{module}/{match.group(1)}")
        for match in TYPE_DECL_RE.finditer(source):
            type_name = match.group(1)
            open_index = source.find("{", match.end())
            if open_index == -1:
                continue
            close_index = find_matching_brace(source, open_index)
            body = source[open_index:close_index]
            if SWIFT_TEST_ATTRIBUTE_RE.search(body):
                identifiers.append(f"{module}/{type_name}")
        for match in EXTENSION_RE.finditer(source):
            type_name = match.group(1)
            open_index = source.find("{", match.end())
            if open_index == -1:
                continue
            close_index = find_matching_brace(source, open_index)
            body = source[open_index:close_index]
            if SWIFT_TEST_ATTRIBUTE_RE.search(body):
                identifiers.append(f"{module}/{type_name}")
            methods = sorted({method.group(1) for method in TEST_METHOD_RE.finditer(body)})
            identifiers.extend(f"{module}/{type_name}/{method}" for method in methods)
        for match in CLASS_RE.finditer(source):
            class_name = match.group(1)
            open_index = source.find("{", match.end())
            if open_index == -1:
                continue
            close_index = find_matching_brace(source, open_index)
            body = source[open_index:close_index]
            methods = sorted({method.group(1) for method in TEST_METHOD_RE.finditer(body)})
            if methods:
                identifiers.extend(f"{module}/{class_name}/{method}" for method in methods)
            else:
                identifiers.append(f"{module}/{class_name}")
    return sorted(set(identifiers))


def shard_for(identifier: str, shard_count: int) -> int:
    digest = hashlib.sha256(identifier.encode("utf-8")).digest()
    return int.from_bytes(digest[:8], byteorder="big") % shard_count


def parse_excluded(raw_values: list[str]) -> set[str]:
    excluded: set[str] = set()
    for raw in raw_values:
        value = raw.removeprefix("-only-testing:")
        if value:
            excluded.add(value)
    return excluded


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tests-dir", type=Path, default=Path("cmuxTests"))
    parser.add_argument("--module", default="cmuxTests")
    parser.add_argument("--shard-index", type=int, required=True)
    parser.add_argument("--shard-count", type=int, required=True)
    parser.add_argument("--exclude", action="append", default=[])
    parser.add_argument("--summary", action="store_true")
    args = parser.parse_args()

    if args.shard_count < 1:
        print("--shard-count must be positive", file=sys.stderr)
        return 2
    if args.shard_index < 0 or args.shard_index >= args.shard_count:
        print("--shard-index must be in [0, shard-count)", file=sys.stderr)
        return 2

    identifiers = discover_xctest_identifiers(args.tests_dir, args.module)
    excluded = parse_excluded(args.exclude)
    selected = [
        identifier
        for identifier in identifiers
        if identifier not in excluded and shard_for(identifier, args.shard_count) == args.shard_index
    ]

    if args.summary:
        print(f"discovered={len(identifiers)} selected={len(selected)} excluded={len(excluded)}", file=sys.stderr)

    if not selected:
        print(
            f"No XCTest identifiers selected for shard {args.shard_index}/{args.shard_count}",
            file=sys.stderr,
        )
        return 1

    print(" ".join(shlex.quote(f"-only-testing:{identifier}") for identifier in selected))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

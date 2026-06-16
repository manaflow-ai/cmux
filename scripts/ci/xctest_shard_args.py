#!/usr/bin/env python3
"""Emit stable xcodebuild -only-testing arguments for a cmuxTests shard."""

from __future__ import annotations

import argparse
import hashlib
import re
import shlex
import sys
from pathlib import Path


ATTRIBUTE_ARGS = r"(?:\((?:[^()]|\([^()]*\))*\))?"
SWIFT_ATTRIBUTE = rf"@[A-Za-z_][A-Za-z0-9_]*{ATTRIBUTE_ARGS}"
TYPE_MODIFIER = r"(?:public|private|internal|fileprivate|open|final)"
CLASS_RE = re.compile(
    rf"^[ \t]*(?:(?:{SWIFT_ATTRIBUTE}|{TYPE_MODIFIER})[ \t]+)*class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*XCTestCase\b",
    re.MULTILINE,
)
TYPE_DECL_RE = re.compile(
    rf"""
    ^[ \t]*
    (?:(?:{SWIFT_ATTRIBUTE}|{TYPE_MODIFIER})[ \t]+)*
    (?:struct|class|actor|enum)\s+([A-Za-z_][A-Za-z0-9_]*)\b
    """,
    re.VERBOSE | re.MULTILINE,
)
EXTENSION_RE = re.compile(r"^[ \t]*extension\s+([A-Za-z_][A-Za-z0-9_]*)\b", re.MULTILINE)
SUITE_RE = re.compile(
    rf"""
    ^[ \t]*@Suite{ATTRIBUTE_ARGS}
    (?:
        [ \t]*(?:\n[ \t]*)+
        {SWIFT_ATTRIBUTE}
    )*
    [ \t]*(?:\n[ \t]*)*
    (?:{TYPE_MODIFIER}[ \t]+)*
    (?:struct|class)\s+([A-Za-z_][A-Za-z0-9_]*)\b
    """,
    re.VERBOSE | re.MULTILINE,
)
TEST_METHOD_RE = re.compile(r"\bfunc\s+(test[A-Za-z0-9_]+)\s*\(")
SWIFT_TEST_ATTRIBUTE_RE = re.compile(r"@Test\b")


def _mask_range(masked: list[str], start: int, end: int) -> None:
    for index in range(start, min(end, len(masked))):
        if masked[index] != "\n":
            masked[index] = " "


def _string_literal_start(source: str, index: int) -> tuple[int, int, bool] | None:
    if source[index] == '"':
        hash_count = 0
        quote_index = index
    elif source[index] == "#":
        cursor = index
        while cursor < len(source) and source[cursor] == "#":
            cursor += 1
        if cursor >= len(source) or source[cursor] != '"':
            return None
        hash_count = cursor - index
        quote_index = cursor
    else:
        return None
    return hash_count, quote_index, source.startswith('"""', quote_index)


def _consume_string_literal(source: str, hash_count: int, quote_index: int, multiline: bool) -> int:
    cursor = quote_index + (3 if multiline else 1)
    delimiter_hashes = "#" * hash_count
    if multiline:
        while cursor < len(source):
            if source.startswith('"""' + delimiter_hashes, cursor):
                return cursor + 3 + hash_count
            cursor += 1
        return len(source)

    while cursor < len(source):
        if hash_count == 0 and source[cursor] == "\\":
            cursor += 2
            continue
        if source[cursor] == '"' and source.startswith(delimiter_hashes, cursor + 1):
            return cursor + 1 + hash_count
        cursor += 1
    return len(source)


def mask_swift_non_code(source: str) -> str:
    """Return source with Swift comments and string literals replaced by spaces."""
    masked = list(source)
    index = 0
    while index < len(source):
        if source.startswith("//", index):
            end = source.find("\n", index + 2)
            if end == -1:
                end = len(source)
            _mask_range(masked, index, end)
            index = end
            continue

        if source.startswith("/*", index):
            depth = 1
            cursor = index + 2
            while cursor < len(source) and depth:
                if source.startswith("/*", cursor):
                    depth += 1
                    cursor += 2
                elif source.startswith("*/", cursor):
                    depth -= 1
                    cursor += 2
                else:
                    cursor += 1
            _mask_range(masked, index, cursor)
            index = cursor
            continue

        string_start = _string_literal_start(source, index)
        if string_start is not None:
            hash_count, quote_index, multiline = string_start
            end = _consume_string_literal(source, hash_count, quote_index, multiline)
            _mask_range(masked, index, end)
            index = end
            continue

        index += 1
    return "".join(masked)


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
    class_fallbacks: set[str] = set()
    classes_with_method_identifiers: set[str] = set()
    for path in sorted(tests_dir.glob("*.swift")):
        source = path.read_text(encoding="utf-8")
        masked_source = mask_swift_non_code(source)
        for match in SUITE_RE.finditer(masked_source):
            identifiers.append(f"{module}/{match.group(1)}")
        for match in TYPE_DECL_RE.finditer(masked_source):
            type_name = match.group(1)
            open_index = masked_source.find("{", match.end())
            if open_index == -1:
                continue
            close_index = find_matching_brace(masked_source, open_index)
            body = masked_source[open_index:close_index]
            if SWIFT_TEST_ATTRIBUTE_RE.search(body):
                identifiers.append(f"{module}/{type_name}")
        for match in EXTENSION_RE.finditer(masked_source):
            type_name = match.group(1)
            open_index = masked_source.find("{", match.end())
            if open_index == -1:
                continue
            close_index = find_matching_brace(masked_source, open_index)
            body = masked_source[open_index:close_index]
            if SWIFT_TEST_ATTRIBUTE_RE.search(body):
                identifiers.append(f"{module}/{type_name}")
            methods = sorted({method.group(1) for method in TEST_METHOD_RE.finditer(body)})
            if methods:
                classes_with_method_identifiers.add(type_name)
            identifiers.extend(f"{module}/{type_name}/{method}" for method in methods)
        for match in CLASS_RE.finditer(masked_source):
            class_name = match.group(1)
            open_index = masked_source.find("{", match.end())
            if open_index == -1:
                continue
            close_index = find_matching_brace(masked_source, open_index)
            body = masked_source[open_index:close_index]
            methods = sorted({method.group(1) for method in TEST_METHOD_RE.finditer(body)})
            if methods:
                classes_with_method_identifiers.add(class_name)
                identifiers.extend(f"{module}/{class_name}/{method}" for method in methods)
            else:
                class_fallbacks.add(class_name)
    identifiers.extend(
        f"{module}/{class_name}"
        for class_name in sorted(class_fallbacks - classes_with_method_identifiers)
    )
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

#!/usr/bin/env python3
"""The Swift copies of the design scale agree with schemas/design-scale/design-scale.json.

Leo, 2026-11-22: "we need to have a proper way to do ui so that when anybody wants to adjust or customize things
like this, it is done easily properly". The web reads the scale through a generator
(webviews/scripts/pages/gen-design-scale.mjs); Swift's copies are hand-written (no committed generated Swift:
scripts/ci/generated-files.json), so this check reads them. The table is data:
schemas/design-scale/swift-parity.json pairs each token with the Swift symbol that carries its value.

Fails when:
  - a pair's Swift value differs from the schema's (change both together; the check pins no number);
  - a pair's symbol cannot be read (a renamed symbol, or a value that is no longer a literal or an alias of one);
  - a `static let` in CmuxNextDesignTokens/DesignTokens.swift has no pair (every constant there is a copy of
    the scale);
  - a drift entry is no longer true: the two values are equal now, or differ from the ones recorded. A drift
    entry can only be removed (fix the value, delete the entry), so the list is a ratchet.
Prints "N mapped, M equal, K drifting, U unmapped" (unmapped: the Swift values listed in the JSON's `unmapped`,
which are computed, not literals).

    python3 -I scripts/cmux-next/check-design-scale-parity.py [--root DIR] [--table FILE]

Tests: scripts/cmux-next/tests/test_design_system_guards.py.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SCALE = "schemas/design-scale/design-scale.json"
TABLE = "schemas/design-scale/swift-parity.json"
TOKENS_FILE = "CmuxNextDesignTokens/DesignTokens.swift"
NUMBER = r"-?\d+(?:\.\d+)?"
MODIFIERS = r"(?:(?:@\w+|public|internal|private|fileprivate|nonisolated|static|final)\s+)*"
DECLARATION = r"^[ \t]*" + MODIFIERS + r"(?:let|var)\s+{name}\s*(?::\s*[\w.]+\s*)?=\s*(?P<value>[^\n]+?)\s*(?://[^\n]*)?$"
TOKENS_CONSTANT = re.compile(r"^[ \t]*" + MODIFIERS + r"static\s+" + MODIFIERS + r"let\s+(\w+)\s*:", re.M)


class Unreadable(Exception):
    pass


def schema_value(data: dict, path: str):
    """The value at `path` (`a.b[name=x].c`) in the design scale, or KeyError."""
    node = data
    for part in path.split("."):
        match = re.fullmatch(r"(\w+)(?:\[(\w+)=([\w-]+)\])?", part)
        if not match:
            raise KeyError(path)
        key, field, want = match.groups()
        node = node[key]
        if field:
            found = [item for item in node if str(item.get(field)) == want]
            if len(found) != 1:
                raise KeyError(path)
            node = found[0]
    return node


def read(value, how: str) -> float:
    if how == "px":
        return float(value)
    if how == "percent":
        return float(value) / 100
    if how == "blurPx":
        match = re.search(r"blur\(\s*(" + NUMBER + r")px\s*\)", str(value))
    elif how == "fallbackPx":
        match = re.search(r",\s*(" + NUMBER + r")px\s*\)\s*$", str(value))
    elif how.startswith("nth:"):
        numbers = re.findall(NUMBER, str(value))
        index = int(how[4:])
        if index >= len(numbers):
            raise Unreadable(f"{value!r} has no number {index}")
        return float(numbers[index])
    else:
        raise Unreadable(f"unknown read {how!r}")
    if not match:
        raise Unreadable(f"{value!r} is not {how}")
    return float(match.group(1))


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def swift_value(root: str, swift_root: str, symbol: str, depth: int = 0) -> float:
    """The number `FILE:NAME` or `FILE:NAME.field` holds, following a `DesignTokens.X` alias."""
    file, _, name = symbol.partition(":")
    path = os.path.join(root, swift_root, file)
    if not os.path.exists(path):
        raise FileNotFoundError(symbol)
    name, _, field = name.partition(".")
    with open(path, encoding="utf-8") as handle:
        code = strip_comments(handle.read())
    found = list(re.finditer(DECLARATION.format(name=re.escape(name)), code, re.M))
    if not found:
        raise FileNotFoundError(symbol)
    if len(found) > 1:
        raise Unreadable(f"{symbol}: {len(found)} declarations named {name}")
    value = found[0].group("value").strip()
    if field:
        match = re.search(r"\b" + re.escape(field) + r"\s*:\s*(" + NUMBER + r")\s*[,)]", value)
        if not match:
            raise Unreadable(f"{symbol}: no literal `{field}:` in {value}")
        return float(match.group(1))
    if re.fullmatch(NUMBER, value):
        return float(value)
    alias = re.fullmatch(r"DesignTokens\.(\w+)", value)
    if alias and depth < 3:
        return swift_value(root, swift_root, f"{TOKENS_FILE}:{alias.group(1)}", depth + 1)
    raise Unreadable(f"{symbol}: `{value}` is not a literal or a DesignTokens alias")


def same(a: float, b: float) -> bool:
    return abs(a - b) < 1e-9


def check(root: str, table_path: str) -> tuple[list[str], str]:
    with open(os.path.join(root, SCALE), encoding="utf-8") as handle:
        scale = json.load(handle)
    with open(table_path, encoding="utf-8") as handle:
        table = json.load(handle)
    swift_root = table["swiftRoot"]
    drift = {entry["swift"]: entry for entry in table.get("drift", [])}
    errors: list[str] = []
    mapped = equal = drifting = 0
    seen_drift = set()
    for pair in table["pairs"]:
        symbol = pair["swift"]
        label = f"{pair['schema']} <-> {symbol}"
        try:
            want = read(schema_value(scale, pair["schema"]), pair["read"])
            has_schema = True
        except KeyError:
            has_schema = False
        try:
            got = swift_value(root, swift_root, symbol)
            has_swift = True
        except FileNotFoundError:
            has_swift = False
        except Unreadable as error:
            errors.append(f"unreadable: {label}: {error}")
            continue
        except (ValueError, Unreadable) as error:  # pragma: no cover
            errors.append(f"unreadable: {label}: {error}")
            continue
        if not has_schema or not has_swift:
            if pair.get("optional") and not has_schema and not has_swift:
                continue
            side = "the schema has no" if not has_schema else "Swift has no"
            errors.append(f"missing: {label}: {side} {pair['schema'] if not has_schema else symbol}")
            continue
        mapped += 1
        entry = drift.get(symbol)
        if entry:
            seen_drift.add(symbol)
            if same(want, got):
                errors.append(f"drift fixed: {label} agree at {got:g} now; delete its drift entry in {TABLE}")
            elif not (same(entry["schemaValue"], want) and same(entry["swiftValue"], got)):
                errors.append(f"drift changed: {label} is schema {want:g} / Swift {got:g}, recorded "
                              f"{entry['schemaValue']:g} / {entry['swiftValue']:g}; fix the pair or update the entry")
            else:
                drifting += 1
            continue
        if same(want, got):
            equal += 1
        else:
            errors.append(f"differs: {label}: schema {want:g}, Swift {got:g}; change them together")
    for symbol in sorted(set(drift) - seen_drift):
        if not any(pair["swift"] == symbol for pair in table["pairs"]):
            errors.append(f"drift entry with no pair: {symbol}")
    tokens_path = os.path.join(root, swift_root, TOKENS_FILE)
    with open(tokens_path, encoding="utf-8") as handle:
        constants = TOKENS_CONSTANT.findall(strip_comments(handle.read()))
    paired = {pair["swift"].partition(":")[2] for pair in table["pairs"]
              if pair["swift"].startswith(TOKENS_FILE + ":")}
    for name in constants:
        if name not in paired:
            errors.append(f"unmapped DesignTokens.{name}: add its design-scale pair to {TABLE}")
    summary = (f"{mapped} mapped, {equal} equal, {drifting} drifting, {len(table.get('unmapped', []))} unmapped")
    return errors, summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=REPO)
    parser.add_argument("--table", help=f"the pairs (default ROOT/{TABLE})")
    args = parser.parse_args(argv)
    errors, summary = check(args.root, args.table or os.path.join(args.root, TABLE))
    for error in errors:
        print(f"check-design-scale-parity: {error}", file=sys.stderr)
    print(f"check-design-scale-parity: {summary}" + (f", {len(errors)} errors" if errors else ""))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())

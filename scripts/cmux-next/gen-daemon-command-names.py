#!/usr/bin/env python3
"""Generates the app's typed daemon command names from the daemon's own tables.

The daemon numbers every request's `daemon.request` slice by its method id
(cmux-tui/crates/cmux-tui-core/src/server/request_spans.rs, `RequestMethod`):
a `Command`'s row in `COMMANDS` (server/command_names.rs), `RESOURCE_BASE`
plus a v2 resource operation's declaration index (resource.rs,
`ResourceOperation`; spelled in resource/wire_name.rs), or `ROUTED_BASE` plus
the `MethodClass` of a name neither table has, by its prefix
(`RequestMethod::routed`). The app's `daemon.request` slice (p09-observability
task 025) carries the same id, so one table names both sides of a request in a
trace.

This writes two Swift files, one `switch` over a 64-bit FNV-1a hash of each
spelling (aliases included) per table, and the routed prefixes:

    Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/DaemonCommandName+Commands.swift
    Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/DaemonCommandName+Resources.swift

The Rust test `request_spans_generated_swift_names_match_the_daemon`
(server/request_spans_tests.rs) reads both files back and fails when a row,
id, spelling or prefix differs from the daemon's, so a table change that
skips this script fails the daemon's own `cargo test`.

Usage: gen-daemon-command-names.py [--check]
  --check  exit 1 when a generated file differs from what the tables give.
Stdlib only; reads the repository, writes only the two files (never with --check).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "cmux-tui/crates/cmux-tui-core/src"
COMMAND_NAMES = CORE / "server/command_names.rs"
REQUEST_SPANS = CORE / "server/request_spans.rs"
RESOURCE_ENUM = CORE / "resource.rs"
RESOURCE_NAMES = CORE / "resource/wire_name.rs"
OUT_DIR = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection"

FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3
MASK = (1 << 64) - 1

Row = tuple[int, str, list[str]]


def fnv1a(text: str) -> int:
    """`DaemonCommandName.hash(_:)`: 64-bit FNV-1a over the UTF-8 bytes."""
    value = FNV_OFFSET
    for byte in text.encode():
        value = ((value ^ byte) * FNV_PRIME) & MASK
    return value


def fail(message: str) -> None:
    sys.exit(f"gen-daemon-command-names: {message}")


def base(name: str) -> int:
    """request_spans.rs `RequestMethod::<name>`."""
    found = re.search(rf"const {name}: u16 = (0x[0-9A-Fa-f]+|\d+);", REQUEST_SPANS.read_text())
    if not found:
        fail(f"no RequestMethod::{name} in {REQUEST_SPANS}")
    return int(found.group(1), 0)


def method_classes() -> dict[str, int]:
    """Each `MethodClass` variant's discriminant (command_names.rs), in declaration order."""
    enum = re.search(r"pub\(crate\) enum MethodClass \{(.*?)\n\}", COMMAND_NAMES.read_text(), re.S)
    if not enum:
        fail(f"no MethodClass enum in {COMMAND_NAMES}")
    body = "\n".join(line for line in enum.group(1).splitlines() if not line.strip().startswith("//"))
    if "=" in body:
        fail("MethodClass has an explicit discriminant: teach the generator to read it")
    variants = re.findall(r"^\s*([A-Z]\w*)\s*,", body, re.M)
    return {variant: index for index, variant in enumerate(variants)}


def routed() -> tuple[list[tuple[list[str], int]], int]:
    """`RequestMethod::routed`: (prefixes, method id) per guarded arm in order, and the fallback's id."""
    text = REQUEST_SPANS.read_text()
    body = re.search(r"fn routed\(cmd: Option<&str>\) -> Self \{(.*?)\n    \}", text, re.S)
    if not body:
        fail(f"no RequestMethod::routed in {REQUEST_SPANS}")
    classes, routed_base = method_classes(), base("ROUTED_BASE")
    arms = re.findall(r"Some\(cmd\) if (.*?)=>\s*\{?\s*MethodClass::(\w+)", body.group(1), re.S)
    fallback = re.search(r"_ => MethodClass::(\w+)", body.group(1))
    if not arms or not fallback:
        fail("RequestMethod::routed is not `Some(cmd) if cmd.starts_with(..) => class, _ => class`")
    out = []
    for guard, cls in arms:
        prefixes = re.findall(r'cmd\.starts_with\("([^"]+)"\)', guard)
        leftover = re.sub(r'cmd\.starts_with\("[^"]+"\)|\|\||\s', "", guard)
        if not prefixes or leftover:
            fail(f"a routed guard is not a prefix test: {guard.strip()}")
        out.append((prefixes, routed_base + classes[cls]))
    return out, routed_base + classes[fallback.group(1)]


def commands() -> list[Row]:
    """(row, wire name, aliases) for every `command_table!` row, in `COMMANDS` order."""
    text = COMMAND_NAMES.read_text()
    start = text.index("command_table! {")
    table = text[start:text.index("\n}", start)]
    rows = re.findall(r'^\s*([A-Z]\w*) => ((?:"[^"]+"\s*\|?\s*)+), \w+;', table, re.M)
    arms = [line for line in table.splitlines() if "=>" in line and not line.strip().startswith("//")]
    if not rows or len(rows) != len(arms):
        fail(f"read {len(rows)} of the {len(arms)} command_table! rows in {COMMAND_NAMES}: teach the row pattern")
    out = []
    for row, (_variant, spellings) in enumerate(rows):
        names = re.findall(r'"([^"]+)"', spellings)
        out.append((row, names[0], names[1:]))
    return out


def resources() -> list[Row]:
    """(method id, wire name, no aliases) for every `ResourceOperation`, by declaration index."""
    enum = re.search(r"pub enum ResourceOperation \{(.*?)\n\}", RESOURCE_ENUM.read_text(), re.S)
    if not enum:
        fail(f"no ResourceOperation enum in {RESOURCE_ENUM}")
    variants = re.findall(r"^\s*([A-Z]\w*)\s*,", enum.group(1), re.M)
    spelled = dict(re.findall(r'^\s*([A-Z]\w*) => "([^"]+)",', RESOURCE_NAMES.read_text(), re.M))
    missing = [v for v in variants if v not in spelled]
    if missing or len(spelled) != len(variants):
        fail(f"resource tables disagree: unspelled {missing}, {len(spelled)} names for {len(variants)} variants")
    resource_base = base("RESOURCE_BASE")
    return [(resource_base + index, spelled[variant], []) for index, variant in enumerate(variants)]


def header(source: str) -> list[str]:
    return [
        f"// Generated by scripts/cmux-next/gen-daemon-command-names.py from {source}. Do not edit:",
        "// run the script after the daemon's table changes (`--check` says whether it did; the Rust test",
        "// request_spans_generated_swift_names_match_the_daemon fails until it does).",
        "",
        "extension DaemonCommandName {",
    ]


def table(function: str, doc: str, rows: list[Row]) -> list[str]:
    lines = [
        f"    /// {doc}",
        "    /// nil when no spelling has `hash` (the caller still compares the spelling: ``DaemonCommandName/lookup(_:)``).",
        f"    static func {function}(hash: UInt64) -> (id: UInt16, text: StaticString)? {{",
        "        switch hash {",
    ]
    for method, wire, aliases in rows:
        for spelling in [wire, *aliases]:
            lines.append(f'        case 0x{fnv1a(spelling):016X}: return ({method}, "{spelling}")')
    return lines + ["        default: return nil", "        }", "    }"]


def routed_function(arms: list[tuple[list[str], int]], fallback: int) -> list[str]:
    lines = [
        "",
        "    /// The id of a name neither table has (request_spans.rs `RequestMethod::routed`): `ROUTED_BASE` plus the",
        "    /// `MethodClass` of the first prefix `wire` starts with, byte for byte.",
        "    static func routedID(_ wire: String) -> UInt16 {",
        "        let bytes = wire.utf8",
    ]
    for prefixes, method in arms:
        test = " || ".join(f'bytes.starts(with: "{prefix}".utf8)' for prefix in prefixes)
        lines.append(f"        if {test} {{ return 0x{method:04X} }}")
    return lines + [f"        return 0x{fallback:04X}", "    }"]


def outputs() -> dict[Path, str]:
    command_rows, resource_rows = commands(), resources()
    spellings = [s for _, wire, aliases in command_rows + resource_rows for s in [wire, *aliases]]
    hashes = [fnv1a(s) for s in spellings]
    if len(set(spellings)) != len(spellings):
        fail("a spelling is in both tables")
    if len(set(hashes)) != len(hashes):
        fail("two spellings share a hash: change the hash before generating")
    arms, fallback = routed()
    commands_file = header("cmux-tui-core/src/server/command_names.rs and request_spans.rs") + table(
        "command", "The daemon `Command` spelled with this hash: its row in `COMMANDS` (command_names.rs).",
        command_rows) + routed_function(arms, fallback) + ["}", ""]
    resources_file = header("cmux-tui-core/src/resource.rs and resource/wire_name.rs") + table(
        "resource", "The v2 resource operation spelled with this hash: `RESOURCE_BASE` plus its declaration index.",
        resource_rows) + ["}", ""]
    return {
        OUT_DIR / "DaemonCommandName+Commands.swift": "\n".join(commands_file),
        OUT_DIR / "DaemonCommandName+Resources.swift": "\n".join(resources_file),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="exit 1 when a generated file is stale")
    args = parser.parse_args()
    stale = []
    for path, text in outputs().items():
        current = path.read_text() if path.exists() else None
        if current == text:
            continue
        stale.append(path.relative_to(ROOT))
        if not args.check:
            path.write_text(text)
    if args.check and stale:
        print("stale: " + ", ".join(map(str, stale)) + " (run scripts/cmux-next/gen-daemon-command-names.py)")
        return 1
    for path in stale:
        print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

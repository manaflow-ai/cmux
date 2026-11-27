#!/usr/bin/env python3
"""Write CmuxNextAgentPane's relay policy tables from cmux-tui/crates/cmux-agent-pane-policy/policy.json.

policy.json is the one copy of what the agent pane page may send to acpmux through the host-owned
socket (ad349): the Rust policy crate embeds it with include_str!, and this script writes the Swift
the macOS relay compiles in, so the two can no longer drift (they did: `_acpmux/status`'s
`health.autoCloud` was in the Swift reply shape and not in policy.json). The tables keep their
names, types and access levels on `AcpmuxPaneMethods`; the logic that reads them stays in Swift.
`notes` in policy.json holds each table's doc comment (`@doc`), each entry's reasons (written above
the entry) and a table's closing notes (`@end`).

The AgentPanePolicyPlugin (Packages/macOS/CmuxNext/Plugins) runs it at every build with
--swift-out <its work directory>; nothing it writes is committed (RFD 0048). A file whose text is
unchanged is not rewritten, so an incremental build recompiles nothing.

Usage: gen-agent-pane-policy-swift.py --swift-out DIR   (or --print to write the Swift to stdout)
"""

from __future__ import annotations

import argparse
import json
import sys
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / "cmux-tui/crates/cmux-agent-pane-policy/policy.json"
FILE_NAME = "AcpmuxPaneMethods+Policy.generated.swift"

# policy.json key -> (Swift declaration up to `=`, kind of table).
TABLES = [
    ("requests", "public static let requests: Set<String>", "set"),
    ("notifications", "public static let notifications: Set<String>", "set"),
    ("session_scoped", "public static let sessionScoped: Set<String>", "set"),
    ("scoped_session_params", "public static let scopedSessionParams: [String: Set<String>]", "map_set"),
    ("primary_session_params", "public static let primarySessionParams: [String: String]", "map_string"),
    ("optional_scoped_session_params", "public static let optionalScopedSessionParams: [String: Set<String>]", "map_set"),
    ("optionally_session_scoped", "public static let optionallySessionScoped: Set<String>", "set"),
    ("source_scoped", "public static let sourceScoped: Set<String>", "set"),
    ("gesture_rules", "public static let gestureRules: [String: GestureRule]", "gesture"),
    ("setting_methods", "static let settingMethods: Set<String>", "set"),
    ("known_params", "static let knownParams: [String: (params: Set<String>, acpmux: Set<String>)]", "params"),
    ("reply_shapes", "public static let replyShapes: [String: ReplyShape]", "shape"),
]

GESTURES = {"always", "when_trusting", "when_option_allows", "when_decision_allows", "when_prompting"}


def string(value: str) -> str:
    """A Swift string literal; json.dumps escapes as Swift reads it for the text policy.json holds."""
    if not isinstance(value, str):
        raise SystemExit(f"{POLICY}: expected a string, got {value!r}")
    return json.dumps(value, ensure_ascii=False)


def string_set(values: list) -> str:
    if len(set(values)) != len(values):
        raise SystemExit(f"{POLICY}: a set lists a value twice: {values!r}")
    return "[" + ", ".join(string(v) for v in values) + "]"


def gesture(value: str) -> str:
    if value not in GESTURES:
        raise SystemExit(f"{POLICY}: unknown gesture rule {value!r} (one of {sorted(GESTURES)})")
    head, *rest = value.split("_")
    return "." + head + "".join(word.capitalize() for word in rest)


def shape(value) -> str:
    """A `ReplyShape` literal: "string" | "bool" | "number" | {object: {}} | {list: shape} | {scheme: field}."""
    if value in ("string", "bool", "number"):
        return "." + value
    if isinstance(value, dict) and len(value) == 1:
        (kind, inner), = value.items()
        if kind == "object" and isinstance(inner, dict):
            return ".object([" + ", ".join(f"{string(k)}: {shape(v)}" for k, v in inner.items()) + "])"
        if kind == "list":
            return ".list(" + shape(inner) + ")"
        if kind == "scheme":
            return ".scheme(from: " + string(inner) + ")"
    raise SystemExit(f"{POLICY}: not a reply shape: {value!r}")


def comment(paragraphs: list[str], indent: str, marker: str = "//") -> list[str]:
    out: list[str] = []
    for i, paragraph in enumerate(paragraphs):
        if i:
            out.append(f"{indent}{marker}")
        out += textwrap.wrap(paragraph, width=110 - len(indent), initial_indent=f"{indent}{marker} ",
                             subsequent_indent=f"{indent}{marker} ", break_long_words=False, break_on_hyphens=False)
    return out


def entry(kind: str, key: str, value) -> str:
    if kind == "set":
        return string(key)
    if kind == "map_set":
        return f"{string(key)}: {string_set(value)}"
    if kind == "map_string":
        return f"{string(key)}: {string(value)}"
    if kind == "gesture":
        return f"{string(key)}: {gesture(value)}"
    if kind == "params":
        if set(value) != {"params", "acpmux"}:
            raise SystemExit(f"{POLICY}: known_params[{key!r}] needs exactly params and acpmux")
        return f"{string(key)}: ({string_set(value['params'])}, {string_set(value['acpmux'])})"
    if kind == "shape":
        return f"{string(key)}: {shape(value)}"
    raise AssertionError(kind)


def render(policy: dict) -> str:
    notes = policy.get("notes", {})
    lines = [
        f"// Generated by scripts/cmux-next/gen-agent-pane-policy-swift.py from",
        f"// cmux-tui/crates/cmux-agent-pane-policy/policy.json. Do not edit: edit policy.json.",
        "",
        "nonisolated extension AcpmuxPaneMethods {",
    ]
    for key, declaration, kind in TABLES:
        table, table_notes = policy[key], dict(notes.get(key, {}))
        keys = table if kind == "set" else list(table)
        if kind == "set":
            string_set(table)
        unknown = set(table_notes) - set(keys) - {"@doc", "@end"}
        if unknown:
            raise SystemExit(f"{POLICY}: notes.{key} names no entry of {key}: {sorted(unknown)}")
        lines += comment(table_notes.pop("@doc", []), "    ", "///")
        end = table_notes.pop("@end", [])
        if not keys:
            lines += [f"    {declaration} = [{':' if kind != 'set' else ''}]", ""]
            continue
        lines.append(f"    {declaration} = [")
        for k in keys:
            lines += comment(table_notes.get(k, []), "        ")
            lines.append(f"        {entry(kind, k, None if kind == 'set' else table[k])},")
        lines += comment(end, "        ")
        lines += ["    ]", ""]
    lines[-1] = "}"
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--swift-out", type=Path, help="write the Swift file into this directory")
    group.add_argument("--print", action="store_true", help="write the Swift to stdout")
    args = parser.parse_args(argv)
    text = render(json.loads(POLICY.read_text()))
    if args.print:
        sys.stdout.write(text)
        return 0
    args.swift_out.mkdir(parents=True, exist_ok=True)
    out = args.swift_out / FILE_NAME
    if not out.exists() or out.read_text() != text:
        out.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())

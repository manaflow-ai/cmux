#!/usr/bin/env python3
"""Validate the Swift dispatcher inventory and render Rust CLI metadata.

The manifest is intentionally data-first.  It is useful to agents before the
Rust binary is available, while the validation keeps it tied to the command
labels shipped by CLI/cmux.swift.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "Native/CmuxCLI/commands.json"
README = ROOT / "Native/CmuxCLI/README.md"
SWIFT = ROOT / "CLI/cmux.swift"


def swift_labels() -> list[str]:
    lines = SWIFT.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "switch command {")
    end = next(i for i in range(start, len(lines)) if "throw unknownCommandError(command)" in lines[i])
    labels: list[str] = []
    pending: str | None = None
    for line in lines[start:end + 1]:
        match = re.match(r"^ {8}case\s+(.*)$", line)
        if match:
            if pending is not None:
                labels.extend(re.findall(r'"([^"\\]+)"', pending.split(":", 1)[0]))
            pending = match.group(1)
            if ":" in pending:
                labels.extend(re.findall(r'"([^"\\]+)"', pending.split(":", 1)[0]))
                pending = None
        elif pending is not None:
            pending += " " + line.strip()
            if ":" in line:
                labels.extend(re.findall(r'"([^"\\]+)"', pending.split(":", 1)[0]))
                pending = None
    if pending is not None:
        labels.extend(re.findall(r'"([^"\\]+)"', pending))
    return list(dict.fromkeys(labels))


def load() -> dict:
    data = json.loads(MANIFEST.read_text())
    if data.get("schema_version") != 1:
        raise SystemExit("commands.json: unsupported schema_version")
    commands = data.get("commands")
    if not isinstance(commands, list):
        raise SystemExit("commands.json: commands must be a list")
    seen: set[str] = set()
    for item in commands:
        if not isinstance(item, dict) or not item.get("label"):
            raise SystemExit("commands.json: every command needs a label")
        label = item["label"]
        if label in seen:
            raise SystemExit(f"commands.json: duplicate command label: {label}")
        seen.add(label)
        if not item.get("ownership"):
            raise SystemExit(f"commands.json: missing command ownership: {label}")
        if item.get("migration") not in {"implemented", "delegated", "fallback"}:
            raise SystemExit(f"commands.json: invalid migration for {label}")
    expected = swift_labels()
    missing = [label for label in expected if label not in seen]
    extra = [label for label in seen if label not in expected]
    if missing:
        raise SystemExit("commands.json: missing Swift dispatcher labels: " + ", ".join(missing))
    if extra:
        raise SystemExit("commands.json: labels no longer in Swift dispatcher: " + ", ".join(extra))
    if len(expected) != 158:
        raise SystemExit(f"Swift dispatcher inventory changed: expected 158 labels, found {len(expected)}")
    return data


def render(data: dict) -> str:
    rows = []
    for item in data["commands"]:
        aliases = ", ".join(f"`{x}`" for x in item.get("aliases", [])) or "none"
        output = ", ".join(item.get("output", ["text"]))
        nested = ", ".join(f"`{x}`" for x in item.get("nested", [])) or "none"
        rows.append(
            f"| `{item['label']}` | `{item['ownership']}` | `{item['migration']}` | "
            f"{output} | {item.get('side_effects', 'socket')} | {aliases} | {nested} |"
        )
    return """# Native cmux CLI command manifest

`commands.json` is the compatibility inventory for the Rust CLI migration. It
contains every label in the Swift `switch command` dispatcher, including hidden
compatibility verbs. `scripts/generate-cli-docs.py` validates the inventory
against `CLI/cmux.swift` and renders this table.

## Agent contract

All commands accept the shared global presentation flags where supported:
`--output text|json|jsonl`, `--non-interactive`, `--dry-run`, and `--explain`.
JSON output is stdout-only; progress and diagnostics belong on stderr. The
`migration` column means `implemented` (Rust owns behavior), `delegated` (Rust
owns dispatch and delegates to a shared/app capability), or `fallback` (Swift
still owns behavior and Rust reports that boundary).

## Inventory

| Label | Rust ownership | Migration | Output | Side effects | Aliases | Nested verbs |
|---|---|---|---|---|---|---|
""" + "\n".join(rows) + "\n"


def main() -> int:
    data = load()
    README.write_text(render(data))
    print(f"validated {len(data['commands'])} command labels; wrote {README}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Ghostty-default keys stay Ghostty's: check the exported default keymap against the reserved list.

The reserved list (schemas/keybindings/ghostty-reserved-keys.json) names Ghostty's macOS default
split keys cmux-next keeps (Cmd-Opt-arrows focus a pane, Cmd-D splits, ...). Lawrence 2026-10-20,
after 2f3e1f95983 moved Cmd-Opt-Left / Right to the sidebar: "We need to ensure this never happens
again."

Findings (one per line, exit 1):
  - a reserved key is not its command's default key or alias in plans/cmux-next/action-surfaces.json;
  - another action has a reserved key as an unscoped default (only `scopedActions`, and aliases whose
    `when` names a `scopedOwners.keys` focus key, may share one: they run only in an editor or field);
  - with --base-reserved: the push removes or changes a reserved entry (needs the user's OK).

  check-ghostty-reserved-keys.py --reserved FILE --surfaces FILE [--base-reserved FILE]

The pre-push gate (scripts/cmux-next/prepush-gate.py) runs it on every push and on CI; only a
`Ghostty-defaults-OK: <the user's words>` commit trailer lets a finding through.
GhosttyReservedKeysTests (CmuxNextActionsTests) checks the same list against the live binding table.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ARROWS = {"left": "", "right": "", "up": "", "down": "", "enter": "\r"}
ORDER = ("ctrl", "opt", "shift", "cmd")


def stroke(text: str) -> tuple[str, tuple[str, ...]]:
    """`cmd+opt+left` as the export's (key, modifiers in ctrl, opt, shift, cmd order)."""
    tokens = text.lower().split("+")
    modifiers = tuple(m for m in ORDER if m in tokens)
    key = next(t for t in tokens if t not in ORDER)
    return ARROWS.get(key, key), modifiers


def wire(shortcut: dict) -> tuple[str, tuple[str, ...]]:
    return shortcut["key"].lower(), tuple(m for m in ORDER if m in shortcut.get("modifiers", []))


def check(reserved: dict, surfaces: dict, base_reserved: dict | None) -> list[str]:
    findings: list[str] = []
    rows = reserved.get("reserved", [])
    scoped_actions = set(reserved.get("scopedActions", []))
    scoped_keys = reserved.get("scopedOwners", {}).get("keys", [])
    owners: dict[tuple, list[tuple[str, str | None]]] = {}
    for action in surfaces.get("actions", []):
        if action.get("default_shortcut"):
            owners.setdefault(wire(action["default_shortcut"]), []).append((action["id"], None))
        for alias in action.get("default_aliases", []):
            if len(alias.get("keys", [])) == 1:
                owners.setdefault(wire(alias["keys"][0]), []).append((action["id"], alias.get("when") or ""))
    for row in rows:
        key, command = stroke(row["key"]), row["command"]
        found = owners.get(key, [])
        if not any(owner == command for owner, _ in found):
            findings.append(f"ghostty-reserved-keys.json: {row['key']} is not a default key of {command} "
                            f"(Ghostty {row.get('ghostty', '?')}); it runs {', '.join(o for o, _ in found) or 'nothing'}")
        for owner, when in found:
            if owner == command:
                continue
            scoped = owner in scoped_actions if when is None else any(k in when for k in scoped_keys)
            if not scoped:
                findings.append(f"action-surfaces.json: {owner} takes Ghostty's {row['key']} ({row.get('ghostty', '?')}, "
                                f"reserved for {command}){' when ' + when if when else ''}")
    if base_reserved is not None:
        head = {(r["key"], r["command"]) for r in rows}
        for row in base_reserved.get("reserved", []):
            if (row["key"], row["command"]) not in head:
                findings.append(f"ghostty-reserved-keys.json: the push removes or changes reserved {row['key']} = "
                                f"{row['command']} (Ghostty {row.get('ghostty', '?')})")
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--reserved", required=True, type=Path)
    parser.add_argument("--surfaces", required=True, type=Path)
    parser.add_argument("--base-reserved", type=Path)
    args = parser.parse_args(argv)
    reserved = json.loads(args.reserved.read_text(encoding="utf-8"))
    surfaces = json.loads(args.surfaces.read_text(encoding="utf-8"))
    base = json.loads(args.base_reserved.read_text(encoding="utf-8")) if args.base_reserved else None
    findings = check(reserved, surfaces, base)
    for line in findings:
        print(line)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())

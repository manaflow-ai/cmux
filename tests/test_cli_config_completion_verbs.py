#!/usr/bin/env python3
"""Asserts `cmux config <TAB>` offers every subcommand `cmux config --help` documents.

A verb the runner handles but completion omits is invisible to anyone who
discovers commands by tabbing. The documented verbs come from the usage line in
CLI/CMUXCLI+Config.swift; aliases (the extra labels on a runner `case`, such as
`paths` for `path`) are left out of completion on purpose. The offered verbs come
from docs/cli-command-tree.txt, which test_cli_command_tree_snapshot.py ties to
the built binary.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG_SOURCE = ROOT / "CLI" / "CMUXCLI+Config.swift"
COMMAND_TREE = ROOT / "docs" / "cli-command-tree.txt"


def documented_verbs(source: str) -> set[str]:
    match = re.search(r"Usage: cmux config <([^>]+)>", source)
    if not match:
        raise AssertionError("usage line `Usage: cmux config <...>` not found")
    return set(match.group(1).split("|"))


def runner_aliases(source: str) -> set[str]:
    """Labels after the first on a runner `case` that lists string literals only."""
    aliases: set[str] = set()
    for labels in re.findall(r'^\s*case ((?:"[^"]+"(?:, )?)+):', source, re.MULTILINE):
        aliases.update(re.findall(r'"([^"]+)"', labels)[1:])
    return aliases


def offered_verbs(tree: str) -> set[str]:
    match = re.search(
        r"^command  config  .*\n(?:  .*\n)*?  arg  arguments  kind=argument  completion=list\(([^)]*)\)$",
        tree,
        re.MULTILINE,
    )
    if not match:
        raise AssertionError("`config` arguments completion list not found in the command tree")
    return set(match.group(1).split(","))


def main() -> int:
    source = CONFIG_SOURCE.read_text(encoding="utf-8")
    aliases = runner_aliases(source)
    expected = documented_verbs(source) - aliases
    offered = offered_verbs(COMMAND_TREE.read_text(encoding="utf-8"))

    failures = []
    missing = sorted(expected - offered)
    if missing:
        failures.append(f"documented but not offered by completion: {', '.join(missing)}")
    offered_aliases = sorted(offered & aliases)
    if offered_aliases:
        failures.append(f"aliases offered by completion: {', '.join(offered_aliases)}")
    if failures:
        for failure in failures:
            print(f"FAIL: cmux config completion: {failure}")
        return 1
    print("PASS: cmux config completion offers every documented subcommand")
    return 0


if __name__ == "__main__":
    sys.exit(main())

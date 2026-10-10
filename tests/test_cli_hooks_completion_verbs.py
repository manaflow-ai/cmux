#!/usr/bin/env python3
"""Asserts `cmux hooks <TAB>` offers every catalog-wide verb `cmux hooks --help` documents.

The verbs are the literal first words of the `cmux hooks ...` lines in the help
text in CLI/cmux.swift: `setup`, `uninstall` and `feed`, plus any agent an
example names (`codex`, `opencode`). Placeholder `<agent>` lines are skipped. The offered words come from docs/cli-command-tree.txt, which
test_cli_command_tree_snapshot.py ties to the built binary.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELP_SOURCE = ROOT / "CLI" / "cmux.swift"
COMMAND_TREE = ROOT / "docs" / "cli-command-tree.txt"


def documented_verbs(source: str) -> set[str]:
    match = re.search(r'case "hooks":\n\s*return """\n(.*?)\n\s*"""', source, re.DOTALL)
    if not match:
        raise AssertionError("`cmux hooks` help text not found")
    verbs = set(re.findall(r"cmux hooks ([a-z][a-z-]*)\b", match.group(1)))
    if not verbs:
        raise AssertionError("no literal `cmux hooks <verb>` usage lines found")
    return verbs


def offered_words(tree: str) -> set[str]:
    match = re.search(
        r"^command  hooks  .*\n(?:  .*\n)*?  arg  arguments  kind=argument  completion=list\(([^)]*)\)$",
        tree,
        re.MULTILINE,
    )
    if not match:
        raise AssertionError("`hooks` arguments completion list not found in the command tree")
    return set(match.group(1).split(","))


def main() -> int:
    expected = documented_verbs(HELP_SOURCE.read_text(encoding="utf-8"))
    offered = offered_words(COMMAND_TREE.read_text(encoding="utf-8"))
    missing = sorted(expected - offered)
    if missing:
        print(f"FAIL: cmux hooks completion: documented but not offered: {', '.join(missing)}")
        return 1
    print(f"PASS: cmux hooks completion offers {', '.join(sorted(expected))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

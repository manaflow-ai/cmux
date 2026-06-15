#!/usr/bin/env python3
"""Require standalone cmux windows to own the standard close shortcut."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


DEFAULT_ROOTS = ("Sources",)
OWNER_LIST_PATH = pathlib.Path("Sources/cmuxApp.swift")
OWNER_LIST_NAME = "cmuxAuxiliaryWindowIdentifiers"

# Hidden/internal bootstrap windows should not take Cmd+W away from the active
# main window. Add to this set only when a window is intentionally not user
# closable.
IGNORED_IDENTIFIERS = {
    # Hidden WebKit preload host; it is not user closable and must not own Cmd+W.
    "cmux.browserBackgroundPreload",
    # Hidden WebKit visual automation host; it renders offscreen and never becomes key/main.
    "cmux.browserVisualAutomationRender",
    "cmux.bootstrap",
    # Cursor-anchored textbox completion popup; it never becomes key/main.
    "cmux.textbox.mentionCompletionPanel",
}

IDENTIFIER_ASSIGNMENT_RE = re.compile(
    r"""\b[A-Za-z_][A-Za-z0-9_]*\.identifier\s*=\s*NSUserInterfaceItemIdentifier\("(?P<identifier>cmux\.[^"]+)"\)"""
)
# `window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)` —
# the identifier comes from a named constant instead of an inline literal. The
# constant is resolved against `let <name> = "cmux...."` declarations in the
# same file (the prevailing pattern: a `static let windowIdentifier` next to
# the controller that assigns it). The pairing window regressed exactly here:
# the literal-only regex never saw `cmux.mobilePairingWindow`, so the lint
# passed while Cmd+W fell through to the terminal's Close Tab.
CONSTANT_ASSIGNMENT_RE = re.compile(
    r"""\b[A-Za-z_][A-Za-z0-9_]*\.identifier\s*=\s*NSUserInterfaceItemIdentifier\(\s*(?P<expr>[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*\)"""
)
STRING_CONSTANT_DECL_RE = re.compile(
    r"""\blet\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*String\s*)?=\s*"(?P<identifier>cmux\.[^"]+)\""""
)
STRING_LITERAL_RE = re.compile(r'"(?P<identifier>cmux\.[^"]+)"')
BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
LINE_COMMENT_RE = re.compile(r"//[^\n]*")


def strip_line_comments(text: str) -> str:
    text = BLOCK_COMMENT_RE.sub(lambda match: "\n" * match.group(0).count("\n"), text)
    return LINE_COMMENT_RE.sub("", text)


def load_close_owner_identifiers(repo_root: pathlib.Path) -> set[str]:
    path = repo_root / OWNER_LIST_PATH
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise ValueError(f"missing {OWNER_LIST_PATH}") from None

    parse_text = strip_line_comments(text)
    marker = f"private let {OWNER_LIST_NAME}"
    marker_index = parse_text.find(marker)
    if marker_index < 0:
        raise ValueError(f"missing {OWNER_LIST_NAME} in {OWNER_LIST_PATH}")

    list_start = parse_text.find("[", marker_index)
    if list_start < 0:
        raise ValueError(f"could not parse {OWNER_LIST_NAME} in {OWNER_LIST_PATH}")

    depth = 0
    list_end = -1
    for index in range(list_start, len(parse_text)):
        if parse_text[index] == "[":
            depth += 1
        elif parse_text[index] == "]":
            depth -= 1
            if depth == 0:
                list_end = index
                break
    if list_end < 0:
        raise ValueError(f"could not parse {OWNER_LIST_NAME} in {OWNER_LIST_PATH}")

    list_body = parse_text[list_start:list_end]
    return {match.group("identifier") for match in STRING_LITERAL_RE.finditer(list_body)}


def collect_window_identifier_assignments(
    repo_root: pathlib.Path,
    roots: tuple[str, ...],
) -> dict[str, list[str]]:
    assignments: dict[str, list[str]] = {}
    for root in roots:
        root_path = repo_root / root
        if not root_path.exists():
            continue
        for path in sorted(root_path.rglob("*.swift")):
            rel_path = path.relative_to(repo_root).as_posix()
            text = strip_line_comments(path.read_text(encoding="utf-8", errors="replace"))
            for match in IDENTIFIER_ASSIGNMENT_RE.finditer(text):
                identifier = match.group("identifier")
                line_number = text.count("\n", 0, match.start()) + 1
                assignments.setdefault(identifier, []).append(f"{rel_path}:{line_number}")
            constants = {
                decl.group("name"): decl.group("identifier")
                for decl in STRING_CONSTANT_DECL_RE.finditer(text)
            }
            for match in CONSTANT_ASSIGNMENT_RE.finditer(text):
                constant_name = match.group("expr").rsplit(".", 1)[-1]
                identifier = constants.get(constant_name)
                if identifier is None:
                    continue
                line_number = text.count("\n", 0, match.start()) + 1
                assignments.setdefault(identifier, []).append(f"{rel_path}:{line_number}")
    return assignments


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        default=pathlib.Path.cwd(),
        type=pathlib.Path,
        help="repository root to scan",
    )
    parser.add_argument(
        "--roots",
        nargs="+",
        default=list(DEFAULT_ROOTS),
        help="repo-relative Swift roots to scan",
    )
    args = parser.parse_args(argv)

    repo_root = args.repo_root.resolve(strict=False)
    try:
        close_owners = load_close_owner_identifiers(repo_root)
    except ValueError as exc:
        print(f"Auxiliary window close-shortcut lint could not run: {exc}", file=sys.stderr)
        return 2

    assignments = collect_window_identifier_assignments(repo_root, tuple(args.roots))
    missing = {
        identifier: locations
        for identifier, locations in assignments.items()
        if identifier not in close_owners and identifier not in IGNORED_IDENTIFIERS
    }

    if missing:
        print("Auxiliary window close-shortcut lint failed.")
        print("")
        print(
            "These cmux window identifiers are assigned to NSWindow/NSPanel "
            f"but are missing from {OWNER_LIST_NAME}:"
        )
        for identifier in sorted(missing):
            print(f"- {identifier}")
            for location in missing[identifier]:
                print(f"  {location}")
        print("")
        print(
            f"Add each user-closable window to {OWNER_LIST_NAME} in {OWNER_LIST_PATH}, "
            "or add a documented lint ignore for internal windows that must not own Cmd+W."
        )
        return 1

    print("Auxiliary window close-shortcut lint passed.")
    print(f"Checked {len(assignments)} cmux window identifier(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

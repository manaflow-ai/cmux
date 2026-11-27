#!/usr/bin/env python3
"""Which cmuxTests/ suites a diff can change the behavior of.

A pull request that edits a few tests needs those tests run, not every suite.
Suites run when a changed line sits inside them. A changed declaration another
file can call is a helper: every place that names it is found, and the
declaration around that place is changed in turn. A test method ends the
trail at its suite; a helper method continues it.

The answer is None, meaning "run every suite", whenever it could be
incomplete: a changed file under cmuxTests/ that is not Swift, or a changed
declaration nothing can search for by name (a conformance, an operator).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

# A column-zero declaration.
TOP_LEVEL_RE = re.compile(
    r"^(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"((?:[a-z]+(?:\([a-z]+\))?\s+)*)"
    r"(func|enum|struct|class|actor|protocol|extension|let|var|typealias)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)"
)
# A member one level inside a top-level declaration. Name-less kinds (init,
# subscript, operators) leave the name group empty.
MEMBER_RE = re.compile(
    r"^    (?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"((?:[a-z]+(?:\([a-z]+\))?\s+)*)"
    r"(?:(func|var|let|enum|struct|class|actor|typealias|case)\s+([A-Za-z_][A-Za-z0-9_]*)"
    r"|(init|subscript|func\s+[^A-Za-z_\s(]))"
)
IDENTIFIER_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
FILE_LOCAL = {"private", "fileprivate"}
SUITE_KINDS = {"class", "struct", "actor", "extension"}
# Kinds whose body holds members rather than statements.
CONTAINER_KINDS = {"class", "struct", "actor", "enum", "protocol", "extension"}
# XCTest calls these itself; nothing else names them.
XCTEST_HOOKS = {"setUp", "tearDown", "setUpWithError", "tearDownWithError", "invokeTest"}


@dataclass(frozen=True)
class Declaration:
    start: int
    end: int
    name: str | None
    suite: str | None
    visible: bool
    test: bool
    # The type a member belongs to: callers elsewhere name it to reach one.
    owner: str | None = None
    # A non-suite declaration with tests inside, such as a container of
    # nested Swift Testing suites, whose selectors this module cannot name.
    holds_tests: bool = False


@dataclass(frozen=True)
class Outline:
    top: tuple[Declaration, ...]
    members: tuple[Declaration, ...]


def is_suite(kind: str, name: str) -> bool:
    return kind in SUITE_KINDS and name.endswith("Tests")


def outline(lines: list[str]) -> Outline:
    """Top-level declarations and their one-level members, with line ranges."""
    starts: list[tuple[int, str, str, str]] = []
    for number, line in enumerate(lines, start=1):
        match = TOP_LEVEL_RE.match(line)
        if match is not None:
            starts.append((number, match.group(1), match.group(2), match.group(3)))
    top: list[Declaration] = []
    members: list[Declaration] = []
    for index, (start, modifiers, kind, name) in enumerate(starts):
        end = starts[index + 1][0] - 1 if index + 1 < len(starts) else len(lines)
        suite = name if is_suite(kind, name) else None
        file_local = bool(FILE_LOCAL & set(modifiers.split()))
        top.append(
            Declaration(
                start,
                end,
                # An extension of another type adds members; the type's own
                # name tells a search nothing about them. A conformance adds
                # behavior no name leads to.
                None if kind == "extension" and suite is None and ":" in lines[start - 1].split("{")[0]
                else (name if kind != "extension" or suite else ""),
                suite,
                not file_local,
                False,
                holds_tests=suite is None
                and any(
                    marker in text
                    for text in lines[start - 1 : end]
                    for marker in ("@Test", "@Suite", "XCTestCase")
                ),
            )
        )
        member_starts: list[tuple[int, re.Match[str]]] = [
            (number, match)
            for number in range(start + 1, end + 1)
            if kind in CONTAINER_KINDS
            and (match := MEMBER_RE.match(lines[number - 1])) is not None
        ]
        for position, (member_start, match) in enumerate(member_starts):
            member_end = (
                member_starts[position + 1][0] - 1 if position + 1 < len(member_starts) else end
            )
            member_name = match.group(3)
            # Only a suite's hooks and test methods are called by the test
            # runner alone; a helper's `tearDown()` has callers.
            test = member_name is not None and suite is not None and (
                member_name.startswith("test")
                or member_name in XCTEST_HOOKS
                or has_test_attribute(lines, member_start)
            )
            members.append(
                Declaration(
                    member_start,
                    member_end,
                    member_name,
                    suite,
                    not file_local and not (FILE_LOCAL & set(match.group(1).split())),
                    test,
                    # Extension members are called on values ("a".shouted)
                    # that never name the extended type.
                    None if kind == "extension" and suite is None else name,
                )
            )
    return Outline(tuple(top), tuple(members))


def has_test_attribute(lines: list[str], start: int) -> bool:
    """Whether the member declared at `start` carries @Test, on its line or above."""
    if "@Test" in lines[start - 1]:
        return True
    # Walk up through attribute lines, including multi-line arguments, to the
    # previous member's closing brace or a blank line.
    for number in range(start - 1, max(start - 12, 0), -1):
        text = lines[number - 1]
        if not text.strip() or text.startswith("    }") or MEMBER_RE.match(text):
            return False
        if text.startswith("    @Test"):
            return True
    return False


def changed_lines(diff: str) -> dict[str, set[int]]:
    """New-side line numbers each file's hunks touch, from `git diff -U0`."""
    changed: dict[str, set[int]] = {}
    path: str | None = None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            target = line[4:].strip()
            path = target[2:] if target.startswith("b/") else None
            if path is not None:
                changed.setdefault(path, set())
            continue
        match = HUNK_RE.match(line)
        if match is None or path is None:
            continue
        first = int(match.group(1))
        count = int(match.group(2)) if match.group(2) is not None else 1
        # A pure deletion touches the declaration around where it was.
        changed[path].update(range(first, first + count) if count else {max(first, 1)})
    return changed


def enclosing(outline_: Outline, line: int) -> tuple[Declaration | None, Declaration | None]:
    top = next((item for item in outline_.top if item.start <= line <= item.end), None)
    member = next((item for item in outline_.members if item.start <= line <= item.end), None)
    return top, member


def affected_suites(
    root: Path, paths: list[str], diff: str | None
) -> list[str] | None:
    """cmuxTests/ suite selectors a diff affects; None to run every suite.

    `diff` is `git diff -U0` output for the same change. Without it, every
    line of each changed file counts as changed.
    """
    files: dict[str, list[str]] = {}
    mentions: dict[str, set[str]] = {}
    for source in sorted((root / "cmuxTests").glob("**/*.swift")):
        relative = source.relative_to(root).as_posix()
        try:
            text = source.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            return None
        files[relative] = text.splitlines()
        for word in set(IDENTIFIER_RE.findall(text)):
            mentions.setdefault(word, set()).add(relative)
    outlines: dict[str, Outline] = {}

    def outline_of(path: str) -> Outline:
        if path not in outlines:
            outlines[path] = outline(files[path])
        return outlines[path]

    hunks = changed_lines(diff) if diff is not None else {}
    suites: set[str] = set()
    # (name, type that owns it). Another file reaches a member through its
    # type's name, so that search stays in files that name both.
    names: list[tuple[str, str | None]] = []

    def touch(path: str, line: int) -> bool:
        """Record what a changed or referencing line affects; False if untraceable."""
        top, member = enclosing(outline_of(path), line)
        if top is None:
            return True  # imports, comments
        if top.name is None or top.holds_tests:
            return False  # inside a conformance, or suites named nowhere here
        if top.suite is not None:
            suites.add(top.suite)
        if member is not None and member.start > top.start:
            if member.name is None:
                # init, subscript or operator: trace through the type, which
                # an extension of some other type does not name.
                if not top.name:
                    return False
                if top.visible:
                    names.append((top.name, None))
            elif member.visible and not member.test:
                if member.owner is not None and top.suite is None:
                    # A helper type's member. App code may call it (a mock)
                    # and callers may hold an instance without naming it, so
                    # trace the type: whatever constructs, returns or stores
                    # one is affected.
                    names.append((member.owner, None))
                else:
                    names.append((member.name, member.owner))
            return True
        if top.name is None:
            return False
        if top.visible and top.name:
            names.append((top.name, None))
        return True

    for path in (path.strip() for path in paths):
        if not path.startswith("cmuxTests/"):
            continue
        if not (root / path).exists():
            # Deleted: whatever used it changed in this diff too, or no
            # longer compiles.
            continue
        if path not in files:
            return None
        text = files[path]
        whole = range(1, len(text) + 1)
        lines = hunks.get(path) if diff is not None else None
        first_declaration = min((item.start for item in outline_of(path).top), default=len(text) + 1)
        if not lines or any(
            line < first_declaration and text[line - 1].strip() and not text[line - 1].lstrip().startswith("//")
            for line in lines
        ):
            # No line information, or an import or other file-level line:
            # the whole file changed.
            lines = set(whole)
        for line in sorted(lines):
            if not touch(path, line):
                return None
            if text[line - 1].lstrip().startswith(("@", "#", "///")):
                # An attribute, directive or doc comment belongs to the
                # declaration it precedes, not the one above it.
                following = next(
                    (
                        number
                        for number in range(line + 1, min(line + 20, len(text)) + 1)
                        if TOP_LEVEL_RE.match(text[number - 1]) or MEMBER_RE.match(text[number - 1])
                    ),
                    None,
                )
                if following is not None and not touch(path, following):
                    return None

    searched: set[tuple[str, str | None]] = set()
    while names:
        name, owner = names.pop()
        if (name, owner) in searched:
            continue
        searched.add((name, owner))
        pattern = re.compile(rf"\b{re.escape(name)}\b")
        scope = mentions.get(name, set())
        if owner is not None:
            scope = scope & mentions.get(owner, set())
        for path in sorted(scope):
            for number, text in enumerate(files[path], start=1):
                if pattern.search(text) and not touch(path, number):
                    return None
    return sorted(f"cmuxTests/{suite}" for suite in suites)

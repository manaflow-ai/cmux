#!/usr/bin/env python3
"""Lexical Swift scope reading shared by the cmux-next checkers, and the one generic-class deinit detector.

guardrails.py (pre-push, what a push adds, Sources and Tests) and check-concurrency.sh (CI,
CHECK_CONCURRENCY_ONLY=crash-class, every Sources file) both refuse the generic main-actor class deinit crash
through `judge`, so the two gates refuse the same classes. guardrails.py's other context rules read their
enclosing blocks with the same `code_of` and `enclosing_openers`.

The crash: swift-frontend 6.3.3 (Xcode 26.6) crashes with signal 11 in -O (EarlyPerfInliner,
isCallerAndCalleeLayoutConstraintsCompatible) on the isolated deinit of a main-actor class that is generic by
its own parameters or by context: nested in a generic type, in an extension of one, in a generic function or
under a `where` clause. #20408 (ThemedPicker.Coordinator, CEFReplyWaiters, BrowserHistoryWriter.Once), #23050
(FirstMouseHostingView), 6bf522e6cdd (ObservedMap.Slot), PageTestWait.Once and CloudPaneTests.Seen hit it.
Only a `nonisolated deinit` is the fix. An `isolated deinit` is the crashing deinit written out, and a plain
`deinit` takes the target's default isolation, the main actor in a uiSwiftSettings target (#20408,
215fe45c7a2: "Under the UI targets' MainActor default isolation a class's deinit is isolated";
check-concurrency.sh refuses a plain deinit there for cx-t7hu); every fix that landed is `nonisolated deinit`.
"""
from __future__ import annotations

import importlib.util
import itertools
import re
from pathlib import Path
from typing import Callable, NamedTuple

COMMENT_LINE = re.compile(r"^\s*(//|\*|/\*)")
# An attribute, its arguments holding one level of nested parentheses (`@available(*, message: "use X (new)")`).
ATTRIBUTE = r"@\w+(?:\((?:[^()]|\([^()]*\))*\))?"
ATTRIBUTE_LINE = re.compile(rf"^\s*{ATTRIBUTE}\s*$")

# check-main-actor-work.py decides which lines are main-actor code (target default plus lexical
# `@MainActor` / `nonisolated` / actor / detached scopes); check-concurrency.sh's other rules use it too.
_SPEC = importlib.util.spec_from_file_location("cmux_next_main_actor_scope",
                                               Path(__file__).resolve().parent / "check-main-actor-work.py")
main_actor_scope = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(main_actor_scope)


def code_of(line: str) -> str:
    """LINE without a trailing `//` comment (outside string literals) and with string contents blanked."""
    if '"' not in line and "/" not in line:
        return line
    if COMMENT_LINE.match(line):
        return ""
    out, in_string, i = [], False, 0
    while i < len(line):
        c = line[i]
        if in_string:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_string = False
                out.append(c)
            i += 1
            continue
        if c == '"':
            in_string = True
            out.append(c)
        elif line.startswith("//", i):
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def escaped(lines: list[str], index: int, marker: re.Pattern) -> bool:
    """MARKER on the line, on the previous code line's trailing comment, or in the comment block above."""
    if marker.search(lines[index]):
        return True
    j = index - 1
    while j >= 0 and (COMMENT_LINE.match(lines[j]) or ATTRIBUTE_LINE.match(lines[j])):
        if marker.search(lines[j]):
            return True
        j -= 1
    return j >= 0 and j == index - 1 and bool(marker.search(lines[j]))


def enclosing_openers(lines: list[str], index: int, stop: re.Pattern, prefix: str = "") -> list[tuple[str, int]]:
    """The block openers around LINES[INDEX], innermost first, up to one matching STOP, as (code, 1-based line).

    PREFIX is the code before the point of interest on LINES[INDEX] itself (a one-line `while x { sleep }`).
    Each opener is its line's code up to and including the `{`.
    """
    openers, depth = [], 0
    above = ((code_of(lines[j]), j + 1) for j in range(index - 1, -1, -1))
    for code, number in itertools.chain([(prefix, index + 1)], above):
        for pos in range(len(code) - 1, -1, -1):
            c = code[pos]
            if c == "}":
                depth += 1
            elif c == "{":
                if depth == 0:
                    openers.append((code[:pos + 1], number))
                    if stop.search(code[:pos + 1]):
                        return openers
                else:
                    depth -= 1
    return openers


# Which targets are main actor by default (`.defaultIsolation(MainActor.self)`, the uiSwiftSettings
# targets), and which target holds a file: check-main-actor-work.py's one Package.swift reader.
Target = main_actor_scope.Target
package_targets = main_actor_scope.package_targets
default_isolation = main_actor_scope.default_isolation


def main_lines(lines: list[str], default_main: bool) -> list[bool]:
    """Whether each line is main-actor code (check-main-actor-work.py's lexical scopes)."""
    return main_actor_scope.main_actor_lines(lines, default_main)


CLASS_DECL = re.compile(r"(^|[\s)])(final\s+)?(?P<kw>class)\s+(?!(?:func|var|let|subscript|init|deinit|override)\b)"
                        r"(?P<name>[A-Za-z_]\w*)\s*(<|:|\{|\bwhere\b|$)")
# The reviewed escapes: guardrails.py's own, and check-concurrency.sh's (the CI gate reads both).
GENERIC_CLASS_ALLOW = re.compile(r"//\s*(generic-class-allow|concurrency-allow):\s*\S")
GENERIC_TYPE = re.compile(r"\b(?:class|struct|enum|actor)\s+([A-Za-z_]\w*)\s*<")
GENERIC_DECL = re.compile(r"\b(?:class|struct|enum|actor)\s+[A-Za-z_]\w*\s*<|\b(?:func|subscript)\s+[^\s(<]*\s*<|\binit\??\s*<")
DECL_OPENER = re.compile(r"\b(class|struct|enum|actor|extension|protocol|func|init|subscript)\b")
EXTENSION = re.compile(r"\bextension\s+([A-Za-z_][\w.]*)")
NEVER = re.compile(r"(?!)")
NONISOLATED_DEINIT = re.compile(r"\bnonisolated\s+deinit\b")
OWN_ISOLATION = re.compile(r"\bnonisolated\b(?!\s*\(unsafe\))|@MainActor\b")


def generic_declarations(text: str) -> dict[str, list[int]]:
    """{type name: the 1-based lines of TEXT that declare it generic (`struct Name<...>`)}."""
    found: dict[str, list[int]] = {}
    for match in GENERIC_TYPE.finditer(text):
        found.setdefault(match.group(1), []).append(text.count("\n", 0, match.start()) + 1)
    return found


def generic_names(text: str) -> set[str]:
    """The type names TEXT declares generic (`struct Name<...>`)."""
    return set(GENERIC_TYPE.findall(text))


def extended_names(line: str, names: set[str] | frozenset[str]) -> set[str]:
    """The NAMES an `extension A.B` declaration on LINE extends (any component of its dotted name)."""
    extension = EXTENSION.search(code_of(line))
    return set(extension.group(1).split(".")) & set(names) if extension else set()


def declaration_of(lines: list[str], number: int, opener: str) -> str:
    """The declaration an opener (`{` line) belongs to, joined with the lines above it that continue it
    (`final class Cache<\\n    Key\\n> {`), up to 8 lines."""
    text, j = opener, number - 2
    while not DECL_OPENER.search(text) and j >= 0 and number - 1 - j <= 8:
        above = code_of(lines[j]).strip()
        if not above or above.endswith(("{", "}", ";")):
            break
        text, j = above + " " + text, j - 1
    return text


def generic_context(lines: list[str], index: int, prefix: str,
                    is_generic: Callable[[str], bool]) -> list[tuple[int, str | None]]:
    """The generic declarations LINES[INDEX] is nested in, innermost first: a generic type or function, a
    `where` clause, or an extension of a type IS_GENERIC names. Each is (its 1-based line, the extended type's
    name when only an extension of a type declared generic elsewhere makes it generic, else None)."""
    found: list[tuple[int, str | None]] = []
    for opener, number in enclosing_openers(lines, index, NEVER, prefix):
        decl = declaration_of(lines, number, opener)
        if not DECL_OPENER.search(decl):
            continue  # a control-flow block (`for x in xs where ...`) is no generic context
        if GENERIC_DECL.search(decl) or re.search(r"\bwhere\b", decl):
            found.append((number, None))
            continue
        extension = EXTENSION.search(decl)
        extended = next((n for n in extension.group(1).split(".") if is_generic(n)), None) if extension else None
        if extended is not None:
            found.append((number, extended))
    return found


def class_body(lines: list[str], index: int, start: str) -> tuple[str, int]:
    """(the class body's depth-1 code, the 0-based line of its closing brace) for the class whose declaration
    starts at LINES[INDEX] with START (that line's code from the `class` keyword on). Members of nested types
    and accessor bodies are left out; an unclosed body runs to the end of the file."""
    depth, opened, members = 0, False, []
    for j in range(index, len(lines)):
        line = code_of(lines[j]) if j > index else start
        for c in line:
            if c == "{":
                depth += 1
                opened = True
            elif c == "}":
                depth -= 1
                if opened and depth <= 0:
                    return "".join(members), j
            elif depth == 1:
                members.append(c)
        members.append("\n")
    return "".join(members), len(lines) - 1


class Judgement(NamedTuple):
    """A generic main-actor class with no `nonisolated deinit`: what makes it one, and where it is."""
    context: list[int]  # 1-based lines of the generic declarations around it (empty: generic by itself)
    span: tuple[int, int]  # 1-based declaration line and closing-brace line of its body
    # When only extensions of types declared generic elsewhere make it generic: those types. A change to their
    # declaration (in another file) makes or unmakes this class a candidate, so that file owns it too.
    extended: tuple[str, ...] = ()


def is_main(lines: list[str], index: int, code: str, keyword: int, main: list[bool], default_main: bool) -> bool:
    """Whether the class declared on LINES[INDEX] (its `class` keyword at KEYWORD of CODE) is main-actor code."""
    own = OWN_ISOLATION.findall(code[:keyword])
    if own:
        return own[-1] == "@MainActor"
    rest = code[keyword:]
    if main_actor_scope.OFF_MAIN.search(rest) or main_actor_scope.MAIN.search(rest):
        # A one-line body (`class Box<T> { nonisolated func f() {} }`) would set the whole line's
        # isolation: read the scope the declaration itself sits in.
        return main_lines(lines[:index] + [code[:keyword] + "class"], default_main)[-1]
    return main[index]


def judge(lines: list[str], index: int, is_generic: Callable[[str], bool], main: list[bool],
          default_main: bool) -> Judgement | None:
    """The crash candidate declared on LINES[INDEX], or None.

    A candidate is a class declaration in main-actor code (MAIN: `main_lines(lines, default_main)`), generic by
    its own parameters or by context (IS_GENERIC answers which type names are generic, for extensions), whose
    own members declare no `nonisolated deinit`. The caller applies the reviewed escape (GENERIC_CLASS_ALLOW).
    """
    code = code_of(lines[index])
    match = CLASS_DECL.search(code)
    if match is None:
        return None
    keyword = match.start("kw")
    if not is_main(lines, index, code, keyword, main, default_main):
        return None
    own = GENERIC_TYPE.match(code, keyword) is not None
    context = generic_context(lines, index, code[:keyword], is_generic)
    if not own and not context:
        return None
    members, last = class_body(lines, index, code[keyword:])
    if NONISOLATED_DEINIT.search(members):
        return None
    # Only when nothing in this file makes it generic does a declaration elsewhere decide it.
    extended = () if own or any(name is None for _, name in context) else tuple(dict.fromkeys(n for _, n in context))
    return Judgement([number for number, _ in context], (index + 1, last + 1), extended)

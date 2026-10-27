#!/usr/bin/env python3
"""Ratchet for heavy non-UI work on the main actor in CmuxNext.

plans/cmux-next/architecture.md section 5a: the main thread never waits and
does no unbounded work. check-concurrency.sh bans blocking calls; this check
flags CPU work whose cost grows with its input when it sits in main-actor code:
whole-input line splits, string scans inside loops, regular expressions, JSON
and property-list decoding, directory walks and process launches.

Main-actor code is every declaration of a `uiSwiftSettings` target in
Packages/macOS/CmuxNext/Package.swift (`.defaultIsolation(MainActor.self)`)
that is not inside a `nonisolated` or `@concurrent` declaration, an `actor`,
or a `Task.detached` closure, plus every `@MainActor` declaration in the other
targets. The scope tracking is lexical (brace depth), so it is a heuristic: a
reviewed exception carries `// main-actor-ok: <reason>` on the line or in the
comment block directly above it.

The check is a ratchet: scripts/cmux-next/main-actor-work-baseline.json holds
the per-file, per-rule hit counts of origin/feat-cmux-next. A count above the
baseline fails; a count below it asks for a baseline update
(`--update-baseline`). Move the work off the main actor (a `nonisolated`
type, a `@concurrent` function, an actor, or the Rust daemon) instead of
raising the baseline.

Usage: scripts/cmux-next/check-main-actor-work.py [--root <repo>] [--update-baseline] [--list]
"""

from __future__ import annotations

import argparse
import json
import os
import posixpath
import re
import subprocess
import sys
from typing import Callable, NamedTuple

PACKAGE = "Packages/macOS/CmuxNext"
BASELINE = "scripts/cmux-next/main-actor-work-baseline.json"

RULES: list[tuple[str, re.Pattern[str]]] = [
    ("line split of a whole input",
     re.compile(r"\.components\(separatedBy:\s*(\"\\n\"|\.newlines)|\.split\((separator:\s*\"\\n\"|whereSeparator:\s*\\\.isNewline)"
                r"|\.enumerateLines\b|\.split\(omittingEmptySubsequences:[^)]*\\\.isNewline")),
    ("regular expression",
     re.compile(r"\bNSRegularExpression\(|\btry\s+Regex\(|\bRegex\s*\{|(?<![\w/])#/|\.matches\(in:|\.firstMatch\(of:|\.wholeMatch\(of:")),
    ("JSON / property-list decode",
     re.compile(r"\bJSONDecoder\(\)|\bJSONSerialization\.jsonObject\(|\bPropertyListDecoder\(\)|\bPropertyListSerialization\.propertyList\(")),
    ("directory walk",
     re.compile(r"\.enumerator\((at|atPath):|\.contentsOfDirectory\((at|atPath):|\.subpathsOfDirectory\(|\.subpaths\(atPath:")),
    ("process launch",
     re.compile(r"\bProcess\(\)|\bposix_spawn\(")),
]
# A string scan inside a loop is quadratic when the loop advances by a small
# step: flag scan calls within LOOP_WINDOW lines after a `while`/`repeat`.
LOOP = re.compile(r"^\s*(\}\s*)?(while\b|repeat\s*\{)")
LOOP_WINDOW = 12
SCAN = re.compile(r"\.range\(of:|\.firstRange\(of:|\.firstIndex\(of:|\.lastIndex\(of:|\.index\(after:|\.index\([^)]*offsetBy:"
                  r"|\.components\(separatedBy:|\.distance\(from:|\.hasPrefix\(|\.contains\(\"")
LOOP_RULE = "string scan inside a loop"

# A main-actor Task per incoming line/event: an unbounded backlog of main-actor
# work under a burst (the 2026-10-09 nightly hang). Batch with
# MainActorLineBatch (CmuxNextAgentActivity) instead.
PER_LINE_CALLBACK = re.compile(r"\b(onLine|onEvent|onMessage|onFrame|onChunk):\s*\{|\bsetEventHandler\s*\{|\breadabilityHandler\s*=|for\s+(try\s+)?await\s+\w+\s+in\b")
# Every unstructured-Task initializer: `Task`, `Task.init`, with any arguments (`priority:`, Swift 6.2's `name:`).
TASK_INIT = r"\bTask(\.init)?\s*(\([^)]*\))?"
MAIN_TASK = re.compile(TASK_INIT + r"\s*\{\s*(\[[^\]]*\]\s*)?@MainActor\b")
PER_LINE_WINDOW = 1
PER_LINE_RULE = "a main-actor Task per line or event (batch with MainActorLineBatch)"

ALLOW = re.compile(r"//\s*main-actor-ok:\s*\S")
COMMENT_ONLY = re.compile(r"^\s*(//|\*|/\*)")
OFF_MAIN = re.compile(r"\bnonisolated\b(?!\s*\(unsafe\))|@concurrent\b|(^|\s)(distributed\s+)?actor\s+\w+|\bTask\.detached\b"
                      r"|\bDispatchQueue\.global\(|\bDispatchQueue\(label:")
MAIN = re.compile(r"@MainActor\b")
STRING_LITERAL = re.compile(r'"(?:\\.|[^"\\])*"')


# ---------------------------------------------------------------- Package.swift targets
# The one reader of which targets are main actor by default. check-concurrency.sh and guardrails.py read it
# through scripts/cmux-next/swift_scope.py, so every checker maps a file to the same target and isolation.

class Target(NamedTuple):
    """One target call of a Package.swift: its name, its folder and its default isolation."""
    name: str
    path: str  # the folder relative to the package root: `path:`, else Sources/<name> (Tests/<name> for a test)
    main: bool  # main actor by default: its swiftSettings name uiSwiftSettings or `.defaultIsolation(MainActor.self)`


# A target call: `.target(`, `.executableTarget(`, `.testTarget(`, `.macro(` (also `Target.target(`).
TARGET_CALL = re.compile(r"(?<![\w.])(?:Target)?\.(target|executableTarget|testTarget|macro)\s*\(")
MAIN_SETTINGS = re.compile(r"\buiSwiftSettings\b|\.defaultIsolation\(\s*MainActor\.self\s*\)")
_STRING_OPEN = re.compile(r'(#*)("""|")')
_ARGUMENT_LABEL = re.compile(r"\s*([A-Za-z_]\w*)\s*:")
_PLAIN_LITERAL = re.compile(r'"([^"\\]*)"')


def mask_code(text: str) -> str:
    """TEXT with comments and string-literal contents blanked (same length; line breaks and quote delimiters
    kept), so the parentheses, brackets and commas left are code.

    Handles nested block comments, multi-line and raw (`#"..."#`) strings, and strings inside `\\( ... )`
    interpolations.
    """
    n, out = len(text), list(text)

    def blank(start: int, end: int) -> None:
        for k in range(start, min(end, n)):
            if out[k] != "\n":
                out[k] = " "

    def comment_end(i: int) -> int:
        if text.startswith("//", i):
            j = text.find("\n", i)
            return n if j < 0 else j
        depth, j = 1, i + 2
        while j < n and depth:
            if text.startswith("/*", j):
                depth, j = depth + 1, j + 2
            elif text.startswith("*/", j):
                depth, j = depth - 1, j + 2
            else:
                j += 1
        return j

    def string_end(literal: re.Match) -> tuple[int, int]:
        """(end of the contents, end of the closing delimiter) of the literal LITERAL opens."""
        hashes, quotes = literal.groups()
        close, escape, j = quotes + hashes, "\\" + hashes, literal.end()
        while j < n:
            if text.startswith(escape + "(", j):
                j = interpolation_end(j + len(escape) + 1)
            elif text.startswith(escape, j):
                j += len(escape) + 1
            elif text.startswith(close, j):
                return j, j + len(close)
            elif quotes == '"' and text[j] == "\n":
                return j, j  # an unterminated one-line literal ends at its line break
            else:
                j += 1
        return n, n

    def interpolation_end(j: int) -> int:
        depth = 1
        while j < n and depth:
            if text.startswith(("//", "/*"), j):
                j = comment_end(j)
            elif (literal := _STRING_OPEN.match(text, j)) is not None:
                j = string_end(literal)[1]
            else:
                depth += (text[j] == "(") - (text[j] == ")")
                j += 1
        return j

    i = 0
    while i < n:
        if text.startswith(("//", "/*"), i):
            j = comment_end(i)
            blank(i, j)
            i = j
        elif (literal := _STRING_OPEN.match(text, i)) is not None:
            contents, i = string_end(literal)
            blank(literal.end(), contents)
        else:
            i += 1
    return "".join(out)


def _closing(masked: str, opening: int) -> int:
    """The index of the `)` that closes the `(` at OPENING in MASKED, or len(MASKED) when none does."""
    depth = 0
    for k in range(opening, len(masked)):
        if masked[k] in "([{":
            depth += 1
        elif masked[k] in ")]}":
            depth -= 1
            if depth == 0:
                return k
    return len(masked)


def _arguments(masked: str, start: int, end: int) -> dict[str, tuple[int, int]]:
    """{label: (start, end) of its value} for the top-level labeled arguments in MASKED[START:END]."""
    args: dict[str, tuple[int, int]] = {}
    depth, segment = 0, start
    for k in range(start, end + 1):
        c = masked[k] if k < end else ","
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            label = _ARGUMENT_LABEL.match(masked, segment, k)
            if label is not None:
                args.setdefault(label.group(1), (label.end(), k))
            segment = k + 1
    return args


def package_targets(manifest: str) -> list[Target]:
    """Every target of a Package.swift text, each read from its own call only.

    A target call is read by balanced parentheses in the manifest with comments and string contents
    masked, so a target with no swiftSettings is nonisolated by default (it never takes the next target's
    settings), and a `.target(name:)` dependency inside a target's call is not a target. A call whose name is
    not a plain string literal is skipped.
    """
    masked = mask_code(manifest)
    targets: list[Target] = []
    position = 0
    while (call := TARGET_CALL.search(masked, position)) is not None:
        end = _closing(masked, call.end() - 1)
        args = _arguments(masked, call.end(), end)
        position = end + 1

        def literal(label: str) -> str | None:
            if label not in args:
                return None
            start, stop = args[label]
            value = _PLAIN_LITERAL.fullmatch(manifest[start:stop].strip())
            return None if value is None else value.group(1)

        name = literal("name")
        if name is None:
            continue
        folder = literal("path") or f"{'Tests' if call.group(1) == 'testTarget' else 'Sources'}/{name}"
        settings = masked[slice(*args["swiftSettings"])] if "swiftSettings" in args else ""
        targets.append(Target(name, posixpath.normpath(folder), MAIN_SETTINGS.search(settings) is not None))
    return targets


class Dependency(NamedTuple):
    """One entry of a target's `dependencies:`: `.product(name:package:)` names its PACKAGE; `.target(name:)` is
    KIND `target`; a string literal or `.byName(name:)` is KIND `byName` (this package's target of that name, else
    the product of that name from the package of that name)."""
    kind: str  # product, target or byName
    name: str
    package: str | None = None


class PackageGraph(NamedTuple):
    """What a Package.swift links: each target's kind and dependencies, its library products and its path links."""
    kinds: dict[str, str]  # target name -> target, executableTarget, testTarget or macro
    dependencies: dict[str, list[Dependency]]  # target name -> its literal dependencies (a variable is skipped)
    libraries: dict[str, list[str]]  # library product name -> its targets (executable products link nothing)
    paths: dict[str, str]  # package identity, lowercased (the path's last component, or `name:`) -> its `path:`


PRODUCT_CALL = re.compile(r"(?<![\w.])(?:Product)?\.library\s*\(")
PATH_PACKAGE_CALL = re.compile(r"(?<![\w.])(?:Package\.Dependency)?\.package\s*\(")
DEPENDENCY_CALL = re.compile(r"\.(product|target|byName)\s*\(")


def _elements(masked: str, start: int, end: int) -> list[tuple[int, int]]:
    """The (start, end) of each top-level element of the array literal in MASKED[START:END] (none if no `[`),
    without the whitespace and comments around it."""
    opening = masked.find("[", start, end)
    if opening < 0:
        return []
    closing = _closing(masked, opening)
    found, depth, segment = [], 0, opening + 1
    for k in range(opening + 1, closing + 1):
        c = masked[k]
        if c in "([{":
            depth += 1
        elif c in ")]}" and depth > 0:
            depth -= 1
        elif (c == "," and depth == 0) or k == closing:
            element = masked[segment:k]
            if element.strip():
                found.append((segment + len(element) - len(element.lstrip()), segment + len(element.rstrip())))
            segment = k + 1
    return found


def package_graph(manifest: str) -> PackageGraph:
    """The PackageGraph of a Package.swift text, each call read alone by balanced parentheses with comments and
    string contents masked, as package_targets() reads targets. Only plain string literals count."""
    masked = mask_code(manifest)

    def literals(start: int, end: int) -> dict[str, str]:
        found = {}
        for label, (a, b) in _arguments(masked, start, end).items():
            value = masked[a:b]  # its own text without the whitespace and comments around it
            value = _PLAIN_LITERAL.fullmatch(manifest[a + len(value) - len(value.lstrip()):a + len(value.rstrip())])
            if value is not None:
                found[label] = value.group(1)
        return found

    def calls(pattern: re.Pattern) -> list[tuple[re.Match, int]]:
        found, position = [], 0
        while (call := pattern.search(masked, position)) is not None:
            end = _closing(masked, call.end() - 1)
            found.append((call, end))
            position = end + 1
        return found

    graph = PackageGraph({}, {}, {}, {})
    for call, end in calls(TARGET_CALL):
        args = _arguments(masked, call.end(), end)
        name = literals(call.end(), end).get("name")
        if name is None:
            continue
        graph.kinds[name] = call.group(1)
        dependencies = graph.dependencies.setdefault(name, [])
        for a, b in _elements(masked, *args["dependencies"]) if "dependencies" in args else []:
            if (plain := _PLAIN_LITERAL.fullmatch(manifest[a:b])) is not None:
                dependencies.append(Dependency("byName", plain.group(1)))
            elif (inner := DEPENDENCY_CALL.match(masked, a)) is not None:
                values = literals(inner.end(), _closing(masked, inner.end() - 1))
                if "name" in values:
                    dependencies.append(Dependency(inner.group(1), values["name"], values.get("package")))
    for call, end in calls(PRODUCT_CALL):
        args = _arguments(masked, call.end(), end)
        name = literals(call.end(), end).get("name")
        if name is not None and "targets" in args:
            graph.libraries[name] = [plain.group(1) for a, b in _elements(masked, *args["targets"])
                                     if (plain := _PLAIN_LITERAL.fullmatch(manifest[a:b])) is not None]
    for call, end in calls(PATH_PACKAGE_CALL):
        values = literals(call.end(), end)
        if "path" in values:
            for identity in {posixpath.basename(posixpath.normpath(values["path"])), values.get("name")} - {None}:
                graph.paths[identity.lower()] = values["path"]
    return graph


def default_isolation(relative: str, targets: list[Target]) -> bool | None:
    """Whether the file at RELATIVE (relative to the package root, `/`-separated) is in a target that is main
    actor by default; None when no target's folder holds it. The deepest folder wins."""
    best: Target | None = None
    for target in targets:
        if relative.startswith(target.path + "/") and (best is None or len(target.path) > len(best.path)):
            best = target
    return None if best is None else best.main


def allowed(lines: list[str], index: int) -> bool:
    if ALLOW.search(lines[index]):
        return True
    j = index - 1
    while j >= 0 and COMMENT_ONLY.match(lines[j]):
        if ALLOW.search(lines[j]):
            return True
        j -= 1
    return False


def strip(line: str) -> str:
    code = STRING_LITERAL.sub('""', line) if '"' in line else line
    return code.split("//", 1)[0] if "//" in code else code


def main_actor_lines(lines: list[str], default_main: bool) -> list[bool]:
    """Whether each line is main-actor code, by lexical scope (brace depth).

    The innermost enclosing `nonisolated` / `@concurrent` declaration, `actor`,
    `Task.detached` or global-queue closure makes a scope off-main; an
    `@MainActor` declaration makes it main; otherwise the target default holds.
    """
    return [main for main, _ in main_actor_scopes(lines, default_main)]


# A type that takes its isolation from what it inherits: AppKit's views, view and window controllers, windows and
# responders and SwiftUI's View, App and Scene are `@MainActor`, so their subclasses, conformers and extensions
# are main actor in any target.
UI_BASE = re.compile(r"NS\w*(View|ViewController|WindowController|Window|Responder)|View|App|Scene")
# A declaration header: its kind, its name and its inheritance clause, which ends at `where` (a constraint such as
# `where T: View` gives the type no isolation) or at the body's `{`.
TYPE_HEADER = re.compile(r"\b(class|struct|extension)\s+((?:\w+\.)*\w+)\s*(?:<[^{]*?>)?\s*"
                         r"(?::((?:(?!\bwhere\b)[^{])*))?")
INHERITED_NAME = re.compile(r"\b(?:\w+\.)*(\w+)\b")
BRACES = re.compile(r"[{}]")


def no_ui_type(name: str) -> bool:
    return False


class TypeHeader(NamedTuple):
    kind: str  # class, struct or extension
    name: str  # the last component (`extension NSView.Foo` -> Foo)
    inherited: list[str]  # the inheritance clause's names, before any `where`


def type_header(code: str) -> TypeHeader | None:
    """The class, struct or extension CODE (strip()ped) declares, if any."""
    header = TYPE_HEADER.search(code)
    if header is None:
        return None
    kind, name, clause = header.groups()
    return TypeHeader(kind, name.rsplit(".", 1)[-1], INHERITED_NAME.findall(clause) if clause else [])


def type_headers(lines: list[str]) -> list[TypeHeader]:
    """type_header() of each code line of LINES that declares a class, struct or extension, in order."""
    found = []
    for raw in lines:
        if ("class" in raw or "struct" in raw or "extension" in raw) and not COMMENT_ONLY.match(raw):
            if (header := type_header(strip(raw))) is not None:
                found.append(header)
    return found


def inherits_ui(header: TypeHeader, ui_type: Callable[[str], bool]) -> bool:
    """Whether HEADER's type takes AppKit's or SwiftUI's main actor: `class Pane: NSView`, `struct Row: Equatable,
    View`, `extension NSView`, `extension View`, or a subclass or extension of a type UI_TYPE accepts (a first-party
    UI subclass: `extension TerminalView` in TerminalView+Drag.swift). Only a class inherits a first-party UI type:
    a struct's or extension's clause lists protocols."""
    if header.kind == "extension" and (UI_BASE.fullmatch(header.name) or ui_type(header.name)):
        return True
    if header.kind == "class":
        return any(UI_BASE.fullmatch(name) or ui_type(name) for name in header.inherited)
    return any(UI_BASE.fullmatch(name) for name in header.inherited)


def ui_subclasses(headers: list[TypeHeader], ui_type: Callable[[str], bool] = no_ui_type) -> set[str]:
    """The names of the classes and structs HEADERS (type_headers) declare that inherits_ui() makes main actor, in
    declaration order (a subclass of an earlier one counts): an index of first-party UI types for their
    extensions."""
    found: set[str] = set()
    for header in headers:
        if header.kind != "extension" and header.inherited \
                and inherits_ui(header, lambda name: name in found or ui_type(name)):
            found.add(header.name)
    return found


def main_actor_scopes(lines: list[str], default_main: bool, ui_types: bool = False,
                      ui_type: Callable[[str], bool] = no_ui_type) -> list[tuple[bool, int]]:
    """main_actor_lines(), each with the 1-based line that set its isolation (0: the target default).

    With UI_TYPES, a type that inherits AppKit's or SwiftUI's isolation (inherits_ui) is main actor too: a subclass
    or conformer, an extension of an AppKit or SwiftUI UI type, and a subclass or extension of a UI type this file
    declares (ui_subclasses) or UI_TYPE accepts (the revision's first-party UI types in other files).
    """
    if ui_types:
        local = ui_subclasses(type_headers(lines), ui_type)

        def known(name: str) -> bool:
            return name in local or ui_type(name)
    result: list[tuple[bool, int]] = []
    stack: list[tuple[int, bool, int]] = []
    depth = 0
    pending: bool | None = None  # isolation of a declaration whose `{` has not opened yet
    source = 0  # the line that set PENDING
    for number, raw in enumerate(lines, 1):
        if COMMENT_ONLY.match(raw):
            result.append(stack[-1][1:] if stack else (default_main, 0))
            continue
        code = strip(raw)
        # The substring tests are OFF_MAIN's and MAIN's literals: most lines skip both regex scans.
        if ("actor" in code or "nonisolated" in code or "@concurrent" in code or "Task.detached" in code
                or "DispatchQueue" in code) and OFF_MAIN.search(code):
            pending, source = False, number
        elif ("@MainActor" in code and MAIN.search(code)) or (
                ui_types and ("class" in code or "struct" in code or "extension" in code)
                and (header := type_header(code)) is not None and inherits_ui(header, known)):
            pending, source = True, number
        scope = stack[-1][1:] if stack else (default_main, 0)
        result.append(scope if pending is None else (pending, source))
        for char in BRACES.findall(code) if "{" in code or "}" in code else ():
            if char == "{":
                depth += 1
                if pending is not None:
                    stack.append((depth, pending, source))
                    pending = None
            elif char == "}":
                while stack and stack[-1][0] >= depth:
                    stack.pop()
                depth -= 1
        # An attribute line, or a declaration header split over lines, carries
        # its isolation to the `{` that opens the body; anything else drops it.
        if pending is not None and "{" not in code and not ATTRIBUTE_ONLY.match(code):
            if not code.rstrip().endswith((",", "(", "->")) and not DECL_KEYWORD.search(code):
                pending = None
    return result


# The start of an unstructured Task (TASK_INIT, then its closure); `Task.detached` is off-main (OFF_MAIN).
TASK_START = re.compile(TASK_INIT + r"\s*\{")


def main_inherited_tasks(lines: list[str], default_main: bool,
                         scopes: list[tuple[bool, int]] | None = None,
                         ui_type: Callable[[str], bool] = no_ui_type) -> list[tuple[int, int]]:
    """The Tasks that run on the main actor, as (0-based line, 1-based line that set its isolation, 0: the target
    default): `Task { @MainActor in` anywhere, and a plain `Task {` whose scope is main actor (an annotation, a
    uiSwiftSettings target's default, or a type that inherits AppKit's or SwiftUI's isolation).

    The one definition for the pre-push guardrail main-hop (guardrails.py) and the arch ratchet's
    main_inherited_tasks row (plans/cmux-next/chrome-parity/p06-scheduler.md, Q1 + Q1b): a Task in main-actor code
    stays counted when its `@MainActor in` is deleted. Lexical, so a heuristic: a `@Sendable` closure between the
    scope and the Task reads as the scope. SCOPES: main_actor_scopes(lines, default_main, ui_types=True), when the
    caller has it already; UI_TYPE: the first-party UI types of other files (main_actor_scopes).
    """
    scopes = scopes if scopes is not None else main_actor_scopes(lines, default_main, ui_types=True, ui_type=ui_type)
    found = []
    for index, raw in enumerate(lines):
        if COMMENT_ONLY.match(raw) or not TASK_START.search(code := strip(raw)):
            continue
        if MAIN_TASK.search(code):  # `nonisolated func f() { Task { @MainActor in ... } }`: the line's own scope is off
            found.append((index, index + 1))
        elif scopes[index][0]:
            found.append((index, scopes[index][1]))
    return found


ATTRIBUTE_ONLY = re.compile(r"^\s*((@\w+(\([^)]*\))?|nonisolated)\s*)+$")
DECL_KEYWORD = re.compile(r"\b(func|init|var|class|struct|enum|extension|actor)\b")


def scan_file(path: str, default_main: bool) -> list[tuple[int, str, str]]:
    """(line number, rule, source line) for every main-actor hit."""
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    main_lines = main_actor_lines(lines, default_main)
    hits: list[tuple[int, str, str]] = []
    # Any isolation: the callback itself may run anywhere; the Task lands on main.
    for index, raw in enumerate(lines):
        if COMMENT_ONLY.match(raw) or allowed(lines, index) or not MAIN_TASK.search(strip(raw)):
            continue
        window = lines[max(0, index - PER_LINE_WINDOW):index + 1]
        if any(PER_LINE_CALLBACK.search(strip(line)) for line in window):
            hits.append((index + 1, PER_LINE_RULE, raw.strip()))
    loop_until = -1
    for index, raw in enumerate(lines):
        if COMMENT_ONLY.match(raw) or not main_lines[index] or allowed(lines, index):
            continue
        code = strip(raw)
        for name, rx in RULES:
            if rx.search(raw if name == "line split of a whole input" else code):
                hits.append((index + 1, name, raw.strip()))
        if LOOP.search(code):
            loop_until = index + LOOP_WINDOW
        if index <= loop_until and SCAN.search(raw):
            hits.append((index + 1, LOOP_RULE, raw.strip()))
            loop_until = -1
    return hits


def collect(root: str) -> dict[str, dict[str, list[tuple[int, str]]]]:
    package_root = os.path.join(root, PACKAGE)
    sources = os.path.join(package_root, "Sources")
    with open(os.path.join(package_root, "Package.swift"), encoding="utf-8") as handle:
        targets = package_targets(handle.read())
    result: dict[str, dict[str, list[tuple[int, str]]]] = {}
    for dirpath, _, files in os.walk(sources):
        for filename in sorted(files):
            if not filename.endswith(".swift"):
                continue
            path = os.path.join(dirpath, filename)
            relative = os.path.relpath(path, root).replace(os.sep, "/")
            in_package = os.path.relpath(path, package_root).replace(os.sep, "/")
            for line, rule, text in scan_file(path, default_isolation(in_package, targets) is True):
                result.setdefault(relative, {}).setdefault(rule, []).append((line, text))
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=None)
    parser.add_argument("--update-baseline", action="store_true")
    parser.add_argument("--list", action="store_true", help="print every hit, not only the ratchet result")
    args = parser.parse_args()
    root = args.root or subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                                       check=True).stdout.strip()
    hits = collect(root)
    counts = {f: {r: len(v) for r, v in rules.items()} for f, rules in sorted(hits.items())}
    baseline_path = os.path.join(root, BASELINE)
    if args.update_baseline:
        with open(baseline_path, "w", encoding="utf-8") as handle:
            json.dump(counts, handle, indent=1, sort_keys=True)
            handle.write("\n")
        total = sum(sum(r.values()) for r in counts.values())
        print(f"check-main-actor-work: baseline written ({total} hits in {len(counts)} files)")
        return 0
    if args.list:
        for f, rules in sorted(hits.items()):
            for rule, items in sorted(rules.items()):
                for line, text in items:
                    print(f"{f}:{line}: {rule}: {text}")
    baseline = json.load(open(baseline_path, encoding="utf-8")) if os.path.exists(baseline_path) else {}
    failures = 0
    lowered = 0
    for f, rules in counts.items():
        for rule, count in rules.items():
            allowed_count = baseline.get(f, {}).get(rule, 0)
            if count > allowed_count:
                failures += 1
                print(f"main-actor-work violation: {f}: {rule}: {count} hit(s), baseline {allowed_count}")
                for line, text in hits[f][rule]:
                    print(f"    {f}:{line}: {text}")
    for f, rules in baseline.items():
        for rule, allowed_count in rules.items():
            if counts.get(f, {}).get(rule, 0) < allowed_count:
                lowered += 1
    if failures:
        print(f"check-main-actor-work: {failures} violation(s): new main-actor hot spots. Move the work off the main actor "
              "(nonisolated type, @concurrent function, actor, or the Rust daemon), or add a reviewed "
              "`// main-actor-ok: <reason>` when its input is provably small.")
        return 1
    if lowered:
        print(f"check-main-actor-work: ok; {lowered} count(s) fell below the baseline: run "
              "scripts/cmux-next/check-main-actor-work.py --update-baseline and commit it.")
        return 0
    print("check-main-actor-work: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())

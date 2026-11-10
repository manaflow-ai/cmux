#!/usr/bin/env python3
"""check-concurrency.sh's caller-isolated blocking rule: no blocking call in an async function that runs on
its caller's actor.

Every CmuxNext target enables `NonisolatedNonsendingByDefault` (Package.swift), so a `nonisolated` async
function (any async function outside an actor or a global actor, `static` ones in an actor too) runs on the
actor of whoever awaits it. Awaited from main-actor code, its synchronous stretches run on the main thread.
`ProcessRunner.run` was one: `public static func ... async` in a plain struct, its stdin pipe write held the
NIGHTLY main thread in write(2) for 391 s when Cloud's spare warm awaited it from the main actor (2026-11-09).
And in a main-actor-default (uiSwiftSettings) target an unannotated async function is main-actor outright.

So a blocking call (a wait, a sleep, a raw FileHandle read or write, a Process launch or wait, or a checked
`blocking*` seam from CmuxNextCompat/Threading) whose innermost enclosing function is `async` must say where
it runs: mark the function `@concurrent`, or move the call into `work.run(_, mayBlock: ...)` (BackgroundWork).
An actor's own methods, another global actor's, `@concurrent` ones and closures handed to someone else
(`Task.detached`, a queue, `work.run`) are off the caller's actor; a sync function is the existing rules'.

The escape is this rule's own, `// caller-isolation-allow: <reason>`, on the line or the comment block above:
a `// concurrency-allow:` there says why a call is safe off the main thread, and this rule is about that
assumption. A file listed in caller-isolated-blocking-pending.json may keep up to its listed count (shrink
only); see skills/cmux-architecture/references/main-thread-model.md.
"""
from __future__ import annotations

import re
from typing import NamedTuple

RULE = ("blocking call in a caller-isolated async function (NonisolatedNonsendingByDefault: awaited from the "
        "main actor, it runs on the main thread); mark the function @concurrent, or move the call into "
        "work.run(_, mayBlock: .files/.system/.cpu)")
ESCAPE = re.compile(r"//\s*caller-isolation-allow:\s*\S")
COMMENT_LINE = re.compile(r"^\s*(//|\*|/\*)")

# Blocking calls beyond check-concurrency.sh's EVERYWHERE rules, which it passes in as well.
EXTRA_BLOCKING = [
    re.compile(r"\.write\(contentsOf:"),
    re.compile(r"\bfileHandleForWriting\.write\("),
    re.compile(r"\.read\(upToCount:"),
    re.compile(r"\breadToEnd\(\)"),
    re.compile(r"\b\w*([pP]rocess|[cC]hild)\.run\(\)"),
    re.compile(r"\bwaitUntilExit\("),
    # CmuxNextCompat/Threading's checked seams: they record (DEV traps) on the main thread.
    re.compile(r"(?<!func )\bblocking(Write|Read\w*|AvailableData|Recv|Send|Wait\w*|Run|Sync|PosixSpawn"
               r"|XPCSendWithReply|ResourceValues)\s*\("),
]

# An awaited call suspends, it does not block (`try await backoff.wait(owner:)`).
AWAITED = re.compile(r"\bawait\s+(try\s+)?[\w.?!\[\]]*$")
DECL = re.compile(r"\b(func|init|subscript|deinit)\b")
TYPE_DECL = re.compile(r"(?:^|[\s)])(?:(?:final|public|internal|package|private|fileprivate|open|indirect|"
                       r"distributed)\s+)*(class|struct|enum|actor|extension|protocol)\s+[A-Za-z_]")
CONTROL = re.compile(r"^\s*(\}\s*)?(if|guard|for|while|do|catch|switch|else|defer|repeat|case|default)\b")
ACCESSOR = re.compile(r"^\s*(get|set|willSet|didSet|_modify|_read)\b")
CONTINUATION_START = re.compile(r"^\s*(\.|&&|\|\||\)|->|where\b|async\b|throws\b|rethrows\b|\?\?|:)")
CONTINUATION_END = re.compile(r"(,|\(|\[|=|&&|\|\||->|:|\.)\s*$")
ATTRIBUTE_ONLY = re.compile(r"^\s*((@\w+(\((?:[^()]|\([^()]*\))*\))?|nonisolated(\(\w+\))?)\s*)+$")
# Closures that run inline, on the caller's executor: the enclosing function's isolation holds inside them.
INLINE_CLOSURE = re.compile(r"\b(with(Checked|Unsafe)(Throwing)?Continuation|withTaskCancellationHandler|"
                            r"operation:|withLock|withValue|withValueInTask|withExtendedLifetime|"
                            r"withUnsafe\w*|map|compactMap|flatMap|forEach|filter|reduce|sorted|first|contains|"
                            r"allSatisfy|lazy|autoreleasepool|assumeIsolated)\s*(\([^{]*\))?\s*$")
GLOBAL_ACTOR = re.compile(r"@(?!MainActor\b)[A-Z]\w*Actor\b")


class Scope(NamedTuple):
    kind: str  # "type", "func", "closure", "block"
    isolation: str  # type: main/actor/other/none; func: main/caller/off/sync; closure: inline/off


def _top_level_start(code: str, depth: int) -> tuple[int, int]:
    """Scanning CODE backward with DEPTH open `)`s: (where the statement starts on it, -1 when it goes on
    above; the depth at its start). A `{`, `}` or `;` outside parentheses ends the statement before it."""
    for pos in range(len(code) - 1, -1, -1):
        char = code[pos]
        if char in ")]":
            depth += 1
        elif char in "([":
            depth -= 1
        elif char in "{};" and depth <= 0:
            return pos + 1, depth
    return -1, depth


def _statement_header(masked_lines: list[str], line: int, column: int) -> str:
    """The code of the statement a `{` at (LINE, COLUMN) opens: from its first line to the brace. Braces in
    parentheses (a default closure argument) do not end it."""
    start, depth = _top_level_start(masked_lines[line][:column], 0)
    parts = [masked_lines[line][:column][max(start, 0):]]
    j = line
    while start < 0 and j > 0:
        above = masked_lines[j - 1]
        j -= 1
        if not above.strip():
            # A blank line, or a comment line (masked blank) inside a parameter list: look past it.
            continue
        inside = depth > 0
        joins = inside or CONTINUATION_END.search(above) or CONTINUATION_START.match(parts[0]) \
            or ATTRIBUTE_ONLY.match(above)
        if not joins:
            break
        start, depth = _top_level_start(above, depth)
        parts.insert(0, above[max(start, 0):])
    return "\n".join(parts)


def _effects_async(signature: str) -> bool:
    """Whether the declaration SIGNATURE (from `func`/`init`/`subscript`) is async: `async` or `reasync` right
    after its parameter list, not inside a parameter's or the result's closure type."""
    opening = signature.find("(")
    if opening < 0:
        return False
    depth = 0
    for pos in range(opening, len(signature)):
        depth += (signature[pos] in "([") - (signature[pos] in ")]")
        if depth == 0:
            return re.match(r"\s*(async|reasync)\b", signature[pos + 1:]) is not None
    return False


TASK_CLOSURE = re.compile(r"\bTask\s*(\(\s*(priority:[^{]*)?\))?\s*$")
MAIN_CLOSURE = re.compile(r"\bMainActor\.run\s*(\([^{]*\))?\s*$")


def _classify(header: str, enclosing: list[Scope], default_type: str, actors: set[str]) -> Scope:
    """The scope a `{` opens, from the statement header before it and the scopes around it."""
    text = " ".join(header.split())
    owner = next((s.isolation for s in reversed(enclosing) if s.kind == "type"), default_type)
    decl = None
    for match in DECL.finditer(text):
        decl = match
    type_match = TYPE_DECL.search(text)
    if decl is not None and not (type_match and type_match.start() > decl.start()):
        before, signature = text[:decl.start()], text[decl.start():]
        if not _effects_async(signature):
            return Scope("func", "sync")
        if "@concurrent" in before:
            return Scope("func", "off")
        if "@MainActor" in before:
            return Scope("func", "main")
        if GLOBAL_ACTOR.search(before):
            return Scope("func", "off")
        if re.search(r"\bnonisolated\b", before) or re.search(r"\bisolated\b", signature):
            return Scope("func", "caller")
        if owner == "actor":
            # An actor's static members are not isolated to an instance: they run on the caller's actor.
            return Scope("func", "caller" if re.search(r"\b(static|class)\b", before) else "off")
        if owner == "other":
            return Scope("func", "off")
        return Scope("func", "main" if owner == "main" else "caller")
    if type_match is not None:
        kind = type_match.group(1)
        before = text[:type_match.start(1)]
        if kind == "actor":
            return Scope("type", "actor")
        if "@MainActor" in before:
            return Scope("type", "main")
        if GLOBAL_ACTOR.search(before):
            return Scope("type", "other")
        if re.search(r"\bnonisolated\b", before):
            return Scope("type", "none")
        if kind == "extension":
            name = re.search(r"\bextension\s+([A-Za-z_][\w.]*)", text)
            if name and name.group(1).split(".")[-1] in actors:
                return Scope("type", "actor")
            return Scope("type", default_type)
        return Scope("type", owner)
    if CONTROL.match(text) or not text.strip():
        return Scope("block", "")
    if ACCESSOR.match(text):
        return Scope("func", "caller" if re.search(r"\basync\b", text) and owner != "actor" else "sync")
    if MAIN_CLOSURE.search(text):
        return Scope("func", "main")
    if TASK_CLOSURE.search(text):
        # `Task { }` inherits a main-actor context's isolation; from a caller-isolated one it runs on the
        # global executor (counted as off the caller).
        return Scope("closure", "task")
    if INLINE_CLOSURE.search(text):
        return Scope("closure", "inline")
    return Scope("closure", "off")


def _runs_on_caller(stack: list[Scope]) -> bool:
    """Whether code in the innermost scope of STACK runs on the caller's actor or the main actor."""
    in_task = False
    for scope in reversed(stack):
        if scope.kind == "block" or (scope.kind == "closure" and scope.isolation == "inline"):
            continue
        if scope.kind == "closure" and scope.isolation == "task":
            in_task = True
            continue
        if scope.kind == "type":
            # A Task at type scope (a stored property's initializer) takes the type's isolation.
            return in_task and scope.isolation == "main"
        if in_task:
            return scope.kind == "func" and scope.isolation == "main"
        return scope.kind == "func" and scope.isolation in ("caller", "main")
    return False


ACTOR_DECL = re.compile(r"\bactor\s+([A-Za-z_]\w*)")


def actor_names(masked_texts) -> set[str]:
    """The names of the actors declared in MASKED_TEXTS (so `extension Name` is read as actor-isolated)."""
    return {name for text in masked_texts for name in ACTOR_DECL.findall(text)}


def caller_isolated_spans(masked_text: str, default_main: bool, actors: set[str] = frozenset()) -> list[list[tuple[int, bool]]]:
    """For each line, where its code runs on its caller's actor or the main actor in an async function, by
    lexical scope over MASKED_TEXT (comments and string contents blanked): (column, runs on the caller) at
    column 0 and after each brace, so a one-line `Task.detached { ... }` is off the caller inside its braces."""
    masked_lines = masked_text.split("\n")
    default_type = "main" if default_main else "none"
    result = []
    stack: list[Scope] = []
    for number, code in enumerate(masked_lines):
        spans = [(0, _runs_on_caller(stack))]
        for column, char in enumerate(code):
            if char == "{":
                stack.append(_classify(_statement_header(masked_lines, number, column), stack, default_type, actors))
            elif char == "}" and stack:
                stack.pop()
            else:
                continue
            spans.append((column + 1, _runs_on_caller(stack)))
        result.append(spans)
    return result


def _at(spans: list[tuple[int, bool]], column: int) -> bool:
    state = spans[0][1]
    for start, value in spans:
        if start > column:
            break
        state = value
    return state


def hits(lines: list[str], masked_text: str, default_main: bool, blocking: list[re.Pattern],
         actors: set[str] = frozenset()) -> list[int]:
    """0-based indexes of the lines of a file with a blocking call in a caller-isolated async function."""
    scoped = caller_isolated_spans(masked_text, default_main, actors)
    out = []
    for index, code in enumerate(masked_text.split("\n")):
        spans = scoped[index]
        if not any(on for _, on in spans) or COMMENT_LINE.match(lines[index]):
            continue
        if not any(_at(spans, match.start()) and not AWAITED.search(code[:match.start()])
                   for rx in list(blocking) + EXTRA_BLOCKING for match in rx.finditer(code)):
            continue
        if _escaped(lines, index):
            continue
        out.append(index)
    return out


def _escaped(lines: list[str], index: int) -> bool:
    if ESCAPE.search(lines[index]):
        return True
    j = index - 1
    while j >= 0 and COMMENT_LINE.match(lines[j]):
        if ESCAPE.search(lines[j]):
            return True
        j -= 1
    return False

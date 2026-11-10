#!/usr/bin/env python3
"""No `withLock` on a lock whose value is a closure (issue #40144).

`Mutex.withLock` (CmuxNextCompat's, CmuxDeviceHub's, `Synchronization.Mutex`) and
`OSAllocatedUnfairLock.withLock` hand their body the value `inout` at the generic
abstraction. When the value is a function type, an optional one, or a tuple holding
one, Swift converts the stored closure to the body's form and writes the converted
closure back: every `withLock` wraps the stored handler in two more reabstraction
thunks, in Debug and Release alike. The main-thread watchdog read its `onStall`
handler that way once per stall; after ~37,000 stalls one call recursed 74,661
frames deep and overflowed the main thread's stack (cmux-next nightly 85b0999).

A struct or an array holding the closure is a nominal type and is not converted, so
it does not grow. Read a closure with `load()` and write it with `store(_:)`
(CmuxNextCompat's Mutex), or keep it in a small struct.

Scans every `Sources/` directory under the given roots (default: Packages/). A
reviewed exception carries `// closure-mutex-allow: <reason>` on the line or the
comment line directly above. Exit 1 with one line per finding.

Usage: check-closure-mutex.py [ROOT ...]
"""
import os
import re
import sys

LOCKS = r"(?:Mutex|OSAllocatedUnfairLock)"
ALLOW = re.compile(r"//\s*closure-mutex-allow:\s*\S")
COMMENT_ONLY = re.compile(r"^\s*(//|\*|/\*)")
# `typealias Sink = @Sendable (Int) -> Void` (a function type, maybe with attributes).
FUNCTION_ALIAS = re.compile(r"\btypealias\s+(\w+)(?:<[^>]*>)?\s*=\s*((?:@\w+(?:\([^)]*\))?\s+)*\(.*)$")


def generic_argument(text, start):
    """The text between the `<` at `start` and its matching `>` (a `->` is not a closer)."""
    depth = 0
    i = start
    while i < len(text):
        ch = text[i]
        if ch == "-" and text.startswith("->", i):
            i += 2
            continue
        if ch in "<([":
            depth += 1
        elif ch in ">)]":
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
        i += 1
    return None


def strip_outer(type_text):
    """`type_text` without attributes, a trailing `?`/`!` and redundant outer parentheses."""
    t = type_text.strip()
    while True:
        before = t
        t = re.sub(r"^(?:@\w+(?:\([^)]*\))?\s+)+", "", t).strip()
        if t.endswith("?") or t.endswith("!"):
            t = t[:-1].strip()
        if t.startswith("(") and t.endswith(")") and matching_paren(t, 0) == len(t) - 1:
            inner = t[1:-1]
            if top_level_split(inner, ",") == [inner] and not re.match(r"^\s*\w+\s*:", inner):
                t = inner.strip()
        if t == before:
            return t


def matching_paren(text, start):
    depth = 0
    for i in range(start, len(text)):
        if text[i] in "([<":
            depth += 1
        elif text[i] in ")]>" and not (text[i] == ">" and i > 0 and text[i - 1] == "-"):
            depth -= 1
            if depth == 0:
                return i
    return -1


def top_level_split(text, sep):
    parts, depth, last = [], 0, 0
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "-" and text.startswith("->", i):
            i += 2
            continue
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
        elif ch == sep and depth == 0:
            parts.append(text[last:i])
            last = i + 1
        i += 1
    parts.append(text[last:])
    return parts


def is_top_level_function(t):
    """True when `t` (stripped) is a function type: a `(...)` parameter list followed by `->`."""
    if not t.startswith("("):
        return False
    close = matching_paren(t, 0)
    if close < 0:
        return False
    rest = t[close + 1:].strip()
    rest = re.sub(r"^(?:async\s+)?(?:throws(?:\([^)]*\))?\s+)?(?:rethrows\s+)?", "", rest)
    return rest.startswith("->")


def converts(type_text, aliases):
    """True when a lock holding `type_text` re-wraps it on every `withLock`: a function type, an optional
    one, a function typealias, or a tuple with such an element."""
    t = strip_outer(type_text)
    if t in aliases:
        return True
    if is_top_level_function(t):
        return True
    if t.startswith("(") and matching_paren(t, 0) == len(t) - 1:
        elements = top_level_split(t[1:-1], ",")
        if len(elements) > 1:
            for element in elements:
                element = re.sub(r"^\s*\w+\s*:", "", element)
                if converts(element, aliases):
                    return True
    return False


NOMINAL = re.compile(r"\b(?:struct|class|enum|actor|protocol)\s+(\w+)")


def file_aliases(text):
    """The function typealiases `text` declares."""
    names = set()
    for line in text.split("\n"):
        match = FUNCTION_ALIAS.search(line)
        if match and is_top_level_function(strip_outer(match.group(2).split("//", 1)[0])):
            names.add(match.group(1))
    return names


def function_aliases(texts):
    """The function typealias names a file may use: one declared in that file, or one declared elsewhere
    whose name no file also gives a struct, class, enum, actor or protocol (names are not module-scoped
    here, so an ambiguous name counts only in its own file)."""
    declared, nominal = set(), set()
    for text in texts.values():
        declared |= file_aliases(text)
        nominal |= set(NOMINAL.findall(text))
    return declared - nominal


def closure_locks(text, aliases):
    """{property name: declaration line number} of the locks in `text` that hold a closure."""
    found = {}
    for match in re.finditer(r"\b(?:let|var)\s+(\w+)\s*(?::\s*" + LOCKS + r"\s*(?=<)|=\s*" + LOCKS + r"\s*(?=<))", text):
        argument = generic_argument(text, match.end())
        if argument is not None and converts(argument, aliases):
            found[match.group(1)] = text.count("\n", 0, match.start()) + 1
    return found


def allowed(lines, index):
    if ALLOW.search(lines[index]):
        return True
    j = index - 1
    while j >= 0 and COMMENT_ONLY.match(lines[j]):
        if ALLOW.search(lines[j]):
            return True
        j -= 1
    return False


def check(roots):
    paths = []
    for root in roots:
        for dirpath, _, files in os.walk(root):
            if os.sep + "Sources" + os.sep not in dirpath + os.sep or os.sep + ".build" in dirpath:
                continue
            paths += [os.path.join(dirpath, name) for name in sorted(files) if name.endswith(".swift")]
    texts = {}
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            texts[path] = handle.read()
    shared_aliases = function_aliases(texts)
    findings = []
    for path in paths:
        text = texts[path]
        aliases = (shared_aliases - set(NOMINAL.findall(text))) | file_aliases(text)
        locks = closure_locks(text, aliases)
        if not locks:
            continue
        lines = text.split("\n")
        use = re.compile(r"\b(" + "|".join(map(re.escape, locks)) + r")\s*\.\s*withLock(IfAvailable)?\b")
        for index, line in enumerate(lines):
            if COMMENT_ONLY.match(line):
                continue
            match = use.search(line)
            if match and not allowed(lines, index):
                findings.append(f"{path}:{index + 1}: `{match.group(1)}.withLock` on a lock holding a closure re-wraps "
                                f"it on every call (#40144); use `{match.group(1)}.load()` / `.store(_:)`, or keep the "
                                "closure in a struct")
    return findings


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    roots = argv[1:] or [os.path.normpath(os.path.join(here, "..", "..", "Packages"))]
    findings = check(roots)
    for line in findings:
        print(f"closure-mutex: {line}")
    if findings:
        print(f"check-closure-mutex: {len(findings)} violation(s).")
        return 1
    print("check-closure-mutex: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

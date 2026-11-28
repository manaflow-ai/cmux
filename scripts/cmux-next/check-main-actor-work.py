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
reviewed exception carries `// main-actor-ok(NSView): <what it does>` on the line
or in the comment block directly above it, naming the AppKit (NS...) or Core
Animation (CA...) type it touches. An exception without one counts as a hit of
its own rule (UNTYPED_RULE), so the old untyped ones ratchet down to none.

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
from typing import NamedTuple

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
    # The encode half (2026-11-21, Leo's NIGHTLY: a page call's 512 KB `newTab.warm` parsed and written again with
    # sorted keys on the main actor). Encode off the main actor, or keep the text the sender made.
    ("JSON / property-list encode",
     re.compile(r"\bJSONSerialization\.data\(withJSONObject:|\bJSONEncoder\(\)|\bPropertyListEncoder\(\)"
                r"|\bPropertyListSerialization\.data\(fromPropertyList:")),
    # Sorting every object's keys costs a comparison sort per object: only where something reads the order or
    # compares the text (a digest, a dedupe), with `// main-actor-ok: <why the order is read>`.
    ("JSON encode with sorted keys",
     re.compile(r"\.sortedKeys\b")),
    ("directory walk",
     re.compile(r"\.enumerator\((at|atPath):|\.contentsOfDirectory\((at|atPath):|\.subpathsOfDirectory\(|\.subpaths\(atPath:")),
    ("process launch",
     re.compile(r"\bProcess\(\)|\bposix_spawn\(")),
    # Calls that wait on another process, the kernel or the disk: their time is not this code's to bound.
    # check-concurrency.sh refuses the waits, sleeps, locks, sync hops and file reads outright; these have no
    # checked seam yet, so they are ratcheted here (plans/cmux-next/main-thread-guarantee-DESIGN.md, layer 1).
    ("keychain call (securityd IPC; can wait on a prompt)",
     re.compile(r"\bSecItem(CopyMatching|Add|Update|Delete)\(|\bSecKeychain\w*\(")),
    ("trust evaluation (can fetch revocation over the network)",
     re.compile(r"\bSecTrustEvaluate(WithError)?\(")),
    ("Accessibility IPC (waits up to 6 s on an app that does not answer)",
     re.compile(r"\bAXUIElement(CopyAttributeValues?|CopyMultipleAttributeValues|CopyAttributeNames|SetAttributeValue"
                r"|PerformAction|CopyElementAtPosition|CopyParameterizedAttributeValue|CopyActionNames|IsAttributeSettable)\(")),
    ("window-server list query (CGWindowList*)",
     re.compile(r"\bCGWindowList(CopyWindowInfo|CreateImage|CreateImageFromArray|CreateDescriptionFromArray)\(")),
    ("DNS lookup",
     re.compile(r"\bgetaddrinfo\(|\bgethostbyname2?\(|\bgetnameinfo\(|\bCFHostStartInfoResolution\(")),
    ("child wait (waitpid blocks until the child exits)",
     re.compile(r"(?:^|[^.\w]|Darwin\.)(waitpid|wait4|waitid)\(")),
    ("fsync (waits for the disk)",
     re.compile(r"(?:^|[^.\w]|Darwin\.)fsync\(|\bF_FULLFSYNC\b|\bF_BARRIERFSYNC\b")),
    ("SQLite statement",
     re.compile(r"\bsqlite3_(exec|step|prepare(_v[23])?|open(_v2)?|close(_v2)?|wal_checkpoint(_v2)?)\(")),
    ("synchronous file write or file-system change",
     # A FileManager receiver only (`FileManager.default`, `.checked`, or a local named manager/fileManager/fm):
     # `menu.removeItem(at:)` is an NSMenu, not a file.
     re.compile(r"\.write\(to(File)?:|\.blockingWrite\(to:|(\bFileManager(\.(default|checked))?|\b(manager|fileManager|fm))"
                r"\.(createDirectory|removeItem|moveItem|copyItem|linkItem|replaceItemAt|trashItem|createFile"
                r"|createSymbolicLink|setAttributes)\(")),
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
MAIN_TASK = re.compile(r"\bTask\s*(\(priority:[^)]*\))?\s*\{\s*(\[[^\]]*\]\s*)?@MainActor\b")
PER_LINE_WINDOW = 1
PER_LINE_RULE = "a main-actor Task per line or event (batch with MainActorLineBatch)"

ALLOW = re.compile(r"//\s*main-actor-ok(\([^)]*\))?:\s*\S")
# Lawrence, 2026-11-27 (#cmux-agent, after the cmux#59531 sidebar hang): "Make `main-actor-ok` a hard failure for
# anything that isn't AppKit or Core Animation. The comment should have to name the UI type it touches, not how
# small the data is ... enforce this now". So an exception reads `// main-actor-ok(NSView): <what it does>`: the
# parentheses name the AppKit (NS...) or Core Animation (CA...) type the line touches. A bare
# `// main-actor-ok: <reason>` or a non-UI type still silences the hit under it, but counts as a hit of
# UNTYPED_RULE itself, ratcheted per file like every other rule: no new one passes, the old ones only go down.
ALLOW_TYPE = re.compile(r"//\s*main-actor-ok\(\s*((?:NS|CA)[A-Z]\w*)\s*\):\s*\S")
# NS-prefixed Foundation types are data, not UI: naming one is the "the data is small" reason in other words.
FOUNDATION_NS = frozenset((
    "NSArray", "NSAttributedString", "NSCache", "NSCondition", "NSData", "NSDate", "NSDecimalNumber", "NSDictionary",
    "NSError", "NSFileCoordinator", "NSFileManager", "NSIndexSet", "NSLock", "NSMutableArray",
    "NSMutableAttributedString", "NSMutableData", "NSMutableDictionary", "NSMutableSet", "NSMutableString",
    "NSNotification", "NSNotificationCenter", "NSNumber", "NSObject", "NSPredicate", "NSRange", "NSRecursiveLock",
    "NSRegularExpression", "NSSet", "NSSortDescriptor", "NSString", "NSTimer", "NSURL", "NSURLComponents",
    "NSURLSession", "NSUUID", "NSUserDefaults", "NSValue",
))
UNTYPED_RULE = "main-actor-ok without an AppKit or Core Animation type (write main-actor-ok(NSView): ...)"


def ui_type_named(line: str) -> bool:
    """Whether LINE's `main-actor-ok` names an AppKit or Core Animation type in its parentheses."""
    named = ALLOW_TYPE.search(line)
    return named is not None and named.group(1) not in FOUNDATION_NS
COMMENT_ONLY = re.compile(r"^\s*(//|\*|/\*)")
# `BackgroundWork.run/post(_:mayBlock:)` runs its closure on a lane thread (CmuxNextWakeups/BackgroundWork.swift).
OFF_MAIN = re.compile(r"\bnonisolated\b(?!\s*\(unsafe\))|@concurrent\b|(^|\s)(distributed\s+)?actor\s+\w+|\bTask\.detached\b"
                      r"|\bDispatchQueue\.global\(|\bDispatchQueue\(label:|\bmayBlock:")
OFF_MAIN_CALL = re.compile(r"\bTask\.detached\b|\bDispatchQueue\.global\(|\bDispatchQueue\(label:"
                           r"|\bmayBlock:")
MAIN = re.compile(r"@MainActor\b")
MAIN_CLOSURE = re.compile(r"\{\s*(\[[^\]]*\]\s*)?@MainActor\b")
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
    code = STRING_LITERAL.sub('""', line)
    return code.split("//", 1)[0]


def main_actor_lines(lines: list[str], default_main: bool) -> list[bool]:
    """Whether each line is main-actor code, by lexical scope (brace depth).

    The innermost enclosing `nonisolated` / `@concurrent` declaration, `actor`,
    `Task.detached` or global-queue closure makes a scope off-main; an
    `@MainActor` declaration makes it main; otherwise the target default holds.
    """
    result: list[bool] = []
    stack: list[tuple[int, bool]] = []
    depth = 0
    pending: bool | None = None  # isolation of a declaration whose `{` has not opened yet
    # Parenthesis depth, and its value where `pending` was set: a `{` inside the declaration's own parentheses (a
    # default closure argument, `stillWanted: () -> Bool = { true }`) is not the body and leaves `pending` alone.
    parens = 0
    pending_parens = 0
    for raw in lines:
        if COMMENT_ONLY.match(raw):
            result.append(stack[-1][1] if stack else default_main)
            continue
        code = strip(raw)
        if OFF_MAIN.search(code):
            # A closure-taking call (`Task.detached(operation: { ... })`) is off-main at its first `{`, in parentheses
            # or not; only a declaration's `{` must sit outside its own parentheses.
            pending, pending_parens = False, (sys.maxsize if OFF_MAIN_CALL.search(code) else parens)
        elif MAIN.search(code):
            # `{ @MainActor in` is a closure, main at its own `{` even inside parentheses.
            pending, pending_parens = True, (sys.maxsize if MAIN_CLOSURE.search(code) else parens)
        main = stack[-1][1] if stack else default_main
        result.append(main if pending is None else pending)
        skipped = False  # a `{` inside the declaration's own parentheses was passed over on this line
        for char in code:
            if char == "(":
                parens += 1
            elif char == ")":
                parens = max(parens - 1, 0)
            elif char == "{":
                depth += 1
                if pending is not None and parens <= pending_parens:
                    stack.append((depth, pending))
                    pending = None
                elif pending is not None:
                    skipped = True
            elif char == "}":
                while stack and stack[-1][0] >= depth:
                    stack.pop()
                depth -= 1
        # A declaration whose only `{` sat in its own parentheses and whose parentheses closed on this line
        # (`nonisolated let m = Mutex<() -> Bool>({ true })`) has no body: its isolation ends with the line, so it
        # never reaches the next declaration's body.
        if skipped and pending is not None and parens <= pending_parens and not code.rstrip().endswith((",", "(", "->")):
            pending = None
        # An attribute line, or a declaration header split over lines, carries
        # its isolation to the `{` that opens the body; anything else drops it.
        if pending is not None and "{" not in code and not ATTRIBUTE_ONLY.match(code):
            if not code.rstrip().endswith((",", "(", "->")) and not DECL_KEYWORD.search(code):
                pending = None
    return result


ATTRIBUTE_ONLY = re.compile(r"^\s*((@\w+(\([^)]*\))?|nonisolated)\s*)+$")
DECL_KEYWORD = re.compile(r"\b(func|init|var|class|struct|enum|extension|actor)\b")


def scan_file(path: str, default_main: bool) -> list[tuple[int, str, str]]:
    """(line number, rule, source line) for every main-actor hit."""
    with open(path, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().split("\n")
    main_lines = main_actor_lines(lines, default_main)
    hits: list[tuple[int, str, str]] = []
    # Any isolation: the callback itself may run anywhere; the Task lands on main.
    for index, raw in enumerate(lines):
        if COMMENT_ONLY.match(raw) or allowed(lines, index) or not MAIN_TASK.search(strip(raw)):
            continue
        window = lines[max(0, index - PER_LINE_WINDOW):index + 1]
        if any(PER_LINE_CALLBACK.search(strip(line)) for line in window):
            hits.append((index + 1, PER_LINE_RULE, raw.strip()))
    for index, raw in enumerate(lines):
        if ALLOW.search(raw) and not ui_type_named(raw):
            hits.append((index + 1, UNTYPED_RULE, raw.strip()))
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
    baseline: dict[str, dict[str, int]] = {}
    if os.path.exists(baseline_path):
        with open(baseline_path, encoding="utf-8") as handle:
            baseline = json.load(handle)
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
              "(nonisolated type, @concurrent function, actor, or the Rust daemon). Only work on an AppKit or Core "
              "Animation object stays, marked `// main-actor-ok(NSView): <what it does>` with the type it touches; "
              "\"the input is small\" is no reason.")
        return 1
    if lowered:
        print(f"check-main-actor-work: ok; {lowered} count(s) fell below the baseline: run "
              "scripts/cmux-next/check-main-actor-work.py --update-baseline and commit it.")
        return 0
    print("check-main-actor-work: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())

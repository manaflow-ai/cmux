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
import re
import subprocess
import sys

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
MAIN_TASK = re.compile(r"\bTask\s*(\(priority:[^)]*\))?\s*\{\s*(\[[^\]]*\]\s*)?@MainActor\b")
PER_LINE_WINDOW = 1
PER_LINE_RULE = "a main-actor Task per line or event (batch with MainActorLineBatch)"

ALLOW = re.compile(r"//\s*main-actor-ok:\s*\S")
COMMENT_ONLY = re.compile(r"^\s*(//|\*|/\*)")
OFF_MAIN = re.compile(r"\bnonisolated\b(?!\s*\(unsafe\))|@concurrent\b|(^|\s)(distributed\s+)?actor\s+\w+|\bTask\.detached\b"
                      r"|\bDispatchQueue\.global\(|\bDispatchQueue\(label:")
MAIN = re.compile(r"@MainActor\b")
STRING_LITERAL = re.compile(r'"(?:\\.|[^"\\])*"')


def ui_targets(package_swift: str) -> set[str]:
    text = open(package_swift, encoding="utf-8").read()
    found = re.findall(r'\.(?:target|executableTarget)\(\s*name:\s*"([^"]+)".*?swiftSettings:\s*(\w+)', text, re.S)
    return {name for name, settings in found if settings == "uiSwiftSettings"}


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
    for raw in lines:
        if COMMENT_ONLY.match(raw):
            result.append(stack[-1][1] if stack else default_main)
            continue
        code = strip(raw)
        if OFF_MAIN.search(code):
            pending = False
        elif MAIN.search(code):
            pending = True
        main = stack[-1][1] if stack else default_main
        result.append(main if pending is None else pending)
        for char in code:
            if char == "{":
                depth += 1
                if pending is not None:
                    stack.append((depth, pending))
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
    sources = os.path.join(root, PACKAGE, "Sources")
    ui = ui_targets(os.path.join(root, PACKAGE, "Package.swift"))
    result: dict[str, dict[str, list[tuple[int, str]]]] = {}
    for dirpath, _, files in os.walk(sources):
        for filename in sorted(files):
            if not filename.endswith(".swift"):
                continue
            path = os.path.join(dirpath, filename)
            relative = os.path.relpath(path, root).replace(os.sep, "/")
            module = os.path.relpath(path, sources).split(os.sep)[0]
            for line, rule, text in scan_file(path, module in ui):
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

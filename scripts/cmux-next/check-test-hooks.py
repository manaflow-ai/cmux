#!/usr/bin/env python3
"""No process-wide test hooks in acpmux (cmux#41350).

The test harness runs tests on parallel threads of one process. A test hook
kept in a process-wide static lets one test's hook replace or clear another's
before the code it was meant to stop ran, so the race the test forces never
happens, or a test runs another test's hook. folder_instructions::SWAP_HOOK
failed 50 of 50 runs that way; hub::transfer_in::SWEEP_PAUSE was one second
user away from it.

This guard fails on a static in cmux-tui/crates/acpmux/src that holds a test
hook, outside a `thread_local!` block:
  - a test slot: a `Mutex<Option<...>>` or `RwLock<Option<...>>` (also inside
    a OnceLock or LazyLock) under `#[cfg(test)]`, in a `#[cfg(test)]` module
    or in a test file;
  - a closure in a cell: a Mutex, RwLock, OnceLock, LazyLock or OnceCell
    whose type holds `dyn Fn`/`FnMut`/`FnOnce`, `impl Fn...`, a `fn(...)`
    pointer, or a type alias of this file that does;
  - any static named `...HOOK`.
Production caches (`Mutex<Option<Cached>>` outside test code) are not hooks.

The fixes: a per-thread hook, a `thread_local!` slot set through an `on_*`
guard that takes it off when dropped (folder_instructions::on_swap); or, when
the code the hook stops runs on another thread, a static only an `on_*` guard
sets, holding a `Mutex<()>` serializer until it drops (the `HOOK_TEST`
pattern). The second needs a marker on the static, in the comment and
attribute lines directly above it or on its line:

    // test-hook-allow: serialized by HOOK_TEST, which every test that sets it holds

A marker that says `serialized by NAME` must name a `static NAME: Mutex<()>`
(std or tokio) in the same file. Any other marker states why the hook cannot
race (one process per test, say), in at least three words.

Usage: check-test-hooks.py [repo-root]   (default: this repository)
Exit 0: no finding; 1: findings, one `path:line: NAME: why` line each.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

SCOPE = "cmux-tui/crates/acpmux/src"
MARKER = re.compile(r"//\s*test-hook-allow:\s*(?P<why>.*)$")
SERIALIZED = re.compile(r"\bserialized by (?P<name>[A-Za-z_][A-Za-z0-9_]*)")
STATIC = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?static\s+(?:mut\s+)?(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*:")
SLOT = re.compile(r"\b(?:Mutex|RwLock)\s*<\s*Option\s*<")
CELL = re.compile(r"\b(?:Mutex|RwLock|OnceLock|LazyLock|OnceCell|Lazy)\s*<")
CLOSURE = re.compile(r"\bdyn\s+(?:Fn|FnMut|FnOnce)\b|\bimpl\s+(?:Fn|FnMut|FnOnce)\b|\bfn\s*\(")
SERIALIZER = re.compile(r"^\s*(?:(?:std|tokio)::sync::)?Mutex\s*<\s*\(\s*\)\s*>\s*$")
ALIAS = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?type\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\b")
CFG_TEST = re.compile(r"^\s*#\[cfg\(test\)\]")
MOD_OPEN = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+\w+\s*\{")
THREAD_LOCAL = re.compile(r"\bthread_local!\s*\{")


def is_test_file(rel: Path) -> bool:
    name = rel.name
    return ("tests" in rel.parts[:-1] or name in ("tests.rs", "test.rs")
            or name.endswith(("_tests.rs", "_test.rs")))


def code_only(line: str) -> str:
    """The line without its string and char literals and its `//` comment, for brace counting."""
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    line = re.sub(r"'(?:[^'\\]|\\.)'", "''", line)
    return line.split("//", 1)[0]


def declared_type(lines: list[str], start: int) -> str:
    """The type of the static declared at lines[start]: from its `:` to its top-level `=` or `;`."""
    text = lines[start].split(":", 1)[1]
    out = []
    depth = 0
    index = start
    while True:
        i = 0
        while i < len(text):
            ch = text[i]
            if ch == "-" and text[i + 1:i + 2] == ">":
                out.append("->")
                i += 2
                continue
            if ch in "<([":
                depth += 1
            elif ch in ">)]":
                depth -= 1
            elif ch in "=;" and depth <= 0:
                return "".join(out)
            out.append(ch)
            i += 1
        index += 1
        if index >= len(lines) or index - start > 12:
            return "".join(out)
        out.append(" ")
        text = lines[index]


def leading_block(lines: list[str], at: int) -> list[str]:
    """The comment and attribute lines directly above lines[at], nearest first."""
    block = []
    i = at - 1
    while i >= 0:
        stripped = lines[i].strip()
        if stripped.startswith(("//", "#[")):
            block.append(stripped)
            i -= 1
            continue
        break
    return block


def closure_aliases(lines: list[str]) -> set[str]:
    names = set()
    for i, line in enumerate(lines):
        match = ALIAS.match(line)
        if not match:
            continue
        text = line
        j = i
        while ";" not in code_only(text) and j + 1 < len(lines) and j - i < 12:
            j += 1
            text += " " + lines[j]
        if CLOSURE.search(text.split("=", 1)[-1]):
            names.add(match.group("name"))
    return names


def serializers(lines: list[str]) -> set[str]:
    names = set()
    for i, line in enumerate(lines):
        match = STATIC.match(line)
        if match and SERIALIZER.match(declared_type(lines, i)):
            names.add(match.group("name"))
    return names


def judge_file(path: Path, rel: str) -> list[str]:
    lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
    test_file = is_test_file(Path(rel))
    aliases = closure_aliases(lines)
    alias_use = re.compile(r"\b(?:" + "|".join(map(re.escape, sorted(aliases))) + r")\b") if aliases else None
    locks: set[str] | None = None
    found = []
    depth = 0
    # Brace depths at which a `thread_local!` block or a `#[cfg(test)]` module opened.
    per_thread: list[int] = []
    test_mods: list[int] = []
    pending_cfg_test = False
    for i, line in enumerate(lines):
        code = code_only(line)
        match = STATIC.match(line)
        if match and not per_thread:
            name = match.group("name")
            ty = declared_type(lines, i)
            block = leading_block(lines, i)
            gated = test_file or bool(test_mods) or any(CFG_TEST.match(b) for b in block)
            why = None
            if gated and SLOT.search(ty):
                why = "a process-wide test slot (`Mutex<Option<...>>`)"
            elif CELL.search(ty) and (CLOSURE.search(ty) or (alias_use and alias_use.search(ty))):
                why = "a closure in a process-wide cell"
            elif name.endswith("HOOK"):
                why = "a process-wide static named as a hook"
            if why:
                marker = next((m for m in (MARKER.search(t) for t in [line, *block]) if m), None)
                reason = marker.group("why").strip() if marker else ""
                serial = SERIALIZED.search(reason)
                if marker is None:
                    found.append(f"{rel}:{i + 1}: {name}: {why}; put it in a thread_local! behind an on_* guard, "
                                 f"or serialize it and mark it `// test-hook-allow: serialized by <Mutex<()> static>, "
                                 f"<why>`")
                elif serial:
                    if locks is None:
                        locks = serializers(lines)
                    if serial.group("name") not in locks:
                        found.append(f"{rel}:{i + 1}: {name}: its test-hook-allow names {serial.group('name')}, "
                                     f"which is no `static {serial.group('name')}: Mutex<()>` in this file")
                elif len(reason.split()) < 3:
                    found.append(f"{rel}:{i + 1}: {name}: its test-hook-allow gives no reason (at least three words)")
        if CFG_TEST.match(line):
            pending_cfg_test = True
        elif line.strip() and not line.strip().startswith(("//", "#[")):
            if pending_cfg_test and MOD_OPEN.match(line):
                test_mods.append(depth)
            pending_cfg_test = False
        if THREAD_LOCAL.search(code):
            per_thread.append(depth)
        depth += code.count("{") - code.count("}")
        while per_thread and depth <= per_thread[-1]:
            per_thread.pop()
        while test_mods and depth <= test_mods[-1]:
            test_mods.pop()
    return found


def violations(root: Path) -> list[str]:
    found = []
    scope = root / SCOPE
    if not scope.is_dir():
        return found
    for path in sorted(scope.rglob("*.rs")):
        found += judge_file(path, path.relative_to(root).as_posix())
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2]
    found = violations(root)
    if found:
        print("process-wide test hooks: a parallel test can replace or clear another's hook (cmux#41350):")
        for line in found:
            print(line)
        return 1
    print("process-wide test hooks: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

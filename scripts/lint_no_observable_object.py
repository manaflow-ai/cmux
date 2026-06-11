#!/usr/bin/env python3
"""Forbid ObservableObject and its ecosystem in cmux-owned Swift code.

The codebase migrated wholesale to @Observable (Observation framework).
This lint keeps it that way: any live use of ObservableObject, @Published,
@StateObject, @ObservedObject, @EnvironmentObject, .environmentObject(, or
objectWillChange in cmux-owned Swift fails CI. Mentions inside // and
/* */ comments (including doc comments) are ignored, so migration-rationale
comments stay legal.

Use @Observable, @State, @Bindable, @Environment(T.self), and .environment()
instead. If a third-party API ever genuinely forces one of these symbols,
add a narrowly-scoped exception here in the same PR, with a comment saying
why.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOTS = ("Sources", "CLI", "Packages", "ios", "cmuxTests", "cmuxUITests")
IGNORED_PATH_PARTS = (
    "/vendor/",
    "/ghostty/",
    "/homebrew-cmux/",
    "/.build/",
    "/SourcePackages/",
    "/.ci-source-packages/",
    "/checkouts/",
)

BANNED = re.compile(
    r"\bObservableObject\b"
    r"|@Published\b"
    r"|@StateObject\b"
    r"|@ObservedObject\b"
    r"|@EnvironmentObject\b"
    r"|\.environmentObject\s*\("
    r"|\bobjectWillChange\b"
)


def strip_comments(source: str) -> str:
    """Blank out // line comments and (nested) /* */ block comments.

    Preserves line structure so reported line numbers match the file.
    String literals are NOT stripped: a banned token inside a string would
    be reported, which is acceptable for a ban lint (no such strings exist,
    and a false positive is visible and easy to rephrase).
    """
    out: list[str] = []
    depth = 0
    for line in source.splitlines():
        result: list[str] = []
        i = 0
        n = len(line)
        while i < n:
            two = line[i : i + 2]
            if depth == 0 and two == "//":
                break
            if two == "/*":
                depth += 1
                i += 2
                continue
            if depth > 0 and two == "*/":
                depth -= 1
                i += 2
                continue
            if depth == 0:
                result.append(line[i])
            i += 1
        out.append("".join(result))
    return "\n".join(out)


def main() -> int:
    repo_root = pathlib.Path.cwd()
    failures: list[str] = []
    for root in ROOTS:
        root_path = repo_root / root
        if not root_path.exists():
            continue
        for path in sorted(root_path.rglob("*.swift")):
            rel = path.relative_to(repo_root).as_posix()
            if any(part in "/" + rel for part in IGNORED_PATH_PARTS):
                continue
            stripped = strip_comments(path.read_text(encoding="utf-8", errors="replace"))
            for line_no, line in enumerate(stripped.splitlines(), start=1):
                match = BANNED.search(line)
                if match:
                    failures.append(f"{rel}:{line_no}: {match.group(0)}")
    if failures:
        print("ObservableObject ban violated. cmux uses @Observable exclusively.")
        print("Use @Observable / @State / @Bindable / @Environment(T.self) / .environment().")
        print("")
        for failure in failures:
            print(f"  {failure}")
        return 1
    print("ObservableObject ban respected.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

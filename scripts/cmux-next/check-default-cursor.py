#!/usr/bin/env python3
"""DEFAULT-CURSOR: cmux-next's own UI shows the arrow over buttons, rows, chips, tabs and links.

The user (2026-10-30, msg 18087): "change all pointers back to cursor-default". A native macOS
app shows the arrow over its controls; the pointing hand is for links in content the app does not
own (a web page in the browser, a URL in a terminal). Resize, I-beam, drag and zoom cursors stay.

Findings, in tracked files:
  1. Swift sources (not tests) under Packages/macOS and Packages/Shared that names the pointing hand
     (`pointingHand`, `pointerStyle(.link)`), in a file not in the allowlist.
  2. Webview sources under webviews/src (.css, .ts, .tsx; tests excluded) that set
     `cursor: pointer` or the Tailwind `cursor-pointer` utility (a variant such as
     `hover:cursor-pointer` too), in a file not in the allowlist.
  3. An allowlist entry for a file that no longer has a pointer cursor, or no longer exists:
     delete the line, so the list only shrinks.

The allowlist is scripts/cmux-next/pointer-cursor-allowlist.txt, one repo-relative path per
line with a `# reason`; `#` starts a comment.

Usage: check-default-cursor.py [repo-root]
Exit 0 clean, 1 with findings (each names the file and line), 2 on a usage error.
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ALLOWLIST = "scripts/cmux-next/pointer-cursor-allowlist.txt"
SWIFT_SCOPES = ("Packages/macOS", "Packages/Shared")
WEB_SCOPE = "webviews/src"

SWIFT_POINTER = re.compile(r"\bpointingHand\b|pointerStyle\(\s*\.link\b")
WEB_POINTER = re.compile(r"cursor\s*:\s*[\"']?pointer\b|(?<![\w-])(?:[\w-]+:)*cursor-pointer(?![\w-])")
WEB_TEST = re.compile(r"\.test\.tsx?$")


def tracked(root: pathlib.Path, scope: str, suffixes: tuple[str, ...]) -> list[str]:
    try:
        out = subprocess.run(["git", "-C", str(root), "ls-files", "--", scope],
                             check=True, capture_output=True, text=True).stdout
        files = [line for line in out.splitlines() if line]
    except (subprocess.CalledProcessError, FileNotFoundError):
        # Not a git checkout (the guard's self-test): every file on disk.
        base = root / scope
        files = sorted(str(p.relative_to(root)) for p in base.rglob("*") if p.is_file()) if base.is_dir() else []
    return [f for f in files if f.endswith(suffixes)]


def strip_swift_comments(text: str) -> str:
    """Blanks `//` line comments so a doc comment that mentions the hand is not a finding."""
    return "\n".join(re.sub(r"//.*$", "", line) for line in text.split("\n"))


def strip_block_comments(text: str) -> str:
    return re.sub(r"/\*[\s\S]*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


def hits(root: pathlib.Path) -> dict[str, list[int]]:
    found: dict[str, list[int]] = {}

    def scan(path: str, text: str, pattern: re.Pattern[str]) -> None:
        for number, line in enumerate(text.split("\n"), start=1):
            if pattern.search(line):
                found.setdefault(path, []).append(number)

    for scope in SWIFT_SCOPES:
        for path in tracked(root, scope, (".swift",)):
            if "/Tests/" in path:
                continue
            text = (root / path).read_text(encoding="utf-8", errors="replace")
            scan(path, strip_swift_comments(strip_block_comments(text)), SWIFT_POINTER)
    for path in tracked(root, WEB_SCOPE, (".css", ".ts", ".tsx")):
        if WEB_TEST.search(path):
            continue
        text = (root / path).read_text(encoding="utf-8", errors="replace")
        text = strip_block_comments(text)
        if path.endswith((".ts", ".tsx")):
            text = strip_swift_comments(text)
        scan(path, text, WEB_POINTER)
    return found


def allowlist(root: pathlib.Path) -> list[str]:
    path = root / ALLOWLIST
    if not path.is_file():
        return []
    entries = []
    for line in path.read_text(encoding="utf-8").splitlines():
        entry = line.split("#", 1)[0].strip()
        if entry:
            entries.append(entry)
    return entries


def main(argv: list[str]) -> int:
    if len(argv) > 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = pathlib.Path(argv[1] if len(argv) == 2 else ".").resolve()
    found = hits(root)
    allowed = allowlist(root)
    findings: list[str] = []
    for path, lines in sorted(found.items()):
        if path not in allowed:
            for line in lines:
                findings.append(f"{path}:{line}: pointer cursor in cmux-next UI; use the arrow "
                                f"(no cursor rule), or add the file to {ALLOWLIST} with a reason "
                                f"if it is web or terminal content")
    for entry in allowed:
        if entry not in found:
            findings.append(f"{ALLOWLIST}: {entry} has no pointer cursor (or is gone); delete the line")
    for finding in findings:
        print(finding, file=sys.stderr)
    if findings:
        print(f"check-default-cursor: {len(findings)} finding(s)", file=sys.stderr)
        return 1
    print("check-default-cursor: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""KEYCHAIN-NO-PROMPT ratchet.

An unattended fleet Mac showed a macOS keychain panel (SecurityAgent) that
the cmux app raised. No one was there to answer it. A Keychain or
LocalAuthentication call that runs without the person asking must never show
UI: it reads with interaction turned off and treats "needs the person" as a
miss.

This guard counts the calls in shipping Swift under Packages/macOS/ and
Packages/Shared/ (not Tests/ folders, Packages/iOS/ or vendor/) that can show
UI without a guard. A call is a code line that calls:
  - SecItemCopyMatching, SecItemAdd, SecItemUpdate, SecItemDelete;
  - any SecKeychain* function, except SecKeychainGetUserInteractionAllowed and
    SecKeychainSetUserInteractionAllowed (those are the guard);
  - LAContext evaluatePolicy( or evaluateAccessControl(.

A call is guarded when its scope holds one of the GUARDS tokens below. The
scope is approximate on purpose: the lines from the nearest preceding line
with `func ` or `init(` (or the top of the file when there is none) down to
the call, plus the call's own statement (the lines after it until its
parentheses close, at most 10). So a query literal built in the same function,
or passed inline, counts. Comment lines in the scope do not count.

A call is also guarded by `// keychain-prompt: consent` on the call line or
the line before. Use it only where the prompt is the person's consent: they
asked for it (a browser import that reads another app's Safe Storage key, a
passcode or Touch ID check they started).

Unguarded calls are listed in scripts/cmux-next/keychain-no-prompt-baseline.tsv
with the count per file, a class (`fix` = runs without the person asking and
should be guarded, `keep` = a reviewed consent prompt) and a reason. A file
with more unguarded calls than its row, or with calls and no row, fails. A
file with fewer also fails until its row is lowered, so the ratchet only goes
down.

Usage: scripts/cmux-next/check-keychain-no-prompt.py [repo-root] [--list]
  --list  print every unguarded call and exit 0.
"""

from __future__ import annotations

import os
import re
import sys

SCOPES = ("Packages/macOS", "Packages/Shared")
SKIP_DIRS = {".build", "Tests", "tests", "vendor", "node_modules", "fixtures"}
BASELINE = "scripts/cmux-next/keychain-no-prompt-baseline.tsv"
CLASSES = ("fix", "keep")

CALL = re.compile(
    r"\bSecItem(?:CopyMatching|Add|Update|Delete)\s*\("
    r"|\bSecKeychain(?!(?:Get|Set)UserInteractionAllowed\b)\w+\s*\("
    r"|\.\s*evaluatePolicy\s*\("
    r"|\.\s*evaluateAccessControl\s*\("
)
GUARDS = (
    "withoutUI",
    "kSecUseAuthenticationUIFail",
    "kSecUseAuthenticationUISkip",
    "interactionNotAllowed",
    "NoPromptContext",
    "noPromptContext",
)
CONSENT = "keychain-prompt: consent"
FUNC_START = re.compile(r"\bfunc\s|\binit[?!]?\s*[(<]")
COMMENT = re.compile(r"^\s*(//|/\*|\*(\s|/|$))")
STATEMENT_LINES = 10


def _statement_end(lines: list[str], index: int) -> int:
    """Index of the last line of the statement that starts at `index` (parentheses balance)."""
    depth = 0
    for offset in range(STATEMENT_LINES):
        if index + offset >= len(lines):
            break
        line = lines[index + offset].split("//", 1)[0]
        depth += line.count("(") - line.count(")")
        if depth <= 0:
            return index + offset
    return min(index + STATEMENT_LINES - 1, len(lines) - 1)


def _guarded(lines: list[str], index: int) -> bool:
    if CONSENT in lines[index] or (index > 0 and CONSENT in lines[index - 1]):
        return True
    start = 0
    for back in range(index, -1, -1):
        if not COMMENT.match(lines[back]) and FUNC_START.search(lines[back]):
            start = back
            break
    end = _statement_end(lines, index)
    for line in lines[start:end + 1]:
        if COMMENT.match(line):
            continue
        if any(token in line for token in GUARDS):
            return True
    return False


def unguarded_calls(text: str) -> list[tuple[int, str]]:
    lines = text.splitlines()
    found = []
    for index, line in enumerate(lines):
        if COMMENT.match(line) or not CALL.search(line.split("//", 1)[0]):
            continue
        if not _guarded(lines, index):
            found.append((index + 1, line.rstrip()))
    return found


def scan(root: str) -> dict[str, list[tuple[int, str]]]:
    hits: dict[str, list[tuple[int, str]]] = {}
    for scope in SCOPES:
        base = os.path.join(root, scope)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for name in sorted(filenames):
                if not name.endswith(".swift") or name.endswith("Tests.swift"):
                    continue
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, root).replace(os.sep, "/")
                if "/Tests/" in rel or "/vendor/" in rel:
                    continue
                try:
                    with open(path, encoding="utf-8", errors="replace") as f:
                        text = f.read()
                except OSError:
                    continue
                found = unguarded_calls(text)
                if found:
                    hits[rel] = found
    return hits


def read_baseline(root: str) -> dict[str, tuple[int, str, str]]:
    rows: dict[str, tuple[int, str, str]] = {}
    path = os.path.join(root, BASELINE)
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 4 or parts[2] not in CLASSES or not parts[1].isdigit():
                print(f"check-keychain-no-prompt: bad baseline row: {line!r}", file=sys.stderr)
                sys.exit(2)
            rows[parts[0]] = (int(parts[1]), parts[2], parts[3])
    return rows


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    root = os.path.abspath(args[0]) if args else os.getcwd()
    hits = scan(root)
    if "--list" in argv:
        for rel, found in sorted(hits.items()):
            for number, line in found:
                print(f"{rel}:{number}: {line.strip()}")
        return 0
    baseline = read_baseline(root)
    status = 0
    for rel, found in sorted(hits.items()):
        allowed = baseline.get(rel, (0, "", ""))[0]
        if len(found) > allowed:
            status = 1
            print(
                f"check-keychain-no-prompt: {rel} has {len(found)} unguarded Keychain/LocalAuthentication "
                f"call(s), baseline {allowed}. A call that runs without the person asking must not show UI: "
                "wrap it in LoginKeychain().withoutUI { ... }, or set kSecUseAuthenticationUI to "
                "kSecUseAuthenticationUIFail (or an LAContext with interactionNotAllowed). A prompt the person "
                "asked for gets `// keychain-prompt: consent` on the line before.",
                file=sys.stderr,
            )
            for number, line in found:
                print(f"  {rel}:{number}: {line.strip()}", file=sys.stderr)
    for rel, (allowed, _, _) in sorted(baseline.items()):
        count = len(hits.get(rel, []))
        if count < allowed:
            status = 1
            print(
                f"check-keychain-no-prompt: {rel} now has {count} unguarded call(s), baseline {allowed}. "
                f"Lower its row in {BASELINE} to {count}" + (" (delete the row)" if count == 0 else "") + ".",
                file=sys.stderr,
            )
    if status == 0:
        print(f"check-keychain-no-prompt: ok ({sum(len(v) for v in hits.values())} baselined call(s) in {len(hits)} file(s))")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

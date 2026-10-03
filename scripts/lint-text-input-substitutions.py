#!/usr/bin/env python3
"""Fail when a cmux text view can rewrite what the user types.

macOS typing substitutions (smart quotes and dashes, text replacement,
autocorrect, double-space period) turned typed `"` into `“` and `--` into `—`
in cmux's editors and corrupted saved files
(https://github.com/manaflow-ai/cmux/issues/16738). Every editor goes through
`CmuxPlainTextInput` (Packages/macOS/CmuxFoundation/.../CmuxPlainTextInput.swift):

  1. Each `NSTextView`, or subclass of one, that macOS code creates must call
     `<view>.cmuxDisableTypingSubstitutions()` after the line that creates it,
     or be a read-only display that sets `<view>.isEditable = false`. A
     subclass that does either in its own body covers all its instances.
  2. `Sources/CmuxMain.swift` must call `CmuxPlainTextInput.installAppDefaults`,
     which covers the text views AppKit and SwiftUI create on their own: the
     field editor behind every `NSTextField` and SwiftUI `TextField`, and
     SwiftUI `TextEditor`.

A creation site that needs neither (a view never shown) can carry
`// text-input-substitutions: exempt (<reason>)` on its line or the line above.

Usage: scripts/lint-text-input-substitutions.py [--repo PATH]
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SCAN_ROOTS = ("Sources", "Packages/macOS", "Packages/Shared")
LAUNCH_FILE = "Sources/CmuxMain.swift"
LAUNCH_CALL = "CmuxPlainTextInput.installAppDefaults("
SETUP_CALL = "cmuxDisableTypingSubstitutions()"
SCROLLABLE_FACTORY_RE = re.compile(
    r"\bNSTextView\s*\.\s*(scrollableTextView|scrollablePlainDocumentContentTextView|"
    r"scrollableDocumentContentTextView)\s*\("
)
SUBCLASS_RE = re.compile(r"\bclass\s+(?!(?:var|func|let)\b)(\w+)\s*:\s*(\w+)")
EXEMPT_RE = re.compile(r"//\s*text-input-substitutions:\s*exempt\s*\(\s*\S[^)]*\)")
SELF_COVERED_RE = re.compile(
    r"(?:^|[\s;{(]|\bself\.)(?:" + re.escape(SETUP_CALL) + r"|isEditable\s*=\s*false\b)",
    re.M,
)


def is_test_path(rel: str) -> bool:
    parts = rel.split("/")
    return any(part == "Tests" or part.endswith("Tests") for part in parts[:-1])


def swift_files(repo: Path) -> dict[str, str]:
    files: dict[str, str] = {}
    for root in SCAN_ROOTS:
        base = repo / root
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.swift")):
            rel = path.relative_to(repo).as_posix()
            if is_test_path(rel) or "/.build/" in rel:
                continue
            files[rel] = path.read_text(encoding="utf-8", errors="replace")
    return files


def strip_comments(text: str) -> str:
    """Blanks `//` and `/* */` comments and string literals, keeping offsets."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out[i:j] = " " * (j - i)
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out[i:j] = [c if c == "\n" else " " for c in text[i:j]]
            i = j
        elif text[i] == '"':
            if text.startswith('"""', i):
                j = text.find('"""', i + 3)
                j = n if j < 0 else j + 3
            else:
                j = i + 1
                while j < n and text[j] not in '"\n':
                    j += 2 if text[j] == "\\" else 1
                j = min(j + 1, n)
            out[i + 1:j - 1] = [c if c == "\n" else " " for c in text[i + 1:j - 1]]
            i = j
        else:
            i += 1
    return "".join(out)


def class_body(code: str, start: int) -> str:
    """Returns the `{...}` body of the declaration starting at `start`."""
    open_brace = code.find("{", start)
    if open_brace < 0:
        return ""
    depth = 0
    for i in range(open_brace, len(code)):
        if code[i] == "{":
            depth += 1
        elif code[i] == "}":
            depth -= 1
            if depth == 0:
                return code[open_brace:i + 1]
    return code[open_brace:]


def line_of(code: str, offset: int) -> int:
    return code.count("\n", 0, offset) + 1


def lint(repo: Path) -> list[str]:
    raw = swift_files(repo)
    code = {rel: strip_comments(text) for rel, text in raw.items()}

    # Every NSTextView subclass declared in macOS code, transitively.
    declarations: dict[str, tuple[str, str, int]] = {}
    for rel, text in code.items():
        for match in SUBCLASS_RE.finditer(text):
            declarations.setdefault(match.group(1), (match.group(2), rel, match.start()))
    text_view_types = {"NSTextView"}
    changed = True
    while changed:
        changed = False
        for name, (base, _, _) in declarations.items():
            if base in text_view_types and name not in text_view_types:
                text_view_types.add(name)
                changed = True

    def covers_itself(name: str) -> bool:
        while name in declarations:
            base, rel, start = declarations[name]
            if SELF_COVERED_RE.search(class_body(code[rel], start)):
                return True
            name = base
        return False

    creation_re = re.compile(r"\b(" + "|".join(sorted(map(re.escape, text_view_types))) + r")\s*\(")
    errors: list[str] = []
    for rel, text in code.items():
        lines = raw[rel].splitlines()
        sites = [(m.start(), m.group(1), False) for m in creation_re.finditer(text)]
        sites += [(m.start(), "NSTextView", True) for m in SCROLLABLE_FACTORY_RE.finditer(text)]
        for offset, type_name, scrollable in sorted(sites):
            line = line_of(text, offset)
            nearby = lines[max(line - 2, 0):line]
            if any(EXEMPT_RE.search(candidate) for candidate in nearby):
                continue
            if not scrollable and covers_itself(type_name):
                continue
            line_start = text.rfind("\n", 0, offset) + 1
            assignment = re.search(r"\b(?:let|var)\s+(\w+)\b[^=\n]*=\s*$", text[line_start:offset])
            rest = text[offset:]
            if scrollable:
                # The text view is the scroll view's document view; it has no
                # name of its own at the creation site.
                pattern = re.compile(
                    r"\." + re.escape(SETUP_CALL) + r"|\.isEditable\s*=\s*false\b"
                )
            elif assignment:
                name = re.escape(assignment.group(1))
                pattern = re.compile(
                    r"\b" + name + r"\s*\.\s*" + re.escape(SETUP_CALL)
                    + r"|\b" + name + r"\s*\.\s*isEditable\s*=\s*false\b"
                )
            else:
                errors.append(
                    f"{rel}:{line}: {type_name} is created without a name; assign it to a "
                    f"`let` and call `.{SETUP_CALL}` on it"
                )
                continue
            if not pattern.search(rest):
                what = "the scroll view's text view" if scrollable else f"`{assignment.group(1)}`"
                errors.append(
                    f"{rel}:{line}: {type_name} {what} can rewrite typed text; call "
                    f"`.{SETUP_CALL}` on it (CmuxFoundation), or set `isEditable = false` "
                    f"if it only displays text"
                )

    launch = raw.get(LAUNCH_FILE)
    if launch is not None and LAUNCH_CALL not in strip_comments(launch):
        errors.append(
            f"{LAUNCH_FILE}: must call `{LAUNCH_CALL}...)` before the app starts, so field "
            f"editors and SwiftUI text views start with typing substitutions off"
        )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    errors = lint(args.repo.resolve())
    if errors:
        print("lint-text-input-substitutions: FAILED", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1
    print("lint-text-input-substitutions: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())

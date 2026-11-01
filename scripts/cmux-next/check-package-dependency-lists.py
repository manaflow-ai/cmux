#!/usr/bin/env python3
"""Keep Package.swift's hot dependency lists one entry per line and sorted.

Nearly every new CmuxNext module adds itself to the CmuxNextAppTests
dependencies. While that list was a few long lines that every pull request
appended to, two pull requests adding different modules always conflicted
(2026-10-20: #21480, #21487, #21284, #21568, #20945 and #21921 were each
CONFLICTING again within about twenty minutes of a clean rebase). GitHub runs
no merge drivers, so the fix is the layout: with one entry per line, sorted,
each with a trailing comma, two additions land on different lines and merge
cleanly unless they are neighbours in the sort order.

A list opts in with this marker on its opening line:

    dependencies: [  // sorted: scripts/cmux-next/check-package-dependency-lists.py

and the targets in REQUIRED must carry it. Inside a marked list every line is
one complete entry ending in a comma, or a `//` comment line, which belongs to
the entry below it and moves with it. Entries sort by their text: target names
("...") before products (.product(...)), each alphabetically.

Also: every target declares the local targets it imports. A source file of target T that writes
`import X`, where X is another target of this package, needs X in T's `dependencies`. Without it SwiftPM
still builds X (it is in T's closure through another target), but an incremental build does not know T
uses X: when X's interface changed (Mutex.withLock gained call-site arguments, 2026-10-24),
CmuxNextDaemonTests' RetryWakeFolderTests.swift was not recompiled and its object linked against the old
symbol, on the fleet's Linux pool and on a warm macOS slot. The imports undeclared before this check landed
are listed in IMPORT_BASELINE (each one is debt: declare it, or stop importing it, and drop its line); a new
one fails.

Usage: scripts/cmux-next/check-package-dependency-lists.py [--fix] [--fix-imports] [--json] [PACKAGE_SWIFT]
  --fix          rewrite each marked list in canonical order (a merge resolution that
                 kept both sides' lines in any order becomes canonical)
  --fix-imports  declare each new undeclared import in its target's dependencies: a marked list
                 gets the entry in sorted order, an inline list `["A", "B"]` gets it before `]`, any
                 other list gets it as its own line before `]`
  --json         print {"problems": [...], "missing": [{"target", "module"}]} on stdout

The pre-push gate (scripts/cmux-next/prepush-gate.py) runs this check on a push that changes the CmuxNext
package, and cmux-next-package-deps-heal.yml runs it after every feat-cmux-next push, which a direct push
reaches without a hook: on a red it opens a pull request made with --fix-imports (2026-10-29: a63986a4 and
e875485c each added a test import its target did not declare, straight to the branch, and "Package
dependency lists sorted" was red on every pull request after them until #27173 and #27219).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# The masker: beside this file first (the pre-push hook's installed copy, install-git-hooks.sh and refresh_checks.py put
# it there, so a push cannot change how its own imports are read), else the repository's scripts/.
sys.path[:0] = [str(Path(__file__).resolve().parent), str(ROOT / "scripts")]
from swift_source_mask import mask_swift_source  # noqa: E402
DEFAULT_MANIFEST = ROOT / "Packages/macOS/CmuxNext/Package.swift"
MARKER = "// sorted: scripts/cmux-next/check-package-dependency-lists.py"
REQUIRED = ("CmuxNextAppTests",)

# Imports that were undeclared when the import check landed (2026-10-24): "Target: Module". Shrink only.
# CmuxNextBridge's Design import is a ui edge from a domain target (architecture-layers.json): declaring it
# would add a layer_hard edge, so its fix is to stop importing Design, not to declare it.
IMPORT_BASELINE = frozenset((
    "CmuxNextActionsTests: CmuxNextWakeups",
    "CmuxNextApp: CmuxNextFileGrid",
    "CmuxNextBridge: CmuxNextDesign", "CmuxNextBridge: CmuxNextWakeups",
    "CmuxNextControlTests: CmuxNextDesign",
    "CmuxNextCookieImport: CmuxNextCompat",
    "CmuxNextPaletteTests: CmuxNextActions", "CmuxNextPaletteTests: CmuxNextDesign",
    "CmuxNextPhoneAccessTests: CmuxNextMobile",
) + tuple(f"CmuxNextAppTests: {module}" for module in (
    "CmuxNextAccounts", "CmuxNextAgentActivity", "CmuxNextAgentPane", "CmuxNextBookmarks", "CmuxNextBridge",
    "CmuxNextBrowser", "CmuxNextCloud", "CmuxNextCodeRouter", "CmuxNextControl", "CmuxNextDesignTokens",
    "CmuxNextDevices", "CmuxNextErrorJournal", "CmuxNextHostPressure", "CmuxNextIcons",
    "CmuxNextPages", "CmuxNextPopups", "CmuxNextRemoteBrowser", "CmuxNextRemoteLocalhost", "CmuxNextRemoteView",
    "CmuxNextResources", "CmuxNextSettingsWindow",
    "CmuxNextTerminal")))
TARGET = re.compile(r'^\s*\.(target|testTarget|executableTarget)\(\s*$')
IMPORT = re.compile(r"^\s*(@\w+(\([^)]*\))?\s+)*((public|package|internal|private|fileprivate)\s+)?import\s+(\w+)")

OPEN = re.compile(r"^(\s*)dependencies: \[\s*" + re.escape(MARKER) + r"\s*$")
NAME = re.compile(r'^\s*name: "([^"]+)",\s*$')


class ListError(Exception):
    pass


def entries_of(lines: list[str], start: int) -> tuple[list[tuple[list[str], str]], int]:
    """Parse the marked list opening at `start`: ([(comments, entry)], closing line index)."""
    entries: list[tuple[list[str], str]] = []
    comments: list[str] = []
    i = start + 1
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped in ("]", "],"):
            if comments:
                raise ListError(f"line {i + 1}: a comment ends the list instead of preceding an entry")
            return entries, i
        if not stripped:
            raise ListError(f"line {i + 1}: blank line inside a sorted list")
        if stripped.startswith("//"):
            comments.append(line)
        elif "//" in stripped:
            raise ListError(f"line {i + 1}: put the comment on its own line above the entry: {stripped}")
        elif not stripped.endswith(","):
            raise ListError(f"line {i + 1}: an entry must end in a comma: {stripped}")
        elif stripped.count("(") != stripped.count(")") or stripped.count('"') % 2:
            raise ListError(f"line {i + 1}: an entry must be complete on its own line: {stripped}")
        elif top_level_commas(stripped) != 1:
            raise ListError(f"line {i + 1}: one entry per line: {stripped}")
        else:
            entries.append((comments, line))
            comments = []
        i += 1
    raise ListError(f"line {start + 1}: the list never closes")


def top_level_commas(entry: str) -> int:
    """Commas outside string literals and parentheses: 1 for one entry with its trailing comma."""
    count = depth = 0
    quoted = False
    for char in entry:
        if char == '"':
            quoted = not quoted
        elif quoted:
            continue
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == "," and depth == 0:
            count += 1
    return count


def key(entry: str) -> str:
    return entry.strip()


def target_name(lines: list[str], start: int) -> str | None:
    for i in range(start - 1, max(start - 6, -1), -1):
        match = NAME.match(lines[i])
        if match:
            return match.group(1)
    return None


def check(text: str, fix: bool) -> tuple[list[str], str]:
    lines = text.split("\n")
    problems: list[str] = []
    marked: set[str] = set()
    out: list[str] = []
    i = 0
    while i < len(lines):
        out.append(lines[i])
        if not OPEN.match(lines[i]):
            i += 1
            continue
        name = target_name(lines, i) or f"line {i + 1}"
        marked.add(name)
        try:
            entries, close = entries_of(lines, i)
        except ListError as error:
            problems.append(f"{name}: {error}")
            i += 1
            continue
        seen: set[str] = set()
        for _, entry in entries:
            if key(entry) in seen:
                problems.append(f"{name}: duplicate entry {key(entry)}")
            seen.add(key(entry))
        indent = {len(entry) - len(entry.lstrip()) for _, entry in entries}
        if len(indent) > 1:
            problems.append(f"{name}: entries are not all indented alike")
        ordered = sorted(entries, key=lambda pair: key(pair[1]))
        if ordered != entries:
            problems.append(f"{name}: entries are not sorted (run with --fix)")
        for comments, entry in ordered if fix else entries:
            out.extend(comments)
            out.append(entry)
        out.append(lines[close])
        i = close + 1
    for name in REQUIRED:
        if name not in marked:
            problems.append(f"{name}: its dependencies list lacks the marker `{MARKER}`")
    return problems, "\n".join(out)


def closing(text: str, start: int) -> int:
    """Index of the bracket that closes the `(` or `[` at START, skipping string literals and `//` comments;
    -1 when it never closes."""
    pairs = {"(": ")", "[": "]"}
    stack = [pairs[text[start]]]
    i = start + 1
    while i < len(text):
        char = text[i]
        if char == '"':
            i += 1
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif text.startswith("//", i):
            newline = text.find("\n", i)
            i = len(text) if newline < 0 else newline
            continue
        elif char in pairs:
            stack.append(pairs[char])
        elif char in ")]":
            if char != stack.pop():
                return -1
            if not stack:
                return i
        i += 1
    return -1


def without_comments(text: str) -> str:
    """TEXT with its `//` and (nested) `/* */` comments blanked to spaces, newlines kept, so every index still points
    at the same character; string literals are left as they are."""
    out = list(text)
    i = 0
    while i < len(text):
        if text[i] == '"':
            i += 1
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            end = len(text) if end < 0 else end
            out[i:end] = " " * (end - i)
            i = end
        elif text.startswith("/*", i):
            start, depth, i = i, 1, i + 2
            while i < len(text) and depth:
                if text.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif text.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            out[start:i] = [c if c == "\n" else " " for c in text[start:i]]
        else:
            i += 1
    return "".join(out)


def target_spans(text: str) -> dict[str, tuple[str, int, int]]:
    """{name: (kind, the index of its `(`, the index of the `)` that closes it)} for each target the manifest
    declares (`.target(`, `.testTarget(`, `.executableTarget(`), its arguments on that line or on the next ones
    (review of 6e507c72: `.target(name: "CmuxNextMallocZone")` on one line was never read). A `.target(name:)`
    inside another target's call is a dependency, not a declaration; a `//` or `/* */` comment declares nothing
    (review of c9beb1af: a commented-out duplicate after the real one replaced its span)."""
    text = without_comments(text)
    spans = {}
    inside = -1  # the end of the last target's call: a match before it is nested in that call
    for match in re.finditer(r"\.(target|testTarget|executableTarget)\(", text):
        open_at = match.end() - 1
        if open_at < inside:
            continue
        close_at = closing(text, open_at)
        if close_at < 0:
            continue
        name = re.search(r'name:\s*"([^"]+)"', text[open_at:close_at])
        if name:
            spans[name.group(1)] = (match.group(1), open_at, close_at)
            inside = close_at
    return spans


def argument(text: str, open_at: int, close_at: int, label: str) -> tuple[int, int] | None:
    """(index of the `[` after `LABEL:`, index of its closing `]`) for a top-level argument of the call whose
    parentheses are at OPEN_AT..CLOSE_AT, or None when the call has no such argument."""
    i = open_at + 1
    while i < close_at:
        char = text[i]
        if char == '"':
            i += 1
            while i < close_at and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
            continue
        if text.startswith("//", i):
            newline = text.find("\n", i)
            i = close_at if newline < 0 else newline
            continue
        if char in "([":
            i = closing(text, i) + 1
            if i <= 0:
                return None
            continue
        found = re.match(rf"{re.escape(label)}:\s*\[", text[i:close_at])
        if found and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
            bracket = i + found.end() - 1
            end = closing(text, bracket)
            return (bracket, end) if end > 0 else None
        i += 1
    return None


def top_level_strings(text: str, open_at: int, close_at: int) -> list[str]:
    """The string-literal entries of the array at OPEN_AT..CLOSE_AT: not strings inside a call such as
    `.product(name: "X", package: "X")`, and not comments."""
    found, i = [], open_at + 1
    while i < close_at:
        char = text[i]
        if char == '"':
            end = text.index('"', i + 1)
            found.append(text[i + 1:end])
            i = end + 1
        elif text.startswith("//", i):
            newline = text.find("\n", i)
            i = close_at if newline < 0 else newline
        elif char in "([":
            i = closing(text, i) + 1 or close_at
        else:
            i += 1
    return [name for name in found if re.fullmatch(r"[A-Za-z0-9_]+", name)]


def manifest_targets(text: str) -> dict[str, tuple[str, set[str], str | None]]:
    """{name: (kind, the local target names in its dependencies, its `path:` or None)} from the manifest text. The
    dependencies are the string entries of the target's own `dependencies:` array, matched bracket for bracket (a
    regex up to the next `]` read a following `resources:` list as dependencies). Comments are blanked first: a
    `/* dependencies: ["X"] */` declares nothing (review of 3f01de17)."""
    text = without_comments(text)
    targets = {}
    for name, (kind, open_at, close_at) in target_spans(text).items():
        span = argument(text, open_at, close_at, "dependencies")
        declared = set(top_level_strings(text, span[0], span[1])) if span else set()
        if span:
            # `.target(name: "X")`, the form that tells a target from a product of the same name.
            declared |= set(re.findall(r'\.target\(\s*name:\s*"([A-Za-z0-9_]+)"', text[span[0]:span[1]]))
        path = re.search(r'path:\s*"([^"]+)"', text[open_at:close_at])
        targets[name] = (kind, declared, path.group(1) if path else None)
    return targets


def undeclared_imports(text: str, package_root: Path) -> list[str]:
    """`Target: Module` for each local target a target's sources import without declaring it."""
    targets = manifest_targets(text)
    found = set()
    for name, (kind, declared, path) in targets.items():
        folder = package_root / (path or (("Tests" if kind == "testTarget" else "Sources") + "/" + name))
        for source in sorted(folder.rglob("*.swift")):
            # Comments and string contents masked: a test's golden source that says `import X` imports nothing.
            for line in mask_swift_source(source.read_text(encoding="utf-8", errors="replace")).split("\n"):
                match = IMPORT.match(line)
                if match and match.group(5) in targets and match.group(5) != name and match.group(5) not in declared:
                    found.add(f"{name}: {match.group(5)}")
    return sorted(found)


def missing_imports(text: str, package_root: Path) -> list[tuple[str, str]]:
    """(target, module) for each undeclared import IMPORT_BASELINE does not hold: what --fix-imports declares."""
    return [tuple(pair.split(": ", 1)) for pair in undeclared_imports(text, package_root) if pair not in IMPORT_BASELINE]


def import_problems(text: str, package_root: Path) -> list[str]:
    found = undeclared_imports(text, package_root)
    problems = [f"{target}: imports {module} but does not declare it in its dependencies (an incremental build then "
                f"keeps objects compiled against its old interface). Fix: add \"{module}\" to the dependencies of {target}, "
                "or run scripts/cmux-next/check-package-dependency-lists.py --fix-imports"
                for target, module in missing_imports(text, package_root)]
    problems += [f"IMPORT_BASELINE lists {pair}, which is declared or gone now: drop its line"
                 for pair in sorted(IMPORT_BASELINE - set(found))]
    return problems


class FixError(Exception):
    pass


def add_dependency(text: str, target: str, module: str) -> str:
    """TEXT with "MODULE" added to TARGET's own `dependencies:` array (see --fix-imports); FixError when it can't be.
    The array is found bracket for bracket inside the target's call, never by the next `]` on a line."""
    span = target_spans(text).get(target)
    if span is None:
        raise FixError(f"no target named {target}")
    _, open_at, close_at = span
    entry = f'"{module}"'
    code = without_comments(text)  # same indices as TEXT; a commented-out `dependencies:` is not the array
    deps = argument(code, open_at, close_at, "dependencies")
    if deps is None:  # no dependencies yet: one goes right after the name (SwiftPM's argument order)
        name = re.search(r'name:\s*"[^"]+"', code[open_at:close_at])
        end = open_at + name.end()
        if "\n" not in text[open_at:close_at]:  # a one-line call stays on its line
            return text[:end] + f", dependencies: [{entry}]" + text[end:]
        line_start = text.rfind("\n", 0, open_at + name.start()) + 1
        indent = text[line_start:open_at + name.start()]
        if not indent.strip() == "":  # `name:` shares its line with `.target(`: indent one step past it
            indent = " " * (len(indent) - len(indent.lstrip()) + 4)
        rest = text[end:close_at]
        if rest.lstrip().startswith(","):
            comma = end + rest.index(",")
            return text[:comma + 1] + f"\n{indent}dependencies: [{entry}]," + text[comma + 1:]
        return text[:end] + f",\n{indent}dependencies: [{entry}]" + text[end:]
    bracket, end = deps
    line_start = text.rfind("\n", 0, bracket) + 1
    line_end = text.find("\n", bracket)
    if OPEN.match(text[line_start:line_end if line_end >= 0 else len(text)]):
        lines = text.split("\n")
        start = text.count("\n", 0, bracket)
        entries, close = entries_of(lines, start)
        indent = (entries[0][1][:len(entries[0][1]) - len(entries[0][1].lstrip())] if entries
                  else OPEN.match(lines[start]).group(1) + "    ")
        lines.insert(close, f"{indent}{entry},")
        return check("\n".join(lines), fix=True)[1]
    inside = text[bracket + 1:end]
    last = code_end(inside)  # the end of the last entry (or of a trailing comma), before any trailing comment
    if last == 0:  # no entry yet; a comment-only list keeps its comment after the new entry
        return text[:bracket + 1] + entry + (text[bracket + 1:] if inside.strip() else text[end:])
    if "\n" not in inside[last:]:  # the `]` follows the last entry on its line: `"A", "B"]` or `...)]`
        separator = " " if inside[:last].endswith(",") else ", "
        return text[:bracket + 1 + last] + separator + entry + text[bracket + 1 + last:]
    # The `]` on a line of its own: a new line before it, indented like the last entry, after that entry's line (its
    # comment stays with it).
    previous_start = inside.rfind("\n", 0, last) + 1
    previous = inside[previous_start:last]
    indent = previous[:len(previous) - len(previous.lstrip())]
    comma = "" if inside[:last].endswith(",") else ","
    at, line_end = bracket + 1 + last, bracket + 1 + inside.index("\n", last)
    return text[:at] + comma + text[at:line_end] + f"\n{indent}{entry}," + text[line_end:]


def code_end(inside: str) -> int:
    """The index just past the last character of INSIDE that is code, not whitespace or a `//` comment."""
    end = i = 0
    while i < len(inside):
        if inside[i] == '"':
            i += 1
            while i < len(inside) and inside[i] != '"':
                i += 2 if inside[i] == "\\" else 1
            end = i = i + 1
        elif inside.startswith("//", i):
            newline = inside.find("\n", i)
            i = len(inside) if newline < 0 else newline
        else:
            end = i + 1 if not inside[i].isspace() else end
            i += 1
    return min(end, len(inside))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fix", action="store_true")
    parser.add_argument("--fix-imports", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("manifest", nargs="?", type=Path, default=DEFAULT_MANIFEST)
    args = parser.parse_args()
    # With --json, stdout is exactly one JSON object: what a fixer did goes to stderr.
    human = sys.stderr if args.json else sys.stdout
    text = args.manifest.read_text(encoding="utf-8")
    problems, fixed = check(text, args.fix)
    if args.fix:
        if fixed != text:
            args.manifest.write_text(fixed, encoding="utf-8")
            print(f"sorted the dependency lists in {args.manifest}", file=human)
        problems, _ = check(fixed, False)
        text = fixed
    package_tree = (args.manifest.parent / "Sources").is_dir()  # a package tree, not a bare manifest (the tests' --fix runs)
    missing = missing_imports(text, args.manifest.parent) if package_tree else []
    if args.fix_imports and missing:
        declared = text
        for target, module in missing:
            try:
                declared = add_dependency(declared, target, module)
                print(f"declared {module} in the dependencies of {target}", file=human)
            except (FixError, ListError) as error:
                print(f"{args.manifest}: could not declare {module} in {target}: {error}", file=sys.stderr)
        args.manifest.write_text(declared, encoding="utf-8")
        text = declared
        problems, _ = check(text, False)
        missing = missing_imports(text, args.manifest.parent)
    if package_tree:
        problems += import_problems(text, args.manifest.parent)
    if args.json:
        print(json.dumps({"problems": problems, "missing": [{"target": t, "module": m} for t, m in missing]}))
    for problem in problems:
        print(f"{args.manifest}: {problem}", file=sys.stderr)
    if problems:
        print("One dependency per line, sorted, trailing comma; `--fix` sorts a list.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

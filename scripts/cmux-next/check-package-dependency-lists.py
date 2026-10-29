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
package (2026-10-29: a63986a4 and e875485c each added a test import its target did not declare, straight to
the branch, and "Package dependency lists sorted" was red on every pull request after them until #27173 and
#27219).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
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
    "CmuxNextMobileHostTests: CmuxNextMobile",
    "CmuxNextPaletteTests: CmuxNextActions", "CmuxNextPaletteTests: CmuxNextDesign",
    "CmuxNextPhoneAccessTests: CmuxNextMobile",
) + tuple(f"CmuxNextAppTests: {module}" for module in (
    "CmuxNextAccounts", "CmuxNextAgentActivity", "CmuxNextAgentPane", "CmuxNextBookmarks", "CmuxNextBridge",
    "CmuxNextBrowser", "CmuxNextCloud", "CmuxNextCodeRouter", "CmuxNextControl", "CmuxNextDesignTokens",
    "CmuxNextDevices", "CmuxNextErrorJournal", "CmuxNextHostPressure", "CmuxNextIcons",
    "CmuxNextPages", "CmuxNextPopups", "CmuxNextRemoteBrowser", "CmuxNextRemoteLocalhost", "CmuxNextRemoteView",
    "CmuxNextResources", "CmuxNextServer", "CmuxNextSettingsWindow",
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


def manifest_targets(text: str) -> dict[str, tuple[str, set[str], str | None]]:
    """{name: (kind, the local target names in its dependencies, its `path:` or None)} from the manifest text."""
    lines = text.split("\n")
    targets = {}
    for index, line in enumerate(lines):
        kind = TARGET.match(line)
        if not kind:
            continue
        depth, body = 0, []
        for inner in lines[index:]:
            body.append(inner)
            depth += inner.count("(") - inner.count(")")
            if depth <= 0:
                break
        block = "\n".join(body)
        name = re.search(r'name:\s*"([^"]+)"', block)
        if not name:
            continue
        deps = re.search(r"dependencies:\s*\[(.*?)\n\s*\]", block, re.S) or re.search(r"dependencies:\s*\[(.*?)\]", block, re.S)
        declared = set(re.findall(r'^\s*"([A-Za-z0-9_]+)"', deps.group(1), re.M)) if deps else set()
        if deps:
            declared |= set(re.findall(r'(?:\[|,)\s*"([A-Za-z0-9_]+)"', deps.group(1)))
        path = re.search(r'path:\s*"([^"]+)"', block)
        targets[name.group(1)] = (kind.group(1), declared, path.group(1) if path else None)
    return targets


def undeclared_imports(text: str, package_root: Path) -> list[str]:
    """`Target: Module` for each local target a target's sources import without declaring it."""
    targets = manifest_targets(text)
    found = set()
    for name, (kind, declared, path) in targets.items():
        folder = package_root / (path or (("Tests" if kind == "testTarget" else "Sources") + "/" + name))
        for source in sorted(folder.rglob("*.swift")):
            for line in source.read_text(encoding="utf-8", errors="replace").split("\n"):
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
    """TEXT with "MODULE" added to TARGET's dependencies list (see --fix-imports); FixError when it can't be."""
    lines = text.split("\n")
    start = next((i for i, line in enumerate(lines) if TARGET.match(line)
                  and any(re.search(rf'name:\s*"{re.escape(target)}"', lines[j]) for j in range(i, min(i + 3, len(lines))))),
                 None)
    if start is None:
        raise FixError(f"no target named {target}")
    depth, end = 0, start
    for end in range(start, len(lines)):
        depth += lines[end].count("(") - lines[end].count(")")
        if depth <= 0:
            break
    entry = f'"{module}"'
    for i in range(start, end + 1):
        line = lines[i]
        if not re.match(r"^\s*dependencies:\s*\[", line):
            continue
        if OPEN.match(line):  # a marked list: one line per entry, then canonical order
            entries, close = entries_of(lines, i)
            indent = (entries[0][1][:len(entries[0][1]) - len(entries[0][1].lstrip())] if entries
                      else OPEN.match(line).group(1) + "    ")
            lines.insert(close, f"{indent}{entry},")
            return check("\n".join(lines), fix=True)[1]
        if top_level_brackets_close(line):  # inline: `dependencies: ["A", "B"],`
            head, _, tail = line.rpartition("]")
            inside = head[head.index("[") + 1:].strip()
            lines[i] = f"{head}{', ' if inside and not inside.endswith(',') else ''}{entry}]{tail}"
            return "\n".join(lines)
        for close in range(i + 1, end + 1):  # multi-line: its own line before the closing bracket
            if lines[close].strip() in ("]", "],"):
                previous = close - 1
                if previous > i and lines[previous].strip() and not lines[previous].rstrip().endswith(","):
                    lines[previous] = lines[previous].rstrip() + ","
                body = lines[previous] if previous > i else lines[close] + "    "
                indent = body[:len(body) - len(body.lstrip())]
                lines.insert(close, f"{indent}{entry},")
                return "\n".join(lines)
        raise FixError(f"{target}: its dependencies list never closes")
    # No dependencies at all: one goes after the name.
    name_line = next(j for j in range(start, end + 1) if re.search(r'name:\s*"', lines[j]))
    indent = lines[name_line][:len(lines[name_line]) - len(lines[name_line].lstrip())]
    lines.insert(name_line + 1, f"{indent}dependencies: [{entry}],")
    return "\n".join(lines)


def top_level_brackets_close(line: str) -> bool:
    """The `[` this dependencies line opens closes on the same line."""
    depth = 0
    quoted = False
    for char in line[line.index("["):]:
        if char == '"':
            quoted = not quoted
        elif quoted:
            continue
        elif char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
            if depth == 0:
                return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fix", action="store_true")
    parser.add_argument("--fix-imports", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("manifest", nargs="?", type=Path, default=DEFAULT_MANIFEST)
    args = parser.parse_args()
    text = args.manifest.read_text(encoding="utf-8")
    problems, fixed = check(text, args.fix)
    if args.fix:
        if fixed != text:
            args.manifest.write_text(fixed, encoding="utf-8")
            print(f"sorted the dependency lists in {args.manifest}")
        problems, _ = check(fixed, False)
        text = fixed
    package_tree = (args.manifest.parent / "Sources").is_dir()  # a package tree, not a bare manifest (the tests' --fix runs)
    missing = missing_imports(text, args.manifest.parent) if package_tree else []
    if args.fix_imports and missing:
        declared = text
        for target, module in missing:
            try:
                declared = add_dependency(declared, target, module)
                print(f"declared {module} in the dependencies of {target}")
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

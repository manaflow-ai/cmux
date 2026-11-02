#!/usr/bin/env python3
"""Swift logic and mirror lines: how much Swift state and logic must still move to Rust (rust-migration step 4).

plans/cmux-next/layer-ownership.md (binding) says Rust owns every state, list and rule and Swift is only the platform
shell; Lawrence 2026-11-02: "move as much from swift into rust as possible." This script measures what is left. It is a
report, never a CI job and not a pre-push gate: the tip watcher (cmux-ad's) runs it per tip and turns a row red when it
rises over the last green tip.

  python3 -I scripts/cmux-next/swift-logic-lines.py --repo ROOT --rev SHA --json   one JSON object (below)
  python3 -I scripts/cmux-next/swift-logic-lines.py --rev SHA                      the totals, as text
  python3 -I scripts/cmux-next/swift-logic-lines.py --rev SHA --sites ROW          the counted declarations of ROW
                                                         (swift_logic_lines, mirror_lines or unlisted), file:line
  python3 -I scripts/cmux-next/swift-logic-lines.py --rev SHA --missing            table rows no declaration matches
  ... --table FILE                                       the table from FILE, not from SHA (a baseline before it landed)

It reads git objects at SHA only (no working tree), with the standard library and arch_counts.py next to it (the same
checkout): the scope, the comment and string blanking and the declaration patterns are arch_counts'.

Scope: every tracked Swift file under the Sources of CmuxNext and its local `.package(path:)` closure at SHA
(arch_counts.read_paths); a file's module is the directory after `Sources/` (arch_counts.package_of).

Unit: each top-level declaration (class, struct, enum, actor, protocol, extension, and file-scope func, var, let,
typealias) of the blanked code (comments and strings blanked, so a declaration in a comment or a string is none) and
its line span: from its first attribute line to the line of its closing brace (a type, a func), or to the end of its
statement (a file-scope let/var/typealias: past brackets, braces and multi-line strings, to the `;` or the newline that
no operator carries on). Lines outside every declaration (imports, header comments, `#if` lines, top-level statements
of a main.swift) never count. A declaration inside `#if` counts like any other.

Table: plans/cmux-next/swift-logic-classes.tsv at SHA, tab-separated, first line exactly
`module kind name ordinal class logic_share mirror_share path reason` (--table FILE reads another copy). Its key is (module, kind, name, ordinal): the
ordinal is the 0-based index among the module's top-level declarations with the same kind and name, in (repo-relative
path, line) order. So a file moved or renamed inside its module keeps its rows, and a declaration moved to another
Swift module or renamed loses its row and counts as an unlisted one (moving logic to another Swift package never lowers
a count; only a move into Rust does). An extension's name is as written (`extension Notification.Name`), without
generic arguments. Class and shares: LOGIC 100/0, MIRROR 0/100, PLATFORM and GENERATED 0/0, MIXED any two integer
percents whose sum is at most 100 (the reader's fixed split; only a code change moves a count, never an estimate).
A row with another shape is ignored (its declaration counts as unlisted) and counted in `table_rows_invalid`; for two
rows with one key, the one with the higher logic + mirror sum counts.

Count of a listed declaration: swift_logic_lines += floor(span * logic_share / 100 + 0.5), mirror_lines +=
floor(span * mirror_share / 100 + 0.5), its span read now (a declaration that grows counts its new lines).
An unlisted declaration counts its full span in swift_logic_lines, unless its header (the text between its name and its
`{`) is view-shaped: its own inheritance clause (not a generic parameter's constraint, not a `where` clause) names View,
NSView, NSViewRepresentable, NSViewControllerRepresentable, NSViewController, NSWindowController, NSWindow, NSPanel,
NSResponder, CALayer, ViewModifier, ShapeStyle, Shape, ButtonStyle, LabelStyle, ToggleStyle or PreviewProvider (a
module prefix such as `SwiftUI.View` is read through), or it is an extension of one of them (`extension View`); then 0.
Only the header is read: `extension BadgeView` of a view declared elsewhere counts in full unless the table lists it.
An unlisted declaration of a generated file counts 0 too: a file named `*.generated.swift` or `*+Generated.swift`, or
one whose leading comment block (the comment lines before its first code line) has a line that opens with `Generated
by`, `Generated from`, `This file was generated from`, `@generated` or `Code generated`, as the repo's generators write it (codegen output moves when its generator does).

JSON (--json): {"method": "swift-logic-lines", "method_version", "sha", "rows": {"swift_logic_lines": n,
"mirror_lines": n}, "packages": {module: {row: n}} (rows that are not 0), "unlisted": {"lines": the swift_logic_lines
lines of unlisted declarations, "declarations": unlisted declarations, "view_shaped": unlisted view-shaped ones, "generated": unlisted ones of generated files,
"in_table_modules" and "other_modules": those lines in the modules the table has rows for (an unclassified declaration
there) and in the others (closure packages that only the default rule counts yet), "packages": {module: lines}}, "table_rows": valid rows, "table_rows_missing": valid rows that no declaration at SHA
matches, "table_rows_invalid": n}.

Each file's declarations are kept by (blob id, path) in arch_counts' facts cache under this script's fingerprint, so
a second count reads only the files that changed. Tests: scripts/cmux-next/tests/test_swift_logic_lines.py (run them
yourself, `python3 -I scripts/cmux-next/tests/test_swift_logic_lines.py`; no CI job runs them).
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
METHOD = "swift-logic-lines"
METHOD_VERSION = 1
TABLE = "plans/cmux-next/swift-logic-classes.tsv"
LOGIC = "swift_logic_lines"
MIRROR = "mirror_lines"
ROWS = (LOGIC, MIRROR)
HEADER = ("module", "kind", "name", "ordinal", "class", "logic_share", "mirror_share", "path", "reason")
KINDS = frozenset({"class", "struct", "enum", "actor", "protocol", "extension", "func", "var", "let", "typealias"})
# class: the (logic_share, mirror_share) it must carry; None: any pair whose sum is at most 100.
CLASSES = {"LOGIC": (100, 0), "MIRROR": (0, 100), "PLATFORM": (0, 0), "GENERATED": (0, 0), "MIXED": None}
VIEW_TYPES = frozenset({
    "View", "NSView", "NSViewRepresentable", "NSViewControllerRepresentable", "NSViewController",
    "NSWindowController", "NSWindow", "NSPanel", "NSResponder", "CALayer", "ViewModifier", "ShapeStyle", "Shape",
    "ButtonStyle", "LabelStyle", "ToggleStyle", "PreviewProvider",
})
_TYPE_KINDS = frozenset({"class", "struct", "enum", "actor", "protocol", "extension"})
# A file-scope let/var/typealias statement goes on past a newline when its line ends in an operator, or when the next
# code line starts with one (`.map {`, `?? x`, the `{` of a computed body).
_CONTINUES_AFTER = re.compile(r"(?:[=,(\[+\-*/%&|.:]|->|\?\?)[ \t]*$")
_CONTINUES_BEFORE = re.compile(r"[ \t]*(?:\.(?!\.)|&&|\|\||\?\?|\?|:|[+*/%&|{=]|->|where\b)")
# Codegen output: a file named so, or whose leading comment block (before its first code line) says so, as the repo's
# generators write it (`// GENERATED by scripts/cmux-next/gen-settings-sources.py from ...`).
GENERATED_NAME = re.compile(r"(?i)[.+]generated\.swift$")
# The claim opens the comment line: prose that mentions generated values (`// The defaults are generated from ...`) is none.
GENERATED_HEADER = re.compile(r"(?i)^[ \t]*//[ \t]*(?:@generated\b|(?:this file (?:was|is) )?(?:auto-?)?generated (?:by|from)\b|"
                              r"code generated\b)")
FINGERPRINT = hashlib.sha1(Path(__file__).read_bytes()).hexdigest()[:16]


def load_counts():
    """arch_counts.py next to this file (its scope, blanking and declaration patterns)."""
    name = "cmux_next_arch_counts"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, HERE / "arch_counts.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


AC = load_counts()


@dataclasses.dataclass(frozen=True)
class Unit:
    """A top-level declaration: kind, name, 1-based first line, lines spanned, whether its header is view-shaped and
    whether its file is generated (generated())."""

    kind: str
    name: str
    line: int
    span: int
    view: bool
    generated: bool = False


@dataclasses.dataclass(frozen=True)
class Entry:
    """A row of the table."""

    cls: str
    logic: int
    mirror: int
    path: str = ""
    reason: str = ""


def view_shaped(kind: str, name: str, header: str) -> bool:
    """Whether a type declaration with HEADER (the text between its name and its `{`) is view-shaped (docstring)."""
    if kind not in _TYPE_KINDS:
        return False
    if kind == "extension" and name.split(".")[-1] in VIEW_TYPES:
        return True
    rest = header.lstrip()
    if rest.startswith("<"):  # the generic parameter clause: a constraint there is no conformance
        depth = 0
        for i, c in enumerate(rest):
            depth += (c == "<") - (c == ">")
            if depth == 0:
                rest = rest[i + 1:].lstrip()
                break
        else:
            return False
    if not rest.startswith(":"):
        return False
    clause = re.split(r"\bwhere\b", rest[1:], maxsplit=1)[0]
    while True:  # drop generic arguments, innermost first
        bare = re.sub(r"<[^<>]*>", "", clause)
        if bare == clause:
            break
        clause = bare
    for part in re.split(r"[,&]", clause):
        words = [w for w in part.split() if not w.startswith("@") and w not in ("any", "some")]
        if words and words[-1].split(".")[-1] in VIEW_TYPES:
            return True
    return False


def _statement_end(code: str, pos: int, braces) -> int:
    """The offset where the file-scope let/var/typealias statement that goes on at POS ends (docstring, Unit)."""
    n = len(code)
    depth = 0
    i = pos
    line_start = code.rfind("\n", 0, pos) + 1
    while i < n:
        c = code[i]
        if c == '"' and code.startswith('"""', i):  # a blanked multi-line string: its lines are blank
            j = code.find('"""', i + 3)
            i = n if j < 0 else j + 3
            continue
        if c in "([":
            depth += 1
        elif c in ")]":
            depth = max(0, depth - 1)
        elif c == "{":
            i = braces.close.get(i, n - 1) + 1
            continue
        elif c == "}" or (c == ";" and depth == 0):
            return i
        elif c == "\n":
            if depth == 0 and not _CONTINUES_AFTER.search(code[line_start:i]):
                j = i + 1
                while j < n:
                    k = code.find("\n", j)
                    k = n if k < 0 else k
                    if code[j:k].strip():
                        break
                    j = k + 1
                if j >= n or not _CONTINUES_BEFORE.match(code, j):
                    return i
            line_start = i + 1
        i += 1
    return n


def generated(path: str, raw: str) -> bool:
    """Whether the Swift file PATH with text RAW is codegen output: its name ends `.generated.swift` or
    `+Generated.swift`, or a line of its leading comment block (the comment and blank lines before its first code
    line) opens a line with `Generated by`, `Generated from`, `This file was generated from`, `@generated` or `Code
    generated` (GENERATED_HEADER; a mention later in a line is none)."""
    if GENERATED_NAME.search(path):
        return True
    for line in raw.split("\n"):
        text = line.strip()
        if not text:
            continue
        if not text.startswith(("//", "/*", "*")):
            return False
        if GENERATED_HEADER.match(line if text.startswith("//") else "// " + text):
            return True
    return False


def units(raw: str, path: str = "") -> list[Unit]:
    """The top-level declarations of the Swift text RAW at PATH, in file order."""
    made = generated(path, raw)
    code = AC.strip(raw)
    braces = AC.Braces(code)
    starts = [0] + [m.end() for m in re.finditer(r"\n", code)]
    code_lines = code.split("\n")
    n = len(code)
    found: list[tuple[int, int, str, str, bool]] = []  # (start offset, end offset, kind, name, view)
    for m in AC.TYPE_DECL.finditer(code):
        if braces.enclosing(m.start()):
            continue
        brace = code.find("{", m.end())
        if brace < 0 or ";" in code[m.end():brace]:
            continue
        kind, name = m.group(1), m.group(2)
        found.append((m.start(), braces.close.get(brace, n - 1) + 1, kind, name,
                      view_shaped(kind, name, code[m.end():brace])))
    for m in AC.FUNC_DECL.finditer(code):
        if braces.enclosing(m.start()):
            continue
        paren = AC._closing(code, m.end() - 1)
        brace = code.find("{", paren)
        end = braces.close.get(brace, n - 1) + 1 if brace >= 0 else min(n, paren + 1)
        found.append((m.start(), end, "func", m.group(2), False))
    for m in AC.STATIC.finditer(code):
        if braces.enclosing(m.start()) or re.search(r"\bstatic\b", m.group(1) or ""):
            continue
        if AC._in_condition_list(code_lines, AC._line_of(code, m.start(2), starts) - 1):
            continue  # a binding of a main.swift's top-level `guard`/`if`/`while` condition list
        found.append((m.start(), _statement_end(code, m.end(), braces), m.group(2), m.group(3).strip("`"), False))
    for m in AC.TYPEALIAS.finditer(code):
        if braces.enclosing(m.start()):
            continue
        found.append((m.start(), _statement_end(code, m.end(1), braces), "typealias", m.group(1), False))
    out = []
    for start, end, kind, name, view in sorted(found):
        # The patterns start at the line start of the first attribute line (`^[ \t]*`); a match after a `;` or a
        # `{` starts on its own line.
        first = AC._line_of(code, start + (1 if code.startswith("\n", start) else 0), starts)
        last = AC._line_of(code, max(start, end - 1), starts)
        out.append(Unit(kind, name, first, last - first + 1, view, made))
    return out


def parse_table(text: str | None) -> tuple[dict[tuple[str, str, str, int], Entry], int]:
    """({(module, kind, name, ordinal): entry}, invalid row count) of the table TEXT (docstring, Table)."""
    table: dict[tuple[str, str, str, int], Entry] = {}
    invalid = 0
    lines = [line.rstrip("\r") for line in (text or "").split("\n")]
    if tuple(lines[0].split("\t")) != HEADER:
        return table, sum(1 for line in lines[1:] if line.strip())
    for line in lines[1:]:
        if not line.strip():
            continue
        fields = line.split("\t", len(HEADER) - 1)
        if len(fields) < 7:
            invalid += 1
            continue
        module, kind, name, ordinal, cls, logic, mirror = fields[:7]
        if (cls not in CLASSES or kind not in KINDS or not module or not name
                or not all(v.isascii() and v.isdigit() for v in (ordinal, logic, mirror))):
            invalid += 1
            continue
        shares = (int(logic), int(mirror))
        if (CLASSES[cls] is not None and shares != CLASSES[cls]) or sum(shares) > 100:
            invalid += 1
            continue
        key = (module, kind, name, int(ordinal))
        entry = Entry(cls, shares[0], shares[1], fields[7] if len(fields) > 7 else "",
                      fields[8] if len(fields) > 8 else "")
        if key in table:
            invalid += 1  # the duplicate row: the one with the higher sum counts
            if sum(shares) <= table[key].logic + table[key].mirror:
                continue
        table[key] = entry
    return table, invalid


def _round(span: int, share: int) -> int:
    return (2 * span * share + 100) // 200  # floor(span * share / 100 + 0.5)


@dataclasses.dataclass
class Count:
    """The rows, per module, the unlisted part and the sites of one count."""

    sha: str
    rows: dict[str, collections.Counter]
    unlisted: collections.Counter  # module -> swift_logic_lines lines of unlisted declarations
    unlisted_declarations: int
    view_shaped: int
    generated: int  # unlisted declarations of generated files (they count 0)
    sites: dict[str, list[tuple[str, int, str]]]  # row or "unlisted" -> [(path, line, text)]
    table_rows: int
    missing: list[tuple[tuple[str, str, str, int], Entry]]
    invalid: int
    table_modules: frozenset = frozenset()  # the modules the table has a row for

    def json(self) -> dict:
        packages: dict[str, dict[str, int]] = collections.defaultdict(dict)
        for row in ROWS:
            for module, n in sorted(self.rows[row].items()):
                if n:
                    packages[module][row] = n
        return {
            "method": METHOD,
            "method_version": METHOD_VERSION,
            "sha": self.sha,
            "rows": {row: sum(self.rows[row].values()) for row in ROWS},
            "packages": dict(sorted(packages.items())),
            "unlisted": {"lines": sum(self.unlisted.values()), "declarations": self.unlisted_declarations,
                         "view_shaped": self.view_shaped, "generated": self.generated,
                         "in_table_modules": sum(n for m, n in self.unlisted.items() if m in self.table_modules),
                         "other_modules": sum(n for m, n in self.unlisted.items() if m not in self.table_modules),
                         "packages": {m: n for m, n in sorted(self.unlisted.items()) if n}},
            "table_rows": self.table_rows,
            "table_rows_missing": len(self.missing),
            "table_rows_invalid": self.invalid,
        }


def count_units(files: dict[str, list[Unit]], table_text: str | None, sha: str = "") -> Count:
    """The count of FILES ({path: its units}) by the table TABLE_TEXT."""
    table, invalid = parse_table(table_text)
    rows = {row: collections.Counter() for row in ROWS}
    unlisted: collections.Counter = collections.Counter()
    sites: dict[str, list[tuple[str, int, str]]] = {row: [] for row in ROWS + ("unlisted",)}
    seen: collections.Counter = collections.Counter()
    used: set = set()
    declarations = views = made = 0
    for path in sorted(files):
        module = AC.package_of(path)
        for u in files[path]:
            ordinal = seen[(module, u.kind, u.name)]
            seen[(module, u.kind, u.name)] += 1
            key = (module, u.kind, u.name, ordinal)
            entry = table.get(key)
            label = f"{u.kind} {u.name} #{ordinal}"
            if entry is not None:
                used.add(key)
                for row, share in ((LOGIC, entry.logic), (MIRROR, entry.mirror)):
                    n = _round(u.span, share)
                    if n:
                        rows[row][module] += n
                        sites[row].append((path, u.line, f"{label}: {n} of {u.span} lines ({entry.cls} {share}%)"))
                continue
            declarations += 1
            if u.generated:
                made += 1
                sites["unlisted"].append((path, u.line, f"{label}: 0 of {u.span} lines (unlisted, generated file)"))
                continue
            if u.view:
                views += 1
                sites["unlisted"].append((path, u.line, f"{label}: 0 of {u.span} lines (unlisted, view-shaped)"))
                continue
            rows[LOGIC][module] += u.span
            unlisted[module] += u.span
            sites[LOGIC].append((path, u.line, f"{label}: {u.span} of {u.span} lines (unlisted)"))
            sites["unlisted"].append((path, u.line, f"{label}: {u.span} of {u.span} lines (unlisted)"))
    missing = [(key, entry) for key, entry in sorted(table.items()) if key not in used]
    return Count(sha, rows, unlisted, declarations, views, made, sites, len(table), missing, invalid,
                 frozenset(key[0] for key in table))


def count(repo: Path, rev: str = "HEAD", cache: bool = True, table_text: str | None = None) -> Count:
    """The count at REV, from git objects: the closure's Swift (arch_counts.read_paths) and the table at REV (or
    TABLE_TEXT: a baseline of a revision that has no table yet)."""
    git = AC.Git(repo)
    sha = git.rev(rev)
    store = AC.FactsCache(git, cache)
    try:
        scope = AC._scope(git, sha, store)
        scope.check()
        blobs = git.swift_blobs(sha, scope)
        files: dict[str, list[Unit]] = {}
        missing = []
        for path, blob in blobs.items():
            text = store.get_text(f"{METHOD}:{FINGERPRINT}:{blob}:{path}")
            if text is None:
                missing.append((blob, path))
            else:
                files[path] = [Unit(*u) for u in json.loads(text)]
        if missing:
            texts = git.read_blobs(missing)
            for blob, path in missing:
                found = units(texts[(blob, path)] or "", path)
                files[path] = found
                store.put_text(f"{METHOD}:{FINGERPRINT}:{blob}:{path}",
                               json.dumps([[u.kind, u.name, u.line, u.span, u.view, u.generated] for u in found],
                                          separators=(",", ":")))
        table = table_text if table_text is not None else git.read([(sha, TABLE)])[(sha, TABLE)]
    finally:
        store.flush()
    return count_units(files, table, sha)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=None)
    parser.add_argument("--rev", default="HEAD")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--sites", metavar="ROW", choices=ROWS + ("unlisted",),
                        help="print the counted declarations of ROW (or every unlisted one), file:line")
    parser.add_argument("--missing", action="store_true", help="print the table rows that no declaration matches")
    parser.add_argument("--table", metavar="FILE",
                        help="read the table from FILE instead of the revision's (a baseline before the table landed)")
    parser.add_argument("--no-cache", action="store_true")
    args = parser.parse_args(argv)
    repo = Path(args.repo).resolve() if args.repo else Path(
        subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip())
    table_text = Path(args.table).read_text() if args.table else None
    found = count(repo, args.rev, cache=not args.no_cache, table_text=table_text)
    if args.sites:
        for path, line, text in found.sites[args.sites]:
            print(f"{path}:{line}: {text}")
        return 0
    if args.missing:
        for (module, kind, name, ordinal), entry in found.missing:
            print(f"{module}\t{kind}\t{name}\t{ordinal}\t{entry.cls}\t{entry.path}")
        return 0
    data = found.json()
    if args.json:
        print(json.dumps(data, sort_keys=True))
        return 0
    print(f"{METHOD} v{METHOD_VERSION} at {found.sha[:11]}")
    for row in ROWS:
        print(f"  {row:18} {data['rows'][row]}")
    u = data["unlisted"]
    print(f"  unlisted           {u['lines']} lines in {u['declarations']} declarations ({u['view_shaped']} view-shaped)")
    print(f"  table              {data['table_rows']} rows, {data['table_rows_missing']} missing, "
          f"{data['table_rows_invalid']} invalid")
    return 0


if __name__ == "__main__":
    sys.exit(main())

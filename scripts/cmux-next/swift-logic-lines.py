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

Unit: each top-level declaration (class, struct, enum, actor, protocol, extension, also of a shorthand type such as
`extension [UInt8]`, and file-scope func, var, let, typealias; at a line start or after a `}` or `;` on its line) of the
blanked code (comments and strings blanked, so a declaration in a comment or a string is none) and its line span: from
its first attribute line to the line of its closing brace (a type; a func whose body `{` follows its parameter list
with only signature text between, `throws` or `-> T` on later lines too), or to the end of its statement (a func with
no body: its signature; a file-scope let/var/typealias: past brackets, braces and multi-line strings, to the `;` or the
newline that no operator carries on). A line counts once: a declaration that starts on a line another one already spans
counts from the next line (`let a = 1; let b = 2`: a 1 line, b 0) and still reports its own line. The top-level
statements of a main.swift (its code lines outside every declaration, not an import or a `#if`-style directive) are
one more unit, kind `main`, name `main.swift` (its non-blank lines, a multi-line string's too). Other lines
outside every declaration (imports, header comments, `#if` lines) never count. A declaration inside `#if` counts like
any other. Known limit: an `#if` whose branches open and close braces unevenly makes the brace before it run to the
end of the file (arch_counts.Braces); the lines are put under the wrong declaration, none is hidden.

Table: plans/cmux-next/swift-logic-classes.tsv at SHA, tab-separated, first line exactly
`module kind name ordinal class logic_share mirror_share path reason` (--table FILE reads another copy). `path` is the
declaration's repo-relative file. Its key is (module, the path inside the module's `Sources/<module>/` folder, kind,
name, ordinal): the ordinal is the 0-based index among that file's top-level declarations with the same kind and name,
in line order. So a new or deleted file never shifts another file's keys; a file moved or renamed, a declaration moved
to another file or Swift module, or a renamed declaration loses its row and counts as an unlisted one until the table
follows (moving logic inside Swift never lowers a count; only a move into Rust does). A row whose path has no
`Sources/<module>/` folder, or whose folder is not its module column, is invalid. An extension's name is as written
(`extension Notification.Name`, `extension [String:Int]` without spaces), without generic arguments. Class and
shares: LOGIC 100/0, MIRROR 0/100, PLATFORM and GENERATED 0/0, MIXED any two integer percents whose sum is at most 100
(the reader's fixed split; only a code change moves a count, never an estimate). A row with another shape is ignored
(its declaration counts as unlisted) and counted in `table_rows_invalid`; for two rows with one key, the larger
logic share and the larger mirror share count (a duplicate never lowers a row).

Count of a listed declaration: swift_logic_lines += floor(span * logic_share / 100 + 0.5), mirror_lines +=
floor(span * mirror_share / 100 + 0.5), its span read now (a declaration that grows counts its new lines).
An unlisted declaration counts its full span in swift_logic_lines, unless its header (the text between its name and its
`{`) is view-shaped: its own inheritance clause (not a generic parameter's constraint, not a `where` clause) names View,
NSView, NSViewRepresentable, NSViewControllerRepresentable, NSViewController, NSWindowController, NSWindow, NSPanel,
NSResponder, CALayer, ViewModifier, ShapeStyle, Shape, ButtonStyle, LabelStyle, ToggleStyle or PreviewProvider (a
module prefix such as `SwiftUI.View` is read through), or it is an extension of one of them (`extension View`); then 0.
Only the header is read: `extension BadgeView` of a view declared elsewhere counts in full unless the table lists it.
An unlisted declaration of a reviewed generator's output counts 0 too: its path matches a GENERATORS glob and its
leading comment block (the comment lines before its first code line) has a line that opens with `Generated by`,
`Generated from`, `This file was generated from`, `@generated` or `Code generated` and names that generator. A header
alone or a generated-looking file name hides nothing; a new generator output is a reviewed change of GENERATORS.

JSON (--json): {"method": "swift-logic-lines", "method_version", "sha", "rows": {"swift_logic_lines": n,
"mirror_lines": n}, "packages": {module: {row: n}} (rows that are not 0), "unlisted": {"lines": the swift_logic_lines
lines of unlisted declarations, "declarations": unlisted declarations, "view_shaped": unlisted view-shaped ones,
"generated" and "generated_lines": unlisted ones of generator output and their lines (they count 0),
"in_table_modules" and "other_modules": the lines in the modules the table has rows for (an unclassified declaration
there) and in the others (closure packages that only the default rule counts yet), "packages": {module: lines}},
"table_rows": valid rows, "table_rows_missing": valid rows that no declaration at SHA matches, "table_rows_invalid": n}.

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
METHOD_VERSION = 2  # v2: the table key is per file; a main.swift's statements count (counts not comparable with v1)
TABLE = "plans/cmux-next/swift-logic-classes.tsv"
LOGIC = "swift_logic_lines"
MIRROR = "mirror_lines"
ROWS = (LOGIC, MIRROR)
HEADER = ("module", "kind", "name", "ordinal", "class", "logic_share", "mirror_share", "path", "reason")
KINDS = frozenset({"class", "struct", "enum", "actor", "protocol", "extension", "func", "var", "let", "typealias",
                   "main"})
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
_CONTINUES_AFTER = re.compile(r"(?:[=,(\[+\-*/%&|.:<]|->|\?\?)[ \t]*$")
_CONTINUES_BEFORE = re.compile(r"[ \t]*(?:\.(?!\.)|&&|\|\||\?\?|\?|:|[+*/%&|{=]|-(?!>)|->|where\b)")
# Codegen output that counts 0 when the table does not list it: a file whose path matches a glob here (`*` stays in
# one folder) AND whose leading comment block names that generator on a line that opens with GENERATED_HEADER. A
# header alone, or a generated-looking name, hides nothing: a new generator (or a new output path) is a reviewed change
# of this list.
GENERATORS = (
    ("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Schema/SettingsSchema+*.generated.swift",
     "scripts/cmux-next/gen-settings-sources.py"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/ProtectedFolderEntry.generated.swift",
     "scripts/cmux-next/gen-protected-folders.py"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Tree/ProtectedFolderEntry.generated.swift",
     "scripts/cmux-next/gen-protected-folders.py"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextOnboarding/System/ProtectedFolderEntry.generated.swift",
     "scripts/cmux-next/gen-protected-folders.py"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextPalette/FolderPicker/ProtectedFolderEntry.generated.swift",
     "scripts/cmux-next/gen-protected-folders.py"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/ChromeStyleActionCatalog.swift",
     "scripts/cmux-next/gen-chrome-styles.py"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextDesignTokens/ChromeStyle.swift",
     "scripts/cmux-next/gen-chrome-styles.py"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/ChromeStyleSetting+Choices.swift",
     "scripts/cmux-next/gen-chrome-styles.py"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/BackdropArt.swift",
     "scripts/cmux-next/art/generate_backdrop_art.py"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/BackdropArt+Entries.swift",
     "scripts/cmux-next/art/generate_backdrop_art.py"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/StatusIndicator/StaticStatusGlyph.generated.swift",
     "scripts/cmux-next/gen-status-glyphs.py"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/TypeScale.generated.swift", "scripts/cmux-next/gen-type-scale.py"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextDesignTokens/Motion/MotionScale.generated.swift",
     "scripts/cmux-next/gen-motion-scale.py"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextIcons/IconName+Catalog.swift", "scripts/icons/build_pack.py"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextIcons/IconName+Members.swift", "scripts/icons/build_pack.py"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy+Fields.generated.swift",
     "scripts/cmux-next/gen-phone-lane-fields.py"),
    ("Packages/Shared/CmuxAgentBrands/Sources/CmuxAgentBrands/AgentBrandCatalog+Generated.swift",
     "scripts/agent-icons/generate.py"),
    ("Packages/Shared/CmuxIrxTransport/Sources/CmuxIrxTransport/ControlPlane/CtlWireModels.swift", "quicktype"),
    ("Packages/Shared/CmuxIrxTransport/Sources/CmuxIrxTransport/ControlPlane/V2WireModels.swift", "quicktype"),
)
# The claim opens the comment line: prose that mentions generated values (`// The defaults are generated from`) is
# none.
GENERATED_HEADER = re.compile(r"(?i)^[ \t]*//[ \t]*(?:@generated\b|(?:this file (?:was|is) )?(?:auto-?)?generated "
                              r"(?:by|from)\b|code generated\b)")
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
# An extension of a shorthand type (`extension [UInt8] {`, `extension [String: Int] {`): TYPE_DECL needs a name.
_SHORTHAND_EXTENSION = re.compile(
    rf"(?:^|(?<=[;}}]))[ \t]*(?:{AC.ATTR}\s+)*(?:{AC.MODS}\s+)*extension[ \t]+(\[[^\]\n{{]*\]|\([^)\n{{]*\))", re.M)
# arch_counts' type and func patterns start at a line start; a declaration also follows a `}` or `;` on its line
# (`}; struct B {`).
_TYPE_DECL = re.compile(r"(?:^|(?<=[;}]))" + AC.TYPE_DECL.pattern[1:], re.M)
_FUNC_DECL = re.compile(r"(?:^|(?<=[;}]))" + AC.FUNC_DECL.pattern[1:], re.M)
# A func signature goes on to a next line that starts with an effect (`throws -> Int` under the parameter list).
_EFFECTS = re.compile(r"[ \t]*(?:async|throws|rethrows|reasync)\b")
# A main.swift line that is no statement: an import (attributes and an access level too) or a compiler directive.
_NO_STATEMENT = re.compile(rf"[ \t]*(?:(?:{AC.ATTR}[ \t]+)*(?:(?:public|package|internal|fileprivate|private)[ \t]+)?"
                           r"import\b|#(?:if|elseif|else|endif|warning|error|sourceLocation)\b)")


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


def _glob(pattern: str) -> re.Pattern[str]:
    """PATTERN with `*` as any run of characters inside one path component (never a `/`)."""
    return re.compile("[^/]*".join(re.escape(part) for part in pattern.split("*")))


def generated(path: str, raw: str) -> bool:
    """Whether the Swift file PATH with text RAW is a reviewed generator's output: PATH matches a GENERATORS glob and a
    line of its leading comment block (the comment and blank lines before its first code line) opens with
    GENERATED_HEADER and names that generator."""
    marks = [mark for glob, mark in GENERATORS if _glob(glob).fullmatch(path)]
    if not marks:
        return False
    for line in raw.split("\n"):
        text = line.strip()
        if not text:
            continue
        if not text.startswith(("//", "/*", "*")):
            return False
        if GENERATED_HEADER.match(line if text.startswith("//") else "// " + text) and any(m in text for m in marks):
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
    for m in _TYPE_DECL.finditer(code):
        if braces.enclosing(m.start()):
            continue
        brace = code.find("{", m.end())
        if brace < 0 or ";" in code[m.end():brace]:
            continue
        kind, name = m.group(1), m.group(2)
        found.append((m.start(), braces.close.get(brace, n - 1) + 1, kind, name,
                      view_shaped(kind, name, code[m.end():brace])))
    for m in _SHORTHAND_EXTENSION.finditer(code):
        if braces.enclosing(m.start()):
            continue
        brace = code.find("{", m.end())
        if brace < 0 or ";" in code[m.end():brace]:
            continue
        name = re.sub(r"\s+", "", m.group(1))
        found.append((m.start(), braces.close.get(brace, n - 1) + 1, "extension", name, False))
    for m in _FUNC_DECL.finditer(code):
        if braces.enclosing(m.start()):
            continue
        # Its statement from the parameter list on: the result, the `where` clause and the body brace (on the line or
        # the next ones: _statement_end), and a next line that starts with an effect; a func with no body
        # (`@_silgen_name`) ends at its signature.
        end = _statement_end(code, AC._closing(code, m.end() - 1) + 1, braces)
        while end < n and code[end] == "\n" and _EFFECTS.match(code, end + 1):
            end = _statement_end(code, end + 1, braces)
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
    covered: set[int] = set()
    counted = 0  # the last line a unit already spans: a line counts once (`let a = 1; let b = 2`: a 1, b 0)
    for start, end, kind, name, view in sorted(found):
        # The patterns start at the line start of the first attribute line (`^[ \t]*`); a match after a `;` or a
        # `{` starts on its own line.
        line = AC._line_of(code, start + (1 if code.startswith("\n", start) else 0), starts)
        last = AC._line_of(code, max(start, end - 1), starts)
        first = max(line, counted + 1)
        out.append(Unit(kind, name, line, max(0, last - first + 1), view, made))
        covered.update(range(line, last + 1))
        counted = max(counted, last)
    if path.rsplit("/", 1)[-1] == "main.swift":
        # Its top-level statements (code outside every declaration, not an import or a directive): one unit.
        # Comments blanked, strings kept: a multi-line string's lines are the statement's lines.
        kept = AC.strip(raw, keep_strings=True).split("\n")
        lines = [i for i, text in enumerate(kept, 1)
                 if i not in covered and text.strip() and not _NO_STATEMENT.match(text)]
        if lines:
            out.append(Unit("main", "main.swift", lines[0], len(lines), False, made))
    return out


_IN_MODULE = re.compile(r"(?:^|/)Sources/([^/]+)/(.+)$")


def in_module(path: str) -> tuple[str, str] | None:
    """(module, PATH relative to its module's folder) (`.../Sources/CmuxNextApp/Windows/W.swift` -> (`CmuxNextApp`,
    `Windows/W.swift`)), or None for a path outside a `Sources/<module>/` folder. Two closure packages never share a
    module folder (arch_counts.AmbiguousModule), so the pair names one file of the count."""
    m = _IN_MODULE.search(path)
    return (m.group(1), m.group(2)) if m else None


def parse_table(text: str | None) -> tuple[dict[tuple[str, str, str, str, int], Entry], int]:
    """({(module, path in the module, kind, name, ordinal in the file): entry}, invalid row count) of the table TEXT
    (docstring, Table)."""
    table: dict[tuple[str, str, str, str, int], Entry] = {}
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
        found = in_module(fields[7]) if len(fields) > 7 else None
        if (CLASSES[cls] is not None and shares != CLASSES[cls]) or sum(shares) > 100 or found is None \
                or found[0] != module:  # a path in another module's folder never matches this module's file
            invalid += 1
            continue
        key = (module, found[1], kind, name, int(ordinal))
        entry = Entry(cls, shares[0], shares[1], fields[7] if len(fields) > 7 else "",
                      fields[8] if len(fields) > 8 else "")
        if key in table:  # a duplicate row: the larger of each share counts, so a duplicate never lowers a row
            invalid += 1
            was = table[key]
            entry = dataclasses.replace(was, logic=max(was.logic, entry.logic), mirror=max(was.mirror, entry.mirror))
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
    generated_lines: int
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
                         "generated_lines": self.generated_lines,
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
    declarations = views = made = made_lines = 0
    for path in sorted(files):
        module = AC.package_of(path)
        where = (in_module(path) or ("", path))[1]
        for u in files[path]:
            ordinal = seen[(path, u.kind, u.name)]
            seen[(path, u.kind, u.name)] += 1
            key = (module, where, u.kind, u.name, ordinal)
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
                made_lines += u.span
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
    return Count(sha, rows, unlisted, declarations, views, made, made_lines, sites, len(table), missing, invalid,
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
    top = ["git", "rev-parse", "--show-toplevel"]
    repo = Path(args.repo).resolve() if args.repo else Path(
        subprocess.run(top, capture_output=True, text=True, check=True).stdout.strip())
    table_text = Path(args.table).read_text() if args.table else None
    found = count(repo, args.rev, cache=not args.no_cache, table_text=table_text)
    if args.sites:
        for path, line, text in found.sites[args.sites]:
            print(f"{path}:{line}: {text}")
        return 0
    if args.missing:
        for (module, _, kind, name, ordinal), entry in found.missing:
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
    print(f"  unlisted           {u['lines']} lines in {u['declarations']} declarations "
          f"({u['view_shaped']} view-shaped, "
          f"{u['generated']} in generated files ({u['generated_lines']} lines))")
    print(f"  table              {data['table_rows']} rows, {data['table_rows_missing']} missing, "
          f"{data['table_rows_invalid']} invalid")
    return 0


if __name__ == "__main__":
    sys.exit(main())

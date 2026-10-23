#!/usr/bin/env python3
"""Architecture counts for cmux-next, method v1: the numbers plans/cmux-next/arch-ratchet.json records.

The rules are the goal (repo CLAUDE.md "Refactor architecture", "Modern Swift concurrency";
plans/cmux-next/perf-lead.md "Architecture targets"); these counts are proxies, and a pattern renamed
to dodge a count is still counted where the method can see it. Every row is counted per package
(the target directory under Sources) and in total.

Scope: tracked Swift under Packages/macOS/CmuxNext/Sources, read from git objects, with comments and
string literals blanked (same length, so offsets and line numbers stay). Package rows come from a
static parse of Packages/macOS/CmuxNext/Package.swift (never `swift package dump-package`: 4-6 s).

Rows (method v1; a change of any definition bumps METHOD_VERSION and rewrites the json):
  layer_hard              target edges from a core, service or domain target to a ui or app target
                          (layers from plans/cmux-next/architecture-layers.json, as arch-layers.py)
  layer_soft              edges from a service target to a domain target
  layer_upward            every other edge that points up a layer: core -> service, core -> domain
                          (edges only point down, DESIGN section 2)
  layer_unplaced          regular, executable and binary targets that architecture-layers.json does not
                          place (no entry, an entry without a string `layer`, a layer not in `order`, or a
                          map that does not parse). One static reader (`parse_manifest`) and one map reader
                          (`LayerMap`) serve these rows, arch-layers.py and the pre-push layer gate
  stateful_singletons     a stored type-scope `static let/var` whose type is stateful, whatever its
                          name. The type comes from the annotation, else from `T(`, `T<..>(`, `T.init(`,
                          `Self(`, `.init(`, `T.factory(` (the enclosing type for Self/.init), `T {`,
                          or a member read of a stateful system type (`FileManager.default`). Stateful:
                          an actor; a repo class with a stored instance `var` or a lock/cache field; a
                          repo struct/enum with a lock/cache field; UserDefaults, URLSession,
                          NotificationCenter, OperationQueue, NSWindow, NSPanel, NSWorkspace,
                          FileManager, WKProcessPool, WKWebsiteDataStore (and
                          DistributedNotificationCenter); and, one link away (TypeTable.DEPTH), a repo
                          class whose superclass or stored instance `let` has such a type. A name
                          declared more than once (two modules) is stateful when any declaration is.
                          Not counted: @TaskLocal statics, association keys, and the composition root
                          (CmuxNextApp's AppDelegate*.swift, CmuxNextApp.swift, AppServices*.swift).
  global_mutable_statics  any other stored `static var`, or a static lock/cache/atomic container
                          (Mutex, OSAllocatedUnfairLock, NSLock, NSRecursiveLock, NSCondition(Lock),
                          NSCache, NSHashTable, NSMapTable, Atomic, ManagedAtomic, NSMutable*); same
                          skips as above
  assume_isolated_outside_adapters
                          every `MainActor.assumeIsolated` except an adapter site: not inside a
                          `deinit` and not inside a raw NotificationCenter `addObserver(... queue: .main)`
                          block, a `main-proof:` comment on its line, in the 2 lines above or in the
                          comment block above, and a file of at most 150 code lines and at most 2 type
                          declarations (class/actor/struct/enum/protocol)
  assume_isolated_total   every `MainActor.assumeIsolated` (report only)
  app_broadcast_names     custom Notification.Name declarations: `Notification.Name(`,
                          `Notification.Name.init(`, `Name(rawValue:`, `.init(`/`Self(` inside an
                          `extension Notification.Name`, `: Notification.Name = .init(`,
                          `post(name: .init(`; not counted: a literal that starts with `com.apple.`
  observer_sites          `addObserver(`, `.notifications(named:`, `.publisher(for:`,
                          `MainActorObservation(` (not a `func addObserver(` declaration)
  app_lines               physical lines (newlines) of CmuxNextApp Swift (report only here)

Delta mode (the pre-push hook) reads only the files a range changes, at both ends, and gives the same
numbers as two full counts subtracted (tests/test_arch_ratchet.py checks it). Statics the range leaves
in place, or moves within a package, cancel without a type lookup; for the rest, and for types whose
declarations the range changes, one worktree `git grep` per link depth finds the declarations (the
worktree stands in for both ends for every file that equals them; changed and dirty files are read
from git objects). A type whose statefulness the range flips (a class gains a stored var) re-counts the
unchanged files whose statics name it. Most pushes need no grep: about 4 git processes in all.

Usage:
  scripts/cmux-next/arch_counts.py [--rev REV] [--json]     full count at REV (default HEAD)
  scripts/cmux-next/arch_counts.py --write [--rev REV]      write plans/cmux-next/arch-ratchet.json
  scripts/cmux-next/arch_counts.py --delta BASE HEAD [--json]
"""

from __future__ import annotations

import argparse
import bisect
import collections
import concurrent.futures
import dataclasses
import datetime
import json
import re
import subprocess
import sys
from pathlib import Path

METHOD_VERSION = 1
SOURCES = "Packages/macOS/CmuxNext/Sources"
MANIFEST = "Packages/macOS/CmuxNext/Package.swift"
LAYERS_JSON = "plans/cmux-next/architecture-layers.json"
RATCHET_JSON = "plans/cmux-next/arch-ratchet.json"
APP_PACKAGE = "CmuxNextApp"
SHA = re.compile(r"[0-9a-f]{40}")


@dataclasses.dataclass(frozen=True)
class Row:
    """One counted row: its id (the json key and the skip name), what it counts and whether it ratchets."""

    id: str
    title: str
    ratchet: bool  # False: printed, never refused by the built-in count rule


ROWS = (
    Row("layer_hard", "hard layer edges (core/service/domain -> ui/app)", True),
    Row("layer_soft", "soft layer edges (service -> domain)", True),
    Row("layer_upward", "other upward layer edges (core -> service/domain)", True),
    Row("layer_unplaced", "targets missing from architecture-layers.json", True),
    Row("stateful_singletons", "stateful singletons (stored static of a stateful type)", True),
    Row("global_mutable_statics", "global mutable statics (static var, static lock/cache)", True),
    Row("assume_isolated_outside_adapters", "MainActor.assumeIsolated outside seam adapters", True),
    Row("assume_isolated_total", "MainActor.assumeIsolated, all sites", False),
    Row("app_broadcast_names", "app-internal Notification.Name broadcasts", True),
    Row("observer_sites", "NotificationCenter/KVO observer sites", True),
    Row("app_lines", "CmuxNextApp Swift lines", False),
)
ROW_IDS = tuple(row.id for row in ROWS)
LAYER_ROWS = ("layer_hard", "layer_soft", "layer_upward", "layer_unplaced")

SYS_STATEFUL = frozenset({
    "UserDefaults", "URLSession", "NotificationCenter", "OperationQueue", "NSWindow", "NSPanel",
    "NSWorkspace", "FileManager", "WKProcessPool", "WKWebsiteDataStore", "DistributedNotificationCenter",
})
CONTAINERS = frozenset({
    "Mutex", "OSAllocatedUnfairLock", "NSLock", "NSRecursiveLock", "NSCondition", "NSConditionLock",
    "NSCache", "NSHashTable", "NSMapTable", "Atomic", "ManagedAtomic", "NSMutableDictionary",
    "NSMutableArray", "NSMutableSet", "NSMutableOrderedSet",
})
# Names that are never a repo type: system classes and value types a static commonly holds.
SYSTEM_PREFIX = re.compile(r"^(?:NS|WK|CA|CG|CF|AV|UI|MTL|MTK|SC|UN|AS|QL|SK|OS|CL|IO|VN|SF|CI|CT|CV|CM)[A-Z]")
VALUE_NAMES = frozenset({
    "String", "Int", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Double", "Float",
    "CGFloat", "Bool", "Character", "Array", "Dictionary", "Set", "Optional", "URL", "Data", "Date", "UUID",
    "Duration", "TimeInterval", "Color", "Font", "Image", "Logger", "Self", "Void", "Any", "AnyObject",
})

COMPOSITION_ROOT = re.compile(r"^Packages/macOS/CmuxNext/Sources/CmuxNextApp/(?:.*/)?"
                              r"(?:AppDelegate[^/]*|CmuxNextApp|AppServices[^/]*)\.swift$")

# ---------------------------------------------------------------------------------------------------
# Comment and string blanking


_TOKEN = re.compile(r'//|/\*|(#*)("""|")')
_BLOCK = re.compile(r"/\*|\*/")
_NOT_NL = re.compile(r"[^\n]")
_STRING_END: dict[tuple[str, str], re.Pattern[str]] = {}
_INTERP = re.compile(r'[()]|//|/\*|(#*)("""|")')


def _blank(text: str) -> str:
    return _NOT_NL.sub(" ", text)


def _string_end_pattern(hashes: str, quote: str) -> re.Pattern[str]:
    key = (hashes, quote)
    pattern = _STRING_END.get(key)
    if pattern is None:
        escape = re.escape("\\" + hashes)
        closing = re.escape(quote + hashes)
        tail = "" if quote == '"""' else r"|\n"
        pattern = re.compile(rf"(?P<interp>{escape}\()|(?P<esc>{escape}.)|(?P<close>{closing}){tail}", re.S)
        _STRING_END[key] = pattern
    return pattern


def _end_of_block_comment(text: str, start: int) -> int:
    depth = 0
    for m in _BLOCK.finditer(text, start):
        depth += 1 if m.group(0) == "/*" else -1
        if depth == 0:
            return m.end()
    return len(text)


def _end_of_interpolation(text: str, start: int) -> int:
    """Index after the `)` that closes an interpolation whose `(` ends just before START."""
    depth = 1
    i = start
    while True:
        m = _INTERP.search(text, i)
        if not m:
            return len(text)
        tok = m.group(0)
        if tok == "(":
            depth += 1
            i = m.end()
        elif tok == ")":
            depth -= 1
            i = m.end()
            if depth == 0:
                return i
        elif tok == "//":
            j = text.find("\n", m.start())
            i = len(text) if j < 0 else j
        elif tok == "/*":
            i = _end_of_block_comment(text, m.start())
        else:
            i = _end_of_string(text, m.end(), m.group(1), m.group(2))


def _end_of_string(text: str, start: int, hashes: str, quote: str) -> int:
    """Index after the closing delimiter of a literal whose opening delimiter ends at START."""
    pattern = _string_end_pattern(hashes, quote)
    i = start
    while True:
        m = pattern.search(text, i)
        if not m:
            return len(text)
        if m.group("interp"):
            i = _end_of_interpolation(text, m.end())
        elif m.group("esc"):
            i = m.end()
        elif m.group("close"):
            return m.end()
        else:  # a newline ends an unterminated single-line literal
            return m.start()


def strip(text: str, keep_strings: bool = False) -> str:
    """TEXT with comments (and, unless KEEP_STRINGS, string contents) blanked to spaces, same length.

    A blanked literal keeps its delimiters, so the next `"` after an opening one closes it.
    """
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        m = _TOKEN.search(text, i)
        if not m:
            out.append(text[i:])
            break
        s = m.start()
        out.append(text[i:s])
        tok = m.group(0)
        if tok == "//":
            j = text.find("\n", s)
            j = n if j < 0 else j
            out.append(" " * (j - s))
            i = j
        elif tok == "/*":
            j = _end_of_block_comment(text, s)
            out.append(_blank(text[s:j]))
            i = j
        else:
            hashes, quote = m.group(1), m.group(2)
            j = _end_of_string(text, m.end(), hashes, quote)
            if keep_strings:
                out.append(text[s:j])
            else:
                open_len = len(hashes) + len(quote)
                body_end = j
                closing = quote + hashes
                if text.startswith(closing, j - len(closing)) and j - len(closing) >= s + open_len:
                    body_end = j - len(closing)
                out.append(text[s:s + open_len] + _blank(text[s + open_len:body_end]) + text[body_end:j])
            i = j
    return "".join(out)


# ---------------------------------------------------------------------------------------------------
# Brace structure


class Braces:
    """The `{` `}` pairs of blanked code: each open's close and parent, and the scopes around an offset."""

    def __init__(self, code: str) -> None:
        self.code = code
        self.opens: list[int] = []
        self.close: dict[int, int] = {}
        self.parent: dict[int, int] = {}
        self.all: list[int] = []
        stack: list[int] = []
        for m in re.finditer(r"[{}]", code):
            p = m.start()
            self.all.append(p)
            if code[p] == "{":
                self.parent[p] = stack[-1] if stack else -1
                stack.append(p)
                self.opens.append(p)
            elif stack:
                self.close[stack.pop()] = p
        for p in stack:  # unbalanced (#if branches): open to the end
            self.close[p] = len(code)

    def enclosing(self, pos: int) -> list[int]:
        """Opens around POS, innermost first."""
        i = bisect.bisect_left(self.opens, pos) - 1
        if i < 0:
            return []
        p = self.opens[i]
        while p >= 0 and self.close.get(p, len(self.code)) < pos:
            p = self.parent.get(p, -1)
        out = []
        while p >= 0:
            out.append(p)
            p = self.parent.get(p, -1)
        return out

    def head(self, open_pos: int, limit: int = 600) -> str:
        """The code between the previous brace and OPEN_POS (the opener's statement head)."""
        i = bisect.bisect_left(self.all, open_pos) - 1
        start = self.all[i] + 1 if i >= 0 else 0
        return self.code[max(start, open_pos - limit):open_pos]

    def children(self, open_pos: int) -> list[int]:
        close = self.close.get(open_pos, len(self.code))
        i = bisect.bisect_right(self.opens, open_pos)
        out = []
        while i < len(self.opens) and self.opens[i] < close:
            child = self.opens[i]
            out.append(child)
            child_close = self.close.get(child, len(self.code))
            i = bisect.bisect_right(self.opens, child_close)
        return out


# ---------------------------------------------------------------------------------------------------
# Per-file facts

MODS = r"(?:public|package|internal|private|fileprivate|open|final|nonisolated|indirect|dynamic|optional)(?:\([\w ]+\))?"
ATTR = r"@[A-Za-z_][\w.]*(?:\((?:[^()\n]|\([^()\n]*\))*\))?"
TYPE_DECL = re.compile(
    rf"^[ \t]*(?:{ATTR}\s+)*(?:{MODS}\s+)*(class|actor|struct|enum|protocol|extension)[ \t]+"
    r"(?!(?:func|var|let|subscript|override|final|static|private|fileprivate|public|internal|package|open|"
    r"nonisolated|required|convenience|init|deinit)\b)([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)",
    re.M,
)
STATIC = re.compile(
    rf"^[ \t]*(?:{ATTR}\s+)*((?:(?:{MODS}|static|class|lazy|override)\s+)*)(let|var)\s+(`?[A-Za-z_]\w*`?)"
    r"[ \t]*(?::[ \t]*([^=\n{]+?))?[ \t]*(=[ \t]*(.*?))?[ \t]*$",
    re.M,
)
VAR_MEMBER = re.compile(
    rf"(?:^|[\n;])[ \t]*(?:{ATTR}\s+)*((?:(?:{MODS}|weak|unowned|lazy|override|static|class|required|"
    r"nonmutating|mutating)\s+)*)var\s+(?:`?[A-Za-z_]\w*`?)([^\n;]*)"
)
LOCK_NAMES = "|".join(sorted(CONTAINERS))
LOCK_MEMBER = re.compile(
    rf"(?:^|[\n;])[ \t]*(?:{ATTR}\s+)*((?:(?:{MODS}|static|class)\s+)*)let\s+\w+\s*"
    rf"(?::\s*(?:{LOCK_NAMES})\b|(?::[^=\n]*)?=\s*(?:{LOCK_NAMES})\b)"
)
ASSUME = re.compile(r"\bMainActor\s*\.\s*assumeIsolated\b")
OBSERVER = re.compile(r"\baddObserver\s*\(|\.notifications\s*\(\s*named\s*:|\.publisher\s*\(\s*for\s*:|"
                      r"\bMainActorObservation\s*\(")
BROADCAST = re.compile(
    r"\b(?:NS)?Notification\s*\.\s*Name\s*(?:\.\s*init\s*)?(\()|\bName\s*(\()\s*rawValue\s*:|"
    r":\s*(?:NS)?Notification\s*\.\s*Name\s*=\s*\.init\s*(\()|\bpost\s*\(\s*name\s*:\s*\.init\s*(\()"
)
EXT_NAME = re.compile(r"\bextension\s+(?:NS)?Notification\s*\.\s*Name\b")
INIT_CALL = re.compile(r"(?<![\w.])(?:\.init|Self(?:\s*\.\s*init)?)\s*(\()")
NC_MAIN = re.compile(r"addObserver\s*\([^{}]*\bqueue\s*:\s*(?:\.main|OperationQueue\s*\.\s*main)\b[^{}]*$")
DEINIT = re.compile(r"\bdeinit\s*$")
ASSOC = re.compile(r"(?i)associat\w*key|assockey")
SUPERCLASS = re.compile(r"^\s*(?:<[^{}]*?>)?\s*:\s*(?:@\w+\s+)?([A-Za-z_][\w.]*)")


@dataclasses.dataclass
class Decl:
    """A class/actor/struct/enum declaration and what makes it stateful on its own."""

    name: str
    kind: str
    own_state: bool
    superclass: str | None
    held: tuple[str, ...] = ()  # types of its stored instance `let`s (a held stateful object is state)


@dataclasses.dataclass
class Static:
    """A stored type-scope static, before its type is resolved."""

    line: int
    text: str
    keyword: str
    type_name: str | None
    container: bool


@dataclasses.dataclass
class Site:
    """A counted finding: the row, file, 1-based line and the source line's text."""

    row: str
    path: str
    line: int
    text: str


@dataclasses.dataclass
class FileFacts:
    """Everything the rows need from one file that does not depend on other files."""

    path: str
    package: str
    decls: list[Decl]
    statics: list[Static]
    sites: list[Site]  # rows other than the static rows
    lines: int


def package_of(path: str) -> str:
    rest = path[len(SOURCES) + 1:] if path.startswith(SOURCES + "/") else path
    return rest.split("/", 1)[0] if "/" in rest else "(top)"


def _line_of(code: str, pos: int, starts: list[int]) -> int:
    return bisect.bisect_right(starts, pos)


def _type_name(text: str) -> str | None:
    m = re.match(r"\s*(?:any\s+|some\s+)?([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\s*(?:<.*>)?\s*[?!]?\s*$", text)
    if not m:
        return None
    return m.group(1).split(".")[-1]


def _skip_generic(expr: str, i: int) -> int:
    """Index after the `<...>` that starts at I (nested; `->` is not a bracket), or I when none."""
    if i >= len(expr) or expr[i] != "<":
        return i
    depth = 0
    j = i
    while j < len(expr):
        ch = expr[j]
        if ch == "<":
            depth += 1
        elif ch == ">" and expr[j - 1] != "-":
            depth -= 1
            if depth == 0:
                return j + 1
        elif ch in "=;{}\n":
            return i
        j += 1
    return i


def _init_type(expr: str, owner: str | None) -> str | None:
    """The constructed type of a static's initializer expression, or None.

    `T(`, `T<..>(`, `T.init(`, `T {`, `T.factory(` (one member after the type), `Self(`/`.init(` (the
    enclosing type), and `Sys.member` for a stateful system type (`FileManager.default`).
    """
    expr = expr.strip()
    if not expr:
        return None
    if re.match(r"\.init\s*\(|Self\s*[.(]", expr):
        return owner
    parts: list[str] = []
    i = 0
    while True:
        m = re.compile(r"\s*([A-Za-z_]\w*)").match(expr, i)
        if not m:
            return None
        parts.append(m.group(1))
        i = _skip_generic(expr, m.end())
        dot = re.compile(r"\s*\.\s*").match(expr, i)
        if not dot:
            break
        i = dot.end()
    rest = expr[i:].lstrip()
    upper = [k for k, p in enumerate(parts) if p[:1].isupper()]
    if not upper:
        return None
    k = upper[-1]
    after = [p for p in parts[k + 1:] if p != "init"]
    if rest[:1] in ("(", "{"):
        return parts[k] if len(after) <= 1 else None
    if not rest and len(after) == 1 and parts[k] in SYS_STATEFUL:
        return parts[k]
    return None


def _is_proved(raw_lines: list[str], i: int) -> bool:
    if "main-proof:" in raw_lines[i]:
        return True
    if any("main-proof:" in raw_lines[j] for j in range(max(0, i - 2), i)):
        return True
    j = i - 1
    while j >= 0 and re.match(r"^\s*(?://|\*|/\*|@\w)", raw_lines[j]):
        if "main-proof:" in raw_lines[j]:
            return True
        j -= 1
    return False


def _decls(code: str, braces: Braces) -> tuple[list[Decl], dict[int, tuple[str, str]], int]:
    """Type declarations, a map body-open -> (kind, name) for owners, and the type count of the file."""
    decls: list[Decl] = []
    owners: dict[int, tuple[str, str]] = {}
    count = 0
    for m in TYPE_DECL.finditer(code):
        kind, name = m.group(1), m.group(2)
        if kind != "extension":
            count += 1
        brace = code.find("{", m.end())
        if brace < 0 or brace not in braces.close:
            continue
        between = code[m.end():brace]
        if ";" in between:
            continue
        owners[brace] = (kind, name.split(".")[-1])
        if kind in ("protocol", "extension"):
            continue
        superclass = None
        if kind == "class":
            sm = SUPERCLASS.match(between)
            if sm:
                superclass = sm.group(1).split(".")[-1]
        own, held = _own_state(code, braces, brace, kind, name.split(".")[-1])
        decls.append(Decl(name.split(".")[-1], kind, kind == "actor" or own, superclass, held))
    return decls, owners, count


HELD_LET = re.compile(
    rf"(?:^|[\n;])[ \t]*(?:{ATTR}\s+)*((?:(?:{MODS}|static|class|weak|unowned(?:\([\w ]+\))?)\s+)*)let\s+"
    r"(?:`?[A-Za-z_]\w*`?)[ \t]*(?::[ \t]*([^=\n]+?))?[ \t]*(?:=[ \t]*([^\n]*))?$",
    re.M,
)


def _own_state(code: str, braces: Braces, open_pos: int, kind: str, owner: str) -> tuple[bool, tuple[str, ...]]:
    """(a stored var or lock field of its own, the types of its stored `let`s) of the body at OPEN_POS."""
    close = braces.close.get(open_pos, len(code))
    start = open_pos + 1
    segments: list[tuple[int, int, int | None]] = []  # (start, end, child open that follows)
    for child in braces.children(open_pos):
        segments.append((start, child, child))
        start = braces.close.get(child, len(code)) + 1
    segments.append((start, close, None))
    held: list[str] = []
    own = False
    for s, e, child in segments:
        text = code[s:e]
        for m in LOCK_MEMBER.finditer(text):
            if not re.search(r"\b(?:static|class)\b", m.group(1)):
                return True, ()
        if kind != "class":
            continue
        for m in HELD_LET.finditer(text):
            if re.search(r"\b(?:static|class|weak|unowned)\b", m.group(1)):
                continue
            t = _type_name(m.group(2)) if m.group(2) else _init_type(m.group(3) or "", owner)
            if t and t != owner and (t in SYS_STATEFUL or repo_type_name(t)):
                held.append(t)
        for m in VAR_MEMBER.finditer(text):
            if re.search(r"\b(?:static|class)\b", m.group(1)):
                continue
            rest = m.group(2)
            followed_by_block = child is not None and "\n" not in text[m.end():]
            if "=" in rest or not followed_by_block:
                own = True
                continue
            block = code[child + 1:braces.close.get(child, len(code))]
            if re.search(r"\b(?:didSet|willSet)\b", block):
                own = True
    return own, (() if own else tuple(dict.fromkeys(held)))


def analyze(path: str, raw: str) -> FileFacts:
    """The per-file facts of PATH with content RAW."""
    code = strip(raw)
    braces = Braces(code)
    starts = [0] + [m.end() for m in re.finditer(r"\n", code)]
    raw_lines = raw.split("\n")
    code_lines = code.split("\n")
    decls, owners, type_count = _decls(code, braces)
    sites: list[Site] = []

    def site(row: str, pos: int) -> None:
        line = _line_of(code, pos, starts)
        sites.append(Site(row, path, line, raw_lines[line - 1].strip() if line - 1 < len(raw_lines) else ""))

    statics: list[Static] = []
    assoc_names = set(re.findall(r"objc_(?:get|set)AssociatedObject\s*\([^,]*,\s*&\s*(?:Self\s*\.\s*|\w+\s*\.\s*)?(\w+)", code))
    for m in STATIC.finditer(code):
        mods, keyword, name, ann, assign, expr = m.groups()
        if not re.search(r"\bstatic\b", mods or ""):
            continue
        line = _line_of(code, m.start(2), starts)  # the `let`/`var` line, not an attribute line above it
        if assign is None:
            # `static var x: T?` is stored (nil); without `=` anything else is computed or a requirement.
            nxt = code_lines[line].strip() if line < len(code_lines) else ""
            if keyword != "var" or not ann or nxt.startswith("{"):
                continue
        raw_line = raw_lines[line - 1] if line - 1 < len(raw_lines) else ""
        head_attrs = raw_line + (raw_lines[line - 2] if line >= 2 else "")
        if "@TaskLocal" in head_attrs:
            continue
        bare = name.strip("`")
        if ASSOC.search(bare) or bare in assoc_names:
            continue
        scopes = braces.enclosing(m.start())
        if not scopes or scopes[0] not in owners:
            continue
        kind, owner = owners[scopes[0]]
        if kind == "protocol":
            continue
        expr = (expr or "").strip()
        if not expr:  # `static let x =` with the value on the next line
            nxt = code_lines[line] if line < len(code_lines) else ""
            expr = nxt.strip()
        tname = _type_name(ann) if ann else None
        if tname is None:
            tname = _init_type(expr, owner)
        statics.append(Static(line, raw_line.strip(), keyword, tname, tname in CONTAINERS))

    small = sum(1 for line in code_lines if line.strip()) <= 150 and type_count <= 2
    for m in ASSUME.finditer(code):
        site("assume_isolated_total", m.start())
        scopes = braces.enclosing(m.start())
        heads = [braces.head(p) for p in scopes]
        in_deinit = any(DEINIT.search(h) for h in heads)
        in_nc_main = any(NC_MAIN.search(h) for h in heads)
        line = _line_of(code, m.start(), starts)
        adapter = small and not in_deinit and not in_nc_main and _is_proved(raw_lines, line - 1)
        if not adapter:
            site("assume_isolated_outside_adapters", m.start())

    for m in OBSERVER.finditer(code):
        if re.search(r"\bfunc\s+$", code[max(0, m.start() - 40):m.start()]):
            continue
        site("observer_sites", m.start())

    parens: set[int] = set()
    for m in BROADCAST.finditer(code):
        parens.add(next(m.start(g) for g in range(1, 5) if m.group(g)))
    for m in INIT_CALL.finditer(code):
        scopes = braces.enclosing(m.start())
        if any(EXT_NAME.search(braces.head(p)) for p in scopes[:3]):
            parens.add(m.start(1))
    for p in sorted(parens):
        q = code.find('"', p)
        close = code.find(")", p)
        literal = ""
        if q >= 0 and (close < 0 or q < close):
            end = code.find('"', q + 1)
            literal = raw[q + 1:end] if end > q else ""
        if literal.startswith("com.apple."):
            continue
        site("app_broadcast_names", p)

    lines = raw.count("\n")
    return FileFacts(path, package_of(path), decls, statics, sites, lines)


# ---------------------------------------------------------------------------------------------------
# Type table


class TypeTable:
    """stateful(name) over every declaration of NAME at one revision.

    A name is stateful when one of its declarations is on its own (an actor, a class with a stored var
    or a lock/cache field, a struct/enum with a lock/cache field), or, at most DEPTH links away, through
    its superclass or the type of a stored `let`. The bound keeps the answer independent of query order
    and lets the delta count stop after DEPTH + 1 lookup rounds. DECLS(name) returns the declarations of
    a name: the full count passes an index of every file, the delta count TypeLookup.
    """

    DEPTH = 1

    def __init__(self, decls_for) -> None:
        self._decls_for = decls_for
        self._memo: dict[tuple[str, int], bool] = {}

    def stateful(self, name: str | None) -> bool:
        return bool(name) and self._resolve(name, self.DEPTH)

    def stateful_at(self, name: str, depth: int) -> bool:
        """stateful(), at most DEPTH links deep (0: the declarations' own state only)."""
        return self._resolve(name, depth)

    def _resolve(self, name: str, depth: int) -> bool:
        if name in SYS_STATEFUL:
            return True
        if not repo_type_name(name):
            return False
        key = (name, depth)
        if key in self._memo:
            return self._memo[key]
        self._memo[key] = False
        result = False
        for decl in self._decls_for(name):
            if decl.own_state:
                result = True
                break
            if depth > 0 and any(self._resolve(t, depth - 1) for t in ((decl.superclass,) if decl.superclass else ()) + decl.held):
                result = True
                break
        self._memo[key] = result
        return result


def repo_type_name(name: str | None) -> bool:
    """True when NAME could be a repo type (worth a lookup)."""
    return bool(name) and name[:1].isupper() and name not in SYS_STATEFUL and name not in VALUE_NAMES \
        and name not in CONTAINERS and not SYSTEM_PREFIX.match(name)


def classify(static: Static, path: str, table: TypeTable) -> str | None:
    """The row a static counts in, or None."""
    if COMPOSITION_ROOT.match(path):
        return None
    if static.container:
        return "global_mutable_statics"
    if table.stateful(static.type_name):
        return "stateful_singletons"
    if static.keyword == "var":
        return "global_mutable_statics"
    return None


# ---------------------------------------------------------------------------------------------------
# Package.swift and layers
#
# The one static reader of Packages/macOS/CmuxNext/Package.swift and the one reader of
# plans/cmux-next/architecture-layers.json: the layer rows here, arch-layers.py's classification and the
# pre-push layer gate (arch_rules/layer_gate.py) all use them, so they never disagree about which edges
# exist or what class an edge has.

PACKAGE_DIR = "Packages/macOS/CmuxNext"
# Target kinds the layer map must place. Test targets are ignored; plugins, macros and system libraries hold no
# app code.
MAPPED_KINDS = ("target", "executableTarget", "binaryTarget")
TARGET_KINDS = MAPPED_KINDS + ("testTarget", "systemLibrary", "plugin", "macro")
UPPER_LAYERS = ("ui", "app")
EDGE_CLASSES = ("hard", "soft", "upward")
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_CONSTRUCTOR = re.compile(r"(?:\bTarget|(?<![\w)\]\"]))\.(" + "|".join(TARGET_KINDS) + r")\s*\(")
_ELEMENT_CONSTRUCTOR = re.compile(r"^(?:Target)?\.(?:" + "|".join(TARGET_KINDS) + r")\s*\(")
_TOP_LET = re.compile(r"^(let|var)\s+(\w+)\s*(?::\s*([^=\n]+?))?\s*=", re.M)
_PACKAGE_CALL = re.compile(r"\bPackage\s*\(")
# A read or a change of the built manifest: `package.` or a `.targets`/`.dependencies` member (the labels
# `targets:`/`dependencies:` have no dot). Matched with strings and comments blanked.
_AFTER_BUILD = re.compile(r"\bpackage\s*\.|\.\s*(?:targets|dependencies)\b(?!\s*:)")
_STRING = re.compile(r'^"((?:[^"\\]|\\.)*)"$')
_IDENT = re.compile(r"^\w+$")


def _skip_string(text: str, i: int) -> int:
    """Index after the string literal that starts at TEXT[i] (a `"`)."""
    if text.startswith('"""', i):
        end = text.find('"""', i + 3)
        return len(text) if end < 0 else end + 3
    j = i + 1
    while j < len(text) and text[j] != '"':
        j += 2 if text[j] == "\\" else 1
    return j + 1


def _closing(text: str, start: int) -> int:
    """Index of the bracket that closes the one at TEXT[start] (strings skipped), or len(TEXT)."""
    depth, i = 0, start
    while i < len(text):
        c = text[i]
        if c == '"':
            i = _skip_string(text, i)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(text)


def _split_top(text: str, sep: str) -> list[str]:
    """TEXT split at SEP outside brackets and strings, each part stripped, empty parts dropped."""
    parts, depth, i, last = [], 0, 0, 0
    while i < len(text):
        c = text[i]
        if c == '"':
            i = _skip_string(text, i)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == sep and depth == 0:
            parts.append(text[last:i])
            last = i + 1
        i += 1
    parts.append(text[last:])
    return [p.strip() for p in parts if p.strip()]


def _labeled(args: str) -> dict[str, str]:
    """The labeled arguments of a call (`name: "X"` -> {"name": '"X"'})."""
    out = {}
    for part in _split_top(args, ","):
        m = re.match(r"^(\w+)\s*:(?!:)\s*(.*)$", part, re.S)
        if m and m.group(1) not in out:
            out[m.group(1)] = m.group(2).strip()
    return out


def _string_value(expr: str) -> str | None:
    m = _STRING.match(expr.strip())
    return m.group(1) if m else None


def _statement_end(text: str, start: int) -> int:
    """End of the top-level `let` initializer that starts at START: the first newline outside brackets
    after some content whose next line does not continue the expression."""
    depth, i, seen = 0, start, False
    while i < len(text):
        c = text[i]
        if c == '"':
            i = _skip_string(text, i)
            seen = True
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "\n" and depth == 0 and seen:
            rest = text[i + 1:].lstrip()
            if not rest[:1] in ("+", ".", "?", ":", "]", ")"):
                return i
        if not c.isspace():
            seen = True
        i += 1
    return len(text)


def _normalized(expr: str) -> str:
    return " ".join(expr.split())


@dataclasses.dataclass
class ManifestTarget:
    """One target constructor of Package.swift."""

    kind: str
    line: int = 1  # 1-based line of the constructor call
    deps: set[str] = dataclasses.field(default_factory=set)
    # Dependency expressions the static reader cannot resolve (a ternary, a `var` or untyped variable).
    unresolved: set[str] = dataclasses.field(default_factory=set)
    path: str | None = None  # the `path:` argument (relative to the package), when it is a string literal


@dataclasses.dataclass
class Manifest:
    """The targets of a Package.swift, read statically (`parse_manifest`)."""

    targets: dict[str, ManifestTarget]
    # Constructs outside any dependency list that the static reader cannot account for:
    # {normalized text: (1-based line, why)}.
    unreadable: dict[str, tuple[int, str]] = dataclasses.field(default_factory=dict)

    def edges(self) -> set[tuple[str, str]]:
        """(source, dependency) for every dependency name of a target that is not a test target."""
        return {(name, dep) for name, t in self.targets.items() if t.kind != "testTarget" for dep in t.deps}

    def source_dir(self, name: str) -> str:
        """The repo path of NAME's sources: its `path:` or Sources/<name>, without a trailing slash."""
        target = self.targets.get(name)
        relative = target.path if target is not None and target.path else f"Sources/{name}"
        return f"{PACKAGE_DIR}/{relative.strip('/')}"


def parse_manifest(raw: str) -> Manifest:
    """The targets of a Package.swift and their in-package dependency names, read without swift.

    Targets come from every `.target(`/`.executableTarget(`/... call that is not inside another one
    (a dependency's `.target(name:)` is), including calls bound to top-level variables
    (`let appFFI: Target = .binaryTarget(...)`). A `dependencies:` value is array literals and
    top-level `let` `[Target.Dependency]` variables joined by `+`; string literals, `.target(name:)` and
    `.byName(name:)` name targets, `.product(...)` entries name other packages and are skipped. A `var`
    dependency variable is not read (a later statement can append to it), so a dependency list that
    names one is unresolved.

    Everything else that could add a target or an edge is recorded in `unreadable`: a constructor
    whose `name:` is not a string literal (a helper `func`), a `Package(targets:)` entry that is not a
    constructor or a top-level `let X: Target`, and any line that reads or changes the built manifest
    (`package.`, `.targets`, `.dependencies`).
    """
    code = strip(raw, keep_strings=True)
    bare = strip(raw)
    dep_vars: dict[str, str] = {}
    target_vars: set[str] = set()
    skip: list[tuple[int, int]] = []
    for m in _TOP_LET.finditer(code):
        annotation = (m.group(3) or "").strip()
        if "Dependency" in annotation:
            end = _statement_end(code, m.end())
            if m.group(1) == "let":
                dep_vars[m.group(2)] = code[m.end():end]
            skip.append((m.start(), end))
        elif annotation == "Target" and m.group(1) == "let":
            target_vars.add(m.group(2))

    lines = code.splitlines()

    def line_of(index: int) -> int:
        return code.count("\n", 0, index) + 1

    unreadable: dict[str, tuple[int, str]] = {}
    after_build_lines: set[int] = set()
    for m in _AFTER_BUILD.finditer(bare):
        line = line_of(m.start())
        if line in after_build_lines:
            continue
        after_build_lines.add(line)
        unreadable.setdefault(_normalized(lines[line - 1]), (line, "it reads or changes the manifest after it is built"))

    def dependency_names(expr: str, target: ManifestTarget, seen: frozenset[str] = frozenset()) -> None:
        for part in _split_top(expr, "+"):
            if part.startswith("[") and part.endswith("]"):
                for element in _split_top(part[1:-1], ","):
                    name = _string_value(element)
                    call = re.match(r"^\.(target|byName)\s*\((.*)\)$", element, re.S)
                    if name is not None:
                        target.deps.add(name)
                    elif call and _string_value(_labeled(call.group(2)).get("name", "")) is not None:
                        target.deps.add(_string_value(_labeled(call.group(2))["name"]))
                    elif not re.match(r"^\.product\s*\(", element):
                        target.unresolved.add(_normalized(element))
            elif _IDENT.match(part) and part in dep_vars and part not in seen:
                dependency_names(dep_vars[part], target, seen | {part})
            else:
                target.unresolved.add(_normalized(part))

    targets: dict[str, ManifestTarget] = {}
    pos = 0
    while True:
        m = _CONSTRUCTOR.search(code, pos)
        if not m:
            break
        if any(a <= m.start() < b for a, b in skip):
            pos = m.end()
            continue
        open_index = m.end() - 1
        close = _closing(code, open_index)
        line = line_of(m.start())
        if line in after_build_lines:
            pos = close + 1  # already unreadable as a whole line (`....dependencies.append(.target(name: "X"))`)
            continue
        args = _labeled(code[open_index + 1:close])
        name = _string_value(args.get("name", ""))
        if name is not None and name not in targets:
            target = ManifestTarget(kind=m.group(1), line=line, path=_string_value(args.get("path", "")))
            if "dependencies" in args:
                dependency_names(args["dependencies"], target)
            targets[name] = target
        elif m.group(1) != "testTarget":  # test targets are ignored, whatever their name
            why = (f"a second target named {name}" if name is not None
                   else "its `name:` is not a string literal")
            unreadable.setdefault(_normalized(code[m.start():close + 1]), (line, why))
        pos = close + 1

    package = _PACKAGE_CALL.search(code)
    if package:
        open_index = package.end() - 1
        close = _closing(code, open_index)
        listed = _labeled(code[open_index + 1:close]).get("targets")
        for part in _split_top(listed or "", "+"):
            elements = _split_top(part[1:-1], ",") if part.startswith("[") and part.endswith("]") else [part]
            for element in elements:
                call = _ELEMENT_CONSTRUCTOR.match(element)
                if element in target_vars or (call and _closing(element, call.end() - 1) == len(element) - 1):
                    continue  # one constructor call, read above (a trailing `.method()` is not)
                at = code.find(element, open_index)
                unreadable.setdefault(_normalized(element), (line_of(at if at >= 0 else open_index),
                                                             "a `Package(targets:)` entry that is not a target "
                                                             "constructor or a top-level `let X: Target`"))
    return Manifest(targets, unreadable)


def valid_date(value) -> bool:
    """VALUE is a real calendar date written YYYY-MM-DD (the layer map's and the ratchet's exceptions)."""
    text = str(value)
    if not _DATE.match(text):
        return False
    try:
        datetime.date.fromisoformat(text)
    except ValueError:
        return False
    return True


def edge_class(order: dict[str, int], a: str | None, b: str | None) -> str | None:
    """The class of an edge from a target of layer A to one of layer B: None when it points down or sideways
    (or an end is unplaced), else

      hard    B is ui or app (a core, service or domain target depends on a view or the composition root)
      soft    a service depends on a domain model
      upward  any other edge that points up (core -> service, core -> domain)

    Edges only point down (DESIGN section 2), so every class is a violation.
    """
    if a is None or b is None or a not in order or b not in order or order[b] <= order[a]:
        return None
    if b in UPPER_LAYERS:
        return "hard"
    if a == "service" and b == "domain":
        return "soft"
    return "upward"


@dataclasses.dataclass
class LayerMap:
    """plans/cmux-next/architecture-layers.json, read defensively.

    A target entry that is not an object or has no string `layer` places nothing (the target is
    unplaced). A file that does not parse, is not an object or has no list of layer names under `order`
    places nothing either and sets ERROR (the layer gate refuses such a head map; the counts treat every
    target as unplaced).
    """

    order: dict[str, int]
    layers: dict[str, str]
    exceptions: dict[tuple[str, str], dict]
    # `relayered` entries: {"target", "from", "to", "date", "reason"} (a dated reason for a relabel).
    relayered: list[dict] = dataclasses.field(default_factory=list)
    error: str | None = None

    @classmethod
    def parse(cls, text: str | None) -> LayerMap:
        def broken(why: str) -> LayerMap:
            return cls({}, {}, {}, [], why)

        if text is None:
            return cls({}, {}, {}, [])
        try:
            spec = json.loads(text)
        except ValueError as error:
            return broken(f"it is not JSON ({error})")
        if not isinstance(spec, dict):
            return broken("it is not a JSON object")
        order = spec.get("order")
        if (not isinstance(order, list) or not order or not all(isinstance(n, str) for n in order)
                or len(set(order)) != len(order)):
            return broken("`order` is not a list of distinct layer names")
        targets = spec.get("targets", {})
        if not isinstance(targets, dict):
            return broken("`targets` is not an object")
        exceptions = {}
        listed = spec.get("exceptions", [])
        for entry in listed if isinstance(listed, list) else []:
            if isinstance(entry, dict) and isinstance(entry.get("from"), str) and isinstance(entry.get("to"), str):
                exceptions[(entry["from"], entry["to"])] = entry
        listed = spec.get("relayered", [])
        return cls(order={name: i for i, name in enumerate(order)},
                   layers={name: entry["layer"] for name, entry in targets.items()
                           if isinstance(entry, dict) and isinstance(entry.get("layer"), str)},
                   exceptions=exceptions,
                   relayered=[e for e in listed if isinstance(e, dict)] if isinstance(listed, list) else [])

    def placed(self, name: str) -> str | None:
        """NAME's layer, or None when the map does not place it or gives it a layer that is not in `order`."""
        layer = self.layers.get(name)
        return layer if layer in self.order else None

    def unmapped(self, manifest: Manifest) -> set[str]:
        """The targets of MANIFEST that must be placed and are not."""
        return {name for name, t in manifest.targets.items() if t.kind in MAPPED_KINDS and self.placed(name) is None}

    def classify(self, source: str, dep: str) -> str | None:
        """`edge_class` of the edge SOURCE -> DEP with this map's layers."""
        return edge_class(self.order, self.placed(source), self.placed(dep))


@dataclasses.dataclass
class Layers:
    hard: list[tuple[str, str, str, str]]
    soft: list[tuple[str, str, str, str]]
    upward: list[tuple[str, str, str, str]]
    unplaced: list[str]
    error: str | None = None  # why the layer map does not parse (then every target is unplaced)

    def sites(self) -> list[Site]:
        out = [Site("layer_hard", MANIFEST, 0, f"{a} ({la}) -> {b} ({lb})") for a, la, b, lb in self.hard]
        out += [Site("layer_soft", MANIFEST, 0, f"{a} ({la}) -> {b} ({lb})") for a, la, b, lb in self.soft]
        out += [Site("layer_upward", MANIFEST, 0, f"{a} ({la}) -> {b} ({lb})") for a, la, b, lb in self.upward]
        out += [Site("layer_unplaced", LAYERS_JSON, 0, name) for name in self.unplaced]
        return out

    def per_package(self) -> dict[str, collections.Counter]:
        rows: dict[str, collections.Counter] = {r: collections.Counter() for r in LAYER_ROWS}
        for row, edges in (("layer_hard", self.hard), ("layer_soft", self.soft), ("layer_upward", self.upward)):
            for a, *_ in edges:
                rows[row][a] += 1
        for name in self.unplaced:
            rows["layer_unplaced"][name] += 1
        return rows


def layers(manifest_raw: str | None, layers_raw: str | None) -> Layers:
    """The layer edges of a manifest under a layers json (`parse_manifest`, `LayerMap`, `edge_class`)."""
    if manifest_raw is None or layers_raw is None:
        return Layers([], [], [], [])
    manifest = parse_manifest(manifest_raw)
    placed = LayerMap.parse(layers_raw)
    found: dict[str, list[tuple[str, str, str, str]]] = {kind: [] for kind in EDGE_CLASSES}
    for source, dep in sorted(manifest.edges()):
        kind = placed.classify(source, dep)
        if kind is not None:
            found[kind].append((source, placed.placed(source), dep, placed.placed(dep)))
    return Layers(found["hard"], found["soft"], found["upward"], sorted(placed.unmapped(manifest)), placed.error)


# ---------------------------------------------------------------------------------------------------
# Git


class Git:
    """The few git calls the counts make, against one repository."""

    def __init__(self, repo: Path) -> None:
        self.repo = repo

    def run(self, *args: str, check: bool = True) -> str:
        r = subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True)
        if check and r.returncode != 0:
            raise RuntimeError(f"git {' '.join(args)}: {r.stderr.decode(errors='replace').strip()}")
        return r.stdout.decode(errors="replace")

    def rev(self, rev: str) -> str:
        return self.run("rev-parse", "--verify", f"{rev}^{{commit}}").strip()

    def read(self, items: list[tuple[str, str]]) -> dict[tuple[str, str], str | None]:
        """{(rev, path): text or None} through one `git cat-file --batch`."""
        if not items:
            return {}
        data = "".join(f"{rev}:{path}\n" for rev, path in items).encode()
        r = subprocess.run(["git", "-C", str(self.repo), "cat-file", "--batch"], input=data, capture_output=True)
        out = r.stdout
        result: dict[tuple[str, str], str | None] = {}
        i = 0
        for item in items:
            nl = out.index(b"\n", i)
            header = out[i:nl].decode(errors="replace").split()
            i = nl + 1
            if len(header) >= 3 and header[1] == "blob":
                size = int(header[2])
                result[item] = out[i:i + size].decode(errors="replace")
                i += size + 1
            else:
                result[item] = None
        return result

    def changed(self, base: str, head: str) -> list[tuple[str, str]]:
        """(status, path) of every file BASE..HEAD changes (renames as delete + add)."""
        out = self.run("diff", "--name-status", "--no-renames", "-z", base, head, "--")
        parts = [p for p in out.split("\0") if p]
        return [(parts[i], parts[i + 1]) for i in range(0, len(parts) - 1, 2)]

    def swift_files(self, rev: str) -> list[str]:
        out = self.run("ls-tree", "-r", "-z", "--name-only", rev, "--", SOURCES)
        return [p for p in out.split("\0") if p.endswith(".swift")]

    def worktree(self) -> Path | None:
        r = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "--is-inside-work-tree", "--show-toplevel"],
                           capture_output=True, text=True)
        lines = r.stdout.split()
        if r.returncode != 0 or not lines or lines[0] != "true":
            return None
        return Path(lines[1])


def is_source(path: str) -> bool:
    return path.startswith(SOURCES + "/") and path.endswith(".swift")


# ---------------------------------------------------------------------------------------------------
# Counts


@dataclasses.dataclass
class Counts:
    """Per row, per package counts plus the sites behind them."""

    rows: dict[str, collections.Counter]
    sites: dict[str, list[Site]]

    @classmethod
    def empty(cls) -> "Counts":
        return cls({r: collections.Counter() for r in ROW_IDS}, {r: [] for r in ROW_IDS})

    def add_site(self, s: Site, package: str) -> None:
        self.rows[s.row][package] += 1
        self.sites[s.row].append(s)

    def totals(self) -> dict[str, int]:
        return {r: sum(self.rows[r].values()) for r in ROW_IDS}


def count_facts(counts: Counts, facts: FileFacts, table: TypeTable) -> None:
    for s in facts.sites:
        counts.add_site(s, facts.package)
    for st in facts.statics:
        row = classify(st, facts.path, table)
        if row:
            counts.add_site(Site(row, facts.path, st.line, st.text), facts.package)
    if facts.package == APP_PACKAGE:
        counts.rows["app_lines"][APP_PACKAGE] += facts.lines


def count_layers(counts: Counts, lay: Layers) -> None:
    for row, counter in lay.per_package().items():
        counts.rows[row].update(counter)
    for s in lay.sites():
        counts.sites[s.row].append(s)


def full_count(repo: Path, rev: str = "HEAD") -> tuple[str, Counts, Layers]:
    """(sha, counts, layers) of every file at REV."""
    git = Git(repo)
    sha = git.rev(rev)
    paths = git.swift_files(sha)
    texts = git.read([(sha, p) for p in paths] + [(sha, MANIFEST), (sha, LAYERS_JSON)])
    facts = [analyze(p, texts[(sha, p)] or "") for p in paths]
    index: dict[str, list[Decl]] = collections.defaultdict(list)
    for f in facts:
        for d in f.decls:
            index[d.name].append(d)
    table = TypeTable(lambda name: index.get(name, []))
    counts = Counts.empty()
    for f in facts:
        count_facts(counts, f, table)
    lay = layers(texts[(sha, MANIFEST)], texts[(sha, LAYERS_JSON)])
    count_layers(counts, lay)
    return sha, counts, lay


def decl_pattern(names: set[str]) -> str:
    """PCRE for a line that declares one of NAMES (a superset: the file's parse decides)."""
    alternation = "|".join(sorted(re.escape(n) for n in names))
    return rf"\b(?:class|actor|struct|enum)[ \t]+(?:{alternation})\b"


def mention_pattern(names: set[str]) -> str:
    alternation = "|".join(sorted(re.escape(n) for n in names))
    return rf"\b(?:{alternation})\b"


class TypeLookup:
    """Declarations by name at BASE and HEAD without reading every file.

    Files that equal the worktree at both ends are found with `git grep` in the worktree and read from
    disk once (shared by both ends); OVERLAY files (changed by the range or dirty in the worktree) are
    analyzed from each end's git content.
    """

    def __init__(self, git: Git, worktree: Path | None, revs: tuple[str, str]) -> None:
        self.git = git
        self.worktree = worktree
        self.revs = revs
        self.overlay: dict[str, dict[str, FileFacts | None]] = {r: {} for r in revs}
        self.overlay_index: dict[str, dict[str, list[Decl]]] = {r: {} for r in revs}
        self.searched: set[str] = set()
        self._grep_cache: dict[tuple[str, str], object] = {}
        self._pool: concurrent.futures.ThreadPoolExecutor | None = None
        self.shared: dict[str, list[Decl]] = collections.defaultdict(list)
        self.shared_files: dict[str, FileFacts] = {}

    def set_overlay(self, overlay: dict[str, dict[str, FileFacts | None]]) -> None:
        """OVERLAY: rev -> path -> facts at that rev (None: absent) for the files the worktree cannot stand in for."""
        self.overlay = overlay
        for rev, files in overlay.items():
            idx: dict[str, list[Decl]] = collections.defaultdict(list)
            for f in files.values():
                for d in (f.decls if f else []):
                    idx[d.name].append(d)
            self.overlay_index[rev] = idx

    def prefetch(self, pattern: str, rev_for_bare: str) -> None:
        """Start grep_files(PATTERN) now, next to the other git calls (the machine runs them in parallel)."""
        key = (pattern, rev_for_bare)
        if key not in self._grep_cache:
            if self._pool is None:
                self._pool = concurrent.futures.ThreadPoolExecutor(max_workers=2)
            self._grep_cache[key] = self._pool.submit(self._grep, pattern, rev_for_bare)

    def close(self) -> None:
        if self._pool is not None:
            self._pool.shutdown(wait=True)

    def grep_files(self, pattern: str, rev_for_bare: str) -> list[str]:
        """Tracked Swift files under Sources whose text matches the PCRE PATTERN (worktree, else REV)."""
        key = (pattern, rev_for_bare)
        if key not in self._grep_cache:
            self._grep_cache[key] = self._grep(pattern, rev_for_bare)
        value = self._grep_cache[key]
        if isinstance(value, concurrent.futures.Future):
            value = self._grep_cache[key] = value.result()
        return value

    def _grep(self, pattern: str, rev_for_bare: str) -> list[str]:
        args = ["grep", "-l", "-I", "-P", "-e", pattern]
        if self.worktree is None:
            args.append(rev_for_bare)
        args += ["--", f"{SOURCES}/*.swift"]
        r = subprocess.run(["git", "-C", str(self.repo_root()), *args], capture_output=True)
        if r.returncode not in (0, 1):
            raise RuntimeError(f"git grep: {r.stderr.decode(errors='replace').strip()}")
        out = r.stdout.decode(errors="replace").splitlines()
        if self.worktree is None:
            out = [line.split(":", 1)[1] if ":" in line else line for line in out]
        return out

    def repo_root(self) -> Path:
        return self.worktree or self.git.repo

    def read_shared(self, paths: list[str]) -> list[FileFacts]:
        out = []
        todo = [p for p in paths if p not in self.shared_files and not any(p in o for o in self.overlay.values())]
        if self.worktree is not None:
            for p in todo:
                try:
                    text = (self.worktree / p).read_text(errors="replace")
                except OSError:
                    continue
                self.shared_files[p] = analyze(p, text)
        else:
            texts = self.git.read([(self.revs[1], p) for p in todo])
            for p in todo:
                if texts[(self.revs[1], p)] is not None:
                    self.shared_files[p] = analyze(p, texts[(self.revs[1], p)])
        for p in paths:
            if p in self.shared_files:
                out.append(self.shared_files[p])
        return out

    def ensure(self, names: set[str]) -> None:
        """Look up NAMES and the names their declarations link to, TypeTable.DEPTH links deep.

        One worktree `git grep` per depth, only for names not looked up yet.
        """
        level = {n for n in names if repo_type_name(n)}
        for _ in range(TypeTable.DEPTH + 1):
            todo = level - self.searched
            if todo:
                self.searched |= todo
                for f in self.read_shared(self.grep_files(decl_pattern(todo), self.revs[1])):
                    for d in f.decls:
                        if d.name in todo and d not in self.shared[d.name]:
                            self.shared[d.name].append(d)
            links: set[str] = set()
            for n in level:
                decls = list(self.shared.get(n, []))
                for rev in self.revs:
                    decls += self.overlay_index[rev].get(n, [])
                for d in decls:
                    links.update(((d.superclass,) if d.superclass else ()) + d.held)
            level = {n for n in links if repo_type_name(n)}
            if not level:
                return

    def table(self, rev: str) -> TypeTable:
        def decls_for(name: str) -> list[Decl]:
            if repo_type_name(name) and name not in self.searched:
                self.ensure({name})  # a name no planned lookup reached (kept correct, costs a grep)
            return self.shared.get(name, []) + self.overlay_index[rev].get(name, [])
        return TypeTable(decls_for)


@dataclasses.dataclass
class Delta:
    """What BASE..HEAD changes: per-row counts over the files it touches at both ends."""

    base: str
    head: str
    files: list[tuple[str, str]]
    before: Counts
    after: Counts

    def total(self, row: str) -> int:
        return sum(self.after.rows[row].values()) - sum(self.before.rows[row].values())

    def by_package(self, row: str) -> dict[str, int]:
        keys = set(self.after.rows[row]) | set(self.before.rows[row])
        out = {k: self.after.rows[row][k] - self.before.rows[row][k] for k in sorted(keys)}
        return {k: v for k, v in out.items() if v}

    def new_sites(self, row: str) -> list[Site]:
        """HEAD sites whose (file, text) BASE does not have, falling back to text alone (moves)."""
        old = collections.Counter(s.text for s in self.before.sites[row])
        out = []
        for s in self.after.sites[row]:
            if old[s.text] > 0:
                old[s.text] -= 1
            else:
                out.append(s)
        return out


def _decl_signature(facts: list[FileFacts | None]) -> dict[str, collections.Counter]:
    out: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for f in facts:
        for d in (f.decls if f else []):
            out[d.name][(d.kind, d.own_state, d.superclass, d.held)] += 1
    return out


def _may_flip(a: collections.Counter | None, b: collections.Counter | None) -> bool:
    """Whether a name's changed-file declarations A (base) and B (head) can change its statefulness.

    Not when a declaration has state of its own at both ends (stateful at both), nor when neither end
    has one and they link to the same types (the other declarations decide, and they are unchanged).
    """
    a, b = a or collections.Counter(), b or collections.Counter()
    if a == b:
        return False
    own_a = any(sig[1] for sig in a)
    own_b = any(sig[1] for sig in b)
    if own_a and own_b:
        return False
    links = [{x for sig in side for x in ((sig[2],) if sig[2] else ()) + sig[3]} for side in (a, b)]
    return own_a != own_b or links[0] != links[1]


def _static_key(f: FileFacts, st: Static) -> tuple:
    return (f.package, st.type_name, st.keyword, st.container, bool(COMPOSITION_ROOT.match(f.path)))


def delta_count(repo: Path, base: str, head: str) -> Delta:
    """Counts of BASE and HEAD over the files BASE..HEAD changes, so after - before is the push's delta.

    Equal to two full counts subtracted. Statics that the range leaves in place or moves within a
    package (same type, keyword and composition-root side) cancel without a type lookup; only the
    others, and the types whose declarations the range changes, are looked up.
    """
    git = Git(repo)
    # Started first: it stats every source file, and only a type lookup waits for it.
    dirty_proc = subprocess.Popen(["git", "-C", str(repo), "diff", "--name-only", "-z", head, "--", SOURCES],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        worktree: Path | None
        if SHA.fullmatch(base) and SHA.fullmatch(head):  # the hook passes shas: no process to resolve them
            worktree = repo if (repo / ".git").exists() else None
        else:
            r = subprocess.run(["git", "-C", str(repo), "rev-parse", "--show-toplevel", f"{base}^{{commit}}",
                                f"{head}^{{commit}}"], capture_output=True, text=True)
            out = r.stdout.split("\n")
            if r.returncode == 0 and len(out) >= 3:
                worktree = Path(out[0])
                base, head = out[1], out[2]
            else:
                worktree = None
                base, head = git.rev(base), git.rev(head)
        return _delta(git, base, head, worktree, dirty_proc)
    finally:
        if dirty_proc.poll() is None:
            dirty_proc.kill()
        dirty_proc.wait()


def _delta(git: Git, base: str, head: str, worktree: Path | None, dirty_proc: subprocess.Popen) -> Delta:
    files = git.changed(base, head)
    changed = sorted({p for _, p in files if is_source(p)})
    before, after = Counts.empty(), Counts.empty()
    layer_files = [p for p in (MANIFEST, LAYERS_JSON) if any(p == q for _, q in files)]
    items = [(r, p) for r in (base, head) for p in changed]
    if layer_files:
        items += [(r, p) for r in (base, head) for p in (MANIFEST, LAYERS_JSON)]
    texts = git.read(items)
    if layer_files:
        count_layers(before, layers(texts[(base, MANIFEST)], texts[(base, LAYERS_JSON)]))
        count_layers(after, layers(texts[(head, MANIFEST)], texts[(head, LAYERS_JSON)]))
    if not changed:
        return Delta(base, head, files, before, after)
    facts = {r: {p: (analyze(p, texts[(r, p)]) if texts[(r, p)] is not None else None) for p in changed}
             for r in (base, head)}

    # Rows that need no other file.
    for r, counts in ((base, before), (head, after)):
        for f in facts[r].values():
            if f is None:
                continue
            for site in f.sites:
                counts.add_site(site, f.package)
            if f.package == APP_PACKAGE:
                counts.rows["app_lines"][APP_PACKAGE] += f.lines

    # Types whose declarations the range changes, and statics that do not cancel.
    sig_base = _decl_signature(list(facts[base].values()))
    sig_head = _decl_signature(list(facts[head].values()))
    redeclared = {n for n in set(sig_base) | set(sig_head) if _may_flip(sig_base.get(n), sig_head.get(n))}
    keys = {r: collections.Counter(_static_key(f, st) for f in facts[r].values() if f for st in f.statics)
            for r in (base, head)}
    net = {base: keys[base] - keys[head], head: keys[head] - keys[base]}
    wanted = {k[1] for r in (base, head) for k in net[r] if k[1]}
    if not (wanted | redeclared) or not any(repo_type_name(n) for n in wanted | redeclared):
        table = TypeTable(lambda name: [])
        tables = {base: table, head: table}
        lookup = None
    else:
        dirty_out, _ = dirty_proc.communicate()
        if dirty_proc.returncode != 0:
            worktree = None
        lookup = TypeLookup(git, worktree, (base, head))
        # The first lookup round and the flip lookup run while the dirty files are read.
        lookup.prefetch(decl_pattern({n for n in wanted | redeclared if repo_type_name(n)}), head)
        if any(repo_type_name(n) for n in redeclared):
            lookup.prefetch(mention_pattern({n for n in redeclared if repo_type_name(n)}), head)
        dirty = [p for p in dirty_out.decode(errors="replace").split("\0") if is_source(p) and p not in facts[head]]
        dirty_texts = git.read([(head, p) for p in dirty])
        dirty_facts = {p: (analyze(p, dirty_texts[(head, p)]) if dirty_texts[(head, p)] is not None else None)
                       for p in dirty}  # not changed by the range: the same at both ends
        lookup.set_overlay({r: {**facts[r], **dirty_facts} for r in (base, head)})
        lookup.ensure(wanted | redeclared)
        tables = {r: lookup.table(r) for r in (base, head)}
    try:
        return _count_statics(base, head, files, facts, net, redeclared, tables, lookup, before, after)
    finally:
        if lookup is not None:
            lookup.close()


def _count_statics(base, head, files, facts, net, redeclared, tables, lookup, before, after) -> Delta:

    # A type the range flips (a stored var added or removed) changes how statics of it count everywhere,
    # and, one link away (TypeTable.DEPTH), the types whose superclass or stored `let` it is.
    def flipped(names: set[str], depth: int) -> set[str]:
        return {n for n in names if tables[base].stateful_at(n, depth) != tables[head].stateful_at(n, depth)}

    flips = flipped(redeclared, TypeTable.DEPTH)
    own_flips = flipped(redeclared, 0)
    mentioned = {n for n in redeclared if repo_type_name(n)}
    if lookup is not None and own_flips:
        # The prefetched grep of every redeclared name (a superset of OWN_FLIPS; the parse filters).
        mention = lookup.read_shared(lookup.grep_files(mention_pattern(mentioned), head))
        decls = [d for f in mention for d in f.decls]
        decls += [d for r in (base, head) for f in lookup.overlay[r].values() if f for d in f.decls]
        linkers = {d.name for d in decls if own_flips & ({d.superclass} | set(d.held))}
        lookup.ensure(linkers)
        flips |= flipped(linkers, TypeTable.DEPTH)

    for r, counts in ((base, before), (head, after)):
        left = collections.Counter(net[r])
        for f in facts[r].values():
            for st in (f.statics if f else []):
                key = _static_key(f, st)
                if st.type_name not in flips:
                    if left[key] <= 0:
                        continue  # the other end has the same static: it cancels
                    left[key] -= 1
                row = classify(st, f.path, tables[r])
                if row:
                    counts.add_site(Site(row, f.path, st.line, st.text), f.package)

    if lookup is not None and flips:
        overlay_paths = set(lookup.overlay[head])
        found = set(lookup.grep_files(mention_pattern(mentioned), head)) if mentioned else set()
        rest = {n for n in flips if repo_type_name(n)} - mentioned
        if rest:
            found |= set(lookup.grep_files(mention_pattern(rest), head))
        users = sorted(p for p in found if p not in overlay_paths)
        unchanged = lookup.read_shared(users) + [f for p, f in lookup.overlay[head].items() if p not in facts[head] and f]
        for f in unchanged:
            for r, counts in ((base, before), (head, after)):
                for st in f.statics:
                    if st.type_name in flips:
                        row = classify(st, f.path, tables[r])
                        if row:
                            counts.add_site(Site(row, f.path, st.line, st.text), f.package)
    return Delta(base, head, files, before, after)


# ---------------------------------------------------------------------------------------------------
# The json record


def record(sha: str, counts: Counts, lay: Layers, exceptions: list | None = None) -> dict:
    """The arch-ratchet.json object for a full count."""
    packages: dict[str, dict[str, int]] = collections.defaultdict(dict)
    for row in ROW_IDS:
        for pkg, n in sorted(counts.rows[row].items()):
            if n:
                packages[pkg][row] = n
    return {
        "_doc": ("Architecture counts the pre-push ratchet holds (scripts/cmux-next/arch-ratchet.py; the method is "
                 "scripts/cmux-next/arch_counts.py, whose docstring defines every row). A push may not raise a "
                 "ratcheted row's total; when one drops, rerun `scripts/cmux-next/arch-ratchet.py --update`. "
                 "exceptions: [{\"date\": \"YYYY-MM-DD\", \"row\": \"<row>\", \"allow\": <n>, \"why\": \"...\"}] "
                 "lets the push that adds the entry raise that row by n; never CI."),
        "method": "arch_counts",
        "method_version": METHOD_VERSION,
        "measured_sha": sha,
        "measured_date": datetime.date.today().isoformat(),
        "rows": {row.id: {"title": row.title, "ratchet": row.ratchet} for row in ROWS},
        "totals": counts.totals(),
        "packages": dict(sorted(packages.items())),
        "layer_edges": {
            "hard": [f"{a} ({la}) -> {b} ({lb})" for a, la, b, lb in lay.hard],
            "soft": [f"{a} ({la}) -> {b} ({lb})" for a, la, b, lb in lay.soft],
            "upward": [f"{a} ({la}) -> {b} ({lb})" for a, la, b, lb in lay.upward],
            "unplaced": lay.unplaced,
        },
        "exceptions": exceptions if exceptions is not None else [],
    }


def write_record(repo: Path, data: dict) -> Path:
    path = repo / RATCHET_JSON
    path.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n")
    return path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=None)
    parser.add_argument("--rev", default="HEAD")
    parser.add_argument("--write", action="store_true", help=f"write {RATCHET_JSON} at --rev")
    parser.add_argument("--delta", nargs=2, metavar=("BASE", "HEAD"))
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--sites", metavar="ROW", help="print the sites of ROW (full count)")
    args = parser.parse_args(argv)
    repo = Path(args.repo).resolve() if args.repo else Path(
        subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip())
    if args.delta:
        d = delta_count(repo, *args.delta)
        totals = {row: d.total(row) for row in ROW_IDS}
        if args.json:
            print(json.dumps({"base": d.base, "head": d.head, "delta": totals,
                              "packages": {r: d.by_package(r) for r in ROW_IDS if d.by_package(r)}}, sort_keys=True))
        else:
            for row in ROWS:
                print(f"{row.id:34} {totals[row.id]:+d} {d.by_package(row.id) or ''}")
        return 0
    sha, counts, lay = full_count(repo, args.rev)
    if args.write:
        old_exceptions = []
        existing = repo / RATCHET_JSON
        if existing.is_file():
            try:
                old_exceptions = json.loads(existing.read_text()).get("exceptions", [])
            except (OSError, ValueError):
                old_exceptions = []
        print(f"wrote {write_record(repo, record(sha, counts, lay, old_exceptions))}")
    if args.sites:
        for s in counts.sites[args.sites]:
            print(f"{s.path}:{s.line}: {s.text}")
        return 0
    if args.json:
        print(json.dumps(record(sha, counts, lay), sort_keys=True))
    else:
        totals = counts.totals()
        print(f"arch_counts v{METHOD_VERSION} at {sha[:11]}")
        for row in ROWS:
            print(f"  {row.id:34} {totals[row.id]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

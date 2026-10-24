#!/usr/bin/env python3
"""Architecture counts for cmux-next, method v3: the numbers plans/cmux-next/arch-ratchet.json records.

The rules are the goal (repo CLAUDE.md "Refactor architecture", "Modern Swift concurrency";
plans/cmux-next/perf-lead.md "Architecture targets"); these counts are proxies, and a pattern renamed
to dodge a count is still counted where the method can see it. Every row is counted per package
(the target directory under Sources) and in total.

Scope: tracked Swift under Packages/macOS/CmuxNext/Sources, read from git objects, with comments and
string literals blanked (same length, so offsets and line numbers stay). Package rows come from a
static parse of Packages/macOS/CmuxNext/Package.swift (never `swift package dump-package`: 4-6 s).

Rows (method v3; a change of any definition bumps METHOD_VERSION, and `arch-ratchet.py --update` then
rewrites the json without comparing totals: reviewers compare the definitions):
  layer_hard              target edges from a core, service or domain target to a ui or app target
                          (layers from plans/cmux-next/architecture-layers.json, as arch-layers.py)
  layer_soft              edges from a service target to a domain target
  layer_upward            every other edge that points up a layer: core -> service, core -> domain
                          (edges only point down, DESIGN section 2)
  layer_unplaced          regular, executable and binary targets that architecture-layers.json does not
                          place (no entry, an entry without a string `layer`, a layer not in `order`, or a
                          map that does not parse). One static reader (`parse_manifest`) and one map reader
                          (`LayerMap`) serve these rows, arch-layers.py and the pre-push layer gate
  stateful_singletons     a global whose type is stateful, whatever its name: a stored type-scope
                          `static let/var` (also `static weak/unowned var`) or a stored file-scope
                          `let/var` (a global by another spelling), at a line start or after a `{` or
                          `;` (`enum E { static let shared = S() }`). Every type the declaration names
                          counts, and one stateful type is enough: the annotation (a protocol or
                          `any P` annotation does not hide a stateful initializer); the initializer's
                          constructed type (`T(`, `T<..>(`, `T.init(`, `Self(`, `.init(`, `T.factory(`,
                          the enclosing type for Self/.init, `T {`, or a member read of a stateful
                          system type such as `FileManager.default`); for an immediately invoked
                          closure `{ ... }()`, its `() -> T in` and what it returns (`return T(...)`,
                          or a local `let x = T(...)` that it returns); for a lowercase call
                          `make(...)`, the return type of `func make` (this file's, else every
                          file-scope or static `func make` in the sources: `func:make` in the type
                          table); and every type the initializer constructs inside it
                          (`Env(store: Store())`). Stateful: an actor; a repo class with a stored
                          instance `var` or a lock/cache field; a repo struct/enum with a lock/cache
                          field; UserDefaults, URLSession, NotificationCenter, OperationQueue, NSWindow,
                          NSPanel, NSWorkspace, FileManager, WKProcessPool, WKWebsiteDataStore (and
                          DistributedNotificationCenter); and, through any number of links, a repo type
                          whose superclass or stored instance property has a stateful type (a class: its
                          stored `let`s; a struct: its stored `let`s and `var`s). A name declared more
                          than once (two modules) is stateful when any declaration is. Not counted:
                          @TaskLocal statics, and an association key: a static whose address (or
                          pointer value) this file passes as the key of objc_get/setAssociatedObject and
                          whose type is a key type (UInt8, Int, Bool, a raw pointer; or an integer or
                          Boolean literal). The name is never the test, and a key used from another file
                          counts (keep the key private next to its use). No file is exempt (the
                          composition root holds instances, not statics). A file-scope func that a
                          `make()` initializer resolves to is written at column 0 (every one in the
                          sources is; an indented one is not in the type table).
  global_mutable_statics  any other stored `static var` or file-scope `var`, or a static or file-scope
                          lock/cache/atomic container (Mutex, OSAllocatedUnfairLock, NSLock,
                          NSRecursiveLock, NSCondition(Lock), NSCache, NSHashTable, NSMapTable, Atomic,
                          ManagedAtomic, NSMutable*), serial queue (DispatchQueue), running Task or
                          stream (AsyncStream, AsyncThrowingStream); same skips as above
  assume_isolated_outside_adapters
                          every `MainActor.assumeIsolated` except an adapter site: not inside a
                          `deinit` and not inside a raw NotificationCenter `addObserver(... queue: .main)`
                          block, a `main-proof:` comment on its own line, in the contiguous comment
                          block directly above it, or trailing its opener on the line directly above
                          when that line has no call of its own (one proof per call: the first code
                          line above ends the search), and inside a seam adapter type: the innermost
                          type around the call is a class/struct/enum/actor declared there (not an
                          extension of a type declared elsewhere, not a protocol, not a free function)
                          whose own body is at most 150 code lines
  assume_isolated_total   every `MainActor.assumeIsolated` (report only)
  app_broadcast_names     custom Notification.Name declarations: `Notification.Name(`,
                          `Notification.Name.init(`, `Name(rawValue:`, `.init(`/`Self(` inside an
                          `extension Notification.Name`, `: Notification.Name = .init(`,
                          `post(name: .init(`, and a type or extension that conforms to
                          `NotificationCenter.MainActorMessage`/`AsyncMessage` (a typed broadcast); not
                          counted: a literal that starts with `com.apple.`
  observer_sites          `addObserver(`, `.notifications(named:`, `.publisher(for:`, `.messages(of:`,
                          `MainActorObservation(`, KVO `.observe(\\.keyPath`, and
                          `CFNotificationCenterAddObserver(` (not a `func addObserver(` declaration)
  app_lines               physical lines (newlines) of CmuxNextApp Swift (report only here)

codebase-health.py imports these patterns, analyze(), count_texts() and layers(), so its report and the ratchet share
one definition of every row (arch-layers.py, PL-arch's, keeps its own grep counts).

Site identity (Delta.unpartnered, the ratchet's swap rule): a counted global keeps its identity by its owner
and name (`Store.shared`; the file and name for a file-scope global) or by its primary type, a broadcast by
its literal (or its message type), an assumeIsolated outside an adapter by the type and function around it,
a layer edge by its two targets.

Delta mode (the pre-push hook) reads only the files a range changes, at both ends, and gives the same
numbers as two full counts subtracted (tests/test_arch_ratchet.py checks it). Statics the range leaves
in place, or moves within a package, cancel without a type lookup; for the rest, and for types whose
declarations the range changes, one worktree `git grep -o` lists every declaration line (DECL_INDEX) and a
type search reads only the declaring files it reaches (the worktree stands in for both ends for every
file that equals them; changed and dirty files are read from git objects). A type whose statefulness the
range flips (a class gains a stored var) re-counts the unchanged files that name it (a `func:` entry only
as a bare call that starts an expression), and then the types that hold it, link by link. Most pushes need
no grep: about 4 git processes in all.

Every analyzed file's facts are kept by (blob id, path) in `<git common dir>/cmux-arch-counts/` (FactsCache,
one sqlite file per version of this script), so a file is analyzed once per content: a warm 80-file
cross-package move reads no file twice; the first run after this file changes pays the analysis once.

The file is self-contained (standard library only): perf-cron-arch-report.py runs a commit's own copy
under `python3 -I`.

Usage:
  scripts/cmux-next/arch_counts.py [--rev REV] [--json]     full count at REV (default HEAD)
  scripts/cmux-next/arch_counts.py --sites ROW [--rev REV]  the sites of ROW
  scripts/cmux-next/arch_counts.py --delta BASE HEAD [--json]
The one writer of plans/cmux-next/arch-ratchet.json is `arch-ratchet.py --update` (it refuses a rise that
no dated exception covers).
"""

from __future__ import annotations

import argparse
import bisect
import collections
import concurrent.futures
import dataclasses
import datetime
import hashlib
import json
import re
import sqlite3
import subprocess
import sys
from pathlib import Path

# v2: file-scope globals, weak/unowned statics, closure and factory initializers, held struct state, any link
# depth, one main-proof per call, KVO and CFNotificationCenter observers, no composition-root exemption.
# v3: seam adapters per type (an extension or free function is none), association keys by use and shape (not
# by name), declarations after `{`/`;`, DispatchQueue/Task/AsyncStream statics, typed NotificationCenter
# messages and `.messages(of:` observers, file-scope funcs at column 0, site identity keys.
METHOD_VERSION = 3
SOURCES = "Packages/macOS/CmuxNext/Sources"
MANIFEST = "Packages/macOS/CmuxNext/Package.swift"
LAYERS_JSON = "plans/cmux-next/architecture-layers.json"
RATCHET_JSON = "plans/cmux-next/arch-ratchet.json"
# This file in the repo (the row definitions). A literal, not __file__: the installed hook runs a copy.
METHOD_FILE = "scripts/cmux-next/arch_counts.py"
# What a count reads besides the Swift sources (is_source): full_count reads both at the counted
# commit; delta_count reads both at each end when its range changes one.
COUNT_INPUTS = (MANIFEST, LAYERS_JSON)
# Every path whose change can change a recorded count: COUNT_INPUTS and the row definitions. With the
# Swift sources, is_counted is the one test for it (arch-ratchet.py's measured_in_range uses it).
COUNTED_PATHS = COUNT_INPUTS + (METHOD_FILE,)
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
    Row("stateful_singletons", "stateful singletons (stored static or file-scope global of a stateful type)", True),
    Row("global_mutable_statics", "global mutable statics (static or file-scope var, lock, cache)", True),
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
# Shared mutable machinery: locks, caches, atomics, mutable Foundation collections, a serial queue (the
# queue-as-lock CLAUDE.md bans), a running Task and a stream (its continuation is a process-wide channel).
CONTAINERS = frozenset({
    "Mutex", "OSAllocatedUnfairLock", "NSLock", "NSRecursiveLock", "NSCondition", "NSConditionLock",
    "NSCache", "NSHashTable", "NSMapTable", "Atomic", "ManagedAtomic", "NSMutableDictionary",
    "NSMutableArray", "NSMutableSet", "NSMutableOrderedSet", "DispatchQueue", "Task", "AsyncStream",
    "AsyncThrowingStream",
})
# Names that are never a repo type: system classes and value types a static commonly holds.
SYSTEM_PREFIX = re.compile(r"^(?:NS|WK|CA|CG|CF|AV|UI|MTL|MTK|SC|UN|AS|QL|SK|OS|CL|IO|VN|SF|CI|CT|CV|CM)[A-Z]")
VALUE_NAMES = frozenset({
    "String", "Int", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Double", "Float",
    "CGFloat", "Bool", "Character", "Array", "Dictionary", "Set", "Optional", "URL", "Data", "Date", "UUID",
    "Duration", "TimeInterval", "Color", "Font", "Image", "Logger", "Self", "Void", "Any", "AnyObject",
})
# A file-scope or static `func` in the type table: `func:make` links to make's return type, so a global
# initialized by `make()` is as stateful as what make returns.
FUNC = "func:"

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
TYPEALIAS = re.compile(
    rf"^[ \t]*(?:{ATTR}\s+)*(?:{MODS}\s+)*typealias[ \t]+([A-Za-z_]\w*)\s*(?:<[^=\n]*>)?\s*=\s*([^\n]*)", re.M)
# A stored `let`/`var` declaration: a type-scope static (`static` among the modifiers) or, with no enclosing
# brace, a file-scope global. weak/unowned are modifiers too (`static weak var app: App?` is a singleton). It
# starts a line or follows a `{` or `;` (`enum E { static var n = 0 }`, `let a = 1; let b = Store()`); the
# match ends before its `=` (group 5) or where the annotation ends, so the next declaration on the line is seen.
STATIC = re.compile(
    rf"(?:^|(?<=[{{;]))[ \t]*(?:{ATTR}\s+)*((?:(?:{MODS}|static|class|lazy|override|weak|unowned(?:\([\w ]+\))?)\s+)*)"
    r"(let|var)\s+(`?[A-Za-z_]\w*`?)"
    r"[ \t]*(?::[ \t]*([^=\n{};]+?))?[ \t]*(?=(=)|[{};\n]|$)",
    re.M,
)
# A func declaration; its modifiers are on the `func` line (DECL_INDEX greps `static ... func name` lines).
FUNC_DECL = re.compile(
    rf"^[ \t]*(?:{ATTR}\s+)*((?:(?:{MODS}|static|class|override|mutating|nonmutating)[ \t]+)*)func[ \t]+"
    r"([A-Za-z_]\w*)\s*(?:<[^(){}\n]*>)?\s*\(",
    re.M,
)
FUNC_RESULT = re.compile(
    r"\s*(?:async\s+)?(?:(?:re)?throws\b(?:\s*\([^()]*\))?\s*)?(?:async\s+)?->\s*([^{\n]+?)\s*(?:\bwhere\b[^{\n]*)?(?:\{|$)",
    re.M,
)
# A type constructed in an initializer outside its closures (`Env(store: Store())` holds a Store; a closure's
# body runs later and is not held), and a stateful system singleton passed as a whole
# (`Config(defaults: UserDefaults.standard)`; `FileManager.default.temporaryDirectory` is a URL value).
CONSTRUCT = re.compile(r"(?<![\w.])([A-Z]\w*)\s*(?:<[^(){}\n]*?>)?\s*(?:\.\s*init\s*)?\(")
SYS_ACCESSORS = frozenset({"standard", "default", "shared", "main", "current"})
SYS_READ = re.compile(r"(?<![\w.])(" + "|".join(sorted(SYS_STATEFUL)) + r")\s*\.\s*(?:" + "|".join(sorted(SYS_ACCESSORS))
                      + r")\b(?:\s*\(\s*\))?(?!\s*[.(\w])")
LOWER_CALL = re.compile(r"([a-z_]\w*)\s*(?:<[^(){}\n]*?>)?\s*\(")
LEAD = re.compile(r"\s*(?:(?:try[!?]?|await)\s+)*")
NOT_CALLS = frozenset({"if", "switch", "try", "await", "some", "any", "return"})
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
                      r"\bMainActorObservation\s*\(|\.observe\s*\(\s*\\|\bCFNotificationCenterAddObserver\s*\(|"
                      r"\.messages\s*\(\s*of\s*:")
OBSERVER_DECL = re.compile(r"\bfunc\s+$")  # `func addObserver(` declares one, it is no site
BROADCAST = re.compile(
    r"\b(?:NS)?Notification\s*\.\s*Name\s*(?:\.\s*init\s*)?(\()|\bName\s*(\()\s*rawValue\s*:|"
    r":\s*(?:NS)?Notification\s*\.\s*Name\s*=\s*\.init\s*(\()|\bpost\s*\(\s*name\s*:\s*\.init\s*(\()"
)
EXT_NAME = re.compile(r"\bextension\s+(?:NS)?Notification\s*\.\s*Name\b")
# A typed broadcast (macOS 26 NotificationCenter messages): a type or extension that conforms to one.
MESSAGE_CONFORMANCE = re.compile(r"\b(?:NotificationCenter\s*\.\s*)?(?:MainActorMessage|AsyncMessage)\b")
INIT_CALL = re.compile(r"(?<![\w.])(?:\.init|Self(?:\s*\.\s*init)?)\s*(\()")
NC_MAIN = re.compile(r"addObserver\s*\([^{}]*\bqueue\s*:\s*(?:\.main|OperationQueue\s*\.\s*main)\b[^{}]*$")
DEINIT = re.compile(r"\bdeinit\s*$")
# The key argument of an Objective-C association call: `&key`, `&Self.key`, `&Type.key` or a pointer `key`.
ASSOC_USE = re.compile(r"\bobjc_(?:get|set)AssociatedObject\s*\([^,()]*(?:\([^()]*\)[^,()]*)*,\s*&?\s*"
                       r"(?:Self\s*\.\s*|[A-Za-z_]\w*\s*\.\s*)?([A-Za-z_]\w*)")
# What an association key holds: only its address (or pointer value) is used, never its contents.
KEY_TYPES = frozenset({"UInt8", "Int8", "UInt", "Int", "Bool", "Character", "Void", "UnsafeRawPointer",
                       "UnsafeMutableRawPointer"})
SUPERCLASS = re.compile(r"^\s*(?:<[^{}]*?>)?\s*:\s*(?:@\w+\s+)?([A-Za-z_][\w.]*)")


@dataclasses.dataclass
class Decl:
    """A class/actor/struct/enum/protocol/typealias declaration (or a `func:` result link) and what makes it
    stateful on its own. PATH and PACKAGE scope a name lookup: a reference resolves to its own file's
    declarations of the name, else its package's, else every declaration (TypeTable)."""

    name: str
    kind: str
    own_state: bool
    superclass: str | None
    # Types of its stored instance properties (a held stateful object is state): a class's stored `let`s,
    # a struct's stored `let`s and `var`s; for a `func:` entry, its return type; for a typealias, its target.
    held: tuple[str, ...] = ()
    path: str = ""
    package: str = ""

    def links(self) -> tuple[str, ...]:
        return ((self.superclass,) if self.superclass else ()) + self.held


@dataclasses.dataclass
class Static:
    """A stored type-scope static or file-scope global, before its types are resolved.

    TYPES: every type the declaration names (annotation, initializer, what it constructs); it counts as a
    stateful singleton when any of them is stateful. CONTAINER: the annotation or the constructed type is a
    lock/cache/atomic container.
    """

    line: int
    text: str
    keyword: str
    types: tuple[str, ...]
    container: bool
    name: str = ""
    # The type it is declared in (the extended type for an `extension Store`); "" for a file-scope global.
    owner: str = ""


@dataclasses.dataclass
class Site:
    """A counted finding: the row, file, 1-based line and the source line's text.

    KEYS: what identifies the debt across a move or an edit (Delta.unpartnered): a global's owner-qualified
    `name:` and its primary `type:`, an assumeIsolated's `scope:` (the type and function around it), a
    broadcast's name literal, a layer edge. Empty: the site is identified by its text.
    """

    row: str
    path: str
    line: int
    text: str
    keys: tuple[str, ...] = ()


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
    if not rest and len(after) == 1 and parts[k] in SYS_STATEFUL and after[0] in SYS_ACCESSORS:
        return parts[k]
    return None


def _is_proved(raw_lines: list[str], i: int) -> bool:
    """A `main-proof:` comment for the call on line I: on that line, in the contiguous comment block directly
    above it, or trailing the code line directly above when that line is the call's opener and has no call of
    its own (`setCompletionBlock { // main-proof: ...`). One proof covers one call: below another call, or
    with any code line between, a call needs its own.
    """
    if "main-proof:" in raw_lines[i]:
        return True
    j = i - 1
    while j >= 0 and re.match(r"^\s*(?://|\*|/\*)", raw_lines[j]):
        if "main-proof:" in raw_lines[j]:
            return True
        j -= 1
    return j == i - 1 and j >= 0 and "main-proof:" in raw_lines[j] and not ASSUME.search(raw_lines[j])


def _statement(code: str, start: int) -> str:
    """The expression from START to the end of its statement (a newline or `;` outside brackets)."""
    depth = 0
    i = start
    n = len(code)
    while i < n:
        ch = code[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif ch in "\n;" and depth == 0:
            break
        i += 1
    return code[start:i]


def _expr_types(expr: str, owner: str | None, funcs: dict[str, list[str]]) -> list[str]:
    """Every type the initializer EXPR names: its constructed type first, then the types built inside it.

    A lowercase call `make(...)` resolves through FUNCS (this file's file-scope and static funcs), else
    to the `func:make` entry of the type table (every such func in the sources).
    """
    expr = expr[LEAD.match(expr).end():]
    out: list[str] = []
    primary = _init_type(expr, owner)
    if primary:
        out.append(primary)
    else:
        call = LOWER_CALL.match(expr)
        if call and call.group(1) not in NOT_CALLS:
            out += funcs.get(call.group(1)) or [FUNC + call.group(1)]
    held = _without_closures(expr)
    out += [m.group(1) for m in CONSTRUCT.finditer(held)]
    out += [m.group(1) for m in SYS_READ.finditer(held)]
    return out


def _without_closures(expr: str) -> str:
    """EXPR with every `{ ... }` body (balanced) cut to `{}`: what a closure builds is not held by the value."""
    out: list[str] = []
    depth = 0
    for ch in expr:
        if ch == "{":
            if depth == 0:
                out.append("{")
            depth += 1
        elif ch == "}" and depth:
            depth -= 1
            if depth == 0:
                out.append("}")
        elif depth == 0:
            out.append(ch)
    return "".join(out)


def _closure_types(code: str, braces: Braces, open_pos: int, owner: str | None,
                   funcs: dict[str, list[str]]) -> list[str]:
    """The types an immediately invoked closure at OPEN_POS yields: its `() -> T in`, what it returns
    (`return T(...)`, or a local `let x = T(...)` it returns) and, with no `return`, its last expression."""
    close = braces.close.get(open_pos, len(code))
    parts: list[str] = []
    i = open_pos + 1
    for child in braces.children(open_pos):  # nested closures and blocks: their returns are not this one's
        parts.append(code[i:child])
        parts.append("{}")
        i = braces.close.get(child, len(code)) + 1
    parts.append(code[i:close])
    top = "".join(parts)
    out: list[str] = []
    signature = re.match(r"\s*(?:\[[^\]]*\]\s*)?\(\s*\)\s*(?:throws\s+)?->\s*(.+?)\s+in\b", top)
    if signature and _type_name(signature.group(1)):
        out.append(_type_name(signature.group(1)))
    results = re.findall(r"\breturn\s+([^\n;]+)", top)
    if not results:
        statements = [s for s in re.split(r"[\n;]", top) if s.strip()]
        results = statements[-1:]
    for expr in results:
        found = _expr_types(expr, owner, funcs)
        name = expr.strip()
        if not found and re.fullmatch(r"[a-z_]\w*", name):
            local = re.compile(rf"\b(?:let|var)\s+{re.escape(name)}\b[ \t]*(?::[ \t]*([^=\n;]+?))?[ \t]*"
                               r"(?:=[ \t]*([^\n;]+))?(?=[\n;]|$)")
            for m in local.finditer(top):
                if m.group(1) and _type_name(m.group(1)):
                    found.append(_type_name(m.group(1)))
                if m.group(2):
                    found += _expr_types(m.group(2), owner, funcs)
        out += found
    return out


def _initializer_types(code: str, braces: Braces, eq_pos: int, owner: str | None,
                       funcs: dict[str, list[str]]) -> list[str]:
    """The types of the initializer after the `=` at EQ_POS (it may start on the next line)."""
    start = eq_pos + 1
    n = len(code)
    while start < n and code[start] in " \t\n":
        start += 1
    if start < n and code[start] == "{" and start in braces.close:
        close = braces.close[start]
        if code[close + 1:close + 41].lstrip(" \t").startswith("("):
            return _closure_types(code, braces, start, owner, funcs)
        return []  # a closure value: its type is a function type
    return _expr_types(_statement(code, start), owner, funcs)


def _owners(code: str, braces: Braces) -> tuple[list[tuple[int, str, str, str]], dict[int, tuple[str, str]]]:
    """([(body open, kind, name, text between name and body)], body open -> (kind, name))."""
    entries: list[tuple[int, str, str, str]] = []
    owners: dict[int, tuple[str, str]] = {}
    for m in TYPE_DECL.finditer(code):
        kind, name = m.group(1), m.group(2)
        brace = code.find("{", m.end())
        if brace < 0 or brace not in braces.close:
            continue
        between = code[m.end():brace]
        if ";" in between:
            continue
        short = name.split(".")[-1]
        owners[brace] = (kind, short)
        entries.append((brace, kind, short, between))
    return entries, owners


ADAPTER_KINDS = frozenset({"class", "struct", "enum", "actor"})
ADAPTER_MAX_LINES = 150


def _in_adapter_type(code: str, braces: Braces, owners: dict[int, tuple[str, str]], scopes: list[int]) -> bool:
    """Whether the innermost type around a site (SCOPES, innermost first) is a seam adapter type: a class,
    struct, enum or actor declared here (not an extension of a type declared elsewhere, not a protocol)
    whose own body is at most ADAPTER_MAX_LINES code lines. A free function or file-scope code is none."""
    for p in scopes:
        if p in owners:
            if owners[p][0] not in ADAPTER_KINDS:
                return False
            body = code[p + 1:braces.close.get(p, len(code))]
            return sum(1 for line in body.split("\n") if line.strip()) <= ADAPTER_MAX_LINES
    return False


# The declaration a body brace opens, at the end of its head: a func, an init/deinit/subscript, or a computed
# or observed property (`var x: T {`; a `let`/`var` with `=` is a stored value whose `{` is a closure).
BODY_DECL = re.compile(
    r"(?:\bfunc\s+([^\s(<]+)[^{}]*|(?<![.\w])(init|deinit|subscript)\b[^{}]*"
    r"|(?:^|\n)[ \t]*(?:(?!(?:for|if|guard|while|case|catch)\b)[\w@]+(?:\([^()\n]*\))?[ \t]+)*var\s+`?(\w+)`?[^{}=]*)$")


def _scope_key(path: str, braces: Braces, owners: dict[int, tuple[str, str]], scopes: list[int]) -> str:
    """`scope:<Type>.<function>` of a site (SCOPES, innermost first): the innermost function, init, deinit,
    subscript or computed property around it, and the innermost type (or extended type) around that; the
    file stands in for the type at file scope. An edit of the line or a move of the file keeps it; the
    same call in another type or function is another site."""
    func = "-"
    for p in scopes:
        if p in owners:
            return f"scope:{owners[p][1]}.{func}"
        if func == "-":
            m = BODY_DECL.search(braces.head(p))
            if m:
                func = next(g for g in m.groups() if g)
    return f"scope:{path}:{func}"


def _funcs(code: str, braces: Braces, owners: dict[int, tuple[str, str]]) -> dict[str, list[str]]:
    """{name: return types} of the file-scope and static/class funcs (the ones a static can call bare).

    A file-scope func is written at column 0 (its `func` line is not indented), as every one in the sources
    is: DECL_INDEX then finds it without matching the indented instance methods of the same name.
    """
    out: dict[str, list[str]] = collections.defaultdict(list)
    for m in FUNC_DECL.finditer(code):
        mods, name = m.group(1) or "", m.group(2)
        scopes = braces.enclosing(m.start())
        if re.search(r"\b(?:static|class)\b", mods):
            if not scopes or scopes[0] not in owners:
                continue
            owner = owners[scopes[0]][1]
        elif scopes:
            continue  # an instance method: no static initializer calls it bare
        else:
            keyword = m.start(1) if mods else code.rfind("func", m.start(), m.start(2))
            if code[code.rfind("\n", 0, keyword) + 1] in " \t":
                continue  # indented: not a file-scope func for this table (see the docstring)
            owner = None
        result = FUNC_RESULT.match(code, _closing(code, m.end() - 1) + 1)
        if not result:
            continue
        text = result.group(1).strip()
        t = owner if re.fullmatch(r"Self\s*[?!]?", text) else _type_name(text)
        if t and t not in out[name]:
            out[name].append(t)
    return {k: v for k, v in out.items() if v}


def _decls(code: str, braces: Braces, entries: list[tuple[int, str, str, str]],
           funcs: dict[str, list[str]]) -> list[Decl]:
    """The type declarations of the file, plus one `func:NAME` entry per file-scope or static func.

    Protocols and typealiases are entries too (never stateful on their own; a typealias links to its
    target): they shadow a same-named type of another file or package in the scoped lookup.
    """
    decls: list[Decl] = []
    for m in TYPEALIAS.finditer(code):
        target = _type_name(m.group(2))
        decls.append(Decl(m.group(1), "typealias", False, None, (target,) if target and target != m.group(1) else ()))
    for brace, kind, name, between in entries:
        if kind == "extension":
            continue
        if kind == "protocol":
            decls.append(Decl(name, kind, False, None))
            continue
        superclass = None
        if kind == "class":
            sm = SUPERCLASS.match(between)
            if sm:
                superclass = sm.group(1).split(".")[-1]
        own, held = _own_state(code, braces, brace, kind, name, funcs)
        decls.append(Decl(name, kind, kind == "actor" or own, superclass, held))
    for name, types in sorted(funcs.items()):
        decls.append(Decl(FUNC + name, "func", False, None, tuple(types)))
    return decls


HELD_LET = re.compile(
    rf"(?:^|[\n;])[ \t]*(?:{ATTR}\s+)*((?:(?:{MODS}|static|class|weak|unowned(?:\([\w ]+\))?)\s+)*)let\s+"
    r"(?:`?[A-Za-z_]\w*`?)[ \t]*(?::[ \t]*([^=\n]+?))?[ \t]*(?:=[ \t]*([^\n]*))?$",
    re.M,
)


def _member_types(ann: str | None, init: str | None, owner: str, funcs: dict[str, list[str]]) -> list[str]:
    """The lookup-worthy types of a stored member with annotation ANN and initializer INIT."""
    found: list[str] = []
    if ann and _type_name(ann):
        found.append(_type_name(ann))
    if init:
        found += _expr_types(init, owner, funcs)
    return [t for t in found if t != owner and (t in SYS_STATEFUL or lookup_name(t))]


def _own_state(code: str, braces: Braces, open_pos: int, kind: str, owner: str,
               funcs: dict[str, list[str]]) -> tuple[bool, tuple[str, ...]]:
    """(state of its own, the types of its stored properties) of the body at OPEN_POS.

    Own state: a lock/cache field, or (a class) a stored instance `var`. Held: a class's stored `let`s, a
    struct's stored `let`s and `var`s (a struct that holds a stateful object shares that state).
    """
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
        for m in HELD_LET.finditer(text):
            if re.search(r"\b(?:static|class|weak|unowned)\b", m.group(1)):
                continue
            held += _member_types(m.group(2), m.group(3), owner, funcs)
        for m in VAR_MEMBER.finditer(text):
            if re.search(r"\b(?:static|class)\b", m.group(1)):
                continue
            rest = m.group(2)
            followed_by_block = child is not None and "\n" not in text[m.end():]
            stored = "=" in rest or not followed_by_block
            if not stored:
                block = code[child + 1:braces.close.get(child, len(code))]
                stored = bool(re.search(r"\b(?:didSet|willSet)\b", block))
            if not stored:
                continue
            if kind == "class":
                own = True
                continue
            member = re.match(r"\s*:\s*([^=]+?)\s*(?:=\s*(.*))?$", rest)
            if member:
                held += _member_types(member.group(1), member.group(2), owner, funcs)
            else:
                assigned = re.match(r"\s*=\s*(.*)$", rest)
                held += _member_types(None, assigned.group(1) if assigned else None, owner, funcs)
    return own, (() if own else tuple(dict.fromkeys(held)))


def observer_calls(code: str) -> list[re.Match[str]]:
    """The observer_sites row's matches in CODE (text as `strip` returns it): NotificationCenter and KVO
    registrations and `MainActorObservation(` wrapper calls. A `func addObserver(` declaration is not one.

    This is the one observer counter: codebase-health.py and arch-layers.py `--counts` read these matches too.
    """
    return [m for m in OBSERVER.finditer(code) if not OBSERVER_DECL.search(code[max(0, m.start() - 40):m.start()])]


def _key_shaped(code: str, m: re.Match, ann: str | None, types: tuple[str, ...]) -> bool:
    """Whether a static matched by STATIC (M) has an association key's shape: an annotation and initializer
    that name only KEY_TYPES, or no annotation and an integer or Boolean literal (`static var key = 0`)."""
    if ann:
        return bool(types) and all(t in KEY_TYPES for t in types)
    if types:
        return all(t in KEY_TYPES for t in types)
    return m.group(5) is not None and bool(re.fullmatch(r"\s*(?:-?\d+|true|false)\s*", _statement(code, m.start(5) + 1)))


def analyze(path: str, raw: str) -> FileFacts:
    """The per-file facts of PATH with content RAW."""
    code = strip(raw)
    braces = Braces(code)
    starts = [0] + [m.end() for m in re.finditer(r"\n", code)]
    raw_lines = raw.split("\n")
    code_lines = code.split("\n")
    entries, owners = _owners(code, braces)
    funcs = _funcs(code, braces, owners)
    package = package_of(path)
    decls = _decls(code, braces, entries, funcs)
    for d in decls:
        d.path, d.package = path, package
    sites: list[Site] = []

    def site(row: str, pos: int, keys: tuple[str, ...] = ()) -> None:
        line = _line_of(code, pos, starts)
        sites.append(Site(row, path, line, raw_lines[line - 1].strip() if line - 1 < len(raw_lines) else "", keys))

    statics: list[Static] = []
    assoc_names = set(ASSOC_USE.findall(code))
    for m in STATIC.finditer(code):
        mods, keyword, name, ann, assign = m.groups()
        scopes = braces.enclosing(m.start())
        if re.search(r"\bstatic\b", mods or ""):
            if not scopes or scopes[0] not in owners:
                continue
            kind, owner = owners[scopes[0]]
            if kind == "protocol":
                continue
        elif scopes:
            continue  # a local or an instance property
        else:
            owner = None  # a file-scope global: the same debt as a static
        line = _line_of(code, m.start(2), starts)  # the `let`/`var` line, not an attribute line above it
        if assign is None:
            # `static var x: T?` is stored (nil); without `=` anything else is computed or a requirement
            # (a `{` after the annotation, on its line or the next).
            eol = code.find("\n", m.end())
            after = code[m.end():len(code) if eol < 0 else eol].strip()
            nxt = code_lines[line].strip() if line < len(code_lines) else ""
            if keyword != "var" or not ann or after.startswith("{") or (not after and nxt.startswith("{")):
                continue
        raw_line = raw_lines[line - 1] if line - 1 < len(raw_lines) else ""
        head_attrs = raw_line + (raw_lines[line - 2] if line >= 2 else "")
        if "@TaskLocal" in head_attrs:
            continue
        bare = name.strip("`")
        annotated = _type_name(ann) if ann else None
        built = _initializer_types(code, braces, m.start(5), owner, funcs) if assign is not None else []
        types = tuple(dict.fromkeys(t for t in ([annotated] if annotated else []) + built if t))
        if bare in assoc_names and _key_shaped(code, m, ann, types):
            continue  # an association key of this file: only its address is used
        container = annotated in CONTAINERS or bool(built and built[0] in CONTAINERS)
        statics.append(Static(line, raw_line.strip(), keyword, types, container, bare, owner or ""))

    for m in ASSUME.finditer(code):
        site("assume_isolated_total", m.start())
        scopes = braces.enclosing(m.start())
        heads = [braces.head(p) for p in scopes]
        in_deinit = any(DEINIT.search(h) for h in heads)
        in_nc_main = any(NC_MAIN.search(h) for h in heads)
        line = _line_of(code, m.start(), starts)
        adapter = (not in_deinit and not in_nc_main and _in_adapter_type(code, braces, owners, scopes)
                   and _is_proved(raw_lines, line - 1))
        if not adapter:
            site("assume_isolated_outside_adapters", m.start(), (_scope_key(path, braces, owners, scopes),))

    for m in observer_calls(code):
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
        site("app_broadcast_names", p, (f"literal:{literal}",) if literal else ())
    for brace, _, name, between in entries:
        conformance = MESSAGE_CONFORMANCE.search(between)
        if conformance:
            site("app_broadcast_names", brace - len(between) + conformance.start(), (f"message:{name}",))

    lines = raw.count("\n")
    return FileFacts(path, package, decls, statics, sites, lines)


# ---------------------------------------------------------------------------------------------------
# Type table


class TypeTable:
    """stateful(name, path) over every declaration of NAME at one revision, as seen from the file PATH.

    Scoped lookup (Swift resolves the innermost declaration): a reference from PATH resolves to PATH's own
    declarations of the name, else those of PATH's package, else every declaration (PATH None: every one).
    A name is stateful when one resolved declaration is on its own (an actor, a class with a stored var or
    a lock/cache field, a struct/enum with a lock/cache field), or through any number of links: its
    superclass, the type of a stored property (Decl.held), a `func:` entry's return type, a typealias's
    target, each resolved from the declaration's own file. Each query is a complete search of the link
    graph (no partial answer is cached), so the answer does not depend on query order or on cycles.
    DECLS(name) returns every declaration of a name: the full count passes an index of every file, the
    delta count TypeLookup.
    """

    def __init__(self, decls_for) -> None:
        self._decls_for = decls_for
        self._memo: dict[tuple[str, str | None], bool] = {}

    def stateful(self, name: str | None, path: str | None = None) -> bool:
        if not name:
            return False
        key = (name, path)
        if key not in self._memo:
            self._memo[key] = self._search(name, path)
        return self._memo[key]

    def stateful_any(self, names, path: str | None = None) -> bool:
        return any(self.stateful(n, path) for n in names)

    def resolve(self, name: str, path: str | None) -> list[Decl]:
        decls = self._decls_for(name)
        if path is None:
            return decls
        mine = [d for d in decls if d.path == path]
        if mine:
            return mine
        package = package_of(path)
        return [d for d in decls if d.package == package] or decls

    def _search(self, root: str, path: str | None) -> bool:
        seen: set[tuple[str, str | None]] = set()
        stack = [(root, path)]
        while stack:
            name, where = stack.pop()
            if (name, where) in seen:
                continue
            seen.add((name, where))
            known = self._memo.get((name, where))
            if known is not None:
                if known:
                    return True
                continue  # a finished search found nothing stateful from here
            if name in SYS_STATEFUL:
                return True
            if not lookup_name(name):
                continue
            for decl in self.resolve(name, where):
                if decl.own_state:
                    return True
                stack.extend((link, decl.path or None) for link in decl.links())
        # Nothing reachable from ROOT is stateful, so nothing reachable from any node it visited is either.
        for node in seen:
            self._memo[node] = False
        return False


def package_probe(package: str) -> str:
    """A path in PACKAGE that declares nothing: TypeTable resolves it to the package's declarations."""
    return f"{SOURCES}/{package}/"


def repo_type_name(name: str | None) -> bool:
    """True when NAME could be a repo type (worth a lookup)."""
    return bool(name) and name[:1].isupper() and name not in SYS_STATEFUL and name not in VALUE_NAMES \
        and name not in CONTAINERS and not SYSTEM_PREFIX.match(name)


def lookup_name(name: str | None) -> bool:
    """True when NAME has declarations worth a lookup: a possible repo type or a `func:` result link."""
    return bool(name) and (name.startswith(FUNC) or repo_type_name(name))


def static_site(row: str, path: str, static: Static) -> Site:
    """The site of a counted static: it keeps its identity through a rename (by its type) or a retype (by
    its owner and name).

    The name key is owner-qualified: `name:Store.shared` for a static of `Store` (or of an `extension
    Store`), `name:<path>:cache` for a file-scope global. A bare name would make every `shared` the partner
    of every other `shared`, so removing `Store.shared = Store()` and adding `Hub.shared = Cache()` would
    read as a retype instead of a swap.
    """
    ident = f"{static.owner}.{static.name}" if static.owner else f"{path}:{static.name}"
    keys = (f"name:{ident}",) + ((f"type:{static.types[0]}",) if static.types else ())
    return Site(row, path, static.line, static.text, keys)


def classify(static: Static, path: str, table: TypeTable) -> str | None:
    """The row a static or global at PATH counts in, or None (no file is exempt; PATH scopes the type lookup)."""
    if static.container:
        return "global_mutable_statics"
    if table.stateful_any(static.types, path):
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
# The `type` that `swift package dump-package` writes for each kind, so a reader of the dump (arch-layers.py)
# keeps exactly the MAPPED_KINDS targets this reader keeps.
DUMP_TYPES = {"target": "regular", "executableTarget": "executable", "binaryTarget": "binary",
              "testTarget": "test", "systemLibrary": "system", "plugin": "plugin", "macro": "macro"}
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
        out = [Site("layer_hard", MANIFEST, 0, f"{a} ({la}) -> {b} ({lb})", (f"edge:{a}->{b}",))
               for a, la, b, lb in self.hard]
        out += [Site("layer_soft", MANIFEST, 0, f"{a} ({la}) -> {b} ({lb})", (f"edge:{a}->{b}",))
                for a, la, b, lb in self.soft]
        out += [Site("layer_upward", MANIFEST, 0, f"{a} ({la}) -> {b} ({lb})", (f"edge:{a}->{b}",))
                for a, la, b, lb in self.upward]
        out += [Site("layer_unplaced", LAYERS_JSON, 0, name, (f"target:{name}",)) for name in self.unplaced]
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

    def read(self, items: list[tuple[str, str]], by_id: bool = False) -> dict[tuple[str, str], str | None]:
        """{(rev, path): text or None} through one `git cat-file --batch` (BY_ID: REV is an object id)."""
        if not items:
            return {}
        data = "".join(f"{rev}\n" if by_id else f"{rev}:{path}\n" for rev, path in items).encode()
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

    def read_blobs(self, items: list[tuple[str, str]]) -> dict[tuple[str, str], str | None]:
        """{(blob, path): text} for ITEMS through one `git cat-file --batch` (by object id)."""
        texts = self.read([(blob, "") for blob, _ in items], by_id=True)
        return {item: texts[(item[0], "")] for item in items}

    def changed(self, base: str, head: str) -> tuple[list[tuple[str, str]], dict[tuple[str, str], str | None]]:
        """((status, path) of every file BASE..HEAD changes (renames as delete + add), {(rev, path): blob id or
        None (absent)} at both ends)."""
        out = self.run("diff", "--raw", "--no-renames", "--no-abbrev", "-z", base, head, "--")
        parts = [p for p in out.split("\0") if p]
        files: list[tuple[str, str]] = []
        blobs: dict[tuple[str, str], str | None] = {}
        for i in range(0, len(parts) - 1, 2):
            meta, path = parts[i].split(), parts[i + 1]
            old, new, status = meta[2], meta[3], meta[4]
            files.append((status, path))
            blobs[(base, path)] = None if set(old) == {"0"} else old
            blobs[(head, path)] = None if set(new) == {"0"} else new
        return files, blobs

    def swift_blobs(self, rev: str) -> dict[str, str]:
        """{path: blob id} of the Swift files under Sources at REV."""
        out = self.run("ls-tree", "-r", "-z", rev, "--", SOURCES)
        blobs: dict[str, str] = {}
        for entry in out.split("\0"):
            meta, _, path = entry.partition("\t")
            fields = meta.split()
            if path.endswith(".swift") and len(fields) == 3 and fields[1] == "blob":
                blobs[path] = fields[2]
        return blobs

    def swift_files(self, rev: str) -> list[str]:
        return sorted(self.swift_blobs(rev))

    def common_dir(self) -> Path | None:
        """The repository's git directory shared by its worktrees (where the facts cache lives)."""
        dot = self.repo / ".git"
        try:
            if dot.is_dir():
                return dot
            if dot.is_file():
                gitdir = Path(dot.read_text().split("gitdir:", 1)[1].strip())
                gitdir = gitdir if gitdir.is_absolute() else (self.repo / gitdir)
                common = gitdir / "commondir"
                if common.is_file():
                    rel = Path(common.read_text().strip())
                    return (rel if rel.is_absolute() else gitdir / rel).resolve()
                return gitdir
        except (OSError, IndexError):
            pass
        out = self.run("rev-parse", "--git-common-dir", check=False).strip()
        return (self.repo / out).resolve() if out else None

    def worktree(self) -> Path | None:
        r = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "--is-inside-work-tree", "--show-toplevel"],
                           capture_output=True, text=True)
        lines = r.stdout.split()
        if r.returncode != 0 or not lines or lines[0] != "true":
            return None
        return Path(lines[1])


def is_source(path: str) -> bool:
    return path.startswith(SOURCES + "/") and path.endswith(".swift")


def is_counted(path: str) -> bool:
    """True when a change to PATH can change a count: a Swift source or one of COUNTED_PATHS."""
    return is_source(path) or path in COUNTED_PATHS


# ---------------------------------------------------------------------------------------------------
# Per-file facts cache

# The facts of a file depend only on its path, its content and this file: one cache per version of this file.
FINGERPRINT = hashlib.sha1(Path(__file__).read_bytes() + str(METHOD_VERSION).encode()).hexdigest()[:16]
CACHE_DIR = "cmux-arch-counts"
CACHE_KEEP_DAYS = 7  # another worktree may run an older copy of this file; its cache is rebuilt when needed


def _facts_json(f: FileFacts) -> str:
    return json.dumps([f.lines, [[d.name, d.kind, d.own_state, d.superclass, list(d.held)] for d in f.decls],
                       [[s.line, s.text, s.keyword, list(s.types), s.container, s.name, s.owner] for s in f.statics],
                       [[s.row, s.line, s.text, list(s.keys)] for s in f.sites]], separators=(",", ":"))


def _facts_from_json(path: str, text: str) -> FileFacts:
    lines, decls, statics, sites = json.loads(text)
    package = package_of(path)
    return FileFacts(path, package,
                     [Decl(n, k, own, sup, tuple(held), path, package) for n, k, own, sup, held in decls],
                     [Static(line, txt, kw, tuple(types), cont, name, owner)
                      for line, txt, kw, types, cont, name, owner in statics],
                     [Site(row, path, line, txt, tuple(keys)) for row, line, txt, keys in sites], lines)


class FactsCache:
    """analyze() results by (blob id, path), kept in the repository's git directory across runs.

    A file is analyzed once per content (per version of this script), so a push that moves 80 files, or a
    retried push, reads the facts of every unchanged declaring file from here. Any sqlite error turns the
    cache off for the run (the counts are the same, only slower): it never fails a count.
    """

    def __init__(self, git: Git, enabled: bool = True) -> None:
        self.git = git
        self.enabled = enabled
        self._db: sqlite3.Connection | None = None
        self._opened = False
        self._new: dict[str, str] = {}
        self.analyzed = 0
        self.cached = 0

    def _connect(self) -> sqlite3.Connection | None:
        if self._opened:
            return self._db
        self._opened = True
        if not self.enabled:
            return None
        try:
            common = self.git.common_dir()
            if common is None:
                return None
            folder = common / CACHE_DIR
            folder.mkdir(exist_ok=True)
            path = folder / f"facts-{FINGERPRINT}.sqlite"
            fresh = not path.exists()
            self._db = sqlite3.connect(str(path), timeout=1.0)
            self._db.execute("CREATE TABLE IF NOT EXISTS facts (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            if fresh:
                horizon = datetime.datetime.now().timestamp() - CACHE_KEEP_DAYS * 86400
                for old in folder.glob("facts-*.sqlite"):
                    if old != path and old.stat().st_mtime < horizon:
                        old.unlink()
        except (sqlite3.Error, OSError):
            self._db = None
        return self._db

    def get(self, items: list[tuple[str, str]]) -> dict[tuple[str, str], FileFacts]:
        """{(blob, path): facts} for the ITEMS the cache has."""
        db = self._connect()
        if db is None or not items:
            return {}
        keys = {f"{blob}:{path}": (blob, path) for blob, path in items}
        out: dict[tuple[str, str], FileFacts] = {}
        try:
            names = list(keys)
            for i in range(0, len(names), 500):
                chunk = names[i:i + 500]
                rows = db.execute(f"SELECT key, value FROM facts WHERE key IN ({','.join('?' * len(chunk))})", chunk)
                for key, value in rows:
                    blob, path = keys[key]
                    out[(blob, path)] = _facts_from_json(path, value)
        except (sqlite3.Error, ValueError, TypeError):
            self.enabled, self._db = False, None
            return {}
        self.cached += len(out)
        return out

    def put(self, blob: str, facts: FileFacts) -> None:
        if self.enabled:
            self._new[f"{blob}:{facts.path}"] = _facts_json(facts)

    def flush(self) -> None:
        """Write the facts analyzed in this run (one transaction; skipped when another run holds the lock)."""
        db = self._connect() if self._new else self._db
        if db is None:
            return
        try:
            if self._new:
                with db:
                    db.executemany("INSERT OR IGNORE INTO facts (key, value) VALUES (?, ?)", self._new.items())
                self._new.clear()
        except sqlite3.Error:
            pass
        finally:
            db.close()
            self._db = None
            self._opened = False

    def facts(self, items: list[tuple[str, str]], read) -> dict[tuple[str, str], FileFacts]:
        """{(blob, path): facts} for ITEMS: from the cache, else analyze(path, text) with READ(missing items)
        returning {(blob, path): text or None}."""
        found = self.get(items)
        missing = [item for item in dict.fromkeys(items) if item not in found]
        if missing:
            texts = read(missing)
            for item in missing:
                text = texts.get(item)
                if text is None:
                    continue
                facts = analyze(item[1], text)
                self.analyzed += 1
                self.put(item[0], facts)
                found[item] = facts
        return found


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
            counts.add_site(static_site(row, facts.path, st), facts.package)
    if facts.package == APP_PACKAGE:
        counts.rows["app_lines"][APP_PACKAGE] += facts.lines


def count_layers(counts: Counts, lay: Layers) -> None:
    for row, counter in lay.per_package().items():
        counts.rows[row].update(counter)
    for s in lay.sites():
        counts.sites[s.row].append(s)


def count_texts(texts: dict[str, str], manifest_raw: str | None, layers_raw: str | None) -> tuple[Counts, Layers]:
    """(counts, layers) of TEXTS ({path: Swift text}; paths outside Sources are ignored) and the manifest.

    The full count reads git objects; arch-layers.py --counts and codebase-health.py pass working-tree
    texts, so every report counts with the same method.
    """
    facts = [analyze(p, t) for p, t in sorted(texts.items()) if is_source(p)]
    return count_file_facts(facts, manifest_raw, layers_raw)


def count_file_facts(facts: list[FileFacts], manifest_raw: str | None, layers_raw: str | None) -> tuple[Counts, Layers]:
    """(counts, layers) of every file's FACTS and the manifest (count_texts and full_count)."""
    index: dict[str, list[Decl]] = collections.defaultdict(list)
    for f in facts:
        for d in f.decls:
            index[d.name].append(d)
    table = TypeTable(lambda name: index.get(name, []))
    counts = Counts.empty()
    for f in facts:
        count_facts(counts, f, table)
    lay = layers(manifest_raw, layers_raw)
    count_layers(counts, lay)
    return counts, lay


def full_count(repo: Path, rev: str = "HEAD", cache: bool = True) -> tuple[str, Counts, Layers]:
    """(sha, counts, layers) of every file at REV (facts of contents seen before come from FactsCache)."""
    git = Git(repo)
    sha = git.rev(rev)
    blobs = git.swift_blobs(sha)
    store = FactsCache(git, cache)
    try:
        items = [(blobs[p], p) for p in sorted(blobs)]
        found = store.facts(items, git.read_blobs)
        meta = git.read([(sha, p) for p in COUNT_INPUTS])
        facts = [found.get(item) or analyze(item[1], "") for item in items]
        counts, lay = count_file_facts(facts, meta[(sha, MANIFEST)], meta[(sha, LAYERS_JSON)])
    finally:
        store.flush()
    return sha, counts, lay


def _alternation(names) -> str:
    return "|".join(sorted(re.escape(n) for n in names))


# Every line that can declare a type or a `func:` entry (a superset: the file's parse decides), as one
# `git grep -o`: the type lookup's index of name -> declaring files, so a link chain of any depth costs one grep.
# A static/class func has its modifier on the func line; a file-scope func's line is not indented (_funcs).
# `class func make` is a func (TYPE_DECL's lookahead): the type alternative skips it so the func one matches.
DECL_INDEX = (r"\b(?:class|actor|struct|enum|protocol|typealias)[ \t]+"
              r"(?!(?:func|var|let|subscript|override|final|static|private|fileprivate|public|internal|package|open|"
              r"nonisolated|required|convenience|init|deinit)\b)[A-Za-z_]\w*|"
              r"\b(?:static|class)\b[^\n]*?\bfunc[ \t]+[A-Za-z_]\w*|^(?![ \t])[^\n]*?\bfunc[ \t]+[A-Za-z_]\w*")
_INDEX_NAME = re.compile(r"(?:\b(class|actor|struct|enum|protocol|typealias)|\bfunc)[ \t]+([A-Za-z_]\w*)$")


def mention_pattern(names: set[str]) -> str:
    """PCRE for a line that can make a static or a stored property name one of NAMES (a superset: the file's
    parse decides). A type by its name; a `func:` entry only as a bare call that starts an expression (after
    `=`, `;`, `{`, `return`, `in` or at a line start, past `try`/`await`), the one place _expr_types resolves
    a lowercase call, so `x.make(` and `func make(` lines do not match."""
    types = {n for n in names if not n.startswith(FUNC)}
    funcs = {n[len(FUNC):] for n in names if n.startswith(FUNC)}
    parts = []
    if types:
        parts.append(rf"\b(?:{_alternation(types)})\b")
    if funcs:
        parts.append(rf"(?:^|[=;{{]|\breturn\b|\bin\b)\s*(?:(?:try[!?]?|await)\s+)*(?:{_alternation(funcs)})"
                     r"\s*(?:<[^>\n]*>)?\s*\(")
    return "|".join(parts)


class TypeLookup:
    """Declarations by name at BASE and HEAD without reading every file.

    Files that equal the worktree at both ends are found with `git grep` in the worktree (shared by both
    ends: their content is HEAD's blob); their facts come from CACHE by blob id, else are analyzed once from
    disk. OVERLAY files (changed by the range or dirty in the worktree) are analyzed from each end's git
    content.
    """

    def __init__(self, git: Git, worktree: Path | None, revs: tuple[str, str], cache: FactsCache | None = None) -> None:
        self.git = git
        self.worktree = worktree
        self.revs = revs
        self.cache = cache or FactsCache(git, enabled=False)
        self._head_blobs: dict[str, str] | None = None
        self.overlay: dict[str, dict[str, FileFacts | None]] = {r: {} for r in revs}
        self.overlay_index: dict[str, dict[str, list[Decl]]] = {r: {} for r in revs}
        self.searched: set[str] = set()
        self._grep_cache: dict[tuple[str, str], object] = {}
        self._index: object = None  # {name: declaring paths} (or the Future that computes it)
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

    def prefetch_index(self) -> None:
        """Start the declaration index grep now (it runs while the dirty files are read)."""
        if self._index is None:
            if self._pool is None:
                self._pool = concurrent.futures.ThreadPoolExecutor(max_workers=2)
            self._index = self._pool.submit(self._grep_index)

    def decl_index(self) -> dict[str, set[str]]:
        """{name or `func:` name: the tracked Swift files with a line that may declare it} (worktree, else HEAD)."""
        if self._index is None:
            self._index = self._grep_index()
        if isinstance(self._index, concurrent.futures.Future):
            self._index = self._index.result()
        return self._index

    def _grep_index(self) -> dict[str, set[str]]:
        args = ["grep", "-o", "-z", "-I", "-P", "-e", DECL_INDEX]
        if self.worktree is None:
            args.append(self.revs[1])
        args += ["--", f"{SOURCES}/*.swift"]
        r = subprocess.run(["git", "-C", str(self.repo_root()), *args], capture_output=True)
        if r.returncode not in (0, 1):
            raise RuntimeError(f"git grep: {r.stderr.decode(errors='replace').strip()}")
        index: dict[str, set[str]] = collections.defaultdict(set)
        prefix = f"{self.revs[1]}:" if self.worktree is None else ""
        for line in r.stdout.decode(errors="replace").split("\n"):
            path, sep, text = line.partition("\0")
            if not sep:
                continue
            m = _INDEX_NAME.search(text)
            if m:
                index[m.group(2) if m.group(1) else FUNC + m.group(2)].add(path[len(prefix):] if prefix and
                                                                            path.startswith(prefix) else path)
        return index

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
        if todo:
            if self._head_blobs is None:
                self._head_blobs = self.git.swift_blobs(self.revs[1])  # one ls-tree: the cache keys
            items = [(self._head_blobs[p], p) for p in todo if p in self._head_blobs]

            def read(missing: list[tuple[str, str]]) -> dict[tuple[str, str], str | None]:
                if self.worktree is None:
                    return self.git.read_blobs(missing)
                texts: dict[tuple[str, str], str | None] = {}
                for item in missing:
                    try:
                        texts[item] = (self.worktree / item[1]).read_text(errors="replace")
                    except OSError:
                        texts[item] = None
                return texts

            for (_, path), facts in self.cache.facts(items, read).items():
                self.shared_files[path] = facts
        for p in paths:
            if p in self.shared_files:
                out.append(self.shared_files[p])
        return out

    def ensure(self, names: set[str]) -> None:
        """Read the declarations of NAMES not looked up yet, in one batch.

        The declaring files come from decl_index() (one `git grep` for the whole run). Links are not
        followed here: TypeTable asks decls() for each name its search reaches, and a search stops at the
        first declaration with state of its own, so only the files a search really needs are read.
        """
        todo = {n for n in names if lookup_name(n)} - self.searched
        if not todo:
            return
        self.searched |= todo
        index = self.decl_index()
        for f in self.read_shared(sorted({p for n in todo for p in index.get(n, ())})):
            for d in f.decls:
                if d.name in todo and d not in self.shared[d.name]:
                    self.shared[d.name].append(d)

    def decls(self, rev: str, name: str) -> list[Decl]:
        if lookup_name(name) and name not in self.searched:
            self.ensure({name})
        return self.shared.get(name, []) + self.overlay_index[rev].get(name, [])

    def table(self, rev: str) -> TypeTable:
        return TypeTable(lambda name: self.decls(rev, name))


@dataclasses.dataclass
class Delta:
    """What BASE..HEAD changes: per-row counts over the files it touches at both ends."""

    base: str
    head: str
    files: list[tuple[str, str]]
    before: Counts
    after: Counts
    analyzed: int = 0  # files analyze() read in this count
    cached: int = 0  # files whose facts came from FactsCache

    def total(self, row: str) -> int:
        return sum(self.after.rows[row].values()) - sum(self.before.rows[row].values())

    def by_package(self, row: str) -> dict[str, int]:
        keys = set(self.after.rows[row]) | set(self.before.rows[row])
        out = {k: self.after.rows[row][k] - self.before.rows[row][k] for k in sorted(keys)}
        return {k: v for k, v in out.items() if v}

    def unpartnered(self, row: str) -> list[Site]:
        """HEAD sites of ROW that no BASE site of the range accounts for. A partner shares a key (the same
        global by name or by type, the same broadcast literal, the same edge) or, for a site without keys,
        its text. A move, a rename or a retyped global has a partner; a site that replaces a removed one of
        another identity (a swap) has none: it is debt the push adds, whatever the total does."""
        def ids(s: Site) -> set[str]:
            return set(s.keys) or {"text:" + s.text}

        old = [ids(s) for s in self.before.sites[row]]
        used = [False] * len(old)
        out = []
        for s in self.after.sites[row]:
            mine = ids(s)
            match = next((i for i, o in enumerate(old) if not used[i] and o == mine), None)
            if match is None:
                match = next((i for i, o in enumerate(old) if not used[i] and o & mine), None)
            if match is None:
                out.append(s)
            else:
                used[match] = True
        return out

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
            out[d.name][(d.kind, d.own_state, d.superclass, d.held, d.path)] += 1
    return out


def _may_flip(a: collections.Counter | None, b: collections.Counter | None) -> bool:
    """Whether a name's changed-file declarations A (base) and B (head) can change its statefulness.

    Judged per file, because a lookup resolves to one file's, one package's or every declaration
    (TypeTable): a file that gains or loses a declaration of the name can change a scope; otherwise a file
    whose declarations have state of their own at both ends, or at neither end with the same links,
    changes no scope's answer.
    """
    a, b = a or collections.Counter(), b or collections.Counter()
    if a == b:
        return False
    sides = []
    for side in (a, b):
        files: dict[str, list[tuple]] = collections.defaultdict(list)
        for sig in side:
            files[sig[4]].append(sig)
        sides.append(files)
    if set(sides[0]) != set(sides[1]):
        return True
    for path in sides[0]:
        own = [any(sig[1] for sig in side[path]) for side in sides]
        if own[0] and own[1]:
            continue
        links = [{x for sig in side[path] for x in ((sig[2],) if sig[2] else ()) + sig[3]} for side in sides]
        if own[0] != own[1] or links[0] != links[1]:
            return True
    return False


def _static_key(f: FileFacts, st: Static) -> tuple:
    return (f.package, st.types, st.keyword, st.container)


def delta_count(repo: Path, base: str, head: str, use_worktree: bool = True, cache: bool = True) -> Delta:
    """Counts of BASE and HEAD over the files BASE..HEAD changes, so after - before is the push's delta.

    Equal to two full counts subtracted. Statics that the range leaves in place or moves within a
    package (same types and keyword) cancel without a type lookup; only the others, and the types whose
    declarations the range changes, are looked up. USE_WORKTREE False reads every lookup from HEAD's git
    objects (an audit of old commits: the worktree would differ from them in most files). CACHE False
    analyzes every file it reads instead of reading facts seen before from FactsCache.
    """
    git = Git(repo)
    # Started first: it stats every source file, and only a type lookup waits for it.
    dirty_proc = subprocess.Popen(["git", "-C", str(repo), "diff", "--name-only", "-z", head, "--", SOURCES],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) if use_worktree else None
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
        if not use_worktree:
            worktree = None
        store = FactsCache(git, cache)
        try:
            delta = _delta(git, base, head, worktree, dirty_proc, store)
        finally:
            store.flush()
        delta.analyzed, delta.cached = store.analyzed, store.cached
        return delta
    finally:
        if dirty_proc is not None:
            if dirty_proc.poll() is None:
                dirty_proc.kill()
            dirty_proc.wait()
            if dirty_proc.stdout is not None:
                dirty_proc.stdout.close()  # communicate() never ran when no type lookup was needed


def _delta(git: Git, base: str, head: str, worktree: Path | None, dirty_proc: subprocess.Popen | None,
           store: FactsCache) -> Delta:
    files, blobs = git.changed(base, head)
    changed = sorted({p for _, p in files if is_source(p)})
    before, after = Counts.empty(), Counts.empty()
    layer_files = [p for p in COUNT_INPUTS if any(p == q for _, q in files)]
    if layer_files:
        texts = git.read([(r, p) for r in (base, head) for p in COUNT_INPUTS])
        count_layers(before, layers(texts[(base, MANIFEST)], texts[(base, LAYERS_JSON)]))
        count_layers(after, layers(texts[(head, MANIFEST)], texts[(head, LAYERS_JSON)]))
    if not changed:
        return Delta(base, head, files, before, after)
    ends = {(r, p): blobs.get((r, p)) for r in (base, head) for p in changed}
    found = store.facts([(b, p) for (_, p), b in ends.items() if b], git.read_blobs)
    facts = {r: {p: (found.get((ends[(r, p)], p)) if ends[(r, p)] else None) for p in changed} for r in (base, head)}

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
    wanted = {t for r in (base, head) for k in net[r] for t in k[1]}
    if not any(lookup_name(n) for n in wanted | redeclared):
        table = TypeTable(lambda name: [])
        tables = {base: table, head: table}
        lookup = None
    else:
        dirty_out = b""
        if dirty_proc is not None and worktree is not None:
            dirty_out, _ = dirty_proc.communicate()
            if dirty_proc.returncode != 0:
                worktree, dirty_out = None, b""
        lookup = TypeLookup(git, worktree, (base, head), store)
        # The first lookup round and the flip lookup run while the dirty files are read.
        lookup.prefetch_index()
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
    # and so does every type that holds it, link by link (its superclass, a stored property, a func result).
    def flipped(names: set[str]) -> set[str]:
        """The names whose answer differs between the ends in any scope a reference can see them from: every
        declaration's file and package, and the whole sources (conservative: a flip only adds a recount)."""
        out = set()
        for n in names:
            decls = [d for r in (base, head) for d in (lookup.decls(r, n) if lookup is not None else [])]
            scopes = {None} | {d.path for d in decls} | {package_probe(d.package) for d in decls}
            if any(tables[base].stateful(n, where) != tables[head].stateful(n, where) for where in scopes):
                out.add(n)
        return out

    flips = flipped(redeclared)
    frontier = set(flips)
    users: set[str] = set()  # the files that mention a flipped name: the union of every round's grep
    while lookup is not None and frontier:
        names = {n for n in frontier if lookup_name(n)}
        if not names:
            break
        found = lookup.grep_files(mention_pattern(names), head)
        users.update(found)
        mention = lookup.read_shared(found)
        decls = [d for f in mention for d in f.decls]
        decls += [d for r in (base, head) for f in lookup.overlay[r].values() if f for d in f.decls]
        linkers = {d.name for d in decls if names & set(d.links())} - flips
        lookup.ensure(linkers)
        frontier = flipped(linkers)
        flips |= frontier

    for r, counts in ((base, before), (head, after)):
        left = collections.Counter(net[r])
        for f in facts[r].values():
            for st in (f.statics if f else []):
                key = _static_key(f, st)
                if not flips.intersection(st.types):
                    if left[key] <= 0:
                        continue  # the other end has the same static: it cancels
                    left[key] -= 1
                row = classify(st, f.path, tables[r])
                if row:
                    counts.add_site(static_site(row, f.path, st), f.package)

    if lookup is not None and flips:
        overlay_paths = set(lookup.overlay[head])
        unchanged = lookup.read_shared(sorted(p for p in users if p not in overlay_paths))
        unchanged += [f for p, f in lookup.overlay[head].items() if p not in facts[head] and f]
        for f in unchanged:
            for r, counts in ((base, before), (head, after)):
                for st in f.statics:
                    if flips.intersection(st.types):
                        row = classify(st, f.path, tables[r])
                        if row:
                            counts.add_site(static_site(row, f.path, st), f.package)
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
        "_doc": ("Architecture counts the pre-push ratchet holds (scripts/cmux-next/guardrails.py runs "
                 "scripts/cmux-next/arch-ratchet.py; the method is scripts/cmux-next/arch_counts.py, whose docstring "
                 "defines every row). A push may not raise a ratcheted row's total, in the code or in this file's "
                 "totals, nor swap a counted global, broadcast or layer edge for another; when one drops, rerun `scripts/cmux-next/arch-ratchet.py --update` (the only writer). The "
                 "one escape is a dated exception: add {\"date\": \"YYYY-MM-DD\", \"row\": \"<row>\", \"allow\": <n>, "
                 "\"why\": \"...\"} to exceptions; the push that adds it may raise that row by n, and the next "
                 "--update folds it into the totals and marks it with applied_sha (an applied entry is never edited "
                 "or removed). --update refuses a rise that no pending exception covers. Never CI."),
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
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n")
    return path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=None)
    parser.add_argument("--rev", default="HEAD")
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

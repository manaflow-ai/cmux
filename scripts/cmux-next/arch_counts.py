#!/usr/bin/env python3
"""Architecture counts for cmux-next, method v6: the numbers plans/cmux-next/arch-ratchet.json records.

The rules are the goal (repo CLAUDE.md "Refactor architecture", "Modern Swift concurrency";
plans/cmux-next/perf-lead.md "Architecture targets"); these counts are proxies, and a pattern renamed
to dodge a count is still counted where the method can see it. Every row is counted per package
(the Swift module: the directory under a package's Sources) and in total.

Scope: the app's package, Packages/macOS/CmuxNext, and the transitive closure of its local
`.package(path:)` dependencies (Packages/Shared/*, Packages/macOS/CmuxUpdater, vendor/..., each path
resolved against the directory of the manifest that names it; a `.package(url:)` dependency is not
read). The closure is read statically from git objects at the counted revision (never `swift package
dump-package`: 4-6 s), once per revision (read_paths, kept in FactsCache by commit). Counted: tracked
Swift under every closure package's Sources, read from git objects, with comments and string literals
blanked (same length, so offsets and line numbers stay); a file's package is its Swift module, the
directory after `Sources/` (package_of), and a module directory two closure packages share is an error
(AmbiguousModule), never one merged package. Package rows come from a static parse of every closure
package's Package.swift: an edge to a local package's `.product(name:package:)` is an edge to the
targets that product exposes, classified by the one layer map like an edge inside a package; a product
of a remote package is no edge. Moving code into a linked local package therefore moves its count, it
does not drop it.

Rows (method v6; a change of any definition bumps METHOD_VERSION, and `arch-ratchet.py --update` then
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
                          NSPanel, NSWorkspace, FileManager, WKProcessPool, WKWebsiteDataStore,
                          DistributedNotificationCenter, NSResponder, NSView, NSViewController,
                          NSWindowController, NSMenu, NSStatusItem, Timer, Process, Thread and FileHandle; and, through any number of links, a repo type
                          whose superclass or stored instance property has a stateful type (a class: its
                          stored `let`s; a struct: its stored `let`s and `var`s). A name declared more
                          than once (two modules) is stateful when any declaration is. Not counted:
                          @TaskLocal statics, and an association key: a static whose address (or
                          pointer value) this file passes as the key of objc_get/setAssociatedObject and
                          whose type is a key type (UInt8, Int, Bool, a raw pointer; or an integer or
                          Boolean literal). The name is never the test, and a key used from another file
                          counts (keep the key private next to its use). No file is exempt (the
                          composition root holds instances, not statics); a top-level `let`/`var` of a
                          main.swift is a module global and counts, the bindings of a top-level
                          `if`/`guard`/`while` condition list there (`guard let a = x,` then `let b = y
                          else`) do not. A file-scope func that a
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
  observer_sites          observer registrations, through wrappers (the "Observer registrations" section
                          gives the rule): a raw `addObserver(`, `.notifications(named:`, `.publisher(for:`,
                          `.messages(of:`, KVO `.observe(\\.keyPath` or `CFNotificationCenterAddObserver(`
                          call (not a `func addObserver(` declaration), or a reference to a wrapper (a
                          function, init or named closure whose parameters, or an init-set stored property,
                          decide what a registration in it observes or its handler; MainActorObservation is
                          one by what its init does, not by its name). A registration that no parameter
                          decides counts once at its own statement, whatever calls it and whatever branch is
                          around it; one a parameter decides counts once per reference to its wrapper, at
                          any depth, and a literal loop multiplies the registrations that use its binding
  blocking_allow_escapes  main-thread blocking allowances (BlockingViolationLog, CmuxNextCompat): every
                          `// blocking-allow:` comment and every `allowBlocking(` call (not a
                          `func allowBlocking(` declaration); ratchets down only (Performance Lead
                          2026-10-24)
  app_lines               physical lines (newlines) of CmuxNextApp Swift; ratchets down only (reward-hacking
                          audit, cmux-ad 2026-10-30: it rose 143,610 -> 164,014 while it was report only)

Every row reads the whole closure: a Shared package's static or observer counts under its module, and its
targets are placed (layer_unplaced) and their edges classified like CmuxNext's.

codebase-health.py imports these patterns, analyze(), count_texts() and layers(), so its report and the ratchet share
one definition of every row (arch-layers.py, PL-arch's, keeps its own grep counts). Both read the same scope: read_paths
at HEAD for the packages, the working tree for the files (count_texts and layers with the closure).

Site identity (Delta.unpartnered, the ratchet's swap rule): a counted global keeps its identity by its owner
and name (static_name: `Store.shared`; `<package>:<name>` for a file-scope global, so a file moved or renamed
within its package keeps its globals) or by its primary type, a broadcast by its literal (or its message
type), an assumeIsolated outside an adapter by the type and function around it, a layer edge by its two
targets. The owner is part of the identity on purpose: a static or an unproved assumeIsolated call moved to
another type (a renamed owner, or a static extracted from a god type into a new Coordinator) is another site,
new debt in that type. A typed global still finds its partner by its type; a typeless static (`static var
hook: ((String) -> Void)?`) and an unproved call have no other key, so their move is a swap: fix the debt in
the move (an injected instance; the call in a seam adapter with its `main-proof:`) or carry a dated exception.

Delta mode (the pre-push hook) reads only the files a range changes, at both ends, and gives the same
numbers as two full counts subtracted (tests/test_arch_ratchet.py checks it). Each end has its own closure
(read_paths: the base's from FactsCache, the head's equal to it when the range changes no Package.swift);
a package in one end's closure only adds every Swift file of its Sources to the files the range changes,
counted at that end and absent at the other. At an end whose layer map does
not parse, the edge rows classify with the newest earlier map that parses (`placing_map`: the value the
edges had before the map broke, never 0), and layer_unplaced counts every target; only when no earlier map
parses are that end's edges unknown and the edge rows not judged (delta 0, a note names them). Statics that keep their
identity at both ends (package, owner and name, types, keyword: left in place, or moved within a package)
cancel without a type lookup; every other changed static gets its own site, so the swap rule and a refusal
see exactly the statics the range changed. For those, and for types whose
declarations the range changes, one worktree `git grep -o` lists every declaration line (DECL_INDEX) and a
type search reads only the declaring files it reaches (the worktree stands in for both ends for every
file that equals them; changed and dirty files are read from git objects). A type whose statefulness the
range flips (a class gains a stored var) re-counts the unchanged files that name it (a `func:` entry only
as a bare call that starts an expression), and then the types that hold it, link by link. Most pushes need
no type grep. observer_sites is counted at both ends in full (a wrapper's change moves the count of files the
range does not touch), over the worktree standing in for both ends outside the changed and dirty files: two
worktree greps (the raw registration lines, the mentions of the wrappers arch-ratchet.json records), one more per
round only for a wrapper name the record lacks, and one `func NAME` grep only for the method wrapper names an
unknown receiver needs; the files' observer facts (raw registrations, init-set properties, per-name references)
come from FactsCache by blob, so a warm push parses only the files it changes.

Every analyzed file's facts are kept by (blob id, path) in `<git common dir>/cmux-arch-counts/` (FactsCache,
one sqlite file per version of this script), so a file is analyzed once per content: a warm 80-file
cross-package move reads no file twice; the first run after this file changes pays the analysis once.

The file is self-contained (standard library only): perf-cron-arch-report.py runs a commit's own copy
under `python3 -I`.

Usage:
  scripts/cmux-next/arch_counts.py [--rev REV] [--json]     full count at REV (default HEAD)
  scripts/cmux-next/arch_counts.py --sites ROW [--rev REV]  the sites of ROW
  scripts/cmux-next/arch_counts.py --delta BASE HEAD [--json]
  scripts/cmux-next/arch_counts.py --read-paths [--rev REV] what a count at REV reads, as one JSON object
                                                            (perf-cron-arch-report.py prefetches it)
The one writer of plans/cmux-next/arch-ratchet.json is `arch-ratchet.py --update`: it refuses a rise that
no dated exception covers, except one that commits already on origin/feat-cmux-next made, which it records
with a generated applied entry naming them (`raised_by`).
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
import posixpath
import re
import sqlite3
import subprocess
import tempfile
import sys
from pathlib import Path
from typing import NamedTuple

# v2: file-scope globals, weak/unowned statics, closure and factory initializers, held struct state, any link
# depth, one main-proof per call, KVO and CFNotificationCenter observers, no composition-root exemption.
# v3: seam adapters per type (an extension or free function is none), association keys by use and shape (not
# by name), declarations after `{`/`;`, DispatchQueue/Task/AsyncStream statics, typed NotificationCenter
# messages and `.messages(of:` observers, file-scope funcs at column 0, site identity keys.
# v4: this definition set (feat-cmux-next after 348ebf06bd8) replaces both earlier v3 sets: upstream's v3
# (ab67f9e73c6: observers by literal call text, `MainActorObservation(` by name) and the arch-ratchet-gate branch's
# v3 (9de6894be2d, never landed: wrappers charged one level, a fixed helper per caller only when its raw call had
# no branch). v4 counts observers as registrations through wrappers of any depth, a fixed one once at its own
# statement (extract, inline and `if` keep the count), a parameter- or init-property-configured one per reference;
# and skips the bindings of a top-level `if`/`guard`/`while` condition list. A broken layer map at an end is judged
# by the newest earlier map that parses. The totals of a v3 record are not comparable with v4.
# v5: the scope is CmuxNext plus the transitive closure of its local `.package(path:)` dependencies (their
# Sources, their targets, and `.product` edges to a local package as layer edges). Every row can rise from v4
# with no code change (the Shared packages' globals, observers and targets are new to the count): the totals of
# a v4 record are not comparable with v5.
# v6: stateful system types add the AppKit responders (NSResponder, NSView, NSViewController, NSWindowController;
# their subclasses through the superclass link), NSMenu, NSStatusItem, Timer, Process, Thread and FileHandle, and
# the blocking_allow_escapes row is new (deep-guardrails review a08985b7dac; lead 2026-10-24). stateful_singletons
# can rise from v5 with no code change.
METHOD_VERSION = 6
# The app's package: the root of the closure (read_paths). Its Sources and Package.swift are the v4 scope; the
# layer gate (arch_rules/layer_gate.py) still judges only this manifest's targets and edges.
PACKAGE_DIR = "Packages/macOS/CmuxNext"
SOURCES = f"{PACKAGE_DIR}/Sources"
MANIFEST = f"{PACKAGE_DIR}/Package.swift"
LAYERS_JSON = "plans/cmux-next/architecture-layers.json"
RATCHET_JSON = "plans/cmux-next/arch-ratchet.json"
# This file in the repo (the row definitions). A literal, not __file__: the installed hook runs a copy.
METHOD_FILE = "scripts/cmux-next/arch_counts.py"
# The count inputs every revision has besides its closure's manifests (ReadPaths.count_inputs adds those): full_count
# reads them at the counted commit; delta_count reads them at each end when its range changes one.
COUNT_INPUTS = (MANIFEST, LAYERS_JSON)
# Every revision-independent path whose change can change a recorded count: COUNT_INPUTS and the row definitions.
# ReadPaths.is_counted (the closure's Swift sources and manifests too) is the one test arch-ratchet.py's
# measured_in_range uses.
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
    Row("blocking_allow_escapes", "main-thread blocking allowances (`// blocking-allow:`, allowBlocking()", True),
    Row("app_lines", "CmuxNextApp Swift lines", True),
)
ROW_IDS = tuple(row.id for row in ROWS)
LAYER_ROWS = ("layer_hard", "layer_soft", "layer_upward", "layer_unplaced")
EDGE_ROWS = ("layer_hard", "layer_soft", "layer_upward")

SYS_STATEFUL = frozenset({
    "UserDefaults", "URLSession", "NotificationCenter", "OperationQueue", "NSWindow", "NSPanel",
    "NSWorkspace", "FileManager", "WKProcessPool", "WKWebsiteDataStore", "DistributedNotificationCenter",
    # Reference objects whose system superclass holds runtime state (deep-guardrails review a08985b7dac): a view,
    # view controller or window controller (a subclass too: a superclass link), a menu, a status item, and running
    # Foundation objects. JSONEncoder/JSONDecoder are left out: configured once and read, they are constants here.
    "NSResponder", "NSView", "NSViewController", "NSWindowController", "NSMenu", "NSStatusItem", "Timer",
    "Process", "Thread", "FileHandle",
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
BLOCKING_ALLOW_COMMENT = re.compile(r"//[ \t]*blocking-allow:")  # matched in the raw text, at a blanked (comment) position
BLOCKING_ALLOW_CALL = re.compile(r"\ballowBlocking\s*\(")
BLOCKING_ALLOW_DECL = re.compile(r"\bfunc\s+$")  # `func allowBlocking(` declares one, it is no site
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


_MODULE_DIR = re.compile(r"(?:^|/)Sources/([^/]+)/")


def package_of(path: str) -> str:
    """The Swift module of PATH: the directory after the first `Sources/` of any closure package
    (`Packages/Shared/CmuxVNC/Sources/CmuxVNC/X.swift` -> `CmuxVNC`; a `Sources/` folder inside a module stays
    in that module), `(top)` for a file directly in a Sources directory. A path with no `Sources/` (arch-layers'
    and codebase-health's keys never lack one) is its first directory."""
    m = _MODULE_DIR.search(path)
    if m:
        return m.group(1)
    if re.search(r"(?:^|/)Sources/[^/]+$", path):
        return "(top)"
    return path.split("/", 1)[0] if "/" in path else "(top)"


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


def _key_shaped(code: str, m: re.Match, ann: str | None, types: tuple[str, ...]) -> bool:
    """Whether a static matched by STATIC (M) has an association key's shape: an annotation and initializer
    that name only KEY_TYPES, or no annotation and an integer or Boolean literal (`static var key = 0`)."""
    if ann:
        return bool(types) and all(t in KEY_TYPES for t in types)
    if types:
        return all(t in KEY_TYPES for t in types)
    return m.group(5) is not None and bool(re.fullmatch(r"\s*(?:-?\d+|true|false)\s*", _statement(code, m.start(5) + 1)))


def _in_condition_list(code_lines: list[str], index: int) -> bool:
    """Whether the `let`/`var` on line INDEX (0-based, blanked code) continues an `if`/`guard`/`while` condition
    list: the lines before it end with `,` back to a line that starts with one of those keywords. Swift allows
    such statements at file scope only in main.swift; there they bind the entry point's locals, not globals."""
    i = index - 1
    while i >= 0 and code_lines[i].rstrip().endswith(","):
        if re.match(r"\s*(?:\}\s*else\s+)?(?:if|guard|while)\b", code_lines[i]):
            return True
        i -= 1
    return False


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
        elif _in_condition_list(code_lines, _line_of(code, m.start(2), starts) - 1):
            continue  # `guard let a = x,\n      let b = y else {`: a binding of main.swift's top-level code
        else:
            owner = None  # a file-scope global (main.swift's too): the same debt as a static
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

    if BLOCKING_ALLOW_COMMENT.search(raw):
        commented = strip(raw, keep_strings=True)  # comments blanked, strings kept: a match there is a comment
        for m in BLOCKING_ALLOW_COMMENT.finditer(raw):
            if commented[m.start()] == " ":
                site("blocking_allow_escapes", m.start())
    for m in BLOCKING_ALLOW_CALL.finditer(code):
        if not BLOCKING_ALLOW_DECL.search(code[max(0, m.start() - 40):m.start()]):
            site("blocking_allow_escapes", m.start())

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
# Observer registrations
#
# observer_sites counts registrations, not the text of one call, and the count does not depend on how the code is
# cut into functions (method v4). A registration is a raw call (RAW_OBSERVER: NotificationCenter `addObserver(`,
# `.notifications(named:`, `.publisher(for:`, `.messages(of:`, KVO `.observe(\`, `CFNotificationCenterAddObserver(`)
# or a reference to a wrapper. A wrapper (MainActorObservation, a helper) is found by what it does, never by its name.
#
# Where a registration counts:
# - Nothing a caller supplies decides it (a fixed name, object, receiver and handler): it counts once, at its own
#   statement, whatever calls the function it stands in and whatever branch, `guard` or closure is around it. So
#   extracting it into a helper, inlining a helper's body into its one caller, or wrapping it in an `if` keeps the
#   count, and so does replacing a raw call by a wrapper call with the same fixed arguments.
# - A parameter decides it: what it observes (its notification name, key path or message type, through the locals the
#   body binds from the parameter: `forName: name`, `(name)`, `Name(rawValue: key)`, `k.name`, `for n in names`) or its
#   handler (a closure argument that calls a parameter of function type). The center, the `object:` filter, the queue
#   and a KVO receiver say where or how it observes, not what: a caller that supplies only those (an injected
#   `services`, a window) does not make a wrapper, or every function that passes a context object on would. It is charged
#   to the innermost such function, which is then a wrapper, and each reference to the wrapper counts the
#   registrations one call of it makes, through any depth of wrappers. A wrapper that nothing references counts its
#   own body once, so a registration never disappears because its callers cannot be resolved.
# - A stored property that an init of the enclosing type sets from the init's parameters decides it the same way
#   (`init(name:) { self.name = name }` and `start() { addObserver(forName: name ...) }`): it is charged to those
#   inits, so each construction of the type counts it.
# A reference is a call (`f(`, `x.f(`, `f { }`, `T(`, `T.init(`, `self.init(`, `let a: T = .init(`) or a use as a value
# (`forEach(f)`, `map(T.init)`, `let g = f`). A loop over a literal (`for n in [.a, .b]`, `[.a, .b].forEach`, or a
# caller's literal passed to the loop's parameter) multiplies the registrations whose observed values or handler use
# its binding; a loop whose binding a registration does not use repeats one registration, which counts once. A method
# resolves by its owner type: an unqualified or `self.` call to the enclosing type's method, `x.f(` to the type x is
# declared with in the file, else only when no other `func` of that name exists in the tree.

# A raw registration call (not a `func addObserver(` declaration).
RAW_OBSERVER = re.compile(r"\baddObserver\s*\(|\.notifications\s*\(\s*named\s*:|\.publisher\s*\(\s*for\s*:|"
                          r"\.messages\s*\(\s*of\s*:|\.observe\s*\(\s*\\|\bCFNotificationCenterAddObserver\s*\(")
# A line that may hold one, for `git grep -P` over raw text (a superset: the file's parse decides).
RAW_OBSERVER_LINE = (r"\baddObserver\s*\(|\.notifications\s*\(|\.publisher\s*\(|\.messages\s*\(|\.observe\s*\(|"
                     r"\bCFNotificationCenterAddObserver\s*\(")
_RAW_OBSERVER_LINE = re.compile(RAW_OBSERVER_LINE)
# Where each raw registration names what it observes: (the argument labels, the positional index) of its
# notification name, key path or message type. `addObserver(forName:` (block), `addObserver(_:selector:name:` and
# `addObserver(_:forKeyPath:` (KVO); `.notifications(named:`, `.publisher(for:`, `.messages(of:for:` (the message
# type); `.observe(\\.keyPath` (its first argument); `CFNotificationCenterAddObserver(center, observer, callback,
# name, ...)` (the fourth).
_OBSERVED_ARGUMENT = {"addObserver": (("forName", "name", "forKeyPath"), None), "notifications": (("named",), None),
                      "publisher": (("for",), None), "messages": (("for",), None), "observe": ((), 0),
                      "CFNotificationCenterAddObserver": ((), 3)}
_FUNC_HEAD = re.compile(r"(?:\bfunc\s+([A-Za-z_]\w*)|(?<![.\w])(init))[?!]?\s*(?:<[^(){}]*>)?\s*\(")
# What cannot follow a function's parameter list before its body `{` (throws, async, -> T and where may).
_NOT_SIGNATURE_TAIL = re.compile(r"\b(?:var|let|func|init|case|class|struct|enum|actor|extension|protocol|subscript|"
                                 r"typealias|import|return|if|guard|for|while|switch|in)\b|[={};]")
# A closure literal bound to a name, `let on = {` or `var on: (Name) -> Void = {`: a helper like a function.
_CLOSURE_BINDING = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::[^=\n]*)?=\s*$")
# A closure's own parameter list before `in`: `[weak self] a, b in`, `(a: T, b: U) -> R in`.
_CLOSURE_SIGNATURE = re.compile(r"\s*(?:\[[^\]]*\]\s*)?(\((?:[^()]|\([^()]*\))*\)|[A-Za-z_][\w \t,]*?)\s*"
                                r"(?:(?:async\s*)?(?:throws\s*)?->\s*[^{}\n]*?)?\s*\bin\b")
_ARG = re.compile(r"^(\w+)\s*:(?!:)\s*(.*)$", re.S)
_PARAM = re.compile(r"^(?:@\w+(?:\([^()]*\))?\s+)*([A-Za-z_]\w*)(?:\s+([A-Za-z_]\w*))?\s*:(.*)$", re.S)
_LEVELS = (("file", re.compile(r"\b(?:private|fileprivate)\b")), ("public", re.compile(r"\b(?:public|open|package)\b")))
_LEVEL_RANK = {"file": 0, "module": 1, "public": 2}
# A word before a name that makes the name a declaration, not a reference.
_DECLARES = re.compile(r"\b(?:func|let|var|case|class|struct|enum|protocol|actor|typealias|extension|import|"
                       r"associatedtype|indirect|macro)\s+$")
# The calls whose closure (or function value) runs once per element of their receiver.
_PER_ELEMENT = re.compile(r"\.\s*(?:forEach|map|compactMap|flatMap)\s*(\(\s*)?$")
_LOOP_HEAD = re.compile(r"for\s+(?:try\s+)?(?:await\s+)?(?:case\s+)?(?:let\s+|var\s+)?(.+?)\s+in\s+(.+?)"
                        r"\s*(?:\bwhere\b.*)?$", re.S)
# Text that may stand before a trailing-closure call `f { }` (a statement start, an assignment, an argument).
_TRAILING_CALL_CONTEXT = re.compile(r"(?:^|[=(,\[{;]|\b(?:return|try[?!]?|await|in|else|defer)|\bdo)\s*$")
_WORD = re.compile(r"\$\d+|[A-Za-z_]\w*")  # an identifier, or a closure's `$0`
# Words of a loop pattern that bind nothing (`for case let .some(x) in`).
_PATTERN_KEYWORDS = frozenset({"let", "var", "case", "some", "try", "await", "in", "is", "as"})
# A local binding and where its value starts: `let x =`, `var x: T =`, `if/guard let x =`, `for x in`.
_BINDING = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::[^=\n]*)?=(?!=)|\bfor\s+(?:case\s+)?(?:let\s+|var\s+)?"
                      r"([A-Za-z_]\w*)\s+in\b")
# An assignment at a statement start, `self.name = ...` or `name = ...` (group 1: `self.`), in an init body.
_ASSIGNMENT = re.compile(r"(?:^|[\n;{])[ \t]*(self\s*\.\s*)?([A-Za-z_]\w*)[ \t]*=(?![=>])")


def _opening(text: str, close: int) -> int:
    """Index of the bracket that opens the one closing at TEXT[close] (blanked code), or -1."""
    depth = 0
    for i in range(close, -1, -1):
        c = text[i]
        if c in ")]}":
            depth += 1
        elif c in "([{":
            depth -= 1
            if depth == 0:
                return i
    return -1


def _receiver_span(code: str, dot: int) -> tuple[int, str]:
    """(start, text) of the postfix expression before the `.` at DOT (`self.items`, `[.a, .b]`, `x?`); the text
    is "" for an implicit member (`.name`)."""
    i = dot - 1
    while i >= 0 and code[i] in " \t\n":
        i -= 1
    if i < dot - 1 and "\n" not in code[i + 1:dot]:
        return dot, ""  # `case .x`, `return .x`: a space (not a line break) before the dot makes it a prefix
    end = i + 1
    while i >= 0:
        c = code[i]
        if c in ")]":
            j = _opening(code, i)
            if j < 0:
                break
            i = j - 1
            continue
        if c in "?!":
            i -= 1
            continue
        if c.isalnum() or c in "_$":
            while i >= 0 and (code[i].isalnum() or code[i] in "_$"):
                i -= 1
            k = i
            while k >= 0 and code[k] in " \t\n":
                k -= 1
            if k >= 0 and code[k] == ".":
                i = k - 1
                while i >= 0 and code[i] in " \t\n":
                    i -= 1
                continue
            break
        break
    start = i + 1
    while start < end and code[start] in " \t\n":
        start += 1
    return start, code[start:end]


def _receiver_before(code: str, dot: int) -> str:
    """The postfix expression before the `.` at DOT, "" for an implicit member."""
    return _receiver_span(code, dot)[1]


def _literal_count(expr: str) -> int | None:
    """Elements of an array literal (`[.a, .b]`: 2) or an integer range literal (`0..<3`: 3), else None."""
    expr = expr.strip()
    if expr.startswith("[") and _closing(expr, 0) == len(expr) - 1:
        parts = _split_top(expr[1:-1], ",")
        if any(len(_split_top(p, ":")) > 1 and not re.match(r"\s*\.", p) for p in parts):
            return None  # a dictionary literal (a `:` outside brackets): not counted per element here
        return len(parts)
    m = re.fullmatch(r"(\d+)\s*\.\.([.<])\s*(\d+)", expr)
    if m:
        low, high = int(m.group(1)), int(m.group(3))
        return max(0, high - low + (1 if m.group(2) == "." else 0))
    return None


def _applies(bound: frozenset | None, varies: set[str]) -> bool:
    """Whether a loop whose pattern binds BOUND (None: a function value passed per element) multiplies a registration
    whose observed values and handler mention VARIES."""
    return bound is None or bool(bound & varies)


@dataclasses.dataclass(frozen=True)
class Param:
    """One parameter of a function declaration."""

    label: str  # the argument label; "_" when the argument is positional
    name: str  # the name inside the body
    default: bool
    closure: bool  # a function type, which a trailing closure can supply


@dataclasses.dataclass(frozen=True)
class Callable:
    """A function, init or named closure declared in a file: what a reference can make register observers."""

    path: str
    package: str
    open: int  # its body's `{`
    name: str  # the function's name, or the owner type's name for an init
    is_init: bool
    params: tuple[Param, ...]
    # Who can call it: ("local", start, end) inside one function body of PATH, ("file",), ("module",) (its
    # package, the Swift module) or ("public",).
    scope: tuple
    # The type (or extension) whose body declares this `func` directly: a method. None for a free or local
    # function, a named closure and an init (an init resolves by its type's name).
    owner: str | None = None
    # (name, the parameters its value comes from) for each parameter and each local its body binds from them
    # (`let key = Name(rawValue: raw)`, `guard let n = name`, `for n in names`): what a call can configure.
    origins: tuple = dataclasses.field(default=(), compare=False)

    @property
    def key(self) -> tuple[str, int]:
        return self.path, self.open

    def param_names(self) -> frozenset[str]:
        return frozenset(p.name for p in self.params)

    def visible(self, path: str, package: str, pos: int) -> bool:
        kind = self.scope[0]
        if kind == "local":
            return path == self.path and self.scope[1] < pos < self.scope[2]
        if kind == "file":
            return path == self.path
        return kind == "public" or package == self.package

    def accepts(self, args: tuple[tuple[str, str], ...], trailing: bool) -> bool:
        """Whether a call with ARGS (labels, "" positional) and maybe a trailing closure can be this one."""
        labels = {p.label for p in self.params}
        given = [label for label, _ in args if label]
        positional = len(args) - len(given)
        if any(label not in labels for label in given):
            return False
        last = self.params[-1] if self.params else None
        required_positional = 0
        for p in self.params:
            if p.default or (p is last and p.closure and trailing):
                continue
            if p.label == "_":
                required_positional += 1
            elif p.label not in given:
                return False
        return required_positional <= positional <= sum(1 for p in self.params if p.label == "_")

    def bound(self, args: tuple[tuple[str, str], ...]) -> dict[str, str]:
        """{parameter name: argument expression} for a call with ARGS."""
        out: dict[str, str] = {}
        positional = iter([p for p in self.params if p.label == "_"])
        for label, expr in args:
            p = next((q for q in self.params if q.label == label), None) if label else next(positional, None)
            if p is not None:
                out[p.name] = expr
        return out


@dataclasses.dataclass(frozen=True)
class Registration:
    """A raw observer registration (KIND "raw") or a reference to a name that may be a wrapper ("call", "value")."""

    path: str
    package: str
    pos: int
    line: int
    text: str
    callee: str | None  # the referenced name (a function's, or a type's for an init); None for a raw call
    init_form: bool  # an init only: `T.init(`, `T.init`, `self.init(`, `let a: T = .init(`
    args: tuple[tuple[str, str], ...]  # (label or "", expression), comments and strings blanked
    trailing: bool
    fns: tuple[Callable, ...]  # the functions whose bodies hold it, innermost first
    kind: str = "raw"
    receiver: str | None = None  # the expression before `.name` ("" for an implicit member); None: unqualified
    owner_ctx: str | None = None  # the innermost type (or extension) around it
    receiver_type: str | None = None  # the receiver's type when the file declares it
    # (multiplier, bound) per loop around it inside its function: the multiplier is an element count, or the name of
    # a parameter of that function whose argument decides it (`for n in names`); BOUND is what the loop's pattern binds
    # (None for a function value passed per element, `names.forEach(on)`): see _applies.
    factors: tuple = ()
    end: int = -1  # the offset after its call's `)` (or its name for a value reference)
    # A raw registration's observed values: the identifiers its notification name, key path or message type argument
    # mentions (_OBSERVED_ARGUMENT).
    mentions: frozenset = frozenset()
    # The identifiers its closure arguments (trailing or `using: { }`) mention: its handler.
    closure: frozenset = frozenset()

    def site(self) -> Site:
        return Site("observer_sites", self.path, self.line, self.text)


class SwiftFile:
    """One file's blanked code, braces and function declarations, for observer registrations."""

    def __init__(self, path: str, raw: str, code: str | None = None, braces: Braces | None = None) -> None:
        self.path = path
        self.package = package_of(path)
        self.code = strip(raw) if code is None else code
        self.braces = braces or Braces(self.code)
        self.starts = [0] + [m.end() for m in re.finditer(r"\n", self.code)]
        self.raw_lines = raw.split("\n")
        self._functions: dict[int, Callable | None] = {}
        self._types: dict[int, tuple[str, str, str | None] | None] = {}
        self._by_name: dict[str, list[Callable]] = {}
        # `let a: T = .init(` and `self.init(` / `Self(` per type name: (offset, its `(`, receiver).
        self._inits: dict[str, list[tuple[int, int, str | None]]] | None = None
        self._receiver_types: dict[str, str | None] = {}
        self._properties: dict[str, bool] = {}

    def _type(self, open_pos: int) -> tuple[str, str, str | None] | None:
        """(kind, name, explicit level or None) of the type or extension whose body opens at OPEN_POS."""
        if open_pos not in self._types:
            head = self.braces.head(open_pos)
            found = None
            for m in TYPE_DECL.finditer(head):
                found = m
            if found is not None and not _NOT_SIGNATURE_TAIL.search(head[found.end():].replace("==", "")
                                                                   .replace("where", "")):
                line = head[head.rfind("\n", 0, found.start(1)) + 1:found.start(1)]  # attributes, modifiers
                level = next((name for name, pattern in _LEVELS if pattern.search(line)), None)
                self._types[open_pos] = (found.group(1), found.group(2).split(".")[-1], level)
            else:
                self._types[open_pos] = None
        return self._types[open_pos]

    def enclosing_type(self, pos: int) -> str | None:
        """The name of the innermost type or extension whose body holds POS."""
        for o in self.braces.enclosing(pos):
            t = self._type(o)
            if t is not None:
                return t[1]
        return None

    def function(self, open_pos: int) -> Callable | None:
        """The function, init or named closure (`let f = { a in ... }`) whose body opens at OPEN_POS, or None."""
        if open_pos in self._functions:
            return self._functions[open_pos]
        self._functions[open_pos] = None
        head = self.braces.head(open_pos)
        outer = self.braces.enclosing(open_pos)  # the braces around this one, innermost first
        owner = next((t for t in (self._type(o) for o in outer) if t is not None), None)
        found = None
        for m in _FUNC_HEAD.finditer(head):
            found = m
        close = _closing(head, found.end() - 1) if found is not None else len(head)
        if found is None or close >= len(head):
            # A parameter list with a `{ ... }` default value: the head starts after that brace, so find the
            # list from its `)` instead.
            last = head.rfind(")")
            if last >= 0 and not _NOT_SIGNATURE_TAIL.search(head[last + 1:].replace("==", "")):
                offset = open_pos - len(head)
                opening = _opening(self.code, offset + last)
                before = self.code[max(0, opening - 300):opening + 1]
                m = None
                for m in _FUNC_HEAD.finditer(before):
                    pass
                if m is not None and m.end() == len(before):
                    shift = max(0, opening - 300)
                    head = self.code[shift + m.start():open_pos]
                    found = _FUNC_HEAD.match(head)
                    close = _closing(head, found.end() - 1)
        method_of = None
        if found is not None and close < len(head) and not _NOT_SIGNATURE_TAIL.search(head[close + 1:].replace("==", "")):
            if found.group(2) and owner is None:
                return None  # an `init` outside a type is not a declaration
            name, is_init, start = found.group(1) or owner[1], bool(found.group(2)), found.start()
            params = []
            for part in _split_top(head[found.end():close], ","):
                m = _PARAM.match(part)
                if m:
                    kind = m.group(3)
                    params.append(Param(m.group(1), m.group(2) or m.group(1), len(_split_top(kind, "=")) > 1,
                                        "->" in kind))
            if not is_init and outer and self._type(outer[0]) is not None:
                method_of = self._type(outer[0])[1]
        else:
            bound = _CLOSURE_BINDING.search(head)
            if bound is None:
                return None
            body_close = self.braces.close.get(open_pos, len(self.code))
            if re.match(r"\s*\(", self.code[body_close + 1:body_close + 40]):
                return None  # `let x = { ... }()`: a value computed once, not a helper
            name, is_init, start = bound.group(1), False, bound.start()
            params = self._closure_params(open_pos)
        scope: tuple | None = None
        levels = []
        for o in outer:
            t = self._type(o)
            if t is not None:
                kind, _, level = t
                if kind != "extension" or level == "file":
                    levels.append(level or "module")
                continue
            if self.function(o) is not None and not levels:
                scope = ("local", o, self.braces.close.get(o, len(self.code)))
                break
        if scope is None:
            at = open_pos - len(head) + start
            line = self.code[self.code.rfind("\n", 0, at) + 1:at]  # the declaration's modifiers
            own = next((level for level, pattern in _LEVELS if pattern.search(line)), None)
            if own is None:
                own = owner[2] if owner is not None and owner[0] == "extension" and owner[2] else "module"
            scope = (min([own] + levels, key=_LEVEL_RANK.__getitem__),)
        fn = Callable(self.path, self.package, open_pos, name, is_init, tuple(params), scope, method_of,
                      self._origins(open_pos, params))
        self._functions[open_pos] = fn
        return fn

    def _closure_params(self, open_pos: int) -> list[Param]:
        """The parameters of the closure literal whose `{` is at OPEN_POS (all positional): its `a, b in` or
        `(a: T, b: U) in` list, else the `$0`, `$1`, ... its body uses."""
        close = self.braces.close.get(open_pos, len(self.code))
        body = self.code[open_pos + 1:close]
        names = self._closure_names(open_pos)
        if names is None:
            names = [f"${i}" for i in range(max((int(n) for n in re.findall(r"\$(\d+)", body)), default=-1) + 1)]
        return [Param("_", n, False, False) for n in names]

    def _closure_names(self, open_pos: int) -> list[str] | None:
        """The names a closure literal at OPEN_POS lists before `in`, or None when it lists none."""
        close = self.braces.close.get(open_pos, len(self.code))
        m = _CLOSURE_SIGNATURE.match(self.code[open_pos + 1:close])
        if not m:
            return None
        listed = m.group(1).strip()
        return [part.split(":", 1)[0].split()[-1] for part in _split_top(listed.strip("()"), ",")
                if part.split(":", 1)[0].split()]

    def callables(self, name: str) -> list[Callable]:
        """The functions, named closures and (for a type NAME) inits this file declares under NAME."""
        if name not in self._by_name:
            word = re.compile(rf"(?<![\w$]){re.escape(name)}(?!\w)")
            out = []
            for o in self.braces.opens:
                head = self.braces.head(o)
                # A declaration's head names it (`func name(`, `let name = {`), or is an `init` (of type NAME).
                if not word.search(head) and "init" not in head:
                    continue
                fn = self.function(o)
                if fn is not None and fn.name == name:
                    out.append(fn)
            self._by_name[name] = out
        return self._by_name[name]

    def enclosing_functions(self, pos: int) -> tuple[Callable, ...]:
        """The functions (and named closures) whose bodies hold POS, innermost first, up to type or file scope."""
        out = []
        for o in self.braces.enclosing(pos):
            fn = self.function(o)
            if fn is not None:
                out.append(fn)
            elif self._type(o) is not None:
                break
        return tuple(out)

    def _sequence_factor(self, seq: str, fns: tuple[Callable, ...], pos: int) -> int | str:
        """How many times a loop over SEQ runs: an element count, a parameter of one of FNS (its argument decides),
        or 1."""
        seq = seq.strip()
        count = _literal_count(seq)
        if count is not None:
            return count
        if _WORD.fullmatch(seq):
            if any(seq == name for f in fns for name, _ in f.origins):
                return seq
            bindings = list(re.finditer(rf"\b(?:let|var)\s+{re.escape(seq)}\s*(?::[^=\n]*)?=\s*(?=\[)",
                                        self.code[:pos]))
            if bindings:
                start = bindings[-1].end()
                literal = self.code[start:_closing(self.code, start) + 1]
                count = _literal_count(literal)
                if count is not None:
                    return count
        return 1

    def factors(self, pos: int, fns: tuple[Callable, ...]) -> tuple:
        """(multiplier, bound) of each loop (`for x in s`, `s.forEach {`) around POS, up to its type: the multiplier
        from _sequence_factor, BOUND the names its pattern (or the closure's parameters) binds."""
        out = []
        for o in self.braces.enclosing(pos):
            if self._type(o) is not None:
                break
            head = self.braces.head(o)
            loop = None
            for m in re.finditer(r"\bfor\s+(?!:)", head):
                loop = m
            if loop is not None:
                m = _LOOP_HEAD.match(head[loop.start():].strip())
                if m:
                    bound = frozenset(_WORD.findall(m.group(1))) - _PATTERN_KEYWORDS
                    out.append((self._sequence_factor(m.group(2), fns, pos), bound))
                    continue
            per = _PER_ELEMENT.search(head)
            if per is not None:
                dot = o - len(head) + per.start()
                names = self._closure_names(o)
                bound = frozenset(names) if names is not None else frozenset(f"${i}" for i in range(4))
                out.append((self._sequence_factor(_receiver_before(self.code, dot), fns, pos), bound))
        return tuple(out)

    def _origins(self, open_pos: int, params: list[Param]) -> tuple:
        """(name, parameters its value comes from) for the parameters of the body at OPEN_POS and the locals the
        body binds from them, to a fixed point (`let key = Name(rawValue: raw)` comes from `raw`)."""
        found = {p.name: {p.name} for p in params}
        body = self.code[open_pos + 1:self.braces.close.get(open_pos, len(self.code))]
        binds = []
        for m in _BINDING.finditer(body):
            start, stop = m.end(), len(body)
            for end in (body.find("\n", start), body.find("{", start)):
                if 0 <= end < stop:
                    stop = end
            binds.append((m.group(1) or m.group(2), set(_WORD.findall(body[start:stop]))))
        grew = bool(found)
        while grew:
            grew = False
            for name, used in binds:
                comes = set().union(*(found[u] for u in used if u in found and u != name))
                if comes - found.get(name, set()):
                    found[name] = found.get(name, set()) | comes
                    grew = True
        return tuple((name, frozenset(ps)) for name, ps in sorted(found.items()))

    def _receiver_type(self, receiver: str, owner_ctx: str | None) -> str | None:
        """The type of RECEIVER (`self`, `Type`, or a name the file declares with a type), else None."""
        r = receiver.strip().rstrip("?!").strip()
        if r in ("self", "Self"):
            return owner_ctx
        if re.fullmatch(r"[A-Z]\w*(?:\.[A-Z]\w*)*", r):
            return r.split(".")[-1]
        m = re.search(r"([A-Za-z_]\w*)[?!]?$", r)
        if m is None:
            return None
        ident = m.group(1)
        if ident not in self._receiver_types:
            found = set(re.findall(rf"\b{ident}\s*:\s*(?:inout\s+|any\s+|some\s+)?([A-Z]\w*)", self.code))
            found |= set(re.findall(rf"\b(?:let|var)\s+{ident}\s*=\s*(?:try\s+|await\s+)*([A-Z]\w*)\s*(?:\.\s*init\s*)?\(",
                                    self.code))
            self._receiver_types[ident] = found.pop() if len(found) == 1 else None
        return self._receiver_types[ident]

    def _shadowed(self, name: str, pos: int, fns: tuple[Callable, ...]) -> bool:
        """Whether NAME at POS is a parameter or a local binding (not a helper) of the code around it."""
        if any(name in fn.param_names() for fn in fns):
            return True
        outer = fns[-1].open if fns else None
        for o in self.braces.enclosing(pos):
            names = self._closure_names(o) if self.function(o) is None else None
            if names and name in names:
                return True
            if o == outer:
                break
        if outer is None:
            return False
        body = self.code[outer:pos]
        for m in re.finditer(rf"\b(?:let|var)\s+{re.escape(name)}\b|\bfor\s+(?:case\s+)?(?:let\s+|var\s+)?"
                             rf"{re.escape(name)}\s+in\b|\b(?:if|guard|while)\s+(?:let|var)\s+{re.escape(name)}\b", body):
            if not re.match(r"\s*(?::[^=\n]*)?=\s*\{", body[m.end():]):
                return True
        return False

    def _call(self, pos: int, open_paren: int, callee: str | None, init_form: bool, kind: str = "raw",
              receiver: str | None = None, observed: tuple = ((), None)) -> Registration:
        close = _closing(self.code, open_paren)
        args = []
        for part in _split_top(self.code[open_paren + 1:close], ","):
            m = _ARG.match(part)
            args.append((m.group(1), m.group(2).strip()) if m else ("", part))
        brace = re.match(r"\s*\{", self.code[close + 1:close + 200])
        end = close + 1
        if brace is not None:
            end = _closing(self.code, close + 1 + brace.end() - 1) + 1
        return self._registration(pos, end, callee, init_form, tuple(args), brace is not None, kind, receiver,
                                  config=self.code[open_paren:end], observed=observed)

    def _registration(self, pos: int, end: int, callee: str | None, init_form: bool, args: tuple, trailing: bool,
                      kind: str, receiver: str | None, extra: tuple = (), config: str = "",
                      observed: tuple = ((), None)) -> Registration:
        line = _line_of(self.code, pos, self.starts)
        text = self.raw_lines[line - 1].strip() if line - 1 < len(self.raw_lines) else ""
        fns = self.enclosing_functions(pos)
        owner_ctx = self.enclosing_type(pos)
        # A reference resolves a method by its receiver's type; a raw call's receiver is only what it observes.
        rtype = self._receiver_type(receiver, owner_ctx) if receiver and kind != "raw" else None
        # What a raw call observes: its notification name, key path or message type (OBSERVED: the labels and the
        # positional index of that argument, _OBSERVED_ARGUMENT). Its center, object, queue and receiver say where or
        # how, not what: a caller that supplies only those does not make it a wrapper. A reference's observed values
        # depend on what its wrapper's parameters configure, so resolve_observers derives them.
        labels, index = observed
        identity, handler = [], []
        positional = 0
        for label, expr in args:
            if expr.lstrip().startswith("{"):
                handler.append(expr)
            elif kind == "raw" and (label in labels or (not label and positional == index)):
                identity.append(expr)
            positional += 0 if label else 1
        if trailing and "{" in config:
            handler.append(config[config.rfind(")", 0, config.find("{")) + 1:] if ")" in config else config)
        mentions = frozenset(_WORD.findall(" ".join(identity)))
        closure = frozenset(_WORD.findall(" ".join(handler)))
        return Registration(self.path, self.package, pos, line, text, callee, init_form, args, trailing, fns, kind,
                            receiver, owner_ctx, rtype, self.factors(pos, fns) + extra, end, mentions, closure)

    def raw_registrations(self) -> list[Registration]:
        """Every raw registration call (RAW_OBSERVER), with its receiver ("" when it has none)."""
        out = []
        for m in RAW_OBSERVER.finditer(self.code):
            if re.search(r"\bfunc\s+$", self.code[max(0, m.start() - 40):m.start()]):
                continue
            dot = m.start()
            if self.code[dot] != ".":
                dot -= 1
                while dot >= 0 and self.code[dot] in " \t\n":
                    dot -= 1
            receiver = _receiver_before(self.code, dot) if dot >= 0 and self.code[dot] == "." else ""
            word = re.search(r"[A-Za-z]+", m.group(0)).group(0)
            out.append(self._call(m.start(), self.code.index("(", m.start()), None, False, "raw", receiver,
                                  _OBSERVED_ARGUMENT[word]))
        return out

    def property_origins(self) -> dict[str, dict[str, list[tuple[Callable, frozenset[str]]]]]:
        """{type: {stored property: [(init, the init's parameters its value comes from)]}} for the inits this file
        declares: `self.p = expr` or `p = expr` at a statement start of an init body (not a parameter or a local of
        the init unless written `self.p`), where EXPR mentions the init's parameters or locals bound from them."""
        out: dict[str, dict[str, list[tuple[Callable, frozenset[str]]]]] = {}
        for o in self.braces.opens:
            if "init" not in self.braces.head(o):
                continue
            fn = self.function(o)
            if fn is None or not fn.is_init or fn.open != o:
                continue
            origins = dict(fn.origins)
            body = self.code[o + 1:self.braces.close.get(o, len(self.code))]
            for m in _ASSIGNMENT.finditer(body):
                prop = m.group(2)
                if not m.group(1) and prop in origins:
                    continue  # a parameter, or a local the init binds: not a stored property
                start = m.end()
                stop = len(body)
                for end in (body.find("\n", start), body.find(";", start)):
                    if 0 <= end < stop:
                        stop = end
                params = set().union(*(origins[w] for w in _WORD.findall(body[start:stop]) if w in origins))
                if params:
                    out.setdefault(fn.name, {}).setdefault(prop, []).append((fn, frozenset(params)))
        return out

    def references(self, name: str) -> list[Registration]:
        """Every reference to NAME that can run it: a call, a trailing-closure call, an init call (also
        `self.init(` in its type and `let a: T = .init(`) and a use as a value; declarations excluded."""
        code = self.code
        out = []
        for m in re.finditer(rf"(?<![\w$#@\\]){re.escape(name)}(?!\w)", code):
            start, end = m.start(), m.end()
            if _DECLARES.search(code[max(0, start - 40):start]):
                continue
            i = start - 1
            while i >= 0 and code[i] in " \t\n":
                i -= 1
            receiver, lead = None, start
            if i >= 0 and code[i] == ".":
                lead, receiver = _receiver_span(code, i)
            after = code[end:end + 200]
            init_call = re.match(r"\s*\.\s*init\s*\(", after)
            if init_call:
                out.append(self._call(start, end + init_call.end() - 1, name, True, "call", receiver))
                continue
            init_value = re.match(r"\s*\.\s*init\b", after)
            if init_value:
                out.append(self._value(start, end + init_value.end(), name, True, receiver,
                                       self._per_element(lead, after[init_value.end():], start)))
                continue
            if receiver == "":
                continue  # an implicit member (`.name`): a static or a case of a contextual type
            fns = self.enclosing_functions(start)
            if receiver is None and self._shadowed(name, start, fns):
                continue  # a parameter or a local binding of that name, not the helper
            call = re.match(r"[ \t]*\(", after)
            if call:
                out.append(self._call(start, end + call.end() - 1, name, False, "call", receiver))
                continue
            prefix = code[code.rfind("\n", 0, lead) + 1:lead]
            if re.match(r"[ \t]*\{", after):
                if _TRAILING_CALL_CONTEXT.search(prefix):
                    brace = code.index("{", end)
                    close = _closing(code, brace) + 1
                    out.append(self._registration(start, close, name, False, (), True, "call", receiver,
                                                  config=code[brace:close]))
                continue
            if re.match(r"\s*(?::(?!:)|=(?![=>])|\.|<)|[ \t]+(?:in\b|[A-Za-z_]\w*\s*:(?!:))", after) or \
                    re.search(r"(?::|->)\s*$", code[max(0, lead - 60):lead]):
                continue  # a label, an assignment target, a member of a variable, a type position, a parameter
            if receiver is not None and receiver not in ("self", "Self") and not re.fullmatch(r"[A-Z]\w*(?:\.[A-Z]\w*)*", receiver):
                continue  # `x.name` without a call: a property of a value, not a function reference
            if self._is_property(name):
                continue  # the file declares a stored or computed property of that name
            out.append(self._value(start, end, name, False, receiver, self._per_element(lead, after, start)))
        if self._inits is None:
            self._inits = collections.defaultdict(list)
            for m in re.finditer(r":\s*([A-Za-z_]\w*)\s*[?!]?\s*=\s*(\.\s*init\s*\()", code):
                self._inits[m.group(1)].append((m.start(2), m.end(2) - 1, None))
            for m in re.finditer(r"(?<![\w.])(?:(?:self|Self)\s*\.\s*init|Self)\s*\(", code):
                owner = self.enclosing_type(m.start())
                if owner is not None:
                    self._inits[owner].append((m.start(), m.end() - 1, "self"))
        for pos, paren, receiver in self._inits.get(name, ()):
            out.append(self._call(pos, paren, name, True, "call", receiver))
        return out

    def _per_element(self, lead: int, after: str, pos: int) -> tuple:
        """((multiplier, None),) for a function value passed as the only argument of `s.forEach(`/`s.map(` (LEAD
        is where the value's expression starts, AFTER the text after it): each element is passed to it, so the loop
        always applies (_applies). Else ()."""
        per = _PER_ELEMENT.search(self.code[max(0, lead - 200):lead])
        if per is None or not per.group(1) or not re.match(r"\s*\)", after):
            return ()
        dot = max(0, lead - 200) + per.start()
        return ((self._sequence_factor(_receiver_before(self.code, dot), self.enclosing_functions(pos), pos), None),)

    def _is_property(self, name: str) -> bool:
        """Whether the file declares a `let`/`var` NAME at type scope (a property, not a helper)."""
        if name not in self._properties:
            self._properties[name] = any(
                not self.enclosing_functions(m.start()) and self.braces.enclosing(m.start())
                for m in re.finditer(rf"\b(?:let|var)\s+{re.escape(name)}\b(?!\s*(?::[^=\n]*)?=\s*\{{)", self.code))
        return self._properties[name]

    def _value(self, pos: int, end: int, callee: str, init_form: bool, receiver: str | None,
               extra: tuple = ()) -> Registration:
        return self._registration(pos, end, callee, init_form, (), False, "value", receiver, extra)


@dataclasses.dataclass
class Observers:
    """The observer registrations of a set of files at one revision (`resolve_observers`)."""

    sites: dict[str, list[Site]]  # per path, one Site per registration
    # The names of the wrappers other files can reference (module or public scope). A local or file-scope wrapper is
    # referenced only in its own file.
    shared_wrappers: set[str]
    # {name: [(the package that sees it, or "*" when public; its owner type for a method, else None)]} of the
    # shared wrappers.
    entries: dict[str, list[tuple[str, str | None]]] = dataclasses.field(default_factory=dict)
    # {name: `func name` declarations in the whole tree} for the shared method wrappers' names.
    func_decls: dict[str, int] = dataclasses.field(default_factory=dict)
    # Per path: (the counted registration or reference, how many registrations it makes).
    hits: dict[str, list[tuple[Registration, int]]] = dataclasses.field(default_factory=dict)

    def search_names(self) -> set[str]:
        """The names whose mentions find every file that can reference a shared wrapper (`sees`): a free
        function's, init's or closure's name, a method's owner type, and a method's own name when no other
        `func` of that name exists (then an unknown receiver resolves to it)."""
        out = set()
        for name, entries in self.entries.items():
            for _, owner in entries:
                if owner is None or self.func_decls.get(name, 0) == 1:
                    out.add(name)
                if owner is not None:
                    out.add(owner)
        return out

    def sees(self, path: str, mentioned: set[str]) -> bool:
        """Whether a file PATH that mentions the names MENTIONED (of `search_names`) can reference a shared
        wrapper: a free function, init or closure it can see by name; a method when the file names its owner
        type (its own type, a declared receiver type, `T.f`), or its name when no other `func` has it."""
        package = package_of(path)
        return any(needs_scan(entries, package, name, mentioned, lambda name=name: self.func_decls.get(name, 0))
                   for name, entries in self.entries.items())

    def total(self) -> int:
        return sum(len(s) for s in self.sites.values())

    def hint_names(self) -> set[str]:
        """search_names and every method wrapper's name: the names whose mentions and `func` declarations the next
        count's first grep reads (recorded as arch-ratchet.json `observer_wrappers`), so a later push greps again only
        for a wrapper this record lacks."""
        return self.search_names() | set(self.func_decls)


def needs_scan(entries, package: str, name: str, mentioned: set[str], decls) -> bool:
    """Whether a file of PACKAGE that mentions MENTIONED (searched names) can reference the shared wrapper NAME
    (ENTRIES: its `Observers.entries`); DECLS() gives the `func NAME` declarations in the tree (asked only for a
    method whose owner type the file does not name)."""
    for scope, owner in entries:
        if scope != "*" and scope != package:
            continue
        if owner is None:
            if name in mentioned:
                return True
        elif owner in mentioned or (name in mentioned and decls() == 1):
            return True
    return False


# A `func` declaration of one of {names}.
FUNC_DECLARATION = r"\bfunc[ \t]+({names})\b"


def func_decls(texts, names: set[str]) -> collections.Counter:
    """{name: `func name` declarations} over TEXTS for NAMES."""
    found: collections.Counter = collections.Counter()
    if not names:
        return found
    pattern = re.compile(FUNC_DECLARATION.format(names="|".join(sorted(map(re.escape, names)))))
    for text in texts:
        found.update(m.group(1) for m in pattern.finditer(text))
    return found


def call_pattern(names: set[str]) -> str:
    """PCRE (and Python) for a mention of one of NAMES (the file's parse decides what kind)."""
    return r"(?<![\w$])(?:" + "|".join(sorted(re.escape(n) for n in names)) + r")(?![\w])"


def resolve_observers(files: dict[str, "ObserverFile"], mentioned, decl_counts) -> Observers:
    """Observer sites of FILES, which hold every file that has a raw registration or can reference a wrapper at
    one revision (the section comment above gives the rule).

    MENTIONED(path) is the set of searched names (Observers.search_names, owner types included) the file's text
    mentions: a file is scanned for a shared wrapper's references only when it can see the wrapper by those
    names (needs_scan); a local or file-scope wrapper is always scanned for in its own file. DECL_COUNTS(names)
    gives the `func` declarations of NAMES in the whole tree (an unknown receiver resolves to a method only when
    no other `func` has its name).
    """
    decl_memo: dict[str, int] = {}

    def decl_count(name: str) -> int:
        if name not in decl_memo:
            # One lookup for every method wrapper known so far (the next ones are usually asked next).
            wanted = {n for n, v in entries.items() if any(o for _, o in v)} | {name}
            decl_memo.update(decl_counts(wanted - set(decl_memo)))
            for n in wanted:
                decl_memo.setdefault(n, 0)
        return decl_memo[name]

    wrappers: dict[tuple[str, int], Callable] = {}
    config: dict[tuple[str, int], set[str]] = {}  # wrapper -> its configuring parameters
    decls: dict[str, dict[tuple[str, int], Callable]] = collections.defaultdict(dict)  # name -> every declaration
    refs: dict[str, list[Registration]] = collections.defaultdict(list)
    scanned: dict[str, set[str]] = collections.defaultdict(set)
    shared_names: set[str] = set()  # wrappers other files can reference
    entries: dict[str, set[tuple[str, str | None]]] = collections.defaultdict(set)  # see Observers.entries
    own_names: dict[str, set[str]] = collections.defaultdict(set)  # path -> its local and file-scope wrappers
    expr_words: dict[str, frozenset[str]] = {}

    def add(fn: Callable) -> bool:
        if fn.key in wrappers:
            return False
        wrappers[fn.key] = fn
        config[fn.key] = set()
        decls[fn.name][fn.key] = fn
        if fn.scope[0] in ("local", "file"):
            own_names[fn.path].add(fn.name)
        else:
            shared_names.add(fn.name)
            entries[fn.name].add(("*" if fn.scope[0] == "public" else fn.package, fn.owner))
        return True

    resolved: dict[Registration, list[Callable]] = {}

    def candidates(ref: Registration) -> list[Callable]:
        """The declarations REF can run (by name, visibility, labels and, for a method, owner)."""
        pool = [c for c in decls.get(ref.callee, {}).values() if c.visible(ref.path, ref.package, ref.pos)]
        if ref.kind == "call":
            pool = [c for c in pool if c.accepts(ref.args, ref.trailing)]
        inits = [c for c in pool if c.is_init]
        if ref.init_form:
            return inits
        if ref.kind == "value":
            inits = []
        methods = [c for c in pool if c.owner is not None]
        others = [c for c in pool if c.owner is None and not c.is_init]
        recv = ref.receiver
        if recv is None or recv in ("self", "Self"):
            own = [c for c in methods if c.owner == ref.owner_ctx]
            return own or others + (inits if recv is None else [])
        if recv in ("super", ""):
            return []
        if ref.receiver_type is not None:
            own = [c for c in methods if c.owner == ref.receiver_type]
            if own:
                return own
            # `Module.f(` / `Module.T(`: a qualified free function or init.
            return others + inits if re.fullmatch(r"[A-Z]\w*", recv) else []
        # An unknown receiver: the method only when no other `func` of that name exists in the tree.
        return methods if len(methods) == 1 and decl_count(ref.callee) == 1 else []

    def targets(ref: Registration) -> list[Callable]:
        if ref not in resolved:
            resolved[ref] = [c for c in candidates(ref) if c.key in wrappers]
        return resolved[ref]

    def words(expr: str) -> frozenset[str]:
        if expr not in expr_words:
            expr_words[expr] = frozenset(_WORD.findall(expr))
        return expr_words[expr]

    def observed(reg: Registration) -> tuple[set[str], set[str]]:
        """(identity, handler) of REG before its loops: the names whose values decide what it observes (a raw call's
        receiver and arguments; for a reference, what it passes to its wrappers' configuring parameters) and the
        names its handler closures mention there."""
        if reg.kind == "raw":
            return set(reg.mentions), set(reg.closure)
        identity: set[str] = set()
        handler: set[str] = set()
        if reg.kind != "call":
            return identity, handler
        for t in targets(reg):
            wanted = config[t.key]
            if not wanted:
                continue
            bound = t.bound(reg.args)
            closures = {p.name for p in t.params if p.closure}
            for param, expr in bound.items():
                if param in wanted:
                    (handler if param in closures or expr.lstrip().startswith("{") else identity).update(words(expr))
            last = t.params[-1] if t.params else None
            if reg.trailing and last is not None and last.closure and last.name in wanted and last.name not in bound:
                handler |= reg.closure
        return identity, handler

    def uses(reg: Registration) -> tuple[set[str], set[str]]:
        """observed(REG), plus as identity each parameter whose argument decides how often a loop that REG uses
        runs (`for n in names` around `addObserver(forName: n`): such a loop makes one registration per element."""
        identity, handler = observed(reg)
        varies = identity | handler
        loops = {mult for mult, bound in reg.factors if isinstance(mult, str) and _applies(bound, varies)}
        return identity | loops, handler

    def charge(reg: Registration) -> list[tuple[Callable, set[str]]]:
        """[(a function REG is charged to, the parameters of it that configure REG)], or []: it counts where it
        stands. What a registration observes comes from any parameter; its handler only from a parameter of
        function type (the caller supplies the reaction), not from a value the handler happens to capture. With no
        such parameter, a stored property of the enclosing type that its inits set from their parameters charges
        it to those inits (each construction registers)."""
        identity, handler = uses(reg)
        for fn in reg.fns:
            origins = dict(fn.origins)
            closures = {p.name for p in fn.params if p.closure}
            params = set().union(*(origins[n] for n in identity if n in origins))
            params |= set().union(*(origins[n] & closures for n in handler if n in origins))
            if params:
                return [(fn, params)]
        props = files[reg.path].properties().get(reg.owner_ctx, {}) if reg.owner_ctx else {}
        found: dict[tuple[str, int], tuple[Callable, set[str]]] = {}
        for word in sorted((identity | handler) & set(props)):
            for init, by in props[word]:
                closures = {p.name for p in init.params if p.closure}
                params = set(by) if word in identity else set(by) & closures
                if params:
                    found.setdefault(init.key, (init, set()))[1].update(params)
        return list(found.values())

    charged: dict[Registration, tuple[tuple[str, int], ...]] = {}

    def settle(reg: Registration) -> bool:
        """Charge REG; True when that made a new wrapper or a new configuring parameter."""
        found = charge(reg)
        if not found:
            charged.pop(reg, None)
            return False
        grew = False
        for fn, params in found:
            grew |= add(fn)
            if not params <= config[fn.key]:
                config[fn.key] |= params
                grew = True
        charged[reg] = tuple(fn.key for fn, _ in found)
        return grew

    for f in files.values():
        for reg in f.raw():
            settle(reg)
    while True:
        for path, f in files.items():
            seen = mentioned(path)
            todo = {n for n in shared_names - scanned[path]
                    if needs_scan(entries[n], f.package, n, seen, lambda n=n: decl_count(n))}
            todo |= own_names.get(path, set()) - scanned[path]
            if not todo:
                continue
            scanned[path] |= todo
            for name in sorted(todo):
                found, declared = f.references(name)
                refs[path] += found
                for c in declared:
                    decls[name][c.key] = c
        resolved.clear()
        grew = False
        for f in files.values():
            for reg in f.raw():
                grew |= settle(reg)
        for found in refs.values():
            for ref in found:
                if targets(ref):
                    grew |= settle(ref)
        if not grew:
            break

    # Per wrapper, the registrations and references charged to it (they repeat per call of it); the rest count where
    # they stand.
    body: dict[tuple[str, int], list[Registration]] = collections.defaultdict(list)
    placed: list[Registration] = []
    edges: dict[tuple[str, int] | None, set[tuple[str, int]]] = collections.defaultdict(set)
    referenced: set[tuple[str, int]] = set()
    for path, f in files.items():
        for reg in f.raw() + [r for r in refs.get(path, ()) if targets(r)]:
            owners = charged.get(reg, ())
            for k in owners:
                body[k].append(reg)
            if not owners:
                placed.append(reg)
            if reg.kind == "raw":
                continue
            around = {fn.key for fn in reg.fns}
            for t in targets(reg):
                if t.key not in around:  # a recursive call is not a caller
                    referenced.add(t.key)
                    for k in owners or (None,):
                        edges[k].add(t.key)

    # Roots count their bodies: wrappers nothing references, then (for a cycle no root reaches) its first member.
    roots = sorted(k for k in wrappers if k not in referenced)
    reached: set[tuple[str, int]] = set()
    todo = list(roots) + sorted(edges.get(None, ()))
    while True:
        while todo:
            k = todo.pop()
            if k in reached:
                continue
            reached.add(k)
            todo.extend(edges.get(k, ()))
        left = sorted(k for k in wrappers if k not in reached and k not in roots)
        if not left:
            break
        roots.append(left[0])
        todo = [left[0]]
    root_set = set(roots)

    weights: dict[tuple, int] = {}

    def callee_env(reg: Registration, callee: Callable, env: dict[str, int]) -> frozenset:
        """The element counts a call passes to CALLEE's parameters (array literals, or the caller's own counts)."""
        if reg.kind != "call":
            return frozenset()
        out = {}
        for p, expr in callee.bound(reg.args).items():
            n = _literal_count(expr)
            if n is None and expr in env:
                n = env[expr]
            if n is not None:
                out[p] = n
        return frozenset(out.items())

    def count(reg: Registration, env: dict[str, int], stack: frozenset) -> int:
        """Registrations REG makes in a body whose parameters' element counts are ENV."""
        identity, handler = observed(reg)
        varies = identity | handler
        times = 1
        for mult, bound in reg.factors:
            if _applies(bound, varies):
                times *= mult if isinstance(mult, int) else env.get(mult, 1)
        if times == 0 or reg.kind == "raw":
            return times
        return times * max((weight(c, callee_env(reg, c, env), stack) for c in targets(reg)), default=0)

    def weight(fn: Callable, env: frozenset, stack: frozenset = frozenset()) -> int:
        """Registrations one call of the wrapper FN makes when its parameters' element counts are ENV."""
        key = (fn.key, env)
        if key in weights:
            return weights[key]
        if fn.key in stack:
            return 1  # a recursive wrapper: at least its own registration
        total = sum(count(reg, dict(env), stack | {fn.key}) for reg in body[fn.key])
        weights[key] = total
        return total

    sites: dict[str, list[Site]] = collections.defaultdict(list)
    hits: dict[str, list[tuple[Registration, int]]] = collections.defaultdict(list)
    # A registration of root bodies counts at its own statement once, and only when none of the functions it is
    # charged to is referenced (then it counts through their callers).
    own = [reg for reg in dict.fromkeys(r for k in roots for r in body[k]) if all(k in root_set for k in charged[reg])]
    for reg in own + placed:
        n = count(reg, {}, frozenset())
        if n:
            hits[reg.path].append((reg, n))
            sites[reg.path] += [reg.site()] * n
    method_names = {n for n, v in entries.items() if any(o for _, o in v)}
    return Observers({p: sorted(s, key=lambda s: s.line) for p, s in sites.items()}, shared_names,
                     {n: sorted(v, key=str) for n, v in entries.items()},
                     {n: decl_count(n) for n in sorted(method_names)},
                     {p: sorted(h, key=lambda h: h[0].pos) for p, h in hits.items()})


# The cache entry kinds of an ObserverFile (FactsCache keys `<kind>:<blob>:<path>`; `ref` adds `:<name>`).
OBSERVER_FACTS = "observers"
OBSERVER_REFS = "observer-refs"


def _callable_json(fn: Callable) -> list:
    return [fn.open, fn.name, fn.is_init, [[p.label, p.name, p.default, p.closure] for p in fn.params], list(fn.scope),
            fn.owner, [[n, sorted(ps)] for n, ps in fn.origins]]


def _registration_json(reg: Registration, table: dict[str, list]) -> list:
    for fn in reg.fns:
        table[str(fn.open)] = _callable_json(fn)
    return [reg.pos, reg.line, reg.text, reg.callee, reg.init_form, [list(a) for a in reg.args], reg.trailing,
            [fn.open for fn in reg.fns], reg.kind, reg.receiver, reg.owner_ctx, reg.receiver_type,
            [[mult, sorted(bound) if bound is not None else None] for mult, bound in reg.factors], reg.end,
            sorted(reg.mentions), sorted(reg.closure)]


class ObserverFile:
    """One file's observer facts, each parsed once per content: its raw registrations, the stored properties its
    inits set (SwiftFile.property_origins) and, per name, the references to it and the declarations under it.

    With a FactsCache and a BLOB (the file's object id), a fact parsed once is kept in the repository's git directory
    and read back by (blob, path), so a push parses only the files whose content it has not seen. TEXT is the content,
    or LOAD() returns it when a fact must be parsed.
    """

    def __init__(self, path: str, text: str | None = None, blob: str | None = None, load=None,
                 cache: "FactsCache | None" = None) -> None:
        self.path = path
        self.package = package_of(path)
        self.blob = blob
        self._text = text
        self._load = load
        self.cache = cache if cache is not None and blob else None
        self._scan: SwiftFile | None = None
        self._callables: dict[int, Callable] = {}
        self._raw: list[Registration] | None = None
        self._props: dict[str, dict[str, list[tuple[Callable, frozenset[str]]]]] | None = None
        self._refs: dict[str, tuple[list[Registration], list[Callable]]] = {}

    def text(self) -> str:
        if self._text is None:
            self._text = (self._load() if self._load is not None else None) or ""
        return self._text

    def _parsed(self) -> SwiftFile:
        if self._scan is None:
            self._scan = SwiftFile(self.path, self.text())
        return self._scan

    def _key(self, kind: str, name: str = "") -> str:
        return f"{kind}:{self.blob}:{self.path}" + (f":{name}" if name else "")

    def _callable(self, table: dict[str, list], open_pos: int) -> Callable:
        if open_pos not in self._callables:
            _, name, is_init, params, scope, owner, origins = table[str(open_pos)]
            self._callables[open_pos] = Callable(
                self.path, self.package, open_pos, name, is_init, tuple(Param(*p) for p in params), tuple(scope),
                owner, tuple((n, frozenset(ps)) for n, ps in origins))
        return self._callables[open_pos]

    def _registration(self, table: dict[str, list], v: list) -> Registration:
        (pos, line, text, callee, init_form, args, trailing, fns, kind, receiver, owner_ctx, receiver_type, factors,
         end, mentions, closure) = v
        return Registration(self.path, self.package, pos, line, text, callee, init_form, tuple(tuple(a) for a in args),
                            trailing, tuple(self._callable(table, o) for o in fns), kind, receiver, owner_ctx,
                            receiver_type, tuple((m, frozenset(b) if b is not None else None) for m, b in factors), end,
                            frozenset(mentions), frozenset(closure))

    def _read(self, key: str):
        if self.cache is None:
            return None
        text = self.cache.get_text(key)
        if text is None:
            return None
        try:
            return json.loads(text)
        except ValueError:
            return None

    def _facts(self) -> None:
        entry = self._read(self._key(OBSERVER_FACTS))
        if entry is not None:
            table = entry["callables"]
            self._raw = [self._registration(table, v) for v in entry["raw"]]
            self._props = {owner: {prop: [(self._callable(table, o), frozenset(ps)) for o, ps in inits]
                                   for prop, inits in props.items()}
                           for owner, props in entry["properties"].items()}
            return
        scan = self._parsed()
        self._raw = scan.raw_registrations() if RAW_OBSERVER.search(scan.code) else []
        self._props = scan.property_origins()
        if self.cache is not None:
            table: dict[str, list] = {}
            raw = [_registration_json(reg, table) for reg in self._raw]
            props = {}
            for owner, by_prop in self._props.items():
                props[owner] = {}
                for prop, inits in by_prop.items():
                    props[owner][prop] = [[fn.open, sorted(ps)] for fn, ps in inits]
                    for fn, _ in inits:
                        table[str(fn.open)] = _callable_json(fn)
            self.cache.put_text(self._key(OBSERVER_FACTS), json.dumps(
                {"callables": table, "raw": raw, "properties": props}, separators=(",", ":")))

    def raw(self) -> list[Registration]:
        """The raw registrations (SwiftFile.raw_registrations)."""
        if self._raw is None:
            self._facts()
        return self._raw

    def properties(self) -> dict[str, dict[str, list[tuple[Callable, frozenset[str]]]]]:
        """SwiftFile.property_origins of the file."""
        if self._props is None:
            self._facts()
        return self._props

    def references(self, name: str) -> tuple[list[Registration], list[Callable]]:
        """(the references to NAME, the functions, named closures and inits declared under NAME)."""
        if name not in self._refs:
            key = self._key(OBSERVER_REFS, name)
            entry = self._read(key)
            if entry is not None:
                table = entry["callables"]
                self._refs[name] = ([self._registration(table, v) for v in entry["refs"]],
                                    [self._callable(table, o) for o in entry["declared"]])
            else:
                scan = self._parsed()
                found, declared = scan.references(name), scan.callables(name)
                self._refs[name] = (found, declared)
                if self.cache is not None:
                    table = {}
                    refs = [_registration_json(reg, table) for reg in found]
                    for fn in declared:
                        table[str(fn.open)] = _callable_json(fn)
                    self.cache.put_text(key, json.dumps({"callables": table, "refs": refs,
                                                         "declared": [fn.open for fn in declared]},
                                                        separators=(",", ":")))
        return self._refs[name]


class TextSource:
    """The files observer_count reads, from texts in memory ({path: Swift text}; paths outside SCOPE's Sources,
    CmuxNext's when SCOPE is None, ignored)."""

    def __init__(self, texts: dict[str, str], scope: "ReadPaths | None" = None) -> None:
        self.texts = {p: t for p, t in texts.items() if is_source(p, scope)}
        self._mentions: dict[str, set[str]] = collections.defaultdict(set)
        self._files: dict[str, ObserverFile] = {}

    def initial(self, hint: set[str]) -> list[str]:
        self.search(hint)
        return sorted(p for p, t in self.texts.items() if _RAW_OBSERVER_LINE.search(t))

    def search(self, names: set[str]) -> None:
        if names:
            pattern = re.compile(call_pattern(names))
            for path, text in self.texts.items():
                found = set(pattern.findall(text))
                if found:
                    self._mentions[path] |= found

    def mentions(self) -> dict[str, set[str]]:
        return self._mentions

    def mentioned(self, path: str) -> set[str]:
        return self._mentions.get(path, set())

    def file(self, path: str) -> ObserverFile | None:
        if path not in self._files and path in self.texts:
            self._files[path] = ObserverFile(path, self.texts[path])
        return self._files.get(path)

    def decl_counts(self, names: set[str]) -> dict[str, int]:
        found = func_decls(self.texts.values(), names)
        return {n: found.get(n, 0) for n in names}


def names_pattern(names: set[str]) -> str:
    """PCRE (and Python) for a `func NAME` declaration or a mention of one of NAMES: name_matches reads its matches."""
    alternation = "|".join(sorted(re.escape(n) for n in names))
    return rf"\bfunc[ \t]+(?:{alternation})\b|(?<![\w$])(?:{alternation})(?![\w])"


def name_matches(matches, names: set[str], mentions: dict[str, set[str]], decls: dict[str, collections.Counter]) -> None:
    """Folds the (path, match) results of names_pattern(NAMES) into MENTIONS ({path: names}) and DECLS ({name: {path:
    `func name` declarations}}, every one of NAMES given a counter): a declaration is a mention too."""
    for n in names:
        decls.setdefault(n, collections.Counter())
    for path, match in matches:
        name = match.split()[-1]
        if match.startswith("func") and name in names and match != name:
            decls[name][path] += 1
        mentions[path].add(name)


def git_blob_id(data: bytes) -> str:
    """The object id git gives a blob with content DATA (the facts cache key of an unchanged worktree file)."""
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


class StandIn:
    """The tracked Swift sources that both ends of a count share outside their overlays: the worktree at ROOT
    (WORKTREE True: its files equal HEAD outside the dirty ones) or the tree at REV. Greps run once per name and are
    shared by the ends; a file's facts come from CACHE by its blob (in the worktree, the git id of its bytes: no
    `ls-tree`, and the file is read only for that hash and, on a cache miss, its parse). SCOPE (ReadPaths) names
    the Sources directories it greps: both ends' closures (a file of a package in one closure only is in both
    overlays, so the union is safe)."""

    def __init__(self, git: "Git", root: Path, rev: str, worktree: bool, cache: "FactsCache | None",
                 scope: "ReadPaths") -> None:
        self.git, self.root, self.rev, self.worktree, self.cache = git, root, rev, worktree, cache
        self.scope = scope
        self.mentions: dict[str, set[str]] = collections.defaultdict(set)
        self.searched: set[str] = set()
        self.raw_paths: set[str] = set()
        self._decls: dict[str, collections.Counter] = {}  # name -> {path: `func name` declarations}
        self._files: dict[str, ObserverFile] = {}
        self._blobs: dict[str, str] | None = None
        self._texts: dict[str, str | None] = {}
        self._initial = None
        self._merged = False

    def _grep(self, pattern: str) -> list[tuple[str, str]]:
        args = ["grep", "-z", "-o", "-I", "-P", "-e", pattern] + ([] if self.worktree else [self.rev])
        r = subprocess.run(["git", "-C", str(self.root), *args, "--", *self.scope.pathspecs()], capture_output=True)
        if r.returncode not in (0, 1):
            raise RuntimeError(f"git grep: {r.stderr.decode(errors='replace').strip()}")
        prefix = "" if self.worktree else f"{self.rev}:"
        out = []
        for line in r.stdout.decode(errors="replace").splitlines():
            path, _, match = line.partition("\0")
            out.append((path[len(prefix):] if prefix and path.startswith(prefix) else path, match))
        return out

    def start(self, hint: set[str], pool: concurrent.futures.ThreadPoolExecutor | None = None) -> None:
        """Start the first greps, on POOL when given: the files with a raw registration line, and the mentions and
        `func` declarations of HINT (two greps: one alternation would let a raw match such as `.observe(` swallow a
        mention of `observe`)."""
        def run(pattern: str):
            return pool.submit(self._grep, pattern) if pool is not None else self._grep(pattern)
        self._initial = (set(hint), run(RAW_OBSERVER_LINE), run(names_pattern(hint)) if hint else None)

    def initial(self, hint: set[str]) -> None:
        """Take the first greps' answers (started by start, or now): the raw registration paths and HINT's mentions."""
        if self._merged:
            self.search(hint)
            return
        if self._initial is None or self._initial[0] != set(hint):
            self.start(hint)
        searched, raw, named = self._initial
        self._initial, self._merged = None, True
        for path, _ in (raw.result() if isinstance(raw, concurrent.futures.Future) else raw):
            self.raw_paths.add(path)
        if named is not None:
            name_matches(named.result() if isinstance(named, concurrent.futures.Future) else named, searched,
                         self.mentions, self._decls)
        self.searched |= searched

    def search(self, names: set[str]) -> None:
        """Greps the mentions (and `func` declarations) of the NAMES not searched yet."""
        names = set(names) - self.searched
        if names:
            name_matches(self._grep(names_pattern(names)), names, self.mentions, self._decls)
            self.searched |= names

    def decl_counts(self, names: set[str]) -> dict[str, collections.Counter]:
        """{name: {path: `func name` declarations}} for NAMES in the stand-in tree (a searched name is known; one grep
        for the rest)."""
        new = set(names) - set(self._decls)
        if new:
            for n in new:
                self._decls[n] = collections.Counter()
            for path, match in self._grep(FUNC_DECLARATION.format(names="|".join(sorted(map(re.escape, new))))):
                self._decls[match.split()[-1]][path] += 1
        return {n: self._decls[n] for n in names}

    def blob(self, path: str) -> str | None:
        """PATH's blob id in the stand-in tree (the facts cache key), None when it has no such file."""
        if self.worktree:
            if path not in self._texts:
                try:
                    data = (self.root / path).read_bytes()
                except OSError:
                    data = None
                self._texts[path] = None if data is None else data.decode(errors="replace")
                if data is not None:
                    self._blobs = self._blobs or {}
                    self._blobs[path] = git_blob_id(data)
            return (self._blobs or {}).get(path)
        if self._blobs is None:
            self._blobs = self.git.swift_blobs(self.rev, self.scope)
        return self._blobs.get(path)

    def _read(self, path: str) -> str | None:
        if self.worktree:
            self.blob(path)
            return self._texts.get(path)
        if path not in self._texts:
            # One `git cat-file --batch` for every file made so far that has not been read.
            todo = [p for p in self._files if p not in self._texts] + ([path] if path not in self._files else [])
            got = self.git.read([(self.rev, p) for p in todo])
            for p in todo:
                self._texts[p] = got.get((self.rev, p))
        return self._texts[path]

    def file(self, path: str) -> ObserverFile:
        if path not in self._files:
            self._files[path] = ObserverFile(path, blob=self.blob(path), load=lambda p=path: self._read(p),
                                             cache=self.cache)
        return self._files[path]


class EndSource:
    """The files observer_count reads at one end of a count: the stand-in tree, with OVERLAY ({path: its
    ObserverFile at this end, or None when absent there}) standing in for the files that differ (a range's changed
    files and the worktree's dirty ones)."""

    def __init__(self, stand: StandIn, overlay: dict[str, ObserverFile | None]) -> None:
        self.stand = stand
        self.overlay = overlay
        self._mentions: dict[str, set[str]] = collections.defaultdict(set)  # overlay files
        self._searched: set[str] = set()

    def initial(self, hint: set[str]) -> list[str]:
        self.stand.initial(hint)
        self.search(hint)
        paths = {p for p in self.stand.raw_paths if p not in self.overlay}
        paths |= {p for p, f in self.overlay.items() if f is not None and _RAW_OBSERVER_LINE.search(f.text())}
        return sorted(paths)

    def search(self, names: set[str]) -> None:
        self.stand.search(names)
        new = set(names) - self._searched
        if new:
            pattern = re.compile(call_pattern(new))
            for path, f in self.overlay.items():
                if f is not None:
                    found = set(pattern.findall(f.text()))
                    if found:
                        self._mentions[path] |= found
            self._searched |= new

    def mentions(self) -> dict[str, set[str]]:
        out = {p: names for p, names in self.stand.mentions.items() if p not in self.overlay}
        out.update(self._mentions)
        return out

    def mentioned(self, path: str) -> set[str]:
        if path in self.overlay:
            return self._mentions.get(path, set())
        return self.stand.mentions.get(path, set())

    def file(self, path: str) -> ObserverFile | None:
        if path in self.overlay:
            return self.overlay[path]
        return self.stand.file(path)

    def decl_counts(self, names: set[str]) -> dict[str, int]:
        per_path = self.stand.decl_counts(names)
        texts = [f.text() for f in self.overlay.values() if f is not None]
        extra = func_decls(texts, set(names))
        return {n: sum(c for p, c in per_path[n].items() if p not in self.overlay) + extra.get(n, 0) for n in names}


def observer_count(source, hint: set[str] = frozenset()) -> Observers:
    """The observer registrations at one revision (the observer_sites row), from SOURCE (TextSource or EndSource).

    resolve_observers needs every file that has a raw registration or can reference a wrapper: the files with a
    raw registration line, then the files that can see a shared wrapper found so far by a name they mention (one
    search per round for the names not searched yet), until no new name and no new file show up. HINT names the
    wrappers a record listed (arch-ratchet.json `observer_wrappers`): searched in the first round, a speed hint only
    (a name it misses is searched for in the next round; a name that is no wrapper loads no file).
    """
    files: dict[str, ObserverFile] = {}
    tried: set[str] = set()
    searched = set(hint)
    paths = source.initial(set(hint))
    while True:
        for path in paths:
            tried.add(path)
            f = source.file(path)
            if f is not None:
                files[path] = f
        found = resolve_observers(files, source.mentioned, source.decl_counts)
        new = found.search_names() - searched
        source.search(new)
        searched |= new
        paths = sorted(p for p, names in source.mentions().items() if p not in tried and found.sees(p, names))
        if not paths and not new:
            return found


def observer_registrations(texts: dict[str, str], scope: "ReadPaths | None" = None) -> Observers:
    """The observer registrations of TEXTS ({repo-relative path: Swift source} under SCOPE's Sources, CmuxNext's when
    SCOPE is None): the observer_sites row.

    The one observer counter: count_texts (codebase-health.py's section 1), codebase-health.py's section 2 and the
    ratchet's full and delta counts all resolve registrations this way.
    """
    return observer_count(TextSource(texts, scope))


def recorded_wrappers(text: str | None) -> set[str]:
    """The `observer_wrappers` of an arch-ratchet.json TEXT: a speed hint for observer_count, never trusted."""
    try:
        names = json.loads(text or "{}").get("observer_wrappers", [])
    except (ValueError, AttributeError):
        return set()
    return {n for n in names if isinstance(n, str) and re.fullmatch(r"[A-Za-z_]\w*", n)} if isinstance(names, list) else set()


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
    """A path in the module PACKAGE that declares nothing: TypeTable resolves it to the module's declarations
    (package_of reads the module from the path, whichever closure package holds it)."""
    return f"Sources/{package}/"


def repo_type_name(name: str | None) -> bool:
    """True when NAME could be a repo type (worth a lookup)."""
    return bool(name) and name[:1].isupper() and name not in SYS_STATEFUL and name not in VALUE_NAMES \
        and name not in CONTAINERS and not SYSTEM_PREFIX.match(name)


def lookup_name(name: str | None) -> bool:
    """True when NAME has declarations worth a lookup: a possible repo type or a `func:` result link."""
    return bool(name) and (name.startswith(FUNC) or repo_type_name(name))


def static_name(package: str, static: Static) -> str:
    """The owner-qualified name of a counted static: `Store.shared` for a static of `Store` (or of an
    `extension Store`), `<package>:cache` for a file-scope global of PACKAGE.

    The one name identity of a static: static_site's `name:` key (the swap rule) and _static_identity (the
    delta cancel) both use it. A bare name would make every `shared` the partner of every other `shared`, so
    removing `Store.shared = Store()` and adding `Hub.shared = Cache()` would read as a retype instead of a
    swap. The owner stays in it when the owner is renamed or the static moves to another type: that is
    another static (see the module docstring, "Site identity").
    """
    return f"{static.owner}.{static.name}" if static.owner else f"{package}:{static.name}"


def static_site(row: str, package: str, path: str, static: Static) -> Site:
    """The site of a counted static of PACKAGE at PATH: it keeps its identity through a rename (by its type)
    or a retype (by its owner and name, static_name)."""
    keys = (f"name:{static_name(package, static)}",) + ((f"type:{static.types[0]}",) if static.types else ())
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
    # (product, package) of every `.product(name:package:)` dependency with string literals: an edge only when the
    # package is local and in the closure (closure_manifest resolves it to the product's targets).
    products: set[tuple[str, str]] = dataclasses.field(default_factory=set)
    # The repo path of the Package.swift that declares the target (closure_manifest; MANIFEST for one manifest).
    manifest: str = MANIFEST


@dataclasses.dataclass
class Manifest:
    """The targets of a Package.swift, read statically (`parse_manifest`), or of every closure manifest
    (`closure_manifest`)."""

    targets: dict[str, ManifestTarget]
    # Constructs outside any dependency list that the static reader cannot account for:
    # {normalized text: (1-based line, why)}.
    unreadable: dict[str, tuple[int, str]] = dataclasses.field(default_factory=dict)
    # {product name: the target names it exposes} from `Package(products:)`'s `.library(`/`.executable(` calls.
    products: dict[str, list[str]] = dataclasses.field(default_factory=dict)

    def edges(self) -> set[tuple[str, str]]:
        """(source, dependency) for every dependency name of a target that is not a test target."""
        return {(name, dep) for name, t in self.targets.items() if t.kind != "testTarget" for dep in t.deps}

    def source_dir(self, name: str) -> str:
        """The repo path of NAME's sources: its `path:` or Sources/<name> in the package that declares it,
        without a trailing slash."""
        target = self.targets.get(name)
        relative = target.path if target is not None and target.path else f"Sources/{name}"
        package = target.manifest.rsplit("/", 1)[0] if target is not None else PACKAGE_DIR
        return f"{package}/{relative.strip('/')}"


def parse_manifest(raw: str) -> Manifest:
    """The targets of a Package.swift and their in-package dependency names, read without swift.

    Targets come from every `.target(`/`.executableTarget(`/... call that is not inside another one
    (a dependency's `.target(name:)` is), including calls bound to top-level variables
    (`let appFFI: Target = .binaryTarget(...)`). A `dependencies:` value is array literals and
    top-level `let` `[Target.Dependency]` variables joined by `+`; string literals, `.target(name:)` and
    `.byName(name:)` name targets, `.product(name:package:)` entries name another package's product and
    go to `products` (closure_manifest makes an edge of one whose package is local). A `var`
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
                    product = re.match(r"^\.product\s*\((.*)\)$", element, re.S)
                    if name is not None:
                        target.deps.add(name)
                    elif call and _string_value(_labeled(call.group(2)).get("name", "")) is not None:
                        target.deps.add(_string_value(_labeled(call.group(2))["name"]))
                    elif product:
                        args = _labeled(product.group(1))
                        pname, pkg = _string_value(args.get("name", "")), _string_value(args.get("package", ""))
                        if pname is not None and pkg is not None:
                            target.products.add((pname, pkg))
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

    products: dict[str, list[str]] = {}
    package = _PACKAGE_CALL.search(code)
    if package:
        open_index = package.end() - 1
        close = _closing(code, open_index)
        package_args = _labeled(code[open_index + 1:close])
        # Every product call in the `products:` value, also in both arms of a ternary (their union).
        offered = package_args.get("products", "")
        for m in _PRODUCT_CALL.finditer(offered):
            args = _labeled(offered[m.end():_closing(offered, m.end() - 1)])
            pname = _string_value(args.get("name", ""))
            listed_targets = args.get("targets", "").strip()
            if pname is not None and listed_targets.startswith("["):
                names = [_string_value(e) for e in _split_top(listed_targets[1:-1], ",")]
                products.setdefault(pname, [])
                products[pname] += [n for n in names if n is not None and n not in products[pname]]
        listed = package_args.get("targets")
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
    return Manifest(targets, unreadable, products)


_PRODUCT_CALL = re.compile(r"\.(?:library|executable)\s*\(")
_PACKAGE_DEPENDENCY = re.compile(r"(?<![\w.])\.package\s*\(")


def local_dependencies(raw: str, package_dir: str) -> dict[str, str]:
    """{identity: repo path} of the local `.package(path:)` dependencies of the Package.swift RAW in PACKAGE_DIR.

    Every `.package(` call with a string `path:` counts, wherever it is (a `package.dependencies.append(...)` under
    a condition too: the closure errs toward reading more). The path resolves against PACKAGE_DIR; one that leaves
    the repository (absolute, or `..` past its root) is not read. The identity is what a `.product(package:)` names:
    the lowercased last path component, and the lowercased `name:` when the call has one.
    """
    code = strip(raw, keep_strings=True)
    out: dict[str, str] = {}
    for m in _PACKAGE_DEPENDENCY.finditer(code):
        args = _labeled(code[m.end():_closing(code, m.end() - 1)])
        path = _string_value(args.get("path", ""))
        if not path or path.startswith("/"):
            continue
        resolved = posixpath.normpath(posixpath.join(package_dir, path))
        if resolved == ".." or resolved.startswith("../") or resolved == ".":
            continue
        out.setdefault(resolved.rsplit("/", 1)[-1].lower(), resolved)
        name = _string_value(args.get("name", ""))
        if name:
            out.setdefault(name.lower(), resolved)
    return out


class AmbiguousModule(ValueError):
    """A Swift module (a Sources directory, or a target name) that two closure packages declare: the counts would
    merge them into one package, so the count stops and names both instead."""


def closure_manifest(manifests: dict[str, str | None]) -> Manifest:
    """The targets of every manifest in MANIFESTS ({Package.swift repo path: text or None}) as one Manifest.

    Each target keeps the path of the manifest that declares it (ManifestTarget.manifest). A `.product(name: P,
    package: Q)` dependency becomes an edge when Q is a local dependency of the declaring manifest
    (local_dependencies) whose manifest is in MANIFESTS: to the targets Q's `products:` lists for P, else to Q's
    target named P; a product of a remote package (or of a package not read) is no edge. A target name that two
    manifests declare (test targets aside) raises AmbiguousModule. `unreadable` is the root manifest's (MANIFEST):
    the layer gate judges only that one.
    """
    parsed = {path: parse_manifest(text) for path, text in manifests.items() if text is not None}
    by_dir = {path.rsplit("/", 1)[0]: m for path, m in parsed.items()}
    merged: dict[str, ManifestTarget] = {}
    for path in sorted(parsed, key=lambda p: (p != MANIFEST, p)):
        m = parsed[path]
        local = local_dependencies(manifests[path] or "", path.rsplit("/", 1)[0]) if any(
            t.products for t in m.targets.values()) else {}
        for name, t in m.targets.items():
            if t.kind == "testTarget":
                continue
            if name in merged:
                raise AmbiguousModule(f"the target {name} is declared by {merged[name].manifest} and by {path}; the "
                                      f"counts would merge them into one package")
            target = dataclasses.replace(t, deps=set(t.deps), manifest=path)
            for product, package in sorted(t.products):
                exposing = by_dir.get(local.get(package.lower(), ""))
                if exposing is None:
                    continue
                target.deps.update(exposing.products.get(product) or ([product] if product in exposing.targets else []))
            merged[name] = target
    root = parsed.get(MANIFEST)
    return Manifest(merged, root.unreadable if root else {}, {})


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
    # When the map does not parse: whether an earlier map that parses classified the edges (`placing_map`).
    edges_from_earlier: bool = False
    # {target: the Package.swift that declares it}: an edge's site is its source target's manifest.
    manifest_of: dict[str, str] = dataclasses.field(default_factory=dict)

    def edges_unknown(self) -> str | None:
        """Why the edge rows (EDGE_ROWS) have no value here, or None when they do.

        A map that does not parse places nothing; its edges are classified by the newest earlier map that
        parses (`placing_map`), the value the edges had before it broke. Only when no earlier map parses
        either are its edges unknown (not 0), and a delta over such an end does not judge the edge rows."""
        return f"{LAYERS_JSON} does not parse ({self.error})" if self.error and not self.edges_from_earlier else None

    def sites(self) -> list[Site]:
        out = []
        for row, edges in (("layer_hard", self.hard), ("layer_soft", self.soft), ("layer_upward", self.upward)):
            out += [Site(row, self.manifest_of.get(a, MANIFEST), 0, f"{a} ({la}) -> {b} ({lb})", (f"edge:{a}->{b}",))
                    for a, la, b, lb in edges]
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


def layers(manifest_raw: str | dict[str, str | None] | None, layers_raw: str | None,
           earlier_raw: str | None = None) -> Layers:
    """The layer edges of the manifests under a layers json (`closure_manifest`, `LayerMap`, `edge_class`).

    MANIFEST_RAW is {Package.swift repo path: text} of every closure manifest (ReadPaths.manifests), or one text,
    MANIFEST's (codebase-health.py and older callers: CmuxNext alone). EARLIER_RAW is the newest earlier map that
    parses (`placing_map`), for a LAYERS_RAW that does not: it classifies the edges then. layer_unplaced reads
    LAYERS_RAW as it is (a broken map places no target)."""
    manifests = manifest_raw if isinstance(manifest_raw, dict) else {MANIFEST: manifest_raw}
    if not any(text is not None for text in manifests.values()) or layers_raw is None:
        return Layers([], [], [], [])
    manifest = closure_manifest(manifests)
    placed = LayerMap.parse(layers_raw)
    classifier = placed
    if placed.error and earlier_raw is not None:
        earlier = LayerMap.parse(earlier_raw)
        classifier = earlier if not earlier.error else placed
    found: dict[str, list[tuple[str, str, str, str]]] = {kind: [] for kind in EDGE_CLASSES}
    for source, dep in sorted(manifest.edges()):
        kind = classifier.classify(source, dep)
        if kind is not None:
            found[kind].append((source, classifier.placed(source), dep, classifier.placed(dep)))
    return Layers(found["hard"], found["soft"], found["upward"], sorted(placed.unmapped(manifest)), placed.error,
                  classifier is not placed, {name: t.manifest for name, t in manifest.targets.items()})


def placing_map(repo: Path | str, rev: str, text: str | None) -> str | None:
    """TEXT (LAYERS_JSON at REV) when it parses or is absent; else the newest LAYERS_JSON that parses in a commit
    before REV that changed it (the map's value before it broke), or None when none does.

    A broken map lands only past the hook (a GitHub merge, --no-verify): the layer gate refuses a head map that
    does not parse. The counts and the gate then judge that end by the layers the targets held before it broke,
    never by an empty map (every edge 0, every relabel unseen)."""
    if text is None or not LayerMap.parse(text).error:
        return text
    git = Git(Path(repo))
    tips = [f"{rev}^@"]
    while True:
        # One commit at a time: the walk stops at the first map that parses (usually the first one).
        sha = git.run("rev-list", "-1", *tips, "--", LAYERS_JSON, check=False).strip()
        if not sha:
            return None
        found = git.read([(sha, LAYERS_JSON)])[(sha, LAYERS_JSON)]
        if found is None:
            return None  # the map did not exist before it broke
        if not LayerMap.parse(found).error:
            return found
        tips = [f"{sha}^@"]


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
        # Through a file, never `input=`: over a pipe a big answer can deadlock (check-leo-bans.py).
        with tempfile.TemporaryFile() as stdin:
            stdin.write(data)
            stdin.seek(0)
            r = subprocess.run(["git", "-C", str(self.repo), "cat-file", "--batch"], stdin=stdin, capture_output=True)
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

    def swift_blobs(self, rev: str, scope: "ReadPaths") -> dict[str, str]:
        """{path: blob id} of the Swift files under every Sources directory of SCOPE at REV."""
        return self.swift_blobs_under(rev, scope.sources)

    def swift_blobs_under(self, rev: str, dirs) -> dict[str, str]:
        """{path: blob id} of the Swift files under DIRS at REV (one `ls-tree`)."""
        dirs = list(dirs)
        if not dirs:
            return {}
        out = self.run("ls-tree", "-r", "-z", rev, "--", *dirs)
        blobs: dict[str, str] = {}
        for entry in out.split("\0"):
            meta, _, path = entry.partition("\t")
            fields = meta.split()
            if path.endswith(".swift") and len(fields) == 3 and fields[1] == "blob":
                blobs[path] = fields[2]
        return blobs

    def swift_files(self, rev: str, scope: "ReadPaths") -> list[str]:
        return sorted(self.swift_blobs(rev, scope))

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


def is_source(path: str, scope: "ReadPaths | None" = None) -> bool:
    """True when PATH is a counted Swift source: under a Sources directory of SCOPE (read_paths), or, SCOPE None,
    of CmuxNext alone (count_texts' working-tree callers)."""
    if scope is not None:
        return scope.is_source(path)
    return path.startswith(SOURCES + "/") and path.endswith(".swift")


def is_counted(path: str, scope: "ReadPaths | None" = None) -> bool:
    """True when a change to PATH can change a count: a Swift source or a count input of SCOPE (every closure
    manifest), or one of COUNTED_PATHS. SCOPE None (a caller with no revision): a superset, any Package.swift and
    any Swift file under a Sources directory, since any of them can be in some revision's closure."""
    if scope is not None:
        return scope.is_counted(path)
    return (path in COUNTED_PATHS or posixpath.basename(path) == "Package.swift"
            or (path.endswith(".swift") and (path.startswith("Sources/") or "/Sources/" in path)))


# ---------------------------------------------------------------------------------------------------
# What a count reads: the local package closure


@dataclasses.dataclass(frozen=True)
class ReadPaths:
    """What a count at REV reads (read_paths): CmuxNext and the transitive closure of its local `.package(path:)`
    dependencies, each package's Package.swift and Sources, the layer map, the ratchet record and this file.

    PACKAGES are the closure's package directories, PACKAGE_DIR first (it is in the closure without a manifest
    too). MANIFESTS is {Package.swift path: blob id} of each one that has a manifest at REV. MODULES is {module
    directory under a Sources: the packages whose Sources has it}; two packages for one name is AmbiguousModule
    (check). Derived from the manifests alone, so a range that changes no Package.swift keeps its base's closure.
    """

    rev: str
    packages: tuple[str, ...]
    manifests: dict[str, str]
    modules: dict[str, tuple[str, ...]]

    @property
    def sources(self) -> tuple[str, ...]:
        """The Sources directory of every closure package (the counted Swift is under them)."""
        return tuple(f"{p}/Sources" for p in self.packages)

    @property
    def count_inputs(self) -> tuple[str, ...]:
        """Every closure manifest (MANIFEST first) and the layer map: what the layer rows read besides Swift."""
        return tuple(sorted(self.manifests, key=lambda p: (p != MANIFEST, p))) + (LAYERS_JSON,)

    @property
    def counted_paths(self) -> tuple[str, ...]:
        """count_inputs and the row definitions: every non-Swift path whose change can change a count."""
        return self.count_inputs + (METHOD_FILE,)

    @property
    def files(self) -> tuple[str, ...]:
        """Every single file a count reads (the Swift aside): count_inputs, the ratchet record (its observer hint)
        and this file."""
        return self.count_inputs + (RATCHET_JSON, METHOD_FILE)

    def package_dir(self, path: str) -> str | None:
        """The closure package whose Sources holds PATH, or None."""
        found = [p for p in self.packages if path.startswith(p + "/Sources/")]
        return max(found, key=len) if found else None

    def is_source(self, path: str) -> bool:
        return path.endswith(".swift") and self.package_dir(path) is not None

    def is_counted(self, path: str) -> bool:
        """True when a change to PATH can change a count at this revision: a closure Swift source, a closure
        manifest (a Package.swift anywhere can join or leave the closure only through one of these), the layer map
        or this file."""
        return self.is_source(path) or path in self.counted_paths

    def pathspecs(self) -> list[str]:
        """git pathspecs of the counted Swift (`git grep`, `git diff`)."""
        return [f"{s}/*.swift" for s in self.sources]

    def ambiguous(self) -> dict[str, tuple[str, ...]]:
        return {m: pkgs for m, pkgs in self.modules.items() if len(pkgs) > 1}

    def check(self) -> None:
        """Raise AmbiguousModule when a module directory is in two closure packages."""
        found = self.ambiguous()
        if found:
            raise AmbiguousModule("; ".join(f"the module {m} is in {' and '.join(f'{p}/Sources' for p in pkgs)}"
                                            for m, pkgs in sorted(found.items()))
                                  + f" at {self.rev[:11]}: the counts would merge them into one package")

    def union(self, other: "ReadPaths") -> "ReadPaths":
        """Both closures' packages and manifests (the stand-in tree of a delta greps both)."""
        modules = collections.defaultdict(set)
        for side in (self, other):
            for m, pkgs in side.modules.items():
                modules[m].update(pkgs)
        packages = (PACKAGE_DIR,) + tuple(sorted((set(self.packages) | set(other.packages)) - {PACKAGE_DIR}))
        return ReadPaths(other.rev, packages, {**self.manifests, **other.manifests},
                         {m: tuple(sorted(p)) for m, p in sorted(modules.items())})

    def with_added(self, rev: str, paths) -> "ReadPaths":
        """This closure at REV, a descendant whose range changes no Package.swift, with the modules of the added
        PATHS. Modules a range empties stay listed, so an ambiguity here may be a module the range moved between
        packages: _scope_after reads REV's trees then."""
        modules = {m: set(pkgs) for m, pkgs in self.modules.items()}
        for path in paths:
            pkg = self.package_dir(path)
            rest = path[len(pkg) + len("/Sources/"):] if pkg else ""
            if "/" in rest:
                modules.setdefault(rest.split("/", 1)[0], set()).add(pkg)
        return ReadPaths(rev, self.packages, self.manifests, {m: tuple(sorted(p)) for m, p in sorted(modules.items())})

    def to_json(self) -> str:
        return json.dumps([list(self.packages), self.manifests, self.modules], separators=(",", ":"))

    @classmethod
    def from_json(cls, rev: str, text: str) -> "ReadPaths":
        packages, manifests, modules = json.loads(text)
        return cls(rev, tuple(packages), dict(manifests), {m: tuple(p) for m, p in modules.items()})


GIT_BATCH_TIMEOUT = 60.0  # seconds one `cat-file --batch` round may take; a stuck git fails the count open, not the push


class _ObjectReader:
    """`git cat-file --batch` asked in rounds: the closure walk learns a manifest's dependencies only after it
    reads it. Each round's request goes through a file and the answers are drained whole (never `stdin=PIPE`
    written before reading): a round of many manifests and Sources trees is bigger than a pipe, and writing it
    while git sat blocked writing answers into a full stdout pipe deadlocked every push's arch ratchet on
    2026-10-28 (a796, a801, a804, a808: "ran past 20s"). One spawn per round; the rounds are the closure's depth."""

    def __init__(self, repo: Path, timeout: float = GIT_BATCH_TIMEOUT) -> None:
        self.repo = repo
        self.timeout = timeout

    def ask(self, specs: list[str]) -> list[tuple[str, str, bytes] | None]:
        """[(object id, type, content) or None (missing)] for SPECS (`rev:path`).

        Raises subprocess.TimeoutExpired when git does not answer within the timeout (the ratchet fails open)."""
        if not specs:
            return []
        with tempfile.TemporaryFile() as stdin:
            stdin.write("".join(f"{s}\n" for s in specs).encode())
            stdin.seek(0)
            data = subprocess.run(["git", "-C", str(self.repo), "cat-file", "--batch"], stdin=stdin,
                                  capture_output=True, timeout=self.timeout).stdout
        out: list[tuple[str, str, bytes] | None] = []
        at = 0
        for _ in specs:
            nl = data.find(b"\n", at)
            if nl < 0:
                out.append(None)  # git died early: the rest are unanswered
                continue
            header = data[at:nl].decode(errors="replace").split()
            at = nl + 1
            if len(header) < 3 or not header[-1].isdigit():
                out.append(None)  # `<spec> missing`
                continue
            size = int(header[2])
            out.append((header[0], header[1], data[at:at + size]))
            at += size + 1
        return out

    def close(self) -> None:
        """Nothing to release: each round's git process has exited when ask() returns."""


def _tree_dirs(data: bytes, oid_bytes: int) -> list[str]:
    """The subdirectory names of a raw tree object (`<mode> <name>\\0<oid>` entries)."""
    out, i = [], 0
    while i < len(data):
        space = data.index(b" ", i)
        nul = data.index(b"\0", space)
        if data[i:space] == b"40000":
            out.append(data[space + 1:nul].decode(errors="replace"))
        i = nul + 1 + oid_bytes
    return out


def _walk_closure(git: Git, sha: str) -> ReadPaths:
    """The closure at the commit SHA from git objects: a breadth-first walk of the `.package(path:)` dependencies
    (local_dependencies) from PACKAGE_DIR; a path with no Package.swift at SHA is not a package. Each round reads
    its packages' manifests and Sources trees through one cat-file process."""
    reader = _ObjectReader(git.repo)
    packages: list[str] = []
    manifests: dict[str, str] = {}
    modules: dict[str, set[str]] = collections.defaultdict(set)
    try:
        todo, seen = [PACKAGE_DIR], {PACKAGE_DIR}
        while todo:
            got = reader.ask([f"{sha}:{p}/Package.swift" for p in todo] + [f"{sha}:{p}/Sources" for p in todo])
            following = []
            for i, package in enumerate(todo):
                manifest, tree = got[i], got[len(todo) + i]
                has_manifest = manifest is not None and manifest[1] == "blob"
                if not has_manifest and package != PACKAGE_DIR:
                    continue
                packages.append(package)
                if tree is not None and tree[1] == "tree":
                    for name in _tree_dirs(tree[2], len(tree[0]) // 2):
                        modules[name].add(package)
                if has_manifest:
                    manifests[f"{package}/Package.swift"] = manifest[0]
                    for dep in sorted(set(local_dependencies(manifest[2].decode(errors="replace"), package).values())):
                        if dep not in seen:
                            seen.add(dep)
                            following.append(dep)
            todo = following
    finally:
        reader.close()
    return ReadPaths(sha, (PACKAGE_DIR,) + tuple(sorted(set(packages) - {PACKAGE_DIR})), manifests,
                     {m: tuple(sorted(p)) for m, p in sorted(modules.items())})


def _scope(git: Git, sha: str, store: "FactsCache | None") -> ReadPaths:
    """read_paths at the commit SHA: from STORE (a commit's closure never changes), else _walk_closure."""
    key = f"read-paths:{sha}"
    text = store.get_text(key) if store is not None else None
    if text:
        try:
            return ReadPaths.from_json(sha, text)
        except (ValueError, TypeError, AttributeError):
            pass
    scope = _walk_closure(git, sha)
    if store is not None:
        store.put_text(key, scope.to_json())
    return scope


def _scope_after(git: Git, head: str, before: ReadPaths, files: list[tuple[str, str]],
                 store: "FactsCache | None") -> ReadPaths:
    """read_paths at HEAD, a descendant of BEFORE's revision whose range changes FILES ([(status, path)]). A range
    that changes no Package.swift keeps BEFORE's closure (only manifests make it), with the modules its added files
    bring; when those look ambiguous (maybe a module moved between packages), and on any manifest change, HEAD's own
    trees decide."""
    if not any(posixpath.basename(p) == "Package.swift" for _, p in files):
        derived = before.with_added(head, [p for status, p in files if status == "A"])
        if not derived.ambiguous():
            return derived
    return _scope(git, head, store)


def read_paths(repo: Path | str, rev: str = "HEAD", cache: bool = True) -> ReadPaths:
    """What a count at REV reads (ReadPaths): the local package closure, read statically from git objects at REV.

    The one source of the scope: full_count, delta_count, arch-ratchet.py (measured_in_range, raised_by) and the
    perf cron's prefetch (`--read-paths`) all use it. Kept in FactsCache by commit (CACHE False: walked again).
    """
    git = Git(Path(repo))
    store = FactsCache(git, cache)
    try:
        return _scope(git, git.rev(rev), store)
    finally:
        store.flush()


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

    def get_text(self, key: str) -> str | None:
        """The text stored under KEY (an ObserverFile fact), or None."""
        if key in self._new:
            return self._new[key]
        db = self._connect()
        if db is None:
            return None
        try:
            row = db.execute("SELECT value FROM facts WHERE key = ?", (key,)).fetchone()
        except sqlite3.Error:
            self.enabled, self._db = False, None
            return None
        return row[0] if row else None

    def put_text(self, key: str, value: str) -> None:
        if self.enabled:
            self._new[key] = value

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
    # {row: why} for rows this count has no value for (Layers.edges_unknown); a delta does not judge them.
    unknown: dict[str, str] = dataclasses.field(default_factory=dict)
    # The names a full count's shared observer wrappers are found by (Observers.hint_names): recorded in
    # arch-ratchet.json as `observer_wrappers`, a speed hint for the next count's first search.
    observer_wrappers: set[str] = dataclasses.field(default_factory=set)

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
            counts.add_site(static_site(row, facts.package, facts.path, st), facts.package)
    if facts.package == APP_PACKAGE:
        counts.rows["app_lines"][APP_PACKAGE] += facts.lines


def count_observers(counts: Counts, observers: Observers) -> None:
    """Adds the observer_sites of OBSERVERS (observer_count) to COUNTS."""
    for path, sites in observers.sites.items():
        for s in sites:
            counts.add_site(s, package_of(path))
    counts.observer_wrappers |= observers.hint_names()


def count_layers(counts: Counts, lay: Layers) -> None:
    why = lay.edges_unknown()
    if why:
        counts.unknown.update(dict.fromkeys(EDGE_ROWS, why))
    for row, counter in lay.per_package().items():
        counts.rows[row].update(counter)
    for s in lay.sites():
        counts.sites[s.row].append(s)


def count_texts(texts: dict[str, str], manifest_raw: str | dict[str, str | None] | None, layers_raw: str | None,
                observers: Observers | None = None, scope: ReadPaths | None = None) -> tuple[Counts, Layers]:
    """(counts, layers) of TEXTS ({path: Swift text}; paths outside SCOPE's Sources, CmuxNext's when SCOPE is None,
    are ignored) and the manifests (MANIFEST_RAW: as `layers` takes it).

    The full count reads git objects; codebase-health.py passes working-tree texts and read_paths' closure, so every
    report counts with the same method and scope. OBSERVERS is
    observer_registrations(TEXTS) when the caller already has it (codebase-health.py's section 2 reads its
    per-statement hits).
    """
    facts = [analyze(p, t) for p, t in sorted(texts.items()) if is_source(p, scope)]
    counts, lay = count_file_facts(facts, manifest_raw, layers_raw)
    count_observers(counts, observers if observers is not None else observer_registrations(texts, scope))
    return counts, lay


def count_file_facts(facts: list[FileFacts], manifest_raw: str | dict[str, str | None] | None, layers_raw: str | None,
                     earlier_layers: str | None = None) -> tuple[Counts, Layers]:
    """(counts, layers) of every file's FACTS and the manifests (count_texts and full_count). EARLIER_LAYERS is
    `placing_map`'s answer for a LAYERS_RAW that does not parse."""
    index: dict[str, list[Decl]] = collections.defaultdict(list)
    for f in facts:
        for d in f.decls:
            index[d.name].append(d)
    table = TypeTable(lambda name: index.get(name, []))
    counts = Counts.empty()
    for f in facts:
        count_facts(counts, f, table)
    lay = layers(manifest_raw, layers_raw, earlier_layers)
    count_layers(counts, lay)
    return counts, lay


def full_count(repo: Path, rev: str = "HEAD", cache: bool = True) -> tuple[str, Counts, Layers]:
    """(sha, counts, layers) of every file of the local package closure at REV (read_paths; facts of contents seen
    before come from FactsCache). Raises AmbiguousModule when two closure packages hold one module."""
    git = Git(repo)
    sha = git.rev(rev)
    store = FactsCache(git, cache)
    try:
        scope = _scope(git, sha, store)
        scope.check()
        blobs = git.swift_blobs(sha, scope)
        items = [(blobs[p], p) for p in sorted(blobs)]
        found = store.facts(items, git.read_blobs)
        meta = git.read([(sha, p) for p in scope.count_inputs + (RATCHET_JSON,)])
        facts = [found.get(item) or analyze(item[1], "") for item in items]
        counts, lay = count_file_facts(facts, {p: meta[(sha, p)] for p in scope.manifests}, meta[(sha, LAYERS_JSON)],
                                       placing_map(repo, sha, meta[(sha, LAYERS_JSON)]))
        stand = StandIn(git, repo, sha, False, store, scope)
        count_observers(counts, observer_count(EndSource(stand, {}), recorded_wrappers(meta[(sha, RATCHET_JSON)])))
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
    content. SCOPE (ReadPaths) names the Sources directories it greps: both ends' closures.
    """

    def __init__(self, git: Git, worktree: Path | None, revs: tuple[str, str], scope: ReadPaths,
                 cache: FactsCache | None = None) -> None:
        self.git = git
        self.worktree = worktree
        self.revs = revs
        self.scope = scope
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
        args += ["--", *self.scope.pathspecs()]
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
        """Tracked Swift files under the closure's Sources whose text matches the PCRE PATTERN (worktree, else REV)."""
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
        args += ["--", *self.scope.pathspecs()]
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
                self._head_blobs = self.git.swift_blobs(self.revs[1], self.scope)  # one ls-tree: the cache keys
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

    def unknown(self) -> dict[str, str]:
        """{row: why} for rows an end has no value for: the delta does not judge them (0, no sites)."""
        return {**self.after.unknown, **self.before.unknown}

    def total(self, row: str) -> int:
        if row in self.before.unknown or row in self.after.unknown:
            return 0
        return sum(self.after.rows[row].values()) - sum(self.before.rows[row].values())

    def by_package(self, row: str) -> dict[str, int]:
        if row in self.before.unknown or row in self.after.unknown:
            return {}
        keys = set(self.after.rows[row]) | set(self.before.rows[row])
        out = {k: self.after.rows[row][k] - self.before.rows[row][k] for k in sorted(keys)}
        return {k: v for k, v in out.items() if v}

    def unpartnered(self, row: str) -> list[Site]:
        """HEAD sites of ROW that no BASE site of the range accounts for. A partner shares a key (the same
        global by name or by type, the same broadcast literal, the same edge) or, for a site without keys,
        its text. A move, a rename or a retyped global has a partner; a site that replaces a removed one of
        another identity (a swap) has none: it is debt the push adds, whatever the total does."""
        if row in self.before.unknown or row in self.after.unknown:
            return []

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
        if row in self.before.unknown or row in self.after.unknown:
            return []
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


class StaticIdentity(NamedTuple):
    """What makes a static at one end of a range the same static at the other (_static_identity)."""

    package: str
    name: str  # static_name: the owner-qualified name, `<package>:<name>` at file scope
    types: tuple[str, ...]
    keyword: str
    container: bool


def _static_identity(f: FileFacts, st: Static) -> StaticIdentity:
    """A static's package, its name as static_site's `name:` key has it (static_name: the owner and name, or
    the package and name for a file-scope global, so a file moved or renamed within its package keeps its
    globals), and the types, keyword and container that classify() reads.

    Only statics equal by all of these cancel unseen in delta mode. Every other static the range changes is
    classified at its end, so its site carries its own line and Delta.unpartnered judges it: a typeless
    `static var` removed from one type and added to another of the same package (a renamed owner too) is a
    swap there, and the refusal names the static the push added, not the first one of the same shape in the
    file.
    """
    return StaticIdentity(f.package, static_name(f.package, st), st.types, st.keyword, st.container)


def delta_count(repo: Path, base: str, head: str, use_worktree: bool = True, cache: bool = True) -> Delta:
    """Counts of BASE and HEAD over the files BASE..HEAD changes, so after - before is the push's delta.

    Equal to two full counts subtracted. Statics that keep their identity (_static_identity: package,
    owner and name, types, keyword) at both ends cancel without a type lookup; only the others, and the
    types whose declarations the range changes, are looked up. USE_WORKTREE False reads every lookup from HEAD's git
    objects (an audit of old commits: the worktree would differ from them in most files). CACHE False
    analyzes every file it reads instead of reading facts seen before from FactsCache. Each end counts its own
    closure (read_paths); AmbiguousModule when an end's closure holds one module twice.
    """
    git = Git(repo)
    # Started first: it stats every tracked Swift file (the closures are not read yet; _delta keeps the ones under
    # them), and only the observer count and a type lookup wait for it.
    dirty_proc = subprocess.Popen(["git", "-C", str(repo), "diff", "--name-only", "-z", head, "--", "*.swift"],
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
    scopes = {base: _scope(git, base, store)}
    scopes[head] = _scope_after(git, head, scopes[base], files, store)
    for scope in scopes.values():
        scope.check()
    both = scopes[base].union(scopes[head])
    changed_paths = {p for _, p in files if both.is_source(p)}
    # A package in one end's closure only: each Swift file of its Sources counts at that end and is absent at the
    # other, whether the range changes it or not (a Package.swift that links or drops it is the change).
    joined: dict[tuple[str, str], str] = {}
    for r, other in ((base, head), (head, base)):
        only = [f"{p}/Sources" for p in scopes[r].packages if p not in scopes[other].packages]
        for path, blob in git.swift_blobs_under(r, only).items():
            joined[(r, path)] = blob
            changed_paths.add(path)
    changed = sorted(changed_paths)
    before, after = Counts.empty(), Counts.empty()
    if any(p in scopes[base].count_inputs or p in scopes[head].count_inputs for _, p in files):
        # A manifest or the layer map changed: the layer rows at both ends, each over its own closure's manifests.
        texts = git.read_blobs([(b, p) for r in (base, head) for p, b in scopes[r].manifests.items()])
        maps = git.read([(r, LAYERS_JSON) for r in (base, head)])
        for r, counts in ((base, before), (head, after)):
            count_layers(counts, layers({p: texts[(b, p)] for p, b in scopes[r].manifests.items()},
                                        maps[(r, LAYERS_JSON)], placing_map(git.repo, r, maps[(r, LAYERS_JSON)])))
    if not changed:
        return Delta(base, head, files, before, after)
    ends = {(r, p): (joined.get((r, p)) or blobs.get((r, p))) if scopes[r].is_source(p) else None
            for r in (base, head) for p in changed}
    found = store.facts([(b, p) for (_, p), b in ends.items() if b], git.read_blobs)
    facts = {r: {p: (found.get((ends[(r, p)], p)) if ends[(r, p)] else None) for p in changed} for r in (base, head)}
    dirty_memo: list = []

    def dirty_paths() -> tuple[Path | None, list[str]]:
        """(the worktree, or None when it cannot stand in, its dirty sources not changed by the range), once."""
        if not dirty_memo:
            out, root = b"", worktree
            if dirty_proc is not None and root is not None:
                out, _ = dirty_proc.communicate()
                if dirty_proc.returncode != 0:
                    out, root = b"", None
            dirty_memo.append((root, [p for p in out.decode(errors="replace").split("\0")
                                      if both.is_source(p) and p not in facts[head]] if root is not None else []))
        return dirty_memo[0]

    _count_observers(git, base, head, changed, ends, dirty_paths, store, before, after, both)

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
    keys = {r: collections.Counter(_static_identity(f, st) for f in facts[r].values() if f for st in f.statics)
            for r in (base, head)}
    net = {base: keys[base] - keys[head], head: keys[head] - keys[base]}
    wanted = {t for r in (base, head) for k in net[r] for t in k.types}
    if not any(lookup_name(n) for n in wanted | redeclared):
        table = TypeTable(lambda name: [])
        tables = {base: table, head: table}
        lookup = None
    else:
        worktree, dirty = dirty_paths()
        lookup = TypeLookup(git, worktree, (base, head), both, store)
        # The first lookup round and the flip lookup run while the dirty files are read.
        lookup.prefetch_index()
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


def _count_observers(git: Git, base: str, head: str, changed: list[str], ends: dict, dirty_paths, store: FactsCache,
                     before: Counts, after: Counts, scope: ReadPaths) -> None:
    """observer_sites of BASE and HEAD: an observer_count at each end, so their difference is two full counts'.

    Every file outside the range's changed files and the worktree's dirty ones is the same at both ends and in the
    stand-in tree (the worktree when DIRTY_PATHS() gives one, else HEAD's tree), so both ends share its greps and its
    files' facts (FactsCache by blob, parsed once per content); ENDS ({(rev, path): blob or None}) gives the changed
    files at each end and HEAD's blob gives a dirty file at both. A file is read only when its facts are not cached.
    SCOPE is both ends' closures (ReadPaths.union): the stand-in tree's greps cover it.
    """
    worktree, dirty = dirty_paths()
    stand = StandIn(git, worktree or git.repo, head, worktree is not None, store, scope)
    # A speed hint only: the worktree's record (no process) when there is one, else HEAD's.
    try:
        hint_text = (worktree / RATCHET_JSON).read_text() if worktree is not None else None
    except OSError:
        hint_text = None
    if worktree is None:
        hint_text = git.read([(head, RATCHET_JSON)])[(head, RATCHET_JSON)]
    hint = recorded_wrappers(hint_text)
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=2)
    try:
        stand.start(hint, pool)  # the first greps run while the changed and dirty files are read
        # One `git cat-file --batch` for the changed files at both ends and the dirty files (HEAD's content, the
        # same at both ends): EndSource reads every overlay text to find its raw lines and mentions.
        items = [(b, p) for (_, p), b in ends.items() if b]
        texts = git.read_blobs(items)
        dirty_texts = git.read([(head, p) for p in dirty])
        shared_dirty = {p: ObserverFile(p, dirty_texts[(head, p)] or "", blob=stand.blob(p), cache=store)
                        for p in dirty if dirty_texts[(head, p)] is not None}
        overlays = {}
        for r in (base, head):
            overlay: dict[str, ObserverFile | None] = dict(shared_dirty)
            for p in dirty:
                overlay.setdefault(p, None)  # added in the index only: HEAD, and so both ends, lack it
            for p in changed:
                blob = ends.get((r, p))
                overlay[p] = ObserverFile(p, texts[(blob, p)] or "", blob=blob, cache=store) if blob else None
            overlays[r] = overlay
        for r, counts in ((base, before), (head, after)):
            count_observers(counts, observer_count(EndSource(stand, overlays[r]), hint))
    finally:
        pool.shutdown(wait=True)


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
                key = _static_identity(f, st)
                if not flips.intersection(st.types):
                    if left[key] <= 0:
                        continue  # the other end has this very static: it cancels
                    left[key] -= 1
                row = classify(st, f.path, tables[r])
                if row:
                    counts.add_site(static_site(row, f.package, f.path, st), f.package)

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
                            counts.add_site(static_site(row, f.package, f.path, st), f.package)
    return Delta(base, head, files, before, after)


# ---------------------------------------------------------------------------------------------------
# The json record


def record(sha: str, counts: Counts, lay: Layers, exceptions: list | None = None,
           escape_reviews: list | None = None) -> dict:
    """The arch-ratchet.json object for a full count. ESCAPE_REVIEWS (the record of who reviewed each
    blocking_allow_escapes site, its owner and expiry) is kept as the old record has it: --update never writes it."""
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
                 "\"why\": \"...\", \"author\": \"<who wrote it>\", \"owner\": \"<who removes it>\", "
                 "\"receipt\": \"Review (<reviewer, not the author>): SHIP at <40-hex sha>\", \"expiry\": "
                 "\"YYYY-MM-DD\"} to exceptions (an entry with no independent receipt, owner or expiry allows "
                 "nothing); the push that adds it may raise that row by n, and the next "
                 "--update folds it into the totals and marks it with applied_sha (an applied entry is never edited "
                 "or removed). --update refuses a rise that no pending exception covers, except a rise that "
                 "commits already on origin/feat-cmux-next made past the hook (a GitHub merge, --no-verify): it "
                 "records that one with a generated applied entry whose raised_by names those commits. A generated "
                 "entry allows no rise in any push's code, and the push that brings it is re-checked: its commits "
                 "must be on origin/feat-cmux-next, after the old measured_sha and in the new one, named by no "
                 "other entry, and its allow at most their rise. Every blocking_allow_escapes site also needs an "
                 "escape_reviews entry (path, text, owner, author, receipt, expiry, state): a push that adds a site "
                 "with no reviewed entry is refused, and --audit lists unreviewed and expired ones. Never CI."),
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
        "escape_reviews": escape_reviews if escape_reviews is not None else [],
        # A speed hint for the observer count's first search (Observers.hint_names), never trusted.
        "observer_wrappers": sorted(counts.observer_wrappers),
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
    parser.add_argument("--read-paths", action="store_true",
                        help="print what a count at --rev reads as one JSON object: `files` (single files) and `sources` "
                             "(directories whose Swift it reads)")
    args = parser.parse_args(argv)
    repo = Path(args.repo).resolve() if args.repo else Path(
        subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip())
    if args.read_paths:
        scope = read_paths(repo, args.rev)
        print(json.dumps({"rev": scope.rev, "method_version": METHOD_VERSION, "packages": list(scope.packages),
                          "files": list(scope.files), "sources": list(scope.sources)}, sort_keys=True))
        return 0
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

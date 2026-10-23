#!/usr/bin/env python3
"""cmux-next guardrails: refuse new architecture debt in what a push adds; warn on hot paths and owned areas.

Run by the pre-push hook through `prepush-gate.py --pre-push` (and by a plain local `prepush-gate.py`),
never by CI (Lawrence 2026-10-23: no new CI gates). Only Swift lines the push ADDS under
Packages/macOS/CmuxNext/Sources count, plus unchanged lines that become debt because the push changed the
line that gives them their context (a new `while` around a sleep, `struct` -> `class` around a static).
Per file and rule it is a count ratchet: an added match is new only when the same file does not remove as
much debt (judged on the base text with the same context and escape rules, so editing a line that already
has debt adds none, and a removed one-shot delay does not pay for a new poll), and an added line whose
text another file removes as debt is a move. Lines a push only brings in from origin/feat-cmux-next (a
merge or rebase onto it) never count (check_push). Base debt never blocks a push
(plans/cmux-next/codebase-health.md has the counts).

Refusals (rules below, `--list` prints them): each names the rule, why, the right pattern and its escape.
Skip once: CMUX_GUARDRAILS_SKIP_REASON="<rule>[,<rule>]: <why>" skips only the named rules; say it in your
report.
A rule (or warning check) that raises is not applied to that push and prints a `guardrails` warning that names
it; the other rules still run and refuse (fail open per check, so one broken rule never switches off the rest).
Warnings (never refuse):
  perf-hot  the push changes a function marked `// perf-hot: <budget> <path-id>` (a trailing comment on its
            declaration line, or in the comment block above it); names the bench from scripts/cmux-next/perf-hot-benches.json to run before
            and after on the fleet.
  owner     the push touches an area in plans/cmux-next/OWNERS.md; names the owner and the doc to read.

`app-size` is a net count over the push, not a per-line rule, in source lines as CI's check-app-size.sh --base
counts them (count-swift-code-lines.py's lexer: blank and comment lines never count, either way). It refuses
when the root (top-level AppDelegate, CmuxNextApp and AppServices(+X).swift) adds more than ROOT_BUDGET lines per
push (lines moved into it from feature files count; lines moved out are free), and when a new App file is
neither a move nor the push's one AppServices+<Domain>Host.swift of one-line forwards (outside the budget), so
feature logic does not become wiring by moving into a root file. It warns (never refuses, for now) when the App
outside the root or CmuxNextApp as a whole grows (the same total check-app-size.sh --base computes, a split
file's new imports included), with the bytes added and the package the code goes to. This is the only App-size
limit in force on a push: CI's check-app-size.sh step is continue-on-error and its absolute cap
(app-size-baseline.txt) is below the App's size today.

  scripts/cmux-next/guardrails.py                    # what HEAD adds over origin/feat-cmux-next
  scripts/cmux-next/guardrails.py --base A --head B
  scripts/cmux-next/guardrails.py --list
"""
from __future__ import annotations

import argparse
import collections
import importlib.util
import itertools
import json
import os
import re
import subprocess
import sys
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

SOURCES = "Packages/macOS/CmuxNext/Sources/"
# The rules read Swift only: the string catalogs under Sources are MBs of JSON per localization push.
SWIFT_SOURCES = f":(glob){SOURCES}**/*.swift"
TESTS = "Packages/macOS/CmuxNext/Tests/"
SWIFT_TESTS = f":(glob){TESTS}**/*.swift"
# Where a shipped build's settings live: the release and nightly pipelines, the release script, build
# settings files and the app's package manifest.
SHIPPED_BUILD = (".github/workflows/", "scripts/build-sign-upload.sh", "Packages/macOS/CmuxNext/Package.swift")
SHIPPED_BUILD_SPECS = (".github/workflows", "scripts/build-sign-upload.sh", "Packages/macOS/CmuxNext/Package.swift",
                       ":(glob)**/*.xcconfig", ":(glob)**/project.pbxproj")
APP = SOURCES + "CmuxNextApp/"
UPSTREAM = "origin/feat-cmux-next"
OWNERS = "plans/cmux-next/OWNERS.md"
BENCHES = "scripts/cmux-next/perf-hot-benches.json"
SKIP_ENV = "CMUX_GUARDRAILS_SKIP_REASON"
COMMENT_LINE = re.compile(r"^\s*(//|\*|/\*)")
ATTRIBUTE_LINE = re.compile(r"^\s*@\w+(\([^)]*\))?\s*$")
PERF_HOT = re.compile(r"//\s*perf-hot:\s*(?P<budget>\S+)(?:\s+(?P<path>[\w-]+))?")
DECL = re.compile(r"\b(func|init|deinit|subscript|var)\b")


def git(repo: Path, *args: str, check: bool = True) -> str:
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, env=env)
    if check and result.returncode != 0:
        raise SystemExit(f"guardrails: git {' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout.decode("utf-8", "replace")


def is_ancestor(repo: Path, ancestor: str, descendant: str) -> bool:
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    return subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", ancestor, descendant],
                          capture_output=True, env=env).returncode == 0


def code_of(line: str) -> str:
    """LINE without a trailing `//` comment (outside string literals) and with string contents blanked."""
    if '"' not in line and "/" not in line:
        return line
    if COMMENT_LINE.match(line):
        return ""
    out, in_string, i = [], False, 0
    while i < len(line):
        c = line[i]
        if in_string:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_string = False
                out.append(c)
            i += 1
            continue
        if c == '"':
            in_string = True
            out.append(c)
        elif line.startswith("//", i):
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def escaped(lines: list[str], index: int, marker: re.Pattern) -> bool:
    """MARKER on the line, on the previous code line's trailing comment, or in the comment block above."""
    if marker.search(lines[index]):
        return True
    j = index - 1
    while j >= 0 and (COMMENT_LINE.match(lines[j]) or ATTRIBUTE_LINE.match(lines[j])):
        if marker.search(lines[j]):
            return True
        j -= 1
    return j >= 0 and j == index - 1 and bool(marker.search(lines[j]))


@dataclass
class Added:
    """A changed line: an added line (NUMBER is 1-based in head) or a removed one (1-based in base)."""
    path: str
    number: int
    text: str


@dataclass
class Version:
    """One side of a changed file: its lines and the 1-based lines the push changed on that side.

    TYPES answers which type names are generic at that side's revision (the generic-class rule reads an
    extension's context with it); without one, only the file's own declarations count.
    """
    path: str
    lines: list[str]
    changed: set[int]
    memo: dict = field(default_factory=dict)
    types: "GenericTypes | None" = None


@dataclass
class FileChange:
    path: str
    head_lines: list[str]
    added: list[Added] = field(default_factory=list)
    touched: set[int] = field(default_factory=set)  # head line numbers the push changed (deletions mark their spot)
    removed: list[Added] = field(default_factory=list)  # numbered in base
    base_lines: list[str] = field(default_factory=list)
    is_new: bool = False
    has_perf_hot: bool = False
    head_types: "GenericTypes | None" = None
    base_types: "GenericTypes | None" = None

    @property
    def head(self) -> Version:
        return Version(self.path, self.head_lines, {a.number for a in self.added}, types=self.head_types)

    @property
    def base(self) -> Version:
        return Version(self.path, self.base_lines, {r.number for r in self.removed}, types=self.base_types)


@dataclass
class Rule:
    id: str
    title: str
    why: str
    fix: str
    escape: str | None
    find: Callable[[list[FileChange], collections.Counter], list[Added]]  # (changed files, removed texts) -> hits
    scope: tuple[str, ...] = (SOURCES,)  # path prefixes the rule reads (most rules: Sources only)
    net: bool = False  # a count over the whole push (NetHit buckets), not per added line


# (version, 0-based line) -> (the match is debt there, the 1-based opener lines that make it so)
Keep = Callable[[Version, int], tuple]


@dataclass
class Matcher:
    pattern: re.Pattern
    escape: re.Pattern | None
    keep: Keep | None = None  # context: a sleep inside a loop, a static of a class, a store in a row


def debt_in(version: Version, changed: list[Added], matcher: Matcher) -> list[Added]:
    """The debt among VERSION's CHANGED lines, plus (context rules) unchanged matches whose context changed.

    A line counts when MATCHER's pattern matches its code, KEEP holds for it in VERSION's text and it carries
    no escape there. For a context rule, an unchanged line also counts when an opener that makes it debt is a
    changed line: a new `while` around an old sleep, `struct` -> `final class` around an old static, a view
    renamed to `...Row` around an old store reference (head side); on the base side the same lines are the
    debt the push takes away, so `while a {` -> `while b {` around a sleep pairs with itself.
    """
    out = []
    lines = version.lines

    def is_debt(index: int) -> tuple[bool, list[int]]:
        if index >= len(lines):  # no text for this side (a failed blob read): judge the line alone
            return True, []
        kept, openers = matcher.keep(version, index) if matcher.keep is not None else (True, [])
        if not kept or (matcher.escape is not None and escaped(lines, index, matcher.escape)):
            return False, openers
        return True, openers

    for line in changed:
        if matcher.pattern.search(code_of(line.text)) and is_debt(line.number - 1)[0]:
            out.append(line)
    if matcher.keep is None or not version.changed:
        return out
    for index, text in enumerate(lines):
        if index + 1 in version.changed or not matcher.pattern.search(text):
            continue
        if not matcher.pattern.search(code_of(text)):
            continue
        debt, openers = is_debt(index)
        if debt and any(o in version.changed for o in openers):
            out.append(Added(version.path, index + 1, text))
    return out


ACCESS_WORDS = re.compile(r"\b(public|package|internal|private|fileprivate|open)\s+(?!\()|\b(public|package|internal)\s+import\b")


def debt_key(text: str) -> str:
    """The text two debt lines are compared by: stripped, with access modifiers dropped, so a line that moved
    to another module and only gained `package` or `public` (a git mv into a package) pairs with its old self."""
    return re.sub(r"\s+", " ", ACCESS_WORDS.sub(lambda m: "import " if m.group(2) else "", text)).strip()


def resolve(found: list[tuple[list[Added], list[Added]]]) -> list[Added]:
    """New debt from each file's (head debt the push changed, base debt the push changed), in file order.

    1. In a file, a head line pairs with a base line of the same text (unchanged, re-indented, context kept).
    2. A head line pairs with a base line of the same text in another file (a move).
    3. In a file, each base debt line left pays for one head line left (an edit of a line that already had the
       debt: a changed initializer, an added conformance). It is a count ratchet per file.
    A base line pays once: a line paired by a move never pays again in its own file. A move takes its line from
    the file with the most base debt to spare (then the first in path order), so an edit there still has its own.
    """
    left_added: list[list[Added]] = []
    pools: list[collections.Counter] = []
    for added, removed in found:
        pool = collections.Counter(debt_key(r.text) for r in removed)
        rest = []
        for line in added:
            key = debt_key(line.text)
            if pool[key] > 0:
                pool[key] -= 1
            else:
                rest.append(line)
        left_added.append(rest)
        pools.append(pool)
    for i, rest in enumerate(left_added):
        still = []
        for line in rest:
            key = debt_key(line.text)
            sources = [j for j, pool in enumerate(pools) if j != i and pool[key] > 0]
            source = max(sources, key=lambda j: (sum(pools[j].values()) - len(left_added[j]), -j), default=None)
            if source is None:
                still.append(line)
            else:
                pools[source][key] -= 1
        left_added[i] = still
    hits = []
    for rest, pool in zip(left_added, pools):
        hits += rest[sum(pool.values()):]
    return hits


def matcher_rule(matcher: Matcher) -> Callable[[list[FileChange], collections.Counter], list[Added]]:
    def find(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
        return resolve([(debt_in(c.head, c.added, matcher), debt_in(c.base, c.removed, matcher)) for c in changes])
    return find


def line_rule(pattern: str, escape: str | None) -> Callable[[list[FileChange], collections.Counter], list[Added]]:
    marker = re.compile(r"//\s*" + re.escape(escape) + r"\s*\S") if escape else None
    return matcher_rule(Matcher(re.compile(pattern), marker))


def enclosing_openers(lines: list[str], index: int, stop: re.Pattern, prefix: str = "") -> list[tuple[str, int]]:
    """The block openers around LINES[INDEX], innermost first, up to one matching STOP, as (code, 1-based line).

    PREFIX is the code before the point of interest on LINES[INDEX] itself (a one-line `while x { sleep }`).
    Each opener is its line's code up to and including the `{`.
    """
    openers, depth = [], 0
    above = ((code_of(lines[j]), j + 1) for j in range(index - 1, -1, -1))
    for code, number in itertools.chain([(prefix, index + 1)], above):
        for pos in range(len(code) - 1, -1, -1):
            c = code[pos]
            if c == "}":
                depth += 1
            elif c == "{":
                if depth == 0:
                    openers.append((code[:pos + 1], number))
                    if stop.search(code[:pos + 1]):
                        return openers
                else:
                    depth -= 1
    return openers


SLEEP = re.compile(r"\bTask\.sleep\(|\.sleep\((for|until):|\bclock\.sleep\b")
LOOP = re.compile(r"^\s*(\}\s*)?(while\b|repeat\b|for\b)|\b(while|repeat)\s*[{(!]")
FUNC_STOP = re.compile(r"\b(func|init|deinit)\b[^{]*\{|\b(Task|Task\.detached)\s*(\([^)]*\))?\s*\{")
# check-concurrency.sh's reviewed `// wakeup-allow:` covers it too; `poll-allow:` is the older name.
POLL_ALLOW = re.compile(r"//\s*(wakeup|poll)-allow:\s*\S")


def in_loop(version: Version, index: int) -> tuple[bool, list[int]]:
    code = code_of(version.lines[index])
    match = SLEEP.search(code)
    prefix = code[:match.start()] if match else ""
    loops = [n for opener, n in enclosing_openers(version.lines, index, FUNC_STOP, prefix) if LOOP.search(opener)]
    return bool(loops), loops


SINGLETON = re.compile(r"\bstatic\s+(let|var)\s+(shared|sharedInstance|instance)\b")
# CLAUDE.md names these too; as stored statics of a class or actor, or mutable ones, they hold runtime state.
# A struct or enum's `static let standard = Style()` is a value constant and passes.
SINGLETON_NAMED = re.compile(r"\bstatic\s+(let|var)\s+(`default`|standard|current|live)\s*(:[^={]*)?=")
SINGLETON_ANY = re.compile(SINGLETON.pattern + "|" + SINGLETON_NAMED.pattern)
STATEFUL = re.compile(r"\bstatic\s+var\b|=\s*(Mutex|NSHashTable|NSMapTable|OSAllocatedUnfairLock)\b")
TYPE_OPENER = re.compile(r"\b(class|actor|struct|enum|extension|protocol)\b")
SINGLETON_ALLOW = re.compile(r"//\s*singleton-allow:\s*\S")


def holds_state(version: Version, index: int) -> tuple[bool, list[int]]:
    code = code_of(version.lines[index])
    if SINGLETON.search(code) or STATEFUL.search(code):
        return True, []
    openers = enclosing_openers(version.lines, index, TYPE_OPENER)
    if not openers:
        return False, []
    opener, number = openers[-1]
    kind = TYPE_OPENER.search(opener)
    return kind is not None and kind.group(1) in ("class", "actor"), [number]


# Creating a name: `Notification.Name("x")`, `.Name(rawValue:)`, `x: Notification.Name = .init("x")`. A typed
# alias or a parameter default (`name: Notification.Name = .pagesChanged`) creates none.
BROADCAST = re.compile(r"\b(NS)?Notification\.Name(\.init)?\(|:\s*(NS)?Notification\.Name\s*=\s*\.init\s*\(")
# Inside `extension Notification.Name`, `static let x = Self("x")` / `.init("x")` declare one too.
BROADCAST_SHORT = re.compile(r"\bstatic\s+(let|var)\s+\w+\s*=\s*(Self|\.init)\s*\(")
BROADCAST_ANY = re.compile(BROADCAST.pattern + "|" + BROADCAST_SHORT.pattern)
NAME_EXTENSION = re.compile(r"\bextension\s+(Foundation\.)?(NS)?Notification\.Name\b")
STATIC_DECL = re.compile(r"\bstatic\s+(let|var)\b")
FILE_SCOPE_DECL = re.compile(r"^\s*(@\w+\s+)*((private|fileprivate|internal|public|package)\s+)?(let|var)\b")
BROADCAST_ALLOW = re.compile(r"//\s*broadcast-allow:\s*\S")


def declares_name(version: Version, index: int) -> tuple[bool, list[int]]:
    """A declared name: a static or file-scope constant that creates one, or anything in a name extension.

    A name created inline to observe an existing (system or distributed) notification declares nothing.
    """
    code = code_of(version.lines[index])
    openers = enclosing_openers(version.lines, index, TYPE_OPENER)
    if openers and NAME_EXTENSION.search(openers[-1][0]):
        return True, [openers[-1][1]]
    if BROADCAST.search(code) and (STATIC_DECL.search(code) or (not openers and FILE_SCOPE_DECL.search(code))):
        return True, []
    return False, []


ROW_STRUCT = re.compile(r"\bstruct\s+(\w*(Row|Cell|Tile|Gap|Item)(View)?)\b[^{]*:\s*[^{]*\bView\b")
ROW_STORE = re.compile(
    r"@(ObservedObject|EnvironmentObject|StateObject|Bindable)\b|@Environment\(\s*\w+\.self\s*\)"
    r"|^\s*(?:(?:private|fileprivate|internal|public|package)\s+)?(?:let|var)\s+\w+\s*:\s*(?:any\s+)?"
    r"\w*(Store|ViewModel|Coordinator|Controller|Manager|Service|Runtime)\b")
ROW_ALLOW = re.compile(r"//\s*row-snapshot-allow:\s*\S")


def row_spans(version: Version) -> list[tuple[int, int]]:
    """(declaration line, closing line), 1-based, of each SwiftUI row type (`...Row`, `...Cell`, `...Gap`)."""
    if "rows" in version.memo:
        return version.memo["rows"]
    lines, spans = version.lines, []
    for index, line in enumerate(lines):
        if not ROW_STRUCT.search(line) or not ROW_STRUCT.search(code_of(line)):
            continue
        depth, started = 0, False
        for j in range(index, len(lines)):
            for c in code_of(lines[j]):
                if c == "{":
                    depth += 1
                    started = True
                elif c == "}":
                    depth -= 1
            if started and depth <= 0:
                spans.append((index + 1, j + 1))
                break
    version.memo["rows"] = spans
    return spans


def in_row(version: Version, index: int) -> tuple[bool, list[int]]:
    for first, last in row_spans(version):
        if first < index + 1 <= last:
            return True, [first]
    return False, []


# ---------------------------------------------------------------- app-size
# CmuxNextApp ends as the composition root only (cmuxApp, AppDelegate, AppServices wiring: about 5-10k lines,
# plans/cmux-next/perf-lead.md "Architecture targets"); every edit in it re-emits the whole module. A line here is
# a source line as check-app-size.sh --base counts it (count-swift-code-lines.py's lexer: blank and comment lines
# do not count), so a comment such as a `// main-proof:` reason is neither growth nor credit.
#
# The values and the refuse-or-warn split below are agreed by the Performance Lead (session cmux-4f) with session
# cmux-b6 (2026-10-23): ROOT_BUDGET 30, HOST_FILE_MAX 30, MOVE_RUN 3, MOVE_SHARE 0.8; the root budget and the
# new-file rules refuse; net growth of the App outside the root (`other`, which replaces the `app-grow` warning) and
# of the App total (`total`) is a warning that prints the bytes added and the package the code goes to (NetHit.warn).
# Revisit: turn the growth warning into a refusal once cmux-next-arch-targets has moved the large domains out of
# CmuxNextApp (until then about two of every three App pushes grow a feature file, below). The perf cron arch report
# is the backstop meanwhile: it opens the regression issue when the App line count rises. Measured on
# origin/feat-cmux-next at 2952080b0a5 (CI's lexer, first-parent commits, each commit against its first parent):
# - ROOT_BUDGET: the wiring of a few domains per push (a stored instance, its construction, passing it on), never
#   their logic; the `total` warning asks the same push to pay for it with an App shrink. Of the last 600 App commits
#   (2026-10-20..23), 62 changed root files: net root growth p50 +2, p95 +11, max +41; 61 of 62 are within +30. The
#   one over (4aa19112632, +41) is folder and harness logic in AppServices+WorkContext.swift, not wiring.
# - HOST_FILE_MAX: one domain's Host protocol forwards, one member per line; a larger Host protocol is a sign that
#   the domain still reaches into the App. No AppServices+<Domain>Host.swift exists yet; the four `*Host` protocols
#   in Sources have 4 to 9 members (BrowserRestoredSessionHost 9), so 30 lines (the opener, its imports and attribute
#   and its `}` included) is about 3x the largest known Host; a bigger domain splits into two Host files over two
#   pushes.
# - MOVE_RUN: one or two lines in a row that match removed text can be chance (`let x = 0`, a shared call); a
#   moved block is longer. Over 1500 Sources commits (2026-10-19..23): of 133 new files git calls a >= 90% rename,
#   132 reach MOVE_SHARE at runs of 2 or 3, 129 at 4, 122 at 5; of 1779 plain new files the p95 credited share is
#   0.19 at 2, 0.14 at 3, 0.10 at 4. 3 is the longest run that still credits every near-pure move run 2 credits.
# - MOVE_SHARE: a git mv or a split also edits some lines (a renamed type, a changed access level); a mostly
#   unchanged file is still a move, not new code. Same 1500 commits at MOVE_RUN 3: 0.8 passes 132 of 133 renames
#   >= 90% similar and 18 of 30 at 80-89%, and passes 23 of 1779 plain new files (splits git does not see as
#   renames); 0.7 would pass 25 of 30 at 80-89% and 29 plain new files.
# - MOVE_GENERIC_PER_LINE: a moved specific line usually closes one or two blocks (`}` of an `if` and of its
#   function); generic lines beyond that are not explained by the run's specific lines.
# - The `other` and `total` buckets as warnings: in the same 600 App commits, 404 grew feature App files (net +14726
#   source lines against -2417 shrinks); the App grew +12500 source lines in those four days. A refusal would stop
#   about two of every three App pushes of that period until they move lines out, so it waits for the domain moves.
# A source line is the unit (CI's unit): joining statements onto one line lowers the count without removing code,
# a count dodge this rule cannot see; review rejects it.
ROOT_BUDGET = 30  # source lines of wiring the root may add per push, moved-in lines included
HOST_FILE_MAX = 30  # source lines of the push's one new `AppServices+<Domain>Host.swift`, all one-line forwards
MOVE_RUN = 3  # a moved line counts only in a run of this many consecutive moved source lines
MOVE_SHARE = 0.8  # a new file is a move (git mv, split) when this share of its non-import source lines is moved
MOVE_GENERIC_PER_LINE = 2  # generic lines a run credits per specific moved line (closing braces of nested blocks)
ROOT_FILE = re.compile(r"^(AppDelegate|CmuxNextApp|AppServices)(\+[A-Za-z0-9]+)?\.swift$")  # top level of the App
HOST_FILE = re.compile(r"^AppServices\+[A-Z][A-Za-z0-9]*Host\.swift$")
HOST_DECL = re.compile(r"^\s*(@\w+\s+)*extension\s+AppServices\s*:[^{]*\b[A-Z]\w*Host\b")
IMPORT_LINE = re.compile(r"^\s*(@\w+\s+)*((public|package|internal|private|fileprivate)\s+)?import\s+\S")
# A Host member: one declaration (KIND); its body, if any, is one brace pair on the same line (checked in host_problem).
HOST_MEMBER = re.compile(r"^(@\w+(\([^)]*\))?\s+)*((public|package|internal|private|fileprivate|nonisolated|static|class|"
                         r"final|override|dynamic)\s+)*(?P<kind>func|var|let|subscript|typealias)\b")
# Bare keywords of a generic line: with braces, punctuation, numbers and attributes they make `}`, `} else {`,
# `return nil`, `return 0`, `@MainActor`, lines that match a removed line of almost any file.
GENERIC_WORDS = frozenset(("else", "return", "break", "continue", "default", "nil", "true", "false", "self", "try",
                           "await", "throws", "async", "case", "fallthrough", "in", "do"))
TOKEN = re.compile(r"@?\w+|\S")
DESIGN = "plans/cmux-next/architecture-refactor-DESIGN.md section 4, \"Destination map\""


def _load_source_line_flags() -> Callable[[str], list[bool]]:
    """CI's lexer, count-swift-code-lines.py's `source_line_flags`, from next to this file.

    One lexer, not a copy: the hook runs the installed copy of scripts/cmux-next, which holds both files.
    """
    spec = importlib.util.spec_from_file_location("cmux_next_count_swift_code_lines",
                                                  Path(__file__).with_name("count-swift-code-lines.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.source_line_flags


source_line_flags = _load_source_line_flags()


@dataclass
class NetHit(Added):
    """A hit of a net-count rule: BUCKET names what grew (`root`, `other`, `total`, `new:<path>`), EXCESS how much.

    WARN marks a hit that check() reports as a warning, never a refusal (the `app-size` growth buckets for now).
    check_push compares a merge's two ranges by bucket, not by line text: a count has no line to intersect.
    """
    bucket: str = ""
    excess: int = 0
    warn: bool = False


@dataclass
class SourceLine(Added):
    """An added or removed source line; ORDINAL is its 1-based place among its file version's source lines."""
    ordinal: int = 0


@dataclass
class AppFile:
    """One changed App Swift file: its added and removed source lines, and whether it is new and a root file."""
    path: str
    is_new: bool
    root: bool
    added: list[SourceLine]
    removed: list[SourceLine]


def app_rel(path: str) -> str:
    return path[len(APP):]


def is_root_file(path: str) -> bool:
    """A composition-root file: AppDelegate, CmuxNextApp or AppServices(+X).swift directly in the App folder.

    Feature folders' `AppServices+Cloud.swift` and the like are feature code, not wiring.
    """
    rel = app_rel(path)
    return "/" not in rel and ROOT_FILE.match(rel) is not None


def destination(path: str) -> str:
    """Where PATH's code goes: the design doc's destination map, named, not copied (a copy drifts from the doc)."""
    rel = app_rel(path)
    top = rel.split("/", 1)[0] if "/" in rel else ""
    return (f"its domain package (the `{top}` folder's row in {DESIGN}; no row: add one)" if top
            else f"its domain package ({DESIGN})")


def app_file(change: FileChange) -> AppFile:
    """CHANGE's added and removed source lines, each judged on its whole file version by CI's lexer (a line in a
    block comment or a multi-line string is what it is there)."""

    def source(lines: list[str], changed: list[Added]) -> list[SourceLine]:
        flags = source_line_flags("\n".join(lines))
        ordinals = list(itertools.accumulate(map(int, flags)))
        return [SourceLine(line.path, line.number, line.text, ordinals[line.number - 1]) for line in changed
                if 0 < line.number <= len(flags) and flags[line.number - 1]]

    return AppFile(change.path, change.is_new, is_root_file(change.path), source(change.head_lines, change.added),
                   source(change.base_lines, change.removed))


def is_generic(key: str) -> bool:
    """KEY (a stripped line) has only braces, punctuation, numbers, attributes and GENERIC_WORDS: alone it proves no
    move. A token scan, linear in the line (a regex with a nested repeat backtracks exponentially on a long number).
    """
    return all(token.isdigit() or token in GENERIC_WORDS or (token[0] == "@" and len(token) > 1)
               or not (token[0].isalnum() or token[0] == "_") for token in TOKEN.findall(key))


def credit_moves(lines: list[SourceLine], pools: list[collections.Counter]) -> int:
    """How many of LINES (one file's added source lines, in head order) moved here from POOLS; consumes what it credits.

    A line is moved when its stripped text is in a pool (the first that has it) and it is in a run of at least
    MOVE_RUN source lines in a row that are all in a pool. A run credits each specific line and at most
    MOVE_GENERIC_PER_LINE generic ones (is_generic: `}`, `return nil`) per specific one: those match some removed
    line anywhere, so on their own they prove nothing. What it does not credit goes back to the pools.
    """
    credited = 0
    run: list[tuple[str, int]] = []

    def close() -> None:
        nonlocal credited
        specific = sum(1 for key, _ in run if not is_generic(key))
        qualifies, generic_left = len(run) >= MOVE_RUN and specific > 0, MOVE_GENERIC_PER_LINE * specific
        for key, source in run:
            generic = is_generic(key)
            if qualifies and not generic:
                credited += 1
            elif qualifies and generic_left > 0:
                generic_left -= 1
                credited += 1
            else:
                pools[source][key] += 1
        run.clear()

    previous = None
    for line in lines:
        key = line.text.strip()
        source = next((i for i, pool in enumerate(pools) if pool[key] > 0), None)
        if source is None or (previous is not None and line.ordinal != previous + 1):
            close()
        if source is not None:
            pools[source][key] -= 1
            run.append((key, source))
        previous = line.ordinal
    close()
    return credited


def host_problem(file: AppFile) -> str | None:
    """Why the new FILE is not a Host conformance file of one-line forwards, or None when it is one.

    Its source lines are imports, attributes and `extension AppServices: <Domain>Host {` blocks whose members are
    each one `func`, `subscript`, `typealias` or computed `var` on one line with at most one brace pair
    (`func quit() { quit.run() }`): the forwards a domain's Host protocol needs, never the domain's logic. A member
    that stores state (any `let`, a `var` with `=` or with no body, e.g. `static var cache = [:]`) is refused: a
    stored static in an extension is a singleton by another name, not a forward to a domain object.
    """
    depth, declared = 0, False
    for line in file.added:
        code = code_of(line.text).strip()
        where = f"line {line.number} (`{code[:60]}`)"
        if depth == 0:
            if IMPORT_LINE.match(code) or ATTRIBUTE_LINE.match(code):
                continue
            if not (HOST_DECL.match(code) and code.endswith(("{", "{}"))):
                return f"{where} is outside `extension AppServices: <Domain>Host {{ ... }}`"
            declared, depth = True, (0 if code.endswith("{}") else 1)
        elif code == "}":
            depth = 0
        elif ATTRIBUTE_LINE.match(code):
            continue
        elif (member := HOST_MEMBER.match(code)) is None or ";" in code or not code.count("{") == code.count("}") <= 1:
            return f"{where} is not a one-line forward"
        elif member["kind"] == "let" or (member["kind"] == "var" and ("=" in code.split("{", 1)[0] or "{" not in code)):
            return f"{where} stores state (a `let`, or a `var` with `=` or no body): not a one-line forward"
    if depth:
        return "its extension block does not close"
    return None if declared else "a Host file declares `extension AppServices: <Domain>Host`"


def app_size(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """The App growth a push may not add or is warned about (NetHit per bucket); see the `app-size` rule's text.

    Per push, in source lines: the root adds at most ROOT_BUDGET lines besides the push's one Host conformance
    file, lines moved into it from feature files included; a new file is refused unless it is a move or that Host
    file. Growth of the App as a whole (exactly check-app-size.sh --base's count: a split file's new import lines
    are growth there and here) and of the App outside the root are NetHit.warn hits: warnings, not refusals.
    Lines moved between feature files (a git mv, a split) and out of the root are not growth; code moved into the
    root (a Host file too) counts against the root's budget and gives the rest no shrink credit. MOVED (removed
    lines of every Sources file) is not used: code moved into the App from a package is App growth.
    """
    app = [app_file(c) for c in changes if c.path.startswith(APP) and c.path.endswith(".swift")]
    if not app:
        return []
    hits: list[Added] = []

    def removed_pool(files: list[AppFile]) -> collections.Counter:
        return collections.Counter(r.text.strip() for f in files for r in f.removed)

    root_pool = removed_pool([f for f in app if f.root])
    other_pool = removed_pool([f for f in app if not f.root])
    host: AppFile | None = None
    for file in app:
        if not file.is_new:
            continue
        # A new root file is split from the root; code from elsewhere does not become wiring by moving.
        moved_lines = credit_moves(file.added, [root_pool] if file.root else [other_pool, root_pool])
        code = sum(1 for a in file.added if not IMPORT_LINE.match(a.text))
        if moved_lines and moved_lines >= MOVE_SHARE * code:
            continue
        lines = len(file.added)
        if not (HOST_FILE.match(app_rel(file.path)) and file.root):
            why = ("only a move or the push's one Host conformance file may be added" if not file.root
                   else "a new root file is split from the root files or is a Host conformance")
        elif lines > HOST_FILE_MAX:
            why = f"a Host conformance file has at most {HOST_FILE_MAX} source lines"
        elif (problem := host_problem(file)) is not None:
            why = f"a Host conformance file holds only one-line forwards: {problem}"
        elif host is not None:
            why = f"one new Host conformance file per push ({app_rel(host.path)} is this push's)"
        else:
            host = file
            continue
        number = file.added[0].number if file.added else 1
        hits.append(NetHit(file.path, number, f"new App file, {lines} source lines ({lines - moved_lines} not "
                           f"moved), goes to {destination(file.path)}: {why}", f"new:{file.path}", lines))

    root_files = [f for f in app if f.root]
    other_files = [f for f in app if not f.root]

    def side(files: list[AppFile]) -> tuple[dict[str, list[SourceLine]], collections.Counter]:
        """(added lines no removed line of the same side explains, per file; lines the side lost)."""
        removed = collections.Counter(r.text.strip() for f in files for r in f.removed)
        lost = removed - collections.Counter(a.text.strip() for f in files for a in f.added)
        own, out = removed.copy(), {}
        for f in files:
            rest = []
            for a in f.added:
                key = a.text.strip()
                if own[key] > 0:
                    own[key] -= 1
                else:
                    rest.append(a)
            out[f.path] = rest
        return out, lost

    # The Host file is a root file here: what it takes from feature files is moved into the root, not a shrink.
    root_new, root_lost = side(root_files)
    other_new, other_lost = side(other_files)
    credited = {f.path: credit_moves(root_new[f.path], [other_lost]) for f in root_files}
    credited.update({f.path: credit_moves(other_new[f.path], [root_lost]) for f in other_files})
    into_root = sum(credited[f.path] for f in root_files)
    out_of_root = sum(credited[f.path] for f in other_files)
    new_lines = {**root_new, **other_new}
    # A root file's moved-in lines are root growth (wiring budget), so only feature files subtract their moves.
    fresh = {f.path: len(new_lines[f.path]) - (0 if f.root else credited[f.path]) for f in app}

    def net(files: list[AppFile]) -> int:
        return sum(len(f.added) - len(f.removed) for f in files)

    def net_bytes(files: list[AppFile]) -> int:
        """UTF-8 bytes of FILES' added source lines minus their removed ones, each with its newline."""
        return sum(len(line.text.encode()) + 1 for f in files for line in f.added) - sum(
            len(line.text.encode()) + 1 for f in files for line in f.removed)

    def top(files: list[AppFile]) -> tuple[str, int, str]:
        """(path, line, summary) of the files with the most added lines no move out of the root explains."""
        grown = sorted(files, key=lambda f: (-fresh[f.path], f.path))
        shown = ", ".join(f"{app_rel(f.path)} +{fresh[f.path]} {'added' if f.root else 'new'}" for f in grown[:3]
                          if fresh[f.path] > 0)
        first = grown[0]
        lines = new_lines[first.path] or first.added
        return first.path, lines[0].number if lines else 1, shown

    # Code moved into the root counts against its wiring budget (a move does not make feature logic wiring); code
    # moved out of it is free: neutral for the root and the rest. The push's one Host file (one-line forwards
    # only, host_problem) is outside the budget; what it takes from feature files still gives them no credit.
    root_net = net(root_files) + out_of_root
    other_net = net(other_files) + into_root - out_of_root
    wiring = root_net - (len(host.added) if host else 0)
    total = net(app)
    if wiring > ROOT_BUDGET:
        path, number, shown = top([f for f in root_files if f is not host] or root_files)
        besides = f" besides {app_rel(host.path)}'s {len(host.added)}" if host else ""
        hits.append(NetHit(path, number, f"the composition root grows {wiring:+d} source lines{besides}, over its "
                           f"wiring budget of +{ROOT_BUDGET} per push ({shown})", "root", wiring - ROOT_BUDGET))
    # Growth warnings, not refusals, until the large domains are out of the App (see the values' comment above).
    if other_net > 0:
        path, number, shown = top(other_files)
        hits.append(NetHit(path, number, f"App outside the root grows {other_net:+d} source lines "
                           f"({net_bytes(other_files):+d} bytes); move the code to {destination(path)} ({shown})",
                           "other", other_net, warn=True))
    if total > 0:
        path, number, shown = top(app)
        hits.append(NetHit(path, number, f"CmuxNextApp grows {total:+d} source lines ({net_bytes(app):+d} bytes, as "
                           f"check-app-size.sh --base counts lines): pay for it by moving as many App lines to "
                           f"{destination(path)} ({shown})", "total", total, warn=True))
    return hits


# A class with an implicit deinit in a generic context: its own generic parameters, or those of a type, extension
# or function it is declared in (ObservedMap.Slot is generic through ObservedMap). In a main-actor target (the
# default of every UI and test target, `.defaultIsolation(MainActor.self)`) that deinit is isolated, and
# swift-frontend 6.3.3 (Xcode 26.6) crashes on it in -O: signal 11 in EarlyPerfInliner,
# isCallerAndCalleeLayoutConstraintsCompatible, on the class's deallocating deinit (`...CfD`). It broke
# `swift build --build-tests -c release` twice on 2026-10-23 (PageTestWait.Once, CloudPaneTests.Seen) and can hit
# any edit of such a class. An `isolated deinit` is that isolated deinit written out, so only a `nonisolated deinit`
# or a plain `deinit` (nonisolated unless marked) is the fix.
CLASS_DECL = re.compile(r"(^|[\s)])(final\s+)?(?P<kw>class)\s+(?!(?:func|var|let|subscript|init|deinit|override)\b)"
                        r"(?P<name>[A-Za-z_]\w*)\s*(<|:|\{|\bwhere\b|$)")
GENERIC_CLASS_ALLOW = re.compile(r"//\s*generic-class-allow:\s*\S")
GENERIC_TYPE = re.compile(r"\b(?:class|struct|enum|actor)\s+([A-Za-z_]\w*)\s*<")
GENERIC_DECL = re.compile(r"\b(?:class|struct|enum|actor)\s+[A-Za-z_]\w*\s*<|\b(?:func|subscript)\s+[^\s(<]*\s*<|\binit\??\s*<")
DECL_OPENER = re.compile(r"\b(class|struct|enum|actor|extension|protocol|func|init|subscript)\b")
EXTENSION = re.compile(r"\bextension\s+([A-Za-z_][\w.]*)")
NEVER = re.compile(r"(?!)")
EXPLICIT_DEINIT = re.compile(r"\b(isolated\s+)?deinit\b")


class GenericTypes:
    """Which type names are declared generic (`struct Name<...>`) at one revision.

    KNOWN holds the declarations in the push's own files at that revision. A name it lacks is looked up once in
    the revision's `Name.swift` files (CLAUDE.md: one major type per file, named after the type); a type declared
    in a file of another name is not found, and its extensions read as non-generic (fail open).
    """

    def __init__(self, repo: Path | None, rev: str | None, texts: list[str]):
        self.repo, self.rev = repo, rev
        self.known = {name for text in texts for name in GENERIC_TYPE.findall(text)}
        self.looked: dict[str, bool] = {}
        self.tree: list[str] | None = None

    def __contains__(self, name: str) -> bool:
        if name in self.known:
            return True
        if name not in self.looked:
            self.looked[name] = self.declared_generic(name)
        return self.looked[name]

    def declared_generic(self, name: str) -> bool:
        if self.repo is None or self.rev is None:
            return False
        if self.tree is None:
            self.tree = git(self.repo, "ls-tree", "-r", "--name-only", self.rev, "--", SOURCES, TESTS,
                            check=False).split("\n")
        paths = [p for p in self.tree if p.rsplit("/", 1)[-1] == f"{name}.swift"]
        declared = re.compile(r"\b(?:class|struct|enum|actor)\s+" + re.escape(name) + r"\s*<")
        return any(declared.search(text) for text in blobs(self.repo, [(self.rev, p) for p in paths]).values())


def declaration_of(lines: list[str], number: int, opener: str) -> str:
    """The declaration an opener (`{` line) belongs to, joined with the lines above it that continue it
    (`final class Cache<\n    Key\n> {`), up to 8 lines."""
    text, j = opener, number - 2
    while not DECL_OPENER.search(text) and j >= 0 and number - 1 - j <= 8:
        above = code_of(lines[j]).strip()
        if not above or above.endswith(("{", "}", ";")):
            break
        text, j = above + " " + text, j - 1
    return text


def generic_context(version: Version, index: int, prefix: str) -> list[int]:
    """The 1-based lines of the generic declarations LINES[INDEX] is nested in: a generic type or function, a
    `where` clause, or an extension of a generic type (this file, the push's files, or the type's own file)."""
    if "generic" not in version.memo:
        version.memo["generic"] = set(GENERIC_TYPE.findall("\n".join(version.lines)))
    local = version.memo["generic"]
    found = []
    for opener, number in enclosing_openers(version.lines, index, NEVER, prefix):
        decl = declaration_of(version.lines, number, opener)
        if not DECL_OPENER.search(decl):
            continue  # a control-flow block (`for x in xs where ...`) is no generic context
        extension = EXTENSION.search(decl)
        generic = bool(GENERIC_DECL.search(decl) or re.search(r"\bwhere\b", decl))
        if not generic and extension:
            names = extension.group(1).split(".")
            generic = any(n in local or (version.types is not None and n in version.types) for n in names)
        if generic:
            found.append(number)
    return found


def implicit_deinit(version: Version, index: int) -> tuple[bool, list[int]]:
    """A class declared here, not `nonisolated`, generic itself or by context, whose body declares no
    `nonisolated deinit` or plain `deinit` (an `isolated deinit` is the crashing one)."""
    code = code_of(version.lines[index])
    match = CLASS_DECL.search(code)
    if match is None or re.search(r"\bnonisolated\b", code[:match.start("kw")]):
        return False, []
    own = GENERIC_TYPE.match(code, match.start("kw")) is not None
    context = generic_context(version, index, code[:match.start("kw")])
    if not own and not context:
        return False, []
    # The class body at depth 1 (its own members, not those of nested types).
    depth, opened, members = 0, False, []
    for j in range(index, len(version.lines)):
        line = code_of(version.lines[j]) if j > index else code[match.start("kw"):]
        for c in line:
            if c == "{":
                depth += 1
                opened = True
            elif c == "}":
                depth -= 1
                if opened and depth <= 0:
                    break
            elif depth == 1:
                members.append(c)
        if opened and depth <= 0:
            break
        members.append("\n")
    for deinit in EXPLICIT_DEINIT.finditer("".join(members)):
        if deinit.group(1) is None:
            return False, []
    return True, context


singleton = matcher_rule(Matcher(SINGLETON_ANY, SINGLETON_ALLOW, holds_state))
sleep_in_loop = matcher_rule(Matcher(SLEEP, POLL_ALLOW, in_loop))
broadcast_name = matcher_rule(Matcher(BROADCAST_ANY, BROADCAST_ALLOW, declares_name))
row_store = matcher_rule(Matcher(ROW_STORE, ROW_ALLOW, in_row))


RULES = (
    Rule("singleton", "New singleton (`static let shared`, or a class's stored `standard`/`default`/`current`/`live`)",
         "a global hides runtime state: no injection, no test seam, every caller couples to one instance "
         "(codebase-health.md counts the ones already there)",
         "construct it once at the composition root (the App's startup) and pass it through `init`; "
         "`static let` is fine for constants and identifiers",
         "// singleton-allow: <why a process-wide instance is the only correct shape>",
         singleton),
    Rule("assume-isolated", "`MainActor.assumeIsolated` without a main-thread proof",
         "it traps in Release when the caller is not on main, and nothing proves it is",
         "make the caller `@MainActor` (and await it), or prove the thread on the line or above: "
         "`// main-proof: <why this always runs on main>` (e.g. an observer registered with queue: .main)",
         "// main-proof: <why>",
         line_rule(r"\bMainActor\.assumeIsolated\b", "main-proof:")),
    Rule("unchecked-sendable", "`@unchecked Sendable` / `nonisolated(unsafe)` without a safety argument",
         "it switches off the data-race checker; without a written argument nobody can review it",
         "an actor, a Sendable value type, or CmuxNextCompat `Mutex` around the state; when it is truly safe, "
         "say why on the declaration: `// crash-allow: <the safety argument>` (crash_ratchet.py counts it as a waived hit: record it with crash_ratchet.py --record-waivers)",
         "// crash-allow: <the safety argument>",
         line_rule(r"@unchecked\s+Sendable\b|\bnonisolated\(unsafe\)", "crash-allow:")),
    Rule("sleep-poll", "A sleep inside a loop (polling)",
         "a sleep that waits for a condition wakes forever, adds up to one period of latency and hides the real signal",
         "await the event (AsyncStream, a continuation, observation); one deadline: DemandTimer; a retry after a "
         "failure: Backoff.wait",
         "// wakeup-allow: <why no event exists> (check-concurrency.sh's marker; `poll-allow:` also works)",
         sleep_in_loop),
    Rule("main-async", "`DispatchQueue.main.async`",
         "an untyped hop that reorders work and hides isolation (CLAUDE.md forbids it in new code)",
         "annotate the destination `@MainActor` and `await` it, or hop once with `Task { @MainActor in ... }` "
         "owned by the caller",
         "// main-async-allow: <the API that forces a GCD hop>",
         line_rule(r"\bDispatchQueue\.main\.async\b|\bOperationQueue\.main\.addOperation\b", "main-async-allow:")),
    Rule("broadcast-name", "New `Notification.Name` (a broadcast signal)",
         "every observer wakes on every post: O(all) work per change (browserChildWindowPagesNeedUpdate makes "
         "every Chromium host re-post geometry on any layout change; perf-lead.md issue 2)",
         "tell the one object that changed (a method on its owner, a closure the owner holds, or an "
         "AsyncStream keyed by id)",
         "// broadcast-allow: <why every observer must hear every post>",
         broadcast_name),
    Rule("combine-state", "`ObservableObject` / `@Published` / Combine state",
         "one change invalidates every observer view; CLAUDE.md requires Observation",
         "`@MainActor @Observable` models; views take `@State`, `@Bindable`, a plain `let` or "
         "`@Environment(Model.self)`",
         None,
         line_rule(r"\bObservableObject\b|@(Published|StateObject|ObservedObject|EnvironmentObject)\b"
                   r"|\.environmentObject\(|\b(PassthroughSubject|CurrentValueSubject)\b", None)),
    Rule("row-store", "A store reference stored in a list row view",
         "a row that holds a store re-renders on every change to it: N rows x every change (the 100 % CPU "
         "LazyLayoutViewCache loop, classic #2586)",
         "give the row an immutable value snapshot plus a closure action bundle; read the store above the "
         "ForEach",
         "// row-snapshot-allow: <why>",
         row_store),
    Rule("generic-class-deinit",
         "A class generic by itself or by context (nested in a generic type, extension or function) with an "
         "implicit or `isolated` deinit (main-actor by default)",
         "swift-frontend 6.3.3 (Xcode 26.6) crashes with signal 11 in -O on the isolated deinit of a generic "
         "main-actor class (EarlyPerfInliner, isCallerAndCalleeLayoutConstraintsCompatible): the Release test build "
         "and every Release bench stop (2026-10-23: PageTestWait.Once, CloudPaneTests.Seen, ObservedMap.Slot)",
         "give it `nonisolated deinit {}` (or a nonisolated deinit that does its cleanup; not `isolated deinit`), "
         "declare the class `nonisolated`, or move it out of the generic context",
         "// generic-class-allow: <why this class is not main-actor isolated, e.g. its target's default isolation>",
         matcher_rule(Matcher(CLASS_DECL, GENERIC_CLASS_ALLOW, implicit_deinit)),
         scope=(SOURCES, TESTS)),
    Rule("bench-hooks-shipped", "The bench configuration in a shipped build's settings",
         "CMUX_BENCH_HOOKS (reload.sh --config bench) keeps the debug.* control commands in an optimized app for "
         "the fleet benches; in a release, nightly or RC build's settings it would ship them to users",
         "build benches with `scripts/reload.sh --config bench` or a measure script's `--config=bench` only; "
         "shipped pipelines run scripts/cmux-next/check-no-bench-hooks.sh on their app",
         None,
         line_rule(r"CMUX_BENCH_HOOKS|--config[= ]bench\b", None),
         scope=SHIPPED_BUILD + (".xcconfig", "project.pbxproj")),
    Rule("app-size", f"CmuxNextApp's composition root grows (in source lines: the root's wiring +{ROOT_BUDGET} per "
         f"push, moves into the root included, plus one Host file; new App files only as moves; growth of the App "
         f"and of its feature files warns)",
         "the App re-emits its whole module on every edit and ends as the composition root only (cmuxApp, "
         "AppDelegate, AppServices wiring: about 5-10k lines, perf-lead.md \"Architecture targets\")",
         f"put the logic in its domain package ({DESIGN}); the root (top-level AppDelegate, CmuxNextApp, "
         f"AppServices(+X).swift) only constructs and passes instances, and the push that adds that wiring should "
         f"move at least as many lines out of the App (a warning names the growth); a domain's one-line forwards "
         f"go in one new AppServices+<Domain>Host.swift per push (<= {HOST_FILE_MAX} source lines, only "
         "`extension AppServices: <Domain>Host { <one-line forwards> }`, no stored `let`/`var`); moves between "
         "feature files (git mv, a split; its new import lines are growth, as check-app-size.sh counts them) and "
         "out of the root are not growth, moves into the root count against its budget; blank and comment lines "
         "never count",
         None,
         app_size,
         scope=(APP,),
         net=True),
)


# ---------------------------------------------------------------- diff

def parse_diff(diff: str) -> dict[str, FileChange]:
    """The files of a `-U0` diff run with `--src-prefix=a/ --dst-prefix=b/` (a user's diff.noprefix is ignored)."""
    changes: dict[str, FileChange] = {}
    current: FileChange | None = None
    number, old_number, pending_new, old_path = 0, 0, False, ""
    for line in diff.split("\n"):
        if line.startswith("diff --git"):
            current = None
        elif line.startswith("--- "):
            pending_new = line == "--- /dev/null"
            old_path = line[6:] if line.startswith("--- a/") else ""
        elif line.startswith("+++ "):
            # A deleted file keeps its old path: its removed lines still make a move elsewhere not new.
            path = line[6:] if line.startswith("+++ b/") else old_path
            current = changes.setdefault(path, FileChange(path, [])) if path else None
            if current is not None:
                current.is_new = pending_new
        elif line.startswith("@@") and current is not None:
            old = re.search(r"-(\d+)", line)
            old_number = int(old.group(1)) if old else 0
            match = re.search(r"\+(\d+)(?:,(\d+))?", line)
            number = int(match.group(1)) if match else 0
            count = int(match.group(2)) if match and match.group(2) is not None else 1
            if count == 0:
                current.touched.add(max(number, 1))  # a pure deletion after line `number`
                current.touched.add(number + 1)
        elif current is not None and line.startswith("+"):
            current.added.append(Added(current.path, number, line[1:]))
            current.touched.add(number)
            number += 1
        elif current is not None and line.startswith("-"):
            current.removed.append(Added(current.path, old_number, line[1:]))
            old_number += 1
    return changes


def blobs(repo: Path, specs: list[tuple[str, str]]) -> dict[tuple[str, str], str]:
    """{(rev, path): text} for SPECS in one `git cat-file --batch` (a path missing at its rev is left out)."""
    if not specs:
        return {}
    request = "".join(f"{rev}:{p}\n" for rev, p in specs).encode()
    result = subprocess.run(["git", "-C", str(repo), "cat-file", "--batch"], input=request, capture_output=True)
    out, cursor, found = result.stdout, 0, {}
    for path in specs:
        end = out.find(b"\n", cursor)
        if end < 0:  # git stopped early (a bad REV): report what it gave
            break
        header = out[cursor:end].split()
        cursor = end + 1
        if len(header) < 3 or header[1] != b"blob":
            continue
        size = int(header[2])
        found[path] = out[cursor:cursor + size].decode("utf-8", "replace")
        cursor += size + 1
    return found


def run_both(repo: Path, *commands: list[str]) -> list[str]:
    """Run git COMMANDS at once (each costs a process start on a busy Mac) and return their outputs."""
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    procs = [subprocess.Popen(["git", "-C", str(repo), *c], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
             for c in commands]
    return [p.communicate()[0].decode("utf-8", "replace") for p in procs]


# ---------------------------------------------------------------- warnings

def function_spans(lines: list[str]) -> list[tuple[int, int, str, str, str]]:
    """(first, last, declaration, budget, path-id) per `// perf-hot:` marked declaration (1-based, inclusive)."""
    spans = []
    for index, line in enumerate(lines):
        match = PERF_HOT.search(line)
        if not match:
            continue
        if COMMENT_LINE.match(line):  # the marker in the comment block above the declaration
            j = index + 1
            while j < len(lines) and (COMMENT_LINE.match(lines[j]) or ATTRIBUTE_LINE.match(lines[j]) or not lines[j].strip()):
                j += 1
        else:  # a trailing marker on the declaration line itself (adds no line to a capped file)
            j = index
        if j >= len(lines) or not DECL.search(code_of(lines[j])):
            continue
        depth, started, k = 0, False, j
        while k < len(lines):
            for c in code_of(lines[k]):
                if c == "{":
                    depth += 1
                    started = True
                elif c == "}":
                    depth -= 1
            if started and depth <= 0:
                break
            k += 1
        spans.append((j + 1, k + 1, code_of(lines[j]).strip(), match.group("budget"), match.group("path") or ""))
    return spans


def perf_hot_warnings(changes: dict[str, FileChange], benches: dict) -> list[str]:
    out = []
    paths = benches.get("paths", {})
    for path, change in sorted(changes.items()):
        if not path.endswith(".swift"):
            continue
        if not change.has_perf_hot:
            continue
        for first, last, decl, budget, hot in function_spans(change.head_lines):
            if not any(first <= n <= last for n in change.touched):
                continue
            entry = paths.get(hot, {})
            bench = entry.get("bench", "no bench mapped: add the path id to " + BENCHES)
            owner = f"; owner {entry['owner']}" if entry.get("owner") else ""
            out.append(f"{path}:{first}: changes perf-hot `{decl[:80]}` (budget {budget}, {hot or 'no path id'}"
                       f"{owner}). Run before and after on the fleet, light and STRESS: {bench}")
    for path, change in sorted(changes.items()):
        # Per path id: an edit of a marked declaration line (a parameter, an attribute) keeps its marker.
        gone = marker_ids(r.text for r in change.removed) - marker_ids(a.text for a in change.added)
        for hot, count in sorted(gone.items()):
            out.append(f"{path}: removes a perf-hot marker (`{hot}`{f', {count}x' if count > 1 else ''}): keep it "
                       "unless the path is no longer hot, and say why in the commit")
    return out


def marker_ids(lines) -> collections.Counter:
    """`// perf-hot:` markers in LINES per path id (the budget when a marker has no id)."""
    found = collections.Counter()
    for line in lines:
        match = PERF_HOT.search(line) if "perf-hot" in line else None
        if match:
            found[match.group("path") or match.group("budget")] += 1
    return found


def parse_owners(text: str) -> list[tuple[str, list[str], str, str]]:
    """(area, path globs, owner, doc) from OWNERS.md's table (columns: Area | Paths | Owner | Read first)."""
    rows, header = [], None
    for line in text.splitlines():
        if not line.startswith("|"):
            header = None if not line.strip() else header
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if header is None:
            header = [c.lower() for c in cells]
            continue
        if set(line) <= set("|-: "):
            continue
        if "paths" not in header or len(cells) < len(header):
            continue
        row = dict(zip(header, cells))
        globs = re.findall(r"`([^`]+)`", row.get("paths", ""))
        cell = row.get("read first", "")
        link = re.search(r"\]\(([^)]+)\)", cell)
        if link:  # a Markdown link is relative to OWNERS.md
            target = link.group(1)
            doc_text = target if target.startswith(("http", "/")) else str(Path(OWNERS).parent / target)
        else:
            quoted = re.search(r"`([^`]+)`", cell)
            doc_text = cell.replace("`", "") if quoted else cell
        rows.append((row.get("area", "?"), globs, row.get("owner", "?"), doc_text))
    return rows


def glob_match(path: str, pattern: str) -> bool:
    """PATTERN from OWNERS.md: a trailing `/` is a directory prefix, `**` crosses folders, `*` does not."""
    if pattern.endswith("/"):
        return path.startswith(pattern)
    regex = re.escape(pattern).replace(r"\*\*", "\0").replace(r"\*", "[^/]*").replace("\0", ".*")
    return re.fullmatch(regex, path) is not None


def owner_warnings(files: list[str], owners: list[tuple[str, list[str], str, str]]) -> list[str]:
    out = []
    for area, globs, owner, doc in owners:
        hit = [f for f in files if any(glob_match(f, g) for g in globs)]
        if hit:
            more = f" and {len(hit) - 1} more" if len(hit) > 1 else ""
            out.append(f"touches {area} ({hit[0]}{more}): owner {owner}. Read {doc} first; tell the owner what changed.")
    return out


# ---------------------------------------------------------------- run

def check_failure(name: str, error: Exception) -> str:
    """The warning for a rule or warning check NAME that raised: the error and where it raised."""
    frames = traceback.extract_tb(error.__traceback__)
    where = f" at {Path(frames[-1].filename).name}:{frames[-1].lineno}" if frames else ""
    return (f"{name} failed ({type(error).__name__}: {error}{where}), so it was not applied to this push "
            "(fail open); the other rules were. Tell the Performance Lead (PL-guardrails) with this line.")


def check(repo: Path, base: str, head: str) -> tuple[list[tuple[Rule, list[Added]]], list[tuple[str, str]]]:
    """(refusals [(rule, hits)], warnings [(kind, text)]) for what HEAD adds over BASE."""
    # Fixed prefixes: a user's diff.noprefix / diff.srcPrefix would otherwise drop every file from the parse.
    diff, names = run_both(repo, ["diff", "-U0", "--no-color", "--no-renames", "--no-ext-diff", "--src-prefix=a/",
                                  "--dst-prefix=b/", base, head, "--", SWIFT_SOURCES, SWIFT_TESTS,
                                  *SHIPPED_BUILD_SPECS],
                           ["diff", "--name-only", "--no-renames", base, head])
    changes = parse_diff(diff)
    warnings: list[tuple[str, str]] = []
    if diff.strip() and not changes:
        warnings.append(("guardrails", "could not read this push's diff, so no rule ran on it (fail open); tell the "
                         "Performance Lead (PL-guardrails) with the output of: git diff -U0 " + f"{base} {head} | head"))
    paths = sorted(changes)
    texts = blobs(repo, [(head, p) for p in paths] + [(base, p) for p in paths]
                  + [(head, BENCHES), (head, OWNERS)])
    for path in paths:
        change = changes[path]
        text = texts.get((head, path), "")
        change.head_lines = text.split("\n")
        change.base_lines = texts.get((base, path), "").split("\n")
        change.has_perf_hot = "perf-hot:" in text
    head_types = GenericTypes(repo, head, [texts.get((head, p), "") for p in paths])
    base_types = GenericTypes(repo, base, [texts.get((base, p), "") for p in paths])
    for path in paths:
        changes[path].head_types, changes[path].base_types = head_types, base_types
    files = [changes[p] for p in paths]
    moved = collections.Counter(r.text.strip() for c in files for r in c.removed if r.text.strip())
    refusals = []
    for rule in RULES:
        scoped = [f for f in files if f.path.startswith(rule.scope) or f.path.endswith(rule.scope)]
        try:
            hits = rule.find(scoped, moved)
        except Exception as error:  # fail open for this rule only: a bug in one rule must not switch off the rest
            warnings.append(("guardrails", check_failure(f"rule {rule.id}", error)))
            continue
        warnings += [(rule.id, f"{h.path}:{h.number}: {h.text}") for h in hits if getattr(h, "warn", False)]
        hits = [h for h in hits if not getattr(h, "warn", False)]
        if hits:
            refusals.append((rule, hits))
    try:
        benches = json.loads(texts[(head, BENCHES)]) if (head, BENCHES) in texts else {}
    except json.JSONDecodeError:
        benches = {}
    try:
        warnings += [("perf-hot", w) for w in perf_hot_warnings(changes, benches)]
    except Exception as error:  # a broken warning must not switch off the refusals above
        warnings.append(("guardrails", check_failure("perf-hot", error)))
    if (head, OWNERS) in texts:
        names_list = [f for f in names.split("\n") if f]
        try:
            warnings += [("owner", w) for w in owner_warnings(names_list, parse_owners(texts[(head, OWNERS)]))]
        except Exception as error:  # a broken warning must not switch off the refusals above
            warnings.append(("guardrails", check_failure("owner", error)))
    return refusals, warnings


def check_push(repo: Path, base: str, head: str, upstream_ref: str = UPSTREAM):
    """check() for a pushed BASE..HEAD, without the lines the push only brings in from UPSTREAM_REF.

    A branch merged with or rebased onto feat-cmux-next pushes every line others landed there since its fork
    point. CI never runs these rules, so those lines can carry debt the push did not write (a skip reason, a
    clone with old or no hooks, --no-verify). Rebased or fast-forwarded onto it (its merge base with HEAD
    descends from BASE): the range starts at that merge base. Merged it in (neither descends from the other):
    a hit counts only when it is also new against that merge base, and the warnings are the branch's own
    plus any rule that failed on the pushed range.
    """
    upstream = git(repo, "merge-base", head, upstream_ref, check=False).strip()
    if not upstream or upstream == base or is_ancestor(repo, upstream, base):
        return check(repo, base, head)
    if is_ancestor(repo, base, upstream):
        return check(repo, upstream, head)
    pushed, pushed_warnings = check(repo, base, head)
    branch, warnings = check(repo, upstream, head)
    # A rule that failed on the pushed range is off for this push even when it ran on the branch's own range.
    warnings += [w for w in pushed_warnings if w[0] == "guardrails" and w not in warnings]
    own = collections.Counter((rule.id, h.path, h.text.strip()) for rule, hits in branch for h in hits)
    refusals = []
    branch_hits = {rule.id: hits for rule, hits in branch}
    for rule, hits in pushed:
        if rule.net:
            # A count has no line to intersect: a bucket refuses when it is over in both ranges, by the smaller excess.
            mine = {h.bucket: h for h in branch_hits.get(rule.id, [])}
            kept = [h if h.excess <= mine[h.bucket].excess else mine[h.bucket] for h in hits if h.bucket in mine]
            if kept:
                refusals.append((rule, kept))
            continue
        kept = []
        for hit in hits:
            key = (rule.id, hit.path, hit.text.strip())
            if own[key] > 0:
                own[key] -= 1
                kept.append(hit)
        if kept:
            refusals.append((rule, kept))
    return refusals, warnings


def parse_skip(value: str) -> tuple[set[str], str | None]:
    """(rule ids, error) from a CMUX_GUARDRAILS_SKIP_REASON of the form "<rule>[,<rule>]: <why>"."""
    known = sorted(rule.id for rule in RULES)
    named, colon, why = value.partition(":")
    ids = {r.strip() for r in named.split(",") if r.strip()}
    if not colon or not why.strip() or not ids:
        return set(), f'{SKIP_ENV} must be "<rule>[,<rule>]: <why>" (rules: {", ".join(known)})'
    unknown = sorted(ids - set(known))
    if unknown:
        return set(), f"{SKIP_ENV} names no rule {', '.join(unknown)} (rules: {', '.join(known)})"
    return ids, None


def format_report(refusals, warnings) -> tuple[str, bool]:
    """The text to print and whether the push is refused.

    CMUX_GUARDRAILS_SKIP_REASON="<rule>[,<rule>]: <why>" lets only the named rules through; the others still
    refuse, and a value that names no known rule skips nothing.
    """
    lines = []
    if warnings:
        lines.append("guardrails: warnings (never refuse):")
        lines += [f"  [{kind}] {text}" for kind, text in warnings]
    skip = os.environ.get(SKIP_ENV, "").strip()
    skip_ids, skip_error = parse_skip(skip) if skip else (set(), None)
    skipped = [(rule, hits) for rule, hits in refusals if rule.id in skip_ids]
    refusals = [(rule, hits) for rule, hits in refusals if rule.id not in skip_ids]
    for rule, hits in skipped:
        first = hits[0]
        lines.append(f"guardrails: SKIPPED by {SKIP_ENV}={skip!r}: [{rule.id}] {len(hits)} hit(s), first "
                     f"{first.path}:{first.number}. Say so in your report.")
    if not refusals:
        return "\n".join(lines), False
    lines.append("guardrails: this push adds architecture debt (scripts/cmux-next/guardrails.py):")
    for rule, hits in refusals:
        lines.append(f"  [{rule.id}] {rule.title}")
        for hit in hits[:20]:
            lines.append(f"    {hit.path}:{hit.number}: {hit.text.strip()[:140]}")
        if len(hits) > 20:
            lines.append(f"    ... {len(hits) - 20} more")
        lines.append(f"    why: {rule.why}")
        lines.append(f"    do:  {rule.fix}")
        if rule.escape:
            lines.append(f"    reviewed escape: `{rule.escape}` (only when it is true)")
    if skip_error:
        lines.append(f"guardrails: {skip_error}; it skipped nothing.")
    elif skip_ids:
        lines.append(f"guardrails: {SKIP_ENV} skips only {', '.join(sorted(skip_ids))}; the rules above still refuse.")
    lines.append(f"Skip once (only with a real reason): {SKIP_ENV}=\"<rule>[,<rule>]: <why>\" git push ...; "
                 "it skips only the named rules; say it in your report. Debt counts: plans/cmux-next/codebase-health.md.")
    return "\n".join(lines), True


def default_base(repo: Path, head: str) -> str:
    base = git(repo, "merge-base", head, UPSTREAM, check=False).strip()
    return base or f"{head}~1"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo")
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--list", action="store_true", help="print the rules")
    args = parser.parse_args(argv)
    if args.list:
        for rule in RULES:
            print(f"{rule.id}: {rule.title}\n  why: {rule.why}\n  do:  {rule.fix}\n  escape: {rule.escape or '-'}")
        return 0
    repo = Path(args.repo or git(Path.cwd(), "rev-parse", "--show-toplevel").strip())
    started = time.monotonic()
    refusals, warnings = check(repo, args.base or default_base(repo, args.head), args.head)
    text, refused = format_report(refusals, warnings)
    if text:
        print(text)
    print(f"guardrails: {'refused' if refused else 'ok'} ({time.monotonic() - started:.2f}s)")
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main())

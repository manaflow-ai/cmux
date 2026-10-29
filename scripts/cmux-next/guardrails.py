#!/usr/bin/env python3
"""cmux-next guardrails: refuse new architecture debt in what a push adds; warn on hot paths and owned areas.

Run by the pre-push hook through `prepush-gate.py --pre-push` (and by a plain local `prepush-gate.py`),
never by CI (Lawrence 2026-10-23: no new CI gates). Only Swift lines the push ADDS under
Packages/macOS/CmuxNext/Sources count, plus unchanged lines that become debt because the push changed the
line that gives them their context (`struct` -> `class` around a static, a view renamed to a `...Row`, an
edited or deleted deinit in a generic class's body, or a type made generic around the classes in its
extensions, read in every Sources and Tests file that extends it: generic_signature_context) or the comment
that escaped them (a deleted or reworded `// <rule>-allow:` line).
Per file and rule it is a count ratchet: an added match is new only when the same file does not remove as
much debt (judged on the base text with the same context and escape rules, so editing a line that already
has debt adds none, and a removed escaped line does not pay for an unescaped one), and an added line whose
text another file removes as debt is a move. Only the push's own commits count (push_range.py, the same
range the gate's scanners and the arch ratchet judge): lines a push only brings in from origin/feat-cmux-next
(a merge or rebase onto it) never count. A merge is judged over the upstream it merged, less what the branch's
old remote head already had over the upstream it started from (check_own), so an upstream removal of debt never
pays for the branch's own. Base debt never blocks a push
(plans/cmux-next/codebase-health.md has the counts). A rule another check already refuses before the push is
not repeated here (sleeps: check-concurrency.sh; assumeIsolated: crash_ratchet.py's ban); a rule shared with
a CI check reads that check's own definition (unchecked-sendable: crash_ratchet.py's class and escape;
app-size: count-swift-code-lines.py's lexer).

Refusals (rules below, `--list` prints them): each names the rule, why, the right pattern and its escape.
Skip once: CMUX_GUARDRAILS_SKIP_REASON="<rule>[,<rule>]: <why>" skips only the named line rules; say it in
your report.
A rule (or warning check) that raises is not applied to that push and prints a `guardrails` warning that names
it; the other rules still run and refuse (fail open per check, so one broken rule never switches off the rest).

Arch ratchet (one entry, one report): run_push() also runs scripts/cmux-next/arch-ratchet.py, next to this file,
on a thread (start_ratchet() starts it early so it runs beside prepush-gate's scanners). It holds the counts of
plans/cmux-next/arch-ratchet.json (arch_counts.py defines them): stateful singletons and file-scope globals,
global mutable statics, MainActor.assumeIsolated outside seam adapters, app Notification.Name broadcasts,
observer sites, layer edges. Those concerns have no line rule here, so there is one definition and one escape
per concern: the dated exception in arch-ratchet.json (CMUX_GUARDRAILS_SKIP_REASON does not skip them, and no
inline marker hides them).
Warnings (never refuse):
  perf-hot  the push changes a function marked `// perf-hot: <budget> <path-id>` (in the comment block above
            its declaration, trailing on the declaration line, or trailing on the `{` line of a wrapped
            signature); names the bench from scripts/cmux-next/perf-hot-benches.json to run before and after
            on the fleet. A marker the push touches that marks no declaration warns too.
  owner     the push touches an area in plans/cmux-next/OWNERS.md; names the owner and the doc to read.

`app-size` is a net count over the push, not a per-line rule, in source lines as CI's check-app-size.sh --base
counts them (count-swift-code-lines.py's lexer: blank and comment lines never count, either way). It refuses
when the root (top-level AppDelegate, CmuxNextApp and AppServices(+X).swift) adds more than ROOT_BUDGET lines per
push (lines moved into it from feature files count; lines moved out of it into other App files are neutral: no
root shrink and no growth), and when a new App file is
neither a move nor the push's one AppServices+<Domain>Host.swift of one-line forwards (outside the budget), so
feature logic does not become wiring by moving into a root file. It warns (never refuses, for now) when the App outside the root or CmuxNextApp as a
whole grows (the same total check-app-size.sh --base computes, a split file's new imports included), with the
bytes added and the package the code goes to. This is the only App-size
limit in force on a push: CI's check-app-size.sh step is continue-on-error and its absolute cap
(app-size-baseline.txt) is below the App's size today.
`app-type`, its own rule (so a fault in its brace scan turns off only it), refuses a new type that is not a move
in an existing App file or in a new App file that passes as a move (the new-file rule's god-file dodge), at any
depth: top-level, a member of an `extension`, or nested with more than PRIVATE_TYPE_MAX source lines (a type's
`extension` blocks in its file count toward its size); a small private or nested helper and `// app-type-allow:`
(on that type only, not the types inside it) pass, and a helper that stops being one is judged whole. It shares
one move pool per push with the new-file rule (move_pools).

  scripts/cmux-next/guardrails.py                    # what HEAD adds over origin/feat-cmux-next
  scripts/cmux-next/guardrails.py --base A --head B   # exactly what B adds over A
  scripts/cmux-next/guardrails.py --list
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures
import dataclasses
import functools
import importlib.util
import itertools
import json
import os
import re
import subprocess
import sys
import threading
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, NamedTuple

HERE = Path(__file__).resolve().parent
# The lexical helpers and the generic-class deinit detector check-concurrency.sh's crash-class rule shares.
_SCOPE = importlib.util.spec_from_file_location("cmux_next_swift_scope", HERE / "swift_scope.py")
swift_scope = importlib.util.module_from_spec(_SCOPE)
sys.modules[_SCOPE.name] = swift_scope  # its NamedTuple resolves its module through sys.modules
_SCOPE.loader.exec_module(swift_scope)
code_of, escaped, enclosing_openers = swift_scope.code_of, swift_scope.escaped, swift_scope.enclosing_openers
COMMENT_LINE, ATTRIBUTE, ATTRIBUTE_LINE = swift_scope.COMMENT_LINE, swift_scope.ATTRIBUTE, swift_scope.ATTRIBUTE_LINE

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
PERF_HOT = re.compile(r"//\s*perf-hot:\s*(?P<budget>\S+)(?:\s+(?P<path>[\w-]+))?")
DECL = re.compile(r"\b(func|init|deinit|subscript|var)\b")


def load_sibling(name: str, filename: str):
    """The module FILENAME beside this file (the checkout's scripts/cmux-next, or the installed checks snapshot)."""
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


git_batch = load_sibling("cmux_next_git_batch", "git_batch.py")
# The crash ratchet's own Swift classifier, escape and bans: the unchecked-sendable rule reads them, never a copy.
ratchet = load_sibling("cmux_next_crash_ratchet", "crash_ratchet.py")


def git_env() -> dict[str, str]:
    """The environment for git: a hook's GIT_INDEX_FILE / GIT_WORK_TREE describe the pushing checkout, not a rev."""
    return {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}


def git(repo: Path, *args: str, check: bool = True) -> str:
    result = git_batch.run(repo, list(args), env=git_env())
    if check and result.returncode != 0:
        raise SystemExit(f"guardrails: git {' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout.decode("utf-8", "replace")




@dataclass
class Added:
    """A changed line: an added line (NUMBER is 1-based in head) or a removed one (1-based in base)."""
    path: str
    number: int
    text: str


def escape_window(lines: list[str], index: int) -> list[int]:
    """The 0-based lines whose comment can escape LINES[INDEX] (swift_scope.escaped's window): the line, the
    comment and attribute block directly above it, or (no such block) the previous code line, whose trailing
    comment counts."""
    window = [index]
    j = index - 1
    while j >= 0 and (COMMENT_LINE.match(lines[j]) or ATTRIBUTE_LINE.match(lines[j])):
        window.append(j)
        j -= 1
    if j >= 0 and j == index - 1:
        window.append(j)
    return window


@dataclass
class Version:
    """One side of a changed file: its lines and the 1-based lines the push changed on that side.

    TOUCHED is CHANGED plus, around each hunk that is empty on one side (a pure deletion or insertion), the
    unchanged line before and after it, marked on both sides: a context rule reads it, so a deletion inside a
    class body or a loop still touches its context, and the base side marks the same lines, so old debt there
    pairs with itself. TYPES answers which type names are generic at that side's revision (the generic-class
    rule reads an extension's context with it); without one, only the file's own declarations count.
    MAIN_DEFAULT is whether the file's target is main actor by default (uiSwiftSettings).
    """
    path: str
    lines: list[str]
    changed: set[int]
    touched: set[int] = field(default_factory=set)
    memo: dict = field(default_factory=dict)
    types: "GenericTypes | None" = None
    main_default: bool = True


@dataclass
class FileChange:
    path: str
    head_lines: list[str]
    added: list[Added] = field(default_factory=list)
    touched: set[int] = field(default_factory=set)  # head line numbers the push changed (deletions mark their spot)
    removed: list[Added] = field(default_factory=list)  # numbered in base
    base_lines: list[str] = field(default_factory=list)
    is_new: bool = False
    is_deleted: bool = False
    has_perf_hot: bool = False
    memo: dict = field(default_factory=dict)  # per-push results of this file that rules share (app_file)
    head_types: "GenericTypes | None" = None
    base_types: "GenericTypes | None" = None
    # The unchanged lines around each hunk that is empty on one side, numbered on each side (Version.touched).
    head_anchors: set[int] = field(default_factory=set)
    base_anchors: set[int] = field(default_factory=set)
    head_main: bool = True
    base_main: bool = True

    @property
    def head(self) -> Version:
        changed = {a.number for a in self.added}
        return Version(self.path, self.head_lines, changed, changed | self.head_anchors, types=self.head_types,
                       main_default=self.head_main)

    @property
    def base(self) -> Version:
        changed = {r.number for r in self.removed}
        return Version(self.path, self.base_lines, changed, changed | self.base_anchors, types=self.base_types,
                       main_default=self.base_main)


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
    keep: Keep | None = None  # context: a static of a class, a store in a row, a generic class without a deinit
    code: Callable[[str], str] = code_of  # the code PATTERN reads (comments dropped, string contents blanked)
    window: Callable[[list[str], int], list[int]] = escape_window  # the lines whose comment can carry ESCAPE


def escape_neighbours(lines: list[str], touched: set[int]) -> set[int]:
    """0-based lines whose escape_window() can hold a TOUCHED (1-based) line: the line itself, the line below
    it, and further down while every line from the touched one on is a comment or attribute line (the block
    above the code line it escapes). crash_ratchet.allow_lines() (the line and the one above) is inside."""
    out = set()
    for number in touched:
        i = number - 1
        out.update((i, i + 1))
        k = i
        while 0 <= k < len(lines) and (COMMENT_LINE.match(lines[k]) or ATTRIBUTE_LINE.match(lines[k])):
            out.add(k + 1)
            k += 1
    return {i for i in out if 0 <= i < len(lines)}


def is_debt(version: Version, index: int, matcher: Matcher) -> tuple[bool, list[int]]:
    """(VERSION's line INDEX is debt: KEEP holds for it and it carries no escape, the 1-based openers KEEP read)."""
    kept, openers = matcher.keep(version, index) if matcher.keep is not None else (True, [])
    if not kept or (matcher.escape is not None and escaped_in(version.lines, index, matcher)):
        return False, openers
    return True, openers


def rejudged(version: Version, matcher: Matcher) -> set[int]:
    """0-based unchanged lines of VERSION that match MATCHER and whose debt the push may have changed: the escape
    window holds a touched line (the push deleted or reworded the `// <rule>-allow:` comment, or put a line
    between it and the code), or, for a context rule, a line KEEP reads is touched (Version.touched): `struct` ->
    `final class` around an old static, a view renamed to `...Row` around an old store reference, an edit or a
    deletion inside a generic class's body."""
    lines = version.lines

    def matches(index: int) -> bool:
        return (index + 1 not in version.changed and matcher.pattern.search(lines[index]) is not None
                and matcher.pattern.search(matcher.code(lines[index])) is not None)

    found: set[int] = set()
    if matcher.escape is not None and version.touched:
        found.update(index for index in escape_neighbours(lines, version.touched)
                     if matches(index) and any(j + 1 in version.touched for j in matcher.window(lines, index)))
    if matcher.keep is not None and version.touched:
        found.update(index for index in range(len(lines)) if index not in found and matches(index)
                     and any(o in version.touched for o in is_debt(version, index, matcher)[1]))
    return found


def unchanged_pairs(change: FileChange) -> dict[int, int]:
    """{0-based head line: 0-based base line} for every line the push did not change.

    The diff's unchanged lines are the same lines in the same order on both sides, so the n-th unchanged head
    line is the n-th unchanged base line. A final newline adds no line (`text.split("\\n")` leaves a last "").
    """
    def unchanged(lines: list[str], changed: set[int]) -> list[int]:
        count = len(lines) - (1 if lines and lines[-1] == "" else 0)
        return [i for i in range(count) if i + 1 not in changed]

    head = unchanged(change.head_lines, {a.number for a in change.added})
    base = unchanged(change.base_lines, {r.number for r in change.removed})
    if len(head) != len(base):
        raise ValueError(f"{change.path}: the diff leaves {len(head)} lines unchanged at head and {len(base)} at "
                         "base; the diff and the file texts disagree")
    return dict(zip(head, base))


def file_debt(change: FileChange, matcher: Matcher) -> tuple[list[Added], list[Added]]:
    """(head debt, base debt) of one changed file: its changed lines that are debt on their side, plus every
    unchanged line whose debt the push may have changed, judged on both sides.

    An unchanged line rejudged() finds on either side is judged on both: at head it is debt the push leaves, at
    base debt the push takes away, and resolve() pairs the two copies (same text). So an edit that keeps the
    escape or the context (a reworded reason, `final class A {` -> `final class A: Sendable {`) or only touches
    lines next to old unescaped debt (a deleted code line above its comment block, a new class opened around an
    old static of a class) adds none, and only a line that is debt at head and was not at base is new. Judging
    each side's candidates on that side alone counted old debt as new when only the head reached the edit.
    """
    head, base = change.head, change.base
    head_debt = [a for a in change.added if matcher.pattern.search(matcher.code(a.text))
                 and is_debt(head, a.number - 1, matcher)[0]]
    base_debt = [r for r in change.removed if matcher.pattern.search(matcher.code(r.text))
                 and is_debt(base, r.number - 1, matcher)[0]]
    head_lines, base_lines = rejudged(head, matcher), rejudged(base, matcher)
    if not head_lines and not base_lines:
        return head_debt, base_debt
    to_base = unchanged_pairs(change)
    to_head = {b: h for h, b in to_base.items()}
    for h, b in sorted({(h, to_base[h]) for h in head_lines} | {(to_head[b], b) for b in base_lines}):
        if head.lines[h] != base.lines[b]:
            raise ValueError(f"{change.path}: unchanged head line {h + 1} is not base line {b + 1}")
        if is_debt(head, h, matcher)[0]:
            head_debt.append(Added(change.path, h + 1, head.lines[h]))
        if is_debt(base, b, matcher)[0]:
            base_debt.append(Added(change.path, b + 1, base.lines[b]))
    return head_debt, base_debt


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


def escaped_in(lines: list[str], index: int, matcher: Matcher) -> bool:
    """MATCHER's escape in a comment of its window around LINES[INDEX]."""
    return any(matcher.escape.search(lines[j]) for j in matcher.window(lines, index))


def matcher_rule(matcher: Matcher) -> Callable[[list[FileChange], collections.Counter], list[Added]]:
    def find(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
        return resolve([file_debt(c, matcher) for c in changes])
    return find


def line_rule(pattern: str, escape: str | None) -> Callable[[list[FileChange], collections.Counter], list[Added]]:
    marker = re.compile(r"//\s*" + re.escape(escape) + r"\s*\S") if escape else None
    return matcher_rule(Matcher(re.compile(pattern), marker))


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
# origin/feat-cmux-next up to 2952080b0a5 with CI's lexer and app_size as of the commit "fix(guardrails app-size):
# moves are credited from lines the push really lost, on whole blocks, with imports out of the moved share" (before
# credit_moves matched a generic line to its neighbour and a `}` to an opener in its run, and before phase 2 took
# phase 1's renames):
# - ROOT_BUDGET: the wiring of a few domains per push (a stored instance, its construction, passing it on), never
#   their logic; the `total` warning asks the same push to pay for it with an App shrink. Measured per push, the
#   unit the rule limits: the 1243 `git push`es to feat-cmux-next from 2026-10-20 00:00Z to 2952080b0a5 (GitHub's
#   repository activity API, activity_type push, each push's before..after through this rule's own root count;
#   PR merges land on GitHub, where no pre-push hook runs). 54 pushes changed root files, 52 of them landing more
#   than one first-parent commit: net root growth p50 +2, p95 +16, max +41; 53 of 54 are within +30. The one over
#   (705557dc225..95b7af279ab, +41, three commits) is folder and harness logic in AppServices+WorkContext.swift
#   (4aa19112632), not wiring.
# - HOST_FILE_MAX: one domain's Host protocol forwards, one member per line; a larger Host protocol is a sign that
#   the domain still reaches into the App. No AppServices+<Domain>Host.swift exists yet; the four `*Host` protocols
#   in Sources have 4 to 9 members (BrowserRestoredSessionHost 9), so 30 lines (the opener, its imports and attribute
#   and its `}` included) is about 3x the largest known Host; a bigger domain splits into two Host files over two
#   pushes.
# - MOVE_RUN: one or two lines in a row that match removed text can be chance (`let x = 0`, a shared call); a
#   moved block is longer. Over the last 1500 Sources commits to 2952080b0a5, each against its first parent, with
#   app_size's own share (credit_moves over lost_lines, imports out of both counts): of 133 new files git calls a
#   >= 90% rename, 132 reach MOVE_SHARE at runs of 2 or 3, 129 at 4, 122 at 5; of 1781 plain new files the p95
#   credited share is 0.17 at 2, 0.14 at 3, 0.08 at 4. 3 is the longest run that still credits every near-pure
#   move run 2 credits.
# - MOVE_SHARE: a git mv or a split also edits some lines (a renamed type, a changed access level); a mostly
#   unchanged file is still a move, not new code. Same commits and share at MOVE_RUN 3: 0.8 passes 132 of 133
#   renames >= 90% similar and 15 of 30 at 80-89%, and passes 22 of 1781 plain new files (splits git does not see
#   as renames); 0.7 would pass 25 of 30 at 80-89% and 28 plain new files.
# - MOVE_GENERIC_PER_LINE: a moved specific line usually closes one or two blocks (`}` of an `if` and of its
#   function); generic lines beyond that are not explained by the run's specific lines.
# - The `other` and `total` buckets as warnings: of the last 600 first-parent App commits (2026-10-20..23, each
#   against its first parent), 404 grew feature App files (net +14726 source lines against -2417 shrinks); the App grew +12500 source lines in those four days. A refusal would stop
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
# A type declaration (lead decision (b), 2026-10-23; `app-type`): a new one in an existing App file, or in a new
# App file that passes as a move, is held to the new-file rule, so the refusal of a new file does not send its type
# into a god file (CLAUDE.md: one major type per file, nested types included). An `extension` is not a type, but
# its block counts toward the size of the type it extends in the same file; a private or fileprivate helper of
# PRIVATE_TYPE_MAX source lines or fewer, and a type nested in another type's body that is that small, stay with
# the type they serve (CLAUDE.md's "small, closely-bound helpers").
TYPE_DECL_BODY = (rf"(({ATTRIBUTE}|public|package|internal|private|fileprivate|final|open|nonisolated|"
                  r"indirect|distributed)\s+)*(?P<kind>struct|class|enum|actor|protocol)\s+"
                  # `class func`, `class var` and the like declare a member, not a type
                  r"(?!(func|var|let|subscript|init|deinit|typealias|override|final|static|dynamic|required|"
                  r"convenience|nonisolated|public|package|internal|private|fileprivate|open)\b)"
                  r"(?P<name>[A-Za-z_]\w*)")
TYPE_DECL = re.compile("^" + TYPE_DECL_BODY)  # on one statement's code (type_scan's code text, split at `;`)
# may_add_type's cheap test on raw added lines: a declaration after a block comment or an earlier `;` statement
# too. It may over-match (a comment's words); the scan then decides.
TYPE_DECL_ANYWHERE = re.compile(r"(?:^|[;/])\s*" + TYPE_DECL_BODY)
TYPE_ALLOW = re.compile(r"//\s*app-type-allow:\s*\S")
TYPE_ESCAPE = "// app-type-allow: <why this type must share its file>"
PRIVATE_TYPE_MAX = 15  # the lead's value (decision (b)): source lines of a private helper type kept in its file
# A declaration that names the brace scope it opens (type_decls), so a nested type's name is qualified by it.
SCOPE_DECL = re.compile(rf"^(({ATTRIBUTE}|(public|package|internal|private|fileprivate)(\(\w+\))?|final|open|"
                        r"nonisolated|static|class|override|mutating|nonmutating|convenience|required|lazy|dynamic|"
                        r"distributed|weak|unowned)\s+)*(?P<kind>extension|func|init|deinit|subscript|var|let|case|"
                        r"typealias|associatedtype|import)\b\s*(?P<name>[A-Za-z_][\w.]*)?")
# A base type that may be a small helper (indented, so nested, or private): only then can a push that adds no
# type declaration line still grow a helper past its exemption, so only then does app-type scan the file.
HELPER_TYPE = re.compile(r"^(?:[ \t]+|[^\n]*\b(?:private|fileprivate)\b[^\n]*?)\b(?:struct|class|enum|actor|protocol)"
                         r"[ \t]+[A-Za-z_]", re.M)
# The type scan's tokens per lexer mode: only what can change the mode or the brace depth, so type_scan jumps
# between them with re.search instead of stepping through every character in Python.
CODE_TOKENS = re.compile(r'//|/\*|(?P<hashes>#*)(?P<quote>"""|")|(?P<xregex>#+)/|/|[{}]')
INTERP_TOKENS = re.compile(r'//|/\*|(?P<hashes>#*)(?P<quote>"""|")|(?P<xregex>#+)/|/|[{}()]')
BLOCK_TOKENS = re.compile(r"/\*|\*/")
# A bare regex literal `/.../` (SE-0354): no space after the opening `/` or before the closing one, on one line;
# an escape or a character class may hold a `/`.
BARE_REGEX = re.compile(r"/(?![\s/*])(?:\\.|\[(?:\\.|[^\]\\])*\]|[^/\\\[])+(?<!\s)/")
REGEX_KEYWORDS = frozenset(("return", "case", "in", "where", "throw", "try", "await", "if", "guard", "while", "else",
                            "is", "as", "switch"))
DESIGN = "plans/cmux-next/architecture-refactor-DESIGN.md section 4, \"Destination map\""


@functools.cache
def swift_lexer() -> Callable[[str], list[bool]]:
    """CI's lexer, count-swift-code-lines.py's `source_line_flags`, from next to this file, loaded on first use.

    One lexer, not a copy: the hook runs the installed copy of scripts/cmux-next, which holds both files. Only
    app-size reads it, so it loads inside that rule: a lexer that does not load (CI owns that file) turns off
    app-size alone through check()'s per-rule fail open, never this module and every rule with it. A failed load
    is not cached; the next push tries again.
    """
    spec = importlib.util.spec_from_file_location("cmux_next_count_swift_code_lines",
                                                  Path(__file__).with_name("count-swift-code-lines.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.source_line_flags


# A file with none of these has no block comment, multi-line string or extended regex literal, so a line's kind is its
# own: a source line is one that is not blank and does not start with `//` (checked against CI's lexer on all 2738
# App blobs of the 296 replayed pushes and the tip: identical; 2681 of them are plain, 98 % of the bytes).
MULTILINE_MARKERS = ("/*", '"""', "#/")
LEX_CACHE: dict = {"dir": None}  # check() sets the per-repository cache directory of lexed blobs (or None)
LEX_CACHE_VERSION = "1"  # bump when count-swift-code-lines.py's line rules change


def lex_cache_dir(repo: Path) -> Path | None:
    """<git common dir>/cmux-guardrails/lex-<version>: CI's lexer's flags of a blob, keyed by its object id (a
    rebase or a retried push reuses them), or None when the common dir is not found (no cache, fail open). Read from
    the .git entry, not a git process (check() runs a fixed number of them)."""
    try:
        dot = repo / ".git"
        if dot.is_dir():
            common = dot
        else:
            gitdir = Path(dot.read_text().split("gitdir:", 1)[1].strip())
            gitdir = gitdir if gitdir.is_absolute() else repo / gitdir
            link = gitdir / "commondir"
            common = (gitdir / link.read_text().strip()) if link.is_file() else gitdir
        return common.resolve() / "cmux-guardrails" / f"lex-{LEX_CACHE_VERSION}"
    except (OSError, IndexError, ValueError):
        return None


def in_diff_scope(path: str) -> bool:
    """PATH is one of check()'s diff pathspecs (SWIFT_SOURCES, SWIFT_TESTS, SHIPPED_BUILD_SPECS), so its blobs are read
    while the content diff runs. A path this misses is read after the diff (check()'s late read)."""
    return ((path.startswith((SOURCES, TESTS)) and path.endswith(".swift")) or path.startswith(".github/workflows/")
            or path in ("scripts/build-sign-upload.sh", "Packages/macOS/CmuxNext/Package.swift")
            or path.endswith(".xcconfig") or path.split("/")[-1] == "project.pbxproj")


def source_flags(text: str, blob: str | None = None) -> list[bool]:
    """CI's lexer's source-line flags of TEXT: computed per line for a plain file (MULTILINE_MARKERS), else read from
    the blob's cache entry or lexed and stored there. Any cache error only skips the cache."""
    lexer = swift_lexer()  # loads CI's lexer even for a plain file: one that does not load turns the App rules off
    if not any(marker in text for marker in MULTILINE_MARKERS):
        return [bool(line.strip()) and not line.lstrip().startswith("//") for line in text.split("\n")]
    entry = LEX_CACHE["dir"] / blob if LEX_CACHE["dir"] and blob and re.fullmatch(r"[0-9a-f]{40,64}", blob) else None
    if entry is not None:
        try:
            cached = entry.read_text()
            if len(cached) == text.count("\n") + 1 and set(cached) <= {"0", "1"}:
                return [c == "1" for c in cached]
        except OSError:
            pass
    flags = lexer(text)
    if entry is not None:
        try:
            entry.parent.mkdir(parents=True, exist_ok=True)
            tmp = entry.with_name(entry.name + f".{os.getpid()}.tmp")
            tmp.write_text("".join("1" if f else "0" for f in flags))
            os.replace(tmp, entry)
        except OSError:
            pass
    return flags


@dataclass
class NetHit(Added):
    """A hit of a net-count rule: BUCKET names what grew (`root`, `other`, `total`, `new:<path>`), EXCESS how much
    over LIMIT (the measured amount is EXCESS + LIMIT).

    An additive hit with EXCESS <= 0 is a measurement, not a finding: check() drops it; check_own needs it to take
    what the branch already had off a merge's amount. WARN marks a hit check() reports as a warning, never a refusal
    (the `app-size` growth buckets and app-type's `scan:<path>` for now). ADDITIVE: the amount adds up over pushes
    (lines of growth); a fact that is true or not (`new:<path>`, a new file or type; `scan:<path>`) is not: it is
    always reported, and in a merge it is the push's own only when the other side does not have it.
    check_own compares a merge's ranges by bucket, not by line text: a count has no line to match.
    """
    bucket: str = ""
    excess: int = 0
    warn: bool = False
    limit: int = 0
    additive: bool = True


@dataclass
class SourceLine(Added):
    """An added or removed source line; ORDINAL is its 1-based place among its file version's source lines."""
    ordinal: int = 0


@dataclass
class AppFile:
    """One changed App Swift file: its added and removed source lines, and whether it is new, deleted, a root file."""
    path: str
    is_new: bool
    root: bool
    added: list[SourceLine]
    removed: list[SourceLine]
    is_deleted: bool = False
    head_lines: list[str] = field(default_factory=list)
    base_lines: list[str] = field(default_factory=list)
    head_flags: list[bool] = field(default_factory=list)  # CI's lexer: whether each head line is a source line
    base_flags: list[bool] = field(default_factory=list)  # the same for each base line


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

    def source(flags: list[bool], changed: list[Added]) -> list[SourceLine]:
        ordinals = list(itertools.accumulate(map(int, flags)))
        return [SourceLine(line.path, line.number, line.text, ordinals[line.number - 1]) for line in changed
                if 0 < line.number <= len(flags) and flags[line.number - 1]]

    if "app_file" not in change.memo:  # app-size and app-type read the same AppFile: lex each file once
        head_blob, base_blob = change.memo.get("blobs") or (None, None)
        head_flags = source_flags("\n".join(change.head_lines), head_blob)
        base_flags = source_flags("\n".join(change.base_lines), base_blob)
        change.memo["app_file"] = AppFile(change.path, change.is_new, is_root_file(change.path),
                                          source(head_flags, change.added), source(base_flags, change.removed),
                                          change.is_deleted, change.head_lines, change.base_lines, head_flags,
                                          base_flags)
    return change.memo["app_file"]


@functools.cache
def string_tokens(hashes: int, multi: bool) -> re.Pattern:
    r"""Inside a string literal opened with HASHES `#` and one or three quotes: an escape (`\` and the same hashes;
    `\(` opens an interpolation) and the closing quotes with the same hashes. A raw string's bare `\` is text."""
    h = "#" * hashes
    return re.compile(r"\\" + h + r"(?:(?P<interp>\()|.)?|" + ('"""' if multi else '"') + h)


@functools.cache
def xregex_tokens(hashes: int) -> re.Pattern:
    """Inside an extended regex literal `#/.../#` with HASHES `#`: an escape, or the closing `/` and hashes."""
    return re.compile(r"\\.|/" + "#" * hashes)


def regex_can_start(line: str, index: int) -> bool:
    """A `/` at INDEX of LINE stands where an expression starts (after an operator, an opener, a comma, a colon,
    a keyword such as `return`, or at the start of the line), so it may open a bare regex, not divide."""
    before = line[:index].rstrip()
    if not before or before[-1] in "([{,:;=!&|?+-*<>%^~":
        return True
    word = re.search(r"\w+$", before)
    return word is not None and word.group() in REGEX_KEYWORDS


class TypeScan(NamedTuple):
    """type_scan's account of a file version: ROWS per line (brace depth at its start, whether it starts in code,
    its code braces in order, its code text: comments left out, string and regex contents blanked), and PROBLEM,
    where the braces do not balance (None when they do)."""
    rows: list[tuple[int, bool, str, str]]
    problem: str | None


def type_scan(lines: list[str]) -> TypeScan:
    """The code braces of LINES: braces in comments (nested block comments too), string literals (one-line,
    multi-line and raw, with their interpolations read as code) and regex literals (`/.../`, `#/.../#`) do not
    count, and a line that starts inside a comment, a multi-line string or a regex is not code.

    A `}` with no opener, a one-line string that does not close on its line, and braces, a comment, a string or a
    regex still open at the end are a PROBLEM: the scan cannot see where types start and end, so app-type warns
    and leaves the file out (never a silent clamp at depth 0).
    """
    rows: list[tuple[int, bool, str, str]] = []
    depth, stack, problem = 0, [], None  # frames: [mode, a string's hashes / a comment's nesting / open parens]
    for number, line in enumerate(lines, 1):
        start, in_code, braces, i, text = depth, not stack, [], 0, []
        while True:
            mode = stack[-1][0] if stack else "code"
            if mode in ("code", "interp"):
                match = (INTERP_TOKENS if mode == "interp" else CODE_TOKENS).search(line, i)
                if match is None:
                    if mode == "code":
                        text.append(line[i:])
                    break
                token = match.group()
                if mode == "code":  # the code text: what the file's own statements say, for TYPE_DECL
                    text.append(line[i:match.start()] + ("" if token == "//" else " " if token == "/*" else
                                                         '"' if match["quote"] else "/" if token == "/" else
                                                         "" if match["xregex"] else token))
                i = match.end()
                if token == "//":
                    break
                if token == "/*":
                    stack.append(["block", 1])
                elif match["quote"]:
                    stack.append(["multi" if match["quote"] == '"""' else "string", len(match["hashes"])])
                elif match["xregex"]:
                    stack.append(["xregex", len(match["xregex"])])
                elif token == "/":
                    regex = BARE_REGEX.match(line, match.start()) if regex_can_start(line, match.start()) else None
                    if regex:
                        i = regex.end()
                        if mode == "code":
                            text.append("/")
                elif token == "{":
                    depth += 1
                    braces.append("{")
                elif token == "}":
                    if depth == 0:
                        problem = problem or f"a `}}` with no opener on line {number}"
                    else:
                        depth -= 1
                        braces.append("}")
                elif token == "(":
                    stack[-1][1] += 1
                elif stack[-1][1] == 0:  # the `)` that closes the interpolation
                    stack.pop()
                else:
                    stack[-1][1] -= 1
            elif mode == "block":
                match = BLOCK_TOKENS.search(line, i)
                if match is None:
                    break
                i = match.end()
                stack[-1][1] += 1 if match.group() == "/*" else -1
                if stack[-1][1] == 0:
                    stack.pop()
            else:
                pattern = (xregex_tokens(stack[-1][1]) if mode == "xregex"
                           else string_tokens(stack[-1][1], mode == "multi"))
                match = pattern.search(line, i)
                if match is None:
                    break
                i = match.end()
                if mode != "xregex" and match["interp"]:
                    stack.append(["interp", 0])
                elif not match.group().startswith("\\"):
                    stack.pop()
                    if not stack:
                        text.append('"' if mode in ("string", "multi") else "/")
        strings = [k for k, frame in enumerate(stack) if frame[0] == "string"]
        if strings:  # a one-line string literal cannot go on to the next line
            problem = problem or f"a string literal that does not close on line {number}"
            del stack[strings[0]:]
        rows.append((start, in_code, "".join(braces), "".join(text)))
    if stack:
        names = {"block": "block comment", "multi": "multi-line string", "xregex": "regex literal",
                 "interp": "string interpolation"}
        problem = problem or f"a {names[stack[-1][0]]} still open at the end"
    elif depth:
        problem = problem or f"{depth} brace(s) still open at the end"
    return TypeScan(rows, problem)


class TypeDecl(NamedTuple):
    """A type declared in a file version (type_decls), at any depth, with 0-based line indexes.

    QUAL is its name qualified by the types, extensions and functions around it (`TextBoxView.Metrics`,
    `AppServices.Big`, `Model.load().Row`); DECL its declaration line, FIRST its first attribute line, END one past
    its closing `}`; PRIVATE marks `private`/`fileprivate`; NESTED that it is inside any brace scope; IN_EXTENSION
    that the scope right around it is an `extension` (such a member is held like a top-level type); PARENTS the
    QUALs of the types around it.
    """
    qual: str
    kind: str
    decl: int
    first: int
    end: int
    private: bool
    nested: bool
    in_extension: bool
    parents: tuple[str, ...]


class ExtensionBlock(NamedTuple):
    """An `extension NAME { ... }` block of a file version (type_decls): FIRST its first attribute line, END one
    past its closing `}` (0-based). Its members belong to the type NAME, so a type declared in the same file is
    judged with them (type_candidates)."""
    name: str
    first: int
    end: int


class Scopes(NamedTuple):
    """type_decls' account of a file version: its TYPES and its EXTENSIONS, each in order."""
    types: list[TypeDecl]
    extensions: list[ExtensionBlock]


def statements(code: str) -> list[str]:
    """The `;`-separated statements of a line's code text (type_scan), stripped: `let a = 1; struct Foo {`
    declares Foo, as `struct Foo {` does."""
    return [part.strip() for part in code.split(";")]


def type_decls(lines: list[str], rows: list[tuple[int, bool, str, str]]) -> Scopes:
    """Every type and extension block declared in LINES (type_scan's ROWS), in order: the brace scope stack names
    each scope a type, an extension or a member (func, init, var) opens, and closes each type and extension at its
    own `}`. A declaration is read from the line's code text, so one after a block comment (`/* x */ struct Foo`)
    or after an earlier statement (`let a = 1; struct Foo`) counts too."""
    found: list[list] = []  # a type's fields, or an extension's [name, first, end] (EXTENSION_ROWS holds which)
    extension_rows: set[int] = set()
    stack: list[tuple[str, str, int | None]] = []  # (kind, label, index in FOUND for a type or an extension)
    pending: tuple[str, str, int | None] | None = None  # the declaration the next `{` opens

    def first_line(j: int, depth: int) -> int:
        first = j
        while first > 0 and rows[first - 1][:2] == (depth, True) and ATTRIBUTE_LINE.match(rows[first - 1][3]):
            first -= 1
        return first

    for j, (depth, in_code, braces, code) in enumerate(rows):
        stored = False
        parts = statements(code) if code.strip() else []
        typed = next(((part, match) for part in parts if (match := TYPE_DECL.match(part)) is not None), None)
        if typed is not None:
            part, match = typed
            labels = [label for _, label, _ in stack if label]
            found.append([".".join(labels + [match["name"]]), match["kind"], j, first_line(j, depth), j + 1,
                          re.search(r"\b(private|fileprivate)\b", part[:match.start("kind")]) is not None,
                          bool(stack), bool(stack) and stack[-1][0] == "extension",
                          tuple(found[index][0] for _, _, index in stack
                                if index is not None and index not in extension_rows)])
            pending = ("type", match["name"], len(found) - 1)
        elif parts and (match := SCOPE_DECL.match(parts[0])) is not None:
            kind, name = match["kind"], match["name"] or match["kind"]
            if kind == "extension":
                extension_rows.add(len(found))
                found.append([name, first_line(j, depth), j + 1])
                pending = ("extension", name, len(found) - 1)
            elif kind in ("func", "init", "deinit", "subscript"):
                pending = ("member", f"{name}()", None)
            elif kind in ("var", "let"):  # a computed property opens its body on its own line, or not at all
                pending, stored = ("member", name, None), True
            else:
                pending = None
        for brace in braces:
            if brace == "{":
                stack.append(pending or ("other", "", None))
                pending = None
            else:
                pending = None
                if stack and (index := stack.pop()[2]) is not None:
                    found[index][-1 if index in extension_rows else 4] = j + 1
        if stored:
            pending = None
    return Scopes([TypeDecl(*entry) for k, entry in enumerate(found) if k not in extension_rows],
                  [ExtensionBlock(*entry) for k, entry in enumerate(found) if k in extension_rows])


def is_generic(key: str) -> bool:
    """KEY (a stripped line) has only braces, punctuation, numbers, attributes and GENERIC_WORDS: alone it proves no
    move. A token scan, linear in the line (a regex with a nested repeat backtracks exponentially on a long number).
    """
    return all(token.isdigit() or token in GENERIC_WORDS or (token[0] == "@" and len(token) > 1)
               or not (token[0].isalnum() or token[0] == "_") for token in TOKEN.findall(key))


class MoveCredit(NamedTuple):
    """credit_moves' account of one file's added lines: MOVED it credited, REST it neither credited nor explained.

    A line BRIDGE names or EXPLAINED took is in neither list. A summary of a file's new lines reads REST (and MOVED
    when moved-in lines are growth), so it comes from the same accounting as the credit and never needs a clamp.
    """
    moved: list[SourceLine]
    rest: list[SourceLine]


def braces(key: str) -> tuple[int, int]:
    """(opening, closing) braces of KEY's code, string contents and a trailing `//` comment left out."""
    code = code_of(key)
    return code.count("{"), code.count("}")


def credit_moves(lines: list[SourceLine], pools: list[collections.Counter], explained: collections.Counter | None = None,
                 bridge: Callable[[str], bool] = lambda key: False) -> MoveCredit:
    """Which of LINES (one file's added source lines, in head order) moved here from POOLS; consumes what it credits.

    A line is moved when its stripped text is in a pool (the first that has it) and it is in a run of at least
    MOVE_RUN source lines in a row that are all in a pool. A run credits each specific line and at most
    MOVE_GENERIC_PER_LINE generic ones (is_generic: `}`, `return nil`) per specific one: those match some removed
    line anywhere, so on their own they prove nothing. A run credits no more closing braces than its credited lines
    open: a `}` with no opener in the run (the `}` of a new `extension` or `Task { ... }` wrapped around a moved
    block) closes code that did not move, so the last such `}` lines are left out. Counting braces over the whole
    run, not line by line, keeps a block whose -U0 hunk starts with the `}` of the block before it (and ends with
    an opener) whole. What a run does not credit goes back to the pools.

    Two kinds of line keep a run going without being in it (neither credited nor counted toward MOVE_RUN), so a
    moved block is judged whole and never cut into pieces by lines that are not part of the move: a line BRIDGE
    names (a new file's imports, which its moved share leaves out), and a line EXPLAINED by the file's own side (a
    Counter of that side's removed lines, consumed). A specific line is taken from EXPLAINED first. A generic line
    goes with the specific line before it: after one EXPLAINED took (a re-indented statement's `}`) it is taken
    from EXPLAINED first, so a file's own re-added braces never join a moved block; otherwise (after a pool line:
    the braces of a moved block; at the start, after a gap or after a new line) it is taken from POOLS first. Either
    way it falls back to the other source.

    Returns the lines it credited (MoveCredit.moved) and the lines that neither a move nor the file's own side
    explains (MoveCredit.rest), both in head order: a line of a run that is not credited goes to EXPLAINED when
    EXPLAINED has it, and to REST only when it does not.
    """
    moved: list[SourceLine] = []
    rest: list[SourceLine] = []
    run: list[tuple[SourceLine, str, int]] = []

    def close() -> None:
        specific = sum(1 for _, key, _ in run if not is_generic(key))
        credited = [False] * len(run)
        if len(run) >= MOVE_RUN and specific > 0:
            generic_left = MOVE_GENERIC_PER_LINE * specific
            for i, (_, key, _) in enumerate(run):
                if not is_generic(key):
                    credited[i] = True
                elif generic_left > 0:
                    credited[i], generic_left = True, generic_left - 1
            unmatched = sum(closing - opening for (_, key, _), ok in zip(run, credited) if ok
                            for opening, closing in [braces(key)])
            for i in reversed(range(len(run))):
                if unmatched <= 0:
                    break
                opening, closing = braces(run[i][1])
                if credited[i] and is_generic(run[i][1]) and closing > opening:
                    credited[i], unmatched = False, unmatched - (closing - opening)
        for (line, key, source), ok in zip(run, credited):
            if ok:
                moved.append(line)
                continue
            pools[source][key] += 1
            if explained is not None and explained[key] > 0:
                explained[key] -= 1
            else:
                rest.append(line)
        run.clear()

    previous = None
    after = None  # where the last specific line came from: "pool", "explained", or None (start, gap, new line)
    for line in lines:
        key = line.text.strip()
        if previous is not None and line.ordinal != previous + 1:
            close()
            after = None
        previous = line.ordinal
        if bridge(key):
            continue
        generic = is_generic(key)
        if explained is not None and explained[key] > 0 and (not generic or after == "explained"):
            explained[key] -= 1
            after = after if generic else "explained"
            continue
        source = next((i for i, pool in enumerate(pools) if pool[key] > 0), None)
        if source is not None:
            pools[source][key] -= 1
            run.append((line, key, source))
            after = after if generic else "pool"
        elif explained is not None and explained[key] > 0:
            explained[key] -= 1
        else:
            close()
            rest.append(line)
            after = after if generic else None
    close()
    return MoveCredit(moved, rest)


def lost_lines(files: list[AppFile], readding: list[AppFile],
               keep: collections.Counter | None = None) -> collections.Counter:
    """The removed source lines of FILES (stripped) that no added line of READDING puts back: what really left.

    A specific line removed and added back with the same stripped text (a re-indented block, a line git's -U0
    diff pairs differently) is still there, so it is not lost and cannot be credited as moved anywhere. A generic
    line is lost whenever it is removed: every edit re-adds braces, and credit_moves credits a generic line only
    in a run that a specific moved line proves, never after a line the file's own side explains, and a `}` only
    when the run opens it. KEEP (stripped lines) are added lines of READDING that do not put a line back: the
    placements being judged (app_type's types), which a move into them must still be able to explain.
    """
    removed = collections.Counter(r.text.strip() for f in files for r in f.removed)
    added = collections.Counter(a.text.strip() for f in readding for a in f.added) - (keep or collections.Counter())
    return collections.Counter({key: count if is_generic(key) else count - added[key]
                                for key, count in removed.items() if is_generic(key) or count > added[key]})


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


def small_helper(decl: TypeDecl, source: int) -> bool:
    """DECL is a helper that may stay in its file: PRIVATE_TYPE_MAX source lines or fewer (its `extension` blocks
    in the file included, type_extent), and private (at any level) or nested in another type's or a function's
    body (not a member of an `extension`)."""
    return source <= PRIVATE_TYPE_MAX and (decl.private or (decl.nested and not decl.in_extension))


class TypeCandidate(NamedTuple):
    """A type app_type judges: DECL in FILE's head, its SOURCE lines, the added source LINES a move may explain,
    WHOLE when the base held it as a small helper (it is judged over all its lines, not only the added ones),
    EXTENDED when `extension` blocks in the file add to its lines, and OUTER, the judged type it is inside (its
    body, or an `extension` of it): such a type is judged on the outer's credit, which holds its lines already,
    so no removed line is drawn twice. OUTER is None for a type that draws from the pools itself."""
    file: AppFile
    decl: TypeDecl
    source: int
    lines: list[SourceLine]
    whole: bool
    extended: bool
    outer: str | None


def type_extent(decl: TypeDecl, extensions: list[ExtensionBlock]) -> list[range]:
    """DECL's lines in its file (0-based ranges): its own declaration and body, and every `extension` block of it or
    of a type inside it (`extension T`, `extension T.Inner`) in the same file. A small private type whose body is
    in extensions (`private struct V: View { var body: some View { content } }` and `extension V { ... }`) is as
    large as all of them."""
    return [range(decl.first, decl.end)] + [range(e.first, e.end) for e in extensions
                                            if e.name == decl.qual or e.name.startswith(decl.qual + ".")]


def type_candidates(file: AppFile, base: Scopes, head: Scopes) -> list[TypeCandidate]:
    """The types of FILE that must be moves, in head order (BASE and HEAD: type_decls of its two versions; a new
    file has an empty BASE, so each of its types is new).

    A type is new when its qualified name is not in the base and its declaration line is added; a new type that
    is a small helper (small_helper) or carries TYPE_ESCAPE passes, and the declaration line of a type renamed in
    place (a base type of the same kind and outer scope that the head no longer has) is the old declaration, not
    new code. A type the base held as a small helper that is one no more (it lost `private`, or grew past
    PRIVATE_TYPE_MAX) is judged whole: the base never judged it, so judging only the lines a push adds would let a
    helper grow into a major type over a few pushes. A type's size and lines are its type_extent: its `extension`
    blocks in this file count. A type inside a judged type is judged too, on the outer's credit (OUTER); a type
    inside a small helper that passed is part of that helper's PRIVATE_TYPE_MAX lines; a type inside an escaped
    type is judged on its own (the escape names one type, not all it holds).
    """
    def source(flags: list[bool], extent: list[range]) -> int:
        return sum(1 for r in extent for n in r if n < len(flags) and flags[n])

    def parent(decl: TypeDecl) -> str:
        return decl.qual.rpartition(".")[0]

    def inside(decl: TypeDecl, quals: list[str]) -> str | None:
        """The innermost of QUALS that DECL is inside (its body, or an extension of it)."""
        return max((q for q in quals if decl.qual.startswith(q + ".")), key=len, default=None)

    old_types: dict[str, TypeDecl] = {}
    for decl in base.types:
        old_types.setdefault(decl.qual, decl)
    head_names = {decl.qual for decl in head.types}
    gone = collections.Counter((d.kind, parent(d)) for d in base.types if d.qual not in head_names)
    added = {a.number: a for a in file.added}
    judged: list[str] = []
    helpers: list[str] = []  # small helpers that passed: what they hold is in their PRIVATE_TYPE_MAX lines
    out: list[TypeCandidate] = []
    for decl in head.types:
        outer = inside(decl, judged)
        helper = inside(decl, helpers)
        if helper is not None and (outer is None or len(helper) > len(outer)):
            continue
        extent = type_extent(decl, head.extensions)
        size = source(file.head_flags, extent)
        mine = sorted((added[n + 1] for r in extent for n in r if n + 1 in added), key=lambda line: line.number)
        small = small_helper(decl, size)
        exempt = small or escaped(file.head_lines, decl.decl, TYPE_ALLOW)
        old = old_types.get(decl.qual)
        if old is None:
            if decl.decl + 1 not in added:  # a scope around it was renamed: not a new declaration
                continue
            if exempt:
                if small:
                    helpers.append(decl.qual)
                continue
            if gone[(decl.kind, parent(decl))] > 0:
                gone[(decl.kind, parent(decl))] -= 1
                mine = [a for a in mine if a.number != decl.decl + 1]
            out.append(TypeCandidate(file, decl, size, mine, False, len(extent) > 1, outer))
            judged.append(decl.qual)
        elif not exempt and small_helper(old, source(file.base_flags, type_extent(old, base.extensions))):
            out.append(TypeCandidate(file, decl, size, mine, True, len(extent) > 1, outer))
            judged.append(decl.qual)
        elif small:
            helpers.append(decl.qual)
    return out


def may_add_type(file: AppFile) -> bool:
    """FILE's push can add a type app_type refuses: an added line declares a type (TYPE_DECL_ANYWHERE: after a block
    comment or a `;` too), or the base has a type that may be a small helper (HELPER_TYPE) a push can grow without
    touching its declaration (in its body or in an `extension` of it). A cheap test (a regex over the added lines
    and one over the base), so the full scan runs only on such files: a wide rename touches hundreds of files that
    add no type."""
    return (any(TYPE_DECL_ANYWHERE.search(a.text) for a in file.added)
            or HELPER_TYPE.search("\n".join(file.base_lines)) is not None)


def app_type(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """The types App files gain that are new code (NetHit per type, bucket `new:<path>:<type>`).

    Judged per type (type_candidates): a type passes when at least MOVE_SHARE of its source lines are moved in
    (credit_moves, the run rule of a new file) or are unchanged lines; a WHOLE candidate passes only when MOVE_SHARE
    of all its lines are moved in. Existing files' types and the types of each new file that new_file_pass passed
    as a move (a split, or a git mv that `git diff --no-renames` shows as a delete and an add, with edits) are
    judged: a type added to a moved file is new code as much as one appended to an existing file. A moved file's
    types are judged on the lines new_file_pass credited there. One pool per push serves every placement in a
    fixed order: the new files (new_file_pass) take first, then the types in path and head order, so one removed
    block is credited to one new file or type only. The pools are move_pools, the computation new_file_pass uses,
    with the drawing types' own lines left out of what puts lines back (KEEP), so that a type moved between two
    existing files, or a nested type lifted in place, still counts, while a generic line removed is always lost
    (other files re-add braces too) and a specific line the other side adds back is subtracted. A root file takes
    from the root's lines first, then the rest's: a type moved into the root is the root budget's to judge
    (app-size). A file whose braces type_scan cannot follow is left out with a warning (fail open, NetHit.warn).
    MOVED is not used.
    """
    app = app_files(changes)
    if not app:
        return []
    placed = new_file_pass(app)
    hits: list[Added] = []
    candidates: list[TypeCandidate] = []
    for file in app:
        # A rename adds no line; a new file that is not a move is app-size's refusal (the Host file holds no type).
        if file.is_deleted or (file.is_new and file.path not in placed.moves) or not may_add_type(file):
            continue
        versions = {"head": file.head_lines} if file.is_new else {"base": file.base_lines, "head": file.head_lines}
        scans = {side: type_scan(lines) for side, lines in versions.items()}
        problem = next((f"{side}: {scan.problem}" for side, scan in scans.items() if scan.problem), None)
        if problem is not None:
            hits.append(NetHit(file.path, 1, f"could not follow this file's braces ({problem}), so its new types "
                               "were not checked (fail open); tell the Performance Lead (PL-guardrails) with this "
                               "line", f"scan:{file.path}", 0, warn=True, additive=False))
            continue
        base = Scopes([], []) if file.is_new else type_decls(file.base_lines, scans["base"].rows)
        candidates += type_candidates(file, base, type_decls(file.head_lines, scans["head"].rows))
    if not candidates:
        return hits

    drawing = [c for c in candidates if c.outer is None and not c.file.is_new]
    keep = {side: collections.Counter(line.text.strip() for c in drawing if c.file.root == side for line in c.lines)
            for side in (True, False)}
    pools = move_pools(app, keep)
    lost = {side: pools[side] - placed.taken[side] for side in (True, False)}
    credited: dict[tuple[str, str], set[int]] = {}
    for c in candidates:
        decl = c.decl
        if c.file.is_new:
            got = placed.moves[c.file.path]
        elif c.outer is not None:
            got = credited[(c.file.path, c.outer)]
        else:
            got = {line.number for line in credit_moves(c.lines, [lost[True], lost[False]] if c.file.root
                                                        else [lost[False], lost[True]]).moved}
        credited[(c.file.path, decl.qual)] = got
        moved_lines = sum(1 for line in c.lines if line.number in got)
        fresh = (c.source if c.whole else len(c.lines)) - moved_lines
        if c.source - fresh >= MOVE_SHARE * c.source:
            continue
        lines = f"{c.source} source lines" + (" with its `extension` blocks in this file" if c.extended else "")
        if c.whole:
            own_file = "its own file" + (" (make it internal)" if decl.private else "") + (
                f" (as an `extension {decl.qual.rpartition('.')[0]}` member)" if decl.nested else "")
            text = (f"type {decl.qual} in an existing App file is no longer a small private or nested helper, "
                    f"{lines} ({fresh} not moved): put it in {destination(c.file.path)}, or move it to {own_file} "
                    "if it must stay in the App (one major type per file, nested types too, CLAUDE.md; only the "
                    f"lines it had before this push count as moved there). Reviewed escape: `{TYPE_ESCAPE}`")
        else:
            where = "a new App file that is a move" if c.file.is_new else "an existing App file"
            text = (f"new type {decl.qual} in {where}, {lines} ({fresh} not moved): put it in "
                    f"{destination(c.file.path)}; a new App file for new code is refused too (app-size); keep it "
                    f"a private helper of <= {PRIVATE_TYPE_MAX} source lines, or use the reviewed escape "
                    f"`{TYPE_ESCAPE}`")
        hits.append(NetHit(c.file.path, decl.first + 1, text, f"new:{c.file.path}:{decl.qual}", c.source,
                           additive=False))
    return hits


def app_files(changes: list[FileChange]) -> list[AppFile]:
    """The App Swift files of CHANGES, each lexed once per push (app_file's memo), in CHANGES' (path) order."""
    return [app_file(c) for c in changes if c.path.startswith(APP) and c.path.endswith(".swift")]


@dataclass
class NewFiles:
    """new_file_pass's result: its refusals, its renames (new file -> the deleted file it renames), the push's one
    Host file, TAKEN, the lines the renames and moves took from each side's pool (root: True), and MOVES, each new
    file it passed as a move (a split, a git mv with edits) -> the head line numbers credit_moves credited there
    (app_type judges each type of such a file on them)."""
    hits: list[Added]
    twins: dict[str, AppFile]
    host: AppFile | None
    taken: dict[bool, collections.Counter]
    moves: dict[str, set[int]] = field(default_factory=dict)


def move_pools(app: list[AppFile], keep: dict[bool, collections.Counter] | None = None
               ) -> dict[bool, collections.Counter]:
    """What a placement (a new file, a new type) may be credited from, per side (root: True): the lines no existing
    App file puts back (lost_lines; a block re-indented in its file and pasted into a new one is new code; a block
    moved into an existing file is not also in a new one). An existing file's re-added specific line is taken from
    its own side's removed lines first, then from the other side's, once (spill). The new files' own lines do not
    cancel their source; KEEP (per side) are the lines of the placements app_type judges, which do not cancel it
    either. The one pool computation of both rules (new_file_pass with no KEEP, app_type with its types' lines),
    so a generic line and a cross-side re-add are counted the same way for a new file and for a type."""
    keep = keep or {True: collections.Counter(), False: collections.Counter()}
    files = {side: [f for f in app if f.root == side] for side in (True, False)}
    existing = {side: [f for f in files[side] if not f.is_new] for side in (True, False)}

    def spill(side: bool) -> collections.Counter:
        """Specific lines SIDE's existing files add back that SIDE did not remove (its KEEP left out)."""
        added = collections.Counter(key for f in existing[side] for a in f.added
                                    if not is_generic(key := a.text.strip())) - keep[side]
        return added - collections.Counter(r.text.strip() for f in files[side] for r in f.removed)

    return {side: lost_lines(files[side], existing[side], keep[side]) - spill(not side) for side in (True, False)}


def new_file_pass(app: list[AppFile]) -> NewFiles:
    """Which new App files of the push (APP, app_files) are renames, moves, its one Host file, or refused new code."""
    hits: list[Added] = []
    pools = move_pools(app)
    root_pool, other_pool = pools[True], pools[False]
    start = {True: root_pool.copy(), False: other_pool.copy()}
    host: AppFile | None = None

    def keys(lines: list[SourceLine]) -> list[str]:
        return [line.text.strip() for line in lines]

    def is_import(key: str) -> bool:
        return IMPORT_LINE.match(key) is not None

    def still_lost(lines: list[SourceLine], pool: collections.Counter) -> bool:
        """Every specific line of LINES is still in POOL: no existing App file put it back, no new file took it."""
        return not collections.Counter(key for key in keys(lines) if not is_generic(key)) - pool

    new_files = [f for f in app if f.is_new]
    twins: dict[str, AppFile] = {}  # a new file that is a rename -> the deleted file it renames
    # A file the push deletes whole and adds back elsewhere, line for line, is a rename however short (no run of a
    # short file reaches MOVE_RUN), when its lines really left: the same lost-lines pool every move draws from, so
    # a deleted file pasted into an existing file is not also renamed. A new root file is split from the root: code
    # from elsewhere does not become wiring by moving, so its twin must be a root file too. Renames are found before
    # any credit_moves, so an exact copy is the rename and a near copy of the same file is not, whatever their names.
    for file in new_files:
        twin = next((d for d in app if d.is_deleted and d not in twins.values() and (d.root or not file.root)
                     and keys(d.removed) == keys(file.added)
                     and still_lost(d.removed, root_pool if d.root else other_pool)), None)
        if twin is not None:
            pool = root_pool if twin.root else other_pool
            for key in keys(file.added):  # what the rename took, no other new file takes
                pool[key] -= 1 if pool[key] > 0 else 0
            twins[file.path] = twin
    moves: dict[str, set[int]] = {}
    for file in new_files:
        if file.path in twins:
            continue
        # The moved share is of non-import source lines on both sides: imports count neither as moved nor as code.
        credited = credit_moves(file.added, [root_pool] if file.root else [other_pool, root_pool],
                                bridge=is_import).moved
        moved_lines = len(credited)
        code = sum(1 for a in file.added if not is_import(a.text.strip()))
        if moved_lines and moved_lines >= MOVE_SHARE * code:
            moves[file.path] = {line.number for line in credited}
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
                           f"moved), goes to {destination(file.path)}: {why}", f"new:{file.path}", lines,
                           additive=False))
    return NewFiles(hits, twins, host, {True: start[True] - root_pool, False: start[False] - other_pool}, moves)


def app_size(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """The App growth a push may not add or is warned about (NetHit per bucket); see the `app-size` rule's text.

    Per push, in source lines: the root adds at most ROOT_BUDGET lines besides the push's one Host conformance
    file, lines moved into it from feature files included; a new file is refused unless it is a move or that Host
    file (new_file_pass; a new type in an existing App file is app_type's rule). Growth of the
    App as a whole (exactly check-app-size.sh --base's count: a split file's new import lines are growth there
    and here) and of the App outside the root are NetHit.warn hits: warnings, not refusals. Lines moved between
    feature files (a git mv, a split) and out of the root into another App file are not growth (and the latter is
    no root shrink); code moved into the root (a Host file too) counts against the root's budget and gives the
    rest no shrink credit. Code moved into the App from a package is new App code (the rule moves code out of
    the App, never in): it makes no new file or type a move and is App growth. MOVED is not used.
    """
    app = app_files(changes)
    if not app:
        return []
    placed = new_file_pass(app)
    hits, twins, host = list(placed.hits), placed.twins, placed.host
    root_files = [f for f in app if f.root]
    other_files = [f for f in app if not f.root]

    def removed(files: list[AppFile]) -> collections.Counter:
        return collections.Counter(r.text.strip() for f in files for r in f.removed)

    # The Host file is a root file here: what it takes from feature files is moved into the root, not a shrink.
    # A move across the root's edge is found on each file's whole added list, from the lines the other side
    # really lost: a line the file's own side explains (a removed stub's `}`) never cuts a moved block apart, so
    # every line moved out of the root is counted and none becomes free root budget.
    # The renames new_file_pass found are the one rename decision: a rename moves its whole file, so neither of its two
    # files is credited again or lends lines to another move, and a root file renamed into a feature folder (the
    # only rename across the edge: a new root file's twin is a root file) counts all its lines as moved out.
    paired = set(twins) | {twin.path for twin in twins.values()}
    moving_root = [f for f in root_files if f.path not in paired]
    moving_other = [f for f in other_files if f.path not in paired]
    root_lost, other_lost = lost_lines(moving_root, moving_root), lost_lines(moving_other, moving_other)
    root_own, other_own = removed(moving_root), removed(moving_other)
    credit = {f.path: credit_moves(f.added, [other_lost], root_own) for f in moving_root}
    credit.update({f.path: credit_moves(f.added, [root_lost], other_own) for f in moving_other})
    into_root = sum(len(credit[f.path].moved) for f in moving_root)
    out_of_root = sum(len(credit[f.path].moved) for f in moving_other) + sum(
        len(f.added) for f in other_files if f.path in twins and twins[f.path].root)
    # What the summary calls a file's new lines, from the credit's own accounting: the lines its own side does not
    # explain, less (for a feature file) the lines moved out of the root. A root file's moved-in lines are root
    # growth (wiring budget), so they stay in, in head order. A rename has no new lines.
    new_lines = {f.path: [] if f.path in paired else (
        sorted(credit[f.path].moved + credit[f.path].rest, key=lambda line: line.ordinal) if f.root
        else credit[f.path].rest) for f in app}
    fresh = {path: len(lines) for path, lines in new_lines.items()}

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

    # Code moved into the root counts against its wiring budget (a move does not make feature logic wiring). Code
    # moved out of it into another App file is neutral: no root shrink (so it makes no room for new wiring) and no
    # root or feature growth (a pure split of a god file passes, CLAUDE.md "File organization"). A move out of the
    # root into a package is a real root shrink. The push's one Host file (one-line forwards only, host_problem)
    # is outside the budget; what it takes from feature files still gives them no credit.
    root_net = net(root_files) + out_of_root
    other_net = net(other_files) + into_root - out_of_root
    wiring = root_net - (len(host.added) if host else 0)
    total = net(app)
    # Every root change is measured (a hit with excess <= 0 is not a finding; check() drops it): a merge's own
    # root growth is its amount less what the branch's last push already had (check_own).
    if root_files and wiring:
        path, number, shown = top([f for f in root_files if f is not host] or root_files)
        besides = f" besides {app_rel(host.path)}'s {len(host.added)}" if host else ""
        out = (f"; {out_of_root} lines moved from the root into other App files give no root shrink: a move into "
               "a package does" if out_of_root else "")
        hits.append(NetHit(path, number, f"the composition root grows {wiring:+d} source lines{besides}, over its "
                           f"wiring budget of +{ROOT_BUDGET} per push ({shown}{out})", "root", wiring - ROOT_BUDGET,
                           limit=ROOT_BUDGET))
    # Growth warnings, not refusals, until the large domains are out of the App (see the values' comment above).
    if other_files and other_net:
        path, number, shown = top(other_files)
        hits.append(NetHit(path, number, f"App outside the root grows {other_net:+d} source lines "
                           f"({net_bytes(other_files):+d} bytes); move the code to {destination(path)} ({shown})",
                           "other", other_net, warn=True))
    if total:
        path, number, shown = top(app)
        hits.append(NetHit(path, number, f"CmuxNextApp grows {total:+d} source lines ({net_bytes(app):+d} bytes, as "
                           f"check-app-size.sh --base counts lines): pay for it by moving as many App lines to "
                           f"{destination(path)} ({shown})", "total", total, warn=True))
    return hits


# The generic main-actor class deinit crash (swift_scope.py has the evidence): swift-frontend 6.3.3 crashes in -O
# on the isolated deinit of a main-actor class generic by itself or by context. swift_scope.judge is the one
# detector check-concurrency.sh's CI crash-class rule uses too; this rule applies it to what a push adds in Sources
# and Tests, and only a `nonisolated deinit` is the fix.
CLASS_DECL = swift_scope.CLASS_DECL
GENERIC_CLASS_ALLOW = swift_scope.GENERIC_CLASS_ALLOW
GENERIC_TYPE = swift_scope.GENERIC_TYPE
PACKAGE_ROOT = "Packages/macOS/CmuxNext/"
MANIFEST = PACKAGE_ROOT + "Package.swift"


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


def main_by_default(path: str, targets: list) -> bool:
    """Whether PATH's target is main actor by default, from TARGETS (swift_scope.package_targets of the
    revision's Package.swift: the target whose folder holds PATH). A file in no target's folder (or no
    manifest) counts as main actor."""
    if not path.startswith(PACKAGE_ROOT):
        return True
    main = swift_scope.default_isolation(path[len(PACKAGE_ROOT):], targets)
    return True if main is None else main


@dataclass
class Attributed(Added):
    """A hit in a file the push did not change: CAUSE names the push's change that makes it debt there."""
    cause: str = ""


def generic_signature_context(repo: Path, head: str, changes: dict[str, FileChange],
                              head_types: GenericTypes, base_types: GenericTypes) -> tuple[list[FileChange], dict[str, str]]:
    """(unchanged files the generic-class rule must judge, {path: cause}) for the push's generic-signature changes.

    A push that adds or removes a type's generic parameters (`struct Ledger {` -> `struct Ledger<Entry> {`) makes
    or unmakes every class in an extension of that type generic by context, also in files the push does not
    change. Each `extension` line of such a type is marked touched on both sides (Version.touched): in the
    push's own files, and in every Sources and Tests file at HEAD that extends the type, which is added here
    unchanged (its base text is its head text). The rule then judges those classes against the base, so the
    push owns the candidates it makes and a class that was already debt pairs with itself. A type whose
    parameters only change (`Ledger<Entry>` -> `Ledger<Entry, Key>`) stays generic and marks nothing.
    """
    flipped: dict[str, str] = {}  # type name -> "path:line" of the declaration whose generic signature changed
    for path, change in sorted(changes.items()):
        if not path.endswith(".swift"):
            continue
        head_decls = swift_scope.generic_declarations("\n".join(change.head_lines))
        base_decls = swift_scope.generic_declarations("\n".join(change.base_lines))
        for name in sorted(set(head_decls) ^ set(base_decls)):
            if (name in head_types) != (name in base_types):
                flipped.setdefault(name, f"{path}:{(head_decls.get(name) or base_decls[name])[0]}")
    if not flipped:
        return [], {}
    names = frozenset(flipped)

    def anchors(lines: list[str]) -> dict[int, set[str]]:
        found = {}
        for number, line in enumerate(lines, 1):
            if "extension" in line and (extended := swift_scope.extended_names(line, names)):
                found[number] = extended
        return found

    for path, change in changes.items():
        if path.endswith(".swift"):
            change.head_anchors.update(anchors(change.head_lines))
            change.base_anchors.update(anchors(change.base_lines))
    pattern = (r"extension[[:space:]]+([A-Za-z_][A-Za-z0-9_]*\.)*(" + "|".join(sorted(names))
               + r")([^A-Za-z0-9_]|$)")
    listed = git(repo, "grep", "-l", "-E", pattern, head, "--", SWIFT_SOURCES, SWIFT_TESTS, check=False)
    others = sorted({line.split(":", 1)[1] for line in listed.splitlines() if ":" in line} - set(changes))
    texts = blobs(repo, [(head, p) for p in others])
    added, causes = [], {}
    for path in others:
        if (head, path) not in texts:
            continue
        lines = texts[(head, path)].split("\n")
        marks = anchors(lines)
        if not marks:
            continue
        added.append(FileChange(path, lines, base_lines=lines, head_anchors=set(marks), base_anchors=set(marks)))
        extended = sorted(set().union(*marks.values()))
        causes[path] = "generic by context: it extends " + ", ".join(
            f"`{name}`, whose generic signature this push changes at {flipped[name]}" for name in extended)
    return added, causes


def implicit_deinit(version: Version, index: int) -> tuple[bool, list[int]]:
    """swift_scope.judge for a class declared here. Its context is the generic declarations around it and every
    line of its own body, so a push that only edits or deletes its deinit (or any member) judges it."""
    memo = version.memo
    if "main" not in memo:
        memo["main"] = swift_scope.main_lines(version.lines, version.main_default)
        memo["generic"] = swift_scope.generic_names("\n".join(version.lines))
    local, types = memo["generic"], version.types

    def is_generic(name: str) -> bool:
        return name in local or (types is not None and name in types)

    judged = swift_scope.judge(version.lines, index, is_generic, memo["main"], version.main_default)
    if judged is None:
        return False, []
    first, last = judged.span
    return True, judged.context + list(range(first, last + 1))


row_store = matcher_rule(Matcher(ROW_STORE, ROW_ALLOW, in_row))


def ratchet_code(line: str) -> str:
    """LINE as crash_ratchet.py reads it: a comment line is no code, else swift_code()."""
    return "" if line.lstrip().startswith("//") else ratchet.swift_code(line)


# crash_ratchet.py's `unchecked` class, judged per added line. The ratchet itself counts per module against
# its full-tree baseline, which the pre-push trees (only the changed files) never reach, so before a push only
# this rule sees a new one. A class the ratchet bans (per file, crash-allowlist.json) it refuses itself.
UNCHECKED = Matcher(ratchet.SWIFT["unchecked"], ratchet.ALLOW, code=ratchet_code, window=ratchet.allow_lines)


def unchecked_sendable(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    banned_everywhere = "unchecked" in ratchet.banned_kinds("swift")
    banned_modules = {module for kind, module in ratchet.banned_in("swift") if kind == "unchecked"}
    judged = [c for c in changes if not banned_everywhere and module_of(c.path) not in banned_modules]
    return matcher_rule(UNCHECKED)(judged, moved)


def module_of(path: str) -> str:
    """The Swift module of a path under Sources/ (its first folder there)."""
    return path[len(SOURCES):].split("/", 1)[0] if path.startswith(SOURCES) else ""


# ---- task-priority (PL-qos)
# Every off-main task and queue states its priority on purpose (Lawrence's threading items 3 and 5,
# plans/cmux-next/PATTERNS.md P14): a detached Task names `priority:`, a global queue its `qos:`, a new serial
# queue its `qos:` or its `target:`. A plain `Task { }` is not counted: it inherits its caller's priority and actor,
# which is right in almost every case (lead, 2026-10-24). The argument list is read to its closing parenthesis, so a
# call split over lines counts by what it names.
TASK_CALL = re.compile(r"\bTask\.detached\s*[({]|\bDispatchQueue\.global\(|\bDispatchQueue\(\s*label:")
STATED = re.compile(r"\b(priority|qos|target):")
RESERVED_LEVEL = re.compile(r"\b(priority|qos):\s*(\.|\w+\.)?(userInteractive|unspecified|background)\b")
QOS_ALLOW = "qos-allow:"
TASK_ARGS_MAX_LINES = 8  # an argument list longer than this is not a queue or task init in this codebase


def unstated_priority(version: Version, index: int) -> tuple[bool, list[int]]:
    """Whether the detached Task or queue call on line INDEX names no priority, QoS or target, or names a level the
    model keeps for other work: `.userInteractive` (the main thread and the threads a frame waits for only),
    `.unspecified` (unstated in effect) or `.background` (work nothing ever waits for: say so in the escape)."""
    code = code_of(version.lines[index])
    match = TASK_CALL.search(code)
    if match is None:
        return False, []
    rest = code[min(i for i in (code.find("(", match.start()), code.find("{", match.start())) if i >= 0):]
    if rest.startswith("{"):
        return True, []
    args, depth = "", 0
    lines = [rest] + [code_of(line) for line in version.lines[index + 1:index + TASK_ARGS_MAX_LINES]]
    for line in lines:
        for i, c in enumerate(line):
            depth += c == "("
            depth -= c == ")"
            if depth == 0:
                args += line[:i + 1]
                return not STATED.search(args) or bool(RESERVED_LEVEL.search(args)), []
        args += line + "\n"
    return not STATED.search(args) or bool(RESERVED_LEVEL.search(args)), []


RULES = (
    Rule("unchecked-sendable", "`@unchecked Sendable` / `nonisolated(unsafe)` without a safety argument",
         "it switches off the data-race checker; without a written argument nobody can review it",
         "an actor, a Sendable value type, or CmuxNextCompat `Mutex` around the state; when it is truly safe, "
         "say why on the declaration line or the line directly above: `// crash-allow: <the safety argument>` "
         "(crash_ratchet.py's class and escape: CI's ratchet reads the same two lines; it counts the line as a "
         "waived hit: record it with crash_ratchet.py --record-waivers)",
         "// crash-allow: <the safety argument>",
         unchecked_sendable),
    Rule("main-async", "`DispatchQueue.main.async`",
         "an untyped hop that reorders work and hides isolation (CLAUDE.md forbids it in new code)",
         "annotate the destination `@MainActor` and `await` it, or hop once with `Task { @MainActor in ... }` "
         "owned by the caller",
         "// main-async-allow: <the API that forces a GCD hop>",
         line_rule(r"\bDispatchQueue\.main\.async\b|\bOperationQueue\.main\.addOperation\b", "main-async-allow:")),
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
         "A main-actor class generic by itself or by context (nested in a generic type, extension or function) "
         "with no `nonisolated deinit` (an implicit, plain or `isolated` deinit is isolated there)",
         "swift-frontend 6.3.3 (Xcode 26.6) crashes with signal 11 in -O on the isolated deinit of a generic "
         "main-actor class (EarlyPerfInliner, isCallerAndCalleeLayoutConstraintsCompatible): the Release test build "
         "and every Release bench stop (2026-10-23: PageTestWait.Once, CloudPaneTests.Seen, ObservedMap.Slot)",
         "give it `nonisolated deinit {}` (or a nonisolated deinit that does its cleanup; not a plain or "
         "`isolated deinit`), declare the class `nonisolated`, or move it out of the generic context; "
         "check-concurrency.sh's CI crash-class rule refuses the same classes in Sources",
         "// generic-class-allow: <why this class is not main-actor isolated> (`concurrency-allow:` also works)",
         matcher_rule(Matcher(CLASS_DECL, GENERIC_CLASS_ALLOW, implicit_deinit)),
         scope=(SOURCES, TESTS)),
    Rule("action-wait", "An action handler that can wait: an untyped bind (`invoke:` / `run:` / `handler:` / a trailing closure) "
         "or a `.waiting` effect",
         "an untyped handler can start a Task that awaits the daemon before anything shows, and nothing in its type says so: the "
         "action misses its 10 ms budget and the regression is invisible (plans/cmux-next/zero-latency.md, the budget contract)",
         "bind with `effect:` and return what the input's turn changed: `.done`, or `daemon.intentEffect(label, intent) { ... }` "
         "(a store intent shows now; the registry sends, rolls back and reports), or `.applied(ActionConfirmation(...))` with a "
         "rollback; `.waiting(reason, work)` only when no local stand-in can exist (network, another process)",
         "// action-wait-allow: <why nothing can show before the reply>",
         line_rule(r"\.bind\([^\n]*\b(invoke|run|handler):|\.bind\([^\n]*\)\s*\{\s*(\w+|_)?\s*(,\s*\w+)*\s*in\b"
                   r"|\.waiting\(\.|\bwaitingEffect\(", "action-wait-allow:")),
    Rule("bench-hooks-shipped", "The bench configuration in a shipped build's settings",
         "CMUX_BENCH_HOOKS (reload.sh --config bench) keeps the debug.* control commands in an optimized app for "
         "the fleet benches; in a release, nightly or RC build's settings it would ship them to users",
         "build benches with `scripts/reload.sh --config bench` or a measure script's `--config=bench` only; "
         "shipped pipelines run scripts/cmux-next/check-no-bench-hooks.sh on their app",
         None,
         line_rule(r"CMUX_BENCH_HOOKS|--config[= ]bench\b", None),
         scope=SHIPPED_BUILD + (".xcconfig", "project.pbxproj")),
    Rule("task-priority", "A detached Task or dispatch queue without a stated priority, or at a reserved level",
         "a task or queue that does not say how much a person waits for it runs at whatever QoS it inherits: work "
         "nobody waits for competes with typing and frames, and the main thread can wait on work that runs below it "
         "(priority inversion; plans/cmux-next/PATTERNS.md P14). .userInteractive is for the main thread and the "
         "threads a frame waits for; .unspecified states nothing; .background may wait without limit",
         "say it: `Task.detached(priority: WorkPriority.bestEffort.taskPriority) { ... }` (or `.high`/`.medium`/`.utility`), "
         "`DispatchQueue.global(qos: .utility)`, `DispatchQueue(label: ..., qos: .utility)`; blocking work (file I/O, a "
         "process wait, a sync C call, a long parse) goes to `BackgroundWork.run(_:mayBlock:)` or `AsyncProcess`, never "
         "into a Task on the cooperative pool",
         "// qos-allow: <why: a frame waits for it (userInteractive), it inherits on purpose, or nothing ever waits for it (background)>",
         matcher_rule(Matcher(TASK_CALL, re.compile(r"//\s*" + re.escape(QOS_ALLOW) + r"\s*\S"), unstated_priority))),
    Rule("appkit-index", "A raw AppKit row or column index read (`.clickedRow`, `.clickedColumn`, `.selectedColumn`, "
         "`item(atRow:`, `selectedRow(inColumn:`)",
         "they are -1 when a click lands off the rows or nothing is selected, and past the end after a reload; "
         "AppKit raises NSRangeException for such an index and the app ends (#24776, NSBrowser itemAtRow:inColumn:)",
         "CmuxNextCompat's checked accessors: `table.clickedRowIfValid` / `selectedRowIfValid`, "
         "`browser.clickedItemIfValid` / `selectedItemIfValid` / `item(ifValidRow:inColumn:)`; still check the row "
         "against the model array you index",
         "// index-allow: <why the index is valid here>",
         line_rule(r"\.(clickedRow|clickedColumn|selectedColumn)\b|\bitem\(atRow:|\bselectedRow\(inColumn:",
                   "index-allow:")),
    Rule("undo-text-write", "Undo turned on for a text view (`allowsUndo = true`)",
         "AppKit's `string` setter replaces the text without telling the undo manager: a typing action keeps its "
         "range into the old text and Cmd-Z raises NSRangeException (#24912)",
         "write text from code only through CmuxNextDesign's `replaceAllTextUndoably(_:)` (one undo step; "
         "TextBoxTextView.replaceText, ShareCmuxMessageTextView.replaceText), then mark the line "
         "`// undo-safe: <the view's replaceText>`",
         "// undo-safe: <the view's replaceText>",
         line_rule(r"\ballowsUndo\s*=\s*true\b", "undo-safe:")),
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
         "out of the root into another App file are not growth (and no root shrink), moves into the root count "
         "against its budget; blank and comment lines never count",
         None,
         app_size,
         scope=(APP,),
         net=True),
    # Known gap (growth stays a warning, see the app-size values' comment; the perf cron arch report is the
    # backstop): code first added as plain members (of an `extension` of an old type, or of an old type's body)
    # gets only the growth warning, and a later push that wraps those members in place in a new `struct T { }` is
    # credited as a move in place. Likewise an `extension` of a small nested helper in ANOTHER file adds to it
    # unseen: a type's size counts only its own file's `extension` blocks.
    Rule("app-type", "A new type in a CmuxNextApp file that is not a move (top-level, a member of an "
         f"`extension`, or nested in a type or function with more than {PRIVATE_TYPE_MAX} source lines, its "
         "`extension` blocks in the file counted), in an existing file or in a new file that passes as a move",
         "the new-file rule's dodge: a type appended to an existing App file, or to a file the push moves or "
         "splits, grows a god file and the App instead of a package (CLAUDE.md: one major type per file, nested "
         "types included)",
         f"put the type in its domain package ({DESIGN}): a new App file for new code is refused too (app-size); "
         f"a private or fileprivate helper, or a type nested in another type's body, of <= {PRIVATE_TYPE_MAX} "
         "source lines (with its `extension` blocks in the file) may stay, and a helper that grows past that or "
         "loses `private` is judged whole; a type moved in from another App file (or lifted out of its outer "
         "type) passes; an escape on a type covers that type only, not the types inside it",
         TYPE_ESCAPE,
         app_type,
         scope=(APP,),
         net=True),
)


# ---------------------------------------------------------------- main-blocking / thread-doc (PL-blocking)
# plans/cmux-next/threading-model.md: the main thread never blocks (Chrome's ScopedBlockingCall). The runtime
# detector (CmuxNextCompat/Threading) is the real guard; these rules are the early warning on what a push adds.
# They judge only the lines the push changed (no whole-file context scan), so the gate stays fast.
# The block owns its lines from here to `RULES += BLOCKING_RULES`; other rules go above it.
THREADING_DOC = "plans/cmux-next/threading-model.md"
THREADING_DOC_SECTION = "## Registered threads and queues"
PACKAGE_MANIFEST = "Packages/macOS/CmuxNext/Package.swift"
# The seams themselves (and Mutex, which reports contended waits) wrap the raw primitives on purpose.
BLOCKING_SEAMS = (SOURCES + "CmuxNextCompat/Threading/", SOURCES + "CmuxNextCompat/Mutex.swift")
BLOCKING_ALLOW = re.compile(r"//\s*blocking-allow:\s*\S")
FILE_OPS = (r"fileExists|isReadableFile|isWritableFile|isExecutableFile|createDirectory|removeItem|contentsOfDirectory|"
            r"subpathsOfDirectory|enumerator|createFile|contents|contentsEqual|attributesOfItem|attributesOfFileSystem|"
            r"setAttributes|moveItem|copyItem|linkItem|replaceItemAt|destinationOfSymbolicLink|createSymbolicLink|"
            r"trashItem|url")
# Raw blocking primitives: each has a checked seam in CmuxNextCompat/Threading. A `.wait(` preceded by `await`
# in its statement is an async wait (Backoff.wait, a continuation), never a blocking one: see blocking_match.
RAW_BLOCKING = re.compile(
    r"\bData\(contentsOf:|\bString\(contentsOf(File)?:|\bNS(Data|String|Dictionary|Array|Image)\(contentsOf(File|URL)?:"
    r"|\bFileManager\.default\.(" + FILE_OPS + r")\("
    r"|\.write\(to:|\.waitUntilExit\(\)|\.readDataToEndOfFile\(\)|\.readToEnd\(\)|\.availableData\b|\.readData\(ofLength:"
    r"|\.resourceValues\(forKeys:|\bxpc_connection_send_message_with_reply_sync\(|\bposix_spawnp?\(|(?<![\w.])fork\(\)"
    r"|(?P<wait>(?<=[\w)\]])\.wait\((timeout:|wallTimeout:|until:)?[^)]*\))"
    r"|\.sync\s*(\{|\(execute:)")
# The checked seams: fine off the main thread, a violation on it.
SEAM_BLOCKING = re.compile(
    r"\bFileManager\.checked\.|\bblockingContentsOf(File)?:|\.blockingResourceValues\(|\.blocking(ReadToEnd|Read|Write|"
    r"AvailableData|ReadDataToEndOfFile|Wait|WaitUntilExit|Sync|Run)\b|\bblocking(Read|Recv|Write|Send|XPCSendWithReply|"
    r"PosixSpawn)\(")
# Never on any thread of the app: a main-queue sync hop deadlocks from main and stalls it from elsewhere; a
# sleep holds a thread to wait for time.
ALWAYS_BLOCKING = re.compile(r"DispatchQueue\.main\.sync\b|\bThread\.sleep\b|(?<![\w.])(usleep|nanosleep)\(")
# A new thread or queue. `extension Thread {` and a type annotation are not one.
# `Thread {` counts only where a value starts (after `=`, `(`, `,`, `return`, or as a statement), so a superclass,
# a return type or a type annotation (`class W: Thread {`, `-> Thread {`, `var t: Thread {`) is not one.
THREAD_CREATE = re.compile(r"\bDispatchQueue\(\s*label:|(?:^\s*|[=(,]\s*|\breturn\s+)Thread\s*(\{|\(block:|\(target:)"
                           r"|\bThread\.detachNewThread\b|\bOperationQueue\(\)|\bpthread_create\(|\bDispatchSerialQueue\("
                           r"|\bDispatchWorkloop\(")
THREAD_NAME = re.compile(r'(\.name\s*=|label:)\s*(?P<literal>"((?:\\.|[^"\\])*)")?')
ALLOWANCE_DECL = re.compile(r"\bstatic\s+let\s+(\w+)\s*=\s*BlockingAllowance\(")
THREAD_BINDING = re.compile(r"\b(?:let|var)\s+(\w+)\s*(?::\s*\w+\s*)?=\s*(?:Thread\b|OperationQueue\(\))")
THREAD_NAME_WINDOW = 80  # lines after `let thread = Thread {` that its `thread.name = "..."` may follow
AWAIT = re.compile(r"\bawait\b")
STATEMENT_START = re.compile(r"[;{}]")
# How a block's header (its opener line, joined with the lines of a header split over several lines) decides
# where the block's body runs. MAIN: openers that run their body on the main thread. DECLARATION: a function,
# initializer, subscript or accessor body (the body runs where its declaration's isolation says), or a type
# body. CONTROL: control flow, which runs inline. Any other `{` is a closure: it may run later or on another
# thread, so main-blocking does not judge its body (the runtime detector does).
MAIN_OPENER = re.compile(r"\bDispatchQueue\.main\.(async|sync)\s*(\(execute:)?\s*\{|\bMainActor\.run\s*(\([^{]*\))?\s*\{"
                         r"|\bTask\s*(\([^{]*\))?\s*\{\s*@MainActor\b")
DECLARATION_OPENER = re.compile(r"^\s*(@[\w.]+(\([^)]*\))?\s+|(public|package|internal|private|fileprivate|open|final|"
                                r"static|class|override|mutating|nonmutating|nonisolated|isolated|convenience|required|"
                                r"lazy|dynamic|indirect|distributed)\s+)*"
                                r"(func|init[?!]?|deinit|subscript|get|set|willSet|didSet|_read|_modify|class|struct|enum|"
                                r"actor|extension|protocol)\b"
                                r"|^\s*(@[\w.]+(\([^)]*\))?\s+|(public|package|internal|private|fileprivate|open|"
                                r"static|class|override|nonisolated|lazy)\s+)*var\s+\w+\s*:[^=]*\{\s*$")
CONTROL_OPENER = re.compile(r"^\s*(\}\s*)?(if|else|guard|for|while|repeat|switch|case|default|do|catch|defer)\b|^\s*\{\s*$")
# A line that ends a statement (the header of the next block starts after it).
STATEMENT_END = re.compile(r"[{};]\s*$|^\s*$|^\s*(//|\*|/\*|@\w)")
HEADER_LINES = 12  # the most lines one block header (a long function signature or condition) is read across
# HEAD's threading doc and package manifest, and loaded helpers; check() refreshes the doc and manifest per run.
BLOCKING_CONTEXT: dict[str, object] = {}


class Prefiltered:
    """PATTERN behind one literal-keyword search: most lines hold none of KEYS, and that search costs a tenth of
    the full alternation."""

    def __init__(self, pattern: re.Pattern, keys: tuple[str, ...]) -> None:
        self.pattern = pattern
        self.keys = re.compile("|".join(re.escape(key) for key in keys))
        # blocking_match's answer per code text: three rules ask about the same changed lines.
        self.answers: dict[str, bool] = {}

    def search(self, text: str):
        return self.pattern.search(text) if self.keys.search(text) else None


BLOCKING_KEYS = ("contentsOf", "FileManager", ".wait(", "waitUntilExit", ".sync", "readToEnd", "availableData", "readData",
                 "esourceValues", "xpc_", "blocking", "write(to:", "posix_spawn", "fork(")
RAW_SCAN = Prefiltered(RAW_BLOCKING, BLOCKING_KEYS)
MAIN_SCAN = Prefiltered(re.compile(RAW_BLOCKING.pattern + "|" + SEAM_BLOCKING.pattern), BLOCKING_KEYS)
ALWAYS_SCAN = Prefiltered(ALWAYS_BLOCKING, ("main.sync", "sleep"))
THREAD_SCAN = Prefiltered(re.compile(THREAD_CREATE.pattern + "|" + ALLOWANCE_DECL.pattern),
                          ("Thread", "Queue", "pthread_", "Workloop", "BlockingAllowance"))


def blocking_match(scan: Prefiltered, code: str) -> bool:
    """Whether CODE holds a blocking call SCAN names. A `.wait(` whose statement has an `await` before it is an
    async wait (`try await backoff.wait(owner:)`), not a blocking one."""
    answer = scan.answers.get(code)
    if answer is None:
        answer = scan.answers[code] = _blocking_match(scan, code)
    return answer


def _blocking_match(scan: Prefiltered, code: str) -> bool:
    match = scan.search(code)
    while match is not None:
        if match.groupdict().get("wait") is None:
            return True
        before = code[:match.start()]
        statement = before[max((m.end() for m in STATEMENT_START.finditer(before)), default=0):]
        if not AWAIT.search(statement):
            return True
        match = scan.pattern.search(code, match.end())
    return False


def main_actor_scope():
    """check-main-actor-work.py next to this file (the hook copies it): its lexical main-actor scopes."""
    if "scope" not in BLOCKING_CONTEXT:
        spec = importlib.util.spec_from_file_location("cmux_next_main_actor_scope", HERE / "check-main-actor-work.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        BLOCKING_CONTEXT["scope"] = module
    return BLOCKING_CONTEXT["scope"]


def ui_targets() -> set[str]:
    """The targets HEAD's manifest builds with `uiSwiftSettings` (main-actor by default), as check-concurrency.sh
    reads them."""
    if "ui_targets" not in BLOCKING_CONTEXT:
        manifest = BLOCKING_CONTEXT.get("manifest")
        found = re.findall(r'\.(?:target|executableTarget)\(\s*name:\s*"([^"]+)".*?swiftSettings:\s*(\w+)',
                           manifest if isinstance(manifest, str) else "", re.S)
        BLOCKING_CONTEXT["ui_targets"] = {name for name, settings in found if settings == "uiSwiftSettings"}
    return BLOCKING_CONTEXT["ui_targets"]


def block_header(lines: list[str], number: int, code: str) -> str:
    """The whole header of the block that opens on 1-based line NUMBER (whose code up to its `{` is CODE): the
    lines back to the previous statement's end, joined, so `func f(\n a: A\n) async throws {` and
    `if a,\n b {` read as one header."""
    parts = [code]
    j = number - 2
    while j >= 0 and number - 1 - j <= HEADER_LINES:
        text = code_of(lines[j])
        if STATEMENT_END.search(text):
            break
        parts.insert(0, text)
        j -= 1
    return " ".join(part.strip() for part in parts)


def runs_on_main(version: Version, index: int) -> bool:
    """Whether VERSION's line INDEX runs on the main thread for sure: inside an opener that runs on main
    (`DispatchQueue.main.async {`, `MainActor.run {`, `Task { @MainActor in`), or main-actor code (a
    uiSwiftSettings target's default or `@MainActor`, minus nonisolated / @concurrent / actor / Task.detached
    scopes, as check-main-actor-work.py reads them) directly in a function body. Inside any other closure it is
    not judged: such a body may run later or elsewhere."""
    answers = version.memo.setdefault("runs_on_main", {})
    if index not in answers:
        answers[index] = _runs_on_main(version, index)
    return answers[index]


def _runs_on_main(version: Version, index: int) -> bool:
    if "main_lines" not in version.memo:
        module = version.path[len(SOURCES):].split("/", 1)[0] if version.path.startswith(SOURCES) else ""
        version.memo["main_lines"] = main_actor_scope().main_actor_lines(version.lines, module in ui_targets())
    main_lines = version.memo["main_lines"]
    declared_main = index < len(main_lines) and main_lines[index]
    code = code_of(version.lines[index])
    match = MAIN_SCAN.search(code)
    prefix = code[:match.start()] if match else ""
    for opener, number in enclosing_openers(version.lines, index, OPENER_STOP, prefix):
        header = block_header(version.lines, number, opener) if number - 1 != index else opener
        # The whole opener line: `Task { @MainActor in` names its isolation after the `{`.
        if MAIN_OPENER.search(opener) or MAIN_OPENER.search(code_of(version.lines[number - 1])):
            return True
        if DECLARATION_OPENER.search(header):
            return declared_main
        if CONTROL_OPENER.search(header):
            continue
        return False  # inside a closure
    return declared_main


# Where the walk out of the blocks stops: an opener line that names a declaration (a function or type body).
# A function whose signature spans lines opens on a `) {` line, so the walk passes it and stops at its type.
OPENER_STOP = re.compile(r"\b(func|init|deinit|subscript|class|struct|enum|actor|extension|protocol)\b")


ASYNC_DECLARATION = re.compile(r"\bfunc\b[^{]*\)\s*(async|async\s+throws|async\s+throws\([^)]*\)|async\s+rethrows)\b")
CALLER_ISOLATION_OPT_OUT = re.compile(r"@concurrent\b|\bnonisolated\b(?!\s*\(unsafe\))|@MainActor\b|\bactor\b")
ACTOR_DECLARATION = re.compile(r"(^|\s)(distributed\s+)?actor\s+\w+")


def may_run_on_main(version: Version, index: int) -> bool:
    """Whether VERSION's line INDEX sits directly in a non-`@concurrent` async function of a target that is not
    main-actor by default, outside an actor. Under NonisolatedNonsendingByDefault such a function runs on its
    caller's executor, so a main-actor caller runs it on main (AsyncProcess.run's spawn stalled screen.close
    807 ms, 2026-10-24). PL-qos proposal; a warning, never a refusal (30 such sites on the tip, 2026-10-24)."""
    module = version.path[len(SOURCES):].split("/", 1)[0] if version.path.startswith(SOURCES) else ""
    if module in ui_targets():
        return False
    code = code_of(version.lines[index])
    match = MAIN_SCAN.search(code)
    prefix = code[:match.start()] if match else ""
    openers = enclosing_openers(version.lines, index, OPENER_STOP, prefix)
    for position, (opener, number) in enumerate(openers):
        header = block_header(version.lines, number, opener) if number - 1 != index else opener
        if DECLARATION_OPENER.search(header):
            if not ASYNC_DECLARATION.search(header) or CALLER_ISOLATION_OPT_OUT.search(header):
                return False
            outer = enclosing_openers(version.lines, number - 1, ACTOR_DECLARATION)
            return not any(ACTOR_DECLARATION.search(o) for o, _ in outer)
        if not CONTROL_OPENER.search(header):
            return False  # a closure: may run anywhere
    return False


@dataclass
class WarnHit(Added):
    """A hit that check() reports as a warning, never a refusal."""
    warn: bool = True


def changed_debt(changes: list[FileChange], judge: Callable[[Version, int, str], bool]) -> list[Added]:
    """New debt among the lines the push changed, as matcher_rule counts it (a per-file count ratchet with moves),
    without matcher_rule's scan of unchanged lines: JUDGE(version, 0-based line, code) decides a changed line."""
    def debt(version: Version, changed: list[Added]) -> list[Added]:
        out = []
        for line in changed:
            index = line.number - 1
            if index < len(version.lines) and escaped(version.lines, index, BLOCKING_ALLOW):
                continue
            if judge(version, index, code_of(line.text)):
                out.append(line)
        return out
    return resolve([(debt(*blocking_sides(c)[0]), debt(*blocking_sides(c)[1])) for c in changes])


def blocking_sides(change: FileChange) -> tuple[tuple[Version, list[Added]], tuple[Version, list[Added]]]:
    """CHANGE's head and base Versions, made once per push for the blocking rules: `FileChange.head` makes a new
    Version per read, and the three rules would each redo the file's main-actor scope walk and each line's
    walk out of its blocks (memoized on the Version)."""
    if "blocking_sides" not in change.memo:
        change.memo["blocking_sides"] = ((change.head, change.added), (change.base, change.removed))
    return change.memo["blocking_sides"]


def outside_seams(changes: list[FileChange]) -> list[FileChange]:
    return [c for c in changes if not c.path.startswith(BLOCKING_SEAMS)]


def blocking_on_main(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """Added lines that block on the main thread: a blocking call (raw or seam) that surely runs on main
    (runs_on_main), and a main-queue sync hop or a sleep anywhere."""
    def judge(version: Version, index: int, code: str) -> bool:
        if ALWAYS_SCAN.search(code):
            return True
        return blocking_match(MAIN_SCAN, code) and index < len(version.lines) and runs_on_main(version, index)
    return changed_debt(outside_seams(changes), judge)


def maybe_blocking_on_main(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """Added blocking calls (raw or seam) that may run on main through a caller-isolated async function
    (may_run_on_main): warnings only."""
    def judge(version: Version, index: int, code: str) -> bool:
        return (index < len(version.lines) and blocking_match(MAIN_SCAN, code) and not runs_on_main(version, index)
                and may_run_on_main(version, index))
    return [WarnHit(h.path, h.number, h.text) for h in changed_debt(outside_seams(changes), judge)]


def raw_blocking(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """Added raw blocking primitives that main-blocking does not report (off the main thread, or in a closure)."""
    def judge(version: Version, index: int, code: str) -> bool:
        return (blocking_match(RAW_SCAN, code) and not ALWAYS_SCAN.search(code)
                and not (index < len(version.lines) and runs_on_main(version, index)))
    return changed_debt(outside_seams(changes), judge)


def doc_labels(doc: str) -> list[re.Pattern]:
    """The thread and queue labels the threading doc's "Registered threads and queues" section lists in
    backticks, each `<x>` inside a label a wildcard (a token that is only a placeholder lists nothing)."""
    start = doc.find(THREADING_DOC_SECTION)
    if start < 0:
        raise RuntimeError(f"{THREADING_DOC} has no \"{THREADING_DOC_SECTION[3:]}\" section")
    end = doc.find("\n## ", start + len(THREADING_DOC_SECTION))
    section = doc[start:end if end >= 0 else len(doc)]
    patterns = []
    for token in re.findall(r"`([^`\n]+)`", section):
        literal = re.sub(r"<[^>]*>", "", token)
        if len(literal.strip(" .-_")) < 3:
            continue  # `<x>`, `<pid>`: a placeholder, not a label
        patterns.append(re.compile("^" + ".+".join(re.escape(part) for part in re.split(r"<[^>]*>", token)) + "$"))
    return patterns


def label_listed(label: str, patterns: list[re.Pattern]) -> bool:
    text = re.sub(r"\\\([^)]*\)", "x", label)  # a string interpolation stands for any text
    return any(p.match(text) for p in patterns)


def undocumented_threads(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """Added threads, queues and BlockingAllowance reasons that plans/cmux-next/threading-model.md does not list.
    A thread or queue whose label is not a string literal (a variable) is not judged."""
    listed: dict[str, object] = {}

    def doc() -> dict[str, object]:
        """The doc's labels and allowances, read when a push adds a thread, queue or allowance to judge."""
        if not listed:
            text = BLOCKING_CONTEXT.get("threading_doc")
            if not isinstance(text, str):
                raise RuntimeError(f"{THREADING_DOC} could not be read at the pushed head")
            listed.update(labels=doc_labels(text), allowances=set(re.findall(r"^\|\s*`(\w+)`\s*\|", text, re.M)))
        return listed

    def judge(version: Version, index: int, code: str) -> bool:
        if not THREAD_SCAN.search(code):
            return False
        decl = ALLOWANCE_DECL.search(code)
        if decl:
            return decl.group(1) not in doc()["allowances"]
        # The label on the line, or `<name>.name = ...` on a later line of the same function for
        # `let <name> = Thread {` / `OperationQueue()` (the body of a Thread closure comes before its name).
        bound = THREAD_BINDING.search(code)
        line = version.lines[index] if index < len(version.lines) else code  # code_of blanks the string literals
        following = version.lines[index + 1:index + 1 + THREAD_NAME_WINDOW] if index < len(version.lines) else []
        for text in [line] + ([t for t in following if re.search(r"\b" + re.escape(bound.group(1)) + r"\.name\s*=", t)]
                              if bound else []):
            named = THREAD_NAME.search(text)
            if named:
                literal = named.group("literal")
                return literal is not None and not label_listed(literal[1:-1], doc()["labels"])
        return True  # an unnamed thread or queue: name it and list it

    return changed_debt(changes, judge)


def load_blocking_context(texts: dict[tuple[str, str], str], head: str) -> None:
    """Keeps HEAD's threading doc and package manifest for the rules above (a missing doc fails thread-doc open)."""
    for key in ("threading_doc", "manifest", "ui_targets"):
        BLOCKING_CONTEXT.pop(key, None)
    for key, path in (("threading_doc", THREADING_DOC), ("manifest", PACKAGE_MANIFEST)):
        if (head, path) in texts:
            BLOCKING_CONTEXT[key] = texts[(head, path)]

BLOCKING_RULES = (
    Rule("main-blocking", "A blocking call on the main thread (file I/O, a socket read, a wait, a process wait or a "
         "sync hop directly in main-actor code; `DispatchQueue.main.sync`, `Thread.sleep`, `usleep` anywhere)",
         "the main thread never blocks (plans/cmux-next/threading-model.md, Chrome's ScopedBlockingCall): one disk, "
         "lock or process wait on it drops frames and delays the next input; in Debug the runtime detector reports it",
         "move the work off the main thread (an actor, `Task.detached`, a `nonisolated` async function, the daemon) "
         "and apply its result on main; a wait becomes an `await` or a callback. The checked seams "
         "(`FileManager.checked`, `Data(blockingContentsOf:)`, `.blockingWait()`) are for code that runs off main",
         "// blocking-allow: <why this cannot leave the main thread, and its reviewed allowBlocking reason>",
         blocking_on_main),
    Rule("raw-blocking", "A raw blocking primitive (file read/write, `.write(to:)`, `FileManager.default.<disk op>`, "
         "`.wait()`, `.sync {`, `waitUntilExit()`, `readToEnd()`, sync XPC, `posix_spawn`, `fork()`) instead of its "
         "checked seam",
         "the runtime detector sees only the seams in CmuxNextCompat/Threading: a raw call that later runs on the "
         "main thread blocks it unseen",
         "use the seam: `FileManager.checked.<op>`, `Data(blockingContentsOf:)`, `String(blockingContentsOf:)`, "
         "`url.blockingResourceValues`, `handle.blockingReadToEnd()`, `semaphore.blockingWait()`, "
         "`queue.blockingSync`, `process.blockingWaitUntilExit()`, `blockingRead/Recv/Write/Send`",
         "// blocking-allow: <why the seam does not fit>",
         raw_blocking),
    Rule("maybe-main-blocking", "A blocking call in a caller-isolated async function (warning only)",
         "under NonisolatedNonsendingByDefault a non-@concurrent async function outside an actor runs on its caller's "
         "executor, so a main-actor caller runs the blocking call on main (AsyncProcess.run: 807 ms, 2026-10-24)",
         "mark the function `@concurrent` (or move the work into an actor) so it never runs on the caller's main thread",
         "// blocking-allow: <why every caller is off the main thread>",
         maybe_blocking_on_main),
    Rule("thread-doc", "A new thread, queue or blocking allowance that plans/cmux-next/threading-model.md does not list",
         "every thread and queue has an owner, a QoS, a bound and a back-pressure rule written down, and every "
         "main-thread blocking allowance is reviewed (Chrome's ScopedAllowBlocking friend list)",
         "name the thread or queue and add its label to the doc's \"Registered threads and queues\" (and a table row "
         "for a new kind); add a new BlockingAllowance to \"Reviewed blocking allowances\" in the same push",
         "// blocking-allow: <why this thread needs no entry>",
         undocumented_threads),
)
RULES += BLOCKING_RULES
# ---------------------------------------------------------------- end of main-blocking / thread-doc (PL-blocking)


# ---------------------------------------------------------------- diff

def parse_diff(diff: str) -> dict[str, FileChange]:
    """The files of a `-U0 --inter-hunk-context=0` diff run with `--src-prefix=a/ --dst-prefix=b/` (a user's
    diff.noprefix and diff.interHunkContext are ignored). A context line, should one come, is on both sides."""
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
                current.is_deleted = line == "+++ /dev/null"
        elif line.startswith("@@") and current is not None:
            old = re.search(r"-(\d+)(?:,(\d+))?", line)
            old_number = int(old.group(1)) if old else 0
            old_count = int(old.group(2)) if old and old.group(2) is not None else 1
            match = re.search(r"\+(\d+)(?:,(\d+))?", line)
            number = int(match.group(1)) if match else 0
            count = int(match.group(2)) if match and match.group(2) is not None else 1
            if count == 0:
                current.touched.add(max(number, 1))  # a pure deletion after line `number`
                current.touched.add(number + 1)
            # A side with no lines in this hunk gives context rules nothing to read: mark the unchanged line
            # before and after the hunk on both sides (an empty range starts at the line before it).
            if count == 0 or old_count == 0:
                head_before = number if count == 0 else number - 1
                base_before = old_number if old_count == 0 else old_number - 1
                current.head_anchors.update(n for n in (head_before, head_before + 1 + count) if n >= 1)
                current.base_anchors.update(n for n in (base_before, base_before + 1 + old_count) if n >= 1)
        elif current is not None and line.startswith("+"):
            current.added.append(Added(current.path, number, line[1:]))
            current.touched.add(number)
            number += 1
        elif current is not None and line.startswith("-"):
            current.removed.append(Added(current.path, old_number, line[1:]))
            old_number += 1
        elif current is not None and line.startswith(" "):
            number += 1
            old_number += 1
    return changes


def blobs(repo: Path, specs: list[tuple[str, str]], ids: dict | None = None) -> dict[tuple[str, str], str]:
    """{(rev, path): text} for SPECS in one `git cat-file --batch` (a path missing at its rev is left out); IDS, when
    given, gets each found blob's object id (the lexer cache's key).

    Raises git_batch.GitError when the read fails, so the hook's fail-open warning names it instead of the
    rules judging lines without their file's text.
    """
    oids: dict[str, str] = {}
    texts = git_batch.cat_file(repo, [f"{rev}:{path}" for rev, path in specs], env=git_env(), ids=oids)
    found = {}
    for rev, path in specs:
        blob = texts[f"{rev}:{path}"]
        if blob is not None:
            found[(rev, path)] = blob.decode("utf-8", "replace")
            if ids is not None:
                ids[(rev, path)] = oids[f"{rev}:{path}"]
    return found


def run_both(repo: Path, *commands: list[str]) -> list[str]:
    """Run git COMMANDS at once (each costs a process start on a busy Mac) and return their outputs."""
    procs = [subprocess.Popen(["git", "-C", str(repo), *c], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              stdin=subprocess.DEVNULL, env=git_env())
             for c in commands]
    return [p.communicate()[0].decode("utf-8", "replace") for p in procs]


# ---------------------------------------------------------------- warnings

@dataclass
class PerfHotMarker:
    """One `// perf-hot: <budget> <path-id>` marker and the declaration it marks."""
    line: int  # 1-based line of the marker
    budget: str
    path_id: str
    span: tuple[int, int] | None  # (declaration line, closing line), 1-based; None: it marks no declaration
    declaration: str = ""


def wrapped_declaration(lines: list[str], index: int) -> int | None:
    """The 0-based line where the declaration whose body `{` is on LINES[INDEX] starts, for a wrapped signature.

    Walking up, the signature's lines hold no brace and its parentheses balance out on the `{` line: the first
    line that matches DECL with every `(` it opens closed by the `{` line is the declaration. None when the `{`
    line closes no parenthesis opened above (a statement, not a wrapped signature) or the walk meets a brace.
    """
    head = code_of(lines[index]).split("{", 1)[0]
    unmatched = head.count(")") - head.count("(")
    k = index - 1
    while unmatched > 0 and k >= 0:
        code = code_of(lines[k])
        if "{" in code or "}" in code:
            return None
        unmatched -= code.count("(") - code.count(")")
        if unmatched == 0 and DECL.search(code):
            return k
        k -= 1
    return None


def perf_hot_markers(lines: list[str]) -> list[PerfHotMarker]:
    """Every `// perf-hot:` marker in LINES and the declaration it marks (codebase-health.py reads these too).

    A marker marks a declaration three ways: in the comment block above it (attributes and blank lines may
    sit between), trailing on its line, or trailing on the line with the body's `{` of a wrapped signature.
    """
    markers = []
    for index, line in enumerate(lines):
        match = PERF_HOT.search(line) if "perf-hot" in line else None
        if not match:
            continue
        if COMMENT_LINE.match(line):  # the marker in the comment block above the declaration
            j = index + 1
            while j < len(lines) and (COMMENT_LINE.match(lines[j]) or ATTRIBUTE_LINE.match(lines[j]) or not lines[j].strip()):
                j += 1
            first = j if j < len(lines) and DECL.search(code_of(lines[j])) else None
        elif DECL.search(code_of(line)):  # a trailing marker on the declaration line (adds no line)
            first = index
        else:
            first = wrapped_declaration(lines, index) if "{" in code_of(line) else None
        marker = PerfHotMarker(index + 1, match.group("budget"), match.group("path") or "", None)
        if first is not None:
            marker.span = (first + 1, block_end(lines, first) + 1)
            marker.declaration = code_of(lines[first]).strip()
        markers.append(marker)
    return markers


def block_end(lines: list[str], first: int) -> int:
    """The 0-based line that closes the first `{` block opened on or after LINES[FIRST] (the last line if none)."""
    depth, started, k = 0, False, first
    while k < len(lines):
        for c in code_of(lines[k]):
            if c == "{":
                depth += 1
                started = True
            elif c == "}":
                depth -= 1
        if started and depth <= 0:
            return k
        k += 1
    return len(lines) - 1


def perf_hot_warnings(changes: dict[str, FileChange], benches: dict) -> list[str]:
    out = []
    paths = benches.get("paths", {})
    for path, change in sorted(changes.items()):
        if not path.endswith(".swift"):
            continue
        if not change.has_perf_hot:
            continue
        for marker in perf_hot_markers(change.head_lines):
            if marker.span is None:
                if marker.line in change.touched:
                    out.append(f"{path}:{marker.line}: this `// perf-hot:` marks no declaration, so no edit of the hot "
                               "function warns: put it in the comment block above the declaration, or trailing on the "
                               "line with the body's `{`")
                continue
            first, last = marker.span
            if not any(first <= n <= last for n in change.touched):
                continue
            hot = marker.path_id
            entry = paths.get(hot, {})
            bench = entry.get("bench", "no bench mapped: add the path id to " + BENCHES)
            owner = f"; owner {entry['owner']}" if entry.get("owner") else ""
            out.append(f"{path}:{first}: changes perf-hot `{marker.declaration[:80]}` (budget {marker.budget}, "
                       f"{hot or 'no path id'}{owner}). Run before and after on the fleet, light and STRESS: {bench}")
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
    """PATTERN from OWNERS.md: a trailing `/` is a directory prefix, `**/` is zero or more folders, `**` crosses
    folders, `*` does not."""
    if pattern.endswith("/"):
        return path.startswith(pattern)
    regex = (re.escape(pattern).replace(r"\*\*/", "\1").replace(r"\*\*", "\0").replace(r"\*", "[^/]*")
             .replace("\1", "(?:.*/)?").replace("\0", ".*"))
    return re.fullmatch(regex, path) is not None


def glob_specificity(pattern: str) -> tuple[int, bool]:
    """How narrowly PATTERN names its files: the length of its literal start (before the first `*`), then an
    exact path (no wildcard, no trailing `/`) over a glob or a folder with the same start."""
    star = pattern.find("*")
    return (len(pattern) if star < 0 else star), (star < 0 and not pattern.endswith("/"))


def owner_warnings(files: list[str], owners: list[tuple[str, list[str], str, str]]) -> list[str]:
    """One warning per owned area of FILES. A file belongs to the most specific row whose globs match it
    (glob_specificity of its best glob), so a folder row (`cmux-tui/crates/cmux-tui-core/`) never names a second
    owner for a file a narrower row assigns (`cmux-tui/crates/cmux-tui-core/src/holder_runtime/`); rows tied on the
    same glob both name theirs. A file no row matches names no owner: a new crate has none until a row lists it."""
    hits: dict[int, list[str]] = collections.defaultdict(list)
    for path in files:
        scored = [(max(glob_specificity(g) for g in globs if glob_match(path, g)), row)
                  for row, (_, globs, _, _) in enumerate(owners) if any(glob_match(path, g) for g in globs)]
        if scored:
            best = max(score for score, _ in scored)
            for score, row in scored:
                if score == best:
                    hits[row].append(path)
    out = []
    for row, (area, _, owner, doc) in enumerate(owners):
        hit = hits.get(row)
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
    return settle(*measure(repo, base, head))


def settle(found: list[tuple[Rule, list[Added]]], warnings: list[tuple[str, str]]):
    """measure()'s hits as check()'s (refusals, warnings): an amount (NetHit.additive) at or under its limit is no
    finding, a fact (a new file, a file whose braces app-type could not follow) always is, and a warning hit
    (NetHit.warn) is a warning."""
    refusals, warnings = [], list(warnings)
    for rule, hits in found:
        hits = [h for h in hits if not (isinstance(h, NetHit) and h.additive and h.excess <= 0)]
        warnings += [(rule.id, f"{h.path}:{h.number}: {h.text}") for h in hits if getattr(h, "warn", False)]
        hits = [h for h in hits if not getattr(h, "warn", False)]
        if hits:
            refusals.append((rule, hits))
    return refusals, warnings


def measure(repo: Path, base: str, head: str) -> tuple[list[tuple[Rule, list[Added]]], list[tuple[str, str]]]:
    """([(rule, every hit, measurements and warning hits included)], warnings) for what HEAD adds over BASE."""
    # Fixed prefixes: a user's diff.noprefix / diff.srcPrefix would otherwise drop every file from the parse. No
    # inter-hunk context: a user's diff.interHunkContext would join nearby hunks with unchanged lines between them.
    specs = ["--", SWIFT_SOURCES, SWIFT_TESTS, *SHIPPED_BUILD_SPECS]
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    # The content diff and the blob read each decompress the same objects: on the slowest real pushes (242 files,
    # load 37) each took 0.7-1 s one after the other. The changed paths come first from a cheap name-only diff, so
    # the blobs are read while the content diff runs.
    diff_proc = subprocess.Popen(["git", "-C", str(repo), "diff", "-U0", "--inter-hunk-context=0", "--no-color",
                                  "--no-renames", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", base, head,
                                  *specs],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
    names = git(repo, "diff", "--name-only", "--no-renames", base, head, check=False)
    early = sorted(p for p in set(names.split("\n")) if p and in_diff_scope(p))
    blob_ids: dict[tuple[str, str], str] = {}
    texts = blobs(repo, [(head, p) for p in early] + [(base, p) for p in early] + [(head, BENCHES), (head, OWNERS)]
                  + [(head, MANIFEST), (base, MANIFEST), (head, THREADING_DOC), (head, PACKAGE_MANIFEST)], blob_ids)
    diff = diff_proc.communicate()[0].decode("utf-8", "replace")
    changes = parse_diff(diff)
    warnings: list[tuple[str, str]] = []
    if diff.strip() and not changes:
        warnings.append(("guardrails", "could not read this push's diff, so no rule ran on it (fail open); tell the "
                         "Performance Lead (PL-guardrails) with the output of: git diff -U0 " + f"{base} {head} | head"))
    paths = sorted(changes)
    late = [p for p in paths if p not in set(early)]  # none unless git lists a path one way only
    if late:
        texts.update(blobs(repo, [(head, p) for p in late] + [(base, p) for p in late], blob_ids))
    LEX_CACHE["dir"] = lex_cache_dir(repo)
    load_blocking_context(texts, head)
    for path in paths:
        change = changes[path]
        # A side with changed lines has the file: git lists no added line of a path absent at head.
        for rev, lines in ((head, change.added), (base, change.removed)):
            if lines and (rev, path) not in texts:
                raise git_batch.GitError(f"{path} has changed lines but no text at {rev}")
        text = texts.get((head, path), "")
        change.head_lines = text.split("\n")
        change.base_lines = texts.get((base, path), "").split("\n")
        change.has_perf_hot = "perf-hot:" in text
        change.memo["blobs"] = (blob_ids.get((head, path)), blob_ids.get((base, path)))
    head_types = GenericTypes(repo, head, [texts.get((head, p), "") for p in paths])
    base_types = GenericTypes(repo, base, [texts.get((base, p), "") for p in paths])
    head_targets = swift_scope.package_targets(texts.get((head, MANIFEST), ""))
    base_targets = swift_scope.package_targets(texts.get((base, MANIFEST), ""))
    try:
        # Classes in extensions of a type whose generic signature the push changes, in files it does not change.
        context_files, causes = generic_signature_context(repo, head, changes, head_types, base_types)
    except Exception as error:  # fail open for this reading only: the rules still judge the push's own files
        context_files, causes = [], {}
        warnings.append(("guardrails", check_failure("generic-signature context", error)))
    for change in [changes[p] for p in paths] + context_files:
        change.head_types, change.base_types = head_types, base_types
        change.head_main = main_by_default(change.path, head_targets)
        change.base_main = main_by_default(change.path, base_targets)
    files = [changes[p] for p in paths]
    moved = collections.Counter(r.text.strip() for c in files for r in c.removed if r.text.strip())
    found = []
    for rule in RULES:
        # The unchanged context files hold no added or removed line: only their touched context can add debt.
        scoped = [f for f in files + context_files if f.path.startswith(rule.scope) or f.path.endswith(rule.scope)]
        try:
            hits = rule.find(scoped, moved)
        except Exception as error:  # fail open for this rule only: a bug in one rule must not switch off the rest
            warnings.append(("guardrails", check_failure(f"rule {rule.id}", error)))
            continue
        hits = [Attributed(h.path, h.number, h.text, causes[h.path]) if h.path in causes and type(h) is Added else h
                for h in hits]
        if hits:
            found.append((rule, hits))
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
    return found, warnings


def load_push_range():
    """push_range.py next to this file: which commits a push owns (the gate and the arch ratchet use it too)."""
    name = "cmux_next_push_range"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, HERE / "push_range.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


def check_own(repo: Path, base: str, head: str, before=()):
    """check() for the push's own range (push_range.OwnRange: BASE, HEAD and the BEFORE ranges it does not own).

    No BEFORE: check(base, head). A merge (BEFORE holds the old remote head's range over the upstream it started
    from): what HEAD adds over BASE (the merged upstream) less what each BEFORE range adds (push_range.less), so
    neither upstream's lines nor what the branch pushed before count, and an upstream removal never pays for a
    line the branch adds. Line hits are matched by rule, file and text. A count rule's bucket counts its amount
    less the BEFORE ranges' amounts of that bucket (push_range.own_count) against the bucket's limit; a bucket
    that is a fact (a new file) is the push's only when no BEFORE range has it. The warnings are BASE..HEAD's,
    with every warning hit's amount taken the same way, plus any rule that failed on a BEFORE range.
    """
    if not before:
        return settle(*measure(repo, base, head))
    push_range = load_push_range()
    # The ranges share most of their objects and each measure() waits on git most of the time: run them together
    # (the slowest real merge push paid 2 x 1.3 s one after the other).
    with concurrent.futures.ThreadPoolExecutor(max_workers=1 + len(before)) as pool:
        results = list(pool.map(lambda pair: measure(repo, *pair), [(base, head), *before]))
    found, warnings = results[0]
    others = []
    for theirs, other_warnings in results[1:]:
        # A rule that failed on one range is off for this push even when it ran on the others.
        warnings += [w for w in other_warnings if w[0] == "guardrails" and w not in warnings]
        others.append({rule.id: hits for rule, hits in theirs})
    mine = {rule.id: hits for rule, hits in found}
    own = []
    for rule in RULES:
        hits = mine.get(rule.id, [])
        prior = [other.get(rule.id, []) for other in others]
        if not rule.net:
            kept = push_range.less(hits, prior, key=lambda h: (h.path, h.text.strip()))
        else:
            # Every bucket either side measured: one only the other side has is an amount the push took back.
            by_bucket = {h.bucket: h for h in hits}
            buckets = dict.fromkeys([h.bucket for h in hits] + [h.bucket for side in prior for h in side
                                                                 if isinstance(h, NetHit)])
            kept = [h for b in buckets if (h := own_net_hit(push_range, by_bucket.get(b), prior, b)) is not None]
        if kept:
            own.append((rule, kept))
    return settle(own, warnings)


def own_net_hit(push_range, hit: NetHit | None, prior: list[list[Added]], bucket: str) -> NetHit | None:
    """The push's own part of BUCKET: HIT (None: only the PRIOR ranges measured it) less the PRIOR ranges' amounts
    of BUCKET, or None when the push owns none of it."""
    theirs = [h for side in prior for h in side if isinstance(h, NetHit) and h.bucket == bucket]
    if not theirs:
        return hit
    model = hit or theirs[0]
    if not model.additive:
        return None  # a fact (a new file) the other side already had: not this push's
    now = hit.excess + hit.limit if hit is not None else 0
    had = [h.excess + h.limit for h in theirs]
    mine = push_range.own_count(now, had)
    if hit is not None and mine == now:
        return hit
    text = (f"{hit.text}; " if hit is not None else f"[{bucket}] ") + (
        f"this push's own: {mine:+d} ({now:+d} over the merged upstream, less {sum(had):+d} the other side already "
        "had: the branch's last push)")
    return dataclasses.replace(model, text=text, excess=mine - model.limit)


def check_push(repo: Path, base: str, head: str, upstream_ref: str = UPSTREAM):
    """check() for a push of HEAD whose remote head is BASE: check_own() over push_range.own_range().

    A branch merged with or rebased onto feat-cmux-next pushes every line others landed there since its fork
    point. CI never runs these rules, so those lines can carry debt the push did not write (a skip reason, a
    clone with old or no hooks, --no-verify): they never count (push_range.py has the exact rule).
    """
    own = load_push_range().own_range(repo, head, [base], upstream_ref)
    return check_own(repo, own.base, own.head, own.before)


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
            if getattr(hit, "cause", ""):
                lines.append(f"      ({hit.cause})")
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


ARCH_RATCHET = "arch-ratchet.py"


class Ratchet:
    """The arch ratchet (arch-ratchet.py next to this file) for RANGES, running on a thread from the start.

    Its cost is the Swift files it reads (git) and analyzes (Python, about 1 ms per file; arch_counts'
    FactsCache keeps every analyzed content, so a warm push analyzes only new contents); the ratchet report
    prints how many. A caller that starts it before other work pays what is left of it at finish(), but the
    analysis shares the interpreter with that work, so it is not free beside CPU-bound scanners. It fails
    open: a missing or broken script, an error or a run past WAIT_LIMIT is a warning and lets the push
    through.
    """

    WAIT_LIMIT = 20.0

    def __init__(self, repo: Path, ranges: list, scripts_dir: Path | None = None) -> None:
        self.out: list[str] = []
        self.refused = False
        self.error: str | None = None
        self.thread: threading.Thread | None = None
        self.waited = 0.0  # seconds finish() waited for the thread (prepush-gate --timings prints it)
        script = (scripts_dir or HERE) / ARCH_RATCHET
        try:
            if not script.is_file():
                self.error = f"{script} is missing; rerun scripts/install-git-hooks.sh"
                return
            spec = importlib.util.spec_from_file_location("cmux_next_arch_ratchet", script)
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module  # dataclasses resolve their module through sys.modules
            spec.loader.exec_module(module)
        except (Exception, SystemExit) as error:
            self.error = f"{ARCH_RATCHET} failed ({type(error).__name__}: {error})"
            return

        def run() -> None:
            try:
                self.refused = bool(module.run_push(repo, ranges, out=self.out))
            except (Exception, SystemExit) as error:  # run_push fails open itself; this is the last guard
                self.error = f"{ARCH_RATCHET} failed ({type(error).__name__}: {error})"

        self.thread = threading.Thread(target=run, name="arch-ratchet", daemon=True)
        self.thread.start()

    def finish(self) -> tuple[str, bool]:
        """(the ratchet's report, whether it refuses the push)."""
        if self.thread is not None:
            started = time.monotonic()
            self.thread.join(self.WAIT_LIMIT)
            self.waited = time.monotonic() - started
            if self.thread.is_alive():
                return (f"guardrails: WARNING: the arch ratchet ran past {self.WAIT_LIMIT:.0f}s; not applied to this "
                        "push. Tell the Performance Lead with this line."), False
        lines = list(self.out)
        if self.error:
            lines.append(f"guardrails: WARNING: {self.error}; the arch ratchet was not applied to this push. Tell the "
                         "Performance Lead with this line.")
        return "\n".join(lines), self.refused and self.error is None


def start_ratchet(repo: Path, ranges: list) -> Ratchet:
    """Start the arch ratchet for RANGES now (prepush-gate calls this before its scanners)."""
    return Ratchet(repo, ranges)


GHOSTTY_NEXT = "ghostty-next"
GHOSTTY_KIT = "Packages/Shared/CmuxGhosttyKit/Package.swift"
GHOSTTY_PIN = re.compile(r"ghostty-next/releases/download/xcframework-([0-9a-f]{40})-")


def ghostty_pin_problem(repo: Path, base: str, head: str, before=()) -> str | None:
    """The refusal when the push's own range (BASE..HEAD less the BEFORE ranges it does not own,
    push_range.OwnRange) changes the ghostty-next gitlink or the GhosttyNextKit pin and HEAD's two name different
    ghostty-next commits (769ae064b16 moved the gitlink and left the app on a binary two pins behind its source).
    A mismatch others landed refuses nobody: a range that does not change either file passes."""
    def changes(a: str, b: str) -> bool:
        return bool(git(repo, "diff", "--name-only", "--no-renames", a, b, "--", GHOSTTY_NEXT, GHOSTTY_KIT,
                        check=False).strip())
    if not changes(base, head) or any(changes(a, b) for a, b in before):
        return None
    link = git(repo, "ls-tree", head, GHOSTTY_NEXT, check=False).split()
    gitlink = link[2] if len(link) >= 3 and link[1] == "commit" else None
    manifest = git(repo, "show", f"{head}:{GHOSTTY_KIT}", check=False)
    pinned = GHOSTTY_PIN.search(manifest)
    if gitlink is None or pinned is None or pinned.group(1) == gitlink:
        return None  # no submodule or no pin in this tree: nothing to compare
    return ("guardrails: this push leaves the ghostty-next source and its binary on different commits:\n"
            f"  [ghostty-pin] the {GHOSTTY_NEXT} gitlink is {gitlink[:12]}, but {GHOSTTY_KIT}'s GhosttyNextKit "
            f"url downloads the xcframework built at {pinned.group(1)[:12]}\n"
            "    why: the app links the pinned binary, so it runs code other than its source, and the next landing "
            "that takes either side moves the other back without a word\n"
            f"    do:  publish the xcframework for {gitlink[:12]} (a ghostty-next release "
            f"xcframework-{gitlink}-apple-vN) and change the url and checksum in the same push, or set the gitlink "
            f"back to {pinned.group(1)[:12]}")


def run_push(repo: Path, ranges: list, ratchet: Ratchet | None = None) -> bool:
    """Print the guardrails report for the pushed RANGES: the line rules (check_own per range) and the arch
    ratchet (started here unless the caller started it). True when either refuses the push.

    RANGES are push_range.OwnRange values (prepush-gate passes the ones its scanners judged, so all three judge
    the same commits); a (base, head) pair is a push whose remote head is base (push_range.as_own_ranges)."""
    ranges = load_push_range().as_own_ranges(repo, ranges)
    ratchet = ratchet or Ratchet(repo, ranges)
    refused = False
    for own in ranges:
        # Fail open per range: a range the checker could not judge goes through; one it judged keeps its answer.
        try:
            refusals, warnings = check_own(repo, own.base, own.head, own.before)
            text, refuse = format_report(refusals, warnings)
        except (Exception, SystemExit) as error:  # SystemExit: git() exits on a failed git call
            print(f"prepush-gate: WARNING: guardrails.py failed ({type(error).__name__}: {error}) on "
                  f"{own.base[:11]}..{own.head[:11]}; not applied to that range. Tell the Performance Lead "
                  "(PL-guardrails) with this line.", file=sys.stderr)
            continue
        if text:
            print(text)
        refused = refused or refuse
        try:
            pin = ghostty_pin_problem(repo, own.base, own.head, own.before)
        except Exception as error:  # fail open: a broken check must not stop the push
            pin = None
            print(f"guardrails: {check_failure('ghostty-pin', error)}")
        if pin:
            print(pin)
            refused = True
    text, refuse = ratchet.finish()
    if text:
        print(text)
    return refused or refuse


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
        print("arch ratchet rows (arch-ratchet.py --list-rules; escape: a dated exception in "
              "plans/cmux-next/arch-ratchet.json)")
        return 0
    repo = Path(args.repo or git(Path.cwd(), "rev-parse", "--show-toplevel").strip())
    started = time.monotonic()
    push_range = load_push_range()
    try:
        own = push_range.given_range(repo, args.base, args.head) if args.base else push_range.own_range(repo, args.head)
    except ValueError as error:
        raise SystemExit(f"guardrails: {error}")
    print(f"guardrails: judging {own.describe()}")
    refused = run_push(repo, [own])
    print(f"guardrails: {'refused' if refused else 'ok'} ({time.monotonic() - started:.2f}s)")
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main())

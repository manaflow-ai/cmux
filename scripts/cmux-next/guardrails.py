#!/usr/bin/env python3
"""cmux-next guardrails: refuse new architecture debt in what a push adds; warn on hot paths and owned areas.

Run by the pre-push hook through `prepush-gate.py --pre-push` (and by a plain local `prepush-gate.py`),
never by CI (Lawrence 2026-10-23: no new CI gates): every rule here is in the local-only tier (prepush-gate's
LOCAL_TIER, p10-stability-199), and under GITHUB_ACTIONS run_push and a judging run judge nothing. Only Swift lines the push ADDS under
Packages/macOS/CmuxNext/Sources count (wakeup-ext also reads the app-linked Shared packages, CmuxUpdater,
the cmux-tui crates' src, webviews/src and the CEF shim with wakeup-audit.py's rules; safety-todo reads every
package's Sources and Tests; the Rust stability rules read the shipped crates' src with the pinned ast-grep),
plus unchanged lines that become debt because the push changed the line that gives them their context (`struct` ->
`class` around a static, a view renamed to a `...Row`, an edited or deleted deinit in a generic class's body, or a
type made generic around the classes in its extensions, read in every Sources and Tests file that extends it:
generic_signature_context) or the comment that escaped them (a deleted or reworded `// <rule>-allow:` line).
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
            on the fleet, and the id's `trace` catalog names to read it under. A marker the push touches
            that marks no declaration warns too.
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
  scripts/cmux-next/guardrails.py --self-test        # the input-monitor, target-settings, safety-todo,
                                                     # raw-continuation, trap-api, decode-trap and Rust stability
                                                     # cases
"""
from __future__ import annotations

import argparse
import bisect
import collections
import concurrent.futures
import dataclasses
import functools
import hashlib
import importlib.util
import itertools
import json
import os
import posixpath
import re
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
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
# The linked packages: CmuxNext's Package.swift links Shared, macOS and iOS packages by path, and
# their code runs in the app, so the blocking rules and task-priority read their Sources too (LINKED_RULE_SCOPE).
# LINKED_SOURCES is a rule scope entry that matches no path prefix: in_rule_scope() matches it to a file under the
# Sources of a package in the closure load_linked_packages() read. Chrome's blocking rules hold in every component
# the browser links, not only //chrome (base/threading/thread_restrictions.h).
LINKED_SOURCES = "<linked package Sources>"
LINKED_RULE_SCOPE = (SOURCES, LINKED_SOURCES)
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


def on_ci() -> bool:
    """Whether this runs under GitHub Actions: every rule here is local-only (p10-stability-199), so CI gains no gate
    from it; --list and --self-test still run."""
    return bool(os.environ.get("GITHUB_ACTIONS"))


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
    # The local tier: judged only on the person's machine, never under GitHub Actions.
    local_only: bool = False


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
    """PATH is one of check()'s diff pathspecs (SWIFT_SOURCES, SWIFT_TESTS, SHIPPED_BUILD_SPECS, WAKEUP_EXT_SPECS,
    PACKAGE_MANIFEST_SPEC, PACKAGE_SWIFT_SPECS, RUST_STABILITY_SPECS, QUALITY_BASELINE), so its blobs are read while the content diff
    runs. A path this misses is read after the diff (check()'s late read)."""
    return (in_swift_scope(path) or in_wakeup_ext_specs(path) or is_package_manifest(path) or is_package_swift(path)
            or in_rust_stability_scope(path) or path == QUALITY_BASELINE)


def in_swift_scope(path: str) -> bool:
    """PATH is in SWIFT_SOURCES, SWIFT_TESTS or SHIPPED_BUILD_SPECS: the files every rule but wakeup-ext, the
    generic-type context and the perf-hot warning read."""
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
UI_LEVELS = 2  # the batches of files GenericTypes.prefetch reads ahead: the named types, then their superclasses


class GenericTypes:
    """Which type names are declared generic (`struct Name<...>`) at one revision, and which are UI types (main
    actor by what they inherit, `final class TerminalView: NSView`).

    KNOWN holds the declarations in the push's own files at that revision. A name it lacks is looked up once in
    the revision's `Name.swift` files (CLAUDE.md: one major type per file, named after the type); a type declared
    in a file of another name is not found, and its extensions read as non-generic and not UI (fail open).
    """

    def __init__(self, repo: Path | None, rev: str | None, texts: list[str]):
        self.repo, self.rev = repo, rev
        self.texts = texts
        self.known = {name for text in texts for name in GENERIC_TYPE.findall(text)}
        self.looked: dict[str, bool] = {}
        self.ui_known: set[str] | None = None
        self.ui_looked: dict[str, bool] = {}
        self.by_name: dict[str, list[str]] | None = None  # file name -> its paths at REV
        self.named: dict[str, str] = {}  # type name -> its `Name.swift` texts, joined
        self.headers: dict[str, list] = {}  # type name -> its class or struct declarations in `Name.swift`

    def __contains__(self, name: str) -> bool:
        if name in self.known:
            return True
        if name not in self.looked:
            declared = re.compile(r"\b(?:class|struct|enum|actor)\s+" + re.escape(name) + r"\s*<")
            self.looked[name] = declared.search(self.named_file(name)) is not None
        return self.looked[name]

    def ui_type(self, name: str) -> bool:
        """Whether NAME is a UI type (check-main-actor-work.py's ui_subclasses): the main-thread rules read an
        extension of it in another file (`extension TerminalView` in TerminalView+Drag.swift) as main actor."""
        scope = swift_scope.main_actor_scope
        if self.ui_known is None:
            self.ui_known = set()
            pushed = [scope.type_headers(text.split("\n")) for text in self.texts]
            # The files the push's declarations name (`extension TerminalView`, `: TerminalView`), read in batches.
            self.prefetch({n for headers in pushed for h in headers
                           for n in ([h.name] if h.kind == "extension" else h.inherited if h.kind == "class" else [])})
            for headers in pushed:
                self.ui_known |= scope.ui_subclasses(headers, self.ui_type)
        if name in self.ui_known:
            return True
        if name not in self.ui_looked:
            self.ui_looked[name] = False  # a cycle (`class A: B`, `class B: A`) reads as no UI type
            self.prefetch({name})
            self.ui_looked[name] = any(scope.inherits_ui(h, self.ui_type) for h in self.headers[name])
        return self.ui_looked[name]

    def named_file(self, name: str) -> str:
        """The revision's `NAME.swift` files under Sources and Tests, joined ("" when there is none)."""
        self.prefetch({name})
        return self.named[name]

    def prefetch(self, names: set[str], levels: int = UI_LEVELS):
        """Read the `Name.swift` files of NAMES not read yet in one `git cat-file --batch`, then, for LEVELS - 1 more
        batches, the files of the types their classes inherit (a subclass of a subclass of NSView)."""
        wanted = {n for n in names if n not in self.named}
        if not wanted:
            return
        if self.repo is None or self.rev is None:
            self.named.update(dict.fromkeys(wanted, ""))
            self.headers.update({n: [] for n in wanted})
            return
        if self.by_name is None:
            self.by_name = collections.defaultdict(list)
            tree = git(self.repo, "ls-tree", "-r", "--name-only", self.rev, "--", SOURCES, TESTS, check=False)
            for path in tree.split("\n"):
                self.by_name[path.rsplit("/", 1)[-1]].append(path)
        paths = {n: self.by_name.get(f"{n}.swift", []) for n in wanted}
        specs = [(self.rev, p) for found in paths.values() for p in found]
        texts = blobs(self.repo, specs) if specs else {}
        inherited = set()
        for n, found in paths.items():
            self.named[n] = "\n".join(texts[(self.rev, p)] for p in found if (self.rev, p) in texts)
            lines = [line for line in self.named[n].split("\n") if n in line] if found else []
            self.headers[n] = [h for h in swift_scope.main_actor_scope.type_headers(lines)
                               if h.name == n and h.kind != "extension"]
            inherited.update(i for h in self.headers[n] if h.kind == "class" for i in h.inherited)
        if levels > 1:
            self.prefetch(inherited, levels - 1)


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
# Every off-main task, queue and thread states its priority on purpose (Lawrence's threading items 3 and 5,
# plans/cmux-next/PATTERNS.md P14; Chromium base/task/task_traits.h: every posted task names its TaskPriority, and
# base/threading/platform_thread.h: every thread is created with a ThreadType). Per form:
# - `Task.detached` only in CmuxNextWakeups, the owner of off-main tasks (elsewhere `work.task(priority) { }`, which
#   quit can drain, or a plain `Task { }`); there it names `priority:`.
# - `DispatchQueue.global(` only in CmuxNextWakeups (a root queue has no name, lane or shutdown: `work.run`
#   elsewhere); there it names `qos:`.
# - `DispatchQueue(label:` names `qos:` or `target:`.
# - `Thread {` / `Thread(block:` / `Thread(target:` (also `Foundation.Thread`, `Thread.init`, the arguments on the
#   next line) sets `.name =` and `.qualityOfService =` on the variable or property it is assigned to, within
#   THREAD_QOS_LINES (its closure body comes first); a `class X: Thread` sets them in its body (its init).
#   `Thread.detachNewThread` starts at once and cannot, so it is refused.
# - `OperationQueue()` sets `.name =` and `.qualityOfService =` the same way, within OPERATION_QUEUE_LINES.
# - A thread or operation queue that nothing names (`return Thread {`, `delegateQueue: OperationQueue()`) is refused:
#   nothing can set its properties before it runs.
# - The level set is not `.userInteractive` or `.background` (RESERVED_LEVEL's reasons) or `.default` (states nothing).
# - `delegateQueue: nil` is refused: URLSession then makes an unnamed queue at default QoS.
# A plain `Task { }` is not counted: it inherits its caller's priority and actor, which is right in almost every case
# (lead, 2026-10-24). An argument list is read to its closing parenthesis, so a call split over lines counts by what
# it names. `// qos-allow: <why>` escapes every form.
TASK_CALL = re.compile(r"(?P<detached>\bTask\.detached\s*[({])|(?P<global>\bDispatchQueue\.global\()"
                       r"|(?P<queue>\bDispatchQueue\(\s*label:)"
                       r"|(?:^\s*|[=(,\[]\s*|\breturn\s+)"
                       r"(?P<thread>(?:Foundation\.)?Thread(?:\.init)?\s*(?:\{|\((?:\s*$|block:|target:)))"
                       r"|(?P<thread_subclass>\bclass\s+\w+\s*:\s*(?:Foundation\.)?Thread\b(?!\.))"
                       r"|(?P<detach_thread>\bThread\.detachNewThread\b)"
                       r"|(?P<operation_queue>\bOperationQueue\(\))"
                       r"|(?P<delegate_nil>\bdelegateQueue:\s*nil\b)")
STATED = re.compile(r"\b(priority|qos|target):")
RESERVED_LEVEL = re.compile(r"\b(priority|qos):\s*(\.|\w+\.)?(userInteractive|unspecified|background)\b")
RESERVED_SET = re.compile(r"\s*(\.|\w+\.)?(userInteractive|background|default)\b")  # after `.qualityOfService =`
QOS_ALLOW = "qos-allow:"
TASK_ARGS_MAX_LINES = 8  # an argument list longer than this is not a queue or task init in this codebase
TASK_OWNER = SOURCES + "CmuxNextWakeups/"  # the one module that may detach a Task or use a root queue
THREAD_QOS_LINES = 40  # lines from `Thread {` to its `.name =` and `.qualityOfService =`
OPERATION_QUEUE_LINES = 10  # lines from `OperationQueue()` to its `.name =` and `.qualityOfService =`
# What a creation is assigned to: `let t: Thread? =`, `var t =`, `self.reader =`, `holder.reader =`.
CREATED_BINDING = re.compile(r"(?:\b(?:let|var)\s+(?P<name>\w+)\s*(?::[^=]+)?"
                             r"|(?:^|[^\w.])(?P<lvalue>(?:\w+\.)*\w+)\s*)=\s*$")


def unstated_args(version: Version, index: int, code: str, start: int) -> bool:
    """Whether the call at CODE[START:] (line INDEX) names no priority, QoS or target, or names a level the model
    keeps for other work: `.userInteractive` (the main thread and the threads a frame waits for only),
    `.unspecified` (unstated in effect) or `.background` (work nothing ever waits for: say so in the escape)."""
    rest = code[min(i for i in (code.find("(", start), code.find("{", start)) if i >= 0):]
    if rest.startswith("{"):
        return True
    args, depth = "", 0
    lines = [rest] + [code_of(line) for line in version.lines[index + 1:index + TASK_ARGS_MAX_LINES]]
    for line in lines:
        for i, c in enumerate(line):
            depth += c == "("
            depth -= c == ")"
            if depth == 0:
                args += line[:i + 1]
                return not STATED.search(args) or bool(RESERVED_LEVEL.search(args))
        args += line + "\n"
    return not STATED.search(args) or bool(RESERVED_LEVEL.search(args))


def created_receiver(version: Version, index: int, code: str, start: int, kind: str) -> str | None:
    """The pattern for the receiver that the thread or queue created at CODE[START:] (line INDEX) gets its
    properties set on: its variable or property (the binding may end the line above), `self.` or nothing at a
    line start in a Thread subclass, None when nothing names it."""
    if kind == "thread_subclass":
        return r"(?:^\s*|(?<![\w.])self\.)"
    prefix = code[:start]
    if not prefix.strip() and index > 0:
        prefix = code_of(version.lines[index - 1])
    bound = CREATED_BINDING.search(prefix.rstrip() + " ")
    if bound is None:
        return None
    name = bound.group("name") or bound.group("lvalue").removeprefix("self.")
    return r"(?<![\w.])(?:self\.)?" + re.escape(name) + r"[?!]?\."


def unset_properties(version: Version, index: int, code: str, start: int, kind: str) -> tuple[bool, list[int]]:
    """(the thread or operation queue created at CODE[START:] on line INDEX leaves `.name` or `.qualityOfService`
    unset on its receiver in its window, sets a reserved level, or has no receiver; the window's 1-based lines,
    so a push that edits, inserts or deletes in it rejudges the unchanged creation line)."""
    end = min(len(version.lines), index + (OPERATION_QUEUE_LINES if kind == "operation_queue" else THREAD_QOS_LINES))
    window = list(range(index + 2, end + 1))
    receiver = created_receiver(version, index, code, start, kind)
    if receiver is None:
        return True, window
    texts = [code[start:]] + [code_of(line) for line in version.lines[index + 1:end]]
    for name in ("name", "qualityOfService"):
        setter = re.compile(receiver + name + r"\s*=(?!=)")
        found = next((m for m in (setter.search(text) for text in texts) if m), None)
        if found is None or (name == "qualityOfService" and RESERVED_SET.match(found.string, found.end())):
            return True, window
    return False, window


def unstated_priority(version: Version, index: int) -> tuple[bool, list[int]]:
    """(a task, queue, thread or URLSession delegate queue created on line INDEX does not state its priority the way
    its form must (see the section comment), the 1-based lines its judgement read: a push that touches one of them
    rejudges the unchanged creation line)."""
    code = code_of(version.lines[index])
    debt, openers = False, []
    owner = version.path.startswith(TASK_OWNER)
    for match in TASK_CALL.finditer(code):
        kind = match.lastgroup
        if kind in ("detached", "global"):
            debt |= not owner or unstated_args(version, index, code, match.start(kind))
        elif kind == "queue":
            debt |= unstated_args(version, index, code, match.start(kind))
        elif kind in ("detach_thread", "delegate_nil"):
            debt = True
        else:
            missing, window = unset_properties(version, index, code, match.start(kind), kind)
            debt |= missing
            openers += window
    return debt, openers


# The one fix for a main-thread hop (p06-scheduler.md recipe R-hop): main-async and main-hop print it, so neither
# rule's fix is a line the other refuses.
R_HOP = ("recipe R-hop: change the model synchronously in the input's turn, or post with a class and an owner "
         "(`mainWork.post(.visible, owner: ...)`, `node.queue(...).post`), or compute off main in a nonisolated "
         "Task and `.reply(on:)`; deliveries use `MainDelivery(class:owner:)`")

RULES = (
    Rule("unchecked-sendable", "`@unchecked Sendable` / `nonisolated(unsafe)` without a safety argument",
         "it switches off the data-race checker; without a written argument nobody can review it",
         "an actor, a Sendable value type, or CmuxNextCompat `Mutex` around the state (a new `Mutex` says why on its "
         "line or directly above: `// concurrency-allow: <why>`, the carve-out rule); when it is truly safe, "
         "say why on the declaration line or the line directly above: `// crash-allow: <the safety argument>` "
         "(crash_ratchet.py's class and escape: CI's ratchet reads the same two lines; it counts the line as a "
         "waived hit: record it with crash_ratchet.py --record-waivers)",
         "// crash-allow: <the safety argument>",
         unchecked_sendable),
    Rule("main-async", "`DispatchQueue.main.async`",
         "an untyped hop that reorders work and hides isolation (CLAUDE.md forbids it in new code)",
         R_HOP,
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
    Rule("bench-hooks-shipped", "The bench or a sanitizer configuration in a shipped build's settings",
         "CMUX_BENCH_HOOKS (reload.sh --config bench) keeps the debug.* control commands in an optimized app for "
         "the fleet benches, and a sanitizer config (reload.sh --config asan|tsan|ubsan) ships its runtime and its "
         "slowdown; in a release, nightly or RC build's settings either would ship to users",
         "build benches with `scripts/reload.sh --config bench` or a measure script's `--config=bench` only, and "
         "sanitizer apps with `scripts/reload.sh --config asan|tsan|ubsan`; shipped pipelines run "
         "scripts/cmux-next/check-no-bench-hooks.sh on their app",
         None,
         line_rule(r"CMUX_BENCH_HOOKS|--config[= ](bench|asan|tsan|ubsan)\b"
                   r"|ENABLE_(ADDRESS|THREAD|UNDEFINED_BEHAVIOR)_SANITIZER\s*=\s*YES"
                   r"|-enable(Address|Thread|UndefinedBehavior)Sanitizer\b", None),
         scope=SHIPPED_BUILD + (".xcconfig", "project.pbxproj")),
    Rule("task-priority", "A task, queue or thread without a stated priority, or at a reserved level: a `Task.detached` "
         "or `DispatchQueue.global(` outside CmuxNextWakeups, a queue with no `qos:`/`target:`, a `Thread` (or Thread "
         "subclass) or `OperationQueue()` with no `.name =` and `.qualityOfService =` on its own variable, or one that "
         "nothing names, `Thread.detachNewThread`, or `delegateQueue: nil`",
         "a task, queue or thread that does not say how much a person waits for it runs at whatever QoS it inherits or "
         "the default: work nobody waits for competes with typing and frames, and the main thread can wait on work that "
         "runs below it (priority inversion; plans/cmux-next/PATTERNS.md P14). A detached Task or root-queue block has "
         "no owner quit can drain. .userInteractive is for the main thread and the threads a frame waits for; "
         ".unspecified states nothing; .background may wait without limit",
         "off-main async work: `work.task(.userVisible) { ... }` (BackgroundWork.task: stated priority, drained at quit), "
         "or a plain `Task { }` that inherits its caller's; blocking work (file I/O, a process wait, a sync C call, a "
         "long parse): `work.run(_:mayBlock:)` or `AsyncProcess`, never a root queue or the cooperative pool; "
         "`DispatchQueue(label: ..., qos: .utility)`; a Thread: `thread.name = ...` and `thread.qualityOfService = "
         ".utility` before `start()` (not `Thread.detachNewThread`; a subclass sets them in its init); an "
         "OperationQueue: `let queue = OperationQueue()`, set `queue.name` and `queue.qualityOfService`, and pass "
         "`queue` as a URLSession's `delegateQueue:`",
         "// qos-allow: <why: a frame waits for it (userInteractive), it inherits on purpose, or nothing ever waits for it (background)>",
         matcher_rule(Matcher(TASK_CALL, re.compile(r"//\s*" + re.escape(QOS_ALLOW) + r"\s*\S"), unstated_priority)),
         scope=LINKED_RULE_SCOPE),
    Rule("appkit-index", "A raw AppKit row or column index read (`.clickedRow`, `.clickedColumn`, `.selectedColumn`, "
         "`item(atRow:`, `selectedRow(inColumn:`)",
         "they are -1 when a click lands off the rows or nothing is selected, and past the end after a reload; "
         "AppKit raises NSRangeException for such an index and the app ends (#24776, NSBrowser itemAtRow:inColumn:)",
         "CmuxNextCompatAppKit's checked accessors: `table.clickedRowIfValid` / `selectedRowIfValid`, "
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


# ---------------------------------------------------------------- sync-layout (PL-guardrails)
# A forced layout or display pass, or a CATransaction flush, does on the caller's turn what the frame does once
# per display refresh (plans/cmux-next/chrome-parity/p03-rendering.md R4, DC11). Blink names the reason of every
# forced lifecycle update (`Document::UpdateStyleAndLayout(DocumentUpdateReason)`,
# third_party/blink/renderer/core/dom/document.cc); here the reason is the `// sync-layout: <why>` comment, on the
# hit's line or the line directly above it, the same pattern, window and raw line text (comments and strings too,
# as its `rg -n` reads them) as render-done-checks.py's MQ-sync-layout queue and DC11, so a push that passes this
# rule never grows that queue. Added lines only, base debt per file as the other line rules; a fault in the rule
# turns off only it (check()'s fail open per rule).
# The block owns its lines from here to `RULES += SYNC_LAYOUT_RULES`.
SYNC_LAYOUT = re.compile(r"layoutSubtreeIfNeeded|displayIfNeeded|\.display\(\)|CATransaction\.flush")
SYNC_LAYOUT_ALLOW = re.compile(r"//\s*sync-layout:\s*\S")
SYNC_LAYOUT_RULES = (
    Rule("sync-layout", "A forced synchronous layout, display or flush (`layoutSubtreeIfNeeded`, `displayIfNeeded`, "
         "`.display()`, `CATransaction.flush`) without a reason",
         "it runs layout, drawing or a commit on the caller's turn instead of once in the next frame: a forced pass "
         "per change or per animation frame is a main-thread stall and a dropped frame (CLAUDE.md: one frame per "
         "display refresh; p03-rendering.md R4, DC11)",
         "set `needsLayout` / `needsDisplay` (behind a changed value) and let the frame lay out and draw; read "
         "geometry from the model, not from a fresh layout; when the next statement truly needs the laid-out "
         "result (a measured size before a window opens, a snapshot), say why on the line or the line directly "
         "above",
         "// sync-layout: <why this turn needs the layout now>",
         matcher_rule(Matcher(SYNC_LAYOUT, SYNC_LAYOUT_ALLOW, code=lambda text: text, window=ratchet.allow_lines))),
)
RULES += SYNC_LAYOUT_RULES
# ---------------------------------------------------------------- end of sync-layout


# ---------------------------------------------------------------- input-monitor (p04-input, PL-typing)
# One input tap (plans/cmux-next/chrome-parity/p04-input.md (A)): `CmuxApplication.sendEvent` is the only place
# that sees raw NSEvents, and CmuxNextInput's InputEventTap hands them to typed subscriptions (class, phase,
# window, live predicate), as Chrome routes every input through one RenderWidgetHostImpl/InputRouter
# (components/input/input_router_impl.cc) instead of per-feature hooks. A new NSEvent monitor, or a new raw
# event-observer closure on CmuxApplication, puts a per-event callback back beside the tap: it runs for every
# event of the process, outside the tap's order and window scope. Local only (prepush-gate runs the guardrails
# never under --commits or GitHub Actions; Lawrence 2026-10-23: no new CI gates). Base debt per file, as
# action-wait: editing a line that already holds a monitor adds none.
# The block owns its lines from here to `RULES += INPUT_RULES`.
INPUT_TAP_MODULE = SOURCES + "CmuxNextInput/"  # the tap itself; its `globalObserve` wraps the global monitor
INPUT_MONITOR = re.compile(r"\badd(Local|Global)MonitorForEvents\b")
# A `var`/`let` whose declaration holds a closure type with an NSEvent parameter, anywhere after the name:
# `var x: ((NSEvent) -> Void)?`, `((_ event: NSEvent) -> Void)?`, `[UUID: (NSEvent) -> Void]`,
# `= [(NSEvent) -> Void]()`, `Optional<(NSEvent, () -> Void) -> Void>`. The `->` after the parameter list is what
# makes it a closure: a tuple such as `(NSEvent, Date)?` has none. One level of nested parentheses is read.
EVENT_PARAMETERS = r"(?:[^()]|\([^()]*\))*"
EVENT_CLOSURE = re.compile(r"\b(?:var|let)\s+\w+\b.*?\((?:" + EVENT_PARAMETERS + r",)?\s*(?:\w+\s+)?(?:\w+\s*:\s*)?"
                           r"(?:@\w+\s+)*(?:inout\s+)?NSEvent\b" + EVENT_PARAMETERS + r"\)\s*(?:async\s+)?"
                           r"(?:(?:re)?throws(?:\([^()]*\))?\s+)?->")
INPUT_MONITOR_LINE = re.compile(INPUT_MONITOR.pattern + "|" + EVENT_CLOSURE.pattern)
INPUT_MONITOR_ALLOW = re.compile(r"//\s*input-monitor-allow:\s*\S")
CMUX_APPLICATION_FILE = re.compile(r"(^|/)CmuxNextApp/CmuxApplication(\+\w+)?\.swift$")
INNERMOST_BLOCK = re.compile(r"\{")  # enclosing_openers stops at the first opener: the innermost block
CMUX_APPLICATION_SCOPE = re.compile(r"\b(class|extension)\s+CmuxApplication\b")


def input_monitor_debt(version: Version, index: int) -> tuple[bool, list[int]]:
    """Whether line INDEX is a monitor (anywhere) or an NSEvent closure member of CmuxApplication (its file, the
    innermost block a `class`/`extension CmuxApplication` body, not a local in a function), with the opener read."""
    code = code_of(version.lines[index])
    if INPUT_MONITOR.search(code):
        return True, []
    if not EVENT_CLOSURE.search(code) or not CMUX_APPLICATION_FILE.search(version.path):
        return False, []
    openers = enclosing_openers(version.lines, index, INNERMOST_BLOCK)
    if not openers:
        return False, []
    opener, number = openers[0]
    return bool(CMUX_APPLICATION_SCOPE.search(opener)), [number]


INPUT_MONITOR_MATCHER = Matcher(INPUT_MONITOR_LINE, INPUT_MONITOR_ALLOW, input_monitor_debt)


def input_monitor(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    return matcher_rule(INPUT_MONITOR_MATCHER)([c for c in changes if not c.path.startswith(INPUT_TAP_MODULE)], moved)


INPUT_RULES = (
    Rule("input-monitor", "A new NSEvent monitor (`addLocalMonitorForEvents` / `addGlobalMonitorForEvents`) outside "
         "CmuxNextInput, or a new raw event-observer closure on CmuxApplication",
         "a monitor runs for every event of the process beside the input tap: outside its declared order and window "
         "scope, unmeasured, and O(monitors) per key (33 monitors before the tap; plans/cmux-next/chrome-parity/"
         "p04-input.md (A), Chrome's one InputRouter per widget)",
         "subscribe through CmuxNextInput's `InputEventTap.subscribe(class:phase:window:while:handler:)` (phase "
         "`.observe`, `.intercept(order:)` or `.afterDispatch`; keep the token, it unsubscribes on deinit); core and "
         "service packages take an `InputObserving` and read `InputEventRecord`s; other apps' events go through the "
         "tap's `globalObserve`; never add a closure property to CmuxApplication, add a tap phase instead",
         "// input-monitor-allow: <why the tap cannot see this event (a nested tracking loop, a modal session)>",
         input_monitor),
)
RULES += INPUT_RULES
# ---------------------------------------------------------------- end of input-monitor (p04-input, PL-typing)


# ---------------------------------------------------------------- target-settings
# Every Swift target of the app's package closure carries the shared compile-time safety settings
# (plans/cmux-next/chrome-parity/p10-stability.md): `stabilitySwiftSettings`, directly or through a top-level
# settings constant that appends it (CmuxNext's uiSwiftSettings and daemonSwiftSettings). Chromium gets this from
# build/config/BUILDCONFIG.gn: every target starts from default_compiler_configs, and one that drops
# `//build/config/compiler:chromium_code` says so in its BUILD.gn. A new Swift target, or one that loses the
# settings, in a closure manifest (CmuxNext's Package.swift and every Packages/ manifest it reaches through
# `.package(path:)`) is refused. Judged per target name: a name the push's base already had without the settings, in
# any changed closure manifest (a move), is base debt. Local only (prepush-gate runs the guardrails never under
# --commits or GitHub Actions; Lawrence 2026-10-23: no new CI gates).
# The block owns its lines from here to `RULES += TARGET_SETTINGS_RULES`.
STABILITY_SETTINGS = "stabilitySwiftSettings"
PACKAGE_MANIFEST_SPEC = ":(glob)Packages/**/Package.swift"
SWIFT_TARGET_CALL = re.compile(r"\.(?:target|executableTarget|testTarget|macro)\s*\(")
TARGET_LITERAL_NAME = re.compile(r'^\s*name\s*:\s*"(_+)"\s*$')  # the first argument, string contents masked
DEPENDENCY_TYPE = re.compile(r"\bDependency\b")  # Target.Dependency, written in a declared type or as a prefix
ARGUMENT_LABEL = re.compile(r"^\s*(\w+)\s*:")
TOP_LEVEL_CONSTANT = re.compile(r"^(?:let|var)\s+(\w+)\b[^=]*=")
EXPRESSION_GOES_ON = frozenset("])}+.")  # a column-0 line starting with one of these continues the expression
IDENTIFIER = re.compile(r"\b[A-Za-z_]\w*\b")
SETTINGS_ALLOW = re.compile(r"//\s*settings-allow:\s*\S")


def is_package_manifest(path: str) -> bool:
    """PATH is in PACKAGE_MANIFEST_SPEC."""
    return path.startswith("Packages/") and path.endswith("/Package.swift")


@dataclass
class SwiftTarget:
    """One Swift target call of a manifest: its literal name, its first 0-based line, and whether it carries the
    shared settings or a `// settings-allow:` reason."""
    name: str
    first: int
    ok: bool


def balanced_end(codes: list[str], line: int, column: int) -> tuple[int, int] | None:
    """The (line, column) of the bracket closing the one at CODES[LINE][COLUMN], or None when the text ends first."""
    depth = 0
    for index in range(line, len(codes)):
        for position in range(column if index == line else 0, len(codes[index])):
            char = codes[index][position]
            if char in "([{":
                depth += 1
            elif char in ")]}":
                depth -= 1
                if depth == 0:
                    return index, position
    return None


def top_level_split(text: str) -> list[str]:
    """TEXT split at its commas outside any bracket."""
    parts, depth, start = [], 0, 0
    for position, char in enumerate(text):
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            parts.append(text[start:position])
            start = position + 1
    parts.append(text[start:])
    return parts


def settings_carriers(codes: list[str]) -> set[str]:
    """STABILITY_SETTINGS and the top-level constants whose expression names it, directly or through another one."""
    expressions: dict[str, str] = {}
    for index, code in enumerate(codes):
        declared = TOP_LEVEL_CONSTANT.match(code)
        if not declared:
            continue
        body = [code[declared.end():]]
        for following in codes[index + 1:]:
            if following.strip() and not following[0].isspace() and following[0] not in EXPRESSION_GOES_ON:
                break
            body.append(following)
        expressions[declared.group(1)] = " ".join(body)
    carriers = {STABILITY_SETTINGS}
    grew = True
    while grew:
        grew = False
        for name, expression in expressions.items():
            if name not in carriers and carriers & set(IDENTIFIER.findall(expression)):
                carriers.add(name)
                grew = True
    return carriers


def masked_code(line: str) -> str:
    """LINE without a trailing `//` comment, its string contents replaced by `_` of the same length: a column of the
    result is the same column of LINE."""
    if COMMENT_LINE.match(line):
        return ""
    out, in_string, i = [], False, 0
    while i < len(line):
        c = line[i]
        if in_string:
            step = 2 if c == "\\" else 1
            if c == '"':
                in_string = False
                out.append(c)
            else:
                out.append("_" * len(line[i:i + step]))
            i += step
            continue
        if c == '"':
            in_string = True
        elif line.startswith("//", i):
            break
        out.append(c)
        i += 1
    return "".join(out)


def declares_dependencies(codes: list[str], index: int) -> bool:
    """The top-level statement holding line INDEX declares Target.Dependency values (`let deps: [Target.Dependency]
    = ...`, `func deps() -> [Target.Dependency] {`): its text before the first `=` or `{` names the type."""
    start = index
    while start > 0 and not (codes[start].strip() and not codes[start][0].isspace()
                             and codes[start][0] not in EXPRESSION_GOES_ON and codes[start][0] != "#"):
        start -= 1
    header = re.split(r"[={]", "\n".join(codes[start:index + 1]), maxsplit=1)[0]
    return bool(DEPENDENCY_TYPE.search(header))


def swift_targets(text: str) -> list[SwiftTarget]:
    """The Swift target calls of manifest TEXT whose first argument is a literal `name:`, outermost only (a
    `.target(name:)` dependency inside another target is not one). A Target.Dependency is not a target either: a
    call with a `condition:` argument (a target takes none), one written `Target.Dependency.target(`, and one in a
    top-level statement declared as Target.Dependency values."""
    lines = text.split("\n")
    codes = [masked_code(line) for line in lines]
    raw = [line[:len(code)] for line, code in zip(lines, codes)]  # the same columns as CODES, strings kept
    carriers = settings_carriers(codes)
    targets: list[SwiftTarget] = []
    after = (-1, -1)
    for index, code in enumerate(codes):
        for call in SWIFT_TARGET_CALL.finditer(code):
            opener = call.end() - 1
            if (index, opener) <= after:
                continue
            end = balanced_end(codes, index, opener)
            if end is None:
                return targets
            after = end
            last, close = end
            code_text = "\n".join(codes[index:last + 1])
            arguments_end = len(code_text) - len(codes[last]) + close
            parts = top_level_split(code_text[opener + 1:arguments_end])
            labelled = {m.group(1): part[m.end():] for part in parts if (m := ARGUMENT_LABEL.match(part))}
            named = TARGET_LITERAL_NAME.match(parts[0])
            if (not named or "condition" in labelled or code[:call.start()].rstrip().endswith("Dependency")
                    or declares_dependencies(codes, index)):
                continue
            name_start = opener + 1 + named.start(1)
            name = "\n".join(raw[index:last + 1])[name_start:name_start + len(named.group(1))]
            shared = bool(carriers & set(IDENTIFIER.findall(labelled.get("swiftSettings", ""))))
            allowed = any(SETTINGS_ALLOW.search(lines[j])
                          for j in set(escape_window(lines, index)) | set(range(index, last + 1)))
            targets.append(SwiftTarget(name, index, shared or allowed))
    return targets


def closure_manifests(context: "WakeupContext") -> set[str]:
    """CmuxNext's Package.swift and every Packages/ manifest it reaches through `.package(path:)` at the head."""
    found = {MANIFEST}
    texts = {MANIFEST: context.manifests[context.head]}
    frontier = [MANIFEST]
    while frontier:
        links = []
        for manifest in frontier:
            folder = posixpath.dirname(manifest)
            for link in PACKAGE_PATH.finditer(texts.get(manifest, "")):
                linked = posixpath.join(posixpath.normpath(posixpath.join(folder, link.group(1))), "Package.swift")
                if is_package_manifest(linked) and linked not in found:
                    found.add(linked)
                    links.append(linked)
        read = blobs(context.repo, [(context.head, path) for path in links])
        texts.update({path: text for (_, path), text in read.items()})
        frontier = links
    return found


def target_settings(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    manifests = [c for c in changes if is_package_manifest(c.path)]
    if not manifests:
        return []
    only_app = all(c.path == MANIFEST for c in manifests)
    closure = {MANIFEST} if only_app else closure_manifests(manifests[0].memo["wakeup"])
    judged = [c for c in manifests if c.path in closure]
    base_ok: dict[str, bool] = {}
    for change in judged:
        for target in swift_targets("\n".join(change.base_lines)):
            base_ok[target.name] = base_ok.get(target.name, False) or target.ok
    hits = []
    for change in judged:
        for target in swift_targets("\n".join(change.head_lines)):
            if not target.ok and base_ok.get(target.name, True):
                hits.append(Added(change.path, target.first + 1, change.head_lines[target.first]))
    return hits


TARGET_SETTINGS_RULES = (
    Rule("target-settings", "A new Swift target, or one that loses the settings, in a Package.swift of the app's "
         f"package closure without `{STABILITY_SETTINGS}`",
         "the compile-time safety flips (strict memory safety, then its group as an error; p10-stability-079/211) land "
         f"once in `{STABILITY_SETTINGS}` and reach a target only through it: a target without it builds unchecked "
         "and the closure's count never reaches 0 (Chromium: every target starts from BUILDCONFIG.gn's "
         "default_compiler_configs)",
         f"pass `swiftSettings: uiSwiftSettings` or `daemonSwiftSettings` (both append `{STABILITY_SETTINGS}`), or "
         f"`... + {STABILITY_SETTINGS}`; a Shared or iOS manifest declares `let {STABILITY_SETTINGS}: [SwiftSetting] "
         "= []` once (the settings lander, scripts/cmux-next/stability-settings.json, fills it) and appends it",
         "// settings-allow: <why this target cannot take the settings (no Swift sources, generated code)>",
         target_settings,
         scope=("/Package.swift",)),
)
RULES += TARGET_SETTINGS_RULES
# ---------------------------------------------------------------- end of target-settings


# ---------------------------------------------------------------- safety-todo
# `// SAFETY-TODO(p10)` marks an old unsafe site that the strict-memory-safety pass (apply-unsafe-fixits.py) found
# when the check went on; the marks are the Q04 queue that module tasks 063-078 empty. Chromium's order
# (docs/unsafe_buffers.md): UNSAFE_TODO() wraps only code that predates the check, and new code writes
# UNSAFE_BUFFERS() with a `// SAFETY:` argument. So a mark the push adds is refused unless it sits where the pass
# puts one: directly above a statement (the line below it, or every line of the multi-line string that line opens)
# holding a changed line that is a removed line of the same hunk with only `unsafe ` / `@unsafe ` inserted. A mark
# the push removes pays only for an added mark over the same code (a moved or re-indented site); a fixed or deleted
# site never pays for a mark on new code. Local only (prepush-gate runs the guardrails never under --commits or
# GitHub Actions; Lawrence 2026-10-23: no new CI gates). The block owns its lines from here to
# `RULES += SAFETY_TODO_RULES`.
SAFETY_TODO_MARK = re.compile(r"//\s*SAFETY-TODO\(p10\)")
UNSAFE_INSERTIONS = ("unsafe ", "@unsafe ")  # apply-unsafe-fixits.py INSERTION
INSERTION_AFTER_WORD = re.compile(r"[A-Za-z0-9_]")  # apply-unsafe-fixits.py WORD: never inside a word
PACKAGE_SWIFT_SPECS = (":(glob)Packages/**/Sources/**/*.swift", ":(glob)Packages/**/Tests/**/*.swift")


def is_package_swift(path: str) -> bool:
    """PATH is in PACKAGE_SWIFT_SPECS: a Swift file of any package's Sources or Tests."""
    return path.startswith("Packages/") and path.endswith(".swift") and ("/Sources/" in path or "/Tests/" in path)


def squashed(text: str) -> str:
    return " ".join(text.split())


def gained_only_unsafe(old: str, new: str) -> bool:
    """NEW is OLD (whitespace squashed on both) with at least one `unsafe ` / `@unsafe ` inserted at a point with no
    word character before it: the fix-it pass's edit, matched by characters, so `print(unsafe "\\(p)")`,
    `\\(unsafe p)` in a string and `#expect(unsafe p == 3)` count like `return unsafe p`."""
    old, new = squashed(old), squashed(new)
    if old == new:
        return False
    seen = {(0, 0)}
    todo = [(0, 0)]
    while todo:
        i, j = todo.pop()
        if i == len(old) and j == len(new):
            return True
        steps = [(i + 1, j + 1)] if i < len(old) and j < len(new) and old[i] == new[j] else []
        if j == 0 or not INSERTION_AFTER_WORD.match(new[j - 1]):
            steps += [(i, j + len(word)) for word in UNSAFE_INSERTIONS if new.startswith(word, j)]
        for step in steps:
            if step not in seen:
                seen.add(step)
                todo.append(step)
    return False


def marked_statement(lines: list[str], index: int) -> range:
    """The 0-based lines a mark at LINES[INDEX] covers: the line below it and, when that line opens a multi-line
    string (an odd number of `\"\"\"`), every line through the one that closes it. apply-unsafe-fixits.py marks the
    line that opens the literal when the site is inside one."""
    start = end = index + 1
    if start < len(lines):
        end = start + 1
        if lines[start].count('"""') % 2:
            while end < len(lines) and lines[end].count('"""') % 2 == 0:
                end += 1
            end = min(end + 1, len(lines))
    return range(start, end)


def hunk_keys(numbers: list[int]) -> Callable[[int], int]:
    """Per changed line number of one side, the count of unchanged lines before it: a removed and an added line
    are in the same hunk exactly when their counts agree (both sides share the unchanged lines, in order)."""
    ordered = sorted(numbers)
    return lambda number: number - 1 - bisect.bisect_left(ordered, number)


def safety_todo(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    changes = [c for c in changes if is_package_swift(c.path)]
    # A removed mark, keyed by the code line under it: it pays for an added mark over the same code.
    moved_marks: collections.Counter = collections.Counter()
    for change in changes:
        for removed in change.removed:
            if SAFETY_TODO_MARK.search(removed.text):
                below = marked_statement(change.base_lines, removed.number - 1)
                moved_marks[squashed(change.base_lines[below.start]) if below else ""] += 1
    unpaid: list[tuple[FileChange, Added]] = []
    for change in changes:
        marks = [a for a in change.added if SAFETY_TODO_MARK.search(a.text)]
        if not marks:
            continue
        base_key = hunk_keys([r.number for r in change.removed])
        head_key = hunk_keys([a.number for a in change.added])
        old: dict[int, list[Added]] = collections.defaultdict(list)
        for removed in change.removed:
            if not SAFETY_TODO_MARK.search(removed.text):
                old[base_key(removed.number)].append(removed)
        added = {a.number - 1: a for a in change.added if not SAFETY_TODO_MARK.search(a.text)}
        for mark in marks:
            paid = False
            for index in marked_statement(change.head_lines, mark.number - 1):
                line = added.get(index)
                pool = old[head_key(line.number)] if line else []
                match = next((r for r in pool if gained_only_unsafe(r.text, line.text)), None)
                if match is not None:
                    pool.remove(match)
                    del added[index]
                    paid = True
                    break
            if not paid:
                unpaid.append((change, mark))
    hits: list[Added] = []
    for change, mark in unpaid:
        below = marked_statement(change.head_lines, mark.number - 1)
        key = squashed(change.head_lines[below.start]) if below else ""
        if moved_marks[key] > 0:
            moved_marks[key] -= 1
        else:
            hits.append(mark)
    return hits


SAFETY_TODO_RULES = (
    Rule("safety-todo", "A new `// SAFETY-TODO(p10)` mark on code that is not an old line marked by the "
         "strict-memory-safety pass",
         "the marks are the queue of old unsafe sites (Q04, p10-stability-211); a mark on new code adds to the queue "
         "instead of stating why the code is safe (Chromium: UNSAFE_TODO only for code that predates the check, "
         "docs/unsafe_buffers.md)",
         "use a safe API (Span, Array, Data, a typed wrapper), or write `unsafe` with a `// SAFETY: <why the "
         "pointer, bounds and lifetime are valid>` line above it; old sites get their marks only from "
         "scripts/cmux-next/apply-unsafe-fixits.py",
         None,
         safety_todo,
         scope=("Packages/",)),
)
RULES += SAFETY_TODO_RULES
# ---------------------------------------------------------------- end of safety-todo


# ---------------------------------------------------------------- main-thread classes (p06-scheduler)
# Main-thread work has a class and an owner, and hidden things do no view work
# (plans/cmux-next/chrome-parity/p06-scheduler.md, section F). Chrome posts every UI-thread task to a typed queue
# (content/browser/scheduler/browser_task_queues.h: BrowserTaskType and its priority), tells hidden pages so
# (content/public/browser/visibility.h, WebContentsImpl::UpdateWebContentsVisibility), aligns timers
# (base/task/delay_policy.h: kFlexibleNoSooner) and registers observers on their owner (base/observer_list.h).
# Six line rules judge what a push adds, per file as a count ratchet like main-async: an edit of a line that
# already has the debt adds none. Local only, never CI (Lawrence 2026-10-23). CmuxNextWakeups holds the
# primitives that implement the classes and is not judged. Each concern has one owner, so these rules do not
# repeat: `DispatchQueue.main.async` (main-async), a sleep without `// wakeup-allow:` (check-concurrency.sh's
# wakeup rule) and a monitor outside CmuxNextInput (input-monitor).
# The block owns its lines from here to `RULES += MAIN_CLASS_RULES`.
WAKEUPS = SOURCES + "CmuxNextWakeups/"
main_actor_work = swift_scope.main_actor_scope  # check-main-actor-work.py: the main-actor scopes and Task predicate
RAW_MAIN_HOP = re.compile(r"\bMainActor\.run\b|\bCFRunLoopPerformBlock\(|\bRunLoop\.main\.perform\b")
MAIN_DELIVERY = re.compile(r"\bMainDelivery\(")


def prefilter(*patterns: re.Pattern) -> re.Pattern:
    """PATTERNS joined, each alternative without its leading `\\b` (so a superset): a rule with a context reads every
    line of a changed file, and a leading `\\b` costs re its literal-prefix scan (5x slower); the rule's own check
    holds the exact patterns."""
    return re.compile("|".join(piece.removeprefix(r"\b") for p in patterns for piece in p.pattern.split("|")))


MAIN_HOP_LINE = prefilter(main_actor_work.TASK_START, RAW_MAIN_HOP, MAIN_DELIVERY)
ARGUMENT_LABEL = re.compile(r"\s*(\w+)\s*:(?!:)")
CALL_LINES = 40  # the lines one call's arguments are read across (`MainDelivery(\n    owner: ...,\n    class: ...`)
# `ObservationStream({`, its trailing-closure form and `.current({`; not `extension ObservationStream {`.
VIEW_OBSERVATION = re.compile(r"(?<!extension )\bObservationStream(\s*[({]|\.current\()|\bwithObservationTracking\b")
HIDDEN_WALK = re.compile(r"\bisHiddenOrHasHiddenAncestor\b")
HIDE_OVERRIDE = re.compile(r"\boverride\s+func\s+viewDid(Hide|Unhide)\b")
# The one body a hide override may have (recipe R-hide): call its own super and tell the view's VisibilityNode its
# own direction (`viewDidHide` -> `.hidden`, `viewDidUnhide` -> `.visible`).
HIDE_FORWARD = {
    direction: re.compile(r"^\s*(super\.viewDid" + direction + r"\(\)|(self\.)?\w*[nN]ode\??\.set\(\." + state
                          + r"\))\s*$")
    for direction, state in (("Hide", "hidden"), ("Unhide", "visible"))
}
BODY_LINES = 40  # the lines a hide override's body is read across
DEMAND_TIMER = re.compile(r"\bDemandTimer\(")
SLEEP = re.compile(r"\bTask\.sleep\(|\.sleep\((for|until):")
WAKEUP_ALLOWED = re.compile(r"//\s*wakeup-allow:\s*\S")
LOOP_OPENER = re.compile(r"^\s*(\}\s*)?(while|for|repeat)\b")
BRANCH_OPENER = re.compile(r"^\s*(\}\s*)?(if|else|guard|switch|case|default|do|catch|defer)\b|^\s*\{$")
SCOPE_STOP = re.compile(r"\b(func|init|deinit|subscript|class|struct|enum|actor|extension|protocol)\b")
RAW_OBSERVER = re.compile(r"\baddObserver\(|\b(NSWindow|NSApplication)\.(did|will)[A-Za-z]+Notification\b"
                          r"|\bNSWorkspace\.shared\.notificationCenter\b|\bnotifications\(named:"
                          r"|\bDistributedNotificationCenter\b|\.observe\(\\\.|\bNSView\.(frame|bounds)DidChangeNotification\b"
                          r"|\bdidUpdateNotification\b")  # queue Q4 of p06-scheduler.md section 6
# R-notif's target: a notice name passed straight to a WindowEvents or AppEvents `subscribe(` (one observer per window
# or app per name, fanned out by the subscriber's node). The name still matches RAW_OBSERVER; the subscription is not
# a raw observer.
SUBSCRIBED_NOTICE = re.compile(r"\bsubscribe\(\s*(?:NSWindow|NSApplication)\.(?:did|will)[A-Za-z]+Notification\b")
TAP_FILE = re.compile(r"^" + re.escape(INPUT_TAP_MODULE) + r"InputEventTap(\+\w+)?\.swift$")


def allow_marker(rule: str) -> re.Pattern:
    return re.compile(r"//\s*" + re.escape(rule) + r"-allow:\s*\S")


# {id(side's lines): (those lines, the side's memo in its FileChange)}: matcher_rule makes a new Version per rule, so
# main-hop and timer-class share one isolation reading per side through the FileChange (scoped_to registers it).
SIDE_MEMO: dict[int, tuple[list[str], dict]] = {}


def side_memo(version: Version) -> dict:
    entry = SIDE_MEMO.get(id(version.lines))
    return entry[1] if entry is not None and entry[0] is version.lines else version.memo


def isolation(version: Version) -> list[tuple[bool, int]]:
    """Each line of VERSION: (main-actor code, the 1-based line that made it so; 0: its target's default)."""
    memo = side_memo(version)
    if "isolation" not in memo:
        ui_type = version.types.ui_type if version.types is not None else main_actor_work.no_ui_type
        memo["isolation"] = main_actor_work.main_actor_scopes(version.lines, version.main_default, ui_types=True,
                                                              ui_type=ui_type)
    return memo["isolation"]


def main_tasks(version: Version) -> dict[int, int]:
    """{0-based line: the 1-based line that set its isolation} of VERSION's Tasks that run on the main actor."""
    memo = side_memo(version)
    if "main_tasks" not in memo:
        memo["main_tasks"] = dict(main_actor_work.main_inherited_tasks(version.lines, version.main_default,
                                                                       isolation(version)))
    return memo["main_tasks"]


def call_labels(lines: list[str], index: int, call: re.Pattern) -> tuple[set[str] | None, list[int]]:
    """(the labels of the arguments of CALL on LINES[INDEX], read to its matching `)`, None when that `)` does not
    come within CALL_LINES lines; the 1-based lines after INDEX it read). A label inside a nested call, closure or
    collection (`MainDelivery(owner: f(class: 1))`) is not the call's own."""
    text = "\n".join(code_of(line) for line in lines[index:index + CALL_LINES])
    start = call.search(text).end()
    depth, labels, argument = 1, set(), start
    for i in range(start, len(text)):
        c = text[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if depth == 0 or (c == "," and depth == 1):
            if label := ARGUMENT_LABEL.match(text, argument, i):
                labels.add(label.group(1))
            argument = i + 1
            if depth == 0:
                return labels, list(range(index + 2, index + 2 + text.count("\n", 0, i)))
    return None, list(range(index + 2, index + 1 + min(CALL_LINES, len(lines) - index)))


def main_hop_debt(version: Version, index: int) -> tuple[bool, list[int]]:
    """A raw main hop, a MainDelivery without a class, or a Task that runs on the main actor (the shared predicate:
    annotated, or plain in main-actor code, so deleting `@MainActor in` keeps the debt). A MainDelivery whose
    arguments do not close within CALL_LINES lines is not judged."""
    code = code_of(version.lines[index])
    if RAW_MAIN_HOP.search(code):
        return True, []
    if MAIN_DELIVERY.search(code):
        labels, read = call_labels(version.lines, index, MAIN_DELIVERY)
        if labels is not None and "class" not in labels:
            return True, read
    main_task = main_tasks(version).get(index)
    source = main_task if main_task is not None else isolation(version)[index][1]
    return main_task is not None, [source] if source else []


def block_body(lines: list[str], index: int) -> tuple[str, int] | None:
    """(the code inside the first block that opens on LINES[INDEX], the 0-based line that closes it), or None when it
    does not close within BODY_LINES."""
    depth, body = 0, []
    for j in range(index, min(len(lines), index + BODY_LINES)):
        for c in code_of(lines[j]):
            if c == "{":
                depth += 1
                if depth == 1:
                    continue
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return "".join(body), j
            if depth > 0:
                body.append(c)
        if depth > 0:
            body.append("\n")
    return None


def visibility_walk_debt(version: Version, index: int) -> tuple[bool, list[int]]:
    """An ancestor walk, or a hide override whose body does more than forward to the view's VisibilityNode (its body
    lines are the context: an edit there re-judges it)."""
    code = code_of(version.lines[index])
    if HIDDEN_WALK.search(code):
        return True, []
    override = HIDE_OVERRIDE.search(code)
    if override is None:
        return False, []
    body = block_body(version.lines, index)
    if body is None:
        return True, []
    text, end = body
    forward = HIDE_FORWARD[override.group(1)]
    forwards = all(forward.match(s) for s in re.split(r"[\n;]", text) if s.strip())
    return not forwards, list(range(index + 2, end + 2))


def timer_class_debt(version: Version, index: int) -> tuple[bool, list[int]]:
    """A DemandTimer made in main-actor code, or a sleep in a loop that check-concurrency.sh lets through (its
    `// wakeup-allow:`): a periodic timer with no class or alignment."""
    lines = version.lines
    code = code_of(lines[index])
    if DEMAND_TIMER.search(code):
        main, source = isolation(version)[index]
        return main, [source] if source else []
    match = SLEEP.search(code)
    window = escape_window(lines, index)
    context = [j + 1 for j in window]
    if match is None or not any(WAKEUP_ALLOWED.search(lines[j]) for j in window):
        return False, context  # an unescaped sleep is check-concurrency.sh's refusal, not this rule's
    for opener, number in enclosing_openers(lines, index, SCOPE_STOP, code[:match.start()]):
        if LOOP_OPENER.search(opener):
            return True, context + [number]
        if not BRANCH_OPENER.search(opener):
            break  # a closure or a declaration: the loop around it does not repeat this sleep
    return False, context


def raw_observer_in(code: str) -> bool:
    """Whether CODE (a line with comments dropped) holds a raw observer: a RAW_OBSERVER match other than a notice name
    passed straight to a WindowEvents or AppEvents `subscribe(` (SUBSCRIBED_NOTICE, recipe R-notif's target).
    p06_queue.py judges its Q4 hits with this too."""
    return RAW_OBSERVER.search(SUBSCRIBED_NOTICE.sub("subscribe(", code)) is not None


def raw_observer_debt(version: Version, index: int) -> tuple[bool, list[int]]:
    """A raw observer on VERSION's line INDEX; a WindowEvents or AppEvents subscription to a named notice is not one."""
    return raw_observer_in(code_of(version.lines[index])), []


def scoped_to(matcher: Matcher, keep_file: Callable[[str], bool]):
    """matcher_rule(MATCHER) over the changed files KEEP_FILE accepts, each side's facts shared through SIDE_MEMO."""
    def find(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
        kept = [c for c in changes if keep_file(c.path)]
        if len(SIDE_MEMO) > 4096:  # one push holds a few hundred sides; a long-lived caller (the tests) many pushes
            SIDE_MEMO.clear()
        for change in kept:
            for side, lines in (("head", change.head_lines), ("base", change.base_lines)):
                SIDE_MEMO[id(lines)] = (lines, change.memo.setdefault(f"main-thread classes {side}", {}))
        return matcher_rule(matcher)(kept, moved)
    return find


MAIN_CLASS_RULES = (
    Rule("main-hop", "A main-thread hop without a class: a `Task` that runs on the main actor (`Task { @MainActor in`, "
         "or a plain `Task {` in main-actor code), `MainActor.run`, `CFRunLoopPerformBlock`, `RunLoop.main.perform` or "
         "a `MainDelivery(` with no `class:`",
         "an unclassed hop is a FIFO main-queue job: the scheduler cannot put the person's input first or keep "
         "automation and hidden work out of the frame (p06-scheduler.md rule 1; Chrome posts every UI-thread task "
         "with a BrowserTaskType, content/browser/scheduler/browser_task_queues.h). Deleting `@MainActor in` does "
         "not remove the hop: the Task still inherits the main actor",
         R_HOP,
         "// main-hop-allow: <the AppKit order that needs this hop (focus, menu tracking)>",
         scoped_to(Matcher(MAIN_HOP_LINE, allow_marker("main-hop"), main_hop_debt),
                   lambda path: not path.startswith((WAKEUPS, SOURCES + "CmuxNextCompat/MainRunLoopBlock.swift")))),
    Rule("view-observation", "A raw observation: `ObservationStream(` or `withObservationTracking`",
         "it re-arms on every change whether or not anything shows the value, with no class or owner: hidden "
         "workspaces keep doing view work and one O(all) closure per row runs per change (p06-scheduler.md F5)",
         "recipe R-obs: `VisibleObservation(node, owner:, on:)` when the apply touches views (it tracks only while "
         "the node is visible), `ServiceObservation(class, owner, read, apply)` for anything else (model, daemon, "
         "disk); waits use StoreWaiters or PageWaiters",
         "// view-observation-allow: <why neither VisibleObservation nor ServiceObservation fits>",
         scoped_to(Matcher(VIEW_OBSERVATION, allow_marker("view-observation")),
                   lambda path: not path.startswith((WAKEUPS, SOURCES + "CmuxNextCompat/ObservationStream.swift")))),
    Rule("visibility-walk", "An ad hoc visibility test: `isHiddenOrHasHiddenAncestor`, or a `viewDidHide`/"
         "`viewDidUnhide` override that does more than forward to its VisibilityNode",
         "an ancestor walk per call, and a per-view hidden flag the scheduler cannot see: hidden work is not held, "
         "and on show it runs out of order (p06-scheduler.md rule 4; Chrome keeps one visibility per WebContents, "
         "content/public/browser/visibility.h)",
         "recipe R-vis: read `node.isVisible` and defer with `node.deferUntilVisible(key:)`; recipe R-hide: a hide "
         "override only calls super and `node.set(.hidden)` / `node.set(.visible)`",
         "// visibility-walk-allow: <the hit test or accessibility read that needs the walk>",
         scoped_to(Matcher(prefilter(HIDDEN_WALK, HIDE_OVERRIDE), allow_marker("visibility-walk"),
                           visibility_walk_debt), lambda path: not path.startswith(WAKEUPS))),
    Rule("timer-class", "A timer with no class: a `DemandTimer(` in main-actor code, or a `Task.sleep` / "
         "`clock.sleep` loop (a sleep in a loop with `// wakeup-allow:`)",
         "a main-thread deadline without a class fires in FIFO order beside the person's input, and an unaligned "
         "periodic sleep wakes the process on its own schedule while hidden (p06-scheduler.md section E; Chrome "
         "aligns delayed tasks, base/task/delay_policy.h, and throttles hidden ones, "
         "third_party/blink/renderer/platform/scheduler/common/throttling/cpu_time_budget_pool.cc)",
         "recipe R-timer: an event first (idle-wakeups.md); else `MainDeadline(owner:, workClass:, alignment:, "
         "scheduler:)` on main (`.flexible` by default, `.precise` only under 36 ms); a race timeout uses the "
         "`Deadline` helper; DemandTimer stays for off-main deadlines",
         "// timer-class-allow: <why this deadline needs no class or alignment>",
         scoped_to(Matcher(prefilter(DEMAND_TIMER, SLEEP), allow_marker("timer-class"),
                           timer_class_debt), lambda path: not path.startswith(WAKEUPS))),
    Rule("raw-observer", "A raw notification or KVO observer (queue Q4: `addObserver(`, NSWindow/NSApplication "
         "notices, the NSWorkspace center, `notifications(named:)`, DistributedNotificationCenter, `.observe(\\.`, "
         "NSView frame/bounds notices, `didUpdateNotification`)",
         "each observer runs for every post, visible or not, in no class: N views x every window notice "
         "(p06-scheduler.md F5; Chrome observers register on their owner, base/observer_list.h)",
         "recipe R-notif: subscribe through WindowEvents or AppEvents with a node (one observer per window or app "
         "per notice, fan-out to visible subscribers); a frame or bounds notice becomes the view's own `layout()` / "
         "`setFrameSize`; KVO on WebKit takes the tab's node",
         "// raw-observer-allow: <why no WindowEvents or AppEvents notice fits>",
         scoped_to(Matcher(RAW_OBSERVER, allow_marker("raw-observer"), raw_observer_debt),
                   lambda path: not path.startswith(WAKEUPS))),
    Rule("local-monitor", "A second NSEvent monitor inside CmuxNextInput, outside the input tap (InputEventTap)",
         "the tap is the one monitor of the process (p06-scheduler.md Q8 target: 1); input-monitor refuses "
         "monitors outside CmuxNextInput, and a module-local one beside the tap runs for every event outside its "
         "order (Chrome's one InputRouter per widget, components/input/input_router_impl.cc)",
         "recipe R-monitor: add a phase or a subscription to `InputEventTap`; a session monitor is subscribed only "
         "while its session is active",
         "// local-monitor-allow: <why the tap cannot see this event>",
         scoped_to(Matcher(INPUT_MONITOR, allow_marker("local-monitor")),
                   lambda path: path.startswith(INPUT_TAP_MODULE) and not TAP_FILE.match(path))),
)
RULES += MAIN_CLASS_RULES
# ---------------------------------------------------------------- end of main-thread classes (p06-scheduler)


# ---------------------------------------------------------------- main-wakeup-owner (sequence-manager S1)
# The main thread has one wake-up timer: the `MainWakeUpQueue` `main()` makes (CmuxNextApp.swift), which the
# scheduler (`MainWorkScheduler.wakeUps`, LaunchOrder.swift) and the app's one `MainDeadlineScheduler`
# (AppServices.swift) share. A new `MainWakeUpQueue(`, `MainDeadlineScheduler(` or `MainWorkScheduler(` (its fixture
# init makes a queue of its own) anywhere else in Sources is a second timer, or a deadline placer whose wakes and
# next fire the idle periods cannot see (plans/cmux-next/sequence-manager-DESIGN.md F1, F2, S1;
# Chrome's one `WakeUpQueue` per thread, base/task/sequence_manager/wake_up_queue.h). Allowed, a closed list: the
# composition root, the Wakeups module that defines both, and the *TestSupport targets (tests are not read). No
# escape comment. Added lines only, base debt per file as the other line rules (today's sites in owners' test
# inits are debt that S3 and S4 remove). Local only, never CI.
# The block owns its lines from here to `RULES += MAIN_WAKEUP_OWNER_RULES`.
MAIN_WAKEUP_OWNER = re.compile(r"\b(?:MainWakeUpQueue|MainDeadlineScheduler|MainWorkScheduler)\(|\bMainWorkScheduler\.testing\b")
MAIN_WAKEUP_OWNER_FILES = (SOURCES + "CmuxNextApp/CmuxNextApp.swift", SOURCES + "CmuxNextApp/AppServices.swift",
                           SOURCES + "CmuxNextLaunch/LaunchOrder.swift")


def main_wakeup_owner_judged(path: str) -> bool:
    """PATH may not make a wake-up queue or a deadline placer: Sources outside the closed list."""
    module = path[len(SOURCES):].split("/", 1)[0] if path.startswith(SOURCES) else ""
    return not (path in MAIN_WAKEUP_OWNER_FILES or path.startswith(WAKEUPS) or module.endswith("TestSupport"))


MAIN_WAKEUP_OWNER_RULES = (
    Rule("main-wakeup-owner", "A `MainWakeUpQueue(`, `MainDeadlineScheduler(` or `MainWorkScheduler(` outside the "
         "composition root (CmuxNextApp.swift, AppServices.swift, LaunchOrder.swift), CmuxNextWakeups and the "
         "TestSupport targets",
         "the main thread has one wake-up timer and one deadline placer on it; another one is a second timer whose "
         "wakes do not coalesce with the app's and whose next fire no idle period ends before "
         "(sequence-manager-DESIGN.md F1, F2)",
         "take the app's in the owner's init: `AppServices.mainWork`, its `wakeUps`, or `AppServices.mainDeadlines` (a "
         "`MainDeadlineScheduler` you are handed has `wakeUpQueue` and `work`); a test passes "
         "`MainDeadlineScheduler.testing()` (CmuxNextWakeupsTestSupport) or a rig's queue",
         None,
         scoped_to(Matcher(MAIN_WAKEUP_OWNER, None), main_wakeup_owner_judged)),
)
RULES += MAIN_WAKEUP_OWNER_RULES
# ---------------------------------------------------------------- end of main-wakeup-owner (sequence-manager S1)


# ---------------------------------------------------------------- raw-continuation
# A raw `with(Checked|Unsafe)(Throwing)?Continuation` traps on a second resume and leaks its task when the producer
# drops it; CmuxSafeConcurrency's OnceContinuation resumes exactly once (a second resume is a no-op and a fault, a
# drop throws `.abandoned`, cancellation only with `.cancellable`), as Chromium's base::OnceCallback runs once and
# is safe to destroy unrun. The class and its scope are crash_ratchet.py's report-only `raw_continuation` (one
# definition; `--report raw_continuation` prints the queue Q06 that tasks 084-089 emptied). The class is banned
# (089), as crash_ratchet.py bans a class at zero: every raw continuation in a file the push changes is refused,
# old lines and moved ones too, not only the lines it adds. Local only, like every guardrail. The block owns its
# lines from here to `RULES += RAW_CONTINUATION_RULES`.
RAW_CONTINUATION = Matcher(ratchet.REPORT_SWIFT["raw_continuation"], allow_marker("raw-continuation"),
                           code=ratchet_code)


def raw_continuation(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """Every raw continuation left in a package Sources file the push changed (added or removed a line in),
    outside the package that implements OnceContinuation. Unchanged context files are not judged."""
    hits = []
    for change in changes:
        if (not change.path.endswith(".swift") or "/Sources/" not in change.path or change.is_deleted
                or ratchet.report_owned("raw_continuation", change.path) or not (change.added or change.removed)):
            continue
        lines = change.head_lines
        hits += [Added(change.path, index + 1, line) for index, line in enumerate(lines)
                 if RAW_CONTINUATION.pattern.search(RAW_CONTINUATION.code(line))
                 and not escaped_in(lines, index, RAW_CONTINUATION)]
    return hits


RAW_CONTINUATION_RULES = (
    Rule("raw-continuation", "A raw continuation (`withCheckedContinuation`, `withCheckedThrowingContinuation`, "
         "`withUnsafeContinuation`, `withUnsafeThrowingContinuation`) in a package Sources file the push changes "
         "(banned: old lines count too)",
         "a second resume stops the process and a dropped continuation hangs its task for ever; the twelve private "
         "resume-once helpers each fixed one site (p10-stability.md, CONTINUATIONS)",
         "CmuxSafeConcurrency's `withOnceContinuation { once in ... }` (or `withOnceThrowingContinuation`, or "
         "`withOnceContinuation(failingWith:)` for a typed error): resume exactly once, a drop throws "
         "`OnceContinuationError.abandoned`; pass `cancellation: .cancellable` (throwing or typed form only; "
         "the throwing form throws CancellationError) only where the producer's work is cancelled too",
         "// raw-continuation-allow: <why OnceContinuation cannot serve this site>",
         raw_continuation,
         scope=("Packages/",)),
)
RULES += RAW_CONTINUATION_RULES
# ---------------------------------------------------------------- end of raw-continuation


# ---------------------------------------------------------------- invariant-site
# Invariant.check traps in every build (Chromium's CHECK) and Invariant.dumpWillBeCheck reports for ever
# (DUMP_WILL_BE_CHECK; base/check.h, docs/checks.md): each site is a reviewed decision, as Chromium reviews each new
# CHECK. The classes are crash_ratchet.py's report-only invariant_check and dump_will_be_check (one definition); CI's
# crash ratchet neither counts nor bans them (p10-stability.md rule 1). A package Sources file the push changes may
# hold a class's sites only up to the count INVARIANT_ALLOWLIST, read at the pushed head, allows for that file and
# class; over it, every site of the class in the file is refused. Local only, like every guardrail. The block owns
# its lines from here to `RULES += INVARIANT_SITE_RULES`.
INVARIANT_ALLOWLIST = "scripts/cmux-next/invariant-allowlist.json"
INVARIANT_CLASSES = ("invariant_check", "dump_will_be_check")
INVARIANT_ALLOW_MEMO = "invariant-allow"


def invariant_allowance(text: str | None) -> dict[tuple[str, str], int]:
    """{(path, class): count} of an invariant-allowlist.json TEXT. An entry without a path, one of INVARIANT_CLASSES,
    a positive whole count, a reason and a reviewer allows nothing; so does a missing or unparsable file."""
    try:
        data = json.loads(text) if text else {}
    except json.JSONDecodeError:
        return {}
    entries = data.get("allow") if isinstance(data, dict) else None
    allowed: dict[tuple[str, str], int] = {}
    for entry in entries if isinstance(entries, list) else []:
        if not isinstance(entry, dict):
            continue
        path, kind, count = entry.get("path"), entry.get("class"), entry.get("count")
        if (isinstance(path, str) and kind in INVARIANT_CLASSES and type(count) is int and count > 0
                and str(entry.get("reason") or "").strip() and str(entry.get("reviewer") or "").strip()):
            allowed[(path, kind)] = allowed.get((path, kind), 0) + count
    return allowed


def invariant_site(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """Every Invariant.check / dumpWillBeCheck site of a class in a package Sources file the push changed (added or
    removed a line in) whose hits of that class are more than the head's invariant-allowlist.json allows there."""
    allowed = next((c.memo[INVARIANT_ALLOW_MEMO] for c in changes if INVARIANT_ALLOW_MEMO in c.memo), {})
    hits = []
    for change in changes:
        if (not change.path.endswith(".swift") or "/Sources/" not in change.path or change.is_deleted
                or not (change.added or change.removed)):
            continue
        for kind in INVARIANT_CLASSES:
            pattern = ratchet.REPORT_SWIFT[kind]
            counted = [(index, len(pattern.findall(ratchet_code(line)))) for index, line in enumerate(change.head_lines)
                       if pattern.search(line)]
            sites = [(index, n) for index, n in counted if n]
            if sum(n for _, n in sites) > allowed.get((change.path, kind), 0):
                hits += [Added(change.path, index + 1, change.head_lines[index]) for index, _ in sites]
    return hits


INVARIANT_SITE_RULES = (
    Rule("invariant-site", "An `Invariant.check` or `Invariant.dumpWillBeCheck` in a package Sources file the push "
         "changes, beyond what scripts/cmux-next/invariant-allowlist.json allows for that file",
         "check stops the process in every build and dumpWillBeCheck reports for ever: each site is a reviewed "
         "decision (Chromium's CHECK and DUMP_WILL_BE_CHECK, base/check.h), and outside input is never one",
         "outside input gets a typed error; for a true internal invariant add an entry to "
         "scripts/cmux-next/invariant-allowlist.json: {\"path\", \"class\": \"invariant_check\" or "
         "\"dump_will_be_check\", \"count\", \"reason\" (check: the shared or persisted state going on would "
         "corrupt; dumpWillBeCheck: the code that recovers), \"reviewer\"}",
         None,
         invariant_site,
         scope=("Packages/",)),
)
RULES += INVARIANT_SITE_RULES
# ---------------------------------------------------------------- end of invariant-site


# ---------------------------------------------------------------- not-fatal-until-lowered
# Invariant.notFatalUntil(cond, id, build: N) reports until build N, then traps, like Chromium's
# base::NotFatalUntil::M<n> (base/check.h). A lower or removed N moves the day users crash, so it needs a reason. The
# rules are crash_ratchet.py's lowered_not_fatal_until (one definition), judged over the push's changed Swift files on
# both sides, so an id that moves between files keeps its build. Local only, like every guardrail.
# The block owns its lines from here to `RULES += NOT_FATAL_UNTIL_RULES`.
def not_fatal_until_lowered(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """Invariant calls that lower or remove the notFatalUntil build of the base call they replace (paired by place)."""
    judged = [c for c in changes if c.path.endswith(".swift") and "/Sources/" in c.path]
    base = {c.path: c.base_lines for c in judged if not c.is_new}
    head = {c.path: c.head_lines for c in judged if not c.is_deleted}
    return [Added(path, line, f"{head[path][line - 1]}  ({why})")
            for path, line, why in ratchet.lowered_not_fatal_until(base, head)]


NOT_FATAL_UNTIL_RULES = (
    Rule("not-fatal-until-lowered", "An `Invariant.notFatalUntil` build lowered or removed (made `check` or "
         "`dumpWillBeCheck`, or its `build:` dropped)",
         "the build number is the release from which the site traps instead of reporting; lowering it crashes users "
         "earlier than the reviewed plan (Chromium's base::NotFatalUntil only ever moves to a later milestone)",
         "keep the build, or raise it while the reports are still coming in; fix the cause, then remove the call",
         "// not-fatal-until-lowered-allow: <why the site may trap sooner>",
         not_fatal_until_lowered,
         scope=("Packages/",)),
)
RULES += NOT_FATAL_UNTIL_RULES
# ---------------------------------------------------------------- end of not-fatal-until-lowered


# ---------------------------------------------------------------- trap-api
# A standard-library call that traps on a bad argument: `uniqueKeysWithValues:` (a repeated key), an unguarded
# `removeFirst()` / `removeLast()` (an empty collection), `(repeating:count:)` with a count that may be negative,
# `index(_:offsetBy:)` without `limitedBy:` (past the end). The class and its guard exemptions are crash_ratchet.py's
# report-only `trap_api` (one definition; `--report trap_api` prints queue Q09). Chromium's base containers check the
# same arguments and report instead of trapping where input reaches them (base/containers/checked_iterators.h,
# base/numerics/checked_math.h); here the caller proves the argument. The Shared and iOS packages are at zero, so
# the class is banned there as crash_ratchet.py bans a class at zero: every hit in a file the push changes is
# refused, old lines and moved ones too. Elsewhere (CmuxNext, whose queue 097 and later waves empty) a push may not
# add one: per changed file, a hit at head pairs with a hit of the same text at base (resolve()), and only an extra
# one is refused. Local only, like every guardrail. The block owns its lines from here to `RULES += TRAP_API_RULES`.
TRAP_API_BANNED = ("Packages/Shared/", "Packages/iOS/")
TRAP_API_ALLOW = allow_marker("trap-api")


def trap_api_lines(path: str, lines: list[str]) -> list[Added]:
    """Every line of LINES (a package Sources file at PATH) that starts a trap_api call without a reviewed escape,
    once per call."""
    return [Added(path, index + 1, lines[index]) for index in range(len(lines))
            for _ in range(ratchet.trap_api_hits(lines, index)) if not any(TRAP_API_ALLOW.search(lines[j]) for j in escape_window(lines, index))]


def trap_api(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """The trap_api calls of the package Sources files the push changed (added or removed a line in): all of them in
    a banned package, the ones the file did not have at base elsewhere. Unchanged context files are not judged."""
    banned, counted = [], []
    for change in changes:
        if (not change.path.endswith(".swift") or "/Sources/" not in change.path or change.is_deleted
                or not (change.added or change.removed)):
            continue
        head = trap_api_lines(change.path, change.head_lines)
        if change.path.startswith(TRAP_API_BANNED):
            banned += head
        else:
            counted.append((head, trap_api_lines(change.path, change.base_lines)))
    return banned + resolve(counted)


TRAP_API_RULES = (
    Rule("trap-api", "A standard-library call that traps on a bad argument (`uniqueKeysWithValues:`, an unguarded "
         "`removeFirst()` / `removeLast()`, `(repeating:count:)` with a count that may be negative, "
         "`index(_:offsetBy:)` without `limitedBy:`): any in a Shared or iOS package Sources file the push changes "
         "(banned: old lines count too), a new one in other package Sources",
         "a duplicate key, an empty queue, a negative count or an offset past the end stops the process; where input "
         "reaches the call, a peer or a file can crash the app (p10-stability.md, SWIFT TRAPS)",
         "`Dictionary(_:uniquingKeysWith:)` with the rule for a repeated key; `popFirst()` / `popLast()`, "
         "`guard let x = q.first else { ... }` before `q.removeFirst()`, or `removeSubrange(..<n)`; a count that is "
         "never negative (`max(0, n)`, a `.count`, a literal, a name validated above, `guard n >= 0`); "
         "`index(_:offsetBy:limitedBy:)` with the nil case handled. "
         "`crash_ratchet.py --report trap_api` lists what it counts",
         "// trap-api-allow: <why the argument is valid here>",
         trap_api,
         scope=("Packages/",)),
)
RULES += TRAP_API_RULES
# ---------------------------------------------------------------- end of trap-api


# ---------------------------------------------------------------- task ids in comments
# A plan task id (`pNN-area-NNN`) in a code comment names where a change came from, which is the commit message's job:
# `git log -S` and `git blame` find it there, and in the code it says nothing to a reader without the plan and goes
# stale when the code moves on (the chrome-parity work left over 2000 of them). task_ids.py beside this file defines
# what an id and a comment are, and strips the old ones (--strip); this rule refuses new ones. Like every rule here it
# is a count ratchet: an added comment line whose ids the push also removes from a comment (an edit, a move) is not
# new; the key is the bare id, so `cp/`, backticks or `(fixer)` around it do not make a kept id new.
# It sees only the files check() diffs (Swift in Packages' Sources and Tests, the shipped crates' src, webviews/src and
# the CEF shim's and Chromium host's src); comments elsewhere (crate tests/, the host's client/ and tests/, scripts)
# are not judged. task_ids.py loads on the first push it judges: a broken copy fails this rule open, not the hook.
TASK_ID_SCOPE = ("Packages/", "cmux-tui/", "webviews/", "Native/", "cmux-next-ios/")


@functools.cache
def task_ids_module():
    return load_sibling("cmux_next_task_ids", "task_ids.py")


def task_id_lines(path: str, lines: list[str]) -> dict[int, set[str]]:
    """1-based line -> the task ids a comment on that line names (a generated file or block names none)."""
    task_ids = task_ids_module()
    text = "\n".join(lines)
    if not task_ids.ID_RE.search(text):
        return {}
    owned = task_ids.generated_ranges(text)
    out: dict[int, set[str]] = {}
    for a, b in task_ids.comment_spans(path, text):
        if any(x <= a < y for x, y in owned):
            continue
        first = text.count("\n", 0, a)
        for k, line in enumerate(text[a:b].split("\n")):
            found = {re.search(task_ids.ID, m.group(0)).group(0) for m in task_ids.ID_RE.finditer(line)}
            if found:
                out.setdefault(first + k + 1, set()).update(found)
    return out


def task_id_comments(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """Added lines whose comment names a task id that no comment line the push removes names."""
    removed_ids: collections.Counter = collections.Counter()
    added: list[tuple[Added, set[str]]] = []
    for change in changes:
        if change.removed:
            base = task_id_lines(change.path, change.base_lines)
            for line in change.removed:
                removed_ids.update(base.get(line.number, ()))
        if change.added:
            head = task_id_lines(change.path, change.head_lines)
            added += [(line, head[line.number]) for line in change.added if line.number in head]
    hits = []
    for line, ids in added:
        if all(removed_ids[i] > 0 for i in ids):
            for i in ids:
                removed_ids[i] -= 1
        else:
            hits.append(line)
    return hits


TASK_ID_RULES = (
    Rule("task-id-comment", "A plan task id (`p04-input-053`, `cp/p10-stability-083`) in a new code comment",
         "a comment says what the code does and why; where the change came from is the commit message's job, where "
         "`git log` and `git blame` find it. In the code an id says nothing without the plan and goes stale",
         "say the reason in words and put the task id in the commit message; strip old ones with "
         "`scripts/cmux-next/task_ids.py --strip PATH`",
         None,
         task_id_comments,
         scope=TASK_ID_SCOPE, local_only=True),
)
RULES += TASK_ID_RULES
# ---------------------------------------------------------------- end of task ids in comments


# ---------------------------------------------------------------- Rust stability rules
# Syntax rules on the Rust a push adds in the shipped crates' src, run with the pinned ast-grep (lint-tools.lock;
# the rules are ast-grep/rules/*.yml beside this file). No cargo build: the person's Mac never builds Rust. They are
# the local tier's early warning (plans/cmux-next/chrome-parity/p10-stability.md, section E "Queues"); the fleet's
# syn scanner (async-blocking-scan) is the full check. Like every rule here, a push's matches are a count ratchet:
# only a match the push adds or un-escapes is new. The block owns its lines from here to `RULES += RUST_RULES`.
RUST_STABILITY_ROOTS = ("cmux-tui/crates/", "Native/", "cmux-next-ios/rust/crates/")
RUST_STABILITY_SPECS = tuple(f":(glob){root}**/src/**/*.rs" for root in RUST_STABILITY_ROOTS)
# Test code may block and spawn freely: test and bench folders, `*_tests.rs` files and `src/tests.rs` modules (the
# rules skip `#[cfg(test)]` modules and `#[test]` functions inside other files themselves).
RUST_TEST_PATH = re.compile(r"/(tests|benches|examples|fuzz)/|_tests?\.rs$|/src/(.+/)?tests?\.rs$")
RUST_RULES_DIR = "ast-grep/rules"  # beside this file
RUST_RULES_TREE = "scripts/cmux-next/" + RUST_RULES_DIR
# The rules that judge a push: the reviewed copy beside this file (install-git-hooks.sh installs it with the
# snapshot). self_test points it at other folders.
RUST_RULES_HOME = HERE / RUST_RULES_DIR
RUST_COMMENT_OR_ATTRIBUTE = re.compile(r"^\s*(//|/\*|\*/|\*(\s|$)|#!?\[)")
RUST_SCAN_TIMEOUT = 20.0  # seconds; a scan of a large push takes well under one
RUST_MEMO = "rust-stability"


class RustScanError(RuntimeError):
    """The pinned ast-grep could not be found, run or read: the Rust rules fail open for this push."""


def in_rust_stability_scope(path: str) -> bool:
    """PATH is shipped Rust source the Rust stability rules read (RUST_STABILITY_SPECS less test code)."""
    return (path.startswith(RUST_STABILITY_ROOTS) and "/src/" in path and path.endswith(".rs")
            and not RUST_TEST_PATH.search(path))


def rust_rule_paths() -> list[str]:
    """The rule files at their repository paths (measure() reads the base's copies)."""
    return [f"{RUST_RULES_TREE}/{rule.id}.yml" for rule in RUST_RULES]


def rust_rule_texts(texts: dict[tuple[str, str], str], base: str) -> str:
    """The Rust rules as one `--inline-rules` document: the copies in RUST_RULES_HOME, else BASE's (a snapshot
    installed before the rules were). Never the pushed HEAD's: the commit under check does not pick its rules."""
    docs = []
    for path in rust_rule_paths():
        own = RUST_RULES_HOME / PurePosixPath(path).name
        text = own.read_text(encoding="utf-8") if own.is_file() else texts.get((base, path))
        if text is None:
            raise RustScanError(f"{path} is neither in {RUST_RULES_HOME} nor at the base {base[:11]}: run "
                                "scripts/install-git-hooks.sh")
        docs.append(text)
    return "\n---\n".join(docs)


@functools.cache
def pinned_tools():
    """prepush-gate.py beside this file: its ensure_tool() downloads and sha256-checks the pinned binaries once."""
    return load_sibling("cmux_next_prepush_gate_tools", "prepush-gate.py")


def ast_grep_binary() -> str:
    try:
        return str(pinned_tools().ensure_tool(HERE / "lint-tools.lock", "ast-grep"))
    except SystemExit as error:  # ensure_tool's refusals: no pinned build for this platform, a wrong sha256
        raise RustScanError(str(error)) from None


def scan_rust(changes: list[FileChange]) -> None:
    """One ast-grep run of every Rust rule over both sides of CHANGES: each file's memo gets ({rule: head lines},
    {rule: base lines}) with 0-based match start lines, or the RustScanError that stopped the scan."""
    todo = [c for c in changes if RUST_MEMO not in c.memo]
    if not todo:
        return
    try:
        found = _scan_rust(todo)
    except (RustScanError, OSError, subprocess.SubprocessError) as error:
        failure = error if isinstance(error, RustScanError) else RustScanError(f"ast-grep: {error}")
        for change in todo:
            change.memo[RUST_MEMO] = failure
        return
    for change in todo:
        change.memo[RUST_MEMO] = found.get(change.path, ({}, {}))


def _scan_rust(changes: list[FileChange]) -> dict[str, tuple[dict[str, set[int]], dict[str, set[int]]]]:
    rules = changes[0].memo.get("rust_rules") or rust_rule_texts({}, "")  # measure() sets it for every Rust file
    if isinstance(rules, RustScanError):
        raise rules
    binary = ast_grep_binary()
    with tempfile.TemporaryDirectory(prefix="cmux-guardrails-rust-") as tmp:
        files = []
        for change in changes:
            for side, lines, present in (("head", change.head_lines, not change.is_deleted),
                                         ("base", change.base_lines, not change.is_new)):
                if not present:
                    continue
                target = Path(tmp, side, change.path)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("\n".join(lines), encoding="utf-8")
                files.append(f"{side}/{change.path}")
        result = subprocess.run([binary, "scan", "--inline-rules", rules, "--json=compact", *files], cwd=tmp,
                                capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=RUST_SCAN_TIMEOUT)
    # 0: no match, 1: matches (the rules are severity error). Anything else is a rule ast-grep rejects, a flag it
    # does not know or a crash: it prints no JSON, and an empty list would pass the push unjudged.
    failed = RustScanError(f"ast-grep exited {result.returncode}: {result.stderr.strip()[:300]}")
    if result.returncode not in (0, 1):
        raise failed
    try:
        matches = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise failed from None
    found: dict[str, tuple[dict[str, set[int]], dict[str, set[int]]]] = {}
    for match in matches:
        side, _, path = match["file"].partition("/")
        sides = found.setdefault(path, ({}, {}))
        sides[0 if side == "head" else 1].setdefault(match["ruleId"], set()).add(match["range"]["start"]["line"])
    return found


def rust_escape_window(lines: list[str], index: int) -> list[int]:
    """escape_window() for Rust: the line, the comment and `#[attribute]` block directly above it, or (no such
    block) the previous line, whose trailing comment counts."""
    window = [index]
    j = index - 1
    while j >= 0 and RUST_COMMENT_OR_ATTRIBUTE.match(lines[j]):
        window.append(j)
        j -= 1
    if j >= 0 and j == index - 1:
        window.append(j)
    return window


def rust_file_debt(change: FileChange, rule_id: str, escape: re.Pattern) -> tuple[list[Added], list[Added]]:
    """file_debt() for one Rust rule: (head debt, base debt) from the matches that start on changed lines, plus the
    unchanged matches whose escape window the push touched (a deleted or reworded escape), judged on both sides."""
    head_hits, base_hits = (side.get(rule_id, set()) for side in change.memo[RUST_MEMO])
    head, base = change.head, change.base

    def debt(version: Version, index: int) -> bool:
        return not any(escape.search(version.lines[j]) for j in rust_escape_window(version.lines, index))

    def rejudged(version: Version, hits: set[int]) -> set[int]:
        return {i for i in hits if i + 1 not in version.changed
                and any(j + 1 in version.touched for j in rust_escape_window(version.lines, i))}

    head_debt = [Added(change.path, i + 1, head.lines[i]) for i in sorted(head_hits)
                 if i + 1 in head.changed and debt(head, i)]
    base_debt = [Added(change.path, i + 1, base.lines[i]) for i in sorted(base_hits)
                 if i + 1 in base.changed and debt(base, i)]
    head_lines, base_lines = rejudged(head, head_hits), rejudged(base, base_hits)
    if head_lines or base_lines:
        to_base = unchanged_pairs(change)
        to_head = {b: h for h, b in to_base.items()}
        pairs = ({(h, to_base[h]) for h in head_lines if h in to_base}
                 | {(to_head[b], b) for b in base_lines if b in to_head})
        for h, b in sorted(pairs):
            if h in head_hits and debt(head, h):
                head_debt.append(Added(change.path, h + 1, head.lines[h]))
            if b in base_hits and debt(base, b):
                base_debt.append(Added(change.path, b + 1, base.lines[b]))
    return head_debt, base_debt


def rust_rule(rule_id: str, escape: str) -> Callable[[list[FileChange], collections.Counter], list[Added]]:
    marker = re.compile(r"//\s*" + re.escape(escape) + r"\s*\S")

    def find(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
        files = [c for c in changes if in_rust_stability_scope(c.path)]
        if not files:
            return []
        scan_rust(files)
        for change in files:
            if isinstance(change.memo[RUST_MEMO], RustScanError):
                raise change.memo[RUST_MEMO]
        return resolve([rust_file_debt(c, rule_id, marker) for c in files])
    return find


RUST_RULES = (
    Rule("rust-async-blocking", "A blocking call in a Rust async body (std sleep, std::fs, a std::net connect, a "
         "join/wait/recv/output that is not awaited, `blocking_*`, `block_on`)",
         "a tokio worker runs many tasks: one blocking call stalls every task queued on it (Chrome: "
         "base/threading/scoped_blocking_call.h; p10-stability.md, cmux-blocking)",
         "`tokio::task::spawn_blocking`, the async API (`tokio::fs`, `tokio::process`, `tokio::time::sleep`, an "
         "awaited channel) or a cmux-blocking wrapper",
         "// blocking-allow: <the thread and the bound>",
         rust_rule("rust-async-blocking", "blocking-allow:"), scope=RUST_STABILITY_ROOTS, local_only=True),
    Rule("rust-unsupervised-spawn", "An unsupervised Rust spawn: a dropped tokio JoinHandle (a statement of its own, "
         "`let _ =` or `drop(...)`) or a raw std thread (`thread::spawn`, `thread::Builder::new()...spawn`)",
         "its panic and its end go unseen, a live process serving nothing (Chrome posts to owned sequences and the "
         "thread pool: docs/threading_and_tasks.md)",
         "keep the JoinHandle (store it, join it, or a JoinSet), or run it under `cmux_panic_log::supervise_task` / "
         "`supervise_thread` with a policy and a ShutdownBehavior",
         "// supervise-allow: <who notices when it ends>",
         rust_rule("rust-unsupervised-spawn", "supervise-allow:"), scope=RUST_STABILITY_ROOTS, local_only=True),
    Rule("rust-ffi-guard", "An `extern \"C\" fn` whose body is not wrapped in `ffi_boundary`",
         "cmux builds Rust with panic=unwind: a panic that reaches an extern \"C\" boundary aborts the app "
         "(Chromium builds Rust with panic=abort: build/config/rust.gni)",
         "wrap the body: `ffi_boundary(<fallback>, || { ... })`",
         "// ffi-nopanic: <why the body cannot panic>",
         rust_rule("rust-ffi-guard", "ffi-nopanic:"), scope=RUST_STABILITY_ROOTS, local_only=True),
)
RULES += RUST_RULES
# ---------------------------------------------------------------- end of Rust stability rules


# ---------------------------------------------------------------- decode-trap
# Outside input never traps (p10-stability.md, section D): a file in decode-paths.json reads a peer's, a device's or
# a file's bytes, and holds no index subscript and no trapping integer conversion, by the crash ratchet's own
# definitions (crash_ratchet.py's index_subscript and int_conversion: one definition). Unlike a count ratchet this
# is a ban: a push that touches a listed file is refused for every unescaped hit in the whole file, so a listed
# file stays at zero. An operand that is not input (a C constant, a bound the code set itself) carries
# `// decode-trap-allow: <why>`. Like Chromium's checks.md, input gets validation that returns an error, and only an
# internal invariant keeps a check. Local only, like every guardrail. The block owns its lines from here to
# `RULES += DECODE_TRAP_RULES`.
DECODE_PATHS = HERE / "decode-paths.json"
DECODE_TRAP_ESCAPE = allow_marker("decode-trap")


@functools.lru_cache(maxsize=1)
def decode_paths() -> tuple[str, ...]:
    """The listed decode files (repo-relative)."""
    return tuple(entry["path"] for entry in json.loads(DECODE_PATHS.read_text())["files"])


def decode_trap_hits(lines: list[str]) -> list[tuple[int, int]]:
    """[(0-based line, hits)] of LINES (one decode file): index subscripts and trapping integer conversions outside
    comments, string contents and lines escaped with `// decode-trap-allow:` (on the line or the comment block above).
    A subscript on a name the file declares only as a dictionary cannot trap and does not count."""
    dictionaries = ratchet.file_dictionaries(lines, frozenset(), frozenset())
    found = []
    for index, line in enumerate(lines):
        code = ratchet_code(line)
        hits = ratchet.index_hits(code, dictionaries) + ratchet.int_conversion_hits(code) if code.strip() else 0
        if hits and not any(DECODE_TRAP_ESCAPE.search(lines[j]) for j in escape_window(lines, index)):
            found.append((index, hits))
    return found


def decode_trap(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """Every unescaped hit in each listed decode file the push changes and keeps."""
    listed = set(decode_paths())
    return [Added(c.path, index + 1, c.head_lines[index])
            for c in changes if c.path in listed and not c.is_deleted and c.head_lines != [""]
            for index, _ in decode_trap_hits(c.head_lines)]


DECODE_TRAP_RULES = (
    Rule("decode-trap", "An index subscript (`bytes[i]`, `buffer[a..<b]`) or a trapping integer conversion (`Int(x)`, "
         "`UInt8(x)`) in a decode file (scripts/cmux-next/decode-paths.json)",
         "the file reads bytes a peer, a device or a file chose: an index or a value they push out of range ends the "
         "app instead of the connection (p10-stability.md, section D: outside input never traps)",
         "read fields from the front of what is left (`prefix`, `dropFirst`, `popFirst`, a reader that throws), "
         "widen with `truncatingIfNeeded:` from a narrower unsigned type, convert with `Int(exactly:)` and turn nil "
         "into the file's typed error (RFBError.protocolViolation, SurfaceSourceWireError, ...); never clamp input",
         "// decode-trap-allow: <why the operand is not input: a C constant, a bound this code set>",
         decode_trap,
         scope=("Packages/",)),
)
RULES += DECODE_TRAP_RULES
# ---------------------------------------------------------------- end of decode-trap


# ---------------------------------------------------------------- wakeup-ext (p14-energy, PL-energy)
# Nothing polls (plans/cmux-next/chrome-parity/p14-energy.md, section C) in the code outside CmuxNext Sources: the
# Shared packages and CmuxUpdater the app links, the cmux-tui crates' src, webviews/src and the CEF shim's C++/ObjC.
# check-concurrency.sh already refuses wakeups in CmuxNext Sources before the push, so they are not repeated here.
# The rules, the masking, the Rust test-item reading and the closed escape vocabulary are wakeup-audit.py's (one
# definition; its --strict run is the full-tree audit of the program's test phase). Like Chromium's PRESUBMIT.py
# banned-function checks (CheckNoBannedFunctions reads only ChangedContents()), it judges what the push adds.
WAKEUP_AUDIT = "wakeup-audit.py"
IDLE_BUDGET = "scripts/cmux-next/idle-budget.json"
SHARED_PACKAGES = "Packages/Shared/"
UPDATER = "Packages/macOS/CmuxUpdater/"
RUST_CRATES = "cmux-tui/crates/"
WEB_SOURCES = "webviews/src/"
# wakeup-audit's cxx roots (CXX_ROOTS): the CEF shim and the Chromium host it splits out.
CXX_SOURCES = (PACKAGE_ROOT + "CEFShim/src/", PACKAGE_ROOT + "ChromiumHost/src/")
WAKEUP_EXT_SPECS = (f":(glob){SHARED_PACKAGES}*/Sources/**/*.swift", f":(glob){UPDATER}Sources/**/*.swift",
                    f":(glob){RUST_CRATES}*/src/**/*.rs", f":(glob){WEB_SOURCES}**/*.ts",
                    f":(glob){WEB_SOURCES}**/*.tsx", f":(glob){WEB_SOURCES}**/*.css", *CXX_SOURCES, IDLE_BUDGET)
# The statuses wakeup-audit --strict fails on (`escaped` passes; the shim's `blocking` loops are reported, never open).
WAKEUP_OPEN = frozenset({"hit", "bad-escape", "no-reason", "periodic-unlisted"})


def in_wakeup_ext_specs(path: str) -> bool:
    """PATH is in one of WAKEUP_EXT_SPECS (in_diff_scope's test for them)."""
    parts = path.split("/")
    return ((path.startswith(SHARED_PACKAGES) and parts[3:4] == ["Sources"] and path.endswith(".swift"))
            or (path.startswith(UPDATER + "Sources/") and path.endswith(".swift"))
            or (path.startswith(RUST_CRATES) and parts[3:4] == ["src"] and path.endswith(".rs"))
            or (path.startswith(WEB_SOURCES) and path.endswith((".ts", ".tsx", ".css")))
            or path.startswith(CXX_SOURCES) or path == IDLE_BUDGET)


RUST_ROOT = re.compile(r"^cmux-tui/crates/[^/]+/src/(?:lib\.rs|main\.rs|bin/[^/]+\.rs|bin/[^/]+/main\.rs)$")
PACKAGE_PATH = re.compile(r'^\s*\.package\(\s*path:\s*"([^"]+)"', re.MULTILINE)


@dataclass
class WakeupContext:
    """What the wakeup-ext rule reads beside a push's files: its revisions and, at each one, the package manifest
    (which packages the app links) and idle-budget.json (the owners a `periodic` escape may name; None: absent)."""
    repo: Path
    base: str
    head: str
    manifests: dict[str, str]
    budgets: dict[str, str | None]


@dataclass
class WakeupHit(Added):
    """An added wakeup: CAUSE names the wakeup-audit rule, the hit's shape and a bad escape (format_report prints
    it)."""
    cause: str = ""


def wakeup_audit():
    """wakeup-audit.py beside this file, loaded on first use (a load error fails only this rule open)."""
    name = "cmux_next_wakeup_audit"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, HERE / WAKEUP_AUDIT)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module  # its dataclasses resolve their module through sys.modules
        try:
            spec.loader.exec_module(module)
        except BaseException:
            del sys.modules[name]
            raise
    return sys.modules[name]


class ChecksRoot:
    """A repository root for wakeup-audit's `root / "scripts/cmux-next/<file>"` reads: the file beside this one, so
    the hook's reviewed snapshot of check-concurrency.sh defines the Swift rules, not the pushing checkout's."""

    def __truediv__(self, relative: str) -> Path:
        return HERE / Path(relative).name


@functools.cache
def wakeup_rules(lang: str) -> tuple:
    """wakeup-audit's rules for LANG (cxx: none until wakeup-audit has CXX_RULES, p14-energy-113)."""
    wa = wakeup_audit()
    if lang == "swift-shared":
        return tuple(wa.swift_wakeup_rules(ChecksRoot()))
    return tuple({"rust": wa.RUST_RULES, "web": wa.WEB_RULES, "cxx": getattr(wa, "CXX_RULES", ())}[lang])


class BudgetText:
    """idle-budget.json at one revision, as the Path wakeup-audit's periodic_owners() reads (TEXT None: absent)."""

    def __init__(self, text: str | None):
        self.text = text

    def exists(self) -> bool:
        return self.text is not None

    def read_text(self, encoding: str = "utf-8") -> str:
        return self.text or ""


def budget_owners(text: str | None) -> tuple[set[str], list[str]]:
    """wakeup-audit's periodic_owners() of idle-budget.json TEXT: (the owners, the entries that break its limits)."""
    try:
        return wakeup_audit().periodic_owners(BudgetText(text))
    except (ValueError, TypeError, AttributeError) as error:  # not JSON, or not the shape the audit reads
        return set(), [f"{IDLE_BUDGET} is not the allowed_periodic list wakeup-audit reads ({error})"]


def budget_hits(context: WakeupContext, head_problems: list[str], base_problems: list[str]) -> list[Added]:
    """A refusal for each limit HEAD's idle-budget.json breaks that BASE's did not (at most PERIODIC_MAX entries,
    period_s >= PERIODIC_MIN_S, an owner and a why on each)."""
    lines = (context.budgets[context.head] or "").split("\n")
    number = next((i + 1 for i, line in enumerate(lines) if '"allowed_periodic"' in line), 1)
    return [WakeupHit(IDLE_BUDGET, number, problem, "wakeup-audit periodic_owners: the idle budget's own limits")
            for problem in head_problems if problem not in base_problems]


def linked_packages(manifest: str) -> frozenset[str]:
    """The Packages/Shared and Packages/macOS package folders CmuxNext's Package.swift (MANIFEST) links by path."""
    found = (posixpath.normpath(posixpath.join(PACKAGE_ROOT, m.group(1))) for m in PACKAGE_PATH.finditer(manifest))
    return frozenset(p for p in found if p.startswith((SHARED_PACKAGES, "Packages/macOS/")))


def wakeup_lang(path: str, linked: frozenset[str]) -> str | None:
    """wakeup-audit's language of PATH when its `sources()` read it, else None."""
    wa = wakeup_audit()
    parts = path.split("/")
    if path.endswith(".swift") and "/".join(parts[:3]) in linked and parts[3:4] == ["Sources"]:
        return None if wa.SHARED_SKIP_DIRS & set(parts[4:-1]) else "swift-shared"
    if path.startswith(RUST_CRATES) and parts[3:4] == ["src"] and path.endswith(".rs"):
        return "rust"
    if path.startswith(WEB_SOURCES) and path.endswith((".ts", ".tsx", ".css")):
        return None if wa.WEB_SKIP_DIRS & set(parts[2:-1]) or wa.WEB_SKIP_FILE.search(parts[-1]) else "web"
    cxx_roots = tuple(root.rstrip("/") + "/" for root in getattr(wa, "CXX_ROOTS", {}).values())
    if path.startswith(cxx_roots) and path.endswith(getattr(wa, "CXX_SUFFIXES", ())) and wakeup_rules("cxx"):
        return "cxx"
    return None


def tree_path(tree: frozenset[str]) -> type:
    """A path type whose `exists()` and `resolve()` answer from TREE (one revision's file list), so wakeup-audit's
    `mod x;` resolution reads the pushed revision, not the pushing checkout's disk."""

    class TreePath(PurePosixPath):
        def exists(self) -> bool:
            return str(self) in tree

        def resolve(self) -> "TreePath":
            return TreePath(posixpath.normpath(str(self)))

    return TreePath


def rust_declarers(repo: Path, rev: str, crates: list[str], files: list[str]) -> set[str]:
    """Files at REV that may declare one of FILES as a module: a `mod <name>;` in the file's folder or above it, or
    a `#[path]` that names its file. rust_test_only() reads which of them do."""
    folders: dict[str, set[str]] = {}
    tails = set()
    for f in files:
        folder, base = posixpath.split(f)
        stem = posixpath.basename(folder) if base == "mod.rs" else base.removesuffix(".rs")
        if re.fullmatch(r"\w+", stem):  # only `#[path]` can name a file that is no identifier
            folders.setdefault(stem, set()).add(posixpath.dirname(folder) if base == "mod.rs" else folder)
        tails.add(re.sub(r"[.+]", r"\\\g<0>", f"{stem}/mod.rs" if base == "mod.rs" else base))
    by_name, by_path = run_both(
        repo, ["grep", "-l", "-E", r"(^|[^[:alnum:]_])mod[[:space:]]+(" + "|".join(sorted(folders) or ["$^"])
               + r")[[:space:]]*;",
               rev, "--", *crates],
        ["grep", "-l", "-E", r'path[[:space:]]*=[[:space:]]*"([^"]*/)?(' + "|".join(sorted(tails)) + r')"', rev, "--",
         *crates])

    def listed(out: str) -> set[str]:
        return {line.split(":", 1)[1] for line in out.splitlines() if ":" in line}

    # `mod name;` declares <the declaring file's folder or its stem's folder>[/<inline modules>]/name.rs.
    wanted = {d for ds in folders.values() for d in ds}
    near = {p for p in listed(by_name)
            if any(d == posixpath.dirname(p) or d.startswith(posixpath.dirname(p) + "/") for d in wanted)}
    return near | listed(by_path)


def rust_tree(repo: Path, rev: str, crates: list[str]) -> frozenset[str]:
    """The files of CRATES at REV."""
    return frozenset(git(repo, "ls-tree", "-r", "--name-only", rev, "--", *crates, check=False).split("\n"))


def rust_test_only(repo: Path, rev: str, files: list[str]) -> set[str]:
    """FILES (crate src files) that only tests compile at REV: declared inside a test-only item, or by a file that
    only tests compile (wakeup-audit's rust_test_files over their declaring files, up to the crate root)."""
    wa = wakeup_audit()
    crates = sorted({"/".join(f.split("/")[:4]) for f in files})
    tree = rust_tree(repo, rev, crates)
    TreePath = tree_path(tree)
    modules: dict = {}
    looked: set[str] = set()
    todo = sorted(f for f in files if f in tree and not RUST_ROOT.match(f))
    while todo:
        looked.update(todo)
        wanted = {TreePath(f) for f in todo}
        candidates = sorted(p for p in rust_declarers(repo, rev, crates, todo) if TreePath(p) not in modules)
        declarers = []
        for (_, path), raw in blobs(repo, [(rev, p) for p in candidates]).items():
            mods = modules[TreePath(path)] = wa.rust_modules(wa.mask(raw, "rust"), raw, TreePath(path))
            if any(child in wanted for child, _ in mods.children):
                declarers.append(path)
        todo = sorted(p for p in declarers if p not in looked and not RUST_ROOT.match(p))
    tests = wa.rust_test_files(modules)
    return {f for f in files if TreePath(f) in tests}


def rust_flipped(context: WakeupContext, changes: list[FileChange]) -> set[str]:
    """Module files whose test-only state the `mod x;` declarations of CHANGES (crate src files) may change: each
    child declared test-only on one side only (`#[cfg(test)]` dropped or added, the declaration deleted), and every
    module file below one (wakeup-audit's rust_test_files reads a test-only file's children as test-only too)."""
    if not changes:
        return set()
    wa = wakeup_audit()
    head, base = context.head, context.base
    crates = sorted({"/".join(c.path.split("/")[:4]) for c in changes})
    trees = {rev: tree_path(rust_tree(context.repo, rev, crates)) for rev in (head, base)}

    def children(rev: str, path: str, raw: str) -> list:
        return wa.rust_modules(wa.mask(raw, "rust"), raw, trees[rev](path)).children if "mod" in raw else []

    flipped: set[str] = set()
    for change in changes:
        tested = [{str(child) for child, in_test in children(rev, change.path, "\n".join(lines)) if in_test}
                  for rev, lines in ((head, change.head_lines), (base, change.base_lines))]
        flipped |= tested[0] ^ tested[1]
    todo = sorted(flipped)
    while todo:
        texts = blobs(context.repo, [(rev, p) for p in todo for rev in (head, base)])
        todo = sorted({str(child) for (rev, p), raw in texts.items() for child, _ in children(rev, p, raw)} - flipped)
        flipped.update(todo)
    return flipped


PERIODIC_ESCAPE = re.compile(r"wakeup-allow:\s*periodic\s+(\S+)")


def wakeup_context_files(context: WakeupContext, changed: dict[str, FileChange], linked: dict[str, frozenset[str]],
                         lost_owners: set[str]) -> dict[str, FileChange]:
    """The unchanged files whose wakeups the push opens by changing what gives them their context: the module files a
    changed `mod` declaration takes out of (or puts into) test-only code, the Sources of a package only HEAD links,
    and the files whose `periodic` escape names an owner the push takes off idle-budget.json."""
    head, base, repo = context.head, context.base, context.repo
    paths = rust_flipped(context, [c for c in changed.values() if wakeup_lang(c.path, frozenset()) == "rust"])
    if newly := sorted(linked[head] - linked[base]):
        listed = git(repo, "ls-tree", "-r", "--name-only", head, "--", *(f"{p}/Sources" for p in newly), check=False)
        paths |= {p for p in listed.split("\n") if p and wakeup_lang(p, linked[head])}
    if lost_owners:
        out = git(repo, "grep", "-I", "-E", r"wakeup-allow:[[:space:]]*periodic", head, "--", *WAKEUP_EXT_SPECS,
                  check=False)
        for line in out.splitlines():  # <rev>:<path>:<text>
            _, path, text = (line.split(":", 2) + ["", ""])[:3]
            if any(m.group(1).rstrip(".,;:") in lost_owners for m in PERIODIC_ESCAPE.finditer(text)):
                paths.add(path)
    paths = sorted(p for p in paths - set(changed) if wakeup_lang(p, linked[head] | linked[base]))
    texts = blobs(repo, [(rev, p) for p in paths for rev in (head, base)])
    return {p: FileChange(p, texts.get((head, p), "").split("\n"), base_lines=texts.get((base, p), "").split("\n"))
            for p in paths}


def open_wakeups(lang: str, path: str, text: str, owners: set[str], repo: Path) -> list:
    """wakeup-audit's hits in TEXT that --strict fails on: an unescaped hit, an escape word outside the vocabulary,
    an escape with no reason, a `periodic` owner idle-budget.json does not list."""
    if not text:
        return []
    wa = wakeup_audit()
    code, skip = None, []
    if lang == "rust":
        code = wa.mask(text, "rust")
        # The file's own test items; its `mod x;` children are rust_test_only()'s, so no tree is needed here.
        skip = wa.rust_modules(code, text, tree_path(frozenset())(path)).test_ranges
    hits = wa.audit_file(repo, lang, "", repo / path, list(wakeup_rules(lang)), owners, skip, text, code)
    return [h for h in hits if h.status in WAKEUP_OPEN]


def opened(hit, pairs: dict[int, int], other: dict[tuple[int, str], str]) -> bool:
    """HIT, on a line the push did not change, is the push's: the other side (OTHER: {(line, rule): shape}; PAIRS:
    this side's 0-based lines to the other's) has no open hit of its rule on that line, or only a one-shot where HIT
    loops (the push put a loop around it or took its loop's event away)."""
    shape = other.get((pairs.get(hit.line - 1, -2) + 1, hit.rule))
    return shape is None or (hit.shape == "loop" and shape != "loop")


def wakeup_ext(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """Wakeups the push opens, per file, wakeup-audit rule and shape (resolve(): a count ratchet, moves between files
    free), so a removed one-shot `thread::sleep` pays for neither a `recv_timeout` nor a polling loop."""
    if not changes:
        return []
    context: WakeupContext = changes[0].memo["wakeup"]
    head, base = context.head, context.base
    linked = {rev: linked_packages(context.manifests[rev]) for rev in (head, base)}
    (head_owners, head_problems), (base_owners, base_problems) = (budget_owners(context.budgets[rev])
                                                                  for rev in (head, base))
    # An owner counts once the base lists it: a push cannot approve its own interval in idle-budget.json.
    owners = {head: head_owners & base_owners, base: base_owners}
    files = {c.path: c for c in changes}
    files.update(wakeup_context_files(context, files, linked, base_owners - owners[head]))
    sides = []
    for change in files.values():
        # A package the app links on one side only is judged on that side only.
        langs = {rev: wakeup_lang(change.path, linked[rev]) for rev in (head, base)}
        if any(langs.values()):
            sides.append((change, {rev: open_wakeups(langs[rev], change.path, "\n".join(lines), owners[rev],
                                                     context.repo) if langs[rev] else []
                                   for rev, lines in ((head, change.head_lines), (base, change.base_lines))}))
    # Which module files only tests compile is read only for the files with hits (it greps the crates' trees).
    rust = sorted(change.path for change, hits in sides
                  if wakeup_lang(change.path, frozenset()) == "rust" and any(hits.values()))
    test_only = {rev: rust_test_only(context.repo, rev, rust) if rust else set() for rev in (head, base)}
    groups: dict[tuple[str, str], list[tuple[list[Added], list[Added]]]] = {}
    order = {}
    for index, (change, hits) in enumerate(sides):
        order[change.path] = index
        head_hits = [] if change.path in test_only[head] else hits[head]
        base_hits = [] if change.path in test_only[base] else hits[base]
        to_base = unchanged_pairs(change)
        to_head = {b: h for h, b in to_base.items()}
        head_open = {(h.line, h.rule): h.shape for h in head_hits}
        base_open = {(h.line, h.rule): h.shape for h in base_hits}
        added = {a.number for a in change.added}
        removed = {r.number for r in change.removed}
        # A changed line's hit is the push's; an unchanged line's only when the push opened or closed it there (an
        # escape deleted or written, a `#[cfg(test)]` removed or added, a loop put around it).
        head_debt = [h for h in head_hits if h.line in added or opened(h, to_base, base_open)]
        base_debt = [h for h in base_hits if h.line in removed or opened(h, to_head, head_open)]
        for key in sorted({(h.rule, h.shape) for h in head_debt + base_debt}):
            groups.setdefault(key, []).append(
                (wakeup_debt(change.path, [h for h in head_debt if (h.rule, h.shape) == key], change.head_lines),
                 wakeup_debt(change.path, [h for h in base_debt if (h.rule, h.shape) == key], change.base_lines)))
    found = sorted((hit for group in groups.values() for hit in resolve(group)),
                   key=lambda hit: (order[hit.path], hit.number))
    return budget_hits(context, head_problems, base_problems) + found


def wakeup_debt(path: str, hits: list, lines: list[str]) -> list[WakeupHit]:
    return [WakeupHit(path, h.line, lines[h.line - 1],
                      f"wakeup-audit {h.rule}, {h.shape}" + (f"; {h.status} `{h.escape}`" if h.status != "hit" else ""))
            for h in hits]


RULES += (
    Rule("wakeup-ext", "An idle wakeup (timer, sleep, timed wait, spin loop, interval, infinite animation) in an "
         "app-linked Shared package, CmuxUpdater, a cmux-tui crate's src, webviews/src or the CEF shim",
         "a timer or a poll wakes the process while the person does nothing: idle wakeups cost battery and keep cmux "
         "above Chrome's (perf-lead.md item 6, plans/cmux-next/chrome-parity/p14-energy.md); the rules and the "
         "escape vocabulary are scripts/cmux-next/wakeup-audit.py's",
         "wait for the event (a read, a channel recv, NOTE_EXIT / pidfd, FSEvents, a push from the host, visibility), "
         "a one-shot deadline for a timeout, Backoff after a failure, MaintenanceClock for maintenance; bound an "
         "animation or gate it on visibility and the motion setting; test-only code (`#[cfg(test)]`, *.test.ts) is "
         "not judged",
         "// wakeup-allow: <deadline|backoff|bounded|cli-only|fixture|debug|periodic> <reason> (`periodic <owner>` "
         "only for an owner in idle-budget.json allowed_periodic)",
         wakeup_ext,
         # The manifest and the budget: a push that changes which packages the app links, or which owners a
         # `periodic` escape may name, changes what the unchanged files' wakeups are.
         scope=(SHARED_PACKAGES, UPDATER, RUST_CRATES, WEB_SOURCES, *CXX_SOURCES, MANIFEST, IDLE_BUDGET)),
)
# ---------------------------------------------------------------- end of wakeup-ext


# ---------------------------------------------------------------- main-blocking / thread-doc (PL-blocking)
# plans/cmux-next/threading-model.md: the main thread never blocks (Chrome's ScopedBlockingCall). The runtime
# detector (CmuxNextCompat/Threading, CmuxNextCompatAppKit/Threading) is the real guard; these rules are the early
# warning on what a push adds.
# They judge only the lines the push changed (no whole-file context scan), so the gate stays fast.
# The block owns its lines from here to `RULES += BLOCKING_RULES`; other rules go above it.
THREADING_DOC = "plans/cmux-next/threading-model.md"
THREADING_DOC_SECTION = "## Registered threads and queues"
PACKAGE_MANIFEST = "Packages/macOS/CmuxNext/Package.swift"
# The seams themselves (and Mutex, which reports contended waits) wrap the raw primitives on purpose, as does
# CmuxThreading, the leaf that gives the linked Shared/iOS packages their `blockingCall` seam and Mutex.
THREADING_LEAF = "Packages/Shared/CmuxThreading/"
BLOCKING_SEAMS = (SOURCES + "CmuxNextCompat/Threading/", SOURCES + "CmuxNextCompatAppKit/Threading/",
                  SOURCES + "CmuxNextCompat/Mutex.swift", THREADING_LEAF)
BLOCKING_ALLOW = re.compile(r"//\s*blocking-allow:\s*\S")
FILE_OPS = (r"fileExists|isReadableFile|isWritableFile|isExecutableFile|createDirectory|removeItem|contentsOfDirectory|"
            r"subpathsOfDirectory|enumerator|createFile|contents|contentsEqual|attributesOfItem|attributesOfFileSystem|"
            r"setAttributes|moveItem|copyItem|linkItem|replaceItemAt|destinationOfSymbolicLink|createSymbolicLink|"
            r"trashItem|url")
# Raw blocking primitives: most have a checked seam in CmuxNextCompat/Threading (the NSWorkspace queries in
# CmuxNextCompatAppKit/Threading); the rest (sync XPC proxies, AppleScript, condition locks, asyncAndWait,
# LSCopy*) move to an async API. A `.wait(` or an SMAppService
# `.unregister()` preceded by `await` in its statement is the async overload (Backoff.wait, a continuation,
# `try await service.unregister()`), never a blocking one: see blocking_match.
# Process launch matches any receiver chain (`try box.process.run()`, ProcessRunner.swift:74).
# The system calls wait on another process: securityd, the AX server, mDNSResponder, the window server, lsd,
# launchd, authd (p02-threads.md "Not seen by any rule").
CALL_ARGS = r"\((?:[^()]|\([^()]*\))*\)"  # one argument list, one nested call deep: `.daemon(plistName: C().name)`
RAW_BLOCKING = re.compile(
    r"\bData\(contentsOf:|\bString\(contentsOf(File)?:|\bNS(Data|String|Dictionary|Array|Image)\(contentsOf(File|URL)?:"
    r"|\bFileManager\.default\.(" + FILE_OPS + r")\("
    r"|\.write\(to:|\.waitUntilExit\(\)|\.readDataToEndOfFile\(\)|\.readToEnd\(\)|\.availableData\b|\.readData\(ofLength:"
    r"|\.resourceValues\(forKeys:|\bxpc_connection_send_message_with_reply_sync\(|\bposix_spawnp?\(|(?<![\w.])fork\(\)"
    r"|(?P<wait>(?<=[\w)\]])\.wait\((timeout:|wallTimeout:|until:)?[^)]*\))"
    r"|\.sync\s*(\{|\(execute:)"
    # process launch, queue and thread waits
    r"|\btry[?!]?\s+[\w.]+\.run\(\)|(?<=[\w)\]])(?<!\bself)\.launch\(\)"
    r"|\.waitUntilAllOperationsAreFinished\(\)|\.asyncAndWait\s*(\{|\()"
    r"|\bpthread_(join|cond_wait|cond_timedwait)\(|\bNSConditionLock\(|\.lock\(whenCondition:"
    # synchronous system calls
    r"|\bSec(Item(CopyMatching|Add|Update|Delete)|TrustEvaluate(WithError)?|StaticCodeCheckValidity(WithErrors)?"
    r"|CodeCopy\w+)\("
    r"|\bAXUIElement(Copy\w+|PerformAction|SetAttributeValue|GetAttributeValueCount)\(|\bgetaddrinfo\("
    r"|\bCGWindowList(Copy|Create)\w*\(|\bLSCopy\w+\("
    r"|\.urls?ForApplications?\((withBundleIdentifier|toOpen):|\.icon\(forFiles?:"
    r"|\b(NSWorkspace\.shared|[wW]orkspace)\.icon\(for:"
    r"|\bSMAppService\.(mainApp|(agent|daemon|loginItem)" + CALL_ARGS + r")\.(status\b|register\(\)"
    r"|(?P<unregister>unregister\(\)))"
    r"|\bAuthorizationCopyRights\(|\.synchronousRemoteObjectProxyWithErrorHandler\b|\.executeAndReturnError\(")
# Named groups whose match is the async overload when an `await` comes before it in the statement.
AWAITABLE = ("wait", "unregister")
# The checked seams: fine off the main thread, a violation on it.
SEAM_BLOCKING = re.compile(
    r"\bFileManager\.checked\.|\bblockingContentsOf(File)?:|\.blockingResourceValues\(|\.blocking(ReadToEnd|Read|Write|"
    r"AvailableData|ReadDataToEndOfFile|Wait|WaitUntilExit|Sync|Run|ForReading|ForWriting|ForUpdating|SeekToEnd|Seek|"
    r"Synchronize|CanEvaluatePolicy)\b|\bblocking(Read|Recv|Write|Send|XPCSendWithReply|PosixSpawn"
    # POSIX files, waitpid, ImageIO file I/O, SQLite, kernel and directory queries
    r"|Open|Pread|Pwrite|Fsync|Flock|Ftruncate|Rename|Unlink|Stat|Lstat|Realpath|Access|Chmod|Mkdir|Rmdir|Waitpid|Waitid"
    r"|Sysctl|SysctlByName|ProcPidInfo|ProcPidPath|ProcPidFDInfo|ProcListPids|ProcPidRusage|Getpwuid|Getpwnam"
    r"|ImageSource|ImageSourceCount|ImageSourceCopyProperties|ImageSourceCreateImage|ImageSourceCreateThumbnail"
    r"|ImageDestination|ImageDestinationFinalize"
    r"|SQLiteOpen|SQLitePrepare|SQLiteStep|SQLiteExec|SQLiteClose|SQLiteCloseV2|SQLiteBackupStep)\(|\bblockingCall\("
    # the system-call seams
    r"|\bblocking(SecItem(CopyMatching|Add|Update|Delete)|SecTrustEvaluate|SecStaticCodeCheckValidity|SecCodeCopy\w+"
    r"|AX(CopyAttributeValue|SetAttributeValue|PerformAction)|Getaddrinfo|WindowList(CopyWindowInfo|CreateImage\w*)"
    r"|URLForApplication|URLsForApplications|Icon|SMAppService(Status|Register|Unregister)|AuthorizationCopyRights)\(")
# Never on any thread of the app: a main-queue sync hop deadlocks from main and stalls it from elsewhere; a
# sleep holds a thread to wait for time; `runModal(` spins a nested modal run loop on main until the person answers.
# Chrome shows its dialogs window-modal, never in a nested loop: SelectFileDialogBridge begins its
# panel with beginSheetModalForWindow (components/remote_cocoa/app_shim/select_file_dialog_bridge.mm). Use
# beginSheetModal(for:), a panel's begin(completionHandler:) or a CmuxDialogSpec. NSPrintOperation's sheet form
# `runModal(for: window, delegate:...)` returns at once, so a call with a `delegate:` is not one.
ALWAYS_BLOCKING = re.compile(r"DispatchQueue\.main\.sync\b|\bThread\.sleep\b|(?<![\w.])(usleep|nanosleep)\("
                             r"|\.runModal\((?![^)]*\bdelegate:)")
# A new thread or queue. `extension Thread {` and a type annotation are not one.
# `Thread {` counts only where a value starts (after `=`, `(`, `,`, `return`, or as a statement), so a superclass,
# a return type or a type annotation (`class W: Thread {`, `-> Thread {`, `var t: Thread {`) is not one.
# `ChildProcessLauncher(label:` is a queue too: the wrapper's own `DispatchQueue(label: label` is not judged.
THREAD_CREATE = re.compile(r"\bDispatchQueue\(\s*label:|(?:^\s*|[=(,]\s*|\breturn\s+)Thread\s*(\{|\(block:|\(target:)"
                           r"|\bThread\.detachNewThread\b|\bOperationQueue\(\)|\bpthread_create\(|\bDispatchSerialQueue\("
                           r"|\bDispatchWorkloop\(|\bChildProcessLauncher\(\s*label:")
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
                 "esourceValues", "xpc_", "blocking", "write(to:", "posix_spawn", "fork(", ".run()", ".launch()",
                 "waitUntilAll", "asyncAndWait", "pthread_", "NSConditionLock", "whenCondition", "SecItem", "SecTrust",
                 "SecStaticCode", "SecCode", "AXUIElement", "getaddrinfo", "CGWindowList", "LSCopy", "ForApplication",
                 "icon(", "SMAppService", "AuthorizationCopyRights", "synchronousRemoteObjectProxy", "executeAndReturnError")
RAW_SCAN = Prefiltered(RAW_BLOCKING, BLOCKING_KEYS)
MAIN_SCAN = Prefiltered(re.compile(RAW_BLOCKING.pattern + "|" + SEAM_BLOCKING.pattern), BLOCKING_KEYS)
ALWAYS_SCAN = Prefiltered(ALWAYS_BLOCKING, ("main.sync", "sleep", "runModal"))
THREAD_SCAN = Prefiltered(re.compile(THREAD_CREATE.pattern + "|" + ALLOWANCE_DECL.pattern),
                          ("Thread", "Queue", "pthread_", "Workloop", "BlockingAllowance", "ChildProcessLauncher"))


def blocking_match(scan: Prefiltered, code: str) -> bool:
    """Whether CODE holds a blocking call SCAN names. An AWAITABLE match whose statement has an `await` before it
    is the async overload (`try await backoff.wait(owner:)`, `try await service.unregister()`), not a blocking
    one."""
    answer = scan.answers.get(code)
    if answer is None:
        answer = scan.answers[code] = _blocking_match(scan, code)
    return answer


def _blocking_match(scan: Prefiltered, code: str) -> bool:
    match = scan.search(code)
    while match is not None:
        groups = match.groupdict()
        if not any(groups.get(name) for name in AWAITABLE):
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


def header_start(lines: list[str], number: int) -> int:
    """The 1-based first line of the header of the block that opens on 1-based line NUMBER: the line after the
    previous statement's end, at most HEADER_LINES lines up."""
    j = number - 2
    while j >= 0 and number - 1 - j <= HEADER_LINES and not STATEMENT_END.search(code_of(lines[j])):
        j -= 1
    return j + 2


def block_header(lines: list[str], number: int, code: str) -> str:
    """The whole header of the block that opens on 1-based line NUMBER (whose code up to its `{` is CODE): the
    lines back to the previous statement's end, joined, so `func f(\n a: A\n) async throws {` and
    `if a,\n b {` read as one header."""
    parts = [code_of(lines[j]) for j in range(header_start(lines, number) - 1, number - 1)] + [code]
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


# pool-blocking: a blocking call on a shared pool thread. Chrome's ThreadPool runs a task without
# MayBlock() under ScopedDisallowBlocking (base/task/thread_pool/task_tracker.cc RunTask); cmux's pools are the Swift
# cooperative pool (Task.detached, child tasks, `Task {` off any actor, default actor executors, @concurrent) and the
# GCD root queues. One blocked pool thread is a whole core's worth of async work stalled (the pool has one per core).
# The body as a trailing closure, or as the `operation:` argument (`Task.detached(operation: { ... })`).
TASK_BODY = r"(?:\s*(\([^{]*\))?\s*\{$|\s*\([^{]*\boperation:\s*\{$)"
POOL_DETACHED = re.compile(r"\bTask\.detached" + TASK_BODY)
POOL_CHILD = re.compile(r"\baddTask(UnlessCancelled)?" + TASK_BODY + r"|\bDispatchQueue\.global\([^{]*\)\s*\.\s*"
                        r"async(After)?\s*(\([^{]*\))?\s*\{$|\.concurrentPerform\s*\([^{]*\)\s*\{$")
TASK_INHERITS = re.compile(r"(?<![\w.])Task\s*(<[^{]*>)?\s*(\([^{]*\))?\s*\{$")
CLOSURE_ON_MAIN = re.compile(r"^\{\s*(\[[^\]]*\]\s*)?@MainActor\b")
# Calls that run their trailing closure before they return, in the caller's isolation.
INLINE_CALLS = (r"map|compactMap|flatMap|filter|forEach|reduce|contains|first|last|firstIndex|lastIndex|allSatisfy|"
                r"sorted|sort|min|max|removeAll|mapValues|compactMapValues|partition|drop|prefix|split|merge|merging|"
                r"withLock|withLockUnchecked|withUnsafe\w*|withCString|withMemoryRebound|withExtendedLifetime|"
                r"autoreleasepool|with(?:Throwing)?(?:Discarding)?TaskGroup|with(?:Checked|Unsafe)(?:Throwing)?Continuation|"
                r"withTaskCancellationHandler|withValue|withObservationTracking")
INLINE_CLOSURE_CALL = re.compile(rf"\b(?:{INLINE_CALLS})\s*(?:\([^{{}}]*\))?\s*\{{$|\b(?:{INLINE_CALLS})\(\s*(?:\w+\s*:\s*)?\{{$")
ACCESSOR_OPENER = re.compile(r"^\s*(get|set|willSet|didSet|_read|_modify)\b")
FUNCTION_OPENER = re.compile(r"\b(func|subscript)\b|\bvar\s+`?\w+`?\s*:")
INIT_OPENER = re.compile(r"\b(init[?!]?|deinit)\b")
CONCURRENT = re.compile(r"@concurrent\b")
# An isolation the declaration states for itself: a global actor, or none (`nonisolated`, a static member). Read on
# the declaration's prefix only (declaration_prefix): a parameter's `@MainActor` closure type or `.static` default
# says nothing about the function's own isolation.
OWN_GLOBAL_ACTOR = re.compile(r"@[A-Z]\w*Actor\b")
NOT_INSTANCE_ISOLATED = re.compile(r"\bnonisolated\b(?!\s*\(unsafe\))|\bstatic\b|\bclass\s+(?=(func|var|subscript)\b)")
DECLARATION_KEYWORD = re.compile(r"\b(func|init|deinit|subscript|var)\b")
ASYNC_EFFECT = re.compile(r"^[^{]*?\basync\b")
TYPE_OPENER = re.compile(r"(?:^|[\s)])(?P<kind>(?:distributed\s+)?actor|class|struct|enum|extension|protocol)\s+"
                         r"(?!(?:func|var|let|subscript|init|deinit|override|static|in|where)\b)(?P<name>[A-Za-z_][\w.]*)")
ACTOR_EXECUTOR = re.compile(r"\bvar\s+unownedExecutor\b")
# An actor declaration line, for `git grep -E` over a revision's sources (actor_index_at).
ACTOR_DECLARATION_GREP = (r"^[[:space:]]*(@[[:alnum:]_]+[[:space:]]+|(public|package|internal|private|fileprivate|final|"
                          r"distributed|nonisolated)[[:space:]]+)*actor[[:space:]]+[A-Za-z_]")
# `async let x = <call>`: the initializer runs as a child task on the cooperative pool.
ASYNC_LET = re.compile(r"^\s*async\s+let\b[^=]*=(?!=)")
ASYNC_LET_OPEN = re.compile(r"^\s*async\s+let\b[^=]*=\s*$")
CALL_MARKERS_ONLY = re.compile(r"^\s*((try[?!]?|await)\s+)*$")  # the prefix of a call that starts its line
NONISOLATED = re.compile(r"\bnonisolated\b(?!\s*\(unsafe\))")
TypeScope = tuple[str, str, int]  # (kind, name, 0-based line of its declaration)


def type_scopes_of(lines: list[str]) -> list[TypeScope | None]:
    """For each of LINES, the innermost type body that holds it as (kind, name, declaration line), else None: kind
    is `actor` for any actor, and an extension's name is its last component (`extension Outer.Store` -> "Store")."""
    scopes: list[TypeScope | None] = []
    stack: list[tuple[int, TypeScope]] = []  # (brace depth, scope) per open type body
    pending: TypeScope | None = None  # a type header whose `{` has not opened yet
    depth = 0
    for index, line in enumerate(lines):
        code = code_of(line)
        scopes.append(stack[-1][1] if stack else None)
        match = TYPE_OPENER.search(code)
        if match:
            kind = "actor" if match.group("kind").endswith("actor") else match.group("kind")
            pending = (kind, match.group("name").rsplit(".", 1)[-1], index)
        for char in code:
            if char == "{":
                depth += 1
                if pending is not None:
                    stack.append((depth, pending))
                    pending = None
            elif char == "}":
                while stack and stack[-1][0] >= depth:
                    stack.pop()
                depth -= 1
    return scopes


def type_scopes(version: Version) -> list[TypeScope | None]:
    if "type_scopes" not in version.memo:
        version.memo["type_scopes"] = type_scopes_of(version.lines)
    return version.memo["type_scopes"]


@dataclass
class ActorIndex:
    """The actors of some files and the types among them with a custom executor, as {(module, name): paths}.

    An actor's extensions and its `unownedExecutor` may sit in files of their own (DaemonConnection+*.swift), so a
    method's actor is resolved against every file of its module: the push's own files (one index per side) and
    HEAD's other files (repo_actor_index, read only when a lookup misses). The custom executor is the HomeCache
    pattern (Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Store/HomeCache.swift): `nonisolated var
    unownedExecutor` over a named DispatchSerialQueue; a comment alone is no executor.
    """
    actors: dict[tuple[str, str], set[str]] = field(default_factory=dict)
    executors: dict[tuple[str, str], set[str]] = field(default_factory=dict)
    own_paths: set[str] = field(default_factory=set)  # the push's files: the repo index's entries for them don't count
    unread: list[tuple[str, list[str]]] = field(default_factory=list)  # (path, lines) added on the first lookup

    def add(self, path: str, lines: list[str]) -> None:
        module = module_of(path)
        for code, scope in zip((code_of(line) for line in lines), type_scopes_of(lines)):
            for match in TYPE_OPENER.finditer(code):
                if match.group("kind").endswith("actor"):
                    self.actors.setdefault((module, match.group("name").rsplit(".", 1)[-1]), set()).add(path)
            if scope is not None and ACTOR_EXECUTOR.search(code):
                self.executors.setdefault((module, scope[1]), set()).add(path)

    def knows(self, table: str, key: tuple[str, str]) -> bool:
        while self.unread:
            self.add(*self.unread.pop())
        if key in getattr(self, table):
            return True
        repo = repo_actor_index()
        return repo is not None and bool(getattr(repo, table).get(key, set()) - self.own_paths)

    def actor_of(self, path: str, scope: TypeScope | None) -> tuple[str, str] | None:
        """The (module, name) of the actor whose instance members a line of PATH in type body SCOPE belongs to."""
        if scope is None or scope[0] not in ("actor", "extension"):
            return None
        key = (module_of(path), scope[1])
        return key if scope[0] == "actor" or self.knows("actors", key) else None

    def has_custom_executor(self, key: tuple[str, str]) -> bool:
        return self.knows("executors", key)


def actor_index_at(repo: Path, rev: str) -> ActorIndex:
    """The actors and custom executors of REV's sources: a `git grep` for actor declaration lines, and the files
    that name `unownedExecutor`, read whole to find the type each one belongs to."""
    index = ActorIndex()
    spec = ["--", SOURCES + "*.swift"]
    found = git(repo, "grep", "-I", "-n", "-E", "-e", ACTOR_DECLARATION_GREP, rev, *spec, check=False)
    for row in found.split("\n"):
        parts = row[len(rev) + 1:].split(":", 2) if row.startswith(rev + ":") else []
        if len(parts) == 3:
            index.add(parts[0], [parts[2]])
    named = git(repo, "grep", "-I", "-l", "-F", "unownedExecutor", rev, *spec, check=False)
    paths = [row[len(rev) + 1:] for row in named.split("\n") if row.startswith(rev + ":")]
    for (_, path), text in blobs(repo, [(rev, p) for p in paths]).items():
        index.add(path, text.split("\n"))
    return index


def repo_actor_index() -> ActorIndex | None:
    """HEAD's ActorIndex for check() (load_blocking_context names the tree), read once per run; None without one."""
    if "actor_index" not in BLOCKING_CONTEXT:
        tree = BLOCKING_CONTEXT.get("actor_tree")
        BLOCKING_CONTEXT["actor_index"] = actor_index_at(*tree) if tree else None
    return BLOCKING_CONTEXT["actor_index"]


# A header line that continues the line above it, and a line that continues on the line below it.
CONTINUES_ABOVE = re.compile(r"^\s*(\.|&&|\|\||\?\?|->|else\b|where\b|async\b|throws\b|rethrows\b)")
CONTINUES_BELOW = re.compile(r"(,|\(|\[|->|=|&&|\|\||\?\?)\s*$")
ATTRIBUTES_ONLY = re.compile(rf"^\s*(?:{ATTRIBUTE}\s*)+$")


def statement_header(lines: list[str], number: int, opener: str) -> tuple[str, int]:
    """The header of the block that opens on 1-based line NUMBER (whose code up to its `{` is OPENER), and the
    0-based line it starts on. Unlike block_header it joins a line above only where the statement goes on (an
    open parenthesis, a trailing `,` or a leading `.`, `else`, `async`): Swift statements end without `;`, so
    `let x = 1` above `do {` is a statement of its own, and `@concurrent` above a signature is an attribute."""
    parts, start = [opener], number - 1
    depth = opener.count("(") + opener.count("[") - opener.count(")") - opener.count("]")
    j = number - 2
    while j >= 0 and number - 1 - j <= HEADER_LINES:
        above = code_of(lines[j])
        if not above.strip() or ATTRIBUTE_LINE.match(above):
            break
        if not (depth < 0 or CONTINUES_ABOVE.match(parts[0]) or CONTINUES_BELOW.search(above)):
            break
        parts.insert(0, above)
        depth += above.count("(") + above.count("[") - above.count(")") - above.count("]")
        start = j
        j -= 1
    return " ".join(part.strip() for part in parts), start


def declaration_attributes(lines: list[str], start: int) -> str:
    """The attribute-only lines right above a declaration whose header starts on 0-based line START (`@concurrent`
    on its own line), past comment lines between them. The walk stops at any other line: a one-line member above
    (`@MainActor var x = 0`, `@concurrent func a() async { }`) has attributes of its own."""
    found = []
    j = start - 1
    while j >= 0 and start - j <= HEADER_LINES:
        code = code_of(lines[j])
        if ATTRIBUTES_ONLY.match(code):
            found.append(code)
        elif not COMMENT_LINE.match(lines[j]):
            break
        j -= 1
    return " ".join(found)


def declaration_prefix(header: str) -> str:
    """HEADER (a declaration's joined header) through its keyword (`func`, `init`, `subscript`, `var`): its
    attributes and modifiers, without the parameter list, the effects or the return type."""
    match = DECLARATION_KEYWORD.search(header)
    return header[:match.end()] if match else header


def type_is_main(version: Version, scope: TypeScope | None) -> bool:
    """Whether a member of type body SCOPE is main-actor code when it states no isolation of its own: the type's
    own `@MainActor`, none for an actor, a `nonisolated` type or another global actor, else its enclosing type's,
    else the target's default. Read from the type's attributes and modifiers only, as for a function."""
    lines = version.lines
    while scope is not None:
        kind, _, line = scope
        code = code_of(lines[line])
        match = TYPE_OPENER.search(code)
        stated = (code[:match.start("kind")] if match else code) + " " + declaration_attributes(lines, line)
        if OWN_GLOBAL_ACTOR.search(stated):
            return re.search(r"@MainActor\b", stated) is not None
        if kind == "actor" or NONISOLATED.search(stated):
            return False
        scope = type_scopes(version)[line]
    return module_of(version.path) in ui_targets()


def declares_async(header: str) -> bool:
    """Whether HEADER (a function or initializer header) is `async`: read in the effects after its parameter list,
    so an `async` closure parameter does not count."""
    match = DECLARATION_KEYWORD.search(header)
    opening = header.find("(", match.end()) if match else -1
    if opening < 0:
        return False
    depth = 0
    for position in range(opening, len(header)):
        depth += header[position] == "("
        depth -= header[position] == ")"
        if depth == 0:
            return bool(ASYNC_EFFECT.search(header[position + 1:]))
    return False


def pool_context(version: Version, index: int) -> str | None:
    """Where VERSION's line INDEX runs if that is a shared pool thread, else None: "Task.detached", "a child task"
    (`addTask {`, a global queue, `concurrentPerform`), "a child task (async let)", "an @concurrent function", "a
    `Task {` in a nonisolated function", or "an actor method" (an actor without a custom executor, resolved against
    the ActorIndex in VERSION.memo["actors"]). Any other closure (`work.run {`, a completion handler, a serial
    queue's `async {`) is not judged: it runs where its API says."""
    answers = version.memo.setdefault("pool_context", {})
    if index not in answers:
        answers[index] = _pool_context(version, index)
    return answers[index]


def _pool_context(version: Version, index: int) -> str | None:
    lines = version.lines
    code = code_of(lines[index])
    match = MAIN_SCAN.search(code)
    prefix = code[:match.start()] if match else ""
    if ASYNC_LET.search(prefix) or (CALL_MARKERS_ONLY.match(prefix) and index > 0
                                    and ASYNC_LET_OPEN.search(code_of(lines[index - 1]))):
        return "a child task (async let)"
    return _pool_walk(version, index, prefix, False)


def is_local_declaration(lines: list[str], start: int) -> bool:
    """Whether the declaration whose header starts on 0-based line START sits in a function or closure body (a
    local function), not in a type body or at file level."""
    outer = enclosing_openers(lines, start, INNERMOST_BLOCK)
    return bool(outer) and not TYPE_OPENER.search(statement_header(lines, outer[0][1], outer[0][0])[0])


def _pool_walk(version: Version, index: int, prefix: str, in_task: bool) -> str | None:
    """pool_context's walk out of the blocks around line INDEX (PREFIX: the code before the call on it)."""
    lines = version.lines
    for opener, number in enclosing_openers(lines, index, OPENER_STOP, prefix):
        header, start = statement_header(lines, number, opener) if number - 1 != index else (opener, index)
        line = code_of(lines[number - 1])
        if MAIN_OPENER.search(opener) or MAIN_OPENER.search(line) or CLOSURE_ON_MAIN.search(line[len(opener) - 1:]):
            return None
        if POOL_DETACHED.search(header):
            return "Task.detached"
        if POOL_CHILD.search(header):
            return "a child task"
        if TASK_INHERITS.search(header):
            in_task = True
            continue
        if ACCESSOR_OPENER.search(header) or CONTROL_OPENER.search(header) or INLINE_CLOSURE_CALL.search(header):
            continue
        if not DECLARATION_OPENER.search(header):
            return None  # a closure: it runs where its API says
        if not FUNCTION_OPENER.search(header) and not INIT_OPENER.search(header):
            return None  # a type body
        stated = declaration_prefix(header) + " " + declaration_attributes(lines, start)
        if CONCURRENT.search(stated):
            return "an @concurrent function"
        if OWN_GLOBAL_ACTOR.search(stated):
            return None
        if is_local_declaration(lines, start):
            return _pool_walk(version, start, "", in_task)  # a local function runs in its enclosing context
        actors = version.memo.get("actors") or ActorIndex()
        actor = actors.actor_of(version.path, type_scopes(version)[number - 1])
        if actor is not None and not NOT_INSTANCE_ISOLATED.search(stated):
            # A synchronous init and deinit run on their caller. An `async` init is actor-isolated once `self` is
            # initialized (SE-0327), so it runs on the actor's executor as a method does.
            if INIT_OPENER.search(header) and not FUNCTION_OPENER.search(header) and not (
                    declaration_prefix(header).endswith("init") and declares_async(header)):
                return None
            return None if actors.has_custom_executor(actor) else "an actor method"
        # A `Task {` takes the function's isolation: the one its prefix states, else its type's.
        if in_task and (NONISOLATED.search(stated) or not type_is_main(version, type_scopes(version)[start])):
            return "a `Task {` in a nonisolated function"
        return None
    return None


def blocking_on_pool(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """Added blocking calls (raw or seam) that run on a shared pool thread (pool_context)."""
    changes = outside_seams(changes)
    own = {c.path for c in changes}
    # Each side's files are read only if a line of the push sits in an extension or an actor (most pushes: none).
    head_actors = ActorIndex(own_paths=own, unread=[(c.path, c.head_lines) for c in changes])
    base_actors = ActorIndex(own_paths=own, unread=[(c.path, c.base_lines) for c in changes])
    for change in changes:
        for version, _ in blocking_sides(change):
            version.memo["actors"] = head_actors if version.lines is change.head_lines else base_actors
            version.memo.pop("pool_context", None)  # its answers read the index the last call set

    def judge(version: Version, index: int, code: str) -> bool:
        return (index < len(version.lines) and blocking_match(MAIN_SCAN, code) and not ALWAYS_SCAN.search(code)
                and not runs_on_main(version, index) and pool_context(version, index) is not None)
    return changed_debt(changes, judge)


def raw_blocking(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """Added raw blocking primitives that main-blocking does not report (off the main thread, or in a closure)."""
    def judge(version: Version, index: int, code: str) -> bool:
        return (blocking_match(RAW_SCAN, code) and not ALWAYS_SCAN.search(code)
                and not (index < len(version.lines) and runs_on_main(version, index))
                and not linked_seam_marked(version, index, code))
    return changed_debt(outside_seams(changes), judge)


def linked_seam_marked(version: Version, index: int, code: str) -> bool:
    """Whether every raw primitive in CODE, line INDEX of a linked package's file, runs in a CmuxThreading
    `blockingCall(.kind) { ... }` closure: below the app that seam marks it (CmuxNextCompat's named seams are out of
    reach there). The app's own files keep their named seams."""
    if index >= len(version.lines) or linked_package(version.path) is None:
        return False
    return all(in_seam_scope(version, index, match.start()) for match in RAW_SCAN.pattern.finditer(code))


# raw-blocking-ext: the blocking primitives RAW_BLOCKING does not name (Chromium marks the same classes with a
# ScopedBlockingCall: base/files/file_util_posix.cc, base/process/kill_posix.cc, sql/database.cc,
# base/system/sys_info_mac.mm). Free functions need a `(?<![\w.])` lookbehind (or `Darwin.`), an argument, no
# argument label and their C arity, so a method (`menu.removeItem(at:)`, `rename(id, to:)`), a one-argument
# `stat(resolved)` or the `stat()` initializer is not one. A bare `open(` counts only with an `O_*` flag among its
# arguments. LAContext's `evaluatePolicy` has no synchronous form (a `reply:` closure or `await`), so only
# `canEvaluatePolicy` is refused.
POSIX_CALLS = (r"fsync|flock|ftruncate|rename|unlink|mkdir|rmdir|lstat|stat|realpath|access|chmod|symlink|readlink|"
               r"opendir|readdir|pread|pwrite|waitpid|wait4|waitid|sysctl|sysctlbyname|getpw\w*")
# Each fixed-arity C function's argument count (getpw* varies: getpwuid 1, getpwuid_r 5; open takes 2 or 3).
C_ARITY = {"fsync": 1, "flock": 2, "ftruncate": 2, "rename": 2, "unlink": 1, "mkdir": 2, "rmdir": 1, "lstat": 2,
           "stat": 2, "realpath": 2, "access": 2, "chmod": 2, "symlink": 2, "readlink": 3, "opendir": 1, "readdir": 1,
           "pread": 4, "pwrite": 4, "waitpid": 3, "wait4": 4, "waitid": 4, "sysctl": 6, "sysctlbyname": 5}
RAW_BLOCKING_EXT = re.compile(
    r"(?:\bDarwin\.|(?<![\w.]))(?P<free>" + POSIX_CALLS + r"|(?P<open>open))\((?!\s*\))|\bDarwin\.(read|write)\("
    r"|\bFileHandle(\.init)?\(\s*for(Reading|Writing|Updating)"
    r"|\.write\(contentsOf:|\.read\(upToCount:|\.seekToEnd(OfFile)?\(\)|\.synchronize(File)?\(\)"
    r"|\bCGImage(SourceCreateWithURL|DestinationCreateWithURL|DestinationFinalize)\("
    r"|\bsqlite3_(open|open_v2|prepare_v2|prepare_v3|step|exec|close|close_v2)\("
    r"|\bproc_(pidinfo|pidpath|listpids)\(|\.canEvaluatePolicy\("
    r"|\bHost\.current\(\)|\bprocessInfo\.hostName\b|\bFileManager\(\)\.(" + FILE_OPS + r")\(")
RAW_EXT_SCAN = Prefiltered(RAW_BLOCKING_EXT, tuple(name + "(" for name in POSIX_CALLS.split("|") if "\\" not in name) + (
    "getpw", "open(", "Darwin.", "FileHandle", "write(contentsOf:", "upToCount:", "seekToEnd", "synchronize", "CGImage",
    "sqlite3_", "proc_", "canEvaluatePolicy(", "Host.current", "hostName", "FileManager()"))
# Where a match names a declaration, not a call: `func rename(`, `case stat(`.
DECLARED_AT = re.compile(r"\b(func|case)\s+$")
O_FLAG = re.compile(r"\bO_[A-Z]")
BRACE = re.compile(r"[{}]")
ARGUMENT_TOKENS = re.compile(r"[()\[\]{},]")
# The seam scopes: a call in a `blockingCall(.kind) { ... }` or `allowBlocking(.reason) { ... }` closure is marked.
SEAM_SCOPE = re.compile(r"\b(blockingCall|allowBlocking)\s*\(")
SIGNATURE = re.compile(r"\b(func|init[?!]?|subscript)\b")
TYPE_NAME = re.compile(r"\b(?:class|struct|enum|actor|extension|protocol)\s+(?!(?:func|var|let)\b)(?P<name>[A-Za-z_]\w*)")
# A declaration of a POSIX name that a bare call in its scope resolves to: a function, a local or member bound to a
# value (`guard let rename = onRename`, `let stat = { ... }`), a function-typed property or a function-typed
# parameter (`rename: @escaping (Target) -> Void`). `var stat: Bool` and `access: AccessLevel` call nothing; `open`
# is never shadowed, because its `O_*` flag is the C signature.
FUNCTION_TYPE = r"\s*:\s*(?:@\w+(?:\([^)]*\))?\s+|inout\s+)*\("
POSIX_DECLARATION = re.compile(r"\bfunc\s+(?P<function>" + POSIX_CALLS + r")\b"
                               r"|\b(?:let|var)\s+(?P<bound>" + POSIX_CALLS + r")\b(?=\s*=|" + FUNCTION_TYPE + r")"
                               r"|[(,]\s*(?:\w+\s+)?(?P<parameter>" + POSIX_CALLS + r")(?=" + FUNCTION_TYPE + r")")
# A name a file binds to a FileManager (`let fm = FileManager.default`, `fileManager: FileManager? = .default`,
# `let files = FileManager()`); `FileManager.default.urls(` and `FileManager.SearchPathDirectory` bind nothing.
FILE_MANAGER_BINDING = re.compile(
    r"\b(?:let|var)\s+(?P<value>\w+)\s*(?::\s*FileManager\s*)?=\s*FileManager(?:\.default|\(\))(?![\w.(])"
    r"|(?<![\w.])(?P<typed>\w+)\s*:\s*FileManager(?![\w.(])")


class BraceBlocks:
    """The brace blocks of one Version's code, read once: the block that holds a position, each block's parent and
    header, and the blocks of each type name. A declaration is visible only in its scope (declaration_scope), so a
    local in one function hides nothing in another."""

    def __init__(self, lines: list[str], codes: list[str]) -> None:
        self.lines, self.codes = lines, codes
        self.parent: list[int] = []  # block -> enclosing block (-1: the file)
        self.opened: list[tuple[int, int]] = []  # block -> (0-based line, column) of its `{`, in file order
        self.starts: list[int] = []  # line -> the block open at the line's start
        self.events: list[list[tuple[int, int]] | None] = []  # line -> [(brace column, block open after it)]
        self.headers: dict[int, str] = {}
        self.types: dict[str, list[int]] | None = None
        stack = [-1]
        for index, code in enumerate(codes):
            self.starts.append(stack[-1])
            if "{" not in code and "}" not in code:
                self.events.append(None)
                continue
            events = []
            for brace in BRACE.finditer(code):
                if brace.group() == "{":
                    stack.append(len(self.parent))
                    self.parent.append(stack[-2])
                    self.opened.append((index, brace.start()))
                elif len(stack) > 1:
                    stack.pop()
                events.append((brace.start(), stack[-1]))
            self.events.append(events)

    def at(self, index: int, column: int) -> int:
        """The innermost block open at COLUMN of line INDEX (-1: the file)."""
        block = self.starts[index]
        for position, after in self.events[index] or ():
            if position >= column:
                break
            block = after
        return block

    def chain(self, block: int) -> list[int]:
        """BLOCK and the blocks around it, innermost first, ending with the file (-1)."""
        out = [block]
        while block != -1:
            block = self.parent[block]
            out.append(block)
        return out

    def header(self, block: int) -> str:
        """BLOCK's whole header up to its `{` (block_header)."""
        if block not in self.headers:
            index, column = self.opened[block]
            self.headers[block] = block_header(self.lines, index + 1, self.codes[index][:column + 1])
        return self.headers[block]

    def declaration_scope(self, index: int, column: int, owner: str | None) -> tuple[int, ...]:
        """The blocks a declaration at COLUMN of line INDEX is visible in: a function parameter's body (OWNER
        "function"), a closure parameter's closure (OWNER "closure"), a local's block, or a member's type body and
        the file's extensions of that type."""
        block = self.at(index, column)
        if owner == "function":
            body = bisect.bisect_right(self.opened, (index, column))
            if (body < len(self.opened) and self.opened[body][0] - index <= HEADER_LINES and self.parent[body] == block
                    and SIGNATURE.search(self.header(body))):
                return (body,)
            return ()  # a protocol requirement or a function type: no body to see it
        if owner == "closure":
            return (block,)
        named = TYPE_NAME.search(self.header(block)) if block != -1 else None
        if named is None:
            return (block,)
        if self.types is None:
            self.types = {}
            for other, (line, at) in enumerate(self.opened):
                found = TYPE_NAME.search(self.codes[line][:at + 1])
                if found:
                    self.types.setdefault(found.group("name"), []).append(other)
        return (block, *self.types.get(named.group("name"), ()))


def codes_of(version: Version) -> list[str]:
    """code_of of each line of VERSION, read once."""
    if "codes" not in version.memo:
        version.memo["codes"] = [code_of(line) for line in version.lines]
    return version.memo["codes"]


def blocks_of(version: Version) -> BraceBlocks:
    if "brace_blocks" not in version.memo:
        version.memo["brace_blocks"] = BraceBlocks(version.lines, codes_of(version))
    return version.memo["brace_blocks"]


def declarations_in_scope(version: Version, pattern: re.Pattern, groups: tuple[str, ...],
                          manager: bool) -> dict[tuple[str, int], list[tuple[int, int, bool]]]:
    """Each PATTERN match in VERSION's code, by (the name in its matched group of GROUPS, each block of its scope):
    [(line, column, whether it binds a FileManager)] in file order. A group named `parameter` is a parameter;
    MANAGER says whether to judge the FileManager binding."""
    codes = codes_of(version)
    if "text" not in version.memo:
        version.memo["text"] = "\n".join(codes)
        version.memo["offsets"] = list(itertools.accumulate((len(code) + 1 for code in codes[:-1]), initial=0))
    text, offsets = version.memo["text"], version.memo["offsets"]
    found: dict[tuple[str, int], list[tuple[int, int, bool]]] = {}
    if pattern.search(text) is None:
        return found
    scopes = blocks_of(version)
    for match in pattern.finditer(text):
        group = next(g for g in groups if match.group(g))
        owner = parameter_owner(text, match.start(group)) if group == "parameter" else None
        if group == "parameter" and owner is None:
            continue  # a call's argument label (`list(fileManager: fileManager)`) declares nothing
        line = bisect.bisect_right(offsets, match.start(group)) - 1
        column = match.start(group) - offsets[line]
        binds = False
        if manager:
            binding = (FILE_MANAGER_BINDING.match(text, match.start()) if group != "parameter" else None) \
                or FILE_MANAGER_BINDING.match(text, match.start(group))
            binds = binding is not None and not (binding.group("value") and line + 1 < len(codes)
                                                 and codes[line + 1].lstrip().startswith("."))
        for block in scopes.declaration_scope(line, column, owner):
            found.setdefault((match.group(group), block), []).append((line, column, binds))
    return found


PARAMETER_LIST_REACH = 4000  # the most characters one parameter list is read back across
SIGNATURE_BEFORE = re.compile(r"\b(?:func\s+[^\s(]+|init[?!]?|subscript)\s*(?:<[^()]*>)?\s*$")
CLOSURE_BEFORE = re.compile(r"\{\s*(?:(?:\[[^\]]*\]|@\w+)\s*)*$")


def parameter_owner(text: str, offset: int) -> str | None:
    """Whether the `name:` at OFFSET of TEXT is a parameter of a function signature ("function"), of a closure
    (`{ (name: T) in`, "closure"), or neither (a call's argument label: None): what comes before the innermost
    `(` it is in."""
    depth = 0
    for position in range(offset - 1, max(-1, offset - PARAMETER_LIST_REACH), -1):
        char = text[position]
        if char == ")":
            depth += 1
        elif char == "(":
            if depth == 0:
                before = text[max(0, position - 200):position]
                if SIGNATURE_BEFORE.search(before):
                    return "function"
                return "closure" if CLOSURE_BEFORE.search(before) else None
            depth -= 1
        elif char in "{}" and depth == 0:
            return None
    return None


def nearest_declaration(version: Version, found: dict, name: str, index: int,
                        column: int) -> tuple[int, int, bool] | None:
    """The declaration of NAME that a use at COLUMN of line INDEX reads: in the innermost scope that declares it, the
    latest one before the use (or that scope's first)."""
    if not found:
        return None
    scopes = blocks_of(version)
    for block in scopes.chain(scopes.at(index, column)):
        candidates = found.get((name, block))
        if candidates:
            before = [c for c in candidates if (c[0], c[1]) <= (index, column)]
            return before[-1] if before else candidates[0]
    return None


def call_arguments(version: Version, index: int, open_paren: int) -> list[str] | None:
    """The arguments of the call whose `(` is at OPEN_PAREN of line INDEX, read across lines to its `)` and split at
    its own commas; None when the list does not close within one header's reach."""
    codes = codes_of(version)
    arguments: list[str] = []
    current: list[str] = []
    depth = 0
    for line in range(index, min(len(codes), index + HEADER_LINES)):
        code = codes[line]
        start = open_paren + 1 if line == index else 0
        for token in ARGUMENT_TOKENS.finditer(code, open_paren if line == index else 0):
            char = token.group()
            if char in "([{":
                depth += 1
            elif char in ")]}":
                depth -= 1
                if depth == 0:
                    current.append(code[start:token.start()])
                    last = " ".join(current)
                    if arguments or last.strip():
                        arguments.append(last)
                    return arguments
            elif depth == 1:
                current.append(code[start:token.start()])
                arguments.append(" ".join(current))
                current, start = [], token.end()
        current.append(code[start:])
    return None


def posix_call(version: Version, index: int, match: re.Match) -> bool:
    """Whether MATCH, a free-function match on line INDEX, is the C function: its arguments (read to the call's `)`)
    carry no label and number its C arity, a bare `open` has an `O_*` flag, a `wait*` has no WNOHANG, and no
    declaration in scope shadows the name (`Darwin.` and `open` never are)."""
    name = match.group("free")
    arguments = call_arguments(version, index, match.end() - 1)
    if arguments is None:
        return not match.group("open")
    if any(ARGUMENT_LABEL.match(argument) for argument in arguments):  # C functions take no labels
        return False
    if C_ARITY.get(name, len(arguments)) != len(arguments):
        return False
    joined = " ".join(arguments)
    if match.group("open"):
        return match.group(0).startswith("Darwin.") or O_FLAG.search(joined) is not None
    if name in ("waitpid", "wait4", "waitid") and "WNOHANG" in joined:
        return False
    if match.group(0).startswith("Darwin."):
        return True
    if "posix_shadows" not in version.memo:
        version.memo["posix_shadows"] = declarations_in_scope(version, POSIX_DECLARATION,
                                                              ("function", "bound", "parameter"), False)
    return nearest_declaration(version, version.memo["posix_shadows"], name, index, match.start("free")) is None


def file_manager_calls(version: Version) -> tuple[re.Pattern, dict] | None:
    """`<name>[?!]?.<FILE_OPS>(` for each name VERSION binds to a FileManager, with every declaration of those names
    by scope (declarations_in_scope), or None when it binds none. A `let x = FileManager.default` whose next line
    starts with `.` is a chained call, not a binding."""
    if "file_manager_calls" not in version.memo:
        lines, codes = version.lines, codes_of(version)
        names = set()
        for index, line in enumerate(lines):
            if "FileManager" not in line:
                continue
            for match in FILE_MANAGER_BINDING.finditer(codes[index]):
                if match.group("value") and index + 1 < len(lines) and codes[index + 1].lstrip().startswith("."):
                    continue
                names.add(match.group("value") or match.group("typed"))
        result = None
        if names:
            alternatives = "|".join(sorted(names))
            declared = re.compile(r"\b(?:let|var)\s+(?P<bound>" + alternatives + r")\b"
                                  r"|[(,]\s*(?:\w+\s+)?(?P<parameter>" + alternatives + r")\s*:(?!:)")
            result = (re.compile(r"(?<![\w$])(" + alternatives + r")[?!]?\.(" + FILE_OPS + r")\("),
                      declarations_in_scope(version, declared, ("bound", "parameter"), True))
        version.memo["file_manager_calls"] = result
    return version.memo["file_manager_calls"]


def in_seam_scope(version: Version, index: int, column: int) -> bool:
    """Whether COLUMN of line INDEX runs in a `blockingCall(...) {` or `allowBlocking(...) {` closure of its own
    function: the seam marks the call there, as Chrome's ScopedBlockingCall does."""
    scopes = blocks_of(version)
    for block in scopes.chain(scopes.at(index, column))[:-1]:
        header = scopes.header(block)
        if SEAM_SCOPE.search(header):
            return True
        if OPENER_STOP.search(header):
            return False
    return False


def blocking_ext_match(version: Version, index: int, code: str) -> bool:
    """Whether CODE, line INDEX of VERSION, holds a raw-blocking-ext primitive outside a seam scope: a
    RAW_BLOCKING_EXT call (not a declaration; a free function only as posix_call reads it), or a FileManager disk op
    through a name whose nearest declaration in scope binds a FileManager."""
    if RAW_EXT_SCAN.search(code):
        for match in RAW_BLOCKING_EXT.finditer(code):
            if DECLARED_AT.search(code[:match.start()]):
                continue
            if match.group("free") and not posix_call(version, index, match):
                continue
            if not in_seam_scope(version, index, match.start()):
                return True
    found = file_manager_calls(version) if "." in code else None
    if found is None:
        return False
    calls, declarations = found
    for call in calls.finditer(code):
        declaration = nearest_declaration(version, declarations, call.group(1), index, call.start())
        if declaration is not None and declaration[2] and not in_seam_scope(version, index, call.start()):
            return True
    return False


def raw_blocking_ext(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """Added raw-blocking-ext primitives, on any thread: main-blocking and raw-blocking do not see them."""
    return changed_debt(outside_seams(changes), blocking_ext_match)


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


# once-blocking: a blocking call in a static, lazy or global initializer. Swift runs such an
# initializer once (swift_once), on whichever thread reads the value first, while every other first reader waits
# on the once guard: its disk, kernel or process wait lands on an unknown thread, often the main thread, and no
# seam can say which. Chromium keeps blocking work out of lazy singletons and static initializers for the same
# reason (base/memory/singleton.h, base/lazy_instance.h, ScopedDisallowSingleton in
# base/threading/thread_restrictions.h). The value is loaded on a lane at warm-up and injected, or its accessor
# becomes async. An initializer is a `static`/`class`/`lazy` stored member's or a file-scope `let`/`var`'s value
# expression, through the closures that run inside it: an immediately called `= { ... }()`, the inline calls
# (`map {`, `flatMap {`, `withLock {`) and control flow. A literal blocks nothing; an instance member's
# initializer, a static closure value that is not called (`static let load = { ... }`) and a computed property
# run on every read, where the other blocking rules judge them.
ASSIGNED_CLOSURE_OPENER = re.compile(r"(?<![=!<>])=\s*\{$")
ONCE_DECLARATION = re.compile(r"^\s*(?:" + ATTRIBUTE + r"\s+)*(?P<modifiers>(?:\w+(?:\([^)]*\))?\s+)*?)"
                              r"(?:let|var)\s+`?\w+`?\s*(?::[^=]*)?=(?!=)")
ONCE_MODIFIER = re.compile(r"\b(static|class|lazy)\b")
# A file that may hold one: a `static`, `lazy` or `class let/var` member, or a `let`/`var` at column 0 (file scope;
# the repo's formatter indents every member). Only a prefilter: once_initializer decides.
ONCE_HINT = re.compile(r"\b(?:static|lazy)\s|\bclass\s+(?:let|var)\b|^(?:[@\w][\w()@.]*\s+)*(?:let|var)\s", re.M)
TYPE_BODY_OPENER = re.compile(r"(?:^|[\s)])(?:(?:distributed\s+)?actor|class|struct|enum|extension)\s+"
                              r"(?!(?:func|var|let|subscript|init|deinit|override|static)\b)[A-Za-z_]")
INVOKED_LINES = 400  # how far an assigned closure is followed to its `}()`


def closure_invoked(codes: list[str], index: int, column: int) -> bool:
    """Whether the closure whose `{` is at COLUMN of line INDEX is called where it closes (`}()`)."""
    depth = 0
    for j in range(index, min(len(codes), index + INVOKED_LINES)):
        code = codes[j]
        for pos in range(column if j == index else 0, len(code)):
            if code[pos] == "{":
                depth += 1
            elif code[pos] == "}":
                depth -= 1
                if depth == 0:
                    return code[pos + 1:].lstrip().startswith("(")
    return False


def once_statement(statement: str, holder: str) -> bool:
    """Whether STATEMENT declares a value Swift initializes once, directly in HOLDER (`file`, `type` or `other`): a
    `static`/`class`/`lazy` stored member of a type, or a `let`/`var` at file scope."""
    match = ONCE_DECLARATION.match(statement) if holder != "other" else None
    return bool(match and (holder == "file" or ONCE_MODIFIER.search(match.group("modifiers"))))


def once_initializer(version: Version, index: int, column: int) -> bool:
    """Whether COLUMN of line INDEX runs in a static, lazy or global initializer (once-blocking's reading): the
    blocks around it, innermost first, are control flow, inline-call closures and immediately called `= { }()`
    closures (each runs inside the statement that opens it) up to a type body or the file, whose statement there
    declares a once-initialized value. Each block's answer is kept on VERSION, so a file's lines cost one walk."""
    blocks, codes = blocks_of(version), codes_of(version)
    kinds: dict[int, tuple[str, str]] = version.memo.setdefault("once_kinds", {})
    answers: dict[int, bool] = version.memo.setdefault("once_blocks", {})

    def kind(block: int) -> tuple[str, str]:
        """(`file` | `type` | `inline` | `other`, the statement that opens BLOCK)."""
        if block == -1:
            return "file", ""
        if block not in kinds:
            line, at = blocks.opened[block]
            opener = codes[line][:at + 1]
            if TYPE_BODY_OPENER.search(opener) and not DECLARATION_KEYWORD.search(opener):
                kinds[block] = ("type", "")  # its members' statements are read, not its own
                return kinds[block]
            header = statement_header(version.lines, line + 1, opener)[0]
            if (CONTROL_OPENER.search(header) or INLINE_CLOSURE_CALL.search(opener)
                  or (ASSIGNED_CLOSURE_OPENER.search(opener) and closure_invoked(codes, line, at))):
                kinds[block] = ("inline", header)
            else:
                kinds[block] = ("other", header)  # a function, accessor or closure body: it runs on every call
        return kinds[block]

    def runs_once(block: int) -> bool:
        """Whether code directly in BLOCK's body runs inside a once initializer (BLOCK is `inline`)."""
        if block not in answers:
            holder = blocks.parent[block]
            holder_kind = kind(holder)[0]
            statement = kind(block)[1]
            answers[block] = runs_once(holder) if holder_kind == "inline" else once_statement(statement, holder_kind)
        return answers[block]

    block = blocks.at(index, column)
    block_kind = kind(block)[0]
    if block_kind == "inline":
        return runs_once(block)
    statement = statement_header(version.lines, index + 1, codes[index][:column])[0]
    return once_statement(statement, block_kind)


def may_initialize_once(version: Version) -> bool:
    """Whether VERSION declares anything Swift initializes once (ONCE_HINT), so most files skip the walk."""
    if "once_possible" not in version.memo:
        version.memo["once_possible"] = ONCE_HINT.search("\n".join(codes_of(version))) is not None
    return version.memo["once_possible"]


def blocking_once(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """Added blocking calls (raw, seam or raw-blocking-ext) in a static, lazy or global initializer."""
    def judge(version: Version, index: int, code: str) -> bool:
        if index >= len(version.lines) or not may_initialize_once(version):
            return False
        columns = [m.start() for m in MAIN_SCAN.pattern.finditer(code)] if blocking_match(MAIN_SCAN, code) else []
        if not columns and blocking_ext_match(version, index, code):
            columns = [m.start() for m in RAW_BLOCKING_EXT.finditer(code)] or [len(code)]
        return any(once_initializer(version, index, column) for column in columns)
    return changed_debt(outside_seams(changes), judge)


class LinkedPackage(NamedTuple):
    """A package CmuxNext's app code links: its Package.swift TEXT and the TARGETS of it that code reaches."""
    text: str
    targets: frozenset[str]


def linked_closure(manifest: str, read: Callable[[list[str]], dict[str, str]]) -> dict[str, LinkedPackage]:
    """{package folder: LinkedPackage} of every package under Packages/ whose code runs in the app: the library
    targets that CmuxNext's MANIFEST's `.target`s reach through `.product(name:package:)` (a `.package(path:)`
    resolved against the folder of the manifest that names it), transitively, with each reached target's own
    `.target` dependencies. A `.testTarget`'s products (CmuxFuzzSupport), an `.executableTarget` or `.macro` (a
    separate process: cmux-vnc-host) and a package no reached target uses are not in it; nor is CmuxNext itself.
    READ maps Package.swift paths to their texts (a path it leaves out has no manifest: not a package)."""
    root = PACKAGE_ROOT.rstrip("/")
    graphs = {root: swift_scope.package_graph(manifest)}
    texts: dict[str, str] = {}
    absent: set[str] = set()
    reached: dict[str, set[str]] = {}
    # (folder, product or None, target or product name): a product resolves once its package's manifest is read.
    pending: list[tuple[str, bool, str]] = [(root, False, name) for name in graphs[root].kinds]
    while pending:
        wanted = sorted({folder for folder, _, _ in pending if folder not in graphs and folder not in absent})
        found = read([folder + "/Package.swift" for folder in wanted]) if wanted else {}
        for folder in wanted:
            if folder + "/Package.swift" in found:
                texts[folder] = found[folder + "/Package.swift"]
                graphs[folder] = swift_scope.package_graph(texts[folder])
            else:
                absent.add(folder)
        following: list[tuple[str, bool, str]] = []
        for folder, product, name in pending:
            graph = graphs.get(folder)
            if graph is None:
                continue
            targets = (graph.libraries.get(name, [name] if name in graph.kinds else [])) if product else [name]
            for target in targets:
                if graph.kinds.get(target) != "target" or target in reached.setdefault(folder, set()):
                    continue
                reached[folder].add(target)
                for dependency in graph.dependencies.get(target, []):
                    if dependency.kind == "target" or (dependency.kind == "byName" and dependency.name in graph.kinds):
                        following.append((folder, False, dependency.name))
                        continue
                    path = graph.paths.get((dependency.package or dependency.name).lower())
                    linked = posixpath.normpath(posixpath.join(folder, path)) if path is not None else ""
                    if linked.startswith("Packages/") and linked != root:
                        following.append((linked, True, dependency.name))
        pending = following
    return {folder: LinkedPackage(texts[folder], frozenset(names))
            for folder, names in sorted(reached.items()) if folder != root and names}


def linked_targets(packages: dict[str, LinkedPackage]) -> dict[str, list]:
    """{package folder: its reached targets (swift_scope.Target: name, folder, isolation)} of linked_closure()'s
    PACKAGES."""
    return {folder: [t for t in swift_scope.package_targets(package.text) if t.name in package.targets]
            for folder, package in packages.items()}


def load_linked_packages(manifest: str | None, read: Callable[[list[str]], dict[str, str]]) -> None:
    """Keeps the linked packages of MANIFEST (HEAD's CmuxNext Package.swift; None: none) and their reached targets
    for in_rule_scope() and linked_main_default(). READ is linked_closure()'s."""
    BLOCKING_CONTEXT["linked"] = linked_targets(linked_closure(manifest or "", read))


def linked_package(path: str) -> str | None:
    """The folder of the linked package one of whose reached targets holds PATH (a Swift file), None for any other
    path (and before load_linked_packages())."""
    if not path.endswith(".swift"):
        return None
    for folder, targets in (BLOCKING_CONTEXT.get("linked") or {}).items():
        if path.startswith(folder + "/") and swift_scope.default_isolation(path[len(folder) + 1:], targets) is not None:
            return folder
    return None


def linked_main_default(path: str) -> bool:
    """Whether PATH, a linked package's source file, is main actor by default: its target says
    `.defaultIsolation(MainActor.self)` (no linked package does today)."""
    folder = linked_package(path)
    if folder is None:
        return False
    return bool(swift_scope.default_isolation(path[len(folder) + 1:], BLOCKING_CONTEXT["linked"][folder]))


def load_push_linked_packages(repo: Path, head: str, manifest: str | None, files: list[FileChange]) -> None:
    """Reads HEAD's linked packages when the push changes a Swift source file of a package outside CmuxNext (any
    other push reads no more manifests) and gives each changed file of a linked package its target's default
    isolation, which is not the main actor's."""
    if not any(is_package_swift(f.path) and "/Sources/" in f.path and not f.path.startswith(PACKAGE_ROOT)
               for f in files):
        return

    def read(paths: list[str]) -> dict[str, str]:
        found = blobs(repo, [(head, path) for path in paths])
        return {path: found[(head, path)] for path in paths if (head, path) in found}

    load_linked_packages(manifest, read)
    for change in files:
        if linked_package(change.path) is not None:
            change.head_main = change.base_main = linked_main_default(change.path)


def in_rule_scope(path: str, scope: tuple[str, ...]) -> bool:
    """Whether a rule with SCOPE reads PATH: a path prefix or suffix of SCOPE, or, with LINKED_SOURCES in SCOPE, a
    linked package's source file."""
    return (path.startswith(scope) or path.endswith(scope)
            or (LINKED_SOURCES in scope and linked_package(path) is not None))


def load_blocking_context(texts: dict[tuple[str, str], str], head: str, repo: Path | None = None) -> None:
    """Keeps HEAD's threading doc and package manifest for the rules above (a missing doc fails thread-doc open),
    and, given REPO, names HEAD's tree for pool-blocking's actor index (repo_actor_index reads it on demand)."""
    for key in ("threading_doc", "manifest", "ui_targets", "actor_tree", "actor_index", "linked"):
        BLOCKING_CONTEXT.pop(key, None)
    for key, path in (("threading_doc", THREADING_DOC), ("manifest", PACKAGE_MANIFEST)):
        if (head, path) in texts:
            BLOCKING_CONTEXT[key] = texts[(head, path)]
    if repo is not None:
        BLOCKING_CONTEXT["actor_tree"] = (repo, head)

BLOCKING_RULES = (
    Rule("main-blocking", "A blocking call on the main thread (file I/O, a socket read, a wait, a process launch or wait, a "
         "synchronous system call or a sync hop directly in main-actor code; `DispatchQueue.main.sync`, `Thread.sleep`, `usleep` anywhere)",
         "the main thread never blocks (plans/cmux-next/threading-model.md, Chrome's ScopedBlockingCall): one disk, "
         "lock or process wait on it drops frames and delays the next input; in Debug the runtime detector reports it",
         "move the work off the main thread (an actor, `Task.detached`, a `nonisolated` async function, the daemon) "
         "and apply its result on main; a wait becomes an `await` or a callback. The checked seams "
         "(`FileManager.checked`, `Data(blockingContentsOf:)`, `.blockingWait()`) are for code that runs off main",
         "// blocking-allow: <why this cannot leave the main thread, and its reviewed allowBlocking reason>",
         blocking_on_main, scope=LINKED_RULE_SCOPE),
    Rule("raw-blocking", "A raw blocking primitive (file read/write, `.write(to:)`, `FileManager.default.<disk op>`, "
         "`.wait()`, `.sync {`, `asyncAndWait`, `waitUntilExit()`, `readToEnd()`, `try process.run()`, sync XPC, "
         "`posix_spawn`, `fork()`, pthread and condition-lock waits, Security, AX, `getaddrinfo`, CGWindowList, "
         "LSCopy, NSWorkspace app and icon queries, SMAppService, AuthorizationCopyRights, AppleScript) instead of its "
         "checked seam",
         "the runtime detector sees only the seams in CmuxNextCompat/Threading and CmuxNextCompatAppKit/Threading: a "
         "raw call that later runs on the main thread blocks it unseen",
         "use the seam: `FileManager.checked.<op>`, `Data(blockingContentsOf:)`, `String(blockingContentsOf:)`, "
         "`url.blockingResourceValues`, `handle.blockingReadToEnd()`, `semaphore.blockingWait()`, "
         "`queue.blockingSync`, `process.blockingWaitUntilExit()`, `process.blockingRun()`, "
         "`blockingRead/Recv/Write/Send`, `blockingSecItem*`, `blockingAX*`, `blockingGetaddrinfo`, "
         "`blockingWindowList*`, `workspace.blockingURLForApplication/blockingIcon` (import CmuxNextCompatAppKit), "
         "`blockingSMAppService*`, "
         "`blockingAuthorizationCopyRights`; with no seam (sync XPC proxy, AppleScript, condition locks, "
         "`asyncAndWait`, LSCopy) use the async API. In a linked Shared/iOS package, wrap it in CmuxThreading's "
         "`blockingCall(.fileIO | .systemCall | ...) { ... }` and run it through the package's MayBlockRunner",
         "// blocking-allow: <why the seam does not fit>",
         raw_blocking, scope=LINKED_RULE_SCOPE),
    Rule("pool-blocking", "A blocking call (raw or seam) on a shared pool thread: in a `Task.detached` or child task "
         "body or an `async let` initializer, a `Task {` in a nonisolated function, an @concurrent function, or a method of an actor that has no "
         "custom executor",
         "the Swift cooperative pool has one thread per core and the GCD root queues are shared: a blocked pool "
         "thread stalls every async job queued behind it (Chrome's ThreadPool runs a task without MayBlock() under "
         "ScopedDisallowBlocking, base/task/thread_pool/task_tracker.cc)",
         "run it on a BackgroundWork lane (`work.run(priority, mayBlock: .files|.system) { ... }`, or a "
         "MayBlockRunner below CmuxNextWakeups or in a linked Shared/iOS package, CmuxThreading's); an actor whose "
         "methods block gets a serial executor on a named "
         "queue at its QoS (`nonisolated var unownedExecutor`, the HomeCache pattern; a comment is no executor)",
         "// blocking-allow: <why this blocking call may hold a pool thread>",
         blocking_on_pool, scope=LINKED_RULE_SCOPE),
    Rule("raw-blocking-ext", "A blocking primitive raw-blocking does not name: a FileManager disk op through a "
         "variable or `FileManager()`, POSIX file calls (`open(..., O_*)`, `stat(path, &st)`, `rename`, `unlink`, "
         "`fsync`, `flock`, `realpath`, ...), `waitpid` without WNOHANG, FileHandle open/write/read/seek/synchronize, "
         "ImageIO URL I/O, `sqlite3_*`, `sysctl`, `proc_pid*`, `canEvaluatePolicy`, `getpw*`, `Host.current()`",
         "each is disk, kernel or daemon I/O the runtime detector cannot see: on the main thread it drops frames "
         "unseen, and off it nobody knows the thread blocks",
         "from code that runs off the main thread, use `FileManager.checked.<op>` instead of a FileManager variable, "
         "`handle.blockingRead(upToCount:)` / `handle.blockingWrite(contentsOf:)` for a FileHandle, and wrap any "
         "other call in `blockingCall(.fileIO | .systemCall | .processWait) { ... }` (CmuxNextCompat/Threading; in a "
         "linked Shared/iOS package, CmuxThreading's `blockingCall`)",
         "// blocking-allow: <why the seam does not fit>",
         raw_blocking_ext, scope=LINKED_RULE_SCOPE),
    Rule("maybe-main-blocking", "A blocking call in a caller-isolated async function (warning only)",
         "under NonisolatedNonsendingByDefault a non-@concurrent async function outside an actor runs on its caller's "
         "executor, so a main-actor caller runs the blocking call on main (AsyncProcess.run: 807 ms, 2026-10-24)",
         "mark the function `@concurrent` (or move the work into an actor) so it never runs on the caller's main thread",
         "// blocking-allow: <why every caller is off the main thread>",
         maybe_blocking_on_main, scope=LINKED_RULE_SCOPE),
    Rule("once-blocking", "A blocking call (raw, seam or raw-blocking-ext) in a static, lazy or global initializer",
         "Swift runs the initializer once, on whichever thread reads the value first, and every other first reader "
         "waits for it: its disk, kernel or process wait lands on an unknown thread, often the main thread "
         "(Chromium keeps blocking work out of lazy singletons: base/memory/singleton.h, base/lazy_instance.h)",
         "load the value on a lane at warm-up (`work.run(.userVisible, mayBlock: .files) { ... }`) and inject it "
         "where it is read, or make its accessor `async`; a literal value needs no load",
         "// blocking-allow: <why no reader can be the main thread or wait on it>",
         blocking_once, scope=LINKED_RULE_SCOPE),
    Rule("thread-doc", "A new thread, queue or blocking allowance that plans/cmux-next/threading-model.md does not list",
         "every thread and queue has an owner, a QoS, a bound and a back-pressure rule written down, and every "
         "main-thread blocking allowance is reviewed (Chrome's ScopedAllowBlocking friend list)",
         "name the thread or queue and add its label to the doc's \"Registered threads and queues\" (and a table row "
         "for a new kind); add a new BlockingAllowance to \"Reviewed blocking allowances\" in the same push",
         "// blocking-allow: <why this thread needs no entry>",
         undocumented_threads, scope=LINKED_RULE_SCOPE),
)
RULES += BLOCKING_RULES
# ---------------------------------------------------------------- end of main-blocking / thread-doc (PL-blocking)


# ---- awaited-low-priority (PL-qos)
# A task started below the person's priority (`Task(priority: .low|.utility|.background)`, `Task.detached(priority:`
# the same, `work.task(.bestEffort|.idle)`) whose `.value` or `.result` main-actor code awaits is a latency inversion:
# the task waits behind work nobody waits for until the await, and Swift's escalation only raises it from the await on
# (WorkPriority.idle's doc). Chrome posts work a person waits for at USER_BLOCKING (base/task/task_traits.h) and raises
# a queued sequence when that changes (base/task/updateable_sequenced_task_runner.h); cmux's recipe is the same: start
# the work at the waiter's priority, or keep a `work.runHandle` and raise it (task 117). Judged lexically, on the
# creation line: awaited at once (`await Task.detached(priority: .utility) { ... }.value`), through a local the same
# function awaits, or through a stored property (`self.x =`, a property initializer) that a method of the same type
# in the file awaits; the await must run on main (main-actor code, a `Task {` or inline closure in it, or
# `MainActor.run {`). A fire-and-forget task, a handle returned or passed on, and an await off main pass.
LOW_TASK = re.compile(r"(?<![\w$])Task(?:\s*<[^>{}]*>)?(?:\.detached)?\s*\(\s*priority:\s*(?:TaskPriority)?\."
                      r"(?:low|utility|background)\b"
                      r"|(?:(?<![\w$.])(?:\w+[?!]?\s*\.\s*)*\w+[?!]?\s*)?\.task\(\s*(?:WorkPriority)?\.(?:bestEffort|idle)\b")
PRIORITY_ALLOW = re.compile(r"//\s*priority-allow:\s*\S")
AWAIT_BEFORE = re.compile(r"\bawait\s*\(?\s*$")
LOCAL_BINDING = re.compile(r"\b(?:let|var)\s+`?(\w+)`?\s*(?::[^=]+)?=\s*(?:try[?!]?\s+)?$")
ASSIGNED_TO = re.compile(r"(?:^|[^\w.$])(self\s*\.\s*)?`?(\w+)`?\s*=\s*$")


NO_STOP = re.compile(r"(?!)")  # enclosing_openers to the file's top level


def awaits_on_main(version: Version, index: int, prefix: str) -> tuple[bool, list[int]]:
    """(whether the await at PREFIX's end on VERSION's line INDEX runs on the main actor: directly in main-actor code,
    in a `Task {` or an inline closure (`map`, `withLock`, ...) that keeps that isolation, or in a main opener; the
    1-based lines that decided it: each opener walked, its whole header, and the line that set the declaration's
    isolation). A detached, queue or escaping closure, an actor and a nonisolated function are off main. The
    isolation is the declaration's, read on its opener line: the await's own line may open a `Task.detached` after
    it."""
    default_main = module_of(version.path) in ui_targets()
    if "main_scopes" not in version.memo:
        version.memo["main_scopes"] = main_actor_scope().main_actor_scopes(version.lines, default_main)
    read: list[int] = []
    for opener, number in enclosing_openers(version.lines, index, OPENER_STOP, prefix):
        header = block_header(version.lines, number, opener) if number - 1 != index else opener
        read.extend(range(header_start(version.lines, number), number + 1) if number - 1 != index else (number,))
        if MAIN_OPENER.search(opener) or MAIN_OPENER.search(code_of(version.lines[number - 1])):
            return True, read
        if DECLARATION_OPENER.search(header):
            # The headers of the types around it too: `nonisolated final class S {` -> `final class S {` moves it.
            for _, outer in enclosing_openers(version.lines, number - 1, NO_STOP):
                read.extend(range(header_start(version.lines, outer), outer + 1))
            main, source = version.memo["main_scopes"][number - 1]
            return main, read + ([source] if source else [])
        # The opener alone too: block_header joins a statement that ends in `)` to the `if ... {` below it.
        if not any(p.search(text) for p in (CONTROL_OPENER, TASK_INHERITS, INLINE_CLOSURE_CALL) for text in (header, opener)):
            return False, read
    return default_main, read


def handle_scope(version: Version, index: int, column: int, prefix: str) -> tuple[str, tuple[int, ...]] | None:
    """(name, blocks) of the handle that the task created at COLUMN of line INDEX (PREFIX: the code before it) is
    stored in: a local's declaring block, or a stored property's type body and that type's extensions in the file.
    None when nothing in this file keeps it (fire-and-forget, `return`, an argument, a member of another value)."""
    local = LOCAL_BINDING.search(prefix)
    assigned = None if local else ASSIGNED_TO.search(prefix)
    if local is None and assigned is None:
        return None
    name = local.group(1) if local else assigned.group(2)
    blocks, codes = blocks_of(version), codes_of(version)
    chain = blocks.chain(blocks.at(index, column))[:-1]
    types = [b for b in chain if TYPE_NAME.search(blocks.header(b)) and not CONTROL_OPENER.search(blocks.header(b))]
    if local is not None and chain[:1] != types[:1]:
        return name, (chain[0],)
    if assigned is not None and not assigned.group(1):
        # `name =`: a `var name` declared in the enclosing function keeps the handle local.
        function = next((b for b in chain if b not in types and DECLARATION_OPENER.search(blocks.header(b))), None)
        declared = re.compile(r"\b(?:var|let)\s+`?" + re.escape(name) + r"`?\b")
        if function is not None:
            inside = chain[:chain.index(function) + 1]
            for j in range(blocks.opened[function][0], index + 1):
                found = declared.search(codes[j])
                if found and blocks.at(j, found.start()) in inside:
                    return name, (blocks.at(j, found.start()),)
    if not types:
        return None
    line, at = blocks.opened[types[0]]
    return name, blocks.declaration_scope(line, at + 1, None)


def awaited_low_task(version: Version, index: int) -> tuple[bool, list[int]]:
    """(a low-priority task created on line INDEX is awaited on main (the section comment), the 1-based lines that
    judgement read: each await of its handle and the openers, headers and isolation lines that place that await on
    or off main. A push that touches one rejudges the unchanged creation line: it adds an await, or drops the
    `nonisolated`, `@concurrent`, `actor` or `Task.detached {` that kept an old await off main)."""
    code = code_of(version.lines[index])
    blocks, codes = blocks_of(version), codes_of(version)
    debt, lines = False, []
    for match in LOW_TASK.finditer(code):
        prefix, at = code[:match.start()], index
        if not prefix.strip() and index > 0:  # `let page =` / `await` ends the line above
            prefix, at = codes[index - 1], index - 1
        if AWAIT_BEFORE.search(prefix[max((m.end() for m in STATEMENT_START.finditer(prefix)), default=0):]):
            main, read = awaits_on_main(version, at, prefix)
            debt, lines = debt or main, lines + read
            continue
        scope = handle_scope(version, index, match.start(), prefix)
        if scope is None:
            continue
        name, kept_in = scope
        site = re.compile(r"(?<![\w$.])(?:self\s*\.\s*)?`?" + re.escape(name) + r"`?\s*[?!]?\s*\.\s*(?:value|result)\b")
        for j, line in enumerate(codes):
            if j == index or name not in line:
                continue
            for found in site.finditer(line):
                head = line[:found.start()]
                if not AWAIT.search(head[max((m.end() for m in STATEMENT_START.finditer(head)), default=0):]):
                    continue
                if not set(kept_in) & set(blocks.chain(blocks.at(j, found.start()))):
                    continue
                main, read = awaits_on_main(version, j, head)
                debt, lines = debt or main, lines + [j + 1] + read
    return debt, lines


AWAITED_LOW_PRIORITY_RULES = (
    Rule("awaited-low-priority", "A task started at `.low`/`.utility`/`.background` (or `work.task(.bestEffort|.idle)`) "
         "whose `.value` or `.result` main-actor code awaits: at once, through a local or through a stored property",
         "the task queues behind work nobody waits for until main awaits it, and the await raises it only from then on: "
         "the person waits for best-effort work (priority inversion; plans/cmux-next/chrome-parity/p02-threads.md D, R8)",
         "start the task at the waiter's priority (`work.task(.userBlocking)` for an input's result, `.userVisible` for "
         "what shows soon), or keep a `work.runHandle` and raise it when main awaits (task 117); fire-and-forget work "
         "keeps its low priority and nothing awaits it",
         "// priority-allow: <why main may wait for this low-priority work>",
         matcher_rule(Matcher(LOW_TASK, PRIORITY_ALLOW, awaited_low_task))),
)
RULES += AWAITED_LOW_PRIORITY_RULES


# ---------------------------------------------------------------- quality ratchet
# The code-quality ratchet (cmux-ad's quality audit of perf/chrome-parity, 2026-10-29, order 1): five line rules over
# every package (Packages/*/Sources and Packages/*/Tests, not only CmuxNext), and one record rule for their baseline.
# A push may not ADD (a) a carve-out (`nonisolated(unsafe)`, `@unchecked Sendable`, a new lock, a GCD main hop or
# `asyncAfter`) without a justification comment, (b) a `static let/var shared` singleton in package Sources, (c) a
# sleep in product Sources without a justification comment, (d) a test that reads source or project files
# (skills/cmux-testing/references/regression-and-quality.md: such a test asserts shape, not behavior) or (e) a new
# product Swift file with two or more top-level types. Where another check already refuses a pattern before the push
# (in CmuxNext's Sources: unchecked-sendable, main-async and check-concurrency.sh's locks, asyncAfter, main.sync and
# sleeps), this block does not judge it again (CARVE_OUT_OWNED, product_sleep_source).
#
# A justification comment is the escape form CLAUDE.md gives (`// concurrency-allow:`, `// crash-allow:`): any
# `// <tag>-allow: <reason>` on the line, in the comment block directly above it, or trailing the code line above
# (escape_window), so a line another rule already escapes (`// main-async-allow:`, `// wakeup-allow:`) needs no
# second comment. (b) has no inline escape: CMUX_GUARDRAILS_SKIP_REASON, said in the report, is its only skip.
#
# The count: per changed file, every hit of the file at head against every hit at base, paired by text and then by
# count (resolve(), as trap-api does), so an edit of a line that already had the debt adds none and a removed
# escape is new debt; a hit whose text another file of the push removes is a move.
# The baseline: plans/cmux-next/quality-ratchet.json lists, per rule and file, a short hash of every hit at the rev
# it was measured on (`guardrails.py --quality-baseline --write`). A hit the base does not have is still no new
# debt when the baseline lists its text for that file and the base has fewer of it: so a push to
# origin/feat-cmux-next that brings perf/chrome-parity's old lines (a slice) passes, and a removed old line can come
# back only as the same line, never as another one. The json comes from the push's base, or, when the base has
# none (the first push of the file, a slice onto a base without it), from the push's first commit that adds it, never
# from the head (quality_reference): a json rewritten after new debt lists that debt, and `quality-baseline` refuses
# a head json with a site its reference lacks, so the baseline only goes down. A reference that does not parse
# allows nothing, and so does a base without the json when no commit of the push adds it (the base deleted it).
# Trusted by design: the commit that first adds the json is trusted as written. Its sites are the baseline for the
# whole push, so debt that this commit, or an earlier commit of the same push, adds and lists passes as old. That
# trust is what lets a slice of perf/chrome-parity (the json's own branch) onto origin/feat-cmux-next bring its old
# lines; a reviewer of a push that adds the json checks that the json was measured at the push's base side
# (`measured_rev`), not after new debt. Local only, like every guardrail.
# The block owns its lines from here to `RULES += QUALITY_RULES`.
QUALITY_BASELINE = "plans/cmux-next/quality-ratchet.json"
QUALITY_MEMO = "quality-baseline"
JUSTIFIED = re.compile(r"//\s*[a-z][a-z0-9]*(?:-[a-z0-9]+)*-allow:\s*\S")
JUSTIFIED_ESCAPE = "// <tag>-allow: <the reason> (any CLAUDE.md escape tag: concurrency-allow, crash-allow, ...)"
CARVE_OUT = re.compile(
    r"\bnonisolated\s*\(\s*unsafe\s*\)|@unchecked\s+Sendable\b"
    r"|\bNS(?:Recursive|Condition)?Lock\s*\(|\bos_unfair_lock(?:_s)?\s*\(\s*\)|\bOSAllocatedUnfairLock\b(?:\s*<[^()]*>)?\s*\("
    r"|\bpthread_mutex_init\s*\(|\bMutex\b(?:\s*<[^()]*>)?\s*\("
    r"|\bDispatchQueue\.main\.(?:async|sync)\b|\.asyncAfter\s*\(")
# In CmuxNext's Sources other checks already refuse these, each with its own escape, so they are not judged again
# here: unchecked-sendable (`// crash-allow:`), main-async (`// main-async-allow:`) and check-concurrency.sh, run by
# the gate before the push (`// concurrency-allow:`: NSLock, NSConditionLock, os_unfair_lock, asyncAfter, main.sync).
CARVE_OUT_OWNED = re.compile(r"\bnonisolated\s*\(\s*unsafe\s*\)|@unchecked\s+Sendable\b|\bDispatchQueue\.main\.(?:async|sync)\b"
                             r"|\bNS(?:Recursive)?Lock\(|\bNSConditionLock\(|\bos_unfair_lock|\basyncAfter\(")
STATIC_SHARED = re.compile(r"\b(?:static|class)\s+(?:let|var)\s+shared\b")
# check-concurrency.sh's SLEEP_CALL (Task.sleep, a clock's `.sleep(for:/until:)`, an awaited injected sleeper).
PRODUCT_SLEEP = re.compile(r"\bTask\.sleep\s*\(|\.sleep\s*\(\s*(?:for|until):|\bclock\.sleep\b"
                           r"|\bawait\s+(?:[A-Za-z_]\w*\??\.)*sleep\(")
# A test file reads the repository when it locates it (`#filePath`, a `packageRoot` / `repoRoot` /
# `repositoryRoot`) and reads a file or lists a folder; each line that names a source or project file there is a hit.
REPO_LOCATOR = re.compile(r"#filePath\b|#file\b|\b[a-z]*(?:[pP]ackage|[rR]epo|[rR]epository|[sS]ources?)Root\b")
FILE_READ = re.compile(r"\bString\s*\(\s*contentsOf|\bData\s*\(\s*contentsOf|contentsOfFile:|\.contents\s*\(\s*atPath"
                       r"|\.enumerator\s*\(\s*at|contentsOfDirectory\s*\(|subpathsOfDirectory\s*\(|\.subpaths\s*\(\s*atPath")
SOURCE_REFERENCE = re.compile(
    r"\b(?:appendingPathComponent|appending)\s*\(\s*(?:path:\s*)?\"[^\"]*\bSources\b"
    r"|\bpathExtension\s*==\s*\"swift\"|\bhasSuffix\s*\(\s*\"\.swift\"\s*\)"
    r"|\"[^\"]*/[^\"]*\.(?:swift|h|hpp|cc|cpp|m|mm|rs)\""
    r"|\"[^\"]*(?:Package\.swift|\.pbxproj|\.xcconfig|\.entitlements|Info\.plist)\"")
GENERATED_HEADER = re.compile(r"\bGENERATED\b|\bDo not edit\b|@generated", re.IGNORECASE)


def product_sleep_source(path: str) -> bool:
    """product_source(PATH) outside CmuxNext's Sources, where check-concurrency.sh already refuses a sleep without
    `// wakeup-allow:` before the push."""
    return product_source(path) and not path.startswith(SOURCES)


def product_source(path: str) -> bool:
    """PATH is a Swift file of a package's product Sources (not a `...TestSupport` target, not under Tests)."""
    if not (path.startswith("Packages/") and path.endswith(".swift") and "/Sources/" in path and "/Tests/" not in path):
        return False
    target = path.split("/Sources/", 1)[1].split("/", 1)[0]
    return not target.endswith("TestSupport")


def package_test(path: str) -> bool:
    """PATH is a Swift file of a package's Tests."""
    return path.startswith("Packages/") and path.endswith(".swift") and "/Tests/" in path


def justified(lines: list[str], index: int) -> bool:
    return any(JUSTIFIED.search(lines[j]) for j in escape_window(lines, index))


def code_hits(pattern: re.Pattern, escape: bool) -> Callable[[str, list[str]], list[Added]]:
    """The lines of a file whose code (comments dropped, strings blanked) matches PATTERN, less the justified ones
    when ESCAPE."""
    def hits(path: str, lines: list[str]) -> list[Added]:
        return [Added(path, i + 1, line) for i, line in enumerate(lines)
                if pattern.search(line) and pattern.search(code_of(line)) and not (escape and justified(lines, i))]
    return hits


def carve_out_hits(path: str, lines: list[str]) -> list[Added]:
    """code_hits(CARVE_OUT), less, in CmuxNext's Sources, the lines whose only carve-out another rule owns."""
    found = code_hits(CARVE_OUT, escape=True)(path, lines)
    if not path.startswith(SOURCES):
        return found
    return [a for a in found if CARVE_OUT.search(CARVE_OUT_OWNED.sub(" ", code_of(a.text)))]


def source_test_hits(path: str, lines: list[str]) -> list[Added]:
    """The lines of a test file that name a source or project file, when the file locates the repository and reads
    a file or lists a folder (the strings matter here, so the raw line is read; comment lines are not)."""
    code = [line if code_of(line).strip() else "" for line in lines]
    text = "\n".join(code)
    if not (REPO_LOCATOR.search(text) and FILE_READ.search(text)):
        return []
    return [Added(path, i + 1, lines[i]) for i, line in enumerate(code)
            if line and SOURCE_REFERENCE.search(line) and not justified(lines, i)]


def extra_types(path: str, lines: list[str]) -> list[Added]:
    """The declaration lines of a file's top-level types after its first one, less justified ones. A private or
    fileprivate helper of at most PRIVATE_TYPE_MAX source lines does not count (app-type's helper rule), and a
    generated file (a GENERATED / Do not edit header) or one whose braces the scan cannot follow has none."""
    if any(GENERATED_HEADER.search(line) for line in lines[:5]):
        return []
    scan = QUALITY_TYPE_SCAN(lines)
    if scan.problem is not None:
        return []
    counted = []
    for decl in type_decls(lines, scan.rows).types:
        if decl.nested:
            continue
        source = sum(1 for j in range(decl.first, decl.end) if scan.rows[j][1] and scan.rows[j][3].strip())
        if decl.private and source <= PRIVATE_TYPE_MAX:
            continue
        counted.append(decl)
    return [Added(path, d.decl + 1, lines[d.decl]) for d in counted[1:] if not justified(lines, d.decl)]


# app-type's scan, bound once: a fault there (or a test's stand-in for it) turns off app-type alone, as app-type's
# own tests require; this rule then fails open on its own.
QUALITY_TYPE_SCAN = type_scan


def site_key(text: str) -> str:
    """The baseline's name for a hit: a short hash of its debt_key (text compared as resolve() compares it)."""
    return hashlib.sha1(debt_key(text).encode()).hexdigest()[:12]


@dataclass(frozen=True)
class QualityKind:
    rule: str
    applies: Callable[[str], bool]
    hits: Callable[[str, list[str]], list[Added]]
    new_files_only: bool = False


QUALITY_KINDS = (
    QualityKind("carve-out", product_source, carve_out_hits),
    QualityKind("static-shared", lambda p: p.startswith("Packages/") and "/Sources/" in p and p.endswith(".swift"),
                code_hits(STATIC_SHARED, escape=False)),
    QualityKind("product-sleep", product_sleep_source, code_hits(PRODUCT_SLEEP, escape=True)),
    QualityKind("source-reading-test", package_test, source_test_hits),
    QualityKind("multi-type-file", product_source, extra_types, new_files_only=True),
)


def quality_baseline_sites(text: str | None) -> dict[str, dict[str, collections.Counter]] | None:
    """{rule: {path: Counter(site key)}} of a quality-ratchet.json text; None for no file or one that does not parse."""
    if text is None:
        return None
    try:
        data = json.loads(text)
        return {rule: {path: collections.Counter(keys.split()) for path, keys in files.items()}
                for rule, files in data.get("sites", {}).items()}
    except (ValueError, AttributeError, TypeError):
        return None


def quality_reference(memo: tuple[str | None, str | None]) -> str | None:
    """The baseline text a push is judged against: the base's json, or, when the base has none, the json as the
    push's first commit that adds it wrote it (quality_origin). Never the head's: a push onto a base without the
    file that reruns `--write` after adding debt would otherwise list its own new debt as old."""
    base_text, origin_text = memo
    return base_text if base_text is not None else origin_text


def quality_allowance(changes: list[FileChange], rule: str) -> dict[str, collections.Counter]:
    """{path: site keys the baseline lists for RULE} (quality_reference). A reference that does not parse allows
    nothing."""
    for change in changes:
        sites = quality_baseline_sites(quality_reference(change.memo.get(QUALITY_MEMO, (None, None))))
        return (sites or {}).get(rule, {})
    return {}


def quality_origin(repo: Path, base: str, head: str, head_text: str | None) -> str | None:
    """The baseline json as the first commit of BASE..HEAD that adds it wrote it. None (nothing old is allowed)
    when HEAD has none, and when no commit of the range adds it (the base deleted it after the branch was made):
    the head's own json is never the reference."""
    if head_text is None:
        return None
    added = git(repo, "log", "--diff-filter=A", "--format=%H", "--reverse", f"{base}..{head}", "--",
                QUALITY_BASELINE, check=False).split()
    if not added:
        return None
    return blobs(repo, [(added[0], QUALITY_BASELINE)]).get((added[0], QUALITY_BASELINE))


def quality_rule(kind: QualityKind) -> Callable[[list[FileChange], collections.Counter], list[Added]]:
    def find(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
        judged = [c for c in changes if kind.applies(c.path) and (c.added or c.removed)]
        found, base_keys = [], {}
        for change in judged:
            base = kind.hits(change.path, change.base_lines) if change.base_lines != [""] else []
            if kind.new_files_only and change.base_lines != [""]:
                # An existing file adds nothing here; its types removed at head may pay for a move into a new file.
                head_keys = collections.Counter(debt_key(a.text) for a in kind.hits(change.path, change.head_lines))
                kept = []
                for line in base:
                    if head_keys[debt_key(line.text)] > 0:
                        head_keys[debt_key(line.text)] -= 1
                    else:
                        kept.append(line)
                found.append(([], kept))
            else:
                head = [] if change.is_deleted else kind.hits(change.path, change.head_lines)
                found.append((head, base))
            base_keys[change.path] = collections.Counter(site_key(r.text) for r in base)
        left = resolve(found)
        allowance = quality_allowance(judged, kind.rule)
        hits = []
        for hit in left:
            spare = allowance.get(hit.path, collections.Counter()) - base_keys.get(hit.path, collections.Counter())
            key = site_key(hit.text)
            if spare[key] > 0:
                allowance[hit.path] = allowance[hit.path] - collections.Counter({key: 1})
            else:
                hits.append(hit)
        return hits
    return find


def quality_baseline_raise(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    """quality-ratchet.json gains a site over its reference (quality_reference: the base's json, else the one the
    push's first commit that adds it wrote), or the reference does not parse."""
    hits = []
    for change in changes:
        if change.path != QUALITY_BASELINE or change.is_deleted:
            continue
        reference = quality_reference(change.memo.get(QUALITY_MEMO, (None, None)))
        if reference is None:
            continue
        base = quality_baseline_sites(reference)
        if base is None:
            hits.append(Added(change.path, 1, "the base's quality baseline does not parse; fix it in its own push"))
            continue
        head = quality_baseline_sites("\n".join(change.head_lines))
        if head is None:
            hits.append(Added(change.path, 1, "the file does not parse as the quality baseline"))
            continue
        for rule in sorted(head):
            for path in sorted(head[rule]):
                extra = head[rule][path] - base.get(rule, {}).get(path, collections.Counter())
                if extra:
                    hits.append(Added(change.path, 1, f"{rule} {path}: {sum(extra.values())} more site(s)"))
    return hits


def quality_counts(repo: Path, rev: str) -> dict:
    """The baseline json for REV: every hit of each rule in every package Swift file (multi-type-file: in every
    product file, as if each were new)."""
    listed = git(repo, "ls-tree", "-r", "--name-only", rev, "--", "Packages").split("\n")
    paths = sorted(p for p in listed if p and any(kind.applies(p) for kind in QUALITY_KINDS))
    texts = blobs(repo, [(rev, p) for p in paths])
    sites: dict[str, dict[str, str]] = {kind.rule: {} for kind in QUALITY_KINDS}
    for path in paths:
        lines = texts.get((rev, path), "").split("\n")
        for kind in QUALITY_KINDS:
            if kind.applies(path) and (found := kind.hits(path, lines)):
                sites[kind.rule][path] = " ".join(sorted(site_key(h.text) for h in found))
    return {
        "_doc": "The quality ratchet's baseline (scripts/cmux-next/guardrails.py, block `quality ratchet`): per rule "
                "and file, the short hashes (site_key) of every existing hit, space-separated. A hit the push's base lacks but this file lists for its "
                "file is old debt, not new. Only `guardrails.py --quality-baseline --write` writes it, and a push may "
                "only remove sites (rule quality-baseline). Never CI.",
        "measured_rev": git(repo, "rev-parse", rev).strip(),
        "counts": {rule: sum(len(v.split()) for v in files.values()) for rule, files in sites.items()},
        "files": {rule: len(files) for rule, files in sites.items()},
        "sites": sites,
    }


QUALITY_RULES = (
    Rule("carve-out", "A carve-out without a justification comment in package Sources: `nonisolated(unsafe)`, "
         "`@unchecked Sendable`, a new lock (`NSLock`, `os_unfair_lock`, `OSAllocatedUnfairLock`, `Mutex`), "
         "`DispatchQueue.main.async` / `.sync` or `.asyncAfter` (in CmuxNext's Sources only the locks other checks do "
         "not judge: `Mutex`, `OSAllocatedUnfairLock`, `pthread_mutex_init`)",
         "each switches off a check (the data-race checker, the main-thread scheduler's classes) or adds a wait; "
         "without a written reason nobody can review it (CLAUDE.md: an escape comment needs a reason that proves the "
         "code is safe; quality audit 2026-10-29: 68 % of perf's carve-outs had none)",
         "an actor or a Sendable value type instead of the lock or the unchecked conformance; recipe R-hop instead of "
         "a GCD main hop; an injected Clock or a MainDeadline instead of asyncAfter. When it must stay, write why on "
         "the line or directly above: `// concurrency-allow: <why>` (`// crash-allow:` for an unchecked conformance; "
         "any `// <tag>-allow: <reason>` counts)",
         JUSTIFIED_ESCAPE, quality_rule(QUALITY_KINDS[0]), scope=("Packages/",), local_only=True),
    Rule("static-shared", "A new `static let shared` / `static var shared` singleton in package Sources",
         "a process-wide instance no owner constructs or injects: tests share its state and nothing can replace it "
         "(CLAUDE.md package design discipline; the arch ratchet's stateful-singleton row counts only stateful types)",
         "construct the instance at the composition root and pass it in (an init parameter or an environment value)",
         None, quality_rule(QUALITY_KINDS[1]), scope=("Packages/",), local_only=True),
    Rule("product-sleep", "A `Task.sleep` / clock sleep in product package Sources outside CmuxNext (check-concurrency.sh "
         "judges CmuxNext's) without a justification comment",
         "a sleep is a wakeup, and a sleep that waits for a state hides a race (REVIEW-STANDARD.md: sleeps and polls "
         "that hide a race are hacks)",
         "wait for the event (a stream, a continuation, a store waiter); a deadline uses MainDeadline or Deadline, a "
         "retry Backoff; a bounded, cancellable delay through an injected Clock says why on the line or directly "
         "above: `// wakeup-allow: <deadline|backoff|bounded|...> <reason>`",
         JUSTIFIED_ESCAPE, quality_rule(QUALITY_KINDS[2]), scope=("Packages/",), local_only=True),
    Rule("source-reading-test", "A test that reads source or project files (a test file that finds the repository "
         "through `#filePath` or a package/repo root, reads files, and names a Swift, C or project file or a Sources "
         "folder)",
         "it asserts the code's shape, not its behavior, and passes while the bug is live "
         "(skills/cmux-testing/references/regression-and-quality.md)",
         "test the behavior through the code (call the type, drive the store, run the built tool); a rule about source "
         "text belongs in guardrails.py or a check script, not in a Swift test; a fixture tree under a temporary folder "
         "that only names Sources says so with a justification comment",
         JUSTIFIED_ESCAPE, quality_rule(QUALITY_KINDS[3]), scope=("Packages/",), local_only=True),
    Rule("multi-type-file", "A new product Swift file with two or more top-level types (a private or fileprivate "
         f"helper of at most {PRIVATE_TYPE_MAX} source lines does not count)",
         "one major type per file keeps files small and findable and keeps every edit from re-reading unrelated "
         "types (CLAUDE.md; quality audit 2026-10-29: 15.6 % of perf's new files, 9.8 % of trunk's)",
         "put each type in its own file named after it; a small helper can be private beside its user",
         JUSTIFIED_ESCAPE, quality_rule(QUALITY_KINDS[4]), scope=("Packages/",), local_only=True),
    Rule("quality-baseline", f"{QUALITY_BASELINE} gains a site",
         "the baseline lists old debt that a push may bring back as it was; a new site would let new debt in",
         "never add a site by hand: fix the code, and rerun `scripts/cmux-next/guardrails.py --quality-baseline "
         "--write` only after a push that removes debt, to drop its sites; a json written after new debt is refused",
         None, quality_baseline_raise, scope=(QUALITY_BASELINE,), local_only=True),
)
RULES += QUALITY_RULES
# ---------------------------------------------------------------- end of quality ratchet


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
            names = entry.get("trace") or []
            trace = f" Read it in a trace under {', '.join(names)}." if names else ""
            out.append(f"{path}:{first}: changes perf-hot `{marker.declaration[:80]}` (budget {marker.budget}, "
                       f"{hot or 'no path id'}{owner}). Run before and after on the fleet, light and STRESS: {bench}"
                       f"{trace}")
    for path, change in sorted(changes.items()):
        # Per path id: an edit of a marked declaration line (a parameter, an attribute) keeps its marker.
        gone = marker_ids(r.text for r in change.removed) - marker_ids(a.text for a in change.added)
        for hot, count in sorted(gone.items()):
            out.append(f"{path}: removes a perf-hot marker (`{hot}`{f', {count}x' if count > 1 else ''}): keep it "
                       "unless the path is no longer hot, and say why in the commit")
    return out


def list_perf_hot(repo: Path, wanted: list[str]) -> int:
    """Prints each path id of BENCHES (or only WANTED) with the markers this hook's resolver sees in the tracked
    Swift files of REPO's working tree, and each marker that marks no declaration or names an unknown id. Exit 1
    when a listed id has no marker that marks a declaration, or a marker marks none."""
    paths = json.loads((repo / BENCHES).read_text(encoding="utf-8")).get("paths", {})
    unknown = [pid for pid in wanted if pid not in paths]
    if unknown:
        print(f"guardrails: not in {BENCHES}: {', '.join(unknown)}")
        return 1
    files = git(repo, "grep", "-I", "-z", "-l", "--no-color", "-F", "perf-hot:", "--", "*.swift", check=False)
    found: dict[str, list[tuple[str, PerfHotMarker]]] = collections.defaultdict(list)
    for path in sorted(p for p in files.split("\0") if p):
        lines = (repo / path).read_text(encoding="utf-8", errors="replace").split("\n")
        for marker in perf_hot_markers(lines):
            found[marker.path_id].append((path, marker))
    failed = False
    for pid in wanted or list(paths):
        markers = found.get(pid, [])
        resolved = [(path, m) for path, m in markers if m.span is not None]
        print(f"{pid}: {len(resolved)} marker{'s' if len(resolved) != 1 else ''}" + ("" if resolved else " (none)"))
        for path, marker in markers:
            target = f"marks `{marker.declaration[:80]}`" if marker.span else "MARKS NO DECLARATION"
            print(f"  {path}:{marker.line}: {marker.budget}, {target}")
        failed = failed or not resolved or len(resolved) != len(markers)
    if not wanted:
        for pid in sorted(set(found) - set(paths)):
            sites = ", ".join(f"{path}:{m.line}" for path, m in found[pid])
            print(f"{pid or '(no path id)'}: not in {BENCHES}: {sites}")
    return 1 if failed else 0


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
    specs = ["--", SWIFT_SOURCES, SWIFT_TESTS, *SHIPPED_BUILD_SPECS, *WAKEUP_EXT_SPECS, PACKAGE_MANIFEST_SPEC,
             *PACKAGE_SWIFT_SPECS, *RUST_STABILITY_SPECS, QUALITY_BASELINE]
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
                  + [(head, MANIFEST), (base, MANIFEST), (head, THREADING_DOC), (head, PACKAGE_MANIFEST),
                     (head, IDLE_BUDGET), (base, IDLE_BUDGET), (head, INVARIANT_ALLOWLIST),
                     (head, QUALITY_BASELINE), (base, QUALITY_BASELINE)]
                  + [(base, p) for p in rust_rule_paths() if any(map(in_rust_stability_scope, early))], blob_ids)
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
    load_blocking_context(texts, head, repo)
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
    rust = [changes[p] for p in paths if in_rust_stability_scope(p)]
    if rust:
        try:
            rust_rules: str | RustScanError = rust_rule_texts(texts, base)
        except RustScanError as error:  # the Rust rules fail open with it (rust_rule)
            rust_rules = error
        for change in rust:
            change.memo["rust_rules"] = rust_rules
    # wakeup-ext's own files (Shared, crates, webviews, the CEF shim) stay out of the Swift readings below.
    swift = {p: changes[p] for p in paths if in_swift_scope(p)}
    head_types = GenericTypes(repo, head, [texts.get((head, p), "") for p in swift])
    base_types = GenericTypes(repo, base, [texts.get((base, p), "") for p in swift])
    head_targets = swift_scope.package_targets(texts.get((head, MANIFEST), ""))
    base_targets = swift_scope.package_targets(texts.get((base, MANIFEST), ""))
    try:
        # Classes in extensions of a type whose generic signature the push changes, in files it does not change.
        context_files, causes = generic_signature_context(repo, head, swift, head_types, base_types)
    except Exception as error:  # fail open for this reading only: the rules still judge the push's own files
        context_files, causes = [], {}
        warnings.append(("guardrails", check_failure("generic-signature context", error)))
    for change in list(swift.values()) + context_files:
        change.head_types, change.base_types = head_types, base_types
        change.head_main = main_by_default(change.path, head_targets)
        change.base_main = main_by_default(change.path, base_targets)
    files = [changes[p] for p in paths]
    wakeup = WakeupContext(repo, base, head, {rev: texts.get((rev, MANIFEST), "") for rev in (base, head)},
                           {rev: texts.get((rev, IDLE_BUDGET)) for rev in (base, head)})
    invariant_allow = invariant_allowance(texts.get((head, INVARIANT_ALLOWLIST)))
    try:
        quality_baseline = (texts.get((base, QUALITY_BASELINE)),
                            None if (base, QUALITY_BASELINE) in texts
                            else quality_origin(repo, base, head, texts.get((head, QUALITY_BASELINE))))
    except Exception as error:  # fail closed for the quality rules only: no baseline, so old lines count as new
        quality_baseline = (None, None)
        warnings.append(("guardrails", check_failure("quality baseline", error)))
    for change in files:
        change.memo["wakeup"] = wakeup
        change.memo[INVARIANT_ALLOW_MEMO] = invariant_allow
        change.memo[QUALITY_MEMO] = quality_baseline
    moved = collections.Counter(r.text.strip() for c in swift.values() for r in c.removed if r.text.strip())
    try:
        load_push_linked_packages(repo, head, texts.get((head, PACKAGE_MANIFEST)), files)
    except Exception as error:  # fail open for the linked packages only: the rules still judge CmuxNext's files
        BLOCKING_CONTEXT.pop("linked", None)
        warnings.append(("guardrails", check_failure("linked packages", error)))
    found = []
    in_ci = bool(os.environ.get("GITHUB_ACTIONS"))
    for rule in RULES:
        if rule.local_only and in_ci:
            continue
        # The unchanged context files hold no added or removed line: only their touched context can add debt.
        scoped = [f for f in files + context_files if in_rule_scope(f.path, rule.scope)]
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
        warnings += [("perf-hot", w) for w in perf_hot_warnings(swift, benches)]
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
    the same commits); a (base, head) pair is a push whose remote head is base (push_range.as_own_ranges). Every
    rule here is in the local-only tier: under GitHub Actions nothing is judged (False), as arch-ratchet.py does."""
    if on_ci():
        return False
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


SELF_TEST_KIT = SOURCES + "CmuxNextKit/"
SELF_TEST_APP_FILE = APP + "CmuxApplication.swift"
SELF_TEST_MONITOR = "        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { $0 }\n"
SELF_TEST_BASE = {
    SELF_TEST_KIT + "OldMonitor.swift": "final class OldMonitor {\n    func start() {\n" + SELF_TEST_MONITOR + "    }\n}\n",
    SELF_TEST_KIT + "Escaped.swift": "func f() {\n        // input-monitor-allow: a nested tracking loop\n" + SELF_TEST_MONITOR + "}\n",
    SELF_TEST_APP_FILE: "final class CmuxApplication: NSApplication {\n    var inputObserver: ((NSEvent) -> Void)?\n}\n",
}


def _self_test_edit(path: str, old: str, new: str) -> dict[str, str]:
    return {path: SELF_TEST_BASE[path].replace(old, new, 1)}


SELF_TEST_CASES = (
    # (what the push does, {path: head text}, refused)
    ("a new local monitor", {SELF_TEST_KIT + "New.swift": "func f() {\n" + SELF_TEST_MONITOR + "}\n"}, True),
    ("a new global monitor", {SELF_TEST_KIT + "New.swift":
                              "func f() {\n    NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { _ in }\n}\n"},
     True),
    ("an escaped monitor", {SELF_TEST_KIT + "New.swift": "func f() {\n"
                            "        // input-monitor-allow: a nested tracking loop never reaches sendEvent\n"
                            + SELF_TEST_MONITOR + "}\n"}, False),
    ("a monitor inside CmuxNextInput", {SOURCES + "CmuxNextInput/InputEventTap.swift":
                                        "func f() {\n" + SELF_TEST_MONITOR + "}\n"}, False),
    ("a monitor named only in a comment", {SELF_TEST_KIT + "New.swift": "// replaces addLocalMonitorForEvents\nfunc f() {}\n"},
     False),
    ("an edit of a line that already holds a monitor (base debt)",
     _self_test_edit(SELF_TEST_KIT + "OldMonitor.swift", ".keyDown", "[.keyDown, .keyUp]"), False),
    ("a second monitor in a file that has one",
     _self_test_edit(SELF_TEST_KIT + "OldMonitor.swift", SELF_TEST_MONITOR, SELF_TEST_MONITOR * 2), True),
    ("deleting the escape of an old monitor", {SELF_TEST_KIT + "Escaped.swift": "func f() {\n" + SELF_TEST_MONITOR + "}\n"},
     True),
    ("a new event closure property on CmuxApplication",
     _self_test_edit(SELF_TEST_APP_FILE, "}\n", "    var keyUpObserver: ((NSEvent) -> Bool)?\n}\n"), True),
    ("a new event closure property in a CmuxApplication extension", {APP + "CmuxApplication+Keys.swift":
     "extension CmuxApplication {\n    static let keyHooks: [(NSEvent) -> Void] = []\n}\n"}, True),
    ("an event closure local in a CmuxApplication method",
     _self_test_edit(SELF_TEST_APP_FILE, "}\n", "    func f(_ event: NSEvent) {\n        let handler: (NSEvent) -> Void = "
                     "{ _ in }\n        handler(event)\n    }\n}\n"), False),
    ("an event closure property on another type", {SELF_TEST_KIT + "New.swift":
                                                   "final class Other {\n    var onKey: ((NSEvent) -> Void)?\n}\n"}, False),
    ("a labelled event closure property on CmuxApplication",
     _self_test_edit(SELF_TEST_APP_FILE, "}\n", "    var labelled: ((_ event: NSEvent) -> Void)?\n}\n"), True),
    ("a dictionary of event handlers on CmuxApplication",
     _self_test_edit(SELF_TEST_APP_FILE, "}\n", "    var hooks: [UUID: (NSEvent) -> Void] = [:]\n}\n"), True),
    ("an inferred array of event handlers on CmuxApplication",
     _self_test_edit(SELF_TEST_APP_FILE, "}\n", "    var hooks = [(NSEvent) -> Void]()\n}\n"), True),
    ("an Optional<> event closure on CmuxApplication",
     _self_test_edit(SELF_TEST_APP_FILE, "}\n", "    var scope: Optional<(NSEvent, () -> Void) -> Void>\n}\n"), True),
    ("an event tuple property on CmuxApplication",
     _self_test_edit(SELF_TEST_APP_FILE, "}\n", "    var lastKey: (NSEvent, Date)?\n    var pending: (NSEvent, NSWindow?)?\n}\n"),
     False),
    ("an escaped event closure property on CmuxApplication",
     _self_test_edit(SELF_TEST_APP_FILE, "}\n", "    // input-monitor-allow: runModal's own loop, the tap never sees it\n"
                     "    var modalKey: ((NSEvent) -> Bool)?\n}\n"), False),
)

# target-settings: the app manifest links Packages/Shared/Linked, not Packages/Shared/Unlinked.
SELF_TEST_SHARED = "Packages/Shared/Linked/Package.swift"
SELF_TEST_UNLINKED = "Packages/Shared/Unlinked/Package.swift"
SELF_TEST_TARGETS_END = "        .target(name: \"Kit\", swiftSettings: uiSwiftSettings),\n    ]\n)\n"
SELF_TEST_ESCAPED_C = "        // settings-allow: C target, no Swift sources\n        .target(name: \"EscapedC\"),\n"
SELF_TEST_MANIFEST_BASE = {
    MANIFEST: "// swift-tools-version: 6.2\nimport PackageDescription\n\n"
              "let stabilitySwiftSettings: [SwiftSetting] = []\n\n"
              "let uiSwiftSettings: [SwiftSetting] = [\n    .swiftLanguageMode(.v6),\n] + stabilitySwiftSettings\n\n"
              "let daemonSwiftSettings: [SwiftSetting] = [\n    .swiftLanguageMode(.v6),\n]\n"
              "    + stabilitySwiftSettings\n\n"
              "let package = Package(\n    name: \"CmuxNext\",\n    dependencies: [\n"
              "        .package(path: \"../../Shared/Linked\"),\n    ],\n    targets: [\n"
              "        .target(name: \"OldC\"),\n" + SELF_TEST_ESCAPED_C + SELF_TEST_TARGETS_END,
    SELF_TEST_SHARED: "// swift-tools-version: 6.2\nimport PackageDescription\n\n"
                      "let stabilitySwiftSettings: [SwiftSetting] = []\n\n"
                      "let package = Package(\n    name: \"Linked\",\n    targets: [\n"
                      "        .target(name: \"Linked\", swiftSettings: stabilitySwiftSettings),\n    ]\n)\n",
    SELF_TEST_UNLINKED: "// swift-tools-version: 6.0\nimport PackageDescription\n\n"
                        "let package = Package(\n    name: \"Unlinked\",\n    targets: [\n"
                        "        .target(name: \"Unlinked\"),\n    ]\n)\n",
}


def _manifest_edit(path: str, old: str, new: str) -> dict[str, str]:
    text = SELF_TEST_MANIFEST_BASE[path]
    if old not in text:
        raise ValueError(f"self-test fixture: {old!r} is not in {path}")
    return {path: text.replace(old, new, 1)}


def _new_target(declaration: str, constant: str = "") -> dict[str, str]:
    """The app manifest with DECLARATION as its last target and CONSTANT declared above `let package`."""
    edit = _manifest_edit(MANIFEST, SELF_TEST_TARGETS_END,
                          SELF_TEST_TARGETS_END.replace("    ]\n", declaration + "    ]\n"))
    return {MANIFEST: edit[MANIFEST].replace("let package", constant + "let package", 1)}


TARGET_SETTINGS_CASES = (
    ("a new target with uiSwiftSettings",
     _new_target("        .target(name: \"New\", swiftSettings: uiSwiftSettings),\n"), False),
    ("a new test target with daemonSwiftSettings, written over lines",
     _new_target("        .testTarget(\n            name: \"NewTests\",\n            dependencies: [\"Kit\"],\n"
                 "            swiftSettings: daemonSwiftSettings\n        ),\n"), False),
    ("a new target with no swiftSettings",
     _new_target("        .target(name: \"New\", dependencies: [\"Kit\"]),\n"), True),
    ("a new executable target with its own settings list",
     _new_target("        .executableTarget(name: \"Tool\", swiftSettings: [.swiftLanguageMode(.v6)]),\n"), True),
    ("a new target with uiSwiftSettings plus a define",
     _new_target("        .target(name: \"New\", swiftSettings: uiSwiftSettings + [.define(\"X\")]),\n"), False),
    ("a new target through a new constant that appends the shared settings",
     _new_target("        .testTarget(name: \"NewTests\", swiftSettings: testSettings),\n",
                 "let testSettings = daemonSwiftSettings + [.define(\"TESTING\")]\n\n"), False),
    ("a new target through a constant that does not append the shared settings",
     _new_target("        .target(name: \"New\", swiftSettings: plainSettings),\n",
                 "let plainSettings: [SwiftSetting] = [\n    .swiftLanguageMode(.v6),\n]\n\n"), True),
    ("a new escaped C target", _new_target("        // settings-allow: C target, no Swift sources\n"
                                           "        .target(name: \"NewC\", path: \"Sources/NewC\"),\n"), False),
    ("a new target that names a target dependency with a condition",
     _new_target("        .target(\n            name: \"New\",\n            dependencies: [.target(name: \"OldC\", "
                 "condition: .when(platforms: [.macOS]))],\n"
                 "            swiftSettings: uiSwiftSettings\n        ),\n"), False),
    ("a new target over a new top-level dependency constant that names an old target",
     _new_target("        .target(name: \"New\", dependencies: kitDeps, swiftSettings: uiSwiftSettings),\n",
                 "let kitDeps: [Target.Dependency] = [\n    .target(name: \"Kit\"),\n]\n\n"), False),
    ("a new top-level Target.Dependency constant that names an old target",
     _new_target("", "let kitDep = Target.Dependency.target(name: \"Kit\")\n\n"), False),
    ("a new target without the settings in a top-level [Target] constant",
     _new_target("", "let extraTargets: [Target] = [\n    .target(name: \"Extra\"),\n]\n\n"), True),
    ("a new target with a non-literal name and a product dependency",
     _new_target("        .target(name: newName, dependencies: [.product(name: \"Kit\", package: \"x\")]),\n",
                 "let newName = \"New\"\n\n"), False),
    ("an edit of an old target without the settings (base debt)",
     _manifest_edit(MANIFEST, ".target(name: \"OldC\"),", ".target(name: \"OldC\", path: \"Sources/OldC\"),"), False),
    ("an old target that loses the shared settings",
     _manifest_edit(MANIFEST, ".target(name: \"Kit\", swiftSettings: uiSwiftSettings)",
                    ".target(name: \"Kit\")"), True),
    ("deleting the escape of an old target", _manifest_edit(MANIFEST, SELF_TEST_ESCAPED_C,
                                                            "        .target(name: \"EscapedC\"),\n"), True),
    ("a target named only in a comment", _new_target("        // .target(name: \"Gone\"),\n"), False),
    ("a new target without settings in a linked Shared manifest",
     _manifest_edit(SELF_TEST_SHARED, "    ]\n)", "        .testTarget(name: \"LinkedTests\"),\n    ]\n)"), True),
    ("a new target with the shared settings in a linked Shared manifest",
     _manifest_edit(SELF_TEST_SHARED, "    ]\n)", "        .testTarget(name: \"LinkedTests\", swiftSettings: "
                    "stabilitySwiftSettings),\n    ]\n)"), False),
    ("a new target without settings in a package the app does not link",
     _manifest_edit(SELF_TEST_UNLINKED, "    ]\n)", "        .testTarget(name: \"UnlinkedTests\"),\n    ]\n)"), False),
    ("linking a package whose targets lack the settings",
     _manifest_edit(MANIFEST, "    ],\n    targets", "        .package(path: \"../../Shared/Unlinked\"),\n    ],\n"
                    "    targets"), False),
    ("a target moved from the app manifest into a linked one, without the settings it never had",
     {**_manifest_edit(MANIFEST, "        .target(name: \"OldC\"),\n", ""),
      **_manifest_edit(SELF_TEST_SHARED, "    ]\n)", "        .target(name: \"OldC\"),\n    ]\n)")}, False),
)

# safety-todo: an old file of a Shared package and one of the app's tests, before the strict-memory-safety pass.
SELF_TEST_SHARED_SOURCE = "Packages/Shared/Linked/Sources/Linked/Buffer.swift"
SELF_TEST_APP_TEST = TESTS + "CmuxNextTests/BufferTests.swift"
SELF_TEST_MARKED = "Packages/Shared/Linked/Sources/Linked/Zero.swift"
SELF_TEST_ARGUMENTS = "Packages/Shared/Linked/Sources/Linked/Describe.swift"
SELF_TEST_EXPECT = "Packages/Shared/Linked/Tests/LinkedTests/ReadTests.swift"
SELF_TEST_SAFETY_BASE = {
    SELF_TEST_SHARED_SOURCE: "func fill(_ p: UnsafeMutablePointer<UInt8>, count: Int) {\n"
                             "    for i in 0..<count {\n        p[i] = 0\n    }\n}\n",
    SELF_TEST_APP_TEST: "func check(_ p: UnsafePointer<UInt8>) -> UInt8 {\n    return p.pointee\n}\n",
    SELF_TEST_MARKED: "func zero(_ p: UnsafeMutablePointer<UInt8>) {\n"
                      "    // SAFETY-TODO(p10)\n    unsafe p.pointee = 0\n}\n",
    # The shapes swiftc 6.2.4 puts its fix-it in that sit after `(`: a call argument, a string literal argument
    # with a pointer interpolated, an interpolation inside a multi-line string, a macro argument.
    SELF_TEST_ARGUMENTS: "func describe(_ p: UnsafePointer<Int>) -> String {\n    use(p.pointee)\n"
                         "    print(\"v: \\(p.pointee)\")\n    return \"\"\"\n    \\(p.pointee)\n    \"\"\"\n}\n",
    SELF_TEST_EXPECT: "@Test func reads(_ p: UnsafePointer<Int>) {\n    #expect(p.pointee == 3)\n}\n",
}


def _safety_edit(path: str, old: str, new: str) -> dict[str, str]:
    text = SELF_TEST_SAFETY_BASE[path]
    if old not in text:
        raise ValueError(f"self-test fixture: {old!r} is not in {path}")
    return {path: text.replace(old, new, 1)}


SAFETY_TODO_CASES = (
    ("the fix-it pass marks an old line",
     _safety_edit(SELF_TEST_SHARED_SOURCE, "        p[i] = 0\n",
                  "        // SAFETY-TODO(p10)\n        unsafe p[i] = 0\n"), False),
    ("the fix-it pass marks an old test line",
     _safety_edit(SELF_TEST_APP_TEST, "    return p.pointee\n",
                  "    // SAFETY-TODO(p10)\n    return unsafe p.pointee\n"),
     False),
    ("a mark on a new line",
     _safety_edit(SELF_TEST_SHARED_SOURCE, "    }\n}\n",
                  "    }\n    // SAFETY-TODO(p10)\n    unsafe p[count] = 0\n}\n"), True),
    ("a mark on a new file",
     {"Packages/iOS/Mobile/Sources/Mobile/Raw.swift": "func raw(_ p: UnsafeRawPointer) -> UInt8 {\n"
                                                      "    // SAFETY-TODO(p10)\n"
                                                      "    return unsafe p.load(as: UInt8.self)\n}\n"}, True),
    ("two marks for one old line",
     _safety_edit(SELF_TEST_SHARED_SOURCE, "        p[i] = 0\n",
                  "        // SAFETY-TODO(p10)\n        // SAFETY-TODO(p10)\n        unsafe p[i] = 0\n"), True),
    ("a mark on an old line edited beyond `unsafe`",
     _safety_edit(SELF_TEST_SHARED_SOURCE, "        p[i] = 0\n",
                  "        // SAFETY-TODO(p10)\n        unsafe p[i] = 1\n"), True),
    ("new unsafe code with a SAFETY argument",
     _safety_edit(SELF_TEST_SHARED_SOURCE, "    }\n}\n",
                  "    }\n    // SAFETY: p has count + 1 bytes (the caller's contract)\n    unsafe p[count] = 0\n}\n"),
     False),
    ("a marked site moved to another file",
     {SELF_TEST_MARKED: "",
      "Packages/Shared/Linked/Sources/Linked/Moved.swift": SELF_TEST_SAFETY_BASE[SELF_TEST_MARKED]},
     False),
    ("a marked site copied to another file",
     {"Packages/Shared/Linked/Sources/Linked/Copy.swift": SELF_TEST_SAFETY_BASE[SELF_TEST_MARKED]}, True),
    ("an old mark re-indented",
     {SELF_TEST_MARKED: SELF_TEST_SAFETY_BASE[SELF_TEST_MARKED].replace("    // SAFETY", "  // SAFETY")}, False),
    ("the fix-it pass marks a call argument",
     _safety_edit(SELF_TEST_ARGUMENTS, "    use(p.pointee)\n", "    // SAFETY-TODO(p10)\n    use(unsafe p.pointee)\n"),
     False),
    ("the fix-it pass marks a string argument with a pointer interpolated",
     _safety_edit(SELF_TEST_ARGUMENTS, '    print("v: \\(p.pointee)")\n',
                  '    // SAFETY-TODO(p10)\n    print(unsafe "v: \\(p.pointee)")\n'), False),
    ("the fix-it pass marks the line that opens a multi-line string",
     _safety_edit(SELF_TEST_ARGUMENTS, '    return """\n    \\(p.pointee)\n',
                  '    // SAFETY-TODO(p10)\n    return """\n    \\(unsafe p.pointee)\n'), False),
    ("the fix-it pass marks a macro argument in a test",
     _safety_edit(SELF_TEST_EXPECT, "    #expect(p.pointee == 3)\n",
                  "    // SAFETY-TODO(p10)\n    #expect(unsafe p.pointee == 3)\n"), False),
    ("fix one old site, mark new code",
     {**_safety_edit(SELF_TEST_MARKED, "    // SAFETY-TODO(p10)\n    unsafe p.pointee = 0\n",
                     "    p.initialize(to: 0)\n"),
      **_safety_edit(SELF_TEST_SHARED_SOURCE, "    }\n}\n",
                     "    }\n    // SAFETY-TODO(p10)\n    unsafe p[count] = 0\n}\n")}, True),
    ("unsafe on an old line, mark on a new line in the same file",
     _safety_edit(SELF_TEST_SHARED_SOURCE, "        p[i] = 0\n    }\n}\n",
                  "        unsafe p[i] = 0\n    }\n    // SAFETY-TODO(p10)\n    unsafe p[count] = 0\n}\n"), True),
    ("unsafe on an old line, a mark on a new copy of it",
     _safety_edit(SELF_TEST_SHARED_SOURCE, "        p[i] = 0\n    }\n}\n",
                  "        unsafe p[i] = 0\n    }\n    // SAFETY-TODO(p10)\n    unsafe p[i] = 0\n}\n"), True),
    ("a mark above an old line the push did not change",
     _safety_edit(SELF_TEST_SHARED_SOURCE, "        p[i] = 0\n", "        // SAFETY-TODO(p10)\n        p[i] = 0\n"),
     True),
    ("a parameter label named unsafe",
     _safety_edit(SELF_TEST_ARGUMENTS, "    use(p.pointee)\n", "    // SAFETY-TODO(p10)\n    use(unsafe: p.pointee)\n"),
     True),
)


SELF_TEST_WAIT = "Packages/Shared/Linked/Sources/Linked/Wait.swift"
SELF_TEST_OTHER_WAIT = "Packages/Shared/Linked/Sources/Linked/OtherWait.swift"
SELF_TEST_OLD_WAIT = ("func value() async throws -> Int {\n"
                      "    await withCheckedContinuation { continuation in\n"
                      "        continuation.resume(returning: 1)\n    }\n}\n")
SELF_TEST_ONCE_WAIT = SELF_TEST_OLD_WAIT.replace("await withCheckedContinuation", "try await withOnceContinuation")
# The base: one file already on OnceContinuation, one with an old raw continuation the push may leave alone.
SELF_TEST_CONTINUATION_BASE = {SELF_TEST_WAIT: SELF_TEST_ONCE_WAIT, SELF_TEST_OTHER_WAIT: SELF_TEST_OLD_WAIT}
SELF_TEST_NEW_WAIT = ("func next() async throws -> Int {{\n"
                      "    try await {call} {{ continuation in\n"
                      "        continuation.resume(returning: 2)\n    }}\n}}\n")
SELF_TEST_NOTE = "// notes\n"
RAW_CONTINUATION_CASES = (
    *((f"a new {call} in a package's Sources",
       {"Packages/macOS/CmuxNext/Sources/CmuxNextApp/Next.swift": SELF_TEST_NEW_WAIT.format(call=call)}, True)
      for call in ("withCheckedContinuation", "withCheckedThrowingContinuation", "withUnsafeContinuation",
                   "withUnsafeThrowingContinuation")),
    ("a new raw continuation in a Shared package", {SELF_TEST_WAIT: SELF_TEST_ONCE_WAIT
                                                     + SELF_TEST_NEW_WAIT.format(call="withCheckedContinuation")},
     True),
    ("an old raw continuation in a file the push changes elsewhere (the ban)",
     {SELF_TEST_OTHER_WAIT: SELF_TEST_NOTE + SELF_TEST_OLD_WAIT}, True),
    ("an old raw continuation moved to another file (the ban)",
     {SELF_TEST_OTHER_WAIT: "", "Packages/Shared/Linked/Sources/Linked/Moved.swift": SELF_TEST_OLD_WAIT}, True),
    ("an old raw continuation in a file the push does not change",
     {SELF_TEST_WAIT: SELF_TEST_NOTE + SELF_TEST_ONCE_WAIT}, False),
    ("an old raw continuation replaced by OnceContinuation",
     {SELF_TEST_OTHER_WAIT: SELF_TEST_ONCE_WAIT}, False),
    ("a file with its raw continuation deleted", {SELF_TEST_OTHER_WAIT: None}, False),
    ("a raw continuation inside CmuxSafeConcurrency, which implements OnceContinuation",
     {"Packages/Shared/CmuxSafeConcurrency/Sources/CmuxSafeConcurrency/Wait.swift":
      SELF_TEST_NEW_WAIT.format(call="withCheckedContinuation")}, False),
    ("a raw continuation in a test",
     {"Packages/Shared/Linked/Tests/LinkedTests/WaitTests.swift":
      SELF_TEST_NEW_WAIT.format(call="withCheckedContinuation")}, False),
    ("a raw continuation named only in a comment or a string",
     {SELF_TEST_WAIT: SELF_TEST_ONCE_WAIT + "// replaces withCheckedContinuation\n"
                                            "let note = \"withCheckedContinuation\"\n"}, False),
    ("a reviewed escape",
     {SELF_TEST_WAIT: SELF_TEST_ONCE_WAIT + SELF_TEST_NEW_WAIT.format(call="withUnsafeContinuation").replace(
         "    try await", "    // raw-continuation-allow: fixture for the escape\n    try await")}, False),
    ("an old raw continuation given a reviewed escape",
     {SELF_TEST_OTHER_WAIT: SELF_TEST_OLD_WAIT.replace(
         "    await", "    // raw-continuation-allow: fixture for the escape\n    await")}, False),
)


SELF_TEST_ORDER = "Packages/Shared/Linked/Sources/Linked/Order.swift"
SELF_TEST_CACHE = "Packages/Shared/Linked/Sources/Linked/Cache.swift"
SELF_TEST_ROWS = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Rows.swift"
SELF_TEST_CHECK = "    Invariant.check(rows.count == order.count, \"order-matches-rows\")\n"
SELF_TEST_DUMP = "    Invariant.dumpWillBeCheck(cache.isCoherent, \"cache-coherent\")\n"


def _self_test_invariant_allowlist(*entries: tuple[str, str, int]) -> str:
    return json.dumps({"allow": [{"path": path, "class": kind, "count": count, "reason": "fixture",
                                  "reviewer": "self-test"} for path, kind, count in entries]})


# The base: Order.swift holds one allowlisted check; Cache.swift one dumpWillBeCheck with no entry.
SELF_TEST_INVARIANT_BASE = {
    SELF_TEST_ORDER: "func save() {\n" + SELF_TEST_CHECK + "}\n",
    SELF_TEST_CACHE: "func load() {\n" + SELF_TEST_DUMP + "}\n",
    INVARIANT_ALLOWLIST: _self_test_invariant_allowlist((SELF_TEST_ORDER, "invariant_check", 1)),
}
INVARIANT_SITE_CASES = (
    ("a new check site with no allowlist entry", {SELF_TEST_ROWS: "func f() {\n" + SELF_TEST_CHECK + "}\n"}, True),
    ("a new dumpWillBeCheck site with no allowlist entry",
     {"Packages/Shared/Linked/Sources/Linked/Other.swift": "func f() {\n" + SELF_TEST_DUMP + "}\n"}, True),
    ("a second check in a file allowed one", {SELF_TEST_ORDER: "func save() {\n" + SELF_TEST_CHECK * 2 + "}\n"}, True),
    ("an edit in a file whose old site has no entry",
     {SELF_TEST_CACHE: "// notes\nfunc load() {\n" + SELF_TEST_DUMP + "}\n"}, True),
    ("an allowlist entry of the other class does not allow a site",
     {SELF_TEST_CACHE: "// notes\nfunc load() {\n" + SELF_TEST_DUMP + "}\n",
      INVARIANT_ALLOWLIST: _self_test_invariant_allowlist((SELF_TEST_ORDER, "invariant_check", 1),
                                                          (SELF_TEST_CACHE, "invariant_check", 1))}, True),
    ("an edit in a file within its allowance",
     {SELF_TEST_ORDER: "// notes\nfunc save() {\n" + SELF_TEST_CHECK + "}\n"}, False),
    ("a new site with its allowlist entry in the same push",
     {SELF_TEST_ROWS: "func f() {\n" + SELF_TEST_CHECK + "}\n",
      INVARIANT_ALLOWLIST: _self_test_invariant_allowlist((SELF_TEST_ORDER, "invariant_check", 1),
                                                          (SELF_TEST_ROWS, "invariant_check", 1))}, False),
    ("an old unlisted site in a file the push does not change",
     {SELF_TEST_ORDER: "// notes\nfunc save() {\n" + SELF_TEST_CHECK + "}\n"}, False),
    ("a site in a test",
     {"Packages/Shared/Linked/Tests/LinkedTests/OrderTests.swift": "func t() {\n" + SELF_TEST_CHECK + "}\n"}, False),
    ("a site named only in a comment or a string",
     {"Packages/Shared/Linked/Sources/Linked/Other.swift": "/// Invariant.check(a, \"doc\")\n"
                                                          "let note = \"Invariant.dumpWillBeCheck(\"\n"}, False),
    ("notFatalUntil is not a class",
     {"Packages/Shared/Linked/Sources/Linked/Other.swift":
      "func f() {\n    Invariant.notFatalUntil(ok, \"tab-in-workspace\", build: 100)\n}\n"}, False),
)


SELF_TEST_SHARED_QUEUE = "Packages/Shared/Linked/Sources/Linked/Queue.swift"
SELF_TEST_APP_QUEUE = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Queue.swift"
SELF_TEST_GUARD = "    guard let first = items.first else {\n        idle()\n        return nil\n    }\n"
SELF_TEST_GUARDED = "func next() -> Int? {\n" + SELF_TEST_GUARD + "    items.removeFirst()\n    return first\n}\n"
SELF_TEST_UNGUARDED = "func drop() {\n    items.removeFirst()\n}\n"
SELF_TEST_PAD = "let pad = String(repeating: \" \", count: width - used)\n"
# The base: a Shared file at zero, a Shared file and an app file with an old unguarded removal each.
SELF_TEST_TRAP_BASE = {SELF_TEST_SHARED_QUEUE: SELF_TEST_GUARDED,
                       "Packages/Shared/Linked/Sources/Linked/Old.swift": SELF_TEST_UNGUARDED,
                       SELF_TEST_APP_QUEUE: SELF_TEST_GUARDED + SELF_TEST_UNGUARDED}
TRAP_API_CASES = (
    *((f"a new {name} in a Shared package", {SELF_TEST_SHARED_QUEUE: SELF_TEST_GUARDED + code}, True)
      for name, code in (
          ("uniqueKeysWithValues", "let byID = Dictionary(uniqueKeysWithValues: pairs)\n"),
          ("unguarded removeLast", "func pop() {\n    stack.removeLast()\n}\n"),
          ("repeating count that may be negative", SELF_TEST_PAD),
          ("offsetBy without limitedBy", "let i = s.index(s.startIndex, offsetBy: n)\n"))),
    ("a new trap in an iOS package",
     {"Packages/iOS/Phone/Sources/Phone/P.swift": "let a = Array(repeating: 0, count: n)\n"}, True),
    ("an old trap in a Shared file the push changes elsewhere (the ban)",
     {"Packages/Shared/Linked/Sources/Linked/Old.swift": "// notes\n" + SELF_TEST_UNGUARDED}, True),
    ("a new trap in an app file", {SELF_TEST_APP_QUEUE: SELF_TEST_GUARDED + SELF_TEST_UNGUARDED + SELF_TEST_PAD}, True),
    ("an app file's old trap with a change elsewhere in it",
     {SELF_TEST_APP_QUEUE: "// notes\n" + SELF_TEST_GUARDED + SELF_TEST_UNGUARDED}, False),
    ("a guard removed above an old app removal",
     {SELF_TEST_APP_QUEUE: SELF_TEST_GUARDED.replace(SELF_TEST_GUARD, "    let first = 0\n") + SELF_TEST_UNGUARDED},
     True),
    ("an old trap in a Shared file the push does not change",
     {SELF_TEST_SHARED_QUEUE: "// notes\n" + SELF_TEST_GUARDED}, False),
    ("safe forms in a Shared package",
     {SELF_TEST_SHARED_QUEUE: SELF_TEST_GUARDED
      + "let byID = Dictionary(pairs, uniquingKeysWith: { first, _ in first })\n"
      + "let top = stack.popLast()\n"
      + "let pad = String(repeating: \" \", count: max(0, width - used))\n"
      + "func cut(_ n: Int) {\n    guard n >= 0 else { return }\n    let a = Array(repeating: 0, count: n)\n}\n"
      + "let i = s.index(s.startIndex, offsetBy: n, limitedBy: s.endIndex)\n"
      + "// Dictionary(uniqueKeysWithValues: pairs)\n"}, False),
    ("a trap in a test", {"Packages/Shared/Linked/Tests/LinkedTests/QueueTests.swift": SELF_TEST_UNGUARDED}, False),
    ("a reviewed escape",
     {SELF_TEST_SHARED_QUEUE: SELF_TEST_GUARDED + SELF_TEST_UNGUARDED.replace(
         "    items.removeFirst()", "    // trap-api-allow: fixture for the escape\n    items.removeFirst()")}, False),
)


SELF_TEST_CRATE = "cmux-tui/crates/demo/src/"
SELF_TEST_OLD_SLEEP = SELF_TEST_CRATE + "old.rs"
SELF_TEST_ESCAPED_SLEEP = SELF_TEST_CRATE + "escaped.rs"
SELF_TEST_SLEEP_ESCAPE = "    // blocking-allow: fixture, a test runtime's own thread\n"
SELF_TEST_ASYNC_BASE = {
    SELF_TEST_OLD_SLEEP: "pub async fn old() {\n    std::thread::sleep(PAUSE);\n}\n",
    SELF_TEST_ESCAPED_SLEEP: "pub async fn escaped() {\n" + SELF_TEST_SLEEP_ESCAPE + "    std::thread::sleep(PAUSE);\n}\n",
}
SELF_TEST_NEW_RS = SELF_TEST_CRATE + "new.rs"
SELF_TEST_RULE = RUST_RULES_TREE + "/rust-async-blocking.yml"
RUST_ASYNC_BLOCKING_CASES = (
    ("a std sleep in an async fn", {SELF_TEST_NEW_RS: "async fn f() {\n    std::thread::sleep(PAUSE);\n}\n"}, True),
    ("a std::fs read in an async block",
     {SELF_TEST_NEW_RS: "fn f() -> impl Future {\n    async move {\n        std::fs::read(path)\n    }\n}\n"}, True),
    ("a thread join that is not awaited in an async closure",
     {SELF_TEST_NEW_RS: "fn f() {\n    let task = async move || {\n        worker.join();\n    };\n}\n"}, True),
    ("a blocking call in an async fn of a Native crate",
     {"Native/DiffSidecar/src/new.rs": "async fn f() {\n    rx.recv();\n}\n"}, True),
    ("an awaited sleep, recv and timeout",
     {SELF_TEST_NEW_RS: "async fn f() {\n    tokio::time::sleep(PAUSE).await;\n    rx.recv().await;\n"
                        "    timeout(PAUSE, rx.recv()).await;\n}\n"}, False),
    ("a blocking call in the closure given to spawn_blocking",
     {SELF_TEST_NEW_RS: "async fn f() {\n    tokio::task::spawn_blocking(move || std::fs::read(path)).await;\n}\n"},
     False),
    ("a blocking call in a plain fn", {SELF_TEST_NEW_RS: "fn f() {\n    std::thread::sleep(PAUSE);\n}\n"}, False),
    ("a join with an argument (a string join)",
     {SELF_TEST_NEW_RS: "async fn f() -> String {\n    parts.join(\",\")\n}\n"}, False),
    ("a blocking call in a #[cfg(test)] module",
     {SELF_TEST_NEW_RS: "#[cfg(test)]\nmod tests {\n    #[tokio::test]\n    async fn t() {\n"
                        "        std::thread::sleep(PAUSE);\n    }\n}\n"}, False),
    ("a blocking call in a crate's tests folder",
     {"cmux-tui/crates/demo/tests/flow.rs": "async fn t() {\n    std::thread::sleep(PAUSE);\n}\n"}, False),
    ("a reviewed escape",
     {SELF_TEST_NEW_RS: "async fn f() {\n" + SELF_TEST_SLEEP_ESCAPE + "    std::thread::sleep(PAUSE);\n}\n"}, False),
    ("an old blocking call in a file the push changes elsewhere",
     {SELF_TEST_OLD_SLEEP: "// notes\n" + SELF_TEST_ASYNC_BASE[SELF_TEST_OLD_SLEEP]}, False),
    ("deleting the escape of an old blocking call",
     {SELF_TEST_ESCAPED_SLEEP: SELF_TEST_ASYNC_BASE[SELF_TEST_ESCAPED_SLEEP].replace(SELF_TEST_SLEEP_ESCAPE, "")},
     True),
    ("a std::fs read handed to an awaited send",
     {SELF_TEST_NEW_RS: "async fn f() {\n    tx.send(std::fs::read(path)).await;\n}\n"}, True),
    ("a std::fs read in a map closure",
     {SELF_TEST_NEW_RS: "async fn f() -> Vec<Vec<u8>> {\n    paths.iter().map(|p| std::fs::read(p).unwrap()).collect()\n"
                        "}\n"}, True),
    ("a std::fs read in an unwrap_or_else closure",
     {SELF_TEST_NEW_RS: "async fn f() -> String {\n    cfg.unwrap_or_else(|| std::fs::read_to_string(path).unwrap())\n"
                        "}\n"}, True),
    ("a std process output bound and never awaited",
     {SELF_TEST_NEW_RS: "async fn f() {\n    let out = std::process::Command::new(x).output();\n    use_it(out);\n}\n"},
     True),
    ("a tokio process output bound and awaited under a timeout",
     {SELF_TEST_NEW_RS: "async fn f() {\n    let fut = tokio::process::Command::new(x).output();\n"
                        "    timeout(PAUSE, fut).await;\n}\n"}, False),
    ("a read_to_end bound and awaited under a timeout",
     {SELF_TEST_NEW_RS: "async fn f() {\n    let read = reader.read_to_end(&mut input);\n"
                        "    match timeout(PAUSE, read).await {\n        _ => {}\n    }\n}\n"}, False),
    ("futures from a closure handed to an awaited call",
     {SELF_TEST_NEW_RS: "async fn f() {\n    timeout(PAUSE, join_all(xs.iter().map(|x| x.wait()))).await;\n}\n"}, False),
    ("an awaited unqualified connect (tokio::net)",
     {SELF_TEST_NEW_RS: "async fn f() {\n    TcpStream::connect(addr).await;\n"
                        "    timeout(PAUSE, TcpStream::connect(addr)).await;\n}\n"}, False),
    ("a blocking call in a new thread's closure",
     {SELF_TEST_NEW_RS: "async fn f() {\n    let worker = std::thread::spawn(move || std::fs::read(path));\n}\n"},
     False),
    ("a push that weakens the rule it is judged by",
     {SELF_TEST_RULE: "id: rust-async-blocking\nlanguage: rust\nseverity: error\nrule:\n  pattern: never_called()\n",
      SELF_TEST_NEW_RS: "async fn f() {\n    std::thread::sleep(PAUSE);\n}\n"}, True),
    ("a push that deletes the rule it is judged by",
     {SELF_TEST_RULE: None, SELF_TEST_NEW_RS: "async fn f() {\n    std::thread::sleep(PAUSE);\n}\n"}, True),
)
SELF_TEST_TASKS = SELF_TEST_CRATE + "tasks.rs"
SELF_TEST_SPAWN_BASE = {SELF_TEST_TASKS: "pub fn start() {\n    let handle = tokio::spawn(run());\n    keep(handle);\n}\n"}
RUST_UNSUPERVISED_SPAWN_CASES = (
    ("a dropped tokio JoinHandle", {SELF_TEST_NEW_RS: "fn f() {\n    tokio::spawn(run());\n}\n"}, True),
    ("a JoinHandle bound to `_`", {SELF_TEST_NEW_RS: "fn f() {\n    let _ = tokio::task::spawn(run());\n}\n"}, True),
    ("a JoinHandle passed to drop", {SELF_TEST_NEW_RS: "fn f() {\n    drop(tokio::spawn(run()));\n}\n"}, True),
    ("a raw std thread, kept",
     {SELF_TEST_NEW_RS: "fn f() {\n    let worker = std::thread::spawn(move || run());\n    keep(worker);\n}\n"}, True),
    ("a named std thread from a Builder",
     {SELF_TEST_NEW_RS: "fn f() {\n    let worker = std::thread::Builder::new()\n        .name(\"x\".into())\n"
                        "        .spawn(move || run());\n}\n"}, True),
    ("a kept JoinHandle", {SELF_TEST_NEW_RS: "fn f() -> JoinHandle<()> {\n    tokio::spawn(run())\n}\n"}, False),
    ("a JoinSet spawn and an awaited spawn",
     {SELF_TEST_NEW_RS: "async fn f() {\n    set.spawn(run());\n    tokio::spawn(run()).await;\n}\n"}, False),
    ("a spawn in a #[test] fn",
     {SELF_TEST_NEW_RS: "#[test]\nfn t() {\n    std::thread::spawn(move || run());\n}\n"}, False),
    ("a reviewed escape",
     {SELF_TEST_NEW_RS: "fn f() {\n    // supervise-allow: fixture, the caller's watchdog sees it end\n"
                        "    tokio::spawn(run());\n}\n"}, False),
    ("an edit next to an old kept spawn",
     {SELF_TEST_TASKS: SELF_TEST_SPAWN_BASE[SELF_TEST_TASKS].replace("keep(handle)", "keep_until_quit(handle)")},
     False),
)
SELF_TEST_FFI = SELF_TEST_CRATE + "ffi.rs"
SELF_TEST_FFI_BASE = {SELF_TEST_FFI: "#[no_mangle]\npub extern \"C\" fn cmux_old(x: i32) -> i32 {\n    x\n}\n"}
RUST_FFI_GUARD_CASES = (
    ("a new extern \"C\" fn",
     {SELF_TEST_NEW_RS: "#[no_mangle]\npub extern \"C\" fn cmux_new(p: *const Cfg) -> i32 {\n    parse(p)\n}\n"},
     True),
    ("a new unsafe extern \"C\" fn",
     {SELF_TEST_NEW_RS: "#[no_mangle]\npub unsafe extern \"C\" fn cmux_new(p: *const u8) -> u8 {\n    *p\n}\n"}, True),
    ("a body wrapped in ffi_boundary",
     {SELF_TEST_NEW_RS: "#[no_mangle]\npub extern \"C\" fn cmux_new(p: *const Cfg) -> i32 {\n"
                        "    ffi_boundary(-1, || parse(p))\n}\n"}, False),
    ("a reviewed escape above the attribute",
     {SELF_TEST_NEW_RS: "// ffi-nopanic: fixture, integer identity cannot panic\n#[no_mangle]\n"
                        "pub extern \"C\" fn cmux_new(x: i32) -> i32 {\n    x\n}\n"}, False),
    ("a foreign declaration", {SELF_TEST_NEW_RS: "extern \"C\" {\n    fn host_log(x: i32);\n}\n"}, False),
    ("an edit inside an old export's body",
     {SELF_TEST_FFI: SELF_TEST_FFI_BASE[SELF_TEST_FFI].replace("    x\n", "    x + 0\n")}, False),
)


SELF_TEST_DECODE = "Packages/Shared/CmuxVNC/Sources/CmuxVNC/Transport/RFBReader.swift"
SELF_TEST_DECODE_BASE = {SELF_TEST_DECODE: ("func length(_ bytes: [UInt8]) throws -> Int {\n"
                                            "    let word = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32(truncatingIfNeeded: $1) }\n"
                                            "    guard let length = Int(exactly: word) else { throw Failure.tooLong }\n"
                                            "    return length\n}\n"),
                         # A listed file that already has a hit (before its wave): any push that touches it fixes it.
                         "Packages/Shared/CmuxVNC/Sources/CmuxVNC/Client/VNCEndpoint.swift":
                             "func port(_ b: [UInt8], _ i: Int) -> UInt8 { b[i] }\n"}


def _decode_edit(body: str, path: str = SELF_TEST_DECODE) -> dict[str, str]:
    """The base decode file with BODY added at its end (at PATH)."""
    return {path: SELF_TEST_DECODE_BASE[SELF_TEST_DECODE] + body}


DECODE_TRAP_CASES = (
    ("an index subscript in a decode file", _decode_edit("func first(_ b: [UInt8], _ i: Int) -> UInt8 { b[i] }\n"), True),
    ("a range subscript in a decode file", _decode_edit("func head(_ b: [UInt8], _ n: Int) -> ArraySlice<UInt8> { b[0..<n] }\n"),
     True),
    ("a trapping conversion in a decode file", _decode_edit("func count(_ w: UInt32) -> UInt16 { UInt16(w) }\n"), True),
    ("an old hit on a line the push did not change, in a decode file it touches",
     {"Packages/Shared/CmuxVNC/Sources/CmuxVNC/Client/VNCEndpoint.swift":
      "// The port byte.\nfunc port(_ b: [UInt8], _ i: Int) -> UInt8 { b[i] }\n"}, True),
    ("front reads and checked conversions", _decode_edit("func pair(_ b: [UInt8]) -> UInt16? {\n"
                                                         "    UInt16(exactly: b.dropFirst(1).prefix(2).count)\n}\n"), False),
    ("a dictionary subscript", _decode_edit("func kind(_ k: String) -> Int? {\n"
                                            "    let kinds: [String: Int] = [:]\n    return kinds[k]\n}\n"), False),
    ("an escaped C constant", _decode_edit("// decode-trap-allow: a C macro, not input\n"
                                           "let maxBytes = Int(CMUX_MAX_BYTES)\n"), False),
    ("a subscript named only in a comment or a string", _decode_edit("// bytes[i] traps\nlet note = \"bytes[i]\"\n"),
     False),
    ("a subscript in a file that is not listed",
     _decode_edit("func first(_ b: [UInt8], _ i: Int) -> UInt8 { b[i] }\n",
                  "Packages/Shared/CmuxVNC/Sources/CmuxVNC/Client/Other.swift"), False),
)


# (rule, base files, cases): each case is one commit over its suite's base.
SELF_TEST_SUITES = (
    ("input-monitor", SELF_TEST_BASE, SELF_TEST_CASES),
    ("target-settings", SELF_TEST_MANIFEST_BASE, TARGET_SETTINGS_CASES),
    ("safety-todo", SELF_TEST_SAFETY_BASE, SAFETY_TODO_CASES),
    ("raw-continuation", SELF_TEST_CONTINUATION_BASE, RAW_CONTINUATION_CASES),
    ("invariant-site", SELF_TEST_INVARIANT_BASE, INVARIANT_SITE_CASES),
    ("trap-api", SELF_TEST_TRAP_BASE, TRAP_API_CASES),
    ("rust-async-blocking", SELF_TEST_ASYNC_BASE, RUST_ASYNC_BLOCKING_CASES),
    ("rust-unsupervised-spawn", SELF_TEST_SPAWN_BASE, RUST_UNSUPERVISED_SPAWN_CASES),
    ("rust-ffi-guard", SELF_TEST_FFI_BASE, RUST_FFI_GUARD_CASES),
    ("decode-trap", SELF_TEST_DECODE_BASE, DECODE_TRAP_CASES),
)


def edits_rust_rules(files: dict[str, str | None]) -> bool:
    return any(path.startswith(RUST_RULES_TREE + "/") for path in files)


def self_test_rust_rules(root: Path, rule_id: str, refusing: tuple, cases: tuple,
                         judge: Callable[[dict[str, str | None], str], tuple[list[Added], list[str]]]) -> list[str]:
    """The Rust rules' sources, judged with RUST_RULES_HOME swapped: a snapshot without the rules (installed before
    them) judges the cases that edit or delete a rule with the base's copy, and a rule ast-grep rejects fails open
    with a warning instead of passing the push unjudged. The failures."""
    global RUST_RULES_HOME
    failures = []
    installed = RUST_RULES_HOME
    broken = root / f"{rule_id}-broken-rules"
    broken.mkdir()
    for path in rust_rule_paths():
        name = PurePosixPath(path).name
        text = (installed / name).read_text(encoding="utf-8")
        if name == f"{rule_id}.yml":
            text = f"id: {rule_id}\nlanguage: rust\nseverity: error\nrule:\n  kind: no_such_kind\n"
        (broken / name).write_text(text, encoding="utf-8")
    try:
        RUST_RULES_HOME = root / "a-snapshot-without-rules"
        for name, files, refused in (case for case in cases if edits_rust_rules(case[1])):
            hits, raised = judge(files, name)
            ok = bool(hits) == refused and not raised
            print(f"  {'ok  ' if ok else 'FAIL'} {name}, from a snapshot without the rules: "
                  f"{'refused' if hits else 'passes'}" + "".join(f"\n         {text}" for text in raised))
            if not ok:
                failures.append(f"{rule_id}: {name} from a snapshot without the rules")
        RUST_RULES_HOME = broken
        hits, raised = judge(refusing[1], refusing[0])
        ok = bool(raised) and not hits
        print(f"  {'ok  ' if ok else 'FAIL'} {refusing[0]}, with a rule ast-grep rejects: "
              f"{'fails open with a warning' if raised else 'refused' if hits else 'passes unjudged'}")
        if not ok:
            failures.append(f"{rule_id}: {refusing[0]} with a rule ast-grep rejects")
    finally:
        RUST_RULES_HOME = installed
    return failures


def self_test() -> int:
    """The rules of SELF_TEST_SUITES on their cases: each case is one commit over its suite's base in a scratch
    repository, judged by check() as the hook judges a push (git only: no network, no build). Exit 1 on a wrong
    answer."""
    import tempfile
    failures, total = [], 0
    with tempfile.TemporaryDirectory(prefix="cmux-guardrails-self-test-") as temporary:
        root = Path(temporary)
        (root / "gitconfig").write_text("[user]\n\tname = guardrails\n\temail = guardrails@example.com\n")
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(root / "gitconfig"), HOME=str(root))
        saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
        try:
            for rule_id, base_files, cases in SELF_TEST_SUITES:
                repo = root / rule_id
                repo.mkdir()

                def run(*args: str) -> str:
                    return subprocess.run(["git", "-C", str(repo), *args], env=env, text=True, capture_output=True,
                                          check=True).stdout.strip()

                def commit(files: dict[str, str | None], message: str) -> str:
                    for relative, text in files.items():
                        path = repo / relative
                        if text is None:  # a deleted file
                            path.unlink()
                            continue
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_text(text)
                    run("add", "-A")
                    run("commit", "--quiet", "--no-verify", "--allow-empty", "-m", message)
                    return run("rev-parse", "HEAD")

                def judge(files: dict[str, str | None], message: str) -> tuple[list[Added], list[str]]:
                    """(this rule's hits, its fail-open warnings) for one commit of FILES over the suite's base."""
                    run("checkout", "--quiet", "--detach", base)
                    refusals, warnings = check(repo, base, commit(files, message))
                    return ([h for rule, found in refusals if rule.id == rule_id for h in found],
                            [text for kind, text in warnings if kind == "guardrails" and f"rule {rule_id} " in text])

                run("init", "--quiet", "--initial-branch=self-test")
                rust_suite = any(r.id == rule_id for r in RUST_RULES)
                # The Rust suites' base holds the reviewed rules, which a snapshot without them falls back to.
                rule_files = {path: (RUST_RULES_HOME / PurePosixPath(path).name).read_text(encoding="utf-8")
                              for path in rust_rule_paths()} if rust_suite else {}
                base = commit({**base_files, **rule_files}, "base")
                print(f"{rule_id}:")
                for name, files, refused in cases:
                    total += 1
                    hits, raised = judge(files, name)
                    # A rule that raised is skipped (fail open) and would pass every case that expects no refusal.
                    ok = bool(hits) == refused and not raised
                    print(f"  {'ok  ' if ok else 'FAIL'} {name}: {'refused' if hits else 'passes'}"
                          + "".join(f"\n         {h.path}:{h.number}: {h.text.strip()}" for h in hits)
                          + "".join(f"\n         {text}" for text in raised))
                    if not ok:
                        failures.append(f"{rule_id}: {name}")
                rule = next(r for r in RULES if r.id == rule_id)
                refusing = next((case for case in cases if case[2]), None)
                if rule.local_only and refusing is not None:
                    # The local tier: the same refusing commit under GitHub Actions runs no local-only rule.
                    total += 1
                    run("checkout", "--quiet", "--detach", base)
                    head = commit(refusing[1], refusing[0])
                    saved_ci = os.environ.get("GITHUB_ACTIONS")
                    os.environ["GITHUB_ACTIONS"] = "true"
                    try:
                        refusals, _ = check(repo, base, head)
                    finally:
                        if saved_ci is None:
                            os.environ.pop("GITHUB_ACTIONS")
                        else:
                            os.environ["GITHUB_ACTIONS"] = saved_ci
                    ok = not any(r.id == rule_id for r, _ in refusals)
                    print(f"  {'ok  ' if ok else 'FAIL'} {refusing[0]}, under GitHub Actions: "
                          f"{'passes' if ok else 'refused'}")
                    if not ok:
                        failures.append(f"{rule_id}: {refusing[0]} under GitHub Actions")
                if rust_suite and refusing is not None:
                    failures += self_test_rust_rules(root, rule_id, refusing, cases, judge)
                    total += 1 + sum(1 for case in cases if edits_rust_rules(case[1]))
        finally:
            os.environ.update(saved)
    rules = ", ".join(rule_id for rule_id, _, _ in SELF_TEST_SUITES)
    print(f"guardrails self-test: {'FAILED: ' + '; '.join(failures) if failures else 'ok'} "
          f"({total - len(failures)}/{total} cases of {rules})")
    return 1 if failures else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo")
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--list", action="store_true", help="print the rules")
    parser.add_argument("--self-test", action="store_true",
                        help="judge the input-monitor, target-settings, safety-todo, raw-continuation, invariant-site, "
                             "trap-api, decode-trap and Rust stability rules' refuse and escape cases in a scratch "
                             "repository")
    parser.add_argument("--list-perf-hot", nargs="*", metavar="PATH_ID",
                        help=f"print the `// perf-hot:` markers per path id of {BENCHES} as this hook resolves them "
                             "(only the ids given, if any); exit 1 when an id has no marker or a marker marks no "
                             "declaration")
    parser.add_argument("--quality-baseline", action="store_true",
                        help=f"print the quality ratchet's counts at --head (default HEAD); with --write, write them "
                             f"to {QUALITY_BASELINE}")
    parser.add_argument("--write", action="store_true", help="with --quality-baseline: write the json")
    args = parser.parse_args(argv)
    if args.quality_baseline:
        repo = Path(args.repo or git(Path.cwd(), "rev-parse", "--show-toplevel").strip())
        data = quality_counts(repo, args.head)
        for rule, count in data["counts"].items():
            print(f"{rule}: {count} sites in {data['files'][rule]} files at {data['measured_rev'][:12]}")
        if args.write:
            (repo / QUALITY_BASELINE).write_text(json.dumps(data, indent=1, sort_keys=True) + "\n")
            print(f"wrote {QUALITY_BASELINE}")
        return 0
    if args.self_test:
        return self_test()
    if args.list_perf_hot is not None:
        return list_perf_hot(Path(args.repo or git(Path.cwd(), "rev-parse", "--show-toplevel").strip()),
                             args.list_perf_hot)
    if args.list:
        for rule in RULES:
            print(f"{rule.id}: {rule.title}\n  why: {rule.why}\n  do:  {rule.fix}\n  escape: {rule.escape or '-'}")
        print("arch ratchet rows (arch-ratchet.py --list-rules; escape: a dated exception in "
              "plans/cmux-next/arch-ratchet.json)")
        return 0
    if on_ci():
        print("guardrails: not run under GitHub Actions (local-only tier: the hook and plain runs)")
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

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
Warnings (never refuse):
  perf-hot  the push changes a function marked `// perf-hot: <budget> <path-id>` (a trailing comment on its
            declaration line, or in the comment block above it); names the bench from scripts/cmux-next/perf-hot-benches.json to run before
            and after on the fleet.
  owner     the push touches an area in plans/cmux-next/OWNERS.md; names the owner and the doc to read.
  app-grow  the push grows the CmuxNextApp target or adds a file to it (new features get their own target).

  scripts/cmux-next/guardrails.py                    # what HEAD adds over origin/feat-cmux-next
  scripts/cmux-next/guardrails.py --base A --head B
  scripts/cmux-next/guardrails.py --list
"""
from __future__ import annotations

import argparse
import collections
import itertools
import json
import os
import re
import subprocess
import sys
import time
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
NEW_APP_FILE_MAX = 400  # check-no-godfiles.sh's per-file budget, refused here for new App files at push time
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
    """One side of a changed file: its lines and the 1-based lines the push changed on that side."""
    path: str
    lines: list[str]
    changed: set[int]
    memo: dict = field(default_factory=dict)


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

    @property
    def head(self) -> Version:
        return Version(self.path, self.head_lines, {a.number for a in self.added})

    @property
    def base(self) -> Version:
        return Version(self.path, self.base_lines, {r.number for r in self.removed})


@dataclass
class Rule:
    id: str
    title: str
    why: str
    fix: str
    escape: str | None
    find: Callable[[list[FileChange], collections.Counter], list[Added]]  # (changed files, removed texts) -> hits
    scope: tuple[str, ...] = (SOURCES,)  # path prefixes the rule reads (most rules: Sources only)


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


# A deinit that tests for the main thread (`guard Thread.isMainThread else { return }`, `if !Thread.isMainThread`,
# `if Thread.isMainThread { MainActor.assumeIsolated { ... } }`, `Thread.current.isMainThread`, `pthread_main_np()`)
# skips its cleanup whenever the last reference goes on another thread: the task, stream or observer it should
# stop runs on.
MAIN_ONLY_GUARD = re.compile(r"\bThread(\.current)?\.isMainThread\b|\bpthread_main_np\s*\(")
DEINIT_OPENER = re.compile(r"\bdeinit\b[^{]*\{")
DEINIT_MAIN_ALLOW = re.compile(r"//\s*deinit-main-allow:\s*\S")


def in_deinit(version: Version, index: int) -> tuple[bool, list[int]]:
    """The main-thread test's nearest enclosing func, init, deinit or Task body is a deinit."""
    code = code_of(version.lines[index])
    match = MAIN_ONLY_GUARD.search(code)
    prefix = code[:match.start()] if match else ""
    openers = enclosing_openers(version.lines, index, FUNC_STOP, prefix)
    if openers and DEINIT_OPENER.search(openers[-1][0]):
        return True, [openers[-1][1]]
    return False, []


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


def line_count(lines: list[str]) -> int:
    """`wc -l` of the text LINES came from (`text.split("\\n")`): a final newline adds no line."""
    return len(lines) - (1 if lines and lines[-1] == "" else 0)


def big_new_app_file(changes: list[FileChange], moved: collections.Counter) -> list[Added]:
    moved = moved.copy()
    hits = []
    for change in changes:
        total = line_count(change.head_lines)
        if not (change.is_new and change.path.startswith(APP) and total > NEW_APP_FILE_MAX):
            continue
        # The diff runs with --no-renames: a `git mv` (or a split of an existing file) shows as a new file whose
        # lines another file removes. Only a file that is mostly new lines is new App code.
        code = [a.text.strip() for a in change.added if a.text.strip()]
        fresh = 0
        for key in code:
            if moved[key] > 0:
                moved[key] -= 1
            else:
                fresh += 1
        if fresh * 2 > len(code):
            hits.append(Added(change.path, 1, f"new file, {total} lines, {fresh} of them new (limit {NEW_APP_FILE_MAX})"))
    return hits


# A generic class whose deinit is implicit. In a main-actor target (the default of every UI and test
# target, `.defaultIsolation(MainActor.self)`) that deinit is isolated, and swift-frontend 6.3.3 (Xcode 26.6)
# crashes on it in -O: signal 11 in EarlyPerfInliner, isCallerAndCalleeLayoutConstraintsCompatible, on the
# class's deallocating deinit (`...CfD`). It broke `swift build --build-tests -c release` twice on 2026-10-23
# (PageTestWait.Once, CloudPaneTests.Seen) and can hit any edit of such a class.
GENERIC_CLASS = re.compile(r"(^|[\s)])(final\s+)?class\s+\w+\s*<")
GENERIC_CLASS_ALLOW = re.compile(r"//\s*generic-class-allow:\s*\S")


def implicit_deinit(version: Version, index: int) -> tuple[bool, list[int]]:
    """A generic class declared here that is not `nonisolated` and whose body declares no `deinit`."""
    code = code_of(version.lines[index])
    match = GENERIC_CLASS.search(code)
    if match is None or re.search(r"\bnonisolated\b", code[:match.end()]):
        return False, []
    depth, opened = 0, False
    for j in range(index, len(version.lines)):
        line = code_of(version.lines[j])
        if opened and depth == 1 and re.search(r"\bdeinit\b", line):
            return False, []
        for c in line if j > index else line[match.start():]:
            if c == "{":
                depth += 1
                opened = True
            elif c == "}":
                depth -= 1
        if opened and depth <= 0:
            break
    return True, []


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
    Rule("deinit-main-only", "A deinit that tests for the main thread (and skips its cleanup off main)",
         "the last reference often goes on another thread (a task, a callback, an action's scope): the deinit then "
         "skips its cleanup and the task, stream or observer it owns runs on for good",
         "cancel the Sendable handles (Task, AsyncStream continuation, DemandTimer, a Sendable connection) directly "
         "in the nonisolated deinit, and hold observers in a MainActorObservation, which removes itself when released",
         "// deinit-main-allow: <the main-only teardown and why skipping it off main is safe>",
         matcher_rule(Matcher(MAIN_ONLY_GUARD, DEINIT_MAIN_ALLOW, in_deinit))),
    Rule("unchecked-sendable", "`@unchecked Sendable` / `nonisolated(unsafe)` without a safety argument",
         "it switches off the data-race checker; without a written argument nobody can review it",
         "an actor, a Sendable value type, or CmuxNextCompat `Mutex` around the state; when it is truly safe, "
         "say why on the declaration: `// crash-allow: <the safety argument>` (crash_ratchet.py honors it too)",
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
    Rule("generic-class-deinit", "A generic class with an implicit deinit (main-actor by default)",
         "swift-frontend 6.3.3 (Xcode 26.6) crashes with signal 11 in -O on the implicit isolated deinit of a generic "
         "main-actor class (EarlyPerfInliner, isCallerAndCalleeLayoutConstraintsCompatible): the Release test build "
         "and every Release bench stop (2026-10-23: PageTestWait.Once, CloudPaneTests.Seen)",
         "give it `nonisolated deinit {}` (or a nonisolated deinit that does its cleanup), declare the class "
         "`nonisolated`, or make the box non-generic",
         "// generic-class-allow: <why this class is not main-actor isolated, e.g. its target's default isolation>",
         matcher_rule(Matcher(GENERIC_CLASS, GENERIC_CLASS_ALLOW, implicit_deinit)),
         scope=(SOURCES, TESTS)),
    Rule("bench-hooks-shipped", "The bench configuration in a shipped build's settings",
         "CMUX_BENCH_HOOKS (reload.sh --config bench) keeps the debug.* control commands in an optimized app for "
         "the fleet benches; in a release, nightly or RC build's settings it would ship them to users",
         "build benches with `scripts/reload.sh --config bench` or a measure script's `--config=bench` only; "
         "shipped pipelines run scripts/cmux-next/check-no-bench-hooks.sh on their app",
         None,
         line_rule(r"CMUX_BENCH_HOOKS|--config[= ]bench\b", None),
         scope=SHIPPED_BUILD + (".xcconfig", "project.pbxproj")),
    Rule("app-big-file", f"New CmuxNextApp file over {NEW_APP_FILE_MAX} lines",
         "the App target re-emits its whole module on every edit (check-app-size.sh) and CI refuses god files",
         "put the feature in its own target under Packages/macOS/CmuxNext/Sources, one type per file",
         None,
         big_new_app_file),
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


def app_warnings(changes: dict[str, FileChange]) -> list[str]:
    # Swift only, like check-app-size.sh: a string catalog or asset change does not grow the module.
    app = {p: c for p, c in changes.items() if p.startswith(APP) and p.endswith(".swift")}
    added = sum(len(c.added) for c in app.values())
    removed = sum(len(c.removed) for c in app.values())
    new_files = sorted(p for p, c in app.items() if c.is_new)
    out = []
    if new_files:
        out.append(f"adds {len(new_files)} file(s) to CmuxNextApp ({new_files[0]}...): new features get their own target "
                   "(plans/cmux-next/code-quality.md SW14); the App only shrinks")
    if added - removed > 0:
        out.append(f"grows CmuxNextApp by {added - removed} lines (CI's check-app-size.sh cap may refuse it)")
    return out


# ---------------------------------------------------------------- run

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
    files = [changes[p] for p in paths]
    moved = collections.Counter(r.text.strip() for c in files for r in c.removed if r.text.strip())
    refusals = []
    for rule in RULES:
        hits = rule.find([f for f in files if f.path.startswith(rule.scope) or f.path.endswith(rule.scope)], moved)
        if hits:
            refusals.append((rule, hits))
    try:
        benches = json.loads(texts[(head, BENCHES)]) if (head, BENCHES) in texts else {}
    except json.JSONDecodeError:
        benches = {}
    warnings += [("perf-hot", w) for w in perf_hot_warnings(changes, benches)]
    if (head, OWNERS) in texts:
        names_list = [f for f in names.split("\n") if f]
        warnings += [("owner", w) for w in owner_warnings(names_list, parse_owners(texts[(head, OWNERS)]))]
    warnings += [("app-grow", w) for w in app_warnings(changes)]
    return refusals, warnings


def check_push(repo: Path, base: str, head: str, upstream_ref: str = UPSTREAM):
    """check() for a pushed BASE..HEAD, without the lines the push only brings in from UPSTREAM_REF.

    A branch merged with or rebased onto feat-cmux-next pushes every line others landed there since its fork
    point. CI never runs these rules, so those lines can carry debt the push did not write (a skip reason, a
    clone with old or no hooks, --no-verify). Rebased or fast-forwarded onto it (its merge base with HEAD
    descends from BASE): the range starts at that merge base. Merged it in (neither descends from the other):
    a hit counts only when it is also new against that merge base, and the warnings are the branch's own.
    """
    upstream = git(repo, "merge-base", head, upstream_ref, check=False).strip()
    if not upstream or upstream == base or is_ancestor(repo, upstream, base):
        return check(repo, base, head)
    if is_ancestor(repo, base, upstream):
        return check(repo, upstream, head)
    pushed, _ = check(repo, base, head)
    branch, warnings = check(repo, upstream, head)
    own = collections.Counter((rule.id, h.path, h.text.strip()) for rule, hits in branch for h in hits)
    refusals = []
    for rule, hits in pushed:
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

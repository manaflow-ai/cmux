#!/usr/bin/env python3
"""p06 queue generator: the file groups of the scheduler sweep (plans/cmux-next/chrome-parity/p06-scheduler.md
section 6, task p06-scheduler-216).

1. Runs the machine queues Q1-Q8, Q10, Q11 and QA over Packages/macOS/CmuxNext/Sources, plus Q1b, the
   main-inherited Task predicate (arch_counts.py's `main_inherited_tasks` row from task 015 when it exists,
   else section 6's heuristic: a plain `Task {` in a file that names a main-actor isolation; `Task { @concurrent
   in` and `Task.detached` are off main). The queue regexes are section 6's `git grep -E` commands; a line with
   `///` is dropped, as `| grep -v '///'` does.
2. Judges each hit in its state after the migration: a `MainDelivery(class:` is the R-delivery target, a notice name
   passed straight to a WindowEvents or AppEvents `subscribe(` is the R-notif target, as is the center given to
   `AppEvents(center:` in the composition root AppServices.swift only (one observer per center for the app), and an
   override that the recipe keeps (R-hide `viewDidHide`/`viewDidUnhide`, R-input `mouseMoved`/`scrollWheel`/
   `mouseDragged`, R-appear `viewDidChangeEffectiveAppearance`) is settled when its body does only what the
   recipe allows. A settled hit is listed by --group and not counted by --check.
3. Groups the hits by file. A line two queues hit counts once in a file's hits.
4. Assigns every file to at most one group. The plan is WORK.tsv's file-group rows (`p06-scheduler-3NN`,
   title `FG: ...`), so `--check 302` means task p06-scheduler-302's files. Membership depends on the path
   only, never on the hits, so it does not move while a sweep removes hits or when the Q1b predicate changes:
   - a file is in the row whose paths match it, at any revision (a new file in a row's folder is the row's);
   - rows that share a folder (`(first half by file name)`) split it by name into runs of about equal hits,
     one per row in row order, weighed by the regex queues' matches in the cut's text (never Q1b), and a file
     goes to the run its name falls in;
   - a file in a folder that rows cover by name ranges (`Handlers/[C-H]*.swift`) but that no range matches
     (`Handlers/I*`) goes to the row whose range starts last at or before its name;
   - any other file is in no group: its hits are residual (--residual, task p06-scheduler-347), and the
     report warns about the files at the cut that no row covers so the lead can add a row.
   `--repack` ignores the plan and packs the files with hits at the cut into groups from 300: by directory
   first (a directory with at most 70 hits stays in one group; a larger one splits into its subdirectories and
   its own files, those split by OWNERS.md owner and then by name), then neighbors merge up to 70 hits,
   closing a group at an owner change once it has 40. A packed group holds its files of the cut and later
   files next to them by name in the same folder. Packing reads the hits, so --repack is a planning view.
5. Prints per group: the files, each file's recipes (section 4 "Recipes") and owner, the owners to tell
   (plans/cmux-next/OWNERS.md, read with guardrails.py's parser so a file's owner is the hook's), and the
   check command for the options in use. A planned row over 70 hits at the cut is a plan problem: the report
   names it, and the fix is a WORK.tsv split, not a repack.

Hits are counted at --rev (default the working tree); the cut is --cut (default the spec's measured sha).

A hit is a reviewed escape when `// <rule>-allow: <why>` for its queue's guardrail rule is in the hook's escape
window (guardrails.escape_window: the line, the comment and attribute block directly above it, or the trailing
comment of the code line before it). The rules are section 3F's: main-hop (Q1, Q1b, Q1c, Q7), view-observation
(Q2, Q3, Q10, Q11), raw-observer (Q4), visibility-walk (Q5, QA), timer-class (Q6), local-monitor (Q8).
`--check` counts neither escapes nor settled hits.

`--undocumented` lists the public and open declarations of CmuxNextWakeups that have no `///` doc comment
(task 205: the frozen API lands with DocC on every public signature) and exits 1 while there are any. A protocol
witness whose doc DocC takes from the protocol (`==`, `<`, `hash(into:)`, `description`, `encode(to:)`, ...) needs
none.

Local tool, never CI (CLAUDE.md: no new CI gates). Tests: python3 -m pytest tests/test_p06_queue.py

Usage: scripts/cmux-next/p06_queue.py [--repo DIR] [--rev REV] [--cut REV] [--plan TSV | --repack] [--json]
                                      [--group N | --check N | --residual | --undocumented]
"""
from __future__ import annotations

import argparse
import bisect
import collections
import dataclasses
import functools
import importlib.util
import json
import math
import posixpath
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCES = "Packages/macOS/CmuxNext/Sources/"
CUT_REV = "772cdfc45ac"  # p06-scheduler.md section 8: the cut was measured here
PLAN = "plans/cmux-next/chrome-parity/WORK.tsv"
OWNERS = "plans/cmux-next/OWNERS.md"
LOW, HIGH = 40, 70
FIRST_GROUP = 300
RECIPES = ("R-hop", "R-delivery", "R-obs", "R-wait", "R-index", "R-notif", "R-vis", "R-hide", "R-timer",
           "R-input", "R-monitor", "R-appear")


@functools.cache
def _load(name: str):
    spec = importlib.util.spec_from_file_location(f"p06_{name}", HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------- queues

@dataclasses.dataclass(frozen=True)
class Queue:
    id: str
    pattern: re.Pattern[str] | None  # None: Q1b, a predicate over the whole file
    recipe: Callable[[str], str]
    rule: str  # the escape is `// <rule>-allow: <why>`
    skips: Callable[[str], bool] = lambda path: False


def _fixed(recipe: str) -> Callable[[str], str]:
    return lambda text: recipe


QUEUES = (
    Queue("Q1", re.compile(r"Task *(\(priority:[^)]*\))? *\{ *@MainActor"), _fixed("R-hop"), "main-hop"),
    Queue("Q1b", None, _fixed("R-hop"), "main-hop"),
    Queue("Q1c", re.compile(r"DispatchQueue\.main\.async|CFRunLoopPerformBlock|RunLoop\.main\.perform|MainDelivery\("),
          lambda text: "R-delivery" if re.search(r"MainDelivery\(|CFRunLoopPerformBlock", text) else "R-hop",
          "main-hop"),
    Queue("Q2", re.compile(r"ObservationStream\("), _fixed("R-obs"), "view-observation",
          lambda path: path.endswith("/CmuxNextCompat/ObservationStream.swift")),
    Queue("Q3", re.compile(r"withObservationTracking"), _fixed("R-obs"), "view-observation",
          lambda path: path.rsplit("/", 1)[-1] == "ObservationStream.swift"),
    Queue("Q4", re.compile(r"addObserver\(|(NSWindow|NSApplication)\.(did|will)[A-Za-z]+Notification"
                           r"|NSWorkspace\.shared\.notificationCenter|notifications\(named:"
                           r"|DistributedNotificationCenter|\.observe\(\\\.|NSView\.(frame|bounds)DidChangeNotification"
                           r"|didUpdateNotification"), _fixed("R-notif"), "raw-observer"),
    Queue("Q5", re.compile(r"isHiddenOrHasHiddenAncestor|override func viewDid(Hide|Unhide)\b"),
          lambda text: "R-hide" if re.search(r"override func viewDid(Hide|Unhide)\b", text) else "R-vis",
          "visibility-walk"),
    Queue("Q6", re.compile(r"DemandTimer\(|Task\.sleep|\.sleep\((for|until):"), _fixed("R-timer"), "timer-class"),
    Queue("Q7", re.compile(r"MainActor\.run\b"), _fixed("R-hop"), "main-hop"),
    Queue("Q8", re.compile(r"override func (mouseMoved|scrollWheel|mouseDragged)\(|addLocalMonitorForEvents"),
          lambda text: "R-monitor" if "addLocalMonitorForEvents" in text else "R-input", "local-monitor"),
    Queue("Q10", re.compile(r"for await .* in ObservationStream\(.*where .*\{ *(return|break)"), _fixed("R-wait"),
          "view-observation"),
    Queue("Q11", re.compile(r"ObservationStream\(.*(workspaces|allTabs|\.tabs\b|\.panes\b|\.contains *\{"
                            r"|first\(where|filter *\{|\.map *\{|machines\.)|locateTab\("),
          _fixed("R-index"), "view-observation"),
    Queue("QA", re.compile(r"override func viewDidChangeEffectiveAppearance"), _fixed("R-appear"), "visibility-walk"),
)
QUEUE_BY_ID = {q.id: q for q in QUEUES}

# Section 6's Q1b heuristic until task 015's predicate lands, as measured there (778 / 389 at the cut): a plain
# Task in a file that names a main-actor isolation: `@MainActor`, an AppKit view or controller superclass, or a
# SwiftUI View conformance. `Task { @concurrent in` is R-hop's nonisolated Task, not a main-inherited one.
_PLAIN_TASK = re.compile(r"\bTask *(\(priority:[^)]*\))? *\{(?! *@(MainActor|concurrent)\b)")
_MAIN_ACTOR_FILE = re.compile(r"@MainActor|:\s*(NSView|NSViewController|NSWindowController)\b|:[^{\n]*\bView\b")


def heuristic_main_inherited(path: str, text: str) -> list[int]:
    """Line numbers of plain Tasks in a file that names a main-actor isolation (section 6's Q1b heuristic)."""
    if not path.endswith(".swift") or not _MAIN_ACTOR_FILE.search(text):
        return []
    return [n for n, line in enumerate(text.split("\n"), 1) if _PLAIN_TASK.search(line)]


def main_inherited_predicate(arch=None) -> tuple[Callable[[str, str], list[int]], str]:
    """(lines(path, text), its name): arch_counts' main_inherited_tasks row when task 015 added it, else the
    heuristic. ARCH replaces the arch_counts module (tests)."""
    arch = arch or _load("arch_counts")
    if "main_inherited_tasks" not in arch.ROW_IDS:
        return heuristic_main_inherited, "heuristic (arch_counts has no main_inherited_tasks row yet; task 015)"

    def lines(path: str, text: str) -> list[int]:
        return [s.line for s in arch.analyze(path, text).sites if s.row == "main_inherited_tasks"]

    return lines, "arch_counts main_inherited_tasks"


# ---------------------------------------------------------------- the state after the migration

# A statement's receiver chain: `self.`, `layer?.`, `hover.node.` (whitespace is folded before matching).
_CHAIN = r"(?:(?:try|await) )*(?:\w+[?!]?\.)*"
_OVERRIDE = re.compile(r"\boverride\s+func\s+(\w+)\s*\(")


def _statements(body: str) -> list[str]:
    """The top-level statements of a blanked function BODY, whitespace folded. A nested closure stays inside
    its statement; a line that starts with `.` continues the one before it."""
    parts, current, depth = [], [], 0
    for char in body:
        depth += char in "([{"
        depth -= char in ")]}"
        if depth == 0 and char in "\n;":
            parts.append("".join(current))
            current = []
        else:
            current.append(char)
    parts.append("".join(current))
    statements: list[str] = []
    for part in (re.sub(r"\s+", " ", p).strip() for p in parts):
        if part and statements and part.startswith("."):
            statements[-1] += part
        elif part:
            statements.append(part)
    return statements


def _forwards_to_node(method: str, statement: str) -> bool:
    """R-hide: `viewDidHide`/`viewDidUnhide` only forward to the node; hidden-dirty work is deferUntilVisible."""
    return bool(re.fullmatch(rf"super\.{method}\(\)", statement)
                or re.match(rf"{_CHAIN}\w*[Nn]ode[?!]?\.", statement)
                or re.match(rf"{_CHAIN}deferUntilVisible\b", statement))


def _forwards_input(method: str, statement: str) -> bool:
    """R-input: cmux-side work goes through FrameInputCoalescer; a forwarded event keeps its order and count."""
    return bool(re.fullmatch(rf"{_CHAIN}{method}\(with: ?event\)", statement) and "." in statement
                or re.match(rf"{_CHAIN}\w*(?:[Cc]oalescer|[Ff]rameInput)\w*[?!]?\.", statement))


def _sets_layer_colors(method: str, statement: str) -> bool:
    """R-appear: a body that does more than set layer colors uses deferUntilVisible."""
    wrapped = re.fullmatch(rf"{_CHAIN}performAsCurrentDrawingAppearance ?\{{(.*)\}}", statement)
    if wrapped:
        return all(_sets_layer_colors(method, s) for s in _statements(wrapped.group(1)))
    return bool(re.fullmatch(rf"super\.{method}\(\)", statement)
                or re.match(rf"{_CHAIN}\w*[Ll]ayer[?!]?\.\w*[Cc]olor ?=", statement)
                or re.match(rf"{_CHAIN}deferUntilVisible\b", statement))


_KEPT_OVERRIDES = {"R-hide": _forwards_to_node, "R-input": _forwards_input, "R-appear": _sets_layer_colors}


class _Bodies:
    """Function bodies of one file, from arch_counts' blanked code and brace pairs."""

    def __init__(self, text: str) -> None:
        arch = _load("arch_counts")
        self.code = arch.strip(text)
        self.braces = arch.Braces(self.code)
        self.starts = [0] + [m.end() for m in re.finditer("\n", text)]

    def override(self, index: int) -> tuple[str, str] | None:
        """(method, body) of the `override func` declared on line INDEX."""
        end = self.starts[index + 1] if index + 1 < len(self.starts) else len(self.code)
        match = _OVERRIDE.search(self.code, self.starts[index], end)
        return (match.group(1), self._body(match.end())) if match else None

    def helper(self, statement: str) -> str | None:
        """The body of the one same-file `func NAME()` with no parameters that STATEMENT (`name()`,
        `self.name()`) calls, so `applyColors()` is judged by what it does."""
        call = re.fullmatch(r"(?:self\.)?(\w+)\(\)", statement)
        if not call:
            return None
        found = list(re.finditer(rf"\bfunc\s+{call.group(1)}\s*\(\s*\)", self.code))
        return self._body(found[0].end()) if len(found) == 1 else None

    def _body(self, after: int) -> str:
        opening = self.code.find("{", after)
        return "" if opening < 0 else self.code[opening + 1:self.braces.close.get(opening, len(self.code))]


def _delivery_settled(lines: list[str], index: int) -> bool:
    """R-delivery's target: every Q1c token on the line is a `MainDelivery(` whose first argument is `class:`."""
    code = _load("swift_scope").code_of(lines[index])
    if re.search(r"DispatchQueue\.main\.async|CFRunLoopPerformBlock|RunLoop\.main\.perform", code):
        return False
    following = _load("swift_scope").code_of(lines[index + 1]) if index + 1 < len(lines) else ""
    calls = [code[m.end():].strip() or following.strip() for m in re.finditer(r"MainDelivery\(", code)]
    return bool(calls) and all(re.match(r"class\s*:", rest) for rest in calls)


# The one file that may make an `AppEvents`: one per notification center for the whole app (R-notif). An
# `AppEvents(center:` anywhere else is a second observer per name, the pattern R-notif removes.
COMPOSITION_ROOT = SOURCES + "CmuxNextApp/AppServices.swift"
_ROOT_APP_EVENTS = re.compile(r"\bAppEvents\(center:\s*NSWorkspace\.shared\.notificationCenter\b")


def _notice_settled(path: str, lines: list[str], index: int) -> bool:
    """R-notif's target: the line's only Q4 matches are notice names passed straight to a WindowEvents or AppEvents
    `subscribe(` (the hook's raw-observer rule judges it the same way, guardrails.raw_observer_in), or, in the
    composition root only, the workspace center handed to the app's one `AppEvents(center:`."""
    code = _load("swift_scope").code_of(lines[index])
    if path == COMPOSITION_ROOT:
        code = _ROOT_APP_EVENTS.sub("AppEvents(center: workspaceCenter", code)
    return not _load("guardrails").raw_observer_in(code)


def _settled(recipe: str, path: str, lines: list[str], index: int, bodies: Callable[[], _Bodies]) -> bool:
    if recipe == "R-delivery":
        return _delivery_settled(lines, index)
    if recipe == "R-notif":
        return _notice_settled(path, lines, index)
    allowed = _KEPT_OVERRIDES.get(recipe)
    if allowed is None:
        return False
    found = bodies().override(index)
    if found is None:
        return False
    method, body = found

    def judged(statements: list[str], depth: int) -> bool:
        for statement in statements:
            if allowed(method, statement):
                continue
            helper = bodies().helper(statement) if depth else None
            if helper is None or not judged(_statements(helper), depth - 1):
                return False
        return True

    return judged(_statements(body), 1)


@dataclasses.dataclass(frozen=True)
class Hit:
    queue: str
    path: str
    line: int
    text: str
    recipe: str
    escaped: bool
    settled: bool = False  # the line still matches, but it is the recipe's target (module docstring, step 2)

    @property
    def open(self) -> bool:
        return not self.escaped and not self.settled


def _escaped(lines: list[str], index: int, rule: str) -> bool:
    mark = re.compile(rf"//\s*{re.escape(rule)}-allow:\s*\S")
    return any(mark.search(lines[j]) for j in _load("guardrails").escape_window(lines, index))


def scan(files: dict[str, str], main_inherited: Callable[[str, str], list[int]]) -> list[Hit]:
    """Every queue hit in FILES {path: text}, in path and line order."""
    hits = []
    for path in sorted(files):
        text = files[path]
        lines = text.split("\n")
        found: list[tuple[int, Queue]] = []
        # A queue that matches nowhere in the text matches no line; the rest are read line by line, as git grep.
        present = [q for q in QUEUES if q.pattern and not q.skips(path) and q.pattern.search(text)]
        for index, line in enumerate(lines if present else ()):
            if "///" not in line:
                found += [(index, q) for q in present if q.pattern.search(line)]
        if "Task" in text:
            q1b = QUEUE_BY_ID["Q1b"]
            found += [(n - 1, q1b) for n in main_inherited(path, text) if 0 < n <= len(lines) and "///" not in lines[n - 1]]
        bodies = functools.cache(lambda: _Bodies(text))
        for index, q in sorted(found, key=lambda f: (f[0], QUEUES.index(f[1]))):
            line = lines[index]
            recipe = q.recipe(line)
            hits.append(Hit(q.id, path, index + 1, line.strip(), recipe, _escaped(lines, index, q.rule),
                            _settled(recipe, path, lines, index, bodies)))
    return hits


# ---------------------------------------------------------------- the frozen API's DocC

WAKEUPS = SOURCES + "CmuxNextWakeups/"
_PUBLIC_DECL = re.compile(r"^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*"
                          r"(?:(?:nonisolated|final|override|static|class|mutating|convenience|required|indirect|lazy)\s+)*"
                          r"(?:public|open)(?:\(set\))?\s+(?!import\b|extension\b|=)")
_WITNESS = re.compile(r"\bstatic func (?:==|!=|<|<=|>|>=|\+|-)\s*\(|\bfunc hash\(into\b|\bvar (?:description|debugDescription)\b"
                      r"|\bfunc encode\(to\b|\binit\(from decoder\b|\bfunc makeIterator\(\)|\bfunc next\(\)")


def _documented(lines: list[str], index: int) -> bool:
    """Whether the declaration at INDEX has a doc comment: `///` lines or a `/** */` block above it, past its
    attribute lines and plain `//` comments."""
    j = index - 1
    while j >= 0:
        above = lines[j].strip()
        if above.startswith("///") or above.endswith("*/"):
            return True
        if above.startswith("@") or (above.startswith("//") and not above.startswith("///")):
            j -= 1
            continue
        return False
    return False


def undocumented(files: dict[str, str]) -> list[tuple[str, int, str]]:
    """(path, line, text) of each public or open declaration under CmuxNextWakeups with no doc comment."""
    found = []
    for path in sorted(p for p in files if p.startswith(WAKEUPS) and p.endswith(".swift")):
        lines = files[path].split("\n")
        for index, line in enumerate(lines):
            if _PUBLIC_DECL.match(line) and not _WITNESS.search(line) and not _documented(lines, index):
                found.append((path, index + 1, line.strip()))
    return found


# ---------------------------------------------------------------- reading a tree

def _git(repo: Path, *args: str, data: bytes | None = None) -> bytes:
    return subprocess.run(["git", "-C", str(repo), *args], input=data, capture_output=True, check=True).stdout


def read_tree(repo: Path, rev: str | None) -> dict[str, str]:
    """{path: text} of the tracked text files under SOURCES at REV, or in the working tree when REV is None."""
    if rev is None:
        paths = [p for p in _git(repo, "ls-files", "-z", "--", SOURCES).decode().split("\0") if p]
        blobs = {}
        for path in paths:
            try:
                blobs[path] = (repo / path).read_bytes()
            except FileNotFoundError:  # deleted in the working tree, not yet in the index
                continue
    else:
        entries = [e.split("\t", 1) for e in _git(repo, "ls-tree", "-r", "-z", rev, "--", SOURCES).decode().split("\0") if e]
        paths = [path for meta, path in entries if meta.split()[1] == "blob"]  # not a submodule's commit
        out = _git(repo, "cat-file", "--batch", data="".join(f"{rev}:{p}\n" for p in paths).encode())
        blobs, at = {}, 0
        for path in paths:
            header_end = out.index(b"\n", at)
            size = int(out[at:header_end].split()[2])
            blobs[path] = out[header_end + 1:header_end + 1 + size]
            at = header_end + 1 + size + 1
    return {p: b.decode("utf-8", "replace") for p, b in blobs.items() if b"\0" not in b}


# ---------------------------------------------------------------- owners

def owners_of(path: str, rows, guardrails) -> tuple[str, ...]:
    """The OWNERS.md owners of PATH: the most specific matching rows, as guardrails.owner_warnings picks them."""
    scored = [(max(guardrails.glob_specificity(g) for g in globs if guardrails.glob_match(path, g)), owner)
              for _, globs, owner, _ in rows if any(guardrails.glob_match(path, g) for g in globs)]
    if not scored:
        return ()
    best = max(score for score, _ in scored)
    return tuple(sorted({owner for score, owner in scored if score == best}))


# ---------------------------------------------------------------- the plan

@dataclasses.dataclass(frozen=True)
class PlanRow:
    id: int
    title: str
    specs: tuple[str, ...]


def _braces(spec: str) -> list[str]:
    match = re.search(r"\{([^{}]*)\}", spec)
    if not match:
        return [spec]
    return [x for part in match.group(1).split(",")
            for x in _braces(spec[:match.start()] + part.strip() + spec[match.end():])]


def _row_specs(cell: str) -> list[str]:
    """One WORK.tsv path with its parenthetical: `D/ (root files second half, FreeTier/, Approvals/)` is
    D's root files plus D/FreeTier/ and D/Approvals/. A half is the row's place among the rows that share the
    path (split_contested), so the words `first half` need no reading."""
    match = re.fullmatch(r"(.*?)\s*\((.*)\)\s*", cell)
    base, prose = (match.group(1), match.group(2)) if match else (cell, "")
    specs = _braces(base) if base else []
    if base.endswith("/") and prose:
        if re.search(r"\broot files\b", prose):
            specs = [f"{s}*.swift" for s in specs]
        specs += [f"{base}{folder}" for folder in re.findall(r"\b([A-Z]\w*/)", prose)]
    return specs


def parse_plan(tsv: str) -> list[PlanRow]:
    """WORK.tsv's file-group rows: `p06-scheduler-3NN` whose title starts with `FG:`."""
    rows = []
    for line in tsv.splitlines()[1:]:
        cells = line.split("\t")
        if len(cells) < 6 or cells[1] != "p06-scheduler" or not cells[4].startswith("FG:"):
            continue
        specs = [s for part in cells[5].split(";") if part.strip() for s in _row_specs(part.strip())]
        rows.append(PlanRow(int(cells[0].rsplit("-", 1)[1]), cells[4][3:].strip(), tuple(specs)))
    return sorted(rows, key=lambda r: r.id)


def spec_match(path: str, spec: str) -> bool:
    """A WORK.tsv path: a trailing `/` is a folder prefix; `*` and `[B-M]` match within one folder."""
    if spec.endswith("/"):
        return path.startswith(spec)
    return _spec_pattern(spec).fullmatch(path) is not None


@functools.cache
def _spec_pattern(spec: str) -> re.Pattern[str]:
    parts = []
    for token in re.split(r"(\*|\[[^\]]*\])", spec):
        if token == "*":
            parts.append("[^/]*")
        elif token.startswith("[") and token.endswith("]") and len(token) > 2:
            parts.append(token)
        else:
            parts.append(re.escape(token))
    return re.compile("".join(parts))


def _name_floor(spec: str) -> tuple[str, str] | None:
    """(folder, the first name it matches) of a name-range glob in one folder (`D/[C-H]*.swift` is (D, "c"),
    `D/*.swift` is (D, "")); None for a folder prefix."""
    if spec.endswith("/") or "/" not in spec:
        return None
    folder, name = spec.rsplit("/", 1)
    match = re.match(r"\[(\w)-\w\]|([^*\[]*)", name)
    return folder, (match.group(1) or match.group(2) or "").casefold()


# ---------------------------------------------------------------- packing (--repack)

def split_balanced(paths: list[str], weight: dict[str, int], parts: int) -> list[list[str]]:
    """PATHS, in order, as at most PARTS contiguous runs of about equal weight (a file is never split)."""
    total = sum(weight[p] for p in paths) or 1
    runs: list[list[str]] = [[] for _ in range(parts)]
    before = 0
    for path in paths:
        runs[min(parts - 1, int((before + weight[path] / 2) * parts / total))].append(path)
        before += weight[path]
    return [r for r in runs if r]


@dataclasses.dataclass
class Block:
    files: list[str]
    hits: int
    owners: frozenset[str]


def _block(files: list[str], weight: dict[str, int], owners: dict[str, tuple[str, ...]]) -> Block:
    return Block(sorted(files), sum(weight[f] for f in files), frozenset(o for f in files for o in owners[f]))


def _split_flat(files: list[str], weight, owners) -> list[Block]:
    if sum(weight[f] for f in files) <= HIGH:
        return [_block(files, weight, owners)] if files else []
    by_owner: dict[tuple[str, ...], list[str]] = collections.defaultdict(list)
    for f in sorted(files):
        by_owner[owners[f]].append(f)
    blocks = []
    for same in by_owner.values():
        parts = max(1, math.ceil(sum(weight[f] for f in same) / HIGH))
        runs = split_balanced(same, weight, parts)
        while any(len(r) > 1 and sum(weight[f] for f in r) > HIGH for r in runs):
            parts += 1
            runs = split_balanced(same, weight, parts)
        blocks += [_block(run, weight, owners) for run in runs]
    return blocks


def _merge(pieces: list[Block]) -> list[Block]:
    groups: list[Block] = []
    for piece in sorted(pieces, key=lambda b: b.files[0]):
        last = groups[-1] if groups else None
        if last and last.hits + piece.hits <= HIGH and (last.hits < LOW or last.owners == piece.owners):
            groups[-1] = Block(last.files + piece.files, last.hits + piece.hits, last.owners | piece.owners)
        else:
            groups.append(piece)
    merged = True
    while merged:  # a group still under LOW joins its lighter neighbor when that fits
        merged = False
        for i, group in enumerate(groups):
            if group.hits >= LOW:
                continue
            near = [j for j in (i - 1, i + 1) if 0 <= j < len(groups) and groups[j].hits + group.hits <= HIGH]
            if near:
                j = min(near, key=lambda k: groups[k].hits)
                a, b = sorted((i, j))
                groups[a:b + 1] = [Block(groups[a].files + groups[b].files, groups[a].hits + groups[b].hits,
                                         groups[a].owners | groups[b].owners)]
                merged = True
                break
    return groups


def pack(files: list[str], weight: dict[str, int], owners: dict[str, tuple[str, ...]], prefix: str = "") -> list[list[str]]:
    """FILES (all under PREFIX) as groups of about LOW-HIGH hits: by directory, then by owner, then by name."""

    def directory(prefix: str, files: list[str]) -> list[Block]:
        if sum(weight[f] for f in files) <= HIGH:
            return [_block(files, weight, owners)]
        own, children = [], collections.defaultdict(list)
        for f in files:
            rest = f[len(prefix):]
            if "/" in rest:
                children[rest.split("/", 1)[0]].append(f)
            else:
                own.append(f)
        pieces = [b for name in sorted(children) for b in directory(f"{prefix}{name}/", children[name])]
        return _merge(pieces + _split_flat(own, weight, owners))

    return [b.files for b in directory(prefix, sorted(files))] if files else []


# ---------------------------------------------------------------- the cut

@dataclasses.dataclass(frozen=True)
class Group:
    id: int
    title: str
    planned: bool


def split_contested(weight: dict[str, int], rows: tuple[int, ...]) -> list[str]:
    """The first path of each run after the first, when the rows that share a folder split its files by name
    (`(first half by file name)`) into runs of about equal WEIGHT, one per row in row order."""
    paths = sorted(p for p, w in weight.items() if w)
    runs = split_balanced(paths, weight, len(rows)) if paths else []
    return [run[0] for run in runs[1:]]


def frozen_weights(cut_hits: list[Hit]) -> dict[str, int]:
    """{path: lines the section 6 regex queues match} at the cut: what the shared folders are split by. It reads
    the regex queues only, never Q1b, escapes or settled state, so the split points stay where they are while the
    sweep removes hits and when task 015's predicate replaces the heuristic."""
    return {p: n for p, hs in by_file(cut_hits).items() if (n := len({h.line for h in hs if h.queue != "Q1b"}))}


class PlannedCut:
    """WORK.tsv's rows: a file's group is a function of its path (module docstring, step 4)."""

    def __init__(self, plan: list[PlanRow], split_weight: dict[str, int]) -> None:
        self.plan = plan
        self.groups = [Group(r.id, r.title, True) for r in plan]
        self.floors: dict[str, list[tuple[str, int]]] = collections.defaultdict(list)
        for row in plan:
            for spec in row.specs:
                if (floor := _name_floor(spec)) is not None:
                    self.floors[floor[0]].append((floor[1], row.id))
        shared: dict[tuple[int, ...], dict[str, int]] = collections.defaultdict(dict)
        for path, weight in split_weight.items():
            if len(rows := self._rows(path)) > 1:
                shared[rows][path] = weight
        self.boundaries = {rows: split_contested(weights, rows) for rows, weights in shared.items()}

    def _rows(self, path: str) -> tuple[int, ...]:
        return tuple(r.id for r in self.plan if any(spec_match(path, s) for s in r.specs))

    def group_of(self, path: str) -> int | None:
        rows = self._rows(path)
        if len(rows) > 1:
            return rows[bisect.bisect_right(self.boundaries.get(rows, []), path)]
        if rows:
            return rows[0]
        folder, name = path.rsplit("/", 1)
        floors = sorted(self.floors.get(folder, ()))
        if not floors:
            return None
        below = [row for floor, row in floors if floor <= name.casefold()]
        return below[-1] if below else floors[0][1]


class PackedCut:
    """--repack's groups: the files with hits at the cut, packed; a later file joins its name neighbor."""

    def __init__(self, weight: dict[str, int], owners: dict[str, tuple[str, ...]]) -> None:
        packed = pack(sorted(weight), weight, owners, SOURCES)
        self.groups = [Group(FIRST_GROUP + n, _label(files), False) for n, files in enumerate(packed)]
        self.held = {f: FIRST_GROUP + n for n, files in enumerate(packed) for f in files}
        self.folders: dict[str, list[str]] = collections.defaultdict(list)
        for path in sorted(self.held):
            self.folders[posixpath.dirname(path)].append(path)

    def group_of(self, path: str) -> int | None:
        if path in self.held:
            return self.held[path]
        near = self.folders.get(posixpath.dirname(path))
        if not near:
            return None
        return self.held[near[max(0, bisect.bisect_left(near, path) - 1)]]


def _label(files: list[str]) -> str:
    dirs = sorted({f[len(SOURCES):].rsplit("/", 1)[0] if "/" in f[len(SOURCES):] else "." for f in files})
    return ", ".join(dirs[:4]) + (f" and {len(dirs) - 4} more" if len(dirs) > 4 else "")


# ---------------------------------------------------------------- report

def open_lines(hits: list[Hit]) -> int:
    """Union open hits: a line two queues hit counts once; escapes and settled hits are done."""
    return len({(h.path, h.line) for h in hits if h.open})


def file_weights(hits: list[Hit]) -> dict[str, int]:
    """Union open hits per file."""
    return {p: n for p, hs in by_file(hits).items() if (n := open_lines(hs))}


def by_file(hits: list[Hit]) -> dict[str, list[Hit]]:
    files: dict[str, list[Hit]] = collections.defaultdict(list)
    for h in hits:
        files[h.path].append(h)
    return dict(files)


def recipes_of(hits: list[Hit]) -> list[str]:
    return sorted({h.recipe for h in hits}, key=RECIPES.index)


@dataclasses.dataclass
class Report:
    groups: list[Group]
    group_of: Callable[[str], int | None]
    cut_hits: dict[str, list[Hit]]
    hits: dict[str, list[Hit]]
    owners: Callable[[str], tuple[str, ...]]
    predicate: str
    rev: str
    cut_rev: str
    check_prefix: str = "python3 scripts/cmux-next/p06_queue.py"

    def __post_init__(self) -> None:
        self.members: dict[int | None, list[str]] = collections.defaultdict(list)
        for path in sorted(set(self.cut_hits) | set(self.hits)):
            self.members[self.group_of(path)].append(path)

    def group(self, gid: int) -> Group | None:
        return next((g for g in self.groups if g.id == gid), None)

    def files(self, gid: int | None) -> list[str]:
        return self.members.get(gid, [])

    def hits_at_cut(self, gid: int | None) -> int:
        return sum(open_lines(self.cut_hits.get(f, [])) for f in self.files(gid))

    def group_json(self, g: Group) -> dict:
        files = [f for f in self.files(g.id) if self.cut_hits.get(f) or self.hits.get(f)]
        return {
            "id": g.id, "title": g.title, "planned": g.planned,
            "hits_at_cut": self.hits_at_cut(g.id),
            "over_limit": g.planned and self.hits_at_cut(g.id) > HIGH,
            "hits_now": sum(open_lines(self.hits.get(f, [])) for f in files),
            "owners_to_tell": sorted({o for f in files for o in self.owners(f)}),
            "check": f"{self.check_prefix} --check {g.id}",
            "files": [{
                "path": f,
                "hits": open_lines(self.hits.get(f, [])),
                "settled": sum(h.settled and not h.escaped for h in self.hits.get(f, [])),
                "recipes": recipes_of([h for h in self.hits.get(f, []) if h.open]),
                "queues": dict(collections.Counter(h.queue for h in self.hits.get(f, []) if h.open)),
                "owner": list(self.owners(f)),
            } for f in files],
        }

    def residual(self) -> list[Hit]:
        """Open hits now in files no group holds: files no plan row covers and new files outside every row."""
        return [h for f in self.files(None) for h in self.hits.get(f, []) if h.open]

    def unplanned_at_cut(self) -> dict[str, int]:
        """{path: open hits} at the cut of the files no group holds: the plan's gaps."""
        return {f: n for f in self.files(None) if (n := open_lines(self.cut_hits.get(f, [])))}

    def over_limit(self) -> list[tuple[int, int]]:
        return [(g.id, self.hits_at_cut(g.id)) for g in self.groups if g.planned and self.hits_at_cut(g.id) > HIGH]

    def new_unheld(self) -> list[str]:
        """Files with open hits now that no group holds and that had none at the cut (new or moved code)."""
        return [f for f in self.files(None) if f not in self.cut_hits and open_lines(self.hits.get(f, []))]


def build(repo: Path, rev: str | None, cut_rev: str, plan_path: Path | None,
          predicate: tuple[Callable[[str, str], list[int]], str] | None = None,
          check_prefix: str = "python3 scripts/cmux-next/p06_queue.py") -> Report:
    guardrails = _load("guardrails")
    owner_rows = guardrails.parse_owners((repo / OWNERS).read_text()) if (repo / OWNERS).exists() else []
    cache: dict[str, tuple[str, ...]] = {}

    def owners(path: str) -> tuple[str, ...]:
        if path not in cache:
            cache[path] = owners_of(path, owner_rows, guardrails)
        return cache[path]

    lines, name = predicate or main_inherited_predicate()
    cut_tree = read_tree(repo, cut_rev)
    cut_list = scan(cut_tree, lines)
    now_list = cut_list if rev == cut_rev else scan(read_tree(repo, rev), lines)
    if plan_path:
        assign = PlannedCut(parse_plan(plan_path.read_text()), frozen_weights(cut_list))
    else:
        weight = file_weights(cut_list)
        assign = PackedCut(weight, {p: owners(p) for p in weight})
    return Report(assign.groups, assign.group_of, by_file(cut_list), by_file(now_list), owners, name,
                  rev or "working tree", cut_rev, check_prefix)


def print_group(report: Report, g: Group, out) -> None:
    data = report.group_json(g)
    origin = f"p06-scheduler-{g.id}" if g.planned else "packed"
    over = f" (over {HIGH}: split the row in WORK.tsv)" if data["over_limit"] else ""
    print(f"group {g.id} [{origin}]: {g.title}: {data['hits_at_cut']} hits at the cut{over}, {data['hits_now']} now, "
          f"{len(data['files'])} files", file=out)
    print(f"  owners to tell: {'; '.join(data['owners_to_tell']) or 'none'}", file=out)
    print(f"  check: {data['check']}", file=out)
    for f in data["files"]:
        queues = ", ".join(f"{q} {n}" for q, n in f["queues"].items())
        settled = f", {f['settled']} settled" if f["settled"] else ""
        print(f"  {f['path']}: {f['hits']} {'hit' if f['hits'] == 1 else 'hits'}, {', '.join(f['recipes']) or 'done'}"
              f"{f' ({queues})' if queues else ''}{settled}; owner {'; '.join(f['owner']) or 'none'}", file=out)


def plan_problems(report: Report) -> list[str]:
    problems = [f"row {gid} has {n} hits at the cut, over {HIGH}: split it in WORK.tsv"
                for gid, n in report.over_limit()]
    gaps = report.unplanned_at_cut()
    if gaps:
        folders = sorted({posixpath.dirname(f)[len(SOURCES):] for f in gaps})
        problems.append(f"{sum(gaps.values())} hits in {len(gaps)} files at the cut are in no WORK.tsv row "
                        f"(--residual lists them for task 347 until a row covers them): {', '.join(folders)}")
    return problems


def _hit_line(h: Hit) -> str:
    state = " escaped" if h.escaped else " settled" if h.settled else ""
    return f"{h.path}:{h.line}: [{h.queue} {h.recipe}{state}] {h.text}"


def main(argv: list[str] | None = None, out=sys.stdout) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--repo", type=Path, default=ROOT, help="the checkout (default: this one)")
    parser.add_argument("--rev", help="count hits at this revision (default: the working tree)")
    parser.add_argument("--cut", default=CUT_REV, help=f"the revision the groups are cut at (default {CUT_REV})")
    parser.add_argument("--plan", type=Path, help=f"WORK.tsv with the file-group rows (default {PLAN})")
    parser.add_argument("--repack", action="store_true", help="ignore the plan; pack every file from group 300")
    parser.add_argument("--json", action="store_true", help="print JSON")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--group", type=int, metavar="N", help="list every hit in group N's files")
    mode.add_argument("--check", type=int, metavar="N", help="exit 1 while group N's files have open hits")
    mode.add_argument("--residual", action="store_true", help="open hits in files no group holds (task 347)")
    mode.add_argument("--undocumented", action="store_true",
                      help="exit 1 while a public CmuxNextWakeups declaration has no doc comment (task 205)")
    args = parser.parse_args(argv)
    if args.repack and args.plan:
        parser.error("--plan and --repack exclude each other")
    repo = args.repo.resolve()
    if args.undocumented:
        missing = undocumented(read_tree(repo, args.rev))
        if args.json:
            print(json.dumps([{"path": p, "line": n, "text": t} for p, n, t in missing], indent=1), file=out)
        for path, line, text in [] if args.json else missing:
            print(f"{path}:{line}: {text}", file=out)
        return 1 if missing else 0
    plan = None if args.repack else (args.plan or repo / PLAN)
    options = (["--cut", args.cut] if args.cut != CUT_REV else []) + (["--repack"] if args.repack else []) + \
        (["--plan", str(args.plan)] if args.plan else [])
    try:
        report = build(repo, args.rev, args.cut, plan,
                       check_prefix=" ".join(["python3 scripts/cmux-next/p06_queue.py", *options]))
    except subprocess.CalledProcessError as error:
        print(f"p06_queue: git failed: {error.stderr.decode().strip()} (is --cut {args.cut} in this clone?)",
              file=sys.stderr)
        return 2

    if args.residual:
        hits = report.residual()
        if args.json:
            print(json.dumps([dataclasses.asdict(h) for h in hits], indent=1), file=out)
        for h in [] if args.json else hits:
            print(_hit_line(h), file=out)
        return 0
    gid = args.group if args.group is not None else args.check
    if gid is not None:
        g = report.group(gid)
        if g is None:
            print(f"p06_queue: no group {gid} at the cut {report.cut_rev}", file=sys.stderr)
            return 2
        every = [h for f in report.files(gid) for h in report.hits.get(f, [])]
        hits = every if args.group is not None else [h for h in every if h.open]
        if args.json:
            print(json.dumps({"group": report.group_json(g), "hits": [dataclasses.asdict(h) for h in hits]},
                             indent=1), file=out)
        else:
            for h in hits:
                print(_hit_line(h), file=out)
            print(f"group {gid}: {open_lines(every)} open hits at {report.rev}, "
                  f"{sum(h.escaped for h in every)} escaped, {sum(h.settled and not h.escaped for h in every)} settled",
                  file=out)
            new = report.new_unheld()
            if args.check is not None and new:
                print(f"note: {len(new)} files that had no hits at the cut have hits now and are in no group "
                      f"(--residual): {', '.join(new[:5])}{' ...' if len(new) > 5 else ''}", file=out)
        return 1 if args.check is not None and hits else 0

    problems = plan_problems(report) if plan else []
    for problem in problems:
        print(f"p06_queue: plan problem: {problem}", file=sys.stderr)
    if args.json:
        print(json.dumps({"rev": report.rev, "cut": report.cut_rev, "q1b": report.predicate,
                          "plan_problems": problems,
                          "unplanned": [{"path": f, "hits_at_cut": n} for f, n in report.unplanned_at_cut().items()],
                          "groups": [report.group_json(g) for g in report.groups]}, indent=1), file=out)
        return 0
    print(f"p06 queues: groups cut at {report.cut_rev}, hits at {report.rev}; Q1b: {report.predicate}", file=out)
    for problem in problems:
        print(f"plan problem: {problem}", file=out)
    for g in report.groups:
        print_group(report, g, out)
    gaps = report.unplanned_at_cut()
    if gaps:
        print(f"no row ({sum(gaps.values())} hits at the cut, residual for task 347):", file=out)
        for f, n in gaps.items():
            print(f"  {f}: {n} {'hit' if n == 1 else 'hits'} at the cut, {open_lines(report.hits.get(f, []))} now",
                  file=out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

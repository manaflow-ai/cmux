#!/usr/bin/env python3
"""p06 queue generator: the file groups of the scheduler sweep (plans/cmux-next/chrome-parity/p06-scheduler.md
section 6, task p06-scheduler-216).

1. Runs the machine queues Q1-Q8, Q10, Q11 and QA over Packages/macOS/CmuxNext/Sources, plus Q1b, the
   main-inherited Task predicate (arch_counts.py's `main_inherited_tasks` row from task 015 when it exists,
   else section 6's heuristic: a plain `Task {` in a file that names a main-actor isolation). The queue regexes
   are section 6's `git grep -E` commands; a line with `///` is dropped, as `| grep -v '///'` does.
2. Groups the hits by file. A line two queues hit counts once in a file's hits.
3. Assigns every file with hits to exactly one group. The planned cut is WORK.tsv's file-group rows
   (`p06-scheduler-3NN`, title `FG: ...`), so `--check 302` means task p06-scheduler-302's files. A file that
   several rows name (the two halves of CmuxNextSidebar/Views) goes to one of them: those files are split
   by path into hit-balanced runs, one per row, in row order. Files no row names are packed into new groups
   from 350, and `--repack` packs every file the same way (groups from 300): by directory first (a directory
   with at most 70 hits stays in one group; a larger one splits into its subdirectories and its own files,
   those split by OWNERS.md owner and then by name), then neighbors merge up to 70 hits, closing a group at an
   owner change once it has 40.
4. Prints per group: the files, each file's recipes (section 4 "Recipes") and owner, the owners to tell
   (plans/cmux-next/OWNERS.md, read with guardrails.py's parser so a file's owner is the hook's), and the
   check command.

Membership is frozen at the cut revision (--cut, default the spec's measured sha), so a group keeps its files
while the sweep removes their hits; hits are counted at --rev (default the working tree). A hit in a file no
group holds (new code since the cut) is a residual for task p06-scheduler-347 (--residual).

A hit is a reviewed escape when its line, or the comment line directly above it, has
`// <rule>-allow: <why>` for its queue's rule (the guardrail ids of task 014: main-hop, view-observation,
raw-observer, visibility-walk, timer-class, local-monitor; Q10, Q11 and QA have none there, so they use
store-wait, observation-index and appearance). `--check` does not count escapes.

Local tool, never CI (CLAUDE.md: no new CI gates). Tests: python3 -m pytest tests/test_p06_queue.py

Usage: scripts/cmux-next/p06_queue.py [--repo DIR] [--rev REV] [--cut REV] [--plan TSV | --repack] [--json]
                                      [--group N | --check N | --residual]
"""
from __future__ import annotations

import argparse
import collections
import dataclasses
import importlib.util
import json
import math
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
FIRST_PLANNED, FIRST_UNPLANNED = 300, 350
RECIPES = ("R-hop", "R-delivery", "R-obs", "R-wait", "R-index", "R-notif", "R-vis", "R-hide", "R-timer",
           "R-input", "R-monitor", "R-appear")


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
          "store-wait"),
    Queue("Q11", re.compile(r"ObservationStream\(.*(workspaces|allTabs|\.tabs\b|\.panes\b|\.contains *\{"
                            r"|first\(where|filter *\{|\.map *\{|machines\.)|locateTab\("),
          _fixed("R-index"), "observation-index"),
    Queue("QA", re.compile(r"override func viewDidChangeEffectiveAppearance"), _fixed("R-appear"), "appearance"),
)
QUEUE_BY_ID = {q.id: q for q in QUEUES}
_ANY_QUEUE = re.compile("|".join(f"(?:{q.pattern.pattern})" for q in QUEUES if q.pattern))

# Section 6's Q1b heuristic until task 015's predicate lands, as measured there (778 / 389 at the cut): a plain
# Task in a file that names a main-actor isolation: `@MainActor`, an AppKit view or controller superclass, or a
# SwiftUI View conformance.
_PLAIN_TASK = re.compile(r"\bTask *(\(priority:[^)]*\))? *\{(?! *@MainActor)")
_MAIN_ACTOR_FILE = re.compile(r"@MainActor|:\s*(NSView|NSViewController|NSWindowController)\b|:[^{\n]*\bView\b")


def heuristic_main_inherited(path: str, text: str) -> list[int]:
    """Line numbers of plain Tasks in a file that names a main-actor isolation (section 6's Q1b heuristic)."""
    if not path.endswith(".swift") or not _MAIN_ACTOR_FILE.search(text):
        return []
    return [n for n, line in enumerate(text.split("\n"), 1) if _PLAIN_TASK.search(line)]


def main_inherited_predicate() -> tuple[Callable[[str, str], list[int]], str]:
    """(lines(path, text), its name): arch_counts' main_inherited_tasks row when task 015 added it, else the
    heuristic."""
    arch = _load("arch_counts")
    if "main_inherited_tasks" not in arch.ROW_IDS:
        return heuristic_main_inherited, "heuristic (arch_counts has no main_inherited_tasks row yet; task 015)"

    def lines(path: str, text: str) -> list[int]:
        return [s.line for s in arch.analyze(path, text).sites if s.row == "main_inherited_tasks"]

    return lines, "arch_counts main_inherited_tasks"


@dataclasses.dataclass(frozen=True)
class Hit:
    queue: str
    path: str
    line: int
    text: str
    recipe: str
    escaped: bool


def _escaped(lines: list[str], index: int, rule: str) -> bool:
    mark = re.compile(rf"//\s*{re.escape(rule)}-allow:\s*\S")
    if mark.search(lines[index]):
        return True
    return index > 0 and lines[index - 1].lstrip().startswith("//") and bool(mark.search(lines[index - 1]))


def scan(files: dict[str, str], main_inherited: Callable[[str, str], list[int]]) -> list[Hit]:
    """Every queue hit in FILES {path: text}, in path and line order."""
    hits = []
    for path in sorted(files):
        text = files[path]
        lines = text.split("\n")
        found: list[tuple[int, Queue]] = []
        for index, line in enumerate(lines):
            if "///" in line or not _ANY_QUEUE.search(line):
                continue
            found += [(index, q) for q in QUEUES if q.pattern and not q.skips(path) and q.pattern.search(line)]
        if "Task" in text:
            q1b = QUEUE_BY_ID["Q1b"]
            found += [(n - 1, q1b) for n in main_inherited(path, text) if 0 < n <= len(lines) and "///" not in lines[n - 1]]
        for index, q in sorted(found, key=lambda f: (f[0], QUEUES.index(f[1]))):
            line = lines[index]
            hits.append(Hit(q.id, path, index + 1, line.strip(), q.recipe(line), _escaped(lines, index, q.rule)))
    return hits


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


def parse_plan(tsv: str) -> list[PlanRow]:
    """WORK.tsv's file-group rows: `p06-scheduler-3NN` whose title starts with `FG:`. A spec's trailing
    parenthetical (`(first half by file name)`) is prose; the halves are split by split_contested."""
    rows = []
    for line in tsv.splitlines()[1:]:
        cells = line.split("\t")
        if len(cells) < 6 or cells[1] != "p06-scheduler" or not cells[4].startswith("FG:"):
            continue
        specs = []
        for part in cells[5].split(";"):
            part = re.sub(r"\s*\(.*\)\s*$", "", part.strip())
            specs += _braces(part) if part else []
        rows.append(PlanRow(int(cells[0].rsplit("-", 1)[1]), cells[4][3:].strip(), tuple(specs)))
    return sorted(rows, key=lambda r: r.id)


def spec_match(path: str, spec: str) -> bool:
    """A WORK.tsv path: a trailing `/` is a folder prefix; `*` and `[B-M]` match within one folder."""
    if spec.endswith("/"):
        return path.startswith(spec)
    parts = []
    for token in re.split(r"(\*|\[[^\]]*\])", spec):
        if token == "*":
            parts.append("[^/]*")
        elif token.startswith("[") and token.endswith("]") and len(token) > 2:
            parts.append(token)
        else:
            parts.append(re.escape(token))
    return re.fullmatch("".join(parts), path) is not None


# ---------------------------------------------------------------- packing

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

@dataclasses.dataclass
class Group:
    id: int
    title: str
    files: list[str]
    planned: bool


def split_contested(paths: list[str], weight: dict[str, int], rows: tuple[int, ...]) -> dict[str, int]:
    """Files several plan ROWS name: hit-balanced runs by path, one per row in row order."""
    runs = split_balanced(sorted(paths), weight, len(rows))
    return {p: row for row, run in zip(rows, runs) for p in run}


def _label(files: list[str]) -> str:
    dirs = sorted({f[len(SOURCES):].rsplit("/", 1)[0] if "/" in f[len(SOURCES):] else "." for f in files})
    return ", ".join(dirs[:4]) + (f" and {len(dirs) - 4} more" if len(dirs) > 4 else "")


def cut(weight: dict[str, int], owners: dict[str, tuple[str, ...]], plan: list[PlanRow] | None) -> list[Group]:
    """Every file of WEIGHT {path: hits} in exactly one group: PLAN's rows first, the rest packed."""
    assigned: dict[str, int] = {}
    loose = []
    contested: dict[tuple[int, ...], list[str]] = collections.defaultdict(list)
    for path in sorted(weight):
        rows = tuple(r.id for r in plan or () if any(spec_match(path, s) for s in r.specs))
        if len(rows) == 1:
            assigned[path] = rows[0]
        elif rows:
            contested[rows].append(path)
        else:
            loose.append(path)
    for rows, paths in contested.items():
        assigned.update(split_contested(paths, weight, rows))
    titles = {r.id: r.title for r in plan or ()}
    members: dict[int, list[str]] = collections.defaultdict(list)
    for path, row in assigned.items():
        members[row].append(path)
    groups = [Group(row, titles[row], sorted(files), True) for row, files in sorted(members.items())]
    first = FIRST_UNPLANNED if plan is not None else FIRST_PLANNED
    for n, files in enumerate(pack(loose, weight, owners, SOURCES)):
        groups.append(Group(first + n, _label(files), files, False))
    return groups


# ---------------------------------------------------------------- report

def file_weights(hits: list[Hit]) -> dict[str, int]:
    """Union hits per file: a line two queues hit counts once."""
    lines: dict[str, set[int]] = collections.defaultdict(set)
    for h in hits:
        lines[h.path].add(h.line)
    return {p: len(s) for p, s in lines.items()}


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
    cut_hits: dict[str, list[Hit]]
    hits: dict[str, list[Hit]]
    owners: Callable[[str], tuple[str, ...]]
    predicate: str
    rev: str
    cut_rev: str

    def group(self, gid: int) -> Group | None:
        return next((g for g in self.groups if g.id == gid), None)

    def group_json(self, g: Group) -> dict:
        tell = sorted({o for f in g.files for o in self.owners(f)})
        return {
            "id": g.id, "title": g.title, "planned": g.planned,
            "hits_at_cut": sum(file_weights(self.cut_hits[f])[f] for f in g.files),
            "hits_now": sum(len({h.line for h in self.hits.get(f, []) if not h.escaped}) for f in g.files),
            "owners_to_tell": tell,
            "check": f"python3 scripts/cmux-next/p06_queue.py --check {g.id}",
            "files": [{
                "path": f,
                "hits": len({h.line for h in self.hits.get(f, []) if not h.escaped}),
                "recipes": recipes_of([h for h in self.hits.get(f, []) if not h.escaped]),
                "queues": dict(collections.Counter(h.queue for h in self.hits.get(f, []) if not h.escaped)),
                "owner": list(self.owners(f)),
            } for f in g.files],
        }

    def residual(self) -> list[Hit]:
        held = {f for g in self.groups for f in g.files}
        return [h for path, hs in sorted(self.hits.items()) if path not in held for h in hs if not h.escaped]


def build(repo: Path, rev: str | None, cut_rev: str, plan_path: Path | None) -> Report:
    guardrails = _load("guardrails")
    owner_rows = guardrails.parse_owners((repo / OWNERS).read_text()) if (repo / OWNERS).exists() else []
    cache: dict[str, tuple[str, ...]] = {}

    def owners(path: str) -> tuple[str, ...]:
        if path not in cache:
            cache[path] = owners_of(path, owner_rows, guardrails)
        return cache[path]

    predicate, name = main_inherited_predicate()
    cut_list = scan(read_tree(repo, cut_rev), predicate)
    now_list = cut_list if rev == cut_rev else scan(read_tree(repo, rev), predicate)
    cut_hits, now_hits = by_file(cut_list), by_file(now_list)
    weight = file_weights(cut_list)
    plan = parse_plan(plan_path.read_text()) if plan_path else None
    groups = cut(weight, {p: owners(p) for p in weight}, plan)
    return Report(groups, cut_hits, now_hits, owners, name, rev or "working tree", cut_rev)


def print_group(report: Report, g: Group, out) -> None:
    data = report.group_json(g)
    origin = f"p06-scheduler-{g.id}" if g.planned else "unplanned"
    over = f" (over {HIGH}: rebalance with --repack)" if data["hits_at_cut"] > HIGH and len(g.files) > 1 else ""
    print(f"group {g.id} [{origin}]: {g.title}: {data['hits_at_cut']} hits at the cut{over}, {data['hits_now']} now, "
          f"{len(g.files)} files", file=out)
    print(f"  owners to tell: {'; '.join(data['owners_to_tell']) or 'none'}", file=out)
    print(f"  check: {data['check']}", file=out)
    for f in data["files"]:
        queues = ", ".join(f"{q} {n}" for q, n in f["queues"].items())
        print(f"  {f['path']}: {f['hits']} {'hit' if f['hits'] == 1 else 'hits'}, {', '.join(f['recipes']) or 'done'}"
              f"{f' ({queues})' if queues else ''}; owner {'; '.join(f['owner']) or 'none'}", file=out)


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
    mode.add_argument("--check", type=int, metavar="N", help="exit 1 while group N's files have unescaped hits")
    mode.add_argument("--residual", action="store_true", help="hits in files no group holds (task 347)")
    args = parser.parse_args(argv)
    repo = args.repo.resolve()
    plan = None if args.repack else (args.plan or repo / PLAN)
    try:
        report = build(repo, args.rev, args.cut, plan)
    except subprocess.CalledProcessError as error:
        print(f"p06_queue: git failed: {error.stderr.decode().strip()} (is --cut {args.cut} in this clone?)",
              file=sys.stderr)
        return 2

    if args.residual:
        hits = report.residual()
        if args.json:
            print(json.dumps([dataclasses.asdict(h) for h in hits], indent=1), file=out)
        for h in [] if args.json else hits:
            print(f"{h.path}:{h.line}: [{h.queue} {h.recipe}] {h.text}", file=out)
        return 0
    gid = args.group if args.group is not None else args.check
    if gid is not None:
        g = report.group(gid)
        if g is None:
            print(f"p06_queue: no group {gid} at the cut {report.cut_rev}", file=sys.stderr)
            return 2
        hits = [h for f in g.files for h in report.hits.get(f, []) if args.group is not None or not h.escaped]
        if args.json:
            print(json.dumps({"group": report.group_json(g), "hits": [dataclasses.asdict(h) for h in hits]},
                             indent=1), file=out)
        else:
            for h in hits:
                print(f"{h.path}:{h.line}: [{h.queue} {h.recipe}{' escaped' if h.escaped else ''}] {h.text}", file=out)
            escaped = sum(h.escaped for f in g.files for h in report.hits.get(f, []))
            print(f"group {gid}: {len([h for h in hits if not h.escaped])} hits at {report.rev}, {escaped} escaped",
                  file=out)
        return 1 if args.check is not None and hits else 0

    if args.json:
        print(json.dumps({"rev": report.rev, "cut": report.cut_rev, "q1b": report.predicate,
                          "groups": [report.group_json(g) for g in report.groups]}, indent=1), file=out)
        return 0
    print(f"p06 queues: groups cut at {report.cut_rev}, hits at {report.rev}; Q1b: {report.predicate}", file=out)
    for g in report.groups:
        print_group(report, g, out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

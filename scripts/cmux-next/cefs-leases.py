#!/usr/bin/env python3
"""Compute the CEFS file leases of plans/cmux-next/coordination/cefs-leases.md (chrome-parity task p01-process-180).

One task at a time may change a shared Chromium file. Every input is observable in git, so every agent computes the
same holder:
  - the queue order of each row, read from the generated section of the lane file (only the lead reorders a row);
  - the tasks whose design-result.json `files` name a file, with `*`, `**`, `[..]` and `{a,b}` patterns expanded;
  - merged tasks: a task id in a subject of a commit that a first-parent commit of the base brings in;
  - open branches: `origin/cp/*` not merged into the base, mapped to a task id by name or by their commit subjects.

Usage:
  cefs-leases.py --check REF [--task ID]
                                    the lease files REF (your branch) changes and their holders; exit 1 when the task
                                    does not hold one of them (run it before every push)
  cefs-leases.py --holder FILE...   holder and queue of each FILE (repository paths)
  cefs-leases.py --write            regenerate the tables of the lane file in place (the lead, after landings)
  cefs-leases.py --write --fresh    rebuild every queue order from scratch (a lead decision; say so in the commit)
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LANE = "plans/cmux-next/coordination/cefs-leases.md"
DESIGN = "plans/cmux-next/chrome-parity/design-result.json"
BEGIN, END = "<!-- cefs-leases:begin -->", "<!-- cefs-leases:end -->"

PKG = "Packages/macOS/CmuxNext/"
APP = PKG + "Sources/"
CEFS = APP + "CmuxNextBrowser/CEF/"
HOST = PKG + "ChromiumHost/"
SHIM = PKG + "CEFShim/"
ROOTS = (CEFS, HOST, SHIM)
SHORT = ((CEFS, "CEFS/"), (HOST, "HOST/"), (SHIM, "CEFShim/"), (APP, "APP/"))
# Files that p01-process-001 moved from CEFShim to ChromiumHost: an older name means the new file.
MOVED = {SHIM + "src/browser_host_main.mm": HOST + "src/browser_host_main.mm",
         SHIM + "src/chromium_host_wire.h": HOST + "src/chromium_host_wire.h",
         SHIM + "tests/chromium_host_wire_test.cpp": HOST + "tests/chromium_host_wire_test.cpp"}
# Tasks whose files get a row even with one entry (p01-process.md, task 180).
LISTED_TASKS = tuple(f"p01-process-{n:03d}" for n in (30, 31, 32, 33, 34, 46, 48, 64, 69))
SITES = r"\bshim\??\.[a-zA-Z]+\("
# A task id, including the range ids of design-result.json (p02-threads-041..045).
TASK_ID = re.compile(r"(?<![A-Za-z0-9-])(p\d\d-[a-z]+(?:-[a-z]+)*-\d{3}[a-z]?(?:\.\.\d{3}[a-z]?)?)(?![A-Za-z0-9])")
DESIGN_DATE = "2026-10-25"
# How design-result.json abbreviates paths: (written start, repository start).
PREFIXES = (("Packages/", "Packages/"), ("P/", APP), ("CEF/", APP + "CmuxNextBrowser/CEF/"),
            ("CEFShim/", SHIM), ("ChromiumHost/", HOST), ("Tests/", PKG + "Tests/"), ("Sources/", APP),
            ("deps/", PKG + "deps/"), ("CmuxNext", APP + "CmuxNext"))


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def short(path: str) -> str:
    for full, abbrev in SHORT:
        if path.startswith(full):
            return abbrev + path[len(full):]
    return path


def expand(path: str) -> str:
    for full, abbrev in SHORT:
        if path.startswith(abbrev):
            return full + path[len(abbrev):]
    return path


# ---------------------------------------------------------------- patterns


def braces(pattern: str) -> list[str]:
    """`a/{b,c}/d` -> [`a/b/d`, `a/c/d`], every group."""
    match = re.search(r"\{([^{}]*)\}", pattern)
    if not match:
        return [pattern]
    head, tail = pattern[:match.start()], pattern[match.end():]
    return [out for part in match.group(1).split(",") for out in braces(head + part + tail)]


def full_pattern(entry: str) -> str | None:
    """The repository pattern of a design-result `files` entry, or None for prose. Drops ' (N)', ' (new)' and other
    parenthesized notes; an entry with other words after its path is prose."""
    words = entry.strip().split(" ", 1)
    if len(words) > 1 and not words[1].lstrip().startswith("("):
        return None
    path = words[0].strip("`")
    for start, prefix in PREFIXES:
        if path.startswith(start):
            return prefix + path[len(start):]
    return None


def pattern_regex(pattern: str) -> re.Pattern[str]:
    if pattern.endswith("/"):
        pattern += "**"
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif pattern[i] == "[":
            end = pattern.index("]", i)
            out, i = out + pattern[i:end + 1], end + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(out)


def literal_start(pattern: str) -> str:
    cut = min([pattern.find(c) for c in "*[" if c in pattern] or [len(pattern)])
    return pattern[:cut]


def lease_root(path: str) -> str:
    """The folder a pattern must be narrower than to name PATH (else it is a sweep of PATH)."""
    return next((root for root in ROOTS if path.startswith(root)), path.rsplit("/", 1)[0] + "/")


# ---------------------------------------------------------------- state


@dataclasses.dataclass
class Entry:
    task: str
    branch: str | None = None   # open branch that changes the file
    started: int | None = None  # committer time of the branch's first commit that changes the file
    sweep: bool = False


@dataclasses.dataclass
class State:
    base: str
    tasks: dict[str, dict]
    order: list[str]                      # task ids in design-result order
    merged_at: dict[str, int]             # task id -> committer time of the first-parent commit that merged it
    files: list[str]                      # repository files under the lease roots, plus the Q3 files
    sites: dict[str, int]
    named: dict[str, list[str]]           # file -> tasks whose files name it
    sweeps: dict[str, list[str]]          # task -> its sweep patterns
    branches: dict[str, tuple[str, list[str]]]  # open branch -> (task id, lease files it changes)
    unresolved: list[str]                 # tasks with prose entries that name browser files

    def ready(self, task: str, at: int | None = None) -> bool:
        deps = self.tasks.get(task, {}).get("depends_on", [])
        return all(dep not in self.tasks or (dep in self.merged_at and (at is None or self.merged_at[dep] <= at))
                   for dep in deps)


def load_design(base: str) -> tuple[dict[str, dict], list[str]]:
    design = json.loads(git("show", f"{base}:{DESIGN}"))
    tasks, order = {}, []
    for program in design["programs"].values():
        for task in program["tasks"]:
            tasks[task["id"]] = task
            order.append(task["id"])
    return tasks, order


def merge_times(base: str, known: set[str]) -> dict[str, int]:
    """Task id -> committer time of the first-parent commit of BASE that brought in a commit naming it."""
    out: dict[str, int] = {}
    for line in git("log", "--first-parent", "--reverse", f"--since={DESIGN_DATE}", "--format=%H %ct %P", base
                    ).splitlines():
        sha, when, *parents = line.split()
        span = f"{parents[0]}..{sha}" if len(parents) > 1 else f"{sha}^!"
        for subject in git("log", "--format=%s", span).splitlines():
            for task in TASK_ID.findall(subject):
                if task in known:
                    out.setdefault(task, int(when))
    return out


def branch_task(branch: str, base: str, known: set[str]) -> str:
    """The task of BRANCH: the id in its name (`cp/<id>`, `cp/<n>-<id>`), else the id its own commit subjects name
    most often (the tip's on a tie). A branch with neither is its own entry, named by the branch."""
    name = re.sub(r"^(?:origin/)?cp/(?:\d+-)?", "", branch)
    if name in known:
        return name
    subjects = git("log", "--format=%s", f"{base}..{branch}").splitlines()
    counts = collections.Counter(t for s in subjects for t in TASK_ID.findall(s) if t in known)
    if counts:
        top = max(counts.values())
        tip = [t for t in TASK_ID.findall(subjects[0]) if counts.get(t) == top] if subjects else []
        return tip[0] if tip else next(t for t, n in counts.items() if n == top)
    return branch.removeprefix("origin/")


def in_scope(path: str, q3: set[str]) -> bool:
    return path.startswith(ROOTS) or path in q3


def open_branches(base: str, known: set[str], q3: set[str], merged: set[str]) -> dict[str, tuple[str, list[str]]]:
    out = {}
    for line in git("branch", "-r", "--no-merged", base, "--list", "origin/cp/*").splitlines():
        branch = line.strip()
        changed = {MOVED.get(p, p) for p in git("diff", "--name-only", f"{base}...{branch}").splitlines()}
        files = sorted(p for p in changed if in_scope(p, q3))
        task = branch_task(branch, base, known)
        if files and task not in merged:
            out[branch] = (task, files)
    return out


def first_touch(base: str, branch: str, path: str) -> int:
    paths = [path] + [old for old, new in MOVED.items() if new == path]
    times = git("log", "--reverse", "--format=%ct", f"{base}..{branch}", "--", *paths).split()
    return int(times[0]) if times else 0


def match_design(state_files: list[str], tasks: dict[str, dict], order: list[str], merged: set[str]
                 ) -> tuple[dict[str, list[str]], dict[str, list[str]], list[str]]:
    named: dict[str, list[str]] = collections.defaultdict(list)
    sweeps: dict[str, list[str]] = collections.defaultdict(list)
    unresolved = []
    prose = re.compile(r"CmuxNextBrowser|CEF/|CEFShim|ChromiumHost/")
    folders = {path[:i + 1] for path in state_files for i, c in enumerate(path) if c == "/"}
    for task in order:
        if task in merged:
            continue
        for entry in tasks[task]["files"]:
            pattern = full_pattern(entry)
            if pattern is None:
                if prose.search(entry) and task not in unresolved:
                    unresolved.append(task)
                continue
            for one in braces(pattern):
                one = MOVED.get(one, one)
                if one + "/" in folders:  # a folder written without its slash
                    one += "/"
                regex = pattern_regex(one)
                for path in state_files:
                    if not regex.fullmatch(path):
                        continue
                    if len(literal_start(one)) > len(lease_root(path)) or one == path:
                        if task not in named[path]:
                            named[path].append(task)
                    elif one not in sweeps[task]:
                        sweeps[task].append(one)
    return named, sweeps, unresolved


def load(base: str) -> State:
    tasks, order = load_design(base)
    known = set(tasks)
    merged_at = merge_times(base, known)
    for subject in git("log", "--format=%s", base).splitlines():  # older merges, before the design date
        for task in TASK_ID.findall(subject):
            if task in known:
                merged_at.setdefault(task, 0)
    sites = {}
    for line in git("grep", "-c", "-P", SITES, base, "--", APP, ":!**/CEFShimLibrary.swift").splitlines():
        _, path, count = line.split(":")
        sites[path] = int(count)
    tree = [p for p in git("ls-tree", "-r", "--name-only", base, "--", *ROOTS).splitlines()]
    new = sorted({MOVED.get(p, p) for t in order for e in tasks[t]["files"]
                  if (p := full_pattern(e)) and "(new)" in e and not re.search(r"[*\[{]", p)
                  and p.startswith(ROOTS)})
    files = sorted(set(tree) | set(sites) | set(new))
    merged = set(merged_at)
    named, sweeps, unresolved = match_design(files, tasks, order, merged)
    branches = open_branches(base, known, set(sites), merged)
    return State(base, tasks, order, merged_at, files, sites, named, sweeps, branches, unresolved)


# ---------------------------------------------------------------- queues


def previous_order(text: str) -> tuple[dict[str, list[str]], list[str]]:
    """Row queues and the sweep order from the generated section of the lane file."""
    rows: dict[str, list[str]] = {}
    sweep_order: list[str] = []
    section = text.split(BEGIN, 1)[-1].split(END, 1)[0] if BEGIN in text else ""
    table = None
    for line in section.splitlines():
        if line.startswith("## "):
            table = line
        cells = [c.strip() for c in line.strip().strip("|").split("|")] if line.startswith("| `") else []
        if not cells:
            continue
        if table and table.startswith("## Sweep"):
            sweep_order.append(cells[0].strip("`"))
        elif table and table.startswith("## Leases"):
            ids = re.findall(r"(?:^|, )((?:p\d\d|cp/)[^ ,()]+)", ", ".join(cells[2:4]))
            rows[expand(cells[0].strip("`"))] = ids
    return rows, sweep_order


def dependency_order(tasks: list[str], state: State) -> list[str]:
    """TASKS with every task after the tasks it depends on; ready ones first, else design order."""
    position = {t: i for i, t in enumerate(state.order)}
    pending = sorted(tasks, key=lambda t: (not state.ready(t), position.get(t, len(position))))
    out: list[str] = []
    while pending:
        pick = next((t for t in pending
                     if not any(d in pending for d in state.tasks.get(t, {}).get("depends_on", []))), pending[0])
        out.append(pick)
        pending.remove(pick)
    return out


def sweep_queue(state: State, previous: list[str]) -> list[str]:
    live = [t for t in state.sweeps if t not in state.merged_at]
    kept = [t for t in previous if t in live]
    return kept + dependency_order([t for t in live if t not in kept], state)


def queue(path: str, state: State, previous: list[str] | None, sweep_order: list[str]) -> list[Entry]:
    """The row of PATH in queue order: kept entries in their previous order, then new entries."""
    opened = {state.branches[b][0]: b for b in sorted(state.branches) if path in state.branches[b][1]}
    entries = {t: Entry(t) for t in state.named.get(path, [])}
    for task, branch in opened.items():
        entries.setdefault(task, Entry(task))
        entries[task].branch, entries[task].started = branch, first_touch(state.base, branch, path)
    if previous is None:  # a fresh row: open branches by their first change of the file, then the named tasks
        head = sorted((e for e in entries.values() if e.branch), key=lambda e: (e.started, e.task))
        ordered = [e.task for e in head] + dependency_order([t for t, e in entries.items() if not e.branch], state)
    else:  # a kept row: new named tasks, then tasks that are not named, after the kept ones; a push moves no one up
        kept = list(dict.fromkeys(t for t in previous if t in entries))
        new_named = dependency_order([t for t in state.named.get(path, []) if t not in kept], state)
        unnamed = sorted((e for t, e in entries.items() if t not in kept and t not in new_named),
                         key=lambda e: (e.started or 0, e.task))
        ordered = kept + new_named + [e.task for e in unnamed]
    rows = [entries[t] for t in ordered]
    for task in sweep_order:
        if task not in entries and any(pattern_regex(p).fullmatch(path) for p in state.sweeps[task]):
            rows.append(Entry(task, sweep=True))
    return rows


def holder(rows: list[Entry], state: State) -> Entry | None:
    """The first ready entry in queue order, except that an entry keeps a lease it took. An open entry took the lease
    when its branch first changed the file at a time when it was ready and no earlier entry was; of those, the one
    that changed the file first holds it (a later one started while the first held)."""
    took = [e for i, e in enumerate(rows)
            if e.branch and state.ready(e.task, e.started)
            and not any(state.ready(earlier.task, e.started) for earlier in rows[:i])]
    if took:
        return min(took, key=lambda e: e.started or 0)
    return next((e for e in rows if state.ready(e.task)), rows[0] if rows else None)


def label(entry: Entry, state: State, held: Entry | None) -> str:
    tags = []
    if entry.branch:
        tags.append("open, `" + entry.branch.removeprefix("origin/") + "`")
    if entry is held and not state.ready(entry.task):
        tags.append("waiting")
    elif state.ready(entry.task) and entry is not held:
        tags.append("ready")
    if entry.sweep:
        tags.append("sweep")
    return entry.task + (f" ({', '.join(tags)})" if tags else "")


# ---------------------------------------------------------------- output


def row_files(state: State) -> list[str]:
    listed = {p for t in LISTED_TASKS for p, tasks in state.named.items() if t in tasks}
    counts = collections.Counter()
    for path, tasks in state.named.items():
        counts[path] += len(tasks)
    for _, files in state.branches.values():
        counts.update(files)
    contested = {p for p, n in counts.items() if n >= 2}
    return sorted(set(state.sites) | listed | contested, key=lambda p: (-state.sites.get(p, 0), short(p)))


def render(state: State, previous: dict[str, list[str]] | None, sweep_prev: list[str]) -> str:
    sweeps = sweep_queue(state, sweep_prev)
    out = [BEGIN, "", f"Generated by `scripts/cmux-next/cefs-leases.py --write` at `{state.base}` "
           f"{git('rev-parse', '--short=11', state.base).strip()}. Do not edit by hand, except that the p01-process "
           "lead may reorder a row (rule 6).", ""]
    out += ["## Sweep tasks", "",
            "Unmerged tasks whose `files` cover a lease folder with a broad pattern. Each is at the end of every row "
            "it matches, in this order (rule 7).", "", "| Task | Patterns | State |", "|---|---|---|"]
    for task in sweeps:
        pats = ", ".join(f"`{short(p)}`" for p in state.sweeps[task])
        out.append(f"| `{task}` | {pats} | {'ready' if state.ready(task) else 'waiting'} |")
    if state.unresolved:
        out += ["", "These tasks name browser files in prose that no pattern resolves; they follow the sweep rule "
                "for every file they change: " + ", ".join(state.unresolved) + "."]
    collisions, lines = [], []
    for path in row_files(state):
        rows = queue(path, state, None if previous is None else previous.get(path, []), sweeps)
        if not rows:
            continue
        held = holder(rows, state)
        rest = [label(e, state, held) for e in rows if e is not held and not e.sweep]
        sweep_count = sum(e.sweep for e in rows if e is not held)
        tail = ", ".join(rest) + (f"{', ' if rest else ''}+{sweep_count} sweep" if sweep_count else "")
        sites = state.sites.get(path)
        lines.append(f"| `{short(path)}` | {sites if sites else '-'} | {label(held, state, held)} | {tail or '-'} |")
        late = [e for e in rows if e.branch and e is not held]
        if late:
            collisions.append(f"| `{short(path)}` | {label(held, state, held)} | "
                              + ", ".join(label(e, state, held) for e in late) + " |")
    out += ["", "## Open collisions", "",
            "Open branches that change a lease file they do not hold. Each pushes no new change to the file, lands "
            "after the holder and the entries before it in the row, and merges `origin/perf/chrome-parity` first "
            "(rule 5).", "", "| File | Holder | Open branches that wait, in land order |", "|---|---|---|"]
    out += collisions or ["| - | - | - |"]
    out += ["", "## Leases", "",
            "Sites: `" + SITES + "` hits at the base (Q3). Each row: holder, then the queue in order. `+N sweep`: "
            "the sweep tasks that match the file, in the sweep order.", "",
            "| File | Sites | Holder | Queue after the holder |", "|---|---|---|---|"]
    out += lines + ["", END]
    return "\n".join(out)


def check(state: State, ref: str, task: str | None, sweeps: list[str], previous: dict[str, list[str]]) -> int:
    """Each lease file REF changes against the base, with its holder; 1 when TASK does not hold one of them. REF is
    a local branch or commit (before the push) or a pushed `origin/cp/...` branch."""
    task = task or branch_task(ref, state.base, set(state.tasks))
    changed = {MOVED.get(p, p) for p in git("diff", "--name-only", f"{state.base}...{ref}").splitlines()}
    bad = 0
    for path in sorted(p for p in changed if in_scope(p, set(state.sites))):
        rows = queue(path, state, previous.get(path, []), sweeps)
        if not any(e.task == task for e in rows):  # an unnamed task before its first push: before the sweeps
            rows.insert(next((i for i, e in enumerate(rows) if e.sweep), len(rows)), Entry(task))
        held = holder(rows, state)
        mine = held is not None and held.task == task
        bad += not mine
        print(f"{'ok  ' if mine else 'WAIT'} {short(path)}: holder {held.task if held else '-'}")
    verdict = f"{bad} lease file(s) held by another task" if bad else "holds every lease file it changes"
    print(f"{ref} ({task}): {verdict}")
    return 1 if bad else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", default="origin/perf/chrome-parity")
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--fresh", action="store_true")
    parser.add_argument("--check", metavar="REF")
    parser.add_argument("--task", help="the task of --check REF when its name and subjects do not say")
    parser.add_argument("--holder", nargs="+", metavar="FILE")
    args = parser.parse_args()
    lane = ROOT / LANE
    text = lane.read_text()
    previous, sweep_prev = previous_order(text)
    state = load(args.base)
    sweeps = sweep_queue(state, sweep_prev)
    if args.check:
        return check(state, args.check, args.task, sweeps, previous)
    if args.holder:
        for path in args.holder:
            path = MOVED.get(expand(path), expand(path))
            rows = queue(path, state, previous.get(path, []), sweeps)
            held = holder(rows, state)
            print(f"{short(path)}: holder {label(held, state, held) if held else '-'}; queue "
                  + ", ".join(label(e, state, held) for e in rows if e is not held))
        return 0
    generated = render(state, None if args.fresh else previous, [] if args.fresh else sweep_prev)
    if not args.write:
        print(generated)
        return 0
    head, _, rest = text.partition(BEGIN)
    lane.write_text(head + generated + rest.partition(END)[2] if BEGIN in text else text + "\n" + generated + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

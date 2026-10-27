#!/usr/bin/env python3
"""MQ12, the orphan bench queue: perf scripts that are neither a lab story nor retired with a reason.

    python3 -I scripts/perf-lab/lab.py stories --orphans [--json]
    python3 -I scripts/perf-lab/orphans.py [--json]

A perf script is a runnable file (a `.py` needs a `__main__` guard or a shebang; a module without either is a
library a bench imports) that is one of:

  - an entry of scripts/measure/ (a fleet measure step) or scripts/perf-lab/stories/ (a story implementation),
    top level only (a subdirectory holds a step's own helpers, scripts/measure/blocking-probe/);
  - a script anywhere under PERF_DIRS (queues.py PERF_DIRS, recursive, queues.SKIP_DIRS such as tests/ and
    node_modules/ pruned) whose name has a bench word (queues.py BENCH_NAME, MQ2's words: `bench` anywhere, as in
    xbench, the others at a word start so `feature-flags` is not `lag`) or whose code writes result-v1 (bench_launch,
    BenchApp, perf_result). The lab's own code (scripts/perf-lab/ outside stories/) runs stories and is not one;
    a unit test (test_*.py, *_test.py, *.test.ts) is not one.

A perf script is covered when a story runs it: a stories.d/<id>.json `command` names it, or the story's `runs` list
does (the scripts the command runs on every run: the bench a session script starts, a fleet step's story module).
Nothing is inferred from a script's text: a suite branch that the story's arguments do not select, a module it
imports, a help text or an error message that names a file is not a run. Otherwise retired.json must hold it with a
kind and a reason:

  duplicate    "of" names the story that already measures it (a fleet wrapper of a story's script)
  one-off      a finished experiment or a single diagnostic, kept as a record
  not-a-bench  a functional check, a generator, a report or a validator step, or lab infrastructure
  outside-lab  a measurement another program owns (iOS, CI, the dev fleet)

Each orphan is one unit of MQ12; the queue prints them in tasks of up to TASK_SIZE scripts, one directory per task.
A retired entry that is stale (the file is gone, it is not a perf script, a story runs it, or its `of` is not a
story) is a problem: the command prints it on stderr and exits 1. Orphans alone exit 0: the queue is a report,
and done check 8 (done_checks.py, no-orphan-benches) reads `--json` and requires an empty list.

Chromium keeps the same ledger for its benchmarks: tools/perf/core/perf_data_generator.py refuses a benchmark that
is neither scheduled on a bot nor listed with a reason in its unscheduled set, and expired metrics leave through a
checked-in allowlist (tools/metrics/histograms/expired_histograms_allowlist.txt), never by silence.

Stdlib only; loads queues.py by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import ast
import importlib.util
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]


def _load_sibling(name: str):
    module_name = f"perf_lab_{name}"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module  # before exec: dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


queues = _load_sibling("queues")

STORIES_DIR = "scripts/perf-lab/stories.d"  # catalog.STORIES_DIR
RETIRED_PATH = "scripts/perf-lab/retired.json"
RETIRED_SCHEMA = "cmux-perf-retired/v1"
TASK_SIZE = 4  # p12-perf-process.md section 7, MQ12: each group of up to 4 scripts is one task

# Every runnable file at the top of these directories is a perf script.
ENTRY_DIRS = ("scripts/measure", "scripts/perf-lab/stories")
# Under these, recursively, a script is a perf script by its name or by writing result-v1.
PERF_DIRS = queues.PERF_DIRS
LAB_DIR = "scripts/perf-lab"  # the lab itself: only its stories/ entries are perf scripts
SUFFIXES = (".py", ".sh", ".ts", ".mjs", ".js")
PERF_NAME = re.compile(r"bench|(?<![a-z])(?:%s)" % queues.BENCH_NAME.pattern)
# A unit test is not a bench, in a tests/ directory (queues.SKIP_DIRS) or next to the code it tests.
TEST_NAME = re.compile(r"^test_.*\.py$|_test\.py$|\.(?:test|spec)\.[a-z]+$")
RESULT_WRITER = re.compile(r"\bbench_launch\b|\bBenchApp\b|\bperf_result\b")

KINDS = ("duplicate", "one-off", "not-a-bench", "outside-lab")


class OrphansError(RuntimeError):
    """An input the queue cannot read at all (retired.json is not JSON, a story file is broken)."""


@dataclass(frozen=True)
class Script:
    path: str  # repository-relative
    why: str  # what makes it a perf script


@dataclass(frozen=True)
class Retired:
    kind: str
    why: str
    of: str | None = None


@dataclass(frozen=True)
class Report:
    scripts: tuple[Script, ...]
    covered: dict[str, str]  # path -> the stories that run it
    retired: dict[str, Retired]
    orphans: tuple[Script, ...]
    problems: tuple[str, ...]


# ---------- the tree ----------

def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def _runnable(name: str, text: str) -> bool:
    """A non-Python file is runnable. A Python file is when it has a `__main__` guard, or a shebang and a top-level
    statement that does work (a call, a loop, a with); a module of only imports, defs and assignments is a library
    its benches load, whatever its first line says."""
    if not name.endswith(".py") or "__main__" in text:
        return True
    if not text.startswith("#!"):
        return False
    try:
        body = ast.parse(text).body
    except SyntaxError:
        return True
    return any(isinstance(node, (ast.For, ast.While, ast.With)) or
               (isinstance(node, ast.Expr) and not isinstance(node.value, ast.Constant)) for node in body)


def _candidates(root: Path) -> Iterable[tuple[str, bool]]:
    """(repository path, whether it is an entry) for every file with a script suffix that may be a perf script."""
    for top in ENTRY_DIRS:
        directory = root / top
        for path in sorted(directory.iterdir()) if directory.is_dir() else []:
            if path.is_file() and path.name.endswith(SUFFIXES):
                yield f"{top}/{path.name}", True
    for top in PERF_DIRS:
        for rel in queues._walk(str(root), top, SUFFIXES):
            if not rel.startswith(LAB_DIR + "/") and not TEST_NAME.search(os.path.basename(rel)):
                yield rel, False


def perf_scripts(root: Path) -> list[Script]:
    """Every perf script of the tree, sorted by path."""
    found: dict[str, Script] = {}
    for rel, entry in _candidates(root):
        name = os.path.basename(rel)
        if rel in found or not _runnable(name, text := _read(root / rel)):
            continue
        if entry:
            found[rel] = Script(rel, f"entry of {os.path.dirname(rel)}/")
        elif match := PERF_NAME.search(name.lower()):
            found[rel] = Script(rel, f"name: {match.group(0)}")
        elif match := RESULT_WRITER.search(text):
            found[rel] = Script(rel, f"writes result-v1: {match.group(0)}")
    return [found[rel] for rel in sorted(found)]


def story_runs(root: Path, problems: list[str]) -> dict[str, list[str]]:
    """Repository path -> the ids of the stories that run it: the paths in a story's `command` and its `runs`."""
    runs: dict[str, list[str]] = {}
    directory = root / STORIES_DIR
    for path in sorted(directory.glob("*.json")) if directory.is_dir() else []:
        try:
            story = json.loads(_read(path))
        except json.JSONDecodeError as error:
            raise OrphansError(f"{STORIES_DIR}/{path.name}: {error}") from None
        if not isinstance(story, dict):
            continue
        story_id = str(story.get("id", path.stem))
        command = story.get("command") if isinstance(story.get("command"), list) else []
        for arg in command:
            if isinstance(arg, str) and not arg.startswith("-") and (root / arg).is_file():
                runs.setdefault(os.path.normpath(arg), []).append(story_id)
        declared = story.get("runs", [])
        for rel in declared if isinstance(declared, list) else [declared]:
            if isinstance(rel, str) and (root / rel).is_file():
                runs.setdefault(os.path.normpath(rel), []).append(story_id)
            else:
                problems.append(f"{STORIES_DIR}/{path.name}: runs path {rel!r} does not exist in the repository")
    return runs


def coverage(root: Path, problems: list[str]) -> dict[str, str]:
    """Path -> `story <ids>` for every path that a story's command or `runs` names; nothing else is a run."""
    return {path: "story " + ", ".join(dict.fromkeys(ids)) for path, ids in story_runs(root, problems).items()}


# ---------- the ledger ----------

def load_retired(root: Path, problems: list[str]) -> dict[str, Retired]:
    path = root / RETIRED_PATH
    if not path.is_file():
        return {}
    try:
        doc = json.loads(_read(path))
    except json.JSONDecodeError as error:
        raise OrphansError(f"{RETIRED_PATH}: {error}") from None
    if not isinstance(doc, dict) or doc.get("schema") != RETIRED_SCHEMA or not isinstance(doc.get("scripts"), dict):
        raise OrphansError(f'{RETIRED_PATH}: needs {{"schema": "{RETIRED_SCHEMA}", "scripts": {{path: entry}}}}')
    retired = {}
    for rel, entry in doc["scripts"].items():
        where = f"{RETIRED_PATH}: {rel}"
        if not isinstance(entry, dict) or set(entry) - {"kind", "why", "of"}:
            problems.append(f'{where}: an entry is {{"kind", "why"}} and, for a duplicate, "of"')
            continue
        kind, why, of = entry.get("kind"), entry.get("why"), entry.get("of")
        if kind not in KINDS:
            problems.append(f"{where}: kind {kind!r} is not one of {', '.join(KINDS)}")
            continue
        if not isinstance(why, str) or not why.strip():
            problems.append(f"{where}: no reason (why)")
            continue
        if (kind == "duplicate") != (of is not None):
            problems.append(f"{where}: " + ('a duplicate names the story it duplicates in "of"' if kind == "duplicate"
                                            else f'only a duplicate has "of" ({kind})'))
            continue
        retired[rel] = Retired(kind, why.strip(), of)
    return retired


def _story_ids(root: Path) -> set[str]:
    directory = root / STORIES_DIR
    return {path.stem for path in directory.glob("*.json")} if directory.is_dir() else set()


def find(root: Path = REPO_ROOT) -> Report:
    problems: list[str] = []
    scripts = perf_scripts(root)
    covered = coverage(root, problems)
    retired = load_retired(root, problems)
    known = {s.path for s in scripts}
    stories = _story_ids(root)
    for rel, entry in sorted(retired.items()):
        where = f"{RETIRED_PATH}: {rel}"
        if not (root / rel).is_file():
            problems.append(f"{where}: no such file; drop the entry")
        elif rel not in known:
            problems.append(f"{where}: not a perf script (orphans.py docstring); drop the entry")
        elif rel in covered:
            problems.append(f"{where}: a story runs it ({covered[rel]}); drop the entry")
        if entry.of is not None and entry.of not in stories:
            problems.append(f"{where}: duplicate of {entry.of!r}, which is not a story in {STORIES_DIR}/")
    orphans = tuple(s for s in scripts if s.path not in covered and s.path not in retired)
    return Report(tuple(scripts), covered, retired, orphans, tuple(problems))


def tasks(orphans: Iterable[Script], size: int = TASK_SIZE) -> list[list[Script]]:
    """The MQ12 tasks: orphans by directory, in runs of up to `size`."""
    by_dir: dict[str, list[Script]] = {}
    for script in sorted(orphans, key=lambda s: s.path):
        by_dir.setdefault(os.path.dirname(script.path), []).append(script)
    return [scripts[i:i + size] for _, scripts in sorted(by_dir.items()) for i in range(0, len(scripts), size)]


# ---------- the command ----------

def run_orphans(root: Path, as_json: bool, out=None, err=None) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    try:
        report = find(root)
    except (OrphansError, OSError) as error:
        print(f"orphans: {error}", file=err)
        return 2
    if as_json:
        print(json.dumps([s.path for s in report.orphans]), file=out)
    else:
        groups = tasks(report.orphans)
        for number, group in enumerate(groups, 1):
            for script in group:
                print(f"{number}\t{script.path}\t{script.why}", file=out)
        print(f"orphans: {len(report.orphans)} in {len(groups)} tasks of up to {TASK_SIZE} (MQ12: add a story to "
              f"{STORIES_DIR}/ or retire it in {RETIRED_PATH})", file=out)
    for problem in report.problems:
        print(problem, file=err)
    return 1 if report.problems else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="orphans.py", description="MQ12: perf scripts with no story and no retirement.")
    parser.add_argument("--json", action="store_true", help="print the orphan paths as one JSON list (done check 8)")
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    return run_orphans(args.root, args.json)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Story qos-static: Swift threads, queues and tasks whose QoS is not declared (target row qos.swift).

The pre-push guardrails refuse an undeclared thread, queue or task only in the lines a push adds. This story runs the
same two rules from scripts/cmux-next/guardrails.py (never a copied regex) over every Swift file in their scope at one
revision, as a push from the empty tree would add it:

  task-priority  a `Task.detached` / `DispatchQueue.global(` outside CmuxNextWakeups, a `DispatchQueue(label:` with no
                 `qos:`/`target:`, a Thread or OperationQueue without `.name` and `.qualityOfService`, a reserved level
  thread-doc     a thread or queue whose label plans/cmux-next/threading-model.md does not list

The tree is read and judged by scripts/cmux-next/threading-inventory.py (its read_tree and judge: one empty-tree driver
for both tools), so the story's per-rule lines are always the inventory's. This file only merges the two rules' lines
into sites and writes result-v1.

A site is one source line; a line both rules refuse is one site. `qos.undeclared_swift` is the number of sites, and
target row qos.swift wants 0. Chromium's model: every thread is created with a ThreadType
(base/threading/platform_thread.h) and every posted task names its TaskPriority (base/task/task_traits.h).

Linux, no build: it reads git objects only (ls-tree, cat-file), so the list is deterministic for a commit and the
result's host is the constant STATIC_HOST (a source count has no host to split its series by).

The counted commit is the measured build, not the harness checkout: `--rev`, else $PERF_LAB_SHA (the story runner,
task 008, sets it to its --sha), else the `CMUXCommit` of `--app`'s Info.plist, else HEAD (a manual run). The story
takes the runner's `--app APP --tag TAG --out DIR` (stories.d/README.md) and the session as $PERF_LAB_SESSION,
`--session` or a trailing word; it runs only the `light` session.

  python3 scripts/perf-lab/stories/qos_static.py --repo .              # the count and the count per rule at HEAD
  python3 scripts/perf-lab/stories/qos_static.py --repo . --list       # every site, sorted by path and line
  python3 scripts/perf-lab/stories/qos_static.py --repo . --json
  python3 scripts/perf-lab/stories/qos_static.py --repo . --out DIR    # result-v1 into DIR, the sites beside it
  PERF_LAB_SHA=SHA python3 scripts/perf-lab/stories/qos_static.py --app APP --tag TAG --out DIR   # as the runner

Not a CI gate (Lawrence 2026-10-23); the lab runs it as a `linux` tier story (stories.d/qos-static.json).
"""
from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # importing the inventory, guardrails and its siblings must not write __pycache__

import argparse
import collections
import hashlib
import importlib.util
import json
import os
import plistlib
import subprocess
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Mapping

HERE = Path(__file__).resolve().parent
PERF_LAB = HERE.parent
SCRIPTS = PERF_LAB.parent

STORY = "qos-static"
METRIC = "qos.undeclared_swift"
TARGET_ROW = "qos.swift"
RULE_IDS = ("task-priority", "thread-doc")
SITES_FILE = "qos-static.sites.json"
SESSION = "light"  # stories.d/qos-static.json
SHA_ENV, SESSION_ENV = "PERF_LAB_SHA", "PERF_LAB_SESSION"  # set by the story runner (task 008)
# A source count is the same on every host: one fixed host block keeps every point in one series.
STATIC_HOST = {"class": "static", "chip": "none"}
STATIC_CONFIG = "release"  # the story's config (stories.d/qos-static.json): the shipped sources are what is counted
MEASURE_VERSION = 1


class StoryError(RuntimeError):
    """The story cannot count (no such revision, no threading doc for thread-doc, no measured commit)."""


def load_by_path(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


inventory = load_by_path("perf_lab_qos_static_inventory", SCRIPTS / "cmux-next" / "threading-inventory.py")
g = inventory.g  # the guardrails module the inventory judges with
perf_result = load_by_path("perf_lab_qos_static_perf_result", PERF_LAB / "perf_result.py")


@dataclass(frozen=True, order=True)
class Site:
    path: str
    line: int
    rules: tuple[str, ...]
    text: str

    def record(self) -> dict:
        return {"path": self.path, "line": self.line, "rules": list(self.rules), "text": self.text}

    def describe(self) -> str:
        return f"{self.path}:{self.line}: [{','.join(self.rules)}] {self.text}"


@dataclass(frozen=True)
class Report:
    sha: str
    sites: tuple[Site, ...]
    per_rule: dict[str, int]

    @property
    def count(self) -> int:
        return len(self.sites)

    def record(self) -> dict:
        return {"story": STORY, "metric": METRIC, "sha": self.sha, "count": self.count, "rules": self.per_rule,
                "sites": [site.record() for site in self.sites]}


def read_tree(repo: Path, rev: str) -> tuple[str, object]:
    """(REV's commit sha, the inventory's Tree of that commit)."""
    try:
        sha = g.git(repo, "rev-parse", "--verify", f"{rev}^{{commit}}").strip()
    except SystemExit as error:  # guardrails.git exits on a git failure
        raise StoryError(f"{rev} is not a commit in {repo}: {error}") from None
    return sha, inventory.read_tree(repo, sha)


def judge(sha: str, tree) -> Report:
    """Every site the two rules refuse in TREE, sorted by path and line."""
    if tree.threading_doc is None:
        raise StoryError(f"{g.THREADING_DOC} does not exist at {sha}: thread-doc has no list to judge against")
    try:
        hits = inventory.judge(tree, RULE_IDS, lambda path: True)
    except RuntimeError as error:  # thread-doc: the doc has no "Registered threads and queues" section
        raise StoryError(str(error)) from None
    found: dict[tuple[str, int], set[str]] = collections.defaultdict(set)
    for rule_id, hit in hits:
        found[(hit.path, hit.number)].add(rule_id)
    per_rule = {rule_id: sum(rule_id in rules for rules in found.values()) for rule_id in RULE_IDS}
    sites = tuple(sorted(Site(path, number, tuple(r for r in RULE_IDS if r in rules),
                              tree.sources[path].split("\n")[number - 1].strip())
                         for (path, number), rules in found.items()))
    return Report(sha, sites, per_rule)


def count(repo: Path, rev: str = "HEAD") -> Report:
    return judge(*read_tree(repo, rev))


def app_commit(app: Path) -> str:
    """The commit APP was built from: its Info.plist `CMUXCommit` (what bench_launch.build_sha reads)."""
    try:
        with open(app / "Contents" / "Info.plist", "rb") as handle:
            commit = str(plistlib.load(handle).get("CMUXCommit") or "").strip()
    except (OSError, plistlib.InvalidFileException) as error:
        raise StoryError(f"--app {app}: no readable Info.plist ({error})") from None
    if not commit:
        raise StoryError(f"--app {app}: its Info.plist has no CMUXCommit, so the measured commit is unknown")
    return commit


def measured_rev(rev: str | None, app: Path | None, environ: Mapping[str, str]) -> str:
    """The commit to count: the one the runner measures; HEAD only when nothing names one (a manual run)."""
    if rev:
        return rev
    if environ.get(SHA_ENV, "").strip():
        return environ[SHA_ENV].strip()
    if app is not None:
        return app_commit(app)
    return "HEAD"


def result(report: Report, run=None):
    """The story's result-v1: one sample, the site count, claiming target row qos.swift."""
    fingerprint = hashlib.sha256("\0".join(STATIC_HOST.values()).encode()).hexdigest()
    return perf_result.Result(
        story=STORY, metric=METRIC, unit="count", better="lower", samples=[report.count],
        build=perf_result.Build(sha=report.sha, config=STATIC_CONFIG, measure_version=MEASURE_VERSION),
        host=perf_result.Host(fingerprint=fingerprint, host_class=STATIC_HOST["class"], chip=STATIC_HOST["chip"],
                              macos=None, macos_build=None, display_hz=None),
        engine="none", session=SESSION, run=run or perf_result.Run.start(),
        target_ref=perf_result.TargetRef(target=TARGET_ROW))


def write(report: Report, out: Path, repo: Path) -> Path:
    """result-v1 into OUT (validated first; nothing is written when it is invalid), and the site list beside it in
    SITES_FILE (not `*.ndjson`, so the ingest reads only the result)."""
    path = perf_result.write_ndjson(out, [result(report)], repo_root=repo)
    sites = out / SITES_FILE
    temporary = out / f".{SITES_FILE}.tmp"
    temporary.write_text(json.dumps(report.record(), indent=1, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, sites)
    return path


def repo_root(repo: Path | None) -> Path:
    if repo is not None:
        return repo.resolve()
    found = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return Path(found.stdout.strip()) if found.returncode == 0 else SCRIPTS.parent


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=None, help="the checkout (default: the one holding the cwd)")
    parser.add_argument("--rev", "--sha", dest="rev", default=None,
                        help=f"the commit to count (default ${SHA_ENV}, else --app's CMUXCommit, else HEAD)")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--list", action="store_true", help="print every site, sorted by path and line")
    output.add_argument("--json", action="store_true", help="print the count, the count per rule and the sites as JSON")
    parser.add_argument("--out", type=Path, default=None,
                        help=f"write the result-v1 file into this directory, and {SITES_FILE} beside it")
    runner = parser.add_argument_group("story runner", "what scripts/perf-lab/run_story.py passes (stories.d/README.md)")
    runner.add_argument("--app", type=Path, default=None, help="the measured build; its CMUXCommit is the commit to count")
    runner.add_argument("--tag", default=None, help="the measured build's tag (unused: a source count runs no app)")
    runner.add_argument("--session", default=None, help=f"the session (default ${SESSION_ENV}); only {SESSION}")
    runner.add_argument("session_word", nargs="?", default=None, metavar="SESSION", help="the session, as a word")
    args = parser.parse_args(argv)
    sessions = {s for s in (args.session, args.session_word) if s is not None}
    if len(sessions) > 1:
        parser.error(f"two sessions: {', '.join(sorted(sessions))}")
    args.session = sessions.pop() if sessions else None
    return args


def main(argv: list[str] | None = None, environ: Mapping[str, str] | None = None) -> int:
    args = parse_args(argv)
    environ = os.environ if environ is None else environ
    session = args.session or environ.get(SESSION_ENV) or SESSION
    if session != SESSION:
        print(f"qos-static: session {session!r}: this story runs only {SESSION!r}", file=sys.stderr)
        return 2
    repo = repo_root(args.repo)
    try:
        report = count(repo, measured_rev(args.rev, args.app, environ))
    except StoryError as error:
        print(f"qos-static: {error}", file=sys.stderr)
        return 2
    if args.out is not None:
        args.out.mkdir(parents=True, exist_ok=True)
        print(f"qos-static: wrote {write(report, args.out, repo)}", file=sys.stderr)
    if args.json:
        print(json.dumps(report.record(), sort_keys=True))
    elif args.list:
        for site in report.sites:
            print(site.describe())
    else:
        print(f"{METRIC} {report.count}  ({report.sha})")
        for rule_id, n in report.per_rule.items():
            print(f"  {rule_id} {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

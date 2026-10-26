#!/usr/bin/env python3
"""Story qos-static: Swift threads, queues and tasks whose QoS is not declared (target row qos.swift).

The pre-push guardrails refuse an undeclared thread, queue or task only in the lines a push adds. This story runs the
same two rules, imported from scripts/cmux-next/guardrails.py (never a copied regex), over every Swift file in their
scope at one revision, as a push from the empty tree would add it:

  task-priority  a `Task.detached` / `DispatchQueue.global(` outside CmuxNextWakeups, a `DispatchQueue(label:` with no
                 `qos:`/`target:`, a Thread or OperationQueue without `.name` and `.qualityOfService`, a reserved level
  thread-doc     a thread or queue whose label plans/cmux-next/threading-model.md does not list

A site is one source line; a line both rules refuse is one site. `qos.undeclared_swift` is the number of sites, and
target row qos.swift wants 0. Chromium's model: every thread is created with a ThreadType
(base/threading/platform_thread.h) and every posted task names its TaskPriority (base/task/task_traits.h).

Linux, no build: it reads git objects only (ls-tree, cat-file), so the list is deterministic for a commit and the
result's host is the constant STATIC_HOST (a source count has no host to split its series by).

  python3 scripts/perf-lab/stories/qos_static.py --repo .              # the count and the count per rule at HEAD
  python3 scripts/perf-lab/stories/qos_static.py --repo . --list       # every site, sorted by path and line
  python3 scripts/perf-lab/stories/qos_static.py --repo . --json
  python3 scripts/perf-lab/stories/qos_static.py --repo . --out DIR    # result-v1 into DIR, the sites beside it

Not a CI gate (Lawrence 2026-10-23); the lab runs it as a `linux` tier story (stories.d/qos-static.json).
"""
from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # importing guardrails and its siblings must not write __pycache__ into the repo

import argparse
import collections
import hashlib
import importlib.util
import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType

HERE = Path(__file__).resolve().parent
PERF_LAB = HERE.parent
SCRIPTS = PERF_LAB.parent

STORY = "qos-static"
METRIC = "qos.undeclared_swift"
TARGET_ROW = "qos.swift"
RULE_IDS = ("task-priority", "thread-doc")
SITES_FILE = "qos-static.sites.json"
# A source count is the same on every host: one fixed host block keeps every point in one series.
STATIC_HOST = {"class": "static", "chip": "none"}
STATIC_CONFIG = "release"  # the story's config (stories.d/qos-static.json): the shipped sources are what is counted
MEASURE_VERSION = 1


class StoryError(RuntimeError):
    """The story cannot count at this revision (no such revision, no threading doc for thread-doc)."""


def load_by_path(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


g = load_by_path("perf_lab_qos_static_guardrails", SCRIPTS / "cmux-next" / "guardrails.py")
perf_result = load_by_path("perf_lab_qos_static_perf_result", PERF_LAB / "perf_result.py")
RULES = {rule.id: rule for rule in g.RULES if rule.id in RULE_IDS}


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


def in_scope(path: str) -> bool:
    return path.endswith(".swift") and any(path.startswith(rule.scope) or path.endswith(rule.scope)
                                           for rule in RULES.values())


def read_tree(repo: Path, rev: str) -> tuple[str, dict[str, str], str | None, str | None]:
    """(REV's commit sha, {path: text} of the Swift files the rules read, the threading doc, the package manifest)."""
    try:
        sha = g.git(repo, "rev-parse", "--verify", f"{rev}^{{commit}}").strip()
    except SystemExit as error:  # guardrails.git exits on a git failure
        raise StoryError(f"{rev} is not a commit in {repo}: {error}") from None
    prefixes = sorted({prefix for rule in RULES.values() for prefix in rule.scope if prefix.endswith("/")})
    listing = g.git(repo, "ls-tree", "-r", "--name-only", sha, "--", *prefixes)
    paths = sorted(p for p in listing.split("\n") if p and in_scope(p))
    texts = g.blobs(repo, [(sha, p) for p in paths] + [(sha, g.THREADING_DOC), (sha, g.PACKAGE_MANIFEST)])
    return (sha, {p: texts[(sha, p)] for p in paths if (sha, p) in texts},
            texts.get((sha, g.THREADING_DOC)), texts.get((sha, g.PACKAGE_MANIFEST)))


def new_file(path: str, text: str, targets: list):
    """PATH as guardrails sees a file a push adds: every line added over the empty tree."""
    lines = text.split("\n")
    change = g.FileChange(path, lines, added=[g.Added(path, i + 1, line) for i, line in enumerate(lines)],
                          base_lines=[], is_new=True)
    change.head_main = change.base_main = g.main_by_default(path, targets)
    return change


def judge(sha: str, sources: dict[str, str], threading_doc: str | None, manifest: str | None) -> Report:
    """Every site the two rules refuse in SOURCES, sorted by path and line."""
    if threading_doc is None:
        raise StoryError(f"{g.THREADING_DOC} does not exist at {sha}: thread-doc has no list to judge against")
    texts = {(sha, g.THREADING_DOC): threading_doc}
    if manifest is not None:
        texts[(sha, g.PACKAGE_MANIFEST)] = manifest
    g.load_blocking_context(texts, sha)
    targets = g.swift_scope.package_targets(manifest or "")
    changes = [new_file(path, sources[path], targets) for path in sorted(sources)]
    found: dict[tuple[str, int], set[str]] = collections.defaultdict(set)
    per_rule = {}
    for rule_id in RULE_IDS:
        rule = RULES[rule_id]
        scoped = [c for c in changes if c.path.startswith(rule.scope) or c.path.endswith(rule.scope)]
        try:
            hits = rule.find(scoped, collections.Counter())
        except RuntimeError as error:  # thread-doc: the doc has no "Registered threads and queues" section
            raise StoryError(f"rule {rule_id}: {error}") from None
        lines = {(hit.path, hit.number) for hit in hits}
        per_rule[rule_id] = len(lines)
        for key in lines:
            found[key].add(rule_id)
    sites = tuple(sorted(Site(path, number, tuple(r for r in RULE_IDS if r in rules),
                              sources[path].split("\n")[number - 1].strip())
                         for (path, number), rules in found.items()))
    return Report(sha, sites, per_rule)


def count(repo: Path, rev: str = "HEAD") -> Report:
    return judge(*read_tree(repo, rev))


def result(report: Report, run=None):
    """The story's result-v1: one sample, the site count, claiming target row qos.swift."""
    fingerprint = hashlib.sha256("\0".join(STATIC_HOST.values()).encode()).hexdigest()
    return perf_result.Result(
        story=STORY, metric=METRIC, unit="count", better="lower", samples=[report.count],
        build=perf_result.Build(sha=report.sha, config=STATIC_CONFIG, measure_version=MEASURE_VERSION),
        host=perf_result.Host(fingerprint=fingerprint, host_class=STATIC_HOST["class"], chip=STATIC_HOST["chip"],
                              macos=None, macos_build=None, display_hz=None),
        engine="none", session="light", run=run or perf_result.Run.start(),
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
    parser.add_argument("--rev", default="HEAD", help="the revision to count (default HEAD)")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--list", action="store_true", help="print every site, sorted by path and line")
    output.add_argument("--json", action="store_true", help="print the count, the count per rule and the sites as JSON")
    parser.add_argument("--out", type=Path, default=None,
                        help=f"write the result-v1 file into this directory, and {SITES_FILE} beside it")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    repo = repo_root(args.repo)
    try:
        report = count(repo, args.rev)
    except StoryError as error:
        print(f"qos-static: {error}", file=sys.stderr)
        return 2
    if args.out is not None:
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

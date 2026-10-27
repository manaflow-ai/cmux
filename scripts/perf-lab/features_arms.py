#!/usr/bin/env python3
"""Lab feature arms: which perfPath features get an on/off try pair today (task 098, p12-perf-process.md 3.9).

    feature_arms(repo, sha, now, base=measured_base(db, now - WINDOW)) -> Selection  # .inputs: plan(arms=...)
    python3 -I scripts/perf-lab/lab.py feature-arms (--db LAB.sqlite3 | --base SHA) [--ref SHA] [--now T] [--json]

T0 and T1 measure the branch defaults, the configuration "most likely to launch": their jobs carry no feature
override. Chrome's perf bots run the same way, with `fieldtrial_testing_config.json` and not with each study's
arms (testing/variations/README.md). A perfPath feature whose code is still moving gets its other arm measured by
a try job instead: each perfPath feature whose watched paths changed on the branch in the WINDOW before `now` is
one scheduler.FeatureArm. The scheduler turns it into one on/off try pair per lab day (its `arms_day` state).

A feature's watched paths, all read at the measured commit:
- its registry file, `schemas/features/features.d/<name>.json` (task 090): defaults, params, stories;
- the file of each of its stories, `scripts/perf-lab/stories.d/<story>.json`;
- each story's command path (its `command[0]`, the bench script).

Changes are a tree diff, `git diff <base> <sha>`. `base` is the commit the lab measured at the start of the window:
`measured_base` gives the commit of the newest waterfall run in the lab store that started at or before
`now - window`. Commit dates are not used, so a fast-forwarded or foxtrot topic commit with an old date counts when
it reaches the branch. Without a base there is nothing to diff against: the Selection has no arm and says so in its
problems. A feature that is not perfPath, or that has no story file at the commit, gets no arm; the second is a
problem too.

Stdlib only; loads scheduler.py by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import json
import sqlite3
import subprocess
import sys
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

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


scheduler = _load_sibling("scheduler")

FEATURES_DIR = "schemas/features/features.d"
STORIES_DIR = "scripts/perf-lab/stories.d"
PERF_PATH = "perfPath"
WINDOW = timedelta(hours=24)
GIT_TIMEOUT = 120

Runner = Callable[..., subprocess.CompletedProcess]


class ArmsError(RuntimeError):
    """Git could not read the measured commit or the base, or the lab store could not be read."""


@dataclass(frozen=True)
class WatchedFeature:
    """A perfPath feature at the measured commit: its stories that have a file and every path it watches."""

    name: str
    stories: tuple[str, ...]
    paths: tuple[str, ...]


@dataclass(frozen=True)
class Arm:
    """One scheduler input and the watched paths that changed in the window (the reason, for the dashboard)."""

    feature: str
    stories: tuple[str, ...]
    changed: tuple[str, ...]

    @property
    def input(self):
        return scheduler.FeatureArm(self.feature, self.stories)


@dataclass(frozen=True)
class Selection:
    sha: str
    base: str | None
    since: datetime
    until: datetime
    arms: tuple[Arm, ...]
    problems: tuple[str, ...]

    @property
    def inputs(self) -> tuple:
        """The `arms` argument of scheduler.plan() and Driver.tick()."""
        return tuple(arm.input for arm in self.arms)

    def to_document(self) -> dict:
        return {
            "sha": self.sha, "base": self.base, "since": _rfc3339(self.since), "until": _rfc3339(self.until),
            "arms": [{"feature": a.feature, "stories": list(a.stories), "changed": list(a.changed)}
                     for a in self.arms],
            "problems": list(self.problems),
        }


# ---------- pure ----------

def watched_features(features: Mapping[str, Mapping], stories: Mapping[str, Mapping | None]
                     ) -> tuple[tuple[WatchedFeature, ...], tuple[str, ...]]:
    """perfPath features with their watched paths. `features` maps a registry path to its document; `stories` maps
    a story id to its stories.d document, or None when the commit has no file for it."""
    watched, problems = [], []
    for path, document in sorted(features.items()):
        if document.get("kind") != PERF_PATH:
            continue
        name = str(document.get("name") or Path(path).stem)
        present, missing, paths = [], [], [path]
        for story in _story_ids(document):
            story_doc = stories.get(story)
            if story_doc is None:
                missing.append(story)
                continue
            present.append(story)
            paths.append(story_path(story))
            command = story_doc.get("command")
            if isinstance(command, list) and command and isinstance(command[0], str):
                paths.append(command[0])
        if missing:
            problems.append(f"{name}: no story file for {', '.join(missing)} in {STORIES_DIR}")
        if not present:
            problems.append(f"{name}: no story to bench its arms; it gets no arm")
            continue
        watched.append(WatchedFeature(name, tuple(present), tuple(dict.fromkeys(paths))))
    return tuple(watched), tuple(problems)


def select(watched: Iterable[WatchedFeature], changed: Iterable[str]) -> tuple[Arm, ...]:
    """One arm per feature with at least one changed watched path, by feature name."""
    changed = frozenset(changed)
    arms = [Arm(f.name, f.stories, tuple(p for p in f.paths if p in changed)) for f in watched]
    return tuple(sorted((arm for arm in arms if arm.changed), key=lambda arm: arm.feature))


def story_path(story: str) -> str:
    return f"{STORIES_DIR}/{story}.json"


def _story_ids(document: Mapping) -> list[str]:
    stories = document.get("stories")
    if not isinstance(stories, list):
        return []
    return list(dict.fromkeys(s for s in stories if isinstance(s, str) and s and "/" not in s))


def _rfc3339(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _store_time(moment: datetime) -> str:
    """store.py's stamp format (fixed-width UTC ISO-8601): it compares with `runs.started_at` as text in time order."""
    return moment.astimezone(timezone.utc).isoformat(timespec="microseconds")


# ---------- git ----------

class GitTree:
    """Reads one commit of `repo` with git: its files, and the paths that differ from another commit."""

    def __init__(self, repo: Path | str, sha: str, *, run: Runner = subprocess.run) -> None:
        self.repo = str(repo)
        self.sha = sha
        self.run = run

    def _git(self, *args: str, stdin: bytes | None = None) -> bytes:
        try:
            done = self.run(["git", "-C", self.repo, *args], input=stdin, capture_output=True, timeout=GIT_TIMEOUT)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ArmsError(f"git {args[0]}: {error}") from None
        if done.returncode != 0:
            message = done.stderr.decode("utf-8", "replace").strip() if isinstance(done.stderr, bytes) else done.stderr
            raise ArmsError(f"git {args[0]} at {self.sha}: {message or f'exit {done.returncode}'}")
        return done.stdout

    def resolve(self, ref: str | None = None) -> str:
        """The full sha of `ref` (default: this commit); raises ArmsError when it names no commit."""
        name = self.sha if ref is None else ref
        return self._git("rev-parse", "--verify", "--end-of-options", f"{name}^{{commit}}").decode().strip()

    def list_dir(self, directory: str) -> tuple[str, ...]:
        listed = self._git("ls-tree", "-z", "--name-only", self.sha, "--", f"{directory}/")
        return tuple(name for name in listed.decode("utf-8").split("\0") if name)

    def read(self, paths: Sequence[str]) -> dict[str, bytes | None]:
        """Each path's content at the commit, or None when the commit has no such file (one git process)."""
        if not paths:
            return {}
        request = "".join(f"{self.sha}:{path}\n" for path in paths).encode("utf-8")
        output = self._git("cat-file", "--batch", stdin=request)
        contents: dict[str, bytes | None] = {}
        at = 0
        for path in paths:
            end = output.index(b"\n", at)
            header = output[at:end].split()
            at = end + 1
            if len(header) != 3 or not header[2].isdigit():  # "<name> missing" (or ambiguous): no content follows
                contents[path] = None
                continue
            size = int(header[2])
            contents[path] = output[at:at + size] if header[1] == b"blob" else None
            at += size + 1
        return contents

    def changed_paths(self, base: str) -> frozenset[str]:
        """Paths whose content differs between the tree of `base` and the tree of this commit."""
        listed = self._git("diff", "--name-only", "--no-renames", "-z", base, self.sha, "--")
        return frozenset(name for name in listed.decode("utf-8").split("\0") if name)


def _json_documents(contents: Mapping[str, bytes | None], problems: list[str]) -> dict[str, dict | None]:
    documents: dict[str, dict | None] = {}
    for path, raw in contents.items():
        if raw is None:
            documents[path] = None
            continue
        try:
            document = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            problems.append(f"{path}: not JSON ({error})")
            continue
        if not isinstance(document, dict):
            problems.append(f"{path}: not a JSON object")
            continue
        documents[path] = document
    return documents


def measured_base(db: Path | str, since: datetime) -> str | None:
    """The commit of the newest waterfall run in the lab store (store.py) that started at or before `since`, or None
    when the store has no run that old. Opens the store read-only."""
    if since.tzinfo is None:
        raise ArmsError(f"since ({since.isoformat()}) has no UTC offset")
    try:
        with contextlib.closing(sqlite3.connect(f"{Path(db).resolve().as_uri()}?mode=ro", uri=True)) as connection:
            row = connection.execute(
                """SELECT b.sha FROM runs u JOIN builds b ON b.id = u.build_id
                   WHERE u.kind = 'waterfall' AND u.started_at <= ?
                   ORDER BY u.started_at DESC, b.commit_pos DESC, u.id DESC LIMIT 1""",
                (_store_time(since),)).fetchone()
    except sqlite3.Error as error:
        raise ArmsError(f"lab store {db}: {error}") from None
    return None if row is None else str(row[0])


def feature_arms(repo: Path | str, sha: str, now: datetime, *, base: str | None, window: timedelta = WINDOW,
                 run: Runner = subprocess.run) -> Selection:
    """The arms of the commit `sha` (the one the try pairs measure): perfPath features whose watched paths differ
    between `base`, the commit the lab measured at `now - window`, and `sha`. With no base: no arm and a problem.
    Raises ArmsError when git cannot read either commit."""
    if now.tzinfo is None:
        raise ArmsError(f"now ({now.isoformat()}) has no UTC offset")
    tree = GitTree(repo, sha, run=run)
    commit = tree.resolve()
    tree = GitTree(repo, commit, run=run)
    base_commit = None if base is None else tree.resolve(base)
    since = now - window
    problems: list[str] = []
    registry = [p for p in tree.list_dir(FEATURES_DIR) if p.endswith(".json")]
    features = {p: d for p, d in _json_documents(tree.read(registry), problems).items() if d is not None}
    story_ids = sorted({s for d in features.values() if d.get("kind") == PERF_PATH for s in _story_ids(d)})
    story_docs = _json_documents(tree.read([story_path(s) for s in story_ids]), problems)
    stories = {s: story_docs.get(story_path(s)) for s in story_ids}
    watched, watch_problems = watched_features(features, stories)
    if base_commit is None:
        problems.append(f"no commit measured at or before {_rfc3339(since)} is known, so there is nothing to diff "
                        "against: no feature arms")
        return Selection(commit, None, since, now, (), tuple(problems) + watch_problems)
    arms = select(watched, tree.changed_paths(base_commit))
    return Selection(commit, base_commit, since, now, arms, tuple(problems) + watch_problems)


# ---------- command (lab.py protocol, task 005) ----------

LAB_COMMANDS = {
    "feature-arms": "List the perfPath features that get an on/off try pair today, with the paths that changed.",
}


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="the repository (default: this checkout)")
    parser.add_argument("--ref", default="HEAD", help="the commit the try pairs measure (default: HEAD)")
    parser.add_argument("--now", help="RFC 3339 time with its UTC offset (default: now)")
    base = parser.add_mutually_exclusive_group()
    base.add_argument("--db", type=Path,
                      help="the lab store; the base is the commit of its newest waterfall run before the window")
    base.add_argument("--base", help="the commit to diff against: the one the lab measured at the window start")
    parser.add_argument("--hours", type=float, default=WINDOW.total_seconds() / 3600,
                        help="the change window before --now, in hours (default: 24)")
    parser.add_argument("--json", action="store_true", help="print the selection as JSON")


def run(command: str, args: argparse.Namespace, out=None, err=None) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    try:
        now = scheduler.parse_time(args.now) if args.now else datetime.now(timezone.utc)
        if args.hours <= 0:
            raise ArmsError(f"--hours {args.hours}: give a positive window")
        window = timedelta(hours=args.hours)
        base = args.base if args.db is None else measured_base(args.db, now - window)
        selection = feature_arms(args.root, args.ref, now, base=base, window=window)
    except (ArmsError, scheduler.SchedulerError) as error:
        print(f"feature-arms: {error}", file=err)
        return 2
    if args.json:
        json.dump(selection.to_document(), out, indent=1)
        print(file=out)
    else:
        base = selection.base[:12] if selection.base else "no base"
        print(f"feature arms at {selection.sha[:12]}, changes since {base} (measured by "
              f"{_rfc3339(selection.since)}) .. {_rfc3339(selection.until)}: {len(selection.arms)}", file=out)
        for arm in selection.arms:
            print(f"  {arm.feature} [{', '.join(arm.stories)}]: {', '.join(arm.changed)}", file=out)
        for problem in selection.problems:
            print(f"  problem: {problem}", file=out)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="features_arms.py", description=LAB_COMMANDS["feature-arms"])
    add_arguments("feature-arms", parser)
    return run("feature-arms", parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())

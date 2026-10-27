#!/usr/bin/env python3
"""Bisect into dependency rolls (p12-perf-process.md 3.6, task 236).

A bisect culprit (pinpoint.py) whose cmux diff only moves a dependency pin says "the roll did it", which names
no change anybody can fix. Pinpoint expands such a culprit into the dependency's own commits: when two adjacent
Changes differ only in a DEPS roll, the midpoint keeps the parent's commit and moves the rolled dependency to the
midpoint of its own range, so the bisect goes on inside the dependency (catapult
dashboard/dashboard/pinpoint/models/change/change.py, Change.Midpoint, _FindMidpoints and
_ExpandDepsToMatchRepositories; the roll is read from commit.py Commit.Deps):
  https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/pinpoint/models/change/change.py
cmux has three pins, read from the cmux tree at the culprit's two ends:

  ghostty       the `ghostty` submodule gitlink        GhosttyKit is built from it
  ghostty-next  the `ghostty-next` submodule gitlink   GhosttyNextKit is built from it
  cef           `fork_ref` of scripts/cmux-next/cef-manifest.json, in its `repo` (manaflow-ai/cef)

expand() turns a culprit (parent P, change C) into a nested bisect Job when the diff P..C touches nothing but
those pins (the CEF pin may move scripts/cmux-next/remote-browser-host.pin.json with it, as cef_pin_staging.py
writes both). The nested range is the path of build states from P to C, one dependency commit at a time:

  P                                    the outer culprit's parent, as measured
  P + dep@d1 ... P + dep@d(n-1)        each first-parent commit of the dependency after the old pin
  C                                    the new pin, which is C's own tree

so a bump of 8 upstream commits is a bisect over 9 Changes and its culprit names one upstream commit (a bump of
one commit names it at once, with no nested job). Two pins
moved by one culprit chain, in PINS order: the second pin's states keep the first at its new commit, the way
_FindMidpoints appends each differing dependency after the last. A roll back to an older commit walks the
dependency's first parents down to it. A pin whose old and new commits do not lie on one first-parent line is
not expanded (catapult's NonLinearError), nor is a culprit that is already inside a nested bisect.

A Change of the nested range is (P, deps) with deps ((pin, commit), ...): pinpoint.Change already carries them,
and the core keys every Change by (sha, deps). Its build is P's tree with each pin checked out at its commit and
that dependency built there (GhosttyKit for a ghostty pin, the fork for a cef pin). build_id(change) is the
40-hex key of those inputs, which the build ledger (builds.py, keyed by (sha, config)) stores it under: a plain
commit keeps its sha, so every existing record stays valid, and P + deps never reads P's own build.

    python3 -I scripts/perf-lab/deps.py moves --repo PATH --parent SHA --change SHA [--dep-dir NAME=PATH ...]

prints the pin moves of a culprit and the dependency commits each expands to, as JSON (exit 0), or why it is
not a dependency roll (exit 1). Stdlib only; loaded by file path, with pinpoint.py next to it.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import subprocess
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


def _load_pinpoint():
    name = "perf_lab_pinpoint"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / "pinpoint.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return module


pinpoint = _load_pinpoint()

GHOSTTY, GHOSTTY_NEXT, CEF = "ghostty", "ghostty-next", "cef"
PINS = (GHOSTTY, GHOSTTY_NEXT, CEF)  # the order in which one culprit's moves chain
SUBMODULES = (GHOSTTY, GHOSTTY_NEXT)  # pin name = submodule path
CEF_MANIFEST = "scripts/cmux-next/cef-manifest.json"
CEF_COMPANIONS = ("scripts/cmux-next/remote-browser-host.pin.json",)  # may move with the CEF pin, never alone
GITMODULES = ".gitmodules"


class DepsError(RuntimeError):
    """The cmux or a dependency repository could not be read (git failed, a commit is missing)."""


class Repo(Protocol):
    """What expand() reads. GitRepo is the lab's; tests pass a fake."""

    def changed_paths(self, parent: str, change: str) -> tuple[str, ...]:
        """Every path the diff parent..change touches (a submodule is its path)."""

    def gitlink(self, sha: str, path: str) -> str | None:
        """The commit the submodule at path points to in sha's tree; None when there is none."""

    def read_file(self, sha: str, path: str) -> bytes | None:
        """The blob at path in sha's tree; None when there is none."""

    def dep_path(self, pin: str, url: str, old: str, new: str) -> tuple[str, ...] | None:
        """The dependency's build states after old, ending at new: its first-parent commits after old up to new
        (oldest first), or, when new is older, the first parents of old down to new. None: old and new are not
        on one first-parent line."""


@dataclass(frozen=True)
class Move:
    """One pin a culprit moves: from old to new, through path (states after old; path[-1] == new)."""

    pin: str
    url: str
    old: str
    new: str
    path: tuple[str, ...]

    def to_dict(self) -> dict:
        return {"pin": self.pin, "url": self.url, "old": self.old, "new": self.new, "path": list(self.path)}


@dataclass(frozen=True)
class Point:
    """A Change of the nested range and the dependency commit it stands for (None for the parent P)."""

    change: "pinpoint.Change"
    pin: str | None
    sha: str | None


@dataclass(frozen=True)
class Expansion:
    """A culprit that only rolls dependencies, and the nested bisect over their commits."""

    culprit: "pinpoint.Culprit"
    moves: tuple[Move, ...]
    points: tuple[Point, ...]  # the nested range, in order, with the dependency commit of each
    job: "pinpoint.Job | None"  # None: the roll moved one commit, which is then the culprit; nothing to bisect

    def dep_commits(self, culprit: "pinpoint.Culprit") -> tuple[tuple[str, str], ...]:
        """The (pin, commit) pairs a culprit of the nested job names: every state in (culprit.parent,
        culprit.change], one commit, or a range across skipped states."""
        index = {point.change: i for i, point in enumerate(self.points)}
        try:
            lo, hi = index[culprit.parent], index[culprit.change]
        except KeyError as error:
            raise DepsError(f"{error.args[0].label()} is not a Change of this nested bisect") from None
        return tuple((p.pin, p.sha) for p in self.points[lo + 1:hi + 1])


@dataclass(frozen=True)
class NotExpanded:
    """Why a culprit stays as it is."""

    reason: str


def build_id(change: "pinpoint.Change") -> str:
    """The 40-hex key of a Change's build inputs: the commit's sha when it pins nothing over its own tree, else a
    sha1 over the commit and its (pin, commit) overrides, so the ledger never answers P + deps with P's build."""
    if not change.deps:
        return change.sha
    text = "\n".join([f"cmux {change.sha}", *(f"{pin} {sha}" for pin, sha in change.deps)])
    return hashlib.sha1(text.encode("utf-8")).hexdigest()


def _manifest(repo: Repo, sha: str) -> Mapping | None:
    raw = repo.read_file(sha, CEF_MANIFEST)
    if raw is None:
        return None
    try:
        document = json.loads(raw)
    except ValueError as error:
        raise DepsError(f"{CEF_MANIFEST} at {sha[:12]} is not JSON: {error}") from error
    return document if isinstance(document, Mapping) else None


def _submodule_url(repo: Repo, sha: str, path: str) -> str:
    raw = repo.read_file(sha, GITMODULES)
    if raw is None:
        return ""
    current, url = None, ""
    for line in raw.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if line.startswith("[submodule"):
            if current == path and url:
                return url
            current, url = None, ""
        elif "=" in line:
            key, _, value = line.partition("=")
            key, value = key.strip(), value.strip()
            if key == "path":
                current = value
            elif key == "url":
                url = value
    return url if current == path else ""


def _pin_moves(repo: Repo, parent: str, change: str) -> list[tuple[str, str, str, str]] | NotExpanded:
    """(pin, url, old, new) for each pin the diff moves, in PINS order, or why the diff is not only pin moves."""
    paths = set(repo.changed_paths(parent, change))
    if not paths:
        return NotExpanded(f"{parent[:12]}..{change[:12]} changes nothing")
    pin_paths = {*SUBMODULES, CEF_MANIFEST, *CEF_COMPANIONS}
    other = sorted(paths - pin_paths)
    if other:
        shown = ", ".join(other[:3]) + (f" and {len(other) - 3} more" if len(other) > 3 else "")
        return NotExpanded(f"{change[:12]} changes more than a dependency pin: {shown}")
    if paths & set(CEF_COMPANIONS) and CEF_MANIFEST not in paths:
        return NotExpanded(f"{change[:12]} moves {', '.join(sorted(paths & set(CEF_COMPANIONS)))} without the CEF pin")
    moves = []
    for pin in SUBMODULES:
        if pin not in paths:
            continue
        old, new = repo.gitlink(parent, pin), repo.gitlink(change, pin)
        if old is None or new is None:
            return NotExpanded(f"the {pin} submodule is {'added' if old is None else 'removed'} by {change[:12]}")
        moves.append((pin, _submodule_url(repo, change, pin), old, new))
    if CEF_MANIFEST in paths:
        before, after = _manifest(repo, parent), _manifest(repo, change)
        if before is None or after is None:
            return NotExpanded(f"{CEF_MANIFEST} is {'added' if before is None else 'removed'} by {change[:12]}")
        old, new = before.get("fork_ref"), after.get("fork_ref")
        if not isinstance(old, str) or not isinstance(new, str) or not old or not new:
            return NotExpanded(f"{CEF_MANIFEST} has no fork_ref at {(parent if not old else change)[:12]}")
        if before.get("repo") != after.get("repo"):
            return NotExpanded(f"the CEF pin moves from {before.get('repo')} to {after.get('repo')}: no single history")
        if old != new:
            moves.append((CEF, f"https://github.com/{after.get('repo')}.git", old, new))
        elif not moves:
            return NotExpanded(f"{change[:12]} re-pins CEF at the same fork commit {new[:12]}: no commits to bisect")
    if not moves:
        return NotExpanded(f"{change[:12]} moves no dependency pin")
    return moves


def moves(repo: Repo, parent: str, change: str) -> tuple[Move, ...] | NotExpanded:
    """The pin moves of the diff parent..change, each with its dependency path, or why there are none."""
    found = _pin_moves(repo, parent, change)
    if isinstance(found, NotExpanded):
        return found
    out = []
    for pin, url, old, new in found:
        path = repo.dep_path(pin, url, old, new)
        if path is None:
            return NotExpanded(f"{pin} {old[:12]}..{new[:12]} is not one first-parent line")
        path = tuple(path)
        if not path or path[-1] != new or old in path or len(set(path)) != len(path):
            raise DepsError(f"{pin} {old[:12]}..{new[:12]}: the dependency path {[s[:12] for s in path]} "
                            f"does not lead from {old[:12]} to {new[:12]}")
        out.append(Move(pin, url, old, new, path))
    return tuple(out)


def expand(job: "pinpoint.Job", culprit: "pinpoint.Culprit", repo: Repo, *,
           stored: Callable[["pinpoint.Change"], bool] = lambda change: False) -> Expansion | NotExpanded:
    """The nested bisect of a culprit that only rolls dependencies, or why the culprit stays as it is.

    job: the outer bisect; the nested one measures the same story, metric, mode, host class and magnitude.
    stored(change): a build of a dependency state exists (the ledger has build_id(change)). The two ends are
    stored: the outer bisect measured them."""
    if job.kind != pinpoint.BISECT:
        raise DepsError(f"a {job.kind} job has no culprit to expand")
    parent, change = culprit.parent, culprit.change
    if parent.deps or change.deps:
        return NotExpanded(f"{change.label()} is already a dependency state of a nested bisect")
    found = moves(repo, parent.sha, change.sha)
    if isinstance(found, NotExpanded):
        return found
    outer = {commit.change for commit in job.range()}
    if parent not in outer or change not in outer:
        raise DepsError(f"{parent.label()}..{change.label()} is not a culprit of this job")
    points = [Point(parent, None, None)]
    held: list[tuple[str, str]] = []
    for number, move in enumerate(found):
        last_move = number == len(found) - 1
        for sha in move.path:
            if last_move and sha == move.new:
                points.append(Point(change, move.pin, sha))
            else:
                points.append(Point(pinpoint.Change(parent.sha, (*held, (move.pin, sha))), move.pin, sha))
        held.append((move.pin, move.new))
    if len(points) == 2:
        return Expansion(culprit, found, tuple(points), None)
    ends = (parent, change)  # the outer bisect measured both, so their builds exist
    commits = tuple(pinpoint.Commit(p.change.sha, batch_tip=False,
                                    stored_build=p.change in ends or stored(p.change), deps=p.change.deps)
                    for p in points)
    nested = pinpoint.Job(kind=pinpoint.BISECT, mode=job.mode, story=job.story, metric=job.metric,
                          host_class=job.host_class, good=parent, bad=change, magnitude=job.magnitude,
                          better=job.better, commits=commits, attempts=job.attempts)
    return Expansion(culprit, found, tuple(points), nested)


def expand_result(job: "pinpoint.Job", result: "pinpoint.Result", repo: Repo, *,
                  stored: Callable[["pinpoint.Change"], bool] = lambda change: False,
                  ) -> list[Expansion | NotExpanded]:
    """expand() for each culprit of a finished bisect, in the result's order."""
    return [expand(job, culprit, repo, stored=stored) for culprit in result.culprits]


# ---------- the lab's repositories ----------

class GitRepo:
    """The cmux checkout at root, and one local clone per pin (dep_dirs[pin]; the submodules default to the
    checkout's own module repositories). A dependency commit that is missing is fetched from the pin's url once."""

    def __init__(self, root: Path | str, dep_dirs: Mapping[str, Path | str] | None = None, *,
                 fetch: bool = True) -> None:
        self._root = Path(root)
        self._dirs = {pin: Path(path) for pin, path in (dep_dirs or {}).items()}
        self._fetch = fetch

    def _git(self, where: Path, *args: str, ok: Sequence[int] = (0,)) -> subprocess.CompletedProcess:
        try:
            done = subprocess.run(["git", "-C", str(where), *args], capture_output=True, check=False)
        except OSError as error:
            raise DepsError(f"git {' '.join(args)}: {error}") from error
        if done.returncode not in ok:
            message = done.stderr.decode("utf-8", "replace").strip()
            raise DepsError(f"git -C {where} {' '.join(args)}: exit {done.returncode}: {message}")
        return done

    def changed_paths(self, parent: str, change: str) -> tuple[str, ...]:
        done = self._git(self._root, "diff", "--no-renames", "--name-only", "-z", parent, change)
        return tuple(p for p in done.stdout.decode("utf-8", "replace").split("\0") if p)

    def gitlink(self, sha: str, path: str) -> str | None:
        done = self._git(self._root, "ls-tree", "-z", sha, "--", path)
        for entry in done.stdout.decode("utf-8", "replace").split("\0"):
            meta, _, name = entry.partition("\t")
            fields = meta.split()
            if name == path and len(fields) == 3 and fields[1] == "commit":
                return fields[2]
        return None

    def read_file(self, sha: str, path: str) -> bytes | None:
        done = self._git(self._root, "cat-file", "blob", f"{sha}:{path}", ok=(0, 128))
        return done.stdout if done.returncode == 0 else None

    def _dep_dir(self, pin: str) -> Path:
        if pin in self._dirs:
            return self._dirs[pin]
        if pin in SUBMODULES:
            common = self._git(self._root, "rev-parse", "--git-common-dir").stdout.decode().strip()
            modules = (self._root / common / "modules" / pin).resolve()
            if modules.is_dir():
                return modules
        raise DepsError(f"no local clone of the {pin} dependency: pass --dep-dir {pin}=PATH")

    def _has(self, where: Path, sha: str) -> bool:
        return self._git(where, "cat-file", "-e", f"{sha}^{{commit}}", ok=(0, 1, 128)).returncode == 0

    def _first_parents(self, where: Path, old: str, new: str) -> list[str]:
        """First-parent commits of new back to (not including) old, newest first."""
        return self._git(where, "rev-list", "--first-parent", f"{old}..{new}").stdout.decode().split()

    def _ancestor(self, where: Path, old: str, new: str) -> bool:
        return self._git(where, "merge-base", "--is-ancestor", old, new, ok=(0, 1)).returncode == 0

    def dep_path(self, pin: str, url: str, old: str, new: str) -> tuple[str, ...] | None:
        where = self._dep_dir(pin)
        missing = [sha for sha in (old, new) if not self._has(where, sha)]
        if missing and self._fetch and url:
            self._git(where, "fetch", "-q", "--no-tags", url, *missing)
            missing = [sha for sha in missing if not self._has(where, sha)]
        if missing:
            raise DepsError(f"the {pin} clone at {where} lacks {', '.join(s[:12] for s in missing)}")
        if self._ancestor(where, old, new):
            path = list(reversed(self._first_parents(where, old, new)))
            return tuple(path) if path and self._first_parent_of(where, path[0]) == old else None
        if self._ancestor(where, new, old):
            down = self._first_parents(where, new, old)  # old, old^, ..., the child of new
            if not down or self._first_parent_of(where, down[-1]) != new:
                return None
            return (*down[1:], new)
        return None

    def _first_parent_of(self, where: Path, sha: str) -> str | None:
        out = self._git(where, "rev-parse", "--verify", "-q", f"{sha}^1", ok=(0, 1)).stdout.decode().strip()
        return out or None


# ---------- CLI ----------

def _dep_dirs(values: Sequence[str]) -> dict[str, str]:
    out = {}
    for value in values:
        pin, sep, path = value.partition("=")
        if not sep or pin not in PINS or not path:
            raise argparse.ArgumentTypeError(f"--dep-dir takes NAME=PATH with NAME in {', '.join(PINS)}: {value}")
        out[pin] = path
    return out


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="The dependency pins a culprit moves, and their commits.")
    sub = parser.add_subparsers(dest="command", required=True)
    show = sub.add_parser("moves", help="print the pin moves of parent..change and each one's dependency commits")
    show.add_argument("--repo", default=".", help="the cmux checkout")
    show.add_argument("--parent", required=True)
    show.add_argument("--change", required=True)
    show.add_argument("--dep-dir", action="append", default=[], metavar="NAME=PATH",
                      help=f"a local clone of a dependency ({', '.join(PINS)})")
    show.add_argument("--no-fetch", action="store_true", help="never fetch a missing dependency commit")
    args = parser.parse_args(argv)
    try:
        repo = GitRepo(args.repo, _dep_dirs(args.dep_dir), fetch=not args.no_fetch)
        found = moves(repo, args.parent, args.change)
    except (DepsError, argparse.ArgumentTypeError) as error:
        print(f"deps: {error}", file=sys.stderr)
        return 2
    if isinstance(found, NotExpanded):
        print(json.dumps({"expanded": False, "reason": found.reason}))
        return 1
    print(json.dumps({"expanded": True, "moves": [move.to_dict() for move in found]}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

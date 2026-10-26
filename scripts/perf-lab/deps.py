#!/usr/bin/env python3
"""Bisect into dependency rolls: a culprit that only moves a dependency pin becomes a nested bisect of
the dependency's own commits (p12-perf-process.md 3.6, task 236).

Pinpoint does this for Chromium DEPS rolls. When the two Changes of a culprit are adjacent in the base
repository, Change.Midpoint expands the DEPS entries that differ between them and goes on bisecting
inside the rolled repository, with the base held at the earlier commit and the dependency overridden;
a dependency that did not move forward is a NonLinearError (catapult change.py _FindMidpoints,
commit.py Commit.Deps):
  https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/pinpoint/models/change/change.py
  https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/pinpoint/models/change/commit.py

cmux has three pins in the role of DEPS (DEPS below, in the order they step):
- `ghostty`: the classic app's submodule (GhosttyKit);
- `ghostty-next`: cmux-next's submodule (GhosttyNextKit);
- `cef`: `fork_ref` of scripts/cmux-next/cef-manifest.json, a commit of manaflow-ai/cef.

A culprit range good..bad is a roll when its diff touches only the pins that moved and their companion
files (the checksum, notice and Package.swift lines a pin change rewrites with it). It expands to
Change(good, {dep: d}) for d = old, then each first-parent commit of old..new in the dependency's
repository. Every nested Change carries its override, the ends too, so each one builds the dependency
the same way (GhosttyKit from source at d). When several pins moved, they step one after another in
DEPS order, the earlier ones already at new, as _FindMidpoints does.

A CEF runtime is a Chromium build, so only fork commits with a published runtime (a release tag) can
be built; the others are unbuildable and the bisect skips them (pinpoint.py, task 015). The two pinned
ends are releases by construction.

The nested Changes build through scripts/measure/perf-lab-build.sh with `--dep=NAME=SHA` next to
`--build-sha` (build_args); their build record is keyed by Change.build_key.

- expand(): the Decision for a culprit range: an Expansion, or the reason it is not a roll.
- Expansion.midpoint(): Pinpoint's midpoint over the nested Changes.
- nested_job(): the bisect Job fields for the nested range, from the parent job.
- GitRepo: the git seam, over a cmux checkout or a dependency's mirror.

Stdlib only. CLI: deps.py expand --repo PATH --good SHA --bad SHA [--dep-repo NAME=PATH ...]
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import subprocess
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol

GITLINK_MODE = "160000"
BUILD_SOURCE = "source"  # the builder builds the dependency at any commit (GhosttyKit from source)
BUILD_PUBLISHED = "published"  # only commits with a published artifact (a release tag) can be built


class DepsError(ValueError):
    """A git query that failed, or a pin that cannot be read."""


@dataclass(frozen=True)
class DepSpec:
    name: str
    pin_path: str  # the submodule's gitlink path, or the manifest file that holds the pin
    manifest_key: str | None  # None: a gitlink; else the manifest's JSON key that names the commit
    companions: tuple[str, ...]  # files a pin change rewrites with the pin
    build: str  # BUILD_SOURCE or BUILD_PUBLISHED
    release_tags: str | None = None  # BUILD_PUBLISHED: glob of the tags that mark a published commit

    @property
    def paths(self) -> frozenset[str]:
        return frozenset((self.pin_path, *self.companions))


DEPS: tuple[DepSpec, ...] = (
    DepSpec(
        name="ghostty",
        pin_path="ghostty",
        manifest_key=None,
        companions=("scripts/ghosttykit-checksums.txt", "docs/ghostty-fork.md"),
        build=BUILD_SOURCE,
    ),
    DepSpec(
        name="ghostty-next",
        pin_path="ghostty-next",
        manifest_key=None,
        companions=(
            "Packages/Shared/CmuxGhosttyKit/Package.swift",
            "cmux-tui/dist/notices/package-notices.json",
            "scripts/cmux-next/notices/vt-link-graph.json",
        ),
        build=BUILD_SOURCE,
    ),
    DepSpec(
        name="cef",
        pin_path="scripts/cmux-next/cef-manifest.json",
        manifest_key="fork_ref",
        companions=(),
        build=BUILD_PUBLISHED,
        release_tags="cef-*-cmux.*",
    ),
)


class Git(Protocol):
    def changed_paths(self, good: str, bad: str) -> tuple[str, ...]: ...

    def gitlink(self, sha: str, path: str) -> str | None: ...

    def read(self, sha: str, path: str) -> str | None: ...

    def has_commit(self, sha: str) -> bool: ...

    def is_ancestor(self, old: str, new: str) -> bool: ...

    def first_parent_range(self, old: str, new: str) -> tuple[str, ...]: ...

    def tags_at(self, sha: str) -> tuple[str, ...]: ...


Runner = Callable[..., subprocess.CompletedProcess]


class GitRepo:
    """Read-only git queries on one repository (a cmux checkout, a submodule's git dir or a mirror)."""

    def __init__(self, path: str, *, run: Runner = subprocess.run) -> None:
        self.path = path
        self._run = run

    def _git(self, *args: str, ok: Sequence[int] = (0,)) -> subprocess.CompletedProcess:
        proc = self._run(["git", "-C", self.path, *args], capture_output=True, text=True, check=False)
        if proc.returncode not in ok:
            raise DepsError(f"git {' '.join(args)} in {self.path}: exit {proc.returncode}: {proc.stderr.strip()}")
        return proc

    def changed_paths(self, good: str, bad: str) -> tuple[str, ...]:
        out = self._git("diff", "--no-renames", "--name-only", "-z", good, bad).stdout
        return tuple(sorted(p for p in out.split("\0") if p))

    def gitlink(self, sha: str, path: str) -> str | None:
        out = self._git("ls-tree", "-z", sha, "--", path).stdout
        for entry in out.split("\0"):
            if not entry:
                continue
            meta, _, name = entry.partition("\t")
            mode, _, rest = meta.partition(" ")
            if name == path and mode == GITLINK_MODE:
                return rest.split(" ")[-1]
        return None

    def read(self, sha: str, path: str) -> str | None:
        proc = self._git("cat-file", "blob", f"{sha}:{path}", ok=(0, 128))
        return proc.stdout if proc.returncode == 0 else None

    def has_commit(self, sha: str) -> bool:
        return self._git("cat-file", "-e", f"{sha}^{{commit}}", ok=(0, 1, 128)).returncode == 0

    def is_ancestor(self, old: str, new: str) -> bool:
        return self._git("merge-base", "--is-ancestor", old, new, ok=(0, 1)).returncode == 0

    def first_parent_range(self, old: str, new: str) -> tuple[str, ...]:
        out = self._git("rev-list", "--first-parent", "--reverse", f"{old}..{new}").stdout
        return tuple(out.split())

    def tags_at(self, sha: str) -> tuple[str, ...]:
        return tuple(self._git("tag", "--points-at", sha).stdout.split())

    def resolve(self, rev: str) -> str:
        """The full commit id of REV, so build keys never hold a relative name."""
        return self._git("rev-parse", "--verify", "--end-of-options", f"{rev}^{{commit}}").stdout.strip()

    def common_dir(self) -> str:
        return self._git("rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()


@dataclass(frozen=True)
class Change:
    """A cmux commit, with the dependency commits it builds against instead of its own pins."""

    sha: str
    deps: tuple[tuple[str, str], ...] = ()  # (dep name, commit), in DEPS order

    def dep(self, name: str) -> str | None:
        return dict(self.deps).get(name)

    @property
    def build_key(self) -> str:
        """The build record's key: the sha alone, or sha+name=commit for each override."""
        return "+".join([self.sha, *(f"{name}={sha}" for name, sha in self.deps)])

    def build_args(self, config: str) -> list[str]:
        """perf-lab-build.sh's arguments for this Change."""
        return [f"--build-sha={self.sha}", *(f"--dep={name}={sha}" for name, sha in self.deps), f"--config={config}"]

    def to_json(self) -> dict[str, object]:
        return {"sha": self.sha, "deps": dict(self.deps), "build_key": self.build_key}


@dataclass(frozen=True)
class Roll:
    dep: str
    old: str
    new: str
    commits: tuple[str, ...]  # first-parent old..new, oldest first; the last one is new

    def to_json(self) -> dict[str, object]:
        return {"dep": self.dep, "old": self.old, "new": self.new, "commits": list(self.commits)}


@dataclass(frozen=True)
class Expansion:
    good: str
    bad: str
    rolls: tuple[Roll, ...]
    changes: tuple[Change, ...]  # good's build with every pin at old, then one step per dependency commit
    unbuildable: frozenset[Change]

    def index(self, change: Change) -> int:
        try:
            return self.changes.index(change)
        except ValueError:
            raise DepsError(f"{change.build_key} is not a Change of the roll {self.good[:12]}..{self.bad[:12]}") from None

    def midpoint(self, a: Change, b: Change) -> Change | None:
        """The Change halfway between a and b; None when they are adjacent (Pinpoint's Midpoint)."""
        lo, hi = sorted((self.index(a), self.index(b)))
        return None if hi - lo < 2 else self.changes[(lo + hi) // 2]

    def culprit(self, a: Change, b: Change) -> tuple[str, str]:
        """(dep, commit) that adjacent Changes a -> b step to: the dependency culprit."""
        lo, hi = sorted((self.index(a), self.index(b)))
        if hi - lo != 1:
            raise DepsError(f"{a.build_key} and {b.build_key} are not adjacent")
        before, after = dict(self.changes[lo].deps), dict(self.changes[hi].deps)
        (moved,) = [name for name in after if after[name] != before[name]]
        return moved, after[moved]

    def to_json(self) -> dict[str, object]:
        return {
            "good": self.good,
            "bad": self.bad,
            "rolls": [roll.to_json() for roll in self.rolls],
            "changes": [change.to_json() for change in self.changes],
            "unbuildable": [change.build_key for change in self.changes if change in self.unbuildable],
        }


@dataclass(frozen=True)
class Decision:
    expansion: Expansion | None
    reason: str

    def to_json(self) -> dict[str, object]:
        return {"expanded": self.expansion is not None, "reason": self.reason,
                "expansion": self.expansion.to_json() if self.expansion else None}


def pin_at(git: Git, spec: DepSpec, sha: str) -> str | None:
    """The dependency commit SPEC pins at cmux commit SHA; None when the pin does not exist there."""
    if spec.manifest_key is None:
        return git.gitlink(sha, spec.pin_path)
    text = git.read(sha, spec.pin_path)
    if text is None:
        return None
    try:
        value = json.loads(text).get(spec.manifest_key)
    except (json.JSONDecodeError, AttributeError) as exc:
        raise DepsError(f"{spec.pin_path} at {sha[:12]} is not a JSON object: {exc}") from None
    return value if isinstance(value, str) and value else None


def _published(spec: DepSpec, repo: Git, sha: str) -> bool:
    return any(fnmatch.fnmatchcase(tag, spec.release_tags or "") for tag in repo.tags_at(sha))


def _list(paths: Sequence[str], limit: int = 5) -> str:
    more = f" (+{len(paths) - limit} more)" if len(paths) > limit else ""
    return ", ".join(paths[:limit]) + more


def expand(
    good: str,
    bad: str,
    git: Git,
    dep_repos: Mapping[str, Git],
    *,
    specs: Sequence[DepSpec] = DEPS,
) -> Decision:
    """Expands the culprit range good..bad of cmux into a nested bisect when it only rolls pins."""
    paths = git.changed_paths(good, bad)
    if not paths:
        return Decision(None, "no-change: the range changes no file")
    moved = [(spec, pin_at(git, spec, good), pin_at(git, spec, bad)) for spec in specs]
    moved = [(spec, old, new) for spec, old, new in moved if old != new]
    if not moved:
        return Decision(None, "no-dep-moved: no pin moves in the range")
    allowed = frozenset().union(*(spec.paths for spec, _, _ in moved))
    other = [path for path in paths if path not in allowed]
    if other:
        return Decision(None, f"mixed: the range also changes {_list(other)}")
    rolls = []
    for spec, old, new in moved:
        if old is None:
            return Decision(None, f"dep-added: {spec.name} has no pin at {good[:12]}")
        if new is None:
            return Decision(None, f"dep-removed: {spec.name} has no pin at {bad[:12]}")
        repo = dep_repos.get(spec.name)
        if repo is None:
            return Decision(None, f"no-repo: no repository of {spec.name} on this host")
        missing = [sha for sha in (old, new) if not repo.has_commit(sha)]
        if missing:
            return Decision(None, f"dep-commit-missing: {spec.name} repository lacks {_list([s[:12] for s in missing])}")
        if not repo.is_ancestor(old, new):
            return Decision(None, f"non-linear: {spec.name} {new[:12]} does not descend from {old[:12]}")
        rolls.append((spec, repo, Roll(spec.name, old, new, repo.first_parent_range(old, new))))
    pins = {roll.dep: roll.old for _, _, roll in rolls}
    changes = [Change(good, tuple(pins.items()))]
    unbuildable = set()
    for spec, repo, roll in rolls:
        for commit in roll.commits:
            pins[roll.dep] = commit
            change = Change(good, tuple(pins.items()))
            changes.append(change)
            if spec.build == BUILD_PUBLISHED and commit != roll.new and not _published(spec, repo, commit):
                unbuildable.add(change)
    summary = "; ".join(f"{r.dep} {r.old[:12]}..{r.new[:12]} ({len(r.commits)} commits)" for _, _, r in rolls)
    return Decision(Expansion(good, bad, tuple(r for _, _, r in rolls), tuple(changes), frozenset(unbuildable)),
                    f"roll: {summary}")


def _field(job: object, name: str) -> object:
    return job[name] if isinstance(job, Mapping) else getattr(job, name)


def nested_job(parent: object, expansion: Expansion) -> dict[str, object]:
    """The fields of the nested bisect Job (pinpoint.py): the parent's story, metric, host class, mode
    and magnitude over the roll's Changes."""
    fields = {name: _field(parent, name) for name in ("mode", "story", "metric", "host_class", "magnitude")}
    return {"kind": "bisect", **fields, "good": expansion.changes[0], "bad": expansion.changes[-1]}


def default_dep_repos(repo: GitRepo, run: Runner = subprocess.run) -> dict[str, GitRepo]:
    """The submodules' git dirs of a cmux checkout (.git/modules/NAME of its common dir)."""
    common = repo.common_dir()
    found = {}
    for spec in DEPS:
        path = os.path.join(common, "modules", spec.pin_path)
        if spec.manifest_key is None and os.path.isdir(path):
            found[spec.name] = GitRepo(path, run=run)
    return found


def _main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="deps.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    cmd = sub.add_parser("expand", help="print the Decision for a culprit range as JSON")
    cmd.add_argument("--repo", default=".", help="the cmux checkout")
    cmd.add_argument("--good", required=True)
    cmd.add_argument("--bad", required=True)
    cmd.add_argument("--dep-repo", action="append", default=[], metavar="NAME=PATH",
                     help="a dependency's repository (default for submodules: the checkout's .git/modules/NAME)")
    args = parser.parse_args(argv)
    names = {spec.name for spec in DEPS}
    repo = GitRepo(args.repo)
    try:
        dep_repos: dict[str, Git] = dict(default_dep_repos(repo))
        for item in args.dep_repo:
            name, sep, path = item.partition("=")
            if not sep or name not in names:
                parser.error(f"--dep-repo takes NAME=PATH with NAME in {sorted(names)} (got {item!r})")
            dep_repos[name] = GitRepo(path)
        decision = expand(repo.resolve(args.good), repo.resolve(args.bad), repo, dep_repos)
    except DepsError as exc:
        print(f"deps.py: {exc}", file=sys.stderr)
        return 1
    json.dump(decision.to_json(), sys.stdout, indent=2, sort_keys=True)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))

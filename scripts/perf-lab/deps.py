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
those pins and the files a roll moves with each pin (COMPANIONS), each only together with its own pin and only as
far as it follows that pin:

  ghostty       scripts/ghosttykit-checksums.txt gains a checksum for the new commit and drops none;
                docs/ghostty-fork.md and .github/workflows/build-ghosttykit.yml (the fork's notes and CI tests)
  ghostty-next  Packages/Shared/CmuxGhosttyKit/Package.swift changes only comments and the GhosttyNextKit
                binaryTarget, whose url names the new commit; cmux-tui/dist/notices/package-notices.json
                (libghostty_vt) and scripts/cmux-next/notices/vt-link-graph.json record the new commit
  cef           scripts/cmux-next/remote-browser-host.pin.json, rebuilt against the new CEF artifact (its cef_sha256
                is the manifest's, its own source stays), as cef_pin_staging.py writes both

A change of the CEF manifest that keeps fork_ref, or that changes a field other than the fork build's own artifact
(CEF_ARTIFACT_FIELDS; require_dcheck_off is cmux's policy, not the fork's history), is never expanded, whatever
else moves: no nested state holds it, so the last nested step would blame an upstream commit for it.
The nested range is the path of build states from P to C, one dependency commit at a time:

  P                                    the outer culprit's parent, as measured
  P + dep@d1 ... P + dep@d(n-1)        each first-parent commit of the dependency after the old pin
  C                                    the new pin, which is C's own tree

so a bump of 8 upstream commits is a bisect over 9 Changes and its culprit names one upstream commit (a bump of
one commit names it at once, with no nested job). Two pins
moved by one culprit chain, in PINS order: the second pin's states keep the first at its new commit, the way
_FindMidpoints appends each differing dependency after the last. A roll back to an older commit walks the
dependency's first parents down to it. A pin whose old and new commits do not lie on one first-parent line is
not expanded (catapult's NonLinearError), nor is any culprit of a job that is already a nested bisect (its range
holds a dependency state), even the range culprit (P, C) of one whose every middle state was skipped.

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
PIN_LABELS = {GHOSTTY: "ghostty", GHOSTTY_NEXT: "ghostty-next", CEF: "CEF"}
CEF_MANIFEST = "scripts/cmux-next/cef-manifest.json"
GITMODULES = ".gitmodules"
GHOSTTYKIT_CHECKSUMS = "scripts/ghosttykit-checksums.txt"
GHOSTTY_FORK_DOC = "docs/ghostty-fork.md"
GHOSTTYKIT_WORKFLOW = ".github/workflows/build-ghosttykit.yml"
GHOSTTY_NEXT_PACKAGE = "Packages/Shared/CmuxGhosttyKit/Package.swift"
GHOSTTY_NEXT_TARGET = "GhosttyNextKit"
PACKAGE_NOTICES = "cmux-tui/dist/notices/package-notices.json"
PACKAGE_NOTICES_ENTRY = "libghostty_vt"
VT_LINK_GRAPH = "scripts/cmux-next/notices/vt-link-graph.json"
REMOTE_BROWSER_HOST_PIN = "scripts/cmux-next/remote-browser-host.pin.json"
# The files a roll moves with each pin; each may change only together with its own pin.
COMPANIONS = {
    GHOSTTY: (GHOSTTYKIT_CHECKSUMS, GHOSTTY_FORK_DOC, GHOSTTYKIT_WORKFLOW),
    GHOSTTY_NEXT: (GHOSTTY_NEXT_PACKAGE, PACKAGE_NOTICES, VT_LINK_GRAPH),
    CEF: (REMOTE_BROWSER_HOST_PIN,),
}
# CEF manifest fields that describe the fork build at fork_ref: its artifact, version, API level and storage. Any
# other field (repo, arch, require_dcheck_off, a new one) is cmux's own choice.
CEF_ARTIFACT_FIELDS = frozenset({
    "fork_ref", "fork_branch", "version", "cef", "chromium", "tag", "asset", "url", "sha256", "r2_bucket", "r2_key",
    "debug_asset", "debug_sha256", "debug_r2_key", "debug_symbols", "cmux_cef_api_version", "missing_api", "x86_64",
    "staging",
})
# Host pin fields that are the host's own build, which a CEF re-pin keeps.
HOST_PIN_OWN_FIELDS = ("asset", "arch", "source_commit", "crate_tree")


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


def _json(repo: Repo, sha: str, path: str) -> Mapping | None:
    raw = repo.read_file(sha, path)
    if raw is None:
        return None
    try:
        document = json.loads(raw)
    except ValueError as error:
        raise DepsError(f"{path} at {sha[:12]} is not JSON: {error}") from error
    return document if isinstance(document, Mapping) else None


def _text(repo: Repo, sha: str, path: str) -> str | None:
    raw = repo.read_file(sha, path)
    return None if raw is None else raw.decode("utf-8", "replace")


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


@dataclass(frozen=True)
class _Pin:
    """One pin the diff moves, before its dependency path is read."""

    pin: str
    url: str
    old: str
    new: str


# ---------- companions: each returns why its diff does more than follow its pin, or None ----------

def _checksums_follow(repo: Repo, parent: str, change: str, pin: _Pin) -> str | None:
    before = set((_text(repo, parent, GHOSTTYKIT_CHECKSUMS) or "").splitlines())
    after = _text(repo, change, GHOSTTYKIT_CHECKSUMS)
    if after is None:
        return f"{GHOSTTYKIT_CHECKSUMS} is removed"
    lines = after.splitlines()
    if not before <= set(lines):
        return f"{GHOSTTYKIT_CHECKSUMS} drops or edits a checksum"
    if not any(line.split()[:1] == [pin.new] for line in lines):
        return f"{GHOSTTYKIT_CHECKSUMS} has no checksum for the new ghostty commit {pin.new[:12]}"
    return None


def _ghostty_notes_follow(repo: Repo, parent: str, change: str, pin: _Pin) -> str | None:
    """The fork's notes and its CI tests are no input of a lab build: the ghostty pin moving with them is enough."""
    return None


def _package_code(text: str) -> tuple[list[str], str | None]:
    """Package.swift's code lines, without comments and without the GhosttyNextKit binaryTarget's url and
    checksum, and that url line."""
    kept, url, in_target = [], None, False
    for line in text.splitlines():
        code = line.strip()
        if not code or code.startswith("//"):
            continue
        if code == f'name: "{GHOSTTY_NEXT_TARGET}",':
            in_target = True
        elif in_target and code.startswith(("url:", "checksum:")):
            url = code if code.startswith("url:") else url
            continue
        elif in_target and code.startswith(")"):
            in_target = False
        kept.append(code)
    return kept, url


def _package_follows(repo: Repo, parent: str, change: str, pin: _Pin) -> str | None:
    before, after = _text(repo, parent, GHOSTTY_NEXT_PACKAGE), _text(repo, change, GHOSTTY_NEXT_PACKAGE)
    if before is None or after is None:
        return f"{GHOSTTY_NEXT_PACKAGE} is {'added' if before is None else 'removed'}"
    (code_before, _), (code_after, url) = _package_code(before), _package_code(after)
    if code_before != code_after:
        return f"{GHOSTTY_NEXT_PACKAGE} changes more than the {GHOSTTY_NEXT_TARGET} binaryTarget"
    if url is None or f"-{pin.new}-" not in url:
        return f"{GHOSTTY_NEXT_PACKAGE} does not pin {GHOSTTY_NEXT_TARGET} at the new commit {pin.new[:12]}"
    return None


def _commit_of(document: Mapping) -> str | None:
    commit = document.get("commit")
    return commit if isinstance(commit, str) else None


def _notices_follow(repo: Repo, parent: str, change: str, pin: _Pin) -> str | None:
    before, after = _json(repo, parent, PACKAGE_NOTICES), _json(repo, change, PACKAGE_NOTICES)
    if before is None or after is None:
        return f"{PACKAGE_NOTICES} is {'added' if before is None else 'removed'}"
    if {k: v for k, v in before.items() if k != PACKAGE_NOTICES_ENTRY} != \
            {k: v for k, v in after.items() if k != PACKAGE_NOTICES_ENTRY}:
        return f"{PACKAGE_NOTICES} changes more than {PACKAGE_NOTICES_ENTRY}"
    old, new = before.get(PACKAGE_NOTICES_ENTRY), after.get(PACKAGE_NOTICES_ENTRY)
    if not isinstance(old, Mapping) or not isinstance(new, Mapping) or old.get("source") != new.get("source") \
            or _commit_of(new) != pin.new:
        return f"{PACKAGE_NOTICES} does not move {PACKAGE_NOTICES_ENTRY} to the new commit {pin.new[:12]}"
    return None


def _link_graph_follows(repo: Repo, parent: str, change: str, pin: _Pin) -> str | None:
    before, after = _json(repo, parent, VT_LINK_GRAPH), _json(repo, change, VT_LINK_GRAPH)
    if before is None or after is None:
        return f"{VT_LINK_GRAPH} is {'added' if before is None else 'removed'}"
    if before.get("source") != after.get("source") or _commit_of(after) != pin.new:
        return f"{VT_LINK_GRAPH} does not move to the new commit {pin.new[:12]}"
    return None


def _host_pin_follows(repo: Repo, parent: str, change: str, pin: _Pin) -> str | None:
    before, after = _json(repo, parent, REMOTE_BROWSER_HOST_PIN), _json(repo, change, REMOTE_BROWSER_HOST_PIN)
    if before is None or after is None:
        return f"{REMOTE_BROWSER_HOST_PIN} is {'added' if before is None else 'removed'}"
    own = [key for key in HOST_PIN_OWN_FIELDS if before.get(key) != after.get(key)]
    if own:
        return f"{REMOTE_BROWSER_HOST_PIN} changes the host's own {', '.join(own)}"
    if after.get("cef_sha256") != (_json(repo, change, CEF_MANIFEST) or {}).get("sha256"):
        return f"{REMOTE_BROWSER_HOST_PIN} is not built against the new CEF artifact"
    return None


_FOLLOWS: dict[str, Callable[[Repo, str, str, _Pin], str | None]] = {
    GHOSTTYKIT_CHECKSUMS: _checksums_follow,
    GHOSTTY_FORK_DOC: _ghostty_notes_follow,
    GHOSTTYKIT_WORKFLOW: _ghostty_notes_follow,
    GHOSTTY_NEXT_PACKAGE: _package_follows,
    PACKAGE_NOTICES: _notices_follow,
    VT_LINK_GRAPH: _link_graph_follows,
    REMOTE_BROWSER_HOST_PIN: _host_pin_follows,
}


def _cef_move(repo: Repo, parent: str, change: str) -> _Pin | NotExpanded:
    """The CEF pin's move. A manifest change that keeps fork_ref, or that changes a field outside the fork build's
    own artifact, is NotExpanded whatever else the diff moves: no nested state holds it."""
    before, after = _json(repo, parent, CEF_MANIFEST), _json(repo, change, CEF_MANIFEST)
    if before is None or after is None:
        return NotExpanded(f"{CEF_MANIFEST} is {'added' if before is None else 'removed'} by {change[:12]}")
    old, new = before.get("fork_ref"), after.get("fork_ref")
    if not isinstance(old, str) or not isinstance(new, str) or not old or not new:
        return NotExpanded(f"{CEF_MANIFEST} has no fork_ref at {(parent if not old else change)[:12]}")
    if before.get("repo") != after.get("repo"):
        return NotExpanded(f"the CEF pin moves from {before.get('repo')} to {after.get('repo')}: no single history")
    if old == new:
        return NotExpanded(f"{change[:12]} changes {CEF_MANIFEST} at the same fork commit {new[:12]}: "
                           "no fork commits to bisect it in")
    policy = sorted(key for key in before.keys() | after.keys()
                    if key not in CEF_ARTIFACT_FIELDS and before.get(key) != after.get(key))
    if policy:
        return NotExpanded(f"{change[:12]} changes {CEF_MANIFEST} {', '.join(policy)} with the fork commit: "
                           "not a commit of the fork")
    return _Pin(CEF, f"https://github.com/{after.get('repo')}.git", old, new)


def _pin_moves(repo: Repo, parent: str, change: str) -> list[_Pin] | NotExpanded:
    """Each pin the diff moves, in PINS order, or why the diff is more than pin moves and the files following them."""
    paths = set(repo.changed_paths(parent, change))
    if not paths:
        return NotExpanded(f"{parent[:12]}..{change[:12]} changes nothing")
    other = sorted(paths - {*SUBMODULES, CEF_MANIFEST, *_FOLLOWS})
    if other:
        shown = ", ".join(other[:3]) + (f" and {len(other) - 3} more" if len(other) > 3 else "")
        return NotExpanded(f"{change[:12]} changes more than a dependency pin: {shown}")
    moved: dict[str, _Pin] = {}
    for pin in SUBMODULES:
        if pin not in paths:
            continue
        old, new = repo.gitlink(parent, pin), repo.gitlink(change, pin)
        if old is None or new is None:
            return NotExpanded(f"the {pin} submodule is {'added' if old is None else 'removed'} by {change[:12]}")
        moved[pin] = _Pin(pin, _submodule_url(repo, change, pin), old, new)
    if CEF_MANIFEST in paths:
        cef = _cef_move(repo, parent, change)
        if isinstance(cef, NotExpanded):
            return cef
        moved[CEF] = cef
    for pin, files in COMPANIONS.items():
        for path in sorted(paths.intersection(files)):
            if pin not in moved:
                return NotExpanded(f"{change[:12]} moves {path} without the {PIN_LABELS[pin]} pin")
            reason = _FOLLOWS[path](repo, parent, change, moved[pin])
            if reason is not None:
                return NotExpanded(f"{change[:12]}: {reason}")
    if not moved:
        return NotExpanded(f"{change[:12]} moves no dependency pin")
    return [moved[pin] for pin in PINS if pin in moved]


def moves(repo: Repo, parent: str, change: str) -> tuple[Move, ...] | NotExpanded:
    """The pin moves of the diff parent..change, each with its dependency path, or why there are none."""
    found = _pin_moves(repo, parent, change)
    if isinstance(found, NotExpanded):
        return found
    out = []
    for pin, url, old, new in ((p.pin, p.url, p.old, p.new) for p in found):
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
    if any(commit.deps for commit in job.range()):
        return NotExpanded(f"{parent.label()}..{change.label()} is a culprit of a nested bisect: "
                           "its dependency states are already expanded")
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

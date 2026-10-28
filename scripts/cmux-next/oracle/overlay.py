#!/usr/bin/env python3
"""Run head's oracle against a base SHA that predates it: the overlay commit, or v0 facets on both sides.

  overlay.py prepare --base REF --head REF [--product P] [--repo DIR] [--v0 REASON] [--push REMOTE] [--out FILE]
  overlay.py describe SHA [--repo DIR]
  overlay.py not-comparable [--product P]

Spec: plans/cmux-next/chrome-parity/p15-oracle.md section 3A (v0 facets, `--overlay`) and task p15-oracle-202.
Stdlib only, safe under `python3 -I`. Tests: overlay_test.py.

`prepare` makes the base build of a base/head diff:
  1. Head's oracle commits that the base lacks (the non-merge commits of base..head whose subject names a
     p15-oracle task, parents first) are applied to the base tree with `git apply --cached --3way`, limited to the
     product's build scope (SCOPES: cmux-tui/ for the VM products) and to files outside RUNNER. These are the
     oracle's additions to product files: the cargo profile and feature, `oracle-state`, a provider's registration.
  2. Products whose runner runs from the build's own checkout (the app: a fleet step runs scripts/measure/oracle.sh
     of the commit it built) also get every RUNNER path whole from head. On the VM the runner is this checkout's.
  3. Outside RUNNER the result must be additive: it only adds lines and files to the base tree. A removed line, a
     deleted file or a binary change would change the base's behavior, so it is refused.
The result is `overlay` (a commit on the base, built instead of it), `native` (the base already has every oracle
change of head in scope: build the base) or `v0`: a patch did not apply, the result was not additive, or the caller
said so (`--v0 REASON`, for example after the overlay failed to build). With v0 both sides run v0 facets
(facets_v0.py, p15-oracle-006: push-base methods only), because a v0 snapshot is compared only with a v0 snapshot,
and every facet or field v0 cannot give is listed in `notComparable`.

The overlay commit is written with fixed author, committer and dates and head's commit time, so one base, head and
product always give one overlay SHA, and it is kept by refs/oracle-overlay/<sha> so gc cannot drop it before its
build. Its message carries Oracle-Overlay-Base/Head/Product trailers: `describe SHA` reads them, so any build of
an overlay commit can say what it is (linux_run.sh puts it in build.json). `prepare` prints the plan
(also written to --out):
  {"schema": "cmux-oracle-overlay-v1", "product", "mode": "native" | "overlay" | "v0", "facets": "v1" | "v0",
   "base", "head", "buildSha", "overlaySha" (when buildSha is not the base), "commits": [{"sha", "subject"}],
   "applied": [sha], "files": [path], "reason" (v0), "notComparable": [{"facet", "reason", "task"?}],
   "pushedRef" (--push)}

`mask_runs` is the comparison side. Before diff.py compares two runs, every facet or facet field that is not
comparable on either side (a not-comparable value, a row's `notComparable`, or the plan's list) is replaced on both
sides by one marker, so it is never compared. A case with checkpoints but no comparable facet left in any of them
is not-comparable: it becomes Skip on both sides when the two results agree (diff.py then reports it skipped,
never equal), and stays a result divergence when they do not. `oracle.py diff --overlay PLAN` applies it.

Chrome reference: catapult dashboard/dashboard/pinpoint/models/change/change.py (a Pinpoint Change is a commit plus
an optional patch, applied to every commit of the bisect range so an old commit runs the new measurement; a patch
that does not apply fails that build instead of running the commit unpatched) and WPT's wptrunner, which runs
head's tests on an older product and reports a test the product cannot run as not run, never as a pass.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, List, Mapping, Optional, Sequence, Set, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]

SCHEMA = "cmux-oracle-overlay-v1"
TASK = "p15-oracle-202"
# The runner, taken whole from head where the build's checkout runs it. A directory ends in "/".
RUNNER: Tuple[str, ...] = (
    "scripts/cmux-next/oracle/",
    "scripts/measure/oracle.sh",
    "schemas/oracle/",
    "tests/oracle/",
    "plans/cmux-next/refactor-switches/",
)
# What each product's build reads: (include prefixes, or () for the whole tree; exclude prefixes).
VM_SCOPE: Tuple[Tuple[str, ...], Tuple[str, ...]] = (("cmux-tui/",), ())
SCOPES: Dict[str, Tuple[Tuple[str, ...], Tuple[str, ...]]] = {
    "daemon": VM_SCOPE,
    "cli": VM_SCOPE,
    "mcp": VM_SCOPE,
    "tui": VM_SCOPE,
    # The fleet's app build: everything but prose, the Linux Swift tier and the script tests.
    "app": ((), ("plans/", "docs/", "scripts/cmux-next/linux/", "scripts/cmux-next/tests/")),
}
RUNNER_IN_TREE = frozenset({"app"})
ORACLE_SUBJECT = re.compile(r"\bp15-oracle-[0-9]{3}\b")
NOT_COMPARABLE = "not-comparable"
MARKER = {"status": NOT_COMPARABLE, "reason": "not comparable on a side of this diff (comparison.json overlay)"}
OVERLAY_REF = "refs/oracle-overlay/"
TRAILERS = {"Oracle-Overlay-Base": "base", "Oracle-Overlay-Head": "head", "Oracle-Overlay-Product": "product",
            "Oracle-Overlay-Mode": "mode"}
IDENTITY = {
    "GIT_AUTHOR_NAME": "cmux oracle overlay",
    "GIT_AUTHOR_EMAIL": "oracle-overlay@cmux.invalid",
    "GIT_COMMITTER_NAME": "cmux oracle overlay",
    "GIT_COMMITTER_EMAIL": "oracle-overlay@cmux.invalid",
}
STDERR_TAIL = 600


class OverlayError(Exception):
    """A ref, product or repository that overlay.py cannot work with (bad input, exit 2)."""


class GitError(OverlayError):
    def __init__(self, args: Sequence[str], code: int, stderr: str) -> None:
        super().__init__(f"git {' '.join(args)} exited {code}: {stderr.strip()[-STDERR_TAIL:]}")


def _under(path: str, prefixes: Iterable[str]) -> bool:
    return any(path == p or (p.endswith("/") and path.startswith(p)) for p in prefixes)


def runner(path: str) -> bool:
    return _under(path, RUNNER)


def in_scope(product: str, path: str) -> bool:
    """A file the product's build reads. Prose (Markdown) never builds, so it never blocks an overlay."""
    include, exclude = SCOPES[product]
    return (not include or _under(path, include)) and not _under(path, exclude) and not path.endswith(".md")


@dataclass(frozen=True)
class Git:
    repo: Path
    env: Mapping[str, str] = field(default_factory=dict)

    def run(self, *args: str, input: Optional[bytes] = None, check: bool = True,
            env: Optional[Mapping[str, str]] = None) -> "subprocess.CompletedProcess[bytes]":
        merged = {**os.environ, **self.env, **(env or {})}
        proc = subprocess.run(["git", "-C", str(self.repo), *args], input=input, env=merged,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if check and proc.returncode != 0:
            raise GitError(args, proc.returncode, proc.stderr.decode("utf-8", "replace"))
        return proc

    def text(self, *args: str, **kwargs: Any) -> str:
        return self.run(*args, **kwargs).stdout.decode("utf-8", "replace")

    def commit(self, ref: str) -> str:
        proc = self.run("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}", check=False)
        if proc.returncode != 0:
            raise OverlayError(f"unknown commit {ref!r} in {self.repo}")
        return proc.stdout.decode().strip()

    def paths(self, *args: str) -> List[str]:
        """NUL-separated path output (`-z`) as a list."""
        return [p.decode("utf-8", "surrogateescape") for p in self.run(*args).stdout.split(b"\0") if p]


# ---------------------------------------------------------------------------------------------------------
# v0 facets


def v0_not_comparable(product: str) -> List[Dict[str, str]]:
    """Facets and facet fields a v0 run cannot give on `product`: facets_v0.py's schema against v1."""
    if str(HERE) not in sys.path:
        sys.path.insert(0, str(HERE))
    import facets_v0  # sibling; imported here so native and overlay plans need no schema

    # The VM products are cmux-tui sessions: their state facet is the daemon's.
    state = "daemon" if SCOPES.get(product) == VM_SCOPE else product
    if state not in facets_v0.PRODUCT_FACETS:
        raise OverlayError(f"--product {product}: v0 facets exist for {sorted(facets_v0.PRODUCT_FACETS)} only")
    try:
        v1 = facets_v0.load_v1()
        v0 = facets_v0.derive_schema(v1)
    except (OSError, ValueError, facets_v0.V0Error) as error:
        raise OverlayError(f"no v0 schema (facets_v0.py): {error}") from None
    old, new = (doc["properties"]["facets"]["properties"] for doc in (v1, v0))
    entries: List[Dict[str, str]] = []
    for name in sorted(old):
        if name in facets_v0.STEP_RECEIPTS:
            continue
        task = old[name].get("x-oracle-source", {}).get("task")
        if name not in facets_v0.FIELDS:
            entries.append(_entry(name, "no push-base method gives it (facets_v0.FIELDS)", task))
            continue
        if name not in facets_v0.PRODUCT_FACETS[state]:
            entries.append(_entry(name, f"the {product} product has no v0 {name} state", task))
            continue
        kept = set(_object_properties(new[name], v0))
        for key in sorted(set(_object_properties(old[name], v1)) - kept):
            entries.append(_entry(f"{name}/{key}", "no push-base method gives it (facets_v0.FIELDS)", task))
    return entries


def _object_properties(spec: Mapping[str, Any], doc: Mapping[str, Any]) -> Mapping[str, Any]:
    for variant in spec.get("oneOf", [spec]):
        if "$ref" in variant:
            variant = doc.get("definitions", {}).get(variant["$ref"].rsplit("/", 1)[-1], {})
        if "properties" in variant and "status" not in variant["properties"]:
            return variant["properties"]
    return {}


def _entry(facet: str, reason: str, task: Optional[str]) -> Dict[str, str]:
    entry = {"facet": facet, "reason": reason}
    if task:
        entry["task"] = task
    return entry


# ---------------------------------------------------------------------------------------------------------
# prepare


def oracle_commits(git: Git, base: str, head: str) -> List[Tuple[str, str]]:
    """Head's oracle commits that the base lacks, parents first."""
    out = git.text("log", "--reverse", "--topo-order", "--no-merges", "--format=%H%x00%s", f"{base}..{head}")
    commits = []
    for line in out.splitlines():
        sha, _, subject = line.partition("\0")
        if ORACLE_SUBJECT.search(subject):
            commits.append((sha, subject))
    return commits


def apply_failure(stderr: str) -> str:
    """`git apply` stderr cut to what failed: the conflicted paths (`U path`) and the error lines."""
    lines = stderr.splitlines()
    conflicts = [line[2:].strip() for line in lines if line.startswith("U ")]
    errors = [line.strip() for line in lines if line.startswith("error:")]
    if conflicts:
        return "conflicts in " + ", ".join(conflicts[:10])
    return "; ".join(errors[:5]) or stderr.strip()[-STDERR_TAIL:]


def non_additive(git: Git, base_tree: str, tree: str) -> List[str]:
    """Files outside RUNNER that the overlay deletes, changes in binary, or removes lines from."""
    problems = []
    for row in git.paths("diff-tree", "-r", "-z", "--no-renames", "--numstat", base_tree, tree):
        added, removed, path = row.split("\t", 2)
        if runner(path):
            continue
        if removed == "-":
            problems.append(f"{path}: binary change")
        elif int(removed) > 0:
            problems.append(f"{path}: {removed} removed lines")
    status = git.paths("diff-tree", "-r", "-z", "--no-renames", "--name-status", "--diff-filter=DT", base_tree, tree)
    for kind, path in zip(status[0::2], status[1::2]):
        if not runner(path):
            problems.append(f"{path}: {'deleted' if kind == 'D' else 'type changed'}")
    return sorted(set(problems))


def prepare(repo: Path, base: str, head: str, *, product: str = "daemon",
            force_v0: Optional[str] = None) -> Dict[str, Any]:
    if product not in SCOPES:
        raise OverlayError(f"--product {product}: one of {sorted(SCOPES)}")
    git = Git(repo)
    base_sha, head_sha = git.commit(base), git.commit(head)
    plan: Dict[str, Any] = {"schema": SCHEMA, "task": TASK, "product": product, "base": base_sha, "head": head_sha,
                            "commits": [], "applied": [], "files": [], "notComparable": []}
    commits = oracle_commits(git, base_sha, head_sha)
    plan["commits"] = [{"sha": sha, "subject": subject} for sha, subject in commits]
    if force_v0:
        return _v0(git, plan, force_v0)
    base_tree = git.text("rev-parse", f"{base_sha}^{{tree}}").strip()
    with tempfile.TemporaryDirectory(prefix="oracle-overlay-") as scratch:
        index = Git(repo, {"GIT_INDEX_FILE": str(Path(scratch) / "index")})
        index.run("read-tree", base_sha)
        for sha, subject in commits:
            files = [p for p in git.paths("diff-tree", "-r", "-z", "--no-commit-id", "--no-renames", "--name-only",
                                          f"{sha}^", sha)
                     if in_scope(product, p) and not runner(p)]
            if not files:
                continue
            # Plumbing: porcelain diff settings (noprefix, external drivers) cannot change the patch.
            patch = git.run("diff-tree", "-p", "--full-index", "--binary", "--no-renames", f"{sha}^", sha,
                            "--", *files).stdout
            applied = index.run("apply", "--cached", "--3way", "--whitespace=nowarn", input=patch, check=False)
            if applied.returncode != 0:
                why = apply_failure(applied.stderr.decode("utf-8", "replace"))
                return _v0(git, plan, f"git apply --3way of {sha[:12]} ({subject}) failed after "
                                      f"{len(plan['applied'])} applied commits: {why}")
            plan["applied"].append(sha)
        if product in RUNNER_IN_TREE:
            _take_runner(index, head_sha)
        tree = index.text("write-tree").strip()
    plan["files"] = git.paths("diff-tree", "-r", "-z", "--no-renames", "--name-only", base_tree, tree)
    if tree == base_tree:
        return {**plan, "mode": "native", "facets": "v1", "buildSha": base_sha}
    problems = non_additive(git, base_tree, tree)
    if problems:
        return _v0(git, plan, "the overlay is not additive outside the runner: " + "; ".join(problems[:10]))
    overlay = _commit(git, tree, plan, "overlay")
    return {**plan, "mode": "overlay", "facets": "v1", "buildSha": overlay, "overlaySha": overlay}


def _take_runner(index: Git, head_sha: str) -> None:
    """RUNNER in the scratch index becomes head's exactly. --index-info only: it needs no work tree (a bare repo)."""
    stale = index.paths("ls-files", "-z", "--", *RUNNER)
    if stale:
        removals = b"".join(f"0 {'0' * 40}\t{path}".encode("utf-8", "surrogateescape") + b"\0" for path in stale)
        index.run("update-index", "-z", "--index-info", input=removals)
    ours = index.run("ls-tree", "-r", "-z", "--full-tree", head_sha, "--", *RUNNER).stdout
    if ours:
        index.run("update-index", "-z", "--index-info", input=ours)


def _commit(git: Git, tree: str, plan: Mapping[str, Any], mode: str) -> str:
    base, head = plan["base"], plan["head"]
    # Head's commit time keeps the SHA a function of base, head and product alone.
    when = git.text("show", "-s", "--format=%ct", head).strip() + " +0000"
    lines = [f"oracle overlay: head {head[:12]}'s oracle on base {base[:12]} ({plan['product']}, {mode})", "",
             f"Oracle-Overlay-Base: {base}", f"Oracle-Overlay-Head: {head}",
             f"Oracle-Overlay-Product: {plan['product']}", f"Oracle-Overlay-Mode: {mode}"]
    lines += [f"Oracle-Overlay-Commit: {sha}" for sha in plan["applied"]]
    env = {**IDENTITY, "GIT_AUTHOR_DATE": when, "GIT_COMMITTER_DATE": when}
    sha = git.text("commit-tree", "--no-gpg-sign", tree, "-p", base, "-F", "-",
                   input=("\n".join(lines) + "\n").encode(), env=env).strip()
    git.run("update-ref", OVERLAY_REF + sha, sha)
    return sha


def _v0(git: Git, plan: Dict[str, Any], reason: str) -> Dict[str, Any]:
    """Both sides on v0 facets. The base builds alone, unless its build's checkout runs the runner: then head's
    runner goes onto the base (RUNNER only, so the product is the base's exactly)."""
    out = {**plan, "mode": "v0", "facets": "v0", "buildSha": plan["base"], "applied": [], "files": [],
           "reason": reason, "notComparable": v0_not_comparable(plan["product"])}
    if plan["product"] not in RUNNER_IN_TREE:
        return out
    base_tree = git.text("rev-parse", f"{plan['base']}^{{tree}}").strip()
    with tempfile.TemporaryDirectory(prefix="oracle-overlay-") as scratch:
        index = Git(git.repo, {"GIT_INDEX_FILE": str(Path(scratch) / "index")})
        index.run("read-tree", plan["base"])
        _take_runner(index, plan["head"])
        tree = index.text("write-tree").strip()
    if tree == base_tree:
        return out
    out["files"] = git.paths("diff-tree", "-r", "-z", "--no-renames", "--name-only", base_tree, tree)
    sha = _commit(git, tree, out, "v0")
    return {**out, "buildSha": sha, "overlaySha": sha}


def describe(repo: Path, sha: str) -> Optional[Dict[str, Any]]:
    """The overlay trailers of a commit (base, head, product, mode, applied), or None for any other commit."""
    git = Git(repo)
    body = git.text("show", "-s", "--format=%B", git.commit(sha))
    found: Dict[str, Any] = {}
    applied: List[str] = []
    for line in body.splitlines():
        key, sep, value = line.partition(": ")
        if not sep:
            continue
        if key in TRAILERS:
            found[TRAILERS[key]] = value.strip()
        elif key == "Oracle-Overlay-Commit":
            applied.append(value.strip())
    if not {"base", "head"} <= set(found):
        return None
    return {"overlaySha": git.commit(sha), **found, "applied": applied}


def push(repo: Path, remote: str, plan: Dict[str, Any]) -> Dict[str, Any]:
    """Publishes the overlay commit for a fleet build; the branch is named by the SHA, so it never moves."""
    sha = plan.get("overlaySha")
    if not sha:
        return plan
    ref = f"refs/heads/oracle-overlay/{sha}"
    Git(repo).run("push", "--quiet", remote, f"{sha}:{ref}")
    return {**plan, "pushedRef": ref}


def summary(plan: Mapping[str, Any]) -> Dict[str, Any]:
    """The plan fields a comparison receipt names: what the base side built and which facets it compared."""
    keys = ("product", "mode", "facets", "base", "head", "buildSha", "overlaySha", "reason", "applied")
    return {key: plan[key] for key in keys if key in plan}


def load_plan(path: Path) -> Dict[str, Any]:
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise OverlayError(f"{path}: not a readable overlay plan: {error}") from None
    if not isinstance(plan, dict) or plan.get("schema") != SCHEMA or plan.get("mode") not in ("native", "overlay", "v0"):
        raise OverlayError(f"{path}: not a {SCHEMA} plan")
    return plan


# ---------------------------------------------------------------------------------------------------------
# Masking not-comparable facets before diff.py


@dataclass
class MaskResult:
    a_dir: Path
    b_dir: Path
    # facet path -> the first reason it was not comparable
    facets: Dict[str, str]
    # case -> why it has no comparable facet left (Skip on both sides)
    cases: Dict[str, str]


def _read_rows(run: Path) -> List[Dict[str, Any]]:
    with (run / "checkpoints.jsonl").open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def _facets(snapshot: Any) -> Optional[Dict[str, Any]]:
    facets = snapshot.get("facets") if isinstance(snapshot, dict) else None
    return facets if isinstance(facets, dict) else None


def _is_marker(value: Any) -> bool:
    return isinstance(value, dict) and value.get("status") == NOT_COMPARABLE


def _row_entries(row: Mapping[str, Any]) -> Iterator[Tuple[str, str]]:
    for name, value in sorted((_facets(row.get("snapshot")) or {}).items()):
        if _is_marker(value):
            yield name, str(value.get("reason") or NOT_COMPARABLE)
    for name in row.get("notComparable") or ():
        yield str(name), "the driver marked it not comparable"


def _parent(facets: Dict[str, Any], path: str) -> Tuple[Optional[Dict[str, Any]], str]:
    parts = path.split("/")
    target: Any = facets
    for part in parts[:-1]:
        target = target.get(part) if isinstance(target, dict) else None
    return (target if isinstance(target, dict) else None), parts[-1]


def _present(snapshots: Sequence[Any], path: str) -> bool:
    for snapshot in snapshots:
        facets = _facets(snapshot)
        parent, key = _parent(facets, path) if facets is not None else (None, "")
        if parent is not None and key in parent:
            return True
    return False


def _mask(snapshot: Any, path: str) -> None:
    facets = _facets(snapshot)
    if facets is None:
        return
    parent, key = _parent(facets, path)
    if parent is not None:
        parent[key] = dict(MARKER)


def _covered(path: str, others: Set[str]) -> bool:
    """True when a shorter path in `others` already masks all of `path`."""
    parts = path.split("/")
    return any("/".join(parts[:n]) in others for n in range(1, len(parts)))


def mask_runs(a_dir: Path, b_dir: Path, out: Path, plan_entries: Sequence[Mapping[str, str]] = ()) -> MaskResult:
    """Masked copies of two run directories (receipt.json and checkpoints.jsonl) in out/a and out/b.

    `plan_entries` ({"facet", "reason"}) apply to every checkpoint of both sides: the plan's v0 list.
    """
    rows = {"a": _read_rows(a_dir), "b": _read_rows(b_dir)}
    receipts = {side: json.loads((d / "receipt.json").read_text(encoding="utf-8"))
                for side, d in (("a", a_dir), ("b", b_dir))}
    plan_level = [(str(e["facet"]), f"plan: {e.get('reason', NOT_COMPARABLE)}") for e in plan_entries]
    by_key: Dict[Tuple[str, int, str], Dict[str, str]] = {}
    snapshots: Dict[Tuple[str, int, str], List[Any]] = {}
    for side, side_rows in rows.items():
        for row in side_rows:
            key = (row["case"], int(row["index"]), row["checkpoint"])
            snapshots.setdefault(key, []).append(row.get("snapshot"))
            entries = by_key.setdefault(key, {})
            for name, reason in [*plan_level, *((n, f"{side}: {r}") for n, r in _row_entries(row))]:
                entries.setdefault(name, reason)
    facets: Dict[str, str] = {}
    comparable: Dict[str, bool] = {}
    masked: Dict[str, List[Dict[str, Any]]] = {"a": [], "b": []}
    for side, side_rows in rows.items():
        for row in side_rows:
            key = (row["case"], int(row["index"]), row["checkpoint"])
            entries = by_key[key]
            paths = [p for p in sorted(entries) if not _covered(p, set(entries)) and _present(snapshots[key], p)]
            row = copy.deepcopy(row)
            for path in paths:
                _mask(row.get("snapshot"), path)
                facets.setdefault(path, entries[path])
            if paths:
                row.pop("sha256", None)
            values = _facets(row.get("snapshot"))
            left = values is None or any(not _is_marker(v) for v in values.values())
            comparable[row["case"]] = comparable.get(row["case"], False) or left
            masked[side].append(row)
    cases: Dict[str, str] = {}
    for case, left in sorted(comparable.items()):
        results = [receipts[s].get("cases", {}).get(case, {}).get("result") for s in ("a", "b")]
        if not left and results[0] == results[1] and results[0] not in ("Flaky", "Skip"):
            cases[case] = "no comparable facet in any checkpoint (result " + str(results[0]) + " on both sides)"
    targets = {"a": out / "a", "b": out / "b"}
    for side, target in targets.items():
        if target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True)
        receipt = copy.deepcopy(receipts[side])
        for case, reason in cases.items():
            entry = receipt.setdefault("cases", {}).setdefault(case, {})
            entry.update(result="Skip", notComparable=reason)
        (target / "receipt.json").write_text(json.dumps(receipt, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        with (target / "checkpoints.jsonl").open("w", encoding="utf-8") as handle:
            for row in masked[side]:
                handle.write(json.dumps(row, sort_keys=True) + "\n")
    return MaskResult(targets["a"], targets["b"], dict(sorted(facets.items())), cases)


# ---------------------------------------------------------------------------------------------------------
# CLI


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="overlay.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare", help="the base build of a base/head diff: overlay commit, native or v0")
    prep.add_argument("--base", required=True)
    prep.add_argument("--head", required=True)
    prep.add_argument("--product", default="daemon", choices=sorted(SCOPES))
    prep.add_argument("--repo", type=Path, default=REPO)
    prep.add_argument("--v0", metavar="REASON", help="no overlay: both sides run v0 facets, for this reason")
    prep.add_argument("--push", metavar="REMOTE", help="push an overlay commit to refs/heads/oracle-overlay/<sha>")
    prep.add_argument("--out", type=Path)
    desc = sub.add_parser("describe", help="the overlay trailers of a commit as JSON (null for any other commit)")
    desc.add_argument("sha")
    desc.add_argument("--repo", type=Path, default=REPO)
    nc = sub.add_parser("not-comparable", help="the facets and fields a v0 run cannot give")
    nc.add_argument("--product", default="daemon")
    args = parser.parse_args(argv)
    try:
        if args.command == "not-comparable":
            print(json.dumps(v0_not_comparable(args.product), indent=1))
            return 0
        if args.command == "describe":
            print(json.dumps(describe(args.repo, args.sha), sort_keys=True))
            return 0
        plan = prepare(args.repo, args.base, args.head, product=args.product, force_v0=args.v0)
        if args.push:
            plan = push(args.repo, args.push, plan)
    except OverlayError as error:
        print(f"overlay.py: {error}", file=sys.stderr)
        return 2
    text = json.dumps(plan, indent=1, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        tmp = args.out.with_name(args.out.name + ".tmp")
        tmp.write_text(text, encoding="utf-8")
        tmp.replace(args.out)
    sys.stdout.write(text)
    detail = plan.get("overlaySha") or plan.get("reason") or plan["buildSha"]
    print(f"overlay.py: {plan['product']} {plan['mode']} ({plan['facets']} facets): {detail}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

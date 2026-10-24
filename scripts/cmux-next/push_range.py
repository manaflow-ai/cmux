#!/usr/bin/env python3
"""What a push adds: the one definition prepush-gate.py, guardrails.py and arch-ratchet.py share.

A pushed ref's own changes are those of the commits the remote does not have yet. The push knows two
commits the remote has: the ref's remote head (pre-push stdin, or a --base) and origin/feat-cmux-next
(the shared base every branch rebases onto or merges in). So

    own commits = git rev-list HEAD --not <remote head> origin/feat-cmux-next
    bases       = the boundary of that walk (the parents of own commits that are not own themselves),
                  less any that is an ancestor of another (git merge-base --independent)

and a finding (a scanner record, a guardrail hit, an arch count rise) is the push's own only when it is new
over EVERY base. The cases:
- a second push of N new commits: the base is the remote head, so all N are judged and nothing pushed before.
- rebased onto origin/feat-cmux-next and force pushed: the base is where HEAD meets origin/feat-cmux-next. The
  rebased commits are new commits and are judged in full; the upstream commits the rebase brought in are not.
- origin/feat-cmux-next merged in: two bases, the old remote head's side and the merged upstream commit. A
  finding counts only when it is new over both: the merge's own resolution and the commits since the last push
  count; upstream's lines and what the branch pushed before do not.
- the first push of a new branch: the base is where HEAD meets origin/feat-cmux-next.
- every pushed commit is already known: no own change (the base is HEAD itself).
The bases are ordered with the remote head's side first and origin/feat-cmux-next's side last (guardrails
prints a merge's advisory warnings over the last one: the branch's own range). A base named on the command line
(`--base A`) is used as given (given_range): the caller chose the range.

Fallbacks (the note says which, and the gate prints it):
- neither a remote head nor origin/feat-cmux-next is known (a first push from a clone that never fetched that
  ref, or that names the remote otherwise): HEAD~1, so only the last commit is judged.
- the own commits reach a root commit (history unrelated to the remote): HEAD~1 as well.

Limit: the bound is the remote head and THIS CLONE's origin/feat-cmux-next ref, not every commit the remote
has. A rebase onto a base that ref does not reach (`git fetch <url> feat-cmux-next && git rebase FETCH_HEAD`,
a rebase onto a sha or another remote's ref, a branch stacked on another rebased topic) counts the upstream
commits between that ref and the new base as the push's own; the gate prints the commit count, so a wide range
shows, and `git fetch origin` fixes it. Not bounded by every remote-tracking ref (`--not --remotes`): listing
them cost about 3 s per push in a clone with 15k loose remote refs (measured 2026-10-24).
"""
from __future__ import annotations

import dataclasses
import os
import subprocess
from pathlib import Path

UPSTREAM = "origin/feat-cmux-next"
ZERO_SHA = "0" * 40


@dataclasses.dataclass(frozen=True)
class OwnRange:
    """One pushed head and the bases its own changes are new over (see the module docstring)."""

    head: str
    bases: tuple[str, ...]
    commits: int  # how many commits are the push's own (0 for a fallback or nothing new)
    note: str  # how the bases were chosen, for the report

    def pairs(self) -> list[tuple[str, str]]:
        """(base, head) for every base: a finding counts only when every pair has it."""
        return [(base, self.head) for base in self.bases]

    def describe(self) -> str:
        """One report line: the head, the bases and how they were chosen."""
        bases = ", ".join(b[:11] for b in self.bases)
        return f"{self.head[:11]} over {bases}: {self.note}"


def _git(repo: Path, *args: str) -> tuple[int, str]:
    # A hook runs with git's GIT_INDEX_FILE / GIT_WORK_TREE for the pushing checkout: never let them reach a
    # read of another tree.
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, env=env)
    return result.returncode, result.stdout.strip()


def commit_of(repo: Path, rev: str) -> str | None:
    """The full sha of commit REV, or None when this clone has no such commit."""
    if not rev or rev == ZERO_SHA:
        return None
    code, out = _git(repo, "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}")
    return out if code == 0 and out else None


def _fallback(repo: Path, head: str, why: str) -> OwnRange:
    parent = commit_of(repo, f"{head}~1")
    if parent is None:
        return OwnRange(head, (head,), 0, f"{why}; a root commit, nothing judged")
    return OwnRange(head, (parent,), 1, f"{why}; only the last commit is judged")


def own_range(repo: Path, head: str, known: list[str] | tuple[str, ...] = (),
              upstream_ref: str = UPSTREAM) -> OwnRange:
    """The push's own range for HEAD, given KNOWN commits the remote has (its remote head) and UPSTREAM_REF.

    Raises ValueError when HEAD or a KNOWN revision is not a commit of this clone (the caller leaves out a remote
    head it does not have).
    """
    tip = commit_of(repo, head)
    if tip is None:
        raise ValueError(f"no commit {head}")
    negatives: list[str] = []
    for rev in known:
        sha = commit_of(repo, rev)
        if sha is None:
            raise ValueError(f"no commit {rev}")
        if sha not in negatives:
            negatives.append(sha)
    upstream = commit_of(repo, upstream_ref)
    if upstream is not None and upstream not in negatives:
        negatives.append(upstream)
    if not negatives:
        return _fallback(repo, tip, f"no remote head and no {upstream_ref} in this clone")
    code, out = _git(repo, "rev-list", "--boundary", tip, "--not", *negatives)
    if code != 0:
        raise ValueError(f"git rev-list --boundary {tip} --not {' '.join(negatives)} failed")
    lines = out.split()
    own = [line for line in lines if not line.startswith("-")]
    edge = list(dict.fromkeys(line[1:] for line in lines if line.startswith("-")))
    if not own:
        return OwnRange(tip, (tip,), 0, "every pushed commit is already on the remote or on " + upstream_ref)
    if not edge:
        return _fallback(repo, tip, f"its {len(own)} commit(s) share no history with the remote")
    if len(edge) > 1:
        code, out = _git(repo, "merge-base", "--independent", *edge)
        independent = set(out.split()) if code == 0 and out else set(edge)
        edge = [sha for sha in edge if sha in independent]
    if len(edge) > 1 and upstream is not None:
        # The remote head's side first, upstream's side last (a stable sort keeps git's order otherwise).
        edge.sort(key=lambda sha: _is_ancestor(repo, sha, upstream))
    how = "a merge: a finding counts only when it is new over every base" if len(edge) > 1 else "the push's own"
    return OwnRange(tip, tuple(edge), len(own), f"{len(own)} own commit(s), {how}")


def given_range(repo: Path, base: str, head: str) -> OwnRange:
    """Exactly BASE..HEAD, for a caller that names the base itself (`--base A --head B`: CI's pull request run
    judges what the PR merge adds over HEAD^1, nothing else). Raises ValueError for a revision that is not a
    commit of this clone."""
    tip, start = commit_of(repo, head), commit_of(repo, base)
    if tip is None or start is None:
        raise ValueError(f"no commit {head if tip is None else base}")
    code, out = _git(repo, "rev-list", "--count", f"{start}..{tip}")
    return OwnRange(tip, (start,), int(out) if code == 0 and out.isdigit() else 0, "the base given")


def _is_ancestor(repo: Path, ancestor: str, descendant: str) -> bool:
    return _git(repo, "merge-base", "--is-ancestor", ancestor, descendant)[0] == 0


def as_own_ranges(repo: Path, items, upstream_ref: str = UPSTREAM) -> list[OwnRange]:
    """ITEMS as own ranges: an own range (anything with `head` and `bases`, from another load of this module)
    stays; a (base, head) pair is a push whose remote head is BASE (own_range(HEAD, [BASE]))."""
    out = []
    for item in items:
        if hasattr(item, "bases") and hasattr(item, "head"):
            out.append(item)
        else:
            base, head = item
            out.append(own_range(repo, head, [base], upstream_ref))
    return out

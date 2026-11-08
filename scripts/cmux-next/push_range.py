#!/usr/bin/env python3
"""What a push adds: the one definition prepush-gate.py, guardrails.py, arch-ratchet.py and web_lint_prepush.py share.

A pushed ref's own changes are those of the commits the remote does not have yet. The push knows commits the
remote has: the ref's remote head (pre-push stdin, or a --base), the remote-tracking ref of the pushed ref name
(refs/remotes/<remote>/<name>: the last head this clone saw there), this clone's origin/feat-cmux-next (the shared
base every branch rebases onto or merges in), the remote's HEAD (refs/remotes/<remote>/HEAD, main: a main-based
branch, a tag on main), and the integration branch the pushed branch was cut from:
- its configured upstream (`<branch>@{upstream}`), when that is a remote-tracking ref of the pushed remote:
  `git worktree add -b topic origin/perf/chrome-parity` and `git checkout -b topic origin/x` record it, so it
  names any long-lived branch;
- the known integration refs (INTEGRATION_REFS: origin/perf/chrome-parity, origin/main), for a branch cut with
  --no-track or whose upstream `git push -u` has since moved to its own name. A new long-lived integration branch
  gets an entry in INTEGRATION_REFS, so a branch cut from it without an upstream is not judged over all of it;
- each ref in this clone's `git config --get-all cmux.prepushExtraUpstream` (a long-lived shared branch that task
  branches merge in; none when unset), under the same rules as the upstream.
Every one of them is only another `--not` of the walk below, so no rule picks among them: git stops the walk at
the first commit any of them reaches, which is the nearest integration branch by history, the fact of where the
branch left it (2026-10-29: a branch cut from perf, 9,426 commits ahead of feat-cmux-next, was judged over all of
them and refused for debt in files it never touched). None of them may hide a commit nobody pushed: an upstream
counts only when it is a remote-tracking ref of the pushed remote (not a local branch, not another remote's such
as a contributor's fork, none for a push to a URL), and a ref this clone lacks bounds nothing. A push onto an
integration branch itself (refs/heads/feat-cmux-next, perf/chrome-parity, main) adds none of them, so landing
perf onto feat-cmux-next is judged over feat-cmux-next as before (and the compile trailer rule sees its Swift).
With none of them nearer, the base is where HEAD meets origin/feat-cmux-next, as before. So

    own commits = git rev-list HEAD --not <those refs>
    edges       = the boundary of that walk (the parents of own commits that are not own themselves),
                  less any that is an ancestor of another (git merge-base --independent)

One edge is the base, and the push's own findings are those of base..HEAD:
- a second push of N new commits: the remote head, so all N are judged and nothing pushed before;
- a new branch, or a branch rebased onto origin/feat-cmux-next and force pushed: where HEAD meets it, so the
  rebased commits are judged in full and the upstream commits the rebase brought in are not;
- a new branch cut from origin/perf/chrome-parity (or tracking another remote branch): where HEAD left it, so
  only the branch's own commits are judged, not what that branch has over origin/feat-cmux-next;
- every pushed commit already known: HEAD itself (nothing is new).

Several edges (a branch that merged origin/feat-cmux-next in): the base is the edge on the shared side (an
ancestor of origin/feat-cmux-next, else of the remote's HEAD, else of the branch's upstream or an integration ref),
so base..HEAD is the branch's whole delta over the upstream it merged. Each other edge X (the old remote head, or
another merged base) gives a range the push does not own, merge-base(X, base)..X: what X's side already had over
the upstream it started from. The push's own findings are those of base..HEAD less those of every such range
(less(); a count: own_count()). Both are measured from upstream, so upstream's own changes are in neither: an
upstream removal of a debt line never pays for a line the branch adds (as a count ratchet per file over the old
remote head would let it), and an upstream addition is never the push's. What the branch pushed before is in both
and cancels; the merge's resolution and every new commit count.

Fallbacks:
- none of those refs is in the clone (a first push from a single-branch clone, a remote named otherwise), or the
  walk reaches a shallow root or a root commit before any of them: the walk is bounded again by every ref of the
  pushed remote (`--not --remotes=<remote>`, about 5 s in a clone with 21k remote refs, so only on this path);
- that bound gives no edge either, or the walk still reaches a shallow root: own_range raises ValueError (the
  caller refuses the push and says to fetch or unshallow). It never judges HEAD~1 alone.

Limit: a branch stacked on another pushed topic that it does not track counts that topic's commits as its own
(only the fallback bounds by every remote ref); the gate prints the own-commit count, and the integration ref
the branch was cut from when that is not origin/feat-cmux-next, so a wide range shows. A base named on the
command line (`--base A`) is used as given (given_range), whatever the branch tracks.
"""
from __future__ import annotations

import collections
import dataclasses
import hashlib
import os
import re
import subprocess
from pathlib import Path

UPSTREAM = "origin/feat-cmux-next"
# Long-lived integration branches with their own merge trains (see the module docstring): a branch cut from one
# is judged over where it left it, even with no upstream configured. Add a new one here.
INTEGRATION_REFS = ("origin/perf/chrome-parity", "origin/main")
DEFAULT_REMOTE = "origin"
ZERO_SHA = "0" * 40


@dataclasses.dataclass(frozen=True)
class OwnRange:
    """One pushed head, the base its own changes are measured from, and the ranges it does not own.

    The push owns what base..head adds less what every BEFORE range (b, a) adds (see the module docstring).
    """

    head: str
    base: str
    before: tuple[tuple[str, str], ...] = ()
    commits: int = 0  # how many commits are the push's own (0 when nothing is new)
    note: str = ""  # how the base was chosen, for the report

    def ranges(self) -> list[tuple[str, str]]:
        """(base, head) first, then every range the push does not own."""
        return [(self.base, self.head), *self.before]

    def describe(self) -> str:
        """One report line: the head, the base, the ranges taken off and how they were chosen."""
        taken = "".join(f", less what {a[:11]} adds over {b[:11]}" for b, a in self.before)
        return f"{self.head[:11]} over {self.base[:11]}{taken}: {self.note}"


def less(found, before, key=lambda item: item) -> list:
    """FOUND (the findings over an own range's base..head) less the ones its BEFORE runs found, matched by KEY.

    Multisets: a key the BEFORE runs hold n times takes off n of FOUND's. The BEFORE runs add up (each is another
    side the push does not own). FOUND's order is kept.
    """
    taken: collections.Counter = collections.Counter()
    for items in before:
        taken.update(key(item) for item in items)
    out = []
    for item in found:
        k = key(item)
        if taken[k] > 0:
            taken[k] -= 1
        else:
            out.append(item)
    return out


def own_count(found: int, before) -> int:
    """A count over base..head less the counts over the BEFORE ranges: the push's own net rise."""
    return found - sum(before)


def _git(repo: Path, *args: str) -> tuple[int, str]:
    # A hook runs with git's GIT_INDEX_FILE / GIT_WORK_TREE for the pushing checkout: never let them reach a
    # read of another tree.
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, env=env)
    return result.returncode, result.stdout.strip()


def commit_of(repo: Path, rev: str | None) -> str | None:
    """The full sha of commit REV, or None when this clone has no such commit."""
    return commits_of(repo, [rev])[0]


def commits_of(repo: Path, revs: list[str | None]) -> list[str | None]:
    """commit_of for each of REVS in one `git rev-parse` (each git process costs ~0.1 s on a busy Mac); a rev that
    is not a commit of this clone, or that git cannot read in a batch, is asked alone."""
    asked = [r for r in dict.fromkeys(revs) if r and r != ZERO_SHA and not r.startswith("-")]
    found: dict[str, str | None] = {}
    if asked:
        code, out = _git(repo, "rev-parse", *[f"{r}^{{commit}}" for r in asked])
        lines = out.split("\n") if out else []
        if code == 0 and len(lines) == len(asked) and all(re.fullmatch(r"[0-9a-f]{40,64}", x) for x in lines):
            found = dict(zip(asked, lines))
        else:  # one of them is not a commit here: ask each (rare)
            for r in asked:
                code, one = _git(repo, "rev-parse", "--verify", "--quiet", f"{r}^{{commit}}")
                found[r] = one if code == 0 and one else None
    return [found.get(r) if r else None for r in revs]


def _is_ancestor(repo: Path, ancestor: str, descendant: str) -> bool:
    return _git(repo, "merge-base", "--is-ancestor", ancestor, descendant)[0] == 0


def remote_name(repo: Path, remote: str | None) -> str | None:
    """REMOTE when it names a configured remote of this clone (a push to a URL names none)."""
    if not remote:
        return None
    code, out = _git(repo, "config", "--get", f"remote.{remote}.url")
    return remote if code == 0 and out else None


def tracking_ref(repo: Path, remote: str, remote_ref: str) -> str | None:
    """The ref REMOTE's fetch refspecs map REMOTE_REF to (refs/heads/x -> refs/remotes/origin/x), or None."""
    code, out = _git(repo, "config", "--get-all", f"remote.{remote}.fetch")
    if code != 0:
        return None
    for spec in out.splitlines():
        spec = spec.strip().lstrip("+")
        if spec.startswith("^") or ":" not in spec:
            continue
        source, dest = spec.split(":", 1)
        if "*" not in source:
            if source == remote_ref:
                return dest
            continue
        prefix, suffix = source.split("*", 1)
        if remote_ref.startswith(prefix) and remote_ref.endswith(suffix) and len(remote_ref) >= len(prefix) + len(suffix):
            return dest.replace("*", remote_ref[len(prefix):len(remote_ref) - len(suffix)], 1)
    return None


def local_branch(repo: Path, local_ref: str | None) -> str | None:
    """LOCAL_REF as a local branch's full name (`refs/heads/topic` as pre-push stdin names it, or HEAD resolved),
    else None: a tag, a detached HEAD, a sha or an expression is no branch."""
    if not local_ref or local_ref.startswith("-") or re.fullmatch(r"[0-9a-f]{40,64}", local_ref):
        return None
    if not local_ref.startswith("refs/heads/"):
        code, local_ref = _git(repo, "rev-parse", "--quiet", "--symbolic-full-name", local_ref)  # HEAD -> refs/heads/x
        if code != 0 or not local_ref.startswith("refs/heads/"):
            return None
    return local_ref


def upstream_of(repo: Path, local_ref: str | None, remote: str | None) -> str | None:
    """The configured upstream of local branch LOCAL_REF (local_branch()) when it is a remote-tracking ref of REMOTE
    (refs/remotes/<remote>/...), else None: a local branch upstream (remote ".") or another remote's branch (a
    contributor's fork) holds commits REMOTE may not have, a push to a URL names no remote, and a tag, a detached
    HEAD or a sha has no upstream. (`<ref>@{upstream}` does not take a full ref name, so this reads for-each-ref's
    %(upstream).)"""
    local_ref = local_branch(repo, local_ref) if remote else None
    if local_ref is None:
        return None
    # The pattern also matches refs/heads/<name>/...: keep the row of LOCAL_REF itself.
    code, out = _git(repo, "for-each-ref", "--format=%(refname) %(upstream)", local_ref)
    rows = dict(line.split(" ", 1) for line in out.splitlines() if " " in line) if code == 0 else {}
    upstream = rows.get(local_ref, "")
    return upstream if upstream.startswith(f"refs/remotes/{remote}/") else None


def _full_ref(ref: str) -> str:
    """REF as a full ref name: `origin/x` -> `refs/remotes/origin/x`."""
    return ref if ref.startswith("refs/") else f"refs/remotes/{ref}"


def _cut_from_note(repo: Path, base: str, upstream_ref: str, cut_from: list[str], branch_upstream: str | None) -> str:
    """The report's note on where the branch was cut: the refs of CUT_FROM that hold BASE when UPSTREAM_REF does
    not (one `git for-each-ref --contains`), else "" (an ordinary feat-cmux-next branch reads as before)."""
    if not cut_from:
        return ""
    wanted = {_full_ref(ref): ref for ref in cut_from}
    code, out = _git(repo, "for-each-ref", f"--contains={base}", "--format=%(refname)", _full_ref(upstream_ref),
                     *wanted)
    holding = set(out.splitlines()) if code == 0 else set()
    if _full_ref(upstream_ref) in holding:
        return ""
    names = [ref.removeprefix("refs/remotes/") + (" (the branch's upstream)" if ref == branch_upstream else "")
             for full, ref in wanted.items() if full in holding]
    return f"; cut from {', '.join(names)}" if names else ""


def _shallow_roots(repo: Path) -> set[str]:
    """The commits whose parents this clone cuts off (.git/shallow), empty for a full clone."""
    code, out = _git(repo, "rev-parse", "--git-path", "shallow")
    if code != 0 or not out:
        return set()
    path = Path(out) if os.path.isabs(out) else Path(repo) / out
    try:
        return set(path.read_text().split())
    except OSError:
        return set()


WALK_CACHE_VERSION = "1"


def _walk_cache(repo: Path, key: str) -> Path | None:
    """<git common dir>/cmux-guardrails/push-range-<version>/<key>, or None (no cache: the walk runs)."""
    code, out = _git(repo, "rev-parse", "--git-common-dir")
    if code != 0 or not out:
        return None
    common = Path(out) if os.path.isabs(out) else Path(repo) / out
    return common / "cmux-guardrails" / f"push-range-{WALK_CACHE_VERSION}" / key


def _walk(repo: Path, tip: str, negatives: list[str], bound: str | None) -> tuple[list[str], list[str]]:
    """(own commits, boundary commits) of `git rev-list --boundary TIP --not NEGATIVES [BOUND]`.

    With no BOUND every input is a commit sha, and commits never change, so the answer is cached by them (lead
    2026-10-24: in a shallow clone git writes no commit-graph, and this walk took 0.5 s on a busy Mac; a retried or
    re-run push of the same head asks again). A BOUND (`--remotes...`) names refs that move, so it is never cached."""
    entry = None
    if bound is None and all(re.fullmatch(r"[0-9a-f]{40,64}", x) for x in [tip, *negatives]):
        key = hashlib.sha256(" ".join([tip, *sorted(negatives)]).encode()).hexdigest()
        entry = _walk_cache(repo, key)
        try:
            lines = entry.read_text().split() if entry is not None and entry.is_file() else None
        except OSError:
            lines = None
        if lines is not None:
            own = [line for line in lines if not line.startswith("-")]
            edge = list(dict.fromkeys(line[1:] for line in lines if line.startswith("-")))
            return own, edge
    args = ["rev-list", "--boundary", tip, "--not", *negatives, *([bound] if bound else [])]
    code, out = _git(repo, *args)
    if code != 0:
        raise ValueError(f"`git {' '.join(args)}` failed")
    lines = out.split()
    if entry is not None:
        try:
            entry.parent.mkdir(parents=True, exist_ok=True)
            tmp = entry.with_name(entry.name + f".{os.getpid()}.tmp")
            tmp.write_text("\n".join(lines) + "\n")
            os.replace(tmp, entry)
        except OSError:
            pass
    own = [line for line in lines if not line.startswith("-")]
    edge = list(dict.fromkeys(line[1:] for line in lines if line.startswith("-")))
    return own, edge


def own_range(repo: Path, head: str, known: list[str] | tuple[str, ...] = (), upstream_ref: str = UPSTREAM,
              remote: str | None = DEFAULT_REMOTE, remote_ref: str | None = None,
              local_ref: str | None = None) -> OwnRange:
    """The push's own range for HEAD (see the module docstring).

    KNOWN are commits the remote has for the pushed ref (its remote head). REMOTE and REMOTE_REF (the pushed ref's
    name there, `refs/heads/topic`) add its remote-tracking ref and the remote's HEAD. UPSTREAM_REF is the shared
    base. LOCAL_REF (the pushed local branch, `refs/heads/topic`; HEAD itself when None) adds its upstream; the
    INTEGRATION_REFS are added too. Raises ValueError when HEAD or a KNOWN revision is not a commit of this clone
    (the caller leaves out a remote head it does not have), and when nothing the remote has bounds the pushed
    commits.
    """
    name = remote_name(repo, remote)
    shown = name or remote or DEFAULT_REMOTE
    tracked_ref = tracking_ref(repo, name, remote_ref) if name and remote_ref else None
    remote_head = f"refs/remotes/{name}/HEAD" if name else None
    integration = [upstream_ref, *INTEGRATION_REFS]
    # A push onto an integration branch itself is judged over that branch alone (see the module docstring).
    # The pushed ref names one (the hook), or, with no pushed ref (a manual run, the guardrails, the web lint), the
    # local branch does, so a manual run on feat-cmux-next reads what its push will.
    branches = {f"refs/heads/{ref.split('/', 1)[-1]}" for ref in integration}
    landing = (remote_ref in branches if remote_ref else local_branch(repo, local_ref or head) in branches) or (
        tracked_ref is not None and _full_ref(tracked_ref) in {_full_ref(ref) for ref in integration})
    known_refs = {_full_ref(ref) for ref in (upstream_ref, remote_head, tracked_ref) if ref}
    branch_upstream = None if landing else upstream_of(repo, local_ref or head, name)
    # `git config --add cmux.prepushExtraUpstream <ref>` names more integration branches (a long-lived branch on
    # the remote that task branches merge in). Each is a cut-from ref like the upstream: none on a push onto an
    # integration branch, and only a remote-tracking ref of the pushed remote, so none hides a commit nobody pushed.
    code, configured = _git(repo, "config", "--get-all", "cmux.prepushExtraUpstream")
    extra = [_full_ref(ref) for ref in (configured.split() if code == 0 else [])]
    extra = [ref for ref in extra if name and ref.startswith(f"refs/remotes/{name}/")]
    cut_from = [] if landing else list(dict.fromkeys(
        ref for ref in (branch_upstream, *INTEGRATION_REFS, *extra) if ref and _full_ref(ref) not in known_refs))
    # Every revision in one rev-parse (it was one each: 4 or more git processes per push).
    resolved = commits_of(repo, [head, *known, tracked_ref, upstream_ref, remote_head, *cut_from])
    tip, known_shas = resolved[0], resolved[1:1 + len(known)]
    tracked, upstream_sha, remote_head_sha = resolved[1 + len(known):4 + len(known)]
    cut_from_shas = resolved[4 + len(known):]
    if tip is None:
        raise ValueError(f"no commit {head}")
    pushed_before: list[str] = []  # commits the pushed ref had on the remote
    for rev, sha in zip(known, known_shas):
        if sha is None:
            raise ValueError(f"no commit {rev}")
        pushed_before.append(sha)
    if tracked is not None:
        pushed_before.append(tracked)
    shared = [sha for sha in (upstream_sha, remote_head_sha, *cut_from_shas) if sha is not None]
    negatives = list(dict.fromkeys(pushed_before + shared))
    present = [ref for ref, sha in zip(cut_from, cut_from_shas) if sha is not None]
    every_ref = f"--remotes={name}" if name else "--remotes"
    shallow = _shallow_roots(repo)
    bound = None if negatives else every_ref
    own, edge = _walk(repo, tip, negatives, bound)
    if own and bound is None and (not edge or shallow & set(own)):
        # Cut at a shallow root, or no history in common with the named refs: every ref of the remote bounds it.
        bound = every_ref
        own, edge = _walk(repo, tip, negatives, bound)
    how = ""
    if bound:
        why = (f"no remote head, tracking ref, {upstream_ref} or remote HEAD in this clone" if not negatives
               else "the walk did not meet those refs")
        how += f"; bounded by every {shown} ref ({why})"
    if not own:
        return OwnRange(tip, tip, (), 0, "every pushed commit is already on the remote" + how)
    if shallow & set(own):
        raise ValueError(f"this shallow clone has no commit the remote has below the {len(own)} pushed commit(s), so "
                         f"it cannot tell which are this push's own; run `git fetch --unshallow {shown}` (or `git "
                         f"fetch {shown} feat-cmux-next`) and push again")
    if not edge:
        raise ValueError(f"its {len(own)} commit(s) share no history with any {shown} ref in this clone, so nothing "
                         f"tells which are this push's own; run `git fetch {shown}` and push again")
    if len(edge) > 1:
        code, out = _git(repo, "merge-base", "--independent", *edge)
        independent = set(out.split()) if code == 0 and out else set(edge)
        edge = [sha for sha in edge if sha in independent]
    if len(edge) == 1:
        how = _cut_from_note(repo, edge[0], upstream_ref, present, branch_upstream) + how
        return OwnRange(tip, edge[0], (), len(own), f"{len(own)} own commit(s){how}")

    def side(sha: str) -> tuple[bool, ...]:
        # The base is on the shared side: upstream's first, then the remote HEAD's, then any side not pushed before.
        return tuple(not _is_ancestor(repo, sha, ref) for ref in shared) + (
            any(_is_ancestor(repo, sha, ref) for ref in pushed_before),)

    base = min(edge, key=side)  # min keeps git's order among equals
    how = _cut_from_note(repo, base, upstream_ref, present, branch_upstream) + how
    before = []
    for other in edge:
        if other == base:
            continue
        code, start = _git(repo, "merge-base", other, base)
        # A side with no history in common with the base is not taken off: all of it counts (fails closed).
        if code == 0 and start:
            before.append((start, other))
    return OwnRange(tip, base, tuple(before), len(own),
                    f"{len(own)} own commit(s), a merge: what HEAD adds over the upstream it merged, less what the "
                    f"other side already had{how}")


def given_range(repo: Path, base: str, head: str) -> OwnRange:
    """Exactly BASE..HEAD, for a caller that names the base itself (`--base A --head B`: CI's pull request run
    judges what the PR merge adds over HEAD^1, nothing else). Raises ValueError for a revision that is not a
    commit of this clone."""
    tip, start = commit_of(repo, head), commit_of(repo, base)
    if tip is None or start is None:
        raise ValueError(f"no commit {head if tip is None else base}")
    code, out = _git(repo, "rev-list", "--count", f"{start}..{tip}")
    return OwnRange(tip, start, (), int(out) if code == 0 and out.isdigit() else 0, "the base given")


def pushed_ranges(repo: Path, lines: list[str], remote: str | None = DEFAULT_REMOTE,
                  upstream_ref: str = UPSTREAM) -> tuple[list[OwnRange], list[str]]:
    """Pre-push stdin rows (`<local ref> <local sha> <remote ref> <remote sha>`) as (own ranges, errors).

    REMOTE is the hook's first argument (a remote name, or the URL of a push to a URL). A deletion or a tag of a
    tree or blob pushes no commit and is left out. A remote head this clone does not have (someone pushed since
    the last fetch) bounds nothing itself (the tracking ref still does); the note says so. A row whose own range
    cannot be told (own_range's ValueError) is an error line naming the ref: the caller refuses the push with it.
    """
    ranges, errors = [], []
    for line in lines:
        parts = line.split()
        if len(parts) != 4 or parts[1] == ZERO_SHA:
            continue  # a deletion pushes no code
        _local_ref, local_sha, pushed_ref, remote_sha = parts
        if commit_of(repo, local_sha) is None:
            continue  # a tag of a tree or blob pushes no commit to judge
        known = [remote_sha] if commit_of(repo, remote_sha) is not None else []
        try:
            own = own_range(repo, local_sha, known, upstream_ref, remote, pushed_ref, _local_ref)
        except ValueError as error:
            errors.append(f"{pushed_ref} ({local_sha[:11]}): {error}")
            continue
        if remote_sha != ZERO_SHA and not known:
            own = dataclasses.replace(own, note=own.note + f"; the remote head {remote_sha[:11]} is not in this "
                                                          "clone (git fetch), so it bounds nothing itself")
        ranges.append(own)
    return ranges, errors


def as_own_ranges(repo: Path, items, upstream_ref: str = UPSTREAM) -> list[OwnRange]:
    """ITEMS as own ranges: an own range (anything with `head`, `base` and `before`, from another load of this
    module) stays; a (base, head) pair is a push whose remote head is BASE (own_range(HEAD, [BASE]))."""
    out = []
    for item in items:
        if all(hasattr(item, name) for name in ("head", "base", "before")):
            out.append(item)
        else:
            base, head = item
            out.append(own_range(repo, head, [base], upstream_ref))
    return out

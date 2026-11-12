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

A push (pushed_ranges, the hook's path) first fetches the shared base (refresh_upstream): origin/feat-cmux-next is
only as new as this clone's last fetch of it, and a branch that merges a base newer than that (its stacked parent
fetched alone, `git fetch origin lane/parent`, after the parent merged feat-cmux-next) brought in feat-cmux-next
commits the walk then counted as its own. On 2026-11-11 a plain base merge on lane/workflow-jobs-parser (#40784) was
refused for release-notes/next/highlights/ios-screen-sharing-paste-image.md, a highlight feat-cmux-next had
(e877ee43879), not the branch. One fetch per push (every check of the hook calls this; the first fetches); a clone
without the ref is left to the fallbacks below, and a fetch that fails or runs past its limit is said in the report
and the stale copy bounds the walk as before.

Every other tool that measures "this branch's own change" from where HEAD meets a remote-tracking base has the same
bug, so it fetches the same way first: a run outside a push (the gate, the arch ratchet and the web lint run by
hand) takes manual_range, and a tool that takes a merge base itself calls refresh_base(repo, ref) before it
(affected tests and its replay, the Rust panic ratchet, gate-plan, build_class, the test-determinism scan,
codebase-health). 2026-11-12: these were the readers left after the pre-push fix; tests/test_stale_base_readers.py
pins each. One fetch per run, on the same 30 s limit; a ref that is not a remote-tracking ref of a configured remote
(a sha, a CI checkout's origin with no such refspec) is left alone, and nothing is fetched on GitHub Actions (each
workflow fetches the base it diffs against). Each tool loads this file by path, from its own tree, and calls
refresh_base.

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
import fcntl
import hashlib
import io
import os
import re
import shlex
import subprocess
import sys
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


UPSTREAM_FETCH_SECONDS = 30
UPSTREAM_REFRESH_FILE = "upstream-refresh"
# Never a credential prompt of any kind (cmux#41310 review: GIT_TERMINAL_PROMPT=0 alone left GIT_ASKPASS, core.askPass
# and SSH_ASKPASS free to open a window or wait out the limit): an empty GIT_ASKPASS stops git before core.askPass and
# SSH_ASKPASS (git takes the first one set, and runs none when it is empty), an empty SSH_ASKPASS with
# SSH_ASKPASS_REQUIRE=never stops ssh's own, BatchMode=yes makes ssh fail instead of asking, GCM_INTERACTIVE=never
# stops Git Credential Manager's window, and credential.interactive=false any other helper's. A stored credential
# still answers; a fetch that would ask fails, and the note says so. The fetch also runs in a session of its own with
# stdin from /dev/null (cmux#41715 review), so no program it starts (a GIT_SSH wrapper, plink, a credential helper)
# has a terminal to open and ask on, whatever options it takes; a keeper there ends it with its caller
# (_FETCH_WATCHDOG).
_NO_PROMPT_CONFIG = ("-c", "credential.interactive=false")
_NO_PROMPT_ENV = {"GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "", "SSH_ASKPASS": "", "SSH_ASKPASS_REQUIRE": "never",
                  "GCM_INTERACTIVE": "never"}


def _no_prompt_env(repo: Path) -> dict[str, str]:
    """os.environ for a fetch that never prompts (_NO_PROMPT_ENV) and never takes a hook's index; ssh runs as the user
    set it up (GIT_SSH_COMMAND, else core.sshCommand, else GIT_SSH, else ssh: git's order) with BatchMode=yes, put
    first for OpenSSH (matched by file name), which keeps an option's first value (cmux#41750 review). A GIT_SSH that
    is OpenSSH itself (`ssh`, `/usr/bin/ssh`) becomes the same command line with BatchMode=yes: GIT_SSH takes no
    options, so it could still ask on the terminal (cmux#41715 review). Any other GIT_SSH program (a wrapper, plink)
    is left as it is; the askpass settings above and the fetch's own session with no terminal (_fetch_upstream) hold
    for it."""
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    env.update(_NO_PROMPT_ENV)
    ssh = env.get("GIT_SSH_COMMAND", "")
    if not ssh:
        code, configured = _git(repo, "config", "--get", "core.sshCommand")
        ssh = configured.strip() if code == 0 else ""
    if not ssh and env.get("GIT_SSH"):
        program = env["GIT_SSH"]
        if _is_openssh(program):
            env["GIT_SSH_COMMAND"] = f"{shlex.quote(program)} {_BATCH}"
        return env
    ssh = ssh or "ssh"
    program, rest = _first_word(ssh)
    if _is_openssh(program):
        # OpenSSH keeps the FIRST value of an option, so BatchMode=yes goes straight after the program: appended, it
        # lost to a `-o BatchMode=no` the user's command already had (cmux#41750 review).
        env["GIT_SSH_COMMAND"] = f"{shlex.quote(program)} {_BATCH}{rest}"
    elif "plink" not in os.path.basename(program).lower():
        env["GIT_SSH_COMMAND"] = f"{ssh} {_BATCH}"
    return env


_BATCH = "-o BatchMode=yes"


def _is_openssh(program: str) -> bool:
    """OpenSSH's client, by its file name, so `/usr/bin/ssh` counts as much as `ssh`."""
    return os.path.basename(program).lower() in ("ssh", "ssh.exe")


def _first_word(command: str) -> tuple[str, str]:
    """A shell command's program word (unquoted) and the text after it, untouched; ("", command) when the first word
    does not parse."""
    lexer = shlex.shlex(io.StringIO(command), posix=True)
    lexer.whitespace_split = True
    try:
        word = lexer.get_token() or ""
    except ValueError:
        return "", command
    if not word:
        return "", command
    rest = command[lexer.instream.tell():]
    return word, f" {rest}" if rest.strip() else ""


def refresh_upstream(repo: Path, remote: str | None, upstream_ref: str = UPSTREAM, key: str = "",
                     whose: str = "the push's own", then: str = "push again") -> str:
    """Fetch UPSTREAM_REF (`origin/feat-cmux-next`) from REMOTE into this clone, once per KEY (the pushed-refs lines)
    and hook run (CMUX_PREPUSH_RUN, which the pre-push hook sets once per run: every check of one push calls this, and
    only the first fetches). The stamp holds for that run alone: a stamp keyed only by the rows outlived its run, so
    the same push tried again after the base moved skipped the fetch (cmux#41310 review); with no run named (a hook
    installed before the run id) every call fetches. A failed fetch is stamped too, with why it failed: each checker
    of the run is its own process, and before that every one of them tried the same fetch again, up to 30 s each
    (cmux#41715 review); the later ones give the first one's note. One checker fetches at a time (a lock beside the
    stamp), so checkers that start together wait for the first one's stamp instead of fetching beside it. Returns ""
    when it is fresh, or was left alone (a push to a URL, a remote whose refspecs do not map the branch there, a clone
    without the ref: the fallbacks), else the report's note on why the stale copy bounds the walk (see the module
    docstring)."""
    name = remote_name(repo, remote)
    if not name or not upstream_ref.startswith(f"{name}/"):
        return ""
    branch = upstream_ref[len(name) + 1:]
    tracked = _full_ref(upstream_ref)
    if tracking_ref(repo, name, f"refs/heads/{branch}") != tracked or commit_of(repo, tracked) is None:
        return ""
    code, common = _git(repo, "rev-parse", "--git-common-dir")
    stamp = None
    if code == 0 and common:
        stamp = (Path(common) if os.path.isabs(common) else Path(repo) / common) / "cmux-guardrails" / UPSTREAM_REFRESH_FILE
    run = os.environ.get("CMUX_PREPUSH_RUN", "")
    if not (key and run):
        stamp = None
    token = hashlib.sha256(f"{name}\n{upstream_ref}\n{run}\n{key}".encode()).hexdigest()

    def stale(why: str) -> str:
        return (f"; {upstream_ref} could not be fetched ({why[:200]}), so what a base merge brought in past this "
                f"clone's copy counts as {whose}: run `git fetch {name} {branch}` and {then}")

    def stamped() -> str | None:
        """The run's stamped result (why the fetch failed, "" for a fetch that worked), or None for none yet."""
        try:
            first, _, why = stamp.read_text().partition("\n")
        except OSError:
            return None
        return why.strip() if first.strip() == token else None

    def write_stamp(why: str) -> None:
        try:
            tmp = stamp.with_name(f"{stamp.name}.{os.getpid()}.tmp")
            tmp.write_text(f"{token}\n{why}\n")
            os.replace(tmp, stamp)
        except OSError:
            pass

    if stamp is None:
        return stale(why) if (why := _fetch_upstream(repo, name, branch, tracked)) else ""
    try:
        stamp.parent.mkdir(parents=True, exist_ok=True)
        lock = os.open(stamp.with_name(f"{stamp.name}.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    except OSError:
        lock = None
    try:
        if lock is not None:
            fcntl.flock(lock, fcntl.LOCK_EX)
        if (why := stamped()) is None:
            # Stamped before it starts too (cmux#41750 review): a checker killed mid-fetch (the fast tier's 4 s
            # SIGKILL) runs no code after, and its run's next checker would fetch again.
            write_stamp("an earlier check of this push was stopped mid-fetch")
            why = _fetch_upstream(repo, name, branch, tracked)
            write_stamp(why)
    finally:
        if lock is not None:
            os.close(lock)  # drops the flock
    return stale(why) if why else ""


def _fetch_upstream(repo: Path, name: str, branch: str, tracked: str) -> str:
    """Fetch BRANCH of remote NAME into TRACKED without ever asking for a credential: "" when it worked, else why it
    did not (one line). The fetch runs in a new session with stdin from /dev/null, so nothing it starts has a terminal
    to prompt on (see _NO_PROMPT_ENV), under _FETCH_WATCHDOG, so it ends with this process however this process ends
    (see there)."""
    args = ["git", "-C", str(repo), *_NO_PROMPT_CONFIG, "fetch", "--quiet", "--no-tags", "--no-write-fetch-head",
            name, f"+refs/heads/{branch}:{tracked}"]
    alive_read, alive_write = os.pipe()  # this process holds the write end until the fetch is over
    fired_read, fired_write = os.pipe()  # the guard writes one byte here before it ends the fetch at the limit
    os.set_blocking(fired_read, False)
    try:
        result = subprocess.run([sys.executable, "-I", "-c", _FETCH_WATCHDOG, str(UPSTREAM_FETCH_SECONDS),
                                 str(fired_write), *args],
                                capture_output=True, text=True, env=_no_prompt_env(repo), pass_fds=(fired_write,),
                                timeout=UPSTREAM_FETCH_SECONDS + 10, stdin=alive_read, start_new_session=True)
        if _guard_fired(fired_read):
            why = f"no answer in {UPSTREAM_FETCH_SECONDS}s"
        else:
            why = "" if result.returncode == 0 else (result.stderr.strip().splitlines()
                                                     or [f"exit {result.returncode}"])[-1]
    except subprocess.TimeoutExpired:
        why = f"no answer in {UPSTREAM_FETCH_SECONDS}s"
    except OSError as error:
        why = str(error)
    finally:
        for fd in (alive_read, alive_write, fired_read, fired_write):
            os.close(fd)
    return " ".join(why.split())


def _guard_fired(fired_read: int) -> bool:
    """Whether the fetch's guard ended it at the time limit: its byte is in the pipe before it kills the fetch, so
    it is there by the time the keeper has seen the fetch end. Only that is a timeout; an exit code is never read as
    one (cmux#41765 review: a git that exited 124 at once was reported as "no answer in 30s")."""
    try:
        return bool(os.read(fired_read, 1))
    except BlockingIOError:
        return False


# The fetch's keeper, the first process of the fetch's own session (cmux#41750 review). The session keeps the fetch
# off the caller's terminal, but it also took it out of the caller's process group: prepush_fast_tier.py SIGKILLs its
# worker's group after 4 s, and the fetch ran on (ssh with no limit, no stamp) while the next checker started another;
# a Ctrl-C reaches only the terminal's foreground group, and subprocess.run answers it by killing its own child alone.
# The guard says it ended the fetch at the limit by writing a byte to the fd named in argv[2] first (_guard_fired);
# the keeper's exit is the fetch's own code, or 128 + the signal that ended it.
# A SIGKILL runs no handler, so the keeper's guard watches a pipe instead, whose write end only the caller holds:
# when the caller is gone or done (it closes the pipe on every way out of _fetch_upstream, an interrupt included),
# the pipe reads EOF and the guard kills the fetch's process group (git and the ssh or helper it started). The guard
# is a fork of its own, out of that group and with no hold on the caller's output pipes, so it outlives a keeper the
# caller killed. It enforces the fetch's time limit the same way.
_FETCH_WATCHDOG = r"""
import os, select, signal, subprocess, sys, time
deadline = time.monotonic() + float(sys.argv[1])
fired = int(sys.argv[2])
fetch = subprocess.Popen(sys.argv[3:], stdin=subprocess.DEVNULL, preexec_fn=os.setpgrp)
if os.fork() == 0:
    null = os.open(os.devnull, os.O_RDWR)
    os.dup2(null, 1)
    os.dup2(null, 2)
    while time.monotonic() < deadline:
        if select.select([0], [], [], min(deadline - time.monotonic(), 0.2))[0] and not os.read(0, 1):
            break
        try:
            os.killpg(fetch.pid, 0)
        except ProcessLookupError:
            os._exit(0)
        except PermissionError:
            pass
    else:
        os.write(fired, b"T")
    try:
        os.killpg(fetch.pid, signal.SIGKILL)
    except OSError:
        pass
    os._exit(0)
os.close(fired)
code = fetch.wait()
sys.exit(code if code >= 0 else 128 - code)
"""


def refresh_base(repo: Path | str, ref: str, remote: str | None = DEFAULT_REMOTE) -> str:
    """Fetch REF (`origin/feat-cmux-next`, `refs/remotes/origin/main`) from REMOTE before a tool measures a branch's
    own change from where HEAD meets it (see the module docstring); refresh_upstream once per process (a failure too),
    with no per-push stamp.
    Returns "" when it is fresh or left alone (a sha, another remote, a remote that does not map it), else the note
    on why the stale copy is used. Never on GitHub Actions: a CI checkout fetches the base it diffs against itself,
    and a fetch there would deepen a shallow clone."""
    if os.environ.get("GITHUB_ACTIONS"):
        return ""
    if ref.startswith("refs/remotes/"):
        ref = ref[len("refs/remotes/"):]
    done = (os.path.realpath(repo), remote, ref)
    if done not in _REFRESHED:
        _REFRESHED[done] = refresh_upstream(Path(repo), remote, ref, whose="this branch's own", then="run this again")
    return _REFRESHED[done]


# refresh_base's result per (clone, remote, ref) for this process, a failed fetch's note included (cmux#41662 review):
# the Rust panic ratchet asked once per failing crate/lint group, so three groups fetched three times and a stalled
# remote cost 30 s each. Every reader loads this file under one module name, so they share it.
_REFRESHED: dict[tuple[str, str | None, str], str] = {}


def manual_range(repo: Path, head: str = "HEAD", upstream_ref: str = UPSTREAM,
                 remote: str | None = DEFAULT_REMOTE) -> OwnRange:
    """own_range for a run outside a push (no pre-push stdin): the shared base is fetched first (refresh_base), as
    pushed_ranges does for a push, and a fetch that fails is said in the note."""
    stale = refresh_base(repo, upstream_ref, remote)
    own = own_range(repo, head, [], upstream_ref, remote)
    return dataclasses.replace(own, note=own.note + stale) if stale else own


def pushed_ranges(repo: Path, lines: list[str], remote: str | None = DEFAULT_REMOTE,
                  upstream_ref: str = UPSTREAM) -> tuple[list[OwnRange], list[str]]:
    """Pre-push stdin rows (`<local ref> <local sha> <remote ref> <remote sha>`) as (own ranges, errors).

    REMOTE is the hook's first argument (a remote name, or the URL of a push to a URL). A deletion or a tag of a
    tree or blob pushes no commit and is left out. A remote head this clone does not have (someone pushed since
    the last fetch) bounds nothing itself (the tracking ref still does); the note says so. A row whose own range
    cannot be told (own_range's ValueError) is an error line naming the ref: the caller refuses the push with it.
    The shared base is fetched first (refresh_upstream), unless every pushed row lands on that branch itself (its
    remote head bounds the walk) or deletes.
    """
    ranges, errors = [], []
    branch = upstream_ref.split("/", 1)[-1]
    rows = [line.split() for line in lines]
    pushing = [parts for parts in rows if len(parts) == 4 and parts[1] != ZERO_SHA]
    stale = ""
    if any(parts[2] != f"refs/heads/{branch}" for parts in pushing):
        stale = refresh_upstream(repo, remote, upstream_ref, key="\n".join(" ".join(parts) for parts in pushing))
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
        if stale:
            own = dataclasses.replace(own, note=own.note + stale)
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

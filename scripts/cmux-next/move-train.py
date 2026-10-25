#!/usr/bin/env python3
"""move-train: land ready commits onto a shared branch after one fleet compile, bisecting on red.

Usage:
  scripts/cmux-next/move-train.py [--onto perf/chrome-parity] [--max 8] [--dry-run] REF...

Each REF (a branch, a remote branch or a commit) contributes its commits that are not on the target
yet (`git rev-list --cherry-pick --right-only <target>...REF`, oldest first; a commit already named
by an earlier REF keeps that REF). A branch REF is fetched from --remote first (`cp/x` and
`origin/cp/x` both mean the remote's cp/x), so the train stacks what the author pushed, not a stale
local copy; a REF the remote does not have resolves locally. Commits of one REF form a group (a seam
commit and its move). Commits named by sha are independent ready commits. The train takes up to
--max of them in argument order, stacks them on the target tip with git plumbing (merge-tree and
commit-tree: no checkout is touched), pushes the stack to a scratch ref and runs ONE fleet check:

  cmux-ci compile-check --app --package CmuxNext --no-cmux-tui --ref <stack tip>

Green lands the whole stack with a fast-forward push. Red first compiles the target tip unless an
earlier train proved it green (Chromium's tools/bisect-builds.py checks the good end before it
bisects), so a red base is reported in one compile instead of blamed on a commit. Then it bisects
the stack on the fleet (binary search between the last green and the first red prefix), names the
first bad commit and drops it with every later commit that builds on it: the rest of its REF and,
by ancestry (`git merge-base --is-ancestor`), the commits of any branch REF made on top of it. It
lands the green prefix and restacks the rest for the next round. A commit that no longer applies is
named and dropped the same way.

The train never builds locally: it refuses to start without cmux-ci, and every verdict is a fleet
receipt (`compile check <target>: passed|failed`). A no-verdict exit (69, 75, 124, ...) stops the
train; only what the fleet proved green lands. After a landing, the train lowers the app-size cap
(check-app-size.sh --update-baseline) and records arch-ratchet.py --update on top of the green tip,
in one bookkeeping commit; those two files do not take part in a compile. Both scripts run from the
target tip (the reviewed copies), never from the stack, and each step's result is in the receipt.

--dry-run does all of it except the push to the target: the stack still goes to scratch refs, since
the fleet only compiles pushed commits. Scratch refs (refs/heads/move-train/<run>-<round>) are
deleted at the end. A receipt with every compile, landing and rejection is written to
artifacts/move-train/<run>.json, also when the run stops on an error; the green shas in earlier
receipts there are known green to later trains.

Exit: 0 every candidate landed, 1 a commit was rejected (the green rest landed), 2 refused (no
cmux-ci, git older than 2.40, bad arguments, an unknown REF), 3 no fleet verdict (the proven-green
prefix landed), 4 the target tip itself is red, 5 the target moved during the run (nothing landed;
rerun), 6 the landing push was refused while the target stayed put (a hook, a branch rule or auth:
the receipt has git's message; a rerun fails the same way), 7 a git error during the run (the
receipt keeps the compiles), 8 everything landed but a bookkeeping step failed (see the receipt).

Tests: python3 -I scripts/cmux-next/tests/test_move_train.py
"""

from __future__ import annotations

import argparse
import dataclasses
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path
from typing import Callable, Protocol, Sequence

DEFAULT_ONTO = "perf/chrome-parity"
DEFAULT_PACKAGES = ("CmuxNext",)
SCRATCH_PREFIX = "refs/heads/move-train"
APP_SIZE = "scripts/cmux-next/check-app-size.sh"
APP_SIZE_BASELINE = "scripts/cmux-next/app-size-baseline.txt"
ARCH_RATCHET = "scripts/cmux-next/arch-ratchet.py"
ARCH_RATCHET_JSON = "plans/cmux-next/arch-ratchet.json"
BOOKKEEPING_FILES = (APP_SIZE_BASELINE, ARCH_RATCHET_JSON)
VERDICT_LINE = re.compile(r"^compile check (\S+): (passed|failed|no verdict)")
JOB_LINE = re.compile(r"^compile check job ([0-9a-f]{6,64})")
FULL_SHA = re.compile(r"[0-9a-f]{40}")
SHORT_SHA = re.compile(r"[0-9a-f]{7,40}")
OBJECT_ID = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")  # sha1 or sha256 repositories
MIN_GIT = (2, 40)  # merge-tree --write-tree --merge-base

(EXIT_OK, EXIT_REJECTED, EXIT_REFUSED, EXIT_NO_VERDICT, EXIT_BASE_RED, EXIT_TARGET_MOVED, EXIT_PUSH_REFUSED,
 EXIT_RUN_ERROR, EXIT_BOOKKEEPING) = range(9)

GREEN, RED, NO_VERDICT = "green", "red", "no-verdict"


class TrainError(Exception):
    def __init__(self, message: str, code: int = EXIT_REFUSED):
        super().__init__(message)
        self.code = code


@dataclasses.dataclass(frozen=True)
class Candidate:
    sha: str
    source: str  # the REF it came from; later commits of one source build on earlier ones
    subject: str
    independent: bool = False  # named by sha: only its own REF group follows it, not its descendants


@dataclasses.dataclass(frozen=True)
class Stacked:
    candidate: Candidate
    sha: str  # the restacked commit


@dataclasses.dataclass(frozen=True)
class Verdict:
    result: str
    code: int
    job: str | None
    lines: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class Rejection:
    candidate: Candidate
    reason: str


class Compiler(Protocol):
    def compile(self, sha: str) -> Verdict: ...


class Git:
    def __init__(self, repo: Path):
        self.repo = repo

    def run(self, *args: str, env: dict[str, str] | None = None, check: bool = True,
            stdin: str | None = None) -> subprocess.CompletedProcess[str]:
        proc = subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True, text=True,
                              input=stdin, env={**os.environ, **(env or {})})
        if check and proc.returncode != 0:
            raise TrainError(f"git {' '.join(args)} failed: {proc.stderr.strip() or proc.stdout.strip()}",
                             EXIT_RUN_ERROR)
        return proc

    def out(self, *args: str) -> str:
        return self.run(*args).stdout.strip()

    def resolve(self, ref: str) -> str | None:
        proc = self.run("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}", check=False)
        return proc.stdout.strip() if proc.returncode == 0 else None

    def tree(self, sha: str) -> str:
        return self.out("rev-parse", f"{sha}^{{tree}}")

    def export(self, rev: str, path: str, into: Path) -> None:
        """rev's copy of path (a directory) under into, from git objects; no worktree. Nothing when rev lacks it."""
        into.mkdir(parents=True, exist_ok=True)
        if self.run("cat-file", "-e", f"{rev}:{path}", check=False).returncode != 0:
            return
        proc = subprocess.run(["git", "-C", str(self.repo), "archive", "--format=tar", rev, "--", path],
                              capture_output=True)
        if proc.returncode != 0:
            raise TrainError(f"git archive {rev[:12]} {path} failed: {proc.stderr.decode(errors='replace').strip()}",
                             EXIT_RUN_ERROR)
        with tarfile.open(fileobj=io.BytesIO(proc.stdout)) as archive:
            if hasattr(tarfile, "data_filter"):
                archive.extractall(into, filter="data")
            else:  # Python without extraction filters (3.9 before 3.9.17): our own repo's objects
                archive.extractall(into)

    def is_ancestor(self, ancestor: str, sha: str) -> bool:
        proc = self.run("merge-base", "--is-ancestor", ancestor, sha, check=False)
        if proc.returncode not in (0, 1):
            raise TrainError(f"git merge-base --is-ancestor {ancestor[:12]} {sha[:12]} exited {proc.returncode}: "
                             f"{proc.stderr.strip()}", EXIT_RUN_ERROR)
        return proc.returncode == 0

    def pick(self, onto: str, sha: str) -> str | None:
        """Cherry-pick sha onto onto without a worktree; the new commit, None on a conflict.
        Raises when the commit is a merge or a root (the train stacks plain commits only), and when
        merge-tree fails for any other reason than a conflict: a conflict exits 1 and still prints
        the tree, a bad object exits 1 with no tree, a usage error exits 129 and a repo error 128."""
        parents = self.out("rev-list", "--parents", "-n", "1", sha).split()[1:]
        if len(parents) != 1:
            raise TrainError(f"{sha[:12]} has {len(parents)} parents; the train stacks plain commits", EXIT_RUN_ERROR)
        merged = self.run("merge-tree", "--write-tree", f"--merge-base={parents[0]}", onto, sha, check=False)
        tree = merged.stdout.split("\n", 1)[0].strip()
        if merged.returncode not in (0, 1) or not OBJECT_ID.fullmatch(tree):
            raise TrainError(f"git merge-tree of {sha[:12]} onto {onto[:12]} exited {merged.returncode}: "
                             f"{merged.stderr.strip() or merged.stdout.strip()}", EXIT_RUN_ERROR)
        if merged.returncode == 1:
            return None
        name, email, date = self.out("log", "-1", "--date=raw", "--format=%an%x00%ae%x00%ad", sha).split("\x00")
        message = self.run("log", "-1", "--format=%B", sha).stdout
        author = {"GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email, "GIT_AUTHOR_DATE": date}
        return self.run("commit-tree", tree, "-p", onto, env=author, stdin=message).stdout.strip()


class FleetCompiler:
    """One `cmux-ci compile-check` per call; its own receipt lines are the verdict."""

    def __init__(self, cmux_ci: str, packages: Sequence[str], timeout: int | None, queue_timeout: int | None,
                 echo: Callable[[str], None]):
        self.cmux_ci, self.packages, self.echo = cmux_ci, list(packages), echo
        self.extra = [*(["--timeout", str(timeout)] if timeout else []),
                      *(["--queue-timeout", str(queue_timeout)] if queue_timeout else [])]

    def command(self, sha: str) -> list[str]:
        # The Swift move train asks for CmuxNext and the app only: a red cmux-tui on the base must not
        # hold every Swift move (a version 1 recipe ignores the flag).
        packages = [arg for package in self.packages for arg in ("--package", package)]
        return [self.cmux_ci, "compile-check", "--app", *packages, "--no-cmux-tui", "--ref", sha, *self.extra]

    def compile(self, sha: str) -> Verdict:
        proc = subprocess.Popen(self.command(sha), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        assert proc.stdout is not None
        lines = []
        for raw in proc.stdout:
            line = raw.rstrip("\n")
            lines.append(line)
            self.echo(f"    {line}")
        code = proc.wait()
        return verdict_from(code, lines)


def verdict_from(code: int, lines: Sequence[str]) -> Verdict:
    """cmux-ci exits 0 when every asked target compiled and 1 when one did not; a red or green exit
    must also carry its receipt lines, else it is no verdict (never trust only the exit code)."""
    job = next((m.group(1) for m in map(JOB_LINE.match, lines) if m), None)
    states = [m.group(2) for m in map(VERDICT_LINE.match, lines) if m]
    if code == 0 and states and all(state == "passed" for state in states):
        return Verdict(GREEN, code, job, tuple(lines))
    if code == 1 and "failed" in states:
        return Verdict(RED, code, job, tuple(lines))
    return Verdict(NO_VERDICT, code, job, tuple(lines))


def find_cmux_ci(explicit: str | None) -> str:
    candidates = [explicit] if explicit else [os.environ.get("CMUX_CI"), shutil.which("cmux-ci"),
                                              str(Path.home() / ".local/bin/cmux-ci")]
    for path in candidates:
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    raise TrainError("move-train needs cmux-ci (the fleet client, ~/.local/bin/cmux-ci) and never builds "
                     "locally; install it: python3 build-fleet/install-client.py --prefix ~/.local (hq main)")


def git_version_ok(text: str) -> bool:
    """`git version 2.43.0` or `git version 2.39.5 (Apple Git-154)`: at least MIN_GIT."""
    match = re.search(r"(\d+)\.(\d+)", text)
    return bool(match) and (int(match.group(1)), int(match.group(2))) >= MIN_GIT


def require_git() -> None:
    text = subprocess.run(["git", "version"], capture_output=True, text=True).stdout.strip()
    if not git_version_ok(text):
        raise TrainError(f"move-train needs git {MIN_GIT[0]}.{MIN_GIT[1]} or newer (merge-tree --merge-base); "
                         f"found {text or 'no git'}")


def known_green(receipts: Path) -> set[str]:
    """The shas earlier trains proved green, from their receipts in this directory."""
    green: set[str] = set()
    for path in receipts.glob("*.json"):
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if isinstance(data, dict) and isinstance(data.get("green"), list):
            green.update(sha for sha in data["green"] if isinstance(sha, str) and FULL_SHA.fullmatch(sha))
    return green


class Train:
    def __init__(self, git: Git, compiler: Compiler, remote: str, onto: str, run_id: str, dry_run: bool,
                 bookkeeping: bool, echo: Callable[[str], None], green: set[str] | None = None):
        self.git, self.compiler, self.remote, self.onto = git, compiler, remote, onto
        self.run_id, self.dry_run, self.bookkeeping, self.echo = run_id, dry_run, bookkeeping, echo
        self.compiles: list[dict] = []
        self.scratch: list[str] = []
        self.green: set[str] = set(green or ())  # known green: from earlier receipts and this run
        self.proven: set[str] = set()  # green in this run (compiled, or known and reused): the receipt's list
        self.refs: list[dict] = []
        self.rejected: list[Rejection] = []
        self.bookkept: list[dict] = []

    # -- inputs ----------------------------------------------------------------------------------------
    def fetch_base(self) -> str:
        self.git.run("fetch", "--quiet", self.remote, f"+refs/heads/{self.onto}:refs/remotes/{self.remote}/{self.onto}")
        base = self.git.resolve(f"refs/remotes/{self.remote}/{self.onto}")
        if not base:
            raise TrainError(f"no branch {self.onto} on {self.remote}")
        return base

    def resolve_ref(self, ref: str) -> tuple[str, str, bool]:
        """(tip, where it came from, independent). A full sha is that commit; any other REF is the
        remote's branch of that name when the remote has one (fetched now), else a local name."""
        if FULL_SHA.fullmatch(ref):
            if self.git.resolve(ref) is None:
                self.git.run("fetch", "--quiet", self.remote, ref, check=False)
            tip = self.git.resolve(ref)
            if tip is None:
                raise TrainError(f"no commit {ref} here or on {self.remote}")
            return tip, "commit", True
        branch = ref
        for prefix in ("refs/heads/", f"refs/remotes/{self.remote}/", f"{self.remote}/"):
            branch = branch.removeprefix(prefix)
        listed = self.git.run("ls-remote", "--exit-code", self.remote, f"refs/heads/{branch}", check=False)
        if listed.returncode not in (0, 2):
            raise TrainError(f"git ls-remote {self.remote} refs/heads/{branch} failed: {listed.stderr.strip()}",
                             EXIT_RUN_ERROR)
        if any(line.split("\t")[-1] == f"refs/heads/{branch}" for line in listed.stdout.splitlines()):
            tracking = f"refs/remotes/{self.remote}/{branch}"
            self.git.run("fetch", "--quiet", self.remote, f"+refs/heads/{branch}:{tracking}")
            tip = self.git.resolve(tracking)
            if tip is None:
                raise TrainError(f"{self.remote}/{branch} did not resolve after the fetch", EXIT_RUN_ERROR)
            return tip, f"{self.remote}/{branch}", False
        tip = self.git.resolve(ref)
        if tip is None:
            raise TrainError(f"no commit {ref} here or branch {branch} on {self.remote}")
        return tip, "local", bool(SHORT_SHA.fullmatch(ref))

    def candidates(self, base: str, refs: Sequence[str]) -> list[Candidate]:
        found: list[Candidate] = []
        seen: set[str] = set()
        for ref in refs:
            tip, where, independent = self.resolve_ref(ref)
            self.refs.append({"ref": ref, "tip": tip, "from": where})
            self.echo(f"  {ref}: {tip[:12]} ({where})")
            listed = self.git.out("rev-list", "--reverse", "--no-merges", "--cherry-pick", "--right-only",
                                  f"{base}...{tip}")
            for sha in listed.split():
                if sha not in seen:
                    seen.add(sha)
                    found.append(Candidate(sha, ref, self.git.out("log", "-1", "--format=%s", sha), independent))
        return found

    def follows(self, culprit: Candidate, candidate: Candidate) -> bool:
        """candidate builds on culprit: the same REF group, or a descendant (unless it was named by sha)."""
        if candidate.source == culprit.source:
            return True
        return not candidate.independent and self.git.is_ancestor(culprit.sha, candidate.sha)

    # -- the fleet -------------------------------------------------------------------------------------
    def publish(self, tip: str) -> None:
        ref = f"{SCRATCH_PREFIX}/{self.run_id}-{len(self.scratch) + 1}"
        self.git.run("push", "--quiet", self.remote, f"{tip}:{ref}")
        self.scratch.append(ref)

    def compile(self, sha: str, why: str) -> Verdict:
        if sha in self.green:
            self.proven.add(sha)
            return Verdict(GREEN, 0, None, ("known green",))
        self.echo(f"  compile {sha[:12]} ({why})")
        verdict = self.compiler.compile(sha)
        self.compiles.append({"sha": sha, "why": why, "verdict": verdict.result, "code": verdict.code,
                              "job": verdict.job, "lines": list(verdict.lines)})
        self.echo(f"  {sha[:12]}: {verdict.result}" + (f" (job {verdict.job})" if verdict.job else ""))
        if verdict.result == GREEN:
            self.green.add(sha)
            self.proven.add(sha)
        return verdict

    def cleanup(self) -> None:
        if self.scratch:
            self.git.run("push", "--quiet", self.remote, "--delete", *self.scratch, check=False)

    # -- the train -------------------------------------------------------------------------------------
    def stack(self, onto: str, pending: list[Candidate]) -> list[Stacked]:
        stacked: list[Stacked] = []
        tip = onto
        dropped: list[tuple[Candidate, str]] = []
        for candidate in pending:
            cause = next((reason for bad, reason in dropped if self.follows(bad, candidate)), None)
            if cause:
                self.rejected.append(Rejection(candidate, cause))
                continue
            picked = self.git.pick(tip, candidate.sha)
            if picked is None:
                reason = f"does not apply on {tip[:12]}"
                self.rejected.append(Rejection(candidate, reason))
                dropped.append((candidate, f"follows {candidate.sha[:12]}, which {reason}"))
                continue
            if self.git.tree(picked) == self.git.tree(tip):
                self.echo(f"  skip {candidate.sha[:12]}: already on the target")
                continue
            stacked.append(Stacked(candidate, picked))
            tip = picked
        return stacked

    def run(self, base: str, pending: list[Candidate]) -> tuple[str, list[Stacked], int]:
        """(green tip, landed, exit code) from fleet verdicts; pushes nothing to the target."""
        green_tip, landed = base, []
        while pending:
            stack = self.stack(green_tip, pending)
            if not stack:
                break
            self.publish(stack[-1].sha)
            verdict = self.compile(stack[-1].sha, f"stack of {len(stack)}")
            if verdict.result == GREEN:
                return stack[-1].sha, landed + stack, self.exit_code()
            if verdict.result == NO_VERDICT:
                return green_tip, landed, EXIT_NO_VERDICT
            if green_tip not in self.green:  # the good end first, as bisect-builds.py checks its endpoints
                tip_verdict = self.compile(green_tip, "target tip")
                if tip_verdict.result != GREEN:
                    self.echo(f"move-train: the target tip {green_tip[:12]} is {tip_verdict.result}; nothing lands")
                    return green_tip, landed, EXIT_BASE_RED if tip_verdict.result == RED else EXIT_NO_VERDICT
            good, bad, red = -1, len(stack) - 1, verdict  # stack[good] (green_tip at -1) green, stack[bad] red
            while bad - good > 1:
                mid = (good + bad) // 2
                verdict = self.compile(stack[mid].sha, f"bisect {mid + 1} of {len(stack)}")
                if verdict.result == NO_VERDICT:
                    return (stack[good].sha if good >= 0 else green_tip), landed + stack[:good + 1], EXIT_NO_VERDICT
                if verdict.result == GREEN:
                    good = mid
                else:
                    bad, red = mid, verdict
            culprit = stack[bad].candidate
            self.rejected.append(Rejection(culprit, f"first red commit: compile red at {stack[bad].sha[:12]}"
                                                    + (f" (job {red.job})" if red.job else "")))
            landed += stack[:bad]
            green_tip = stack[bad - 1].sha if bad > 0 else green_tip
            reason = f"follows bad commit {culprit.sha[:12]}"
            rest = []
            for item in stack[bad + 1:]:
                if self.follows(culprit, item.candidate):
                    self.rejected.append(Rejection(item.candidate, reason))
                else:
                    rest.append(item.candidate)
            pending = rest
        return green_tip, landed, self.exit_code()

    def exit_code(self) -> int:
        return EXIT_REJECTED if self.rejected else EXIT_OK

    def bookkeep(self, base: str, tip: str) -> str:
        """The app-size cap and arch ratchet recorded on top of tip, as one commit; tip when nothing
        changed or bookkeeping could not run. The scripts run from base (landed, reviewed), measuring tip."""
        if not self.bookkeeping:
            return tip
        scratch = Path(tempfile.mkdtemp(prefix="move-train-"))
        measured = scratch / "tip"
        added = False
        try:
            self.git.export(base, Path(APP_SIZE).parent.as_posix(), scratch / "base")
            self.git.run("worktree", "add", "--quiet", "--detach", str(measured), tip)
            added = True
            return self.record(scratch / "base", measured, tip)
        except TrainError as error:
            self.note("bookkeeping", False, str(error))
            return tip
        finally:
            if added:
                self.git.run("worktree", "remove", "--force", str(measured), check=False)
            shutil.rmtree(scratch, ignore_errors=True)

    def note(self, step: str, ok: bool | None, detail: str, code: int | None = None) -> None:
        self.bookkept.append({"step": step, "ok": ok, "exit": code, "detail": detail[-400:]})
        if ok is False:
            exited = f" (exit {code})" if code is not None else ""
            self.echo(f"  bookkeeping: {step} failed{exited}: {detail[-400:]}")

    def bookkeeping_failed(self) -> bool:
        return any(entry["ok"] is False for entry in self.bookkept)

    def record(self, trusted: Path, measured: Path, tip: str) -> str:
        tree = Git(measured)
        steps = (
            (APP_SIZE, APP_SIZE_BASELINE, ["bash", str(trusted / APP_SIZE), "--update-baseline", str(measured)]),
            (ARCH_RATCHET, ARCH_RATCHET_JSON, [sys.executable, "-I", str(trusted / ARCH_RATCHET), "--repo",
                                               str(measured), "--update", "--rev", "HEAD",
                                               "--upstream", f"{self.remote}/{self.onto}"]),
        )
        for script, owned, command in steps:
            if not (trusted / script).is_file():
                self.note(script, None, "not on the target tip; skipped")
                continue
            proc = subprocess.run(command, cwd=measured, capture_output=True, text=True)
            output = (proc.stdout + proc.stderr).strip()
            self.note(script, proc.returncode == 0, output, proc.returncode)
            if proc.returncode != 0:  # a failed step records nothing, the other step still does
                tree.run("checkout", "HEAD", "--", owned, check=False)
                tree.run("clean", "--quiet", "-f", "--", owned, check=False)
        tree.run("add", "-A")
        paths = set(tree.out("diff", "--cached", "--name-only", "HEAD").splitlines())
        if not paths:
            return tip
        if not paths <= set(BOOKKEEPING_FILES):
            self.note("bookkeeping", False, f"it changed {sorted(paths - set(BOOKKEEPING_FILES))}; nothing recorded")
            return tip
        message = ("move-train: lower the app-size cap and record the arch ratchet\n\n"
                   f"After the green stack {tip[:12]} (run {self.run_id}): {', '.join(sorted(paths))}.\n"
                   "Data files only, not compiled.\n")
        commit = tree.run("commit-tree", tree.out("write-tree"), "-p", tip, stdin=message).stdout.strip()
        self.note("bookkeeping", True, f"commit {commit} records {', '.join(sorted(paths))}")
        return commit

    def remote_tip(self) -> str | None:
        listed = self.git.run("ls-remote", self.remote, f"refs/heads/{self.onto}").stdout.split()
        return listed[0] if listed else None

    def land(self, base: str, tip: str) -> int:
        if self.remote_tip() != base:
            self.echo(f"move-train: {self.onto} moved since {base[:12]}; nothing landed, rerun the train")
            return EXIT_TARGET_MOVED
        # A plain push is a fast-forward only: a target that moved after the check above refuses it.
        pushed = self.git.run("push", "--quiet", self.remote, f"{tip}:refs/heads/{self.onto}", check=False)
        if pushed.returncode == 0:
            return EXIT_OK
        if self.remote_tip() != base:
            self.echo(f"move-train: {self.onto} moved during the push; nothing landed, rerun the train")
            return EXIT_TARGET_MOVED
        self.echo(f"move-train: the push to {self.onto} was refused and {self.onto} is still at {base[:12]} "
                  f"(a pre-push hook, a branch rule or auth); nothing landed. git said:\n"
                  f"  {(pushed.stderr or pushed.stdout).strip()}")
        return EXIT_PUSH_REFUSED


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("refs", nargs="*", metavar="REF", help="ready commits: branches or commits, in landing order")
    parser.add_argument("--from", dest="from_file", help="read more REFs from this file, one per line (# comments)")
    parser.add_argument("--onto", default=DEFAULT_ONTO, help=f"the shared branch to land on (default {DEFAULT_ONTO})")
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--max", type=int, default=8, help="at most this many commits per train (default 8)")
    parser.add_argument("--package", action="append", help="compile-check package (default CmuxNext; repeatable)")
    parser.add_argument("--cmux-ci", help="the fleet client (default $CMUX_CI, PATH, ~/.local/bin/cmux-ci)")
    parser.add_argument("--timeout", type=int, help="cmux-ci compile-check --timeout")
    parser.add_argument("--queue-timeout", type=int, help="cmux-ci compile-check --queue-timeout")
    parser.add_argument("--dry-run", action="store_true", help="compile and bisect on the fleet, push nothing to --onto")
    parser.add_argument("--no-bookkeeping", action="store_true", help="skip the app-size cap and arch ratchet commit")
    parser.add_argument("--run-id", help="names the scratch refs and the receipt (default a timestamp)")
    parser.add_argument("--receipt", help="train receipt path (default artifacts/move-train/<run>.json)")
    parser.add_argument("--repo", help="the repository (default the current one)")
    args = parser.parse_args(argv)
    if args.max < 1:
        parser.error("--max must be at least 1")
    if args.run_id and not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", args.run_id):
        parser.error("--run-id takes letters, digits, '.', '_' and '-'")
    return args


def main(argv: Sequence[str] | None = None, compiler: Compiler | None = None) -> int:
    args = parse_args(argv)
    echo = lambda line: print(line, flush=True)  # noqa: E731
    try:
        cmux_ci = find_cmux_ci(args.cmux_ci)  # first: no cmux-ci, no train, even for a dry run
        require_git()
        refs = list(args.refs)
        if args.from_file:
            text = Path(args.from_file).read_text()
            refs += [line.split("#", 1)[0].strip() for line in text.splitlines() if line.split("#", 1)[0].strip()]
        if not refs:
            raise TrainError("no REF given: name the ready commits or branches")
        repo = Path(args.repo or subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True,
                                                text=True).stdout.strip() or ".").resolve()
        run_id = args.run_id or time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + f"-{os.getpid()}"
        receipt = Path(args.receipt) if args.receipt else repo / "artifacts" / "move-train" / f"{run_id}.json"
        compiler = compiler or FleetCompiler(cmux_ci, args.package or DEFAULT_PACKAGES, args.timeout,
                                             args.queue_timeout, echo)
        train = Train(Git(repo), compiler, args.remote, args.onto, run_id, args.dry_run, not args.no_bookkeeping,
                      echo, known_green(receipt.parent))
    except TrainError as error:
        print(f"move-train: {error}", file=sys.stderr)
        return error.code

    base: str | None = None
    pending: list[Candidate] = []
    waiting: list[Candidate] = []
    landed: list[Stacked] = []
    tip = final = None
    pushed = False
    code, error_text = EXIT_RUN_ERROR, "the train stopped before it finished"
    try:
        base = train.fetch_base()
        found = train.candidates(base, refs)
        pending, waiting = found[:args.max], found[args.max:]
        echo(f"move-train {run_id}: {len(pending)} commit(s) onto {args.onto} at {base[:12]}"
             + (f", {len(waiting)} wait for the next train" if waiting else "") + (" (dry run)" if args.dry_run else ""))
        tip, landed, code = train.run(base, pending)
        final = tip
        if landed:
            final = train.bookkeep(base, tip)
            if code == EXIT_OK and train.bookkeeping_failed():
                code = EXIT_BOOKKEEPING
            if not args.dry_run:
                landing = train.land(base, final)
                pushed = landing == EXIT_OK
                code = code if pushed else landing
        error_text = None
    except TrainError as error:
        code, error_text, landed = error.code, str(error), []
        print(f"move-train: {error}", file=sys.stderr)
    finally:
        train.cleanup()
        if pushed and tip in train.proven:
            train.proven.add(final)  # its bookkeeping commit changes data files only
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({
            "run": run_id, "onto": args.onto, "remote": args.remote, "base": base, "dry_run": args.dry_run,
            "exit": code, "error": error_text, "pushed": pushed, "green_tip": tip,
            "landed_tip": final if landed else None, "refs": train.refs,
            "landed": [{"source": i.candidate.source, "sha": i.candidate.sha, "landed_sha": i.sha,
                        "subject": i.candidate.subject} for i in landed],
            "rejected": [{"source": r.candidate.source, "sha": r.candidate.sha, "subject": r.candidate.subject,
                          "reason": r.reason} for r in train.rejected],
            "waiting": [c.sha for c in waiting], "bookkeeping": train.bookkept, "green": sorted(train.proven),
            "compiles": train.compiles,
        }, indent=2) + "\n")
        echo(f"move-train: receipt {receipt}")

    if error_text is None:
        verb = "would land" if args.dry_run else ("landed" if pushed else "did not land")
        echo(f"move-train: {verb} {len(landed)} of {len(pending)} onto {args.onto}"
             + (f" at {final[:12]}" if landed and final else ""))
        for item in landed:
            echo(f"  landed   {item.candidate.sha[:12]} -> {item.sha[:12]} {item.candidate.subject}")
    for rejection in train.rejected:
        echo(f"  rejected {rejection.candidate.sha[:12]} {rejection.candidate.subject}: {rejection.reason}")
    for candidate in waiting:
        echo(f"  waiting  {candidate.sha[:12]} {candidate.subject}")
    return code


if __name__ == "__main__":
    sys.exit(main())

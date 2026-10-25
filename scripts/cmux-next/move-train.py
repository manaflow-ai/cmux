#!/usr/bin/env python3
"""move-train: land ready commits onto a shared branch after one fleet compile, bisecting on red.

Usage:
  scripts/cmux-next/move-train.py [--onto perf/chrome-parity] [--max 8] [--dry-run] REF...

Each REF (a branch, a remote branch or a commit) contributes its commits that are not on the target
yet (`git rev-list --cherry-pick --right-only <target>...REF`, oldest first; a commit already named
by an earlier REF keeps that REF). Commits of one REF form a group (a seam commit and its move);
name commits by sha to make them independent ready commits. The train takes up to
--max of them in argument order, stacks them on the target tip with git plumbing (merge-tree and
commit-tree: no checkout is touched), pushes the stack to a scratch ref and runs ONE fleet check:

  cmux-ci compile-check --app --package CmuxNext --ref <stack tip>

Green lands the whole stack with a fast-forward push. Red bisects the stack on the fleet (binary
search between the last green and the first red prefix, as Chromium's tools/bisect-builds.py does
between a good and a bad build), names the first bad commit, drops it and the later commits of the
same REF (they build on it), lands the green prefix and restacks the rest for the next round. A
commit that no longer applies once a bad one is dropped is named too. When the culprit is the first
commit, the target tip itself is compiled once, so a red base is reported instead of blamed on a
commit.

The train never builds locally: it refuses to start without cmux-ci, and every verdict is a fleet
receipt (`compile check <target>: passed|failed`). A no-verdict exit (69, 75, 124, ...) stops the
train; only what the fleet proved green lands. After a landing, the train lowers the app-size cap
(check-app-size.sh --update-baseline) and records arch-ratchet.py --update on top of the green tip,
in one bookkeeping commit; those two files do not take part in a compile.

--dry-run does all of it except the push to the target: the stack still goes to scratch refs, since
the fleet only compiles pushed commits. Scratch refs (refs/heads/move-train/<run>-<round>) are
deleted at the end. A receipt with every compile, landing and rejection is written to
artifacts/move-train/<run>.json.

Exit: 0 every candidate landed, 1 a commit was rejected (the green rest landed), 2 refused (no
cmux-ci, bad arguments), 3 no fleet verdict, 4 the target tip itself is red, 5 the target moved
during the run (nothing landed; rerun).

Tests: python3 -I scripts/cmux-next/tests/test_move_train.py
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import shutil
import subprocess
import sys
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

EXIT_OK, EXIT_REJECTED, EXIT_REFUSED, EXIT_NO_VERDICT, EXIT_BASE_RED, EXIT_TARGET_MOVED = range(6)

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
            raise TrainError(f"git {' '.join(args)} failed: {proc.stderr.strip() or proc.stdout.strip()}")
        return proc

    def out(self, *args: str) -> str:
        return self.run(*args).stdout.strip()

    def resolve(self, ref: str) -> str | None:
        proc = self.run("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}", check=False)
        return proc.stdout.strip() if proc.returncode == 0 else None

    def tree(self, sha: str) -> str:
        return self.out("rev-parse", f"{sha}^{{tree}}")

    def pick(self, onto: str, sha: str) -> str | None:
        """Cherry-pick sha onto onto without a worktree; the new commit, None on a conflict.
        Raises when the commit is a merge or a root (the train stacks plain commits only)."""
        parents = self.out("rev-list", "--parents", "-n", "1", sha).split()[1:]
        if len(parents) != 1:
            raise TrainError(f"{sha[:12]} has {len(parents)} parents; the train stacks plain commits")
        merged = self.run("merge-tree", "--write-tree", f"--merge-base={parents[0]}", onto, sha, check=False)
        if merged.returncode != 0:
            return None
        tree = merged.stdout.split("\n", 1)[0].strip()
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
        packages = [arg for package in self.packages for arg in ("--package", package)]
        return [self.cmux_ci, "compile-check", "--app", *packages, "--ref", sha, *self.extra]

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


class Train:
    def __init__(self, git: Git, compiler: Compiler, remote: str, onto: str, run_id: str, dry_run: bool,
                 bookkeeping: bool, echo: Callable[[str], None]):
        self.git, self.compiler, self.remote, self.onto = git, compiler, remote, onto
        self.run_id, self.dry_run, self.bookkeeping, self.echo = run_id, dry_run, bookkeeping, echo
        self.compiles: list[dict] = []
        self.scratch: list[str] = []
        self.green: set[str] = set()

    # -- inputs ----------------------------------------------------------------------------------------
    def fetch_base(self) -> str:
        self.git.run("fetch", "--quiet", self.remote, f"+refs/heads/{self.onto}:refs/remotes/{self.remote}/{self.onto}")
        base = self.git.resolve(f"refs/remotes/{self.remote}/{self.onto}")
        if not base:
            raise TrainError(f"no branch {self.onto} on {self.remote}")
        return base

    def candidates(self, base: str, refs: Sequence[str]) -> list[Candidate]:
        found: list[Candidate] = []
        seen: set[str] = set()
        for ref in refs:
            tip = self.git.resolve(ref)
            if tip is None:
                self.git.run("fetch", "--quiet", self.remote, ref)
                tip = self.git.resolve("FETCH_HEAD")
            if tip is None:
                raise TrainError(f"no commit {ref}")
            listed = self.git.out("rev-list", "--reverse", "--no-merges", "--cherry-pick", "--right-only",
                                  f"{base}...{tip}")
            for sha in listed.split():
                if sha not in seen:
                    seen.add(sha)
                    found.append(Candidate(sha, ref, self.git.out("log", "-1", "--format=%s", sha)))
        return found

    # -- the fleet -------------------------------------------------------------------------------------
    def publish(self, tip: str) -> None:
        ref = f"{SCRATCH_PREFIX}/{self.run_id}-{len(self.scratch) + 1}"
        self.git.run("push", "--quiet", self.remote, f"{tip}:{ref}")
        self.scratch.append(ref)

    def compile(self, sha: str, why: str) -> Verdict:
        if sha in self.green:
            return Verdict(GREEN, 0, None, ("known green",))
        self.echo(f"  compile {sha[:12]} ({why})")
        verdict = self.compiler.compile(sha)
        self.compiles.append({"sha": sha, "why": why, "verdict": verdict.result, "code": verdict.code,
                              "job": verdict.job, "lines": list(verdict.lines)})
        self.echo(f"  {sha[:12]}: {verdict.result}" + (f" (job {verdict.job})" if verdict.job else ""))
        if verdict.result == GREEN:
            self.green.add(sha)
        return verdict

    def cleanup(self) -> None:
        if self.scratch:
            self.git.run("push", "--quiet", self.remote, "--delete", *self.scratch, check=False)

    # -- the train -------------------------------------------------------------------------------------
    def stack(self, onto: str, pending: list[Candidate], rejected: list[Rejection]) -> list[Stacked]:
        stacked: list[Stacked] = []
        tip = onto
        dropped_sources: dict[str, str] = {}
        for candidate in pending:
            if candidate.source in dropped_sources:
                rejected.append(Rejection(candidate, dropped_sources[candidate.source]))
                continue
            picked = self.git.pick(tip, candidate.sha)
            if picked is None:
                reason = f"does not apply on {tip[:12]}"
                rejected.append(Rejection(candidate, reason))
                dropped_sources[candidate.source] = f"follows {candidate.sha[:12]}, which {reason}"
                continue
            if self.git.tree(picked) == self.git.tree(tip):
                self.echo(f"  skip {candidate.sha[:12]}: already on the target")
                continue
            stacked.append(Stacked(candidate, picked))
            tip = picked
        return stacked

    def run(self, base: str, pending: list[Candidate]) -> tuple[str, list[Stacked], list[Rejection], int]:
        """(green tip, landed, rejected, exit code) from fleet verdicts; pushes nothing to the target."""
        green_tip, landed, rejected = base, [], []
        while pending:
            stack = self.stack(green_tip, pending, rejected)
            if not stack:
                break
            self.publish(stack[-1].sha)
            verdict = self.compile(stack[-1].sha, f"stack of {len(stack)}")
            if verdict.result == GREEN:
                return stack[-1].sha, landed + stack, rejected, EXIT_REJECTED if rejected else EXIT_OK
            if verdict.result == NO_VERDICT:
                return green_tip, landed, rejected, EXIT_NO_VERDICT
            good, bad, red = -1, len(stack) - 1, verdict  # stack[good] (green_tip at -1) green, stack[bad] red
            while bad - good > 1:
                mid = (good + bad) // 2
                verdict = self.compile(stack[mid].sha, f"bisect {mid + 1} of {len(stack)}")
                if verdict.result == NO_VERDICT:
                    return (stack[good].sha if good >= 0 else green_tip), landed + stack[:good + 1], rejected, \
                        EXIT_NO_VERDICT
                if verdict.result == GREEN:
                    good = mid
                else:
                    bad, red = mid, verdict
            if bad == 0 and green_tip not in self.green:
                verdict = self.compile(green_tip, "target tip")
                if verdict.result != GREEN:
                    self.echo(f"move-train: the target tip {green_tip[:12]} is {verdict.result}; nothing lands")
                    return green_tip, [], rejected, EXIT_BASE_RED if verdict.result == RED else EXIT_NO_VERDICT
            culprit = stack[bad].candidate
            rejected.append(Rejection(culprit, f"first red commit: compile red at {stack[bad].sha[:12]}"
                                               + (f" (job {red.job})" if red.job else "")))
            landed += stack[:bad]
            green_tip = stack[bad - 1].sha if bad > 0 else green_tip
            reason = f"follows bad commit {culprit.sha[:12]}"
            rest = []
            for item in stack[bad + 1:]:
                if item.candidate.source == culprit.source:
                    rejected.append(Rejection(item.candidate, reason))
                else:
                    rest.append(item.candidate)
            pending = rest
        return green_tip, landed, rejected, EXIT_REJECTED if rejected else EXIT_OK

    def bookkeep(self, tip: str) -> str:
        """The app-size cap and arch ratchet recorded on top of tip, as one commit; tip when nothing changed."""
        if not self.bookkeeping:
            return tip
        scratch = Path(tempfile.mkdtemp(prefix="move-train-"))
        worktree = scratch / "tree"
        self.git.run("worktree", "add", "--quiet", "--detach", str(worktree), tip)
        try:
            tree = Git(worktree)
            steps = []
            if (worktree / APP_SIZE).is_file():
                steps.append(["bash", APP_SIZE, "--update-baseline", str(worktree)])
            if (worktree / ARCH_RATCHET).is_file():
                steps.append([sys.executable, ARCH_RATCHET, "--repo", str(worktree), "--update", "--rev", "HEAD",
                              "--upstream", f"{self.remote}/{self.onto}"])
            for step in steps:
                proc = subprocess.run(step, cwd=worktree, capture_output=True, text=True)
                if proc.returncode != 0:
                    self.echo(f"  bookkeeping skipped: {step[1]} exited {proc.returncode}: "
                              f"{(proc.stderr or proc.stdout).strip()[-400:]}")
                    return tip
            paths = set(tree.out("diff", "--name-only", "HEAD").splitlines())
            if not paths:
                return tip
            if not paths <= set(BOOKKEEPING_FILES):
                self.echo(f"  bookkeeping skipped: it changed {sorted(paths - set(BOOKKEEPING_FILES))}")
                return tip
            tree.run("add", "--", *sorted(paths))
            tree.run("commit", "--quiet", "-m", "move-train: lower the app-size cap and record the arch ratchet\n\n"
                     f"After the green stack {tip[:12]} (run {self.run_id}); data files only, not compiled.")
            return tree.out("rev-parse", "HEAD")
        finally:
            self.git.run("worktree", "remove", "--force", str(worktree), check=False)
            shutil.rmtree(scratch, ignore_errors=True)

    def land(self, base: str, tip: str) -> int:
        remote_tip = self.git.run("ls-remote", self.remote, f"refs/heads/{self.onto}").stdout.split()
        if not remote_tip or remote_tip[0] != base:
            self.echo(f"move-train: {self.onto} moved since {base[:12]}; nothing landed, rerun the train")
            return EXIT_TARGET_MOVED
        pushed = self.git.run("push", "--quiet", self.remote, f"{tip}:refs/heads/{self.onto}", check=False)
        if pushed.returncode != 0:
            self.echo(f"move-train: the push to {self.onto} was refused (it moved?); nothing landed, rerun the train\n"
                      f"  {pushed.stderr.strip()}")
            return EXIT_TARGET_MOVED
        return EXIT_OK


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
        refs = list(args.refs)
        if args.from_file:
            text = Path(args.from_file).read_text()
            refs += [line.split("#", 1)[0].strip() for line in text.splitlines() if line.split("#", 1)[0].strip()]
        if not refs:
            raise TrainError("no REF given: name the ready commits or branches")
        repo = Path(args.repo or subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True,
                                                text=True).stdout.strip() or ".").resolve()
        git = Git(repo)
        run_id = args.run_id or time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + f"-{os.getpid()}"
        compiler = compiler or FleetCompiler(cmux_ci, args.package or DEFAULT_PACKAGES, args.timeout,
                                             args.queue_timeout, echo)
        train = Train(git, compiler, args.remote, args.onto, run_id, args.dry_run, not args.no_bookkeeping, echo)
        base = train.fetch_base()
        found = train.candidates(base, refs)
        pending, waiting = found[:args.max], found[args.max:]
        echo(f"move-train {run_id}: {len(pending)} commit(s) onto {args.onto} at {base[:12]}"
             + (f", {len(waiting)} wait for the next train" if waiting else "") + (" (dry run)" if args.dry_run else ""))
        try:
            tip, landed, rejected, code = train.run(base, pending)
            final, pushed = tip, False
            if landed:
                final = train.bookkeep(tip)
                if not args.dry_run:
                    landing = train.land(base, final)
                    pushed = landing == EXIT_OK
                    code = landing if landing != EXIT_OK else code
        finally:
            train.cleanup()
    except TrainError as error:
        print(f"move-train: {error}", file=sys.stderr)
        return error.code

    verb = "would land" if args.dry_run else ("landed" if pushed else "did not land")
    echo(f"move-train: {verb} {len(landed)} of {len(pending)} onto {args.onto}"
         + (f" at {final[:12]}" if landed else ""))
    for item in landed:
        echo(f"  landed   {item.candidate.sha[:12]} -> {item.sha[:12]} {item.candidate.subject}")
    for rejection in rejected:
        echo(f"  rejected {rejection.candidate.sha[:12]} {rejection.candidate.subject}: {rejection.reason}")
    for candidate in waiting:
        echo(f"  waiting  {candidate.sha[:12]} {candidate.subject}")
    receipt = Path(args.receipt) if args.receipt else repo / "artifacts" / "move-train" / f"{run_id}.json"
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps({
        "run": run_id, "onto": args.onto, "remote": args.remote, "base": base, "dry_run": args.dry_run,
        "exit": code, "pushed": pushed, "green_tip": tip, "landed_tip": final if landed else None,
        "landed": [{"source": i.candidate.source, "sha": i.candidate.sha, "landed_sha": i.sha,
                    "subject": i.candidate.subject} for i in landed],
        "rejected": [{"source": r.candidate.source, "sha": r.candidate.sha, "subject": r.candidate.subject,
                      "reason": r.reason} for r in rejected],
        "waiting": [c.sha for c in waiting], "compiles": train.compiles,
    }, indent=2) + "\n")
    echo(f"move-train: receipt {receipt}")
    return code


if __name__ == "__main__":
    sys.exit(main())

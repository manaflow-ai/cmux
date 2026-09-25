#!/usr/bin/env python3
"""Bisect SwiftPM package test failures across main's history on CI.

Old commits carry old CI scripts, so a plain `ref` dispatch of test-ios.yml
fails before the tests run. Each probe instead pushes a temporary branch:
the probed commit's tree with today's iOS CI files laid over it and the
package-lint gate dropped (old sources fail today's lint baseline). The
package suite then runs exactly as it does now.

    package_bisect.py start --package CmuxMobileShell --points 6 GOOD..BAD
    package_bisect.py start --package CmuxMobileShell SHA [SHA ...]
    package_bisect.py adopt SHA RUN_ID     # count a run that already exists
    package_bisect.py status [--wait]      # failure matrix + per-test windows
    package_bisect.py next [--dispatch]    # midpoints that split each break window
    package_bisect.py cleanup              # delete the probe branches

Add --bisect NAME to run a second experiment beside the first, for example
the same commits with `start --patch <fix>` applied to get past a hang.

State lives in <git-common-dir>/package-bisect/<package>.json, so every
worktree of one checkout shares a bisect; finished job logs are cached beside
it per run attempt, so `status --refetch` re-reads a rerun but not an old log. Probes leave the runner on `auto`
(owned minis first, Blacksmith overflow).
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

REPO = "manaflow-ai/cmux"
REMOTE_URL = f"git@github.com:{REPO}.git"
WORKFLOW = "test-ios.yml"
WORKFLOW_PATH = ".github/workflows/test-ios.yml"
PACKAGE_JOB = "mobile-core-package"
BRANCH_PREFIX = "bisect/"
# Everything the package job runs from its checkout, taken from the CI base.
OVERLAY_PATHS = (WORKFLOW_PATH, "scripts/ci", "scripts/select-ci-xcode.sh")
LINT_GATE = "&& (needs.package-conventions-lint.result == 'success'"
# History that can change an iOS package test result.
DEFAULT_PATHS = ("Packages/iOS", "Packages/Shared")

SWIFT_TESTING_RESULT = re.compile(r"(?P<mark>[✔✘]) Test (?P<name>.+?) (?P<verdict>passed|failed) after ")
XCTEST_RESULT = re.compile(r"Test Case '-\[\S+ (?P<name>\w+)\]' (?P<verdict>passed|failed)")
RUN_SUMMARY = re.compile(r"Test run with (?P<tests>\d+) tests?")
RUN_URL = re.compile(r"/actions/runs/(?P<id>\d+)")


def run(*args: str, input: str | None = None, env: dict | None = None) -> str:
    result = subprocess.run(
        args, input=input, env=env, text=True, capture_output=True
    )
    if result.returncode != 0:
        raise SystemExit(f"{' '.join(args[:4])} failed: {result.stderr.strip()}")
    return result.stdout


def git(*args: str, **kwargs) -> str:
    return run("git", *args, **kwargs)


def gh_json(*args: str):
    return json.loads(run("gh", *args))


# --- log parsing -----------------------------------------------------------


def test_name(raw: str) -> str:
    """`foo(bar:)` and `foo()` both name test `foo`; display names stay whole."""
    raw = raw.strip()
    if raw.startswith('"'):
        return raw
    return raw.split("(", 1)[0]


@dataclasses.dataclass
class Results:
    failed: set[str]
    passed: set[str]
    # False when the log never reached its "Test run with" summary: the job
    # hung or timed out, and tests after that point never ran.
    complete: bool


def test_results(log: str) -> Results | None:
    """Every test the log reports, or None when no test ran at all."""
    failed, passed = set(), set()
    for match in SWIFT_TESTING_RESULT.finditer(log):
        name = test_name(match["name"])
        if name.startswith("run with "):
            continue
        (failed if match["verdict"] == "failed" else passed).add(name)
    for match in XCTEST_RESULT.finditer(log):
        (failed if match["verdict"] == "failed" else passed).add(match["name"])
    complete = RUN_SUMMARY.search(log) is not None
    if not failed and not passed and not complete:
        return None
    # A parameterized test can pass one case and fail another.
    return Results(failed=failed, passed=passed - failed, complete=complete)


# --- state -----------------------------------------------------------------


@dataclasses.dataclass
class Probe:
    sha: str
    branch: str
    run_id: int | None = None
    # "pending", "done", or "error" (no test ran: compile or runner).
    status: str = "pending"
    failures: list[str] = dataclasses.field(default_factory=list)
    passes: list[str] = dataclasses.field(default_factory=list)
    complete: bool = False

    def result(self, test: str) -> bool | None:
        """True failed, False passed, None not run (or probe unfinished)."""
        if self.status != "done":
            return None
        if test in self.failures:
            return True
        return False if test in self.passes else None


@dataclasses.dataclass
class State:
    name: str
    package: str
    test_filter: str
    ci_base: str
    history: list[str]  # main's first-parent commits, oldest first
    candidates: list[str]  # the history commits that touch the watched paths
    probes: dict[str, Probe]
    # Commits whose changes are applied to every probe, e.g. a fix for a hang
    # that stops older commits from running the whole suite.
    patches: list[str] = dataclasses.field(default_factory=list)

    @classmethod
    def path(cls, name: str) -> Path:
        common = Path(git("rev-parse", "--git-common-dir").strip()).resolve()
        return common / "package-bisect" / f"{name}.json"

    @classmethod
    def load(cls, name: str) -> "State":
        path = cls.path(name)
        if not path.exists():
            raise SystemExit(f"no bisect named {name}; run `start` first")
        data = json.loads(path.read_text())
        data.setdefault("name", name)
        data["probes"] = {k: Probe(**v) for k, v in data["probes"].items()}
        return cls(**data)

    def save(self) -> None:
        """Write atomically, keeping probes another invocation added meanwhile."""
        path = self.path(self.name)
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            on_disk = json.loads(path.read_text()).get("probes", {})
            for sha, probe in on_disk.items():
                mine = self.probes.get(sha)
                # The newer dispatch or adoption of a commit has the higher run id.
                if mine is None or (probe.get("run_id") or 0) > (mine.run_id or 0):
                    self.probes[sha] = Probe(**probe)
        scratch = path.with_suffix(f".{os.getpid()}.tmp")
        scratch.write_text(json.dumps(dataclasses.asdict(self), indent=2) + "\n")
        scratch.replace(path)

    def ordered(self) -> list[Probe]:
        index = {sha: i for i, sha in enumerate(self.history)}
        return sorted(self.probes.values(), key=lambda p: index.get(p.sha, -1))


# --- probing ---------------------------------------------------------------


def drop_lint_gate(workflow: str) -> str:
    start = workflow.index(f"\n  {PACKAGE_JOB}:")
    body = workflow[start:]
    if LINT_GATE not in body:
        raise SystemExit(f"{WORKFLOW_PATH}: {PACKAGE_JOB} lint gate not found")
    return workflow[:start] + body.replace(LINT_GATE, "&& (true", 1)


def probe_commit(sha: str, ci_base: str, patches: list[str] = ()) -> str:
    """Commit `sha`'s tree with the CI base's iOS CI files, without a checkout."""
    with tempfile.TemporaryDirectory() as scratch:
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(scratch) / "index")}
        git("read-tree", sha, env=env)
        for patch in patches:
            if subprocess.run(["git", "merge-base", "--is-ancestor", patch, sha]).returncode == 0:
                continue  # already in this commit
            diff = git("diff", "--binary", f"{patch}^", patch)
            applied = subprocess.run(
                ["git", "apply", "--cached", "-3"], input=diff, env=env, text=True, capture_output=True
            )
            if applied.returncode != 0:
                raise SystemExit(f"patch {patch[:10]} does not apply to {sha[:10]}: {applied.stderr.strip()}")
        entries = git("ls-tree", "-r", ci_base, "--", *OVERLAY_PATHS)
        git("update-index", "--index-info", input=entries, env=env)
        workflow = git("show", f"{ci_base}:{WORKFLOW_PATH}")
        blob = git("hash-object", "-w", "--stdin", input=drop_lint_gate(workflow)).strip()
        git("update-index", "--cacheinfo", f"100644,{blob},{WORKFLOW_PATH}", env=env)
        tree = git("write-tree", env=env).strip()
    message = f"bisect probe: {sha[:12]} with iOS CI from {ci_base[:12]} (temporary)"
    return git("commit-tree", tree, "-p", sha, "-m", message).strip()


def dispatch(state: State, sha: str) -> Probe:
    branch = f"{BRANCH_PREFIX}{state.name}/{sha[:10]}"
    commit = probe_commit(sha, state.ci_base, state.patches)
    git("push", "-q", "-f", REMOTE_URL, f"{commit}:refs/heads/{branch}")
    args = ["gh", "workflow", "run", WORKFLOW, "--repo", REPO, "--ref", branch,
            "-f", f"swift_package={state.package}"]
    if state.test_filter:
        args += ["-f", f"test_filter={state.test_filter}"]
    match = RUN_URL.search(run(*args))
    probe = Probe(sha=sha, branch=branch, run_id=int(match["id"]) if match else None)
    state.probes[sha] = probe
    state.save()  # a later probe's failure must not orphan this branch and run
    print(f"{sha[:10]} -> {branch} run {probe.run_id}")
    return probe


def log_cache(run_id: int, attempt: int) -> Path:
    common = Path(git("rev-parse", "--git-common-dir").strip()).resolve()
    return common / "package-bisect" / "logs" / f"{run_id}-{attempt}.log"


def package_job_log(run_id: int) -> tuple[str, str]:
    """(status, log) for the run's latest attempt.

    One cheap run lookup finds the attempt; its job log is downloaded once and
    cached, because the REST budget is shared. A rerun is a new attempt, so it
    never reads the previous attempt's log. A cancelled job (a job timeout
    reports as cancelled) still has partial results worth reading.
    """
    jobs = gh_json("run", "view", str(run_id), "--repo", REPO, "--json", "status,attempt,jobs")
    job = next((j for j in jobs["jobs"] if j["name"] == PACKAGE_JOB), None)
    if jobs["status"] != "completed" or job is None:
        return jobs["status"], ""
    if job["conclusion"] == "skipped" or not job.get("steps"):
        return "error", ""
    cached = log_cache(run_id, jobs.get("attempt", 1))
    if cached.exists():
        return "completed", cached.read_text()
    log = run("gh", "api", "--allow-escape-sequences", f"repos/{REPO}/actions/jobs/{job['databaseId']}/logs")
    cached.parent.mkdir(parents=True, exist_ok=True)
    cached.write_text(log)
    return "completed", log


def refresh(state: State, refetch: bool = False) -> None:
    for probe in state.probes.values():
        if probe.run_id is None or (probe.status != "pending" and not refetch):
            continue
        try:
            status, log = package_job_log(probe.run_id)
        except SystemExit as error:  # e.g. the shared REST budget ran out
            print(f"skipping run {probe.run_id} for now: {error}", file=sys.stderr)
            continue
        if status == "error":
            probe.status = "error"
        elif status == "completed":
            results = test_results(log)
            probe.status = "error" if results is None else "done"
            probe.failures = sorted(results.failed) if results else []
            probe.passes = sorted(results.passed) if results else []
            probe.complete = bool(results and results.complete)
    state.save()


# --- analysis --------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Verdict:
    """A test's failures form one contiguous run of probes, or it is flaky."""

    flaky: bool
    # The probe pairs around the run: (last pass, first fail) where it broke,
    # (last fail, first pass) where it was fixed. None past either end.
    broke: tuple[str, str] | None = None
    fixed: tuple[str, str] | None = None


def verdicts(state: State) -> dict[str, Verdict]:
    """Judge each failing test only on the probes that actually ran it."""
    done = [p for p in state.ordered() if p.status == "done"]
    result = {}
    for test in sorted({t for p in done for t in p.failures}):
        ran = [(p, p.result(test)) for p in done if p.result(test) is not None]
        marks = [failed for _, failed in ran]
        first = marks.index(True)
        last = len(marks) - 1 - marks[::-1].index(True)
        if not all(marks[first : last + 1]):
            result[test] = Verdict(flaky=True)
            continue
        broke = (ran[first - 1][0].sha, ran[first][0].sha) if first > 0 else None
        fixed = (ran[last][0].sha, ran[last + 1][0].sha) if last + 1 < len(ran) else None
        result[test] = Verdict(flaky=False, broke=broke, fixed=fixed)
    return result


def open_windows(state: State, include_fixed: bool = False) -> set[tuple[str, str]]:
    found = set()
    for verdict in verdicts(state).values():
        found |= {w for w in (verdict.broke, include_fixed and verdict.fixed) if w}
    return found


def between(state: State, good: str, bad: str) -> list[str]:
    """Commits after `good` up to and excluding `bad` that could change a result."""
    i, j = state.history.index(good), state.history.index(bad)
    watched = set(state.candidates)
    return [sha for sha in state.history[i + 1 : j] if sha in watched]


def print_status(state: State) -> None:
    probes = state.ordered()
    subjects = {}
    for probe in probes:
        subjects[probe.sha] = git("log", "-1", "--format=%ad %s", "--date=format:%m-%d %H:%M", probe.sha).strip()
    for n, probe in enumerate(probes):
        detail = {
            "done": f"{len(probe.failures)} failing, {len(probe.passes)} passing"
            + ("" if probe.complete else ", INCOMPLETE (hung or timed out)"),
            "error": "no test ran",
        }.get(probe.status, "pending")
        print(f"[{n}] {probe.sha[:10]} {subjects[probe.sha][:70]:70} {detail}  run {probe.run_id}")
    found = verdicts(state)
    if not found:
        return
    width = max(len(t) for t in found)
    print(f"\n{'test':{width}}  " + " ".join(f"{n:>2}" for n in range(len(probes))))

    watched = set(state.candidates)

    def describe(verb: str, window: tuple[str, str]) -> str:
        left, right = window
        inside = between(state, left, right)
        if not inside and right in watched:
            return f"{verb} by {right[:10]} {subjects[right][12:72]}"
        suspects = len(inside) + (right in watched)
        return f"{verb} in {left[:10]}..{right[:10]} ({suspects} watched commits)"

    for test, verdict in found.items():
        cells = []
        for probe in probes:
            if probe.status != "done":
                cells.append("?" if probe.status == "pending" else "E")
            else:
                cells.append({True: "X", False: ".", None: "-"}[probe.result(test)])
        if verdict.flaky:
            notes = ["flaky (passes between failures)"]
        else:
            notes = [describe("broken", verdict.broke) if verdict.broke else "failing at the oldest probe"]
            if verdict.fixed:
                notes.append(describe("fixed", verdict.fixed))
        print(f"{test:{width}}  " + " ".join(f"{c:>2}" for c in cells) + "  " + "; ".join(notes))


def next_points(state: State, include_fixed: bool = False) -> list[str]:
    """The unprobed commit nearest the middle of each open window.

    A probe inside the window that answered nothing for the test (an error,
    or a hang before it ran) leaves the window unchanged, so step past it.
    """
    picks = set()
    for left, right in open_windows(state, include_fixed):
        window = between(state, left, right)
        if any(sha in state.probes and state.probes[sha].status == "pending" for sha in window):
            continue  # its answer is on the way
        inside = [sha for sha in window if sha not in state.probes]
        if inside:
            picks.add(inside[len(inside) // 2])
    return sorted(picks, key=state.history.index)


# --- commands --------------------------------------------------------------


def first_parent_history(ci_base: str, paths: list[str] = ()) -> list[str]:
    args = ["rev-list", "--first-parent", "--reverse", ci_base]
    return git(*args, "--", *paths).split() if paths else git(*args).split()


def cmd_start(args) -> None:
    ci_base = git("rev-parse", args.ci_base).strip()
    history = first_parent_history(ci_base)
    candidates = first_parent_history(ci_base, args.paths)
    patches = [git("rev-parse", p).strip() for p in args.patch]
    name = args.bisect or args.package
    state = State(name, args.package, args.filter, ci_base, history, candidates, {}, patches)
    if State.path(name).exists():
        if not args.force:
            raise SystemExit(f"bisect {name} already exists; `cleanup`, --force, or another --bisect name")
        old = State.load(name)
        leftover = sorted({p.branch for p in old.probes.values() if p.branch})
        if leftover:
            print(f"--force: not deleting {len(leftover)} old probe branches: {' '.join(leftover)}", file=sys.stderr)
        State.path(name).unlink()
    on_history = set(history)

    def resolve(spec: str) -> str:
        sha = git("rev-parse", spec).strip()
        if sha not in on_history:
            raise SystemExit(f"{spec} is not on {args.ci_base}'s first-parent history")
        return sha

    shas = []
    for spec in args.commits:
        if ".." in spec:
            good, bad = (resolve(s) for s in spec.split("..", 1))
            span = [good] + [c for c in between(state, good, bad)] + [bad]
            count = min(len(span), max(2, args.points))
            shas += [span[round(i * (len(span) - 1) / (count - 1))] for i in range(count)]
        else:
            shas.append(resolve(spec))
    state.save()
    for sha in dict.fromkeys(shas):
        dispatch(state, sha)


def cmd_adopt(args) -> None:
    state = State.load(args.bisect or args.package)
    sha = git("rev-parse", args.sha).strip()
    if sha not in state.history:
        raise SystemExit(f"{args.sha} is not on the bisect's first-parent history")
    branch = state.probes[sha].branch if sha in state.probes else ""
    state.probes[sha] = Probe(sha=sha, branch=branch, run_id=args.run_id)
    refresh(state)


def cmd_status(args) -> None:
    state = State.load(args.bisect or args.package)
    deadline = time.monotonic() + args.timeout
    refresh(state, args.refetch)
    while args.wait and time.monotonic() < deadline and any(
        p.status == "pending" for p in state.probes.values()
    ):
        time.sleep(60)
        refresh(state)
    print_status(state)


def cmd_next(args) -> None:
    state = State.load(args.bisect or args.package)
    refresh(state)
    picks = next_points(state, args.fixed)
    if not picks:
        print("no open windows: every break is pinned to one commit, flaky, or older than the oldest probe")
    for sha in picks:
        if args.dispatch:
            dispatch(state, sha)
        else:
            print(f"would probe {sha[:10]} {git('log', '-1', '--format=%s', sha).strip()}")
    state.save()


def cmd_cleanup(args) -> None:
    state = State.load(args.bisect or args.package)
    branches = sorted({p.branch for p in state.probes.values() if p.branch})
    failed = [
        b for b in branches
        if subprocess.run(["git", "push", "-q", REMOTE_URL, f":refs/heads/{b}"]).returncode != 0
    ]
    if failed:
        raise SystemExit(f"could not delete {', '.join(failed)}; state kept, rerun cleanup")
    State.path(state.name).unlink()
    print(f"deleted {len(branches)} probe branches and the bisect state")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--package", default="CmuxMobileShell")
    parser.add_argument("--bisect", help="name for this bisect (default: the package); lets experiments coexist")
    sub = parser.add_subparsers(dest="command", required=True)
    start = sub.add_parser("start")
    start.add_argument("commits", nargs="*", help="SHAs or GOOD..BAD ranges")
    start.add_argument("--points", type=int, default=6, help="probes per range")
    start.add_argument("--filter", default="", help="test_filter for the package suite")
    start.add_argument("--ci-base", default="upstream/main", help="where today's CI files come from")
    start.add_argument("--paths", nargs="+", default=list(DEFAULT_PATHS))
    start.add_argument("--force", action="store_true")
    start.add_argument("--patch", action="append", default=[], metavar="SHA",
                       help="apply this commit's change to every probe (repeatable)")
    adopt = sub.add_parser("adopt")
    adopt.add_argument("sha")
    adopt.add_argument("run_id", type=int)
    status = sub.add_parser("status")
    status.add_argument("--wait", action="store_true")
    status.add_argument("--timeout", type=int, default=45 * 60)
    status.add_argument("--refetch", action="store_true", help="re-read every probe's log")
    nxt = sub.add_parser("next")
    nxt.add_argument("--dispatch", action="store_true")
    nxt.add_argument("--fixed", action="store_true", help="also split windows where a test was fixed")
    sub.add_parser("cleanup")
    args = parser.parse_args(argv)
    {"start": cmd_start, "adopt": cmd_adopt, "status": cmd_status, "next": cmd_next, "cleanup": cmd_cleanup}[args.command](args)


if __name__ == "__main__":
    main()

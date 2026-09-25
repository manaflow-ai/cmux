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

State lives in <git-common-dir>/package-bisect/<package>.json, so every
worktree of one checkout shares a bisect. Probes leave the runner on `auto`
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

SWIFT_TESTING_FAILURE = re.compile(r"✘ Test (?P<name>.+?) failed after ")
XCTEST_FAILURE = re.compile(r"Test Case '-\[\S+ (?P<name>\w+)\]' failed")
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


def failed_tests(log: str) -> set[str] | None:
    """Failing test names, or None when the log never reached a test summary."""
    names = {test_name(m["name"]) for m in SWIFT_TESTING_FAILURE.finditer(log)}
    names |= {m["name"] for m in XCTEST_FAILURE.finditer(log)}
    names = {n for n in names if not n.startswith("run with ")}
    if not names and not RUN_SUMMARY.search(log):
        return None
    return names


# --- state -----------------------------------------------------------------


@dataclasses.dataclass
class Probe:
    sha: str
    branch: str
    run_id: int | None = None
    # "pending", "done", or "error" (no test summary: compile or runner).
    status: str = "pending"
    failures: list[str] = dataclasses.field(default_factory=list)


@dataclasses.dataclass
class State:
    package: str
    test_filter: str
    ci_base: str
    history: list[str]  # main's first-parent commits, oldest first
    candidates: list[str]  # the history commits that touch the watched paths
    probes: dict[str, Probe]

    @classmethod
    def path(cls, package: str) -> Path:
        common = Path(git("rev-parse", "--git-common-dir").strip()).resolve()
        return common / "package-bisect" / f"{package}.json"

    @classmethod
    def load(cls, package: str) -> "State":
        path = cls.path(package)
        if not path.exists():
            raise SystemExit(f"no bisect for {package}; run `start` first")
        data = json.loads(path.read_text())
        data["probes"] = {k: Probe(**v) for k, v in data["probes"].items()}
        return cls(**data)

    def save(self) -> None:
        path = self.path(self.package)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(dataclasses.asdict(self), indent=2) + "\n")

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


def probe_commit(sha: str, ci_base: str) -> str:
    """Commit `sha`'s tree with the CI base's iOS CI files, without a checkout."""
    with tempfile.TemporaryDirectory() as scratch:
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(scratch) / "index")}
        git("read-tree", sha, env=env)
        entries = git("ls-tree", "-r", ci_base, "--", *OVERLAY_PATHS)
        git("update-index", "--index-info", input=entries, env=env)
        workflow = git("show", f"{ci_base}:{WORKFLOW_PATH}")
        blob = git("hash-object", "-w", "--stdin", input=drop_lint_gate(workflow)).strip()
        git("update-index", "--cacheinfo", f"100644,{blob},{WORKFLOW_PATH}", env=env)
        tree = git("write-tree", env=env).strip()
    message = f"bisect probe: {sha[:12]} with iOS CI from {ci_base[:12]} (temporary)"
    return git("commit-tree", tree, "-p", sha, "-m", message).strip()


def dispatch(state: State, sha: str) -> Probe:
    branch = f"{BRANCH_PREFIX}{state.package}/{sha[:10]}"
    commit = probe_commit(sha, state.ci_base)
    git("push", "-q", "-f", REMOTE_URL, f"{commit}:refs/heads/{branch}")
    args = ["gh", "workflow", "run", WORKFLOW, "--repo", REPO, "--ref", branch,
            "-f", f"swift_package={state.package}"]
    if state.test_filter:
        args += ["-f", f"test_filter={state.test_filter}"]
    match = RUN_URL.search(run(*args))
    probe = Probe(sha=sha, branch=branch, run_id=int(match["id"]) if match else None)
    state.probes[sha] = probe
    print(f"{sha[:10]} -> {branch} run {probe.run_id}")
    return probe


def package_job_log(run_id: int) -> tuple[str, str]:
    jobs = gh_json("run", "view", str(run_id), "--repo", REPO, "--json", "status,jobs")
    job = next((j for j in jobs["jobs"] if j["name"] == PACKAGE_JOB), None)
    if jobs["status"] != "completed" or job is None:
        return jobs["status"], ""
    if job["conclusion"] in ("skipped", "cancelled"):
        return "error", ""
    log = run("gh", "api", "--allow-escape-sequences", f"repos/{REPO}/actions/jobs/{job['databaseId']}/logs")
    return "completed", log


def refresh(state: State) -> None:
    for probe in state.probes.values():
        if probe.status != "pending" or probe.run_id is None:
            continue
        status, log = package_job_log(probe.run_id)
        if status == "error":
            probe.status = "error"
        elif status == "completed":
            failures = failed_tests(log)
            probe.status = "error" if failures is None else "done"
            probe.failures = sorted(failures or [])
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
    done = [p for p in state.ordered() if p.status == "done"]
    result = {}
    for test in sorted({t for p in done for t in p.failures}):
        marks = [test in p.failures for p in done]
        first = marks.index(True)
        last = len(marks) - 1 - marks[::-1].index(True)
        if not all(marks[first : last + 1]):
            result[test] = Verdict(flaky=True)
            continue
        broke = (done[first - 1].sha, done[first].sha) if first > 0 else None
        fixed = (done[last].sha, done[last + 1].sha) if last + 1 < len(done) else None
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
        detail = {"done": f"{len(probe.failures)} failing", "error": "no test summary"}.get(probe.status, "pending")
        print(f"[{n}] {probe.sha[:10]} {subjects[probe.sha][:70]:70} {detail}  run {probe.run_id}")
    found = verdicts(state)
    if not found:
        return
    width = max(len(t) for t in found)
    print(f"\n{'test':{width}}  " + " ".join(f"{n:>2}" for n in range(len(probes))))

    def describe(verb: str, window: tuple[str, str]) -> str:
        left, right = window
        inside = between(state, left, right)
        if not inside:
            return f"{verb} by {right[:10]} {subjects[right][12:72]}"
        return f"{verb} in {left[:10]}..{right[:10]} ({len(inside) + 1} commits)"

    for test, verdict in found.items():
        cells = []
        for probe in probes:
            if probe.status != "done":
                cells.append("?" if probe.status == "pending" else "E")
            else:
                cells.append("X" if test in probe.failures else ".")
        if verdict.flaky:
            notes = ["flaky (passes between failures)"]
        else:
            notes = [describe("broken", verdict.broke) if verdict.broke else "failing at the oldest probe"]
            if verdict.fixed:
                notes.append(describe("fixed", verdict.fixed))
        print(f"{test:{width}}  " + " ".join(f"{c:>2}" for c in cells) + "  " + "; ".join(notes))


def next_points(state: State, include_fixed: bool = False) -> list[str]:
    picks = set()
    for left, right in open_windows(state, include_fixed):
        inside = between(state, left, right)
        if inside:
            picks.add(inside[len(inside) // 2])
    return sorted(picks - set(state.probes), key=state.history.index)


# --- commands --------------------------------------------------------------


def first_parent_history(ci_base: str, paths: list[str] = ()) -> list[str]:
    args = ["rev-list", "--first-parent", "--reverse", ci_base]
    return git(*args, "--", *paths).split() if paths else git(*args).split()


def cmd_start(args) -> None:
    ci_base = git("rev-parse", args.ci_base).strip()
    history = first_parent_history(ci_base)
    candidates = first_parent_history(ci_base, args.paths)
    state = State(args.package, args.filter, ci_base, history, candidates, {})
    if State.path(args.package).exists() and not args.force:
        raise SystemExit("a bisect already exists for this package; `cleanup` or --force")
    shas = []
    for spec in args.commits:
        if ".." in spec:
            good, bad = (git("rev-parse", s).strip() for s in spec.split("..", 1))
            span = [good] + git(
                "rev-list", "--first-parent", "--reverse", f"{good}..{bad}", "--", *args.paths
            ).split()
            step = max(1, (len(span) - 1) // max(1, args.points - 1))
            shas += span[::step] + [span[-1]]
        else:
            sha = git("rev-parse", spec).strip()
            if sha not in history:
                raise SystemExit(f"{spec} is not on {args.ci_base}'s first-parent history")
            shas.append(sha)
    for sha in dict.fromkeys(shas):
        dispatch(state, sha)
    state.save()


def cmd_adopt(args) -> None:
    state = State.load(args.package)
    sha = git("rev-parse", args.sha).strip()
    if sha not in state.history:
        raise SystemExit(f"{args.sha} is not on the bisect's first-parent history")
    state.probes[sha] = Probe(sha=sha, branch="", run_id=args.run_id)
    refresh(state)


def cmd_status(args) -> None:
    state = State.load(args.package)
    deadline = time.monotonic() + args.timeout
    refresh(state)
    while args.wait and time.monotonic() < deadline and any(
        p.status == "pending" for p in state.probes.values()
    ):
        time.sleep(60)
        refresh(state)
    print_status(state)


def cmd_next(args) -> None:
    state = State.load(args.package)
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
    state = State.load(args.package)
    for probe in state.probes.values():
        if probe.branch:
            subprocess.run(["git", "push", "-q", REMOTE_URL, f":refs/heads/{probe.branch}"])
    State.path(args.package).unlink()
    print(f"deleted {len(state.probes)} probe branches and the bisect state")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--package", default="CmuxMobileShell")
    sub = parser.add_subparsers(dest="command", required=True)
    start = sub.add_parser("start")
    start.add_argument("commits", nargs="*", help="SHAs or GOOD..BAD ranges")
    start.add_argument("--points", type=int, default=6, help="probes per range")
    start.add_argument("--filter", default="", help="test_filter for the package suite")
    start.add_argument("--ci-base", default="upstream/main", help="where today's CI files come from")
    start.add_argument("--paths", nargs="+", default=list(DEFAULT_PATHS))
    start.add_argument("--force", action="store_true")
    adopt = sub.add_parser("adopt")
    adopt.add_argument("sha")
    adopt.add_argument("run_id", type=int)
    status = sub.add_parser("status")
    status.add_argument("--wait", action="store_true")
    status.add_argument("--timeout", type=int, default=45 * 60)
    nxt = sub.add_parser("next")
    nxt.add_argument("--dispatch", action="store_true")
    nxt.add_argument("--fixed", action="store_true", help="also split windows where a test was fixed")
    sub.add_parser("cleanup")
    args = parser.parse_args(argv)
    {"start": cmd_start, "adopt": cmd_adopt, "status": cmd_status, "next": cmd_next, "cleanup": cmd_cleanup}[args.command](args)


if __name__ == "__main__":
    main()

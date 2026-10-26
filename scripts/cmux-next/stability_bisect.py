#!/usr/bin/env python3
"""Find the feat-cmux-next merge that brought a stability signature (plans/cmux-next/chrome-parity/p10-stability.md,
task 005).

A binary search over the first-parent commits of GOOD..BAD, as ClusterFuzz's regression task does for a crash state
(src/clusterfuzz/_internal/bot/tasks/utasks/regression_task.py) and Chromium's tools/bisect-builds.py does for a
bug: test the commits that already have a build first, build only where none exists, and skip a commit whose build
fails (ClusterFuzz's "bad build"). Each tested commit replays the finding N times (default 3):

  N of N reproduce   the commit is bad      0 of N, every run clean   the commit is good
  1..N-1 reproduce   flaky: the bisect stops and blames no commit

A replay reproduces when the replay's reports give the signature's hash12 (crash_signature.py, task 002). A run that
failed another way (another signature, or no report) is neither this bug nor a clean run: a commit with no hit and
such a run cannot be judged and is skipped, like `git bisect skip`. Replays:

  repro:NAME             scripts/fuzz/macos-matrix/repros/NAME.jsonl in a Tart VM (os-matrix.sh --suite repro:NAME,
                         vm.sh --replay); the file must be on the runner ref (a landed commit).
  fuzz:SEED:MINUTES      the seeded VM fuzz walk (os-matrix.sh --suite fuzz).
  test:PACKAGE:FILTER    a Swift test id at the commit itself (package-test-lane.sh suite PACKAGE FILTER x N: one
                         build, N runs); a failed run is a reproduction. No app build.

Fleet use (cmux-ci only, never maclease): an app build of a commit is reused when the fleet has one (any done DEV
build of that exact commit), else `cmux-ci build cmux --ref SHA` is submitted once, with a receipt. A wait that
times out waits again on the same job: the bisect never resubmits a job it is waiting for. A step is re-attached by
its key; a new attempt runs only after the step ended with no verdict. At the deadline a step client is stopped
(the step keeps running) and the next run re-attaches to it. Every job id, step key and result is in the state file,
so the same command resumes after a crash, a deadline (exit 75) or a reboot.

    python3 scripts/cmux-next/stability_bisect.py plan --hash12 H --good SHA --bad SHA --replay fuzz:21:30 --os 26
    python3 scripts/cmux-next/stability_bisect.py run  --hash12 H --good SHA --bad SHA --replay fuzz:21:30 --os 26 --post

Exit: 0 a verdict (printed as JSON; --post records first_bad and flaky verdicts with stability_issues.py
bisect-result), 75 not finished yet (rerun the same command), 1 an error, 2 bad arguments.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Protocol

ROOT = Path(__file__).resolve().parents[2]
STATE_SCHEMA = "cmux-stability-bisect/v1"
DEFAULT_RUNS = 3
DEFAULT_INFRA_RETRIES = 2
WAIT_SLICE_SECONDS = 1800
EX_TEMPFAIL = 75
SHA = re.compile(r"^[0-9a-f]{40}$")
HASH12 = re.compile(r"^[0-9a-f]{12}$")
JOB_ID = re.compile(r"^[0-9a-f]{24}$")
STEP_LINE = re.compile(r"cmux-ci: step ([0-9a-f]{24})")
ACTIVE_STATES = {"queued", "leased", "running", "artifact_pending"}
TERMINAL_STATES = {"done", "failed", "cancelled"}
# `cmux-ci run` exits that are the fleet's, not the commit's: no worker (69), queue timeout (75), superseded (76),
# the step ran past its --timeout (124), the client was interrupted (130).
STEP_NO_VERDICT_EXITS = {69, 75, 76, 124, 130}
REPORT_SUFFIXES = (".ips", ".hang")
# fuzz.py writes main-thread hang samples as hang-N.sample.txt / hang-N.live-sample.txt (kind "hang" signatures).
SAMPLE_SUFFIXES = (".sample.txt", "-sample.txt")
TEST_ROW = re.compile(r"^(?P<filter>\S+)\s+(?P<result>passed|failed \(exit \d+\)|stalled/timeout)\s+\d+s\s*$")

GOOD, BAD, FLAKY, UNTESTABLE = "good", "bad", "flaky", "untestable"
HIT, MISS, OTHER = "hit", "miss", "other"


class BisectError(Exception):
    """A bad argument, a range that is not first-parent, or a fleet answer the bisect cannot use."""


class Pending(Exception):
    """The fleet has not answered yet: the state is saved and the same command resumes."""


# --- Replay specs -------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Replay:
    kind: str  # repro, fuzz or test
    name: str = ""
    seed: int = 0
    minutes: int = 0
    package: str = ""
    test_filter: str = ""

    @property
    def needs_app(self) -> bool:
        return self.kind in ("repro", "fuzz")

    @property
    def suite(self) -> str:
        return f"repro:{self.name}" if self.kind == "repro" else "fuzz"

    def text(self) -> str:
        if self.kind == "repro":
            return f"repro:{self.name}"
        if self.kind == "fuzz":
            return f"fuzz:{self.seed}:{self.minutes}"
        return f"test:{self.package}:{self.test_filter}"


def parse_replay(text: str) -> Replay:
    kind, _, rest = text.partition(":")
    if kind == "repro" and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", rest):
        return Replay("repro", name=rest)
    if kind == "fuzz":
        match = re.fullmatch(r"(0|[1-9][0-9]{0,8}):([1-9]|[1-5][0-9]|60)", rest)
        if match:
            return Replay("fuzz", seed=int(match.group(1)), minutes=int(match.group(2)))
    if kind == "test":
        package, _, test_filter = rest.partition(":")
        if (re.fullmatch(r"Packages/[A-Za-z0-9_][A-Za-z0-9_./-]*", package) and ".." not in package
                and re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_./:-]*", test_filter) and test_filter[-1] not in "./"):
            return Replay("test", package=package, test_filter=test_filter)
    if kind == "fuzz-input":
        raise BisectError("fuzz-input replays need a single-input mode in scripts/cmux-next/rust-fuzz.sh "
                          "(p10-stability-017); replay the input as a regression test instead (test:PACKAGE:FILTER)")
    raise BisectError(f"--replay takes repro:NAME, fuzz:SEED:MINUTES (1..60) or test:PACKAGE_DIR:FILTER, got {text!r}")


def test_token(test_filter: str) -> str:
    """The identifier a test filter ends in (CmuxNextAppTests.FooTests/testBar -> testBar), searched at a commit."""
    return re.split(r"[./:]", test_filter)[-1]


# --- Seams --------------------------------------------------------------------------------------------------------


@dataclass
class StepRun:
    code: int
    step: str = ""
    log: str = ""


class Fleet(Protocol):
    def jobs(self, ref: str | None = None) -> list[dict]: ...
    def job(self, job_id: str) -> dict: ...
    def submit_build(self, sha: str, tag: str, workspace: str, receipt: Path) -> str: ...
    def wait(self, job_id: str, timeout: float) -> int: ...
    def os_matrix(self, build_job: str, majors: str, suite: str, seed: int, minutes: int, runner_ref: str,
                  attempt: int, out: Path, timeout: float) -> StepRun: ...
    def run_tests(self, sha: str, package: str, filters: list[str], key: str, timeout: float) -> StepRun: ...
    def signatures(self, paths: list[Path]) -> set[str]: ...
    def post(self, hash12: str, verdict: dict) -> None: ...


class Git:
    def __init__(self, root: Path) -> None:
        self.root = root

    def _git(self, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        proc = subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, text=True, timeout=300)
        if check and proc.returncode != 0:
            raise BisectError(f"git {' '.join(args[:2])} failed: {proc.stderr.strip()[-300:]}")
        return proc

    def commit(self, rev: str) -> str:
        return self._git("rev-parse", "--verify", "--end-of-options", f"{rev}^{{commit}}").stdout.strip()

    def first_parent_range(self, good: str, bad: str) -> list[str]:
        """The first-parent commits after good up to bad, oldest first; good must be on bad's first-parent line."""
        commits = self._git("rev-list", "--first-parent", "--reverse", f"{good}..{bad}", "--").stdout.split()
        if not commits:
            raise BisectError(f"{good[:12]}..{bad[:12]} has no commits (is good newer than bad?)")
        parent = self._git("rev-parse", "--verify", f"{commits[0]}^1", check=False).stdout.strip()
        if parent != good:
            raise BisectError(f"{good[:12]} is not on {bad[:12]}'s first-parent line: pick a feat-cmux-next commit")
        return commits

    def has_file(self, sha: str, path: str) -> bool:
        return self._git("cat-file", "-e", f"{sha}:{path}", check=False).returncode == 0

    def has_word(self, sha: str, word: str, path: str) -> bool:
        return self._git("grep", "-q", "-w", "-F", "-e", word, sha, "--", path, check=False).returncode == 0


class CmuxCi:
    """The real fleet: the cmux-ci client and os-matrix.sh of this checkout. Every call is one bounded process."""

    def __init__(self, root: Path, client: str, repo: str) -> None:
        self.root = root
        self.client = client
        self.repo = repo

    def _ci(self, *args: str, timeout: float = 300) -> subprocess.CompletedProcess:
        try:
            return subprocess.run([self.client, *args], capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise Pending(f"cmux-ci {args[0]} did not answer in {int(timeout)} s") from error
        except OSError as error:
            raise BisectError(f"cannot run {self.client}: {error}") from error

    def _json(self, *args: str) -> object:
        proc = self._ci(*args)
        if proc.returncode != 0:
            raise Pending(f"cmux-ci {' '.join(args)} failed: {proc.stderr.strip()[-300:]}")
        try:
            return json.loads(proc.stdout or "null")
        except json.JSONDecodeError as error:
            raise BisectError(f"cmux-ci {args[0]} printed no JSON: {error}") from error

    def jobs(self, ref: str | None = None) -> list[dict]:
        out = self._json("status", *(["--ref", ref] if ref else []))
        out = out.get("jobs", []) if isinstance(out, dict) else out
        return [job for job in out or [] if isinstance(job, dict)]

    def job(self, job_id: str) -> dict:
        out = self._json("status", job_id)
        if not isinstance(out, dict):
            raise BisectError(f"cmux-ci status {job_id} printed no job")
        return out

    def submit_build(self, sha: str, tag: str, workspace: str, receipt: Path) -> str:
        receipt.parent.mkdir(parents=True, exist_ok=True)
        proc = self._ci("build", "cmux", "--ref", sha, "--tag", tag, "--workspace", workspace,
                        "--agent", "stability-bisect", "--receipt", str(receipt), timeout=900)
        job = read_receipt(receipt)
        if job:
            return job
        if receipt_pending(receipt).exists():
            raise Pending(f"the build submission for {sha[:12]} has an unknown outcome ({receipt_pending(receipt)}): "
                          "reconcile it with `cmux-ci status --ref SHA` before running again")
        raise BisectError(f"cmux-ci build {sha[:12]} was refused: {(proc.stderr or proc.stdout).strip()[-300:]}")

    def wait(self, job_id: str, timeout: float) -> int:
        # Exit 0 done, 1 failed or cancelled, 2 the wait timed out (the job is unchanged).
        proc = self._ci("wait", job_id, "--interval", "30", "--timeout", str(int(max(1, timeout))),
                        timeout=timeout + 120)
        return proc.returncode

    def os_matrix(self, build_job: str, majors: str, suite: str, seed: int, minutes: int, runner_ref: str,
                  attempt: int, out: Path, timeout: float) -> StepRun:
        out.mkdir(parents=True, exist_ok=True)
        argv = [str(self.root / "scripts/cmux-next/os-matrix.sh"), "--build", build_job, "--os", majors,
                "--suite", suite, "--ref", runner_ref, "--attempt", str(attempt), "--out", str(out)]
        if suite == "fuzz":
            argv += ["--seed", str(seed), "--minutes", str(minutes)]
        env = dict(os.environ, CMUX_CI=self.client)
        return run_step(argv, self.root, env, timeout, f"replay step {suite} (attempt {attempt})")

    def run_tests(self, sha: str, package: str, filters: list[str], key: str, timeout: float) -> StepRun:
        argv = [self.client, "run", "--class", "light", "--script", "scripts/ci/package-test-lane.sh",
                "--ref", sha, "--repo", self.repo, "--background", "--key", key, "--arg=suite", f"--arg={package}",
                *[f"--arg={name}" for name in filters]]
        return run_step(argv, self.root, None, timeout, f"test step {key}")

    def signatures(self, paths: list[Path]) -> set[str]:
        script = self.root / "scripts/cmux-next/crash_signature.py"
        if not script.exists():
            raise BisectError("scripts/cmux-next/crash_signature.py (p10-stability-002) is not in this checkout")
        if not paths:
            return set()
        proc = subprocess.run([sys.executable, "-I", str(script), *map(str, paths)], capture_output=True, text=True)
        if proc.returncode == 2:
            raise BisectError(f"crash_signature.py refused its arguments: {proc.stderr.strip()[-300:]}")
        hashes = set()
        for line in proc.stdout.splitlines():
            try:
                value = json.loads(line).get("hash12", "")
            except (json.JSONDecodeError, AttributeError):
                continue
            if HASH12.match(str(value)):
                hashes.add(value)
        return hashes

    def post(self, hash12: str, verdict: dict) -> None:
        script = self.root / "scripts/cmux-next/stability_issues.py"
        if not script.exists():
            raise BisectError("scripts/cmux-next/stability_issues.py (p10-stability-004) is not in this checkout")
        argv = [sys.executable, "-I", str(script), "bisect-result", "--hash12", hash12]
        argv += (["--first-bad", verdict["sha"]] if verdict["result"] == "first_bad" else ["--flaky", verdict["hits"]])
        argv += ["--range", verdict["range"], "--evidence", verdict.get("evidence", "")]
        proc = subprocess.run(argv, capture_output=True, text=True)
        if proc.returncode == EX_TEMPFAIL:
            raise Pending("stability_issues.py deferred the write (GitHub budget); rerun to post")
        if proc.returncode != 0:
            raise BisectError(f"stability_issues.py bisect-result failed: {proc.stderr.strip()[-300:]}")


def run_step(argv: list[str], cwd: Path, env: dict | None, timeout: float, what: str) -> StepRun:
    """Run one foreground fleet step client until it ends or the deadline. At the deadline the client's process
    group gets SIGTERM: outside GitHub Actions cmux-ci leaves the step running, and the same command re-attaches by
    its key on the next run."""
    proc = subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            start_new_session=True)
    try:
        log, _ = proc.communicate(timeout=max(1.0, timeout))
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
        raise Pending(f"{what} has not finished; it keeps running on the fleet and the same command re-attaches")
    return StepRun(proc.returncode, step_id(log), log)


def step_id(log: str) -> str:
    match = STEP_LINE.search(log)
    return match.group(1) if match else ""


def receipt_pending(receipt: Path) -> Path:
    return receipt.with_name(receipt.name + ".pending")


def read_receipt(receipt: Path) -> str:
    try:
        job = str(json.loads(receipt.read_text())["id"])
    except (OSError, ValueError, KeyError, TypeError):
        return ""
    return job if JOB_ID.match(job) else ""


def dev_build(job: dict, sha: str) -> bool:
    """A cmux DEV (Debug) app build of exactly sha: what the VM replays need."""
    variant = str(job.get("variant") or "dev")
    return (job.get("kind") == "cmux" and job.get("ref") == sha and variant == "dev"
            and JOB_ID.match(str(job.get("id"))) is not None)


def pick_build(jobs: list[dict], sha: str) -> dict | None:
    """The fleet build to reuse for sha: the newest done one, else one still running; never a failed one."""
    mine = [job for job in jobs if dev_build(job, sha)]
    for states in ({"done"}, ACTIVE_STATES):
        found = [job for job in mine if job.get("state") in states]
        if found:
            return max(found, key=lambda job: str(job.get("created_at") or job.get("submitted_at") or ""))
    return None


def report_paths(out: Path) -> list[Path]:
    return sorted(path for path in out.rglob("*") if path.is_file()
                  and (path.suffix in REPORT_SUFFIXES or path.name.endswith(SAMPLE_SUFFIXES)
                       or (path.suffix == ".jsonl" and "panic" in path.name)))


def test_results(log: str, filters: list[str]) -> list[str] | None:
    """One hit/miss per run from package-test-lane.sh's suite table, or None when the table is missing or short
    (the package did not build: the commit cannot run the test)."""
    rows = []
    for line in log.splitlines():
        match = TEST_ROW.match(line.strip())
        if match and match.group("filter") == filters[0]:
            rows.append(MISS if match.group("result") == "passed" else HIT)
    return rows[-len(filters):] if len(rows) >= len(filters) else None


# --- The bisect ---------------------------------------------------------------------------------------------------


@dataclass
class Options:
    hash12: str
    good: str
    bad: str
    replay: Replay
    majors: str
    runs: int = DEFAULT_RUNS
    runner_ref: str = ""
    infra_retries: int = DEFAULT_INFRA_RETRIES
    post: bool = False


@dataclass
class Bisect:
    opts: Options
    fleet: Fleet
    git: Git
    state_path: Path
    deadline: float
    clock: Callable[[], float] = time.monotonic
    log: Callable[[str], None] = lambda text: print(f"stability_bisect: {text}", file=sys.stderr)
    state: dict = field(default_factory=dict)
    commits: list[str] = field(default_factory=list)

    # -- state

    def load(self) -> None:
        o = self.opts
        params = {"hash12": o.hash12, "good": o.good, "bad": o.bad, "replay": o.replay.text(), "majors": o.majors,
                  "runs": o.runs}
        if self.state_path.exists():
            try:
                self.state = json.loads(self.state_path.read_text())
            except (OSError, json.JSONDecodeError) as error:
                raise BisectError(f"cannot read {self.state_path}: {error}") from error
            if self.state.get("schema") != STATE_SCHEMA or self.state.get("params") != params:
                raise BisectError(f"{self.state_path} holds another bisect ({self.state.get('params')}); "
                                  "pass another --state")
        else:
            self.state = {"schema": STATE_SCHEMA, "params": params, "runner_ref": o.runner_ref, "builds": {},
                          "replays": {}, "results": {}, "verdict": None, "posted": False}
        # The VM step keys hold the runner ref: the first run fixes it, so a resumed run re-attaches its steps.
        self.state["runner_ref"] = self.state.get("runner_ref") or o.runner_ref
        self.commits = self.git.first_parent_range(o.good, o.bad)

    def save(self) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.state_path.with_name(self.state_path.name + ".tmp")
        tmp.write_text(json.dumps(self.state, indent=1, sort_keys=True) + "\n")
        tmp.replace(self.state_path)

    @property
    def work(self) -> Path:
        return self.state_path.with_suffix("")

    # -- fleet jobs

    def remaining(self, what: str) -> float:
        remaining = self.deadline - self.clock()
        if remaining <= 0:
            raise Pending(f"{what}: out of time; rerun the same command to continue")
        return remaining

    def await_job(self, job_id: str, what: str) -> str:
        """Wait for one job until it ends: 'done' or 'failed'. A wait timeout waits again on the same job."""
        while True:
            remaining = self.deadline - self.clock()
            if remaining <= 0:
                raise Pending(f"{what} (job {job_id}) has not finished; rerun the same command to wait again")
            code = self.fleet.wait(job_id, min(remaining, WAIT_SLICE_SECONDS))
            if code == 0:
                return "done"
            if code == 1:
                # Exit 1 is also a client error (an HTTP 4xx): only the job's own end state is a failure.
                state = self.fleet.job(job_id).get("state")
                if state in TERMINAL_STATES:
                    return "done" if state == "done" else "failed"
                raise Pending(f"cmux-ci wait {job_id} exited 1 while the job is {state}; rerun to wait again")
            if code != 2:
                raise Pending(f"cmux-ci wait {job_id} exited {code}; rerun the same command to wait again")
            self.log(f"{what}: still running (job {job_id}); waiting again, not resubmitting")

    def build(self, sha: str) -> str | None:
        """A done DEV build job of sha, or None when the commit does not build."""
        builds = self.state["builds"]
        record = builds.get(sha)
        if record is None:
            found = pick_build(self.fleet.jobs(sha), sha)
            record = {"job": found["id"], "own": False} if found else self.submit(sha)
            builds[sha] = record
            self.save()
        if record.get("result") == "failed":
            return None
        outcome = self.await_job(record["job"], f"build of {sha[:12]}")
        if outcome == "done":
            return record["job"]
        if not record["own"]:
            # Someone else's build failed (a cancel, a worker loss): build it once ourselves before calling it bad.
            self.log(f"reused build {record['job']} of {sha[:12]} failed; submitting one build")
            builds[sha] = {**self.submit(sha), "reused_failed": record["job"]}
            self.save()
            return self.build(sha)
        record["result"] = "failed"
        self.save()
        return None

    def submit(self, sha: str) -> dict:
        receipt = self.work / f"{sha[:12]}-submit.json"
        job = read_receipt(receipt)
        if not job:
            if receipt_pending(receipt).exists():
                raise Pending(f"the build submission for {sha[:12]} has an unknown outcome "
                              f"({receipt_pending(receipt)}): reconcile it with `cmux-ci status --ref {sha}`")
            tag = f"bisect-{self.opts.hash12}-{sha[:10]}"
            job = self.fleet.submit_build(sha, tag, f"stability-bisect-{self.opts.hash12}", receipt)
            self.log(f"submitted build {job} of {sha[:12]} (tag {tag})")
        return {"job": job, "own": True}

    def settle_step(self, run: StepRun, what: str) -> bool:
        """After a step gave no verdict: True when it is still queued or running (it was waited for and the same
        command re-attaches), False when it ended without one (a new attempt may run)."""
        if not run.step:
            return False
        state = self.fleet.job(run.step).get("state")
        if state in ACTIVE_STATES:
            self.await_job(run.step, what)
            return True
        return False

    # -- replays

    def replay(self, sha: str) -> list[str] | None:
        """N hit/miss results at sha, or None when the commit cannot run the replay."""
        o = self.opts
        record = self.state["replays"].setdefault(sha, {"results": [], "attempt": 1, "no_verdict": 0})
        if o.replay.kind == "test":
            return self.replay_test(sha, record)
        build = self.build(sha)
        if build is None:
            record["why"] = "the app build failed"
            return None
        while len(record["results"]) < o.runs:
            attempt = record["attempt"]
            what = f"replay {len(record['results']) + 1}/{o.runs} at {sha[:12]} (attempt {attempt})"
            out = self.work / f"{sha[:12]}-a{attempt}"
            run = self.fleet.os_matrix(build, o.majors, o.replay.suite, o.replay.seed, o.replay.minutes,
                                       self.state["runner_ref"], attempt, out, self.remaining(what))
            if run.code == 2:
                raise BisectError(f"os-matrix.sh refused the replay: {run.log.strip()[-400:]}")
            if run.code in (0, 1):
                hashes = self.fleet.signatures(report_paths(out))
                result = HIT if o.hash12 in hashes else MISS if run.code == 0 else OTHER
                record["results"].append({"attempt": attempt, "step": run.step, "result": result,
                                          "verdict": "PASS" if run.code == 0 else "FAIL"})
                record["attempt"] += 1
                self.log(f"{what}: {result}")
                self.save()
                continue
            if self.settle_step(run, what):
                continue  # the same attempt again: os-matrix.sh re-attaches to the finished step
            record["no_verdict"] += 1
            record["attempt"] += 1
            self.save()
            if record["no_verdict"] > o.infra_retries:
                record["why"] = f"{record['no_verdict']} replay steps ended without a verdict"
                return None
        return [item["result"] for item in record["results"]]

    def replay_test(self, sha: str, record: dict) -> list[str] | None:
        o = self.opts
        if not self.git.has_word(sha, test_token(o.replay.test_filter), o.replay.package):
            record["why"] = f"{test_token(o.replay.test_filter)} is not in {o.replay.package} at this commit"
            return None
        filters = [o.replay.test_filter] * o.runs
        while not record["results"]:
            attempt = record["attempt"]
            what = f"test replay x{o.runs} at {sha[:12]} (attempt {attempt})"
            key = f"stability-bisect-{o.hash12}-{sha[:12]}-a{attempt}"
            run = self.fleet.run_tests(sha, o.replay.package, filters, key, self.remaining(what))
            results = test_results(run.log, filters)
            if results is not None:
                record["results"] = [{"attempt": attempt, "step": run.step, "result": r} for r in results]
                self.log(f"{what}: {results.count(HIT)}/{o.runs} failed")
                self.save()
                break
            if self.settle_step(run, what):
                continue  # the same key again: cmux-ci re-attaches to the finished step and prints its log
            if run.code not in STEP_NO_VERDICT_EXITS:
                record["why"] = f"the test step exited {run.code} with no suite table (the package does not build)"
                return None
            record["no_verdict"] += 1
            record["attempt"] += 1
            self.save()
            if record["no_verdict"] > o.infra_retries:
                record["why"] = f"{record['no_verdict']} test steps ended without a verdict"
                return None
        return [item["result"] for item in record["results"]]

    def judge(self, sha: str) -> dict:
        results = self.state["results"]
        if sha not in results:
            outcome = self.replay(sha)
            if outcome is None:
                why = self.state["replays"].get(sha, {}).get("why", "")
                results[sha] = {"verdict": UNTESTABLE, "why": why}
            else:
                hits, others, runs = outcome.count(HIT), outcome.count(OTHER), len(outcome)
                if hits == runs:
                    results[sha] = {"verdict": BAD, "hits": f"{hits}/{runs}"}
                elif hits:
                    results[sha] = {"verdict": FLAKY, "hits": f"{hits}/{runs}"}
                elif others:
                    results[sha] = {"verdict": UNTESTABLE, "hits": f"0/{runs}",
                                    "why": f"{others} of {runs} runs failed without {self.opts.hash12}"}
                else:
                    results[sha] = {"verdict": GOOD, "hits": f"0/{runs}"}
            self.save()
            self.log(f"{sha[:12]}: {results[sha]}")
        return results[sha]

    # -- search

    def built(self) -> set[str]:
        """Commits of the range with a done DEV build on the fleet now (one /v1/jobs read)."""
        if not self.opts.replay.needs_app:
            return set()
        wanted = set(self.commits)
        return {job["ref"] for job in self.fleet.jobs() if job.get("state") == "done" and job.get("ref") in wanted
                and dev_build(job, job["ref"])}

    def bounds(self) -> tuple[int, int]:
        """Index of the newest good commit (-1: the good end) and of the oldest bad one."""
        results = self.state["results"]
        good = [i for i, sha in enumerate(self.commits) if results.get(sha, {}).get("verdict") == GOOD]
        bad = [i for i, sha in enumerate(self.commits) if results.get(sha, {}).get("verdict") == BAD]
        lo, hi = max(good, default=-1), min(bad)
        if lo > hi:
            raise BisectError(f"{self.commits[lo][:12]} is good after the bad {self.commits[hi][:12]}: "
                              "the replay does not separate the range")
        return lo, hi

    def run(self) -> dict:
        self.load()
        if self.state["verdict"]:
            return self.finish(self.state["verdict"])
        o = self.opts
        span = f"{o.good}..{o.bad}"
        bad = self.judge(o.bad)
        if bad["verdict"] != BAD:
            return self.finish(self.endpoint_verdict(o.bad, bad, span, "bad"))
        good = self.judge(o.good)
        if good["verdict"] != GOOD:
            return self.finish(self.endpoint_verdict(o.good, good, span, "good"))
        while True:
            lo, hi = self.bounds()
            open_ = [i for i in range(lo + 1, hi) if self.commits[i] not in self.state["results"]]
            if not open_:
                return self.finish(self.conclude(lo, hi, span))
            sha = self.commits[midpoint(open_, lo, hi, self.built(), self.commits)]
            self.log(f"{len(open_)} commits open between {self.at(lo)[:12]} and {self.at(hi)[:12]}; "
                     f"testing {sha[:12]}")
            result = self.judge(sha)
            if result["verdict"] == FLAKY:
                return self.finish({"result": "flaky", "sha": sha, "hits": result["hits"], "range": span,
                                    "evidence": f"{result['hits']} replays at {sha[:12]} reproduced"
                                                + self.steps_text(sha)})

    def at(self, index: int) -> str:
        return self.opts.good if index < 0 else self.commits[index]

    def endpoint_verdict(self, sha: str, result: dict, span: str, end: str) -> dict:
        verdict = result["verdict"]
        if verdict == FLAKY:
            return {"result": "flaky", "sha": sha, "hits": result["hits"], "range": span,
                    "evidence": f"{result['hits']} replays at the {end} end {sha[:12]} reproduced"
                                + self.steps_text(sha)}
        if verdict == UNTESTABLE:
            return {"result": "untestable", "sha": sha, "range": span, "evidence": f"the {end} end: {result['why']}"}
        if end == "bad":
            return {"result": "no_repro", "sha": sha, "range": span,
                    "evidence": f"0/{self.opts.runs} replays at the bad end reproduced" + self.steps_text(sha)}
        return {"result": "bad_at_good", "sha": sha, "range": span,
                "evidence": f"{result['hits']} replays at the good end reproduced: the bug is older than the range"
                            + self.steps_text(sha)}

    def conclude(self, lo: int, hi: int, span: str) -> dict:
        skipped = [self.commits[i] for i in range(lo + 1, hi)]
        first_bad = self.commits[hi]
        if skipped:
            return {"result": "ambiguous", "range": span, "candidates": skipped + [first_bad],
                    "evidence": f"the first bad commit is one of {len(skipped) + 1} after {self.at(lo)[:12]}; "
                                f"{len(skipped)} of them could not run the replay"}
        hits = self.state["results"][first_bad]["hits"]
        parent = self.at(hi - 1)
        return {"result": "first_bad", "sha": first_bad, "range": span,
                "evidence": f"{hits} replays reproduced at {first_bad[:12]}{self.steps_text(first_bad)}, "
                            f"0/{self.opts.runs} at its first parent {parent[:12]}{self.steps_text(parent)}"}

    def steps_text(self, sha: str) -> str:
        steps = [item["step"] for item in self.state["replays"].get(sha, {}).get("results", []) if item.get("step")]
        return f" (steps {', '.join(dict.fromkeys(steps))})" if steps else ""

    def finish(self, verdict: dict) -> dict:
        self.state["verdict"] = verdict
        self.save()
        if self.opts.post and verdict["result"] in ("first_bad", "flaky") and not self.state["posted"]:
            self.fleet.post(self.opts.hash12, verdict)
            self.state["posted"] = True
            self.save()
        return verdict


def midpoint(open_: list[int], lo: int, hi: int, built: set[str], commits: list[str]) -> int:
    """The commit to test next: one with a fleet build in the middle half of the open range when there is one (no
    build to wait for, as bisect-builds.py bisects archived builds), else the one nearest the middle."""
    mid = (lo + hi) / 2
    quarter = (hi - lo) / 4
    ready = [i for i in open_ if commits[i] in built and abs(i - mid) <= quarter]
    pool = ready or open_
    return min(pool, key=lambda i: (abs(i - mid), i))


def plan(opts: Options, fleet: Fleet, git: Git) -> dict:
    """What a run would do, with no submission: the range, the steps a bisect needs, the builds it can reuse."""
    commits = git.first_parent_range(opts.good, opts.bad)
    built = set()
    if opts.replay.needs_app:
        wanted = set(commits) | {opts.good}
        built = {job["ref"] for job in fleet.jobs() if job.get("state") == "done" and job.get("ref") in wanted
                 and dev_build(job, job["ref"])}
    steps = math.ceil(math.log2(len(commits))) if len(commits) > 1 else 0
    return {"range": f"{opts.good}..{opts.bad}", "first_parent_commits": len(commits), "bisect_steps": steps,
            "replays": (steps + 2) * opts.runs, "replay": opts.replay.text(), "majors": opts.majors,
            "reusable_builds": sorted(built), "runner_ref": opts.runner_ref}


# --- CLI ----------------------------------------------------------------------------------------------------------


def options(args: argparse.Namespace, git: Git) -> Options:
    if not HASH12.match(args.hash12):
        raise BisectError(f"--hash12 takes 12 lowercase hex digits, got {args.hash12!r}")
    replay = parse_replay(args.replay)
    if replay.needs_app and not re.fullmatch(r"[0-9]+(,[0-9]+)*", args.os or ""):
        raise BisectError("a VM replay needs --os MAJORS, e.g. --os 26")
    if not 1 <= args.runs <= 10:
        raise BisectError("--runs takes 1..10")
    good, bad = git.commit(args.good), git.commit(args.bad)
    runner_ref = ""
    if replay.needs_app:
        runner_ref = git.commit(args.runner_ref)
        if replay.kind == "repro" and not git.has_file(runner_ref, f"scripts/fuzz/macos-matrix/repros/{replay.name}.jsonl"):
            raise BisectError(f"repros/{replay.name}.jsonl is not on the runner ref {runner_ref[:12]}: land it first")
    return Options(hash12=args.hash12, good=good, bad=bad, replay=replay, majors=args.os or "", runs=args.runs,
                   runner_ref=runner_ref, infra_retries=args.infra_retries, post=getattr(args, "post", False))


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    for name, text in (("plan", "print the range, step count and reusable builds; submit nothing"),
                       ("run", "bisect (resumable: the same command continues from the state file)")):
        cmd = sub.add_parser(name, help=text)
        cmd.add_argument("--hash12", required=True, help="the signature (crash_signature.py)")
        cmd.add_argument("--good", required=True, help="a feat-cmux-next commit without the bug")
        cmd.add_argument("--bad", required=True, help="a later feat-cmux-next commit with it")
        cmd.add_argument("--replay", required=True, help="repro:NAME, fuzz:SEED:MINUTES or test:PACKAGE_DIR:FILTER")
        cmd.add_argument("--os", default="", help="VM replays: macOS majors, e.g. 26")
        cmd.add_argument("--runs", type=int, default=DEFAULT_RUNS, help="replays per commit (default 3)")
        cmd.add_argument("--runner-ref", default="origin/feat-cmux-next",
                         help="VM replays: the landed commit whose vm.sh and repros run (fixed by the first run)")
        cmd.add_argument("--infra-retries", type=int, default=DEFAULT_INFRA_RETRIES,
                         help="new attempts per commit after steps that ended without a verdict")
        cmd.add_argument("--client", default=os.environ.get("CMUX_CI", str(Path.home() / ".local/bin/cmux-ci")))
        cmd.add_argument("--repo", default="manaflow-ai/cmux")
        if name == "run":
            cmd.add_argument("--state", type=Path, help="default artifacts/stability-bisect/<hash12>.json")
            cmd.add_argument("--max-hours", type=float, default=12, help="stop waiting after this (exit 75)")
            cmd.add_argument("--post", action="store_true", help="record the verdict with stability_issues.py")
    return p


def main(argv: list[str] | None = None, fleet: Fleet | None = None, git: Git | None = None,
         clock: Callable[[], float] = time.monotonic) -> int:
    args = parser().parse_args(argv)
    git = git or Git(ROOT)
    try:
        opts = options(args, git)
        fleet = fleet or CmuxCi(ROOT, args.client, args.repo)
        if args.cmd == "plan":
            print(json.dumps(plan(opts, fleet, git), indent=1))
            return 0
        state = args.state or ROOT / "artifacts/stability-bisect" / f"{opts.hash12}.json"
        bisect = Bisect(opts, fleet, git, state, deadline=clock() + args.max_hours * 3600, clock=clock)
        verdict = bisect.run()
    except Pending as pending:
        print(f"stability_bisect: not finished: {pending}", file=sys.stderr)
        return EX_TEMPFAIL
    except BisectError as error:
        print(f"stability_bisect: {error}", file=sys.stderr)
        return 1
    print(json.dumps(verdict, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())

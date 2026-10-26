#!/usr/bin/env python3
"""The perf lab's regression canary: a known regression on a scratch ref, checked end to end.

    python3 -I scripts/perf-lab/lab.py canary --run [--tip SHA] [--at N] [--seed N] --submit-command PATH ...
    python3 -I scripts/perf-lab/lab.py canary --last 3 [--json]

A canary proves that the lab finds a regression it was not told about (p12-perf-process.md 3.7, done check 10). The
bench-only feature `perfLabCanary` (schemas/features/features.d/perfLabCanary.json; PerfLabKeySpin in
CmuxNextFeatures/PerfLabProbes.swift) makes every key-down spin for exactly 2 ms before key dispatch. A run:

1. Builds a scratch history on top of the tip: BATCHES_BEFORE + 1 + BATCHES_AFTER batches of BATCH_COMMITS commits
   each. Every commit is empty except one inside batch BATCHES_BEFORE (never its tip, so the bisect must go below
   batch granularity): it turns `perfLabCanary` on by its channel defaults and regenerates the registry with
   gen-features.py, the step a features default flip makes inside one series (3.1). The history is pushed only to
   refs/heads/perf-lab/canary/<run>; `push_scratch` refuses any other ref, so the big branch is never touched.
2. Runs a lane of its own in DATA_DIR/canary/<run>/: its own store (lab.sqlite3), with the scratch ref as the
   mainline that orders points. Each batch gets one T0 round, at most one per scheduler.BATCH_INTERVAL as on the
   waterfall: its tip build is requested, and once built the T0 stories run on their shard-map owners. Plans go
   to the same --submit-command labd uses, with a "lane" entry: the program writes the lane's results to
   lane.results, which the canary ingests into the lane store before alerts.detect runs on it. Bisect and
   verification run on the lane store through --pinpoint-command (pinpoint_exec.py, task 016, and verify.py),
   which gets the lane store's path.
3. Judges the lane store (`judge`): an alert whose range holds the injected commit within ALERT_WITHIN_BATCHES T0
   batches of it (MIN_SEGMENT_SIZE = 6 points after the step, plus the step), a bisect whose culprit is exactly
   the injected commit within CULPRIT_WITHIN of the alert, and a verification of that commit by the strict rule
   (DIFFERENT, p <= 0.01) in the regression direction.

`--last N` judges the newest N runs again and exits 0 only when there are N and every one passed.
Stdlib only; loads its siblings by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import random
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import asdict, dataclass, field, replace
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]


def _sibling(name: str):
    """scripts/perf-lab/<name>.py as perf_lab_<name>, once per process (the names the siblings use)."""
    module_name = f"perf_lab_{name}"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module  # before exec: dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


store = _sibling("store")
scheduler = _sibling("scheduler")
anomaly = _sibling("anomaly")

FEATURE = "perfLabCanary"
FEATURE_FILE = f"schemas/features/features.d/{FEATURE}.json"
GENERATED_SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextFeatures/Features.generated.swift"
GENERATOR = "scripts/cmux-next/gen-features.py"
SCRATCH_PREFIX = "refs/heads/perf-lab/canary/"
LANE_PREFIX = "refs/perf-lab/canary/"
RUN_ID = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$")
SHA = re.compile(r"^[0-9a-f]{40}$")

BATCH_COMMITS = 4
BATCHES_BEFORE = anomaly.MIN_SEGMENT_SIZE  # a step needs MIN_SEGMENT_SIZE points on each side
BATCHES_AFTER = anomaly.MIN_SEGMENT_SIZE
ALERT_WITHIN_BATCHES = anomaly.MIN_SEGMENT_SIZE + 1  # the injected batch and the 6 after it (done check 10)
CULPRIT_WITHIN = timedelta(hours=3)
VERIFY_WITHIN = timedelta(hours=12)  # the sheriff loop's fix-or-flag-off SLO, counted from the alert
RUN_LIMIT = timedelta(hours=24)  # a check still pending a day after the start fails (no build, no host)
POLL_SECONDS = scheduler.POLL_SECONDS

PASS, FAIL, PENDING = "pass", "fail", "pending"
DATA_DIR = Path.home() / "Library" / "Application Support" / "cmux-perf-lab"
RUN_FILE = "run.json"
DB_NAME = "lab.sqlite3"


class CanaryError(RuntimeError):
    pass


# ---------- layout (pure) ----------

@dataclass(frozen=True)
class Layout:
    """Where the injected commit sits: batch `injected_batch`, commit `injected_offset` of it (0-based)."""

    batches: int = BATCHES_BEFORE + 1 + BATCHES_AFTER
    batch_commits: int = BATCH_COMMITS
    injected_batch: int = BATCHES_BEFORE
    injected_offset: int = 0

    def __post_init__(self) -> None:
        if self.batch_commits < 2:
            raise CanaryError("a batch needs at least 2 commits, so the injected commit is not its tip")
        if not 0 <= self.injected_offset < self.batch_commits - 1:
            raise CanaryError(f"--at {self.injected_offset}: the injected commit is one of the first "
                              f"{self.batch_commits - 1} of its batch, never its tip")
        if not 0 < self.injected_batch < self.batches:
            raise CanaryError("the injected batch needs batches before it")

    @property
    def total(self) -> int:
        return self.batches * self.batch_commits

    @property
    def injected_index(self) -> int:
        return self.injected_batch * self.batch_commits + self.injected_offset


def choose_layout(rng: random.Random, at: int | None = None) -> Layout:
    """The standard layout with the injected commit at `at`, or at a random commit of its batch but the tip."""
    return Layout(injected_offset=rng.randrange(BATCH_COMMITS - 1) if at is None else at)


def run_id_for(now: datetime, tip: str) -> str:
    return f"{now.astimezone(timezone.utc):%Y%m%dT%H%M%SZ}-{tip[:12]}"


def scratch_ref(run_id: str) -> str:
    if not RUN_ID.match(run_id):
        raise CanaryError(f"run id {run_id!r} is not <UTC stamp>-<12 hex>")
    return SCRATCH_PREFIX + run_id


# ---------- scratch history (git) ----------

Git = Callable[..., str]


def git_runner(run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> Git:
    def git(*args: str, cwd: Path) -> str:
        try:
            done = run(["git", "-C", str(cwd), *args], capture_output=True, text=True, timeout=600)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise CanaryError(f"git {' '.join(args)}: {error}") from None
        if done.returncode != 0:
            raise CanaryError(f"git {' '.join(args)} exited {done.returncode}: {done.stderr.strip()[-500:]}")
        return done.stdout.strip()

    return git


def turn_on(text: str) -> str:
    """The feature file with `perfLabCanary` on in every channel default; the rest of the file is kept."""
    flipped, count = re.subn(r'"defaults"\s*:\s*\{[^{}]*\}', '"defaults": { "dev": true, "nightly": true, "release": true }',
                             text)
    document = json.loads(flipped)
    if count != 1 or document.get("name") != FEATURE or set(document["defaults"].values()) != {True}:
        raise CanaryError(f"{FEATURE_FILE}: no single defaults object to turn on")
    return flipped


def regenerate_registry(tree: Path) -> None:
    """The tree's own generator, so the flip commit's registry is what that commit generates."""
    done = subprocess.run([sys.executable, str(tree / GENERATOR)], cwd=tree, capture_output=True, text=True,
                          timeout=300)
    if done.returncode != 0:
        raise CanaryError(f"{GENERATOR} exited {done.returncode}: {done.stderr.strip()[-500:]}")


@dataclass(frozen=True)
class Batch:
    first: str
    tip: str
    commits: tuple[str, ...]


@dataclass(frozen=True)
class Scratch:
    base: str
    batches: tuple[Batch, ...]
    injected: str


def build_scratch(repo: Path, tip: str, run_id: str, layout: Layout, *, git: Git,
                  regenerate: Callable[[Path], None] = regenerate_registry) -> Scratch:
    """Commits the layout on top of `tip` in a detached worktree of `repo`; the worktree is removed after."""
    if not SHA.match(tip):
        raise CanaryError(f"tip {tip!r} is not a full sha")
    work = Path(tempfile.mkdtemp(prefix="perf-lab-canary-"))
    tree = work / "tree"
    shas: list[str] = []
    injected = None
    added = False
    try:
        git("worktree", "add", "--detach", str(tree), tip, cwd=repo)
        added = True
        if not (tree / FEATURE_FILE).is_file():
            raise CanaryError(f"{tip[:12]} has no {FEATURE_FILE}; the canary needs a tip with that feature")
        identity = ("-c", "user.name=cmux perf lab canary", "-c", "user.email=perf-lab-canary@cmux.invalid")
        for index in range(layout.total):
            batch, offset = divmod(index, layout.batch_commits)
            subject = f"perf-lab canary {run_id}: batch {batch + 1}, commit {offset + 1}"
            if index == layout.injected_index:
                path = tree / FEATURE_FILE
                path.write_text(turn_on(path.read_text(encoding="utf-8")), encoding="utf-8")
                regenerate(tree)
                git("add", "--", FEATURE_FILE, GENERATED_SWIFT, cwd=tree)
                git(*identity, "commit", "--quiet", "-m", f"{subject}: turn {FEATURE} on", cwd=tree)
            else:
                git(*identity, "commit", "--quiet", "--allow-empty", "-m", subject, cwd=tree)
            shas.append(git("rev-parse", "HEAD", cwd=tree))
            if index == layout.injected_index:
                injected = shas[-1]
    finally:
        try:
            if added:
                git("worktree", "remove", "--force", str(tree), cwd=repo)
        finally:
            shutil.rmtree(work, ignore_errors=True)
    size = layout.batch_commits
    batches = tuple(Batch(shas[i], shas[i + size - 1], tuple(shas[i:i + size])) for i in range(0, len(shas), size))
    return Scratch(tip, batches, injected)


def push_scratch(repo: Path, remote: str, sha: str, ref: str, *, git: Git) -> None:
    """Pushes the scratch history; only a perf-lab/canary/<run> ref, so no lab branch is ever touched."""
    if not ref.startswith(SCRATCH_PREFIX) or not RUN_ID.match(ref[len(SCRATCH_PREFIX):]):
        raise CanaryError(f"{ref}: a canary pushes only {SCRATCH_PREFIX}<run>")
    git("push", "--quiet", remote, f"{sha}:{ref}", cwd=repo)
    git("update-ref", LANE_PREFIX + ref[len(SCRATCH_PREFIX):], sha, cwd=repo)


# ---------- run record ----------

@dataclass
class RunRecord:
    run_id: str
    started_at: str
    remote: str
    base: str
    injected: str
    injected_pos: int  # its commit position on the scratch mainline (ingest.GitCommitPositions)
    injected_batch: int
    batches: list[dict]  # {first, tip, commits, build_requested, t0_at}
    finished_at: str | None = None
    verdict: dict | None = None

    @property
    def ref(self) -> str:
        return scratch_ref(self.run_id)

    @property
    def mainline(self) -> str:
        return LANE_PREFIX + self.run_id

    @classmethod
    def new(cls, run_id: str, now: datetime, remote: str, scratch: Scratch, layout: Layout,
            injected_pos: int) -> "RunRecord":
        return cls(run_id, _stamp(now), remote, scratch.base, scratch.injected, injected_pos, layout.injected_batch,
                   [{"first": b.first, "tip": b.tip, "commits": list(b.commits), "build_requested": False,
                     "t0_at": None} for b in scratch.batches])

    def save(self, directory: Path) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        handle, temp = tempfile.mkstemp(dir=directory, prefix=".run-", suffix=".json")
        try:
            with os.fdopen(handle, "w", encoding="utf-8") as out:
                json.dump(asdict(self), out, indent=1, sort_keys=True)
            os.replace(temp, directory / RUN_FILE)
        except BaseException:
            Path(temp).unlink(missing_ok=True)
            raise

    @classmethod
    def load(cls, directory: Path) -> "RunRecord":
        try:
            return cls(**json.loads((directory / RUN_FILE).read_text(encoding="utf-8")))
        except (OSError, ValueError, TypeError) as error:
            raise CanaryError(f"{directory / RUN_FILE}: {error}") from None


def _stamp(moment: datetime) -> str:
    """The lab store's stamp (store._stamp): fixed-width UTC, so stamps compare as text in time order."""
    return moment.astimezone(timezone.utc).isoformat(timespec="microseconds")


def _time(text: str) -> datetime:
    return datetime.fromisoformat(text).astimezone(timezone.utc)


# ---------- T0 lane ----------

@dataclass
class Lane:
    """One canary run's T0 rounds: each batch tip is built, then measured by its shard owners, one round per
    scheduler.BATCH_INTERVAL. `submit` takes a plan document and returns the job ids it could not start."""

    record: RunRecord
    directory: Path
    stories: Sequence  # scheduler.StorySpec
    shard_map: object  # scheduler.ShardMap
    hosts: Callable[[], Sequence]  # scheduler.Host
    builds: Callable[[], object]  # scheduler.Builds
    submit: Callable[[dict], set[str]]
    clock: Callable[[], datetime]

    def _t0(self) -> list:
        return [s for s in self.stories if s.tier == "T0"]

    def _configs(self) -> set[str]:
        return {s.config for s in self._t0()}

    def _plan(self, jobs: Sequence, builds: Sequence) -> dict:
        document = scheduler.Plan(scheduler.State(), tuple(jobs), tuple(builds), (), (), (), "every-batch", None,
                                  ()).to_document()
        document["lane"] = {"name": f"canary/{self.record.run_id}", "ref": self.record.ref,
                            "results": str(self.directory / "results")}
        return document

    def round_jobs(self, index: int, batch: Mapping) -> list:
        """The T0 jobs of batch `index`: each T0 shard of each class on its waterfall owner (never moved)."""
        seconds = {s.id: s.seconds for s in self._t0()}
        owners = {(h.lab_class, h.shard): h for h in self.hosts() if h.role == scheduler.WATERFALL and h.up}
        jobs = []
        for lab_class in sorted(self.shard_map.classes):
            for shard_index, shard in enumerate(self.shard_map.shards(lab_class)):
                ids = tuple(s for s in shard.get("T0", ()) if s in seconds)
                host = owners.get((lab_class, shard_index))
                if not ids or host is None:
                    continue
                key = f"{lab_class}/{shard_index}"
                jobs.append(scheduler.Job(
                    f"canary:{self.record.run_id}:T0-{index + 1}:{key}", "waterfall", host.name,
                    sum(seconds[s] for s in ids), tier="T0", round=f"canary-T0-{index + 1}", sha=batch["tip"],
                    first=batch["first"], stories=ids, key=key))
        return jobs

    def step(self) -> list[str]:
        """Requests every batch tip build once, then starts the next due T0 round. Returns what it did."""
        now, done = self.clock(), []
        record = self.record
        wanted = [b for b in record.batches if not b["build_requested"]]
        if wanted:
            builds = [scheduler.BuildRequest(b["tip"], config, "batch-tip") for b in wanted
                      for config in sorted(self._configs())]
            self.submit(self._plan((), builds))
            for batch in wanted:
                batch["build_requested"] = True
            done.append(f"requested {len(wanted)} batch-tip builds")
        measured = [b for b in record.batches if b["t0_at"]]
        if len(measured) == len(record.batches):
            return done
        if measured and now - _time(measured[-1]["t0_at"]) < scheduler.BATCH_INTERVAL:
            return done
        index = len(measured)
        batch = record.batches[index]
        ready = self.builds().ready
        if not all((batch["tip"], config) in ready for config in self._configs()):
            return done
        jobs = self.round_jobs(index, batch)
        if not jobs:
            raise CanaryError("no waterfall host owns a T0 shard; the canary has nothing to measure on")
        refused = self.submit(self._plan(jobs, ()))
        if refused:
            return [*done, f"T0 round {index + 1}: the controller refused {', '.join(sorted(refused))}; retrying"]
        batch["t0_at"] = _stamp(now)
        return [*done, f"T0 round {index + 1} on {batch['tip'][:12]} ({len(jobs)} jobs)"]


# ---------- judge ----------

@dataclass(frozen=True)
class Check:
    state: str  # PASS, FAIL or PENDING
    detail: str


@dataclass(frozen=True)
class Verdict:
    alert: Check
    bisect: Check
    verify: Check

    @property
    def state(self) -> str:
        states = {self.alert.state, self.bisect.state, self.verify.state}
        return FAIL if FAIL in states else PENDING if PENDING in states else PASS

    def to_dict(self) -> dict:
        return {"state": self.state, **{name: asdict(getattr(self, name)) for name in ("alert", "bisect", "verify")}}


def _culprits(result_json: str | None) -> list[tuple[str, ...]]:
    """The commits of each culprit of a bisect job's result (pinpoint.Result.to_json)."""
    try:
        result = json.loads(result_json or "{}")
        return [tuple(culprit["commits"]) for culprit in result.get("culprits", ())]
    except (ValueError, TypeError, KeyError, AttributeError):
        return []


def _alert(db: sqlite3.Connection, record: RunRecord) -> tuple[sqlite3.Row | None, int]:
    """The first regression alert whose range holds the injected commit, and the T0 batches measured at or after
    that commit by then (all of them while there is no alert)."""
    alert = db.execute(
        """SELECT a.*, s.story, s.metric FROM alerts a JOIN series s ON s.id = a.series_id
           WHERE a.rule = 'edivisive' AND a.is_improvement = 0 AND a.group_id IS NOT NULL
             AND a.start_pos <= ? AND a.end_pos >= ? ORDER BY a.created_at, a.id LIMIT 1""",
        (record.injected_pos, record.injected_pos)).fetchone()
    query = """SELECT COUNT(DISTINCT b.commit_pos) FROM runs r JOIN builds b ON b.id = r.build_id
               WHERE r.kind = 'waterfall' AND b.commit_pos >= ?"""
    params: tuple = (record.injected_pos,)
    if alert is not None:
        query, params = query + " AND r.started_at <= ?", (*params, alert["created_at"])
    return alert, db.execute(query, params).fetchone()[0]


def _bisect(db: sqlite3.Connection, record: RunRecord, group: int, alerted_at: datetime, now: datetime) -> Check:
    jobs = db.execute("""SELECT * FROM jobs WHERE kind = 'bisect' AND alert_group_id = ? AND state = 'done'
                         ORDER BY updated_at, id""", (group,)).fetchall()
    exact = [job for job in jobs if (record.injected,) in _culprits(job["result_json"])]
    if exact:
        took = _time(exact[0]["updated_at"]) - alerted_at
        return Check(PASS if took <= CULPRIT_WITHIN else FAIL,
                     f"culprit {record.injected[:12]} {took} after the alert (limit {CULPRIT_WITHIN})")
    if jobs:
        named = sorted({" ".join(sha[:12] for sha in commits)
                        for job in jobs for commits in _culprits(job["result_json"])})
        return Check(FAIL, f"the bisect named {', '.join(named) or 'no culprit'}, not {record.injected[:12]}")
    return Check(FAIL if now - alerted_at > CULPRIT_WITHIN else PENDING, f"no finished bisect of group {group}")


def _verify(db: sqlite3.Connection, record: RunRecord, group: int, alerted_at: datetime, now: datetime) -> Check:
    rows = db.execute("""SELECT result_json FROM jobs WHERE kind = 'verify' AND alert_group_id = ? AND state = 'done'
                         AND head_sha = ? ORDER BY id""", (group, record.injected)).fetchall()
    results = [json.loads(row["result_json"] or "{}") for row in rows]
    strict = [r for r in results if r.get("state") == "verified" and r.get("strict") == "different"]
    if strict:
        return Check(PASS, f"strict DIFFERENT, p = {strict[0].get('p_value')}, median shift "
                           f"{strict[0].get('median_shift')}")
    if results:
        last = results[-1]
        return Check(FAIL, f"{last.get('state')} ({last.get('strict')}): {last.get('reason')}")
    return Check(FAIL if now - alerted_at > VERIFY_WITHIN else PENDING,
                 f"no finished verification of {record.injected[:12]}")


def _expire(check: Check, record: RunRecord, now: datetime) -> Check:
    if check.state == PENDING and now - _time(record.started_at) > RUN_LIMIT:
        return Check(FAIL, f"timed out after {RUN_LIMIT}: {check.detail}")
    return check


def judge(db: sqlite3.Connection, record: RunRecord, now: datetime) -> Verdict:
    """The three checks of done check 10 on a lane store (store.py schema)."""
    db.row_factory = sqlite3.Row
    alert, measured = _alert(db, record)
    if alert is None:
        waiting = Check(PENDING, "waits for the alert")
        state = FAIL if measured >= ALERT_WITHIN_BATCHES else PENDING
        checks = (Check(state, f"no alert holds the injected commit after {measured} T0 batches"), waiting, waiting)
    else:
        group, alerted_at = alert["group_id"], _time(alert["created_at"])
        checks = (Check(PASS if measured <= ALERT_WITHIN_BATCHES else FAIL,
                        f"group {group}: {alert['story']} {alert['metric']} after {measured} T0 batches "
                        f"(limit {ALERT_WITHIN_BATCHES})"),
                  _bisect(db, record, group, alerted_at, now), _verify(db, record, group, alerted_at, now))
    return Verdict(*(_expire(check, record, now) for check in checks))


def judge_run(directory: Path, now: datetime) -> tuple[RunRecord, Verdict]:
    record = RunRecord.load(directory)
    path = directory / DB_NAME
    if not path.is_file():
        waiting = Check(PENDING, "the lane store has no results yet")
        return record, Verdict(waiting, waiting, waiting)
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return record, judge(db, record, now)
    finally:
        db.close()


def runs(root: Path) -> list[Path]:
    """Canary run directories, newest first (run ids start with their UTC stamp)."""
    if not root.is_dir():
        return []
    return sorted((p for p in root.iterdir() if RUN_ID.match(p.name) and (p / RUN_FILE).is_file()),
                  key=lambda p: p.name, reverse=True)


def report_last(root: Path, count: int, now: datetime, *, as_json: bool, out) -> int:
    rows = []
    for directory in runs(root)[:count]:
        record, verdict = judge_run(directory, now)
        rows.append({"run": record.run_id, "injected": record.injected, "started_at": record.started_at,
                     **verdict.to_dict()})
    passed = sum(row["state"] == PASS for row in rows)
    if as_json:
        json.dump({"runs": rows, "passed": passed, "wanted": count}, out, indent=1)
        print(file=out)
    else:
        for row in rows:
            print(f"{row['run']}\t{row['state'].upper()}\talert: {row['alert']['detail']}; "
                  f"bisect: {row['bisect']['detail']}; verify: {row['verify']['detail']}", file=out)
        print(f"{passed}/{count} canary runs passed", file=out)
    return 0 if len(rows) == count and passed == count else 1


# ---------- the run ----------

@dataclass
class Services:
    """Everything a run touches outside its directory; tests replace each."""

    git: Git
    clock: Callable[[], datetime]
    sleep: Callable[[float], None]
    submit: Callable[[dict], set[str]]
    hosts: Callable[[], Sequence]
    builds: Callable[[], object]
    ingest: Callable[[Path, RunRecord], None]
    detect: Callable[[Path], None]
    pinpoint: Callable[[Path], None] | None
    log: Callable[[str], None] = field(default=lambda line: print(line, file=sys.stderr))


def start_run(root: Path, repo: Path, remote: str, tip: str, layout: Layout, services: Services) -> Path:
    """Builds and pushes the scratch history and writes the run record; returns the run directory."""
    run_id = run_id_for(services.clock(), tip)
    ref = scratch_ref(run_id)
    scratch = build_scratch(repo, tip, run_id, layout, git=services.git)
    push_scratch(repo, remote, scratch.batches[-1].tip, ref, git=services.git)
    directory = root / run_id
    position = int(services.git("rev-list", "--count", "--first-parent", scratch.injected, "--", cwd=repo))
    RunRecord.new(run_id, services.clock(), remote, scratch, layout, position).save(directory)
    services.log(f"canary {run_id}: {ref} pushed; injected {scratch.injected} "
                 f"(batch {layout.injected_batch + 1}, commit {layout.injected_offset + 1})")
    return directory


def drive(directory: Path, lane_inputs: Mapping, services: Services) -> Verdict:
    """Runs the lane until the verdict is not pending. Resumable: the record is saved after every step."""
    record = RunRecord.load(directory)
    db = store.Store(directory / DB_NAME)
    try:
        db.migrate()
    finally:
        db.close()
    lane = Lane(record, directory, clock=services.clock, submit=services.submit, hosts=services.hosts,
                builds=services.builds, **lane_inputs)
    while True:
        for line in lane.step():
            services.log(f"canary {record.run_id}: {line}")
        record.save(directory)
        services.ingest(directory, record)
        services.detect(directory / DB_NAME)
        if services.pinpoint is not None:
            services.pinpoint(directory / DB_NAME)
        _, verdict = judge_run(directory, services.clock())
        if verdict.state != PENDING:
            record.finished_at, record.verdict = _stamp(services.clock()), verdict.to_dict()
            record.save(directory)
            return verdict
        services.sleep(POLL_SECONDS)


def command_submit(program: Path) -> Callable[[dict], set[str]]:
    """labd's submit protocol (labd.command_submitter): the plan JSON on stdin, {"jobs": [refused ids]} out."""
    def submit(document: dict) -> set[str]:
        done = subprocess.run([str(program)], input=json.dumps(document), capture_output=True, text=True, timeout=120)
        if done.returncode != 0:
            raise CanaryError(f"{program} exited {done.returncode}: {done.stderr.strip()[-500:]}")
        answer = json.loads(done.stdout) if done.stdout.strip() else {}
        return set(map(str, answer.get("jobs", ())))

    return submit


def lane_ingest(repo: Path, git: Git) -> Callable[[Path, RunRecord], None]:
    ingest = _sibling("ingest")

    def run(directory: Path, record: RunRecord) -> None:
        results = directory / "results"
        if not results.is_dir() or not any(results.rglob("*.ndjson")):
            return
        try:
            git("rev-parse", "--verify", "--quiet", f"{record.mainline}^{{commit}}", cwd=repo)
        except CanaryError:  # a resumed run on another checkout: the push wrote the lane ref only where it ran
            git("fetch", "--quiet", "--no-tags", record.remote, f"+{record.ref}:{record.mainline}", cwd=repo)
        db = store.Store(directory / DB_NAME)
        try:
            ingest.ingest_paths(db, [results], commit_positions=ingest.GitCommitPositions(repo, mainline=record.mainline),
                                kind="waterfall", tier="T0")
        finally:
            db.close()

    return run


def lane_detect(path: Path) -> None:
    alerts = _sibling("alerts")
    db = store.Store(path)
    try:
        alerts.detect(db, alerts.Subscriptions.load(alerts.DEFAULT_SUBSCRIPTIONS), alerts.CatapultDetector(),
                      alerts.load_targets(alerts.DEFAULT_TARGETS), floors=alerts.load_floors())
    finally:
        db.close()


def pinpoint_command(program: Path) -> Callable[[Path], None]:
    def run(path: Path) -> None:
        done = subprocess.run([str(program), "--db", str(path)], capture_output=True, text=True, timeout=600)
        if done.returncode != 0:
            raise CanaryError(f"{program} exited {done.returncode}: {done.stderr.strip()[-500:]}")

    return run


# ---------- command (lab.py protocol) ----------

LAB_COMMANDS = {
    "canary": "Regression canary: --run injects perfLabCanary on a scratch ref and checks alert, bisect and "
              "verification; --last N judges the newest N runs.",
}


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--run", action="store_true", help="start a canary run and drive it to its verdict")
    mode.add_argument("--resume", metavar="RUN", help="drive an earlier run to its verdict")
    mode.add_argument("--last", type=int, metavar="N", help="judge the newest N runs; exit 0 when all N passed")
    parser.add_argument("--data-dir", type=Path, default=DATA_DIR, help="labd's data directory")
    parser.add_argument("--repo", type=Path, help="the lab's git checkout (default DATA_DIR/repo)")
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--branch", default="feat-cmux-next", help="the branch whose tip the scratch ref starts from")
    parser.add_argument("--tip", help="start from this commit instead of the branch tip")
    parser.add_argument("--at", type=int, help=f"the injected commit's index in its batch (0..{BATCH_COMMITS - 2})")
    parser.add_argument("--seed", type=int, help="seed for the injected commit's place")
    parser.add_argument("--submit-command", type=Path, help="labd's --submit-command program")
    parser.add_argument("--pinpoint-command", type=Path,
                        help="runs bisect and verification on the lane store (`PROGRAM --db LANE_DB`)")
    parser.add_argument("--pool", type=Path, default=HERE / "pool.json", help="the lab hosts (task 130)")
    parser.add_argument("--json", action="store_true")


def run(command: str, args: argparse.Namespace, out=None) -> int:
    out = out or sys.stdout
    root = args.data_dir / "canary"
    now = datetime.now(timezone.utc)
    if args.last is not None:
        if args.last < 1:
            print("canary: --last needs N >= 1", file=sys.stderr)
            return 2
        return report_last(root, args.last, now, as_json=args.json, out=out)
    if args.submit_command is None:
        print("canary: --run and --resume need --submit-command (labd's), or no T0 job ever starts", file=sys.stderr)
        return 2
    repo = args.repo or args.data_dir / "repo"
    git = git_runner()
    catalog = _sibling("catalog")
    labd = _sibling("labd")
    builds_mod = _sibling("builds")
    try:
        stories = scheduler.stories_from_catalog(catalog.load_catalog(REPO_ROOT))
        shard_map = scheduler.ShardMap.load(HERE / "shard_map.json")
        services = Services(
            git=git, clock=lambda: datetime.now(timezone.utc), sleep=time.sleep,
            submit=command_submit(args.submit_command),
            hosts=lambda: scheduler.hosts_from_document(json.loads(args.pool.read_text(encoding="utf-8"))),
            builds=lambda: labd.ledger_builds(scheduler, builds_mod, args.data_dir / "builds"),
            ingest=lane_ingest(repo, git), detect=lane_detect,
            pinpoint=pinpoint_command(args.pinpoint_command) if args.pinpoint_command else None)
        if args.run:
            tip = args.tip or scheduler.git_ls_remote(args.remote, args.branch, repo=repo)
            if not tip:
                raise CanaryError(f"cannot read the tip of {args.branch} on {args.remote}")
            git("fetch", "--quiet", "--no-tags", args.remote, f"+refs/heads/{args.branch}:refs/perf-lab/{args.branch}",
                cwd=repo)
            git("merge-base", "--is-ancestor", tip, f"refs/perf-lab/{args.branch}", cwd=repo)
            layout = choose_layout(random.Random(args.seed), args.at)
            directory = start_run(root, repo, args.remote, tip, layout, services)
        else:
            scratch_ref(args.resume)
            directory = root / args.resume
        if services.pinpoint is None:
            services.log("canary: no --pinpoint-command, so the bisect and verification checks stay pending")
        verdict = drive(directory, {"stories": stories, "shard_map": shard_map}, services)
    except (CanaryError, scheduler.SchedulerError, catalog.CatalogError, store.StoreError, OSError, ValueError) as error:
        print(f"canary: {error}", file=sys.stderr)
        return 2
    json.dump({"run": directory.name, **verdict.to_dict()}, out, indent=1)
    print(file=out)
    return 0 if verdict.state == PASS else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="canary.py", description=LAB_COMMANDS["canary"])
    add_arguments("canary", parser)
    return run("canary", parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())

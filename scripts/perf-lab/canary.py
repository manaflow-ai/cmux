#!/usr/bin/env python3
"""The perf lab's regression canary: a known regression on a scratch ref, checked end to end.

    python3 -I scripts/perf-lab/lab.py canary --run [--tip SHA] [--at N] [--seed N] [--pinpoint-command PATH]
    python3 -I scripts/perf-lab/lab.py canary --resume RUN [--pinpoint-command PATH]
    python3 -I scripts/perf-lab/lab.py canary --last 3 [--json]

A canary proves that the lab finds a regression it was not told about (p12-perf-process.md 3.7, done check 10). The
bench-only feature `perfLabCanary` (schemas/features/features.d/perfLabCanary.json; PerfLabKeySpin in
CmuxNextFeatures/PerfLabProbes.swift) makes every key-down spin for exactly 2 ms before key dispatch, so it moves
key-to-frame series only. A run measures the T0 stories with a key_to_frame metric (`key_frame_stories`; 3.3 lists
terminal, Home and omnibar key->frame) and refuses to start while stories.d and shard_map.json have none. A run:

1. Builds a scratch history on top of the tip: BATCHES_BEFORE + 1 + BATCHES_AFTER batches of BATCH_COMMITS commits
   each. Every commit is empty except one inside batch BATCHES_BEFORE (never its tip, so the bisect must go below
   batch granularity): it turns `perfLabCanary` on by its channel defaults and regenerates the registry with
   gen-features.py, the step a features default flip makes inside one series (3.1). The history is pushed only to
   refs/heads/perf-lab/canary/<run>, and that ref is deleted from the remote once the run has its verdict;
   `push_scratch` and `delete_scratch` refuse any other ref, so the big branch is never touched.
2. Is a side lane of labd (scheduler.Lane): DATA_DIR/canary/<run>/lane.json (`LaneDocument`) gives labd's Driver
   the lane's builds and due T0 rounds, which it starts on the T0 shard owners only when they are free, after the
   waterfall's own T0 and pinpoint work. labd's /ingest stores the results of the scratch commits in the lane's own
   store (DATA_DIR/canary/<run>/lab.sqlite3), ordered on the lane ref, never in the lab's. The run asks for one
   round per batch, at most one per scheduler.BATCH_INTERVAL as on the waterfall, once the batch tip is built; a
   round with no result ROUND_RETRY after it was asked is asked again under a new attempt id. alerts.detect, and
   bisect and verification through --pinpoint-command (pinpoint_exec.py, task 016, and verify.py, `PROGRAM --db
   LANE_DB`), run on the lane store.
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
from dataclasses import asdict, dataclass, field
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
ROUND_RETRY = timedelta(hours=1)  # a round asked this long ago with no result is asked again (a lost job)
POLL_SECONDS = scheduler.POLL_SECONDS
KEY_FRAME_METRIC = re.compile(r"key_to_frame")  # a catalog metric pattern the 2 ms key-down spin moves

PASS, FAIL, PENDING = "pass", "fail", "pending"
DATA_DIR = Path.home() / "Library" / "Application Support" / "cmux-perf-lab"
CANARY_DIR = "canary"
RUN_FILE = "run.json"
LANE_FILE = "lane.json"
LANE_SCHEMA = "cmux-perf-lab-lane/v1"
DB_NAME = "lab.sqlite3"
LABD_SOCKET = "labd.sock"  # labd.SOCKET_NAME: labd runs on this data directory


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


def key_frame_stories(stories: Sequence, shard_map) -> tuple[str, ...]:
    """The T0 stories (catalog.Story) with a key_to_frame metric that the shard map runs in T0, sorted. The 2 ms
    key-down spin moves nothing else, so a run refuses to start without one."""
    sharded = shard_map.sharded()
    found = tuple(sorted(s.id for s in stories if s.tier == "T0" and ("T0", s.id) in sharded
                         and any(KEY_FRAME_METRIC.search(metric.name) for metric in s.metrics)))
    if not found:
        t0 = ", ".join(sorted(s.id for s in stories if s.tier == "T0")) or "none"
        raise CanaryError(
            f"no T0 story measures key-to-frame (T0 now: {t0}), so the 2 ms key-down spin can move no T0 series "
            "and no run could alert. The canary needs a T0 key->frame story in stories.d and shard_map.json first "
            "(p12-perf-process.md 3.3: terminal key->frame light from the typing benches, task "
            "p12-perf-process-050)")
    return found


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


def _run_of(ref: str) -> str:
    if not ref.startswith(SCRATCH_PREFIX) or not RUN_ID.match(ref[len(SCRATCH_PREFIX):]):
        raise CanaryError(f"{ref}: a canary pushes only {SCRATCH_PREFIX}<run>")
    return ref[len(SCRATCH_PREFIX):]


def push_scratch(repo: Path, remote: str, sha: str, ref: str, *, git: Git) -> None:
    """Pushes the scratch history; only a perf-lab/canary/<run> ref, so no lab branch is ever touched. The local
    lane ref is the mainline labd orders the lane's points on."""
    run_id = _run_of(ref)
    git("push", "--quiet", remote, f"{sha}:{ref}", cwd=repo)
    git("update-ref", LANE_PREFIX + run_id, sha, cwd=repo)


def delete_scratch(repo: Path, remote: str, ref: str, *, git: Git) -> None:
    """Deletes a finished run's scratch branch from the remote (the same refs only); the local lane ref stays."""
    _run_of(ref)
    git("push", "--quiet", remote, f":{ref}", cwd=repo)


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
    stories: list[str]  # the T0 key-to-frame stories the lane measures (key_frame_stories)
    batches: list[dict]  # {first, tip, commits, t0_at (first asked), attempt, attempt_at}
    finished_at: str | None = None
    verdict: dict | None = None

    @property
    def ref(self) -> str:
        return scratch_ref(self.run_id)

    @property
    def mainline(self) -> str:
        return LANE_PREFIX + self.run_id

    @property
    def lane_name(self) -> str:
        return f"{CANARY_DIR}/{self.run_id}"

    @classmethod
    def new(cls, run_id: str, now: datetime, remote: str, scratch: Scratch, layout: Layout, injected_pos: int,
            stories: Sequence[str]) -> "RunRecord":
        return cls(run_id, _stamp(now), remote, scratch.base, scratch.injected, injected_pos, layout.injected_batch,
                   list(stories), [{"first": b.first, "tip": b.tip, "commits": list(b.commits), "t0_at": None,
                                    "attempt": 0, "attempt_at": None} for b in scratch.batches])

    def save(self, directory: Path) -> None:
        _write_json(directory / RUN_FILE, asdict(self))

    @classmethod
    def load(cls, directory: Path) -> "RunRecord":
        try:
            return cls(**json.loads((directory / RUN_FILE).read_text(encoding="utf-8")))
        except (OSError, ValueError, TypeError) as error:
            raise CanaryError(f"{directory / RUN_FILE}: {error}") from None


def _write_json(path: Path, document: object) -> None:
    """Atomic: labd reads the old file or the new one, never a partial one."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.stem}-", suffix=".json")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            json.dump(document, out, indent=1, sort_keys=True)
        os.replace(temp, path)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise


def _stamp(moment: datetime) -> str:
    """The lab store's stamp (store._stamp): fixed-width UTC, so stamps compare as text in time order."""
    return moment.astimezone(timezone.utc).isoformat(timespec="microseconds")


def _time(text: str) -> datetime:
    return datetime.fromisoformat(text).astimezone(timezone.utc)


# ---------- the side lane (labd reads it) ----------

def round_id(record: RunRecord, index: int, attempt: int) -> str:
    """A controller-safe job id prefix (labd.JOB_ID): the scheduler appends `:<lab class>.<shard>`."""
    return f"canary:{record.run_id}:T0-{index + 1}.{attempt}"


@dataclass(frozen=True)
class LaneDocument:
    """DATA_DIR/canary/<run>/lane.json, what labd needs of a run in progress: the Driver plans `lane`
    (scheduler.Lane), and /ingest stores a body of `commits` in `store`, its points ordered on `mainline`. The
    store and mainline follow from the run directory, never from the file."""

    lane: object  # scheduler.Lane
    commits: frozenset[str]
    mainline: str
    store: Path

    @property
    def name(self) -> str:
        return self.lane.name

    @classmethod
    def of(cls, record: RunRecord, directory: Path, measured: set[tuple[str, str]]) -> "LaneDocument":
        rounds = tuple(scheduler.LaneRound(round_id(record, index, batch["attempt"]), batch["tip"], batch["first"])
                       for index, batch in enumerate(record.batches)
                       if batch["t0_at"] and not _measured(batch, record.stories, measured))
        lane = scheduler.Lane(record.lane_name, tuple(record.stories), tuple(b["tip"] for b in record.batches),
                              rounds)
        return cls(lane, frozenset(sha for b in record.batches for sha in b["commits"]), record.mainline,
                   directory / DB_NAME)

    def to_document(self) -> dict:
        return {"schema": LANE_SCHEMA, "name": self.lane.name, "stories": list(self.lane.stories),
                "builds": list(self.lane.builds), "commits": sorted(self.commits),
                "rounds": [{"id": r.id, "sha": r.sha, "first": r.first} for r in self.lane.rounds]}

    @classmethod
    def read(cls, directory: Path) -> "LaneDocument":
        document = json.loads((directory / LANE_FILE).read_text(encoding="utf-8"))
        name = f"{CANARY_DIR}/{directory.name}"
        if document.get("schema") != LANE_SCHEMA or document.get("name") != name:
            raise ValueError(f"not a {LANE_SCHEMA} document of {name}")
        ends = [r[key] for r in document["rounds"] for key in ("sha", "first")]
        shas = [*document["builds"], *document["commits"], *ends]
        if not all(isinstance(sha, str) and SHA.match(sha) for sha in shas):
            raise ValueError("a commit is not a full sha")
        rounds = tuple(scheduler.LaneRound(str(r["id"]), r["sha"], r["first"]) for r in document["rounds"])
        lane = scheduler.Lane(name, tuple(map(str, document["stories"])), tuple(document["builds"]), rounds)
        return cls(lane, frozenset(document["commits"]), LANE_PREFIX + directory.name, directory / DB_NAME)


def lane_documents(root: Path) -> list[LaneDocument]:
    """The lanes of the canary runs in progress under DATA_DIR/canary (labd: its Driver and /ingest). A file that
    does not read is skipped, so one broken run never stops the lab's own scheduling."""
    found = []
    for directory in runs(root):
        try:
            found.append(LaneDocument.read(directory))
        except FileNotFoundError:
            continue  # finished: the run removed its lane
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            print(f"canary: {directory / LANE_FILE} skipped: {error}", file=sys.stderr)
    return found


def _measured(batch: Mapping, stories: Sequence[str], measured: set[tuple[str, str]]) -> bool:
    return all((batch["tip"], story) in measured for story in stories)


def measured_in(path: Path) -> set[tuple[str, str]]:
    """(sha, story) of every waterfall run in the lane store."""
    if not path.is_file():
        return set()
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return set(db.execute("""SELECT DISTINCT b.sha, r.story FROM runs r JOIN builds b ON b.id = r.build_id
                                 WHERE r.kind = 'waterfall'""").fetchall())
    finally:
        db.close()


def advance(record: RunRecord, now: datetime, built: set[str], measured: set[tuple[str, str]]) -> list[str]:
    """Asks for the next batch's T0 round once its tip is `built`, at most one per scheduler.BATCH_INTERVAL, and asks
    again (a new attempt id) for a round with no result ROUND_RETRY after its last attempt. Returns what it did."""
    done = []
    for index, batch in enumerate(record.batches):
        if (batch["attempt_at"] and not _measured(batch, record.stories, measured)
                and now - _time(batch["attempt_at"]) >= ROUND_RETRY):
            batch["attempt"] += 1
            batch["attempt_at"] = _stamp(now)
            done.append(f"T0 round {index + 1}: no result {ROUND_RETRY} after it was asked; attempt {batch['attempt']}")
    asked = [b for b in record.batches if b["t0_at"]]
    if len(asked) == len(record.batches):
        return done
    if asked and now - _time(asked[-1]["t0_at"]) < scheduler.BATCH_INTERVAL:
        return done
    batch = record.batches[len(asked)]
    if batch["tip"] not in built:
        return done
    batch["t0_at"] = batch["attempt_at"] = _stamp(now)
    batch["attempt"] = 1
    return [*done, f"T0 round {len(asked) + 1} on {batch['tip'][:12]} asked of labd"]


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
    builds: Callable[[], object]  # scheduler.Builds: the lab's build ledger
    detect: Callable[[Path], None]
    pinpoint: Callable[[Path], None] | None
    log: Callable[[str], None] = field(default=lambda line: print(line, file=sys.stderr))
    regenerate: Callable[[Path], None] = regenerate_registry


def start_run(root: Path, repo: Path, remote: str, tip: str, layout: Layout, stories: Sequence[str],
              services: Services) -> Path:
    """Builds and pushes the scratch history and writes the run record; returns the run directory."""
    if not stories:
        raise CanaryError("no T0 key-to-frame story to measure (key_frame_stories)")
    run_id = run_id_for(services.clock(), tip)
    ref = scratch_ref(run_id)
    scratch = build_scratch(repo, tip, run_id, layout, git=services.git, regenerate=services.regenerate)
    push_scratch(repo, remote, scratch.batches[-1].tip, ref, git=services.git)
    directory = root / run_id
    position = int(services.git("rev-list", "--count", "--first-parent", scratch.injected, "--", cwd=repo))
    RunRecord.new(run_id, services.clock(), remote, scratch, layout, position, stories).save(directory)
    services.log(f"canary {run_id}: {ref} pushed; injected {scratch.injected} "
                 f"(batch {layout.injected_batch + 1}, commit {layout.injected_offset + 1}); measures "
                 f"{', '.join(stories)}")
    return directory


def _step(directory: Path, record: RunRecord, configs: set[str], services: Services) -> None:
    """One poll: the next round, the lane file labd reads, then detection, bisect and verification."""
    ready = services.builds().ready
    built = {b["tip"] for b in record.batches if all((b["tip"], config) in ready for config in configs)}
    path = directory / DB_NAME
    for line in advance(record, services.clock(), built, measured_in(path)):
        services.log(f"canary {record.run_id}: {line}")
    record.save(directory)
    _write_json(directory / LANE_FILE, LaneDocument.of(record, directory, measured_in(path)).to_document())
    services.detect(path)
    if services.pinpoint is not None:
        services.pinpoint(path)


def _finish(directory: Path, record: RunRecord, repo: Path, verdict: Verdict, services: Services) -> None:
    """Ends the lane (labd stops planning and routing it) and deletes the scratch branch from the remote."""
    (directory / LANE_FILE).unlink(missing_ok=True)
    record.finished_at, record.verdict = _stamp(services.clock()), verdict.to_dict()
    record.save(directory)
    try:
        delete_scratch(repo, record.remote, record.ref, git=services.git)
    except CanaryError as error:
        services.log(f"canary {record.run_id}: {record.ref} stays on {record.remote}: {error}")


def drive(directory: Path, repo: Path, configs: set[str], services: Services) -> Verdict:
    """Runs the lane until the verdict is not pending. Resumable: the record is saved after every step. A failing
    step (the build ledger, the store, a failing --pinpoint-command) is logged and runs again on the next poll, as
    labd's Worker does, and the verdict is still judged, so RUN_LIMIT ends a run that never recovers."""
    record = RunRecord.load(directory)
    db = store.Store(directory / DB_NAME)
    try:
        db.migrate()
    finally:
        db.close()
    while True:
        try:
            _step(directory, record, configs, services)
        except Exception as error:  # noqa: BLE001 - as labd's Worker: logged, and the next poll runs the step again
            services.log(f"canary {record.run_id}: {error}; trying again in {POLL_SECONDS} s")
        _, verdict = judge_run(directory, services.clock())
        if verdict.state != PENDING:
            _finish(directory, record, repo, verdict, services)
            return verdict
        services.sleep(POLL_SECONDS)


def lane_detect(path: Path, *, clock: Callable[[], datetime] = store.utc_now) -> None:
    """alerts.detect on the lane store. The canary judges only change points (edivisive), so the lane has no
    target tiles to compute."""
    alerts = _sibling("alerts")
    db = store.Store(path, clock=clock)
    try:
        alerts.detect(db, alerts.Subscriptions.load(alerts.DEFAULT_SUBSCRIPTIONS), alerts.CatapultDetector(),
                      lambda target_id: None, floors=alerts.load_floors())
    finally:
        db.close()


def pinpoint_command(program: Path) -> Callable[[Path], None]:
    def run(path: Path) -> None:
        try:
            done = subprocess.run([str(program), "--db", str(path)], capture_output=True, text=True, timeout=600)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise CanaryError(f"{program}: {error}") from None
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
    parser.add_argument("--pinpoint-command", type=Path,
                        help="runs bisect and verification on the lane store (`PROGRAM --db LANE_DB`)")
    parser.add_argument("--json", action="store_true")


def run(command: str, args: argparse.Namespace, out=None) -> int:
    out = out or sys.stdout
    root = args.data_dir / CANARY_DIR
    now = datetime.now(timezone.utc)
    if args.last is not None:
        if args.last < 1:
            print("canary: --last needs N >= 1", file=sys.stderr)
            return 2
        return report_last(root, args.last, now, as_json=args.json, out=out)
    repo = args.repo or args.data_dir / "repo"
    git = git_runner()
    catalog = _sibling("catalog")
    labd = _sibling("labd")
    builds_mod = _sibling("builds")
    try:
        loaded = catalog.load_catalog(REPO_ROOT)
        stories = key_frame_stories(loaded.stories, scheduler.ShardMap.load(HERE / "shard_map.json"))
        if not (args.data_dir / LABD_SOCKET).exists():
            raise CanaryError(f"labd does not run on {args.data_dir} (no {LABD_SOCKET}): its scheduler starts the "
                              "canary's rounds and stores their results")
        configs = {s.config for s in scheduler.stories_from_catalog(loaded) if s.id in stories}
        services = Services(
            git=git, clock=lambda: datetime.now(timezone.utc), sleep=time.sleep,
            builds=lambda: labd.ledger_builds(scheduler, builds_mod, args.data_dir / "builds"),
            detect=lane_detect, pinpoint=pinpoint_command(args.pinpoint_command) if args.pinpoint_command else None)
        if args.run:
            tip = args.tip or scheduler.git_ls_remote(args.remote, args.branch, repo=repo)
            if not tip:
                raise CanaryError(f"cannot read the tip of {args.branch} on {args.remote}")
            git("fetch", "--quiet", "--no-tags", args.remote, f"+refs/heads/{args.branch}:refs/perf-lab/{args.branch}",
                cwd=repo)
            git("merge-base", "--is-ancestor", tip, f"refs/perf-lab/{args.branch}", cwd=repo)
            layout = choose_layout(random.Random(args.seed), args.at)
            directory = start_run(root, repo, args.remote, tip, layout, stories, services)
        else:
            scratch_ref(args.resume)
            directory = root / args.resume
        if services.pinpoint is None:
            services.log("canary: no --pinpoint-command, so the bisect and verification checks stay pending")
        verdict = drive(directory, repo, configs, services)
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

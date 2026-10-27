"""The perf lab's MVP tick: split-spring bench baselines on cmux20-bench until the scheduler is live (p12-perf-process-161).

    python3 -I scripts/perf-lab/lab.py mvp-loop   --db LAB.sqlite3 [--branch feat-cmux-next] [--worker cmux20-bench]
    python3 -I scripts/perf-lab/lab.py mvp-tick   --db LAB.sqlite3 ...      (one tick, then exit)
    python3 -I scripts/perf-lab/lab.py mvp-status [--require 3] [--json]

Until the scheduler and labd run the waterfall (p12-perf-process.md 5, H6-H12), this loop on cmux-lawrence gives the
other programs bench baselines. Each tick:

1. stops when scripts/perf-lab/SCHEDULER_LIVE exists in this checkout or on a fetched live ref (SCHEDULER_LIVE.md);
2. fetches the measured branch and takes its newest first-parent commit whose cmux-tui tree is published (a fleet
   build needs it; perf-cron.py tree_published), as the perf cron picks its tip;
3. runs that commit's scripts/measure/split-spring.sh with `--config=bench --vdisplay=120` as ONE exclusive
   measurement step at background priority on the worker, and waits for it to end (the client blocks);
4. fetches the step's report.json, converts its gestures to cmux-perf-result/v1 (motion_bench_report.split_series:
   the story's `split_spring.<right|down>.{frame,missed,resizes_sent}`) and ingests them as waterfall runs.

The next tick starts when the step ends, so the worker measures back to back, as a Chrome perf tester runs
continuously on the newest built revision (docs/speed/perf_waterfall.md). A tip that did not move is measured again:
another run of one commit is more samples of that point. A commit whose step ran and failed FAILED_LIMIT times is
not tried again; a tick that started no step (a fleet error) counts against no commit and waits IDLE_SECONDS. A git,
fleet client or lab DB error is a recorded idle, fleet-error or unrecorded tick, never the end of the loop.

The converted rows are keyed by sha and host class like any lab row. The host class is the pool's chip and memory
(pool.json) with the nominal rate the step's display held (report.json `display.refresh_ms` through host_env.hz_for,
the lab's own 120/60 rule), so a run that fell back to a 60 Hz display lands in a 60 Hz series. The fingerprint is this tick's own (`perf-lab-mvp`, worker, chip,
macOS, Hz, memory): report.json names no macOS build. Its measure_version is the measured split-spring.sh's
SPLIT_SPRING_MEASURE_VERSION. Features are unknown (the bench at the tip writes no snapshot), so they are empty.

No controller or workflow change: the step is a plain `cmux-ci run`. Restarting the loop resubmits a pending step
under its own idempotency key, which attaches to the step already queued instead of adding one. Stdlib only; loads
siblings by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
CMUX_NEXT = ROOT / "scripts" / "cmux-next"


def _sibling(name: str, path: Path):
    """The module at `path` under `name`, once per process (the names ingest.py and bench_launch.py use)."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None:
        raise ImportError(f"mvp-tick: no module at {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


ingest = _sibling("perf_lab_ingest", HERE / "ingest.py")
perf_result = ingest.perf_result
store = ingest.store

LAB_COMMANDS = {
    "mvp-tick": "one MVP tick: measure the newest tip with split-spring.sh --config=bench and ingest it",
    "mvp-loop": "MVP ticks back to back until scripts/perf-lab/SCHEDULER_LIVE exists",
    "mvp-status": "the MVP ticks so far; --require N exits 0 only when the last N measured ticks stored results",
}

STORY = "split-spring"
SCRIPT = "scripts/measure/split-spring.sh"
ARTIFACT = "artifacts/split-spring/report.json"
STEP_ARGS = ("--config=bench", "--vdisplay=120")
CONFIG = "bench"  # what --config=bench builds (reload.sh --config bench)
ENGINE = "none"
LIVE_FILE = "scripts/perf-lab/SCHEDULER_LIVE"
DEFAULT_BRANCH = "feat-cmux-next"
DEFAULT_LIVE_REFS = ("perf/chrome-parity",)
DEFAULT_WORKER = "cmux20-bench"
DEFAULT_LABELS = ("bench", "measure")  # a bench worker takes only steps that ask for `bench` (perf-cron step_labels)
DEFAULT_CLIENT = Path.home() / ".local" / "bin" / "cmux-ci"
DEFAULT_STATE_DIR = Path.home() / ".local" / "share" / "cmux-perf-lab" / "mvp-tick"
STATE_DIR_ENV = "CMUX_PERF_LAB_MVP_DIR"
STATE_SCHEMA = "cmux-perf-lab-mvp-tick/v1"
RUN_SECONDS = 3 * 3600  # a cold bench build plus both directions; the step is cancelled past this (exit 124)
QUEUE_SECONDS = 2 * 3600  # then the next tick asks again with the newest tip (exit 75)
CANDIDATE_DEPTH = 20  # first-parent commits searched for a published cmux-tui tree
FAILED_LIMIT = 2
IDLE_SECONDS = 300  # a tick that ran no step (no candidate, a fleet error) waits this long before the next
KEPT_TICKS = 500
BACKGROUND_NICE = 10
STEP_ID = re.compile(r"cmux-ci: step ([0-9a-f]{12,}) ")
SHA = re.compile(r"^[0-9a-f]{40}$")

# What a tick ended as. Only `stored` ticks count for --require. `failed` is a step that ran and failed (or a commit
# with no measure version) and counts against its commit; `fleet-error` is a tick that started no step (the client
# could not run, the controller refused or was unreachable, the checkout could not be read) and counts against nothing.
STORED, FAILED, YIELDED, UNRECORDED, IDLE, STOPPED = "stored", "failed", "yielded", "unrecorded", "idle", "stopped"
FLEET_ERROR = "fleet-error"


class TickError(RuntimeError):
    """A step's report cannot be described as result-v1 truthfully (no display rate, no macOS, an unknown worker)."""


def _cron():
    """scripts/cmux-next/perf-cron.py (tree_published, measure_version, STEP_YIELD_EXITS, step_worker)."""
    return ingest._cron_module()


def _motion():
    return _sibling("motion_bench_report", CMUX_NEXT / "motion_bench_report.py")


def _host_env():
    """scripts/perf-lab/host_env.py (hz_for: the lab's one rule from a measured frame interval to a nominal rate)."""
    return _sibling("perf_lab_host_env", HERE / "host_env.py")


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _stamp(at: datetime) -> str:
    return at.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


@dataclass(frozen=True)
class PoolHost:
    """A worker's chip and memory from pool.json's host_class (store.host_class form: chip/<n>gb/<n>hz)."""

    name: str
    chip: str
    memory_gb: int

    @classmethod
    def load(cls, worker: str, pool: Path = HERE / "pool.json") -> "PoolHost":
        try:
            hosts = json.loads(pool.read_text(encoding="utf-8"))["hosts"]
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise TickError(f"{pool}: not a lab pool ({error!r})") from None
        for host in hosts:
            if isinstance(host, dict) and host.get("name") == worker:
                match = ingest.MAC_CLASS.match(str(host.get("host_class") or ""))
                if match is None:
                    raise TickError(f"{pool}: {worker}'s host_class {host.get('host_class')!r} is not chip/<n>gb/<n>hz")
                return cls(worker, match["chip"], int(match["memory"]))
        raise TickError(f"{pool}: {worker} is not a lab host")


def measured_hz(report: dict) -> int:
    """The nominal rate (120 or 60) the step's display held: report.json `display.refresh_ms` (split-spring.sh's
    virtual display, or the real main display after VDISPLAY-FALLBACK) classified by host_env.hz_for, the rule every
    lab row's host class uses, so display jitter never splits a series."""
    display = report.get("display")
    refresh = display.get("refresh_ms") if isinstance(display, dict) else None
    if isinstance(refresh, bool) or not isinstance(refresh, (int, float)) or not refresh > 0:
        raise TickError(f"the report names no measured display refresh (display {display!r})")
    hz = _host_env().hz_for(refresh)
    if hz is None:
        raise TickError(f"the display ticked at {refresh} ms, slower than 60 Hz; no lab host class holds it")
    return hz


def host_block(report: dict, pool_host: PoolHost) -> "perf_result.Host":
    hz = measured_hz(report)
    macos = report.get("macos")
    if not isinstance(macos, str) or not re.fullmatch(perf_result.MACOS_PATTERN, macos):
        raise TickError(f"the report names no macOS version ({macos!r}); the series key needs its major")
    parts = ("perf-lab-mvp", pool_host.name, pool_host.chip, macos, hz, pool_host.memory_gb)
    fingerprint = hashlib.sha256("\0".join(str(part) for part in parts).encode()).hexdigest()
    return perf_result.Host(fingerprint=fingerprint,
                            host_class=store.host_class(chip=pool_host.chip, memory_gb=pool_host.memory_gb,
                                                        display_hz=hz),
                            chip=pool_host.chip, macos=macos, macos_build=None, display_hz=hz)


def to_results(report: object, *, sha: str, measure_version: int, pool_host: PoolHost,
               run: "perf_result.Run") -> tuple[list, dict[str, str]]:
    """The report's gestures as result-v1 results of one run, and the series not recorded with why."""
    if not isinstance(report, dict) or not isinstance(report.get("runs"), list):
        raise TickError("report.json has no runs")
    motion = _motion()
    try:
        story = motion.Story.load(STORY, ENGINE)
    except motion.StoryError as error:
        raise TickError(str(error)) from None
    host = host_block(report, pool_host)
    build = perf_result.Build(sha=sha, config=CONFIG, measure_version=measure_version)
    runs = [entry for entry in report["runs"] if isinstance(entry, dict)]
    series, skipped = motion.split_series(runs, story)
    results = [perf_result.Result(story=s.story, metric=s.metric, unit=s.unit, better="lower", samples=list(s.samples),
                                  build=build, host=host, engine=s.engine, session=s.session, run=run)
               for s in series]
    return results, skipped


def story_tier(path: Path = HERE / "stories.d" / f"{STORY}.json") -> str | None:
    try:
        tier = json.loads(path.read_text(encoding="utf-8")).get("tier")
    except (OSError, ValueError, AttributeError):
        return None
    return tier if isinstance(tier, str) else None


class Repo:
    """The lab checkout's git: one ref fetched per call, first-parent commits, a file at a ref."""

    def __init__(self, root: Path | str = ROOT, *, run: Callable[..., subprocess.CompletedProcess] = subprocess.run):
        self.root, self._run = str(root), run

    def _git(self, *args: str, timeout: int = 300) -> subprocess.CompletedProcess:
        return self._run(["git", "-C", self.root, *args], capture_output=True, text=True, timeout=timeout)

    def fetch(self, branch: str) -> bool:
        done = self._git("fetch", "--quiet", "--no-tags", "origin", f"+refs/heads/{branch}:refs/remotes/origin/{branch}")
        return done.returncode == 0

    def first_parent(self, ref: str, depth: int) -> list[str]:
        done = self._git("rev-list", "--first-parent", f"-n{depth}", ref, "--")
        return [sha for sha in done.stdout.split() if SHA.match(sha)] if done.returncode == 0 else []

    def has_file(self, ref: str, path: str) -> bool:
        return self._git("cat-file", "-e", f"{ref}:{path}", timeout=60).returncode == 0


class CmuxCi:
    """The fleet client: `cmux-ci run` (blocks until the step ends) and `cmux-ci artifact`."""

    def __init__(self, client: Path | str = DEFAULT_CLIENT, *,
                 run: Callable[..., subprocess.CompletedProcess] = subprocess.run):
        self.client, self._run = str(client), run

    def run_step(self, argv: Sequence[str], log: Path) -> int:
        with log.open("wb") as out:
            try:
                return self._run([self.client, *argv], stdout=out, stderr=subprocess.STDOUT).returncode
            except OSError as error:
                out.write(f"mvp-tick: {self.client}: {error}\n".encode())
                return 127

    def artifact(self, step_id: str, dest: Path) -> subprocess.CompletedProcess:
        return self._run([self.client, "artifact", step_id, str(dest)], capture_output=True, text=True, timeout=600)


@dataclass
class Config:
    db: Path
    state_dir: Path
    branch: str = DEFAULT_BRANCH
    live_refs: tuple[str, ...] = DEFAULT_LIVE_REFS
    worker: str = DEFAULT_WORKER
    labels: tuple[str, ...] = DEFAULT_LABELS
    run_seconds: int = RUN_SECONDS
    queue_seconds: int = QUEUE_SECONDS

    @property
    def mainline(self) -> str:
        return f"origin/{self.branch}"


@dataclass
class Seams:
    repo: Repo = field(default_factory=Repo)
    fleet: CmuxCi = field(default_factory=CmuxCi)
    published: Callable[[str], bool] = field(default_factory=lambda: _cron().tree_published)
    measure_version: Callable[[str], int | None] = field(default_factory=lambda: _cron().measure_version)
    commit_positions: Callable[[Config], Callable] = field(
        default_factory=lambda: lambda config: ingest.GitCommitPositions(ROOT, mainline=config.mainline))
    pool_host: Callable[[str], PoolHost] = PoolHost.load
    now: Callable[[], datetime] = _now
    sleep: Callable[[float], None] = time.sleep
    local_live: Path = ROOT / LIVE_FILE
    ingest_results: Callable[[Config, "Seams", Path], "ingest.IngestReport"] = field(default_factory=lambda: _ingest)


def load_state(state_dir: Path) -> dict:
    path = state_dir / "state.json"
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        state = None
    except (OSError, ValueError) as error:
        raise TickError(f"{path}: {error}") from None
    if state is None:
        return {"schema": STATE_SCHEMA, "seq": 0, "pending": None, "ticks": []}
    if not isinstance(state, dict) or state.get("schema") != STATE_SCHEMA:
        raise TickError(f"{path}: not a {STATE_SCHEMA} state")
    return state


def save_state(state_dir: Path, state: dict) -> None:
    state["ticks"] = state["ticks"][-KEPT_TICKS:]
    path = state_dir / "state.json"
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(state, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def scheduler_live(config: Config, seams: Seams) -> str | None:
    """Where SCHEDULER_LIVE was found, or None. Each live ref (and the measured branch) is fetched first."""
    if seams.local_live.exists():
        return str(seams.local_live)
    for branch in (*config.live_refs, config.branch):
        if seams.repo.fetch(branch) and seams.repo.has_file(f"origin/{branch}", LIVE_FILE):
            return f"origin/{branch}:{LIVE_FILE}"
    return None


def failures(state: dict, sha: str) -> int:
    """The ticks that failed for `sha` itself; a fleet error started no step, so it says nothing about the commit."""
    return sum(1 for tick in state["ticks"] if tick.get("sha") == sha and tick.get("state") == FAILED)


def candidate(config: Config, seams: Seams, state: dict) -> tuple[str | None, str]:
    """The newest first-parent commit of the branch that a fleet step can build, or None and why not."""
    shas = seams.repo.first_parent(config.mainline, CANDIDATE_DEPTH)
    if not shas:
        return None, f"{config.mainline} has no commits in this checkout (fetch failed?)"
    given_up = 0
    for sha in shas:
        if failures(state, sha) >= FAILED_LIMIT:
            given_up += 1
            continue
        if seams.published(sha):
            return sha, ""
    return None, (f"of the newest {len(shas)} commits of {config.mainline}, {given_up} failed {FAILED_LIMIT} times "
                  f"and the other {len(shas) - given_up} have no published cmux-tui tree")


def step_argv(config: Config, sha: str, key: str) -> list[str]:
    return ["run", "--class", "exclusive", "--measurement", "--background",
            *[part for label in config.labels for part in ("--label", label)],
            "--target-worker", config.worker, "--no-supersede", "--script", SCRIPT, "--ref", sha, "--key", key,
            "--artifact", ARTIFACT, "--timeout", str(config.run_seconds), "--queue-timeout", str(config.queue_seconds),
            *[f"--arg={arg}" for arg in STEP_ARGS]]


def _ingest(config: Config, seams: Seams, results_dir: Path) -> "ingest.IngestReport":
    db = store.Store(config.db)
    try:
        db.migrate()
        return ingest.ingest_paths(db, [results_dir], commit_positions=seams.commit_positions(config),
                                   host_name=config.worker, kind="waterfall", tier=story_tier())
    finally:
        db.close()


def _record(tick: dict, report: dict, *, sha: str, measure_version: int, config: Config, seams: Seams,
            tick_dir: Path) -> None:
    """Converts and ingests the step's report into `tick` (state stored or unrecorded)."""
    run = perf_result.Run(id=f"mvp-{tick['step_id']}", started_at=tick["submitted_at"])
    try:
        results, skipped = to_results(report, sha=sha, measure_version=measure_version,
                                      pool_host=seams.pool_host(config.worker), run=run)
    except TickError as error:
        tick.update(state=UNRECORDED, reason=str(error))
        return
    tick["skipped"] = skipped
    if not results:
        tick.update(state=UNRECORDED, reason="the report has no gesture the story records")
        return
    tick["host_class"] = results[0].host.host_class
    results_dir = tick_dir / "results"
    results_dir.mkdir(exist_ok=True)
    try:
        perf_result.write_ndjson(results_dir, results, repo_root=ROOT)
        stored = seams.ingest_results(config, seams, results_dir)
    except (perf_result.ResultError, ingest.IngestError, store.StoreError, sqlite3.Error, OSError,
            subprocess.SubprocessError) as error:  # a locked lab DB or a slow commit lookup: unrecorded, the loop goes on
        tick.update(state=UNRECORDED, reason=f"{type(error).__name__}: {error}")
        return
    tick.update(added_runs=stored.added_runs, added_results=stored.added_results,
                series=sorted(result.metric for result in results))
    if stored.rejected:
        tick.update(state=UNRECORDED, reason="; ".join(rejection.line() for rejection in stored.rejected)[:2000])
    else:
        tick["state"] = STORED


def tick(config: Config, seams: Seams) -> dict:
    """One tick; returns its record (also appended to the state's ticks unless it is `stopped`)."""
    config.state_dir.mkdir(parents=True, exist_ok=True)
    state = load_state(config.state_dir)
    pending = state.get("pending")
    try:
        live = scheduler_live(config, seams)
        if live:
            return {"state": STOPPED, "reason": f"the scheduler is live ({live})"}
        sha, why = (pending["sha"], "") if pending else candidate(config, seams, state)
    except subprocess.SubprocessError as error:  # a fetch or a probe timed out: ask again next tick
        sha, why = None, f"git: {type(error).__name__}: {error}"
    if sha is None:
        record = {"state": IDLE, "reason": why, "at": _stamp(seams.now())}
        state["ticks"].append(record)
        save_state(config.state_dir, state)  # a pending step stays pending: the next tick reattaches by its key
        return record
    if pending:
        key, seq, submitted = pending["key"], pending["seq"], pending["submitted_at"]
    else:
        state["seq"] += 1
        seq, submitted = state["seq"], _stamp(seams.now())
        key = f"perf-lab-mvp-{seq}-{sha[:12]}"
        state["pending"] = {"sha": sha, "key": key, "seq": seq, "submitted_at": submitted}
        save_state(config.state_dir, state)  # before the submit: a restart reattaches by this key
    record = {"seq": seq, "sha": sha, "key": key, "worker": config.worker, "submitted_at": submitted}
    try:
        version = seams.measure_version(sha)
    except subprocess.SubprocessError as error:  # nothing was submitted: the step stays pending under its key
        record.update(state=FLEET_ERROR, reason=f"{SCRIPT} at {sha[:12]} could not be read ({type(error).__name__}: "
                                                f"{error})", ended_at=_stamp(seams.now()))
        state["ticks"].append(record)
        save_state(config.state_dir, state)
        return record
    if version is None:
        record.update(state=FAILED, reason=f"{SCRIPT} at {sha[:12]} has no SPLIT_SPRING_MEASURE_VERSION")
    else:
        record["measure_version"] = version
        tick_dir = config.state_dir / "ticks" / f"{seq:06d}"
        tick_dir.mkdir(parents=True, exist_ok=True)
        log = tick_dir / "step.log"
        code = seams.fleet.run_step(step_argv(config, sha, key), log)
        text = log.read_bytes().decode(errors="replace")
        found = STEP_ID.search(text)
        cron = _cron()
        record.update(exit=code, step_id=found.group(1) if found else None, ran_on=cron.step_worker(text))
        tail = "\n".join(text.splitlines()[-20:])[-2000:]
        if code in cron.STEP_YIELD_EXITS:
            record.update(state=YIELDED, reason=cron.STEP_YIELD_EXITS[code])
        elif not record["step_id"]:  # no step started: the client or the controller failed, not the commit
            record.update(state=FLEET_ERROR, reason=tail)
        elif code != 0:
            record.update(state=FAILED, reason=tail)
        else:
            _collect(record, sha=sha, version=version, config=config, seams=seams, tick_dir=tick_dir)
    record["ended_at"] = _stamp(seams.now())
    state["pending"] = None
    state["ticks"].append(record)
    save_state(config.state_dir, state)
    return record


def _collect(record: dict, *, sha: str, version: int, config: Config, seams: Seams, tick_dir: Path) -> None:
    dest = tick_dir / "report.json"
    try:
        got = seams.fleet.artifact(record["step_id"], dest)
    except (OSError, subprocess.SubprocessError) as error:
        record.update(state=UNRECORDED, reason=f"cmux-ci artifact: {type(error).__name__}: {error}")
        return
    if got.returncode != 0:
        record.update(state=UNRECORDED, reason=f"cmux-ci artifact: {(got.stderr or got.stdout or '')[-500:]}")
        return
    try:
        report = json.loads(dest.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        record.update(state=UNRECORDED, reason=f"report.json: {error}")
        return
    _record(record, report, sha=sha, measure_version=version, config=config, seams=seams, tick_dir=tick_dir)


def loop(config: Config, seams: Seams, *, ticks: int | None = None) -> dict:
    """Ticks until the scheduler is live (or `ticks` ran); the next step starts when the previous one ends."""
    done = 0
    while True:
        record = tick(config, seams)
        print(f"mvp-tick: {json.dumps({k: v for k, v in record.items() if k != 'skipped'}, sort_keys=True)}", flush=True)
        if record["state"] == STOPPED:
            return record
        done += 1
        if ticks is not None and done >= ticks:
            return record
        if record["state"] in (IDLE, YIELDED, FLEET_ERROR):
            seams.sleep(IDLE_SECONDS)  # nothing ran: a fleet error or no candidate, so ask again later


def measured(ticks: Sequence[dict]) -> list[dict]:
    """The ticks that asked the fleet for a run (idle ticks ran nothing)."""
    return [t for t in ticks if t.get("state") not in (IDLE, STOPPED)]


def require_check(state: dict, count: int, worker: str) -> str | None:
    """None when the last `count` measured ticks stored results on `worker`, else why not."""
    last = measured(state["ticks"])[-count:]
    if len(last) < count:
        return f"{len(last)} measured tick(s); {count} needed"
    bad = [t for t in last if t.get("state") != STORED or (t.get("ran_on") or t.get("worker")) != worker]
    if bad:
        return "; ".join(f"tick {t.get('seq')} {t.get('state')} on {t.get('ran_on') or t.get('worker')}: "
                         f"{str(t.get('reason') or '')[:200]}" for t in bad)
    return None


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--state-dir", default=os.environ.get(STATE_DIR_ENV) or str(DEFAULT_STATE_DIR),
                        help=f"state.json and each tick's step log, report and results (default ${STATE_DIR_ENV} "
                             f"or {DEFAULT_STATE_DIR})")
    parser.add_argument("--worker", default=DEFAULT_WORKER, help=f"the bench worker (default {DEFAULT_WORKER})")
    parser.add_argument("--json", action="store_true")
    if command == "mvp-status":
        parser.add_argument("--require", type=int, default=0,
                            help="exit 1 unless the last N measured ticks stored results on the worker")
        return
    parser.add_argument("--db", default=os.environ.get(ingest.DB_ENV), help=f"the lab store; default ${ingest.DB_ENV}")
    parser.add_argument("--branch", default=DEFAULT_BRANCH, help=f"the measured branch (default {DEFAULT_BRANCH})")
    parser.add_argument("--live-ref", action="append", dest="live_refs",
                        help=f"a branch whose {LIVE_FILE} stops the loop (repeatable; default "
                             f"{', '.join(DEFAULT_LIVE_REFS)} and the measured branch)")
    parser.add_argument("--label", action="append", dest="labels",
                        help=f"a worker label the step asks for (repeatable; default {', '.join(DEFAULT_LABELS)})")
    parser.add_argument("--client", default=str(DEFAULT_CLIENT), help="the cmux-ci client")
    if command == "mvp-loop":
        parser.add_argument("--ticks", type=int, help="stop after N ticks (default: until the scheduler is live)")


def _config(args: argparse.Namespace) -> Config:
    return Config(db=Path(args.db), state_dir=Path(args.state_dir), branch=args.branch,
                  live_refs=tuple(args.live_refs or DEFAULT_LIVE_REFS), worker=args.worker,
                  labels=tuple(args.labels or DEFAULT_LABELS))


def _status(args: argparse.Namespace) -> int:
    try:
        state = load_state(Path(args.state_dir))
    except TickError as error:
        print(f"lab.py mvp-status: {error}", file=sys.stderr)
        return 2
    why = require_check(state, args.require, args.worker) if args.require else None
    if args.json:
        print(json.dumps({"pending": state.get("pending"), "ticks": state["ticks"][-20:], "require": why},
                         indent=1, sort_keys=True))
    else:
        for t in state["ticks"][-20:]:
            print(f"{t.get('seq', '-')!s:>4} {t.get('state'):<10} {str(t.get('sha') or '')[:12]:<12} "
                  f"{t.get('host_class') or '':<22} runs {t.get('added_runs', 0)} results {t.get('added_results', 0)} "
                  f"{str(t.get('reason') or '')[:120]}")
        if state.get("pending"):
            print(f"pending: {json.dumps(state['pending'], sort_keys=True)}")
        if args.require:
            print(why or f"the last {args.require} measured ticks stored results on {args.worker}")
    return 1 if why else 0


def run(command: str, args: argparse.Namespace) -> int:
    """mvp-tick and mvp-loop: exit 0 on a stored (or stopped) end, 1 otherwise, 2 when they cannot run."""
    if command == "mvp-status":
        return _status(args)
    if not args.db:
        print(f"lab.py {command}: --db or ${ingest.DB_ENV} names the lab store", file=sys.stderr)
        return 2
    config = _config(args)
    config.state_dir.mkdir(parents=True, exist_ok=True)
    seams = Seams(fleet=CmuxCi(args.client))
    with (config.state_dir / "lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)  # one loop per state dir: a second would submit twice
        except BlockingIOError:
            print(f"lab.py {command}: another MVP tick holds {config.state_dir / 'lock'}", file=sys.stderr)
            return 2
        try:
            if command == "mvp-loop":
                os.nice(BACKGROUND_NICE)  # background priority on the controller's host
                record = loop(config, seams, ticks=args.ticks)
            else:
                record = tick(config, seams)
        except TickError as error:
            print(f"lab.py {command}: {error}", file=sys.stderr)
            return 2
    if command == "mvp-tick" or args.json:
        print(json.dumps(record, indent=1, sort_keys=True))
    return 0 if record["state"] in (STORED, STOPPED) else 1


#!/usr/bin/env python3
"""MVP tick: bench baselines on one measure host before the lab's scheduler runs (p12-perf-process-161).

    python3 -I scripts/perf-lab/mvp_tick.py run --db LAB.sqlite3 --state-dir DIR --host-facts FACTS.json \
        [--worker cmux20-bench] [--branch feat-cmux-next] [--max-ticks N]
    python3 -I scripts/perf-lab/mvp_tick.py convert --report report.json --job JOB.json --host-facts FACTS.json \
        --measure-version N --out DIR

`run` is a loop. Each tick takes the newest tip of --branch and submits one background, exclusive measurement step
on --worker: `scripts/measure/split-spring.sh --config=bench --vdisplay=120` (five Cmd-D presses, 100 ms apart, in an
optimized bench build on a 120 Hz virtual display). When the step ends, report.json becomes cmux-perf-result/v1
files in DIR/results (one story per split direction, one metric per report key, one sample per round), and
`lab.py ingest` stores them. Then the next tick starts. A commit whose step failed is not submitted again; the loop
waits for a newer tip. The loop stops before a new submission once scripts/perf-lab/SCHEDULER_LIVE exists at the tip
or in this checkout (SCHEDULER_LIVE.md).

Chromium's perf waterfall works the same way: a tester bot takes the newest revision once its previous run ends
(the LUCI scheduler collapses the queued revisions into the newest), runs the benchmark, converts its output to
histograms (tools/perf/core/results_processor/processor.py) and uploads them to the dashboard.

The step's report names no chip, memory or macOS build, so --host-facts gives them per worker (SCHEDULER_LIVE.md
says how to read them). The report's own macOS version must equal the facts' version: after an OS update the loop
stops instead of storing results under the old fingerprint. The display Hz comes from the measured refresh in the
report. The host block is bench_launch.host_record's, so these rows and BenchApp.record's rows of one host share
its fingerprint and series host class.

A restart resumes the step in flight: DIR/state.json keeps its idempotency key and DIR/steps/<key>.log its id, so
the loop waits for that step again instead of submitting another. One loop per state folder (DIR/lock).

Stdlib only; loads its siblings by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import fcntl
import importlib.util
import json
import math
import os
import re
import subprocess
import sys
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
LAB_PY = HERE / "lab.py"
BENCH_LAUNCH = ROOT / "scripts" / "cmux-next" / "bench_launch.py"
DB_ENV = "CMUX_PERF_LAB_DB"

STOP_SENTINEL = "scripts/perf-lab/SCHEDULER_LIVE"
SCRIPT = "scripts/measure/split-spring.sh"
STEP_ARGS = ("--config=bench", "--vdisplay=120")
ARTIFACT = "artifacts/split-spring/report.json"
BUILD_CONFIG = "bench"
DEFAULT_WORKER = "cmux20-bench"
# The controller checks split-spring.sh against the reviewed blob at the tip of feat-cmux-next.
DEFAULT_BRANCH = "feat-cmux-next"
# A cold bench build took 323 s on cmux20-bench (perf-cron.py PARTS); the bench itself runs about two minutes.
RUN_SECONDS = 3600
# The client blocks while the step is queued behind every foreground job. After this long it is ended and the next
# tick waits for the same step by its id; the step itself keeps its place.
CLIENT_SECONDS = 4 * 3600
RETRY_SECONDS = 300
STATE_SCHEMA = "cmux-perf-lab-mvp-tick/v1"
KEPT_TICKS = 500
KEPT_FAILED = 50

# `cmux-ci run` exits that say the fleet took no step (hq build-fleet/ci-client.py; perf-cron.py STEP_YIELD_EXITS).
YIELD_EXITS = {69: "no fleet worker takes steps", 75: "queue-timeout", 76: "superseded"}
# The controller's end states of a step; any other state (queued, running) is still in flight.
DONE_STATES = ("done",)
YIELDED_STATES = ("cancelled",)
FAILED_STATES = ("failed",)
STEP_ID_RE = re.compile(r"cmux-ci: step ([0-9a-f]{12,}) ")
# perf-cron.py MEASURE_VERSION_RE
VERSION_RE = re.compile(r"""^(?:(?:export|readonly|declare(?:\s+-\w+)*)\s+)?"""
                        r"""SPLIT_SPRING_MEASURE_VERSION=(["']?)(\d+)\1\s*(?:#.*)?$""", re.MULTILINE)
UNSET_TIME = "0001-01-01T"

# The display classes of host_env.hz_for (p12-perf-process-006): 120 when it holds 8.33 ms, else 60, within 5 %.
FRAME_TOLERANCE = 1.05

# split-spring-terminal.py's per-round keys that become metrics: (report key, unit, better). Each key is the metric
# name as it is, so a row traces back to the report without a mapping.
METRICS = (
    ("frames_p50_ms", "ms", "lower"),
    ("frames_p95_ms", "ms", "lower"),
    ("frames_p99_ms", "ms", "lower"),
    ("frames_max_ms", "ms", "lower"),
    ("missed", "count", "lower"),
    ("layout_p50_ms", "ms", "lower"),
    ("layout_p95_ms", "ms", "lower"),
    ("layout_max_ms", "ms", "lower"),
    ("resizes_sent", "count", "lower"),
    ("grid_reports", "count", "lower"),
    ("hangs", "count", "lower"),
)

LAB_COMMANDS = {
    "mvp-tick": "submit split-spring --config=bench for the newest tip on one host, store result-v1, repeat",
    "mvp-convert": "convert one split-spring report.json into cmux-perf-result/v1 files",
}


def _sibling(name: str, path: Path):
    """The module at `path` under `name`, once per process (the names ingest.py and bench_launch.py use)."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None:
        raise ImportError(f"mvp_tick: no module at {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


perf_result = _sibling("perf_result", HERE / "perf_result.py")


def _bench_launch():
    return _sibling("bench_launch", BENCH_LAUNCH)


class ConvertError(ValueError):
    """A report that cannot become result-v1 truthfully; nothing of it is written."""


class HostFactsError(ConvertError):
    """The host facts do not describe the host that measured; every later tick would be refused the same way."""


# --- conversion -------------------------------------------------------------------------------------------------


def _number(value: object) -> bool:
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value)


def hz_class(refresh_ms: float) -> int | None:
    """120 or 60 for a measured refresh interval in ms; None when it does not hold 60 Hz."""
    if refresh_ms <= 1000.0 / 120 * FRAME_TOLERANCE:
        return 120
    if refresh_ms <= 1000.0 / 60 * FRAME_TOLERANCE:
        return 60
    return None


def load_host_facts(path: Path | str) -> dict[str, dict[str, object]]:
    """{worker: {chip, memory_bytes, macos, macos_build}}; raises HostFactsError naming the bad entry."""
    try:
        facts = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as error:
        raise HostFactsError(f"{path}: {error}") from None
    if not isinstance(facts, dict) or not facts:
        raise HostFactsError(f"{path}: not an object of workers")
    for worker, entry in facts.items():
        if not isinstance(entry, dict):
            raise HostFactsError(f"{path}: {worker}: not an object")
        for key in ("chip", "macos", "macos_build"):
            if not isinstance(entry.get(key), str) or not entry[key]:
                raise HostFactsError(f"{path}: {worker}.{key}: not a non-empty string")
        memory = entry.get("memory_bytes")
        if isinstance(memory, bool) or not isinstance(memory, int) or memory <= 0:
            raise HostFactsError(f"{path}: {worker}.memory_bytes: not a positive integer")
    return facts


def measure_version(script_text: str) -> int | None:
    """split-spring.sh's SPLIT_SPRING_MEASURE_VERSION, or None when the blob has none."""
    match = VERSION_RE.search(script_text or "")
    return int(match.group(2)) if match else None


def job_started_at(job: dict) -> str:
    """The step's start (else its submission) as result-v1 run.started_at."""
    for key in ("started_at", "created_at"):
        value = job.get(key)
        if isinstance(value, str) and not value.startswith(UNSET_TIME) and re.fullmatch(
                perf_result.STARTED_AT_PATTERN, value):
            return value
    raise ConvertError(f"job {job.get('id')}: no start time in RFC 3339 UTC")


def _host(report: dict, worker: str, facts: dict[str, dict[str, object]]) -> "perf_result.Host":
    display = report.get("display")
    refresh = display.get("refresh_ms") if isinstance(display, dict) else None
    if not _number(refresh) or refresh <= 0:
        raise ConvertError("display.refresh_ms is unknown: the step measured on no display that ticked")
    hz = hz_class(refresh)
    if hz is None:
        raise ConvertError(f"display.refresh_ms {refresh} does not hold 60 Hz")
    for run in report["runs"]:
        seen = run.get("refresh_ms")
        if _number(seen) and seen > 0 and hz_class(seen) != hz:
            raise ConvertError(f"run {run.get('label')!r} ticked at {seen} ms, not on the {hz} Hz display")
    entry = facts.get(worker)
    if entry is None:
        raise HostFactsError(f"the host facts name no {worker}")
    if report.get("macos") != entry["macos"]:
        raise HostFactsError(f"{worker} runs macOS {report.get('macos')!r}, the host facts say {entry['macos']!r}: "
                             "read its chip, memory and macOS build again (SCHEDULER_LIVE.md)")
    bench_launch = _bench_launch()
    try:
        record = bench_launch.host_record(entry["chip"], entry["memory_bytes"], entry["macos"], entry["macos_build"],
                                          hz)
    except bench_launch.RecordError as error:
        raise HostFactsError(str(error)) from None
    return perf_result.Host.from_dict(record)


def convert(report: object, *, job: dict, worker: str, facts: dict[str, dict[str, object]],
            measure_version: int) -> list["perf_result.Result"]:
    """The result-v1 results of one split-spring report: story split-spring[.stream].<direction>, one result per
    METRICS key that any round measured, its samples the rounds' values. Raises ConvertError."""
    if not isinstance(report, dict) or not isinstance(report.get("runs"), list) or not report["runs"]:
        raise ConvertError("report.json has no runs")
    if any(not isinstance(run, dict) for run in report["runs"]):
        raise ConvertError("report.json has a run that is not an object")
    sha = job.get("ref")
    if not isinstance(sha, str) or not re.fullmatch(perf_result.SHA_PATTERN, sha):
        raise ConvertError(f"job {job.get('id')}: ref {sha!r} is not a full commit sha")
    if job.get("worker") != worker:
        raise ConvertError(f"job {job.get('id')} ran on {job.get('worker')!r}, not {worker}")
    host = _host(report, worker, facts)
    run = perf_result.Run(id=str(job.get("id")), started_at=job_started_at(job))
    build = perf_result.Build(sha=sha, config=BUILD_CONFIG, measure_version=measure_version)
    prefix = "split-spring.stream" if report.get("stream") else "split-spring"
    directions: dict[str, list[dict]] = {}
    for entry in report["runs"]:
        direction = entry.get("direction")
        if not isinstance(direction, str) or not direction:
            raise ConvertError(f"run {entry.get('label')!r} names no direction")
        directions.setdefault(direction, []).append(entry)
    results = []
    for direction, rounds in directions.items():
        for key, unit, better in METRICS:
            samples = [entry[key] for entry in rounds if _number(entry.get(key))]
            if not samples:
                continue
            results.append(perf_result.Result(
                story=f"{prefix}.{direction}", metric=key, unit=unit, better=better, samples=samples, build=build,
                host=host, engine="none", session="light", run=run))
    if not results:
        raise ConvertError("no round measured any metric")
    try:
        for result in results:
            result.validate()
    except perf_result.ResultError as error:
        raise ConvertError(str(error)) from None
    return results


# --- the fleet, git and the ingest, behind small seams ----------------------------------------------------------

Runner = Callable[..., subprocess.CompletedProcess]


class Fleet:
    """`cmux-ci` (the controller client): no credential, the controller knows the caller by its tailnet login."""

    def __init__(self, client: str, run: Runner = subprocess.run) -> None:
        self.client = client
        self._run = run

    def _json(self, *args: str, timeout: float = 120) -> object:
        done = self._run([self.client, *args], capture_output=True, text=True, timeout=timeout)
        if done.returncode != 0:
            raise OSError(f"cmux-ci {args[0]} exited {done.returncode}: {(done.stderr or done.stdout)[-300:]}")
        try:
            return json.JSONDecoder().raw_decode((done.stdout or "").lstrip())[0]
        except ValueError:
            raise OSError(f"cmux-ci {args[0]}: no JSON in its output") from None

    def labels(self, worker: str) -> list[str] | None:
        """The labels a measure step on `worker` asks for: bench too on a bench host, which takes only steps that ask
        for it (perf-cron.py step_labels). None when the controller lists no such worker."""
        workers = self._json("workers")
        entry = workers.get(worker) if isinstance(workers, dict) else None
        if not isinstance(entry, dict):
            return None
        return ["bench", "measure"] if "bench" in (entry.get("labels") or []) else ["measure"]

    def run_step(self, argv: Sequence[str], log: Path, timeout: float) -> int | None:
        """Runs `cmux-ci run ...` with its output in `log`; its exit code, or None when it ran past `timeout`."""
        log.parent.mkdir(parents=True, exist_ok=True)
        with open(log, "ab") as out:
            try:
                return self._run([self.client, *argv], stdout=out, stderr=subprocess.STDOUT, timeout=timeout).returncode
            except subprocess.TimeoutExpired:
                return None

    def wait(self, job_id: str, timeout: float) -> None:
        try:
            self._run([self.client, "wait", job_id], capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            pass  # the step keeps running; the status read says so

    def status(self, job_id: str) -> dict:
        job = self._json("status", job_id)
        if not isinstance(job, dict) or job.get("id") != job_id:
            raise OSError(f"cmux-ci status {job_id}: not that job")
        return job

    def artifact(self, job_id: str, out: Path) -> str | None:
        """Downloads the step's artifact to `out`; None, or why it could not."""
        out.parent.mkdir(parents=True, exist_ok=True)
        done = self._run([self.client, "artifact", job_id, str(out)], capture_output=True, text=True, timeout=600)
        return None if done.returncode == 0 and out.is_file() else (done.stderr or done.stdout or "no file")[-300:]


class Repo:
    def __init__(self, path: Path | str, run: Runner = subprocess.run) -> None:
        self.path = str(path)
        self._run = run

    def _git(self, *args: str, timeout: float = 300) -> subprocess.CompletedProcess:
        return self._run(["git", "-C", self.path, *args], capture_output=True, text=True, timeout=timeout)

    def fetch_tip(self, branch: str) -> str:
        """The branch's newest commit on origin, fetched into this checkout."""
        ref = f"refs/remotes/origin/{branch}"
        fetched = self._git("fetch", "--quiet", "origin", f"+refs/heads/{branch}:{ref}")
        if fetched.returncode != 0:
            raise OSError(f"git fetch origin {branch}: {(fetched.stderr or '')[-300:]}")
        sha = self._git("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").stdout.strip()
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise OSError(f"origin/{branch} names no commit")
        return sha

    def has_file(self, sha: str, path: str) -> bool:
        return self._git("cat-file", "-e", f"{sha}:{path}", timeout=60).returncode == 0

    def show(self, sha: str, path: str) -> str:
        return self._git("show", f"{sha}:{path}", timeout=60).stdout


class Ingest:
    """`lab.py ingest` (p12-perf-process-005), the one path that stores result-v1 in the lab store."""

    def __init__(self, db: str, repo: str, run: Runner = subprocess.run, lab_py: Path = LAB_PY) -> None:
        self.db, self.repo, self.lab_py = db, repo, lab_py
        self._run = run

    def __call__(self, path: Path, host_name: str) -> dict[str, object]:
        """{"state": stored|rejected|pending, ...}: pending when nothing could run, so `lab.py ingest` of the results
        folder later stores it (an ingest is idempotent)."""
        if not self.lab_py.is_file():
            return {"state": "pending", "reason": f"{self.lab_py} is not in this checkout"}
        argv = [sys.executable, "-I", str(self.lab_py), "ingest", "--db", self.db, "--repo", self.repo,
                "--host-name", host_name, "--kind", "waterfall", "--json", str(path)]
        try:
            done = self._run(argv, capture_output=True, text=True, timeout=600)
        except subprocess.TimeoutExpired:
            return {"state": "pending", "reason": "lab.py ingest ran past 600 s"}
        try:
            report = json.loads(done.stdout) if done.returncode in (0, 1) else None
        except ValueError:
            report = None
        if report is None:
            why = (done.stderr or "")[-300:]
            return {"state": "pending", "reason": f"lab.py ingest exited {done.returncode}: {why}"}
        return {"state": "stored" if done.returncode == 0 else "rejected", **report}


# --- the loop ---------------------------------------------------------------------------------------------------


@dataclass
class Outcome:
    """What one tick did. `counts`: a step ended (a tick of --max-ticks). `wait`: back off before the next tick."""

    state: str
    reason: str = ""
    counts: bool = False
    wait: bool = False
    stop: bool = False
    fatal: bool = False
    record: dict = field(default_factory=dict)


def _utc(now: datetime) -> str:
    return now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Ticker:
    def __init__(self, *, state_dir: Path, worker: str, branch: str, facts_path: Path, fleet: Fleet, repo: Repo,
                 ingest: Callable[[Path, str], dict], now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
                 local_sentinel: Path = ROOT / STOP_SENTINEL, run_seconds: int = RUN_SECONDS,
                 client_seconds: float = CLIENT_SECONDS) -> None:
        self.state_dir, self.worker, self.branch, self.facts_path = state_dir, worker, branch, facts_path
        self.fleet, self.repo, self.ingest, self.now = fleet, repo, ingest, now
        self.local_sentinel, self.run_seconds, self.client_seconds = local_sentinel, run_seconds, client_seconds
        self.state_path = state_dir / "state.json"
        self.results_dir = state_dir / "results"

    # state.json: {"schema", "current": {key, sha, submitted_at, labels, job_id?} | null, "failed_shas", "ticks"}
    def load(self) -> dict:
        try:
            state = json.loads(self.state_path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return {"schema": STATE_SCHEMA, "current": None, "failed_shas": [], "ticks": []}
        if not isinstance(state, dict) or state.get("schema") != STATE_SCHEMA:
            raise ValueError(f"{self.state_path}: not a {STATE_SCHEMA} state")
        return state

    def save(self, state: dict) -> None:
        state["ticks"] = state["ticks"][-KEPT_TICKS:]
        state["failed_shas"] = state["failed_shas"][-KEPT_FAILED:]
        self.state_dir.mkdir(parents=True, exist_ok=True)
        temporary = self.state_path.with_name(f".{self.state_path.name}.{os.getpid()}.tmp")
        temporary.write_text(json.dumps(state, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temporary, self.state_path)

    def stop_reason(self, tip: str) -> str | None:
        if self.local_sentinel.exists():
            return f"{self.local_sentinel} exists"
        if self.repo.has_file(tip, STOP_SENTINEL):
            return f"{STOP_SENTINEL} exists at {self.branch} {tip[:12]}"
        return None

    def step_log(self, key: str) -> Path:
        return self.state_dir / "steps" / f"{key}.log"

    def submit_argv(self, sha: str, key: str, labels: Sequence[str]) -> list[str]:
        return ["run", "--class", "exclusive", "--background", "--measurement",
                *[x for label in labels for x in ("--label", label)],
                "--target-worker", self.worker, "--no-supersede", "--script", SCRIPT, "--ref", sha, "--key", key,
                "--artifact", ARTIFACT, "--timeout", str(self.run_seconds), *[f"--arg={a}" for a in STEP_ARGS]]

    def tick(self) -> Outcome:
        state = self.load()
        if state["current"] is None:
            outcome = self._start(state)
            if outcome is not None:
                return outcome
            self.save(state)  # the key is kept before the submission: a restart submits that same key again
        current = state["current"]
        log = self.step_log(current["key"])
        job_id = current.get("job_id") or self._logged_step_id(log)
        if job_id is None:
            code = self.fleet.run_step(self.submit_argv(current["sha"], current["key"], current["labels"]), log,
                                       self.client_seconds)
            job_id = self._logged_step_id(log)
            if job_id is None:
                state["current"] = None
                self.save(state)
                reason = YIELD_EXITS.get(code, f"cmux-ci run exited {code} before the controller named a step")
                return Outcome("yielded", reason, wait=True)
        else:
            self.fleet.wait(job_id, self.client_seconds)  # a step from before a restart: wait, never resubmit
        current["job_id"] = job_id
        self.save(state)
        return self._finish(state, job_id)

    def _start(self, state: dict) -> Outcome | None:
        """Picks the commit for a new step into state["current"]; an Outcome when no step starts now."""
        try:
            tip = self.repo.fetch_tip(self.branch)
        except (OSError, subprocess.SubprocessError) as error:
            return Outcome("idle", str(error), wait=True)
        stop = self.stop_reason(tip)
        if stop:
            return Outcome("stop", stop, stop=True)
        if tip in state["failed_shas"]:
            return Outcome("idle", f"{tip[:12]} failed its step; waiting for a newer {self.branch}", wait=True)
        try:
            labels = self.fleet.labels(self.worker)
        except (OSError, subprocess.SubprocessError) as error:
            return Outcome("idle", f"the controller did not answer: {error}", wait=True)
        if labels is None:
            return Outcome("idle", f"{self.worker} is not a controller worker now", wait=True)
        now = self.now()
        key = f"perf-lab-mvp-{tip[:12]}-{now.astimezone(timezone.utc).strftime('%Y%m%d%H%M%S')}"
        state["current"] = {"key": key, "sha": tip, "submitted_at": _utc(now), "labels": labels}
        return None

    @staticmethod
    def _logged_step_id(log: Path) -> str | None:
        try:
            match = STEP_ID_RE.search(log.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            return None
        return match.group(1) if match else None

    def _finish(self, state: dict, job_id: str) -> Outcome:
        current = state["current"]
        try:
            job = self.fleet.status(job_id)
        except (OSError, subprocess.SubprocessError) as error:
            return Outcome("waiting", f"step {job_id}: the controller did not answer ({error})", wait=True)
        job_state = job.get("state")
        if job_state not in DONE_STATES + YIELDED_STATES + FAILED_STATES:
            return Outcome("waiting", f"step {job_id} is {job_state}", wait=True)
        record = {"sha": current["sha"], "key": current["key"], "job_id": job_id, "job_state": job_state,
                  "worker": job.get("worker"), "submitted_at": current["submitted_at"], "ended_at": _utc(self.now())}
        if job_state in YIELDED_STATES:
            outcome = Outcome("yielded", f"step {job_id} was {job_state}", wait=True)
        elif job_state in FAILED_STATES:
            state["failed_shas"].append(current["sha"])
            outcome = Outcome("failed", f"step {job_id} {job_state} (exit {job.get('exit_code')})", counts=True)
        else:
            outcome = self._store(job)
        record.update(state=outcome.state, reason=outcome.reason, **outcome.record)
        state["ticks"].append(record)
        state["current"] = None
        self.save(state)
        outcome.record = record
        return outcome

    def _store(self, job: dict) -> Outcome:
        job_id = job["id"]
        report_path = self.state_dir / "reports" / job_id / "report.json"
        problem = self.fleet.artifact(job_id, report_path)
        if problem:
            return Outcome("failed", f"step {job_id}: no report.json ({problem})", counts=True)
        try:
            facts = load_host_facts(self.facts_path)
            version = measure_version(self.repo.show(job["ref"], SCRIPT))
            if version is None:
                raise ConvertError(f"{SCRIPT} at {job['ref'][:12]} has no SPLIT_SPRING_MEASURE_VERSION")
            report = json.loads(report_path.read_text(encoding="utf-8"))
            results = convert(report, job=job, worker=self.worker, facts=facts, measure_version=version)
            path = perf_result.write_ndjson(self.results_dir, results)
        except HostFactsError as error:
            return Outcome("refused", str(error), counts=True, fatal=True)
        except (ConvertError, perf_result.ResultError, ValueError, OSError) as error:
            return Outcome("unconverted", str(error), counts=True)
        ingested = self.ingest(path, self.worker)
        return Outcome("stored", f"{len(results)} result(s) in {path.name}; ingest {ingested.get('state')}",
                       counts=True, record={"results": str(path), "metrics": len(results), "ingest": ingested})


def run_loop(ticker: Ticker, *, max_ticks: int, retry_seconds: float,
             sleep: Callable[[float], None] = time.sleep, say: Callable[[str], None] = print) -> int:
    """Ticks until the stop sentinel (0), `max_ticks` ended steps (0), or host facts that no longer hold (1)."""
    ended = 0
    while True:
        outcome = ticker.tick()
        say(f"mvp-tick: {outcome.state}: {outcome.reason}".rstrip(": "))
        if outcome.stop:
            return 0
        if outcome.fatal:
            return 1
        if outcome.counts:
            ended += 1
            if max_ticks and ended >= max_ticks:
                return 0
        if outcome.wait:
            sleep(retry_seconds)  # the fleet or the tip gives no step to run now; a bounded back-off


# --- command line -----------------------------------------------------------------------------------------------


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--host-facts", required=True,
                        help="JSON {worker: {chip, memory_bytes, macos, macos_build}} (SCHEDULER_LIVE.md)")
    if command == "mvp-tick":
        parser.add_argument("--db", default=os.environ.get(DB_ENV), help=f"the lab store; default ${DB_ENV}")
        parser.add_argument("--state-dir", required=True, help="state.json, step logs, reports and results/")
        parser.add_argument("--worker", default=DEFAULT_WORKER)
        parser.add_argument("--branch", default=DEFAULT_BRANCH)
        parser.add_argument("--repo", default=str(ROOT), help="a full (not shallow) checkout to fetch the tip into")
        parser.add_argument("--client", default=os.path.expanduser("~/.local/bin/cmux-ci"))
        parser.add_argument("--max-ticks", type=int, default=0, help="stop after N ended steps (0: until stopped)")
        parser.add_argument("--retry-seconds", type=float, default=RETRY_SECONDS)
    else:
        parser.add_argument("--report", required=True, help="the step's report.json")
        parser.add_argument("--job", required=True, help="the step's `cmux-ci status ID` JSON")
        parser.add_argument("--measure-version", type=int, required=True, help="split-spring.sh's version at the ref")
        parser.add_argument("--worker", default=DEFAULT_WORKER)
        parser.add_argument("--out", required=True, help="folder for the result-v1 .ndjson file")


def run(command: str, args: argparse.Namespace) -> int:
    if command == "mvp-convert":
        try:
            facts = load_host_facts(args.host_facts)
            report = json.loads(Path(args.report).read_text(encoding="utf-8"))
            job = json.loads(Path(args.job).read_text(encoding="utf-8"))
            results = convert(report, job=job, worker=args.worker, facts=facts, measure_version=args.measure_version)
            print(perf_result.write_ndjson(args.out, results))
        except (ConvertError, perf_result.ResultError, OSError, ValueError) as error:
            print(f"mvp-convert: {error}", file=sys.stderr)
            return 1
        return 0
    if not args.db:
        print(f"mvp-tick: --db or ${DB_ENV} names the lab store", file=sys.stderr)
        return 2
    try:
        load_host_facts(args.host_facts)
    except HostFactsError as error:
        print(f"mvp-tick: {error}", file=sys.stderr)
        return 2
    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    lock = open(state_dir / "lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)  # one loop per state folder
    except BlockingIOError:
        print(f"mvp-tick: another loop holds {state_dir / 'lock'}", file=sys.stderr)
        return 2
    try:
        os.nice(10)  # the loop only waits on the fleet; it never competes with the person's work on this Mac
    except OSError:
        pass
    ticker = Ticker(state_dir=state_dir, worker=args.worker, branch=args.branch, facts_path=Path(args.host_facts),
                    fleet=Fleet(args.client), repo=Repo(args.repo), ingest=Ingest(args.db, args.repo))
    return run_loop(ticker, max_ticks=args.max_ticks, retry_seconds=args.retry_seconds,
                    say=lambda line: print(line, flush=True))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name, alias in (("mvp-tick", "run"), ("mvp-convert", "convert")):
        add_arguments(name, sub.add_parser(alias, help=LAB_COMMANDS[name]))
    args = parser.parse_args(argv)
    return run({"run": "mvp-tick", "convert": "mvp-convert"}[args.command], args)


if __name__ == "__main__":
    sys.exit(main())

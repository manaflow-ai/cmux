#!/usr/bin/env python3
"""Ingest of `cmux-perf-result/v1` folders and of the perf cron's history into the lab store.

    python3 -I scripts/perf-lab/lab.py ingest --db LAB.sqlite3 DIR [DIR|FILE ...]
    python3 -I scripts/perf-lab/lab.py import-perf-cron --db LAB.sqlite3 STATE.json

`ingest` reads every `*.ndjson` file (perf_result.read_file), rejects a bad file with its path and reason and stores
the rest. Results of one run and one story become one store run with one result row per metric, as chromeperf's
add_histograms turns one uploaded HistogramSet into Rows of one revision (catapult
`dashboard/dashboard/api/add_histograms.py`, `add_histograms_queue.py`). A stored run is never changed, so a run with
results in a rejected file is not stored at all until that file is fixed (`_rejected_runs`). The build config is part
of the series key (store.series_key), so a debug result lands in a debug series and is never a point of a bench series.
A waterfall point's commit position is its index on the mainline's first-parent chain, as Chromium's
Cr-Commit-Position is `refs/heads/main@{#N}`; a commit off that chain is no waterfall point.
A perf-lab job folder (perf-lab.tgz unpacked: run_story.py's summary.json beside results/) is ingested as its
results/ folder. For waterfall runs each story run's outcome in its summary is then recorded and judged by
harness_alerts.py (task 214), so a story that errors on consecutive batches opens a harness-broken group, though it
stored no result. A stored run's attachment file next to its results (`<kind>.json` whose sha256 is the declared digest) is kept in
the store by that digest (store.keep_attachment), so `lab.py queue typecheck --latest` reads it away from the builder.

`import-perf-cron` turns each good p95 of the cron's `row_history` (scripts/cmux-next/perf-cron.py, state artifact
`perf-cron-state`) into one point of a legacy series. The cron kept p95 only, from Debug builds: a legacy point has no
raw samples, carries its p95 and LEGACY_FLAGS in its summary, has a `legacy-` measure version and lives on a
`perf-cron:<host>` host class, so it is shown on the dashboard and never judged (alerts.judged_points). Its series are
never the lab's bench series (p12-perf-process.md, Risks).

Both are idempotent: a run is stored under a stable id, and store.insert_run keeps a replay of the same content as a
no-op, so a second ingest or import adds 0 rows.

Stdlib only; loads its siblings by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import re
import sqlite3
import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
PERF_CRON = ROOT / "scripts" / "cmux-next" / "perf-cron.py"
DB_ENV = "CMUX_PERF_LAB_DB"


def _sibling(name: str, path: Path):
    """The module at `path` under `name`, once per process (the names bench_launch.py uses for the same files)."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None:
        raise ImportError(f"ingest: no module at {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


perf_result = _sibling("perf_result", HERE / "perf_result.py")
perf_stats = _sibling("perf_stats", HERE / "perf_stats.py")
store = _sibling("perf_lab_store", HERE / "store.py")

# lab.py reads this literal with ast (no import) to list its commands, and imports this module only to run one.
LAB_COMMANDS = {
    "ingest": "validate cmux-perf-result/v1 files and store their runs",
    "import-perf-cron": "import a perf-cron-state history as legacy points (shown, never judged)",
}

# A legacy point's summary carries both flags. legacy_p95_only: the point is one p95 and has no raw samples.
# legacy_stat: the statistic came from the cron's own pipeline over a Debug build, not from perf_stats over raw
# samples, so no lab rule may compare it.
LEGACY_FLAGS = ("legacy_p95_only", "legacy_stat")
LEGACY_CONFIG = "debug"  # perf-cron.py measures the Debug build (p12-perf-process.md 2, "Perf cron")
LEGACY_STORY_PREFIX = "perf-cron."
LEGACY_HOST_PREFIX = "perf-cron:"
LEGACY_MEASURE_VERSION = "legacy-perf-cron"  # alerts.judged_points skips a "legacy" measure version
# The branch the lab measures: its first-parent commits give waterfall commit positions (p12-perf-process.md).
DEFAULT_MAINLINE = "origin/feat-cmux-next"
# A result-v1 host class in store.host_class form: chip / memory / display Hz.
MAC_CLASS = re.compile(r"^(?P<chip>.+)/(?P<memory>[0-9]+)gb/(?P<hz>[0-9]+)hz$")
CRON_TIME = "%Y-%m-%dT%H:%M:%SZ"
# An attachment file ingest keeps in the store (store.keep_attachment): <kind>.json next to the results, at most this
# big. A queue or a module list is kilobytes; a trace is uploaded to R2 instead (trace_quest.py).
ATTACHMENT_FILE_MAX_BYTES = 8 * 2 ** 20
JOB_SUMMARY = "summary.json"  # run_story.py's summary in a perf-lab job folder, beside its results/ folder


class IngestError(RuntimeError):
    """The ingest cannot run at all (no store, a shallow checkout); a bad file or run is a Rejection instead."""


class _Reject(Exception):
    """One run or file that is not stored; becomes a Rejection."""


@dataclass(frozen=True)
class LabHost(store.Host):
    """A store host whose series host class is the one the result declares.

    For a Mac the declared class equals store.host_class(chip, memory, Hz) (checked in `_store_host`). A Linux runner
    class or a legacy cron host has no chip/memory/Hz form, so its declared class is the series host class as is.
    """

    declared_class: str = ""

    @property
    def host_class(self) -> str:
        return self.declared_class


@dataclass(frozen=True)
class Rejection:
    source: str
    reason: str

    def line(self) -> str:
        return f"{self.source}: {self.reason}"


@dataclass
class IngestReport:
    added_runs: int = 0
    added_results: int = 0
    unchanged_runs: int = 0
    kept_attachments: int = 0
    rejected: list[Rejection] = field(default_factory=list)
    outcomes: int = 0  # story outcomes newly recorded from job folders' summaries (harness_alerts.py)
    harness_groups: list[int] = field(default_factory=list)  # harness-broken groups those outcomes opened

    def to_dict(self) -> dict[str, object]:
        return {"added_runs": self.added_runs, "added_results": self.added_results,
                "unchanged_runs": self.unchanged_runs, "kept_attachments": self.kept_attachments,
                "outcomes": self.outcomes, "harness_groups": list(self.harness_groups),
                "rejected": [{"source": r.source, "reason": r.reason} for r in self.rejected]}

    def summary_line(self) -> str:
        return (f"stored {self.added_runs} run(s) with {self.added_results} result(s); "
                f"{self.unchanged_runs} already stored; {len(self.rejected)} rejected")


@dataclass(frozen=True)
class CommitPosition:
    """A commit's first-parent count, and whether the commit is on the mainline's first-parent chain. Only a mainline
    position orders series points: a branch commit's count says nothing about where it sits on the mainline."""

    position: int
    mainline: bool


CommitPositions = Callable[[str], "CommitPosition | None"]


class GitCommitPositions:
    """Commit positions in `repo` (Chromium's Cr-Commit-Position, `refs/heads/main@{#N}`).

    A commit on the first-parent chain of `mainline` is at its index on that chain, counted from the root commit,
    which equals its `git rev-list --count --first-parent`. Any other commit gets that count with mainline False.
    None when the checkout does not have the commit.
    """

    def __init__(self, repo: Path | str, *, mainline: str = DEFAULT_MAINLINE,
                 run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> None:
        self._repo = str(repo)
        self._run = run
        self._cache: dict[str, CommitPosition | None] = {}
        shallow = self._git("rev-parse", "--is-shallow-repository")
        if shallow is None:
            raise IngestError(f"{repo}: not a git checkout; commit positions need one")
        if shallow == "true":
            raise IngestError(f"{repo}: shallow checkout; its first-parent counts are not commit positions "
                              "(git fetch --unshallow)")
        tip = self._git("rev-parse", "--verify", "--quiet", f"{mainline}^{{commit}}")
        chain = self._git("rev-list", "--first-parent", "--reverse", tip, "--") if tip else None
        if chain is None:
            raise IngestError(f"{repo}: mainline {mainline!r} is not a commit in this checkout (git fetch it)")
        self.mainline = mainline
        self._mainline = {sha: index for index, sha in enumerate(chain.split(), start=1)}

    def _git(self, *args: str) -> str | None:
        try:
            done = self._run(["git", "-C", self._repo, *args], capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return done.stdout.strip() if done.returncode == 0 else None

    def __call__(self, sha: str) -> CommitPosition | None:
        if sha in self._mainline:
            return CommitPosition(self._mainline[sha], mainline=True)
        if sha not in self._cache:
            count = self._git("rev-list", "--count", "--first-parent", f"{sha}^{{commit}}", "--")
            self._cache[sha] = CommitPosition(int(count), mainline=False) if count and count.isdigit() else None
        return self._cache[sha]


def _parse_time(text: str) -> datetime:
    """result-v1 run.started_at (RFC 3339 UTC, Z, up to 9 fraction digits) as an aware datetime (microseconds).

    The result pattern admits times that are on no calendar (second 60, February 30): such a run is rejected.
    """
    body = text[:-1]
    if "." in body:
        whole, fraction = body.split(".", 1)
        body = f"{whole}.{fraction[:6].ljust(6, '0')}"
    try:
        return datetime.fromisoformat(body).replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise _Reject(f"run.started_at {text!r} is not a valid time: {error}") from None


def _position(commit_positions: CommitPositions, sha: str, *, waterfall: bool, again: str) -> int:
    """The commit position a run of `sha` is stored at; a waterfall run needs a commit on the mainline."""
    commit = commit_positions(sha)
    if commit is None:
        raise _Reject(f"commit {sha} is not in the lab's checkout; fetch it and {again}")
    if waterfall and not commit.mainline:
        raise _Reject(f"commit {sha} is not on the mainline's first-parent chain, so a waterfall point has no "
                      "position for it (ingest a branch build with --kind try)")
    return commit.position


def _store_host(host: perf_result.Host, name: str) -> LabHost:
    hz = None if host.display_hz is None else int(round(host.display_hz))
    match = MAC_CLASS.match(host.host_class)
    if match is None:
        if host.macos is not None:
            raise _Reject(f"host.class {host.host_class!r} is not chip/<n>gb/<n>hz (store.host_class) on a Mac")
        return LabHost(name=name, chip=host.chip, memory_gb=0, display_hz=hz or 0, fingerprint=host.fingerprint,
                       declared_class=host.host_class)
    memory, class_hz = int(match["memory"]), int(match["hz"])
    derived = store.host_class(chip=host.chip, memory_gb=memory, display_hz=class_hz)
    if derived != host.host_class or (hz is not None and hz != class_hz):
        raise _Reject(f"host.class {host.host_class!r} does not match chip {host.chip!r} and display_hz "
                      f"{host.display_hz!r} (expected {derived!r})")
    return LabHost(name=name, chip=host.chip, memory_gb=memory, display_hz=class_hz, fingerprint=host.fingerprint,
                   declared_class=derived)


def _target_ref(ref: perf_result.TargetRef | None) -> str | None:
    return None if ref is None else json.dumps(ref.to_dict(), sort_keys=True, separators=(",", ":"))


def _run_fields(result: perf_result.Result) -> dict[str, object]:
    """What every result of one store run must agree on."""
    return {"started_at": result.run.started_at, "build": result.build.to_dict(), "host": result.host.to_dict(),
            "engine": result.engine, "session": result.session,
            "features": {name: feature.to_dict() for name, feature in sorted(result.features.items())},
            "features_hash": result.features_hash, "safe_mode": result.safe_mode}


@dataclass
class _Group:
    run_id: str
    story: str
    results: list[tuple[Path, perf_result.Result]] = field(default_factory=list)

    @property
    def run_uuid(self) -> str:
        return f"{self.run_id}/{self.story}"

    @property
    def source(self) -> str:
        files = sorted({str(path) for path, _ in self.results})
        return f"run {self.run_uuid} ({', '.join(files)})"


def _result_files(paths: Sequence[Path | str], rejected: list[Rejection], jobs: list[Path]) -> list[Path]:
    """Each named .ndjson file, and each folder's `*.ndjson` files in name order (not recursive, as read_dir). A
    perf-lab job folder (JOB_SUMMARY in it) goes to `jobs` and gives its results/ folder's files."""
    files: list[Path] = []
    for path in map(Path, paths):
        if path.is_dir() and (path / JOB_SUMMARY).is_file():
            jobs.append(path)
            path = path / "results"  # absent when the runner refused the job before any story ran
            if not path.is_dir():
                continue
        if path.is_dir():
            files.extend(p for p in sorted(path.glob("*.ndjson")) if not p.name.startswith(".") and p.is_file())
        elif path.is_file():
            files.append(path)
        else:
            rejected.append(Rejection(str(path), "no such file or folder"))
    return files


def _store_records(group: _Group, *, commit_positions: CommitPositions, host_name: str | None, kind: str,
                   tier: str | None, job_id: int | None) -> tuple[store.Run, store.Build, LabHost, list[store.Metric]]:
    first = group.results[0][1]
    expected = _run_fields(first)
    for path, result in group.results[1:]:
        fields = _run_fields(result)
        differing = sorted(name for name in expected if fields[name] != expected[name])
        if differing:
            raise _Reject(f"{path} disagrees with the run's other results on {', '.join(differing)}")
    metrics: list[store.Metric] = []
    seen: set[str] = set()
    for path, result in group.results:
        if result.metric in seen:
            raise _Reject(f"metric {result.metric} is recorded twice (again in {path})")
        seen.add(result.metric)
        metrics.append(store.Metric(name=result.metric, unit=result.unit, better=result.better,
                                    samples=list(result.samples), summary=perf_stats.summary(result.samples),
                                    target_ref=_target_ref(result.target_ref)))
    position = _position(commit_positions, first.build.sha, waterfall=kind == "waterfall", again="ingest again")
    host = _store_host(first.host, host_name or f"fp-{first.host.fingerprint[:12]}")
    attachments: list[dict[str, str]] = []
    for _, result in group.results:
        for attachment in result.attachments:
            if attachment.to_dict() not in attachments:
                attachments.append(attachment.to_dict())
    run = store.Run(
        run_uuid=group.run_uuid, kind=kind, measure_version=str(first.build.measure_version), story=group.story,
        engine=first.engine, macos_major=int(first.host.macos.split(".")[0]) if first.host.macos else 0,
        macos_build=first.host.macos_build or "", features_hash=first.features_hash or "",
        safe_mode=first.safe_mode or "", started_at=_parse_time(first.run.started_at),
        features={name: feature.to_dict() for name, feature in sorted(first.features.items())},
        attachments=tuple(attachments), tier=tier, session=first.session, job_id=job_id)
    build = store.Build(sha=first.build.sha, config=first.build.config, commit_pos=position)
    return run, build, host, metrics


def _insert(db: store.Store, report: IngestReport, source: str, run: store.Run, build: store.Build, host: LabHost,
            metrics: Sequence[store.Metric]) -> bool:
    """True when the run is stored (now or before)."""
    existed = bool(db.run_metrics(run.run_uuid))
    try:
        db.insert_run(run, build=build, host=host, metrics=metrics)
    except (store.StoreError, sqlite3.IntegrityError) as error:
        report.rejected.append(Rejection(source, str(error)))
        return False
    if existed:
        report.unchanged_runs += 1
    else:
        report.added_runs += 1
        report.added_results += len(metrics)
    return True


def _keep_attachments(db: store.Store, group: _Group, run: store.Run) -> int:
    """Keeps the bytes of each of the run's attachments found next to its results: <kind>.json in a result file's
    folder whose sha256 is the declared digest. Returns how many; any other attachment stays a digest only."""
    folders = sorted({path.parent for path, _ in group.results})
    kept = 0
    for attachment in run.attachments:
        kind, digest = attachment["kind"], attachment["digest"]
        for folder in folders:
            candidate = folder / f"{kind}.json"
            try:
                if not candidate.is_file() or candidate.stat().st_size > ATTACHMENT_FILE_MAX_BYTES:
                    continue
                data = candidate.read_bytes()
            except OSError:
                continue
            if f"sha256:{hashlib.sha256(data).hexdigest()}" == digest:
                db.keep_attachment(kind, data)
                kept += 1
                break
    return kept


def _file_reason(path: Path, error: perf_result.ResultError) -> str:
    """read_file's "PATH:LINE: reason" or "PATH: reason" without the path, as "line N: reason" or "reason"."""
    reason = str(error).removeprefix(f"{path}:").lstrip()
    line = re.match(r"^([0-9]+): ", reason)
    return f"line {line[1]}: {reason[line.end():]}" if line else reason


def _rejected_runs(path: Path) -> set[str] | None:
    """The run ids of a rejected file's lines; None when it cannot be read or a line names no run."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return None
    runs: set[str] = set()
    for line in filter(str.strip, lines):
        try:
            run_id = json.loads(line)["run"]["id"]
        except (ValueError, TypeError, KeyError):
            return None
        if not isinstance(run_id, str):
            return None
        runs.add(run_id)
    return runs


def _incomplete(group: _Group, runs: dict[str, Path], folders: dict[Path, Path]) -> str | None:
    """Why `group` may lack results of a rejected file, or None. A stored run is never changed, so a run stored
    without them would stay without them."""
    if group.run_id in runs:
        return f"{runs[group.run_id]} holds results of this run and was rejected; fix it and ingest again"
    for path, _ in group.results:
        if path.parent in folders:
            return (f"{folders[path.parent]} in the same folder was rejected and its runs are unknown; "
                    "fix it and ingest again")
    return None


def ingest_paths(db: store.Store, paths: Sequence[Path | str], *, commit_positions: CommitPositions,
                 host_name: str | None = None, kind: str = "waterfall", tier: str | None = None,
                 job_id: int | None = None) -> IngestReport:
    """Stores every valid result under `paths`; a bad file or an inconsistent run is rejected, the rest is stored.

    `job_id`: the lab job (jobs row) whose controller job produced these results; every stored run links to it
    (Run.job_id). Pinpoint's executor ingests each story job's artifact this way and reads the runs back by it.

    A run is stored whole or not at all: a run with results in a rejected file, or with results next to a rejected
    file whose runs are unknown, is rejected too.
    """
    if kind not in store.RUN_KINDS:
        raise IngestError(f"run kind {kind!r} is not one of {store.RUN_KINDS}")
    report = IngestReport()
    groups: dict[tuple[str, str], _Group] = {}
    rejected_runs: dict[str, Path] = {}
    rejected_folders: dict[Path, Path] = {}
    jobs: list[Path] = []
    for path in _result_files(paths, report.rejected, jobs):
        try:
            results = perf_result.read_file(path)
        except perf_result.ResultError as error:
            report.rejected.append(Rejection(str(path), _file_reason(path, error)))
            runs = _rejected_runs(path)
            if runs is None:
                rejected_folders.setdefault(path.parent, path)
            for run_id in runs or ():
                rejected_runs.setdefault(run_id, path)
            continue
        for result in results:
            key = (result.run.id, result.story)
            groups.setdefault(key, _Group(result.run.id, result.story)).results.append((path, result))
    for group in sorted(groups.values(), key=lambda g: (g.results[0][1].run.started_at, g.run_uuid)):
        incomplete = _incomplete(group, rejected_runs, rejected_folders)
        if incomplete is not None:
            report.rejected.append(Rejection(group.source, incomplete))
            continue
        try:
            records = _store_records(group, commit_positions=commit_positions, host_name=host_name, kind=kind,
                                     tier=tier, job_id=job_id)
        except _Reject as reason:
            report.rejected.append(Rejection(group.source, str(reason)))
            continue
        if _insert(db, report, group.source, *records):
            report.kept_attachments += _keep_attachments(db, group, records[0])
    if kind == "waterfall":
        for folder in jobs:
            _record_outcomes(db, folder, report, commit_positions=commit_positions, host_name=host_name)
    return report


def _harness_alerts():
    return _sibling("perf_lab_harness_alerts", HERE / "harness_alerts.py")


def _record_outcomes(db: store.Store, folder: Path, report: IngestReport, *, commit_positions: CommitPositions,
                     host_name: str | None) -> None:
    """Records the story outcomes of a waterfall job folder's summary at its batch tip and runs the harness-broken
    detection on them (harness_alerts.record_summary), after the folder's results are stored."""
    harness = _harness_alerts()
    source = str(folder / JOB_SUMMARY)
    try:
        summary = json.loads((folder / JOB_SUMMARY).read_text(encoding="utf-8"))
        sha = summary.get("sha") if isinstance(summary, dict) else None
        if not isinstance(sha, str) or not sha:
            raise _Reject("names no measured sha")
        position = _position(commit_positions, sha, waterfall=True, again="ingest again")
        detected = harness.record_summary(db, summary, batch_pos=position, host=host_name)
    except (OSError, UnicodeDecodeError, ValueError) as error:
        report.rejected.append(Rejection(source, f"not readable JSON ({error})"))
        return
    except (_Reject, harness.HarnessAlertsError) as reason:
        report.rejected.append(Rejection(source, str(reason)))
        return
    report.outcomes += detected.recorded
    report.harness_groups += detected.groups_created


def _cron_module():
    return _sibling("perf_cron", PERF_CRON)


def _cron_units(state: dict) -> dict[str, str]:
    """Row name -> unit from the state's measurement records (row_history entries carry no unit)."""
    units: dict[str, str] = {}
    for key in ("last", "last_good"):
        record = state.get(key)
        rows = record.get("rows") if isinstance(record, dict) else None
        for name, row in (rows or {}).items():
            if isinstance(row, dict) and isinstance(row.get("unit"), str) and row["unit"]:
                units[name] = row["unit"]
    return units


def _cron_shas(state: dict, cron) -> dict[str, str]:
    """Measurement time -> sha, for history entries written before they carried their sha (perf-cron remember_good)."""
    shas: dict[str, str] = {}
    for entry in state.get("history") or []:
        if isinstance(entry, dict) and entry.get("kind") == "tip" and cron.is_sha(entry.get("sha")):
            shas.setdefault(entry.get("at"), entry["sha"])
    for key in ("last", "last_good"):
        record = state.get(key)
        if isinstance(record, dict) and cron.is_sha(record.get("sha")) and isinstance(record.get("measured_at"), str):
            shas.setdefault(record["measured_at"], record["sha"])
    return shas


def _cron_point(cron, name: str, entry: object, *, units: dict[str, str], shas: dict[str, str],
                commit_positions: CommitPositions) -> tuple[store.Run, store.Build, LabHost, list[store.Metric]]:
    if not isinstance(entry, dict):
        raise _Reject("history entry is not an object")
    value, at = entry.get("p95"), entry.get("at")
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise _Reject(f"p95 {value!r} is not a finite number")
    try:
        started = datetime.strptime(at, CRON_TIME).replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        raise _Reject(f"time {at!r} is not {CRON_TIME}") from None
    row, host_name = cron.base_row(name), cron.row_host(name)
    part = cron.part_for_row(name)
    if part is None:
        raise _Reject("no perf-cron part measures this row")
    if not host_name:
        raise _Reject("the row names no host")
    story, metric = f"{LEGACY_STORY_PREFIX}{part}", row
    for label, text in (("story", story), ("metric", metric)):
        if not re.fullmatch(perf_result.NAME_PATTERN, text):
            raise _Reject(f"{label} {text!r} does not match {perf_result.NAME_PATTERN}")
    unit = units.get(name)
    if unit is None:
        raise _Reject("the state's measurement records give this row no unit")
    sha = entry.get("sha") if cron.is_sha(entry.get("sha")) else shas.get(at)
    if sha is None:
        raise _Reject(f"no commit is known for the measurement at {at}")
    position = _position(commit_positions, sha, waterfall=True, again="import again")
    lab_class = f"{LEGACY_HOST_PREFIX}{host_name}"
    host = LabHost(name=host_name, chip="unknown", memory_gb=0, display_hz=0, fingerprint=lab_class,
                   declared_class=lab_class)
    run = store.Run(run_uuid=f"perf-cron:{name}:{at}", kind="waterfall", measure_version=LEGACY_MEASURE_VERSION,
                    story=story, engine="none", macos_major=0, macos_build="", features_hash="", safe_mode="",
                    started_at=started)
    summary = {"p95": value, **dict.fromkeys(LEGACY_FLAGS, True)}
    metrics = [store.Metric(name=metric, unit=unit, better="lower", samples=[], summary=summary)]
    return run, store.Build(sha=sha, config=LEGACY_CONFIG, commit_pos=position), host, metrics


def import_perf_cron(db: store.Store, state: object, *, commit_positions: CommitPositions,
                     source: str = "perf-cron-state") -> IngestReport:
    """Stores every good p95 in the state's row_history as one legacy point; returns what was stored or refused.

    Each point is its own run (`perf-cron:<row>:<time>`), so an older and a newer artifact that both hold the
    same value import it once, whatever else either holds.
    """
    report = IngestReport()
    if not isinstance(state, dict) or not isinstance(state.get("row_history"), dict):
        report.rejected.append(Rejection(source, "not a perf-cron state: no row_history object"))
        return report
    cron = _cron_module()
    if state.get("schema") != cron.SCHEMA:
        report.rejected.append(Rejection(source, f"state schema {state.get('schema')!r} is not {cron.SCHEMA}"))
        return report
    units, shas = _cron_units(state), _cron_shas(state, cron)
    for raw_name, history in sorted(state["row_history"].items()):
        name = cron.legacy_row_name(raw_name)
        if not isinstance(history, list):
            report.rejected.append(Rejection(f"{source} row {raw_name}", "history is not a list"))
            continue
        for index, entry in enumerate(history):
            where = f"{source} row {raw_name}[{index}]"
            try:
                records = _cron_point(cron, name, entry, units=units, shas=shas, commit_positions=commit_positions)
            except _Reject as reason:
                report.rejected.append(Rejection(where, str(reason)))
                continue
            _insert(db, report, where, *records)
    return report


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--db", default=os.environ.get(DB_ENV),
                        help=f"the lab store (SQLite); default ${DB_ENV}")
    parser.add_argument("--repo", default=str(ROOT), help="git checkout that resolves commit positions")
    parser.add_argument("--mainline", default=DEFAULT_MAINLINE,
                        help=f"the ref whose first-parent chain orders waterfall points (default {DEFAULT_MAINLINE})")
    parser.add_argument("--json", action="store_true", help="print the report as JSON")
    if command == "ingest":
        parser.add_argument("paths", nargs="+", help="result folders (their *.ndjson files), perf-lab job folders "
                                                     "(summary.json and results/) or .ndjson files")
        parser.add_argument("--host-name", help="the lab host that measured the results (default fp-<fingerprint>)")
        parser.add_argument("--kind", default="waterfall", choices=store.RUN_KINDS,
                            help="what the runs were for; only waterfall runs are series points")
        parser.add_argument("--tier", help="the tier the runs belong to (T0, T1, T2)")
    else:
        parser.add_argument("state", help="state.json of a perf-cron-state artifact")


def _print(report: IngestReport, as_json: bool) -> None:
    if as_json:
        print(json.dumps(report.to_dict(), indent=2, sort_keys=True))
        return
    for rejection in report.rejected:
        print(f"rejected: {rejection.line()}", file=sys.stderr)
    print(report.summary_line())


def run(command: str, args: argparse.Namespace) -> int:
    """Exit 0 when everything was stored (or already was), 1 when anything was rejected, 2 when nothing could run."""
    if not args.db:
        print(f"lab.py {command}: --db or ${DB_ENV} names the lab store", file=sys.stderr)
        return 2
    state = None
    if command == "import-perf-cron":
        try:
            state = json.loads(Path(args.state).read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError) as error:
            print(f"lab.py {command}: {args.state}: {error}", file=sys.stderr)
            return 2
    try:
        positions = GitCommitPositions(args.repo, mainline=args.mainline)
        db = store.Store(args.db)
    except (IngestError, store.StoreError, sqlite3.Error) as error:
        print(f"lab.py {command}: {error}", file=sys.stderr)
        return 2
    try:
        db.migrate()
    except (store.StoreError, sqlite3.Error) as error:
        db.close()
        print(f"lab.py {command}: {error}", file=sys.stderr)
        return 2
    try:
        if command == "ingest":
            report = ingest_paths(db, args.paths, commit_positions=positions, host_name=args.host_name,
                                  kind=args.kind, tier=args.tier)
        else:
            report = import_perf_cron(db, state, commit_positions=positions, source=args.state)
    finally:
        db.close()
    _print(report, args.json)
    return 1 if report.rejected else 0

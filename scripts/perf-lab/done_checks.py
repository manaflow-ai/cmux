#!/usr/bin/env python3
"""The perf lab's done checks (p12-perf-process.md section 6) as one runner.

    python3 scripts/perf-lab/lab.py done-checks [--json] [--only 1,3,9] [--kill-switch-evidence DIR]

CHECKS is the one table: each row holds the check's commands (as section 6 writes them, plus --json where the
runner reads JSON), its thresholds in the spec's own units, and the judge that compares the two. The judges own
no numbers. Queries come from queues.py (task 200): `queues.find(MQ).run(root)`, each item's key one hit, and
its ALLOWLIST. MQ4 is section 7's pipeline (`lab.py stories --lint --format=paths`, then the files without a
result-v1 writer), since queues.py does not hold it. Check 3 reads each target's stories from the story catalog
(catalog.py, task 007). Check 4 reads the lab store (store.py's schema, $CMUX_PERF_LAB_DB) read-only: `lab.py runs`
has no --config or --tier and prints no metric values.

It prints one line per check (a JSON object with --json) and exits 0 only when every judged check passes; field
and stability (check 18) are reported, never judged, because opt-in Nightly data in 72 h is small (3.10).
A check that cannot see its data fails with the reason; it never passes on missing output.

Chrome's analog is the perf waterfall's per-builder status: each step's command and expectation are data
(tools/perf/core/bot_platforms.py, tools/perf/expectations.config), and the runner only executes and judges them.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shlex
import sqlite3
import subprocess
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import ModuleType
from typing import Protocol

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
LAB_COMMANDS = {"done-checks": "run every perf-lab done check (p12-perf-process.md section 6)"}
DB_ENV = "CMUX_PERF_LAB_DB"
ALLOWLIST_QUERY = "ALLOWLIST"  # queues.ALLOWLIST: the files MQ1 keeps, by repo path

PASS, FAIL, REPORTED = "pass", "fail", "reported"


class DoneCheckError(Exception):
    """A check cannot read what it judges: a missing command, key, file or query."""


@dataclass(frozen=True)
class Command:
    """One command of a check. `run=False` names a command the runner does not run: the judge reads the same answer
    from evidence files or the lab store."""
    argv: str
    spec: bool = True  # section 6 writes this command (tests hold the row to the spec text)
    run: bool = True
    timeout_s: int = 900


@dataclass(frozen=True)
class CommandResult:
    argv: str
    returncode: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class TargetMap:
    """One fixed target as the catalog maps it: its rows' engines, whether every row check has a story, the stories."""
    id: str
    browser: bool
    engines: tuple[str, ...]
    mapped: bool
    stories: tuple[str, ...]


Targets = Callable[[Path], list[TargetMap]]


class RunStore(Protocol):
    """The lab store as check 4 reads it (LabStore; tests pass a fake)."""

    def runs(self, *, since_hours: float, config: str, tiers: Sequence[str]) -> list[dict[str, object]]:
        """Runs of any kind started in the window on a build of `config` at one of `tiers`, oldest first:
        {"run_uuid", "kind", "tier", "story", "sha", "config", "started_at"}."""
        ...

    def newest_point(self, metric: str, *, since_hours: float) -> dict[str, object] | None:
        """The newest waterfall result of `metric` in the window: {"run_uuid", "story", "sha", "started_at", "p50"}."""
        ...


@dataclass
class Evidence:
    root: Path
    outputs: list[CommandResult]
    queries: dict[str, list[str]]
    kill_switch_evidence: Path | None = None
    targets: Targets | None = None
    store: RunStore | None = None


Verdict = tuple[bool, dict[str, object], str]
Judge = Callable[[Evidence, Mapping[str, object]], Verdict]


@dataclass(frozen=True)
class Check:
    number: int
    name: str
    commands: tuple[Command, ...]
    threshold: Mapping[str, object]
    judge: Judge
    queries: tuple[str, ...] = ()
    reported_only: bool = False


# --- reading outputs ---------------------------------------------------------------------------------------------

def _get(obj: object, key: str) -> object:
    if not isinstance(obj, Mapping) or key not in obj:
        raise DoneCheckError(f"output lacks {key!r}")
    return obj[key]


def _number(obj: object, key: str) -> float:
    value = _get(obj, key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise DoneCheckError(f"{key!r} is not a number: {value!r}")
    return value


def _list(obj: object, key: str | None = None) -> list:
    value = obj if key is None else _get(obj, key)
    if not isinstance(value, list):
        raise DoneCheckError(f"{key or 'output'} is not a list")
    return value


def _tail(result: CommandResult) -> str:
    return (result.stderr or result.stdout).strip()[-300:]


def _json(result: CommandResult) -> object:
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        raise DoneCheckError(f"`{result.argv}` exited {result.returncode} without JSON: {_tail(result)}") from None


def _exited_zero(result: CommandResult) -> None:
    if result.returncode != 0:
        raise DoneCheckError(f"`{result.argv}` exited {result.returncode}: {_tail(result)}")


def _percent_of(part: int, whole: int) -> float:
    return round(100.0 * part / whole, 2)


def _verdict(failures: list[str], measured: dict[str, object]) -> Verdict:
    return (not failures, measured, "; ".join(failures))


# --- judges (thresholds come only from the row) -----------------------------------------------------------------

def judge_coverage_t0(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    """Reads {"planned", "covered", "batch_minutes", "window_minutes"}: coverage counts planned batches (every-2nd-batch mode plans half)."""
    report = _json(ev.outputs[0])
    failures = []
    for key in ("batch_minutes", "window_minutes"):
        if _number(report, key) != t[key]:
            failures.append(f"coverage used {key}={report[key]}, the spec says {t[key]}")
    planned, covered = int(_number(report, "planned")), int(_number(report, "covered"))
    if planned == 0:
        return _verdict(["0 planned T0 batches since lab-live"], {"planned": 0})
    covered_pct = _percent_of(covered, planned)
    if covered_pct < t["min_covered_pct"]:
        failures.append(f"{covered}/{planned} batches covered ({covered_pct} %), need >= {t['min_covered_pct']} %")
    return _verdict(failures, {"planned": planned, "covered": covered, "covered_pct": covered_pct})


def judge_coverage_t1(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    """Reads {"newest_complete_age_hours": float | None, "missing_families": [str]}."""
    report = _json(ev.outputs[0])
    age = _get(report, "newest_complete_age_hours")
    missing = _list(report, "missing_families")
    failures = []
    if age is None:
        failures.append("no complete T1 yet")
    elif _number(report, "newest_complete_age_hours") > t["max_age_hours"]:
        failures.append(f"newest complete T1 is {age} h old, need <= {t['max_age_hours']} h")
    if len(missing) > t["max_missing_families"]:
        failures.append(f"missing story families: {', '.join(map(str, missing))}")
    return _verdict(failures, {"newest_complete_age_hours": age, "missing_families": missing})


TARGETS_MAPPED = re.compile(r"^targets mapped: (\d+)/(\d+)$", re.M)


def judge_targets(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    """Reads `targets --check` ("targets mapped: N/M"), the waterfall runs JSON (trace_quest.runs_since rows, each
    {"story", "kind", "started_at", ...}) and the catalog's targets."""
    check, runs = ev.outputs
    match = TARGETS_MAPPED.search(check.stdout)
    if match is None:
        raise DoneCheckError(f"`{check.argv}` exited {check.returncode} without a mapped count: {_tail(check)}")
    mapped, total = int(match.group(1)), int(match.group(2))
    failures = []
    if check.returncode != 0 or (mapped, total) != (t["targets"], t["targets"]):
        failures.append(f"{mapped}/{total} targets mapped, need {t['targets']}/{t['targets']}")
    if ev.targets is None:
        raise DoneCheckError("no story catalog to read the targets' stories from")
    targets = ev.targets(ev.root)
    engines = set(t["browser_engines"])
    for target in targets:
        if target.browser and not engines <= set(target.engines):
            failures.append(f"{target.id} lacks an engine row ({', '.join(sorted(engines - set(target.engines)))})")
    try:
        stored = [str(_get(run, "story")) for run in _list(_json(runs))]
    except DoneCheckError as error:  # the mapped count above still reports
        return _verdict([*failures, str(error)], {"mapped": mapped, "total": total})
    stale = sorted({story for target in targets if target.mapped for story in target.stories
                    if stored.count(story) < t["min_results"]})
    if stale:
        failures.append(f"mapped stories with no stored result in the runs window: {', '.join(stale)}")
    return _verdict(failures, {"mapped": mapped, "total": total, "stories_without_results": stale})


def judge_release_grade(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    """The spec's `runs --config debug --tier T0,T1` rows and the parity series' newest point, both from the store."""
    if ev.store is None:
        raise DoneCheckError(f"no lab store: set ${DB_ENV}")
    window, config, tiers = t["window_hours"], str(t["config"]), tuple(map(str, t["tiers"]))
    debug_rows = ev.store.runs(since_hours=window, config=config, tiers=tiers)
    point = ev.store.newest_point(str(t["parity_metric"]), since_hours=window)
    failures = []
    if len(debug_rows) > t["max_debug_runs"]:
        first = debug_rows[0]
        failures.append(f"{len(debug_rows)} {config}-config {'/'.join(tiers)} runs in {window} h, first "
                        f"{_get(first, 'story')} at {_get(first, 'started_at')}")
    delta = None if point is None else _get(point, "p50")
    if delta is None:
        failures.append(f"no {t['parity_metric']} waterfall result in {window} h")
    elif abs(_number(point, "p50")) > t["max_parity_delta_pct"]:
        failures.append(f"{t['parity_metric']} = {delta} % at {_get(point, 'started_at')}, "
                        f"need within {t['max_parity_delta_pct']} %")
    return _verdict(failures, {"debug_runs": len(debug_rows), t["parity_metric"]: delta})


def judge_one_format(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    """MQ1 from queues.py, whose ALLOWLIST must be the row's; MQ4 is each story command path
    (`stories --lint --format=paths`) with no result-v1 writer."""
    kept, allowed = sorted(ev.queries[ALLOWLIST_QUERY]), sorted(t["mq1_allowlist"])
    private_stats = ev.queries["MQ1"]
    listing = ev.outputs[0]
    paths = [line.strip() for line in listing.stdout.splitlines() if line.strip()]
    if not paths:
        raise DoneCheckError(f"`{listing.argv}` printed no story command paths: {_tail(listing)}")
    writes_result = re.compile(str(t["mq4_result_writer"]))
    unwritten = []
    for path in paths:
        try:
            text = (ev.root / path).read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            raise DoneCheckError(f"MQ4 cannot read {path}: {error}") from None
        if not writes_result.search(text):
            unwritten.append(path)
    failures = []
    if kept != allowed:
        failures.append(f"queues.py's MQ1 allowlist is {', '.join(kept) or 'empty'}, the spec allows "
                        f"{', '.join(allowed)}")
    if len(private_stats) > t["max_mq1_outside_allowlist"]:
        failures.append(f"MQ1 outside the allowlist: {', '.join(private_stats)}")
    if len(unwritten) > t["max_mq4"]:
        failures.append(f"MQ4 stories without result-v1: {', '.join(unwritten)}")
    return _verdict(failures, {"mq1_allowlist": kept, "mq1_outside_allowlist": private_stats, "mq4": unwritten})


def _query_empty(name: str, limit_key: str, label: str) -> Judge:
    def judge(ev: Evidence, t: Mapping[str, object]) -> Verdict:
        hits = ev.queries[name]
        failures = [f"{label}: {', '.join(hits)}"] if len(hits) > t[limit_key] else []
        return _verdict(failures, {name: hits})
    return judge


def judge_orphans(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    """Reads [str]: the orphan scripts."""
    orphans = _list(_json(ev.outputs[0]))
    failures = [f"{len(orphans)} orphan benches"] if len(orphans) > t["max_orphans"] else []
    return _verdict(failures, {"orphans": orphans})


def judge_noise(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    """Reads aa.py's {"summary": {...}} (task 024): its CV limits and shares are fractions, the row's are percent."""
    summary = _get(_json(ev.outputs[0]), "summary")
    limits = _get(summary, "thresholds")
    failures = []
    for key, row_key in (("median_cv", "max_median_cv_pct"), ("p99_cv", "max_p99_cv_pct")):
        if round(100.0 * _number(limits, key), 6) != t[row_key]:
            failures.append(f"aa judged {key} at {100.0 * limits[key]:g} %, the spec says {t[row_key]} %")
    hosts = [str(host) for host in _list(summary, "waterfall_hosts")]
    runs = _get(summary, "aa_runs_by_host")
    if not hosts:
        failures.append("no waterfall host in the A/A window")
    short = [f"{host}={int(_number(runs, host))}" for host in hosts
             if _number(runs, host) < t["min_aa_runs_per_waterfall_host"]]
    if short:
        failures.append(f"hosts under {t['min_aa_runs_per_waterfall_host']} A/A runs: {', '.join(short)}")
    rate = _get(summary, "false_alerts_per_100_series_days")
    if rate is None:
        failures.append("no false-alert rate (0 monitored series-days)")
    elif _number(summary, "false_alerts_per_100_series_days") > t["max_false_alerts_per_100_series_days"]:
        failures.append(f"{rate:.3f} false alerts per 100 series-days")
    measured: dict[str, object] = {"false_alerts_per_100_series_days": rate,
                                   "latency_series": _get(summary, "latency_series_judged")}
    for key, max_key, min_key in (("median_cv_share_within", "max_median_cv_pct", "min_median_cv_series_pct"),
                                  ("p99_cv_share_within", "max_p99_cv_pct", "min_p99_cv_series_pct")):
        if _get(summary, key) is None:
            failures.append(f"{key}: 0 judged latency series")
            continue
        share_pct = round(100.0 * _number(summary, key), 2)
        measured[key] = share_pct
        if share_pct < t[min_key]:
            failures.append(f"{share_pct} % of latency series within {t[max_key]} % CV, need >= {t[min_key]} %")
    return _verdict(failures, measured)


def judge_canary(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    """Reads [{"injected_sha", "culprit_sha", "alert_batches", "alert_to_culprit_hours", "verification"}]."""
    runs = _list(_json(ev.outputs[0]))
    failures = [] if len(runs) == t["runs"] else [f"{len(runs)} canary runs, need {t['runs']}"]
    passed = 0
    for run in runs:
        injected, culprit = _get(run, "injected_sha"), _get(run, "culprit_sha")
        batches, hours = _get(run, "alert_batches"), _get(run, "alert_to_culprit_hours")
        problems = []
        if batches is None or _number(run, "alert_batches") > t["max_alert_batches"]:
            problems.append(f"alert after {batches} T0 batches")
        if culprit != injected:
            problems.append(f"bisect found {culprit}")
        if hours is None or _number(run, "alert_to_culprit_hours") > t["max_bisect_hours"]:
            problems.append(f"culprit {hours} h after the alert")
        if str(_get(run, "verification")).lower() != str(t["verification"]).lower():
            problems.append(f"verification {run['verification']}")
        if problems:
            failures.append(f"canary {injected}: {', '.join(problems)}")
        else:
            passed += 1
    return _verdict(failures, {"passed": f"{passed}/{len(runs)}"})


def _load_module(prefix: str, path: Path) -> ModuleType:
    """Imports the file at `path` once per resolved path: another root or path is another module."""
    path = path.resolve()
    name = f"{prefix}_{hashlib.sha256(str(path).encode()).hexdigest()[:12]}"
    if name in sys.modules:
        return sys.modules[name]
    if not path.is_file():
        raise DoneCheckError(f"{path} does not exist")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException as error:
        del sys.modules[name]
        if isinstance(error, Exception):
            raise DoneCheckError(f"{path.name} does not import: {type(error).__name__}: {error}") from None
        raise
    return module


def judge_stats(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    """Runs perf_stats.py on the row's sample pairs (spec item 11's inputs) and compares with catapult's values."""
    failures = []
    if ev.outputs[0].returncode != 0:
        failures.append(f"`{ev.outputs[0].argv}` exited {ev.outputs[0].returncode}")
    stats = _load_module("perf_lab_done_checks_perf_stats", ev.root / "scripts/perf-lab/perf_stats.py")
    got = {}
    for name, (x, y) in t["samples"].items():
        got[f"mwu_{name}"], got[f"ks_{name}"] = stats.MannWhitneyU(x, y), stats.KolmogorovSmirnov(x, y)
    for key, value in got.items():
        if abs(value - t[key]) > t["tolerance"]:
            failures.append(f"{key} = {value:.4f}, catapult gives {t[key]}")
    mode, magnitude, n = t["high_threshold_args"]
    high = stats.HighThreshold(mode, magnitude, n)
    if high != t["high_threshold"]:
        failures.append(f"HighThreshold{t['high_threshold_args']} = {high}, catapult gives {t['high_threshold']}")
    return _verdict(failures, {**{k: round(v, 4) for k, v in got.items()}, "high_threshold": high})


def judge_sheriff(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    """Reads Sheriff.slo() of sheriff.py (task 019): {"groups", "triage": {"missed", "pct", "slo_hours"}, "culprit": {"median_hours"}, "stale": [{"group", "state", "age_hours"}]}."""
    report = _json(ev.outputs[0])
    triage, culprit = _get(report, "triage"), _get(report, "culprit")
    failures = []
    if _number(triage, "slo_hours") != t["triage_hours"]:
        failures.append(f"triage judged at {triage['slo_hours']} h, the spec says {t['triage_hours']} h")
    missed = _list(triage, "missed")
    triaged_pct = _get(triage, "pct")
    if missed or (triaged_pct is not None and _number(triage, "pct") < t["min_triaged_pct"]):
        failures.append(f"triaged in {t['triage_hours']} h: {triaged_pct} %, missed groups {missed}")
    median = _get(culprit, "median_hours")
    if median is not None and _number(culprit, "median_hours") > t["max_median_culprit_hours"]:
        failures.append(f"median alert->culprit {median} h, need <= {t['max_median_culprit_hours']} h")
    stale = [g for g in _list(report, "stale")
             if _get(g, "state") in t["stale_states"] and _number(g, "age_hours") > t["stale_hours"]]
    if len(stale) > t["max_stale_groups"]:
        failures.append(f"groups older than {t['stale_hours']} h in {'/'.join(t['stale_states'])}: "
                        f"{[g.get('group') for g in stale]}")
    return _verdict(failures, {"groups": _get(report, "groups"), "triaged_pct": triaged_pct,
                               "median_culprit_hours": median, "stale_groups": len(stale)})


def _feature_row(document: object, name: str) -> Mapping[str, object]:
    rows = _get(document, "features") if isinstance(document, Mapping) else document
    for row in _list(rows):
        if isinstance(row, Mapping) and row.get("name") == name:
            return row
    raise DoneCheckError(f"{name} is not in the feature listing")


def judge_kill_switch(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    """Reads off.json and on.json, each `cmux settings feature-flags --json` ({"features": [{"name", "state", "source"}]} or the bare list)."""
    directory = ev.kill_switch_evidence
    if directory is None:
        raise DoneCheckError("pass --kill-switch-evidence DIR: the bench-build run's off.json, on.json "
                             "(each the output of `cmux settings feature-flags --json`) and safe-mode.log")
    def read(name: str) -> str:
        path = directory / name
        if not path.is_file():
            raise DoneCheckError(f"{path} does not exist")
        return path.read_text(encoding="utf-8")
    def document(name: str) -> object:
        try:
            return json.loads(read(name))
        except json.JSONDecodeError as error:
            raise DoneCheckError(f"{name} is not JSON: {error}") from None
    off, on = _feature_row(document("off.json"), t["feature"]), _feature_row(document("on.json"), t["feature"])
    failures = []
    if (_get(off, "state"), _get(off, "source")) != (t["off_state"], t["off_source"]):
        failures.append(f"after the off document: {off['state']} source={off['source']}, "
                        f"need {t['off_state']} source={t['off_source']}")
    if _get(on, "state") != t["on_state"]:
        failures.append(f"after the on document: {on['state']}, need {t['on_state']}")
    log = read("safe-mode.log")
    suite = re.escape(str(t["safe_mode_suite"]))
    if re.search(rf"\b{suite}\b\W*\s+failed", log) or not re.search(rf"\b{suite}\b\W*\s+passed", log):
        failures.append(f"{t['safe_mode_suite']} did not pass in safe-mode.log")
    return _verdict(failures, {"off": f"{off['state']} source={off['source']}", "on": on["state"]})


def judge_features(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    _exited_zero(ev.outputs[0])
    unmigrated = ev.queries["MQ6"]
    failures = [f"unmigrated: {', '.join(unmigrated)}"] if len(unmigrated) > t["max_unmigrated"] else []
    return _verdict(failures, {"unmigrated": unmigrated})


def judge_corpus(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    """Reads [{"story", "replays", "digests_identical", "key_frame_p50_cv", "wpr_misses"}]; the CV is a fraction."""
    stories = _list(_json(ev.outputs[0]))
    failures = [] if len(stories) >= t["min_stories"] else [f"{len(stories)} stories, need >= {t['min_stories']}"]
    for story in stories:
        name, problems = _get(story, "story"), []
        if _number(story, "replays") < t["min_replays"]:
            problems.append(f"{story['replays']} replays")
        if _get(story, "digests_identical") is not True:
            problems.append("checkpoint digests differ")
        cv_pct = 100.0 * _number(story, "key_frame_p50_cv")
        if cv_pct > t["max_key_frame_p50_cv_pct"]:
            problems.append(f"key->frame p50 CV {cv_pct:.1f} %")
        if _number(story, "wpr_misses") > t["max_wpr_misses"]:
            problems.append(f"{story['wpr_misses']} WPR misses")
        if problems:
            failures.append(f"{name}: {', '.join(problems)}")
    return _verdict(failures, {"stories": len(stories)})


def judge_exit_zero(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    result = ev.outputs[0]
    ok = result.returncode == t["exit_code"]
    return ok, {"exit_code": result.returncode}, "" if ok else f"`{result.argv}` exited {result.returncode}: {_tail(result)}"


def judge_no_ci(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    _exited_zero(ev.outputs[0])
    stat = ev.outputs[0].stdout.strip()
    return (stat == t["stdout"]), {"stat": stat}, f"workflow files changed: {stat.splitlines()[-1]}" if stat else ""


def judge_reported(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    return True, {"report": _json(ev.outputs[0])}, ""


# --- the table ---------------------------------------------------------------------------------------------------

LAB = "python3 scripts/perf-lab/lab.py"
SHERIFF = "python3 scripts/perf-lab/sheriff.py"  # `lab.py sheriff`'s commands; sheriff.py declares no LAB_COMMANDS yet

CHECKS: tuple[Check, ...] = (
    Check(1, "coverage-t0", (Command(f"{LAB} coverage --tier T0 --since 24h --json"),),
          {"min_covered_pct": 90, "batch_minutes": 10, "window_minutes": 60}, judge_coverage_t0),
    Check(2, "coverage-t1", (Command(f"{LAB} coverage --tier T1 --json", spec=False),),
          {"max_age_hours": 3, "max_missing_families": 0}, judge_coverage_t1),
    Check(3, "targets-mapped", (Command(f"{LAB} targets --check"),
                                Command(f"{LAB} runs --since 24h --kind waterfall --json", spec=False)),
          {"targets": 12, "browser_engines": ("chromium", "webkit"), "min_results": 1}, judge_targets),
    Check(4, "release-grade", (Command(f"{LAB} runs --since 24h --config debug --tier T0,T1", run=False),),
          {"window_hours": 24, "config": "debug", "tiers": ("T0", "T1"), "max_debug_runs": 0,
           "parity_metric": "bench_parity.action_commit_delta_pct", "max_parity_delta_pct": 3},
          judge_release_grade),
    Check(5, "one-result-format", (Command(f"{LAB} stories --lint --format=paths"),),
          {"mq1_allowlist": ("scripts/cmux-next/perf-budgets.py", "scripts/cmux-next/perf-cron.py"),
           "max_mq1_outside_allowlist": 0, "mq4_result_writer": r"perf_result|BenchApp|\.record\(", "max_mq4": 0},
          judge_one_format, queries=("MQ1", ALLOWLIST_QUERY)),
    Check(6, "self-launch-removed", (), {"max_files": 0},
          _query_empty("MQ2", "max_files", "MQ2 benches that launch their own app"), queries=("MQ2",)),
    Check(7, "signposts-live", (), {"max_cases": 0},
          _query_empty("MQ5", "max_cases", "MQ5 SignpostName cases with no emitter"), queries=("MQ5",)),
    Check(8, "no-orphan-benches", (Command(f"{LAB} stories --orphans --json"),), {"max_orphans": 0}, judge_orphans),
    Check(9, "noise", (Command(f"{LAB} aa --since-live --json"),),
          {"min_aa_runs_per_waterfall_host": 3, "max_false_alerts_per_100_series_days": 1,
           "max_median_cv_pct": 5, "min_median_cv_series_pct": 90, "max_p99_cv_pct": 10, "min_p99_cv_series_pct": 80},
          judge_noise),
    Check(10, "pipeline-proof", (Command(f"{LAB} canary --last 3 --json"),),
          {"runs": 3, "max_alert_batches": 7, "max_bisect_hours": 3, "verification": "DIFFERENT"}, judge_canary),
    Check(11, "pinpoint-statistics", (Command("python3 -m unittest scripts/perf-lab/tests/test_perf_stats.py"),),
          {"samples": {"discrete": ([0] * 20, [0] * 15 + [1] * 5),
                       "spread": (list(range(10, 30)), list(range(10)) + list(range(30, 40)))},
           "mwu_discrete": 0.0195, "ks_discrete": 0.4973, "mwu_spread": 0.9892, "ks_spread": 0.0082,
           "tolerance": 0.0005, "high_threshold_args": ("performance", 1.0, 10), "high_threshold": 0.5708},
          judge_stats),
    Check(12, "sheriff-slo", (Command(f"{SHERIFF} --slo --since-live --json"),),
          {"min_triaged_pct": 100, "triage_hours": 1, "max_median_culprit_hours": 4, "stale_hours": 12,
           "stale_states": ("new", "triaged", "culprit"), "max_stale_groups": 0}, judge_sheriff),
    Check(13, "kill-switch", (Command("cmux settings feature-flags --json", run=False),),
          {"feature": "perfLabKillProbe", "off_state": "off", "off_source": "remote", "on_state": "on",
           "safe_mode_suite": "FeatureSafeModeTests"}, judge_kill_switch),
    Check(14, "features-complete", (Command("python3 scripts/cmux-next/gen-features.py --check"),),
          {"max_unmigrated": 0}, judge_features, queries=("MQ6",)),
    Check(15, "corpus", (Command("python3 scripts/perf-lab/corpus/play.py --verify --all --json", timeout_s=6 * 3600),),
          {"min_stories": 6, "min_replays": 2, "max_key_frame_p50_cv_pct": 5, "max_wpr_misses": 0}, judge_corpus),
    Check(16, "env-audit", (Command("python3 scripts/features/env_audit.py --check"),), {"exit_code": 0},
          judge_exit_zero),
    Check(17, "no-ci-added", (Command("git diff origin/feat-cmux-next... --stat -- .github/workflows"),),
          {"stdout": ""}, judge_no_ci),
    Check(18, "field", (Command(f"{LAB} field --since 7d --json"),), {}, judge_reported, reported_only=True),
    Check(18, "stability", (Command(f"{LAB} stability --since 7d --json"),), {}, judge_reported, reported_only=True),
)


# --- the runner --------------------------------------------------------------------------------------------------

Runner = Callable[[Sequence[str], Path, int], CommandResult]
Queries = Callable[[str, Path], list[str]]


def run_subprocess(argv: Sequence[str], cwd: Path, timeout_s: int) -> CommandResult:
    text = shlex.join(argv)
    command = [sys.executable, *argv[1:]] if argv[0] == "python3" else list(argv)
    try:
        done = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=timeout_s, check=False)
    except FileNotFoundError as error:
        raise DoneCheckError(f"`{text}`: {error}") from None
    except subprocess.TimeoutExpired:
        raise DoneCheckError(f"`{text}` ran over {timeout_s} s") from None
    return CommandResult(text, done.returncode, done.stdout, done.stderr)


@dataclass
class QueuesModule:
    """queues.py (task 200), imported once; `query(MQ, root)` returns the item keys of `queues.find(MQ).run(root)`,
    `query(ALLOWLIST_QUERY, root)` the repo paths of queues.ALLOWLIST."""
    path: Path = HERE / "queues.py"
    _module: ModuleType | None = field(default=None, repr=False)

    def __call__(self, name: str, root: Path) -> list[str]:
        if self._module is None:
            self._module = _load_module("perf_lab_queues", self.path)
        queues = self._module
        if name == ALLOWLIST_QUERY:
            return sorted(queues.ALLOWLIST)
        try:
            items = queues.find(name).run(str(root))
        except (queues.QueueError, OSError, ValueError) as error:
            raise DoneCheckError(f"queues.py {name}: {error}") from None
        return [item.key for item in items]


def catalog_targets(root: Path) -> list[TargetMap]:
    """The fixed targets of catalog.py (task 007), each with the stories that claim its rows' checks."""
    catalog = _load_module("perf_lab_catalog", root / "scripts/perf-lab/catalog.py")
    try:
        loaded = catalog.load_catalog(root)
    except (catalog.CatalogError, OSError) as error:
        raise DoneCheckError(f"catalog.py: {error}") from None
    claims = catalog.claimed_checks(loaded)
    return [TargetMap(target.id, target.browser, tuple(sorted({row.engine for row in target.rows if row.engine})),
                      mapped, tuple(sorted({story for row in target.rows for check in row.checks
                                            for story in claims.get((row.id, check.metric), ())})))
            for target, mapped in catalog.mapped_targets(loaded)]


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


@dataclass(frozen=True)
class LabStore:
    """labd's SQLite store (store.py's schema), opened read-only per query, as aa.py reads it."""
    path: Path | None
    clock: Callable[[], datetime] = _utc_now

    @classmethod
    def from_env(cls) -> "LabStore":
        value = os.environ.get(DB_ENV)
        return cls(Path(value) if value else None)

    def _since(self, hours: float) -> str:
        """store._stamp's fixed-width UTC form, so the bound compares with started_at as text."""
        return (self.clock() - timedelta(hours=hours)).astimezone(timezone.utc).isoformat(timespec="microseconds")

    def _rows(self, sql: str, params: Sequence[object]) -> list[sqlite3.Row]:
        if self.path is None:
            raise DoneCheckError(f"no lab store: set ${DB_ENV}")
        if not self.path.is_file():
            raise DoneCheckError(f"{self.path}: no lab store")
        try:
            db = sqlite3.connect(f"{self.path.resolve().as_uri()}?mode=ro", uri=True)
        except sqlite3.Error as error:
            raise DoneCheckError(f"{self.path}: {error}") from None
        db.row_factory = sqlite3.Row
        try:
            return db.execute(sql, params).fetchall()
        except sqlite3.Error as error:
            raise DoneCheckError(f"{self.path}: {error}") from None
        finally:
            db.close()

    def runs(self, *, since_hours: float, config: str, tiers: Sequence[str]) -> list[dict[str, object]]:
        marks = ", ".join("?" for _ in tiers)
        rows = self._rows(
            f"""SELECT u.run_uuid, u.kind, u.tier, u.story, b.sha, b.config, u.started_at
                FROM runs u JOIN builds b ON b.id = u.build_id
                WHERE u.started_at >= ? AND b.config = ? AND u.tier IN ({marks})
                ORDER BY u.started_at, u.id""", (self._since(since_hours), config, *tiers))
        return [dict(row) for row in rows]

    def newest_point(self, metric: str, *, since_hours: float) -> dict[str, object] | None:
        rows = self._rows(
            """SELECT u.run_uuid, u.story, b.sha, u.started_at, r.samples_json, r.summary_json
               FROM results r JOIN series s ON s.id = r.series_id JOIN runs u ON u.id = r.run_id
               JOIN builds b ON b.id = u.build_id
               WHERE s.metric = ? AND u.kind = 'waterfall' AND u.started_at >= ?
               ORDER BY u.started_at DESC, u.id DESC LIMIT 1""", (metric, self._since(since_hours)))
        if not rows:
            return None
        row = rows[0]
        summary = json.loads(row["summary_json"]) if row["summary_json"] is not None else {}
        samples = json.loads(row["samples_json"])
        p50 = summary.get("p50")
        if p50 is None:  # a point stored without a summary: perf_stats, the lab's one stats home, computes it
            p50 = _load_module("perf_lab_done_checks_perf_stats", HERE / "perf_stats.py").pct(samples, 0.50)
        return {"run_uuid": row["run_uuid"], "story": row["story"], "sha": row["sha"],
                "started_at": row["started_at"], "p50": p50}


@dataclass(frozen=True)
class Outcome:
    check: Check
    status: str
    measured: dict[str, object]
    reason: str

    def as_json(self) -> dict[str, object]:
        return {"check": self.check.number, "name": self.check.name, "status": self.status,
                "commands": [c.argv for c in self.check.commands] + [f"queues.{q}" for q in self.check.queries],
                "threshold": dict(self.check.threshold), "measured": self.measured, "reason": self.reason}

    def as_line(self) -> str:
        detail = self.reason or json.dumps(self.measured, sort_keys=True)
        return f"{self.status.upper():8} {self.check.number:>2} {self.check.name}: {detail}"


def _one_line(text: str) -> str:
    return " / ".join(line.strip() for line in text.splitlines() if line.strip())


def evaluate(check: Check, root: Path, *, runner: Runner = run_subprocess, queries: Queries | None = None,
             kill_switch_evidence: Path | None = None, targets: Targets = catalog_targets,
             store: RunStore | None = None) -> Outcome:
    """Judges one check. Any error (a missing input, or a bug in a module or judge it calls) is that check's reason:
    the runner still judges the checks after it."""
    queries = QueuesModule() if queries is None else queries
    store = LabStore.from_env() if store is None else store
    try:
        outputs = [runner(shlex.split(c.argv), root, c.timeout_s) for c in check.commands if c.run]
        found = {name: queries(name, root) for name in check.queries}
        evidence = Evidence(root, outputs, found, kill_switch_evidence, targets, store)
        ok, measured, reason = check.judge(evidence, check.threshold)
    except DoneCheckError as error:
        ok, measured, reason = False, {}, str(error)
    except Exception as error:  # one broken dependency must not hide the later checks' lines
        ok, measured, reason = False, {}, f"{type(error).__name__}: {error}"
    reason = _one_line(reason)
    if check.reported_only:
        return Outcome(check, REPORTED, measured, reason)
    return Outcome(check, PASS if ok else FAIL, measured, reason)


def run_checks(checks: Sequence[Check], root: Path, *, emit: Callable[[Outcome], None], runner: Runner = run_subprocess,
               queries: Queries | None = None, kill_switch_evidence: Path | None = None,
               targets: Targets = catalog_targets, store: RunStore | None = None) -> int:
    """Runs `checks` in table order, emits each outcome as it lands; 0 only when no judged check failed."""
    queries = QueuesModule() if queries is None else queries
    store = LabStore.from_env() if store is None else store
    failed = False
    for check in checks:
        outcome = evaluate(check, root, runner=runner, queries=queries, kill_switch_evidence=kill_switch_evidence,
                           targets=targets, store=store)
        failed |= outcome.status == FAIL
        emit(outcome)
    return 1 if failed else 0


def select(only: str | None) -> tuple[Check, ...]:
    if not only:
        return CHECKS
    try:
        wanted = {int(part) for part in only.split(",") if part.strip()}
    except ValueError:
        raise DoneCheckError(f"--only takes check numbers, got {only!r}") from None
    unknown = wanted - {check.number for check in CHECKS}
    if unknown:
        raise DoneCheckError(f"no check {sorted(unknown)}")
    return tuple(check for check in CHECKS if check.number in wanted)


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--json", action="store_true", help="print one JSON object per check")
    parser.add_argument("--only", metavar="N,N", help="run only these check numbers")
    parser.add_argument("--kill-switch-evidence", type=Path, metavar="DIR",
                        help="check 13's bench-build run: off.json, on.json and safe-mode.log")
    parser.add_argument("--repo", type=Path, default=ROOT, help=argparse.SUPPRESS)


def run(command: str, args: argparse.Namespace) -> int:
    try:
        checks = select(args.only)
    except DoneCheckError as error:
        print(f"done-checks: {error}", file=sys.stderr)
        return 2

    def emit(outcome: Outcome) -> None:
        print(json.dumps(outcome.as_json(), sort_keys=True) if args.json else outcome.as_line(), flush=True)

    return run_checks(checks, args.repo.resolve(), emit=emit, kill_switch_evidence=args.kill_switch_evidence)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="done_checks.py", description=LAB_COMMANDS["done-checks"])
    add_arguments("done-checks", parser)
    return run("done-checks", parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""The perf lab's done checks (p12-perf-process.md section 6) as one runner.

    python3 scripts/perf-lab/lab.py done-checks [--json] [--only 1,3,9] [--kill-switch-evidence DIR]

CHECKS is the one table: each row holds the check's commands (as section 6 writes them, plus --json where the
runner reads JSON), its thresholds in the spec's own units, and the judge that compares the two. The judges own
no numbers. Queries come from queues.py (task 200): `queues.<name>(root)` returns the hits as a list of strings.

It prints one line per check (a JSON object with --json) and exits 0 only when every judged check passes; field
and stability (check 18) are reported, never judged, because opt-in Nightly data in 72 h is small (3.10).
A check that cannot see its data fails with the reason; it never passes on missing output.

Chrome's analog is the perf waterfall's per-builder status: each step's command and expectation are data
(tools/perf/core/bot_platforms.py, tools/perf/expectations.config), and the runner only executes and judges them.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import shlex
import subprocess
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from types import ModuleType

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
LAB_COMMANDS = {"done-checks": "run every perf-lab done check (p12-perf-process.md section 6)"}

PASS, FAIL, REPORTED = "pass", "fail", "reported"


class DoneCheckError(Exception):
    """A check cannot read what it judges: a missing command, key, file or query."""


@dataclass(frozen=True)
class Command:
    """One command of a check. `run=False` names a command whose output the check reads from evidence files."""
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


@dataclass
class Evidence:
    root: Path
    outputs: list[CommandResult]
    queries: dict[str, list[str]]
    kill_switch_evidence: Path | None = None


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


def _json(result: CommandResult) -> object:
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        tail = (result.stderr or result.stdout).strip()[-300:]
        raise DoneCheckError(f"`{result.argv}` exited {result.returncode} without JSON: {tail}") from None


def _exited_zero(result: CommandResult) -> None:
    if result.returncode != 0:
        tail = (result.stderr or result.stdout).strip()[-300:]
        raise DoneCheckError(f"`{result.argv}` exited {result.returncode}: {tail}")


def _pct(part: int, whole: int) -> float:
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
    covered_pct = _pct(covered, planned)
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


def judge_targets(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    """Reads {"total", "mapped", "result_window_hours", "targets": [{"id", "browser", "engines", "stories": [{"id", "results"}]}]}."""
    result = ev.outputs[0]
    report = _json(result)
    total, mapped = int(_number(report, "total")), int(_number(report, "mapped"))
    failures = []
    if result.returncode != 0:
        failures.append(f"`targets --check` exited {result.returncode}")
    if total != t["targets"] or mapped != t["targets"]:
        failures.append(f"{mapped}/{total} targets mapped, need {t['targets']}/{t['targets']}")
    if _number(report, "result_window_hours") != t["result_window_hours"]:
        failures.append(f"results counted over {report['result_window_hours']} h, the spec says "
                        f"{t['result_window_hours']} h")
    engines = set(t["browser_engines"])
    stale = []
    for target in _list(report, "targets"):
        name = _get(target, "id")
        if _get(target, "browser") and not engines <= set(_list(target, "engines")):
            failures.append(f"{name} lacks an engine row ({', '.join(sorted(engines - set(target['engines'])))})")
        stale += [f"{name}:{_get(s, 'id')}" for s in _list(target, "stories")
                  if _number(s, "results") < t["min_results"]]
    if stale:
        failures.append(f"mapped stories with no result in {t['result_window_hours']} h: {', '.join(stale)}")
    return _verdict(failures, {"mapped": mapped, "total": total, "stories_without_results": stale})


def judge_release_grade(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    """Reads both outputs as [{"started", "results": [{"metric", "p50"}]}]; the newest parity point counts."""
    debug_rows = _list(_json(ev.outputs[0]))
    parity_rows = _list(_json(ev.outputs[1]))
    failures = []
    if len(debug_rows) > t["max_debug_runs"]:
        failures.append(f"{len(debug_rows)} debug-config T0/T1 runs in 24 h")
    values = [(str(_get(row, "started")), _number(result, "p50"))
              for row in parity_rows for result in _list(row, "results")
              if _get(result, "metric") == t["parity_metric"]]
    delta = max(values)[1] if values else None
    if delta is None:
        failures.append(f"no {t['parity_metric']} result in 24 h")
    elif abs(delta) > t["max_parity_delta_pct"]:
        failures.append(f"{t['parity_metric']} = {delta} %, need within {t['max_parity_delta_pct']} %")
    return _verdict(failures, {"debug_runs": len(debug_rows), t["parity_metric"]: delta})


def judge_one_format(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    allowed = set(t["mq1_allowlist"])
    private_stats = [hit for hit in ev.queries["mq1"] if Path(hit).name not in allowed]
    unwritten = ev.queries["mq4"]
    failures = []
    if len(private_stats) > t["max_mq1_outside_allowlist"]:
        failures.append(f"MQ1 outside the allowlist: {', '.join(private_stats)}")
    if len(unwritten) > t["max_mq4"]:
        failures.append(f"MQ4 stories without result-v1: {', '.join(unwritten)}")
    return _verdict(failures, {"mq1_outside_allowlist": private_stats, "mq4": unwritten})


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
    """Reads {"hosts": [{"name", "role", "aa_runs"}], "series_days", "false_alerts", "series": [{"kind", "cv_median", "cv_p99"}]}; CVs are fractions."""
    report = _json(ev.outputs[0])
    failures = []
    waterfall = [h for h in _list(report, "hosts") if _get(h, "role") == "waterfall"]
    if not waterfall:
        failures.append("no waterfall host in the A/A report")
    short = [f"{_get(h, 'name')}={int(_number(h, 'aa_runs'))}" for h in waterfall
             if _number(h, "aa_runs") < t["min_aa_runs_per_waterfall_host"]]
    if short:
        failures.append(f"hosts under {t['min_aa_runs_per_waterfall_host']} A/A runs: {', '.join(short)}")
    series_days, false_alerts = _number(report, "series_days"), _number(report, "false_alerts")
    rate = round(100.0 * false_alerts / series_days, 3) if series_days else None
    if rate is None:
        failures.append("0 monitored series-days")
    elif rate > t["max_false_alerts_per_100_series_days"]:
        failures.append(f"{rate} false alerts per 100 series-days")
    latency = [s for s in _list(report, "series") if _get(s, "kind") == "latency"]
    measured: dict[str, object] = {"false_alerts_per_100_series_days": rate, "latency_series": len(latency)}
    if not latency:
        failures.append("0 monitored latency series")
    else:
        for stat, max_key, min_key in (("cv_median", "max_median_cv_pct", "min_median_cv_series_pct"),
                                       ("cv_p99", "max_p99_cv_pct", "min_p99_cv_series_pct")):
            quiet = sum(1 for s in latency if 100.0 * _number(s, stat) <= t[max_key])
            share = _pct(quiet, len(latency))
            measured[f"{stat}_quiet_pct"] = share
            if share < t[min_key]:
                failures.append(f"{share} % of latency series have {stat} <= {t[max_key]} %, need >= {t[min_key]} %")
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


def _load_module(name: str, path: Path) -> ModuleType:
    if name in sys.modules:
        return sys.modules[name]
    if not path.is_file():
        raise DoneCheckError(f"{path} does not exist")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    try:
        spec.loader.exec_module(module)
    except (ImportError, SyntaxError) as error:
        del sys.modules[name]
        raise DoneCheckError(f"{path.name} does not import: {error}") from None
    except BaseException:
        del sys.modules[name]
        raise
    return module


def judge_stats(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    failures = []
    if ev.outputs[0].returncode != 0:
        failures.append(f"`{ev.outputs[0].argv}` exited {ev.outputs[0].returncode}")
    stats = _load_module("perf_lab_done_checks_perf_stats", ev.root / "scripts/perf-lab/perf_stats.py")
    discrete = ([0] * 20, [0] * 15 + [1] * 5)
    spread = (list(range(10, 30)), list(range(10)) + list(range(30, 40)))
    got = {
        "mwu_discrete": stats.MannWhitneyU(*discrete), "ks_discrete": stats.KolmogorovSmirnov(*discrete),
        "mwu_spread": stats.MannWhitneyU(*spread), "ks_spread": stats.KolmogorovSmirnov(*spread),
    }
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
    unmigrated = ev.queries["mq6"]
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
    return ok, {"exit_code": result.returncode}, "" if ok else (result.stderr or result.stdout).strip()[-300:]


def judge_no_ci(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    _exited_zero(ev.outputs[0])
    stat = ev.outputs[0].stdout.strip()
    return (stat == t["stdout"]), {"stat": stat}, f"workflow files changed: {stat}" if stat else ""


def judge_reported(ev: Evidence, t: Mapping[str, object]) -> Verdict:
    return True, {"report": _json(ev.outputs[0])}, ""


# --- the table ---------------------------------------------------------------------------------------------------

LAB = "python3 scripts/perf-lab/lab.py"

CHECKS: tuple[Check, ...] = (
    Check(1, "coverage-t0", (Command(f"{LAB} coverage --tier T0 --since 24h --json"),),
          {"min_covered_pct": 90, "batch_minutes": 10, "window_minutes": 60}, judge_coverage_t0),
    Check(2, "coverage-t1", (Command(f"{LAB} coverage --tier T1 --json", spec=False),),
          {"max_age_hours": 3, "max_missing_families": 0}, judge_coverage_t1),
    Check(3, "targets-mapped", (Command(f"{LAB} targets --check --json"),),
          {"targets": 12, "browser_engines": ("chromium", "webkit"), "result_window_hours": 24, "min_results": 1},
          judge_targets),
    Check(4, "release-grade", (Command(f"{LAB} runs --since 24h --config debug --tier T0,T1 --json"),
                               Command(f"{LAB} runs --since 24h --story bench-parity --json", spec=False)),
          {"max_debug_runs": 0, "parity_metric": "bench_parity.action_commit_delta_pct", "max_parity_delta_pct": 3},
          judge_release_grade),
    Check(5, "one-result-format", (), {"mq1_allowlist": ("perf-budgets.py", "perf-cron.py"),
                                       "max_mq1_outside_allowlist": 0, "max_mq4": 0},
          judge_one_format, queries=("mq1", "mq4")),
    Check(6, "self-launch-removed", (), {"max_files": 0},
          _query_empty("mq2", "max_files", "MQ2 benches that launch their own app"), queries=("mq2",)),
    Check(7, "signposts-live", (), {"max_cases": 0},
          _query_empty("mq5", "max_cases", "MQ5 SignpostName cases with no emitter"), queries=("mq5",)),
    Check(8, "no-orphan-benches", (Command(f"{LAB} stories --orphans --json"),), {"max_orphans": 0}, judge_orphans),
    Check(9, "noise", (Command(f"{LAB} aa --since-live --json"),),
          {"min_aa_runs_per_waterfall_host": 3, "max_false_alerts_per_100_series_days": 1,
           "max_median_cv_pct": 5, "min_median_cv_series_pct": 90, "max_p99_cv_pct": 10, "min_p99_cv_series_pct": 80},
          judge_noise),
    Check(10, "pipeline-proof", (Command(f"{LAB} canary --last 3 --json"),),
          {"runs": 3, "max_alert_batches": 7, "max_bisect_hours": 3, "verification": "DIFFERENT"}, judge_canary),
    Check(11, "pinpoint-statistics", (Command("python3 -m unittest scripts/perf-lab/tests/test_perf_stats.py"),),
          {"mwu_discrete": 0.0195, "ks_discrete": 0.4973, "mwu_spread": 0.9892, "ks_spread": 0.0082,
           "tolerance": 0.0005, "high_threshold_args": ("performance", 1.0, 10), "high_threshold": 0.5708},
          judge_stats),
    Check(12, "sheriff-slo", (Command(f"{LAB} sheriff --slo --since-live --json"),),
          {"min_triaged_pct": 100, "triage_hours": 1, "max_median_culprit_hours": 4, "stale_hours": 12,
           "stale_states": ("new", "triaged", "culprit"), "max_stale_groups": 0}, judge_sheriff),
    Check(13, "kill-switch", (Command("cmux settings feature-flags --json", run=False),),
          {"feature": "perfLabKillProbe", "off_state": "off", "off_source": "remote", "on_state": "on",
           "safe_mode_suite": "FeatureSafeModeTests"}, judge_kill_switch),
    Check(14, "features-complete", (Command("python3 scripts/cmux-next/gen-features.py --check"),),
          {"max_unmigrated": 0}, judge_features, queries=("mq6",)),
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
    """queues.py (task 200), imported once; `query(name, root)` returns `queues.<name>(root)` as strings."""
    path: Path = HERE / "queues.py"
    _module: ModuleType | None = field(default=None, repr=False)

    def __call__(self, name: str, root: Path) -> list[str]:
        if self._module is None:
            self._module = _load_module("perf_lab_queues", self.path)
        function = getattr(self._module, name, None)
        if not callable(function):
            raise DoneCheckError(f"queues.py has no {name}(root)")
        try:
            hits = function(root)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            raise DoneCheckError(f"queues.{name}(root): {error}") from None
        if isinstance(hits, (str, bytes)) or not all(isinstance(hit, str) for hit in hits):
            raise DoneCheckError(f"queues.{name}(root) must return strings")
        return list(hits)


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


def evaluate(check: Check, root: Path, *, runner: Runner = run_subprocess, queries: Queries | None = None,
             kill_switch_evidence: Path | None = None) -> Outcome:
    queries = QueuesModule() if queries is None else queries
    try:
        outputs = [runner(shlex.split(c.argv), root, c.timeout_s) for c in check.commands if c.run]
        found = {name: queries(name, root) for name in check.queries}
        ok, measured, reason = check.judge(Evidence(root, outputs, found, kill_switch_evidence), check.threshold)
    except DoneCheckError as error:
        ok, measured, reason = False, {}, str(error)
    if check.reported_only:
        return Outcome(check, REPORTED, measured, reason)
    return Outcome(check, PASS if ok else FAIL, measured, reason)


def run_checks(checks: Sequence[Check], root: Path, *, emit: Callable[[Outcome], None], runner: Runner = run_subprocess,
               queries: Queries | None = None, kill_switch_evidence: Path | None = None) -> int:
    """Runs `checks` in table order, emits each outcome as it lands; 0 only when no judged check failed."""
    queries = QueuesModule() if queries is None else queries
    failed = False
    for check in checks:
        outcome = evaluate(check, root, runner=runner, queries=queries, kill_switch_evidence=kill_switch_evidence)
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

#!/usr/bin/env python3
"""Compare five warm terminal relaunches with the previous passing feed build's measurements."""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
from statistics import median
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nightly_next_train as train

RUNS = 5
# Bump when the workload, input path, timing endpoints or units change.
PROFILE = "warm-terminal-in-app-v1"
FLOORS_MS = {"first_frame_ms": 150, "typing_echo_ms": 25}
FRACTION = 0.25


def elapsed(value):
    return type(value) in (float, int) and math.isfinite(value) and value >= 0


def samples(tti, outcome, smoke_failures=()):
    """Keep first frames on an input-only failure. A broken launch or seed measures neither metric."""
    readings = {metric: [] for metric in FLOORS_MS}
    if not isinstance(tti, dict):
        return readings, "missing launch harness report"
    seed = tti.get("seed")
    if not isinstance(seed, dict) or (seed.get("workspaces"), seed.get("chats")) != (3, 1):
        return readings, "expected the Home workspace plus the seeded terminal and chat workspaces"
    rounds = tti.get("rounds")
    if not isinstance(rounds, list) or len(rounds) != RUNS:
        return readings, f"harness did not complete {RUNS} relaunches"

    missed_input = []
    for index, row in enumerate(rounds, 1):
        if not isinstance(row, dict) or (row.get("kind"), row.get("front"), row.get("input")) != ("warm", "terminal", "in_app"):
            return readings, "unexpected launch round or input path"
        failures = row.get("failures")
        if not isinstance(failures, list) or any(
            not isinstance(f, str) or not f.startswith(("the app typed no key:", "the terminal took no key within "))
            for f in failures
        ):
            return readings, "harness reported a failed launch round"
        frame = row.get("first_frame_ms")
        if elapsed(frame):
            readings["first_frame_ms"].append(frame)
        if failures:
            missed_input.extend(f"round {index}: {failure}" for failure in failures)
            continue
        marks = row.get("marks")
        if isinstance(marks, dict):
            typed, accepted, echo = (marks.get(k) for k in ("terminal.probe_key_typed", "terminal_input_accepted", "terminal_echo"))
            if all(elapsed(v) for v in (typed, accepted, echo)) and typed <= accepted <= echo:
                readings["typing_echo_ms"].append(round(echo - typed, 3))
    if outcome != "success" or tti.get("verdict") != "pass":
        # The smoke can also fail after the rounds (e.g. a crash). Preserve the independent
        # frame readings only when the smoke confirms that *all* failures were missing input.
        if missed_input and smoke_failures == missed_input:
            return readings, "the terminal probe missed input in one or more rounds"
        return {}, f"launch harness verdict {tti.get('verdict')} (step {outcome})"
    return readings, None


def stats(values):
    if not isinstance(values, list) or len(values) != RUNS or not all(elapsed(v) for v in values):
        return None
    middle = median(values)
    return dict(median=middle, minimum=min(values), maximum=max(values),
                mad=median([abs(v - middle) for v in values]))


def matches_build(report, doc):
    """The producer job verified the artifact source. Its build workflow may have a different head."""
    return (isinstance(report, dict) and report.get("build") == doc["build"]
            and train.SHA_RE.fullmatch(str(report.get("source_commit", "")))
            and report.get("canaryRun") == doc.get("canaryRun") and bool(doc.get("canaryRun"))
            and report.get("canaryAttempt") == doc.get("canaryAttempt") and bool(doc.get("canaryAttempt")))


def judge(current, previous):
    """A failed metric warns on the release ring. An unavailable metric never reads as a pass."""
    base = (previous or {}).get("latency")
    reason = None
    if previous is None:
        reason = "no earlier passing build found"
    elif not matches_build(base, previous):
        reason = "previous passing build has no matching latency report"
    elif base.get("profile") != current["profile"]:
        reason = "measurement profile changed"
    elif base.get("machine") != current["machine"]:
        reason = "Mac model, chip or OS build changed"

    rows = {}
    for metric, floor in FLOORS_MS.items():
        now = stats(current["samples"].get(metric))
        baseline = {} if reason else base.get("samples")
        old = stats(baseline.get(metric)) if isinstance(baseline, dict) else None
        row = rows[metric] = dict(current=now, previous=old, verdict="unavailable")
        if not now:
            row["reason"] = current.get("measurement_error") or f"fewer than {RUNS} valid candidate readings"
        elif not old:
            row["reason"] = reason or f"fewer than {RUNS} valid baseline readings"
        else:
            delta = now["median"] - old["median"]
            limit = max(floor, FRACTION * old["median"], 3 * max(old["mad"], now["mad"]))
            row.update(delta_ms=round(delta, 3), threshold_ms=round(limit, 3),
                       verdict="fail" if delta > limit else "pass")
    verdicts = {r["verdict"] for r in rows.values()}
    return {**current, "baseline_build": (previous or {}).get("build"), "metrics": rows,
            "verdict": "fail" if "fail" in verdicts else "unavailable" if "unavailable" in verdicts else "pass"}


def report(args):
    from nightly_next_artifact_check import fetch_url  # same 404 handling as the static canary

    try:
        tti = json.loads(args.tti.read_text())
        smoke = json.loads(args.tti.with_name("report.json").read_text()) if args.harness_outcome == "failure" else {}
        readings, error = samples(tti, args.harness_outcome, smoke.get("failures") if isinstance(smoke, dict) else None)
    except (OSError, ValueError) as exc:
        readings, error = {}, f"launch harness report unreadable ({type(exc).__name__}, step {args.harness_outcome})"
    current = {"build": args.build, "source_commit": args.source_commit, "canaryRun": args.run_url,
               "canaryAttempt": args.attempt, "profile": PROFILE, "machine": args.machine, "samples": readings}
    if error:
        current["measurement_error"] = error
    candidates = sorted({b for b in args.earlier.split() if b.isdigit() and int(b) < int(args.build)}, key=int, reverse=True)
    try:
        previous = train.passing_verdict(candidates, fetch_url)
    except OSError as error:
        print(f"::warning::Could not read the previous passing canary verdict: {error}", file=sys.stderr)
        previous = None
    result = judge(current, previous)
    args.out.write_text(json.dumps(result, allow_nan=False) + "\n")
    lines = [f"### Felt latency · build {args.build} · {result['verdict']} (advisory)",
             f"Previous passing build: {result['baseline_build'] or 'unavailable'}. Machine: {args.machine}.",
             "", "| Metric | Candidate median (range), ms | Previous median (range), ms | Delta / threshold, ms | Verdict |",
             "| --- | --- | --- | --- | --- |"]
    for name, row in result["metrics"].items():
        cells = [f"{s['median']:g} ({s['minimum']:g}–{s['maximum']:g})" if s else "unavailable"
                 for s in (row["current"], row["previous"])]
        delta = f"{row['delta_ms']:g} / {row['threshold_ms']:g}" if "delta_ms" in row else "—"
        detail = row["verdict"] + (" · " + row["reason"] if "reason" in row else "")
        lines.append(f"| {name} | {' | '.join(cells)} | {delta} | {detail} |")
        if row["verdict"] != "pass":
            print(f"::warning title=nightly-next felt latency::{name}: {detail}, build {args.build} "
                  f"{cells[0]} vs {result['baseline_build']} {cells[1]} ms (delta / threshold {delta} ms)")
    print("\n".join(lines))
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as target:
            target.write("\n".join(lines) + "\n")


def attach(verdict_path, report_path):
    """Add advisory evidence only to the already authenticated build's verdict."""
    doc = json.loads(verdict_path.read_text())
    try:
        if report_path.stat().st_size > 8192:
            raise ValueError("oversized report")
        result = json.loads(report_path.read_text())
        if (not matches_build(result, doc) or result.get("profile") != PROFILE
                or result.get("verdict") not in ("pass", "fail", "unavailable")):
            raise ValueError("report does not describe this verified build")
    except (OSError, ValueError) as error:
        result = {"verdict": "unavailable", "reason": "no matching measurement report"}
        print(f"::warning title=nightly-next felt latency::{error}")
    doc["latency"] = result
    temp = verdict_path.with_suffix(".tmp")
    temp.write_text(json.dumps(doc, indent=2) + "\n")
    temp.replace(verdict_path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    writer = commands.add_parser("attach")
    writer.add_argument("--verdict", type=Path, required=True)
    writer.add_argument("--report", type=Path, required=True)
    measure = commands.add_parser("report")
    measure.add_argument("--build", required=True)
    measure.add_argument("--source-commit", required=True)
    measure.add_argument("--run-url", required=True)
    measure.add_argument("--attempt", type=int, required=True)
    measure.add_argument("--harness-outcome", required=True)
    measure.add_argument("--machine", required=True)
    measure.add_argument("--earlier", default="")
    measure.add_argument("--tti", type=Path, required=True)
    measure.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "attach":
        attach(args.verdict, args.report)
    else:
        report(args)


if __name__ == "__main__":
    main()

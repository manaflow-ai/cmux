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
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nightly_next_train as train

RUNS = 5
# Bump when the workload, input path, timing endpoints or units change.
PROFILE = "warm-terminal-in-app-v1"
FLOORS_MS = {"first_frame_ms": 150, "typing_echo_ms": 25}
FRACTION = 0.25


def elapsed(value):
    return type(value) in (float, int) and math.isfinite(value) and value >= 0


def samples(tti):
    rows = {metric: [] for metric in FLOORS_MS}
    for row in tti.get("rounds", []):
        if (row.get("kind"), row.get("front"), row.get("input")) != ("warm", "terminal", "in_app"):
            continue
        frame = row.get("first_frame_ms")
        if elapsed(frame):
            rows["first_frame_ms"].append(frame)
        marks = row.get("marks", {})
        typed, accepted, echo = (marks.get(k) for k in ("terminal.probe_key_typed", "terminal_input_accepted", "terminal_echo"))
        if all(elapsed(v) for v in (typed, accepted, echo)) and typed <= accepted <= echo:
            rows["typing_echo_ms"].append(round(echo - typed, 3))
    return rows


def stats(values):
    if not isinstance(values, list) or len(values) != RUNS or not all(elapsed(v) for v in values):
        return None
    middle = median(values)
    return dict(median=middle, minimum=min(values), maximum=max(values),
                mad=median([abs(v - middle) for v in values]))


def judge(current, previous):
    """Return a per-metric verdict. A failed latency verdict is advisory on the release ring."""
    base = (previous or {}).get("latency") or {}
    comparable = (base.get("profile") == current["profile"] and base.get("machine") == current["machine"]
                  and base.get("build") == previous["build"] and base.get("commit") == previous["commit"])
    rows = {}
    for metric, floor in FLOORS_MS.items():
        now = stats(current["samples"].get(metric))
        old = stats(base.get("samples", {}).get(metric)) if comparable else None
        row = rows[metric] = dict(current=now, previous=old, verdict="unavailable")
        if now and old:
            delta = now["median"] - old["median"]
            limit = max(floor, FRACTION * old["median"], 3 * max(old["mad"], now["mad"]))
            row.update(delta_ms=round(delta, 3), threshold_ms=round(limit, 3),
                       verdict="fail" if delta > limit else "pass")
    verdicts = {r["verdict"] for r in rows.values()}
    return {**current, "baseline_build": (previous or {}).get("build"), "metrics": rows,
            "verdict": "fail" if "fail" in verdicts else "unavailable" if "unavailable" in verdicts else "pass"}


def read_verdict(url):
    request = urllib.request.Request(url, headers={"Cache-Control": "no-cache", "User-Agent": "cmux-canary-latency/1"})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def report(args):
    current = {"build": args.build, "commit": args.commit, "profile": PROFILE, "machine": args.machine,
               "samples": samples(json.loads(args.tti.read_text())) if args.tti.is_file() else {}}
    candidates = sorted({b for b in args.earlier.split() if b.isdigit() and int(b) < int(args.build)}, key=int, reverse=True)
    try:
        previous = train.passing_verdict(candidates, read_verdict)
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
        lines.append(f"| {name} | {' | '.join(cells)} | {delta} | {row['verdict']} |")
        if row["verdict"] != "pass":
            print(f"::warning title=nightly-next felt latency::{name}: {row['verdict']}, build {args.build} "
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
        if (not isinstance(result, dict) or result.get("build") != doc["build"]
                or result.get("commit") != doc["commit"] or result.get("profile") != PROFILE
                or result.get("verdict") not in ("pass", "fail", "unavailable")):
            raise ValueError("report does not describe this verified build")
    except (OSError, ValueError) as error:
        result = {"verdict": "unavailable", "reason": "no matching measurement report"}
        print(f"::warning title=nightly-next felt latency::{error}")
    doc["latency"] = result
    verdict_path.write_text(json.dumps(doc, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    writer = commands.add_parser("attach")
    writer.add_argument("--verdict", type=Path, required=True)
    writer.add_argument("--report", type=Path, required=True)
    measure = commands.add_parser("report")
    measure.add_argument("--build", required=True)
    measure.add_argument("--commit", required=True)
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

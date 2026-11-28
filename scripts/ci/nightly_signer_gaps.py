#!/usr/bin/env python3
"""Signer idle gaps: when the nightly builder/signer sat free between builds.

    gh api 'repos/manaflow-ai/cmux/actions/workflows/nightly.yml/runs?per_page=100' > runs.json
    nightly_signer_gaps.py [--branch nightly-next] [--min-busy-minutes 15] [--min-gap-minutes 10] runs.json   (`-` for stdin)

Prints JSON: each gap between one signing build's end and the next one's start, plus totals. A run
counts as a signing build when it ran at least --min-busy-minutes (skips, cache warmups and refused
pushes end in a few minutes). Overlapping builds merge into one busy span. The gaps are where work
that needs the signer (a nightly-next rebuild, a notary probe) could be packed without queueing.
Run spans include queue and cache steps, so this is an upper bound on busy time until it reads the
signing job's own timestamps.
"""
import argparse
import json
import sys
from datetime import datetime


def _ts(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def busy_spans(runs, min_busy_minutes=15):
    spans = []
    for run in runs:
        start, end = run.get("run_started_at") or run.get("created_at"), run.get("updated_at")
        if not start or not end or run.get("status") != "completed":
            continue
        start, end = _ts(start), _ts(end)
        if (end - start).total_seconds() >= min_busy_minutes * 60:
            spans.append((start, end, run.get("head_branch")))
    spans.sort()
    merged = []
    for start, end, branch in spans:
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(end, merged[-1][1]), merged[-1][2])
        else:
            merged.append((start, end, branch))
    return merged


def gaps(runs, min_busy_minutes=15, min_gap_minutes=10):
    spans = busy_spans(runs, min_busy_minutes)
    out = []
    for (_, prev_end, prev_branch), (next_start, _, next_branch) in zip(spans, spans[1:]):
        minutes = (next_start - prev_end).total_seconds() / 60
        if minutes >= min_gap_minutes:
            out.append({"from": prev_end.isoformat(), "to": next_start.isoformat(), "minutes": round(minutes, 1),
                        "after": prev_branch, "before": next_branch})
    busy = sum((e - s).total_seconds() for s, e, _ in spans) / 60
    window = (spans[-1][1] - spans[0][0]).total_seconds() / 60 if spans else 0
    return {"builds": len(spans), "busy_minutes": round(busy, 1), "window_minutes": round(window, 1),
            "idle_minutes": round(sum(g["minutes"] for g in out), 1),
            "longest_gap_minutes": max((g["minutes"] for g in out), default=0), "gaps": out}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--min-busy-minutes", type=float, default=15)
    parser.add_argument("--min-gap-minutes", type=float, default=10)
    parser.add_argument("--branch", help="only runs of this branch (each track signs on its own runner)")
    parser.add_argument("runs")
    args = parser.parse_args(argv)
    data = json.load(sys.stdin if args.runs == "-" else open(args.runs))
    runs = data.get("workflow_runs", data) if isinstance(data, dict) else data
    if args.branch:
        runs = [run for run in runs if run.get("head_branch") == args.branch]
    print(json.dumps(gaps(runs, args.min_busy_minutes, args.min_gap_minutes), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

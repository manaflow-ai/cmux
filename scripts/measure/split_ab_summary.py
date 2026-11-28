#!/usr/bin/env python3
"""Summarize a split-ab.sh step: per arm the median of its rounds, then head - base (scripts/measure/split-ab.sh).

  split_ab_summary.py OUT ROUNDS

OUT holds <arm>-<round>/{rc,report.json} for arm base and head. A report's numbers are its split-scale `cells`
(cell -> transition -> {first_frame_ms, settled_ms, blank_frames, commit_ms, ...}) and its perf `rows`
([{name, p50, p95}]), each one metric "cell/transition/key" or "row/p50". Prints
  SPLIT-AB round <arm> <round> rc <N> metrics <count>
  SPLIT-AB median <arm> n <rounds measured> <metric> <value> ...   (one line per metric)
  SPLIT-AB delta <metric> base <v> head <v> delta <head - base>
writes OUT/summary.json, and exits 0 when every round measured, 3 when none did, 1 otherwise.
"""
import json
import os
import statistics
import sys

ARMS = ("base", "head")


def metrics(report):
    """{metric: number} from one split-spring report.json (split-scale cells and perf rows)."""
    found = {}
    cells = report.get("cells") if isinstance(report, dict) else None
    for cell, per in (cells or {}).items():
        for name, stats in (per or {}).items() if isinstance(per, dict) else ():
            for key, value in (stats or {}).items() if isinstance(stats, dict) else ():
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    found[f"{cell}/{name}/{key}"] = value
    rows = report.get("rows") if isinstance(report, dict) else None
    for row in rows if isinstance(rows, list) else ():
        if not isinstance(row, dict) or not row.get("name"):
            continue
        for key in ("p50", "p95"):
            value = row.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                found[f"{row['name']}/{key}"] = value
    return found


def read_round(out, arm, i):
    """(rc, metrics) of one arm's round; rc 3 when the round left no exit code."""
    folder = os.path.join(out, f"{arm}-{i}")
    try:
        rc = int(open(os.path.join(folder, "rc")).read().strip() or 3)
    except (OSError, ValueError):
        rc = 3
    try:
        found = metrics(json.load(open(os.path.join(folder, "report.json"))))
    except (OSError, ValueError):
        found = {}
    return rc, found


def summarize(out, rounds):
    """The summary dict and the step's exit code."""
    summary, codes = {}, []
    for arm in ARMS:
        per_round = []
        for i in range(1, rounds + 1):
            rc, found = read_round(out, arm, i)
            # A round counts when its bench ran and reported numbers; a gate verdict (exit 1) is not a failed round.
            codes.append(0 if found and rc in (0, 1) else (rc or 1))
            per_round.append({"round": i, "rc": rc, "metrics": found})
        names = sorted({k for r in per_round for k in r["metrics"]})
        median = {k: round(statistics.median([r["metrics"][k] for r in per_round if k in r["metrics"]]), 2)
                  for k in names}
        summary[arm] = {"rounds": per_round, "median": median,
                        "measured": sum(1 for r in per_round if r["metrics"])}
    shared = sorted(set(summary["base"]["median"]) & set(summary["head"]["median"]))
    summary["delta"] = {k: round(summary["head"]["median"][k] - summary["base"]["median"][k], 2) for k in shared}
    code = 0 if all(c == 0 for c in codes) else 3 if all(c == 3 for c in codes) else 1
    return summary, code


def main(argv):
    out, rounds = argv[1], int(argv[2])
    summary, code = summarize(out, rounds)
    for arm in ARMS:
        for r in summary[arm]["rounds"]:
            print("SPLIT-AB round", arm, r["round"], "rc", r["rc"], "metrics", len(r["metrics"]), flush=True)
        print("SPLIT-AB median", arm, "n", summary[arm]["measured"])
        for k, v in summary[arm]["median"].items():
            print("SPLIT-AB median", arm, k, v)
    for k, d in summary["delta"].items():
        print("SPLIT-AB delta", k, "base", summary["base"]["median"][k], "head", summary["head"]["median"][k], "delta", d)
    with open(os.path.join(out, "summary.json"), "w") as handle:
        json.dump(summary, handle, indent=1)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv))

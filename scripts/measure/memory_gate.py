#!/usr/bin/env python3
"""Per-change memory check: what an item costs before and after a change, from one harness on one runner.

Leo, 2026-11-22 (ask-5b56389121): "i also want us to keep pursuing the ability to have infinite f***ing tabs and
workspaces and s*** without getting starved of cpu/ram". The only memory check used to be the exclusive Mac bench
(scripts/measure/infinite-tabs.sh), whose queue waits about 17 h at p90, so a regression was found days late and by
hand. This reads the Linux harness's A/B output (scripts/measure/infinite-items-linux.sh before=ref:REF repeat=N:
`BEFORE rI PERF_ROW {...}` and `AFTER rI PERF_ROW {...}` lines, the daemons acpmux and cmux-tui with N hibernated
items) and says whether the change grew what an item costs, beyond the spread its own repeats show.

    memory_gate.py verdict LOG [--metric GLOB] [--tolerance 0.10] [--floor-mb 0.05] [--markdown]
        exit 0: no growth; 1: grew; 2: no data (a harness that failed to run: the caller fails open)

A metric grew when the median after is over every before sample AND the median moved by more than both
`tolerance` of the before median and `floor_mb` (MB per item). The rule needs no stored baseline: both sides
are built and run on the same runner in the same job, interleaved (before r1, after r1, before r2, ...).
memory_bisect.py runs the same probe across a landing range to name the first commit that grew it.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import re
import statistics
import sys

LINE = re.compile(r"^(BEFORE|AFTER) r(\d+) PERF_ROW (\{.*\})\s*$")
DEFAULT_METRICS = "infinite_items.n*.mb_per_item"


def parse(lines) -> dict[str, dict[str, list[float]]]:
    """{metric: {"before": [...], "after": [...]}} from the harness's A/B lines; other lines are ignored."""
    out: dict[str, dict[str, list[float]]] = {}
    for line in lines:
        m = LINE.match(line.rstrip("\n"))
        if not m:
            continue
        try:
            row = json.loads(m.group(3))
        except json.JSONDecodeError:
            continue
        name, value = row.get("name"), row.get("p50")
        if not isinstance(name, str) or not isinstance(value, (int, float)):
            continue
        out.setdefault(name, {"before": [], "after": []})[m.group(1).lower()].append(float(value))
    return out


def judge(before: list[float], after: list[float], tolerance: float, floor: float) -> dict:
    b, a = statistics.median(before), statistics.median(after)
    delta = a - b
    bound = max(tolerance * b, floor)
    grew = a > max(before) and delta > bound
    return {
        "before_median": round(b, 4), "after_median": round(a, 4), "delta": round(delta, 4),
        "before_spread": round(max(before) - min(before), 4), "after_spread": round(max(after) - min(after), 4),
        "bound": round(bound, 4), "n_before": len(before), "n_after": len(after), "grew": grew,
    }


def verdict(rows: dict, metric_glob: str, tolerance: float, floor: float) -> tuple[str, dict]:
    judged = {}
    for name in sorted(rows):
        if not fnmatch.fnmatch(name, metric_glob):
            continue
        sides = rows[name]
        if not sides["before"] or not sides["after"]:
            continue
        judged[name] = judge(sides["before"], sides["after"], tolerance, floor)
    if not judged:
        return "no-data", judged
    return ("grew" if any(j["grew"] for j in judged.values()) else "flat"), judged


def render(state: str, judged: dict, markdown: bool) -> str:
    if markdown:
        lines = ["| metric | before (median, spread) | after (median, spread) | change | bound | grew |",
                 "| --- | --- | --- | --- | --- | --- |"]
        for name, j in judged.items():
            lines.append(f"| {name} | {j['before_median']} ({j['before_spread']}, n={j['n_before']}) | "
                         f"{j['after_median']} ({j['after_spread']}, n={j['n_after']}) | {j['delta']:+} | "
                         f"{j['bound']} | {'yes' if j['grew'] else 'no'} |")
        lines.append("")
    else:
        lines = [f"MEMORY_GATE {name} {json.dumps(j)}" for name, j in judged.items()]
    lines.append(f"MEMORY_GATE verdict={state}")
    return "\n".join(lines)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("verdict", help="judge a harness A/B log")
    v.add_argument("log", help="the harness output, or - for stdin")
    v.add_argument("--metric", default=DEFAULT_METRICS, help=f"a glob over PERF_ROW names (default {DEFAULT_METRICS})")
    v.add_argument("--tolerance", type=float, default=0.10, help="share of the before median a change may move")
    v.add_argument("--floor-mb", type=float, default=0.05, help="smallest change that counts, in the metric's unit")
    v.add_argument("--markdown", action="store_true")
    args = p.parse_args(argv)
    fh = sys.stdin if args.log == "-" else open(args.log, encoding="utf-8", errors="replace")
    with fh:
        rows = parse(fh)
    state, judged = verdict(rows, args.metric, args.tolerance, args.floor_mb)
    print(render(state, judged, args.markdown))
    return {"flat": 0, "grew": 1}.get(state, 2)


if __name__ == "__main__":
    sys.exit(main())

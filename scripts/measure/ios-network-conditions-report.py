#!/usr/bin/env python3
"""The network-conditions report: NETCOND lines in, report.json and a markdown table out.

Input lines (ios-network-conditions.sh writes them): `LABEL {json}`, LABEL before or after, the
json one value: {"surface", "profile" (name@version), "phase", "scale", "metric", "value", "run",
"seed"}. A null value is a run that did not get there within the bench's bound: it counts as a
miss (shown as `n/miss`), never as a number.

report.json: {"after": SHA, "before": SHA|null, "rows": [{surface, profile, phase, scale, metric,
"after": {p50, p95, n, miss}, "before": {...}|null}]}. report.md: one table per surface.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import defaultdict

METRIC_ORDER = [
    "first_content_ms",
    "interactive_ms",
    "gap_after_link_back_ms",
    "gap_total_ms",
    "redial_after_drop_ms",
    "dial_from_link_back_ms",
    "dial_open_ms",
    "bytes_down",
    "bytes_up",
    "round_trips",
]
PHASE_ORDER = ["cold", "warm", "warm-full", "streaming", "reconnect", "path-change"]


def first_content_summary(rows: list[dict]) -> list[str]:
    """First content, p50 / p95 ms, profile x history scale x phase; then each phase's p95 at
    the largest scale over the smallest (history size must not move first content). With a
    before, the summary shows after; the change is in the detail tables below."""
    label = "after"
    cells: dict[tuple, dict] = {}
    for row in rows:
        if row["metric"] == "first_content_ms" and row[label] and row[label]["n"]:
            cells[(row["surface"], row["profile"], row["scale"], row["phase"])] = row[label]
    out: list[str] = []
    for surface in sorted({k[0] for k in cells}):
        phases = [p for p in PHASE_ORDER if any(k[0] == surface and k[3] == p for k in cells)]
        profiles = list(dict.fromkeys(k[1] for k in cells if k[0] == surface))
        scales = sorted({k[2] for k in cells if k[0] == surface}, key=scale_order)
        out.append(f"### {surface}: first content ms, p50 / p95 (n per cell in report.json)")
        out.append("")
        out.append("| profile | history | " + " | ".join(phases) + " |")
        out.append("|---|---|" + "---|" * len(phases))
        for profile in profiles:
            for scale in scales:
                vals = []
                for phase in phases:
                    c = cells.get((surface, profile, scale, phase))
                    vals.append(f"{c['p50']:,.0f} / {c['p95']:,.0f}" if c else "-")
                if any(v != "-" for v in vals):
                    out.append(f"| {profile} | {scale} | " + " | ".join(vals) + " |")
            history = [sc for sc in scales if scale_order(sc)[0] == 0]
            if len(history) >= 2:
                lo, hi = history[0], history[-1]
                ratio = []
                for phase in phases:
                    a, b = cells.get((surface, profile, lo, phase)), cells.get((surface, profile, hi, phase))
                    ratio.append(f"{b['p95'] / a['p95']:.2f}" if a and b and a["p95"] else "-")
                if any(r != "-" for r in ratio):
                    out.append(f"| {profile} | p95 {hi}/{lo} | " + " | ".join(ratio) + " |")
        out.append("")
    return out


def scale_order(scale: str) -> tuple:
    # history scales sort by size ("1x" < "10x"); a named scale such as "ios" sorts after them
    return (0, int(scale[:-1]), "") if re.fullmatch(r"\d+x", scale) else (1, 0, scale)


def percentile(values: list[float], q: float) -> float:
    ordered = sorted(values)
    # Nearest rank: a p95 of 5 runs is the slowest run, never an interpolation below it.
    rank = max(1, math.ceil(q * len(ordered)))
    return ordered[rank - 1]


def summarize(values: list[float | None]) -> dict:
    present = [v for v in values if v is not None]
    out = {"n": len(present), "miss": len(values) - len(present)}
    if present:
        out["p50"] = round(percentile(present, 0.5), 1)
        out["p95"] = round(percentile(present, 0.95), 1)
    return out


def fmt(summary: dict | None, metric: str) -> str:
    if not summary:
        return "-"
    if "p50" not in summary:
        return f"miss {summary['miss']}/{summary['miss']}"
    unit = "" if metric in ("round_trips",) else (" B" if metric.startswith("bytes") else " ms")
    p50, p95 = summary["p50"], summary["p95"]
    num = lambda v: f"{v:,.0f}" if abs(v) >= 10 else f"{v:g}"
    text = f"{num(p50)}{unit}" if p50 == p95 else f"{num(p50)} / {num(p95)}{unit}"
    if summary["miss"]:
        text += f" ({summary['miss']} miss)"
    return text


def change(before: dict | None, after: dict | None) -> str:
    if not before or not after or "p50" not in before or "p50" not in after or before["p50"] == 0:
        return ""
    return f"{(after['p50'] - before['p50']) / before['p50'] * 100:+.0f}%"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("lines")
    parser.add_argument("--json", required=True)
    parser.add_argument("--markdown", required=True)
    parser.add_argument("--before")
    parser.add_argument("--after", required=True)
    args = parser.parse_args()

    values: dict[tuple, dict[str, list]] = defaultdict(lambda: defaultdict(list))
    with open(args.lines) as handle:
        for line in handle:
            label, _, payload = line.strip().partition(" ")
            if not payload:
                continue
            try:
                row = json.loads(payload)
            except json.JSONDecodeError:
                print(f"ios-network-conditions-report: skipped a line that is not json: {line.strip()[:120]}", file=sys.stderr)
                continue
            key = (row["surface"], row["profile"], row["phase"], row["scale"], row["metric"])
            values[key][label].append(row["value"])

    def order(key: tuple):
        surface, profile, phase, scale, metric = key
        return (
            surface,
            profile,
            PHASE_ORDER.index(phase) if phase in PHASE_ORDER else 9,
            scale_order(scale),
            METRIC_ORDER.index(metric) if metric in METRIC_ORDER else 99,
        )

    rows = []
    for key in sorted(values, key=order):
        surface, profile, phase, scale, metric = key
        by_label = values[key]
        rows.append(
            {
                "surface": surface,
                "profile": profile,
                "phase": phase,
                "scale": scale,
                "metric": metric,
                "after": summarize(by_label["after"]) if "after" in by_label else None,
                "before": summarize(by_label["before"]) if "before" in by_label else None,
            }
        )
    with open(args.json, "w") as handle:
        json.dump({"after": args.after, "before": args.before, "rows": rows}, handle, indent=1)

    out = first_content_summary(rows)
    for surface in sorted({row["surface"] for row in rows}):
        out.append(f"### {surface} (p50 / p95; after {args.after[:12]}" + (f", before {args.before[:12]})" if args.before else ")"))
        out.append("")
        if args.before:
            out.append("| profile | phase | scale | metric | before | after | change |")
            out.append("|---|---|---|---|---|---|---|")
        else:
            out.append("| profile | phase | scale | metric | value |")
            out.append("|---|---|---|---|---|")
        for row in rows:
            if row["surface"] != surface:
                continue
            cells = [row["profile"], row["phase"], row["scale"], row["metric"]]
            if args.before:
                cells += [fmt(row["before"], row["metric"]), fmt(row["after"], row["metric"]), change(row["before"], row["after"])]
            else:
                cells += [fmt(row["after"], row["metric"])]
            out.append("| " + " | ".join(cells) + " |")
        out.append("")
    with open(args.markdown, "w") as handle:
        handle.write("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""The idle axes report (perf-10x-idle.sh axes=): what each idle item costs, per process.

Reads one bench_memory.py --axis report per axis (chat-hidden, chat-visible, terminal-hidden,
terminal-visible) and writes, for each axis and phase (`items`: 20 s after the items opened; `settled`:
after --settled-wait more, the hidden pages frozen and released), the marginal cost of one more item
(the least-squares slope over item counts, idle-launch counted as 0 items) and every sample's numbers by
process group: idle CPU %, footprint and RSS, wakeups/s, disk bytes written and read per hour, and the
GPU's own utilization (whole Mac, ioreg).

Usage: idle_axes_report.py --json OUT.json --markdown OUT.md AXIS.json [AXIS.json ...]
"""
from __future__ import annotations

import argparse
import json
import sys

METRICS = ("footprint_mb", "rss_mb", "cpu_pct", "wakeups_per_s", "disk_write_mb_per_h", "disk_read_mb_per_h")
GROUPS = ("app", "cef-renderer", "cef-gpu", "cef-other", "acpmux", "cmux-tui", "terminal-hosts", "webkit", "other")


def group_of(kind: str) -> str:
    """bench_memory.py's kind, as the report's process group."""
    if kind in ("app", "cef-renderer", "cef-gpu"):
        return kind
    if kind.startswith("cef-"):
        return "cef-other"
    if kind.startswith("acpmux"):
        return "acpmux"
    if kind.startswith("tui-") or kind.startswith("cmux-"):
        return "cmux-tui"
    if kind in ("terminal-host", "holder"):
        return "terminal-hosts"
    if kind.startswith("webkit-"):
        return "webkit"
    return "other"


def grouped(sample: dict) -> dict:
    """{group: {n, metric: value}} of one sample, plus `total`."""
    out: dict[str, dict] = {}
    for kind, entry in (sample.get("kinds") or {}).items():
        for name in (group_of(kind), "total"):
            row = out.setdefault(name, {"n": 0})
            row["n"] += entry.get("count", 0)
            for metric in METRICS:
                if entry.get(metric) is not None:
                    row[metric] = round(row.get(metric, 0.0) + entry[metric], 3)
    return out


def slope(points: list[tuple[float, float]]) -> float | None:
    """Least-squares slope of (x, y) points, or None with fewer than two distinct x."""
    if len({x for x, _ in points}) < 2:
        return None
    n = len(points)
    mx = sum(x for x, _ in points) / n
    my = sum(y for _, y in points) / n
    den = sum((x - mx) ** 2 for x, _ in points)
    return sum((x - mx) * (y - my) for x, y in points) / den


def phase_samples(report: dict, phase: str) -> list[dict]:
    """idle-launch (0 items) and the `phase-N` samples of one axis report."""
    out = []
    for s in report.get("samples", []):
        if s.get("label") == "idle-launch" or str(s.get("label", "")).startswith(phase + "-"):
            out.append(s)
    return out


def summarize(reports: list[dict]) -> dict:
    axes = []
    for report in reports:
        axis = report.get("axis") or "?"
        phases = {}
        for phase in ("items", "settled"):
            samples = phase_samples(report, phase)
            if len(samples) < 2:
                continue
            rows = [{"label": s["label"], "items": s.get("items", 0), "gpu": s.get("gpu"), "groups": grouped(s)}
                    for s in samples]
            marginal: dict[str, dict] = {}
            for name in GROUPS + ("total",):
                for metric in METRICS:
                    pts = [(r["items"], r["groups"].get(name, {}).get(metric, 0.0)) for r in rows
                           if r["groups"].get("total", {}).get(metric) is not None]
                    got = slope(pts)
                    if got is not None:
                        marginal.setdefault(name, {})[metric] = round(got, 4)
            phases[phase] = {"samples": rows, "marginal_per_item": marginal}
        axes.append({"axis": axis, "made": report.get("axis_made"), "phases": phases,
                     "pane_failures": report.get("pane_failures", [])[:5]})
    return {"axes": axes}


def fmt(value, digits: int = 2) -> str:
    return "-" if value is None else f"{value:.{digits}f}"


def markdown(summary: dict, machine: str = "") -> str:
    lines = ["# Idle cost per item (perf-10x-idle axes)", ""]
    if machine:
        lines += [machine, ""]
    lines += ["Marginal cost of one more item (slope over item counts; `items`: 20 s after they opened, "
              "`settled`: after the hidden pages' freeze and release timers).", "",
              "| axis | phase | footprint MB | RSS MB | CPU % | wakeups/s | disk W MB/h | disk R MB/h |",
              "|---|---|---:|---:|---:|---:|---:|---:|"]
    for axis in summary["axes"]:
        for phase, data in axis["phases"].items():
            t = data["marginal_per_item"].get("total", {})
            lines.append(f"| {axis['axis']} | {phase} | {fmt(t.get('footprint_mb'))} | {fmt(t.get('rss_mb'))} | "
                         f"{fmt(t.get('cpu_pct'), 3)} | {fmt(t.get('wakeups_per_s'))} | "
                         f"{fmt(t.get('disk_write_mb_per_h'))} | {fmt(t.get('disk_read_mb_per_h'))} |")
    lines += ["", "Marginal footprint MB and CPU % per item, by process group:", "",
              "| axis | phase | " + " | ".join(GROUPS) + " |", "|---|---|" + "---:|" * len(GROUPS)]
    for axis in summary["axes"]:
        for phase, data in axis["phases"].items():
            m = data["marginal_per_item"]
            cells = [f"{fmt(m.get(g, {}).get('footprint_mb'))} / {fmt(m.get(g, {}).get('cpu_pct'), 3)}" for g in GROUPS]
            lines.append(f"| {axis['axis']} | {phase} | " + " | ".join(cells) + " |")
    for axis in summary["axes"]:
        lines += ["", f"## {axis['axis']} (made: {json.dumps(axis.get('made'))})", "",
                  "| sample | items | process | n | footprint MB | RSS MB | CPU % | wakeups/s | disk W MB/h | disk R MB/h |",
                  "|---|---:|---|---:|---:|---:|---:|---:|---:|---:|"]
        seen = set()
        for phase, data in axis["phases"].items():
            for row in data["samples"]:
                if row["label"] in seen:
                    continue
                seen.add(row["label"])
                for name in GROUPS + ("total",):
                    g = row["groups"].get(name)
                    if not g:
                        continue
                    lines.append(f"| {row['label']} | {row['items']} | {name} | {g['n']} | {fmt(g.get('footprint_mb'), 1)} | "
                                 f"{fmt(g.get('rss_mb'), 1)} | {fmt(g.get('cpu_pct'), 3)} | {fmt(g.get('wakeups_per_s'))} | "
                                 f"{fmt(g.get('disk_write_mb_per_h'))} | {fmt(g.get('disk_read_mb_per_h'))} |")
                gpu = row.get("gpu") or {}
                if gpu and not gpu.get("error"):
                    lines.append(f"| {row['label']} | {row['items']} | GPU (whole Mac) | | "
                                 f"in use {fmt(gpu.get('in_use_system_memory_mb'), 1)} | | "
                                 f"device {fmt(gpu.get('device_utilization_pct'))} % | "
                                 f"renderer {fmt(gpu.get('renderer_utilization_pct'))} % | | |")
        if axis.get("pane_failures"):
            lines += ["", "Refused: " + "; ".join(axis["pane_failures"])]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", required=True)
    parser.add_argument("--markdown", required=True)
    parser.add_argument("--machine", default="", help="a line naming the machine and commit")
    parser.add_argument("reports", nargs="+")
    args = parser.parse_args(argv)
    reports = []
    for path in args.reports:
        try:
            with open(path) as handle:
                reports.append(json.load(handle))
        except (OSError, ValueError) as error:
            print(f"idle-axes: {path}: {error}", file=sys.stderr)
    summary = summarize(reports)
    with open(args.json, "w") as handle:
        json.dump(summary, handle, indent=2)
    text = markdown(summary, args.machine)
    with open(args.markdown, "w") as handle:
        handle.write(text)
    sys.stdout.write(text)
    return 0 if reports else 1


if __name__ == "__main__":
    sys.exit(main())

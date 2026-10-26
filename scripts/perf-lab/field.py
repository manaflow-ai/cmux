#!/usr/bin/env python3
"""Field metrics of opt-in Nightly hang reports, split by field-trial arm (p12-perf-process 3.10, task 152).

A Nightly study gives each install one arm of a perfPath feature (CmuxNextFeatures FieldTrial.swift):
the arm comes from the study name and the install's low entropy value 0..7999, as in Chrome's
variations (components/variations/entropy_provider.cc). The report carries the running arms as
`fieldTrials: ["study=arm", ...]` (FieldTrials.reportKey, task 151). This module reads the reports
and gives, per study, per arm and per (Nightly build, hardware class):

- reports and distinct installs
- hangs >= 250 ms per report, and the hang durations as p50/p95/p99/max (perf_stats.summary)
- the MetricKit hang-time histogram mass >= 250 ms, when the report has one
- for a study with exactly two arms, catapult's Mann-Whitney U p-value of the per-report hang counts

It never queries the database: task 042's `field.py` import (pscale --org cmux, branch main, a
read-only role) writes the reports this reads. Input is one JSON report per line, or one JSON array.

  python3 scripts/perf-lab/field.py arms --input reports.jsonl [--study NAME] [--json]
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
from collections import defaultdict
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field

HANG_THRESHOLD_MS = 250
REPORT_KEY = "fieldTrials"  # FieldTrials.reportKey
ALL_BUILDS = "*"


def _load_stats():
    name = "perf_lab_perf_stats"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf_stats.py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


perf_stats = _load_stats()


def arms_of(report: Mapping) -> dict[str, str]:
    """{study: arm} from the report's `fieldTrials` entries; malformed entries are skipped."""
    arms: dict[str, str] = {}
    entries = report.get(REPORT_KEY)
    if not isinstance(entries, list):
        return arms
    for entry in entries:
        if not isinstance(entry, str) or entry.count("=") != 1:
            continue
        study, arm = entry.split("=")
        if study and arm:
            arms[study] = arm
    return arms


def hardware_class(report: Mapping) -> str:
    """`chip/<n>gb`, the field side of store.host_class (reports have no display rate)."""
    hardware = report.get("hardware") if isinstance(report.get("hardware"), Mapping) else {}
    chip = str(hardware.get("chip") or "other").strip().lower().replace(" ", "-")
    memory = hardware.get("memoryGB")
    return f"{chip}/{int(memory)}gb" if isinstance(memory, (int, float)) else f"{chip}/?gb"


def build_of(report: Mapping) -> str:
    app = report.get("app") if isinstance(report.get("app"), Mapping) else {}
    return str(app.get("build") or "?")


def long_hangs_ms(report: Mapping) -> list[float]:
    """Durations of the report's hangs and stalls of at least HANG_THRESHOLD_MS."""
    hangs = report.get("hangs")
    if not isinstance(hangs, list):
        return []
    durations = []
    for hang in hangs:
        duration = hang.get("durationMs") if isinstance(hang, Mapping) else None
        if isinstance(duration, (int, float)) and duration >= HANG_THRESHOLD_MS:
            durations.append(float(duration))
    return durations


def metrickit_long_hang_count(report: Mapping) -> int | None:
    """The MetricKit hang-time histogram count in buckets at or above HANG_THRESHOLD_MS, or None."""
    metrics = report.get("metrics") if isinstance(report.get("metrics"), Mapping) else {}
    buckets = metrics.get("hangTime")
    if not isinstance(buckets, list) or not buckets:
        return None
    return sum(int(b.get("count", 0)) for b in buckets
               if isinstance(b, Mapping) and isinstance(b.get("lowMs"), (int, float)) and b["lowMs"] >= HANG_THRESHOLD_MS)


@dataclass
class ArmCell:
    """The reports of one arm in one (build, hardware class) cell."""
    reports: int = 0
    installs: set = field(default_factory=set)
    hang_counts: list = field(default_factory=list)
    hang_durations: list = field(default_factory=list)
    metrickit_long_hangs: int = 0
    metrickit_reports: int = 0

    def add(self, report: Mapping) -> None:
        durations = long_hangs_ms(report)
        self.reports += 1
        install = report.get("installId")
        if isinstance(install, str) and install:
            self.installs.add(install)
        self.hang_counts.append(len(durations))
        self.hang_durations.extend(durations)
        metrickit = metrickit_long_hang_count(report)
        if metrickit is not None:
            self.metrickit_reports += 1
            self.metrickit_long_hangs += metrickit

    def row(self) -> dict:
        return {
            "reports": self.reports,
            "installs": len(self.installs),
            "long_hangs_per_report": sum(self.hang_counts) / self.reports if self.reports else None,
            "long_hang_ms": perf_stats.summary(self.hang_durations),
            "metrickit_long_hangs_per_report": (self.metrickit_long_hangs / self.metrickit_reports
                                                if self.metrickit_reports else None),
        }


def split_by_arm(reports: Iterable[Mapping], study: str | None = None) -> dict:
    """{study: {"cells": [...], "arms": {arm: row}, "p_value": p or None}}.

    Each cell row is one (build, hardware class, arm); `arms` pools every build and class
    (build `*`). A report with no arm for a study does not count for it.
    """
    cells: dict = defaultdict(lambda: defaultdict(ArmCell))
    pooled: dict = defaultdict(lambda: defaultdict(ArmCell))
    for report in reports:
        if not isinstance(report, Mapping):
            continue
        for name, arm in arms_of(report).items():
            if study is not None and name != study:
                continue
            cells[name][(build_of(report), hardware_class(report), arm)].add(report)
            pooled[name][arm].add(report)
    result = {}
    for name in sorted(pooled):
        arms = pooled[name]
        p_value = None
        if len(arms) == 2:
            first, second = (arms[arm].hang_counts for arm in sorted(arms))
            p_value = perf_stats.MannWhitneyU(first, second)
        result[name] = {
            "cells": [{"build": build, "hardware": hardware, "arm": arm, **cell.row()}
                      for (build, hardware, arm), cell in sorted(cells[name].items())],
            "arms": {arm: {"build": ALL_BUILDS, **arms[arm].row()} for arm in sorted(arms)},
            "p_value": p_value,
        }
    return result


def read_reports(text: str) -> list:
    """One JSON array, or one JSON report per line (blank lines skipped)."""
    stripped = text.strip()
    if not stripped:
        return []
    if stripped.startswith("["):
        reports = json.loads(stripped)
        if not isinstance(reports, list):
            raise ValueError("the input array is not a list")
        return reports
    return [json.loads(line) for line in stripped.splitlines() if line.strip()]


def _fmt(value) -> str:
    if value is None:
        return "-"
    return f"{value:.3g}" if isinstance(value, float) else str(value)


def render(split: dict) -> str:
    lines = []
    for name, data in split.items():
        lines.append(f"study {name}" + (f"  (Mann-Whitney U p={data['p_value']:.3g})" if data["p_value"] is not None else ""))
        lines.append("  build      hardware              arm          reports installs hangs/report  p50   p95   max")
        for row in [*data["cells"], *({"hardware": "*", "arm": arm, **r} for arm, r in data["arms"].items())]:
            hangs = row["long_hang_ms"]
            lines.append(f"  {row['build']:<10} {row['hardware']:<21} {row['arm']:<12} {row['reports']:>7} {row['installs']:>8}"
                         f" {_fmt(row['long_hangs_per_report']):>12} {_fmt(hangs['p50']):>5} {_fmt(hangs['p95']):>5} {_fmt(hangs['max']):>5}")
    return "\n".join(lines) if lines else "no report carries a field-trial arm"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    commands = parser.add_subparsers(dest="command", required=True)
    arms = commands.add_parser("arms", help="split field metrics by field-trial arm")
    arms.add_argument("--input", required=True, help="hang reports: a JSON array or JSON lines ('-' for stdin)")
    arms.add_argument("--study", help="only this study")
    arms.add_argument("--json", action="store_true", help="print JSON instead of a table")
    args = parser.parse_args(argv)
    if args.input == "-":
        text = sys.stdin.read()
    else:
        with open(args.input, encoding="utf-8") as handle:
            text = handle.read()
    try:
        split = split_by_arm(read_reports(text), study=args.study)
    except ValueError as error:
        print(f"field.py: {error}", file=sys.stderr)
        return 2
    print(json.dumps(split, indent=2, sort_keys=True) if args.json else render(split))
    return 0


if __name__ == "__main__":
    sys.exit(main())

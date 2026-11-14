#!/usr/bin/env python3
"""The perf cron's memory-agents part (split-spring-terminal.py --suite=memory-agents): the app's idle memory, empty and
with idle agent chats open, as perf-cron rows (CMUX-571).

Leo, 2026-11-14: "all those perf things shouldve merged and been in a while ago... the other related goals should also
have been started and raised too". Goal ram-baseline checks the empty app's footprint, and goal memory-per-chat checks
what open chats cost against it. Until now the numbers came only from hand runs of scripts/measure/perf-10x-idle.sh
(its PERF-IDLE app-agents lines), which nothing stored.

This runs the same measurement perf-10x-idle.sh's agents step runs: scripts/cmux-next/bench_memory.py on the cron's
app, one idle chat per workspace on the acpmux test agent (its first turn answered). It writes report.json's `rows`
(perf-cron.py's budgets kind), each phys_footprint summed over every process of the app:
- memory.app_agents.empty.total_footprint_mb: the launch sample (bench_memory's idle-launch, no chat open);
- memory.app_agents.<N>.total_footprint_mb: N chats open and idle;
- memory.app_agents.ratio_vs_empty: the highest N's total / the empty total, both from this one run.
A count whose chats did not all open (fewer workspaces than asked, or a pane failure) gets no row and no ratio: a
partial sample is not that count's cost.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FAKE_AGENT = "cmux-tui/crates/acpmux/tests/fake_agent.py"
TOTAL_FLOOR_MB = 50.0  # the empty app's launch-to-launch spread was 849-941 MB (ram-baseline, 2026-11-08)


def rows_from(report: dict) -> list[dict]:
    """perf-cron rows from bench_memory.py's report (pure)."""
    samples = [s for s in report.get("samples") or [] if isinstance(s, dict)]
    empty = next((s for s in samples if s.get("label") == "idle-launch"), None)
    total = (empty or {}).get("total_footprint_mb")
    if not isinstance(total, (int, float)) or total <= 0:
        return []
    rows = [{"name": "memory.app_agents.empty.total_footprint_mb", "p50": total, "p95": total, "unit": "MB",
             "floor": TOTAL_FLOOR_MB}]
    full = []
    for s in samples:
        label = str(s.get("label") or "")
        if not label.startswith("idle-") or label == "idle-launch":
            continue
        try:
            asked = int(label.split("-", 1)[1])
        except ValueError:
            continue
        value = s.get("total_footprint_mb")
        if s.get("workspaces") != asked or s.get("pane_failures") or not isinstance(value, (int, float)):
            continue
        rows.append({"name": f"memory.app_agents.{asked}.total_footprint_mb", "p50": value, "p95": value, "unit": "MB",
                     "floor": TOTAL_FLOOR_MB})
        full.append((asked, value))
    if full:
        asked, value = max(full)
        ratio = round(value / total, 3)
        rows.append({"name": "memory.app_agents.ratio_vs_empty", "p50": ratio, "p95": ratio, "unit": "x", "floor": 0.1,
                     "agents": asked})
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--json", required=True, help="the part's report.json")
    parser.add_argument("--out", default=None, help="split-spring's artifact folder (bench_memory's own report goes there)")
    parser.add_argument("--agents", default="10", help="agent chat counts, e.g. 10 or 10,20")
    parser.add_argument("--settle", default="20")
    parser.add_argument("--measure", default="30")
    args, _rest = parser.parse_known_args(argv)  # split-spring's own args (--tag) are not this suite's
    out_dir = args.out or os.path.dirname(os.path.abspath(args.json))
    os.makedirs(out_dir, exist_ok=True)
    raw = os.path.join(out_dir, "memory-agents.json")
    cmd = [sys.executable, os.path.join(HERE, "bench_memory.py"), "--app", args.app, "--workspaces", args.agents,
           "--mix", "terminal+chat", "--fake-agent", os.path.join(ROOT, FAKE_AGENT), "--settle", args.settle,
           "--measure", args.measure, "--top", "8", "--out", raw]
    status = subprocess.run(cmd, cwd=ROOT).returncode
    try:
        with open(raw) as f:
            report = json.load(f)
    except (OSError, ValueError):
        report = {}
    rows = rows_from(report)
    out = {"rows": rows, "agents": args.agents, "bench_status": status}
    # perf-cron.py: an incomplete report keeps its rows for diagnostics but is no done part (incomplete_why names it).
    missing = [] if any(r["name"].endswith(".empty.total_footprint_mb") for r in rows) else \
        [f"no empty-app sample (bench_memory.py exit {status})"]
    for n in sorted({int(x) for x in args.agents.split(",") if x.strip().isdigit()}):
        if not any(r["name"] == f"memory.app_agents.{n}.total_footprint_mb" for r in rows):
            missing.append(f"agents {n}: not every chat opened (or no sample)")
    if missing:
        out["incomplete"] = missing
    with open(args.json, "w") as f:
        json.dump(out, f, indent=1)
    for r in rows:
        print(f"memory-agents: {r['name']} = {r['p95']} {r['unit']}")
    return status or (1 if missing else 0)


if __name__ == "__main__":
    raise SystemExit(main())

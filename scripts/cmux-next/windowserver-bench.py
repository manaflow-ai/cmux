#!/usr/bin/env python3
"""One GUI harness for WindowServer and device GPU cost across cmux NEXT scenarios.

Each scenario launches the same tagged app in a fresh process and uses the existing browser-idle or
typing-frame probe. Those probes sample IOAccelerator only inside each measured window. WindowServer CPU
comes from the probe's process-time delta. GPU rows are whole-device utilization;
macOS does not expose per-process GPU time, so the report never labels them as cmux-attributable.

The fleet entry point is scripts/measure/windowserver-cost.sh. The harness is intentionally report-only:
its output is accepted only when every requested scenario has a shaped report, but no value is a gate.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

# Keep the sibling sampler import working when this file is loaded by the bench
# tests via ``importlib`` instead of executed as a script.
_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

from windowserver_gpu import read_gpu_stats, summarize as summarize_gpu

SCENARIOS = ("idle", "typing", "spinner", "glass-blur", "many-panes")
SCHEMA = "cmux-windowserver/v1"


def scenario_command(scenario: str, app: str, out: Path, idle_s: float, tabs: int, samples: int) -> tuple[list[str], Path]:
    if scenario == "spinner":
        report_dir = out / scenario
        return [sys.executable, "scripts/cmux-next/browser-idle-cost-live.py", "--app", app,
                "--tabs", str(tabs), "--idle-s", str(idle_s), "--phases", "static,loading",
                "--no-sample", "--out", str(report_dir)], report_dir / f"browser-idle-cost-{tabs}.json"
    if scenario == "idle":
        report_dir = out / scenario
        return [sys.executable, "scripts/cmux-next/browser-idle-cost-live.py", "--app", app,
                "--tabs", str(tabs), "--idle-s", str(idle_s), "--phases", "static",
                "--no-sample", "--out", str(report_dir)], report_dir / f"browser-idle-cost-{tabs}.json"
    report = out / f"{scenario}.json"
    args = [sys.executable, "scripts/cmux-next/typing-frame-bench.py", "--app", app,
            "--tag", f"windowserver-{scenario}", "--out", str(out / scenario), "--json", str(report),
            "--rounds", "1", "--samples", str(samples), "--chat-agent", "mock"]
    if scenario == "typing":
        args += ["--surfaces", "agentpane", "--phases", "idle,load"]
    elif scenario == "glass-blur":
        # The typing harness's picture backdrop exercises the see-through glass/blur compositor path.
        args += ["--surfaces", "home", "--phases", "idle", "--backdrops", "opaque,picture"]
    else:  # many-panes
        args += ["--surfaces", "terminal", "--phases", "idle", "--sessions", "stress"]
    return args, report


def extract_runs(scenario: str, report: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if scenario in ("idle", "spinner"):
        for phase in report.get("phases", []):
            if not isinstance(phase, dict):
                continue
            phase_name = phase.get("phase")
            row = {"scenario": scenario, "phase": phase_name,
                   "surface": "tab-strip" if scenario == "spinner" and phase_name == "loading" else "browser-tabs",
                   "visibility": "background-loading-tab" if scenario == "spinner" and phase_name == "loading" else "shown",
                   "window_server_cpu_percent": phase.get("window_server_cpu_percent"),
                   "app_cpu_percent": (phase.get("classes", {}).get("app", {}) or {}).get("cpu_percent"),
                   "cef_gpu_cpu_percent": (phase.get("classes", {}).get("gpu", {}) or {}).get("cpu_percent"),
                   "gpu": phase.get("gpu")}
            rows.append(row)
        return rows
    for run in report.get("runs", []):
        if not isinstance(run, dict):
            continue
        cpu = run.get("cpu_pct") or run.get("cpu_percent") or {}
        rows.append({"scenario": scenario, "phase": run.get("phase"), "session": run.get("session"),
                     "surface": run.get("surface"), "backdrop": run.get("backdrop"),
                     "window_server_cpu_percent": cpu.get("window_server"),
                     "app_cpu_percent": cpu.get("app"), "gpu": run.get("gpu")})
    return rows


def run_scenario(scenario: str, app: str, root: Path, idle_s: float, tabs: int, samples: int) -> list[dict[str, Any]]:
    command, report_path = scenario_command(scenario, app, root, idle_s, tabs, samples)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    print("WINDOWSERVER-SCENARIO " + scenario, flush=True)
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    except OSError as error:
        raise RuntimeError(f"{scenario}: probe could not start: {error}") from error
    assert process.stdout is not None
    for line in process.stdout:
        print(f"{scenario}: {line}", end="", flush=True)
    code = process.wait()
    if code != 0:
        raise RuntimeError(f"{scenario}: probe exited {code}")
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RuntimeError(f"{scenario}: missing or invalid report {report_path}: {error}") from error
    if not isinstance(report, dict):
        raise RuntimeError(f"{scenario}: report is not an object")
    rows = extract_runs(scenario, report)
    if not rows:
        raise RuntimeError(f"{scenario}: report contained no measured rows")
    if any(row.get("window_server_cpu_percent") is None for row in rows):
        raise RuntimeError(f"{scenario}: report omitted WindowServer CPU for a measured phase")
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--scenarios", default=",".join(SCENARIOS))
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--idle-s", type=float, default=20.0)
    parser.add_argument("--tabs", type=int, default=5)
    parser.add_argument("--samples", type=int, default=40)
    opts = parser.parse_args()
    scenarios = [item.strip() for item in opts.scenarios.split(",") if item.strip()]
    if not scenarios:
        parser.error("at least one scenario is required")
    if opts.rounds < 1:
        parser.error("rounds must be at least 1")
    unknown = [item for item in scenarios if item not in SCENARIOS]
    if unknown:
        parser.error(f"unknown scenarios {unknown}; known: {','.join(SCENARIOS)}")
    root = Path(opts.out).resolve()
    root.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = []
    failures: list[dict[str, str]] = []
    for _round in range(opts.rounds):
        for scenario in scenarios:
            try:
                for row in run_scenario(scenario, opts.app, root / f"round-{_round + 1}", opts.idle_s, opts.tabs, opts.samples):
                    row["round"] = _round + 1
                    rows.append(row)
            except RuntimeError as error:
                failures.append({"scenario": scenario, "round": str(_round + 1), "error": str(error)})
                print(f"WINDOWSERVER-FAIL {error}", file=sys.stderr, flush=True)
    result = {"schema": SCHEMA, "app": os.path.abspath(opts.app), "host": os.uname().nodename,
              "scenarios": scenarios, "rounds": opts.rounds, "runs": rows, "failures": failures,
              "attribution": {"window_server_cpu": "process CPU delta from the WindowServer process",
                              "gpu": "whole-device IOAccelerator utilization; no per-process attribution is available",
                              "spinner": "background loading tab in the shown workspace; parked-strip workspace-switch coverage is excluded"}}
    Path(opts.json).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 1 if failures or not rows else 0


if __name__ == "__main__":
    raise SystemExit(main())

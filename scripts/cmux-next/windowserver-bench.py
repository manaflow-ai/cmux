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
import hashlib
import json
import math
import os
import plistlib
import subprocess
import sys
from pathlib import Path
from collections import Counter
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
                "--config", json.dumps({"appearance": {"statusIndicator": {"showPageLoading": True}}}),
                "--workspace-cycle", "--no-sample", "--out", str(report_dir)], report_dir / f"browser-idle-cost-{tabs}.json"
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
        args += ["--surfaces", "home", "--phases", "idle", "--backdrops",
                 "blur-none,blur-frosted,blur-glass,blur-glassClear"]
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
                   "visibility": "parked" if phase.get("workspace_state") == "parked" else
                                 "background-loading-tab" if scenario == "spinner" and phase_name == "loading" else "shown",
                   "workspace_state": phase.get("workspace_state", "shown"), "evidence": phase.get("evidence"),
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
                     "requested_appearance": run.get("requested_appearance"),
                     "backdrop_readback": run.get("backdrop_readback"), "effective_material": run.get("effective_material"),
                     "frame_timing": run.get("frame_timing"), "streams": run.get("streams"),
                     "window_server_cpu_percent": cpu.get("window_server"),
                     "app_cpu_percent": cpu.get("app"), "gpu": run.get("gpu")})
    return rows


def validate_report(scenario: str, report: dict[str, Any], samples: int) -> list[dict[str, Any]]:
    """A child can exit zero after catching a surface failure; require every requested cell exactly once."""
    for field in ("launch_failures", "surface_failures", "failures", "ab_problems", "error", "skipped"):
        if report.get(field):
            raise RuntimeError(f"{scenario}: probe reported {field}: {report[field]}")
    browser = scenario in ("idle", "spinner")
    raw = report.get("phases" if browser else "runs")
    if not isinstance(raw, list) or any(not isinstance(row, dict) for row in raw):
        raise RuntimeError(f"{scenario}: malformed measured rows")
    if browser:
        expected = ([("static", "shown")] if scenario == "idle" else
                    [(phase, state) for phase in ("static", "loading") for state in ("shown", "parked", "restored")])
        actual = [(row.get("phase"), row.get("workspace_state", "shown")) for row in raw]
    else:
        expected = {"typing": [("agentpane", phase, "light") for phase in ("idle", "load")],
                    "glass-blur": [("home", "idle", "light/blur-" + material)
                                   for material in ("none", "frosted", "glass", "glassClear")],
                    "many-panes": [("terminal", "idle", "stress")]}[scenario]
        actual = [(row.get("surface"), row.get("phase"), row.get("session")) for row in raw]
    if Counter(actual) != Counter(expected):
        raise RuntimeError(f"{scenario}: incomplete or unexpected coverage; expected {expected}, got {actual}")
    for row in raw:
        if (row.get("error") or row.get("skipped") or row.get("mode_missing") or
                row.get("complete") is False or row.get("status") in ("failed", "skipped")):
            raise RuntimeError(f"{scenario}: invalid or skipped measurement: {row}")
        if not browser:
            if row.get("keys") != samples or row.get("measured") != samples:
                raise RuntimeError(f"{scenario}: requested {samples} keys were not fully measured")
            if scenario == "typing":
                if row.get("complete") is not True or (row.get("clear") or {}).get("verified") is not True:
                    raise RuntimeError("typing: key integrity or composer reset was not verified")
                if row["phase"] == "load" and not any(
                        isinstance(count, (int, float)) and count > 0 for count in row.get("streams") or []):
                    raise RuntimeError("typing: requested background stream never ran")
                # frame_timing.valid concerns listener->frame comparisons only. Mock load is
                # intentional here; retain that caveat but do not treat it as missing CPU/GPU.
    rows = extract_runs(scenario, report)
    for row in rows:
        value = row.get("window_server_cpu_percent")
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            raise RuntimeError(f"{scenario}: invalid WindowServer CPU for a measured phase")
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
    return validate_report(scenario, report, samples)


def provenance(app: str, source_sha: str | None) -> dict[str, Any]:
    """Fingerprint the actual binary and probe files; caller-supplied source is explicitly a declaration."""
    def digest(path):
        value = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                value.update(block)
        return value.hexdigest()

    result = {"declared_app_source_sha": source_sha, "app": str(Path(app).resolve()),
              "harness_sha256": {name: digest(_SCRIPT_DIR / name) for name in (
                  "windowserver-bench.py", "browser-idle-cost-live.py", "typing-frame-bench.py",
                  "windowserver_gpu.py", "windowserver_metrics.py")}}
    try:
        info_path = Path(app) / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        executable = Path(app) / "Contents/MacOS" / info["CFBundleExecutable"]
        result.update(executable=str(executable.resolve()), executable_sha256=digest(executable),
                      info_plist_sha256=digest(info_path),
                      bundle_version=info.get("CFBundleVersion"), bundle_id=info.get("CFBundleIdentifier"))
    except (OSError, ValueError, KeyError) as error:
        result["binary_provenance_error"] = str(error)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--app-source-sha", help="source commit declared by the binary's build receipt")
    parser.add_argument("--out", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--scenarios", default=",".join(SCENARIOS))
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--idle-s", type=float, default=20.0)
    parser.add_argument("--tabs", type=int, default=5)
    parser.add_argument("--samples", type=int, default=40)
    parser.add_argument("--transport-envelope", action="store_true",
                        help="return success after writing a report, even when its validation verdict is failed")
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
    failed = bool(failures or not rows)
    result = {"verdict": "failed" if failed else "passed", "harness_exit_code": int(failed),
              "schema": SCHEMA, "app": os.path.abspath(opts.app), "host": os.uname().nodename,
              "provenance": provenance(opts.app, opts.app_source_sha),
              "scenarios": scenarios, "rounds": opts.rounds, "runs": rows, "failures": failures,
              "attribution": {"window_server_cpu": "process CPU delta from the WindowServer process",
                              "gpu": "whole-device IOAccelerator utilization; no per-process attribution is available",
                              "typing": "idle/load type the requested keys; load uses verified mock stream calls, not real ACP transport; frame-start timing caveats are retained",
                              "spinner": "static/loading shown→parked→restored workspace cycle; retained mounted controller and pending request verified, native strip animation unexposed",
                              "glass_blur": "requested none/frosted/glass/glassClear at opacity 0.85, native backdrop readback retained; effective material unexposed"}}
    Path(opts.json).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 0 if opts.transport_envelope else int(failed)


if __name__ == "__main__":
    raise SystemExit(main())

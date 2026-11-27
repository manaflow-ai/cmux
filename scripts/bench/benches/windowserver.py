"""WindowServer and whole-device GPU cost across the CMUX-887 scenario matrix.

The single fleet harness launches one optimized app per scenario and records process WindowServer CPU plus
IOAccelerator device/renderer/tiler utilization when macOS exposes it. GPU numbers are deliberately labelled
whole-device: macOS has no supported per-process GPU time counter, so they are not presented as cmux-only cost.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from benchlib.bench import Bench, BenchError, Context


HARNESS = "scripts/measure/windowserver-cost.sh"
ARTIFACT = "artifacts/windowserver-cost/report.json"
SCENARIOS = ("idle", "typing", "spinner", "glass-blur", "many-panes")


def number(value: Any) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    return None


class WindowServer(Bench):
    name = "windowserver"
    summary = "WindowServer CPU and whole-device IOAccelerator GPU cost across idle, typing, spinner, glass/blur and many panes"
    units = "% CPU, % GPU, MB"
    owner = "CMUX-887 investigate macOS WindowServer"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    nightly = False

    def run(self, ctx: Context) -> None:
        scenarios = ctx.arg("scenarios", ",".join(SCENARIOS))
        selected = [item for item in scenarios.split(",") if item]
        unknown = [item for item in selected if item not in SCENARIOS]
        if unknown:
            raise BenchError(f"windowserver: unknown scenarios {unknown}; known: {','.join(SCENARIOS)}")
        args = [f"--scenarios={','.join(selected)}"]
        for key in ("rounds", "idle_s", "tabs", "samples"):
            value = ctx.arg(key)
            if value not in (None, ""):
                args.append(f"--{key.replace('_', '-')}={value}")
        res = ctx.fleet_step(HARNESS, args=args, artifact=ARTIFACT, step_class="exclusive",
                             labels=("bench", "measure", "gui-session-v1"),
                             timeout=int(ctx.arg("timeout", "10800")), display=True,
                             ref=ctx.arg("ref") or ctx.build.get("sha"))
        path = res.artifact_path
        if path is None:
            raise BenchError(f"windowserver: fleet step {res.job_id or '?'} left no report artifact; log {res.log_path}")
        self.ingest(ctx, path)

    def ingest(self, ctx: Context, path: Path) -> None:
        try:
            report = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise BenchError(f"windowserver: cannot read {path}: {error}") from error
        if not isinstance(report, dict) or report.get("schema") != "cmux-windowserver/v1":
            raise BenchError(f"windowserver: {path} is not a cmux-windowserver/v1 report")
        if report.get("host"):
            ctx.host["name"] = str(report["host"])
            ctx.host["role"] = "fleet"
        for failure in report.get("failures") or []:
            if isinstance(failure, dict):
                ctx.notes.append(f"windowserver {failure.get('scenario', '?')} round {failure.get('round', '?')}: {failure.get('error', 'failed')}")
        measured = 0
        for run in report.get("runs") or []:
            if not isinstance(run, dict):
                continue
            scenario = run.get("scenario")
            if scenario not in SCENARIOS:
                ctx.notes.append(f"windowserver: ignored unknown scenario {scenario!r}")
                continue
            labels = {"scenario": scenario, "round": run.get("round", "")}
            for key in ("phase", "session", "surface", "backdrop", "visibility"):
                if run.get(key) not in (None, ""):
                    labels[key] = run[key]
            if labels.get("session") and "/" in str(labels["session"]):
                session, backdrop = str(labels["session"]).split("/", 1)
                labels["session"], labels["backdrop"] = session, backdrop
            for source, metric, unit in (
                ("window_server_cpu_percent", "window_server_cpu", "%"),
                ("app_cpu_percent", "app_cpu", "%"),
                ("cef_gpu_cpu_percent", "cef_gpu_cpu", "%"),
            ):
                value = number(run.get(source))
                if value is not None:
                    ctx.row(metric, value, unit, labels=labels)
                    measured += 1
            gpu = run.get("gpu")
            if not isinstance(gpu, dict) or not gpu.get("available"):
                ctx.notes.append(f"windowserver {scenario}: IOAccelerator GPU counters unavailable")
                continue
            for source, metric, unit in (
                ("device_utilization_percent", "gpu_device_utilization", "%"),
                ("renderer_utilization_percent", "gpu_renderer_utilization", "%"),
                ("tiler_utilization_percent", "gpu_tiler_utilization", "%"),
                ("in_use_system_memory_mb", "gpu_in_use_memory", "MB"),
                ("alloc_system_memory_mb", "gpu_alloc_memory", "MB"),
            ):
                value = number(gpu.get(source))
                if value is not None:
                    ctx.row(metric, value, unit, labels=labels)
                    measured += 1
        ctx.notes.append("GPU metrics are whole-device IOAccelerator counters; macOS does not expose per-process GPU time.")
        attribution = report.get("attribution")
        if isinstance(attribution, dict) and attribution.get("spinner"):
            ctx.notes.append(f"spinner coverage: {attribution['spinner']}")
        if report.get("verdict") == "failed" or report.get("failures") or report.get("harness_exit_code", 0):
            raise BenchError(f"windowserver: scenario validation failed; partial measurements retained in {path}")
        if not measured:
            raise BenchError(f"windowserver: {path} contained no measured rows")


BENCH = WindowServer()

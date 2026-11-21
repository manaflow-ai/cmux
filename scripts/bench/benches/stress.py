"""Adapter for the cmux NEXT multi-angle stress-bench report."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/split-spring.sh"
ARTIFACT = "artifacts/split-spring/report.json"


def _num(value: Any) -> float | None:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


class Stress(Bench):
    name = "stress"
    summary = "cmux NEXT multi-angle GUI stress bench with ramps and recovery"
    units = "fps, ms, count, %, MB, MB"
    owner = "cmux NEXT performance"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    nightly = True
    nightly_args = {"host": "fleet", "duration": "1"}
    thresholds = {"frame_rate_fps": 15.0, "input_to_paint_p95": 20.0, "cpu_pct": 25.0,
                  "rss_mb": 15.0, "disk_growth_mb": 20.0}

    def run(self, ctx: Context) -> None:
        args = ["--suite=stress-bench", f"--duration={ctx.arg('duration', '1')}"]
        if ctx.arg("scenarios"):
            args.append(f"--scenarios={ctx.arg('scenarios')}")
        result = ctx.fleet_step(HARNESS, args=args, artifact=ARTIFACT, step_class="exclusive",
                                labels=("measure", "gui-session-v1", "stress"),
                                timeout=int(ctx.arg("timeout", "10800")), display=True,
                                ref=ctx.arg("ref") or ctx.build.get("sha"))
        path = result.artifact_path
        if path is None:
            raise BenchError(f"stress: fleet step {result.job_id or '?'} left no report artifact; log {result.log_path}")
        self.ingest(ctx, path)

    def ingest(self, ctx: Context, path: Path) -> None:
        try:
            report = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise BenchError(f"stress: cannot read {path}: {error}") from error
        if not isinstance(report, dict) or not isinstance(report.get("scenarios"), list):
            raise BenchError(f"stress: {path} is not a stress-bench report (missing scenarios)")
        if report.get("host"):
            ctx.host["name"] = str(report["host"])
        found = 0
        for scenario in report["scenarios"]:
            if not isinstance(scenario, dict):
                continue
            name, ramp = str(scenario.get("scenario", "?")), str(scenario.get("ramp", "?"))
            labels = {"scenario": name, "ramp": ramp}
            metrics = scenario.get("metrics") or {}
            direct = (("frame_rate_fps", "fps"), ("cpu_pct", "%"), ("rss_mb", "MB"))
            for metric, unit in direct:
                value = _num(metrics.get(metric))
                if value is not None:
                    ctx.row(metric, value, unit, better="higher" if metric == "frame_rate_fps" else "lower", labels=labels)
                    found += 1
            latency = metrics.get("input_to_paint_ms") or {}
            for stat in ("p50", "p95", "p99"):
                value = _num(latency.get(stat))
                if value is not None:
                    ctx.row(f"input_to_paint_{stat}", value, "ms", labels=labels)
                    found += 1
            hangs = metrics.get("main_thread_hangs") or {}
            for metric, key, unit in (("hangs_count", "count", "count"), ("hang_max_ms", "max_ms", "ms")):
                value = _num(hangs.get(key))
                if value is not None:
                    ctx.row(metric, value, unit, labels=labels)
                    found += 1
            disk = _num(metrics.get("disk_growth_bytes"))
            if disk is not None:
                ctx.row("disk_growth_mb", disk / (1024 * 1024), "MB", labels=labels)
                found += 1
            recovery = metrics.get("recovery") or {}
            value = _num(recovery.get("fps"))
            if value is not None:
                ctx.row("recovery_fps", value, "fps", better="higher", labels=labels)
            if "recovered" in recovery:
                ctx.row("recovered", 1 if recovery["recovered"] else 0, "count", better="higher", labels=labels)
        for problem in report.get("top_problems") or []:
            ctx.notes.append("stress problem: " + json.dumps(problem, sort_keys=True))
        if not found:
            raise BenchError(f"stress: {path} contained no measured scenario rows")


BENCH = Stress()

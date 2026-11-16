"""Native composer typing under load, wrapping agent-engine-bench via split-spring.

The paint metric is the existing DOM keydown-to-after-frame proxy. Same-host epoch
timestamps also include native admission; this does not certify physical presentation.
p99 is a distinct metric, so the shared v1 ledger/compare can compare it without a
schema change. Failed/incomplete runs retain diagnostics but produce no timing rows.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context


class Typing(Bench):
    name = "typing"
    summary = "Native composer keydown-to-after-frame p95/p99 and key integrity under four load modes"
    units = "ms, count"
    owner = "typing-under-load (CMUX-571)"
    hosts = ("fleet",)
    harness = "scripts/measure/split-spring.sh"
    version = "1"

    def run(self, ctx: Context) -> None:
        ref = ctx.arg("ref") or ctx.build.get("sha")
        if not ref:
            raise BenchError("typing needs an exact source SHA (--build SHA or --arg ref=SHA)")
        result = ctx.fleet_step(self.harness, ["--config=bench", "--app-cache", "--vdisplay=120",
            "--suite=typing-load", "--modes=chromium", "--activate", f"--keys={ctx.arg('keys') or 500}",
            f"--key-gap-ms={ctx.arg('gap_ms') or 20}",
            f"--typing-loads={ctx.arg('loads') or 'idle,streaming-3,background-wake,cpu,100k'}"],
            "artifacts/split-spring/report.json", labels=("bench", "measure", "gui-session-v1"),
            ref=ref, timeout=int(ctx.arg("timeout") or 7200))
        if not result.artifact_path:
            raise BenchError(f"typing run {result.job_id} left no artifact; log {result.log_path}")
        self.ingest(ctx, result.artifact_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        doc = json.loads(path.read_text())
        if doc.get("host"):
            ctx.host["name"] = doc["host"]
        for engine, run in doc.get("modes", {}).items():
            for report in run.get("typing_loads", []):
                labels = {"engine": engine, "load": report["load"]}
                ctx.row("measurement_complete", int(report.get("complete") is True), "count",
                        better="higher", labels=labels)
                ctx.row("key_integrity", int(report.get("text_exact") is True and report.get("key_order_ok") is True),
                        "count", better="higher", labels=labels)
                # Keep lost keys and invalid cadence visible; never turn an empty/partial run into a fast one.
                if report.get("complete") is not True:
                    ctx.notes.append(f"{engine}/{report['load']}: incomplete; {report.get('error', 'see raw artifact')}")
                    continue
                if report.get("text_exact") is not True or report.get("key_order_ok") is not True:
                    raise BenchError("typing: complete run has no exact key/text integrity receipt")
                if report.get("app_active_before") is not True or report.get("app_active_after") is not True:
                    raise BenchError("typing: complete run has no foreground scheduling receipt")
                samples = report.get("typing", {}).get("samples", [])
                if len(samples) < 200 or len(samples) != report.get("expected_keys"):
                    raise BenchError("typing: complete run lacks the requested >=200 samples")
                for stage in ("listener", "work", "frame", "paint"):
                    xs = [s.get(stage) for s in samples]
                    if not all(type(x) in (int, float) and math.isfinite(x) and x >= 0 for x in xs):
                        raise BenchError(f"typing: invalid {stage} sample")
                    xs.sort()
                    ctx.row(f"keydown_to_{stage}", samples=xs, labels=labels)
                    for q in (95, 99):
                        value = xs[math.floor((len(xs) - 1) * q / 100 + .5)]
                        ctx.row(f"keydown_to_{stage}_p{q}_ms", value, n=len(xs), labels=labels)
                for key in ("driver_p95_late_ms", "driver_p99_rpc_ms"):
                    ctx.row(key, report.get(key), labels=labels)
                joined = report.get("dispatch_to_after_frame_ms", [])
                if len(joined) != len(samples) or not all(type(x) in (int, float) and math.isfinite(x) and x >= 0 for x in joined):
                    raise BenchError("typing: native dispatch/paint clock join is incomplete")
                ctx.row("dispatch_to_after_frame", samples=joined, labels=labels)
                joined = sorted(joined)
                for q in (95, 99):
                    value = joined[math.floor((len(joined) - 1) * q / 100 + .5)]
                    ctx.row(f"dispatch_to_after_frame_p{q}_ms", value,
                            n=len(joined), labels=labels)
        if not ctx.rows:
            raise BenchError("typing: artifact contains no load measurements")


BENCH = Typing()

"""typing-native: native typing under load; ingests the typing-frame report into cmux-bench.

The web composer bench is `typing` (benches/typing.py); this one reads the native Mac harness, which
measures what the browser clock cannot (native key admission, physical frames, L4/L5, daemon wakeups).

The GUI harness remains ``scripts/cmux-next/typing-frame-bench.py`` and is run by
``scripts/measure/split-spring.sh --suite=typing-frame``.  This adapter keeps the
report's provenance in labels and only records latency rows when the harness
proved the sample complete (foreground, exact key order/text, and joined frame
clock).  A failed or incomplete run is therefore visible as a note, never as a
misleading fast value.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from benchlib.bench import Bench, BenchError, Context


HARNESS = "scripts/cmux-next/typing-frame-bench.py"
FLEET_SCRIPT = "scripts/measure/split-spring.sh"
ARTIFACT = "artifacts/split-spring/report.json"


def _number(value: Any) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    return None


def _labels(run: dict[str, Any]) -> dict[str, str]:
    labels: dict[str, str] = {}
    for key in ("session", "surface", "phase", "mode", "engine"):
        value = run.get(key)
        if value not in (None, ""):
            labels[key] = str(value)
    missing = run.get("mode_missing") or []
    if missing:
        labels["native_missing"] = ";".join(str(item) for item in missing)
    capabilities = run.get("capabilities") or {}
    for key in ("load_source", "daemon_wake"):
        value = capabilities.get(key)
        if value not in (None, ""):
            labels[key] = str(value)
    return labels


class TypingNative(Bench):
    name = "typing-native"
    summary = "Native key-to-frame typing latency under the shared L0-L5 load modes"
    units = "ms, count"
    owner = "chat-instant typing-under-load, native (PR #44479)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    thresholds = {
        "key_to_frame_p95": 15.0,
        "key_to_frame_p99": 25.0,
        "dispatch_to_after_frame_p95": 15.0,
        "dispatch_to_after_frame_p99": 25.0,
    }

    def run(self, ctx: Context) -> None:
        args = ["--suite=typing-frame"]
        for key, default in (
            ("modes", "all"),
            ("surfaces", "agentpane"),
            ("chat_agent", "real"),
            ("rounds", "1"),
            ("samples", "200"),
            ("vdisplay", "120"),
            ("vdisplay_size", "1920x1200"),
        ):
            value = ctx.arg(key, default)
            if value not in (None, ""):
                args.append(f"--{key.replace('_', '-')}={value}")
        for key in ("interval", "busy", "chats", "cpu_burners", "stream", "sample", "gate_p95_ms", "stress"):
            value = ctx.arg(key)
            if value not in (None, "", "0", "false", "False"):
                args.append(f"--{key.replace('_', '-')}={value}" if key not in ("sample", "stress")
                            else "--" + key.replace("_", "-"))
        res = ctx.fleet_step(
            FLEET_SCRIPT,
            args=args,
            artifact=ARTIFACT,
            step_class="exclusive",
            labels=("measure", "gui-session-v1"),
            timeout=int(ctx.arg("timeout", "7200")),
            ref=ctx.arg("ref") or ctx.build.get("sha"),
            display=True,
        )
        path = res.artifact_path
        if path is None:
            raise BenchError(f"typing-native: fleet step {res.job_id or '?'} left no report artifact; log {res.log_path}")
        self.ingest(ctx, path)

    def ingest(self, ctx: Context, path: Path) -> None:
        try:
            report = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise BenchError(f"typing-native: cannot read {path}: {error}") from error
        if not isinstance(report, dict) or not isinstance(report.get("runs"), list):
            raise BenchError(f"typing-native: {path} is not a typing-frame report (missing runs)")
        if report.get("macos"):
            ctx.host["os"] = f"macOS {report['macos']}"
        if report.get("host"):
            ctx.host["name"] = str(report["host"])
            ctx.host["role"] = "fleet"
        found = 0
        for run in report["runs"]:
            if not isinstance(run, dict):
                continue
            labels = _labels(run)
            complete = run.get("complete") is True
            if not complete:
                ctx.notes.append(
                    "typing-native: unmeasured incomplete run "
                    f"{labels.get('surface', '?')}.{labels.get('mode', labels.get('phase', '?'))} "
                    f"text_exact={run.get('text_exact')} key_order_ok={run.get('key_order_ok')} "
                    f"active={(run.get('focus') or {}).get('app_active')}"
                )
                continue
            found += 1
            for source, metric in (
                ("key_to_frame_ms", "key_to_frame"),
                ("dispatch_to_after_frame_ms", "dispatch_to_after_frame"),
            ):
                distribution = run.get(source)
                if not isinstance(distribution, dict):
                    continue
                for stat in ("p50", "p95", "p99", "max"):
                    value = _number(distribution.get(stat))
                    if value is None:
                        continue
                    ctx.row(f"{metric}_{stat}", value, "ms", labels=labels)
            frame_metrics = run.get("frame_metrics") or {}
            for metric, value, unit in (
                ("frames_over_16ms", frame_metrics.get("frames_over_16ms"), "count"),
                ("main_thread_cost_total", (frame_metrics.get("main_thread_cost") or {}).get("total_ms"), "ms"),
            ):
                value = _number(value)
                if value is not None:
                    ctx.row(metric, value, unit, labels=labels)
        if not found:
            raise BenchError(f"typing-native: {path} contained no complete measured runs")


BENCH = TypingNative()

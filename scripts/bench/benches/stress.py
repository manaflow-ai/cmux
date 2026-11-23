"""stress: the app under extreme stress from several angles, each a baseline window and a stress window.

Leo, 2026-11-21: "i think being able to test our app under extreme stress from various angles would be a good bench
to be able to run through".

Angles (``--arg angles=cpu,chats,scale,cli,memory``, default all):

  cpu     CPU and thread starvation: processes x threads hashing beside the app
  chats   many mock agent chats streaming at once, two with very long transcripts (no model calls)
  scale   many workspaces and terminals, with output floods
  cli     the CLI/socket API flood (scripts/stress-cli-socket-api.py) plus socket client threads
  memory  incompressible dirty pages past RAM, until the machine swaps

The GUI harness is ``scripts/cmux-next/stress-bench.py``, run on an exclusive bench worker by the allowlisted
``scripts/measure/split-spring.sh --suite=stress``. Rows carry labels {angle, arm}: arm is ``baseline`` (the quiet
app, same launch) or ``stress``. ``cmux-bench compare stress@sha:A stress@sha:B`` is the before/after of a change.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from benchlib.bench import Bench, BenchError, Context


HARNESS = "scripts/cmux-next/stress-bench.py"
FLEET_SCRIPT = "scripts/measure/split-spring.sh"
ARTIFACT = "artifacts/split-spring/report.json"
ANGLES = ("cpu", "chats", "scale", "cli", "memory")
ARMS = ("baseline", "stress")

# (report key, metric, unit, better)
METRICS = (
    ("frame_p50_ms", "frame_p50", "ms", "lower"),
    ("frame_p95_ms", "frame_p95", "ms", "lower"),
    ("dropped_frames_pct", "dropped_frames", "%", "lower"),
    ("input_p50_ms", "input_latency_p50", "ms", "lower"),
    ("input_p95_ms", "input_latency_p95", "ms", "lower"),
    ("daemon_rtt_p50_ms", "daemon_rtt_p50", "ms", "lower"),
    ("daemon_rtt_p95_ms", "daemon_rtt_p95", "ms", "lower"),
    ("app_cpu_pct", "app_cpu", "%", "lower"),
    ("footprint_mb", "footprint", "MB", "lower"),
    ("hangs", "hangs", "count", "lower"),
)
# Conditions of the window, not results of the app: recorded so a compare shows the stress was really applied.
CONDITIONS = (
    ("load_avg_1m", "load_avg_1m", "x", "none"),
    ("swap_used_mb", "swap_used", "MB", "none"),
)
# Forwarded as --key=value to the harness when given with --arg.
KNOBS = ("window", "key_interval", "hang_ms", "cpu_procs", "cpu_threads", "chats", "transcript_rows", "long_chats",
         "long_rows", "workspaces", "panes", "flood_terminals", "cli_clients", "cli_burst_workers", "memory_fraction",
         "memory_cap_mb")


def _number(value: Any) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    return None


class Stress(Bench):
    name = "stress"
    summary = "The app under extreme stress (cpu, chats, scale, cli, memory): frames, input, daemon RTT, CPU, memory, hangs"
    units = "ms, %, MB, count"
    owner = "perf: stress from several angles (Leo, 2026-11-21)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"

    def run(self, ctx: Context) -> None:
        angles = ctx.arg("angles", ",".join(ANGLES))
        unknown = [a for a in angles.split(",") if a and a not in ANGLES]
        if unknown:
            raise BenchError(f"stress: unknown angles {unknown}; known: {','.join(ANGLES)}")
        args = ["--suite=stress", f"--angles={angles}"]
        for key in KNOBS:
            value = ctx.arg(key)
            if value not in (None, ""):
                args.append(f"--{key.replace('_', '-')}={value}")
        vdisplay = ctx.arg("vdisplay", "120")
        if vdisplay not in (None, "", "0"):
            args.append(f"--vdisplay={vdisplay}")
        if ctx.arg("config"):
            args.append(f"--config={ctx.arg('config')}")
        labels = tuple(x for x in ctx.arg("labels", "bench").split(",") if x)
        res = ctx.fleet_step(
            FLEET_SCRIPT,
            args=args,
            artifact=ARTIFACT,
            step_class="exclusive",
            labels=labels,
            timeout=int(ctx.arg("timeout", "7200")),
            ref=ctx.arg("ref") or ctx.build.get("sha"),
            display=True,
        )
        path = res.artifact_path
        if path is None:
            raise BenchError(f"stress: fleet step {res.job_id or '?'} left no report artifact; log {res.log_path}")
        self.ingest(ctx, path)

    def ingest(self, ctx: Context, path: Path) -> None:
        try:
            report = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise BenchError(f"stress: cannot read {path}: {error}") from error
        stress = report.get("stress") if isinstance(report, dict) else None
        if not isinstance(stress, dict) or not isinstance(stress.get("angles"), dict):
            raise BenchError(f"stress: {path} is not a stress report (missing stress.angles)")
        macos = report.get("macos") or stress.get("macos")
        if macos:
            ctx.host["os"] = f"macOS {macos}"
        if stress.get("host"):
            ctx.host["name"] = str(stress["host"])
            ctx.host["role"] = "fleet"
        display = report.get("display") or {}
        refresh = _number(display.get("refresh_ms")) if isinstance(display, dict) else None
        for failure in stress.get("failures") or []:
            ctx.notes.append(f"stress: {failure.get('angle')}: {failure.get('reason')}: {failure.get('detail')}")
        measured = 0
        for angle, entry in stress["angles"].items():
            if not isinstance(entry, dict):
                continue
            for line in entry.get("notes") or []:
                ctx.notes.append(f"stress {angle}: {line}")
            for arm in ARMS:
                window = entry.get(arm)
                if not isinstance(window, dict):
                    ctx.notes.append(f"stress {angle}: no {arm} window")
                    continue
                labels = {"angle": str(angle), "arm": arm}
                if window.get("terminal_focused") is False:
                    ctx.notes.append(f"stress {angle} {arm}: the typed terminal never had the keyboard; input rows skipped")
                rows = 0
                for key, metric, unit, better in METRICS + CONDITIONS:
                    if metric.startswith("input_") and window.get("terminal_focused") is False:
                        continue
                    value = _number(window.get(key))
                    if value is None:
                        continue
                    extra: dict[str, Any] = {}
                    if metric.startswith("input_latency"):
                        extra["n"] = (window.get("input") or {}).get("n")
                    if metric.startswith("frame_"):
                        extra["n"] = (window.get("frames") or {}).get("frames")
                    if not (isinstance(extra.get("n"), int) and extra["n"] >= 1):
                        extra.pop("n", None)
                    ctx.row(metric, value, unit, better=better, labels=labels, **extra)
                    rows += 1
                if rows:
                    measured += 1
        if refresh:
            ctx.notes.append(f"stress: display refresh {refresh} ms")
        if not measured:
            raise BenchError(f"stress: {path} contained no measured window")


BENCH = Stress()

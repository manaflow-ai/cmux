"""rivals: cmux NEXT against the agent apps and browsers people run beside it (scripts/perf-bench/rivals.py).

Leo, 2026-11-22 (ask-7c96907088): "compare to claude and codex and t3 code too. we absolutely need as many numbers
as possible, as many tables with as much data as possible [...] go look at edge/chrome/safari/slack/helium too."

Wraps scripts/measure/rivals.sh on a fleet Mac (the newest nightly-next DMG against Claude, Codex, T3 Code, Slack,
Chrome, Edge, Helium, Safari, and Rex where the host has it) and turns its results.json into rows, one per row id
and app (label app=<name>): first launch of a new install, launch after purge (close to a restart) and warm relaunch
to window (ms), the CPU (s) and peak footprint (MB) each costs, and the idle soak (footprint start/end/peak, growth
per minute, CPU, wakeups, disk, processes, threads) and bundle size.

  value = the run's samples for that row and app (results.json `samples`), else its median.
  Row ids become snake_case metrics (`fresh-window` -> `fresh_window`); `soak-memory-growth` (MB/min) becomes
  `soak_memory_growth_per_min` in MB. Units: /s -> per_s, KB/s -> kbps (x 8.192), n -> count.

`cmux-bench rivals --import FILE` records a results.json you already have.
"""
from __future__ import annotations

import collections
import json
import re
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/rivals.sh"
ARTIFACT = "artifacts/rivals/results.json"
PASS_THROUGH = ("apps", "rounds", "warm", "after", "soak", "sample", "maxload")
UNIT_MAP = {"ms": ("ms", 1.0), "s": ("s", 1.0), "MB": ("MB", 1.0), "MB/min": ("MB", 1.0), "%": ("%", 1.0),
            "/s": ("per_s", 1.0), "KB/s": ("kbps", 1024 * 8 / 1000), "n": ("count", 1.0)}
ROW_UNITS = {
    "fresh-window": "ms", "restart-window": "ms", "warm-window": "ms",
    "fresh-cpu": "s", "restart-cpu": "s", "warm-cpu": "s",
    "fresh-memory-peak": "MB", "restart-memory-peak": "MB", "warm-memory-peak": "MB",
    "soak-memory-start": "MB", "soak-memory-end": "MB", "soak-memory-peak": "MB", "soak-memory-growth": "MB/min",
    "soak-cpu": "%", "soak-cpu-peak": "%", "soak-wakeups": "/s", "soak-processes": "n", "soak-threads": "n",
    "soak-disk": "KB/s", "bundle-size": "MB",
}


def metric_of(row: str) -> str:
    return "soak_memory_growth_per_min" if row == "soak-memory-growth" else row.replace("-", "_")


class Rivals(Bench):
    name = "rivals"
    summary = ("cmux NEXT vs Claude, Codex, T3 Code, Rex, Slack and browsers: first-install, after-purge and warm "
               "launch, CPU and RAM per launch, idle RAM ceiling and growth")
    units = "ms, s, MB, %, per_s, kbps, count"
    owner = "perf (ask-7c96907088)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"

    def run(self, ctx: Context) -> None:
        channel = ctx.build.get("channel")
        if channel != "nightly":
            raise BenchError(f"rivals: measures the newest nightly-next DMG; --build {channel} has no fleet app here")
        args = [f"{k}={v}" for k, v in ctx.args.items() if k in PASS_THROUGH]
        res = ctx.fleet_step(self.harness, args, ARTIFACT, step_class="exclusive", labels=("bench",), timeout=7200)
        if not res.artifact_path:
            raise BenchError(f"rivals: step {res.job_id or '?'} left no results.json (exit {res.exit_code}); log {res.log_path}")
        self.ingest(ctx, res.artifact_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
        if not isinstance(doc, dict) or not isinstance(doc.get("rows"), dict):
            raise BenchError(f"{path}: not a rivals results.json (no rows)")
        m = doc.get("machine") or {}
        if m.get("host"):
            ctx.host.update({"name": str(m["host"]), "role": "fleet"})
        if m.get("macos"):
            ctx.host["os"] = f"macOS {m['macos']}"
        if m.get("chip"):
            ctx.host["chip"] = str(m["chip"])
        version = ((doc.get("apps") or {}).get("cmux") or {}).get("version")
        if version and not ctx.build.get("version"):
            ctx.build["version"] = version
        date = doc.get("date")
        if isinstance(date, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", date) and not ctx.timestamp.startswith(date):
            ctx.timestamp = f"{date}T00:00:00Z"
        samples: dict[tuple[str, str], list[float]] = {}
        for s in doc.get("samples") or []:
            if isinstance(s, dict) and isinstance(s.get("value"), (int, float)):
                samples.setdefault((s.get("row"), s.get("browser")), []).append(float(s["value"]))
        for row, per in sorted(doc["rows"].items()):
            unit = UNIT_MAP.get(ROW_UNITS.get(row, ""))
            if unit is None:
                ctx.notes.append(f"rivals: row {row} has no unit; skipped")
                continue
            unit_name, factor = unit
            for app, cell in sorted(per.items()):
                if not isinstance(cell, dict) or cell.get("median") is None:
                    continue
                labels = {"app": app}
                got = samples.get((row, app))
                if got and len(got) == cell.get("n", len(got)):
                    ctx.row(metric_of(row), unit=unit_name, samples=[v * factor for v in got], labels=labels)
                else:
                    ctx.row(metric_of(row), float(cell["median"]) * factor, unit_name, labels=labels)
        errors = collections.Counter((e.get("browser"), e.get("row"), e.get("note")) for e in doc.get("errors") or []
                                     if isinstance(e, dict))
        for (app, row, note), count in errors.items():
            ctx.notes.append(f"rivals: not measured: {app} {row}: {note}" + (f" (x{count})" if count > 1 else ""))


BENCH = Rivals()

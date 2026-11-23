"""launch-matrix: any .app's launch, timed the same way for every app (scripts/measure/launch-matrix.sh).

One harness for the cold-start tables: cmux NEXT and the apps it is compared with (Claude, Codex, T3 Code, Edge,
Chrome, Safari, Slack, Helium) on one Mac. Per launch, in ms from the LaunchServices open request: proc_start,
window_on_screen, first_visible_frame, interactive (the first accepted key), and the app's whole process tree at
first interactive and after an idle settle (procs, threads, footprint, RSS, CPU, disk read, idle CPU % and wakeups).
Scenarios: warm, cold-quit, evicted, first-install, update, large-session (the harness's header says each).

  --arg app=PATH|nightly     the app on the fleet Mac (nightly: the cmux NEXT NIGHTLY the feed offers now)
  --arg scenario=warm,cold-quit   --arg reps=3   --arg settle=30   --arg source=URL (first-install's download)
  --import FILE              the harness's log (LM-RUN lines) or its report.json

Rows: one per number, labeled app=<name> scenario=<arm>; value = median over the arm's launches.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/launch-matrix.sh"
LM_RUN = re.compile(r"LM-RUN (\{.*\})\s*$")
HOST = re.compile(r'LM host (\S+) chip="([^"]*)" macOS (\S+)')
TIMES = ("proc_start", "window_on_screen", "first_visible_frame", "interactive")
RESOURCES = {"procs": "count", "threads": "count", "footprint_mb": "MB", "rss_mb": "MB", "cpu_ms": "ms",
             "disk_read_mb": "MB", "pageins": "count"}
SETTLED = {"idle_cpu_pct": "%", "idle_wakeups_per_s": "per_s"}


def read_runs(path: Path) -> tuple[list[dict], str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    if text.lstrip().startswith("{") and '"schema": "launch-matrix/v1"' in text:
        return json.loads(text)["runs"], text
    runs = []
    for line in text.splitlines():
        m = LM_RUN.search(line) if "LM-RUN" in line else None
        if m:
            row = json.loads(m.group(1))
            if row.get("scenario"):  # the harness's recorded line, not the probe's own
                runs.append(row)
    return runs, text


class LaunchMatrix(Bench):
    name = "launch-matrix"
    summary = "Any app's launch, one harness: first visible frame, first accepted input, tree resources, per scenario"
    units = "ms, MB, count"
    owner = "cold-start tables (ask-37d682a340)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"

    def run(self, ctx: Context) -> None:
        args = [f"app={ctx.arg('app', 'nightly')}", f"scenario={ctx.arg('scenario', 'warm,cold-quit')}",
                f"reps={ctx.arg('reps', '3')}", f"settle={ctx.arg('settle', '30')}", "out=.build/launch-matrix"]
        for key in ("name", "source", "state-dir", "profile"):
            if ctx.arg(key):
                args.append(f"{key}={ctx.arg(key)}")
        res = ctx.fleet_step(HARNESS, args, ".build/launch-matrix/report.json",
                             labels=tuple(ctx.arg("labels", "measure").split(",")), timeout=7200, display=True)
        self.ingest(ctx, res.artifact_path or res.log_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        runs, text = read_runs(path)
        host = HOST.search(text)
        if host and ctx.host.get("name") in ("fleet", "", None):
            ctx.host.update({"name": host.group(1), "chip": host.group(2), "os": f"macOS {host.group(3)}"})
        if not runs:
            raise BenchError(f"{path}: no LM-RUN lines")
        for app, scenario in dict.fromkeys((r.get("app_name", "?"), r["scenario"]) for r in runs):
            measured = [r for r in runs if r.get("app_name", "?") == app and r["scenario"] == scenario]
            done = [r for r in measured if not r.get("error") and r.get("window_on_screen") is not None]
            labels = {"app": app, "scenario": scenario}
            ctx.row("failed_launches", len(measured) - len(done), "count", labels=labels)
            for key in TIMES:
                ctx.row(key, unit="ms", samples=[r.get(key) for r in done], labels=labels)
            for key, unit in RESOURCES.items():
                ctx.row(f"at_interactive_{key}", unit=unit, samples=[(r.get("at_interactive") or {}).get(key) for r in done],
                        labels=labels)
                ctx.row(f"settled_{key}", unit=unit, samples=[(r.get("settled") or {}).get(key) for r in done], labels=labels)
            for key, unit in SETTLED.items():
                ctx.row(f"settled_{key}", unit=unit, samples=[(r.get("settled") or {}).get(key) for r in done], labels=labels)


BENCH = LaunchMatrix()

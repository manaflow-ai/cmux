"""glass-perf: the app's cost idle and under load with 1/10/50 glass surfaces, and the composer over a fast-scrolled
chat, plain glass vs the lens (Leo, 2026-11-20: "i hope we got good numbers on idle ram/cpu/gpu and under load too").

scripts/cmux-next/glass-perf.py (through scripts/measure/split-spring.sh --suite=glass-perf, which builds the commit in
the bench configuration) drives the real app on a display mini. Per glass mode (`glass.lens`: plain, lens):
  state=idle   60 s with nothing moving, at 1, 10 and 50 `.ui-glass` surfaces in the chat page
  state=load   a streaming reply, wheel scrolling, window resizes, 3 popovers, background changes
  state=composer-scroll  the composer over a 2,000-message chat scrolled fast
Rows, labelled state, mode and surfaces: rss_mb, cpu_pct, energy_mw (CPU energy of the app's processes), gpu_pct
(the Mac's GPU Device Utilization, ioreg), gpu_ms_per_frame, frame_p50_ms and frame_p95_ms (the page's frames; load
and composer-scroll only). The web lens's own GPU cost per frame is the glass-engine bench.

`cmux-bench glass-perf --build SHA` runs it on the fleet; `--import FILE` reads the step's report.json or its log
(GLASS-PERF lines). Each run also prints the table rows for cmuxterm-hq docs/perf/glass-bench.md (`--markdown`).
"""
from __future__ import annotations

import json
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/split-spring.sh"
DRIVER = "scripts/cmux-next/glass-perf.py"
ARTIFACT = "artifacts/split-spring/report.json"
MARK = "GLASS-PERF "


def runs_of(path: Path) -> tuple[list[dict], dict]:
    """(the runs, the report's other keys) from report.json or a log's GLASS-PERF lines (pure)."""
    text = path.read_text(encoding="utf-8", errors="replace")
    try:
        doc = json.loads(text)
    except ValueError:
        doc = None
    if isinstance(doc, dict) and isinstance(doc.get("runs"), list):
        return [r for r in doc["runs"] if isinstance(r, dict)], doc
    runs = [json.loads(ln[len(MARK):]) for ln in text.splitlines() if ln.startswith(MARK)]
    return runs, {}


def cell(value, digits: int = 1) -> str:
    return "-" if value is None else f"{value:.{digits}f}"


def table_row(run: dict, date: str, sha: str, host: str) -> str:
    """One docs/perf/glass-bench.md row for a run (pure)."""
    total = run.get("total") or {}
    frame = run.get("frame") or {}
    state = run["state"] + {"wallpaper-still": " (lens: wallpaper still)",
                            "live-content": " (lens: live chat)"}.get(run.get("lens_source"), "")
    gpu = f"{cell(run.get('gpu_pct'))} / {cell(run.get('gpu_ms_per_frame'), 2)}"
    frames = f"{cell(frame.get('page_p50_ms'))} / {cell(frame.get('page_p95_ms'))}" if frame else "- / -"
    return (f"| {date} | {sha[:10]} | {host} | {state} | {run.get('mode')} | {run.get('surfaces', '-')} | "
            f"{cell(total.get('rss_mb'), 0)} | {cell(total.get('cpu_pct'))} | {gpu} | {frames} | "
            f"{cell(total.get('energy_mw'), 0)} |")


class GlassPerf(Bench):
    name = "glass-perf"
    summary = "idle and load RSS, CPU, GPU, frames, energy at 1/10/50 glass; composer over a fast scroll, plain vs lens"
    units = "MB, %, ms, mW"
    owner = "glass engine (webviews/src/ui/glass)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    floors = {"rss_mb": 30.0, "cpu_pct": 2.0, "gpu_pct": 2.0, "gpu_ms_per_frame": 0.2, "frame_p50_ms": 1.0,
              "frame_p95_ms": 2.0, "energy_mw": 30.0}

    def run(self, ctx: Context) -> None:
        sha = ctx.build.get("sha")
        if not sha:
            raise BenchError(f"glass-perf: --build {ctx.build.get('channel')} has no commit to build; pass --build SHA")
        args = ["--suite=glass-perf", "--config=bench", "--app-cache"]
        for key in ("surfaces", "modes", "scenario", "idle", "load", "messages"):
            if ctx.arg(key):
                args.append(f"--{key}={ctx.arg(key)}")
        res = ctx.fleet_step(HARNESS, args, ARTIFACT, step_class="exclusive", labels=("measure",), display=True,
                             timeout=int(ctx.arg("timeout") or 7200), ref=sha)
        self.ingest(ctx, res.artifact_path or res.log_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        runs, doc = runs_of(path)
        if not runs:
            raise BenchError(f"glass-perf: {path}: no glass-perf runs (report.json `runs` or GLASS-PERF lines)")
        for error in doc.get("errors") or []:
            ctx.notes.append(f"glass-perf: {str(error)[:300]}")
        for run in runs:
            labels = {"state": run["state"], "mode": run.get("mode"), "surfaces": run.get("surfaces")}
            total = run.get("total") or {}
            ctx.row("rss_mb", total.get("rss_mb"), "MB", labels=labels)
            ctx.row("cpu_pct", total.get("cpu_pct"), "%", labels=labels)
            ctx.row("energy_mw", total.get("energy_mw"), "mW", labels=labels)
            for group, g in sorted((run.get("groups") or {}).items()):
                ctx.row("rss_mb", g.get("rss_mb"), "MB", labels={**labels, "component": group})
                ctx.row("cpu_pct", g.get("cpu_pct"), "%", labels={**labels, "component": group})
            if run.get("gpu_pct") is not None:
                ctx.row("gpu_pct", run["gpu_pct"], "%", labels=labels)
            if run.get("gpu_ms_per_frame") is not None:
                ctx.row("gpu_ms_per_frame", run["gpu_ms_per_frame"], "ms", labels=labels)
            frame = run.get("frame") or {}
            if frame.get("page_p50_ms") is not None:
                ctx.row("frame_p50_ms", frame["page_p50_ms"], "ms", labels=labels)
                ctx.row("frame_p95_ms", frame["page_p95_ms"], "ms", labels=labels)
        date = ctx.timestamp[:10] if isinstance(ctx.timestamp, str) else ""
        sha = str(doc.get("sha") or ctx.build.get("sha") or "")
        host = str(doc.get("host") or ctx.host.get("name") or "")
        for run in runs:
            ctx.notes.append("table: " + table_row(run, date, sha, host))


BENCH = GlassPerf()

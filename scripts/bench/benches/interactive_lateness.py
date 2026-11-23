"""interactive-lateness: how interactive this machine is right now (RFD 0072, "The measurement").

Wraps scripts/measure/interactive-lateness.sh (probe: scripts/measure/latency_probe.py), which prints one JSON line
(schema interactive-lateness/v1): a user-interactive thread sleeping 10 ms and how late each wake is, CPU busy over
the window, load, memory pressure, swap and its growth, thermal pressure and HID idle. Read-only; it runs where
cmux-bench runs (--host local-readonly on the person's Mac, before and after one move) or on any host.

Args: --arg seconds=60 (default) --arg label=before. `--import FILE` reads a saved line.

Rows (better = lower unless noted): lateness_p50, lateness_p95, lateness_p99, lateness_max (ms, n = wakes);
lateness_over_5ms, lateness_over_16ms (%); cpu_busy (%); memory_free (%, higher); swap_used (MB);
swapout_rate (MB swapped out per minute, labels window=per_min); hid_idle (s, higher).
Every row is labelled with the run's label.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/interactive-lateness.sh"
REPO = Path(__file__).resolve().parents[3]


class InteractiveLateness(Bench):
    name = "interactive-lateness"
    summary = "Timer lateness (10 ms sleeps), CPU busy, memory pressure, swap, thermal and HID idle of this machine now"
    units = "ms, %, MB, s"
    owner = "RFD 0072 auto local-cloud harmony"
    hosts = ("local-readonly", "anywhere")
    harness = HARNESS
    version = "1"
    thresholds = {"lateness_p50": 50.0, "lateness_p95": 50.0, "cpu_busy": 20.0}
    nightly = False

    def run(self, ctx: Context) -> None:
        seconds = ctx.arg("seconds", "60")
        label = ctx.arg("label", "run")
        got = subprocess.run(["bash", str(REPO / HARNESS), f"seconds={seconds}", f"label={label}"], text=True,
                             capture_output=True, timeout=float(seconds) + 120)
        if got.returncode != 0:
            raise BenchError(f"interactive-lateness: harness exit {got.returncode}: {got.stderr.strip()[-300:]}")
        path = ctx.workdir / "interactive-lateness.json"
        path.write_text(got.stdout)
        ctx.notes.append(f"interactive-lateness: line {path}")
        self.ingest(ctx, path)

    def ingest(self, ctx: Context, path: Path) -> None:
        lines = [ln for ln in Path(path).read_text(encoding="utf-8").splitlines() if ln.strip()]
        if not lines:
            raise BenchError(f"{path}: empty")
        doc = json.loads(lines[-1])
        if doc.get("schema") != "interactive-lateness/v1":
            raise BenchError(f"{path}: not an interactive-lateness/v1 line")
        if doc.get("os"):
            ctx.host["os"] = doc["os"]
        labels = {"label": doc.get("label", "run")}
        lat = doc.get("lateness_ms") or {}
        n = lat.get("wakes")
        for q in ("p50", "p95", "p99", "max"):
            ctx.row(f"lateness_{q}", lat.get(q), "ms", n=n, labels=labels)
        ctx.row("lateness_over_5ms", lat.get("over_5ms_pct"), "%", n=n, labels=labels)
        ctx.row("lateness_over_16ms", lat.get("over_16ms_pct"), "%", n=n, labels=labels)
        ctx.row("cpu_busy", (doc.get("cpu") or {}).get("busy_pct"), "%", labels=labels)
        mem = doc.get("memory") or {}
        if mem.get("free_pct") is not None:
            ctx.row("memory_free", mem["free_pct"], "%", better="higher", labels=labels)
        swap = doc.get("swap") or {}
        if swap.get("used_mb") is not None:
            ctx.row("swap_used", swap["used_mb"], "MB", labels=labels)
        if swap.get("swapout_mb_per_min") is not None:
            ctx.row("swapout_rate", swap["swapout_mb_per_min"], "MB", labels={**labels, "window": "per_min"})
        if doc.get("hid_idle_s") is not None:
            ctx.row("hid_idle", doc["hid_idle_s"], "s", better="higher", labels=labels)
        for key, why in sorted((doc.get("errors") or {}).items()):
            ctx.notes.append(f"interactive-lateness: {key}: {why}")


BENCH = InteractiveLateness()

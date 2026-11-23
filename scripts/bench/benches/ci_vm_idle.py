"""GCP CI VM occupancy and idle list-cost measurement.

The harness reads a local capture directory and prints one JSON document.  The
bench keeps the harness's hour and dollar totals in its report while recording
seconds and integer cents in the shared row schema, whose units are fixed.
"""
from __future__ import annotations

import json
import math
import subprocess
import sys
from pathlib import Path
from typing import Any

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context

HARNESS = "scripts/measure/ci-vm-idle.py"
POOLS = ("persistent", "jit")
INPUT_METRICS = ("running_vm_hours", "idle_vm_hours", "idle_list_usd")


class CiVmIdle(Bench):
    name = "ci-vm-idle"
    summary = "GCP CI VM running time, idle time and list-price cost from a captured 24-hour inventory"
    units = "s, count"
    owner = "GCP CI capacity"
    hosts = ("anywhere",)
    harness = HARNESS
    version = "1"

    def run(self, ctx: Context) -> None:
        input_dir = ctx.arg("input")
        if not input_dir:
            raise BenchError("ci-vm-idle: pass --arg input=PATH to a captured input directory")
        capture = Path(input_dir).expanduser().resolve()
        if not capture.is_dir():
            raise BenchError(f"ci-vm-idle: input capture is not a directory: {capture}")
        command = [sys.executable, str(REPO_ROOT / HARNESS), str(capture)]
        if ctx.dry_run:
            print("dry run:", " ".join(command))
            raise BenchError("dry run")
        got = subprocess.run(command, cwd=REPO_ROOT, text=True, capture_output=True, timeout=1800, check=False)
        if got.returncode:
            detail = (got.stderr or got.stdout).strip()[-500:]
            raise BenchError(f"ci-vm-idle: harness failed ({got.returncode}): {detail}")
        report = ctx.workdir / "ci-vm-idle.json"
        report.write_text(got.stdout, encoding="utf-8")
        self.ingest(ctx, report)

    def ingest(self, ctx: Context, path: Path) -> None:
        try:
            report: Any = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise BenchError(f"ci-vm-idle: {path}: expected harness JSON: {exc}") from exc
        if not isinstance(report, dict) or not isinstance(report.get("pools"), dict):
            raise BenchError(f"ci-vm-idle: {path}: missing pools object")
        window_end = report.get("window_end")
        if not isinstance(window_end, str) or not window_end:
            raise BenchError(f"ci-vm-idle: {path}: missing window_end")

        values: dict[tuple[str, str], float] = {}
        for pool in POOLS:
            row = report["pools"].get(pool)
            if not isinstance(row, dict):
                raise BenchError(f"ci-vm-idle: {path}: missing {pool} pool")
            for metric in INPUT_METRICS:
                value = row.get(metric)
                if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value) or value < 0:
                    raise BenchError(f"ci-vm-idle: {path}: {pool}.{metric} must be a non-negative number")
                values[(pool, metric)] = float(value)

        # Convert only after validating the complete report, so a malformed pool cannot publish partial rows.
        for pool in POOLS:
            ctx.row("running_vm_seconds", values[(pool, "running_vm_hours")] * 3600, "s",
                    labels={"pool": pool})
            ctx.row("idle_vm_seconds", values[(pool, "idle_vm_hours")] * 3600, "s",
                    labels={"pool": pool})
            ctx.row("idle_list_cents", round(values[(pool, "idle_list_usd")] * 100), "count",
                    labels={"pool": pool})
        ctx.notes.append(f"ci-vm-idle: source window ended {window_end}; source totals are hours and USD")


BENCH = CiVmIdle()

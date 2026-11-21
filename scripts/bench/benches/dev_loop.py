"""dev-loop: edit to running for four loops, each against its simulated stage-floor bound (goal dev-loop-ceiling).

Leo: "Dev loop at its theoretical ceiling: a measured and simulated bound for edit-to-running (web swap, daemon
restart, Swift inject, startup-time loop) published, and the measured p50 within 2x of that bound".

Runs scripts/measure/dev-loop-ceiling.sh on one fleet Mac (one exclusive step): each loop's
scripts/measure/dev-loop/<loop>.sh makes N real edits and times each stage, measures each stage's floor, then
scripts/measure/dev-loop/bound.py writes report.json. Rows per loop: end_to_end (p50 over rounds), bound (simulated
critical path of the floors), ratio; per stage: its time over its floor. worst_ratio is the goal's number, written only
when all four loops measured.

  --arg rounds=N   edit rounds per loop (default 5); --arg loops=web_swap,...   a subset
  --import PATH    ingest a report.json (or a directory holding one) from an earlier step
"""
from __future__ import annotations

import json
import subprocess
import tarfile
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/dev-loop-ceiling.sh"
OUT = ".build/dev-loop-ceiling"
ARTIFACT = f"{OUT}/report.json"  # cmux-ci run --artifact takes one file
LOOPS = "web_swap,daemon_restart,swift_inject,startup_loop"


def find_report(path: Path) -> Path:
    if path.is_file() and path.name == "report.json":
        return path
    if path.is_file() and tarfile.is_tarfile(path):
        out = path.with_suffix(".d")
        with tarfile.open(path) as tar:
            tar.extractall(out, filter="data")
        path = out
    if path.is_dir():
        found = sorted(path.rglob("report.json"))
        if found:
            return found[0]
    raise BenchError(f"dev-loop: no report.json in {path}")


class DevLoop(Bench):
    name = "dev-loop"
    summary = "Edit to running (web swap, daemon restart, Swift inject, startup loop) over each loop's stage-floor bound"
    units = "ms, x"
    owner = "goal dev-loop-ceiling"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"

    def run(self, ctx: Context) -> None:
        if ctx.args.get("import"):
            self.ingest(ctx, Path(ctx.args["import"]))
            return
        args = [OUT, ctx.arg("rounds", "5"), ctx.arg("loops", LOOPS)]
        res = ctx.fleet_step(HARNESS, args, ARTIFACT, labels=tuple(ctx.arg("labels", "measure").split(",")),
                             timeout=int(ctx.arg("timeout", "5400")), display=True)  # startup_loop draws a window
        if res.artifact_path is None and res.job_id:  # an incomplete run exits 1 and still writes report.json
            got = self.workdir_fetch(ctx, res.job_id)
            if got:
                res.artifact_path = got
        if res.artifact_path is None:
            raise BenchError(f"dev-loop: step {res.job_id or '?'} gave no artifact; log {res.log_path}")
        self.ingest(ctx, res.artifact_path)

    @staticmethod
    def workdir_fetch(ctx: Context, job_id: str) -> Path | None:
        out = ctx.workdir / "report.json"
        got = subprocess.run(["cmux-ci", "artifact", job_id, str(out), "--failed"], text=True, capture_output=True)
        return out if got.returncode == 0 and out.exists() else None

    def ingest(self, ctx: Context, path: Path) -> None:
        report = json.loads(find_report(path).read_text())
        for loop, r in (report.get("loops") or {}).items():
            if not r.get("measured"):
                ctx.notes.append(f"{loop}: unmeasured ({r.get('why')})")
                continue
            labels = {"loop": loop}
            ctx.row("end_to_end_p50", r["end_to_end_p50_ms"], "ms", n=r.get("rounds"), labels=labels)
            ctx.row("bound_p50", r["simulated_bound_p50_ms"], "ms", labels=labels)
            ctx.row("ratio", r["ratio"], "x", labels=labels)
            for stage, s in (r.get("stages") or {}).items():
                if s.get("over_floor_ms") is not None:
                    ctx.row("stage_over_floor", s["over_floor_ms"], "ms", labels={**labels, "stage": stage})
        if report.get("worst_ratio") is not None:
            ctx.row("worst_ratio", report["worst_ratio"], "x", labels={"loop": report.get("worst_loop")})
        else:
            ctx.notes.append("worst_ratio: unmeasured (not every loop measured)")


BENCH = DevLoop()

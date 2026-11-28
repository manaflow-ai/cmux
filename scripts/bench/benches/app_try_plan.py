"""app-try-plan: the plan phase of a repeat `cmux app try dir:CHECKOUT` of an unchanged tree, before and after
hot-verify.py kept its index copy between snapshots (goal team-dev-build-is-swap: the swap's 5 s bound).

Runs scripts/measure/app-try-plan.py, which times hot-verify.py snapshot() (the dir: source half of plan), the two
arms alternated in one process over the cmux checkout itself.
Rows: snapshot_ms per arm (p50 over rounds), labels arm=before|after; first_ms (the kept copy's first use).

  --host fleet       one exclusive fleet-Mac step (the default); --host anywhere   this machine's checkout
  --arg rounds=N     rounds per arm (default 5)
  --import PATH      ingest a report the harness wrote
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context

HARNESS = "scripts/measure/app-try-plan.py"
ARTIFACT = ".build/app-try-plan/report.json"


class AppTryPlan(Bench):
    name = "app-try-plan"
    summary = "Plan phase of a repeat `cmux app try dir:` of an unchanged tree, throwaway vs kept index copy"
    units = "ms"
    owner = "goal team-dev-build-is-swap"
    hosts = ("fleet", "anywhere")
    harness = HARNESS
    version = "1"

    def run(self, ctx: Context) -> None:
        if ctx.args.get("import"):
            self.ingest(ctx, Path(ctx.args["import"]))
            return
        rounds = ctx.arg("rounds", "5")
        if ctx.host_role == "fleet":
            res = ctx.fleet_step(HARNESS, ["--rounds", rounds, "--out", ARTIFACT], ARTIFACT,
                                 labels=tuple(ctx.arg("labels", "measure").split(",")),
                                 timeout=int(ctx.arg("timeout", "1800")))
            if res.artifact_path is None:
                raise BenchError(f"app-try-plan: step {res.job_id or '?'} gave no artifact; log {res.log_path}")
            self.ingest(ctx, res.artifact_path)
            return
        out = ctx.workdir / "report.json"
        command = [sys.executable, str(REPO_ROOT / HARNESS), "--rounds", rounds, "--out", str(out)]
        if ctx.dry_run:
            print("dry run:", " ".join(command))
            raise BenchError("dry run")
        got = subprocess.run(command, cwd=REPO_ROOT, text=True, capture_output=True, timeout=3600, check=False)
        if got.returncode:
            raise BenchError(f"app-try-plan: harness failed ({got.returncode}): {(got.stderr or got.stdout)[-500:]}")
        self.ingest(ctx, out)

    def ingest(self, ctx: Context, path: Path) -> None:
        try:
            report = json.loads(Path(path).read_text())
            samples = report["samples_ms"]
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise BenchError(f"app-try-plan: {path}: not the harness's report: {exc}") from exc
        for arm in ("before", "after"):
            ctx.row("snapshot_ms", samples=samples.get(arm) or [], labels={"arm": arm})
        ctx.row("first_ms", report.get("first_ms"))
        ctx.notes.append(f"app-try-plan: {report.get('files')} tracked files, {report.get('rounds')} rounds per arm")


BENCH = AppTryPlan()

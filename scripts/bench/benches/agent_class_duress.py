"""agent-class-duress: an agent's tool loop under load, at the CPU class acpmux gave it before and after
the dynamic class (cmux-tui/crates/acpmux/src/cpu_class/pressure.rs).

Leo, 2026-11-25: "lucas ran into slow stuff on the desktop gui app with claude bc he was at relatively high
cpu and agents' tool calls ran at background priority and stuff so it took like 87 minutes to do things".

Wraps scripts/measure/agent-class-duress.sh on one fleet Mac (exclusive). Rows: tool_loop_wall (s) labelled
{load: idle|eighty|full, arm: background|dynamic}, and per load the controller's own reading (busy_p50,
late_p90_ms_p50, pressured_share). A cell that hit the harness's cap is a note, not a row.

  --arg rounds=N jobs=N cap=S     the harness's knobs
  --import PATH                   ingest a report.json from an earlier step
"""
from __future__ import annotations

import json
import statistics
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/agent-class-duress.sh"
OUT = ".build/agent-class-duress"
ARTIFACT = f"{OUT}/report.json"
DEMOTE_BUSY, DEMOTE_LATE_MS = 0.90, 2.0


def readings(text: str) -> list[tuple[float, float]]:
    out = []
    for part in text.split(";"):
        fields = dict(kv.split("=", 1) for kv in part.split()[1:] if "=" in kv)
        if "busy" in fields and "late_p90_ms" in fields:
            out.append((float(fields["busy"]), float(fields["late_p90_ms"])))
    return out


class AgentClassDuress(Bench):
    name = "agent-class-duress"
    summary = "An agent's tool loop under 80% and full load at background class (before) and the dynamic class (after)"
    units = "s, %, ms"
    owner = "acpmux dynamic CPU class (Leo, 2026-11-25)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"

    def run(self, ctx: Context) -> None:
        if ctx.args.get("import"):
            self.ingest(ctx, Path(ctx.args["import"]))
            return
        args = [OUT, ctx.arg("rounds", "4"), ctx.arg("jobs", "4"), ctx.arg("cap", "900")]
        res = ctx.fleet_step(HARNESS, args, ARTIFACT, labels=tuple(ctx.arg("labels", "measure").split(",")),
                             timeout=int(ctx.arg("timeout", "7200")), ref=ctx.arg("ref") or ctx.build.get("sha"))
        if res.artifact_path is None:
            raise BenchError(f"agent-class-duress: step {res.job_id or '?'} gave no report; log {res.log_path}")
        self.ingest(ctx, res.artifact_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        if path.is_dir():
            path = path / "report.json"
        try:
            report = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise BenchError(f"agent-class-duress: cannot read {path}: {error}") from error
        cells = report.get("cells") or []
        if not cells:
            raise BenchError(f"agent-class-duress: {path} has no cells")
        if report.get("host"):
            ctx.host["name"] = str(report["host"])
        for cell in cells:
            labels = {"load": cell["load"], "arm": cell["arm"]}
            if cell["wall_s"] == "cap":
                ctx.notes.append(f"{cell['load']}/{cell['arm']}: past the {report.get('cap_s')} s cap")
                continue
            ctx.row("tool_loop_wall", float(cell["wall_s"]), "s", labels=labels)
        for probe in report.get("probes") or []:
            got = readings(probe.get("readings", ""))
            if not got:
                continue
            labels = {"load": probe["load"]}
            ctx.row("busy_p50", 100 * statistics.median(b for b, _ in got), "%", better="none", labels=labels)
            ctx.row("late_p90_ms_p50", statistics.median(l for _, l in got), "ms", labels=labels)
            pressured = sum(1 for b, l in got if b >= DEMOTE_BUSY and l >= DEMOTE_LATE_MS) / len(got)
            ctx.row("pressured_share", 100 * pressured, "%", better="none", labels=labels)


BENCH = AgentClassDuress()

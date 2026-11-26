"""Shared Linux/Mac acpmux drill; import validation is not a latency or load-budget pass."""
from __future__ import annotations

import json
import math
import re
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/ci/cmux-tui-rust-check.sh"
ARTIFACT = ".build/artifacts/acpmux-duress/duress-bench.json"


def number(value, name, *, maximum=None):
    if (isinstance(value, bool) or not isinstance(value, (int, float))
            or not math.isfinite(value) or value < 0
            or (maximum is not None and value > maximum)):
        raise BenchError(f"acpmux-duress: missing or invalid {name}: {value!r}")
    return value


class AcpmuxDuress(Bench):
    name = "acpmux-duress"
    summary = "Acpmux baseline and RFD 0050 CPU/RAM/broker drill, with CLI/socket p50 and p99"
    units = "ms, %, count"
    owner = "RFD 0050 / 0124"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"

    def run(self, ctx: Context) -> None:
        if ctx.args.get("import"):
            self.ingest(ctx, Path(ctx.args["import"]))
            return
        sha = ctx.build.get("sha")
        if not sha:
            raise BenchError("acpmux-duress: --build must resolve to the source commit")
        result = ctx.fleet_step(HARNESS, ["duress"], ARTIFACT, ref=sha,
                                labels=("macos-26",), timeout=7200)
        if result.exit_code or result.artifact_path is None:
            raise BenchError(f"acpmux-duress: step {result.job_id} has no successful report; {result.log_path}")
        self.ingest(ctx, result.artifact_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        try:
            report = json.loads(path.read_text())
        except (ValueError, OSError) as error:
            raise BenchError(f"acpmux-duress: cannot read report: {error}") from error
        if not isinstance(report, dict) or report.get("schema") != "acpmux.duress-bench.v1":
            raise BenchError("acpmux-duress: unsupported report")
        sha = report.get("commit", "")
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise BenchError("acpmux-duress: missing source commit")
        if ctx.build.get("sha") and ctx.build["sha"] != sha:
            raise BenchError("acpmux-duress: report does not match requested source commit")
        if report.get("removalErrors") != []:
            raise BenchError("acpmux-duress: cleanup is unverified or failed")
        if not report.get("host") or report.get("os") not in ("macos", "linux") or not report.get("memoryMetric"):
            raise BenchError("acpmux-duress: missing host or counter identity")
        legs = report.get("legs", [])
        if not isinstance(legs, list) or len(legs) != 2 or {l.get("leg") for l in legs} != {"baseline", "rfd0050"}:
            raise BenchError("acpmux-duress: expected baseline and rfd0050 reports")
        # Validate all cells before publishing any rows. Failures remain measured outcomes;
        # missing operations/counters or an incomplete setup are not measurements.
        for leg in legs:
            if leg.get("error") or leg.get("setupErrors") != {}:
                raise BenchError(f"acpmux-duress: incomplete {leg['leg']} setup")
            ops = leg.get("ops", [])
            required = {"ls", "send"} | ({"status", "send-far"} if leg["leg"] == "rfd0050" else set())
            if not {(op, via) for op in required for via in ("cli", "socket")} <= {(o.get("op"), o.get("via")) for o in ops}:
                raise BenchError(f"acpmux-duress: missing {leg['leg']} operations")
            for op in ops:
                if number(op.get("n"), "sample count") < 1:
                    raise BenchError("acpmux-duress: empty operation")
                for key in ("p50Ms", "p95Ms", "p99Ms", "maxMs", "errors"):
                    number(op.get(key), key)
            live = leg.get("liveness", {})
            if number(live.get("polls"), "liveness polls") < 1:
                raise BenchError("acpmux-duress: no liveness observations")
            number(live.get("falseDead"), "falseDead")
            if leg["leg"] == "rfd0050":
                for key in ("cpuBusyPct", "memUsedPctAtClock", "memUsedPctAtEnd"):
                    number(leg.get("stressors", {}).get(key), key, maximum=100)
        ctx.build["sha"] = sha
        ctx.host.update(name=report["host"], os=report["os"])
        for leg in legs:
            labels = {"leg": leg["leg"], "os": report["os"]}
            for op in leg["ops"]:
                cell = dict(labels, op=op["op"], via=op["via"])
                ctx.row("latency", op["p50Ms"], "ms", p50=op["p50Ms"], p95=op["p95Ms"], n=op["n"], labels=cell)
                ctx.row("latency_p99", op["p99Ms"], "ms", n=op["n"], labels=cell)
                ctx.row("errors", op["errors"], "count", labels=cell)
            ctx.row("false_dead", leg["liveness"]["falseDead"], "count", labels=labels)
            if leg["leg"] == "rfd0050":
                for key in ("cpuBusyPct", "memUsedPctAtClock", "memUsedPctAtEnd"):
                    ctx.row(key, leg["stressors"][key], "%", better="none",
                            labels=dict(labels, memory_metric=report["memoryMetric"]))
        ctx.notes.append("Observed load is recorded, not certified as a sustained 90% CPU/RAM budget pass.")


BENCH = AcpmuxDuress()

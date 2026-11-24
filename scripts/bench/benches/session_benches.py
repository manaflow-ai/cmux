"""session-benches: the published session benchmarks (RFD 0167 row 18) on Linux, one run per week.

Wraps scripts/measure/published-benches-linux.sh: resume after a daemon restart, fork of a 20-turn chat, `acpmux
session move` between two daemons, a cold and a warm release build of acpmux, and the long session under load (8 chats
streaming, a probe prompt on an idle chat every 5 s; `--arg soak_secs=28800` is the 8 h run). It prints one
`PUBLISHED-BENCH <json>` line per part (schema cmux.published-bench.v1); `ingest` reads them. cmuxterm-hq
docs/benchmarks/README.md publishes the numbers.

Rows, better = lower: resume_ms, resume.daemon_ready_ms, fork_ms, move_ms, build.cold_s, build.warm_s,
soak.input_ms (p50, p95), soak.ls_ms, soak.rss_end_mb, soak.rss_growth_mb, soak.zombies_max, soak.turn_errors.

Run: `cmux-bench session-benches [--arg parts=resume,fork,move,build,soak] [--arg soak_secs=600]` sends the
harness through `cmux-ci test --setup rust` (on a lane VM at the caller's open PR head; its 3 h cap bounds the soak
there). `--import PATH` reads a harness log.
"""
from __future__ import annotations

import json
import re
import shlex
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/published-benches-linux.sh"
PASS_THROUGH = ("parts", "samples", "soak_secs", "moves")
MARK = "PUBLISHED-BENCH "
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ")


def records(text: str) -> list[dict]:
    out = []
    for raw in text.splitlines():
        line = STAMP.sub("", raw.strip())
        at = line.find(MARK)
        if at < 0:
            continue
        try:
            value = json.loads(line[at + len(MARK):])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and value.get("schema") == "cmux.published-bench.v1":
            out.append(value)
    return out


class SessionBenches(Bench):
    name = "session-benches"
    summary = "Resume, fork, move, build and the long session under load (p95 input latency, RSS) on Linux"
    units = "ms, s, MB, count"
    owner = "benches-fresh (RFD 0167 row 18)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"

    def run(self, ctx: Context) -> None:
        args = [f"{k}={v}" for k, v in ctx.args.items() if k in PASS_THROUGH]
        cmd = ["cmux-ci", "test", "--setup", "rust", "--timeout", "10800", "--", HARNESS, *args]
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        log = ctx.workdir / "session-benches.log"
        with log.open("w", encoding="utf-8") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, check=False)
        ctx.host.update({"name": "linux-ci", "os": "Linux"})
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        found = records(Path(path).read_text(encoding="utf-8", errors="replace"))
        if not found:
            raise BenchError(f"{path}: no PUBLISHED-BENCH line (not a published-benches-linux.sh log?)")

        def dist(metric, d, unit, labels=None):
            if isinstance(d, dict) and isinstance(d.get("p50"), (int, float)) and isinstance(d.get("p95"), (int, float)):
                ctx.row(metric, d["p50"], unit, p50=d["p50"], p95=d["p95"], n=d.get("n"), labels=labels or {})

        def one(metric, v, unit, labels=None):
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                ctx.row(metric, v, unit, labels=labels or {})

        for r in found:
            kind = r.get("bench")
            if kind == "resume":
                dist("resume_ms", r.get("resume_ms"), "ms")
                dist("resume.daemon_ready_ms", r.get("daemon_ready_ms"), "ms")
            elif kind == "fork":
                dist("fork_ms", r.get("fork_ms"), "ms", {"history_turns": str(r.get("history_turns"))})
            elif kind == "move":
                dist("move_ms", r.get("move_ms"), "ms")
            elif kind == "build":
                one("build.cold_s", r.get("cold_s"), "s")
                one("build.warm_s", r.get("warm_s"), "s")
            elif kind == "soak":
                labels = {"duration_s": str(r.get("duration_s")), "load_chats": str(r.get("load_chats"))}
                dist("soak.input_ms", r.get("input_ms"), "ms", labels)
                dist("soak.ls_ms", r.get("ls_ms"), "ms", labels)
                rss = r.get("rss_mb") or {}
                one("soak.rss_end_mb", rss.get("end"), "MB", labels)
                if isinstance(rss.get("end"), (int, float)) and isinstance(rss.get("start"), (int, float)):
                    one("soak.rss_growth_mb", round(rss["end"] - rss["start"], 1), "MB", labels)
                one("soak.zombies_max", r.get("zombies_max"), "count", labels)
                one("soak.turn_errors", r.get("turn_errors"), "count", labels)


BENCH = SessionBenches()

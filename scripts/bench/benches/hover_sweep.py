"""hover-sweep: the hover rules' main-thread cost per pointer move, in ns (B8 step B's A/B).

Wraps scripts/measure/hover-sweep.sh, which runs Lawrence's HoverCardSweepBench (CmuxNextDesignTests) in a
release build on a fleet Mac, `runs` times: a pointer resting on a sidebar row until its card opens, then
sweeping 60 rows down and back with the card following, timing each move's safe-triangle test and
HoverCardMachine event. The rules are the ones the commit has: the Swift reducers before step B, the Rust
hover rules through the app FFI after. Each run prints

  HS-RUN hover-card sweep bench: macOS ..., 96000 pointer moves over 60 rows: p50 X ns, p95 Y ns, p99 Z ns, max W ns

Rows: pointer_move_p50, pointer_move_p95, pointer_move_p99, pointer_move_max (ns, lower), one sample per test
process (value = the median process); moves (count, none). Before and after are two runs at two commits, on one worker:

  cmux-bench hover-sweep --host fleet --build <before sha>
  cmux-bench hover-sweep --host fleet --build <after sha> --arg ffi=source --arg worker=<the first run's worker>
  cmux-bench compare <before run> <after run> --markdown

  --arg ffi=source   build the app FFI from the commit's Rust sources, for a commit whose Swift needs FFI changes
                     the pinned release lacks (default: pinned)
  --arg runs=N       test processes (default 5)

`--import LOG` reads a step log with HS-RUN lines.
"""
from __future__ import annotations

import re
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

LINE = re.compile(r"HS-RUN hover-card sweep bench:.*?(\d+) pointer moves over (\d+) rows: p50 (\d+) ns, "
                  r"p95 (\d+) ns, p99 (\d+) ns, max (\d+) ns")
HOST = re.compile(r'HS host (\S+) chip="([^"]*)" macOS (\S+)')
QUANTILES = ("p50", "p95", "p99", "max")


class HoverSweep(Bench):
    name = "hover-sweep"
    summary = "Hover rules per pointer move (ns): a 60-row sidebar sweep through HoverCardMachine, release build"
    units = "ns"
    owner = "hover rules in Rust (B8 step B)"
    hosts = ("fleet",)
    harness = "scripts/measure/hover-sweep.sh"
    version = "1"
    floors = {f"pointer_move_{q}": 50.0 for q in QUANTILES}

    def run(self, ctx: Context) -> None:
        ref = ctx.build.get("sha") if ctx.build.get("channel") == "sha" else None
        if not ref:
            raise BenchError("hover-sweep: pass --build <sha>, the commit whose hover rules to measure")
        args = [f"ffi={ctx.arg('ffi') or 'pinned'}", f"runs={ctx.arg('runs') or 5}"]
        res = ctx.fleet_step(self.harness, args, None, step_class="exclusive", labels=("measure",),
                             timeout=5400, ref=ref)
        self.ingest(ctx, res.log_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        runs = [m.groups() for m in LINE.finditer(text)]
        if not runs:
            raise BenchError(f"hover-sweep: no HS-RUN line in {path}")
        host = HOST.search(text)
        if host:
            ctx.host.update({"chip": host.group(2), "os": f"macOS {host.group(3)}"})
            if ctx.host.get("name") in (None, "", "fleet"):
                ctx.host["name"] = host.group(1)
        for i, q in enumerate(QUANTILES):
            ctx.row(f"pointer_move_{q}", unit="ns", samples=[float(r[2 + i]) for r in runs])
        ctx.row("moves", float(runs[0][0]), "count", better="none")


BENCH = HoverSweep()

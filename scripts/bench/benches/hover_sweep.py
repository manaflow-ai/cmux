"""hover-sweep: the hover rules' main-thread cost per pointer move, in us (B8 step B's A/B).

Runs Lawrence's HoverCardSweepBench (CmuxNextDesignTests) in a release build on a fleet Mac, `runs` test
processes: a pointer resting on a sidebar row until its card opens, then sweeping 60 rows down and back with the
card following, timing each move's safe-triangle test and HoverCardMachine event. The rules are the ones the commit
has: the Swift reducers before step B, the Rust hover rules through the app FFI after. Each process prints

  hover-card sweep bench: macOS ..., 96000 pointer moves over 60 rows: p50 X ns, p95 Y ns, p99 Z ns, max W ns

Two routes to a fleet Mac:
  --arg via=lane     (default) scripts/ci/package-test-lane.sh suite, a light step at any commit, with
                     CMUX_SWIFT_SUITE_CONFIGURATION=release and CMUX_HOVER_SWEEP_BENCH=1. It links the FFI release
                     the commit pins, so a commit whose Swift needs an unreleased FFI change does not build here.
  --arg via=measure  scripts/measure/hover-sweep.sh at the feat-cmux-next tip (`--arg ref=SHA` another reviewed
                     commit), alone on an exclusive worker, measuring --build in a scratch worktree with today's
                     harness. `--arg ffi=source` builds the app FFI from the commit's Rust sources first. The
                     controller runs an unlisted scripts/measure script only at a commit on feat-cmux-next or main,
                     so this route works once hover-sweep.sh has landed there.

Rows: pointer_move_p50, pointer_move_p95, pointer_move_p99, pointer_move_max (us, lower; the test prints ns), one sample per test
process (value = the median process); moves (count, none). Before and after are two runs at two commits:

  cmux-bench hover-sweep --host fleet --build <before sha>
  cmux-bench hover-sweep --host fleet --build <after sha> [--arg worker=<the first run's worker>]
  cmux-bench compare <before run> <after run> --markdown

  --arg runs=N       test processes (default 5)

`--import LOG` reads a step log with those lines (either route).
"""
from __future__ import annotations

import re
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

LANE = "scripts/ci/package-test-lane.sh"
PACKAGE = "Packages/macOS/CmuxNext"
SUITE = "HoverCardSweepBench"
LINE = re.compile(r"hover-card sweep bench:.*?(\d+) pointer moves over (\d+) rows: p50 (\d+) ns, "
                  r"p95 (\d+) ns, p99 (\d+) ns, max (\d+) ns")
HOST = re.compile(r'HS host (\S+) chip="([^"]*)" macOS (\S+)')
QUANTILES = ("p50", "p95", "p99", "max")


class HoverSweep(Bench):
    name = "hover-sweep"
    summary = "Hover rules per pointer move (us): a 60-row sidebar sweep through HoverCardMachine, release build"
    units = "us"
    owner = "hover rules in Rust (B8 step B)"
    hosts = ("fleet",)
    harness = "scripts/measure/hover-sweep.sh"
    version = "1"
    floors = {f"pointer_move_{q}": 0.05 for q in QUANTILES}  # 50 ns

    def run(self, ctx: Context) -> None:
        ref = ctx.build.get("sha") if ctx.build.get("channel") == "sha" else None
        if not ref:
            raise BenchError("hover-sweep: pass --build <sha>, the commit whose hover rules to measure")
        runs = int(ctx.arg("runs") or 5)
        via = ctx.arg("via") or ("measure" if ctx.arg("ffi") == "source" else "lane")
        if via == "lane":
            res = ctx.fleet_step(LANE, ["suite", PACKAGE] + [SUITE] * runs, None, step_class="light", labels=(),
                                 timeout=5400, ref=ref,
                                 env={"CMUX_SWIFT_SUITE_CONFIGURATION": "release", "CMUX_HOVER_SWEEP_BENCH": "1"})
            ctx.notes.append(f"via lane ({LANE} suite, light step, release, pinned FFI)")
        elif via == "measure":
            args = [f"sha={ref}", f"ffi={ctx.arg('ffi') or 'pinned'}", f"runs={runs}"]
            # ref None: the step runs at the feat-cmux-next tip (fleet_step's default, or --arg ref=).
            res = ctx.fleet_step(self.harness, args, None, step_class="exclusive", labels=("measure",),
                                 timeout=5400)
            ctx.notes.append(f"via measure ({self.harness}, exclusive, ffi={ctx.arg('ffi') or 'pinned'})")
        else:
            raise BenchError(f"hover-sweep: --arg via={via}: expected lane or measure")
        self.ingest(ctx, res.log_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        runs = list(dict.fromkeys(m.group(0) for m in LINE.finditer(text)))
        runs = [LINE.search(r).groups() for r in runs]
        if not runs:
            raise BenchError(f"hover-sweep: no 'hover-card sweep bench:' line in {path}")
        host = HOST.search(text)
        if host:
            ctx.host.update({"chip": host.group(2), "os": f"macOS {host.group(3)}"})
            if ctx.host.get("name") in (None, "", "fleet"):
                ctx.host["name"] = host.group(1)
        for i, q in enumerate(QUANTILES):
            ctx.row(f"pointer_move_{q}", unit="us", samples=[int(r[2 + i]) / 1000.0 for r in runs])
        ctx.row("moves", float(runs[0][0]), "count", better="none")


BENCH = HoverSweep()

"""launch-premain: time to `main` of a launch after a 60 s full run, next to one after a short launch (CMUX-629).

The launch bench's mode=premain (scripts/measure/launch-premain.sh), registered on its own so the nightly measures the
case a back-to-back relaunch never shows: a launch about 60 s after a full run began reached `main` in 600 to 1170 ms
against 30 to 80 ms. The nightly runs arms h (short launch, then B), a (60 s run, then B) and k (short launch, a hard
link made and removed, then B; cmux#44204's XProtect rescan) at 3 reps, about 6 minutes on a fleet Mac. Rows as the
launch bench's mode=premain: main_start, pageins, CPU, residency and pages_touched per arm.

  --arg arms=h,a,b,c,g,d,k,e,e2,x,f   every arm (about 55 minutes at 5 reps); --arg reps=N
"""
from __future__ import annotations

from pathlib import Path

from benchlib.bench import Context

from benches.launch import PREMAIN, Launch


class LaunchPremain(Launch):
    name = "launch-premain"
    summary = "Time to main after a 60 s full run vs after a short launch (pre-main cost, per arm)"
    units = "ms, count, %"
    harness = PREMAIN
    version = "1"
    thresholds = {"failed_launches": 0.0}
    floors = {"failed_launches": 0.0}
    nightly = True
    nightly_args = {"arms": "h,a,k", "reps": "3"}

    def run(self, ctx: Context) -> None:
        ctx.args.setdefault("mode", "premain")
        super().run(ctx)

    def ingest(self, ctx: Context, path: Path) -> None:
        self.ingest_premain(ctx, path)


BENCH = LaunchPremain()

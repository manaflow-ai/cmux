"""typing: composer typing under load in the agent chat pane, Chromium and WebKit, on Linux.

Wraps webviews/bench/composer-typing.bench.ts in its load modes (CMUX-571; Leo 2026-11-16: "but typing under load is
not good enough"): the real pane against the in-page mock daemon, `keys` letters `gap_ms` apart typed into the
composer under each load:
  L0  idle
  L1  a focused reply and tool stream (60 chunks and 2,000 tool lines per second)
  L2  ten other streaming documents (five visible, five hidden iframes; not native tabs or processes)
  L3  a focused 100k-row stream
Every load ends explicitly or at its 120 s safety deadline. The bench prints one `COMPOSER-TYPING [...]` line, a
JSON array with one object per engine and load, which `ingest` reads.

Rows (labels: engine, load, transcript_rows):
  valid (count, higher): 1 when the load's receipt holds (exact ordered keys and final text, the stream's rate and
    continuity, the input cadence, clocks within 2 ms). An invalid load keeps its errors as notes and gets no timing
    row, so a broken run never reads as a fast one.
  target_met (count, higher): valid, at least 200 keys, paint p95 <= 16 ms and p99 <= 33 ms (report-only budgets).
  keydown_to_paint, keydown_to_frame (ms, samples): DOM keydown to the after-frame paint proxy and to the next frame.
  keydown_to_paint_p95_ms, keydown_to_paint_p99_ms (ms): the bench's own percentiles.
  frames_over_16ms (count). The browser clock starts at DOM keydown: these rows cannot certify native admission or
  physical presentation (the native Mac harness's job).

perf-cron.py's web-ui-typing part runs the same bench through web-ui-suite.ts (rows webui.composer_typing.*, the
targets above, advisory: the cron files an issue, it gates nothing).

Run: `cmux-bench typing --build SHA [--arg modes=L0,L1] [--arg engines=chromium] [--arg keys=500] [--arg gap_ms=20]`
sends the bench through `cmux-ci test --setup playwright` (Linux, at the caller's open PR head on a lane VM) and
reads the log it writes to $FAST_CHECKS_OUT. `--import LOG` reads a saved log (a GitHub Actions log is fine).
"""
from __future__ import annotations

import json
import math
import re
import shlex
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "webviews/bench/composer-typing.bench.ts"
LOG = "composer-typing.log"
DEFAULTS = {"modes": "L0,L1,L2,L3", "engines": "chromium,webkit", "lengths": "60", "keys": "500", "gap_ms": "20"}
# A GitHub Actions log prefixes each line with its time.
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ")
LINE = re.compile(r"COMPOSER-TYPING (\[.*\])\s*$")


def _finite(value) -> bool:
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


class Typing(Bench):
    name = "typing"
    summary = "Composer keydown-to-paint p95/p99 and key integrity under idle, stream, 10-doc and 100k-row loads (web)"
    units = "ms, count"
    owner = "typing-under-load (CMUX-571)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    floors = {"keydown_to_paint": 1.0, "keydown_to_frame": 1.0, "keydown_to_paint_p95_ms": 1.0,
              "keydown_to_paint_p99_ms": 2.0, "frames_over_16ms": 2.0}

    def command(self, ctx: Context) -> list[str]:
        opt = {k: ctx.arg(k) or v for k, v in DEFAULTS.items()}
        bench = ["bun", "bench/composer-typing.bench.ts", "--mode", opt["modes"], "--engines", opt["engines"],
                 "--lengths", opt["lengths"], "--keys", opt["keys"], "--gap", opt["gap_ms"]]
        script = (f"set -o pipefail; cd webviews && bun install --frozen-lockfile && {shlex.join(bench)} 2>&1"
                  f' | tee "${{FAST_CHECKS_OUT:-/tmp}}/{LOG}"')
        return ["cmux-ci", "test", "--setup", "playwright", "--timeout", str(ctx.arg("timeout") or 2400),
                "--artifact", str(ctx.workdir / "artifact"), "--", "bash", "-c", script]

    def run(self, ctx: Context) -> None:
        cmd = self.command(ctx)
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        log = ctx.workdir / LOG
        with log.open("w", encoding="utf-8") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, check=False)
        full = ctx.workdir / "artifact" / LOG
        ctx.host.update({"name": "linux-ci", "os": "Linux"})
        self.ingest(ctx, full if full.exists() else log)

    def ingest(self, ctx: Context, path: Path) -> None:
        table = None
        for raw in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            if m := LINE.search(STAMP.sub("", raw.strip())):
                try:
                    table = json.loads(m.group(1))
                except json.JSONDecodeError:
                    continue
        if not isinstance(table, list):
            raise BenchError(f"{path}: no COMPOSER-TYPING line (not a composer-typing.bench.ts log?)")
        loads = [r for r in table if isinstance(r, dict) and isinstance(r.get("valid"), bool)]
        if not loads:
            raise BenchError("typing: the run has no load-mode result (pass --mode L0..L3, not idle/stream)")
        for r in loads:
            labels = {"engine": str(r.get("engine", "chromium")), "load": str(r.get("mode")),
                      "transcript_rows": str(r.get("requested_rows"))}
            ctx.row("valid", int(r["valid"]), "count", better="higher", labels=labels)
            ctx.row("target_met", int(r.get("target_met") is True), "count", better="higher", labels=labels)
            if not r["valid"]:
                ctx.notes.append(f"{labels['engine']}/{labels['load']}: invalid; {'; '.join(map(str, r.get('errors') or []))}")
                continue
            samples = r.get("samples") if isinstance(r.get("samples"), list) else []
            for stage in ("paint", "frame"):
                xs = [s.get(stage) for s in samples if isinstance(s, dict)]
                if not xs or not all(_finite(x) for x in xs):
                    raise BenchError(f"typing: a valid {labels['engine']}/{labels['load']} has invalid {stage} samples")
                ctx.row(f"keydown_to_{stage}", samples=sorted(xs), labels=labels)
            for q in (95, 99):
                value = r.get(f"to_paint_p{q}")
                if not _finite(value):
                    raise BenchError(f"typing: a valid {labels['engine']}/{labels['load']} has no paint p{q}")
                ctx.row(f"keydown_to_paint_p{q}_ms", value, n=len(samples), labels=labels)
            if _finite(r.get("frames_over_16_ms")):
                ctx.row("frames_over_16ms", r["frames_over_16_ms"], "count", labels=labels)


BENCH = Typing()

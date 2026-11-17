"""transcript-replay: visible-row shifts and first paint of the agent chat transcript, over one scripted replay.

Wraps webviews/scripts/agent-pane/transcript-replay.bench.ts, the step 0 harness of cmuxterm-hq
docs/design/agent-transcript-clean-slate.md. It opens a chat of ROWS log records (default 50,000) on a synthetic
daemon in headless Chrome, streams at 60 tokens/s, pages up 3 times, streams scrolled up, folds and unfolds a tool
row 10 times and grows the composer, recording every visible row's top after every painted frame. It prints one
line, which `ingest` reads:

  BENCH {"bench": "transcript-replay", "small": {...}, "big": {"totals": {...}, "phases": {...}, ...}}

Rows (better = lower):
  row_shifts (count): rows that moved with no user act in the last 500 ms; labels phase (stream, page-up,
    scrolled, fold, composer-scrolled, composer-latest, open) and total.
  shift_frames (count), max_shift (px), input_jostle (count: rows that moved apart inside an act's window),
    scroll_writes (count: offset writes the ScrollController traced), same labels.
  first_paint (ms) and socket_to_paint (ms), labels rows (500, the run's count).
Run: `cmux-bench transcript-replay --build SHA` sends the harness through `cmux-ci test` (Linux, at the caller's
open PR head on a lane VM). `--import LOG` reads a saved log.
"""
from __future__ import annotations

import json
import re
import shlex
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "webviews/scripts/agent-pane/transcript-replay.bench.ts"
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ")
LINE = re.compile(r"^BENCH (\{.*\"bench\":\s*\"transcript-replay\".*\})$")
PHASE_METRICS = (("row_shifts", "rowShifts", "count"), ("shift_frames", "shiftFrames", "count"),
                 ("max_shift", "maxShiftPx", "px"), ("input_jostle", "inputJostleRows", "count"),
                 ("scroll_writes", "scrollWrites", "count"))


class TranscriptReplay(Bench):
    name = "transcript-replay"
    summary = "Agent chat transcript: visible-row shifts per scripted replay phase, and first paint at 500 and 50k rows"
    units = "count, px, ms"
    owner = "agent chat transcript (clean slate, step 0)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    floors = {"row_shifts": 1.0, "shift_frames": 1.0, "max_shift": 2.0, "input_jostle": 2.0, "scroll_writes": 5.0}

    def run(self, ctx: Context) -> None:
        rows = ctx.arg("rows") or "50000"
        command = ("set -o pipefail; cd webviews && bun scripts/pages/gen-strings.mjs --best-effort >/dev/null && "
                   f"CMUX_BROWSER_TESTS=1 ROWS={shlex.quote(rows)} bun scripts/agent-pane/transcript-replay.bench.ts")
        cmd = ["cmux-ci", "test", "--timeout", "1800", "--", "bash", "-c", command]
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        log = ctx.workdir / "transcript-replay.log"
        with log.open("w", encoding="utf-8") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, check=False)
        ctx.host.update({"name": "linux-ci", "os": "Linux"})
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        found = None
        for raw in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            match = LINE.match(STAMP.sub("", raw.strip()))
            if match:
                found = json.loads(match.group(1))
        if found is None:
            raise BenchError(f"transcript-replay: no BENCH line in {path}")
        for key in ("small", "big"):
            run = found.get(key) or {}
            labels = {"rows": str(run.get("rows"))}
            for metric, field in (("first_paint", "firstPaintMs"), ("socket_to_paint", "socketToPaintMs")):
                if run.get(field) is not None:
                    ctx.row(metric, run[field], "ms", labels=labels)
        big = found.get("big") or {}
        sections = {"total": big.get("totals") or {}, **(big.get("phases") or {})}
        for phase, counts in sections.items():
            for metric, field, unit in PHASE_METRICS:
                if field in counts:
                    ctx.row(metric, counts[field], unit, labels={"phase": phase})


BENCH = TranscriptReplay()

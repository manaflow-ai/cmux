"""terminal-throughput-quick: an installed cmux NEXT against Ghostty, MB/s each and NEXT/Ghostty (goal terminal-throughput).

scripts/measure/terminal-throughput-quick.sh on a shared fleet display Mac (`cmux-ci run --class isolated --display`,
no --measurement): the same 200 MB burst as the perf cron's `throughput` part, through the worker's installed NIGHTLY (a
side-instance copy) and Ghostty interleaved, NEXT then Ghostty per pair (the bench's --paired). The ratio row is the
median of the per-pair ratios and pair_spread_pct their spread (max - min over the median), so load on the host hits
both arms of a pair alike and cancels (paired A/B, as Chromium Pinpoint runs its pairs): a quiet, exclusive host buys the
ratio nothing, and as an exclusive measurement it queued for hours behind the others (2026-11-28: step ebe47e65, 150+
min behind 65 measurements). The exclusive per-commit path (terminal-throughput.sh) stays the confirm. With `--arg trace=1` the
first timed burst of each terminal runs under Instruments and the rows add the PTY reader's and the busiest
parse/render thread's running share (terminal_throughput_trace.stage_split), which says whether the PTY read loop or
the render path bounds the rate.

  scripts/bench/cmux-bench terminal-throughput-quick --host fleet [--arg trace=1] [--arg next=APP] [--arg mb=N]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

ARTIFACT = "artifacts/terminal-throughput-quick.json"
PASSED = ("next", "ghostty", "trace", "mb", "runs", "payload")
CMUX_NEXT = Path(__file__).resolve().parents[2] / "cmux-next"


class TerminalThroughputQuick(Bench):
    name = "terminal-throughput-quick"
    summary = "Terminal MB/s of an installed NEXT and Ghostty and their ratio; with trace=1 the PTY read/render split"
    units = "per_s (MB per second), x, %"
    owner = "terminal throughput (CMUX-571)"
    hosts = ("fleet",)
    harness = "scripts/measure/terminal-throughput-quick.sh"
    version = "1"
    thresholds = {"next_mb_s": 5.0, "ratio": 5.0}
    self_normalizing = True  # a paired NEXT/Ghostty ratio: never an exclusive measurement (fleet_step refuses one)

    def run(self, ctx: Context) -> None:
        args = ["artifact=1"] + [f"{k}={ctx.arg(k)}" for k in PASSED if ctx.arg(k)]
        res = ctx.fleet_step(self.harness, args, ARTIFACT, step_class="isolated", measurement=False, labels=(),
                             timeout=1800, display=True)
        if not res.artifact_path:
            raise BenchError(f"{self.name}: no report from job {res.job_id or '?'} (exit {res.exit_code}); "
                             f"see {res.log_path}")
        self.ingest(ctx, res.artifact_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        """terminal-throughput-bench.py's --json report: its rows, then the trace's split when it has one."""
        try:
            report = json.loads(Path(path).read_text())
        except (OSError, ValueError) as e:
            raise BenchError(f"{path}: not a terminal-throughput report ({e})") from e
        labels = {"payload": report.get("payload") or "?"}
        for r in report.get("rows", []):
            metric = r["name"].rsplit(".", 1)[1]
            if metric in ("next_mb_s", "ghostty_mb_s", "ratio"):
                # The schema has no MB/s: the *_mb_s rows are MB per second (per_s), the ratio x.
                ctx.row(metric, r.get("p50"), "x" if metric == "ratio" else "per_s", better="higher", labels=labels,
                        n=r.get("n"))
            elif metric == "pair_spread_pct":
                ctx.row(metric, r.get("p50"), "%", better="lower", labels=labels, n=r.get("n"))
        if str(CMUX_NEXT) not in sys.path:
            sys.path.insert(0, str(CMUX_NEXT))
        from terminal_throughput_trace import stage_split
        for terminal in ("next", "ghostty"):
            trace = (report.get(terminal) or {}).get("trace")
            if trace is None:
                continue
            split = stage_split(trace)
            for stage in ("pty_read", "render"):
                if stage in split:
                    ctx.row(f"{stage}_running_pct", split[stage]["running_pct"], "%", better="none",
                            labels={**labels, "terminal": terminal, "bound": split["bound"]})


BENCH = TerminalThroughputQuick()

"""claude-vs-acpmux: Claude Code in a terminal against Claude Code through acpmux and a cmux NEXT chat, real model.

Wraps scripts/measure/claude-vs-acpmux.py (cmux#57487: "some people said claude code is much faster on the terminal
than in acpmux for the cmux next GUI"). Same model, effort, prompt and folder per arm; each run is a new session's
first turn (label turn=cold) and a second prompt in it (turn=warm). Arms: stdio (Claude Code on the stream-json wire,
no acpmux), acpmux (headless, the daemon's event stamps), tui (the interactive TUI, its transcript's stamps), gui (a
running app's chat, the page polled) and mcp (a new chat's `cmux mcp serve` to its first `tools/list`, which Claude
Code waits for before its first turn). It prints a table and one line `ingest` reads:

  CLAUDE-VS-ACPMUX {"bench": "claude-vs-acpmux", "rows": [{"arm", "turn", "run", <metric>: ms, ...}], ...}

Rows (label arm, turn; ms and lower is better unless said): spawn, start_wait, first_token, daemon_first_token,
first_block, first_tool, tool_rt, model_after_tool, total, initialize, first_list; throughput (per_s: characters per second,
higher); cpu_s, daemon_cpu_s (s); rss_mb (MB).

It runs real model turns and starts sessions in this Mac's acpmux, so it is a person's local run, not a fleet one:
`cmux-bench claude-vs-acpmux --host anywhere [--arg arms=stdio,acpmux,mcp] [--arg runs=5]`; `--import LOG` reads a saved
log. The harness's own `--guard` holds the regression limits (its GUARDS).
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/claude-vs-acpmux.py"
MARK = "CLAUDE-VS-ACPMUX "
UNITS = {"throughput": ("per_s", "higher"), "cpu_s": ("s", "lower"), "daemon_cpu_s": ("s", "lower"),
         "rss_mb": ("MB", "lower")}
METRICS = ("spawn", "start_wait", "first_token", "daemon_first_token", "first_block", "first_tool", "tool_rt",
           "model_after_tool", "throughput", "total", "cpu_s", "daemon_cpu_s", "rss_mb", "initialize", "first_list")
PASS_THROUGH = ("arms", "runs", "mcp_runs", "model", "effort", "harness", "app_socket", "acpmux_bin")


def report(text: str) -> dict | None:
    found = None
    for line in text.splitlines():
        at = line.find(MARK)
        if at >= 0:
            try:
                found = json.loads(line[at + len(MARK):])
            except json.JSONDecodeError:
                pass
    return found if isinstance(found, dict) else None


class ClaudeVsAcpmux(Bench):
    name = "claude-vs-acpmux"
    summary = "Claude Code in a terminal vs through acpmux vs a cmux NEXT chat, real model: each stage, cold and warm"
    units = "ms, per_s, s, MB"
    owner = "agent path (acpmux), cmux#57487"
    hosts = ("anywhere",)
    harness = HARNESS
    version = "1"
    nightly = False

    def run(self, ctx: Context) -> None:
        root = Path(__file__).resolve().parents[3]
        cmd = [sys.executable, "-I", str(root / HARNESS)]
        for key in PASS_THROUGH:
            if ctx.arg(key):
                cmd += [f"--{key.replace('_', '-')}", ctx.arg(key)]
        log = ctx.workdir / "claude-vs-acpmux.log"
        got = subprocess.run(cmd, capture_output=True, text=True, timeout=7200)
        log.write_text(got.stdout + got.stderr, encoding="utf-8")
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        found = report(Path(path).read_text(encoding="utf-8", errors="replace"))
        if found is None:
            raise BenchError(f"claude-vs-acpmux: no {MARK.strip()} line in {path}")
        samples: dict[tuple[str, str, str], list[float]] = {}
        for row in found.get("rows") or []:
            for metric in METRICS:
                if isinstance(row.get(metric), (int, float)):
                    samples.setdefault((row["arm"], row["turn"], metric), []).append(float(row[metric]))
        if not samples:
            raise BenchError("claude-vs-acpmux: the run measured no turn")
        for (arm, turn, metric), values in sorted(samples.items()):
            unit, better = UNITS.get(metric, ("ms", "lower"))
            ctx.row(metric, unit=unit, samples=values, better=better, labels={"arm": arm, "turn": turn})


BENCH = ClaudeVsAcpmux()

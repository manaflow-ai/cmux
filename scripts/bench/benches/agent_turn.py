"""agent-turn: what our agent path costs one turn when the model costs nothing, by stage, on Linux.

Wraps the acpmux bench `cmux-tui/crates/acpmux/benches/turn_overhead.rs` (Leo, 2026-11-19, on a published harness
bench: a mock model over a 100-turn session). It starts a real `acpmux daemon run`, a Claude Code stand-in that
answers each prompt at once, and the chat pane's client core on the daemon's v2 chat surface, then times every turn.
It prints a Markdown table and one line that `ingest` reads:

  AGENT-TURN {"bench": "agent_turn", "rows": [{"metric": "send", "unit": "us", "n": 100, "p50": .., "p95": ..,
              "samples": [..]}, ...], "env": {...}}

Rows (ms, better = lower; the bench's module text defines each): send, harness, store, deliver, render, turn, shown.

Run: `cmux-bench agent-turn [--arg turns=100]` sends the bench through `cmux-ci test` (Linux, at the caller's open PR
head on a lane VM) and reads the log. `--import LOG` reads a run's log (a CI job's log works: its time stamps are
skipped).
"""
from __future__ import annotations

import json
import re
import shlex
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "cmux-tui/crates/acpmux/benches/turn_overhead.rs"
# A GitHub Actions log prefixes each line with its time.
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ")
LINE = re.compile(r"^AGENT-TURN (\{.*\})$")


class AgentTurn(Bench):
    name = "agent-turn"
    summary = "One agent turn through acpmux with a stand-in model that answers at once: median and p95 by stage"
    units = "ms"
    owner = "agent path (acpmux)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    thresholds = {"turn": 10.0, "shown": 10.0}
    floors = {"send": 0.2, "harness": 0.2, "store": 0.2, "deliver": 0.2, "render": 0.2, "turn": 0.5, "shown": 0.5}

    def run(self, ctx: Context) -> None:
        turns = ctx.arg("turns") or "100"
        if not turns.isdigit():
            raise BenchError(f"agent-turn: turns={turns} is not a count")
        out = ctx.workdir / "artifact"
        command = (
            "set -o pipefail; cd cmux-tui && cargo bench --locked -p acpmux --bench turn_overhead -- "
            f"--turns {turns} | tee \"$FAST_CHECKS_OUT/agent-turn.log\""
        )
        cmd = ["cmux-ci", "test", "--timeout", "3600", "--artifact", str(out), "--", "bash", "-c", command]
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        log = ctx.workdir / "agent-turn.log"
        with log.open("w", encoding="utf-8") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, check=False)
        full = out / "agent-turn.log"
        ctx.host.update({"name": "linux-ci", "os": "Linux"})
        self.ingest(ctx, full if full.exists() else log)

    def ingest(self, ctx: Context, path: Path) -> None:
        report = None
        for raw in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            if m := LINE.match(STAMP.sub("", raw.strip())):
                report = json.loads(m.group(1))
        if report is None:
            raise BenchError(f"agent-turn: no AGENT-TURN line in {path}")
        for row in report["rows"]:
            samples = [us / 1000.0 for us in row["samples"]]
            ctx.row(row["metric"], unit="ms", samples=samples)


BENCH = AgentTurn()

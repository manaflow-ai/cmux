"""ask-card-wait: how long an agent's wrap-up card waits before the chat draws it.

Wraps webviews/scripts/agent-pane/ask-card-wait.harness.ts, which reads acpmux session event logs
(~/.acpmux/sessions, or --arg sessions=DIR) and, for each wrap-up call that returned, shapes the running
turn as the pane does at that moment (turns.ts `turnView`). A card drawn then waited 0 ms; otherwise it
waited until the turn's turn_end. It prints one line:

  ASK-CARD-WAIT n=N p50_ms=X p90_ms=X p95_ms=X drawn_live=K

Rows: wait (ms, p50 as value with p95), drawn_live (count of cards drawn the moment their call returned).
Runs anywhere with bun and the checkout's webviews dependencies; it reads the logs, never writes them.
Leo, 2026-11-19, on the Needs your input cards: "plus it's not instant yet".
"""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context

HARNESS = "webviews/scripts/agent-pane/ask-card-wait.harness.ts"
LINE = re.compile(r"^ASK-CARD-WAIT (.*)$")
FIELD = re.compile(r"(\w+)=(\S+)")


def _num(value: str | None) -> float | None:
    try:
        return float(value) if value is not None else None
    except ValueError:  # None
        return None


class AskCardWait(Bench):
    name = "ask-card-wait"
    summary = "Wait from an agent's wrap-up call returning to its card in the chat, replayed from acpmux logs"
    units = "ms, count"
    owner = "needs-input-card-polish (ask-114ecd8bd9)"
    hosts = ("anywhere",)
    harness = HARNESS
    version = "1"
    floors = {"wait": 16.0}

    def run(self, ctx: Context) -> None:
        cmd = ["bun", str(REPO_ROOT / HARNESS)]
        if ctx.arg("sessions"):
            cmd.append(str(ctx.arg("sessions")))
        got = subprocess.run(cmd, cwd=REPO_ROOT / "webviews", text=True, capture_output=True, timeout=1800)
        if got.returncode != 0:
            raise BenchError(f"ask-card-wait: harness failed: {got.stderr.strip()[-500:]}")
        out = ctx.workdir / "ask-card-wait.log"
        out.write_text(got.stdout)
        self.ingest(ctx, out)

    def ingest(self, ctx: Context, path: Path) -> None:
        lines = [m for ln in Path(path).read_text(errors="replace").splitlines() if (m := LINE.match(ln.strip()))]
        if not lines:
            raise BenchError(f"ask-card-wait: {path}: no ASK-CARD-WAIT line")
        fields = dict(FIELD.findall(lines[-1].group(1)))
        n = int(fields.get("n", "0"))
        p50, p95 = _num(fields.get("p50_ms")), _num(fields.get("p95_ms"))
        ctx.row("wait", p50, "ms", p50=p50, p95=p95, n=n)
        ctx.row("drawn_live", _num(fields.get("drawn_live")), "count", better="higher", n=n)


BENCH = AskCardWait()

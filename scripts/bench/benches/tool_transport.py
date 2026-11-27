"""tool-transport: what batching, gateway keep-alive and read prefetch could save on agent tool calls.

Wraps scripts/measure/tool-transport.py on this host (read-only: Claude Code transcripts under ~/.claude/projects,
and refused loopback requests to the acpmux MCP gateway). It prints one line, which `ingest` reads:

  BENCH {"bench": "tool-transport", "transcripts": {...}, "gateway": {...}}

Rows:
  calls_per_step (count), calls_in_multi_call_steps (%): tool calls the model already sends together.
  think (ms, p50/p95 as p50/p90): model time from a tool result to its next step.
  tool_exec (ms), label tool: call-to-result time per tool.
  read_named_in_previous_result (%): the best case for prefetching the next Read.
  gateway_fresh_request (us), gateway_connect (us): one loopback request on a new connection, and the connect
    alone, what HTTP keep-alive would save per call.
Run: `cmux-bench tool-transport --host local-readonly`; `--import LOG` reads a saved log.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/tool-transport.py"
LINE = re.compile(r"BENCH (\{.*\"bench\":\s*\"tool-transport\".*\})\s*$")


class ToolTransport(Bench):
    name = "tool-transport"
    summary = "Agent tool calls over acpmux: calls per model step, tool vs think time, prefetch hit, gateway reconnect cost"
    units = "count, %, ms, us"
    owner = "acpmux tool transport (Leo 2026-11-25 04:31Z)"
    hosts = ("local-readonly", "anywhere")
    harness = HARNESS
    version = "1"
    nightly = False

    def run(self, ctx: Context) -> None:
        root = Path(__file__).resolve().parents[3]
        cmd = [sys.executable, "-I", str(root / HARNESS), "--transcripts", ctx.arg("transcripts") or "400",
               "--requests", ctx.arg("requests") or "300"]
        log = ctx.workdir / "tool-transport.log"
        got = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
        log.write_text(got.stdout + got.stderr, encoding="utf-8")
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        found = None
        for raw in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            match = LINE.search(raw.strip())
            if match:
                found = json.loads(match.group(1))
        if found is None:
            raise BenchError(f"tool-transport: no BENCH line in {path}")
        tx = found.get("transcripts") or {}
        if not tx.get("steps"):
            raise BenchError("tool-transport: no tool steps in the transcripts read")
        ctx.row("calls_per_step", tx["calls_per_step"], "count", better="higher")
        ctx.row("calls_in_multi_call_steps", tx["calls_in_multi_call_steps_pct"], "%", better="higher")
        ctx.row("think", tx.get("think_p50_ms"), "ms", p50=tx.get("think_p50_ms"), p95=tx.get("think_p90_ms"))
        for tool, stats in (tx.get("tools") or {}).items():
            ctx.row("tool_exec", stats.get("p50_ms"), "ms", p50=stats.get("p50_ms"), p95=stats.get("p90_ms"),
                    n=stats.get("n"), labels={"tool": tool})
        ctx.row("read_named_in_previous_result", tx.get("read_named_in_previous_result_pct"), "%",
                better="higher", n=tx.get("reads"))
        gw = found.get("gateway") or {}
        if "error" not in gw:
            ctx.row("gateway_fresh_request", gw.get("fresh_request_p50_us"), "us", p50=gw.get("fresh_request_p50_us"),
                    p95=gw.get("fresh_request_p90_us"), n=gw.get("requests"))
            ctx.row("gateway_connect", gw.get("connect_p50_us"), "us", p50=gw.get("connect_p50_us"),
                    p95=gw.get("connect_p90_us"), n=gw.get("requests"))


BENCH = ToolTransport()

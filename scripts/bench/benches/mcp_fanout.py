"""mcp-fanout: MCP tool-server processes, RSS and idle CPU per kind at N open agent chats.

Wraps scripts/measure/mcp-fanout.sh (scripts/measure/mcp-fanout.py): per harness (Claude Code, Codex) and N open
chats, an isolated acpmux daemon from the build's own Contents/Resources/bin, the stand-in model, one cmux tool
call per Claude chat, then `ps` over a window. It prints one line per (harness, N, phase, kind):

  MCP-FANOUT row harness=H n=N phase=awake|idleS kind=K count=C rss_mb=R cpu_pct=X|None window_s=W

Rows (better = lower), labels harness, count (N), phase, kind (cmux-mcp-serve, acpmux-tools-mcp, acpmux-forum-mcp,
..., cmux-cua, agent-host, bg-run, claude, codex, TOTAL-tool-servers): processes (count), rss (MB), cpu (%).
first_call (ms), labels harness, count, chat (fresh, idle): the p50 time from a chat's first cmux tool call to its
result (MCP-FANOUT-CALL lines).

The build is the published app itself: --build nightly measures the newest NIGHTLY DMG (app=nightly); any other
build needs --arg app=https://...dmg. Harness args pass through: --arg counts=1,5 --arg harness=claude ...
"""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/mcp-fanout.sh"
PASS_THROUGH = ("app", "counts", "harness", "sample", "settle", "after_idle", "raw_at", "parallel", "claude", "codex",
                "tool")
FIELD = re.compile(r"(\w+)=(\S+)")
ROW = re.compile(r"^MCP-FANOUT row (.*)$")
CALL = re.compile(r"^MCP-FANOUT-CALL (.*)$")
MACHINE = re.compile(r"^MCP-FANOUT-MACHINE (.*)$")


def _num(fields: dict[str, str], key: str) -> float | None:
    try:
        return float(fields[key])
    except (KeyError, ValueError):  # missing or None
        return None


class McpFanout(Bench):
    name = "mcp-fanout"
    summary = "MCP tool-server processes, RSS and idle CPU per kind at N open agent chats of a cmux NEXT build"
    units = "count, MB, %, ms"
    owner = "nightly-mcp-fanout"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    thresholds = {"cpu": 50.0, "rss": 15.0, "first_call": 25.0}
    nightly = False

    def harness_args(self, ctx: Context) -> list[str]:
        args = {k: v for k, v in ctx.args.items() if k in PASS_THROUGH}
        if "app" not in args:
            if ctx.build.get("channel") != "nightly":
                raise BenchError("mcp-fanout: measures a published app; pass --build nightly or --arg app=https://...dmg")
            args["app"] = "nightly"
        return [f"{k}={v}" for k, v in args.items()]

    def run(self, ctx: Context) -> None:
        res = ctx.fleet_step(self.harness, self.harness_args(ctx), None, step_class="exclusive", labels=("measure",),
                             timeout=5400)
        log = res.log_path
        if "MCP-FANOUT row" not in res.log and res.job_id:
            full = ctx.workdir / f"{res.job_id}.log"
            got = subprocess.run(["cmux-ci", "log", res.job_id, "--tail", "200000"], text=True, capture_output=True)
            if got.returncode == 0:
                full.write_text(got.stdout)
                log = full
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        found = 0
        for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            # A cmux-ci log may prefix each line; the marker starts the part we read.
            at = line.find("MCP-FANOUT")
            line = line[at:] if at >= 0 else line
            if m := MACHINE.match(line):
                f = dict(FIELD.findall(m.group(1)))
                if f.get("host"):
                    ctx.host.update({"name": f["host"], "role": "fleet"})
                if f.get("os"):
                    ctx.host["os"] = f["os"]
                continue
            if m := CALL.match(line):
                f = dict(FIELD.findall(m.group(1)))
                v = _num(f, "p50_ms")
                if v is not None:
                    ctx.row("first_call", v, "ms", labels={"harness": f.get("harness", "?"), "count": f.get("n", "?"),
                                                            "chat": f.get("tag", "?")})
                continue
            if m := ROW.match(line):
                f = dict(FIELD.findall(m.group(1)))
                labels = {"harness": f.get("harness", "?"), "count": f.get("n", "?"), "phase": f.get("phase", "?"),
                          "kind": f.get("kind", "?")}
                for metric, key, unit in (("processes", "count", "count"), ("rss", "rss_mb", "MB"),
                                          ("cpu", "cpu_pct", "%")):
                    v = _num(f, key)
                    if v is not None:
                        ctx.row(metric, v, unit, labels=labels)
                found += 1
        if not found:
            raise BenchError(f"{path}: no MCP-FANOUT row (not a mcp-fanout.sh log?)")


BENCH = McpFanout()

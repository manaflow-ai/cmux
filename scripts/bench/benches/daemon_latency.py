"""daemon-latency: bin/cmux's hot paths on Linux at two or more commits, from one harness on one runner.

Wraps scripts/measure/tui-idle-ram.sh with `runs=0 latency=1` (CMUX-570, a size change's runtime cost): it builds
each commit's release cmux-tui (the `cmux` binary) and acpmux bench on one runner, then in rounds whose commit order
alternates times
  - the daemon request path and the CLI: cmux-tui/scripts/bench-daemon-latency.py (ping, identify,
    list-workspaces, send, new-tab, 10 concurrent clients, `cmux` CLI end to end and with no socket) at 1 terminal
    ("small") and 50 workspaces / 200 terminals ("scale");
  - acpmux: a prompt's send to first token, cold (agent start + send) and warm (send), from
    cmux-tui/crates/acpmux/tests/start_under_load_bench.rs at no load (its stand-in agent).
Lines it reads:

  TUI-IDLE-AT <40-char sha> <subject>
  TUI-LATENCY <sha12> <round> PERF-DAEMON <scenario> <op> n=.. p50=.. p95=.. p99=.. max=..   (ms)
  TUI-ACPMUX <sha12> <round> (cold|warm) (...): idle p50 <ms> ms p95 <ms> ms | load ...

One run holds one commit, so `cmux-bench compare` matches the two sides row by row: the run's commit is
`--arg commit=PREFIX`, else its build's sha. Import the same log once per commit:
  cmux-bench daemon-latency --import LOG --build BASE --arg commit=BASE
  cmux-bench daemon-latency --import LOG --build HEAD --arg commit=HEAD
  cmux-bench compare <base run> <head run> --markdown

Rows, better = lower, the median over rounds of each round's number:
  <op> (us, label scenario): the round's p50; <op>.p95 (us): the round's p95.
  acpmux.cold, acpmux.warm (ms): idle p50; acpmux.cold.p95, acpmux.warm.p95 (ms): idle p95.

Run: `cmux-bench daemon-latency --build HEAD_SHA --arg commits=BASE_SHA,HEAD_SHA` sends the harness through
`cmux-ci test` (Linux, at the caller's open PR head on a lane VM) and records the head side; import the log it
keeps (the run's artifact tui-idle-ram.log) for the base side as above.
"""
from __future__ import annotations

import re
import shlex
import statistics
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context
from benches.tui_idle import STAMP, resolve

HARNESS = "scripts/measure/tui-idle-ram.sh"
PASS_THROUGH = ("latency_rounds", "latency_n", "latency_cli_n", "latency_scenarios", "acpmux", "acpmux_samples",
                "profile", "arenas")
AT = re.compile(r"^TUI-IDLE-AT ([0-9a-f]{40})\b")
LATENCY = re.compile(r"^TUI-LATENCY ([0-9a-f]{12}) (\d+) PERF-DAEMON (\S+) (\S+) n=(\d+) p50=([\d.]+) p95=([\d.]+)")
ACPMUX = re.compile(r"^TUI-ACPMUX ([0-9a-f]{12}) (\d+) (cold|warm) .*?idle p50 (\d+) ms p95 (\d+) ms")


class DaemonLatency(Bench):
    name = "daemon-latency"
    summary = "bin/cmux hot paths on Linux at commits: daemon requests, CLI end to end, acpmux send to first token"
    units = "us, ms"
    owner = "size (CMUX-570)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    # A sub-millisecond request: 50 us (the us floor) and 10 %. acpmux's lines are whole milliseconds.
    floors = {"acpmux.cold": 3.0, "acpmux.cold.p95": 5.0, "acpmux.warm": 2.0, "acpmux.warm.p95": 3.0}

    def run(self, ctx: Context) -> None:
        listed = [c for c in (ctx.arg("commits") or "").split(",") if c]
        if len(listed) < 2:
            raise BenchError("daemon-latency: name both sides (--arg commits=BASE,HEAD)")
        commits = [resolve(c) for c in listed]
        if not ctx.arg("commit"):
            ctx.args["commit"] = ctx.build.get("sha") or commits[-1]
        args = ["runs=0", "latency=1"] + [f"{k}={v}" for k, v in ctx.args.items() if k in PASS_THROUGH] + commits
        out = ctx.workdir / "artifact"
        command = (f"set -o pipefail; {{ exec 2>&1; {HARNESS} {shlex.join(args)}; }}"
                   ' | tee "$FAST_CHECKS_OUT/tui-idle-ram.log"')
        cmd = ["cmux-ci", "test", "--timeout", "9000", "--artifact", str(out), "--", "bash", "-c", command]
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        log = ctx.workdir / "tui-idle-ram.log"
        with log.open("w", encoding="utf-8") as f:
            result = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, check=False)
        if result.returncode:
            raise BenchError(f"daemon-latency failed ({result.returncode}); see {log} and {out}")
        full = out / "tui-idle-ram.log"
        ctx.host.update({"name": "linux-ci", "os": "Linux"})
        self.ingest(ctx, full if full.exists() else log)

    def ingest(self, ctx: Context, path: Path) -> None:
        want = (ctx.arg("commit") or ctx.build.get("sha") or "")[:12]
        if len(want) < 7:
            raise BenchError("daemon-latency: name the run's commit (--arg commit=PREFIX or --build SHA)")
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        commits: set[str] = set()
        ops: dict[tuple[str, str], list[tuple[float, float]]] = {}
        agent: dict[str, list[tuple[float, float]]] = {}
        for raw in text.splitlines():
            line = STAMP.sub("", raw.strip())
            if m := AT.match(line):
                commits.add(m.group(1)[:12])
            elif (m := LATENCY.match(line)) and m.group(1).startswith(want):
                ops.setdefault((m.group(3), m.group(4)), []).append((float(m.group(6)), float(m.group(7))))
            elif (m := ACPMUX.match(line)) and m.group(1).startswith(want):
                agent.setdefault(m.group(3), []).append((float(m.group(4)), float(m.group(5))))
        if not commits:
            raise BenchError(f"{path}: no TUI-IDLE-AT line (not a tui-idle-ram.sh log?)")
        if not any(c.startswith(want) for c in commits):
            raise BenchError(f"{path}: commit {want} is not in this log (it has {', '.join(sorted(commits))})")
        if not ops and not agent:
            raise BenchError(f"{path}: no TUI-LATENCY or TUI-ACPMUX line for {want} (run with latency=1)")
        for (scenario, op), rounds in sorted(ops.items()):
            labels = {"scenario": scenario}
            ctx.row(op, statistics.median(p50 for p50, _ in rounds) * 1000, "us", n=len(rounds), labels=labels)
            ctx.row(f"{op}.p95", statistics.median(p95 for _, p95 in rounds) * 1000, "us", n=len(rounds),
                    labels=labels)
        for kind, rounds in sorted(agent.items()):
            ctx.row(f"acpmux.{kind}", statistics.median(p50 for p50, _ in rounds), "ms", n=len(rounds))
            ctx.row(f"acpmux.{kind}.p95", statistics.median(p95 for _, p95 in rounds), "ms", n=len(rounds))
        if not agent:
            ctx.notes.append(f"daemon-latency: {want} has no acpmux rows (acpmux=0, or its bench failed)")


BENCH = DaemonLatency()

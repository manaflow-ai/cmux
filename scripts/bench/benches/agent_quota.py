"""agent-quota: GitHub calls and wall time real Claude Code agents spend waiting for one pull request's CI.

Wraps scripts/measure/agent-quota.sh: per arm (without: no cmux guidance; skill: the cmux-quota skill only;
shipped: the skill plus the first-turn guidance, as cmux sends it) and number of agents on one machine at once, it
runs headless Claude Code agents against a stand-in gh whose one check finishes after ci_seconds, and prints

  AGENT-QUOTA row arm=A agents=K trial=N calls=C wall_s=W correct=X/K

Rows (better = lower), labels arm, agents: github_calls (count, per trial), wall (s, per trial); and correct
(count, better = higher), the agents whose last reply said the checks passed.

It needs the claude CLI with a model login and an acpmux built from the checkout (pr-wait), so it runs where an
agent works: `cmux-bench agent-quota --arg acpmux=PATH` runs the harness here; `--import LOG` reads a run's lines.
Harness args pass through: --arg arms=without,shipped --arg agents=1,6 --arg trials=3 --arg ci_seconds=300.
"""
from __future__ import annotations

import re
import subprocess
from collections import defaultdict
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/agent-quota.sh"
PASS_THROUGH = ("arms", "agents", "trials", "ci_seconds", "model", "acpmux")
FIELD = re.compile(r"(\w+)=(\S+)")
ROW = re.compile(r"^AGENT-QUOTA row (.*)$")
MACHINE = re.compile(r"^AGENT-QUOTA-MACHINE (.*)$")


class AgentQuota(Bench):
    name = "agent-quota"
    summary = "GitHub calls and wall time Claude Code agents spend waiting on one PR's CI, with and without cmux's guidance"
    units = "count, s"
    owner = "agent quota guidance (cmux-quota skill, acpmux pr-wait)"
    hosts = ("anywhere",)
    harness = HARNESS
    version = "1"
    thresholds = {"github_calls": 25.0}
    nightly = False

    def run(self, ctx: Context) -> None:
        if "acpmux" not in ctx.args:
            raise BenchError("agent-quota: pass --arg acpmux=PATH, an acpmux built from this checkout")
        args = [f"{k}={v}" for k, v in ctx.args.items() if k in PASS_THROUGH]
        repo = Path(__file__).resolve().parents[3]
        log = ctx.workdir / "agent-quota.log"
        with log.open("w") as out:
            done = subprocess.run(["bash", str(repo / HARNESS), *args], stdout=out, stderr=subprocess.STDOUT)
        if done.returncode != 0:
            raise BenchError(f"agent-quota: {HARNESS} exited {done.returncode}; see {log}")
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        calls: dict[tuple[str, str], list[float]] = defaultdict(list)
        wall: dict[tuple[str, str], list[float]] = defaultdict(list)
        correct: dict[tuple[str, str], list[float]] = defaultdict(list)
        for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            at = line.find("AGENT-QUOTA")
            line = line[at:] if at >= 0 else line
            if m := MACHINE.match(line):
                f = dict(FIELD.findall(m.group(1)))
                if f.get("host"):
                    ctx.host["name"] = f["host"]
                continue
            if m := ROW.match(line):
                f = dict(FIELD.findall(m.group(1)))
                key = (f.get("arm", "?"), f.get("agents", "?"))
                try:
                    calls[key].append(float(f["calls"]))
                    wall[key].append(float(f["wall_s"]))
                    correct[key].append(float(f.get("correct", "0/0").split("/")[0]))
                except (KeyError, ValueError):
                    ctx.notes.append(f"agent-quota: unreadable row {line!r}")
        if not calls:
            raise BenchError(f"{path}: no AGENT-QUOTA row (not an agent-quota.sh log?)")
        for (arm, agents), samples in sorted(calls.items()):
            labels = {"arm": arm, "agents": agents}
            ctx.row("github_calls", unit="count", samples=samples, labels=labels)
            ctx.row("wall", unit="s", samples=wall[(arm, agents)], labels=labels)
            ctx.row("correct", unit="count", better="higher", samples=correct[(arm, agents)], labels=labels)


BENCH = AgentQuota()

"""cloud-turn: agent-turn with the chat crossing a real relay, as a chat on a Cloud machine does, on Linux.

The `--route relay` arm of the acpmux bench `cmux-tui/crates/acpmux/benches/turn_overhead.rs` (Leo, 2026-11-19: "for
cloud and remote and screenshare and general perf related stuf too we should go looky"). The same 100 turns as
agent-turn (a real `acpmux daemon run`, a Claude Code stand-in that answers at once, the chat pane's client core), but
both clients reach the daemon through the Cloud carrier's relay in process on loopback (cmux-relay, cmux-remote's relay
client, a Noise link to the machine's side), not its local socket. No network and no account. One run does both routes
from one binary, local first, so the two tables compare. Each prints one line that `ingest` reads:

  CLOUD-TURN {"bench": "cloud_turn", "route": "relay", "rows": [{"metric": "send", "unit": "us", "n": 100, "p50": ..,
              "p95": .., "samples": [..]}, ...], "env": {...}}

Rows (ms, better = lower; the bench's module text defines each), labeled `route=local|relay`: send, relay_in, harness,
store, relay_out, deliver, render, turn, shown (per turn), and attach_connect, attach_handshake, attach_first_frame (per
fresh pane attach). relay_in, relay_out and attach_handshake are on the relay route only.

Run: `cmux-bench cloud-turn [--arg turns=100] [--arg attaches=20]` sends the bench through `cmux-ci test` (Linux, at the
caller's open PR head on a lane VM) and reads the log. `--import LOG` reads a run's log (a CI job's log works: its
time stamps are skipped).
"""
from __future__ import annotations

import re
import shlex
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

from benches.agent_turn import read_lines

HARNESS = "cmux-tui/crates/acpmux/benches/turn_overhead.rs"
LINE = re.compile(r"^CLOUD-TURN (\{.*\})$")


class CloudTurn(Bench):
    name = "cloud-turn"
    summary = "One agent turn through a real relay (the Cloud carrier's) with a stand-in model, beside the local route: median and p95 by stage"
    units = "ms"
    owner = "agent path (acpmux)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    thresholds = {"turn": 10.0, "shown": 10.0}
    floors = {"send": 0.2, "relay_in": 0.2, "harness": 0.2, "store": 0.2, "relay_out": 0.2, "deliver": 0.2,
              "render": 0.2, "turn": 0.5, "shown": 0.5, "attach_connect": 0.5, "attach_handshake": 0.5,
              "attach_first_frame": 0.5}

    def run(self, ctx: Context) -> None:
        turns = ctx.arg("turns") or "100"
        attaches = ctx.arg("attaches") or "20"
        if not turns.isdigit() or not attaches.isdigit():
            raise BenchError(f"cloud-turn: turns={turns} attaches={attaches} are not counts")
        out = ctx.workdir / "artifact"
        bench = (
            "cargo bench --locked -p acpmux --features hub-carrier --bench turn_overhead -- "
            f"--turns {turns} --attaches {attaches}"
        )
        # One build, both routes back to back.
        command = (
            "set -o pipefail; cd cmux-tui && "
            f"{{ {bench} --route local && {bench} --route relay; }} | tee \"$FAST_CHECKS_OUT/cloud-turn.log\""
        )
        cmd = ["cmux-ci", "test", "--timeout", "3600", "--artifact", str(out), "--", "bash", "-c", command]
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        log = ctx.workdir / "cloud-turn.log"
        with log.open("w", encoding="utf-8") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, check=False)
        full = out / "cloud-turn.log"
        ctx.host.update({"name": "linux-ci", "os": "Linux"})
        self.ingest(ctx, full if full.exists() else log)

    def ingest(self, ctx: Context, path: Path) -> None:
        reports = read_lines(path, LINE)
        if not reports:
            raise BenchError(f"cloud-turn: no CLOUD-TURN line in {path}")
        # The last report of each route counts.
        by_route = {report.get("route", "local"): report for report in reports}
        for route, report in by_route.items():
            for row in report["rows"]:
                samples = [us / 1000.0 for us in row["samples"]]
                ctx.row(row["metric"], unit="ms", samples=samples, labels={"route": route})


BENCH = CloudTurn()

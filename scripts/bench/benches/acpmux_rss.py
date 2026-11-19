"""acpmux-rss: the acpmux daemon's resident memory under synthetic load, round by round, on Linux.

Wraps the manual Rust test `cmux-tui/crates/acpmux/tests/daemon_rss_growth.rs` (`#[ignore]`): it starts the
real daemon over a fixture home of 200 chats and drives rounds of `acpmux send --no-wait` to coordinators,
sends to a peer that is down, peer row changes, prompts and list reads (each knob an `ACPMUX_RSS_*`
variable; `--arg sends=20` sets `ACPMUX_RSS_SENDS=20`). Every line `ingest` reads starts with RSS-:

  RSS-CONFIG {"sends": .., "retries": .., "peerChanges": .., "prompts": .., "lists": .., ...}
  RSS-ROW <round> <rssMB> <hwmMB> <cpuS> <threads> <fds> <outboxN> <pending> <inboxN> <peerListsB> <ops> ...
  RSS-SLOPE {"mbPer1000OpsSecondHalf": .., "mbPer1000OpsWholeRun": .., ...}

Rows (label mix = the load components that ran, e.g. "sends" or "sends+retries"), better = lower:
  mb_per_1000_ops (MB): RSS growth per 1000 operations over the run's second half (past warm-up);
  mb_per_1000_ops_whole (MB): the same over the whole run;
  rss_end, rss_start (MB): RSS at the last and the first row; cpu_end (s): the daemon's CPU seconds at the end;
  threads_end, fds_end (count).

Run: `cmux-bench acpmux-rss --build local --arg sends=20 --arg rounds=200` sends the test through `cmux-ci test`
(Linux). `--import LOG` reads a run's output (`cargo test ... --test daemon_rss_growth -- --ignored --nocapture`).
"""
from __future__ import annotations

import json
import re
import shlex
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "cmux-tui/crates/acpmux/tests/daemon_rss_growth.rs"
# --arg name -> the harness's variable.
KNOBS = {"rounds": "ROUNDS", "every": "EVERY", "sends": "SENDS", "retries": "RETRIES",
         "peer_changes": "PEER_CHANGES", "prompts": "PROMPTS", "lists": "LISTS", "sessions": "SESSIONS",
         "coords": "COORDS", "bytes": "BYTES", "par": "PAR"}
MIX = (("sends", "sends"), ("retries", "retries"), ("peerChanges", "peers"), ("prompts", "prompts"),
       ("lists", "lists"))
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ")
CONFIG = re.compile(r"^RSS-CONFIG (\{.*\})$")
ROW = re.compile(r"^RSS-ROW (\d+) (\d+) (\d+) ([\d.]+) (\d+) (\d+)\b")
SLOPE = re.compile(r"^RSS-SLOPE (\{.*\})$")


class AcpmuxRss(Bench):
    name = "acpmux-rss"
    summary = "acpmux daemon RSS growth per 1000 operations under synthetic send/peer/prompt load (Linux)"
    units = "MB, s, count"
    owner = "acpmux"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    thresholds = {"mb_per_1000_ops": 20.0, "rss_end": 10.0}
    floors = {"mb_per_1000_ops": 5.0, "mb_per_1000_ops_whole": 5.0, "rss_end": 15.0, "rss_start": 15.0}

    def run(self, ctx: Context) -> None:
        env = [f"ACPMUX_RSS_{var}={ctx.arg(key)}" for key, var in KNOBS.items() if ctx.arg(key) is not None]
        test = "cargo test -j 6 --profile gate -p acpmux --test daemon_rss_growth -- --ignored --nocapture"
        command = f"cd cmux-tui && env {shlex.join(env)} {test}" if env else f"cd cmux-tui && {test}"
        cmd = ["cmux-ci", "test", "--timeout", "7200", "--", "bash", "-c", command]
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        log = ctx.workdir / "acpmux-rss.log"
        with log.open("w", encoding="utf-8") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, check=False)
        ctx.host.update({"name": "linux-ci", "os": "Linux"})
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        config: dict | None = None
        slope: dict | None = None
        rows: list[tuple[float, ...]] = []
        for raw in text.splitlines():
            line = STAMP.sub("", raw.strip())
            if m := CONFIG.match(line):
                config = json.loads(m.group(1))
            elif m := SLOPE.match(line):
                slope = json.loads(m.group(1))
            elif m := ROW.match(line):
                rows.append(tuple(float(g) for g in m.groups()))
        if config is None or not rows:
            raise BenchError(f"{path}: no RSS-CONFIG or RSS-ROW line (not a daemon_rss_growth log?)")
        mix = "+".join(name for key, name in MIX if config.get(key)) or "idle"
        labels = {"mix": mix}
        first, last = rows[0], rows[-1]
        ctx.row("rss_start", first[1], "MB", labels=labels)
        ctx.row("rss_end", last[1], "MB", labels=labels)
        ctx.row("cpu_end", last[3], "s", labels=labels)
        ctx.row("threads_end", last[4], "count", labels=labels)
        ctx.row("fds_end", last[5], "count", labels=labels)
        if slope is None:
            ctx.notes.append("acpmux-rss: no RSS-SLOPE line (the run ended early?)")
            return
        for metric, key in (("mb_per_1000_ops", "mbPer1000OpsSecondHalf"),
                            ("mb_per_1000_ops_whole", "mbPer1000OpsWholeRun")):
            if slope.get(key) is not None:
                ctx.row(metric, slope[key], "MB", labels=labels)


BENCH = AcpmuxRss()

"""tailnet-stable-node: one stable tailnet node ("cmux") in front of two VMs that move underneath it, on Linux.

Wraps scripts/bench/tailnet-stable-node.sh, which builds everything in a local headscale and tailscale rig (network
namespaces, one tailscaled per namespace, its own state; never a real tailnet) and prints one line
`TNSB-RUN {...}` (schema tailnet-stable-node-run.v1). `ingest` reads that line, from the log or a summary JSON.

Rows (labels: moves, variant where it applies), better = lower unless noted:
  connect_cmux_ms, connect_client_ms: `tailscale up` to Running, for the stable node and the client
  route_visible_ms: the subnet route approved in headscale to the client's route table
  derp_to_direct_ms: from the client's first ping to the path being direct (its final path is in labels)
  v1|v2 .tcp.rtt_ms: a line's echo round trip (p50, p95; p99 in labels)
  v1|v2 .tcp.resume_ms: a move to the first echo after it (p50, p95); .tcp.stall_ms: the last echo before a move
    to the first after it (p50, p95)
  v1|v2 .tcp.disconnects (count): client TCP sessions that broke (idle or eof) over the run
  v1 .udp.lost, v1 .udp.resume_ms, v1 .udp.stall_ms: the UDP stream across the VIP move
  v1|v2 .tcp.lost (count): sent lines with no echo, over the run
  tailnet_view_unchanged (1 or 0): the client's `tailscale status` peers, IPs and node keys before and after the moves

Run: `cmux-bench tailnet-stable-node [--arg moves=20]` sends the harness through `cmux-ci test --timeout 3600` (a Linux
CI runner, on a lane VM at the caller's open PR head). `--import PATH` reads a harness log or a summary JSON.
"""
from __future__ import annotations

import json
import re
import shlex
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/bench/tailnet-stable-node.sh"
SCHEMA = "tailnet-stable-node-run.v1"
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ")


def rows_of_summary(run: dict, ctx: Context) -> None:
    meta = run.get("meta") or {}
    labels = {"moves": meta.get("moves")}
    for key in ("connect_cmux_ms", "connect_client_ms", "route_visible_ms", "derp_to_direct_ms"):
        if isinstance(meta.get(key), (int, float)):
            lab = dict(labels)
            if key == "derp_to_direct_ms":
                lab["final_path"] = meta.get("final_path", "")
                lab["first_pong"] = meta.get("first_pong", "")
            ctx.row(key, meta[key], "ms", labels=lab)
    for variant in ("v1", "v2"):
        block = run.get(variant) or {}
        tcp = block.get("tcp") or {}
        vlab = dict(labels, variant=variant)
        rtt = tcp.get("rtt_ms") or {}
        if isinstance(rtt.get("p50"), (int, float)):
            ctx.row(f"{variant}.tcp.rtt_ms", rtt["p50"], "ms", p50=rtt["p50"], p95=rtt.get("p95"),
                    n=rtt.get("n"), labels=dict(vlab, p99_ms=rtt.get("p99")))
        _resume(ctx, f"{variant}.tcp", tcp, vlab)
        if isinstance(tcp.get("disconnects"), int):
            ctx.row(f"{variant}.tcp.disconnects", tcp["disconnects"], "count", labels=vlab)
        if isinstance(tcp.get("lost"), int):
            ctx.row(f"{variant}.tcp.lost", tcp["lost"], "count", labels=vlab)
        udp = block.get("udp") or {}
        if udp:
            _resume(ctx, f"{variant}.udp", udp, vlab)
            if isinstance(udp.get("lost"), int):
                ctx.row(f"{variant}.udp.lost", udp["lost"], "count", labels=vlab)
    if "tailnet_view_unchanged" in run:
        ctx.row("tailnet_view_unchanged", 1 if run["tailnet_view_unchanged"] else 0, "count", better="higher",
                labels=labels)


def _resume(ctx: Context, prefix: str, stats: dict, labels: dict) -> None:
    for key in ("resume_ms", "stall_ms"):
        d = stats.get(key) or {}
        if isinstance(d.get("p50"), (int, float)):
            ctx.row(f"{prefix}.{key}", d["p50"], "ms", p50=d["p50"], p95=d.get("p95"), n=d.get("n"), labels=labels)


class TailnetStableNode(Bench):
    name = "tailnet-stable-node"
    summary = "One stable tailnet node in front of VMs that move underneath it: connect, echo, reconnect, DERP->direct"
    units = "ms, count"
    owner = "tailnet carrier"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    thresholds = {"v1.tcp.resume_ms": 25.0, "v2.tcp.resume_ms": 25.0}
    floors = {"v1.tcp.disconnects": 0.5, "v2.tcp.disconnects": 0.5, "v1.tcp.lost": 0.5, "v2.tcp.lost": 0.5}

    def run(self, ctx: Context) -> None:
        moves = ctx.arg("moves", "20")
        out = ctx.workdir / "artifact"
        command = f"set -o pipefail; {HARNESS} {shlex.quote(moves)} {shlex.quote(str(out))}"
        cmd = ["cmux-ci", "test", "--timeout", "3600", "--artifact", str(out), "--", "bash", "-c", command]
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        log = ctx.workdir / "tailnet-stable-node.log"
        with log.open("w", encoding="utf-8") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, check=False)
        ctx.host.update({"name": "linux-ci", "os": "Linux"})
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        path = Path(path)
        if path.is_dir():
            path = path / "summary.json"
        text = path.read_text(encoding="utf-8", errors="replace")
        run = None
        try:
            whole = json.loads(text)
        except json.JSONDecodeError:
            whole = None
        if isinstance(whole, dict) and whole.get("schema") == SCHEMA:
            run = whole
        else:
            for raw in text.splitlines():
                line = STAMP.sub("", raw.strip())
                if line.startswith("TNSB-RUN "):
                    line = line[len("TNSB-RUN "):]
                if not line.startswith("{"):
                    continue
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(value, dict) and value.get("schema") == SCHEMA:
                    run = value
        if run is None:
            raise BenchError(f"{path}: no {SCHEMA} line (not a tailnet-stable-node.sh log?)")
        rows_of_summary(run, ctx)
        if not ctx.rows:
            ctx.notes.append("tailnet-stable-node: the run has no rows (did the harness finish?)")


BENCH = TailnetStableNode()

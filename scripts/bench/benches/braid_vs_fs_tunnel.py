"""braid-vs-fs-tunnel: one Cloud VM reached over the Freestyle Tunnel, the Freestyle ssh proxy, the tailnet and
Braid's rungs, with the same probes on each path, from one origin (a Mac, a phone on cellular, a lane VM).

Wraps scripts/measure/braid-vs-fs-tunnel.py, which prints one line `BVT-RUN {...}` (schema
braid-vs-fs-tunnel-run.v1). Rows (labels: origin, path), better = lower unless noted:
  PATH.cold_ms    fresh ssh connect + auth + one command (p50, p95)
  PATH.echo_ms    a line out and back through one held session: keystroke echo (p50, p95)
  PATH.fails      failed cold and echo runs (count; a failed run is counted, never dropped)
  PATH.up_mbps, PATH.down_mbps   bulk through the session (better = higher)

The origin must hold the path (the app's device tunnel socket, a tailnet, a proxy identity), so `run` happens on that
host, not in CI: `cmux-bench braid-vs-fs-tunnel --arg target=USER@VM --arg origin=mac --arg paths='NAME=PROXY;...'`.
`--import PATH` reads a harness log. Network-change, NAT and handoff rows for Braid's rungs come from netlab
(cmuxterm-hq docs/architecture/connectivity-harness/netlab routes.sh and h2h.sh) through `cmux-ci test --setup netem`.
"""
from __future__ import annotations

import json
import shlex
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/braid-vs-fs-tunnel.py"
SCHEMA = "braid-vs-fs-tunnel-run.v1"


def rows_of_run(run: dict, ctx: Context) -> None:
    origin = run.get("origin", "")
    for path, r in sorted((run.get("paths") or {}).items()):
        lab = {"origin": origin, "path": path}
        fails = 0
        for key in ("cold_ms", "echo_ms"):
            d = r.get(key) or {}
            fails += int(d.get("fails") or 0)
            if isinstance(d.get("p50"), (int, float)):
                ctx.row(f"{path}.{key}", d["p50"], "ms", p50=d["p50"], p95=d.get("p95"), n=d.get("n"), labels=lab)
        ctx.row(f"{path}.fails", fails, "count", labels=lab)
        for way, v in (r.get("bulk_mbps") or {}).items():
            if isinstance(v, (int, float)):
                ctx.row(f"{path}.{way}_mbps", v, "Mbit/s", better="higher", labels=lab)


class BraidVsFsTunnel(Bench):
    name = "braid-vs-fs-tunnel"
    summary = "A Cloud VM over the Freestyle Tunnel, its ssh proxy, the tailnet and Braid rungs: connect, echo, bulk"
    units = "ms, Mbit/s, count"
    owner = "ultra-connectivity"
    hosts = ("mac", "fleet")
    harness = HARNESS
    version = "1"
    thresholds = {"fs-tunnel.echo_ms": 25.0, "fs-tunnel.cold_ms": 25.0}
    floors = {"fs-tunnel.fails": 0.5}

    def run(self, ctx: Context) -> None:
        target = ctx.arg("target", "")
        if not target:
            raise BenchError("--arg target=USER@VM is required")
        cmd = ["python3", HARNESS, "--target", target, "--origin", ctx.arg("origin", "unlabeled"),
               "--n", ctx.arg("n", "20"), "--bulk-mb", ctx.arg("bulk_mb", "64")]
        for spec in filter(None, ctx.arg("paths", "fs-tunnel=;tailnet=").split(";")):
            cmd += ["--path", spec]
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        log = ctx.workdir / "braid-vs-fs-tunnel.log"
        with log.open("w", encoding="utf-8") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, check=False)
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        runs = []
        for raw in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if line.startswith("BVT-RUN "):
                line = line[len("BVT-RUN "):]
            if not line.startswith("{"):
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict) and value.get("schema") == SCHEMA:
                runs.append(value)
        if not runs:
            raise BenchError(f"{path}: no {SCHEMA} line (not a braid-vs-fs-tunnel.py log?)")
        for run in runs:
            rows_of_run(run, ctx)


BENCH = BraidVsFsTunnel()

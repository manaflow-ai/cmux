"""bytes-path: the cloud copy's bytes path, today's against the new one, per folder kind and network profile.

Wraps `cmux-bytes bench` (cmux-tui/crates/cmux-bytes), which reads each folder, encodes it the way today's copy does
(fs.write JSON lines, base64, a deflate probe, 8 MiB parts, one round trip each) and the new way (manifest first,
content-defined chunks, a codec chosen per chunk that never grows a payload, priority lanes, pipelined streams),
decodes every new payload on the receiver to check it, and replays both over modeled links. The codec CPU is real
(thread CPU time); the link is a model: lan 117 MB/s 1 ms, home-wifi 5 MB/s 25 ms 0.1 % loss, lossy 1.25 MB/s
80 ms 2 % loss, tailnet-xregion 25 MB/s 150 ms 0.05 % loss, TCP streams capped by window and Mathis.
It writes `now-bytes/v1` JSON (the file NOW's bytes section reads):

  {"schema": "now-bytes/v1", "params": {..}, "runs": 9, "rows": [{"folder", "scenario", "profile", "strategy",
   "raw_bytes", "wire_bytes", "first_turn_p50", "first_turn_p95", "synced_p50", "synced_p95", "cpu_send_s",
   "cpu_recv_s", "grown_bytes", "verify_failures", ...}]}

Rows (labels: folder, scenario cold|edit, profile, strategy today|new), better = lower:
  first_turn (s): until the agent can take its first turn (manifest plus hot files);
  synced (s): until the whole folder is there;
  wire_bytes (bytes); cpu_send / cpu_recv (s); grown_bytes (bytes: payload bytes past raw; must be 0 for new).

Run: `cmux-bench bytes-path --host anywhere --arg folders=FILE` (FILE: `NAME=PATH` lines) or
`--arg folder=NAME=PATH`, optional `--arg runs=9 --arg cap_bytes=268435456 --arg profile=lan`.
`--import latest.json` reads a run (the hill-climb timer writes ~/.cache/cmux-bytes/latest.json).
"""
from __future__ import annotations

import json
import shlex
import subprocess
from pathlib import Path

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context

HARNESS = "cmux-tui/crates/cmux-bytes/src/harness.rs"
PASS = {"runs": "--runs", "cap_bytes": "--cap-bytes", "profile": "--profile", "scenario": "--scenario"}


class BytesPath(Bench):
    name = "bytes-path"
    summary = "Cloud copy bytes path, today vs new: first turn, synced, wire bytes, CPU per folder kind and link"
    units = "s, bytes"
    owner = "cloud bytes (lane cloud-bytes-hillclimb)"
    hosts = ("anywhere",)
    harness = HARNESS
    version = "1"
    floors = {"first_turn": 0.01, "synced": 0.01, "cpu_send": 0.02, "cpu_recv": 0.02}

    def run(self, ctx: Context) -> None:
        out = ctx.workdir / "bytes-path.json"
        cmd = ["cargo", "run", "--quiet", "--release", "-p", "cmux-bytes", "--bin", "cmux-bytes", "--", "bench",
               "--json", str(out)]
        if ctx.arg("folders"):
            cmd += ["--folders-file", ctx.arg("folders")]
        elif ctx.arg("folder"):
            cmd += ["--folder", ctx.arg("folder")]
        else:
            raise BenchError("bytes-path: pass --arg folders=FILE (NAME=PATH lines) or --arg folder=NAME=PATH")
        for key, flag in PASS.items():
            if ctx.arg(key):
                cmd += [flag, ctx.arg(key)]
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        got = subprocess.run(cmd, cwd=REPO_ROOT / "cmux-tui", text=True, capture_output=True, timeout=7200,
                             check=False)
        if not out.exists():
            raise BenchError(f"bytes-path: harness failed ({got.returncode}): {got.stderr.strip()[-500:]}")
        if got.returncode:
            ctx.notes.append("bytes-path: a payload grew or failed to decode (cmux-bytes exited 1)")
        self.ingest(ctx, out)

    def ingest(self, ctx: Context, path: Path) -> None:
        try:
            doc = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise BenchError(f"bytes-path: {path}: expected cmux-bytes JSON: {exc}") from exc
        if doc.get("schema") != "now-bytes/v1" or not doc.get("rows"):
            raise BenchError(f"bytes-path: {path}: not a now-bytes/v1 file with rows")
        n = doc.get("runs")
        for r in doc["rows"]:
            labels = {k: r.get(k, "") for k in ("folder", "scenario", "profile", "strategy")}
            ctx.row("first_turn", r["first_turn_p50"], "s", p50=r["first_turn_p50"], p95=r["first_turn_p95"], n=n,
                    labels=labels)
            ctx.row("synced", r["synced_p50"], "s", p50=r["synced_p50"], p95=r["synced_p95"], n=n, labels=labels)
            ctx.row("wire_bytes", r["wire_bytes"], "bytes", labels=labels)
            ctx.row("cpu_send", r["cpu_send_s"], "s", labels=labels)
            ctx.row("cpu_recv", r["cpu_recv_s"], "s", labels=labels)
            ctx.row("grown_bytes", r.get("grown_bytes", 0), "bytes", labels=labels)
            if r.get("verify_failures"):
                ctx.notes.append(f"{labels}: {r['verify_failures']} payloads failed to decode")


BENCH = BytesPath()

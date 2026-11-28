"""fold-hosts: bytes, start time and idle memory of the programs bin/cmux runs by argv[0] (CMUX-570), base vs head.

Wraps scripts/measure/fold-hosts.sh: on one Linux runner it builds stripped release binaries of a base commit and of
the caller's PR head (bin/cmux, bin/cmux-tui-host, bin/cmux-agent-screen-detection, bin/cmux-cloud), lays each out as
the bundle does (the folded names become links to cmux), then samples both folders in turns (fold-hosts.py).

Rows (labels: side = base or head, program; better = lower):
  bytes (MB, label file): each regular file of bin/, a link counts 0; total (MB): their sum.
  start_ms (ms): `cmux-agent-screen-detection list`, the Cloud server's first line, `cmux-tui-host --version`,
    `cmux --version`.
  idle_rss_kb, idle_pss_kb, idle_pss_anon_kb, idle_private_dirty_kb (kB): the detector under a headless daemon, the
    Cloud server waiting on stdin, the terminal host of one terminal (`cmux-tui-host@full`: that host run from
    bin/cmux instead, the cost of folding it).

Run: `cmux-bench fold-hosts --build SHA [--arg base=SHA]` sends the harness through `cmux-ci test` (at the caller's
open PR head on a lane VM); `--import LOG` reads a run's fold-hosts.log.
"""
from __future__ import annotations

import json
import re
import shlex
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/fold-hosts.sh"
MB = 1024 * 1024
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ")
AT = re.compile(r"^FOLD-AT (base|head) ([0-9a-f]{40})\b")
SIZE = re.compile(r"^FOLD-SIZE (base|head) (\S+) (\d+|link)$")
TOTAL = re.compile(r"^FOLD-TOTAL (base|head) (\d+)$")
SAMPLE = re.compile(r"^FOLD-SAMPLE (\{.*\})$")


class FoldHosts(Bench):
    name = "fold-hosts"
    summary = "Bytes, start time and idle memory of the programs folded into bin/cmux, base vs head (Linux)"
    units = "MB, ms, kB"
    owner = "bundle size (CMUX-570)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    thresholds = {"start_ms": 10.0, "idle_rss_kb": 10.0, "total": 1.0}
    floors = {"start_ms": 1.0, "idle_rss_kb": 256, "idle_pss_kb": 256, "idle_pss_anon_kb": 128,
              "idle_private_dirty_kb": 128, "bytes": 0.05, "total": 0.05}

    def run(self, ctx: Context) -> None:
        args = [ctx.arg("base")] if ctx.arg("base") else []
        out = ctx.workdir / "artifact"
        command = f"set -o pipefail; {HARNESS} {shlex.join(args)}"
        cmd = ["cmux-ci", "test", "--timeout", "7200", "--artifact", str(out), "--", "bash", "-c", command]
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        log = ctx.workdir / "fold-hosts.log"
        with log.open("w", encoding="utf-8") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, check=False)
        full = out / "fold-hosts.log"
        ctx.host.update({"name": "linux-ci", "os": "Linux"})
        self.ingest(ctx, full if full.exists() else log)

    def ingest(self, ctx: Context, path: Path) -> None:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        samples: dict[tuple[str, str, str], list[float]] = {}
        found = 0
        for raw in text.splitlines():
            line = STAMP.sub("", raw.strip())
            if AT.match(line):
                found += 1
            elif m := SIZE.match(line):
                value = 0 if m.group(3) == "link" else int(m.group(3))
                ctx.row("bytes", value / MB, "MB", labels={"side": m.group(1), "file": m.group(2)})
            elif m := TOTAL.match(line):
                ctx.row("total", int(m.group(2)) / MB, "MB", labels={"side": m.group(1)})
            elif m := SAMPLE.match(line):
                try:
                    s = json.loads(m.group(1))
                except json.JSONDecodeError:
                    continue
                samples.setdefault((s["label"], s["program"], s["metric"]), []).append(s["value"])
        if found < 2:
            raise BenchError(f"{path}: fewer than two FOLD-AT lines (not a fold-hosts.sh log, or a build failed)")
        for (side, program, metric), values in samples.items():
            unit = "ms" if metric == "start_ms" else "kB"
            ctx.row(metric, unit=unit, samples=values, labels={"side": side, "program": program})


BENCH = FoldHosts()

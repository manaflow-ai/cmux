"""download-bridge: a big npm install on this host's own link, and the bytes a Mac gets per scheme (ask-70d77cbccc).

Wraps scripts/measure/download-bridge.sh: webviews/package.json's dependencies installed cold (empty npm cache,
--ignore-scripts) and again warm (same cache, fresh node_modules: what a host-shared cache buys the next VM).
Each round prints one `download-bridge: {...}` line.

Rows: install_s and warm_install_s (s), download_bytes, node_modules_bytes and lazy_read_bytes (bytes), with label
host_os. Bytes to the Mac by scheme: install on the Mac = download_bytes over its link; install on the VM and sync
back = node_modules_bytes; download bridge = 0 at install, then lazy_read_bytes (package.json and type
declarations) as the Mac reads them. `--host fleet` runs it on a fleet Mac; `--host anywhere` here.
`--arg rounds=2`.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context

HARNESS = "scripts/measure/download-bridge.sh"
PREFIX = "download-bridge: "
METRICS = (("install_s", "seconds", "s"), ("warm_install_s", "warmSeconds", "s"),
           ("download_bytes", "downloadBytes", "bytes"), ("node_modules_bytes", "nodeModulesBytes", "bytes"),
           ("lazy_read_bytes", "lazyReadBytes", "bytes"))


class DownloadBridge(Bench):
    name = "download-bridge"
    summary = "Cold and warm npm install of webviews' deps on this link; bytes a Mac gets per scheme"
    units = "s, bytes"
    owner = "cloud (ask-70d77cbccc)"
    hosts = ("fleet", "anywhere")
    harness = HARNESS
    version = "1"
    nightly = False

    def run(self, ctx: Context) -> None:
        args = [f"rounds={ctx.arg('rounds', '2')}"]
        if ctx.host_role == "fleet":
            res = ctx.fleet_step(self.harness, args, None, labels=("measure",), timeout=3600,
                                 ref=ctx.build.get("sha"))
            self.ingest(ctx, res.log_path)
            return
        if ctx.dry_run:
            raise BenchError("dry run")
        log = ctx.workdir / "download-bridge.log"
        got = subprocess.run([str(REPO_ROOT / HARNESS), *args], text=True, capture_output=True, timeout=3600)
        log.write_text(got.stdout + got.stderr, encoding="utf-8")
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        runs = []
        for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            at = line.find(PREFIX)
            if at < 0:
                continue
            try:
                runs.append(json.loads(line[at + len(PREFIX):]))
            except ValueError:
                continue
        if not runs:
            raise BenchError(f"{path}: no `{PREFIX.strip()}` line (not a download-bridge.sh log?)")
        labels = {"host_os": str(runs[0].get("os"))}
        for metric, key, unit in METRICS:
            ctx.row(metric, unit=unit, samples=[r[key] for r in runs if isinstance(r.get(key), (int, float))],
                    labels=labels)


BENCH = DownloadBridge()

"""desktop-link: time from Connect to a linked row in Settings > Agents > Your other apps.

Wraps scripts/measure/desktop-link-connect.py: in a scratch home where Claude desktop and Codex look installed,
the build's `cmux agent hook install link-<app>` (Connect) and the `agent hook status` the card reads next, until
the row says installed; then Disconnect. It writes only inside its scratch home, so it runs anywhere a cmux
binary does: --arg bin=PATH (a fleet-built or local cmux-tui `cmux`), --arg runs=N, --arg apps=a,b.

Rows (better = lower, unit ms), label app: linked (Connect click to the row reading Connected: install plus the
status read), connect, status, disconnect.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/desktop-link-connect.py"
ROW = re.compile(r"DESKTOP-LINK row (.*)$")
FIELD = re.compile(r"(\w+)=(\S+)")


class DesktopLink(Bench):
    name = "desktop-link"
    summary = "Time from Connect to a linked row in Settings > Agents (cmux agent hook install link-<app> + status)"
    units = "ms"
    owner = "agents-transport-hub"
    hosts = ("anywhere",)
    harness = HARNESS
    version = "1"
    thresholds = {"linked": 25.0}
    nightly = False

    def run(self, ctx: Context) -> None:
        binary = ctx.arg("bin")
        if not binary:
            raise BenchError("desktop-link: pass --arg bin=PATH to a cmux binary")
        root = Path(__file__).resolve().parents[3]
        log = ctx.workdir / "desktop-link.log"
        args = [sys.executable, str(root / HARNESS), "--bin", binary, "--runs", ctx.arg("runs", "20")]
        if ctx.arg("apps"):
            args += ["--apps", ctx.arg("apps")]
        done = subprocess.run(args, text=True, capture_output=True)
        log.write_text(done.stdout + done.stderr)
        if done.returncode != 0:
            raise BenchError(f"desktop-link: harness failed: {done.stderr.strip()[-400:]}")
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        found = 0
        for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            if m := ROW.search(line):
                f = dict(FIELD.findall(m.group(1)))
                ctx.row(f.get("step", "?"), float(f["p50_ms"]), "ms", p50=float(f["p50_ms"]),
                        p95=float(f["p95_ms"]), n=int(f["n"]), labels={"app": f.get("app", "?")})
                found += 1
        if not found:
            raise BenchError(f"{path}: no DESKTOP-LINK row (not a desktop-link-connect.py log?)")


BENCH = DesktopLink()

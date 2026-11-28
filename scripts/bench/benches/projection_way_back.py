"""projection-way-back: Bring Back of a projected folder (RFD 0007) against today's pull, one harness.

Wraps the ignored Rust test `a_bench_of_bring_back` (cmux-tui/crates/cmux-tui/tests/link_project_back.rs): the
real `cmux link start-chat copy` and `cmux link seed pull --or-copy` (Bring Back Local's pull) against the real
FsService and projection-v1 server behind a link of 50 ms RTT, over a folder of N notes plus a repository, after
the same 50 edits on the machine (48 changed, one made, one deleted). It prints one line per path:

  WAY-BACK {"path": "copy (today)" | "projected", "mode", "files", "edits", "bring_back_ms", "plan_ms", ...}
  WAY-BACK {"path": "plan only (in memory)", "files", "edits", "plan_us"}

Rows (labels: path, files), better = lower:
  bring_back (ms): the whole Bring Back, as the person waits for it;
  plan (ms): the projected path's plan step (the Mac's stat of the touched paths and the plan);
  plan_only (us): the pure plan over an in-memory manifest of N files with 50 edits (median of 20).

Run: `cmux-bench projection-way-back [--arg files=100000]` sends the harness through `cmux-ci test --setup rust`
(Linux, at the caller's open PR head on a lane VM). `--import LOG` reads a run's log.
"""
from __future__ import annotations

import json
import re
import shlex
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "cmux-tui/crates/cmux-tui/tests/link_project_back.rs"
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ")
LINE = re.compile(r"WAY-BACK (\{.*\})\s*$")


class ProjectionWayBack(Bench):
    name = "projection-way-back"
    summary = "Bring Back of a projected folder vs today's pull (ms), and the plan's cost, at N files and 50 edits"
    units = "ms, us"
    owner = "projected folders (RFD 0007)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    floors = {"bring_back": 20.0, "plan": 5.0, "plan_only": 100.0}

    def run(self, ctx: Context) -> None:
        files = int(ctx.arg("files") or 100000)
        command = (f"set -o pipefail; cd cmux-tui && CMUX_WAY_BACK_FILES={files} cargo test -p cmux-tui "
                   "--test it -- --ignored --nocapture a_bench_of_bring_back 2>&1 | tail -40")
        cmd = ["cmux-ci", "test", "--setup", "rust", "--timeout", "5400", "--", "bash", "-c", command]
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        log = ctx.workdir / "projection-way-back.log"
        with log.open("w", encoding="utf-8") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, check=False)
        ctx.host.update({"name": "linux-ci", "os": "Linux"})
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        found = 0
        for raw in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            m = LINE.search(STAMP.sub("", raw.strip()))
            if not m:
                continue
            try:
                row = json.loads(m.group(1))
            except json.JSONDecodeError:
                continue
            found += 1
            labels = {"path": str(row.get("path")), "files": str(row.get("files"))}
            if row.get("bring_back_ms") is not None:
                ctx.row("bring_back", float(row["bring_back_ms"]), "ms", labels=labels)
            if row.get("plan_ms") is not None:
                ctx.row("plan", float(row["plan_ms"]), "ms", labels=labels)
            if row.get("plan_us") is not None:
                ctx.row("plan_only", float(row["plan_us"]), "us", labels=labels)
        if not found:
            raise BenchError(f"{path}: no WAY-BACK line (not an a_bench_of_bring_back log?)")


BENCH = ProjectionWayBack()

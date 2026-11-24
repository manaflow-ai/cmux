"""projection-scale: RFD 0065's serve/link/mount and clone matrix, on one harness (piece 14).

Wraps `scripts/measure/projection-scale/measure.py`, which appends one JSON object a line to OUT/rows.jsonl:

  {"kind": "projection"|"git", "label", "mode", "profile", "phase", "wall_s", "down_bytes", "up_bytes", "asks",
   "git_bytes", "tree_bytes", "st1_s", "st2_s", "rss_mb", "rc", "note", ...}

Rows (labels: kind, label, mode, profile), better = lower:
  <phase> (s): wall seconds of a step (ls_cold, rg_warm, mount_rg, clone, widen, ...);
  <phase>_down (bytes): bytes down the link (projection) or received (git: pack growth, archive size);
  <phase>_asks (count): round trips up the link (projection only);
  <phase>_status1 (s): the first `git status` after a clone option.
A row whose command failed (rc != 0) records nothing but a note.

Run: `cmux-bench projection-scale --host anywhere --arg kind=projection --arg tree=PATH [--arg mode=plain]
[--arg profile=store-v6-1-low] [--arg bin=SLICE_BENCH]` or `--arg kind=git --arg repo=PATH [--arg cone=a,b]`.
`--import rows.jsonl` reads a run's rows.
"""
from __future__ import annotations

import json
import shlex
import subprocess
import sys
from pathlib import Path

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context

HARNESS = "scripts/measure/projection-scale/measure.py"
PASS = ("mode", "steps", "profile", "rtt_ms", "mbps", "bin", "branch", "options", "cone", "label")


class ProjectionScale(Bench):
    name = "projection-scale"
    summary = "Projection serve/link/mount and git clone options: seconds, bytes and asks per step (RFD 0065)"
    units = "s, bytes, count"
    owner = "projected folders (RFD 0065)"
    hosts = ("anywhere",)
    harness = HARNESS
    version = "1"
    floors = {"ls_cold": 0.05, "ls_warm": 0.05, "rg_cold": 0.1, "rg_warm": 0.05, "gitstatus_cold": 0.1,
              "gitstatus_warm": 0.05}

    def run(self, ctx: Context) -> None:
        kind = ctx.arg("kind") or "projection"
        if kind not in ("projection", "git"):
            raise BenchError("projection-scale: --arg kind=projection|git")
        target = ctx.arg("tree" if kind == "projection" else "repo")
        if not target:
            raise BenchError(f"projection-scale: pass --arg {'tree' if kind == 'projection' else 'repo'}=PATH")
        out = ctx.workdir / "projection-scale"
        cmd = [sys.executable, str(REPO_ROOT / HARNESS), kind, target, "--out", str(out)]
        for key in PASS:
            if ctx.arg(key):
                cmd += [f"--{key.replace('_', '-')}", ctx.arg(key)]
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        got = subprocess.run(cmd, cwd=REPO_ROOT, text=True, capture_output=True, timeout=7200, check=False)
        if got.returncode:
            raise BenchError(f"projection-scale: harness failed ({got.returncode}): {got.stderr.strip()[-500:]}")
        self.ingest(ctx, out / "rows.jsonl")

    def ingest(self, ctx: Context, path: Path) -> None:
        path = Path(path)
        path = path / "rows.jsonl" if path.is_dir() else path
        try:
            rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
        except (OSError, json.JSONDecodeError) as exc:
            raise BenchError(f"projection-scale: {path}: expected measure.py rows.jsonl: {exc}") from exc
        found = 0
        for row in rows:
            phase, wall = row.get("phase"), row.get("wall_s")
            if not phase or wall is None:
                continue
            labels = {k: row.get(k) or "" for k in ("kind", "label", "mode", "profile")}
            if row.get("rc"):
                ctx.notes.append(f"{labels['mode']} {phase}: rc={row['rc']} {row.get('note', '')}"[:300])
                continue
            ctx.row(phase, wall, "s", labels=labels)
            if row.get("down_bytes") is not None:
                ctx.row(f"{phase}_down", row["down_bytes"], "bytes", labels=labels)
            if row.get("kind") == "projection" and row.get("asks") is not None:
                ctx.row(f"{phase}_asks", row["asks"], "count", labels=labels)
            if row.get("st1_s") is not None:
                ctx.row(f"{phase}_status1", row["st1_s"], "s", labels=labels)
            found += 1
        if not found:
            raise BenchError(f"projection-scale: {path}: no measured rows")


BENCH = ProjectionScale()

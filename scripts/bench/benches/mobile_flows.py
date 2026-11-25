"""mobile-flows: iPhone app flows measured frame by frame, ours and Claude's, Codex's and other chat apps'.

The harness is scripts/mobile-bench/compare-mobile (its README defines every metric). `run` captures our app at
--build on a fleet iOS simulator and measures it (--arg flow=FLOW|all, default all); `--import DIR` records clips
already measured (any folder holding */result.json: a compare-mobile OUT/ours, or cmux-design-references
apps/<app>-mobile/bench).

Rows per app and flow (labels app=, flow=, source=): response, settle, motion (ms), dropped and jumps
(count), and spring_response (s) and spring_damping (x, the damping fraction) where the flow has a moving edge.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context

HARNESS = "scripts/mobile-bench/compare-mobile"


class MobileFlows(Bench):
    name = "mobile-flows"
    summary = "iPhone flows frame by frame (response, motion, drops, springs), ours vs Claude, Codex and other chat apps"
    units = "ms"
    owner = "iOS (Aziz)"
    hosts = ("anywhere",)
    harness = HARNESS
    version = "1"

    def run(self, ctx: Context) -> None:
        sha = ctx.build.get("sha")
        if not sha:
            raise BenchError("mobile-flows: --build must name a pushed commit")
        out = ctx.workdir / "compare-mobile"
        cmd = [sys.executable, str(REPO_ROOT / HARNESS), ctx.arg("flow", "all"), "--ref", sha, "--out", str(out)]
        if ctx.dry_run:
            print("dry run:", " ".join(cmd))
            raise BenchError("dry run")
        proc = subprocess.run(cmd, text=True)
        if proc.returncode != 0:
            raise BenchError(f"compare-mobile exited {proc.returncode}")
        self.ingest(ctx, out / "ours")

    def ingest(self, ctx: Context, path: Path) -> None:
        results = sorted(Path(path).rglob("result.json"))
        if not results:
            raise BenchError(f"{path}: no result.json (run scripts/mobile-bench/measure.py on its clips)")
        for res_path in results:
            r = json.loads(res_path.read_text())
            labels = {"app": r.get("app") or "?", "flow": r.get("flow") or "?", "source": r.get("source") or ""}
            for key in ("response_ms", "settle_ms", "motion_ms"):
                if r.get(key) is not None:
                    ctx.row(key.removesuffix("_ms"), r[key], "ms", labels=labels)
            for key in ("dropped", "jumps"):
                if r.get(key) is not None:
                    ctx.row(key, r[key], "count", labels=labels)
            curve = r.get("curve") or {}
            if curve:
                ctx.row("spring_response", curve["spring_response_s"], "s", better="none", labels=labels)
                ctx.row("spring_damping", curve["spring_damping_fraction"], "x", better="none", labels=labels)


BENCH = MobileFlows()

"""pane-compile: the agent pane's JS compile before first paint, cold and with a warm V8 code cache.

Wraps scripts/measure/pane-compile-ab.mjs: it builds the pane (scripts/cmux-next/build-agent-pane-web.sh --out DIR)
at the checkout, then loads it in a stock headless Chrome over http, cold (fresh profile per load) and warm (one
profile, cacheable responses, three priming loads), with a DevTools trace of each load. Linux, no app.

Rows per mode (label mode=cold|warm): fcp (first contentful paint after navigation start), main_compile (main-thread
V8.CompileCode ms), main_compiles (their count: lazy compiles), background_parse (the streaming thread's
v8.parseOnBackground ms) and cache_consumed (code cache deserializations per load, the page's small classic scripts included; higher is
better).
A warm load that still compiles as much as a cold one means the code cache is not consumed: on 2026-11-23 the
pane, an ES module, compiled 4,387 functions warm and cold alike (cmuxterm-hq
docs/research/2026-11-23-startup-module-code-cache.md).

  --arg runs=N       loads per mode (default 5)
  --arg dir=PATH     measure an already built pane instead of building one
  --import PATH      a saved {"cold": ..., "warm": ...} pair of the harness's outputs
"""
from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context

HARNESS = "scripts/measure/pane-compile-ab.mjs"
BUILD = "scripts/cmux-next/build-agent-pane-web.sh"
METRICS = (
    ("fcpMs", "fcp", "ms", "lower"),
    ("mainCompileMs", "main_compile", "ms", "lower"),
    ("mainCompiles", "main_compiles", "count", "lower"),
    ("backgroundParseMs", "background_parse", "ms", "lower"),
    ("cacheConsumed", "cache_consumed", "count", "higher"),
)


class PaneCompile(Bench):
    name = "pane-compile"
    summary = "Agent pane JS compile before first paint, cold and warm code cache (headless Chrome, Linux)"
    units = "ms, count"
    owner = "research:startup (gcp-codex-lane-5/startup-tti)"
    hosts = ("anywhere",)
    harness = HARNESS
    version = "1"
    floors = {"fcp": 20.0, "main_compile": 10.0, "background_parse": 20.0}

    def run(self, ctx: Context) -> None:
        pane = ctx.arg("dir")
        if not pane:
            pane = tempfile.mkdtemp(prefix="pane-compile-", dir=ctx.workdir)
            built = subprocess.run([str(REPO_ROOT / BUILD), "--out", pane], cwd=REPO_ROOT, text=True,
                                   capture_output=True, timeout=1800)
            if built.returncode != 0:
                raise BenchError(f"pane-compile: pane build failed: {built.stderr.strip()[-500:]}")
        runs = str(ctx.arg("runs", "5"))
        pair = {}
        for mode in ("cold", "warm"):
            cmd = ["node", str(REPO_ROOT / HARNESS), pane, pane, runs] + (["--warm"] if mode == "warm" else [])
            got = subprocess.run(cmd, cwd=REPO_ROOT, text=True, capture_output=True, timeout=3600)
            if got.returncode != 0:
                raise BenchError(f"pane-compile: {mode} harness failed: {got.stderr.strip()[-500:]}")
            pair[mode] = json.loads(got.stdout)
        out = ctx.workdir / "pane-compile.json"
        out.write_text(json.dumps(pair))
        self.ingest(ctx, out)

    def ingest(self, ctx: Context, path: Path) -> None:
        try:
            pair = json.loads(Path(path).read_text())
        except (OSError, ValueError) as err:
            raise BenchError(f"pane-compile: {path}: {err}") from err
        if not any(mode in pair for mode in ("cold", "warm")):
            raise BenchError(f"pane-compile: {path}: no cold or warm run")
        for mode in ("cold", "warm"):
            doc = pair.get(mode)
            if not doc:
                continue
            # Both sides load the same pane in a bench run (A/B runs compare two), so every load is a sample.
            loads = [r for side in ("A", "B") for r in (doc.get(side) or {}).get("runs", [])]
            for field, metric, unit, better in METRICS:
                ctx.row(metric, unit=unit, better=better, samples=[r.get(field) for r in loads],
                        labels={"mode": mode})


BENCH = PaneCompile()

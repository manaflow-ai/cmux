"""glass-engine: web glass per frame on a fleet Mac's GPU, the lens as it ships against the glass engine.

scripts/measure/glass-engine-frames.sh runs webviews/bench/glass-engine.bench.ts in the installed Google Chrome (ANGLE on
Metal, no automation attached) on a display worker, headless (the viewport exactly the asked size) and then headful
(the display paces the frames), at 1440x900@2 and 1920x1080@2 (3840x2160 device px) with 3 and 32 glass, per glass
mode and art blur. Rows, labelled renderer (lens|engine), mode, blur, glass, viewport and run (headless|headful):
  cost_ms               one frame's GPU ms (120 frames back to back, one readback), p50/p95
  frame_interval_ms     animation frame interval with every glass moving (the lens redraws every frame), p50/p95
  frame_interval_max_ms the longest of those
  fps, dropped_frames   frames per second, and intervals over 1.5x the idle refresh
A run on software GL (SwiftShader, llvmpipe) is refused: it measures no GPU.

`cmux-bench glass-engine --import FILE` reads the artifact (.tar.gz), one of its JSON files, or the step's log
(its GLASS-ENGINE-FRAMES lines).
"""
from __future__ import annotations

import json
import tarfile
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/glass-engine-frames.sh"
ARTIFACT = "artifacts/glass-engine-frames.tar.gz"
MARK = "GLASS-ENGINE-FRAMES "


def _rows_of(path: Path) -> list[dict]:
    if path.name.endswith(".tar.gz"):
        rows: list[dict] = []
        with tarfile.open(path) as archive:
            for member in archive.getmembers():
                if member.isfile() and member.name.endswith(".json"):
                    rows += json.load(archive.extractfile(member))  # type: ignore[arg-type]
        return rows
    text = path.read_text(encoding="utf-8", errors="replace")
    try:
        data = json.loads(text)
    except ValueError:
        return [json.loads(ln[len(MARK):]) for ln in text.splitlines() if ln.startswith(MARK)]
    return data if isinstance(data, list) else []


class GlassEngine(Bench):
    name = "glass-engine"
    summary = "lens vs glass engine per frame at 1440x900@2 and 4K, 3 and 32 glass: GPU ms, frame interval, drops"
    units = "ms, fps, count"
    owner = "glass engine (webviews/src/ui/glass/engine)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    floors = {"cost_ms": 0.2, "frame_interval_ms": 1.0}

    def run(self, ctx: Context) -> None:
        args = [f"rounds={ctx.arg('rounds') or 20}", f"paced={ctx.arg('paced') or 600}"]
        for key in ("modes", "chips", "sizes"):
            if ctx.arg(key):
                args.append(f"{key}={ctx.arg(key)}")
        res = ctx.fleet_step(HARNESS, args, ARTIFACT, step_class="exclusive", labels=("measure",), display=True,
                             timeout=int(ctx.arg("timeout") or 5400))
        self.ingest(ctx, res.artifact_path or res.log_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        rows = [r for r in _rows_of(path) if isinstance(r, dict)]
        if not rows:
            raise BenchError(f"glass-engine: {path}: no rows of glass-engine.bench.ts")
        measured = [r for r in rows if not r.get("error")]
        for r in rows:
            if r.get("error"):
                ctx.notes.append(f"{r.get('label')} {r.get('renderer')} {r.get('mode')}: {str(r['error'])[:200]}")
        if any(r.get("software") for r in measured):
            raise BenchError(f"glass-engine: {path} ran on software GL ({measured[0].get('gpu')}): no GPU number")
        gpus = sorted({str(r.get("gpu")) for r in measured})
        ctx.notes.append(f"renderer {', '.join(gpus)}; host {measured[0].get('host') if measured else '?'}")
        for r in measured:
            labels = {
                "renderer": str(r["renderer"]), "mode": str(r["mode"]), "blur": str(r.get("artBlur")),
                "glass": str(r.get("glass")), "viewport": str(r.get("viewport")), "run": str(r.get("label")),
            }
            ctx.row("cost_ms", r["p50"], "ms", p50=r["p50"], p95=r["p95"], labels=labels)
            if r.get("frames"):
                ctx.row("frame_interval_ms", r["frameP50"], "ms", p50=r["frameP50"], p95=r["frameP95"], n=r["frames"],
                        labels=labels)
                ctx.row("frame_interval_max_ms", r["frameMax"], "ms", labels=labels)
                ctx.row("fps", r["fps"], "fps", better="higher", labels=labels)
                ctx.row("dropped_frames", r["dropped"], "count", labels=labels)


BENCH = GlassEngine()

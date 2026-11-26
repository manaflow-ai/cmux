"""pane-resize-drag: frame time while the divider beside a long agent chat is dragged with pauses (web, Linux CI).

Wraps webviews/bench/pane-resize-drag.bench.ts: a headless Chromium and WebKit page holding the agent pane's real
transcript (VirtualTranscript, the pane's styles, the thread minimap) over a long chat (prompts, tool rows, diffs,
Markdown replies with headings, lists, code and tables; webviews/bench/pane-resize-drag/longChat.ts) at 200, 700 and
2000 turns, while its width is dragged 900 -> 320 -> 900 px over about 3.3 s with 150-300 ms pauses, as a person drags
the split divider (Leo, 2026-11-18: 12-16 fps, 0-4 fps narrow, single 0.9-1.5 s frames beside a 700-turn chat). Each
frame is the interval between two requestAnimationFrame callbacks, reported by phase: drag (the divider moving),
resume (the first 3 frames of a move after a pause), settle (the width holding after a move) and all.

The harness runs on a Linux CI box, never on a Mac (no Playwright on Macs). `run` sends it there with `cmux-ci test`
from webviews/ (on a lane VM that is the open PR's head, so push first) and reads the artifact back; or run it
yourself and record the result:

  cd webviews && cmux-ci test --setup playwright --artifact /tmp/dragbench -- bash bench/pane-resize-drag/ci.sh
  scripts/bench/cmux-bench pane-resize-drag --import /tmp/dragbench/summary.json --build <sha>

  --arg turns=200,700,2000  --arg engines=chromium,webkit  --arg rounds=3  --arg driver=root|viewport

Rows, labels engine, turns, phase (all, drag, resume, settle) and driver:
  frame_ms          every frame interval of the measured rounds (value = median; p50, p95, n)
  frame_p95_ms      the p95 interval (the lane's target: <= 18.2 ms, 55 fps)
  frame_max_ms      the longest interval (target: <= 50 ms)
  frames_over_50ms  frames longer than 50 ms
  fps_at_p95        1000 / p95 (higher is better)
Headless Linux has no display refresh: these are main-thread frame times on a CI runner, comparable before and after
on the same runner class, not the Mac's display frames.
"""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "webviews/bench/pane-resize-drag.bench.ts"
CI_SCRIPT = "bench/pane-resize-drag/ci.sh"
PHASES = ("all", "drag", "resume", "settle")
PASSED_ARGS = ("turns", "engines", "rounds", "driver", "wide", "narrow")


class PaneResizeDrag(Bench):
    name = "pane-resize-drag"
    summary = "Frame time dragging the divider beside a long agent chat, with pauses (Chromium/WebKit, 200-2000 turns)"
    units = "ms, count, fps"
    owner = "agent chat pane resize (lane pane-resize-60fps)"
    hosts = ("anywhere",)
    harness = HARNESS
    version = "1"
    floors = {"frame_ms": 2.0, "frame_p95_ms": 2.0, "frame_max_ms": 10.0, "frames_over_50ms": 1.0, "fps_at_p95": 2.0}

    def run(self, ctx: Context) -> None:
        if shutil.which("cmux-ci") is None:
            raise BenchError(f"pane-resize-drag: run {CI_SCRIPT} on a Linux CI box (cmux-ci test --setup playwright "
                             f"--artifact DIR -- bash {CI_SCRIPT}), then `cmux-bench pane-resize-drag --import "
                             "DIR/summary.json`")
        webviews = Path(__file__).resolve().parents[3] / "webviews"
        artifact = ctx.workdir / "artifact"
        extra = [f"--{key}={ctx.args[key]}" for key in PASSED_ARGS if ctx.args.get(key)]
        cmd = ["cmux-ci", "test", "--setup", "playwright", "--artifact", str(artifact), "--", "bash", CI_SCRIPT, *extra]
        if ctx.dry_run:
            print(f"cd {webviews} && " + " ".join(cmd))
            raise BenchError("dry run")
        done = subprocess.run(cmd, cwd=webviews)
        summary = artifact / "summary.json"
        if not summary.exists():
            raise BenchError(f"pane-resize-drag: cmux-ci test exited {done.returncode} and left no {summary}")
        self.ingest(ctx, summary)
        if done.returncode != 0:
            ctx.notes.append(f"pane-resize-drag: the harness exited {done.returncode}; rows are from the cases that ran")

    def ingest(self, ctx: Context, path: Path) -> None:
        if path.is_dir():
            path = path / "summary.json"
        text = path.read_text(encoding="utf-8", errors="replace")
        try:
            doc = json.loads(text)
        except ValueError:
            doc = None
        if isinstance(doc, dict) and doc.get("schema") == "pane-resize-drag/v1":
            return self._summary(ctx, doc)
        lines = [ln for ln in text.splitlines() if ln.startswith("PANE_RESIZE_DRAG {")]
        if not lines:
            raise BenchError(f"pane-resize-drag: {path}: no summary.json document or PANE_RESIZE_DRAG line")
        for ln in lines:
            case = json.loads(ln.split(" ", 1)[1])
            self._stats(ctx, case, case.get("driver", "root"), {phase: case.get(phase) or {} for phase in PHASES})
        ctx.notes.append("pane-resize-drag: read from the PANE_RESIZE_DRAG lines (no per-frame samples)")

    def _summary(self, ctx: Context, doc: dict) -> None:
        driver = doc.get("driver", "root")
        for case in doc.get("cases") or []:
            labels = self._labels(case, driver)
            for phase in PHASES:
                samples = (case.get("intervals") or {}).get(phase) or []
                if samples:
                    ctx.row("frame_ms", unit="ms", samples=samples, labels={**labels, "phase": phase})
            self._stats(ctx, case, driver, case.get("phases") or {})
        for failure in doc.get("failures") or []:
            ctx.notes.append(f"pane-resize-drag: {failure}")

    @staticmethod
    def _labels(case: dict, driver: str) -> dict:
        return {"engine": case.get("engine", ""), "turns": case.get("turns", ""), "driver": driver}

    def _stats(self, ctx: Context, case: dict, driver: str, phases: dict) -> None:
        labels = self._labels(case, driver)
        for phase in PHASES:
            cell = phases.get(phase) or {}
            if not cell.get("frames"):
                continue
            at = {**labels, "phase": phase}
            ctx.row("frame_p95_ms", cell.get("p95_ms"), "ms", n=cell.get("frames"), labels=at)
            ctx.row("frame_max_ms", cell.get("max_ms"), "ms", n=cell.get("frames"), labels=at)
            ctx.row("frames_over_50ms", cell.get("over_50ms"), "count", labels=at)
            ctx.row("fps_at_p95", cell.get("fps_at_p95"), "fps", better="higher", labels=at)


BENCH = PaneResizeDrag()

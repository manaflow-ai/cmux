"""overlay: intent to overlay, the main-thread time of the store's optimistic overlay for one intent.

Wraps the Swift Testing suite `OptimisticOverlayBench` (Packages/macOS/CmuxNext/Tests/CmuxNextDaemonTests) through
scripts/ci/package-test-lane.sh's `suite` mode on a fleet Mac, built optimized (CMUX_SWIFT_SUITE_CONFIGURATION=release,
what the person runs; a Debug build times its walks several times slower), with CMUX_SWIFT_TEST_SUITES=
OptimisticOverlayBench (the suite runs only when named). Each sample is one `DaemonStore.intend` of a split, Split
Left, New Column (screens of 2, 64 and 256 panes, a chain and a balanced tree: scenarios `*_balanced`), a tab move (a
pane of 50 tabs) or a workspace move (200 workspaces); the suite prints one line per case:

  OVERLAY-BENCH {"scenario": "split", "panes": 64, "unit": "ns", "p50": .., "p95": .., "samples": [..]}

Rows: `intent_to_overlay` (us, lower), labels scenario and panes; p50, p95 and n from the samples.
The overlay is the first part of an action's path to its committed frame (budget < 10 ms p95).

Run: `cmux-bench overlay --host fleet --build SHA`. `--import LOG` reads a step log with those lines.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/ci/package-test-lane.sh"
PACKAGE = "Packages/macOS/CmuxNext"
SUITE = "OptimisticOverlayBench"
LINE = re.compile(r"OVERLAY-BENCH (\{.*\})\s*$")


class Overlay(Bench):
    name = "overlay"
    summary = "Intent to overlay: the store's optimistic overlay time per split, column, tab or workspace intent"
    units = "us"
    owner = "cmux-next store (#37429)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "2"  # 2: release build, balanced-tree cases
    floors = {"intent_to_overlay": 50.0}

    def run(self, ctx: Context) -> None:
        ref = ctx.build.get("sha") if ctx.build.get("channel") == "sha" else None
        res = ctx.fleet_step(self.harness, ["suite", PACKAGE, SUITE], None, step_class="light", labels=(), timeout=5400,
                             ref=ref, env={"CMUX_SWIFT_TEST_SUITES": SUITE, "CMUX_SWIFT_SUITE_CONFIGURATION": "release"})
        self.ingest(ctx, res.log_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        found = 0
        for raw in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            m = LINE.search(raw)
            if not m:
                continue
            try:
                case = json.loads(m.group(1))
            except json.JSONDecodeError:
                continue
            samples = [ns / 1000.0 for ns in case.get("samples") or []]
            if not samples:
                continue
            ctx.row("intent_to_overlay", unit="us", samples=samples,
                    labels={"scenario": str(case.get("scenario")), "panes": int(case.get("panes", 0))})
            found += 1
        if not found:
            raise BenchError(f"overlay: no OVERLAY-BENCH line in {path}")


BENCH = Overlay()

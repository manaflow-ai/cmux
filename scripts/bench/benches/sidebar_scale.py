"""sidebar-scale: the work one peer session's change costs the sidebar at 50, 200 and 2,000 attached sessions.

Goal sessions-2000-attached: per-update cost at 2,000 sessions within 1.2x of 50. Wraps the CmuxNextAppTests suite
SidebarScaleWorkTests (Tests/CmuxNextAppTests/SidebarScaleWorkTests.swift), run through
scripts/ci/package-test-lane.sh's `suite` mode on a fleet Mac. The suite counts work with `ScaleWork`
(CmuxNextCompat), not time, so the numbers are exact and the same on every Mac. Every line it prints that this reads:

  SIDEBAR-SCALE {"op": "change"|"follow"|"band", "n": N, "lanes_walked": .., "sets_built": .., "rebuilds": ..,
                 "band_rows": .., "list_reloads": .., "total": .., "rows": ..}
  SIDEBAR-SCALE-RATIO {"op": .., "ratio": ..}

op change: one peer `_acpmux/session_changed`; follow: one follow reply with one changed row; each followed by the
readers' work (the machines' groups, the Dock menu's chats, the band's transient rows). op band: one band layout
with every chat of one machine shown (`rows` rows).

Rows (labels op, n), better = lower: lanes_walked, sets_built, rebuilds, band_rows, list_reloads, total (count);
ratio (label op): op's total at the largest n over the smallest (band: band rows per row shown).

Run: `cmux-bench sidebar-scale --host fleet --build SHA`, or `--import LOG` for a step's log.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/ci/package-test-lane.sh"
SUITE = "SidebarScaleWorkTests"
KINDS = ("lanes_walked", "sets_built", "rebuilds", "band_rows", "list_reloads", "probes", "total")
LINE = re.compile(r"SIDEBAR-SCALE(-RATIO)? (\{.*\})\s*$")


class SidebarScale(Bench):
    name = "sidebar-scale"
    summary = "Sidebar work for one peer session change at 50/200/2000 sessions (counted, not timed)"
    units = "count, x"
    owner = "sidebar at scale (goal sessions-2000-attached)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    floors = {kind: 0.0 for kind in KINDS} | {"ratio": 0.05}

    def run(self, ctx: Context) -> None:
        ref = ctx.build.get("sha") if ctx.build.get("channel") == "sha" else None
        res = ctx.fleet_step(self.harness, ["suite", "Packages/macOS/CmuxNext", SUITE], None, step_class="light",
                             labels=(), timeout=5400, ref=ref)
        self.ingest(ctx, res.log_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        seen: dict[tuple[str, int], dict] = {}
        ratios: dict[str, float] = {}
        for raw in text.splitlines():
            m = LINE.search(raw)
            if not m:
                continue
            try:
                obj = json.loads(m.group(2))
            except json.JSONDecodeError:
                continue
            if m.group(1):
                ratios[str(obj.get("op"))] = float(obj.get("ratio") or 0)
            else:
                seen[(str(obj.get("op")), int(obj.get("n") or 0))] = obj
        if not seen:
            raise BenchError(f"{path}: no SIDEBAR-SCALE line (not a {SUITE} log, or the suite did not build)")
        for (op, n), obj in sorted(seen.items()):
            labels = {"op": op, "n": str(n)}
            for kind in KINDS:
                if isinstance(obj.get(kind), (int, float)):
                    ctx.row(kind, float(obj[kind]), "count", labels=labels)
            if isinstance(obj.get("rows"), (int, float)):
                ctx.row("rows", float(obj["rows"]), "count", better="none", labels=labels)
        for op, ratio in sorted(ratios.items()):
            ctx.row("ratio", ratio, "x", labels={"op": op})


BENCH = SidebarScale()

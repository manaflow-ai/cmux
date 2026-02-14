#!/usr/bin/env python3
"""Regression: nested split must keep panel-to-view routing consistent.

Symptom (user report): after split churn, it can look like you're typing into one terminal
but the visible terminal doesn't update until refocus. Another manifestation is that a
pane can appear to disappear or show the wrong surface.

We validate routing using debug-only `panel_snapshot` diffs:
  - Create a 3-pane horizontal layout: split right, focus right, split right again.
  - For each panel, send a unique marker line to that specific panel.
  - After each send, only that panel's snapshot should change materially.

This test avoids `layout_debug` because it calls `layoutSubtreeIfNeeded()` and can mask
layout/view-tree problems.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _baseline_all(c: cmux, panel_ids: list[str], label: str) -> None:
    for pid in panel_ids:
        c.panel_snapshot(pid, label=f"{label}_base_{pid[:6]}")


def _after_all(c: cmux, panel_ids: list[str], label: str) -> dict[str, int]:
    diffs: dict[str, int] = {}
    for pid in panel_ids:
        snap = c.panel_snapshot(pid, label=f"{label}_after_{pid[:6]}")
        diffs[pid] = int(snap["changed_pixels"])
    return diffs


def _assert_routing(diffs: dict[str, int], target: str, *, min_changed: int = 250, ratio: float = 3.0) -> None:
    tgt = diffs.get(target)
    if tgt is None:
        raise cmuxError(f"missing diff for target {target}")
    # -1 means first diff or size mismatch; treat as failure here.
    if tgt < min_changed:
        raise cmuxError(f"target panel did not change enough (changed_pixels={tgt}): diffs={diffs}")

    others = [v for k, v in diffs.items() if k != target]
    max_other = max(others) if others else 0
    if max_other > 0 and float(tgt) < float(max_other) * ratio:
        raise cmuxError(
            f"non-target changed too much (target={tgt} max_other={max_other} ratio={ratio}): diffs={diffs}"
        )


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        c.new_workspace()
        time.sleep(0.25)

        surfaces0 = c.list_surfaces()
        if not surfaces0:
            raise cmuxError("expected initial surface")
        left_panel = surfaces0[0][1]

        right_panel = c.new_split("right")
        time.sleep(0.1)

        c.focus_surface(right_panel)
        time.sleep(0.05)

        new_right_panel = c.new_split("right")
        time.sleep(0.15)

        panel_ids = [left_panel, right_panel, new_right_panel]

        # Ensure snapshots start from a clean baseline.
        for pid in panel_ids:
            c.panel_snapshot_reset(pid)

        # Warm up: take an initial baseline.
        _baseline_all(c, panel_ids, label="warm")

        # Route-check each panel.
        for i, target in enumerate(panel_ids):
            marker = f"CMUX_ROUTE_{i}_{target[:6]}"

            _baseline_all(c, panel_ids, label=f"step{i}")

            # Send marker to the target panel.
            c.send_surface(target, f"echo {marker}\n")

            # Allow time for the terminal to render the new line.
            time.sleep(0.35)

            diffs = _after_all(c, panel_ids, label=f"step{i}")
            _assert_routing(diffs, target)

            # Sanity: the marker should be present in the terminal model too.
            text = c.read_terminal_text(target)
            if marker not in text:
                raise cmuxError(f"marker missing from read_terminal_text for {target}: {marker}")

        print("PASS: nested split panel routing via snapshots")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())

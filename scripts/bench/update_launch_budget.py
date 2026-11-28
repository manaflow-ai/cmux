#!/usr/bin/env python3
"""The Update flow area's launch budget: the first launch after an update (app_update_launch_ms), under 2 s.

    update_launch_budget.py [--dmg DMG] [--rounds N]          (DMG also from $CMUX_UPDATE_LAUNCH_DMG)

shadow-leo, 2026-11-28 (ask c-5ad71ec59c): "pick update flow as the one area: path map entry -> its test list -> its
bench budget (app_update_launch_ms), run only when those paths change, fail-open on missing reference."

docs/benches/relevance-map.toml's "Update flow" area names this as its `run` with budget_s = 2.0, so
`cmux-bench for-paths --run` (bench-relevance-pr.yml) runs it only when a pull request touches that area's paths.
It measures the arm NOW's app_update_launch_ms reads: scripts/measure/nightly-fresh-launch.py --arms update
(prewarm-update-moved: the updater's StagedUpdatePrewarm in a staging folder, renamed into place, launched in a new
home), each launch read as cmuxterm-hq nightly_dogfood.update_launch_reading does: max(first_window_frame_committed,
Home's page) by the app's own marks, a round whose pre-warm failed left out. It prints `bench_seconds=S` (the median),
the line relevance._measure reads, so the area's budget_s judges it: over 2.0 s is red.

Fail open: no Mac (the bench job is Linux), no DMG to launch, or no launch with app marks is no reading. It says why
and exits 127, which for-paths --run reports as a missing tool: a warning, never a red.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FRESH_LAUNCH = ROOT / "scripts" / "measure" / "nightly-fresh-launch.py"
ARM = "prewarm-update-moved"
NO_READING = 127  # relevance._measure: MISSING, a warning (fail open)


def launch_ms(row: dict) -> float | None:
    """One update launch's ms since process start by the app's marks (nightly_dogfood_journey.launch_ms's rule), or
    None when the round's pre-warm failed or the launch showed no Home page with marks."""
    before = row.get("before") if isinstance(row.get("before"), dict) else {}
    if before.get("chromium_exit") != 0 or not isinstance(before.get("main_start_at"), (int, float)):
        return None
    if row.get("rendered_at") is None or row.get("exit") is not None:
        return None
    marks = row.get("marks") if isinstance(row.get("marks"), dict) else {}
    frame = marks.get("first_window_frame_committed")
    home = marks.get("home.saved_page_shown", marks.get("home.first_page"))
    if home is None and "reveal.home.by_deadline" not in marks:
        home = marks.get("reveal.home")
    if not isinstance(frame, (int, float)) or not isinstance(home, (int, float)):
        return None
    return float(max(frame, home))


def reading(report: dict) -> tuple[float | None, str]:
    """The median update launch in ms, or None and why."""
    rows = [r for r in report.get("launches") or [] if isinstance(r, dict) and r.get("arm") == ARM]
    if not rows:
        return None, "no update arm reported"
    values = [v for v in (launch_ms(r) for r in rows) if v is not None]
    if not values:
        return None, "no update launch rendered Home with app marks"
    return statistics.median(values), f"{len(values)} of {len(rows)} rounds"


def no_reading(why: str) -> int:
    print(f"update-launch: fail open, nothing measured: {why}")
    return NO_READING


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--dmg", default=os.environ.get("CMUX_UPDATE_LAUNCH_DMG", ""))
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--report", help="read this report.json instead of launching (tests)")
    args = parser.parse_args(argv)
    if args.report:
        report = json.loads(Path(args.report).read_text(encoding="utf-8"))
    else:
        if platform.system() != "Darwin":
            return no_reading(f"an update launch needs a Mac; this runner is {platform.system()}")
        if not args.dmg or not Path(args.dmg).is_file():
            return no_reading("no DMG to launch (pass --dmg or set CMUX_UPDATE_LAUNCH_DMG)")
        with tempfile.TemporaryDirectory(prefix="update-launch-") as out:
            res = subprocess.run([sys.executable, "-I", str(FRESH_LAUNCH), "--dmg", args.dmg, "--out", out,
                                  "--rounds", str(args.rounds), "--arms", "update"], timeout=1200)
            path = Path(out) / "report.json"
            if not path.is_file():
                return no_reading(f"nightly-fresh-launch.py wrote no report (exit {res.returncode})")
            report = json.loads(path.read_text(encoding="utf-8"))
    ms, detail = reading(report)
    if ms is None:
        return no_reading(detail)
    print(f"update-launch: app_update_launch_ms={ms:.1f} ({detail})")
    print(f"bench_seconds={ms / 1000:.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""The perf cron's hot-swap part (split-spring-terminal.py --suite=graceful-swap): a webview .tsx save to the first
changed frame of the pane, per surface, as perf-cron rows: the goal hot-swap-fast's numbers on every measured tip.

Leo's rule: "Root-fix anything slow, stalling, uncached, growing". Until this part, hot_swap_mac_*_p95_ms in
cmuxterm-hq's NOW came only from a person's cmux-ci step (graceful-swap-fleet.sh), then `cmux-bench graceful-swap
--import` and a hand publish (now_hand_measures.py): the unfocused row read null from 2026-11-24 to 2026-11-27.

This runs graceful-swap-fleet.py's latency series on the cron's app (split-spring's tagged bench build, already on
the cron's virtual display), no films: the dev server serves this checkout, `composer` saves ComposerFoot.tsx and
films the focused chat-a and the unfocused chat-b; `hidden` saves it while chat-c is hidden and films its show.
report.json `rows` (perf-cron.py's budgets kind), from each DIR/latency/<series>-<surface>.json receipt:
- hot_swap.mac.<surface>.p95_ms (focused_pane 150 ms, unfocused_pane 300 ms, hidden_tab 100 ms: the bars of
  scripts/bench/benches/graceful_swap.py LATENCY_ROWS), only when the run is valid: every other region kept its
  picture in every run (drafts_kept == runs) and showed no transient frame. A swap that lost a draft has no latency
  to report, so its row is missing and the report says why (`incomplete`);
- hot_swap.mac.<surface>.drafts_lost and .transient_frames (count, budget 0), always, so an invalid run is a red
  row in the cron, never only a missing one.
NOW reads hot_swap.mac.<surface>.p95_ms@<host> (cmuxterm-hq tools/fleet-reconcilers/now_benches.py HOT_SWAP_ROWS).
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
# graceful-swap-fleet.py's receipt surface -> (row surface, bar ms). Same bars as cmux-bench graceful-swap.
SURFACES = {"focused": ("focused_pane", 150.0), "unfocused": ("unfocused_pane", 300.0), "hidden": ("hidden_tab", 100.0)}
SERIES = "composer,hidden"
FLOOR_MS = 17.0  # about one frame of a 60 Hz film: smaller moves are the film's phase, not the swap
COUNT_FLOOR = 0.5


def rows_from(receipts: list[dict]) -> tuple[list[dict], list[str]]:
    """perf-cron rows and the reasons a surface has no latency row, from the latency receipts (pure)."""
    rows, incomplete, seen = [], [], set()
    for receipt in receipts:
        surface = receipt.get("surface")
        if surface not in SURFACES or surface in seen:
            continue
        seen.add(surface)
        name, bar = SURFACES[surface]
        prefix = f"hot_swap.mac.{name}"
        regions = receipt.get("regions") if isinstance(receipt.get("regions"), dict) else {}
        watched = regions.get(receipt.get("watch")) or {}
        others = [r for key, r in regions.items() if key != receipt.get("watch") and isinstance(r, dict)]
        runs = int(receipt.get("runs") or 0)
        kept = min((int(r.get("kept", 0)) for r in others), default=runs)
        transient = sum(int(r.get("transient_frames", 0)) for r in others)
        lost = max(runs - kept, 0)
        rows.append({"name": f"{prefix}.drafts_lost", "p50": lost, "p95": lost, "unit": "count", "budget": 0,
                     "floor": COUNT_FLOOR})
        rows.append({"name": f"{prefix}.transient_frames", "p50": transient, "p95": transient, "unit": "count",
                     "budget": 0, "floor": COUNT_FLOOR})
        p95, n = watched.get("p95_ms"), int(watched.get("n") or 0)
        if not isinstance(p95, (int, float)) or n == 0:
            incomplete.append(f"{surface}: the watched region {receipt.get('watch')!r} never changed in {runs} runs")
        elif lost or transient:
            incomplete.append(f"{surface}: invalid run, drafts kept {kept}/{runs}, {transient} transient frames "
                              f"(p95 {p95:.0f} ms not reported)")
        else:
            rows.append({"name": f"{prefix}.p95_ms", "p50": watched.get("p50_ms"), "p95": p95, "unit": "ms",
                         "budget": bar, "floor": FLOOR_MS, "n": n, "missed": watched.get("missed", 0),
                         "drafts_kept": f"{kept}/{runs}"})
    for surface in SURFACES:
        if surface not in seen:
            incomplete.append(f"{surface}: no latency receipt")
    return rows, incomplete


def tool_path(out: str) -> str:
    """PATH with bun and ffmpeg, as graceful-swap-fleet.sh finds them: the account's tool folders, the private bun."""
    path = os.environ.get("PATH", "")
    home = os.path.expanduser("~")
    for folder in (f"{home}/.bun/bin", f"{home}/.local/node/bin", "/opt/homebrew/bin", "/usr/local/bin"):
        if os.path.isdir(folder):
            path = f"{folder}:{path}"
    if not shutil.which("bun", path=path):
        bun_path = os.path.join(out, "bun-path")
        subprocess.run([os.path.join(ROOT, "scripts/cmux-next/private-bun.sh")], cwd=ROOT, check=False,
                       env={**os.environ, "PATH": path, "RUNNER_TEMP": out, "GITHUB_PATH": bun_path})
        if os.path.exists(bun_path):
            with open(bun_path) as f:
                lines = f.read().split()
            if lines:
                path = f"{lines[-1]}:{path}"
    return path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--json", required=True, help="the part's report.json")
    parser.add_argument("--out", default=None, help="split-spring's artifact folder")
    parser.add_argument("--runs", type=int, default=20)
    args, _rest = parser.parse_known_args(argv)  # split-spring's own args are not this suite's
    out = os.path.join(args.out or os.path.dirname(os.path.abspath(args.json)), "graceful-swap")
    os.makedirs(out, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="gsw-cron-")
    path = tool_path(scratch)
    if not shutil.which("ffmpeg", path=path) or not shutil.which("ffprobe", path=path):
        brew = shutil.which("brew", path=path) or "/opt/homebrew/bin/brew"
        subprocess.run([brew, "install", "ffmpeg"], env={**os.environ, "PATH": path, "HOMEBREW_NO_AUTO_UPDATE": "1"},
                       capture_output=True, check=False)
    status = subprocess.run([sys.executable, os.path.join(HERE, "graceful-swap-fleet.py"), "--app", args.app,
                             "--tree", ROOT, "--out", out, "--runs", str(args.runs), "--films=", "--series", SERIES],
                            cwd=ROOT, env={**os.environ, "PATH": path, "CMUX_BENCH_LAUNCH": "direct"}).returncode
    receipts = []
    folder = os.path.join(out, "latency")
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        try:
            with open(os.path.join(folder, name)) as f:
                receipts.append(json.load(f))
        except (OSError, ValueError):
            continue
    shutil.rmtree(scratch, ignore_errors=True)  # this run's own bun scratch folder
    rows, incomplete = rows_from(receipts)
    report = {"rows": rows, "bench_status": status, "series": SERIES, "runs": args.runs}
    if incomplete:
        report["incomplete"] = incomplete
    with open(args.json, "w") as f:
        json.dump(report, f, indent=1)
    for r in rows:
        print(f"graceful-swap: {r['name']} = {r['p95']} {r['unit']} (budget {r['budget']})")
    for why in incomplete:
        print(f"graceful-swap: incomplete: {why}")
    # The cron reads report.json only from a step that exits 0: an invalid run still stores its red count rows.
    return 0 if rows else 1


if __name__ == "__main__":
    raise SystemExit(main())

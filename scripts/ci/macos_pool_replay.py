#!/usr/bin/env python3
"""Replay the macos_15 pool choice (runner_pools.reconcile()) over saved janitor macos-pool-load snapshots.

This is the data behind runner_pools.SLOW_SPILL_MINUTES (cmux#65148): 29 snapshots from 2026-11-27 18:17Z to
2026-11-28 16:15Z, kept in tests/fixtures/macos-pool-load-replay.json, where the median wait a new swift-check
job queues behind falls from 21 to 3 min at bound 20. tests/test_ci_runner_pools.py replays the fixture, so a change to
the slow rule shows its before -> after here.

  python3 scripts/ci/macos_pool_replay.py replay [FIXTURE] [--bound N ...] [--table]
  python3 scripts/ci/macos_pool_replay.py reduce SNAPDIR... > FIXTURE

`reduce` reads macos-pool-load.json in each artifact directory (downloaded janitor artifacts; read as data only) and
keeps what the replay reads: the time, the truncation fields and the Blacksmith macOS labels' queue counts. It drops
runner names and every other label.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import statistics
import sys
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import runner_pools  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "tests" / "fixtures" / "macos-pool-load-replay.json"
POOL = "macos_15"
SLOW, OTHER = "blacksmith-6vcpu-macos-15", "blacksmith-6vcpu-macos-26"
KEPT = ("generated_at", "truncated", "listed", "total", "total_at_least")
LOAD_KEPT = ("queued", "running", "oldest_queued_minutes")


def reduce(snapshot: Mapping[str, Any]) -> dict[str, Any]:
    """`snapshot` with only what the replay reads."""
    kept = {key: snapshot[key] for key in KEPT if key in snapshot}
    kept["pools"] = {label: {key: load[key] for key in LOAD_KEPT if key in load}
                     for label, load in sorted((snapshot.get("pools") or {}).items())
                     if runner_pools.SLOW_SPILL.match(label) and isinstance(load, Mapping)}
    return kept


def wait(snapshot: Mapping[str, Any], label: str) -> float:
    """The oldest queued job's wait on `label`, 0 with nothing queued."""
    load = (snapshot.get("pools") or {}).get(label) or {}
    return float(load.get("oldest_queued_minutes") or 0) if int(load.get("queued") or 0) else 0.0


def replay(snapshots: Iterable[Mapping[str, Any]], pools: Mapping[str, Mapping[str, Any]],
           bound: float) -> dict[str, Any]:
    """Run reconcile() over `snapshots` in time order at SLOW_SPILL_MINUTES = `bound`, each read 1 min after it was
    written. "before" is the wait on the macOS 15 label, "after" the wait on the label the pool names."""
    ordered = sorted(snapshots, key=lambda snapshot: snapshot["generated_at"])
    saved = runner_pools.SLOW_SPILL_MINUTES
    runner_pools.SLOW_SPILL_MINUTES = bound
    try:
        current: Mapping[str, Any] = {}
        rows = []
        for snapshot in ordered:
            now = runner_pools.parse_time(snapshot["generated_at"]) + dt.timedelta(minutes=1)
            value, _ = runner_pools.reconcile(current, pools, dead_now=(), served_now=(), now=now, covered=None,
                                              waits=runner_pools.slow_waits(snapshot, now=now))
            rows.append({"at": snapshot["generated_at"], "slow": wait(snapshot, SLOW), "other": wait(snapshot, OTHER),
                         "chosen": value[POOL], "after": wait(snapshot, value[POOL])})
            current = value
    finally:
        runner_pools.SLOW_SPILL_MINUTES = saved
    before = [row["slow"] for row in rows]
    after = [row["after"] for row in rows]
    return {"bound": bound, "snapshots": len(rows), "spilled": sum(row["chosen"] == OTHER for row in rows),
            "median_before": statistics.median(before), "median_after": statistics.median(after),
            "mean_before": statistics.mean(before), "mean_after": statistics.mean(after), "rows": rows}


def load(path: Path = FIXTURE) -> dict[str, Any]:
    return json.loads(path.read_text())


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("replay", help="print the before -> after per bound")
    run.add_argument("fixture", nargs="?", type=Path, default=FIXTURE)
    run.add_argument("--bound", type=float, action="append", help="SLOW_SPILL_MINUTES to try (repeatable)")
    run.add_argument("--table", action="store_true", help="print each snapshot's choice at the first bound")
    cut = sub.add_parser("reduce", help="write a fixture from janitor artifact directories")
    cut.add_argument("dirs", nargs="+", type=Path)
    args = parser.parse_args(argv)
    if args.command == "reduce":
        snapshots = [reduce(json.loads((d / "macos-pool-load.json").read_text())) for d in args.dirs]
        snapshots.sort(key=lambda snapshot: snapshot["generated_at"])
        pools = {POOL: {"members": runner_pools.members(runner_pools.load_pools()[POOL])}}
        json.dump({"pools": pools, "snapshots": snapshots}, sys.stdout, indent=1, sort_keys=True)
        print()
        return 0
    data = load(args.fixture)
    for bound in args.bound or (10.0, 15.0, 20.0, 30.0):
        result = replay(data["snapshots"], data["pools"], bound)
        print(f"bound {bound:g}: spilled {result['spilled']}/{result['snapshots']}; median wait "
              f"{result['median_before']:.0f} -> {result['median_after']:.0f} min; mean "
              f"{result['mean_before']:.0f} -> {result['mean_after']:.0f} min")
    if args.table:
        for row in replay(data["snapshots"], data["pools"], (args.bound or [20.0])[0])["rows"]:
            print(f"{row['at'][5:16]} m15 {row['slow']:5.0f} m26 {row['other']:4.0f} -> {row['chosen']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

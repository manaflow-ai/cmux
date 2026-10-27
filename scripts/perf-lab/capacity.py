#!/usr/bin/env python3
"""Builder capacity: utilization and queue age of the bench build queue (p12-perf-process.md 3.11, task 234).

    python3 -I scripts/perf-lab/lab.py capacity [--since 24h] [--json]

From the build queue's state (build_queue.py) and the builders in pool.json:

- per builder: busy seconds in the window (each step's wall time, cut to the window; a running step counts up to
  now), utilization = busy / window, jobs by outcome, and build seconds of incremental and clean builds;
- the queue: open jobs by class, the age of the oldest queued job of each class, and the wait from queued to
  started (p50, p95, max) of the jobs started in the window;
- the T0 mode the scheduler picks from it: every-2nd-batch while more than scheduler.EVERY_SECOND_QUEUE requested
  builds are held (per-commit builds do not count).

Chrome's perf dashboard reports bot utilization and pending-task age per pool the same way (Swarming's bot and
task-pending metrics, luci-py appengine/swarming/server/ts_mon_metrics.py). Stdlib only; `python3 -I`.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from collections.abc import Sequence
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _sibling(name: str):
    module_name = f"perf_lab_{name}"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


build_queue = _sibling("build_queue")
scheduler = _sibling("scheduler")


def _overlap(start: datetime, end: datetime, window_start: datetime, now: datetime) -> float:
    return max(0.0, (min(end, now) - max(start, window_start)).total_seconds())


def report(state, builders: Sequence[str], now: datetime, window: timedelta) -> dict:
    """The capacity report of a build_queue.QueueState over the `window` that ends at `now`."""
    parse = build_queue.parse_stamp
    window_start = now - window
    per_builder = {name: {"busy_s": 0.0, "jobs": {}, "incremental_s": [], "clean_s": []} for name in builders}
    waits: dict[str, list[float]] = {}
    for job in state.jobs:
        if job.started_at is None or job.builder is None:
            continue
        started = parse(job.started_at)
        ended = parse(job.ended_at) if job.ended_at else now
        if ended < window_start:
            continue
        row = per_builder.setdefault(job.builder, {"busy_s": 0.0, "jobs": {}, "incremental_s": [], "clean_s": []})
        row["busy_s"] += _overlap(started, ended, window_start, now)
        row["jobs"][job.state] = row["jobs"].get(job.state, 0) + 1
        if job.state == build_queue.DONE and not job.cached and job.seconds is not None:
            row["incremental_s" if job.incremental else "clean_s"].append(job.seconds)
        if started >= window_start:
            waits.setdefault(job.kind, []).append((started - parse(job.enqueued_at)).total_seconds())
    seconds = window.total_seconds()
    builders_out = {}
    for name, row in sorted(per_builder.items()):
        builders_out[name] = {
            "busy_s": int(row["busy_s"]), "utilization": round(row["busy_s"] / seconds, 4) if seconds else None,
            "jobs": dict(sorted(row["jobs"].items())),
            "incremental_build_s": build_queue.summary(row["incremental_s"]),
            "clean_build_s": build_queue.summary(row["clean_s"]),
        }
    open_jobs = [job for job in state.jobs if job.state in build_queue.OPEN]
    depth: dict[str, dict[str, int]] = {}
    oldest: dict[str, int] = {}
    for job in open_jobs:
        depth.setdefault(job.kind, {}).setdefault(job.state, 0)
        depth[job.kind][job.state] += 1
        if job.state == build_queue.QUEUED:
            age = int((now - parse(job.enqueued_at)).total_seconds())
            oldest[job.kind] = max(oldest.get(job.kind, 0), age)
    requested = sum(1 for job in open_jobs if job.kind != "backfill")
    total = sum(row["busy_s"] for name, row in per_builder.items() if name in builders)
    return {
        "now": build_queue.stamp(now), "window_s": int(seconds),
        "utilization": round(total / (seconds * len(builders)), 4) if builders and seconds else None,
        "builders": builders_out,
        "queue": {"depth": {kind: depth[kind] for kind in build_queue.KINDS if kind in depth},
                  "oldest_queued_age_s": {kind: oldest[kind] for kind in build_queue.KINDS if kind in oldest},
                  "wait_s": {kind: build_queue.summary(waits[kind]) for kind in build_queue.KINDS if kind in waits},
                  "requested": requested},
        "t0_mode": "every-2nd-batch" if requested > scheduler.EVERY_SECOND_QUEUE else "every-batch",
    }


def format_report(doc: dict) -> str:
    hours = doc["window_s"] / 3600
    util = doc["utilization"]
    lines = [f"builders over the last {hours:g} h: utilization {'-' if util is None else f'{util:.0%}'}, "
             f"T0 {doc['t0_mode']}"]
    for name, row in doc["builders"].items():
        jobs = ", ".join(f"{n} {state}" for state, n in row["jobs"].items()) or "no jobs"
        line = f"  {name}: {row['utilization']:.0%} busy ({row['busy_s']} s), {jobs}"
        for label, key in (("incremental", "incremental_build_s"), ("clean", "clean_build_s")):
            if row[key]:
                line += f"; {label} build p50 {row[key]['p50']} s (n {row[key]['n']})"
        lines.append(line)
    queue = doc["queue"]
    depth = ", ".join(f"{kind} {sum(states.values())}" for kind, states in queue["depth"].items()) or "empty"
    lines.append(f"queue: {depth}")
    for kind, age in queue["oldest_queued_age_s"].items():
        lines.append(f"  oldest queued {kind}: {age} s")
    for kind, wait in queue["wait_s"].items():
        lines.append(f"  {kind} wait to start: p50 {wait['p50']:g} s, p95 {wait['p95']:g} s, max {wait['max']:g} s "
                     f"(n {wait['n']})")
    return "\n".join(lines)


# ---------- command (lab.py protocol, task 005) ----------

LAB_COMMANDS = {"capacity": "Builder utilization and build queue age (task 234): [--since 24h] [--json]"}


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--data-dir", type=Path, default=build_queue.DATA_DIR)
    parser.add_argument("--state", type=Path, help="queue state (default DATA_DIR/build-queue.json)")
    parser.add_argument("--pool", type=Path, default=HERE / "pool.json")
    parser.add_argument("--since", default="24h")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--now", help=argparse.SUPPRESS)


def run(command: str, args: argparse.Namespace, out=None, err=None) -> int:
    out, err = out or sys.stdout, err or sys.stderr
    try:
        now = build_queue.parse_stamp(args.now) if args.now else datetime.now(timezone.utc)
        state = build_queue.load_state(args.state or args.data_dir / "build-queue.json")
        doc = report(state, build_queue.pool_builders(args.pool), now, build_queue.parse_window(args.since))
    except (build_queue.BuildQueueError, OSError, ValueError, KeyError) as error:
        print(f"capacity: {error}", file=err)
        return 2
    if args.json:
        json.dump(doc, out, indent=1)
        print(file=out)
    else:
        print(format_report(doc), file=out)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="capacity.py", description=LAB_COMMANDS["capacity"])
    add_arguments("capacity", parser)
    return run("capacity", parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())

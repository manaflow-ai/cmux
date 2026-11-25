#!/usr/bin/env python3
"""Measure a tagged cmux NEXT while the native Chief conversation is open."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_memory  # noqa: E402


def wait_for(app: bench_memory.App, predicate, seconds: float, step: float = 0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--minutes", type=int, default=10)
    parser.add_argument("--sample-seconds", type=int, default=60)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    if args.minutes < 1 or args.sample_seconds < 1:
        parser.error("minutes and sample-seconds must be positive")

    bundle = os.path.realpath(args.app)
    chief_home = tempfile.mkdtemp(prefix="chief-memory-", dir="/tmp")
    report = {
        "schema": "cmux-chief-memory/v1",
        "app": bundle,
        "minutes": args.minutes,
        "sample_seconds": args.sample_seconds,
        "started_at": time.time(),
        "samples": [],
    }
    pid = socket_path = scratch = None
    try:
        pid, socket_path, scratch = bench_memory.launch(
            bundle,
            {},
            {"CMUX_NEXT_CHIEF_HOME": chief_home},
        )
        app = bench_memory.App(bundle, socket_path)
        home = app.action("home.show", focus=True)
        geometry = wait_for(
            app,
            lambda: (app.call("debug.home.drive", {"action": "geometry"}, timeout=10) or {}).get("ok"),
            120,
        )
        chief = app.action("home.openChief", focus=True)
        state = app.call("debug.home", timeout=30)
        report["open"] = {"home": home, "geometry": bool(geometry), "chief": chief, "state": state}
        if not geometry:
            raise RuntimeError("Home composer did not become ready")
        print(f"CHIEF-MEMORY open geometry={bool(geometry)} action={json.dumps(chief, sort_keys=True)[:500]}", flush=True)

        started = time.monotonic()
        labels = ["open"] + [f"soak-{n}" for n in range(1, args.minutes + 1)]
        for index, label in enumerate(labels):
            if index:
                time.sleep(args.sample_seconds)
            result = bench_memory.sample(pid, bundle, label, 0)
            report["samples"].append(result)
            bench_memory.print_sample(result, top=12)
            print(
                f"CHIEF-MEMORY sample={label} elapsed_s={round(time.monotonic() - started, 1)} "
                f"footprint_mb={result['total_footprint_mb']} rss_mb={result['total_rss_mb']} "
                f"kinds={json.dumps(result['kinds'], sort_keys=True)}",
                flush=True,
            )
        report["finished_at"] = time.time()
        report["growth_mb"] = {
            kind: round(
                report["samples"][-1]["kinds"].get(kind, {}).get("footprint_mb", 0)
                - report["samples"][0]["kinds"].get(kind, {}).get("footprint_mb", 0),
                1,
            )
            for kind in sorted(
                set(report["samples"][0]["kinds"]) | set(report["samples"][-1]["kinds"])
            )
        }
        return 0
    finally:
        if pid is not None:
            bench_memory.end_bundle(bundle)
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)
        shutil.rmtree(chief_home, ignore_errors=True)
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=1)


if __name__ == "__main__":
    raise SystemExit(main())

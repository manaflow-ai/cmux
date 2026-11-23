#!/usr/bin/env python3
"""Gate the labelled FrameIntervalStats JSONL from cmux-next-ios-sim.sh test ui=AnimationFrameBenchUITests."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

ANIMATIONS = (
    "composer-grow", "keyboard-show", "keyboard-hide", "workspace-enter", "workspace-exit",
    "sheet-present", "sheet-dismiss", "tab-overview-zoom", "jump-to-bottom", "composer-typing",
)
CPU_BUDGET_MS = 1000 / 120
MAX_DROPS = 2


def measure(stats: dict) -> dict:
    def number(key):
        value = stats[key]
        if type(value) not in (float, int) or not math.isfinite(value) or value <= 0:
            raise ValueError(f"invalid {key}")
        return value

    frames = stats["frames"]
    cpu = stats["mainThreadCPUPerFrameMs"]
    if type(frames) is not int or frames < 2 or not isinstance(cpu, list) or len(cpu) != frames:
        raise ValueError("need a main-thread CPU sample for each recorded frame and at least two frames")
    if any(type(ms) not in (float, int) or not math.isfinite(ms) or ms < 0 for ms in cpu):
        raise ValueError("invalid main-thread CPU samples")
    dropped = stats["droppedFrames"]
    if type(dropped) is not int or dropped < 0:
        raise ValueError("invalid droppedFrames")
    p50, p95, maximum = (number(key) for key in ("p50Ms", "p95Ms", "maxMs"))
    if not p50 <= p95 <= maximum:
        raise ValueError("inconsistent interval percentiles")
    expected = number("expectedMs")
    cpu_p95 = sorted(cpu)[math.ceil(frames * 0.95) - 1]  # Same nearest rank as FrameIntervalStats.
    failures = []
    if cpu_p95 > CPU_BUDGET_MS:
        failures.append(f"CPU p95 {cpu_p95:.2f} ms exceeds {CPU_BUDGET_MS:.2f} ms")
    if dropped > MAX_DROPS:
        failures.append(f"{dropped} dropped frames exceeds {MAX_DROPS}")
    return {
        "frames": frames, "p50_ms": p50, "p95_ms": p95, "max_ms": maximum, "dropped_frames": dropped,
        "expected_ms": expected, "nominal_hz": round(1000 / expected, 2),
        "display_maximum_hz": number("displayMaximumHz"), "main_thread_cpu_p95_ms": cpu_p95,
        "main_thread_cpu_max_ms": max(cpu), "failures": failures,
    }


def read_run(evidence: Path, profile: str) -> tuple[list[dict], list[str]]:
    slug = profile.replace(",", "_").replace("=", "_")
    path = evidence / f"ui-duress-{slug}-framelog.jsonl"
    if profile == "off" and not path.exists():
        path = evidence / "ui-framelog.jsonl"
    expected = ("composer-typing",) if profile == "heavy" else ANIMATIONS
    windows = {name: [] for name in expected}
    errors = []
    try:
        with path.open(encoding="utf-8") as source:
            for line_no, line in enumerate(source, 1):
                stats = json.loads(line)
                if not isinstance(stats, dict) or not isinstance(stats.get("label"), str):
                    raise ValueError(f"invalid window on line {line_no}")
                if stats["label"] in windows:  # Other FrameIntervalLog consumers share the cache.
                    windows[stats["label"]].append(stats)
    except (OSError, ValueError) as error:
        errors.append(f"{path.name}: {error}")

    rows = []
    for name, samples in windows.items():
        row = {"animation": name, "profile": profile}
        try:
            if len(samples) != 1:
                raise ValueError(f"expected one window, found {len(samples)}")
            row.update(measure(samples[0]))
        except (KeyError, ValueError, TypeError) as error:
            row["failures"] = [str(error)]
        row["gate"] = "fail" if row["failures"] else "pass"
        errors.extend(f"{profile}/{name}: {reason}" for reason in row["failures"])
        rows.append(row)
    return rows, errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--run", action="append", metavar="PROFILE")
    parser.add_argument("--model", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--sha", required=True)
    args = parser.parse_args()
    rows, errors = [], []
    for profile in args.run or ["off"]:
        if not profile or "/" in profile:
            parser.error("invalid profile")
        windows, failures = read_run(args.evidence, profile)
        rows.extend(windows)
        errors.extend(failures)
    if not args.model.strip() or not args.runtime.strip():
        errors.append("missing simulator model or runtime")

    report = {
        "head": args.sha, "measured_on": {"simulator_model": args.model, "runtime": args.runtime},
        "cpu_p95_budget_ms": CPU_BUDGET_MS, "max_dropped_frames_per_window": MAX_DROPS,
        "animations": rows, "gate": "fail" if errors else "pass", "failures": errors,
    }
    args.out.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(f"Measured on {args.model} ({args.runtime}), head `{args.sha}`.\n")
    print("| Animation | Load | Frames | p50 / p95 / max (ms) | Dropped | Nominal ms | Screen max Hz | CPU p95 ms | Gate |")
    print("|---|---|---:|---|---:|---:|---:|---:|---|")
    for row in rows:
        if "frames" in row:
            metrics = (f"{row['frames']} | {row['p50_ms']:.2f} / {row['p95_ms']:.2f} / {row['max_ms']:.2f} | "
                       f"{row['dropped_frames']} | {row['expected_ms']:.2f} | {row['display_maximum_hz']:g} | "
                       f"{row['main_thread_cpu_p95_ms']:.2f}")
        else:
            metrics = "— | — | — | — | — | —"
        print(f"| {row['animation']} | {row['profile']} | {metrics} | {row['gate']} |")
    for error in errors:
        print(f"\n- {error}")
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())

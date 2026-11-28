#!/usr/bin/env python3
"""Gate labelled FrameIntervalStats XCTest attachments from a fleet simulator evidence.zip."""
from __future__ import annotations

import argparse
import json
import math
import re
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
    folder = evidence / f"ui-duress-{profile}-attachments"
    if profile == "off" and not folder.exists():
        folder = evidence / "ui-attachments"
    # Heavy XCTest emits a distinct mark only on the path that verifies active replay.
    expected = ("composer-typing-heavy",) if profile == "heavy" else ANIMATIONS
    windows = {name: [] for name in expected}
    errors = []
    try:
        manifest = json.loads((folder / "manifest.json").read_text())
        entries = manifest if isinstance(manifest, list) else [manifest]
        for entry in entries:
            for attachment in entry["attachments"]:
                # Xcode can add _<index>_<UUID> to the suggested name when
                # exporting an attachment (the exported filename is opaque).
                name = attachment.get("suggestedHumanReadableName", "")
                match = re.fullmatch(
                    r"animation-frame-([a-z-]+)(?:\.json)?(?:_\d+_[a-fA-F0-9-]{36})?(?:\.json)?", name
                )
                if not match or match[1] not in windows:
                    continue
                label = match[1]
                filename = attachment["exportedFileName"]
                if not isinstance(filename, str) or Path(filename).name != filename:
                    raise ValueError(f"{name}: invalid exported filename")
                try:
                    stats = json.loads((folder / filename).read_text())
                    if not isinstance(stats, dict) or stats.get("label") != label:
                        raise ValueError("stats label differs from attachment name")
                    windows[label].append(stats)
                except (OSError, ValueError) as error:
                    errors.append(f"{folder.name}/{name}: {error}")
    except (KeyError, OSError, TypeError, ValueError) as error:
        errors.append(f"{folder.name}/manifest.json: {error}")

    rows = []
    for name, samples in windows.items():
        row = {"animation": name.removesuffix("-heavy"), "profile": profile}
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


def simulator_identity(evidence, sha, model, runtime):
    summary_path = evidence / "SUMMARY.md"
    errors = []
    if summary_path.exists():
        lines = summary_path.read_text().splitlines()
        for line in lines:
            if line.startswith("- commit: "):
                observed = line.removeprefix("- commit: ").strip()
                if observed != sha:
                    errors.append(f"SUMMARY.md measured commit {observed}, expected {sha}")
            elif line.startswith("- simulator: "):
                device_type, on, version = line.removeprefix("- simulator: ").partition(" on ")
                if on:
                    model = model or device_type.strip()
                    runtime = version.strip()
            elif line.startswith("- device: "):
                model = line.removeprefix("- device: ").split(" (", 1)[0].strip()
    if not model or not runtime:
        errors.append("missing simulator model or runtime in SUMMARY.md or --model/--runtime")
    return {"simulator_model": model, "runtime": runtime}, errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--run", action="append", choices=("off", "heavy"))
    parser.add_argument("--model")
    parser.add_argument("--runtime")
    parser.add_argument("--sha", required=True)
    args = parser.parse_args()
    measured_on, errors = simulator_identity(args.evidence, args.sha, args.model, args.runtime)
    rows = []
    for profile in args.run or ["off"]:
        windows, failures = read_run(args.evidence, profile)
        rows.extend(windows)
        errors.extend(failures)

    report = {
        "head": args.sha, "measured_on": measured_on,
        "cpu_p95_budget_ms": CPU_BUDGET_MS, "max_dropped_frames_per_window": MAX_DROPS,
        "animations": rows, "gate": "fail" if errors else "pass", "failures": errors,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(f"Measured on {measured_on['simulator_model']} ({measured_on['runtime']}), head `{args.sha}`.\n")
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

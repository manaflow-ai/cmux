#!/usr/bin/env python3
"""Produce a compact, non-authoritative receipt from Xcode build logs."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
import os
from pathlib import Path
import platform
import re
import subprocess
from typing import Iterable


TARGET_RE = re.compile(r"\(in target '([^']+)' from project '[^']+'\)")
SWIFT_COMPILE_RE = re.compile(r"^SwiftCompile\s+.*\bCompiling(?:\\ |\s)")
SWIFT_EMIT_RE = re.compile(r"^(?:SwiftEmitModule|SwiftDriverJobDiscovery\s+.*\bEmitting module)")
TIMING_RE = re.compile(
    r"^\s*(.+?)(?:\s+\(\d+\s+tasks?\)\s+\|)?\s+"
    r"([0-9]+(?:\.[0-9]+)?) seconds\s*$"
)
CACHE_VALUES = {"Cache hit": "hit", "Cache miss": "miss"}


def command_output(*argv: str) -> str | None:
    try:
        return subprocess.check_output(argv, text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def nearest_target(lines: list[str], index: int, radius: int = 4) -> str | None:
    # Cache remarks may appear immediately before or after the Xcode action line.
    # Choose the nearest action; when both sides are equally close, prefer the
    # preceding action. This avoids attaching a leading cache remark to an older
    # target when the action it describes follows on the next line.
    for distance in range(1, radius + 1):
        for direction in (-1, 1):
            candidate = index + direction * distance
            if candidate < 0 or candidate >= len(lines):
                continue
            line = lines[candidate].strip()
            if not line:
                continue
            match = TARGET_RE.search(line)
            if match:
                return match.group(1)
    return None


def timing_summary(lines: Iterable[str]) -> dict[str, float]:
    in_summary = False
    values: dict[str, float] = {}
    for raw in lines:
        line = raw.rstrip()
        if line.strip() == "Build Timing Summary":
            in_summary = True
            continue
        if not in_summary:
            continue
        if line.startswith("** ") or line.startswith("Build settings from"):
            in_summary = False
            continue
        match = TIMING_RE.match(line)
        if match:
            values[match.group(1).strip()] = float(match.group(2))
    return values


def parse_log(path: Path) -> dict[str, object]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    cache = Counter()
    cache_by_target: dict[str, Counter[str]] = defaultdict(Counter)
    swift_compile_by_target = Counter()
    swift_emit_by_target = Counter()

    for index, raw in enumerate(lines):
        line = raw.strip()
        for marker, outcome in CACHE_VALUES.items():
            if line == marker:
                cache[outcome] += 1
                target = nearest_target(lines, index)
                cache_by_target[target or "<unattributed>"][outcome] += 1
                break

        target_match = TARGET_RE.search(line)
        target = target_match.group(1) if target_match else None
        if target:
            if SWIFT_COMPILE_RE.match(line):
                swift_compile_by_target[target] += 1
            if SWIFT_EMIT_RE.match(line):
                swift_emit_by_target[target] += 1

    targets: dict[str, object] = {}
    names = set(cache_by_target) | set(swift_compile_by_target) | set(swift_emit_by_target)
    for target in sorted(names):
        targets[target] = {
            "cache_hits": cache_by_target[target]["hit"],
            "cache_misses": cache_by_target[target]["miss"],
            "swift_compile_events": swift_compile_by_target[target],
            "swift_emit_module_events": swift_emit_by_target[target],
        }

    return {
        "path": path.name,
        "bytes": path.stat().st_size,
        "cache_hits": cache["hit"],
        "cache_misses": cache["miss"],
        "swift_compile_events": sum(swift_compile_by_target.values()),
        "swift_emit_module_events": sum(swift_emit_by_target.values()),
        "timing_summary_seconds": timing_summary(lines),
        "targets": targets,
    }


def aggregate(schemes: list[dict[str, object]]) -> dict[str, object]:
    totals = Counter()
    targets: dict[str, Counter[str]] = defaultdict(Counter)
    timing = Counter()

    for scheme in schemes:
        for key in ("cache_hits", "cache_misses", "swift_compile_events", "swift_emit_module_events"):
            totals[key] += int(scheme[key])
        for name, seconds in dict(scheme["timing_summary_seconds"]).items():
            timing[name] += float(seconds)
        for target, values in dict(scheme["targets"]).items():
            for key, value in dict(values).items():
                targets[target][key] += int(value)

    return {
        **dict(totals),
        "timing_summary_seconds": dict(sorted(timing.items())),
        "targets": {
            target: dict(values)
            for target, values in sorted(
                targets.items(),
                key=lambda item: (
                    -item[1]["swift_compile_events"],
                    -item[1]["cache_misses"],
                    item[0],
                ),
            )
        },
    }


def discover_activity_logs(derived_data: Path) -> list[dict[str, object]]:
    root = derived_data / "Logs" / "Build"
    if not root.is_dir():
        return []
    result = []
    for path in sorted(root.glob("*.xcactivitylog")):
        try:
            size = path.stat().st_size
        except OSError:
            continue
        result.append({"name": path.name, "bytes": size})
    return result


def git_output(*args: str) -> str | None:
    return command_output("git", *args)


def build_receipt(
    derived_data: Path,
    compile_seconds: float | None,
    compile_outcome: str | None = None,
) -> dict[str, object]:
    scheme_logs = sorted(derived_data.glob("*-build.log"))
    schemes = [parse_log(path) for path in scheme_logs]

    xcode = command_output("xcodebuild", "-version")
    sdk_version = command_output("xcrun", "--sdk", "macosx", "--show-sdk-version")
    sdk_build = command_output("xcrun", "--sdk", "macosx", "--show-sdk-build-version")

    return {
        "schema_version": 1,
        "source": {
            "revision": os.environ.get("GITHUB_SHA") or git_output("rev-parse", "HEAD"),
            "tree": git_output("rev-parse", "HEAD^{tree}"),
        },
        "toolchain": {
            "xcode": xcode,
            "macos_sdk_version": sdk_version,
            "macos_sdk_build": sdk_build,
        },
        "runner": {
            "name": os.environ.get("RUNNER_NAME"),
            "os": os.environ.get("RUNNER_OS") or platform.system(),
            "arch": os.environ.get("RUNNER_ARCH") or platform.machine(),
        },
        "compile_wall_seconds": compile_seconds,
        "compile_outcome": compile_outcome,
        "derived_data_log_count": len(schemes),
        "activity_logs": discover_activity_logs(derived_data),
        "schemes": schemes,
        "aggregate": aggregate(schemes),
    }


def write_summary(receipt: dict[str, object], stream) -> None:
    aggregate_values = dict(receipt["aggregate"])
    print("### Xcode build metrics", file=stream)
    print(file=stream)
    print(f"- compile wall seconds: `{receipt.get('compile_wall_seconds')}`", file=stream)
    print(f"- cache hits: `{aggregate_values.get('cache_hits', 0)}`", file=stream)
    print(f"- cache misses: `{aggregate_values.get('cache_misses', 0)}`", file=stream)
    print(f"- SwiftCompile events: `{aggregate_values.get('swift_compile_events', 0)}`", file=stream)
    print(f"- Swift emit-module events: `{aggregate_values.get('swift_emit_module_events', 0)}`", file=stream)
    targets = dict(aggregate_values.get("targets", {}))
    if targets:
        print("- top targets by SwiftCompile events:", file=stream)
        for target, values in list(targets.items())[:8]:
            data = dict(values)
            print(
                f"  - `{target}`: compile={data.get('swift_compile_events', 0)}, "
                f"cache hit={data.get('cache_hits', 0)}, miss={data.get('cache_misses', 0)}",
                file=stream,
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("derived_data", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compile-seconds", type=float)
    parser.add_argument("--compile-outcome")
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()

    receipt = build_receipt(
        args.derived_data,
        args.compile_seconds,
        compile_outcome=args.compile_outcome,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if args.summary:
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        with args.summary.open("a", encoding="utf-8") as stream:
            write_summary(receipt, stream)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Decide whether a host is too busy for the launch-time budget probe.

The launch probe measures an app's first frame. A host-wide load spike can
make that measurement fail before the app is meaningfully exercised. Record
the host load and skip the probe for that run; the compile remains a required
check and the next run gets a fresh measurement.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path


def threshold(cpu_count: int | None) -> int:
    """Return a conservative one-minute-load threshold for the host."""
    return max(16, (cpu_count or 0) * 2)


def should_skip(load1: float | None, cpu_count: int | None) -> bool:
    """Skip only when a known load is above the host's bounded threshold."""
    return load1 is not None and load1 > threshold(cpu_count)


def read_load() -> tuple[float | None, int | None]:
    try:
        load1 = float(os.getloadavg()[0])
    except (AttributeError, OSError, ValueError):
        load1 = None
    try:
        cpu_count = os.cpu_count()
    except (OSError, ValueError):
        cpu_count = None
    return load1, cpu_count


def write_receipt(path: str, load1: float | None, cpu_count: int | None, skip: bool) -> None:
    if not path:
        return
    value = "unknown" if load1 is None else f"{load1:.2f}"
    cpus = "unknown" if cpu_count is None else str(cpu_count)
    limit = threshold(cpu_count)
    with Path(path).open("a", encoding="utf-8") as output:
        output.write(f"skip={'true' if skip else 'false'}\n")
        output.write(f"load1={value}\n")
        output.write(f"cpu_count={cpus}\n")
        output.write(f"threshold={limit}\n")


def write_summary(path: str, load1: float | None, cpu_count: int | None, skip: bool) -> None:
    if not path:
        return
    value = "unknown" if load1 is None else f"{load1:.2f}"
    cpus = "unknown" if cpu_count is None else str(cpu_count)
    limit = threshold(cpu_count)
    action = "skipped launch-time budget; compile result remains required" if skip else "running launch-time budget"
    with Path(path).open("a", encoding="utf-8") as output:
        output.write("### Launch budget host-load gate\n\n")
        output.write(f"- load1: `{value}`\n- CPUs: `{cpus}`\n- threshold: `{limit}`\n- action: {action}\n")


def main(argv: list[str] | None = None, *, environ: dict[str, str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", help="GitHub output file (defaults to GITHUB_OUTPUT)")
    parser.add_argument("--summary", help="step summary file (defaults to GITHUB_STEP_SUMMARY)")
    args = parser.parse_args(argv)
    env = os.environ if environ is None else environ
    load1, cpu_count = read_load()
    skip = should_skip(load1, cpu_count)
    write_receipt(args.output or env.get("GITHUB_OUTPUT", ""), load1, cpu_count, skip)
    write_summary(args.summary or env.get("GITHUB_STEP_SUMMARY", ""), load1, cpu_count, skip)
    print(f"launch budget: load1={load1 if load1 is not None else 'unknown'} "
          f"cpus={cpu_count if cpu_count is not None else 'unknown'} "
          f"threshold={threshold(cpu_count)} skip={str(skip).lower()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Run one declared Python regression lane."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from test_execution_registry import load_registry


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "tests" / "test-execution.toml"
NON_RUNNABLE_LANES = {"legacy", "manual"}
SUPPORTED_REQUIREMENTS = {"cmux-cli", "fish"}


def environment_for(entry: dict[str, object]) -> dict[str, str]:
    requirements = entry.get("requirements", [])
    if not isinstance(requirements, list) or not all(isinstance(value, str) for value in requirements):
        raise SystemExit(f"{entry.get('path')}: requirements must be a list of strings")
    unknown = sorted(set(requirements) - SUPPORTED_REQUIREMENTS)
    if unknown:
        raise SystemExit(f"{entry.get('path')}: unsupported requirements: {', '.join(unknown)}")

    env = os.environ.copy()
    if "cmux-cli" in requirements:
        cli = env.get("CMUX_CLI_BIN", "")
        if not cli:
            raise SystemExit(f"{entry.get('path')}: lane requires CMUX_CLI_BIN")
        if not Path(cli).is_file():
            raise SystemExit(f"{entry.get('path')}: CMUX_CLI_BIN does not exist: {cli}")
    else:
        env.pop("CMUX_CLI_BIN", None)

    if "fish" in requirements and shutil.which("fish", path=env.get("PATH")) is None:
        raise SystemExit(f"{entry.get('path')}: lane requires fish on PATH")
    return env


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lane", required=True)
    parser.add_argument("--list", action="store_true", help="print lane members without executing them")
    args = parser.parse_args(argv)

    if args.lane in NON_RUNNABLE_LANES:
        raise SystemExit(f"{args.lane!r} is inventory, not an executable lane")

    try:
        entries = load_registry(MANIFEST)
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error

    tests = [entry for entry in entries if entry.get("lane") == args.lane]
    if not tests:
        raise SystemExit(f"no tests registered for lane {args.lane!r}")

    for entry in tests:
        path = entry.get("path")
        if not isinstance(path, str):
            raise SystemExit(f"lane {args.lane!r} contains an entry without a string path")
        if args.list:
            print(path)
            continue

        print(f"==> {path}", flush=True)
        result = subprocess.run(
            [sys.executable, str(ROOT / path)],
            cwd=ROOT,
            env=environment_for(entry),
            check=False,
        )
        if result.returncode != 0:
            return result.returncode

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

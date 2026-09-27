#!/usr/bin/env python3
"""Run declared Python regression lanes.

Each test runs as its own process with a private TMPDIR, so tests that use the
default temporary directory never share files or sockets. With `--jobs N`
the lane runs N tests at a time; entries marked `serial = true` in the
registry run first, alone, because they assert wall-clock bounds that a busy
machine could miss. Every test runs even after a failure so one red run names
every failing file, and each test's output prints as one block when it ends.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

from test_execution_registry import load_registry


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "tests" / "test-execution.toml"
NON_RUNNABLE_LANES = {"legacy", "manual"}
SUPPORTED_REQUIREMENTS = {"cmux-cli", "fish"}
# Short on purpose: tests bind Unix sockets under TMPDIR, and macOS caps a
# socket path at 104 bytes.
TMP_BASE = "/tmp"


@dataclass
class Result:
    path: str
    returncode: int
    seconds: float
    output: str


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


def run_one(path: str, env: dict[str, str], tmpdir: Path) -> Result:
    tmpdir.mkdir()
    env = {**env, "TMPDIR": f"{tmpdir}/"}
    started = time.monotonic()
    try:
        completed = subprocess.run(
            [sys.executable, str(ROOT / path)],
            cwd=ROOT,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            check=False,
        )
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return Result(path, completed.returncode, time.monotonic() - started, completed.stdout)


def report(result: Result) -> None:
    status = "ok" if result.returncode == 0 else f"FAILED (exit {result.returncode})"
    sys.stdout.write(f"==> {result.path} {status} in {result.seconds:.1f}s\n")
    sys.stdout.write(result.output)
    if result.output and not result.output.endswith("\n"):
        sys.stdout.write("\n")
    sys.stdout.flush()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lane", action="append", required=True, help="lane to run; repeat to run several together")
    parser.add_argument("--jobs", type=int, default=1, help="tests to run at once (serial entries always run alone)")
    parser.add_argument("--list", action="store_true", help="print lane members without executing them")
    args = parser.parse_args(argv)
    if args.jobs < 1:
        raise SystemExit("--jobs must be at least 1")

    for lane in args.lane:
        if lane in NON_RUNNABLE_LANES:
            raise SystemExit(f"{lane!r} is inventory, not an executable lane")

    try:
        entries = load_registry(MANIFEST)
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error

    tests: list[dict[str, object]] = []
    for lane in args.lane:
        members = [entry for entry in entries if entry.get("lane") == lane]
        if not members:
            raise SystemExit(f"no tests registered for lane {lane!r}")
        tests.extend(members)

    for entry in tests:
        if not isinstance(entry.get("path"), str):
            raise SystemExit(f"lane {entry.get('lane')!r} contains an entry without a string path")
    if args.list:
        for entry in tests:
            print(entry["path"])
        return 0

    # Resolve every environment before starting anything so a missing
    # requirement fails fast instead of after minutes of other tests.
    planned = [(str(entry["path"]), environment_for(entry), entry.get("serial") is True) for entry in tests]
    serial = [item for item in planned if item[2]]
    concurrent = [item for item in planned if not item[2]]

    base = Path(tempfile.mkdtemp(prefix="cmux-lane-", dir=TMP_BASE))
    started = time.monotonic()
    results: list[Result] = []
    try:
        index = 0

        def slot() -> Path:
            nonlocal index
            index += 1
            return base / f"{index:03d}"

        for path, env, _ in serial:
            result = run_one(path, env, slot())
            report(result)
            results.append(result)

        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = [pool.submit(run_one, path, env, slot()) for path, env, _ in concurrent]
            # Print in registry order so logs stay comparable between runs;
            # a slow early test only delays printing, not the others' work.
            for future in futures:
                result = future.result()
                report(result)
                results.append(result)
    finally:
        shutil.rmtree(base, ignore_errors=True)

    failed = [result for result in results if result.returncode != 0]
    print(
        f"==> {len(results)} tests in {time.monotonic() - started:.1f}s "
        f"(jobs={args.jobs}, serial={len(serial)}); {len(failed)} failed"
    )
    for result in failed:
        print(f"FAILED: {result.path} (exit {result.returncode})")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

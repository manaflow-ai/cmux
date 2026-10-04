#!/usr/bin/env python3
"""package-test-lane.sh suite PACKAGE FILTER: one Swift Testing filter of one package.

Lanes gate a change with one focused `swift test --filter` on a fleet worker
(`cmux-ci run`, coordinator decision 2026-10-04). The lane's other phases pick
packages from the diff and run whole packages, so a lane could not ask for one
suite of Packages/macOS/CmuxNext. A fake `swift` records the calls.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

FAKE_SWIFT = """#!/bin/bash
echo "swift $*" >> "$FAKE_SWIFT_LOG"
case "$1" in
  build) echo "Build complete!" ;;
  test)
    if [ -n "${FAKE_SWIFT_NO_TESTS:-}" ]; then echo "Build complete!"; exit 0; fi
    echo "✔ Test run with 2 tests in 1 suite passed after 0.001 seconds." ;;
esac
"""


def run(repo: Path, env: dict, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", "scripts/ci/package-test-lane.sh", *args], cwd=repo, env=env,
                          capture_output=True, text=True, timeout=120)


def main() -> int:
    scratch = Path(tempfile.mkdtemp(prefix="lane-suite-"))
    failures = []
    try:
        repo = scratch / "cmux"
        (repo / "scripts/ci").mkdir(parents=True)
        for name in ("package-test-lane.sh", "hung_test_watchdog.py", "require_swift_test_execution.py"):
            shutil.copy(ROOT / "scripts/ci" / name, repo / "scripts/ci" / name)
        pkg = repo / "Packages/macOS/Pkg"
        pkg.mkdir(parents=True)
        (pkg / "Package.swift").write_text("// swift-tools-version: 6.0\n")
        bin_dir = scratch / "bin"
        bin_dir.mkdir()
        (bin_dir / "swift").write_text(FAKE_SWIFT)
        (bin_dir / "swift").chmod(0o755)
        log = scratch / "swift.log"
        env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_SWIFT_LOG": str(log),
               "DEVELOPER_DIR": "/Applications/Xcode_26.6.app/Contents/Developer", "RUNNER_TEMP": str(scratch / "tmp")}
        (scratch / "tmp").mkdir()
        for name in ("GITHUB_OUTPUT", "GITHUB_ACTIONS", "EVENT_NAME", "FULL_SUITE"):
            env.pop(name, None)

        r = run(repo, env, "suite", "Packages/macOS/Pkg", "FooTests")
        calls = log.read_text() if log.exists() else ""
        if r.returncode != 0:
            failures.append(f"suite run failed ({r.returncode}): {r.stdout}{r.stderr}")
        if "swift build --build-tests --package-path Packages/macOS/Pkg" not in calls:
            failures.append(f"no build of the package: {calls!r}")
        if "swift test --package-path Packages/macOS/Pkg --skip-build --filter FooTests" not in calls:
            failures.append(f"no filtered test run: {calls!r}")

        # A filter that runs no test fails: an empty match is not a pass.
        log.write_text("")
        r = run(repo, {**env, "FAKE_SWIFT_NO_TESTS": "1"}, "suite", "Packages/macOS/Pkg", "NoSuchTests")
        if r.returncode == 0:
            failures.append("a filter that ran no tests passed")

        # Bad arguments are refused before any swift call.
        for args in (("suite", "Packages/macOS/Pkg"), ("suite", "../outside", "FooTests"),
                     ("suite", "Packages/macOS/Missing", "FooTests"), ("suite", "Packages/macOS/Pkg", "--skip-build")):
            log.write_text("")
            r = run(repo, env, *args)
            if r.returncode != 2 or log.read_text():
                failures.append(f"{args} was not refused before swift (exit {r.returncode}): {r.stderr}")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    for failure in failures:
        print("FAIL:", failure)
    if failures:
        return 1
    print("package-test-lane suite: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())

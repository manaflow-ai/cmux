#!/usr/bin/env python3
"""package-test-lane.sh suite PACKAGE FILTER[,FILTER...]: focused Swift Testing filters of one package after one build.

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
    filter="${@: -1}"
    if [ -n "${FAKE_SWIFT_FAIL_FILTER:-}" ] && [ "$filter" = "$FAKE_SWIFT_FAIL_FILTER" ]; then
      echo "✘ Test run with 1 test failed after 0.001 seconds with 1 issue."; exit 1
    fi
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
        (repo / "scripts").mkdir(parents=True)
        shutil.copytree(ROOT / "scripts/ci", repo / "scripts/ci")
        (repo / "scripts/cmux-next").mkdir()
        catalogs = repo / "scripts/cmux-next/compile-string-catalogs.sh"
        catalogs.write_text(f"#!/bin/bash\necho \"compile-string-catalogs cwd=$(pwd)\" >> {scratch / 'catalogs.log'}\n")
        catalogs.chmod(0o755)
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
        # swift build copies String Catalogs uncompiled; the lane compiles them into
        # <lang>.lproj tables before the tests, as cmux-next.yml does
        # (RefusalLocalizationTests and friends failed only on fleet workers).
        catalogs = (scratch / "catalogs.log").read_text() if (scratch / "catalogs.log").exists() else ""
        if "compile-string-catalogs cwd=" + str(pkg.resolve()) not in catalogs and "compile-string-catalogs cwd=" + str(pkg) not in catalogs:
            failures.append(f"string catalogs were not compiled in the package: {catalogs!r}")
        elif calls.index("--build-tests") > calls.index("--filter FooTests"):
            failures.append("the build ran after the tests")

        # A filter that runs no test fails: an empty match is not a pass.
        log.write_text("")
        r = run(repo, {**env, "FAKE_SWIFT_NO_TESTS": "1"}, "suite", "Packages/macOS/Pkg", "NoSuchTests")
        if r.returncode == 0:
            failures.append("a filter that ran no tests passed")

        # Several suites in one step: one build, then one `swift test` per suite, so a
        # lane's whole gate shares one cold build (coordinator, 2026-10-04: the light
        # queue held ~67 one-suite steps, each with its own 4-5 min CmuxNext build).
        # Comma lists and repeated arguments both work.
        log.write_text("")
        (scratch / "catalogs.log").unlink(missing_ok=True)
        r = run(repo, env, "suite", "Packages/macOS/Pkg", "ATests,BTests", "CTests")
        calls = log.read_text()
        if r.returncode != 0:
            failures.append(f"multi-suite run failed ({r.returncode}): {r.stdout}{r.stderr}")
        if calls.count("swift build ") != 1:
            failures.append(f"multi-suite run did not build exactly once: {calls!r}")
        for name in ("ATests", "BTests", "CTests"):
            if f"--skip-build --filter {name}\n" not in calls:
                failures.append(f"multi-suite run did not test {name}: {calls!r}")
        catalog_runs = (scratch / "catalogs.log").read_text().count("compile-string-catalogs") if (scratch / "catalogs.log").exists() else 0
        if catalog_runs != 1:
            failures.append(f"string catalogs compiled {catalog_runs} times, want once")

        # One failing suite fails the step but does not hide the suites after it, and
        # the summary names every suite with its result.
        log.write_text("")
        r = run(repo, {**env, "FAKE_SWIFT_FAIL_FILTER": "BTests"}, "suite", "Packages/macOS/Pkg", "ATests,BTests,CTests")
        calls = log.read_text()
        if r.returncode == 0:
            failures.append("a failing suite in a multi-suite step passed")
        if "--filter CTests" not in calls:
            failures.append(f"the suite after a failure did not run: {calls!r}")
        rows = {line.split()[0]: line for line in r.stdout.splitlines()
                if line.split() and line.split()[0] in ("ATests", "BTests", "CTests")}
        for name, want in (("ATests", "passed"), ("BTests", "failed"), ("CTests", "passed")):
            if want not in rows.get(name, ""):
                failures.append(f"summary row for {name} lacks {want!r}: {r.stdout!r}")
        if "1 of 3 suites failed" not in r.stdout:
            failures.append(f"no failure count in the summary: {r.stdout!r}")

        # Bad arguments are refused before any swift call.
        for args in (("suite", "Packages/macOS/Pkg"), ("suite", "../outside", "FooTests"),
                     ("suite", "Packages/macOS/Pkg", "ATests,,BTests"), ("suite", "Packages/macOS/Pkg", "ATests,"),
                     ("suite", "Packages/macOS/Pkg", "ATests", "--skip-build"),
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

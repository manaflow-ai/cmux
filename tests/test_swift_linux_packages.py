#!/usr/bin/env python3
"""scripts/ci/swift-linux-packages.txt: the Swift packages whose suites run on Linux.

The fleet controller sends a `package-test-lane.sh suite` step to Linux only for a package this list
names, and the script on Linux runs only those packages and test targets, without an Xcode or a macOS
SDK. This test keeps the list honest:
  - every row names a package directory whose manifest declares each listed test target, and an ENV
    key the manifest reads;
  - .github/workflows/swift-linux-packages.yml (the receipt) runs every row through the script on
    Linux, on every change to a package, the list or the script;
  - the script, run as on Linux with an xcrun that fails, runs a listed package without it, and
    refuses an unlisted package and a filter outside the row's test targets.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIST = ROOT / "scripts/ci/swift-linux-packages.txt"
WORKFLOW = ROOT / ".github/workflows/swift-linux-packages.yml"

FAKE_SWIFT = """#!/bin/bash
case "$1 ${2:-}" in "package resolve"|"--version "*) echo "Swift version 6.2"; exit 0 ;; esac
echo "swift $* env=${CMUX_TERMINAL_CLIENT_MODEL_ONLY:-}" >> "$FAKE_SWIFT_LOG"
case "$1" in
  build) echo "Build complete!" ;;
  test)
    filter="${@: -1}"
    for id in 'ListedTests.Suite/test()' 'ListedTests.Other/test()' 'ListedTestsExtra.Suite/test()' 'ListedTestsXSuite/test()' 'ModelTests.Suite/test()'; do
      if printf '%s\n' "$id" | grep -Eq -- "$filter"; then echo "ran $id" >> "$FAKE_SWIFT_LOG"; fi
    done
    echo "✔ Test run with 2 tests in 1 suite passed after 0.001 seconds." ;;
esac
"""


def rows() -> list[tuple[str, list[str], list[str]]]:
    out = []
    for line in LIST.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 3:
            raise SystemExit(f"{LIST.name}: a row needs PACKAGE_DIR TEST_TARGETS ENV: {line!r}")
        dir_, targets, envs = parts
        out.append((dir_, targets.split(","), [] if envs == "-" else envs.split(",")))
    return out


def check_rows(failures: list[str]) -> None:
    seen = set()
    for dir_, targets, envs in rows():
        if dir_ in seen:
            failures.append(f"{dir_} is listed twice")
        seen.add(dir_)
        manifest = ROOT / dir_ / "Package.swift"
        if not re.fullmatch(r"Packages/[A-Za-z0-9_]+/[A-Za-z0-9_]+", dir_) or not manifest.is_file():
            failures.append(f"{dir_}: not a package directory under Packages/")
            continue
        text = manifest.read_text()
        for target in targets:
            if not re.search(r'\.testTarget\(\s*name:\s*"' + re.escape(target) + '"', text):
                failures.append(f"{dir_}: its manifest declares no test target {target}")
        for pair in envs:
            key = pair.split("=", 1)[0]
            if not re.fullmatch(r"[A-Z_][A-Z0-9_]*=[A-Za-z0-9_.:/-]*", pair) or key not in text:
                failures.append(f"{dir_}: ENV {pair} is malformed or its manifest never reads {key}")


def check_workflow(failures: list[str]) -> None:
    wf = WORKFLOW.read_text()
    for needed in ("shell: bash", "scripts/ci/swift-linux-packages.txt", "bash scripts/ci/package-test-lane.sh suite \"$dir\" \"$targets\"",
                   "container: swift:", "ubuntu-2404"):
        if needed not in wf:
            failures.append(f"{WORKFLOW.name} lacks {needed!r}: it must run every listed package through the lane on Linux")
    for path in ("Packages/**", "scripts/ci/swift-linux-packages.txt", "scripts/ci/package-test-lane.sh"):
        if wf.count(f"- {path}") < 2:
            failures.append(f"{WORKFLOW.name} must run on pull requests and pushes that change {path}")


def check_script(failures: list[str]) -> None:
    scratch = Path(tempfile.mkdtemp(prefix="swift-linux-packages-"))
    try:
        repo = scratch / "cmux"
        (repo / "scripts").mkdir(parents=True)
        shutil.copytree(ROOT / "scripts/ci", repo / "scripts/ci")
        for dir_ in ("Packages/Shared/Listed", "Packages/Shared/Model", "Packages/Shared/Other"):
            (repo / dir_).mkdir(parents=True)
            (repo / dir_ / "Package.swift").write_text("// swift-tools-version: 6.0\n")
        (repo / "scripts/ci/swift-linux-packages.txt").write_text(
            "Packages/Shared/Listed  ListedTests  -\nPackages/Shared/Model  ModelTests  CMUX_TERMINAL_CLIENT_MODEL_ONLY=1\n")
        bin_dir = scratch / "bin"
        bin_dir.mkdir()
        (bin_dir / "swift").write_text(FAKE_SWIFT)
        (bin_dir / "xcrun").write_text("#!/bin/bash\necho 'xcrun ran on Linux' >&2\nexit 1\n")
        for tool in ("swift", "xcrun"):
            (bin_dir / tool).chmod(0o755)
        log = scratch / "swift.log"
        (scratch / "tmp").mkdir()
        env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_SWIFT_LOG": str(log),
               "RUNNER_TEMP": str(scratch / "tmp"), "CMUX_PACKAGE_LANE_TEST_OS": "Linux"}
        for name in ("DEVELOPER_DIR", "SDKROOT", "CMUX_CI_XCODE_APP", "GITHUB_OUTPUT", "GITHUB_ACTIONS",
                     "CMUX_SWIFT_SANITIZE", "CMUX_SWIFT_SUITE_CONFIGURATION", "CMUX_TERMINAL_CLIENT_MODEL_ONLY"):
            env.pop(name, None)

        def lane(*args: str) -> subprocess.CompletedProcess:
            return subprocess.run(["bash", "scripts/ci/package-test-lane.sh", "suite", *args], cwd=repo, env=env,
                                  capture_output=True, text=True, timeout=120)

        r = lane("Packages/Shared/Listed", "ListedTests,ListedTests.Suite/test")
        calls = log.read_text() if log.exists() else ""
        if r.returncode != 0 or "xcrun ran" in r.stderr:
            failures.append(f"a listed package did not run on Linux without xcrun ({r.returncode}): {r.stdout[-800:]}{r.stderr[-800:]}")
        if "swift test" not in calls or "ran ListedTests.Suite/test()" not in calls or "ran ListedTests.Other/test()" not in calls:
            failures.append(f"a listed package's suites did not run: {calls}")
        if "ran ListedTestsExtra" in calls or "ran ListedTestsX" in calls:
            failures.append(f"a filter reached a target off the list (an unanchored or unescaped --filter): {calls}")
        log.unlink(missing_ok=True)
        r = lane("Packages/Shared/Model", "ModelTests")
        if r.returncode != 0 or "env=1" not in (log.read_text() if log.exists() else ""):
            failures.append(f"a row's ENV did not reach swift ({r.returncode}): {r.stderr[-800:]}")
        log.unlink(missing_ok=True)
        r = lane("Packages/Shared/Other", "OtherTests")
        if r.returncode != 2 or log.exists() or "is not in scripts/ci/swift-linux-packages.txt" not in r.stderr:
            failures.append(f"an unlisted package ran on Linux ({r.returncode}): {r.stderr[-800:]}")
        r = lane("Packages/Shared/Listed", "ListedTests,KitTests")
        if r.returncode != 2 or log.exists() or "names none of" not in r.stderr:
            failures.append(f"a filter outside the row's test targets ran on Linux ({r.returncode}): {r.stderr[-800:]}")
        for regex in ("ListedTests.Suite|ModelTests", "ListedTests.*", "ListedTests(Extra)?", "ListedTests\\.Suite"):
            r = lane("Packages/Shared/Listed", regex)
            if r.returncode != 2 or log.exists():
                failures.append(f"a regex filter {regex!r} ran on Linux ({r.returncode}): {r.stderr[-400:]}")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def main() -> int:
    failures: list[str] = []
    check_rows(failures)
    check_workflow(failures)
    check_script(failures)
    for f in failures:
        print(f"FAIL: {f}")
    if failures:
        return 1
    print(f"swift-linux-packages: ok ({len(rows())} packages)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

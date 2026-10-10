#!/usr/bin/env python3
"""Run one test filter against an already built SwiftPM test bundle, as `swift test` does.

`swift test --skip-build --filter F` on macOS (SwiftPM 6.3, Xcode 26.6) loads
the package graph, opens .build/build.db, and then runs two processes in the
package directory:

1. XCTest: `xctest -XCTest <every XCTest case matching F, comma-joined> <bundle>`
   with SWIFT_TESTING_ENABLED=0;
2. Swift Testing: `swiftpm-testing-helper --test-bundle-path <binary> --filter F
   <binary> --testing-library swift-testing`, which filters by itself.

Both get DYLD_FRAMEWORK_PATH and DYLD_LIBRARY_PATH for the macOS platform's
developer frameworks (Testing.framework and XCTest live there), and the
`swift` shim's SDKROOT. This script runs the same two processes with the same
environment, without the SwiftPM process, so parallel suites never contend for
build.db. It skips a phase that matches no test: SwiftPM would run it with no
test (the helper then exits 69).

SwiftPM 6.3 links every test target into one bundle (<Package>PackageTests.xctest).
SwiftPM 6.4 (Xcode 27) builds one bundle per test target, named after it
(CmuxNextActionsTests.xctest). Pass every bundle with --bundle; with more than
one, each selected test runs from the bundle named after its module (the part
of `Module.Suite/test` before the first dot), one phase pair per bundle.

Exit status follows `swift test`: 0 when every phase passed, 1 when a phase
failed or crashed ("Exited with unexpected signal code N", as SwiftPM prints),
1 when the filter matches no test.
"""

from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
from pathlib import Path


def read_tests(path: Path) -> list[str]:
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def prepend(value: str, existing: str | None) -> str:
    return f"{value}:{existing}" if existing else value


def phase_environment(args: argparse.Namespace, xctest: bool) -> dict[str, str]:
    env = os.environ.copy()
    developer = Path(args.platform) / "Developer"
    env["DYLD_FRAMEWORK_PATH"] = prepend(
        f"{developer}/Library/Frameworks:{developer}/Library/PrivateFrameworks",
        env.get("DYLD_FRAMEWORK_PATH"),
    )
    env["DYLD_LIBRARY_PATH"] = prepend(f"{developer}/usr/lib", env.get("DYLD_LIBRARY_PATH"))
    if args.sdk:
        env.setdefault("SDKROOT", args.sdk)
    if xctest:
        env["SWIFT_TESTING_ENABLED"] = "0"
    else:
        env.pop("SWIFT_TESTING_ENABLED", None)
    return env


def run_phase(command: list[str], env: dict[str, str], cwd: str) -> int:
    sys.stdout.flush()
    status = subprocess.run(command, env=env, cwd=cwd, stdin=subprocess.DEVNULL, check=False).returncode
    if status < 0:
        print(f"error: Exited with unexpected signal code {-status}", flush=True)
        return 1
    return 0 if status == 0 else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument(
        "--bundle",
        required=True,
        action="append",
        help="a built .xctest bundle (repeat for one bundle per test target)",
    )
    parser.add_argument("--xctest", required=True, help="path of xctest (xcrun --find xctest)")
    parser.add_argument("--helper", required=True, help="path of swiftpm-testing-helper")
    parser.add_argument("--platform", required=True, help="xcrun --sdk macosx --show-sdk-platform-path")
    parser.add_argument("--sdk", default="", help="xcrun --sdk macosx --show-sdk-path (SDKROOT default)")
    parser.add_argument("--tests", required=True, type=Path, help="`swift test list` output")
    parser.add_argument(
        "--xctest-tests", required=True, type=Path, help="`swift test list --disable-swift-testing` output"
    )
    parser.add_argument("--cwd", required=True, help="the package directory")
    parser.add_argument("--filter", required=True)
    args = parser.parse_args(argv)

    pattern = re.compile(args.filter)
    xctest_names = read_tests(args.xctest_tests)
    xctest_set = set(xctest_names)
    xctest_selected = [name for name in xctest_names if pattern.search(name)]
    swift_selected = [
        name for name in read_tests(args.tests) if name not in xctest_set and pattern.search(name)
    ]
    if not xctest_selected and not swift_selected:
        print(f"error: no test matches --filter {args.filter}", flush=True)
        return 1

    bundles = [Path(path) for path in args.bundle]
    by_module = {bundle.stem: bundle for bundle in bundles}

    def bundle_for(name: str) -> Path | None:
        if len(bundles) == 1:
            return bundles[0]
        return by_module.get(name.split(".", 1)[0])

    # Bundle order follows --bundle, so the phases run in a stable order.
    groups: dict[Path, tuple[list[str], list[str]]] = {bundle: ([], []) for bundle in bundles}
    for kind, names in ((0, xctest_selected), (1, swift_selected)):
        for name in names:
            bundle = bundle_for(name)
            if bundle is None:
                print(f"error: no built .xctest bundle for test {name}", flush=True)
                return 1
            groups[bundle][kind].append(name)

    status = 0
    for bundle, (xctests, swift_tests) in groups.items():
        binary = bundle / "Contents" / "MacOS" / bundle.stem
        if xctests:
            status |= run_phase(
                [args.xctest, "-XCTest", ",".join(xctests), str(bundle)],
                phase_environment(args, xctest=True),
                args.cwd,
            )
        if swift_tests:
            status |= run_phase(
                [
                    args.helper,
                    "--test-bundle-path",
                    str(binary),
                    "--filter",
                    args.filter,
                    str(binary),
                    "--testing-library",
                    "swift-testing",
                ],
                phase_environment(args, xctest=False),
                args.cwd,
            )
    return status


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    raise SystemExit(main())

#!/usr/bin/env python3
"""A failing Bonsplit run must not hide the Swift package results after it."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
LANE = ROOT / "scripts/ci/package-test-lane.sh"

# Stands in for swift at its process boundary. Bonsplit's tests fail; every
# package's build, test listing and test run succeeds and is recorded.
FAKE_SWIFT = textwrap.dedent("""\
    #!/usr/bin/env python3
    import os, pathlib, sys
    args = sys.argv[1:]
    path = args[args.index("--package-path") + 1] if "--package-path" in args else ""
    log = pathlib.Path(os.environ["FIXTURE_ROOT"]) / "swift-calls.txt"
    with log.open("a") as handle:
        handle.write(f"{args[0]} {args[1] if len(args) > 1 else ''} {path}\\n")
    if args[0] == "build":
        sys.exit(0)
    if args[:2] == ["test", "list"]:
        print("Fixture.FixtureSuite/passes()")
        sys.exit(0)
    print("Build complete!")
    print("Test Suite 'All tests' started at 2026-10-01 00:00:00.000.")
    if path == "vendor/bonsplit":
        print("Test Case '-[BonsplitTests.BonsplitTests testFails]' started.")
        print("error: -[BonsplitTests.BonsplitTests testFails] : XCTAssertTrue failed")
        print("Test Case '-[BonsplitTests.BonsplitTests testFails]' failed (0.001 seconds).")
        print("\\t Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.001) seconds")
        sys.exit(1)
    print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds")
    print("✔ Test run with 1 test in 1 suite passed after 0.001 seconds.")
    sys.exit(0)
""")


class PackageLaneBonsplitFailureTests(unittest.TestCase):
    def test_bonsplit_failure_still_runs_and_reports_every_package(self) -> None:
        with tempfile.TemporaryDirectory(prefix="package-lane-bonsplit-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "scripts/ci").symlink_to(ROOT / "scripts/ci", target_is_directory=True)
            (root / "scripts/install-rust-ci.sh").write_text("#!/usr/bin/env bash\nexit 0\n")
            (root / "scripts/install-rust-ci.sh").chmod(0o755)
            (root / "vendor/bonsplit").mkdir(parents=True)
            (root / "vendor/bonsplit/Package.swift").write_text("// fixture\n")
            (root / "GhosttyKit.xcframework").mkdir()
            (root / "GhosttyKit.xcframework/Info.plist").write_text("<plist/>\n")
            packages = subprocess.run(
                ["bash", "-c", f"sed -n '/^  PACKAGES=(/,/^  )/p' '{LANE}' | sed '1d;$d'"],
                capture_output=True, text=True, check=True,
            ).stdout.split()
            self.assertGreater(len(packages), 10)
            for package in packages:
                (root / "Packages/macOS" / package).mkdir(parents=True)
            # install_rust puts $CARGO_HOME/bin and $HOME/.cargo/bin first on PATH.
            binaries = root / "home/.cargo/bin"
            binaries.mkdir(parents=True)
            for name, body in (("swift", FAKE_SWIFT), ("cargo", "#!/usr/bin/env bash\nexit 0\n")):
                (binaries / name).write_text(body)
                (binaries / name).chmod(0o755)
            developer_dir = subprocess.run(
                ["xcode-select", "-p"], capture_output=True, text=True,
            ).stdout.strip() or "/Library/Developer/CommandLineTools"
            env = dict(
                os.environ,
                PATH=f"{binaries}:{os.environ['PATH']}",
                FIXTURE_ROOT=str(root),
                HOME=str(root / "home"),
                CARGO_HOME=str(root / "home/.cargo"),
                EVENT_NAME="push",
                FULL_SUITE="true",
                GITHUB_ACTIONS="true",
                DEVELOPER_DIR=developer_dir,
                RUNNER_TEMP=str(root / "runner-temp"),
                CMUX_SWIFT_PACKAGE_BUILD_JOBS="1",
                GITHUB_OUTPUT="",
                GITHUB_STEP_SUMMARY="",
            )
            (root / "runner-temp").mkdir()
            result = subprocess.run(
                ["bash", str(LANE), "run"], cwd=root, env=env,
                capture_output=True, text=True, timeout=300,
            )
            output = result.stdout + result.stderr
            self.assertNotEqual(result.returncode, 0, output[-4000:])
            self.assertIn("Bonsplit failed", output, output[-4000:])
            self.assertIn("Swift package test results:", output, output[-4000:])
            tested = {
                line.split()[-1]
                for line in (root / "swift-calls.txt").read_text().splitlines()
                if line.startswith("test ") and not line.startswith("test list")
            }
            for package in packages:
                self.assertTrue(
                    any(path.endswith(f"/{package}") for path in tested),
                    f"{package} never ran after the Bonsplit failure\n{output[-4000:]}",
                )


if __name__ == "__main__":
    unittest.main()

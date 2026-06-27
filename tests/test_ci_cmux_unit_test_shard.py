#!/usr/bin/env python3
"""Behavioral guards for cmuxTests CI sharding."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "cmux_unit_test_shard.py"


def write_large_suite_fixture(test_root: Path) -> None:
    methods = "\n".join(
        f"    func testGenerated{index:02d}() {{}}"
        for index in range(1, 41)
    )
    (test_root / "LargeSuiteTests.swift").write_text(
        f"""
final class LargeSuiteTests: XCTestCase {{
{methods}
}}
""".lstrip(),
        encoding="utf-8",
    )
    (test_root / "LargeSuiteExtensionTests.swift").write_text(
        """
extension LargeSuiteTests {
    func testExtensionRegression() {}
}
""".lstrip(),
        encoding="utf-8",
    )


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_root = Path(tmp)
        test_root = tmp_root / "cmuxTests"
        test_root.mkdir()
        write_large_suite_fixture(test_root)

        selectors: list[str] = []
        for shard in range(1, 5):
            output = tmp_root / f"shard-{shard}.args"
            result = subprocess.run(
                [
                    sys.executable,
                    str(HELPER),
                    "--root",
                    str(tmp_root),
                    "--shard-index",
                    str(shard),
                    "--shard-total",
                    "4",
                    "--output",
                    str(output),
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            if result.returncode != 0:
                print(result.stdout, end="")
                print(result.stderr, end="", file=sys.stderr)
                print(f"FAIL: shard helper exited {result.returncode}")
                return 1
            selectors.extend(output.read_text(encoding="utf-8").splitlines())

    extension_selector = "-only-testing:cmuxTests/LargeSuiteTests/testExtensionRegression"
    if selectors.count(extension_selector) != 1:
        print(f"FAIL: expected extension selector exactly once, got {selectors.count(extension_selector)}")
        return 1

    suite_selector = "-only-testing:cmuxTests/LargeSuiteTests"
    if suite_selector in selectors:
        print("FAIL: large suite should be method-sharded, not selected as a whole suite")
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        output = Path(tmp) / "repo-shard.args"
        for shard in range(1, 5):
            result = subprocess.run(
                [
                    sys.executable,
                    str(HELPER),
                    "--root",
                    str(ROOT),
                    "--shard-index",
                    str(shard),
                    "--shard-total",
                    "4",
                    "--output",
                    str(output),
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            if result.returncode != 0:
                print(result.stdout, end="")
                print(result.stderr, end="", file=sys.stderr)
                print(f"FAIL: repo shard helper exited {result.returncode}")
                return 1
            shard_selectors = output.read_text(encoding="utf-8").splitlines()
            delayed_selector = "-only-testing:cmuxTests/BrowserDeveloperToolsVisibilityPersistenceTests"
            if delayed_selector in shard_selectors and shard_selectors[-1] != delayed_selector:
                print(f"FAIL: crash-prone selector must run last in shard: {delayed_selector}")
                return 1
            for focused_selector in (
                "-only-testing:cmuxTests/BrowserSystemProxyMirrorTests",
                "-only-testing:cmuxTests/GhosttyOptionAsAltModsTests",
            ):
                if focused_selector in shard_selectors:
                    print(f"FAIL: focused gate selector should not be folded into shard: {focused_selector}")
                    return 1

    print("PASS: cmuxTests sharding covers extension methods and leaves focused gates explicit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

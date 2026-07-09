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


def write_timed_suites_fixture(test_root: Path) -> None:
    for name in ("AlphaTests", "BetaTests", "GammaTests", "DeltaTests"):
        (test_root / f"{name}.swift").write_text(
            f"""
final class {name}: XCTestCase {{
    func testOne() {{}}
    func testTwo() {{}}
}}
""".lstrip(),
            encoding="utf-8",
        )


def run_shard(tmp_root: Path, shard: int, output: Path, timings: Path) -> list[str]:
    result = subprocess.run(
        [
            sys.executable,
            str(HELPER),
            "--root",
            str(tmp_root),
            "--shard-index",
            str(shard),
            "--shard-total",
            "2",
            "--output",
            str(output),
            "--timings",
            str(timings),
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        raise SystemExit(f"FAIL: timed shard helper exited {result.returncode}")
    return output.read_text(encoding="utf-8").splitlines()


def check_timing_weighted_packing() -> int:
    """A suite measured as dominant must get a shard to itself."""
    import json

    with tempfile.TemporaryDirectory() as tmp:
        tmp_root = Path(tmp)
        test_root = tmp_root / "cmuxTests"
        test_root.mkdir()
        write_timed_suites_fixture(test_root)

        manifest = tmp_root / "timings.json"
        manifest.write_text(
            json.dumps(
                {
                    "default_test_ms": 200,
                    "suites": {"AlphaTests": 600000, "BetaTests": 400, "GammaTests": 300},
                    "methods": {},
                }
            ),
            encoding="utf-8",
        )

        shards = [
            run_shard(tmp_root, shard, tmp_root / f"timed-{shard}.args", manifest)
            for shard in (1, 2)
        ]

    alpha = "-only-testing:cmuxTests/AlphaTests"
    alpha_shards = [lines for lines in shards if alpha in lines]
    if len(alpha_shards) != 1:
        print(f"FAIL: AlphaTests should be assigned exactly once, got {len(alpha_shards)}")
        return 1
    if len(alpha_shards[0]) != 1:
        print(
            "FAIL: the 600s AlphaTests suite should be packed alone, shard also got: "
            f"{alpha_shards[0]}"
        )
        return 1
    others = {"BetaTests", "GammaTests", "DeltaTests"}
    assigned = {line.rsplit("/", 1)[-1] for lines in shards for line in lines}
    if not others <= assigned:
        print(f"FAIL: expected all light suites assigned, got {sorted(assigned)}")
        return 1
    print("PASS: timing manifest packs the dominant suite alone")
    return 0


def check_separated_suites_never_share_a_shard() -> int:
    """The app-host-crasher suite and its victim must land on different shards."""
    import json

    with tempfile.TemporaryDirectory() as tmp:
        tmp_root = Path(tmp)
        test_root = tmp_root / "cmuxTests"
        test_root.mkdir()
        for name in (
            "HeavyTests",
            "DeltaTests",
            "BrowserDeveloperToolsVisibilityPersistenceTests",
            "BrowserSessionHistoryRestoreTests",
        ):
            (test_root / f"{name}.swift").write_text(
                f"""
final class {name}: XCTestCase {{
    func testOne() {{}}
    func testTwo() {{}}
}}
""".lstrip(),
                encoding="utf-8",
            )

        # Weights chosen so plain min-weight packing would put both separated
        # suites into the same (light) bucket: Heavy takes shard 1, Delta and
        # both separated suites would all fall into shard 2.
        manifest = tmp_root / "timings.json"
        manifest.write_text(
            json.dumps(
                {
                    "default_test_ms": 200,
                    "suites": {
                        "HeavyTests": 600000,
                        "DeltaTests": 400,
                        "BrowserDeveloperToolsVisibilityPersistenceTests": 300,
                        "BrowserSessionHistoryRestoreTests": 200,
                    },
                    "methods": {},
                }
            ),
            encoding="utf-8",
        )

        shards = [
            run_shard(tmp_root, shard, tmp_root / f"separated-{shard}.args", manifest)
            for shard in (1, 2)
        ]

    crasher = "-only-testing:cmuxTests/BrowserDeveloperToolsVisibilityPersistenceTests"
    victim = "-only-testing:cmuxTests/BrowserSessionHistoryRestoreTests"
    placement = {
        selector: [index for index, lines in enumerate(shards) if selector in lines]
        for selector in (crasher, victim)
    }
    for selector, indexes in placement.items():
        if len(indexes) != 1:
            print(f"FAIL: {selector} should be assigned exactly once, got shards {indexes}")
            return 1
    if placement[crasher] == placement[victim]:
        print(
            "FAIL: separated suites shared a shard: "
            f"crasher={placement[crasher]} victim={placement[victim]}"
        )
        return 1
    print("PASS: separated suites are packed onto different shards")
    return 0


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
                    "--timings",
                    str(tmp_root / "no-manifest.json"),
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

    repo_separated_placement: dict[str, list[int]] = {
        "-only-testing:cmuxTests/BrowserDeveloperToolsVisibilityPersistenceTests": [],
        "-only-testing:cmuxTests/BrowserSessionHistoryRestoreTests": [],
    }
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
            for focused_selector in (
                "-only-testing:cmuxTests/BrowserSystemProxyMirrorTests",
                "-only-testing:cmuxTests/GhosttyOptionAsAltModsTests",
            ):
                if focused_selector in shard_selectors:
                    print(f"FAIL: focused gate selector should not be folded into shard: {focused_selector}")
                    return 1
            for separated_selector, placements in repo_separated_placement.items():
                if separated_selector in shard_selectors:
                    placements.append(shard)

    placements = list(repo_separated_placement.values())
    if any(len(shards) != 1 for shards in placements) or placements[0] == placements[1]:
        print(f"FAIL: repo packing must separate crasher/victim suites, got {repo_separated_placement}")
        return 1

    if (rc := check_timing_weighted_packing()) != 0:
        return rc

    if (rc := check_separated_suites_never_share_a_shard()) != 0:
        return rc

    print("PASS: cmuxTests sharding covers extension methods and leaves focused gates explicit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

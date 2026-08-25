#!/usr/bin/env python3
"""Behavioral guards for cmuxTests CI sharding."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "cmux_unit_test_shard.py"
TIMING_GENERATOR = ROOT / "scripts" / "ci" / "generate_test_timings.py"


def write_large_suite_fixture(test_root: Path) -> None:
    methods = "\n".join(
        f"    @Test func testGenerated{index:02d}() {{}}"
        for index in range(1, 40)
    )
    (test_root / "LargeSuiteTests.swift").write_text(
        f"""
import Testing

struct LargeSuiteTests {{
{methods}
}}
""".lstrip(),
        encoding="utf-8",
    )
    (test_root / "LargeSuiteExtensionTests.swift").write_text(
        """
extension LargeSuiteTests {
    @Test func testExtensionRegression() {}

    @Test
    func extensionOnFollowingLine() {}
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


def check_parameterized_swift_testing_counts() -> int:
    """Parameterized cases and stacked attributes must count as real executions."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp_root = Path(tmp)
        test_root = tmp_root / "cmuxTests"
        test_root.mkdir()
        (test_root / "ParameterizedCountingTests.swift").write_text(
            """
import Testing

@Suite struct ParameterizedCountingTests {
    private static let seeds: [UInt64] = [
        1, 2, 3, 4,
        5, 6, 7, 8,
    ]

    @Test(arguments: seeds)
    func seededCase(seed: UInt64) {}

    @MainActor @Test(arguments: ["alpha", "beta", "gamma"])
    func mainActorCase(name: String) {}

    @Test(arguments: [1, 2] as [Int], [10, 20, 30])
    func castedCartesianCase(lhs: Int, rhs: Int) {}

    @Test func ordinaryCase() {}
}
""".lstrip(),
            encoding="utf-8",
        )
        result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--root",
                str(tmp_root),
                "--validate",
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
        print(f"FAIL: parameterized discovery exited {result.returncode}")
        return 1
    if "representing 18 tests" not in result.stdout:
        print(result.stdout, end="")
        print(
            "FAIL: parameterized Swift Testing cases, stacked attributes, or "
            "Cartesian argument collections were not counted"
        )
        return 1

    print("PASS: parameterized Swift Testing cases count as app-host executions")
    return 0


def check_runtime_parameterized_tests_fail_closed() -> int:
    """An unknown parameter expansion must not bypass the hard process cap."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp_root = Path(tmp)
        test_root = tmp_root / "cmuxTests"
        test_root.mkdir()
        (test_root / "RuntimeParameterizedTests.swift").write_text(
            """
import Testing

@Suite struct RuntimeParameterizedTests {
    private static var runtimeCases: [Int] { Array(0..<4) }

    @Test(arguments: runtimeCases)
    func runtimeExpandedCase(value: Int) {}

    @Test func ordinaryCase() {}
}

@Suite struct PeerTests {
    @Test func peerCase() {}
}
""".lstrip(),
            encoding="utf-8",
        )
        output_directory = tmp_root / "batches"
        result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--root",
                str(tmp_root),
                "--shard-index",
                "1",
                "--shard-total",
                "1",
                "--batch-selector-limit",
                "24",
                "--batch-test-limit",
                "80",
                "--batch-output-directory",
                str(output_directory),
                "--timings",
                str(tmp_root / "no-manifest.json"),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
    selector = "cmuxTests/RuntimeParameterizedTests/runtimeExpandedCase"
    if (
        result.returncode == 0
        or selector not in result.stderr
        or "runtime-expanded test count" not in result.stderr
    ):
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        print("FAIL: runtime-expanded parameterized tests must fail closed")
        return 1

    print("PASS: runtime-expanded parameterized tests cannot bypass the process cap")
    return 0


def check_nested_swift_testing_suites_keep_umbrella_selectors() -> int:
    """Nested suites must retain their recursively selecting umbrella type."""
    nested_methods = "\n".join(
        f"    @Test func nestedCase{index:02d}() {{}}" for index in range(1, 42)
    )
    non_suffixed_methods = "\n".join(
        f"        @Test func case{index:02d}() {{}}" for index in range(1, 82)
    )
    multiline_attribute_methods = "\n".join(
        f"        @Test func scenario{index:02d}() {{}}" for index in range(1, 4)
    )
    with tempfile.TemporaryDirectory() as tmp:
        tmp_root = Path(tmp)
        test_root = tmp_root / "cmuxTests"
        test_root.mkdir()
        (test_root / "BehaviorUmbrellaTests.swift").write_text(
            f"""
import Testing

@Suite(.serialized)
struct BehaviorUmbrellaTests {{}}

extension BehaviorUmbrellaTests {{
    @Suite struct NestedBehaviorTests {{
{nested_methods}
    }}
}}
""".lstrip(),
            encoding="utf-8",
        )
        (test_root / "SharedStateSuites.swift").write_text(
            """
import Testing

@Suite(.serialized)
enum SharedStateSuites {}

extension SharedStateSuites {
    @Suite struct FirstSharedStateTests {
        @Test func firstCase() {}
    }

    @Suite struct SecondSharedStateTests {
        @Test func secondCase() {}
    }
}
""".lstrip(),
            encoding="utf-8",
        )
        (test_root / "ExplicitlyAnnotatedUmbrellaTests.swift").write_text(
            f"""
import Testing

@Suite(.serialized)
struct ExplicitlyAnnotatedUmbrellaTests {{}}

extension ExplicitlyAnnotatedUmbrellaTests {{
    @Suite struct Cases {{
{non_suffixed_methods}
    }}
}}

@Suite(.serialized)
struct MultilineAnnotatedUmbrellaTests {{}}

extension MultilineAnnotatedUmbrellaTests {{
    @Suite
    struct Scenarios {{
{multiline_attribute_methods}
    }}
}}
""".lstrip(),
            encoding="utf-8",
        )
        result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--root",
                str(tmp_root),
                "--list",
                "--timings",
                str(tmp_root / "no-manifest.json"),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        batch_result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--root",
                str(tmp_root),
                "--shard-index",
                "1",
                "--shard-total",
                "1",
                "--batch-selector-limit",
                "24",
                "--batch-test-limit",
                "80",
                "--batch-output-directory",
                str(tmp_root / "batches"),
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
        print(f"FAIL: nested-suite discovery exited {result.returncode}")
        return 1

    selectors = {
        fields[0]: int(fields[1])
        for line in result.stdout.splitlines()
        if len(fields := line.split("\t", 2)) == 3
    }
    expected = {
        "cmuxTests/BehaviorUmbrellaTests": 41 * 200,
        "cmuxTests/ExplicitlyAnnotatedUmbrellaTests": 81 * 200,
        "cmuxTests/MultilineAnnotatedUmbrellaTests": 3 * 200,
        "cmuxTests/SharedStateSuites": 2 * 200,
    }
    if selectors != expected:
        print(result.stdout, end="")
        print(
            "FAIL: nested Swift Testing suites must stay under their recursively "
            f"selecting umbrella with exact counts, got {selectors}"
        )
        return 1
    if (
        batch_result.returncode == 0
        or "cmuxTests/ExplicitlyAnnotatedUmbrellaTests" not in batch_result.stderr
        or "represents 81 tests" not in batch_result.stderr
    ):
        print(batch_result.stdout, end="")
        print(batch_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: a non-suffixed nested @Suite must not bypass the process cap"
        )
        return 1

    print("PASS: nested Swift Testing suites retain umbrella selectors and counts")
    return 0


def check_parameterized_method_fallback_weight() -> int:
    """Method-split parameterized tests must retain per-case fallback weight."""
    ordinary_methods = "\n".join(
        f"    @Test func ordinaryCase{index:02d}() {{}}" for index in range(32)
    )
    with tempfile.TemporaryDirectory() as tmp:
        tmp_root = Path(tmp)
        test_root = tmp_root / "cmuxTests"
        test_root.mkdir()
        (test_root / "ParameterizedFallbackWeightTests.swift").write_text(
            f"""
import Testing

@Suite struct ParameterizedFallbackWeightTests {{
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8])
    func parameterizedCase(value: Int) {{}}

{ordinary_methods}
}}
""".lstrip(),
            encoding="utf-8",
        )
        result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--root",
                str(tmp_root),
                "--list",
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
        print(f"FAIL: parameterized fallback weighting exited {result.returncode}")
        return 1
    weights = {
        fields[0]: int(fields[1])
        for line in result.stdout.splitlines()
        if len(fields := line.split("\t", 2)) == 3
    }
    selector = "cmuxTests/ParameterizedFallbackWeightTests/parameterizedCase"
    if weights.get(selector) != 8 * 200:
        print(result.stdout, end="")
        print(
            "FAIL: parameterized method fallback weight must scale by its "
            f"eight cases, got {weights.get(selector)}"
        )
        return 1

    print("PASS: parameterized method fallback weight scales by case count")
    return 0


def check_batched_swift_timing_aggregation() -> int:
    """Timing refreshes must sum distinct partial Swift Testing batches."""
    import json

    with tempfile.TemporaryDirectory() as tmp:
        tmp_root = Path(tmp)
        first_log = tmp_root / "shard-1.log"
        first_log.write_text(
            """
Suite LargeSwiftTests passed after 20.0 seconds
Suite LegacyOnlyTests passed after 5.0 seconds
##[group]Run app-host process batch batch-001.args (3 selectors)
Suite LargeSwiftTests passed after 2.0 seconds
Suite SmallSwiftTests passed after 1.0 seconds
##[endgroup]
##[group]Run app-host process batch batch-002.args (2 selectors)
Suite LargeSwiftTests passed after 3.0 seconds
Suite LargeSwiftTests passed after 2.5 seconds
##[endgroup]
""".lstrip(),
            encoding="utf-8",
        )
        second_log = tmp_root / "shard-2.log"
        second_log.write_text(
            """
Suite LegacyOnlyTests passed after 6.0 seconds
##[group]Run app-host process batch batch-001.args (4 selectors)
Suite LargeSwiftTests passed after 4.0 seconds
##[endgroup]
""".lstrip(),
            encoding="utf-8",
        )
        output = tmp_root / "timings.json"
        result = subprocess.run(
            [
                sys.executable,
                str(TIMING_GENERATOR),
                "--run-id",
                "fixture-run",
                "--output",
                str(output),
                str(first_log),
                str(second_log),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            print(result.stdout, end="")
            print(result.stderr, end="", file=sys.stderr)
            print(f"FAIL: timing generation exited {result.returncode}")
            return 1
        manifest = json.loads(output.read_text(encoding="utf-8"))

    suites = manifest["suites"]
    if suites.get("LargeSwiftTests") != 9_000:
        print(
            "FAIL: distinct partial Swift Testing batches must sum to 9000 ms, "
            f"got {suites.get('LargeSwiftTests')}"
        )
        return 1
    if suites.get("LegacyOnlyTests") != 6_000:
        print(
            "FAIL: legacy unbatched Swift Testing observations must retain the "
            f"largest duration, got {suites.get('LegacyOnlyTests')}"
        )
        return 1

    print("PASS: Swift Testing timing refresh aggregates distinct process batches")
    return 0


def check_bounded_process_batches() -> int:
    """Process batches must bound represented work and cover every selector once."""
    import json

    suite_names = (
        "HeavyTests",
        "WideTests",
        "AlphaTests",
        "BetaTests",
        "GammaTests",
        "DeltaTests",
        "EpsilonTests",
        "ZetaTests",
        "TerminalWindowPortalLifecycleTests",
        "TerminalOffscreenStartupTests",
        "BrowserWindowPortalLifecycleTests",
    )
    test_counts = {name: 5 if name == "WideTests" else 2 for name in suite_names}
    with tempfile.TemporaryDirectory() as tmp:
        tmp_root = Path(tmp)
        test_root = tmp_root / "cmuxTests"
        test_root.mkdir()
        for name in suite_names:
            methods = "\n".join(
                f"    func testGenerated{index}() {{}}"
                for index in range(1, test_counts[name] + 1)
            )
            (test_root / f"{name}.swift").write_text(
                f"""
final class {name}: XCTestCase {{
{methods}
}}
""".lstrip(),
                encoding="utf-8",
            )

        manifest = tmp_root / "timings.json"
        manifest.write_text(
            json.dumps(
                {
                    "default_test_ms": 200,
                    "suites": {
                        "HeavyTests": 600_000,
                        **{name: 400 for name in suite_names if name != "HeavyTests"},
                    },
                    "methods": {},
                }
            ),
            encoding="utf-8",
        )
        output_directory = tmp_root / "batches"
        batch_command = [
            sys.executable,
            str(HELPER),
            "--root",
            str(tmp_root),
            "--shard-index",
            "1",
            "--shard-total",
            "1",
            "--batch-selector-limit",
            "2",
            "--batch-test-limit",
            "6",
            "--batch-output-directory",
            str(output_directory),
            "--timings",
            str(manifest),
        ]
        result = subprocess.run(
            batch_command,
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            print(result.stdout, end="")
            print(result.stderr, end="", file=sys.stderr)
            print(f"FAIL: batched shard helper exited {result.returncode}")
            return 1

        invalid_selector_limit_command = [*batch_command]
        invalid_selector_limit_command[
            invalid_selector_limit_command.index("--batch-selector-limit") + 1
        ] = "0"
        invalid_selector_limit = subprocess.run(
            invalid_selector_limit_command,
            text=True,
            capture_output=True,
            check=False,
        )
        if (
            invalid_selector_limit.returncode == 0
            or "--batch-selector-limit must be >= 1"
            not in invalid_selector_limit.stderr
        ):
            print(invalid_selector_limit.stdout, end="")
            print(invalid_selector_limit.stderr, end="", file=sys.stderr)
            print("FAIL: zero selector limit must be rejected")
            return 1

        invalid_test_limit_command = [*batch_command]
        invalid_test_limit_command[
            invalid_test_limit_command.index("--batch-test-limit") + 1
        ] = "0"
        invalid_test_limit = subprocess.run(
            invalid_test_limit_command,
            text=True,
            capture_output=True,
            check=False,
        )
        if (
            invalid_test_limit.returncode == 0
            or "--batch-test-limit must be >= 1" not in invalid_test_limit.stderr
        ):
            print(invalid_test_limit.stdout, end="")
            print(invalid_test_limit.stderr, end="", file=sys.stderr)
            print("FAIL: zero represented-test limit must be rejected")
            return 1

        unsafe_test_limit_command = [*batch_command]
        unsafe_test_limit_command[
            unsafe_test_limit_command.index("--batch-test-limit") + 1
        ] = "81"
        unsafe_test_limit = subprocess.run(
            unsafe_test_limit_command,
            text=True,
            capture_output=True,
            check=False,
        )
        if (
            unsafe_test_limit.returncode == 0
            or "--batch-test-limit must be <= 80" not in unsafe_test_limit.stderr
        ):
            print(unsafe_test_limit.stdout, end="")
            print(unsafe_test_limit.stderr, end="", file=sys.stderr)
            print(
                "FAIL: a process test limit above the safety boundary must be rejected"
            )
            return 1

        undersized_test_limit_command = [*batch_command]
        undersized_test_limit_command[
            undersized_test_limit_command.index("--batch-test-limit") + 1
        ] = "1"
        undersized_test_limit = subprocess.run(
            undersized_test_limit_command,
            text=True,
            capture_output=True,
            check=False,
        )
        if (
            undersized_test_limit.returncode == 0
            or "exceeding --batch-test-limit 1" not in undersized_test_limit.stderr
        ):
            print(undersized_test_limit.stdout, end="")
            print(undersized_test_limit.stderr, end="", file=sys.stderr)
            print("FAIL: a suite larger than the process test limit must be rejected")
            return 1

        batches = [
            path.read_text(encoding="utf-8").splitlines()
            for path in sorted(output_directory.glob("batch-*.args"))
        ]
        rerun = subprocess.run(
            batch_command,
            text=True,
            capture_output=True,
            check=False,
        )
        if (
            rerun.returncode == 0
            or "already contains process batches" not in rerun.stderr
        ):
            print(rerun.stdout, end="")
            print(rerun.stderr, end="", file=sys.stderr)
            print("FAIL: reused batch output directory must be rejected")
            return 1

    if not batches:
        print("FAIL: batched shard helper emitted no process batches")
        return 1
    if any(not batch or len(batch) > 2 for batch in batches):
        print(f"FAIL: process batches must contain 1...2 selectors, got {batches}")
        return 1

    represented_tests = [
        sum(test_counts[selector.rsplit("/", 1)[-1]] for selector in batch)
        for batch in batches
    ]
    if any(count > 6 for count in represented_tests):
        print(
            "FAIL: process batches exceeded the represented-test limit: "
            f"counts={represented_tests} batches={batches}"
        )
        return 1

    flattened = [selector for batch in batches for selector in batch]
    expected = {f"-only-testing:cmuxTests/{name}" for name in suite_names}
    if len(flattened) != len(set(flattened)) or set(flattened) != expected:
        print(f"FAIL: process batches lost or duplicated selectors: {batches}")
        return 1

    heavy_selector = "-only-testing:cmuxTests/HeavyTests"
    heavy_batch = next(batch for batch in batches if heavy_selector in batch)
    if heavy_batch != [heavy_selector]:
        print(
            f"FAIL: timing-balanced batches should isolate the dominant suite: {heavy_batch}"
        )
        return 1

    isolated_suites = (
        "TerminalWindowPortalLifecycleTests",
        "TerminalOffscreenStartupTests",
        "BrowserWindowPortalLifecycleTests",
    )
    for suite in isolated_suites:
        selector = f"-only-testing:cmuxTests/{suite}"
        batch = next(batch for batch in batches if selector in batch)
        if batch != [selector]:
            print(
                f"FAIL: resource-lifecycle suite must run in a fresh process: {batch}"
            )
            return 1

    print("PASS: process batches bound app-host work without losing selectors")
    return 0


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


def check_non_dict_manifest_falls_back() -> int:
    """Valid-JSON-but-not-a-dict manifests must fall back, not crash."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp_root = Path(tmp)
        test_root = tmp_root / "cmuxTests"
        test_root.mkdir()
        write_timed_suites_fixture(test_root)

        manifest = tmp_root / "timings.json"
        manifest.write_text('["not", "a", "dict"]', encoding="utf-8")

        shards = [
            run_shard(tmp_root, shard, tmp_root / f"nondict-{shard}.args", manifest)
            for shard in (1, 2)
        ]

    assigned = {line.rsplit("/", 1)[-1] for lines in shards for line in lines}
    expected = {"AlphaTests", "BetaTests", "GammaTests", "DeltaTests"}
    if assigned != expected:
        print(f"FAIL: non-dict manifest fallback lost suites, got {sorted(assigned)}")
        return 1
    print("PASS: non-dict JSON manifest falls back to count-based packing")
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
    if (rc := check_bounded_process_batches()) != 0:
        return rc

    if (rc := check_parameterized_swift_testing_counts()) != 0:
        return rc

    nested_suite_rc = check_nested_swift_testing_suites_keep_umbrella_selectors()
    runtime_parameter_rc = check_runtime_parameterized_tests_fail_closed()
    if nested_suite_rc != 0 or runtime_parameter_rc != 0:
        return 1

    if (rc := check_parameterized_method_fallback_weight()) != 0:
        return rc

    if (rc := check_batched_swift_timing_aggregation()) != 0:
        return rc

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

    extension_selectors = {
        "-only-testing:cmuxTests/LargeSuiteTests/testExtensionRegression",
        "-only-testing:cmuxTests/LargeSuiteTests/extensionOnFollowingLine",
    }
    for extension_selector in extension_selectors:
        if selectors.count(extension_selector) != 1:
            print(
                "FAIL: expected Swift Testing extension selector exactly once, got "
                f"{extension_selector}={selectors.count(extension_selector)}"
            )
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
                "-only-testing:cmuxTests/CLISSHSessionAttachAnchorTests",
                "-only-testing:cmuxTests/GhosttyTerminalViewVisibilityPolicyTests",
                "-only-testing:cmuxTests/GhosttyOptionAsAltModsTests",
                "-only-testing:cmuxTests/RemoteTmuxMirrorLayoutIdentityTests",
                "-only-testing:cmuxTests/SidebarWorkspaceSwitchLayoutFaultTests",
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

    if (rc := check_non_dict_manifest_falls_back()) != 0:
        return rc

    print("PASS: cmuxTests sharding covers extension methods and leaves focused gates explicit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

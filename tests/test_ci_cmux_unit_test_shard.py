#!/usr/bin/env python3
"""Behavioral guards for cmuxTests CI sharding."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "cmux_unit_test_shard.py"
CI_PHYSICAL_SHARD_TOTAL = 6
CI_LOGICAL_BATCHES_PER_WORKER = 2
CI_LOGICAL_SHARD_TOTAL = CI_PHYSICAL_SHARD_TOTAL * CI_LOGICAL_BATCHES_PER_WORKER


def production_shard_constants() -> tuple[int, int]:
    """Read the production matrix constants so this test exercises its topology."""
    # ci-macos.yml's batch steps run this script.
    workflow = (ROOT / "scripts" / "ci" / "run-app-host-unit-batches.sh").read_text(encoding="utf-8")
    values: dict[str, int] = {}
    for line in workflow.splitlines():
        stripped = line.strip()
        for name in ("PHYSICAL_SHARD_TOTAL", "LOGICAL_BATCHES_PER_WORKER"):
            prefix = f"{name}="
            if stripped.startswith(prefix):
                values[name] = int(stripped[len(prefix):])
    try:
        return values["PHYSICAL_SHARD_TOTAL"], values["LOGICAL_BATCHES_PER_WORKER"]
    except KeyError as error:
        raise AssertionError(f"production CI is missing {error.args[0]}") from error


def check_test_topology_matches_production() -> int:
    physical, batches = production_shard_constants()
    if (physical, batches) != (CI_PHYSICAL_SHARD_TOTAL, CI_LOGICAL_BATCHES_PER_WORKER):
        print(
            "FAIL: test shard topology differs from production: "
            f"test={CI_PHYSICAL_SHARD_TOTAL}x{CI_LOGICAL_BATCHES_PER_WORKER}, "
            f"production={physical}x{batches}"
        )
        return 1
    print("PASS: test shard topology matches production")
    return 0


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


def check_split_methods_use_callable_identifiers() -> int:
    """Xcode matches Swift Testing methods only with their call signature.

    A real Xcode bundle with a failing @Test sentinel exits zero and runs zero
    tests for ModernTests/testSentinel. ModernTests/testSentinel() executes the
    failure; XCTest accepts that explicit no-argument signature as well.
    """
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        test_root = root / "cmuxTests"
        test_root.mkdir()
        for suite, declaration, attribute in (
            ("ModernTests", "@Suite struct ModernTests", "    @Test\n"),
            ("LegacyTests", "final class LegacyTests: XCTestCase", ""),
        ):
            methods = "\n".join(
                f"{attribute}    func testGenerated{index:02d}() {{}}"
                for index in range(40)
            )
            (test_root / f"{suite}.swift").write_text(
                f"{declaration} {{\n{methods}\n}}\n", encoding="utf-8"
            )
        selectors = set()
        for shard in (1, 2):
            selectors.update(run_shard(root, shard, root / f"{shard}.args", root / "absent.json"))
        expected = {
            f"-only-testing:cmuxTests/{suite}/testGenerated{index:02d}()"
            for suite in ("ModernTests", "LegacyTests") for index in range(40)
        }
        if selectors != expected:
            print("FAIL: split selectors must retain callable method signatures; "
                  f"missing={sorted(expected - selectors)[:3]} unexpected={sorted(selectors - expected)[:3]}")
            return 1
        import json
        timings = root / "timings.json"
        timings.write_text(json.dumps({
            "suites": {}, "methods": {"ModernTests/testGenerated00": 12345},
        }), encoding="utf-8")
        listed = subprocess.run(
            [sys.executable, str(HELPER), "--root", str(root), "--list", "--timings", str(timings)],
            text=True, capture_output=True, check=True,
        )
        weights = {row.split("\t")[0]: int(row.split("\t")[1])
                   for row in listed.stdout.splitlines()}
        if weights["cmuxTests/ModernTests/testGenerated00()"] != 12345:
            print("FAIL: call suffix must preserve measured method weights")
            return 1
    print("PASS: split XCTest and Swift Testing methods retain callable signatures")
    return 0


def check_parameterized_test_methods_keep_their_suite() -> int:
    """A no-argument method selector must never replace a parameterized test."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        test_root = root / "cmuxTests"
        test_root.mkdir()
        ordinary = "\n".join(f"    @Test\n    func testGenerated{i}() {{}}" for i in range(40))
        declarations = {
            "DirectTests": "    @Test(arguments: [1, 2]) func testValues(value: Int) {}",
            "MultilineTests": "    @Test(arguments: [1, 2])\n    func testValues(\n        value: Int\n    ) {}",
            "ExtendedTests": "",
        }
        for suite, extra in declarations.items():
            (test_root / f"{suite}.swift").write_text(
                f"@Suite struct {suite} {{\n{ordinary}\n{extra}\n}}\n", encoding="utf-8"
            )
        (test_root / "Extension.swift").write_text(
            "extension ExtendedTests {\n    @Test(arguments: [1, 2])\n    func testValues(value: Int) {}\n}\n",
            encoding="utf-8",
        )
        selected = []
        for shard in (1, 2):
            selected.extend(run_shard(root, shard, root / f"{shard}.args", root / "absent.json"))
        expected = {f"-only-testing:cmuxTests/{suite}" for suite in declarations}
        if len(selected) != len(expected) or set(selected) != expected:
            print(f"FAIL: parameterized suites must run whole exactly once: {selected[:5]}")
            return 1
    print("PASS: parameterized and multiline test methods preserve whole-suite execution")
    return 0


def check_unrepresented_swift_tests_keep_their_suite() -> int:
    """Large migrated suites cannot drop modern names or inline @Test methods."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        test_root = root / "cmuxTests"
        test_root.mkdir()
        ordinary = "\n".join(f"    @Test\n    func testGenerated{i}() {{}}" for i in range(40))
        declarations = {
            "ModernNameTests": "    @Test\n    func otherName() {}",
            "InlineTests": "    @Test func testInline() {}",
            "ExtendedModernTests": "",
        }
        for suite, extra in declarations.items():
            (test_root / f"{suite}.swift").write_text(
                f"@Suite struct {suite} {{\n{ordinary}\n{extra}\n}}\n", encoding="utf-8"
            )
        (test_root / "ModernExtension.swift").write_text(
            "extension ExtendedModernTests {\n    @Test func otherName() {}\n}\n",
            encoding="utf-8",
        )
        selected = []
        for shard in (1, 2):
            selected.extend(run_shard(root, shard, root / f"{shard}.args", root / "absent.json"))
        expected = {f"-only-testing:cmuxTests/{suite}" for suite in declarations}
        if len(selected) != len(expected) or set(selected) != expected:
            print(f"FAIL: unrepresented Swift Testing methods must preserve their whole suite: {selected[:5]}")
            return 1
    print("PASS: modern names and inline Swift Testing methods preserve whole-suite execution")
    return 0


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


def check_swift_testing_extension_weights() -> int:
    """Empty Swift Testing containers must count their extension-declared tests."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        test_root = root / "cmuxTests"
        test_root.mkdir()
        (test_root / "ContainerTests.swift").write_text(
            "@Suite struct ContainerTests {}\n", encoding="utf-8"
        )
        (test_root / "ContainerExtensions.swift").write_text(
            """extension ContainerTests {
    @Suite struct NestedTests {
        @Test func first() {}
        @Test func second() {}
    }
}
extension ContainerTests {
    @Test func third() {}
}
final class LegacyTests: XCTestCase {
    func testFirst() {}
}
extension LegacyTests {
    func testSecond() {}
}
extension LegacyTests {
    func helperOnly() {}
}
""", encoding="utf-8"
        )
        result = subprocess.run(
            [sys.executable, str(HELPER), "--root", str(root), "--list",
             "--timings", str(root / "absent.json")],
            text=True, capture_output=True, check=False,
        )
        if result.returncode != 0:
            print(result.stdout + result.stderr)
            return 1
        weights = {row.split("\t")[0]: int(row.split("\t")[1])
                   for row in result.stdout.splitlines()}
    expected = {"cmuxTests/ContainerTests": 600, "cmuxTests/LegacyTests": 400}
    if weights != expected:
        print(f"FAIL: extension test weights must reflect all three Swift tests and two XCTest methods: {weights}")
        return 1
    print("PASS: Swift Testing extension containers retain their test weights")
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


def run_reserved_shard(
    tmp_root: Path, shard: int, total: int, physical: int, reserve: list[str], timings: Path
) -> subprocess.CompletedProcess[str]:
    arguments = [
        sys.executable, str(HELPER), "--root", str(tmp_root),
        "--shard-index", str(shard), "--shard-total", str(total),
        "--physical-shard-total", str(physical),
        "--output", str(tmp_root / f"reserved-{shard}.args"), "--timings", str(timings),
    ]
    for value in reserve:
        arguments += ["--reserve", value]
    return subprocess.run(arguments, text=True, capture_output=True, check=False)


def check_reserved_workers_get_less_of_the_batch() -> int:
    """A worker with strict steps outside the batch must receive less batch work."""
    import json

    suites = [f"Timed{index:02d}Tests" for index in range(24)]
    with tempfile.TemporaryDirectory() as tmp:
        tmp_root = Path(tmp)
        test_root = tmp_root / "cmuxTests"
        test_root.mkdir()
        for name in suites:
            (test_root / f"{name}.swift").write_text(
                f"final class {name}: XCTestCase {{\n    func testOne() {{}}\n}}\n", encoding="utf-8"
            )
        manifest = tmp_root / "timings.json"
        manifest.write_text(
            json.dumps({"default_test_ms": 200, "suites": {name: 10000 for name in suites}, "methods": {}}),
            encoding="utf-8",
        )

        # Two workers, two logical shards each. Worker 1 carries 40 s of wall
        # time outside the batch, worth 100 s of the 240 s batch.
        assigned: dict[int, list[str]] = {}
        for shard in range(1, 5):
            result = run_reserved_shard(tmp_root, shard, 4, 2, ["1=40"], manifest)
            if result.returncode != 0:
                print(result.stdout + result.stderr)
                return 1
            assigned[shard] = (tmp_root / f"reserved-{shard}.args").read_text(encoding="utf-8").split()

        for bad in (["3=40"], ["1=x"], ["1=40", "1=50"], ["1"]):
            result = run_reserved_shard(tmp_root, 1, 4, 2, bad, manifest)
            if result.returncode == 0 or "Traceback" in result.stderr:
                print(f"FAIL: --reserve {bad} should be rejected without a traceback")
                return 1
        result = run_reserved_shard(tmp_root, 1, 3, 2, [], manifest)
        if result.returncode == 0 or "Traceback" in result.stderr:
            print("FAIL: a non-divisible logical total should be rejected without a traceback")
            return 1
        for total, physical in ((0, 0), (4, 0), (4, -2), (-4, 2)):
            result = run_reserved_shard(tmp_root, 1, total, physical, [], manifest)
            if result.returncode == 0 or "Traceback" in result.stderr:
                print(f"FAIL: shard totals {total}/{physical} should be rejected with a message")
                return 1

    everything = sorted(selector for lines in assigned.values() for selector in lines)
    if everything != sorted(f"-only-testing:cmuxTests/{name}" for name in suites):
        print(f"FAIL: reservations must not drop or duplicate selectors, got {len(everything)}")
        return 1
    worker_one = len(assigned[1]) + len(assigned[3])
    worker_two = len(assigned[2]) + len(assigned[4])
    if (worker_one, worker_two) != (7, 17):
        print(f"FAIL: expected the reserved worker to get 7 of 24 suites, got {worker_one} and {worker_two}")
        return 1
    print("PASS: a worker's reserved wall time moves batch work to the other workers")
    return 0


def focused_steps_in_ci_workflow() -> tuple[set[str], set[str], dict[str, str]]:
    """Return suites strict steps run in full, suites run in part, and the job env."""
    import re

    workflow = (ROOT / ".github" / "workflows" / "ci-macos.yml").read_text(encoding="utf-8")
    match = re.search(r"(?ms)^  app-host-unit-tests:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n)", workflow)
    if match is None:
        raise SystemExit("FAIL: app-host-unit-tests job missing from ci-macos.yml")
    job = match.group(1)
    whole: set[str] = set()
    partial: set[str] = set()
    for step in re.split(r"(?m)^      - name: ", job)[1:]:
        if step.split("\n", 1)[0] == "Run unit tests":
            continue
        body = "\n".join(line for line in step.splitlines() if not line.strip().startswith("#"))
        for selector in re.finditer(r'-only-testing:"?cmuxTests/([A-Za-z0-9_]+)(/[A-Za-z0-9_]+)?', body):
            (partial if selector.group(2) else whole).add(selector.group(1))
        for loop in re.finditer(r"(?s)for suite in(.*?)(?:;|\n\s*do\b)", body):
            whole |= {word for word in re.findall(r"[A-Za-z0-9_]+", loop.group(1)) if word[0].isupper()}
    env = dict(re.findall(r'(?m)^      (CMUX_APP_HOST_[A-Z_]+): "([^"]*)"$', job))
    return whole, partial, env


def check_truthful_broad_suites_leave_focused_gates(
    generated_selectors: list[str],
) -> int:
    """Suites protected by strict broad accounting should run in the timed batch."""
    import importlib.util

    folded = {
        "AgentChatFallbackTranscriptResolutionCoordinatorTests",
        "AgentChatSessionRegistryLifecycleReviewRegressionTests",
        "AgentRestoreLiveOwnerAdmissionTests",
        "BackgroundPrimeStartableSurfaceTests",
        "BrowserSystemProxyMirrorTests",
        "BrowserViewportRuntimeTests",
        "CLISSHSessionAttachAnchorTests",
        "CLISendQueuedOutputTests",
        "ClaudeHookLifecycleCleanupTests",
        "ClaudeHookLiveDeliveryTargetTests",
        "ClaudeHookPIDAuthenticationTests",
        "CloudNotificationDismissParityTests",
        "CloudWorkspaceRenameSurfaceParityTests",
        "CmuxBundledBinPathIntegrationTests",
        "DockNotificationAttentionTests",
        "GhosttyOptionAsAltModsTests",
        "HostSettingsShortcutNotificationTests",
        "LiveAgentIndexRelevantChurnTests",
        "MainWindowZoomPlacementTests",
        "NotificationRowSnapshotBoundaryTests",
        "NotificationScrollRestoreLifecycleTests",
        "NotificationScrollRestoreRecoveryTests",
        "PhonePushPresenceGateTests",
        "RestoreAdmissionRetryPolicyTests",
        "RestoredAgentShellActivityLivenessTests",
        "SurfaceResumeAgentHookDowngradeTests",
    }
    spec = importlib.util.spec_from_file_location("cmux_unit_test_shard_folded", HELPER)
    assert spec is not None and spec.loader is not None
    helper = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = helper
    spec.loader.exec_module(helper)

    focused = {selector.split("/", 1)[1] for selector in helper.FOCUSED_GATE_SELECTORS}
    whole, _, _ = focused_steps_in_ci_workflow()
    stale = sorted(folded & (focused | whole))
    if stale:
        print(f"FAIL: truthful broad suites still have dedicated focused ownership: {stale}")
        return 1

    discovered = {
        selector.identifier.split("/", 2)[1]
        for selector in helper.discover_selectors(ROOT)
        if selector.identifier.startswith("cmuxTests/")
    }
    missing = sorted(folded - discovered)
    if missing:
        print(f"FAIL: folded suites are absent from broad shard discovery: {missing}")
        return 1

    ownership = {
        suite: generated_selectors.count(f"-only-testing:cmuxTests/{suite}")
        for suite in folded
    }
    bad_ownership = {
        suite: count for suite, count in ownership.items() if count != 1
    }
    if bad_ownership:
        print(
            "FAIL: folded suites must have exactly one generated broad-shard owner: "
            f"{bad_ownership}"
        )
        return 1

    print("PASS: truthful broad suites are discovered and owned exactly once by the measured shard batch")
    return 0


def check_folded_fish_suite_keeps_prerequisite() -> int:
    import re

    workflow = (ROOT / ".github" / "workflows" / "ci-macos.yml").read_text(encoding="utf-8")
    match = re.search(
        r"(?ms)^  app-host-unit-tests:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n)",
        workflow,
    )
    if match is None:
        print("FAIL: app-host-unit-tests job missing")
        return 1
    job = match.group(1)
    run_step = re.search(
        r"(?ms)^      - name: Run unit tests\n(.*?)(?=^      - name: |\Z)",
        job,
    )
    if run_step is None:
        print("FAIL: Run unit tests step missing")
        return 1
    body = run_step.group(0)
    batches = "scripts/ci/run-app-host-unit-batches.sh"
    if f"run: {batches}" not in body:
        print(f"FAIL: Run unit tests no longer runs {batches}")
        return 1
    body = (ROOT / batches).read_text(encoding="utf-8")
    required = (
        "CmuxBundledBinPathIntegrationTests",
        "grep -Fq",
        "brew install fish",
        "command -v fish",
        "fish is required for CmuxBundledBinPathIntegrationTests",
    )
    missing = [needle for needle in required if needle not in body]
    if missing:
        print(f"FAIL: folded fish suite lost its runtime prerequisite: {missing}")
        return 1
    print("PASS: folded bundled-bin suite installs and requires fish only in its owning batch")
    return 0


def check_global_search_has_dedicated_consumer() -> int:
    """Global search must run beside, never ahead of, the six broad workers."""
    import re

    workflow = (ROOT / ".github" / "workflows" / "ci-macos.yml").read_text(encoding="utf-8")
    match = re.search(r"(?ms)^  app-host-unit-tests:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n)", workflow)
    if match is None:
        print("FAIL: app-host-unit-tests job missing")
        return 1
    job = match.group(1)
    # The matrix rows are JSON literals inside the `include` expression: the
    # numbered consumers, and the single changed-suites worker.
    import json

    include = re.search(r"(?ms)^        include: >-\n(.*?)\]'\) \}\}$", job)
    if include is None:
        print("FAIL: app-host matrix include expression missing")
        return 1
    row_sets = [
        json.loads(literal)
        for literal in re.findall(r"(?s)'(\[.*?\])'", include.group(0))
    ]
    numbered = next((rows for rows in row_sets if len(rows) > 1), [])
    changed = next((rows for rows in row_sets if len(rows) == 1), [])
    rows = {int(row["shard"]) for row in numbered}
    missing_shards = [shard for shard in range(1, 8) if shard not in rows]
    if missing_shards:
        print(f"FAIL: app-host matrix is missing consumers: {missing_shards}")
        return 1
    # A consumer runs compile admission's product, which only loads under the
    # admission's Xcode, so no row may route a consumer to a pool of its own.
    if any(set(row) != {"shard"} for row in numbered + changed):
        print("FAIL: an app-host matrix row names its own pool; consumers run on compile admission's pool")
        return 1
    if [row.get("shard") for row in changed] != [8]:
        print("FAIL: a changed-suites run must be one shard-8 worker")
        return 1
    if 'CMUX_APP_HOST_GLOBAL_SEARCH_SHARD: "7"' not in job:
        print("FAIL: global search must own consumer 7")
        return 1

    steps = {
        part.split("\n", 1)[0]: part
        for part in re.split(r"(?m)^      - name: ", job)[1:]
    }
    global_step = steps.get("Run global search shortcut regressions", "")
    broad_step = steps.get("Run unit tests", "")
    if "matrix.shard == fromJSON(env.CMUX_APP_HOST_GLOBAL_SEARCH_SHARD)" not in global_step:
        print("FAIL: global search step is not pinned to its dedicated consumer")
        return 1
    if "matrix.shard != fromJSON(env.CMUX_APP_HOST_GLOBAL_SEARCH_SHARD)" not in broad_step:
        print("FAIL: dedicated global-search consumer can still enter broad batches")
        return 1

    physical, _ = production_shard_constants()
    if physical != 6:
        print(f"FAIL: dedicated consumer must not change six-worker broad topology, got {physical}")
        return 1
    print("PASS: global search has a seventh consumer and the broad topology stays six workers")
    return 0


def check_focused_gates_run_once() -> int:
    import importlib.util
    import re

    spec = importlib.util.spec_from_file_location("cmux_unit_test_shard", HELPER)
    assert spec is not None and spec.loader is not None
    helper = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = helper
    spec.loader.exec_module(helper)

    whole, partial, env = focused_steps_in_ci_workflow()
    excluded = {selector.split("/", 1)[1] for selector in helper.FOCUSED_GATE_SELECTORS}
    if excluded != whole - partial:
        print("FAIL: the batch must leave out exactly the suites a strict ci-macos.yml step runs in full")
        print(f"  strict in ci-macos.yml but still in the batch: {sorted(whole - partial - excluded)}")
        print(f"  left out of the batch but not strict in ci-macos.yml: {sorted(excluded - (whole - partial))}")
        return 1

    sources = "\n".join(
        path.read_text(encoding="utf-8") for path in sorted((ROOT / "cmuxTests").glob("**/*.swift"))
    )
    undeclared = sorted(
        name for name in whole | partial
        if not re.search(rf"(?m)^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:final\s+)?(?:class|struct|enum|actor)\s+{name}\b", sources)
    )
    if undeclared:
        print(f"FAIL: ci-macos.yml strict steps name suites cmuxTests does not declare: {undeclared}")
        return 1

    groups = {
        env.get(name)
        for name in (
            "CMUX_APP_HOST_CLI_REGRESSION_SHARD",
            "CMUX_APP_HOST_FOCUSED_REGRESSION_B_SHARD",
            "CMUX_APP_HOST_FOCUSED_REGRESSION_SHARD",
        )
    }
    reserved = {value.split("=")[0] for value in env.get("CMUX_APP_HOST_RESERVED_WALL_SECONDS", "").split()}
    if None in groups or len(groups) != 3 or groups != reserved:
        print(f"FAIL: shared strict groups run on shards {sorted(map(str, groups))} but wall time is reserved on {sorted(reserved)}")
        return 1
    print("PASS: strict suites run once, exist, and every worker that runs them has wall time reserved")
    return 0


def main() -> int:
    if (rc := check_split_methods_use_callable_identifiers()) != 0:
        return rc
    if (rc := check_parameterized_test_methods_keep_their_suite()) != 0:
        return rc
    if (rc := check_unrepresented_swift_tests_keep_their_suite()) != 0:
        return rc

    if (rc := check_test_topology_matches_production()) != 0:
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

    extension_selector = "-only-testing:cmuxTests/LargeSuiteTests/testExtensionRegression()"
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
    repo_assigned_selectors: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        output = Path(tmp) / "repo-shard.args"
        for shard in range(1, CI_LOGICAL_SHARD_TOTAL + 1):
            result = subprocess.run(
                [
                    sys.executable,
                    str(HELPER),
                    "--root",
                    str(ROOT),
                    "--shard-index",
                    str(shard),
                    "--shard-total",
                    str(CI_LOGICAL_SHARD_TOTAL),
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
            repo_assigned_selectors.extend(shard_selectors)
            for focused_selector in (
                "-only-testing:cmuxTests/GhosttyTerminalViewVisibilityPolicyTests",
                "-only-testing:cmuxTests/GlobalSearchShortcutBehaviorTests",
                "-only-testing:cmuxTests/KeyboardShortcutSettingsFileStoreNoOpPersistenceTests",
                "-only-testing:cmuxTests/RemoteTmuxMirrorLayoutIdentityTests",
                "-only-testing:cmuxTests/SidebarWorkspaceSwitchLayoutFaultTests",
            ):
                if focused_selector in shard_selectors:
                    print(f"FAIL: focused gate selector should not be folded into shard: {focused_selector}")
                    return 1
            for separated_selector, placements in repo_separated_placement.items():
                if separated_selector in shard_selectors:
                    placements.append(shard)

    listed = subprocess.run(
        [sys.executable, str(HELPER), "--root", str(ROOT), "--list"],
        text=True,
        capture_output=True,
        check=False,
    )
    if listed.returncode != 0:
        print(listed.stdout, end="")
        print(listed.stderr, end="", file=sys.stderr)
        print(f"FAIL: repo selector listing exited {listed.returncode}")
        return 1
    expected_repo_selectors = {
        f"-only-testing:{line.split(chr(9), 1)[0]}"
        for line in listed.stdout.splitlines()
        if line
    }
    assigned_repo_selector_set = set(repo_assigned_selectors)
    if len(repo_assigned_selectors) != len(assigned_repo_selector_set):
        print("FAIL: logical app-host shards assign at least one selector more than once")
        return 1
    if assigned_repo_selector_set != expected_repo_selectors:
        missing = sorted(expected_repo_selectors - assigned_repo_selector_set)
        unexpected = sorted(assigned_repo_selector_set - expected_repo_selectors)
        print(
            "FAIL: logical app-host shards do not exactly cover discovered selectors; "
            f"missing={missing[:10]} unexpected={unexpected[:10]}"
        )
        return 1

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

    if (rc := check_swift_testing_extension_weights()) != 0:
        return rc

    if (rc := check_reserved_workers_get_less_of_the_batch()) != 0:
        return rc

    if (rc := check_truthful_broad_suites_leave_focused_gates(repo_assigned_selectors)) != 0:
        return rc

    if (rc := check_folded_fish_suite_keeps_prerequisite()) != 0:
        return rc

    if (rc := check_global_search_has_dedicated_consumer()) != 0:
        return rc

    if (rc := check_focused_gates_run_once()) != 0:
        return rc

    print("PASS: cmuxTests sharding covers extension methods and leaves focused gates explicit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""The broad Swift test pass runs as several processes, and every selected test falls in exactly one of them.

One swift test process ran every selected suite: its tests queued on one main thread, the windows they left open
piled up (3 -> 428 in run 40705037968) and the pass hit its limit with 466 tests unfinished.
scripts/cmux-next/swift-test-shards.py splits the selected targets by target and suite-name prefix.
"""

from __future__ import annotations

import importlib.util
import re
import sys
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Packages" / "macOS" / "CmuxNext"
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next.yml"
SCRIPT = ROOT / "scripts" / "cmux-next" / "swift-test-shards.py"

def load(name: str, path: Path):
    """A script as a module, registered in sys.modules first: a @dataclass reads its module from there
    (on Python 3.12 and 3.13 an unregistered module crashes the import)."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


shards = load("swift_test_shards", SCRIPT)


def matching(plan: list[dict], test_id: str) -> list[str]:
    """The shards that run `test_id`: their filter matches it and none of their skips does."""
    return [s["name"] for s in plan
            if re.search(s["filter"], test_id) and not any(re.search(k, test_id) for k in s.get("skip", []))]


class Plan(unittest.TestCase):
    def test_every_suite_of_every_target_is_in_exactly_one_shard(self) -> None:
        plan = shards.plan(PACKAGE / "Tests", PACKAGE / "Package.swift", "all", 10)
        self.assertGreater(len(plan), 1)
        for target in shards.test_targets(PACKAGE / "Package.swift"):
            for suite in shards.suite_counts(PACKAGE / "Tests" / target):
                with self.subTest(suite=f"{target}.{suite}"):
                    self.assertEqual(len(matching(plan, f"{target}.{suite}/aTest()")), 1)

    def test_a_suite_the_sources_did_not_show_still_lands_in_exactly_one_shard(self) -> None:
        plan = shards.plan(PACKAGE / "Tests", PACKAGE / "Package.swift", "all", 10)
        for name in ("Zz", "_Hidden", "lowercase", "S", "Sx9", "CmQ", "Ä"):
            with self.subTest(name=name):
                self.assertEqual(len(matching(plan, f"CmuxNextAppTests.{name}/aTest()")), 1)

    def test_the_cloud_suites_run_in_a_shard_of_their_own(self) -> None:
        # Run 40723548016, shard 4: three Cloud tests sat 300 s packed beside other suites, and pass alone.
        plan = shards.plan(PACKAGE / "Tests", PACKAGE / "Package.swift", "all", 10)
        cloud = [s for s in plan if s["filter"] == r"^(CmuxNextAppTests\.Cloud)"]
        self.assertEqual(len(cloud), 1)
        for suite in ("CloudCodexBrokerTests", "CloudCodexBrokerAdapterTests", "CloudStartSessionTests"):
            with self.subTest(suite=suite):
                self.assertEqual(matching(plan, f"CmuxNextAppTests.{suite}/aTest()"), [cloud[0]["name"]])
        self.assertEqual(len(matching(plan, "CmuxNextAppTests.ClipboardTests/aTest()")), 1)
        self.assertNotIn(cloud[0]["name"], matching(plan, "CmuxNextAppTests.ClipboardTests/aTest()"))
        self.assertEqual([s for s in plan if s["filter"] == r"^(CmuxNextAppTests\.Cloud)"][0]["skip"], [])

    def test_shards_are_balanced_and_the_largest_runs_first(self) -> None:
        plan = shards.plan(PACKAGE / "Tests", PACKAGE / "Package.swift", "all", 10)
        sizes = [s["tests"] for s in plan]
        self.assertEqual(sizes, sorted(sizes, reverse=True))
        packed = [s["tests"] for s in plan if s["skip"]]
        self.assertLess(max(packed), 1.5 * sum(packed) / len(packed))

    def test_every_test_of_every_target_is_counted_in_a_suite(self) -> None:
        # A `nonisolated struct` suite went uncounted: CmuxNextAgentPaneTests read as 737 tests of its 803.
        for target in shards.test_targets(PACKAGE / "Package.swift"):
            sources = (PACKAGE / "Tests" / target).rglob("*.swift")
            raw = sum(len(shards.TEST.findall(p.read_text(encoding="utf-8", errors="replace"))) for p in sources)
            with self.subTest(target=target):
                self.assertEqual(sum(shards.suite_counts(PACKAGE / "Tests" / target).values()), raw)

    def test_a_free_test_function_runs_in_exactly_one_shard(self) -> None:
        # AgentPageOpsBtwTests.swift declares its @Test at file scope: Swift Testing names it Target.function().
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "SomeTests"
            target.mkdir()
            (target / "Free.swift").write_text('import Testing\n@Test("free")\nfunc freeOne() {}\n'
                                               "struct ASuite {\n    @Test func a() {}\n}\n")
            self.assertEqual(shards.suite_counts(target), {"freeOne": 1, "ASuite": 1})
        plan = shards.plan(PACKAGE / "Tests", PACKAGE / "Package.swift", "all", 10)
        self.assertEqual(len(matching(plan, "CmuxNextAgentPaneTests.inlineBtwActionIsAllowlisted()")), 1)

    def test_one_target_whose_suites_share_a_long_prefix_still_splits_evenly(self) -> None:
        # Under a 4-character prefix cap, AgentPane* (489 tests) stayed one unit: shards of 489, 152, 49 and 47.
        plan = shards.plan(PACKAGE / "Tests", PACKAGE / "Package.swift", "CmuxNextAgentPaneTests", 4)
        sizes = [s["tests"] for s in plan]
        self.assertGreater(len(plan), 1)
        self.assertLess(max(sizes), 1.5 * sum(sizes) / len(sizes))
        for suite in shards.suite_counts(PACKAGE / "Tests" / "CmuxNextAgentPaneTests"):
            with self.subTest(suite=suite):
                self.assertEqual(len(matching(plan, f"CmuxNextAgentPaneTests.{suite}/aTest()")), 1)

    def test_only_the_selected_targets_and_never_an_excluded_one(self) -> None:
        plan = shards.plan(PACKAGE / "Tests", PACKAGE / "Package.swift", "CmuxNextFilesTests CmuxNextControlTests", 10,
                           {"CmuxNextControlTests"})
        self.assertEqual(matching(plan, "CmuxNextFilesTests.Any/aTest()"), ["shard 1"])
        self.assertEqual(matching(plan, "CmuxNextControlTests.Any/aTest()"), [])
        self.assertEqual(matching(plan, "CmuxNextAppTests.Any/aTest()"), [])

    def test_a_nonisolated_or_open_suite_is_its_own_suite(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "ATests"
            target.mkdir()
            (target / "X.swift").write_text("@MainActor struct ATests {\n    @Test func a() {}\n}\n"
                                            "nonisolated struct BTests {\n    @Test func b() {}\n    @Test func c() {}\n}\n"
                                            "@Suite private nonisolated final class CTests {\n    @Test func d() {}\n}\n")
            self.assertEqual(shards.suite_counts(target), {"ATests": 1, "BTests": 2, "CTests": 1})

    def test_a_small_selection_is_one_process(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Package.swift").write_text('.testTarget(\n    name: "ATests"\n)\n.testTarget(name: "BTests")\n')
            for target in ("ATests", "BTests"):
                (root / "Tests" / target).mkdir(parents=True)
                (root / "Tests" / target / "X.swift").write_text("struct XTests {\n    @Test func a() {}\n}\n")
            plan = shards.plan(root / "Tests", root / "Package.swift", "all", 8)
        self.assertEqual(len(plan), 1)
        self.assertEqual(matching(plan, "BTests.XTests/a()"), ["shard 1"])


FAKE_SWIFT_TEST = """#!/usr/bin/env bash
# A stand-in for swift-test-with-hang-sampler.sh: records when it opened the build database and when its
# helper started, and fails like SwiftPM when another start holds the database.
dir="$FAKE_DIR"; name="$(echo "$*" | tr -c 'A-Za-z0-9' _ | cut -c1-60)"
if { [ -n "${FAKE_LOCK_ONCE:-}" ] && [ ! -e "$dir/locked-$name" ]; } || ! mkdir "$dir/db" 2>/dev/null; then
  touch "$dir/locked-$name"
  echo "error: unable to attach DB: database is locked"; exit 1
fi
sleep 1; rmdir "$dir/db"
echo "◇ Test run started."
echo "$name" >> "$dir/ran"
sleep 1
echo "✔ Test run with 1 test in 1 suite passed after 1 seconds."
"""


class Run(unittest.TestCase):
    def run_shards(self, count: int, at_once: int, lock_once: bool = False) -> tuple[int, list[str], Path]:
        tmp = Path(tempfile.mkdtemp())
        wrapper = tmp / "fake.sh"
        wrapper.write_text(FAKE_SWIFT_TEST)
        wrapper.chmod(0o755)
        plan = [{"name": f"shard {i}", "filter": f"^(T{i}\\.)", "tests": 1, "skip": []} for i in range(1, count + 1)]
        env = {"FAKE_DIR": str(tmp), "GITHUB_STEP_SUMMARY": ""}
        if lock_once:
            env["FAKE_LOCK_ONCE"] = "1"
        with mock.patch.dict("os.environ", env), mock.patch("sys.stdout"):
            status = shards.run(plan, at_once, str(wrapper), [], time.time() + 600)
        ran = (tmp / "ran").read_text().split() if (tmp / "ran").exists() else []
        return status, ran, tmp

    def test_two_starts_never_hold_the_build_database_at_once(self) -> None:
        # Run 40734897241: three shards started together lost .build/build.db and ran no test.
        status, ran, _ = self.run_shards(3, 3)
        self.assertEqual(status, 0)
        self.assertEqual(len(ran), 3)

    def test_a_shard_that_lost_the_database_before_any_test_runs_again_once(self) -> None:
        status, ran, _ = self.run_shards(2, 2, lock_once=True)
        self.assertEqual(status, 0)
        self.assertEqual(len(ran), 2)


class Width(unittest.TestCase):
    def test_width_comes_from_the_runners_cores_and_memory(self) -> None:
        self.assertEqual(shards.width(14, 64), 3)  # cores bound it: a quarter, not half (run 40874507839)
        self.assertEqual(shards.width(16, 8), 2)  # memory bounds it
        self.assertEqual(shards.width(1, 2), 1)
        self.assertEqual(shards.width(10, 64, "2"), 2)


class Route(unittest.TestCase):
    def test_a_change_to_either_script_runs_every_swift_target(self) -> None:
        route = load("cmux_next_route_for_shards", ROOT / "scripts" / "ci" / "cmux_next_route.py")
        for path in ("scripts/cmux-next/swift-test-shards.py", "scripts/cmux-next/main-thread-heavy-suites.py"):
            with self.subTest(path=path):
                self.assertIn(path, route.FULL_INPUTS)


class Workflow(unittest.TestCase):
    def test_the_broad_pass_runs_the_shards(self) -> None:
        steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["swift-test"]["steps"]
        broad = next(s for s in steps if s.get("name", "").startswith("Run package tests (changed suites first"))
        self.assertIn("swift-test-shards.py run", broad["run"])
        self.assertIn('--targets "$SWIFT_TARGETS"', broad["run"])
        self.assertIn("--exclude CmuxNextControlTests", broad["run"])
        self.assertNotIn("swift-test-with-hang-sampler.sh --skip-build ${filter", broad["run"])

    def test_every_shard_sees_the_same_tree_the_broad_pass_started_with(self) -> None:
        # Run 40932106119: shards that started after a CmuxNextDaemonTests suite fetched the same-tree cmux-tui ran
        # live-daemon suites the base's one process skipped. The tree is resolved once, after the changed-suites
        # pass, and only the broad pass gets it (the changed-suites pass keeps its own lookup and fetch).
        steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["swift-test"]["steps"]
        broad = next(s for s in steps if s.get("name", "").startswith("Run package tests (changed suites first"))
        self.assertNotIn("CMUX_NEXT_TUI_TREE_PATH", broad.get("env", {}))
        run = broad["run"]
        resolve = run.index('tree_path="$(../../../scripts/cmux-next/pin-cmux-tui.sh path')
        self.assertLess(run.index("SWIFT_PRIORITY_FILTER\" ]]; then"), resolve)
        self.assertLess(resolve, run.index('CMUX_NEXT_TUI_TREE_PATH="$tree_path" python3 ../../../scripts/cmux-next/swift-test-shards.py run'))
        self.assertIn("tree_path=/dev/null/no-same-tree-here", run)
        # Every live-daemon helper reads a set path that is no binary as none, without looking again.
        tests = ROOT / "Packages" / "macOS" / "CmuxNext" / "Tests"
        for helper in ("CmuxNextAppTests/FirstLaunchTests.swift", "CmuxNextMobileTests/LiveDaemonTests.swift",
                       "CmuxNextDaemonTests/IntegrationTests.swift"):
            with self.subTest(helper=helper):
                self.assertRegex((tests / helper).read_text(),
                                 r"\? URL\(fileURLWithPath: (?:path|resolved)\) : nil")


class SignalPolicy(unittest.TestCase):
    def test_the_sigpipe_handler_calls_only_async_signal_safe_functions(self) -> None:
        # A stack print (backtrace, backtrace_symbols_fd) in a signal handler can take a lock the interrupted
        # thread holds and deadlock the test process.
        source = (PACKAGE / "Tests" / "Support" / "CmuxNextTestExitTrace" / "CmuxNextTestSignalPolicy.c").read_text()
        body = re.search(r"static void sigpipe_caught\(int signal\) \{\n(.*?)\n\}", source, re.S).group(1)
        body = re.sub(r'"(?:[^"\\]|\\.)*"', '""', body)
        calls = set(re.findall(r"\b([A-Za-z_]\w*)\s*\(", body)) - {"if", "sizeof", "void"}
        self.assertLessEqual(calls, {"write", "atomic_fetch_add"})


if __name__ == "__main__":
    unittest.main()

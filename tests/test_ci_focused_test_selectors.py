#!/usr/bin/env python3
"""A focused test run must never pass after executing zero tests.

`-only-testing:cmuxTests/Suite/method` matches no Swift Testing test: the
selector needs the call suffix, `method()` or `method(label:)`. xcodebuild
then reports zero executed tests and exits 0. These tests hold the three
layers that stop that: the resolver that repairs or rejects a selector, the
executed-count backstop, and the workflow steps that run them.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/focused_test_selectors.py"
E2E = yaml.safe_load((ROOT / ".github/workflows/test-e2e.yml").read_text())
# test-e2e.yml's build job, or its fallback test job, runs the tests through
# this composite action.
E2E_TESTS = yaml.safe_load((ROOT / ".github/actions/e2e-run-tests/action.yml").read_text())
MACOS_SUITE = yaml.safe_load((ROOT / ".github/workflows/test-macos-suite.yml").read_text())


def load():
    spec = importlib.util.spec_from_file_location("focused_test_selectors", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def action_step(action, name):
    found = [s for s in action["runs"]["steps"] if s.get("name") == name]
    if len(found) != 1:
        raise AssertionError(f"expected one {name!r} step in the action, found {len(found)}")
    return found[0]


def step(workflow, job, name):
    found = [s for s in workflow["jobs"][job]["steps"] if s.get("name") == name]
    if len(found) != 1:
        raise AssertionError(f"expected one {name!r} step in {job}, found {len(found)}")
    return found[0]


# Spelled the way the built inventory spells them: XCTest methods carry `()`,
# parameterized Swift Testing methods carry their argument labels.
INVENTORY = {
    "LegacyTests/testOne()",
    "ModernTests/plain()",
    "ModernTests/parameterized(value:)",
    "ModernTests/unlabeled(_:_:)",
    "ModernTests/Nested/inner()",
    "OverloadTests/run(a:)",
    "OverloadTests/run(b:)",
}


def typed_results(*identifiers):
    return {"testNodes": [{
        "nodeType": "Test Suite",
        "children": [
            {"nodeType": "Test Case", "nodeIdentifier": identifier, "result": "Passed"}
            for identifier in identifiers
        ],
    }]}


class ResolveSelectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.selectors = load()

    def resolve(self, selector):
        return self.selectors.resolve_selector(INVENTORY, selector)

    def test_a_swift_testing_method_without_its_suffix_gets_the_one_it_needs(self):
        for given, expected in (
            ("cmuxTests/ModernTests/plain", "cmuxTests/ModernTests/plain()"),
            ("cmuxTests/ModernTests/parameterized", "cmuxTests/ModernTests/parameterized(value:)"),
            ("cmuxTests/ModernTests/unlabeled", "cmuxTests/ModernTests/unlabeled(_:_:)"),
            ("cmuxTests/ModernTests/Nested/inner", "cmuxTests/ModernTests/Nested/inner()"),
        ):
            with self.subTest(given=given):
                resolved, note = self.resolve(given)
                self.assertEqual(resolved, expected)
                self.assertIn(expected, note)

    def test_a_wrong_suffix_is_replaced_by_the_declared_labels(self):
        resolved, _ = self.resolve("cmuxTests/ModernTests/parameterized()")
        self.assertEqual(resolved, "cmuxTests/ModernTests/parameterized(value:)")

    def test_a_selector_that_already_names_a_test_or_suite_is_unchanged(self):
        for selector in (
            "cmuxTests/ModernTests",
            "cmuxTests/ModernTests/Nested",
            "cmuxTests/ModernTests/plain()",
            "cmuxTests/ModernTests/parameterized(value:)",
            "cmuxTests/LegacyTests/testOne()",
        ):
            with self.subTest(selector=selector):
                self.assertEqual(self.resolve(selector), (selector, None))

    def test_an_xctest_method_is_given_the_suffix_xctest_also_accepts(self):
        resolved, _ = self.resolve("cmuxTests/LegacyTests/testOne")
        self.assertEqual(resolved, "cmuxTests/LegacyTests/testOne()")

    def test_an_overloaded_name_is_rejected_with_every_form_named(self):
        with self.assertRaises(self.selectors.AmbiguousSelector) as raised:
            self.resolve("cmuxTests/OverloadTests/run")
        self.assertIn("cmuxTests/OverloadTests/run(a:)", str(raised.exception))
        self.assertIn("cmuxTests/OverloadTests/run(b:)", str(raised.exception))

    def test_a_name_the_inventory_lacks_is_rejected_with_the_correct_forms(self):
        for selector in ("cmuxTests/MissingTests", "cmuxTests/ModernTests/absent"):
            with self.subTest(selector=selector):
                with self.assertRaises(self.selectors.UnknownSelector) as raised:
                    self.resolve(selector)
                self.assertIn(selector, str(raised.exception))
                self.assertIn("Suite/method()", str(raised.exception))

    def test_every_bad_selector_in_a_batch_is_reported(self):
        resolved, notices, errors = self.selectors.resolve_selectors(
            INVENTORY,
            ["cmuxTests/ModernTests/plain", "cmuxTests/MissingTests", "cmuxTests/OverloadTests/run"],
        )
        self.assertEqual(resolved, ["cmuxTests/ModernTests/plain()"])
        self.assertEqual(len(notices), 1)
        self.assertEqual(len(errors), 2)

    def test_resolve_command_prints_resolved_selectors_or_fails_naming_them(self):
        with tempfile.TemporaryDirectory() as temp:
            inventory = Path(temp) / "inventory.json"
            inventory.write_text(json.dumps({"version": 1, "tests": sorted(INVENTORY)}))
            ok = subprocess.run(
                [sys.executable, str(SCRIPT), "resolve", "--inventory", str(inventory),
                 "--selectors", "cmuxTests/ModernTests/plain,cmuxTests/LegacyTests"],
                text=True, capture_output=True,
            )
            self.assertEqual(ok.returncode, 0, ok.stderr)
            self.assertEqual(ok.stdout.strip(), "cmuxTests/ModernTests/plain(),cmuxTests/LegacyTests")
            self.assertIn("::notice::", ok.stderr)

            bad = subprocess.run(
                [sys.executable, str(SCRIPT), "resolve", "--inventory", str(inventory),
                 "--selectors", "cmuxTests/ModernTests/plain,cmuxTests/MissingTests"],
                text=True, capture_output=True,
            )
            self.assertEqual(bad.returncode, 1)
            self.assertEqual(bad.stdout, "")
            self.assertIn("::error::cmuxTests/MissingTests matches no built test", bad.stderr)


class ExecutedCountTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.selectors = load()

    def check(self, selectors, *documents):
        with tempfile.TemporaryDirectory() as temp:
            paths = []
            for index, document in enumerate(documents):
                path = Path(temp) / f"attempt-{index}.tests.json"
                path.write_text(document if isinstance(document, str) else json.dumps(document))
                paths.append(str(path))
            return subprocess.run(
                [sys.executable, str(SCRIPT), "check-executed", "--selectors", selectors,
                 "--tests-json", *paths],
                text=True, capture_output=True,
            )

    def test_a_selector_that_executed_nothing_fails_even_when_another_ran(self):
        result = self.check(
            "cmuxTests/ModernTests/plain(),cmuxTests/ModernTests/parameterized",
            typed_results("ModernTests/plain()"),
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error::cmuxTests/ModernTests/parameterized executed zero tests", result.stderr)
        self.assertNotIn("plain() executed zero", result.stderr)

    def test_every_selector_accounting_for_a_test_passes(self):
        result = self.check(
            "cmuxTests/ModernTests,cmuxTests/LegacyTests/testOne",
            typed_results("ModernTests/plain()", "ModernTests/Nested/inner()"),
            typed_results("LegacyTests/testOne()"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cmuxTests/ModernTests: 2 test(s) executed", result.stdout)

    def test_ui_results_match_with_or_without_the_target_in_the_identifier(self):
        for identifier in ("FooUITests/testBar()", "cmuxUITests/FooUITests/testBar()"):
            with self.subTest(identifier=identifier):
                result = self.check("cmuxUITests/FooUITests/testBar,BazUITests", typed_results(identifier))
                self.assertEqual(result.returncode, 1)
                self.assertIn("::error::BazUITests executed zero tests", result.stderr)
                self.assertNotIn("testBar executed zero", result.stderr)

    def test_an_empty_result_set_fails_every_selector(self):
        result = self.check("cmuxTests/ModernTests/plain", {"testNodes": []})
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error::cmuxTests/ModernTests/plain executed zero tests", result.stderr)

    def test_unreadable_results_defer_to_the_aggregate_guard_without_passing(self):
        result = self.check("cmuxTests/ModernTests/plain", "")
        self.assertEqual(result.returncode, 3)
        self.assertIn("::warning::", result.stderr)


class SourceInventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.selectors = load()

    def test_source_names_match_what_the_built_inventory_records(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "cmuxTests").mkdir()
            (root / "cmuxTests/ModernTests.swift").write_text('''import Testing

@MainActor
struct ModernTests {
    @Test func plain() {}

    @Test("display name (with parens)", arguments: [1, 2])
    func parameterized(value: Int) {}

    @Test(arguments: zip([1], ["a"]))
    func unlabeled(_ number: Int, _ text: String) {}

    @Test func labeled(external internal: [String: Int], handler: (Int) -> Void) async throws {}

    // @Test func commentedOut() {}

    func helper(value: Int) -> Int { value }
}

extension ModernTests {
    @Test func fromExtension() {}
}

final class LegacyTests: XCTestCase {
    func testOne() {}
    func helper() {}
}
''')
            self.assertEqual(self.selectors.source_inventory(root, "ModernTests"), {
                "ModernTests/plain()",
                "ModernTests/parameterized(value:)",
                "ModernTests/unlabeled(_:_:)",
                "ModernTests/labeled(external:handler:)",
                "ModernTests/fromExtension()",
            })
            self.assertEqual(self.selectors.source_inventory(root, "LegacyTests"), {"LegacyTests/testOne()"})
            self.assertEqual(self.selectors.source_inventory(root, "AbsentTests"), set())


class WorkflowTests(unittest.TestCase):
    """Run the real workflow step bodies against fake Xcode tools."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.workspace = self.root / "workspace"
        (self.workspace / "scripts/ci").mkdir(parents=True)
        for relative in (
            "scripts/ci/focused_test_selectors.py",
            "scripts/ci/app_host_result_accounting.py",
            "scripts/ci/cmux_unit_test_shard.py",
            "scripts/ci/run-and-capture.sh",
            "scripts/ci/require_selected_test_execution.sh",
            "scripts/swift_source_mask.py",
        ):
            shutil.copy2(ROOT / relative, self.workspace / relative)
        console = self.workspace / "scripts/ci/run-in-console-session.sh"
        console.write_text('#!/usr/bin/env bash\nexec "$@"\n')
        console.chmod(0o755)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.root / "output").write_text("")
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "RUNNER_TEMP": str(self.root),
            "GITHUB_OUTPUT": str(self.root / "output"),
            "CMUX_APP_HOST_XCTESTRUN": str(self.root / "unit.xctestrun"),
        }

    def tool(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def run_script(self, script, **env):
        return subprocess.run(
            ["bash", "-eu", "-o", "pipefail", "-c", script],
            cwd=self.workspace, env={**self.env, **env}, text=True, capture_output=True,
        )

    def outputs(self):
        return dict(
            line.split("=", 1) for line in (self.root / "output").read_text().splitlines() if "=" in line
        )

    def fake_enumeration(self):
        enumeration = {"values": [{"children": [{
            "name": "cmuxTests",
            "children": [{"name": "ModernTests", "children": [
                {"name": "plain()"}, {"name": "parameterized(value:)"},
            ]}],
        }]}]}
        self.tool("xcodebuild", f'''#!/usr/bin/env python3
import sys
args = sys.argv[1:]
path = args[args.index("-test-enumeration-output-path") + 1]
open(path, "w").write({json.dumps(json.dumps(enumeration))})
''')

    def test_every_e2e_test_run_passes_the_filter_jobs_selectors(self):
        for job, name in (("build", "Run selected tests"), ("test", "Run selected tests")):
            with self.subTest(job=job):
                call = step(E2E, job, name)
                self.assertEqual(call["uses"], "./.e2e-workflow/.github/actions/e2e-run-tests")
                self.assertEqual(call["with"]["target"], "${{ needs.filter.outputs.target }}")
                self.assertEqual(call["with"]["selectors"], "${{ needs.filter.outputs.selectors }}")

    def test_the_test_steps_resolve_selectors_before_running_them(self):
        resolve = action_step(E2E_TESTS, "Resolve selectors against the built tests")
        self.assertEqual(resolve["if"], "${{ inputs.target == 'cmuxTests' }}")
        run = action_step(E2E_TESTS, "Run selected tests")
        self.assertEqual(
            run["env"]["TEST_SELECTORS"],
            "${{ steps.resolve-selectors.outputs.selectors || inputs.selectors }}",
        )
        names = [s.get("name") for s in E2E_TESTS["runs"]["steps"]]
        self.assertLess(names.index("Prepare isolated app-host home"), names.index(resolve["name"]))
        self.assertLess(names.index(resolve["name"]), names.index("Run selected tests"))

        self.fake_enumeration()
        result = self.run_script(
            resolve["run"], TEST_SELECTORS="cmuxTests/ModernTests/plain,cmuxTests/ModernTests/parameterized"
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            self.outputs()["selectors"],
            "cmuxTests/ModernTests/plain(),cmuxTests/ModernTests/parameterized(value:)",
        )

    def test_a_selector_matching_no_built_test_fails_before_the_run(self):
        self.fake_enumeration()
        result = self.run_script(
            action_step(E2E_TESTS, "Resolve selectors against the built tests")["run"],
            TEST_SELECTORS="cmuxTests/ModernTests/plain,cmuxTests/ModernTests/misspelled",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("::error::cmuxTests/ModernTests/misspelled matches no built test", result.stderr)
        self.assertNotIn("selectors", self.outputs())

    def test_an_older_revision_or_failed_enumeration_runs_selectors_as_given(self):
        script = action_step(E2E_TESTS, "Resolve selectors against the built tests")["run"]
        self.tool("xcodebuild", "#!/bin/sh\nexit 70\n")
        result = self.run_script(script, TEST_SELECTORS="cmuxTests/ModernTests/plain")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("::warning::Could not enumerate", result.stdout)
        (self.workspace / "scripts/ci/focused_test_selectors.py").unlink()
        result = self.run_script(script, TEST_SELECTORS="cmuxTests/ModernTests/plain")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("selectors", self.outputs())

    def backstop(self):
        script = action_step(E2E_TESTS, "Run selected tests")["run"]
        start = script.index("if [ -f scripts/ci/focused_test_selectors.py ]; then")
        end = script.index("# Name each", start)
        return script[start:end]

    def test_the_run_step_fails_a_batch_entry_that_executed_nothing(self):
        results = self.root / "cmux-app-host-xcresults"
        results.mkdir()
        (results / "attempt-1.tests.json").write_text(json.dumps(typed_results("ModernTests/plain()")))
        for selectors, expected in (
            ("cmuxTests/ModernTests/plain()", 0),
            ("cmuxTests/ModernTests/plain(),cmuxTests/ModernTests/parameterized", 1),
        ):
            with self.subTest(selectors=selectors):
                result = self.run_script(
                    self.backstop(), TEST_TARGET="cmuxTests", TEST_SELECTORS=selectors, OUTPUT="log"
                )
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertIn("::error::cmuxTests/ModernTests/parameterized executed zero tests", result.stderr)
        self.assertIn("test_result=failed", (self.root / "output").read_text())

    def test_the_run_step_reads_ui_results_from_the_ui_bundle(self):
        bundle = self.root / "cmux-app-host-xcresults/cmuxUITests.xcresult"
        bundle.mkdir(parents=True)
        self.tool("xcrun", "#!/bin/sh\nprintf '%s' \"$FAKE_TESTS_JSON\"\n")
        result = self.run_script(
            self.backstop(), TEST_TARGET="cmuxUITests", OUTPUT="log",
            TEST_SELECTORS="cmuxUITests/FooUITests/testBar,cmuxUITests/FooUITests/testTypo",
            FAKE_TESTS_JSON=json.dumps(typed_results("FooUITests/testBar()")),
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("::error::cmuxUITests/FooUITests/testTypo executed zero tests", result.stderr)

    def test_macos_suite_ui_filter_that_executed_nothing_fails(self):
        script = step(MACOS_SUITE, "tests", "Run UI tests")["run"]
        for summary, filter_, expected in (
            ("Executed 0 tests, with 0 failures (0 unexpected) in 0.001 seconds", "FooUITests/testTypo", 1),
            ("Executed 1 test, with 0 failures (0 unexpected) in 0.5 seconds", "FooUITests/testBar", 0),
            ("Executed 0 tests, with 0 failures (0 unexpected) in 0.001 seconds", "", 0),
        ):
            with self.subTest(filter=filter_, summary=summary):
                self.tool("xcodebuild", f"#!/bin/sh\necho '** TEST SUCCEEDED **'\necho '{summary}'\n")
                result = self.run_script(script, TEST_FILTER=filter_, TEST_TIMEOUT="120")
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                if expected:
                    self.assertIn(f"::error::test_filter cmuxUITests/{filter_} executed zero tests", result.stdout)


if __name__ == "__main__":
    unittest.main()

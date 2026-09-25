#!/usr/bin/env python3
"""Tests for scripts/ci/reverse_test_impact.py and its report-only wiring.

The selector maps a diff to app code onto the cmuxTests/ suites that name what
changed. ci.yml runs it in a job of its own once routing is known, from the
trusted base revision, and only records the answer: nothing waits for that job,
it writes no output, and it cannot fail the run.
"""

from __future__ import annotations

import json
import re
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts" / "ci"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
sys.path.insert(0, str(SCRIPTS))

import reverse_test_impact as rti  # noqa: E402

REPORT_JOB = "reverse-test-impact"
REPORT_STEP = "Report reverse test impact (report only)"
UPLOAD_STEP = "Upload the reverse test impact report"

FEED_SOURCE = """\
import Foundation

final class FeedCoordinator {
    func refreshFeed() -> Int {
        return computeBadge()
    }

    private func computeBadge() -> Int {
        return 1
    }

    func update() {}
}
"""
FEED_TESTS = """\
import XCTest
@testable import cmux

final class FeedCoordinatorTests: XCTestCase {
    func testRefresh() {
        XCTAssertEqual(FeedCoordinator().refreshFeed(), 1)
    }
}
"""
UNRELATED_TESTS = """\
import XCTest

final class UnrelatedTests: XCTestCase {
    func testNothing() {
        XCTAssertTrue(true)
    }
}
"""


def hunk(path: str, line: int, count: int = 1) -> str:
    return f"--- a/{path}\n+++ b/{path}\n@@ -{line},{count} +{line},{count} @@\n"


def fixture(**extra: str) -> dict[str, str]:
    files = {
        "Sources/Feed/FeedCoordinator.swift": FEED_SOURCE,
        "cmuxTests/FeedCoordinatorTests.swift": FEED_TESTS,
        "cmuxTests/UnrelatedTests.swift": UNRELATED_TESTS,
    }
    files.update(extra)
    return files


class SelectorTests(unittest.TestCase):
    def test_a_member_change_selects_the_suite_that_names_it(self) -> None:
        # Line 5 is the body of refreshFeed().
        selection = rti.select(fixture(), hunk("Sources/Feed/FeedCoordinator.swift", 5))
        self.assertIsNone(selection.fallback)
        self.assertEqual(selection.suites, {"FeedCoordinatorTests"})
        [seed] = selection.reached
        self.assertEqual((seed.name, seed.owner, seed.how), ("refreshFeed", "FeedCoordinator", "member"))

    def test_package_sources_count_as_app_code(self) -> None:
        path = "Packages/macOS/CmuxFeed/Sources/CmuxFeed/FeedCoordinator.swift"
        files = fixture(**{path: FEED_SOURCE})
        del files["Sources/Feed/FeedCoordinator.swift"]
        selection = rti.select(files, hunk(path, 5))
        self.assertEqual(selection.app_files, [path])
        self.assertEqual(selection.suites, {"FeedCoordinatorTests"})
        # iOS packages and package tests are not what cmuxTests/ links.
        self.assertFalse(rti.is_app_path("Packages/iOS/CmuxFeed/Sources/CmuxFeed/A.swift"))
        self.assertFalse(rti.is_app_path("Packages/macOS/CmuxFeed/Tests/CmuxFeedTests/A.swift"))

    def test_a_generic_name_is_dropped_with_its_reason(self) -> None:
        # Line 12 is `func update() {}`: every test file says "update".
        selection = rti.select(fixture(), hunk("Sources/Feed/FeedCoordinator.swift", 12))
        self.assertEqual(selection.suites, set())
        self.assertEqual(
            [(seed.name, seed.owner, reason) for seed, reason in selection.dropped],
            [("update", "FeedCoordinator", "generic name")],
        )

    def test_a_hot_name_is_dropped_with_how_many_files_name_it(self) -> None:
        source = "func formatWidget() -> String {\n    \"w\"\n}\n"
        files = {"Sources/Widget.swift": source}
        for index in range(rti.HOT_TEST_FILES + 1):
            files[f"cmuxTests/Widget{index}Tests.swift"] = (
                f"final class Widget{index}Tests: XCTestCase {{\n"
                f"    func testFormat() {{ _ = formatWidget() }}\n"
                "}\n"
            )
        selection = rti.select(files, hunk("Sources/Widget.swift", 2))
        self.assertEqual(selection.suites, set())
        [(seed, reason)] = selection.dropped
        self.assertEqual(seed.name, "formatWidget")
        self.assertEqual(reason, f"hot: {rti.HOT_TEST_FILES + 1} test files")

    def test_a_private_member_traces_to_its_visible_caller(self) -> None:
        # Line 9 is the body of the private computeBadge(), which no test can
        # name; refreshFeed() calls it.
        selection = rti.select(fixture(), hunk("Sources/Feed/FeedCoordinator.swift", 9))
        self.assertEqual(selection.suites, {"FeedCoordinatorTests"})
        [seed] = selection.reached
        self.assertEqual((seed.name, seed.owner, seed.how), ("refreshFeed", "FeedCoordinator", "via-private"))

    def test_a_test_helper_continues_the_trail_to_its_suites(self) -> None:
        files = fixture(**{
            "cmuxTests/FeedFixtures.swift": (
                "struct FeedFixture {\n"
                "    static func refreshed() -> Int {\n"
                "        FeedCoordinator().refreshFeed()\n"
                "    }\n"
                "}\n"
            ),
            "cmuxTests/FeedBadgeTests.swift": (
                "final class FeedBadgeTests: XCTestCase {\n"
                "    func testBadge() { XCTAssertEqual(FeedFixture.refreshed(), 1) }\n"
                "}\n"
            ),
        })
        selection = rti.select(files, hunk("Sources/Feed/FeedCoordinator.swift", 5))
        self.assertEqual(selection.suites, {"FeedCoordinatorTests", "FeedBadgeTests"})

    def test_unparseable_input_returns_a_fallback_marker(self) -> None:
        self.assertEqual(rti.select(fixture(), None).fallback, "diff unavailable")
        self.assertEqual(rti.select(fixture(), "not a diff at all\n").fallback, "diff not parseable")
        without_tests = {"Sources/Feed/FeedCoordinator.swift": FEED_SOURCE}
        self.assertEqual(
            rti.select(without_tests, hunk("Sources/Feed/FeedCoordinator.swift", 5)).fallback,
            "cmuxTests/ not found",
        )
        # A diff that leaves app code alone is an empty answer, not a fallback.
        empty = rti.select(fixture(), hunk("docs/README.md", 1))
        self.assertIsNone(empty.fallback)
        self.assertEqual(empty.suites, set())

    def test_a_non_swift_app_file_is_reported_as_not_traced(self) -> None:
        selection = rti.select(fixture(), hunk("Sources/Feed/feed.json", 1))
        self.assertEqual(selection.nonswift_app_files, ["Sources/Feed/feed.json"])

    def test_a_deleted_app_file_is_recorded_rather_than_skipped(self) -> None:
        # Recall is measured later, so a file the selector could not read
        # has to show up in the report.
        selection = rti.select(fixture(), hunk("Sources/Feed/Gone.swift", 1))
        self.assertIn("Sources/Feed/Gone.swift deleted", selection.untraceable)


def change(path: str, removed: list[str], added: list[str]) -> str:
    """A `git diff -U0` hunk that replaces `removed` lines with `added` ones."""
    body = "".join(f"-{line}\n" for line in removed) + "".join(f"+{line}\n" for line in added)
    return f"--- a/{path}\n+++ b/{path}\n@@ -1,{len(removed)} +1,{len(added)} @@\n{body}"


CLI_OUTPUT_TESTS = """\
import XCTest

final class CLIWorkspaceRefTests: XCTestCase {
    func testMissingRef() {
        XCTAssertEqual(runCLI(["select-workspace", "workspace:9"]), "Workspace ref not found: workspace:9")
    }
}
"""


class LiteralTests(unittest.TestCase):
    """Tests that drive the CLI or socket assert on text, never on Swift names."""

    def test_a_changed_cli_literal_selects_the_suite_that_asserts_on_it(self) -> None:
        path = "CLI/cmux.swift"
        diff = change(
            path,
            ['        throw CLIError(message: "Workspace ref not found: \\(ref)")'],
            ['        throw CLIError(message: "No workspace matches \\(ref)")'],
        )
        files = fixture(**{"cmuxTests/CLIWorkspaceRefTests.swift": CLI_OUTPUT_TESTS})
        selection = rti.select(files, diff)
        self.assertEqual(selection.app_files, [path])
        self.assertEqual(selection.suites, {"CLIWorkspaceRefTests"})
        [seed] = selection.reached
        self.assertEqual((seed.name, seed.how), ("Workspace ref not found:", "string"))
        data = rti.report(selection, {})
        self.assertEqual(data["budgeted"]["kept_names"], ['"Workspace ref not found:"'])

    def test_app_source_literals_are_followed_as_well(self) -> None:
        diff = change(
            "Sources/Feed/FeedCoordinator.swift",
            ['        return "feed.refresh_badge"'],
            ['        return "feed.badge_refresh"'],
        )
        files = fixture(**{
            "cmuxTests/FeedSocketTests.swift": (
                "final class FeedSocketTests: XCTestCase {\n"
                '    func testMethod() { XCTAssertEqual(send("feed.refresh_badge"), "OK") }\n'
                "}\n"
            ),
        })
        self.assertIn("FeedSocketTests", rti.select(files, diff).suites)

    def test_a_literal_on_both_sides_of_the_diff_only_moved(self) -> None:
        line = '        print("Workspace ref not found: \\(ref)")'
        diff = change("CLI/cmux.swift", [line], ["    " + line])
        files = fixture(**{"cmuxTests/CLIWorkspaceRefTests.swift": CLI_OUTPUT_TESTS})
        self.assertEqual(rti.select(files, diff).suites, set())

    def test_short_text_comments_and_interpolations_are_not_searched(self) -> None:
        self.assertEqual(rti.literal_pieces('let flag = "--json"'), set())
        self.assertEqual(rti.literal_pieces('// "Workspace ref not found"'), set())
        self.assertEqual(
            rti.literal_pieces('fail("Workspace ref not found: \\(ref) (use --window)")'),
            {"Workspace ref not found:", "(use --window)"},
        )
        # Kept as the Swift source spells it, so a test's escaped copy matches.
        self.assertEqual(rti.literal_pieces('say("reply \\"hello there\\"")'), {'reply \\"hello there\\"'})

    def test_a_literal_many_tests_contain_is_dropped_as_hot(self) -> None:
        diff = change("CLI/cmux.swift", ['    let key = "workspace_id_value"'], [])
        files = fixture()
        for index in range(rti.HOT_TEST_FILES + 1):
            files[f"cmuxTests/Ref{index}Tests.swift"] = (
                f"final class Ref{index}Tests: XCTestCase {{\n"
                '    func testKey() { _ = "workspace_id_value" }\n'
                "}\n"
            )
        selection = rti.select(files, diff)
        self.assertEqual(selection.suites, set())
        self.assertEqual(
            [(seed.name, reason) for seed, reason in selection.dropped],
            [("workspace_id_value", f"hot: {rti.HOT_TEST_FILES + 1} test files")],
        )

    def test_text_moved_to_another_file_only_moved(self) -> None:
        line = '        throw CLIError(message: "Workspace ref not found: \\(ref)")'
        diff = change("CLI/cmux.swift", [line], []) + change("CLI/CMUXCLI+Refs.swift", [], [line])
        files = fixture(**{"cmuxTests/CLIWorkspaceRefTests.swift": CLI_OUTPUT_TESTS})
        self.assertEqual(rti.changed_literals(diff), {})
        self.assertEqual(rti.select(files, diff).suites, set())

    def test_a_literal_that_is_also_a_common_property_name_is_still_followed(self) -> None:
        # Three app files declare `surfaceIdentifier`; as a name it is
        # ambiguous, but as JSON text a test asserts on it is specific.
        files = fixture(**{
            f"Sources/Surface{index}.swift": f"struct Surface{index} {{ var surfaceIdentifier = 0 }}\n"
            for index in range(rti.AMBIGUOUS_APP_DECLARATIONS)
        })
        files["cmuxTests/CLISurfaceJSONTests.swift"] = (
            "final class CLISurfaceJSONTests: XCTestCase {\n"
            '    func testKey() { XCTAssertTrue(output().contains("surfaceIdentifier")) }\n'
            "}\n"
        )
        diff = change("CLI/cmux.swift", ['    payload["surfaceIdentifier"] = id'], ['    payload["surface_id"] = id'])
        self.assertEqual(rti.select(files, diff).suites, {"CLISurfaceJSONTests"})

    def test_a_literal_is_followed_through_a_test_helper(self) -> None:
        files = fixture(**{
            "cmuxTests/CLIFixtures.swift": (
                "enum CLIFixtures {\n"
                '    static let missingRef = "Workspace ref not found: workspace:9"\n'
                "}\n"
            ),
            "cmuxTests/CLIRefErrorTests.swift": (
                "final class CLIRefErrorTests: XCTestCase {\n"
                "    func testMessage() { XCTAssertEqual(run(), CLIFixtures.missingRef) }\n"
                "}\n"
            ),
        })
        diff = change("CLI/cmux.swift", ['    fail("Workspace ref not found: \\(ref)")'], [])
        self.assertEqual(rti.select(files, diff).suites, {"CLIRefErrorTests"})

    def test_a_literal_does_not_hide_a_type_with_the_same_name(self) -> None:
        # Line 3 is inside FeedCoordinator; the literal names it too.
        diff = hunk("Sources/Feed/FeedCoordinator.swift", 3) + change(
            "Sources/Feed/FeedLabels.swift", [], ['    let id = "FeedCoordinator"']
        )
        seeds = {(seed.name, seed.how) for seed in rti.select(fixture(), diff).reached}
        self.assertIn(("FeedCoordinator", "string"), seeds)
        self.assertIn(("FeedCoordinator", "top"), seeds)

    def test_literals_past_the_cap_are_recorded_not_searched(self) -> None:
        added = [f'    let m{index} = "distinct message number {index}"' for index in range(5)]
        with unittest.mock.patch.object(rti, "MAX_LITERAL_SEEDS", 3):
            selection = rti.select(fixture(), change("CLI/cmux.swift", [], added))
        self.assertIn("CLI/cmux.swift literals over the cap of 3", selection.untraceable)

    def test_text_no_test_contains_is_left_out_of_the_report(self) -> None:
        diff = change("CLI/cmux.swift", ['    log("an internal log line nobody asserts")'], [])
        selection = rti.select(fixture(), diff)
        self.assertEqual((selection.reached, selection.dropped), ({}, []))
        self.assertEqual(selection.app_files, ["CLI/cmux.swift"])


class BudgetTests(unittest.TestCase):
    def test_over_budget_keeps_the_most_specific_names_that_fit(self) -> None:
        narrow = rti.Seed("refreshFeed", "FeedCoordinator", "member")
        broad = rti.Seed("FeedStore", None, "top")
        selection = rti.Selection(reached={
            broad: ({"FeedCoordinatorTests", "FeedStoreTests"}, set()),
            narrow: ({"FeedCoordinatorTests"}, set()),
        })
        costs = {"FeedCoordinatorTests": 60_000, "FeedStoreTests": 20 * 60_000}
        data = rti.report(selection, costs, budget_ms=10 * 60_000)
        self.assertTrue(data["over_budget"])
        self.assertEqual(data["cost_ms"], 21 * 60_000)
        self.assertEqual(data["would_run"], ["FeedCoordinatorTests"])
        self.assertEqual(data["budgeted"]["cost_ms"], 60_000)
        self.assertEqual(data["budgeted"]["kept_names"], ["FeedCoordinator.refreshFeed"])
        self.assertEqual(data["budgeted"]["left_out_names"], ["FeedStore"])

    def test_under_budget_would_run_the_whole_selection(self) -> None:
        seed = rti.Seed("refreshFeed", "FeedCoordinator", "member")
        selection = rti.Selection(reached={seed: ({"FeedCoordinatorTests", "NewTests"}, set())})
        data = rti.report(selection, {"FeedCoordinatorTests": 1_000}, default_ms=200)
        self.assertFalse(data["over_budget"])
        self.assertEqual(data["budget_ms"], rti.CHANGED_SUITES_BUDGET_MS)
        self.assertEqual(data["would_run"], ["FeedCoordinatorTests", "NewTests"])
        self.assertEqual(data["cost_ms"], 1_200)
        self.assertEqual(data["unmeasured_suites"], ["NewTests"])

    def test_suite_costs_come_from_the_measured_timings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "cmuxTests").mkdir()
            (root / "cmuxTests/MeasuredTests.swift").write_text(
                "final class MeasuredTests: XCTestCase {\n    func testA() {}\n}\n"
            )
            (root / "cmuxTests/GuessedTests.swift").write_text(
                "final class GuessedTests: XCTestCase {\n"
                "    func testA() {}\n    func testB() {}\n    func testC() {}\n}\n"
            )
            timings = {"default_test_ms": 200, "suites": {"MeasuredTests": 4_321}, "methods": {}}
            costs = rti.suite_costs(root, timings)
        self.assertEqual(costs["MeasuredTests"], 4_321)
        self.assertEqual(costs["GuessedTests"], 3 * 200)


class CommandLineTests(unittest.TestCase):
    def write_tree(self, root: Path) -> None:
        for path, text in fixture().items():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(text)

    def test_writes_the_report_and_a_step_summary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_tree(root)
            (root / "app.diff").write_text(hunk("Sources/Feed/FeedCoordinator.swift", 5))
            output, summary = root / "report.json", root / "summary.md"
            status = rti.main([
                "--root", str(root), "--diff-from", str(root / "app.diff"),
                "--output", str(output), "--summary", str(summary),
            ])
            self.assertEqual(status, 0)
            data = json.loads(output.read_text())
            text = summary.read_text()
        self.assertTrue(data["report_only"])
        self.assertEqual(data["would_run"], ["FeedCoordinatorTests"])
        self.assertIn("### Reverse test impact (report only)", text)
        self.assertIn("would run: FeedCoordinatorTests", text)
        self.assertIn("Nothing here changes which jobs run.", text)

    def test_a_missing_diff_or_an_error_still_exits_zero(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_tree(root)
            output, summary = root / "report.json", root / "summary.md"
            argv = [
                "--root", str(root), "--diff-from", str(root / "missing.diff"),
                "--output", str(output), "--summary", str(summary),
            ]
            self.assertEqual(rti.main(argv), 0)
            self.assertEqual(json.loads(output.read_text())["fallback"], "diff unavailable")
            with unittest.mock.patch.object(rti, "run", side_effect=RuntimeError("boom")), \
                    unittest.mock.patch("sys.stderr"):
                self.assertEqual(rti.main(argv), 0)
            data = json.loads(output.read_text())
            text = summary.read_text()
        self.assertTrue(data["fallback"].startswith("selector error"))
        self.assertIn("No selection: selector error", text)


def jobs(workflow: str) -> dict[str, str]:
    """Each top-level job's block, by id, in file order."""
    body = workflow.split("\njobs:\n", 1)[1]
    out: dict[str, str] = {}
    for block in re.split(r"(?m)^(?=  [A-Za-z0-9_-]+:[ \t]*$)", body):
        match = re.match(r"  ([A-Za-z0-9_-]+):", block)
        if match:
            out[match.group(1)] = block
    return out


def needs(block: str) -> set[str]:
    """The jobs a job block waits for, inline (`needs: [a, b]`) or as a list."""
    match = re.search(r"(?m)^    needs:[ \t]*(.*)$", block)
    if match is None:
        return set()
    inline = set(re.findall(r"[A-Za-z0-9_-]+", match.group(1)))
    if inline:
        return inline
    listed = block[match.end():].split("\n")
    out: set[str] = set()
    for line in listed[1:]:
        item = re.match(r"^      - ([A-Za-z0-9_-]+)[ \t]*$", line)
        if item is None:
            break
        out.add(item.group(1))
    return out


def steps(job: str) -> list[tuple[str, str]]:
    """(name, block) for each step of a job, in order."""
    out: list[tuple[str, str]] = []
    for block in job.split("\n      - name: ")[1:]:
        out.append((block.split("\n", 1)[0].strip(), "      - name: " + block))
    return out


class WorkflowGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.jobs = jobs(CI_WORKFLOW.read_text(encoding="utf-8"))
        cls.job = cls.jobs[REPORT_JOB]
        cls.steps = steps(cls.job)
        cls.names = [name for name, _ in cls.steps]
        cls.report = dict(cls.steps)[REPORT_STEP]
        cls.upload = dict(cls.steps)[UPLOAD_STEP]

    def job_line(self, key: str) -> str:
        return next(line for line in self.job.splitlines() if line.startswith(f"    {key}:"))

    def test_the_report_job_can_never_fail_the_run(self) -> None:
        self.assertEqual(self.job_line("continue-on-error"), "    continue-on-error: true")
        self.assertEqual(self.job_line("timeout-minutes"), "    timeout-minutes: 5")
        condition = self.job_line("if")
        self.assertIn("github.event_name == 'pull_request'", condition)
        self.assertIn("needs.changes.result == 'success'", condition)
        for block in (self.report, self.upload):
            self.assertIn("        continue-on-error: true", block.splitlines())
        self.assertNotIn("set -e", self.report)
        self.assertEqual(self.report.rstrip().splitlines()[-1].strip(), "exit 0")

    def test_the_report_job_is_off_the_critical_path(self) -> None:
        # It starts once routing is known and nothing waits for it: not
        # ci-status, not any rollup, not any other job.
        self.assertEqual(needs(self.job), {"changes"})
        dependents = sorted(name for name, block in self.jobs.items() if REPORT_JOB in needs(block))
        self.assertEqual(dependents, [])
        self.assertIn("changes", needs(self.jobs["ci-status"]))
        for name, block in self.jobs.items():
            if name != REPORT_JOB:
                self.assertNotIn(f"needs.{REPORT_JOB}", block, name)
        # The same Linux runner, with the same fork fallback, as `changes`.
        self.assertEqual(self.job_line("runs-on"), jobs_line(self.jobs["changes"], "runs-on"))
        self.assertIn("github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'", self.job_line("runs-on"))

    def test_the_report_job_writes_no_outputs(self) -> None:
        self.assertFalse(any(line.startswith("    outputs:") for line in self.job.splitlines()))
        for sink in ("GITHUB_OUTPUT", "GITHUB_ENV", "GITHUB_PATH"):
            self.assertNotIn(sink, self.job, sink)
        self.assertFalse(any(line.startswith("        id: ") for line in self.job.splitlines()))
        self.assertEqual(self.job_line("permissions"), "    permissions:")
        self.assertIn("      contents: read", self.job.splitlines())

    def test_the_report_reads_its_own_checkout(self) -> None:
        self.assertEqual(self.names, ["Checkout", REPORT_STEP, UPLOAD_STEP])
        checkout = dict(self.steps)["Checkout"].splitlines()
        self.assertIn("          fetch-depth: 2", checkout)
        self.assertIn("          persist-credentials: false", checkout)
        # Its changed-file list is its own, not a file another job wrote.
        self.assertNotIn("/tmp/cmux-ci-", self.job)
        self.assertIn('git diff --no-renames --name-only "$base" HEAD', self.report)
        # CLI/ too: its string literals are what the CLI suites assert on.
        self.assertIn("^(Sources/|CLI/|Packages/(macOS|Shared)/[^/]+/Sources/)", self.report)
        self.assertIn("-- Sources Packages/macOS Packages/Shared CLI >", self.report)

    def test_the_selector_runs_from_the_trusted_base_revision(self) -> None:
        # The pull request's own copy never runs: it is read out of the merge
        # commit's first parent into a directory of its own.
        self.assertIn("git rev-parse -q --verify 'HEAD^1'", self.report)
        self.assertRegex(self.report, r'git archive "\$base" --')
        self.assertIn('python3 -I "$trusted/scripts/ci/reverse_test_impact.py"', self.report)
        self.assertNotRegex(self.job, r"python3 (-I )?scripts/ci/reverse_test_impact\.py")
        # Everything it imports from scripts/ci/ comes along, or the trusted
        # copy fails to import and reports nothing.
        source = (SCRIPTS / "reverse_test_impact.py").read_text(encoding="utf-8")
        needed = {"scripts/ci/reverse_test_impact.py", "scripts/ci/cmux-unit-test-timings.json"}
        pending = [source]
        while pending:
            for module in re.findall(r"^from (\w+) import", pending.pop(), re.M):
                path = SCRIPTS / f"{module}.py"
                relative = f"scripts/ci/{module}.py"
                if path.exists() and relative not in needed:
                    needed.add(relative)
                    pending.append(path.read_text(encoding="utf-8"))
        for relative in sorted(needed):
            self.assertIn(relative, self.report, relative)

    def test_the_upload_is_small_and_optional(self) -> None:
        lines = self.upload.splitlines()
        self.assertRegex(self.upload, r"uses: actions/upload-artifact@[0-9a-f]{40} ")
        self.assertIn("          retention-days: 14", lines)
        self.assertIn("          if-no-files-found: ignore", lines)


def jobs_line(block: str, key: str) -> str:
    return next(line for line in block.splitlines() if line.startswith(f"    {key}:"))


if __name__ == "__main__":
    unittest.main(verbosity=2)

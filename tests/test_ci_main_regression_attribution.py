"""New failures on main's full suite, their suspect pull requests, and the report text."""

import importlib.util
import json
import pathlib
import sys
import unittest
import git_fixture_env  # noqa: F401  (disables git auto maintenance)

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/main_regression_attribution.py"
WORKFLOW = ROOT / ".github/workflows/ci-main-full-suite.yml"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("main_regression_attribution", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE  # dataclasses resolve annotations through it
SPEC.loader.exec_module(MODULE)

REPO = "manaflow-ai/cmux"
PREV = "p" * 40
HEAD = "h" * 40
LOG = """\
2026-09-25T07:44:10.4990000Z Test Case '-[cmuxTests.FooTests testBar]' failed (0.1 seconds).
2026-09-25T07:44:10.4990110Z RATCHET_NEW_FAILURE AgentSessionAutoResumeSwiftTests/splitAfterRestore()
2026-09-25T07:44:10.4990120Z \x1b[31mRATCHET_NEW_FAILURE FooTests/testBar\x1b[0m
2026-09-25T07:44:10.4990130Z RATCHET_KNOWN_FAILURE SidebarHiddenPresentationTests/visibility()
2026-09-25T07:44:10.4990140Z   echo "RATCHET_NEW_FAILURE $identifier"
"""
# A dedicated batch the ratchet does not grade reports only through xcodebuild.
XCODEBUILD_LOG = """\
2026-09-25T05:55:55.4893920Z Failing tests:
2026-09-25T05:55:55.4894300Z \tGlobalSearchLocalMonitorChainTests.visibleSearchCloses()
2026-09-25T05:55:55.4894300Z \tGlobalSearchLocalMonitorChainTests.visibleSearchCloses()
2026-09-25T05:55:55.4894400Z \tcmuxTests.LegacyTests.testOld()
2026-09-25T05:55:55.4894500Z \tSidebarHiddenPresentationTests.visibility()
2026-09-25T05:55:55.4907210Z 
2026-09-25T05:55:55.4907400Z \x1b[1m\x1b[31m** TEST EXECUTE FAILED **
2026-09-25T05:55:55.4907500Z \tNotATest.after()
"""


# The shard 7 log of main run 36307768440, cut down: the app host aborted under
# RecoverableMainWindowLifecycleTests, xcodebuild restarted it, and the
# accounting recorded the test in flight as a new failure.
VICTIM = "RecoverableMainWindowLifecycleTests/closingRecoveredWindowUsesNormalCloseFinalization()"
CRASH_LOG = """\
2026-09-27T09:06:35.6623060Z     /Applications/Xcode_26.6.app/Contents/Developer/usr/bin/xcodebuild -xctestrun /x/cmux-unit.xctestrun
2026-09-27T09:07:36.2652870Z \u25c7 Test "Closing a recovered window uses normal close finalization" started.
2026-09-27T09:07:36.2653460Z objc[73048]: Cannot form weak reference to instance (0x76e0e4f00) of class NSKVONotifying_NSWindow. It is possible that this object was over-released, or is in the process of deallocation.
2026-09-27T09:07:36.2653820Z 
2026-09-27T09:07:36.2653890Z *** Signal 6: Backtracing from 0x18cadab10... done ***
2026-09-27T09:07:36.2654010Z 
2026-09-27T09:07:36.2654080Z *** Program crashed: Aborted at 0x000000018cadab10 ***
2026-09-27T09:07:36.2654420Z Thread 0 crashed:
2026-09-27T09:07:41.2857780Z Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
2026-09-27T09:07:56.4282040Z Failing tests:
2026-09-27T09:07:56.4282280Z \tRecoverableMainWindowLifecycleTests.closingRecoveredWindowUsesNormalCloseFinalization()
2026-09-27T09:07:56.4282510Z 
2026-09-27T09:07:56.4282550Z ** TEST EXECUTE FAILED **
2026-09-27T09:08:01.5247210Z incomplete app-host run: app host restarted after test execution
2026-09-27T09:08:01.5247600Z RATCHET_NEW_FAILURE RecoverableMainWindowLifecycleTests/closingRecoveredWindowUsesNormalCloseFinalization()
2026-09-27T09:08:01.5247950Z recorded verdicts: 1 new, 0 known-main; typed test cases: 845
2026-09-27T09:08:12.2949580Z     /Applications/Xcode_26.6.app/Contents/Developer/usr/bin/xcodebuild -xctestrun /x/cmux-unit.xctestrun
2026-09-27T09:08:30.0000000Z Failing tests:
2026-09-27T09:08:30.0000000Z \tOtherTests.plainFailure()
2026-09-27T09:08:30.0000000Z 
2026-09-27T09:08:31.0000000Z RATCHET_NEW_FAILURE OtherTests/plainFailure()
2026-09-27T09:08:31.0000000Z recorded verdicts: 1 new, 0 known-main; typed test cases: 12
2026-09-27T09:08:54.2024000Z   name: cmux-app-host-diagnostics-shard-7-run-1
"""
CRASH_SIGNATURE = "Cannot form weak reference to instance (0x*) of class NSKVONotifying_NSWindow"


def run(**overrides):
    base = {
        "id": 2, "event": "workflow_dispatch", "head_branch": "main", "path": ".github/workflows/ci.yml",
        "head_sha": HEAD, "status": "completed", "conclusion": "failure",
        "created_at": "2026-09-25T07:00:00Z", "html_url": "https://github.com/x/runs/2",
    }
    base.update(overrides)
    return base


def pr_node(number, merge_sha, state="MERGED", base="main", labels=()):
    return {
        "number": number, "title": f"PR {number}", "url": f"https://github.com/{REPO}/pull/{number}",
        "state": state, "baseRefName": base, "author": {"login": "someone"},
        "mergeCommit": {"oid": merge_sha} if merge_sha else None,
        "labels": {"nodes": [{"name": name} for name in labels]},
    }


def pr(number, edited=(), reached=(), unverified=False, ranked=True):
    return MODULE.PullRequest(
        number=number, title=f"PR {number}", url=f"u/{number}", merge_sha=f"m{number}",
        edited_suites=set(edited), reached_suites=set(reached), unverified=unverified,
        paths=["Sources/App.swift"] if ranked else [], ranked=ranked,
    )


class ExtractionTests(unittest.TestCase):
    def test_reads_only_ratchet_new_failure_verdict_lines(self):
        self.assertEqual(
            MODULE.log_failures(LOG),
            {"AgentSessionAutoResumeSwiftTests/splitAfterRestore()", "FooTests/testBar"},
        )

    def test_reads_the_xcodebuild_failing_tests_block_minus_the_catalog(self):
        self.assertEqual(
            MODULE.log_failures(XCODEBUILD_LOG, {"SidebarHiddenPresentationTests/visibility()"}),
            {"GlobalSearchLocalMonitorChainTests/visibleSearchCloses()", "LegacyTests/testOld()"},
        )
        # A dedicated lane's xcodebuild failure stops the shard before its
        # graded batches, so it is not a verdict on the shard.
        self.assertFalse(MODULE.shard_log_complete(MODULE.ANSI_RE.sub("", XCODEBUILD_LOG)))

    def test_catalog_ids_match_what_the_log_names(self):
        known = set(MODULE.json.loads(MODULE.CATALOG.read_text())["tests"])
        listed = "Failing tests:\n" + "".join("\t" + t.replace("/", ".", 1) + "\n" for t in known)
        self.assertEqual(MODULE.log_failures(listed, known), set())

    def test_a_failed_shard_is_complete_only_when_every_batch_was_graded(self):
        self.assertTrue(MODULE.shard_log_complete(LOG))
        self.assertTrue(MODULE.shard_log_complete("typed app-host run passed: 796 test cases\n"))
        # Failed before any batch was graded: no verdict at all.
        self.assertFalse(MODULE.shard_log_complete("##[error]Process completed with exit code 1.\n"))
        for stop in (
            "incomplete app-host run: app host restarted after test execution",
            "typed xcresult is incomplete: 3 selected Test Case(s) have no terminal result",
            "No typed xcresult test JSON found for unit-physical-3",
            "xcodebuild status 70 is not ratchetable",
            "inventory lists no built tests",
            "no selectors: nothing was selected to run",
        ):
            with self.subTest(stop=stop):
                self.assertFalse(MODULE.shard_log_complete(LOG + stop + "\n"))

    def test_app_host_ran_needs_every_shard_finished(self):
        shards = [{"name": f"macos / app-host unit tests ({n}/7)", "conclusion": "failure"} for n in range(1, 8)]
        rollup = {"name": "ci-status", "conclusion": "failure"}
        self.assertTrue(MODULE.app_host_ran(shards + [rollup]))
        self.assertFalse(MODULE.app_host_ran(shards[:-1] + [{**shards[-1], "conclusion": "cancelled"}]))
        # A compile break skips every shard, which says nothing about tests.
        self.assertFalse(MODULE.app_host_ran([{"name": "macos / macOS compile admission", "conclusion": "failure"}]))


class CrashTests(unittest.TestCase):
    def test_a_restarted_batch_names_the_test_the_app_died_under_and_the_crash(self):
        crash = MODULE.host_crash(CRASH_LOG, (), "7", "https://job/7")
        self.assertEqual(crash.tests, [VICTIM])  # the next batch's plain failure is not the crash's
        self.assertEqual(crash.signatures, [CRASH_SIGNATURE])
        self.assertEqual(crash.artifact, "cmux-app-host-diagnostics-shard-7-run-1")
        self.assertEqual(MODULE.log_failures(CRASH_LOG), {VICTIM, "OtherTests/plainFailure()"})
        self.assertIsNone(MODULE.host_crash(LOG))
        self.assertEqual(MODULE.host_crash(CRASH_LOG, {VICTIM}).tests, [])

    def test_the_signature_falls_back_to_the_crash_reason_then_to_the_last_message(self):
        header_only = CRASH_LOG.replace("objc[73048]:", "note:")
        self.assertEqual(MODULE.host_crash(header_only).signatures, ["crashed: Aborted"])
        # No backtracer header: the message before the restart names the crash.
        no_header = "\n".join(
            line for line in CRASH_LOG.splitlines() if "Program crashed" not in line
        ).replace("objc[73048]: Cannot form", "cmux/App.swift:12: Fatal error: Cannot form")
        self.assertEqual(
            MODULE.host_crash(no_header).signatures,
            ["Fatal error: Cannot form weak reference to instance (0x*) of class NSKVONotifying_NSWindow"],
        )
        silent = "\n".join(line for line in header_only.splitlines() if "Program crashed" not in line)
        self.assertEqual(MODULE.host_crash(silent).signatures, [])
        # A restart-budget abort with no accounting afterwards still counts as a restart.
        aborted = "Aborted by the app-host restart budget: xcodebuild restarted the app host 3 times\n"
        self.assertEqual(MODULE.host_crash(aborted).tests, [])

    def test_a_crash_is_recurring_only_when_an_earlier_run_showed_every_signature(self):
        same = MODULE.HostCrash("3", signatures=[CRASH_SIGNATURE])
        other = MODULE.HostCrash("3", signatures=["Fatal error: something else"])
        unknown = MODULE.HostCrash("3")
        crash = MODULE.HostCrash("7", signatures=[CRASH_SIGNATURE])
        earlier_run = run(id=1)
        self.assertIsNone(MODULE.prior_crash(crash, []))
        self.assertIsNone(MODULE.prior_crash(crash, [(earlier_run, other)]))
        self.assertEqual(MODULE.prior_crash(crash, [(earlier_run, other), (earlier_run, same)]), (earlier_run, same))
        # No signature on either side cannot be compared, so it is new.
        self.assertIsNone(MODULE.prior_crash(crash, [(earlier_run, unknown)]))
        self.assertIsNone(MODULE.prior_crash(unknown, [(earlier_run, same)]))
        # A shard that also crashed a new way is not excused by the known one.
        both = MODULE.HostCrash("7", signatures=[CRASH_SIGNATURE, "Fatal error: something new"])
        self.assertIsNone(MODULE.prior_crash(both, [(earlier_run, same)]))
        self.assertEqual(MODULE.prior_crash(both, [(earlier_run, same), (earlier_run, MODULE.HostCrash(
            "1", signatures=["Fatal error: something new"]))]), (earlier_run, same))

    def test_only_the_test_in_flight_is_the_crash_victim(self):
        # The accounting lists every failure of a restarted batch; a plain
        # assertion failure printed its own failed line and stays a regression.
        log = CRASH_LOG.replace(
            "2026-09-27T09:07:36.2652870Z",
            "2026-09-27T09:07:30.0000000Z \u25c7 Test plainFailure() started.\n"
            "2026-09-27T09:07:30.1000000Z \u2718 Test plainFailure() failed after 0.1 seconds with 1 issue.\n"
            "2026-09-27T09:07:36.2652870Z", 1,
        ).replace(
            "\tRecoverableMainWindowLifecycleTests.closingRecoveredWindowUsesNormalCloseFinalization()\n",
            "\tRecoverableMainWindowLifecycleTests.closingRecoveredWindowUsesNormalCloseFinalization()\n"
            "2026-09-27T09:07:56.4282300Z \tRecoverableMainWindowLifecycleTests.plainFailure()\n", 1,
        ).replace(
            "recorded verdicts: 1 new, 0 known-main; typed test cases: 845",
            "RATCHET_NEW_FAILURE RecoverableMainWindowLifecycleTests/plainFailure()\n"
            "recorded verdicts: 2 new, 0 known-main; typed test cases: 845", 1,
        )
        crash = MODULE.host_crash(log, (), "7", "https://job/7")
        self.assertEqual(crash.tests, [VICTIM])
        plain = "RecoverableMainWindowLifecycleTests/plainFailure()"
        failures = {VICTIM: ["https://job/7"], plain: ["https://job/7"]}
        finding = MODULE.CrashFinding(crash, (run(id=1), MODULE.HostCrash("2", signatures=[CRASH_SIGNATURE])))
        regressions, attributed, crashed = MODULE.split_crashes(failures, [finding])
        self.assertEqual((list(regressions), list(attributed), crashed), ([plain], [plain], {}))
        suite = pr(9, edited={"RecoverableMainWindowLifecycleTests"})
        attributions = {plain: MODULE.suspects_for(plain, [suite])}
        self.assertEqual([p.number for p, _, _, _ in MODULE.comment_plan(attributed, attributions)], [9])
        text = MODULE.issue_section(
            repo=REPO, run=run(), previous=run(id=1, head_sha=PREV), failures=regressions,
            attributions=attributions, prs=[suite], direct=[], commits=[], crashes=[finding],
        )
        marker = [line for line in text.splitlines() if line.startswith(MODULE.DATA_PREFIX)][0]
        data = json.loads(marker[len(MODULE.DATA_PREFIX):-3])
        self.assertEqual(data["tests"], [{"test": plain, "suspects": [9], "how": "only pull request in the range; edits the suite"}])

    def test_a_display_name_maps_to_its_function_through_the_sources(self):
        source = (
            '@Suite struct RecoverableMainWindowLifecycleTests {\n'
            '    @Test("Closing a recovered window uses normal close finalization")\n'
            '    @MainActor\n    func closingRecoveredWindowUsesNormalCloseFinalization() async {}\n'
            '    @Test("Shared") func a() {}\n}\n'
        )
        names = MODULE.swift_test_names([source, '@Test("Shared") func b() {}'])
        self.assertEqual(names, {"Closing a recovered window uses normal close finalization": "closingRecoveredWindowUsesNormalCloseFinalization"})
        # Two unexplained failures and one restart: the log cannot say which
        # one the app died under without the display-name map, so neither is.
        two = CRASH_LOG.replace(
            "RATCHET_NEW_FAILURE RecoverableMainWindowLifecycleTests/closingRecoveredWindowUsesNormalCloseFinalization()",
            "RATCHET_NEW_FAILURE RecoverableMainWindowLifecycleTests/closingRecoveredWindowUsesNormalCloseFinalization()\n"
            "RATCHET_NEW_FAILURE RecoverableMainWindowLifecycleTests/silentFailure()", 1,
        )
        self.assertEqual(MODULE.host_crash(two).tests, [])
        self.assertEqual(MODULE.host_crash(two, display_names=names).tests, [VICTIM])
        # An XCTest in flight is named by the live log itself.
        xctest = two.replace(
            '\u25c7 Test "Closing a recovered window uses normal close finalization" started.',
            "Test Case '-[cmuxTests.RecoverableMainWindowLifecycleTests silentFailure]' started.",
        )
        self.assertEqual(MODULE.host_crash(xctest).tests, ["RecoverableMainWindowLifecycleTests/silentFailure()"])


class BaselineTests(unittest.TestCase):
    def test_previous_run_is_an_earlier_tested_full_suite_run(self):
        current = run()
        runs = [
            current,
            run(id=5, created_at="2026-09-25T08:00:00Z"),  # later
            run(id=3, created_at="2026-09-25T06:00:00Z", conclusion="cancelled"),
            run(id=4, created_at="2026-09-25T05:00:00Z", event="pull_request"),
            run(id=1, created_at="2026-09-25T04:00:00Z", conclusion="success"),
            run(id=0, created_at="2026-09-25T03:00:00Z"),
        ]
        self.assertEqual([r["id"] for r in MODULE.earlier_tested_runs(runs, current)], [1, 0])

    def test_new_failures_drop_what_failed_before(self):
        current = {"A/a()": ["j1"], "B/b()": ["j2"]}
        shards = {"A/a()": {"1"}, "B/b()": {"2"}}
        self.assertEqual(MODULE.new_failures(current, shards, {"A/a()"}, set()), ({"B/b()": ["j2"]}, []))
        self.assertEqual(MODULE.new_failures(current, shards, set(), set()), (current, []))

    def test_a_shard_the_baseline_did_not_grade_gives_no_verdict(self):
        current = {"A/a()": ["j1"], "B/b()": ["j2"], "C/c()": ["j3", "j4"]}
        shards = {"A/a()": {"1"}, "B/b()": {"2"}, "C/c()": {"2", "3"}}
        self.assertEqual(
            MODULE.new_failures(current, shards, set(), {"2"}),
            ({"A/a()": ["j1"], "C/c()": ["j3", "j4"]}, ["B/b()"]),
        )

    def test_shard_map_changed_compares_the_packing_inputs(self):
        import subprocess, tempfile
        with tempfile.TemporaryDirectory() as repo:
            def git(*args):
                return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True).stdout.strip()
            git("init", "-q")
            git("config", "user.email", "t@t"); git("config", "user.name", "t")
            (pathlib.Path(repo) / "cmuxTests").mkdir()
            (pathlib.Path(repo) / "cmuxTests/A.swift").write_text("a")
            git("add", "-A"); git("commit", "-qm", "a"); first = git("rev-parse", "HEAD")
            (pathlib.Path(repo) / "Sources").mkdir()
            (pathlib.Path(repo) / "Sources/B.swift").write_text("b")
            git("add", "-A"); git("commit", "-qm", "b"); second = git("rev-parse", "HEAD")
            (pathlib.Path(repo) / "cmuxTests/A.swift").write_text("a2")
            git("add", "-A"); git("commit", "-qm", "c"); third = git("rev-parse", "HEAD")
            self.assertFalse(MODULE.shard_map_changed(pathlib.Path(repo), first, second))
            self.assertTrue(MODULE.shard_map_changed(pathlib.Path(repo), second, third))
            self.assertTrue(MODULE.shard_map_changed(pathlib.Path(repo), first, "0" * 40))

    def test_shard_of_reads_the_job_name(self):
        self.assertEqual(MODULE.shard_of({"name": "macos / app-host unit tests (4/7)"}), "4")


class MergedPullRequestTests(unittest.TestCase):
    def test_only_pull_requests_merged_by_a_commit_in_the_range_count(self):
        # rev-list order: newest first.
        shas = ["m2", "branchcommit", "m1", "direct"]
        associated = {
            "m2": [pr_node(2, "m2")],
            "branchcommit": [pr_node(2, "m2"), pr_node(9, None, state="OPEN")],
            "m1": [pr_node(1, "m1"), pr_node(7, "elsewhere")],
            "direct": [pr_node(8, "m8", base="release")],
        }
        prs, direct = MODULE.merged_prs(shas, associated)
        self.assertEqual([p.number for p in prs], [1, 2])  # oldest merge first
        self.assertEqual(direct, ["direct"])


class RankingTests(unittest.TestCase):
    def test_the_only_pull_request_must_reach_the_suite(self):
        only = pr(1, reached={"Suite"})
        self.assertEqual(
            MODULE.suspects_for("Suite/test()", [only]),
            ([only], "only pull request in the range; changes code the suite names"),
        )
        self.assertEqual(MODULE.suspects_for("Other/test()", [only]), ([], "the only pull request in the range does not reach this suite"))
        outside = pr(2)
        outside.paths, outside.ranked = ["docs/a.md", "web/tests/x.test.ts"], True
        self.assertEqual(
            MODULE.suspects_for("Suite/test()", [outside])[1],
            "the only pull request in the range changes nothing the app host loads",
        )
        # A test-only diff is loaded by the app host, so that reason would be wrong.
        outside.paths = ["cmuxTests/OtherTests.swift"]
        self.assertEqual(MODULE.suspects_for("Suite/test()", [outside])[1], "the only pull request in the range does not reach this suite")
        self.assertEqual(
            MODULE.suspects_for("Suite/test()", [pr(3, ranked=False)])[1],
            "the only pull request in the range could not be diffed",
        )

    def test_a_changed_localized_string_reaches_a_suite_that_spells_it(self):
        old = json.dumps({"strings": {
            "agent.codex": {"localizations": {"en": {"stringUnit": {"value": "Codex"}}, "de": {"stringUnit": {"value": "Kodex"}}}},
            "settings.open": {"localizations": {"en": {"stringUnit": {"value": "Open Settings Window"}}}},
            "same": {"localizations": {"en": {"stringUnit": {"value": "Unchanged text here"}}}},
        }})
        new = json.dumps({"strings": {
            "agent.codex": {"localizations": {"en": {"stringUnit": {"value": "Codex"}}, "de": {"stringUnit": {"value": "Codex"}}}},
            "settings.open": {"localizations": {"en": {"stringUnit": {"value": "Open the Settings Window"}}}},
            "same": {"localizations": {"en": {"stringUnit": {"value": "Unchanged text here"}}}},
        }})
        literals = MODULE.xcstrings_literals(old, new)
        self.assertEqual(literals, {
            "agent.codex", "Kodex", "settings.open", "Open Settings Window", "Open the Settings Window",
        })
        import reverse_test_impact
        files = {
            "Sources/App.swift": "struct App {}\n",
            "cmuxTests/SettingsTests.swift": (
                "import XCTest\n\nfinal class SettingsTests: XCTestCase {\n"
                "    func testTitle() {\n        XCTAssertEqual(title, \"Open the Settings Window\")\n    }\n}\n"
            ),
            "cmuxTests/AgentTests.swift": (
                "import XCTest\n\nfinal class AgentTests: XCTestCase {\n"
                "    func testName() {\n        XCTAssertEqual(name, \"Codex\")\n    }\n}\n"
            ),
        }
        # "Kodex" is too short to search, as select() treats a changed Swift literal.
        self.assertEqual(reverse_test_impact.literal_suites(files, literals), {"SettingsTests"})

    def test_a_direct_push_in_the_range_needs_the_pull_request_to_reach_the_suite(self):
        self.assertEqual(MODULE.suspects_for("Suite/test()", [pr(1)], ["abc"])[0], [])
        reaches = pr(1, reached={"Suite"})
        self.assertEqual(MODULE.suspects_for("Suite/test()", [reaches], ["abc"])[0], [reaches])

    def test_only_commits_that_can_change_an_app_host_test_are_bisected(self):
        log = "\0".join([
            "", f"{'a' * 40}\n\nSources/App.swift\ndocs/x.md\n",
            f"{'b' * 40}\n\ndocs/readme.md\nweb/app/page.tsx\nscripts/ci/foo.py\n",
            f"{'c' * 40}\n\ncmuxTests/FooTests.swift\n",
            f"{'d' * 40}\n\n",
            f"{'e' * 40}\n\nPackages/macOS/Kit/Sources/K.swift\n",
        ])
        self.assertEqual(MODULE.outcome_commits(log), ["a" * 40, "c" * 40, "e" * 40])

    def test_overlay_reads_changed_files_at_the_merge(self):
        files = {"Sources/A.swift": "old", "Sources/B.swift": "b", "cmuxTests/T.swift": "t"}
        self.assertEqual(
            MODULE.overlay(files, {"Sources/A.swift": "new", "cmuxTests/T.swift": None, "Sources/C.swift": "c"}),
            {"Sources/A.swift": "new", "Sources/B.swift": "b", "Sources/C.swift": "c"},
        )
        self.assertEqual(files["Sources/A.swift"], "old")

    def test_editing_the_suite_beats_reaching_it(self):
        edits, reaches, neither = pr(1, edited={"Suite"}), pr(2, reached={"Suite"}), pr(3)
        suspects, how = MODULE.suspects_for("Suite/test()", [neither, reaches, edits])
        self.assertEqual([p.number for p in suspects], [1])
        self.assertEqual(how, "edits the suite")
        suspects, how = MODULE.suspects_for("Suite/test()", [neither, reaches])
        self.assertEqual([p.number for p in suspects], [2])

    def test_ties_name_every_top_pull_request(self):
        a, b = pr(1, reached={"Suite"}), pr(2, reached={"Suite"})
        self.assertEqual([p.number for p in MODULE.suspects_for("Suite/t()", [a, b, pr(3)])[0]], [1, 2])

    def test_a_tie_lists_pull_requests_that_merged_unverified_first(self):
        a, b = pr(1, reached={"Suite"}), pr(2, reached={"Suite"}, unverified=True)
        suspects, how = MODULE.suspects_for("Suite/t()", [a, b, pr(3, unverified=True)])
        self.assertEqual([p.number for p in suspects], [2, 1])
        self.assertEqual(how, "changes code the suite names")
        # The label breaks ties only: a stronger signal still wins, and no signal blames nobody.
        edits = pr(4, edited={"Suite"})
        self.assertEqual([p.number for p in MODULE.suspects_for("Suite/t()", [edits, b])[0]], [4])
        self.assertEqual(MODULE.suspects_for("Suite/t()", [pr(1), pr(2, unverified=True)])[0], [])

    def test_merged_prs_reads_the_merged_unverified_label(self):
        prs, _ = MODULE.merged_prs(["m1", "m2"], {
            "m1": [pr_node(1, "m1", labels=("merged-unverified",))], "m2": [pr_node(2, "m2")],
        })
        self.assertEqual([(p.number, p.unverified) for p in prs], [(2, False), (1, True)])

    def test_no_signal_blames_nobody(self):
        self.assertEqual(MODULE.suspects_for("Suite/t()", [pr(1), pr(2)])[0], [])
        self.assertEqual(MODULE.suspects_for("Suite/t()", [])[0], [])


class CrashReportTests(unittest.TestCase):
    """Main run 36307768440: #14922, the only pull request in the range, changed
    localized values and web tests; the app host crashed under an unrelated
    test, as it had in every full-suite run since 02:04Z."""

    def setUp(self):
        self.previous = run(id=1, head_sha=PREV, html_url="https://github.com/x/runs/1")
        self.lone = pr(14922)
        self.lone.paths = ["Resources/Localizable.xcstrings", "web/tests/changelog-pages.test.tsx"]
        self.lone.ranked = True
        self.crash = MODULE.host_crash(CRASH_LOG, (), "7", "https://job/7")
        self.failures = {VICTIM: ["https://job/7"], "OtherTests/plainFailure()": ["https://job/7"]}

    def test_a_recurring_crash_is_reported_once_and_pings_nobody(self):
        earlier = MODULE.HostCrash("2", "https://job/old", signatures=[CRASH_SIGNATURE], tests=["Elsewhere/test()"])
        finding = MODULE.CrashFinding(self.crash, MODULE.prior_crash(self.crash, [(self.previous, earlier)]))
        regressions, attributed, crashed = MODULE.split_crashes(self.failures, [finding])
        self.assertEqual(list(regressions), ["OtherTests/plainFailure()"])
        self.assertEqual(list(attributed), ["OtherTests/plainFailure()"])
        self.assertEqual(crashed, {})
        attributions = {test: MODULE.suspects_for(test, [self.lone]) for test in attributed}
        self.assertEqual(attributions["OtherTests/plainFailure()"][0], [])
        self.assertEqual(MODULE.comment_plan(attributed, attributions), [])
        text = MODULE.issue_section(
            repo=REPO, run=run(), previous=self.previous, failures=regressions, attributions=attributions,
            prs=[self.lone], direct=[], commits=[], crashes=[finding],
        )
        self.assertIn(f"- `{CRASH_SIGNATURE}` in [shard 7](https://job/7), while running `{VICTIM}`. Not new:", text)
        self.assertIn(f"at `{PREV[:10]}` had the same crash (shard 2)", text)
        self.assertNotIn(f"`{VICTIM}` |", text)
        self.assertIn("`OtherTests/plainFailure()` | unattributed (the only pull request in the range does not reach this suite)", text)
        marker = [line for line in text.splitlines() if line.startswith(MODULE.DATA_PREFIX)][0]
        data = json.loads(marker[len(MODULE.DATA_PREFIX):-3])
        self.assertEqual([entry["test"] for entry in data["tests"]], ["OtherTests/plainFailure()"])
        self.assertNotIn("—", text)

    def test_only_the_crash_left_says_so(self):
        finding = MODULE.CrashFinding(self.crash, (self.previous, MODULE.HostCrash("2", signatures=[CRASH_SIGNATURE])))
        regressions, attributed, _ = MODULE.split_crashes({VICTIM: ["https://job/7"]}, [finding])
        text = MODULE.issue_section(
            repo=REPO, run=run(), previous=self.previous, failures=regressions, attributions={},
            prs=[], direct=[], crashes=[finding],
        )
        self.assertIn("had the same crash (shard 2)", text)
        self.assertIn("No other app-host test fails here", text)
        self.assertNotIn("Pull requests merged", text)

    def test_a_new_crash_pings_only_a_pull_request_that_reaches_the_suite(self):
        finding = MODULE.CrashFinding(self.crash, None)
        _, attributed, crashed = MODULE.split_crashes({VICTIM: ["https://job/7"]}, [finding])
        self.assertEqual(list(crashed), [VICTIM])
        attributions = {VICTIM: MODULE.suspects_for(VICTIM, [self.lone])}
        self.assertEqual(MODULE.comment_plan(attributed, attributions), [])
        text = MODULE.issue_section(
            repo=REPO, run=run(), previous=self.previous, failures={}, attributions=attributions,
            prs=[self.lone], direct=[], crashes=[finding],
        )
        self.assertIn(f"New since the baseline: `{VICTIM}` unattributed (the only pull request in the range does not reach this suite)", text)
        reaches = pr(7, edited={"RecoverableMainWindowLifecycleTests"})
        attributions = {VICTIM: MODULE.suspects_for(VICTIM, [reaches])}
        plan = MODULE.comment_plan(attributed, attributions)
        self.assertEqual([p.number for p, _, _, _ in plan], [7])
        _, tests, how, others = plan[0]
        body = MODULE.pr_comment(
            repo=REPO, pr=reaches, tests=tests, how=how, run=run(), previous=self.previous,
            failures=attributed, others=others, crashed=crashed,
        )
        self.assertIn("newly fail or crash the app host", body)
        text = MODULE.issue_section(
            repo=REPO, run=run(), previous=self.previous, failures={}, attributions=attributions,
            prs=[reaches], direct=[], commits=[], crashes=[finding], crashed=list(crashed),
        )
        marker = [line for line in text.splitlines() if line.startswith(MODULE.DATA_PREFIX)][0]
        data = json.loads(marker[len(MODULE.DATA_PREFIX):-3])
        self.assertEqual([(entry["test"], entry.get("crash")) for entry in data["tests"]], [(VICTIM, True)])
        self.assertIn(
            f"- `{VICTIM}` (the app host crashed while running it: `{CRASH_SIGNATURE}`; "
            "only pull request in the range; edits the suite)", body,
        )

    def test_a_crash_without_a_message_points_at_the_diagnostics_artifact(self):
        silent = MODULE.HostCrash("4", "https://job/4", tests=["A/a()"], artifact="cmux-app-host-diagnostics-shard-4-run-1")
        lines = MODULE.crash_lines(run(), [MODULE.CrashFinding(silent, None)], {})
        self.assertIn(
            "no crash message in the log; the backtrace is in the `cmux-app-host-diagnostics-shard-4-run-1` "
            "artifact of [this run](https://github.com/x/runs/2#artifacts)", lines[1],
        )


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.a, self.b = pr(1, reached={"S"}), pr(2, reached={"S", "T"})
        self.failures = {"S/x()": ["https://job/1"], "T/y()": ["https://job/2"], "U/z()": ["https://job/3"]}
        self.attributions = {test: MODULE.suspects_for(test, [self.a, self.b]) for test in self.failures}
        self.previous = run(id=1, head_sha=PREV, conclusion="success", html_url="https://github.com/x/runs/1")

    def test_issue_section_lists_each_new_failure_with_suspects_and_jobs(self):
        text = MODULE.issue_section(
            repo=REPO, run=run(), previous=self.previous, failures=self.failures,
            attributions=self.attributions, prs=[self.a, self.b], direct=[],
        )
        self.assertIn(f"### New since `{PREV[:10]}`", text)
        self.assertIn(f"https://github.com/{REPO}/compare/{PREV}...{HEAD}", text)
        self.assertIn("`S/x()` | #1, #2 (changes code the suite names) | [job](https://job/1)", text)
        self.assertIn("`T/y()` | #2 (changes code the suite names)", text)
        self.assertIn("`U/z()` | unattributed", text)

    def test_issue_section_carries_the_data_the_bisect_reads(self):
        text = MODULE.issue_section(
            repo=REPO, run=run(), previous=self.previous, failures=self.failures,
            attributions=self.attributions, prs=[self.a, self.b], direct=[], commits=["c" * 40],
        )
        marker = [line for line in text.splitlines() if line.startswith(MODULE.DATA_PREFIX)]
        self.assertEqual(len(marker), 1)
        data = json.loads(marker[0][len(MODULE.DATA_PREFIX):-3])
        self.assertEqual((data["run_id"], data["head"], data["prev"]), (2, HEAD, PREV))
        self.assertEqual(data["commits"], ["c" * 40])
        self.assertEqual(data["tests"][0], {"test": "S/x()", "suspects": [1, 2], "how": "changes code the suite names"})
        self.assertEqual(data["tests"][2]["suspects"], [])
        self.assertEqual(data["prs"], {})  # neither merge commit is one the bisect probes
        merged = [pr(n) for n in range(MODULE.MAX_BISECT_COMMITS + 1)]
        for each in merged:
            each.merge_sha = f"{each.number:040x}"
        long = MODULE.issue_section(
            repo=REPO, run=run(), previous=self.previous, failures=self.failures,
            attributions=self.attributions, prs=merged, direct=[],
            commits=[each.merge_sha for each in merged],
        )
        marker = [line for line in long.splitlines() if line.startswith(MODULE.DATA_PREFIX)][0]
        long_data = json.loads(marker[len(MODULE.DATA_PREFIX):-3])
        self.assertIsNone(long_data["commits"])
        self.assertEqual(long_data["prs"], {})
        without = MODULE.issue_section(
            repo=REPO, run=run(), previous=self.previous, failures=self.failures,
            attributions=self.attributions, prs=[self.a, self.b], direct=[],
        )
        self.assertNotIn(MODULE.DATA_PREFIX, without)

    def test_issue_section_lists_failures_without_a_baseline(self):
        text = MODULE.issue_section(
            repo=REPO, run=run(), previous=self.previous, failures={}, attributions={}, prs=[], direct=[],
            no_baseline=["B/b()"],
        )
        self.assertIn("Not compared, because that run's shard stopped before grading them: `B/b()`", text)

    def test_issue_section_without_new_failures_or_baseline(self):
        text = MODULE.issue_section(
            repo=REPO, run=run(), previous=self.previous, failures={}, attributions={}, prs=[], direct=[],
        )
        self.assertIn("No app-host test fails here", text)
        text = MODULE.issue_section(
            repo=REPO, run=run(), previous=None, failures={}, attributions={}, prs=[], direct=[],
        )
        self.assertIn("No earlier full-suite run", text)

    def test_one_comment_per_suspect_with_its_own_tests(self):
        plan = MODULE.comment_plan(self.failures, self.attributions)
        self.assertEqual([(p.number, tests) for p, tests, _, _ in plan], [(1, ["S/x()"]), (2, ["S/x()", "T/y()"])])
        pr2, tests, how, others = plan[1]
        body = MODULE.pr_comment(
            repo=REPO, pr=pr2, tests=tests, how=how, run=run(), previous=self.previous,
            failures=self.failures, others=others,
        )
        self.assertTrue(body.startswith(MODULE.marker(2, ["S/x()", "T/y()"], f"{PREV[:10]}..{HEAD[:10]}")))
        self.assertTrue(MODULE.already_told([body], 2, ["T/y()", "S/x()"], "other..range"))
        self.assertIn("- `S/x()` (changes code the suite names; also suspected: #1) [job](https://job/1)", body)
        self.assertIn("- `T/y()` (changes code the suite names) [job](https://job/2)", body)
        self.assertNotIn("U/z()", body)
        self.assertNotIn("—", body)

    def test_a_wide_tie_pings_nobody(self):
        tied = [pr(n, reached={"S"}) for n in range(1, MODULE.MAX_PINGED_SUSPECTS + 2)]
        failures = {"S/x()": ["https://job/1"]}
        attributions = {"S/x()": MODULE.suspects_for("S/x()", tied)}
        self.assertEqual(len(attributions["S/x()"][0]), len(tied))
        self.assertEqual(MODULE.comment_plan(failures, attributions), [])

    def test_the_comment_cap_skips_suspects_already_told(self):
        prs = [pr(n, reached={"S"}) for n in range(1, MODULE.MAX_COMMENTED_PRS + 3)]
        plan = [(p, ["S/x()"], {}, {}) for p in prs]
        told = {p.number for p in prs[:MODULE.MAX_COMMENTED_PRS]}
        chosen = MODULE.untold(plan, lambda p, tests: p.number in told)
        self.assertEqual([p.number for p, _, _, _ in chosen], [MODULE.MAX_COMMENTED_PRS + 1, MODULE.MAX_COMMENTED_PRS + 2])
        chosen = MODULE.untold(plan, lambda p, tests: False)
        self.assertEqual(len(chosen), MODULE.MAX_COMMENTED_PRS)

    def test_a_pull_request_hears_once_per_test_set_and_once_per_range(self):
        told = ["intro", MODULE.marker(2, ["a", "b"], "p..h")]
        self.assertEqual(MODULE.marker(2, ["b", "a"], "p..h"), MODULE.marker(2, ["a", "b"], "p..h"))
        self.assertTrue(MODULE.already_told(told, 2, ["b", "a"], "p2..h2"))  # same tests, later range
        self.assertTrue(MODULE.already_told(told, 2, ["a"], "p..h"))  # re-run of the same range
        self.assertFalse(MODULE.already_told(told, 2, ["a"], "p2..h2"))
        self.assertFalse(MODULE.already_told(told, 3, ["a", "b"], "p..h"))
        self.assertFalse(MODULE.already_told([], 2, ["a"], "p..h"))


class WorkflowTests(unittest.TestCase):
    text = WORKFLOW.read_text(encoding="utf-8")
    report = text.split("\n  report:\n", 1)[1]

    def test_report_job_can_comment_on_pull_requests(self):
        self.assertIn("pull-requests: write", self.report)
        self.assertIn("issues: write", self.report)

    def test_attribution_feeds_the_issue_section_and_cannot_block_it(self):
        self.assertIn("scripts/ci/main_regression_attribution.py", self.report)
        step = self.report.split("main_regression_attribution.py", 1)[0].rsplit("- name:", 1)[1]
        self.assertIn("continue-on-error: true", step)
        self.assertIn("--extra-section", self.report)

    def test_the_issue_sync_checkout_stays_shallow_and_attribution_deepens_it(self):
        checkout = self.report.split("      - name: Checkout\n", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("fetch-depth: 1", checkout)
        for tree in ("scripts/ci", "cmuxTests", "Sources", "Packages/macOS", "Packages/Shared", "CLI"):
            self.assertIn(f"            {tree}\n", checkout)
        step = self.report.split("main_regression_attribution.py", 1)[0].rsplit("- name:", 1)[1]
        self.assertIn("git fetch --no-tags --filter=blob:none --depth=", step)


if __name__ == "__main__":
    unittest.main()

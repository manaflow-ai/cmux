#!/usr/bin/env python3
"""classify_failures.py tells a machine failure from a code failure (no network).

The log lines are trimmed from runs of 2026-09-27 whose pull request code was
fine: a product restore that failed (run 36308928998), a runner hook refusal
(run 36312478082), and a CLI that loaded package frameworks from another build
(job 108599057429). The cases also pin that a signature spelled in a step's
echoed script does not count, that the gate jobs exist under the names the
jobs API reports, the at-most-once re-run, and the workflow's trust (it runs
main's script and never checks out the pull request).
"""

from __future__ import annotations

import sys
import textwrap
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import classify_failures as cf  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/ci-failure-attribution.yml"
ESC = "\x1b"

RESTORE_FAILED = textwrap.dedent(f"""\
    2026-09-27T09:27:44.4138020Z Validated app-host test products for 89e82bd1f4ca15e8655b2edf4dd78873c1bb61be
    2026-09-27T09:27:44.4680740Z glaeda-cmux-runner-hook: take-root: '/private/tmp/cmux-ci-2' is not one of this mini's 1 canonical root(s) (/private/tmp/cmux-ci, /private/tmp/cmux-ci-N or N)
    2026-09-27T09:27:44.4859810Z CMUX_TEST_PRODUCT_RESTORE {{"archive_bytes": 0, "artifact_id": 10928258685, "job": "app-host-unit-tests", "layer_hit": true, "outcome": "failure", "producer_run_attempt": 1}}
    2026-09-27T09:27:44.4886770Z ##[error]Process completed with exit code 2.
    2026-09-27T09:27:45.9700000Z ##[group]Run case "$CMUX_APP_HOST_PREPARATION_OUTCOME" in
    2026-09-27T09:27:45.9706630Z {ESC}[36;1m    echo "::error::Unexpected app-host preparation outcome: $CMUX_APP_HOST_PREPARATION_OUTCOME"{ESC}[0m
    2026-09-27T09:27:45.9710000Z ##[endgroup]
    """)

HOOK_REFUSED = textwrap.dedent("""\
    2026-09-27T10:26:16.9930940Z   pr_refused_retry_runner: glaeda-std-xcode-26.6
    2026-09-27T10:26:17.2532030Z glaeda-cmux-runner-hook: refused: capacity: 0 of 5 units free, swift-package-tests (light) needs 1
    2026-09-27T10:26:17.2547700Z ##[error]glaeda-cmux-runner-hook: refused: capacity: 0 of 5 units free, swift-package-tests (light) needs 1
    2026-09-27T10:26:17.2594190Z ##[error]Process completed with exit code 1.
    2026-09-27T10:26:17.7508430Z glaeda-cmux-runner-hook: no host lock holder to release
    2026-09-27T10:26:17.8437740Z Cleaning up orphan processes
    """)

# The shard's CLI tests failed by the dozen; the dyld line says why.
MIXED_PRODUCTS = textwrap.dedent("""\
    2026-09-27T10:19:26.7431580Z /tmp/cmux-ci-2/src/cmuxTests/CLIAmpLifecycleIntegrationTests.swift:260: error: -[cmuxTests.CLINotifyProcessIntegrationRegressionTests testAmpCancelledTurnSettlesWithoutCompletionNotification] : XCTAssertEqual failed: ("6") is not equal to ("0") - dyld[9231]: Symbol not found: _$s15CMUXAgentLaunch05AgentB18CaptureArgvVerdictO
    2026-09-27T10:19:26.7433260Z   Referenced from: <4150A975-C72E-3C4B-A99A-7113745B2919> /Users/cmux/actions-runner-glaeda-4/_work/_temp/cmux-derived-data-tests-36308928998-2-shard-7/Build/Products/Debug/cmux DEV.app/Contents/Resources/bin/cmux
    2026-09-27T10:19:26.7434490Z   Expected in:     <AEE55255-798E-3AEB-B342-06D79CC6F0CA> /private/tmp/cmux-ci-2/derived-data-compile-admission/Build/Products/Debug/PackageFrameworks/CMUXAgentLaunch_-158D461BD47E196A_PackageProduct.framework/Versions/A/CMUXAgentLaunch_-158D461BD47E196A_PackageProduct
    2026-09-27T10:21:17.5608820Z ✘ Test singleArgumentCommandStringIsSplitShellStyle() recorded an issue at CLITmuxCompatRemoteSplitTests.swift:119:13: Expectation failed: (result.status → 6) == 0
    2026-09-27T10:26:29.4506340Z RATCHET_NEW_FAILURE CLINotifyProcessIntegrationRegressionTests/testAmpCancelledTurnSettlesWithoutCompletionNotification()
    2026-09-27T10:26:29.4510000Z ##[error]Process completed with exit code 65.
    """)

TEST_FAILED = textwrap.dedent("""\
    2026-09-27T09:28:02.4500070Z ✘ Test testAmbientTaggedCLIListsEveryDeadSocketCandidateOnFailure() recorded an issue at CMUXCLITestAssertions.swift:33:13: Expectation failed: try expression()
    2026-09-27T09:31:30.4047700Z RATCHET_NEW_FAILURE WorkspaceClosePanelFallbackTests/fallbackRefusesToCloseSelectedTabOwnedByAnotherPanel()
    2026-09-27T09:31:30.4083830Z ##[error]Process completed with exit code 65.
    """)

NO_CONSOLE_WARNING = (
    "No logged-in console user (or no passwordless sudo) on this runner; running in the current bootstrap. "
    "XCTest will fail here if this runner has no GUI session."
)
GUI_TOKEN_UNAVAILABLE = "Could not take this Mac's gui token for the app-host tests (take-gui exited 1)."

PARAMETERIZED_TEST_FAILED = (
    "2026-09-27T10:40:00.0000000Z ✘ Test mapsConnectionClosedStartupFailureToRetryableStatus(_:) recorded an issue "
    "with 1 argument diagnostic → \"Connection closed by 192.0.2.1 port 22\" at "
    "SSHForegroundAuthenticationRetryPolicyTests.swift:863:13: Expectation failed\n"
)
DISPLAY_NAME_TEST_FAILED = (
    "2026-09-27T10:40:00.0000000Z ✘ Test \"each change describes itself as the equivalent cmux config command\" "
    "failed after 0.100 seconds with 1 issue.\n"
)
COMPILE_FAILED = (
    "2026-09-27T10:40:00.0000000Z /tmp/cmux-ci/src/cmuxTests/SidebarWidthPolicyTests.swift:672:57: error: "
    "ambiguous use of 'init'\n"
)
STATIC_CHECK_FAILED = "2026-09-27T10:40:00.0000000Z FAILED config-schema (0.03s)\n"
ADMISSION_DECLINED = (
    "2026-09-27T10:40:00.0000000Z macOS admission gate declined: a fast Linux job failed. The product compiled "
    "and was uploaded; re-run failed jobs to collect macOS results anyway.\n"
)
# Run 36553044270's swift-package-tests on cmux14 (glaeda-std-xcode-26.6), as
# the job printed it then (a head branched before the marker), and as
# scripts/select-ci-xcode.sh prints it now.
XCODE_PIN_MISSING_LEGACY = textwrap.dedent("""\
    2026-09-29T12:23:37.0000000Z ##[group]Run set -euo pipefail
    2026-09-29T12:23:37.0000000Z \x1b[36;1mset -euo pipefail\x1b[0m
    2026-09-29T12:23:37.0000000Z ##[endgroup]
    2026-09-29T12:23:37.1000000Z Pinned Xcode developer dir does not exist: /Applications/Xcode_26.3.app/Contents/Developer
    2026-09-29T12:23:37.1000000Z ##[error]Process completed with exit code 1.
    """)
XCODE_PIN_MISSING = (
    "2026-09-29T12:23:37.1000000Z ##[error]Pinned Xcode developer dir does not exist: "
    "/Applications/Xcode_26.3.app/Contents/Developer on runner cmux14-glaeda-1. "
    "[cmux-ci machine: xcode-pin-missing] Installed: Xcode.app=26.3 Xcode_26.6.app=26.6\n"
)
POOL_XCODE_MISSING = (
    "2026-09-29T12:23:37.1000000Z ##[error]This macOS 26 runner has no Xcode 26.6, the version "
    "scripts/ci/xcode-pins.txt pins for its pool. Installed: Xcode_26.3.app=26.3\n"
)
NOISE = textwrap.dedent("""\
    2026-09-27T09:24:56.6949430Z ##[group]Run if [ "$REQUESTED_RUNNER" = ubuntu-24.04 ]; then
    2026-09-27T09:24:56.6949430Z \x1b[36;1m      echo "::error::$REQUESTED_RUNNER resolved outside GitHub-hosted capacity: $RUNNER_CONTEXT_NAME"\x1b[0m
    2026-09-27T09:24:56.6950000Z ##[endgroup]
    2026-09-27T10:26:17.8437740Z Cleaning up orphan processes
    2026-09-27T10:26:17.8437740Z Terminate orphan process: pid (3476) (report_adoption_and_setup_ssh.sh)
    2026-09-27T10:26:17.8437740Z ##[error]Process completed with exit code 1.
    """)


def job(job_id: int, name: str, conclusion: str = "failure", step: str = "Run unit tests") -> dict:
    return {"id": job_id, "name": name, "conclusion": conclusion, "runner_name": f"runner-{job_id}",
            "html_url": f"https://github.com/manaflow-ai/cmux/actions/runs/1/job/{job_id}",
            "steps": [{"name": "Set up job", "conclusion": "success"}, {"name": step, "conclusion": conclusion}]}


class SignatureTests(unittest.TestCase):
    def verdict(self, text: str) -> tuple[str, str | None]:
        result = cf.classify_text(text)
        return result["verdict"], result["signature"]

    def test_a_failed_product_restore_is_the_machine(self) -> None:
        self.assertEqual(self.verdict(RESTORE_FAILED), (cf.MACHINE, "product-restore-failed"))

    def test_a_runner_hook_refusal_is_the_machine(self) -> None:
        self.assertEqual(self.verdict(HOOK_REFUSED), (cf.MACHINE, "runner-hook-refused"))

    def test_products_from_two_builds_outweigh_the_test_failures_they_cause(self) -> None:
        verdict, signature = self.verdict(MIXED_PRODUCTS)
        self.assertEqual((verdict, signature), (cf.MACHINE, "mixed-products"))
        self.assertIn("Symbol not found", cf.classify_text(MIXED_PRODUCTS)["evidence"])

    def test_a_gui_token_failure_is_the_machine(self) -> None:
        log = f"##[error]{GUI_TOKEN_UNAVAILABLE}\n"
        self.assertEqual(self.verdict(log), (cf.MACHINE, "gui-token-unavailable"))
        self.assertIn(GUI_TOKEN_UNAVAILABLE, cf.classify_text(log)["evidence"])

    def test_a_gui_token_failure_is_read_from_its_failure_annotation(self) -> None:
        result = cf.classify_text("", [GUI_TOKEN_UNAVAILABLE])
        self.assertEqual((result["verdict"], result["signature"]), (cf.MACHINE, "gui-token-unavailable"))

    def test_an_ambiguous_console_warning_does_not_outweigh_test_failures(self) -> None:
        log = f"##[warning]{NO_CONSOLE_WARNING}\n{TEST_FAILED}"
        self.assertEqual(self.verdict(log), (cf.CODE, "swift-testing-issue"))

    def test_a_gui_token_diagnostic_in_assertion_output_is_the_code(self) -> None:
        log = ("✘ Test reportsGUITokenFailure() recorded an issue at GUITokenTests.swift:12:5: "
               f'Expectation failed: diagnostic → "{GUI_TOKEN_UNAVAILABLE}"\n'
               "##[error]Process completed with exit code 1.\n")
        self.assertEqual(self.verdict(log), (cf.CODE, "swift-testing-issue"))

    def test_an_echoed_gui_token_error_does_not_outweigh_test_failures(self) -> None:
        log = ('##[group]Run "$helper" take-gui --wait 1800\n'
               f'{ESC}[36;1mecho "::error::{GUI_TOKEN_UNAVAILABLE}"{ESC}[0m\n'
               f"##[endgroup]\n{TEST_FAILED}")
        self.assertEqual(self.verdict(log), (cf.CODE, "swift-testing-issue"))

    def test_a_test_failure_on_a_healthy_runner_is_the_code(self) -> None:
        self.assertEqual(self.verdict(TEST_FAILED), (cf.CODE, "swift-testing-issue"))
        self.assertEqual(self.verdict(PARAMETERIZED_TEST_FAILED), (cf.CODE, "swift-testing-issue"))
        self.assertEqual(self.verdict(DISPLAY_NAME_TEST_FAILED), (cf.CODE, "swift-testing-issue"))
        self.assertEqual(self.verdict(COMPILE_FAILED), (cf.CODE, "compile-error"))
        self.assertEqual(self.verdict(STATIC_CHECK_FAILED), (cf.CODE, "static-check-failed"))

    def test_a_missing_pinned_xcode_is_the_machine(self) -> None:
        for log in (XCODE_PIN_MISSING, XCODE_PIN_MISSING_LEGACY, POOL_XCODE_MISSING):
            with self.subTest(log=log[:80]):
                self.assertEqual(self.verdict(log), (cf.MACHINE, "xcode-pin-missing"))
        # Only every failed job being machine re-runs the run; this one does.
        jobs = cf.classify_jobs([job(7, "macos / swift-package-tests", step="Select Xcode")],
                                {7: (XCODE_PIN_MISSING_LEGACY, [])})
        self.assertTrue(cf.all_machine(jobs))

    def test_a_forks_missing_pool_xcode_warning_is_not_the_machine(self) -> None:
        # A fork's own CI warns and falls back; that warning is not where it failed.
        warned = POOL_XCODE_MISSING.replace("##[error]", "##[warning]") + COMPILE_FAILED + \
            "2026-09-29T12:30:00.0000000Z ##[error]Process completed with exit code 65.\n"
        self.assertEqual(self.verdict(warned), (cf.CODE, "compile-error"))

    def test_a_signature_in_an_echoed_script_or_cleanup_noise_does_not_count(self) -> None:
        self.assertEqual(self.verdict(NOISE), (cf.UNKNOWN, None))
        restore_ok = RESTORE_FAILED.replace('"outcome": "failure"', '"outcome": "success"')
        self.assertEqual(self.verdict(restore_ok), (cf.UNKNOWN, None))

    def test_a_lost_runner_is_read_from_its_annotation(self) -> None:
        annotation = "The self-hosted runner: cmux7s-mac-mini-glaeda-4 lost communication with the server."
        result = cf.classify_text("", [annotation])
        self.assertEqual((result["verdict"], result["signature"]), (cf.MACHINE, "runner-lost"))

    def test_a_machine_line_in_a_step_that_passed_does_not_count(self) -> None:
        # A cache save warns about the disk; the job failed on a test.
        log = textwrap.dedent(f"""\
            2026-09-27T10:00:00.0Z ##[group]Run swift test
            2026-09-27T10:00:00.0Z {ESC}[36;1mswift test{ESC}[0m
            2026-09-27T10:00:00.0Z ##[endgroup]
            2026-09-27T10:00:01.0Z ✘ Test parsesConfig() recorded an issue at ConfigTests.swift:12:5: Expectation failed
            2026-09-27T10:00:01.0Z ##[error]Process completed with exit code 1.
            2026-09-27T10:00:02.0Z ##[group]Run actions/cache/save@v4
            2026-09-27T10:00:02.0Z with:
            2026-09-27T10:00:02.0Z   path: .build
            2026-09-27T10:00:02.0Z ##[endgroup]
            2026-09-27T10:00:03.0Z Warning: Failed to save: No space left on device
            """)
        self.assertEqual(self.verdict(log), (cf.CODE, "swift-testing-issue"))
        gui_token_noise = log.replace("Warning: Failed to save: No space left on device", GUI_TOKEN_UNAVAILABLE)
        self.assertEqual(self.verdict(gui_token_noise), (cf.CODE, "swift-testing-issue"))

    def test_a_group_a_step_titles_run_keeps_its_output(self) -> None:
        log = textwrap.dedent("""\
            2026-09-27T10:00:00.0Z ##[group]Run agent-chat unit tests
            2026-09-27T10:00:00.0Z FAIL: test_renders_reply (__main__.ChatTests.test_renders_reply)
            2026-09-27T10:00:00.0Z ##[endgroup]
            2026-09-27T10:00:01.0Z ##[error]Process completed with exit code 1.
            """)
        self.assertEqual(self.verdict(log), (cf.CODE, "unittest-failure"))

    def test_every_signature_has_a_verdict_and_a_reason(self) -> None:
        names = [s.name for s in cf.SIGNATURES]
        self.assertEqual(len(names), len(set(names)))
        for signature in cf.SIGNATURES:
            self.assertIn(signature.verdict, {cf.MACHINE, cf.CODE, cf.DERIVED})
            self.assertTrue(signature.why)


class RunTests(unittest.TestCase):
    JOBS = [
        job(1, "macos / app-host unit tests (2/7)"),
        job(2, "macos / swift-package-tests"),
        job(3, "macos / app-host unit tests (1/7)"),
        job(4, "macos / macOS compile admission"),
        job(5, "macos / release-build", conclusion="cancelled"),
        job(6, "macos / macOS status"),
        job(7, "ci-status"),
        job(8, "guards / workflow-guard-tests / preflight", step="Validate embedded cmux.json schema generation"),
        job(9, "macos / cli-product-tests", conclusion="success"),
    ]
    TEXTS = {1: (RESTORE_FAILED, []), 2: (HOOK_REFUSED, []), 3: (TEST_FAILED, []),
             4: (ADMISSION_DECLINED, []), 8: ("no signature here", [])}

    def test_gates_derived_and_cancelled_jobs_are_left_out(self) -> None:
        jobs = cf.classify_jobs(self.JOBS, self.TEXTS)
        self.assertEqual({j["id"]: j["verdict"] for j in jobs},
                         {1: cf.MACHINE, 2: cf.MACHINE, 3: cf.CODE, 8: cf.UNKNOWN})
        unknown = next(j for j in jobs if j["id"] == 8)
        self.assertIn("Validate embedded cmux.json schema generation", unknown["why"])
        self.assertFalse(cf.all_machine(jobs))

    def test_only_machine_failures_are_all_machine(self) -> None:
        jobs = cf.classify_jobs(self.JOBS[:2] + self.JOBS[4:7], self.TEXTS)
        self.assertTrue(cf.all_machine(jobs))
        self.assertFalse(cf.all_machine([]))


class RerunDecisionTests(unittest.TestCase):
    def report(self, verdicts: list[str], attempt: int = 1, conclusion: str = "failure") -> dict:
        jobs = [{"name": f"job {i}", "verdict": v} for i, v in enumerate(verdicts)]
        return {"run_id": 42, "attempt": attempt, "head_sha": "a" * 40, "conclusion": conclusion, "jobs": jobs}

    LATEST = {"run_attempt": 1, "status": "completed"}

    def test_every_failure_on_the_machine_reruns(self) -> None:
        rerun, line = cf.rerun_decision(self.report([cf.MACHINE, cf.MACHINE]), self.LATEST)
        self.assertTrue(rerun)
        self.assertIn("attempt 2", line)

    def test_a_gui_token_failure_does_not_block_other_machine_retries(self) -> None:
        report = self.report([])
        report["jobs"] = cf.classify_jobs(
            [job(1, "macos / app-host unit tests (2/7)"), job(2, "macos / swift-package-tests")],
            {1: (f"##[error]{GUI_TOKEN_UNAVAILABLE}\n", []), 2: (HOOK_REFUSED, [])},
        )
        self.assertTrue(cf.rerun_decision(report, self.LATEST)[0])

    def test_one_code_or_unknown_failure_keeps_the_run_red(self) -> None:
        for other in (cf.CODE, cf.UNKNOWN):
            rerun, line = cf.rerun_decision(self.report([cf.MACHINE, other]), self.LATEST)
            self.assertFalse(rerun)
            self.assertIn("`job 1`", line)

    def test_an_automatic_re_run_on_blacksmith_is_not_re_run_again(self) -> None:
        # The bot's attempt 3 went to Blacksmith; nothing a comment says can restart it.
        rerun, line = cf.rerun_decision(self.report([cf.MACHINE], attempt=3),
                                        {"run_attempt": 3, "status": "completed",
                                         "triggering_actor": {"login": cf.BOT}})
        self.assertFalse(rerun)
        self.assertIn("attempt 3", line)

    def test_an_automatic_attempt_2_a_mini_failed_goes_to_blacksmith_once(self) -> None:
        # The bot's attempt 2 goes back to the minis; an online but broken one (a full
        # disk, a failed product restore) may fail it again. Its re-run, attempt 3,
        # takes Blacksmith, which ends the chain.
        rerun, line = cf.rerun_decision(self.report([cf.MACHINE], attempt=2),
                                        {"run_attempt": 2, "status": "completed",
                                         "triggering_actor": {"login": cf.BOT}})
        self.assertTrue(rerun)
        self.assertIn("attempt 3", line)

    def test_a_persons_re_run_that_a_mini_failed_goes_to_blacksmith_once(self) -> None:
        # A person's re-run follows a code failure back to the minis; a machine
        # failure there is re-run by the bot, whose re-run takes Blacksmith.
        rerun, _ = cf.rerun_decision(self.report([cf.MACHINE], attempt=2),
                                     {"run_attempt": 2, "status": "completed",
                                      "triggering_actor": {"login": "teamleaderleo"}})
        self.assertTrue(rerun)

    def test_a_cancelled_run_is_reported_not_rerun(self) -> None:
        # owned_pool_rescue cancels a stuck run before its own full re-run.
        self.assertFalse(cf.rerun_decision(self.report([cf.MACHINE], conclusion="cancelled"), self.LATEST)[0])

    def test_a_run_someone_else_reran_is_left_alone(self) -> None:
        for latest in ({"run_attempt": 2, "status": "completed", "triggering_actor": {"login": cf.BOT}},
                       {"run_attempt": 1, "status": "in_progress"}):
            self.assertFalse(cf.rerun_decision(self.report([cf.MACHINE]), latest)[0])

    def test_gates_alone_do_not_rerun(self) -> None:
        self.assertFalse(cf.rerun_decision(self.report([]), self.LATEST)[0])


class FakeGitHub:
    repo = "manaflow-ai/cmux"

    def __init__(self, *, head: str = "a" * 40, state: str = "open", comments: list[dict] | None = None,
                 latest: dict | None = None, merged: bool = False, files: list[str] | None = None,
                 main_issue: dict | None = None, main_comments: list[dict] | None = None):
        self.head, self.state, self.merged = head, state, merged
        self._comments = comments or []
        self.latest = latest or {"run_attempt": 1, "status": "completed"}
        self.files = files or []
        self.main_issue, self.main_comments = main_issue, main_comments or []
        self.calls: list[tuple[str, str]] = []
        self.reads: list[str] = []

    def pull(self, number: int) -> dict:
        return {"number": number, "state": self.state, "head": {"sha": self.head},
                "merged_at": "2026-10-05T02:20:16Z" if self.merged else None}

    def get(self, path: str) -> object:
        self.reads.append(path)
        if "/files?" in path:
            return [{"filename": name} for name in self.files] if "page=1" in path else []
        if "labels=main-full-suite-failure" in path:
            return [self.main_issue] if self.main_issue else []
        if "/comments?" in path:
            return self.main_comments
        raise AssertionError(f"unexpected read {path}")

    def comments(self, number: int) -> list[dict]:
        return self._comments

    def run(self, run_id: int) -> dict:
        return self.latest

    def request(self, method: str, path: str, body: object = None) -> dict:
        self.calls.append((method, path))
        return {}


def bot_comment(body: str, comment_id: int = 99, login: str = cf.BOT) -> dict:
    return {"id": comment_id, "body": body, "user": {"login": login}}


class ActTests(unittest.TestCase):
    RUN = {"id": 42, "head_sha": "a" * 40, "pull_requests": [
        {"number": 7, "base": {"repo": {"url": "https://api.github.com/repos/manaflow-ai/cmux"}}}]}

    def report(self, verdicts: list[str], conclusion: str = "failure") -> dict:
        jobs = [{"name": f"job {i}", "verdict": v, "why": "because", "evidence": "line `x`", "url": None,
                 "runner": "cmux7s-mac-mini-glaeda-4"} for i, v in enumerate(verdicts)]
        return {"run_id": 42, "attempt": 1, "head_sha": "a" * 40, "run_url": "https://run",
                "conclusion": conclusion, "jobs": jobs}

    def act(self, gh: FakeGitHub, report: dict) -> dict:
        return cf.act(gh, cf.Writer(gh, dry_run=False), self.RUN, report)  # type: ignore[arg-type]

    def test_machine_failures_rerun_and_comment(self) -> None:
        gh = FakeGitHub()
        result = self.act(gh, self.report([cf.MACHINE]))
        self.assertTrue(result["rerun"])
        # The bot's re-run may emit no workflow_run event, so it starts the
        # UI test dispatch for attempt 2 itself (ci-ui-tests.yml).
        self.assertEqual(gh.calls, [("POST", "repos/manaflow-ai/cmux/actions/runs/42/rerun-failed-jobs"),
                                    ("POST", "repos/manaflow-ai/cmux/actions/workflows/ci-ui-tests.yml/dispatches"),
                                    ("POST", "repos/manaflow-ai/cmux/issues/7/comments")])

    def test_the_bots_comment_is_edited_and_a_lookalike_is_ignored(self) -> None:
        body = cf.render_comment(self.report([cf.CODE]), "line")
        gh = FakeGitHub(comments=[bot_comment(body, 5, login="someone"), bot_comment(body)])
        self.act(gh, self.report([cf.CODE]))
        self.assertEqual(gh.calls, [("PATCH", "repos/manaflow-ai/cmux/issues/comments/99")])

    def test_a_stale_head_or_a_closed_pr_gets_nothing(self) -> None:
        for gh in (FakeGitHub(head="b" * 40), FakeGitHub(state="closed")):
            self.assertFalse(self.act(gh, self.report([cf.MACHINE]))["rerun"])
            self.assertEqual(gh.calls, [])

    def test_green_only_updates_a_comment_that_exists(self) -> None:
        green = self.report([], conclusion="success")
        gh = FakeGitHub()
        self.act(gh, green)
        self.assertEqual(gh.calls, [])
        gh = FakeGitHub(comments=[bot_comment(cf.MARKER + "\nred")])
        self.act(gh, green)
        self.assertEqual(gh.calls, [("PATCH", "repos/manaflow-ai/cmux/issues/comments/99")])

    def test_a_superseded_cancelled_run_says_nothing(self) -> None:
        gh = FakeGitHub()
        self.act(gh, self.report([], conclusion="cancelled"))
        self.assertEqual(gh.calls, [])

    def test_log_text_cannot_break_out_of_the_comment(self) -> None:
        report = self.report([cf.MACHINE])
        report["jobs"][0]["evidence"] = "```\n# injected"
        self.assertIn("````", cf.render_comment(report, "line"))


# Run 37254190713 (#17074 at abae4be97b), job 111591382576 "macos / app-host
# unit tests (changed suites)", trimmed: its own test files failed, among
# app-host noise. Two lines carry the zero-width space Swift Testing prints.
PR_17074_LOG = textwrap.dedent("""\
    2026-10-05T02:30:00.0000000Z ##[group]Run scripts/ci/run-app-host-unit-batches.sh
    2026-10-05T02:30:00.0000000Z \x1b[36;1mscripts/ci/run-app-host-unit-batches.sh\x1b[0m
    2026-10-05T02:30:00.0000000Z ##[endgroup]
    2026-10-05T02:33:24.8768510Z Test Case '-[cmuxTests.CLINotifyProcessIntegrationRegressionTests testSSHPTYAttachUnknownFlagStaysFatal]' started.
    2026-10-05T02:33:24.8769270Z Test Case '-[cmuxTests.CLINotifyProcessIntegrationRegressionTests testSSHPTYAttachUnknownFlagStaysFatal]' passed (0.039 seconds).
    2026-10-05T02:34:00.0000000Z 2026-10-04 19:34:00.000000-0700 cmux DEV[43530:62173076] [ProcessSuspension] error: Error Domain=RBSServiceErrorDomain Code=1 "(originator doesn't have entitlement com.apple.runningboard.assertions.webkit)"
    2026-10-05T02:34:00.1000000Z error: Error Domain=NSCocoaErrorDomain Code=4097 "connection to service named com.apple.linkd.autoShortcut"
    2026-10-05T02:34:00.2000000Z error: <dictionary: 0x1f2c3a4b5> { count = 1 }
    2026-10-05T02:34:00.3000000Z error: UpdateFailed
    2026-10-05T02:35:15.9500540Z \u200b◇ Test "Opening the Ports tab requests discovery once; closed Ports and collapsed machines do not scan" started.
    2026-10-05T02:35:15.9501390Z ✘ Test "Opening the Ports tab requests discovery once; closed Ports and collapsed machines do not scan" recorded an issue at CloudPortsVPNAffordanceTests.swift:285:9: Expectation failed: (requested → [opened, closed, collapsed]) == ([.cloud("opened")] → [opened])
    2026-10-05T02:35:15.9502030Z ± inserted [closed, collapsed]
    2026-10-05T02:35:15.9502430Z ✘ Test "Opening the Ports tab requests discovery once; closed Ports and collapsed machines do not scan" failed after 0.012 seconds with 1 issue.
    2026-10-05T02:35:15.9505320Z ✘ Suite "Cloud sidebar Ports status controls" failed after 0.142 seconds with 1 issue.
    2026-10-05T02:35:46.2227920Z \u200b✘ Test "Cloud/Beta gating keeps both bottom actions present but disabled" recorded an issue at DeviceDiscoverabilityGatingTests.swift:20:9: Expectation failed: (section.discoveryControl.title → "Discover other Macs") == "Discover other devices"
    2026-10-05T02:35:46.2228550Z ✘ Test "Cloud/Beta gating keeps both bottom actions present but disabled" failed after 0.001 seconds with 1 issue.
    2026-10-05T02:35:46.2228890Z ✘ Suite DeviceDiscoverabilityGatingTests failed after 0.001 seconds with 1 issue.
    2026-10-05T02:37:32.1292550Z ✘ Test run with 2073 tests in 175 suites failed after 182.810 seconds with 2 issues.
    2026-10-05T02:37:37.1509310Z Failing tests:
    2026-10-05T02:37:37.1509460Z \tCloudPortsVPNAffordanceTests.openedPortsDemand()
    2026-10-05T02:37:37.1509710Z \tDeviceDiscoverabilityGatingTests.unavailableDevicesKeepGatedControls()
    2026-10-05T02:37:37.1509940Z ** TEST EXECUTE FAILED **
    2026-10-05T02:37:42.2893230Z RATCHET_NEW_FAILURE CloudPortsVPNAffordanceTests/openedPortsDemand()
    2026-10-05T02:37:42.2893580Z RATCHET_NEW_FAILURE DeviceDiscoverabilityGatingTests/unavailableDevicesKeepGatedControls()
    2026-10-05T02:37:42.2936340Z ##[error]Process completed with exit code 65.
    """)
PR_17074_FILES = ["Sources/Cloud/CloudPortsDiscoveryDemand.swift", "cmuxTests/CloudPortsVPNAffordanceTests.swift",
                  "cmuxTests/DeviceDiscoverabilityGatingTests.swift", "cmuxTests/CloudSidebarPolishTests.swift"]

# Run 37301425463 (#17232 at b5691441b0), job 111735129083 "macos / macOS
# compile admission", trimmed: the one real error sat under 411 cache warnings
# and 45 cache errors.
PR_17232_LOG = (
    "2026-10-05T11:15:00.0000000Z ##[group]Run scripts/ci/run-xcodebuild-with-diagnostics.sh build-for-testing\n"
    "2026-10-05T11:15:00.0000000Z \x1b[36;1mscripts/ci/run-xcodebuild-with-diagnostics.sh build-for-testing\x1b[0m\n"
    "2026-10-05T11:15:00.0000000Z ##[endgroup]\n"
    + "2026-10-05T11:15:39.6216300Z warning: CAS error: read-only cache client\n" * 411
    + "2026-10-05T11:15:39.7000000Z error: read-only cache client\n" * 3
    + "2026-10-05T11:15:40.0000000Z error: failed to update cache: cache poisoned\n" * 45
    + textwrap.dedent("""\
    2026-10-05T11:16:38.8339440Z /tmp/cmux-ci/src/Sources/TerminalController.swift:119:16: note: static property declared here
    2026-10-05T11:16:38.8340200Z /tmp/cmux-ci/src/Sources/AppDelegate.swift:20553:39: error: cannot find type 'UpdateRelaunchBlockers' in scope
    2026-10-05T11:16:38.8340570Z     func updaterRelaunchBlockers() -> UpdateRelaunchBlockers {
    2026-10-05T11:16:38.8341110Z /tmp/cmux-ci/src/Sources/AppDelegate.swift:20588:10: error: cannot find type 'UpdateRelaunchBlockers' in scope
    2026-10-05T11:16:38.8342050Z /tmp/cmux-ci/src/Sources/AppDelegate.swift:2028:87: warning: 'activateIgnoringOtherApps' was deprecated in macOS 14.0
    2026-10-05T11:16:38.8407140Z /tmp/cmux-ci/src/Sources/AppDelegate.swift:20589:24: error: cannot find 'UpdateRelaunchBlockers' in scope
    2026-10-05T11:16:43.4671470Z ** TEST BUILD FAILED **
    2026-10-05T11:16:43.4671900Z \tSwiftCompile normal arm64 Compiling\\ AppDelegate.swift /tmp/cmux-ci/src/Sources/AppDelegate.swift (in target 'cmux' from project 'cmux')
    2026-10-05T11:16:43.9931880Z ##[error]Process completed with exit code 65.
    """))

# XCTest, a crash, the warning budget and the CLI help contract, as their scripts print them.
OTHER_FAILURES_LOG = textwrap.dedent("""\
    2026-10-05T13:00:00.0000000Z /Users/cmux/actions-runner/_work/cmux/cmux/cmuxTests/WorkspaceTabTests.swift:88: error: -[cmuxTests.WorkspaceTabTests testCloseKeepsSelection] : XCTAssertEqual failed: ("1") is not equal to ("2")
    2026-10-05T13:00:00.1000000Z Test Case '-[cmuxTests.WorkspaceTabTests testCloseKeepsSelection]' failed (0.120 seconds).
    2026-10-05T13:00:00.2000000Z Test Case '-[cmuxTests.SidebarDropTests testDropReorders]' failed (0.050 seconds).
    2026-10-05T13:08:10.7508640Z objc[68679]: Cannot form weak reference to instance (0xaacbf7c00) of class NSKVONotifying_NSWindow. It is possible that this object was over-released, or is in the process of deallocation.
    2026-10-05T13:08:10.7509000Z *** Program crashed: Aborted at 0x000000018eaf2b10 ***
    2026-10-05T13:09:00.0000000Z Swift warning budget exceeded.
    2026-10-05T13:09:00.0000000Z
    2026-10-05T13:09:00.0000000Z +1 Sources/Panels/BrowserPanel.swift: variable 'x' was never mutated; consider changing to 'let' constant
    2026-10-05T13:09:00.0000000Z    actual=1 budget=0
    2026-10-05T13:09:00.0000000Z Fix the new warnings or refresh the budget only when accepting known debt.
    2026-10-05T13:10:00.0000000Z FAIL: CLI help contract probes failed
    2026-10-05T13:10:00.0000000Z
    2026-10-05T13:10:00.0000000Z cmux settings --help: stale literal target usage still present
    2026-10-05T13:10:00.0000000Z stdout='Usage: cmux settings [open|path|docs|target]'
    2026-10-05T13:10:00.0000000Z ##[error]Process completed with exit code 1.
    """)


def red_report(log: str, name: str = "macos / app-host unit tests (changed suites)") -> dict:
    jobs = cf.classify_jobs([job(1, name)], {1: (log, [])})
    return {"run_id": 37254190713, "attempt": 1, "head_sha": "a" * 40, "run_url": "https://run",
            "conclusion": "failure", "jobs": jobs, "macos_ran": True}


def main_issue(failures: list[dict], number: int = 17300) -> tuple[dict, list[dict]]:
    """main_full_suite.py's open issue, its latest comment carrying the red run's failures."""
    import main_full_suite

    run = {"id": 9, "head_sha": "c" * 40, "html_url": "https://run/9"}
    body = main_full_suite.failure_body(run, [], "", failures)
    return ({"number": number, "html_url": f"https://github.com/manaflow-ai/cmux/issues/{number}", "comments": 1,
             "body": "Full-suite CI on `main` failed at older"}, [{"body": body}])


class ExtractTests(unittest.TestCase):
    def test_own_test_failures_come_with_file_line_and_name(self) -> None:
        found = cf.extract_failures(PR_17074_LOG)
        self.assertEqual([(f["kind"], cf.where(f)) for f in found],
                         [("test", "CloudPortsVPNAffordanceTests.swift:285"),
                          ("test", "DeviceDiscoverabilityGatingTests.swift:20")])
        self.assertEqual(found[1]["test"], "Cloud/Beta gating keeps both bottom actions present but disabled")
        self.assertIn('"Discover other Macs"', found[1]["message"])

    def test_a_compile_error_under_cache_noise_is_found(self) -> None:
        found = cf.extract_failures(PR_17232_LOG)
        self.assertEqual([(f["kind"], f["file"], f["line"]) for f in found],
                         [("compile", "Sources/AppDelegate.swift", 20553), ("compile", "Sources/AppDelegate.swift", 20588),
                          ("compile", "Sources/AppDelegate.swift", 20589)])
        self.assertEqual(found[0]["message"], "cannot find type 'UpdateRelaunchBlockers' in scope")
        # The job's evidence line is the compile error too, not the cache noise.
        self.assertEqual(cf.classify_text(PR_17232_LOG)["signature"], "compile-error")

    def test_xctest_crash_warning_budget_and_cli_contract(self) -> None:
        found = cf.extract_failures(OTHER_FAILURES_LOG)
        self.assertEqual([(f["kind"], cf.where(f), f["test"]) for f in found], [
            ("test", "WorkspaceTabTests.swift:88", "WorkspaceTabTests.testCloseKeepsSelection"),
            # No issue line: the suite names its file, for ownership.
            ("test", "SidebarDropTests.swift", "SidebarDropTests.testDropReorders"),
            ("crash", "", ""), ("crash", "", ""),
            ("warning", "BrowserPanel.swift", ""),
            ("cli-contract", "", ""),
        ])
        self.assertIn("NSKVONotifying_NSWindow", found[2]["message"])
        self.assertEqual(found[3]["message"], "Aborted")
        self.assertEqual(found[5]["message"], "cmux settings --help: stale literal target usage still present")

    def test_failures_outside_failed_steps_and_in_echoed_scripts_do_not_count(self) -> None:
        log = textwrap.dedent(f"""\
            2026-10-05T10:00:00.0Z ##[group]Run swift test
            2026-10-05T10:00:00.0Z {ESC}[36;1mecho "Sources/X.swift:1:1: error: spelled in a script"{ESC}[0m
            2026-10-05T10:00:00.0Z ##[endgroup]
            2026-10-05T10:00:01.0Z ✘ Test retried() recorded an issue at RetryTests.swift:3:1: passed on retry
            2026-10-05T10:00:02.0Z ##[group]Run guards
            2026-10-05T10:00:02.0Z {ESC}[36;1mguards{ESC}[0m
            2026-10-05T10:00:02.0Z ##[endgroup]
            2026-10-05T10:00:03.0Z ✘ Test real() recorded an issue at RealTests.swift:9:1: Expectation failed
            2026-10-05T10:00:03.0Z ##[error]Process completed with exit code 1.
            """)
        self.assertEqual([cf.where(f) for f in cf.extract_failures(log)], ["RealTests.swift:9"])

    def test_the_list_is_capped(self) -> None:
        log = "".join(f"✘ Test t{i}() recorded an issue at T{i}Tests.swift:{i}:1: no\n" for i in range(30))
        self.assertEqual(len(cf.extract_failures(log + "##[error]Process completed with exit code 1.\n")),
                         cf.MAX_FAILURES_PER_JOB)


class OwnershipTests(unittest.TestCase):
    def comment(self, report: dict, files: list[str], main: tuple[dict, list[dict]] | None = None) -> str:
        issue, comments = main or (None, [])
        gh = FakeGitHub(files=files, main_issue=issue, main_comments=comments)
        cf.act(gh, cf.Writer(gh, dry_run=True), ActTests.RUN, report)  # type: ignore[arg-type]
        return cf.render_comment(report, "line")

    @staticmethod
    def verdict(body: str) -> str:
        return body.splitlines()[2]

    def test_17074_its_own_test_files_are_yours(self) -> None:
        body = self.comment(red_report(PR_17074_LOG), PR_17074_FILES)
        self.assertTrue(body.startswith(cf.MARKER))
        self.assertEqual(self.verdict(body),
                         "**Yours to fix:** `CloudPortsVPNAffordanceTests.swift:285` (a file this PR changes), "
                         "`DeviceDiscoverabilityGatingTests.swift:20` (a file this PR changes).")
        self.assertIn("- **yours** `CloudPortsVPNAffordanceTests.swift:285`", body)

    def test_a_compile_error_in_a_changed_file_is_yours_with_its_line(self) -> None:
        body = self.comment(red_report(PR_17232_LOG, "macos / macOS compile admission"),
                            ["Sources/AppDelegate.swift", "Sources/Panels/BrowserPanel.swift"])
        self.assertTrue(self.verdict(body).startswith(
            "**Yours to fix:** compile error in `Sources/AppDelegate.swift:20553` "
            "`cannot find type 'UpdateRelaunchBlockers' in scope` (a file this PR changes)"))
        self.assertNotIn("read-only cache client", body)

    def test_a_failure_main_shares_is_not_yours(self) -> None:
        # The real #17232 did not touch AppDelegate.swift: main broke it (#17368), and main's full
        # suite failed the same way, at other line numbers.
        main_failures = [{**f, "line": f["line"] + 3} for f in cf.extract_failures(PR_17232_LOG)]
        body = self.comment(red_report(PR_17232_LOG, "macos / macOS compile admission"),
                            ["Sources/Panels/BrowserPanel.swift"], main_issue(main_failures))
        self.assertTrue(self.verdict(body).startswith("**Not yours:** compile error in `Sources/AppDelegate.swift:20553`"))
        self.assertIn("also fails on main (#17300); merge main once it is fixed there.", self.verdict(body))
        self.assertIn("- **also red on main**", body)

    def test_a_failure_neither_owned_nor_on_main_is_probably_yours(self) -> None:
        # #17233: the failing suites test code the PR changed, under other names.
        body = self.comment(red_report(PR_17074_LOG), ["Sources/Cloud/CloudTreeNode.swift"], main_issue([]))
        self.assertTrue(self.verdict(body).startswith("**Probably yours:** `CloudPortsVPNAffordanceTests.swift:285`"))
        self.assertIn("not on main's latest full suite", self.verdict(body))
        body = self.comment(red_report(PR_17074_LOG), ["Sources/Cloud/CloudTreeNode.swift"])
        self.assertIn("not on main, whose full suite is green", self.verdict(body))

    def test_a_test_of_a_changed_source_file_is_yours(self) -> None:
        item = cf.failure("test", "cmuxTests/DevicesCloudTreeBuilderTests.swift", 48, "builds")
        self.assertEqual(cf.owner(item, ["Sources/Cloud/DevicesCloudTreeBuilder.swift"], []),
                         (cf.YOURS, "tests DevicesCloudTreeBuilder.swift, which this PR changes"))

    def test_machine_failures_keep_their_verdict(self) -> None:
        report = red_report(RESTORE_FAILED)
        self.assertEqual(report["jobs"][0]["failures"], [])
        self.assertTrue(self.verdict(cf.render_comment(report, "re-ran", True)).startswith("**Machine:**"))

    def test_main_failure_data_survives_log_text_that_closes_a_comment(self) -> None:
        item = cf.failure("compile", "Sources/X.swift", 1, message="expected '-->' here")
        marker = cf.main_failures_marker({"id": 1, "head_sha": "c"}, [item])
        self.assertEqual(marker.count("-->"), 1)
        self.assertEqual(cf.parse_main_failures(["old", marker])["keys"], [cf.failure_key(item)])


class StaleAndSkippedTests(unittest.TestCase):
    OLD = "2957faacff" + "0" * 30
    NEW = "b5691441b0" + "0" * 30

    def passed_body(self, head: str) -> str:
        return cf.render_comment({"run_id": 1, "attempt": 1, "head_sha": head, "run_url": "u",
                                  "conclusion": "success", "jobs": [], "macos_ran": True}, "")

    def test_a_pass_for_an_older_head_turns_pending_when_the_new_heads_ci_starts(self) -> None:
        gh = FakeGitHub(head=self.NEW, comments=[bot_comment(self.passed_body(self.OLD))])
        run = {**ActTests.RUN, "head_sha": self.NEW, "status": "requested", "html_url": "https://run/2"}
        writer = cf.Writer(gh, dry_run=True)
        self.assertEqual(cf.act_requested(gh, writer, run)["line"], "marked pending on b5691441b0")
        (entry,) = writer.log
        self.assertIn("would PATCH repos/manaflow-ai/cmux/issues/comments/99", entry)
        self.assertIn("**Pending:** CI is running on `b5691441b0` ([run](https://run/2)); the result below was "
                      "for `2957faacff`", entry)
        self.assertNotIn("**Passes:**", entry)
        self.assertEqual(cf.verdict_of(entry).split(":")[0], "**Pending")
        self.assertIn("Last result: Passes: CI passes on `2957faacff`.", entry)
        # Once pending on this head, a second start (a re-run) leaves it alone.
        gh = FakeGitHub(head=self.NEW, comments=[bot_comment(entry.split("\n", 1)[1])])
        writer = cf.Writer(gh, dry_run=True)
        self.assertEqual(cf.act_requested(gh, writer, run)["line"], "nothing to mark")
        self.assertEqual(writer.log, [])

    def test_a_legacy_pass_comment_is_rewritten_when_an_older_heads_run_completes(self) -> None:
        legacy = f"{cf.MARKER}\n### CI failure attribution\n\nCI passes on `{self.OLD[:10]}` (run).\n"
        gh = FakeGitHub(head=self.NEW, comments=[bot_comment(legacy)])
        result = cf.act(gh, cf.Writer(gh, dry_run=False), {**ActTests.RUN, "head_sha": self.OLD},
                        {**red_report(PR_17074_LOG), "head_sha": self.OLD})
        self.assertEqual(result["line"], "marked pending on b5691441b0")
        self.assertEqual(gh.calls, [("PATCH", "repos/manaflow-ai/cmux/issues/comments/99")])

    def test_a_pr_merged_before_its_ci_finished_still_hears_it_and_is_not_rerun(self) -> None:
        gh = FakeGitHub(state="closed", merged=True, files=PR_17074_FILES)
        writer = cf.Writer(gh, dry_run=True)
        result = cf.act(gh, writer, ActTests.RUN, red_report(PR_17074_LOG))
        self.assertFalse(result["rerun"])
        (entry,) = writer.log
        self.assertIn("would POST repos/manaflow-ai/cmux/issues/7/comments", entry)
        self.assertIn("This PR merged before its CI finished: fix forward on main.", entry)
        gh = FakeGitHub(state="closed", merged=True)
        self.assertTrue(cf.act(gh, cf.Writer(gh, False), ActTests.RUN, red_report(RESTORE_FAILED))["line"]
                        .startswith("Not re-run: this PR has merged"))

    def test_a_green_run_whose_macos_jobs_never_ran_is_not_reported_green(self) -> None:
        jobs = [job(1, "macos", conclusion="skipped"), job(2, "macOS admission gate", conclusion="skipped"),
                job(3, "guards / workflow-guard-tests / ci", conclusion="success"),
                job(4, "macos / macOS status", conclusion="success")]
        self.assertFalse(cf.macos_ran(jobs))
        self.assertTrue(cf.macos_ran([job(5, "macos / macOS compile admission", conclusion="success")]))
        green = {"run_id": 1, "attempt": 1, "head_sha": "a" * 40, "run_url": "u", "conclusion": "success",
                 "jobs": [], "macos_ran": False}
        gh = FakeGitHub(files=["Sources/AppDelegate.swift"])
        writer = cf.Writer(gh, dry_run=True)
        cf.act(gh, writer, ActTests.RUN, dict(green))
        (entry,) = writer.log
        self.assertIn("**Not verified:** macOS jobs did not run: compile and app tests were skipped on `aaaaaaaaaa`",
                      entry)
        self.assertNotIn("**Passes:**", entry)
        # A docs-only PR that routes nothing to macOS stays quiet.
        gh = FakeGitHub(files=["docs/ci/merge-main.md"])
        writer = cf.Writer(gh, dry_run=True)
        cf.act(gh, writer, ActTests.RUN, dict(green))
        self.assertEqual(writer.log, [])

    def test_a_red_run_says_when_macos_was_skipped(self) -> None:
        report = {**red_report(NOISE, "Fast static checks"), "macos_ran": False}
        gh = FakeGitHub(files=["Sources/AppDelegate.swift"])
        writer = cf.Writer(gh, dry_run=True)
        cf.act(gh, writer, ActTests.RUN, report)
        self.assertIn("macOS jobs did not run: compile and app tests were skipped.", writer.log[0])


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))

    def test_follows_ci(self) -> None:
        on = self.workflow.get("on", self.workflow.get(True))
        self.assertEqual(on["workflow_run"]["workflows"], ["CI"])
        # `requested` marks an older head's comment pending as soon as a new head's CI starts.
        self.assertEqual(on["workflow_run"]["types"], ["completed", "requested"])
        (only,) = self.workflow["jobs"].values()
        self.assertIn("github.event.action == 'requested'", only["if"])

    def test_runs_mains_script_and_never_checks_out_the_pull_request(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("head_sha", text.split("steps:", 1)[1])
        self.assertNotIn("ref:", text)
        (only,) = self.workflow["jobs"].values()
        self.assertEqual(only["permissions"]["actions"], "write")
        self.assertFalse(self.workflow["concurrency"]["cancel-in-progress"])
        self.assertNotIn("contents", {k for k, v in only["permissions"].items() if v == "write"})

    def test_every_gate_job_exists_under_the_name_the_jobs_api_reports(self) -> None:
        # The jobs API names a job by its display name, prefixed by the calling
        # job's for a reusable workflow ("macos / macOS status").
        ci = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8"))
        jobs: dict[str, dict] = {}
        for job_id, body in ci["jobs"].items():
            called = str(body.get("uses") or "")
            if called.startswith("./.github/workflows/"):
                callee = yaml.safe_load((ROOT / called.removeprefix("./")).read_text(encoding="utf-8"))
                for inner_id, inner in callee["jobs"].items():
                    jobs[f"{body.get('name') or job_id} / {inner.get('name') or inner_id}"] = inner
            else:
                jobs[str(body.get("name") or job_id)] = body
        for name in sorted(cf.GATE_JOBS):
            with self.subTest(name=name):
                self.assertIn(name, jobs, "a GATE_JOBS name no longer matches a CI job")
                self.assertTrue(jobs[name].get("needs"), f"{name} reads no `needs`, so it is not a gate")

if __name__ == "__main__":
    unittest.main()

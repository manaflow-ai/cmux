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

    def test_a_test_failure_on_a_healthy_runner_is_the_code(self) -> None:
        self.assertEqual(self.verdict(TEST_FAILED), (cf.CODE, "swift-testing-issue"))
        self.assertEqual(self.verdict(PARAMETERIZED_TEST_FAILED), (cf.CODE, "swift-testing-issue"))
        self.assertEqual(self.verdict(DISPLAY_NAME_TEST_FAILED), (cf.CODE, "swift-testing-issue"))
        self.assertEqual(self.verdict(COMPILE_FAILED), (cf.CODE, "compile-error"))
        self.assertEqual(self.verdict(STATIC_CHECK_FAILED), (cf.CODE, "static-check-failed"))

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

    def test_one_code_or_unknown_failure_keeps_the_run_red(self) -> None:
        for other in (cf.CODE, cf.UNKNOWN):
            rerun, line = cf.rerun_decision(self.report([cf.MACHINE, other]), self.LATEST)
            self.assertFalse(rerun)
            self.assertIn("`job 1`", line)

    def test_an_automatic_re_run_is_not_re_run_again(self) -> None:
        # The bot's own re-run went to Blacksmith; nothing a comment says can restart it.
        rerun, line = cf.rerun_decision(self.report([cf.MACHINE], attempt=2),
                                        {"run_attempt": 2, "status": "completed",
                                         "triggering_actor": {"login": cf.BOT}})
        self.assertFalse(rerun)
        self.assertIn("attempt 2", line)

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
                 latest: dict | None = None):
        self.head, self.state = head, state
        self._comments = comments or []
        self.latest = latest or {"run_attempt": 1, "status": "completed"}
        self.calls: list[tuple[str, str]] = []

    def pull(self, number: int) -> dict:
        return {"number": number, "state": self.state, "head": {"sha": self.head}}

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
        self.assertEqual(gh.calls, [("POST", "repos/manaflow-ai/cmux/actions/runs/42/rerun-failed-jobs"),
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


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))

    def test_follows_ci(self) -> None:
        on = self.workflow.get("on", self.workflow.get(True))
        self.assertEqual(on["workflow_run"]["workflows"], ["CI"])
        self.assertEqual(on["workflow_run"]["types"], ["completed"])

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

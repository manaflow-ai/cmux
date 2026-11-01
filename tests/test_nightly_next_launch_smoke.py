#!/usr/bin/env python3
"""The cmux NEXT fresh-home launch smoke: a pre-publish gate in nightly.yml, and a post-publish backstop.

Leo, 2026-10-29, on build 4091813159501, which Sparkle downloaded and the post-publish smoke pulled
afterwards: "Just don't have that be the downloading thing." So nightly.yml smokes the exact DMG it
would publish before any appcast names it (scripts/ci/nightly-steps/launch-smoke-gate.sh, in
verify-final-dmg-nightly and verify-recovered-nightly-next): a crash on both attempts fails the verify
job, and publish-nightly, which needs that job's success, puts nothing of the build on the feed.

Leo, 2026-10-23: "we want no smoke tests. No smoke tests, okay? Or at least, like, you know,
previously we had the daemon with a smoke test literally block the entire nightly release, right?
Like, that's unacceptable." So only a crash with the app's own launch evidence holds a build: a
cannot-run (no GUI session, a harness or infrastructure error before launch, a hung attempt) passes
the gate, and the post-publish smoke (nightly-next-launch-smoke.yml) acts after the fact:

  - pass does nothing; cannot-run (no Mac, an infrastructure or harness error before launch, or a
    check cut short) does nothing and never rolls back;
  - a crash on both attempts rolls the feed back through nightly-next-rollback.yml (dispatched, no
    second copy of its logic), only while the build is still the feed's newest, so a second report
    of the same build does nothing and a rollback never goes past the kept good build;
  - nothing waits on the post-publish workflow: no nightly.yml job needs it or reads its result.
"""
from __future__ import annotations

import contextlib
import io
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly-next-launch-smoke.yml"
NIGHTLY = ROOT / ".github" / "workflows" / "nightly.yml"
GATE = ROOT / "scripts" / "ci" / "nightly-steps" / "launch-smoke-gate.sh"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


smoke = load("nightly_next_launch_smoke", ROOT / "scripts" / "ci" / "nightly_next_launch_smoke.py")
rollback = load("nightly_next_feed_rollback", ROOT / "scripts" / "ci" / "nightly_next_feed_rollback.py")
BASE = "https://files-next.cmux.com/nightly-next/next"


def feed(*builds: int, channel: dict | None = None) -> str:
    channel = channel or {}
    items = "".join(
        f"<item><title>{b}</title><sparkle:version>{b}</sparkle:version>"
        + (f"<sparkle:channel>{channel[b]}</sparkle:channel>" if b in channel else "")
        + f'<enclosure url="{BASE}/cmux-nightly-next-macos-arm64-{b}.dmg" length="5" sparkle:edSignature="s"/></item>'
        for b in builds)
    return ('<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            f"<channel>{items}</channel></rss>")


RAN = {"verdict": "fail", "pid": 4242, "failures": ["the app exited (signal 11) 2.8s after launch"]}
PASSED = {"verdict": "pass", "pid": 4242}
NO_LAUNCH = {"verdict": "cannot-run", "failures": ["this process is in a Background session, not Aqua (no GUI)"]}


class VerdictTests(unittest.TestCase):
    def test_a_pass_on_either_attempt_passes(self) -> None:
        self.assertEqual(smoke.verdict([(0, PASSED)]), smoke.PASS)
        self.assertEqual(smoke.verdict([(1, RAN), (0, PASSED)]), smoke.PASS)

    def test_a_crash_needs_both_attempts_to_crash_with_the_app_launched(self) -> None:
        self.assertEqual(smoke.verdict([(1, RAN), (1, RAN)]), smoke.CRASH)

    def test_what_could_not_run_is_cannot_run(self) -> None:
        self.assertEqual(smoke.verdict([]), smoke.CANNOT_RUN)  # no Mac, the download failed
        self.assertEqual(smoke.verdict([(3, NO_LAUNCH)]), smoke.CANNOT_RUN)  # no GUI session, a signing keychain
        self.assertEqual(smoke.verdict([(2, {})]), smoke.CANNOT_RUN)  # a harness usage error
        self.assertEqual(smoke.verdict([(1, RAN), (3, NO_LAUNCH)]), smoke.CANNOT_RUN)
        self.assertEqual(smoke.verdict([(1, RAN)]), smoke.CANNOT_RUN)  # cut short after one crash

    def test_exit_1_without_the_harness_evidence_of_a_launch_is_not_a_crash(self) -> None:
        # The console-session hop failing, or an uncaught setup error: exit 1, no report or no pid.
        self.assertEqual(smoke.verdict([(1, {}), (1, {})]), smoke.CANNOT_RUN)
        self.assertEqual(smoke.verdict([(1, {"verdict": "fail"}), (1, {"verdict": "fail"})]), smoke.CANNOT_RUN)
        self.assertEqual(smoke.verdict([(0, {})]), smoke.CANNOT_RUN)

    def test_attempts_are_read_from_the_runs_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for n, (status, report) in enumerate([(1, RAN), (1, None)], start=1):
                (root / f"status-{n}").write_text(f"{status}\n")
                (root / f"attempt-{n}").mkdir()
                if report is not None:
                    (root / f"attempt-{n}" / "report.json").write_text(json.dumps(report))
            self.assertEqual(smoke.read_attempts(root), [(1, RAN), (1, {})])
            self.assertEqual(smoke.verdict(smoke.read_attempts(root)), smoke.CANNOT_RUN)


class DecideTests(unittest.TestCase):
    def test_a_pass_does_nothing(self) -> None:
        self.assertEqual(smoke.decide(feed(200, 150), 200, smoke.PASS)["action"], "none")

    def test_a_smoke_that_cannot_run_never_rolls_back(self) -> None:
        self.assertEqual(smoke.decide(feed(200, 150), 200, smoke.CANNOT_RUN)["action"], "none")

    def test_a_crash_of_the_newest_build_rolls_back_to_the_kept_build(self) -> None:
        decision = smoke.decide(feed(200, 150), 200, smoke.CRASH)
        self.assertEqual(decision["action"], "rollback")
        self.assertEqual(decision["serving"], 150)

    def test_a_second_crash_report_of_the_same_build_does_not_roll_back_twice(self) -> None:
        live = feed(200, 150)
        self.assertEqual(smoke.decide(live, 200, smoke.CRASH)["action"], "rollback")
        # nightly-next-rollback.yml's own plan, as the dispatched rollback writes it.
        pulled, summary = rollback.plan(live, bad="200")
        self.assertEqual(summary["serving"], "150")
        again = smoke.decide(pulled, 200, smoke.CRASH)
        self.assertEqual(again["action"], "none")
        self.assertIn("no longer on the feed", again["why"])

    def test_the_rollback_never_pulls_a_build_published_after_the_crash_was_judged(self) -> None:
        # The smoke judged 200 the newest; 250 landed before the rollback read the feed.
        live = feed(250, 200, 150)
        pulled, summary = rollback.plan(live, bad="200", if_newest="200")
        self.assertFalse(summary["changed"])
        self.assertEqual(pulled, live)
        # Still the newest: the pull goes ahead.
        _, summary = rollback.plan(feed(200, 150), bad="200", if_newest="200")
        self.assertEqual((summary["changed"], summary["serving"]), (True, "150"))

    def test_a_rollback_never_goes_past_the_kept_good_build(self) -> None:
        # The kept build is never pulled: once 200 is gone, a crash report of 150's successor is
        # stale, and a crash of the only build left pulls nothing.
        self.assertEqual(smoke.decide(feed(150), 150, smoke.CRASH)["action"], "none")
        # A newer build on the feed: rolling back 200 would pull 250 too, so nothing happens.
        self.assertEqual(smoke.decide(feed(250, 200, 150), 200, smoke.CRASH)["action"], "none")

    def test_only_a_build_nightly_apps_are_offered_is_served_instead(self) -> None:
        live = feed(200, 180, channel={180: "cmux-next-dev"})
        self.assertEqual(smoke.decide(live, 200, smoke.CRASH)["action"], "none")
        live = feed(200, 180, 150, channel={180: "cmux-next-dev", 150: "cmux-next"})
        self.assertEqual(smoke.decide(live, 200, smoke.CRASH)["serving"], 150)

    def test_a_stable_ring_build_is_served_instead(self) -> None:
        # Nightly apps accept cmux-next-stable, so the stable build before a crashed newest one is served.
        live = feed(200, 180, channel={200: "cmux-next", 180: "cmux-next-stable"})
        decision = smoke.decide(live, 200, smoke.CRASH)
        self.assertEqual(decision["action"], "rollback")
        self.assertEqual(decision["serving"], 180)

    def test_the_nightly_channels_match_what_nightly_apps_accept(self) -> None:
        live_check = load("nightly_next_live_feed_check", ROOT / "scripts" / "ci" / "nightly_next_live_feed_check.py")
        self.assertEqual(set(smoke.NIGHTLY_CHANNELS) - {None}, set(live_check.NIGHTLY_ACCEPTED))


class EvidenceTests(unittest.TestCase):
    def test_the_issue_body_carries_the_failures_crash_and_log_tail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ips = Path(tmp) / "cmux-2026-10-27-224207.ips"
            ips.write_text(json.dumps({"app_name": "cmux", "app_version": "1.0.0", "build_version": "4062224162001"})
                           + "\n" + json.dumps({"exception": {"type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"},
                                                "termination": {"namespace": "SIGNAL", "indicator": "Segmentation fault: 11"}}))
            report = {"failures": ["the app exited (signal 11) 2.8s after launch"],
                      "system_log_errors": ["cmux[1:2] *** Assertion failure in <private>, NSStackView.m:873"]}
            log = "\n".join(f"line {n}" for n in range(100))
            body = smoke.evidence(report, log, [ips])
        self.assertIn("the app exited (signal 11)", body)
        self.assertIn("NSStackView.m:873", body)
        self.assertIn("EXC_BAD_ACCESS SIGSEGV", body)
        self.assertIn("line 99", body)
        self.assertNotIn("line 50\n", body)


class DmgDigestTests(unittest.TestCase):
    """The smoke checks the downloaded DMG's bytes against the feed item's edSignature
    (nightly_next_artifact_check.py), not only its byte length."""

    def test_pick_names_the_items_ed_signature(self) -> None:
        text = feed(300, 200, channel={300: "cmux-next-dev"})
        self.assertEqual(smoke.pick(text), (200, f"{BASE}/cmux-nightly-next-macos-arm64-200.dmg", "5", "s"))
        unsigned = text.replace(' sparkle:edSignature="s"', "")
        self.assertEqual(smoke.pick(unsigned)[3], "")

    def test_the_download_step_verifies_the_bytes(self) -> None:
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        self.assertEqual(jobs["pick"]["outputs"]["ed_signature"], "${{ steps.feed.outputs.ed_signature }}")
        self.assertEqual(jobs["smoke"]["env"]["DMG_ED_SIGNATURE"], "${{ needs.pick.outputs.ed_signature }}")
        sparse = jobs["smoke"]["steps"][0]["with"]["sparse-checkout"].split()
        self.assertIn("scripts/ci/nightly_next_artifact_check.py", sparse)
        self.assertIn("scripts/ci/release-signer/verify_appcast_item.py", sparse)
        download = next(step for step in jobs["smoke"]["steps"] if step.get("id") == "dmg")["run"]
        self.assertIn("nightly_next_artifact_check.py dmg", download)
        self.assertIn('--ed-signature "$DMG_ED_SIGNATURE"', download)
        self.assertIn('--length "$DMG_LENGTH"', download)


class NothingWaitsOnTheSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.text = WORKFLOW.read_text(encoding="utf-8")
        cls.workflow = yaml.safe_load(cls.text)
        cls.jobs = cls.workflow["jobs"]
        cls.nightly_text = NIGHTLY.read_text(encoding="utf-8")
        cls.nightly = yaml.safe_load(cls.nightly_text)

    def test_the_publish_job_never_needs_the_smoke(self) -> None:
        publish = self.nightly["jobs"]["publish-nightly"]
        needs = publish.get("needs") or []
        needs = [needs] if isinstance(needs, str) else needs
        for need in needs:
            self.assertNotRegex(need, r"smoke", f"publish-nightly needs {need}")
        self.assertNotIn("nightly-next-launch-smoke", self.nightly_text)
        self.assertNotIn("fresh_home_launch_smoke", self.nightly_text)

    def test_no_workflow_waits_on_or_triggers_from_the_smoke(self) -> None:
        # The owned-pool rescue only re-runs a refused smoke job; it gates nothing.
        watchers = {WORKFLOW.name, "ci-owned-pool-rescue.yml"}
        for path in (ROOT / ".github" / "workflows").glob("*.yml"):
            if path.name in watchers:
                continue
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("nightly-next launch smoke", text, f"{path.name} names the smoke workflow")
            self.assertNotIn("nightly-next-launch-smoke", text, f"{path.name} names the smoke workflow")

    def test_the_smoke_runs_after_publication_from_the_feed(self) -> None:
        triggers = self.workflow.get("on") or self.workflow.get(True)
        self.assertEqual(set(triggers), {"schedule", "workflow_dispatch", "pull_request"})
        self.assertIn("files-next.cmux.com/nightly-next/next/appcast-arm64.xml", self.text)

    def test_a_crash_rolls_back_through_nightly_next_rollback(self) -> None:
        crashed = self.jobs["crashed"]
        self.assertIn("needs.smoke.outputs.verdict == 'crash'", crashed["if"])
        self.assertIn("github.event_name != 'pull_request'", crashed["if"])
        run = "\n".join(step.get("run", "") for step in crashed["steps"])
        self.assertIn("gh workflow run nightly-next-rollback.yml", run)
        self.assertIn('-f bad_build="$BUILD" -f if_newest="$BUILD"', run)
        # Every rollback dispatch carries if_newest: one without it would pull a build published
        # while the rollback waited in a queue. A target that predates the input fails the step.
        joined = re.sub(r"\\\n\s*", " ", self.text)
        dispatches = re.findall(r"gh workflow run nightly-next-rollback\.yml[^\n]*", joined)
        self.assertTrue(dispatches)
        for dispatch in dispatches:
            self.assertIn("if_newest", dispatch, dispatch)
        self.assertNotIn("unexpected inputs", self.text)
        self.assertEqual(crashed["concurrency"]["cancel-in-progress"], False)
        self.assertIn("needs.pick.outputs.build", crashed["concurrency"]["group"])
        self.assertIn("--state all", run)
        self.assertIn("nightly_next_launch_smoke.py decide", run)
        # No second copy of the rollback's logic: nothing here writes the feed.
        self.assertNotRegex(self.text, r"upload-r2-object|R2_ENDPOINT|nightly_next_feed_rollback")

    def test_tooling_comes_from_feat_cmux_next_except_a_pull_request_into_it(self) -> None:
        self.assertEqual(self.workflow["env"]["TOOLING_REF"],
                         "${{ github.event_name == 'pull_request' && github.base_ref == 'feat-cmux-next' "
                         "&& github.sha || 'feat-cmux-next' }}")
        for name in ("smoke", "crashed"):
            checkout = self.jobs[name]["steps"][0]
            self.assertEqual(checkout["with"]["ref"], "${{ env.TOOLING_REF }}", name)

    def test_a_tooling_ref_without_the_tooling_judges_nothing(self) -> None:
        # A pull request into main runs before feat-cmux-next has the tooling: no verdict, so
        # nothing rolls back, nothing is cached, and the step does not fail.
        record = next(s for s in self.jobs["smoke"]["steps"] if s.get("name") == "Record the verdict")
        run = record["run"]
        guard = run.index("if [ ! -f scripts/ci/nightly_next_launch_smoke.py ]; then")
        self.assertLess(guard, run.index("nightly_next_launch_smoke.py verdict"))
        self.assertIn("exit 0", run[guard:run.index("fi", guard)])

    def test_a_cannot_run_is_retried_within_the_hour(self) -> None:
        # A pass is cached per build; a cannot-run only under a key for the pick's UTC hour, so
        # one transient infrastructure failure never stops a build from being smoked again.
        record = self.jobs["record"]
        key = record["steps"][-1]["with"]["key"]
        self.assertEqual(key, "${{ env.SMOKE_CACHE_PREFIX }}${{ needs.pick.outputs.build }}"
                              "${{ needs.smoke.outputs.verdict == 'cannot-run' && "
                              "format('-cannot-run-{0}', needs.pick.outputs.hour) || '' }}")
        steps = {step.get("id"): step for step in self.jobs["pick"]["steps"]}
        self.assertEqual(steps["seen"]["with"]["key"],
                         "${{ env.SMOKE_CACHE_PREFIX }}${{ steps.feed.outputs.build }}")
        self.assertEqual(steps["seen-hour"]["with"]["key"],
                         "${{ env.SMOKE_CACHE_PREFIX }}${{ steps.feed.outputs.build }}"
                         "-cannot-run-${{ steps.hour.outputs.hour }}")
        self.assertIn("date -u +%Y%m%d%H", steps["hour"]["run"])
        self.assertEqual(self.jobs["pick"]["outputs"]["hour"], "${{ steps.hour.outputs.hour }}")

    def test_a_crash_is_never_marked_smoked_so_a_failed_rollback_is_retried(self) -> None:
        record = self.jobs["record"]
        self.assertNotIn("crash'", record["if"].replace("'pass'", "").replace("'cannot-run'", ""))
        self.assertIn("needs.smoke.outputs.verdict == 'pass'", record["if"])
        self.assertIn("needs.smoke.outputs.verdict == 'cannot-run'", record["if"])

    def test_no_secrets_no_environment_and_only_the_rollbacks_permissions(self) -> None:
        # The one secret is the routing App's key, read on Linux by the pick's placement (a read-only
        # token for the runner and queue reads), never by a pull request's run and never on the Mac
        # that runs the published app.
        mints = [step for step in self.jobs["pick"]["steps"] if "secrets." in json.dumps(step)]
        self.assertEqual([step.get("id") for step in mints], ["route-token"])
        self.assertIn("github.event_name != 'pull_request'", mints[0]["if"])
        self.assertEqual({key: value for key, value in mints[0]["with"].items() if key.startswith("permission-")},
                         {"permission-administration": "read", "permission-organization-self-hosted-runners": "read"})
        for name, job in self.jobs.items():
            if name != "pick":
                self.assertNotIn("secrets.", json.dumps(job), name)
        allowed = {"actions": "write", "contents": "read", "issues": "write"}
        self.assertEqual(self.workflow.get("permissions"), {})
        for name, job in self.jobs.items():
            if name == "pick":
                self.assertEqual(job["environment"], "${{ github.event_name != 'pull_request' && 'ci-routing-agent' || '' }}")
                continue
            self.assertNotIn("environment", job, name)
            for scope, level in (job.get("permissions") or {}).items():
                self.assertEqual(allowed.get(scope), level, f"{name}: {scope}: {level}")
        self.assertEqual(self.jobs["smoke"]["permissions"], {"contents": "read"})
        pick_steps = {step.get("id"): step for step in self.jobs["pick"]["steps"]}
        self.assertEqual(pick_steps["in-flight"]["env"]["GH_TOKEN"], "${{ github.token }}")
        self.assertEqual(pick_steps["place"]["env"]["SNAPSHOT_TOKEN"], "${{ github.token }}")

    def test_it_never_cancels_and_its_mac_job_routes_owned_first(self) -> None:
        self.assertNotRegex(self.text, r"cancel-in-progress:\s*true")
        # Only a pull request's run is replaced by a newer push; a schedule or dispatch never is.
        self.assertEqual(self.workflow["concurrency"]["cancel-in-progress"], "${{ github.event_name == 'pull_request' }}")
        # A schedule or dispatch run is alone in its group, so a waiting one is never replaced.
        self.assertEqual(self.workflow["concurrency"]["group"],
                         "nightly-next-launch-smoke-${{ github.event_name == 'pull_request' && "
                         "format('pr-{0}', github.event.pull_request.number) || github.run_id }}")
        runs_on = self.jobs["smoke"]["runs-on"]
        self.assertTrue(runs_on.rstrip(" }").endswith("'blacksmith-6vcpu-macos-26'"))
        self.assertLess(runs_on.index("CI_SIDE_LANE_RUNNER"), runs_on.rindex("blacksmith-6vcpu-macos-26"))
        for label in re.findall(r"'(macos-[^']+)'", runs_on):
            self.assertIn(f"github.repository_owner != 'manaflow-ai' && '{label}'", runs_on)


class InFlightTests(unittest.TestCase):
    """One smoke per build: a tick skips a build whose smoke another run has queued or running."""

    RUNS = [
        {"id": 5, "status": "queued", "event": "schedule"},       # this tick
        {"id": 4, "status": "queued", "event": "schedule"},       # smoke 200 waits for a Mac
        {"id": 3, "status": "in_progress", "event": "pull_request"},
        {"id": 2, "status": "completed", "event": "schedule"},
    ]
    JOBS = {
        4: [{"name": "pick", "conclusion": "success"}, {"name": "smoke 200", "status": "queued", "conclusion": None}],
        3: [{"name": "smoke 300", "status": "queued", "conclusion": None}],
        2: [{"name": "smoke 100", "status": "completed", "conclusion": "success"}],
        5: [{"name": "smoke 200", "status": "queued", "conclusion": None}],
    }

    def jobs_of(self, run: int) -> list[dict]:
        return self.JOBS.get(run, [])

    def test_a_queued_smoke_of_the_build_holds_it(self) -> None:
        self.assertEqual(smoke.in_flight(self.RUNS, self.jobs_of, 200, own_run=5), 4)
        self.assertEqual(smoke.in_flight(self.RUNS, self.jobs_of, "200", own_run=5), 4)

    def test_its_own_run_a_completed_run_and_another_build_hold_nothing(self) -> None:
        self.assertIsNone(smoke.in_flight(self.RUNS[1:], self.jobs_of, 200, own_run=4))  # only itself has one
        self.assertIsNone(smoke.in_flight(self.RUNS, self.jobs_of, 100, own_run=5))
        self.assertEqual(smoke.in_flight(self.RUNS, self.jobs_of, 300, own_run=5), 3)  # a pull request's smoke holds it
        self.assertIsNone(smoke.in_flight(self.RUNS, self.jobs_of, 400, own_run=5))

    def test_a_skipped_smoke_holds_nothing(self) -> None:
        runs = [{"id": 7, "status": "in_progress", "event": "schedule"}]
        skipped = {7: [{"name": "smoke 200", "status": "completed", "conclusion": "skipped"}]}
        self.assertIsNone(smoke.in_flight(runs, lambda run: skipped[run], 200, own_run=8))

    def test_a_smoke_done_while_its_run_still_records_holds_the_build(self) -> None:
        # The verdict is cached by the run's record job after the smoke: until the run completes,
        # a tick would not yet see the cache, so the build stays held.
        runs = [{"id": 7, "status": "in_progress", "event": "schedule"}]
        done = {7: [{"name": "smoke 200", "status": "completed", "conclusion": "success"}]}
        self.assertEqual(smoke.in_flight(runs, lambda run: done[run], 200, own_run=8), 7)

    def test_a_scheduled_tick_starts_no_second_smoke(self) -> None:
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        steps = {step.get("id"): step for step in jobs["pick"]["steps"]}
        self.assertIn("nightly_next_launch_smoke.py in-flight", steps["in-flight"]["run"])
        self.assertEqual(jobs["pick"]["outputs"]["in_flight"], "${{ steps.in-flight.outputs.in_flight }}")
        self.assertIn("(github.event_name != 'schedule' || needs.pick.outputs.in_flight == '')", jobs["smoke"]["if"])
        self.assertIn("(github.event_name != 'schedule' || steps.in-flight.outputs.in_flight == '')",
                      steps["place"]["if"])
        # The job name is what in_flight() matches.
        self.assertEqual(jobs["smoke"]["name"], "smoke ${{ needs.pick.outputs.build }}")
        self.assertEqual(smoke.smoke_job(200), "smoke 200")

    def test_a_failed_read_is_unknown_and_warns_durably(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            summary = Path(tmp) / "summary.md"
            stdout, stderr = io.StringIO(), io.StringIO()
            with mock.patch.object(smoke, "read_in_flight", side_effect=TimeoutError("API timeout")), \
                 mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_STEP_SUMMARY": str(summary)}, clear=False), \
                 contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(smoke.main(["in-flight", "--build", "200"]), 0)
            self.assertEqual(stdout.getvalue().strip(), "in_flight=unknown")
            self.assertIn("::warning", stderr.getvalue())
            self.assertIn("in-flight state unknown", summary.read_text(encoding="utf-8"))
            self.assertIn("next scheduled tick", summary.read_text(encoding="utf-8"))


class PrePublishGateTests(unittest.TestCase):
    """nightly.yml smokes the DMG it would publish before an appcast names it."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.jobs = yaml.safe_load(NIGHTLY.read_text(encoding="utf-8"))["jobs"]

    def smoke_step(self, job: str) -> tuple[list, int]:
        steps = self.jobs[job]["steps"]
        names = [step.get("name") for step in steps]
        self.assertEqual(names.count("Launch smoke from a fresh home"), 1, job)
        return steps, names.index("Launch smoke from a fresh home")

    def assert_gates(self, job: str, dmg: str) -> None:
        steps, index = self.smoke_step(job)
        step = steps[index]
        self.assertIn("scripts/ci/nightly-steps/launch-smoke-gate.sh", step["run"])
        self.assertIn(dmg, step["run"])
        # A crash fails the job: never continue-on-error, and it runs before the tested digests go up.
        self.assertNotIn("continue-on-error", step)
        self.assertLessEqual(int(step["timeout-minutes"]), 12)
        upload = [s.get("name") for s in steps].index("Upload tested DMG digests")
        self.assertLess(index, upload, f"{job}: the smoke must run before the tested digests upload")
        # The app runs only in a job without secrets or an environment.
        self.assertNotIn("environment", self.jobs[job])
        self.assertNotIn("secrets.", json.dumps(self.jobs[job]))

    def test_this_runs_build_is_smoked_before_publish(self) -> None:
        self.assert_gates("verify-final-dmg-nightly", 'final-dmg/${CHANNEL_DMG_PREFIX}-arm64.dmg')
        steps, index = self.smoke_step("verify-final-dmg-nightly")
        condition = steps[index]["if"]
        self.assertIn("env.TRACK == 'nightly-next'", condition)
        self.assertIn("matrix.variant == 'arm64'", condition)
        # The harness comes from the workflow commit, not the build's (possibly older) checkout.
        self.assertIn(".publish-tooling/scripts/ci/nightly-steps/launch-smoke-gate.sh", steps[index]["run"])
        tooling = next(i for i, s in enumerate(steps) if s.get("with", {}).get("path") == ".publish-tooling")
        self.assertEqual(steps[tooling]["with"]["ref"], "${{ github.sha }}")
        self.assertLess(tooling, index)

    def test_a_recovered_build_is_smoked_before_publish(self) -> None:
        self.assert_gates("verify-recovered-nightly-next", 'recovered/${CHANNEL_DMG_PREFIX}-arm64.dmg')

    def test_publish_needs_both_verify_jobs_to_pass(self) -> None:
        publish = self.jobs["publish-nightly"]
        self.assertIn("verify-final-dmg-nightly", publish["needs"])
        self.assertIn("verify-recovered-nightly-next", publish["needs"])
        self.assertIn("needs.verify-final-dmg-nightly.result == 'success'", publish["if"])
        self.assertIn("needs.verify-recovered-nightly-next.result == 'success'", publish["if"])


@unittest.skipUnless(shutil.which("bash") and shutil.which("perl"), "needs bash and perl")
class GateScriptTests(unittest.TestCase):
    """launch-smoke-gate.sh against a stub harness: only a crash with launch evidence fails."""

    def run_gate(self, plan: list[str], attempt_seconds: str = "60") -> tuple[int, str, Path]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ci = root / "scripts" / "ci"
            (ci / "nightly-steps").mkdir(parents=True)
            (ci / "frame-pacing").mkdir()
            (ci / "lib").mkdir()
            shutil.copy(GATE, ci / "nightly-steps" / GATE.name)
            shutil.copy(ROOT / "scripts" / "ci" / "nightly_next_launch_smoke.py", ci)
            shutil.copy(ROOT / "scripts" / "ci" / "lib" / "signing-runtime-guard.sh", ci / "lib")
            (ci / "frame-pacing" / "console-session.sh").write_text('#!/usr/bin/env bash\nexec "$@"\n')
            (ci / "frame-pacing" / "console-session.sh").chmod(0o755)
            # The stub harness: attempt N follows PLAN[N-1] (pass, crash, cannot-run or hang).
            (ci / "fresh_home_launch_smoke.py").write_text(
                "import json, os, signal, sys, time\n"
                "out = sys.argv[sys.argv.index('--out') + 1]\n"
                "n = int(out.rsplit('-', 1)[1])\n"
                "kind = os.environ['STUB_PLAN'].split(',')[n - 1]\n"
                "if kind == 'hang':\n"
                # A harness stopped by SIGTERM cleans up, and even an exit 1 with a fail report is no crash.
                "    def stop(*_):\n"
                "        open(os.path.join(out, 'cleaned'), 'w').close()\n"
                "        open(os.path.join(out, 'report.json'), 'w').write(json.dumps({'verdict': 'fail', 'pid': 1}))\n"
                "        sys.exit(1)\n"
                "    signal.signal(signal.SIGTERM, stop)\n    time.sleep(30)\n"
                "if kind == 'stubborn':\n    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n    time.sleep(30)\n"
                "report = {'pass': {'verdict': 'pass', 'pid': 1}, 'crash': {'verdict': 'fail', 'pid': 1,"
                " 'failures': ['the app exited (signal 11)']}, 'cannot-run': {'verdict': 'cannot-run'}}[kind]\n"
                "open(os.path.join(out, 'report.json'), 'w').write(json.dumps(report))\n"
                "open(os.path.join(out, 'app.log'), 'w').write('log\\n')\n"
                "sys.exit({'pass': 0, 'crash': 1, 'cannot-run': 3}[kind])\n")
            dmg = root / "app.dmg"
            dmg.write_bytes(b"dmg")
            (root / "runner").mkdir()
            env = {"PATH": os.environ["PATH"], "RUNNER_TEMP": str(root / "runner"), "STUB_PLAN": ",".join(plan),
                   "LAUNCH_SMOKE_ATTEMPT_SECONDS": attempt_seconds, "LAUNCH_SMOKE_KILL_GRACE": "1",
                   "GITHUB_STEP_SUMMARY": str(root / "summary.md")}
            result = subprocess.run(["bash", str(ci / "nightly-steps" / GATE.name), str(dmg)], env=env,
                                    capture_output=True, text=True, timeout=60)
            cleaned = (root / "runner" / "launch-smoke" / "attempt-1" / "cleaned").exists()
            return result.returncode, result.stdout + result.stderr, cleaned

    def test_a_pass_passes(self) -> None:
        self.assertEqual(self.run_gate(["pass"])[0], 0)
        self.assertEqual(self.run_gate(["crash", "pass"])[0], 0)

    def test_a_crash_on_both_attempts_holds_the_build(self) -> None:
        status, output, _ = self.run_gate(["crash", "crash"])
        self.assertEqual(status, 1, output)
        self.assertIn("not published", output)

    def test_what_could_not_run_never_holds_the_build(self) -> None:
        status, output, _ = self.run_gate(["cannot-run"])
        self.assertEqual(status, 0, output)
        self.assertIn("::warning", output)
        self.assertEqual(self.run_gate(["crash", "cannot-run"])[0], 0)

    def test_a_hung_attempt_is_stopped_with_sigterm_so_the_harness_cleans_up(self) -> None:
        status, output, cleaned = self.run_gate(["hang"], attempt_seconds="2")
        self.assertEqual(status, 0, output)
        self.assertTrue(cleaned, "the harness got SIGTERM and ran its cleanup")
        self.assertIn("still running after 2s", output)
        self.assertIn("::warning", output)

    def test_a_harness_that_ignores_sigterm_is_killed_and_never_holds_the_build(self) -> None:
        status, output, _ = self.run_gate(["stubborn"], attempt_seconds="1")
        self.assertEqual(status, 0, output)
        self.assertIn("::warning", output)

if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""The cmux NEXT post-publish launch smoke (nightly-next-launch-smoke.yml) is not a publish gate.

Leo, 2026-10-23: "we want no smoke tests. No smoke tests, okay? Or at least, like, you know,
previously we had the daemon with a smoke test literally block the entire nightly release, right?
Like, that's unacceptable." So nightly.yml publishes without waiting on the smoke, and the smoke
acts only after the fact:

  - pass does nothing; cannot-run (no Mac, an infrastructure or harness error before launch, or a
    check cut short) does nothing and never rolls back;
  - a crash on both attempts rolls the feed back through nightly-next-rollback.yml (dispatched, no
    second copy of its logic), only while the build is still the feed's newest, so a second report
    of the same build does nothing and a rollback never goes past the kept good build;
  - nothing waits on it: no nightly.yml job needs it or reads its result.
"""
from __future__ import annotations

import importlib.util
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly-next-launch-smoke.yml"
NIGHTLY = ROOT / ".github" / "workflows" / "nightly.yml"


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
        self.assertNotRegex(self.text, r"secrets\.")
        allowed = {"actions": "write", "contents": "read", "issues": "write"}
        self.assertEqual(self.workflow.get("permissions"), {})
        for name, job in self.jobs.items():
            self.assertNotIn("environment", job, name)
            for scope, level in (job.get("permissions") or {}).items():
                self.assertEqual(allowed.get(scope), level, f"{name}: {scope}: {level}")
        self.assertEqual(self.jobs["smoke"]["permissions"], {"contents": "read"})

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


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""The nightly's sign, notarize and publish jobs take a Blacksmith macOS label whose queue moves.

On 2026-10-26 vars.MACOS_RUNNER_26 named blacksmith-12vcpu-macos-26, which started
no job from about 01:20Z, and every nightly's signing jobs waited on it: the feed
went eight hours stale. scripts/ci/nightly_sign_runner.py now picks the label
right before those jobs queue, and no signing job's runs-on can resolve to the
variable alone.
"""

from __future__ import annotations

import datetime as dt
import os
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import nightly_sign_runner as picker  # noqa: E402

NOW = dt.datetime(2026, 10, 26, 9, 30, tzinfo=dt.timezone.utc)
LARGE, SMALL = "blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26"
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8"))

# The jobs that sign, notarize, verify a signed build or publish it, and the job whose
# output names their label. Each reads it first, then the variable, then 6 vCPU.
SIGNING_JOBS = {
    "build-sign-notarize-nightly": "needs.pick-nightly-sign-runner.outputs.runner",
    "verify-signed-nightly": "needs.pick-nightly-sign-runner.outputs.runner",
    "verify-final-dmg-nightly": "needs.pick-nightly-sign-runner.outputs.runner",
    "recover-nightly-next-notarization": "needs.find-nightly-next-recovery.outputs.sign_runner",
    "verify-recovered-nightly-next": "needs.find-nightly-next-recovery.outputs.sign_runner",
    "sign-nightly-identity-legacy": "needs.legacy-identity-target.outputs.sign_runner",
    "verify-nightly-identity-legacy": "needs.legacy-identity-target.outputs.sign_runner",
    # Signs the Sparkle deltas (the release environment), after the feed is published.
    "generate-nightly-deltas": "needs.pick-nightly-sign-runner.outputs.runner",
    # The release-pool path's one Mac job: Apple's checks and the DMG image, no secrets.
    "signer-dmg-image": "needs.pick-nightly-sign-runner.outputs.runner",
}
# Each picker's re-run label, the other Blacksmith macOS 26 size.
ALTERNATES = {
    "needs.pick-nightly-sign-runner.outputs.runner": "needs.pick-nightly-sign-runner.outputs.alternate",
    "needs.find-nightly-next-recovery.outputs.sign_runner": "needs.find-nightly-next-recovery.outputs.sign_alternate",
    "needs.legacy-identity-target.outputs.sign_runner": "needs.legacy-identity-target.outputs.sign_alternate",
}
# macOS jobs that still read vars.MACOS_RUNNER_26 directly: they build (no signing material)
# and have owned-pool routes of their own.
BUILD_JOBS = {"build-nightly-app", "prepare-nightly-variant-primary"}


def snapshot(waits: dict[str, int], age_minutes: int = 2) -> dict:
    generated = (NOW - dt.timedelta(minutes=age_minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"generated_at": generated,
            "pools": {label: {"queued": 1 if wait else 0, "oldest_queued_minutes": wait} for label, wait in waits.items()}}


class Pick(unittest.TestCase):
    def test_the_variable_comes_first_while_it_moves(self) -> None:
        self.assertEqual(picker.pick(LARGE, snapshot({LARGE: 3}), NOW)[0], LARGE)
        self.assertEqual(picker.pick(SMALL, snapshot({}), NOW)[0], SMALL)

    def test_a_stalled_variable_falls_back_to_a_moving_label(self) -> None:
        label, why = picker.pick(LARGE, snapshot({LARGE: 90}), NOW)
        self.assertEqual(label, SMALL)
        self.assertIn(LARGE, why)
        self.assertEqual(picker.pick(SMALL, snapshot({SMALL: 40}), NOW)[0], LARGE)

    def test_a_wait_counts_the_snapshot_age(self) -> None:
        self.assertEqual(picker.pick(LARGE, snapshot({LARGE: 5}, age_minutes=6), NOW)[0], SMALL)
        self.assertEqual(picker.pick(LARGE, snapshot({LARGE: 5}, age_minutes=1), NOW)[0], LARGE)

    def test_no_fresh_snapshot_keeps_the_variable(self) -> None:
        self.assertEqual(picker.pick(LARGE, None, NOW)[0], LARGE)
        self.assertEqual(picker.pick(LARGE, snapshot({LARGE: 90}, age_minutes=60), NOW)[0], LARGE)

    def test_a_non_blacksmith_or_empty_variable_is_never_picked(self) -> None:
        for variable in ("", "glaeda-mini", "macos-26", "blacksmith-4vcpu-ubuntu-2404"):
            with self.subTest(variable=variable):
                self.assertEqual(picker.pick(variable, None, NOW)[0], SMALL)
                self.assertNotIn(variable, picker.candidates(variable)) if variable else None

    def test_every_label_stalled_still_names_one(self) -> None:
        self.assertEqual(picker.pick(LARGE, snapshot({LARGE: 90, SMALL: 90}), NOW)[0], SMALL)

    def test_the_alternate_is_the_other_size_and_prefers_a_moving_one(self) -> None:
        # Run 40489472569 (2026-10-27): both 26 sizes were stalled at the pick, so 6 vCPU won;
        # a re-run of its signing jobs must not queue on 6 vCPU again.
        for variable in ("", SMALL, LARGE, "glaeda-mini"):
            for waits in ({}, {SMALL: 90}, {LARGE: 90}, {SMALL: 90, LARGE: 90}):
                with self.subTest(variable=variable, waits=waits):
                    snap = snapshot(waits)
                    label = picker.pick(variable, snap, NOW)[0]
                    other = picker.alternate(variable, label, snap, NOW)
                    self.assertIn(other, (SMALL, LARGE))
                    stalled_others = {SMALL, LARGE} - {label} <= set(waits)
                    self.assertEqual(other == label, stalled_others)
        self.assertEqual(picker.alternate(LARGE, LARGE, None, NOW), SMALL)

    def test_a_stalled_alternate_is_never_offered(self) -> None:
        # Both sizes stalled at the pick: a re-run of failed jobs keeps the pick instead of
        # moving to a size the snapshot already saw stalled (12 vCPU, 2026-10-27 13:01Z on).
        snap = snapshot({SMALL: 90, LARGE: 90})
        self.assertEqual(picker.alternate("", SMALL, snap, NOW), SMALL)
        self.assertEqual(picker.alternate("", SMALL, snapshot({LARGE: 90}), NOW), SMALL)
        self.assertEqual(picker.alternate("", SMALL, snapshot({SMALL: 90}), NOW), LARGE)

    def test_a_failed_jobs_rerun_reads_attempt_ones_alternate(self) -> None:
        # Attempt 1's picker writes the other size; a re-run of failed jobs keeps that output.
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            env = {"CANDIDATE": "", "SNAPSHOT_TOKEN": "t", "GITHUB_REPOSITORY": "o/r",
                   "GITHUB_OUTPUT": str(output), "GITHUB_RUN_ATTEMPT": "1"}
            self.assertEqual(picker.main(env, read=lambda t, r: snapshot({SMALL: 3}), now=NOW), 0)
            self.assertEqual(output.read_text(), f"runner={SMALL}\nalternate={LARGE}\n")

    def test_a_pick_made_on_a_rerun_is_its_own_alternate(self) -> None:
        # A full re-run runs the picker again; its fresh pick must win over the other size.
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            env = {"CANDIDATE": "", "SNAPSHOT_TOKEN": "t", "GITHUB_REPOSITORY": "o/r",
                   "GITHUB_OUTPUT": str(output), "GITHUB_RUN_ATTEMPT": "2"}
            self.assertEqual(picker.main(env, read=lambda t, r: snapshot({LARGE: 90}), now=NOW), 0)
            self.assertEqual(output.read_text(), f"runner={SMALL}\nalternate={SMALL}\n")

    def test_main_writes_the_output_and_never_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            env = {"CANDIDATE": LARGE, "SNAPSHOT_TOKEN": "t", "GITHUB_REPOSITORY": "o/r", "GITHUB_OUTPUT": str(output)}

            def broken(token: str, repo: str) -> dict:
                raise OSError("rate limit")
            self.assertEqual(picker.main(env, read=broken, now=NOW), 0)
            self.assertEqual(output.read_text(), f"runner={LARGE}\nalternate={SMALL}\n")
            output.write_text("")
            self.assertEqual(picker.main(env, read=lambda t, r: snapshot({LARGE: 90}), now=NOW), 0)
            # 12 vCPU is stalled, so a re-run keeps 6 vCPU rather than moving onto it.
            self.assertEqual(output.read_text(), f"runner={SMALL}\nalternate={SMALL}\n")


class Workflow(unittest.TestCase):
    def test_signing_jobs_read_the_picked_label_first(self) -> None:
        jobs = WORKFLOW["jobs"]
        for name, picked in SIGNING_JOBS.items():
            with self.subTest(job=name):
                runs_on = str(jobs[name]["runs-on"])
                self.assertIn(f"|| {picked} || vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26'", runs_on)
                # A re-run (attempt 2 on) takes the other size: GitHub never re-routes a queued job,
                # so a label that stalls after the pick is left only by a re-run, which must not
                # queue on it again (run 40489472569, 2026-10-27).
                self.assertIn(f"|| github.run_attempt > 1 && {ALTERNATES[picked]} || {picked} ||", runs_on)
                needs = jobs[name]["needs"]
                self.assertIn(picked.split(".")[1], [needs] if isinstance(needs, str) else needs)

    def test_no_other_macos_job_resolves_to_the_variable_alone(self) -> None:
        reads = {name for name, job in WORKFLOW["jobs"].items() if "vars.MACOS_RUNNER_26" in str(job.get("runs-on", ""))}
        self.assertEqual(reads - set(SIGNING_JOBS) - BUILD_JOBS, set(),
                         "a new macOS job reads vars.MACOS_RUNNER_26 for its route: give it a picked label "
                         "(scripts/ci/nightly_sign_runner.py) or add it to BUILD_JOBS if it signs nothing")
        for name in BUILD_JOBS & reads:
            with self.subTest(job=name):
                self.assertNotIn("environment", WORKFLOW["jobs"][name].get("environment", "") or "")

    def test_the_pickers_run_the_step_and_publish_its_output(self) -> None:
        jobs = WORKFLOW["jobs"]
        for job, output in (("pick-nightly-sign-runner", "runner"), ("find-nightly-next-recovery", "sign_runner"),
                            ("legacy-identity-target", "sign_runner")):
            with self.subTest(job=job):
                step = next(s for s in jobs[job]["steps"] if s.get("id") == "sign-runner")
                self.assertTrue(step["continue-on-error"])
                # The picker job checks out only the publication tooling (tests/test_nightly_cmux_tui_resolve.py).
                tooling = ".publish-tooling/" if job == "pick-nightly-sign-runner" else ""
                self.assertEqual(step["run"].strip(), f"python3 {tooling}scripts/ci/nightly_sign_runner.py")
                self.assertEqual(step["env"]["CANDIDATE"], "${{ vars.MACOS_RUNNER_26 }}")
                self.assertEqual(jobs[job]["outputs"][output], "${{ steps.sign-runner.outputs.runner }}")
                alternate = "alternate" if output == "runner" else "sign_alternate"
                self.assertEqual(jobs[job]["outputs"][alternate], "${{ steps.sign-runner.outputs.alternate }}")
                # legacy-identity-target takes release-next only for the release App credentials of its
                # gh calls (tests/test_gh_app_token.py); that environment has no reviewers, so nothing waits.
                # pick-nightly-sign-runner mints the routing token, so it reads GLAEDA_ROUTE_APP_KEY in
                # ci-routing-agent, as pick-nightly-build-runner does (tests/test_supplychain_security.py).
                expected = {"legacy-identity-target": "release-next", "pick-nightly-sign-runner": "ci-routing-agent"}
                self.assertEqual(jobs[job].get("environment"), expected.get(job))
        self.assertEqual(jobs["pick-nightly-sign-runner"]["permissions"], {"actions": "read", "contents": "read"})
        # A failed pick never blocks signing: the jobs fall back to the variable.
        self.assertTrue(jobs["pick-nightly-sign-runner"]["continue-on-error"])


class OwnedVerify(unittest.TestCase):
    """The secret-free verify jobs take a free owned Mac first, Blacksmith last (2026-10-26).

    nightly-next runs 40396929672 and 40403525126 waited over an hour on blacksmith-6vcpu-macos-26
    behind pull request compiles. The routing order is Linux, owned Macs, then Blacksmith last
    (Leo, 2026-10-24); the signing jobs, which hold the keys, stay on Blacksmith.
    """

    OWNED_JOBS = ("verify-signed-nightly", "verify-final-dmg-nightly", "signer-dmg-image")
    # The cmux NIGHTLY-identity verify, also secret-free, keeps its own picker's Blacksmith labels after
    # the owned pick: on 2026-10-28 it queued 20+ min on blacksmith-6vcpu-macos-26 while 12 vCPU was stalled.
    LEGACY_OWNED_JOBS = ("verify-nightly-identity-legacy",)
    OWNED = "needs.pick-nightly-sign-runner.outputs.owned"

    def test_verify_jobs_read_the_owned_pick_only_for_the_attempt_it_was_made_for(self) -> None:
        # Dispatch run 40594111618 (2026-10-27) reached signing on attempt 3, where signer-dmg-image waited
        # 51 min on blacksmith-6vcpu-macos-26: the pick ran only on attempt 1 of a push.
        jobs = WORKFLOW["jobs"]
        for name in self.OWNED_JOBS:
            with self.subTest(job=name):
                job = jobs[name]
                self.assertNotIn("environment", job)
                self.assertNotIn("secrets.", yaml.safe_dump(job))
                self.assertIn(f"|| needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && {self.OWNED} "
                              "|| github.run_attempt > 1 && "
                              "needs.pick-nightly-sign-runner.outputs.alternate || needs.pick-nightly-sign-runner.outputs.runner "
                              "|| vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26'", str(job["runs-on"]))
                xcode = job["env"]["CMUX_CI_XCODE_APP"]
                self.assertIn(f"needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && {self.OWNED} != '' "
                              "&& vars.CMUX_CI_XCODE_APP_PR", xcode)
                self.assertIn("|| vars.CMUX_CI_XCODE_APP_MACOS_26", xcode)

    def test_the_legacy_verify_reads_the_owned_pick_then_its_own_labels(self) -> None:
        jobs = WORKFLOW["jobs"]
        for name in self.LEGACY_OWNED_JOBS:
            with self.subTest(job=name):
                job = jobs[name]
                self.assertNotIn("environment", job)
                self.assertNotIn("secrets.", yaml.safe_dump(job))
                self.assertIn("pick-nightly-sign-runner", job["needs"])
                # A skipped or failed pick must not skip the verify.
                self.assertTrue(job["if"].startswith("!cancelled()"))
                self.assertIn(f"|| needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && {self.OWNED} "
                              "|| github.run_attempt > 1 && needs.legacy-identity-target.outputs.sign_alternate "
                              "|| needs.legacy-identity-target.outputs.sign_runner "
                              "|| vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26'", str(job["runs-on"]))
                xcode = job["env"]["CMUX_CI_XCODE_APP"]
                self.assertIn(f"needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && {self.OWNED} != '' "
                              "&& vars.CMUX_CI_XCODE_APP_PR", xcode)
                self.assertIn("|| vars.CMUX_CI_XCODE_APP_MACOS_26", xcode)

    def test_no_job_that_holds_a_secret_reads_the_owned_pick(self) -> None:
        for name, job in WORKFLOW["jobs"].items():
            if self.OWNED not in str(job.get("runs-on", "")):
                continue
            with self.subTest(job=name):
                self.assertIn(name, self.OWNED_JOBS + self.LEGACY_OWNED_JOBS)
                self.assertFalse(job.get("environment"))
                self.assertNotIn("secrets.", yaml.safe_dump(job))

    def test_the_owned_pick_is_bounded_and_never_blocks(self) -> None:
        job = WORKFLOW["jobs"]["pick-nightly-sign-runner"]
        # Outside attempt 1 of a push the pick stands only with the sweeper's marker uploaded.
        self.assertEqual(job["outputs"]["owned"],
                         "${{ (github.event_name == 'push' && github.run_attempt == 1 || "
                         "steps.upload-marker.outcome == 'success') && steps.owned.outputs.owned || '' }}")
        self.assertEqual(job["outputs"]["attempt"], "${{ github.run_attempt }}")
        # The routing environment only scopes the routing App key; it has no reviewers, so nothing waits.
        self.assertEqual(job.get("environment"), "ci-routing-agent")
        step = next(s for s in job["steps"] if s.get("id") == "owned")
        self.assertTrue(step["continue-on-error"])
        self.assertNotIn("github.run_attempt == 1", step["if"])
        self.assertIn("vars.CI_PR_POOL_OWNED == '1'", step["if"])
        # Only where ci-owned-pool-rescue watches (nightly-next push and dispatch): a stuck owned job elsewhere
        # would never fall back.
        for name in ("route-token", "owned"):
            guard = next(s for s in job["steps"] if s.get("id") == name)["if"]
            with self.subTest(step=name):
                self.assertIn("(github.event_name == 'push' || github.event_name == 'workflow_dispatch') "
                              "&& github.ref_name == 'nightly-next'", guard)
                self.assertEqual(guard.count("||"), 1)
        marker = next(s for s in job["steps"] if s.get("id") == "marker")
        self.assertIn("github.event_name != 'push' || github.run_attempt != 1", marker["if"])
        upload = next(s for s in job["steps"] if s.get("id") == "upload-marker")
        self.assertEqual(upload["with"]["name"], "owned-pool-watch")
        # The build picker's owned rule (nightly_build_runner.py verify), over the labels it offers the build,
        # not the pull request pool picker: run 40515681971's verify got blacksmith-6vcpu-macos-15 from that one
        # while owned side runners sat idle.
        self.assertEqual(step["run"].strip(), "python3 .publish-tooling/scripts/ci/nightly_build_runner.py verify")
        self.assertNotIn("e2e_runner_pool.py", yaml.safe_dump(job))
        self.assertEqual(step["env"]["OWNED_LABELS"],
                         "${{ format('{0} {1}', vars.CI_NIGHTLY_NEXT_BUILD_RUNNER, vars.CI_SIDE_LANE_RUNNER) }}")
        self.assertEqual(step["env"]["CANDIDATE"], "${{ vars.MACOS_RUNNER_26 }}")
        self.assertNotIn("DEDICATED_LABEL", step["env"])
        # The job outlives its step budgets, and the Blacksmith pick comes first: a slow App API
        # never cancels the job before `runner` is written (a cancelled pick skips signing).
        ids = [s.get("id") for s in job["steps"]]
        self.assertLess(ids.index("sign-runner"), ids.index("route-token"))
        budget = sum(int(s.get("timeout-minutes", 0)) for s in job["steps"])
        self.assertTrue(all("timeout-minutes" in s for s in job["steps"] if s.get("id")))
        self.assertGreaterEqual(int(job["timeout-minutes"]), budget + 2)

if __name__ == "__main__":
    unittest.main()

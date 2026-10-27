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

    def test_main_writes_the_output_and_never_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            env = {"CANDIDATE": LARGE, "SNAPSHOT_TOKEN": "t", "GITHUB_REPOSITORY": "o/r", "GITHUB_OUTPUT": str(output)}

            def broken(token: str, repo: str) -> dict:
                raise OSError("rate limit")
            self.assertEqual(picker.main(env, read=broken, now=NOW), 0)
            self.assertEqual(output.read_text(), f"runner={LARGE}\n")
            output.write_text("")
            self.assertEqual(picker.main(env, read=lambda t, r: snapshot({LARGE: 90}), now=NOW), 0)
            self.assertEqual(output.read_text(), f"runner={SMALL}\n")


class Workflow(unittest.TestCase):
    def test_signing_jobs_read_the_picked_label_first(self) -> None:
        jobs = WORKFLOW["jobs"]
        for name, picked in SIGNING_JOBS.items():
            with self.subTest(job=name):
                runs_on = str(jobs[name]["runs-on"])
                self.assertIn(f"|| {picked} || vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26'", runs_on)
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
                # legacy-identity-target takes release-next only for the release App credentials of its
                # gh calls (tests/test_gh_app_token.py); that environment has no reviewers, so nothing waits.
                self.assertEqual(jobs[job].get("environment"), "release-next" if job == "legacy-identity-target" else None)
        self.assertEqual(jobs["pick-nightly-sign-runner"]["permissions"], {"actions": "read", "contents": "read"})
        # A failed pick never blocks signing: the jobs fall back to the variable.
        self.assertTrue(jobs["pick-nightly-sign-runner"]["continue-on-error"])


class OwnedVerify(unittest.TestCase):
    """The secret-free verify jobs take a free owned Mac first, Blacksmith last (2026-10-26).

    nightly-next runs 40396929672 and 40403525126 waited over an hour on blacksmith-6vcpu-macos-26
    behind pull request compiles. The routing order is Linux, owned Macs, then Blacksmith last
    (Leo, 2026-10-24); the signing jobs, which hold the keys, stay on Blacksmith.
    """

    OWNED_JOBS = ("verify-signed-nightly", "verify-final-dmg-nightly")
    OWNED = "needs.pick-nightly-sign-runner.outputs.owned"

    def test_verify_jobs_read_the_owned_pick_on_attempt_one_only(self) -> None:
        jobs = WORKFLOW["jobs"]
        for name in self.OWNED_JOBS:
            with self.subTest(job=name):
                job = jobs[name]
                self.assertNotIn("environment", job)
                self.assertNotIn("secrets.", yaml.safe_dump(job))
                self.assertIn(f"|| github.run_attempt == 1 && {self.OWNED} || needs.pick-nightly-sign-runner.outputs.runner "
                              "|| vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26'", str(job["runs-on"]))
                xcode = job["env"]["CMUX_CI_XCODE_APP"]
                self.assertIn(f"github.run_attempt == 1 && {self.OWNED} != '' && vars.CMUX_CI_XCODE_APP_PR", xcode)
                self.assertIn("|| vars.CMUX_CI_XCODE_APP_MACOS_26", xcode)

    def test_no_job_that_holds_a_secret_reads_the_owned_pick(self) -> None:
        for name, job in WORKFLOW["jobs"].items():
            if self.OWNED not in str(job.get("runs-on", "")):
                continue
            with self.subTest(job=name):
                self.assertIn(name, self.OWNED_JOBS)
                self.assertFalse(job.get("environment"))
                self.assertNotIn("secrets.", yaml.safe_dump(job))

    def test_the_owned_pick_is_bounded_and_never_blocks(self) -> None:
        job = WORKFLOW["jobs"]["pick-nightly-sign-runner"]
        self.assertEqual(job["outputs"]["owned"], "${{ steps.owned.outputs.label }}")
        self.assertNotIn("environment", job)
        step = next(s for s in job["steps"] if s.get("id") == "owned")
        self.assertTrue(step["continue-on-error"])
        self.assertIn("github.run_attempt == 1", step["if"])
        self.assertIn("vars.CI_PR_POOL_OWNED == '1'", step["if"])
        # Only where ci-owned-pool-rescue watches: a stuck owned job elsewhere would never fall back.
        for name in ("route-token", "owned"):
            guard = next(s for s in job["steps"] if s.get("id") == name)["if"]
            with self.subTest(step=name):
                self.assertIn("github.event_name == 'push' && github.ref_name == 'nightly-next'", guard)
                self.assertIn("startsWith(vars.CI_NIGHTLY_NEXT_TRUSTED_POOL, 'glaeda-trusted-')", guard)
                self.assertIn("startsWith(vars.CI_NIGHTLY_NEXT_TRUSTED_RUNNER, 'glaeda-runner-')", guard)
                self.assertNotIn("||", guard)
        self.assertIn("e2e_runner_pool.py", step["run"])
        # The job outlives its step budgets, and the Blacksmith pick comes first: a slow App API
        # never cancels the job before `runner` is written (a cancelled pick skips signing).
        ids = [s.get("id") for s in job["steps"]]
        self.assertLess(ids.index("sign-runner"), ids.index("route-token"))
        budget = sum(int(s.get("timeout-minutes", 0)) for s in job["steps"])
        self.assertTrue(all("timeout-minutes" in s for s in job["steps"] if s.get("id")))
        self.assertGreaterEqual(int(job["timeout-minutes"]), budget + 2)
        # Only an owned label is ever offered; anything else leaves the Blacksmith pick.
        self.assertIn('glaeda-*)', step["run"])
        self.assertIn('label=""', step["run"])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Every runs-on that reads vars.CI_SIDE_LANE_RUNNER takes vars.CI_SIDE_LANE_LABELS first.

Leo, 2026-11-16: "the roles/labels need to be modernized to what they actually are hiwhc is just genearl
blobs of compute". A side-lane job used to ask for one pool label (glaeda-side-std-xcode-26.6), so it could
land only on the hosts that pool's class names. CI_SIDE_LANE_LABELS is the same requirement as what the job
needs: a JSON label array, one side pool label and the capability tiers
(scripts/ci/runner_label_policy.py side_lane_labels_reason). GitHub gives the job any runner carrying every
label in it.

The readers take it as `(vars.CI_SIDE_LANE_LABELS != '' && fromJSON(vars.CI_SIDE_LANE_LABELS) ||
vars.CI_SIDE_LANE_RUNNER)`: unset, each route is the single label it was. This is main's copy of
feat-cmux-next's test (cmux#45244). This test fails when:

- a job's runs-on reads vars.CI_SIDE_LANE_RUNNER without that wrapper (a single-label reader), unless its job
  is in ENV_COPY (its env copies the route as one label for its scripts). Nightly workflows (nightly*.yml)
  are left out: their routing does not change here;
- the policy accepts an array no runner can carry (two pools, a host label, an unknown tier).
"""
from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import runner_label_policy as policy  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
READ = "vars.CI_SIDE_LANE_RUNNER"
WRAPPED = ("(vars.CI_SIDE_LANE_LABELS != '' && fromJSON(vars.CI_SIDE_LANE_LABELS) || "
           "vars.CI_SIDE_LANE_RUNNER)")
# A read in value position: the label the route picks. A read as a function argument or either side of a
# comparison is a condition (startsWith(vars.CI_SIDE_LANE_RUNNER, 'glaeda-side-'), X != vars.CI_SIDE_LANE_RUNNER)
# and stays a string.
BARE_READ = re.compile(r"(?<![\w.(])(?<!!= )(?<!== )vars\.CI_SIDE_LANE_RUNNER(?!\w)(?! *(?:==|!=|,))")
# Jobs that keep the single label for now, each because its own env copies the route as one label string,
# which the job's scripts read as a runner label (an array would reach them as JSON text). Each leaves when
# that copy reads the array too; an entry whose copy is gone fails, so the list only shrinks.
ENV_COPY = {
    "iroh-v2.yml#client": "REQUESTED_RUNNER",
}
# Arrays the variable may hold: what a std side job needs today (any side runner with Xcode 26.6; every one
# has at least 16 GiB, the measured std footprint), and a job that needs a 48 GiB host.
ARRAYS = (
    ["glaeda-side-xcode-26.6", "glaeda-ram-16"],
    ["glaeda-side-xcode-26.6", "glaeda-ram-48", "glaeda-cores-12"],
    ["glaeda-side-std-xcode-26.6", "glaeda-ram-48"],
)


def side_lane_routes() -> list[tuple[str, str, dict]]:
    """(workflow#job, runs-on, job) for every non-nightly job whose runs-on reads the side-lane variable."""
    routes = []
    for path in sorted(WORKFLOWS.glob("*.yml")):
        if path.name.startswith("nightly"):
            continue
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for job_id, job in (doc.get("jobs") or {}).items():
            runs_on = job.get("runs-on") if isinstance(job, dict) else None
            runs_on = runs_on if isinstance(runs_on, str) else json.dumps(runs_on)
            if READ in runs_on:
                routes.append((f"{path.name}#{job_id}", runs_on, job))
    return routes


def env_copies(job: dict) -> set[str]:
    """The env names in a job (its own env or a step's) whose value reads the side-lane variable."""
    envs = [job.get("env") or {}] + [step.get("env") or {} for step in job.get("steps") or []]
    return {name for env in envs for name, value in env.items() if isinstance(value, str) and READ in value}


class SideLaneCapabilityLabelsTests(unittest.TestCase):
    def test_no_runs_on_reads_the_single_side_label_alone(self) -> None:
        routes = side_lane_routes()
        self.assertGreater(len(routes), 10)
        bare = [key for key, runs_on, _ in routes
                if key not in ENV_COPY and BARE_READ.search(runs_on.replace(WRAPPED, ""))]
        self.assertEqual(bare, [], f"read vars.CI_SIDE_LANE_RUNNER as {WRAPPED}")
        jobs = {key: job for key, _, job in routes}
        for key, name in ENV_COPY.items():
            with self.subTest(env_copy=key):
                self.assertIn(key, jobs, "the job no longer reads the side lane; drop its ENV_COPY entry")
                self.assertIn(name, env_copies(jobs[key]), "its env no longer copies the route; wrap its runs-on")

    def test_the_policy_accepts_the_arrays_the_variable_may_hold(self) -> None:
        for array in ARRAYS:
            value = json.dumps(array)
            self.assertIsNone(policy.side_lane_labels_reason(value), value)

    def test_the_policy_refuses_an_array_no_runner_carries(self) -> None:
        for value, why in (
            ('["glaeda-ram-48"]', "exactly one side pool"),
            ('["glaeda-side-xcode-26.6", "glaeda-side-std-xcode-26.6"]', "exactly one side pool"),
            ('["glaeda-aws-side-std-xcode-26.6", "glaeda-ram-48"]', "exactly one side pool"),
            ('["glaeda-side-xcode-26.6", "glaeda-aws-side-std-xcode-26.6"]', "not a capability label"),
            ('["glaeda-side-xcode-26.6", "glaeda-runner-cmux16-glaeda"]', "not a capability label"),
            ('["glaeda-side-xcode-26.6", "glaeda-ram-32"]', "not a capability label"),
            ('["glaeda-side-xcode-26.6", "glaeda-ram-16", "glaeda-ram-16"]', "twice"),
            ('"glaeda-side-xcode-26.6"', "JSON array"),
            ("[]", "JSON array"),
            ("glaeda-side-xcode-26.6", "valid JSON"),
        ):
            with self.subTest(value=value):
                self.assertIn(why, policy.side_lane_labels_reason(value) or "")
        self.assertIsNone(policy.side_lane_labels_reason(""))
        drifted = policy.drifted_runner_variables({"CI_SIDE_LANE_LABELS": '["glaeda-ram-48"]'})
        self.assertEqual([name for name, _, _ in drifted], ["CI_SIDE_LANE_LABELS"])

    def test_the_repository_variable_checks_read_the_array(self) -> None:
        for name in ("ci-repo-variables.yml", "ci-health-report.yml"):
            text = (WORKFLOWS / name).read_text(encoding="utf-8")
            self.assertIn("CI_SIDE_LANE_LABELS=${{ vars.CI_SIDE_LANE_LABELS }}", text, name)


if __name__ == "__main__":
    unittest.main()

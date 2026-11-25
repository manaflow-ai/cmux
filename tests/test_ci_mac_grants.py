#!/usr/bin/env python3
"""The Mac grant switch (CI v2 step 9, cmuxterm-hq#16502).

With scripts/ci/mac-grants.json on, every same-repository Mac pull request job asks for
`cmux-mac` (plus `xcode-<version>`); off, every route is what it was.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import mac_grants  # noqa: E402
import owned_pool_rescue  # noqa: E402
import simple_pool_picker as picker  # noqa: E402
import starved_labels  # noqa: E402
from test_seed_derived_data import evaluate, github_context, load  # noqa: E402

REPO = "manaflow-ai/cmux"
PR_ENV = {"EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": REPO, "GITHUB_REPOSITORY_OWNER": "manaflow-ai",
          "HEAD_REPO": REPO, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2"}
GRANT = '["cmux-mac","xcode-26.6"]'

# Every Mac pull request job the switch moves, and the expression it reads the grant from.
PICKER_TERM = "github.event_name == 'pull_request' && inputs.pr_grant != '' && fromJSON(inputs.pr_grant) || "
GRANTED_JOBS = {
    ("ci.yml", "claude-wrapper"): ("github.event_name == 'pull_request' && needs.changes.outputs.macos_pr_grant != '' "
                                   "&& fromJSON(needs.changes.outputs.macos_pr_grant) || "),
    ("remote-daemon.yml", "remote-daemon-macos-tests"): PICKER_TERM,
    **{("ci-macos.yml", job): PICKER_TERM for job in (
        "macos-compile-admission", "app-host-unit-tests", "cli-product-tests", "cli-regressions",
        "tests-build-and-lag", "release-build")},
    ("ci-macos.yml", "swift-package-tests"): (
        "github.event_name == 'pull_request' && !(inputs.full_suite == 'true' && inputs.release_build == 'true') "
        "&& inputs.pr_grant != '' && fromJSON(inputs.pr_grant) || "),
}


def switch(on: object) -> Path:
    handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump({"on": on}, handle)
    handle.close()
    return Path(handle.name)


class Switch(unittest.TestCase):
    def test_the_committed_switch_is_off(self):
        self.assertIs(json.loads((ROOT / "scripts/ci/mac-grants.json").read_text())["on"], False)
        self.assertFalse(mac_grants.switch_on())
        self.assertEqual(mac_grants.grant_labels(PR_ENV, ["glaeda-std-xcode-26.6"]), "")

    def test_only_a_literal_true_turns_it_on(self):
        self.assertTrue(mac_grants.switch_on(switch(True)))
        for value in (False, "true", 1, None):
            with self.subTest(value=value):
                self.assertFalse(mac_grants.switch_on(switch(value)))
        broken = Path(tempfile.mkdtemp()) / "broken.json"
        broken.write_text("{on: true")
        self.assertFalse(mac_grants.switch_on(broken))
        self.assertFalse(mac_grants.switch_on(Path(tempfile.mkdtemp()) / "missing.json"))

    def test_on_a_same_repository_pull_request_gets_the_label_and_its_xcode(self):
        on = switch(True)
        self.assertEqual(mac_grants.grant_labels(PR_ENV, ["glaeda-std-xcode-26.6"], path=on), GRANT)
        self.assertEqual(mac_grants.grant_labels(PR_ENV, ["/Applications/Xcode_26.6.app"], path=on), GRANT)
        self.assertEqual(mac_grants.grant_labels(PR_ENV, ['["glaeda-side","glaeda-side-xcode-26.6"]'], path=on),
                         GRANT)
        self.assertEqual(mac_grants.grant_labels(PR_ENV, ["", None, "glaeda-std-xcode-26.6"], path=on), GRANT)
        self.assertEqual(mac_grants.grant_labels(PR_ENV, ["glaeda-std"], path=on), '["cmux-mac"]')
        self.assertTrue(mac_grants.is_grant_label("cmux-123-2-mac"))
        self.assertFalse(mac_grants.is_grant_label("cmux-linux"))
        self.assertEqual(mac_grants.grant_label(123, 2), "cmux-123-2-mac")

    def test_forks_other_events_and_other_owners_get_no_grant(self):
        on = switch(True)
        for change in ({"HEAD_REPO": "someone/cmux"}, {"EVENT_NAME": "push"}, {"EVENT_NAME": "schedule"},
                       {"EVENT_NAME": "workflow_dispatch"}, {"EVENT_NAME": "merge_group"},
                       {"GITHUB_REPOSITORY": "someone/cmux", "GITHUB_REPOSITORY_OWNER": "someone",
                        "HEAD_REPO": "someone/cmux"},
                       {"GITHUB_RUN_ID": ""}):
            with self.subTest(change=change):
                self.assertEqual(mac_grants.grant_labels({**PR_ENV, **change}, ["glaeda-std-xcode-26.6"], path=on), "")


class Picker(unittest.TestCase):
    ENV = {**PR_ENV, "GH_REPO": REPO, "RUN_JOBS": "3", "CMUX_CI_XCODE_APP_PR": "/Applications/Xcode_26.6.app"}

    def run_picker(self, path: Path) -> tuple[dict[str, str], bool]:
        out = Path(tempfile.mkdtemp()) / "out"
        observed = []
        state = picker.State(jobs=3)
        with mock.patch.object(mac_grants, "SWITCH_FILE", path), \
                mock.patch.object(picker, "observe", lambda **kwargs: observed.append(kwargs) or state), \
                mock.patch("sys.stdout"), mock.patch("sys.stderr"):
            picker.main([], {**self.ENV, "GITHUB_OUTPUT": str(out)})
        return dict(line.split("=", 1) for line in out.read_text().splitlines()), bool(observed)

    def test_on_the_picker_grants_and_picks_no_pool(self):
        outputs, observed = self.run_picker(switch(True))
        self.assertFalse(observed, "a granted run reads no runner list")
        self.assertEqual(outputs["grant"], GRANT)
        self.assertEqual((outputs["persistent"], outputs["placed"], outputs["jobs"]), ("false", "0", "3"))
        self.assertEqual(outputs["xcode_app"], "/Applications/Xcode_26.6.app")
        for key in ("runner", "retry_runner", "shard_runner", "owned_jobs", "root_runner", "side_runner",
                    "light_side_runner", "light_side_jobs", "gui_runner", "admission_runner", "admission_route",
                    "admission_warm"):
            self.assertEqual(outputs[key], "", key)

    def test_off_the_outputs_are_the_pick_they_were(self):
        off, observed = self.run_picker(switch(False))
        self.assertTrue(observed)
        self.assertNotIn("grant", off)
        missing, _ = self.run_picker(Path(tempfile.mkdtemp()) / "missing.json")
        self.assertEqual(off, missing)
        # The same outputs write_outputs gives the pick without any switch code.
        with mock.patch("sys.stdout"):
            expected = picker.write_outputs(picker.pick(picker.State(jobs=3)), 3,
                                            str(Path(tempfile.mkdtemp()) / "x"), self.ENV)
        self.assertEqual(off, {key: str(value) for key, value in expected.items()})

    def test_on_a_fork_head_still_picks(self):
        out = Path(tempfile.mkdtemp()) / "out"
        observed = []
        with mock.patch.object(mac_grants, "SWITCH_FILE", switch(True)), \
                mock.patch.object(picker, "observe", lambda **kwargs: observed.append(kwargs) or picker.State(jobs=3)), \
                mock.patch("sys.stdout"), mock.patch("sys.stderr"):
            picker.main([], {**self.ENV, "HEAD_REPO": "someone/cmux", "GITHUB_OUTPUT": str(out)})
        self.assertTrue(observed)
        self.assertNotIn("grant=", out.read_text())


class Workflows(unittest.TestCase):
    def context(self, event: str, head: str, grant: str, attempt: str = "1") -> dict:
        context = github_context(event, ref="refs/pull/1/merge", CI_PR_POOL_OWNED="1",
                                 CI_SIDE_LANE_RUNNER="glaeda-side-xcode-26.6",
                                 CI_LIGHT_LANE_RUNNER="glaeda-side-light-xcode-26.6")
        context["github"].update(repository=REPO, run_attempt=attempt, triggering_actor="someone",
                                 event={"pull_request": {"head": {"repo": {"full_name": head}}}})
        context["inputs"].update(pr_grant=grant, pr_runner="glaeda-std-xcode-26.6",
                                 pr_side_runner="glaeda-side-xcode-26.6", pr_owned_jobs="",
                                 full_suite="false", release_build="false")
        context["needs"] = {"changes": {"outputs": {"macos_pr_grant": grant, "owned_head_repos": f'["{REPO}"]',"macos_pr_runner": "glaeda-std-xcode-26.6",
                                                    "macos_pr_side_runner": "glaeda-side-xcode-26.6"}},
                            "late-placement": {"outputs": {}}, "admission-placement": {"outputs": {}},
                            "macos-compile-admission": {"outputs": {"runner": "glaeda-std-xcode-26.6"}},
                            "resolve-ref": {"outputs": {"trusted_ref": "true"}}}
        return context

    def test_every_mac_pull_request_job_reads_the_grant_after_its_fork_branch(self):
        for (workflow, name), term in GRANTED_JOBS.items():
            with self.subTest(workflow=workflow, job=name):
                job = load(workflow)["jobs"][name]
                runs_on = job["runs-on"]
                self.assertEqual(runs_on.count(term), 1)
                fork = "github.event.pull_request.head.repo.full_name != github.repository"
                if fork in runs_on:
                    self.assertLess(runs_on.index(fork), runs_on.index(term))

    def test_on_a_same_repository_pull_request_takes_the_grant_and_nothing_else_does(self):
        for (workflow, name) in GRANTED_JOBS:
            runs_on = load(workflow)["jobs"][name]["runs-on"]
            runs_on = (runs_on.replace("format(' shard-{0} ', matrix.shard)", "' shard-1 '")
                       .replace("format('shard-{0}', matrix.shard)", "'shard-1'")
                       .replace("format(' cli-regressions-{0} ', matrix.shard)", "' cli-regressions-1 '")
                       .replace("format('cli-regressions-{0}', matrix.shard)", "'cli-regressions-1'"))
            with self.subTest(workflow=workflow, job=name):
                self.assertEqual(evaluate(runs_on, self.context("pull_request", REPO, GRANT)), json.loads(GRANT))
                # Neither producer grants a fork; a job with its own fork branch keeps it even if one did.
                fork_first = "github.event.pull_request.head.repo.full_name != github.repository" in runs_on
                for event, head in (("pull_request", "someone/cmux"), ("push", REPO), ("schedule", REPO)):
                    leaked = GRANT if event == "pull_request" and fork_first else ""
                    label = evaluate(runs_on, self.context(event, head, leaked))
                    self.assertNotEqual(label, json.loads(GRANT), (event, head))
                # Off: the same expression with no grant routes as it did.
                off = evaluate(runs_on, self.context("pull_request", REPO, ""))
                self.assertNotEqual(off, json.loads(GRANT))
                self.assertTrue(off)

    def test_the_full_suite_release_package_lane_keeps_blacksmith(self):
        runs_on = load("ci-macos.yml")["jobs"]["swift-package-tests"]["runs-on"]
        context = self.context("pull_request", REPO, GRANT)
        context["inputs"].update(full_suite="true", release_build="true")
        self.assertNotEqual(evaluate(runs_on, context), json.loads(GRANT))

    def test_placement_jobs_stand_down_when_granted(self):
        jobs = load("ci-macos.yml")["jobs"]
        # admission-placement needs a glaeda root, and a grant leaves pr_root_runner "".
        self.assertIn("startsWith(inputs.pr_root_runner, 'glaeda-root-')", jobs["admission-placement"]["if"])
        # Job conditions stay free of pr_grant: test_ci_gate_absent_signal.py's seeded walk reads them.
        self.assertNotIn("pr_grant", jobs["admission-placement"]["if"])
        self.assertNotIn("pr_grant", jobs["late-placement"]["if"])
        # late-placement runs, but places nothing: its outputs fall back to {} and "".
        steps = {step.get("id"): step for step in jobs["late-placement"]["steps"]}
        for step_id in ("route-token", "place"):
            self.assertEqual(steps[step_id]["if"], "${{ inputs.pr_grant == '' }}", step_id)
        self.assertIn("steps.place.outputs.runners || '{}'", jobs["late-placement"]["outputs"]["runners"])


class Watchers(unittest.TestCase):
    def test_the_rescue_and_the_starvation_alarm_leave_a_granted_job_to_the_controller(self):
        for labels in (["cmux-mac", "xcode-26.6"], ["cmux-123-2-mac", "xcode-26.6"]):
            job = {"name": "app-host-unit-tests (1)", "labels": labels, "status": "queued"}
            self.assertIsNone(owned_pool_rescue.job_pool(job), labels)
            self.assertEqual(starved_labels.fleet_key(job), "", labels)


if __name__ == "__main__":
    unittest.main()

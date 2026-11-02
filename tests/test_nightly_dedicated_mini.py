#!/usr/bin/env python3
"""The explicitly reserved nightly mini precedes every early portable route."""
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
sys.path.insert(0, str(ROOT / "tests"))
import nightly_build_runner as picker
import runner_label_policy as policy
from test_nightly_trusted_routing import evaluate, parse_expression

LABEL = "glaeda-nightly-only-m4pro"
VARIABLE = "vars.CI_NIGHTLY_ONLY_RUNNER"
BUILDER = "glaeda-nightly-only-m4pro-builder"
BUILDER_VARIABLE = "vars.CI_NIGHTLY_ONLY_BUILDER_RUNNER"
EARLY = ("decide", "resolve-nightly-cmux-tui-client", "resolve-nightly-ghostty-cli-helper",
         "build-nightly-inputs", "find-nightly-next-recovery", "pick-nightly-build-runner",
         "build-nightly-ghostty-cli-helper")
DOC = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())


def context(**changes):
    value = {"github.repository": "manaflow-ai/cmux", "github.repository_owner": "manaflow-ai",
             "github.ref": "refs/heads/nightly-next", "github.event_name": "push",
             "github.run_attempt": 1, "needs.decide.outputs.track": "nightly-next", VARIABLE: LABEL,
             "vars.LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404"}
    value.update(changes)
    return value


def selected(job, values):
    return evaluate(parse_expression(DOC["jobs"][job]["runs-on"].removeprefix("${{").removesuffix("}}")), values)


class DedicatedMini(unittest.TestCase):
    def test_reservation_variable_rejects_unknown_or_hosted_labels(self):
        for value in ("", LABEL):
            self.assertEqual(policy.drifted_runner_variables({"CI_NIGHTLY_ONLY_RUNNER": value}), [])
        for value in ("glaeda-unregistered", "macos-26", "ubuntu-24.04", "blacksmith-16vcpu-ubuntu-2404"):
            self.assertTrue(policy.drifted_runner_variables({"CI_NIGHTLY_ONLY_RUNNER": value}))

    def test_early_jobs_prefer_reserved_mini_even_without_picker_outputs(self):
        for job in EARLY:
            with self.subTest(job=job):
                self.assertEqual(selected(job, context()), LABEL)

    def test_exception_is_exact_label_next_repository_and_first_attempt(self):
        for job in EARLY:
            for changes in ({VARIABLE: ""}, {VARIABLE: "glaeda-unregistered"},
                            {VARIABLE: "blacksmith-16vcpu-ubuntu-2404"},
                            {"github.run_attempt": 2}, {"github.run_attempt": 3},
                            {"github.repository": "other/cmux", "github.repository_owner": "other"},
                            {"github.ref": "refs/heads/main", "needs.decide.outputs.track": "nightly"}):
                with self.subTest(job=job, changes=changes):
                    self.assertNotEqual(selected(job, context(**changes)), LABEL)

    def test_dedicated_route_skips_the_unreachable_linux_admission_wait(self):
        steps = {step.get("id"): step for step in DOC["jobs"]["decide"]["steps"]}
        values = context(**{"steps.decide.outputs.track": "nightly-next",
                            "steps.decide.outputs.should_build": "true"})
        for name in ("start-early-linux", "place-early", "place-early-mac"):
            condition = steps[name]["if"].removeprefix("${{").removesuffix("}}")
            self.assertFalse(evaluate(parse_expression(condition), values))
            self.assertTrue(evaluate(parse_expression(condition), {**values, VARIABLE: ""}))

    def test_app_and_helper_pick_the_reserved_mini_without_api_quota(self):
        def unavailable(*args):
            raise AssertionError("dedicated reservation must not need a capacity read")
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "output"
            env = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_RUN_ATTEMPT": "1",
                   "GITHUB_REF": "refs/heads/nightly-next", "GITHUB_EVENT_NAME": "push",
                   "GITHUB_OUTPUT": str(path), "NIGHTLY_ONLY_LABEL": LABEL,
                   "ROUTE_TOKEN": "present", "SNAPSHOT_TOKEN": "present",
                   "DEDICATED_LABEL": "glaeda-trusted-next-nightly"}
            self.assertEqual(picker.main(env, read_runners=unavailable, read_snapshot=unavailable,
                                         read_admission_fn=unavailable), 0)
            out = dict(line.split("=", 1) for line in path.read_text().splitlines())
            for key in ("owned", "helper", "dedicated", "runner"):
                self.assertEqual(out[key], LABEL)
            self.assertEqual(out["trusted"], "")
            values = context(**{f"needs.pick-nightly-build-runner.outputs.{key}": value
                                for key, value in out.items()})
            self.assertEqual(selected("build-nightly-app", values), LABEL)
            # The legacy helper selector rejects helper == dedicated. The new
            # all-nightly reservation admits both, including cache-hit controls.
            for hit, resume in (("false", ""), ("true", ""), ("false", "123")):
                with self.subTest(hit=hit, resume=resume):
                    routed = {**values, "needs.resolve-nightly-ghostty-cli-helper.outputs.hit": hit,
                              "inputs.nightly_next_unsigned_run": resume}
                    self.assertEqual(selected("build-nightly-ghostty-cli-helper", routed), LABEL)

    def test_picker_exception_does_not_capture_reruns_forks_or_other_tracks(self):
        for changes in ({"GITHUB_RUN_ATTEMPT": "2"}, {"GITHUB_REPOSITORY": "another/repo"},
                        {"GITHUB_REF": "refs/heads/main"}, {"GITHUB_EVENT_NAME": "pull_request"},
                        {"NIGHTLY_ONLY_LABEL": "glaeda-unregistered"}):
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as scratch:
                path = Path(scratch) / "output"
                env = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_RUN_ATTEMPT": "1",
                       "GITHUB_REF": "refs/heads/nightly-next", "GITHUB_EVENT_NAME": "push",
                       "GITHUB_OUTPUT": str(path), "NIGHTLY_ONLY_LABEL": LABEL, **changes}
                self.assertEqual(picker.main(env), 0)
                out = dict(line.split("=", 1) for line in path.read_text().splitlines())
                self.assertNotEqual(out["owned"], LABEL)
                self.assertNotEqual(out["helper"], LABEL)

    def builder_pick(self, runners, **changes):
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "output"
            env = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_RUN_ATTEMPT": "1",
                   "GITHUB_REF": "refs/heads/nightly-next", "GITHUB_EVENT_NAME": "push",
                   "GITHUB_OUTPUT": str(path), "NIGHTLY_ONLY_LABEL": LABEL, "ROUTE_TOKEN": "present",
                   "NIGHTLY_ONLY_BUILDER_LABEL": BUILDER, **changes}

            def read(token, repo):
                if isinstance(runners, Exception):
                    raise runners
                return runners
            self.assertEqual(picker.main(env, read_runners=read), 0)
            return dict(line.split("=", 1) for line in path.read_text().splitlines())

    @staticmethod
    def runner(*labels, status="online", busy=False):
        return {"status": status, "busy": busy, "labels": [{"name": label} for label in labels]}

    def test_app_takes_the_warm_builder_only_while_one_is_idle_now(self):
        idle = [self.runner(LABEL, BUILDER, busy=True), self.runner(LABEL, BUILDER)]
        out = self.builder_pick(idle)
        self.assertEqual((out["owned"], out["runner"]), (BUILDER, BUILDER))
        # Only build-nightly-app reads `owned`: the helper and light jobs keep the plain label.
        self.assertEqual((out["helper"], out["dedicated"]), (LABEL, LABEL))
        values = context(**{f"needs.pick-nightly-build-runner.outputs.{key}": value for key, value in out.items()})
        self.assertEqual(selected("build-nightly-app", values), BUILDER)
        self.assertEqual(selected("build-nightly-ghostty-cli-helper", values), LABEL)
        # Busy, offline, unread, a failed read, no token or a mistyped label: the plain label, never a wait.
        for runners, changes in (([self.runner(LABEL, BUILDER, busy=True)], {}),
                                 ([self.runner(LABEL, BUILDER, status="offline"), self.runner(LABEL)], {}),
                                 ([], {}), (None, {}), (RuntimeError("403"), {}), (idle, {"ROUTE_TOKEN": ""}),
                                 (idle, {"NIGHTLY_ONLY_BUILDER_LABEL": "glaeda-unregistered"}),
                                 (idle, {"NIGHTLY_ONLY_BUILDER_LABEL": ""})):
            with self.subTest(runners=runners, changes=changes):
                out = self.builder_pick(runners, **changes)
                self.assertEqual((out["owned"], out["runner"], out["helper"]), (LABEL, LABEL, LABEL))

    def test_builder_variable_is_validated_and_mints_the_read_token_only_when_set(self):
        for value in ("", BUILDER):
            self.assertEqual(policy.drifted_runner_variables({"CI_NIGHTLY_ONLY_BUILDER_RUNNER": value}), [])
        for value in (LABEL, "glaeda-unregistered", "macos-26", "blacksmith-6vcpu-macos-26"):
            self.assertTrue(policy.drifted_runner_variables({"CI_NIGHTLY_ONLY_BUILDER_RUNNER": value}))
        steps = {step.get("id"): step for step in DOC["jobs"]["pick-nightly-build-runner"]["steps"]}
        condition = parse_expression(steps["route-token"]["if"])
        values = {"github.repository": "manaflow-ai/cmux", "vars.CI_PR_POOL_OWNED": "1",
                  "vars.GLAEDA_ROUTE_APP_ID": "1", "github.event_name": "push",
                  "github.ref": "refs/heads/nightly-next", "github.run_attempt": 1, VARIABLE: LABEL}
        self.assertFalse(evaluate(condition, {**values, BUILDER_VARIABLE: ""}))
        self.assertTrue(evaluate(condition, {**values, BUILDER_VARIABLE: BUILDER}))
        self.assertIn(f"${{{{ {BUILDER_VARIABLE} }}}}", steps["pick"]["env"]["NIGHTLY_ONLY_BUILDER_LABEL"])

    def test_linux_elf_signer_does_not_take_the_mac_reservation(self):
        self.assertNotIn(VARIABLE, DOC["jobs"]["signer-build"]["runs-on"])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Admission placement: compile admission is pinned to a root runner on a mini running no root job."""
from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/admission_placement.py"
WORKFLOWS = ROOT / ".github/workflows"
ROOT_STD = "glaeda-root-std-xcode-26.6"
ROOT_AWS = "glaeda-aws-root-std-xcode-26.6"
STD = "glaeda-std-xcode-26.6"


def load():
    spec = importlib.util.spec_from_file_location("admission_placement", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["admission_placement"] = module
    spec.loader.exec_module(module)
    return module


placement = load()


def runner(host: str, k: int, *, busy: bool = False, status: str = "online", own: bool = True,
           namespace: str = "") -> dict:
    name = f"{host}-glaeda" + (f"-{k}" if k else "")
    prefix = f"glaeda-{namespace}-" if namespace else "glaeda-"
    labels = ["self-hosted", f"{prefix}std-xcode-26.6", f"{prefix}root-std-xcode-26.6",
              *([f"glaeda-runner-{name}"] if own else [])]
    return {"name": name, "status": status, "busy": busy, "labels": [{"name": label} for label in labels]}


ENV = {"ROOT_RUNNER": ROOT_STD, "ADMISSION_WARM": "", "GITHUB_RUN_ID": "123"}


class Decide(unittest.TestCase):
    def test_namespaced_aws_root_is_eligible_for_spread_placement(self):
        env = dict(ENV, ROOT_RUNNER=ROOT_AWS)
        labels, how, _ = placement.decide(env, [
            runner("aws-a", 0, busy=True, namespace="aws"), runner("aws-a", 1, namespace="aws"),
            runner("aws-b", 0, namespace="aws"), runner("aws-b", 1, namespace="aws"),
        ])
        self.assertEqual(json.loads(labels)[0], ROOT_AWS)
        self.assertEqual(how, "spread")

    def test_pins_admission_to_an_empty_mini(self):
        runners = [runner("mini-a", 0, busy=True), runner("mini-a", 1), runner("mini-b", 0), runner("mini-b", 1)]
        labels, how, why = placement.decide(ENV, runners)
        self.assertEqual(json.loads(labels)[0], ROOT_STD)
        self.assertTrue(json.loads(labels)[1].startswith("glaeda-runner-mini-b-glaeda"), labels)
        self.assertEqual(how, "spread")
        self.assertIn("no root job running", why)

    def test_prefers_a_warm_runner_on_an_empty_mini(self):
        runners = [runner("mini-a", 0), runner("mini-b", 0), runner("mini-b", 1)]
        env = dict(ENV, ADMISSION_WARM='["mini-b-glaeda-1"]')
        self.assertEqual(placement.decide(env, runners)[:2],
                         (json.dumps([ROOT_STD, "glaeda-runner-mini-b-glaeda-1"]).replace(" ", ""), "spread-warm"))

    def test_every_mini_busy_takes_an_idle_warm_runner_then_the_root_label(self):
        runners = [runner("mini-a", 0, busy=True), runner("mini-a", 1)]
        warm = dict(ENV, ADMISSION_WARM='["mini-a-glaeda-1"]')
        self.assertEqual(placement.decide(warm, runners)[:2],
                         ('["glaeda-root-std-xcode-26.6","glaeda-runner-mini-a-glaeda-1"]', "warm"))
        self.assertEqual(placement.decide(ENV, runners)[:2], (json.dumps([ROOT_STD]), "root"))
        # The pull request's tier after the merge base's.
        tiers = dict(ENV, ADMISSION_WARM='[["mini-z-glaeda"],["mini-a-glaeda-1"]]')
        self.assertEqual(placement.decide(tiers, runners)[1], "warm")
        # Garbage in ADMISSION_WARM names no runner.
        for raw in ("not json", '{"a": 1}', "[1, 2]"):
            self.assertEqual(placement.decide(dict(ENV, ADMISSION_WARM=raw), runners)[1], "root", raw)

    def test_admission_warm_is_tiers_of_names(self):
        self.assertEqual(placement.warm_tiers('[["a", "b"], ["c"]]'), [["a", "b"], ["c"]])
        self.assertEqual(placement.warm_tiers('["a", "b"]'), [["a", "b"]])
        for raw in ("", "[]", "not json", '{"a": 1}', "7"):
            self.assertEqual(placement.warm_tiers(raw), [], raw)
        self.assertEqual(placement.warm_tiers('[["a", 1], "b"]'), [["a"]])

    def test_unreadable_runners_or_no_root_label_keep_the_pickers_choice(self):
        self.assertEqual(placement.decide(ENV, None)[:2], ("", ""))
        for root in ("", STD, "blacksmith-6vcpu-macos-26"):
            self.assertEqual(placement.decide(dict(ENV, ROOT_RUNNER=root), [runner("mini-a", 0)])[:2], ("", ""), root)

    def test_main_writes_empty_outputs_without_a_token(self):
        with tempfile.NamedTemporaryFile("r+", suffix=".out") as out:
            self.assertEqual(placement.main(dict(ENV, GITHUB_OUTPUT=out.name, GITHUB_RUN_ATTEMPT="1")), 0)
            self.assertEqual(Path(out.name).read_text(), "runner=\nplacement=\nattempt=1\n")

    def test_a_re_run_skips_the_minis_that_failed_a_job_in_the_attempt_before(self):
        jobs = [{"conclusion": "failure", "runner_name": "mini-b-glaeda-1"},
                # Lost communication: a failed job that keeps its runner's name.
                {"conclusion": "failure", "runner_name": "mini-c-glaeda"},
                {"conclusion": "success", "runner_name": "mini-a-glaeda"},
                {"conclusion": "cancelled", "runner_name": None},
                {"conclusion": "failure", "runner_name": "blacksmith-6vcpu-macos-26-Runner-1"}]
        self.assertEqual(placement.failed_members(jobs), {"mini-b", "mini-c"})
        runners = [runner("mini-a", 0, busy=True), runner("mini-a", 1), runner("mini-b", 0), runner("mini-b", 1)]
        self.assertIn("mini-b", placement.decide(ENV, runners)[0])
        # Only mini-a is left, and it runs a root job: the root label, never mini-b's runners.
        self.assertEqual(placement.decide(ENV, runners, {"mini-b"})[:2], (json.dumps([ROOT_STD]), "root"))
        warm = dict(ENV, ADMISSION_WARM='["mini-b-glaeda-1"]')
        self.assertEqual(placement.decide(warm, runners, {"mini-b"})[1], "root")

    def test_main_reads_the_attempt_before_once_on_a_re_run(self):
        from unittest import mock
        paths = []

        class API:
            def __init__(self, token, repo):
                pass

            def runners(self):
                return [runner("mini-a", 0), runner("mini-b", 0)]

            def get(self, path):
                paths.append(path)
                return {"jobs": [{"conclusion": "failure", "runner_name": "mini-a-glaeda"}]}
        with tempfile.NamedTemporaryFile("r+", suffix=".out") as out, \
                mock.patch.object(placement.pool, "GitHub", API), mock.patch("sys.stdout"):
            env = dict(ENV, GITHUB_OUTPUT=out.name, ROUTE_TOKEN="t", GITHUB_REPOSITORY="o/r", GITHUB_RUN_ATTEMPT="2")
            self.assertEqual(placement.main(env), 0)
            text = Path(out.name).read_text()
        self.assertEqual(paths, ["/actions/runs/123/attempts/1/jobs?per_page=100"])
        self.assertIn("glaeda-runner-mini-b-glaeda", text)
        self.assertTrue(text.endswith("attempt=2\n"), text)
        # Attempt 1 reads no jobs.
        paths.clear()
        with tempfile.NamedTemporaryFile("r+", suffix=".out") as out, \
                mock.patch.object(placement.pool, "GitHub", API), mock.patch("sys.stdout"):
            placement.main(dict(ENV, GITHUB_OUTPUT=out.name, ROUTE_TOKEN="t", GITHUB_REPOSITORY="o/r",
                                GITHUB_RUN_ATTEMPT="1"))
        self.assertEqual(paths, [])


class Workflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load((WORKFLOWS / "ci-macos.yml").read_text())["jobs"]

    def test_the_pin_is_picked_in_the_job_admission_waits_for(self):
        spec = self.jobs["admission-placement"]
        # Opt in, a same-repository run, admission on a root label only, on any attempt that runs it.
        self.assertNotIn("run_attempt", spec["if"])
        for clause in ("vars.CI_OWNED_SPREAD == '1'",
                       "github.event.pull_request.head.repo.full_name == github.repository",
                       "startsWith(inputs.pr_root_runner, 'glaeda-root-')",
                       "startsWith(inputs.pr_root_runner, 'glaeda-aws-root-')",
                       "contains(inputs.pr_owned_jobs, ' admission ')"):
            self.assertIn(clause, spec["if"])
        self.assertTrue(all(step.get("continue-on-error") for step in spec["steps"]))
        self.assertEqual(spec["outputs"]["runner"], "${{ steps.place.outputs.runner }}")
        self.assertEqual(spec["outputs"]["attempt"], "${{ steps.place.outputs.attempt }}")
        # The previous attempt's jobs, to skip the minis that failed one.
        for mint in ("route-token", "route-token-repo"):
            mint_step = next(step for step in spec["steps"] if step.get("id") == mint)
            self.assertEqual(mint_step["with"]["permission-actions"], "read", mint)
        place = next(step for step in spec["steps"] if step.get("id") == "place")
        self.assertEqual(place["run"], "python3 scripts/ci/admission_placement.py")
        self.assertEqual(place["env"]["ROOT_RUNNER"], "${{ inputs.pr_root_runner }}")
        self.assertEqual(place["env"]["ADMISSION_WARM"], "${{ inputs.pr_admission_warm }}")
        # Admission waits for it, and a skipped or failed placement never skips admission.
        admission = self.jobs["macos-compile-admission"]
        self.assertEqual(admission["needs"], ["admission-placement"])
        self.assertTrue(admission["if"].startswith("${{ !cancelled() && "), admission["if"])
        # Only the pin made in this attempt: a re-run of failed jobs keeps the earlier attempt's outputs.
        self.assertIn("needs.admission-placement.outputs.attempt == github.run_attempt && "
                      "needs.admission-placement.outputs.runner && fromJSON(needs.admission-placement.outputs.runner)",
                      admission["runs-on"])

    def test_the_picker_hands_the_warm_names_through(self):
        ci = yaml.safe_load((WORKFLOWS / "ci.yml").read_text())["jobs"]
        self.assertEqual(ci["changes"]["outputs"]["macos_pr_admission_warm"],
                         "${{ steps.macos-pool.outputs.admission_warm }}")
        self.assertEqual(ci["macos"]["with"]["pr_admission_warm"],
                         "${{ needs.changes.outputs.macos_pr_admission_warm }}")


if __name__ == "__main__":
    unittest.main()

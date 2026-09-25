#!/usr/bin/env python3
"""Late placement: jobs after compile admission move onto idle root runners."""
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/late_placement.py"
WORKFLOW = ROOT / ".github/workflows/ci-macos.yml"
XCODE = "/Applications/Xcode_26.6.app"
ROOT_STD = "glaeda-root-std-xcode-26.6"
FULL = {"MACOS": "true", "CLI": "false", "FULL_SUITE": "true", "UNIT_SUITE": "false",
        "UNIT_IN_ADMISSION": "false", "UNIT_SELECTORS": "", "ADMISSION_XCODE_APP": XCODE,
        "ADMISSION_RUNNER": "blacksmith-12vcpu-macos-26", "OWNED_JOBS": ""}


def load():
    spec = importlib.util.spec_from_file_location("late_placement", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["late_placement"] = module
    spec.loader.exec_module(module)
    return module


late = load()


def runner(name: str, *labels: str, busy: bool = False, status: str = "online") -> dict:
    return {"name": name, "status": status, "busy": busy, "labels": [{"name": label} for label in labels]}


def roots(idle: int, busy: int = 0) -> list[dict]:
    return ([runner(f"idle-{i}", "self-hosted", ROOT_STD) for i in range(idle)]
            + [runner(f"busy-{i}", ROOT_STD, busy=True) for i in range(busy)])


class Decide(unittest.TestCase):
    def test_a_full_suite_off_blacksmith_takes_the_idle_roots_shards_first(self):
        placed, why = late.decide(FULL, roots(idle=3, busy=5))
        self.assertEqual(placed, {"shard-1": ROOT_STD, "shard-2": ROOT_STD, "shard-3": ROOT_STD})
        self.assertIn("3 idle", why)

    def test_enough_idle_roots_move_every_job_after_admission(self):
        placed, _ = late.decide(FULL, roots(idle=16))
        self.assertEqual(set(placed), {*(f"shard-{i}" for i in range(1, 8)), "lag", "cli-product"})

    def test_jobs_the_picker_already_owned_stay_put(self):
        env = dict(FULL, OWNED_JOBS=" admission shard-1 shard-2 ")
        placed, _ = late.decide(env, roots(idle=2))
        self.assertEqual(placed, {"shard-3": ROOT_STD, "shard-4": ROOT_STD})

    def test_no_idle_root_changes_nothing(self):
        self.assertEqual(late.decide(FULL, roots(idle=0, busy=16))[0], {})

    def test_offline_runners_do_not_count(self):
        self.assertEqual(late.decide(FULL, [runner("off", ROOT_STD, status="offline")])[0], {})

    def test_another_xcode_has_no_owned_pool(self):
        env = dict(FULL, ADMISSION_XCODE_APP="/Applications/Xcode_26.3.app")
        placed, why = late.decide(env, roots(idle=8))
        self.assertEqual(placed, {})

    def test_unreadable_runners_change_nothing(self):
        placed, why = late.decide(FULL, None)
        self.assertEqual(placed, {})
        self.assertIn("could not be read", why)

    def test_gui_off_moves_only_cli_product(self):
        env = dict(FULL, POOL_OWNED_GUI="0")
        self.assertEqual(late.decide(env, roots(idle=8))[0], {"cli-product": ROOT_STD})

    def test_a_changed_suites_run_moves_its_one_worker(self):
        env = dict(FULL, FULL_SUITE="false", UNIT_SUITE="true", UNIT_SELECTORS="cmuxTests/FooTests")
        self.assertEqual(late.decide(env, roots(idle=4))[0], {"shard-8": ROOT_STD})

    def test_a_compile_only_run_has_nothing_after_admission(self):
        env = dict(FULL, FULL_SUITE="false")
        self.assertEqual(late.decide(env, roots(idle=4))[0], {})


class Output(unittest.TestCase):
    def test_main_writes_an_empty_object_without_a_token(self):
        import tempfile
        with tempfile.NamedTemporaryFile("r+", suffix=".out") as out:
            self.assertEqual(late.main(dict(FULL, GITHUB_OUTPUT=out.name)), 0)
            self.assertEqual(Path(out.name).read_text(), "runners={}\n")


class Workflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]

    def test_the_consumers_wait_for_late_placement_and_read_it_first_on_attempt_one(self):
        keys = {"app-host-unit-tests": "format('shard-{0}', matrix.shard)",
                "tests-build-and-lag": "'lag'", "cli-product-tests": "'cli-product'"}
        prefix = "${{ github.run_attempt == 1 && fromJSON(needs.late-placement.outputs.runners || '{}')[%s] || "
        for job, key in keys.items():
            with self.subTest(job=job):
                spec = self.jobs[job]
                self.assertIn("late-placement", spec["needs"])
                late = (prefix % key).removeprefix("${{ ")
                owner = "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || "
                # tests-build-and-lag keeps the fork-owner branch first (test_ci_fork_runner_routing).
                self.assertTrue(spec["runs-on"].startswith("${{ " + late) or spec["runs-on"].startswith(owner + late),
                                spec["runs-on"][:200])
                # The job-level if never requires late-placement, so a skipped or failed one
                # leaves the consumer running where the picker put it.
                self.assertNotIn("late-placement", spec["if"])
                requested = [step["env"]["REQUESTED_RUNNER"] for step in spec["steps"]
                             if "REQUESTED_RUNNER" in (step.get("env") or {})]
                self.assertEqual(requested, [spec["runs-on"]])

    def test_late_placement_runs_only_where_the_picker_may_use_owned_runners(self):
        spec = self.jobs["late-placement"]
        for clause in ("github.run_attempt == 1", "vars.CI_PR_POOL_OWNED == '1'",
                       "github.event.pull_request.head.repo.full_name == github.repository",
                       "needs.macos-compile-admission.result == 'success'"):
            self.assertIn(clause, spec["if"])
        self.assertTrue(all(step.get("continue-on-error") for step in spec["steps"]))
        self.assertEqual(spec["outputs"]["runners"], "${{ steps.place.outputs.runners || '{}' }}")

    def test_moved_jobs_leave_the_marker_the_rescue_watch_looks_for(self):
        steps = {step["name"]: step for step in self.jobs["late-placement"]["steps"]}
        marker = steps["Upload the late placement marker"]
        self.assertIn("steps.place.outputs.runners != '{}'", marker["if"])
        rescue = (ROOT / "scripts/ci/owned_pool_rescue.py").read_text()
        # owned_pool_rescue.late_marker_name() and LATE_JOB: the names the watch reads.
        self.assertIn('LATE_MARKER_PREFIX = "macos-pool-late"', rescue)
        self.assertEqual(marker["with"]["name"], "macos-pool-late-${{ github.run_id }}-${{ github.run_attempt }}")
        self.assertIn('LATE_JOB = "macos / late-placement"', rescue)
        # It starts nothing itself: ci.yml's owned-pool-watch holds the only actions: write.
        self.assertEqual(self.jobs["late-placement"]["permissions"], {"contents": "read"})


if __name__ == "__main__":
    unittest.main()

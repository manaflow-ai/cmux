#!/usr/bin/env python3
"""An E2E dispatch waits for an earlier run's compile of the same revision."""
from __future__ import annotations

import importlib.util
import re
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("e2e_sibling_build", ROOT / "scripts/ci/e2e_sibling_build.py")
sibling = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sibling)

SHA = "a" * 40
OTHER = "b" * 40
SMALL = "blacksmith-6vcpu-macos-26"
LARGE = "blacksmith-12vcpu-macos-26"
OLD = "blacksmith-6vcpu-macos-15"


def run(run_id: int, revision: str = SHA, runner: str = SMALL, status: str = "in_progress") -> dict:
    title = f"cmuxTests/Suite{run_id} on {runner} @ {revision} [d{run_id}]"
    return {"id": run_id, "status": status, "display_title": title}


class Fake:
    """The Actions API as a sequence of build-job states for one sibling run."""

    def __init__(self, runs: list[dict], states: list[tuple[str, str | None]], run_status: str = "in_progress"):
        self.runs = runs
        self.states = list(states)
        self.run_status = run_status
        self.sleeps = 0
        self.now = 0.0

    def get(self, path: str) -> dict:
        if "/workflows/" in path:
            assert path == sibling.RUNNING, path
            return {"workflow_runs": self.runs}
        if path.endswith("/jobs?filter=latest&per_page=100"):
            status, conclusion = self.states.pop(0) if len(self.states) > 1 else self.states[0]
            return {"jobs": [{"name": "build", "status": status, "conclusion": conclusion},
                             {"name": "test", "status": "queued", "conclusion": None}]}
        return {"status": self.run_status}

    def sleep(self, seconds: float) -> None:
        self.sleeps += 1
        self.now += seconds

    def wait(self, run_id: str = "100", runner: str = SMALL, budget: float = 1200) -> bool:
        return sibling.wait(run_id, SHA, runner, budget, poll=30, get=self.get, sleep=self.sleep, clock=lambda: self.now)


class SiblingWaitTests(unittest.TestCase):
    def test_waits_for_an_earlier_compile_of_the_same_revision(self) -> None:
        fake = Fake([run(90)], [("in_progress", None), ("in_progress", None), ("completed", "success")])
        self.assertTrue(fake.wait())
        self.assertEqual(fake.sleeps, 2)

    def test_a_failed_compile_is_not_waited_for_again(self) -> None:
        fake = Fake([run(90)], [("in_progress", None), ("completed", "failure")])
        self.assertFalse(fake.wait())

    def test_a_cancelled_run_before_its_build_finishes_ends_the_wait(self) -> None:
        fake = Fake([run(90)], [("in_progress", None)], run_status="completed")
        self.assertFalse(fake.wait())
        self.assertEqual(fake.sleeps, 0)

    def test_a_compile_still_queued_for_a_runner_is_waited_for(self) -> None:
        # The wait holds only a Linux runner, so a queued compile is worth it.
        fake = Fake([run(90)], [("queued", None), ("in_progress", None), ("completed", "success")])
        self.assertTrue(fake.wait())

    def test_the_budget_bounds_the_wait(self) -> None:
        fake = Fake([run(90)], [("in_progress", None)])
        self.assertFalse(fake.wait(budget=300))
        self.assertEqual(fake.sleeps, 10)

    def test_no_budget_means_no_wait(self) -> None:
        fake = Fake([run(90)], [("in_progress", None)])
        self.assertFalse(fake.wait(budget=0))
        self.assertEqual(fake.sleeps, 0)

    def test_a_later_run_is_never_waited_for(self) -> None:
        # Two simultaneous dispatches: only the later one waits.
        self.assertFalse(Fake([run(110)], [("in_progress", None)]).wait(run_id="100"))

    def test_another_revision_or_macos_is_not_a_sibling(self) -> None:
        runs = [run(90, revision=OTHER), run(91, runner=OLD), run(92, status="completed")]
        self.assertIsNone(sibling.earlier_sibling(runs, "100", SHA, SMALL))

    def test_the_other_macos_26_pool_builds_the_same_product(self) -> None:
        found = sibling.earlier_sibling([run(95, runner=LARGE), run(90, runner=SMALL)], "100", SHA, SMALL)
        self.assertEqual(found["id"], 90)

    def test_the_listing_asks_for_running_runs(self) -> None:
        # event=workflow_dispatch alone returned a stale page (run 36020090083
        # compiled beside running sibling 36020076746).
        self.assertIn("status=in_progress", sibling.RUNNING)
        self.assertNotIn("event=", sibling.RUNNING)

    def test_a_title_without_a_full_revision_is_ignored(self) -> None:
        loose = {"id": 90, "status": "in_progress", "display_title": "cmuxTests/Suite on blacksmith-6vcpu-macos-26 @ main"}
        self.assertIsNone(sibling.earlier_sibling([loose], "100", SHA, SMALL))


class WorkflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = yaml.safe_load((ROOT / ".github/workflows/test-e2e.yml").read_text())["jobs"]

    def test_the_wait_runs_on_linux_before_the_build(self) -> None:
        sibling_job = self.jobs["sibling"]
        self.assertNotIn("macos", str(sibling_job["runs-on"]))
        self.assertEqual(sibling_job["runs-on"], self.jobs["runner"]["runs-on"])
        self.assertIn("sibling", self.jobs["build"]["needs"])
        wait = next(step for step in sibling_job["steps"] if "e2e_sibling_build.py wait" in str(step.get("run")))
        self.assertTrue(wait["run"].endswith("|| true"))
        # The job outlasts the wait, so the budget, not the timeout, ends it.
        self.assertGreater(sibling_job["timeout-minutes"] * 60, int(wait["env"]["CMUX_E2E_SIBLING_WAIT_SECONDS"]))

    def test_a_failed_wait_never_skips_the_build(self) -> None:
        condition = self.jobs["build"]["if"]
        self.assertIn("!cancelled()", condition)
        self.assertNotIn("needs.sibling", condition)
        for job in ("resolve-ref", "filter", "runner"):
            self.assertIn(f"needs.{job}.result == 'success'", condition)

    def test_the_helper_comes_from_the_workflow_revision(self) -> None:
        checkout = self.jobs["sibling"]["steps"][0]
        self.assertEqual(checkout["with"]["sparse-checkout"], "scripts/ci/e2e_sibling_build.py")
        self.assertNotIn("ref", checkout["with"])

    def test_the_build_restores_through_the_unchanged_reuse_step(self) -> None:
        reuse = next(step for step in self.jobs["build"]["steps"] if step.get("id") == "reuse")
        self.assertEqual(reuse["run"].strip(), 'python3 scripts/ci/reuse_app_host_products.py restore "$CMUX_DERIVED_DATA_PATH"')


if __name__ == "__main__":
    unittest.main()

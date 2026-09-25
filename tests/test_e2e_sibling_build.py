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
OWNED = "glaeda-root-std-xcode-26.6"


def started(run_id: int) -> str:
    """By default a run's attempt started in id order, as a first attempt does."""
    return f"2026-09-25T17:{run_id % 60:02d}:00Z"


def run(run_id: int, revision: str = SHA, runner: str = SMALL, status: str = "in_progress",
        run_started_at: str | None = None) -> dict:
    title = f"cmuxTests/Suite{run_id} on {runner} @ {revision} [d{run_id}]"
    return {"id": run_id, "status": status, "display_title": title,
            "run_started_at": run_started_at or started(run_id)}


THIS = run(100)


class Fake:
    """The Actions API as a sequence of build-job states for one sibling run."""

    def __init__(self, runs: list[dict], states: list[tuple], run_status: str = "in_progress",
                 restarts: dict[int, str] | None = None):
        self.runs = runs
        self.states = list(states)
        self.run_status = run_status
        # A run re-run while this one waits: its attempt's new start.
        self.restarts = restarts or {}
        self.sleeps = 0
        self.now = 0.0

    def get(self, path: str) -> dict:
        if "/workflows/" in path:
            assert path == sibling.RUNNING, path
            return {"workflow_runs": self.runs}
        if path.endswith("/jobs?filter=latest&per_page=100"):
            status, conclusion, *steps = self.states.pop(0) if len(self.states) > 1 else self.states[0]
            build = {"name": "build", "status": status, "conclusion": conclusion}
            if steps:
                build["steps"] = steps[0]
            return {"jobs": [build, {"name": "test", "status": "queued", "conclusion": None}]}
        run_id = int(path.rsplit("/", 1)[-1])
        listed = next((run for run in self.runs if run["id"] == run_id), None)
        if listed is None:
            return {"id": run_id, "status": "in_progress", "run_started_at": started(run_id)}
        return {**listed, "status": self.run_status,
                "run_started_at": self.restarts.get(run_id, listed["run_started_at"])}

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

    def test_a_published_product_ends_the_wait_while_its_tests_run(self) -> None:
        # The build job runs the tests after uploading, so waiting for the job
        # would wait for someone else's tests, and a failing test would look
        # like a failed compile.
        compiling = [{"name": sibling.PUBLISH_STEP, "status": "pending", "conclusion": None}]
        published = [{"name": sibling.PUBLISH_STEP, "status": "completed", "conclusion": "success"},
                     {"name": "Run selected tests on the build runner", "status": "in_progress", "conclusion": None}]
        fake = Fake([run(90)], [("in_progress", None, compiling), ("in_progress", None, published)])
        self.assertTrue(fake.wait())
        self.assertEqual(fake.sleeps, 1)
        tests_failed = [{"name": sibling.PUBLISH_STEP, "status": "completed", "conclusion": "success"},
                        {"name": "Run selected tests on the build runner", "status": "completed", "conclusion": "failure"}]
        self.assertTrue(Fake([run(90)], [("completed", "failure", tests_failed)]).wait())
        # An owned Mac tests first and uploads after, whatever the tests did.
        owned_failed = [{"name": sibling.PUBLISH_STEP, "status": "completed", "conclusion": "skipped"},
                        {"name": "Run selected tests", "status": "completed", "conclusion": "failure"},
                        {"name": sibling.PUBLISH_AFTER_TESTS_STEP, "status": "completed", "conclusion": "success"}]
        self.assertTrue(Fake([run(90)], [("completed", "failure", owned_failed)]).wait())

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

    def test_a_rerun_waits_on_a_run_that_started_before_it(self) -> None:
        # Run 36168890047's attempt 2 started at 17:44:55, after run
        # 36168944875 (a higher id, started 17:43:51) was already on its way
        # to compiling the same product. The id alone said not to wait.
        rerun = run(90, run_started_at="2026-09-25T17:44:55Z")
        other = run(95, run_started_at="2026-09-25T17:43:51Z")
        fake = Fake([rerun, other], [("in_progress", None), ("completed", "success")])
        self.assertTrue(fake.wait(run_id="90"))

    def test_two_runs_never_wait_on_each_other(self) -> None:
        for a, b in (
            (run(90, run_started_at="2026-09-25T17:44:55Z"), run(95, run_started_at="2026-09-25T17:43:51Z")),
            (run(90, run_started_at="2026-09-25T17:44:00Z"), run(95, run_started_at="2026-09-25T17:44:00Z")),
            (run(90), run(95)),
        ):
            with self.subTest(a=a["run_started_at"], b=b["run_started_at"]):
                waits = [sibling.earlier_sibling([a, b], a, SHA, SMALL), sibling.earlier_sibling([a, b], b, SHA, SMALL)]
                self.assertEqual(sum(found is not None for found in waits), 1)

    def test_the_same_start_waits_in_id_order(self) -> None:
        same = "2026-09-25T17:44:00Z"
        found = sibling.earlier_sibling([run(90, run_started_at=same)], run(95, run_started_at=same), SHA, SMALL)
        self.assertEqual(found["id"], 90)

    def test_a_sibling_rerun_after_this_run_started_ends_the_wait(self) -> None:
        # Its new attempt may now wait on this run, so this run stops first.
        fake = Fake([run(90)], [("in_progress", None)], restarts={90: "2026-09-25T18:00:00Z"})
        self.assertFalse(fake.wait())
        self.assertEqual(fake.sleeps, 0)

    def test_another_revision_or_macos_is_not_a_sibling(self) -> None:
        runs = [run(90, revision=OTHER), run(91, runner=OLD), run(92, status="completed")]
        self.assertIsNone(sibling.earlier_sibling(runs, THIS, SHA, SMALL))

    def test_the_other_macos_26_pool_builds_the_same_product(self) -> None:
        found = sibling.earlier_sibling([run(95, runner=LARGE), run(90, runner=SMALL)], THIS, SHA, SMALL)
        self.assertEqual(found["id"], 90)

    def test_an_owned_mac_waits_only_on_its_own_pool(self) -> None:
        # The contract hashes the node, go and bun versions, which no run has
        # yet shown to match between an owned Mac and Blacksmith, so an owned
        # run never waits up to the budget on a product it may not adopt.
        self.assertIsNone(sibling.earlier_sibling([run(90, runner=SMALL)], THIS, SHA, OWNED))
        self.assertEqual(sibling.earlier_sibling([run(90, runner=OWNED)], THIS, SHA, OWNED)["id"], 90)

    def test_the_listing_asks_for_running_runs(self) -> None:
        # event=workflow_dispatch alone returned a stale page (run 36020090083
        # compiled beside running sibling 36020076746).
        self.assertIn("status=in_progress", sibling.RUNNING)
        self.assertNotIn("event=", sibling.RUNNING)

    def test_a_title_without_a_full_revision_is_ignored(self) -> None:
        loose = {"id": 90, "status": "in_progress", "display_title": "cmuxTests/Suite on blacksmith-6vcpu-macos-26 @ main"}
        self.assertIsNone(sibling.earlier_sibling([loose], THIS, SHA, SMALL))


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

    def test_a_failed_wait_never_skips_the_tests(self) -> None:
        # The implicit success() on test reads every upstream job, sibling too.
        # The build job runs the tests itself, so test is its fallback.
        self.assertEqual(self.jobs["test"]["if"],
                         "${{ !cancelled() && needs.build.result == 'success' && needs.build.outputs.tested != 'true' }}")
        self.assertNotIn("sibling", self.jobs["test"]["needs"])

    def test_the_publish_step_the_wait_watches_exists(self) -> None:
        names = [step.get("name") for step in self.jobs[sibling.BUILD_JOB]["steps"]]
        self.assertIn(sibling.PUBLISH_STEP, names)
        self.assertIn(sibling.PUBLISH_AFTER_TESTS_STEP, names)

    def test_the_helper_comes_from_the_workflow_revision(self) -> None:
        checkout = self.jobs["sibling"]["steps"][0]
        self.assertEqual(checkout["with"]["sparse-checkout"], "scripts/ci/e2e_sibling_build.py")
        self.assertNotIn("ref", checkout["with"])

    def test_the_build_restores_through_the_unchanged_reuse_step(self) -> None:
        reuse = next(step for step in self.jobs["build"]["steps"] if step.get("id") == "reuse")
        self.assertEqual(reuse["run"].strip(), 'python3 scripts/ci/reuse_app_host_products.py restore "$CMUX_DERIVED_DATA_PATH"')


if __name__ == "__main__":
    unittest.main()

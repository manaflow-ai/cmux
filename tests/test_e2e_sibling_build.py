#!/usr/bin/env python3
"""An E2E dispatch waits for an earlier run's compile of the same revision."""
from __future__ import annotations

import importlib.util
import re
from pathlib import Path
import unittest

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
        fake = Fake([run(90)], [("in_progress", None)] * 3 + [("completed", "success")])
        self.assertTrue(fake.wait())
        self.assertEqual(fake.sleeps, 2)

    def test_a_failed_compile_is_not_waited_for_again(self) -> None:
        fake = Fake([run(90)], [("in_progress", None), ("completed", "failure")])
        self.assertFalse(fake.wait())

    def test_a_cancelled_run_before_its_build_finishes_ends_the_wait(self) -> None:
        fake = Fake([run(90)], [("in_progress", None)], run_status="completed")
        self.assertFalse(fake.wait())
        self.assertEqual(fake.sleeps, 0)

    def test_a_compile_still_queued_for_a_runner_is_not_waited_for(self) -> None:
        # Waiting would hold this runner idle while the other waits for one.
        fake = Fake([run(90)], [("queued", None)])
        self.assertFalse(fake.wait())
        self.assertEqual(fake.sleeps, 0)

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

    def test_a_title_without_a_full_revision_is_ignored(self) -> None:
        loose = {"id": 90, "status": "in_progress", "display_title": "cmuxTests/Suite on blacksmith-6vcpu-macos-26 @ main"}
        self.assertIsNone(sibling.earlier_sibling([loose], "100", SHA, SMALL))


class WorkflowTests(unittest.TestCase):
    def test_the_reuse_step_waits_then_restores_again(self) -> None:
        text = (ROOT / ".github/workflows/test-e2e.yml").read_text()
        step = text[text.index("- name: Reuse a compiled product instead of building one"):]
        step = step[: step.index("\n      - name:", 1)]
        first = step.index('GITHUB_OUTPUT="$first" python3 scripts/ci/reuse_app_host_products.py restore')
        waited = step.index("python3 scripts/ci/e2e_sibling_build.py wait")
        again = step.index('python3 scripts/ci/reuse_app_host_products.py restore', waited)
        self.assertLess(first, waited)
        self.assertLess(waited, again)
        # A tested revision older than the helper compiles as before.
        self.assertIn("[ -f scripts/ci/e2e_sibling_build.py ]", step)
        self.assertIn('cat "$first" >> "$GITHUB_OUTPUT"', step)

    def test_the_wait_has_its_own_share_of_the_build_timeout(self) -> None:
        text = (ROOT / ".github/workflows/test-e2e.yml").read_text()
        added = int(re.search(r'SIBLING_WAIT_MINUTES: "(\d+)"', text).group(1))
        waited = int(re.search(r'CMUX_E2E_SIBLING_WAIT_SECONDS: "(\d+)"', text).group(1))
        self.assertEqual(added * 60, waited)
        build = text[text.index("\n  build:\n"):text.index("\n  test:\n")]
        self.assertIn("timeout-minutes: ${{ fromJSON(needs.runner.outputs.build_timeout", build)


if __name__ == "__main__":
    unittest.main()

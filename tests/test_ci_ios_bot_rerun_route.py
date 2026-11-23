"""test-ios.yml on a cmux-next lane: a person's re-run stays on the owned minis, the bot's re-run takes Blacksmith.

Leo, 2026-11-16: "no required check waits past a bound on any owned label; past it, it moves to Blacksmith."
The owned-pool rescue (OWNED_WAIT_BOUND_SECONDS on main) moves a job past that bound with a
re-run of failed jobs as the bot. On a cmux-next lane the runner job overrode retry_runs_on with the owned label, so
that re-run queued on the same minis again: run 43899971589 (PR #44053) attempt 2's ios-simulator-build (job
133486478133) queued on [glaeda-std-xcode-26.6, glaeda-ios-sim] from 17:39Z, after attempt 1 waited from 15:48Z.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

from test_seed_derived_data import evaluate  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/test-ios.yml"
OWNED = json.dumps(["glaeda-std-xcode-26.6", "glaeda-ios-sim"])
SMALL = "blacksmith-6vcpu-macos-26"
BOTS = ("github-actions[bot]", "cmux-bot[bot]")


def jobs() -> dict:
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]


def route(expression: str, attempt: int, actor: str, **extra: str) -> object:
    """The runs-on `expression` takes on a cmux-next lane whose runner job placed it on the owned minis: the
    picker's retry is Blacksmith, and the lane's own re-run route (retry_runs_on) is the owned label."""
    outputs = {"runs_on": OWNED, "package_runs_on": json.dumps("glaeda-std-xcode-26.6"), "retry_runs_on": OWNED,
               "label": "glaeda-std-xcode-26.6", "retry_label": "glaeda-std-xcode-26.6",
               "bot_retry_runs_on": json.dumps(SMALL), "bot_retry_label": SMALL, **extra}
    context = {"github": {"repository_owner": "manaflow-ai", "run_attempt": str(attempt), "triggering_actor": actor,
                          "event_name": "pull_request"},
               "needs": {"runner": {"outputs": outputs}}, "vars": {}, "inputs": {}}
    inner = expression.strip()
    assert inner.startswith("${{") and inner.endswith("}}"), inner
    return evaluate(inner[3:-2], context)


class IOSBotRerunRoute(unittest.TestCase):
    def test_the_bot_s_re_run_takes_blacksmith_and_a_person_s_stays_owned(self):
        for name in ("mobile-core-package", "ios-simulator-build"):
            runs_on = jobs()[name]["runs-on"]
            with self.subTest(job=name):
                for bot in BOTS:
                    self.assertEqual(route(runs_on, 2, bot), SMALL)
                self.assertEqual(route(runs_on, 2, "teamleaderleo"), json.loads(OWNED))
                self.assertNotEqual(route(runs_on, 1, BOTS[0]), SMALL)

    def test_the_build_takes_the_sim_first_label_on_attempt_one_only(self):
        # 2026-11-17: cmux#44053's ios-simulator-build (job 133824519208) queued from 04:44Z behind
        # glaeda-side-std's 101 queued jobs; the picker's build_runs_on names glaeda's sim-first runner.
        first = json.dumps("glaeda-sim-xcode-26.6")
        runs_on = jobs()["ios-simulator-build"]["runs-on"]
        self.assertEqual(route(runs_on, 1, BOTS[0], build_runs_on=first), "glaeda-sim-xcode-26.6")
        # Re-runs keep their fallback.
        for bot in BOTS:
            self.assertEqual(route(runs_on, 2, bot, build_runs_on=first), SMALL)
        self.assertEqual(route(runs_on, 2, "teamleaderleo", build_runs_on=first), json.loads(OWNED))
        # A picker without the output: runs_on, as before.
        self.assertEqual(route(runs_on, 1, "teamleaderleo"), json.loads(OWNED))
        # mobile-core-package never reads it.
        self.assertEqual(route(jobs()["mobile-core-package"]["runs-on"], 1, BOTS[0], build_runs_on=first),
                         "glaeda-std-xcode-26.6")

    def test_the_requested_runner_follows_the_same_route(self):
        for name in ("mobile-core-package", "ios-simulator-build"):
            requested = [step["env"]["REQUESTED_RUNNER"] for step in jobs()[name]["steps"]
                         if "REQUESTED_RUNNER" in (step.get("env") or {})]
            with self.subTest(job=name):
                self.assertTrue(requested)
                for expression in requested:
                    self.assertEqual(route(expression, 2, BOTS[1]), SMALL)
                    self.assertEqual(route(expression, 2, "teamleaderleo"), "glaeda-std-xcode-26.6")

    def test_the_runner_job_keeps_the_picker_s_retry_for_the_bot(self):
        runner = jobs()["runner"]
        for key in ("bot_retry_runs_on", "bot_retry_label"):
            self.assertIn(f"steps.pool.outputs.{key}", runner["outputs"][key])
        script = next(step["run"] for step in runner["steps"] if step.get("id") == "pool")
        # Written before the lane's owned override, from the picker's own answer.
        self.assertLess(script.index("bot_retry_runs_on="), script.index('if [ -n "$NEXT_LANE" ]'))


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""A bot re-run past a workflow's attempt cap keeps a runner that serves it.

2026-11-14 (cmuxterm-hq#10952): cmux#42880's fast tier, run 43600399789 attempt 5 (triggered by cmux-bot), sat queued
on blacksmith-6vcpu-macos-26 with no runner. The cmux-next Mac routes put a bot re-run on the owned side lane only up
to attempt 3 (#22565: the bot's attempt 4 leaves the side pool for the small overflow); past it they fall through to
`vars.MACOS_RUNNER_26`, a Blacksmith macOS label, ahead of the Blacksmith off switch (vars.CI_BLACKSMITH_MACOS, #43103).
With Blacksmith macOS off nothing serves that label, so every later re-run waited forever.

For every job route in a workflow with an attempt cap (runs-on, and CMUX_NEXT_RUNNER where a job sets it), with
Blacksmith macOS off: a route attempt 1 serves with an owned label never gives a bot re-run (attempts 2 to 6, with
placement run again or carried from attempt 1) a Blacksmith macOS label. With the switch `on` the designed overflow
to Blacksmith past the cap still holds.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
sys.path.insert(0, str(ROOT / "tests"))
from test_seed_derived_data import evaluate, github_context  # noqa: E402
import workflow_jobs  # noqa: E402

SIDE = "glaeda-side-light-xcode-26.6"
SMALL = "blacksmith-6vcpu-macos-26"
BLACKSMITH_MACOS = re.compile(r"blacksmith-\d+vcpu-macos-")
ATTEMPT_CAP = re.compile(r"github\.run_attempt\s*<=\s*\d")
BOT = "cmux-bot[bot]"


def capped_workflows() -> list[Path]:
    """The workflows whose routes cap re-run attempts (`github.run_attempt <= N`)."""
    return sorted(p for p in WORKFLOWS.glob("*.yml") if ATTEMPT_CAP.search(p.read_text()))


def routes(path: Path) -> dict[str, str]:
    jobs = (yaml.safe_load(path.read_text()) or {}).get("jobs") or {}
    out = {}
    for name, job in jobs.items():
        if not isinstance(job, dict):
            continue
        for index, cell in enumerate(workflow_jobs.resolve(job).runs_on_cells or ()):
            if isinstance(cell, str) and "${{" in cell:
                out[f"{path.name} {name}: runs-on[{index}]"] = cell
        runner = (job.get("env") or {}).get("CMUX_NEXT_RUNNER")
        if isinstance(runner, str) and "${{" in runner:
            out[f"{path.name} {name}: CMUX_NEXT_RUNNER"] = runner
    return out


def route_at(expression: str, attempt: int, switch: str, placed: int = 1) -> object:
    """The label a bot re-run's attempt takes on a member's pull request, owned pools on, the side lane set, the
    repository's generic macOS variable naming the small Blacksmith label (what run 43600399789's attempt 5 got), and
    placement last run at attempt `placed` (1: carried into the re-run; the attempt itself: placement ran again)."""
    context = github_context("pull_request", CI_PR_POOL_OWNED="1", CI_SIDE_LANE_RUNNER=SIDE,
                             CI_BLACKSMITH_MACOS=switch, MACOS_RUNNER_26=SMALL)
    context["github"].update(run_attempt=str(attempt), triggering_actor=BOT, repository="manaflow-ai/cmux",
                             event={"pull_request": {"head": {"repo": {"full_name": "manaflow-ai/cmux"}},
                                                     "author_association": "MEMBER", "labels": []}})
    context["needs"] = _PlacedNeeds(placed)
    return evaluate(expression, context)


class _PlacedNeeds(dict):
    """needs.<any job>.outputs.placed_attempt is the attempt placement last ran at; every other output and result is
    empty, as a skipped or carried job reads."""

    def __init__(self, placed):
        super().__init__()
        self.placed = placed

    def get(self, key, default=None):
        return {"outputs": {"placed_attempt": str(self.placed)}, "result": "skipped"}

    def __getitem__(self, key):
        return self.get(key)

    def __contains__(self, key):
        return True


class RerunPastTheAttemptCap(unittest.TestCase):
    maxDiff = None

    def test_the_workflows_with_an_attempt_cap_are_read(self):
        names = {p.name for p in capped_workflows()}
        self.assertIn("cmux-next.yml", names)
        self.assertGreater(sum(len(routes(p)) for p in capped_workflows()), 20)

    def test_a_bot_rerun_past_the_cap_keeps_an_owned_runner_while_blacksmith_macos_is_off(self):
        stranded = {}
        for path in capped_workflows():
            for where, expression in routes(path).items():
                try:
                    first = route_at(expression, 1, "")
                except Exception:  # noqa: BLE001 - an expression this evaluator cannot read is not judged here
                    continue
                if not isinstance(first, str) or not first or BLACKSMITH_MACOS.match(first):
                    continue  # a route that is not owned at attempt 1 is not this check's (forks, Blacksmith jobs)
                for attempt in range(2, 7):
                    found = [(placed, label) for placed in sorted({1, attempt})
                             if isinstance(label := route_at(expression, attempt, "", placed), str)
                             and BLACKSMITH_MACOS.match(label)]
                    if found:
                        stranded[where] = f"attempt 1 {first}, attempt {attempt} (placed at {found[0][0]}) {found[0][1]}"
                        break
        self.assertEqual(stranded, {}, "with vars.CI_BLACKSMITH_MACOS off these routes send a bot re-run past the "
                         "attempt cap to a Blacksmith macOS label nothing serves (cmuxterm-hq#10952): put the read "
                         "behind the switch, (vars.CI_BLACKSMITH_MACOS != 'on' && vars.CI_SIDE_LANE_RUNNER || ...)")

    def test_the_incident_fast_tier_attempt_5_takes_the_side_lane(self):
        """Run 43600399789 attempt 5: the fast tier of cmux#42880."""
        jobs = yaml.safe_load((WORKFLOWS / "cmux-next.yml").read_text())["jobs"]
        fast_tier = workflow_jobs.resolve(jobs["fast-tier"]).runs_on_cells[0]
        self.assertEqual(jobs["fast-tier"]["name"], "cmux-next fast tier")
        self.assertEqual(route_at(fast_tier, 5, ""), SIDE)
        # The switch `on` keeps #22565's overflow: the bot's attempt 4 leaves the side pool for Blacksmith.
        self.assertEqual(route_at(fast_tier, 5, "on"), SMALL)


if __name__ == "__main__":
    unittest.main()

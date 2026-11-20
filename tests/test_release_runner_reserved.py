#!/usr/bin/env python3
"""No pull request job, and no lane push, can take the reserved release runner.

On 2026-11-19 nightly run 44447636260 failed at 03:52Z: cmux-tui tree e3a36f02 was never published, because the
tree publisher (job 135284046642) and run 44455787026's tree preflight sat queued on cmux-gcp-lane-build-x64 while
every runner of that label ran PR CI (guard group, size cap, plan the look). GitHub has no job priority, so a
release job shares a label with PR CI only by waiting behind it. Leo: "when will the nightly come?"; rulebook:
"Nightlies come first on the fleet." (cmuxterm-hq#13909).

So the release path (the nightly-gating jobs of cmux-tui-artifacts.yml, the build package's select/package jobs
and heavy legs it calls, the tree request, the nightly-next tick) takes its own label on attempt 1,
cmux-gcp-nightly-x64 (cmux#46815's nightly-only label, widened from nightly-next to the whole release path), carried
alone by a reserved build-lane runner, and falls back to the shared cmux-gcp-lane-build-x64 on attempt 2. That
reservation
holds only while nothing else can name the label. This test evaluates every `${{ }}` that names it, in every
workflow, as a pull request event and as a lane push, on attempts 1 to 3, and refuses any that can resolve to it.
It also refuses the label in any runner pool (`fromJSON(vars.RUNNER_POOLS)`, which PR jobs read).
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import gh_expressions  # noqa: E402
import workflow_jobs  # noqa: E402
from runs_on_labels import GCP_NIGHTLY_LINUX, declared_pools, resolve_labels  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
RESERVED = GCP_NIGHTLY_LINUX
# The release path: each of these workflows must still route attempt 1 to the reserved label.
RELEASE_WORKFLOWS = ("cmux-tui-artifacts.yml", "cmux-tui-build-package.yml", "cmux-tui-tree-request.yml",
                     "nightly-next-tick.yml", "cloud-vm-image-roll.yml")
# What a pull request or a lane push looks like to an expression. workflow_ref is the tree workflow's (the worst
# case: build package's nightly route also requires it). A pull_request_target run reads the base ref, so the
# expressions cannot tell it from a feat-cmux-next push: no workflow that names the label, nor the tree workflow
# whose workflow_ref unlocks it in the build package, may have a pull request trigger at all.
NOT_RELEASE = (
    ("pull request", "'pull_request'", "'refs/pull/1/merge'"),
    ("lane push", "'push'", "'refs/heads/lane/x'"),
    ("merge queue", "'merge_group'", "'refs/heads/gh-readonly-queue/feat-cmux-next/pr-1'"),
)
TREE_WORKFLOW_REF = "'manaflow-ai/cmux/.github/workflows/cmux-tui-artifacts.yml@refs/heads/x'"


def expressions_naming(label: str) -> list[tuple[str, str]]:
    """(workflow, expression) for each `${{ }}` in a workflow whose text names `label`."""
    found = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        text = path.read_text(encoding="utf-8")
        if label not in text:
            continue
        found.extend((path.name, inner) for inner in gh_expressions.contents(text, strict=False) if label in inner)
    return found


def as_event(expression: str, event: str, ref: str, attempt: int) -> str:
    text = expression.replace("github.run_attempt", str(attempt))
    text = text.replace("github.event_name", event)
    text = text.replace("github.workflow_ref", TREE_WORKFLOW_REF)
    text = re.sub(r"\bgithub\.ref\b", ref, text)
    return "${{ " + text + " }}"


def reachable(expression: str, event: str, ref: str, attempt: int) -> bool:
    labels = resolve_labels(as_event(expression, event, ref, attempt), owner="manaflow-ai",
                            silent=("needs", "inputs"), variables={"LINUX_RUNNER": [""],
                                                                   "CI_CLOUD_OVERFLOW_SAVED": [""]})
    return RESERVED in labels


class ReleaseRunnerReservedTest(unittest.TestCase):
    def test_the_release_path_names_the_reserved_label(self) -> None:
        named = {workflow for workflow, _ in expressions_naming(RESERVED)}
        for workflow in RELEASE_WORKFLOWS:
            with self.subTest(workflow=workflow):
                self.assertIn(workflow, named)

    def test_the_nightly_path_reaches_it_on_attempt_one(self) -> None:
        for workflow, expression in expressions_naming(RESERVED):
            with self.subTest(workflow=workflow, expression=expression[:80]):
                self.assertTrue(
                    reachable(expression, "'workflow_dispatch'", "'refs/heads/feat-cmux-next'", 1)
                    or reachable(expression, "'push'", "'refs/heads/feat-cmux-next'", 1)
                    or reachable(expression, "'schedule'", "'refs/heads/main'", 1))

    def test_no_pull_request_or_lane_push_can_name_it(self) -> None:
        for workflow, expression in expressions_naming(RESERVED):
            for case, event, ref in NOT_RELEASE:
                for attempt in (1, 2, 3):
                    with self.subTest(workflow=workflow, case=case, attempt=attempt, expression=expression[:80]):
                        self.assertFalse(reachable(expression, event, ref, attempt),
                                         f"{RESERVED} is the release path's alone: gate it on the nightly path")

    def test_no_workflow_that_can_name_it_runs_on_a_pull_request(self) -> None:
        names = {workflow for workflow, _ in expressions_naming(RESERVED)} | {"cmux-tui-artifacts.yml"}
        for workflow in sorted(names):
            document = workflow_jobs.document(WORKFLOWS / workflow)
            triggers = document.get("on", document.get(True))
            events = set(triggers) if isinstance(triggers, (dict, list)) else {triggers}
            with self.subTest(workflow=workflow):
                self.assertFalse(events & {"pull_request", "pull_request_target", "merge_group"}, events)

    def test_a_re_run_falls_back_off_it(self) -> None:
        for workflow, expression in expressions_naming(RESERVED):
            with self.subTest(workflow=workflow, expression=expression[:80]):
                self.assertFalse(reachable(expression, "'push'", "'refs/heads/feat-cmux-next'", 2))

    def test_no_runner_pool_holds_it(self) -> None:
        for name, members in declared_pools().items():
            with self.subTest(pool=name):
                self.assertNotIn(RESERVED, members)

    def test_the_detector_refuses_an_ungated_route(self) -> None:
        ungated = f"github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || '{RESERVED}'"
        self.assertTrue(reachable(ungated, "'pull_request'", "'refs/pull/1/merge'", 1))
        attempt_only = f"github.run_attempt == 1 && '{RESERVED}' || 'blacksmith-4vcpu-ubuntu-2404'"
        self.assertTrue(reachable(attempt_only, "'push'", "'refs/heads/lane/x'", 1))


if __name__ == "__main__":
    unittest.main()

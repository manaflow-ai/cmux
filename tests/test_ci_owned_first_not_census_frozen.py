#!/usr/bin/env python3
"""No owned-first job is frozen onto Blacksmith by a one-shot runner census.

On 2026-11-19 cmux-tui artifacts run 44464326281 (feat-cmux-next) put "cmux_next_ daemon tests" on
blacksmith-16vcpu-ubuntu-2404 and it sat queued there from 05:23Z, holding the tree publish the nightly and Leo's tip
build waited for, while the owned GCP runners freed up. tree-preflight's linux-placement step reads the runner census
once (scripts/ci/portable_job_placement.py, REQUIRE_LIVE_CAPACITY): no member was idle at that instant, its output was
empty, and the job's runs-on fell straight through to the Blacksmith pool. GitHub never moves a queued job, so one
reading decided the job's runner for good. Leo: a job already headed for an owned 16 vCPU GCP runner class must not move off GCP onto
Blacksmith.

The rule: a census may choose among owned labels, but it never chooses Blacksmith. On attempt 1 of the nightly path
(feat-cmux-next and nightly-next pushes, dispatches such as cmux-tui-tree-request.yml's) every expression in the tree
workflows that reads a census output still resolves to an owned label when the census answered nothing. The spill to
Blacksmith is attempt 2+, which ci-owned-first-spill.yml (main) starts after a bounded wait on the owned label, so the
wait is bounded and the route is never decided by one instant's reading.

This evaluates every such `${{ }}` with each census output read as '' (the answer of a census that saw no idle
member), and refuses any that can still resolve to a Blacksmith label.
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
from runs_on_labels import BLACKSMITH_LINUX, GCP_LANE_BUILD_LINUX, resolve_labels  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
# The tree workflow and the build package it calls: the jobs a NEXT nightly waits for.
TREE_WORKFLOWS = ("cmux-tui-artifacts.yml", "cmux-tui-build-package.yml")
# Each output a one-shot runner census writes (tree-preflight's linux-placement, linux-build-placement and
# gcp-placement steps), and the build package inputs that carry them.
CENSUS_READS = re.compile(
    r"needs\.tree-preflight\.outputs\.(?:linux_runner|linux_jobs|linux_build_runner|machine_build_runner|gcp_runner"
    r"|gcp_jobs)\b|steps\.(?:linux-placement|linux-build-placement|gcp-placement)\.outputs\.[a-z_]+\b"
    r"|inputs\.linux_(?:build_)?runner\b")
# The nightly-only build-lane runner (cmux#46815); the label the tree preflight takes for a dispatch or nightly-next.
GCP_NIGHTLY_LINUX = "cmux-gcp-nightly-x64"
OWNED = {GCP_LANE_BUILD_LINUX, GCP_NIGHTLY_LINUX, "cmux-fleet-linux-x64"}
TREE_WORKFLOW_REF = "'manaflow-ai/cmux/.github/workflows/cmux-tui-artifacts.yml@refs/heads/feat-cmux-next'"
NIGHTLY_PATH = (
    ("feat-cmux-next push", "'push'", "'refs/heads/feat-cmux-next'"),
    ("tree request", "'workflow_dispatch'", "'refs/heads/feat-cmux-next'"),
    ("nightly-next push", "'push'", "'refs/heads/nightly-next'"),
)
# The owned label each nightly-path case's tree preflight takes, which its daemon tests queue on with an empty census.
PREFLIGHT_LABEL = {
    "feat-cmux-next push": GCP_LANE_BUILD_LINUX,
    "tree request": GCP_NIGHTLY_LINUX,
    "nightly-next push": GCP_NIGHTLY_LINUX,
}
# The label a census that saw an idle fleet member writes for the daemon tests.
FLEET_LINUX = "cmux-fleet-linux-x64"
DAEMON_TESTS = "cmux_next_ daemon tests"


def census_expressions(workflow: str) -> list[str]:
    """Each `${{ }}` of `workflow` that reads a census output."""
    text = (WORKFLOWS / workflow).read_text(encoding="utf-8")
    return [inner for inner in gh_expressions.contents(text, strict=False) if CENSUS_READS.search(inner)]


def labels_with_empty_census(expression: str, event: str, ref: str, attempt: int) -> set:
    """The labels `expression` can take on that event and attempt when every census answered ''."""
    text = CENSUS_READS.sub("''", expression)
    text = text.replace("github.run_attempt", str(attempt)).replace("github.event_name", event)
    text = text.replace("github.workflow_ref", TREE_WORKFLOW_REF)
    text = re.sub(r"\bgithub\.ref\b", ref, text)
    return resolve_labels("${{ " + text + " }}", owner="manaflow-ai", silent=("needs", "inputs", "steps"),
                          variables={"LINUX_RUNNER": [""], "CI_CLOUD_OVERFLOW_SAVED": ["", "1"]})


def labels_with_idle_fleet(expression: str, event: str, ref: str, attempt: int) -> set:
    """The labels `expression` can take when the census saw an idle fleet member and placed the daemon tests on it."""
    text = expression.replace("needs.tree-preflight.outputs.linux_jobs", "' cmux-next-daemon-tests '")
    text = text.replace("needs.tree-preflight.outputs.linux_runner", f"'{FLEET_LINUX}'")
    text = text.replace("github.run_attempt", str(attempt)).replace("github.event_name", event)
    text = re.sub(r"\bgithub\.ref\b", ref, text)
    return resolve_labels("${{ " + text + " }}", owner="manaflow-ai", silent=("needs", "inputs", "steps"),
                          variables={"LINUX_RUNNER": [""], "CI_CLOUD_OVERFLOW_SAVED": ["", "1"]})


def blacksmith(labels: set) -> set:
    return {label for label in labels if isinstance(label, str) and BLACKSMITH_LINUX.fullmatch(label)}


def daemon_tests_runs_on() -> str:
    text = (WORKFLOWS / "cmux-tui-artifacts.yml").read_text(encoding="utf-8")
    block = text.split(f"    name: {DAEMON_TESTS}\n", 1)[1]
    return re.search(r"^    runs-on: (\$\{\{.*\}\})$", block, re.M).group(1)


class OwnedFirstNotCensusFrozenTest(unittest.TestCase):
    def test_the_tree_workflows_read_a_census(self) -> None:
        # The scan below proves nothing if the reads moved or were renamed.
        for workflow in TREE_WORKFLOWS:
            with self.subTest(workflow=workflow):
                self.assertTrue(census_expressions(workflow))

    def test_an_empty_census_never_puts_the_nightly_path_on_blacksmith(self) -> None:
        for workflow in TREE_WORKFLOWS:
            for expression in census_expressions(workflow):
                for case, event, ref in NIGHTLY_PATH:
                    with self.subTest(workflow=workflow, case=case, expression=expression[:100]):
                        got = blacksmith(labels_with_empty_census(expression, event, ref, 1))
                        self.assertFalse(
                            got, f"one census reading sends this to {sorted(got)}: put the owned label for attempt 1 "
                                 "of the nightly path before the Blacksmith pools; the spill is attempt 2+")

    def test_the_daemon_tests_queue_owned_on_attempt_one(self) -> None:
        runs_on = daemon_tests_runs_on()[3:-2]
        for case, event, ref in NIGHTLY_PATH:
            with self.subTest(case=case):
                # Exactly the label the case's tree preflight takes, not any owned label.
                self.assertEqual(labels_with_empty_census(runs_on, event, ref, 1), {PREFLIGHT_LABEL[case]})

    def test_the_daemon_tests_spill_on_attempt_two(self) -> None:
        # The bounded wait's way off a busy owned label: the spill janitor's re-run is attempt 2, which reads the
        # RUNNER_POOLS pool. Since #47803 that pool's members lead with the one-job fleet VMs
        # (cmux-fleet-linux-x64) and then Blacksmith, so attempt 2 leaves the owned build-lane and nightly labels
        # for the pool, never for the label it was stuck on.
        runs_on = daemon_tests_runs_on()[3:-2]
        for case, event, ref in NIGHTLY_PATH:
            with self.subTest(case=case):
                labels = labels_with_empty_census(runs_on, event, ref, 2)
                self.assertTrue(blacksmith(labels))
                self.assertFalse(labels & {GCP_LANE_BUILD_LINUX, GCP_NIGHTLY_LINUX})

    def test_a_lane_push_keeps_its_blacksmith_route(self) -> None:
        # Lane pushes never crowd the owned runners the nightly path queues on.
        labels = labels_with_empty_census(daemon_tests_runs_on()[3:-2], "'push'", "'refs/heads/lane/x'", 1)
        self.assertFalse(labels & {GCP_LANE_BUILD_LINUX, GCP_NIGHTLY_LINUX})

    def test_a_lane_push_reads_the_census_on_every_attempt(self) -> None:
        # The attempt-1 gate on the census is the nightly path's spill alone: an opted-in lane push on attempt 2
        # with an idle fleet member still takes it, as before, not Blacksmith.
        runs_on = daemon_tests_runs_on()[3:-2]
        for attempt in (1, 2):
            with self.subTest(attempt=attempt):
                self.assertEqual(labels_with_idle_fleet(runs_on, "'push'", "'refs/heads/lane/x'", attempt),
                                 {FLEET_LINUX})
        for case, event, ref in NIGHTLY_PATH:
            with self.subTest(case=case):
                self.assertEqual(labels_with_idle_fleet(runs_on, event, ref, 1), {FLEET_LINUX})
                # Attempt 2 of the nightly path is the spill: the census is not read, the pool decides.
                self.assertEqual(labels_with_idle_fleet(runs_on, event, ref, 2),
                                 labels_with_empty_census(runs_on, event, ref, 2))

    def test_no_other_workflow_reads_the_tree_census(self) -> None:
        tree = re.compile(r"needs\.tree-preflight\.outputs\.(?:linux_runner|linux_build_runner|machine_build_runner"
                          r"|gcp_runner)\b")
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            if path.name in TREE_WORKFLOWS:
                continue
            with self.subTest(workflow=path.name):
                self.assertIsNone(tree.search(path.read_text(encoding="utf-8")))

    def test_the_detector_refuses_the_frozen_route(self) -> None:
        # Run 44464326281's daemon-tests runs-on: the census, then straight to the Blacksmith pools.
        frozen = ("github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || contains(needs.tree-preflight."
                  "outputs.linux_jobs, ' cmux-next-daemon-tests ') && needs.tree-preflight.outputs.linux_runner || "
                  "vars.CI_CLOUD_OVERFLOW_SAVED && fromJSON(vars.RUNNER_POOLS).linux_16 || "
                  "fromJSON(vars.RUNNER_POOLS).linux_8")
        self.assertTrue(blacksmith(labels_with_empty_census(frozen, "'push'", "'refs/heads/feat-cmux-next'", 1)))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Every Linux job of cmux-tui-artifacts.yml takes the shared Linux runner set.

On 2026-10-30 from about 05:20Z every cmux-tui artifacts run on feat-cmux-next
sat queued on blacksmith-4vcpu-ubuntu-2404: run 41007923202's tree preflight
waited 4 minutes for a runner, and mark-tree-commits and point-feat-channel,
about 10 seconds of work each, were still queued 15 minutes later. nightly-next
promotion waits on the tree marker those jobs publish, so the NEXT nightly feed
stalled behind them. They read `vars.LINUX_RUNNER || 'blacksmith-4vcpu-...'`
(and 2 vCPU for two others), a size outside the declared set.

Leo's rule (2026-10-28): no job names one runner size; every job resolves its
runner from one declared set (the GCP pool, then the Blacksmith size and failover
.github/runners.json linux_sizes measured for the job), with stall-aware failover. In this workflow that is the expression the
publish jobs already use:

    !startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER
    || vars.CI_CLOUD_OVERFLOW_SAVED && '<failover>' || '<size>'

A non-Blacksmith pool named by LINUX_RUNNER wins; otherwise the job's size, and its
failover while the overflow switch (scripts/ci/cloud_overflow_switch.py) has failed
over. A Blacksmith size the switch or anyone writes into LINUX_RUNNER (it has
named blacksmith-4vcpu-ubuntu-2404) is ignored, so it can never pin these jobs.

This evaluates every Linux runs-on of the workflow for each variable state and
checks the answer is a member of that set. A fork keeps GitHub-hosted Ubuntu.
"""

from __future__ import annotations

import itertools
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

from blacksmith_linux_sizes import failover_label, size_label  # noqa: E402
from runs_on_labels import pool_members, resolve_labels  # noqa: E402
import workflow_jobs  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"
BIG = "blacksmith-32vcpu-ubuntu-2404"
SMALL = "blacksmith-16vcpu-ubuntu-2404"


def blacksmith_set(job: str) -> set[str]:
    """Members of the pools selected for this job's size and failover."""
    labels = (size_label(WORKFLOW.name, job), failover_label(WORKFLOW.name, job))
    return {member for label in labels for member in pool_members(pool_for_label(label))}


def pool_for_label(label: str) -> str:
    """The declared pool corresponding to a measured Blacksmith label."""
    return f"linux_{re.search(r'[0-9]+', label).group()}"


def resolved(runs_on: str, owner: str, linux_runner: str, overflow: str, trusted: str,
             darwin_cross: str = "") -> set[str]:
    """Resolve the route through RUNNER_POOLS, keeping picker contexts silent."""
    return resolve_labels(
        runs_on,
        owner=owner,
        variables={
            "LINUX_RUNNER": [linux_runner],
            "CI_CLOUD_OVERFLOW_SAVED": [overflow],
            "CI_TRUSTED_RUNNER": [trusted],
            "LINUX_RUNNER_DARWIN_CROSS": [darwin_cross],
        },
        silent=("needs",),
    )
# A non-Blacksmith Linux pool LINUX_RUNNER may name (the GCP pool, say).
POOL = "gcp-linux-pool"
# The overflow switch writes GitHub-hosted Ubuntu into LINUX_RUNNER when it fails over.
HOSTED = "ubuntu-24.04"
# The one job with its own override: the Darwin cross-compile shadow.
DARWIN_CROSS_JOB = "macos-cross-shadow"
DARWIN_CROSS = "darwin-cross-pool"
# The owned GCP pool the nightly path's attempt 1 takes first (cmux-tui-artifacts.yml's jobs: comment).
OWNED = "cmux-fleet-linux-x64"
# Jobs with a placement or override of their own: the daemon tests (linux-placement) and the shadow.
OWN_ROUTE_JOBS = ("cmux-next-daemon-tests", DARWIN_CROSS_JOB)
OVERFLOW_RECORD = '{"probe":"blacksmith-4vcpu-ubuntu-2404"}'
# The short jobs that sat queued on 2026-10-30; each must stay in the set.
SHORT_JOBS = (
    "reject-untrusted-pin-ref",
    "tree-preflight",
    "tree-owner-wait",
    "darwin-fallback-plan",
    "publish-ref-notice",
    "sentry-dsyms",
    "publish-tree-tested",
    "point-feat-channel",
    "point-machine-channel",
    "mark-tree-commits",
    "request-nightly-next",
    "notify-unpublished-tree",
)
LINUX_RUNNER_VALUES = (
    "",
    "blacksmith-2vcpu-ubuntu-2404",
    "blacksmith-4vcpu-ubuntu-2404",
    SMALL,
    BIG,
    POOL,
    HOSTED,
)
TRUSTED_RUNNER_VALUES = ("", "ubuntu-24.04", "blacksmith-4vcpu-ubuntu-2404")


def linux_routes() -> list[tuple[str, str]]:
    """(job, route) for every Linux route: each matrix cell of a runs-on (`${{ matrix.runner }}` read as its
    values) is a route of its own. A runs-on with a matrix value nothing resolves fails, never drops out."""
    routes = []
    for name, job in yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"].items():
        cells = workflow_jobs.runs_on_cells(job)
        if cells is None:
            raise AssertionError(f"{WORKFLOW.name}#{name}: runs-on has a matrix value nothing resolves")
        routes.extend((name, runs_on) for runs_on in cells if "ubuntu" in runs_on)
    return routes


def context(owner: str, linux_runner: str, overflow: str, trusted: str, darwin_cross: str = "") -> dict:
    return {
        "github.repository_owner": owner,
        "github.repository": f"{owner}/cmux",
        "github.event_name": "push",
        "github.ref": "refs/heads/feat-cmux-next",
        "github.run_attempt": 1,
        "vars.LINUX_RUNNER": linux_runner,
        "vars.CI_CLOUD_OVERFLOW_SAVED": overflow,
        "vars.CI_TRUSTED_RUNNER": trusted,
        "vars.LINUX_RUNNER_DARWIN_CROSS": darwin_cross,
    }


class CmuxTuiArtifactsLinuxRunnerSetTest(unittest.TestCase):
    def test_the_short_jobs_are_linux_jobs_of_this_workflow(self) -> None:
        names = {name for name, _ in linux_routes()}
        for name in SHORT_JOBS:
            with self.subTest(job=name):
                self.assertIn(name, names)

    def test_every_linux_job_resolves_into_the_shared_set(self) -> None:
        routes = linux_routes()
        for (name, runs_on), linux_runner, overflow, trusted in itertools.product(
            routes, LINUX_RUNNER_VALUES, ("", OVERFLOW_RECORD), TRUSTED_RUNNER_VALUES
        ):
            labels = resolved(runs_on, "manaflow-ai", linux_runner, overflow, trusted)
            # A non-Blacksmith LINUX_RUNNER wins; a job that does not read it (the daemon
            # tests) stays on Blacksmith. The nightly path's attempt 1 takes the owned pool.
            allowed = (blacksmith_set(name) | ({linux_runner} if linux_runner in (POOL, HOSTED) else set())
                       | ({OWNED} if name not in OWN_ROUTE_JOBS else set()))
            with self.subTest(job=name, linux_runner=linux_runner, overflow=bool(overflow), trusted=trusted):
                self.assertTrue(labels <= allowed, labels - allowed)

    def test_the_overflow_switch_moves_every_linux_job_to_the_other_size(self) -> None:
        for name, runs_on in linux_routes():
            for linux_runner in ("", "blacksmith-4vcpu-ubuntu-2404", SMALL):
                with self.subTest(job=name, linux_runner=linux_runner):
                    size = size_label(WORKFLOW.name, name)
                    failover = failover_label(WORKFLOW.name, name)
                    size_pool = pool_for_label(size)
                    failover_pool = pool_for_label(failover)
                    self.assertIn(f"fromJSON(vars.RUNNER_POOLS).{size_pool}", runs_on)
                    self.assertIn(f"fromJSON(vars.RUNNER_POOLS).{failover_pool}", runs_on)
                    self.assertIn(size, resolved(runs_on, "manaflow-ai", linux_runner, "", ""))
                    self.assertIn(failover, resolved(runs_on, "manaflow-ai", linux_runner, OVERFLOW_RECORD, ""))
                    self.assertEqual(pool_members(size_pool)[0], size)
                    self.assertEqual(pool_members(failover_pool)[0], failover)

    def test_only_the_darwin_cross_shadow_reads_its_override(self) -> None:
        for name, runs_on in linux_routes():
            for linux_runner in ("", POOL):
                with self.subTest(job=name, linux_runner=linux_runner):
                    labels = resolved(runs_on, "manaflow-ai", linux_runner, "", "", DARWIN_CROSS)
                    if name == DARWIN_CROSS_JOB:
                        self.assertIn(DARWIN_CROSS, labels)
                    else:
                        self.assertNotIn(DARWIN_CROSS, labels)

    def test_the_nightly_path_takes_the_owned_pool_first(self) -> None:
        # 2026-11-18: tree preflights waited 11-56+ min on blacksmith-2vcpu and -4vcpu behind PR CI under the
        # Blacksmith vCPU cap, and tree request run 44375949434 for the nightly-next head sat queued at its first job.
        # Coordinator: "nightly-gating jobs must not wait behind PR CI on capped Blacksmith. Route every job the
        # nightly path needs (tree request/preflight/publish, nightly.yml legs) to owned fleet runners first, with
        # Blacksmith only as overflow." Every Linux job of the tree path (this workflow's, the build package's
        # select/package jobs when this workflow calls it, the tree request) resolves to the owned pool alone on
        # attempt 1 of a nightly-path run, whatever LINUX_RUNNER holds; a re-run, and a lane push, keep Blacksmith.
        routes = [(WORKFLOW.name, name, runs_on) for name, runs_on in linux_routes() if name not in OWN_ROUTE_JOBS]
        for workflow in ("cmux-tui-build-package.yml", "cmux-tui-tree-request.yml"):
            jobs = yaml.load((WORKFLOW.parent / workflow).read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]
            routes.extend((workflow, name, job["runs-on"]) for name, job in jobs.items()
                          if "vars.LINUX_RUNNER" in str(job.get("runs-on", "")))
        self.assertGreater(len(routes), len(SHORT_JOBS) + 2)
        nightly = {"event": "'push'", "ref": "'refs/heads/feat-cmux-next'", "attempt": "1"}
        cases = (
            ("feat-cmux-next push", nightly, True),
            ("nightly-next push", {**nightly, "ref": "'refs/heads/nightly-next'"}, True),
            ("dispatch", {**nightly, "event": "'workflow_dispatch'", "ref": "'refs/heads/feat-cmux-next'"}, True),
            ("re-run", {**nightly, "attempt": "2"}, False),
            ("lane push", {**nightly, "ref": "'refs/heads/lane/x'"}, False),
        )
        for workflow, name, runs_on in routes:
            for case, values, owned in cases:
                if workflow == "cmux-tui-tree-request.yml" and case == "lane push":
                    continue  # it runs only as a feat-cmux-next dispatch
                text = runs_on.replace("github.run_attempt", values["attempt"])
                text = text.replace("github.event_name", values["event"])
                text = re.sub(r"\bgithub\.ref\b", values["ref"], text)
                text = text.replace("github.workflow_ref",
                                    "'manaflow-ai/cmux/.github/workflows/cmux-tui-artifacts.yml@refs/heads/x'")
                for linux_runner in LINUX_RUNNER_VALUES:
                    labels = resolve_labels(text, owner="manaflow-ai", silent=("needs", "inputs"), variables={
                        "LINUX_RUNNER": [linux_runner], "CI_CLOUD_OVERFLOW_SAVED": [""]})
                    with self.subTest(workflow=workflow, job=name, case=case, linux_runner=linux_runner):
                        if owned:
                            self.assertEqual(labels, {OWNED})
                        else:
                            self.assertNotIn(OWNED, labels)

    def test_a_fork_keeps_github_hosted_ubuntu(self) -> None:
        for name, runs_on in linux_routes():
            with self.subTest(job=name):
                self.assertEqual(resolved(runs_on, "someone-else", "", "", ""), {"ubuntu-24.04"})


if __name__ == "__main__":
    unittest.main()

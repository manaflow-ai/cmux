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
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

from test_ci_tui_routes_avoid_nightly_label import route  # noqa: E402
from blacksmith_linux_sizes import failover_label, size_label  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"
BIG = "blacksmith-32vcpu-ubuntu-2404"
SMALL = "blacksmith-16vcpu-ubuntu-2404"


def blacksmith_set(job: str) -> set[str]:
    """The job's Blacksmith size and its failover, from .github/runners.json linux_sizes (Leo, 2026-11-01: "we
    should have resized a long-ass time ago")."""
    return {size_label(WORKFLOW.name, job), failover_label(WORKFLOW.name, job)}
# A non-Blacksmith Linux pool LINUX_RUNNER may name (the GCP pool, say).
POOL = "gcp-linux-pool"
# The overflow switch writes GitHub-hosted Ubuntu into LINUX_RUNNER when it fails over.
HOSTED = "ubuntu-24.04"
# The one job with its own override: the Darwin cross-compile shadow.
DARWIN_CROSS_JOB = "macos-cross-shadow"
DARWIN_CROSS = "darwin-cross-pool"
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


def linux_routes() -> dict[str, str]:
    jobs = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]
    return {
        name: job["runs-on"]
        for name, job in jobs.items()
        if "runs-on" in job and "ubuntu" in job["runs-on"]
    }


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
        routes = linux_routes()
        for name in SHORT_JOBS:
            with self.subTest(job=name):
                self.assertIn(name, routes)

    def test_every_linux_job_resolves_into_the_shared_set(self) -> None:
        routes = linux_routes()
        for (name, runs_on), linux_runner, overflow, trusted in itertools.product(
            routes.items(), LINUX_RUNNER_VALUES, ("", OVERFLOW_RECORD), TRUSTED_RUNNER_VALUES
        ):
            label = route(runs_on, context("manaflow-ai", linux_runner, overflow, trusted))
            # A non-Blacksmith LINUX_RUNNER wins; a job that does not read it (the daemon
            # tests) stays on Blacksmith.
            allowed = blacksmith_set(name) | ({linux_runner} if linux_runner in (POOL, HOSTED) else set())
            with self.subTest(job=name, linux_runner=linux_runner, overflow=bool(overflow), trusted=trusted):
                self.assertIn(label, allowed)

    def test_the_overflow_switch_moves_every_linux_job_to_the_other_size(self) -> None:
        for name, runs_on in linux_routes().items():
            for linux_runner in ("", "blacksmith-4vcpu-ubuntu-2404", SMALL):
                with self.subTest(job=name, linux_runner=linux_runner):
                    self.assertEqual(route(runs_on, context("manaflow-ai", linux_runner, "", "")),
                                     size_label(WORKFLOW.name, name))
                    self.assertEqual(route(runs_on, context("manaflow-ai", linux_runner, OVERFLOW_RECORD, "")),
                                     failover_label(WORKFLOW.name, name))

    def test_only_the_darwin_cross_shadow_reads_its_override(self) -> None:
        for name, runs_on in linux_routes().items():
            for linux_runner in ("", POOL):
                with self.subTest(job=name, linux_runner=linux_runner):
                    label = route(runs_on, context("manaflow-ai", linux_runner, "", "", DARWIN_CROSS))
                    if name == DARWIN_CROSS_JOB:
                        self.assertEqual(label, DARWIN_CROSS)
                    else:
                        self.assertNotEqual(label, DARWIN_CROSS)

    def test_a_fork_keeps_github_hosted_ubuntu(self) -> None:
        for name, runs_on in linux_routes().items():
            with self.subTest(job=name):
                self.assertEqual(route(runs_on, context("someone-else", "", "", "")), "ubuntu-24.04")


if __name__ == "__main__":
    unittest.main()

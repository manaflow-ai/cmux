#!/usr/bin/env python3
"""Cron and maintenance workflows keep one queued run; delivery workflows are never deduped.

After the 2026-11-11 20:17Z-21:38Z Actions stall, 683 runs sat queued over about 40 workflows, the
queue janitor and the owned-pool rescue among them. scripts/ci/cron_concurrency.py holds the rule;
this is its detector (docs/ci/cron-concurrency.md):

1. every workflow parses;
2. a schedule or workflow_run workflow without a group shared by those runs fails;
3. a nightly, DEV, promote, release or publish workflow that gains cancel-in-progress or a shared
   cron group fails;
4. the trivial pull request checks are listed, and each cancels its superseded runs.
"""

from __future__ import annotations

import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cron_concurrency as cc  # noqa: E402


def write(root: Path, name: str, text: str) -> cc.Workflow:
    folder = root / ".github" / "workflows"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / name
    path.write_text(textwrap.dedent(text).lstrip(), encoding="utf-8")
    return cc.load(path)


class RepositoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflows = cc.workflows(ROOT)

    def test_every_workflow_parses(self):
        folder = ROOT / ".github" / "workflows"
        self.assertEqual(len(self.workflows), len([*folder.glob("*.yml"), *folder.glob("*.yaml")]))
        for workflow in self.workflows:
            self.assertIsInstance(workflow.doc.get("jobs"), dict, workflow.name)

    def test_every_cron_and_maintenance_workflow_keeps_one_queued_run(self):
        problems = [p for w in self.workflows for p in cc.cron_findings(w)]
        self.assertEqual(problems, [], "\n".join(problems))

    def test_no_delivery_or_publish_workflow_gained_cancel_or_a_shared_cron_group(self):
        problems = [p for w in self.workflows for p in cc.excluded_findings(w)]
        self.assertEqual(problems, [], "\n".join(problems))

    def test_trivial_checks_cancel_their_superseded_runs(self):
        trivial = cc.trivial_checks(self.workflows)
        print("trivial pull request checks:", ", ".join(trivial), file=sys.stderr)
        self.assertIn("risk-tier.yml", trivial)
        problems = [p for w in self.workflows for p in cc.supersede_findings(w)]
        self.assertEqual(problems, [], "\n".join(problems))

    def test_the_named_build_and_publish_workflows_are_excluded(self):
        for name in ("nightly.yml", "nightly-sign.yml", "nightly-next-tick.yml", "cmux-next-dev-daily.yml",
                     "cloud-vm-image-promote.yml", "release.yml", "stable-next.yml", "stable-next-rollback.yml",
                     "ios-testflight.yml", "ios-app-store.yml", "ios-appstore-upload.yml", "update-homebrew.yml",
                     "dogfood-artifact-publish.yml", "cmux-tui-release-delivery.yml", "sdk-publish-npm.yml",
                     "resume-nightly-notarization.yml", "repair-nightly-appcast-content-types.yml"):
            self.assertTrue(cc.is_excluded(name), name)
        for name in ("ci-queue-janitor.yml", "ci-owned-pool-rescue.yml", "risk-tier.yml",
                     "signing-keychain-macos.yml"):
            self.assertFalse(cc.is_excluded(name), name)

    def test_every_allowance_still_names_a_file(self):
        names = {w.name for w in self.workflows}
        for table in (cc.PER_SOURCE_RUN, cc.SOURCE_KEYED, cc.CANCEL_FALSE_ON_SCHEDULE, cc.TRIVIAL_NO_SUPERSEDE):
            self.assertEqual(sorted(set(table) - names), [])
        for name, _owner in [*cc.EXCLUDED_SHARED, *cc.EXCLUDED_CANCEL]:
            self.assertIn(name, names)

    def test_the_janitor_collapses_only_interchangeable_runs(self):
        self.assertTrue(cc.collapsible_run(".github/workflows/ci-queue-janitor.yml", "workflow_run"))
        self.assertTrue(cc.collapsible_run(".github/workflows/ci-owned-pool-rescue.yml", "schedule"))
        for path, event in (("ci-owned-pool-rescue.yml", "workflow_run"), ("ci-guard-attribution.yml", "workflow_run"),
                            ("nightly.yml", "schedule"), ("ios-testflight.yml", "schedule"),
                            ("ci-queue-janitor.yml", "workflow_dispatch"), ("ci.yml", "pull_request")):
            self.assertFalse(cc.collapsible_run(path, event), (path, event))

    def test_per_source_run_entries_are_still_needed(self):
        by_name = {w.name: w for w in self.workflows}
        for name in list(cc.PER_SOURCE_RUN):
            saved = cc.PER_SOURCE_RUN.pop(name)
            try:
                self.assertTrue(cc.cron_findings(by_name[name]), f"{name} no longer needs PER_SOURCE_RUN")
            finally:
                cc.PER_SOURCE_RUN[name] = saved


class RuleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cmux-cron-concurrency-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def test_a_cron_without_a_group_fails(self):
        workflow = write(self.root, "sweep.yml", """
            on:
              schedule: [{cron: "*/10 * * * *"}]
            jobs:
              sweep: {runs-on: ubuntu-24.04, steps: [{run: x}]}
            """)
        [problem] = cc.cron_findings(workflow)
        self.assertIn("no concurrency group", problem)

    def test_a_cron_keyed_per_run_fails(self):
        workflow = write(self.root, "sweep.yml", """
            on:
              schedule: [{cron: "*/10 * * * *"}]
            concurrency:
              group: sweep-${{ github.run_id }}
              cancel-in-progress: false
            jobs:
              sweep: {runs-on: ubuntu-24.04, steps: [{run: x}]}
            """)
        [problem] = cc.cron_findings(workflow)
        self.assertIn("unique per run", problem)

    def test_a_cron_that_cancels_a_running_sweep_fails(self):
        workflow = write(self.root, "sweep.yml", """
            on:
              schedule: [{cron: "*/10 * * * *"}]
            concurrency: {group: sweep, cancel-in-progress: true}
            jobs:
              sweep: {runs-on: ubuntu-24.04, steps: [{run: x}]}
            """)
        [problem] = cc.cron_findings(workflow)
        self.assertIn("cut a running scheduled run short", problem)

    def test_dispatches_with_inputs_may_keep_their_own_group(self):
        workflow = write(self.root, "sweep.yml", """
            on:
              schedule: [{cron: "*/10 * * * *"}]
              workflow_dispatch:
                inputs:
                  target: {required: true, type: string}
            concurrency:
              group: sweep-${{ github.event_name == 'schedule' && 'cron' || github.run_id }}
              cancel-in-progress: ${{ github.event_name == 'pull_request' }}
            jobs:
              sweep: {runs-on: ubuntu-24.04, steps: [{run: x}]}
            """)
        self.assertEqual(cc.cron_findings(workflow), [])

    def test_a_workflow_run_maintenance_workflow_keyed_per_source_run_fails(self):
        workflow = write(self.root, "rescue.yml", """
            on:
              workflow_run: {workflows: [CI], types: [completed]}
            concurrency:
              group: rescue-${{ github.event.workflow_run.id }}
            jobs:
              rescue: {runs-on: ubuntu-24.04, steps: [{run: x}]}
            """)
        [problem] = cc.cron_findings(workflow)
        self.assertIn("on workflow_run", problem)

    def test_a_job_that_never_runs_on_schedule_needs_no_group(self):
        workflow = write(self.root, "gate.yml", """
            on:
              schedule: [{cron: "17 * * * *"}]
              pull_request_target: {}
            jobs:
              check:
                if: github.event_name == 'pull_request_target'
                concurrency: {group: "gate-${{ github.event.pull_request.number }}", cancel-in-progress: true}
                runs-on: ubuntu-24.04
                timeout-minutes: 5
                steps: [{run: x}]
              expire:
                if: github.event_name != 'pull_request_target'
                concurrency: {group: gate-expire, cancel-in-progress: false}
                runs-on: ubuntu-24.04
                timeout-minutes: 5
                steps: [{run: x}]
            """)
        self.assertEqual(cc.cron_findings(workflow), [])
        self.assertEqual(cc.supersede_findings(workflow), [])

    def test_a_nightly_that_gains_cancel_in_progress_fails(self):
        workflow = write(self.root, "nightly-x.yml", """
            on:
              schedule: [{cron: "0 6 * * *"}]
            concurrency:
              group: nightly-x-${{ github.run_id }}
              cancel-in-progress: true
            jobs:
              build: {runs-on: macos-15, steps: [{run: x}]}
            """)
        [problem] = cc.excluded_findings(workflow)
        self.assertIn("never cancelled", problem)

    def test_a_nightly_that_gains_a_shared_cron_group_fails(self):
        workflow = write(self.root, "nightly-x.yml", """
            on:
              schedule: [{cron: "0 6 * * *"}]
            concurrency: {group: nightly-x, cancel-in-progress: false}
            jobs:
              build: {runs-on: macos-15, steps: [{run: x}]}
            """)
        [problem] = cc.excluded_findings(workflow)
        self.assertIn("never dedupe a delivery run", problem)
        self.assertEqual(cc.cron_findings(workflow), [], "the cron rule never asks a delivery run to share")

    def test_a_release_or_publish_build_is_excluded_too(self):
        for name in ("release-mac.yml", "foo-publish-npm.yml", "stable-next-x.yml", "ios-testflight-x.yml"):
            workflow = write(self.root, name, """
                on:
                  workflow_run: {workflows: [CI], types: [completed]}
                concurrency: {group: shared-publish, cancel-in-progress: true}
                jobs:
                  publish: {runs-on: ubuntu-24.04, steps: [{run: x}]}
                """)
            self.assertEqual(len(cc.excluded_findings(workflow)), 2, name)

    def test_a_trivial_check_without_supersede_fails(self):
        workflow = write(self.root, "lint-title.yml", """
            on: [pull_request]
            jobs:
              lint: {runs-on: ubuntu-24.04, timeout-minutes: 5, steps: [{run: x}]}
            """)
        self.assertEqual(cc.trivial_checks([workflow]), ["lint-title.yml"])
        [problem] = cc.supersede_findings(workflow)
        self.assertIn("no concurrency group", problem)

    def test_a_trivial_check_keyed_by_pull_request_passes(self):
        workflow = write(self.root, "lint-title.yml", """
            on: [pull_request]
            concurrency:
              group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
              cancel-in-progress: true
            jobs:
              lint: {runs-on: ubuntu-24.04, timeout-minutes: 5, steps: [{run: x}]}
            """)
        self.assertEqual(cc.supersede_findings(workflow), [])

    def test_a_long_or_macos_check_is_not_trivial(self):
        long = write(self.root, "long.yml", """
            on: [pull_request]
            jobs:
              t: {runs-on: ubuntu-24.04, timeout-minutes: 30, steps: [{run: x}]}
            """)
        mac = write(self.root, "mac.yml", """
            on: [pull_request]
            jobs:
              t: {runs-on: macos-15, timeout-minutes: 5, steps: [{run: x}]}
            """)
        self.assertEqual(cc.trivial_checks([long, mac]), [])


class ReplayTests(unittest.TestCase):
    """scripts/ci/backlog_drain_replay.py applies the same policy to a feed snapshot."""

    def test_the_policy_collapses_crons_drops_superseded_heads_and_serves_trivial_first(self):
        import datetime as dt

        import backlog_drain_replay as replay

        t0 = dt.datetime(2026, 11, 11, 20, 0, tzinfo=dt.timezone.utc)

        def run(i, workflow, event, minute, *, sha="a", prs=(), trivial=False, start=None):
            r = replay.Run(i, workflow, event, "main" if not prs else "topic", sha, t0 + dt.timedelta(minutes=minute),
                           start, False, "pool", tuple(prs))
            r.trivial = trivial
            return r

        runs = [run(1, "ci-queue-janitor.yml", "schedule", 0), run(2, "ci-queue-janitor.yml", "schedule", 1),
                run(3, "ci-queue-janitor.yml", "schedule", 2), run(4, "nightly.yml", "schedule", 0),
                run(5, "nightly.yml", "schedule", 1), run(6, "ci.yml", "pull_request", 0, sha="a", prs=(7,)),
                run(7, "ci.yml", "pull_request", 1, sha="b", prs=(7,)),
                run(8, "risk-tier.yml", "pull_request_target", 3, prs=(9,), trivial=True)]
        for r in runs:
            r.collapsible = cc.collapsible_run(r.workflow, r.event)
        rates = {"pool": 1.0}
        resume = t0 + dt.timedelta(minutes=5)
        window = (t0, resume)
        base = replay.replay(runs, rates, resume=resume, policy=False, pre_depth=0, window=window)
        after = replay.replay(runs, rates, resume=resume, policy=True, pre_depth=0, window=window)
        self.assertEqual(base["dropped"], {})
        self.assertEqual(after["dropped"], {"cron collapsed": 2, "superseded head": 1}, "nightly runs are kept")
        self.assertLess(after["trivial"]["p50"], base["trivial"]["p50"])
        self.assertLess(after["drained"], base["drained"])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""A CI repair workflow never queues behind the queue it drains.

The janitors and rescues cancel, shed and re-run the CI backlog. On 2026-11-19 they were queued on the same
starved Blacksmith labels as about 28,700 jobs (#47644 moved them to cmux-fleet-linux-x64). On 2026-11-20 that
shared label held about 1,856 queued jobs, oldest about 591 min: backlog-rescue run 44679805477 sat queued from
05:15Z with no runner, held its concurrency group, and the passes after it were cancelled with no job, so
#47559's required check (run 44604684959) was never rescued.

So each repair job leads with a label no other workflow asks for, `cmux-gcp-repair-jit-x64`. The fleet
reconciler serves it ahead of every PR label and keeps idle runners warm on it, so a repair pass starts however
deep the backlog is. This test is that pattern's detector: a repair job off the reserved label, or any other
workflow on it, fails.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
REPAIR_LABEL = "cmux-gcp-repair-jit-x64"
# (workflow file, job) for every job that sheds or rescues the CI queue.
REPAIR_JOBS = {
    ("ci-queue-janitor.yml", "sweep"),
    ("ci-stale-run-janitor.yml", "janitor"),
    ("ci-hosted-backlog-rescue.yml", "backlog"),
    ("ci-hosted-light-rescue.yml", "rescue"),
    ("ci-cla-quota-rerun.yml", "cla-quota-rerun"),
    ("ci-owned-pool-rescue.yml", "rescue"),
}
FORK_BRANCH = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
# The reserved operand, right after the fork branch: an optional schedule-or-dispatch gate (the per-run passes of
# ci-cla-quota-rerun and ci-owned-pool-rescue keep their own selector so a backlog's events cannot fill the label),
# the CI_REPAIR_SKIP_FLEET switch, then the literal.
REPAIR_OPERAND = re.compile(
    r"(?:\(github\.event_name == 'schedule' \|\| github\.event_name == 'workflow_dispatch'(?: && !inputs\.run_id)?\) && )?"
    r"vars\.CI_REPAIR_SKIP_FLEET != '1' && '" + re.escape(REPAIR_LABEL) + r"' \|\| "
)


def load(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text())


def runs_on(job: dict) -> str:
    value = job.get("runs-on", "")
    return " ".join(value) if isinstance(value, list) else str(value)


class RepairLabelTest(unittest.TestCase):
    def test_every_repair_job_leads_with_the_reserved_label(self) -> None:
        for name, job_id in sorted(REPAIR_JOBS):
            with self.subTest(workflow=name, job=job_id):
                value = runs_on(load(name)["jobs"][job_id])
                self.assertTrue(value.startswith(FORK_BRANCH), value)
                self.assertRegex(value[len(FORK_BRANCH):], "^" + REPAIR_OPERAND.pattern)

    def test_no_repair_job_leads_with_the_shared_fleet_label(self) -> None:
        for name, job_id in sorted(REPAIR_JOBS):
            with self.subTest(workflow=name, job=job_id):
                self.assertNotIn("'cmux-fleet-linux-x64'", runs_on(load(name)["jobs"][job_id]))

    def test_only_repair_jobs_ask_for_the_reserved_label(self) -> None:
        # The label stays reserved: a PR or build job on it would put the backlog back in front of the repairs.
        found = set()
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            jobs = (yaml.safe_load(path.read_text()) or {}).get("jobs") or {}
            for job_id, job in jobs.items():
                if isinstance(job, dict) and REPAIR_LABEL in runs_on(job):
                    found.add((path.name, job_id))
        self.assertEqual(found, REPAIR_JOBS)

    def test_the_switch_still_restores_the_previous_selector(self) -> None:
        for name, job_id in sorted(REPAIR_JOBS):
            with self.subTest(workflow=name, job=job_id):
                rest = runs_on(load(name)["jobs"][job_id])[len(FORK_BRANCH):]
                after = REPAIR_OPERAND.sub("", rest, count=1)
                self.assertNotIn(REPAIR_LABEL, after)
                self.assertRegex(after, r"'blacksmith-\dvcpu-ubuntu-2404' }}$")

    def test_the_operand_refuses_a_shared_or_variable_label(self) -> None:
        for bad in ("vars.CI_REPAIR_SKIP_FLEET != '1' && 'cmux-fleet-linux-x64' || ",
                    "vars.CI_REPAIR_SKIP_FLEET != '1' && vars.REPAIR_LABEL || ",
                    "'cmux-gcp-repair-jit-x64' || "):
            with self.subTest(operand=bad):
                self.assertIsNone(REPAIR_OPERAND.match(bad))


if __name__ == "__main__":
    unittest.main()

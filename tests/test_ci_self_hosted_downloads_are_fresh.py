#!/usr/bin/env python3
"""A job on a self-hosted selector downloads into a directory nothing earlier left behind.

The self-hosted Linux selectors (vars.LINUX_RUNNER, the RUNNER_POOLS pools, self-hosted) hand a job a
persistent worker: its workspace survives from one job to the next. A job that downloads an artifact into a
relative directory (`path: dist`) and never checks out first finds whatever an earlier job left there, so an
exact-files check fails on a stale file, or a publish step ships it. Only these places are fresh:

- the runner's temp directory (`${{ runner.temp }}/...`, emptied by the runner before each job);
- a directory a step created for the job (`${{ steps.<id>.outputs.<name> }}`);
- the workspace after `actions/checkout` (its default clean removes untracked files), unless `clean: false`.

Every download-artifact step of a job on a self-hosted selector must write to one of them. Hosted and Blacksmith
runners are one-shot VMs and are not held to this. Run: python3 tests/test_ci_self_hosted_downloads_are_fresh.py
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path
from typing import Any, Mapping

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import workflow_jobs  # noqa: E402

WORKFLOWS = ROOT / ".github/workflows"
SELF_HOSTED = re.compile(r"vars\.|RUNNER_POOLS|self-hosted", re.IGNORECASE)
FRESH_PATH = re.compile(r"^\$\{\{\s*(runner\.temp|steps\.[A-Za-z0-9_-]+\.outputs\.[A-Za-z0-9_-]+)\s*\}\}")


def on_self_hosted_selector(job: Mapping[str, Any]) -> bool:
    return bool(SELF_HOSTED.search(workflow_jobs.runs_on(job)))


def stale_downloads(job: Mapping[str, Any]) -> list[str]:
    """The download-artifact steps of one job whose output directory can hold an earlier job's files."""
    found = []
    cleaned = False
    for step in job.get("steps") or []:
        if not isinstance(step, dict):
            continue
        uses = str(step.get("uses", ""))
        options = step.get("with") if isinstance(step.get("with"), dict) else {}
        if uses.startswith("actions/checkout"):
            cleaned = str(options.get("clean", "true")).lower() != "false"
        elif uses.startswith("actions/download-artifact"):
            path = str(options.get("path", "")).strip()
            if not FRESH_PATH.match(path) and not cleaned:
                found.append(f"{step.get('name') or uses}: path {path or '(the workspace)'!r}")
    return found


def problems(documents: Mapping[str, Mapping[str, Any]]) -> list[str]:
    found = []
    for workflow, document in documents.items():
        for name, job in workflow_jobs.jobs(document).items():
            if on_self_hosted_selector(job):
                found += [f"{workflow} {name}: {why}" for why in stale_downloads(job)]
    return found


def load_all() -> dict[str, dict]:
    return {path.name: workflow_jobs.document(path) for path in sorted(WORKFLOWS.glob("*.y*ml"))}


def fixture(runs_on: str, steps: list[dict]) -> dict:
    return {"jobs": {"j": {"runs-on": runs_on, "steps": steps}}}


POOL = "${{ vars.LINUX_RUNNER || fromJSON(vars.RUNNER_POOLS).linux_4 }}"
DOWNLOAD = "actions/download-artifact@v4"
CHECKOUT = "actions/checkout@v6"


class SelfHostedDownloads(unittest.TestCase):
    def test_the_checked_in_workflows_download_into_fresh_directories(self) -> None:
        found = problems(load_all())
        self.assertEqual(found, [], "a self-hosted job downloads into a directory an earlier job may have used; "
                         "use ${{ runner.temp }}/<name> (see this file's docstring):\n  " + "\n  ".join(found))

    def test_a_relative_download_on_a_pool_runner_is_named(self) -> None:
        for path in ("dist", "./dist", "${{ github.workspace }}/dist", ""):
            with self.subTest(path=path):
                document = fixture(POOL, [{"uses": DOWNLOAD, "with": {"name": "a", "path": path}}])
                self.assertEqual(len(problems({"w.yml": document})), 1)

    def test_a_download_under_the_runner_temp_or_a_step_made_directory_passes(self) -> None:
        for path in ("${{ runner.temp }}/linux-build", "${{ steps.fresh.outputs.dir }}"):
            with self.subTest(path=path):
                document = fixture(POOL, [{"uses": DOWNLOAD, "with": {"name": "a", "path": path}}])
                self.assertEqual(problems({"w.yml": document}), [])

    def test_a_checkout_before_the_download_cleans_the_workspace(self) -> None:
        steps = [{"uses": CHECKOUT}, {"uses": DOWNLOAD, "with": {"name": "a", "path": "dist"}}]
        self.assertEqual(problems({"w.yml": fixture(POOL, steps)}), [])
        after = [steps[1], steps[0]]
        self.assertEqual(len(problems({"w.yml": fixture(POOL, after)})), 1)
        kept = [{"uses": CHECKOUT, "with": {"clean": False}}, steps[1]]
        self.assertEqual(len(problems({"w.yml": fixture(POOL, kept)})), 1)

    def test_a_one_shot_runner_is_not_held_to_it(self) -> None:
        for runs_on in ("ubuntu-24.04", "blacksmith-4vcpu-ubuntu-2404"):
            document = fixture(runs_on, [{"uses": DOWNLOAD, "with": {"name": "a", "path": "dist"}}])
            self.assertEqual(problems({"w.yml": document}), [])

    def test_every_download_of_a_job_is_checked(self) -> None:
        steps = [{"uses": DOWNLOAD, "with": {"name": "a", "path": "${{ runner.temp }}/a"}},
                 {"uses": DOWNLOAD, "with": {"name": "b", "path": "b"}}]
        self.assertEqual(len(problems({"w.yml": fixture(POOL, steps)})), 1)


if __name__ == "__main__":
    unittest.main()

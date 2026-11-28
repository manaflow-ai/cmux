#!/usr/bin/env python3
"""No workflow step runs a script from this repository before its job has checked the repository out.

A self-hosted runner reuses its workspace, so a repository script can still be there from the previous job and
run fine, then fail on a fresh or wiped workspace. On 2026-11-27 23:35Z to 2026-11-28 03:05Z the `cmux-next generated
files (Mac fallback)` job's first step, `Log the Mac fallback`, ran `bash scripts/ci/cmux-next-steps/
generated-files-linux.sh fallback` ahead of Checkout. Moving steps into scripts/ci/cmux-next-steps/ to keep
cmux-next.yml under GitHub's size limit (tests/cmux_next_step_text.py) is what put a repo script there. On every
fleet Mac with a fresh workspace, about a dozen of them, bash exited 127 within 7 to 52 s:
about two thirds of NOW's mac_pr_setup refusals that night.

A job's steps up to its first `actions/checkout` may run only commands that do not live in the repository.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
# A repository path the step runs: `bash scripts/...`, `./scripts/...`, `python3 -I scripts/...`, a bare `scripts/x.sh`.
REPO_SCRIPT = re.compile(r"(?:^|[\s;&|(])(?:\./)?(scripts|tools)/[A-Za-z0-9_./-]+\.(?:sh|py|mjs|js|ts)\b")


def is_checkout(step: dict) -> bool:
    return str(step.get("uses") or "").startswith("actions/checkout@")


def before_checkout(steps: list) -> list[tuple[int, dict]]:
    found = []
    for index, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        if is_checkout(step):
            break
        found.append((index, step))
    else:
        return []  # a job that never checks out runs no repository script, and this test is not where that is held
    return found


def job_failures(where: str, job: dict) -> list[str]:
    failures = []
    for index, step in before_checkout(job.get("steps") or []):
        # A shell comment that names a script (`# scripts/ci/needs_verdict.py SHELL_RULE, copied verbatim`) runs nothing.
        run = "\n".join(line.split(" #", 1)[0] for line in str(step.get("run") or "").splitlines()
                         if not line.lstrip().startswith("#"))
        hit = REPO_SCRIPT.search(run)
        if hit and not step.get("working-directory"):
            failures.append(f"{where}: step {index + 1} ({step.get('name') or step.get('id') or 'unnamed'}) runs "
                            f"{hit.group(0).strip()!r} before the job's actions/checkout; a fresh workspace has no "
                            f"such file (bash exits 127). Move the step after Checkout.")
    return failures


def workflow_jobs():
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for name, job in (document.get("jobs") or {}).items():
            if isinstance(job, dict):
                yield f"{path.name}:{name}", job


class RepoScriptsAfterCheckout(unittest.TestCase):
    def test_no_job_runs_a_repo_script_before_checkout(self) -> None:
        found = [f for where, job in workflow_jobs() for f in job_failures(where, job)]
        self.assertEqual(found, [], "\n".join(found))

    def test_the_mac_fallback_log_before_checkout_is_caught(self) -> None:
        job = {"steps": [
            {"name": "Log the Mac fallback", "run": "bash scripts/ci/cmux-next-steps/generated-files-linux.sh fallback"},
            {"name": "Checkout", "uses": "actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803"},
            {"name": "Select Xcode", "run": "./scripts/select-ci-xcode.sh"},
        ]}
        self.assertEqual(len(job_failures("w:j", job)), 1)
        self.assertIn("Log the Mac fallback", job_failures("w:j", job)[0])

    def test_steps_after_checkout_and_non_repo_commands_pass(self) -> None:
        job = {"steps": [
            {"name": "hook", "run": "'/Users/cmux/actions-runner-glaeda-1/glaeda-hooks/job-started.sh'"},
            {"name": "home", "run": 'home="$RUNNER_TEMP/acpmux-home"\nrm -rf "$home"'},
            {"name": "verdict", "run": "f() {  # scripts/ci/needs_verdict.py SHELL_RULE, copied verbatim\n  :\n}"},
            {"name": "Checkout", "uses": "actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803"},
            {"name": "Log", "run": "bash scripts/ci/cmux-next-steps/generated-files-linux.sh fallback"},
        ]}
        self.assertEqual(job_failures("w:j", job), [])


if __name__ == "__main__":
    sys.exit(unittest.main())

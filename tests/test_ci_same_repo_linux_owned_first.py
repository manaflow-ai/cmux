#!/usr/bin/env python3
"""A same-repository Linux job names the persistent runner pool (cmux-linux) on attempt 1, not Blacksmith.

On 2026-11-21 the controller feed showed 47,907 jobs / 93,045 runner-minutes in 24 hours on
blacksmith-2vcpu and blacksmith-8vcpu while the owned persistent Linux pool (label `cmux-linux`, which every
cmux-runner-pool-* runner carries with cmux-fleet-linux-x64) sat idle. feat-cmux-next's workflows read
`fromJSON(vars.RUNNER_POOLS).linux|linux_2|linux_8|linux_16|linux_32`, and main's runner_pools.py writes that
variable from main's .github/runners.json, whose Linux pools are Blacksmith-only, so every one of those jobs
went to Blacksmith on attempt 1. Main moved its own jobs in #47956 ("let this thing run, we can clean up at some
later point, let our caches do work, install stuff properly"); Leo, on the minutes: "the goal is ofc to have that
214x reduction in minutes asap so we dont have to use so much stuff".

The rule: for every workflow, every runs-on (and every matrix `runner` / `runs_on` / `linux_runner` value that
feeds one), evaluated for a same-repository push and a same-repository pull_request on attempt 1, resolves to no
Blacksmith Linux x64 label, unless the line or its job is one of:
- an ephemeral-only route: a read of the ephemeral_only linux_4 pool (write tokens, ephemeral-required, fork code
  without a fork branch; tests/test_ci_ephemeral_pool_readers.py), a `# ephemeral-required` line, or the
  CI_TRUSTED_RUNNER selector (merge-gating checks on an ephemeral VM);
- a job that holds a secret other than GITHUB_TOKEN, or runs under a deployment environment: no variable or
  persistent machine reaches what holds a key (tests/test_ci_fork_runner_routing.py);
- an entry in ALLOWED below, each with its reason.

A fork pull request's branch is not checked here: it must still come first, to an ephemeral label
(tests/test_ci_fork_runner_routing.py). Expressions are evaluated by tests/runs_on_labels.py with every unknown
context free (it may be falsy), RUNNER_POOLS read from .github/runners.json, LINUX_RUNNER as a Blacksmith label
(what the overflow pickers fell back to) and CI_CLOUD_OVERFLOW_SAVED either way.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

import workflow_jobs  # noqa: E402
from runs_on_labels import resolve_labels  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
# Blacksmith Linux x64 (arm64 has no owned pool and stays on Blacksmith).
BLACKSMITH_LINUX_X64 = re.compile(r"blacksmith-[0-9]+vcpu-ubuntu-[0-9]{4}")
JOB_HEADER = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$")
# runs-on, and the matrix / output values that feed one.
RUNNER_KEY = re.compile(r"^\s*(?:- )?(runs-on|runner|runs_on|linux_runner):\s*(.*?)\s*$")
# `# frozen-label: RUNNER_POOLS.linux_4` is the same route after #54437 froze the picker to its label
# (scripts/ci/check_runs_on_pools.py EPHEMERAL_MARK reads the same marks).
EPHEMERAL_ROUTE = re.compile(r"RUNNER_POOLS\)\.linux_(?:4|arm64)\b|ephemeral-required|frozen-label:|vars\.CI_TRUSTED_RUNNER")
SAME_REPOSITORY_EVENTS = ("push", "pull_request")
VARIABLES = {"LINUX_RUNNER": ["blacksmith-4vcpu-ubuntu-2404"], "CI_CLOUD_OVERFLOW_SAVED": ["1"]}

# (workflow, job) -> why its attempt-1 route may still reach Blacksmith Linux for a same-repository run.
ALLOWED: dict[tuple[str, str], str] = {
    ("cloudflare-relay.yml", "cloudflare-relay"): (
        "`cargo install worker-build` builds openssl-sys, and the owned Linux image has no OpenSSL headers and no "
        "sudo to add them (docs: root-step-on-a-no-sudo-runner); it moves once the image carries them"),
    ("cmux-tui-artifacts.yml", "cmux-next-daemon-tests"): (
        "owned-first census route (tests/test_ci_owned_first_not_census_frozen.py): an owned GCP label on the "
        "nightly path, the pool only past it; its spill design is its own change"),
    ("cmux-tui-build-package.yml", "plan-build"): (
        "tree build package: owned GCP labels first on the nightly path, census-routed "
        "(tests/test_ci_owned_first_not_census_frozen.py); its spill design is its own change"),
    ("cmux-tui-build-package.yml", "package"): (
        "tree build package: owned GCP labels first on the nightly path, census-routed "
        "(tests/test_ci_owned_first_not_census_frozen.py); its spill design is its own change"),
    ("cmux-tui-build-package.yml", "build"): (
        "matrix.runner comes from the census-routed plan-build; its attempt-2 small-size bump reads linux_16"),
    ("cmux-tui-testbox-warmup.yml", "cmux-tui-rust"): (
        "warms a Blacksmith testbox (environment blacksmith-testbox-trusted): it must run on Blacksmith"),
    ("fast-checks.yml", "checks"): (
        "credentialed: the generator leaves it on the ephemeral pool (tests/test_ci_runner_set.py EPHEMERAL_POOL_JOBS)"),
}


def runner_lines(text: str):
    """(line number, job id, value) for each runner key inside `jobs:`."""
    job, in_jobs = None, False
    for number, line in enumerate(text.splitlines(), 1):
        if line.startswith("jobs:"):
            in_jobs = True
            continue
        if in_jobs and line and not line.startswith((" ", "#")):
            in_jobs = False
        if not in_jobs:
            continue
        header = JOB_HEADER.match(line)
        if header:
            job = header.group(1)
            continue
        match = RUNNER_KEY.match(line)
        if match and job and match.group(2):
            yield number, job, match.group(1), match.group(2)


def strip_comment(value: str) -> str:
    """The value without a trailing YAML comment (`# ...` after the closing `}}` or a plain label)."""
    if value.startswith("${{"):
        end = value.rfind("}}")
        return value[:end + 2] if end != -1 else value
    return value.split(" #", 1)[0].strip().strip("'\"")


def same_repository(value: str, event: str) -> str:
    """`value` as a same-repository `event` run on attempt 1 sees it."""
    # x['y-z'] reads x.y_z: an unknown context either way, in a form the evaluator's tokenizer reads.
    value = re.sub(r"\['([A-Za-z_][A-Za-z0-9_-]*)'\]", lambda m: "." + m.group(1).replace("-", "_"), value)
    value = value.replace("github.event.pull_request.head.repo.full_name", "'manaflow-ai/cmux'")
    value = re.sub(r"\bgithub\.repository\b(?![_.])", "'manaflow-ai/cmux'", value)
    value = value.replace("github.event_name", f"'{event}'")
    return value.replace("github.run_attempt", "1")


def blacksmith_on_attempt_one(value: str) -> set[str]:
    """The Blacksmith Linux x64 labels `value` can take for a same-repository push or pull_request, attempt 1."""
    value = strip_comment(value)
    if not value.startswith("${{"):
        return {value} if BLACKSMITH_LINUX_X64.fullmatch(value) else set()
    found: set[str] = set()
    for event in SAME_REPOSITORY_EVENTS:
        for label in resolve_labels(same_repository(value, event), variables=VARIABLES):
            if isinstance(label, str) and BLACKSMITH_LINUX_X64.fullmatch(label):
                found.add(label)
    return found


def holds_key(job) -> bool:
    if job is None:
        return False
    return bool(workflow_jobs.secret_names(job) - {"GITHUB_TOKEN"}) or workflow_jobs.environment_spec(job) is not None


def violations(workflow: str, text: str, jobs: dict) -> list[str]:
    out = []
    for number, job_id, key, value in runner_lines(text):
        if EPHEMERAL_ROUTE.search(value) or (workflow, job_id) in ALLOWED or holds_key(jobs.get(job_id)):
            continue
        labels = blacksmith_on_attempt_one(value)
        if labels:
            out.append(f"{workflow}:{number} {job_id} {key} reaches {sorted(labels)} on attempt 1: name 'cmux-linux'")
    return out


class SameRepositoryLinuxOwnedFirstTests(unittest.TestCase):
    def test_no_same_repository_linux_job_starts_on_blacksmith(self) -> None:
        problems = []
        for path in sorted(WORKFLOWS.glob("*.yml")):
            text = path.read_text(encoding="utf-8")
            problems += violations(path.name, text, workflow_jobs.jobs(path))
        self.assertEqual(problems, [], "\n".join(problems))

    def test_allowlist_names_jobs_that_exist(self) -> None:
        for workflow, job in ALLOWED:
            with self.subTest(job=f"{workflow}#{job}"):
                self.assertIn(job, workflow_jobs.jobs(WORKFLOWS / workflow))

    def test_detector_refuses_todays_pool_reads(self) -> None:
        owner = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'"
        fork = ("github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != "
                "github.repository && 'blacksmith-4vcpu-ubuntu-2404'")
        refused = {
            "linux_2 pool": "${{ " + owner + " || fromJSON(vars.RUNNER_POOLS).linux_2 }}",
            "overflow selector": "${{ " + owner + " || " + fork + " || vars.CI_CLOUD_OVERFLOW_SAVED && "
                                 "fromJSON(vars.RUNNER_POOLS).linux_16 || fromJSON(vars.RUNNER_POOLS).linux_8 }}",
            "LINUX_RUNNER picker": "${{ " + owner + " || vars.LINUX_RUNNER || fromJSON(vars.RUNNER_POOLS).linux }}",
            "fork-wrapped pool": "${{ " + owner + " || (github.event_name == 'pull_request' && "
                                 "github.event.pull_request.head.repo.full_name != github.repository && "
                                 "'blacksmith-2vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux_2) }}",
            "Blacksmith literal": "${{ " + owner + " || 'blacksmith-8vcpu-ubuntu-2404' }}",
            "bare Blacksmith label": "blacksmith-2vcpu-ubuntu-2404 # a comment",
            "owned picker falling through": "${{ " + owner + " || vars.CI_LINUX_GATE_OWNED_RUNNER || "
                                            "fromJSON(vars.RUNNER_POOLS).linux_16 }}",
        }
        for name, value in refused.items():
            with self.subTest(case=name):
                self.assertTrue(blacksmith_on_attempt_one(value), value)
                text = f"jobs:\n  j:\n    runs-on: {value}\n    steps:\n      - run: true\n"
                self.assertEqual(len(violations("x.yml", text, {"j": {}})), 1)

    def test_detector_accepts_the_persistent_pool_after_the_fork_branch(self) -> None:
        owner = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'"
        fork = ("github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != "
                "github.repository && 'blacksmith-4vcpu-ubuntu-2404'")
        accepted = (
            "${{ " + owner + " || 'cmux-linux' }}",
            "${{ " + owner + " || " + fork + " || 'cmux-linux' }}",
            "${{ " + owner + " || vars.CI_LINUX_GATE_OWNED_RUNNER || 'cmux-linux' }} # owned gate first",
            "${{ " + owner + " || needs.x.outputs.ok == 'true' && (" + fork + " || 'cmux-linux') || 'macos-26' }}",
        )
        for value in accepted:
            with self.subTest(value=value):
                self.assertEqual(blacksmith_on_attempt_one(value), set())

    def test_exemptions_are_the_ephemeral_routes_and_key_holders(self) -> None:
        pooled = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux_8 }}"
        ephemeral = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux_4 }}"
        text = "jobs:\n  j:\n    runs-on: {}\n    steps:\n      - run: true\n"
        self.assertEqual(violations("x.yml", text.format(ephemeral), {"j": {}}), [])
        self.assertEqual(violations("x.yml", text.format(pooled + " # ephemeral-required: write token"), {"j": {}}), [])
        secret_job = {"steps": [{"run": "true", "env": {"K": "${{ secrets.SOME_KEY }}"}}]}
        self.assertEqual(violations("x.yml", text.format(pooled), {"j": secret_job}), [])
        token_job = {"steps": [{"run": "true", "env": {"T": "${{ secrets.GITHUB_TOKEN }}"}}]}
        self.assertEqual(len(violations("x.yml", text.format(pooled), {"j": token_job})), 1)


if __name__ == "__main__":
    unittest.main()

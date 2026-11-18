#!/usr/bin/env python3
"""A pull_request run may not join the tailnet through OIDC unless a repo variable admits it.

`tailscale/github-action` with `audience` joins through a federated Tailscale
identity, and the identity names the events it trusts. #42973 added a
pull_request trigger to ios-e2e.yml, whose identity admits only
workflow_dispatch. Every PR run then failed at "Join tailnet" before any test
ran, a red with no base run to excuse it (cmux#43753). #43854 gated the
tailnet jobs on the repo variable IOS_E2E_PR_TAILNET.

So in a workflow triggered by pull_request or pull_request_target, every job
whose tailscale step sets `audience` must:
  1. keep fork PRs away from the identity: its `if` compares
     github.event.pull_request.head.repo.full_name with github.repository;
  2. stay off for pull requests until someone widens the identity: its `if`, or
     the step env of a job it needs (directly or transitively), reads a repo
     variable named `vars.<NAME>_PR_TAILNET`. Set that variable to true only
     after the identity admits `repo:<owner>/<repo>:pull_request`.

Run with workflow files as arguments to check only those files, for example a
version from history.
"""

from __future__ import annotations

import re
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"

PR_EVENTS = {"pull_request", "pull_request_target"}
FORK_GUARD = re.compile(
    r"github\.event\.pull_request\.head\.repo\.full_name\s*==\s*github\.repository"
)
PR_OPT_IN = re.compile(r"vars\.[A-Z0-9_]*_PR_TAILNET\b")


def triggers(document: dict) -> set[str]:
    # PyYAML reads the bare key `on` as boolean True.
    on = document.get("on", document.get(True))
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return {str(event) for event in on}
    if isinstance(on, dict):
        return {str(event) for event in on}
    return set()


def joins_tailnet_with_oidc(job: dict) -> bool:
    for step in job.get("steps") or []:
        if not isinstance(step, dict):
            continue
        uses = str(step.get("uses", ""))
        if uses.startswith("tailscale/github-action@") and (step.get("with") or {}).get("audience"):
            return True
    return False


def needs_of(job: dict) -> list[str]:
    needs = job.get("needs") or []
    return [needs] if isinstance(needs, str) else list(needs)


def reads_opt_in(job: dict) -> bool:
    if PR_OPT_IN.search(str(job.get("if", ""))):
        return True
    envs = [job.get("env") or {}] + [
        (step.get("env") or {}) for step in job.get("steps") or [] if isinstance(step, dict)
    ]
    return any(PR_OPT_IN.search(str(value)) for env in envs for value in env.values())


def gated_by_opt_in(name: str, jobs: dict, seen: set[str] | None = None) -> bool:
    seen = seen if seen is not None else set()
    if name in seen or name not in jobs:
        return False
    seen.add(name)
    job = jobs[name]
    if reads_opt_in(job):
        return True
    return any(gated_by_opt_in(need, jobs, seen) for need in needs_of(job))


def violations(paths: list[Path]) -> list[str]:
    failures: list[str] = []
    for path in paths:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict) or not (triggers(document) & PR_EVENTS):
            continue
        jobs = document.get("jobs") or {}
        for name, job in jobs.items():
            if not isinstance(job, dict) or not joins_tailnet_with_oidc(job):
                continue
            if not FORK_GUARD.search(str(job.get("if", ""))):
                failures.append(
                    f"{path.name} job {name} joins the tailnet through OIDC on pull requests without "
                    "the same-repo guard (github.event.pull_request.head.repo.full_name == "
                    "github.repository) in its `if`; fork PRs must never reach the identity"
                )
            if not gated_by_opt_in(name, jobs):
                failures.append(
                    f"{path.name} job {name} joins the tailnet through OIDC on pull requests with no "
                    "vars.*_PR_TAILNET opt-in in its `if` or a needed job's env; the federated "
                    "identity refuses events it was not issued for, so gate PR runs off until it "
                    "admits pull_request"
                )
    return failures


def main(argv: list[str]) -> int:
    paths = [Path(arg) for arg in argv] or sorted(WORKFLOWS.glob("*.y*ml"))
    failures = violations(paths)
    if failures:
        print("pull_request tailnet joins the OIDC identity may refuse:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(f"{len(paths)} workflows checked: every pull_request OIDC tailnet join is opt-in and same-repo only")
    return 0


GATED_ROUTE = {
    "runs-on": "ubuntu-24.04",
    "steps": [{"run": "true", "env": {"PR_TAILNET": "${{ vars.IOS_E2E_PR_TAILNET }}"}}],
}
UNGATED_ROUTE = {"runs-on": "ubuntu-24.04", "steps": [{"run": "true"}]}
SAME_REPO = (
    "github.event_name != 'pull_request' || "
    "github.event.pull_request.head.repo.full_name == github.repository"
)


def tailnet_job(condition: str, needs: object = "route") -> dict:
    return {
        "runs-on": "ubuntu-24.04",
        "needs": needs,
        "if": condition,
        "steps": [
            {
                "uses": "tailscale/github-action@d1b6cd204f8dceda5b3eaad7f1f767be390056cd",
                "with": {"oauth-client-id": "x", "audience": "y"},
            }
        ],
    }


class TailnetPullRequestGateTests(unittest.TestCase):
    def check(self, on: object, jobs: dict) -> list[str]:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "x.yml"
            path.write_text(yaml.safe_dump({"name": "x", "on": on, "jobs": jobs}), encoding="utf-8")
            return violations([path])

    def test_current_tree_passes(self) -> None:
        self.assertEqual(violations(sorted(WORKFLOWS.glob("*.y*ml"))), [])

    def test_ungated_pull_request_join_is_rejected(self) -> None:
        failures = self.check(
            {"pull_request": None, "workflow_dispatch": None},
            {"route": UNGATED_ROUTE, "backend": tailnet_job(SAME_REPO)},
        )
        self.assertEqual(len(failures), 1)
        self.assertIn("_PR_TAILNET", failures[0])

    def test_missing_fork_guard_is_rejected(self) -> None:
        failures = self.check(["pull_request"], {"route": GATED_ROUTE, "backend": tailnet_job("always()")})
        self.assertEqual(len(failures), 1)
        self.assertIn("same-repo", failures[0])

    def test_gate_through_a_transitive_need_passes(self) -> None:
        jobs = {
            "route": GATED_ROUTE,
            "backend": tailnet_job(SAME_REPO),
            "mac": tailnet_job(SAME_REPO, needs=["backend"]),
        }
        self.assertEqual(self.check("pull_request", jobs), [])

    def test_gate_in_job_if_passes(self) -> None:
        condition = f"vars.CHIEF_PR_TAILNET == 'true' && ({SAME_REPO})"
        self.assertEqual(self.check("pull_request_target", {"a": tailnet_job(condition, needs=[])}), [])

    def test_dispatch_only_workflow_is_not_checked(self) -> None:
        jobs = {"route": UNGATED_ROUTE, "backend": tailnet_job("always()")}
        self.assertEqual(self.check({"workflow_dispatch": None, "push": None}, jobs), [])

    def test_stored_key_join_is_not_checked(self) -> None:
        job = tailnet_job("always()")
        job["steps"][0]["with"] = {"authkey": "${{ secrets.TS_AUTHKEY }}"}
        self.assertEqual(self.check("pull_request", {"a": job}), [])


if __name__ == "__main__":
    if len(sys.argv) == 1:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(TailnetPullRequestGateTests)
        if not unittest.TextTestRunner().run(suite).wasSuccessful():
            sys.exit(1)
    sys.exit(main(sys.argv[1:]))

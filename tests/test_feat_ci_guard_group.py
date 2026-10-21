#!/usr/bin/env python3
"""ci-guards.yml's `ci` group runs for feat-cmux-next pull requests and pushes.

ci.yml's "CI fast guards" job runs the group (scripts/ci/guards-local.sh, among them
tests/test_preflight_trust.py and every workflow lint) but skips pull requests into
feat-cmux-next, and ci-guards.yml's routed matrix leaves the group to it. So nothing ran it
for the branch: test_preflight_trust.py errored in all five tests there unseen (#23006).
"""
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"


def triggers(workflow: dict) -> dict:
    found = workflow.get("on", workflow.get(True)) or {}
    return found if isinstance(found, dict) else {name: {} for name in ([found] if isinstance(found, str) else found)}


def covers_feat(trigger) -> bool:
    if trigger is None:
        return True
    branches = (trigger or {}).get("branches")
    return not (trigger or {}).get("paths") and (branches is None or "feat-cmux-next" in branches)


def runs_ci_group(job: dict) -> bool:
    """The job runs guards-local.sh's default set (the `ci` group) and nothing keeps it off feat-cmux-next."""
    condition = str(job.get("if", ""))
    if "feat-cmux-next" in condition and "!=" in condition:
        return False
    for step in job.get("steps") or []:
        command = str(step.get("run", ""))
        if "scripts/ci/guards-local.sh" in command and "--group" not in command and "--list" not in command:
            return True
    return False


class FeatRunsTheCiGuardGroup(unittest.TestCase):
    def test_a_workflow_runs_the_ci_group_on_feat_pull_requests_and_pushes(self):
        for event in ("pull_request", "push"):
            with self.subTest(event=event):
                found = []
                for path in sorted(WORKFLOWS.glob("*.yml")):
                    workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
                    on = triggers(workflow)
                    if event not in on or not covers_feat(on[event]):
                        continue
                    found += [f"{path.name}:{name}" for name, job in (workflow.get("jobs") or {}).items()
                              if runs_ci_group(job)]
                self.assertTrue(found, f"no {event} workflow for feat-cmux-next runs scripts/ci/guards-local.sh")


class TheBaseIsCheckedOutOnPullRequests(unittest.TestCase):
    """On pull_request, github.event.before is null, and the expression language's loose `!=` turns null and the
    all-zeros sha into 0, so `github.event.before != '000…'` was false. The base checkout was skipped, and every base
    red counted as the change's (24 reds on every feat PR, run 39562873067). The zero test must be on the chosen sha."""

    def test_the_zero_sha_test_is_on_the_sha_it_checks_out(self):
        workflow = yaml.safe_load((WORKFLOWS / "cmux-next-guards.yml").read_text(encoding="utf-8"))
        steps = [s for job in workflow["jobs"].values() for s in job.get("steps") or []
                 if s.get("name") == "Checkout the base"]
        self.assertEqual(len(steps), 1)
        step = steps[0]
        chosen = step["with"]["ref"].removeprefix("${{").removesuffix("}}").strip()
        self.assertIn(f"({chosen}) != '{'0' * 40}'", step["if"])
        self.assertNotIn(f"github.event.before != '{'0' * 40}'", step["if"])


if __name__ == "__main__":
    unittest.main()

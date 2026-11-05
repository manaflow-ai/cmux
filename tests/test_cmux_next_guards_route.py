#!/usr/bin/env python3
"""feat-cmux-next pull requests and pushes run the release-notary guard group.

Pushes run it in nightly-guards (judged at the tip); pull requests run it in the CI guard group,
compared with their base.

ci.yml skips its guards for feat-cmux-next and has no push trigger, so the
nightly, notarization and nightly-next publication tests ran nowhere on the
branch nightly-next ships from (tests/test_nightly_cmux_tui_resolve.py stayed
red there unseen).
"""

import json
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


def callers():
    for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
        workflow = yaml.safe_load(path.read_text())
        triggers = workflow.get(True) or workflow.get("on") or {}
        for job in (workflow.get("jobs") or {}).values():
            if job.get("uses") == "./.github/workflows/ci-guards.yml":
                yield path.name, triggers, job


class CmuxNextGuardsRouteTests(unittest.TestCase):
    def test_feat_cmux_next_runs_release_notary_on_pushes(self):
        found = []
        for name, triggers, job in callers():
            if not isinstance(triggers, dict):
                continue
            push = triggers.get("push") or {}
            if "feat-cmux-next" not in (push.get("branches") or []) or push.get("paths"):
                continue
            inputs = job.get("with") or {}
            if "release-notary" in json.loads(inputs.get("linux_guard_test_groups", "[]")) and "true" in str(
                inputs.get("linux_guard_tests")
            ):
                found.append(name)
        self.assertTrue(found, "no workflow runs the release-notary guards for feat-cmux-next pushes")

    def test_a_pull_request_runs_release_notary_against_its_base(self):
        # Run on its own, every pull request was red while the branch was (833 of 1656 runs in the 24 h to
        # 2026-11-05 08:24Z). A pull request runs the group in the CI guard group's head-and-base comparison
        # (guards_new_reds.py), which fails on a step red on the change and not on its base; a push still runs
        # nightly-guards, judged at its tip, so a base red fails the push that caused it.
        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next-guards.yml").read_text())
        triggers = workflow.get(True) or workflow.get("on") or {}
        pull = triggers.get("pull_request") or {}
        self.assertIn("feat-cmux-next", pull.get("branches") or [])
        self.assertFalse(pull.get("paths"), "a path filter would let a pull request skip the release guards")
        jobs = workflow["jobs"]
        self.assertIn("github.event_name != 'pull_request'", jobs["nightly-guards"]["if"])
        group = jobs["ci-guard-group"]
        self.assertEqual(group["if"], "${{ !cancelled() }}")
        steps = {step.get("name"): step for step in group["steps"]}
        run = steps["Run the ci guard group and the routed groups"]
        self.assertEqual(run["env"]["EVENT_NAME"], "${{ github.event_name }}")
        script = run["run"]
        self.assertIn('if [ "$EVENT_NAME" = pull_request ]; then\n  groups=(--group ci --group release-notary)', script)
        calls = [line for line in script.splitlines() if "scripts/ci/guards-local.sh" in line]
        self.assertEqual(len(calls), 2, calls)
        for call in calls:
            self.assertIn('"${groups[@]}"', call)
        self.assertIn('python3 scripts/ci/guards_new_reds.py "$RUNNER_TEMP/guards-head.json" "$RUNNER_TEMP/guards-base.json"',
                      script)

    def test_release_notary_has_ghostty_next_for_the_toolchain_notices(self):
        # toolchain_notices.py fails on a missing ghostty-next/build.zig.zon by
        # design; the guard checkout has no submodules.
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-guards.yml").read_text())
        steps = workflow["jobs"]["workflow-guard-tests"]["steps"]
        init = [
            s for s in steps
            if "release-notary" in str(s.get("if", "")) and "git submodule update --init --depth 1 ghostty-next" in s.get("run", "")
        ]
        self.assertTrue(init, "release-notary must initialize ghostty-next before the license compliance test")
        names = [s.get("name") for s in steps]
        self.assertLess(names.index(init[0]["name"]), names.index("Validate app bundle license compliance"))


if __name__ == "__main__":
    unittest.main()

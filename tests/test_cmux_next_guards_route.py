#!/usr/bin/env python3
"""feat-cmux-next pull requests and pushes run the release-notary guard group.

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
    def test_feat_cmux_next_runs_release_notary_on_pull_requests_and_pushes(self):
        found = []
        for name, triggers, job in callers():
            if not isinstance(triggers, dict):
                continue
            events = {
                event
                for event in ("pull_request", "push")
                if "feat-cmux-next" in ((triggers.get(event) or {}).get("branches") or [])
                and not (triggers.get(event) or {}).get("paths")
            }
            if events != {"pull_request", "push"}:
                continue
            inputs = job.get("with") or {}
            if "release-notary" in json.loads(inputs.get("linux_guard_test_groups", "[]")) and "true" in str(
                inputs.get("linux_guard_tests")
            ):
                found.append(name)
        self.assertTrue(found, "no workflow runs the release-notary guards for feat-cmux-next pull requests and pushes")

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

#!/usr/bin/env python3
"""A pull request head's push builds no cmux-tui tree unless something asked for it.

Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period."

PR-branch pushes were 343 runs and 29.8k runner-min a day of cmux-tui artifacts (11-22 21Z..11-23 21Z,
25.8 per merged PR), three ~28-min target builds a head. unreviewed_verdict now supersedes a current head
of a non-trunk branch unless its commit has the Cmux-Daemon-Tests: run trailer or a cmux-next dispatch
asked for it (a dispatch of the artifacts workflow itself is never superseded). The hot verify rust layer
dispatches it for the head it looks at. CMUX_TUI_BRANCH_ON_REQUEST=0 restores the open-PR-head rule.

Run: python3 tests/test_cmux_tui_branch_on_request.py
"""

from __future__ import annotations

import importlib.util
import os
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("sup", ROOT / "scripts/ci/cmux_tui_superseded_push.py")
sup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sup)

SHA = "a" * 40
REF = "refs/heads/fix/some-pr"


class BranchOnRequest(unittest.TestCase):
    def run_verdict(self, env: dict, trailer: bool = False, pr_head: bool = True, dispatches: int = 0):
        calls = []

        def api(path):
            calls.append(path)
            if path.startswith("actions/workflows/cmux-next.yml/runs"):
                return 200, {"total_count": dispatches, "workflow_runs": []}
            return 200, []

        with mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "o/r", **env}, clear=False), \
                mock.patch.object(sup, "branch_head", return_value=SHA), \
                mock.patch.object(sup, "asks_for_daemon_tests", return_value=trailer), \
                mock.patch.object(sup, "has_pull_request_head", return_value=pr_head), \
                mock.patch.object(sup, "api", side_effect=api):
            return sup.verdict("push", REF, SHA, "", ""), calls

    def test_open_pr_head_is_not_built_by_default(self) -> None:
        (stale, reason), calls = self.run_verdict({"CMUX_TUI_BRANCH_ON_REQUEST": "1"})
        self.assertTrue(stale)
        self.assertIn("on request", reason)
        self.assertFalse([c for c in calls if c.startswith("commits/")])

    def test_default_is_on_request(self) -> None:
        env = dict(os.environ)
        env.pop("CMUX_TUI_BRANCH_ON_REQUEST", None)
        with mock.patch.dict(os.environ, env, clear=True):
            (stale, _), _ = self.run_verdict({})
        self.assertTrue(stale)

    def test_the_trailer_still_builds(self) -> None:
        (stale, _), _ = self.run_verdict({"CMUX_TUI_BRANCH_ON_REQUEST": "1"}, trailer=True)
        self.assertFalse(stale)

    def test_a_cmux_next_dispatch_still_builds(self) -> None:
        (stale, _), _ = self.run_verdict({"CMUX_TUI_BRANCH_ON_REQUEST": "1"}, dispatches=1)
        self.assertFalse(stale)

    def test_off_switch_restores_the_open_pr_head_rule(self) -> None:
        (stale, _), _ = self.run_verdict({"CMUX_TUI_BRANCH_ON_REQUEST": "0"})
        self.assertFalse(stale)

    def test_a_dispatch_is_never_superseded(self) -> None:
        self.assertFalse(sup.verdict("workflow_dispatch", REF, SHA, "", "")[0])

    def test_trunk_refs_are_untouched(self) -> None:
        with mock.patch.dict(os.environ, {"CMUX_TUI_BRANCH_ON_REQUEST": "1"}):
            for ref in ("refs/heads/main", "refs/heads/feat-cmux-next"):
                self.assertFalse(sup.verdict("push", ref, SHA, "", "")[0])

    def test_workflow_passes_the_switch_to_every_gate_and_hot_verify_asks(self) -> None:
        wf = (ROOT / ".github/workflows/cmux-tui-artifacts.yml").read_text()
        self.assertEqual(wf.count("CMUX_TUI_BRANCH_ON_REQUEST:"), wf.count("cmux_tui_superseded_push.py --event"))
        hv = (ROOT / ".github/workflows/cmux-next-hot-verify.yml").read_text()
        self.assertIn("gh workflow run cmux-tui-artifacts.yml", hv)


if __name__ == "__main__":
    unittest.main()

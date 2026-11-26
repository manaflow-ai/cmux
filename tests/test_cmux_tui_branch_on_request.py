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

    def test_hot_verify_sends_no_dispatch_that_cannot_publish(self) -> None:
        # The artifacts workflow publishes a dispatched run only on main or feat-cmux-next, so a dispatch on a pull
        # request's branch built three targets and published nothing (82 lane/* heads, 2026-11-24 05:08-10:20Z).
        wf = (ROOT / ".github/workflows/cmux-tui-artifacts.yml").read_text()
        publish_if = next(l for l in wf.split("\n  publish-tree:\n", 1)[1].splitlines() if l.strip().startswith("if:"))
        self.assertIn("github.event_name == 'push'", publish_if)
        self.assertNotIn("workflow_dispatch", publish_if)
        hv = (ROOT / ".github/workflows/cmux-next-hot-verify.yml").read_text()
        step = hv.split("- name: Ask for the head's tree when it is not published", 1)[1].split("\n  # ", 1)[0]
        self.assertIn("LOOK_DISPATCH: ${{ vars.CMUX_TUI_LOOK_DISPATCH }}", step)
        gate = step.index('if [[ "${LOOK_DISPATCH:-}" != 1 ]]; then')
        self.assertLess(gate, step.index("gh workflow run cmux-tui-artifacts.yml"))


class SpareTokens(unittest.TestCase):
    """A 403 or 429 on one token moves the read to the next spare (a spent github.token kept unasked heads building)."""

    def fake_urlopen(self, answers: dict, seen: list):
        import io
        import urllib.error

        def urlopen(request, timeout=0):
            token = request.get_header("Authorization").removeprefix("Bearer ")
            seen.append(token)
            code = answers[token]
            if code != 200:
                raise urllib.error.HTTPError(request.full_url, code, "no", {}, io.BytesIO(b""))
            return mock.MagicMock(__enter__=lambda self: mock.MagicMock(status=200, read=lambda: b'{"total_count": 0}'),
                                  __exit__=lambda *a: False)
        return urlopen

    def call(self, answers: dict, spares: str):
        seen: list = []
        env = {"GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "pool", "GH_TOKEN_SPARES": spares}
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(sup.urllib.request, "urlopen", self.fake_urlopen(answers, seen)):
            return sup.api("actions/workflows/cmux-next.yml/runs"), seen

    def test_rate_limited_token_falls_through_to_the_next(self) -> None:
        (status, data), seen = self.call({"pool": 403, "spare": 429, "ghtoken": 200}, "spare ghtoken")
        self.assertEqual((status, data), (200, {"total_count": 0}))
        self.assertEqual(seen, ["pool", "spare", "ghtoken"])

    def test_other_errors_stop_at_once(self) -> None:
        (status, data), seen = self.call({"pool": 404, "ghtoken": 200}, "ghtoken")
        self.assertEqual((status, data, seen), (404, None, ["pool"]))

    def test_every_token_spent_answers_the_last_status(self) -> None:
        (status, data), seen = self.call({"pool": 403, "ghtoken": 403}, "pool ghtoken")
        self.assertEqual((status, data, seen), (403, None, ["pool", "ghtoken"]))


if __name__ == "__main__":
    unittest.main()

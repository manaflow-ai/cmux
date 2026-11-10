#!/usr/bin/env python3
"""The classic deploy guard refuses a classic cmux.com deploy from main without Leo's label, and cancels it."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts" / "ci"
CONFIG = SCRIPTS / "classic-auto-deploy.json"
WORKFLOW = ROOT / ".github" / "workflows" / "classic-deploy-guard.yml"
DOCS = ROOT / ".github" / "workflows" / "docs-channels.yml"
IGNORE = ROOT / "web" / "tools" / "vercel-ignore-build.sh"

spec = importlib.util.spec_from_file_location("classic_deploy_guard", SCRIPTS / "classic_deploy_guard.py")
assert spec and spec.loader
guard = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = guard
spec.loader.exec_module(guard)

CFG = guard.load_config(CONFIG)
SHA = "a" * 40
LANE = {"login": "teamleaderleo", "id": 13091533, "type": "User"}
MATE = {"login": "lawrencecchen", "id": 54008264, "type": "User"}


def pr(number: int = 1, user: dict = LANE, labels: tuple[str, ...] = (), sha: str = SHA, base: str = "main") -> dict:
    return {"number": number, "user": user, "labels": [{"name": n} for n in labels], "merged_at": "2026-11-09T00:00:00Z",
            "merge_commit_sha": sha, "base": {"ref": base}}


def judge(files: list[str], pulls: list[dict]) -> tuple[list[str], list[str]]:
    return guard.judge(CFG, [SHA], lambda _sha: files, lambda _sha: pulls)


class JudgeTests(unittest.TestCase):
    def test_lane_change_to_classic_api_without_label_is_refused(self) -> None:
        refusals, _ = judge(["web/app/api/vm/route.ts"], [pr()])
        self.assertEqual(len(refusals), 1)
        self.assertIn("classic-migration", refusals[0])
        self.assertIn("teamleaderleo", refusals[0])

    def test_site_page_counts_too(self) -> None:
        refusals, _ = judge(["web/app/(site)/next/page.tsx"], [pr()])
        self.assertEqual(len(refusals), 1)

    def test_leo_label_approves(self) -> None:
        refusals, notices = judge(["web/app/api/vm/route.ts", "web/db/schema.ts"], [pr(labels=("classic-migration",))])
        self.assertEqual(refusals, [])
        self.assertIn("classic-migration", notices[0])

    def test_other_labels_do_not_approve(self) -> None:
        refusals, _ = judge(["web/proxy.ts"], [pr(labels=("ready-to-land", "leo-named-fix"))])
        self.assertEqual(len(refusals), 1)

    def test_teammate_classic_work_passes(self) -> None:
        refusals, notices = judge(["web/app/(site)/pricing/page.tsx"], [pr(user=MATE)])
        self.assertEqual(refusals, [])
        self.assertIn("lawrencecchen", notices[0])

    def test_teammate_login_with_another_id_or_a_bot_is_refused(self) -> None:
        self.assertEqual(len(judge(["web/proxy.ts"], [pr(user={**MATE, "id": 1})])[0]), 1)
        self.assertEqual(len(judge(["web/proxy.ts"], [pr(user={**MATE, "type": "Bot"})])[0]), 1)

    def test_direct_push_is_refused(self) -> None:
        refusals, _ = judge(["web/app/api/vm/route.ts"], [])
        self.assertIn("direct push", refusals[0])

    def test_pr_into_another_base_does_not_count(self) -> None:
        refusals, _ = judge(["web/app/api/vm/route.ts"], [pr(labels=("classic-migration",), base="feat-cmux-next")])
        self.assertEqual(len(refusals), 1)

    def test_non_deployed_paths_pass(self) -> None:
        refusals, notices = judge(["web/tests/foo.test.ts", "web/scripts/x.ts", "web/README.md", "Sources/A.swift"],
                                  [])
        self.assertEqual(refusals, [])
        self.assertIn("no deployed classic path", notices[0])

    def test_relay_catalog_and_changelog_deploy(self) -> None:
        for path in ("config/iroh/managed-relay-catalog.json", "CHANGELOG.md", ".vercelignore"):
            self.assertEqual(len(judge([path], [pr()])[0]), 1, path)

    def test_unreadable_answers_refuse(self) -> None:
        def boom(_sha: str) -> list:
            raise guard.Unreadable("HTTP 502")

        refusals, _ = guard.judge(CFG, [SHA], boom, lambda _sha: [])
        self.assertIn("could not be read", refusals[0])
        refusals, _ = guard.judge(CFG, [SHA], lambda _sha: ["web/proxy.ts"], boom)
        self.assertIn("could not be read", refusals[0])

    def test_each_commit_of_a_push_is_judged(self) -> None:
        other = "b" * 40
        files = {SHA: ["web/proxy.ts"], other: ["web/app/api/vm/route.ts"]}
        pulls = {SHA: [pr(1, labels=("classic-migration",))], other: [pr(2, sha=other)]}
        refusals, _ = guard.judge(CFG, [SHA, other], files.__getitem__, pulls.__getitem__)
        self.assertEqual(len(refusals), 1)
        self.assertIn("#2", refusals[0])


class FakeApi:
    def __init__(self, routes: dict[str, object]):
        self.routes, self.calls = routes, []

    def __call__(self, url: str, token: str | None, method: str = "GET", accept: str = "", timeout: float = 30):
        self.calls.append((method, url))
        for key, value in self.routes.items():
            if re.search(key, url) and (method == "GET" or key.startswith(method)):
                return value(url) if callable(value) else value
        if method == "PATCH":
            return {"state": "CANCELED"}
        raise guard.Unreadable(f"no route for {url}")


class GitHubReaderTests(unittest.TestCase):
    def test_new_branch_push_judges_the_head(self) -> None:
        self.assertEqual(guard.GitHub("o/r", None, FakeApi({})).commits(guard.ZERO_SHA, SHA), [SHA])

    def test_compare_lists_the_pushed_commits(self) -> None:
        api = FakeApi({"compare/": {"status": "ahead", "total_commits": 2, "commits": [{"sha": "1"}, {"sha": "2"}]}})
        self.assertEqual(guard.GitHub("o/r", None, api).commits("0" * 39 + "1", SHA), ["1", "2"])

    def test_a_truncated_compare_is_unreadable(self) -> None:
        api = FakeApi({"compare/": {"status": "ahead", "total_commits": 300, "commits": [{"sha": "1"}]}})
        with self.assertRaises(guard.Unreadable):
            guard.GitHub("o/r", None, api).commits("c" * 40, SHA)

    def test_files_include_renamed_paths_and_pages(self) -> None:
        page1 = {"files": [{"filename": f"x/{i}"} for i in range(99)] + [{"filename": "a", "previous_filename":
                                                                            "web/proxy.ts"}]}
        api = FakeApi({r"page=1$": page1, r"page=2$": {"files": [{"filename": "web/db/schema.ts"}]}})
        files = guard.GitHub("o/r", None, api).files(SHA)
        self.assertIn("web/proxy.ts", files)
        self.assertIn("web/db/schema.ts", files)

    def test_check_cli_exit_codes(self) -> None:
        for labels, code in (((), 1), (("classic-migration",), 0)):
            api = FakeApi({rf"commits/{SHA}\?": {"files": [{"filename": "web/app/api/vm/route.ts"}]},
                           rf"commits/{SHA}/pulls": [pr(labels=labels)]})
            original = guard._request
            guard._request = api
            try:
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    got = guard.main(["check", "--repo", "o/r", "--before", "", "--after", SHA])
            finally:
                guard._request = original
            self.assertEqual(got, code, out.getvalue())


class CancelTests(unittest.TestCase):
    def run_cancel(self, lists: list[list[dict]], wait: float = 60) -> tuple[int, list[str], FakeApi]:
        answers = iter(lists)
        last = {"deployments": []}

        def listing(_url: str) -> dict:
            nonlocal last
            last = {"deployments": next(answers, last["deployments"])}
            return last

        api = FakeApi({r"/v6/deployments": listing})
        now = [0.0]
        code, lines = guard.cancel_deploy(CFG, SHA, "t", "team", wait, step_s=15, request=api,
                                          sleep=lambda s: now.__setitem__(0, now[0] + s), clock=lambda: now[0])
        return code, lines, api

    @staticmethod
    def dep(state: str, sha: str = SHA, uid: str = "dpl_1") -> dict:
        return {"uid": uid, "url": "cmux-x.vercel.app", "state": state, "meta": {"githubCommitSha": sha}}

    def test_a_building_deployment_is_cancelled(self) -> None:
        code, lines, api = self.run_cancel([[], [self.dep("BUILDING"), self.dep("BUILDING", sha="f" * 40, uid="o")]])
        self.assertEqual(code, 0)
        patched = [url for method, url in api.calls if method == "PATCH"]
        self.assertEqual(len(patched), 1)
        self.assertIn("/v12/deployments/dpl_1/cancel", patched[0])
        self.assertIn("Cancelled", lines[0])

    def test_a_live_deployment_is_an_error(self) -> None:
        code, lines, api = self.run_cancel([[self.dep("READY")]])
        self.assertEqual(code, 1)
        self.assertIn("roll it back", lines[-1])
        self.assertFalse([c for c in api.calls if c[0] == "PATCH"])

    def test_no_deployment_waits_then_gives_up(self) -> None:
        code, lines, api = self.run_cancel([], wait=60)
        self.assertEqual(code, 0)
        self.assertIn("No Vercel production deployment", lines[-1])
        self.assertEqual(len(api.calls), 5)  # at 0, 15, 30, 45 and 60 s

    def test_an_already_cancelled_deployment_needs_nothing(self) -> None:
        code, lines, _ = self.run_cancel([[self.dep("CANCELED")]])
        self.assertEqual(code, 0)
        self.assertIn("already stopped", lines[-1])


class WiringTests(unittest.TestCase):
    def test_config_names_known_deploys_and_teammates_with_ids(self) -> None:
        g = CFG["deploy_guard"]
        self.assertEqual(g["label"], "classic-migration")
        self.assertTrue(all(isinstance(m["id"], int) and m["login"] for m in g["teammates"]))
        self.assertNotIn("teamleaderleo", {m["login"] for m in g["teammates"]})

    def test_exclude_matches_the_vercel_ignore_script(self) -> None:
        # The ignore script's own exclusions; a checkout without web/ compares against this copy of them.
        skipped = ["tests/", "e2e/", "scripts/", "README.md", "AGENTS.md", "CLAUDE.md"]
        if IGNORE.exists():
            skipped = re.findall(r'":\(exclude\)([^"]+)"', IGNORE.read_text())
        want = sorted("web/" + (s + "**" if s.endswith("/") else s) for s in skipped)
        self.assertEqual(sorted(CFG["deploy_guard"]["exclude"]), want)

    def test_workflow_runs_on_main_pushes_and_cancels_only_there(self) -> None:
        text = WORKFLOW.read_text()
        self.assertRegex(text, r"push:\n\s+branches: \[main\]")
        self.assertIn('- "web/**"', text)
        self.assertIn("classic_deploy_guard.py check", text)
        cancel = text[text.index("Cancel the refused"):]
        self.assertIn("github.event_name == 'push'", cancel)
        self.assertIn("inputs.role != 'docs'", cancel)
        self.assertIn("steps.check.outcome == 'failure'", cancel)
        self.assertNotIn("pull_request", text.split("jobs:")[0])

    def test_docs_deploy_waits_for_the_guard(self) -> None:
        text = DOCS.read_text()
        self.assertIn("uses: ./.github/workflows/classic-deploy-guard.yml", text)
        nightly = text[text.index("  nightly:"):text.index("  release:")]
        self.assertIn("needs: guard", nightly)


if __name__ == "__main__":
    unittest.main()

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
        self.assertEqual(guard.GitHub("o/r", None, FakeApi({})).commits(guard.ZERO_SHA, SHA), ([SHA], None))

    def test_compare_lists_the_pushed_commits(self) -> None:
        api = FakeApi({"compare/": {"status": "ahead", "total_commits": 2, "commits": [{"sha": "1"}, {"sha": "2"}],
                                    "files": [{"filename": "web/a.ts", "previous_filename": "web/b.ts"}]}})
        self.assertEqual(guard.GitHub("o/r", None, api).commits("0" * 39 + "1", SHA),
                         (["1", "2"], {"web/a.ts", "web/b.ts"}))

    def test_a_capped_compare_file_list_is_unknown(self) -> None:
        files = [{"filename": f"x/{i}"} for i in range(guard.COMPARE_FILES_CAP)]
        api = FakeApi({"compare/": {"status": "ahead", "total_commits": 1, "commits": [{"sha": "1"}], "files": files}})
        self.assertEqual(guard.GitHub("o/r", None, api).commits("c" * 40, SHA), (["1"], None))

    def test_a_push_that_rewrote_history_is_not_forward(self) -> None:
        for status in ("diverged", "behind"):
            api = FakeApi({"compare/": {"status": status, "total_commits": 1, "commits": [{"sha": "1"}]}})
            with self.assertRaises(guard.NotForward):
                guard.GitHub("o/r", None, api).commits("c" * 40, SHA)

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
                           rf"commits/{SHA}/pulls": [pr(labels=labels)], "actions/workflows/": NO_RUNS})
            got, out = run_check(api, "--before", "", "--after", SHA)
            self.assertEqual(got, code, out)


NO_RUNS = {"workflow_runs": []}
BASE, A, R, B = "0" * 39 + "1", "1" * 40, "2" * 40, "3" * 40
API, PAGE = "web/app/api/vm/route.ts", "web/app/(site)/pricing/page.tsx"


def run_check(api: "FakeApi", *args: str) -> tuple[int, str]:
    original = guard._request
    guard._request = api
    try:
        with contextlib.redirect_stdout(io.StringIO()) as out:
            got = guard.main(["check", "--repo", "o/r", *args])
    finally:
        guard._request = original
    return got, out.getvalue()


def push_api(baseline: str | None, compare: dict, files: dict[str, list[str]], pulls: dict[str, list[dict]]) -> "FakeApi":
    routes: dict[str, object] = {
        "actions/workflows/classic-deploy-guard.yml/runs\\?branch=main&event=push&status=success":
            {"workflow_runs": [{"head_sha": baseline}] if baseline else []},
        "compare/": lambda url: {**compare, "_url": url},
    }
    for sha, paths in files.items():
        routes[rf"commits/{sha}\?"] = {"files": [{"filename": p} for p in paths]}
        routes[rf"commits/{sha}/pulls"] = pulls[sha]
    return FakeApi(routes)


class BaselineTests(unittest.TestCase):
    """F1 and F2 of the #40119 review: what ships is everything since the last passed deploy, not only the push."""

    def test_two_pushes_a_later_approved_push_does_not_ship_an_earlier_refused_one(self) -> None:
        # Push 1 lands A (our lane, no label): refused, so the baseline stays at BASE.
        api1 = push_api(BASE, {"status": "ahead", "total_commits": 1, "commits": [{"sha": A}],
                               "files": [{"filename": API}]}, {A: [API]}, {A: [pr(1, sha=A)]})
        code1, out1 = run_check(api1, "--before", BASE, "--after", A)
        self.assertEqual(code1, 1, out1)
        # Push 2 lands B (a teammate's page): B alone passes, but the deploy ships A's change too.
        compare = {"status": "ahead", "total_commits": 2, "commits": [{"sha": A}, {"sha": B}],
                   "files": [{"filename": API}, {"filename": PAGE}]}
        api2 = push_api(BASE, compare, {A: [API], B: [PAGE]}, {A: [pr(1, sha=A)], B: [pr(2, user=MATE, sha=B)]})
        code2, out2 = run_check(api2, "--before", A, "--after", B)
        self.assertEqual(code2, 1, out2)
        self.assertIn(A[:12], out2)
        self.assertIn(f"compare/{BASE}...{B}", " ".join(url for _m, url in api2.calls))
        # The same second push judged only before..after (the old behaviour) would have passed.
        api3 = push_api(None, {"status": "ahead", "total_commits": 1, "commits": [{"sha": B}],
                               "files": [{"filename": PAGE}]}, {B: [PAGE]}, {B: [pr(2, user=MATE, sha=B)]})
        self.assertEqual(run_check(api3, "--before", A, "--after", B)[0], 0)

    def test_labelling_the_refused_pr_later_lets_the_next_push_through(self) -> None:
        compare = {"status": "ahead", "total_commits": 2, "commits": [{"sha": A}, {"sha": B}],
                   "files": [{"filename": API}, {"filename": PAGE}]}
        api = push_api(BASE, compare, {A: [API], B: [PAGE]},
                       {A: [pr(1, sha=A, labels=("classic-migration",))], B: [pr(2, user=MATE, sha=B)]})
        self.assertEqual(run_check(api, "--before", A, "--after", B)[0], 0)

    def test_a_reverted_refused_change_ships_nothing(self) -> None:
        compare = {"status": "ahead", "total_commits": 3, "commits": [{"sha": A}, {"sha": R}, {"sha": B}],
                   "files": [{"filename": PAGE}]}  # A's API change and its revert R cancel out
        api = push_api(BASE, compare, {A: [API], R: [API], B: [PAGE]},
                       {A: [pr(1, sha=A)], R: [pr(3, sha=R)], B: [pr(2, user=MATE, sha=B)]})
        code, out = run_check(api, "--before", R, "--after", B)
        self.assertEqual(code, 0, out)

    def test_a_force_push_past_the_baseline_is_refused(self) -> None:
        api = push_api(BASE, {"status": "diverged", "total_commits": 1, "commits": [{"sha": B}]},
                       {B: ["web/README.md"]}, {B: []})
        code, out = run_check(api, "--before", A, "--after", B)
        self.assertEqual(code, 1)
        self.assertIn("does not contain", out)

    def test_no_green_run_yet_falls_back_to_before(self) -> None:
        api = push_api(None, {"status": "ahead", "total_commits": 1, "commits": [{"sha": B}],
                              "files": [{"filename": PAGE}]}, {B: [PAGE]}, {B: [pr(2, user=MATE, sha=B)]})
        self.assertEqual(run_check(api, "--before", A, "--after", B)[0], 0)
        self.assertIn(f"compare/{A}...{B}", " ".join(url for _m, url in api.calls))

    def test_unreadable_runs_refuse(self) -> None:
        api = FakeApi({})
        self.assertEqual(run_check(api, "--before", A, "--after", B)[0], 1)

    def test_dispatch_judges_one_commit_without_the_baseline(self) -> None:
        api = push_api("f" * 40, {}, {B: [PAGE]}, {B: [pr(2, user=MATE, sha=B)]})
        self.assertEqual(run_check(api, "--before", "", "--after", B, "--baseline", "before")[0], 0)
        self.assertFalse([url for _m, url in api.calls if "actions/workflows" in url])


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
        self.assertIn("actions: read", text)
        self.assertIn("'before' || 'auto'", text)
        self.assertNotIn("pull_request", text.split("jobs:")[0])

    def test_docs_deploy_waits_for_the_guard(self) -> None:
        text = DOCS.read_text()
        self.assertIn("uses: ./.github/workflows/classic-deploy-guard.yml", text)
        nightly = text[text.index("  nightly:"):text.index("  release:")]
        self.assertIn("needs: guard", nightly)
        self.assertIn("actions: read", text[text.index("  guard:"):text.index("  nightly:")])


if __name__ == "__main__":
    unittest.main()

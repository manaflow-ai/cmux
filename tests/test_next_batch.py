#!/usr/bin/env python3
"""The feat-cmux-next batch queue: selection, debounce, stacking, bisect.

scripts/ci/next_batch.py stacks eligible PRs on feat-cmux-next, rebuilds
conflicted generated files instead of resolving them by hand, drops PRs with
real conflicts, and bisects a red stack to one culprit. The stacking tests
run real git merges in a scratch repository.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import next_batch as nb  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/cmux-next-batch.yml"
NOW = dt.datetime(2026, 10, 6, 5, 0, tzinfo=dt.timezone.utc)
PANE = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/pane.js"


def pr(number: int, **fields) -> nb.PullRequest:
    defaults = dict(sha=f"{number:040x}", title=f"PR {number}", author="teamleaderleo",
                    committed_at="2026-10-06T04:00:00Z", head_ref=f"lane-{number}")
    defaults.update(fields)
    return nb.PullRequest(number=number, **defaults)


class Classify(unittest.TestCase):
    def test_generated_paths_by_generator(self):
        cases = {
            PANE: "web",
            "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/settings/locales/ko.js": "web",
            "webviews/src/pages/settings/generated/strings.json": "web",
            "schemas/settings/settings-schema.json": "swift",
            "plans/cmux-next/action-surfaces.json": "swift",
            "cmux-tui/bindings/python/cmux/raw/_generated/models.py": "sdk",
            "cmux-tui/bindings/java/src/com/cmux/raw/Client.java": "sdk",
            "cmux-tui/spec/sdk-schema.json": "spec",
            "Resources/Localizable.xcstrings": "xcstrings",
            "cmux.xcodeproj/project.pbxproj": "pbxproj",
            "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/SidebarListView.swift": "source",
            "plans/cmux-next/inventory.md": "source",
        }
        for path, kind in cases.items():
            with self.subTest(path=path):
                self.assertEqual(nb.classify(path), kind)


class Eligibility(unittest.TestCase):
    def reason(self, item: nb.PullRequest) -> str | None:
        return nb.ineligible_reason(item, NOW, authors=frozenset({"teamleaderleo"}))

    def test_green_or_pending_fast_checks_are_eligible(self):
        self.assertIsNone(self.reason(pr(1, checks=[("lint", "completed", "success"),
                                                     ("tests", "in_progress", "")])))

    def test_red_fast_check_is_not(self):
        self.assertEqual(self.reason(pr(1, checks=[("lint", "completed", "failure")])), "red check lint")

    def test_red_or_pending_heavy_check_does_not_block(self):
        # The batch runs the heavy tier once on the stack.
        self.assertIsNone(self.reason(pr(1, checks=[("cmux-next swift test", "completed", "failure"),
                                                     ("cmux app scheme compile (Debug)", "queued", "")])))

    def test_hold_draft_fork_stale_and_batch_branch(self):
        self.assertEqual(self.reason(pr(1, labels=["hold"])), "label hold")
        self.assertEqual(self.reason(pr(1, labels=["exploration", "needs a call"])), "label exploration, needs a call")
        self.assertEqual(self.reason(pr(1, draft=True)), "draft")
        self.assertEqual(self.reason(pr(1, same_repo=False)), "head is in a fork")
        self.assertIn("older than", self.reason(pr(1, committed_at="2026-09-20T00:00:00Z")))
        self.assertEqual(self.reason(pr(1, head_ref="next-batch/1-1")), "a batch integration branch")

    def test_a_red_web_format_check_does_not_block_a_webviews_pr(self):
        red = [("web / react-apps-check", "completed", "failure"), ("web / Web status", "completed", "failure")]
        self.assertIsNone(nb.ineligible_reason(pr(5, checks=red, files=["webviews/src/a.ts"]), NOW))
        self.assertIn("react-apps-check", nb.ineligible_reason(pr(5, checks=red, files=["app.swift"]), NOW))

    def test_workflow_changes_land_by_hand(self):
        # GitHub refuses the job token's push or merge of a workflow change.
        self.assertIn("lands by hand", self.reason(pr(1, files=[".github/workflows/cmux-next.yml"])))
        self.assertIsNone(self.reason(pr(1, files=["scripts/ci/x.py"])))

    def test_other_authors_opt_in_with_a_label(self):
        self.assertIn("has not opted in", self.reason(pr(1, author="lawrencecchen")))
        self.assertIsNone(self.reason(pr(1, author="lawrencecchen", labels=["batch-queue"])))

    def test_select_orders_by_number_and_caps_the_batch(self):
        prs = [pr(n) for n in (30, 10, 20, 40)] + [pr(5, labels=["hold"])]
        with mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_AUTHORS": ""}):
            eligible, skipped = nb.select(prs, NOW, limit=3)
        self.assertEqual([item.number for item in eligible], [10, 20, 30])
        self.assertEqual(skipped, {5: "label hold", 40: "batch is full (3); next batch"})


class ConflictingWithBase(unittest.TestCase):
    def test_a_pr_conflicting_with_the_base_keeps_out_and_unknown_does_not(self):
        with mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_AUTHORS": ""}):
            self.assertEqual(nb.ineligible_reason(pr(1, mergeable="CONFLICTING"), NOW),
                             "conflicts with feat-cmux-next (merge it, push)")
            self.assertIsNone(nb.ineligible_reason(pr(2, mergeable="UNKNOWN"), NOW))
            self.assertIsNone(nb.ineligible_reason(pr(3, mergeable="MERGEABLE"), NOW))


class OpenPrsQuery(unittest.TestCase):
    """The PR list is light and paged; files and checks (30 PRs with both in one
    page timed out, HTTP 504) come only for PRs the cheap filters keep."""

    def setUp(self):
        nb.DETAILS.clear()

    def node(self, number: int, draft: bool = False, state: str = "SUCCESS") -> dict:
        return {"id": f"PR_{number}", "number": number, "title": "t", "url": "u", "isDraft": draft,
                "headRefName": f"b{number}", "headRefOid": f"{number:040x}", "authorAssociation": "MEMBER",
                "author": {"login": "teamleaderleo"}, "isCrossRepository": False, "labels": {"nodes": []},
                "commits": {"nodes": [{"commit": {"committedDate": dt.datetime.now(dt.timezone.utc).isoformat(),
                                                  "statusCheckRollup": {"state": state, "contexts": {}}}}]}}

    def fake(self, pages: list[dict], details: dict) -> tuple[nb.GitHub, list]:
        """GraphQL stub: list pages in order; a detail query answers each alias
        from details[(node id, cursor)] = (paths, contexts, next cursor)."""
        gh, seen = nb.GitHub("o/r"), []

        def graphql(query, **variables):
            if "pullRequests(" in query:
                after = variables.get("after")
                seen.append(("list", after))
                cursors = [None] + [page["repository"]["pullRequests"]["pageInfo"]["endCursor"] for page in pages]
                return pages[cursors.index(after)]
            reply = {}
            for alias, node_id, rest in re.findall(r'^(p\d+): node\(id: "([^"]+)"\)(.*?)(?=^p\d+: |\Z)', query, re.S | re.M):
                cursor = None
                if "contexts(" in rest:
                    found = re.search(r'after: "([^"]+)"', rest)
                    cursor = found.group(1) if found else ""
                seen.append(("detail", node_id, "files(" in rest, cursor))
                paths, contexts, following = details[(node_id, cursor or "")]
                node = {}
                if "files(" in rest:
                    node["files"] = {"nodes": [{"path": path} for path in paths]}
                if cursor is not None:
                    node["commits"] = {"nodes": [{"commit": {"statusCheckRollup": {"contexts": {
                        "nodes": contexts, "pageInfo": {"hasNextPage": bool(following), "endCursor": following}}}}}]}
                reply[alias] = node
            return reply

        gh.graphql = graphql
        return gh, seen

    @staticmethod
    def run_context(name: str, conclusion: str) -> dict:
        return {"__typename": "CheckRun", "name": name, "status": "COMPLETED", "conclusion": conclusion}

    def test_lists_every_page_and_fetches_details_only_for_candidates(self):
        pages = [
            {"repository": {"pullRequests": {"nodes": [self.node(1), self.node(2, draft=True)],
                                              "pageInfo": {"hasNextPage": True, "endCursor": "c1"}}}},
            {"repository": {"pullRequests": {"nodes": [self.node(3)],
                                              "pageInfo": {"hasNextPage": False, "endCursor": None}}}},
        ]
        gh, seen = self.fake(pages, {("PR_1", ""): (["a.swift"], [], None), ("PR_3", ""): ([".github/workflows/x.yml"], [], None)})
        with mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_AUTHORS": ""}):
            prs = nb.open_prs(gh)
        self.assertEqual([item.number for item in prs], [1, 2, 3])
        self.assertEqual(seen[:2], [("list", None), ("list", "c1")])
        # The draft gets no detail query; a green rollup gets files but no contexts.
        self.assertEqual(sorted(seen[2:]), [("detail", "PR_1", True, None), ("detail", "PR_3", True, None)])
        self.assertEqual(prs[2].files, [".github/workflows/x.yml"])
        self.assertEqual(prs[1].files, [])

    def test_pages_contexts_past_the_first_hundred_and_caches_by_head_and_counts(self):
        pages = [{"repository": {"pullRequests": {"nodes": [self.node(1, state="FAILURE")],
                                                   "pageInfo": {"hasNextPage": False, "endCursor": None}}}}]
        details = {
            ("PR_1", ""): (["a.swift"], [self.run_context("ok", "SUCCESS")] * 100, "k1"),
            ("PR_1", "k1"): ([], [self.run_context("cmux-next fast tier", "FAILURE")], None),
        }
        gh, seen = self.fake(pages, details)
        with mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_AUTHORS": ""}):
            first = nb.open_prs(gh)
            self.assertEqual(nb.red_fast_checks(first[0]), ["cmux-next fast tier"])
            self.assertEqual([item[1:] for item in seen if item[0] == "detail"],
                             [("PR_1", True, ""), ("PR_1", False, "k1")])
            seen.clear()
            again = nb.open_prs(gh)
        self.assertEqual([item for item in seen if item[0] == "detail"], [])
        self.assertEqual(nb.red_fast_checks(again[0]), ["cmux-next fast tier"])

    def test_a_red_count_fetches_checks_whatever_the_rollup_state(self):
        rollup = {"state": "PENDING", "contexts": {"checkRunCountsByState": [{"state": "CANCELLED", "count": 1}]}}
        self.assertTrue(nb.rollup_failing(rollup))
        self.assertFalse(nb.rollup_failing({"state": "PENDING", "contexts": {
            "checkRunCountsByState": [{"state": "FAILURE", "count": 0}, {"state": "IN_PROGRESS", "count": 3}]}}))

    def test_a_full_cache_never_drops_a_hit_of_this_poll(self):
        pages = [{"repository": {"pullRequests": {"nodes": [self.node(1), self.node(2)],
                                                   "pageInfo": {"hasNextPage": False, "endCursor": None}}}}]
        gh, _ = self.fake(pages, {("PR_1", ""): (["a"], [], None), ("PR_2", ""): (["b"], [], None)})
        with mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_AUTHORS": ""}):
            nb.open_prs(gh)
            nb.DETAILS.update({(str(n), "x"): ([], []) for n in range(5001)})
            moved = self.node(2)
            moved["headRefOid"] = "f" * 40
            pages[0]["repository"]["pullRequests"]["nodes"][1] = moved
            prs = nb.open_prs(gh)
        self.assertEqual([item.files for item in prs], [["a"], ["b"]])

    def test_landing_rechecks_without_the_cache(self):
        pages = [{"repository": {"pullRequests": {"nodes": [self.node(1)],
                                                   "pageInfo": {"hasNextPage": False, "endCursor": None}}}}]
        gh, seen = self.fake(pages, {("PR_1", ""): (["a"], [], None)})
        with mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_AUTHORS": ""}):
            nb.open_prs(gh)
            seen.clear()
            nb.open_prs(gh, fresh=True)
        self.assertEqual([item[0] for item in seen], ["list", "detail"])

    def test_the_detail_query_refuses_an_unexpected_id(self):
        with self.assertRaises(ValueError):
            nb.detail_query([('x") { a } b: node(id: "y', True, None)])

    def test_a_gateway_timeout_is_retried_once(self):
        gh = nb.GitHub("o/r")
        replies = [subprocess.CompletedProcess([], 1, "", "gh: HTTP 504"),
                   subprocess.CompletedProcess([], 0, '{"data": {"ok": 1}}', "")]
        with mock.patch.object(nb.subprocess, "run", side_effect=replies), mock.patch.object(nb.time, "sleep"):
            self.assertEqual(gh.graphql("query { x }"), {"ok": 1})

    def test_a_truncated_reply_is_retried_once(self):
        gh = nb.GitHub("o/r")
        replies = [subprocess.CompletedProcess([], 1, "", "unexpected end of JSON input"),
                   subprocess.CompletedProcess([], 0, '{"data": {"ok": 1}}', "")]
        with mock.patch.object(nb.subprocess, "run", side_effect=replies), mock.patch.object(nb.time, "sleep"):
            self.assertEqual(gh.graphql("query { x }"), {"ok": 1})


class Debounce(unittest.TestCase):
    def test_waits_for_quiet_but_not_past_the_hard_max(self):
        self.assertEqual(nb.debounce_wait(NOW, NOW), 120)
        self.assertEqual(nb.debounce_wait(NOW, NOW - dt.timedelta(seconds=530)), 70)
        self.assertEqual(nb.debounce_wait(NOW, NOW - dt.timedelta(minutes=30)), 0)

    def test_first_trigger_counts_from_the_last_batch_dispatch(self):
        def run(event: str, minutes: int, title: str = "debounce 1") -> dict:
            return {"event": event, "display_title": title,
                    "created_at": (NOW - dt.timedelta(minutes=minutes)).isoformat()}
        runs = [run("pull_request", 1), run("push", 6), run("workflow_dispatch", 8, "batch "),
                run("pull_request", 9), run("workflow_dispatch", 3, "build x")]
        self.assertEqual(nb.first_trigger_since_dispatch(runs, NOW), NOW - dt.timedelta(minutes=6))
        self.assertEqual(nb.first_trigger_since_dispatch([], NOW), NOW)

    def debounce(self, runs: list[dict], run_id: int) -> mock.MagicMock:
        """cmd_debounce as run `run_id`, with GitHub faked; returns the fake."""
        gh = mock.MagicMock()
        gh.runs.return_value = runs
        with mock.patch.object(nb, "GitHub", return_value=gh), mock.patch.object(nb, "now", return_value=NOW), \
                mock.patch.object(nb.time, "sleep"), mock.patch.dict(os.environ, {"GITHUB_RUN_ID": str(run_id)}):
            self.assertEqual(nb.cmd_debounce(Namespace(repo="o/r", reason="r")), 0)
        return gh

    def test_a_superseded_wait_ends_green_without_dispatching(self):
        """A newer event's run takes over the wait: the older one exits 0, never CANCELLED,
        so the debounce check on a pull request does not read red."""
        def run(run_id: int, event: str, minutes: int) -> dict:
            return {"id": run_id, "event": event, "display_title": "debounce 1",
                    "created_at": (NOW - dt.timedelta(minutes=minutes)).isoformat()}
        runs = [run(12, "pull_request", 0), run(11, "push", 1), run(10, "workflow_dispatch", 2)]
        self.assertTrue(nb.superseded(runs, 11))
        self.assertFalse(nb.superseded(runs, 12))
        self.assertFalse(nb.superseded(runs, 99))  # not listed yet: wait, then look again
        # only a run whose debounce job runs takes over: not a fork's or a next-batch/ head's (skipped there)
        fork = {**run(13, "pull_request", 0), "head_repository": {"full_name": "fork/r"}, "head_branch": "x"}
        stack = {**run(14, "pull_request", 0), "head_repository": {"full_name": "o/r"}, "head_branch": "next-batch/7"}
        self.assertFalse(nb.superseded(runs + [fork, stack], 12, "o/r"))
        self.assertTrue(nb.superseded(runs + [{**fork, "head_repository": {"full_name": "o/r"}}], 12, "o/r"))
        # a run the full listing no longer reaches has 60 newer runs: it is superseded
        page = [run(100 + i, "pull_request", 0) for i in range(60)]
        self.assertTrue(nb.superseded(page, 11))
        self.assertFalse(nb.superseded(page[:59], 11))
        self.debounce(runs, 11).dispatch.assert_not_called()
        self.debounce(runs, 12).dispatch.assert_called_once()
        # a newer event that arrives during the wait also supersedes it
        gh = mock.MagicMock()
        gh.runs.side_effect = [runs[1:], runs]
        with mock.patch.object(nb, "GitHub", return_value=gh), mock.patch.object(nb, "now", return_value=NOW), \
                mock.patch.object(nb.time, "sleep"), mock.patch.dict(os.environ, {"GITHUB_RUN_ID": "11"}):
            self.assertEqual(nb.cmd_debounce(Namespace(repo="o/r", reason="r")), 0)
        gh.dispatch.assert_not_called()


class ServeDebounce(unittest.TestCase):
    """The big-red serve loop: quiet after the eligible set changes, capped."""

    def at(self, seconds: int) -> dt.datetime:
        return NOW + dt.timedelta(seconds=seconds)

    def test_runs_after_quiet_and_not_again_for_the_same_set(self):
        debouncer = nb.Debouncer()
        heads = ((1, "a"), (2, "b"))
        self.assertFalse(debouncer.observe(heads, self.at(0)))
        self.assertFalse(debouncer.observe(heads, self.at(60)))
        self.assertTrue(debouncer.observe(heads, self.at(120)))
        debouncer.ran(heads)
        self.assertFalse(debouncer.observe(heads, self.at(600)))

    def test_constant_pushes_still_run_at_the_hard_max(self):
        debouncer = nb.Debouncer()
        fired = [seconds for seconds in range(0, 900, 60)
                 if debouncer.observe(((1, f"sha{seconds}"),), self.at(seconds))]
        self.assertEqual(fired[0], 600)

    def test_nothing_eligible_never_runs(self):
        debouncer = nb.Debouncer()
        self.assertFalse(debouncer.observe((), self.at(0)))
        self.assertFalse(debouncer.observe((), self.at(3600)))

    def test_a_new_push_after_a_batch_starts_a_new_wait(self):
        debouncer = nb.Debouncer()
        debouncer.observe(((1, "a"),), self.at(0))
        debouncer.ran(((1, "a"),))
        self.assertFalse(debouncer.observe(((1, "b"),), self.at(1000)))
        self.assertTrue(debouncer.observe(((1, "b"),), self.at(1120)))


class CloseWatch(unittest.TestCase):
    """serve's poll also notices a batch author's PR closed, unmerged, by
    someone else; it only reports, never reopens."""

    def watch(self, closes: dict[int, dict]) -> tuple[nb.CloseWatch, list[str], list[int]]:
        sent, looked = [], []

        def lookup(number):
            looked.append(number)
            return closes[number]

        return nb.CloseWatch(lookup, sent.append, frozenset({"teamleaderleo"})), sent, looked

    def at(self, seconds: int) -> dt.datetime:
        return NOW + dt.timedelta(seconds=seconds)

    def closed(self, actor="azooz2003-bit", merged=False, state="CLOSED", when="2026-10-06T20:30:00Z") -> dict:
        return {"state": state, "merged": merged, "author": "teamleaderleo", "actor": actor, "closed_at": when}

    def test_a_close_by_someone_else_is_reported_with_actor_and_time(self):
        watch, sent, _ = self.watch({2: self.closed()})
        watch.observe([pr(1), pr(2)], self.at(0))
        self.assertEqual(sent, [])
        watch.observe([pr(1)], self.at(60))
        self.assertEqual(len(sent), 1)
        for part in ("#2", "azooz2003-bit", "2026-10-06T20:30:00Z"):
            self.assertIn(part, sent[0])

    def test_merges_own_closes_retargets_and_other_authors_are_quiet(self):
        watch, sent, looked = self.watch({
            1: self.closed(merged=True, state="MERGED"),
            2: self.closed(actor="teamleaderleo"),
            3: self.closed(state="OPEN"),
        })
        watch.observe([pr(1), pr(2), pr(3), pr(4, author="lawrencecchen")], self.at(0))
        watch.observe([], self.at(60))
        self.assertEqual(sent, [])
        self.assertEqual(sorted(looked), [1, 2, 3])  # never looks up another author's PR

    def test_three_closes_in_ten_minutes_post_one_alert(self):
        watch, sent, _ = self.watch({n: self.closed() for n in range(1, 7)})
        watch.observe([pr(n) for n in range(1, 7)], self.at(0))
        watch.observe([pr(n) for n in range(2, 7)], self.at(60))     # #1
        watch.observe([pr(n) for n in range(3, 7)], self.at(120))    # #2
        watch.observe([pr(n) for n in range(4, 7)], self.at(180))    # #3: alert
        watch.observe([pr(n) for n in range(5, 7)], self.at(240))    # #4: folded into the burst
        self.assertEqual(len(sent), 3)
        self.assertIn("ALERT", sent[2])
        for number in ("#1", "#2", "#3"):
            self.assertIn(number, sent[2])
        watch.observe([pr(n) for n in range(5, 7)], self.at(240 + 600))  # burst over: one summary
        self.assertEqual(len(sent), 4)
        self.assertIn("#4", sent[3])
        self.assertNotIn("ALERT", sent[3])

    def test_a_failed_lookup_retries_on_the_next_poll(self):
        calls = []

        def lookup(number):
            calls.append(number)
            if len(calls) == 1:
                raise RuntimeError("HTTP 502")
            return self.closed()

        sent = []
        watch = nb.CloseWatch(lookup, sent.append, frozenset({"teamleaderleo"}))
        watch.observe([pr(1)], self.at(0))
        watch.observe([], self.at(60))
        self.assertEqual(sent, [])
        watch.observe([], self.at(120))
        self.assertEqual(len(sent), 1)


class JsonMerge(unittest.TestCase):
    def test_different_keys_merge(self):
        base = {"commands": {"a": 1}}
        merged = nb.json_merge(base, {"commands": {"a": 1, "b": 2}}, {"commands": {"a": 1, "c": 3}})
        self.assertEqual(merged, {"commands": {"a": 1, "b": 2, "c": 3}})

    def test_appended_lists_merge(self):
        self.assertEqual(nb.json_merge([1], [1, 2], [1, 3]), [1, 2, 3])

    def test_same_key_changed_both_ways_conflicts(self):
        with self.assertRaises(nb.JsonConflict):
            nb.json_merge({"a": 1}, {"a": 2}, {"a": 3})

    def test_text_keeps_the_files_indent(self):
        base = '{\n    "a": 1\n}\n'
        text = nb.json_merge_text(base, '{\n    "a": 1,\n    "b": 2\n}\n', '{\n    "a": 1,\n    "c": 3\n}\n')
        self.assertEqual(text, '{\n    "a": 1,\n    "b": 2,\n    "c": 3\n}\n')


class Stacking(unittest.TestCase):
    """Real merges: base commit plus PR branches in a scratch repository."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "repo"
        self.root.mkdir()
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        self.git("init", "-q", "-b", "base")
        self.write({"app.swift": "let a = 1\nlet b = 2\n", PANE: "bundle v0\n",
                    "cmux-tui/spec/sdk-schema.json": '{\n  "commands": {\n    "a": 1\n  }\n}\n'})
        self.base = self.commit("base")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.root, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, files: dict[str, str]) -> None:
        for path, text in files.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def branch(self, number: int, files: dict[str, str]) -> nb.PullRequest:
        self.git("checkout", "-q", "-B", f"pr{number}", self.base)
        self.write(files)
        sha = self.commit(f"pr {number}")
        self.git("checkout", "-q", "--detach", self.base)
        return pr(number, sha=sha)

    def stack(self, prs: list[nb.PullRequest]) -> nb.Stack:
        with mock.patch.dict(os.environ, self.env):
            return nb.build_stack(self.root, self.base, prs, regen=False)

    def test_clean_prs_stack_in_order(self):
        one = self.branch(1, {"one.swift": "1\n"})
        two = self.branch(2, {"two.swift": "2\n"})
        stack = self.stack([one, two])
        self.assertEqual([item.number for item in stack.included], [1, 2])
        self.assertFalse(stack.dropped)
        self.assertEqual(self.git("log", "--format=%s", "-2", stack.head).splitlines(),
                         ["next-batch: merge #2", "next-batch: merge #1"])

    def test_generated_conflict_keeps_the_stack_copy_and_asks_for_regeneration(self):
        one = self.branch(1, {PANE: "bundle one\n", "pane-src-1.ts": "1\n"})
        two = self.branch(2, {PANE: "bundle two\n", "pane-src-2.ts": "2\n"})
        stack = self.stack([one, two])
        self.assertEqual([item.number for item in stack.included], [1, 2])
        self.assertIn("web", stack.regen)
        self.assertEqual(self.git("show", f"{stack.head}:{PANE}"), "bundle one")

    def test_source_conflict_drops_the_later_pr(self):
        one = self.branch(1, {"app.swift": "let a = 10\nlet b = 2\n"})
        two = self.branch(2, {"app.swift": "let a = 20\nlet b = 2\n"})
        three = self.branch(3, {"three.swift": "3\n"})
        stack = self.stack([one, two, three])
        self.assertEqual([item.number for item in stack.included], [1, 3])
        self.assertEqual([(item.number, [b["path"] for b in blocking]) for item, blocking in stack.dropped],
                         [(2, ["app.swift"])])
        self.assertEqual(self.git("status", "--porcelain", "--untracked-files=no"), "")

    def test_spec_json_merges_by_key_and_regenerates_the_sdk(self):
        spec = "cmux-tui/spec/sdk-schema.json"
        one = self.branch(1, {spec: '{\n  "commands": {\n    "a": 1,\n    "b": 2\n  }\n}\n'})
        two = self.branch(2, {spec: '{\n  "commands": {\n    "a": 1,\n    "c": 3\n  }\n}\n'})
        stack = self.stack([one, two])
        self.assertEqual([item.number for item in stack.included], [1, 2])
        self.assertEqual(json.loads(self.git("show", f"{stack.head}:{spec}")),
                         {"commands": {"a": 1, "b": 2, "c": 3}})
        self.assertIn("sdk", stack.regen)

    def test_generated_file_both_sides_changed_cleanly_is_still_rebuilt(self):
        self.git("checkout", "-q", "--detach", self.base)
        self.write({PANE: "line1\nline2\nline3\nline4\nline5\nline6\n"})
        self.base = self.commit("longer bundle")
        one = self.branch(1, {PANE: "line1 one\nline2\nline3\nline4\nline5\nline6\n"})
        two = self.branch(2, {PANE: "line1\nline2\nline3\nline4\nline5\nline6 two\n"})
        stack = self.stack([one, two])
        self.assertEqual(len(stack.included), 2)
        self.assertIn("web", stack.regen)


class Bisect(unittest.TestCase):
    def controller(self, red_from: int) -> nb.Controller:
        controller = nb.Controller.__new__(nb.Controller)
        controller.validations = []
        probes = []

        def validate(prs, name):
            probes.append([item.number for item in prs])
            stack = nb.Stack(base="b", head="h", included=list(prs))
            validation = nb.Validation(name=name, stack=stack, build={"ok": True})
            if any(item.number >= red_from for item in prs):
                validation.heavy_failed = ["cmux-next swift test"]
            controller.validations.append(validation)
            return validation

        controller.validate = validate
        controller.probes = probes
        return controller

    def test_finds_the_first_pr_that_turns_the_stack_red(self):
        prs = [pr(n) for n in range(1, 9)]
        for red_from in range(1, 9):
            with self.subTest(red_from=red_from):
                controller = self.controller(red_from)
                red = nb.Validation(name="batch", stack=nb.Stack(base="b", included=prs),
                                    heavy_failed=["x"], build={"ok": True})
                self.assertEqual(controller.bisect(red).number, red_from)
                self.assertLessEqual(len(controller.probes), 3)  # log2(8)


class RemoteRegeneration(unittest.TestCase):
    """Generators run the stack's code, so they run in a dispatched job and
    send back a patch; the controller never runs them on its own host."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        self.git("init", "-q", "-b", "base")
        (self.root / "pane.js").write_text("v0\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "stack")
        self.head = self.git("rev-parse", "HEAD")
        (self.root / "pane.js").write_text("v1\n")
        self.git("commit", "-q", "-am", "next-batch: regenerate web bundles")
        self.patch = subprocess.run(["git", "format-patch", "-1", "--binary", "--stdout"], cwd=self.root,
                                    env=self.env, check=True, capture_output=True).stdout
        self.git("reset", "-q", "--hard", self.head)

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.root, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def controller(self, results: dict[str, dict]) -> tuple[nb.Controller, list]:
        controller = nb.Controller.__new__(nb.Controller)
        controller.worktree = self.root
        calls = []

        def mini(mode, branch, sha, extra):
            calls.append((mode, sha, extra.get("kinds")))
            return {}, results[mode]

        controller.mini = mini
        controller.git = lambda *args, cwd=None: subprocess.run(
            ["git", *args], cwd=cwd or self.root, env=self.env, check=True, capture_output=True, text=True,
        ).stdout.strip() if args[0] != "push" else calls.append(("push", args[-1], None))
        return controller, calls

    def test_web_and_sdk_on_linux_then_swift_on_a_mini_each_applied_as_a_patch(self):
        controller, calls = self.controller({"regen-linux": {"ok": True, "patch": self.patch},
                                             "regen": {"ok": True}})
        stack = nb.Stack(base="b", head=self.head, regen={"web", "sdk", "swift"})
        with mock.patch.dict(os.environ, self.env):
            self.assertTrue(controller.regenerate_remote(stack, "next-batch/x-1"))
        self.assertEqual([call[0] for call in calls], ["regen-linux", "push", "regen"])
        self.assertEqual(calls[0][2], "sdk web")
        self.assertNotEqual(stack.head, self.head)
        self.assertEqual((self.root / "pane.js").read_text(), "v1\n")
        self.assertEqual(calls[2][1], stack.head)  # swift runs on the regenerated head

    def test_a_failed_generator_is_the_stack_error(self):
        controller, _ = self.controller({"regen": {"ok": False, "error": "swift test failed"}})
        stack = nb.Stack(base="b", head=self.head, regen={"swift"})
        self.assertFalse(controller.regenerate_remote(stack, "next-batch/x-1"))
        self.assertIn("swift test failed", stack.error)

    def test_validate_never_runs_a_generator_locally(self):
        controller = nb.Controller.__new__(nb.Controller)
        controller.validations, controller.base_sha, controller.worktree = [], "", self.root
        controller.fetch = lambda prs: self.head
        seen = {}

        def build_stack(worktree, base_sha, prs, regen=True):
            seen["regen"] = regen
            return nb.Stack(base=base_sha)

        with mock.patch.object(nb, "build_stack", build_stack):
            controller.validate([pr(1)], "batch")
        self.assertIs(seen["regen"], False)


class MiniRetry(unittest.TestCase):
    """A mini refused at setup (host busy) writes no result: try once more."""

    def controller(self, outcomes: list[bool]) -> tuple[nb.Controller, list]:
        controller = nb.Controller.__new__(nb.Controller)
        controller.args = Namespace(repo="o/r", ref="feat-cmux-next")
        controller.batch_id = "b"
        attempts = []

        def once(mode, branch, sha, extra):
            wrote = outcomes[len(attempts)]
            attempts.append(mode)
            return {"html_url": f"u{len(attempts)}"}, ({"ok": True, "run": "u"} if wrote else
                                                        {"ok": False, "error": "mini run failure", "run": "u",
                                                         "no_result": True})

        controller.mini_once = once
        return controller, attempts

    def test_a_job_without_a_result_is_dispatched_once_more(self):
        controller, attempts = self.controller([False, True])
        _, result = controller.mini("regen", "next-batch/x", "c" * 40, {})
        self.assertTrue(result["ok"])
        self.assertEqual(attempts, ["regen", "regen"])

    def test_it_gives_up_after_the_second_refusal(self):
        controller, attempts = self.controller([False, False, True])
        _, result = controller.mini("regen", "next-batch/x", "c" * 40, {})
        self.assertFalse(result["ok"])
        self.assertEqual(len(attempts), 2)

    def test_a_generator_failure_is_not_retried(self):
        controller = nb.Controller.__new__(nb.Controller)
        attempts = []
        controller.mini_once = lambda *args: attempts.append(1) or ({}, {"ok": False, "error": "script failed"})
        self.assertFalse(controller.mini("regen", "next-batch/x", "c" * 40, {})[1]["ok"])
        self.assertEqual(len(attempts), 1)


class FormatBeforeLanding(unittest.TestCase):
    """Formatting never blocks a landing: the queue runs the web formatter on
    the PR's head on a runner and pushes the fix to the PR's branch."""

    def setUp(self):
        # Landing rechecks eligibility at nb.now(); pin it to the fixtures'
        # clock so their head commits never age past the 5-day limit.
        patcher = mock.patch.object(nb, "now", return_value=NOW)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        self.root = root / "repo"
        self.root.mkdir()
        self.git("init", "-q", "-b", "lane")
        (self.root / "a.ts").write_text("let a=1\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "pr")
        self.head = self.git("rev-parse", "HEAD")
        (self.root / "a.ts").write_text("let a = 1;\n")
        self.git("commit", "-q", "-am", "next-batch: format webviews")
        self.patch = subprocess.run(["git", "format-patch", "-1", "--binary", "--stdout"], cwd=self.root,
                                    env=self.env, check=True, capture_output=True).stdout
        self.git("reset", "-q", "--hard", self.head)

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.root, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def controller(self, result: dict) -> tuple[nb.Controller, list]:
        controller = nb.Controller.__new__(nb.Controller)
        controller.worktree = Path(self.tmp.name) / "stack"
        calls = []

        def mini(mode, branch, sha, extra):
            calls.append((mode, sha, extra.get("kinds")))
            return {}, result

        def git(*args, cwd=None):
            if args[0] == "push":
                calls.append(("push", args[-1], None))
                return ""
            return subprocess.run(["git", *args], cwd=cwd or self.root, env=self.env, check=True,
                                  capture_output=True, text=True).stdout.strip()

        controller.mini, controller.git = mini, git
        return controller, calls

    def test_formats_on_a_runner_and_pushes_to_the_pr_branch(self):
        controller, calls = self.controller({"ok": True, "patch": self.patch})
        target = pr(9, sha=self.head, head_ref="lane-9", files=["webviews/a.ts"])
        with mock.patch.dict(os.environ, self.env):
            sha = controller.format_pr(target, "next-batch/x-1")
        self.assertEqual(calls[0], ("regen-linux", self.head, "format"))
        self.assertEqual(calls[1][0], "push")
        self.assertEqual(calls[1][1], f"{sha}:refs/heads/lane-9")
        self.assertNotEqual(sha, self.head)
        self.assertEqual(self.git("show", f"{sha}:a.ts"), "let a = 1;")

    def test_nothing_to_format_pushes_nothing(self):
        controller, calls = self.controller({"ok": True})
        target = pr(9, sha=self.head, head_ref="lane-9", files=["webviews/a.ts"])
        self.assertEqual(controller.format_pr(target, "next-batch/x-1"), "")
        self.assertEqual([call[0] for call in calls], ["regen-linux"])

    def test_an_owner_push_during_formatting_waits_for_the_next_batch(self):
        controller, _ = self.controller({"ok": True, "patch": self.patch})

        def git(*args, cwd=None):
            if args[0] == "push":
                raise RuntimeError("git push --quiet failed: ! [rejected] (non-fast-forward)")
            return subprocess.run(["git", *args], cwd=cwd or self.root, env=self.env, check=True,
                                  capture_output=True, text=True).stdout.strip()

        controller.git = git
        target = pr(9, sha=self.head, head_ref="lane-9", files=["webviews/a.ts"])
        with mock.patch.dict(os.environ, self.env), self.assertRaises(nb.OwnerPushed):
            controller.format_pr(target, "next-batch/x-1")

    def test_never_pushes_to_a_branch_outside_the_batch_authors(self):
        controller = nb.Controller.__new__(nb.Controller)
        controller.args = Namespace(repo="o/r", dry_run=False, no_land=False, land=False)
        controller.run_url = "u"
        controller.gh = mock.Mock()
        controller.merge_green = lambda: Path("/bin/true")
        controller.comment_once = lambda *args: None
        formatted = []
        controller.format_pr = lambda item, branch: formatted.append(item.number) or "f" * 40
        opted_in = pr(3, author="someone-else", labels=[nb.OPT_IN], files=["webviews/a.ts"],
                      checks=[("web / react-apps-check", "completed", "failure")])
        validation = nb.Validation(name="batch", stack=nb.Stack(base="b", head="h", included=[opted_in]),
                                   branch="next-batch/x-1")
        with mock.patch.object(nb, "open_prs", return_value=[opted_in]):
            controller.land(validation)
        self.assertEqual(formatted, [])

    def test_land_formats_only_a_pr_with_a_red_format_check(self):
        controller = nb.Controller.__new__(nb.Controller)
        controller.args = Namespace(repo="o/r", dry_run=False, no_land=False)
        controller.run_url = "u"
        red = pr(1, files=["webviews/a.ts"], checks=[("web / react-apps-check", "completed", "failure")])
        clean = pr(2, files=["webviews/b.ts"])
        controller.gh = mock.Mock()
        controller.merge_green = lambda: Path("/bin/true")
        controller.comment_once = lambda *args: None
        formatted, merged = [], []
        controller.format_pr = lambda item, branch: formatted.append(item.number) or "f" * 40
        controller.merge_one = lambda helper, item, validation: merged.append(item.number) or "landed"
        validation = nb.Validation(name="batch", stack=nb.Stack(base="b", head="h", included=[red, clean]),
                                   branch="next-batch/x-1")
        with mock.patch.object(nb, "open_prs", return_value=[red, clean]):
            landed = controller.land(validation)
        self.assertEqual(formatted, [1])
        self.assertEqual(merged, [1, 2])
        self.assertEqual([text for _, text in landed], ["landed", "landed"])


class NotifyOwners(unittest.TestCase):
    """Until landing is allowed, serve posts a receipt and the owner lands."""

    def setUp(self):
        # Landing rechecks eligibility at nb.now(); pin it to the fixtures'
        # clock so their head commits never age past the 5-day limit.
        patcher = mock.patch.object(nb, "now", return_value=NOW)
        patcher.start()
        self.addCleanup(patcher.stop)

    def controller(self, notify: bool) -> nb.Controller:
        controller = nb.Controller.__new__(nb.Controller)
        controller.args = Namespace(repo="o/r", dry_run=False, no_land=False, land=not notify)
        controller.run_url = "u"
        controller.gh = mock.Mock()
        controller.merge_green = lambda: Path("/bin/true")
        controller.comments = []
        controller.comment_once = lambda item, kind, body: controller.comments.append((item.number, kind, body))
        controller.merged = []
        controller.merge_one = lambda helper, item, validation: controller.merged.append(item.number) or "landed"
        return controller

    def validation(self, prs, passed=("cmux-next swift test",)) -> nb.Validation:
        return nb.Validation(name="batch", stack=nb.Stack(base="b" * 40, head="h" * 40, included=prs),
                             branch="next-batch/x-1", heavy_url="https://heavy", heavy_passed=list(passed),
                             build={"ok": True, "job_id": "job-7", "link": "cmux-ci artifact job-7"})

    def test_serve_notifies_by_default(self):
        with mock.patch.object(nb, "cmd_serve", lambda args: args), mock.patch.object(nb.subprocess, "run"):
            args = nb.main(["serve", "--worktree", tempfile.mkdtemp() + "/w"])
        self.assertFalse(args.land)

    def test_a_local_run_notifies_and_an_actions_run_lands(self):
        with mock.patch.object(nb, "cmd_run", lambda args: args), mock.patch.object(nb.subprocess, "run"):
            worktree = tempfile.mkdtemp() + "/w"
            self.assertFalse(nb.main(["run", "--local", "--worktree", worktree]).land)
            self.assertTrue(nb.main(["run", "--worktree", worktree]).land)

    def test_notify_posts_a_receipt_and_merges_nothing(self):
        controller = self.controller(notify=True)
        prs = [pr(1), pr(2)]
        with mock.patch.object(nb, "open_prs", return_value=prs):
            landed = controller.land(self.validation(prs))
        self.assertEqual(controller.merged, [])
        self.assertEqual([kind for _, kind, _ in controller.comments], ["receipt", "receipt"])
        self.assertIn("job-7", controller.comments[0][2])
        self.assertIn("land it yourself", controller.comments[0][2])
        self.assertTrue(all(text.startswith("receipt posted") for _, text in landed))

    def test_a_receipt_says_when_the_heavy_tier_did_not_run(self):
        controller = self.controller(notify=True)
        prs = [pr(1)]
        with mock.patch.object(nb, "open_prs", return_value=prs):
            controller.land(self.validation(prs, passed=()))
        self.assertIn("heavy tier did not run", controller.comments[0][2])

    def test_land_flag_merges(self):
        controller = self.controller(notify=False)
        prs = [pr(1)]
        with mock.patch.object(nb, "open_prs", return_value=prs):
            controller.land(self.validation(prs))
        self.assertEqual(controller.merged, [1])


class LocalController(unittest.TestCase):
    """`serve` on a workstation: the operator's gh login, cmux-ci for the build."""

    def controller(self) -> nb.Controller:
        with mock.patch.dict(os.environ, {"GH_TOKEN": "t", "CMUX_NEXT_BATCH_STICKY": "o/hq#5"}):
            return nb.Controller(Namespace(repo="o/r", worktree="/tmp/x", ref="feat-cmux-next", local=True,
                                           dry_run=False, no_land=False, prs="", keep_branches=False))

    def test_links_the_sticky_issue_and_names_the_batch_by_time(self):
        controller = self.controller()
        self.assertEqual(controller.run_url, "https://github.com/o/hq/issues/5")
        self.assertTrue(controller.batch_id.startswith("local-"))

    def test_fleet_build_goes_through_cmux_ci_on_this_host(self):
        controller = self.controller()
        commands = []

        def fake_run(command, **_):
            commands.append(command)
            if command[1] == "build":
                Path(command[command.index("--receipt") + 1]).write_text('{"id": "job-9"}')
            if command[1] == "publish-hq":
                return subprocess.CompletedProcess(command, 0, '{"url": "https://hq.test/b/9"}\n', "")
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch.object(nb.subprocess, "run", fake_run):
            result = controller.fleet_build("next-batch/x-1", "c" * 40, "nb-x-1")
        build = commands[0]
        self.assertEqual(build[:3], ["cmux-ci", "build", "cmux"])
        self.assertIn("--production", build)
        self.assertNotIn("--backend-mode", build)  # cmux-ci refuses offline mode for production
        self.assertEqual(build[build.index("--ref") + 1], "c" * 40)
        self.assertEqual([command[1] for command in commands], ["build", "wait", "publish-hq"])
        self.assertTrue(result["ok"])
        self.assertIn("https://hq.test/b/9", result["link"])

    def test_failed_fleet_job_is_not_ok(self):
        controller = self.controller()

        def fake_run(command, **_):
            if command[1] == "build":
                Path(command[command.index("--receipt") + 1]).write_text('{"id": "job-9"}')
            return subprocess.CompletedProcess(command, 1 if command[1] == "wait" else 0, "", "")

        with mock.patch.object(nb.subprocess, "run", fake_run):
            result = controller.fleet_build("next-batch/x-1", "c" * 40, "nb-x-1")
        self.assertFalse(result["ok"])
        self.assertIn("job-9", result["error"])

    def test_user_token_merges_start_ci_so_nothing_is_redispatched(self):
        controller = self.controller()
        controller.gh = mock.Mock()
        controller.after_landing()
        controller.gh.dispatch.assert_not_called()


class StickyBody(unittest.TestCase):
    def test_newest_on_top_and_history_bounded(self):
        body = ""
        for index in range(12):
            body = nb.sticky_body(f"batch {index}", body, keep=3)
        self.assertTrue(body.startswith(nb.STICKY_MARKER + "\nbatch 11\n"))
        self.assertIn("batch 10", body)
        self.assertIn("batch 8", body)
        self.assertNotIn("batch 7", body)


class LandingRetry(unittest.TestCase):
    def test_red_heavy_check_lands_with_an_override_naming_the_batch(self):
        controller = nb.Controller.__new__(nb.Controller)
        controller.args = Namespace(repo="o/r")
        controller.run_url = "https://example.test/run/1"
        controller.writer = nb.GitHub("o/r")
        validation = nb.Validation(name="batch", stack=nb.Stack(base="b", head="c" * 40))
        calls = []

        def fake_run(command, **_):
            calls.append(command)
            if "--override" not in command:
                return subprocess.CompletedProcess(command, 1, "", "not green: 'cmux-next swift test' is not successful on abc\n")
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch.object(nb.subprocess, "run", fake_run):
            outcome = controller.merge_one(Path("/bin/true"), pr(7), validation)
        self.assertTrue(outcome.startswith("landed"))
        self.assertIn("https://example.test/run/1", calls[-1][calls[-1].index("--override") + 1])

    def test_github_refusal_is_reported_not_retried(self):
        controller = nb.Controller.__new__(nb.Controller)
        controller.args = Namespace(repo="o/r")
        controller.run_url = "u"
        controller.writer = nb.GitHub("o/r")
        validation = nb.Validation(name="batch", stack=nb.Stack(base="b", head="c" * 40))
        refusal = subprocess.CompletedProcess([], 1, "", "not green: GitHub refused to merge o/r#7\n")
        with mock.patch.object(nb.subprocess, "run", return_value=refusal):
            self.assertEqual(controller.merge_one(Path("/bin/true"), pr(7), validation),
                             "not landed: not green: GitHub refused to merge o/r#7")


class WorkflowShape(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.jobs = self.workflow["jobs"]

    def test_nothing_on_a_pull_request_is_cancelled(self):
        """A cancelled debounce read red on every feat-cmux-next PR: a newer run supersedes an
        older wait inside the script instead, and a running batch is never cancelled."""
        self.assertNotIn("concurrency", self.jobs["debounce"])
        self.assertNotIn("concurrency", self.workflow)
        self.assertEqual(self.jobs["batch"]["concurrency"],
                         {"group": "cmux-next-batch", "cancel-in-progress": False})

    def test_debounce_is_skipped_while_the_queue_is_off(self):
        self.assertIn("vars.CMUX_NEXT_BATCH_ENABLED == '1'", self.jobs["debounce"]["if"])

    def test_debounce_runs_the_trusted_controller(self):
        checkout = self.jobs["debounce"]["steps"][0]
        self.assertEqual(checkout["with"]["ref"], "feat-cmux-next")
        self.assertFalse(checkout["with"]["persist-credentials"])
        self.assertIn("head.repo.full_name == github.repository", self.jobs["debounce"]["if"])

    def test_debounce_dispatches_only_when_enabled(self):
        step = self.jobs["debounce"]["steps"][-1]
        self.assertEqual(step["env"]["ENABLED"], "${{ vars.CMUX_NEXT_BATCH_ENABLED }}")
        self.assertIn('[[ "$ENABLED" == 1 ]]', step["run"])

    def test_batch_checkout_keeps_the_token_out_of_git_config(self):
        checkout = self.jobs["batch"]["steps"][0]
        self.assertFalse(checkout["with"]["persist-credentials"])

    def test_mini_jobs_only_touch_next_batch_branches(self):
        for job in ("regen", "regen-linux", "build"):
            with self.subTest(job=job):
                self.assertIn("startsWith(inputs.branch, 'next-batch/')", self.jobs[job]["if"])

    def test_dispatch_inputs_match_the_controller(self):
        inputs = self.workflow[True]["workflow_dispatch"]["inputs"]
        for name in ("mode", "prs", "branch", "sha", "tag", "nonce", "reason"):
            self.assertIn(name, inputs)
        self.assertIn("next-batch-regen", WORKFLOW.read_text())
        self.assertIn("next-batch-build", WORKFLOW.read_text())
        self.assertIn("kinds", inputs)

    def test_swift_generator_script_comes_from_the_workflow_ref(self):
        steps = self.jobs["regen"]["steps"]
        tools = next(step for step in steps if step.get("with", {}).get("path") == ".next-batch-tools")
        self.assertEqual(tools["with"]["ref"], "${{ github.sha }}")
        regen = next(step for step in steps if step.get("id") == "regen")
        self.assertIn(".next-batch-tools/scripts/cmux-next/regenerate-swift-exports.sh", regen["run"])

    def test_regen_linux_runs_the_web_formatter_and_lint_autofix(self):
        script = "\n".join(step.get("run", "") for step in self.jobs["regen-linux"]["steps"])
        self.assertIn('*" format "*', script)
        self.assertIn("bun run check:fix", script)

    def test_regeneration_jobs_return_a_patch_and_never_push(self):
        for job in ("regen", "regen-linux"):
            with self.subTest(job=job):
                spec = self.jobs[job]
                self.assertEqual(spec.get("permissions"), {"contents": "read"})
                script = "\n".join(step.get("run", "") for step in spec["steps"])
                self.assertNotIn("git push", script)
                self.assertNotIn("git -c", script.replace("git -c user.", ""))
                self.assertIn("format-patch", script)
                self.assertFalse(any("secrets." in json.dumps(step) for step in spec["steps"]))

    def run_format(self, bun: str) -> dict:
        """Run regen-linux's real step script for `kinds: format` with a stub bun."""
        step = next(s for s in self.jobs["regen-linux"]["steps"] if "check:fix" in s.get("run", ""))
        with tempfile.TemporaryDirectory() as tmp:
            work, bin_dir, temp = Path(tmp, "work"), Path(tmp, "bin"), Path(tmp, "temp")
            for path in (work / "webviews", bin_dir, temp):
                path.mkdir(parents=True)
            (bin_dir / "bun").write_text(f"#!/bin/sh\n{bun}\n")
            (bin_dir / "bun").chmod(0o755)
            subprocess.run(["git", "init", "-q"], cwd=work, check=True)
            env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "KINDS": "format",
                   "RUNNER_TEMP": str(temp), "SERVER_URL": "https://github.com",
                   "REPOSITORY": "manaflow-ai/cmux", "GITHUB_RUN_ID": "1"}
            subprocess.run(["bash", "-c", step["run"]], cwd=work, env=env, check=True,
                           capture_output=True)
            return json.loads((temp / "result/result.json").read_text())

    def test_a_failed_install_is_not_a_clean_format(self):
        # Codex CI audit (#20763): `bun install && bun run check:fix || echo`
        # turned a failed install into {"ok": true} with no patch, which the
        # controller reads as "nothing to fix".
        result = self.run_format('[ "$1" = install ] && exit 1; exit 0')
        self.assertFalse(result["ok"], result)
        self.assertIn("bun install", result["error"])

    def test_check_fix_leftovers_still_keep_what_it_fixed(self):
        self.assertTrue(self.run_format('[ "$1" = install ] && exit 0; exit 1')["ok"])


if __name__ == "__main__":
    unittest.main()

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
import threading
import unittest
from argparse import Namespace
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import next_batch as nb  # noqa: E402

# The suite also runs on Actions. Start every test from a host environment, so the
# "never land from Actions" refusal (landing_refusal) applies only where a test sets
# GITHUB_ACTIONS itself, and a runner's own batch settings never leak into a case.
for _name in [n for n in os.environ if n == "GITHUB_ACTIONS" or n.startswith("CMUX_NEXT_BATCH_")]:
    del os.environ[_name]

WORKFLOW = ROOT / ".github/workflows/cmux-next-batch.yml"
NOW = dt.datetime(2026, 10, 6, 5, 0, tzinfo=dt.timezone.utc)
PANE = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/pane.js"


def pr(number: int, **fields) -> nb.PullRequest:
    defaults = dict(sha=f"{number:040x}", title=f"PR {number}", author="teamleaderleo",
                    committed_at="2026-10-06T04:00:00Z", head_ref=f"lane-{number}")
    defaults.update(fields)
    return nb.PullRequest(number=number, **defaults)


def reviewed_heads(text: str) -> Path:
    """A CMUX_NEXT_BATCH_REVIEWED file as the reviewer writes it: owned by this user, writable by nobody else.

    The mode is set, not left to the umask: next_batch.reviewed() ignores a group- or world-writable
    file, so under a umask of 002 (Ubuntu's default for a login shell) a plain write_text() reads as
    "not reviewed" and every landing test fails for the wrong reason.
    """
    path = Path(tempfile.mkdtemp()) / "reviewed"
    path.write_text(text)
    path.chmod(0o600)
    return path


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

    def test_override_label_actors_come_from_the_list_query_after_the_head_commit(self):
        """#21925 on top of #21891's two-query list: who applied a label still arrives
        with the light list, and only an application after the head's commit counts."""
        node = self.node(1)
        committed = node["commits"]["nodes"][0]["commit"]["committedDate"]
        before = (dt.datetime.fromisoformat(committed) - dt.timedelta(hours=1)).isoformat()
        after = (dt.datetime.fromisoformat(committed) + dt.timedelta(minutes=5)).isoformat()
        node["labels"] = {"nodes": [{"name": nb.OVERRIDE_ALONE}, {"name": "stale"}]}
        node["timelineItems"] = {"nodes": [
            {"createdAt": after, "label": {"name": nb.OVERRIDE_ALONE}, "actor": {"login": "lawrencecchen"}},
            {"createdAt": before, "label": {"name": "stale"}, "actor": {"login": "lawrencecchen"}},
            {},
        ]}
        pages = [{"repository": {"pullRequests": {"nodes": [node],
                                                  "pageInfo": {"hasNextPage": False, "endCursor": None}}}}]
        gh, _ = self.fake(pages, {("PR_1", ""): (["a.swift"], [], None)})
        with mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_AUTHORS": ""}):
            [item] = nb.open_prs(gh)
        self.assertEqual(item.label_actors, {nb.OVERRIDE_ALONE: "lawrencecchen"})
        self.assertIn("LABELED_EVENT", nb.LIST_QUERY)

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


CHECKS_LOG = """\
2026-10-19T03:02:59.3742502Z \x1b[36;1m  echo "### ${#failed[@]} cmux-next check(s) failed"\x1b[0m
2026-10-19T03:02:59.3742784Z \x1b[36;1m  printf -- '- %s\\n' "${failed[@]}"\x1b[0m
2026-10-19T03:02:59.3791306Z ### 2 cmux-next check(s) failed
2026-10-19T03:02:59.3791407Z 
2026-10-19T03:02:59.3791459Z - Type scale (failure)
2026-10-19T03:02:59.3791577Z - Tier routing (failure)
2026-10-19T03:02:59.3791651Z 
2026-10-19T03:02:59.3791707Z Each check's own step log has the details.
2026-10-19T03:02:59.3792894Z ##[error]Process completed with exit code 1.
"""


class BaseReds(unittest.TestCase):
    """Base pushes and dispatches skip the checks job, so the batch validates the
    base itself and compares single checks, not the whole job."""

    def controller(self) -> nb.Controller:
        controller = nb.Controller.__new__(nb.Controller)
        controller.args = Namespace(repo="o/r", dry_run=False, keep_branches=False)
        controller.gh = mock.Mock()
        controller.base_failures = None
        controller.base_probe = None
        controller.base_probe_result = {}
        controller.base_probe_stop = threading.Event()
        controller.base_tree_waited = False
        controller.base_sha = "b" * 40
        controller.batch_id = "local-1"
        return controller

    def test_reads_the_red_checks_from_the_jobs_last_step(self):
        self.assertEqual(nb.red_subchecks(CHECKS_LOG), ["Type scale", "Tier routing"])
        self.assertEqual(nb.red_subchecks("no listing here\n"), [])

    def test_a_red_checks_job_counts_each_red_check(self):
        controller = self.controller()
        controller.gh.api.return_value = {"jobs": [
            {"id": 7, "name": nb.CHECKS_JOB, "conclusion": "failure"},
            {"id": 8, "name": "cmux-next swift test", "conclusion": "failure"},
            {"id": 9, "name": "cmux-next daemon tests", "conclusion": "success"},
        ]}
        controller.gh.gh.return_value = subprocess.CompletedProcess([], 0, CHECKS_LOG, "")
        self.assertEqual(controller.failed_jobs(1), [
            f"{nb.CHECKS_JOB}: Tier routing", f"{nb.CHECKS_JOB}: Type scale", "cmux-next swift test"])
        self.assertIn("actions/jobs/7/logs", " ".join(controller.gh.gh.call_args.args))

    def test_an_unreadable_log_keeps_the_job(self):
        controller = self.controller()
        controller.gh.gh.return_value = subprocess.CompletedProcess([], 1, "", "not found")
        self.assertEqual(controller.expand_job(nb.CHECKS_JOB, 7), {nb.CHECKS_JOB})

    def test_job_log_uses_the_flag_with_old_gh_fallback(self):
        controller = self.controller()
        controller.gh.gh.side_effect = [
            subprocess.CompletedProcess([], 1, "", "unknown flag: --allow-escape-sequences\n\nUsage:  gh api"),
            subprocess.CompletedProcess([], 0, CHECKS_LOG, "")]
        self.assertEqual(controller.job_log(7), CHECKS_LOG)
        self.assertEqual([c.args for c in controller.gh.gh.call_args_list],
                         [("api", "--allow-escape-sequences", "repos/o/r/actions/jobs/7/logs"),
                          ("api", "repos/o/r/actions/jobs/7/logs")])

    def test_any_other_log_failure_is_not_retried(self):
        controller = self.controller()
        controller.gh.gh.return_value = subprocess.CompletedProcess([], 1, "", "gh: Not Found (HTTP 404)")
        self.assertIsNone(controller.job_log(7))
        self.assertEqual(controller.gh.gh.call_count, 1)

    def test_the_probes_reds_are_the_inherited_ones(self):
        controller = self.controller()
        controller.base_probe_result = {"failed": {f"{nb.CHECKS_JOB}: Type scale"}}
        self.assertEqual(controller.failing_on_base("b" * 40), {f"{nb.CHECKS_JOB}: Type scale"})
        controller.gh.runs.assert_not_called()

    def test_without_a_probe_only_outright_failures_in_the_push_run_count(self):
        controller = self.controller()
        controller.gh.runs.return_value = [{"id": 1, "status": "completed", "head_branch": nb.BASE}]
        controller.gh.api.return_value = {"jobs": [
            {"id": 7, "name": "cmux-next generated files", "conclusion": "cancelled"},
            {"id": 8, "name": "cmux app scheme compile (Debug)", "conclusion": "failure"},
        ]}
        controller.gh.gh.return_value = subprocess.CompletedProcess([], 0, "2026-10-19T03:02:59.1Z error: x\n", "")
        self.assertEqual(controller.failing_on_base("b" * 40), {"cmux app scheme compile (Debug): error error: x"})
        self.assertIn("event=push", controller.gh.runs.call_args_list[0].args[1])

    def test_without_a_probe_the_newest_base_tier_run_stands_in_for_its_jobs(self):
        # cmuxterm-hq#5424: a feat-cmux-next push no longer runs daemon tests, generated files or the
        # Debug scheme compile; a `cmux-next base tier · <sha>` dispatch does, at most every 15 minutes.
        controller = self.controller()
        tier = {"id": 2, "status": "completed", "conclusion": "failure", "head_branch": nb.BASE,
                "display_title": "cmux-next base tier · " + "c" * 40, "created_at": "2026-10-30T12:00:00Z"}
        dev = {"id": 3, "status": "completed", "conclusion": "failure", "head_branch": nb.BASE,
               "display_title": "cmux NEXT DEV daily · " + "c" * 40}
        controller.gh.runs.side_effect = [[{"id": 1, "status": "completed", "head_branch": nb.BASE}], [dev, tier]]
        jobs = {1: [{"id": 7, "name": "cmux-next Release compile (Xcode 26)", "conclusion": "success"}],
                2: [{"id": 8, "name": "cmux-next daemon tests", "conclusion": "failure"},
                    {"id": 9, "name": "cmux-next checks (god files, concurrency, crash safety, l10n)",
                     "conclusion": "failure"}]}
        controller.gh.api.side_effect = lambda route, **_: {"jobs": jobs[int(route.split("/runs/")[1].split("/")[0])]}
        controller.gh.gh.return_value = subprocess.CompletedProcess([], 0, "2026-10-19T03:02:59.1Z error: y\n", "")
        self.assertEqual(controller.failing_on_base("b" * 40), {"cmux-next daemon tests: error error: y"})
        listed = controller.gh.runs.call_args_list[1].args[1]
        # Review of this change: where the base's own push run has a verdict for the job (coalescing off, or
        # a push that kept its scheme compile), an older base tier red is not inherited.
        jobs[1].append({"id": 10, "name": "cmux-next daemon tests", "conclusion": "success"})
        controller.base_failures = None
        controller.gh.runs.side_effect = [[{"id": 1, "status": "completed", "head_branch": nb.BASE}], [dev, tier]]
        self.assertEqual(controller.failing_on_base("b" * 40), set())
        self.assertIn("event=workflow_dispatch", listed)
        self.assertIn("status=completed", listed)

    def test_a_base_tier_run_that_skipped_a_job_never_hides_an_older_red(self):
        # Review of this change: a base tier run whose cmux-tui tree was not published yet skips the
        # daemon tests and the scheme compile (its same-tree run carries them) and can end green. Each
        # job's verdict comes from the newest base tier run that ran it.
        controller = self.controller()
        title = "cmux-next base tier · "
        newest = {"id": 2, "status": "completed", "conclusion": "success", "head_branch": nb.BASE,
                  "display_title": title + "d" * 40, "created_at": "2026-10-30T12:15:00Z"}
        older = {"id": 3, "status": "completed", "conclusion": "failure", "head_branch": nb.BASE,
                 "display_title": title + "c" * 40, "created_at": "2026-10-30T12:00:00Z"}
        controller.gh.runs.side_effect = [[{"id": 1, "status": "completed", "head_branch": nb.BASE}], [newest, older]]
        jobs = {1: [{"id": 7, "name": "cmux-next Release compile (Xcode 26)", "conclusion": "success"}],
                2: [{"id": 8, "name": "cmux-next daemon tests", "conclusion": "skipped"},
                    {"id": 9, "name": "cmux-next generated files", "conclusion": "success"}],
                3: [{"id": 10, "name": "cmux-next daemon tests", "conclusion": "failure"},
                    {"id": 11, "name": "cmux-next generated files", "conclusion": "failure"}]}
        controller.gh.api.side_effect = lambda route, **_: {"jobs": jobs[int(route.split("/runs/")[1].split("/")[0])]}
        controller.gh.gh.return_value = subprocess.CompletedProcess([], 0, "2026-10-19T03:02:59.1Z error: y\n", "")
        # The daemon red is the older run's; generated files passed in the newest run, so its older red is not.
        self.assertEqual(controller.failing_on_base("b" * 40), {"cmux-next daemon tests: error error: y"})

    def test_cancelled_base_tier_runs_never_count_toward_the_lookback(self):
        # The base tier kick cancels superseded base tier runs before a Mac job starts; more of them than
        # the lookback must not hide the newest run with a verdict.
        controller = self.controller()
        title = "cmux-next base tier · "
        cancelled = [{"id": 100 + n, "status": "completed", "conclusion": "cancelled", "head_branch": nb.BASE,
                      "display_title": title + f"{n:x}" * 40} for n in range(nb.BASE_TIER_LOOKBACK + 2)]
        tier = {"id": 2, "status": "completed", "conclusion": "failure", "head_branch": nb.BASE,
                "display_title": title + "c" * 40, "created_at": "2026-10-30T12:00:00Z"}
        controller.gh.runs.side_effect = [[{"id": 1, "status": "completed", "head_branch": nb.BASE}], cancelled + [tier]]
        jobs = {1: [{"id": 7, "name": "cmux-next Release compile (Xcode 26)", "conclusion": "success"}],
                2: [{"id": 8, "name": "cmux-next daemon tests", "conclusion": "failure"}]}
        controller.gh.api.side_effect = lambda route, **_: {"jobs": jobs[int(route.split("/runs/")[1].split("/")[0])]}
        controller.gh.gh.return_value = subprocess.CompletedProcess([], 0, "2026-10-19T03:02:59.1Z error: y\n", "")
        self.assertEqual(controller.failing_on_base("b" * 40), {"cmux-next daemon tests: error error: y"})

    def test_a_stack_waits_once_for_the_bases_own_tree_run(self):
        controller = self.controller()
        controller.gh.runs.return_value = [
            {"id": 3, "status": "in_progress", "head_branch": nb.BASE, "html_url": "u"},
            {"id": 4, "status": "in_progress", "head_branch": "next-batch/x-1", "html_url": "u"},
            {"id": 5, "status": "completed", "head_branch": nb.BASE, "html_url": "u"},
        ]
        waited = []
        controller.wait_run = lambda run_id, timeout: waited.append(run_id) or {"status": "completed"}
        controller.wait_base_tree()
        controller.wait_base_tree()
        self.assertEqual(waited, [3])
        self.assertEqual(controller.gh.runs.call_args.args[0], nb.TUI_WORKFLOW)

    def test_a_cancelled_probe_is_never_rerun(self):
        controller = self.controller()
        controller.push = lambda sha, ref: None
        controller.find_run = lambda workflow, branch, match, since: {"id": 5, "html_url": "https://probe"}
        controller.wait_run = lambda run_id, timeout: {"status": "completed", "conclusion": "cancelled"}
        controller.failed_jobs = lambda run_id, detail=False: ["cmux-next swift test"]
        controller.probe_base()
        self.assertNotIn("rerun", [call.args[0] for call in controller.gh.gh.call_args_list])
        self.assertNotIn("failed", controller.base_probe_result)

    def test_a_batch_that_ends_first_cancels_the_probes_run(self):
        controller = self.controller()
        controller.base_probe = mock.Mock(is_alive=lambda: True)
        controller.base_probe_result = {"run": 42}
        controller.stop_base_probe()
        self.assertEqual(controller.gh.gh.call_args.args[:3], ("run", "cancel", "42"))

    def test_the_probe_validates_the_base_on_its_own_branch(self):
        controller = self.controller()
        pushed = []
        controller.push = lambda sha, ref: pushed.append((sha, ref))
        controller.find_run = lambda workflow, branch, match, since: {"id": 5, "html_url": "https://probe"}
        controller.wait_run = lambda run_id, timeout: {"status": "completed"}
        controller.failed_jobs = lambda run_id, detail=False: [f"{nb.CHECKS_JOB}: Type scale"]
        with mock.patch.object(nb.time, "sleep"):
            controller.probe_base()
        self.assertEqual(pushed, [("b" * 40, "next-batch/local-1-base")])
        controller.gh.dispatch.assert_called_once_with(nb.HEAVY_WORKFLOW, "next-batch/local-1-base")
        self.assertEqual(controller.base_probe_result["failed"], {f"{nb.CHECKS_JOB}: Type scale"})
        self.assertEqual(controller.base_probe_result["url"], "https://probe")


    def test_a_base_red_job_excuses_only_the_tests_that_fail_on_the_base(self):
        """A red swift test on the base must not excuse a stack that breaks another test."""
        controller = self.controller()
        steps = [{"name": "Set up job", "conclusion": "success"}, {"name": "Run tests", "conclusion": "failure"}]
        job = {"id": 8, "name": "cmux-next swift test", "conclusion": "failure", "steps": steps}
        controller.gh.api.return_value = {"jobs": [job]}

        def failing(*tests):
            text = "".join(f"2026-10-19T03:02:59.1Z \u2718 Test {name} recorded an issue at A.swift:1:2: x\n" for name in tests)
            return subprocess.CompletedProcess([], 0, text, "")

        controller.gh.gh.return_value = failing("alpha()")
        base = set(controller.failed_jobs(1, detail=True))
        controller.gh.gh.return_value = failing("alpha()", "beta()")
        stack = set(controller.failed_jobs(2, detail=True))
        self.assertIn("cmux-next swift test: test beta()", stack - base)
        controller.gh.gh.return_value = failing("alpha()")
        self.assertEqual(set(controller.failed_jobs(3, detail=True)) - base, set())
        # Job-level names stay for the base-red comparison's lanes.
        self.assertEqual(controller.failed_jobs(1), ["cmux-next swift test"])

    def test_a_job_with_nothing_to_compare_is_never_excused_by_its_steps(self):
        """A timeout or a crash leaves only the failed step; the base failing that step for another reason excuses nothing."""
        controller = self.controller()
        steps = [{"name": "Run tests", "conclusion": "failure"}]
        controller.gh.api.return_value = {"jobs": [
            {"id": 8, "name": "cmux-next swift test", "conclusion": "failure", "steps": steps}]}
        controller.gh.gh.return_value = subprocess.CompletedProcess(
            [], 0, "2026-10-19T03:02:59.1Z \u2718 Test alpha() recorded an issue at A.swift:1:2: x\n", "")
        base = set(controller.failed_jobs(1, detail=True))
        controller.gh.gh.return_value = subprocess.CompletedProcess([], 0, "2026-10-19T03:02:59.1Z still running\n", "")
        self.assertEqual(set(controller.failed_jobs(2, detail=True)) - base, {"cmux-next swift test"})
        crash = "2026-10-19T03:02:59.1Z error: Exited with unexpected signal code 5\n".replace("Exited", "exited")
        controller.gh.gh.return_value = subprocess.CompletedProcess([], 0, crash, "")
        stack = set(controller.failed_jobs(3, detail=True))
        self.assertIn("cmux-next swift test: the test process crashed (signal 5) (job 8, never a base red)", stack - base)
        # The same crash on the base excuses nothing: each crash is keyed by its own job.
        controller.gh.api.return_value = {"jobs": [
            {"id": 9, "name": "cmux-next swift test", "conclusion": "failure", "steps": steps}]}
        self.assertEqual(stack - set(controller.failed_jobs(4, detail=True)), stack)

    def test_a_non_test_jobs_crash_signal_still_keys_its_failure(self):
        controller = self.controller()
        steps = [{"name": "Build", "conclusion": "failure"}]
        controller.gh.gh.return_value = subprocess.CompletedProcess(
            [], 0, "2026-10-19T03:02:59.1Z the test helper died on signal 11\n", "")
        self.assertIn("cmux app scheme compile (Debug): the test process crashed (signal 11) (job 5, never a base red)",
                      controller.expand_job("cmux app scheme compile (Debug)", 5, {"steps": steps}))

    def test_a_non_test_job_cut_short_or_crash_never_matches_a_base_red(self):
        controller = self.controller()
        steps = [{"name": "Build", "conclusion": "failure"}]
        # No test name is present: test_reds still records the abnormal end, and the
        # job must remain keyed to its own run instead of inheriting a base job red.
        cut_short = ("2026-10-19T03:02:59.1Z ##[error]no \"Test run with\" summary line "
                     "(crash, kill or truncation); 0 tests started\n")
        controller.gh.gh.return_value = subprocess.CompletedProcess([], 0, cut_short, "")
        result = controller.expand_job("cmux-next generated files", 5, {"steps": steps})
        self.assertTrue(any("never a base red" in item for item in result), result)

        crashed = "2026-10-19T03:02:59.1Z ##[error]Process completed with exit code 139.\n"
        controller.gh.gh.return_value = subprocess.CompletedProcess([], 0, crashed, "")
        result = controller.expand_job("cmux app scheme compile (Debug)", 6, {"steps": steps})
        self.assertTrue(any("never a base red" in item for item in result), result)

    def test_an_unreadable_no_verdict_compile_log_is_keyed_by_its_own_job(self):
        controller = self.controller()
        steps = [{"name": "Wait", "conclusion": "failure"}]
        controller.gh.gh.return_value = subprocess.CompletedProcess([], 1, "", "boom")
        for name in ("cmux-next fleet Release compile", "cmux-next app compile (build fleet)"):
            with self.subTest(name=name):
                self.assertEqual(controller.expand_job(name, 7, {"steps": steps}),
                                 {f"{name}: log unreadable (job 7, never a base red)"})

    def test_a_compile_with_no_verdict_is_keyed_by_its_own_job(self):
        """The fleet Release compile's "no result" compiled nothing: the base showing the same line (its own
        sha aside) excuses nothing."""
        controller = self.controller()
        name = "cmux-next fleet Release compile"
        steps = [{"name": "Wait for the fleet Release compile and publish cmux-next/compile", "conclusion": "failure"}]

        def no_result(sha):
            return subprocess.CompletedProcess(
                [], 0, f"2026-10-28T08:40:00.1Z ##[error]cmux-next/compile is not a pass for {sha} (no result)\n", "")

        controller.gh.gh.return_value = no_result("7ea21d1ce82ffaecc58599ae3f6bbf95afd92c51")
        base = controller.expand_job(name, 4, {"steps": steps})
        controller.gh.gh.return_value = no_result("df40f81342c8bb1eb135ced40728a4e7a090ed49")
        stack = controller.expand_job(name, 5, {"steps": steps})
        self.assertEqual(stack, {f"{name}: no compile verdict (job 5, never a base red)"})
        self.assertEqual(stack - base, stack)

    def test_an_unreadable_log_fails_closed_only_for_a_test_job(self):
        controller = self.controller()
        steps = [{"name": "Build", "conclusion": "failure"}]
        controller.gh.gh.return_value = subprocess.CompletedProcess([], 1, "", "boom")
        self.assertEqual(controller.expand_job("cmux app scheme compile (Debug)", 5, {"steps": steps}),
                         {"cmux app scheme compile (Debug)"})
        self.assertEqual(controller.expand_job("cmux-next swift test", 6, {"steps": steps}),
                         {"cmux-next swift test: log unreadable (job 6, never a base red)"})

    def test_a_probe_stopped_before_its_run_is_found_cancels_it(self):
        controller = self.controller()
        controller.push = lambda sha, ref: None
        deleted = []
        controller.delete_branch = deleted.append

        def find_run(workflow, branch, match, since):
            controller.base_probe_stop.set()  # the batch ended while the probe looked for its run
            return {"id": 5, "html_url": "https://probe"}

        controller.find_run = find_run
        controller.wait_run = mock.Mock()
        controller.probe_base()
        controller.wait_run.assert_not_called()
        self.assertIn(("run", "cancel", "5"), [call.args[:3] for call in controller.gh.gh.call_args_list])
        self.assertEqual(deleted, ["next-batch/local-1-base"])
        self.assertNotIn("failed", controller.base_probe_result)

    def test_a_probe_whose_rerun_does_not_finish_records_nothing(self):
        controller = self.controller()
        controller.push = lambda sha, ref: None
        controller.find_run = lambda workflow, branch, match, since: {"id": 5, "html_url": "https://probe"}
        states = iter([{"status": "completed", "conclusion": "failure"}, {"status": "in_progress"}])
        controller.wait_run = lambda run_id, timeout: next(states)
        controller.failed_jobs = lambda run_id, detail=False: ["cmux-next swift test: test flaky()"]
        with mock.patch.object(nb.time, "sleep"):
            controller.probe_base()
        self.assertNotIn("failed", controller.base_probe_result)

    def test_a_batch_that_raises_still_cleans_up(self):
        controller = self.controller()
        controller.args = Namespace(repo="o/r", dry_run=False, no_land=False, keep_branches=False, prs="7")
        controller.reported = lambda pr, kinds: ""
        controller.validations = []
        controller.base_probe_result = {"branch": "next-batch/local-1-base", "run": 9}
        controller.base_probe = mock.Mock(is_alive=lambda: True)
        deleted = []
        controller.delete_branch = deleted.append

        def validate(prs, name):
            controller.validations.append(nb.Validation(name=name, stack=nb.Stack(base="b", head="c"),
                                                        branch="next-batch/local-1-1"))
            raise RuntimeError("HTTP 502")

        controller.validate = validate
        with mock.patch.object(nb, "open_prs", return_value=[]), \
                mock.patch.object(nb, "select", return_value=([pr(7)], {})), \
                mock.patch.object(nb, "admit_reviewed", return_value=([pr(7)], {})), \
                mock.patch.object(nb, "freeze_check", return_value=(0, "")):
            with self.assertRaises(RuntimeError):
                controller.run()
        self.assertEqual(deleted, ["next-batch/local-1-1", "next-batch/local-1-base"])
        self.assertIn(("run", "cancel", "9"), [call.args[:3] for call in controller.gh.gh.call_args_list])

class TreeInputs(unittest.TestCase):
    def test_a_tree_input_outside_cmux_tui_counts_and_other_files_do_not(self):
        root = Path(tempfile.mkdtemp())
        (root / "scripts/cmux-next").mkdir(parents=True)
        (root / nb.TREE_INPUTS).write_text("# inputs\ntree first-party-apps/cloud/server\nfile schemas/x/vectors.json\n")
        self.assertTrue(nb.touches_tree(["schemas/x/vectors.json"], root))
        self.assertTrue(nb.touches_tree(["first-party-apps/cloud/server/main.rs"], root))
        self.assertTrue(nb.touches_tree(["cmux-tui/crates/a.rs"], root))
        self.assertFalse(nb.touches_tree(["webviews/src/a.tsx", "schemas/x/other.json"], root))


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
        controller.comment_once = lambda *args: None
        formatted, merged = [], []
        controller.format_pr = lambda item, branch: formatted.append(item.number) or "f" * 40
        controller.merge_one = lambda item, validation: merged.append(item.number) or "landed"
        validation = nb.Validation(name="batch", stack=nb.Stack(base="b", head="h", included=[red, clean]),
                                   branch="next-batch/x-1")
        reviewed = reviewed_heads(f"1 {red.sha}\n2 {clean.sha}\n")
        with mock.patch.object(nb, "open_prs", return_value=[red, clean]), \
                mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_REVIEWED": str(reviewed)}):
            landed = controller.land(validation)
        self.assertEqual(formatted, [1])
        # The pushed formatting is a new head nobody validated or reviewed, and the
        # PR stacked on top of it was validated with it, so neither lands now.
        self.assertEqual(merged, [])
        self.assertIn("formatted", landed[0][1])
        self.assertIn("earlier PR in this stack", landed[1][1])


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
        controller.comments = []
        controller.comment_once = lambda item, kind, body: controller.comments.append((item.number, kind, body))
        controller.merged = []
        controller.merge_one = lambda item, validation: controller.merged.append(item.number) or "landed"
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

    def test_land_flag_merges_a_head_reviewed_at_its_exact_sha(self):
        controller = self.controller(notify=False)
        prs = [pr(1)]
        reviewed = reviewed_heads(f"# coord-2's reviewed heads\n1 {pr(1).sha}\n")
        with mock.patch.object(nb, "open_prs", return_value=prs), \
                mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_REVIEWED": str(reviewed)}):
            controller.land(self.validation(prs))
        self.assertEqual(controller.merged, [1])


class ReviewGate(NotifyOwners):
    """The queue lands only heads an independent review approved at that exact SHA."""

    def land(self, prs, env=None, statuses=None):
        controller = self.controller(notify=False)
        controller.gh.api = mock.Mock(return_value=statuses or [])
        with mock.patch.object(nb, "open_prs", return_value=prs), mock.patch.dict(os.environ, env or {}, clear=False):
            for key in ("CMUX_NEXT_BATCH_REVIEWED", "CMUX_NEXT_BATCH_REVIEWERS"):
                if key not in (env or {}):
                    os.environ.pop(key, None)
            landed = controller.land(self.validation(prs))
        return controller, dict((item.number, text) for item, text in landed)

    def test_an_unreviewed_head_gets_a_receipt_and_is_not_merged(self):
        controller, landed = self.land([pr(1)])
        self.assertEqual(controller.merged, [])
        self.assertIn("not reviewed at this head", landed[1])
        # A note, not a receipt: a receipt would keep it out of the batch after its review.
        self.assertEqual([kind for _, kind, _ in controller.comments], ["validated"])

    def test_a_review_of_an_older_head_does_not_count(self):
        reviewed = reviewed_heads(f"1 {'f' * 40}\n")
        controller, landed = self.land([pr(1)], {"CMUX_NEXT_BATCH_REVIEWED": str(reviewed)})
        self.assertEqual(controller.merged, [])

    def test_a_status_counts_only_from_a_named_reviewer(self):
        status = lambda login: [{"context": "review/independent", "state": "success", "creator": {"login": login}}]
        env = {"CMUX_NEXT_BATCH_REVIEWERS": "cmux-review-bot"}
        controller, _ = self.land([pr(1)], env, status("teamleaderleo"))
        self.assertEqual(controller.merged, [])  # every lane runs gh as teamleaderleo
        controller, _ = self.land([pr(1)], env, status("cmux-review-bot"))
        self.assertEqual(controller.merged, [1])


class ReviewGateHoles(NotifyOwners):
    """Review findings on #21925: every way an unreviewed head could still land."""

    def reviewed_file(self, *items):
        return str(reviewed_heads("".join(f"{item.number} {item.sha}\n" for item in items)))

    def test_only_reviewed_prs_are_stacked_when_landing(self):
        gh = mock.Mock()
        with mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_REVIEWED": self.reviewed_file(pr(2))}):
            admitted, waiting = nb.admit_reviewed([pr(1), pr(2)], gh, landing=True)
            self.assertEqual([item.number for item in admitted], [2])
            self.assertIn("review", waiting[1])
            # Receipt mode lands nothing, so everything is validated.
            admitted, waiting = nb.admit_reviewed([pr(1), pr(2)], gh, landing=False)
            self.assertEqual([item.number for item in admitted], [1, 2])

    def test_a_statuses_error_counts_as_not_reviewed(self):
        gh = mock.Mock(repo="o/r")
        gh.api.side_effect = RuntimeError("HTTP 502")
        with mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_REVIEWERS": "cmux-review-bot"}):
            os.environ.pop("CMUX_NEXT_BATCH_REVIEWED", None)
            self.assertFalse(nb.reviewed(pr(1), gh))

    def test_a_reviewed_file_others_can_write_is_ignored(self):
        path = self.reviewed_file(pr(1))
        Path(path).chmod(0o666)
        with mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_REVIEWED": path}):
            self.assertFalse(nb.reviewed(pr(1)))

    def test_actions_never_lands_without_coord2_s_list(self):
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}):
            os.environ.pop("CMUX_NEXT_BATCH_EXCLUDE", None)
            self.assertIn("CMUX_NEXT_BATCH_EXCLUDE", nb.landing_refusal())
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "", "CMUX_NEXT_BATCH_EXCLUDE": ""}):
            self.assertIsNone(nb.landing_refusal())


class LandOnlyTheValidatedTree(NotifyOwners):
    """Second review of #21925: what lands must be a prefix of the validated stack."""

    def test_nothing_after_a_pr_that_did_not_land(self):
        controller = self.controller(notify=False)
        a, b, c = pr(1), pr(2), pr(3)
        reviewed = reviewed_heads(f"1 {a.sha}\n3 {c.sha}\n")  # b is not reviewed
        with mock.patch.object(nb, "open_prs", return_value=[a, b, c]), \
                mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_REVIEWED": str(reviewed)}):
            landed = dict((item.number, text) for item, text in controller.land(self.validation([a, b, c])))
        self.assertEqual(controller.merged, [1])
        self.assertIn("earlier PR in this stack", landed[3])

    def test_a_run_that_may_not_land_leaves_no_marker_that_holds_a_pr_out(self):
        controller = self.controller(notify=False)
        reviewed = reviewed_heads(f"1 {pr(1).sha}\n")
        with mock.patch.object(nb, "open_prs", return_value=[pr(1)]), \
                mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "CMUX_NEXT_BATCH_REVIEWED": str(reviewed)}):
            os.environ.pop("CMUX_NEXT_BATCH_EXCLUDE", None)
            controller.land(self.validation([pr(1)]))
        self.assertEqual(controller.merged, [])
        self.assertNotIn("receipt", [kind for _, kind, _ in controller.comments])

    def test_the_lanes_configured_login_never_counts(self):
        with mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_AUTHORS": "leo-bot", "CMUX_NEXT_BATCH_OVERRIDERS": "leo-bot lawrencecchen"}):
            self.assertEqual(nb.overriders(), frozenset({"lawrencecchen"}))


class CoordinatorAndOverrides(unittest.TestCase):
    def test_prs_coord2_lands_itself_stay_out(self):
        listed = Path(tempfile.mkdtemp()) / "merge-ready.sh"
        listed.write_text('READY=(\n  "manaflow-ai/cmux|21686|98f2d9818d5|build"\n  "manaflow-ai/cmux|21697|3b544e65d8d|"\n)\n'
                          "sleep 1800  # 21700 is not listed\n")
        with mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_EXCLUDE": str(listed)}):
            self.assertIn("coord-2 lands it", nb.ineligible_reason(pr(21686), NOW))
            self.assertIsNone(nb.ineligible_reason(pr(21700), NOW))
            self.assertIsNone(nb.ineligible_reason(pr(1800), NOW))

    def test_known_base_red_counts_only_when_an_allowed_login_applied_it(self):
        red = [("lint", "completed", "failure")]
        label = nb.OVERRIDE_BASE_RED
        trusted = pr(1, checks=red, labels=[label], label_actors={label: "lawrencecchen"})
        by_lane = pr(1, checks=red, labels=[label], label_actors={label: "teamleaderleo"})
        self.assertIsNone(nb.ineligible_reason(trusted, NOW))
        self.assertEqual(nb.ineligible_reason(by_lane, NOW), "red check lint")

    def test_known_base_red_never_waives_risk_evidence_or_a_freeze(self):
        label = nb.OVERRIDE_BASE_RED
        for check in ("risk evidence", "merge freeze"):
            with self.subTest(check=check):
                item = pr(1, checks=[(check, "completed", "failure")], labels=[label],
                          label_actors={label: "lawrencecchen"})
                self.assertIn(check, nb.ineligible_reason(item, NOW) or "")

    def test_land_alone_takes_a_batch_of_its_own(self):
        label = nb.OVERRIDE_ALONE
        prs = [pr(1), pr(2, labels=[label], label_actors={label: "lawrencecchen"}), pr(3)]
        self.assertEqual([item.number for item in nb.land_alone_first(prs)], [2])
        # One try per head: a land-alone that didn't land doesn't hold the queue every batch.
        self.assertEqual([item.number for item in nb.land_alone_first(prs, tried={2})], [1, 2, 3])
        untrusted = [pr(1), pr(2, labels=[label], label_actors={label: "teamleaderleo"})]
        self.assertEqual([item.number for item in nb.land_alone_first(untrusted)], [1, 2])


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


class Landing(unittest.TestCase):
    """The batch lands through GitHub's merge API pinned to the head it validated; no gh-merge-green."""

    def controller(self, api):
        controller = nb.Controller.__new__(nb.Controller)
        controller.args = Namespace(repo="o/r")
        controller.run_url = "u"
        controller.writer = mock.Mock()
        controller.gh = mock.Mock(env={})

        def routed(path, method="GET", **kw):
            if "check-runs" in path and not getattr(api, "reads_checks", False):
                return {"check_runs": []}
            return api(path, method=method, **kw) if "method" in api.__code__.co_varnames else api(path, **{"method": method, **kw})
        controller.writer.api = routed
        controller.gh.api = routed
        return controller

    def validation(self):
        return nb.Validation(name="batch", stack=nb.Stack(base="b", head="c" * 40))

    def test_merges_the_validated_head_with_a_squash(self):
        calls = []
        controller = self.controller(lambda path, **kw: calls.append((path, kw)) or {"sha": "m" * 40, "merged": True})
        with self.freeze(0):
            self.assertEqual(controller.merge_one(pr(7), self.validation()), "landed")
        path, kw = calls[0]
        self.assertEqual(path, "repos/o/r/pulls/7/merge")
        self.assertEqual(kw["method"], "PUT")
        self.assertEqual(kw["body"]["sha"], pr(7).sha)
        self.assertEqual(kw["body"]["merge_method"], "squash")

    def test_a_refusal_is_reported_not_retried(self):
        calls = []

        def refuse(path, **kw):
            calls.append(path)
            raise RuntimeError("gh api -X PUT failed: Head branch was modified. Review and try the merge again. (HTTP 409)")
        with self.freeze(0):
            outcome = self.controller(refuse).merge_one(pr(7), self.validation())
        self.assertTrue(outcome.startswith("not landed: GitHub refused to merge"), outcome)
        self.assertEqual(len(calls), 1)

    def freeze(self, code):
        return mock.patch.object(nb, "freeze_check", lambda repo, number, env: (code, "frozen: CmuxNext/Foo/ (#9)"))

    def test_keeps_githubs_default_squash_body_with_its_trailers(self):
        calls = []
        controller = self.controller(lambda path, **kw: calls.append(kw) or {"merged": True})
        with self.freeze(0):
            controller.merge_one(pr(7), self.validation())
        self.assertNotIn("commit_message", calls[0]["body"])

    def test_a_freeze_opened_since_the_last_push_stops_the_merge(self):
        calls = []
        controller = self.controller(lambda path, **kw: calls.append(path) or {})
        with self.freeze(1):
            outcome = controller.merge_one(pr(7), self.validation())
        self.assertTrue(outcome.startswith("not landed: frozen"), outcome)
        self.assertEqual(calls, [])
        with self.freeze(2):
            self.assertIn("unreadable", controller.merge_one(pr(7), self.validation()))
        self.assertEqual(calls, [])

    def test_a_transient_error_is_retried_and_never_marks_the_pr_refused(self):
        puts = iter([RuntimeError("gh api -X PUT failed: Base branch was modified. Review and try the merge again. (HTTP 405)"),
                     {"merged": True}])

        def api(path, method="GET", **kw):
            if method == "PUT":
                reply = next(puts)
                if isinstance(reply, Exception):
                    raise reply
                return reply
            return {"merged": False, "head": {"sha": pr(7).sha}}
        with self.freeze(0), mock.patch.object(nb.time, "sleep"):
            self.assertEqual(self.controller(api).merge_one(pr(7), self.validation()), "landed")

        def always_502(path, method="GET", **kw):
            if method == "PUT":
                raise RuntimeError("gh api -X PUT failed: gh: HTTP 502")
            return {"merged": False}
        with self.freeze(0), mock.patch.object(nb.time, "sleep"):
            outcome = self.controller(always_502).merge_one(pr(7), self.validation())
        self.assertTrue(outcome.startswith("not landed"))
        self.assertNotIn("GitHub refused to merge", outcome)
    def test_a_5xx_after_github_merged_counts_as_landed(self):
        def api(path, method="GET", **kw):
            if method == "PUT":
                raise RuntimeError("gh api -X PUT failed: gh: HTTP 504")
            return {"merged": True, "head": {"sha": pr(7).sha}}
        with self.freeze(0), mock.patch.object(nb.time, "sleep"):
            self.assertEqual(self.controller(api).merge_one(pr(7), self.validation()), "landed")

    def test_a_network_error_is_transient_not_a_refusal(self):
        def api(path, method="GET", **kw):
            if method == "PUT":
                raise RuntimeError("gh api -X PUT failed: Post https://api.github.com: read: connection reset by peer")
            return {"merged": False, "head": {"sha": pr(7).sha}}
        with self.freeze(0), mock.patch.object(nb.time, "sleep"):
            outcome = self.controller(api).merge_one(pr(7), self.validation())
        self.assertNotIn("GitHub refused to merge", outcome)

    def test_pending_risk_evidence_holds_the_merge(self):
        calls = []

        def api(path, method="GET", **kw):
            calls.append((method, path))
            if "check-runs" in path:
                return {"check_runs": [{"name": "risk evidence", "status": "in_progress", "conclusion": None}]}
            return {"merged": True}
        api.reads_checks = True
        with self.freeze(0):
            outcome = self.controller(api).merge_one(pr(7), self.validation())
        self.assertIn("risk evidence", outcome)
        self.assertNotIn("GitHub refused to merge", outcome)
        self.assertFalse(any(method == "PUT" for method, _ in calls))

    def test_freeze_check_maps_the_checkers_exit_and_uses_the_given_token(self):
        root = Path(tempfile.mkdtemp())
        (root / "scripts/ci").mkdir(parents=True)
        script = root / "scripts/ci/merge_freeze.py"
        for code, expected in ((0, 0), (1, 1), (3, 2)):
            script.write_text(f"import os, sys\nprint(os.environ.get('GH_TOKEN'))\nsys.exit({code})\n")
            with mock.patch.object(nb, "TOOLS_ROOT", root):
                got, detail = nb.freeze_check("o/r", 7, {**os.environ, "GH_TOKEN": "job-token"})
            self.assertEqual(got, expected)
            self.assertIn("job-token", detail)

    def test_frozen_prs_never_enter_a_stack(self):
        verdicts = {1: (0, ""), 2: (1, "frozen: x/"), 3: (2, "HTTP 502")}
        kept, skipped = nb.drop_frozen([pr(1), pr(2), pr(3)], lambda number: verdicts[number])
        self.assertEqual([item.number for item in kept], [1])
        self.assertIn("frozen", skipped[2])
        self.assertIn("unreadable", skipped[3])

    def test_gh_merge_green_is_gone_from_the_queue(self):
        source = (ROOT / "scripts/ci/next_batch.py").read_text()
        self.assertNotIn("gh-merge-green", source)

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

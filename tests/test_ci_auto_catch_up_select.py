#!/usr/bin/env python3
"""Automatic PR catch-up: which open pull requests a green main run catches up.

scripts/ci/auto_catch_up_select.py reads the open pull requests against main
through GraphQL and picks the ones pr-catch-up.yml merges main into on its own.
Each case feeds it GraphQL responses shaped like GitHub's (a fake that answers
by query, or the checked-in replay in tests/fixtures/auto_catch_up/) at a fixed
`now`, and checks the decision for every pull request: selected because it
conflicts or is red only because of main, or skipped with the reason printed.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/auto_catch_up_select.py"
REPLAY = ROOT / "tests/fixtures/auto_catch_up/replay.json"
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import auto_catch_up_select as selector  # noqa: E402

REPO = "manaflow-ai/cmux"
NOW = datetime(2026, 9, 25, 12, 0, tzinfo=timezone.utc)
GREEN = "9" * 40


def guard(head: str, *, red_on_main: bool = True) -> str:
    """A CI fast guards comment as guard_attribution.render_pr_comment writes it for `head`."""
    step = "### `tests/test_x.py` (red on main too, not this PR)\nMain has failed this step since #1." if red_on_main \
        else "### `tests/test_x.py`\nThe failure is this pull request's."
    return (f"<!-- cmux-fast-guards-pr -->\n**`ci-fast-guards.yml` failed** on `{head[:10]}`"
            f" (https://github.com/{REPO}/actions/runs/1). It does not block the merge.\n\n{step}\n")


def iso(moment: datetime) -> str:
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def sha(number: int, salt: str = "a") -> str:
    return (f"{number:08x}" + salt * 40)[:40]


def pr_node(number: int, *, pushed_minutes_ago: float = 120, mergeable: str = "MERGEABLE",
            draft: bool = False, head_repo: str = REPO, labels: tuple[str, ...] = (),
            comments: tuple[tuple[str, str, str], ...] = (), head: str | None = None,
            suite: bool = True, updated_minutes_ago: float | None = None,
            protection: bool = False, rules: int = 0, head_ref: bool = True) -> dict:
    """One pull request as the PULL_REQUESTS_QUERY returns it; comments are (id, login, body).

    Like GitHub, `comments` holds the first 100 and `lastComments` the last
    100; the ones in between are what the middle-comments query pages.
    """
    pushed = NOW - timedelta(minutes=pushed_minutes_ago)
    updated = NOW - timedelta(minutes=updated_minutes_ago if updated_minutes_ago is not None else pushed_minutes_ago)
    commit = {"oid": head or sha(number),
              "checkSuites": {"nodes": [{"createdAt": iso(pushed)}] if suite else []}}
    listed = [{"id": cid, "author": {"login": login}} for cid, login, _ in comments]
    node = {
        "number": number, "isDraft": draft, "isCrossRepository": head_repo != REPO,
        "updatedAt": iso(updated), "headRefName": f"feature-{number}", "headRefOid": head or sha(number),
        "mergeable": mergeable, "headRepository": {"nameWithOwner": head_repo},
        "headRef": {"branchProtectionRule": {"id": "BPR_1"} if protection else None,
                    "rules": {"totalCount": rules}} if head_ref else None,
        "labels": {"nodes": [{"name": name} for name in labels]},
        "commits": {"nodes": [{"commit": commit}]},
        "comments": {"totalCount": len(listed),
                     "pageInfo": {"hasNextPage": len(listed) > 100, "endCursor": "p100" if len(listed) > 100 else None},
                     "nodes": listed[:100]},
        "lastComments": {"nodes": listed[-100:] if len(listed) > 100 else listed},
    }
    node["_bodies"] = {cid: body for cid, _, body in comments}
    node["_all"] = listed
    return node


def page(nodes: list[dict], cursor: str | None = None) -> dict:
    clean = [{k: v for k, v in node.items() if not k.startswith("_")} for node in nodes]
    return {"data": {"repository": {"pullRequests": {
        "pageInfo": {"hasNextPage": cursor is not None, "endCursor": cursor}, "nodes": clean}}}}


class FakeGitHub:
    """Answers the queries the selector sends, and records them."""

    def __init__(self, pages: list[list[dict]], mergeable_rounds: list[dict[int, tuple[str, str]]] = (),
                 ahead: dict[int, int | None] | None = None) -> None:
        self.pages = [page(nodes, f"c{i}" if i + 1 < len(pages) else None) for i, nodes in enumerate(pages)]
        self.bodies = {cid: body for nodes in pages for node in nodes for cid, body in node["_bodies"].items()}
        self.all_comments = {node["number"]: node["_all"] for nodes in pages for node in nodes}
        self.heads = {node["number"]: node["headRefOid"] for nodes in pages for node in nodes}
        # Per re-read round: number -> (headRefOid, mergeable).
        self.mergeable_rounds = list(mergeable_rounds)
        # number -> aheadBy of the green commit over the head; missing means 1, None no answer.
        self.ahead = ahead or {}
        self.calls: list[tuple[str, dict]] = []
        self.body_ids: list[str] = []
        self.compared: list[int] = []
        self.middle_pages: list[int] = []

    def __call__(self, query: str, variables: dict) -> dict:
        self.calls.append((query, variables))
        if "pullRequests(" in query:
            index = 0 if variables.get("after") is None else int(variables["after"][1:]) + 1
            return self.pages[index]
        if "nodes(ids:" in query:
            self.body_ids += variables["ids"]
            return {"data": {"nodes": [{"id": i, "body": self.bodies[i]} for i in variables["ids"]]}}
        if "comments(first: 100, after: $after)" in query:
            number = variables["number"]
            self.middle_pages.append(number)
            start = int(variables["after"][1:])
            listed = self.all_comments[number][start:start + 100]
            end = start + len(listed)
            return {"data": {"repository": {"pullRequest": {"comments": {
                "pageInfo": {"hasNextPage": end < len(self.all_comments[number]), "endCursor": f"p{end}"},
                "nodes": listed}}}}}
        if "compare(headRef:" in query:
            assert variables["green"] == GREEN
            answers = {}
            for number in map(int, re.findall(r"pr(\d+): pullRequest", query)):
                self.compared.append(number)
                ahead = self.ahead.get(number, 1)
                answers[f"pr{number}"] = {"number": number, "headRefOid": self.heads[number],
                                          "headRef": {"compare": None if ahead is None else {"aheadBy": ahead}}}
            return {"data": {"repository": answers}}
        answers = self.mergeable_rounds.pop(0) if self.mergeable_rounds else {}
        return {"data": {"repository": {
            f"pr{n}": {"number": n, "headRefOid": head, "mergeable": state} for n, (head, state) in answers.items()}}}


def run(pages: list[list[dict]], cap: int = 15, **kwargs) -> tuple[dict[int, selector.Decision], list[int], FakeGitHub]:
    github = FakeGitHub(pages, kwargs.pop("mergeable_rounds", ()), kwargs.pop("ahead", None))
    sleeps: list[float] = []
    decisions, _ = selector.select(github, REPO, NOW, cap, GREEN, kwargs.pop("ledger", None),
                                   sleep=sleeps.append, **kwargs)
    github.sleeps = sleeps
    return {d.number: d for d in decisions}, [d.number for d in decisions if d.selected], github


class SelectionRuleTests(unittest.TestCase):
    def test_conflicting_pull_request_is_selected(self) -> None:
        by_number, chosen, _ = run([[pr_node(1, mergeable="CONFLICTING")]])
        self.assertEqual(chosen, [1])
        self.assertEqual(by_number[1].why, "conflict")
        self.assertEqual(by_number[1].head, sha(1))

    def test_red_only_because_of_main_is_selected(self) -> None:
        node = pr_node(2, comments=(("c2", "github-actions", guard(sha(2))),))
        by_number, chosen, _ = run([[node]])
        self.assertEqual(chosen, [2])
        self.assertEqual(by_number[2].why, "red-on-main")

    def test_red_on_the_pull_request_itself_is_not_selected(self) -> None:
        node = pr_node(3, comments=(("c3", "github-actions", guard(sha(3), red_on_main=False)),))
        by_number, chosen, _ = run([[node]])
        self.assertEqual(chosen, [])
        self.assertIn("nothing to catch up", by_number[3].reason)

    def test_marker_pasted_by_a_person_does_not_count(self) -> None:
        node = pr_node(4, comments=(("c4", "someone", guard(sha(4))),))
        _, chosen, github = run([[node]])
        self.assertEqual(chosen, [])
        self.assertEqual(github.body_ids, [], "only the Actions bot's comments are read")

    def test_matrix_pins_each_selected_head(self) -> None:
        by_number, _, _ = run([[pr_node(5, mergeable="CONFLICTING"), pr_node(6)]])
        matrix = selector.matrix(sorted(by_number.values(), key=lambda d: d.number))
        self.assertEqual(matrix, {"include": [{"pr": 5, "pin": sha(5), "why": "conflict"}]})


class SkipReasonTests(unittest.TestCase):
    def assert_skipped(self, node: dict, reason: str) -> None:
        by_number, chosen, _ = run([[node]])
        self.assertEqual(chosen, [])
        self.assertIn(reason, by_number[node["number"]].reason)

    def test_draft(self) -> None:
        self.assert_skipped(pr_node(10, mergeable="CONFLICTING", draft=True), "draft")

    def test_fork_head(self) -> None:
        self.assert_skipped(pr_node(11, mergeable="CONFLICTING", head_repo="someone/cmux"),
                            "head is in someone/cmux")

    def test_cross_repository_flag_alone_refuses(self) -> None:
        node = pr_node(12, mergeable="CONFLICTING")
        node["isCrossRepository"] = True
        self.assert_skipped(node, "not manaflow-ai/cmux")

    def test_opt_out_label(self) -> None:
        self.assert_skipped(pr_node(13, mergeable="CONFLICTING", labels=("no-auto-catch-up",)),
                            "labeled no-auto-catch-up")

    def test_recent_push(self) -> None:
        self.assert_skipped(pr_node(14, mergeable="CONFLICTING", pushed_minutes_ago=29), "under 30m")

    def test_quiet_exactly_thirty_minutes_is_selected(self) -> None:
        _, chosen, _ = run([[pr_node(15, mergeable="CONFLICTING", pushed_minutes_ago=30)]])
        self.assertEqual(chosen, [15])

    def test_head_not_pushed_within_the_age_limit(self) -> None:
        self.assert_skipped(pr_node(16, mergeable="CONFLICTING", pushed_minutes_ago=15 * 24 * 60,
                                    updated_minutes_ago=60), "over 14d")

    def test_already_attempted_conflict_on_this_head(self) -> None:
        marker = selector.ATTEMPT_MARKER.format(head=sha(17)) + "\nI tried to catch this branch up..."
        self.assert_skipped(pr_node(17, mergeable="CONFLICTING", comments=(("c17", "github-actions", marker),)),
                            f"already tried head {sha(17)[:12]}")

    def test_attempt_on_an_older_head_does_not_block_the_new_one(self) -> None:
        marker = selector.ATTEMPT_MARKER.format(head=sha(18, "b"))
        _, chosen, _ = run([[pr_node(18, mergeable="CONFLICTING", comments=(("c18", "github-actions", marker),))]])
        self.assertEqual(chosen, [18])

    def test_already_attempted_red_on_main_head(self) -> None:
        marker = selector.ATTEMPT_MARKER.format(head=sha(19))
        node = pr_node(19, comments=(("g19", "github-actions", guard(sha(19))), ("c19", "github-actions", marker)))
        self.assert_skipped(node, "already tried")

    def test_no_reason(self) -> None:
        self.assert_skipped(pr_node(20), "nothing to catch up: no conflict, guards not red on main")

    def test_skipped_pull_requests_cost_no_body_reads(self) -> None:
        nodes = [pr_node(21, draft=True, comments=(("c21", "github-actions", guard(sha(21))),)),
                 pr_node(22, pushed_minutes_ago=5, comments=(("c22", "github-actions", guard(sha(22))),))]
        _, chosen, github = run([nodes])
        self.assertEqual(chosen, [])
        self.assertEqual(github.body_ids, [])


class MergeabilityTests(unittest.TestCase):
    def test_unknown_is_read_again_until_github_answers(self) -> None:
        node = pr_node(30, mergeable="UNKNOWN")
        rounds = [{30: (sha(30), "UNKNOWN")}, {30: (sha(30), "CONFLICTING")}]
        by_number, chosen, github = run([[node]], mergeable_rounds=rounds)
        self.assertEqual(chosen, [30])
        self.assertEqual(github.sleeps, [selector.MERGEABLE_RETRY_SECONDS], "one wait between the two re-reads")

    def test_still_unknown_after_the_retries_is_skipped(self) -> None:
        rounds = [{31: (sha(31), "UNKNOWN")}] * selector.MERGEABLE_RETRIES
        by_number, chosen, github = run([[pr_node(31, mergeable="UNKNOWN")]], mergeable_rounds=rounds)
        self.assertEqual(chosen, [])
        self.assertIn("not computed mergeability", by_number[31].reason)
        self.assertEqual(len(github.sleeps), selector.MERGEABLE_RETRIES - 1)

    def test_head_that_moved_keeps_unknown(self) -> None:
        rounds = [{32: (sha(32, "f"), "CONFLICTING")}] * selector.MERGEABLE_RETRIES
        _, chosen, _ = run([[pr_node(32, mergeable="UNKNOWN")]], mergeable_rounds=rounds)
        self.assertEqual(chosen, [])

    def test_red_on_main_needs_no_mergeability(self) -> None:
        node = pr_node(33, mergeable="UNKNOWN", comments=(("c33", "github-actions", guard(sha(33))),))
        _, chosen, github = run([[node]])
        self.assertEqual(chosen, [33])
        self.assertFalse(any("mergeable }" in query for query, _ in github.calls))

    def test_decided_pull_requests_are_not_read_again(self) -> None:
        _, _, github = run([[pr_node(34, mergeable="CONFLICTING"), pr_node(35), pr_node(36, draft=True,
                                                                                         mergeable="UNKNOWN")]])
        self.assertFalse(any("pullRequest(number:" in query for query, _ in github.calls))
        self.assertEqual(github.compared, [])


class CapAndOrderTests(unittest.TestCase):
    def test_cap_keeps_the_most_recently_pushed(self) -> None:
        nodes = [pr_node(100 + i, mergeable="CONFLICTING", pushed_minutes_ago=40 + i) for i in range(20)]
        by_number, chosen, _ = run([nodes])
        self.assertEqual(chosen, [100 + i for i in range(15)])
        for number in range(115, 120):
            self.assertIn("over this run's cap of 15", by_number[number].reason)

    def test_order_is_newest_push_first_whatever_the_page_order(self) -> None:
        nodes = [pr_node(1, mergeable="CONFLICTING", pushed_minutes_ago=300),
                 pr_node(2, mergeable="CONFLICTING", pushed_minutes_ago=45),
                 pr_node(3, comments=(("c3", "github-actions", guard(sha(3))),), pushed_minutes_ago=90)]
        _, chosen, _ = run([nodes])
        self.assertEqual(chosen, [2, 3, 1])

    def test_ties_break_by_number(self) -> None:
        nodes = [pr_node(n, mergeable="CONFLICTING", pushed_minutes_ago=60) for n in (7, 9, 8)]
        _, chosen, _ = run([nodes])
        self.assertEqual(chosen, [9, 8, 7])

    def test_zero_cap_selects_nothing(self) -> None:
        _, chosen, _ = run([[pr_node(1, mergeable="CONFLICTING")]], cap=0)
        self.assertEqual(chosen, [])

    def test_cap_from_the_repository_variable(self) -> None:
        self.assertEqual(selector.parse_cap(None), (15, None))
        self.assertEqual(selector.parse_cap(""), (15, None))
        self.assertEqual(selector.parse_cap(" 4 "), (4, None))
        self.assertEqual(selector.parse_cap("many")[0], 15)
        self.assertEqual(selector.parse_cap("-1")[0], 15)
        self.assertEqual(selector.parse_cap("500"), (selector.MAX_CEILING, selector.parse_cap("500")[1]))
        self.assertIn("over", selector.parse_cap("500")[1])


class PagingTests(unittest.TestCase):
    def test_follows_pages_and_stops_at_the_age_limit(self) -> None:
        old = 15 * 24 * 60
        pages = [[pr_node(1, mergeable="CONFLICTING")],
                 [pr_node(2, mergeable="CONFLICTING"), pr_node(3, mergeable="CONFLICTING",
                                                                pushed_minutes_ago=old, updated_minutes_ago=old)],
                 [pr_node(4, mergeable="CONFLICTING")]]
        by_number, chosen, github = run(pages)
        self.assertEqual(sorted(by_number), [1, 2], "nothing after the first pull request older than the limit")
        self.assertEqual(sum("pullRequests(" in query for query, _ in github.calls), 2)
        self.assertEqual(github.calls[1][1]["after"], "c0")

    def test_push_time_is_the_check_suite(self) -> None:
        node = pr_node(1, pushed_minutes_ago=10)
        node["commits"]["nodes"][0]["commit"]["committedDate"] = iso(NOW - timedelta(days=3))
        self.assertEqual(selector.last_push(node), NOW - timedelta(minutes=10))

    def test_head_without_a_check_suite_is_skipped(self) -> None:
        # A rebased head keeps an old committer date; it would read as quiet.
        node = pr_node(2, mergeable="CONFLICTING", suite=False)
        node["commits"]["nodes"][0]["commit"]["committedDate"] = iso(NOW - timedelta(days=3))
        self.assertIsNone(selector.last_push(node))
        by_number, chosen, _ = run([[node]])
        self.assertEqual(chosen, [])
        self.assertIn("no check suite on the head yet", by_number[2].reason)


class RedOnMainTests(unittest.TestCase):
    """(red on main) is about this head, and only while the head lacks the green commit."""

    def test_guard_comment_about_an_older_head_is_ignored(self) -> None:
        node = pr_node(40, comments=(("g40", "github-actions", guard(sha(40, "b"))),))
        by_number, chosen, github = run([[node]])
        self.assertEqual(chosen, [])
        self.assertIn("nothing to catch up", by_number[40].reason)
        self.assertEqual(github.compared, [], "no comparison for a pull request that is not red on main")

    def test_head_that_already_has_the_green_commit_is_skipped(self) -> None:
        # The guard comment is stale: the head has main at the green commit,
        # so a catch-up would find it up to date, silently, on every green main.
        node = pr_node(41, comments=(("g41", "github-actions", guard(sha(41))),))
        by_number, chosen, github = run([[node]], ahead={41: 0})
        self.assertEqual(chosen, [])
        self.assertIn(f"already has main at {GREEN[:12]}", by_number[41].reason)
        self.assertEqual(github.compared, [41])

    def test_head_behind_the_green_commit_is_selected(self) -> None:
        node = pr_node(42, comments=(("g42", "github-actions", guard(sha(42))),))
        by_number, chosen, _ = run([[node]], ahead={42: 5})
        self.assertEqual(chosen, [42])
        self.assertEqual(by_number[42].why, "red-on-main")

    def test_no_comparison_answer_is_skipped(self) -> None:
        node = pr_node(43, comments=(("g43", "github-actions", guard(sha(43))),))
        by_number, chosen, _ = run([[node]], ahead={43: None})
        self.assertEqual(chosen, [])
        self.assertIn("could not compare", by_number[43].reason)

    def test_conflicts_need_no_comparison(self) -> None:
        node = pr_node(44, mergeable="CONFLICTING", comments=(("g44", "github-actions", guard(sha(44))),))
        _, chosen, github = run([[node]], ahead={44: 0})
        self.assertEqual(chosen, [44])
        self.assertEqual(github.compared, [])

    def test_strict_guard_comment_shape(self) -> None:
        head = sha(45)
        good = guard(head)
        self.assertTrue(selector.guard_red_on_main(good, head))
        self.assertFalse(selector.guard_red_on_main("quoting:\n" + good, head), "marker must be the first line")
        self.assertFalse(selector.guard_red_on_main(good.replace("### `tests", "`tests"), head),
                         "the note must be in a step heading")
        self.assertFalse(selector.guard_red_on_main(
            good.replace("### `tests/test_x.py` (red on main too, not this PR)", "### `tests/test_x.py`")
            + "\nsomeone wrote (red on main too, not this PR)", head))
        self.assertFalse(selector.guard_red_on_main(good.replace(f"on `{head[:10]}`", "on `abc`"), head))
        self.assertFalse(selector.guard_red_on_main(good, sha(46)))


class ProtectionTests(unittest.TestCase):
    """merge refuses these without a comment, so selecting them would take a slot every run."""

    def test_branch_protection_rule(self) -> None:
        by_number, chosen, _ = run([[pr_node(50, mergeable="CONFLICTING", protection=True)]])
        self.assertEqual(chosen, [])
        self.assertIn("protected by a rule or ruleset", by_number[50].reason)

    def test_ruleset(self) -> None:
        by_number, chosen, _ = run([[pr_node(51, mergeable="CONFLICTING", rules=2)]])
        self.assertEqual(chosen, [])
        self.assertIn("protected by a rule or ruleset", by_number[51].reason)

    def test_deleted_head_branch(self) -> None:
        by_number, chosen, _ = run([[pr_node(52, mergeable="CONFLICTING", head_ref=False)]])
        self.assertEqual(chosen, [])
        self.assertIn("head branch is gone", by_number[52].reason)


def chatter(number: int, count: int, start: int = 0) -> tuple[tuple[str, str, str], ...]:
    return tuple((f"x{number}-{i}", "someone", "comment") for i in range(start, start + count))


class ManyCommentsTests(unittest.TestCase):
    """The guard comment is created once and edited in place, so it can be an early one."""

    def test_guard_comment_among_the_first_of_more_than_a_hundred(self) -> None:
        comments = (("g60", "github-actions", guard(sha(60))),) + chatter(60, 150)
        node = pr_node(60, comments=comments)
        _, chosen, github = run([[node]])
        self.assertEqual(chosen, [60])
        self.assertIn("g60", github.body_ids)
        self.assertEqual(github.middle_pages, [], "first and last 100 cover 151 comments")

    def test_guard_comment_in_the_middle_of_more_than_two_hundred(self) -> None:
        comments = chatter(61, 150) + (("g61", "github-actions", guard(sha(61))),) + chatter(61, 200, 150)
        node = pr_node(61, comments=comments)
        _, chosen, github = run([[node]])
        self.assertEqual(chosen, [61])
        self.assertEqual(github.middle_pages, [61], "one middle page reaches the guard comment")

    def test_attempt_marker_in_the_last_hundred_still_counts(self) -> None:
        marker = selector.ATTEMPT_MARKER.format(head=sha(62))
        comments = chatter(62, 250) + (("m62", "github-actions", marker),)
        by_number, chosen, _ = run([[pr_node(62, mergeable="CONFLICTING", comments=comments)]])
        self.assertEqual(chosen, [])
        self.assertIn("already tried", by_number[62].reason)

    def test_middle_paging_stops_at_the_last_hundred(self) -> None:
        node = pr_node(63, comments=chatter(63, 450))
        by_number, chosen, github = run([[node]])
        self.assertEqual(chosen, [])
        self.assertEqual(github.middle_pages, [63, 63, 63], "pages 100-400, then the last 100 are known")


class LedgerTests(unittest.TestCase):
    """Silent outcomes leave no marker; the ledger bounds how often one head is picked."""

    def test_head_selected_twice_is_left_alone(self) -> None:
        node = pr_node(70, mergeable="CONFLICTING")
        by_number, chosen, _ = run([[node]], ledger={70: (sha(70), selector.MAX_ATTEMPTS_PER_HEAD)})
        self.assertEqual(chosen, [])
        self.assertIn(f"already selected head {sha(70)[:12]} 2 times", by_number[70].reason)

    def test_one_earlier_selection_or_another_head_still_selects(self) -> None:
        nodes = [pr_node(71, mergeable="CONFLICTING"), pr_node(72, mergeable="CONFLICTING")]
        _, chosen, _ = run([nodes], ledger={71: (sha(71), 1), 72: (sha(72, "b"), 5)})
        self.assertEqual(sorted(chosen), [71, 72])

    def test_next_ledger_counts_picks_and_drops_stale_heads(self) -> None:
        prs = [pr_node(73), pr_node(74), pr_node(75)]
        decisions = [selector.Decision(73, sha(73), True, ""), selector.Decision(74, sha(74), True, ""),
                     selector.Decision(75, sha(75), False, "")]
        old = {73: (sha(73), 1), 74: (sha(74, "b"), 2), 75: (sha(75), 1), 99: (sha(99), 1)}
        self.assertEqual(selector.next_ledger(prs, decisions, old),
                         {73: (sha(73), 2), 74: (sha(74), 1), 75: (sha(75), 1)})

    def test_malformed_ledger_starts_empty(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ledger.json"
            self.assertEqual(selector.load_ledger(path), ({}, None))
            for text in ("not json", "[]", json.dumps({"version": 9, "attempts": {}}),
                         json.dumps({"version": 1, "attempts": []})):
                path.write_text(text, encoding="utf-8")
                ledger, warning = selector.load_ledger(path)
                self.assertEqual(ledger, {}, text)
                self.assertTrue(warning, text)
            path.write_text(json.dumps({"version": 1, "attempts": {
                "1": {"head": sha(1), "count": 1}, "x": {"head": sha(2), "count": 1},
                "3": {"head": "main", "count": 1}, "4": {"head": sha(4), "count": "2"}}}), encoding="utf-8")
            self.assertEqual(selector.load_ledger(path), ({1: (sha(1), 1)}, None))


class CommandLineTests(unittest.TestCase):
    def cli(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--repo", REPO, "--green-sha", GREEN, *args],
                              capture_output=True, text=True)

    def test_replay_prints_every_decision_and_writes_the_matrix(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "github_output"
            completed = self.cli("--responses", str(REPLAY), "--now", iso(NOW), "--max", "2",
                                 "--github-output", str(output))
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            written = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
        matrix = json.loads(written["matrix"])
        self.assertEqual([(e["pr"], e["why"]) for e in matrix["include"]], [(14702, "conflict"), (14650, "red-on-main")])
        self.assertEqual(written["count"], "2")
        lines = completed.stdout.splitlines()
        self.assertEqual(lines[0], "auto catch-up: 2 of 10 open pull request(s) against main selected")
        text = completed.stdout
        for expected in ("skip   #14710", "draft", "head is in someone/cmux", "labeled no-auto-catch-up",
                         "under 30m", "already tried head", "over this run's cap of 2", "nothing to catch up",
                         "#14640 00003930aaaa pushed 3h ago: head branch is protected"):
            self.assertIn(expected, text)

    def test_ledger_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ledger_in = Path(tmp) / "previous.json"
            ledger_out = Path(tmp) / "ledger.json"
            # 14702 was selected twice already; 14713 once, on a head it no longer has.
            ledger_in.write_text(selector.dump_ledger({14702: ("0000396eaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 2),
                                                       14713: ("f" * 40, 1)}), encoding="utf-8")
            completed = self.cli("--responses", str(REPLAY), "--now", iso(NOW), "--max", "2",
                                 "--ledger-in", str(ledger_in), "--ledger-out", str(ledger_out))
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertIn("#14702 0000396eaaaa", completed.stdout)
            self.assertIn("already selected head 0000396eaaaa 2 times", completed.stdout)
            written = json.loads(ledger_out.read_text(encoding="utf-8"))
        self.assertEqual(written["version"], selector.LEDGER_VERSION)
        attempts = {int(k): (v["head"][:8], v["count"]) for k, v in written["attempts"].items()}
        # 14713's entry was for another head; this run's picks are counted.
        chosen = json.loads(completed.stdout.splitlines()[-1])["include"]
        self.assertEqual(attempts, {14702: ("0000396e", 2), **{e["pr"]: (e["pin"][:8], 1) for e in chosen}})

    def test_green_sha_must_be_a_commit_id(self) -> None:
        completed = subprocess.run([sys.executable, "-I", str(SCRIPT), "--repo", REPO, "--green-sha", "main",
                                    "--responses", str(REPLAY), "--now", iso(NOW)], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 2)
        self.assertIn("green commit is not a full commit id", completed.stdout)

    def test_graphql_error_fails_without_a_matrix(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            replay = Path(tmp) / "replay.json"
            replay.write_text(json.dumps([{"data": {"repository": None}}]), encoding="utf-8")
            output = Path(tmp) / "github_output"
            completed = self.cli("--responses", str(replay), "--now", iso(NOW), "--github-output", str(output))
            self.assertEqual(completed.returncode, 2)
            self.assertIn("::error::", completed.stdout)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()

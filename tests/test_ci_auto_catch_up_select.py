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
GUARD_RED_ON_MAIN = (
    "<!-- cmux-fast-guards-pr -->\n**`ci-fast-guards.yml` failed** on `abc`.\n\n"
    "### `tests/test_x.py` (red on main too, not this PR)\nMain has failed this step since #1."
)
GUARD_RED_HERE = "<!-- cmux-fast-guards-pr -->\n**`ci-fast-guards.yml` failed** on `abc`.\n\n### `tests/test_x.py`"


def iso(moment: datetime) -> str:
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def sha(number: int, salt: str = "a") -> str:
    return (f"{number:08x}" + salt * 40)[:40]


def pr_node(number: int, *, pushed_minutes_ago: float = 120, mergeable: str = "MERGEABLE",
            draft: bool = False, head_repo: str = REPO, labels: tuple[str, ...] = (),
            comments: tuple[tuple[str, str, str], ...] = (), head: str | None = None,
            suite: bool = True, updated_minutes_ago: float | None = None) -> dict:
    """One pull request as the PULL_REQUESTS_QUERY returns it; comments are (id, login, body)."""
    pushed = NOW - timedelta(minutes=pushed_minutes_ago)
    updated = NOW - timedelta(minutes=updated_minutes_ago if updated_minutes_ago is not None else pushed_minutes_ago)
    commit = {"oid": head or sha(number), "committedDate": iso(pushed - timedelta(seconds=30)),
              "checkSuites": {"nodes": [{"createdAt": iso(pushed)}] if suite else []}}
    node = {
        "number": number, "isDraft": draft, "isCrossRepository": head_repo != REPO,
        "updatedAt": iso(updated), "headRefOid": head or sha(number), "mergeable": mergeable,
        "headRepository": {"nameWithOwner": head_repo},
        "labels": {"nodes": [{"name": name} for name in labels]},
        "commits": {"nodes": [{"commit": commit}]},
        "comments": {"nodes": [{"id": cid, "author": {"login": login}} for cid, login, _ in comments]},
    }
    node["_bodies"] = {cid: body for cid, _, body in comments}
    return node


def page(nodes: list[dict], cursor: str | None = None) -> dict:
    clean = [{k: v for k, v in node.items() if k != "_bodies"} for node in nodes]
    return {"data": {"repository": {"pullRequests": {
        "pageInfo": {"hasNextPage": cursor is not None, "endCursor": cursor}, "nodes": clean}}}}


class FakeGitHub:
    """Answers the three queries the selector sends, and records them."""

    def __init__(self, pages: list[list[dict]], mergeable_rounds: list[dict[int, tuple[str, str]]] = ()) -> None:
        self.pages = [page(nodes, f"c{i}" if i + 1 < len(pages) else None) for i, nodes in enumerate(pages)]
        self.bodies = {cid: body for nodes in pages for node in nodes for cid, body in node["_bodies"].items()}
        # Per re-read round: number -> (headRefOid, mergeable).
        self.mergeable_rounds = list(mergeable_rounds)
        self.calls: list[tuple[str, dict]] = []
        self.body_ids: list[str] = []

    def __call__(self, query: str, variables: dict) -> dict:
        self.calls.append((query, variables))
        if "pullRequests(" in query:
            index = 0 if variables.get("after") is None else int(variables["after"][1:]) + 1
            return self.pages[index]
        if "nodes(ids:" in query:
            self.body_ids += variables["ids"]
            return {"data": {"nodes": [{"id": i, "body": self.bodies[i]} for i in variables["ids"]]}}
        answers = self.mergeable_rounds.pop(0) if self.mergeable_rounds else {}
        return {"data": {"repository": {
            f"pr{n}": {"number": n, "headRefOid": head, "mergeable": state} for n, (head, state) in answers.items()}}}


def run(pages: list[list[dict]], cap: int = 15, **kwargs) -> tuple[dict[int, selector.Decision], list[int], FakeGitHub]:
    github = FakeGitHub(pages, kwargs.pop("mergeable_rounds", ()))
    sleeps: list[float] = []
    decisions, _ = selector.select(github, REPO, NOW, cap, sleep=sleeps.append, **kwargs)
    github.sleeps = sleeps
    return {d.number: d for d in decisions}, [d.number for d in decisions if d.selected], github


class SelectionRuleTests(unittest.TestCase):
    def test_conflicting_pull_request_is_selected(self) -> None:
        by_number, chosen, _ = run([[pr_node(1, mergeable="CONFLICTING")]])
        self.assertEqual(chosen, [1])
        self.assertEqual(by_number[1].why, "conflict")
        self.assertEqual(by_number[1].head, sha(1))

    def test_red_only_because_of_main_is_selected(self) -> None:
        node = pr_node(2, comments=(("c2", "github-actions", GUARD_RED_ON_MAIN),))
        by_number, chosen, _ = run([[node]])
        self.assertEqual(chosen, [2])
        self.assertEqual(by_number[2].why, "red-on-main")

    def test_red_on_the_pull_request_itself_is_not_selected(self) -> None:
        node = pr_node(3, comments=(("c3", "github-actions", GUARD_RED_HERE),))
        by_number, chosen, _ = run([[node]])
        self.assertEqual(chosen, [])
        self.assertIn("nothing to catch up", by_number[3].reason)

    def test_marker_pasted_by_a_person_does_not_count(self) -> None:
        node = pr_node(4, comments=(("c4", "someone", GUARD_RED_ON_MAIN),))
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
        node = pr_node(19, comments=(("g19", "github-actions", GUARD_RED_ON_MAIN), ("c19", "github-actions", marker)))
        self.assert_skipped(node, "already tried")

    def test_no_reason(self) -> None:
        self.assert_skipped(pr_node(20), "nothing to catch up: no conflict, guards not red on main")

    def test_skipped_pull_requests_cost_no_body_reads(self) -> None:
        nodes = [pr_node(21, draft=True, comments=(("c21", "github-actions", GUARD_RED_ON_MAIN),)),
                 pr_node(22, pushed_minutes_ago=5, comments=(("c22", "github-actions", GUARD_RED_ON_MAIN),))]
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
        node = pr_node(33, mergeable="UNKNOWN", comments=(("c33", "github-actions", GUARD_RED_ON_MAIN),))
        _, chosen, github = run([[node]])
        self.assertEqual(chosen, [33])
        self.assertFalse(any("pullRequest(number:" in query for query, _ in github.calls))

    def test_decided_pull_requests_are_not_read_again(self) -> None:
        _, _, github = run([[pr_node(34, mergeable="CONFLICTING"), pr_node(35), pr_node(36, draft=True,
                                                                                         mergeable="UNKNOWN")]])
        self.assertFalse(any("pullRequest(number:" in query for query, _ in github.calls))


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
                 pr_node(3, comments=(("c3", "github-actions", GUARD_RED_ON_MAIN),), pushed_minutes_ago=90)]
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

    def test_push_time_prefers_the_check_suite(self) -> None:
        node = pr_node(1, pushed_minutes_ago=10)
        node["commits"]["nodes"][0]["commit"]["committedDate"] = iso(NOW - timedelta(days=3))
        self.assertEqual(selector.last_push(node), NOW - timedelta(minutes=10))
        bare = pr_node(2, pushed_minutes_ago=10, suite=False)
        self.assertEqual(selector.last_push(bare), NOW - timedelta(minutes=10, seconds=30))


class CommandLineTests(unittest.TestCase):
    def cli(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--repo", REPO, *args],
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
        self.assertEqual(lines[0], "auto catch-up: 2 of 9 open pull request(s) against main selected")
        text = completed.stdout
        for expected in ("skip   #14710", "draft", "head is in someone/cmux", "labeled no-auto-catch-up",
                         "under 30m", "already tried head", "over this run's cap of 2", "nothing to catch up"):
            self.assertIn(expected, text)

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

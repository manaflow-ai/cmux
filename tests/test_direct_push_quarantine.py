#!/usr/bin/env python3
"""Direct pushes to feat-cmux-next get the fast gates, and a red one quarantines the branch.

Leo, 2026-11-12, asked whether to require pull requests on feat-cmux-next: "ugh we can just warn/pre-whatever/
quarantine stuff idk". In the week to 11-12, 16 base-red fixes repaired a direct push that met no gate. Shapes are those
pushes: e0d3bb0ec2f0 and 1d3552f766b6 by lawrencecchen, a squash merge of #42028, and the base autofix's commit.

Two halves: scripts/ci/direct_push_quarantine.py's decisions (which commits are direct, which base the gates judge
against, which commits are quarantined), and the workflow's shape.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("direct_push_quarantine", ROOT / "scripts/ci/direct_push_quarantine.py")
dpq = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dpq)
WORKFLOW = ROOT / ".github/workflows/cmux-next-direct-push-gates.yml"

BEFORE = "4bddccd2944d" + "b" * 28
DIRECT = "e0d3bb0ec2f0" + "a" * 28
DIRECT2 = "1d3552f766b6" + "c" * 28
MERGED = "741563166ecf" + "d" * 28
BOT = "cc00000000c3" + "e" * 28
OPEN_BASE = "307a6b626217" + "f" * 28


def commit(sha, login="lawrencecchen", name="Lawrence Chen"):
    return {"sha": sha, "author": {"login": login} if login else None, "commit": {"author": {"name": name}}}


PULLS = {MERGED: [{"number": 42028, "merged_at": "2026-11-12T17:31:26Z", "merge_commit_sha": MERGED}],
         # A direct commit that a still-open PR also carries is not that PR's merge.
         DIRECT: [{"number": 41999, "merged_at": None, "merge_commit_sha": "0" * 40}]}


def pulls_of(sha):
    return PULLS.get(sha, [])


def node(oid, state=None, desc=""):
    return {"oid": oid, "author": {"user": {"login": "lawrencecchen"}},
            "status": {"context": {"state": state, "description": desc} if state else None}}


def red(oid, base=OPEN_BASE, since="e0d3bb0ec2f0"):
    return node(oid, "FAILURE", f"red: base {base} since {since} by lawrencecchen")


class Direct(unittest.TestCase):
    def test_a_person_s_commit_from_no_merged_pr_is_direct(self):
        commits = [commit(DIRECT), commit(MERGED, "teamleaderleo"),
                   commit(BOT, "github-actions[bot]", "github-actions[bot]")]
        self.assertEqual(dpq.direct_commits(commits, pulls_of), [DIRECT])

    def test_a_bot_named_only_in_the_git_author_is_a_bot(self):
        self.assertEqual(dpq.direct_commits([commit(BOT, None, "github-actions[bot]")], pulls_of), [])

    def test_past_the_read_cap_a_person_s_commit_counts_as_direct_unread(self):
        reads = []
        commits = [commit(f"{n:040x}") for n in range(dpq.PULL_READS + 2)]
        out = dpq.direct_commits(commits, lambda sha: reads.append(sha) or [])
        self.assertEqual(len(reads), dpq.PULL_READS)
        self.assertEqual(len(out), dpq.PULL_READS + 2)


class Decide(unittest.TestCase):
    def decide(self, commits, nodes=(), forced=False, status="ahead", before=BEFORE, after=DIRECT2):
        compare = lambda b, a: {"status": status, "commits": commits,  # noqa: E731
                                "merge_base_commit": {"sha": "9" * 40}}
        return dpq.decide(before, after, forced, compare, pulls_of, lambda oid: list(nodes))

    def test_a_direct_push_is_gated_against_its_before(self):
        out = self.decide([commit(DIRECT), commit(DIRECT2)])
        self.assertEqual((out["run"], out["base"], out["since"], out["reason"]),
                         ("true", BEFORE, "e0d3bb0ec2f0", "direct"))
        self.assertEqual(out["direct"], f"{DIRECT} {DIRECT2}")

    def test_a_pr_merge_or_a_bot_push_is_not_gated(self):
        self.assertEqual(self.decide([commit(MERGED, "teamleaderleo")])["run"], "false")
        self.assertEqual(self.decide([commit(BOT, "github-actions[bot]", "github-actions[bot]")])["run"], "false")

    def test_while_quarantined_every_push_is_gated_against_the_quarantine_base(self):
        out = self.decide([commit(MERGED, "teamleaderleo")], nodes=[node(BEFORE), red(DIRECT)])
        self.assertEqual((out["run"], out["base"], out["since"], out["reason"], out["direct"]),
                         ("true", OPEN_BASE, "e0d3bb0ec2f0", "quarantine", ""))

    def test_a_cleared_quarantine_gates_nothing_more(self):
        nodes = [node(BEFORE, "SUCCESS", f"cleared: base {OPEN_BASE} since e0d3bb0ec2f0"), red(DIRECT)]
        self.assertEqual(self.decide([commit(MERGED, "teamleaderleo")], nodes=nodes)["run"], "false")

    def test_a_forced_push_is_gated_from_the_merge_base(self):
        self.assertEqual(self.decide([commit(DIRECT)], forced=True, status="diverged")["base"], "9" * 40)

    def test_a_new_branch_is_not_gated(self):
        self.assertEqual(self.decide([commit(DIRECT)], before="0" * 40)["run"], "false")

    def test_an_unreadable_quarantine_still_gates_a_direct_push(self):
        def broken(oid):
            raise ValueError("graphql errors")
        compare = lambda b, a: {"status": "ahead", "commits": [commit(DIRECT)]}  # noqa: E731
        out = dpq.decide(BEFORE, DIRECT, False, compare, pulls_of, broken)
        self.assertEqual((out["run"], out["base"]), ("true", BEFORE))


class Walk(unittest.TestCase):
    def test_commits_from_the_red_push_until_a_green_one_are_held(self):
        nodes = [node("5" * 40), node("4" * 40, "SUCCESS", "cleared"), node("3" * 40, "PENDING"), red("2" * 40),
                 node("1" * 40, "SUCCESS", "green")]
        found, held = dpq.quarantine_walk(nodes)
        self.assertIsNone(found)
        self.assertEqual([sha for sha, _ in held], ["2" * 40, "3" * 40])
        self.assertEqual(held[0][1], {"culprit": "e0d3bb0ec2f0", "base": OPEN_BASE, "pusher": "lawrencecchen"})

    def test_an_error_status_quarantines_nothing(self):
        found, held = dpq.quarantine_walk([node("2" * 40, "ERROR", "no verdict (cancelled)")])
        self.assertEqual((found, held), (None, []))


class WorkflowShape(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text()

    def test_it_runs_on_feat_cmux_next_pushes_and_never_cancels_a_verdict(self):
        self.assertIn("branches: [feat-cmux-next]", self.text)
        self.assertIn("group: direct-push-gates-${{ github.sha }}", self.text)
        self.assertIn("cancel-in-progress: false", self.text)

    def test_it_runs_the_pull_request_gates_and_posts_the_context_the_readers_parse(self):
        self.assertIn("scripts/ci/cmux_next_fast_gates.py run --base", self.text)
        self.assertIn(f'context="{dpq.CONTEXT}"', self.text)
        for desc in ('desc="red: base $BASE since ${SINCE:0:12} by $PUSHER"', 'desc="cleared: base $BASE since',
                     'desc="green: base $BASE"'):
            self.assertIn(desc, self.text)

    def test_it_warns_and_never_reverts(self):
        self.assertIn("commits/$SHA/comments", self.text)
        self.assertNotIn("git revert", self.text)
        self.assertNotIn("git push", self.text)


if __name__ == "__main__":
    unittest.main()

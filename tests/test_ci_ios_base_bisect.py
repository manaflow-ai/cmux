#!/usr/bin/env python3
"""scripts/ci/ios_base_bisect.py: the commit range, the bisect over a fake runner, and the comment."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import ios_base_bisect as bb  # noqa: E402


def sha(n: int) -> str:
    return f"{n:040x}"


def log_for(n: int) -> str:
    """git log --first-parent output, newest first, for commits 1..n with PR numbers 100+i."""
    return "\n".join(f"{sha(i)}\tfeat: change {i} (#{100 + i})" for i in range(n, 0, -1)) + "\n"


class FakeRunner:
    """Green before `first_red` (1-based), red from it on; `none` gives no verdict at those commits."""

    def __init__(self, first_red: int | None, none: set[int] = frozenset()):
        self.first_red, self.none, self.calls = first_red, none, []

    def __call__(self, commit: str):
        index = int(commit, 16)
        self.calls.append(index)
        if index in self.none:
            return None
        return self.first_red is None or index < self.first_red


class CandidatesTest(unittest.TestCase):
    def test_oldest_first_with_pr_numbers(self):
        commits = bb.candidates(log_for(3))
        self.assertEqual([c.sha for c in commits], [sha(1), sha(2), sha(3)])
        self.assertEqual([c.pr for c in commits], [101, 102, 103])

    def test_merge_commit_and_direct_push(self):
        commits = bb.candidates(f"{sha(2)}\tMerge pull request #42914 from x/y\n{sha(1)}\tchore: base autofix\n")
        self.assertEqual([c.pr for c in commits], [None, 42914])

    def test_empty(self):
        self.assertEqual(bb.candidates(""), [])


class BisectTest(unittest.TestCase):
    def test_every_position_is_found(self):
        for n in (1, 2, 3, 7, 16):
            for first_red in range(1, n + 1):
                runner = FakeRunner(first_red)
                result = bb.bisect(bb.candidates(log_for(n)), runner, good=sha(0))
                self.assertEqual(result.status, "culprit", (n, first_red))
                self.assertEqual(result.culprit.sha, sha(first_red), (n, first_red))
                self.assertEqual(result.culprit.pr, 100 + first_red)
                # The red head first, then log2(n) probes at most.
                self.assertEqual(runner.calls[0], n)
                self.assertLessEqual(len(runner.calls), 1 + max(1, (n - 1).bit_length()))

    def test_two_prs_green_alone_names_the_second(self):
        # #1 and #2 each green alone; together red: the base turns red at #2.
        result = bb.bisect(bb.candidates(log_for(4)), FakeRunner(2), good=sha(0))
        self.assertEqual(result.culprit.pr, 102)
        self.assertEqual(result.good, sha(1))

    def test_green_at_red_head_blames_nobody(self):
        result = bb.bisect(bb.candidates(log_for(5)), FakeRunner(None), good=sha(0))
        self.assertEqual(result.status, "not-reproduced")
        self.assertIsNone(result.culprit)

    def test_no_verdict_stops_with_the_narrowed_range(self):
        runner = FakeRunner(6, none={4})
        result = bb.bisect(bb.candidates(log_for(8)), runner, good=sha(0))
        self.assertEqual(result.status, "unresolved")
        self.assertIsNone(result.culprit)
        self.assertEqual(result.bad, sha(8))

    def test_no_verdict_at_head(self):
        result = bb.bisect(bb.candidates(log_for(3)), FakeRunner(1, none={3}), good=sha(0))
        self.assertEqual(result.status, "unresolved")

    def test_probe_budget(self):
        result = bb.bisect(bb.candidates(log_for(64)), FakeRunner(3), good=sha(0), max_probes=3)
        self.assertEqual(result.status, "too-many")
        self.assertEqual(len(result.probes), 3)

    def test_empty_range(self):
        runner = FakeRunner(1)
        result = bb.bisect([], runner, good=sha(0))
        self.assertEqual(result.status, "empty")
        self.assertEqual(runner.calls, [])


class ReportTest(unittest.TestCase):
    def test_failing_tests_from_xctest_and_swift_testing(self):
        log = (
            "Test Case '-[CmuxMobileLiveTests.LinkRecoveryTests testRetry]' failed (0.2 seconds).\n"
            "Test Case '-[CmuxMobileLiveTests.LinkRecoveryTests testRetry]' failed (0.2 seconds).\n"
            "✘ Test bannerShowsOffline() recorded an issue at Banner.swift:10\n"
        )
        self.assertEqual(
            bb.failing_tests(log), ["CmuxMobileLiveTests.LinkRecoveryTests/testRetry", "bannerShowsOffline"]
        )

    def test_comment_names_test_run_and_never_reverts(self):
        result = bb.bisect(bb.candidates(log_for(4)), FakeRunner(3), good=sha(0))
        body = bb.comment_body(result, red=sha(4), run_url="https://example.invalid/run/1", failing=["A/b"], mode="test")
        self.assertIn(bb.MARKER.format(red=sha(4)), body)
        self.assertIn("`A/b`", body)
        self.assertIn("https://example.invalid/run/1", body)
        self.assertIn(f"--ref {sha(3)}", body)
        self.assertIn("Nothing was reverted or blocked", body)

    def test_summary_lists_probes(self):
        commits = bb.candidates(log_for(4))
        result = bb.bisect(commits, FakeRunner(3), good=sha(0))
        text = bb.summary(result, commits, red=sha(4))
        self.assertIn("Culprit: #103", text)
        self.assertIn("| red |", text)
        self.assertIn("| green |", text)


if __name__ == "__main__":
    unittest.main()

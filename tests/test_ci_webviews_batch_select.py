#!/usr/bin/env python3
"""webviews_batch_select.py: a post-merge batch tick carries a file's last pass only when the change since cannot
reach it, and sizes the shard matrix to what it runs."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import webviews_batch_select as bs  # noqa: E402

NOW = 1_800_000_000.0 + 12 * 3600 - 1_800_000_000.0 % 86400  # 12:00 UTC
TESTS = {f"webviews/src/t{i}.test.ts" for i in range(10)}


class FakeGraph:
    def __init__(self, tests):
        self.tests = tests


class FakeSelector:
    """select() maps a diff (a list of paths) to the tests it names, or None when one path is `bun.lock`."""

    def __init__(self, tests=TESTS, always=()):
        self.graph = FakeGraph(sorted(tests))
        self.always = set(always)
        self.root = Path(".")

    def select(self, files):
        if "webviews/bun.lock" in files:
            return None, "build input"
        return {f for f in files if f in self.graph.tests} | self.always, ""


def run(sha, files, red=(), time=NOW - 3600):
    return {"sha": sha, "time": time, "inputs": "k", "files": sorted(f.removeprefix("webviews/") for f in files),
            "red": [f"{f.removeprefix('webviews/')} > a test" for f in red]}


class Select(unittest.TestCase):
    def pick(self, runs, diffs, selector=None):
        return bs.select(selector or FakeSelector(), runs, "head", NOW, diff=lambda base: diffs[base])

    def test_carries_passes_the_change_cannot_reach(self):
        picked, _, counts = self.pick([run("a", TESTS)], {"a": ["webviews/src/t1.test.ts", "README.md"]})
        self.assertEqual(picked, {"webviews/src/t1.test.ts"})
        self.assertEqual(counts["carried"], 9)

    def test_a_standing_red_runs_every_tick(self):
        picked, _, _ = self.pick([run("a", TESTS, red=["webviews/src/t2.test.ts"])], {"a": []})
        self.assertEqual(picked, {"webviews/src/t2.test.ts"})

    def test_newest_verdict_wins(self):
        runs = [run("a", TESTS, red=["webviews/src/t3.test.ts"], time=NOW - 7200), run("b", ["webviews/src/t3.test.ts"])]
        picked, _, _ = self.pick(runs, {"a": [], "b": []})
        self.assertEqual(picked, set())

    def test_a_file_never_recorded_runs(self):
        picked, _, _ = self.pick([run("a", TESTS - {"webviews/src/t4.test.ts"})], {"a": []})
        self.assertEqual(picked, {"webviews/src/t4.test.ts"})

    def test_a_build_input_runs_every_file_it_passed_before(self):
        runs = [run("a", TESTS - {"webviews/src/t5.test.ts"}, time=NOW - 7200), run("b", ["webviews/src/t5.test.ts"])]
        picked, _, _ = self.pick(runs, {"a": ["webviews/bun.lock"], "b": []})
        self.assertEqual(picked, TESTS - {"webviews/src/t5.test.ts"})

    def test_a_commit_that_does_not_diff_runs_its_files(self):
        def diff(base):
            raise OSError("no such commit")
        picked, _, counts = bs.select(FakeSelector(), [run("a", TESTS)], "head", NOW, diff=diff)
        self.assertEqual(picked, TESTS)
        self.assertEqual(counts["unresolved"], 10)

    def test_always_run_files_run(self):
        picked, _, _ = self.pick([run("a", TESTS)], {"a": []}, FakeSelector(always={"webviews/src/t6.test.ts"}))
        self.assertEqual(picked, {"webviews/src/t6.test.ts"})

    def test_the_first_tick_of_a_utc_day_runs_every_file(self):
        picked, why, _ = self.pick([run("a", TESTS, time=NOW - 13 * 3600)], {"a": []})
        self.assertIsNone(picked)
        self.assertIn("daily", why)

    def test_a_later_tick_that_day_selects(self):
        runs = [run("a", TESTS, time=NOW - 13 * 3600), run("b", ["webviews/src/t1.test.ts"], time=NOW - 11 * 3600)]
        self.assertEqual(self.pick(runs, {"a": [], "b": []})[0], set())

    def test_no_history_runs_every_file(self):
        self.assertIsNone(self.pick([], {})[0])


class Shards(unittest.TestCase):
    def test_count_follows_selected_seconds(self):
        secs = {f.removeprefix("webviews/"): 100.0 for f in TESTS}
        self.assertEqual(bs.shard_count(set(), TESTS, secs, 12), 1)
        self.assertEqual(bs.shard_count({"webviews/src/t1.test.ts"}, TESTS, secs, 12), 2)
        self.assertEqual(bs.shard_count(TESTS, TESTS, secs, 12), 12)


if __name__ == "__main__":
    unittest.main()

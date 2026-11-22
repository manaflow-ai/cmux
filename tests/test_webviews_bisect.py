#!/usr/bin/env python3
"""scripts/ci/webviews_bisect.py pins a newly red webview test file to one merged commit.

The bisect runs against a fake probe (a set of red shas), so each case checks the verdict, the culprit and the
probe count without running a test. targets() reads history runs shaped like webviews_test_history.py's, and
merge() joins per-file results into the CULPRITS.json another team's auto-revert step reads.
"""
from __future__ import annotations

import json
import math
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import webviews_bisect as wb  # noqa: E402
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)


def suspects(n: int) -> list[dict]:
    return [{"sha": f"c{i:02d}", "pr": 100 + i, "subject": f"change {i} (#{100 + i})"} for i in range(n)]


def probe_breaking_at(commits: list[dict], index: int, calls: list[str] | None = None):
    """Green before commits[index], red from it on; the good sha "g" is green."""
    red = {c["sha"] for c in commits[index:]}

    def probe(sha: str) -> bool:
        if calls is not None:
            calls.append(sha)
        return sha not in red
    return probe


def run(sha: str, files: list[str], red: list[str], time: float = 0) -> dict:
    return {"sha": sha, "attempt": 1, "time": time, "inputs": "k", "files": files, "red": red}


class CommitParse(unittest.TestCase):
    def test_pr_from_squash_and_merge_subjects(self) -> None:
        self.assertEqual(wb.pr_number("Fix the pane (#12345)"), 12345)
        self.assertEqual(wb.pr_number("Fix (#1) the pane (#12345)  "), 12345)
        self.assertEqual(wb.pr_number("Merge pull request #77 from a/b"), 77)
        self.assertIsNone(wb.pr_number("Bump version"))
        self.assertIsNone(wb.pr_number("Mentions #12 in the middle"))

    def test_parse_lines(self) -> None:
        text = "aaa\tFirst (#10)\nbbb\tSecond\twith tab\n\n"
        self.assertEqual(wb.parse_commits(text), [
            {"sha": "aaa", "pr": 10, "subject": "First (#10)"},
            {"sha": "bbb", "pr": None, "subject": "Second\twith tab"},
        ])

    def test_first_parent_range_from_git(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            def git(*args: str) -> str:
                return subprocess.run(["git", "-C", tmp, "-c", "user.name=t", "-c", "user.email=t@t",
                                       "-c", "commit.gpgsign=false", *args],
                                      check=True, capture_output=True, text=True).stdout.strip()
            git_fixture_env.init_repo(tmp, "-b", "main")
            git("commit", "-q", "--allow-empty", "-m", "base")
            good = git("rev-parse", "HEAD")
            git("commit", "-q", "--allow-empty", "-m", "one (#1)")
            git("checkout", "-q", "-b", "side")
            git("commit", "-q", "--allow-empty", "-m", "side work")
            git("checkout", "-q", "main")
            git("merge", "-q", "--no-ff", "side", "-m", "Merge pull request #2 from x/side")
            bad = git("rev-parse", "HEAD")
            found = wb.commits(good, bad, tmp)
            self.assertEqual([(c["pr"], c["subject"]) for c in found],
                             [(1, "one (#1)"), (2, "Merge pull request #2 from x/side")])
            self.assertEqual(found[-1]["sha"], bad)
            with self.assertRaises(subprocess.CalledProcessError):
                wb.commits("nope", bad, tmp)
            result = wb.run_file("a.test.ts", "nope", bad, lambda sha: True, tmp)
            self.assertEqual(result["verdict"], "unresolved")
            self.assertIn("failed", result["reason"])


class Midpoint(unittest.TestCase):
    def test_midpoint(self) -> None:
        self.assertEqual(wb.midpoint(-1, 1), 0)
        self.assertEqual(wb.midpoint(-1, 7), 3)
        self.assertEqual(wb.midpoint(3, 7), 5)
        self.assertEqual(wb.midpoint(5, 7), 6)


class Bisect(unittest.TestCase):
    def test_culprit_first_middle_last(self) -> None:
        commits = suspects(9)
        for index in (0, 4, 8):
            with self.subTest(index=index):
                found = wb.bisect(commits, probe_breaking_at(commits, index), "g")
                self.assertEqual(found["verdict"], "culprit")
                self.assertEqual(found["culprit"], commits[index])
                self.assertEqual(found["probes"][0]["sha"], "g")
                self.assertEqual(found["rounds"], len(found["probes"]) - 1)

    def test_one_commit_needs_no_round(self) -> None:
        commits = suspects(1)
        calls: list[str] = []
        found = wb.bisect(commits, probe_breaking_at(commits, 0, calls), "g")
        self.assertEqual((found["verdict"], found["culprit"], found["rounds"]), ("culprit", commits[0], 0))
        self.assertEqual(calls, ["g"])

    def test_red_at_good_is_base_red(self) -> None:
        found = wb.bisect(suspects(5), lambda sha: False, "g")
        self.assertEqual((found["verdict"], found["culprit"], found["rounds"]), ("base-red", None, 0))
        self.assertEqual([p["sha"] for p in found["probes"]], ["g"])

    def test_confirm_bad_green_is_flaky(self) -> None:
        commits = suspects(5)
        found = wb.bisect(commits, lambda sha: True, "g", confirm_bad=True)
        self.assertEqual(found["verdict"], "flaky")
        self.assertEqual([p["sha"] for p in found["probes"]], ["g", "c04"])
        confirmed = wb.bisect(commits, probe_breaking_at(commits, 2), "g", confirm_bad=True)
        self.assertEqual((confirmed["verdict"], confirmed["culprit"]), ("culprit", commits[2]))
        self.assertEqual(confirmed["rounds"], len(confirmed["probes"]) - 2)

    def test_probe_cap(self) -> None:
        commits = suspects(64)
        found = wb.bisect(commits, probe_breaking_at(commits, 40), "g", max_probes=3)
        self.assertEqual(found["verdict"], "unresolved")
        self.assertIsNone(found["culprit"])
        self.assertEqual(len(found["probes"]), 3)
        self.assertIn("probe cap", found["reason"])

    def test_empty_range(self) -> None:
        found = wb.bisect([], lambda sha: True, "g")
        self.assertEqual((found["verdict"], found["probes"]), ("unresolved", []))

    def test_rounds_within_log2(self) -> None:
        for n in range(1, 70):
            commits = suspects(n)
            bound = math.ceil(math.log2(n)) if n > 1 else 0
            for index in range(n):
                found = wb.bisect(commits, probe_breaking_at(commits, index), "g", max_probes=99)
                self.assertEqual(found["culprit"], commits[index], (n, index))
                self.assertLessEqual(found["rounds"], bound, (n, index))

    def test_probe_seconds(self) -> None:
        ticks = iter([0.0, 1.25, 5.0, 7.0])
        found = wb.bisect(suspects(2), lambda sha: sha != "c01", "g", clock=lambda: next(ticks))
        self.assertEqual([p["seconds"] for p in found["probes"]], [1.2, 2.0])


class Targets(unittest.TestCase):
    def test_newly_red(self) -> None:
        runs = [
            run("s1", ["a", "b", "c"], ["b"]),
            run("s2", ["a", "b"], ["b > it fails"]),  # c did not run here; b red again
            run("s3", ["a", "b", "c", "d"], ["a > x", "b", "c", "d"]),
        ]
        self.assertEqual(wb.targets(runs), {
            "bad": "s3",
            "targets": [{"file": "a", "good": "s2"}, {"file": "c", "good": "s1"}],
            "skipped_over_cap": 0,
        })

    def test_cap(self) -> None:
        files = [f"f{i}" for i in range(5)]
        runs = [run("s1", files, []), run("s2", files, files)]
        found = wb.targets(runs, max_files=2)
        self.assertEqual(found["targets"], [{"file": "f0", "good": "s1"}, {"file": "f1", "good": "s1"}])
        self.assertEqual(found["skipped_over_cap"], 3)

    def test_empty(self) -> None:
        self.assertEqual(wb.targets([]), {"bad": "", "targets": [], "skipped_over_cap": 0})
        self.assertEqual(wb.targets([run("s1", ["a"], ["a"])])["targets"], [])

    def test_cli_github_output(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            history = Path(tmp) / "h.json"
            history.write_text(json.dumps({"runs": [run("s1", ["a"], []), run("s2", ["a"], ["a"])]}))
            gh = Path(tmp) / "gh"
            out = Path(tmp) / "t.json"
            self.assertEqual(wb.main(["targets", str(history), "--out", str(out), "--github-output", str(gh)]), 0)
            self.assertEqual(json.loads(out.read_text())["targets"], [{"file": "a", "good": "s1"}])
            self.assertEqual(gh.read_text(), 'matrix=[{"file":"a","good":"s1"}]\ncount=1\n')


class Merge(unittest.TestCase):
    def test_groups_by_culprit_oldest_first(self) -> None:
        commits = suspects(6)

        def result(file: str, verdict: str, culprit: dict | None, rng: list[dict]) -> dict:
            return {"file": file, "verdict": verdict, "good": "g", "bad": "c05", "suspects": rng, "culprit": culprit,
                    "probes": [], "rounds": 0, "reason": ""}
        results = [
            result("x", "culprit", commits[4], commits),
            result("y", "culprit", commits[1], commits[1:]),  # a shorter range still orders by distance to bad
            result("w", "culprit", commits[4], commits[3:]),
            result("z", "base-red", None, commits),
        ]
        doc = wb.merge(results, run_url="u")
        self.assertEqual((doc["schema"], doc["bad"], doc["run_url"]), ("webviews-bisect/1", "c05", "u"))
        self.assertEqual(doc["culprits"], [
            {"sha": "c01", "pr": 101, "subject": "change 1 (#101)", "files": ["y"]},
            {"sha": "c04", "pr": 104, "subject": "change 4 (#104)", "files": ["w", "x"]},
        ])

    def test_cli_unreadable_result_and_summary(self) -> None:
        commits = suspects(3)
        with tempfile.TemporaryDirectory() as tmp:
            good = Path(tmp) / "a.json"
            good.write_text(json.dumps({"file": "a.test.ts", "verdict": "culprit", "good": "g", "bad": "c02",
                                        "suspects": commits, "culprit": commits[1],
                                        "probes": [{"sha": "g", "green": True, "seconds": 1.0}], "rounds": 1,
                                        "reason": "r"}))
            (Path(tmp) / "bad.json").write_text("{not json")
            out, summary = Path(tmp) / "c.json", Path(tmp) / "s.md"
            wb.main(["merge", str(good), str(Path(tmp) / "bad.json"), str(Path(tmp) / "gone.json"),
                     "--out", str(out), "--summary", str(summary), "--repo-slug", "o/r"])
            doc = json.loads(out.read_text())
            self.assertEqual([f["verdict"] for f in doc["files"]], ["culprit", "unresolved", "unresolved"])
            self.assertEqual(doc["bad"], "c02")
            self.assertEqual(doc["culprits"][0]["files"], ["a.test.ts"])
            text = summary.read_text()
            self.assertIn("[#101](https://github.com/o/r/pull/101)", text)
            self.assertIn("| `a.test.ts` | culprit: r |", text)


if __name__ == "__main__":
    unittest.main()

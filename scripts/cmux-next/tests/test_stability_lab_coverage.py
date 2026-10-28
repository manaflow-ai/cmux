#!/usr/bin/env python3
"""stability-lab.py coverage (p10-stability-007) on a 10-commit fixture repository.

The fixture branch has 10 first-parent commits, one hour apart, plus one older commit before the window
and a side-branch commit that a merge brings in. Lab tips sit at commits 4, 7 and 10. A commit is covered
only when a tip that contains it passed every fast lane; long lanes do not count.

    python3 -I -m unittest scripts/cmux-next/tests/test_stability_lab_coverage.py
    python3 -I -m pytest scripts/cmux-next/tests/test_stability_lab_coverage.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "stability-lab.py"
BASE = 1_790_000_000  # fixed commit clock, so the window is exact
HOUR = 3600
FAST = ["crash-e2e", "smoke-14", "smoke-26"]


def load_lab():
    spec = importlib.util.spec_from_file_location("stability_lab", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses resolve annotations through sys.modules
    spec.loader.exec_module(module)
    return module


lab = load_lab()


class Fixture:
    """Commit 0 is before the window; commits 1..10 are the window; commit 6 merges side branch s1."""

    def __init__(self, root: Path) -> None:
        self.repo = root / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.shas: dict[int, str] = {}
        self.commit(0, BASE - 10 * HOUR)
        for n in range(1, 11):
            when = BASE + n * HOUR
            if n == 6:
                self.git("checkout", "-q", "-b", "side", self.shas[5])
                self.side = self.commit("s1", when - HOUR // 2)
                self.git("checkout", "-q", "main")
                self.git("merge", "-q", "--no-ff", "-m", "c6 merge side", "side", env=self.clock(when))
                self.shas[6] = self.rev("HEAD")
            else:
                self.commit(n, when)
        self.now = BASE + 10 * HOUR + 60

    @staticmethod
    def clock(when: int) -> dict[str, str]:
        return {"GIT_AUTHOR_DATE": f"@{when} +0000", "GIT_COMMITTER_DATE": f"@{when} +0000"}

    def git(self, *args: str, env: dict[str, str] | None = None) -> str:
        full_env = {
            **os.environ,
            "GIT_AUTHOR_NAME": "lab",
            "GIT_AUTHOR_EMAIL": "lab@example.invalid",
            "GIT_COMMITTER_NAME": "lab",
            "GIT_COMMITTER_EMAIL": "lab@example.invalid",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            **(env or {}),
        }
        return subprocess.run(
            ["git", "-C", str(self.repo), *args], capture_output=True, text=True, check=True, env=full_env
        ).stdout.strip()

    def rev(self, rev: str) -> str:
        return self.git("rev-parse", rev)

    def commit(self, n, when: int) -> str:
        (self.repo / f"f{n}.txt").write_text(f"{n}\n")
        self.git("add", f"f{n}.txt")
        self.git("commit", "-q", "-m", f"c{n}", env=self.clock(when))
        sha = self.rev("HEAD")
        if isinstance(n, int):
            self.shas[n] = sha
        return sha


def green() -> dict[str, str]:
    return {lane: "passed" for lane in FAST}


class CoverageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = tempfile.TemporaryDirectory()
        cls.fx = Fixture(Path(cls.tmp.name))

    @classmethod
    def tearDownClass(cls) -> None:
        cls.tmp.cleanup()

    def report(self, tips: dict[str, dict[str, str]], since: str = "10h") -> dict:
        return lab.coverage(
            lab.Git(self.fx.repo), "main", lab.since_epoch(since, self.fx.now), FAST, tips
        )

    def by_number(self, report: dict) -> dict[int, dict]:
        number = {sha: n for n, sha in self.fx.shas.items()}
        return {number[row["sha"]]: row for row in report["commits"]}

    def test_window_lists_the_ten_first_parent_commits_newest_first(self) -> None:
        report = self.report({})
        self.assertEqual([row["sha"] for row in report["commits"]], [self.fx.shas[n] for n in range(10, 0, -1)])
        self.assertNotIn(self.fx.side, [row["sha"] for row in report["commits"]])
        self.assertEqual(report["summary"], {"commits": 10, "covered": 0, "uncovered": 10, "percent": 0.0})
        self.assertEqual(report["schema"], "cmux-stability-coverage/v1")

    def test_covered_only_by_a_containing_tip_that_passed_every_fast_lane(self) -> None:
        sha = self.fx.shas
        tips = {
            sha[4]: {**green(), "vm-fuzz-26": "failed"},  # a long-lane failure does not uncover
            sha[7]: {**green(), "smoke-14": "failed"},
            sha[10]: {"crash-e2e": "passed", "smoke-14": "passed", "smoke-26": "running"},
        }
        rows = self.by_number(self.report(tips))
        for n in range(1, 5):
            self.assertTrue(rows[n]["covered"], n)
            self.assertEqual(rows[n]["covering_tip"], sha[4])
            # Every containing tip is listed, newest first.
            self.assertEqual([tip["tip"] for tip in rows[n]["tips"]], [sha[10], sha[7], sha[4]])
        for n in range(5, 11):
            self.assertFalse(rows[n]["covered"], n)
            self.assertIsNone(rows[n]["covering_tip"])
        self.assertEqual([tip["tip"] for tip in rows[9]["tips"]], [sha[10]])
        seven = rows[5]["tips"][1]
        self.assertEqual(seven["tip"], sha[7])
        self.assertEqual(seven["lanes_failed"], ["smoke-14"])
        self.assertEqual(seven["lanes_passed"], ["crash-e2e", "smoke-26"])
        self.assertFalse(seven["fast_lanes_passed"])
        ten = rows[10]["tips"][0]
        self.assertEqual(ten["lanes_pending"], ["smoke-26"])
        self.assertEqual(self.report(tips)["summary"]["covered"], 4)

    def test_a_missing_fast_lane_is_pending_not_passed(self) -> None:
        rows = self.by_number(self.report({self.fx.shas[10]: {"crash-e2e": "passed", "smoke-14": "passed"}}))
        self.assertFalse(rows[1]["covered"])
        self.assertEqual(rows[1]["tips"][0]["lanes_pending"], ["smoke-26"])

    def test_an_earlier_tip_never_covers_a_later_commit(self) -> None:
        rows = self.by_number(self.report({self.fx.shas[3]: green()}))
        self.assertEqual(sorted(n for n, row in rows.items() if row["covered"]), [1, 2, 3])
        self.assertEqual(rows[4]["tips"], [])

    def test_green_newest_tip_covers_all_and_side_branch_tips_count(self) -> None:
        self.assertEqual(self.report({self.fx.shas[10]: green()})["summary"]["percent"], 100.0)
        # A tip on the side branch contains commits 1..5 (its fork point) but not the merge.
        rows = self.by_number(self.report({self.fx.side: green()}))
        self.assertEqual(sorted(n for n, row in rows.items() if row["covered"]), [1, 2, 3, 4, 5])

    def test_window_bounds_and_short_tip_names(self) -> None:
        report = self.report({self.fx.shas[10][:12]: green(), "0" * 40: green()}, since="3h")
        self.assertEqual(len(report["commits"]), 3)
        self.assertEqual(report["summary"]["covered"], 3)
        self.assertEqual(report["unknown_tips"], ["0" * 40])

    def test_cli_table_json_and_check(self) -> None:
        root = Path(self.tmp.name)
        lanes = root / "lanes.json"
        lanes.write_text(json.dumps({"lanes": [{"id": lane, "tier": "fast"} for lane in FAST]
                                     + [{"id": "vm-fuzz-26", "tier": "long"}]}))
        state = root / "state.json"
        state.write_text(json.dumps({"tips": [
            {"sha": self.fx.shas[4], "lanes": {lane: {"status": "passed"} for lane in FAST}},
            {"sha": self.fx.shas[10], "lanes": {**green(), "smoke-26": [{"status": "passed"}, {"status": "failed"}]}},
        ]}))
        since = lab.dt.datetime.fromtimestamp(BASE, lab.dt.timezone.utc).isoformat()
        common = ["coverage", "--repo", str(self.fx.repo), "--ref", "main", "--since", since,
                  "--lanes", str(lanes), "--state", str(state)]

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(lab.main(common + ["--check"]), 1)
        table = out.getvalue()
        self.assertIn("COVERED", table)
        self.assertIn("covered 4/10 (40.0 %)", table)
        self.assertIn(f"{self.fx.shas[10][:11]}  ", table)
        self.assertIn("smoke-26", table)

        out = io.StringIO()
        json_out = root / "out" / "coverage.json"
        with contextlib.redirect_stdout(out):
            self.assertEqual(lab.main(common + ["--json", "--json-out", str(json_out)]), 0)
        printed = json.loads(out.getvalue())
        self.assertEqual(printed, json.loads(json_out.read_text()))
        self.assertEqual(printed["fast_lanes"], FAST)
        self.assertEqual(printed["summary"]["covered"], 4)

    def test_bad_inputs_are_refused(self) -> None:
        with self.assertRaises(lab.LabError):
            lab.fast_lanes({"lanes": [{"id": "vm-fuzz-26", "tier": "long"}]})
        with self.assertRaises(lab.LabError):
            lab.since_epoch("yesterday", self.fx.now)
        with self.assertRaises(lab.LabError):
            lab.coverage(lab.Git(self.fx.repo), "no-such-ref", 0, FAST, {})
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(lab.main(["coverage", "--repo", str(self.fx.repo), "--lanes", "/nonexistent.json"]), 2)
        self.assertIn("lanes registry not found", err.getvalue())

    def test_since_parses_durations(self) -> None:
        self.assertEqual(lab.since_epoch("72h", 1_000_000), 1_000_000 - 72 * HOUR)
        self.assertEqual(lab.since_epoch("3d", 1_000_000), 1_000_000 - 72 * HOUR)
        self.assertEqual(lab.since_epoch("90m", 1_000_000), 1_000_000 - 90 * 60)


if __name__ == "__main__":
    unittest.main()

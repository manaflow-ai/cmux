#!/usr/bin/env python3
"""The CI timing readout finds the critical path and places it against history."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import ci_timing_readout as readout  # noqa: E402


def at(seconds: int) -> str:
    return f"2026-09-25T10:{seconds // 60:02d}:{seconds % 60:02d}Z"


def job(name, created, started, completed, runner="blacksmith-4vcpu-ubuntu-2404-Runner-1",
        labels=("blacksmith-4vcpu-ubuntu-2404",), conclusion="success", steps=()):
    return {
        "name": name, "created_at": at(created), "started_at": at(started), "completed_at": at(completed),
        "runner_name": runner, "labels": list(labels), "conclusion": conclusion, "run_attempt": 1,
        "steps": [{"name": n, "started_at": at(a), "completed_at": at(b)} for n, a, b in steps],
    }


# changes 0-30; compile admission (mini) created at 31, queued 9 s, runs 5 min;
# guards finish early; shard 2/3 waits 4 min behind the admission; the
# status roll-ups follow; one job was reused from an earlier attempt.
JOBS = [
    job("changes", 0, 2, 30),
    job("guards / workflow-guard-tests / ci", 31, 33, 120),
    job("macos / macOS compile admission", 31, 40, 340, runner="cmux14-glaeda", labels=("glaeda-root-std",),
        steps=[("Compile app-host test product", 60, 280), ("Checkout", 40, 45)]),
    job("macos / app-host unit tests (1/3)", 341, 350, 700, labels=("blacksmith-12vcpu-macos-26",)),
    job("macos / app-host unit tests (2/3)", 341, 581, 1100, labels=("blacksmith-12vcpu-macos-26",),
        steps=[("Run unit tests", 600, 1000)]),
    job("macos / macOS status", 1101, 1103, 1106),
    job("tests", 1107, 1109, 1112),
    job("ci-status", 1113, 1115, 1118),
    job("web", 30, 20, 25),  # reused: started before created
    {"name": "browser", "created_at": at(30), "started_at": at(30), "completed_at": at(30), "runner_name": None,
     "labels": [], "conclusion": "skipped", "steps": []},
]


def series(metric, job="", step="", p50=100.0, p90=200.0, recent=(10, 100, 200), past=(40, 100, 200)):
    q = [50, p50 * 0.5, p50 * 0.7, p50 * 0.8, p50 * 0.9, p50, (p50 + p90) / 2 * 0.9, (p50 + p90) / 2, p90 * 0.9, p90, p90 * 1.2, p90 * 1.5]
    return {"metric": metric, "job": job, "step": step, "runner": "", "recent": list(recent), "past": list(past), "q": q}


STATS = {"series": [
    series("run", "macos / macOS compile admission", p50=240, p90=280, recent=(12, 300, 330), past=(60, 240, 280)),
    series("queue", "macos / app-host unit tests (*)", p50=20, p90=60),
    series("run", "macos / app-host unit tests (*)", p50=400, p90=600),
    series("step", "macos / macOS compile admission", "Compile app-host test product", p50=150, p90=200),
    series("run", "guards / workflow-guard-tests / ci", p50=40, p90=50),
    series("wall", p50=900, p90=1300),
]}


class CriticalPathTests(unittest.TestCase):
    def test_chain_follows_the_last_finished_predecessor(self):
        chain = [j.name for j in readout.critical_path([readout.Job(j) for j in JOBS])]
        self.assertEqual(chain, [
            "changes", "macos / macOS compile admission", "macos / app-host unit tests (2/3)",
            "macos / macOS status", "tests",
        ])

    def test_reused_and_skipped_jobs_did_not_run_here(self):
        jobs = {j["name"]: readout.Job(j) for j in JOBS}
        self.assertTrue(jobs["web"].reused)
        self.assertFalse(jobs["web"].fresh)
        self.assertFalse(jobs["browser"].ran)


class ReadoutTests(unittest.TestCase):
    def test_readout_with_history(self):
        text = readout.build_readout(JOBS, STATS, "pr", run_attempt=2)
        headline = text.splitlines()[2]
        self.assertTrue(headline.startswith("**wall 18m32s (p"), headline)
        self.assertIn("attempt 2", headline)
        self.assertIn("macOS compile admission 5m00s (p9", headline)
        self.assertIn("app-host unit tests (2/3) queued 4m00s (above p90) + 8m39s", headline)
        self.assertNotIn("tests 3s", headline)  # roll-ups stay in the table only
        self.assertIn("| macos / macOS compile admission | mini cmux14 | 9s |", text)
        self.assertIn("| p92 (p50 4m00s, p90 4m40s) | 5m00s vs 4m00s ↑ |", text)
        self.assertIn("| macOS compile admission | Compile app-host test product | 3m40s | p92 (p50 2m30s, p90 3m20s) |", text)
        self.assertIn("**4m00s (>p99), above p90**", text)
        self.assertNotIn("Checkout", text)  # under the step floor
        self.assertIn("guards / workflow-guard-tests / ci: run 1m27s", text)
        self.assertEqual(readout.short_name("guards / workflow-guard-tests / ci"), "workflow-guard-tests / ci")
        self.assertIn("1 job reused from an earlier attempt", text)
        self.assertNotIn("—", text)

    def test_readout_without_history(self):
        text = readout.build_readout(JOBS, None, "pr", stats_note="stats unreachable: URLError")
        self.assertIn("critical path: changes 28s", text.replace("changes queued", "changes"))
        self.assertIn("no history (stats unreachable: URLError)", text)
        self.assertIn("| - | - |", text)

    def test_pipes_in_names_do_not_break_tables(self):
        jobs = [job("a | b", 0, 1, 100, steps=[("x | y", 0, 60)])]
        text = readout.build_readout(jobs, None, "pr")
        self.assertIn("| a \\| b |", text)
        self.assertIn("| x \\| y |", text)

    def test_nothing_ran(self):
        self.assertIn("No job ran", readout.build_readout([JOBS[-1]], None, "pr"))


class HelperTests(unittest.TestCase):
    def test_rank(self):
        q = [20, 10, 20, 30, 40, 50, 60, 70, 80, 90, 95, 99]
        self.assertEqual(readout.rank(5, q), "<p10")
        self.assertEqual(readout.rank(50, q), "p50")
        self.assertEqual(readout.rank(85, q), "p85")
        self.assertEqual(readout.rank(120, q), ">p99")

    def test_segment_and_names(self):
        self.assertEqual(readout.segment("pull_request", "feat"), "pr")
        self.assertEqual(readout.segment("workflow_dispatch", "main"), "main")
        self.assertEqual(readout.segment("merge_group", "gh-readonly-queue/main/pr-1"), "queue")
        self.assertEqual(readout.segment("workflow_dispatch", "feat"), "other")
        self.assertEqual(readout.shard_group("macos / app-host unit tests (3/7)"), "macos / app-host unit tests (*)")
        self.assertIsNone(readout.shard_group("CLI product tests"))
        self.assertEqual(readout.fmt_duration(3725), "1h02m")

    def test_where(self):
        self.assertEqual(readout.where({"runner_name": "cmuxs-mac-mini-5-glaeda-3", "labels": ["glaeda-side-std"]}), "mini cmuxs-mac-mini-5-glaeda-3")
        self.assertEqual(readout.where({"runner_name": "b-1", "labels": ["blacksmith-12vcpu-macos-26"]}), "Blacksmith 12vcpu-macos-26")
        self.assertEqual(readout.where({"runner_name": "GitHub Actions 3", "labels": ["ubuntu-latest"]}), "GitHub-hosted")


if __name__ == "__main__":
    unittest.main()

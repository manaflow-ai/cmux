#!/usr/bin/env python3
"""harness_alerts.py: harness-broken groups, story coverage and Pinpoint's functional bisect.

  python3 -m unittest scripts/perf-lab/tests/test_functional_bisect.py

The scratch-ref tests build a throwaway git repository whose story breaks on purpose at one commit
and bisect it by running the story at each commit, as the lab runs a story at a bisect midpoint.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
_SPEC = importlib.util.spec_from_file_location("perf_lab_harness_alerts", HERE / "harness_alerts.py")
harness = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = harness
_SPEC.loader.exec_module(harness)
alerts = harness.alerts
store_mod = harness.store_mod
perf_stats = harness.perf_stats

NOW = datetime(2026, 10, 26, 12, 0, tzinfo=timezone.utc)
HOST = store_mod.Host(name="cmux15", chip="Apple M6", memory_gb=24, display_hz=120, fingerprint="fp-1")
CLASS = HOST.host_class
STORY = "terminal-key-to-frame-light"


def sha(pos: int) -> str:
    return f"{pos:04d}" + "a" * 36


def outcome(pos: int, status: str, *, story: str = STORY, host: str = "cmux15", reason: str = "") -> object:
    return harness.StoryOutcome(story, CLASS, host, pos, sha(pos), status, reason)


class LabFixture(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.db_path = Path(self._tmp.name) / "lab.sqlite"
        self.store = store_mod.Store(self.db_path, clock=lambda: NOW)
        self.store.migrate()
        self.runs = 0

    def tearDown(self) -> None:
        self.store.close()
        self._tmp.cleanup()

    def add_points(self, *, story: str = STORY, metrics=("key_to_frame_ms", "dropped_frames"),
                   positions=range(0, 100, 10), value: float = 6.0) -> None:
        """Waterfall points of the story's passing batches (a broken batch stores nothing)."""
        for pos in positions:
            self.runs += 1
            run = store_mod.Run(run_uuid=f"run-{self.runs}", kind="waterfall", measure_version="1", story=story,
                                engine="chromium", macos_major=26, macos_build="26.7 (25H1)", features_hash="f0",
                                safe_mode="off", started_at=NOW + timedelta(minutes=self.runs))
            self.store.insert_run(run, build=store_mod.Build(sha=sha(pos), config="bench", commit_pos=pos), host=HOST,
                                  metrics=[store_mod.Metric(name, "ms", "lower", [value] * 10) for name in metrics])

    def detect(self, outcomes):
        return harness.detect(self.store, outcomes)

    def groups(self):
        return self.store._db.execute("SELECT * FROM alert_groups ORDER BY id").fetchall()

    def harness_alerts(self):
        return self.store._db.execute("SELECT * FROM alerts WHERE rule = 'harness_broken' ORDER BY id").fetchall()


class HarnessBrokenTests(LabFixture):
    def test_two_consecutive_env_valid_errors_open_one_harness_broken_group(self) -> None:
        self.add_points()
        report = self.detect([outcome(p, "pass") for p in range(0, 100, 10)]
                             + [outcome(100, "error", reason="socket timeout"),
                                outcome(110, "error", reason="debug.layout missing")])
        self.assertEqual((report.broken, report.alerts), (1, 2))
        [group] = self.groups()
        self.assertEqual(group["state"], "new")
        self.assertEqual((group["start_pos"], group["end_pos"]), (91, 100))
        self.assertEqual({row["group_id"] for row in self.harness_alerts()}, {group["id"]})
        history = self.store._db.execute("SELECT reason FROM sheriff_history WHERE group_id = ?",
                                         (group["id"],)).fetchone()
        self.assertIn("2 consecutive batches", history["reason"])
        self.assertIn("debug.layout missing", history["reason"])
        [job] = harness.functional_bisects(self.store, group["id"])
        self.assertEqual((job.mode, job.good, job.bad, job.story, job.host_class),
                         ("functional", sha(90), sha(100), STORY, CLASS))
        self.assertEqual(report.bisects, [self.store._db.execute("SELECT id FROM jobs").fetchone()["id"]])

    def test_one_error_is_not_harness_broken(self) -> None:
        self.add_points()
        report = self.detect([outcome(90, "pass"), outcome(100, "error")])
        self.assertEqual((report.broken, report.alerts, self.groups()), (0, 0, []))

    def test_error_then_pass_then_error_is_not_consecutive(self) -> None:
        self.add_points()
        report = self.detect([outcome(90, "error"), outcome(100, "pass"), outcome(110, "error")])
        self.assertEqual(report.broken, 0)

    def test_env_invalid_batches_neither_count_nor_break_the_streak(self) -> None:
        self.add_points()
        only_invalid = self.detect([outcome(90, "pass"), outcome(100, "env-invalid"), outcome(110, "env-invalid")])
        self.assertEqual(only_invalid.broken, 0)
        report = self.detect([outcome(90, "pass"), outcome(100, "error"), outcome(110, "env-invalid"),
                              outcome(120, "error")])
        self.assertEqual(report.broken, 1)
        [group] = self.groups()
        self.assertEqual((group["start_pos"], group["end_pos"]), (91, 100))

    def test_a_pass_on_another_host_of_the_batch_is_a_pass(self) -> None:
        self.add_points()
        report = self.detect([outcome(90, "pass"), outcome(100, "error"),
                              outcome(110, "error"), outcome(110, "pass", host="cmux16")])
        self.assertEqual(report.broken, 0)

    def test_rerun_adds_nothing(self) -> None:
        self.add_points()
        history = [outcome(90, "pass"), outcome(100, "error"), outcome(110, "error")]
        self.detect(history)
        again = self.detect(history + [outcome(120, "error")])
        self.assertEqual((again.broken, again.alerts, again.groups_created, again.bisects), (1, 0, [], []))
        self.assertEqual(len(self.groups()), 1)
        self.assertEqual(self.store._db.execute("SELECT COUNT(*) FROM jobs").fetchone()[0], 1)

    def test_story_that_passes_again_fixes_its_group_and_a_new_break_opens_another(self) -> None:
        self.add_points()
        broken = [outcome(90, "pass"), outcome(100, "error"), outcome(110, "error")]
        self.detect(broken)
        recovered = self.detect(broken + [outcome(120, "pass")])
        [group] = self.groups()
        self.assertEqual((group["state"], recovered.groups_fixed), ("fixed", [group["id"]]))
        again = self.detect(broken + [outcome(120, "pass"), outcome(130, "error"), outcome(140, "error")])
        self.assertEqual(len(again.groups_created), 1)
        self.assertEqual([(g["state"], g["start_pos"], g["end_pos"]) for g in self.groups()],
                         [("fixed", 91, 100), ("new", 121, 130)])

    def test_broken_from_the_first_known_batch_opens_a_group_without_a_bisect(self) -> None:
        self.add_points()
        report = self.detect([outcome(100, "error"), outcome(110, "error")])
        self.assertEqual((len(report.groups_created), report.bisects), (1, []))
        self.assertEqual(report.no_good_batch, [f"{STORY} ({CLASS})"])

    def test_story_without_series_is_reported_not_grouped(self) -> None:
        report = self.detect([outcome(90, "pass"), outcome(100, "error"), outcome(110, "error")])
        self.assertEqual((report.no_series, self.groups()), ([f"{STORY} ({CLASS})"], []))

    def test_regression_alert_does_not_join_a_harness_broken_group(self) -> None:
        self.add_points()
        self.detect([outcome(90, "pass"), outcome(100, "error"), outcome(110, "error")])
        db, now = self.store._db, self.store._now()
        series_id = db.execute("SELECT id FROM series ORDER BY id").fetchone()["id"]
        group = self.store._write(lambda: alerts._group_for(db, now, alerts.SeriesInfo.from_row(
            db.execute("SELECT * FROM series WHERE id = ?", (series_id,)).fetchone()), 95, 100, alerts.DetectReport()))
        self.assertNotEqual(group, self.groups()[0]["id"])
        self.assertEqual(len(self.groups()), 2)

    def test_harness_broken_group_never_gets_a_regression_issue(self) -> None:
        self.add_points()
        self.detect([outcome(90, "pass"), outcome(100, "error"), outcome(110, "error")])
        self.store._write(lambda: self.store._db.execute(
            "UPDATE alert_groups SET culprit_sha = ?, culprit_verified = 1, state = 'culprit'", (sha(100),)))
        github = _NoWrites()
        subs = alerts.Subscriptions.parse({"build_configs": ["bench"], "subscriptions": [
            {"name": "key", "kind": "target", "owner": "PL-typing", "match": {"story": "terminal-*"}}]})
        report = alerts.sync_issues(self.store, subs, github, repo="manaflow-ai/cmux", dashboard_url="http://lab")
        self.assertEqual(report.issues_created, [])


class _NoWrites:
    def issue_comment_bodies(self, number):
        return []

    def create_issue(self, title, body, labels):
        raise AssertionError("a harness-broken group opened a perf-regression issue")

    edit_issue = comment = create_issue


class CoverageTests(unittest.TestCase):
    def plan(self, positions, story: str = STORY):
        return [harness.PlannedStory(story, CLASS, pos) for pos in positions]

    def test_failing_story_counts_missing(self) -> None:
        outcomes = ([outcome(p, "pass") for p in (10, 20, 30)] + [outcome(p, "error") for p in (40, 50, 60)]
                    + [outcome(p, "pass", story="split-spring") for p in (10, 20, 30, 40, 50, 60)])
        coverage = harness.story_coverage(self.plan((10, 20, 30, 40, 50, 60)) + self.plan(
            (10, 20, 30, 40, 50, 60), story="split-spring"), outcomes)
        self.assertEqual((coverage.planned, coverage.measured), (12, 9))
        self.assertEqual([(m.story, m.batch_pos, m.reason) for m in coverage.missing],
                         [(STORY, 40, "harness-broken"), (STORY, 50, "harness-broken"), (STORY, 60, "harness-broken")])
        self.assertAlmostEqual(coverage.fraction, 0.75)

    def test_single_error_env_invalid_and_not_run_are_missing_with_their_reason(self) -> None:
        coverage = harness.story_coverage(self.plan((10, 20, 30, 40)), [
            outcome(10, "pass"), outcome(20, "error"), outcome(30, "env-invalid")])
        self.assertEqual([(m.batch_pos, m.reason) for m in coverage.missing],
                         [(20, "error"), (30, "env-invalid"), (40, "not-run")])
        self.assertEqual(coverage.measured, 1)


class FunctionalComparisonTests(unittest.TestCase):
    def test_all_pass_vs_all_fail_is_different(self) -> None:
        verdict = harness.functional_comparison([0] * 10, [1] * 10)
        self.assertEqual((verdict.verdict, verdict.failure_rate_a, verdict.failure_rate_b), ("different", 0.0, 1.0))

    def test_uses_the_functional_high_threshold_floored(self) -> None:
        verdict = harness.functional_comparison([0] * 10, [0] * 7 + [1] * 3)
        expected = max(perf_stats.HighThreshold("functional", harness.FUNCTIONAL_MAGNITUDE, 10), 0.10)
        self.assertEqual(verdict.comparison.floored.high_threshold, expected)
        self.assertEqual(verdict.verdict, "unknown")

    def test_fewer_failures_on_the_later_change_is_same(self) -> None:
        self.assertEqual(harness.functional_comparison([1] * 10, [0] * 10).verdict, "same")

    def test_same_failure_rate_is_same(self) -> None:
        flaky = [1, 0, 0, 0, 0] * 2
        self.assertEqual(harness.functional_comparison(flaky, flaky).verdict, "same")


class FakeStory:
    """A story at commits[index]: fails with `rate` from `breaks_at` on; records attempt counts asked."""

    def __init__(self, commits, breaks_at: int, *, rate_every: int = 1, unbuildable=()) -> None:
        self.index = {sha: i for i, sha in enumerate(commits)}
        self.breaks_at, self.rate_every, self.unbuildable = breaks_at, rate_every, set(unbuildable)
        self.ran: dict[str, int] = {}
        self.build_failed: list[str] = []

    def __call__(self, sha_: str, count: int):
        if sha_ in self.unbuildable:
            self.build_failed.append(sha_)
            return None
        done = self.ran.get(sha_, 0)
        self.ran[sha_] = done + count
        broken = self.index[sha_] >= self.breaks_at
        return [int(broken and (done + i) % self.rate_every == 0) for i in range(count)]


class FunctionalBisectTests(unittest.TestCase):
    COMMITS = [f"c{i:02d}" for i in range(64)]

    def test_story_failing_from_c_bisects_to_c(self) -> None:
        for breaks_at in (1, 17, 40, 63):
            story = FakeStory(self.COMMITS, breaks_at)
            result = harness.functional_bisect(self.COMMITS, story)
            self.assertEqual(result.culprit, self.COMMITS[breaks_at], breaks_at)
            self.assertLessEqual(len(story.ran), 9)

    def test_flaky_failure_from_c_bisects_to_c(self) -> None:
        story = FakeStory(self.COMMITS, 29, rate_every=3)
        self.assertEqual(harness.functional_bisect(self.COMMITS, story).culprit, "c29")

    def test_no_change_ends_same_with_no_culprit(self) -> None:
        story = FakeStory(self.COMMITS, 99)
        result = harness.functional_bisect(self.COMMITS, story)
        self.assertEqual((result.culprit, result.comparisons), (None, (("c00", "c63", "same"),)))

    def test_unbuildable_midpoint_is_skipped(self) -> None:
        story = FakeStory(self.COMMITS, 40, unbuildable={"c32", "c48", "c36"})
        result = harness.functional_bisect(self.COMMITS, story)
        self.assertEqual(result.culprit, "c40")
        self.assertEqual(story.build_failed, ["c32", "c48", "c36"])  # each tried once, then left out of the range

    def test_unbuildable_commit_before_the_culprit_widens_it_to_a_range(self) -> None:
        story = FakeStory(self.COMMITS, 40, unbuildable={"c39"})
        result = harness.functional_bisect(self.COMMITS[30:41], story)
        self.assertEqual((result.culprit, result.good, result.bad, result.skipped), (None, "c38", "c40", ("c39",)))

    def test_unknown_doubles_attempts_10_to_160_then_counts_same(self) -> None:
        asked = []

        def run(sha_: str, count: int):
            asked.append((sha_, count))
            done = sum(n for s, n in asked[:-1] if s == sha_)
            return [int(sha_ == "bad" and done + i < 3) for i in range(count)]  # 3 failures in total

        result = harness.functional_bisect(["good", "bad"], run)
        totals = []
        for name in ("good", "bad"):
            running, seen = 0, []
            for s, n in asked:
                if s == name:
                    running += n
                    seen.append(running)
            totals.append(seen)
        self.assertEqual(totals, [[10, 20, 40, 80, 160]] * 2)
        self.assertEqual((result.culprit, result.comparisons), (None, (("good", "bad", "same"),)))


@unittest.skipUnless(shutil.which("git"), "git is not installed")
class ScratchRefTests(LabFixture):
    """A story broken on purpose at one commit of a scratch repository, found by running it at each commit."""

    def setUp(self) -> None:
        super().setUp()
        self.repo = Path(self._tmp.name) / "scratch"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.shas = []
        for index in range(24):
            broken = index >= 13
            body = ("import sys\n"
                    f"# commit {index}\n"
                    + ("sys.exit('debug.layout: no such method')\n" if broken else "print('{\"ms\": 6.0}')\n"))
            (self.repo / "story.py").write_text(body)
            self.git("add", "story.py")
            self.git("-c", "user.name=lab", "-c", "user.email=lab@example.invalid", "commit", "-q", "-m", f"c{index}")
            self.shas.append(self.git("rev-parse", "HEAD").strip())

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True, text=True).stdout

    def run_story(self, sha_: str, count: int):
        source = self.git("show", f"{sha_}:story.py")
        failed = []
        for _ in range(count):
            result = subprocess.run([sys.executable, "-I", "-c", source], capture_output=True, text=True)
            failed.append(int(result.returncode != 0))
        return failed

    def test_broken_story_alerts_and_its_functional_bisect_finds_the_commit(self) -> None:
        batch_tips = [3, 7, 11, 15, 19, 23]  # positions of 10-minute batch tips in the scratch history
        for pos in batch_tips:
            if not self.run_story(self.shas[pos], 1)[0]:
                self.add_points(positions=[pos])
        outcomes = [harness.StoryOutcome(STORY, CLASS, "cmux15", pos, self.shas[pos],
                                         "error" if self.run_story(self.shas[pos], 1)[0] else "pass")
                    for pos in batch_tips]
        report = self.detect(outcomes)
        [group] = self.groups()
        self.assertEqual((report.broken, group["start_pos"], group["end_pos"]), (1, 12, 15))
        [job] = harness.functional_bisects(self.store, group["id"])
        self.assertEqual((job.good, job.bad), (self.shas[11], self.shas[15]))
        commits = self.git("rev-list", "--first-parent", "--reverse", f"{job.good}^..{job.bad}").split()
        result = harness.functional_bisect(commits, self.run_story)
        self.assertEqual(result.culprit, self.shas[13])
        coverage = harness.story_coverage([harness.PlannedStory(STORY, CLASS, pos) for pos in batch_tips], outcomes)
        self.assertEqual([m.batch_pos for m in coverage.missing], [15, 19, 23])


class CliTests(LabFixture):
    def write_outcomes(self, rows) -> Path:
        path = Path(self._tmp.name) / "outcomes.ndjson"
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
        return path

    def rows(self):
        return [{"story": STORY, "host_class": CLASS, "host": "cmux15", "batch_pos": pos, "sha": sha(pos),
                 "status": status} for pos, status in ((90, "pass"), (100, "error"), (110, "error"))]

    def main(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = harness.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def test_dry_run_writes_nothing(self) -> None:
        self.add_points()
        code, out, _ = self.main("detect", "--db", str(self.db_path), "--outcomes", str(self.write_outcomes(self.rows())),
                                 "--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["broken"], 1)
        self.assertEqual(self.groups(), [])

    def test_detect_writes_the_group(self) -> None:
        self.add_points()
        code, out, _ = self.main("detect", "--db", str(self.db_path), "--outcomes", str(self.write_outcomes(self.rows())))
        self.assertEqual((code, len(json.loads(out)["groups_created"])), (0, 1))
        self.assertEqual(len(self.groups()), 1)

    def test_bad_outcome_line_names_path_and_field(self) -> None:
        rows = self.rows()
        rows[1]["status"] = "crashed"
        path = self.write_outcomes(rows)
        code, _, err = self.main("detect", "--db", str(self.db_path), "--outcomes", str(path))
        self.assertEqual(code, 1)
        self.assertIn(f"{path}:2: status 'crashed'", err)


if __name__ == "__main__":
    unittest.main()

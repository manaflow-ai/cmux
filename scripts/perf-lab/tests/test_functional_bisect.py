#!/usr/bin/env python3
"""harness_alerts.py and Pinpoint's functional mode: harness-broken groups, story coverage, and the functional
bisect of a broken story's pass/fail rate (pinpoint.py's core, pinpoint_exec.py's executor).

  python3 -m unittest scripts/perf-lab/tests/test_functional_bisect.py

The scratch-ref test builds a throwaway git repository whose story breaks on purpose at one commit and bisects
it with the functional Job by running the story at each commit, as the lab runs a story at a bisect midpoint.
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

LAB = Path(__file__).resolve().parent.parent


def _load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return module


harness = _load("perf_lab_harness_alerts", LAB / "harness_alerts.py")
exec_tests = _load("perf_lab_test_pinpoint_exec", LAB / "tests" / "test_pinpoint_exec.py")  # its World and Fixture
exe = exec_tests.exe
pinpoint = exe.pinpoint
perf_stats = pinpoint.perf_stats
alerts = harness.alerts
store_mod = harness.store_mod

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
        history = self.store._db.execute("SELECT actor, reason FROM sheriff_history WHERE group_id = ?",
                                         (group["id"],)).fetchone()
        self.assertEqual(history["actor"], harness.ACTOR)
        self.assertIn("2 consecutive batches", history["reason"])
        self.assertIn("debug.layout missing", history["reason"])
        target = harness.functional_target(self.store, group["id"])
        self.assertEqual((target.series.story, target.series.metric, target.series.host_class, target.good),
                         (STORY, "key_to_frame_ms", CLASS, sha(90)))

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
        self.assertEqual((again.broken, again.alerts, again.groups_created, again.groups_joined), (1, 0, [], []))
        self.assertEqual(len(self.groups()), 1)

    def test_a_closed_group_is_not_reopened_by_the_same_break(self) -> None:
        self.add_points()
        history = [outcome(90, "pass"), outcome(100, "error"), outcome(110, "error")]
        self.detect(history)
        self.store._write(lambda: self.store._db.execute("UPDATE alert_groups SET state = 'invalid'"))
        again = self.detect(history)
        self.assertEqual((again.alerts, again.groups_created, len(self.groups())), (0, [], 1))

    def test_a_pass_leaves_the_group_to_the_sheriff_and_a_new_break_opens_another(self) -> None:
        self.add_points()
        broken = [outcome(90, "pass"), outcome(100, "error"), outcome(110, "error")]
        self.detect(broken)
        recovered = self.detect(broken + [outcome(120, "pass")])
        self.assertEqual((recovered.broken, recovered.groups_created), (0, []))
        self.assertEqual([g["state"] for g in self.groups()], ["new"])  # only sheriff.py moves it, by its rules
        again = self.detect(broken + [outcome(120, "pass"), outcome(130, "error"), outcome(140, "error")])
        self.assertEqual(len(again.groups_created), 1)
        self.assertEqual([(g["state"], g["start_pos"], g["end_pos"]) for g in self.groups()],
                         [("new", 91, 100), ("new", 121, 130)])

    def test_broken_from_the_first_known_batch_is_reported_and_bisects_from_the_store(self) -> None:
        self.add_points(positions=range(0, 60, 10))
        report = self.detect([outcome(100, "error"), outcome(110, "error")])
        self.assertEqual((len(report.groups_created), report.no_good_batch), (1, [f"{STORY} ({CLASS})"]))
        [group] = self.groups()
        self.assertEqual(harness.functional_target(self.store, group["id"]).good, sha(50))

    def test_a_story_never_stored_has_no_good_end(self) -> None:
        self.add_points(positions=[120])  # its only pass is after the break
        self.detect([outcome(100, "error"), outcome(110, "error")])
        [group] = self.groups()
        self.assertIsNone(harness.functional_target(self.store, group["id"]).good)

    def test_story_without_series_is_reported_not_grouped(self) -> None:
        report = self.detect([outcome(90, "pass"), outcome(100, "error"), outcome(110, "error")])
        self.assertEqual((report.no_series, self.groups()), ([f"{STORY} ({CLASS})"], []))

    def test_regression_group_has_no_functional_target(self) -> None:
        self.add_points()
        self.store._write(lambda: self.store._db.execute(
            "INSERT INTO alert_groups (state, start_pos, end_pos, created_at, updated_at) VALUES ('new', 1, 2, ?, ?)",
            (NOW.isoformat(), NOW.isoformat())))
        self.assertIsNone(harness.functional_target(self.store, self.groups()[0]["id"]))

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


def functional_job(commits) -> object:
    return pinpoint.Job(pinpoint.BISECT, pinpoint.FUNCTIONAL, STORY, "key_to_frame_ms", CLASS,
                        pinpoint.Change(commits[0]), pinpoint.Change(commits[-1]),
                        commits=tuple(pinpoint.Commit(s) for s in commits))


def bisect(commits, failed, *, unbuildable=(), compare=None) -> object:
    """Runs a functional bisect to its end; failed(sha, attempt index) says whether that attempt of the story failed."""
    state = pinpoint.JobState(functional_job(commits), **({"compare": compare} if compare else {}))

    def attempt(change, index):
        broke = failed(change.sha, index)
        return pinpoint.Attempt(change, index, values=() if broke else (6.0,), failed=broke)

    return pinpoint.run_to_end(state, lambda change: change.sha not in unbuildable, attempt)


class FunctionalModeTests(unittest.TestCase):
    COMMITS = [f"{i:02x}" * 20 for i in range(64)]

    def failing_from(self, culprit: int, *, every: int = 1):
        index = {s: i for i, s in enumerate(self.COMMITS)}
        return lambda sha_, attempt: index[sha_] >= culprit and attempt % every == 0

    def test_story_failing_from_c_bisects_to_c(self) -> None:
        for culprit in (1, 17, 40, 63):
            with self.subTest(culprit=culprit):
                result = bisect(self.COMMITS, self.failing_from(culprit))
                self.assertEqual(result.outcome, pinpoint.CULPRITS)
                self.assertEqual([c.change.sha for c in result.culprits], [self.COMMITS[culprit]])
                self.assertEqual(result.culprits[0].comparison.basis, pinpoint.FAILURES)

    def test_flaky_failure_from_c_bisects_to_c(self) -> None:
        result = bisect(self.COMMITS, self.failing_from(29, every=2))
        self.assertEqual([c.change.sha for c in result.culprits], [self.COMMITS[29]])

    def test_compares_pass_fail_with_the_functional_threshold_and_magnitude(self) -> None:
        calls = []

        def spy(values_a, values_b, attempt_count, mode, magnitude):
            calls.append((mode, magnitude, set(values_a) | set(values_b)))
            return perf_stats.compare(values_a, values_b, attempt_count, mode, magnitude)

        bisect(self.COMMITS[:9], self.failing_from(5), compare=spy)
        self.assertTrue(calls)
        self.assertEqual({(mode, magnitude) for mode, magnitude, _ in calls}, {("functional", 0.5)})
        self.assertLessEqual(set().union(*(values for _, _, values in calls)), {0.0, 1.0})

    def test_a_story_that_never_broke_has_no_culprit(self) -> None:
        result = bisect(self.COMMITS, lambda sha_, attempt: attempt % 5 == 0)  # flaky the same everywhere
        self.assertEqual((result.outcome, result.culprits), (pinpoint.NO_CULPRIT, ()))

    def test_fewer_failures_later_is_not_a_culprit(self) -> None:
        result = bisect(self.COMMITS[:9], lambda sha_, attempt: sha_ in self.COMMITS[:4])
        self.assertEqual(result.culprits, ())

    def test_unbuildable_commits_are_skipped(self) -> None:
        unbuildable = {self.COMMITS[32], self.COMMITS[39]}
        result = bisect(self.COMMITS, self.failing_from(40), unbuildable=unbuildable)
        [culprit] = result.culprits
        self.assertEqual((culprit.change.sha, culprit.commits), (self.COMMITS[40], (self.COMMITS[39], self.COMMITS[40])))
        self.assertLessEqual({s for s, _ in result.skipped}, unbuildable)


class BrokenStoryWorld(exec_tests.World):
    """The executor's lab world with a story that fails every attempt from commit `breaks_at` on: run_story.py exits
    1 and its artifact holds no result."""

    def __init__(self, root: Path, *, breaks_at: int) -> None:
        super().__init__(root, culprit=len(exec_tests.SHAS))  # no value step anywhere
        self.breaks_at = breaks_at
        self.exit_code = lambda request, number: 1 if self.broken(request.sha) else 0

    def broken(self, sha_: str) -> bool:
        return exec_tests.SHAS.index(sha_) >= self.breaks_at

    def artifact(self, controller_id: str, request, repeats: int) -> Path:
        if not self.broken(request.sha):
            return super().artifact(controller_id, request, repeats)
        folder = self.root / "artifacts" / controller_id
        folder.mkdir(parents=True)
        return folder


class ExecutorTests(exec_tests.Fixture):
    BREAKS_AT = 10

    def seed(self, world: BrokenStoryWorld) -> int:
        """The waterfall at the batch tips: the story stores a run where it passes; another story keeps the failing
        tips measured. Then the harness alerts read the tips' outcomes."""
        shas, lab = exec_tests.SHAS, world.lab
        outcomes = []
        for index in exec_tests.TIPS:
            passed = not world.broken(shas[index])
            story = exec_tests.STORY if passed else "other.story"
            run = store_mod.Run(run_uuid=f"wf-{index}", kind="waterfall", measure_version="1", story=story,
                                engine="native", macos_major=26, macos_build="25A1", features_hash="f", safe_mode="off",
                                started_at=exec_tests.NOW + timedelta(minutes=index))
            lab.insert_run(run, build=store_mod.Build(shas[index], "bench", index), host=exec_tests.M6,
                           metrics=[store_mod.Metric(exec_tests.METRIC, "ms", "lower", [10.0] * 5)])
            world.ledger.record(exe.builds.BuildRecord(shas[index], "bench", "ok", 30, digest="e" * 64,
                                                       app="cmux DEV perf-lab.app"))
            outcomes.append(harness.StoryOutcome(exec_tests.STORY, exec_tests.CLASS, "cmux15", index, shas[index],
                                                 harness.PASS if passed else harness.ERROR, "" if passed else "exit 1"))
        report = harness.detect(lab, outcomes)
        self.assertEqual(report.broken, 1)
        return report.groups_created[0]

    def test_harness_broken_group_bisects_to_the_breaking_commit(self) -> None:
        world = BrokenStoryWorld(self.root, breaks_at=self.BREAKS_AT)
        group_id = self.seed(world)
        executor = self.executor(world)
        self.assertEqual(len(executor.start_bisects()), 1)
        job = json.loads(self.bisect_row(world)["params_json"])["job"]
        self.assertEqual((job["mode"], job["story"], job["metric"], job["magnitude"]),
                         (pinpoint.FUNCTIONAL, exec_tests.STORY, exec_tests.METRIC, None))
        self.assertEqual((job["good"]["sha"], job["bad"]["sha"]), (exec_tests.SHAS[8], exec_tests.SHAS[12]))
        self.drive(world, executor)
        result = self.result(world)
        self.assertEqual(result["outcome"], pinpoint.CULPRITS)
        self.assertEqual([c["change"]["sha"] for c in result["culprits"]], [exec_tests.SHAS[self.BREAKS_AT]])
        group = self.group(world, group_id)
        self.assertEqual((group["state"], group["culprit_sha"]), ("culprit", exec_tests.SHAS[self.BREAKS_AT]))
        self.assertEqual(self.history(world, group_id), [(None, "new"), ("new", "triaged"), ("triaged", "bisecting"),
                                                         ("bisecting", "culprit")])

    def test_harness_broken_group_with_no_stored_pass_waits(self) -> None:
        world = BrokenStoryWorld(self.root, breaks_at=0)
        world.lab.insert_run(  # the story's series exists, from a try run, but the waterfall never stored a pass
            store_mod.Run(run_uuid="try-0", kind="try", measure_version="1", story=exec_tests.STORY, engine="native",
                          macos_major=26, macos_build="25A1", features_hash="f", safe_mode="off",
                          started_at=exec_tests.NOW),
            build=store_mod.Build(exec_tests.SHAS[0], "bench", 0), host=exec_tests.M6,
            metrics=[store_mod.Metric(exec_tests.METRIC, "ms", "lower", [10.0] * 5)])
        group_id = self.seed(world)
        report = self.executor(world).tick()
        self.assertEqual(report.started, [])
        self.assertEqual(report.problems, [f"group {group_id}: no stored waterfall pass of {exec_tests.STORY} "
                                           "before the range"])


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
        self.ran: dict[str, bool] = {}

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True, text=True).stdout

    def story_fails(self, sha_: str) -> bool:
        """Runs the story as committed at sha_; it is deterministic, so one run per commit stands for each attempt."""
        if sha_ not in self.ran:
            source = self.git("show", f"{sha_}:story.py")
            self.ran[sha_] = subprocess.run([sys.executable, "-I", "-c", source], capture_output=True).returncode != 0
        return self.ran[sha_]

    def test_broken_story_alerts_and_its_functional_bisect_finds_the_commit(self) -> None:
        batch_tips = [3, 7, 11, 15, 19, 23]  # positions of 10-minute batch tips in the scratch history
        outcomes = []
        for pos in batch_tips:
            failed = self.story_fails(self.shas[pos])
            if not failed:
                self.store.insert_run(
                    store_mod.Run(run_uuid=f"run-{pos}", kind="waterfall", measure_version="1", story=STORY,
                                  engine="chromium", macos_major=26, macos_build="26.7 (25H1)", features_hash="f0",
                                  safe_mode="off", started_at=NOW + timedelta(minutes=pos)),
                    build=store_mod.Build(sha=self.shas[pos], config="bench", commit_pos=pos), host=HOST,
                    metrics=[store_mod.Metric("key_to_frame_ms", "ms", "lower", [6.0] * 10)])
            outcomes.append(harness.StoryOutcome(STORY, CLASS, "cmux15", pos, self.shas[pos],
                                                 harness.ERROR if failed else harness.PASS))
        report = self.detect(outcomes)
        [group] = self.groups()
        self.assertEqual((report.broken, group["start_pos"], group["end_pos"]), (1, 12, 15))
        target = harness.functional_target(self.store, group["id"])
        self.assertEqual(target.good, self.shas[11])
        bad = self.shas[15]
        commits = [target.good, *self.git("rev-list", "--first-parent", "--reverse", f"{target.good}..{bad}").split()]
        result = bisect(commits, lambda sha_, attempt: self.story_fails(sha_))
        self.assertEqual([c.change.sha for c in result.culprits], [self.shas[13]])
        coverage = harness.story_coverage([harness.PlannedStory(STORY, CLASS, pos) for pos in batch_tips], outcomes)
        self.assertEqual([(m.batch_pos, m.reason) for m in coverage.missing],
                         [(15, "harness-broken"), (19, "harness-broken"), (23, "harness-broken")])


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

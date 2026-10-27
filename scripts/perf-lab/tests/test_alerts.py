#!/usr/bin/env python3
"""alerts.py: subscriptions, alert groups and verified-only issues on a temp lab store.

  python3 -m unittest scripts/perf-lab/tests/test_alerts.py

The change-point detector is a seam (alerts.Detector). StepDetector below finds one step the way
catapult's thresholds would pass it (both segments >= 6 points, >= 10 % relative change), so these
tests do not depend on the E-Divisive port (task 003); CatapultDetectorTests checks the adapter.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import types
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
_SPEC = importlib.util.spec_from_file_location("perf_lab_alerts", HERE / "alerts.py")
alerts = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = alerts
_SPEC.loader.exec_module(alerts)
store_mod = alerts.store_mod
perf_stats = alerts.perf_stats

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
HOST = store_mod.Host(name="cmux15", chip="Apple M6", memory_gb=24, display_hz=120, fingerprint="fp-1")
REPO = "manaflow-ai/cmux"
DASH = "http://lab.test"


class StepDetector:
    """The split with the largest mean shift (>= 6 points each side), if its medians differ by >= 10 %."""

    def __init__(self, min_segment: int = 6, min_relative: float = 0.1) -> None:
        self.min_segment, self.min_relative = min_segment, min_relative

    def change_points(self, values, config):
        best = None
        for split in range(self.min_segment, len(values) - self.min_segment + 1):
            mean_shift = abs(sum(values[split:]) / (len(values) - split) - sum(values[:split]) / split)
            if best is None or mean_shift > best[0]:
                best = (mean_shift, split)
        if best is None:
            return []
        split = best[1]
        before, after = perf_stats.pct(values[:split], 0.5), perf_stats.pct(values[split:], 0.5)
        if not before or abs(after - before) / abs(before) < self.min_relative:
            return []
        return [alerts.ChangePoint(split, split, before, after)]

    def target_miss(self, values, target, better):
        changes = self.change_points(values, {})
        if not changes:
            return None
        split = changes[0].extended_start
        newest, previous = perf_stats.pct(values[split:], 0.5), perf_stats.pct(values[:split], 0.5)
        miss = (lambda v: v > target) if better == "lower" else (lambda v: v < target)
        return split if miss(newest) and not miss(previous) else None


class FakeGitHub:
    """Records writes; comments are readable back as glaeda-gh would serve them."""

    def __init__(self) -> None:
        self.issues: dict[int, dict[str, object]] = {}
        self.comments: dict[int, list[str]] = {}
        self.edits: list[tuple[int, bool]] = []

    def issue_comment_bodies(self, number):
        return list(self.comments.get(number, []))

    def create_issue(self, title, body, labels):
        number = 100 + len(self.issues)
        self.issues[number] = {"title": title, "body": body, "labels": list(labels), "closed": False}
        return number

    def edit_issue(self, number, body, *, closed):
        self.issues[number].update(body=body, closed=closed)
        self.edits.append((number, closed))

    def comment(self, number, body):
        self.comments.setdefault(number, []).append(body)


SUBSCRIPTIONS = alerts.Subscriptions.parse({
    "build_configs": ["bench", "bench-checks", "release"],
    "subscriptions": [
        {"name": "key", "kind": "target", "owner": "PL-typing",
         "match": {"story": "terminal-key-to-frame*", "metric": "key_to_frame_ms"}, "targets": ["key-frame-p50"]},
        {"name": "panes", "kind": "perf-hot", "owner": "PL-motion-core", "match": {"metric": "panes.*.frame"}},
        {"name": "launch", "kind": "target", "owner": "Performance Lead",
         "match": {"story": "launch-*", "metric": "launch_ms"}, "targets": ["launch-cold"]},
    ],
})
TARGETS = {"key-frame-p50": alerts.Target("key-frame-p50", 8.3, "p50"),
           "launch-cold": alerts.Target("launch-cold", 300.0, "p50")}.get


class LabFixture(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.db_path = Path(self._tmp.name) / "lab.sqlite"
        self.clock = [NOW]
        self.store = store_mod.Store(self.db_path, clock=lambda: self.clock[0])
        self.store.migrate()
        self.runs = 0

    def tearDown(self) -> None:
        self.store.close()
        self._tmp.cleanup()

    def add_series(self, *, story: str, metric: str, values: list[float], positions: list[int],
                   better: str = "lower", config: str = "bench", measure_version: str = "1") -> str:
        """One waterfall point per position, 10 samples around each value; returns the series key."""
        for value, pos in zip(values, positions):
            self.runs += 1
            run = store_mod.Run(run_uuid=f"run-{self.runs}", kind="waterfall", measure_version=measure_version,
                                story=story, engine="chromium", macos_major=26, macos_build="26.7 (25H1)",
                                features_hash="f0", safe_mode="off",
                                started_at=NOW + timedelta(minutes=self.runs))
            samples = [value * (1 + (i - 5) * 0.001) for i in range(10)]
            self.store.insert_run(run, build=store_mod.Build(sha=f"{pos:04d}" + "c" * 36, config=config, commit_pos=pos),
                                  host=HOST, metrics=[store_mod.Metric(metric, "ms", better, samples)])
        return store_mod.series_key(story=story, metric=metric, engine="chromium", host_class=HOST.host_class,
                                    macos_major=26, build_config=config)

    def detect(self, keys=None):
        return alerts.detect(self.store, SUBSCRIPTIONS, StepDetector(), TARGETS, keys=keys)

    def sync(self, github):
        return alerts.sync_issues(self.store, SUBSCRIPTIONS, github, repo=REPO, dashboard_url=DASH)

    def groups(self):
        return self.store._db.execute("SELECT * FROM alert_groups ORDER BY id").fetchall()

    def alerts_rows(self):
        return self.store._db.execute("SELECT * FROM alerts ORDER BY id").fetchall()

    def verify(self, group_id: int, sha: str, *, state: str = "culprit") -> None:
        """What task 017 does after a strict DIFFERENT verification (and the sheriff's state move)."""
        def write():
            db = self.store._db
            previous = db.execute("SELECT state FROM alert_groups WHERE id = ?", (group_id,)).fetchone()[0]
            db.execute("UPDATE alert_groups SET culprit_sha = ?, culprit_verified = 1, state = ? WHERE id = ?",
                       (sha, state, group_id))
            db.execute("INSERT INTO sheriff_history (group_id, from_state, to_state, actor, reason, at) "
                       "VALUES (?, ?, ?, 'verify', 'strict DIFFERENT p=0.004', ?)",
                       (group_id, previous, state, self.store._now()))
        self.store._write(write)

    def move(self, group_id: int, state: str, reason: str = "") -> None:
        def write():
            db = self.store._db
            previous = db.execute("SELECT state FROM alert_groups WHERE id = ?", (group_id,)).fetchone()[0]
            db.execute("UPDATE alert_groups SET state = ? WHERE id = ?", (state, group_id))
            db.execute("INSERT INTO sheriff_history (group_id, from_state, to_state, actor, reason, at) "
                       "VALUES (?, ?, ?, 'sheriff', ?, ?)", (group_id, previous, state, reason, self.store._now()))
        self.store._write(write)


def step(before: float, after: float, n_before: int = 8, n_after: int = 8) -> list[float]:
    return [before] * n_before + [after] * n_after


class GroupingTests(LabFixture):
    def test_overlapping_ranges_form_one_group(self) -> None:
        # Step between 70 and 80 (range 71..80) and between 65 and 75 (range 66..75): they overlap.
        key_a = self.add_series(story="terminal-key-to-frame-light", metric="key_to_frame_ms",
                                values=step(6.0, 7.5), positions=[10 * i for i in range(16)])
        key_b = self.add_series(story="split-spring", metric="panes.split.frame",
                                values=step(5.0, 6.5), positions=[10 * i + 5 for i in range(16)])
        report = self.detect([key_a, key_b])
        self.assertEqual(report.alerts, 2)
        groups = self.groups()
        self.assertEqual(len(groups), 1)
        self.assertEqual((groups[0]["start_pos"], groups[0]["end_pos"]), (76, 80))
        self.assertEqual(len(alerts.group_alerts(self.store, groups[0]["id"])), 2)

    def test_disjoint_ranges_form_two_groups(self) -> None:
        self.add_series(story="terminal-key-to-frame-light", metric="key_to_frame_ms",
                        values=step(6.0, 7.5), positions=[10 * i for i in range(16)])
        self.add_series(story="split-spring", metric="panes.split.frame",
                        values=step(5.0, 6.5), positions=[10 * i + 500 for i in range(16)])
        report = self.detect()
        self.assertEqual(report.alerts, 2)
        self.assertEqual(len(self.groups()), 2)
        self.assertEqual(len(report.groups_created), 2)

    def test_unmonitored_series_is_stored_without_alert_or_group(self) -> None:
        key = self.add_series(story="action-sweep", metric="action.newTab.light.commit",
                              values=step(1.0, 3.0), positions=list(range(16)))
        report = self.detect([key])
        self.assertEqual((report.series, report.unmonitored, report.alerts), (1, 1, 0))
        self.assertEqual(len(self.store.series_points(key)), 16)
        self.assertEqual(self.alerts_rows(), [])
        self.assertEqual(self.groups(), [])

    def test_debug_config_never_alerts(self) -> None:
        key = self.add_series(story="terminal-key-to-frame-light", metric="key_to_frame_ms",
                              values=step(6.0, 9.0), positions=list(range(16)), config="debug")
        self.assertEqual(self.detect([key]).unmonitored, 1)
        self.assertEqual(self.groups(), [])

    def test_improvement_is_recorded_and_makes_no_group_or_issue(self) -> None:
        key = self.add_series(story="terminal-key-to-frame-light", metric="key_to_frame_ms",
                              values=step(7.5, 6.0), positions=list(range(16)))
        report = self.detect([key])
        self.assertEqual((report.alerts, report.improvements), (0, 1))
        self.assertEqual(self.groups(), [])
        row, = self.alerts_rows()
        self.assertEqual((row["is_improvement"], row["group_id"]), (1, None))
        github = FakeGitHub()
        self.assertEqual(self.sync(github).issues_created, [])
        self.assertEqual(github.issues, {})

    def test_higher_is_better_drop_is_a_regression(self) -> None:
        subscriptions = alerts.Subscriptions.parse({"build_configs": ["bench"], "subscriptions": [
            {"name": "survival", "kind": "target", "owner": "PL-cef-helper",
             "match": {"story": "chromium-crash-survival"}}]})
        key = self.add_series(story="chromium-crash-survival", metric="survival_rate",
                              values=step(1.0, 0.8), positions=list(range(16)), better="higher")
        report = alerts.detect(self.store, subscriptions, StepDetector(), TARGETS, keys=[key])
        self.assertEqual((report.alerts, report.improvements), (1, 0))

    def test_rerun_adds_no_alert_and_no_group(self) -> None:
        key = self.add_series(story="terminal-key-to-frame-light", metric="key_to_frame_ms",
                              values=step(6.0, 7.5), positions=list(range(16)))
        self.detect([key])
        again = self.detect([key])
        self.assertEqual((again.alerts, again.groups_created, again.groups_joined), (0, [], []))
        self.assertEqual(len(self.alerts_rows()), 1)

    def test_legacy_points_are_not_judged(self) -> None:
        key = self.add_series(story="terminal-key-to-frame-light", metric="key_to_frame_ms",
                              values=step(6.0, 7.5), positions=list(range(16)), measure_version="legacy-perf-cron")
        report = self.detect([key])
        self.assertEqual(report.alerts, 0)
        self.assertEqual(self.alerts_rows(), [])

    def test_target_miss_is_a_tile_not_a_group(self) -> None:
        # 6 ms -> 9 ms crosses the 8.3 ms p50 target: one regression alert (grouped) and one target_miss (not).
        key = self.add_series(story="terminal-key-to-frame-light", metric="key_to_frame_ms",
                              values=step(6.0, 9.0), positions=list(range(16)))
        report = self.detect([key])
        self.assertEqual((report.alerts, report.target_misses), (1, 1))
        rules = {row["rule"]: row["group_id"] for row in self.alerts_rows()}
        self.assertIsNotNone(rules["edivisive"])
        self.assertIsNone(rules["target_miss"])
        self.assertEqual(len(self.groups()), 1)

    def test_target_miss_tile_range_is_the_missing_segment_not_an_older_step(self) -> None:
        # Two steps pass the thresholds (newest first, as catapult returns them): 4 -> 6 at index 8 and
        # 6 -> 9 at index 16. Only the newest segment misses the 8.3 ms target, so the tile's range is
        # the commits before index 16, never the older step's.
        class TwoSteps(StepDetector):
            def change_points(self, values, config):
                return [alerts.ChangePoint(16, 16, 6.0, 9.0), alerts.ChangePoint(8, 8, 4.0, 6.0)]

            def target_miss(self, values, target, better):
                return 16

        key = self.add_series(story="terminal-key-to-frame-light", metric="key_to_frame_ms",
                              values=[4.0] * 8 + [6.0] * 8 + [9.0] * 8, positions=[10 * i for i in range(24)])
        alerts.detect(self.store, SUBSCRIPTIONS, TwoSteps(), TARGETS, keys=[key])
        ranges = {(row["rule"], row["start_pos"], row["end_pos"]) for row in self.alerts_rows()}
        self.assertIn(("target_miss", 151, 160), ranges)
        self.assertEqual({r for r in ranges if r[0] == "edivisive"}, {("edivisive", 151, 160), ("edivisive", 71, 80)})

    def test_group_routes_to_the_owner_of_its_largest_regression(self) -> None:
        self.add_series(story="terminal-key-to-frame-light", metric="key_to_frame_ms",
                        values=step(6.0, 6.8), positions=[10 * i for i in range(16)])
        self.add_series(story="split-spring", metric="panes.split.frame",
                        values=step(5.0, 8.0), positions=[10 * i + 5 for i in range(16)])
        self.detect()
        group, = alerts.list_groups(self.store, SUBSCRIPTIONS)
        self.assertEqual(group["owner"], "PL-motion-core")
        self.assertEqual(group["alerts"][0]["metric"], "panes.split.frame")

    def test_closed_group_does_not_take_new_alerts(self) -> None:
        key_a = self.add_series(story="terminal-key-to-frame-light", metric="key_to_frame_ms",
                                values=step(6.0, 7.5), positions=[10 * i for i in range(16)])
        self.detect([key_a])
        first, = self.groups()
        self.move(first["id"], "invalid", "noise")
        key_b = self.add_series(story="split-spring", metric="panes.split.frame",
                                values=step(5.0, 6.5), positions=[10 * i + 5 for i in range(16)])
        report = self.detect([key_b])
        self.assertEqual(len(report.groups_created), 1)
        self.assertEqual(len(self.groups()), 2)


class IssueTests(LabFixture):
    def make_group(self) -> int:
        self.add_series(story="terminal-key-to-frame-light", metric="key_to_frame_ms",
                        values=step(6.0, 7.5), positions=[10 * i for i in range(16)])
        self.detect()
        group, = self.groups()
        return group["id"]

    def test_unverified_group_gets_no_issue(self) -> None:
        group_id = self.make_group()
        self.move(group_id, "bisecting")
        self.store._write(lambda: self.store._db.execute(
            "UPDATE alert_groups SET culprit_sha = ?, state = 'culprit' WHERE id = ?", ("c" * 40, group_id)))
        github = FakeGitHub()
        report = self.sync(github)
        self.assertEqual((report.issues_created, report.comments), ([], 0))
        self.assertEqual(github.issues, {})

    def test_verified_group_opens_one_labelled_issue_with_the_table(self) -> None:
        group_id = self.make_group()
        self.verify(group_id, "ab" * 20)
        github = FakeGitHub()
        report = self.sync(github)
        self.assertEqual(report.issues_created, [100])
        issue = github.issues[100]
        self.assertEqual(issue["labels"], ["perf-regression"])
        self.assertIn("abababab", issue["title"])
        body = issue["body"]
        self.assertIn("| Story | Metric | Host class | Before p50 / p95 / p99 | After p50 / p95 / p99 | Range "
                      "| Dashboard | Bisect | Traces |", body)
        self.assertIn("terminal-key-to-frame-light", body)
        self.assertIn(HOST.host_class, body)
        self.assertIn(f"[71..80](https://github.com/{REPO}/compare/0070cccccccc...0080cccccccc)", body)
        self.assertIn(f"{DASH}/series/", body)
        self.assertIn("Owner: PL-typing", body)
        self.assertIn("| 6 ms / 6.02 ms / 6.02 ms | 7.5 ms / 7.53 ms / 7.53 ms |", body)
        self.assertEqual(len(github.comments[100]), 1)
        self.assertIn("-> culprit", github.comments[100][0])
        stored = self.store._db.execute("SELECT issue_number FROM alert_groups WHERE id = ?", (group_id,)).fetchone()
        self.assertEqual(stored[0], 100)

    def test_rerun_makes_no_new_issue_or_comment(self) -> None:
        group_id = self.make_group()
        self.verify(group_id, "ab" * 20)
        github = FakeGitHub()
        self.sync(github)
        self.detect()
        again = self.sync(github)
        self.assertEqual((again.issues_created, again.comments, again.edits), ([], 0, 0))
        self.assertEqual(len(github.issues), 1)
        self.assertEqual(len(github.comments[100]), 1)

    def test_each_state_change_is_one_comment_and_an_edit(self) -> None:
        group_id = self.make_group()
        self.verify(group_id, "ab" * 20)
        github = FakeGitHub()
        self.sync(github)
        self.move(group_id, "assigned", "routed to PL-typing")
        self.move(group_id, "fixed", "fixed by #25100")
        report = self.sync(github)
        self.assertEqual((report.comments, report.edits), (2, 1))
        self.assertEqual(len(github.comments[100]), 3)
        self.assertIn("assigned -> fixed", github.comments[100][2])
        self.assertTrue(github.issues[100]["closed"])
        self.assertIn("State: fixed", github.issues[100]["body"])
        self.assertEqual(self.sync(github).comments, 0)

    def test_verified_lab_drift_group_gets_no_issue(self) -> None:
        group_id = self.make_group()
        self.verify(group_id, "ab" * 20, state="lab-drift")
        github = FakeGitHub()
        self.assertEqual(self.sync(github).issues_created, [])

    def test_bisect_job_and_traces_are_linked(self) -> None:
        group_id = self.make_group()
        def write():
            db, now = self.store._db, self.store._now()
            job = db.execute("INSERT INTO jobs (kind, state, alert_group_id, created_at, updated_at) "
                             "VALUES ('bisect', 'done', ?, ?, ?)", (group_id, now, now)).lastrowid
            db.execute("INSERT INTO traces (job_id, kind, digest, url, bytes, created_at) "
                       "VALUES (?, 'signpost', 'd1', 'https://r2.test/d1', 10, ?)", (job, now))
        self.store._write(write)
        self.verify(group_id, "ab" * 20)
        github = FakeGitHub()
        self.sync(github)
        self.assertIn(f"[job 1]({DASH}/jobs/1)", github.issues[100]["body"])
        self.assertIn("[1](https://r2.test/d1)", github.issues[100]["body"])


class GhClientTests(unittest.TestCase):
    def result(self, code: int, stdout: str = "", stderr: str = "") -> subprocess.CompletedProcess:
        return subprocess.CompletedProcess([], code, stdout, stderr)

    def test_reads_go_through_glaeda_gh(self) -> None:
        calls = []
        def runner(argv, **kwargs):
            calls.append(argv)
            return self.result(0, json.dumps({"comments": [{"body": "a"}, {"body": "b"}]}))
        client = alerts.GhClient(REPO, runner=runner, sleep=lambda s: None)
        self.assertEqual(client.issue_comment_bodies(7), ["a", "b"])
        self.assertEqual(calls, [["glaeda-gh", "status", "comment", f"{REPO}#7", "--json"]])

    def test_daemon_down_is_an_error_not_a_fallback(self) -> None:
        client = alerts.GhClient(REPO, runner=lambda argv, **kw: self.result(3), sleep=lambda s: None)
        with self.assertRaisesRegex(alerts.AlertsError, "daemon is down"):
            client.issue_comment_bodies(7)

    def test_rate_limited_write_backs_off_and_retries(self) -> None:
        replies = [self.result(1, stderr="gh: API rate limit exceeded (HTTP 403)"),
                   self.result(1, stderr="HTTP 429"), self.result(0, json.dumps({"number": 42}))]
        sleeps, calls = [], []
        def runner(argv, **kwargs):
            calls.append((argv, json.loads(kwargs["input"])))
            return replies.pop(0)
        client = alerts.GhClient(REPO, runner=runner, sleep=sleeps.append, base_delay_s=2.0)
        self.assertEqual(client.create_issue("t", "b", ["perf-regression"]), 42)
        self.assertEqual(sleeps, [2.0, 4.0])
        self.assertEqual(calls[0][0], ["gh", "api", "--method", "POST", f"repos/{REPO}/issues", "--input", "-"])
        self.assertEqual(calls[0][1]["labels"], ["perf-regression"])

    def test_server_error_on_post_is_not_retried(self) -> None:
        calls = []
        def runner(argv, **kwargs):
            calls.append(argv)
            return self.result(1, stderr="HTTP 502")
        client = alerts.GhClient(REPO, runner=runner, sleep=lambda s: None)
        with self.assertRaises(alerts.AlertsError):
            client.comment(7, "x")
        self.assertEqual(len(calls), 1)

    def test_server_error_on_patch_is_retried(self) -> None:
        replies = [self.result(1, stderr="HTTP 502"), self.result(0, "{}")]
        client = alerts.GhClient(REPO, runner=lambda argv, **kw: replies.pop(0), sleep=lambda s: None)
        client.edit_issue(7, "b", closed=False)
        self.assertEqual(replies, [])


class SubscriptionsTests(unittest.TestCase):
    def test_repo_subscriptions_parse_and_cover_the_kinds(self) -> None:
        subscriptions = alerts.Subscriptions.load(alerts.DEFAULT_SUBSCRIPTIONS)
        kinds = {entry.kind for entry in subscriptions.entries}
        self.assertEqual(kinds, set(alerts.SUBSCRIPTION_KINDS))
        targets = {t for entry in subscriptions.entries for t in entry.targets}
        self.assertGreaterEqual(len(targets), 12)
        self.assertNotIn("debug", subscriptions.build_configs)

    def test_owners_are_owners_md_lanes(self) -> None:
        # Lanes are named in OWNERS.md, perf-lead.md section 4 and the lane docs (PL-blocking: threading-model.md).
        plans = HERE.parent.parent / "plans" / "cmux-next"
        lanes = "".join((plans / name).read_text() for name in ("OWNERS.md", "perf-lead.md", "threading-model.md"))
        for entry in alerts.Subscriptions.load(alerts.DEFAULT_SUBSCRIPTIONS).entries:
            self.assertIn(entry.owner, lanes)

    def test_first_match_wins(self) -> None:
        subscriptions = alerts.Subscriptions.parse({"build_configs": ["bench"], "subscriptions": [
            {"name": "a", "kind": "perf-hot", "owner": "A", "match": {"metric": "panes.*"}},
            {"name": "b", "kind": "perf-hot", "owner": "B", "match": {"metric": "*"}}]})
        series = alerts.SeriesInfo(1, "k", "s", "panes.x.frame", "chromium", "h", 26, "bench", "ms", "lower")
        self.assertEqual(subscriptions.match(series).owner, "A")

    def test_bad_entries_are_refused(self) -> None:
        bad = [
            {"name": "x", "kind": "nope", "owner": "A", "match": {"metric": "*"}},
            {"name": "x", "kind": "perf-hot", "owner": "", "match": {"metric": "*"}},
            {"name": "x", "kind": "perf-hot", "owner": "A", "match": {"sha": "*"}},
            {"name": "x", "kind": "perf-hot", "owner": "A", "match": {"metric": "*"}, "targets": ["t"]},
            {"name": "x", "kind": "perf-hot", "owner": "A", "match": {"metric": "*"},
             "anomaly_config": {"min_relative_change": "0.2"}},
            {"name": "x", "kind": "perf-hot", "owner": "A", "match": {"metric": "*"},
             "anomaly_config": {"threshold": 0.2}},
        ]
        for config in ({"max_window_size": 40.5}, {"max_window_size": 0}, {"min_segment_size": -1},
                       {"min_segment_size": 6.2}):
            bad.append({"name": "x", "kind": "perf-hot", "owner": "A", "match": {"metric": "*"},
                        "anomaly_config": config})
        for entry in bad:
            with self.subTest(entry=entry), self.assertRaises(alerts.AlertsError):
                alerts.Subscriptions.parse({"build_configs": ["bench"], "subscriptions": [entry]})

    def test_whole_float_counts_become_ints_the_real_detector_takes(self) -> None:
        entry, = alerts.Subscriptions.parse({"build_configs": ["bench"], "subscriptions": [
            {"name": "x", "kind": "perf-hot", "owner": "A", "match": {"metric": "*"},
             "anomaly_config": {"max_window_size": 40.0, "min_segment_size": 6.0, "min_relative_change": 0.1}}]}).entries
        self.assertEqual(entry.anomaly_config, {"max_window_size": 40, "min_segment_size": 6, "min_relative_change": 0.1})
        self.assertIsInstance(entry.anomaly_config["max_window_size"], int)
        change, = alerts.CatapultDetector().change_points(step(100.0, 120.0, 20, 12), entry.anomaly_config)
        self.assertEqual((change.median_before, change.median_after), (100.0, 120.0))

    def test_anomaly_config_override_reaches_the_detector(self) -> None:
        seen = []

        class Recording(StepDetector):
            def change_points(self, values, config):
                seen.append((len(values), dict(config)))
                return []

        with tempfile.TemporaryDirectory() as tmp:
            lab = store_mod.Store(Path(tmp) / "lab.sqlite", clock=lambda: NOW)
            lab.migrate()
            for pos in range(30):
                run = store_mod.Run(run_uuid=f"r{pos}", kind="waterfall", measure_version="1", story="split-spring",
                                    engine="chromium", macos_major=26, macos_build="b", features_hash="f",
                                    safe_mode="off", started_at=NOW)
                lab.insert_run(run, build=store_mod.Build(sha=f"{pos:040x}", config="bench", commit_pos=pos),
                               host=HOST, metrics=[store_mod.Metric("panes.split.frame", "ms", "lower", [1.0])])
            subscriptions = alerts.Subscriptions.parse({"build_configs": ["bench"], "subscriptions": [
                {"name": "p", "kind": "perf-hot", "owner": "A", "match": {"metric": "panes.*"},
                 "anomaly_config": {"max_window_size": 20, "min_relative_change": 0.2}}]})
            alerts.detect(lab, subscriptions, Recording(), TARGETS)
            lab.close()
        self.assertEqual(seen, [(20, {"max_window_size": 20, "min_relative_change": 0.2})])

    def test_row_floor_is_min_absolute_change_and_an_override_only_raises_it(self) -> None:
        seen = []

        class Recording(StepDetector):
            def change_points(self, values, config):
                seen.append(config.get("min_absolute_change"))
                return []

        with tempfile.TemporaryDirectory() as tmp:
            lab = store_mod.Store(Path(tmp) / "lab.sqlite", clock=lambda: NOW)
            lab.migrate()
            for story in ("floored", "plain"):
                run = store_mod.Run(run_uuid=f"r-{story}", kind="waterfall", measure_version="1", story=story,
                                    engine="chromium", macos_major=26, macos_build="b", features_hash="f",
                                    safe_mode="off", started_at=NOW)
                lab.insert_run(run, build=store_mod.Build(sha="f" * 40, config="bench", commit_pos=1),
                               host=HOST, metrics=[store_mod.Metric("panes.split.frame", "ms", "lower", [1.0])])

            def floors(series):
                return 1.0 if series.story == "floored" else None

            for override, expected in ((None, [1.0, None]), (0.2, [1.0, 0.2]), (3.0, [3.0, 3.0])):
                config = {} if override is None else {"min_absolute_change": override}
                subscriptions = alerts.Subscriptions.parse({"build_configs": ["bench"], "subscriptions": [
                    {"name": "p", "kind": "perf-hot", "owner": "A", "match": {"metric": "panes.*"},
                     "anomaly_config": config}]})
                seen.clear()
                alerts.detect(lab, subscriptions, Recording(), TARGETS, floors=floors)
                with self.subTest(override=override):
                    self.assertEqual(sorted(seen, key=str), sorted(expected, key=str))
            lab.close()

    def test_load_floors_resolves_the_catalog_floor_refs(self) -> None:
        # stories.d/motion.json cmd_n floor_ref "/rows/cmd_n\\..*/floor"; home-idle.json idle app CPU.
        budgets = json.loads((alerts.REPO_ROOT / "scripts" / "cmux-next" / "perf-budgets.json").read_text())["rows"]
        floors = alerts.load_floors()

        def series(story, metric):
            return alerts.SeriesInfo(1, "k", story, metric, "none", "h", 26, "bench", "ms", "lower")

        self.assertEqual(floors(series("motion", "cmd_n.light.key_to_visible")), budgets["cmd_n\\..*"]["floor"])
        self.assertEqual(floors(series("home-idle", "idle.light.app_cpu_pct")),
                         budgets["idle\\..*\\.app_cpu_pct"]["floor"])
        self.assertIsNone(floors(series("motion", "not.a.catalog.metric")))
        self.assertIsNone(floors(series("no-such-story", "cmd_n.light.key_to_visible")))


class CatapultDetectorTests(unittest.TestCase):
    def test_adapter_maps_catapult_change_points_and_negates_higher_is_better(self) -> None:
        calls = []
        fake = types.ModuleType("perf_lab_anomaly")
        fake.find_change_points = lambda series, **config: (calls.append((series, config)) or [
            types.SimpleNamespace(x_value=8, extended_start=7, extended_end=9, median_before=1.0, median_after=2.0)])
        fake.target_miss = lambda values, target: calls.append((values, target)) or types.SimpleNamespace(x_value=1)
        previous = sys.modules.get("perf_lab_anomaly")
        sys.modules["perf_lab_anomaly"] = fake
        try:
            detector = alerts.CatapultDetector()
            change, = detector.change_points([1.0, 2.0], {"min_segment_size": 6})
            self.assertEqual(change, alerts.ChangePoint(7, 9, 1.0, 2.0))
            self.assertEqual(calls[0], ([(0, 1.0), (1, 2.0)], {"min_segment_size": 6}))
            self.assertEqual(detector.target_miss([1.0, 0.5], 0.9, "higher"), 1)
            self.assertEqual(calls[1], ([-1.0, -0.5], -0.9))
        finally:
            if previous is None:
                sys.modules.pop("perf_lab_anomaly")
            else:
                sys.modules["perf_lab_anomaly"] = previous


class CliTests(LabFixture):
    def run_cli(self, *argv, github=None) -> tuple[int, dict | list | str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = alerts.main(list(argv), detector=StepDetector(), github=github)
        text = out.getvalue()
        try:
            return code, json.loads(text)
        except json.JSONDecodeError:
            return code, text

    def test_dry_run_detect_writes_nothing(self) -> None:
        self.add_series(story="terminal-key-to-frame-light", metric="key_to_frame_ms",
                        values=step(6.0, 7.5), positions=list(range(16)))
        self.store.close()
        code, report = self.run_cli("detect", "--db", str(self.db_path), "--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual((report["dry_run"], report["alerts"], len(report["groups_created"])), (True, 1, 1))
        self.store = store_mod.Store(self.db_path)
        self.assertEqual(self.groups(), [])
        code, report = self.run_cli("detect", "--db", str(self.db_path))
        self.assertEqual((code, report["alerts"]), (0, 1))
        self.assertEqual(len(self.groups()), 1)

    def test_dry_run_sync_prints_writes_and_stores_no_issue_number(self) -> None:
        self.add_series(story="terminal-key-to-frame-light", metric="key_to_frame_ms",
                        values=step(6.0, 7.5), positions=list(range(16)))
        self.detect()
        self.verify(self.groups()[0]["id"], "ab" * 20)
        github = FakeGitHub()
        code, report = self.run_cli("sync-issues", "--db", str(self.db_path), "--dashboard-url", DASH, "--dry-run",
                                    github=github)
        self.assertEqual(code, 0)
        self.assertEqual([action["action"] for action in report["actions"]], ["create", "comment"])
        self.assertEqual(github.issues, {})
        self.assertIsNone(self.groups()[0]["issue_number"])

    def test_groups_json_and_check_subscriptions(self) -> None:
        self.add_series(story="terminal-key-to-frame-light", metric="key_to_frame_ms",
                        values=step(6.0, 7.5), positions=list(range(16)))
        self.detect()
        code, groups = self.run_cli("groups", "--db", str(self.db_path), "--state", "new,triaged,culprit", "--json")
        self.assertEqual(code, 0)
        self.assertEqual([group["state"] for group in groups], ["new"])
        code, text = self.run_cli("check-subscriptions")
        self.assertEqual(code, 0)
        self.assertIn("subscriptions ok", text)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Fixture tests for scripts/ci/ci_health_report.py (no network).

Every number the report publishes is computed by a pure function over JSON the
GitHub client already fetched, so the tests feed it recorded Actions payloads
from tests/fixtures/ci-health-report/ and assert the arithmetic, the waste
patterns, the sampling policy, and the issue-comment write path -- the last one
against a fake client, because the real one is the only part that talks to the
network and it is deliberately not exercised here.
"""

from __future__ import annotations

import datetime as dt
import importlib.util
import json
import sys
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/ci_health_report.py"
WORKFLOW = ROOT / ".github/workflows/ci-health-report.yml"
DOC = ROOT / "docs/ci/health-report.md"
FIXTURES = ROOT / "tests/fixtures/ci-health-report"

SPEC = importlib.util.spec_from_file_location("ci_health_report", SCRIPT)
report = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["ci_health_report"] = report
SPEC.loader.exec_module(report)

NOW = dt.datetime(2026, 9, 22, 18, 0, tzinfo=dt.timezone.utc)
REPO = "manaflow-ai/cmux"
MAC = "blacksmith-6vcpu-macos-15"
LINUX = "blacksmith-4vcpu-ubuntu-2404"


def load(name: str) -> dict[str, Any]:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def rows_from(fixture: dict[str, Any]) -> list[Any]:
    by_id = {str(run["id"]): run for run in fixture["runs"]}
    rows: list[Any] = []
    for run_id, jobs in fixture["jobs"].items():
        rows.extend(report.job_rows(by_id[run_id], jobs, REPO))
    return rows


def metrics_from(fixture: dict[str, Any], window: Any, partial: tuple[str, ...] = ()) -> Any:
    rows = rows_from(fixture)
    return report.build_metrics(
        window=window,
        runs=fixture["runs"],
        rows=rows,
        sampled_runs=len(fixture["jobs"]),
        partial=partial,
    )


CURRENT_WINDOW, PREVIOUS_WINDOW = report.windows(NOW, 6)


class JobRowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = load("window.json")
        self.rows = rows_from(self.fixture)

    def test_minutes_come_from_started_to_completed(self):
        cancelled = next(row for row in self.rows if row.run_id == 1001 and row.macos)
        self.assertAlmostEqual(cancelled.minutes, 42.0)
        self.assertEqual(cancelled.bucket, "cancelled")

    def test_queue_wait_is_created_to_started(self):
        cancelled = next(row for row in self.rows if row.run_id == 1001 and row.macos)
        self.assertAlmostEqual(cancelled.queue_seconds, 50 * 60)

    def test_a_job_that_never_started_has_no_wait_and_no_minutes(self):
        skipped = next(row for row in self.rows if row.run_id == 1007)
        self.assertIsNone(skipped.queue_seconds)
        self.assertEqual(skipped.minutes, 0.0)
        self.assertEqual(skipped.bucket, "skipped")

    def test_fork_head_repository_marks_the_row(self):
        fork = next(row for row in self.rows if row.run_id == 1013)
        self.assertTrue(fork.fork)
        self.assertFalse(next(row for row in self.rows if row.run_id == 1002).fork)

    def test_timed_out_and_startup_failure_count_as_failure_minutes(self):
        self.assertEqual(report.bucket_of("timed_out"), "failure")
        self.assertEqual(report.bucket_of("startup_failure"), "failure")
        self.assertEqual(report.bucket_of("neutral"), "other")

    def test_multiple_labels_stay_one_distinguishable_pool(self):
        label = report.runner_label({"labels": ["self-hosted", "macos"]})
        self.assertEqual(label, "macos+self-hosted")
        self.assertNotEqual(label, report.runner_label({"labels": ["macos"]}))

    def test_a_per_run_dispatch_name_does_not_split_a_workflow(self):
        # cmux's focused-test dispatches name each run after the test class,
        # runner and SHA, which grouped by run name buries the real cost.
        runs = [
            {"path": ".github/workflows/dispatch-focused-test.yml",
             "name": "cmuxTests/FooTests on blacksmith-6vcpu-macos-15 @ abc123 [branch-a]"},
            {"path": ".github/workflows/dispatch-focused-test.yml",
             "name": "cmuxTests/BarTests on blacksmith-6vcpu-macos-15 @ def456 [branch-b]"},
        ]
        self.assertEqual(
            {report.workflow_name(run) for run in runs}, {"dispatch-focused-test.yml"}
        )

    def test_a_job_with_no_labels_does_not_crash_the_report(self):
        self.assertEqual(report.runner_label({}), "unknown")


class MinutesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.rows = rows_from(load("window.json"))

    def test_minutes_by_workflow_split_by_conclusion(self):
        cells = report.aggregate_minutes(self.rows, lambda row: row.workflow)
        ci = cells["ci.yml"]
        self.assertAlmostEqual(ci.minutes["cancelled"], 42.0)
        self.assertAlmostEqual(ci.minutes["failure"], 90.0)
        self.assertAlmostEqual(ci.minutes["success"], 92.0)
        self.assertAlmostEqual(cells["nightly.yml"].total, 58.0)

    def test_minutes_by_job_and_by_label_agree_on_the_total(self):
        by_job = report.aggregate_minutes(self.rows, lambda row: (row.workflow, row.job))
        by_label = report.aggregate_minutes(self.rows, lambda row: row.label)
        self.assertAlmostEqual(
            sum(cell.total for cell in by_job.values()),
            sum(cell.total for cell in by_label.values()),
        )
        self.assertAlmostEqual(by_label[LINUX].total, 2.0)
        self.assertAlmostEqual(by_label[MAC].total, 280.0)

    def test_top_cells_orders_by_minutes_burned(self):
        top = report.top_cells(report.aggregate_minutes(self.rows, lambda row: row.workflow), 2)
        self.assertEqual([key for key, _ in top], ["ci.yml", "nightly.yml"])

    def test_run_conclusions_are_counted_per_bucket(self):
        counts = report.count_by_bucket(load("window.json")["runs"])
        self.assertEqual(counts["skipped"], 6)
        self.assertEqual(counts["failure"], 3)
        self.assertEqual(counts["cancelled"], 1)
        self.assertEqual(counts["success"], 3)

    def test_an_unfinished_run_is_not_counted_as_a_conclusion(self):
        counts = report.count_by_bucket([{"status": "in_progress"}, {"status": "queued"}])
        self.assertEqual(counts["other"], 2)
        self.assertEqual(counts["success"], 0)


class QueueWaitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.stats = report.queue_wait_stats(rows_from(load("window.json")))
        self.mac = next(item for item in self.stats if item.label == MAC)

    def test_percentiles_are_nearest_rank_over_the_sampled_waits(self):
        # Waits in minutes: 2, 5, 10, 20, 50, 70, 70.
        self.assertEqual(self.mac.jobs, 7)
        self.assertAlmostEqual(self.mac.p50, 20.0)
        self.assertAlmostEqual(self.mac.p90, 70.0)
        self.assertAlmostEqual(self.mac.worst, 70.0)

    def test_a_capped_pool_trips_the_queue_threshold(self):
        self.assertTrue(self.mac.alerting)
        self.assertTrue(self.mac.macos)
        self.assertAlmostEqual(report.macos_queue_p90(self.stats), 70.0)

    def test_a_linux_pool_that_schedules_immediately_does_not_alert(self):
        linux = next(item for item in self.stats if item.label == LINUX)
        self.assertFalse(linux.alerting)
        self.assertFalse(linux.macos)

    def test_percentile_edges(self):
        self.assertEqual(report.percentile([], 90), 0.0)
        self.assertEqual(report.percentile([7.0], 50), 7.0)
        self.assertEqual(report.percentile([1.0, 2.0], 100), 2.0)

    def test_labels_are_ordered_worst_p90_first(self):
        self.assertEqual(self.stats[0].label, MAC)


class WastePatternTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = load("window.json")
        self.rows = rows_from(self.fixture)

    def test_cancelled_after_real_macos_work_is_reported_with_its_minutes(self):
        waste = report.cancelled_macos_waste(self.rows)
        self.assertEqual(len(waste), 1)
        self.assertEqual(waste[0].job, "macOS / app-host tests")
        self.assertAlmostEqual(waste[0].minutes, 42.0)

    def test_a_cancel_before_the_threshold_is_not_waste(self):
        self.assertEqual(report.cancelled_macos_waste(self.rows, threshold_minutes=60.0), [])

    def test_a_cancelled_linux_job_is_not_macos_waste(self):
        linux_cancel = report.job_rows(
            self.fixture["runs"][0],
            [{
                "name": "web", "labels": [LINUX], "status": "completed", "conclusion": "cancelled",
                "created_at": "2026-09-22T16:00:00Z", "started_at": "2026-09-22T16:00:00Z",
                "completed_at": "2026-09-22T17:00:00Z",
            }],
            REPO,
        )
        self.assertEqual(report.cancelled_macos_waste(linux_cancel), [])

    def test_one_job_failing_across_unrelated_heads_is_a_main_broken_signal(self):
        repeated = report.repeated_job_failures(self.rows)
        self.assertEqual(len(repeated), 1)
        self.assertEqual(repeated[0].heads, 3)
        self.assertEqual(repeated[0].failures, 3)
        self.assertEqual(repeated[0].job, "macOS / app-host tests")

    def test_one_pull_request_failing_repeatedly_is_not_a_main_signal(self):
        one_head = [row for row in self.rows if row.head_sha == "bbb2bbb2bbb2"] * 5
        self.assertEqual(report.repeated_job_failures(one_head), [])

    def test_a_workflow_whose_runs_are_all_skipped_is_surfaced(self):
        skipped = report.mostly_skipped_workflows(self.fixture["runs"], min_runs=5)
        self.assertEqual([item.workflow for item in skipped], ["docs-channels.yml"])
        self.assertEqual(skipped[0].runs, 6)
        self.assertAlmostEqual(skipped[0].ratio, 1.0)

    def test_a_busy_workflow_that_actually_runs_is_not_surfaced(self):
        self.assertNotIn(
            "ci.yml",
            [item.workflow for item in report.mostly_skipped_workflows(self.fixture["runs"], min_runs=1)],
        )

    def test_a_rare_workflow_is_not_surfaced_on_a_thin_sample(self):
        self.assertEqual(report.mostly_skipped_workflows(self.fixture["runs"]), [])

    def test_both_shapes_of_unchanged_tree_rerun_are_counted(self):
        reruns = {(item.workflow, item.head_sha): item for item in report.unchanged_tree_reruns(self.fixture["runs"])}
        second_run = reruns[("ci.yml", "aaa1aaa1aaa1")]
        self.assertEqual((second_run.runs, second_run.retries), (2, 0))
        attempt = reruns[("nightly.yml", "eee5eee5eee5")]
        self.assertEqual((attempt.runs, attempt.retries), (1, 1))

    def test_two_triggers_over_one_head_are_distinguishable_rows(self):
        # The event is part of the grouping key, so without it in the output
        # two different triggers render as duplicate-looking rows.
        runs = [
            dict(self.fixture["runs"][0], id=2001, event="issue_comment"),
            dict(self.fixture["runs"][0], id=2002, event="issue_comment"),
            dict(self.fixture["runs"][0], id=2003, event="pull_request"),
            dict(self.fixture["runs"][0], id=2004, event="pull_request"),
        ]
        events = {item.event for item in report.unchanged_tree_reruns(runs)}
        self.assertEqual(events, {"issue_comment", "pull_request"})

    def test_a_single_first_attempt_run_is_not_a_rerun(self):
        keys = {(item.workflow, item.head_sha) for item in report.unchanged_tree_reruns(self.fixture["runs"])}
        self.assertNotIn(("ci.yml", "bbb2bbb2bbb2"), keys)

    def test_fork_jobs_and_their_uncached_minutes_are_totalled(self):
        jobs, minutes = report.fork_runs_without_cache(self.rows)
        self.assertEqual(jobs, 1)
        self.assertAlmostEqual(minutes, 60.0)


class SamplingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.runs = load("window.json")["runs"]

    def test_the_sample_spreads_across_workflows_rather_than_down_one(self):
        chosen = report.choose_job_runs(self.runs, per_workflow=2, total_cap=4)
        names = [report.workflow_name(run) for run in chosen]
        self.assertGreaterEqual(len(set(names)), 3)
        self.assertEqual(len(chosen), 4)

    def test_macos_capable_workflows_are_sampled_first(self):
        linux_only = frozenset({".github/workflows/docs-channels.yml"})
        chosen = report.choose_job_runs(
            self.runs, per_workflow=1, total_cap=2, linux_only_paths=linux_only
        )
        self.assertNotIn("docs-channels.yml", [report.workflow_name(run) for run in chosen])

    def test_the_total_cap_is_never_exceeded(self):
        self.assertEqual(len(report.choose_job_runs(self.runs, per_workflow=9, total_cap=3)), 3)
        self.assertEqual(report.choose_job_runs(self.runs, per_workflow=3, total_cap=0), [])

    def test_unfinished_runs_are_not_worth_a_job_listing(self):
        pending = [dict(run, status="in_progress", conclusion=None) for run in self.runs]
        self.assertEqual(report.choose_job_runs(pending, per_workflow=3, total_cap=10), [])

    def test_evenly_spaced_is_deterministic_and_covers_the_range(self):
        self.assertEqual(report.evenly_spaced([1, 2, 3, 4, 5, 6], 3), [1, 3, 5])
        self.assertEqual(report.evenly_spaced([1, 2], 5), [1, 2])
        self.assertEqual(report.evenly_spaced([], 3), [])


class WindowMetricTests(unittest.TestCase):
    def setUp(self) -> None:
        self.current = metrics_from(load("window.json"), CURRENT_WINDOW)
        self.previous = metrics_from(load("previous-window.json"), PREVIOUS_WINDOW)

    def test_a_window_covered_to_its_start_is_not_marked_truncated(self):
        self.assertFalse(self.current.truncated)
        self.assertAlmostEqual(self.current.covered_hours, 6.0)

    def test_a_page_capped_window_reports_only_the_span_it_covers(self):
        wide = report.Window(NOW - dt.timedelta(hours=24), NOW)
        capped = metrics_from(load("window.json"), wide)
        self.assertTrue(capped.truncated)
        self.assertAlmostEqual(capped.covered_hours, 6.0)
        self.assertGreater(capped.runs_per_hour, 0)

    def test_shares_are_over_the_runs_actually_fetched(self):
        self.assertAlmostEqual(self.current.cancelled_share, 1 / 13)
        self.assertAlmostEqual(self.current.skipped_share, 6 / 13)
        self.assertAlmostEqual(self.current.failure_share, 3 / 13)

    def test_the_comparison_surfaces_the_queue_regression(self):
        rows = {row.metric: row for row in report.compare(self.current, self.previous)}
        queue = rows["macOS queue wait p90 (min)"]
        self.assertEqual(queue.current, "70.0")
        self.assertEqual(queue.previous, "5.0")
        self.assertEqual(queue.change, "+65.0")
        self.assertTrue(queue.alerting)

    def test_a_missing_baseline_reads_as_not_available_rather_than_zero(self):
        empty = report.build_metrics(
            window=PREVIOUS_WINDOW, runs=[], rows=[], sampled_runs=0, partial=()
        )
        rows = {row.metric: row for row in report.compare(self.current, empty)}
        self.assertEqual(rows["macOS queue wait p90 (min)"].previous, "n/a")
        self.assertEqual(rows["macOS queue wait p90 (min)"].change, "n/a")

    def test_windows_are_adjacent_and_equal_length(self):
        self.assertEqual(CURRENT_WINDOW.start, PREVIOUS_WINDOW.end)
        self.assertAlmostEqual(CURRENT_WINDOW.hours, PREVIOUS_WINDOW.hours)
        self.assertIn("..", CURRENT_WINDOW.query())


class SliceTests(unittest.TestCase):
    """A `created:` query caps at 1000 runs, so a busy window must be asked for in pieces."""

    def test_slices_are_contiguous_newest_first_and_cover_the_window(self):
        pieces = report.slice_windows(CURRENT_WINDOW, 4)
        self.assertEqual(len(pieces), 4)
        self.assertEqual(pieces[0].end, CURRENT_WINDOW.end)
        self.assertEqual(pieces[-1].start, CURRENT_WINDOW.start)
        for newer, older in zip(pieces, pieces[1:]):
            self.assertEqual(newer.start, older.end)
        self.assertAlmostEqual(sum(piece.hours for piece in pieces), CURRENT_WINDOW.hours)

    def test_one_slice_is_the_whole_window(self):
        self.assertEqual(report.slice_windows(CURRENT_WINDOW, 1), [CURRENT_WINDOW])
        self.assertEqual(report.slice_windows(CURRENT_WINDOW, 0), [CURRENT_WINDOW])

    def test_the_default_slices_are_half_hours(self):
        # An hourly slice hit the 1000-run cap in 22 of 24 measured hours.
        self.assertEqual(report.auto_slices(6), 12)
        self.assertEqual(report.auto_slices(24), 48)
        self.assertEqual(report.auto_slices(1), 2)
        # The cap keeps a long window from turning into hundreds of queries.
        self.assertEqual(report.auto_slices(500), report.MAX_WINDOW_SLICES)

    def test_complete_slices_cover_the_whole_window(self):
        pieces = report.slice_windows(CURRENT_WINDOW, 3)
        results = [report.SliceResult(window=piece, runs=[], capped=False) for piece in pieces]
        hours, truncated = report.slice_coverage(results)
        self.assertAlmostEqual(hours, CURRENT_WINDOW.hours)
        self.assertFalse(truncated)

    def test_a_capped_slice_only_counts_back_to_its_oldest_run(self):
        pieces = report.slice_windows(CURRENT_WINDOW, 2)
        newest, oldest = pieces
        # The newer slice stopped at 17:00, an hour into its three-hour span.
        capped_runs = [{"created_at": "2026-09-22T17:00:00Z"}]
        results = [
            report.SliceResult(window=newest, runs=capped_runs, capped=True),
            report.SliceResult(window=oldest, runs=[], capped=False),
        ]
        hours, truncated = report.slice_coverage(results)
        self.assertTrue(truncated)
        self.assertAlmostEqual(hours, 1.0 + oldest.hours)

    def test_metrics_take_truncation_from_the_slices_not_the_oldest_run(self):
        fixture = load("window.json")
        pieces = report.slice_windows(CURRENT_WINDOW, 2)
        newer = [run for run in fixture["runs"] if run["created_at"] >= "2026-09-22T16:00:00Z"]
        metrics = report.build_metrics(
            window=CURRENT_WINDOW,
            runs=fixture["runs"],
            rows=rows_from(fixture),
            sampled_runs=1,
            partial=(),
            slices=[
                # The newer slice hit the cap at 16:00 and never reached 15:00.
                report.SliceResult(window=pieces[0], runs=newer, capped=True),
                report.SliceResult(window=pieces[1], runs=[], capped=False),
            ],
        )
        # The oldest fetched run reaches the window start, so the pre-slicing
        # check would have called this fully covered.
        self.assertTrue(metrics.truncated)
        self.assertLess(metrics.covered_hours, CURRENT_WINDOW.hours)


class RenderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.current = metrics_from(load("window.json"), CURRENT_WINDOW)
        self.previous = metrics_from(load("previous-window.json"), PREVIOUS_WINDOW)
        self.text = report.render_report(
            self.current, self.previous, repo=REPO, now=NOW, api_calls=42
        )

    def test_every_section_the_report_promises_is_present(self):
        for heading in (
            "### Headline vs previous window",
            "### Run conclusions",
            "### Runner minutes by workflow (sampled)",
            "### Runner minutes by job (sampled)",
            "### Runner minutes by runner label (sampled)",
            "### Queue wait, created → started (sampled)",
            "### Wasteful patterns",
        ):
            self.assertIn(heading, self.text)

    def test_the_call_count_is_stated(self):
        self.assertIn("42 API calls, nothing cached", self.text)

    def test_the_waste_patterns_reach_the_output(self):
        self.assertIn("docs-channels.yml", self.text)
        self.assertIn("macOS / app-host tests", self.text)
        self.assertIn("Reruns of an unchanged tree", self.text)
        self.assertIn("Fork pull requests (no cache access):", self.text)

    def test_partial_data_is_announced_instead_of_failing(self):
        partial = metrics_from(load("window.json"), CURRENT_WINDOW, partial=("rate limited on runs",))
        text = report.render_report(partial, self.previous, repo=REPO, now=NOW, api_calls=7)
        self.assertIn("**Partial data.**", text)
        self.assertIn("rate limited on runs", text)

    def test_a_repeated_partial_reason_is_counted_not_repeated(self):
        banner = report.summarize_partial(
            [report.CAPPED_SLICE_REASON] * 22, [report.CAPPED_SLICE_REASON, "rate limited"]
        )
        self.assertEqual(banner.count(report.CAPPED_SLICE_REASON), 1)
        self.assertIn("(23 slices)", banner)
        self.assertIn("rate limited", banner)

    def test_a_pipe_in_a_job_name_cannot_break_the_table(self):
        rows = report.job_rows(
            load("window.json")["runs"][0],
            [{
                "name": "web | lint", "labels": [LINUX], "status": "completed", "conclusion": "success",
                "created_at": "2026-09-22T16:00:00Z", "started_at": "2026-09-22T16:00:00Z",
                "completed_at": "2026-09-22T16:10:00Z",
            }],
            REPO,
        )
        metrics = report.build_metrics(
            window=CURRENT_WINDOW, runs=load("window.json")["runs"], rows=rows, sampled_runs=1, partial=()
        )
        self.assertIn("web \\| lint", report.render_report(metrics, self.previous, repo=REPO, now=NOW, api_calls=1))

    def test_the_report_says_it_only_measures(self):
        self.assertIn("only measures", self.text)
        self.assertIn("queue_janitor.py", self.text)


class FakeGitHub:
    """Stands in for the real client so the write path is tested without network."""

    def __init__(self, *, title: str, comments: list[dict[str, Any]]) -> None:
        self._title = title
        self._comments = comments
        self.created: list[str] = []
        self.updated: list[tuple[int, str]] = []

    def issue(self, number: int) -> dict[str, Any]:
        return {"number": number, "title": self._title}

    def issue_comments(self, number: int) -> list[dict[str, Any]]:
        return self._comments

    def create_comment(self, number: int, body: str) -> None:
        self.created.append(body)

    def update_comment(self, comment_id: int, body: str) -> None:
        self.updated.append((comment_id, body))


class IssueSectionTests(unittest.TestCase):
    def test_only_the_generated_section_is_replaced(self):
        body = (
            "Keep this note.\n\n"
            f"{report.START_MARKER}\nold report\n{report.END_MARKER}\n\n"
            "And this one."
        )
        updated = report.replace_generated(body, "new report")
        self.assertIn("Keep this note.", updated)
        self.assertIn("And this one.", updated)
        self.assertIn("new report", updated)
        self.assertNotIn("old report", updated)

    def test_a_body_without_exactly_one_marker_pair_is_refused(self):
        with self.assertRaises(ValueError):
            report.replace_generated("no markers here", "x")
        with self.assertRaises(ValueError):
            report.replace_generated(
                f"{report.START_MARKER}{report.START_MARKER}{report.END_MARKER}", "x"
            )

    def test_the_report_comment_is_found_by_its_markers(self):
        comments = [
            {"id": 1, "body": "unrelated human comment"},
            {"id": 2, "body": f"{report.START_MARKER}\nreport\n{report.END_MARKER}"},
        ]
        self.assertEqual(report.find_report_comment(comments)["id"], 2)
        self.assertIsNone(report.find_report_comment([{"id": 1, "body": "nothing"}]))

    def test_a_first_run_posts_one_comment_carrying_the_markers(self):
        client = FakeGitHub(title="[CI Health] CI health report", comments=[])
        result = report.publish_to_issue(client, 4242, "generated body")
        self.assertIn("posted a new report comment", result)
        self.assertEqual(len(client.created), 1)
        self.assertIn(report.START_MARKER, client.created[0])
        self.assertIn("generated body", client.created[0])

    def test_a_later_run_updates_that_same_comment_in_place(self):
        existing = {"id": 77, "body": f"human note\n{report.START_MARKER}\nold\n{report.END_MARKER}"}
        client = FakeGitHub(title="[CI Health] CI health report", comments=[existing])
        report.publish_to_issue(client, 4242, "fresh")
        self.assertEqual(client.created, [])
        self.assertEqual(client.updated[0][0], 77)
        self.assertIn("human note", client.updated[0][1])
        self.assertIn("fresh", client.updated[0][1])

    def test_an_unchanged_report_does_not_rewrite_the_comment(self):
        body = report.new_comment_body("same")
        client = FakeGitHub(title="[CI Health] CI health report", comments=[{"id": 9, "body": body}])
        self.assertIn("already current", report.publish_to_issue(client, 4242, "same"))
        self.assertEqual(client.updated, [])

    def test_writing_to_an_issue_that_is_not_the_tracking_issue_is_refused(self):
        client = FakeGitHub(title="Crash on launch", comments=[])
        with self.assertRaises(RuntimeError):
            report.publish_to_issue(client, 13369, "generated")
        self.assertEqual(client.created, [])


class WorkflowStructureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def test_it_runs_every_six_hours_and_on_demand(self):
        self.assertIn("schedule:", self.text)
        self.assertIn('- cron: "37 2,8,14,20 * * *"', self.text)
        self.assertIn("workflow_dispatch:", self.text)

    def test_the_runner_comes_from_a_repository_variable(self):
        self.assertIn(
            "runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}", self.text
        )

    def test_it_can_read_runs_and_write_issue_comments_but_not_cancel(self):
        self.assertIn("permissions:\n  actions: read\n  issues: write\n  contents: read\n", self.text)
        self.assertNotIn("actions: write", self.text)

    def test_comment_refreshes_are_serialized(self):
        self.assertIn("concurrency:\n  group: ci-health-report\n  cancel-in-progress: false\n", self.text)

    def test_the_tracking_issue_and_caps_come_from_repository_variables(self):
        self.assertIn("vars.CI_HEALTH_REPORT_ISSUE", self.text)
        self.assertIn("vars.CI_HEALTH_MAX_RUN_PAGES", self.text)
        self.assertIn("vars.CI_HEALTH_MAX_JOB_LISTINGS", self.text)

    def test_it_runs_the_script_from_a_credential_free_checkout(self):
        self.assertIn("run: python3 scripts/ci/ci_health_report.py", self.text)
        self.assertIn("persist-credentials: false", self.text)

    def test_skipping_the_issue_clears_the_number_rather_than_passing_it(self):
        # `a && b || c` yields c whenever b is falsy, so `skip_issue && '' || vars`
        # would have published on exactly the dispatch that asked not to.
        self.assertIn(
            "${{ (inputs.skip_issue != true) && vars.CI_HEALTH_REPORT_ISSUE || '' }}", self.text
        )
        self.assertNotIn("inputs.skip_issue && ''", self.text)

    def test_it_allows_enough_time_for_a_few_hundred_api_calls(self):
        self.assertIn("timeout-minutes: 30", self.text)

    def test_it_never_opens_an_issue(self):
        self.assertNotIn("create-issue", self.text)
        self.assertIn("No issue is ever opened automatically", self.text)


class DocumentationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.text = DOC.read_text(encoding="utf-8")

    def test_every_action_threshold_the_script_uses_is_documented(self):
        self.assertIn(f"{report.QUEUE_P90_ALERT_MINUTES:.0f}", self.text)
        self.assertIn(f"{report.SKIPPED_WORKFLOW_RATIO * 100:.0f}%", self.text)
        self.assertIn(f"{report.CANCELLED_SHARE_ALERT * 100:.0f}%", self.text)
        self.assertIn(f"{report.FAILURE_SHARE_ALERT * 100:.0f}%", self.text)
        self.assertIn(str(report.REPEATED_FAILURE_MIN_HEADS), self.text)

    def test_it_says_which_variables_turn_the_issue_output_on(self):
        self.assertIn("CI_HEALTH_REPORT_ISSUE", self.text)
        self.assertIn(report.REPORT_TITLE_PREFIX, self.text)

    def test_it_draws_the_line_between_measuring_and_cancelling(self):
        self.assertIn("queue_janitor.py", self.text)

    def test_it_explains_the_capacity_reading_of_the_queue_metric(self):
        self.assertIn("capacity, not builds", self.text)


if __name__ == "__main__":
    unittest.main()

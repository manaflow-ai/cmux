#!/usr/bin/env python3
"""report.py: the weekly perf report is deterministic on a fixture store, and --append writes perf-lead.md 5.

  python3 -m unittest scripts/perf-lab/tests/test_report.py
"""
from __future__ import annotations

import argparse
import importlib.util
import io
import json
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent


def _load(name: str, filename: str):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, LAB / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


store = _load("perf_lab_store", "store.py")
catalog = _load("perf_lab_catalog", "catalog.py")
report = _load("perf_lab_report", "report.py")
lab = _load("perf_lab_lab", "lab.py")

NOW = datetime(2026, 10, 26, 12, 0, tzinfo=timezone.utc)
HOST = store.Host(name="cmux15", chip="Apple M4 Pro", memory_gb=24, display_hz=120, fingerprint="fp-15")
STORY = "terminal.key-frame.light"
KEY_FRAME_REF = json.dumps({"target": "key-frame.light"})
TARGETS = [
    catalog.Target("key-frame", "key->frame p50 <= 8.3 ms and p99 <= 16.7 ms", False, (
        catalog.Row("key-frame.light", "key-frame", (
            catalog.Check("terminal\\.key_to_frame", "p50", "<=", 8.3, "ms"),
            catalog.Check("terminal\\.key_to_frame", "p99", "<=", 16.7, "ms"),
        ), session="light", hz=120),
    )),
    catalog.Target("launch", "launch cold <= 300 ms", False, (
        catalog.Row("launch.cold", "launch", (catalog.Check("launch\\.cold", "p50", "<=", 300, "ms"),)),
    )),
]


def _stamp(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).isoformat(timespec="microseconds")


class NoChangePoints:
    def change_points(self, values, config):
        return []


def monitor_all(series):
    return {"min_relative_change": 0.1}


class Fixture:
    """A migrated store with a week of target points, alert groups and A/A pairs."""

    def __init__(self, directory: Path):
        self.path = directory / "lab.db"
        self.db = store.Store(self.path, clock=lambda: NOW)
        self.db.migrate()
        self.count = 0

    def close(self) -> None:
        self.db.close()

    def run(self, *, pos: int, at: datetime, samples, kind: str = "waterfall", metric: str = "terminal.key_to_frame",
            target_ref: str | None = KEY_FRAME_REF, sha: str | None = None, host: store.Host = HOST) -> None:
        self.count += 1
        run = store.Run(run_uuid=f"run-{self.count}", kind=kind, measure_version="m1", story=STORY, engine="none",
                        macos_major=26, macos_build="26.1", features_hash="f0", safe_mode="off", started_at=at,
                        tier="T0", session="light")
        self.db.insert_run(run, build=store.Build(sha=sha or f"{pos:040x}", config="bench", commit_pos=pos), host=host,
                           metrics=[store.Metric(name=metric, unit="ms", better="lower", samples=samples,
                                                 target_ref=target_ref)])

    def execute(self, sql: str, *args) -> int:
        db = sqlite3.connect(self.path)
        try:
            with db:
                return db.execute(sql, args).lastrowid
        finally:
            db.close()

    def group(self, opened: datetime, moves: list[tuple[str, timedelta, str | None]], *, culprit: str | None = None,
              verified: bool = False, issue: int | None = None) -> int:
        """A group with its creation row and one sheriff_history row per (state, offset from opened, reason)."""
        state, reason = (moves[-1][0], moves[-1][2]) if moves else ("new", None)
        gid = self.execute("INSERT INTO alert_groups (state, start_pos, end_pos, culprit_sha, culprit_verified, "
                           "issue_number, reason, created_at, updated_at) VALUES (?, 190, 200, ?, ?, ?, ?, ?, ?)",
                           state, culprit, int(verified), issue, reason, _stamp(opened), _stamp(opened))
        self.execute("INSERT INTO sheriff_history (group_id, from_state, to_state, actor, reason, at) "
                     "VALUES (?, NULL, 'new', 'perf-lab-alerts', 'alert', ?)", gid, _stamp(opened))
        previous = "new"
        for to_state, offset, why in moves:
            self.execute("INSERT INTO sheriff_history (group_id, from_state, to_state, actor, reason, at) "
                         "VALUES (?, ?, ?, 'sheriff-1', ?, ?)", gid, previous, to_state, why, _stamp(opened + offset))
            previous = to_state
        return gid

    def alert(self, group_id: int, at: datetime, *, improvement: bool = False, start: int = 190) -> None:
        series_id = self.db.list_series(story=STORY)[0]["id"]
        self.execute("INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, median_before, median_after, "
                     "is_improvement, created_at) VALUES (?, ?, 'edivisive', ?, 200, 5.0, 10.0, ?, ?)",
                     series_id, group_id, start, int(improvement), _stamp(at))


def build_fixture(directory: Path) -> Fixture:
    fixture = Fixture(directory)
    # Before the week: the target misses p50 (10 ms > 8.3 ms). In the week: a fix lands and it passes.
    fixture.run(pos=100, at=NOW - timedelta(days=9), samples=[10.0, 10.0, 10.0, 11.0])
    fixture.run(pos=150, at=NOW - timedelta(days=8), samples=[9.0, 9.0, 9.0, 12.0])
    fixture.run(pos=200, at=NOW - timedelta(days=1), samples=[5.0, 5.0, 6.0, 7.0])
    # A point after the week's end never shows (a clock skew or a run that started late).
    fixture.run(pos=210, at=NOW + timedelta(hours=1), samples=[50.0, 50.0])
    # A/A: one pair a night for 3 nights, each of one artifact on one host. key_to_frame is quiet; noisy's
    # medians move 20 % between the two runs of one artifact.
    for night in (1, 2, 3):
        sha = f"{night:040d}"
        start = NOW - timedelta(days=night, hours=3)
        for offset, quiet, noisy in ((0, [10.0, 10.4, 9.8, 10.1, 9.9], [5.0, 10.0, 15.0, 20.0, 8.0]),
                                     (10, [10.1, 9.9, 10.3, 10.0, 9.8], [6.0, 12.0, 18.0, 9.0, 14.0])):
            fixture.run(kind="aa", pos=300 + night, at=start + timedelta(minutes=offset), samples=quiet, sha=sha)
            fixture.run(kind="aa", pos=300 + night, at=start + timedelta(minutes=offset + 1), samples=noisy, sha=sha,
                        metric="terminal.noisy", target_ref=None)

    opened = NOW - timedelta(days=3)
    assigned = fixture.group(opened, [("triaged", timedelta(minutes=30), "real"),
                                      ("bisecting", timedelta(minutes=40), None),
                                      ("culprit", timedelta(hours=2), None),
                                      ("assigned", timedelta(hours=3), "owner PL-input")],
                             culprit="abcdef1234567890", verified=True, issue=4242)
    fixture.alert(assigned, opened)
    fixture.alert(assigned, opened, improvement=True, start=191)
    # Opened before the week, closed in it.
    old = NOW - timedelta(days=9)
    invalid = fixture.group(old, [("triaged", timedelta(minutes=20), "looked"),
                                  ("invalid", timedelta(days=4), "harness | flake")])
    fixture.alert(invalid, old, start=180)
    # Opened and triaged before the week and still open: in the report, with no move in the week.
    waiting = fixture.group(NOW - timedelta(days=12), [("triaged", timedelta(minutes=50), None)])
    fixture.alert(waiting, NOW - timedelta(days=12), start=160)
    # Opened and closed before the week: not in the report.
    fixture.group(old, [("invalid", timedelta(hours=1), "noise")])
    # Opened in the week and never triaged: misses the triage SLO and is stale.
    fresh = fixture.group(NOW - timedelta(days=1), [])
    fixture.alert(fresh, NOW - timedelta(days=1), start=170)
    return fixture


EXPECTED = """\
### Weekly perf report 2026-W44, 2026-10-19 12:00 to 2026-10-26 12:00 UTC

#### Targets

Checks at the end of the week: 3 (pass 2, no-data 1).

| Target | Row | Check | Series | Start | End |
|---|---|---|---|---|---|
| key-frame | key-frame.light | `terminal\\.key_to_frame` p50 <= 8.30 ms | terminal.key-frame.light terminal.key_to_frame on apple-m4-pro/24gb/120hz | 9 ms (miss) | 5.50 ms (pass) |
| key-frame | key-frame.light | `terminal\\.key_to_frame` p99 <= 16.7 ms | terminal.key-frame.light terminal.key_to_frame on apple-m4-pro/24gb/120hz | 11.9 ms (pass) | 6.97 ms (pass) |
| launch | launch.cold | `launch\\.cold` p50 <= 300 ms | - | - (no-data) | - (no-data) |

#### Alert groups

Groups opened, moved or open in the week: 4. State at the end: assigned 1, invalid 1, new 1, triaged 1. Closed in the week: invalid 1.

| Group | Opened | Stories | Range | Alerts | Moves in the week | State | Culprit | Issue | Reason |
|---|---|---|---|---|---|---|---|---|---|
| #3 | 2026-10-14 12:00 | terminal.key-frame.light | 190-200 | regressions 1, improvements 0 | - | triaged | - | - | - |
| #2 | 2026-10-17 12:00 | terminal.key-frame.light | 190-200 | regressions 1, improvements 0 | triaged -> invalid | invalid | - | - | harness \\| flake |
| #1 | 2026-10-23 12:00 | terminal.key-frame.light | 190-200 | regressions 1, improvements 1 | new -> triaged; triaged -> bisecting; bisecting -> culprit; culprit -> assigned | assigned | abcdef1234 (verified) | #4242 | owner PL-input |
| #5 | 2026-10-25 12:00 | terminal.key-frame.light | 190-200 | regressions 1, improvements 0 | - | new | - | - | - |

#### Sheriff SLO

Groups opened in the week: 2. FAIL.

| SLO | Result | Numbers |
|---|---|---|
| triage <= 1 h | MISSED | 50.0 % met; met 1, missed 1, pending 0 |
| culprit <= 4 h (median) | MISSED | median 13.0 h; reached 1, overdue 1, pending 0 |
| fix or flag-off <= 12 h | MISSED | 0.0 % met; met 0, missed 1, pending 0 |
| none older than 12 h before assigned | MISSED | #5 new 24.0 h |

#### A/A noise

Monitored series: 2, series-days: 6, waterfall hosts: 1.

| Check | Result | Numbers |
|---|---|---|
| false alerts <= 1 per 100 series-days | ok | 0 false alerts, 0.00 per 100 |
| median CV <= 5.0 % on >= 90.0 % of latency series | MISSED | 50.0 % of 2 |
| p99 CV <= 10.0 % on >= 80.0 % of latency series | ok | 100.0 % of 2 |
| >= 3 A/A runs per waterfall host | ok | every host |

Noisiest series (median CV over 5.0 % or p99 CV over 10.0 %):

| Series | Pairs | Median CV | p99 CV |
|---|---|---|---|
| terminal.key-frame.light terminal.noisy on apple-m4-pro/24gb/120hz | 3 | 12.9 % | 7.4 % |
"""

PERF_LEAD = """\
# perf lead

## 5. Results log

| Date | Workstream | sha range on feat-cmux-next | Row | Before | After |
|---|---|---|---|---|---|
| 2026-10-23 | PL sweep | a..b | 26 | x | y |

### Process-model baseline

text

## 6. Next
"""


class WeeklyReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.directory = Path(self._tmp.name)
        self.fixture = build_fixture(self.directory)
        self.key = store.series_key(story=STORY, metric="terminal.key_to_frame", engine="none",
                                    host_class=HOST.host_class, macos_major=26, build_config="bench")

    def tearDown(self) -> None:
        self.fixture.close()
        self._tmp.cleanup()

    def report(self, *, now: datetime = NOW, **overrides) -> str:
        values = dict(db=str(self.fixture.path), root=self.directory, json=False, append=None, week=True)
        values.update(overrides)
        out = io.StringIO()
        code = report.weekly_report(argparse.Namespace(**values), clock=lambda: now,
                                    targets_loader=lambda root: (TARGETS, ()), detector=NoChangePoints(),
                                    configs=monitor_all, out=out)
        self.assertEqual(code, 0)
        return out.getvalue()

    def test_markdown_on_the_fixture(self) -> None:
        self.assertEqual(self.report(), EXPECTED)

    def test_the_same_store_gives_the_same_report(self) -> None:
        self.assertEqual(self.report(), self.report())
        self.assertEqual(self.report(json=True), self.report(json=True))

    def test_json_carries_the_same_numbers(self) -> None:
        found = json.loads(self.report(json=True))
        self.assertEqual(found["window"], {"start": "2026-10-19T12:00:00.000000+00:00",
                                           "end": "2026-10-26T12:00:00.000000+00:00", "week": "2026-W44"})
        self.assertEqual([(t["row"], t["start"], t["end"], t["end_status"]) for t in found["targets"]],
                         [("key-frame.light", 9.0, 5.5, "pass"), ("key-frame.light", 11.91, 6.97, "pass"),
                          ("launch.cold", None, None, "no-data")])
        self.assertEqual(found["targets"][0]["series"], self.key)
        self.assertEqual(found["outcomes"], {"assigned": 1, "invalid": 1, "new": 1, "triaged": 1})
        self.assertEqual(found["closed"], {"invalid": 1})
        self.assertEqual(found["slo"]["triage"]["missed"], [5])
        self.assertEqual(found["aa"]["series_days"], 6)
        self.assertEqual([row["metric"] for row in found["noisy"]], ["terminal.noisy"])

    def test_a_series_that_starts_in_the_week_has_no_start_value(self) -> None:
        later = NOW - timedelta(days=2)
        self.fixture.run(pos=180, at=later, samples=[200.0], metric="launch.cold",
                         target_ref=json.dumps({"target": "launch.cold"}))
        found = json.loads(self.report(json=True))
        launch = [t for t in found["targets"] if t["row"] == "launch.cold"]
        self.assertEqual([(t["start"], t["start_status"], t["end"], t["end_status"]) for t in launch],
                         [(None, "no-data", 200.0, "pass")])

    def test_append_adds_a_subsection_at_the_end_of_section_5(self) -> None:
        lead = self.directory / "perf-lead.md"
        lead.write_text(PERF_LEAD, encoding="utf-8")
        self.assertIn("added", self.report(append=lead))
        text = lead.read_text(encoding="utf-8")
        before, rest = text.split("### Weekly perf report", 1)
        self.assertTrue(before.endswith("### Process-model baseline\n\ntext\n\n"))
        self.assertTrue(rest.endswith("| 3 | 12.9 % | 7.4 % |\n\n## 6. Next\n"))
        self.assertEqual("### Weekly perf report" + rest.split("\n## 6. Next")[0].rstrip("\n") + "\n",
                         EXPECTED)
        with self.assertRaisesRegex(report.ReportError, "already has the report of 2026-W44"):
            self.report(append=lead)
        self.assertEqual(lead.read_text(encoding="utf-8"), text)

    def test_append_refuses_a_second_report_later_in_the_same_week(self) -> None:
        lead = self.directory / "perf-lead.md"
        lead.write_text(PERF_LEAD, encoding="utf-8")
        self.report(append=lead)
        text = lead.read_text(encoding="utf-8")
        for later in (NOW + timedelta(minutes=7), NOW + timedelta(days=4, hours=3)):
            with self.subTest(later=later), self.assertRaisesRegex(report.ReportError, "already has the report of"):
                self.report(append=lead, now=later)
        self.assertEqual(lead.read_text(encoding="utf-8"), text)
        # The next ISO week gets its own report.
        self.assertIn("added", self.report(append=lead, now=NOW + timedelta(days=7)))
        self.assertEqual(lead.read_text(encoding="utf-8").count("### Weekly perf report "), 2)

    def test_host_classes_that_rotate_in_the_week_keep_their_values(self) -> None:
        # Host a reports until mid-week, host b before the week and again late in it, host c starts in the week.
        # Each is hidden at a bound where a current sibling feeds the check, yet keeps its own value there.
        directory = self.directory / "rotate"
        directory.mkdir()
        fixture = Fixture(directory)
        self.addCleanup(fixture.close)
        hosts = {name: store.Host(name=f"cmux-{name}", chip="Apple M4 Pro", memory_gb=memory, display_hz=120,
                                  fingerprint=f"fp-{name}") for name, memory in (("a", 24), ("b", 48), ("c", 64))}
        fixture.run(pos=100, at=NOW - timedelta(days=11), samples=[7.0], host=hosts["b"])
        fixture.run(pos=110, at=NOW - timedelta(days=8), samples=[6.0], host=hosts["a"])
        fixture.run(pos=120, at=NOW - timedelta(days=5), samples=[9.0], host=hosts["a"])
        fixture.run(pos=130, at=NOW - timedelta(days=2), samples=[5.0], host=hosts["b"])
        fixture.run(pos=140, at=NOW - timedelta(days=1), samples=[4.0], host=hosts["c"])
        found = json.loads(self.report(json=True, db=str(fixture.path)))
        rows = {t["series_name"].split(" on ")[1]: (t["start"], t["start_status"], t["end"], t["end_status"])
                for t in found["targets"] if t["check"].endswith("p50 <= 8.30 ms")}
        self.assertEqual(rows, {
            hosts["a"].host_class: (6.0, "pass", 9.0, "stale"),
            hosts["b"].host_class: (7.0, "stale", 5.0, "pass"),
            hosts["c"].host_class: (None, "no-data", 4.0, "pass"),
        })
        markdown = self.report(db=str(fixture.path))
        self.assertIn("Checks at the end of the week: 7 (pass 4, stale 2, no-data 1).", markdown)
        self.assertIn("| 6 ms (pass) | 9 ms (stale) |", markdown)
        self.assertIn("| 7 ms (stale) | 5 ms (pass) |", markdown)

    def test_a_week_with_no_waterfall_host_says_so(self) -> None:
        directory = self.directory / "empty"
        directory.mkdir()
        fixture = Fixture(directory)
        self.addCleanup(fixture.close)
        markdown = self.report(db=str(fixture.path))
        self.assertIn("| >= 3 A/A runs per waterfall host | MISSED | no waterfall host in the week |", markdown)
        self.assertNotIn("every host", markdown)

    def test_append_needs_a_results_section(self) -> None:
        lead = self.directory / "other.md"
        lead.write_text("# nothing\n", encoding="utf-8")
        with self.assertRaisesRegex(report.ReportError, "Results log"):
            self.report(append=lead)

    def test_a_missing_store_is_refused(self) -> None:
        with self.assertRaisesRegex(report.ReportError, "no lab store"):
            self.report(db=str(self.directory / "missing.db"))

    def test_lab_py_lists_the_command(self) -> None:
        self.assertIn("report", lab.discover())


if __name__ == "__main__":
    unittest.main()

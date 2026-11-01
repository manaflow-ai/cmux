#!/usr/bin/env python3
"""dashboard.py: every page renders from a temp lab store, loads nothing from the network, and the
target tiles judge only current, non-debug series that claim a row (at the row's Hz when it names one)
and link to the series they judge.

  python3 -m unittest scripts/perf-lab/tests/test_dashboard.py
  UPDATE_SNAPSHOTS=1 python3 -m unittest scripts/perf-lab/tests/test_dashboard.py   # rewrite snapshots
"""
from __future__ import annotations

import html.parser
import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import unquote, urlsplit

LAB = Path(__file__).resolve().parent.parent
SNAPSHOTS = Path(__file__).resolve().parent / "snapshots"


def _load(name: str, filename: str):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, LAB / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


store = _load("perf_lab_store", "store.py")
dashboard = _load("perf_lab_dashboard", "dashboard.py")

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
HOST_120 = store.Host(name="cmux15", chip="Apple M4 Pro", memory_gb=24, display_hz=120, fingerprint="fp-15")
HOST_60 = store.Host(name="cmux20-bench", chip="Apple M4 Pro", memory_gb=24, display_hz=60, fingerprint="fp-20")
LIGHT = "terminal.key-frame.light"
STRESS = "terminal.key-frame.stress"
LAUNCH = "launch.warm"
UNCLAIMED = "terminal.key-frame.unclaimed"
IDLE = "idle.tabs-10"

Check = dashboard.TargetCheck
Row = dashboard.TargetRow
KEY_FRAME_CHECKS = (Check(r"key_to_frame_ms", "p50", "<=", 8.3, "ms"), Check(r"key_to_frame_ms", "p99", "<=", 16.7, "ms"))
TARGETS = [
    dashboard.Target("key-frame", "key->frame p50 <= 8.3 ms and p99 <= 16.7 ms, light and STRESS, at hz=120", False, (
        Row("key-frame.light", "key-frame", KEY_FRAME_CHECKS, session="light", hz=120),
        Row("key-frame.stress", "key-frame", KEY_FRAME_CHECKS, session="stress", hz=120))),
    dashboard.Target("launch", "warm launch p95 <= 150 ms", False, (
        Row("launch.warm", "launch", (Check(r"launch_ms", "p95", "<=", 150, "ms"),
                                      Check(r"launch_ms", "min", ">=", 100, "ms"))),)),
    dashboard.Target("build", "incremental leaf build p50 < 30 s", False, (
        Row("incremental-build", "build", (Check(r"build\.incremental\.[a-z0-9_]+_s", "p50", "<", 30, "s"),)),)),
    dashboard.Target("idle", "idle wakeups p50 <= 1 per s", True, (
        Row("idle.webkit", "idle", (Check(r"wakeups_per_s", "p50", "<=", 1, "count"),), engine="webkit"),)),
]


def claim(row_id: str) -> str:
    """A stored target_ref as ingest writes it (ingest._target_ref)."""
    return json.dumps({"target": row_id}, sort_keys=True, separators=(",", ":"))


def key_of(story: str, metric: str, host: store.Host, *, engine: str = "none", config: str = "bench",
           macos_major: int = 26) -> str:
    return store.series_key(story=story, metric=metric, engine=engine, host_class=host.host_class,
                            macos_major=macos_major, build_config=config)


class LabFixture:
    """A small lab: two 120 Hz key-frame series (light passes after a recovered target_miss, STRESS misses p99),
    a failing 60 Hz copy that must not count, a failing debug copy that must not count, a failing macOS 25 copy
    that went stale, a failing series that claims no row, a chromium series claiming a webkit row, warm launch on
    a 60 Hz host, an alert group, a bisect job with traces, and a tiered coverage history."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.store = store.Store(path, clock=lambda: NOW)
        self.store.migrate()
        self.uuid = 0

    def close(self) -> None:
        self.store.close()

    def add(self, story: str, metric: str, samples: list[float], *, pos: int, host: store.Host = HOST_120,
            config: str = "bench", kind: str = "waterfall", tier: str | None = "T0", features_hash: str = "f0",
            macos_build: str = "26.1 (25B78)", started_at: datetime | None = None, unit: str = "ms",
            target: str | None = None, engine: str = "none", macos_major: int = 26) -> None:
        self.uuid += 1
        run = store.Run(run_uuid=f"run-{self.uuid}", kind=kind, measure_version="m1", story=story, engine=engine,
                        macos_major=macos_major, macos_build=macos_build, features_hash=features_hash, safe_mode="off",
                        started_at=started_at or NOW - timedelta(minutes=10 * (12 - pos)), tier=tier)
        self.store.insert_run(run, build=store.Build(sha=f"{pos:040x}", config=config, commit_pos=pos), host=host,
                              metrics=[store.Metric(name=metric, unit=unit, better="lower", samples=samples,
                                                    target_ref=claim(target) if target else None)])

    def sql(self, statement: str, *args) -> int:
        db = sqlite3.connect(self.path)
        try:
            cursor = db.execute(statement, args)
            db.commit()
            return cursor.lastrowid
        finally:
            db.close()

    def populate(self) -> None:
        for pos in range(1, 13):
            self.add(LIGHT, "key_to_frame_ms", [5.0, 6.0, 7.0, 8.0, 9.0], pos=pos, target="key-frame.light",
                     features_hash="f0" if pos < 8 else "f1", macos_build="26.1 (25B78)" if pos < 10 else "26.1 (25B80)")
            stress_tail = 14.0 if pos < 9 else 30.0
            self.add(STRESS, "key_to_frame_ms", [6.0, 7.0, 7.5, 8.0, stress_tail], pos=pos, target="key-frame.stress")
            self.add(LIGHT, "key_to_frame_ms", [40.0, 41.0, 42.0], pos=pos, host=HOST_60, target="key-frame.light")
            self.add(LIGHT, "key_to_frame_ms", [90.0, 95.0], pos=pos, config="debug", tier=None,
                     target="key-frame.light")
            self.add(UNCLAIMED, "key_to_frame_ms", [80.0, 90.0], pos=pos)
            self.add(LAUNCH, "launch_ms", [100.0 + i for i in range(20)], pos=pos, host=HOST_60, tier="T1",
                     target="launch.warm")
            self.add(IDLE, "wakeups_per_s", [9.0], pos=pos, unit="count", engine="chromium", target="idle.webkit")
        self.add(LIGHT, "key_to_frame_ms", [5.5, 6.5], pos=12, kind="reference", tier=None, target="key-frame.light")
        # The same story on the previous macOS major: it stopped getting points ten days ago, and it missed.
        self.add(LIGHT, "key_to_frame_ms", [50.0, 60.0], pos=1, macos_major=25, target="key-frame.light",
                 started_at=NOW - timedelta(days=10))
        # A target_miss the light series has since recovered from: stored, never grouped, never closed.
        self.sql("""INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, median_before, median_after,
                    is_improvement, created_at) VALUES (?, NULL, 'target_miss', 3, 4, 7.0, 20.0, 0, ?)""",
                 self.series_id(key_of(LIGHT, "key_to_frame_ms", HOST_120)), NOW.isoformat())
        stress_key = key_of(STRESS, "key_to_frame_ms", HOST_120)
        series_id = self.series_id(stress_key)
        group = self.sql("""INSERT INTO alert_groups (state, start_pos, end_pos, culprit_sha, culprit_verified,
                            issue_number, created_at, updated_at) VALUES ('culprit', 8, 9, ?, 1, 4242, ?, ?)""",
                         f"{9:040x}", NOW.isoformat(), NOW.isoformat())
        self.sql("""INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, median_before, median_after,
                    is_improvement, created_at) VALUES (?, ?, 'edivisive', 8, 9, 7.5, 7.5, 0, ?)""",
                 series_id, group, NOW.isoformat())
        self.sql("""INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, median_before, median_after,
                    is_improvement, created_at) VALUES (?, NULL, 'target_miss', 9, 12, 14.0, 30.0, 0, ?)""",
                 series_id, NOW.isoformat())
        job = self.sql("""INSERT INTO jobs (controller_job_id, kind, state, story, host_class, base_sha, head_sha,
                          alert_group_id, created_at, updated_at) VALUES ('ctl-77', 'bisect', 'culprit', ?, ?, ?, ?, ?, ?, ?)""",
                       STRESS, HOST_120.host_class, f"{8:040x}", f"{9:040x}", group, NOW.isoformat(), NOW.isoformat())
        self.sql("""INSERT INTO traces (job_id, attempt, kind, digest, url, bytes, created_at)
                    VALUES (?, 0, 'signpost', 'sha256:aa', 'https://traces.example.invalid/aa', 10, ?)""",
                 job, NOW.isoformat())
        self.sql("""INSERT INTO traces (job_id, attempt, kind, digest, url, bytes, created_at)
                    VALUES (?, 5, 'daemon', 'sha256:bb', 'javascript:alert(1)', 10, ?)""", job, NOW.isoformat())
        self.store.annotate(kind="note", start_pos=6, end_pos=6, text="host reimaged <b>", created_by="test",
                            key=key_of(LIGHT, "key_to_frame_ms", HOST_120))

    def series_id(self, key: str) -> int:
        db = sqlite3.connect(self.path)
        try:
            return db.execute("SELECT id FROM series WHERE series_key = ?", (key,)).fetchone()[0]
        finally:
            db.close()


class Fetches(html.parser.HTMLParser):
    """Collects everything in a page that a browser would load without a click."""

    LOADING_ATTRS = {"src", "srcset", "data", "poster", "background", "manifest", "ping", "xlink:href"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.loads: list[str] = []
        self.anchors: list[str] = []
        self.forms: list[str] = []
        self._in_style = False
        self.style = ""

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag in ("script", "link", "iframe", "img", "embed", "object", "video", "audio", "source", "image", "use"):
            self.loads.append(f"<{tag}>")
        for name, value in attrs:
            if name in self.LOADING_ATTRS:
                self.loads.append(f"{tag}[{name}]={value}")
            if name.startswith("on"):
                self.loads.append(f"{tag}[{name}] handler")
            if name == "style" and value and "url(" in value:
                self.loads.append(f"{tag}[style]")
        if tag == "meta" and attributes.get("http-equiv", "").lower() == "refresh":
            self.loads.append("meta refresh")
        if tag == "a" and "href" in attributes:
            self.anchors.append(attributes["href"])
        if tag == "form":
            self.forms.append(attributes.get("action", ""))
        self._in_style = tag == "style"

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        self._in_style = False

    def handle_endtag(self, tag):
        if tag == "style":
            self._in_style = False

    def handle_data(self, data):
        if self._in_style:
            self.style += data


def scan(body: str) -> Fetches:
    parser = Fetches()
    parser.feed(body)
    parser.close()
    return parser


class DashboardTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._tmp = tempfile.TemporaryDirectory()
        cls.db = Path(cls._tmp.name) / "lab.sqlite"
        fixture = LabFixture(cls.db)
        fixture.populate()
        fixture.close()
        cls.targets = TARGETS

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmp.cleanup()

    def setUp(self) -> None:
        self.source = dashboard.StoreSource(self.db, field_rows=lambda: [
            dashboard.FieldRow("0.1.0-nightly.42", "m4pro", "hangs_per_1000h", 1.25, "count", 310, "perfPath:on")],
            stability_rows=lambda: [dashboard.StabilityRow("cmux-next@0.1.0+42", 0.9981, 0.995, 2)])
        self.dash = dashboard.Dashboard(self.source, self.targets, clock=lambda: NOW)

    def tearDown(self) -> None:
        self.source.close()

    def get(self, path: str) -> str:
        result = self.dash.handle(path)
        self.assertEqual(result.status, 200, result.body)
        return result.body


class NoNetworkTests(DashboardTestCase):
    def pages(self) -> list[str]:
        paths = ["/", "/status", "/series", "/series?q=launch", "/alerts", "/jobs", "/coverage", "/field", "/stability"]
        db = sqlite3.connect(self.db)
        keys = [row[0] for row in db.execute("SELECT series_key FROM series")]
        db.close()
        return paths + [dashboard.series_href(key) for key in keys]

    def test_rendered_pages_fetch_nothing(self) -> None:
        for path in self.pages():
            with self.subTest(path=path):
                body = self.get(path)
                found = scan(body)
                self.assertEqual(found.loads, [])
                self.assertNotIn("url(", found.style)
                self.assertNotIn("@import", found.style)
                self.assertNotIn("@font-face", found.style)
                self.assertIn(f'content="{dashboard.CSP}"', body)
                for form in found.forms:
                    self.assertTrue(form.startswith("/"), form)
                for href in found.anchors:
                    parts = urlsplit(href)
                    self.assertIn(parts.scheme, ("", "https"), href)
                    if not parts.scheme:
                        self.assertTrue(href.startswith(("/", "#")), href)

    def test_the_policy_forbids_every_load_but_inline_style(self) -> None:
        directives = dict(part.strip().split(" ", 1) for part in dashboard.CSP.split(";"))
        self.assertEqual(directives["default-src"], "'none'")
        self.assertEqual(directives["style-src"], "'unsafe-inline'")
        self.assertNotIn("script-src", directives)

    def test_a_stored_javascript_trace_url_is_not_a_link(self) -> None:
        body = self.get("/jobs")
        self.assertIn('href="https://traces.example.invalid/aa"', body)
        self.assertNotIn("javascript:", body)
        self.assertIn("daemon #5", body)

    def test_stored_text_is_escaped(self) -> None:
        body = self.get(dashboard.series_href(key_of(LIGHT, "key_to_frame_ms", HOST_120)))
        self.assertIn("host reimaged &lt;b&gt;", body)
        self.assertNotIn("host reimaged <b>", body)


class TileTests(DashboardTestCase):
    def tile(self, target_id: str):
        return next(tile for tile in self.dash.tiles() if tile.target.id == target_id)

    def test_every_tile_row_links_to_its_series_and_the_link_resolves(self) -> None:
        body = self.get("/")
        hrefs = set(scan(body).anchors)
        for tile in self.dash.tiles():
            for row in tile.rows:
                if row.series is None:
                    continue
                href = dashboard.series_href(row.series.key)
                with self.subTest(target=tile.target.id, series=row.series.story):
                    self.assertIn(href, hrefs)
                    self.assertIn(row.series.key, unquote(href))
                    self.get(href)

    def test_key_frame_judges_only_claiming_120_hz_non_debug_series(self) -> None:
        tile = self.tile("key-frame")
        judged = {(row.row.id, row.check.stat, row.series.story, row.series.host_class, row.series.build_config)
                  for row in tile.rows}
        self.assertEqual(judged, {(f"key-frame.{session}", stat, story, HOST_120.host_class, "bench")
                                  for stat in ("p50", "p99") for session, story in (("light", LIGHT), ("stress", STRESS))})

    def test_a_series_that_claims_no_row_is_never_judged(self) -> None:
        stories = {row.series.story for tile in self.dash.tiles() for row in tile.rows if row.series is not None}
        self.assertNotIn(UNCLAIMED, stories)

    def test_a_row_engine_excludes_other_engines(self) -> None:
        tile = self.tile("idle")
        self.assertEqual([(row.status, row.series) for row in tile.rows], [("no-data", None)])
        self.assertIn("no series claims idle.webkit for wakeups_per_s", self.get("/"))

    def test_pass_and_miss_values(self) -> None:
        rows = {(row.check.stat, row.series.story): row for row in self.tile("key-frame").rows}
        self.assertEqual(rows["p50", LIGHT].status, "pass")
        self.assertAlmostEqual(rows["p50", LIGHT].value, 7.0)
        self.assertEqual(rows["p99", LIGHT].status, "pass")
        self.assertEqual(rows["p99", STRESS].status, "miss")
        self.assertAlmostEqual(rows["p99", STRESS].value, 30.0 - 0.04 * 22.0)
        self.assertTrue(rows["p99", STRESS].target_miss_open)
        self.assertEqual(rows["p99", STRESS].point.commit_pos, 12)
        self.assertEqual(self.tile("key-frame").status, "miss")

    def test_a_recovered_target_miss_is_not_open(self) -> None:
        rows = {(row.check.stat, row.series.story): row for row in self.tile("key-frame").rows}
        self.assertFalse(rows["p50", LIGHT].target_miss_open)
        self.assertFalse(rows["p99", LIGHT].target_miss_open)
        self.assertFalse(rows["p50", STRESS].target_miss_open)
        self.assertEqual(self.get("/").count("target_miss open"), 1)

    def test_a_stale_series_is_not_judged_while_a_current_one_is(self) -> None:
        majors = {row.series.macos_major for row in self.tile("key-frame").rows}
        self.assertEqual(majors, {26})
        self.assertNotIn(dashboard.series_href(key_of(LIGHT, "key_to_frame_ms", HOST_120, macos_major=25)), self.get("/"))

    def test_p95_and_min_checks_read_the_newest_samples(self) -> None:
        p95, low = self.tile("launch").rows
        self.assertEqual(p95.series.host_class, HOST_60.host_class)
        self.assertAlmostEqual(p95.value, 100 + 0.95 * 19)
        self.assertEqual(p95.status, "pass")
        self.assertEqual((low.check.stat, low.value, low.status), ("min", 100.0, "pass"))

    def test_a_target_with_no_series_is_no_data(self) -> None:
        tile = self.tile("build")
        self.assertEqual([row.status for row in tile.rows], ["no-data"])
        self.assertEqual(tile.status, "no-data")
        body = self.get("/")
        self.assertIn(r"no series claims incremental-build for build\.incremental\.[a-z0-9_]+_s", body)
        self.assertIn('href="/series?q=build.incremental."', body)

    def test_status_never_rests_on_color_alone(self) -> None:
        body = self.get("/")
        self.assertIn("Miss</span>", body)
        self.assertIn("Pass</span>", body)
        self.assertIn("No data</span>", body)


class SnapshotTests(unittest.TestCase):
    INFO = dashboard.SeriesInfo(key="sk1:0123456789abcdef0123456789abcdef", story=LIGHT, metric="key_to_frame_ms",
                                engine="none", host_class="apple-m4-pro/24gb/120hz", macos_major=26,
                                build_config="bench", unit="ms", better="lower",
                                target_ref=claim("key-frame.light"))
    CHECK = Check(r"key_to_frame_ms", "p99", "<=", 16.7, "ms")
    ROW = Row("key-frame.light", "key-frame", (CHECK,), session="light", hz=120)
    TARGET = dashboard.Target("key-frame", "key->frame p99 <= 16.7 ms at hz=120", False, (ROW,))

    def point(self, p99: float) -> dashboard.PointView:
        return dashboard.PointView(commit_pos=41, sha="ab" * 20, started_at="2026-10-25T11:50:00.000000+00:00",
                                   p50=6.0, p99=p99, n=30, features_hash="f0", macos_build="26.1 (25B78)",
                                   safe_mode="off", host_name="cmux15")

    def tile(self, p99: float, status: str, miss_open: bool = False) -> dashboard.Tile:
        return dashboard.Tile(self.TARGET, (dashboard.TileRow(self.ROW, self.CHECK, self.INFO, self.point(p99), p99, status,
                                                               miss_open),))

    def check(self, name: str, rendered: str) -> None:
        path = SNAPSHOTS / f"{name}.html"
        if os.environ.get("UPDATE_SNAPSHOTS") == "1":
            SNAPSHOTS.mkdir(exist_ok=True)
            path.write_text(rendered + "\n")
        self.assertEqual(rendered + "\n", path.read_text(), f"{path} differs; rerun with UPDATE_SNAPSHOTS=1 and review")

    def test_pass_tile(self) -> None:
        self.check("tile-pass", dashboard.render_tile(self.tile(12.5, "pass")))

    def test_fail_tile(self) -> None:
        self.check("tile-miss", dashboard.render_tile(self.tile(21.0, "miss", miss_open=True)))

    def test_no_data_tile(self) -> None:
        row = dashboard.TileRow(self.ROW, self.CHECK, None, None, None, "no-data")
        self.check("tile-no-data", dashboard.render_tile(dashboard.Tile(self.TARGET, (row,))))

    def test_a_check_fed_only_by_a_stale_series_is_stale_not_a_miss(self) -> None:
        old = self.point(21.0)
        fresh_since = dashboard.parse_stamp(old.started_at) + timedelta(seconds=1)
        (tile,) = dashboard.build_tiles([self.TARGET], [self.INFO], {self.INFO.key: old}, lambda key, stat: 21.0,
                                        {self.INFO.key}, fresh_since=fresh_since)
        (row,) = tile.rows
        self.assertEqual((row.status, row.value, row.target_miss_open), ("stale", 21.0, False))
        self.assertEqual(tile.status, "no-data")
        body = dashboard.render_tile(tile)
        self.assertIn("Stale</span>", body)
        self.assertIn("newest point 2026-10-25, no current series", body)

    def test_build_tiles_decides_the_snapshot_states(self) -> None:
        for p99, expected in ((12.5, "pass"), (16.7, "pass"), (21.0, "miss")):
            with self.subTest(p99=p99):
                (tile,) = dashboard.build_tiles([self.TARGET], [self.INFO], {self.INFO.key: self.point(p99)},
                                                lambda key, stat: p99, set())
                self.assertEqual(tile.status, expected)


class PageTests(DashboardTestCase):
    def test_series_page_has_lines_change_points_annotations_and_reference(self) -> None:
        light = self.get(dashboard.series_href(key_of(LIGHT, "key_to_frame_ms", HOST_120)))
        self.assertIn("f0 → f1", light)
        self.assertIn("26.1 (25B78) → 26.1 (25B80)", light)
        self.assertIn('class="line s1"', light)
        self.assertIn('class="line s2"', light)
        self.assertIn("key-frame.light: p50 ≤ 8.30 ms", light)
        self.assertIn("1 runs of the weekly-frozen build", light)
        stress = self.get(dashboard.series_href(key_of(STRESS, "key_to_frame_ms", HOST_120)))
        self.assertIn('class="band regression"', stress)
        self.assertIn('href="/alerts#group-', stress)

    def test_series_page_points_are_waterfall_runs_in_commit_order(self) -> None:
        view = self.source.series(key_of(LIGHT, "key_to_frame_ms", HOST_120), 100)
        self.assertEqual([point.commit_pos for point in view.points], list(range(1, 13)))
        self.assertEqual(len(view.reference_points), 1)

    def test_series_list_filters_and_draws_sparklines(self) -> None:
        body = self.get("/series?q=launch")
        self.assertIn(LAUNCH, body)
        self.assertNotIn(STRESS, body)
        self.assertIn('class="spark"', body)
        by_metric = self.get("/series?q=key_to_frame")
        self.assertIn(STRESS, by_metric)
        self.assertNotIn(LAUNCH, by_metric)
        self.assertIn("No series match.", self.get("/series?q=key%25frame"))
        everything = self.get("/series")
        self.assertIn('class="cp"', everything)

    def test_alerts_page_shows_the_group_culprit_and_issue(self) -> None:
        body = self.get("/alerts")
        self.assertIn("Group #1 · culprit", body)
        self.assertIn(f"{9:040x}"[:10] + " (verified)", body)
        self.assertIn("https://github.com/manaflow-ai/cmux/issues/4242", body)

    def test_newer_closed_groups_never_push_out_an_open_group(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "lab.sqlite"
            fixture = LabFixture(db)
            fixture.close()
            old = (NOW - timedelta(days=30)).isoformat()
            fixture.sql("""INSERT INTO alert_groups (state, start_pos, end_pos, created_at, updated_at)
                           VALUES ('triaged', 1, 2, ?, ?)""", old, old)
            for index in range(dashboard.ALERT_GROUPS_LIMIT + 5):
                stamp = (NOW - timedelta(minutes=index)).isoformat()
                fixture.sql("""INSERT INTO alert_groups (state, start_pos, end_pos, created_at, updated_at)
                               VALUES ('fixed', 3, 4, ?, ?)""", stamp, stamp)
            source = dashboard.StoreSource(db)
            try:
                groups = source.alert_groups()
            finally:
                source.close()
        self.assertEqual(len(groups), dashboard.ALERT_GROUPS_LIMIT)
        self.assertEqual((groups[0].id, groups[0].state), (1, "triaged"))
        self.assertEqual({group.state for group in groups[1:]}, {"fixed"})

    def test_coverage_marks_stale_tiers(self) -> None:
        rows = {(row.tier, row.story, row.host_name): row for row in self.source.coverage(NOW - timedelta(hours=24))}
        self.assertEqual(rows["T0", LIGHT, "cmux15"].runs_24h, 12)
        self.assertNotIn((None, LIGHT, "cmux15"), rows)
        body = self.get("/coverage")
        self.assertIn("Fresh</span>", body)
        late = dashboard.Dashboard(self.source, self.targets, clock=lambda: NOW + timedelta(hours=2))
        self.assertIn("Stale</span>", late.handle("/coverage").body)

    def test_field_and_stability_tabs(self) -> None:
        self.assertIn("hangs_per_1000h", self.get("/field"))
        self.assertIn("perfPath:on", self.get("/field"))
        self.assertIn("99.81 %", self.get("/stability"))

    def test_unknown_pages_and_series_are_404(self) -> None:
        self.assertEqual(self.dash.handle("/nope").status, 404)
        self.assertEqual(self.dash.handle("/series/sk1%3Amissing").status, 404)

    def test_no_targets_file_still_renders(self) -> None:
        body = dashboard.Dashboard(self.source, None, targets_problem="targets.json: missing").handle("/").body
        self.assertIn("targets.json: missing", body)


class TargetTests(unittest.TestCase):
    ROW = Row("idle-wakeups.webkit", "idle-wakeups",
              (Check(r"idle\.tabs-10\.main_wakes_per_s", "p50", "<=", 0.5, "count"),
               Check(r"idle\.tabs-10\.app_daemon_wakeups_per_s", "p50", "<=", 1, "count")), engine="webkit")

    def info(self, **changes) -> "dashboard.SeriesInfo":
        fields = dict(key="k", story="idle-tabs", metric="idle.tabs-10.main_wakes_per_s", engine="webkit",
                      host_class="c/24gb/120hz", macos_major=26, build_config="bench", unit="count", better="lower",
                      target_ref=claim("idle-wakeups.webkit"))
        fields.update(changes)
        return dashboard.SeriesInfo(**fields)

    def test_a_claim_picks_the_checks_whose_pattern_full_matches(self) -> None:
        (check,) = dashboard.judged_checks(self.ROW, self.info())
        self.assertEqual(check.metric, r"idle\.tabs-10\.main_wakes_per_s")
        self.assertEqual(dashboard.judged_checks(self.ROW, self.info(metric="idle.tabs-10.main_wakes_per_s.extra")), [])

    def test_a_series_must_claim_the_row_and_fit_its_constraints(self) -> None:
        for changes in ({"target_ref": None}, {"target_ref": claim("idle-wakeups.chromium")},
                        {"target_ref": '{"key":"/rows/x","path":"scripts/cmux-next/perf-budgets.json"}'},
                        {"engine": "chromium"}, {"build_config": "debug"}):
            with self.subTest(changes=changes):
                self.assertEqual(dashboard.judged_checks(self.ROW, self.info(**changes)), [])

    def test_row_hz_and_config_constrain_the_series(self) -> None:
        row = Row("r", "t", (Check("m", "max", "<=", 0, "count"),), config="bench-checks", hz=120)
        fits = self.info(metric="m", target_ref=claim("r"), build_config="bench-checks")
        self.assertEqual(len(dashboard.judged_checks(row, fits)), 1)
        self.assertEqual(dashboard.judged_checks(row, self.info(metric="m", target_ref=claim("r"))), [])
        at_60 = self.info(metric="m", target_ref=claim("r"), build_config="bench-checks", host_class="c/24gb/60hz")
        self.assertEqual(dashboard.judged_checks(row, at_60), [])

    def test_literal_prefix(self) -> None:
        self.assertEqual(dashboard.literal_prefix(r"terminal\.key_to_frame"), "terminal.key_to_frame")
        self.assertEqual(dashboard.literal_prefix(r"panes\.[^.]+\.missed"), "panes.")
        self.assertEqual(dashboard.literal_prefix(r"hangs\.over_250ms\.[a-z_]+"), "hangs.over_250ms.")

    def test_sample_stats(self) -> None:
        samples = [3.0, 1.0, 2.0]
        self.assertEqual(dashboard.sample_stat(samples, "min"), 1.0)
        self.assertEqual(dashboard.sample_stat(samples, "max"), 3.0)
        self.assertEqual(dashboard.sample_stat(samples, "mean"), 2.0)
        self.assertEqual(dashboard.sample_stat(samples, "p50"), 2.0)
        self.assertIsNone(dashboard.sample_stat([], "p50"))
        with self.assertRaises(dashboard.DashboardError):
            dashboard.sample_stat(samples, "p42")

    def test_the_repository_catalog_gives_twelve_tiles(self) -> None:
        targets, problems = dashboard.load_targets(LAB.parents[1])
        self.assertEqual(problems, ())
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "lab.sqlite"
            empty = store.Store(db, clock=lambda: NOW)
            empty.migrate()
            empty.close()
            source = dashboard.StoreSource(db)
            try:
                dash = dashboard.Dashboard(source, targets, clock=lambda: NOW)
                tiles = dash.tiles()
                body = dash.handle("/").body
            finally:
                source.close()
        self.assertEqual(len(tiles), 12)
        self.assertEqual({tile.status for tile in tiles}, {"no-data"})
        self.assertEqual(body.count('<section class="tile no-data"'), 12)
        self.assertEqual(scan(body).loads, [])

    def test_catalog_problems_show_on_the_targets_page(self) -> None:
        body = dashboard.render_targets((), catalog_problems=("targets.json: 11 targets <x>",))
        self.assertIn("1 catalog problems", body)
        self.assertIn("targets.json: 11 targets &lt;x&gt;", body)

    def test_a_missing_catalog_is_a_dashboard_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(dashboard.DashboardError):
            dashboard.load_targets(Path(tmp))


class ChartTests(unittest.TestCase):
    def test_nice_ticks_cover_the_range(self) -> None:
        self.assertEqual(dashboard.nice_ticks(0, 16.7), [0, 5, 10, 15, 20])
        ticks = dashboard.nice_ticks(3.0, 3.0)
        self.assertLessEqual(ticks[0], 3.0)
        self.assertGreater(ticks[-1], 3.0)

    INFO = SnapshotTests.INFO

    @staticmethod
    def points(*positions: int) -> list:
        return [dashboard.PointView(commit_pos=pos, sha=f"{pos:040x}", started_at=NOW.isoformat(), p50=5.0 + pos % 3,
                                    p99=9.0, n=5, features_hash="f0", macos_build="26.1 (25B78)", safe_mode="off",
                                    host_name="cmux15") for pos in positions]

    @staticmethod
    def change(start: int, end: int):
        return dashboard.ChangePointView("edivisive", start, end, 5.0, 7.0, False, None)

    def test_window_span(self) -> None:
        positions = [10, 20, 30]
        self.assertEqual(dashboard.window_span(positions, 21, 30), (2, 2))
        self.assertEqual(dashboard.window_span(positions, 11, 30), (1, 2))
        self.assertEqual(dashboard.window_span(positions, 1, 10), (0, 0))
        self.assertEqual(dashboard.window_span(positions, 15, 15), (1, 1))
        self.assertIsNone(dashboard.window_span(positions, 1, 5))
        self.assertIsNone(dashboard.window_span(positions, 31, 40))
        self.assertIsNone(dashboard.window_span([], 1, 5))

    def test_sparse_positions_still_show_change_point_ticks(self) -> None:
        # alerts._candidate_range: the range starts after the previous point, so start_pos is never a point.
        row = dashboard.SeriesListRow(self.INFO, self.points(*range(10, 130, 10)), [(51, 60), (1, 5), (121, 140)], 0)
        body = dashboard.render_series_list([row], 1, "")
        self.assertEqual(body.count('class="cp"'), 1)
        self.assertIn('<line class="cp" x1="64.0"', body)

    def test_the_chart_skips_ranges_outside_the_shown_points(self) -> None:
        points = self.points(*range(100, 200, 10))
        notes = [dashboard.AnnotationView("note", 5, 5, "old note"), dashboard.AnnotationView("note", 205, 205, "future")]
        view = dashboard.SeriesView(self.INFO, points, [self.change(21, 30), self.change(201, 210)], notes)
        svg = dashboard.series_chart(view)
        self.assertNotIn('class="band', svg)
        self.assertNotIn('class="mark"', svg)
        page = dashboard.render_series(view)
        self.assertIn("<td>21..30</td>", page)
        self.assertIn("old note", page)

    def test_the_chart_clips_a_range_that_starts_before_the_shown_points(self) -> None:
        points = self.points(*range(100, 200, 10))
        view = dashboard.SeriesView(self.INFO, points, [self.change(95, 110), self.change(141, 150)],
                                    [dashboard.AnnotationView("note", 145, 145, "between")])
        svg = dashboard.series_chart(view)
        self.assertEqual(svg.count('class="band regression"'), 2)
        step = (760 - 56 - 16) / 9
        self.assertIn(f'<rect class="band regression" x="56.0" y="18" width="{1.5 * step:.1f}"', svg)
        self.assertIn(f'<rect class="band regression" x="{56 + 4.5 * step:.1f}"', svg)
        self.assertIn(f'<path class="mark" d="M{56 + 5 * step - 4:.1f},', svg)

    def test_sparkline_breaks_at_missing_points(self) -> None:
        svg = dashboard.sparkline([1.0, None, 2.0, 3.0])
        path = svg.split('d="')[1].split('"')[0]
        self.assertEqual(path.count("M"), 2)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""dashboard.py: every page renders from a temp lab store, loads nothing from the network, and the
target tiles judge only 120 Hz, non-debug series and link to the series they judge.

  python3 -m unittest scripts/perf-lab/tests/test_dashboard.py
  UPDATE_SNAPSHOTS=1 python3 -m unittest scripts/perf-lab/tests/test_dashboard.py   # rewrite snapshots
"""
from __future__ import annotations

import html.parser
import importlib.util
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

TARGETS = {"targets": [
    {"id": "key-frame", "title": "Key to frame",
     "rows": [{"story": "terminal.key-frame.*", "metric": "key_to_frame_ms", "stat": "p50", "op": "<=",
               "limit": 8.3, "unit": "ms", "label": "p50"},
              {"story": "terminal.key-frame.*", "metric": "key_to_frame_ms", "stat": "p99", "op": "<=",
               "limit": 16.7, "unit": "ms", "label": "p99"}]},
    {"id": "launch", "title": "Launch",
     "rows": [{"story": "launch.warm", "metric": "launch_ms", "stat": "p95", "op": "<=", "limit": 150,
               "unit": "ms", "hz": None, "label": "warm p95"}]},
    {"id": "build", "title": "Incremental leaf build",
     "rows": [{"story": "incremental-build", "metric": "leaf_build_s", "stat": "p50", "op": "<", "limit": 30,
               "unit": "s", "hz": None}]},
]}


def key_of(story: str, metric: str, host: store.Host, *, engine: str = "none", config: str = "bench") -> str:
    return store.series_key(story=story, metric=metric, engine=engine, host_class=host.host_class, macos_major=26,
                            build_config=config)


class LabFixture:
    """A small lab: two 120 Hz key-frame series (light passes, STRESS misses p99), a failing 60 Hz copy that
    must not count, a failing debug copy that must not count, warm launch on a 60 Hz host, an alert group,
    a bisect job with traces, and a tiered coverage history."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.store = store.Store(path, clock=lambda: NOW)
        self.store.migrate()
        self.uuid = 0

    def close(self) -> None:
        self.store.close()

    def add(self, story: str, metric: str, samples: list[float], *, pos: int, host: store.Host = HOST_120,
            config: str = "bench", kind: str = "waterfall", tier: str | None = "T0", features_hash: str = "f0",
            macos_build: str = "26.1 (25B78)", started_at: datetime | None = None, unit: str = "ms") -> None:
        self.uuid += 1
        run = store.Run(run_uuid=f"run-{self.uuid}", kind=kind, measure_version="m1", story=story, engine="none",
                        macos_major=26, macos_build=macos_build, features_hash=features_hash, safe_mode="off",
                        started_at=started_at or NOW - timedelta(minutes=10 * (12 - pos)), tier=tier)
        self.store.insert_run(run, build=store.Build(sha=f"{pos:040x}", config=config, commit_pos=pos), host=host,
                              metrics=[store.Metric(name=metric, unit=unit, better="lower", samples=samples)])

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
            self.add(LIGHT, "key_to_frame_ms", [5.0, 6.0, 7.0, 8.0, 9.0], pos=pos,
                     features_hash="f0" if pos < 8 else "f1", macos_build="26.1 (25B78)" if pos < 10 else "26.1 (25B80)")
            stress_tail = 14.0 if pos < 9 else 30.0
            self.add(STRESS, "key_to_frame_ms", [6.0, 7.0, 7.5, 8.0, stress_tail], pos=pos)
            self.add(LIGHT, "key_to_frame_ms", [40.0, 41.0, 42.0], pos=pos, host=HOST_60)
            self.add(LIGHT, "key_to_frame_ms", [90.0, 95.0], pos=pos, config="debug", tier=None)
            self.add(LAUNCH, "launch_ms", [100.0 + i for i in range(20)], pos=pos, host=HOST_60, tier="T1")
        self.add(LIGHT, "key_to_frame_ms", [5.5, 6.5], pos=12, kind="reference", tier=None)
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
        cls.targets = dashboard.parse_targets(TARGETS)

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

    def test_key_frame_judges_only_120_hz_non_debug_series(self) -> None:
        tile = self.tile("key-frame")
        judged = {(row.row.stat, row.series.story, row.series.host_class, row.series.build_config) for row in tile.rows}
        self.assertEqual(judged, {(stat, story, HOST_120.host_class, "bench")
                                  for stat in ("p50", "p99") for story in (LIGHT, STRESS)})

    def test_pass_and_miss_values(self) -> None:
        rows = {(row.row.stat, row.series.story): row for row in self.tile("key-frame").rows}
        self.assertEqual(rows["p50", LIGHT].status, "pass")
        self.assertAlmostEqual(rows["p50", LIGHT].value, 7.0)
        self.assertEqual(rows["p99", LIGHT].status, "pass")
        self.assertEqual(rows["p99", STRESS].status, "miss")
        self.assertAlmostEqual(rows["p99", STRESS].value, 30.0 - 0.04 * 22.0)
        self.assertTrue(rows["p99", STRESS].target_miss_open)
        self.assertEqual(rows["p99", STRESS].point.commit_pos, 12)
        self.assertEqual(self.tile("key-frame").status, "miss")

    def test_a_p95_row_reads_the_newest_samples(self) -> None:
        (row,) = self.tile("launch").rows
        self.assertEqual(row.series.host_class, HOST_60.host_class)
        self.assertAlmostEqual(row.value, 100 + 0.95 * 19)
        self.assertEqual(row.status, "pass")

    def test_a_target_with_no_series_is_no_data(self) -> None:
        tile = self.tile("build")
        self.assertEqual([row.status for row in tile.rows], ["no-data"])
        self.assertEqual(tile.status, "no-data")
        self.assertIn("no series matches incremental-build / leaf_build_s", self.get("/"))

    def test_status_never_rests_on_color_alone(self) -> None:
        body = self.get("/")
        self.assertIn("Miss</span>", body)
        self.assertIn("Pass</span>", body)
        self.assertIn("No data</span>", body)


class SnapshotTests(unittest.TestCase):
    INFO = dashboard.SeriesInfo(key="sk1:0123456789abcdef0123456789abcdef", story=LIGHT, metric="key_to_frame_ms",
                                engine="none", host_class="apple-m4-pro/24gb/120hz", macos_major=26,
                                build_config="bench", unit="ms", better="lower")
    ROW = dashboard.TargetRow(story="terminal.key-frame.*", metric="key_to_frame_ms", stat="p99", op="<=", limit=16.7,
                              unit="ms", label="light p99")
    TARGET = dashboard.Target(id="key-frame", title="Key to frame", rows=(ROW,))

    def point(self, p99: float) -> dashboard.PointView:
        return dashboard.PointView(commit_pos=41, sha="ab" * 20, started_at="2026-10-25T11:50:00.000000+00:00",
                                   p50=6.0, p99=p99, n=30, features_hash="f0", macos_build="26.1 (25B78)",
                                   safe_mode="off", host_name="cmux15")

    def tile(self, p99: float, status: str, miss_open: bool = False) -> dashboard.Tile:
        return dashboard.Tile(self.TARGET, (dashboard.TileRow(self.ROW, self.INFO, self.point(p99), p99, status,
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
        row = dashboard.TileRow(self.ROW, None, None, None, "no-data")
        self.check("tile-no-data", dashboard.render_tile(dashboard.Tile(self.TARGET, (row,))))

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
        self.assertIn("Key to frame: p50 ≤ 8.30 ms", light)
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


class TargetParseTests(unittest.TestCase):
    def test_rejects_bad_rows(self) -> None:
        for row in ({"stat": "p42", "op": "<=", "limit": 1}, {"stat": "p50", "op": "~", "limit": 1},
                    {"stat": "p50", "op": "<=", "limit": "8"}, {"stat": "p50", "op": "<=", "limit": True},
                    {"stat": "p50", "op": "<=", "limit": 1, "hz": "120"}):
            with self.subTest(row=row), self.assertRaises(dashboard.DashboardError):
                dashboard.parse_targets({"targets": [{"id": "t", "rows": [row]}]})

    def test_a_target_ref_names_a_series_into_a_target(self) -> None:
        (target,) = dashboard.parse_targets({"targets": [{"id": "idle", "rows": [
            {"story": "nothing-matches", "metric": "wakeups_per_s", "stat": "p50", "op": "<=", "limit": 1, "hz": None}]}]})
        info = dashboard.SeriesInfo("k", "idle-tabs", "wakeups_per_s", "chromium", "c/24gb/120hz", 26, "bench", "count",
                                    "lower", '{"target": "idle"}')
        self.assertTrue(target.rows[0].matches(info, "idle"))
        self.assertFalse(target.rows[0].matches(info, "other"))


class ChartTests(unittest.TestCase):
    def test_nice_ticks_cover_the_range(self) -> None:
        self.assertEqual(dashboard.nice_ticks(0, 16.7), [0, 5, 10, 15, 20])
        ticks = dashboard.nice_ticks(3.0, 3.0)
        self.assertLessEqual(ticks[0], 3.0)
        self.assertGreater(ticks[-1], 3.0)

    def test_sparkline_breaks_at_missing_points(self) -> None:
        svg = dashboard.sparkline([1.0, None, 2.0, 3.0])
        path = svg.split('d="')[1].split('"')[0]
        self.assertEqual(path.count("M"), 2)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""dashboard.py: tiles judged against targets, every page rendered from a real store, 0 network fetches.

  python3 -m unittest scripts/perf-lab/tests/test_dashboard.py
"""
from __future__ import annotations

import importlib.util
import json
import re
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, LAB / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


dashboard = _load("perf_lab_dashboard", "dashboard.py")
store = _load("perf_lab_store", "store.py")

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
STAMP = NOW.isoformat(timespec="microseconds")
HOST_120 = store.Host(name="cmux15", chip="Apple M6", memory_gb=32, display_hz=120, fingerprint="a" * 64)
HOST_60 = store.Host(name="cmux16", chip="Apple M6", memory_gb=32, display_hz=60, fingerprint="b" * 64)
KEY_FRAME = "terminal.key-frame.light"

TARGETS_DOC = {"targets": [
    {"id": "key-frame-light", "title": "Key to frame, light", "unit": "ms",
     "rows": [{"series": [f"{KEY_FRAME}/key_to_frame_ms"],
               "limits": [{"stat": "p50", "op": "<=", "value": 8.3}, {"stat": "p99", "op": "<=", "value": 16.7}]}]},
    {"id": "launch-warm", "title": "Warm launch", "unit": "ms",
     "rows": [{"series": ["launch.warm/launch_ms"], "limits": [{"stat": "p50", "op": "<=", "value": 150}]}]},
    {"id": "crash-survival", "title": "Chromium crash survival", "unit": "", "hz": None,
     "rows": [{"engine": "chromium", "series": ["browser.crash/survival"],
               "limits": [{"stat": "min", "op": ">=", "value": 1.0}]},
              {"engine": "webkit", "series": ["browser.crash/survival"],
               "limits": [{"stat": "min", "op": ">=", "value": 1.0}]}]},
]}


def series_info(story: str = KEY_FRAME, metric: str = "key_to_frame_ms", *, hz: int = 120,
                engine: str = "none", config: str = "bench") -> object:
    host_class = store.host_class(chip="Apple M6", memory_gb=32, display_hz=hz)
    key = store.series_key(story=story, metric=metric, engine=engine, host_class=host_class, macos_major=26,
                           build_config=config)
    return dashboard.SeriesInfo(key, story, metric, engine, host_class, 26, config, "ms", "lower")


class FakeSource:
    """A DashboardSource with fixed points; enough for tile snapshots."""

    def __init__(self, series, points=None, alerts=None):
        self._series, self._points, self._alerts = list(series), points or {}, alerts or {}

    def series(self):
        return self._series

    def points(self, key, limit=dashboard.MAX_WINDOW_SIZE):
        return self._points.get(key, [])[-limit:]

    def alerts(self, key=None):
        return self._alerts.get(key, [])

    def annotations(self, key):
        return []


def point(pos: int, samples, features: str = "f0", macos_build: str = "25A100") -> object:
    return dashboard.PointView(pos, f"{pos:040x}", STAMP, tuple(samples), features, macos_build, "off", "cmux15")


class TargetLoadTests(unittest.TestCase):
    def test_a_target_without_rows_is_one_row(self) -> None:
        [target] = dashboard.load_targets({"targets": [
            {"id": "t", "series": ["a/b"], "limits": [{"stat": "p99", "op": "<=", "value": 4}]}]})
        self.assertEqual(target.rows, (dashboard.TargetRow(("a/b",), (dashboard.Limit("p99", "<=", 4.0),)),))
        self.assertEqual(target.hz, 120)

    def test_bad_limits_are_refused_with_their_place(self) -> None:
        for limit in ({"stat": "p50", "op": "~", "value": 1}, {"stat": "median", "op": "<=", "value": 1},
                      {"stat": "p50", "op": "<=", "value": True}):
            with self.subTest(limit=limit), self.assertRaisesRegex(dashboard.DashboardError, r"targets\[0\]"):
                dashboard.load_targets({"targets": [{"id": "t", "series": ["a/b"], "limits": [limit]}]})

    def test_stat_of_uses_perf_stats_pct(self) -> None:
        samples = [float(v) for v in range(1, 101)]
        self.assertEqual(dashboard.stat_of(samples, "p50"), dashboard.perf_stats.pct(samples, 0.5))
        self.assertEqual(dashboard.stat_of(samples, "p99"), dashboard.perf_stats.pct(samples, 0.99))
        self.assertEqual(dashboard.stat_of(samples, "max"), 100.0)
        self.assertIsNone(dashboard.stat_of([], "p50"))


class TileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.targets = dashboard.load_targets(TARGETS_DOC)
        self.info = series_info()

    def tile(self, samples, alerts=None):
        source = FakeSource([self.info], {self.info.key: [point(40, [9.0] * 10), point(41, samples)]},
                            alerts={self.info.key: alerts or []})
        return dashboard.build_tile(self.targets[0], source.series(), source)

    def test_pass_tile_snapshot(self) -> None:
        tile = self.tile([5.0, 6.0, 7.0, 7.5, 8.0, 8.0, 8.1, 8.2, 9.0, 12.0])
        self.assertEqual(tile.status, "pass")
        href = "/series/" + self.info.key
        self.assertEqual(dashboard.render_tile(tile), (
            '<section class="tile status-pass" id="target-key-frame-light"><h3>Key to frame, light</h3>'
            '<div class="status">✓ pass</div><ul>'
            f'<li><a href="{href}">none · apple-m6/32gb/120hz · macOS 26</a><br>'
            'p50 8 ms ✓ ≤ 8.3 ms, p99 11.7 ms ✓ ≤ 16.7 ms '
            '<span class="muted">at #41</span></li></ul></section>'))

    def test_fail_tile_snapshot(self) -> None:
        miss = dashboard.AlertView(7, self.info.key, "target_miss", 35, 41, 8.0, 9.4, False, STAMP)
        tile = self.tile([9.0, 9.2, 9.4, 9.4, 9.5, 9.6, 9.8, 10.0, 15.0, 30.0], alerts=[miss])
        self.assertEqual(tile.status, "miss")
        href = "/series/" + self.info.key
        self.assertEqual(dashboard.render_tile(tile), (
            '<section class="tile status-miss" id="target-key-frame-light"><h3>Key to frame, light</h3>'
            '<div class="status">✕ miss</div><ul>'
            f'<li><a href="{href}">none · apple-m6/32gb/120hz · macOS 26</a><br>'
            'p50 9.55 ms ✕ ≤ 8.3 ms, p99 28.7 ms ✕ ≤ 16.7 ms '
            '<span class="muted">at #41</span> <span class="muted">missing since #35</span></li></ul></section>'))

    def test_a_tile_with_no_series_is_a_gap_and_links_to_coverage(self) -> None:
        tile = dashboard.build_tile(self.targets[1], [self.info], FakeSource([self.info]))
        self.assertEqual(tile.status, "gap")
        self.assertIn('href="/coverage"', dashboard.render_tile(tile))

    def test_only_120hz_bench_series_are_judged(self) -> None:
        target = self.targets[0]
        row = target.rows[0]
        self.assertTrue(dashboard.row_matches(target, row, self.info))
        self.assertFalse(dashboard.row_matches(target, row, series_info(hz=60)))
        self.assertFalse(dashboard.row_matches(target, row, series_info(config="debug")))
        self.assertFalse(dashboard.row_matches(target, row, series_info(story="launch.warm")))

    def test_a_hz_free_target_has_one_row_per_engine_and_a_missing_engine_is_a_gap(self) -> None:
        chromium = series_info("browser.crash", "survival", hz=60, engine="chromium")
        source = FakeSource([chromium], {chromium.key: [point(3, [1.0, 1.0])]})
        tile = dashboard.build_tile(self.targets[2], source.series(), source)
        self.assertEqual([row.series.engine for row in tile.rows], ["chromium"])
        self.assertEqual(tile.gaps, ("webkit",))
        self.assertEqual(tile.status, "gap")

    def test_target_ref_matches_without_a_pattern(self) -> None:
        info = dashboard.SeriesInfo(**{**series_info("odd.story", "x").__dict__,
                                       "target_ref": json.dumps({"target": "launch-warm"})})
        self.assertTrue(dashboard.row_matches(self.targets[1], self.targets[1].rows[0], info))


class SvgTests(unittest.TestCase):
    def test_nice_ticks_cover_the_range(self) -> None:
        self.assertEqual(dashboard.nice_ticks(3.2, 17.9), [0.0, 5.0, 10.0, 15.0, 20.0])
        self.assertEqual(dashboard.nice_ticks(5.0, 5.0), [4, 6, 8, 10])

    def test_sparkline_marks_change_points_annotations_and_the_newest_point(self) -> None:
        svg = dashboard.sparkline([1.0, 1.1, None, 2.0], steps=[(3, False, "regression <x>")], marks=[(1, "note")])
        self.assertEqual(svg.count('class="step-bad"'), 1)
        self.assertIn("regression &lt;x&gt;", svg)
        self.assertEqual(svg.count('class="mark"'), 1)
        self.assertEqual(svg.count("<circle"), 1)

    def test_point_metadata_changes_become_annotation_marks(self) -> None:
        points = [point(1, [1.0]), point(2, [1.0], features="f1"), point(3, [1.0], features="f1", macos_build="25A200")]
        notes = [dashboard.AnnotationView("reference_drift", 2, 3, "ref moved 4%", "sheriff")]
        titles = [title for _, title in dashboard.annotation_marks(points, notes)]
        self.assertEqual(titles, [".ref drift: ref moved 4% (#2..#3, sheriff)", "features hash f0 → f1",
                                  "macOS build 25A100 → 25A200"])


# ---------- the full dashboard over a real store ----------

FETCHING_TAGS = {"script", "link", "img", "iframe", "frame", "object", "embed", "video", "audio", "source", "track",
                 "image", "use", "feimage", "form", "base", "picture", "portal"}
FETCHING_ATTRS = {"src", "srcset", "data", "poster", "background", "action", "formaction", "ping", "xlink:href",
                  "manifest", "codebase", "archive", "longdesc", "lowsrc", "dynsrc"}


class FetchAudit(HTMLParser):
    """Collects every construct that makes a browser fetch: elements that load, loading attributes,
    CSS url()/@import, meta refresh, link preloads and inline event handlers or javascript: URLs."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.fetches: list[str] = []
        self.anchors: list[str] = []
        self._in_style = False

    def handle_starttag(self, tag, attrs):
        if tag in FETCHING_TAGS:
            self.fetches.append(f"<{tag}>")
        for name, value in attrs:
            if name in FETCHING_ATTRS or name.startswith("on"):
                self.fetches.append(f"{tag}[{name}]")
            if name == "href" and tag != "a":
                self.fetches.append(f"{tag}[href]")
            if name == "href" and (value or "").strip().lower().startswith(("javascript:", "data:")):
                self.fetches.append(f"{tag}[href={value}]")
            if name == "style" and re.search(r"url\(|@import|image-set", value or "", re.I):
                self.fetches.append(f"{tag}[style]")
            if tag == "meta" and name == "http-equiv" and (value or "").lower() == "refresh":
                self.fetches.append("meta refresh")
        if tag == "a":
            self.anchors.append(dict(attrs).get("href", ""))
        self._in_style = tag == "style"

    handle_startendtag = handle_starttag

    def handle_endtag(self, tag):
        self._in_style = False

    def handle_data(self, data):
        if self._in_style and re.search(r"url\(|@import|image-set|@font-face", data, re.I):
            self.fetches.append("css fetch")


def audit(body: str) -> FetchAudit:
    parser = FetchAudit()
    parser.feed(body)
    parser.close()
    return parser


class LabDashboardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._tmp = tempfile.TemporaryDirectory()
        path = Path(cls._tmp.name) / "lab.sqlite"
        lab = store.Store(path, clock=lambda: NOW)
        lab.migrate()
        cls.key_light = cls._seed(lab, KEY_FRAME, "key_to_frame_ms", HOST_120, lambda pos: 7.0 if pos < 20 else 9.0)
        cls.key_60 = cls._seed(lab, KEY_FRAME, "key_to_frame_ms", HOST_60, lambda pos: 12.0)
        cls.launch = cls._seed(lab, "launch.warm", "launch_ms", HOST_120, lambda pos: 120.0, tier="T0")
        lab.annotate(kind="reference_drift", start_pos=25, end_pos=26, text="ref <moved> 4%", created_by="sheriff",
                     key=cls.key_light)
        lab.annotate(kind="note", start_pos=10, end_pos=10, text="lab host reboot", created_by="lab-owner")
        lab.close()
        db = sqlite3.connect(path)
        db.execute("PRAGMA foreign_keys=ON")
        light_id = db.execute("SELECT id FROM series WHERE series_key = ?", (cls.key_light,)).fetchone()[0]
        db.execute("""INSERT INTO alert_groups (id, state, start_pos, end_pos, culprit_sha, culprit_verified,
                      issue_number, reason, created_at, updated_at) VALUES (1, 'culprit', 19, 20, ?, 1, 4242, NULL, ?, ?)""",
                   (f"{20:040x}", STAMP, STAMP))
        db.execute("""INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, median_before, median_after,
                      is_improvement, created_at) VALUES (?, 1, 'edivisive', 19, 20, 7.0, 9.0, 0, ?)""",
                   (light_id, STAMP))
        db.execute("""INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, median_before, median_after,
                      is_improvement, created_at) VALUES (?, NULL, 'target_miss', 20, 29, 7.0, 9.0, 0, ?)""",
                   (light_id, STAMP))
        db.execute("""INSERT INTO jobs (id, controller_job_id, kind, state, story, host_class, base_sha, head_sha,
                      alert_group_id, created_at, updated_at) VALUES (1, 'J-77', 'bisect', 'done', ?, ?, ?, ?, 1, ?, ?)""",
                   (KEY_FRAME, HOST_120.host_class, f"{19:040x}", f"{20:040x}", STAMP, STAMP))
        db.execute("""INSERT INTO traces (job_id, attempt, kind, digest, url, bytes, created_at)
                      VALUES (1, 0, 'signpost', ?, 'https://traces.example/sha256/abc', 1024, ?)""", ("c" * 64, STAMP))
        db.execute("""INSERT INTO traces (job_id, attempt, kind, digest, url, bytes, created_at)
                      VALUES (1, 5, 'daemon', ?, 'javascript:alert(1)', 10, ?)""", ("d" * 64, STAMP))
        db.commit()
        db.close()
        field = lambda: [dashboard.ReportTable("Hangs over 250 ms per 1000 active hours", ("Nightly", "Hangs"),
                                               (("2026.10.24", 3.25),))]
        cls.reader = dashboard.LabReader.open(path, field=field)
        cls.dashboard = dashboard.Dashboard(cls.reader, dashboard.load_targets(TARGETS_DOC), clock=lambda: NOW)

    @classmethod
    def _seed(cls, lab, story, metric, host, value_at, *, tier=None) -> str:
        for pos in range(1, 31):
            run = store.Run(run_uuid=f"{story}-{host.name}-{pos}", kind="waterfall", measure_version="1", story=story,
                            engine="none", macos_major=26, macos_build="25A100" if pos < 15 else "25A200",
                            features_hash="f0" if pos < 25 else "f1", safe_mode="off",
                            started_at=NOW - timedelta(hours=31 - pos), tier=tier)
            samples = [value_at(pos) + 0.1 * i for i in range(10)]
            lab.insert_run(run, build=store.Build(sha=f"{pos:040x}", config="bench", commit_pos=pos), host=host,
                           metrics=[store.Metric(name=metric, unit="ms", better="lower", samples=samples)])
        return store.series_key(story=story, metric=metric, engine="none", host_class=host.host_class,
                                macos_major=26, build_config="bench")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.reader.close()
        cls._tmp.cleanup()

    def pages(self):
        paths = ["/", "/alerts", "/jobs", "/coverage", "/field", "/stability",
                 *(dashboard.series_href(info.key) for info in self.reader.series())]
        return {path: self.dashboard.route(path) for path in paths}

    def test_every_page_renders_with_zero_network_fetches(self) -> None:
        for path, page in self.pages().items():
            with self.subTest(path=path):
                self.assertEqual(page.status, 200)
                self.assertEqual(audit(page.body).fetches, [])
                self.assertIn("default-src 'none'", page.headers["Content-Security-Policy"])
                self.assertIn(f'content="{dashboard.CSP}"', page.body)

    def test_the_audit_catches_fetching_markup(self) -> None:
        for body in ('<img src="x">', '<a href="/" onclick="f()">', "<style>a{background:url(x)}</style>",
                     '<svg><use href="#a"/></svg>', '<link rel="preload" href="x">', '<a href="javascript:x">'):
            with self.subTest(body=body):
                self.assertNotEqual(audit(body).fetches, [])

    def test_every_tile_links_to_its_series(self) -> None:
        overview = self.dashboard.route("/").body
        series_pages = {dashboard.series_href(info.key) for info in self.reader.series()}
        for tile in self.dashboard.tiles():
            with self.subTest(target=tile.target.id):
                section = re.search(rf'<section class="tile[^"]*" id="target-{re.escape(tile.target.id)}">.*?</section>',
                                    overview).group(0)
                links = audit(section).anchors
                for row in tile.rows:
                    self.assertIn(dashboard.series_href(row.series.key), links)
                    self.assertIn(dashboard.series_href(row.series.key), series_pages)
                    self.assertEqual(self.dashboard.route(dashboard.series_href(row.series.key)).status, 200)
                if not tile.rows:
                    self.assertIn("/coverage", links)

    def test_overview_tiles_judge_only_the_120hz_newest_point(self) -> None:
        light, launch, crash = self.dashboard.tiles()
        self.assertEqual([row.series.key for row in light.rows], [self.key_light])
        self.assertEqual((light.status, light.rows[0].commit_pos, light.rows[0].miss_since), ("miss", 30, 20))
        self.assertEqual(launch.status, "pass")
        self.assertEqual(crash.status, "gap")

    def test_overview_lists_every_series_with_a_sparkline(self) -> None:
        body = self.dashboard.route("/").body
        self.assertEqual(body.count('<svg class="spark"'), 3)
        self.assertIn('class="step-bad"', body)

    def test_series_page_shows_change_points_annotations_targets_and_a_table(self) -> None:
        body = self.dashboard.route(dashboard.series_href(self.key_light)).body
        self.assertIn('class="step-bad"', body)
        self.assertIn("regression +28.6% at #19..#20", body)
        self.assertIn(".ref drift: ref &lt;moved&gt; 4%", body)
        self.assertIn("note: lab host reboot", body)
        self.assertIn("features hash f0 → f1", body)
        self.assertIn("macOS build 25A100 → 25A200", body)
        self.assertIn("target p50 ≤ 8.3", body)
        self.assertIn("target p99 ≤ 16.7", body)
        self.assertEqual(body.count("<tr>") - body.count("<thead><tr>"), 30 + 2 + 2)

    def test_alert_groups_link_series_culprit_and_issue(self) -> None:
        body = self.dashboard.route("/alerts").body
        self.assertIn("Group 1: culprit", body)
        self.assertIn(dashboard.series_href(self.key_light), body)
        self.assertIn("(verified)", body)
        self.assertIn("https://github.com/manaflow-ai/cmux/issues/4242", body)

    def test_jobs_link_only_http_traces(self) -> None:
        body = self.dashboard.route("/jobs").body
        self.assertIn('<a href="https://traces.example/sha256/abc">signpost #0</a>', body)
        self.assertIn("daemon #5", body)
        self.assertNotIn("javascript:", body)
        self.assertIn('href="/alerts#group-1"', body)

    def test_coverage_counts_runs_in_the_last_day(self) -> None:
        body = self.dashboard.route("/coverage").body
        self.assertRegex(body, r"<td>launch\.warm</td><td>T0</td><td>none</td><td>1 h ago</td>"
                               r'<td class="num">24</td><td>cmux15</td>')

    def test_field_and_stability_tabs(self) -> None:
        self.assertIn("3.25", self.dashboard.route("/field").body)
        self.assertIn("No stability source is configured", self.dashboard.route("/stability").body)

    def test_unknown_paths_are_404(self) -> None:
        self.assertEqual(self.dashboard.route("/series/sk1:nope").status, 404)
        page = self.dashboard.route("/<script>")
        self.assertEqual(page.status, 404)
        self.assertNotIn("<script>", page.body)

    def test_cli_renders_a_page(self) -> None:
        import contextlib
        import io
        out = io.StringIO()
        db = Path(self._tmp.name) / "lab.sqlite"
        targets = Path(self._tmp.name) / "targets.json"
        targets.write_text(json.dumps(TARGETS_DOC))
        with contextlib.redirect_stdout(out):
            code = dashboard.main(["render", "--db", str(db), "--targets", str(targets), "--path", "/coverage"])
        self.assertEqual(code, 0)
        self.assertIn("<h1>Coverage</h1>", out.getvalue())


if __name__ == "__main__":
    unittest.main()

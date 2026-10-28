#!/usr/bin/env python3
"""soak.py against test_play.py's fake app, bench and clock (no app, no macOS): one launch serves every cycle and is
stopped once at the end, the composed stories play in turn through play.py's real Player with their checkpoint
digests checked, the app is reset to one fresh workspace before each idle gap, the gap reads the processes only
after its settle and at its end with no socket call between, hangs and Chromium failures are counted per hour, the
footprint growth is fitted without the warm-up pass, the web replay and agent install run once before the launch,
failed cycles are counted and end the soak only in a row, an app that exits ends it, and the checked-in manifest and
lab story agree with what soak.py writes.

  python3 -m unittest scripts/perf-lab/tests/test_corpus_soak.py
"""
from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import re
import sys
import unittest
import unittest.mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]


def _load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


soak = _load("perf_lab_corpus_soak_under_test", HERE.parent / "corpus" / "soak.py")
fakes = _load("perf_lab_test_play_fixtures", HERE / "test_play.py")  # test_play.py's FakeApp, FakeBench, Fixture
play = soak.play
catalog = _load("perf_lab_catalog_for_soak", HERE.parent / "catalog.py")

HOUR_NS = 3600 * 1_000_000_000
GAP_MS = 600_000
BASE_FOOTPRINT, APP_FOOTPRINT = 900_000_000, 400_000_000
GROWTH_PER_HOUR, APP_GROWTH_PER_HOUR = 12_000_000, 5_000_000
WAKEUPS_PER_S = 7


class SoakApp(fakes.FakeApp):
    """FakeApp with a fresh launch's one lone terminal, the reset's actions (workspace.newAtBottom, goToWorkspace,
    closeWorkspace), debug.hangs (one hang over 250 ms per tab.focus) and debug.crashes."""

    def __init__(self, clock, **kwargs):
        super().__init__(clock, tabs=(1,), **kwargs)
        self.hangs = self.crashes = 0
        self.refuse_close = False
        self.gap_calls = []  # socket calls while a gap's processes are being measured
        self.measuring = False

    def layout(self, tabs=(2, 1)):
        """What session_io.import_layout builds from test_play's SNAPSHOT."""
        self.workspaces = []
        for count in tabs:
            pane = {"id": fakes.new_id(), "tabs": [fakes.new_id() for _ in range(count)]}
            pane["selected"] = pane["tabs"][0]
            self.workspaces.append({"id": fakes.new_id(), "key": fakes.new_id(), "panes": [pane]})
        self.shown = 0

    def handle(self, method, params, now):
        if self.measuring:
            self.gap_calls.append(method)
        if method == "debug.hangs":
            return {"installed": True, "count250": self.hangs, "count": self.hangs, "records": []}
        if method == "debug.crashes":
            return {"chromium_total": self.crashes, "chromium": []}
        if method == "action.run":
            name, target = params["action"], params.get("target", "")
            if name == "tab.focus":
                self.hangs += 1
            if name == "workspace.newAtBottom":
                pane = {"id": fakes.new_id(), "tabs": [fakes.new_id()]}
                pane["selected"] = pane["tabs"][0]
                self.workspaces.append({"id": fakes.new_id(), "key": fakes.new_id(), "panes": [pane]})
                return {"ok": True}
            if name == "goToWorkspace":
                self.shown = next(i for i, w in enumerate(self.workspaces) if w["id"] == params["args"]["workspace"])
                return {"ok": True}
            if name == "closeWorkspace":
                if self.refuse_close:
                    return {"ok": True}  # accepted, but the workspace stays
                shown = self.workspaces[self.shown]["id"]
                self.workspaces = [w for w in self.workspaces if f"workspace:{w['id']}" != target]
                self.shown = next(i for i, w in enumerate(self.workspaces) if w["id"] == shown)
                return {"ok": True}
        return super().handle(method, params, now)


class SoakProcess:
    pid = 7

    def __init__(self):
        self.code = None

    def poll(self):
        return self.code


class FakeProcesses:
    """The app and a Chromium renderer: footprints grow linearly with the fake clock, wakeups at a fixed rate."""

    def __init__(self, clock, app_of):
        self.clock, self.app_of = clock, app_of
        self.before_launch_calls, self.reads = 0, []

    def before_launch(self):
        self.before_launch_calls += 1

    def read(self, app_pid, app):
        hours = self.clock.now_ns() / HOUR_NS
        seconds = self.clock.now_ns() / 1e9
        app_state = self.app_of()
        app_state.measuring = not app_state.measuring  # a gap reads twice: the calls between are inside its window
        self.reads.append((app_pid, app, self.clock.now_ns()))
        return {7: soak.ProcessReading("app", round(APP_FOOTPRINT + APP_GROWTH_PER_HOUR * hours),
                                       round(WAKEUPS_PER_S / 2 * seconds)),
                8: soak.ProcessReading("cef-renderer", round(BASE_FOOTPRINT - APP_FOOTPRINT +
                                                             (GROWTH_PER_HOUR - APP_GROWTH_PER_HOUR) * hours),
                                       round(WAKEUPS_PER_S / 2 * seconds))}


class SoakFixture:
    """A corpus root (a temporary perf-corpus/) with two recorded fixture stories and a soak manifest over them; a
    Soak over test_play.py's fakes with SoakApp, whose fake layout import builds the snapshot only into a fresh app."""

    def __init__(self, test, *, duration_ms=2 * 3600 * 1000, gap_ms=GAP_MS, stories=("fixture-a", "fixture-b"),
                 digests=None, web_story=None, agent_story=None):
        self.play_fixture = fakes.Fixture(test, digests=digests)
        self.root = self.play_fixture.dir / "root"
        corpus = self.root / play.CORPUS_DIR
        corpus.mkdir(parents=True)
        for relative in ("schemas/perf/corpus-story-v1.schema.json", "schemas/perf/corpus-input-vocabulary-v1.json",
                         "plans/cmux-next/OWNERS.md"):
            (self.root / relative).parent.mkdir(parents=True, exist_ok=True)
            (self.root / relative).write_bytes((REPO_ROOT / relative).read_bytes())
        self.web, self.agents = fakes.FakeWebReplay(), fakes.FakeAgents()
        for name in stories:
            manifest = copy.deepcopy(self.play_fixture.manifest)
            manifest["id"] = name
            if name == web_story:
                manifest["web_archive"] = {"wprgo": self.play_fixture.add_blob(f"wpr {name}".encode()),
                                           "spki": "A" * 43 + "="}
            if name == agent_story:
                manifest["agents"] = [{"surface": "@w0.p0.t0", "agent": "replay",
                                       "transcript": self.play_fixture.add_blob(b'{"frames": []}\n')}]
            (corpus / f"{name}.json").write_text(json.dumps(manifest), encoding="utf-8")
        self.soak_manifest = {
            "schema": "cmux-perf-corpus-story/v1", "id": "fixture-soak", "tier": "T2", "status": "planned",
            "planned": "soak.py plays it.", "description": "A fixture soak.", "owner": "PL-perf-lab",
            "duration_ms": duration_ms, "layout": {"snapshot": None, "workspaces": 1}, "input": {"events": []},
            "pty": [], "web_archive": None, "agents": [],
            "checkpoints": [{"t_ms": 0, "name": "hour-0", "focus": None, "surfaces": None}],
            "compose": {"stories": list(stories), "idle_gap_ms": gap_ms},
            "metrics": [{"name": "corpus\\.fixture_soak\\.hangs_over_250ms", "unit": "count", "better": "lower"},
                        {"name": "corpus\\.fixture_soak\\.footprint_growth_per_hour\\.(total|app)", "unit": "bytes",
                         "better": "lower"},
                        {"name": "corpus\\.fixture_soak\\.idle_wakeups", "unit": "per_s", "better": "lower"},
                        {"name": "corpus\\.fixture_soak\\.browser_crashes", "unit": "count", "better": "lower"}]}
        self.path = corpus / "fixture-soak.json"
        self.write()
        self.clock = self.play_fixture.clock
        self.apps, self.benches, self.imports = [], [], []
        self.processes = FakeProcesses(self.clock, lambda: self.apps[-1])
        pf = self.play_fixture
        self.soak = soak.Soak(root=self.root, clock=self.clock, make_bench=self.make_bench, processes=self.processes,
                              web_replay=self.web, agents=self.agents, log=lambda line: None,
                              player_options={"fetch": pf.fetch, "import_layout": self.import_layout,
                                              "signposts": self.signposts, "spawn": pf.spawn,
                                              "open_channel": pf.open_channel, "pty_gate": pf.pty_gate,
                                              "settle_s": 0.2})

    def write(self):
        self.path.write_text(json.dumps(self.soak_manifest), encoding="utf-8")

    def make_bench(self, app, *, out, env, session):
        fake = SoakApp(self.clock)
        self.apps.append(fake)
        bench = fakes.FakeBench(fake, out, env, session)
        bench.process = SoakProcess()
        self.benches.append(bench)
        return bench

    def import_layout(self, rpc, snapshot):
        app = self.apps[-1]
        if len(app.workspaces) != 1 or len(app.workspaces[0]["panes"][0]["tabs"]) != 1:
            raise play.PlayError("layout import: the app is not fresh")
        app.layout()
        self.imports.append(self.clock.now_ns())
        return fakes.FakeBuilder()

    def signposts(self, pid):
        return fakes.FakeRecording(self.apps[-1])

    def run(self, **kwargs):
        return self.soak.run(self.path, app="/x/cmux DEV t.app", out=self.play_fixture.dir / "out", **kwargs)


# ---------------------------------------------------------------- pure parts


class PerHour(unittest.TestCase):
    def test_each_hour_counts_what_its_readings_added(self):
        readings = [(0, 3), (1000, 5), (3500, 6), (3700, 6), (7000, 10), (7300, 11)]
        self.assertEqual(soak.per_hour(readings, 2), [3, 5])  # 7300 s is past the last full hour: it joins hour 2

    def test_an_hour_with_no_reading_counts_zero(self):
        self.assertEqual(soak.per_hour([(0, 0), (100, 2), (8000, 4)], 3), [2, 0, 2])

    def test_a_soak_shorter_than_an_hour_has_one_bucket(self):
        self.assertEqual(soak.per_hour([(0, 1), (600, 4)], 1), [3])


class Growth(unittest.TestCase):
    def test_the_slope_is_per_hour(self):
        points = [(t, 100 + 50 * t / 3600) for t in (0, 1800, 3600, 9000)]
        self.assertAlmostEqual(soak.slope_per_hour(points), 50)

    def test_under_two_distinct_times_there_is_no_slope(self):
        self.assertIsNone(soak.slope_per_hour([(10, 1)]))
        self.assertIsNone(soak.slope_per_hour([(10, 1), (10, 2)]))


class GapReading(unittest.TestCase):
    def test_wakeups_count_only_processes_that_ran_through_the_window(self):
        before = {1: soak.ProcessReading("app", 10, 100), 2: soak.ProcessReading("cef-gpu", 5, 50),
                  3: soak.ProcessReading("cef-renderer", 5, 500)}
        after = {1: soak.ProcessReading("app", 12, 160), 2: soak.ProcessReading("cef-renderer", 6, 10),
                 4: soak.ProcessReading("cef-renderer", 7, 9999)}
        gap = soak.gap_reading(0, 100.0, 1, before, after, 10.0)
        self.assertEqual(gap.wakeups_per_s, 6.0)  # pid 2 changed kind (a reused pid), 3 ended, 4 started
        self.assertEqual(gap.churned, 3)
        self.assertEqual((gap.footprint, gap.app_footprint), (25, 12))
        self.assertEqual(gap.kinds, {"app": 12, "cef-renderer": 13})


class Counters(unittest.TestCase):
    def test_a_build_without_the_methods_is_not_measurable_at_the_first_read(self):
        def rpc(method, params=None, timeout=60):
            return {"error": {"code": "method_not_found"}}
        with self.assertRaises(soak.NotMeasurable):
            soak.read_counters(rpc, first=True)
        with self.assertRaises(soak.SoakError) as raised:
            soak.read_counters(rpc)
        self.assertNotIsInstance(raised.exception, soak.NotMeasurable)

    def test_a_watchdog_that_does_not_run_fails(self):
        with self.assertRaisesRegex(soak.SoakError, "watchdog"):
            soak.read_counters(lambda m, p=None, t=60: {"installed": False, "count250": 0}, first=True)


# ---------------------------------------------------------------- the soak


class SoakRun(unittest.TestCase):
    def test_one_launch_plays_the_stories_in_turn_and_writes_the_soak_metrics(self):
        fx = SoakFixture(self)
        report = fx.run()
        self.assertTrue(report.ok, report.summary())
        self.assertEqual(len(fx.benches), 1)
        bench = fx.benches[0]
        self.assertTrue(bench.launched and bench.stopped)
        self.assertEqual(fx.processes.before_launch_calls, 1)
        self.assertEqual(bench.session, "corpus:fixture-soak")
        stories = [c.story for c in report.cycles]
        self.assertEqual(stories[:4], ["fixture-a", "fixture-b", "fixture-a", "fixture-b"])
        self.assertEqual(len(fx.imports), len(report.cycles))
        for cycle in report.cycles:  # every loop reaches the recorded checkpoints
            self.assertEqual([c["name"] for c in cycle.replay["checkpoints"]], ["start", "midpoint", "late", "end"])
        self.assertGreaterEqual(report.cycles[-1].start_s * 1000, 2 * 3600 * 1000 - GAP_MS - 60_000)
        self.assertLess(report.cycles[-1].start_s * 1000, 2 * 3600 * 1000)
        metrics = {r["metric"]: r for r in bench.records}
        self.assertEqual(sorted(metrics), sorted(f"corpus.fixture_soak.{key}" for key, _ in soak.SERIES))
        self.assertTrue(all(r["story"] == "fixture-soak" and r["session"] == "corpus:fixture-soak"
                            for r in bench.records))
        hangs = metrics["corpus.fixture_soak.hangs_over_250ms"]["samples"]
        self.assertEqual(len(hangs), 2)
        self.assertEqual(sum(hangs), 2 * len(report.cycles))  # two tab.focus events per cycle
        self.assertEqual(metrics["corpus.fixture_soak.browser_crashes"]["samples"], [0.0, 0.0])
        self.assertAlmostEqual(metrics["corpus.fixture_soak.footprint_growth_per_hour.total"]["samples"][0],
                               GROWTH_PER_HOUR, delta=GROWTH_PER_HOUR * 0.01)
        self.assertAlmostEqual(metrics["corpus.fixture_soak.footprint_growth_per_hour.app"]["samples"][0],
                               APP_GROWTH_PER_HOUR, delta=APP_GROWTH_PER_HOUR * 0.01)
        wakeups = metrics["corpus.fixture_soak.idle_wakeups"]
        self.assertEqual(len(wakeups["samples"]), len(report.cycles))
        self.assertTrue(all(abs(w - WAKEUPS_PER_S) < 0.01 for w in wakeups["samples"]))
        self.assertEqual((wakeups["unit"], wakeups["better"]), ("per_s", "lower"))
        summary = json.loads((fx.play_fixture.dir / "out" / "soak-summary.json").read_text())
        self.assertTrue(summary["ok"])
        self.assertEqual(len(summary["gaps"]), len(report.cycles))

    def test_each_gap_is_idle_at_one_workspace_and_its_window_has_no_socket_call(self):
        fx = SoakFixture(self, duration_ms=3600 * 1000)
        report = fx.run()
        self.assertEqual(fx.apps[0].gap_calls, [])
        self.assertTrue(all(g.workspaces == 1 for g in report.gaps))
        reads = fx.processes.reads
        self.assertEqual(len(reads), 2 * len(report.gaps))
        for (_, app, settled), (_, _, end) in zip(reads[::2], reads[1::2]):
            self.assertEqual(app, "/x/cmux DEV t.app")
            self.assertEqual(end - settled, (GAP_MS / 1000 - soak.GAP_SETTLE_S) * 1e9)
        self.assertTrue(all(g.measured_s == GAP_MS / 1000 - soak.GAP_SETTLE_S for g in report.gaps))

    def test_the_growth_fit_leaves_out_the_warm_up_pass(self):
        fx = SoakFixture(self, duration_ms=3600 * 1000)

        def warm_up_then_flat(app_pid, app):  # the first pass (2 stories) grows by 1 GB; then nothing moves
            gap = len(fx.processes.reads) // 2
            fx.processes.reads.append((app_pid, app, fx.clock.now_ns()))
            footprint = 1_000_000 * (gap + 1) if gap < 2 else 1_000_000_000
            return {7: soak.ProcessReading("app", footprint, 0)}
        fx.processes.read = warm_up_then_flat
        report = fx.run()
        self.assertEqual(sorted({g.cycle for g in report.gaps if g.footprint < 1_000_000_000}), [0, 1])
        self.assertGreater(len(report.gaps), 3)
        self.assertEqual(report.metrics["corpus.fixture_soak.footprint_growth_per_hour.total"], [0.0])
        self.assertEqual(report.metrics["corpus.fixture_soak.footprint_growth_per_hour.app"], [0.0])

    def test_a_soak_too_short_for_two_steady_gaps_leaves_growth_unmeasured(self):
        fx = SoakFixture(self, duration_ms=60_000)
        report = fx.run()
        self.assertTrue(report.ok)
        self.assertIn("corpus.fixture_soak.footprint_growth_per_hour.total", report.unmeasured)
        self.assertNotIn("corpus.fixture_soak.footprint_growth_per_hour.total", report.metrics)
        self.assertIn("corpus.fixture_soak.hangs_over_250ms", report.metrics)

    def test_chromium_failures_land_in_their_hour(self):
        fx = SoakFixture(self, duration_ms=2 * 3600 * 1000)
        original = fx.processes.read

        def crash_late(app_pid, app):
            if fx.clock.now_ns() > 1.5 * HOUR_NS:
                fx.apps[-1].crashes = 3
            return original(app_pid, app)
        fx.processes.read = crash_late
        report = fx.run()
        self.assertEqual(report.metrics["corpus.fixture_soak.browser_crashes"], [0.0, 3.0])

    def test_the_web_replay_and_agents_start_once_before_the_launch(self):
        fx = SoakFixture(self, duration_ms=3600 * 1000, web_story="fixture-a", agent_story="fixture-b")
        report = fx.run()
        self.assertTrue(report.ok, report.summary())
        self.assertEqual([s for s in fx.web.served if s != "stopped"][0][0], b"wpr fixture-a")
        self.assertEqual(fx.web.served[-1], "stopped")
        self.assertEqual(len([s for s in fx.web.served if s != "stopped"]), 1)
        self.assertEqual(len(fx.agents.staged), 1)
        env = fx.benches[0].env
        self.assertIn("CMUX_NEXT_BENCH_CEF_SWITCHES", env)
        self.assertIn("CMUX_NEXT_ACPMUX_ROOT", env)

    def test_two_web_archives_are_refused_before_launch(self):
        fx = SoakFixture(self, stories=("fixture-a", "fixture-b", "fixture-c"), web_story="fixture-a")
        manifest = json.loads((fx.root / "perf-corpus" / "fixture-a.json").read_text())
        other = copy.deepcopy(manifest)
        other["id"] = "fixture-c"
        other["web_archive"]["wprgo"] = fx.play_fixture.add_blob(b"another archive")
        (fx.root / "perf-corpus" / "fixture-c.json").write_text(json.dumps(other))
        with self.assertRaisesRegex(soak.SoakError, "one Web Page Replay server"):
            fx.run()
        self.assertEqual(fx.benches, [])

    def test_a_planned_composed_story_is_refused_before_launch(self):
        fx = SoakFixture(self)
        path = fx.root / "perf-corpus" / "fixture-b.json"
        manifest = json.loads(path.read_text())
        manifest["status"], manifest["planned"] = "planned", "Not yet."
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(soak.SoakError, "fixture-b.*planned"):
            fx.run()
        self.assertEqual(fx.benches, [])

    def test_a_soak_manifest_with_another_workspace_count_is_refused(self):
        fx = SoakFixture(self)
        fx.soak_manifest["layout"]["workspaces"] = 40
        fx.write()
        with self.assertRaisesRegex(soak.SoakError, "layout.workspaces"):
            fx.run()

    def test_a_failed_cycle_is_counted_and_the_soak_goes_on(self):
        digests = fakes.recorded_digests()
        fx = SoakFixture(self, duration_ms=3600 * 1000, digests=digests)
        broken = json.loads((fx.root / "perf-corpus" / "fixture-b.json").read_text())
        broken["checkpoints"][1]["surfaces"] = "0" * 64
        (fx.root / "perf-corpus" / "fixture-b.json").write_text(json.dumps(broken))
        report = fx.run()
        failed = [c for c in report.cycles if not c.ok]
        self.assertTrue(failed and all(c.story == "fixture-b" for c in failed))
        self.assertTrue(all("checkpoint midpoint" in c.reason for c in failed))
        self.assertIsNone(report.ended)  # fixture-a passes between them, so no three fail in a row
        self.assertFalse(report.ok)
        self.assertGreater(len(report.cycles), 3)

    def test_failures_in_a_row_end_the_soak_with_its_metrics(self):
        fx = SoakFixture(self, stories=("fixture-a",))
        broken = json.loads((fx.root / "perf-corpus" / "fixture-a.json").read_text())
        broken["checkpoints"][0]["focus"] = "0" * 64
        (fx.root / "perf-corpus" / "fixture-a.json").write_text(json.dumps(broken))
        report = fx.run()
        self.assertEqual(len(report.cycles), soak.MAX_CONSECUTIVE_FAILURES)
        self.assertRegex(report.ended, "3 cycles in a row failed")
        self.assertIn("corpus.fixture_soak.hangs_over_250ms", report.metrics)
        self.assertTrue(fx.benches[0].stopped)

    def test_an_app_that_exits_ends_the_soak(self):
        fx = SoakFixture(self)
        original = fx.processes.read

        def die(app_pid, app):
            readings = original(app_pid, app)
            if fx.clock.now_ns() > 0.5 * HOUR_NS:
                fx.benches[0].process.code = -11
            return readings
        fx.processes.read = die
        report = fx.run()
        self.assertRegex(report.ended, r"the app exited \(code -11\)")
        self.assertFalse(report.ok)
        self.assertEqual(len(report.metrics.get("corpus.fixture_soak.hangs_over_250ms", [])), 1)  # only hours it ran
        self.assertFalse(report.cycles[-1].ok)
        self.assertTrue(fx.benches[0].stopped)

    def test_a_reset_that_does_not_close_the_workspaces_ends_the_soak(self):
        fx = SoakFixture(self)
        original = fx.make_bench

        def stubborn(*args, **kwargs):
            bench = original(*args, **kwargs)
            bench.app.refuse_close = True
            return bench
        fx.soak.make_bench = stubborn
        report = fx.run()
        self.assertEqual(len(report.cycles), 1)
        self.assertRegex(report.ended, "old workspaces did not close")
        self.assertEqual(report.gaps, [])

    def test_a_build_without_debug_crashes_is_not_measurable(self):
        fx = SoakFixture(self)
        original = SoakApp.handle

        def handle(app, method, params, now):
            if method == "debug.crashes":
                return {"error": {"code": "method_not_found"}}
            return original(app, method, params, now)
        with unittest.mock.patch.object(SoakApp, "handle", handle):
            code = soak.main([str(fx.path), "--app", "/x/cmux DEV t.app", "--out", str(fx.play_fixture.dir / "o")],
                             soak=fx.soak)
        self.assertEqual(code, soak.EXIT_NOT_MEASURABLE)
        self.assertTrue(fx.benches[0].stopped)

    def test_main_prints_the_report_line(self):
        fx = SoakFixture(self, duration_ms=3600 * 1000)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = soak.main([str(fx.path), "--app", "/x/cmux DEV t.app", "--out", str(fx.play_fixture.dir / "o"),
                              "--duration-ms", "1200000"], soak=fx.soak)
        self.assertEqual(code, soak.EXIT_OK)
        line = json.loads(out.getvalue().split("CORPUS-SOAK ", 1)[1])
        self.assertTrue(line["ok"])
        self.assertEqual(line["cycles"], 2)  # 20 minutes: each cycle is its 10 minute gap


# ---------------------------------------------------------------- the checked-in story


class CheckedIn(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((REPO_ROOT / "perf-corpus" / "long-day-soak.json").read_text())
        self.story = json.loads((REPO_ROOT / "scripts" / "perf-lab" / "stories.d" / "long-day-soak.json").read_text())
        self.written = [f"corpus.long_day_soak.{key}" for key, _ in soak.SERIES]

    def test_the_manifest_composes_the_three_stories_for_eight_hours_at_one_workspace(self):
        corpus = play.corpus_manifest()
        known = frozenset(p.stem for p in play.corpus_paths(REPO_ROOT))
        self.assertEqual(corpus.validation_errors(self.manifest, root=REPO_ROOT, stories=known), [])
        self.assertEqual(self.manifest["compose"]["stories"], ["agent-swarm", "dev-loop", "browse-heavy"])
        self.assertEqual(self.manifest["duration_ms"], 8 * 3600 * 1000)
        self.assertEqual(self.manifest["layout"]["workspaces"], soak.RESET_WORKSPACES)
        self.assertEqual(self.manifest["tier"], "T2")

    def test_every_metric_soak_writes_is_declared_with_its_unit_in_both_files(self):
        units = dict(soak.SERIES)
        for doc in (self.manifest, self.story):
            for metric in self.written:
                spec = play.declared(doc, metric)
                self.assertIsNotNone(spec, f"{doc['id']} does not declare {metric}")
                self.assertEqual(spec["unit"], units[metric.split(".", 2)[2]])
            self.assertTrue(all(any(re.fullmatch(m["name"], w) for w in self.written) for m in doc["metrics"]))

    def test_the_lab_story_runs_soak_py_on_the_manifest_and_lints(self):
        self.assertEqual(self.story["command"], ["scripts/perf-lab/corpus/soak.py", "perf-corpus/long-day-soak.json"])
        self.assertEqual(self.story["session"], f"corpus:{self.manifest['id']}")
        self.assertEqual(self.story["seconds"] * 1000, self.manifest["duration_ms"])
        loaded = catalog.load_catalog(REPO_ROOT)
        self.assertEqual([p for p in loaded.problems if "long-day-soak" in p], [])
        self.assertIn("long-day-soak", {s.id for s in loaded.stories})


if __name__ == "__main__":
    unittest.main()

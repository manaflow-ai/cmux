#!/usr/bin/env python3
"""The browser engine benches' result-v1 series (browser_engine_bench_report.py, p12-perf-process-058): the names the
lab stories claim, the missed-run counts, the perf_stats percentiles against the private ones they replace, the
story commands through each bench's own parser, and one run's series through BenchApp.record and perf-lab ingest.

Runs on any host (Linux included): no app, no socket, no fleet, no network.

    python3 -m unittest scripts/cmux-next/tests/test_browser_engine_bench_report.py
"""

from __future__ import annotations

import ast
import importlib.util
import io
import json
import re
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
PERF_LAB = HERE.parent / "perf-lab"
STORIES = PERF_LAB / "stories.d"
sys.path.insert(0, str(HERE))
import bench_launch  # noqa: E402
import browser_engine_bench_report as report  # noqa: E402


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ingest = load("perf_lab_ingest", PERF_LAB / "ingest.py")
pr = report.perf_result
store = ingest.store

VECTOR = [3.1, 4.0, 4.2, 5.5, 6.0, 7.9, 8.3, 9.0, 12.4, 20.1]
SHA = "b" * 40
CHIP = "Apple M4 Pro"
HOST = pr.Host(fingerprint="e" * 64, host_class=store.host_class(chip=CHIP, memory_gb=24, display_hz=120), chip=CHIP,
               macos="26.1", macos_build="25B78", display_hz=120)
BUILD = pr.Build(sha=SHA, config="bench", measure_version=2)
STORY_IDS = ("browser-hibernation", "browser-hibernation-webkit", "renderer-sharing", "chromium-host",
             "remote-browser-media")


# The private percentiles the four benches had before the migration (R8: old and new on one fixed vector).
def old_index_by_length(values, q):  # bench_hibernation.py and bench_renderer_sharing.py percentile
    values = sorted(v for v in values if v is not None)
    return values[min(len(values) - 1, int(len(values) * q))] if values else None


def old_round_rank(values, q):  # chromium-host-bench.py percentiles, remote-browser-local-live.py pct
    s = sorted(values)
    return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]


def old_probe_page(values, q):  # chromium-host-bench.py's probe page pct (JavaScript Math.round: half up)
    s = sorted(values)
    return s[int(q * (len(s) - 1) + 0.5)]


def story(story_id):
    return json.loads((STORIES / f"{story_id}.json").read_text())


def claimed(doc, series):
    """The story metric that full-matches the series' name with its unit and direction, or None."""
    return next((m for m in doc["metrics"] if re.fullmatch(m["name"], series.metric) and m["unit"] == series.unit
                 and m["better"] == series.better), None)


def proc(pid, kind, mb, cpu=None, wakeups=None):
    row = {"pid": pid, "kind": kind, "footprint_mb": mb, "footprint_bytes": int(mb * 1048576)}
    if cpu is not None:
        row.update(cpu_pct=cpu, wakeups_per_s=wakeups)
    return row


def wake_row(engine="chromium", mounted=40, usable=120, restored=130, app_mounted=30, loaded=110, scroll=True,
             form=True):
    return {"tab": "tab_1", "engine": engine, "mounted_ms": mounted, "usable_ms": usable, "restored_ms": restored,
            "app_mounted_ms": app_mounted, "loaded_ms": loaded, "scroll_ok": scroll, "form_ok": form}


def hibernation_series(engine="chromium"):
    gone = [proc(11, "cef-renderer", 100.0, cpu=0.5, wakeups=4.0), proc(12, "cef-renderer", 80.0, cpu=0.25, wakeups=2.0)]
    frozen = [proc(11, "cef-renderer", 100.0, cpu=0.0, wakeups=0.5)] if engine == "chromium" else None
    wakes = [wake_row(engine), wake_row(engine, usable=None, restored=None, scroll=False), wake_row(engine, form=False)]
    return report.hibernation_series(engine, 2, gone, wakes, frozen)


def renderer_series():
    sample = {"total_footprint_bytes": 9_000_000_000,
              "processes": [proc(1, "app", 300.0), proc(2, "cef-renderer", 120.0), proc(3, "cef-renderer", 80.0)]}
    return report.renderer_sharing_series([250, None, 310, 280], 2, 1, sample)


def chromium_host_series():
    samples = {"inproc": {"key_to_paint": [9.0, 11.0, None], "key_to_raf": [4.0, 5.0], "click_to_paint": [10.0],
                          "click_to_raf": [5.5], "raf_interval": [8.3, 8.4, 16.7]},
               "helper": {"key_to_paint": [12.0, 13.0], "raf_interval": []}}
    modes = {"inproc": {"long_frames": 1, "pump_share": {"light": {"idle": {"share": 0.01}, "scroll": {"share": 0.2}},
                                                         "stress": {"idle": {"share": 0.05}}}},
             "helper": {"error": "the host page never showed"}}
    return report.chromium_host_series(samples, modes)


def remote_series():
    numbers = {"motion": {"fps": 58.5, "windows": 8}, "still": {"frames": 0, "bytes": 0, "windows": 4},
               "tap": {"windows": 8}}
    return report.remote_browser_series(numbers, [21.0, 25.5, 19.0], 5)


class PercentileTests(unittest.TestCase):
    def test_fixed_vector_old_private_percentiles_and_the_perf_stats_ones(self):
        self.assertEqual([old_index_by_length(VECTOR, q) for q in (.5, .9, .95)], [7.9, 20.1, 20.1])
        self.assertEqual([old_round_rank(VECTOR, q) for q in (.5, .95, .99)], [6.0, 20.1, 20.1])
        self.assertEqual([old_probe_page(VECTOR, q) for q in (.5, .95)], [7.9, 20.1])
        new = {q: report.pct(VECTOR, q) for q in (.5, .9, .95, .99, 1)}
        self.assertEqual(new, {.5: 6.95, .9: 13.17, .95: 16.63, .99: 19.41, 1: 20.1})

    def test_pct_and_percentiles_are_perf_stats_and_skip_missing_values(self):
        for q in (.5, .95, .99):
            self.assertEqual(report.pct(VECTOR, q, 3), round(report.perf_stats.pct(VECTOR, q), 3))
        self.assertIsNone(report.pct([None, None], .95))
        self.assertEqual(report.pct([None, 4.0, True], .5), 4.0, "None and booleans are not samples")
        self.assertIsInstance(report.pct([250, 310], .5, None), int)
        self.assertEqual(report.percentiles(VECTOR + [None]),
                         {"n": 10, "p50": 6.95, "p95": 16.635, "p99": 19.407, "max": 20.1})
        self.assertIsNone(report.percentiles([None]))


class SeriesTests(unittest.TestCase):
    def test_hibernation_freed_bytes_cpu_frozen_and_wakes(self):
        by_name = {s.metric: s for s in hibernation_series()}
        freed = by_name["hibernation.freed_per_tab"]
        self.assertEqual((freed.unit, freed.better, freed.samples), ("bytes", "higher", [90 * 1048576]))
        self.assertEqual(by_name["hibernation.hidden_cpu"].samples, [0.75])
        self.assertEqual(by_name["hibernation.frozen_wakeups"].samples, [0.5])
        self.assertEqual(by_name["hibernation.wake.usable"].samples, [120, 120])
        self.assertEqual(by_name["hibernation.wake.usable.missed_runs"].samples, [1])
        self.assertEqual(by_name["hibernation.wake.mounted.missed_runs"].samples, [0])
        self.assertEqual((by_name["hibernation.wake.scroll_lost"].samples, by_name["hibernation.wake.form_lost"].samples),
                         ([1], [1]))
        self.assertEqual({s.story for s in by_name.values()}, {"browser-hibernation"})

    def test_hibernation_webkit_arm_is_its_own_story_without_a_frozen_phase(self):
        series = hibernation_series("webkit")
        self.assertEqual({(s.story, s.engine) for s in series}, {("browser-hibernation-webkit", "webkit")})
        self.assertFalse([s for s in series if "frozen" in s.metric])

    def test_renderer_sharing_counts_a_tab_that_showed_no_title_as_missed(self):
        by_name = {s.metric: s for s in renderer_series()}
        self.assertEqual(by_name["renderer_sharing.new_tab"].samples, [250, 310, 280])
        self.assertEqual(by_name["renderer_sharing.new_tab.missed_runs"].samples, [1])
        self.assertEqual(by_name["renderer_sharing.renderer_footprint"].samples, [200 * 1048576])
        self.assertEqual(by_name["renderer_sharing.total_footprint"].samples, [9_000_000_000])
        self.assertEqual((by_name["renderer_sharing.renderers"].samples, by_name["renderer_sharing.tab_renderers"].samples),
                         ([2], [1]))

    def test_chromium_host_records_only_the_runs_session_and_measured_values(self):
        by_name = {s.metric: s for s in chromium_host_series()}
        self.assertEqual(by_name["chromium_host.light.inproc.key_to_paint"].samples, [9.0, 11.0])
        self.assertEqual(by_name["chromium_host.light.inproc.key_to_paint.missed_runs"].samples, [1])
        self.assertEqual(by_name["chromium_host.light.inproc.pump_share.scroll"].samples, [0.2])
        self.assertEqual(by_name["chromium_host.light.inproc.long_frames"].samples, [1])
        self.assertNotIn("chromium_host.stress.inproc.pump_share.idle", by_name, "one story run is one session")
        self.assertNotIn("chromium_host.light.helper.raf_interval", by_name, "no frame was measured")
        self.assertEqual(by_name["chromium_host.light.helper.raf_interval.missed_runs"].samples, [1],
                         "a mode that ran with no frame interval is a missed pacing run")
        self.assertEqual(by_name["chromium_host.light.inproc.raf_interval"].samples, [8.3, 8.4, 16.7])
        self.assertEqual(by_name["chromium_host.light.inproc.raf_interval.missed_runs"].samples, [0])
        self.assertNotIn("chromium_host.light.helper.long_frames", by_name)
        self.assertEqual({s.session for s in by_name.values()}, {"light"})

    def test_remote_browser_pads_clicks_the_host_answered_with_no_frame(self):
        by_name = {s.metric: s for s in remote_series()}
        self.assertEqual(by_name["remote_browser.tap.input_to_frame"].samples, [21.0, 25.5, 19.0])
        self.assertEqual(by_name["remote_browser.tap.input_to_frame.missed_runs"].samples, [2])
        self.assertEqual((by_name["remote_browser.motion.fps"].better, by_name["remote_browser.still.frames"].samples),
                         ("higher", [0]))
        more = report.remote_browser_series({"motion": {}, "still": {}}, [1.0, 2.0, 3.0], 2)
        self.assertEqual({s.metric: s.samples for s in more}["remote_browser.tap.input_to_frame"], [1.0, 2.0])

    def test_out_paths_keep_a_json_report_and_make_a_runner_folder(self):
        self.assertEqual(report.out_paths(None, "r.json"), (None, None))
        self.assertEqual(report.out_paths("/x/report.json", "r.json"), ("/x/report.json", None))
        with tempfile.TemporaryDirectory() as tmp:
            folder = str(Path(tmp) / "out")
            self.assertEqual(report.out_paths(folder, "r.json"), (str(Path(folder) / "r.json"), folder))
            self.assertTrue(Path(folder).is_dir())


class StoryTests(unittest.TestCase):
    RUNNER = ["--app", "/x/cmux DEV t.app", "--tag", "t", "--out", "/x/out"]  # what the story runner adds

    def test_every_series_a_story_runs_is_claimed_by_it(self):
        series = (hibernation_series() + hibernation_series("webkit") + renderer_series() + chromium_host_series()
                  + remote_series())
        for story_id in STORY_IDS:
            doc = story(story_id)
            mine = [s for s in series if s.story == story_id]
            self.assertTrue(mine, f"no series for {story_id}")
            for s in mine:
                self.assertEqual((s.engine, s.session), (doc["engine"], doc["session"]), s.metric)
                self.assertIsNotNone(claimed(doc, s), f"{story_id} claims no metric {s.metric} ({s.unit}, {s.better})")

    def parsed(self, story_id, script, name):
        """The story's command, plus the runner's flags, through its bench's own parser. bench_power loads libproc at
        import (macOS only); the parse never calls it, so a stand-in module takes its place here."""
        command = story(story_id)["command"]
        self.assertEqual(command[0], f"scripts/cmux-next/{script}")
        stand_in = types.ModuleType("bench_power")
        with mock.patch.dict(sys.modules, {"bench_power": sys.modules.get("bench_power", stand_in)}):
            bench = load(name, HERE / script)
        return bench.parse(command[1:] + self.RUNNER)

    def test_story_commands_parse_with_their_bench(self):
        for story_id, engines in (("browser-hibernation", "chromium"), ("browser-hibernation-webkit", "webkit")):
            args = self.parsed(story_id, "bench_hibernation.py", "bench_hibernation_058")
            self.assertEqual((args.engines, args.tabs, args.out, args.session), (engines, 6, "/x/out", "light"))
            self.assertEqual(report.hibernation_story(args.engines), story_id)
        sharing = self.parsed("renderer-sharing", "bench_renderer_sharing.py", "bench_renderer_sharing_058")
        self.assertEqual((sharing.tabs, sharing.sites, sharing.out), (60, 20, "/x/out"))
        host = self.parsed("chromium-host", "chromium-host-bench.py", "chromium_host_bench_058")
        self.assertEqual((host.count, host.modes, host.story, host.stress), (60, "inproc,helper", "chromium-host", False))

    def test_a_runner_tag_that_is_not_the_apps_is_refused(self):
        bench = load("chromium_host_bench_058", HERE / "chromium-host-bench.py")
        with self.assertRaises(SystemExit), mock.patch("sys.stderr", io.StringIO()):
            bench.parse(["--app", "/x/cmux DEV t.app", "--out", "/x/out", "--tag", "other"])

    def test_remote_browser_script_takes_the_runner_flags_and_the_story_flags(self):
        tree = ast.parse((HERE / "remote-browser-local-live.py").read_text())
        flags = {node.args[0].value for node in ast.walk(tree)
                 if isinstance(node, ast.Call) and getattr(node.func, "attr", "") == "add_argument"
                 and node.args and isinstance(node.args[0], ast.Constant)}
        self.assertLessEqual({"--app", "--tag", "--out", "--bundled", "--stats", "--session"}, flags)
        self.assertLessEqual(set(story("remote-browser-media")["command"][1:]), flags)

    def test_the_catalog_lints_the_new_stories_clean(self):
        catalog = load("perf_lab_catalog", PERF_LAB / "catalog.py").load_catalog()
        self.assertLessEqual(set(STORY_IDS), {s.id for s in catalog.stories})
        self.assertEqual([p for p in catalog.problems if any(i in p for i in STORY_IDS)], [])

    def test_the_four_benches_keep_no_private_stats_and_report_p99(self):
        queues = load("perf_lab_queues", PERF_LAB / "queues.py")
        mine = {f"scripts/cmux-next/{name}" for name in ("bench_hibernation.py", "bench_renderer_sharing.py",
                                                         "chromium-host-bench.py", "remote-browser-local-live.py")}
        root = str(HERE.parent.parent)
        for query in (queues.private_stats, queues.self_launch, queues.p95_without_p99):
            self.assertEqual([i.key for i in query(root) if i.key in mine], [], query.__name__)


# The probe page's script under node's vm with a stand-in DOM and a stepped clock: the bench's own order of input in
# helper mode (chromium-host-bench.py drive, run_helper's identity clicks, input_rows), then the longest title it
# reported and the lists drive() reads. Frame and event times have the widest values a run gives (two-digit deltas,
# a 13-digit wall clock with 3 decimals).
PROBE_HARNESS = r"""
const vm = require('node:vm');
const fs = require('node:fs');
const [script, count, hz] = [fs.readFileSync(process.argv[2], 'utf8'), +process.argv[3], +process.argv[4]];
let now = 13456.789, longest = 0, title = '';
const queue = [], handlers = {};
const element = id => ({id, style: {}, textContent: '', value: '', selectionStart: 0,
                        classList: {add() {}, remove() {}}});
const elements = Object.fromEntries(['t', 'b', 'box', 's', 'al', 'f'].map(id => [id, element(id)]));
const ctx = {
  performance: {timeOrigin: 1793000000000, now: () => now},
  requestAnimationFrame: cb => queue.push(cb),
  addEventListener: (type, fn) => (handlers[type] = handlers[type] || []).push(fn),
  alert() {},
  document: {
    getElementById: id => elements[id], addEventListener() {}, hasFocus: () => true, activeElement: elements.t,
    get title() { return title; }, set title(v) { title = v; longest = Math.max(longest, v.length); },
  },
};
ctx.window = ctx;
vm.createContext(ctx);
vm.runInContext(script, ctx);
const period = 1000 / hz;
let jitter = 0;
function frame() {
  now += period + (jitter++ % 3) * 0.013;
  queue.splice(0).forEach(cb => cb(now));
}
function fire(type, fields) {
  (handlers[type] || []).forEach(h => h({preventDefault() {}, ...fields}));
  now += 0.37; frame(); frame();
}
const key = k => fire('keydown', {key: k, target: elements.t});
const click = id => fire('mousedown', {target: elements[id]});
const state = () => JSON.parse(title.slice('probe '.length));
click('t');                                   // drive: the focus click
for (let i = 0; i < count; i++) key('a');
for (let i = 0; i < count; i++) click('b');
const drive = state();
key('p');                                     // the 3 s pacing run
const end = now + 3100;
while (now < end) frame();
const paced = state().raf_raw.length;
key('r');
for (let i = 0; i < 10; i++) { click('b'); key('a'); }   // run_helper's identity clicks
click('t'); for (let i = 0; i < 5; i++) key('a');         // input_rows: typing, focus, copy and paste, natives
click('t'); ['a', 'c', 'delete', 'v'].forEach(key); ['s', 'al', 'f', 't'].forEach(click);
console.log(JSON.stringify({longest, key_raw: drive.key_raw.length, click_raw: drive.click_raw.length,
                            click_paint: drive.click_paint.length, paced, raf_after: state().raf_raw.length}));
"""


@unittest.skipUnless(shutil.which("node"), "the probe page runs under node")
class ProbePageTests(unittest.TestCase):
    def run_probe(self, count, hz):
        bench = load("chromium_host_bench_058", HERE / "chromium-host-bench.py")
        script = re.search(r"<script>(.*)</script>", bench.PAGE, re.S).group(1)
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "page.js").write_text(script)
            (Path(tmp) / "harness.js").write_text(PROBE_HARNESS)
            done = subprocess.run(["node", str(Path(tmp) / "harness.js"), str(Path(tmp) / "page.js"), str(count),
                                   str(hz)], capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        return bench, json.loads(done.stdout)

    def test_the_title_stays_below_blinks_limit_through_a_helper_run(self):
        for hz in (60, 120):
            bench, got = self.run_probe(60, hz)
            self.assertLess(got["longest"], bench.TITLE_LIMIT, f"{hz} Hz: {got}")
            self.assertGreaterEqual(got["paced"], 3 * hz - 2, f"{hz} Hz: the pacing run reported its intervals")
            self.assertEqual(got["raf_after"], 0, "`r` drops the intervals the bench read")

    def test_the_lists_drive_reads_hold_exactly_its_measured_events(self):
        _, got = self.run_probe(60, 60)
        self.assertEqual((got["key_raw"], got["click_raw"], got["click_paint"]), (60, 60, 60),
                         "the focus click is not a sample: drive's clicks start each list")


class RecordTests(unittest.TestCase):
    def bench_app(self, tmp, out):
        """A real BenchApp (its record, its run handling) with the launch's snapshot, build and host filled in."""
        bundle = Path(tmp) / "cmux DEV be058.app"
        bundle.mkdir()
        app = bench_launch.BenchApp(str(bundle), out=str(out), teardown=False)
        app.features, app._build, app._host = ({}, None, None), BUILD, HOST
        return app

    def test_record_all_writes_every_story_and_ingest_stores_them(self):
        series = hibernation_series() + hibernation_series("webkit") + renderer_series() + chromium_host_series()
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "results"
            app = self.bench_app(tmp, out)
            with redirect_stdout(io.StringIO()):
                written = report.record_all(app, series)
            self.assertFalse([v for v in written.values() if v.startswith("not recorded")], written)
            back = pr.read_dir(out)
            self.assertEqual(sorted(r.metric for r in back), sorted(s.metric for s in series))
            freed = next(r for r in back if r.metric == "hibernation.freed_per_tab")
            self.assertEqual(freed.better, "higher")
            db = store.Store(Path(tmp) / "lab.sqlite3")
            db.migrate()
            self.addCleanup(db.close)
            got = ingest.ingest_paths(db, [out], commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
            self.assertEqual(got.rejected, [])
            run_id = app.run.id
            for story_id in ("browser-hibernation", "browser-hibernation-webkit", "renderer-sharing", "chromium-host"):
                self.assertTrue(db.run_metrics(f"{run_id}/{story_id}"), story_id)

    def test_a_series_without_a_launch_snapshot_is_reported_not_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "results"
            app = self.bench_app(tmp, out)
            app.features = None
            with redirect_stdout(io.StringIO()) as printed:
                written = report.record_all(app, remote_series())
            self.assertTrue(all(v.startswith("not recorded") for v in written.values()))
            self.assertIn("result-v1 remote-browser-media/", printed.getvalue())
            self.assertFalse(out.exists() and any(out.glob("*.ndjson")))


if __name__ == "__main__":
    unittest.main()

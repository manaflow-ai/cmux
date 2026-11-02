#!/usr/bin/env python3
"""ext_tiers and tiers_report.py: the start tier of each measured turn (HARNESS CORES, STATUS 7767). No fleet, no ssh.

    python3 scripts/journeys/test_tiers.py

On the M6 minis a main thread that wakes from idle starts on the Efficiency cores and moves to Super after about
25-30 ms of run; a turn that starts on E costs about 2x. These cases use synthetic sampler rows (the format the
sampler writes: [uptime_ns, cpu_ms per tier..., cycles per tier...], cumulative):
- turn_tiers names the start tier, the wall ms to the first Super interval and the E CPU ms before it; a turn that
  starts on Super has 0 ms to Super; a time the sampler does not cover says so;
- start/stop protocol (stand-in samplers): the stop file ends the sampler; no first reading in time is an OSError and
  the sampler process is killed; a sampler that exits non-zero is an OSError at stop; a failed journey's sampler ends
  at the next journey's start; two samplers of one journey both run to their stop;
- video_start starts the sampler on the app's pid for the recording; a sampler that does not start never fails it;
- a driver time (time.monotonic: process-relative on the minis' python 3.9) moves to the host clock of the journal and
  the sampler; video_stop gives each HID action the start tier at its HOST time;
- video_stop writes "tiers" (each key-down and HID action) in the recording's meta.json; a sampler that failed to
  start or fails at stop leaves its error there and the film still completes;
- run.py fetches <case>/video/<name>.tiers.json; video-go.py publishes it;
- tiers_report.py groups the turns of film folders and of diag-tiers folders by arm and start tier; a key the
  sampler does not cover is "uncovered", never "idle".
"""
import io
import json
import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ext_tiers  # noqa: E402

LEVELS = ["Super", "Performance", "Efficiency"]
T0 = 100_000_000_000_000  # ns


def rows(plan, step_ns=1_000_000, start=T0):
    """Cumulative sampler rows from PLAN: a string, one character per 1 ms interval: S / P / E (1 ms of CPU there)
    or '.' (idle). Cycles: 4 GHz on S, 2 GHz elsewhere."""
    cpu, cyc, out = [0.0, 0.0, 0.0], [0, 0, 0], []
    out.append([start] + cpu[:] + cyc[:])
    for i, c in enumerate(plan):
        if c != ".":
            k = "SPE".index(c)
            cpu[k] += 1.0
            cyc[k] += 4_000_000 if k == 0 else 2_000_000
        out.append([start + (i + 1) * step_ns] + [round(x, 4) for x in cpu] + cyc[:])
    return {"levels": LEVELS, "rows": out, "ps": []}


class HostClockTest(unittest.TestCase):
    def test_driver_time_moves_to_the_host_clock(self):
        import time
        clock = getattr(time, "CLOCK_UPTIME_RAW", time.CLOCK_MONOTONIC)
        self.assertAlmostEqual(ext_tiers.host_seconds(time.monotonic()), time.clock_gettime(clock), delta=0.01)


class TurnTiersTest(unittest.TestCase):
    def test_efficiency_start_then_super(self):
        data = rows("." * 10 + "E" * 28 + "S" * 12 + "." * 60)
        [turn] = ext_tiers.turn_tiers(data, [(T0 + 10_000_000) / 1e9])
        self.assertEqual(turn["start_tier"], "Efficiency")
        self.assertEqual(turn["ms_to_super"], 28.0)
        self.assertEqual(turn["e_cpu_ms_before_super"], 28.0)
        self.assertEqual(turn["cpu_ms"], {"Super": 12.0, "Performance": 0.0, "Efficiency": 28.0})

    def test_super_start(self):
        data = rows("." * 5 + "S" * 13 + "." * 100)
        [turn] = ext_tiers.turn_tiers(data, [(T0 + 5_000_000) / 1e9])
        self.assertEqual((turn["start_tier"], turn["ms_to_super"], turn["e_cpu_ms_before_super"]), ("Super", 0.0, 0.0))

    def test_idle_and_uncovered(self):
        data = rows("." * 200)
        idle, early = ext_tiers.turn_tiers(data, [(T0 + 50_000_000) / 1e9, (T0 - 5_000_000) / 1e9])
        self.assertIsNone(idle["start_tier"])
        self.assertIsNone(idle["ms_to_super"])
        self.assertIn("does not cover", early["error"])


class SamplerProcessTest(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "PROC_PIDTHREADCOUNTS is macOS only")
    def test_samples_own_process_until_stopped(self):
        with tempfile.TemporaryDirectory() as tmp:
            handle = ext_tiers.start(os.getpid(), Path(tmp) / "t.tiers.json", seconds=20, interval_ms=1)
            data = ext_tiers.stop(handle)
            self.assertEqual(len(data["levels"]), len(data["rows"][0]) // 2)
            self.assertGreater(len(data["rows"]), 1)
            self.assertFalse(os.path.exists(handle["stop"]))


# Stand-in samplers (same argv as SAMPLER: pid seconds interval_ms out stop): the start/stop protocol on any OS.
FAKE_SAMPLER = r"""
import json, os, sys, time
pid, seconds, interval, out, stop = sys.argv[1:6]
print("ready", flush=True)
end = time.monotonic() + float(seconds)
while time.monotonic() < end and not os.path.exists(stop):
    time.sleep(0.005)
json.dump({"levels": ["Super"], "rows": [[1, 0.0, 0]], "ps": [], "stopped_by_file": os.path.exists(stop)}, open(out, "w"))
"""
SILENT_SAMPLER = "import time\ntime.sleep(30)\n"
BROKEN_SAMPLER = "print('ready', flush=True)\nraise SystemExit(1)\n"


class StartStopProtocolTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "x.tiers.json"

    def tearDown(self):
        ext_tiers.reap()
        self.tmp.cleanup()

    def test_stop_file_ends_the_sampler_and_returns_its_data(self):
        handle = ext_tiers.start(1, self.path, seconds=20, sampler=FAKE_SAMPLER)
        data = ext_tiers.stop(handle)
        self.assertTrue(data["stopped_by_file"])
        self.assertFalse(os.path.exists(handle["stop"]))
        self.assertNotIn(handle, ext_tiers._LIVE)

    def test_no_first_reading_is_an_oserror_and_kills_the_sampler(self):
        before = set(subprocess.run(["ps", "-A", "-o", "pid="], capture_output=True, text=True).stdout.split())
        real_popen, made = subprocess.Popen, []
        def popen(*a, **k):
            made.append(real_popen(*a, **k))
            return made[-1]
        ext_tiers.subprocess.Popen = popen
        try:
            with self.assertRaises(OSError) as raised:
                ext_tiers.start(1, self.path, sampler=SILENT_SAMPLER, timeout=0.5)
        finally:
            ext_tiers.subprocess.Popen = real_popen
        self.assertIn("no first reading", str(raised.exception))
        self.assertEqual(len(made), 1)
        self.assertIsNotNone(made[0].poll(), "the silent sampler still runs")
        self.assertEqual(ext_tiers._LIVE, [])

    def test_a_sampler_that_fails_is_an_oserror_at_stop(self):
        handle = ext_tiers.start(1, self.path, sampler=BROKEN_SAMPLER)
        with self.assertRaises(OSError):
            ext_tiers.stop(handle)

    def test_a_failed_journeys_sampler_ends_at_the_next_journeys_start(self):
        first, second = object(), object()
        stale = ext_tiers.start(1, self.path, seconds=20, sampler=FAKE_SAMPLER, owner=first)
        fresh = ext_tiers.start(1, Path(self.tmp.name) / "y.tiers.json", seconds=20, sampler=FAKE_SAMPLER, owner=second)
        self.assertIsNotNone(stale["proc"].poll())
        self.assertEqual(ext_tiers._LIVE, [fresh])
        ext_tiers.stop(fresh)

    def test_two_samplers_of_one_journey_both_run_to_their_stop(self):
        journey = types.SimpleNamespace(out=Path(self.tmp.name), app=types.SimpleNamespace(pid=1))
        ext_tiers.install(fake_driver())
        saved = ext_tiers.SAMPLER
        ext_tiers.SAMPLER = FAKE_SAMPLER
        try:
            ext_tiers.step_tiers_start(journey, {"name": "a", "seconds": 20})
            ext_tiers.step_tiers_start(journey, {"name": "b", "seconds": 20})
            a = ext_tiers.step_tiers_stop(journey, {"name": "a"})
            b = ext_tiers.step_tiers_stop(journey, {"name": "b"})
        finally:
            ext_tiers.SAMPLER = saved
        self.assertEqual((a["rows"], b["rows"]), (1, 1))
        self.assertTrue(json.loads((Path(self.tmp.name) / "diag-a.json").read_text())["stopped_by_file"])


class FakeProc:
    pass


class VideoStartTiersTest(unittest.TestCase):
    def setUp(self):
        import ext_video
        self.v = ext_video
        self.v.install(fake_driver())
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)
        self.saved = (self.v._motion, self.v.R._journal_last_seq, self.v._bypass_dialog, self.v.T.start, self.v.time)
        replies = {"trace_start": {"views": 2}, "record_start": {"starting": True}, "record_read": {"capturing": True},
                   "trace_read": {"refresh_ms": 8.33}}
        self.v._motion = lambda j, action, **p: replies.get(action, {})
        self.v.R._journal_last_seq = lambda j: 0
        self.v._bypass_dialog = lambda j: None
        real = self.saved[4]
        self.v.time = types.SimpleNamespace(sleep=lambda s: None, monotonic=real.monotonic, time=real.time)
        self.started = []

    def tearDown(self):
        (self.v._motion, self.v.R._journal_last_seq, self.v._bypass_dialog, self.v.T.start, self.v.time) = self.saved
        self.tmp.cleanup()

    def journey(self):
        return types.SimpleNamespace(out=self.out, app=types.SimpleNamespace(pid=4242), video=None)

    def test_video_start_starts_the_sampler_on_the_app_for_the_recording(self):
        def start(pid, path, seconds=120.0, interval_ms=1.0, owner=None):
            self.started.append((pid, str(path), seconds, owner))
            return {"proc": FakeProc()}
        self.v.T.start = start
        j = self.journey()
        reply = self.v.step_video_start(j, {"name": "case", "seconds": 30})
        self.assertEqual(self.started, [(4242, str(self.out / "video" / "case.tiers.json"), 90.0, j)])
        self.assertEqual(reply["tiers"], "sampling")
        self.assertIn("tiers", j.video)

    def test_a_sampler_that_does_not_start_never_fails_video_start(self):
        def start(pid, path, seconds=120.0, interval_ms=1.0, owner=None):
            raise OSError("tiers sampler gave no first reading on pid 4242 within 40.0 s")
        self.v.T.start = start
        j = self.journey()
        reply = self.v.step_video_start(j, {"name": "case"})
        self.assertIn("no first reading", reply["tiers"])
        self.assertIn("no first reading", j.video["tiers_error"])
        self.assertNotIn("tiers", j.video)


def fake_driver():
    class StepError(Exception):
        pass

    class NotRun(Exception):
        pass

    return types.SimpleNamespace(StepError=StepError, NotRun=NotRun, now=lambda: 0.0)


class VideoStopTiersTest(unittest.TestCase):
    def setUp(self):
        import ext_video
        self.v = ext_video
        self.v.install(fake_driver())
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)
        self.saved = (self.v._motion, self.v.R._journal_entries, self.v.R._layers_window, self.v._bypass_dialog, self.v.T.stop)
        self.saved_offset = self.v.T.HOST_OFFSET
        self.v._motion = lambda j, action, **p: {"written": True} if action == "record_read" else {"samples": []}
        key_ns = T0 + 10_000_000
        self.v.R._journal_entries = lambda j, last=40: [
            {"seq": 5, "uptimeNanos": key_ns, "kind": {"key": {"_0": {"phase": "down", "keyClass": "letter"}}}},
            {"seq": 6, "uptimeNanos": key_ns, "kind": {"key": {"_0": {"phase": "flags", "keyClass": "modifier"}}}}]
        self.v.R._layers_window = lambda j: {}
        self.v._bypass_dialog = lambda j: None

    def tearDown(self):
        (self.v._motion, self.v.R._journal_entries, self.v.R._layers_window, self.v._bypass_dialog, self.v.T.stop) = self.saved
        self.v.T.HOST_OFFSET = self.saved_offset
        self.tmp.cleanup()

    def journey(self, rec):
        j = types.SimpleNamespace(out=self.out, app=types.SimpleNamespace(pid=1), video=rec)
        return j

    def rec(self, **extra):
        # t_sent is the driver's clock (process-relative time.monotonic), not the host clock: 3.0 s here.
        self.v.T.HOST_OFFSET = (T0 + 10_000_000) / 1e9 - 3.0
        base = {"name": "case", "t_start": 0.0, "hid": [{"kind": "key", "t_sent": 3.0}],
                "journal_seq": 1, "start": {}, "notes": {}, "trace_views": None, "refresh_ms": 8.33}
        base.update(extra)
        return base

    def test_meta_has_the_start_tier_of_each_turn(self):
        self.v.T.stop = lambda handle, timeout=30.0: rows("." * 10 + "E" * 28 + "S" * 12 + "." * 60)
        j = self.journey(self.rec(tiers={"proc": FakeProc()}))
        self.v.step_video_stop(j, {"name": "case", "tail": 0})
        meta = json.loads((self.out / "video" / "case.meta.json").read_text())
        self.assertEqual(meta["tiers"]["levels"], LEVELS)
        self.assertEqual([t["start_tier"] for t in meta["tiers"]["key_downs"]], ["Efficiency"])
        self.assertEqual(meta["tiers"]["key_downs"][0]["ms_to_super"], 28.0)
        self.assertEqual(meta["tiers"]["hid"][0]["kind"], "key")
        self.assertEqual(meta["tiers"]["hid"][0]["start_tier"], "Efficiency")
        self.assertEqual(meta["tiers"]["hid"][0]["t_sent"], 3.0)
        self.assertNotIn("error", meta["tiers"]["hid"][0])

    def test_a_sampler_that_did_not_start_never_fails_the_film(self):
        j = self.journey(self.rec(tiers_error="tiers sampler did not start on pid 1: boom"))
        self.v.step_video_stop(j, {"name": "case", "tail": 0})
        meta = json.loads((self.out / "video" / "case.meta.json").read_text())
        self.assertIn("boom", meta["tiers"]["error"])

    def test_a_sampler_that_fails_at_stop_never_fails_the_film(self):
        def broken(handle, timeout=30.0):
            raise OSError("tiers sampler failed (1): no rows")
        self.v.T.stop = broken
        j = self.journey(self.rec(tiers={"proc": FakeProc()}))
        self.v.step_video_stop(j, {"name": "case", "tail": 0})
        meta = json.loads((self.out / "video" / "case.meta.json").read_text())
        self.assertIn("no rows", meta["tiers"]["error"])


class FetchAndPublishTest(unittest.TestCase):
    def test_run_fetches_and_video_go_publishes_tiers_files(self):
        import run
        self.assertTrue(run.VIDEO_FILE.fullmatch("rv-case/video/split-1.tiers.json"))
        text = (HERE / "video-go.py").read_text()
        self.assertIn('".tiers.json"', text.split("SUFFIXES = ", 1)[1].split("\n", 1)[0])


def trace_with_motion(key_s, first_after_ms, frames):
    """A debug.motion trace: ticks every 8.33 ms from key - 50 ms; the panes change at each of the FRAMES ticks
    after first_after_ms."""
    t0 = key_s - 0.05
    samples, pane = [], 0
    for i in range(80):
        t = t0 + i * 0.00833
        if 0 < (t - key_s) * 1000 >= first_after_ms and pane < frames:
            pane += 1
        samples.append({"t": (t - t0) * 1000, "panes": [["p", pane]]})
    return {"t0_s": t0, "refresh_ms": 8.33, "samples": samples}


class ReportTest(unittest.TestCase):
    def test_groups_film_and_diag_folders_by_arm_and_start_tier(self):
        key_ns = T0 + 60_000_000
        journal = [{"uptimeNanos": key_ns, "kind": {"key": {"_0": {"phase": "down", "keyClass": "letter"}}}}]
        with tempfile.TemporaryDirectory() as tmp:
            film = Path(tmp) / "case-r01-film"
            (film / "video").mkdir(parents=True)
            (film / "video" / "split.trace.json").write_text(json.dumps(trace_with_motion(key_ns / 1e9, 30, 5)))
            (film / "video" / "split.events.json").write_text(json.dumps({"hid": [], "journal": journal}))
            (film / "video" / "split.meta.json").write_text(json.dumps({"refresh_ms": 8.33}))
            (film / "video" / "split.tiers.json").write_text(json.dumps(rows("." * 60 + "E" * 28 + "S" * 12 + "." * 600)))
            diag = Path(tmp) / "case-r02-diag"
            diag.mkdir()
            trace = trace_with_motion(key_ns / 1e9, 14, 5)
            trace["journal"] = journal
            (diag / "diag-closetrace.json").write_text(json.dumps(trace))
            (diag / "diag-tiers.json").write_text(json.dumps(rows("." * 60 + "S" * 13 + "." * 600)))
            out = Path(tmp) / "report.json"
            done = subprocess.run([sys.executable, str(HERE / "tiers_report.py"), str(film), str(diag), "--json", str(out)],
                                  capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            report = json.loads(out.read_text())
            by_case = {t["case"]: t for t in report["turns"]}
            self.assertEqual(by_case["case-r01-film"]["start_tier"], "Efficiency")
            self.assertEqual(by_case["case-r01-film"]["recording"], "split")
            self.assertEqual(by_case["case-r02-diag"]["start_tier"], "Super")
            self.assertLess(by_case["case-r02-diag"]["first_motion_ms"], by_case["case-r01-film"]["first_motion_ms"])
            self.assertIn("film/Efficiency", report["groups"])
            self.assertIn("diag/Super", report["groups"])

    def test_a_key_the_sampler_does_not_cover_is_uncovered_not_idle(self):
        key_ns = T0 + 20_000_000
        journal = [{"uptimeNanos": key_ns, "kind": {"key": {"_0": {"phase": "down", "keyClass": "letter"}}}}]
        with tempfile.TemporaryDirectory() as tmp:
            diag = Path(tmp) / "late-sampler"
            diag.mkdir()
            trace = trace_with_motion(key_ns / 1e9, 14, 5)
            trace["journal"] = journal
            (diag / "diag-closetrace.json").write_text(json.dumps(trace))
            (diag / "diag-tiers.json").write_text(json.dumps(rows("." * 600, start=T0 + 40_000_000)))
            out = Path(tmp) / "report.json"
            done = subprocess.run([sys.executable, str(HERE / "tiers_report.py"), str(diag), "--json", str(out)],
                                  capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            groups = json.loads(out.read_text())["groups"]
            self.assertIn("all/uncovered", groups)
            self.assertNotIn("all/idle", groups)
            self.assertIn("does not cover", done.stdout)


if __name__ == "__main__":
    unittest.main()

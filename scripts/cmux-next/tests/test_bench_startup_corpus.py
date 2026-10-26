#!/usr/bin/env python3
"""bench-startup.py --corpus: a corpus launch story (perf-corpus/launch-restore.json, task p12-perf-process-121).

1. --corpus is the launch's state: not with a --profile or --after-reboot; --capture needs it; --out takes it.
2. A run seeds the tag once per layout digest, gives every launch the seeding launch's window, screen and config,
   waits for the first live terminal frame and the live sidebar rows (both), and reads the restored checkpoint at
   the seeding's window frame before the app quits (only when the launch drew).
3. The restored checkpoint is judged against the story's recorded digests, else the seeding's state at quit.
4. Results are `corpus.<id>.<mode>.<mark>` in session corpus:<id>, story `<id>-<mode>`, with
   `checkpoint_mismatch_runs`; a mismatched or missing checkpoint fails the bench; --capture records only states
   that every run agreed on.

Runs on any host (Linux included): no app, no fleet.

    python3 -m unittest scripts/cmux-next/tests/test_bench_startup_corpus.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import re
import shutil
import tempfile
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
SPEC = importlib.util.spec_from_file_location("bench_startup", HERE / "bench-startup.py")
bs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bs)

A = {"focus": "a" * 64, "surfaces": "b" * 64}
B = {"focus": "c" * 64, "surfaces": "b" * 64}
LAYOUT = "d" * 64


def story(recorded=None):
    return SimpleNamespace(id="launch-restore", session="corpus:launch-restore", metric_root="corpus.launch_restore",
                           layout_sha=LAYOUT, recorded=recorded)


def parse(*argv):
    with contextlib.redirect_stderr(io.StringIO()):
        return bs.parse_args(["--tag", "t", *argv])


class ParseTests(unittest.TestCase):
    def test_corpus_is_the_profile(self):
        args = parse("--corpus", "perf-corpus/launch-restore.json", "--mode", "warm", "--out", "/tmp/o")
        self.assertEqual(args.profile, "corpus")

    def test_corpus_and_a_profile_are_refused(self):
        with self.assertRaises(SystemExit):
            parse("--corpus", "m.json", "--profile", "realistic")

    def test_corpus_has_no_after_reboot_run(self):
        with self.assertRaises(SystemExit):
            parse("--corpus", "m.json", "--after-reboot")

    def test_capture_needs_corpus(self):
        with self.assertRaises(SystemExit):
            parse("--capture", "--profile", "empty")

    def test_a_cold_result_still_needs_purge(self):
        with self.assertRaises(SystemExit):
            parse("--corpus", "m.json", "--mode", "cold", "--out", "/tmp/o")


class FakeLaunch:
    waits = []
    reaches = True
    made = []  # (environment, cmux.json) of each launch

    def __init__(self, tag, scratch, extra_env=None):
        with open(Path(scratch) / "cmux.json") as config:
            FakeLaunch.made.append((bs.launch_environment(scratch, 3, extra_env), json.load(config)))
        self.marks = {"first_window_frame_committed": 100.0, "first_terminal_frame": 300.0, "sidebar_rows_shown": 250.0}

    def wait_for(self, mark, timeout, any_of=False):
        FakeLaunch.waits.append((list(mark) if not isinstance(mark, str) else [mark], any_of))
        return FakeLaunch.reaches

    def quit(self):
        pass


class OneRunTests(unittest.TestCase):
    def setUp(self):
        names = ("Launch", "app_pids", "tag_pids", "CORPUS", "corpus_seed", "seed_corpus", "restored_checkpoint")
        self.saved = {name: getattr(bs, name) for name in names}
        self.addCleanup(lambda: [setattr(bs, name, value) for name, value in self.saved.items()])
        bs.Launch = FakeLaunch
        bs.app_pids = lambda tag: []
        bs.tag_pids = lambda tag: [4242]  # the daemon runs: a warm run needs no priming launch
        bs.CORPUS = story()
        self.seeds, self.marker = [], None
        bs.corpus_seed = lambda tag: self.marker

        def seed(tag, given):
            self.seeds.append(tag)
            self.marker = {"layout": given.layout_sha, **A}
            return self.marker
        bs.seed_corpus = seed
        bs.restored_checkpoint = lambda tag, given, seeded: {**seeded, "matches": True}
        FakeLaunch.waits, FakeLaunch.made = [], []
        FakeLaunch.reaches = True

    def run_once(self):
        with contextlib.redirect_stderr(io.StringIO()):
            return bs.one_run("t", "warm", 5, "corpus")

    def test_it_seeds_once_per_layout_and_waits_for_the_terminal_and_the_sidebar(self):
        first = self.run_once()
        second = self.run_once()
        self.assertEqual(self.seeds, ["t"], "the second run restores the same seeded session")
        # Each run also waits for p08-startup-068's thread census, sent after the first frame.
        self.assertEqual(FakeLaunch.waits,
                         [([bs.FINAL_MARK, bs.SIDEBAR_MARK], False), (list(bs.THREAD_MARKS), False)] * 2)
        self.assertEqual(first["checkpoint"], {"layout": LAYOUT, **A, "matches": True})
        self.assertIn("checkpoint", second)

    def test_a_marker_of_another_layout_seeds_again(self):
        self.marker = {"layout": "0" * 64, **A}
        self.run_once()
        self.assertEqual(self.seeds, ["t"])

    def test_every_launch_gets_the_seeding_launch_s_window_screen_and_config(self):
        lr = bs.corpus_module()
        out = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, out)
        seeding = lr.seeding_bench("/Apps/cmux DEV t.app", Path(out))
        self.addCleanup(shutil.rmtree, seeding.scratch)
        seeding_env = seeding.environment()
        with open(seeding_env["CMUX_NEXT_CONFIG_FILE"]) as config:
            seeding_config = json.load(config)
        bs.tag_pids = lambda tag: []  # no daemon: a warm run primes it, and the priming launch is a launch too
        self.run_once()
        self.assertEqual(len(FakeLaunch.made), 2)
        width, height = lr.session_io().load_stress().WINDOW_SIZE
        for env, config in FakeLaunch.made:
            for key in ("CMUX_NEXT_TEST_WINDOW_FRAME", "CMUX_NEXT_TEST_WINDOW_SCREEN", "CMUX_NEXT_NO_ACTIVATE"):
                self.assertEqual(env[key], seeding_env[key], key)
            self.assertEqual(env["CMUX_NEXT_TEST_WINDOW_FRAME"], f"0,0,{width},{height}")
            self.assertEqual(env["CMUX_NEXT_TEST_WINDOW_SCREEN"], "0", "the main display, where seeding places it")
            self.assertEqual(config["layout"], seeding_config["layout"])
            self.assertEqual(config, lr.launch_config())

    def test_another_profile_keeps_the_last_screen_and_an_empty_config(self):
        with contextlib.redirect_stderr(io.StringIO()):
            bs.one_run("t", "warm", 5, None)
        env, config = FakeLaunch.made[-1]
        self.assertEqual(env["CMUX_NEXT_TEST_WINDOW_SCREEN"], "last")
        self.assertNotIn("CMUX_NEXT_TEST_WINDOW_FRAME", env)
        self.assertEqual(config, {})

    def test_a_launch_that_did_not_draw_reads_no_checkpoint(self):
        FakeLaunch.reaches = False
        self.assertNotIn("checkpoint", self.run_once())


class RestoredCheckpointTests(unittest.TestCase):
    def setUp(self):
        self.saved = bs.corpus_module
        self.addCleanup(setattr, bs, "corpus_module", self.saved)
        self.wanted, self.calls = [], []

        def settled(read, want):
            self.calls.append("settled")
            self.wanted.append(want)
            return dict(A)
        bs.corpus_module = lambda: SimpleNamespace(settled_digests=settled, place_window=self.place)

    def place(self, rpc):
        self.calls.append("place")
        return {}

    def test_the_window_goes_where_seeding_left_it_before_the_digests_are_read(self):
        bs.restored_checkpoint("t", story(), {"layout": LAYOUT, **B})
        self.assertEqual(self.calls, ["place", "settled"])

    def test_a_display_that_cannot_hold_the_window_gives_no_checkpoint(self):
        class Refused(RuntimeError):
            pass

        def place(rpc):
            raise Refused("window: the window is [1024, 700] pt")
        bs.corpus_module = lambda: SimpleNamespace(place_window=place, settled_digests=None, LaunchRestoreError=Refused)
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertIsNone(bs.restored_checkpoint("t", story(), {"layout": LAYOUT, **B}))
        self.assertIn("no restored checkpoint (window: the window is", err.getvalue())

    def test_without_recorded_digests_the_state_at_quit_is_wanted(self):
        got = bs.restored_checkpoint("t", story(), {"layout": LAYOUT, **B})
        self.assertEqual(self.wanted, [B])
        self.assertEqual(got, {**A, "matches": False})

    def test_an_app_that_does_not_answer_gives_no_checkpoint(self):
        class Unanswered(RuntimeError):
            pass

        def settled(read, want):
            raise Unanswered("debug.focus gave no report")
        bs.corpus_module = lambda: SimpleNamespace(settled_digests=settled, place_window=self.place,
                                                   LaunchRestoreError=Unanswered)
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertIsNone(bs.restored_checkpoint("t", story(), {"layout": LAYOUT, **B}))
        self.assertIn("no restored checkpoint (debug.focus gave no report)", err.getvalue())

    def test_recorded_digests_win(self):
        got = bs.restored_checkpoint("t", story(recorded=A), {"layout": LAYOUT, **B})
        self.assertEqual(self.wanted, [A])
        self.assertTrue(got["matches"])


def run(checkpoint):
    marks = {"first_window_frame_committed": 100.0, "first_terminal_frame": 300.0, "sidebar_rows_shown": 250.0,
             "did_finish_launching_end": 80.0}
    if checkpoint is not None:
        marks["checkpoint"] = checkpoint
    return marks


class ResultTests(unittest.TestCase):
    def setUp(self):
        self.saved = bs.CORPUS
        self.addCleanup(setattr, bs, "CORPUS", self.saved)
        bs.CORPUS = story()

    def test_series_are_named_under_the_story_and_count_mismatches(self):
        runs = [run({**A, "matches": True}), run({**B, "matches": False})]
        series = {name: samples for name, _, samples in bs.result_series("warm", runs, "corpus", "corpus.launch_restore")}
        self.assertEqual(series["corpus.launch_restore.warm.first_terminal_frame"], [300.0, 300.0])
        self.assertEqual(series["corpus.launch_restore.warm.sidebar_rows_shown"], [250.0, 250.0])
        self.assertEqual(series["corpus.launch_restore.warm.checkpoint_mismatch_runs"], [1])
        self.assertFalse([name for name in series if name.startswith("launch.")])

    def test_the_manifest_declares_every_series_the_launches_write(self):
        loaded = bs.corpus_module().load("perf-corpus/launch-restore.json")
        patterns = [m["name"] for m in loaded.manifest["metrics"]]
        written = [name for mode in ("cold", "warm")
                   for name, _, _ in bs.result_series(mode, [run({**A, "matches": True})], "corpus", loaded.metric_root)]
        for name in written:
            self.assertTrue(any(re.fullmatch(p, name) for p in patterns), name)
        for pattern in patterns:
            self.assertTrue(any(re.fullmatch(pattern, name) for name in written), pattern)

    def test_the_story_and_session_are_the_corpus_story(self):
        self.assertEqual(bs.default_story("cold", "corpus"), "launch-restore-cold")

        class FakeBenchApp:
            made = []

            def __init__(self, app, out=None, teardown=True, perf_session="light", build_config=None, run=None):
                self.session, self.records, self.features = perf_session, [], {}
                FakeBenchApp.made.append(self)

            def record(self, story_name, metric, unit, samples, better, engine, target_ref=None):
                self.records.append((story_name, metric, target_ref))
                return metric

        saved = dict(bs.APPS)
        self.addCleanup(lambda: (bs.APPS.clear(), bs.APPS.update(saved)))
        bs.APPS["t"] = "/tmp/cmux DEV t.app"
        recorder = bs.Recorder("/tmp/out", "corpus", "corpus:launch-restore", bench_app=FakeBenchApp)
        recorder.story = None  # not the perf-lab runner's PERF_LAB_STORY
        recorder.record("t", "warm", [run({**A, "matches": True})])
        made = FakeBenchApp.made[-1]
        self.assertEqual(made.session, "corpus:launch-restore")
        self.assertIn(("launch-restore-warm", "corpus.launch_restore.warm.first_terminal_frame", None), made.records)
        self.assertFalse([r for r in made.records if r[2] is not None], "no program target judges a corpus story")

    def test_mismatched_and_missing_checkpoints_fail(self):
        lines = bs.check_checkpoints({"t": {"warm": [run({**A, "matches": True}), run({**B, "matches": False}),
                                                     run(None)]}})
        self.assertEqual(len(lines), 2)
        self.assertIn("run 2: restored another state", lines[0])
        self.assertIn("run 3: no restored checkpoint", lines[1])

    def test_capture_records_only_a_state_every_run_agreed_on(self):
        captured = []
        saved = bs.corpus_module
        self.addCleanup(setattr, bs, "corpus_module", saved)
        bs.corpus_module = lambda: SimpleNamespace(capture=lambda given, digests: captured.append(digests) or "m.json",
                                                   LaunchRestoreError=RuntimeError)
        with self.assertRaises(bs.Refused), contextlib.redirect_stderr(io.StringIO()):
            bs.capture_checkpoint({"t": {"warm": [run({**A, "matches": True})]}, "u": {"warm": [run({**B, "matches": True})]}})
        self.assertEqual(captured, [])
        with contextlib.redirect_stdout(io.StringIO()):
            bs.capture_checkpoint({"t": {"warm": [run({**A, "matches": True}), run({**A, "matches": True})]}})
        self.assertEqual(captured, [A])


if __name__ == "__main__":
    unittest.main()

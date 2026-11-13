#!/usr/bin/env python3
"""launch_time_profile.py (bench-startup.py --time-profile): the export parser keeps only the app's main thread, the
clock is set from the first sample inside applicationDidFinishLaunching, samples are split by frame and by gap
between marks, and a recording that saved nothing gives the run an `error`, not a crash. No xctrace, no app.
Run: python3 -I scripts/cmux-next/tests/test_launch_time_profile.py"""
import importlib.util, os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import launch_time_profile  # noqa: E402

spec = importlib.util.spec_from_file_location("bench_startup", os.path.join(HERE, "..", "bench-startup.py"))
bench_startup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench_startup)


class FakeRecorder:
    def __init__(self, directory, saved):
        self.path = os.path.join(directory, "launch.trace")
        self.saved = saved
        if saved:
            os.makedirs(self.path)

    def stop(self):
        return self.saved

    def log(self):
        return "xctrace: no recording"

    def export(self, out_xml):
        with open(out_xml, "w") as f:
            f.write(launch_time_profile.SELF_TEST_XML)
        return True


class LaunchTimeProfile(unittest.TestCase):
    def test_self_test(self):
        launch_time_profile.self_test()

    def test_run_summary_and_trace_removed(self):
        with tempfile.TemporaryDirectory() as scratch:
            recorder = FakeRecorder(scratch, saved=True)
            marks = {"main_start": 1.0, "did_finish_launching_start": 12.0, "first_window_frame_committed": 30.0}
            summary = bench_startup.time_profile(recorder, 42, marks, scratch)
            self.assertNotIn("error", summary)
            self.assertEqual(summary["ours_leaf"][0], ["CloudServices.init()", 2.0])
            self.assertFalse(os.path.exists(recorder.path))  # the trace never stays behind
            self.assertFalse(os.path.exists(os.path.join(scratch, "time-profile.xml")))

    def test_nothing_saved_is_an_error(self):
        with tempfile.TemporaryDirectory() as scratch:
            summary = bench_startup.time_profile(FakeRecorder(scratch, saved=False), 42, {}, scratch)
            self.assertIn("no recording", summary["error"])

    def test_merge_takes_the_median(self):
        a = {"busy_ms": 10.0, "window_ms": 20.0, "ours_leaf": [["A", 6.0], ["B", 4.0]]}
        b = {"busy_ms": 12.0, "window_ms": 22.0, "ours_leaf": [["A", 2.0]]}
        c = {"busy_ms": 30.0, "window_ms": 40.0, "ours_leaf": [["A", 8.0], ["B", 9.0]]}
        merged = launch_time_profile.merge([a, b, c])
        self.assertEqual(merged["busy_ms"], 12.0)
        self.assertEqual(dict(merged["ours_leaf"]), {"A": 6.0, "B": 4.0})


if __name__ == "__main__":
    unittest.main()

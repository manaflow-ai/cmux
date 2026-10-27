#!/usr/bin/env python3
"""thread_wakeups.py and bench_idle.py's daemon_threads (p06-scheduler-228): a thread's wakeups are the sample
intervals its CPU time moved in, a thread that starts in the window counts its start, threads of one name pattern
are one row, the queue holds the rows over 0.05/s, the window samples only the daemon and leaves the result's
`daemon_threads` null with no daemon, and the criterion fails a scenario whose daemon threads sum over the limit.
The live case samples a real thread of this process through this system's reader (procfs on Linux, libproc on
macOS). Run: python3 -I scripts/cmux-next/tests/test_thread_wakeups.py"""
import importlib.util, os, sys, threading, time, types, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


tw = load("thread_wakeups", os.path.join(HERE, "..", "thread_wakeups.py"))
bi = load("bench_idle", os.path.join(HERE, "..", "bench_idle.py"))


class Clock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def frames_source(frames):
    """A reader for one pid that answers sample i from `frames[i]` ({pid: {thread: (name, cpu_ns)}}), the last
    frame after the end."""
    state = {"index": 0}

    class Source:
        def threads(self, pid):
            frame = frames[min(state["index"], len(frames) - 1)]
            state["index"] += 1
            return frame.get(pid)

    return Source()


class SampleTests(unittest.TestCase):
    def run_frames(self, frames, seconds, interval=1.0):
        clock = Clock()
        return tw.sample(frames_source(frames), [7], seconds, interval, clock=clock.monotonic, sleep=clock.sleep)

    def test_a_run_is_an_interval_whose_cpu_time_moved(self):
        frames = [
            {7: {1: ("mux-idle-close", 100), 2: ("cmux-journal-maintenance", 50)}},
            {7: {1: ("mux-idle-close", 100), 2: ("cmux-journal-maintenance", 80)}},
            {7: {1: ("mux-idle-close", 100), 2: ("cmux-journal-maintenance", 80)}},
            {7: {1: ("mux-idle-close", 140), 2: ("cmux-journal-maintenance", 95)}},
        ]
        threads, samples = self.run_frames(frames, 3)
        self.assertEqual(samples, 4)
        self.assertEqual(threads[(7, 1)]["runs"], 1)
        self.assertEqual(threads[(7, 2)]["runs"], 2)
        self.assertEqual(threads[(7, 2)]["cpu_ns"], 45)

    def test_a_thread_that_starts_in_the_window_counts_its_start(self):
        frames = [{7: {1: ("a", 10)}}, {7: {1: ("a", 10), 3: ("mux-deadline-0", 5)}}]
        threads, _ = self.run_frames(frames, 1)
        self.assertEqual(threads[(7, 3)]["runs"], 1)
        self.assertEqual(threads[(7, 1)]["runs"], 0, "a thread present at the first sample is the baseline")

    def test_a_gone_process_is_skipped(self):
        threads, samples = self.run_frames([{}], 2)
        self.assertEqual((threads, samples), ({}, 3))


class SummaryTests(unittest.TestCase):
    def test_rows_group_by_name_pattern_and_the_queue_holds_rows_over_the_threshold(self):
        threads = {
            (7, 1): {"name": "mux-deadline-0", "runs": 2, "cpu_ns": 1_000_000},
            (7, 2): {"name": "mux-deadline-11", "runs": 2, "cpu_ns": 1_000_000},
            (7, 3): {"name": "cmux-journal-maintenance", "runs": 2, "cpu_ns": 0},
            (7, 4): {"name": "", "runs": 0, "cpu_ns": 0},
        }
        summary = tw.summarize(threads, 60.0)
        rows = {row["name"]: row for row in summary["threads"]}
        self.assertEqual(rows["mux-deadline-*"]["threads"], 2)
        self.assertEqual(rows["mux-deadline-*"]["wakeups"], 4)
        self.assertEqual(rows["mux-deadline-*"]["per_second"], round(4 / 60, 3))
        self.assertEqual(rows["(unnamed)"]["wakeups"], 0)
        self.assertEqual(summary["threads"][0]["name"], "mux-deadline-*", "most wakeups first")
        self.assertEqual(summary["sum_per_s"], 0.1)
        self.assertEqual(summary["queue"], ["mux-deadline-*"], "0.033/s is under the 0.05/s threshold")
        self.assertEqual(summary["sample_ms"], 20.0)


class BenchIdleTests(unittest.TestCase):
    def test_the_window_samples_only_the_daemon(self):
        source = frames_source([{9: {1: ("a", 1)}}, {9: {1: ("a", 2)}}])
        clock = Clock()
        with mock.patch.object(tw.time, "monotonic", clock.monotonic), mock.patch.object(tw.time, "sleep", clock.sleep):
            threads = bi.daemon_thread_window([9], 0.02, source=source)
        self.assertEqual(threads[(9, 1)]["runs"], 1)

    def test_no_daemon_sleeps_the_window_and_reports_null(self):
        slept = []
        with mock.patch.object(bi.time, "sleep", slept.append):
            self.assertIsNone(bi.daemon_thread_window([], 60, source=frames_source([{}])))
        self.assertEqual(slept, [60])

    def test_measure_writes_daemon_threads(self):
        clock = Clock()
        control = types.SimpleNamespace(call=lambda method, params=None, timeout=None: {"result": {}})
        sampled = []

        def window(pids, seconds):
            sampled.append(pids)
            clock.sleep(seconds)
            return {(5, 1): {"name": "mux-idle-close", "runs": 6, "cpu_ns": 0}}

        with mock.patch.object(bi, "classify", lambda pid, bundle: {1: "app", 5: "daemon"}), \
                mock.patch.object(bi.procs, "usage", lambda pid: None), \
                mock.patch.object(bi, "daemon_thread_window", window), \
                mock.patch.object(bi.time, "monotonic", clock.monotonic):
            result = bi.measure(1, "/x.app", 60, control)
        self.assertEqual(sampled, [[5]])
        self.assertEqual(result["daemon_threads"]["sum_per_s"], 0.1)
        self.assertEqual(result["daemon_threads"]["queue"], ["mux-idle-close"])

    def test_the_criterion_fails_a_daemon_over_the_sum(self):
        args = types.SimpleNamespace(max_cpu=0.5, max_wakeups=5, max_host_cpu=0.2, max_host_wakeups=2,
                                     max_helper_cpu=1, max_daemon_thread_wakeups=0.5)
        over = {"processes": [], "daemon_threads": {"sum_per_s": 0.9, "queue": ["mux-idle-close"]}}
        under = {"processes": [], "daemon_threads": {"sum_per_s": 0.4, "queue": []}}
        unmeasured = {"processes": [], "daemon_threads": None}
        failures = bi.criteria("terminals", over, args)
        self.assertEqual(len(failures), 1)
        self.assertIn("mux-idle-close", failures[0])
        self.assertEqual(bi.criteria("terminals", under, args), [])
        self.assertEqual(bi.criteria("terminals", unmeasured, args), [])


@unittest.skipIf(tw.reader() is None, "no thread reader on this system")
class LiveTests(unittest.TestCase):
    def test_a_thread_that_wakes_ten_times_a_second_counts_about_ten_wakeups(self):
        stop = threading.Event()

        def ticker():
            while not stop.wait(0.1):
                sum(range(2000))  # some CPU time per wake

        worker = threading.Thread(target=ticker, name="tw-ticker")
        worker.start()
        try:
            threads, _ = tw.sample(tw.reader(), [os.getpid()], 1.0, 0.02)
        finally:
            stop.set()
            worker.join()
        # The sampling thread runs every sample itself; the ticker is the thread that woke about 10 times (its
        # kernel name is Python's only on 3.14+, so it is found by its count).
        runs = sorted(row["runs"] for row in threads.values())
        self.assertTrue(any(6 <= count <= 14 for count in runs), f"no thread woke about 10 times: {runs}")


if __name__ == "__main__":
    unittest.main()

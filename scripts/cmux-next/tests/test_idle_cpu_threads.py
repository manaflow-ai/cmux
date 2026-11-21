#!/usr/bin/env python3
"""idle_cpu.py's per-thread view of the app: which threads ran in an idle window.
Run: python3 -I scripts/cmux-next/tests/test_idle_cpu_threads.py (not a CI job)."""
import os, sys, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import idle_cpu  # noqa: E402


class AppThreads(unittest.TestCase):
    def test_threads_group_by_name_busiest_first_and_idle_ones_drop(self):
        before = {1: ("main", 1_000_000), 2: ("ThreadPoolForegroundWorker", 0), 3: ("ThreadPoolForegroundWorker", 0),
                  4: ("HangWatcher", 5_000_000)}
        after = {1: ("main", 3_000_000), 2: ("ThreadPoolForegroundWorker", 1_500_000),
                 3: ("ThreadPoolForegroundWorker", 2_500_000), 4: ("HangWatcher", 5_000_000), 5: ("?", 400_000)}
        groups = idle_cpu.app_threads(before, after, 2.0)
        self.assertEqual([g["name"] for g in groups], ["ThreadPoolForegroundWorker", "main", "?"])
        self.assertEqual(groups[0], {"name": "ThreadPoolForegroundWorker", "threads": 2, "cpu_ms_per_s": 2.0})
        self.assertEqual(groups[1]["cpu_ms_per_s"], 1.0)
        self.assertEqual(groups[2]["threads"], 1)   # a thread born in the window counts from 0

    def test_live_process_reads_its_own_threads(self):
        before = idle_cpu.bench_memory.thread_times(os.getpid())
        sum(i * i for i in range(100_000))
        after = idle_cpu.bench_memory.thread_times(os.getpid())
        self.assertTrue(idle_cpu.app_threads(before, after, 1.0))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""idle_cpu.py's per-thread view of the app: which threads ran in an idle window.
Run: python3 -I scripts/cmux-next/tests/test_idle_cpu_threads.py (not a CI job)."""
import ctypes, os, sys, unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
if sys.platform == "darwin":
    import idle_cpu  # noqa: E402
else:  # bench_memory loads macOS's libproc at import; the grouping test needs none of it
    with mock.patch.object(ctypes, "CDLL", mock.MagicMock()):
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

    @unittest.skipUnless(sys.platform == "darwin", "reads threads through macOS libproc")
    def test_live_process_reads_its_own_threads(self):
        before = idle_cpu.bench_memory.thread_times(os.getpid())
        sum(i * i for i in range(100_000))
        after = idle_cpu.bench_memory.thread_times(os.getpid())
        self.assertTrue(idle_cpu.app_threads(before, after, 1.0))


class PageActivity(unittest.TestCase):
    def test_cmux_pages_get_the_probe_and_metrics_per_second(self):
        import json
        idle_cpu.time.sleep, sleep = (lambda s: None), idle_cpu.time.sleep
        try:
            calls, task = [], iter([1.0, 5.0, 3.0, 5.0])

            def call(method, params=None):
                calls.append((method, (params or {}).get("method")))
                if method == "debug.cef_pages":
                    return {"pages": [{"browser": 2, "origin": "cmux-page://cmux.agent", "path": "/"},
                                      {"browser": 3, "origin": "cmux-page://cmux.agent", "hidden": True},
                                      {"browser": 4, "origin": "https://example.com"}]}
                if params["method"] == "Runtime.evaluate":
                    value = json.dumps({"animation_count": 1, "animations": [{"name": "spin"}], "active": "DIV"})
                    return {"result": json.dumps({"result": {"value": value}})}
                if params["method"] == "Performance.getMetrics":
                    return {"result": json.dumps({"metrics": [{"name": "TaskDuration", "value": next(task)}]})}
                return {"result": "{}"}

            pages = idle_cpu.page_activity(call, seconds=10)
        finally:
            idle_cpu.time.sleep = sleep
        self.assertEqual([p["browser"] for p in pages], [2, 3])  # hidden cmux pages too; web pages are not probed
        self.assertTrue(pages[1]["hidden"])
        self.assertEqual(pages[0]["animation_count"], 1)
        self.assertEqual(pages[0]["metrics_per_s"], {"TaskDuration": 0.2})
        self.assertIn(("debug.cef_page_devtools", "Performance.disable"), calls)

    def test_a_failed_devtools_call_keeps_its_error(self):
        idle_cpu.time.sleep, sleep = (lambda s: None), idle_cpu.time.sleep
        try:
            pages = idle_cpu.page_activity(lambda m, p=None: {"pages": [{"browser": 1, "origin": "cmux-page://x"}]}
                                           if m == "debug.cef_pages" else {"error": "gone"})
        finally:
            idle_cpu.time.sleep = sleep
        self.assertIn("probe_error", pages[0])
        self.assertNotIn("metrics_per_s", pages[0])


class RendererThreads(unittest.TestCase):
    def test_each_renderer_gets_its_own_thread_groups_per_window(self):
        procs = {10: ("app", "cmux"), 20: ("cef-renderer", "r --type=renderer"), 30: ("cef-gpu", "g"),
                 40: ("cef-renderer-extension", "e --type=renderer")}
        self.assertEqual(idle_cpu.renderer_pids(procs), [20, 40])
        times = {10: [{1: ("main", 0)}, {1: ("main", 1_000_000)}],
                 20: [{7: ("Compositor", 0)}, {7: ("Compositor", 4_000_000)}],
                 40: [{8: ("main", 0)}, {8: ("main", 0)}]}
        calls = {pid: iter(v) for pid, v in times.items()}
        renderer_threads: list = []
        with mock.patch.object(idle_cpu.bench_memory, "owned", return_value=procs), \
                mock.patch.object(idle_cpu.bench_memory, "thread_times", side_effect=lambda pid: next(calls[pid])), \
                mock.patch.object(idle_cpu.bench_memory, "usage", return_value=None), \
                mock.patch.object(idle_cpu, "switches", return_value=None), \
                mock.patch.object(idle_cpu.time, "sleep"), \
                mock.patch.object(idle_cpu.time, "monotonic", side_effect=[0.0, 2.0]):
            idle_cpu.measure(10, "b", 1, 2.0, None, [], renderer_threads)
        self.assertEqual(renderer_threads, [{20: [{"name": "Compositor", "threads": 1, "cpu_ms_per_s": 2.0}], 40: []}])


class CefSwitches(unittest.TestCase):
    def test_switches_reach_the_launch_env_after_the_home_is_prepared(self):
        seen = []
        env = {"HOME": "/tmp/h"}
        idle_cpu.with_cef_switches(lambda e: seen.append(dict(e)), "disable-component-update")(env)
        self.assertEqual(seen, [{"HOME": "/tmp/h"}])
        self.assertEqual(env["CMUX_NEXT_CEF_EXTRA_SWITCHES"], "disable-component-update")

    def test_no_switches_leave_the_env_alone(self):
        env = {"HOME": "/tmp/h"}
        idle_cpu.with_cef_switches(lambda e: None, "")(env)
        self.assertNotIn("CMUX_NEXT_CEF_EXTRA_SWITCHES", env)

    def test_the_bench_runs_without_the_component_updater_by_default(self):
        # A fresh home installs every Chromium component in its first minutes (about 0.25 % app CPU and a third of
        # the renderer's idle cost on cmux20-bench, 2 on and 2 off runs of one build): runs varied with it.
        args = idle_cpu.parse_args(["--app", "/x.app"])
        self.assertEqual(args.cef_switches, "disable-component-update")
        env = {"HOME": "/tmp/h"}
        idle_cpu.with_cef_switches(lambda e: None, args.cef_switches)(env)
        self.assertEqual(env["CMUX_NEXT_CEF_EXTRA_SWITCHES"], "disable-component-update")

    def test_none_keeps_the_updater_on(self):
        env = {"HOME": "/tmp/h"}
        idle_cpu.with_cef_switches(lambda e: None, "none")(env)
        self.assertNotIn("CMUX_NEXT_CEF_EXTRA_SWITCHES", env)


class ChromiumDirs(unittest.TestCase):
    def test_each_top_level_entry_of_the_chromium_root_with_its_size(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as home:
            root = Path(home) / "Library/Application Support/dev.cmux.next.tag/Chromium"
            (root / "CertificateRevocation/1").mkdir(parents=True)
            (root / "CertificateRevocation/1/crl-set").write_bytes(b"x" * 3000)
            (root / "Default").mkdir()
            (root / "Local State").write_bytes(b"y" * 10)
            dirs = idle_cpu.chromium_dirs(Path(home))
        self.assertEqual(dirs, [{"name": "CertificateRevocation", "bytes": 3000},
                                {"name": "Local State", "bytes": 10}, {"name": "Default", "bytes": 0}])


if __name__ == "__main__":
    unittest.main()

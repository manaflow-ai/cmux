#!/usr/bin/env python3
"""cef-idle-probe.py CEF-IDLE-POSTED (p14-energy-041): a recorded trace's posting locations, highest per_s first, each
naming process and thread; `--queue` keeps per_s >= 0.02 (3 locations in, 1 out) and needs a window >= 50 s (default 100 s); the browser main thread's task rate
beside the pump counters. Runs anywhere (no app, no Chromium).
Run: python3 -I scripts/cmux-next/tests/test_cef_idle_probe.py"""
import importlib.util, io, json, os, subprocess, sys, tempfile, unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, "..", "cef-idle-probe.py")

spec = importlib.util.spec_from_file_location("cef_idle_probe", PROBE)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

SECONDS = 100.0
BROWSER, GPU, RENDERER = 100, 200, 300


def meta(pid, tid, kind, name):
    return {"ph": "M", "pid": pid, "tid": tid, "name": kind, "args": {"name": name}}


def task(pid, tid, src_file, src_func, name="ThreadControllerImpl::RunTask"):
    return {"ph": "X", "pid": pid, "tid": tid, "ts": 0, "dur": 5, "name": name,
            "args": {"src_file": src_file, "src_func": src_func}}


def recorded_trace():
    """A 100 s idle window: three locations at or above 0.02/s, one at 0.01/s, one frame event that is not a task."""
    events = [
        meta(BROWSER, 0, "process_name", "Browser"), meta(GPU, 0, "process_name", "GPU Process"),
        meta(RENDERER, 0, "process_name", "Renderer"),
        meta(BROWSER, 1, "thread_name", "CrBrowserMain"), meta(BROWSER, 2, "thread_name", "ThreadPoolBackgroundWorker"),
        meta(GPU, 3, "thread_name", "VizCompositorThread"), meta(RENDERER, 4, "thread_name", "CrRendererMain"),
    ]
    events += [task(BROWSER, 1, "components/media_router/discovery.cc", "StartDiscovery")] * 6
    events += [task(GPU, 3, "components/viz/service/display/display_scheduler.cc", "OnBeginFrame")] * 3
    events += [task(BROWSER, 2, "net/nqe/network_quality_estimator.cc", "ComputeEffectiveConnectionType",
                    name="ThreadPool_RunTask")] * 2
    events += [task(RENDERER, 4, "third_party/blink/renderer/core/timing/idle_deadline.cc", "Tick")]
    events.append({"ph": "X", "pid": RENDERER, "tid": 4, "ts": 0, "dur": 1, "name": "ProxyMain::BeginMainFrame", "args": {}})
    return {"traceEvents": events}


class PostedTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.trace = os.path.join(self.dir.name, "chromium-trace.json")
        with open(self.trace, "w") as f:
            json.dump(recorded_trace(), f)
        self.counts = probe.chromium_summary(self.trace, SECONDS)["task_counts"]

    def tearDown(self):
        self.dir.cleanup()

    def test_queue_keeps_three_above_threshold_and_drops_the_one_below(self):
        rows = probe.posted_rows(self.counts, SECONDS, probe.QUEUE_MIN_PER_S)
        self.assertEqual([(r["process"], r["thread"], r["location"], r["per_s"]) for r in rows], [
            ("Browser", "CrBrowserMain", "components/media_router/discovery.cc:StartDiscovery", 0.06),
            ("GPU Process", "VizCompositorThread", "components/viz/service/display/display_scheduler.cc:OnBeginFrame", 0.03),
            ("Browser", "ThreadPoolBackgroundWorker",
             "net/nqe/network_quality_estimator.cc:ComputeEffectiveConnectionType", 0.02),
        ])
        self.assertNotIn("idle_deadline", json.dumps(rows))

    def test_without_queue_every_location_is_listed_highest_first(self):
        rows = probe.posted_rows(self.counts, SECONDS)
        self.assertEqual(len(rows), 4)
        self.assertEqual([r["per_s"] for r in rows], sorted((r["per_s"] for r in rows), reverse=True))
        self.assertEqual(rows[-1]["thread"], "CrRendererMain")
        self.assertEqual(set(rows[0]), {"process", "pid", "thread", "location", "per_s"})

    def test_threshold_compares_before_rounding(self):
        counts = {("Browser", BROWSER, "CrBrowserMain", "a.cc:F"): 199}
        self.assertEqual(probe.posted_rows(counts, 10_000.0, probe.QUEUE_MIN_PER_S), [])

    def test_typed_event_posted_from(self):
        args = {"task": {"posted_from": {"file_name": "gcm/engine/heartbeat_manager.cc", "function_name": "Start"}}}
        self.assertEqual(probe.posted_from(args), "gcm/engine/heartbeat_manager.cc:Start")

    def test_pump_comparison_sets_browser_main_beside_pump(self):
        rows = probe.posted_rows(self.counts, SECONDS)
        report = probe.pump_comparison(rows, {"work_runs": 4.5, "delayed_requests": 2.0, "work_ms": 9.0}, 3)
        self.assertEqual(report, {"browser_main_tasks_per_s": 0.06, "early_passes": 3,
                                  "work_runs_per_s": 4.5, "delayed_requests_per_s": 2.0})

    def test_print_posted_emits_sorted_lines_then_pump_line(self):
        out = io.StringIO()
        with redirect_stdout(out):
            probe.print_posted(self.counts, SECONDS, True, {"work_runs": 1.0}, 0)
        lines = out.getvalue().splitlines()
        self.assertEqual([line.split(" ", 1)[0] for line in lines], ["CEF-IDLE-POSTED"] * 3 + ["CEF-IDLE-POSTED-PUMP"])
        self.assertEqual(json.loads(lines[0].split(" ", 1)[1])["thread"], "CrBrowserMain")

    def test_cli_reads_a_recorded_trace(self):
        run = subprocess.run([sys.executable, "-I", PROBE, "--trace", self.trace, "--seconds", str(SECONDS), "--queue"],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stderr)
        posted = [line for line in run.stdout.splitlines() if line.startswith("CEF-IDLE-POSTED ")]
        self.assertEqual(len(posted), 3)

    def test_queue_window_defaults_long_enough_to_resolve_the_threshold(self):
        self.assertEqual(probe.window_seconds(None, True), 100.0)
        self.assertEqual(probe.window_seconds(None, False), 10.0)
        self.assertEqual(probe.window_seconds(60.0, True), 60.0)
        self.assertIsNone(probe.queue_window_error(probe.window_seconds(None, True), "--window"))
        self.assertIsNone(probe.queue_window_error(50.0, "--window"))
        self.assertIn("--window >= 50", probe.queue_window_error(49.0, "--window"))

    def test_cli_app_queue_refuses_a_short_window(self):
        # Refused by the parser before any app launch, so the app path need not exist.
        run = subprocess.run([sys.executable, "-I", PROBE, "--app", os.path.join(self.dir.name, "missing.app"),
                              "--queue", "--window", "10", "--out", self.dir.name],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("--queue needs --window >= 50", run.stderr)

    def test_cli_trace_queue_refuses_a_short_window(self):
        run = subprocess.run([sys.executable, "-I", PROBE, "--trace", self.trace, "--seconds", "10", "--queue"],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("--queue needs --seconds >= 50", run.stderr)
        self.assertNotIn("CEF-IDLE-POSTED", run.stdout)

    def test_cli_trace_needs_seconds(self):
        run = subprocess.run([sys.executable, "-I", PROBE, "--trace", self.trace],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 2)
        self.assertIn("--seconds", run.stderr)


if __name__ == "__main__":
    unittest.main()

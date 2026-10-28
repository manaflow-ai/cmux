#!/usr/bin/env python3
"""cef-idle-probe.py CEF-IDLE-POSTED (p14-energy-041, -109): a recorded trace's posting locations, highest per_s first,
each naming kind, process and thread. `--queue` is the Q8 work list: locations at or above 0.02/s on any
browser-process thread (CrBrowserMain, ThreadPool workers) or in a renderer, GPU, network, storage, audio or utility
process; locations below it, in the probe's tracing service or an extension renderer, and Safe Browsing, CRLSet
and the probe's own DevTools work stay out. Seed-list locations name their candidate and switch. The browser main
thread's task rate sits beside the pump counters. `--queue` needs a window >= 50 s (default 100 s). Runs anywhere (no app, no Chromium).
Run: python3 -I scripts/cmux-next/tests/test_cef_idle_probe.py"""
import importlib.util, io, json, os, subprocess, sys, tempfile, unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, "..", "cef-idle-probe.py")

spec = importlib.util.spec_from_file_location("cef_idle_probe", PROBE)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

SECONDS = 100.0
BROWSER, GPU, RENDERER, RENDERER2, NETWORK, TRACING, EXTENSION, STORAGE = 100, 200, 300, 301, 400, 500, 600, 700


def meta(pid, tid, kind, name):
    return {"ph": "M", "pid": pid, "tid": tid, "name": kind, "args": {"name": name}}


def task(pid, tid, src_file, src_func, name="ThreadControllerImpl::RunTask"):
    return {"ph": "X", "pid": pid, "tid": tid, "ts": 0, "dur": 5, "name": name,
            "args": {"src_file": src_file, "src_func": src_func}}


def pool(pid, tid, src_file, src_func):
    return task(pid, tid, src_file, src_func, name="ThreadPool_RunTask")


def recorded_trace():
    """A 100 s idle window over the browser, GPU, two renderers, the network, storage and tracing services and an
    extension renderer. Names from base/process/current_process.cc and the threads' SetName calls."""
    events = [
        meta(BROWSER, 0, "process_name", "Browser"), meta(GPU, 0, "process_name", "GPU Process"),
        meta(RENDERER, 0, "process_name", "Renderer"), meta(RENDERER2, 0, "process_name", "Renderer"),
        meta(NETWORK, 0, "process_name", "Service: network.mojom.NetworkService"),
        meta(STORAGE, 0, "process_name", "Service: storage.mojom.StorageService"),
        meta(TRACING, 0, "process_name", "Service: tracing.mojom.TracingService"),
        meta(EXTENSION, 0, "process_name", "Renderer"),
        meta(BROWSER, 1, "thread_name", "CrBrowserMain"),
        meta(BROWSER, 2, "thread_name", "ThreadPoolBackgroundWorker"),
        meta(BROWSER, 6, "thread_name", "ThreadPoolBackgroundWorker"),
        meta(BROWSER, 5, "thread_name", "ThreadPoolForegroundWorker"),
        meta(GPU, 3, "thread_name", "VizCompositorThread"), meta(GPU, 7, "thread_name", "CrGpuMain"),
        meta(RENDERER, 4, "thread_name", "CrRendererMain"), meta(RENDERER, 9, "thread_name", "Compositor"),
        meta(RENDERER2, 8, "thread_name", "CrRendererMain"),
        meta(NETWORK, 10, "thread_name", "ThreadPoolForegroundWorker"),
        meta(STORAGE, 13, "thread_name", "CrUtilityMain"),
        meta(TRACING, 11, "thread_name", "CrUtilityMain"), meta(EXTENSION, 12, "thread_name", "CrRendererMain"),
        {"ph": "I", "pid": BROWSER, "tid": 1, "ts": 0, "name": "TracingStartedInBrowser", "args": {"data": {"frames": [
            {"processId": RENDERER, "url": "https://example.com/"},
            {"processId": RENDERER2, "url": "https://example.org/"},
            {"processId": EXTENSION, "url": "chrome-extension://cjpalhdlnbpafiamejdnhcphjbkeiagm/background.html"}]}}},
    ]
    # In the queue (at or above 0.02/s).
    events += [task(BROWSER, 1, "chrome/browser/media/router/discovery/dial/dial_service_impl.cc", "StartDiscovery")] * 6
    events += [task(GPU, 3, "components/viz/service/display/display_scheduler.cc", "OnBeginFrame")] * 3
    # Two workers of one name add up to 0.02/s.
    events += [pool(BROWSER, 2, "components/update_client/update_checker.cc", "CheckForUpdates"),
               pool(BROWSER, 6, "components/update_client/update_checker.cc", "CheckForUpdates")]
    events += [pool(BROWSER, 5, "../../google_apis/gcm/engine/heartbeat_manager.cc", "OnHeartbeatTriggered")] * 2
    events += [pool(NETWORK, 10, "net/nqe/network_quality_estimator.cc", "ComputeEffectiveConnectionType")] * 2
    events += [task(STORAGE, 13, "components/services/storage/dom_storage/session_storage_impl.cc", "Flush")] * 2
    # One DOM timer at 0.01/s in each of two renderers is one location at 0.02/s.
    events += [task(RENDERER, 4, "third_party/blink/renderer/core/timing/dom_timer.cc", "Fired"),
               task(RENDERER2, 8, "third_party/blink/renderer/core/timing/dom_timer.cc", "Fired")]
    # Out: below the threshold.
    events += [task(GPU, 7, "gpu/ipc/service/gpu_watchdog_thread.cc", "OnWatchdogTimeout")]
    events += [task(RENDERER, 9, "cc/trees/proxy_impl.cc", "ScheduledActionDraw")]
    # Out: they stay (Safe Browsing, CRLSet, the probe's own DevTools session).
    events += [pool(BROWSER, 5, "components/safe_browsing/core/browser/db/v4_update_protocol_manager.cc",
                    "ScheduleNextUpdate")] * 5
    events += [task(BROWSER, 1, "chrome/browser/component_updater/crl_set_component_installer.cc", "ComponentReady")] * 3
    events += [task(BROWSER, 1, "content/browser/devtools/devtools_session.cc", "DispatchProtocolMessage")] * 9
    # Out: the probe's tracing service and the extension renderer (p14-energy-108).
    events += [task(TRACING, 11, "mojo/public/cpp/system/simple_watcher.cc", "Notify")] * 10
    events += [task(EXTENSION, 12, "third_party/blink/renderer/core/timing/dom_timer.cc", "Fired")] * 8
    events.append({"ph": "X", "pid": RENDERER, "tid": 4, "ts": 0, "dur": 1, "name": "ProxyMain::BeginMainFrame", "args": {}})
    return {"traceEvents": events}


QUEUE = [
    ("browser", "Browser", "CrBrowserMain", "chrome/browser/media/router/discovery/dial/dial_service_impl.cc:StartDiscovery", 0.06),
    ("gpu", "GPU Process", "VizCompositorThread", "components/viz/service/display/display_scheduler.cc:OnBeginFrame", 0.03),
    ("browser", "Browser", "ThreadPoolBackgroundWorker", "components/update_client/update_checker.cc:CheckForUpdates", 0.02),
    ("browser", "Browser", "ThreadPoolForegroundWorker", "../../google_apis/gcm/engine/heartbeat_manager.cc:OnHeartbeatTriggered", 0.02),
    ("network", "Service: network.mojom.NetworkService", "ThreadPoolForegroundWorker",
     "net/nqe/network_quality_estimator.cc:ComputeEffectiveConnectionType", 0.02),
    ("renderer", "Renderer", "CrRendererMain", "third_party/blink/renderer/core/timing/dom_timer.cc:Fired", 0.02),
    ("storage", "Service: storage.mojom.StorageService", "CrUtilityMain",
     "components/services/storage/dom_storage/session_storage_impl.cc:Flush", 0.02),
]


class PostedTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.trace = os.path.join(self.dir.name, "chromium-trace.json")
        with open(self.trace, "w") as f:
            json.dump(recorded_trace(), f)
        summary = probe.chromium_summary(self.trace, SECONDS)
        self.counts, self.urls = summary["task_counts"], summary["renderer_urls"]

    def tearDown(self):
        self.dir.cleanup()

    def queue(self):
        return probe.queue_rows(self.counts, SECONDS, self.urls)

    def test_queue_has_every_process_kind_above_threshold_and_nothing_else(self):
        rows = self.queue()
        self.assertEqual([(r["kind"], r["process"], r["thread"], r["location"], r["per_s"]) for r in rows], QUEUE)
        text = json.dumps(rows)
        for out in ("gpu_watchdog_thread", "proxy_impl", "safe_browsing", "crl_set", "devtools", "simple_watcher"):
            self.assertNotIn(out, text)

    def test_each_queue_line_names_process_and_thread(self):
        for row in self.queue():
            self.assertTrue(row["process"] and row["thread"], row)
            self.assertTrue(row["pids"], row)

    def test_processes_of_one_kind_add_up_and_list_their_pids(self):
        renderer = [r for r in self.queue() if r["kind"] == "renderer"]
        self.assertEqual(len(renderer), 1)
        self.assertEqual(renderer[0]["pids"], [RENDERER, RENDERER2])
        worker = [r for r in self.queue() if r["thread"] == "ThreadPoolBackgroundWorker"]
        self.assertEqual(worker[0]["pids"], [BROWSER])

    def test_extension_and_tracing_processes_are_listed_but_not_queued(self):
        kinds = {r["kind"] for r in probe.posted_rows(self.counts, SECONDS, self.urls)}
        self.assertTrue({"extension", "tracing"} <= kinds, kinds)
        self.assertFalse({"extension", "tracing"} & {r["kind"] for r in self.queue()})

    def test_safe_browsing_crlset_and_the_probe_stay(self):
        stays = {r["stays"]: r["per_s"] for r in probe.posted_rows(self.counts, SECONDS, self.urls) if "stays" in r}
        self.assertEqual(stays, {"probe": 0.09, "Safe Browsing": 0.05, "CRLSet": 0.03})

    def test_seed_list_names_candidate_and_switch(self):
        seeds = {r["seed"]: r["switch"] for r in self.queue() if "seed" in r}
        self.assertEqual(seeds, {"Media Router discovery": "disable-features=MediaRouter", "component updater": None,
                                 "GCM": None, "NetworkQualityEstimator": None})

    def test_crlset_installer_is_not_the_component_updater_seed(self):
        self.assertEqual(probe.classify("chrome/browser/component_updater/crl_set_component_installer.cc:F"),
                         {"stays": "CRLSet"})
        self.assertEqual(probe.classify("chrome/browser/component_updater/registration.cc:F")["seed"], "component updater")

    def test_process_kinds_follow_chromium_process_names(self):
        self.assertEqual(probe.process_kind("Service: audio.mojom.AudioService"), "audio")
        self.assertEqual(probe.process_kind("Service: data_decoder.mojom.DataDecoderService"), "utility")
        self.assertEqual(probe.process_kind("browser 4242"), "browser")
        self.assertEqual(probe.process_kind("Renderer", "chrome-extension://x/background.html"), "extension")
        self.assertEqual(probe.process_kind("Zygote"), "other")

    def test_without_queue_every_location_is_listed_highest_first(self):
        rows = probe.posted_rows(self.counts, SECONDS, self.urls)
        self.assertEqual(len(rows), len(QUEUE) + 7)
        self.assertEqual([r["per_s"] for r in rows], sorted((r["per_s"] for r in rows), reverse=True))
        self.assertTrue({"kind", "process", "thread", "location", "per_s", "pids"} <= set(rows[0]))

    def test_threshold_compares_before_rounding(self):
        counts = {("Browser", BROWSER, "CrBrowserMain", "a.cc:F"): 199}
        self.assertEqual(probe.queue_rows(counts, 10_000.0), [])

    def test_typed_event_posted_from(self):
        args = {"task": {"posted_from": {"file_name": "gcm/engine/heartbeat_manager.cc", "function_name": "Start"}}}
        self.assertEqual(probe.posted_from(args), "gcm/engine/heartbeat_manager.cc:Start")

    def test_pump_comparison_sets_browser_main_beside_pump(self):
        rows = probe.posted_rows(self.counts, SECONDS, self.urls)
        report = probe.pump_comparison(rows, {"work_runs": 4.5, "delayed_requests": 2.0, "work_ms": 9.0}, 3)
        # CrBrowserMain: media router 0.06, CRLSet 0.03, DevTools 0.09.
        self.assertEqual(report, {"browser_main_tasks_per_s": 0.18, "early_passes": 3,
                                  "work_runs_per_s": 4.5, "delayed_requests_per_s": 2.0})

    def test_print_posted_emits_queue_then_stays_then_pump(self):
        out = io.StringIO()
        with redirect_stdout(out):
            probe.print_posted(self.counts, SECONDS, True, {"work_runs": 1.0}, 0, self.urls)
        lines = out.getvalue().splitlines()
        self.assertEqual([line.split(" ", 1)[0] for line in lines],
                         ["CEF-IDLE-POSTED"] * len(QUEUE) + ["CEF-IDLE-POSTED-STAYS"] * 3 + ["CEF-IDLE-POSTED-PUMP"])
        self.assertEqual(json.loads(lines[0].split(" ", 1)[1])["thread"], "CrBrowserMain")

    def test_cli_reads_a_recorded_trace(self):
        run = subprocess.run([sys.executable, "-I", PROBE, "--trace", self.trace, "--seconds", str(SECONDS), "--queue"],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stderr)
        posted = [json.loads(line.split(" ", 1)[1]) for line in run.stdout.splitlines() if line.startswith("CEF-IDLE-POSTED ")]
        self.assertEqual([(r["kind"], r["thread"]) for r in posted], [(k, t) for k, _, t, _, _ in QUEUE])

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

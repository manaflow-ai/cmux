#!/usr/bin/env python3
"""bench_idle.py tabs-10 (p12-perf-process-034): the 10-page plan over 3 workspaces, the actions that build it (sent
once, the workspace count checked), the process set (every Chromium process of the app, its WebKit XPC processes),
the engine checks (each page's own navigator.vendor; real Chromium per debug.cef; WebKit with Chromium not started
and no Chromium process), the one shown page, interrupt-wakeup rows and metrics (main wakes timed by their own
reads; helpers that come or go are notes), the window that reads the app only at its ends, the result-v1 records
with their target references, the exit 2 paths of main()'s scenario loop, and the one rusage reader of every
scenario, checked against the idle-tabs stories and the files they reference. Runs anywhere (no libproc, no app).
Run: python3 -I scripts/cmux-next/tests/test_bench_idle_tabs.py"""
import importlib.util, json, os, re, socket, sys, types, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(HERE, ".."))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


bi = load("bench_idle", os.path.join(HERE, "..", "bench_idle.py"))
procs = sys.modules["procs"]
perf_result = load("perf_result", os.path.join(ROOT, "scripts", "perf-lab", "perf_result.py"))
catalog = load("catalog", os.path.join(ROOT, "scripts", "perf-lab", "catalog.py"))

KEYS = [key for _workspace, key in bi.tabs10_plan()]
READY_CEF = {"state": "ready", "unavailable": None, "fallback": None, "default_engine": "chromium"}
IDLE_CEF = {"state": "idle", "unavailable": None, "fallback": None, "default_engine": "webkit"}
CHROMIUM_VENDORS = {key: "Google Inc." for key in KEYS}
WEBKIT_VENDORS = {key: "Apple Computer, Inc." for key in KEYS}
THREE_WORKSPACES = {"result": {"topology": {"workspaces": [{"id": "w1"}, {"id": "w2"}, {"id": "w3"}]}}}


class FakeControl:
    """A control socket that answers each method from `answers` ({method or action: reply}) and logs every call.
    A reply that is an exception is raised."""

    def __init__(self, answers=None, log=None):
        self.answers = {"snapshot.get": THREE_WORKSPACES, **(answers or {})}
        self.calls = []
        self.log = log if log is not None else []

    def call(self, method, params=None, timeout=None):
        self.calls.append((method, params))
        self.log.append(("rpc", method))
        if method == "action.run":
            answer = self.answers.get(params["action"], {"result": {}})
            answer = answer.pop(0) if isinstance(answer, list) else answer
        else:
            answer = self.answers.get(method, {"result": {}})
        if isinstance(answer, BaseException):
            raise answer
        return answer


class FakePages:
    def __init__(self, loaded=(), visibility=None, vendors=None):
        self.loaded = set(loaded)
        self.visibility = dict(visibility or {})
        self.vendors = dict(vendors or {})

    def url(self, kind, n):
        return f"http://127.0.0.1:1/{kind}-{n}"


def usage(cpu_ns=0, interrupt=0, pkg_idle=0, footprint=1048576):
    return procs.Usage(cpu_ns=cpu_ns, interrupt_wakeups=interrupt, pkg_idle_wakeups=pkg_idle, footprint=footprint)


class PlanTests(unittest.TestCase):
    def test_ten_pages_over_three_workspaces_the_last_shown(self):
        plan = bi.tabs10_plan()
        self.assertEqual(len(plan), 10)
        self.assertEqual(len(set(KEYS)), 10)
        self.assertEqual(sorted({workspace for workspace, _key in plan}), [0, 1, 2])
        self.assertEqual([workspace for workspace, _key in plan], sorted(workspace for workspace, _key in plan))

    def test_config_sets_freeze_and_webkit_default_under_any_setting(self):
        self.assertEqual(bi.tabs10_config("chromium", {}), {"browser": {"freezeHiddenTabs": bi.TABS10_FREEZE_S}})
        self.assertEqual(bi.tabs10_config("webkit", {})["browser"]["defaultEngine"], "webkit")
        given = {"browser": {"freezeHiddenTabs": "off"}}
        self.assertEqual(bi.tabs10_config("chromium", given)["browser"]["freezeHiddenTabs"], "off")

    def test_settle_outlasts_the_hidden_tab_freeze(self):
        self.assertGreater(bi.TABS10_SETTLE_MIN_S, bi.TABS10_FREEZE_S)


class BuildTests(unittest.TestCase):
    def build(self, engine="chromium", answers=None, loaded=lambda pages, key: True):
        control = FakeControl(answers)
        with mock.patch.object(bi.time, "sleep"):
            reason = bi.build_tabs10(control, FakePages(), engine, loaded=loaded)
        return reason, control.calls

    @staticmethod
    def actions(calls):
        return [params["action"] for method, params in calls if method == "action.run"]

    def test_new_workspace_before_each_later_workspace_and_every_page_selected(self):
        for engine in bi.ENGINES:
            reason, calls = self.build(engine)
            self.assertIsNone(reason)
            actions = self.actions(calls)
            self.assertEqual(actions.count("newTab"), 2)
            self.assertEqual(actions.count(f"openBrowser.{engine}"), 10)
            self.assertEqual(actions.index("newTab"), 4)
            self.assertEqual(actions.index("newTab", 5), 8)
            runs = [params for method, params in calls if method == "action.run"]
            self.assertTrue(all(params["focus"] and params["origin"] == "script" for params in runs))
            urls = [params["args"]["url"] for params in runs if params["action"].startswith("openBrowser")]
            self.assertEqual(urls, [f"http://127.0.0.1:1/engine-{key}" for key in KEYS])
            self.assertEqual(calls[-1][0], "snapshot.get")

    def test_open_timeout_is_no_refusal_the_load_decides(self):
        reason, calls = self.build(answers={"openBrowser.chromium": {"error": {"code": "timeout"}}})
        self.assertIsNone(reason)
        self.assertEqual(len(self.actions(calls)), 12)  # no retry of an open that may have happened

    def test_new_workspace_timeout_is_not_retried_the_count_decides(self):
        def answers():
            return {"newTab": [{"error": {"code": "timeout"}}, {"result": {}}]}

        reason, calls = self.build(answers=answers())
        self.assertIsNone(reason)
        self.assertEqual(self.actions(calls).count("newTab"), 2)
        # A timed-out newTab that never ran leaves 2 workspaces; one that ran twice (or a restored session) 4.
        for workspaces in (2, 4):
            snapshot = {"result": {"topology": {"workspaces": [{"id": f"w{i}"} for i in range(workspaces)]}}}
            reason, _calls = self.build(answers=dict(answers(), **{"snapshot.get": snapshot}))
            self.assertIn(f"{workspaces} workspaces after the build, expected 3", reason)
        reason, _calls = self.build(answers={"snapshot.get": {"error": {"code": "unknown_method"}}})
        self.assertIn("None workspaces", reason)

    def test_refusal_and_unloaded_page_are_skip_reasons(self):
        reason, _calls = self.build(answers={"openBrowser.webkit": {"error": {"code": "denied"}}}, engine="webkit")
        self.assertIn("openBrowser.webkit refused", reason)
        reason, _calls = self.build(answers={"newTab": {"error": {"code": "denied"}}})
        self.assertIn("newTab refused", reason)
        reason, _calls = self.build(loaded=lambda pages, key: key != "t5")
        self.assertIn("page t5 did not load", reason)


class ProcessSetTests(unittest.TestCase):
    APP = "/A/cmux DEV t.app"
    FW = f"{APP}/Contents/Frameworks"

    def test_every_chromium_process_and_the_webkit_xpc_processes(self):
        commands = {
            1: f"{self.APP}/Contents/MacOS/cmux DEV",
            # A grandchild renderer (under the Chromium Host) and a GPU process: not direct children of the app.
            7: f"{self.APP}/Contents/MacOS/cmux DEV t Chromium Host --framework=/x",
            8: f"{self.FW}/cmux DEV t Helper (Renderer).app/Contents/MacOS/cmux DEV t Helper (Renderer) --type=renderer",
            9: f"{self.FW}/cmux DEV t Helper (GPU).app/Contents/MacOS/cmux DEV t Helper (GPU) --type=gpu-process",
            20: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/"
                "Contents/MacOS/com.apple.WebKit.WebContent",
            21: "/usr/sbin/something-else",
        }
        instance = types.SimpleNamespace(pids=lambda: dict(commands))
        with mock.patch.object(bi, "classify", lambda pid, bundle: {1: "app", 2: "daemon"}), \
                mock.patch.object(bi.procs, "Instance", lambda bundle, pid: instance):
            kinds = bi.tab_kinds(1, self.APP)
        self.assertEqual(kinds, {1: "app", 2: "daemon", 7: "cef-host", 8: "cef-renderer", 9: "cef-gpu",
                                 20: "webkit-webcontent"})


class EngineCheckTests(unittest.TestCase):
    def problems(self, engine, cef, kinds, vendors, loaded=KEYS):
        return bi.engine_problems(engine, cef, kinds, set(loaded), KEYS, vendors)

    def test_real_chromium(self):
        kinds = {1: "app", 2: "daemon", 3: "cef-renderer", 4: "cef-gpu"}
        self.assertEqual(self.problems("chromium", READY_CEF, kinds, CHROMIUM_VENDORS), [])

    def test_chromium_refused_without_a_ready_engine_or_renderer(self):
        kinds = {1: "app", 3: "cef-renderer"}
        fallback = dict(READY_CEF, fallback={"count": 1})
        self.assertTrue(any("WebKit fallbacks" in p for p in self.problems("chromium", fallback, kinds, CHROMIUM_VENDORS)))
        starting = dict(READY_CEF, state="loading")
        self.assertTrue(any("not ready" in p for p in self.problems("chromium", starting, kinds, CHROMIUM_VENDORS)))
        unavailable = dict(READY_CEF, unavailable={"code": "notBundled"})
        self.assertTrue(any("unavailable" in p for p in self.problems("chromium", unavailable, kinds, CHROMIUM_VENDORS)))
        self.assertIn("no Chromium renderer process", self.problems("chromium", READY_CEF, {1: "app"}, CHROMIUM_VENDORS))
        self.assertTrue(self.problems("chromium", None, kinds, CHROMIUM_VENDORS))
        self.assertTrue(self.problems("chromium", {"error": {"code": "unknown_method"}}, kinds, CHROMIUM_VENDORS))

    def test_chromium_spare_renderer_does_not_stand_in_for_the_pages(self):
        # A ready engine and a renderer (ChromiumWarmup's spare window), but the pages opened in WebKit.
        kinds = {1: "app", 3: "cef-renderer", 5: "webkit-webcontent"}
        problems = self.problems("chromium", READY_CEF, kinds, WEBKIT_VENDORS)
        self.assertTrue(any("not drawn by chromium" in p for p in problems))
        one_wrong = dict(CHROMIUM_VENDORS, t3="Apple Computer, Inc.")
        self.assertTrue(any("t3=" in p for p in self.problems("chromium", READY_CEF, kinds, one_wrong)))

    def test_real_webkit(self):
        kinds = {1: "app", 5: "webkit-webcontent", 6: "webkit-networking"}
        self.assertEqual(self.problems("webkit", IDLE_CEF, kinds, WEBKIT_VENDORS), [])
        self.assertEqual(self.problems("webkit", dict(IDLE_CEF, state="shutDown"), kinds, WEBKIT_VENDORS), [])

    def test_webkit_refused_when_the_pages_are_not_webkit(self):
        # The app's own WKWebViews give a WebContent process even when the tabs are Chromium: the vendor decides.
        kinds = {1: "app", 5: "webkit-webcontent"}
        self.assertTrue(any("not drawn by webkit" in p for p in self.problems("webkit", IDLE_CEF, kinds, CHROMIUM_VENDORS)))
        self.assertTrue(any("not drawn by webkit" in p for p in self.problems("webkit", IDLE_CEF, kinds, {})))

    def test_webkit_refused_when_chromium_runs_in_any_form(self):
        kinds = {1: "app", 5: "webkit-webcontent"}
        for extra in ("cef-gpu", "cef-utility", "cef-host", "cef-renderer"):
            problems = self.problems("webkit", IDLE_CEF, {**kinds, 9: extra}, WEBKIT_VENDORS)
            self.assertTrue(any("Chromium processes run" in p and extra in p for p in problems), extra)
        for state in bi.CEF_STARTED:
            problems = self.problems("webkit", dict(IDLE_CEF, state=state), kinds, WEBKIT_VENDORS)
            self.assertTrue(any(f"Chromium state {state}" in p for p in problems), state)
        problems = self.problems("webkit", dict(IDLE_CEF, default_engine="chromium"), kinds, WEBKIT_VENDORS)
        self.assertTrue(any("default engine chromium" in p for p in problems))
        self.assertTrue(self.problems("webkit", {"error": "x"}, kinds, WEBKIT_VENDORS))
        self.assertTrue(self.problems("webkit", None, kinds, WEBKIT_VENDORS))

    def test_unloaded_pages_named(self):
        problems = self.problems("webkit", IDLE_CEF, {5: "webkit-webcontent"}, WEBKIT_VENDORS, loaded=KEYS[:-1])
        self.assertEqual(problems, [f"page {KEYS[-1]} never loaded"])

    def test_exactly_the_last_page_shown(self):
        hidden = {key: "hidden" for key in KEYS}
        self.assertEqual(bi.shown_problems(dict(hidden, **{KEYS[-1]: "visible"}), KEYS), [])
        self.assertTrue(bi.shown_problems(hidden, KEYS))
        self.assertTrue(bi.shown_problems(dict(hidden, **{KEYS[0]: "visible", KEYS[-1]: "visible"}), KEYS))


class MetricTests(unittest.TestCase):
    KINDS = {10: "app", 11: "daemon", 12: "terminal-host", 13: "cef-renderer", 14: "cef-gpu", 15: "webkit-webcontent"}

    def rows(self, end_overrides=None, kinds=None):
        kinds = kinds or self.KINDS
        start = {pid: usage() for pid in kinds}
        end = {10: usage(cpu_ns=10**8, interrupt=30, pkg_idle=20), 11: usage(interrupt=12),
               12: usage(), 13: usage(interrupt=6), 14: usage(interrupt=60), 15: usage(interrupt=3)}
        end.update(end_overrides or {})
        return bi.window_rows(kinds, start, end, 60.0)

    def test_interrupt_wakeups_only(self):
        app = next(row for row in self.rows() if row["kind"] == "app")
        self.assertEqual(app["wakeups_per_s"], 0.5)  # 30 interrupt wakeups in 60 s; package-idle apart
        self.assertEqual(app["pkg_idle_wakeups_per_s"], 0.333)
        self.assertAlmostEqual(app["cpu_percent"], 0.167, places=3)

    def test_metrics(self):
        metrics = bi.tabs10_metrics(self.rows(), (100, 115), 60.0)
        self.assertEqual(set(metrics), set(bi.TABS10_METRICS))
        self.assertEqual(metrics["idle.tabs-10.app_wakeups_per_s"], 0.5)
        self.assertEqual(metrics["idle.tabs-10.daemon_wakeups_per_s"], 0.2)
        self.assertEqual(metrics["idle.tabs-10.app_daemon_wakeups_per_s"], 0.7)
        self.assertEqual(metrics["idle.tabs-10.main_wakes_per_s"], 0.25)
        self.assertEqual(metrics["idle.tabs-10.helper_wakeups_per_s"], 1.15)  # Chromium and WebKit, no terminal host

    def test_main_wakes_divided_by_their_own_span(self):
        # 15 wakes between debug.hangs replies 62 s apart; the counter window is 60 s.
        self.assertEqual(bi.tabs10_metrics(self.rows(), (100, 115), 62.0)["idle.tabs-10.main_wakes_per_s"], 0.242)

    def test_partial_judged_kind_has_no_value(self):
        metrics = bi.tabs10_metrics(self.rows({11: None}), None, 60.0)
        self.assertIsNone(metrics["idle.tabs-10.daemon_wakeups_per_s"])
        self.assertIsNone(metrics["idle.tabs-10.app_daemon_wakeups_per_s"])
        self.assertIsNone(metrics["idle.tabs-10.main_wakes_per_s"])
        self.assertEqual(metrics["idle.tabs-10.app_wakeups_per_s"], 0.5)

    def test_partial_helper_is_a_note_not_a_missing_value(self):
        # A transient Chromium utility process came and a WebKit process went inside the window.
        kinds = {**self.KINDS, 16: "cef-utility"}
        rows = self.rows({15: None}, kinds)
        metrics = bi.tabs10_metrics(rows, (100, 115), 60.0)
        self.assertEqual(metrics["idle.tabs-10.helper_wakeups_per_s"], 1.1)  # the complete renderer and GPU rows
        self.assertEqual(metrics["idle.tabs-10.app_daemon_wakeups_per_s"], 0.7)
        notes = bi.helper_notes(rows)
        self.assertEqual(len(notes), 2)
        self.assertTrue(any("cef-utility 16" in note for note in notes))
        self.assertTrue(any("webkit-webcontent 15" in note for note in notes))
        bench = FakeBench()
        _paths, failures = bi.record_tabs10(bench, "chromium", dict(metrics, **{"idle.tabs-10.helper_wakeups_per_s": None}),
                                            perf_result.TargetRef)
        self.assertEqual(failures, [])  # a reported metric with no value writes nothing and fails nothing

    def test_main_wakes_of(self):
        self.assertEqual(bi.main_wakes_of({"result": {"main_wakes": 7}}), 7)
        self.assertIsNone(bi.main_wakes_of({"error": {"code": "unknown_method"}}))
        self.assertIsNone(bi.main_wakes_of({"result": {"main_wakes": True}}))


class WindowTests(unittest.TestCase):
    def run_window(self, control, engine="chromium", kinds=None, vendors=CHROMIUM_VENDORS, log=None):
        log = log if log is not None else []
        clock = types.SimpleNamespace(now=0.0)

        def sleep(seconds):
            log.append(("sleep", seconds))
            clock.now += seconds

        def scan(pid, bundle):
            clock.now += 0.5  # a ps scan and a responsibility call per process
            return dict(kinds or {1: "app", 2: "daemon", 3: "cef-renderer"})

        fake_procs = types.SimpleNamespace(usage=lambda pid: log.append(("usage", pid)) or usage(interrupt=60 * pid),
                                           rates=procs.rates)
        pages = FakePages(KEYS, {key: "hidden" for key in KEYS[:-1]} | {KEYS[-1]: "visible"}, vendors)
        with mock.patch.object(bi, "procs", fake_procs), \
                mock.patch.object(bi, "tab_kinds", scan), \
                mock.patch.object(bi.time, "sleep", sleep), \
                mock.patch.object(bi.time, "monotonic", lambda: clock.now):
            return bi.measure_tabs10(1, "/x.app", 60, control, engine, pages, KEYS)

    def test_no_app_read_inside_the_window_and_main_wakes_timed_by_their_reads(self):
        log = []
        hangs = [{"result": {"main_wakes": 100}}, {"result": {"main_wakes": 106}}]
        control = FakeControl({"debug.cef": {"result": READY_CEF}}, log)
        original_call = control.call

        def call(method, params=None, timeout=None):
            reply = original_call(method, params, timeout)
            return hangs.pop(0) if method == "debug.hangs" else reply

        control.call = call
        result = self.run_window(control, log=log)
        reads = [i for i, entry in enumerate(log) if entry[0] == "usage"]
        inside = [entry for entry in log[reads[0]:reads[-1] + 1] if entry[0] == "rpc"]
        self.assertEqual(inside, [])
        self.assertIn(("sleep", bi.QUIET_GAP_S), log[:reads[0]])
        self.assertEqual([m for m, _p in control.calls], ["debug.hangs", "debug.hangs", "debug.cef"])
        self.assertEqual(result["engine_problems"], [])
        self.assertEqual(result["wall_s"], 60.0)
        # 1 s quiet gap + two 0.5 s scans + 60 s: 6 wakes over 62 s, not over the counters' 60 s.
        self.assertEqual(result["main_wakes_span_s"], 62.0)
        self.assertEqual(result["metrics"]["idle.tabs-10.main_wakes_per_s"], 0.097)
        self.assertEqual(result["notes"], [])
        self.assertEqual(result["vendors"], CHROMIUM_VENDORS)

    def test_webkit_window_reads_debug_cef(self):
        control = FakeControl({"debug.cef": {"result": dict(IDLE_CEF, state="ready")},
                               "debug.hangs": {"result": {"main_wakes": 1}}})
        result = self.run_window(control, "webkit", {1: "app", 2: "daemon", 5: "webkit-webcontent"}, WEBKIT_VENDORS)
        self.assertTrue(any("Chromium state ready" in p for p in result["engine_problems"]))


class FakeBench:
    def __init__(self, fail_on=None, error=RuntimeError("no features.list snapshot")):
        self.records = []
        self.fail_on = fail_on
        self.error = error

    def record(self, story, metric, unit, samples, better, engine, target_ref=None):
        if metric == self.fail_on:
            raise self.error
        self.records.append((story, metric, unit, samples, better, engine, target_ref))
        return f"/out/{metric}.ndjson"


class RecordTests(unittest.TestCase):
    METRICS = {name: 0.25 for name in bi.TABS10_METRICS}

    def test_each_metric_one_result_with_its_reference(self):
        for engine in bi.ENGINES:
            bench = FakeBench()
            paths, failures = bi.record_tabs10(bench, engine, self.METRICS, perf_result.TargetRef)
            self.assertEqual(failures, [])
            self.assertEqual(len(paths), len(bi.TABS10_METRICS))
            refs = {metric: ref for _story, metric, _unit, _samples, _better, _engine, ref in bench.records}
            self.assertEqual(refs["idle.tabs-10.app_daemon_wakeups_per_s"], f"idle-wakeups.{engine}")
            self.assertEqual(refs["idle.tabs-10.main_wakes_per_s"], f"idle-wakeups.{engine}")
            self.assertEqual(refs["idle.tabs-10.app_wakeups_per_s"],
                             perf_result.TargetRef(path=bi.IDLE_BUDGET, key="/kinds/app/wakeups_per_s"))
            self.assertIsNone(refs["idle.tabs-10.helper_wakeups_per_s"])
            self.assertEqual({r[0] for r in bench.records}, {bi.TABS10_STORIES[engine]})
            self.assertEqual({(r[2], r[4], r[5]) for r in bench.records}, {("per_s", "lower", engine)})

    def test_unmeasured_or_refused_metric_is_reported(self):
        metrics = dict(self.METRICS, **{"idle.tabs-10.main_wakes_per_s": None})
        bench = FakeBench(fail_on="idle.tabs-10.app_wakeups_per_s")
        paths, failures = bi.record_tabs10(bench, "chromium", metrics, perf_result.TargetRef)
        self.assertEqual(len(paths), len(bi.TABS10_METRICS) - 2)
        self.assertEqual(len(failures), 2)

    def test_a_file_error_is_a_failure_not_a_traceback(self):
        bench = FakeBench(fail_on="idle.tabs-10.daemon_wakeups_per_s", error=OSError(28, "No space left on device"))
        paths, failures = bi.record_tabs10(bench, "webkit", self.METRICS, perf_result.TargetRef)
        self.assertEqual(len(paths), len(bi.TABS10_METRICS) - 1)
        self.assertTrue(any("No space left" in failure for failure in failures))

    def test_invalid_pages_write_nothing(self):
        bench = FakeBench()
        result = {"engine_problems": ["no Chromium renderer process"], "metrics": self.METRICS}
        invalid = bi.judge_tabs10(result, bench, "chromium", perf_result.TargetRef)
        self.assertEqual(bench.records, [])
        self.assertIn("no Chromium renderer process", invalid)
        self.assertEqual(bi.judge_tabs10(dict(result, engine_problems=[]), bench, "chromium", perf_result.TargetRef), [])
        self.assertEqual(len(bench.records), len(bi.TABS10_METRICS))

    def test_result_validates_as_result_v1(self):
        ref = perf_result.TargetRef(path=bi.IDLE_BUDGET, key="/kinds/daemon/wakeups_per_s")
        self.assertEqual(perf_result.TargetRef.from_dict(ref.to_dict()), ref)
        self.assertTrue(all(re.match(perf_result.NAME_PATTERN, m) for m in bi.TABS10_METRICS))
        self.assertTrue(all(re.match(perf_result.NAME_PATTERN, s) for s in bi.TABS10_STORIES.values()))


class FakeApp:
    def __init__(self, returncode=None):
        self.returncode = returncode

    def poll(self):
        return self.returncode


class RunTests(unittest.TestCase):
    """main()'s scenario loop and exit code: every way tabs-10 can end without a valid result is exit 2, with the
    report still written by main (no traceback)."""

    ARGS = types.SimpleNamespace(engine="chromium", settle=0, measure=60, url="http://x/", no_fail=True)

    def run_loop(self, app, control, measured=None):
        report = {"scenarios": {}}
        writer = types.SimpleNamespace(TargetRef=perf_result.TargetRef)
        with mock.patch.object(bi, "prepare", lambda *a, **k: None), \
                mock.patch.object(bi, "load_by_path", lambda *a: writer), \
                mock.patch.object(bi, "measure_tabs10", measured or (lambda *a: (_ for _ in ()).throw(AssertionError))), \
                mock.patch.object(bi.time, "sleep"):
            failures, invalid = bi.run_scenarios([bi.TABS10], app, control, self.ARGS, 1, "/x.app", FakePages(),
                                                 FakeBench(), report)
        return report, failures, invalid

    def test_app_gone_before_the_scenario_is_invalid(self):
        report, failures, invalid = self.run_loop(FakeApp(-9), FakeControl())
        self.assertEqual(report["app_exit"], -9)
        self.assertTrue(failures)
        self.assertTrue(invalid)
        self.assertEqual(bi.exit_code(failures, invalid, no_fail=True), 2)

    def test_socket_errors_in_the_window_are_invalid(self):
        for error in (ConnectionError("socket closed"), socket.timeout("timed out"), TimeoutError("timed out"),
                      json.JSONDecodeError("Expecting value", "", 0)):
            def measured(*_args, error=error):
                raise error

            report, failures, invalid = self.run_loop(FakeApp(), FakeControl(), measured)
            self.assertIn("measure failed", report["scenarios"][bi.TABS10]["skipped"])
            self.assertTrue(any("measure failed" in reason for reason in invalid), error)
            self.assertEqual(failures, [])
            self.assertEqual(bi.exit_code(failures, invalid, no_fail=True), 2)

    def test_a_valid_window_writes_results_and_exits_0(self):
        metrics = {name: 0.25 for name in bi.TABS10_METRICS}

        def measured(*_args):
            return {"processes": [], "metrics": metrics, "engine_problems": [], "notes": []}

        report, failures, invalid = self.run_loop(FakeApp(), FakeControl(), measured)
        self.assertEqual((failures, invalid), ([], []))
        self.assertEqual(len(report["scenarios"][bi.TABS10]["results"]), len(bi.TABS10_METRICS))
        self.assertEqual(bi.exit_code(failures, invalid, no_fail=False), 0)

    def test_exit_codes(self):
        self.assertEqual(bi.exit_code([], [], False), 0)
        self.assertEqual(bi.exit_code(["x"], [], False), 1)
        self.assertEqual(bi.exit_code(["x"], [], True), 0)
        self.assertEqual(bi.exit_code([], ["y"], True), 2)
        self.assertEqual(bi.exit_code(["x"], ["y"], False), 2)

    def test_legacy_limits_do_not_judge_tabs10(self):
        args = types.SimpleNamespace(max_cpu=0.5, max_wakeups=5, max_host_cpu=0.2, max_host_wakeups=2, max_helper_cpu=1)
        rows = [{"pid": 1, "kind": "app", "cpu_percent": 9.0, "wakeups_per_s": 99.0}]
        self.assertEqual(bi.criteria(bi.TABS10, {"processes": rows}, args), [])
        self.assertEqual(len(bi.criteria("chromium-static", {"processes": rows}, args)), 2)


class UsageTests(unittest.TestCase):
    """Every scenario reads one wakeup definition: procs.usage's interrupt wakeups (package-idle not added)."""

    def test_usage_is_procs_usage(self):
        with mock.patch.object(bi.procs, "usage", lambda pid: usage(cpu_ns=5, interrupt=7, pkg_idle=4, footprint=9)):
            self.assertEqual(bi.usage(3), (5, 7, 9))
        with mock.patch.object(bi.procs, "usage", lambda pid: None):
            self.assertIsNone(bi.usage(3))
        self.assertFalse(hasattr(bi, "_darwin"))

    def test_legacy_scenarios_use_interrupt_wakeups(self):
        clock = types.SimpleNamespace(now=0.0)
        reads = iter([usage(interrupt=0, pkg_idle=0), usage(interrupt=60, pkg_idle=600)])
        control = FakeControl({"debug.wakeups": {"result": {}}, "debug.hangs": {"result": {}}})
        with mock.patch.object(bi, "classify", lambda pid, bundle: {1: "app"}), \
                mock.patch.object(bi.procs, "usage", lambda pid: next(reads)), \
                mock.patch.object(bi.time, "sleep", lambda s: setattr(clock, "now", clock.now + s)), \
                mock.patch.object(bi.time, "monotonic", lambda: clock.now):
            result = bi.measure(1, "/x.app", 60, control)
        self.assertEqual(result["processes"][0]["wakeups_per_s"], 1.0)
        self.assertEqual(result["processes"][0]["pkg_idle_wakeups_per_s"], 10.0)


class StoryTests(unittest.TestCase):
    def test_stories_match_the_bench(self):
        loaded = catalog.load_catalog(catalog.REPO_ROOT)
        self.assertEqual([p for p in loaded.problems if "idle-tabs" in p], [])
        stories = {story.id: story for story in loaded.stories}
        for engine, story_id in bi.TABS10_STORIES.items():
            story = stories[story_id]
            self.assertEqual(story.engine, engine)
            self.assertIn("--engine", story.command)
            self.assertIn("--fresh", story.command)  # build_tabs10 refuses a session that is not the plan's 3 workspaces
            self.assertEqual(story.command[story.command.index("--engine") + 1], engine)
            self.assertEqual(story.command[story.command.index("--scenarios") + 1], bi.TABS10)
            self.assertIn("debug:debug.cef", story.needs)  # both arms read it in engine_problems
            for metric, ref in bi.TABS10_METRICS.items():
                matching = [m for m in story.metrics if re.fullmatch(m.name, metric)]
                self.assertEqual(len(matching), 1, f"{story_id}: {metric}")
                claimed = matching[0]
                if ref and "target" in ref:
                    self.assertEqual(claimed.target, ref["target"].format(engine=engine))
                elif ref:
                    self.assertEqual((claimed.target_ref.path, claimed.target_ref.key), (ref["path"], ref["key"]))
                else:
                    self.assertIsNone(claimed.target)
                    self.assertIsNone(claimed.target_ref)

    def test_budget_kind_references_are_numbers(self):
        with open(os.path.join(ROOT, bi.IDLE_BUDGET)) as handle:
            budget = json.load(handle)
        for ref in bi.TABS10_METRICS.values():
            if ref and "path" in ref:
                _empty, _kinds, kind, field = ref["key"].split("/")
                self.assertIsInstance(budget["kinds"][kind][field], (int, float))


if __name__ == "__main__":
    unittest.main()

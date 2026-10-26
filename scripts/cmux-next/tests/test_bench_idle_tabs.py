#!/usr/bin/env python3
"""bench_idle.py tabs-10 (p12-perf-process-034): the 10-page plan over 3 workspaces, the actions that build it, the
engine checks (real Chromium per debug.cef, real WebKit), the one shown page, interrupt-wakeup rows and metrics, the
window that reads the app only at its ends, and the result-v1 records with their target references, checked against
the idle-tabs stories and the files they reference. Runs anywhere (no libproc, no app).
Run: python3 -I scripts/cmux-next/tests/test_bench_idle_tabs.py"""
import importlib.util, json, os, re, sys, types, unittest
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
READY_CEF = {"state": "ready", "unavailable": None, "fallback": None}


class FakeControl:
    """A control socket that answers each method from `answers` ({method or action: reply}) and logs every call."""

    def __init__(self, answers=None, log=None):
        self.answers = answers or {}
        self.calls = []
        self.log = log if log is not None else []

    def call(self, method, params=None, timeout=None):
        self.calls.append((method, params))
        self.log.append(("rpc", method))
        if method == "action.run":
            answer = self.answers.get(params["action"], {"result": {}})
            return answer.pop(0) if isinstance(answer, list) else answer
        return self.answers.get(method, {"result": {}})


class FakePages:
    def __init__(self, loaded=(), visibility=None):
        self.loaded = set(loaded)
        self.visibility = dict(visibility or {})

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

    def test_new_workspace_before_each_later_workspace_and_every_page_selected(self):
        for engine in bi.ENGINES:
            reason, calls = self.build(engine)
            self.assertIsNone(reason)
            actions = [params["action"] for _method, params in calls]
            self.assertEqual(actions.count("newTab"), 2)
            self.assertEqual(actions.count(f"openBrowser.{engine}"), 10)
            self.assertEqual(actions.index("newTab"), 4)
            self.assertEqual(actions.index("newTab", 5), 8)
            self.assertTrue(all(params["focus"] and params["origin"] == "script" for _method, params in calls))
            urls = [params["args"]["url"] for _method, params in calls if params["action"].startswith("openBrowser")]
            self.assertEqual(urls, [f"http://127.0.0.1:1/static-{key}" for key in KEYS])

    def test_open_timeout_is_no_refusal_the_load_decides(self):
        reason, calls = self.build(answers={"openBrowser.chromium": {"error": {"code": "timeout"}}})
        self.assertIsNone(reason)
        self.assertEqual(len(calls), 12)  # no retry of an open that may have happened

    def test_new_workspace_timeout_retried(self):
        answers = {"newTab": [{"error": {"code": "timeout"}}, {"result": {}}, {"result": {}}]}
        reason, calls = self.build(answers=answers)
        self.assertIsNone(reason)
        self.assertEqual([params["action"] for _m, params in calls].count("newTab"), 3)

    def test_refusal_and_unloaded_page_are_skip_reasons(self):
        reason, _calls = self.build(answers={"openBrowser.webkit": {"error": {"code": "denied"}}}, engine="webkit")
        self.assertIn("openBrowser.webkit refused", reason)
        reason, _calls = self.build(loaded=lambda pages, key: key != "t5")
        self.assertIn("page t5 did not load", reason)


class EngineCheckTests(unittest.TestCase):
    def test_real_chromium(self):
        kinds = {1: "app", 2: "daemon", 3: "cef-renderer", 4: "cef-gpu"}
        self.assertEqual(bi.engine_problems("chromium", READY_CEF, kinds, set(KEYS), KEYS), [])

    def test_chromium_refused_without_a_ready_engine_or_renderer(self):
        kinds = {1: "app", 3: "cef-renderer"}
        fallback = dict(READY_CEF, fallback={"count": 1})
        self.assertTrue(any("WebKit fallbacks" in p for p in bi.engine_problems("chromium", fallback, kinds, set(KEYS), KEYS)))
        starting = dict(READY_CEF, state="initializing")
        self.assertTrue(any("not ready" in p for p in bi.engine_problems("chromium", starting, kinds, set(KEYS), KEYS)))
        unavailable = dict(READY_CEF, unavailable={"code": "notBundled"})
        self.assertTrue(any("unavailable" in p for p in bi.engine_problems("chromium", unavailable, kinds, set(KEYS), KEYS)))
        self.assertIn("no Chromium renderer process", bi.engine_problems("chromium", READY_CEF, {1: "app"}, set(KEYS), KEYS))
        self.assertTrue(bi.engine_problems("chromium", None, kinds, set(KEYS), KEYS))

    def test_real_webkit(self):
        kinds = {1: "app", 5: "webkit-webcontent", 6: "webkit-networking"}
        self.assertEqual(bi.engine_problems("webkit", {"error": "x"}, kinds, set(KEYS), KEYS), [])
        self.assertIn("no WebKit WebContent process", bi.engine_problems("webkit", {}, {1: "app"}, set(KEYS), KEYS))
        both = {**kinds, 7: "cef-renderer"}
        self.assertTrue(any("may not be WebKit" in p for p in bi.engine_problems("webkit", {}, both, set(KEYS), KEYS)))

    def test_unloaded_pages_named(self):
        problems = bi.engine_problems("webkit", {}, {5: "webkit-webcontent"}, set(KEYS[:-1]), KEYS)
        self.assertEqual(problems, [f"page {KEYS[-1]} never loaded"])

    def test_exactly_the_last_page_shown(self):
        hidden = {key: "hidden" for key in KEYS}
        self.assertEqual(bi.shown_problems(dict(hidden, **{KEYS[-1]: "visible"}), KEYS), [])
        self.assertTrue(bi.shown_problems(hidden, KEYS))
        self.assertTrue(bi.shown_problems(dict(hidden, **{KEYS[0]: "visible", KEYS[-1]: "visible"}), KEYS))


class MetricTests(unittest.TestCase):
    KINDS = {10: "app", 11: "daemon", 12: "terminal-host", 13: "cef-renderer", 14: "cef-gpu", 15: "webkit-webcontent"}

    def rows(self, end_overrides=None):
        start = {pid: usage() for pid in self.KINDS}
        end = {10: usage(cpu_ns=10**8, interrupt=30, pkg_idle=20), 11: usage(interrupt=12),
               12: usage(), 13: usage(interrupt=6), 14: usage(interrupt=60), 15: usage(interrupt=3)}
        end.update(end_overrides or {})
        return bi.tabs10_rows(self.KINDS, start, end, 60.0)

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

    def test_partial_kind_has_no_value(self):
        metrics = bi.tabs10_metrics(self.rows({11: None}), None, 60.0)
        self.assertIsNone(metrics["idle.tabs-10.daemon_wakeups_per_s"])
        self.assertIsNone(metrics["idle.tabs-10.app_daemon_wakeups_per_s"])
        self.assertIsNone(metrics["idle.tabs-10.main_wakes_per_s"])
        self.assertEqual(metrics["idle.tabs-10.app_wakeups_per_s"], 0.5)

    def test_main_wakes_of(self):
        self.assertEqual(bi.main_wakes_of({"result": {"main_wakes": 7}}), 7)
        self.assertIsNone(bi.main_wakes_of({"error": {"code": "unknown_method"}}))
        self.assertIsNone(bi.main_wakes_of({"result": {"main_wakes": True}}))


class WindowTests(unittest.TestCase):
    def test_no_app_read_inside_the_window(self):
        log = []
        hangs = [{"result": {"main_wakes": 100}}, {"result": {"main_wakes": 106}}]
        control = FakeControl({"debug.cef": {"result": READY_CEF}}, log)
        control.answers["debug.hangs"] = None
        original_call = control.call

        def call(method, params=None, timeout=None):
            reply = original_call(method, params, timeout)
            return hangs.pop(0) if method == "debug.hangs" else reply

        control.call = call
        clock = types.SimpleNamespace(now=0.0)

        def sleep(seconds):
            log.append(("sleep", seconds))
            clock.now += seconds

        kinds = {1: "app", 2: "daemon", 3: "cef-renderer"}
        fake_procs = types.SimpleNamespace(usage=lambda pid: log.append(("usage", pid)) or usage(interrupt=60 * pid),
                                           rates=procs.rates)
        pages = FakePages(KEYS, {key: "hidden" for key in KEYS[:-1]} | {KEYS[-1]: "visible"})
        with mock.patch.object(bi, "procs", fake_procs), \
                mock.patch.object(bi, "tab_kinds", lambda pid, bundle: dict(kinds)), \
                mock.patch.object(bi.time, "sleep", sleep), \
                mock.patch.object(bi.time, "monotonic", lambda: clock.now):
            result = bi.measure_tabs10(1, "/x.app", 60, control, "chromium", pages, KEYS)
        reads = [i for i, entry in enumerate(log) if entry[0] == "usage"]
        inside = [entry for entry in log[reads[0]:reads[-1] + 1] if entry[0] == "rpc"]
        self.assertEqual(inside, [])
        self.assertIn(("sleep", bi.QUIET_GAP_S), log[:reads[0]])
        self.assertEqual([m for m, _p in control.calls], ["debug.hangs", "debug.hangs", "debug.cef"])
        self.assertEqual(result["engine_problems"], [])
        self.assertEqual(result["metrics"]["idle.tabs-10.main_wakes_per_s"], 0.1)


class FakeBench:
    def __init__(self, fail_on=None):
        self.records = []
        self.fail_on = fail_on

    def record(self, story, metric, unit, samples, better, engine, target_ref=None):
        if metric == self.fail_on:
            raise RuntimeError("no features.list snapshot")
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


class StoryTests(unittest.TestCase):
    def test_stories_match_the_bench(self):
        loaded = catalog.load_catalog(catalog.REPO_ROOT)
        self.assertEqual([p for p in loaded.problems if "idle-tabs" in p], [])
        stories = {story.id: story for story in loaded.stories}
        for engine, story_id in bi.TABS10_STORIES.items():
            story = stories[story_id]
            self.assertEqual(story.engine, engine)
            self.assertIn("--engine", story.command)
            self.assertEqual(story.command[story.command.index("--engine") + 1], engine)
            self.assertEqual(story.command[story.command.index("--scenarios") + 1], bi.TABS10)
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

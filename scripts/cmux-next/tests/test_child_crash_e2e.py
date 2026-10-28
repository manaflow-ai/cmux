#!/usr/bin/env python3
"""child-crash-e2e.py, the crash survival story (p12-perf-process-036):

1. Only pids of the app's own process tree are signalled: a Chromium child by its --type (and the network service by
   its --utility-sub-type), also under a host (F2, grandchildren); a WebKit WebContent only when the app reports it
   and its responsible process is the app's (the app, or the launcher the app inherited responsibility from). Any
   other pid, the app itself, or one whose owner cannot be read is never signalled, and its case is NOT-MEASURABLE;
   in check mode a refused pid the app reported is a FAIL.
2. crash_survival.<engine> is survived/cases (EXPECTED-FAIL left out, NOT-MEASURABLE counted as not survived), one
   sample per launch, with .measured beside it; recover and key->frame series per case, key->frame only from cases
   that crashed something. Every series name matches a metric of its story file, and the survival series claims the
   target row crash-survival.<engine>.
3. The browser CHECK URL is typed only on proof that a host, not the app, runs the tab's renderers; without it (in
   process, or no renderer to read) the case is EXPECTED-FAIL. The host case kills the host that runs the tab's
   renderers and needs the same tab back under a new host. A case whose debug method the build lacks is
   NOT-MEASURABLE.
4. A case that "survived" is DIED when the app no longer runs, or when typing was on and the terminal drew no key
   after the kill (keys before it do not count).
5. The network case kills the network service by exact pid and proves a navigation over the new one.
6. The command line takes exactly one of --socket (check a running app) and --app (launch and measure); check mode
   keeps the capture slot's cases (renderer, gpu, webkit, agent) unless --only names others.

Runs on any host (Linux included): no app, no socket, no signal sent (os.kill is replaced).

    python3 -m unittest scripts/cmux-next/tests/test_child_crash_e2e.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
PERF_LAB = ROOT / "scripts" / "perf-lab"


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


crash = load("child_crash_e2e", HERE / "child-crash-e2e.py")
catalog = load("perf_lab_catalog", PERF_LAB / "catalog.py")
perf_result = load("perf_result", PERF_LAB / "perf_result.py")

APP = 500
PS = f"""\
  1     0 /sbin/launchd
{APP}     1 /Applications/cmux DEV t.app/Contents/MacOS/cmux DEV
  510 {APP} cmux Helper (Renderer) --type=renderer --renderer-client-id=5
  511 {APP} cmux Helper (GPU) --type=gpu-process
  512 {APP} cmux Helper --type=utility --utility-sub-type=network.mojom.NetworkService
  513 {APP} cmux Helper --type=utility --utility-sub-type=storage.mojom.StorageService
  520 {APP} cmux Chromium Host
  521   520 cmux Helper (Renderer) --type=renderer --renderer-client-id=9
  600     1 /System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/WebContent
  700     1 /usr/bin/other --type=renderer
"""


class ProcessTree(unittest.TestCase):
    def setUp(self):
        self.table = crash.parse_ps(PS)

    def test_descendants_include_grandchildren_and_nothing_else(self):
        self.assertEqual(sorted(crash.descendants(self.table, APP)), [510, 511, 512, 513, 520, 521])

    def test_children_by_type_and_sub_type(self):
        self.assertEqual(crash.chromium_children(self.table, APP, "renderer"), [510, 521])
        self.assertEqual(crash.chromium_children(self.table, APP, "gpu-process"), [511])
        self.assertEqual(crash.chromium_children(self.table, APP, "utility", crash.NETWORK_SERVICE), [512])
        self.assertNotIn(700, crash.chromium_children(self.table, APP, "renderer"))  # another app's renderer

    def test_serving_host_needs_every_renderer_under_one_host_of_the_app(self):
        self.assertEqual(crash.serving_host(self.table, APP, [521]), 520)  # under the host (F2)
        self.assertIsNone(crash.serving_host(self.table, APP, [510]))  # the app's own child: in process
        self.assertIsNone(crash.serving_host(self.table, APP, [510, 521]))  # mixed parents: no proof
        self.assertIsNone(crash.serving_host(self.table, APP, []))  # no renderer: no proof
        self.assertIsNone(crash.serving_host(self.table, APP, [999]))  # not running
        self.assertIsNone(crash.serving_host(self.table, APP, [700]))  # another app's renderer


class OwnershipProof(unittest.TestCase):
    def owner(self, responsible):
        table = crash.parse_ps(PS)
        return crash.Ownership(APP, read_table=lambda: table, responsible=responsible)

    def test_tree_members_are_the_apps(self):
        for pid in (510, 511, 512, 520, 521):
            self.assertTrue(self.owner(lambda pid: None).proof(pid)[0], pid)

    def test_others_are_refused(self):
        ownership = self.owner(lambda pid: APP)
        for pid in (700, 1, APP, 999, 0, None, os.getpid()):
            self.assertFalse(ownership.proof(pid)[0], pid)

    def test_webcontent_needs_the_apps_report_and_responsibility(self):
        self.assertTrue(self.owner(lambda pid: APP).proof(600, reported_by_app=True)[0])
        self.assertFalse(self.owner(lambda pid: APP).proof(600)[0])
        self.assertFalse(self.owner({600: 42, APP: APP}.get).proof(600, reported_by_app=True)[0])
        self.assertFalse(self.owner({600: 42}.get).proof(600, reported_by_app=True)[0])
        self.assertFalse(self.owner(lambda pid: None).proof(600, reported_by_app=True)[0])
        self.assertFalse(self.owner({600: 1, APP: 1}.get).proof(600, reported_by_app=True)[0])  # launchd: no proof
        # Reported by the app, but not a WebContent process: refused.
        self.assertFalse(self.owner(lambda pid: APP).proof(700, reported_by_app=True)[0])

    def test_webcontent_of_an_app_launched_from_a_shell(self):
        # A Popen from a shell: the app inherits the launcher's responsibility, and so does its XPC service.
        self.assertTrue(self.owner({600: 42, APP: 42}.get).proof(600, reported_by_app=True)[0])

    def test_check_mode_fails_on_a_refused_pid_the_app_reported(self):
        strict = crash.Driver(lambda *a, **k: {}, APP, "http://x/", ownership=self.owner({600: 42}.get), strict=True)
        bench = crash.Driver(lambda *a, **k: {}, APP, "http://x/", ownership=self.owner({600: 42}.get))
        with mock.patch.object(crash.os, "kill") as kill:
            self.assertIsNone(strict.kill("webkit WebContent", 600, reported_by_app=True))
            self.assertIsNone(bench.kill("webkit WebContent", 600, reported_by_app=True))
            kill.assert_not_called()
        self.assertEqual(len(strict.failures), 1)
        self.assertEqual(bench.failures, [])

    def test_kill_never_signals_an_unproved_pid(self):
        driver = crash.Driver(lambda *a, **k: {}, APP, "http://x/", ownership=self.owner(lambda pid: None))
        with mock.patch.object(crash.os, "kill") as kill:
            self.assertIsNone(driver.kill("renderer", 700))
            self.assertIsNone(driver.kill("webkit WebContent", 600, reported_by_app=True))
            kill.assert_not_called()
            self.assertIsNotNone(driver.kill("renderer", 510))
            kill.assert_called_once_with(510, crash.signal.SIGKILL)


def result(name, outcome, recover=None, keys=()):
    return crash.CaseResult(name, crash.CASES[name], outcome, "", recover, list(keys))


class Series(unittest.TestCase):
    RUNS = [
        [result("renderer", crash.SURVIVED, 120.0, [3.0, 4.0]), result("gpu", crash.DIED),
         result("network", crash.NOT_MEASURABLE), result("browser_check", crash.EXPECTED_FAIL),
         result("webkit", crash.SURVIVED, 90.0, [5.0])],
        [result("renderer", crash.SURVIVED, 110.0, [2.5]), result("gpu", crash.SURVIVED, 300.0)],
    ]

    def test_survival_counts_an_unmeasured_case_as_not_survived(self):
        self.assertAlmostEqual(crash.survival(self.RUNS[0], "chromium"), 1 / 3)  # renderer of renderer, gpu, network
        self.assertEqual(crash.survival(self.RUNS[1], "chromium"), 1.0)
        self.assertEqual(crash.survival([result("network", crash.NOT_MEASURABLE)], "chromium"), 0.0)
        self.assertIsNone(crash.survival([result("browser_check", crash.EXPECTED_FAIL)], "chromium"))
        self.assertIsNone(crash.survival(self.RUNS[1], "webkit"))

    def test_measured_is_the_share_of_cases_that_ran(self):
        self.assertAlmostEqual(crash.measured(self.RUNS[0], "chromium"), 2 / 3)
        self.assertEqual(crash.measured(self.RUNS[1], "chromium"), 1.0)

    def test_a_partial_run_cannot_claim_the_target(self):
        partial = [result("renderer", crash.SURVIVED, 100.0, [1.0]), result("crash_url", crash.NOT_MEASURABLE)]
        out = {s.metric: s for s in crash.series([partial], ("chromium",))}
        self.assertEqual(out["crash_survival.chromium"].samples, (0.5,))
        self.assertEqual(out["crash_survival.chromium.measured"].samples, (0.5,))

    def test_series_values(self):
        out = {s.metric: s for s in crash.series(self.RUNS, crash.ENGINES)}
        self.assertEqual(out["crash_survival.chromium"].samples, (1 / 3, 1.0))
        self.assertEqual(out["crash_survival.chromium.measured"].samples, (2 / 3, 1.0))
        self.assertEqual(out["crash_survival.chromium"].target_ref, "crash-survival.chromium")
        self.assertEqual(out["crash_survival.chromium.renderer.recover"].samples, (120.0, 110.0))
        self.assertEqual(out["crash_survival.chromium.renderer.key_to_frame"].samples, (3.0, 4.0, 2.5))
        self.assertEqual(out["crash_survival.chromium.gpu.recover"].samples, (300.0,))  # the died run has none
        self.assertEqual(out["crash_survival.webkit"].samples, (1.0,))  # run 2 measured no WebKit case
        self.assertNotIn("crash_survival.chromium.network.recover", out)

    def test_cases_that_crashed_nothing_record_no_key_samples(self):
        runs = [[result("browser_check", crash.EXPECTED_FAIL, keys=[7.0]), result("network", crash.NOT_MEASURABLE, keys=[8.0]),
                 result("gpu", crash.DIED, keys=[9.0])]]
        out = {s.metric: s for s in crash.series(runs, ("chromium",))}
        self.assertNotIn("crash_survival.chromium.browser_check.key_to_frame", out)
        self.assertNotIn("crash_survival.chromium.network.key_to_frame", out)
        self.assertEqual(out["crash_survival.chromium.gpu.key_to_frame"].samples, (9.0,))

    def test_every_series_matches_its_story_and_claims_the_row(self):
        stories = {}
        for engine, story in crash.STORIES.items():
            doc = json.loads((PERF_LAB / "stories.d" / f"{story}.json").read_text())
            self.assertEqual(doc["engine"], engine)
            self.assertEqual(doc["command"][0], "scripts/cmux-next/child-crash-e2e.py")
            stories[story] = doc
        for s in crash.series(self.RUNS, crash.ENGINES):
            self.assertRegex(s.metric, perf_result.NAME_PATTERN)
            self.assertIn(s.unit, perf_result.UNITS)
            doc = stories[s.story]
            matched = [m for m in doc["metrics"] if re.fullmatch(m["name"], s.metric)]
            self.assertEqual(len(matched), 1, s.metric)
            self.assertEqual(matched[0]["unit"], s.unit)
            self.assertEqual(matched[0]["better"], s.better)
            if s.target_ref:
                self.assertEqual(matched[0]["target_ref"], {"target": s.target_ref})

    def test_catalog_lints_the_stories_and_maps_the_target(self):
        loaded = catalog.load_catalog(ROOT)
        mine = [p for p in loaded.problems if "crash-survival" in p]
        self.assertEqual(mine, [])
        mapped = dict((t.id, ok) for t, ok in catalog.mapped_targets(loaded))
        self.assertTrue(mapped["crash-survival"])


class ProbeWindow(unittest.TestCase):
    def test_window_samples_take_complete_drawn_rows_after_start(self):
        rows = [{"complete": "1", "contents_ms": "9"}, {"complete": "1", "contents_ms": "4.5"},
                {"complete": "0", "contents_ms": "7"}, {"complete": "1", "contents_ms": ""},
                {"complete": "1", "contents_ms": "x"}, {"complete": "1", "contents_ms": "6"}]
        self.assertEqual(crash.window_samples(rows, 1), [4.5, 6.0])


class FakeApp:
    """The socket of an app: a dict of method -> reply (or callable(params))."""

    def __init__(self, replies):
        self.replies, self.calls = replies, []

    def __call__(self, method, params=None, timeout=None):
        self.calls.append((method, params))
        reply = self.replies.get(method, {"error": {"code": "method_not_found"}})
        return reply(params or {}) if callable(reply) else reply


class Cases(unittest.TestCase):
    def driver(self, app):
        """A Driver whose app is this test process (PS with APP renamed to its pid); `drv.tables(ps)` swaps the
        process table it reads."""
        state = {}

        def tables(ps):
            state["table"] = crash.parse_ps(ps.replace(str(APP), str(os.getpid())))
        tables(PS)
        ownership = crash.Ownership(os.getpid(), read_table=lambda: state["table"], responsible=lambda pid: None)
        drv = crash.Driver(app, os.getpid(), "http://127.0.0.1:1/", ownership=ownership)
        drv.tables = tables
        return drv

    def test_browser_check_expected_fail_in_process_and_url_cases_need_the_method(self):
        app = FakeApp({})
        drv = self.driver(app)
        with mock.patch.object(crash.os, "kill") as kill, mock.patch.object(crash, "alive", return_value=True):
            results = drv.chromium_cases("tab_1", {"crash_url", "gpucrash_url", "browser_check"})
            kill.assert_not_called()
        outcomes = {r.name: r.outcome for r in results}
        self.assertEqual(outcomes, {"crash_url": crash.NOT_MEASURABLE, "gpucrash_url": crash.NOT_MEASURABLE,
                                    "browser_check": crash.EXPECTED_FAIL})
        self.assertEqual(crash.survival(results, "chromium"), 0.0)
        self.assertEqual([m for m, _ in app.calls].count("debug.omnibar_type"), 2)  # never for browser_check

    def omnibar_calls(self, app):
        return [p["text"] for m, p in app.calls if m == "debug.omnibar_type"]

    def test_browser_check_without_renderers_never_types_the_url(self):
        # The host arm, but no renderer of the tab runs (an earlier case left a sad tab): no proof, no URL.
        app = FakeApp({"debug.omnibar_type": {"typed": True}})
        drv = self.driver(app)
        drv.host_on = True
        drv.tables("\n".join(line for line in PS.splitlines() if "--type=renderer" not in line))
        with mock.patch.object(crash, "alive", return_value=True):
            [res] = drv.chromium_cases("tab_1", {"browser_check"})
        self.assertEqual(res.outcome, crash.EXPECTED_FAIL)
        self.assertEqual(self.omnibar_calls(app), [])

    def test_browser_check_in_process_never_types_the_url_even_with_the_host_on(self):
        app = FakeApp({"debug.omnibar_type": {"typed": True}})
        drv = self.driver(app)
        drv.host_on = True  # renderer 510 is the app's own child, 521 is under the host: mixed, no proof
        with mock.patch.object(crash, "alive", return_value=True):
            [res] = drv.chromium_cases("tab_1", {"browser_check"})
        self.assertEqual(res.outcome, crash.EXPECTED_FAIL)
        self.assertEqual(self.omnibar_calls(app), [])

    def test_browser_check_runs_on_proof_of_a_host(self):
        app = FakeApp({"debug.omnibar_type": {"typed": True}, "debug.browser.page_status": {"gone": "0"},
                       "browser.page.eval": {"value": "alive"}})
        drv = self.driver(app)
        drv.host_on = True
        drv.baseline_renderers = {510}  # the tab's renderer is 521, under the host 520
        with mock.patch.object(crash, "alive", return_value=True):
            [res] = drv.chromium_cases("tab_1", {"browser_check"})
        self.assertEqual(res.outcome, crash.SURVIVED, res.detail)
        self.assertEqual(self.omnibar_calls(app), ["chrome://inducebrowsercrashforrealz"])

    def test_host_case_kills_the_host_that_runs_the_tab(self):
        # The host's end shows the crash page with Reload; Reload brings the tab back.
        page = {"gone": False}

        def page_status(params):
            if params.get("press") == "reload":
                pressed, page["gone"] = page["gone"], False
                return {"pressed": "1" if pressed else "0"}
            return {"gone": "1", "gone_text": "Aw, Snap!\nChromium stopped.\nReload"} if page["gone"] else {"gone": "0"}
        app = FakeApp({"debug.browser.page_status": page_status, "browser.page.eval": {"value": "alive"}})
        drv = self.driver(app)
        drv.host_on = True
        drv.baseline_renderers = {510}

        def kill(pid, sig):
            self.assertEqual((pid, sig), (520, crash.signal.SIGKILL))
            page["gone"] = True
            drv.tables(PS.replace(" 520 ", " 530 ").replace("521   520", "531   530"))  # a new host, a new renderer
        with mock.patch.object(crash.os, "kill", side_effect=kill) as killed, \
                mock.patch.object(crash, "alive", return_value=True):
            [res] = drv.chromium_cases("tab_1", {"host"})
        killed.assert_called_once()
        self.assertEqual(res.outcome, crash.SURVIVED, res.detail)
        self.assertFalse([m for m, _ in app.calls if m == "debug.chromium_host"])

    def test_host_case_without_a_host_is_not_measurable(self):
        drv = self.driver(FakeApp({}))
        drv.host_on = True  # the feature says on, but the tab's renderer 510 is the app's own child
        drv.baseline_renderers = {521}
        with mock.patch.object(crash.os, "kill") as kill, mock.patch.object(crash, "alive", return_value=True):
            [res] = drv.chromium_cases("tab_1", {"host"})
            kill.assert_not_called()
        self.assertEqual(res.outcome, crash.NOT_MEASURABLE)

    def test_host_case_runs_only_with_the_host_on(self):
        drv = self.driver(FakeApp({}))
        with mock.patch.object(crash.os, "kill") as kill:
            self.assertEqual(drv.chromium_cases("tab_1", {"host"}), [])
            kill.assert_not_called()

    def test_network_case_kills_the_service_and_navigates_over_the_new_one(self):
        nav = {}

        def evaluate(params):
            if params["script"] == "location.search":
                return {"value": nav.get("search")}
            return {"value": "alive"}

        def navigate(params):
            nav["search"] = params["url"].split("/", 3)[-1]
            return {}

        app = FakeApp({"browser.page.eval": evaluate, "browser.page.navigate": navigate})
        drv = self.driver(app)

        def kill(pid, sig):
            self.assertEqual((pid, sig), (512, crash.signal.SIGKILL))
            drv.tables(PS.replace(" 512 ", " 514 "))  # Chromium starts a new network service
        with mock.patch.object(crash.os, "kill", side_effect=kill) as killed, \
                mock.patch.object(crash, "alive", return_value=True):
            [res] = drv.chromium_cases("tab_1", {"network"})
        killed.assert_called_once()
        self.assertEqual(res.outcome, crash.SURVIVED, res.detail)
        self.assertIsNotNone(res.recover_ms)
        self.assertEqual(nav["search"], "?n=1")

    def test_survived_becomes_died_when_the_app_ended(self):
        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait()
        drv = crash.Driver(FakeApp({}), dead.pid, "http://x/")
        res = drv.window("gpu", "chromium", lambda: (crash.SURVIVED, "", 12.0))
        self.assertEqual((res.outcome, res.detail), (crash.DIED, "the app ended"))
        self.assertEqual(drv.failures, ["gpu: survived"])

    def typed_driver(self, probe, rows_before):
        header = "complete,contents_ms\n"
        with open(probe, "w") as handle:
            handle.write(header + "".join("1,5\n" for _ in range(rows_before)))
        drv = crash.Driver(FakeApp({"debug.key": {}, "action.run": {}}), os.getpid(), "http://x/", probe=probe,
                           key_interval=0.05)
        drv.layout = {"terminal_pane": "p1", "terminal_tab": "t1", "browser_pane": "p2", "tab": "tab_1"}
        return drv

    def test_keys_before_the_kill_do_not_make_a_frozen_terminal_survive(self):
        with tempfile.TemporaryDirectory() as folder:
            drv = self.typed_driver(os.path.join(folder, "probe.csv"), rows_before=5)

            def run():
                drv.crash_sent()  # the kill; the terminal draws nothing after it
                return crash.SURVIVED, "", 12.0
            with mock.patch.object(crash.time, "sleep"):
                res = drv.window("gpu", "chromium", run)
        self.assertEqual(res.outcome, crash.DIED)
        self.assertIn("after the kill", res.detail)
        self.assertEqual(res.key_to_frame, [])

    def test_key_to_frame_takes_only_the_keys_after_the_kill(self):
        with tempfile.TemporaryDirectory() as folder:
            probe = os.path.join(folder, "probe.csv")
            drv = self.typed_driver(probe, rows_before=5)

            def run():
                drv.crash_sent()
                with open(probe, "a") as handle:
                    handle.write("1,40\n1,8\n")
                return crash.SURVIVED, "", 12.0
            with mock.patch.object(crash.time, "sleep"):
                res = drv.window("gpu", "chromium", run)
        self.assertEqual(res.outcome, crash.SURVIVED, res.detail)
        self.assertEqual(res.key_to_frame, [40.0, 8.0])

    def test_a_case_that_crashed_nothing_keeps_no_keys(self):
        with tempfile.TemporaryDirectory() as folder:
            probe = os.path.join(folder, "probe.csv")
            drv = self.typed_driver(probe, rows_before=5)
            with mock.patch.object(crash.time, "sleep"):
                res = drv.window("network", "chromium", lambda: (crash.NOT_MEASURABLE, "no network service", None))
        self.assertEqual((res.outcome, res.key_to_frame), (crash.NOT_MEASURABLE, []))

    def test_survived_becomes_died_when_the_terminal_drew_nothing(self):
        drv = crash.Driver(FakeApp({"debug.key": {}, "action.run": {}}), os.getpid(), "http://x/",
                           probe=os.devnull, key_interval=0.05)
        drv.layout = {"terminal_pane": "p1", "terminal_tab": "t1", "browser_pane": "p2", "tab": "tab_1"}
        with mock.patch.object(crash.time, "sleep"):
            res = drv.window("gpu", "chromium", lambda: (crash.SURVIVED, "", 12.0))
        self.assertEqual(res.outcome, crash.DIED)
        self.assertIn("no key", res.detail)


class CommandLine(unittest.TestCase):
    def test_exactly_one_mode(self):
        with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
            crash.parse([])
        with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
            crash.parse(["--socket", "/tmp/s", "--app", "/tmp/a.app"])
        self.assertEqual(crash.parse(["--socket", "/tmp/s"]).socket, "/tmp/s")

    def test_engine_selects_its_cases(self):
        engines, only = crash.selected(crash.parse(["--app", "a", "--engine", "webkit"]))
        self.assertEqual((engines, only), (("webkit",), {"webkit", "agent"}))
        self.assertEqual(crash.selected(crash.parse(["--app", "a"]))[1], set(crash.CASES))

    def test_check_mode_keeps_the_capture_slot_cases(self):
        self.assertEqual(crash.selected(crash.parse(["--socket", "/tmp/s"]))[1], {"renderer", "gpu", "webkit", "agent"})
        self.assertEqual(crash.selected(crash.parse(["--socket", "/tmp/s", "--engine", "chromium"]))[1], {"renderer", "gpu"})
        self.assertEqual(crash.selected(crash.parse(["--socket", "/tmp/s", "--only", "network"]))[1], {"network"})
        with self.assertRaises(SystemExit):
            crash.selected(crash.parse(["--app", "a", "--only", "renderer,nope"]))

    def test_missing_method(self):
        self.assertTrue(crash.missing_method({"error": {"code": "method_not_found"}}))
        self.assertFalse(crash.missing_method({"error": "socket closed"}))
        self.assertFalse(crash.missing_method(None))


class HostArms(unittest.TestCase):
    """p12-perf-process-101: each arm turns cefHelperHost on or off through a tunables file a launched app keeps
    (an inherited CMUX_ENABLE_FEATURES is stripped), and reads the arm back from features.list."""

    class FakeApp:
        def __init__(self, answers):
            self.answers = list(answers)
            self.features = self.answers.pop(0)

        def read_features(self):
            return self.answers.pop(0) if self.answers else self.features

    @staticmethod
    def snapshot(state, source="local"):
        return ({"cefHelperHost": {"state": state, "source": source}}, "hash", None) if state else ({}, None, None)

    def test_each_arm_writes_its_own_toggle_and_never_the_stripped_variable(self):
        with tempfile.TemporaryDirectory() as out:
            for arm in ("off", "on"):
                path = os.path.join(out, f"t-{arm}.json")
                env = crash.arm_env(arm, "/tmp/probe.csv", path)
                self.assertEqual(env[crash.TUNABLES_FILE], path)
                self.assertEqual(env["CMUX_NEXT_TYPING_PROBE"], "/tmp/probe.csv")
                self.assertNotIn("CMUX_ENABLE_FEATURES", env)
                self.assertTrue(crash.TUNABLES_FILE.startswith("CMUX_NEXT_"), "LaunchIdentity keeps CMUX_NEXT_ knobs")
                with open(path) as handle:
                    expected = {"browserHost.helper": arm == "on", "browserHost.tabs": arm == "on"}
                    self.assertEqual(json.load(handle), {"version": 1, "values": expected})

    def test_the_on_arm_waits_for_the_toggle_and_records_that_snapshot(self):
        app = self.FakeApp([self.snapshot("off", "default"), self.snapshot("off", "default"), self.snapshot("on")])
        with mock.patch.object(crash.time, "sleep"):
            self.assertEqual(crash.settle_host_state(app, "on", seconds=5), "on")
        self.assertEqual(app.features[0]["cefHelperHost"], {"state": "on", "source": "local"})

    def test_an_on_arm_the_app_never_reports_stays_off(self):
        app = self.FakeApp([self.snapshot("off", "default"), self.snapshot("off", "default")])
        self.assertEqual(crash.settle_host_state(app, "on", seconds=0), "off")

    def test_the_off_arm_reads_once_and_a_build_without_features_runs(self):
        app = self.FakeApp([self.snapshot("off", "local")])
        self.assertEqual(crash.settle_host_state(app, "off"), "off")
        self.assertIsNone(crash.host_state(self.snapshot(None)))
        self.assertIsNone(crash.host_state(None))

    def test_the_story_runs_both_arms(self):
        doc = json.loads((PERF_LAB / "stories.d" / "crash-survival.json").read_text())
        command = doc["command"]
        arms = command[command.index("--host-arms") + 1]
        self.assertEqual(crash.parse(["--app", "a", "--host-arms", arms]).host_arms.split(","), ["off", "on"])
        self.assertIn("env:CMUX_NEXT_DEBUG_TUNABLES_FILE", doc["needs"])


if __name__ == "__main__":
    unittest.main()

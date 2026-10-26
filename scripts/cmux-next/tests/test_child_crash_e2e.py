#!/usr/bin/env python3
"""child-crash-e2e.py, the crash survival story (p12-perf-process-036):

1. Only pids of the app's own process tree are signalled: a Chromium child by its --type (and the network service by
   its --utility-sub-type), also under a host (F2, grandchildren); a WebKit WebContent only when the app reports it
   and the app is its responsible process. Any other pid, the app itself, or one whose owner cannot be read is never
   signalled, and its case is NOT-MEASURABLE.
2. crash_survival.<engine> is survived/total of the measured cases (NOT-MEASURABLE and EXPECTED-FAIL left out), one
   sample per launch; recover and key->frame series per case. Every series name matches a metric of its story file,
   and the survival series claims the target row crash-survival.<engine>.
3. The in-process browser CHECK is EXPECTED-FAIL while a renderer of the tab is the app's own child; a case whose
   debug method the build lacks is NOT-MEASURABLE.
4. A case that "survived" is DIED when the app no longer runs, or when typing was on and the terminal drew no key.
5. The network case kills the network service by exact pid and proves a navigation over the new one.
6. The command line takes exactly one of --socket (check a running app) and --app (launch and measure).

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

    def test_in_process_is_a_renderer_whose_parent_is_the_app(self):
        self.assertTrue(crash.in_process_chromium(self.table, APP, [510]))
        self.assertFalse(crash.in_process_chromium(self.table, APP, [521]))  # under the host (F2)
        self.assertFalse(crash.in_process_chromium(self.table, APP, []))


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
        self.assertFalse(self.owner(lambda pid: 42).proof(600, reported_by_app=True)[0])
        self.assertFalse(self.owner(lambda pid: None).proof(600, reported_by_app=True)[0])
        # Reported by the app, but not a WebContent process: refused.
        self.assertFalse(self.owner(lambda pid: APP).proof(700, reported_by_app=True)[0])

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

    def test_survival_counts_only_measured_cases(self):
        self.assertEqual(crash.survival(self.RUNS[0], "chromium"), 0.5)
        self.assertEqual(crash.survival(self.RUNS[1], "chromium"), 1.0)
        self.assertIsNone(crash.survival([result("network", crash.NOT_MEASURABLE)], "chromium"))
        self.assertIsNone(crash.survival(self.RUNS[1], "webkit"))

    def test_series_values(self):
        out = {s.metric: s for s in crash.series(self.RUNS, crash.ENGINES)}
        self.assertEqual(out["crash_survival.chromium"].samples, (0.5, 1.0))
        self.assertEqual(out["crash_survival.chromium"].target_ref, "crash-survival.chromium")
        self.assertEqual(out["crash_survival.chromium.renderer.recover"].samples, (120.0, 110.0))
        self.assertEqual(out["crash_survival.chromium.renderer.key_to_frame"].samples, (3.0, 4.0, 2.5))
        self.assertEqual(out["crash_survival.chromium.gpu.recover"].samples, (300.0,))  # the died run has none
        self.assertEqual(out["crash_survival.webkit"].samples, (1.0,))  # run 2 measured no WebKit case
        self.assertNotIn("crash_survival.chromium.network.recover", out)

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
        self.assertIsNone(crash.survival(results, "chromium"))

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
        with self.assertRaises(SystemExit):
            crash.selected(crash.parse(["--app", "a", "--only", "renderer,nope"]))

    def test_missing_method(self):
        self.assertTrue(crash.missing_method({"error": {"code": "method_not_found"}}))
        self.assertFalse(crash.missing_method({"error": "socket closed"}))
        self.assertFalse(crash.missing_method(None))


if __name__ == "__main__":
    unittest.main()

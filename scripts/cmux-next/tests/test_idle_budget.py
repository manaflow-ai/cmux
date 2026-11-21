#!/usr/bin/env python3
"""idle-budget.py's pure parts: process kinds, per-kind sums, the budget check and the perf cron rows."""

from __future__ import annotations

import importlib.util
import os
import sys
import tarfile
import tempfile
import unittest
from contextlib import nullcontext
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "perf-bench"))
spec = importlib.util.spec_from_file_location("idle_budget", HERE / "idle-budget.py")
ib = importlib.util.module_from_spec(spec)
# These tests exercise pure bookkeeping and fake socket replies, not libproc.
with patch("ctypes.CDLL") if sys.platform != "darwin" else nullcontext():
    spec.loader.exec_module(ib)

APP = "/Users/x/DerivedData/cmux-t/Build/Products/Debug/cmux DEV t.app"


def row(kind, threads, wakeups, cpu=0.0):
    return {"kind": kind, "threads": threads, "threads_ran": 0, "wakeups_per_s": wakeups, "csw_per_s": 0.0, "cpu_pct": cpu}


def terminal(pane="p"):
    return {"pane": pane, "focused": True, "kind": "terminal", "selected_tab": "tab_terminal",
            "shown_tab": "tab_terminal", "content_installed": True, "content_in_window": True}


class IdleBudgetTests(unittest.TestCase):
    def test_newtabs_create_a_terminal_before_pages_and_return_to_its_stable_key(self):
        class App:
            def __init__(self, ignore_focus=False, visible_copy=False):
                self.terminal = self.created = False
                self.selected = None
                self.actions = []
                self.ignore_focus, self.visible_copy = ignore_focus, visible_copy

            def rpc(self, method, params=None, **kwargs):
                if method == "action.run":
                    self.actions.append(params)
                    if params["action"] == "newSurface":
                        assert not self.created, "creating a terminal must not replace a measured New Tab"
                        self.terminal, self.selected = True, "tab_terminal"
                    elif params["action"] == "newTab.page":
                        self.created, self.selected = True, "tab_new"
                    elif params["action"] == "tab.focus":
                        if not self.ignore_focus:
                            self.selected = params["target"].removeprefix("tab:")
                    # With one tab in the new pane, cycling selects that same tab.
                    return {}
                if method == "debug.agent_pane":
                    return {"document_ready": True, "body_text_length": 100, "engine": "cef"}
                panes = [{"pane": "home", "kind": "page", "focused": self.selected is None,
                          "selected_tab": "tab_home", "shown_tab": "tab_home"}]
                if self.selected:
                    panes.append({"pane": "main", "kind": "terminal" if self.selected == "tab_terminal" else "agent",
                                  "focused": True, "selected_tab": self.selected, "shown_tab": self.selected,
                                  "content_installed": True, "content_in_window": True})
                if self.visible_copy and self.created:
                    panes.append({"pane": "copy", "kind": "agent", "focused": False,
                                  "selected_tab": "tab_new", "shown_tab": "tab_new"})
                return {"windows": [{"panes": panes}],
                        "hibernation": {"chat_pages": ["tab_new"] if self.created else []}}

        app = App()
        with patch.object(ib.time, "monotonic", side_effect=[0, 0, 0, 0, 0, 0, 2]), patch.object(ib.time, "sleep"):
            opened = ib.build_newtabs(app, 1, limit=1)
        self.assertEqual(opened["keys"], ["tab_new"])
        self.assertEqual([p["action"] for p in app.actions], ["newSurface", "newTab.page", "tab.focus"])
        self.assertEqual(app.actions[0]["target"], "tab:tab_home")
        self.assertEqual(app.actions[1]["target"], "pane:main")
        self.assertEqual(app.actions[-1]["target"], "tab:tab_terminal")
        self.assertEqual(ib.newtab_evidence(app, opened)["live_count"], 1)

        for option in ("ignore_focus", "visible_copy"):
            with self.subTest(option=option), patch.object(ib.time, "sleep"), patch.object(
                    ib.time, "monotonic", side_effect=[0, 0, 0, 0, 0, 0, 2]):
                with self.assertRaisesRegex(ib.NewTabSetupError, "terminal did not hide every"):
                    ib.build_newtabs(App(**{option: True}), 1, limit=1)

    def test_newtabs_require_observed_terminal_before_creating_measured_pages(self):
        class App:
            actions = []

            def rpc(self, method, params=None, **kwargs):
                if method == "action.run":
                    self.actions.append(params["action"])
                return {"windows": [{"panes": [{"pane": "home", "kind": "page", "focused": True}]}],
                        "hibernation": {"chat_pages": []}}

        app = App()
        with patch.object(ib.time, "monotonic", side_effect=[0, 0, 2]), patch.object(ib.time, "sleep"):
            with self.assertRaisesRegex(ib.NewTabSetupError, "stable tab"):
                ib.build_newtabs(app, 1, limit=1)
        self.assertEqual(app.actions, [])

    def test_newtab_sessions_build_each_page_before_hiding_without_replacing_it(self):
        class App:
            def __init__(self):
                self.count = 0
                self.hidden = False
                self.calls = []

            def rpc(self, method, params=None, **kwargs):
                self.calls.append((method, params))
                if method == "action.run":
                    if params["action"] == "newTab.page":
                        self.count += 1
                    elif params["action"] == "tab.focus" and params["target"] == "tab:tab_terminal":
                        self.hidden = True
                    else:
                        raise AssertionError(params)
                    return {}
                if method == "debug.agent_pane":
                    return {"document_ready": True, "body_text_length": 100, "engine": "cef"}
                key = "tab_terminal" if self.hidden or self.count == 0 else f"tab_newtab{self.count}"
                return {"windows": [{"panes": [{"pane": "p", "focused": True,
                         "kind": "terminal" if self.hidden or self.count == 0 else "agent", "selected_tab": key,
                         "shown_tab": key, "content_installed": True, "content_in_window": True}]}],
                        "hibernation": {"chat_pages": [f"tab_newtab{i}" for i in range(1, self.count + 1)]}}

        for count in (1, 5, 20):
            app = App()
            opened = ib.build_newtabs(app, count)
            self.assertEqual(opened["rendered"], count)
            self.assertEqual(len(set(opened["keys"])), count)
            self.assertEqual(opened["engines"], ["cef"] * count)
            self.assertEqual(sum(method == "debug.agent_pane" and params["action"] == "readiness"
                                 for method, params in app.calls), count)
            self.assertEqual([params["action"] for method, params in app.calls if method == "action.run"],
                             ["newTab.page"] * count + ["tab.focus"])
            self.assertEqual(ib.newtab_evidence(app, opened)["live_count"], count)

    def test_newtab_measurement_rejects_missing_or_lazy_pages(self):
        class App:
            def rpc(self, *args, **kwargs):
                return {}
        with self.assertRaisesRegex(RuntimeError, "lacks hibernation.chat_pages"):
            ib.build_newtabs(App(), 5, limit=0)
        with self.assertRaisesRegex(RuntimeError, "lacks hibernation.chat_pages"):
            ib.newtab_evidence(App(), {"keys": ["a"]})

    def test_newtab_setup_preserves_full_panes_and_readiness_error(self):
        pane = {"pane": "p", "focused": True, "kind": "agent", "selected_tab": "tab_real",
                "shown_tab": "tab_real", "content_installed": True, "content_in_window": True}
        readiness = {"error": "page script failed", "document_ready": True, "body_text_length": 100}

        class App:
            created = False

            def rpc(self, method, params=None, **kwargs):
                if method == "action.run":
                    self.created = True
                    return {}
                if method == "debug.agent_pane":
                    return readiness
                return {"windows": [{"panes": [pane] if self.created else [terminal()]}],
                        "hibernation": {"chat_pages": ["tab_real"] if self.created else []}}

        with patch.object(ib.time, "monotonic", side_effect=[0, 0, 0, 0, 2]), patch.object(ib.time, "sleep"):
            with self.assertRaises(ib.NewTabSetupError) as failure:
                ib.build_newtabs(App(), 1, limit=1)
        self.assertEqual(failure.exception.diagnostics["panes"], [pane])
        self.assertEqual(failure.exception.diagnostics["readiness"], readiness)

    def test_newtab_setup_never_counts_a_provisional_tab_id(self):
        class App:
            created = False

            def rpc(self, method, params=None, **kwargs):
                if method == "action.run":
                    self.created = True
                    return {}
                if method == "debug.agent_pane":
                    raise AssertionError("a provisional tab is not a stable page to measure")
                if not self.created:
                    return {"windows": [{"panes": [terminal()]}], "hibernation": {"chat_pages": []}}
                return {"windows": [{"panes": [{"pane": "p", "focused": True, "kind": "agent",
                        "selected_tab": "pending_tab_1", "shown_tab": "pending_tab_1",
                        "content_installed": True, "content_in_window": True}]}],
                        "hibernation": {"chat_pages": ["pending_tab_1"]}}

        with patch.object(ib.time, "monotonic", side_effect=[0, 0, 0, 0, 2]), patch.object(ib.time, "sleep"):
            with self.assertRaisesRegex(ib.NewTabSetupError, "only built 0 of 1"):
                ib.build_newtabs(App(), 1, limit=1)

    def test_newtab_setup_focuses_the_new_stable_agent_before_readiness(self):
        class App:
            def __init__(self):
                self.created = self.focused = self.hidden = False
                self.calls = []

            def rpc(self, method, params=None, **kwargs):
                self.calls.append((method, params))
                if method == "action.run":
                    if params["action"] == "newTab.page":
                        self.created = True
                    elif params["action"] == "tab.focus":
                        if params["target"] == "tab:tab_new":
                            self.assert_target = params["target"]
                            self.focused = True
                        else:
                            self.hidden = params["target"] == "tab:tab_terminal"
                    return {}
                if method == "debug.agent_pane":
                    assert self.focused and params["pane"] == "agent", "readiness needs the target pane's focus"
                    return {"document_ready": True, "body_text_length": 100, "engine": "cef"}
                panes = [{"pane": "other", "kind": "page", "focused": self.created and not self.focused},
                         {"pane": "existing", "kind": "agent", "focused": False,
                          "selected_tab": "tab_existing", "shown_tab": "tab_existing",
                          "content_installed": True, "content_in_window": True}]
                if self.created:
                    key = "tab_terminal" if self.hidden else "tab_new"
                    panes.append({"pane": "agent", "kind": "terminal" if self.hidden else "agent",
                                  "focused": self.focused, "selected_tab": key, "shown_tab": key,
                                  "content_installed": True, "content_in_window": True})
                else:
                    panes.append(terminal("agent"))
                return {"windows": [{"panes": panes}],
                        "hibernation": {"chat_pages": ["tab_existing"] + (["tab_new"] if self.created else [])}}

        app = App()
        with patch.object(ib.time, "monotonic", side_effect=[0, 0, 0, 0, 0, 2, 2]), patch.object(ib.time, "sleep"):
            opened = ib.build_newtabs(app, 1, limit=1)
        self.assertEqual(opened["keys"], ["tab_new"])
        self.assertEqual(app.assert_target, "tab:tab_new")
        focus = next(i for i, (method, params) in enumerate(app.calls)
                     if method == "action.run" and params["action"] == "tab.focus")
        ready = next(i for i, (method, params) in enumerate(app.calls)
                     if method == "debug.agent_pane" and params["action"] == "readiness")
        self.assertLess(focus, ready)

    def test_newtab_setup_requires_observed_focus_even_when_focus_action_succeeds(self):
        class App:
            created = False

            def rpc(self, method, params=None, **kwargs):
                if method == "action.run":
                    if params["action"] == "newTab.page":
                        self.created = True
                    return {}
                if method == "debug.agent_pane":
                    raise AssertionError("an unfocused pane cannot pass readiness")
                panes = [{"pane": "agent", "kind": "agent", "focused": False,
                          "selected_tab": "tab_new", "shown_tab": "tab_new",
                          "content_installed": True, "content_in_window": True}] if self.created else [terminal("agent")]
                return {"windows": [{"panes": panes}],
                        "hibernation": {"chat_pages": ["tab_new"] if self.created else []}}

        with patch.object(ib.time, "monotonic", side_effect=[0, 0, 0, 0, 2]), patch.object(ib.time, "sleep"):
            with self.assertRaisesRegex(ib.NewTabSetupError, "only built 0 of 1"):
                ib.build_newtabs(App(), 1, limit=1)

    def test_newtab_evidence_intersects_measured_keys_and_rejects_visible_page(self):
        class App:
            def rpc(self, *args, **kwargs):
                return {"windows": [{"panes": [{"shown_tab": "terminal"}]}],
                        "hibernation": {"chat_pages": ["b", "unrelated"]}}
        evidence = ib.newtab_evidence(App(), {"keys": ["a", "b"], "rendered": 2})
        self.assertEqual(evidence["live_count"], 1)
        self.assertEqual(evidence["live_keys"], ["b"])
        with patch.object(App, "rpc", return_value={"windows": [{"panes": [{"shown_tab": "a"}]}]}):
            with self.assertRaisesRegex(RuntimeError, "visible during"):
                ib.newtab_evidence(App(), {"keys": ["a"]})

    def test_memory_summary_counts_renderers_and_sums_all_footprints(self):
        result = {"processes": [{"pid": 1, "kind": "app", "footprint_mb": 10.1},
                                {"pid": 2, "kind": "cef-renderer", "footprint_mb": 20.2},
                                {"pid": 3, "kind": "webkit-webcontent", "footprint_mb": 30.3},
                                {"pid": 4, "kind": "cef-gpu", "footprint_mb": 40.4}]}
        self.assertEqual(ib.memory_summary(result), {"total_footprint_mb": 101.0, "renderer_count": 2,
                                                   "renderer_pids": [2, 3], "renderer_footprint_mb": 50.5})

    def test_kinds(self):
        self.assertEqual(ib.kind(f"{APP}/Contents/MacOS/cmux DEV"), "app")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux-tui server --socket s"), "daemon")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux-tui __holder --socket s"), "holder")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux-tui __terminal-host --owner a@1"), "terminal-host")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/acpmux daemon"), "acpmux")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper (Renderer).app/x --type=renderer"), "cef-renderer")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper (GPU).app/x --type=gpu-process"), "cef-gpu")
        self.assertEqual(ib.kind("/bin/zsh -l"), "other:zsh")

    def test_aggregate_sums_and_maxes_per_kind(self):
        kinds = ib.aggregate({"processes": [row("terminal-host", 3, 0.0), row("terminal-host", 5, 0.5), row("app", 40, 2.0)],
                              "main_wakes_per_s": 1.5})
        self.assertEqual(kinds["terminal-host"]["n"], 2)
        self.assertEqual(kinds["terminal-host"]["threads"], 8)
        self.assertEqual(kinds["terminal-host"]["threads_max"], 5)
        self.assertEqual(kinds["terminal-host"]["wakeups_max"], 0.5)
        self.assertEqual(kinds["app"]["main_wakes_per_s"], 1.5)

    def test_over_budget_names_each_value_over_its_limit(self):
        budget = {"kinds": {"app": {"main_wakes_per_s": 0, "wakeups_per_s": 1.0, "threads_max": None},
                            "holder": {"wakeups_max": {"light": 0, "stress": 1}}}}
        kinds = {"app": {"main_wakes_per_s": 0.2, "wakeups_per_s": 0.9, "threads_max": 99},
                 "holder": {"wakeups_max": 0.5}}
        self.assertEqual(ib.over_budget("light", kinds, budget), [("app", "main_wakes_per_s", 0.2, 0), ("holder", "wakeups_max", 0.5, 0)])
        self.assertEqual(ib.over_budget("stress", kinds, budget), [("app", "main_wakes_per_s", 0.2, 0)])

    def test_cron_rows(self):
        report = {"sessions": {"light": {"kinds": {"app": {"wakeups_per_s": 0.4, "threads_max": 30, "main_wakes_per_s": 0}}}}}
        rows = ib.cron_rows(report, {"kinds": {"app": {"wakeups_per_s": 1.0}}})
        self.assertEqual(rows["idle_budget.light.app.wakeups_per_s"],
                         {"p50": 0.4, "p95": 0.4, "unit": "/s", "budget": 1.0, "floor": 0.5})
        self.assertEqual(rows["idle_budget.light.app.threads_max"]["unit"], "threads")
        self.assertIsNone(rows["idle_budget.light.app.threads_max"]["budget"])

    def test_display_link_clients_names_what_the_link_calls(self):
        # A /usr/bin/sample report: the CVDisplayLink thread's own frames are CoreVideo's; its owner is the
        # client its callback reaches (here a Chromium frame), which the bench must name.
        report = """Call graph:
    2417 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
    + 2417 CmuxNextApp.main()  (in cmux DEV.debug.dylib) + 8  [0x1]
    4490 Thread_2: CVDisplayLink
    + 4490 thread_start  (in libsystem_pthread.dylib) + 8  [0x2]
    +   4490 CVDisplayLink::runIOThread()  (in CoreVideo) + 600  [0x3]
    +     4400 CVDisplayLink::waitUntil(unsigned long long)  (in CoreVideo) + 20  [0x4]
    +     90 CVDisplayLink::performIO(CVTimeStamp*)  (in CoreVideo) + 230  [0x5]
    +       90 ui::DisplayLinkMac::DisplayLinkCallback(__CVDisplayLink*)  (in Chromium Embedded Framework) + 40  [0x6]
    +         12 base::TaskRunner::PostTask  (in Chromium Embedded Framework) + 4  [0x7]
Total number in stack
"""
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "sample-app.txt")
            with open(path, "w") as handle:
                handle.write(report)
            clients = ib.display_link_clients(path)
        self.assertEqual(clients[0], ("ui::DisplayLinkMac::DisplayLinkCallback(__CVDisplayLink*) (Chromium Embedded Framework)", 90))
        self.assertNotIn("CmuxNextApp.main() (cmux DEV.debug.dylib)", dict(clients), "a frame of another thread")
        self.assertTrue(all("CoreVideo" not in frame for frame, _ in clients))

    def test_bundle_is_one_regular_file_cmux_ci_can_upload(self):
        with tempfile.TemporaryDirectory() as out:
            os.makedirs(os.path.join(out, "stress"))
            with open(os.path.join(out, "stress", "sample-app.txt"), "w") as handle:
                handle.write("sample")
            with open(os.path.join(out, "idle-budget.json"), "w") as handle:
                handle.write("{}")
            with open(os.path.join(out, "idle-budget.md"), "w") as handle:
                handle.write("# table")
            # What split-spring keeps beside the run (the tagged app, the virtual display) stays out.
            os.makedirs(os.path.join(out, "app", "cmux DEV split-spring.app"))
            os.makedirs(os.path.join(out, "vdisplay"))
            path = ib.bundle(out, ["stress"], os.path.join(out, "idle-budget.json"))
            self.assertEqual(path, os.path.join(out, "idle-budget.tgz"))
            self.assertTrue(os.path.isfile(path))
            with tarfile.open(path) as archive:
                self.assertEqual(sorted(archive.getnames()),
                                 ["idle-budget.json", "idle-budget.md", "stress", "stress/sample-app.txt"])

    def test_checked_in_budget_parses(self):
        budget = ib.json.load(open(ib.BUDGET_FILE))
        self.assertEqual(budget["kinds"]["app"]["main_wakes_per_s"], 0)


if __name__ == "__main__":
    unittest.main()

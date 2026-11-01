#!/usr/bin/env python3
"""chat-open-bench.py's summary: a case with an open that showed no content, or with no empty time,
is reported as failed with its valid count, never as a median over the opens that survived."""

from __future__ import annotations

import importlib.util
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import chat_open_summary as cos  # noqa: E402


def load_bench(*args):
    """chat-open-bench.py with its macOS-only helpers stubbed (bench_memory loads libproc), so its
    open and diagnostics run on any host."""
    def merged(base, extra):
        out = dict(base)
        for key, value in extra.items():
            out[key] = merged(out[key], value) if isinstance(value, dict) and isinstance(out.get(key), dict) else value
        return out

    stubs = {"bench_memory": types.SimpleNamespace(merged=merged),
             "idle_cost_load": types.SimpleNamespace(), "bench_power": types.SimpleNamespace(wipe_state=None)}
    spec = importlib.util.spec_from_file_location("chat_open_bench", HERE / "chat-open-bench.py")
    module = importlib.util.module_from_spec(spec)
    with mock.patch.dict(sys.modules, stubs), mock.patch.object(sys, "argv", ["chat-open-bench.py", "--app", "/x.app", *args]):
        spec.loader.exec_module(module)
    return module


class FakeApp:
    def __init__(self, replies):
        self.replies = replies
        self.calls = []

    def action(self, action, *, focus=False, **args):
        self.calls.append((action, focus, args))
        return self.replies.get(action, {})


def open_(first, empty=0.0, **extra):
    return {"first_content_ms": first, "longest_empty_ms": empty, "flashes": 0, **extra}



class SubagentClickTests(unittest.TestCase):
    class Run:
        """`debug.agent_pane click` as the app answers it (DebugAgentPaneClick.click): `text` names
        the element; one the page does not show answers "no visible element matches"."""
        def __init__(self, shown):
            self.shown, self.clicked = shown, []

        def rpc(self, method, params=None, timeout=40):
            assert method == "debug.agent_pane" and params["action"] == "click" and params.get("text")
            self.clicked.append(params["text"])
            if params["text"] not in self.shown:
                return {"pane": "p", "error": "no visible element matches"}
            return {"pane": "p", "clicked": True, "x": 1.0, "y": 2.0}

    def test_clicks_the_newest_subagent_the_chat_shows(self):
        bench = load_bench("--runs=3")
        # The chat holds Auditor 0..3; this build renders only 0 and 2.
        run = self.Run({"Auditor 0", "Auditor 2"})
        reply = bench.click_subagent(run)
        self.assertEqual(run.clicked, ["Auditor 3", "Auditor 2"])
        self.assertEqual(reply["subagent"], "Auditor 2")
        self.assertIs(reply["clicked"], True, "the app's own clicked flag is kept")
        self.assertNotIn("error", reply)

    def test_an_older_rendered_line_still_opens(self):
        bench = load_bench("--runs=3")
        run = self.Run({"Auditor 0"})
        self.assertEqual(bench.click_subagent(run)["subagent"], "Auditor 0")

    def test_no_shown_line_keeps_the_error(self):
        bench = load_bench("--runs=3")
        self.assertEqual(bench.click_subagent(self.Run(set()))["error"], "no visible element matches")


class SummaryTests(unittest.TestCase):
    def test_complete_case_reports_medians(self):
        summary = cos.summarize([open_(100, 10), open_(300, 30), open_(200, 20)])
        self.assertTrue(summary["complete"])
        self.assertEqual((summary["n"], summary["ok"]), (3, 3))
        self.assertEqual(summary["first_content_ms"]["median"], 200)
        self.assertEqual(summary["longest_empty_ms"], 20)
        self.assertEqual(cos.cell(summary, "sidebar"), "200, empty 20, 0 flashes")

    def test_timed_out_open_fails_the_case(self):
        # The slow open timed out: a median of the other two (150) would look faster than the truth.
        summary = cos.summarize([open_(100), open_(200), {"timed_out": True, "longest_empty_ms": 15000}])
        self.assertFalse(summary["complete"])
        self.assertEqual((summary["n"], summary["ok"]), (3, 2))
        self.assertIsNone(summary["first_content_ms"]["median"])
        self.assertEqual(cos.cell(summary, "sidebar"), "FAILED (2/3 valid)")

    def test_timed_out_open_with_numbers_still_fails_the_case(self):
        # The trace gave up but still reported the times it had: they are not the open's.
        slow = open_(15000, 15000, timed_out=True)
        summary = cos.summarize([open_(100), open_(200), slow])
        self.assertFalse(summary["complete"])
        self.assertEqual((summary["n"], summary["ok"], summary["timed_out"]), (3, 2, 1))
        self.assertEqual(cos.cell(summary, "big"), "FAILED (2/3 valid)")
        errored = cos.summarize([open_(100), open_(120, error="wait: closed")])
        self.assertEqual(cos.cell(errored, "subagent"), "FAILED (1/2 valid)")

    def test_missing_empty_time_is_missing_not_zero(self):
        summary = cos.summarize([open_(100, 50), {"first_content_ms": 120, "flashes": 0}])
        self.assertFalse(summary["complete"])
        self.assertIsNone(summary["longest_empty_ms"])
        self.assertEqual(cos.cell(summary, "restore"), "FAILED (1/2 valid)")

    def test_error_and_empty_cases_fail(self):
        self.assertFalse(cos.summarize([{"error": "arm: None"}])["complete"])
        self.assertFalse(cos.summarize([])["complete"])


class OpenTests(unittest.TestCase):
    """The bench's open shows the chat it opens (agent.openSessionWorkspace alone never switches to
    its workspace, so no agent pane was made and every open timed out with no frames)."""

    def setUp(self):
        self.bench = load_bench()

    def test_open_shows_the_workspace_it_created(self):
        # By its ref: selectLast read the sidebar's order, which can lag the open on a loaded host,
        # and showed the previous workspace (a loaded fleet Mac: every open after the first).
        app = FakeApp({"agent.openSessionWorkspace": {"created": ["ws_1"]}})
        reply = self.bench.open_workspace(types.SimpleNamespace(app=app), "s1")
        self.assertEqual([(c[0], c[1], c[2]) for c in app.calls],
                         [("agent.openSessionWorkspace", True, {"session": "s1"}),
                          ("goToWorkspace", True, {"workspace": "ws_1"})])
        self.assertEqual(reply["created"], ["ws_1"])
        self.assertEqual(reply["shown"], {"via": "goToWorkspace", "reply": {}})

    def test_open_with_no_created_ref_falls_back_to_the_last_workspace(self):
        app = FakeApp({"agent.openSessionWorkspace": {}, "workspace.selectLast": {}})
        reply = self.bench.open_workspace(types.SimpleNamespace(app=app), "s1")
        self.assertEqual([c[0] for c in app.calls], ["agent.openSessionWorkspace", "workspace.selectLast"])
        self.assertEqual(reply["shown"]["via"], "workspace.selectLast")

    def test_a_refused_switch_falls_back_and_says_so(self):
        app = FakeApp({"agent.openSessionWorkspace": {"created": ["ws_1"]},
                       "goToWorkspace": {"error": "No workspace ws_1."}})
        reply = self.bench.open_workspace(types.SimpleNamespace(app=app), "s1")
        self.assertEqual([c[0] for c in app.calls], ["agent.openSessionWorkspace", "goToWorkspace", "workspace.selectLast"])
        self.assertEqual(reply["shown"]["refused"], {"error": "No workspace ws_1."})

    def test_a_refused_open_shows_nothing(self):
        app = FakeApp({"agent.openSessionWorkspace": {"error": "daemon offline"}})
        reply = self.bench.open_workspace(types.SimpleNamespace(app=app), "s1")
        self.assertEqual([c[0] for c in app.calls], ["agent.openSessionWorkspace"])
        self.assertEqual(reply, {"error": "daemon offline"})

    def test_new_workspaces_go_last(self):
        # selectLast shows the open's workspace only when new ones go to the bottom (default: top).
        self.assertEqual(self.bench.CONFIG["workspaces"]["newPlacement"], "bottom")
        # A --config placement would make selectLast show another workspace: bottom wins, the rest applies.
        bench = load_bench("--config", '{"workspaces": {"newPlacement": "top", "autoName": false}}')
        self.assertEqual(bench.CONFIG["workspaces"], {"newPlacement": "bottom", "autoName": False})

    def test_why_names_the_marks_that_ran(self):
        # marks_ms names every mark (null when it did not run): only `order` says which ran.
        line = self.bench.why({"timed_out": True, "frames": [], "frame_count": 0, "order": ["action"],
                               "marks_ms": {"action": 0.0, "pane_made": None, "page_painted": None}})
        self.assertIn("marks=['action']", line)
        self.assertNotIn("pane_made", line)

    def test_why_shows_how_the_workspace_was_shown_past_a_long_reply(self):
        reply = {"action": "agent.openSessionWorkspace", "args": {"session": "s" * 300}, "created": ["ws_1"],
                 "shown": {"via": "workspace.selectLast", "reply": {}, "refused": {"error": "No workspace ws_1."}}}
        record = {"timed_out": True, "frames": [], "order": ["action"], "open_reply": reply}
        line = self.bench.why(record)
        self.assertIn('shown={"via": "workspace.selectLast"', line)
        self.assertIn("shown", record["open_reply"])  # the record keeps it for the JSON artifact


class TableTests(unittest.TestCase):
    def test_a_measured_table_says_failed_nowhere_but_its_legend(self):
        # The header's FAILED read as a verdict on a run where every case measured.
        bench = load_bench("--conditions", "idle", "--cases", "sidebar")
        ok = cos.summarize([open_(100, 10)])
        table = bench.markdown({"host": "h", "model": "m", "ncpu": 1, "cases": {"idle": {"sidebar": ok}}})
        self.assertNotIn("FAILED:", table)
        self.assertEqual(sum("FAILED" in line for line in table.splitlines()), 1)  # the legend's one mention


if __name__ == "__main__":
    unittest.main()

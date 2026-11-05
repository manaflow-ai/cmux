#!/usr/bin/env python3
"""chat-open-bench.py's summary: a case with an open that showed no content, or with no empty time,
is reported as failed with its valid count, never as a median over the opens that survived."""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
import uuid
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
        """`debug.agent_pane click` as the app answers it (DebugAgentPaneClick.click): `text` or `selector` names
        the element; one the page does not show answers "no visible element matches". `hover` answers the same way
        and `chat_state` with an empty state."""
        def __init__(self, shown):
            self.shown, self.clicked, self.probed = shown, [], []

        def rpc(self, method, params=None, timeout=40):
            assert method == "debug.agent_pane"
            if params["action"] == "chat_state":
                return {"pane": "p"}
            target = params.get("text") or params.get("selector")
            assert target and params["action"] in ("click", "hover")
            (self.clicked if params["action"] == "click" else self.probed).append(target)
            if target not in self.shown:
                return {"pane": "p", "error": "no visible element matches"}
            return {"pane": "p", "clicked": True, "x": 1.0, "y": 2.0}

    def test_clicks_the_newest_subagent_the_chat_shows(self):
        bench = load_bench("--runs=3")
        # The chat holds Auditor 0..3; this build renders only 0 and 2.
        run = self.Run({"Auditor 0", "Auditor 2"})
        reply = bench.click_subagent(run)
        self.assertEqual(run.clicked, ["Auditor 3", bench.subagent_task(3), "Auditor 2"])
        self.assertEqual(reply["subagent"], "Auditor 2")
        self.assertIs(reply["clicked"], True, "the app's own clicked flag is kept")
        self.assertNotIn("error", reply)

    def test_an_older_rendered_line_still_opens(self):
        bench = load_bench("--runs=3")
        run = self.Run({"Auditor 0"})
        self.assertEqual(bench.click_subagent(run)["subagent"], "Auditor 0")

    def test_a_line_named_by_its_task_is_clicked_by_its_task(self):
        # Since 2026-11-04 the tray and a finished line read the task first: no element is the name alone.
        bench = load_bench("--runs=3")
        run = self.Run({bench.subagent_task(1)})
        reply = bench.click_subagent(run)
        self.assertEqual(reply["subagent"], bench.subagent_task(1))
        self.assertIs(reply["clicked"], True)

    def test_a_line_matched_by_no_text_is_clicked_by_its_selector(self):
        bench = load_bench("--runs=3")
        run = self.Run({bench.SUBAGENT_LINES[1]})
        reply = bench.click_subagent(run)
        self.assertEqual(run.clicked[-2:], list(bench.SUBAGENT_LINES))
        self.assertEqual(reply["subagent"], bench.SUBAGENT_LINES[1])

    def test_no_shown_line_keeps_the_error_and_says_what_the_page_shows(self):
        bench = load_bench("--runs=3")
        run = self.Run({".cv-tool"})
        reply = bench.click_subagent(run)
        self.assertEqual(reply["error"], "no visible element matches")
        self.assertEqual(run.probed, list(bench.PROBE_SELECTORS))
        self.assertEqual(reply["probe"][".cv-tool"], "shown")
        self.assertEqual(reply["probe"]["button.cv-subagent-done"], "no visible element matches")
        self.assertIn("chat_state", reply["probe"])


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
        self.assertEqual(cos.cell(summary, "sidebar"), "FAILED (2/3 valid; timed_out 1)")

    def test_timed_out_open_with_numbers_still_fails_the_case(self):
        # The trace gave up but still reported the times it had: they are not the open's.
        slow = open_(15000, 15000, timed_out=True)
        summary = cos.summarize([open_(100), open_(200), slow])
        self.assertFalse(summary["complete"])
        self.assertEqual((summary["n"], summary["ok"], summary["timed_out"]), (3, 2, 1))
        self.assertEqual(cos.cell(summary, "big"), "FAILED (2/3 valid; timed_out 1)")
        errored = cos.summarize([open_(100), open_(120, error="wait: closed")])
        self.assertEqual(cos.cell(errored, "subagent"), "FAILED (1/2 valid; error 1)")

    def test_missing_empty_time_is_missing_not_zero(self):
        summary = cos.summarize([open_(100, 50), {"first_content_ms": 120, "flashes": 0}])
        self.assertFalse(summary["complete"])
        self.assertIsNone(summary["longest_empty_ms"])
        self.assertEqual(cos.cell(summary, "restore"), "FAILED (1/2 valid; no_empty_time 1)")

    def test_an_open_with_no_content_that_did_not_time_out_is_invalid_as_no_content(self):
        # #32448's step 3bbdee10: the loading watchdog ended the wait (pane_painted/loading_left with no
        # web paint, after the trace's frame cap), so the trace said timed_out false with no first content.
        blank = {"timed_out": False, "first_content_ms": None, "longest_empty_ms": 4800.0, "frame_count": 400,
                 "marks_ms": {"spare_adopted": 40.0, "pane_painted": 900.0}}
        self.assertEqual(cos.invalid_reason(blank), "no_content")
        self.assertEqual(cos.invalid_reason({**blank, "timed_out": True}), "timed_out")
        self.assertEqual(cos.invalid_reason(open_(100, frame_count=0)), "no_frames")
        self.assertIsNone(cos.invalid_reason(open_(100, frame_count=12)))
        summary = cos.summarize([open_(100), blank, blank])
        self.assertFalse(summary["complete"])
        self.assertEqual((summary["ok"], summary["timed_out"], summary["no_first_content"]), (1, 0, 2))
        self.assertEqual(summary["invalid"], {"no_content": 2})
        self.assertEqual(cos.cell(summary, "sidebar"), "FAILED (1/3 valid; no_content 2)")

    def test_marks_medians_cover_every_open_that_ran_the_mark_even_when_incomplete(self):
        # An incomplete case once reported marks_median_ms {}, which hid spare_adopted on 21 of 24 opens.
        blank = {"timed_out": False, "first_content_ms": None, "longest_empty_ms": 4800.0,
                 "marks_ms": {"spare_adopted": 30.0, "web_paint": None}}
        summary = cos.summarize([open_(100, marks_ms={"spare_adopted": 10.0, "web_paint": 90.0}),
                                 open_(200, marks_ms={"spare_adopted": 20.0, "web_paint": 190.0}),
                                 blank, {"error": "arm: None", "marks_ms": {"spare_adopted": 999.0}}])
        self.assertFalse(summary["complete"])
        self.assertEqual(summary["marks_median_ms"], {"spare_adopted": 20.0, "web_paint": 140.0})
        self.assertEqual(summary["marks_n"], {"spare_adopted": 3, "web_paint": 2})

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



class ClickRowTests(unittest.TestCase):
    """The click cases read workspace ids from debug.sidebar_rows, whose keys are SidebarRowKey descriptions."""

    def test_workspace_id_reads_the_row_key(self):
        bench = load_bench()
        self.assertEqual(bench.workspace_id({"key": "workspace(ws_1a2b)"}), "ws_1a2b")
        self.assertEqual(bench.workspace_id({"key": "workspace(mac:ws_1a2b)"}), "mac:ws_1a2b")
        self.assertIsNone(bench.workspace_id({"key": "group(grp_1)"}))
        self.assertIsNone(bench.workspace_id({"key": "item(home)"}))
        self.assertIsNone(bench.workspace_id(None))

    def test_shown_workspace_makes_one_when_home_is_shown(self):
        bench = load_bench()
        calls = []
        replies = [{"windows": [{"rows": [{"key": "item(home)", "selected": True}]}]},
                   {"windows": [{"rows": [{"key": "item(home)", "selected": False},
                                          {"key": "workspace(ws_new)", "selected": True}]}]}]

        class Run:
            app = types.SimpleNamespace(action=lambda name, **kw: calls.append(name) or {})

            def rpc(self, method, params=None, timeout=40):
                return replies.pop(0) if len(replies) > 1 else replies[0]

        self.assertEqual(bench.shown_workspace(Run()), "ws_new")
        self.assertEqual(calls, ["workspace.newAtBottom"])


class SeedCacheTests(unittest.TestCase):
    """seed() writes each template once on the seeding daemon and caches it; a second run (another
    arm) reads it back and starts no daemon, and still copies fresh ids into a fresh store."""

    class Peer:
        started = 0
        sends = 0

        def __init__(self, app, root, agent):
            self.home = os.path.join(root, "peer")
            self.chats = {}

        def start(self):
            type(self).started += 1

        def stop(self):
            pass

        def _chat(self, texts):
            sid = str(uuid.uuid4())
            self.chats[sid] = {"id": sid, "meta": json.dumps({"id": sid}).encode(),
                               "events": {"000000.ndjson": "".join(f'{{"sid": "{sid}", "t": "{t}"}}\n' for t in texts).encode()}}
            return sid

        def new_chat(self, text):
            return self._chat([text])

        def acpmux(self, *args, timeout=None):
            type(self).sends += 1
            chat = self.chats[args[1]]
            chat["events"]["000000.ndjson"] += f'{{"sid": "{args[1]}", "t": "{args[2]}"}}\n'.encode()
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")

        def templates(self):
            return self.chats[self._chat(["answered"])], self.chats[self._chat(["closed"])]

    def fake_icl(self):
        def private_write(path, data):
            with open(path, "wb") as handle:
                handle.write(data)

        return types.SimpleNamespace(
            PeerDaemon=self.Peer, bundled_acpmux=lambda app: __file__,
            read_chat=lambda home, sid: dict(self.peer_chats()[sid]),
            seed_store=lambda home, count, share, answered, closed: {"sessions": count},
            private_dir=lambda path: os.makedirs(path, exist_ok=True), private_write=private_write)

    def peer_chats(self):
        return self.last_peer.chats

    def run_seed(self, *flags):
        bench = load_bench("--conditions", "idle", "--cases", "big", "--runs", "1", "--turns", "5", "--small-turns", "3", *flags)
        bench.icl = self.fake_icl()
        real = self.Peer.__init__
        test = self

        def init(peer, *args):
            real(peer, *args)
            test.last_peer = peer

        root = tempfile.mkdtemp(dir=self.tmp.name)
        with mock.patch.object(self.Peer, "__init__", init), \
                mock.patch.dict(os.environ, {"CMUX_BENCH_SEED_CACHE": os.path.join(self.tmp.name, "cache")}):
            home, per, seeded = bench.seed(root)
        return home, per, seeded

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.Peer.started = self.Peer.sends = 0

    def tearDown(self):
        self.tmp.cleanup()

    def big_events(self, home, per):
        with open(os.path.join(home, "sessions", per["idle"]["big"][0], "events", "000000.ndjson"), "rb") as handle:
            return handle.read()

    def test_the_second_run_reads_the_cache_and_starts_no_daemon(self):
        home, per, first = self.run_seed()
        self.assertEqual(first["seed_cache"], {"small": "miss", "subagent": "miss", "big": "miss", "store": "miss"})
        self.assertEqual(self.Peer.started, 1)
        sends = self.Peer.sends
        cold = self.big_events(home, per)
        home2, per2, second = self.run_seed()
        self.assertEqual(second["seed_cache"], {"small": "hit", "subagent": "hit", "big": "hit", "store": "hit"})
        self.assertEqual((self.Peer.started, self.Peer.sends), (1, sends))
        self.assertNotEqual(per["idle"]["big"], per2["idle"]["big"])  # fresh ids per run: every open stays cold
        warm = self.big_events(home2, per2)
        self.assertEqual(warm.replace(per2["idle"]["big"][0].encode(), b"ID"), cold.replace(per["idle"]["big"][0].encode(), b"ID"))
        self.assertEqual(warm.count(b"turn: "), 5)

    def test_no_seed_cache_seeds_again_and_writes_nothing(self):
        _home, _per, seeded = self.run_seed("--no-seed-cache")
        self.assertEqual(set(seeded["seed_cache"].values()), {"off"})
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "cache")))
        self.run_seed("--no-seed-cache")
        self.assertEqual(self.Peer.started, 2)

    def test_a_new_turn_count_seeds_only_the_big_chat(self):
        self.run_seed()
        _home, _per, seeded = self.run_seed("--turns", "6")
        self.assertEqual(seeded["seed_cache"], {"small": "hit", "subagent": "hit", "big": "miss", "store": "hit"})


if __name__ == "__main__":
    unittest.main()

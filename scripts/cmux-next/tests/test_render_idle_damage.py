#!/usr/bin/env python3
"""render-idle-damage.py's pure parts (p03-rendering-003): the availability check, the owner sums of motion rounds,
the MQ-damage-owners queue, the idle verdict, the session checks and the static pages. No app."""

from __future__ import annotations

import importlib.util
import sys
import unittest
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
spec = importlib.util.spec_from_file_location("render_idle_damage", HERE / "render-idle-damage.py")
rid = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rid)


def reply(damage, owners, frames=0):
    return {"available": True, "running": False, "seconds": 60.0, "damage": damage, "damage_per_s": damage / 60,
            "owners": owners, "ghostty": {"frames": frames, "frames_per_s": frames / 60, "display_calls": None}}


class AvailabilityTests(unittest.TestCase):
    def test_release_build_is_unavailable(self):
        # A Release router registers no debug.* method: the socket answers with an error and no `available`.
        self.assertIn("not a method", rid.unavailable_reason({"error": {"code": "method_not_found"}}))
        self.assertEqual(rid.unavailable_reason({"available": False, "error": "needs the render hooks"}),
                         "needs the render hooks")
        # A dead or wrong socket (bench_launch.rpc_at) is not a Release build, and neither is another failure.
        unreachable = {"error": "[Errno 2] No such file or directory", "unreachable": True}
        self.assertIsNone(rid.unavailable_reason(unreachable))
        self.assertIn("did not answer", rid.unreachable_reason(unreachable))
        self.assertIn("did not answer", rid.read_problem(unreachable))
        self.assertIsNone(rid.unavailable_reason({"error": {"code": "timeout"}}))
        self.assertIsNotNone(rid.read_problem({"error": {"code": "timeout"}}))
        self.assertIsNotNone(rid.read_problem(None))

    def test_debug_build_is_available(self):
        self.assertIsNone(rid.unavailable_reason({"available": True, "running": False}))
        self.assertIsNone(rid.read_problem({"available": True, "running": False}))

    def test_check_available_tells_a_dead_socket_from_a_release_build(self):
        bench = bench_with({"read": [{"error": "[Errno 61] Connection refused", "unreachable": True}]})
        with self.assertRaises(rid.MeasureError) as raised:
            bench.check_available()
        self.assertIn("did not answer", str(raised.exception))
        with self.assertRaises(rid.Unavailable):
            bench_with({"read": [{"error": {"code": "method_not_found", "message": "Unknown method debug.damage"}}]}).check_available()


class StopReplyTests(unittest.TestCase):
    def test_a_stop_without_counts_is_a_problem(self):
        self.assertIsNone(rid.stop_problem(reply(0, [])))
        for bad in (None, {"error": "timeout", "unreachable": True}, {"error": {"code": "timeout"}},
                    {"available": True, "running": False}, {"available": False, "error": "no hooks"}):
            self.assertIsNotNone(rid.stop_problem(bad), bad)

    def test_a_failed_idle_stop_never_passes(self):
        for bad in (None, {}, {"error": "timeout", "unreachable": True}, {"available": True, "running": False}):
            self.assertEqual(rid.verdict(bad), {"idle_damage_zero": False, "ghostty_idle_frames_zero": False}, bad)

    def test_a_failed_idle_stop_or_start_is_a_measure_error(self):
        unreachable = {"error": "timed out", "unreachable": True}
        for replies in ({"start": [{"running": True}], "stop": [unreachable]},
                        {"start": [{"running": True}], "stop": [{"available": True, "running": False}]},
                        {"start": [{"available": True, "running": False, "error": "the render hooks are not counting"}]}):
            with self.assertRaises(rid.MeasureError):
                bench_with(replies).idle()
        self.assertEqual(bench_with({"start": [{"running": True}], "stop": [reply(0, [])]}).idle(), reply(0, []))


class MotionTests(unittest.TestCase):
    def test_a_failed_round_goes_into_errors_and_out_of_the_sums(self):
        good = reply(3, [{"owner": "PaneView", "damage": 3, "damage_rects": 3}])
        bench = bench_with({"start": [{"running": True}, {"available": True, "running": False, "error": "not counting"},
                                      {"running": True}],
                            "stop": [good, good, {"available": True, "running": False}]}, rounds=3)
        results, incomplete = bench.motion()
        self.assertIsNone(incomplete)
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["rounds"], [good])
        self.assertEqual(results[0]["failed_rounds"], 2)
        self.assertEqual(results[0]["damage"], 3)
        self.assertEqual(results[0]["owners"][0]["damage"], 3)
        self.assertIn("round 2", results[0]["errors"][0])
        self.assertIn("no counts", results[0]["errors"][1])
        self.assertEqual(bench.undos, 3)

    def test_a_dead_socket_ends_the_motion_pass_and_keeps_what_finished(self):
        good = reply(2, [{"owner": "PaneView", "damage": 2, "damage_rects": 2}])
        dead = {"error": "[Errno 61] Connection refused", "unreachable": True}
        bench = bench_with({"start": [{"running": True}, dead], "stop": [good, dead]}, rounds=3, scenarios=2)
        results, incomplete = bench.motion()
        self.assertIn("did not answer", incomplete)
        self.assertEqual([r["scenario"] for r in results], ["s0"])
        self.assertEqual(results[0]["rounds"], [good])
        self.assertEqual(results[0]["failed_rounds"], 1)


class FakeStress:
    def __init__(self, rpc, log=print):
        self.rpc = rpc

    def focus_pane(self, pane):
        pass


class FakeStressModule:
    Stress = FakeStress


class FakeBench(rid.Bench):
    def __init__(self, rpc, opts, scenarios):
        super().__init__(rpc, FakeStressModule, opts, log=lambda *args, **kwargs: None)
        self.count = scenarios
        self.undos = 0

    def undo(self):
        self.undos += 1
        return {}

    def scenarios(self):
        return [(f"s{i}", None, lambda: {}, self.undo) for i in range(self.count)]


def bench_with(replies, rounds=1, scenarios=1):
    """A Bench whose `debug.damage` actions answer from `replies` (per action, in order) and whose sleeps are 0."""
    queues = {action: list(items) for action, items in replies.items()}

    def rpc(method, params=None, timeout=60):
        assert method == "debug.damage", method
        return queues[params["action"]].pop(0)
    opts = rid.parse(["--socket", "/tmp/x.sock", "--settle", "0", "--idle-s", "0", "--step-settle", "0",
                      "--rounds", str(rounds)])
    return FakeBench(rpc, opts, scenarios)


class OwnerTests(unittest.TestCase):
    def test_rounds_sum_by_owner_with_damage_only_most_first(self):
        rounds = [
            reply(5, [{"owner": "SidebarRowView", "damage": 3, "damage_rects": 3, "damage_area": 300},
                      {"owner": "TerminalSurfaceView", "damage": 2, "contents_sets": 2}]),
            reply(4, [{"owner": "TerminalSurfaceView", "damage": 4, "contents_sets": 4, "frame_sets": 9},
                      {"owner": "PaneView", "damage": 0, "frame_sets": 3}]),
            None,
        ]
        owners = rid.sum_owners(rounds)
        self.assertEqual([o["owner"] for o in owners], ["TerminalSurfaceView", "SidebarRowView"])
        self.assertEqual(owners[0], {"owner": "TerminalSurfaceView", "contents_sets": 6, "frame_sets": 9, "damage": 6})
        self.assertEqual(owners[1]["damage_area"], 300)

    def test_ties_break_on_area_then_name(self):
        owners = rid.sum_owners([reply(4, [{"owner": "B", "damage_rects": 2, "damage_area": 10},
                                           {"owner": "A", "damage_rects": 2, "damage_area": 10},
                                           {"owner": "C", "damage_rects": 2, "damage_area": 90}])])
        self.assertEqual([o["owner"] for o in owners], ["C", "A", "B"])

    def test_queue_lists_idle_owners_first_then_motion(self):
        idle = reply(7, [{"owner": "SpinnerView", "damage": 6, "damage_per_s": 0.1, "damage_rects": 6, "damage_area": 600},
                         {"owner": "TerminalSurfaceView", "damage": 1, "damage_per_s": 0.02, "contents_sets": 1}], frames=1)
        motion = [{"scenario": "split-right", "owners": [{"owner": "PaneChromeView", "damage_rects": 9},
                                                         {"owner": "SpinnerView", "damage_rects": 2}]},
                  {"scenario": "zoom", "owners": [{"owner": "PaneChromeView", "damage_rects": 1}]}]
        queue = rid.owner_queue(idle, motion)
        self.assertEqual([q["owner"] for q in queue], ["SpinnerView", "TerminalSurfaceView", "PaneChromeView"])
        self.assertEqual(queue[0]["idle_damage"], 6)
        self.assertEqual(queue[0]["idle_damage_area"], 600)
        self.assertEqual(queue[0]["motion_damage"], 2)
        self.assertEqual(queue[1]["idle_contents_sets"], 1)
        self.assertEqual(queue[2], {"owner": "PaneChromeView", "idle_damage": 0, "idle_damage_per_s": 0.0, "idle_damage_area": 0,
                                    "idle_contents_sets": 0, "motion_damage": 10, "scenarios": {"split-right": 9, "zoom": 1}})
        self.assertIn("PaneChromeView", rid.table(queue))

    def test_an_idle_window_with_no_damage_passes(self):
        self.assertEqual(rid.verdict(reply(0, [])), {"idle_damage_zero": True, "ghostty_idle_frames_zero": True})
        self.assertEqual(rid.verdict(reply(3, [], frames=3)), {"idle_damage_zero": False, "ghostty_idle_frames_zero": False})
        self.assertEqual(rid.owner_queue(reply(0, []), []), [])
        self.assertIn("no owner", rid.table([]))


class SessionTests(unittest.TestCase):
    def test_idle_pane_needs_its_tabs_and_a_selected_terminal(self):
        tabs = [{"kind": "browser"}] * 10 + [{"kind": "terminal", "selected": True}]
        self.assertEqual(rid.idle_problems(tabs, 10, {}, lambda cef: []), [])
        problems = rid.idle_problems(tabs[:3] + [{"kind": "terminal"}, {"kind": "browser", "selected": True}], 10, {},
                                     lambda cef: ["Chromium is not running"])
        self.assertEqual(len(problems), 3)
        self.assertIn("4 browser tabs", problems[0])
        self.assertIn("not a terminal", problems[1])

    def test_replies_errors_reads_a_reply_or_a_tuple(self):
        self.assertEqual(rid.replies_errors({"error": "refused"}), ["refused"])
        self.assertEqual(rid.replies_errors(({"ok": 1}, {"error": "no pane"}, None)), ["no pane"])
        self.assertEqual(rid.replies_errors(None), [])

    def test_static_pages_have_no_script(self):
        pages = rid.StaticPages()
        try:
            url = pages.url()
            self.assertTrue(url.startswith("http://127.0.0.1:"))
            body = urllib.request.urlopen(url, timeout=5).read().decode()
            self.assertIn("static page 1", body)
            self.assertNotIn("<script", body)
            self.assertNotIn("animation", body.replace("no animation", ""))
        finally:
            pages.close()
        self.assertEqual(rid.page_index("/idle/12"), 12)
        self.assertEqual(rid.page_index("/"), 0)

    def test_arguments(self):
        opts = rid.parse(["--socket", "/tmp/x.sock", "--no-motion", "--idle-s", "5"])
        self.assertFalse(opts.motion)
        self.assertEqual((opts.session, opts.tabs, opts.idle_s, opts.rounds), ("stress", 10, 5.0, 3))


if __name__ == "__main__":
    unittest.main()

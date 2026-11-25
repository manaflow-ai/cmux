"""screen-share-vs.py stage ledger: Apple to the presented frame, the table of every leg (wired and
a shaped Wi-Fi profile), and the shaper's start and clear around each leg. Fakes only: no Mac.

    python3 -m unittest cmux-tui/crates/cmux-rd-host/scripts/test_screen_share_vs_legs.py
"""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("screen_share_vs", os.path.join(HERE, "screen-share-vs.py"))
vs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vs)


def breakdown_row(**over):
    row = {"up": 1.0, "inject": 0.5, "draw": 10.0, "sck": 6.0, "gate": 2.0, "encode": 5.0,
           "send": 3.0, "first_packet": 1.0, "down": 4.0, "decode": 2.0, "total": 34.0}
    row.update(over)
    return row


def rows_named(b):
    return {r["row"]: r for r in b["rows"]}


class ApplePresented(unittest.TestCase):
    def test_observe_on_screen_sharing_makes_apple_total_end_at_the_presented_frame(self):
        b = vs.build_budget(None, {"g2g": [20.0, 30.0], "presented": [40.0, 50.0, 60.0]})
        total = rows_named(b)["Total"]["apple"]
        self.assertEqual(total["to"], "presented")
        self.assertEqual(total["p50"], 50.0)
        self.assertIn("Screen Sharing.app", total["source"])
        # Its stages stay null: Apple exposes none, and the RFB client is another viewer.
        self.assertIn("null", rows_named(b)["Present"]["apple"])

    def test_without_a_window_apple_total_is_the_rfb_update(self):
        b = vs.build_budget(None, {"g2g": [20.0, 30.0], "presented": None})
        self.assertEqual(rows_named(b)["Total"]["apple"]["to"], "RFB update")


class Legs(unittest.TestCase):
    def test_a_leg_named_after_a_profile_is_shaped_and_wired_is_not(self):
        self.assertEqual(vs.parse_legs("wired, wifi-away"), [("wired", None), ("wifi-away", "wifi-away")])
        self.assertEqual(vs.parse_legs("radio=wifi-long"), [("radio", "wifi-long")])
        self.assertEqual(vs.parse_legs(None), [])
        with self.assertRaises(SystemExit):
            vs.parse_legs("wired=bogus")

    def budgets(self):
        wired = vs.build_budget({"rows": [breakdown_row()] * 3, "presented": [40.0, 41.0, 42.0]},
                                {"g2g": [28.0], "presented": [45.0]}, rev="0123456789abcdef",
                                link="wired", rtt=0.79)
        radio = vs.build_budget({"rows": [breakdown_row(down=60.0, total=90.0)] * 3},
                                {"skipped": "skipped: no --vnc-user / --vnc-password-file given"},
                                rev="0123456789abcdef", link="wifi-away", rtt=4.5)
        return wired, radio

    def test_one_table_has_every_leg_side_by_side_with_glass_to_glass(self):
        text = "\n".join(vs.format_legs(list(self.budgets())))
        lines = text.splitlines()
        self.assertIn("@ 0123456789ab", lines[0])
        self.assertIn("leg 1: wired, udp rtt min 0.79 ms", text)
        self.assertIn("leg 2: wifi-away", text)
        head = next(line for line in lines if line.split()[:2] == ["stage", "budget"])
        for h in ("cmux wired", "Apple wired", "cmux wifi-away", "Apple wifi-away"):
            self.assertIn(h, head)
        for stage in ("Capture", "Encode", "Send", "Network", "Reassembly", "Decode", "Present"):
            self.assertTrue(any(line.strip().startswith(stage) for line in lines), stage)
        g2g = next(line for line in lines if line.strip().startswith("Glass to glass"))
        self.assertIn("41 / 42", g2g)  # cmux wired, to the presented frame
        self.assertIn("45 / 45", g2g)  # Apple wired, Screen Sharing.app presented
        self.assertIn("90 / 90 (to decoded)", g2g)  # the radio leg had no viewer pane
        network = next(line for line in lines if line.strip().startswith("Network"))
        self.assertIn("60 / 60", network)
        # Each null names its reason once in a footnote.
        self.assertIn("null: skipped: no --vnc-user", text)

    def test_table_reads_every_budget_record_of_a_run_file(self):
        wired, radio = self.budgets()
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "legs.jsonl")
            with open(p, "w") as f:
                for rec in ({"clock": {}}, {"budget": wired}, {"summary": {}}, {"budget": radio}):
                    f.write(json.dumps(rec) + "\n")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                vs.cmd_table(argparse.Namespace(files=[p]))
            self.assertIn("cmux wifi-away", out.getvalue())
            empty = os.path.join(d, "none.jsonl")
            with open(empty, "w") as f:
                f.write("{}\n")
            with self.assertRaises(SystemExit):
                vs.load_budgets([empty])


class CaptureSplit(unittest.TestCase):
    """Capture's two parts: the gate wait (ss-encode-transport's stage) and the Linux readback
    (ss-capture's capture_start_us)."""

    def breakdown(self, frame):
        o = vs.Orchestrator(types.SimpleNamespace(
            source="synthetic", host="h", viewer="v", via="ssh", root="/r", python="p", out=None))
        timing = [{"recv_us": 1_000, "inject_us": 1_100}, dict(frame, release_us=10_000,
                                                              encoded_us=15_000, sent_us=16_000)]
        sample = {"capture_us": 10_000, "sent_ns": 900_000, "first_rx_ns": 17_000_000,
                  "complete_ns": 18_000_000, "decoded_ns": 20_000_000}
        return o.breakdown({"sample_times": [sample]}, timing, 0)[0]

    def test_linux_capture_start_splits_gate_wait_from_readback(self):
        row = self.breakdown({"damage_us": 6_000, "capture_start_us": 8_000})
        self.assertEqual((row["gate_wait"], row["readback"]), (2.0, 2.0))
        b = vs.build_budget({"rows": [row]}, None)
        self.assertEqual(rows_named(b)[" Readback"]["cmux"]["p50"], 2.0)
        self.assertEqual(rows_named(b)[" Gate wait"]["cmux"]["p50"], 2.0)

    def test_without_capture_start_the_gate_wait_runs_to_encode_start_and_readback_says_why(self):
        row = self.breakdown({"shown_us": 5_000, "arrived_us": 7_000})
        self.assertEqual((row["gate_wait"], row["readback"]), (3.0, None))
        b = vs.build_budget({"rows": [row]}, None)
        self.assertIn("capture_start_us", rows_named(b)[" Readback"]["cmux"]["null"])
        self.assertEqual(rows_named(b)["Capture"]["cmux"]["p50"], 5.0)  # sck 2 + gate 3, unchanged

    def test_a_record_from_before_the_split_still_tables_beside_a_new_one(self):
        old = vs.build_budget({"rows": [breakdown_row()]}, None, link="old")
        old["rows"] = [r for r in old["rows"] if r["row"] not in (" Gate wait", " Readback")]
        new = vs.build_budget({"rows": [breakdown_row(gate_wait=2.0)]}, None, link="new")
        lines = vs.format_legs([old, new])
        wait = next(line for line in lines if line.strip().startswith("Gate wait"))
        self.assertIn("-", wait.split()[2])
        self.assertIn("2 / 2", wait)


class FakeRemote:
    def __init__(self, fail_on=()):
        self.calls, self.fail_on = [], fail_on

    def run(self, cmd, timeout=120, stdin=None):
        self.calls.append(cmd)
        if any(f in cmd for f in self.fail_on):
            raise RuntimeError("refused")
        if cmd.endswith(" holds"):
            return json.dumps({"kind": "long", "hold_ms": 455}) + "\n"
        return ""

    def put(self, local, remote_path, mode="0755"):
        self.calls.append(f"put {os.path.basename(local)} {remote_path}")


def orchestrator(**kw):
    args = dict(source="synthetic", host="cmux20", viewer="cmux17", via="ssh", root="/Users/c/rd",
                python="/usr/bin/python3", out=None, shape="wifi-away", viewer_ip="10.0.0.7",
                shape_max_s=900, shape_sudo="sudo -n", host_ip="10.0.0.5")
    args.update(kw)
    o = vs.Orchestrator(types.SimpleNamespace(**args))
    o.host = FakeRemote()
    o.setup = lambda: None
    return o


class Shape(unittest.TestCase):
    def test_a_shaped_leg_starts_the_profile_toward_the_viewer_and_clears_it_after(self):
        o = orchestrator()
        o.measure = lambda: {"budget": "b"}
        logged = []
        o.log = logged.append
        self.assertEqual(o.main(), {"budget": "b"})
        self.assertTrue(os.path.exists(vs.MAC_HOLDS), vs.MAC_HOLDS)
        self.assertEqual(o.host.calls[0], "put mac-holds.sh /Users/c/rd/bin/mac-holds.sh")
        self.assertEqual(o.host.calls[1:], [
            "sudo -n /bin/bash /Users/c/rd/bin/mac-holds.sh start wifi-away 900 10.0.0.7",
            "sudo -n /bin/bash /Users/c/rd/bin/mac-holds.sh holds",
            "sudo -n /bin/bash /Users/c/rd/bin/mac-holds.sh clear"])
        self.assertEqual(logged[-1]["holds"], [{"kind": "long", "hold_ms": 455}])
        self.assertFalse(o.shaped)

    def test_a_leg_that_fails_still_clears_the_shaper(self):
        o = orchestrator()
        o.log = lambda rec: None

        def boom():
            raise RuntimeError("bench died")
        o.measure = boom
        with self.assertRaises(RuntimeError):
            o.main()
        self.assertTrue(o.host.calls[-1].endswith("mac-holds.sh clear"))

    def test_a_start_that_fails_still_clears_the_shaper(self):
        o = orchestrator()
        o.log = lambda rec: None
        real = o.shape_run

        def run(verb):
            if verb.startswith("start"):
                real(verb)
                raise RuntimeError("mac-holds start died after the pipe")
            return real(verb)
        o.shape_run = run
        o.measure = lambda: self.fail("measured on a failed start")
        with self.assertRaises(RuntimeError):
            o.main()
        self.assertTrue(o.host.calls[-1].endswith("mac-holds.sh clear"))

    def test_one_failed_leg_keeps_the_others_and_the_table(self):
        ran, printed = [], []

        class Orch:
            def __init__(self, a):
                self.a = a

            def main(self):
                ran.append(self.a.link)
                if self.a.link == "wifi-away":
                    raise RuntimeError("warm-up failed")
                return {"leg": self.a.link}
        old = vs.Orchestrator, vs.format_legs
        vs.Orchestrator = Orch
        vs.format_legs = lambda budgets: printed.append(budgets) or ["table"]
        try:
            with self.assertRaises(SystemExit) as e:
                vs.cmd_run(argparse.Namespace(legs="wifi-away,wired"))
        finally:
            vs.Orchestrator, vs.format_legs = old
        self.assertEqual(ran, ["wifi-away", "wired"])
        self.assertEqual(printed, [[{"leg": "wired"}]])
        self.assertIn("wifi-away", str(e.exception))

    def test_every_leg_failed_prints_no_table(self):
        class Orch:
            def __init__(self, a):
                pass

            def main(self):
                raise RuntimeError("down")
        old = vs.Orchestrator, vs.format_legs
        vs.Orchestrator = Orch
        vs.format_legs = lambda budgets: self.fail("table printed with no leg")
        try:
            with self.assertRaises(SystemExit) as e:
                vs.cmd_run(argparse.Namespace(legs="wired,wifi-away"))
        finally:
            vs.Orchestrator, vs.format_legs = old
        self.assertIn("wired, wifi-away", str(e.exception))

    def test_an_unshaped_leg_never_touches_the_shaper(self):
        o = orchestrator(shape=None)
        o.measure = lambda: None
        o.main()
        self.assertEqual(o.host.calls, [])

    def test_shape_needs_the_viewer_address(self):
        o = orchestrator(viewer_ip=None)
        o.measure = lambda: None
        with self.assertRaises(SystemExit):
            o.main()

    def test_local_sudo_runs_here_with_the_host_filled_in(self):
        o = orchestrator(shape_sudo="local:echo {host}")
        self.assertEqual(o.shape_run("show").strip(), "cmux20 /bin/bash /Users/c/rd/bin/mac-holds.sh show")
        o = orchestrator(shape_sudo="local:false")
        with self.assertRaises(RuntimeError):
            o.shape_run("show")


WINDOWS = [
    {"owner": "Dock", "pid": 1, "window": 5, "title": "", "layer": 20, "w": 2000, "h": 80},
    {"owner": "Screen Sharing", "pid": 900, "window": 41, "title": "old", "layer": 0, "w": 800, "h": 600},
    {"owner": "Screen Sharing", "pid": 900, "window": 77, "title": "10.0.0.5", "layer": 0, "w": 1600,
     "h": 1000},
    {"owner": "Screen Sharing", "pid": 900, "window": 78, "title": "", "layer": 0, "w": 40, "h": 20},
]


class FakeViewer:
    """The viewing Mac: answers `apple open|close` and observe."""

    def __init__(self, opened):
        self.opened, self.calls = opened, []

    def run(self, cmd, timeout=120, stdin=None):
        self.calls.append(cmd)
        if " apple open " in cmd:
            return json.dumps(self.opened) + "\n"
        if " apple close " in cmd:
            return json.dumps({"killed": 900}) + "\n"
        if "cmux-rd observe" in cmd:
            return json.dumps({"complete": True, "samples_us": [40000, 50000, 60000], "n": 3}) + "\n"
        raise AssertionError(cmd)


def apple_orchestrator(opened):
    o = orchestrator(shape=None, vnc_user="bench", vnc_password_file="/Users/c/.vncpw",
                     timeout=30, samples=3, apple_presented_pid=None, apple_presented_window=None)
    o.a.apple_viewer = True  # past setup's check for --tools (no Mac here)
    o.viewer = FakeViewer(opened)
    o.rig = lambda msg: {}
    o.logged = []
    o.log = o.logged.append
    return o


class AppleViewer(unittest.TestCase):
    def test_the_url_quotes_the_password_and_redact_hides_it(self):
        url = vs.vnc_url("bench", "p@ss:w/rd", "10.0.0.5")
        self.assertEqual(url, "vnc://bench:p%40ss%3Aw%2Frd@10.0.0.5")
        self.assertEqual(vs.redact_vnc(f"open {url}: exit 1"), "open vnc://bench:***@10.0.0.5: exit 1")

    def test_the_window_is_the_new_screen_sharing_window_naming_the_host(self):
        self.assertEqual(vs.screen_sharing_window(WINDOWS, "10.0.0.5"),
                         {"pid": 900, "window": 77, "title": "10.0.0.5"})
        # One there before the run is never picked; a tiny one is no viewer window.
        only_old = [w for w in WINDOWS if w["window"] != 77]
        self.assertIsNone(vs.screen_sharing_window(only_old, "10.0.0.5", exclude={41}))
        self.assertIsNone(vs.screen_sharing_window([], "10.0.0.5"))

    def test_a_found_window_is_observed_and_apple_total_ends_presented(self):
        o = apple_orchestrator({"pid": 900, "window": 77, "title": "10.0.0.5", "launched": True,
                                "origin": "100,200", "cell": 32, "at": "90,190"})
        self.assertEqual(o.run_apple_presented(), [40.0, 50.0, 60.0])
        self.assertEqual(o.apple_presented_source["kind"], "apple-viewer")
        self.assertEqual(o.apple_presented_source["window"], 77)
        opened = next(c for c in o.viewer.calls if " apple open " in c)
        self.assertIn("--password-file /Users/c/.vncpw", opened)
        self.assertIn("--host 10.0.0.5", opened)
        observe = next(c for c in o.viewer.calls if "cmux-rd observe" in c)
        self.assertIn("--pid 900 --window 77", observe)
        self.assertIn("--marker-origin 100,200 --at 90,190", observe)
        self.assertTrue(o.viewer.calls[-1].endswith("--launched --state /Users/c/rd/state"), o.viewer.calls[-1])
        b = vs.build_budget(None, {"g2g": [20.0], "presented": [40.0, 50.0, 60.0],
                                   "presented_source": o.apple_presented_source})
        total = rows_named(b)["Total"]["apple"]
        self.assertEqual((total["to"], total["via"]), ("presented", "apple-viewer"))

    def test_a_failed_open_is_a_null_reason_on_apple_total_only(self):
        o = apple_orchestrator({"error": "no Screen Sharing window to 10.0.0.5 in 30 s"})
        self.assertIsNone(o.run_apple_presented())
        self.assertIn("no Screen Sharing window", o.apple_presented_source["null"])
        self.assertFalse(any("cmux-rd observe" in c for c in o.viewer.calls))
        self.assertFalse(any(" apple close " in c for c in o.viewer.calls))
        b = vs.build_budget(None, {"g2g": [20.0, 30.0], "presented": None,
                                   "presented_source": o.apple_presented_source})
        total = rows_named(b)["Total"]["apple"]
        self.assertEqual(total["to"], "RFB update")
        self.assertIn("no Screen Sharing window", total["presented_null"])

    def test_apple_open_never_prints_the_password(self):
        with tempfile.TemporaryDirectory() as d:
            pw = os.path.join(d, "pw")
            with open(pw, "w") as f:
                f.write("hunter2secret\n")
            calls = []

            def fake_run(argv, **kw):
                calls.append(argv)
                return types.SimpleNamespace(returncode=1, stdout="", stderr=f"cannot open {argv[-1]}")
            old_run, old_list = vs.subprocess.run, vs.list_windows
            vs.subprocess.run, vs.list_windows = fake_run, lambda state: []
            out = io.StringIO()
            try:
                with contextlib.redirect_stdout(out):
                    vs.cmd_apple(argparse.Namespace(action="open", host="10.0.0.5", user="bench",
                                                    password_file=pw, state=d, locate="x", wait=1,
                                                    locate_wait=1, pid=None, launched=False))
            finally:
                vs.subprocess.run, vs.list_windows = old_run, old_list
            self.assertIn(["open", "vnc://bench:hunter2secret@10.0.0.5"], calls)
            text = out.getvalue()
            self.assertNotIn("hunter2secret", text)
            self.assertIn("***@10.0.0.5", json.loads(text)["error"])

    def open_with(self, windows_after, pids_before, pids_after, wait=0):
        """cmd_apple open with `open` succeeding, WINDOWS_AFTER listed once it ran, and pgrep
        answering PIDS_BEFORE then PIDS_AFTER: its JSON line and the pids it SIGTERMed."""
        pgreps, killed = [set(pids_before), set(pids_after)], []

        def fake_run(argv, **kw):
            if argv[0] == "pgrep":
                pids = pgreps.pop(0) if len(pgreps) > 1 else pgreps[0]
                return types.SimpleNamespace(returncode=0 if pids else 1, stderr="",
                                             stdout="".join(f"{x}\n" for x in sorted(pids)))
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")
        lists = [[], windows_after]
        saved = (vs.subprocess.run, vs.list_windows, vs.os.kill)
        vs.subprocess.run = fake_run
        vs.list_windows = lambda state: lists.pop(0) if len(lists) > 1 else lists[0]
        vs.os.kill = lambda pid, sig: killed.append(pid)
        out = io.StringIO()
        try:
            with tempfile.TemporaryDirectory() as d, contextlib.redirect_stdout(out):
                pw = os.path.join(d, "pw")
                with open(pw, "w") as f:
                    f.write("pw\n")
                vs.cmd_apple(argparse.Namespace(action="open", host="10.0.0.5", user="bench",
                                                password_file=pw, state=d, locate="x", wait=wait,
                                                locate_wait=1, pid=None, launched=False))
        finally:
            vs.subprocess.run, vs.list_windows, vs.os.kill = saved
        return json.loads(out.getvalue()), killed

    def test_no_window_quits_only_the_screen_sharing_this_run_started(self):
        out, killed = self.open_with([], pids_before={500}, pids_after={500, 900})
        self.assertIn("no Screen Sharing window to 10.0.0.5", out["error"])
        self.assertEqual((killed, out["killed"]), ([900], [900]))
        self.assertNotIn("pid", out)  # nothing left for the caller to close
        # One that ran before is never touched.
        out, killed = self.open_with([], pids_before={500}, pids_after={500})
        self.assertEqual((killed, out["killed"]), ([], []))

    def test_an_unnamed_window_is_never_picked_and_says_so(self):
        unnamed = [{"owner": "Screen Sharing", "pid": 900, "window": 90, "title": "other-mac",
                    "layer": 0, "w": 1600, "h": 1000}]
        self.assertIsNone(vs.screen_sharing_window(unnamed, "10.0.0.5"))
        out, killed = self.open_with(unnamed, pids_before=set(), pids_after={900})
        self.assertIn("no Screen Sharing window names 10.0.0.5", out["error"])
        self.assertEqual(killed, [900])

    def test_the_presented_flags_path_says_why_when_observe_is_incomplete(self):
        o = orchestrator(shape=None, timeout=30, samples=3, apple_presented_pid=900,
                         apple_presented_window=77, apple_presented_origin="100,200",
                         apple_presented_cell=32, apple_presented_at="90,190")
        o.a.apple_viewer = False
        o.viewer = types.SimpleNamespace(run=lambda cmd, timeout=120, stdin=None:
                                         json.dumps({"complete": False, "error": "obscured"}) + "\n")
        o.rig = lambda msg: {}
        o.log = lambda rec: None
        self.assertIsNone(o.run_apple_presented())
        self.assertEqual(o.apple_presented_source["kind"], "presented-flags")
        self.assertEqual(o.apple_presented_source["null"], "observe incomplete")
        b = vs.build_budget(None, {"g2g": [20.0], "presented": None,
                                   "presented_source": o.apple_presented_source})
        total = rows_named(b)["Total"]["apple"]
        self.assertEqual((total["to"], total["presented_null"]), ("RFB update", "observe incomplete"))

    def test_setup_refuses_apple_viewer_without_the_locate_tool(self):
        with self.assertRaises(SystemExit) as e:
            orchestrator(shape=None, apple_viewer=True, vnc_user="bench", vnc_password_file="p",
                         apple_presented_pid=None, apple_presented_window=None)
        self.assertIn("screen-eval-marker-locate", str(e.exception))

    def test_close_kills_only_a_process_this_run_started(self):
        out = io.StringIO()
        with tempfile.TemporaryDirectory() as d, contextlib.redirect_stdout(out):
            vs.cmd_apple(argparse.Namespace(action="close", pid=900, launched=False, state=d))
        self.assertIn("left", json.loads(out.getvalue()))


if __name__ == "__main__":
    unittest.main()
